-- Item Vendor catalog - "some of my items has multiple vendors.. do we put the items under vendor
-- same as the BC approach". Yes: this is Business Central's Item Vendor Catalog (table 99),
-- adapted to the tables here.
--
-- TWO things, not one - the same split BC makes:
--
--   1. Items."VendorCode" stays the PRIMARY vendor. One per item, unchanged. Stock On Hand keeps
--      grouping by it (one row per item, under its primary vendor - per the direct decision to
--      follow BC here rather than listing an item once per vendor), Item Setup's vendor factbox
--      and its Excel import keep writing it, and every existing query keeps working.
--
--   2. public."ItemVendors" is the catalog of every OTHER vendor who can supply the item, with
--      that vendor's own item number, price and lead time.
--
-- What the catalog buys you:
--   - the Purchase Order item picker offers an item under every vendor that supplies it, not only
--     its primary one;
--   - a PO to vendor B prefills B's price rather than whatever was last paid to vendor A;
--   - the printed PO can carry the vendor's OWN item number, so they recognise what is ordered.

create table if not exists public."ItemVendors" (
    "ItemCode"     varchar(200) not null references public."Items"("Code") on delete cascade,
    "VendorCode"   varchar(50)  not null references public."Vendors"("VendorCode") on delete cascade,
    -- The vendor's own code for this item. Printed on the PO alongside your own item code.
    "VendorItemNo" varchar(100),
    -- This vendor's price. NULL means "no separate price for this vendor" and falls back to
    -- Items."Cost" - so seeding the catalog does not freeze a copy of a cost that later moves.
    "Cost"         numeric(18, 4),
    "LeadTimeDays" int,
    "Notes"        varchar(500),
    "UpdatedAtUtc" timestamptz not null default now(),
    primary key ("ItemCode", "VendorCode")
);

create index if not exists "IX_ItemVendors_VendorCode" on public."ItemVendors" ("VendorCode");

alter table public."ItemVendors" enable row level security;
revoke all on public."ItemVendors" from anon, authenticated;

-- Seed: every item that already has a primary vendor gets a catalog row for it, so the catalog is
-- complete from day one and "which vendors supply this?" never reads as empty for an item that
-- plainly has one. Cost is deliberately left NULL (see the column comment above).
insert into public."ItemVendors" ("ItemCode", "VendorCode")
select i."Code", i."VendorCode"
from public."Items" i
join public."Vendors" v on v."VendorCode" = i."VendorCode"
where i."VendorCode" is not null
on conflict ("ItemCode", "VendorCode") do nothing;

