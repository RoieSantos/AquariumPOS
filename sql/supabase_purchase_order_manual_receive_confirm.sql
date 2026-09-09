-- Recovery path for exactly the scenario the "Failed" Pancake sync warning in js/purchaseOrders.js
-- describes (per direct request: "if I choose cancel and confirm that the pancake already has the
-- products adjusted as PO.. how can I change the status to fully received?"). Pancake has no
-- confirmed GET/list-by-note endpoint and no confirmed idempotency key (see
-- supabase_purchase_order_pancake_sync.sql's header comment), so a 'Failed' sync attempt (a
-- connection/timeout error, unlike 'Rejected' which is a definite 4xx that could not have gone
-- through) is genuinely ambiguous - it may have actually created the stock-in in Pancake despite
-- the app never seeing a success response. Local QtyReceived is only ever incremented on a
-- 'Synced' result, so once staff manually check Pancake's own purchase list and confirm the
-- stock-in is already there, there was previously no way to bring the Purchase Order's local
-- QtyReceived in line with that reality without staff_receive_purchase_order_lines attempting
-- ANOTHER live Pancake POST - which, now that the first is confirmed to have landed, would create
-- a genuine second, duplicate stock-in.
--
-- Super-user only (is_admin_authorized, not is_staff_authorized like the normal Receive) -
-- deliberately harder to reach than an everyday action, since this bypasses the one safety net the
-- normal path has (Pancake's own confirmation) and trusts a human's manual check instead. Every use
-- is logged into PurchaseOrder_Pancake_Purchases with Sync Status 'ManuallyConfirmed' (never
-- 'Synced', which is reserved for an actual Pancake API confirmation) so the Pancake Sync panel
-- keeps an honest, auditable record of who bypassed the sync and when.
drop function if exists public.staff_confirm_purchase_order_receipt_without_sync(text, text, text, jsonb, text);

-- p_lines: JSON array of {entry_no, quantity} - same shape as staff_receive_purchase_order_lines'
-- own p_lines. `quantity` is the amount to mark received in THIS action, capped at each line's
-- remaining (Quantity - QtyReceived), same running-total/cap rule as the normal Receive.
create or replace function public.staff_confirm_purchase_order_receipt_without_sync(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_lines jsonb,
  p_confirmation_note text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line jsonb;
  v_entry_no bigint;
  v_requested numeric;
  v_po_line record;
  v_increment numeric;
  v_updated_count int := 0;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can confirm a receipt without a Pancake sync.';
  end if;

  if not exists (select 1 from public."PurchaseOrders" where "PONo" = p_po_no) then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one line with a quantity is required.';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_entry_no := nullif(v_line ->> 'entry_no', '')::bigint;
    v_requested := nullif(v_line ->> 'quantity', '')::numeric;
    if v_entry_no is null or v_requested is null or v_requested <= 0 then
      continue;
    end if;

    select * into v_po_line from public."PurchaseOrderLines" where "EntryNo" = v_entry_no and "PONo" = p_po_no;
    if not found then
      continue;
    end if;

    v_increment := least(v_requested, greatest(0, v_po_line."Quantity" - v_po_line."QtyReceived"));
    if v_increment <= 0 then
      continue;
    end if;

    update public."PurchaseOrderLines"
    set "QtyReceived" = least("Quantity", "QtyReceived" + v_increment)
    where "EntryNo" = v_entry_no;

    -- Logged the same shape a real Pancake sync attempt would be (see
    -- staff_receive_purchase_order_lines in supabase_purchase_order_pancake_sync.sql), minus the
    -- actual API call - "Pancake Purchase ID" stays null since none was made, and "Sync Status" of
    -- 'ManuallyConfirmed' (never 'Synced') is what tells the Pancake Sync panel this row was a
    -- human override, not an API confirmation.
    insert into public."PurchaseOrder_Pancake_Purchases"
      ("PONo", "WarehouseId", "WarehouseName", "Items Json", "Sync Status", "Sync Error", "ReceivedBy")
    values (
      p_po_no,
      coalesce(v_po_line."WarehouseId", ''),
      v_po_line."WarehouseName",
      jsonb_build_array(jsonb_build_object('entry_no', v_entry_no, 'item_code', v_po_line."ItemCode", 'quantity', v_increment)),
      'ManuallyConfirmed',
      coalesce(nullif(trim(p_confirmation_note), ''), 'Marked received without a Pancake sync - staff manually verified in Pancake that this stock-in already exists there.'),
      p_admin_username
    );

    v_updated_count := v_updated_count + 1;
  end loop;

  if v_updated_count = 0 then
    raise exception 'No matching line(s) with a quantity greater than zero remain to be received.';
  end if;
end;
$$;

grant execute on function public.staff_confirm_purchase_order_receipt_without_sync(text, text, text, jsonb, text) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_confirm_purchase_order_receipt_without_sync';
