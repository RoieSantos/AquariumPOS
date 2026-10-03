-- READ-ONLY diagnostic: why several PRODUCTION ITEM rows (PI-040..PI-045) all got renamed to
-- "Tubular 2x2". Suspect: the Pancake -> Items sync (cron every 5 min) matched one Pancake
-- product onto the wrong Items row and overwrote its Name.
--
-- Checks, in one result (section column):
--   1. live_function   - whether the LIVE sync functions still contain the old buggy
--                        "SKU = t.sku OR Code = t.code" match (re-introduced if
--                        supabase_pancake_manual_sync.sql was re-run after
--                        supabase_pancake_item_sku_match_fix.sql), or the fixed ProductId match.
--   2. affected_item   - every Item named like "Tubular 2x2" with its SKU / ProductId / last sync.
--   3. shared_sku      - other Items sharing those SKUs (collision targets of the old bug).
--   4. shared_product  - other Items sharing those ProductIds (collision targets of the fix's
--                        ProductId match).
--   5. variant         - Variants rows pointing at the affected items.

with affected as (
  select i."Code", i."Name", i."SKU", i."ProductId", i."CategoryCode", i."SyncedAtUtc"
  from public."Items" i
  where i."Name" ~* 'tubular\s*2\s*[x×]\s*2'
     or i."Code" in ('PI-040', 'PI-041', 'PI-042', 'PI-043', 'PI-044', 'PI-045')
),
fn as (
  select p.proname, pg_get_functiondef(p.oid) as def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('admin_sync_items_from_pancake', 'cron_sync_items_from_pancake', 'admin_list_items_live')
)
select '1 live_function' as section,
       proname as code,
       case
         when def ~* 'i\."SKU"\s*=\s*t\.sku' or def ~* '"SKU"\s*=\s*v_sku' then 'BUGGY: still matches on SKU (old supabase_pancake_manual_sync.sql version is live)'
         when def ~* '"ProductId"\s*=\s*t\.product_id' or def ~* '"ProductId"\s*=\s*v_product_id' then 'FIXED: matches on ProductId then Code'
         else 'unknown match logic'
       end as name,
       null::text as sku, null::text as product_id, null::text as category, null::text as synced_at
from fn

union all
select '2 affected_item', a."Code", a."Name", a."SKU", a."ProductId", a."CategoryCode", a."SyncedAtUtc"::text
from affected a

union all
select '3 shared_sku', i."Code", i."Name", i."SKU", i."ProductId", i."CategoryCode", i."SyncedAtUtc"::text
from public."Items" i
where i."SKU" in (select "SKU" from affected where "SKU" is not null)
  and i."Code" not in (select "Code" from affected)

union all
select '4 shared_product', i."Code", i."Name", i."SKU", i."ProductId", i."CategoryCode", i."SyncedAtUtc"::text
from public."Items" i
where i."ProductId" in (select "ProductId" from affected where "ProductId" is not null)
  and i."Code" not in (select "Code" from affected)

union all
select '5 variant', v."ItemCode", v."VariantName", v."SKU", v."ProductId", v."MainItemCode", v."SyncedAtUtc"::text
from public."Variants" v
where v."ItemCode" in (select "Code" from affected)
   or v."MainItemCode" in (select "Code" from affected)

order by 1, 2;
