-- Widens server-side authorization for every RPC GMA Conversations (gma-conversations.html/
-- js/gmaConversations.js) actually calls, so a "Conversations Access" account (StaffUsers.
-- ConversationsStaff = true, see supabase_staff_users_conversations_staff_field.sql) can use the
-- page for real - not just open it.
--
-- Context: that earlier migration only added the FLAG and widened the PAGE-LEVEL JS gates
-- (gmaConversations.js's init(), nav.js, auth.js's STORE_MANAGER_ALLOWED_PAGES). It did NOT touch
-- the ~25 underlying Postgres RPC functions the page calls, each of which independently
-- re-authorizes via `public.is_admin_authorized(p_admin_username, p_admin_password)` - which
-- checks ONLY the "SuperUser" boolean (see supabase_staff_users_table.sql). Result: a
-- ConversationsStaff-only account could open the page, but every RPC call on it (loading the
-- conversation list, messages, orders, quick replies, media library, sending replies, etc.) failed
-- with "Not authorized." server-side.
--
-- Fix: a new helper, is_conversations_authorized(), same re-verification trust model as
-- is_admin_authorized() (re-checks username+password every call, not a stored session) but allows
-- EITHER SuperUser OR ConversationsStaff. Deliberately a SEPARATE helper, not a change to
-- is_admin_authorized() itself - that function gates dozens of unrelated SuperUser-only admin
-- surfaces (User Setup, Item Setup, Vendor Setup, Pricing Setup, GL Setup, etc.), and widening it
-- globally would quietly hand ConversationsStaff accounts access to all of those too. Every
-- function below is CREATE OR REPLACE with its body otherwise byte-for-byte unchanged from its
-- current live definition - only the one `is_admin_authorized(...)` check line is swapped for
-- `is_conversations_authorized(...)`.
--
-- NOT covered (documented gap, not fixed here): the "Import Facebook History" button calls the
-- facebook-conversations-backfill Edge Function, which re-checks is_admin_authorized() in its own
-- TypeScript (not via an RPC), so it stays Super User-only unless that Edge Function is separately
-- patched.
--
-- Run this AFTER supabase_staff_users_conversations_staff_field.sql.

-- ---------------------------------------------------------------------------
-- New shared authorization helper for GMA Conversations' own RPCs only.

drop function if exists public.is_conversations_authorized(text, text);

create or replace function public.is_conversations_authorized(p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_super_user boolean;
  v_conversations_staff boolean;
begin
  select "PasswordHash", "IsActive", "SuperUser", "ConversationsStaff"
    into v_password_hash, v_is_active, v_super_user, v_conversations_staff
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active or not (coalesce(v_super_user, false) or coalesce(v_conversations_staff, false)) then
    return false;
  end if;

  return v_password_hash = crypt(p_password, v_password_hash);
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. admin_list_chatbot_conversations (live def: supabase_chatbot_conversations_search.sql)

drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text);

