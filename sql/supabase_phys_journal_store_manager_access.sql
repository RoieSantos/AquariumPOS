-- Opens the Physical Inventory Journal to Store Manager accounts too, per direct request: "can you
-- show this to manager permission too?" (i.e. the "Store Manager" permission -
-- supabase_staff_users_store_manager_field.sql).
--
-- WHY A NEW FUNCTION INSTEAD OF EDITING is_admin_authorized()
-- Every RPC behind this page checks is_admin_authorized(), which is a strict "must be SuperUser"
-- gate shared by lots of other admin-only functions (creating staff logins, Item Setup, Variant
-- Setup, etc.) - loosening it there would open all of those too. Instead this adds a new
-- is_phys_journal_authorized() that accepts SuperUser OR StoreManager, and swaps it in ONLY for the
-- Physical Inventory Journal's own RPCs (batches/lines/calculate/add/edit/delete/post + the two
-- Pancake-live-stock helpers). Everything else on the SuperUser-only Inventory menu (Item Ledger
-- Entries, Warehouse/Item/Variant/Category/Vendor Setup) is untouched and still SuperUser-only.
--
-- KNOWN GAP (left as-is for now, flagged rather than guessed at): admin_list_items,
-- admin_list_variants (the "Add Line" item/variant search) and admin_get_item_ledger_balances (the
-- per-line "availability by location" fact box) are also called by this page, but are shared with
-- Item Setup/Variant Setup/Item Ledger Entries - all still SuperUser-only pages - so they were left
-- on is_admin_authorized(). A Store Manager can still Calculate Inventory, count, and Post normally;
-- they'll just see "Not authorized" if they try to manually search for an item to add a line, or
-- open a line's availability-by-location box. Say the word if you want those opened up too.
--
-- Run AFTER supabase_staff_users_store_manager_field.sql and supabase_phys_journal_sku_column.sql.

-- ============================================================================
-- 0. The shared auth check
-- ============================================================================

drop function if exists public.is_phys_journal_authorized(text, text);

