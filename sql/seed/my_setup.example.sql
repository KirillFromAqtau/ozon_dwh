-- =====================================================================
--  ОБРАЗЕЦ справочников производства (цифры примерные).
-- =====================================================================

-- 1. Материалы
INSERT INTO core.materials (name, color, brand) VALUES
    ('PETG', 'Чёрный', 'Generic'),
    ('PETG', 'Белый',  'Generic')
ON CONFLICT (name, color, brand) DO NOTHING;

-- 2. Закупки пластика. Файл = источник правды:
--    таблица очищается и заливается заново при каждом запуске.
TRUNCATE core.material_purchases RESTART IDENTITY;

INSERT INTO core.material_purchases (material_id, purchase_date, weight_kg, total_cost)
SELECT m.material_id, v.d::date, v.kg, v.cost
FROM (VALUES
    -- (цвет,     дата,         кг, стоимость ₸)
    ('Чёрный', '2026-10-01', 5, 20000),
    ('Белый',  '2026-10-01', 5, 20000)
) AS v(color, d, kg, cost)
JOIN core.materials m ON m.name = 'PETG' AND m.color = v.color;

-- 3. Принтеры: цена покупки (₸), средняя мощность при печати (Вт),
--    expected_life_h — за сколько часов работы принтер «окупается»
INSERT INTO core.printers (model, nickname, purchase_price, avg_power_w, expected_life_h) VALUES
    ('Bambu Lab P1S', 'P1S',  300000, 140, 10000),
    ('Bambu Lab A1',  'A1-1', 200000, 100, 10000)
ON CONFLICT (nickname) DO UPDATE SET
    purchase_price = EXCLUDED.purchase_price,
    avg_power_w    = EXCLUDED.avg_power_w;

-- 4. Прочие ставки
INSERT INTO core.cost_settings (setting_key, valid_from, value) VALUES
    ('electricity_per_kwh', '2026-01-01', 25),   -- ₸ за кВт·ч
    ('packaging_per_unit',  '2026-01-01', 60)    -- упаковка на 1 шт, ₸
ON CONFLICT (setting_key, valid_from) DO UPDATE SET value = EXCLUDED.value;
