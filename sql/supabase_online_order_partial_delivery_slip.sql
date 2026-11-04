-- Online Orders: printable Partial Delivery Slip per release batch - per "build me a report for an advance
-- order.. they partially send over the items to the customer.. and right now they are sending over the
-- other half but there will be one more item that left to deliver".
--
-- Feeds docs/partial-delivery.html (?order=<OrderID>&batch=<n>; no batch = the latest). One row per order
-- line, header columns repeated on every row (same shape as admin_get_delivery_receipt):
--   ordered_qty      - the line's quantity
--   delivered_before - released in batches BEFORE this one
--   this_batch_qty   - released in THIS batch
--   remaining_qty    - still to deliver after this batch
-- Batch data comes from OnlineOrderLineReleases (supabase_online_order_partial_release.sql). Read-only.
-- advance_order_no is the portal AO- number linked to the online order, if any.
-- Works for ANY status ("but this one status is delivered"): an order never released in batches returns
-- batch_no 0 / zero quantities, and the page lets staff type Delivered Before / This Delivery (print only).
--
-- Also staff_get_advance_order_delivery_slip (bottom) for POS Advance Orders - typed quantities only.
--
-- Run AFTER supabase_online_order_partial_release.sql and supabase_advance_orders_sales_user_all_branches.sql.
-- Safe to re-run.

drop function if exists public.staff_get_online_order_partial_delivery_slip(text, text, text, int);

create or replace function public.staff_get_online_order_partial_delivery_slip(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_batch_no int default null
)
returns table(
  order_id text,
  advance_order_no text,
  order_date date,
  customer_name text,
  shipping_address text,
  shipping_phone text,
  warehouse_name text,
  warehouse_address text,
  money_to_collect numeric,
  amount_paid numeric,
  balance numeric,
  batch_no int,
  last_batch_no int,
  released_at timestamptz,
  released_by_name text,
  batch_note text,
  line_no int,
  item_code text,
  description text,
  line_note text,
  ordered_qty numeric,
  delivered_before numeric,
  this_batch_qty numeric,
  remaining_qty numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_last int;
  v_batch int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."OnlineOrders" o where o."OrderID" = p_order_id) then
    raise exception 'Order % not found.', p_order_id;
  end if;

  -- No release batches (e.g. an order already Delivered, never released in batches): every line comes back
  -- with batch_no 0 and zero quantities - the slip page then lets staff type the quantities (not saved).
  select coalesce(max(r."BatchNo"), 0) into v_last from public."OnlineOrderLineReleases" r where r."OrderID" = p_order_id;

  v_batch := coalesce(p_batch_no, v_last);
  if v_batch > 0 and not exists (select 1 from public."OnlineOrderLineReleases" r where r."OrderID" = p_order_id and r."BatchNo" = v_batch) then
    raise exception 'Order % has no release batch #%.', p_order_id, v_batch;
  end if;

  return query
    with b as (
      select min(r."ReleasedAtUtc") as at, min(r."ReleasedBy") as by_user, max(r."Note") as note
      from public."OnlineOrderLineReleases" r
      where r."OrderID" = p_order_id and r."BatchNo" = v_batch
    ),
    rel as (
      select r."LineID",
             sum(r."Quantity") filter (where r."BatchNo" < v_batch) as before_qty,
             sum(r."Quantity") filter (where r."BatchNo" = v_batch) as this_qty
      from public."OnlineOrderLineReleases" r
      where r."OrderID" = p_order_id and r."BatchNo" <= v_batch
      group by r."LineID"
    )
    select o."OrderID"::text,
           (select ao."OrderNo"::text from public."AutomatedOrders" ao
             where ao."PancakeReceiptNo" = o."OrderID" order by ao."OrderNo" desc limit 1),
           o."Date",
           o."CustomerName"::text,
           o."ShippingAddress"::text,
           o."ShippingPhone"::text,
           w."Name"::text,
           w."Address"::text,
           o."MoneyToCollect",
           o."AmountPaid",
           o."Balance",
           v_batch,
           v_last,
           b.at,
           coalesce(nullif(trim(s."DisplayName"), ''), b.by_user)::text,
           b.note::text,
           (row_number() over (order by l."LineID"))::int,
           l."ItemCode"::text,
           coalesce(nullif(trim(l."Description"), ''), l."ItemCode")::text,
           nullif(trim(l."Note"::text), ''),
           coalesce(l."Quantity", 1),
           coalesce(rel.before_qty, 0),
           coalesce(rel.this_qty, 0),
           greatest(coalesce(l."Quantity", 1) - coalesce(rel.before_qty, 0) - coalesce(rel.this_qty, 0), 0)
    from public."OnlineOrders" o
    join public."OnlineOrderLines" l on l."OrderID" = o."OrderID" and coalesce(l."Quantity", 1) > 0
    left join rel on rel."LineID" = l."LineID"
    left join public."Warehouses" w on w."ID" = o."LocationID"
    cross join b
    left join public."StaffUsers" s on s."Username" = b.by_user
    where o."OrderID" = p_order_id
    order by l."LineID";
end;
$$;

grant execute on function public.staff_get_online_order_partial_delivery_slip(text, text, text, int) to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Advance Orders (POS AdvanceOrders, "also this is under advance orders"): they have no partial release,
-- so the slip page takes the quantities typed by staff (print only, nothing saved). This just returns the
-- header + item lines (quantity > 0). Same view rule as the Advance Order document (_advance_order_can_view).
drop function if exists public.staff_get_advance_order_delivery_slip(text, text, text);

create or replace function public.staff_get_advance_order_delivery_slip(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(
  transaction_no text,
  receipt_no text,
  online_order_id text,
  order_date date,
  customer_name text,
  customer_address text,
  customer_mobile text,
  warehouse_name text,
  order_description text,
  net_amount numeric,
  balance numeric,
  fully_paid boolean,
  line_no int,
  item_code text,
  description text,
  ordered_qty numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_view(p_admin_username, p_no) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."AdvanceOrders" a where a."TransactionNo" = p_no) then
    raise exception 'Advance order % not found.', p_no;
  end if;

  return query
    select a."TransactionNo"::text, a."ReceiptNo"::text, a."OnlineOrderID"::text, a."Date",
           a."CustomerName"::text, a."CustomerAddress"::text, a."CustomerMobile"::text, a."Warehouse"::text,
           a."Order_Description"::text, a."NetAmount", a."Balance",
           coalesce(a."FullyPaid", false) or coalesce(a."Balance", 0) <= 0,
           (row_number() over (order by case when l."LineNo" ~ '^\d+$' then l."LineNo"::numeric end nulls last, l."LineNo"))::int,
           l."No"::text,
           coalesce(nullif(trim(l."Description"), ''), l."No")::text,
           l."Quantity"
    from public."AdvanceOrders" a
    join public."AdvanceOrderLines" l on l."TransactionNo" = a."TransactionNo" and coalesce(l."Quantity", 0) > 0
    where a."TransactionNo" = p_no
    order by case when l."LineNo" ~ '^\d+$' then l."LineNo"::numeric end nulls last, l."LineNo";
end;
$$;

grant execute on function public.staff_get_advance_order_delivery_slip(text, text, text) to anon;

notify pgrst, 'reload schema';
