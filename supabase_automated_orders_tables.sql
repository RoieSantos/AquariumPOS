-- "Automated Orders": customer-submitted order requests from the public, no-login order wizard
-- (docs/order-now.html / js/orderNow.js). A customer picks a category (Aquarium/Stand/Filtration/
-- Sump/Fish/etc, sourced live from Items/Categories), adds items + quantities to a cart, enters
-- contact + pickup/delivery info, and submits - landing here as its own table (per direct request:
-- "I want a separate table, Automated Orders"), NOT into OnlineOrders (that table is a one-way
-- Pancake sync mirror - see supabase_orders_sync_tables.sql - not something a customer wizard
-- should write into).
--
-- Unlike supabase_allow_anon_order_sync.sql's emergency stop-gap (full anon select/insert/update
-- on Pancake-order tables, explicitly flagged there as a workaround not a design), this is a
-- narrow, intentional public-insert surface: anon gets ONLY an insert-only, validating RPC
-- (submit_automated_order) plus two read-only catalog lookups (public_list_order_categories/
-- public_list_order_items) that expose nothing but active items' name/price/image. Direct table
-- access stays fully revoked from anon/authenticated; staff read/update goes through the usual
-- is_staff_authorized-gated admin_* RPCs (same trust model as Online Orders/Delivery - open to any
-- active staff login, not just super users, so requests get followed up on quickly).

