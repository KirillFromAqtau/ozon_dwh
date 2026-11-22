"""Разбор raw.ozon_accrual_pages → core.accruals ("атомы" начислений)."""
import copy

from conftest import load_json

FBS = "sql/transform/fbs_postings.sql"
PRODUCTS = "sql/transform/products_from_postings.sql"
ACCRUALS = "sql/transform/accruals.sql"


def prepare(load_postings, load_accruals, run_sql, page=None):
    load_postings()
    run_sql(FBS, PRODUCTS)
    load_accruals(page=page)
    run_sql(ACCRUALS)


def test_sum_of_atoms_equals_ozon_total(load_postings, load_accruals, run_sql, query):
    """Главный инвариант: сумма атомов = сумме total_amount от Ozon."""
    page = load_json("accrual_page.json")
    expected = sum(float(a["total_amount"]["amount"]) for a in page["accruals"])
    prepare(load_postings, load_accruals, run_sql)
    (total,), = query("SELECT sum(amount) FROM core.accruals")
    assert float(total) == expected == 584.0


def test_groups(load_postings, load_accruals, run_sql, query):
    prepare(load_postings, load_accruals, run_sql)
    groups = {g: float(s) for g, s in query("SELECT accrual_group, sum(amount) FROM core.accruals GROUP BY 1")}
    assert groups == {
        "revenue": 1500.0,
        "commission": -180.0,
        "logistics": -246.0,
        "penalty": -330.0,       # DefectRate — плата за просрочку отгрузки
        "returns": -160.0,       # Disposal — утилизация (блок item_fees)
    }


def test_bonus_is_not_counted_as_money(load_postings, load_accruals, run_sql, query):
    """bonus — скидка за счёт Ozon, в total_amount не входит и атомом быть не должен."""
    prepare(load_postings, load_accruals, run_sql)
    assert query("SELECT count(*) FROM core.accruals WHERE amount = 80") == [(0,)]


def test_offer_id_resolved(load_postings, load_accruals, run_sql, query):
    prepare(load_postings, load_accruals, run_sql)
    rows = dict(query("SELECT accrual_type, offer_id FROM core.accruals WHERE offer_id IS NOT NULL"))
    assert rows["SaleAmount"] == "TEST_HOLDER"     # через отправление
    assert rows["Disposal"] == "TEST_CLIP"         # ITEM-начисление: через sku в справочнике


def test_delivered_at_from_revenue_date(load_postings, load_accruals, run_sql, query):
    prepare(load_postings, load_accruals, run_sql)
    (d,), = query("SELECT delivered_at::date::text FROM core.postings WHERE posting_number='11111111-0001-1'")
    assert d == "2026-11-10"


def test_unknown_block_goes_to_unparsed(load_postings, load_accruals, run_sql, query):
    """Неизвестный блок (container_fees) не теряется: разница уходит в Unparsed."""
    page = copy.deepcopy(load_json("accrual_page.json"))
    page["accruals"].append({
        "accrual_id": 1004, "date": "2026-11-12", "accrued_category": "CONTAINER",
        "unit_number": "RU12-AB000", "posting": None, "item_fees": None, "non_item_fee": None,
        "container_fees": {"something": "new"},
        "total_amount": {"amount": "-50", "currency": "KZT"},
    })
    prepare(load_postings, load_accruals, run_sql, page=page)
    assert query("SELECT accrual_type, amount::float FROM core.accruals WHERE ozon_accrual_id = 1004") == \
        [("Unparsed", -50.0)]


def test_rebuild_is_idempotent(load_postings, load_accruals, run_sql, query):
    prepare(load_postings, load_accruals, run_sql)
    run_sql(ACCRUALS)
    run_sql(ACCRUALS)
    assert query("SELECT count(*) FROM core.accruals") == [(5,)]
