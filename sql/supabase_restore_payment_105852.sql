-- One-off: put back order 105852's GCASH 501.00 in Pancake, then refresh the portal from it.
-- The payment was wiped in Pancake when the order went To Ship (10/3 9:57 AM) - see
-- supabase_pancake_patch_keep_payments.sql (run that FIRST: this uses its _pancake_put_bank_payments).
-- The amount and method are the ones the order card showed before (Amount Paid 501.00, Paid Via
-- GCASH: 501.00); the old helper kept no copy, so they're typed in here.
--
-- How it works:
--   1. Finds the GCASH payment method code (PaymentMethods - the Pancake bank-account ID). If there is
--      not exactly one active GCASH method it stops and lists them - put the right one in v_code below.
--   2. Reads the order's current bank_payments from Pancake. If GCASH already has an amount there it
--      stops (nothing to restore - never adds twice).
--   3. Writes bank_payments back with GCASH 501.00 added.
--   4. Re-reads the order and refreshes the portal: AmountPaid / Balance / MoneyToCollect and the Paid
--      Via rows (same as supabase_resync_order_payments_105852.sql).
-- The last grid shows the portal values after. Re-running is safe (step 2 stops it).

do $$
declare
  v_order_id text := '105852';
  v_amount numeric := 501.00;
  v_code text := null;   -- set to the GCASH PaymentMethods."Code" if step 1 asks you to
  v_matches text;
  v_count int;
  v_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_el jsonb;
  v_bank jsonb;
  v_error text;
  v_money numeric;
  v_paid numeric;
begin
  -- 1. GCASH method code.
  if v_code is null then
    select count(*), string_agg(format('%s = %s', "Code", coalesce("Name", "PancakeName")), '; ')
      into v_count, v_matches
    from public."PaymentMethods"
    where "IsActive" and (coalesce("Name", '') ilike '%gcash%' or coalesce("PancakeName", '') ilike '%gcash%');
    if v_count <> 1 then
      raise exception 'Found % active GCASH payment methods (%). Set v_code at the top of this script to the right Code and run again.', v_count, coalesce(v_matches, 'none');
    end if;
    select "Code" into v_code
    from public."PaymentMethods"
    where "IsActive" and (coalesce("Name", '') ilike '%gcash%' or coalesce("PancakeName", '') ilike '%gcash%');
  end if;

  -- 2. Current bank_payments in Pancake.
  v_url := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || v_order_id || '?api_key=' || public._pancake_api_key();
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  v_response := extensions.http_get(v_url);
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake returned HTTP % for order %.', v_response.status, v_order_id;
  end if;
  v_body := v_response.content::jsonb;
  v_el := case when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data' else v_body end;
  v_bank := case when jsonb_typeof(v_el -> 'bank_payments') = 'object' then v_el -> 'bank_payments' else '{}'::jsonb end;

  if coalesce(public.pancake_parse_decimal(v_bank ->> v_code), 0) > 0 then
    raise exception 'Order % already has % on GCASH (%) in Pancake - nothing restored.', v_order_id, v_bank ->> v_code, v_code;
  end if;

  -- 3. Write it back.
  v_error := public._pancake_put_bank_payments(v_order_id, v_bank || jsonb_build_object(v_code, v_amount));
  if v_error is not null then
    raise exception 'Pancake did not accept the payment (%). Nothing changed on the portal - try again.', v_error;
  end if;

  -- 4. Re-read and refresh the portal (same mapping as the order sync).
  perform pg_sleep(1);
  v_response := extensions.http_get(v_url);
  if v_response.status < 200 or v_response.status >= 300 then
    raise notice 'Restored in Pancake, but the re-read failed (HTTP %) - the order sync will pick it up, or run supabase_resync_order_payments_105852.sql.', v_response.status;
    return;
  end if;
  v_body := v_response.content::jsonb;
  v_el := case when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data' else v_body end;

  v_money := public.pancake_parse_decimal(coalesce(
    v_el -> 'money_to_collect' ->> 'amount', v_el -> 'money_to_collect' ->> 'value', v_el -> 'money_to_collect' ->> 'total',
    v_el ->> 'money_to_collect', v_el ->> 'moneyToCollect', v_el ->> 'total_price', v_el ->> 'total', v_el ->> 'amount', v_el ->> 'money'));
  v_paid := public.pancake_parse_decimal(coalesce(
    v_el -> 'prepaid' ->> 'amount', v_el -> 'prepaid' ->> 'value',
    v_el ->> 'prepaid', v_el ->> 'prepaid_amount', v_el ->> 'pre_paid', v_el ->> 'deposit', v_el ->> 'prepayment'));

  update public."OnlineOrders"
  set "MoneyToCollect" = coalesce(v_money, "MoneyToCollect"),
      "AmountPaid" = coalesce(v_paid, "AmountPaid"),
      "Balance" = coalesce(v_money, "MoneyToCollect") - coalesce(v_paid, "AmountPaid")
  where "OrderID" = v_order_id;

  perform public._order_payments_store(v_el || jsonb_build_object('receipt_no', v_order_id));
end;
$$;

select o."OrderID", o."MoneyToCollect", o."AmountPaid", o."Balance",
       (select string_agg(coalesce(m."Name", p."MethodCode") || ' ' || p."Amount", ', ')
          from public."OnlineOrderPayments" p
          left join public."PaymentMethods" m on m."Code" = p."MethodCode"
         where p."OrderID" = o."OrderID") as paid_via
from public."OnlineOrders" o
where o."OrderID" = '105852';
