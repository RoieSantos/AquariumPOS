-- One-off (2026-11-21): set up the fish for the IsdaPoko (V020) purchase order.
--  1. Creates 2 new FISH items, the same way admin_create_item does (Items + Variants rows,
--     next F- code): Black Angel Fish and Longfin Danio. Primary vendor = V020.
--  2. Adds V020 to the vendor catalog (ItemVendors) of all 10 PO fish, with this PO's unit cost,
--     so V020 can be picked for them on the PO. Existing primary vendors are left alone.
-- Safe to re-run: new items are only created if no item with that name exists yet, and catalog
-- rows are upserted.

do $$
declare
  v_new record;
  v_code text;
  v_var text;
begin
  for v_new in
    select * from (values
      ('Black Angel Fish', 340::numeric, 20::numeric),
      ('Longfin Danio',     45::numeric, 25::numeric)
    ) t(name, price, cost)
  loop
    if exists (select 1 from public."Items" where "Name" ilike v_new.name) then
      continue;
    end if;
    perform pg_advisory_xact_lock(hashtext('item-code|F'));
    v_code := public._next_item_code('F');
    v_var := gen_random_uuid()::text;

    insert into public."Items" ("Code", "Name", "Description", "CategoryCode", "SKU", "Price", "Cost",
                                "IsActive", "VendorCode", "VariationId", "PortalEditedAtUtc", "PortalEditedBy")
    values (v_code, v_new.name, v_new.name, 'FISH', v_code, v_new.price, v_new.cost,
            true, 'V020', v_var, now(), 'Claude (Roie request)');

    insert into public."Variants" ("VariationId", "MainItemCode", "ItemCode", "SKU", "VariantName", "Price", "CategoryCode")
    values (v_var, v_code, v_code, v_code, v_new.name, v_new.price, 'FISH');
  end loop;
end $$;

insert into public."ItemVendors" ("ItemCode", "VendorCode", "Cost", "Notes", "UpdatedAtUtc")
select i."Code", 'V020', m.cost, 'IsdaPoko PO 2026-11-21', now()
from (values
  ('F-087', 5),     -- Tiger Barb        50 pcs  P250
  ('F-118', 15),    -- Green Sumatra     50 pcs  P750
  ('F-056', 9),     -- Glo Tetra random 400 pcs  P3600
  ('F-033', 10),    -- Danio random     100 pcs  P1000
  ('F-97', 10),     -- Kohaku Red Eye    50 pcs  P500
  ('F-020', 20),    -- Local Oranda      25 pcs  P500
  ('F-146', 200),   -- Albino Gibbi       3 pcs  P600
  ('F-162', 25)     -- Juli Cory         20 pcs  P500
) m(code, cost)
join public."Items" i on i."Code" = m.code
union all
select i."Code", 'V020', i."Cost", 'IsdaPoko PO 2026-11-21', now()
from public."Items" i
where i."Name" in ('Black Angel Fish', 'Longfin Danio') and i."VendorCode" = 'V020'
on conflict ("ItemCode", "VendorCode") do update
  set "Cost" = excluded."Cost", "Notes" = excluded."Notes", "UpdatedAtUtc" = now();

-- Result: the 10 PO fish with their V020 cost.
select i."Code", i."Name", i."Price", iv."Cost" as "V020Cost", i."VendorCode" as "PrimaryVendor"
from public."ItemVendors" iv
join public."Items" i on i."Code" = iv."ItemCode"
where iv."VendorCode" = 'V020'
order by i."Code";
