-- Order Confirmation Timing dashboard (Web Portal, super users only) - per "show the timing of
-- the order confirmation... what is the best time or day we are confirming orders and creating
-- order". Requires the "ConfirmedAtUtc" column on public."OnlineOrders" and the extended
-- public.pancake_extract_created_confirmed_by() helper - both added in
-- supabase_orders_sync_tables.sql / supabase_pancake_manual_sync.sql. Run those two files (they
-- already exist in the repo, just updated) BEFORE this one.

drop function if exists public.admin_get_order_confirmation_timing(text, text, date, date);

-- Returns day-of-week (0=Sunday..6=Saturday, Postgres extract(dow) convention), hour-of-day
-- (0-23), actual calendar date, and week-start-date counts, split by metric ('created' vs
-- 'confirmed'), all in Asia/Manila local time - same timezone convention used everywhere else
-- Pancake timestamps are bucketed in this project (see supabase_pancake_manual_sync.sql). One
-- flat result set: a row is a day-of-week bucket, an hour-of-day bucket, a per-date bucket, or a
-- per-week bucket, distinguished by which of day_of_week/hour_of_day/bucket_date/week_start is
-- non-null - the client splits on that. The date/week buckets are what let the dashboard call out
-- actual strong dates/weeks (e.g. "Aug 3-9 was unusually busy"), not just an average-by-weekday
-- picture. "created" timing reads the existing Date/Time text columns (already Asia/Manila local,
-- no conversion needed); "confirmed" timing reads the new ConfirmedAtUtc column, converted from
-- UTC. week_start uses Postgres's date_trunc('week', ...) convention (weeks start Monday).
create or replace function public.admin_get_order_confirmation_timing(
  p_admin_username text,
  p_admin_password text,
  p_date_from date default null,
  p_date_to date default null
)
returns table(metric text, day_of_week int, hour_of_day int, bucket_date date, week_start date, order_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  select 'created'::text, extract(dow from "Date")::int, null::int, null::date, null::date, count(*)
    from public."OnlineOrders"
    where "Date" is not null
      and (p_date_from is null or "Date" >= p_date_from)
      and (p_date_to is null or "Date" <= p_date_to)
    group by 1, 2
  union all
  select 'created'::text, null::int, extract(hour from "Time"::time)::int, null::date, null::date, count(*)
    from public."OnlineOrders"
    where "Date" is not null and "Time" is not null
      and (p_date_from is null or "Date" >= p_date_from)
      and (p_date_to is null or "Date" <= p_date_to)
    group by 1, 3
  union all
  select 'created_date'::text, null::int, null::int, "Date", null::date, count(*)
    from public."OnlineOrders"
    where "Date" is not null
      and (p_date_from is null or "Date" >= p_date_from)
      and (p_date_to is null or "Date" <= p_date_to)
    group by 1, 4
  union all
  select 'created_week'::text, null::int, null::int, null::date, date_trunc('week', "Date")::date, count(*)
    from public."OnlineOrders"
    where "Date" is not null
      and (p_date_from is null or "Date" >= p_date_from)
      and (p_date_to is null or "Date" <= p_date_to)
    group by 1, 5
  union all
  select 'confirmed'::text, extract(dow from ("ConfirmedAtUtc" at time zone 'Asia/Manila'))::int, null::int, null::date, null::date, count(*)
    from public."OnlineOrders"
    where "ConfirmedAtUtc" is not null
      and (p_date_from is null or ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date >= p_date_from)
      and (p_date_to is null or ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date <= p_date_to)
    group by 1, 2
  union all
  select 'confirmed'::text, null::int, extract(hour from ("ConfirmedAtUtc" at time zone 'Asia/Manila'))::int, null::date, null::date, count(*)
    from public."OnlineOrders"
    where "ConfirmedAtUtc" is not null
      and (p_date_from is null or ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date >= p_date_from)
      and (p_date_to is null or ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date <= p_date_to)
    group by 1, 3
  union all
  select 'confirmed_date'::text, null::int, null::int, ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date, null::date, count(*)
    from public."OnlineOrders"
    where "ConfirmedAtUtc" is not null
      and (p_date_from is null or ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date >= p_date_from)
      and (p_date_to is null or ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date <= p_date_to)
    group by 1, 4
  union all
  select 'confirmed_week'::text, null::int, null::int, null::date, date_trunc('week', ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date)::date, count(*)
    from public."OnlineOrders"
    where "ConfirmedAtUtc" is not null
      and (p_date_from is null or ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date >= p_date_from)
      and (p_date_to is null or ("ConfirmedAtUtc" at time zone 'Asia/Manila')::date <= p_date_to)
    group by 1, 5;
end;
$$;

drop function if exists public.admin_backfill_order_confirmed_at(text, text, int);

-- One-time (re-runnable) backfill for existing orders synced before ConfirmedAtUtc existed.
-- Deliberately NOT a reset-the-cron-watermark approach - the incremental cron sync
-- (cron_sync_online_orders_from_pancake) advances public."PancakeSyncState" based on the newest
-- last_updated_at it sees per run, and resetting that watermark to force a full re-walk would risk
-- interacting with its catch-up/pagination logic in ways not worth the risk to the live sync job.
-- Instead this targets exactly the rows that need it - orders already known to have been
-- confirmed ("ConfirmedBy" is set) but still missing the new timestamp - and fetches each one's
-- own detail page directly (same GET /shops/{shop}/orders/{id} endpoint the sync functions already
-- use for line items), so it's fully independent of the cron job's cursor/state. Bounded by
-- p_limit per call (HTTP round trip per order, so keep this modest) - call it repeatedly from the
-- SQL editor until remaining_count reaches 0.
create or replace function public.admin_backfill_order_confirmed_at(
  p_admin_username text,
  p_admin_password text,
  p_limit int default 25
)
returns table(processed_count int, updated_count int, remaining_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_limit int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_order_id text;
  v_detail_url text;
  v_detail_response extensions.http_response;
  v_detail_body jsonb;
  v_order_el jsonb;
  v_confirmed_at timestamptz;
  v_processed int := 0;
  v_updated int := 0;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  for v_order_id in
    select "OrderID" from public."OnlineOrders"
    where "ConfirmedAtUtc" is null and "ConfirmedBy" is not null
    order by "OrderID"
    limit v_limit
  loop
    v_processed := v_processed + 1;
    begin
      v_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order_id || '?api_key=' || v_api_key || '&page_size=1000';
      v_detail_response := extensions.http_get(v_detail_url);

      if v_detail_response.status >= 200 and v_detail_response.status < 300 then
        v_detail_body := v_detail_response.content::jsonb;
        v_order_el := case
          when jsonb_typeof(v_detail_body -> 'data') = 'object' then v_detail_body -> 'data'
          when jsonb_typeof(v_detail_body) = 'object' then v_detail_body
          else null
        end;

        if v_order_el is not null then
          select t.confirmed_at into v_confirmed_at
          from public.pancake_extract_created_confirmed_by(v_order_el) t;

          if v_confirmed_at is not null then
            update public."OnlineOrders"
            set "ConfirmedAtUtc" = v_confirmed_at
            where "OrderID" = v_order_id and "ConfirmedAtUtc" is null;
            v_updated := v_updated + 1;
          end if;
        end if;
      end if;
    exception when others then
      null; -- skip this order, keep processing the rest of the batch
    end;
  end loop;

  return query
    select v_processed, v_updated,
      (select count(*) from public."OnlineOrders" where "ConfirmedAtUtc" is null and "ConfirmedBy" is not null);
end;
$$;

grant execute on function public.admin_get_order_confirmation_timing(text, text, date, date) to anon;
grant execute on function public.admin_backfill_order_confirmed_at(text, text, int) to anon;
