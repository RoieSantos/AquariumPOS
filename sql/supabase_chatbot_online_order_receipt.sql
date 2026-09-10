-- Public (no-login), customer-facing Online Order receipt - backs docs/online-order-receipt.html,
-- linked to by the AI Messenger chatbot (supabase/functions/facebook-messenger-webhook) when a
-- customer asks for a receipt/proof of their order. Per direct decision: there is no way to render
-- an actual image/PDF server-side in this stack without adding a paid third-party rendering
-- service, so the bot shares a LINK to this page instead (same pattern as docs/track-driver.html) -
-- the customer can open it, screenshot it, or print it themselves.
--
-- Deliberately its own function, not a reuse of admin_get_delivery_receipt (supabase_delivery_
-- receipt.sql): that one requires real staff login (is_staff_authorized) and is keyed by an
-- internal DeliveryStops.StopID, neither of which a Messenger customer has. This one is keyed
-- directly by the OrderID the customer already has, with NO staff auth and NO ownership check -
-- same trust model as public_get_online_order_status (supabase_chatbot_online_order_status_rpc.sql)
-- and the same explicit call already made there: knowing the order number is treated as proof
-- enough.
--
-- Per direct decision, this DOES include CustomerName/ShippingAddress (a real receipt needs to say
-- who it's for and where it shipped) - more than public_get_online_order_status exposes today.
-- Deliberately does NOT include ShippingPhone - not asked for, kept out to avoid exposing more PII
-- than necessary; add it later if it turns out to be needed. Excludes ReceivedAtShop = true
-- (in-store/walk-in orders), same exclusion used throughout the Online Orders RPCs.
--
-- Same flat "one row per line, header fields repeated" shape as admin_get_delivery_receipt so the
-- client can render it the same way - line_no IS NULL is the sentinel for "this order has no synced
-- lines yet" so the header still renders.
--
-- v2: added note_print (OnlineOrders."NotePrint" - the order-level print note, e.g. general
-- delivery instructions) and line_note (OnlineOrderLines."Note" - a per-product note, e.g. a custom
-- aquarium's dimensions/sealant spec) per direct request to show "all the notes captured in the
-- order" - same two note fields/same header-vs-per-line split admin_get_delivery_receipt already
-- exposes to staff.

drop function if exists public.public_get_online_order_receipt(text);

create or replace function public.public_get_online_order_receipt(p_order_id text)
returns table(
  order_id text,
  order_date date,
  customer_name text,
  shipping_address text,
  status_label text,
  warehouse_name text,
  warehouse_address text,
  delivery_fee numeric,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  note_print text,
  line_no int,
  line_description text,
  line_quantity numeric,
  line_amount numeric,
  line_note text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_date date;
  v_customer_name text;
  v_shipping_address text;
  v_status_label text;
  v_warehouse_name text;
  v_warehouse_address text;
  v_delivery_fee numeric;
  v_money_to_collect numeric;
  v_amount_paid numeric;
  v_discount numeric;
  v_balance numeric;
  v_note_print text;
  v_order_id text := trim(p_order_id);
  v_line record;
  v_line_no int := 0;
begin
  select
    o."Date", o."CustomerName"::text, o."ShippingAddress"::text,
    coalesce(
      case
        when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted') then 'Confirmed'
        when lower(trim(coalesce(o."Status", ''))) = 'printed' then 'Printed'
        when lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed') then 'To Ship'
        when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2') then 'Shipped'
        when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
        else null
      end,
      o."Status"
    )::text,
    w."Name"::text, w."Address"::text,
    o."DeliveryFee", o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance",
    nullif(trim(o."NotePrint"::text), '')
    into v_order_date, v_customer_name, v_shipping_address, v_status_label,
         v_warehouse_name, v_warehouse_address,
         v_delivery_fee, v_money_to_collect, v_amount_paid, v_discount, v_balance, v_note_print
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = v_order_id
    and o."ReceivedAtShop" is not true;

  if not found then
    return;
  end if;

  for v_line in
    select l."Description"::text as description, l."Quantity" as quantity,
           coalesce(l."GrossAmount", l."NetAmount", l."Price" * l."Quantity") as amount,
           nullif(trim(l."Note"::text), '') as note
    from public."OnlineOrderLines" l
    where l."OrderID" = v_order_id
    order by l."LineID"
  loop
    v_line_no := v_line_no + 1;
    order_id := v_order_id;
    order_date := v_order_date;
    customer_name := v_customer_name;
    shipping_address := v_shipping_address;
    status_label := v_status_label;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    delivery_fee := v_delivery_fee;
    money_to_collect := v_money_to_collect;
    amount_paid := v_amount_paid;
    discount := v_discount;
    balance := v_balance;
    note_print := v_note_print;
    line_no := v_line_no;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_amount := v_line.amount;
    line_note := v_line.note;
    return next;
  end loop;

  if v_line_no = 0 then
    order_id := v_order_id;
    order_date := v_order_date;
    customer_name := v_customer_name;
    shipping_address := v_shipping_address;
    status_label := v_status_label;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    delivery_fee := v_delivery_fee;
    money_to_collect := v_money_to_collect;
    amount_paid := v_amount_paid;
    discount := v_discount;
    balance := v_balance;
    note_print := v_note_print;
    line_no := null;
    line_description := null;
    line_quantity := null;
    line_amount := null;
    line_note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.public_get_online_order_receipt(text) to anon;
