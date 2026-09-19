-- Per direct follow-up request: a GMA order's status card previously could only show the
-- OnlineOrders mirror's status (online_order_status, supabase_gma_conversation_online_order_status.
-- sql) - but that mirror table is populated by a periodic Pancake -> Supabase sync job
-- (supabase_pancake_manual_sync.sql) that DELIBERATELY SKIPS any order still 'new' in Pancake
-- (`if lower(trim(v_status_raw)) = 'new' then continue`). Since a freshly-pushed GMA order sits at
-- exactly that 'new' stage until someone confirms it, the mirror-based badge would never show
-- anything useful for the one moment staff actually needs it. This fetches Pancake's LIVE status
-- directly instead (same GET .../orders/{receiptNo} pattern used everywhere else in this codebase -
-- see admin_update_online_order_status), keyed by AutomatedOrders.PancakeReceiptNo (the exact id
-- format Pancake's detail endpoint expects - confirmed by supabase_pancake_manual_sync.sql already
-- using receipt_no the same way), so it works before the order ever reaches OnlineOrders.
--
-- Also adds the one write action requested alongside it - a staff member confirming the order
-- directly from the conversation. Deliberately narrow, same conservative philosophy as
-- admin_update_online_order_status (which only allows Printed -> To Ship, nothing else): this ONLY
-- allows New -> Confirmed, refuses to run against any order that isn't currently 'New' in Pancake,
-- and does the same GET-snapshot/PATCH-status/PATCH-restore bank_payments dance as admin_update_
-- online_order_status (Pancake silently wipes bank_payments on a PATCH unless they're re-sent).
--
-- Status token for Confirmed: the desktop app's MapStatusForApi dictionary claims it's the string
-- 'submitted', but that was never actually exercised for this specific transition (only 'To Ship'/
-- '8' has a real proven-working precedent) - tried it here first and Pancake rejected it outright
-- ("[status]: is invalid", HTTP 422). Pancake's own numeric status codes (confirmed via their public
-- order-status reference: 0=New, 1=Confirmed, 2=Shipped, 3=Delivered, 8=Packing, 13=Printed, etc -
-- the same numbering already backing this codebase's '2'/'3'/'8'/'13' tokens elsewhere) put Confirmed
-- at code 1, which is what's actually used below instead.

drop function if exists public.admin_get_gma_order_pancake_status(text, text, text);

create or replace function public.admin_get_gma_order_pancake_status(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(pancake_status text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '20000'
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_receipt_no text;
  v_order_url text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_status_raw text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "PancakeReceiptNo" into v_receipt_no from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;

  -- Not pushed to Pancake (or the push hasn't captured a receipt_no) - nothing to check yet.
  if v_receipt_no is null or trim(v_receipt_no) = '' then
    return query select null::text;
    return;
  end if;

  v_order_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_receipt_no || '?api_key=' || v_api_key || '&page_size=1000';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select * into v_get_response from extensions.http_get(v_order_url);
  if v_get_response.status < 200 or v_get_response.status >= 300 then
    raise exception 'Pancake returned HTTP % fetching order status.', v_get_response.status;
  end if;

  v_get_body := v_get_response.content::jsonb;
  v_order_obj := case
    when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
    when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
    else v_get_body
  end;

  v_status_raw := coalesce(v_order_obj ->> 'status_name', v_order_obj ->> 'status', v_order_obj ->> 'state', v_order_obj ->> 'order_status');

  -- Same raw-token -> friendly-label mapping as the background sync job (supabase_pancake_manual_
  -- sync.sql) - kept manually in sync since Postgres functions can't share a constant table easily.
  -- Explicit 'new' case added here (the sync job skips it entirely instead of mapping it) since
  -- that's the whole point of this function.
  return query select case lower(trim(coalesce(v_status_raw, '')))
    when 'new' then 'New'
    when '0' then 'New'
    when 'submitted' then 'Confirmed'
    when '1' then 'Confirmed'
    when 'packing' then 'To Ship'
    when 'packed' then 'To Ship'
    when 'pending' then 'Pending Transfer'
    when '9' then 'Pending Transfer'
    when 'pending_transfer' then 'Pending Transfer'
    when 'pending transfer' then 'Pending Transfer'
    when 'waiting_for_pickup' then 'Pending Transfer'
    when 'waiting for pickup' then 'Pending Transfer'
    when '12' then 'In-Transit'
    when 'wait_print' then 'In-Transit'
    when 'wait print' then 'In-Transit'
    when 'in_transit' then 'In-Transit'
    when 'in-transit' then 'In-Transit'
    when 'shipped' then 'Shipped'
    when 'delivered' then 'Shipped'
    when '2' then 'Shipped'
    when 'received' then 'Received'
    when '3' then 'Received'
    when 'printed' then 'Printed'
    when '13' then 'Printed'
    when 'cancel' then 'Cancelled'
    when 'cancelled' then 'Cancelled'
    when 'canceled' then 'Cancelled'
    when '6' then 'Cancelled'
    else coalesce(v_status_raw, 'Unknown')
  end;
end;
$$;

grant execute on function public.admin_get_gma_order_pancake_status(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_confirm_gma_order_in_pancake: the one manual write this feature allows - New -> Confirmed,
-- nothing else.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_confirm_gma_order_in_pancake(text, text, text);

create or replace function public.admin_confirm_gma_order_in_pancake(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(new_status text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_receipt_no text;
  v_order_url text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_status_raw text;
  v_current_status text;
  v_patch_response extensions.http_response;
  v_patch_attempt int;
  v_confirmed_by_name text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce(nullif(trim("DisplayName"), ''), "Username") into v_confirmed_by_name
  from public."StaffUsers" where "Username" = p_admin_username;

  select "PancakeReceiptNo" into v_receipt_no from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if v_receipt_no is null or trim(v_receipt_no) = '' then
    raise exception 'This order has not been pushed to Pancake yet.';
  end if;

  v_order_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_receipt_no || '?api_key=' || v_api_key || '&page_size=1000';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  -- Snapshot bank_payments and re-verify the CURRENT live status before writing anything - the
  -- portal's own cached copy could be stale (e.g. someone else already confirmed it, or it moved
  -- further along), and PATCHing 'submitted' onto an order that isn't 'new' would be a real mistake
  -- in a live system, not just a display glitch.
  select * into v_get_response from extensions.http_get(v_order_url);
  if v_get_response.status < 200 or v_get_response.status >= 300 then
    raise exception 'Pancake returned HTTP % fetching order before confirming.', v_get_response.status;
  end if;
  v_get_body := v_get_response.content::jsonb;
  v_order_obj := case
    when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
    when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
    else v_get_body
  end;
  if jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then
    v_bank_payments := v_order_obj -> 'bank_payments';
  end if;

  v_status_raw := coalesce(v_order_obj ->> 'status_name', v_order_obj ->> 'status', v_order_obj ->> 'state', v_order_obj ->> 'order_status');
  v_current_status := case lower(trim(coalesce(v_status_raw, '')))
    when 'new' then 'New'
    when '0' then 'New'
    when 'submitted' then 'Confirmed'
    when '1' then 'Confirmed'
    when 'packing' then 'To Ship'
    when 'packed' then 'To Ship'
    when 'printed' then 'Printed'
    else coalesce(v_status_raw, 'Unknown')
  end;

  if v_current_status <> 'New' then
    raise exception 'Order is already % in Pancake - cannot re-confirm.', v_current_status;
  end if;

  -- '1' is Pancake's own numeric status code for Confirmed (see file header) - same token style as
  -- admin_update_online_order_status's 'To Ship'/'8'.
  v_patch_attempt := 0;
  loop
    v_patch_attempt := v_patch_attempt + 1;
    begin
      select * into v_patch_response from extensions.http((
        'PATCH',
        v_order_url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('Expect', '')
        ],
        'application/json',
        jsonb_build_object('status', '1')::text
      )::extensions.http_request);
      exit;
    exception when others then
      if v_patch_attempt >= 2 then
        raise;
      end if;
    end;
  end loop;

  if v_patch_response.status < 200 or v_patch_response.status >= 300 then
    -- Surface Pancake's own response body (not just the status code) - a 422 means the request was
    -- well-formed but semantically rejected, and only Pancake's own error body says why (unknown
    -- token, missing required field, wrong current state, etc). Truncated defensively in case it's
    -- huge/HTML.
    raise exception 'Pancake rejected the confirm (HTTP %): %', v_patch_response.status, left(coalesce(v_patch_response.content, '(no body)'), 500);
  end if;

  -- Records WHO actually confirmed this order in OUR system - per direct request: "if an order is
  -- coming from GMA branch and confirmed by the staff from GMA, please add their name in the
  -- confirmed by. use their name on the portal". Pancake's own status_history (what admin_list_
  -- online_orders' ConfirmedBy is normally read from via pancake_extract_created_confirmed_by,
  -- see supabase_pancake_manual_sync.sql) has no name for a status change made through this API
  -- call - no logged-in Pancake user performed it, unlike a change made through Pancake's own UI -
  -- so that sync would otherwise leave ConfirmedBy blank forever for every GMA order confirmed
  -- this way, which is exactly the blank column the Orders page was showing.
  --
  -- INSERT ... ON CONFLICT (not a plain UPDATE) - a GMA order can still have no OnlineOrders row
  -- at all at the exact moment staff hit Confirm here (that row only appears once the background
  -- cron sync or a portal page view has pulled this order in from Pancake), and a plain UPDATE
  -- would silently touch 0 rows in that case, leaving this permanently unrecorded once the sync
  -- later creates the row with Pancake's own (nameless) data. Every other column is left for that
  -- sync to fill in as normal - this only ever stakes a claim on ConfirmedBy/ConfirmedAtUtc.
  -- coalesce(existing, new) on conflict keeps this from clobbering a name/timestamp that's already
  -- there; safe against being overwritten by a LATER sync too, since that sync's own upsert only
  -- ever replaces these two columns when Pancake's status_history gives it a non-null value
  -- (coalesce(excluded, existing) there - see supabase_pancake_manual_sync.sql), and Pancake never
  -- has one for this transition.
  insert into public."OnlineOrders" ("OrderID", "ConfirmedBy", "ConfirmedAtUtc")
  values (v_receipt_no, v_confirmed_by_name, now())
  on conflict ("OrderID") do update
  set "ConfirmedBy" = coalesce(public."OnlineOrders"."ConfirmedBy", excluded."ConfirmedBy"),
      "ConfirmedAtUtc" = coalesce(public."OnlineOrders"."ConfirmedAtUtc", excluded."ConfirmedAtUtc");

  if v_bank_payments is not null then
    begin
      perform extensions.http((
        'PATCH',
        v_order_url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('Expect', '')
        ],
        'application/json',
        jsonb_build_object('bank_payments', v_bank_payments)::text
      )::extensions.http_request);
    exception when others then
      null; -- best-effort restore, same contract as admin_update_online_order_status
    end;
  end if;

  return query select 'Confirmed'::text;
end;
$$;

grant execute on function public.admin_confirm_gma_order_in_pancake(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_cancel_gma_order_in_pancake: per direct follow-up request, the counterpart action once an
-- order IS confirmed - only allows Confirmed -> Cancelled, refuses to run against any other current
-- status (same "New only" -> "Confirmed only" narrowness as admin_confirm_gma_order_in_pancake
-- above).
--
-- Status token for Cancelled: UNVERIFIED. Unlike Confirmed's code 1 (found in a third-party API
-- client's source and cross-checked against this codebase's own already-proven '2'/'3'/'8'/'13'
-- numbering), no source could confirm Cancelled's actual code despite real effort - Pancake's own
-- Vietnamese docs list "Đã huỷ" as a real status but never show its numeric value, and the same
-- third-party client's status table (14 entries) doesn't include it either. '6' below is a guess
-- (one of the unused low numbers in the known sequence 0,1,2,3,4,5,_,_,8,9,_,11,12,13) - per direct
-- instruction, ship it as-is and let a real HTTP 422 (with Pancake's own message - see the error
-- handling below, same as admin_confirm_gma_order_in_pancake's own HTTP 422 debugging round) guide
-- the next fix if it's wrong, rather than block this on further research.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_cancel_gma_order_in_pancake(text, text, text);

create or replace function public.admin_cancel_gma_order_in_pancake(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(new_status text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_receipt_no text;
  v_order_url text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_status_raw text;
  v_current_status text;
  v_patch_response extensions.http_response;
  v_patch_attempt int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "PancakeReceiptNo" into v_receipt_no from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if v_receipt_no is null or trim(v_receipt_no) = '' then
    raise exception 'This order has not been pushed to Pancake yet.';
  end if;

  v_order_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_receipt_no || '?api_key=' || v_api_key || '&page_size=1000';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  -- Snapshot bank_payments and re-verify the CURRENT live status before writing anything - same
  -- reasoning as admin_confirm_gma_order_in_pancake (the portal's own cached copy could be stale).
  select * into v_get_response from extensions.http_get(v_order_url);
  if v_get_response.status < 200 or v_get_response.status >= 300 then
    raise exception 'Pancake returned HTTP % fetching order before cancelling.', v_get_response.status;
  end if;
  v_get_body := v_get_response.content::jsonb;
  v_order_obj := case
    when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
    when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
    else v_get_body
  end;
  if jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then
    v_bank_payments := v_order_obj -> 'bank_payments';
  end if;

  v_status_raw := coalesce(v_order_obj ->> 'status_name', v_order_obj ->> 'status', v_order_obj ->> 'state', v_order_obj ->> 'order_status');
  v_current_status := case lower(trim(coalesce(v_status_raw, '')))
    when 'new' then 'New'
    when '0' then 'New'
    when 'submitted' then 'Confirmed'
    when '1' then 'Confirmed'
    when 'packing' then 'To Ship'
    when 'packed' then 'To Ship'
    when 'printed' then 'Printed'
    else coalesce(v_status_raw, 'Unknown')
  end;

  if v_current_status <> 'Confirmed' then
    raise exception 'Order is % in Pancake, not Confirmed - cannot cancel from here.', v_current_status;
  end if;

  v_patch_attempt := 0;
  loop
    v_patch_attempt := v_patch_attempt + 1;
    begin
      select * into v_patch_response from extensions.http((
        'PATCH',
        v_order_url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('Expect', '')
        ],
        'application/json',
        jsonb_build_object('status', '6')::text
      )::extensions.http_request);
      exit;
    exception when others then
      if v_patch_attempt >= 2 then
        raise;
      end if;
    end;
  end loop;

  if v_patch_response.status < 200 or v_patch_response.status >= 300 then
    raise exception 'Pancake rejected the cancel (HTTP %): %', v_patch_response.status, left(coalesce(v_patch_response.content, '(no body)'), 500);
  end if;

  if v_bank_payments is not null then
    begin
      perform extensions.http((
        'PATCH',
        v_order_url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('Expect', '')
        ],
        'application/json',
        jsonb_build_object('bank_payments', v_bank_payments)::text
      )::extensions.http_request);
    exception when others then
      null; -- best-effort restore, same contract as admin_confirm_gma_order_in_pancake
    end;
  end if;

  return query select 'Cancelled'::text;
end;
$$;

grant execute on function public.admin_cancel_gma_order_in_pancake(text, text, text) to anon;
