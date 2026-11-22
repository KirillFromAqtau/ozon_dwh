"""Выполнить один или несколько SQL-файлов в базе ozon_dwh.
    python src/run_sql.py sql/transform/products_from_postings.sql
"""
import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

conn = psycopg2.connect(host=os.getenv("PG_HOST", "localhost"), port=os.getenv("PG_PORT", "5432"),
                        dbname=os.getenv("PG_DB", "ozon_dwh"), user=os.environ["PG_USER"],
                        password=os.environ["PG_PASSWORD"])
with conn, conn.cursor() as cur:            # with conn → commit или rollback автоматически
    for f in sys.argv[1:]:
        cur.execute((ROOT / f).read_text(encoding="utf-8"))
        print(f"OK: {f}")
conn.close()
