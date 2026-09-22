-- Adds Category to the Physical Inventory Journal grid, per direct request: "can you show the
-- category field on the physical inventory journal".
--
-- Run AFTER supabase_phys_journal_calculate_from_pancake_fix.sql (the version this redefines).
--
-- _ile_phys_journal_rows / admin_get_phys_journal_lines now also return each line's item Category
-- (code + description, from Items."CategoryCode" -> Categories."Description" - same lookup
-- Category Setup and the Calculate Inventory category filter already use). Additive (appended at
-- the end) - admin_post_phys_inventory_journal's own "select * from _ile_phys_journal_rows(...) r"
-- keeps working unchanged since it accesses fields by name. Display-only column; does not affect
-- Calculate Inventory's existing Category filter/dropdown or posting.

drop function if exists public._ile_phys_journal_rows(text);

create or replace function public._ile_phys_journal_rows(p_batch_name text)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  qty_calculated numeric, qty_counted numeric, qty_current numeric, quantity numeric,
  updated_at_utc timestamptz, updated_by text,
  product_id text, pancake_variation_id text,
  category_code text, category_name text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    l."LineID", l."ItemCode"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), l."ItemCode")::text,
    l."VariantId"::text, v."VariantName"::text,
    l."WarehouseId"::text, coalesce(w."Name", l."WarehouseId")::text,
    l."QtyCalculated", l."QtyCounted",
    public._ile_balance(l."ItemCode", l."VariantId", l."WarehouseId"),
    case when l."QtyCounted" is null then null
         else l."QtyCounted" - public._ile_balance(l."ItemCode", l."VariantId", l."WarehouseId") end,
    l."UpdatedAtUtc", l."UpdatedBy"::text,
    coalesce(v."ProductId", i."ProductId")::text,
    coalesce(l."VariantId", i."VariationId")::text,
    i."CategoryCode"::text,
    coalesce(nullif(trim(cat."Description"), ''), i."CategoryCode")::text
  from public."PhysInventoryJournalLines" l
  left join public."Items" i on i."Code" = l."ItemCode"
  left join public."Variants" v on v."VariationId" = l."VariantId"
  left join public."Warehouses" w on w."ID" = l."WarehouseId"
  left join public."Categories" cat on cat."Code" = i."CategoryCode"
  where l."BatchName" = p_batch_name
$$;

revoke execute on function public._ile_phys_journal_rows(text) from public, anon, authenticated;

drop function if exists public.admin_get_phys_journal_lines(text, text, text);

create or replace function public.admin_get_phys_journal_lines(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text
)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  qty_calculated numeric, qty_counted numeric, qty_current numeric, quantity numeric,
  updated_at_utc timestamptz, updated_by text,
  product_id text, pancake_variation_id text,
  category_code text, category_name text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select r.* from public._ile_phys_journal_rows(trim(coalesce(p_batch_name, 'DEFAULT'))) r
    order by r.item_name, r.variant_name nulls first, r.warehouse_name;
end;
$$;

grant execute on function public.admin_get_phys_journal_lines(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect 2 rows.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('_ile_phys_journal_rows', 'admin_get_phys_journal_lines')
order by p.proname;
