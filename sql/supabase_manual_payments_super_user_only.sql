-- Manual payments: super users only + no Confirm Order without a payment.
--
-- 1. Per "if the xendit is live we can remove the manual payment option under conversations orders" - Add /
--    Edit / Delete payment on an order (Conversations, Online Orders) is now super users only. Everyone else
--    sends the customer a Pay link, which records itself (xendit-webhook). Applies only while Xendit is switched
--    on for customers (XenditSettings."Enabled") - with it off there's no Pay link. Super users keep it for cash on
--    delivery, money sent outside Xendit, and Xendit outages. The pages hide the buttons too
--    (js/gmaConversations.js, js/onlineNewOrders.js ?v=manualpay1); this is the rule that can't be bypassed.
--
--    The live functions are NOT copied here: whatever version is live is renamed to
--    _<name>_impl (no grants) and a small guard function takes its place, so nothing in the live body is lost.
--    If an older file re-creates one of these functions later, just run this file again - it moves that
--    version behind the guard.
--
-- 2. Per "before the system allow order confirmation it will check if the payment has been made" -
--    admin_confirm_bot_order refuses an order with no real payment (Xendit TEST payments don't count).
--    Super users can still confirm one, for cash on delivery. Xendit's own auto-confirm is unchanged (it
--    already waits for the 50% down payment).
--
-- Run AFTER supabase_xendit_auto_confirm.sql, supabase_bot_orders_portal_confirm.sql and
-- supabase_ao_order_payment_edit.sql. Safe to re-run. If supabase_xendit_auto_confirm.sql is ever re-run,
-- run this one again afterwards (it redefines admin_confirm_bot_order without the payment check).
-- NOTE: supabase_automated_order_cod.sql redefines admin_confirm_bot_order again with a COD exception - if
-- you re-run THIS file, run that one again afterwards too.

-- ---------------------------------------------------------------------------
-- Helpers

create or replace function public._manual_payment_guard(p_username text, p_password text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_conversations_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  -- Only while Xendit is switched on for customers: with it off there's no Pay link, so everyone keeps manual payments.
  if coalesce((select s."Enabled" from public."XenditSettings" s where s."Id" = 1), false)
     and not public._is_active_super_user(p_username) then
    raise exception 'Only a super user can record or change a payment by hand. Send the customer a Pay link instead - the payment is recorded on the order automatically.';
  end if;
end;
$$;

revoke execute on function public._manual_payment_guard(text, text) from public, anon, authenticated;

-- Real money on an order: every payment except Xendit test ones.
create or replace function public._order_real_paid(p_order_no text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(p."Amount"), 0)::numeric
    from public."AutomatedOrderPayments" p
   where p."OrderNo" = trim(p_order_no) and coalesce(p."Method", '') not ilike 'Xendit TEST%';
$$;

revoke execute on function public._order_real_paid(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Move each live payment function behind the guard (only if it isn't the guard already)

do $$
declare
  f record;
  v_sig regprocedure;
begin
  for f in
    select * from (values
      ('admin_add_automated_order_payment',    'text, text, text, numeric, text, text'),
      ('admin_update_automated_order_payment', 'text, text, bigint, numeric, text, text'),
      ('admin_delete_automated_order_payment', 'text, text, bigint')
    ) v(name, args)
  loop
    v_sig := format('public.%I(%s)', f.name, f.args)::regprocedure;
    if position('_manual_payment_guard' in pg_get_functiondef(v_sig)) = 0 then
      execute format('drop function if exists public.%I(%s)', '_' || f.name || '_impl', f.args);
      execute format('alter function public.%I(%s) rename to %I', f.name, f.args, '_' || f.name || '_impl');
      execute format('revoke execute on function public.%I(%s) from public, anon, authenticated', '_' || f.name || '_impl', f.args);
    end if;
  end loop;
end;
$$;

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
begin
  perform public._manual_payment_guard(p_admin_username, p_admin_password);
  return query select i.pancake_sync_error
    from public._admin_add_automated_order_payment_impl(p_admin_username, p_admin_password, p_order_no, p_amount, p_method, p_reference) i;
end;
$$;

grant execute on function public.admin_add_automated_order_payment(text, text, text, numeric, text, text) to anon;

create or replace function public.admin_update_automated_order_payment(
  p_admin_username text,
  p_admin_password text,
  p_payment_id bigint,
  p_amount numeric,
  p_method text,
  p_reference text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
begin
  perform public._manual_payment_guard(p_admin_username, p_admin_password);
  perform public._admin_update_automated_order_payment_impl(p_admin_username, p_admin_password, p_payment_id, p_amount, p_method, p_reference);
end;
$$;

grant execute on function public.admin_update_automated_order_payment(text, text, bigint, numeric, text, text) to anon;

create or replace function public.admin_delete_automated_order_payment(
  p_admin_username text,
  p_admin_password text,
  p_payment_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
begin
  perform public._manual_payment_guard(p_admin_username, p_admin_password);
  perform public._admin_delete_automated_order_payment_impl(p_admin_username, p_admin_password, p_payment_id);
end;
$$;

grant execute on function public.admin_delete_automated_order_payment(text, text, bigint) to anon;

-- ---------------------------------------------------------------------------
-- 2. Confirm Order needs a payment (body otherwise as in supabase_xendit_auto_confirm.sql)

create or replace function public.admin_confirm_bot_order(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(online_order_id text, order_status text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if public._order_real_paid(p_order_no) <= 0 and not public._is_active_super_user(p_admin_username) then
    raise exception 'Order % has no payment yet, so it can''t be confirmed. Send the customer a Pay link - the order confirms itself once the down payment is paid. Cash on delivery: ask a super user to confirm it.', trim(p_order_no);
  end if;
  return query select c.online_order_id, c.order_status from public._confirm_bot_order(p_order_no, p_admin_username) c;
end;
$$;

grant execute on function public.admin_confirm_bot_order(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Check: the 4 admin_ functions should say 'guarded'; the 3 _impl rows are the original bodies behind them.
select p.proname::text as function_name,
       case when p.proname like '\_%\_impl' then 'original body (no grants)'
            when position('_manual_payment_guard' in pg_get_functiondef(p.oid)) > 0
              or position('_order_real_paid' in pg_get_functiondef(p.oid)) > 0 then 'guarded'
            else 'NOT GUARDED - run this file again' end as state
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('admin_add_automated_order_payment', 'admin_update_automated_order_payment',
                     'admin_delete_automated_order_payment', 'admin_confirm_bot_order',
                     '_admin_add_automated_order_payment_impl', '_admin_update_automated_order_payment_impl',
                     '_admin_delete_automated_order_payment_impl')
 order by 1;
