"""
Проверки качества данных (Data Quality) после загрузки.
Если критичная проверка не прошла — скрипт завершается с кодом 1,
и задача в Airflow становится красной (failed).

    python src/dq_checks.py
"""
import sys

from db import connect

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


def run_checks(conn):
    """Возвращает список (название, число проблем, статус: OK / WARN / FAIL)."""
    results = []
    with conn.cursor() as cur:
        for name, sql, critical in CHECKS:
            cur.execute(sql)
            problems = cur.fetchone()[0] or 0
            status = "OK" if problems == 0 else ("FAIL" if critical else "WARN")
            results.append((name, problems, status))
    return results


def main():
    conn = connect()
    try:
        results = run_checks(conn)
    finally:
        conn.close()
    for name, problems, status in results:
        print(f"[{status:<4}] {name}: {problems}")
    return 1 if any(s == "FAIL" for _, _, s in results) else 0


if __name__ == "__main__":
    sys.exit(main())
