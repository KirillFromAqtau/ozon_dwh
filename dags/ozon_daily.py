"""
Ежедневная загрузка данных Ozon в ozon_dwh.

    load_fbs_postings ─► load_accruals ─► refresh_products ─► dq_checks

Почему такие периоды:
  * отправления за 30 дней — статусы меняются (delivering → delivered ~2 недели),
    поэтому перезабираем «хвост» и обновляем статусы через upsert;
  * начисления за 14 дней — Ozon может досписать что-то задним числом.
Все шаги идемпотентны: повторный запуск не создаёт дублей.
"""
from datetime import timedelta

import pendulum
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import dag
from airflow.timetables.trigger import CronTriggerTimetable

PROJECT = "/opt/ozon_dwh"


@dag(
    dag_id="ozon_daily",
    # каждый день в 07:00 по Актау. run_immediately=True: если MacBook спал
    # в 07:00, пропущенный запуск выполнится сразу, как только Airflow проснётся
    schedule=CronTriggerTimetable("0 7 * * *", timezone="Asia/Aqtau", run_immediately=True),
    start_date=pendulum.datetime(2026, 11, 22, tz="Asia/Aqtau"),
    catchup=False,                                 # пропущенные дни не догоняем пачкой
    max_active_runs=1,                             # не запускать два прогона одновременно
    default_args={
        "retries": 2,                              # Ozon API иногда отвечает 5xx
        "retry_delay": timedelta(minutes=5),
    },
    tags=["ozon", "elt"],
)
def ozon_daily():
    load_postings = BashOperator(
        task_id="load_fbs_postings",
        bash_command=f"cd {PROJECT} && python src/load_fbs_postings.py --days 30",
    )
    load_accruals = BashOperator(
        task_id="load_accruals",
        bash_command=f"cd {PROJECT} && python src/load_accruals.py --days 14",
    )
    refresh_products = BashOperator(
        task_id="refresh_products",
        bash_command=f"cd {PROJECT} && python src/run_sql.py sql/transform/products_from_postings.sql",
    )
    dq_checks = BashOperator(
        task_id="dq_checks",
        bash_command=f"cd {PROJECT} && python src/dq_checks.py",
        retries=0,                                 # проверку повторять бессмысленно
    )

    load_postings >> load_accruals >> refresh_products >> dq_checks


ozon_daily()
