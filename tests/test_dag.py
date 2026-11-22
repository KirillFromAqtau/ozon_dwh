"""Проверка DAG: файл импортируется без ошибок, порядок задач верный.

Нужен установленный Airflow — в основном прогоне тест пропускается,
в CI его гоняет отдельная задача dag-check.
"""
import pytest

pytest.importorskip("airflow")


def test_dag_loads_and_order():
    try:
        from airflow.dag_processing.dagbag import DagBag
    except ImportError:                      # старые версии Airflow
        from airflow.models.dagbag import DagBag

    bag = DagBag(dag_folder="dags", include_examples=False)
    assert bag.import_errors == {}

    dag = bag.dags["ozon_daily"]
    order = ["migrate", "load_fbs_postings", "load_accruals", "refresh_products", "dq_checks"]
    for upstream, downstream in zip(order, order[1:]):
        assert dag.get_task(upstream).downstream_task_ids == {downstream}
    assert dag.catchup is False
