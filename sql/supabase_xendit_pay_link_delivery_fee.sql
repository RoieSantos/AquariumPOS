-- Xendit pay link: include the delivery fee on orders not yet confirmed - per "if the order has delivery fee will
-- it send a paylink with the delivery fee as well?".
--
-- Bug: the Messenger pay-link message (Conversations card) uses AutomatedOrders."EstimatedTotal" = items + fee, but
-- pay.html / the Xendit checkout worked out an unconfirmed (AO draft) order's total with _automated_order_total =
-- items only. So the message said e.g. Full balance 1,200 while the pay page charged 1,000, and after confirm the
-- order still had the 200 fee due. Confirmed orders were already right (OnlineOrders Balance includes the fee).
--
-- Fix: _xendit_resolve_order now counts the draft total as items + DeliveryFee (Delivery orders only), the same
-- total _xendit_try_auto_confirm and the order card use. With no lines yet it falls back to EstimatedTotal (which
-- already includes the fee). Everything that reads it follows: pay.html, the checkout amount, Vic / Alice's
-- payment lookup. _automated_order_total itself is left alone (other pages use it).
--
-- Only _xendit_resolve_order changes; it is otherwise the same as supabase_xendit_pos_walkin.sql.
-- Run AFTER supabase_xendit_pos_walkin.sql. Safe to re-run. No Edge Function or JS change.

create or replace function public._xendit_resolve_order(p_ref text)
returns table(order_ref text, automated_order_no text, online_order_id text, order_status text,
              is_cancelled boolean, is_portal boolean, total numeric, amount_paid numeric, balance numeric,
              customer_name text, customer_phone text, customer_email text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_ref text := upper(trim(coalesce(p_ref, '')));
  v_ao public."AutomatedOrders"%rowtype;
  v_has_ao boolean := false;
  v_oo public."OnlineOrders"%rowtype;
  v_has_oo boolean := false;
  v_paid numeric;
  v_total numeric;
  v_status text;
  -- Paid at Xendit but not on the order yet (failed / still applying) - counted as paid so the
  -- customer is never asked to pay it again.
  v_unapplied numeric;
begin
  if v_ref = '' then
    return;
  end if;

  select * into v_ao from public."AutomatedOrders" where upper("OrderNo") = v_ref;
  v_has_ao := found;
  if v_has_ao then
    select * into v_oo from public."OnlineOrders"
     where "OrderID" = coalesce(nullif(trim(v_ao."PancakeReceiptNo"), ''), v_ao."OrderNo");
    v_has_oo := found;
  else
    select * into v_oo from public."OnlineOrders" where "OrderID" = trim(p_ref);
    v_has_oo := found;
    if not v_has_oo then
      return;
    end if;
    select * into v_ao from public."AutomatedOrders" where "PancakeReceiptNo" = v_oo."OrderID" limit 1;
    v_has_ao := found;
  end if;

  select coalesce(sum(coalesce(x."PaidAmount", x."Amount")), 0) into v_unapplied
    from public."XenditPayments" x
   where x."Status" = 'Paid' and x."ApplyStatus" in ('Pending', 'Failed')
     and (x."AutomatedOrderNo" = v_ao."OrderNo" or x."OnlineOrderID" = v_oo."OrderID");

  if v_has_oo then
    v_paid := coalesce(v_oo."AmountPaid", 0);
    v_total := coalesce(v_oo."AmountPaid", 0) + coalesce(v_oo."Balance", 0);
    v_status := v_oo."Status";
  else
    v_paid := coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = v_ao."OrderNo"), 0);
    -- This file: items + delivery fee, like the order card and _xendit_try_auto_confirm.
    select sum(l."Price" * l."Quantity") into v_total
      from public."AutomatedOrderLines" l where l."OrderNo" = v_ao."OrderNo";
    if v_total is null then
      v_total := coalesce(v_ao."EstimatedTotal", 0);
    else
      v_total := v_total + case when v_ao."FulfillmentType" = 'Delivery' then coalesce(v_ao."DeliveryFee", 0) else 0 end;
    end if;
    v_status := v_ao."Status";
  end if;
  v_paid := v_paid + v_unapplied;

  return query select
    case when v_has_ao then v_ao."OrderNo" else v_oo."OrderID" end::text,
    case when v_has_ao then v_ao."OrderNo" end::text,
    case when v_has_oo then v_oo."OrderID" end::text,
    v_status::text,
    lower(trim(coalesce(v_status, ''))) in ('canceled', 'cancelled', 'cancel', 'returned', 'returning'),
    case when v_has_oo then public._is_portal_only_online_order(v_oo."OrderID") and v_oo."PosReceiptNo" is null else true end,
    round(v_total, 2),
    round(v_paid, 2),
    round(greatest(v_total - v_paid, 0), 2),
    coalesce(nullif(trim(v_ao."CustomerName"), ''), v_oo."CustomerName")::text,
    coalesce(nullif(trim(v_ao."CustomerPhone"), ''), v_oo."ShippingPhone")::text,
    nullif(trim(coalesce(v_ao."CustomerEmail", '')), '')::text;
end;
$$;

revoke all on function public._xendit_resolve_order(text) from public, anon, authenticated;

-- Check: unconfirmed delivery orders with a fee, open balance - pay_page_total should now equal card_total.
select a."OrderNo"                      as order_no,
       a."FulfillmentType"              as fulfillment,
       a."DeliveryFee"                  as delivery_fee,
       a."EstimatedTotal"               as card_total,
       r.total                          as pay_page_total,
       r.balance                        as pay_page_balance,
       a."EstimatedTotal" = r.total     as matches
  from public."AutomatedOrders" a
  cross join lateral public._xendit_resolve_order(a."OrderNo") r
 where coalesce(a."PancakeSyncStatus", '') = 'Not Pushed'
   and a."Status" not in ('Completed', 'Cancelled')
   and coalesce(a."DeliveryFee", 0) > 0
 order by a."OrderNo" desc
 limit 50;
