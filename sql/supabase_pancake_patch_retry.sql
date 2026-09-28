-- Sturdier Pancake PATCH for portal status changes - per "error upon assigning order":
-- "Saved, but the status wasn't updated: OpenSSL SSL_read: SSL_ERROR_SYSCALL, errno 0".
--
-- That's the connection to Pancake dropping mid-request (network/Pancake side, not bad data).
-- _pancake_patch_online_order_status (supabase_online_order_assigned_status.sql) tried twice back to
-- back, so a brief drop still failed the Assign. Now: up to 3 attempts with a short pause between
-- them, and a plain-language error if every attempt fails. A retry is safe - setting the same status
-- twice has the same result. Used by Assign, Mark Shipped and the maker/dispatcher status steps.
--
-- Run AFTER supabase_online_order_assigned_status.sql. Replaces one function - no table locks.

create or replace function public._pancake_patch_online_order_status(p_order_id text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key() || '&page_size=1000';
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_patch_response extensions.http_response;
  v_attempt int := 0;
  v_max_attempts int := 3;
  v_last_error text;
begin
  -- 8s per call keeps the worst case (snapshot + 3 tries + pauses, ~35s) inside the 60s limit of
  -- admin_sync_online_order_assigned_status, which also sends the customer message afterwards.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

  -- Snapshot bank_payments (Pancake's PATCH wipes them otherwise).
  begin
    select * into v_get_response from extensions.http_get(v_order_url);
    if v_get_response.status >= 200 and v_get_response.status < 300 then
      v_get_body := v_get_response.content::jsonb;
      v_order_obj := case
        when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
        when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
        else v_get_body
      end;
      if jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then
        v_bank_payments := v_order_obj -> 'bank_payments';
      end if;
    end if;
  exception when others then
    v_bank_payments := null;
  end;

  loop
    v_attempt := v_attempt + 1;
    begin
      select * into v_patch_response from extensions.http((
        'PATCH', v_order_url,
        array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
        'application/json',
        p_payload::text
      )::extensions.http_request);
      -- Pancake's own hiccups (5xx) are retried too; a 4xx is a real rejection.
      exit when v_patch_response.status < 500;
      v_last_error := format('HTTP %s', v_patch_response.status);
    exception when others then
      v_last_error := sqlerrm;
    end;

    if v_attempt >= v_max_attempts then
      raise exception 'Could not reach Pancake after % tries (%). The status was not changed on the portal - please try again in a moment.', v_max_attempts, v_last_error;
    end if;
    perform pg_sleep(v_attempt);
  end loop;

  if v_patch_response.status < 200 or v_patch_response.status >= 300 then
    raise exception 'Pancake rejected the status update (HTTP %).', v_patch_response.status;
  end if;

  if v_bank_payments is not null then
    for i in 1..2 loop
      begin
        perform extensions.http((
          'PATCH', v_order_url,
          array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
          'application/json',
          jsonb_build_object('bank_payments', v_bank_payments)::text
        )::extensions.http_request);
        exit;
      exception when others then
        perform pg_sleep(1);
      end;
    end loop;
  end if;
end;
$$;

revoke execute on function public._pancake_patch_online_order_status(text, jsonb) from public, anon, authenticated;
