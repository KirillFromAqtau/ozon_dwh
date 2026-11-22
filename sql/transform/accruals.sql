-- =====================================================================
--  raw.ozon_accrual_pages  ->  core.accruals
--  Одно начисление Ozon (accrual_id) раскладываем на "атомы":
--    продажа (sale_amount), комиссия, каждая услуга логистики, штраф...
--  Тогда любую сумму можно сгруппировать как угодно.
--  Полная пересборка из raw: идемпотентно, дублей не бывает.
-- =====================================================================

-- 0. Справочник типов из последней загрузки + группировка по имени
INSERT INTO core.accrual_types (type_id, name, description, accrual_group)
SELECT (t->>'id')::int, t->>'name', t->>'description',
    CASE
      WHEN t->>'name' = 'SaleCommission'                                   THEN 'commission'
      WHEN t->>'name' = 'Acquiring'                                        THEN 'acquiring'
      WHEN t->>'name' ~ '^(DefectRate|DefectFine|PenaltyFee)'              THEN 'penalty'
      WHEN t->>'name' ~ '(ReturnFlowLogistic|BackwardShipment|BackwardLogistics|ClientReturn|Cancellation|PartialReturn|ReturnAcceptance|PreparingToReturn|Disposal)'
                                                                           THEN 'returns'
      WHEN t->>'name' ~ '(Placement|ReturnStorage)'                        THEN 'storage'
      WHEN t->>'name' ~ '(Marketing|PayPerClick|Promotion|Premium|Brand|Advertising|Review|Stencil|PushCampaign|StarsMembership)'
                                                                           THEN 'ads'
      WHEN t->>'name' ~ '(Logistic|LastMile|Shipment|Drop-Off|Pick-Up|PickUp|Delivery|CrossDock|Fulfillment|Packing|Package|Quant)'
                                                                           THEN 'logistics'
      ELSE 'other'
    END
FROM (SELECT payload FROM raw.ozon_accrual_types ORDER BY loaded_at DESC LIMIT 1) r
CROSS JOIN LATERAL jsonb_array_elements(r.payload->'accrual_types') t
ON CONFLICT (type_id) DO UPDATE SET
    name = EXCLUDED.name, description = EXCLUDED.description,
    accrual_group = EXCLUDED.accrual_group;

-- 1. Пересобираем атомы начислений
DELETE FROM core.accruals;

