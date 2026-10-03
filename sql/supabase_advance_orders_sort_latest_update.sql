-- SUPERSEDED by supabase_advance_order_production.sql (same sort + production/assignment columns).
-- Don't run this one after that file - it would drop the new columns again.
--
-- Advance Orders list: sort by LATEST UPDATE instead of order date - per "sort the advance order
-- base on the latest date update". There's no real "updated at" column on AdvanceOrders
-- ("SyncedAtUtc" is re-stamped on every row by the POS's 5-minute bulk sync, so it's the same for
-- everything), so "latest update" = the later of the order's paid date ("DatePaid") and its
-- placed date/time ("Date" + "Time", Manila). A just-paid older order now jumps back to the top.
--
-- Same function/columns as supabase_advance_orders_list_sort.sql; only the ORDER BY changes.
-- Run AFTER supabase_advance_orders_list_sort.sql (supersedes it - don't re-run that one after this).
-- Safe to re-run.

drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int);

create or replace function public.admin_list_advance_orders(p_admin_username text, p_admin_password text, p_search text default null, p_transaction_no text default null, p_page int default 1, p_page_size int default 50)
returns table(
  transaction_no text,
  receipt_no text,
  user_id text,
  customer_name text,
  order_description text,
  order_date date,
  order_time text,
  net_amount numeric,
  downpayment numeric,
  balance numeric,
  online_order_id text,
  fully_paid boolean,
  date_paid timestamptz,
  warehouse text,
  synced_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "TransactionNo"::text, "ReceiptNo"::text, "UserID"::text, "CustomerName"::text, "Order_Description"::text,
           "Date", "Time"::text, "NetAmount", "Downpayment", "Balance",
           "OnlineOrderID"::text,
           coalesce("FullyPaid", false) or coalesce("Balance", 0) <= 0,
           "DatePaid", "Warehouse"::text, "SyncedAtUtc",
           count(*) over()
    from public."AdvanceOrders"
    where (p_transaction_no is not null and trim(p_transaction_no) <> '' and "TransactionNo" = p_transaction_no)
       or (
         (p_transaction_no is null or trim(p_transaction_no) = '')
         and (
           p_search is null or trim(p_search) = ''
           or "TransactionNo" ilike '%' || p_search || '%'
           or "ReceiptNo" ilike '%' || p_search || '%'
           or "CustomerName" ilike '%' || p_search || '%'
           or "UserID" ilike '%' || p_search || '%'
         )
       )
    -- Latest activity first: the later of when it was fully paid ("DatePaid") and when it was
    -- placed ("Date" + "Time", Manila). "Time" is free text from the POS, so it's only used when it
    -- looks like a clock time (e.g. 14:05, 2:05:33 PM); otherwise the order counts from midnight.
    order by greatest(
               "DatePaid",
               ("Date" + case when trim(coalesce("Time", '')) ~* '^\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\s*([ap]m)?$'
                              then trim("Time")::time else time '00:00' end) at time zone 'Asia/Manila'
             ) desc nulls last,
             case when "TransactionNo" ~ '^\d+$' then "TransactionNo"::numeric end desc nulls last,
             "TransactionNo" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_advance_orders(text, text, text, text, int, int) to anon;

notify pgrst, 'reload schema';

-- Read-only preview: top 15 in the new order, with the computed "last update" shown (Manila time).
select "TransactionNo", "CustomerName", "Date", "Time",
       "DatePaid" at time zone 'Asia/Manila' as date_paid_manila,
       greatest("DatePaid",
                ("Date" + case when trim(coalesce("Time", '')) ~* '^\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\s*([ap]m)?$'
                               then trim("Time")::time else time '00:00' end) at time zone 'Asia/Manila'
       ) at time zone 'Asia/Manila' as last_update_manila
from public."AdvanceOrders"
order by last_update_manila desc nulls last
limit 15;
