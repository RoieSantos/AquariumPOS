-- Adds "Online Order ID" (mirrors local AdvanceOrderHeader.OnlineOrderID - the
-- Pancake order id), "Fully Paid", and "Date Paid" to the Portal's Advance
-- Orders view.
--
-- Run sql_advance_order_paid_status.sql against the local SQL Server database
-- first (adds FullyPaid/DatePaid to dbo.AdvanceOrderHeader) - the desktop app
-- won't have anything to push into these new Supabase columns until that's in
-- place, since OnlinefunctionsEvents only includes a column in the sync
-- payload when it actually exists locally.
--
-- Direct table access to public."AdvanceOrders" is blocked by RLS (see
-- supabase_orders_sync_tables.sql) - the portal only ever reads through
-- admin_list_advance_orders below, so that function's return columns are
-- updated here too. Without this, the new table columns would exist but stay
-- invisible to the portal.
--
-- Also changes the default sort from "TransactionNo desc" to "Date desc, Time
-- desc" (TransactionNo desc as a final tiebreaker) per "sort the advance
-- orders by date, newest on top" - TransactionNo desc usually lines up with
-- newest-first too, but an order's actual Date/Time is the more literal and
-- reliable way to mean "newest".

alter table public."AdvanceOrders" add column if not exists "OnlineOrderID" text;
alter table public."AdvanceOrders" add column if not exists "FullyPaid" boolean not null default false;
alter table public."AdvanceOrders" add column if not exists "DatePaid" timestamptz;

drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int);

-- p_transaction_no: exact filter, used by the lines drill-down page to fetch just that order's
-- header - that call site doesn't pass p_page/p_page_size, so it just gets the (1, 50) defaults,
-- fine since exactly one matching row is expected.
-- p_search: free-text browsing filter, ignored when p_transaction_no is set.
-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
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
           -- Derived, not just the stored FullyPaid bit: a Balance of 0 (or less, on an overpayment)
           -- always counts as fully paid even if FullyPaid somehow wasn't set on that row (older data
           -- synced before this column existed, or any future write path that updates Balance without
           -- remembering to also set FullyPaid). The stored bit still wins when true on its own -
           -- this only adds Balance<=0 as a second, independent way to arrive at "yes".
           coalesce("FullyPaid", false) or coalesce("Balance", 0) <= 0,
           "DatePaid", "SyncedAtUtc",
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
    order by "Date" desc, "Time" desc, "TransactionNo" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_advance_orders(text, text, text, text, int, int) to anon;
