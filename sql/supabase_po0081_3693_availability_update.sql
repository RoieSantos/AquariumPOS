-- One-off (2026-11-19): trim PO-0081 (vendor 3693PETSHOP) to what 3693 Petshop actually has
-- available, per their availability/price list sent 2026-11-19.
--
--   1. Removes 30 lines: 26 fish not on their list, plus the 4 per-colour glow tetra lines
--      (F-127/F-128/F-129/F-130), which are replaced by one generic F-056 GLO-TETRA line.
--   2. Updates UnitCost on 7 kept lines to their new prices.
--   3. Adds F-056 GLO-TETRA (qty 200 = the 4 removed glow lines' 50 each), F-028 GUPPY-FISH
--      (generic, no cost on their list as one number), F-116 Red Tiger Barb, F-156 Red Shrimp,
--      F-158 Black / Chocolate Shrimp. New lines get qty 1 as a PLACEHOLDER - Roie types the real
--      quantities on the PO page (the portal does not allow a 0-qty line).
--   4. Updates Items."Cost" and the 3693PETSHOP ItemVendors price to the new prices, so the next
--      PO to 3693 prefills the right cost.
--
-- Guarded: aborts if PO-0081 is missing/posted or any line has already been received.
-- NOT safe to re-run blindly (step 3 would add the new lines a second time) - the guard below
-- also aborts if the F-056 line already exists.

do $$
begin
  if not exists (select 1 from public."PurchaseOrders" where "PONo" = 'PO-0081') then
    raise exception 'PO-0081 not found (already posted?) - nothing changed.';
  end if;
  if exists (select 1 from public."PurchaseOrderLines" where "PONo" = 'PO-0081' and coalesce("QtyReceived", 0) <> 0) then
    raise exception 'PO-0081 has received lines - nothing changed.';
  end if;
  if exists (select 1 from public."PurchaseOrderLines" where "PONo" = 'PO-0081' and "ItemCode" = 'F-056') then
    raise exception 'PO-0081 already has an F-056 line - this script was already run.';
  end if;

  -- 1. Remove lines not available (by EntryNo, read 2026-11-19)
  delete from public."PurchaseOrderLines"
  where "PONo" = 'PO-0081'
    and "EntryNo" in (
      335, -- F-121 Albino Bristlenose Longfin
      336, -- F-146 Albino Butterfly Pleco (5-6")
      339, -- F-134 Albino Pristella Tetra
      340, -- F-115 Albino Rainbow Shark
      341, -- F-132 Albino Skirt Tetra
      342, -- F-119 Albino Tiger Barb
      345, -- F-125 Angel Fish (Breeder)
      349, -- F-164 Black Pleco
      350, -- F-131 Black Skirt Tetra
      352, -- F-161 Bronze Corydora
      353, -- F-138 Cosmic Blue Zebra
      356, -- F-159 Fire Red Shrimp
      360, -- F-145 Green Terror
      361, -- F-139 Green Zebra
      363, -- F-162 Julii Corydora
      364, -- F-144 Koi
      366, -- F-137 Leopard Zebra
      368, -- F-126 Marble Angel Fish
      370, -- F-141 Orange Danio
      371, -- F-157 Orange Shrimp
      372, -- F-117 Pink Tiger Barb
      375, -- F-163 Pygmy Cory
      377, -- F-150 Red & White Ranchu
      380, -- F-154 Red Dwarf Gourami (Fem)
      381, -- F-153 Red Dwarf Gourami (M)
      386, -- F-149 Red Tiger Oscar
      -- glow tetras -> replaced by one F-056 GLO-TETRA line
      354, -- F-129 Dark Green Glow Tetra
      369, -- F-128 Neon Glow Tetra
      382, -- F-130 Red Glow Tetra
      389  -- F-127 Yellow Glow Tetra
    );

  -- 2. New prices on kept lines
  update public."PurchaseOrderLines" l
  set "UnitCost" = v.cost
  from (values
    (376::bigint, 30::numeric), -- F-114 Rainbow Shark       25  -> 30
    (348, 20),                  -- F-122 Black Hammerhead    15  -> 20
    (383, 20),                  -- F-143 Red Paco            15  -> 20
    (358, 5),                   -- F-120 Golden Rosie Barb   3.5 -> 5
    (379, 5),                   -- F-135 Red Cross           3.5 -> 5
    (373, 4),                   -- F-136 Pink Zebra          2.5 -> 4
    (359, 20)                   -- F-118 Green Sumatra Barb  10  -> 20
  ) as v(entry_no, cost)
  where l."PONo" = 'PO-0081' and l."EntryNo" = v.entry_no;

  -- 3. New lines (qty 1 = placeholder, except glow tetra carries over 200)
  insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "Quantity", "QuantityUom", "UnitCost")
  values
    ('PO-0081', 'F-056', 'GLO-TETRA',                200, 200, 9),
    ('PO-0081', 'F-028', 'GUPPY-FISH',               1,   1,   null),
    ('PO-0081', 'F-116', 'Red Tiger Barb',           1,   1,   20),
    ('PO-0081', 'F-156', 'Red Shrimp',               1,   1,   12),
    ('PO-0081', 'F-158', 'Black / Chocolate Shrimp', 1,   1,   15);

  -- 4a. Item cost
  update public."Items" i
  set "Cost" = v.cost,
      "PortalEditedAtUtc" = now(),
      "PortalEditedBy" = 'SQL: 3693 availability 2026-11-19'
  from (values
    ('F-114', 30::numeric), ('F-122', 20), ('F-143', 20), ('F-120', 5), ('F-135', 5),
    ('F-136', 4), ('F-118', 20), ('F-116', 20), ('F-158', 15), ('F-056', 9)
  ) as v(code, cost)
  where i."Code" = v.code;

  -- 4b. 3693PETSHOP vendor price (adds F-056 / F-028 to the 3693 catalog so they show in its picker)
  insert into public."ItemVendors" ("ItemCode", "VendorCode", "Cost", "UpdatedAtUtc")
  values
    ('F-114', '3693PETSHOP', 30, now()), ('F-122', '3693PETSHOP', 20, now()),
    ('F-143', '3693PETSHOP', 20, now()), ('F-120', '3693PETSHOP', 5, now()),
    ('F-135', '3693PETSHOP', 5, now()),  ('F-136', '3693PETSHOP', 4, now()),
    ('F-118', '3693PETSHOP', 20, now()), ('F-116', '3693PETSHOP', 20, now()),
    ('F-158', '3693PETSHOP', 15, now()), ('F-056', '3693PETSHOP', 9, now()),
    ('F-028', '3693PETSHOP', null, now())
  on conflict ("ItemCode", "VendorCode") do update
    set "Cost" = excluded."Cost", "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end $$;

-- Result: PO-0081 lines after the update
select l."EntryNo", l."ItemCode", l."ItemName", l."Quantity", l."UnitCost"
from public."PurchaseOrderLines" l
where l."PONo" = 'PO-0081'
order by l."ItemName";
