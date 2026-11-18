-- Slow & Fast Moving Items report (Web Portal, Reports > Sales) - per "Which products are
-- slow-moving? and Fast moving items".
--
-- One row per item (variants combined), classified over a look-back window (p_days, default 90):
--   * SALES  - public."OnlineOrderLines" joined to public."OnlineOrders", the same source the Top
--     Selling Items / Category Sales reports use (online orders + in-store orders received at the
--     shop). Cancelled orders excluded. Revenue = bundle share for custom aquarium builds
--     (OnlineOrderLineBundleRevenue), else GrossAmount - same as admin_get_top_selling_items.
--   * STOCK  - SUM(ItemLedgerEntries.Quantity) across all warehouses: the portal's stock source of
--     truth (Stock On Hand page reads the same ledger).
--   * LAST SOLD - all-time latest order date for the item, so a "Not Moving" item still shows when
--     it last sold.
--
-- CLASSIFICATION (among items that sold at least once in the window, ranked by units sold):
--   Fast       = top 20% of selling items
--   Medium     = next 30%
--   Slow       = bottom 50%
--   Not Moving = zero sales in the window (active items, or any item still holding stock)
-- Ties share the same rank (cume_dist), so equal sellers never land in different classes.
-- Items in the "PRODUCTION ITEM" category (build materials) are left out of Slow / Not Moving.
--
-- Cost / stock value at cost are only returned to Super Users (is_admin_authorized); other staff
-- who can see Sales reports get null there and the page hides those columns.
--
-- Read-only. Safe to re-run.

drop function if exists public.admin_get_slow_fast_moving_items(text, text, int);

create or replace function public.admin_get_slow_fast_moving_items(
  p_admin_username text,
  p_admin_password text,
  p_days int default 90
)
returns table(
  item_code text,
  item_name text,
  category_code text,
  category_name text,
  is_active boolean,
  qty_sold numeric,
  revenue numeric,
  order_count bigint,
  last_sold_date date,
  stock_on_hand numeric,
  unit_cost numeric,
  unit_price numeric,
  movement_class text,
  sales_rank bigint,
  last_entry_date date,
  last_entry_type text,
  last_entry_doc text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 90), 7), 730);
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_from date;
  v_show_cost boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_show_cost := public.is_admin_authorized(p_admin_username, p_admin_password);
  v_from := v_today - (v_days - 1);

  return query
    with sold_lines as (
      select l."ItemCode" as code,
             o."Date"::date as order_date,
             l."OrderID" as order_id,
             l."Quantity" as qty,
             coalesce(br."Revenue", l."GrossAmount") as amount
      from public."OnlineOrderLines" l
      join public."OnlineOrders" o on o."OrderID" = l."OrderID"
      left join public."OnlineOrderLineBundleRevenue" br on br."OrderID" = l."OrderID" and br."LineID" = l."LineID"
      where nullif(trim(l."ItemCode"), '') is not null
        and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled')
    ),
    period_sales as (
      select s.code,
             sum(s.qty) as p_qty,
             sum(s.amount) as p_rev,
             count(distinct s.order_id)::bigint as p_orders
      from sold_lines s
      where s.order_date >= v_from and s.order_date <= v_today
      group by s.code
      having sum(s.qty) > 0
    ),
    last_sold as (
      select s.code, max(s.order_date) as last_date
      from sold_lines s
      where s.order_date <= v_today
      group by s.code
    ),
    stock as (
      select e."ItemCode" as code, sum(e."Quantity") as on_hand
      from public."ItemLedgerEntries" e
      where e."PostingDate" <= v_today
      group by e."ItemCode"
    ),
    last_entry as (
      select distinct on (e."ItemCode") e."ItemCode" as code, e."PostingDate" as l_date,
             e."EntryType" as l_type,
             trim(concat_ws(' ', nullif(trim(e."DocumentType"), ''), nullif(trim(e."DocumentNo"), ''))) as l_doc
      from public."ItemLedgerEntries" e
      where e."PostingDate" <= v_today
      order by e."ItemCode", e."PostingDate" desc, e."EntryNo" desc
    ),
    universe as (
      select i."Code" as code from public."Items" i where coalesce(i."IsActive", true)
      union
      select st.code from stock st where st.on_hand <> 0
      union
      select ps.code from period_sales ps
    ),
    ranked as (
      select ps.code,
             rank() over (order by ps.p_qty desc)::bigint as rnk,
             cume_dist() over (order by ps.p_qty desc) as cd
      from period_sales ps
    )
    select
      u.code::text,
      coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), u.code)::text,
      i."CategoryCode"::text,
      coalesce(nullif(trim(cat."Description"), ''), i."CategoryCode")::text,
      coalesce(i."IsActive", true),
      coalesce(ps.p_qty, 0),
      coalesce(ps.p_rev, 0),
      coalesce(ps.p_orders, 0)::bigint,
      ls.last_date,
      coalesce(st.on_hand, 0),
      case when v_show_cost then i."Cost" else null end,
      i."Price",
      case
        when r.code is null then 'Not Moving'
        when r.cd <= 0.20 then 'Fast'
        when r.cd <= 0.50 then 'Medium'
        else 'Slow'
      end::text,
      r.rnk,
      le.l_date,
      le.l_type::text,
      nullif(le.l_doc, '')::text
    from universe u
    left join public."Items" i on i."Code" = u.code
    left join public."Categories" cat on cat."Code" = i."CategoryCode"
    left join period_sales ps on ps.code = u.code
    left join ranked r on r.code = u.code
    left join last_sold ls on ls.code = u.code
    left join stock st on st.code = u.code
    left join last_entry le on le.code = u.code
    -- Items in the "PRODUCTION ITEM" category (glass, tubular, sealant, cutting discs - materials
    -- used to build tanks/stands) are never listed as Slow / Not Moving: per "dont include category
    -- PRODUCTION ITEM". Matched on code or description, ignoring case/spaces/underscores/hyphens.
    -- They still count in the ranking, so Fast/Medium can show them.
    where not (
      (regexp_replace(upper(coalesce(i."CategoryCode", '')), '[^A-Z]', '', 'g') = 'PRODUCTIONITEM'
       or regexp_replace(upper(coalesce(cat."Description", '')), '[^A-Z]', '', 'g') = 'PRODUCTIONITEM')
      and (r.code is null or r.cd > 0.50)
    )
    order by r.rnk nulls last, coalesce(st.on_hand, 0) desc, 2;
