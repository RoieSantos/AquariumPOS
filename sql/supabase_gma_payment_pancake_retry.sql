-- GMA Conversations Add Payment: retry the Pancake sync on connection drops - per "Payment recorded,
-- but could not flow it to Pancake: OpenSSL SSL_read: SSL_ERROR_SYSCALL, errno 0".
--
-- Same dropped-connection error already fixed for Assign / To Ship (supabase_pancake_patch_retry.sql,
-- supabase_online_order_to_ship_retry.sql), but admin_add_automated_order_payment still did a single
-- GET + single PATCH, so one hiccup failed the sync. Now: GET up to 3 tries, PATCH up to 3 tries, with
-- short pauses. The merged bank_payments object is computed ONCE from the first successful GET and the
-- exact same absolute object is re-sent on each PATCH retry - so if a PATCH actually landed but its
-- response got cut off, the retry just writes the same totals again (never double-adds the payment).
--
-- Based on the latest definition in supabase_gma_conversations_staff_rpc_access.sql (section 9,
-- is_conversations_authorized). Run AFTER that file. Replaces one function - no table changes.

drop function if exists public.admin_add_automated_order_payment(text, text, text, numeric, text, text);

create or replace function public.admin_add_automated_order_payment(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_amount numeric,
  p_method text,
  p_reference text
)
returns table(pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '60000'
as $$
declare
  v_method text := coalesce(nullif(trim(p_method), ''), 'Cash');
  v_bank_key text;
  v_order public."AutomatedOrders"%rowtype;
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_order_url text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_existing_amount numeric;
  v_patch_response extensions.http_response;
  v_attempt int;
  v_max_attempts int := 3;
  v_last_error text;
  v_sync_error text;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_order_no is null or trim(p_order_no) = '' then
    raise exception 'OrderNo is required.';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'Amount is required.';
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

  insert into public."AutomatedOrderPayments" ("OrderNo", "Amount", "Method", "Reference", "RecordedBy")
  values (p_order_no, p_amount, v_method, nullif(trim(coalesce(p_reference, '')), ''), p_admin_username);

  v_bank_key := case lower(v_method)
    when 'gcash' then 'GCASH'
    when 'bdo' then 'BDO'
    when 'metrobank' then 'METROBANK'
    when 'bank transfer' then 'Bank Transfer'
    else null
  end;

  if v_bank_key is not null and v_order."PancakeReceiptNo" is not null then
    begin
      v_order_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order."PancakeReceiptNo" || '?api_key=' || v_api_key || '&page_size=1000';

      -- 8s per call keeps the worst case (3 GETs + 3 PATCHes + pauses, ~54s) inside the 60s limit.
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

      -- GET (read-only, always safe to retry).
      v_attempt := 0;
      loop
        v_attempt := v_attempt + 1;
        begin
          select * into v_get_response from extensions.http_get(v_order_url);
          exit when v_get_response.status < 500;
          v_last_error := format('HTTP %s', v_get_response.status);
        exception when others then
          v_last_error := sqlerrm;
        end;
        if v_attempt >= v_max_attempts then
          raise exception 'Could not reach Pancake after % tries (%)', v_max_attempts, v_last_error;
        end if;
        perform pg_sleep(v_attempt);
      end loop;

      if v_get_response.status < 200 or v_get_response.status >= 300 then
        raise exception 'Could not read the order from Pancake (HTTP %).', v_get_response.status;
      end if;

      v_get_body := v_get_response.content::jsonb;
      v_order_obj := case
        when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
        when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
        else v_get_body
      end;
      v_bank_payments := case when jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then v_order_obj -> 'bank_payments' else '{}'::jsonb end;

      v_existing_amount := coalesce((v_bank_payments ->> v_bank_key)::numeric, 0);
      v_bank_payments := v_bank_payments || jsonb_build_object(v_bank_key, v_existing_amount + p_amount);

      -- PATCH the same absolute totals on every try - idempotent, so a retry can't double-add.
      v_attempt := 0;
      loop
        v_attempt := v_attempt + 1;
        begin
          select * into v_patch_response from extensions.http((
            'PATCH',
            v_order_url,
            array[
              extensions.http_header('Accept', 'application/json'),
              extensions.http_header('Expect', '')
            ],
            'application/json',
            jsonb_build_object('bank_payments', v_bank_payments)::text
          )::extensions.http_request);
          exit when v_patch_response.status < 500;
          v_last_error := format('HTTP %s', v_patch_response.status);
        exception when others then
          v_last_error := sqlerrm;
        end;
        if v_attempt >= v_max_attempts then
          raise exception 'Could not reach Pancake after % tries (%)', v_max_attempts, v_last_error;
        end if;
        perform pg_sleep(v_attempt);
      end loop;

      if v_patch_response.status < 200 or v_patch_response.status >= 300 then
        raise exception 'Pancake rejected the bank_payments update (HTTP %): %', v_patch_response.status, left(v_patch_response.content, 300);
      end if;
    exception when others then
      v_sync_error := sqlerrm;
    end;
  end if;

  return query select v_sync_error;
end;
$$;

grant execute on function public.admin_add_automated_order_payment(text, text, text, numeric, text, text) to anon;
