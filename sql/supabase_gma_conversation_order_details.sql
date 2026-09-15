-- Per direct follow-up request, each order card in GMA Conversations' "Orders from this
-- conversation" list (docs/gma-conversations.html) is now collapsed to just its order number and
-- status by default, expanding on click to show products/payments/address/etc - fields
-- admin_list_automated_orders_by_gma_conversation (supabase_gma_conversation_orders.sql) never
-- returned before (only customer_name/phone, not email/delivery address/location/notes). Products
-- and payment history reuse the ALREADY-EXISTING admin_list_automated_order_lines
-- (supabase_automated_orders_tables.sql) and admin_list_automated_order_payments
-- (supabase_gma_conversation_orders.sql) RPCs - no changes needed there.

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
      o."CreatedAtUtc"
    from public."AutomatedOrders" o
    where o."GmaPsid" = trim(p_psid)
      and (p_page_id is null or trim(p_page_id) = '' or o."GmaPageId" = trim(p_page_id))
    order by o."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_automated_orders_by_gma_conversation(text, text, text, text) to anon;
