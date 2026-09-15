-- Per direct follow-up request: the GMA Conversations order card's status control (see
-- orderStatusSelectHtml in gmaConversations.js) edits AutomatedOrders.Status (New/Contacted/
-- Confirmed/Completed/Cancelled) - a simple pre-Pancake staging status, NOT the real fulfillment
-- status (Confirmed/Printed/To Ship/Shipped/Cancelled) tracked on the synced OnlineOrders row once
-- Pancake actually has the order. Those are two separate tables/lifecycles (OnlineOrders is a
-- one-way Pancake sync mirror - see supabase_orders_sync_tables.sql's header comment - and its
-- status can't be freely edited; see admin_update_online_order_status's strict New/Printed/To-Ship
-- gating in supabase_online_order_portal_status_update.sql).
--
-- So rather than conflating the two, this just surfaces the REAL OnlineOrders.Status alongside the
-- existing editable one, read-only, once an order has actually synced - joined via
-- AutomatedOrders.PancakeReceiptNo = OnlineOrders.OrderID, the same exact join key
-- admin_list_online_orders already uses for its "GMA Page" flag (see supabase_gma_conversation_
-- orders.sql's header comment). Null (not shown) for an order that hasn't synced yet.

drop function if exists public.admin_list_automated_orders_by_gma_conversation(text, text, text, text);

create or replace function public.admin_list_automated_orders_by_gma_conversation(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text
)
returns table(
  order_no text,
  customer_name text,
  customer_phone text,
  customer_email text,
  fulfillment_type text,
  delivery_address text,
  location text,
  notes text,
  status text,
  estimated_total numeric,
  amount_paid numeric,
  balance numeric,
  pancake_order_id text,
  pancake_order_link text,
  pancake_sync_status text,
  online_order_status text,
  created_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;

  return query
    select
      o."OrderNo"::text,
      o."CustomerName"::text,
      o."CustomerPhone"::text,
      o."CustomerEmail"::text,
      o."FulfillmentType"::text,
      o."DeliveryAddress"::text,
      o."Location"::text,
      o."Notes"::text,
      o."Status"::text,
      o."EstimatedTotal",
      coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0)::numeric,
      (o."EstimatedTotal" - coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0))::numeric,
      o."PancakeOrderId"::text,
      o."PancakeOrderLink"::text,
      o."PancakeSyncStatus"::text,
      oo."Status"::text,
      o."CreatedAtUtc"
    from public."AutomatedOrders" o
    left join public."OnlineOrders" oo on oo."OrderID" = o."PancakeReceiptNo"
    where o."GmaPsid" = trim(p_psid)
      and (p_page_id is null or trim(p_page_id) = '' or o."GmaPageId" = trim(p_page_id))
    order by o."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_automated_orders_by_gma_conversation(text, text, text, text) to anon;
