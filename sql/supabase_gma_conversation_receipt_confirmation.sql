-- Per direct follow-up request: after a customer sends a downpayment on a brand-new (still 'New',
-- not-yet-staff-confirmed) order, the AI Bot (supabase/functions/facebook-messenger-webhook/index.ts)
-- now sends the FULL itemized receipt (every product + qty, order no, total, payment, balance) and
-- asks the customer to confirm it's all correct, instead of the plain "our team will verify this"
-- ack it used to send. Once the customer replies with a recognized affirmative (isAffirmativeReply -
-- "yes", "tama", "confirmed", etc.), that's treated as "pass to staff for order id confirmation" -
-- staff already see every 'New' order in GMA Conversations, so this just flags it as customer-
-- confirmed and ready, surfaced as a badge right next to the existing Confirm-in-Pancake button
-- (sql/supabase_gma_conversation_pancake_confirm.sql's admin_confirm_gma_order_in_pancake).
--
-- Two new columns on AutomatedOrders track the exchange:
--   ReceiptConfirmationRequestedAtUtc - set when the itemized receipt + "reply YES" prompt was sent.
--     Null means either no downpayment receipt has been sent yet, or (once ReceiptConfirmedAtUtc is
--     set) it already got its answer - this column alone isn't "awaiting", see below.
--   ReceiptConfirmedAtUtc - set when the customer's affirmative reply was recognized. The webhook
--     only intercepts a reply as "awaiting" when RequestedAtUtc is set AND ConfirmedAtUtc is still
--     null, so a customer replying "yes" a second time (e.g. to a later, unrelated message) doesn't
--     do anything - there's nothing pending to confirm anymore.

alter table public."AutomatedOrders" add column if not exists "ReceiptConfirmationRequestedAtUtc" timestamptz;
alter table public."AutomatedOrders" add column if not exists "ReceiptConfirmedAtUtc" timestamptz;

comment on column public."AutomatedOrders"."ReceiptConfirmationRequestedAtUtc" is 'Set by the AI Bot webhook when it sent the itemized receipt + "reply YES to confirm" prompt after a downpayment on a still-New order. Paired with ReceiptConfirmedAtUtc to detect the customer''s next reply as an answer to this specific prompt.';
comment on column public."AutomatedOrders"."ReceiptConfirmedAtUtc" is 'Set by the AI Bot webhook when the customer replied with a recognized affirmative to the receipt-confirmation prompt (isAffirmativeReply). This is the "passed to staff for order id confirmation" signal - drives the badge in the GMA Conversations order card (renderConversationOrderCards, js/gmaConversations.js) telling staff this order is customer-confirmed and ready to Confirm in Pancake.';

-- ---------------------------------------------------------------------------
-- admin_list_automated_orders_by_gma_conversation: redefined once more (same shape as
-- sql/supabase_gma_conversation_order_details.sql, the version currently live - confirmed against
-- js/gmaConversations.js's actual field usage: customer_email/delivery_address/location/notes, not
-- the superseded online_order_status column from supabase_gma_conversation_online_order_status.sql)
-- to also return receipt_confirmed_at_utc.
-- ---------------------------------------------------------------------------

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
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
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