create or replace function public.is_phys_journal_authorized(p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_super_user boolean;
  v_store_manager boolean;
begin
  select "PasswordHash", "IsActive", "SuperUser", "StoreManager"
    into v_password_hash, v_is_active, v_super_user, v_store_manager
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active or not (coalesce(v_super_user, false) or coalesce(v_store_manager, false)) then
    return false;
  end if;

  return v_password_hash = crypt(p_password, v_password_hash);
end;
$$;

-- Not granted to anon directly, same as is_admin_authorized() - only callable from inside the
-- security definer functions below.

-- ============================================================================
-- 1. Batches / lines
-- ============================================================================

create or replace function public.admin_list_phys_journal_batches(
  p_admin_username text,
  p_admin_password text
)
returns table(batch_name text, line_count bigint, counted_count bigint, last_updated_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."BatchName"::text, count(*), count(*) filter (where l."QtyCounted" is not null), max(l."UpdatedAtUtc")
    from public."PhysInventoryJournalLines" l
    group by l."BatchName"
    order by max(l."UpdatedAtUtc") desc;
end;
$$;

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
  sku text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select r.* from public._ile_phys_journal_rows(trim(coalesce(p_batch_name, 'DEFAULT'))) r
    order by r.item_name, r.variant_name nulls first, r.warehouse_name;
end;
$$;

-- ============================================================================
-- 2. Calculate Inventory
-- ============================================================================

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
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
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

-- ============================================================================
-- 3. Edit lines by hand
-- ============================================================================

create or replace function public.admin_add_phys_journal_line(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_item_code text,
  p_variant_id text,
  p_warehouse_id text
)
returns table(line_id bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_warehouse text := trim(coalesce(p_warehouse_id, ''));
  v_item text;
  v_variant text;
  v_line_id bigint;
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_batch = '' then
    raise exception 'A batch name is required.';
  end if;

  if v_warehouse = '' or not exists (select 1 from public."Warehouses" where "ID" = v_warehouse) then
    raise exception 'Pick a location.';
  end if;

  select k.item_code, k.variant_id into v_item, v_variant
    from public._ile_resolve_stock_key(p_item_code, p_variant_id) k;

  insert into public."PhysInventoryJournalLines"
    ("BatchName", "ItemCode", "VariantId", "WarehouseId", "QtyCalculated", "UpdatedAtUtc", "UpdatedBy")
  values (v_batch, v_item, v_variant, v_warehouse, public._ile_balance(v_item, v_variant, v_warehouse), now(), p_admin_username)
  on conflict ("BatchName", "ItemCode", (coalesce("VariantId", '')), "WarehouseId")
  do update set "UpdatedAtUtc" = now(), "UpdatedBy" = excluded."UpdatedBy"
  returning "LineID" into v_line_id;

  return query select v_line_id;
end;
$$;

create or replace function public.admin_set_phys_journal_qty(
  p_admin_username text,
  p_admin_password text,
  p_line_id bigint,
  p_qty_counted numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_qty_counted is not null and p_qty_counted < 0 then
    raise exception 'A physical count cannot be negative.';
  end if;

  update public."PhysInventoryJournalLines"
     set "QtyCounted" = p_qty_counted, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
   where "LineID" = p_line_id;

  if not found then
    raise exception 'That line is no longer on the worksheet - someone may have already posted or deleted it. Refresh the page.';
  end if;
end;
$$;

create or replace function public.admin_delete_phys_journal_line(
  p_admin_username text,
  p_admin_password text,
  p_line_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."PhysInventoryJournalLines" where "LineID" = p_line_id;
end;
$$;

create or replace function public.admin_clear_phys_journal_batch(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text
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
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_batch = '' then
    raise exception 'A batch name is required.';
  end if;

  delete from public."PhysInventoryJournalLines" where "BatchName" = v_batch;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ============================================================================
-- 4. Post
-- ============================================================================

create or replace function public.admin_post_phys_inventory_journal(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_posting_date date,
  p_reason text default null,
  p_dry_run boolean default true
)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text, qty_calculated numeric, qty_counted numeric, quantity numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_transaction_no bigint;
  v_doc_no text;
  v_row record;
  v_ids bigint[] := array[]::bigint[];
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."PhysInventoryJournalLines" where "BatchName" = v_batch and "QtyCounted" is not null) then
    raise exception 'Nothing on this worksheet has a count yet.';
  end if;

  if not coalesce(p_dry_run, true) and (p_reason is null or trim(p_reason) = '') then
    raise exception 'A reason is required (e.g. "Cycle count", "Year-end count").';
  end if;

  if not coalesce(p_dry_run, true) then
    v_transaction_no := nextval('public.ile_transaction_no_seq');
    v_doc_no := 'PHYS-' || lpad(v_transaction_no::text, 6, '0');
  end if;

  for v_row in
    select * from public._ile_phys_journal_rows(v_batch) r where r.qty_counted is not null
  loop
    if not coalesce(p_dry_run, true) then
      if coalesce(v_row.quantity, 0) <> 0 then
        perform public._ile_post(
          case when v_row.quantity > 0 then 'Positive Adjmt.' else 'Negative Adjmt.' end,
          v_row.item_code, v_row.variant_id, v_row.warehouse_id, v_row.quantity,
          coalesce(p_posting_date, public._ile_today()), 'Phys. Inventory', v_doc_no, trim(p_reason),
          v_transaction_no, p_admin_username
        );
      end if;
      v_ids := v_ids || v_row.line_id;
    end if;

    line_id := v_row.line_id; item_code := v_row.item_code; item_name := v_row.item_name;
    variant_id := v_row.variant_id; variant_name := v_row.variant_name;
    warehouse_id := v_row.warehouse_id; warehouse_name := v_row.warehouse_name;
    qty_calculated := v_row.qty_calculated; qty_counted := v_row.qty_counted; quantity := v_row.quantity;
    return next;
  end loop;

  if not coalesce(p_dry_run, true) and array_length(v_ids, 1) > 0 then
    delete from public."PhysInventoryJournalLines" where "LineID" = any(v_ids);
  end if;
end;
$$;

-- ============================================================================
-- 5. Pancake-live-stock helpers
-- ============================================================================

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
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_product_id is null or trim(p_product_id) = '' then
    return;
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');

  begin
    select * into v_response from extensions.http_get(
      v_base_url || '/shops/' || v_shop_id || '/products/' || p_product_id || '?api_key=' || v_api_key
    );
  exception when others then
    return;
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

create or replace function public.admin_apply_phys_journal_calculated_qty(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_updates jsonb
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
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
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

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Verification. Expect 10 rows, all has_anon_execute = true (unchanged grants -
-- create or replace doesn't touch existing grants).
-- ---------------------------------------------------------------------------
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_list_phys_journal_batches', 'admin_get_phys_journal_lines',
    'admin_calculate_phys_inventory', 'admin_add_phys_journal_line',
    'admin_set_phys_journal_qty', 'admin_delete_phys_journal_line',
    'admin_clear_phys_journal_batch', 'admin_post_phys_inventory_journal',
    'admin_get_pancake_stock_for_product', 'admin_apply_phys_journal_calculated_qty'
  )
order by p.proname;
