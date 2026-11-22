-- One-off: load the GMA branch fish physical count (2026-11-22, sent by Roie) into a Physical
-- Inventory Journal batch "GMA-FISH-2026-11-22". This does NOT post - it only fills the worksheet
-- so the counts can be reviewed on the Physical Inventory Journal page and posted from there.
--
-- Rule (per Roie): only the fish on the list have stock at GMA; every other FISH item with a
-- non-zero GMA balance is counted as 0.
--
-- Safe to re-run: upserts on the batch/item/warehouse key and just re-sets QtyCounted.
-- Run AFTER supabase_item_ledger_phys_inventory_journal.sql.

with gma as (
  select "ID"::text as wh from public."Warehouses" where "Name" = 'GMA'
),
counted(item_code, qty, list_line) as (
  values
    ('F-058', 1,  'super red arowana 10in'),
    ('F-015', 1,  'albino silver arowana 7in'),
    ('F-080', 1,  'hbrtg 11in'),
    ('F-014', 3,  'silver arowana 4in'),
    ('F-050', 23, 'platinum tinfoil small'),
    ('F-072', 9,  'platinum tinfoil large'),
    ('F-012', 1,  'gar'),
    ('F-006', 1,  'irwini cf'),
    ('F-077', 1,  'bichir'),
    ('F-068', 12, 'koi 4in'),
    ('F-096', 3,  'flowerhorn medium'),
    ('F-052', 1,  'flowerhorn small'),
    ('F-047', 2,  'oscar albino 6in'),
    ('F-037', 5,  'rtc small'),
    ('F-018', 4,  'clown fish'),
    ('F-076', 15, 'goldfish redcap'),
    ('F-011', 2,  'torpedo barb'),
    ('F-020', 2,  'local oranda'),
    ('F-060', 17, 'molly platinum'),
    ('F-106', 3,  'tricolor molly'),
    ('F-033', 44, 'danios yellow'),
    ('F-139', 10, 'green (danio)'),
    ('F-021', 27, 'pristella'),
    ('F-102', 4,  'yellow prince'),
    ('F-066', 25, 'serpae'),
    ('F-092', 2,  'corydora')
),
zeroed as (
  -- Every other fish with a non-zero GMA balance -> counted 0.
  select e."ItemCode"::text as item_code, 0 as qty
  from public."ItemLedgerEntries" e
  join public."Items" i on i."Code" = e."ItemCode"
  where i."CategoryCode" = 'FISH'
    and e."WarehouseId" = (select wh from gma)
    and e."ItemCode" not in (select item_code from counted)
  group by e."ItemCode", e."VariantId"
  having sum(e."Quantity") <> 0
),
all_lines as (
  select item_code, qty from counted
  union all
  select item_code, qty from zeroed
)
insert into public."PhysInventoryJournalLines"
  ("BatchName", "ItemCode", "VariantId", "WarehouseId", "QtyCalculated", "QtyCounted", "UpdatedAtUtc", "UpdatedBy")
select 'GMA-FISH-2026-11-22', a.item_code, null, g.wh,
       public._ile_balance(a.item_code, null, g.wh), a.qty, now(), 'claude-code'
from all_lines a cross join gma g
on conflict ("BatchName", "ItemCode", (coalesce("VariantId", '')), "WarehouseId")
do update set "QtyCounted" = excluded."QtyCounted", "UpdatedAtUtc" = now(), "UpdatedBy" = excluded."UpdatedBy";

-- Preview: what posting this batch would do (nothing is posted here).
select r.item_code, r.item_name, r.qty_current::int as gma_now, r.qty_counted::int as counted,
       r.quantity::int as will_adjust_by
from public._ile_phys_journal_rows('GMA-FISH-2026-11-22') r
order by r.qty_counted desc, r.item_name;
