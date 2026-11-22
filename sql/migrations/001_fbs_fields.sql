-- Миграция 001: поля, найденные в реальном ответе /v4/posting/fbs/list
-- IF NOT EXISTS — можно запускать повторно без ошибок.
ALTER TABLE core.postings
    ADD COLUMN IF NOT EXISTS substatus          TEXT,         -- posting_on_way_to_city и т.п.
    ADD COLUMN IF NOT EXISTS shipment_deadline  TIMESTAMPTZ,  -- до какого времени нужно отгрузить
    ADD COLUMN IF NOT EXISTS delivery_type      TEXT,         -- PVZ / Courier / ...
    ADD COLUMN IF NOT EXISTS cluster_to         TEXT,         -- куда едет: 'Москва, МО и Дальние регионы'
    ADD COLUMN IF NOT EXISTS cancel_initiator   TEXT;         -- 'Клиент' / 'Продавец' / 'Ozon'

ALTER TABLE core.posting_items
    ADD COLUMN IF NOT EXISTS customer_price     NUMERIC(12,2), -- сколько заплатил покупатель
    ADD COLUMN IF NOT EXISTS customer_currency  CHAR(3),       -- обычно RUB
    ALTER COLUMN currency SET DEFAULT 'KZT';

COMMENT ON COLUMN core.postings.shipped_at   IS 'delivering_date: когда отправление передано в доставку';
COMMENT ON COLUMN core.postings.delivered_at IS 'пока не заполняется: в списке отправлений нет даты вручения, возьмём из финансов';
