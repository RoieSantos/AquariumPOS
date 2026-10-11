-- Request Production - per "if an order has no stocks in the warehouse.. can we allow the user to request
-- for production.. if requested for production the production manager can see the order in the list
-- because he is 'All branch fabricator'".
--
-- A stock order (no custom tank/stand line) that's short on serials at its branch could only be built by a
-- Production Manager (Assign - build missing units, supabase_online_order_stock_ship.sql), and an
-- All-Branch Fabrication user never saw it from another branch (that view only covered custom / 10mm /
-- 12mm orders). Now:
--   * Branch staff press "Request Production" on such an order -> OnlineOrders.ProductionRequestedAtUtc /
--     ProductionRequestedBy are stamped and Production Managers + All-Branch Fabrication users get a push.
--   * _online_order_open_fabrication also counts an open order with a production request or a linked
--     Production Order, so All-Branch Fabrication users see it from any branch (list + status counts).
--   * The Production Manager then uses the existing Assign (build missing units) - unchanged. The build is
--     still for the order's own branch, so its output serials land there and the order ships from there.
--   * The request can be cancelled until a Production Order is linked. Cancelled / shipped orders drop out
--     of the other-branch view on their own (open statuses only).
--
-- Run AFTER supabase_online_order_all_branch_fabrication.sql, supabase_online_order_stock_ship.sql and
-- supabase_web_push_targeted.sql (all already live - do NOT re-run the All-Branch file: it re-creates an
-- old admin_list_online_orders overload; supabase_fix_online_orders_list_overload.sql repairs that).
-- Safe to re-run.

alter table public."OnlineOrders" add column if not exists "ProductionRequestedAtUtc" timestamptz;
alter table public."OnlineOrders" add column if not exists "ProductionRequestedBy" varchar(100);

