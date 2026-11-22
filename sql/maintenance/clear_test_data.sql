-- Удаляет ВСЕ тестовые данные из core и raw (структура таблиц остаётся).
-- RESTART IDENTITY — счётчики SERIAL снова начнутся с 1.
TRUNCATE core.posting_items, core.postings, core.accruals, core.accrual_type_map,
         core.returns, core.stock_snapshots, core.production_batches,
         core.products, core.material_purchases, core.materials, core.printers,
         core.cost_settings, core.other_expenses, core.fx_rates,
         raw.ozon_postings_fbs, raw.ozon_postings_fbo, raw.ozon_accruals,
         raw.ozon_returns, raw.ozon_products, raw.ozon_stocks
RESTART IDENTITY CASCADE;
