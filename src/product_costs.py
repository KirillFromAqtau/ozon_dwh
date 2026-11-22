"""
Себестоимость товаров через обычную таблицу (Numbers / Excel / Google Таблицы).

1) Выгрузить список товаров в CSV:
       python src/product_costs.py export
   → data/product_costs.csv (самые продаваемые сверху)

2) Открыть CSV, заполнить колонки:
       filament_g      — граммы пластика на 1 шт (из слайсера Bambu Studio, вместе с поддержками)
       print_time_min  — минут печати на 1 шт (если на столе 6 шт за 300 мин → 50)
       color           — Чёрный / Белый (как в core.materials)
   Сохранить в CSV.

3) Загрузить обратно в базу:
       python src/product_costs.py import
"""
import csv
import sys

from db import ROOT, connect

CSV_PATH = ROOT / "data" / "product_costs.csv"
FIELDS = ["offer_id", "name", "sold_units", "filament_g", "print_time_min", "color"]




def export():
    conn = connect()
    with conn, conn.cursor() as cur:
        # сначала обновим справочник товаров из отправлений
        cur.execute((ROOT / "sql/transform/products_from_postings.sql").read_text(encoding="utf-8"))
        cur.execute("""
            SELECT p.offer_id, p.name,
                   COALESCE(SUM(i.quantity) FILTER (WHERE po.status <> 'cancelled'), 0) AS sold,
                   p.filament_g, p.print_time_min, m.color
            FROM core.products p
            LEFT JOIN core.posting_items i USING (offer_id)
            LEFT JOIN core.postings po USING (posting_number)
            LEFT JOIN core.materials m USING (material_id)
            GROUP BY p.offer_id, p.name, p.filament_g, p.print_time_min, m.color
            ORDER BY sold DESC, p.offer_id""")
        rows = cur.fetchall()
    CSV_PATH.parent.mkdir(exist_ok=True)
    # utf-8-sig и ';' — чтобы Excel/Numbers с русской локалью открыли без "кракозябр"
    with CSV_PATH.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(FIELDS)
        for r in rows:
            w.writerow(["" if v is None else v for v in r])
    print(f"Выгружено товаров: {len(rows)} → {CSV_PATH}")


def to_num(s):
    s = (s or "").strip().replace(" ", "").replace(",", ".")   # 38,5 → 38.5
    return float(s) if s else None


def import_():
    text = CSV_PATH.read_text(encoding="utf-8-sig")
    delim = ";" if text.splitlines()[0].count(";") >= text.splitlines()[0].count(",") else ","
    rows = list(csv.DictReader(text.splitlines(), delimiter=delim))
    conn = connect()
    updated, skipped = 0, []
    with conn, conn.cursor() as cur:
        for r in rows:
            g, t = to_num(r.get("filament_g")), to_num(r.get("print_time_min"))
            if g is None or t is None:
                skipped.append(r["offer_id"])
                continue
            color = (r.get("color") or "Чёрный").strip()
            # сравниваем без учёта регистра и разницы е/ё: 'черный' = 'Чёрный'
            cur.execute("""SELECT material_id FROM core.materials
                           WHERE name = 'PETG'
                             AND replace(lower(color), 'ё', 'е') = replace(lower(%s), 'ё', 'е')""", (color,))
            m = cur.fetchone()
            if not m:
                print(f"  ! {r['offer_id']}: цвет '{color}' не найден в core.materials")
                continue
            cur.execute("""UPDATE core.products
                           SET filament_g=%s, print_time_min=%s, material_id=%s
                           WHERE offer_id=%s""", (g, round(t), m[0], r["offer_id"]))
            updated += cur.rowcount
    print(f"Обновлено: {updated}. Не заполнено (пропущено): {len(skipped)}")
    if skipped:
        print("  " + ", ".join(skipped[:15]) + (" ..." if len(skipped) > 15 else ""))


if __name__ == "__main__":
    {"export": export, "import": import_}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: print(__doc__))()
