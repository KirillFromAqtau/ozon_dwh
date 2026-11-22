-- Справочник товаров из проданного: offer_id, sku и название берём из отправлений.
-- Себестоимостные поля (filament_g, print_time_min...) НЕ трогаем — их заполняешь ты.
INSERT INTO core.products (offer_id, ozon_sku, name)
SELECT DISTINCT ON (pr->>'offer_id')
       pr->>'offer_id', (pr->>'sku')::bigint, pr->>'name'
FROM raw.ozon_postings_fbs r
CROSS JOIN LATERAL jsonb_array_elements(r.payload->'products') pr
ORDER BY pr->>'offer_id', r.loaded_at DESC
ON CONFLICT (offer_id) DO UPDATE SET
    name     = EXCLUDED.name,
    ozon_sku = COALESCE(core.products.ozon_sku, EXCLUDED.ozon_sku);
