-- =====================================================================
--  MART: витрины для дашбордов (все суммы приводим к тенге)
-- =====================================================================

-- Курс на дату: берём последний известный курс не позже этой даты.
-- (на выходных курса нет — тогда возьмётся пятничный)
CREATE OR REPLACE FUNCTION mart.fx(p_date DATE, p_from CHAR(3), p_to CHAR(3) DEFAULT 'KZT')
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_from = p_to THEN 1 ELSE (
        SELECT rate FROM core.fx_rates
        WHERE currency_from = p_from AND currency_to = p_to AND rate_date <= p_date
        ORDER BY rate_date DESC LIMIT 1) END
$$;

-- ---------------------------------------------------------------------
-- 1. Себестоимость одной штуки каждого товара (в тенге)
--    пластик + электричество + амортизация принтера + упаковка
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.product_unit_cost AS
WITH filament_price AS (          -- средневзвешенная цена кг по материалу
    SELECT material_id,
           SUM(total_cost * mart.fx(purchase_date, currency)) / SUM(weight_kg) AS kzt_per_kg
    FROM core.material_purchases
    GROUP BY material_id
),
settings AS (                     -- актуальные (последние) значения настроек
    SELECT DISTINCT ON (setting_key) setting_key, value
    FROM core.cost_settings
    ORDER BY setting_key, valid_from DESC
),
printer_avg AS (                  -- "средний" принтер парка
    SELECT AVG(avg_power_w)                       AS power_w,
           AVG(purchase_price / expected_life_h)  AS kzt_per_hour
    FROM core.printers WHERE is_active
)
SELECT
    p.offer_id,
    p.name,
    p.filament_g,
    p.print_time_min,
    ROUND(p.filament_g / 1000 * fp.kzt_per_kg, 2)                                    AS cost_filament,
    ROUND(p.print_time_min / 60.0 * pa.power_w / 1000
          * COALESCE((SELECT value FROM settings WHERE setting_key='electricity_per_kwh'),0), 2) AS cost_electricity,
    ROUND(p.print_time_min / 60.0 * pa.kzt_per_hour, 2)                              AS cost_depreciation,
    COALESCE((SELECT value FROM settings WHERE setting_key='packaging_per_unit'),0)  AS cost_packaging,
    ROUND(
        COALESCE(p.filament_g / 1000 * fp.kzt_per_kg, 0)
      + COALESCE(p.print_time_min / 60.0 * pa.power_w / 1000
          * (SELECT value FROM settings WHERE setting_key='electricity_per_kwh'), 0)
      + COALESCE(p.print_time_min / 60.0 * pa.kzt_per_hour, 0)
      + COALESCE((SELECT value FROM settings WHERE setting_key='packaging_per_unit'),0)
    , 2)                                                                              AS unit_cost_kzt
FROM core.products p
LEFT JOIN filament_price fp ON fp.material_id = p.material_id
CROSS JOIN printer_avg pa;

-- ---------------------------------------------------------------------
-- 2. Финансы по каждому отправлению: что Ozon начислил и списал
--    (переводим в тенге по курсу на дату операции)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.posting_finance AS
SELECT
    a.posting_number,
    SUM(a.amount * mart.fx(a.operation_date, a.currency)) FILTER (WHERE COALESCE(a.accrual_group, m.accrual_group) = 'revenue')                    AS revenue_kzt,
    SUM(a.amount * mart.fx(a.operation_date, a.currency)) FILTER (WHERE COALESCE(a.accrual_group, m.accrual_group) = 'commission')                 AS commission_kzt,
    SUM(a.amount * mart.fx(a.operation_date, a.currency)) FILTER (WHERE COALESCE(a.accrual_group, m.accrual_group) IN ('logistics','last_mile'))   AS logistics_kzt,
    SUM(a.amount * mart.fx(a.operation_date, a.currency)) FILTER (WHERE COALESCE(a.accrual_group, m.accrual_group) NOT IN
                                                         ('revenue','commission','logistics','last_mile')
                                                         OR COALESCE(a.accrual_group, m.accrual_group) IS NULL)                                    AS other_kzt,
    SUM(a.amount * mart.fx(a.operation_date, a.currency))                                                                                         AS payout_kzt
