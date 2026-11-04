-- GMA Conversations order card: once an order is in Online Orders, its Total / Paid / Balance come from
-- Online Orders - per "will this happen moving forwards?" -> "yes" (after AO-00176 / AO-00172 showed a
-- delivery fee "due" on the card while Online Orders had them fully paid; supabase_ao_delivery_fee_double_count_fix.sql).
--
-- After Confirm Order the order's money lives in two places: AutomatedOrders.EstimatedTotal +
-- AutomatedOrderPayments (what the card showed) and OnlineOrders AmountPaid / Balance (Online Orders, the
-- driver's amount to collect, receipts). Every writer had to keep both in step; any one that didn't left the
-- card wrong. Now the card reads the Online Orders row when there is one - joined the same way as
-- _xendit_resolve_order (PancakeReceiptNo, else OrderNo), with the same Total = AmountPaid + Balance - so the
-- card, Online Orders, the pay page and Vic / Alice's get_order_status all show the same figures.
-- Drafts (not confirmed yet, no Online Orders row) keep EstimatedTotal - sum(AutomatedOrderPayments), as before.
--
-- Re-creates admin_list_automated_orders_by_gma_conversation (latest: supabase_xendit_bot_pay_online.sql) -
-- same columns, only estimated_total / amount_paid / balance change. No JS change.
-- Run AFTER supabase_xendit_bot_pay_online.sql. Safe to re-run. If that file is re-run, run this one again.
-- Ends with one result: every order where the card's figures changed.

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
  created_at_utc timestamptz,
  delivery_fee numeric,
  awaiting_online_payment boolean
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
      -- This file: the Online Orders figures once confirmed, else the draft's own.
      case when oo."OrderID" is not null then coalesce(oo."AmountPaid", 0) + coalesce(oo."Balance", 0) else o."EstimatedTotal" end::numeric,
      case when oo."OrderID" is not null then coalesce(oo."AmountPaid", 0) else ap.paid end::numeric,
      case when oo."OrderID" is not null then coalesce(oo."Balance", 0) else o."EstimatedTotal" - ap.paid end::numeric,
      o."PancakeOrderId"::text,
      o."PancakeOrderLink"::text,
      o."PancakeSyncStatus"::text,
      o."ReceiptConfirmedAtUtc",
      o."CreatedAtUtc",
      coalesce(o."DeliveryFee", 0)::numeric,
      o."AwaitingOnlinePaymentSinceUtc" is not null and public._xendit_unpaid_order_open(o."OrderNo")
    from public."AutomatedOrders" o
    cross join lateral (select coalesce(sum(p."Amount"), 0) as paid
                          from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo") ap
    left join public."OnlineOrders" oo
      on oo."OrderID" = coalesce(nullif(trim(o."PancakeReceiptNo"), ''), o."OrderNo")
    where o."GmaPsid" = trim(p_psid)
      and (p_page_id is null or trim(p_page_id) = '' or o."GmaPageId" = trim(p_page_id))
    order by o."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_automated_orders_by_gma_conversation(text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Check - one result: orders whose card figures this changes (old -> new). Empty = all already agreed.
select ao."OrderNo"::text as order_no,
       ao."EstimatedTotal" as old_card_total,
       coalesce(oo."AmountPaid", 0) + coalesce(oo."Balance", 0) as new_card_total,
       ap.paid as old_card_paid,
       coalesce(oo."AmountPaid", 0) as new_card_paid,
       ao."EstimatedTotal" - ap.paid as old_card_balance,
       coalesce(oo."Balance", 0) as new_card_balance,
       oo."Status"::text as online_status
  from public."AutomatedOrders" ao
  cross join lateral (select coalesce(sum(p."Amount"), 0) as paid
                        from public."AutomatedOrderPayments" p where p."OrderNo" = ao."OrderNo") ap
  join public."OnlineOrders" oo on oo."OrderID" = coalesce(nullif(trim(ao."PancakeReceiptNo"), ''), ao."OrderNo")
 where ao."GmaPsid" is not null
   and (ao."EstimatedTotal" - ap.paid is distinct from coalesce(oo."Balance", 0)
        or ap.paid is distinct from coalesce(oo."AmountPaid", 0))
 order by ao."OrderNo";
