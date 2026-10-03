-- One-off: re-sync order 105852's payments from Pancake - per "can you help me write a script to be able
-- to sync over the payments again for orderid 105852".
--
-- Reads the order live from Pancake (one call) and refreshes, for this order only:
--   1. OnlineOrders: MoneyToCollect, AmountPaid (Pancake "prepaid"), Discount, DeliveryFee,
--      LastPaid_Date / LastPaid_Time, and Balance = MoneyToCollect - AmountPaid - the same mapping as
--      the every-minute order sync (supabase_walkin_order_pos_note.sql).
--   2. OnlineOrderPayments (Paid Via / Payment Method report): replaced from Pancake's cash +
--      bank_payments through the existing _order_payments_store (supabase_payment_method_report.sql).
-- Status, lines and everything else are left alone, so no notification fires. Safe to re-run.
-- To use it for another order, change '105852' in the three places below.
--
-- The result grid shows each field BEFORE and AFTER.

drop table if exists _resync_payments_before;
create temp table _resync_payments_before as
select o."OrderID", o."MoneyToCollect", o."AmountPaid", o."Balance", o."Discount", o."DeliveryFee",
       o."LastPaid_Date", o."LastPaid_Time",
       (select string_agg(p."MethodCode" || ' ' || p."Amount", ', ' order by p."MethodCode")
          from public."OnlineOrderPayments" p where p."OrderID" = o."OrderID") as payments
from public."OnlineOrders" o
where o."OrderID" = '105852';

do $$
declare
  v_order_id text := '105852';
  v_response extensions.http_response;
  v_body jsonb;
  v_el jsonb;
  v_money numeric;
  v_paid numeric;
  v_discount numeric;
  v_delivery_fee numeric;
  v_last_paid_utc timestamptz;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  v_response := extensions.http_get(
    'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || v_order_id || '?api_key=' || public._pancake_api_key());
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake returned HTTP % for order %: %', v_response.status, v_order_id, left(v_response.content, 300);
  end if;

  v_body := v_response.content::jsonb;
  v_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' then v_body
  end;
  if v_el is null then
    raise exception 'Order % not found in Pancake.', v_order_id;
  end if;

  -- Same field mapping as the order sync.
  v_money := public.pancake_parse_decimal(coalesce(
    v_el -> 'money_to_collect' ->> 'amount', v_el -> 'money_to_collect' ->> 'value', v_el -> 'money_to_collect' ->> 'total',
    v_el ->> 'money_to_collect', v_el ->> 'moneyToCollect', v_el ->> 'total_price', v_el ->> 'total', v_el ->> 'amount', v_el ->> 'money'));
  v_paid := public.pancake_parse_decimal(coalesce(
    v_el -> 'prepaid' ->> 'amount', v_el -> 'prepaid' ->> 'value',
    v_el ->> 'prepaid', v_el ->> 'prepaid_amount', v_el ->> 'pre_paid', v_el ->> 'deposit', v_el ->> 'prepayment'));
  v_discount := public.pancake_parse_decimal(coalesce(v_el ->> 'discount', v_el ->> 'discount_amount', v_el ->> 'discounted_amount'));
  v_delivery_fee := public.pancake_parse_decimal(coalesce(
    v_el -> 'shipping_fee' ->> 'amount', v_el -> 'shipping_fee' ->> 'value',
    v_el ->> 'shipping_fee', v_el ->> 'shippingFee', v_el ->> 'delivery_fee', v_el ->> 'deliveryFee'));
  v_last_paid_utc := public.pancake_try_parse_timestamptz(coalesce(
    v_el ->> 'last_paid_at', v_el ->> 'lastPaidAt', v_el ->> 'last_payment', v_el ->> 'last_paid', v_el ->> 'last_payment_at'));

  update public."OnlineOrders"
  set "MoneyToCollect" = coalesce(v_money, "MoneyToCollect"),
      "AmountPaid" = coalesce(v_paid, "AmountPaid"),
      "Balance" = coalesce(v_money, "MoneyToCollect") - coalesce(v_paid, "AmountPaid"),
      "Discount" = coalesce(v_discount, "Discount"),
      "DeliveryFee" = coalesce(v_delivery_fee, "DeliveryFee"),
      "LastPaid_Date" = coalesce((v_last_paid_utc at time zone 'Asia/Manila')::date, "LastPaid_Date"),
      "LastPaid_Time" = coalesce(to_char(v_last_paid_utc at time zone 'Asia/Manila', 'HH24:MI:SS'), "LastPaid_Time")
  where "OrderID" = v_order_id;

  -- Paid Via / Payment Method report rows (cash + bank_payments).
  -- receipt_no pinned to this order so the rows can't land under another id field.
  perform public._order_payments_store(v_el || jsonb_build_object('receipt_no', v_order_id));
end;
$$;

select 'before' as snapshot, b.* from _resync_payments_before b
union all
select 'after', o."OrderID", o."MoneyToCollect", o."AmountPaid", o."Balance", o."Discount", o."DeliveryFee",
       o."LastPaid_Date", o."LastPaid_Time",
       (select string_agg(p."MethodCode" || ' ' || p."Amount", ', ' order by p."MethodCode")
          from public."OnlineOrderPayments" p where p."OrderID" = o."OrderID")
from public."OnlineOrders" o
where o."OrderID" = '105852';
