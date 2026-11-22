"""Разбор raw.ozon_postings_fbs → core.postings / core.posting_items."""
TRANSFORM = "sql/transform/fbs_postings.sql"


def test_postings_loaded(load_postings, run_sql, query):
    load_postings()
    run_sql(TRANSFORM)
    rows = dict(query("SELECT posting_number, status FROM core.postings"))
    assert rows == {
        "11111111-0001-1": "delivered",
        "22222222-0001-1": "cancelled",
        "33333333-0001-1": "awaiting_deliver",
    }


def test_price_as_object_and_as_string(load_postings, run_sql, query):
    """v4 отдаёт цену объектом {amount, currency}, старые ответы — строкой."""
    load_postings()
    run_sql(TRANSFORM)
    prices = {(r[0], r[1]): (float(r[2]), r[3]) for r in query(
        "SELECT posting_number, offer_id, price, currency FROM core.posting_items")}
    assert prices[("11111111-0001-1", "TEST_HOLDER")] == (1500.0, "KZT")   # объект
    assert prices[("22222222-0001-1", "TEST_CLIP")] == (800.0, "KZT")      # строка


def test_customer_price_from_financial_data(load_postings, run_sql, query):
    load_postings()
    run_sql(TRANSFORM)
    (price, cur), = query("""SELECT customer_price, customer_currency FROM core.posting_items
                             WHERE posting_number = '11111111-0001-1'""")
    assert (float(price), cur) == (320.5, "RUB")


def test_dates_and_cancellation(load_postings, run_sql, query):
    load_postings()
    run_sql(TRANSFORM)
    rows = {r[0]: r[1:] for r in query("""
        SELECT posting_number, shipped_at IS NOT NULL, cancel_reason, cancel_initiator, cluster_to
        FROM core.postings""")}
    # delivering_date → shipped_at; пустая строка → NULL, а не ошибка
    assert rows["11111111-0001-1"][0] is True
    assert rows["22222222-0001-1"][0] is False
    assert rows["22222222-0001-1"][1:3] == ("Покупатель отменил", "Клиент")
    assert rows["11111111-0001-1"][1] is None            # пустая причина → NULL
    assert rows["11111111-0001-1"][3] == "Москва, МО и Дальние регионы"


def test_multiple_products_in_one_posting(load_postings, run_sql, query):
    load_postings()
    run_sql(TRANSFORM)
    items = dict(query("""SELECT offer_id, quantity FROM core.posting_items
                          WHERE posting_number = '33333333-0001-1'"""))
    assert items == {"TEST_CLIP": 2, "TEST_HOLDER": 1}


def test_transform_is_idempotent(load_postings, run_sql, query):
    load_postings()
    run_sql(TRANSFORM)
    run_sql(TRANSFORM)
    assert query("SELECT count(*) FROM core.postings") == [(3,)]
    assert query("SELECT count(*) FROM core.posting_items") == [(4,)]


def test_status_update_on_reload(load_postings, run_sql, query):
    """Повторная загрузка того же отправления обновляет статус (upsert), а не дублирует."""
    postings = load_postings()
    run_sql(TRANSFORM)
    postings[2]["status"] = "delivering"
    load_postings(postings)
    run_sql(TRANSFORM)
    assert query("SELECT status FROM core.postings WHERE posting_number='33333333-0001-1'") == [("delivering",)]
    assert query("SELECT count(*) FROM core.postings") == [(3,)]
