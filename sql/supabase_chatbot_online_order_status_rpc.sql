-- AI Messenger chatbot: look up an Online Order's status, extending the get_order_status tool
-- (supabase/functions/facebook-messenger-webhook) beyond the portal's own AutomatedOrders (format
-- AO-xxxxx, see supabase_automated_order_async_pancake_sync.sql's public_get_automated_order_status)
-- to also cover public."OnlineOrders" - the much bigger table of real Pancake customer orders
-- (see supabase_orders_sync_tables.sql), which is what most customers actually mean when they ask
-- "what's the status of my order."
--
-- Per direct decision: no ownership check against the Messenger conversation - same trust model as
-- get_order_status already uses for Automated Orders, and how most package-tracking flows work
-- ("knowing the order number is proof enough").
--
-- public."OnlineOrders"/"OnlineOrderLines" carry real customer PII (CustomerName, ShippingAddress,
-- Page_ID, Conversation_ID - see OnlineOrders' own header comment for why it's NOT opened to anon
-- wholesale). These RPCs deliberately return none of that - only what's needed to answer "what did I
-- order and what's the status": status, warehouse/location, item description + quantity per line,
-- total amount, and balance. status_label reuses the exact same bucket mapping as
-- admin_get_online_order_status_summary (Confirmed/Printed/To Ship/Shipped/Cancelled) so the bot
-- gives the customer the same friendly label staff see on the dashboard, falling back to the raw
-- stored Status only if it doesn't match any known bucket. Both exclude ReceivedAtShop = true
-- (in-store/walk-in orders) - a Messenger customer wouldn't have that kind of order number anyway,
-- same exclusion the dashboard summary functions already apply.
--
-- v2: per direct request, dropped EstimatedDeliveryDate/ForDelivery/AmountPaid from the header
-- result (not what the customer asked to see) and added warehouse_name (which branch the order was
-- placed from/at, same Warehouses join admin_list_online_orders already uses) plus a companion
-- public_get_online_order_lines() so the bot can list what was actually ordered (item + quantity)
-- alongside the total (MoneyToCollect) and balance.

drop function if exists public.public_get_online_order_status(text);

create or replace function public.public_get_online_order_status(p_order_id text)
returns table(
  order_id text,
  status_label text,
  warehouse_name text,
  money_to_collect numeric,
  balance numeric
)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select
    o."OrderID"::text,
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
    coalesce(w."Name"::text, o."LocationID"::text),
    o."MoneyToCollect",
    o."Balance"
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = trim(p_order_id)
    and o."ReceivedAtShop" is not true;
$$;

grant execute on function public.public_get_online_order_status(text) to anon;

drop function if exists public.public_get_online_order_lines(text);

-- Companion to public_get_online_order_status above - item name + quantity only, per direct
-- request ("Items Order with Quantity"). No unit price/cost/discount fields, matching the same
-- "only what's needed to answer the customer's question" discipline as the status RPC.
create or replace function public.public_get_online_order_lines(p_order_id text)
returns table(item_name text, quantity numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select coalesce(nullif(trim(ol."Description"), ''), ol."ItemCode")::text, ol."Quantity"
  from public."OnlineOrderLines" ol
  where ol."OrderID" = trim(p_order_id)
  order by ol."LineID";
$$;

grant execute on function public.public_get_online_order_lines(text) to anon;
