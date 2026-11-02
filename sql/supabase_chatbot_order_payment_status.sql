-- Vic / Alice: an order's payment status for get_order_status - per "does ai bot vic and alice know if the order
-- is paid from xendit?". They couldn't tell: an AO- lookup returned no amounts at all, so a customer who just
-- paid could be asked for a screenshot.
--
-- Returns the total, amount paid, balance and real Xendit payments. TEST payments are left out of the amounts,
-- so the bot never tells a customer fake money counts as paid. pay_link_ok is true only when customers can
-- really pay (Enabled and LiveMode on, order payable): before that the bot has no link to send.
-- Walk-ins don't use this: they were paid at the counter, and their lookup already has a balance.
--
-- Run AFTER supabase_xendit_live_mode.sql and supabase_xendit_pos_walkin.sql. Safe to re-run.
-- Needs chatbot-engine.ts redeployed (every function that uses it).

create or replace function public._chatbot_order_payment_status(p_order_ref text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  r record;
  v_test numeric;
  v_paid numeric;
  v_balance numeric;
  v_payments jsonb;
begin
  select * into r from public._xendit_resolve_order(p_order_ref);
  if r.order_ref is null then
    return null;
  end if;

  select coalesce(sum(coalesce(x."PaidAmount", x."Amount")), 0) into v_test
    from public."XenditPayments" x
   where x."OrderRef" = r.order_ref and x."Source" = 'Online' and x."Status" = 'Paid' and x."IsTest";

  select coalesce(jsonb_agg(jsonb_build_object(
           'amount', coalesce(x."PaidAmount", x."Amount"),
           'purpose', x."Purpose",
           'channel', public._xendit_channel_label(x."PaymentChannel", x."PaymentMethod"),
           'paid_at', to_char(x."PaidAtUtc" at time zone 'Asia/Manila', 'Mon DD, YYYY HH12:MI AM')
         ) order by x."PaidAtUtc"), '[]'::jsonb) into v_payments
    from public."XenditPayments" x
   where x."OrderRef" = r.order_ref and x."Source" = 'Online' and x."Status" = 'Paid' and not x."IsTest";

  v_paid := greatest(r.amount_paid - v_test, 0);
  v_balance := greatest(r.total - v_paid, 0);

  return jsonb_build_object(
    'order_ref', r.order_ref,
    'total', r.total,
    'amount_paid', round(v_paid, 2),
    'balance', round(v_balance, 2),
    'xendit_payments', v_payments,
    'pay_link_ok', coalesce((select s."Enabled" and s."LiveMode" from public."XenditSettings" s where s."Id" = 1), false)
                   and not r.is_cancelled and r.is_portal and v_balance > 0
  );
end;
$$;

revoke all on function public._chatbot_order_payment_status(text) from public, anon, authenticated;
grant execute on function public._chatbot_order_payment_status(text) to service_role;

notify pgrst, 'reload schema';

-- Verification - one result: the ₱1 test order should show its amounts, with test payments left out.
select 'AO-00188' as order_ref, public._chatbot_order_payment_status('AO-00188')::text as payment_status;
