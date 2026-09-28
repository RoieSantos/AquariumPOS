-- Payment Methods sync, one Pancake call per request.
--
-- 1. Fix: "Sync from Pancake" failed with "canceling statement due to statement timeout" - the first
--    version (supabase_payment_methods_master.sql) made up to 8 Pancake calls in one request, past
--    the API role's statement timeout. The page now calls one step per request and loops itself
--    (docs/js/paymentMethods.js); the nightly cron still runs every step in one go.
-- 2. Names: per "use this api endpoint to get all the payment methods
--    {{BaseURL}}/shops/{{ShopId}}/bank_payments?api_key={{ApiKey}} - you will see the name too",
--    step 1 reads Pancake's own bank-payment list (the same IDs orders use as bank_payments keys)
--    into PaymentMethods."PancakeName". Replaces the guessed endpoints of the first version.
--
-- Step 1:    /shops/{id}/bank_payments -> every payment method with its Pancake name.
-- Steps 2-4: bank_payments IDs used on order pages 1-3 (100 orders each) - catches any ID the list
--            doesn't include.
-- Run AFTER supabase_payment_methods_master.sql.

drop function if exists public._payment_methods_sync_step(int) cascade;

create or replace function public._payment_methods_sync_step(p_step int)
returns table(named_from_pancake int, seen_on_orders int, pancake_source text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_named int := 0;
  v_seen int := 0;
  v_source text := null;
  v_response extensions.http_response;
  v_body jsonb;
  v_list jsonb;
  v_key text;
  v_el jsonb;
  v_id text;
  v_name text;
  v_orders jsonb;
  v_order jsonb;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');

  if p_step = 1 then
    v_response := extensions.http_get(v_base_url || '/shops/' || v_shop_id || '/bank_payments?api_key=' || v_api_key);
    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake bank_payments request failed (HTTP %).', v_response.status;
    end if;
    v_body := v_response.content::jsonb;

    -- The list: a bare array, or an array/object under data / bank_payments / result.
    v_list := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body -> 'data') in ('array', 'object') then v_body -> 'data'
      when jsonb_typeof(v_body -> 'bank_payments') in ('array', 'object') then v_body -> 'bank_payments'
      when jsonb_typeof(v_body -> 'result') in ('array', 'object') then v_body -> 'result'
      else '[]'::jsonb
    end;

    -- Array elements come through with a null key; an object keyed by ID gives (id, element).
    for v_key, v_el in
      select null::text, value from jsonb_array_elements(case when jsonb_typeof(v_list) = 'array' then v_list else '[]'::jsonb end)
      union all
      select key, value from jsonb_each(case when jsonb_typeof(v_list) = 'object' then v_list else '{}'::jsonb end)
    loop
      if jsonb_typeof(v_el) = 'object' then
        v_id := coalesce(v_el ->> 'id', v_el ->> 'bank_id', v_el ->> 'bank_payment_id', v_el ->> 'uuid', v_key);
        v_name := nullif(trim(concat_ws(' - ',
          nullif(trim(coalesce(v_el ->> 'name', v_el ->> 'bank_name', v_el ->> 'short_name', v_el ->> 'bank_short_name', v_el ->> 'title', v_el ->> 'display_name', '')), ''),
          nullif(trim(coalesce(v_el ->> 'account_name', v_el ->> 'owner_name', v_el ->> 'holder_name', '')), ''),
          nullif(trim(coalesce(v_el ->> 'account_number', v_el ->> 'bank_number', v_el ->> 'number', '')), '')
        )), '');
      else
        -- {"<id>": "<name>"}
        v_id := v_key;
        v_name := nullif(trim(v_el #>> '{}'), '');
      end if;
      continue when v_id is null or trim(v_id) = '';

      insert into public."PaymentMethods" ("Code", "PancakeName", "Source", "SyncedAtUtc")
      values (v_id, v_name, 'Pancake', now())
      on conflict ("Code") do update set
        "PancakeName" = coalesce(excluded."PancakeName", public."PaymentMethods"."PancakeName"),
        "Source" = 'Pancake',
        "SyncedAtUtc" = now();
      if v_name is not null then
        v_named := v_named + 1;
      end if;
    end loop;
    v_source := '/shops/' || v_shop_id || '/bank_payments';

  elsif p_step between 2 and 4 then
    begin
      v_response := extensions.http_get(
        v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key || '&page_size=100&page=' || (p_step - 1)
      );
      if v_response.status between 200 and 299 then
        v_body := v_response.content::jsonb;
      end if;
    exception when others then
      v_body := null;
    end;
    v_orders := case
      when jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body -> 'orders') = 'array' then v_body -> 'orders'
      else '[]'::jsonb
    end;
    for v_order in select value from jsonb_array_elements(v_orders) as value loop
      if jsonb_typeof(v_order -> 'bank_payments') = 'object' then
        for v_key in select jsonb_object_keys(v_order -> 'bank_payments') loop
          perform public._payment_method_touch(v_key);
          v_seen := v_seen + 1;
        end loop;
      end if;
    end loop;
  end if;

  return query select v_named, v_seen, v_source;
end;
$$;

revoke execute on function public._payment_methods_sync_step(int) from public, anon, authenticated;

-- One step per page request.
create or replace function public.admin_sync_payment_methods_step(
  p_admin_username text,
  p_admin_password text,
  p_step int
)
returns table(named_from_pancake int, seen_on_orders int, pancake_source text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query select * from public._payment_methods_sync_step(p_step);
end;
$$;

grant execute on function public.admin_sync_payment_methods_step(text, text, int) to anon;

-- Nightly cron (sync-payment-methods-from-pancake, scheduled in the master file) - every step.
create or replace function public._sync_payment_methods_from_pancake(p_order_pages int default 3)
returns table(named_from_pancake int, seen_on_orders int, new_methods int, pancake_source text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_before int;
  v_named int := 0;
  v_seen int := 0;
  v_source text;
  v_step int;
  r record;
begin
  select count(*) into v_before from public."PaymentMethods";
  begin
    select * into r from public._payment_methods_sync_step(1);
    v_named := r.named_from_pancake;
    v_source := r.pancake_source;
  exception when others then
    v_source := 'bank_payments list failed: ' || sqlerrm;
  end;
  for v_step in 2 .. 1 + least(greatest(coalesce(p_order_pages, 3), 1), 3) loop
    select * into r from public._payment_methods_sync_step(v_step);
    v_seen := v_seen + r.seen_on_orders;
  end loop;
  return query select v_named, v_seen,
    (select count(*)::int from public."PaymentMethods") - v_before,
    v_source;
end;
$$;

-- Fill the names now and show what came back.
select * from public._payment_methods_sync_step(1);
select "Code", "PancakeName", "Name" from public."PaymentMethods" order by "PancakeName" nulls last;
