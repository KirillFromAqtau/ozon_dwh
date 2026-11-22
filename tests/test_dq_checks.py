from dq_checks import run_checks


def statuses(conn):
    return {name: status for name, _, status in run_checks(conn)}


def test_clean_data_has_no_failures(load_postings, run_sql, conn):
    load_postings()
    run_sql("sql/transform/fbs_postings.sql")
    assert "FAIL" not in statuses(conn).values()


def test_unparsed_is_critical(conn):
    with conn.cursor() as cur:
        cur.execute("""INSERT INTO core.accruals (accrual_id, operation_date, accrual_type, accrual_group, amount)
                       VALUES ('x:unparsed', '2026-11-01', 'Unparsed', 'other', -1)""")
    conn.commit()
    assert statuses(conn)["Неразобранные начисления (Unparsed)"] == "FAIL"


def test_posting_without_items_is_critical(conn):
    with conn.cursor() as cur:
        cur.execute("INSERT INTO core.postings (posting_number, scheme, status) VALUES ('x', 'FBS', 'delivered')")
    conn.commit()
    assert statuses(conn)["Отправления без товаров"] == "FAIL"
