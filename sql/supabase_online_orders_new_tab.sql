-- Online Orders "New" tab - per "maybe we create a new layer or status NEW.. before the confirmed status
-- so all new created that is not yet confirmed will go there" and "remove the online page orders".
--
-- Lists the orders waiting to be confirmed: AI bot (Vic / website Alice) orders and GMA Conversations
-- "+ New Order" orders, i.e. AutomatedOrders rows with PancakeSyncStatus = 'Not Pushed' that aren't
-- Cancelled / Completed (supabase_bot_orders_portal_confirm.sql, supabase_gma_new_order_no_pancake.sql).
-- They stay in AutomatedOrders until Confirm Order (admin_confirm_bot_order) creates the real
-- OnlineOrders row - so dashboards, payment reports, the Item Ledger and the Pancake crons never see
-- an unconfirmed order. docs/js/onlineNewOrders.js renders the tab.
--
-- Read-only. Run AFTER supabase_bot_orders_portal_confirm.sql. Safe to re-run.

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
  total_count bigint
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
      count(*) over()
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
