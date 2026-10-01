-- Advance Orders list sort fix - per the Online Orders "Advance Orders" tab showing
-- 9988, 9982, ... 967, 9659, 964 ... (TransactionNo is varchar, so it sorted as text, and
-- "Date" desc puts NULL dates FIRST in Postgres, so undated rows jumped the queue).
--
-- Same function/columns as supabase_advance_orders_warehouse_field.sql; only the ORDER BY changes:
-- newest Date first (NULL dates last), then Time, then TransactionNo as a NUMBER (non-numeric
-- transaction nos fall back to text order at the end).
--
-- Run AFTER supabase_advance_orders_warehouse_field.sql. Safe to re-run.

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
    order by "Date" desc nulls last,
             "Time" desc nulls last,
             case when "TransactionNo" ~ '^\d+$' then "TransactionNo"::numeric end desc nulls last,
             "TransactionNo" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_advance_orders(text, text, text, text, int, int) to anon;

notify pgrst, 'reload schema';

-- Sync health check (read-only): when the POS last pushed an advance order, and how many rows
-- have no Date (those would have been the ones sorting to the top before this fix).
select count(*)                                   as total_orders,
       max("SyncedAtUtc") at time zone 'Asia/Manila' as last_synced_manila,
       max("Date")                                as newest_order_date,
       count(*) filter (where "Date" is null)     as orders_without_date
from public."AdvanceOrders";
