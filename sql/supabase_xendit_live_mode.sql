-- Xendit: test / live switch - per "can we store it on a separate key.. let the system decide what key it will
-- use.. this way we avoid manual input storage in supabase". Both keys and both webhook tokens stay in Supabase
-- secrets; XenditSettings."LiveMode" (ticked on the Xendit Payments page, default OFF = test) picks the key for
-- NEW payments. An existing payment always uses the key of its own mode ("IsTest"), and the webhook picks the
-- key from the token Xendit sent, so switching mode never strands a payment.
--
-- TEST MODE IS SUPER USERS ONLY on pay.html: fake money must never mark a customer's real order as paid, so
-- customers can't start a payment in test mode, even with "Enabled" on. Switching to test also turns the POS
-- switch off, since a POS could otherwise complete a sale on a test QR.
--
-- Run AFTER supabase_xendit_pos_walkin.sql and supabase_xendit_expire_old_invoices.sql. Safe to re-run.
-- Needs the Edge Functions xendit-create-invoice, xendit-webhook and xendit-pos-payment redeployed with the
-- secrets in their headers, and js/xenditPayments.js ?v=xendit8.

alter table public."XenditSettings" add column if not exists "LiveMode" boolean not null default false;

-- ---------------------------------------------------------------------------
-- 1. Edge Functions only: which mode new payments use, and whether this caller may start one.

create or replace function public._xendit_current_mode(p_staff_username text default null, p_staff_password text default null)
returns table(is_test boolean, may_pay boolean)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_live boolean := coalesce((select s."LiveMode" from public."XenditSettings" s where s."Id" = 1), false);
begin
  return query select not v_live,
    v_live or (p_staff_username is not null and public.is_admin_authorized(p_staff_username, p_staff_password));
end;
$$;

revoke all on function public._xendit_current_mode(text, text) from public, anon, authenticated;
grant execute on function public._xendit_current_mode(text, text) to service_role;

-- Same as supabase_xendit_expire_old_invoices.sql, plus each invoice's mode so it's cancelled with its own key.
drop function if exists public._xendit_open_invoices(text, text, text);

create or replace function public._xendit_open_invoices(p_order_ref text, p_staff_username text default null,
                                                       p_staff_password text default null)
returns table(payment_id uuid, invoice_id text, is_test boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not coalesce((select "Enabled" from public."XenditSettings" where "Id" = 1), false)
     and not (p_staff_username is not null and public.is_admin_authorized(p_staff_username, p_staff_password)) then
    return;
  end if;
  return query
    select x."PaymentID", x."InvoiceID", x."IsTest"
      from public."XenditPayments" x
     where x."OrderRef" = (select r.order_ref from public._xendit_resolve_order(p_order_ref) r)
       and x."Status" = 'Pending'
       and x."InvoiceID" is not null
     order by x."CreatedAtUtc";
end;
$$;

revoke all on function public._xendit_open_invoices(text, text, text) from public, anon, authenticated;
grant execute on function public._xendit_open_invoices(text, text, text) to service_role;

-- Same as supabase_xendit_pos_walkin.sql, plus the payment's mode.
drop function if exists public._xendit_pos_get_payment(uuid);

create or replace function public._xendit_pos_get_payment(p_payment_id uuid)
returns table(payment_id uuid, invoice_id text, status text, amount numeric, paid_amount numeric, payment_channel text, payment_method text, expires_at timestamptz, is_test boolean)
language sql
stable
security definer
set search_path = public
as $$
  select x."PaymentID", x."InvoiceID", x."Status", x."Amount", x."PaidAmount", x."PaymentChannel", x."PaymentMethod", x."ExpiresAtUtc", x."IsTest"
    from public."XenditPayments" x
   where x."PaymentID" = p_payment_id and x."Source" = 'POS';
$$;

revoke all on function public._xendit_pos_get_payment(uuid) from public, anon, authenticated;
grant execute on function public._xendit_pos_get_payment(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Xendit Payments page

drop function if exists public.admin_get_xendit_settings(text, text);

create or replace function public.admin_get_xendit_settings(p_admin_username text, p_admin_password text)
returns table(enabled boolean, show_on_order_now boolean, updated_by text, updated_at timestamptz, pos_enabled boolean, live_mode boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select s."Enabled", s."ShowOnOrderNow", s."UpdatedBy", s."UpdatedAtUtc", s."PosEnabled", s."LiveMode"
      from public."XenditSettings" s where s."Id" = 1;
end;
$$;

grant execute on function public.admin_get_xendit_settings(text, text) to anon;

create or replace function public.admin_set_xendit_live_mode(p_admin_username text, p_admin_password text, p_live_mode boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  update public."XenditSettings"
     set "LiveMode" = coalesce(p_live_mode, false),
         "PosEnabled" = case when coalesce(p_live_mode, false) then "PosEnabled" else false end,
         "UpdatedBy" = p_admin_username,
         "UpdatedAtUtc" = now()
   where "Id" = 1;
end;
$$;

grant execute on function public.admin_set_xendit_live_mode(text, text, boolean) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'setting' as section, 'Mode' as item, case when s."LiveMode" then 'LIVE' else 'TEST' end as value
  from public."XenditSettings" s where s."Id" = 1
union all
select 'function', p.proname::text,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon'
            when has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role only'
            else 'internal' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('_xendit_current_mode', '_xendit_open_invoices', '_xendit_pos_get_payment', 'admin_get_xendit_settings', 'admin_set_xendit_live_mode');
