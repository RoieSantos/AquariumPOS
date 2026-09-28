-- Payment Methods master setup - per "i can see its paid via 'GUID'... can you create a new master
-- setup 'Payment method' this will sync all the payment from pancake so we can use it over to the
-- portal".
--
-- Pancake keys an order's non-cash payments (`bank_payments`) by its own bank-account ID (a GUID
-- like cbe9ddfa-8cc8-4658-93f3-b1750763aa27), not by a readable name - the desktop POS maps them
-- by hand in Tender Types (TenderTypes.POSBankID). This table is the portal's copy of that list:
-- Code = the Pancake ID, Name = what staff see.
--
-- Where rows come from (admin_sync_payment_methods_from_pancake / the daily cron):
--   1. Pancake's shop settings - a few candidate endpoints are tried and any bank-account list found
--      in the response fills in PancakeName. (No Pancake bank-account endpoint is used anywhere
--      else in this codebase, so this is best-effort; the sync result says whether it found one.)
--   2. Recent orders - every bank_payments key seen on the latest orders is added, so every ID
--      actually in use shows up even if step 1 finds nothing. Staff then type the Name once.
--   3. The Online Order card's Paid Via lookup (admin_get_online_order_payment_methods, below)
--      also adds any ID it hasn't seen before, so a brand-new bank account appears on its own.
-- "CASH" (Pancake's separate `cash` field) is seeded as a built-in row.
--
-- Name / Type / Active are portal-owned and never overwritten by a sync.

create table if not exists public."PaymentMethods" (
  "Code" text primary key,
  "Name" text,
  "PancakeName" text,
  "MethodType" text not null default 'Bank',
  "IsActive" boolean not null default true,
  "Source" text not null default 'Order',
  "FirstSeenAtUtc" timestamptz not null default now(),
  "LastSeenAtUtc" timestamptz,
  "SyncedAtUtc" timestamptz
);

alter table public."PaymentMethods" enable row level security;

insert into public."PaymentMethods" ("Code", "Name", "MethodType", "Source")
values ('CASH', 'Cash', 'Cash', 'Built-in')
on conflict ("Code") do nothing;

-- Display name used everywhere: staff Name, else Pancake's, else "Unnamed (cbe9ddfa)".
create or replace function public._payment_method_label(p_code text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), ''))
     from public."PaymentMethods" pm where pm."Code" = p_code),
    'Unnamed (' || left(p_code, 8) || ')'
  );
$$;

