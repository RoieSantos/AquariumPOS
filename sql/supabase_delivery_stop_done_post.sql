-- Delivery "Mark Done": on the Delivery Team's route view (delivery.html), each stop card has a
-- Mark Done button that takes a photo, then (supabase/functions/facebook-page-post):
--   1. MARK DONE - saves the photo and records the stop as done (DeliveryStopCompletions), marking
--      its order "Delivered" (a portal-only status, NOT sent to Pancake). No Facebook involved, so
--      a delivery is recorded even if Facebook is down or the posting token breaks.
--   2. POST - posts it to the GMA Facebook Page as a "Delivery Done / Setup Done" post, at most
--      ONCE per stop: service_claim_delivery_stop_post claims the stop before anything is sent, and
--      a claim is never released after a successful post. A failed post releases the claim, and
--      the card offers "Post to Facebook" to try again (using the stored photo).
--
-- DELIVERED vs THE PANCAKE SYNC. The Pancake sync rewrites OnlineOrders."Status" on every run
-- ("Status" = excluded."Status"), which would flip a Delivered order back to Shipped. So the
-- delivery is stored in two new portal-only columns the sync never touches (DeliveredAtUtc /
-- DeliveredBy), and a trigger keeps "Status" = 'Delivered' whenever DeliveredAtUtc is set - on
-- the sync's upsert too. 'delivered' was already treated as a finished status everywhere (same as
-- Shipped), so lists, filters and My Assignments need no change; the status summary below just
-- gives it its own "Delivered" tab count instead of counting it under Shipped.
--
-- ADVANCE ORDERS (DeliveryStops."AdvanceTransactionNo"): their stage is portal-only already
-- (AdvanceOrderProduction, worked out by _advance_order_prod_status), so Delivered is just a new
-- stage after Shipped: AdvanceOrderProduction.DeliveredAtUtc / DeliveredBy. The Advance Orders
-- status tabs (staff_get_advance_order_status_summary) and list filter (admin_list_advance_orders)
-- both group by _advance_order_prod_status, so the Delivered tab needs no change to them.
--
-- PHOTO: the watermarked photo is also saved to Supabase Storage (online-order-status-photos bucket)
-- and listed in the order's Photos as "Delivered" (OnlineOrderStatusPhotos) - not only on Facebook.
--
-- WHO / WHEN is logged in three places: DeliveryStopCompletions (per stop, with the Facebook post),
-- OnlineOrders.DeliveredBy / DeliveredAtUtc, and AdvanceOrderProduction.DeliveredBy / DeliveredAtUtc.
--
-- Re-creates (latest versions):
--   admin_get_online_order_status_summary (supabase_online_order_all_branch_fabrication.sql) -
--     online branch only: 'delivered' gets its own bucket. Walk-in branch unchanged.
--   _advance_order_prod_status + staff_set_advance_order_stage (supabase_advance_order_production.sql)
--     - Delivered stage, and "step back" from Delivered clears it.
--
-- Run AFTER supabase_delivery_advance_and_walkin_orders.sql, supabase_advance_order_production.sql
-- and supabase_online_order_all_branch_fabrication.sql. Safe to re-run.
-- Needs js/delivery.js ?v=donefirst1 and js/onlineOrders.js ?v=delivered3.

-- ---------------------------------------------------------------------------
-- 1. Which stops are done, and the Facebook post made for each.
create table if not exists public."DeliveryStopCompletions" (
    "StopID" uuid primary key references public."DeliveryStops"("StopID") on delete cascade,
    "DoneBy" varchar(100) not null,
    "DoneAtUtc" timestamptz not null default now(),
    "FacebookPostId" varchar(100),
    "FacebookPostUrl" varchar(500),
    "PhotoUrl" varchar(1000)
);
-- Table may already exist from an earlier run of this file.
alter table public."DeliveryStopCompletions" add column if not exists "PhotoUrl" varchar(1000);
-- The Facebook step (2 above): stored photo to post, the claim, and the outcome.
alter table public."DeliveryStopCompletions" add column if not exists "PhotoStoragePath" varchar(500);
alter table public."DeliveryStopCompletions" add column if not exists "PostClaimedAtUtc" timestamptz;
alter table public."DeliveryStopCompletions" add column if not exists "PostedAtUtc" timestamptz;
alter table public."DeliveryStopCompletions" add column if not exists "PostCaption" text;
alter table public."DeliveryStopCompletions" add column if not exists "PostError" text;
-- Rows from the earlier post-first version already went to Facebook.
update public."DeliveryStopCompletions" set "PostedAtUtc" = "DoneAtUtc"
 where "PostedAtUtc" is null and "FacebookPostId" is not null;

