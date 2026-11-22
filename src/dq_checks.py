"""
Проверки качества данных (Data Quality) после загрузки.
Если критичная проверка не прошла — скрипт завершается с кодом 1,
и задача в Airflow становится красной (failed). Так ты узнаешь о проблеме сразу.

    python src/dq_checks.py
"""
import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

# (название, SQL, который возвращает ЧИСЛО ПРОБЛЕМ, критичная ли проверка)
CHECKS = [
    ("Неразобранные начисления (Unparsed)",
     "SELECT count(*) FROM core.accruals WHERE accrual_type = 'Unparsed'", True),
    ("Отправления без товаров",
     """SELECT count(*) FROM core.postings p
        WHERE NOT EXISTS (SELECT 1 FROM core.posting_items i WHERE i.posting_number = p.posting_number)""", True),
    ("Нет новых отправлений за 3 дня (подозрительно)",
     "SELECT CASE WHEN max(created_at) < now() - interval '3 days' THEN 1 ELSE 0 END FROM core.postings", False),
    ("Проданные товары без себестоимости",
     """SELECT count(DISTINCT i.offer_id) FROM core.posting_items i
        LEFT JOIN core.products p USING (offer_id)
        WHERE p.filament_g IS NULL OR p.print_time_min IS NULL""", False),
    ("Новые типы начислений вне групп (other)",
     "SELECT count(*) FROM core.accruals WHERE accrual_group = 'other' AND accrual_type <> 'Unparsed'", False),
]

conn = psycopg2.connect(host=os.getenv("PG_HOST", "localhost"), port=os.getenv("PG_PORT", "5432"),
                        dbname=os.getenv("PG_DB", "ozon_dwh"), user=os.environ["PG_USER"],
                        password=os.environ["PG_PASSWORD"])
failed = False
with conn.cursor() as cur:
    for name, sql, critical in CHECKS:
        cur.execute(sql)
        problems = cur.fetchone()[0] or 0
        if problems == 0:
            status = "OK  "
        elif critical:
            status, failed = "FAIL", True
        else:
            status = "WARN"
        print(f"[{status}] {name}: {problems}")
conn.close()

sys.exit(1 if failed else 0)
