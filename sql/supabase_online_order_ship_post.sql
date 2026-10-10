-- Dispatcher "Release / Ship" auto-post - per "can we apply this auto post to facebook for
-- dispatchers if the location/warehouse is GMA ?" and "it will remain to Shipped status for now".
--
-- When a Dispatcher marks a GMA-branch online order Shipped (whole-order Mark Shipped, or the
-- release that ships the last item - NOT a partial release), online-orders.html watermarks the
-- proof photo they just took and the facebook-page-post Edge Function (action 'post_ship') posts it
-- to the GMA Page with the Dispatch caption (the item only - no customer, address or city).
--
-- Same "post at most ONCE" rule as Mark Done (supabase_delivery_stop_done_post.sql): the function
-- claims the order here BEFORE calling Facebook; only one caller can win the claim, a successful
-- post keeps it for good, a failed post releases it (Try Again). A claim never expires on its own.
--
-- GMA = the order's branch (OnlineOrders.LocationID -> Warehouses.Name) has "GMA" in its name.
--
-- Run AFTER supabase_online_order_partial_release.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=shippost1 and the facebook-page-post Edge Function redeployed.

-- ---------------------------------------------------------------------------
-- 1. One row per order posted (or being posted) to Facebook on ship.
create table if not exists public."OnlineOrderShipPosts" (
    "OrderID" varchar(100) primary key,
    "PostedBy" varchar(100),
    "PostClaimedAtUtc" timestamptz,
    "PostedAtUtc" timestamptz,
    "FacebookPostId" varchar(100),
    "FacebookPostUrl" varchar(500),
    "PostCaption" text,
    "PostError" text
);

alter table public."OnlineOrderShipPosts" enable row level security;
-- No policies: only the service role (Edge Function) reads/writes it.

-- ---------------------------------------------------------------------------
-- 2. Claim. status: 'claimed' (go ahead) / 'posted' / 'in_progress' / 'not_shipped' / 'not_gma'.
create or replace function public.service_claim_order_ship_post(p_order_id text, p_username text)
returns table(status text, facebook_post_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_warehouse text;
  v_row public."OnlineOrderShipPosts";
begin
  select o."Status", w."Name" into v_status, v_warehouse
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = p_order_id;

  if lower(coalesce(v_status, '')) not in ('shipped', 'delivered') then
    return query select 'not_shipped'::text, null::text;
    return;
  end if;
  if coalesce(v_warehouse, '') !~* 'gma' then
    return query select 'not_gma'::text, null::text;
    return;
  end if;

  insert into public."OnlineOrderShipPosts"("OrderID") values (p_order_id) on conflict do nothing;
  select * into v_row from public."OnlineOrderShipPosts" where "OrderID" = p_order_id for update;

  if v_row."PostedAtUtc" is not null or v_row."FacebookPostId" is not null then
    return query select 'posted'::text, v_row."FacebookPostUrl"::text;
  elsif v_row."PostClaimedAtUtc" is not null then
    return query select 'in_progress'::text, null::text;
  else
    update public."OnlineOrderShipPosts"
       set "PostClaimedAtUtc" = now(), "PostedBy" = p_username, "PostError" = null
     where "OrderID" = p_order_id;
    return query select 'claimed'::text, null::text;
  end if;
end;
$$;

revoke all on function public.service_claim_order_ship_post(text, text) from public, anon, authenticated;
grant execute on function public.service_claim_order_ship_post(text, text) to service_role;

-- 3. Outcome of a claimed post: p_post_id set = posted (claim kept for good); else failed (claim
-- released so it can be tried again).
create or replace function public.service_finish_order_ship_post(
  p_order_id text, p_post_id text, p_post_url text, p_caption text, p_error text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if nullif(trim(coalesce(p_post_id, '')), '') is not null then
    update public."OnlineOrderShipPosts"
       set "FacebookPostId" = p_post_id, "FacebookPostUrl" = p_post_url, "PostCaption" = p_caption,
           "PostedAtUtc" = now(), "PostError" = null
     where "OrderID" = p_order_id;
  else
    update public."OnlineOrderShipPosts"
       set "PostClaimedAtUtc" = null, "PostError" = left(coalesce(p_error, 'Post failed.'), 1000),
           "PostCaption" = coalesce(p_caption, "PostCaption")
     where "OrderID" = p_order_id;
  end if;
end;
$$;

revoke all on function public.service_finish_order_ship_post(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.service_finish_order_ship_post(text, text, text, text, text) to service_role;

-- Result: the warehouses that count as GMA for this auto-post (check the right branch is listed).
select w."ID" as warehouse_id, w."Name" as warehouse_name, 'counts as GMA' as auto_post
from public."Warehouses" w
where w."Name" ~* 'gma'
order by w."Name";