end;
$$;

grant execute on function public.admin_get_slow_fast_moving_items(text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- Drill-down for one item (clicking a row on the report) - per "can you let me see the last
-- transaction happen on the item?". Two sections, newest first, p_limit rows each:
--   'sale'   - its order lines (OnlineOrderLines + OnlineOrders), cancelled orders included but
--              flagged by status, so a recent cancellation is visible too.
--   'ledger' - its Item Ledger Entries (purchases, transfers, adjustments, sales postings).
-- Read-only.

drop function if exists public.admin_get_item_recent_transactions(text, text, text, int);

create or replace function public.admin_get_item_recent_transactions(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_limit int default 20
)
returns table(
  section text,
  tx_date date,
  entry_type text,
  document_type text,
  document_no text,
  party text,
  warehouse_name text,
  quantity numeric,
  amount numeric,
  status text,
  posted_by text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 100);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    (
      select 'sale'::text,
             o."Date"::date,
             case when coalesce(o."ReceivedAtShop", false) then 'Walk-in' else 'Online' end::text,
             'Sales Order'::text,
             l."OrderID"::text,
             coalesce(nullif(trim(o."WalkinCustomerName"), ''), nullif(trim(o."CustomerName"), ''))::text,
             w."Name"::text,
             l."Quantity",
             coalesce(br."Revenue", l."GrossAmount"),
             o."Status"::text,
             o."CreatedBy"::text
      from public."OnlineOrderLines" l
      join public."OnlineOrders" o on o."OrderID" = l."OrderID"
      left join public."OnlineOrderLineBundleRevenue" br on br."OrderID" = l."OrderID" and br."LineID" = l."LineID"
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where l."ItemCode" = p_item_code
      order by o."Date" desc, l."OrderID" desc
      limit v_limit
    )
    union all
    (
      select 'ledger'::text,
             e."PostingDate",
             e."EntryType"::text,
             e."DocumentType"::text,
             e."DocumentNo"::text,
             e."Description"::text,
             coalesce(w."Name", e."WarehouseId")::text,
             e."Quantity",
             null::numeric,
             case when e."ReversesEntryNo" is not null then 'Reversal' end::text,
             e."PostedBy"::text
      from public."ItemLedgerEntries" e
      left join public."Warehouses" w on w."ID" = e."WarehouseId"
      where e."ItemCode" = p_item_code
      order by e."PostingDate" desc, e."EntryNo" desc
      limit v_limit
    );
end;
$$;

grant execute on function public.admin_get_item_recent_transactions(text, text, text, int) to anon;
