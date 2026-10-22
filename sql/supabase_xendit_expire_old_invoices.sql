-- Xendit: one open invoice per order - per AO-00118 (₱3,000 order showed ₱4,500 paid). Two invoices for
-- the same order (Full balance at 7:22 PM, Down payment at 7:28 PM) were both left open and both got paid.
--
-- xendit-create-invoice now, BEFORE making a new invoice, lists the order's still-open invoices
-- (_xendit_open_invoices) and expires each one at Xendit (POST /invoices/{id}/expire!), marking it
-- Expired here (_xendit_mark_expired). If Xendit says one was already paid, it is recorded as paid
-- (_xendit_record_invoice_status) and the customer is asked to refresh instead of getting a new invoice.
--
-- Run AFTER supabase_xendit_payments.sql. Safe to re-run. Needs xendit-create-invoice redeployed.

-- Same gate as _xendit_prepare_invoice: while Xendit is switched off only a super user's login gets the
-- list, so nobody else can make the function expire a customer's open invoice.
drop function if exists public._xendit_open_invoices(text);
drop function if exists public._xendit_open_invoices(text, text, text);

create or replace function public._xendit_open_invoices(p_order_ref text, p_staff_username text default null,
                                                       p_staff_password text default null)
returns table(payment_id uuid, invoice_id text)
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
    select x."PaymentID", x."InvoiceID"
      from public."XenditPayments" x
     where x."OrderRef" = (select r.order_ref from public._xendit_resolve_order(p_order_ref) r)
       and x."Status" = 'Pending'
       and x."InvoiceID" is not null
     order by x."CreatedAtUtc";
end;
$$;

revoke all on function public._xendit_open_invoices(text, text, text) from public, anon, authenticated;
grant execute on function public._xendit_open_invoices(text, text, text) to service_role;

create or replace function public._xendit_mark_expired(p_payment_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update public."XenditPayments" set "Status" = 'Expired'
   where "PaymentID" = p_payment_id and "Status" in ('Pending', 'Creating');
$$;

revoke all on function public._xendit_mark_expired(uuid) from public, anon, authenticated;
grant execute on function public._xendit_mark_expired(uuid) to service_role;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name,
       case when has_function_privilege('service_role', p.oid, 'EXECUTE')
             and not has_function_privilege('anon', p.oid, 'EXECUTE') then 'service_role only' else 'CHECK GRANTS' end as access
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('_xendit_open_invoices', '_xendit_mark_expired');
