-- Purchase Order line Description now defaults to the item's ACTUAL catalog description, per
-- "can you validate the description base on the actual description of the item / variant" - the
-- field was free text with nothing behind it, so every line was typed from scratch (or left
-- blank) even though Items."Description" already holds the real description.
--
-- staff_search_items gains a trailing "description" column (Items."Description", the same text
-- Item Setup edits) so the New Purchase Order grid and the Receive document's Add Item toolbar
-- can prefill a line's Description the moment an item is picked. Variants carry no Description
-- column of their own - a variant's descriptive text is Variants."VariantName", which
-- staff_search_variants already returns - so that function needs no change here.
--
-- SUPERSEDES supabase_fix_staff_search_items_overloads.sql: this file contains that same
-- overload cleanup, so running this one alone is enough whether or not the other was ever run.
--
-- Every public.staff_search_items overload is dropped BY OID rather than by a hard-coded
-- argument list. The function has been widened several times (p_page, then p_vendor_code, then
-- the "cost" column), and each of those migrations dropped the previous version by its exact
-- signature - so any older copy whose signature differed even slightly survived, leaving two
-- overloads that both accept the argument names the portal sends. PostgREST then refuses to pick
-- one and returns "Could not choose the best candidate function between: ..." (PGRST203) instead
-- of search results, which is what broke the New Purchase Order item picker.
--
-- Safe to re-run.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'staff_search_items'
  loop
    raise notice 'Dropping overload: %', r.signature;
    execute format('drop function %s', r.signature);
  end loop;
end;
$$;

create or replace function public.staff_search_items(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 20, p_use_production_category boolean default null, p_page int default 1, p_vendor_code text default null)
returns table(code text, name text, category_code text, quantity_in_stock int, total_count bigint, cost numeric, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text, i."Name"::text, i."CategoryCode"::text, i."QuantityInStock",
           count(*) over(), i."Cost",
           -- Blank descriptions come back as null, not '', so the caller's "fall back to the item
           -- name" only has one empty case to handle.
           nullif(trim(i."Description"), '')::text
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where (p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%')
      and (p_use_production_category is null or coalesce(c."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(c."ExcludeInTransferOrders", false)
      and (p_vendor_code is null or trim(p_vendor_code) = '' or i."VendorCode" = p_vendor_code)
    order by i."Name"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

grant execute on function public.staff_search_items(text, text, text, int, boolean, int, text) to anon;

-- PostgREST caches the schema; without this the old ambiguity (and the missing column) can
-- persist for up to ~10 minutes.
notify pgrst, 'reload schema';

-- Verification. Expect EXACTLY ONE row, reading:
--   staff_search_items | p_admin_username text, p_admin_password text, p_search text,
--                        p_limit integer, p_use_production_category boolean, p_page integer,
--                        p_vendor_code text | t
-- More than one row means a drop was blocked - check the NOTICE output above.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_search_items';

-- Sanity check on the data itself: how many of your items actually carry a Description. Items
-- with none fall back to the item Name in the picker, which is why the Description box is never
-- left empty even for a sparsely-filled catalog.
select
  count(*) as items,
  count(nullif(trim("Description"), '')) as items_with_description
from public."Items";
