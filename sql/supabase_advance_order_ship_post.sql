-- Advance orders auto-post to Facebook on Mark Shipped too - per "i want it to advance orders too if
-- possible". Same flow as an online order's ship post (supabase_online_order_ship_post.sql +
-- supabase_online_order_ship_post_amaya.sql): when an advance order is marked Shipped with a proof
-- photo, online-orders.html watermarks it and facebook-page-post 'post_ship' posts it with the
-- Dispatch caption (the item only - no customer, address or city).
--
-- The advance order is passed as order_id 'ADV-<TransactionNo>' (the same ADV- prefix the serial
-- reservations use), so it can never collide with an online order id in OnlineOrderShipPosts.
-- Shipped = AdvanceOrderProduction.ShippedAtUtc / DeliveredAtUtc set (_advance_order_prod_status);
-- branch = AdvanceOrders."Warehouse": "GMA" -> GMA Page, "Amaya" -> RS Pet Stop Page, else no post.
-- Still at most ONCE per order - an Undo Stage + Mark Shipped again does not post a second time.
--
-- Only re-creates service_claim_order_ship_post (same signature + result columns, so no drop needed);
-- online orders behave exactly as before.
--
-- Run AFTER supabase_online_order_ship_post_amaya.sql and supabase_delivery_stop_done_post.sql.
-- Safe to re-run. Do NOT re-run supabase_online_order_ship_post_amaya.sql after this one (it would put
-- back the online-only claim). Needs js/onlineOrders.js ?v=advshippost1 and the facebook-page-post
-- Edge Function redeployed.

create or replace function public.service_claim_order_ship_post(p_order_id text, p_username text)
returns table(status text, facebook_post_url text, page text, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_warehouse text;
  v_page text;
  v_advance_no text;
  v_row public."OnlineOrderShipPosts";
begin
  if p_order_id ~* '^ADV-' then
    v_advance_no := substr(p_order_id, 5);
    select public._advance_order_prod_status(p), a."Warehouse"
      into v_status, v_warehouse
      from public."AdvanceOrders" a
      left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
     where a."TransactionNo" = v_advance_no
     limit 1;
  else
    select o."Status", w."Name" into v_status, v_warehouse
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where o."OrderID" = p_order_id;
  end if;

  v_page := case
    when coalesce(v_warehouse, '') ~* 'gma' then 'gma'
    when coalesce(v_warehouse, '') ~* 'amaya' then 'amaya'
  end;

  if lower(coalesce(v_status, '')) not in ('shipped', 'delivered') then
    return query select 'not_shipped'::text, null::text, v_page, v_warehouse::text;
    return;
  end if;
  if v_page is null then
    return query select 'not_posting_branch'::text, null::text, null::text, v_warehouse::text;
    return;
  end if;

  insert into public."OnlineOrderShipPosts"("OrderID") values (p_order_id) on conflict do nothing;
  select * into v_row from public."OnlineOrderShipPosts" where "OrderID" = p_order_id for update;

  if v_row."PostedAtUtc" is not null or v_row."FacebookPostId" is not null then
    return query select 'posted'::text, v_row."FacebookPostUrl"::text, coalesce(v_row."Page", v_page)::text, v_warehouse::text;
  elsif v_row."PostClaimedAtUtc" is not null then
    return query select 'in_progress'::text, null::text, v_page, v_warehouse::text;
  else
    update public."OnlineOrderShipPosts"
       set "PostClaimedAtUtc" = now(), "PostedBy" = p_username, "PostError" = null, "Page" = v_page
     where "OrderID" = p_order_id;
    return query select 'claimed'::text, null::text, v_page, v_warehouse::text;
  end if;
end;
$$;

revoke all on function public.service_claim_order_ship_post(text, text) from public, anon, authenticated;
grant execute on function public.service_claim_order_ship_post(text, text) to service_role;

-- Result: advance-order branches and which Page their Shipped photo goes to.
select coalesce(a."Warehouse", '(no branch)') as advance_order_branch,
       case when a."Warehouse" ~* 'gma' then 'RS Pet Stop GMA Page'
            when a."Warehouse" ~* 'amaya' then 'RS Pet Stop Page'
            else 'not posted' end as posts_to,
       count(*) as advance_orders
from public."AdvanceOrders" a
group by 1, 2
order by 1;
