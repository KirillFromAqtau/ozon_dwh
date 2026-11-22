-- =====================================================================
--  Трансформация raw.ozon_postings_fbs -> core.postings + core.posting_items
--  Сверено с реальным ответом /v4/posting/fbs/list (ноябрь 2026).
--  Идемпотентно: можно запускать сколько угодно раз.
-- =====================================================================

-- 1. Шапка отправления
INSERT INTO core.postings (posting_number, order_number, scheme, status, substatus,
                           created_at, shipment_deadline, shipped_at,
                           cancel_reason, cancel_initiator, delivery_type,
                           region, cluster_to, updated_at)
SELECT
    r.source_id,
    p->>'order_number',
    'FBS',
    p->>'status',
    p->>'substatus',
    NULLIF(p->>'in_process_at','')::timestamptz,          -- покупатель оформил
    NULLIF(p->>'shipment_date','')::timestamptz,          -- крайний срок отгрузки
    NULLIF(p->>'delivering_date','')::timestamptz,        -- факт. передача в доставку
    NULLIF(p->'cancellation'->>'cancel_reason',''),
    NULLIF(p->'cancellation'->>'cancellation_initiator',''),
    NULLIF(p->'analytics_data'->>'delivery_type',''),
    NULLIF(p->'analytics_data'->>'region',''),            -- часто пустой
    NULLIF(p->'financial_data'->>'cluster_to',''),
    now()
FROM raw.ozon_postings_fbs r
CROSS JOIN LATERAL (SELECT r.payload AS p) x
ON CONFLICT (posting_number) DO UPDATE SET
    status            = EXCLUDED.status,
    substatus         = EXCLUDED.substatus,
    shipment_deadline = EXCLUDED.shipment_deadline,
    shipped_at        = EXCLUDED.shipped_at,
    cancel_reason     = EXCLUDED.cancel_reason,
    cancel_initiator  = EXCLUDED.cancel_initiator,
    delivery_type     = EXCLUDED.delivery_type,
    region            = COALESCE(EXCLUDED.region, core.postings.region),
    cluster_to        = EXCLUDED.cluster_to,
    updated_at        = now();

-- 2. Товары внутри отправления.
--    products[]                 — твоя цена (в KZT)
--    financial_data.products[]  — цена для покупателя (в RUB); связь по sku = product_id
INSERT INTO core.posting_items (posting_number, offer_id, ozon_sku, quantity,
                                price, currency, customer_price, customer_currency)
SELECT
    r.source_id,
    pr->>'offer_id',
    (pr->>'sku')::bigint,
    SUM((pr->>'quantity')::int),
    MAX(CASE jsonb_typeof(pr->'price')
            WHEN 'object' THEN (pr->'price'->>'amount')::numeric
            ELSE NULLIF(pr->>'price','')::numeric END),
    MAX(COALESCE(pr->'price'->>'currency', pr->>'currency_code', 'KZT')),
    MAX((fp->'customer_price'->>'amount')::numeric),
    MAX(fp->'customer_price'->>'currency')
FROM raw.ozon_postings_fbs r
CROSS JOIN LATERAL jsonb_array_elements(r.payload->'products') AS pr
LEFT JOIN LATERAL (
    SELECT f FROM jsonb_array_elements(r.payload->'financial_data'->'products') f
    WHERE (f->>'product_id')::bigint = (pr->>'sku')::bigint
    LIMIT 1) AS fin(fp) ON TRUE
GROUP BY r.source_id, pr->>'offer_id', (pr->>'sku')::bigint
ON CONFLICT (posting_number, offer_id) DO UPDATE SET
    quantity          = EXCLUDED.quantity,
    price             = EXCLUDED.price,
    currency          = EXCLUDED.currency,
    customer_price    = EXCLUDED.customer_price,
    customer_currency = EXCLUDED.customer_currency;
