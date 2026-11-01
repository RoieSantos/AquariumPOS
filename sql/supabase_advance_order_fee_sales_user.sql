-- Delivery Fee on the Advance Order card: Sales Users too - per "CAN you allow sales user too?".
--
-- Re-creates _advance_order_fee_authorized (supabase_order_card_delivery_fee_walkin_advance.sql), the one
-- check behind staff_get_advance_order_delivery_fee and staff_set_advance_order_delivery_fee.
-- Run AFTER supabase_order_card_delivery_fee_walkin_advance.sql. Safe to re-run. Needs js/onlineOrders.js ?v=advfeesales1.

create or replace function public._advance_order_fee_authorized(p_username text, p_password text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin_authorized(p_username, p_password)
      or (public.is_staff_authorized(p_username, p_password)
          and (public._production_is_manager(p_username)
               or exists (select 1 from public."StaffUsers" u
                          where u."Username" = p_username and u."IsActive" and coalesce(u."SalesUser", false))));
$$;

revoke execute on function public._advance_order_fee_authorized(text, text) from public, anon, authenticated;

-- Check: should return true.
select (pg_get_functiondef('public._advance_order_fee_authorized(text, text)'::regprocedure) like '%SalesUser%') as sales_user_allowed;
