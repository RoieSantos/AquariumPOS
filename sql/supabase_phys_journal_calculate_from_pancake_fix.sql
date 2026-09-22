-- Fixes "Calculate failed: canceling statement due to statement timeout" on the "Qty. (Calculated)
-- from Pancake (live)" option added in supabase_phys_journal_calculate_from_pancake.sql.
--
-- WHY IT TIMED OUT
-- That version made ALL of its live Pancake HTTP calls (one per distinct product in the filtered
-- set) sequentially inside ONE PostgREST RPC call - i.e. one single Postgres statement. Supabase's
-- API roles (anon/authenticated) run under a strict statement_timeout (this project's is well under
-- a minute), armed once at the START of that statement using whatever the role's timeout already
-- was - a function-level override (ALTER FUNCTION ... SET statement_timeout) does NOT get applied
-- until AFTER that timer is already running, so it can't rescue a call like this. With more than a
-- handful of distinct products (very likely, e.g. a whole flagged category), the accumulated network
-- time blew straight through it.
--
-- THE FIX: stop doing the fetching inside one big statement. admin_calculate_phys_inventory goes
-- back to being purely ledger-based and fast (no Pancake HTTP at all, same as before that feature was
-- added) - it only builds the worksheet's lines. The live Pancake read is now a SEPARATE step the
-- CLIENT drives, one product at a time via admin_get_pancake_stock_for_product (one bounded HTTP
-- call = one small statement, safely under any reasonable statement_timeout), applying the results
-- back with the fast, HTTP-free admin_apply_phys_journal_calculated_qty. physicalInventoryJournal.js
-- shows this as a progress message ("Fetching live Pancake stock... N/M products") after Calculate
-- finishes, instead of blocking the Calculate call itself.
--
-- Run AFTER supabase_phys_journal_calculate_from_pancake.sql (undoes its inline-fetch approach).

-- ============================================================================
-- 1. admin_calculate_phys_inventory - back to purely ledger-based and fast. Identical to
--    supabase_phys_journal_calculate_stock_sync_filter.sql's version; p_from_pancake is dropped
--    (the client no longer passes it - see below).
-- ============================================================================

drop function if exists public.admin_calculate_phys_inventory(text, text, text, text, text, text, boolean, boolean);
drop function if exists public.admin_calculate_phys_inventory(text, text, text, text, text, text, boolean);

create or replace function public.admin_calculate_phys_inventory(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_warehouse_id text,
  p_category_code text default null,
  p_search text default null,
  p_only_stock_sync_categories boolean default false
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_warehouse text := trim(coalesce(p_warehouse_id, ''));
  v_count int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_batch = '' then
    raise exception 'A batch name is required.';
  end if;

  if v_warehouse = '' or not exists (select 1 from public."Warehouses" where "ID" = v_warehouse) then
    raise exception 'Pick a location to calculate inventory for.';
  end if;

  with variant_counts as (
    select v."ItemCode" as item_code, count(*) as cnt from public."Variants" v group by v."ItemCode"
  ),
  keys as (
    select i."Code" as item_code, v."VariationId" as variant_id
    from public."Items" i
    join public."Variants" v on v."ItemCode" = i."Code"
    join variant_counts vc on vc.item_code = i."Code" and vc.cnt >= 2
    where coalesce(i."IsActive", true)
    union all
    select i."Code", null
    from public."Items" i
    left join variant_counts vc on vc.item_code = i."Code"
    where coalesce(i."IsActive", true) and coalesce(vc.cnt, 0) < 2
  ),
  filtered as (
    select k.item_code, k.variant_id
    from keys k
    join public."Items" i on i."Code" = k.item_code
    left join public."Variants" v on v."VariationId" = k.variant_id
    left join public."Categories" cat on cat."Code" = i."CategoryCode"
    where (p_category_code is null or trim(p_category_code) = '' or i."CategoryCode" = p_category_code)
      and (not coalesce(p_only_stock_sync_categories, false) or coalesce(cat."IncludeInStockSync", false) is true)
      and (
        p_search is null or trim(p_search) = ''
        or k.item_code ilike '%' || trim(p_search) || '%'
        or i."Name" ilike '%' || trim(p_search) || '%'
        or v."VariantName" ilike '%' || trim(p_search) || '%'
      )
  )
  insert into public."PhysInventoryJournalLines"
    ("BatchName", "ItemCode", "VariantId", "WarehouseId", "QtyCalculated", "UpdatedAtUtc", "UpdatedBy")
  select v_batch, f.item_code, f.variant_id, v_warehouse,
         public._ile_balance(f.item_code, f.variant_id, v_warehouse), now(), p_admin_username
  from filtered f
  on conflict ("BatchName", "ItemCode", (coalesce("VariantId", '')), "WarehouseId")
  do update set
    "QtyCalculated" = case when public."PhysInventoryJournalLines"."QtyCounted" is null
                            then excluded."QtyCalculated"
                            else public."PhysInventoryJournalLines"."QtyCalculated" end,
    "UpdatedAtUtc" = now(),
    "UpdatedBy" = excluded."UpdatedBy";

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_calculate_phys_inventory(text, text, text, text, text, text, boolean) to anon;

-- ============================================================================
-- 2. _ile_phys_journal_rows / admin_get_phys_journal_lines - now also expose each line's Pancake
--    product id + variation id, so the client knows what to ask admin_get_pancake_stock_for_product
--    for without a separate lookup call. Additive (appended at the end) - admin_post_phys_inventory_
--    journal's "select * from _ile_phys_journal_rows(...) r" (supabase_item_ledger_phys_inventory_
--    journal.sql) keeps working unchanged since it accesses fields by name.
-- ============================================================================

