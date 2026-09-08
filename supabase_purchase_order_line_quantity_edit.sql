-- Editable Qty Ordered on an open Purchase Order line, per "in the PO can we modify the Qty
-- Ordered too?". Until now a quantity could only be set as the line was created - a vendor
-- confirming a different quantity meant removing the line and re-adding it.
--
-- The quantity is entered in the line's OWN ordering unit, the same as its Unit Cost
-- (supabase_units_of_measure.sql): type 5 on a BOX(12) line and the stored base quantity becomes
-- 60. The conversion is applied here rather than in the browser, so it has one home.
--
-- Blocked outright once ANYTHING has been received against the line, per direct request ("once
-- the po has received item or fully received... make Qty Ordered editable = false so the user
-- cannot change the ordered qty") - same gate the client already used for Unit Cost/UoM/Variant
-- (Number(l.qty_received || 0) === 0 in js/purchaseOrders.js). Supersedes this function's original
-- policy, which only blocked dropping below what had already arrived and otherwise allowed editing
-- through a partial delivery (a vendor short-ship, or cutting the balance of the order) without
-- losing receipt history by removing and re-adding the line. That flexibility is intentionally
-- given up here in favor of a firm rule: once a line has receipt history, its ordered quantity is
-- locked.
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

  if coalesce(v_line."QtyReceived", 0) > 0 then
    raise exception 'This line has already received % - the ordered quantity can no longer be changed.',
      trim(to_char(v_line."QtyReceived", 'FM999999990.00'));
  end if;

  if p_quantity_uom is null or p_quantity_uom <= 0 then
    raise exception 'Quantity must be greater than 0. To take the item off the order, remove the line.';
  end if;

  v_qty_per := coalesce(v_line."QtyPerUnitOfMeasure", 1);
  v_new_quantity := p_quantity_uom * v_qty_per;

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
