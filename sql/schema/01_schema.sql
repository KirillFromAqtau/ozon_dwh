-- =====================================================================
--  OZON SHOP DWH — схема базы данных (PostgreSQL 16)
--  Магазин 3D-печатных товаров, схема работы FBS (+ возвраты на FBO)
--
--  Три слоя:
--    raw   — сырые ответы API Ozon "как есть" (JSONB). Ничего не правим.
--    core  — чистые нормализованные таблицы: товары, заказы, деньги,
--            производство. Главный слой, с ним работаем.
--    mart  — витрины (VIEW) под дашборды: прибыль, юнит-экономика и т.д.
--
--  Зачем raw? Если завтра поменяется логика парсинга — перегружаем core
--  из raw, не дёргая API заново. Классика ELT.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS mart;

-- =====================================================================
--  RAW: один шаблон на каждый метод API
-- =====================================================================
-- Каждая строка = один объект из ответа API (одно отправление,
-- одно начисление...). payload хранит JSON целиком.
-- source_id — естественный ключ объекта (номер отправления и т.п.),
-- по нему делаем upsert, чтобы повторная загрузка не плодила дубли.

CREATE TABLE IF NOT EXISTS raw.ozon_postings_fbs (
    source_id   TEXT PRIMARY KEY,            -- posting_number
    payload     JSONB       NOT NULL,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.ozon_postings_fbo (
    source_id   TEXT PRIMARY KEY,
    payload     JSONB       NOT NULL,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.ozon_accruals (    -- финансовые начисления
    source_id   TEXT PRIMARY KEY,
    payload     JSONB       NOT NULL,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.ozon_returns (
    source_id   TEXT PRIMARY KEY,
    payload     JSONB       NOT NULL,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.ozon_products (
    source_id   TEXT PRIMARY KEY,            -- offer_id
    payload     JSONB       NOT NULL,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.ozon_stocks (       -- снимок остатков
    source_id   TEXT,                        -- offer_id
    snapshot_date DATE      NOT NULL,
    payload     JSONB       NOT NULL,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_id, snapshot_date)
);

-- =====================================================================
--  CORE: справочники производства (заполняешь сам)
-- =====================================================================

-- Материалы: PETG чёрный, PETG белый, PLA...
CREATE TABLE IF NOT EXISTS core.materials (
    material_id   SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,             -- 'PETG'
    color         TEXT,                      -- 'Чёрный'
    brand         TEXT,                      -- 'Generic'
    UNIQUE (name, color, brand)
);

-- Закупки пластика. Цена за кг считается сама (GENERATED-колонка).
CREATE TABLE IF NOT EXISTS core.material_purchases (
    purchase_id     SERIAL PRIMARY KEY,
    material_id     INT  NOT NULL REFERENCES core.materials,
    purchase_date   DATE NOT NULL,
    weight_kg       NUMERIC(8,3)  NOT NULL CHECK (weight_kg > 0),
    total_cost      NUMERIC(12,2) NOT NULL CHECK (total_cost >= 0),
    currency        CHAR(3) NOT NULL DEFAULT 'KZT',
    price_per_kg    NUMERIC(12,2) GENERATED ALWAYS AS (total_cost / weight_kg) STORED
);

-- Принтеры: нужны для амортизации и расчёта электричества.
CREATE TABLE IF NOT EXISTS core.printers (
    printer_id      SERIAL PRIMARY KEY,
    model           TEXT NOT NULL,           -- 'Bambu Lab P1S'
    nickname        TEXT UNIQUE,             -- 'P1S', 'A1-1', 'A1-2'
    purchase_date   DATE,
    purchase_price  NUMERIC(12,2),
    currency        CHAR(3) DEFAULT 'KZT',
    avg_power_w     INT,                     -- средняя мощность при печати
    expected_life_h INT DEFAULT 10000,       -- за сколько часов "окупаем" принтер
    is_active       BOOLEAN DEFAULT TRUE
);

-- Прочие настройки себестоимости, меняющиеся во времени
-- (тариф на электричество, стоимость упаковки за штуку).
-- valid_from — с какой даты действует значение (SCD-подход "по датам").
CREATE TABLE IF NOT EXISTS core.cost_settings (
    setting_key  TEXT NOT NULL,              -- 'electricity_per_kwh', 'packaging_per_unit'
    valid_from   DATE NOT NULL,
    value        NUMERIC(12,4) NOT NULL,
    currency     CHAR(3) DEFAULT 'KZT',
    PRIMARY KEY (setting_key, valid_from)
);

-- =====================================================================
--  CORE: товары
-- =====================================================================
-- offer_id — ТВОЙ артикул (ты его задаёшь в карточке Ozon).
-- Это главный ключ, связывающий производство и продажи.
CREATE TABLE IF NOT EXISTS core.products (
    offer_id          TEXT PRIMARY KEY,      -- 'CLIP-BAG-01'
    ozon_product_id   BIGINT UNIQUE,         -- product_id в Ozon
    ozon_sku          BIGINT UNIQUE,         -- sku в Ozon
    name              TEXT NOT NULL,
    category          TEXT,                  -- 'Кухня', 'Декор'...
    material_id       INT REFERENCES core.materials,
    -- нормативы на 1 штуку (из слайсера Bambu Studio):
    filament_g        NUMERIC(8,2),          -- вес пластика вкл. поддержки
    print_time_min    INT,                   -- время печати 1 шт
    units_per_pack    INT DEFAULT 1,         -- например "набор из 2 крючков"
    is_active         BOOLEAN DEFAULT TRUE,
    created_at        TIMESTAMPTZ DEFAULT now()
);

-- =====================================================================
--  CORE: производство (журнал печати, ведёшь вручную)
-- =====================================================================
-- Одна строка = одна партия на столе принтера.
CREATE TABLE IF NOT EXISTS core.production_batches (
    batch_id        SERIAL PRIMARY KEY,
    print_date      DATE NOT NULL,
    printer_id      INT  NOT NULL REFERENCES core.printers,
    offer_id        TEXT NOT NULL REFERENCES core.products,
    material_id     INT  REFERENCES core.materials,
    qty_ok          INT  NOT NULL DEFAULT 0 CHECK (qty_ok >= 0),
    qty_defect      INT  NOT NULL DEFAULT 0 CHECK (qty_defect >= 0),
    filament_g      NUMERIC(10,2),           -- факт. расход на всю партию
    print_time_min  INT,                     -- факт. время всей партии
    comment         TEXT
);

-- =====================================================================
--  CORE: заказы (отправления) и их состав
-- =====================================================================
-- posting_number — номер отправления Ozon. Один заказ покупателя может
-- распасться на несколько отправлений, поэтому считаем именно их.
CREATE TABLE IF NOT EXISTS core.postings (
    posting_number   TEXT PRIMARY KEY,
    order_number     TEXT,
    scheme           TEXT NOT NULL CHECK (scheme IN ('FBS','FBO')),
    status           TEXT NOT NULL,          -- delivered, cancelled, ...
    created_at       TIMESTAMPTZ,            -- когда покупатель оформил
    shipped_at       TIMESTAMPTZ,            -- когда ты отгрузил
    delivered_at     TIMESTAMPTZ,
    cancel_reason    TEXT,
    region           TEXT,                   -- если есть в analytics_data
    updated_at       TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.posting_items (
    posting_number   TEXT NOT NULL REFERENCES core.postings ON DELETE CASCADE,
    offer_id         TEXT NOT NULL,          -- без FK: товар мог быть удалён
    ozon_sku         BIGINT,
    quantity         INT  NOT NULL CHECK (quantity > 0),
    price            NUMERIC(12,2),          -- цена для покупателя
    currency         CHAR(3) DEFAULT 'RUB',
    PRIMARY KEY (posting_number, offer_id)
);

-- =====================================================================
--  CORE: деньги от Ozon
-- =====================================================================
-- Каждое начисление/списание: выручка, комиссия, логистика, эквайринг,
-- хранение на FBO, штрафы. Знак: + деньги тебе, − списание.
-- posting_number может быть NULL (хранение, подписка, реклама).
CREATE TABLE IF NOT EXISTS core.accruals (
    accrual_id       TEXT PRIMARY KEY,
    operation_date   DATE NOT NULL,
    posting_number   TEXT,
    offer_id         TEXT,
    accrual_type     TEXT NOT NULL,          -- как пришло из API
    accrual_group    TEXT,                   -- наша группировка, см. ниже
    amount           NUMERIC(12,2) NOT NULL,
    currency         CHAR(3) DEFAULT 'RUB'
);

-- Маппинг сырых типов начислений Ozon в понятные группы.
-- Заполняется один раз, дополняется по мере появления новых типов.
CREATE TABLE IF NOT EXISTS core.accrual_type_map (
    accrual_type    TEXT PRIMARY KEY,
    accrual_group   TEXT NOT NULL CHECK (accrual_group IN
        ('revenue','commission','logistics','last_mile','acquiring',
         'returns','storage','ads','penalty','other'))
);

-- =====================================================================
--  CORE: возвраты и остатки
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.returns (
    return_id        TEXT PRIMARY KEY,
    posting_number   TEXT,
    offer_id         TEXT,
    quantity         INT DEFAULT 1,
    return_type      TEXT,       -- 'cancellation' (отказ на ПВЗ) / 'client_return'
    reason           TEXT,
    returned_at      TIMESTAMPTZ,
    destination      TEXT CHECK (destination IN ('FBO','SELLER','UTILIZED', NULL))
);

-- Ежедневный снимок остатков. Отдельно по FBS (твой склад)
-- и FBO (то, что осело на складе Ozon после отказов).
CREATE TABLE IF NOT EXISTS core.stock_snapshots (
    snapshot_date    DATE NOT NULL,
    offer_id         TEXT NOT NULL,
    warehouse_type   TEXT NOT NULL CHECK (warehouse_type IN ('FBS','FBO')),
    qty_available    INT NOT NULL DEFAULT 0,
    qty_reserved     INT NOT NULL DEFAULT 0,
    PRIMARY KEY (snapshot_date, offer_id, warehouse_type)
);

-- =====================================================================
--  CORE: прочие расходы и курсы валют
-- =====================================================================
-- Всё, что не приходит из API: упаковка, сопла, смазка, доставка
-- пластика, реклама вне Ozon.
CREATE TABLE IF NOT EXISTS core.other_expenses (
    expense_id    SERIAL PRIMARY KEY,
    expense_date  DATE NOT NULL,
    category      TEXT NOT NULL,             -- 'packaging','spare_parts','ads'...
    description   TEXT,
    amount        NUMERIC(12,2) NOT NULL,
    currency      CHAR(3) NOT NULL DEFAULT 'KZT'
);

-- Ozon считает в рублях, расходы у тебя в тенге.
-- Сюда можно грузить курс из твоего Currency ETL Pipeline :)
CREATE TABLE IF NOT EXISTS core.fx_rates (
    rate_date     DATE    NOT NULL,
    currency_from CHAR(3) NOT NULL,          -- 'RUB'
    currency_to   CHAR(3) NOT NULL,          -- 'KZT'
    rate          NUMERIC(14,6) NOT NULL,    -- 1 RUB = rate KZT
    PRIMARY KEY (rate_date, currency_from, currency_to)
);

-- Индексы под типовые запросы витрин
CREATE INDEX IF NOT EXISTS ix_postings_created   ON core.postings (created_at);
CREATE INDEX IF NOT EXISTS ix_accruals_date      ON core.accruals (operation_date);
CREATE INDEX IF NOT EXISTS ix_accruals_posting   ON core.accruals (posting_number);
CREATE INDEX IF NOT EXISTS ix_batches_offer_date ON core.production_batches (offer_id, print_date);