alter table public."DeliveryStopCompletions" enable row level security;
-- No policies: browser access only through the RPC below; the Edge Function uses the service role.
revoke all on public."DeliveryStopCompletions" from anon, authenticated;

comment on table public."DeliveryStopCompletions" is 'Delivery stops marked Done from the driver route view, with the Facebook post made at the time - written by service_mark_delivery_stop_done (facebook-page-post Edge Function).';

-- ---------------------------------------------------------------------------
-- 2. Portal-only Delivered status on OnlineOrders.
set lock_timeout = '10s';
alter table public."OnlineOrders" add column if not exists "DeliveredAtUtc" timestamptz;
alter table public."OnlineOrders" add column if not exists "DeliveredBy" varchar(100);
reset lock_timeout;

create or replace function public._online_orders_keep_delivered()
returns trigger
language plpgsql
as $$
begin
  -- The Pancake sync never sets DeliveredAtUtc, so on its upsert NEW keeps the old value and the
  -- status it tries to write (e.g. 'Shipped') is replaced with 'Delivered'.
  if new."DeliveredAtUtc" is not null then
    new."Status" := 'Delivered';
  end if;
  return new;
end;
$$;

drop trigger if exists "TRG_OnlineOrders_KeepDelivered" on public."OnlineOrders";
create trigger "TRG_OnlineOrders_KeepDelivered"
  before insert or update on public."OnlineOrders"
  for each row execute function public._online_orders_keep_delivered();

-- ---------------------------------------------------------------------------
-- 2b. Advance orders: Delivered stage after Shipped.
set lock_timeout = '10s';
alter table public."AdvanceOrderProduction" add column if not exists "DeliveredAtUtc" timestamptz;
alter table public."AdvanceOrderProduction" add column if not exists "DeliveredBy" varchar(100);
reset lock_timeout;

create or replace function public._advance_order_prod_status(p public."AdvanceOrderProduction")
returns text
language sql
immutable
as $$
  select case
    when p."DeliveredAtUtc" is not null then 'Delivered'
    when p."ShippedAtUtc" is not null then 'Shipped'
    when p."ToShipAtUtc" is not null then 'To Ship'
    when p."TankMaker" is null and p."StandMaker" is null then null
    when (p."TankMaker" is not null and p."TankDoneAtUtc" is null)
      or (p."StandMaker" is not null and p."StandDoneAtUtc" is null) then 'Assigned'
    else 'Production Done'
  end;
$$;
revoke execute on function public._advance_order_prod_status(public."AdvanceOrderProduction") from public, anon, authenticated;

