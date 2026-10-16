-- Payments on Shipped / Delivered / Completed portal orders (AO-xxxxx) - per "once the order is shipped
-- or delivered or any status there are floating payments that not yet fulfilled can a user manually
-- fulfill it?".
--
-- The order card's Payments editor used to disappear once an AO order left the open statuses, so a
-- balance collected on delivery (COD) or paid after shipping could never be recorded and the order stayed
-- "with balance" forever. The card now shows the editor (and a "Settle balance" shortcut) on every status
-- except Cancelled / Returned (js/onlineOrders.js isPayablePortalOrder).
--
-- admin_add_automated_order_payment never checked the status, so Add already worked. This only relaxes
-- the Edit / Delete guard (_ao_payment_editable_order, supabase_ao_order_payment_edit.sql) the same way,
-- so a mistyped final payment can still be fixed: refused only for Cancelled / Returned / Returning
-- orders, and old Pancake orders (their payments live in Pancake). Every edit / delete is still logged in
-- AutomatedOrderPaymentChanges.
--
-- Run AFTER supabase_ao_order_payment_edit.sql. Safe to re-run.
-- Needs online-orders.html with js/onlineOrders.js + js/onlineNewOrders.js ?v=paysettle1.

create or replace function public._ao_payment_editable_order(p_payment_id bigint)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
  v_order public."AutomatedOrders"%rowtype;
  v_online_status text;
begin
  select "OrderNo" into v_order_no from public."AutomatedOrderPayments" where "PaymentId" = p_payment_id;
  if v_order_no is null then
    raise exception 'Payment % not found.', p_payment_id;
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = v_order_no for update;
  if v_order."Status" = 'Cancelled' then
    raise exception 'Order % is Cancelled, its payments can no longer be changed.', v_order_no;
  end if;
  if coalesce(v_order."PancakeSyncStatus", '') not in ('Not Pushed', 'Portal') then
    raise exception 'Order % is a Pancake order - its payments are also in Pancake, fix them there.', v_order_no;
  end if;
  if v_order."PancakeSyncStatus" = 'Portal' then
    select lower(trim(coalesce("Status", ''))) into v_online_status from public."OnlineOrders" where "OrderID" = v_order_no;
    if v_online_status in ('cancelled', 'canceled', 'returned', 'returning') then
      raise exception 'Order % is %, its payments can no longer be changed.', v_order_no, v_online_status;
    end if;
  end if;
  return v_order_no;
end;
$$;

revoke all on function public._ao_payment_editable_order(bigint) from public, anon, authenticated;

notify pgrst, 'reload schema';