-- ---------------------------------------------------------------------------
-- Same as supabase_online_order_all_branch_fabrication.sql, plus: an open online order with a production
-- request or a Production Order built for it.
create or replace function public._online_order_open_fabrication(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when o."ReceivedAtShop" is true
      then coalesce(public._walkin_order_stage(o."OrderID") in ('To Assign', 'Assigned', 'Production Done'), false)
    when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned', 'to ship', 'packing', 'packed')
      then o."ProductionRequestedAtUtc" is not null
        or exists (select 1 from public."ProductionOrders" po where po."SourceOnlineOrderId" = o."OrderID")
        or cardinality(public._online_order_production_roles(o."OrderID")) > 0
    else false
  end
  from public."OnlineOrders" o
  where o."OrderID" = p_order_id;
$$;

revoke execute on function public._online_order_open_fabrication(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The caller may request / cancel for this order: active, not maker-only, and either a Production
-- Manager / Super User, a user with no branch, or staff of the order's own branch.
create or replace function public._online_order_can_request_production(p_username text, p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public."StaffUsers" s
    cross join public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where s."Username" = p_username and s."IsActive"
      and o."OrderID" = p_order_id
      and not public._is_order_maker_only(p_username)
      and (public._production_is_manager(p_username)
           or nullif(trim(coalesce(s."WarehouseName", '')), '') is null
           or lower(trim(s."WarehouseName")) = lower(trim(coalesce(w."Name", ''))))
  );
$$;

revoke execute on function public._online_order_can_request_production(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_request_online_order_production(text, text, text);

create or replace function public.staff_request_online_order_production(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
-- The push below is a synchronous HTTP call to send-web-push (up to 8s); the anon role's default
-- statement_timeout (~3s) cancelled the whole request when it was slow - per "its timeout when I request
-- Production". Same fix as the other HTTP-calling RPCs (supabase_gma_conversation_order_statement_timeout.sql).
set statement_timeout = '30000'
as $$
declare
  v_order record;
  v_stock record;
  v_recipients text[];
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select o."OrderID", o."Status", o."CustomerName", o."ReceivedAtShop", o."ProductionRequestedAtUtc", w."Name" as warehouse_name
    into v_order
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = p_order_id;

  if v_order."OrderID" is null then
    raise exception 'Order % not found.', p_order_id;
  end if;
  if not public._online_order_can_request_production(p_admin_username, p_order_id) then
    raise exception 'Only staff of % can request production for this order.', coalesce(v_order.warehouse_name, 'the order''s branch');
  end if;
  if v_order."ReceivedAtShop" is true then
    raise exception 'Walk-in orders use their own Assign flow.';
  end if;
  if lower(trim(coalesce(v_order."Status", ''))) not in ('confirmed', 'submitted', 'printed', 'assigned') then
    raise exception 'Order % is %, production can''t be requested for it.', p_order_id, v_order."Status";
  end if;
  if cardinality(public._online_order_production_roles(p_order_id)) > 0 then
    raise exception 'Order % is a custom / maker order - the Production Manager assigns it directly.', p_order_id;
  end if;
  if exists (select 1 from public."ProductionOrders" po where po."SourceOnlineOrderId" = p_order_id) then
    raise exception 'Order % already has a Production Order.', p_order_id;
  end if;
  if v_order."ProductionRequestedAtUtc" is not null then
    return 'Production was already requested for this order.';
  end if;

  -- Same stock check the page shows (counted at the order's branch).
  select s.needs_serial, s.all_available into v_stock
  from public.staff_get_online_order_stock_status(p_admin_username, p_admin_password, array[p_order_id]) s;
  if not coalesce(v_stock.needs_serial, false) then
    raise exception 'Order % has no stock aquarium / stand / sump to build.', p_order_id;
  end if;
  if coalesce(v_stock.all_available, false) then
    raise exception 'Everything for order % is in stock at % - it can ship now.', p_order_id, coalesce(v_order.warehouse_name, 'its branch');
  end if;

  update public."OnlineOrders"
  set "ProductionRequestedAtUtc" = now(), "ProductionRequestedBy" = p_admin_username
  where "OrderID" = p_order_id;

  select array_agg(s."Username") into v_recipients
  from public."StaffUsers" s
  where s."IsActive" and s."Username" <> p_admin_username
    and s."StaffRoles" && array['ProductionManager', 'AllBranchFabrication']::text[];

  perform public._trigger_web_push(
    'Production requested',
    'Order ' || p_order_id || ' - ' || coalesce(v_order."CustomerName", '-') || ' (' || coalesce(v_order.warehouse_name, '-') || '): not enough in stock',
    'online-orders.html?open=' || p_order_id,
    coalesce(v_recipients, '{}'));

  return 'Production requested. The Production Manager has been notified.';
end;
$$;

grant execute on function public.staff_request_online_order_production(text, text, text) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_cancel_online_order_production_request(text, text, text);

create or replace function public.staff_cancel_online_order_production_request(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._online_order_can_request_production(p_admin_username, p_order_id) then
    raise exception 'Only staff of the order''s branch can cancel this request.';
  end if;
  if exists (select 1 from public."ProductionOrders" po where po."SourceOnlineOrderId" = p_order_id) then
    raise exception 'Order % is already being built - ask the Production Manager to cancel its Production Order instead.', p_order_id;
  end if;

  update public."OnlineOrders"
  set "ProductionRequestedAtUtc" = null, "ProductionRequestedBy" = null
  where "OrderID" = p_order_id;
end;
$$;

grant execute on function public.staff_cancel_online_order_production_request(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Requests on the orders on screen (the page's "Production Requested" badge / button).
drop function if exists public.staff_list_online_order_production_requests(text, text, text[]);

create or replace function public.staff_list_online_order_production_requests(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, requested_at timestamptz, requested_by text, requested_by_name text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."OrderID"::text, o."ProductionRequestedAtUtc", o."ProductionRequestedBy"::text,
           coalesce(s."DisplayName", o."ProductionRequestedBy")::text
    from public."OnlineOrders" o
    left join public."StaffUsers" s on s."Username" = o."ProductionRequestedBy"
    where o."OrderID"::text = any(coalesce(p_order_ids, '{}'))
      and o."ProductionRequestedAtUtc" is not null;
end;
$$;

grant execute on function public.staff_list_online_order_production_requests(text, text, text[]) to anon;

notify pgrst, 'reload schema';