-- Add an ID seen on an order (never touches Name/Type/Active of an existing row).
create or replace function public._payment_method_touch(p_code text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public."PaymentMethods" ("Code", "Source", "LastSeenAtUtc")
  values (p_code, 'Order', now())
  on conflict ("Code") do update set "LastSeenAtUtc" = now();
$$;

-- ---------------------------------------------------------------------------
-- Sync (shared by the page's button and the daily cron)
create or replace function public._sync_payment_methods_from_pancake(p_order_pages int default 3)
returns table(named_from_pancake int, seen_on_orders int, new_methods int, pancake_source text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '120000'
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_before int;
  v_named int := 0;
  v_seen int := 0;
  v_source text := null;
  v_endpoint text;
  v_response extensions.http_response;
  v_body jsonb;
  v_list_key text;
  v_list jsonb;
  v_el jsonb;
  v_id text;
  v_name text;
  v_page int;
  v_orders jsonb;
  v_order jsonb;
  v_key text;
begin
  select count(*) into v_before from public."PaymentMethods";
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  -- 1. Bank-account list from Pancake shop settings (best-effort).
  foreach v_endpoint in array array[
    '/shops/' || v_shop_id || '/bank_accounts',
    '/shops/' || v_shop_id || '/banks',
    '/shops/' || v_shop_id || '/settings',
    '/shops/' || v_shop_id,
    '/shops'
  ] loop
    begin
      v_response := extensions.http_get(v_base_url || v_endpoint || '?api_key=' || v_api_key);
      if v_response.status < 200 or v_response.status >= 300 then
        continue;
      end if;
      v_body := v_response.content::jsonb;
    exception when others then
      continue;
    end;

    foreach v_list_key in array array['bank_accounts', 'banks', 'shop_banks', 'bank_account_settings', 'payment_methods'] loop
      for v_list in select value from jsonb_path_query(v_body, ('lax $.**.' || v_list_key)::jsonpath) as value loop
        if jsonb_typeof(v_list) <> 'array' then
          continue;
        end if;
        for v_el in select value from jsonb_array_elements(v_list) as value loop
          if jsonb_typeof(v_el) <> 'object' then
            continue;
          end if;
          v_id := coalesce(v_el ->> 'id', v_el ->> 'bank_id', v_el ->> 'account_id', v_el ->> 'uuid');
          v_name := nullif(trim(concat_ws(' - ',
            nullif(trim(coalesce(v_el ->> 'name', v_el ->> 'bank_name', v_el ->> 'short_name', v_el ->> 'title', '')), ''),
            nullif(trim(coalesce(v_el ->> 'account_name', v_el ->> 'owner_name', '')), ''),
            nullif(trim(coalesce(v_el ->> 'account_number', v_el ->> 'bank_number', '')), '')
          )), '');
          -- Only bank-account-looking rows: a GUID-style id plus some name.
          if v_id is null or v_name is null or v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-' then
            continue;
          end if;
          insert into public."PaymentMethods" ("Code", "PancakeName", "Source", "SyncedAtUtc")
          values (v_id, v_name, 'Pancake', now())
          on conflict ("Code") do update set
            "PancakeName" = excluded."PancakeName",
            "Source" = 'Pancake',
            "SyncedAtUtc" = now();
          v_named := v_named + 1;
          v_source := coalesce(v_source, v_endpoint || ' (' || v_list_key || ')');
        end loop;
      end loop;
    end loop;

    exit when v_named > 0;
  end loop;

  -- 2. Every bank_payments ID on the most recent orders.
  for v_page in 1 .. greatest(coalesce(p_order_pages, 3), 1) loop
    begin
      v_response := extensions.http_get(
        v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key || '&page_size=100&page=' || v_page
      );
      if v_response.status < 200 or v_response.status >= 300 then
        exit;
      end if;
      v_body := v_response.content::jsonb;
    exception when others then
      exit;
    end;
    v_orders := case
      when jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body -> 'orders') = 'array' then v_body -> 'orders'
      else '[]'::jsonb
    end;
    exit when jsonb_array_length(v_orders) = 0;

    for v_order in select value from jsonb_array_elements(v_orders) as value loop
      if jsonb_typeof(v_order -> 'bank_payments') = 'object' then
        for v_key in select jsonb_object_keys(v_order -> 'bank_payments') loop
          perform public._payment_method_touch(v_key);
          v_seen := v_seen + 1;
        end loop;
      end if;
    end loop;
  end loop;

  return query select
    v_named,
    v_seen,
    (select count(*)::int from public."PaymentMethods") - v_before,
    coalesce(v_source, 'none found - name them on the Payment Methods page');
end;
$$;

create or replace function public.admin_sync_payment_methods_from_pancake(
  p_admin_username text,
  p_admin_password text
)
returns table(named_from_pancake int, seen_on_orders int, new_methods int, pancake_source text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query select * from public._sync_payment_methods_from_pancake(3);
end;
$$;

-- Internal helpers: only reachable through the authorized RPCs above / the cron job.
revoke execute on function public._sync_payment_methods_from_pancake(int) from public, anon, authenticated;
revoke execute on function public._payment_method_touch(text) from public, anon, authenticated;

grant execute on function public.admin_sync_payment_methods_from_pancake(text, text) to anon;

-- ---------------------------------------------------------------------------
-- Page RPCs
create or replace function public.admin_list_payment_methods(
  p_admin_username text,
  p_admin_password text
)
returns table(
  code text, name text, pancake_name text, method_type text, is_active boolean,
  source text, first_seen_at_utc timestamptz, last_seen_at_utc timestamptz, synced_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select pm."Code", pm."Name", pm."PancakeName", pm."MethodType", pm."IsActive",
           pm."Source", pm."FirstSeenAtUtc", pm."LastSeenAtUtc", pm."SyncedAtUtc"
    from public."PaymentMethods" pm
    order by (pm."Code" = 'CASH') desc, coalesce(nullif(trim(pm."Name"), ''), pm."PancakeName") nulls last, pm."Code";
end;
$$;

grant execute on function public.admin_list_payment_methods(text, text) to anon;

create or replace function public.admin_update_payment_method(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_name text,
  p_method_type text,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if coalesce(p_method_type, '') not in ('Cash', 'Bank', 'E-Wallet', 'Card', 'Other') then
    raise exception 'Type must be Cash, Bank, E-Wallet, Card or Other.';
  end if;
  update public."PaymentMethods"
  set "Name" = nullif(trim(p_name), ''),
      "MethodType" = p_method_type,
      "IsActive" = coalesce(p_is_active, true)
  where "Code" = p_code;
  if not found then
    raise exception 'Payment method % not found.', p_code;
  end if;
end;
$$;

grant execute on function public.admin_update_payment_method(text, text, text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Online Order card's Paid Via (replaces the version in supabase_online_order_payment_methods.sql):
-- now returns the method's name (and its code), and records any ID it hasn't seen before.
drop function if exists public.admin_get_online_order_payment_methods(text, text, text);

create or replace function public.admin_get_online_order_payment_methods(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(method text, code text, amount numeric)
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
  v_order_el jsonb;
  v_key text;
  v_value jsonb;
  v_amount numeric;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  v_response := extensions.http_get(
    v_base_url || '/shops/' || v_shop_id || '/orders/' || trim(p_order_id) || '?api_key=' || v_api_key
  );
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake order request failed (HTTP %).', v_response.status;
  end if;

  v_body := v_response.content::jsonb;
  v_order_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body -> 'order') = 'object' then v_body -> 'order'
    when jsonb_typeof(v_body) = 'object' then v_body
    else null
  end;
  if v_order_el is null then
    return;
  end if;

  begin
    v_amount := nullif(trim(coalesce(v_order_el ->> 'cash', '')), '')::numeric;
  exception when others then
    v_amount := null;
  end;
  if coalesce(v_amount, 0) > 0 then
    method := public._payment_method_label('CASH');
    code := 'CASH';
    amount := v_amount;
    return next;
  end if;

  if jsonb_typeof(v_order_el -> 'bank_payments') = 'object' then
    for v_key, v_value in select * from jsonb_each(v_order_el -> 'bank_payments') loop
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
        method := public._payment_method_label(v_key);
        code := v_key;
        amount := v_amount;
        return next;
      end if;
    end loop;
  end if;
end;
$$;

grant execute on function public.admin_get_online_order_payment_methods(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Daily background sync (02:00 PH = 18:00 UTC), same cron pattern as the other Pancake syncs.
do $$
begin
  perform cron.unschedule('sync-payment-methods-from-pancake');
exception when others then
  null; -- job didn't exist yet
end;
$$;

select cron.schedule(
  'sync-payment-methods-from-pancake',
  '0 18 * * *',
  $$select * from public._sync_payment_methods_from_pancake(3);$$
);

-- Fill it now.
select * from public._sync_payment_methods_from_pancake(3);