-- ============================================================================
-- staff_search_items: the vendor filter now matches the catalog as well as the primary tag, and
-- the cost it returns is THIS vendor's price when there is one.
--
-- Dropped by OID rather than by a hard-coded argument list - see
-- supabase_po_line_description_from_catalog.sql for why (an older overload that survives a
-- signature-specific drop makes every call ambiguous, PGRST203).
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
           count(*) over(),
           -- The price agreed with the vendor being ordered from, falling back to the item's own
           -- catalog cost. With no vendor in play (Transfer Orders' picker) the subquery is null
           -- and this is just Items."Cost", exactly as before.
           coalesce(
             (select iv."Cost"
              from public."ItemVendors" iv
              where iv."ItemCode" = i."Code" and iv."VendorCode" = p_vendor_code),
             i."Cost"
           ),
           nullif(trim(i."Description"), '')::text
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where (p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%')
      and (p_use_production_category is null or coalesce(c."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(c."ExcludeInTransferOrders", false)
      -- Primary tag OR catalog entry - this one clause is what makes a multi-vendor item
      -- orderable from every vendor that carries it.
      and (
        p_vendor_code is null or trim(p_vendor_code) = ''
        or i."VendorCode" = p_vendor_code
        or exists (
          select 1 from public."ItemVendors" iv
          where iv."ItemCode" = i."Code" and iv."VendorCode" = p_vendor_code
        )
      )
    order by i."Name"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

grant execute on function public.staff_search_items(text, text, text, int, boolean, int, text) to anon;

-- ============================================================================
-- Catalog maintenance, from Item Setup's factbox.
--
-- Reading is staff-level (the PO screens need it); editing is super-user only, matching
-- admin_set_item_vendor - vendor master data has always been super-user territory here.

drop function if exists public.staff_list_item_vendors(text, text, text);

create or replace function public.staff_list_item_vendors(p_admin_username text, p_admin_password text, p_item_code text)
returns table(vendor_code text, vendor_name text, vendor_item_no text, cost numeric, lead_time_days int, notes text, is_primary boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- is_primary is derived from Items."VendorCode" rather than stored - one source of truth for
  -- "the" vendor, so the two can never disagree.
  return query
    select iv."VendorCode"::text, v."Name"::text, iv."VendorItemNo"::text, iv."Cost",
           iv."LeadTimeDays", iv."Notes"::text,
           (i."VendorCode" = iv."VendorCode") as is_primary
    from public."ItemVendors" iv
    join public."Items" i on i."Code" = iv."ItemCode"
    left join public."Vendors" v on v."VendorCode" = iv."VendorCode"
    where iv."ItemCode" = p_item_code
    order by (i."VendorCode" = iv."VendorCode") desc, v."Name";
end;
$$;

grant execute on function public.staff_list_item_vendors(text, text, text) to anon;

drop function if exists public.admin_upsert_item_vendor(text, text, text, text, text, numeric, int, text);

create or replace function public.admin_upsert_item_vendor(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_vendor_code text,
  p_vendor_item_no text default null,
  p_cost numeric default null,
  p_lead_time_days int default null,
  p_notes text default null
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

  if not exists (select 1 from public."Items" where "Code" = p_item_code) then
    raise exception 'Item "%" not found.', p_item_code;
  end if;

  if not exists (select 1 from public."Vendors" where "VendorCode" = p_vendor_code) then
    raise exception 'Vendor "%" not found.', p_vendor_code;
  end if;

  if p_cost is not null and p_cost < 0 then
    raise exception 'Cost cannot be negative.';
  end if;

  insert into public."ItemVendors" ("ItemCode", "VendorCode", "VendorItemNo", "Cost", "LeadTimeDays", "Notes")
  values (
    p_item_code,
    p_vendor_code,
    nullif(trim(coalesce(p_vendor_item_no, '')), ''),
    p_cost,
    p_lead_time_days,
    nullif(trim(coalesce(p_notes, '')), '')
  )
  on conflict ("ItemCode", "VendorCode") do update
    set "VendorItemNo" = excluded."VendorItemNo",
        "Cost" = excluded."Cost",
        "LeadTimeDays" = excluded."LeadTimeDays",
        "Notes" = excluded."Notes",
        "UpdatedAtUtc" = now();
end;
$$;

grant execute on function public.admin_upsert_item_vendor(text, text, text, text, text, numeric, int, text) to anon;

drop function if exists public.admin_remove_item_vendor(text, text, text, text);

create or replace function public.admin_remove_item_vendor(p_admin_username text, p_admin_password text, p_item_code text, p_vendor_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Removing the primary here would leave Items."VendorCode" pointing at a vendor the catalog no
  -- longer lists, and would silently untag the item everywhere Stock On Hand groups by it. Make
  -- the caller choose a different primary first - an explicit step, not a side effect of a
  -- Remove button.
  if exists (select 1 from public."Items" where "Code" = p_item_code and "VendorCode" = p_vendor_code) then
    raise exception 'This is the item''s primary vendor. Set a different primary vendor first, or clear the item''s vendor tag.';
  end if;

  delete from public."ItemVendors" where "ItemCode" = p_item_code and "VendorCode" = p_vendor_code;
end;
$$;

grant execute on function public.admin_remove_item_vendor(text, text, text, text) to anon;

-- admin_set_item_vendor (the existing Item Setup factbox Save) now also files the chosen vendor in
-- the catalog. Setting a primary vendor who is not in the catalog would otherwise leave the two
-- views of the same fact disagreeing. Signature unchanged, so the page needs no change to keep
-- working.
drop function if exists public.admin_set_item_vendor(text, text, text, text);

create or replace function public.admin_set_item_vendor(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_vendor_code text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_vendor_code text := nullif(trim(coalesce(p_vendor_code, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."Items" set "VendorCode" = v_vendor_code where "Code" = p_item_code;

  if v_vendor_code is not null then
    insert into public."ItemVendors" ("ItemCode", "VendorCode")
    values (p_item_code, v_vendor_code)
    on conflict ("ItemCode", "VendorCode") do nothing;
  end if;

  -- Clearing the tag deliberately does NOT empty the catalog - the other vendors still supply the
  -- item, there just is no default any more.
end;
$$;

grant execute on function public.admin_set_item_vendor(text, text, text, text) to anon;

-- ============================================================================
-- Vendor Item No. on the Purchase Order lines, so the printed PO can show the vendor their own
-- code. Joined live against the catalog (keyed by the ORDER's vendor) rather than snapshot onto
-- the line: unlike a price, a vendor's item number is reference data, not a figure the order
-- commits to, and it is the vendor's CURRENT code that makes an order readable to them.

drop function if exists public.staff_list_purchase_order_lines(text, text, text);

create or replace function public.staff_list_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric, vendor_item_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- line_cost is computed here rather than in the browser so the PO total is derived one way
  -- only, and stays right for any other caller that reads these lines.
  return query
    select l."EntryNo", l."ItemCode"::text, l."ItemName"::text, l."WarehouseId"::text, l."WarehouseName"::text,
           l."Quantity", l."QtyReceived", l."Description"::text, l."UnitCost",
           round(coalesce(l."UnitCost", 0) * l."Quantity", 2),
           iv."VendorItemNo"::text
    from public."PurchaseOrderLines" l
    join public."PurchaseOrders" po on po."PONo" = l."PONo"
    left join public."ItemVendors" iv
      on iv."ItemCode" = l."ItemCode" and iv."VendorCode" = po."VendorCode"
    where l."PONo" = p_po_no
    order by l."EntryNo";
end;
$$;

grant execute on function public.staff_list_purchase_order_lines(text, text, text) to anon;

drop function if exists public.staff_list_posted_purchase_order_lines(text, text, text);

create or replace function public.staff_list_posted_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric, vendor_item_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Posted lines cost out against what was actually RECEIVED, not what was ordered - the archive
  -- is a record of money committed, and a short-shipped line did not cost the full ordered
  -- quantity. Open POs above use Quantity instead, since nothing has arrived yet.
  return query
    select l."EntryNo", l."ItemCode"::text, l."ItemName"::text, l."WarehouseId"::text, l."WarehouseName"::text,
           l."Quantity", l."QtyReceived", l."Description"::text, l."UnitCost",
           round(coalesce(l."UnitCost", 0) * coalesce(l."QtyReceived", 0), 2),
           iv."VendorItemNo"::text
    from public."PostedPurchaseOrderLines" l
    join public."PostedPurchaseOrders" po on po."PONo" = l."PONo"
    left join public."ItemVendors" iv
      on iv."ItemCode" = l."ItemCode" and iv."VendorCode" = po."VendorCode"
    where l."PONo" = p_po_no
    order by l."EntryNo";
end;
$$;

grant execute on function public.staff_list_posted_purchase_order_lines(text, text, text) to anon;

-- ============================================================================
-- Per-vendor last cost, kept current the same way Items."Cost" already is.
--
-- Posting a PO writes the cost actually paid back onto Items."Cost" (the last-cost writeback in
-- supabase_item_cost_and_po_line_cost.sql). With several vendors that single figure can only ever
-- be "whoever we bought from last", so the same writeback is mirrored per vendor here - otherwise
-- ItemVendors."Cost" would be a field nobody ever updates and the per-vendor prefill would drift.
--
-- Done as a trigger rather than by editing staff_post_purchase_order, for the same reason the
-- header-warehouse carry-over is (supabase_purchase_order_header_warehouse.sql): that function has
-- been redefined by four migrations already and the newest lives in the GL integration file, so
-- anything added to its body would be lost the next time one of those is re-run. Posting inserts
-- the PostedPurchaseOrders header before its lines, so the vendor is always resolvable here.
create or replace function public._item_vendor_cost_from_posted_line()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_vendor_code text;
begin
  -- Only a line that actually arrived, at a known cost, says anything about what this vendor
  -- charges - an ordered-but-undelivered line was never paid for.
  if new."UnitCost" is null or coalesce(new."QtyReceived", 0) <= 0 then
    return new;
  end if;

  select "VendorCode" into v_vendor_code
  from public."PostedPurchaseOrders"
  where "PONo" = new."PONo";

  if v_vendor_code is null then
    return new;
  end if;

  insert into public."ItemVendors" ("ItemCode", "VendorCode", "Cost")
  values (new."ItemCode", v_vendor_code, new."UnitCost")
  on conflict ("ItemCode", "VendorCode") do update
    set "Cost" = excluded."Cost",
        "UpdatedAtUtc" = now();

  return new;
end;
$$;

drop trigger if exists "TR_PostedPurchaseOrderLines_ItemVendorCost" on public."PostedPurchaseOrderLines";
create trigger "TR_PostedPurchaseOrderLines_ItemVendorCost"
after insert on public."PostedPurchaseOrderLines"
for each row execute function public._item_vendor_cost_from_posted_line();

notify pgrst, 'reload schema';

-- ============================================================================
-- Verification.

-- One row per function. staff_search_items must appear ONCE - more than one and PostgREST cannot
-- choose between them (PGRST203).
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'staff_search_items',
    'staff_list_item_vendors',
    'admin_upsert_item_vendor',
    'admin_remove_item_vendor',
    'admin_set_item_vendor',
    'staff_list_purchase_order_lines',
    'staff_list_posted_purchase_order_lines'
  )
order by p.proname, arguments;

-- How the catalog seeded. items_with_primary_vendor and catalog_rows should match right after
-- this runs (one row per tagged item); items_with_multiple_vendors grows as you add alternates.
select
  (select count(*) from public."Items" where "VendorCode" is not null) as items_with_primary_vendor,
  (select count(*) from public."ItemVendors") as catalog_rows,
  (select count(*) from (
     select "ItemCode" from public."ItemVendors" group by "ItemCode" having count(*) > 1
   ) as m) as items_with_multiple_vendors;
