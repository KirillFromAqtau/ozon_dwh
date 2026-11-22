-- Миграция 003: начисления под новый API /v1/finance/accrual/by-day

-- Справочник типов начислений Ozon (139 штук) + наша группировка
CREATE TABLE IF NOT EXISTS raw.ozon_accrual_types (
    loaded_at  TIMESTAMPTZ PRIMARY KEY DEFAULT now(),
    payload    JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS core.accrual_types (
    type_id        INT PRIMARY KEY,
    name           TEXT NOT NULL,        -- 'Logistic'
    description    TEXT,                 -- 'Логистика'
    accrual_group  TEXT NOT NULL         -- revenue / commission / logistics / ...
);

-- Новые колонки в core.accruals
ALTER TABLE core.accruals
    ADD COLUMN IF NOT EXISTS ozon_accrual_id   BIGINT,   -- исходный accrual_id из API
    ADD COLUMN IF NOT EXISTS accrued_category  TEXT,     -- POSTING / NON_ITEM / ...
    ADD COLUMN IF NOT EXISTS unit_number       TEXT,     -- как пришло (обычно номер отправления)
    ADD COLUMN IF NOT EXISTS type_id           INT,
    ADD COLUMN IF NOT EXISTS ozon_sku          BIGINT,
    ALTER COLUMN currency SET DEFAULT 'KZT';

CREATE INDEX IF NOT EXISTS ix_accruals_ozon_id ON core.accruals (ozon_accrual_id);
