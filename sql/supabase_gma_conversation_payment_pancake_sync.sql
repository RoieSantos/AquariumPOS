-- Per direct follow-up request: a payment recorded from GMA Conversations (either the per-order Add
-- Payment form or the new order's Payment panel - both call admin_add_automated_order_payment) should
-- also flow to the actual Pancake order, not just sit in AutomatedOrderPayments. Pancake tracks
-- non-cash payments in an order's `bank_payments` object, keyed by a POSBankID string configured per
-- tender type (see TenderTypesForm.cs / OnlinefunctionsEvents.cs's `context.BankPayments` and
-- OnlineOrdersForm.cs's merge-into-bank_payments block, all in the desktop app) - cash is a separate
-- `cash` field set only at order creation, not something this PATCHes. Per direct instruction, this
-- shop's configured bank keys are BDO / GCASH / METROBANK / Bank Transfer, so the Method dropdown
-- (js/gmaConversations.js) now offers those verbatim alongside Cash/Other, and Method -> bank key is
-- a direct 1:1 mapping below.
--
-- Read-merge-write mirrors the already-proven GET -> merge -> PATCH shape from
-- admin_update_online_order_status (supabase_online_order_portal_status_update.sql) and
-- OnlineOrdersForm.cs's own bank_payments merge block - GET the live order, add this payment's
-- amount onto whatever's already there for that bank key (never overwrite), PATCH the merged object
-- back. Best-effort only: the AutomatedOrderPayments row is always inserted first and is never rolled
-- back if the Pancake side fails (network hiccup, order not yet synced, etc.) - the caller just gets
-- pancake_sync_error back to surface a non-blocking warning, same contract as
-- admin_create_gma_conversation_order's pancake_sync_error already has for order creation.
--
-- Skipped (no Pancake call attempted, pancake_sync_error stays null) when: Method is Cash or Other
-- (no known bank key), or the order has no PancakeReceiptNo yet (never synced to Pancake).

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
set statement_timeout = '30000'
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
  v_sync_error text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
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

      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

      select * into v_get_response from extensions.http_get(v_order_url);
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
