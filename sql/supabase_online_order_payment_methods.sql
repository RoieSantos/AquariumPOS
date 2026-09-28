-- Online Order card: "can I see what payment did they use?" - the payment method breakdown for one
-- order, read live from Pancake (same GET as admin_get_online_order_detail_live in
-- supabase_pancake_manual_sync.sql).
--
-- Pancake keeps non-cash payments in the order's `bank_payments` object, keyed by the bank account
-- key configured per tender type (this shop: BDO / GCASH / METROBANK / Bank Transfer - see
-- supabase_gma_conversation_payment_pancake_sync.sql, TenderTypesForm.cs), with the amount as the
-- value. Cash is the separate `cash` field. One row per method with an amount > 0.
--
-- Read-only; nothing is stored. Returns no rows when Pancake has no breakdown for the order (the
-- card then just shows the Amount Paid total).

create or replace function public.admin_get_online_order_payment_methods(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(method text, amount numeric)
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

  -- Cash first, then each bank key.
  begin
    v_amount := nullif(trim(coalesce(v_order_el ->> 'cash', '')), '')::numeric;
  exception when others then
    v_amount := null;
  end;
  if coalesce(v_amount, 0) > 0 then
    method := 'Cash';
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
        method := v_key;
        amount := v_amount;
        return next;
      end if;
    end loop;
  end if;
end;
$$;

grant execute on function public.admin_get_online_order_payment_methods(text, text, text) to anon;
