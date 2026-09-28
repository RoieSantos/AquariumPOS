-- Payment Method report - per "under reports can you create me a new report for per payment type? i
-- want to see all the payments and who is using bigger".
--
-- Until now an order's payment breakdown (Pancake's `cash` field + `bank_payments` object) was only
-- read live, one order at a time, for the Online Order card's Paid Via. A report over many orders
-- needs it stored, so:
--
--   OnlineOrderPayments      one row per order per method (Code = PaymentMethods."Code": 'CASH' or
--                            the Pancake bank-account ID), amount > 0 only.
--   OnlineOrderPaymentScans  one row per order this sync has read, so "no payment rows" can be told
--                            apart from "never read".
--
-- Filled by its own background sync (cron_sync_order_payments, every 5 minutes, its own
-- PancakeSyncState cursor '/order-payments' - same updated_after walk as the main order sync, which
-- is left untouched). Older history is loaded page by page from the report's "Load payment history"
-- button (admin_backfill_order_payments_step - one Pancake call per request, like the Payment
-- Methods page's sync steps, so it never hits the API statement timeout).
--
-- The order ID is taken exactly the way the main sync takes it (receipt_no, then id...), so rows
-- join to OnlineOrders."OrderID".
--
-- Super users only. Run AFTER supabase_payment_methods_master.sql. Safe to re-run.

-- ============================================================================
-- 1. Tables
-- ============================================================================

create table if not exists public."OnlineOrderPayments" (
    "OrderID" text not null,
    "MethodCode" text not null,
    "Amount" numeric(18, 2) not null,
    "SyncedAtUtc" timestamptz not null default now(),
    primary key ("OrderID", "MethodCode")
);

create table if not exists public."OnlineOrderPaymentScans" (
    "OrderID" text primary key,
    "PancakeUpdatedAtUtc" timestamptz,
    "ScannedAtUtc" timestamptz not null default now()
);

alter table public."OnlineOrderPayments" enable row level security;
alter table public."OnlineOrderPaymentScans" enable row level security;
revoke all on public."OnlineOrderPayments", public."OnlineOrderPaymentScans" from anon, authenticated;

-- ============================================================================
-- 2. Storing one Pancake order's payments
-- ============================================================================

-- p_order: one element of Pancake's /orders list (or a single-order GET). Replaces whatever was
-- stored for that order. Returns false when the element has no usable order ID.
create or replace function public._order_payments_store(p_order jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
  v_amount numeric;
  v_key text;
  v_value jsonb;
begin
  v_order_id := nullif(trim(coalesce(
    p_order ->> 'receipt_no', p_order ->> 'receiptNo', p_order ->> 'receipt',
    p_order ->> 'id', p_order ->> 'order_number', p_order ->> 'number'
  )), '');
  if v_order_id is null then
    return false;
  end if;

  delete from public."OnlineOrderPayments" where "OrderID" = v_order_id;

  begin
    v_amount := nullif(trim(coalesce(p_order ->> 'cash', '')), '')::numeric;
  exception when others then
    v_amount := null;
  end;
  if coalesce(v_amount, 0) > 0 then
    insert into public."OnlineOrderPayments" ("OrderID", "MethodCode", "Amount") values (v_order_id, 'CASH', v_amount);
  end if;

  if jsonb_typeof(p_order -> 'bank_payments') = 'object' then
    for v_key, v_value in select * from jsonb_each(p_order -> 'bank_payments') loop
      begin
        v_amount := case
          when jsonb_typeof(v_value) = 'object' then coalesce(v_value ->> 'amount', v_value ->> 'value')::numeric
          else (v_value #>> '{}')::numeric
        end;
      exception when others then
        v_amount := null;
      end;
      if coalesce(v_amount, 0) > 0 then
        perform public._payment_method_touch(v_key);
        insert into public."OnlineOrderPayments" ("OrderID", "MethodCode", "Amount")
        values (v_order_id, v_key, v_amount)
        on conflict ("OrderID", "MethodCode") do update set "Amount" = public."OnlineOrderPayments"."Amount" + excluded."Amount";
      end if;
    end loop;
  end if;

  insert into public."OnlineOrderPaymentScans" ("OrderID", "PancakeUpdatedAtUtc", "ScannedAtUtc")
  values (v_order_id,
          public.pancake_try_parse_timestamptz(coalesce(p_order ->> 'updated_at', p_order ->> 'updatedAt')),
          now())
  on conflict ("OrderID") do update set
    "PancakeUpdatedAtUtc" = excluded."PancakeUpdatedAtUtc",
    "ScannedAtUtc" = now();

  return true;
end;
$$;

revoke execute on function public._order_payments_store(jsonb) from public, anon, authenticated;

-- One page of Pancake's /orders list (100 orders), stored. p_since_qs is the updated_after query
-- string for the cron, '' for the history backfill.
create or replace function public._order_payments_sync_page(p_page int, p_since_qs text default '')
returns table(orders_seen int, max_updated_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_response extensions.http_response;
  v_body jsonb;
  v_items jsonb;
  v_item jsonb;
  v_updated timestamptz;
begin
  orders_seen := 0;
  max_updated_at := null;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  v_response := extensions.http_get(
    v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key
      || '&page_size=100&page=' || greatest(coalesce(p_page, 1), 1) || coalesce(p_since_qs, '')
  );
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake orders request failed (HTTP %) on page %.', v_response.status, p_page;
  end if;

  v_body := v_response.content::jsonb;
  v_items := case
    when jsonb_typeof(v_body) = 'array' then v_body
    when jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
    when jsonb_typeof(v_body -> 'orders') = 'array' then v_body -> 'orders'
    else '[]'::jsonb
  end;

  for v_item in select value from jsonb_array_elements(v_items) as value loop
    if public._order_payments_store(v_item) then
      orders_seen := orders_seen + 1;
      v_updated := public.pancake_try_parse_timestamptz(coalesce(v_item ->> 'updated_at', v_item ->> 'updatedAt'));
      if v_updated is not null and (max_updated_at is null or v_updated > max_updated_at) then
        max_updated_at := v_updated;
      end if;
    end if;
  end loop;

  return next;
end;
$$;

revoke execute on function public._order_payments_sync_page(int, text) from public, anon, authenticated;

-- ============================================================================
-- 3. Background sync (new / changed orders)
-- ============================================================================

create or replace function public.cron_sync_order_payments(p_max_pages int default 5)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_last timestamptz;
  v_iso text;
  v_since_qs text := '';
  v_page int;
  v_res record;
  v_total int := 0;
  v_max timestamptz;
begin
  select "LastSyncUtc" into v_last from public."PancakeSyncState" where "Entity" = '/order-payments';
  if v_last is not null then
    -- A minute of overlap: an order saved in the same second as the last cursor isn't skipped.
    v_iso := to_char((v_last - interval '1 minute') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    v_since_qs := '&updated_after=' || v_iso || '&updatedAfter=' || v_iso;
  end if;

  for v_page in 1 .. greatest(coalesce(p_max_pages, 5), 1) loop
    select * into v_res from public._order_payments_sync_page(v_page, v_since_qs);
    v_total := v_total + v_res.orders_seen;
    if v_res.max_updated_at is not null and (v_max is null or v_res.max_updated_at > v_max) then
      v_max := v_res.max_updated_at;
    end if;
    exit when v_res.orders_seen < 100;
  end loop;

  if v_max is not null then
    insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
    values ('/order-payments', v_max)
    on conflict ("Entity") do update
      set "LastSyncUtc" = excluded."LastSyncUtc"
      where public."PancakeSyncState"."LastSyncUtc" is null
         or excluded."LastSyncUtc" > public."PancakeSyncState"."LastSyncUtc";
  end if;

  return v_total;
end;
$$;

revoke execute on function public.cron_sync_order_payments(int) from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('sync-order-payments-from-pancake');
exception when others then
  null; -- job didn't exist yet
end;
$$;

select cron.schedule(
  'sync-order-payments-from-pancake',
  '*/5 * * * *',
  $$select public.cron_sync_order_payments();$$
);

-- ============================================================================
-- 4. History backfill (report page's "Load payment history" button, one page per call)
-- ============================================================================

drop function if exists public.admin_backfill_order_payments_step(text, text, int);

create or replace function public.admin_backfill_order_payments_step(
  p_admin_username text,
  p_admin_password text,
  p_page int
)
returns table(orders_seen int, oldest_order_date date)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_res record;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_res from public._order_payments_sync_page(p_page, '');
  orders_seen := v_res.orders_seen;
  select min(o."Date") into oldest_order_date
    from public."OnlineOrderPaymentScans" s
    join public."OnlineOrders" o on o."OrderID" = s."OrderID";
  return next;
end;
$$;

grant execute on function public.admin_backfill_order_payments_step(text, text, int) to anon;

-- ============================================================================
-- 5. Report
-- ============================================================================

drop function if exists public.admin_get_payment_method_report(text, text, date, date);

-- One row per warehouse x online/walk-in x method for orders dated p_date_from..p_date_to (order
-- "Date", cancelled orders left out). The page filters and totals these client-side.
--   method_code null  = paid (AmountPaid > 0) but Pancake has no Cash/bank breakdown for it.
--   order_count       = orders that used that method (a split payment counts under each method).
-- The last row (warehouse_name null, method_code '__coverage') carries how many orders in the range
-- the payment sync has not read yet, in order_count.
create or replace function public.admin_get_payment_method_report(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date
)
returns table(
  warehouse_name text, is_walkin boolean,
  method_code text, method_name text, method_type text,
  amount numeric, order_count int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_to < p_date_from then
    raise exception 'Pick a valid date range.';
  end if;

  return query
    with orders as (
      select o."OrderID" as order_id,
             coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
             coalesce(o."ReceivedAtShop", false) as walkin,
             coalesce(o."AmountPaid", 0) as amount_paid,
             exists (select 1 from public."OnlineOrderPaymentScans" s where s."OrderID" = o."OrderID") as scanned
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."Date" >= p_date_from and o."Date" <= p_date_to
        and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
    )
    select x.wh::text, x.walkin, p."MethodCode"::text,
           public._payment_method_label(p."MethodCode")::text,
           coalesce(pm."MethodType", 'Other')::text,
           sum(p."Amount")::numeric, count(*)::int
    from orders x
    join public."OnlineOrderPayments" p on p."OrderID" = x.order_id
    left join public."PaymentMethods" pm on pm."Code" = p."MethodCode"
    group by x.wh, x.walkin, p."MethodCode", pm."MethodType"
    union all
    select x.wh::text, x.walkin, null::text, 'Method not recorded'::text, null::text,
           sum(x.amount_paid)::numeric, count(*)::int
    from orders x
    where x.scanned and x.amount_paid > 0
      and not exists (select 1 from public."OnlineOrderPayments" p where p."OrderID" = x.order_id)
    group by x.wh, x.walkin
    union all
    select null::text, null::boolean, '__coverage'::text, null::text, null::text,
           null::numeric, (select count(*) from orders x where not x.scanned)::int;
end;
$$;

grant execute on function public.admin_get_payment_method_report(text, text, date, date) to anon;

-- Fill the newest orders now (the page's button loads older history).
select public.cron_sync_order_payments();