drop function if exists public._ile_phys_journal_rows(text);

create or replace function public._ile_phys_journal_rows(p_batch_name text)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  qty_calculated numeric, qty_counted numeric, qty_current numeric, quantity numeric,
  updated_at_utc timestamptz, updated_by text,
  product_id text, pancake_variation_id text
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
    coalesce(l."VariantId", i."VariationId")::text
  from public."PhysInventoryJournalLines" l
  left join public."Items" i on i."Code" = l."ItemCode"
  left join public."Variants" v on v."VariationId" = l."VariantId"
  left join public."Warehouses" w on w."ID" = l."WarehouseId"
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
  product_id text, pancake_variation_id text
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

-- ============================================================================
-- 3. admin_get_pancake_stock_for_product - ONE product per call (one bounded HTTP round trip), so
--    a single call can never approach the statement_timeout the way the old loop did. Same response
--    shape already confirmed working by supabase_transfer_line_pancake_stock.sql
--    (staff_get_transfer_line_pancake_stock) for this exact endpoint.
-- ============================================================================

drop function if exists public.admin_get_pancake_stock_for_product(text, text, text);

create or replace function public.admin_get_pancake_stock_for_product(
  p_admin_username text,
  p_admin_password text,
  p_product_id text
)
returns table(variation_id text, warehouse_id text, remain_quantity numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_response extensions.http_response;
  v_body jsonb;
  v_product jsonb;
  v_variations jsonb;
  v_variation jsonb;
  v_warehouses jsonb;
  v_wh_entry jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_product_id is null or trim(p_product_id) = '' then
    return;
  end if;

  -- Kept comfortably below this project's statement_timeout (the whole point of splitting this out
  -- to one product per call) - if a single call like this still times out, the role's
  -- statement_timeout is tighter than expected and this number needs lowering further.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');

  begin
    select * into v_response from extensions.http_get(
      v_base_url || '/shops/' || v_shop_id || '/products/' || p_product_id || '?api_key=' || v_api_key
    );
  exception when others then
    return; -- unreachable/timed out - caller falls back to the portal's own ledger figure
  end;

  if v_response.status < 200 or v_response.status >= 300 then
    return;
  end if;

  v_body := v_response.content::jsonb;
  v_product := case
    when jsonb_typeof(v_body -> 'product') = 'object' then v_body -> 'product'
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    else v_body
  end;

  v_variations := case
    when jsonb_typeof(v_product -> 'variations') = 'array' then v_product -> 'variations'
    else '[]'::jsonb
  end;

  for v_variation in select * from jsonb_array_elements(v_variations)
  loop
    v_warehouses := case
      when jsonb_typeof(v_variation -> 'variations_warehouses') = 'array' then v_variation -> 'variations_warehouses'
      else '[]'::jsonb
    end;

    for v_wh_entry in select * from jsonb_array_elements(v_warehouses)
    loop
      variation_id := coalesce(nullif(v_variation ->> 'id', ''), nullif(v_variation ->> 'variation_id', ''));
      warehouse_id := coalesce(nullif(v_wh_entry ->> 'warehouse_id', ''), nullif(v_wh_entry ->> 'warehouseId', ''));
      remain_quantity := nullif(coalesce(v_wh_entry ->> 'remain_quantity', v_wh_entry ->> 'remainQuantity', v_wh_entry ->> 'quantity'), '')::numeric;
      return next;
    end loop;
  end loop;
end;
$$;

grant execute on function public.admin_get_pancake_stock_for_product(text, text, text) to anon;

-- ============================================================================
-- 4. admin_apply_phys_journal_calculated_qty - fast, HTTP-free batched write: the client accumulates
--    {line_id, qty} results from repeated admin_get_pancake_stock_for_product calls and applies them
--    a batch at a time. Only touches a line if it's still in this batch AND not yet counted - same
--    "frozen once counted" rule Calculate Inventory itself already follows.
-- ============================================================================

drop function if exists public.admin_apply_phys_journal_calculated_qty(text, text, text, jsonb);

create or replace function public.admin_apply_phys_journal_calculated_qty(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_updates jsonb -- [{ "line_id": 123, "qty": 45 }, ...]
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_count int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_updates is null or jsonb_typeof(p_updates) <> 'array' or jsonb_array_length(p_updates) = 0 then
    return 0;
  end if;

  update public."PhysInventoryJournalLines" l
  set "QtyCalculated" = (u.value ->> 'qty')::numeric,
      "UpdatedAtUtc" = now(),
      "UpdatedBy" = p_admin_username
  from jsonb_array_elements(p_updates) u
  where l."LineID" = (u.value ->> 'line_id')::bigint
    and l."BatchName" = v_batch
    and l."QtyCounted" is null
    and (u.value ->> 'qty') is not null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_apply_phys_journal_calculated_qty(text, text, text, jsonb) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect 4 rows.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_calculate_phys_inventory',
    'admin_get_phys_journal_lines',
    'admin_get_pancake_stock_for_product',
    'admin_apply_phys_journal_calculated_qty'
  )
order by p.proname, arguments;
