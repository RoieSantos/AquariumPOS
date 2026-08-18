-- Per direct request: a per-item toggle to keep a specific item out of the Order Now "SET"
-- listing (public_list_order_items, see supabase_automated_orders_tables.sql) without touching
-- its CategoryCode or IsActive - those are synced from Pancake every 5 minutes and would just get
-- overwritten back. This new column is local-only, same pattern as Items."VendorCode" (see
-- supabase_vendor_tables.sql) - never written by the Pancake sync, only by the RPC below, edited
-- from the Item Setup factbox (docs/item-setup.html / docs/js/itemSetup.js).

alter table public."Items" add column if not exists "HideFromSet" boolean not null default false;

-- Order Now's item listing (any category, not just SET) now skips anything flagged this way.
drop function if exists public.public_list_order_items(text);

create or replace function public.public_list_order_items(p_category_code text)
returns table(code text, name text, description text, price numeric, images text, quantity_in_stock int)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select
    i."Code"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text,
    i."Description"::text,
    coalesce(i."RetailPrice", i."Price", 0)::numeric,
    i."Images"::text,
    i."QuantityInStock"
  from public."Items" i
  where i."IsActive" is true
    and trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
    and i."HideFromSet" is not true
  order by 2;
$$;

grant execute on function public.public_list_order_items(text) to anon;

-- ---------------------------------------------------------------------------
-- Item Setup factbox toggle (super users only, same auth as every other admin_* Items RPC).
-- ---------------------------------------------------------------------------

drop function if exists public.admin_set_item_hide_from_set(text, text, text, boolean);

create or replace function public.admin_set_item_hide_from_set(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_hide_from_set boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."Items" set "HideFromSet" = coalesce(p_hide_from_set, false) where "Code" = p_item_code;
end;
$$;

grant execute on function public.admin_set_item_hide_from_set(text, text, text, boolean) to anon;

-- Widen admin_list_items (Item Setup's own list) to also expose the flag, so the factbox
-- checkbox reflects the current value on open. Return columns are widening, so this needs the
-- explicit drop (Postgres 42P13 "cannot change return type of existing function").
drop function if exists public.admin_list_items(text, text, text, int, int);

create or replace function public.admin_list_items(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50)
returns table(
  code text,
  name text,
  description text,
  cost numeric,
  price numeric,
  wholesale_price numeric,
  retail_price numeric,
  promo_price numeric,
  category_code text,
  brand text,
  sku text,
  quantity_in_stock int,
  minimum_stock int,
  is_active boolean,
  images text,
  synced_at_utc timestamptz,
  vendor_code text,
  vendor_name text,
  hide_from_set boolean,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text, i."Name"::text, i."Description"::text, i."Cost", i."Price", i."WholesalePrice", i."RetailPrice", i."PromoPrice",
           i."CategoryCode"::text, i."Brand"::text, i."SKU"::text, i."QuantityInStock", i."MinimumStock", i."IsActive", i."Images"::text, i."SyncedAtUtc",
           i."VendorCode"::text, v."Name"::text, i."HideFromSet",
           count(*) over()
    from public."Items" i
    left join public."Vendors" v on v."VendorCode" = i."VendorCode"
    where p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%'
    order by i."Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_items(text, text, text, int, int) to anon;
