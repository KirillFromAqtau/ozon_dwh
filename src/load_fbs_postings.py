"""
Загрузчик FBS-отправлений Ozon:  API  ->  raw.ozon_postings_fbs  ->  core.postings / core.posting_items

Запуск:
    python src/load_fbs_postings.py --days 7          # последние 7 дней
    python src/load_fbs_postings.py --days 180        # первичная загрузка истории
    python src/load_fbs_postings.py --days 3 --dump   # сохранить сырой ответ в файл и посмотреть глазами

Схема ELT:
    E (extract)   — забираем JSON из API постранично
    L (load)      — кладём каждый posting целиком в raw (upsert по posting_number)
    T (transform) — SQL-скрипт sql/transform/fbs_postings.sql разбирает JSON в core
"""

import argparse
import json
import os
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2
import requests
from dotenv import load_dotenv
from psycopg2.extras import Json, execute_values

# --------------------------------------------------------------------------
# Настройки
# --------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")                    # читает OZON_CLIENT_ID, OZON_API_KEY, PG_*

API_URL = "https://api-seller.ozon.ru/v4/posting/fbs/list"
PAGE_LIMIT = 100          # v4 принимает максимум 100 за запрос
WINDOW_DAYS = 30          # большой период режем на куски по 30 дней

HEADERS = {
    "Client-Id": os.environ["OZON_CLIENT_ID"],
    "Api-Key": os.environ["OZON_API_KEY"],
    "Content-Type": "application/json",
}


def pg_connect():
    return psycopg2.connect(
        host=os.getenv("PG_HOST", "localhost"),
        port=os.getenv("PG_PORT", "5432"),
        dbname=os.getenv("PG_DB", "ozon_dwh"),
        user=os.environ["PG_USER"],
        password=os.environ["PG_PASSWORD"],
    )


# --------------------------------------------------------------------------
# EXTRACT
# --------------------------------------------------------------------------
def post_with_retry(body: dict, retries: int = 3) -> dict:
    """POST-запрос с повторами: на 429 (лимит запросов) и 5xx ждём и пробуем ещё."""
    for attempt in range(1, retries + 1):
        resp = requests.post(API_URL, headers=HEADERS, json=body, timeout=30)
        if resp.status_code == 200:
            return resp.json()
        if resp.status_code in (429, 500, 502, 503, 504) and attempt < retries:
            wait = 2 ** attempt                      # 2, 4, 8 секунд
            print(f"  HTTP {resp.status_code}, повтор через {wait} с...")
            time.sleep(wait)
            continue
        # 400/403 и т.п. — повтор не поможет, показываем текст ошибки Ozon
        raise RuntimeError(f"Ozon API {resp.status_code}: {resp.text}")


def fetch_window(since: datetime, to: datetime) -> list[dict]:
    """Все отправления за окно [since, to). Пагинация курсором."""
    postings, cursor, page = [], None, 0
    while True:
        body = {
            "filter": {
                "since": since.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "to": to.strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
            "limit": PAGE_LIMIT,
            "with": {"analytics_data": True, "financial_data": True},
        }
        if cursor:
            body["cursor"] = cursor

        data = post_with_retry(body)
        page += 1

        # В v4 postings лежат на верхнем уровне; на всякий случай поддержим и старый вид
        batch = data.get("postings") or data.get("result", {}).get("postings", [])
        postings.extend(batch)
        print(f"  стр. {page}: +{len(batch)} отправлений")

        cursor = data.get("cursor")
        if not data.get("has_next") or not cursor:
            return postings


def fetch_period(days: int) -> list[dict]:
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=days)
    result, win_start = [], start
    while win_start < end:
        win_end = min(win_start + timedelta(days=WINDOW_DAYS), end)
        print(f"Окно {win_start:%Y-%m-%d} → {win_end:%Y-%m-%d}")
        result.extend(fetch_window(win_start, win_end))
        win_start = win_end
    return result


# --------------------------------------------------------------------------
# LOAD (в raw)
# --------------------------------------------------------------------------
def load_raw(conn, postings: list[dict]) -> int:
    rows = [(p["posting_number"], Json(p)) for p in postings]
    if not rows:
        return 0
    with conn.cursor() as cur:
        # ON CONFLICT: если отправление уже есть — обновляем JSON
        # (статус мог смениться с delivering на delivered)
        execute_values(cur, """
            INSERT INTO raw.ozon_postings_fbs (source_id, payload)
            VALUES %s
            ON CONFLICT (source_id) DO UPDATE
               SET payload = EXCLUDED.payload,
                   loaded_at = now()
        """, rows)
    return len(rows)


# --------------------------------------------------------------------------
# TRANSFORM (raw -> core) — сам SQL лежит в отдельном файле
# --------------------------------------------------------------------------
def transform(conn):
    sql = (ROOT / "sql" / "transform" / "fbs_postings.sql").read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql)


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--dump", action="store_true", help="сохранить ответ в data/fbs_dump.json")
    args = ap.parse_args()

    postings = fetch_period(args.days)
    print(f"Всего получено: {len(postings)}")

    if args.dump:
        out = ROOT / "data" / "fbs_dump.json"
        out.parent.mkdir(exist_ok=True)
        out.write_text(json.dumps(postings, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Сохранено в {out}")
        return

    conn = pg_connect()
    try:
        n = load_raw(conn, postings)
        transform(conn)
        conn.commit()                 # всё или ничего: одна транзакция
        print(f"OK: в raw записано {n}, core обновлён")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