create or replace function public.admin_list_chatbot_conversations(
  p_admin_username text,
  p_admin_password text,
  p_page int default 1,
  p_page_size int default 50,
  p_search text default null
)
returns table(
  psid text,
  page_id text,
  customer_name text,
  status text,
  is_paused boolean,
  last_message_at_utc timestamptz,
  last_customer_message_at_utc timestamptz,
  created_at_utc timestamptz,
  last_message_preview text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      c."Psid"::text,
      c."PageId"::text,
      c."CustomerName"::text,
      c."Status"::text,
      c."IsPaused",
      c."LastMessageAtUtc",
      c."LastCustomerMessageAtUtc",
      c."CreatedAtUtc",
      (
        select left(m."Content", 200)
        from public."ChatbotMessages" m
        where m."Psid" = c."Psid"
        order by m."CreatedAtUtc" desc
        limit 1
      )::text,
      count(*) over()
    from public."ChatbotConversations" c
    where
      v_search is null
      or c."CustomerName" ilike '%' || v_search || '%'
      or c."Psid" ilike '%' || v_search || '%'
      or exists (
        select 1 from public."ChatbotMessages" m
        where m."Psid" = c."Psid" and m."Content" ilike '%' || v_search || '%'
      )
    order by coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. admin_set_chatbot_conversation_paused (live def: supabase_chatbot_conversations_admin_inbox.sql)

drop function if exists public.admin_set_chatbot_conversation_paused(text, text, text, boolean);

create or replace function public.admin_set_chatbot_conversation_paused(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_is_paused boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;

  update public."ChatbotConversations"
  set "IsPaused" = coalesce(p_is_paused, false)
  where "Psid" = p_psid;

  if not found then
    raise exception 'No conversation found for that Psid.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_conversation_paused(text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- 3. admin_get_chatbot_conversation_messages (live def: supabase_chatbot_payment_confirmation_flag.sql)

drop function if exists public.admin_get_chatbot_conversation_messages(text, text, text, int);

create or replace function public.admin_get_chatbot_conversation_messages(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_limit int default 100
)
returns table(
  message_id bigint,
  role text,
  content text,
  created_at_utc timestamptz,
  sent_by_username text,
  attachment_url text,
  attachment_type text,
  detected_payment_amount numeric,
  detected_payment_method text,
  detected_payment_reference text,
  detected_payment_sender_name text,
  detected_payment_at_text text,
  detected_payment_applied_at_utc timestamptz,
  delivery_status text,
  seen_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      m."Id",
      m."Role"::text,
      m."Content"::text,
      m."CreatedAtUtc",
      m."SentByUsername"::text,
      m."AttachmentUrl"::text,
      m."AttachmentType"::text,
      m."DetectedPaymentAmount",
      m."DetectedPaymentMethod"::text,
      m."DetectedPaymentReference"::text,
      m."DetectedPaymentSenderName"::text,
      m."DetectedPaymentAtText"::text,
      m."DetectedPaymentAppliedAtUtc",
      m."DeliveryStatus"::text,
      m."SeenAtUtc"
    from (
      select * from public."ChatbotMessages"
      where "Psid" = p_psid
      order by "CreatedAtUtc" desc
      limit v_limit
    ) m
    order by m."CreatedAtUtc" asc;
end;
$$;

grant execute on function public.admin_get_chatbot_conversation_messages(text, text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- 4. admin_list_automated_orders_by_gma_conversation (live def: supabase_gma_conversation_receipt_confirmation.sql)

drop function if exists public.admin_list_automated_orders_by_gma_conversation(text, text, text, text);

create or replace function public.admin_list_automated_orders_by_gma_conversation(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text
)
returns table(
  order_no text,
  customer_name text,
  customer_phone text,
  customer_email text,
  fulfillment_type text,
  delivery_address text,
  location text,
  notes text,
  status text,
  estimated_total numeric,
  amount_paid numeric,
  balance numeric,
  pancake_order_id text,
  pancake_order_link text,
  pancake_sync_status text,
  receipt_confirmed_at_utc timestamptz,
  created_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;

  return query
    select
      o."OrderNo"::text,
      o."CustomerName"::text,
      o."CustomerPhone"::text,
      o."CustomerEmail"::text,
      o."FulfillmentType"::text,
      o."DeliveryAddress"::text,
      o."Location"::text,
      o."Notes"::text,
      o."Status"::text,
      o."EstimatedTotal",
      coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0)::numeric,
      (o."EstimatedTotal" - coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0))::numeric,
      o."PancakeOrderId"::text,
      o."PancakeOrderLink"::text,
      o."PancakeSyncStatus"::text,
      o."ReceiptConfirmedAtUtc",
      o."CreatedAtUtc"
    from public."AutomatedOrders" o
    where o."GmaPsid" = trim(p_psid)
      and (p_page_id is null or trim(p_page_id) = '' or o."GmaPageId" = trim(p_page_id))
    order by o."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_automated_orders_by_gma_conversation(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. admin_get_gma_order_pancake_status (live def: supabase_gma_conversation_pancake_confirm.sql)

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
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "PancakeReceiptNo" into v_receipt_no from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;

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
-- 6. admin_list_automated_order_payments (live def: supabase_gma_conversation_orders.sql)

drop function if exists public.admin_list_automated_order_payments(text, text, text);

create or replace function public.admin_list_automated_order_payments(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(payment_id bigint, amount numeric, method text, reference text, recorded_by text, recorded_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select p."PaymentId", p."Amount", p."Method"::text, p."Reference"::text, p."RecordedBy"::text, p."RecordedAtUtc"
    from public."AutomatedOrderPayments" p
    where p."OrderNo" = p_order_no
    order by p."RecordedAtUtc" asc;
end;
$$;

grant execute on function public.admin_list_automated_order_payments(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 7. admin_confirm_gma_order_in_pancake (live def: supabase_gma_conversation_pancake_confirm.sql)

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
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
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
    raise exception 'Pancake rejected the confirm (HTTP %): %', v_patch_response.status, left(coalesce(v_patch_response.content, '(no body)'), 500);
  end if;

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
      null;
    end;
  end if;

  return query select 'Confirmed'::text;
end;
$$;

grant execute on function public.admin_confirm_gma_order_in_pancake(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 8. admin_cancel_gma_order_in_pancake (live def: supabase_gma_conversation_pancake_confirm.sql)

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
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
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
      null;
    end;
  end if;

  return query select 'Cancelled'::text;
end;
$$;

grant execute on function public.admin_cancel_gma_order_in_pancake(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 9. admin_add_automated_order_payment (live def: supabase_gma_conversation_payment_pancake_sync.sql)

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

-- ---------------------------------------------------------------------------
-- 10. admin_mark_chatbot_payment_applied (live def: supabase_chatbot_payment_confirmation_flag.sql)

drop function if exists public.admin_mark_chatbot_payment_applied(text, text, bigint);

create or replace function public.admin_mark_chatbot_payment_applied(
  p_admin_username text,
  p_admin_password text,
  p_message_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."ChatbotMessages"
  set "DetectedPaymentAppliedAtUtc" = now()
  where "Id" = p_message_id;
end;
$$;

grant execute on function public.admin_mark_chatbot_payment_applied(text, text, bigint) to anon;

-- ---------------------------------------------------------------------------
-- 11. admin_update_automated_order (live def: supabase_gma_conversation_order_pancake_items_update.sql)

drop function if exists public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb);

create or replace function public.admin_update_automated_order(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_lines jsonb
)
returns table(order_no text, estimated_total numeric, pancake_sync_status text, pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_current_status text;
  v_current_sync_status text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "Status", "PancakeSyncStatus" into v_current_status, v_current_sync_status
  from public."AutomatedOrders"
  where "OrderNo" = p_order_no;

  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if v_current_status in ('Completed', 'Cancelled') then
    raise exception 'This order is % and can no longer be edited.', v_current_status;
  end if;

  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  if regexp_replace(p_customer_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567.';
  end if;
  if v_fulfillment not in ('Pickup', 'Delivery') then
    raise exception 'Fulfillment type must be Pickup or Delivery.';
  end if;
  if v_fulfillment = 'Delivery' and (p_delivery_address is null or trim(p_delivery_address) = '') then
    raise exception 'Delivery address is required for delivery orders.';
  end if;
  if v_location not in ('Amaya', 'GMA') then
    raise exception 'Location must be Amaya or GMA.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one item is required.';
  end if;

  update public."AutomatedOrders"
  set "CustomerName" = trim(p_customer_name),
      "CustomerPhone" = trim(p_customer_phone),
      "CustomerEmail" = nullif(trim(coalesce(p_customer_email, '')), ''),
      "FulfillmentType" = v_fulfillment,
      "DeliveryAddress" = case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
      "Notes" = nullif(trim(coalesce(p_notes, '')), ''),
      "Location" = v_location,
      "UpdatedBy" = p_admin_username,
      "UpdatedAtUtc" = now()
  where "OrderNo" = p_order_no;

  delete from public."AutomatedOrderLines" where "OrderNo" = p_order_no;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId")
    values
      (p_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       nullif(trim(coalesce(v_line->>'note', '')), ''), nullif(trim(coalesce(v_line->>'variation_id', '')), ''));

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = p_order_no;

  if v_current_sync_status = 'Synced' then
    begin
      perform public._update_automated_order_items_in_pancake(p_order_no);
    exception when others then
      update public."AutomatedOrders"
      set "PancakeSyncStatus" = 'Stale',
          "PancakeSyncError" = 'Order was edited in the portal, but updating the live Pancake order failed: ' || sqlerrm
      where "OrderNo" = p_order_no;
    end;
  else
    perform public._push_automated_order_to_pancake(p_order_no);
  end if;

  return query
    select o."OrderNo"::text, o."EstimatedTotal", o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = p_order_no;
end;
$$;

grant execute on function public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb) to anon;

-- ---------------------------------------------------------------------------
-- 12. admin_create_gma_conversation_order (live def: supabase_gma_conversation_order_line_variant_selection.sql)

drop function if exists public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb);

create or replace function public.admin_create_gma_conversation_order(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_lines jsonb
)
returns table(order_no text, pancake_order_id text, pancake_sync_status text, pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;
  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  if regexp_replace(p_customer_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567.';
  end if;
  if v_fulfillment not in ('Pickup', 'Delivery') then
    raise exception 'Fulfillment type must be Pickup or Delivery.';
  end if;
  if v_fulfillment = 'Delivery' and (p_delivery_address is null or trim(p_delivery_address) = '') then
    raise exception 'Delivery address is required for delivery orders.';
  end if;
  if v_location not in ('Amaya', 'GMA') then
    raise exception 'Location must be Amaya or GMA.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one item is required.';
  end if;

  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  insert into public."AutomatedOrders"
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status", "EstimatedTotal", "Location", "GmaPsid", "GmaPageId", "UpdatedBy")
  values
    (v_order_no, trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0, v_location, trim(p_psid), nullif(trim(coalesce(p_page_id, '')), ''), p_admin_username);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId")
    values
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       nullif(trim(coalesce(v_line->>'note', '')), ''), nullif(trim(coalesce(v_line->>'variation_id', '')), ''));

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = v_order_no;

  perform public._push_automated_order_to_pancake(v_order_no);

  return query
    select o."OrderNo"::text, o."PancakeOrderId"::text, o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = v_order_no;
end;
$$;

grant execute on function public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb) to anon;

-- ---------------------------------------------------------------------------
-- 13. admin_create_chatbot_attachment_upload (live def: supabase_chatbot_staff_attachment_upload.sql)

drop function if exists public.admin_create_chatbot_attachment_upload(text, text, text);

create or replace function public.admin_create_chatbot_attachment_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'chatbot-attachments';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
  v_ext text;
  v_path text;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  v_ext := lower(regexp_replace(coalesce(p_file_name, ''), '^.*\.', ''));
  if v_ext !~ '^[a-z0-9]{1,10}$' then
    v_ext := 'jpg';
  end if;
  v_path := 'staff-' || extract(epoch from clock_timestamp())::bigint || '-' || floor(random() * 1000000)::int || '.' || v_ext;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path;

  select * into v_response from extensions.http((
    'POST',
    v_sign_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
      extensions.http_header('apikey', v_service_role_key)
    ],
    'application/json',
    '{}'
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not prepare upload (HTTP %): %', v_response.status, v_response.content;
  end if;

  v_body := v_response.content::jsonb;
  v_token := coalesce(nullif(v_body ->> 'token', ''), nullif(split_part(coalesce(v_body ->> 'url', ''), 'token=', 2), ''));

  if v_token is null or v_token = '' then
    raise exception 'Storage did not return an upload token.';
  end if;

  storage_path := v_path;
  upload_token := v_token;
  return next;
end;
$$;

grant execute on function public.admin_create_chatbot_attachment_upload(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 14. admin_get_chatbot_attachment_signed_url (live def: supabase_chatbot_staff_attachment_upload.sql)

drop function if exists public.admin_get_chatbot_attachment_signed_url(text, text, text);

create or replace function public.admin_get_chatbot_attachment_signed_url(
  p_admin_username text,
  p_admin_password text,
  p_storage_path text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'chatbot-attachments';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_signed_path text;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_storage_path is null or trim(p_storage_path) = '' then
    raise exception 'Storage path is required.';
  end if;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/sign/' || v_bucket || '/' || p_storage_path;

  select * into v_response from extensions.http((
    'POST',
    v_sign_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
      extensions.http_header('apikey', v_service_role_key)
    ],
    'application/json',
    jsonb_build_object('expiresIn', 60 * 24 * 60 * 60)::text
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not sign attachment URL (HTTP %): %', v_response.status, left(v_response.content, 300);
  end if;

  v_body := v_response.content::jsonb;
  v_signed_path := coalesce(nullif(v_body ->> 'signedURL', ''), nullif(v_body ->> 'signedUrl', ''));

  if v_signed_path is null or trim(v_signed_path) = '' then
    raise exception 'Storage did not return a signed URL.';
  end if;

  return v_base_url || '/storage/v1' || v_signed_path;
end;
$$;

grant execute on function public.admin_get_chatbot_attachment_signed_url(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 15. admin_create_chatbot_media_upload (live def: supabase_chatbot_media_library.sql)

drop function if exists public.admin_create_chatbot_media_upload(text, text, text);

create or replace function public.admin_create_chatbot_media_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'chatbot-media-library';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
  v_ext text;
  v_path text;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  v_ext := lower(regexp_replace(coalesce(p_file_name, ''), '^.*\.', ''));
  if v_ext !~ '^[a-z0-9]{1,10}$' then
    v_ext := 'jpg';
  end if;
  v_path := 'media-' || extract(epoch from clock_timestamp())::bigint || '-' || floor(random() * 1000000)::int || '.' || v_ext;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path;

  select * into v_response from extensions.http((
    'POST',
    v_sign_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
      extensions.http_header('apikey', v_service_role_key)
    ],
    'application/json',
    '{}'
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not prepare upload (HTTP %): %', v_response.status, v_response.content;
  end if;

  v_body := v_response.content::jsonb;
  v_token := coalesce(nullif(v_body ->> 'token', ''), nullif(split_part(coalesce(v_body ->> 'url', ''), 'token=', 2), ''));

  if v_token is null or v_token = '' then
    raise exception 'Storage did not return an upload token.';
  end if;

  storage_path := v_path;
  upload_token := v_token;
  public_url := v_base_url || '/storage/v1/object/public/' || v_bucket || '/' || v_path;
  return next;
end;
$$;

grant execute on function public.admin_create_chatbot_media_upload(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 16. admin_add_chatbot_media_item (live def: supabase_chatbot_media_library.sql)

drop function if exists public.admin_add_chatbot_media_item(text, text, text, text, text, text);

create or replace function public.admin_add_chatbot_media_item(
  p_admin_username text,
  p_admin_password text,
  p_storage_path text,
  p_media_url text,
  p_media_type text,
  p_file_name text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_media_type text := lower(trim(coalesce(p_media_type, '')));
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_storage_path is null or trim(p_storage_path) = '' or p_media_url is null or trim(p_media_url) = '' then
    raise exception 'Storage path/url is required.';
  end if;
  if v_media_type not in ('image', 'video') then
    v_media_type := 'image';
  end if;

  insert into public."ChatbotMediaItems" ("MediaType", "StoragePath", "MediaUrl", "FileName", "CreatedBy")
  values (v_media_type, trim(p_storage_path), trim(p_media_url), nullif(trim(coalesce(p_file_name, '')), ''), p_admin_username)
  returning "Id" into v_id;

  return v_id;
end;
$$;

grant execute on function public.admin_add_chatbot_media_item(text, text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 17. admin_list_chatbot_media_items (live def: supabase_chatbot_media_library.sql)

drop function if exists public.admin_list_chatbot_media_items(text, text);

create or replace function public.admin_list_chatbot_media_items(
  p_admin_username text,
  p_admin_password text
)
returns table(id bigint, media_type text, media_url text, file_name text, created_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select m."Id", m."MediaType"::text, m."MediaUrl"::text, m."FileName"::text, m."CreatedAtUtc"
    from public."ChatbotMediaItems" m
    order by m."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_chatbot_media_items(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 18. admin_delete_chatbot_media_item (live def: supabase_chatbot_media_library.sql)

drop function if exists public.admin_delete_chatbot_media_item(text, text, bigint);

create or replace function public.admin_delete_chatbot_media_item(
  p_admin_username text,
  p_admin_password text,
  p_media_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."ChatbotMediaItems" where "Id" = p_media_id;
end;
$$;

grant execute on function public.admin_delete_chatbot_media_item(text, text, bigint) to anon;

-- ---------------------------------------------------------------------------
-- 19. admin_list_chatbot_quick_replies (live def: supabase_chatbot_quick_reply_multi_images.sql)

drop function if exists public.admin_list_chatbot_quick_replies(text, text);

create or replace function public.admin_list_chatbot_quick_replies(
  p_admin_username text,
  p_admin_password text
)
returns table(id bigint, label text, message_text text, image_urls jsonb)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      q."Id",
      q."Label"::text,
      q."MessageText"::text,
      coalesce(
        (
          select jsonb_agg(jsonb_build_object('id', i."Id", 'image_url', i."ImageUrl") order by i."SortOrder", i."Id")
          from public."ChatbotQuickReplyImages" i
          where i."QuickReplyId" = q."Id"
        ),
        '[]'::jsonb
      ) as image_urls
    from public."ChatbotQuickReplies" q
    order by q."SortOrder", q."Id";
end;
$$;

grant execute on function public.admin_list_chatbot_quick_replies(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 20. admin_upsert_chatbot_quick_reply (live def: supabase_chatbot_quick_reply_multi_images.sql)

drop function if exists public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text, text, text, boolean);
drop function if exists public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text, text, text);
drop function if exists public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text);

create or replace function public.admin_upsert_chatbot_quick_reply(
  p_admin_username text,
  p_admin_password text,
  p_id bigint,
  p_label text,
  p_message_text text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_message text := nullif(trim(coalesce(p_message_text, '')), '');
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_label is null or trim(p_label) = '' then
    raise exception 'Label is required.';
  end if;

  if p_id is null then
    insert into public."ChatbotQuickReplies" ("Label", "MessageText", "CreatedBy")
    values (trim(p_label), coalesce(v_message, ''), p_admin_username)
    returning "Id" into v_id;
  else
    update public."ChatbotQuickReplies"
    set "Label" = trim(p_label), "MessageText" = coalesce(v_message, '')
    where "Id" = p_id;

    if not found then
      raise exception 'Quick reply not found.';
    end if;
    v_id := p_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 21. admin_create_quick_reply_image_upload (live def: supabase_chatbot_quick_reply_images.sql)

drop function if exists public.admin_create_quick_reply_image_upload(text, text, text);

create or replace function public.admin_create_quick_reply_image_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'quick-reply-images';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
  v_ext text;
  v_path text;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  v_ext := lower(regexp_replace(coalesce(p_file_name, ''), '^.*\.', ''));
  if v_ext !~ '^[a-z0-9]{1,10}$' then
    v_ext := 'jpg';
  end if;
  v_path := 'quickreply-' || extract(epoch from clock_timestamp())::bigint || '-' || floor(random() * 1000000)::int || '.' || v_ext;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path;

  select * into v_response from extensions.http((
    'POST',
    v_sign_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
      extensions.http_header('apikey', v_service_role_key)
    ],
    'application/json',
    '{}'
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not prepare upload (HTTP %): %', v_response.status, v_response.content;
  end if;

  v_body := v_response.content::jsonb;
  v_token := coalesce(nullif(v_body ->> 'token', ''), nullif(split_part(coalesce(v_body ->> 'url', ''), 'token=', 2), ''));

  if v_token is null or v_token = '' then
    raise exception 'Storage did not return an upload token.';
  end if;

  storage_path := v_path;
  upload_token := v_token;
  public_url := v_base_url || '/storage/v1/object/public/' || v_bucket || '/' || v_path;
  return next;
end;
$$;

grant execute on function public.admin_create_quick_reply_image_upload(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 22. admin_add_chatbot_quick_reply_image (live def: supabase_chatbot_quick_reply_multi_images.sql)

drop function if exists public.admin_add_chatbot_quick_reply_image(text, text, bigint, text, text);

create or replace function public.admin_add_chatbot_quick_reply_image(
  p_admin_username text,
  p_admin_password text,
  p_quick_reply_id bigint,
  p_image_path text,
  p_image_url text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_next_sort int;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_image_path is null or trim(p_image_path) = '' or p_image_url is null or trim(p_image_url) = '' then
    raise exception 'Image path/url is required.';
  end if;
  if not exists (select 1 from public."ChatbotQuickReplies" where "Id" = p_quick_reply_id) then
    raise exception 'Quick reply not found.';
  end if;

  select coalesce(max("SortOrder") + 1, 0) into v_next_sort
  from public."ChatbotQuickReplyImages" where "QuickReplyId" = p_quick_reply_id;

  insert into public."ChatbotQuickReplyImages" ("QuickReplyId", "ImagePath", "ImageUrl", "SortOrder")
  values (p_quick_reply_id, trim(p_image_path), trim(p_image_url), v_next_sort)
  returning "Id" into v_id;

  return v_id;
end;
$$;

grant execute on function public.admin_add_chatbot_quick_reply_image(text, text, bigint, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 23. admin_delete_chatbot_quick_reply (live def: supabase_chatbot_quick_replies.sql)

create or replace function public.admin_delete_chatbot_quick_reply(
  p_admin_username text,
  p_admin_password text,
  p_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."ChatbotQuickReplies" where "Id" = p_id;
end;
$$;

grant execute on function public.admin_delete_chatbot_quick_reply(text, text, bigint) to anon;

-- ---------------------------------------------------------------------------
-- 24. admin_delete_chatbot_quick_reply_image (live def: supabase_chatbot_quick_reply_multi_images.sql)

drop function if exists public.admin_delete_chatbot_quick_reply_image(text, text, bigint);

create or replace function public.admin_delete_chatbot_quick_reply_image(
  p_admin_username text,
  p_admin_password text,
  p_image_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."ChatbotQuickReplyImages" where "Id" = p_image_id;
end;
$$;

grant execute on function public.admin_delete_chatbot_quick_reply_image(text, text, bigint) to anon;

-- ---------------------------------------------------------------------------
-- 25. admin_send_chatbot_message - the actual "send reply" RPC. Not called directly from
-- gmaConversations.js - reached via the chatbot-staff-reply Edge Function
-- (supabase/functions/chatbot-staff-reply/index.ts), which uses the service-role client to call
-- this. Live def: supabase_chatbot_staff_attachment_upload.sql.

drop function if exists public.admin_send_chatbot_message(text, text, text, text, text, text);

create or replace function public.admin_send_chatbot_message(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_message text,
  p_attachment_url text default null,
  p_attachment_type text default null,
  p_attachment_path text default null
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_message_id bigint;
  v_message text := coalesce(trim(p_message), '');
  v_attachment_url text := nullif(trim(coalesce(p_attachment_url, '')), '');
  v_attachment_type text := nullif(trim(coalesce(p_attachment_type, '')), '');
  v_attachment_path text := nullif(trim(coalesce(p_attachment_path, '')), '');
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;
  if v_message = '' and v_attachment_url is null then
    raise exception 'Message is required.';
  end if;

  insert into public."ChatbotMessages" ("Psid", "Role", "Content", "SentByUsername", "AttachmentUrl", "AttachmentType", "AttachmentPath")
  values (
    p_psid,
    'staff',
    case when v_message = '' then '[Photo]' else v_message end,
    p_admin_username,
    v_attachment_url,
    v_attachment_type,
    v_attachment_path
  )
  returning "Id" into v_message_id;

  update public."ChatbotConversations"
  set "LastMessageAtUtc" = now(),
      "LastBotMessageAtUtc" = now(),
      "IsPaused" = true
  where "Psid" = p_psid;

  if not found then
    raise exception 'No conversation found for that Psid.';
  end if;

  return v_message_id;
end;
$$;

grant execute on function public.admin_send_chatbot_message(text, text, text, text, text, text, text) to anon;
