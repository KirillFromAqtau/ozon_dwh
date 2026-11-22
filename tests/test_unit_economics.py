"""Витрины себестоимости и юнит-экономики на маленьком наборе с ручным расчётом."""
import pytest

FBS = "sql/transform/fbs_postings.sql"
PRODUCTS = "sql/transform/products_from_postings.sql"
ACCRUALS = "sql/transform/accruals.sql"


@pytest.fixture
def setup_costs(conn):
    with conn.cursor() as cur:
        cur.execute("INSERT INTO core.materials (name, color, brand) VALUES ('PETG', 'Чёрный', 'Generic')")
        # 5 кг за 20 000 ₸ → 4000 ₸/кг
        cur.execute("""INSERT INTO core.material_purchases (material_id, purchase_date, weight_kg, total_cost)
                       VALUES (1, '2026-10-01', 5, 20000)""")
        # один принтер: 100 Вт, 100 000 ₸ на 10 000 ч → 10 ₸/ч износа
        cur.execute("""INSERT INTO core.printers (model, nickname, purchase_price, avg_power_w, expected_life_h)
                       VALUES ('Test', 'T1', 100000, 100, 10000)""")
        cur.execute("""INSERT INTO core.cost_settings (setting_key, valid_from, value) VALUES
                       ('electricity_per_kwh', '2026-01-01', 25), ('packaging_per_unit', '2026-01-01', 60)""")
    conn.commit()


def test_unit_cost_formula(setup_costs, load_postings, run_sql, conn, query):
    load_postings()
    run_sql(FBS, PRODUCTS)
    with conn.cursor() as cur:   # 40 г, 60 мин на штуку
        cur.execute("UPDATE core.products SET filament_g=40, print_time_min=60, material_id=1 "
                    "WHERE offer_id='TEST_HOLDER'")
    conn.commit()
    (fil, el, dep, pack, total), = query("""
        SELECT cost_filament, cost_electricity, cost_depreciation, cost_packaging, unit_cost_kzt
        FROM mart.product_unit_cost WHERE offer_id = 'TEST_HOLDER'""")
    assert float(fil) == 160.0          # 40 г × 4000 ₸/кг
    assert float(el) == 2.5             # 1 ч × 0,1 кВт × 25 ₸
    assert float(dep) == 10.0           # 1 ч × 10 ₸/ч
    assert float(pack) == 60.0
    assert float(total) == 232.5


def test_unit_economics(setup_costs, load_postings, load_accruals, run_sql, conn, query):
    load_postings()
    run_sql(FBS, PRODUCTS)
    with conn.cursor() as cur:
        cur.execute("UPDATE core.products SET filament_g=40, print_time_min=60, material_id=1 "
                    "WHERE offer_id='TEST_HOLDER'")
    conn.commit()
    load_accruals()
    run_sql(ACCRUALS)
    (units, payout, profit, margin), = query("""
        SELECT units_sold, avg_payout_kzt, profit_per_unit_kzt, margin_pct
        FROM mart.unit_economics WHERE offer_id = 'TEST_HOLDER'""")
    # 1500 − 180 − 246 − 330 = 744 пришло на счёт; 744 − 232,5 = 511,5
    assert units == 1
    assert float(payout) == 744
    assert float(profit) == 512                 # ROUND(511.5)
    assert float(margin) == 34.1                # 511,5 / 1500