FROM core.accruals a
LEFT JOIN core.accrual_type_map m ON m.accrual_type = a.accrual_type
WHERE a.posting_number IS NOT NULL
GROUP BY a.posting_number;

-- ---------------------------------------------------------------------
-- 3. Юнит-экономика по товару: сколько реально зарабатываешь с 1 продажи
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.unit_economics AS
WITH sold AS (
    SELECT i.offer_id,
           i.posting_number,
           i.quantity
    FROM core.posting_items i
    JOIN core.postings p USING (posting_number)
    WHERE p.status = 'delivered'
),
-- если в отправлении несколько товаров, делим деньги пропорционально кол-ву
alloc AS (
    SELECT s.offer_id,
           s.quantity,
           f.payout_kzt  * s.quantity / SUM(s.quantity) OVER (PARTITION BY s.posting_number) AS payout_kzt,
           f.revenue_kzt * s.quantity / SUM(s.quantity) OVER (PARTITION BY s.posting_number) AS revenue_kzt
    FROM sold s
    JOIN mart.posting_finance f USING (posting_number)
)
SELECT
    a.offer_id,
    pr.name,
    SUM(a.quantity)                                        AS units_sold,
    ROUND(SUM(a.revenue_kzt) / SUM(a.quantity), 0)         AS avg_price_kzt,
    ROUND(SUM(a.payout_kzt)  / SUM(a.quantity), 0)         AS avg_payout_kzt,   -- пришло на счёт
    uc.unit_cost_kzt,
    ROUND(SUM(a.payout_kzt) / SUM(a.quantity) - uc.unit_cost_kzt, 0)          AS profit_per_unit_kzt,
    ROUND(SUM(a.payout_kzt) - uc.unit_cost_kzt * SUM(a.quantity), 0)          AS total_profit_kzt,
    ROUND(100 * (SUM(a.payout_kzt) - uc.unit_cost_kzt * SUM(a.quantity))
          / NULLIF(SUM(a.revenue_kzt), 0), 1)                                 AS margin_pct
FROM alloc a
JOIN core.products pr USING (offer_id)
LEFT JOIN mart.product_unit_cost uc USING (offer_id)
GROUP BY a.offer_id, pr.name, uc.unit_cost_kzt;

-- ---------------------------------------------------------------------
-- 4. Продажи по дням (для графика динамики)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.sales_daily AS
SELECT
    p.created_at::date                                              AS order_date,
    COUNT(DISTINCT p.posting_number)                                AS postings,
    COUNT(DISTINCT p.posting_number) FILTER (WHERE p.status = 'cancelled') AS cancelled,
    SUM(i.quantity)                                                 AS units,
    ROUND(SUM(i.quantity * i.price * mart.fx(p.created_at::date, i.currency)), 0) AS gmv_kzt
FROM core.postings p
JOIN core.posting_items i USING (posting_number)
GROUP BY 1;

-- ---------------------------------------------------------------------
-- 5. Производство: брак и загрузка принтеров
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.production_stats AS
SELECT
    date_trunc('week', b.print_date)::date          AS week,
    pr.nickname                                     AS printer,
    SUM(b.qty_ok)                                   AS qty_ok,
    SUM(b.qty_defect)                               AS qty_defect,
    ROUND(100.0 * SUM(b.qty_defect) / NULLIF(SUM(b.qty_ok + b.qty_defect),0), 1) AS defect_pct,
    ROUND(SUM(b.print_time_min) / 60.0, 1)          AS print_hours,
    ROUND(SUM(b.filament_g) / 1000, 2)              AS filament_kg
FROM core.production_batches b
JOIN core.printers pr USING (printer_id)
GROUP BY 1, 2;
