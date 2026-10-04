-- Advance Orders tab for Store Managers too (per "can you show this advance order to store manager too?").
-- View-only: Store Managers (StaffUsers."StoreManager") can list advance orders, see the stage counts and
-- open an order's lines / rework history. Assigning makers and moving stages stays with Super Users and
-- Production Managers (staff_assign_advance_order_maker / staff_set_advance_order_stage /
-- staff_send_back_advance_order are unchanged; the portal hides those buttons for everyone else).
-- Own branch only (per "yes they can only see their own branch"): a Store Manager sees only the orders
-- whose "Warehouse" matches their StaffUsers."WarehouseName" (no branch set / order with no Warehouse =
-- not shown). Super Users and Production Managers still see every branch.
--
-- Re-creates admin_list_advance_orders and staff_get_advance_order_status_summary as in
-- supabase_advance_order_production.sql, with only the authorization check widened and the branch
-- filter added, plus _advance_order_can_view.
--
-- Run AFTER supabase_advance_order_production.sql. Safe to re-run. If supabase_advance_order_production.sql
-- is ever re-run, run this file again afterwards (it would put the old Super User / Production Manager-only
-- checks back).

-- Production Manager or an active Store Manager - may view (not manage) advance orders.
create or replace function public._advance_order_is_viewer(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._production_is_manager(p_username)
      or exists (select 1 from public."StaffUsers"
                 where "Username" = p_username and "IsActive" and coalesce("StoreManager", false));
$$;

revoke execute on function public._advance_order_is_viewer(text) from public, anon, authenticated;

-- The one branch a viewer is limited to: null = every branch (Super User / Production Manager), else the
-- Store Manager's WarehouseName ('' when none is set - matches no order).
create or replace function public._advance_order_viewer_branch(p_username text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public._production_is_manager(p_username)
      or exists (select 1 from public."StaffUsers" where "Username" = p_username and "IsActive" and "SuperUser")
      then null
    else coalesce((select lower(trim(coalesce("WarehouseName", ''))) from public."StaffUsers"
                   where "Username" = p_username limit 1), '')
  end;
$$;

revoke execute on function public._advance_order_viewer_branch(text) from public, anon, authenticated;

drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int);
drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int, text);

