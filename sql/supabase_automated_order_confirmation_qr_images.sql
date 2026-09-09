-- Follow-up to supabase_automated_order_confirmation_payment_info.sql - per direct request ("can
-- you send QR image together with the Order Received?"), sends the GCash and BDO QR codes as two
-- follow-up Messenger images right after the "Order Received" text message, so the customer gets
-- something to scan instead of having to manually enter account numbers.
--
-- Pancake's reply_inbox API takes one message per call - there's no single call that attaches an
-- image to a text message - so these land as two extra messages immediately after the text one,
-- back-to-back in the same conversation. Confirmed payload shape (see
-- admin_send_online_order_status_photo in supabase_online_order_portal_status_update.sql, tested
-- live against Pancake): {"action":"reply_inbox","Type":"image","content_url":"<public url>"} -
-- built with json_build_object (NOT jsonb_build_object) because jsonb reorders object keys and
-- Pancake silently drops the image attachment unless the keys arrive in exactly that order.
--
-- The QR images themselves are static (same for every order, not per-order like status photos),
-- so no Supabase Storage upload/signing needed - they're just committed to docs/icons/ and served
-- publicly via GitHub Pages at rspetstop.com, same as every other icon in that folder.
--
-- Best-effort, same contract as the text message and the Pancake push before it: a QR send
-- failure is swallowed and never raises - it must never block or fail the order itself. It also
-- deliberately does NOT touch ConfirmationMessageStatus/ConfirmationMessageError - those track the
-- primary text message only, so a QR-image hiccup doesn't make a successfully-sent text
-- confirmation look like it failed.
drop function if exists public._send_order_confirmation_message(text);

create or replace function public._send_order_confirmation_message(p_order_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_page_id text := '195716644410829';
  v_public_api_key text := public._pancake_public_api_key();
  v_base_url text := 'https://pages.fm/api/public_api/v1';
  v_conversation_id text;
  v_payload jsonb;
  v_url text;
  v_response extensions.http_response;
  v_qr_url text;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

  if v_order."Psid" is null then
    update public."AutomatedOrders"
    set "ConfirmationMessageStatus" = 'Skipped', "ConfirmationMessageError" = 'No Psid on this order - customer did not arrive via a Messenger-personalized link.'
    where "OrderNo" = p_order_no;
    return;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

    v_conversation_id := v_page_id || '_' || v_order."Psid";
    v_payload := jsonb_build_object('action', 'reply_inbox', 'message', public._build_order_confirmation_message(p_order_no));
    v_url := v_base_url || '/pages/' || v_page_id || '/conversations/' || v_conversation_id || '/messages?page_access_token=' || v_public_api_key;

    select * into v_response from extensions.http((
      'POST',
      v_url,
      array[
        extensions.http_header('Accept', 'application/json'),
        extensions.http_header('Expect', '')
      ],
      'application/json',
      v_payload::text
    )::extensions.http_request);

    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake message send failed (HTTP %): %', v_response.status, left(v_response.content, 300);
    end if;

    update public."AutomatedOrders"
    set "ConfirmationMessageStatus" = 'Sent', "ConfirmationMessageError" = null, "ConfirmationMessageSentAtUtc" = now()
    where "OrderNo" = p_order_no;
  exception when others then
    update public."AutomatedOrders"
    set "ConfirmationMessageStatus" = 'Failed', "ConfirmationMessageError" = left(sqlerrm, 1000)
    where "OrderNo" = p_order_no;
    -- Text message failed outright - don't bother trying the QR follow-ups either, same
    -- conversation issue would just fail them too.
    return;
  end;

  -- QR follow-ups - best effort, deliberately outside the exception handler above so a QR failure
  -- never flips ConfirmationMessageStatus back to Failed after a real text send already succeeded.
  begin
    foreach v_qr_url in array array[
      'https://rspetstop.com/icons/QR1.jpg', -- GCash
      'https://rspetstop.com/icons/QR2.png'  -- BDO
    ]
    loop
      begin
        select * into v_response from extensions.http((
          'POST',
          v_url,
          array[
            extensions.http_header('Accept', 'application/json'),
            extensions.http_header('Expect', '')
          ],
          'application/json',
          json_build_object(
            'action', 'reply_inbox',
            'Type', 'image',
            'content_url', v_qr_url
          )::text
        )::extensions.http_request);
      exception when others then
        -- Swallowed - a QR image failing to send is a nice-to-have miss, not an order problem.
        null;
      end;
    end loop;
  end;
end;
$$;

-- No grant to anon - only called from submit_automated_order below, which needs none (public by
-- design).
