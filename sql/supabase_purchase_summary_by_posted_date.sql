-- Dashboard "Total Purchase" card (docs/js/dashboard.js loadPurchaseSummary).
-- Per "in the dashboard can you track the total purchase base on the posted date not the actual
-- date created": the month filter now keys off PostedPurchaseOrders."PostedAtUtc" (converted to
-- Asia/Manila, same month boundary as the other finance cards) instead of the PO's OrderDate.
-- A PO ordered last month but posted this month now counts toward this month's purchases.
--
-- Same signature as supabase_item_cost_and_po_line_cost.sql, so create or replace is enough. That
-- file has the same change, so re-running it won't undo this.

create or replace function public.admin_get_purchase_summary(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(month_purchase numeric, month_po_count int, month_uncosted_po_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
    with month_lines as (
      select l."PONo" as po_no,
             l."UnitCost" as unit_cost,
             coalesce(l."QtyReceived", 0) as qty_received
      from public."PostedPurchaseOrderLines" l
      join public."PostedPurchaseOrders" h on h."PONo" = l."PONo"
      where (h."PostedAtUtc" at time zone 'Asia/Manila')::date >= v_month_start
        and (h."PostedAtUtc" at time zone 'Asia/Manila')::date < v_month_end
        -- Scoped on the LINE's warehouse, not the header - a PO can span warehouses, and a
        -- warehouse-scoped user should see only the part that landed in theirs.
        and (p_warehouse_name is null or trim(p_warehouse_name) = '' or l."WarehouseName" = p_warehouse_name)
    )
    select
      coalesce(sum(round(coalesce(unit_cost, 0) * qty_received, 2)), 0)::numeric,
      count(distinct po_no)::int,
      count(distinct po_no) filter (where unit_cost is null and qty_received > 0)::int
    from month_lines;
end;
$$;

grant execute on function public.admin_get_purchase_summary(text, text, text) to anon;
