-- Purchase Order Payment Method (Cash/Online), per direct request: "my business process is pay
-- first before receiving the item.. can we add a payment method on the PO so I can track how it
-- is get paid".
--
-- Deliberately a plain tag on the PO header, not a full accounts-payable entry - this codebase
-- already has a fuller VendorBills/VendorPayments system (supabase_vendor_tables.sql, complete
-- with its own Method/Amount/Date/Reference No. and vendor balance rollups), but that's
-- super-user-only and has nothing linking it to a Purchase Order. What's asked for here is
-- simpler: a label staff can see at a glance on the PO itself, matching how lightweight the rest
-- of this PO feature already is (see supabase_purchase_orders.sql's own header comment).
--
-- Editable independently of PO creation (its own RPC, not folded into staff_create_purchase_order)
-- because the real order of operations here is create the PO, pay it, THEN receive the goods -
-- staff need to set/change this on an already-open PO, not only at the moment it's created.
-- staff_create_purchase_order is also, as of this session, several migrations deep (item cost,
-- line description, line variant, units of measure all redefine it) - routing a new required
-- field through its body risks silently dropping one of those. A separate small RPC avoids that
-- risk entirely.

alter table public."PurchaseOrders" add column if not exists "PaymentMethod" varchar(20);
alter table public."PostedPurchaseOrders" add column if not exists "PaymentMethod" varchar(20);

alter table public."PurchaseOrders" drop constraint if exists "CK_PurchaseOrders_PaymentMethod";
alter table public."PurchaseOrders"
  add constraint "CK_PurchaseOrders_PaymentMethod" check ("PaymentMethod" is null or "PaymentMethod" in ('Cash', 'Online'));

alter table public."PostedPurchaseOrders" drop constraint if exists "CK_PostedPurchaseOrders_PaymentMethod";
alter table public."PostedPurchaseOrders"
  add constraint "CK_PostedPurchaseOrders_PaymentMethod" check ("PaymentMethod" is null or "PaymentMethod" in ('Cash', 'Online'));

-- Carried into the posted archive the same way the header Warehouse is (see
-- _posted_purchase_order_fill_warehouse in supabase_purchase_order_header_warehouse.sql) - a
-- trigger rather than editing staff_post_purchase_order's INSERT, for the same reason: that
-- function has been redefined by several migrations since and re-running any of them would
-- silently drop a column added to its INSERT list here.
create or replace function public._posted_purchase_order_fill_payment_method()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new."PaymentMethod" is null then
    select po."PaymentMethod"
      into new."PaymentMethod"
    from public."PurchaseOrders" po
    where po."PONo" = new."PONo";
  end if;

  return new;
end;
$$;

drop trigger if exists "TR_PostedPurchaseOrders_FillPaymentMethod" on public."PostedPurchaseOrders";
create trigger "TR_PostedPurchaseOrders_FillPaymentMethod"
before insert on public."PostedPurchaseOrders"
for each row execute function public._posted_purchase_order_fill_payment_method();

drop function if exists public.staff_set_purchase_order_payment_method(text, text, text, text);

-- Any active staff (same trust level as everything else on this page - see
-- supabase_purchase_orders.sql's own header comment) may set/change this on an OPEN Purchase
-- Order; a posted one is a permanent archive record with no editor for it. A null/blank
-- p_payment_method clears it back to unset.
create or replace function public.staff_set_purchase_order_payment_method(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_payment_method text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_payment_method text := nullif(trim(coalesce(p_payment_method, '')), '');
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_payment_method is not null and v_payment_method not in ('Cash', 'Online') then
    raise exception 'Payment Method must be Cash or Online.';
  end if;

  if not exists (select 1 from public."PurchaseOrders" where "PONo" = p_po_no) then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  update public."PurchaseOrders" set "PaymentMethod" = v_payment_method where "PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_set_purchase_order_payment_method(text, text, text, text) to anon;

-- The four header readers below all gain payment_method, appended last so any caller that doesn't
-- know about it yet keeps working unchanged - same convention as
-- supabase_purchase_order_header_warehouse.sql's own widening of these same four functions. Bodies
-- are reproduced from that migration (still the latest definition of all four - nothing since has
-- touched them) plus the new column.
drop function if exists public.staff_get_purchase_order(text, text, text);

create or replace function public.staff_get_purchase_order(p_admin_username text, p_admin_password text, p_po_no text)
returns table(po_no text, vendor_code text, vendor_name text, order_date date, notes text, created_by text, created_at_utc timestamptz, warehouse_id text, warehouse_name text, payment_method text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
           po."CreatedBy"::text, po."CreatedAtUtc", po."WarehouseId"::text, po."WarehouseName"::text,
           po."PaymentMethod"::text
    from public."PurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    where po."PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_get_purchase_order(text, text, text) to anon;

drop function if exists public.staff_list_purchase_orders(text, text, text, int, int);

create or replace function public.staff_list_purchase_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  po_no text,
  vendor_code text,
  vendor_name text,
  order_date date,
  notes text,
  created_by text,
  created_at_utc timestamptz,
  line_count bigint,
  total_quantity numeric,
  total_received_quantity numeric,
  total_count bigint,
  warehouse_name text,
  payment_method text
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

  -- total_received_quantity: restored here after being accidentally dropped when
  -- supabase_purchase_order_header_warehouse.sql widened this function for the Warehouse column -
  -- that migration was built from the pre-receiving version of staff_list_purchase_orders and
  -- silently lost the sum(QtyReceived) supabase_purchase_order_receiving.sql had added, which is
  -- what the list page's "Fully Received"/"Not Received" badge (receivedBadgeHtml in
  -- js/purchaseOrders.js) reads. Every PO's badge has been reading total_received_quantity as
  -- undefined (-> 0 -> always "Not Received") since that migration, regardless of what was
  -- actually received.
  return query
    select
      po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
      po."CreatedBy"::text, po."CreatedAtUtc",
      count(l."EntryNo"), coalesce(sum(l."Quantity"), 0), coalesce(sum(l."QtyReceived"), 0),
      count(*) over(),
      po."WarehouseName"::text,
      po."PaymentMethod"::text
    from public."PurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    left join public."PurchaseOrderLines" l on l."PONo" = po."PONo"
    where p_search is null or trim(p_search) = ''
      or po."PONo" ilike '%' || p_search || '%'
      or v."Name" ilike '%' || p_search || '%'
      or po."WarehouseName" ilike '%' || p_search || '%'
    group by po."PONo", po."VendorCode", v."Name", po."OrderDate", po."Notes", po."CreatedBy", po."CreatedAtUtc", po."WarehouseName", po."PaymentMethod"
    order by po."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.staff_list_purchase_orders(text, text, text, int, int) to anon;

drop function if exists public.staff_get_posted_purchase_order(text, text, text);

create or replace function public.staff_get_posted_purchase_order(p_admin_username text, p_admin_password text, p_po_no text)
returns table(po_no text, vendor_code text, vendor_name text, order_date date, notes text, created_by text, created_at_utc timestamptz, posted_by text, posted_at_utc timestamptz, warehouse_id text, warehouse_name text, payment_method text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
           po."CreatedBy"::text, po."CreatedAtUtc", po."PostedBy"::text, po."PostedAtUtc",
           po."WarehouseId"::text, po."WarehouseName"::text, po."PaymentMethod"::text
    from public."PostedPurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    where po."PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_get_posted_purchase_order(text, text, text) to anon;

drop function if exists public.staff_list_posted_purchase_orders(text, text, text, int, int);

create or replace function public.staff_list_posted_purchase_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  po_no text,
  vendor_code text,
  vendor_name text,
  order_date date,
  notes text,
  created_by text,
  created_at_utc timestamptz,
  posted_by text,
  posted_at_utc timestamptz,
  line_count bigint,
  total_quantity numeric,
  total_received_quantity numeric,
  total_count bigint,
  warehouse_name text,
  payment_method text
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
    select
      po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
      po."CreatedBy"::text, po."CreatedAtUtc", po."PostedBy"::text, po."PostedAtUtc",
      count(l."EntryNo"), coalesce(sum(l."Quantity"), 0), coalesce(sum(l."QtyReceived"), 0),
      count(*) over(),
      po."WarehouseName"::text,
      po."PaymentMethod"::text
    from public."PostedPurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    left join public."PostedPurchaseOrderLines" l on l."PONo" = po."PONo"
    where p_search is null or trim(p_search) = ''
      or po."PONo" ilike '%' || p_search || '%'
      or v."Name" ilike '%' || p_search || '%'
      or po."WarehouseName" ilike '%' || p_search || '%'
    group by po."PONo", po."VendorCode", v."Name", po."OrderDate", po."Notes", po."CreatedBy", po."CreatedAtUtc", po."PostedBy", po."PostedAtUtc", po."WarehouseName", po."PaymentMethod"
    order by po."PostedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.staff_list_posted_purchase_orders(text, text, text, int, int) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect one row per function - more than one for any of the four read functions
-- means an older overload survived and PostgREST will not be able to choose between them.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'staff_set_purchase_order_payment_method',
    'staff_get_purchase_order',
    'staff_list_purchase_orders',
    'staff_get_posted_purchase_order',
    'staff_list_posted_purchase_orders'
  )
order by p.proname, arguments;
