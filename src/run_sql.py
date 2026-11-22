"""Выполнить один или несколько SQL-файлов в базе ozon_dwh.

    python src/run_sql.py sql/transform/products_from_postings.sql
"""
import sys

from db import ROOT, connect


def run(conn, *files):
    with conn.cursor() as cur:
        for f in files:
            cur.execute((ROOT / f).read_text(encoding="utf-8"))
            print(f"OK: {f}")
    conn.commit()


if __name__ == "__main__":
    conn = connect()
    try:
        run(conn, *sys.argv[1:])
    finally:
        conn.close()
