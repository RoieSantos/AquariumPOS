-- Add an item line to a confirmed online order - Super Users and Sales Users. Per "can we add items too?"
-- (after Change Item / line edit, supabase_order_line_change_variant.sql / supabase_online_order_line_edit.sql).
--
-- PORTAL orders only (Source 'Portal'): the line goes into AutomatedOrderLines (the order's source, so the
-- receipt / invoice / GMA order card show it) and OnlineOrderLines with LineID = its EntryNo - the same shape
-- admin_confirm_bot_order (supabase_gma_order_delivery_fee.sql) gives every confirmed line. Old
-- Pancake-backed orders are refused (no new Pancake writes since 2026-10-21).
--
-- Money follows: qty x price is added to OnlineOrders Money to Collect / Balance and AutomatedOrders
-- EstimatedTotal (same fields the line edit moves). The Item Ledger posts it on its own
-- (TR_OnlineOrderLines_ItemLedgerQueue). Logged in OrderLineEditHistory as Field 'Added', so the line shows
-- "Edited by X" and appears in Edit History.
--
-- Same status rules as Change Item: up to and including To Ship (Packing and later locked); at To Ship
-- also not a SET or a serial-tracked item (the SET assembly / serial pick already happened at Ready to Ship).
--
-- Run AFTER supabase_order_line_change_variant.sql (helpers) and supabase_online_order_line_edit.sql
-- (history table). Safe to re-run. Needs js/onlineOrders.js ?v=addline1.

drop function if exists public.staff_add_online_order_line(text, text, text, text, numeric, numeric, text);

create or replace function public.staff_add_online_order_line(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_variation_id text,
  p_quantity numeric,
  p_price numeric default null,         -- null = the item's list price
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_status text;
  v_found boolean;
  v_to_ship boolean;
  v_new record;
  v_category text;
  v_qty int;
  v_price numeric(18, 2);
  v_amount numeric(18, 2);
  v_entry_no bigint;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._can_change_order_line_item(p_admin_username) then
    raise exception 'Only a Super User or Sales User can add an order line.';
  end if;
  if p_quantity is null or p_quantity < 1 or p_quantity <> trunc(p_quantity) then
    raise exception 'Quantity must be a whole number, 1 or more.';
  end if;
  v_qty := p_quantity::int;
  if p_price is not null and p_price < 0 then
    raise exception 'Unit Price can''t be negative.';
  end if;

  begin
    select "Status", true into v_status, v_found from public."OnlineOrders" where "OrderID" = v_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (another update is still running on it). Wait a moment and try again.', v_order_id;
  end;
  if not coalesce(v_found, false) then
    raise exception 'Order % not found.', v_order_id;
  end if;
  if not public._is_portal_only_online_order(v_order_id) then
    raise exception 'Order % is an old Pancake order - lines can only be added to portal orders.', v_order_id;
  end if;
  if not exists (select 1 from public."AutomatedOrders" where "OrderNo" = v_order_id) then
    raise exception 'Order % has no portal source order - lines can''t be added.', v_order_id;
  end if;
  if lower(trim(coalesce(v_status, ''))) in ('packing', 'packed', 'shipped', 'delivered', 'completed',
                                             'received', 'canceled', 'cancelled', 'returned', 'returning', 'deleted') then
    raise exception 'Order % is % - lines can only be added up to To Ship.', v_order_id, v_status;
  end if;
  v_to_ship := lower(trim(coalesce(v_status, ''))) = 'to ship';

  select * into v_new from public._order_line_variant_candidates() c where c.variation_id = trim(coalesce(p_variation_id, '')) limit 1;
  if not found then
    raise exception 'That product wasn''t found - search and pick it again.';
  end if;
  v_category := public._online_order_line_category(v_new.variation_id, v_new.item_code);

  if v_to_ship then
    if upper(coalesce(v_category, '')) = 'SET' then
      raise exception 'Order % is at To Ship - a SET can only be added before To Ship (it needs assembling).', v_order_id;
    end if;
    if public._order_line_item_needs_serial(v_new.variation_id, v_new.item_code) then
      raise exception '% takes a serial and order % is already at To Ship (serials were picked at Ready to Ship) - add it before To Ship.', v_new.label, v_order_id;
    end if;
  end if;

  v_price := round(coalesce(p_price, v_new.price, 0), 2);
  v_amount := v_price * v_qty;

  insert into public."AutomatedOrderLines"
    ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId")
  values (v_order_id, left(nullif(trim(coalesce(v_category, '')), ''), 100), v_new.item_code, left(v_new.label, 255),
          v_qty, v_price, v_note, v_new.variation_id)
  returning "EntryNo" into v_entry_no;

  insert into public."OnlineOrderLines" (
    "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price",
    "Discount", "GrossAmount", "NetAmount", "Note", "Description", "SyncedAtUtc"
  ) values (
    v_order_id, v_entry_no::text, v_new.item_code, v_new.item_code, v_new.variation_id, v_qty, null, v_price,
    0, v_amount, v_amount, v_note, left(v_new.label, 500), now()
  );

  if v_amount <> 0 then
    update public."OnlineOrders"
       set "MoneyToCollect" = coalesce("MoneyToCollect", 0) + v_amount,
           "Balance" = coalesce("Balance", 0) + v_amount
     where "OrderID" = v_order_id;
    update public."AutomatedOrders" set "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_amount
     where "OrderNo" = v_order_id;
  end if;

  insert into public."OrderLineEditHistory" ("OrderKind", "OrderNo", "LineNo", "Field", "OldValue", "NewValue", "ChangedBy")
  values ('Online', v_order_id, v_entry_no::text, 'Added', null,
          rtrim(to_char(v_qty, 'FM999,999,990')) || ' x ' || v_new.label || ' @ ' || to_char(v_price, 'FM999,999,990.00'),
          p_admin_username);

  return jsonb_build_object('line_id', v_entry_no::text, 'description', v_new.label, 'quantity', v_qty,
                            'price', v_price, 'money_delta', v_amount);
end;
$$;

grant execute on function public.staff_add_online_order_line(text, text, text, text, numeric, numeric, text) to anon;

notify pgrst, 'reload schema';