-- p_prod_status: null = all, 'New' = never assigned, or Assigned / Production Done / To Ship / Shipped.
create or replace function public.admin_list_advance_orders(
  p_admin_username text, p_admin_password text,
  p_search text default null, p_transaction_no text default null,
  p_page int default 1, p_page_size int default 50,
  p_prod_status text default null
)
returns table(
  transaction_no text,
  receipt_no text,
  user_id text,
  customer_name text,
  order_description text,
  order_date date,
  order_time text,
  net_amount numeric,
  downpayment numeric,
  balance numeric,
  online_order_id text,
  fully_paid boolean,
  date_paid timestamptz,
  warehouse text,
  synced_at_utc timestamptz,
  prod_status text,             -- null = not assigned yet
  tank_maker text,
  tank_maker_name text,
  stand_maker text,
  stand_maker_name text,
  tank_done_at timestamptz,
  stand_done_at timestamptz,
  to_ship_at timestamptz,
  to_ship_by text,
  shipped_at timestamptz,
  shipped_by text,
  needs_tank boolean,
  needs_stand boolean,
  open_rework_count int,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_status text := nullif(trim(coalesce(p_prod_status, '')), '');
  v_branch text; -- null = all branches; else a Store Manager's own branch (lower-cased)
begin
  if public.is_admin_authorized(p_admin_username, p_admin_password) then
    v_branch := null;
  elsif public.is_staff_authorized(p_admin_username, p_admin_password) and public._advance_order_is_viewer(p_admin_username) then
    v_branch := public._advance_order_viewer_branch(p_admin_username);
  else
    raise exception 'Not authorized.';
  end if;

  -- Filter + sort + page first (cheap columns only), then work out the per-order extras (which makers
  -- the lines suggest, open rework, maker names) for just the rows on this page.
  return query
    with base as (
      select a.*, p as prod, public._advance_order_prod_status(p) as status,
             -- Latest activity: the later of when it was fully paid ("DatePaid") and when it was placed
             -- ("Date" + "Time", Manila; a "Time" that isn't a clock value counts as midnight).
             greatest(a."DatePaid",
                      (a."Date" + coalesce(public._advance_order_time(a."Time"), time '00:00')) at time zone 'Asia/Manila') as last_update
      from public."AdvanceOrders" a
      left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
    ),
    page as (
      select b.*, count(*) over() as total
      from base b
      where ((p_transaction_no is not null and trim(p_transaction_no) <> '' and b."TransactionNo" = p_transaction_no)
         or (
           (p_transaction_no is null or trim(p_transaction_no) = '')
           and (
             p_search is null or trim(p_search) = ''
             or b."TransactionNo" ilike '%' || p_search || '%'
             or b."ReceiptNo" ilike '%' || p_search || '%'
             or b."CustomerName" ilike '%' || p_search || '%'
             or b."UserID" ilike '%' || p_search || '%'
             or b."OnlineOrderID" ilike '%' || p_search || '%'
           )
         ))
        and (v_status is null
             or (v_status = 'New' and b.status is null)
             or b.status = v_status)
        and (v_branch is null or lower(trim(coalesce(b."Warehouse", ''))) = v_branch)
      order by b.last_update desc nulls last,
               case when b."TransactionNo" ~ '^\d+$' then b."TransactionNo"::numeric end desc nulls last,
               b."TransactionNo" desc
      limit v_page_size offset (v_page - 1) * v_page_size
    )
    select pg."TransactionNo"::text, pg."ReceiptNo"::text, pg."UserID"::text, pg."CustomerName"::text, pg."Order_Description"::text,
           pg."Date", pg."Time"::text, pg."NetAmount", pg."Downpayment", pg."Balance",
           pg."OnlineOrderID"::text,
           coalesce(pg."FullyPaid", false) or coalesce(pg."Balance", 0) <= 0,
           pg."DatePaid", pg."Warehouse"::text, pg."SyncedAtUtc",
           pg.status,
           (pg.prod)."TankMaker", tank."DisplayName"::text,
           (pg.prod)."StandMaker", stand."DisplayName"::text,
           (pg.prod)."TankDoneAtUtc", (pg.prod)."StandDoneAtUtc",
           (pg.prod)."ToShipAtUtc", (pg.prod)."ToShipBy",
           (pg.prod)."ShippedAtUtc", (pg.prod)."ShippedBy",
           n.needs_tank, n.needs_stand,
           (select count(*)::int from public."AdvanceOrderRework" r where r."TransactionNo" = pg."TransactionNo" and r."FixedAtUtc" is null),
           pg.total
    from page pg
    cross join lateral public._advance_order_needs(pg."TransactionNo") n
    left join public."StaffUsers" tank on tank."Username" = (pg.prod)."TankMaker"
    left join public."StaffUsers" stand on stand."Username" = (pg.prod)."StandMaker"
    order by pg.last_update desc nulls last,
             case when pg."TransactionNo" ~ '^\d+$' then pg."TransactionNo"::numeric end desc nulls last,
             pg."TransactionNo" desc;
end;
$$;

grant execute on function public.admin_list_advance_orders(text, text, text, text, int, int, text) to anon;

-- Counts per stage for the tab's status pills.
create or replace function public.staff_get_advance_order_status_summary(p_admin_username text, p_admin_password text)
returns table(status text, order_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch text; -- null = all branches; else a Store Manager's own branch (lower-cased)
begin
  if public.is_admin_authorized(p_admin_username, p_admin_password) then
    v_branch := null;
  elsif public.is_staff_authorized(p_admin_username, p_admin_password) and public._advance_order_is_viewer(p_admin_username) then
    v_branch := public._advance_order_viewer_branch(p_admin_username);
  else
    raise exception 'Not authorized.';
  end if;
  return query
    select coalesce(public._advance_order_prod_status(p), 'New'), count(*)
    from public."AdvanceOrders" a
    left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
    where v_branch is null or lower(trim(coalesce(a."Warehouse", ''))) = v_branch
    group by 1;
end;
$$;

grant execute on function public.staff_get_advance_order_status_summary(text, text) to anon;

-- Lines + rework history: managers, Super Users, a Store Manager for an order of their own branch, or a
-- maker assigned to that order.
create or replace function public._advance_order_can_view(p_username text, p_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._production_is_manager(p_username)
      or (public._advance_order_is_viewer(p_username)
          and exists (select 1 from public."AdvanceOrders" a
                      where a."TransactionNo" = p_no
                        and lower(trim(coalesce(a."Warehouse", ''))) = public._advance_order_viewer_branch(p_username)))
      or exists (select 1 from public."StaffUsers" where "Username" = p_username and "IsActive" and "SuperUser")
      or exists (select 1 from public."AdvanceOrderProduction" p
                 where p."TransactionNo" = p_no and p_username in (p."TankMaker", p."StandMaker"));
$$;

revoke execute on function public._advance_order_can_view(text, text) from public, anon, authenticated;
