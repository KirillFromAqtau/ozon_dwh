-- Тестовые данные, чтобы увидеть, как работают витрины.
-- Цифры выдуманные! Перед боевым запуском таблицы core.* очистить.

INSERT INTO core.materials (name, color, brand) VALUES ('PETG','Чёрный','Generic');

INSERT INTO core.material_purchases (material_id, purchase_date, weight_kg, total_cost)
VALUES (1, '2026-11-01', 5, 24000);                -- 4800 ₸/кг

INSERT INTO core.printers (model, nickname, purchase_price, avg_power_w) VALUES
 ('Bambu Lab P1S','P1S', 350000, 110),
 ('Bambu Lab A1','A1-1', 180000, 95),
 ('Bambu Lab A1','A1-2', 180000, 95);

INSERT INTO core.cost_settings (setting_key, valid_from, value) VALUES
 ('electricity_per_kwh','2026-01-01', 25),
 ('packaging_per_unit', '2026-01-01', 60);

INSERT INTO core.products (offer_id, name, category, material_id, filament_g, print_time_min) VALUES
 ('SPONGE-01','Держатель для губки','Кухня',1, 38, 75),
 ('CANDLE-01','Подсвечник декоративный','Декор',1, 95, 210);

INSERT INTO core.fx_rates VALUES ('2026-11-01','RUB','KZT', 6.45);

INSERT INTO core.postings (posting_number, scheme, status, created_at) VALUES
 ('0001-1','FBS','delivered','2026-11-10 12:00+05'),
 ('0002-1','FBS','delivered','2026-11-11 09:30+05'),
 ('0003-1','FBS','cancelled','2026-11-12 18:10+05');

INSERT INTO core.posting_items VALUES
 ('0001-1','SPONGE-01',NULL,1,390,'RUB'),
 ('0002-1','CANDLE-01',NULL,1,790,'RUB'),
 ('0003-1','SPONGE-01',NULL,1,390,'RUB');

INSERT INTO core.accrual_type_map VALUES
 ('MarketplaceSellerReexposureDeliveryReturnOperation','returns'),
 ('SaleRevenue','revenue'), ('SaleCommission','commission'), ('DirectFlowLogistic','logistics');

INSERT INTO core.accruals (accrual_id, operation_date, posting_number, accrual_type, amount) VALUES
 ('a1','2026-11-14','0001-1','SaleRevenue',     390),
 ('a2','2026-11-14','0001-1','SaleCommission',  -78),
 ('a3','2026-11-14','0001-1','DirectFlowLogistic',-63),
 ('a4','2026-11-15','0002-1','SaleRevenue',     790),
 ('a5','2026-11-15','0002-1','SaleCommission', -158),
 ('a6','2026-11-15','0002-1','DirectFlowLogistic',-76);

INSERT INTO core.production_batches (print_date, printer_id, offer_id, qty_ok, qty_defect, filament_g, print_time_min)
VALUES ('2026-11-09',2,'SPONGE-01',8,1,340,640),
       ('2026-11-09',1,'CANDLE-01',4,0,385,830);
