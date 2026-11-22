"""
Общие фикстуры pytest.

Тесты работают с НАСТОЯЩИМ PostgreSQL: схема пересоздаётся с нуля,
поэтому имя базы обязано заканчиваться на "_test" — защита от
случайного запуска тестов на боевой базе ozon_dwh.

Локально:  PG_DB=ozon_test pytest
В CI:      переменные задаёт .github/workflows/ci.yml
"""
import json
import os
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture(scope="session")
def _session_conn():
    """Одно подключение на весь прогон + чистая схема."""
    from db import connect
    from migrate import apply

    db_name = os.getenv("PG_DB", "")
    if not db_name.endswith("_test"):
        pytest.exit(f"PG_DB='{db_name}': тесты запускаются только на базе с суффиксом _test", returncode=2)

    c = connect()
    with c.cursor() as cur:                       # чистая схема перед прогоном
        cur.execute("DROP SCHEMA IF EXISTS mart, core, raw CASCADE")
    c.commit()
    apply(c)                                      # та же миграция, что и в проде
    yield c
    c.close()


@pytest.fixture
def conn(_session_conn):
    """Подключение для теста: перед каждым тестом — пустые таблицы, счётчики SERIAL с 1.
    Тесты без базы (например, проверка DAG) эту фикстуру не запрашивают и к БД не ходят."""
    conn = _session_conn
    with conn.cursor() as cur:
        cur.execute("""
            SELECT string_agg(format('%I.%I', schemaname, tablename), ', ')
            FROM pg_tables WHERE schemaname IN ('raw', 'core')""")
        tables = cur.fetchone()[0]
        cur.execute(f"TRUNCATE {tables} RESTART IDENTITY CASCADE")
    conn.commit()
    yield conn
    conn.rollback()


def load_json(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


@pytest.fixture
def run_sql(conn):
    """Выполнить SQL-файл проекта, как это делает DAG."""
    from run_sql import run

    def _run(*files):
        run(conn, *files)
    return _run


@pytest.fixture
def query(conn):
    def _query(sql, params=None):
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    return _query


@pytest.fixture
def load_postings(conn):
    """Положить отправления из фикстуры в raw — как это делает загрузчик."""
    from psycopg2.extras import Json

    def _load(postings=None):
        postings = postings if postings is not None else load_json("fbs_postings.json")
        with conn.cursor() as cur:
            for p in postings:
                cur.execute("""
                    INSERT INTO raw.ozon_postings_fbs (source_id, payload) VALUES (%s, %s)
                    ON CONFLICT (source_id) DO UPDATE SET payload = EXCLUDED.payload""",
                            (p["posting_number"], Json(p)))
        conn.commit()
        return postings
    return _load


@pytest.fixture
def load_accruals(conn):
    from psycopg2.extras import Json

    def _load(page=None, types=None):
        page = page or load_json("accrual_page.json")
        types = types or load_json("accrual_types.json")
        with conn.cursor() as cur:
            cur.execute("INSERT INTO raw.ozon_accrual_types (payload) VALUES (%s)", (Json(types),))
            cur.execute("""INSERT INTO raw.ozon_accrual_pages (accrual_date, page_no, payload)
                           VALUES ('2026-11-10', 1, %s)""", (Json(page),))
        conn.commit()
        return page
    return _load
