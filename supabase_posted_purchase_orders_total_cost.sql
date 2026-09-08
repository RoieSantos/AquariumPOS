-- Total Cost on the Posted Purchase Orders LIST, per direct request ("in posted purchase orders
-- can you show the total cost"). The detail view (docs/js/postedPurchaseOrders.js's
-- renderViewLines) already totals a posted PO's lines client-side once you open one - this widens
-- staff_list_posted_purchase_orders so the same figure shows in the list itself, without opening
-- each order.
--
-- Costed the same way the detail view/staff_list_posted_purchase_order_lines already does: UnitCost
-- x QtyReceived, not QtyOrdered - a posted PO is a record of money actually committed, and a
-- short-shipped line never cost the full ordered quantity (see
-- supabase_item_cost_and_po_line_cost.sql's own comment on staff_list_posted_purchase_order_lines).
--
-- Base body is supabase_purchase_order_payment_method.sql's version of this function (the current,
-- latest definition - nothing since has touched it) plus total_cost appended.

drop function if exists public.staff_list_posted_purchase_orders(text, text, text, int, int);

create or replace function public.staff_list_posted_purchase_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  po_no text,
  vendor_code text,
  vendor_name text,
  order_date date,
  notes text,
  created_by text,
  created_at_utc timestamptz,
  posted_by text,
  posted_at_utc timestamptz,
  line_count bigint,
  total_quantity numeric,
  total_received_quantity numeric,
  total_count bigint,
  warehouse_name text,
  payment_method text,
  total_cost numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
      po."CreatedBy"::text, po."CreatedAtUtc", po."PostedBy"::text, po."PostedAtUtc",
      count(l."EntryNo"), coalesce(sum(l."Quantity"), 0), coalesce(sum(l."QtyReceived"), 0),
      count(*) over(),
      po."WarehouseName"::text,
      po."PaymentMethod"::text,
      coalesce(sum(coalesce(l."UnitCost", 0) * coalesce(l."QtyReceived", 0)), 0)
    from public."PostedPurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    left join public."PostedPurchaseOrderLines" l on l."PONo" = po."PONo"
    where p_search is null or trim(p_search) = ''
      or po."PONo" ilike '%' || p_search || '%'
      or v."Name" ilike '%' || p_search || '%'
      or po."WarehouseName" ilike '%' || p_search || '%'
    group by po."PONo", po."VendorCode", v."Name", po."OrderDate", po."Notes", po."CreatedBy", po."CreatedAtUtc", po."PostedBy", po."PostedAtUtc", po."WarehouseName", po."PaymentMethod"
    order by po."PostedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.staff_list_posted_purchase_orders(text, text, text, int, int) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_list_posted_purchase_orders';
