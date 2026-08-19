-- Diagnostic helper for "I think pancake time is 4 hours ahead" - before baking a blind time
-- correction into ConfirmedAtUtc (which now drives the Dashboard's per-staff Daily Sales figure,
-- see supabase_dashboard_daily_sales_include_status.sql), this lets you see exactly what Pancake
-- sent for a given order's confirmation event, how it got parsed, and how it converts to Manila
-- time - so you can compare that against what Pancake's own order screen shows and tell me the
-- precise offset/direction, rather than guessing and risking a wrong shift on every order.
--
-- Usage: run this file once to create the function, then for a recently-confirmed order:
--   select * from public.admin_diagnose_confirmed_at('<portal username>', '<portal password>', '<OrderID>');
-- Compare parsed_confirmed_at_manila (and the raw fields in confirmed_status_entry) against what
-- Pancake's own UI shows for when that order was confirmed.
drop function if exists public.admin_diagnose_confirmed_at(text, text, text);

create or replace function public.admin_diagnose_confirmed_at(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(
  order_id text,
  confirmed_by text,
  confirmed_status_entry jsonb,
  parsed_confirmed_at_utc timestamptz,
  parsed_confirmed_at_manila text,
  stored_confirmed_at_utc timestamptz,
  stored_confirmed_at_manila text,
  full_status_history jsonb
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_detail_url text;
  v_detail_response extensions.http_response;
  v_detail_body jsonb;
  v_order_el jsonb;
  v_status_history jsonb;
  v_entry jsonb;
  v_status_code int;
  v_confirmed_by text;
  v_confirmed_entry jsonb;
  v_confirmed_at timestamptz;
  v_stored_confirmed_at timestamptz;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || p_order_id || '?api_key=' || v_api_key || '&page_size=1000';
  v_detail_response := extensions.http_get(v_detail_url);

  if v_detail_response.status < 200 or v_detail_response.status >= 300 then
    raise exception 'Pancake order detail fetch failed (status %): %', v_detail_response.status, v_detail_response.content;
  end if;

  v_detail_body := v_detail_response.content::jsonb;
  v_order_el := case
    when jsonb_typeof(v_detail_body -> 'data') = 'object' then v_detail_body -> 'data'
    when jsonb_typeof(v_detail_body) = 'object' then v_detail_body
    else null
  end;

  if v_order_el is null then
    raise exception 'Could not find order data in Pancake response for %', p_order_id;
  end if;

  v_status_history := v_order_el -> 'status_history';
  if jsonb_typeof(v_status_history) = 'array' then
    for v_entry in select * from jsonb_array_elements(v_status_history)
    loop
      v_status_code := null;
      begin
        v_status_code := nullif(trim(v_entry ->> 'status'), '')::int;
      exception when others then
        v_status_code := null;
      end;
      if v_status_code = 1 and v_confirmed_entry is null then
        v_confirmed_entry := v_entry;
        v_confirmed_by := v_entry ->> 'name';
      end if;
    end loop;
  end if;

  if v_confirmed_entry is not null then
    v_confirmed_at := public.pancake_try_parse_timestamptz(
      coalesce(
        v_confirmed_entry ->> 'inserted_at', v_confirmed_entry ->> 'insertedAt',
        v_confirmed_entry ->> 'created_at', v_confirmed_entry ->> 'createdAt',
        v_confirmed_entry ->> 'updated_at', v_confirmed_entry ->> 'updatedAt',
        v_confirmed_entry ->> 'time', v_confirmed_entry ->> 'at', v_confirmed_entry ->> 'date'
      )
    );
  end if;

  select "ConfirmedAtUtc" into v_stored_confirmed_at from public."OnlineOrders" where "OrderID" = p_order_id;

  return query select
    p_order_id,
    v_confirmed_by,
    v_confirmed_entry,
    v_confirmed_at,
    to_char(v_confirmed_at at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI:SS'),
    v_stored_confirmed_at,
    to_char(v_stored_confirmed_at at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI:SS'),
    v_status_history;
end;
$$;

grant execute on function public.admin_diagnose_confirmed_at(text, text, text) to anon;
