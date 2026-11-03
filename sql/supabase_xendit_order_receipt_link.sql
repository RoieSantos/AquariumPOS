-- Xendit receipt link on an order's payments - per "do we have a xendit link in the orders once its paid?" /
-- "yes for super user only". A Xendit payment showed on the order as text only (method + reference); the receipt
-- page (payment-receipt.html?id=) was only linked from Xendit Payments.
--
-- admin_list_automated_order_payments (supabase_gma_conversations_staff_rpc_access.sql section 6) + xendit_payment_id:
-- the XenditPayments row a payment came from, matched on the Xendit id that _xendit_apply_payment puts at the end
-- of its Reference ("Xendit Down payment - <id>"). Null for a manual payment, or one whose Reference staff edited.
-- The pages show the link to super users only.
--
-- Run AFTER supabase_gma_conversations_staff_rpc_access.sql and supabase_xendit_payments.sql. Safe to re-run.
-- If either is ever re-run, run this one again afterwards. Needs js/gmaConversations.js ?v=xreceipt1 and
-- js/onlineNewOrders.js ?v=xreceipt1.

drop function if exists public.admin_list_automated_order_payments(text, text, text);

create or replace function public.admin_list_automated_order_payments(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(payment_id bigint, amount numeric, method text, reference text, recorded_by text, recorded_at_utc timestamptz, xendit_payment_id uuid)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select p."PaymentId", p."Amount", p."Method"::text, p."Reference"::text, p."RecordedBy"::text, p."RecordedAtUtc",
           (select x."PaymentID"
              from public."XenditPayments" x
             where p."RecordedBy" = 'Xendit'
               and x."Status" = 'Paid'
               and p_order_no in (x."AutomatedOrderNo", x."OnlineOrderID", x."OrderRef")
               and (right(p."Reference", length(x."XenditPaymentRef") + 2) = '- ' || x."XenditPaymentRef"
                 or right(p."Reference", length(x."InvoiceID") + 2) = '- ' || x."InvoiceID"
                 or right(p."Reference", length(x."ExternalID") + 2) = '- ' || x."ExternalID")
             order by x."PaidAtUtc" desc
             limit 1)
    from public."AutomatedOrderPayments" p
    where p."OrderNo" = p_order_no
    order by p."RecordedAtUtc" asc;
end;
$$;

grant execute on function public.admin_list_automated_order_payments(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: Xendit payments on orders, and how many now find their receipt.
select count(*) as xendit_payments_on_orders,
       count(*) filter (where exists (
         select 1 from public."XenditPayments" x
          where x."Status" = 'Paid'
            and p."OrderNo" in (x."AutomatedOrderNo", x."OnlineOrderID", x."OrderRef")
            and (right(p."Reference", length(x."XenditPaymentRef") + 2) = '- ' || x."XenditPaymentRef"
              or right(p."Reference", length(x."InvoiceID") + 2) = '- ' || x."InvoiceID"
              or right(p."Reference", length(x."ExternalID") + 2) = '- ' || x."ExternalID")
       )) as with_receipt_link
  from public."AutomatedOrderPayments" p
 where p."RecordedBy" = 'Xendit';
