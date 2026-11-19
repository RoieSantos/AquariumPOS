-- Sales Manager can record payments by hand - per "please allow my sales manager to do payments manually for
-- online orders / conversations and other orders" (2026-11-19).
--
-- While Xendit is live, _manual_payment_guard (supabase_manual_payments_super_user_only.sql) only let a Super
-- User Add / Edit / Delete a payment on an order (admin_add/update/delete_automated_order_payment - used by
-- Conversations and Online Orders). Now a Super User OR an active Sales Manager (Staff Role, supabase_sales_manager_role.sql)
-- can. The caller must still pass is_conversations_authorized (Conversations Access), as before.
-- Pages: js/gmaConversations.js ?v=salesmgrpay1, js/onlineNewOrders.js ?v=salesmgrpay1.
--
-- Run AFTER supabase_manual_payments_super_user_only.sql and supabase_sales_manager_role.sql.
-- If supabase_manual_payments_super_user_only.sql is ever re-run, run this file again afterwards. Safe to re-run.

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
     and not public._is_active_super_user(p_username)
     and not exists (select 1 from public."StaffUsers" u
                      where u."Username" = p_username and u."IsActive"
                        and 'SalesManager' = any(coalesce(u."StaffRoles", '{}'::text[]))) then
    raise exception 'Only a super user or sales manager can record or change a payment by hand. Send the customer a Pay link instead - the payment is recorded on the order automatically.';
  end if;
end;
$$;

revoke execute on function public._manual_payment_guard(text, text) from public, anon, authenticated;

-- Check - one result.
select 'guard allows Sales Manager' as check_name,
       (pg_get_functiondef('public._manual_payment_guard(text, text)'::regprocedure) like '%SalesManager%')::text as ok
union all
select 'add/update/delete still guarded',
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('admin_add_automated_order_payment', 'admin_update_automated_order_payment', 'admin_delete_automated_order_payment')
           and position('_manual_payment_guard' in pg_get_functiondef(p.oid)) > 0)::text || ' of 3';
