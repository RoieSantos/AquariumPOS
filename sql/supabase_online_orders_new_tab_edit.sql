-- Online Orders "New" tab: Edit an order waiting to be confirmed - per "can the user also modify the order
-- here.. only for new orders" (the New order dialog was read-only, edits went through GMA Conversations).
--
-- The dialog's new Edit mode saves with the same admin_update_automated_order GMA Conversations' Edit Order
-- uses (supabase_gma_order_delivery_fee.sql) - it already only edits orders that aren't confirmed yet
-- (refuses Portal / Completed / Cancelled), and the New tab only lists those. That save replaces every
-- header field, so the dialog needs the ones the list didn't return: customer_email and delivery_fee.
--
-- Re-creates staff_list_new_online_orders (supabase_online_orders_new_tab.sql) + customer_email, delivery_fee.
-- Run AFTER supabase_gma_order_delivery_fee.sql (needs AutomatedOrders."DeliveryFee"). Read-only. Safe to
-- re-run. Needs js/onlineNewOrders.js ?v=edit1.

drop function if exists public.staff_list_new_online_orders(text, text, text, int, int);

create or replace function public.staff_list_new_online_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  order_no text,
  created_at_utc timestamptz,
  created_by text,
  customer_name text,
  customer_phone text,
  fulfillment_type text,
  delivery_address text,
  location text,
  notes text,
  estimated_total numeric,
  amount_paid numeric,
  items_summary text,
  gma_psid text,
  total_count bigint,
  customer_email text,
  delivery_fee numeric
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      o."OrderNo"::text,
      o."CreatedAtUtc",
      o."UpdatedBy"::text,
      o."CustomerName"::text,
      o."CustomerPhone"::text,
      o."FulfillmentType"::text,
      o."DeliveryAddress"::text,
      o."Location"::text,
      o."Notes"::text,
      o."EstimatedTotal",
      coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0)::numeric,
      (select string_agg(l."Quantity" || ' x ' || l."ItemName", ', ' order by l."EntryNo")
         from public."AutomatedOrderLines" l where l."OrderNo" = o."OrderNo")::text,
      o."GmaPsid"::text,
      count(*) over(),
      o."CustomerEmail"::text,
      coalesce(o."DeliveryFee", 0)::numeric
    from public."AutomatedOrders" o
    where o."PancakeSyncStatus" = 'Not Pushed'
      and coalesce(o."Status", '') not in ('Cancelled', 'Completed')
      and (
        v_search is null
        or o."OrderNo" ilike '%' || v_search || '%'
        or o."CustomerName" ilike '%' || v_search || '%'
        or o."CustomerPhone" ilike '%' || v_search || '%'
      )
    order by o."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.staff_list_new_online_orders(text, text, text, int, int) to anon;

notify pgrst, 'reload schema';
