-- Advance Orders: "TO FOLLOW" badge + filter, and a "No serial yet" tag per line - per "so the products
-- that has no serials will push to the advance orders in the portal with tag?" / "yes".
--
-- Context: the POS now saves a sale with an out-of-stock serial-tracked unit (no serial - the POS can't
-- create serials anymore) as an Advance Order, Paid in Full when the customer pays everything. Until now the
-- portal couldn't tell "paid, tank still owed" from "paid and released" - both just showed Fully Paid = Yes.
--
-- An order is TO FOLLOW when ALL of these hold:
--   - fully paid (FullyPaid, or Balance <= 0 - same rule as admin_list_advance_orders' fully_paid);
--   - not Shipped / Delivered yet (_advance_order_prod_status);
--   - at least one serial-tracked unit still has no serial tied to the order - same count as
--     staff_get_advance_order_serial_requirements' quantity_needed (_advance_order_line_items +
--     _advance_order_serials, SOLD serials linked 'ADV-<TransactionNo>');
--   - placed on/after 2026-10-09 (when Ready to Ship started tagging serials, supabase_advance_order_serials.sql)
--     OR already in the production flow (has an AdvanceOrderProduction row). Older orders were released
--     before serials were ever tagged on advance orders, so without this cut-off every old paid order
--     would show as TO FOLLOW forever. To move the cut-off, change v_since in _advance_order_to_follow_since.
--
--   staff_get_advance_orders_to_follow(user, pw, p_nos) - p_nos null: every TO FOLLOW order the user can
--       see (pill count + filter); p_nos given: those orders' unit counts (badges on the visible page).
--   staff_get_advance_order_line_serial_status(user, pw, p_no) - per ITEM line: needs a serial? qty,
--       units tagged, units still without a serial ("No serial yet" tag in the order's lines).
--
-- admin_list_advance_orders is deliberately NOT changed (it has had two overloads side by side before -
-- see supabase_advance_orders_drop_old_list_overload.sql); the portal calls these alongside it.
--
-- Run AFTER supabase_advance_order_serials.sql, supabase_advance_order_sticker_no_serial.sql,
-- supabase_advance_orders_store_manager_view.sql and supabase_delivery_stop_done_post.sql. Safe to re-run.
-- Needs js/onlineOrders.js + online-orders.html cache v=tofollow1.

create or replace function public._advance_order_to_follow_since()
returns date
language sql
immutable
as $$
  select date '2026-10-09';
$$;

revoke execute on function public._advance_order_to_follow_since() from public, anon, authenticated;

-- Serial-tracked units on an order: total, tagged (SOLD serial tied to it), still untagged (internal).
create or replace function public._advance_order_unit_counts(p_no text,
  out units_total int, out units_tagged int, out units_untagged int)
language sql
stable
security definer
set search_path = public
as $$
  with lines as (
    select li.item_code as code, coalesce(li.variation_id, '') as variant, li.quantity as qty
    from public._advance_order_line_items(p_no) li
    where li.needs_serial
  ),
  grouped as (
    select code, variant, sum(qty)::int as total from lines group by code, variant
  ),
  tagged as (
    select s."ItemCode" as code, coalesce(s."VariantCode", '') as variant, count(*)::int as n
    from public._advance_order_serials(p_no) s
    where s."Status" = 'SOLD'
    group by 1, 2
  )
  select coalesce(sum(g.total), 0)::int,
         coalesce(sum(least(coalesce(t.n, 0), g.total)), 0)::int,
         coalesce(sum(greatest(g.total - coalesce(t.n, 0), 0)), 0)::int
  from grouped g
  left join tagged t on t.code = g.code and t.variant = g.variant;
$$;

revoke execute on function public._advance_order_unit_counts(text) from public, anon, authenticated;

drop function if exists public.staff_get_advance_orders_to_follow(text, text, text[]);

create or replace function public.staff_get_advance_orders_to_follow(
  p_admin_username text,
  p_admin_password text,
  p_nos text[] default null
)
returns table(
  transaction_no text,
  units_total int,
  units_tagged int,
  units_to_follow int,  -- serial-tracked units with no serial yet
  to_follow boolean     -- the TO FOLLOW badge (rules above)
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch text; -- null = all branches; else a Store Manager's own branch (lower-cased)
begin
  -- Same access as admin_list_advance_orders (supabase_advance_orders_store_manager_view.sql).
  if public.is_admin_authorized(p_admin_username, p_admin_password) then
    v_branch := null;
  elsif public.is_staff_authorized(p_admin_username, p_admin_password) and public._advance_order_is_viewer(p_admin_username) then
    v_branch := public._advance_order_viewer_branch(p_admin_username);
  else
    raise exception 'Not authorized.';
  end if;

  return query
    with candidates as (
      select a."TransactionNo"::text as no,
             (coalesce(a."FullyPaid", false) or coalesce(a."Balance", 0) <= 0)
               and coalesce(public._advance_order_prod_status(p), '') not in ('Shipped', 'Delivered')
               and (a."Date" >= public._advance_order_to_follow_since() or p."TransactionNo" is not null) as eligible
      from public."AdvanceOrders" a
      left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
      where (v_branch is null or lower(trim(coalesce(a."Warehouse", ''))) = v_branch)
        and (case when p_nos is null then true else a."TransactionNo" = any(p_nos) end)
    ),
    -- the full list (p_nos null) only needs the TO FOLLOW ones - don't count serials on every old order
    checked as (
      select c.* from candidates c where p_nos is not null or c.eligible
    )
    select c.no, u.units_total, u.units_tagged, u.units_untagged,
           c.eligible and u.units_untagged > 0
    from checked c
    cross join lateral public._advance_order_unit_counts(c.no) u
    where p_nos is not null or u.units_untagged > 0
    order by c.no;
end;
$$;

grant execute on function public.staff_get_advance_orders_to_follow(text, text, text[]) to anon;

drop function if exists public.staff_get_advance_order_line_serial_status(text, text, text);

-- Per ITEM line: does it need a serial, and how many of its units have one. Tagged serials are counted per
-- item/variant and handed out to that item's lines in line order (a serial isn't tied to a line number).
create or replace function public.staff_get_advance_order_line_serial_status(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(
  line_no text,
  needs_serial boolean,
  quantity int,
  quantity_tagged int,
  quantity_untagged int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_view(p_admin_username, p_no) then
    raise exception 'Not authorized.';
  end if;

  return query
    with lines as (
      select li.line_no, li.needs_serial, coalesce(li.quantity, 0)::int as qty,
             li.item_code as code, coalesce(li.variation_id, '') as variant,
             case when li.line_no ~ '^\d+$' then li.line_no::numeric end as line_sort
      from public._advance_order_line_items(p_no) li
    ),
    tagged as (
      select s."ItemCode" as code, coalesce(s."VariantCode", '') as variant, count(*)::int as n
      from public._advance_order_serials(p_no) s
      where s."Status" = 'SOLD'
      group by 1, 2
    ),
    running as (
      select l.*,
             coalesce(t.n, 0) as tagged_total,
             sum(l.qty) over (partition by l.code, l.variant order by l.line_sort nulls last, l.line_no
                              rows between unbounded preceding and current row) - l.qty as qty_before
      from lines l
      left join tagged t on t.code = l.code and t.variant = l.variant
      where l.needs_serial
    )
    select l.line_no::text, l.needs_serial, l.qty,
           case when l.needs_serial then least(l.qty, greatest(r.tagged_total - r.qty_before, 0))::int else 0 end,
           case when l.needs_serial then (l.qty - least(l.qty, greatest(r.tagged_total - r.qty_before, 0)))::int else 0 end
    from lines l
    left join running r on r.line_no = l.line_no
    order by l.line_sort nulls last, l.line_no;
end;
$$;

grant execute on function public.staff_get_advance_order_line_serial_status(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one row: how many TO FOLLOW orders exist right now (every branch).
with eligible as (
  select a."TransactionNo"
  from public."AdvanceOrders" a
  left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
  where (coalesce(a."FullyPaid", false) or coalesce(a."Balance", 0) <= 0)
    and coalesce(public._advance_order_prod_status(p), '') not in ('Shipped', 'Delivered')
    and (a."Date" >= public._advance_order_to_follow_since() or p."TransactionNo" is not null)
)
select count(*) filter (where u.units_untagged > 0) as to_follow_orders,
       count(*) as paid_not_shipped_orders_checked,
       public._advance_order_to_follow_since() as counting_orders_since
from eligible e
cross join lateral public._advance_order_unit_counts(e."TransactionNo") u;