-- Same as supabase_advance_order_production.sql, plus: stepping back (p_stage null) from Delivered
-- clears Delivered (back to Shipped / To Ship), the way it already does for Shipped.
create or replace function public.staff_set_advance_order_stage(
  p_admin_username text, p_admin_password text, p_no text, p_stage text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_stage text := nullif(trim(coalesce(p_stage, '')), '');
  v_prod public."AdvanceOrderProduction";
  v_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can change this.';
  end if;
  if not exists (select 1 from public."AdvanceOrders" where "TransactionNo" = p_no) then
    raise exception 'Advance order % not found.', p_no;
  end if;
  insert into public."AdvanceOrderProduction" ("TransactionNo") values (p_no) on conflict do nothing;
  select * into v_prod from public."AdvanceOrderProduction" where "TransactionNo" = p_no for update;
  v_status := public._advance_order_prod_status(v_prod);

  if v_stage = 'To Ship' then
    if v_status = 'Assigned' then
      raise exception 'Advance order % is still in production - every assigned part must be Production Done first.', p_no;
    end if;
    update public."AdvanceOrderProduction"
       set "ToShipAtUtc" = now(), "ToShipBy" = p_admin_username, "ShippedAtUtc" = null, "ShippedBy" = null,
           "DeliveredAtUtc" = null, "DeliveredBy" = null
     where "TransactionNo" = p_no;
  elsif v_stage = 'Shipped' then
    if v_status is distinct from 'To Ship' then
      raise exception 'Advance order % must be To Ship before it can be marked Shipped.', p_no;
    end if;
    update public."AdvanceOrderProduction" set "ShippedAtUtc" = now(), "ShippedBy" = p_admin_username where "TransactionNo" = p_no;
  elsif v_stage is null then
    if v_status = 'Delivered' then
      update public."AdvanceOrderProduction" set "DeliveredAtUtc" = null, "DeliveredBy" = null where "TransactionNo" = p_no;
    elsif v_status = 'Shipped' then
      update public."AdvanceOrderProduction" set "ShippedAtUtc" = null, "ShippedBy" = null where "TransactionNo" = p_no;
    else
      update public."AdvanceOrderProduction" set "ToShipAtUtc" = null, "ToShipBy" = null where "TransactionNo" = p_no;
    end if;
  else
    raise exception 'p_stage must be ''To Ship'', ''Shipped'' or null.';
  end if;

  update public."AdvanceOrderProduction" set "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
   where "TransactionNo" = p_no
  returning * into v_prod;
  return public._advance_order_prod_status(v_prod);
end;
$$;
grant execute on function public.staff_set_advance_order_stage(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Mark a stop done (+ its order Delivered) - step 1, no Facebook. Called only by the
-- facebook-page-post Edge Function with the service role - not callable from the browser.
-- Returns true when this call marked it done, false when it was already done (left untouched).
drop function if exists public.service_mark_delivery_stop_done(uuid, text, text, text, text, text);
drop function if exists public.service_mark_delivery_stop_done(uuid, text, text, text);

-- p_photo_storage_path / p_photo_url: the watermarked photo, uploaded by the Edge Function to the
-- online-order-status-photos bucket (same bucket and table as the Shipped / Production Done proof
-- photos - supabase_online_order_proof_photos.sql), so it shows in the order's Photos as "Delivered".
create or replace function public.service_mark_delivery_stop_done(
  p_stop_id uuid,
  p_username text,
  p_photo_storage_path text,
  p_photo_url text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
  v_advance_no text;
  v_automated_no text;
begin
  -- A stop points at ONE of OrderID / AdvanceTransactionNo / AutomatedOrderNo (a draft AO order -
  -- supabase_delivery_assign_automated_order_search.sql; the column may not exist before that file).
  select s."OrderID", s."AdvanceTransactionNo", to_jsonb(s) ->> 'AutomatedOrderNo'
    into v_order_id, v_advance_no, v_automated_no
    from public."DeliveryStops" s where s."StopID" = p_stop_id;
  if not found then
    raise exception 'Delivery stop not found.';
  end if;

  insert into public."DeliveryStopCompletions" ("StopID", "DoneBy", "DoneAtUtc", "PhotoStoragePath", "PhotoUrl")
  values (p_stop_id, p_username, now(), p_photo_storage_path, p_photo_url)
  on conflict ("StopID") do nothing;
  if not found then
    return false; -- already done (second phone / double tap)
  end if;

  -- The order's Photos (OrderID holds the advance TransactionNo for advance orders, same as their
  -- Shipped proof photos; the AO number for a draft AO). A draft AO has no Delivered status of its
  -- own - once it's confirmed, the stop moves onto the online order.
  if nullif(trim(coalesce(p_photo_url, '')), '') is not null then
    insert into public."OnlineOrderStatusPhotos" ("OrderID", "Status", "StoragePath", "PublicUrl", "SentToCustomer", "SendError", "UploadedBy")
    values (coalesce(v_order_id, v_advance_no, v_automated_no), 'Delivered', coalesce(p_photo_storage_path, ''), p_photo_url, null, null, p_username);
  end if;

  -- Online / walk-in order: Delivered (the trigger above sets Status).
  if v_order_id is not null then
    update public."OnlineOrders"
       set "DeliveredAtUtc" = now(), "DeliveredBy" = p_username
     where "OrderID" = v_order_id;
  end if;

  -- Advance order: Delivered stage (_advance_order_prod_status above).
  if v_advance_no is not null then
    insert into public."AdvanceOrderProduction" ("TransactionNo") values (v_advance_no) on conflict do nothing;
    update public."AdvanceOrderProduction"
       set "DeliveredAtUtc" = now(), "DeliveredBy" = p_username,
           "UpdatedAtUtc" = now(), "UpdatedBy" = p_username
     where "TransactionNo" = v_advance_no;
  end if;

  return true;
end;
$$;

revoke all on function public.service_mark_delivery_stop_done(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.service_mark_delivery_stop_done(uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3a. Post to Facebook at most once per stop (step 2). The Edge Function claims the stop BEFORE
-- calling Facebook; only one caller can win the claim (row lock + conditions), and a claim is only
-- released by a FAILED post. A claim never expires on its own: if the function died after Facebook
-- took the post but before recording it, auto-expiring could post it twice - a stuck claim
-- ("in_progress") is cleared by hand instead, after checking the Page.
create or replace function public.service_claim_delivery_stop_post(p_stop_id uuid)
returns table(status text, photo_storage_path text, facebook_post_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."DeliveryStopCompletions";
begin
  select * into v_row from public."DeliveryStopCompletions" where "StopID" = p_stop_id for update;
  if not found then
    return query select 'not_done'::text, null::text, null::text;
  elsif v_row."PostedAtUtc" is not null or v_row."FacebookPostId" is not null then
    return query select 'posted'::text, v_row."PhotoStoragePath"::text, v_row."FacebookPostUrl"::text;
  elsif v_row."PostClaimedAtUtc" is not null then
    return query select 'in_progress'::text, v_row."PhotoStoragePath"::text, null::text;
  else
    update public."DeliveryStopCompletions" set "PostClaimedAtUtc" = now(), "PostError" = null
     where "StopID" = p_stop_id;
    return query select 'claimed'::text, v_row."PhotoStoragePath"::text, null::text;
  end if;
end;
$$;

revoke all on function public.service_claim_delivery_stop_post(uuid) from public, anon, authenticated;
grant execute on function public.service_claim_delivery_stop_post(uuid) to service_role;

-- Outcome of a claimed post: p_post_id set = posted (claim kept for good); else failed (claim
-- released so it can be tried again, p_error kept for the card).
create or replace function public.service_finish_delivery_stop_post(
  p_stop_id uuid, p_post_id text, p_post_url text, p_caption text, p_error text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if nullif(trim(coalesce(p_post_id, '')), '') is not null then
    update public."DeliveryStopCompletions"
       set "FacebookPostId" = p_post_id, "FacebookPostUrl" = p_post_url, "PostCaption" = p_caption,
           "PostedAtUtc" = now(), "PostError" = null
     where "StopID" = p_stop_id;
  else
    update public."DeliveryStopCompletions"
       set "PostClaimedAtUtc" = null, "PostError" = left(coalesce(p_error, 'Post failed.'), 1000),
           "PostCaption" = coalesce(p_caption, "PostCaption")
     where "StopID" = p_stop_id;
  end if;
end;
$$;

revoke all on function public.service_finish_delivery_stop_post(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.service_finish_delivery_stop_post(uuid, text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3b. Order card: Delivered By / Delivered Date (+ the Facebook post and photo) for one online or
-- advance order. Separate lookup so the big list functions don't change.
create or replace function public.staff_get_order_delivery(
  p_username text,
  p_password text,
  p_order_id text default null,
  p_advance_no text default null
)
returns table(delivered_by text, delivered_at_utc timestamptz, facebook_post_url text, photo_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  if nullif(trim(coalesce(p_order_id, '')), '') is not null then
    return query
    select coalesce(u."DisplayName", o."DeliveredBy")::text, o."DeliveredAtUtc",
           c."FacebookPostUrl"::text, c."PhotoUrl"::text
      from public."OnlineOrders" o
      left join public."StaffUsers" u on u."Username" = o."DeliveredBy"
      left join lateral (
        select dc.* from public."DeliveryStops" s
        join public."DeliveryStopCompletions" dc on dc."StopID" = s."StopID"
        where s."OrderID" = o."OrderID" order by dc."DoneAtUtc" desc limit 1
      ) c on true
     where o."OrderID" = trim(p_order_id) and o."DeliveredAtUtc" is not null;
  elsif nullif(trim(coalesce(p_advance_no, '')), '') is not null then
    return query
    select coalesce(u."DisplayName", p."DeliveredBy")::text, p."DeliveredAtUtc",
           c."FacebookPostUrl"::text, c."PhotoUrl"::text
      from public."AdvanceOrderProduction" p
      left join public."StaffUsers" u on u."Username" = p."DeliveredBy"
      left join lateral (
        select dc.* from public."DeliveryStops" s
        join public."DeliveryStopCompletions" dc on dc."StopID" = s."StopID"
        where s."AdvanceTransactionNo" = p."TransactionNo" order by dc."DoneAtUtc" desc limit 1
      ) c on true
     where p."TransactionNo" = trim(p_advance_no) and p."DeliveredAtUtc" is not null;
  end if;
end;
$$;

grant execute on function public.staff_get_order_delivery(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. Driver view: which of these stops are done, and where their Facebook post stands
-- (post_status: 'posted' | 'in_progress' | 'failed' | 'not_posted').
drop function if exists public.staff_list_delivery_stop_completions(text, text, uuid[]);

create or replace function public.staff_list_delivery_stop_completions(
  p_username text,
  p_password text,
  p_stop_ids uuid[]
)
returns table(stop_id uuid, done_by text, done_at_utc timestamptz, facebook_post_url text,
              post_status text, post_error text, post_claimed_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  select c."StopID", coalesce(u."DisplayName", c."DoneBy")::text, c."DoneAtUtc", c."FacebookPostUrl"::text,
         case when c."PostedAtUtc" is not null or c."FacebookPostId" is not null then 'posted'
              when c."PostClaimedAtUtc" is not null then 'in_progress'
              when c."PostError" is not null then 'failed'
              else 'not_posted' end,
         c."PostError"::text, c."PostClaimedAtUtc"
    from public."DeliveryStopCompletions" c
    left join public."StaffUsers" u on u."Username" = c."DoneBy"
   where c."StopID" = any(p_stop_ids);
end;
$$;

grant execute on function public.staff_list_delivery_stop_completions(text, text, uuid[]) to anon;

-- ---------------------------------------------------------------------------
-- 5. Online Orders status pills: a "Delivered" count of its own (was counted under Shipped).
create or replace function public.admin_get_online_order_status_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null, p_walkin_only boolean default false,
  p_branch_scoped boolean default false)
returns table(status_label text, order_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_all_branch_fab boolean := false;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if coalesce(p_branch_scoped, false) then
    select coalesce('AllBranchFabrication' = any(s."StaffRoles"), false) into v_all_branch_fab
    from public."StaffUsers" s where s."Username" = p_admin_username;
    v_all_branch_fab := coalesce(v_all_branch_fab, false);
  end if;

  if coalesce(p_walkin_only, false) then
    return query
      with buckets(status_label, sort_order) as (
        values ('To Assign', 1), ('Assigned', 2), ('Production Done', 3), ('Completed', 4), ('Shipped', 5), ('Cancelled', 6)
      ),
      order_buckets as (
        select
          case
            when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
            else coalesce(public._walkin_order_stage(o."OrderID"),
                   case when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2') then 'Shipped' end)
          end as status_label
        from public."OnlineOrders" o
        left join public."Warehouses" w on w."ID" = o."LocationID"
        where o."ReceivedAtShop" is true
          and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name
               or (case when v_all_branch_fab and o."PickedUpAtUtc" is null
                          and (o."Date" >= public._walkin_flow_start()
                               or nullif(trim(coalesce(o."AssignedTankMaker", '')), '') is not null
                               or nullif(trim(coalesce(o."AssignedStandMaker", '')), '') is not null)
                        then public._online_order_open_fabrication(o."OrderID") else false end))
      )
      select b.status_label, count(ob.status_label)::int as order_count
      from buckets b
      left join order_buckets ob on ob.status_label = b.status_label
      group by b.status_label, b.sort_order
      order by b.sort_order;
    return;
  end if;

  return query
    with buckets(status_label, sort_order) as (
      values ('Confirmed', 1), ('Printed', 2), ('Assigned', 3), ('Production Done', 4), ('To Ship', 5), ('Shipped', 6), ('Delivered', 7), ('Cancelled', 8)
    ),
    order_flags as (
      select
        o.*,
        -- Needed makers - only worked out for Printed orders, the one bucket that uses them.
        case when lower(trim(coalesce(o."Status", ''))) = 'printed'
          then public._online_order_assignment_complete(o."OrderID") else false end as all_assigned
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."ReceivedAtShop" is not true
        and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name
             or (case when v_all_branch_fab
                        and lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned', 'to ship', 'packing', 'packed')
                   then public._online_order_open_fabrication(o."OrderID") else false end))
    ),
    order_buckets as (
      select
        case
          -- CASE-gated so the done check only runs for open orders (see the list function).
          when case when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned')
                 then public._online_order_production_all_done(o."OrderID") else false end then 'Production Done'
          when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted') then 'Confirmed'
          when lower(trim(coalesce(o."Status", ''))) = 'assigned' then 'Assigned'
          when lower(trim(coalesce(o."Status", ''))) = 'printed' then
            case when o.all_assigned then 'Assigned' else 'Printed' end
          when lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed') then 'To Ship'
          when lower(trim(coalesce(o."Status", ''))) in ('shipped', '2') then 'Shipped'
          when lower(trim(coalesce(o."Status", ''))) = 'delivered' then 'Delivered'
          when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
          else null
        end as status_label
      from order_flags o
    )
    select b.status_label, count(ob.status_label)::int as order_count
    from buckets b
    left join order_buckets ob on ob.status_label = b.status_label
    group by b.status_label, b.sort_order
    order by b.sort_order;
end;
$$;

grant execute on function public.admin_get_online_order_status_summary(text, text, text, boolean, boolean) to anon;

-- ---------------------------------------------------------------------------
-- 6. Draft AO confirmed later: when a done stop moves from its draft AO onto the new online order
-- (supabase_delivery_assign_automated_order_search.sql sets OrderID and clears AutomatedOrderNo),
-- carry the delivery over - the online order becomes Delivered, and the "Delivered" photo filed
-- under the AO number moves to the order.
create or replace function public._delivery_stop_carry_done_to_order()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_done public."DeliveryStopCompletions";
  v_old_ref text := coalesce(to_jsonb(OLD) ->> 'AutomatedOrderNo', OLD."AdvanceTransactionNo");
begin
  select * into v_done from public."DeliveryStopCompletions" where "StopID" = NEW."StopID";
  if not found then
    return null;
  end if;

  update public."OnlineOrders"
     set "DeliveredAtUtc" = coalesce("DeliveredAtUtc", v_done."DoneAtUtc"),
         "DeliveredBy" = coalesce("DeliveredBy", v_done."DoneBy")
   where "OrderID" = NEW."OrderID";

  if v_old_ref is not null then
    update public."OnlineOrderStatusPhotos" set "OrderID" = NEW."OrderID"
     where "OrderID" = v_old_ref and "Status" = 'Delivered';
  end if;
  return null;
end;
$$;

drop trigger if exists "TR_DeliveryStops_CarryDoneToOrder" on public."DeliveryStops";
create trigger "TR_DeliveryStops_CarryDoneToOrder"
  after update of "OrderID" on public."DeliveryStops"
  for each row when (OLD."OrderID" is null and NEW."OrderID" is not null)
  execute function public._delivery_stop_carry_done_to_order();