create table if not exists public."AutomatedOrders" (
    "OrderNo" varchar(50) primary key,
    "CustomerName" varchar(200) not null,
    "CustomerPhone" varchar(50) not null,
    "CustomerEmail" varchar(200),
    "FulfillmentType" varchar(20) not null default 'Pickup',
    "DeliveryAddress" varchar(500),
    "Notes" varchar(1000),
    "Status" varchar(30) not null default 'New',
    "EstimatedTotal" numeric(18, 4) not null default 0,
    "CreatedAtUtc" timestamptz not null default now(),
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

create table if not exists public."AutomatedOrderLines" (
    "EntryNo" bigint generated always as identity primary key,
    "OrderNo" varchar(50) not null references public."AutomatedOrders"("OrderNo") on delete cascade,
    "CategoryCode" varchar(100),
    "ItemCode" varchar(200),
    "ItemName" varchar(255) not null,
    "Quantity" int not null default 1,
    "Price" numeric(18, 4) not null default 0
);

create index if not exists "IX_AutomatedOrderLines_OrderNo" on public."AutomatedOrderLines" ("OrderNo");

alter table public."AutomatedOrders" enable row level security;
alter table public."AutomatedOrderLines" enable row level security;
revoke all on public."AutomatedOrders" from anon, authenticated;
revoke all on public."AutomatedOrderLines" from anon, authenticated;

comment on table public."AutomatedOrders" is 'Customer-submitted order requests from the public order wizard (order-now.html) - a lead/request queue staff action manually, separate from the Pancake-synced OnlineOrders table.';
comment on table public."AutomatedOrderLines" is 'Line items for an AutomatedOrders request. Price/ItemName are snapshotted at submission time so the request stays accurate even if Items catalog prices change later.';

insert into public."NoSeries" ("SeriesCode", "Description", "Prefix", "Padding", "StartingNo", "WarehouseScoped")
select 'AUTOMATED-ORDER', 'Automated Order request number (customer order wizard)', 'AO-', 5, 1, false
where not exists (select 1 from public."NoSeries" where "SeriesCode" = 'AUTOMATED-ORDER');

-- ---------------------------------------------------------------------------
-- Public (anon, no login) catalog lookups - deliberately narrow: only Code/Name/Description/
-- Price/Images/QuantityInStock ever leave the server, never Cost/WholesalePrice/PromoPrice/etc
-- (same "pricing data stays behind a narrow view" intent as staff_list_items_by_category, just
-- taken one step further since these two are reachable with NO credentials at all).
-- ---------------------------------------------------------------------------

drop function if exists public.public_list_order_categories();

-- Every category is offered as a wizard button (per direct request: "I want to be able to show
-- all the categories in buttons") - a category with no active items right now just shows the
-- "No items available" empty state in step 2 (js/orderNow.js) rather than disappearing from
-- step 1 entirely.
create or replace function public.public_list_order_categories()
returns table(code text, description text)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select c."Code"::text, coalesce(nullif(trim(c."Description"), ''), c."Code")::text
  from public."Categories" c
  order by 2;
$$;

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
  order by 2;
$$;

-- ---------------------------------------------------------------------------
-- Public (anon, no login) order submission - the only write path into AutomatedOrders/Lines.
-- Insert-only: builds and validates the whole request server-side rather than granting anon any
-- direct table insert, so a caller can never read back or edit someone else's request.
-- ---------------------------------------------------------------------------

drop function if exists public.submit_automated_order(text, text, text, text, text, text, jsonb);

-- p_lines: jsonb array of {"category_code","item_code","item_name","quantity","price"} - built
-- client-side from the wizard's cart (js/orderNow.js). item_name/price are trusted from the
-- client only as a display snapshot; nothing here grants pricing authority, this is a request
-- queue staff review and action manually (fulfillment/final pricing happens off this table).
create or replace function public.submit_automated_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_lines jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_line_count int := 0;
begin
  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  if v_fulfillment not in ('Pickup', 'Delivery') then
    raise exception 'Fulfillment type must be Pickup or Delivery.';
  end if;
  if v_fulfillment = 'Delivery' and (p_delivery_address is null or trim(p_delivery_address) = '') then
    raise exception 'Delivery address is required for delivery orders.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one item is required.';
  end if;

  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  insert into public."AutomatedOrders"
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status", "EstimatedTotal")
  values
    (v_order_no, trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price")
    values
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price);

    v_total := v_total + (v_qty * v_price);
    v_line_count := v_line_count + 1;
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = v_order_no;

  return v_order_no;
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff-facing read/update (docs/automated-orders.html / js/automatedOrders.js) - open to any
-- active staff login, same tier as admin_list_online_orders/Delivery, since a fast follow-up
-- with the customer matters more than restricting this to super users.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_automated_orders(text, text, text, text, int, int);

create or replace function public.admin_list_automated_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  order_no text,
  customer_name text,
  customer_phone text,
  customer_email text,
  fulfillment_type text,
  delivery_address text,
  notes text,
  status text,
  estimated_total numeric,
  created_at_utc timestamptz,
  updated_by text,
  updated_at_utc timestamptz,
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
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."OrderNo"::text, o."CustomerName"::text, o."CustomerPhone"::text, o."CustomerEmail"::text,
           o."FulfillmentType"::text, o."DeliveryAddress"::text, o."Notes"::text, o."Status"::text,
           o."EstimatedTotal", o."CreatedAtUtc", o."UpdatedBy"::text, o."UpdatedAtUtc",
           count(*) over()
    from public."AutomatedOrders" o
    where (p_status is null or trim(p_status) = '' or o."Status" ilike p_status)
      and (
        p_search is null or trim(p_search) = ''
        or o."OrderNo" ilike '%' || p_search || '%'
        or o."CustomerName" ilike '%' || p_search || '%'
        or o."CustomerPhone" ilike '%' || p_search || '%'
      )
    order by o."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_list_automated_order_lines(text, text, text);

create or replace function public.admin_list_automated_order_lines(p_admin_username text, p_admin_password text, p_order_no text)
returns table(entry_no bigint, category_code text, item_code text, item_name text, quantity int, price numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."EntryNo", l."CategoryCode"::text, l."ItemCode"::text, l."ItemName"::text, l."Quantity", l."Price"
    from public."AutomatedOrderLines" l
    where l."OrderNo" = p_order_no
    order by l."EntryNo";
end;
$$;

drop function if exists public.admin_update_automated_order_status(text, text, text, text);

create or replace function public.admin_update_automated_order_status(p_admin_username text, p_admin_password text, p_order_no text, p_status text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_status not in ('New', 'Contacted', 'Confirmed', 'Completed', 'Cancelled') then
    raise exception 'Invalid status.';
  end if;

  update public."AutomatedOrders"
    set "Status" = p_status, "UpdatedBy" = p_admin_username, "UpdatedAtUtc" = now()
    where "OrderNo" = p_order_no;
end;
$$;

grant execute on function public.public_list_order_categories() to anon;
grant execute on function public.public_list_order_items(text) to anon;
grant execute on function public.submit_automated_order(text, text, text, text, text, text, jsonb) to anon;
grant execute on function public.admin_list_automated_orders(text, text, text, text, int, int) to anon;
grant execute on function public.admin_list_automated_order_lines(text, text, text) to anon;
grant execute on function public.admin_update_automated_order_status(text, text, text, text) to anon;
