"""
Загрузчик финансовых начислений Ozon (новый API с сентября 2026):
    POST /v1/finance/accrual/by-day   — начисления за ОДИН день, пагинация по last_id
    POST /v1/finance/accrual/types    — справочник типов начислений

Схема: API -> raw.ozon_accrual_pages (страницы как есть) -> sql/transform/accruals.sql -> core.accruals

Запуск:
    python src/load_accruals.py --days 7 --dump    # сохранить в data/ и посмотреть глазами
    python src/load_accruals.py --days 180         # загрузить в raw.ozon_accrual_pages
"""

import argparse
import json
import os
import time
from datetime import date, timedelta

import requests
from psycopg2.extras import Json

from db import ROOT, connect  # общее подключение к БД (+ чтение .env)

BASE = "https://api-seller.ozon.ru"
HEADERS = {
    "Client-Id": os.environ["OZON_CLIENT_ID"],
    "Api-Key": os.environ["OZON_API_KEY"],
    "Content-Type": "application/json",
}




def post(path: str, body: dict, retries: int = 4) -> dict:
    for attempt in range(1, retries + 1):
        resp = requests.post(BASE + path, headers=HEADERS, json=body, timeout=60)
        if resp.status_code == 200:
            return resp.json()
        if resp.status_code in (429, 500, 502, 503, 504) and attempt < retries:
            wait = 2 ** attempt
            print(f"  HTTP {resp.status_code}, повтор через {wait} с...")
            time.sleep(wait)
            continue
        raise RuntimeError(f"{path} → {resp.status_code}: {resp.text[:500]}")


def fetch_day(day: date) -> list[dict]:
    """Все страницы ответа за один день."""
    pages, last_id = [], ""
    while True:
        body = {"date": day.isoformat()}
        if last_id:
            body["last_id"] = last_id
        data = post("/v1/finance/accrual/by-day", body)
        pages.append(data)

        rows = data.get("accruals") or data.get("result", {}).get("accruals") or []
        new_last_id = data.get("last_id") or ""
        # Конец: строк нет, курсор пустой или не сдвинулся, либо явно has_next=false
        if not rows or not new_last_id or new_last_id == last_id or data.get("has_next") is False:
            return pages
        last_id = new_last_id
        time.sleep(0.2)                       # бережём лимиты API


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--dump", action="store_true")
    args = ap.parse_args()

    # Сегодняшний день ещё не закрыт — берём до вчера включительно
    end = date.today() - timedelta(days=1)
    days = [end - timedelta(days=i) for i in range(args.days)][::-1]

    result = {}
    for d in days:
        pages = fetch_day(d)
        n = sum(len(p.get("accruals") or []) for p in pages)
        print(f"{d}: страниц {len(pages)}, строк {n}")
        result[d.isoformat()] = pages

    if args.dump:
        out_dir = ROOT / "data"
        out_dir.mkdir(exist_ok=True)
        (out_dir / "accruals_dump.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        types = post("/v1/finance/accrual/types", {})
        (out_dir / "accrual_types.json").write_text(
            json.dumps(types, ensure_ascii=False, indent=2), encoding="utf-8")
        print("Сохранено: data/accruals_dump.json и data/accrual_types.json")
        return

    types = post("/v1/finance/accrual/types", {})

    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute("INSERT INTO raw.ozon_accrual_types (payload) VALUES (%s)", (Json(types),))
            for d, pages in result.items():
                # перезаливаем день целиком: удалили старые страницы → записали новые
                cur.execute("DELETE FROM raw.ozon_accrual_pages WHERE accrual_date = %s", (d,))
                for i, page in enumerate(pages, start=1):
                    cur.execute(
                        "INSERT INTO raw.ozon_accrual_pages (accrual_date, page_no, payload) VALUES (%s, %s, %s)",
                        (d, i, Json(page)))
            # разбор raw -> core (в той же транзакции)
            cur.execute((ROOT / "sql" / "transform" / "accruals.sql").read_text(encoding="utf-8"))
        conn.commit()
        print(f"OK: загружено дней {len(result)}, core.accruals пересобран")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
