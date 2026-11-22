from migrate import apply


def test_migrate_is_idempotent(conn, query):
    """Повторное применение схемы не падает и ничего не ломает."""
    apply(conn)
    apply(conn)
    schemas = {r[0] for r in query(
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name IN ('raw','core','mart')")}
    assert schemas == {"raw", "core", "mart"}


def test_migrations_added_columns(query):
    cols = {r[0] for r in query(
        "SELECT column_name FROM information_schema.columns WHERE table_schema='core' AND table_name='accruals'")}
    assert {"ozon_accrual_id", "accrued_category", "type_id", "ozon_sku"} <= cols
