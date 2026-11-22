"""Общее подключение к PostgreSQL для всех скриптов проекта.

Параметры берутся из переменных окружения. Файл .env подгружается,
но НЕ перезаписывает уже заданные переменные: так CI и Airflow
могут передать свои значения (например, PG_HOST=postgres).
"""
import os
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")


def connect():
    return psycopg2.connect(
        host=os.getenv("PG_HOST", "localhost"),
        port=os.getenv("PG_PORT", "5432"),
        dbname=os.getenv("PG_DB", "ozon_dwh"),
        user=os.environ["PG_USER"],
        password=os.environ["PG_PASSWORD"],
        # облачные базы (Neon) требуют шифрование: PG_SSLMODE=require;
        # локальный Docker работает и с prefer (по умолчанию)
        sslmode=os.getenv("PG_SSLMODE", "prefer"),
    )