WITH acc AS (                              -- все начисления из всех страниц
    SELECT a
    FROM raw.ozon_accrual_pages p
    CROSS JOIN LATERAL jsonb_array_elements(p.payload->'accruals') a
),
atoms AS (
    -- 1a. Выручка по товару в отправлении
    SELECT a, (pr->>'sku')::bigint AS sku, 'sale:' || (pr->>'sku') AS part,
           NULL::int AS type_id, 'SaleAmount' AS accrual_type, 'revenue' AS grp,
           (pr->'commission'->'sale_amount'->>'amount')::numeric  AS amount,
           pr->'commission'->'sale_amount'->>'currency'           AS currency
    FROM acc CROSS JOIN LATERAL jsonb_array_elements(a->'posting'->'products') pr
    WHERE jsonb_typeof(pr->'commission') = 'object'
  UNION ALL
    -- 1b. Комиссия за продажу
    SELECT a, (pr->>'sku')::bigint, 'comm:' || (pr->>'sku'),
           69, 'SaleCommission', 'commission',
           (pr->'commission'->'sale_commission'->>'amount')::numeric,
           pr->'commission'->'sale_commission'->>'currency'
    FROM acc CROSS JOIN LATERAL jsonb_array_elements(a->'posting'->'products') pr
    WHERE jsonb_typeof(pr->'commission') = 'object'
  UNION ALL
    -- 1c. Услуги доставки по товару (логистика, обратная логистика...)
    SELECT a, (pr->>'sku')::bigint, 'svc:' || (pr->>'sku') || ':' || (s->>'type_id') || ':' || n,
           (s->>'type_id')::int, NULL, NULL,
           (s->'accrued'->>'amount')::numeric, s->'accrued'->>'currency'
    FROM acc
    CROSS JOIN LATERAL jsonb_array_elements(a->'posting'->'products') pr
    CROSS JOIN LATERAL jsonb_array_elements(pr->'delivery'->'services') WITH ORDINALITY AS sv(s, n)
    WHERE jsonb_typeof(pr->'delivery') = 'object'
  UNION ALL
    -- 1d. Начисления не по товару (штрафы, подписки, хранение...)
    SELECT a, NULL, 'nonitem:' || (a->'non_item_fee'->>'type_id'),
           (a->'non_item_fee'->>'type_id')::int, NULL, NULL,
           (a->'non_item_fee'->'accrued'->>'amount')::numeric,
           a->'non_item_fee'->'accrued'->>'currency'
    FROM acc
    WHERE jsonb_typeof(a->'non_item_fee') = 'object'
  UNION ALL
    -- 1d'. Сборы по товару вне отправления (accrued_category = ITEM),
    --      например утилизация. Структура: item_fees.fees[] → {sku, fees[] → {type_id, accrued}}
    SELECT a, (it->>'sku')::bigint,
           'item:' || (it->>'sku') || ':' || (f->>'type_id') || ':' || n,
           (f->>'type_id')::int, NULL, NULL,
           (f->'accrued'->>'amount')::numeric, f->'accrued'->>'currency'
    FROM acc
    CROSS JOIN LATERAL jsonb_array_elements(a->'item_fees'->'fees') it
    CROSS JOIN LATERAL jsonb_array_elements(it->'fees') WITH ORDINALITY AS fe(f, n)
    WHERE jsonb_typeof(a->'item_fees') = 'object'
),
-- 1e. Контроль: сумма атомов должна совпасть с total_amount.
--     Если Ozon прислал блок, который мы не разбираем (item_fees, container_fees),
--     разница попадёт в строку 'Unparsed' — итоги не потеряются, а мы увидим проблему.
unparsed AS (
    SELECT acc.a, NULL::bigint AS sku, 'unparsed' AS part, NULL::int AS type_id,
           'Unparsed' AS accrual_type, 'other' AS grp,
           (acc.a->'total_amount'->>'amount')::numeric - COALESCE(s.sum_amount, 0) AS amount,
           acc.a->'total_amount'->>'currency' AS currency
    FROM acc
    LEFT JOIN (SELECT a->>'accrual_id' AS id, SUM(amount) AS sum_amount
               FROM atoms GROUP BY 1) s ON s.id = acc.a->>'accrual_id'
    WHERE abs((acc.a->'total_amount'->>'amount')::numeric - COALESCE(s.sum_amount, 0)) > 0.005
),
all_atoms AS (SELECT * FROM atoms UNION ALL SELECT * FROM unparsed)
INSERT INTO core.accruals (accrual_id, ozon_accrual_id, operation_date, accrued_category,
                           unit_number, posting_number, ozon_sku, offer_id,
                           type_id, accrual_type, accrual_group, amount, currency)
SELECT
    (x.a->>'accrual_id') || ':' || x.part,
    (x.a->>'accrual_id')::bigint,
    (x.a->>'date')::date,
    x.a->>'accrued_category',
    x.a->>'unit_number',
    -- номер отправления имеет вид 12345678-0001-1 (три части)
    CASE WHEN x.a->>'unit_number' ~ '^\d+-\d+-\d+$' THEN x.a->>'unit_number' END,
    x.sku,
    COALESCE(pi.offer_id, pr.offer_id),
    x.type_id,
    COALESCE(x.accrual_type, t.name, 'type_' || x.type_id),
    COALESCE(x.grp, t.accrual_group, 'other'),
    x.amount,
    COALESCE(x.currency, 'KZT')
FROM all_atoms x
LEFT JOIN core.accrual_types t ON t.type_id = x.type_id
LEFT JOIN core.posting_items pi
       ON pi.posting_number = x.a->>'unit_number' AND pi.ozon_sku = x.sku
LEFT JOIN core.products pr
       ON pr.ozon_sku = x.sku;          -- для ITEM-начислений без отправления

-- 2. Дата вручения ≈ день, когда Ozon начислил выручку за отправление
UPDATE core.postings p
SET delivered_at = s.first_sale
FROM (SELECT posting_number, MIN(operation_date)::timestamptz AS first_sale
      FROM core.accruals WHERE accrual_group = 'revenue' AND posting_number IS NOT NULL
      GROUP BY 1) s
WHERE s.posting_number = p.posting_number
  AND p.delivered_at IS DISTINCT FROM s.first_sale;
