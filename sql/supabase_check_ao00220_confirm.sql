-- Read-only check: why was AO-00220 confirmed with no payment? Shows who confirmed it and when, whether
-- they're a super user (super users may confirm unpaid orders), how much real money is on it, and whether the
-- Confirm-needs-payment check (supabase_manual_payments_super_user_only.sql) is installed yet.
-- One result; nothing is changed.

with o as (
  select "OrderID", "ConfirmedBy", "ConfirmedAtUtc", "CreatedBy", "Source", "AmountPaid"
    from public."OnlineOrders" where "OrderID" = 'AO-00220'
),
confirmer as (
  select s."Username", s."DisplayName", coalesce(s."SuperUser", false) as super_user
    from public."StaffUsers" s, o
   where s."Username" = o."ConfirmedBy" or s."DisplayName" = o."ConfirmedBy"
   limit 1
)
select '1. Confirmed by' as section,
       coalesce((select "ConfirmedBy" from o), '(order not found)') as value,
       coalesce(to_char((select "ConfirmedAtUtc" from o) at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'), '') || ' (PH time)' as detail
union all
select '2. Confirmer is a super user',
       coalesce((select case when super_user then 'YES - allowed to confirm unpaid orders' else 'no' end from confirmer), 'unknown'),
       coalesce((select "Username" from confirmer), '')
union all
select '3. Real payments on the order',
       coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p
                  where p."OrderNo" = 'AO-00220' and coalesce(p."Method", '') not ilike 'Xendit TEST%'), 0)::text,
       'Xendit TEST payments excluded'
union all
select '4. Confirm-needs-payment check installed',
       case when position('_order_real_paid' in pg_get_functiondef('public.admin_confirm_bot_order(text, text, text)'::regprocedure)) > 0
            then 'YES' else 'NO - supabase_manual_payments_super_user_only.sql not run yet' end,
       '';
