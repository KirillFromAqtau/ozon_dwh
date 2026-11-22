"""Применить схему базы: таблицы, миграции, витрины.

    python src/migrate.py

Порядок:
    1. sql/schema/01_schema.sql   — базовые таблицы raw/core/mart
    2. sql/migrations/*.sql       — изменения схемы, по номеру
    3. sql/schema/02_marts.sql    — витрины (последними: им нужны все колонки)

Все файлы идемпотентны (IF NOT EXISTS, CREATE OR REPLACE), поэтому
скрипт безопасно запускать на новой и на уже рабочей базе.
Всё выполняется в одной транзакции: либо схема применилась целиком, либо никак.
"""
from db import ROOT, connect


def schema_files():
    return (
        [ROOT / "sql/schema/01_schema.sql"]
        + sorted((ROOT / "sql/migrations").glob("*.sql"))
        + [ROOT / "sql/schema/02_marts.sql"]
    )


def apply(conn):
    with conn.cursor() as cur:
        for f in schema_files():
            cur.execute(f.read_text(encoding="utf-8"))
            print(f"OK: {f.relative_to(ROOT)}")
    conn.commit()


if __name__ == "__main__":
    conn = connect()
    try:
        apply(conn)
    finally:
        conn.close()
