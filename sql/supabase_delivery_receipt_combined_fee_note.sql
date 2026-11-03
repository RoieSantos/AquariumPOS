-- Delivery Receipt / Invoice: show where a combined delivery's one fee was charged - per "in the printout
-- delivery fee can we show its been charge on the original order id".
--
-- In a combined drop charged once (supabase_delivery_combined_drops.sql / supabase_delivery_drops_by_psid.sql)
-- one order carries the fee and the others print "Delivery Fee : 0.00". Now they print
-- "Delivery Fee : 0.00 (charged on AO-00172)", and the order carrying it prints
-- "Delivery Fee : 2,478.00 (covers AO-00184)".
--
-- New admin_get_delivery_stop_fee_note(stop) - a separate small call next to admin_get_delivery_receipt,
-- so that function (patched by several files) is left as it is. Same access as the receipt.
-- An order that rides on another's fee but still has its own fee (already paid, so it was not taken off)
-- gets no note - its printed fee is real.
--
-- Run AFTER supabase_delivery_combined_drops.sql. Safe to re-run. Needs js/deliveryReceipt.js and
-- js/invoice.js ?v=feenote1 (the pages print as before without this file). Ends with one result query.

create or replace function public.admin_get_delivery_stop_fee_note(
  p_admin_username text,
  p_admin_password text,
  p_stop_id uuid
)
returns table(fee_charged_on text, fee_covers text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select case when coalesce(s."ManualDeliveryFee", o."DeliveryFee", 0) = 0
                  then coalesce(c."OrderID", 'ADV-' || c."AdvanceTransactionNo", c."AutomatedOrderNo") end::text,
           (select string_agg(coalesce(r."OrderID", 'ADV-' || r."AdvanceTransactionNo", r."AutomatedOrderNo"), ', '
                              order by r."CreatedAtUtc")
              from public."DeliveryStops" r
              left join public."OnlineOrders" ro on ro."OrderID" = r."OrderID"
              where r."FeeCombinedWithStopID" = s."StopID"
                and coalesce(r."ManualDeliveryFee", ro."DeliveryFee", 0) = 0)::text
    from public."DeliveryStops" s
    left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    left join public."DeliveryStops" c on c."StopID" = s."FeeCombinedWithStopID"
    where s."StopID" = p_stop_id;
end;
$$;

grant execute on function public.admin_get_delivery_stop_fee_note(text, text, uuid) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the function, then the notes the printouts would show from today on.
select 'setup' as section,
       'function admin_get_delivery_stop_fee_note' as item,
       (to_regprocedure('public.admin_get_delivery_stop_fee_note(text, text, uuid)') is not null)::text as detail
union all
select 'note ' || s."DeliveryDate"::text,
       coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo"),
       case when s."FeeCombinedWithStopID" is not null
              then 'charged on ' || coalesce(c."OrderID", 'ADV-' || c."AdvanceTransactionNo", c."AutomatedOrderNo")
            else 'covers other orders in its drop' end
from public."DeliveryStops" s
left join public."DeliveryStops" c on c."StopID" = s."FeeCombinedWithStopID"
where s."DeliveryDate" >= (now() at time zone 'Asia/Manila')::date
  and (s."FeeCombinedWithStopID" is not null
       or exists (select 1 from public."DeliveryStops" r where r."FeeCombinedWithStopID" = s."StopID"));
