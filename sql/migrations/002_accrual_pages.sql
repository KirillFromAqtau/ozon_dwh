-- Миграция 002: сырые страницы ответа /v1/finance/accrual/by-day.
-- Новый API отдаёт начисления по дням, поэтому храним "день + номер страницы".
-- При повторной загрузке дня старые страницы удаляются и пишутся заново.
CREATE TABLE IF NOT EXISTS raw.ozon_accrual_pages (
    accrual_date  DATE        NOT NULL,
    page_no       INT         NOT NULL,
    payload       JSONB       NOT NULL,
    loaded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (accrual_date, page_no)
);
