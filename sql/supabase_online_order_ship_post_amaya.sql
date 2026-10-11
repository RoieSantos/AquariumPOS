-- Dispatcher "Release / Ship" auto-post for AMAYA too - per "can we implement mark shipped auto
-- posting to RSPetStop Page too? this is for amaya warehouse".
--
-- Same flow as supabase_online_order_ship_post.sql (GMA), but the Page now depends on the order's
-- branch (OnlineOrders.LocationID -> Warehouses.Name):
--   name has "GMA"   -> 'gma'   -> RS Pet Stop GMA Page  (FACEBOOK_GMA_POST_TOKEN / FACEBOOK_GMA_PAGE_ID)
--   name has "Amaya" -> 'amaya' -> RS Pet Stop Page      (FACEBOOK_RSPETSTOP_POST_TOKEN / FACEBOOK_RSPETSTOP_PAGE_ID)
--   anything else    -> not posted ('not_posting_branch')
-- Still at most ONCE per order, whichever Page it goes to.
--
-- Re-creates service_claim_order_ship_post with two extra result columns (page, warehouse_name), so
-- it is dropped first. service_finish_order_ship_post is unchanged.
--
-- Run AFTER supabase_online_order_ship_post.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=amayapost1 and the facebook-page-post Edge Function redeployed.

-- ---------------------------------------------------------------------------
-- 1. Which Page each order was posted to.
alter table public."OnlineOrderShipPosts" add column if not exists "Page" varchar(20);
update public."OnlineOrderShipPosts" set "Page" = 'gma' where "Page" is null;

-- ---------------------------------------------------------------------------
-- 2. Claim. status: 'claimed' (go ahead) / 'posted' / 'in_progress' / 'not_shipped' / 'not_posting_branch'.
drop function if exists public.service_claim_order_ship_post(text, text);

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
  v_row public."OnlineOrderShipPosts";
begin
  select o."Status", w."Name" into v_status, v_warehouse
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = p_order_id;

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

-- Result: which warehouses auto-post on ship, and to which Page (check Amaya and GMA are listed).
select w."ID" as warehouse_id, w."Name" as warehouse_name,
       case when w."Name" ~* 'gma' then 'RS Pet Stop GMA Page' else 'RS Pet Stop Page' end as posts_to
from public."Warehouses" w
where w."Name" ~* 'gma' or w."Name" ~* 'amaya'
order by w."Name";
