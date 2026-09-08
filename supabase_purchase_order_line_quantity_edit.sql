-- Editable Qty Ordered on an open Purchase Order line, per "in the PO can we modify the Qty
-- Ordered too?". Until now a quantity could only be set as the line was created - a vendor
-- confirming a different quantity meant removing the line and re-adding it.
--
-- The quantity is entered in the line's OWN ordering unit, the same as its Unit Cost
-- (supabase_units_of_measure.sql): type 5 on a BOX(12) line and the stored base quantity becomes
-- 60. The conversion is applied here rather than in the browser, so it has one home.
--
-- NOT blocked outright once received, unlike the unit cost. A quantity that changes after a
-- partial delivery is ordinary - the vendor short-ships, or you cut the balance of the order - and
-- blocking it would leave "remove the line and re-add it" as the only route, which loses the
-- receipt history. What IS blocked is dropping below what has already arrived: that quantity is
-- real stock in Pancake, and an order claiming to be for less than was received would make the
-- outstanding balance negative and the "Fully Received" badge a lie.
--
-- Super-user only (is_admin_authorized), matching staff_set_purchase_order_line_cost and
-- staff_set_purchase_order_line_uom - changing what was ordered is structural, not a note.

drop function if exists public.staff_set_purchase_order_line_quantity(text, text, bigint, numeric);

create or replace function public.staff_set_purchase_order_line_quantity(
  p_admin_username text,
  p_admin_password text,
  p_entry_no bigint,
  p_quantity_uom numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line record;
  v_qty_per numeric;
  v_new_quantity numeric;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can edit an existing Purchase Order.';
  end if;

  select * into v_line from public."PurchaseOrderLines" where "EntryNo" = p_entry_no;

  if not found then
    raise exception 'Purchase Order line not found - it may already be posted.';
  end if;

  if p_quantity_uom is null or p_quantity_uom <= 0 then
    raise exception 'Quantity must be greater than 0. To take the item off the order, remove the line.';
  end if;

  v_qty_per := coalesce(v_line."QtyPerUnitOfMeasure", 1);
  v_new_quantity := p_quantity_uom * v_qty_per;

  if v_new_quantity < coalesce(v_line."QtyReceived", 0) then
    raise exception 'This line has already received % - the order cannot be reduced below that.',
      trim(to_char(v_line."QtyReceived", 'FM999999990.00'));
  end if;

  update public."PurchaseOrderLines"
     set "Quantity" = v_new_quantity,
         -- Kept in step so the line keeps reading in the unit it was ordered in. A line raised
         -- before units existed has no QuantityUom and no conversion, so the two are the same
         -- number and it simply starts carrying one.
         "QuantityUom" = p_quantity_uom
   where "EntryNo" = p_entry_no;
end;
$$;

grant execute on function public.staff_set_purchase_order_line_quantity(text, text, bigint, numeric) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_set_purchase_order_line_quantity';
