-- BIR Sales report (bir-sales-report.html) - per "i need to extract my sales.. only for walkin, its for bir
-- compliance.. can we have some feature to extract the sales base on BIR".
--
-- Returns every walk-in sale (OnlineOrders."ReceivedAtShop" - POS walk-ins WI-xxxxx and the older
-- Pancake-synced ones) in the date range, one element per receipt. The page builds the BIR views from it
-- (Sales Journal per receipt, Daily Summary with first / last receipt no., Monthly Totals for the quarterly
-- return) and the VAT / percentage-tax split, so switching views or tax type doesn't re-query.
--
--   receipt_no - the POS receipt no. (PosReceiptNo, e.g. RS-000123); older Pancake walk-ins kept it only at
--                the start of the Note ("RS-... - Customer: ..."), so it's read from there.
--   gross      - net + discount (the sale before discount)
--   discount   - OnlineOrders."Discount"
--   net        - MoneyToCollect, the sale total after discount (same figure as the Dashboard's walk-in sales)
--   payments   - "Cash 500.00, GCash 1,200.00" from OnlineOrderPayments
-- Cancelled orders are left out (a cancelled receipt shouldn't count as a sale).
--
-- Returned as ONE jsonb value, not a set of rows, so a full quarter is never cut at the API's 1000-row cap.
-- Super users only (is_admin_authorized), like the other finance reports.
-- Run AFTER supabase_pos_walkin_orders_direct.sql and supabase_payment_method_report.sql. Safe to re-run.

drop function if exists public.admin_get_bir_walkin_sales(text, text, date, date);

create or replace function public.admin_get_bir_walkin_sales(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_to < p_date_from then
    raise exception 'Pick a valid date range.';
  end if;
  if p_date_to - p_date_from > 400 then
    raise exception 'Pick at most about a year at a time.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'order_id', x.order_id,
             'receipt_no', x.receipt_no,
             'sale_date', x.sale_date,
             'sale_time', x.sale_time,
             'warehouse_name', x.wh,
             'customer_name', x.customer,
             'gross', x.net + x.discount,
             'discount', x.discount,
             'net', x.net,
             'payments', x.payments,
             'cashier', x.cashier
           ) order by x.sale_date, x.receipt_no nulls last, x.sale_time, x.order_id)
      from (
        select o."OrderID"::text as order_id,
               coalesce(nullif(trim(o."PosReceiptNo"), ''),
                        substring(o."Note" from '^\s*(RS-[0-9A-Za-z-]*[0-9A-Za-z])')) as receipt_no,
               o."Date" as sale_date,
               o."Time"::text as sale_time,
               coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
               coalesce(nullif(trim(o."WalkinCustomerName"), ''),
                        nullif(nullif(trim(o."CustomerName"), ''), 'POS WALKIN ORDERS'),
                        'Walk-in') as customer,
               round(coalesce(o."MoneyToCollect", 0), 2) as net,
               round(coalesce(o."Discount", 0), 2) as discount,
               (select string_agg(coalesce(nullif(trim(pm."Name"), ''), p."MethodCode") || ' '
                                    || to_char(p."Amount", 'FM999,999,990.00'), ', ' order by p."Amount" desc)
                  from public."OnlineOrderPayments" p
                  left join public."PaymentMethods" pm on pm."Code" = p."MethodCode"
                 where p."OrderID" = o."OrderID") as payments,
               o."CreatedBy"::text as cashier
          from public."OnlineOrders" o
          left join public."Warehouses" w on w."ID" = o."LocationID"
         where o."ReceivedAtShop" is true
           and o."Date" >= p_date_from and o."Date" <= p_date_to
           and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled', 'cancel')
      ) x
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.admin_get_bir_walkin_sales(text, text, date, date) to anon;

notify pgrst, 'reload schema';

-- Verification - ONE result: the function exists and anon can call it (expect detail = true).
select 'function' as section, p.proname::text as name,
       has_function_privilege('anon', p.oid, 'EXECUTE')::text as detail
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'admin_get_bir_walkin_sales';
