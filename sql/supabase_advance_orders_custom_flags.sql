-- Advance Orders tab: same "Custom" and "10mm / 12mm glass" flags as the Online Orders list - per "in the
-- advance order.. can we apply same flags too if needed a custom".
--
--   has_custom_line - any line whose Description / No contains "custom" (same keyword as online orders'
--                     has_custom_line), so it's obvious which advance orders need production work.
--   glass_thickness - '12mm' / '10mm' / null from the lines' Description / No (12mm wins, same priority
--                     as the online orders' GlassThickness and detectGlassThickness in onlineOrderLines.js).
--
-- Re-creates admin_list_advance_orders exactly as in supabase_advance_orders_store_manager_view.sql (same
-- auth, branch filter, latest-update sort), with only those two columns added at the end before
-- total_count.
--
-- Run AFTER supabase_advance_orders_store_manager_view.sql. Safe to re-run. If that file is ever re-run,
-- run this one again afterwards (it would drop the two flag columns - the page just hides the badges).

-- Custom / glass flags from an advance order's lines.
create or replace function public._advance_order_flags(p_no text, out has_custom_line boolean, out glass_thickness text)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(bool_or(coalesce(l."Description", '') ilike '%custom%' or coalesce(l."No", '') ilike '%custom%'), false),
         case
           when bool_or(regexp_replace(coalesce(l."Description", '') || coalesce(l."No", ''), '\s', '', 'g') ilike '%12mm%') then '12mm'
           when bool_or(regexp_replace(coalesce(l."Description", '') || coalesce(l."No", ''), '\s', '', 'g') ilike '%10mm%') then '10mm'
         end
  from public."AdvanceOrderLines" l
  where l."TransactionNo" = p_no;
$$;

revoke execute on function public._advance_order_flags(text) from public, anon, authenticated;

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
  has_custom_line boolean,      -- this file
  glass_thickness text,         -- this file: '12mm' / '10mm' / null
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
  -- the lines suggest, custom / glass flags, open rework, maker names) for just the rows on this page.
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
           f.has_custom_line, f.glass_thickness,
           pg.total
    from page pg
    cross join lateral public._advance_order_needs(pg."TransactionNo") n
    cross join lateral public._advance_order_flags(pg."TransactionNo") f
    left join public."StaffUsers" tank on tank."Username" = (pg.prod)."TankMaker"
    left join public."StaffUsers" stand on stand."Username" = (pg.prod)."StandMaker"
    order by pg.last_update desc nulls last,
             case when pg."TransactionNo" ~ '^\d+$' then pg."TransactionNo"::numeric end desc nulls last,
             pg."TransactionNo" desc;
end;
$$;

grant execute on function public.admin_list_advance_orders(text, text, text, text, int, int, text) to anon;

notify pgrst, 'reload schema';
