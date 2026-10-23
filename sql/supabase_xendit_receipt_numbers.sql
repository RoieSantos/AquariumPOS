-- Xendit payment receipts: a plain running receipt number - per "is that a correct receipt #.. i am just
-- thinking the customer will get confuse" (the receipt showed RSPS-AO-00118-2b0fae71, which is the
-- external_id sent to Xendit, not something a customer recognises as a receipt number).
--
-- Every payment gets "ReceiptNo" the moment it becomes Paid (trigger - covers the webhook and every other
-- path without redefining them): PR-000001, PR-000002, ... for live payments, TEST-PR-0001, ... for
-- test-mode payments (their own series, so testing never uses up real receipt numbers). Existing paid
-- payments are numbered in the order they were paid. The receipt page shows it as "Receipt #", and the
-- Xendit Payments page shows it on the Receipt link so staff can find the payment a customer quotes.
-- ExternalID stays as the internal Xendit reference (not shown to customers).
--
-- Run AFTER supabase_xendit_payment_receipt_page.sql. Safe to re-run. Needs js/xenditPayments.js ?v=xendit6.

create sequence if not exists public.xendit_receipt_no_seq;
create sequence if not exists public.xendit_test_receipt_no_seq;

alter table public."XenditPayments" add column if not exists "ReceiptNo" text;
create unique index if not exists "UX_XenditPayments_ReceiptNo" on public."XenditPayments" ("ReceiptNo");

create or replace function public._xendit_next_receipt_no(p_is_test boolean)
returns text
language sql
security definer
set search_path = public
as $$
  select case when p_is_test
              then 'TEST-PR-' || lpad(nextval('public.xendit_test_receipt_no_seq')::text, 4, '0')
              else 'PR-' || lpad(nextval('public.xendit_receipt_no_seq')::text, 6, '0') end;
$$;

revoke all on function public._xendit_next_receipt_no(boolean) from public, anon, authenticated;

create or replace function public._xendit_assign_receipt_no()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new."Status" = 'Paid' and new."ReceiptNo" is null then
    new."ReceiptNo" := public._xendit_next_receipt_no(new."IsTest");
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_XenditPayments_ReceiptNo" on public."XenditPayments";
create trigger "TR_XenditPayments_ReceiptNo"
  before insert or update of "Status" on public."XenditPayments"
  for each row execute function public._xendit_assign_receipt_no();

-- Number the payments already paid, oldest first.
do $$
declare
  p record;
begin
  for p in select "PaymentID", "IsTest" from public."XenditPayments"
            where "Status" = 'Paid' and "ReceiptNo" is null
            order by coalesce("PaidAtUtc", "CreatedAtUtc"), "CreatedAtUtc"
  loop
    update public."XenditPayments" set "ReceiptNo" = public._xendit_next_receipt_no(p."IsTest")
     where "PaymentID" = p."PaymentID";
  end loop;
end;
$$;

-- Receipt page: "Receipt #" is now ReceiptNo (same columns as before).
create or replace function public.public_get_xendit_payment_receipt(p_payment_id uuid)
returns table(receipt_no text, paid_at timestamptz, amount numeric, purpose text, paid_via text,
              xendit_reference text, is_test boolean, order_ref text, order_status text, customer_name text,
              order_total numeric, total_paid numeric, balance numeric, items jsonb)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  x public."XenditPayments"%rowtype;
  r record;
  v_items jsonb;
begin
  select * into x from public."XenditPayments" where "PaymentID" = p_payment_id and "Status" = 'Paid';
  if not found then
    return;
  end if;

  select * into r from public._xendit_resolve_order(x."OrderRef");

  if r.online_order_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(l."Description", l."ItemCode"), 'qty', l."Quantity",
                                                 'amount', coalesce(l."NetAmount", l."Quantity" * l."Price")) order by l."LineID"), '[]'::jsonb)
      into v_items from public."OnlineOrderLines" l where l."OrderID" = r.online_order_id;
  end if;
  if coalesce(jsonb_array_length(v_items), 0) = 0 and r.automated_order_no is not null then
    select coalesce(jsonb_agg(jsonb_build_object('name', l."ItemName", 'qty', l."Quantity",
                                                 'amount', l."Quantity" * l."Price") order by l."EntryNo"), '[]'::jsonb)
      into v_items from public."AutomatedOrderLines" l where l."OrderNo" = r.automated_order_no;
  end if;

  return query select
    coalesce(x."ReceiptNo", x."ExternalID"),
    coalesce(x."PaidAtUtc", x."CreatedAtUtc"),
    coalesce(x."PaidAmount", x."Amount"),
    x."Purpose",
    public._xendit_channel_label(x."PaymentChannel", x."PaymentMethod") || ' via Xendit',
    coalesce(x."XenditPaymentRef", x."InvoiceID"),
    x."IsTest",
    x."OrderRef",
    r.order_status,
    r.customer_name,
    r.total,
    r.amount_paid,
    r.balance,
    coalesce(v_items, '[]'::jsonb);
end;
$$;

grant execute on function public.public_get_xendit_payment_receipt(uuid) to anon;

-- Xendit Payments page: + receipt_no, and searchable by it (return type changes, so drop first).
drop function if exists public.admin_list_xendit_payments(text, text, text, int);

create or replace function public.admin_list_xendit_payments(p_admin_username text, p_admin_password text,
                                                            p_search text default null, p_limit int default 200)
returns table(payment_id uuid, created_at timestamptz, order_ref text, online_order_id text, purpose text,
              amount numeric, is_test boolean, status text, invoice_url text, expires_at timestamptz,
              create_error text, paid_amount numeric, payment_method text, payment_channel text, paid_at timestamptz,
              apply_status text, apply_error text, applied_in text, applied_amount numeric, external_id text,
              receipt_message_status text, receipt_no text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select x."PaymentID", x."CreatedAtUtc", x."OrderRef", x."OnlineOrderID", x."Purpose", x."Amount", x."IsTest",
           x."Status", x."InvoiceUrl", x."ExpiresAtUtc", x."CreateError", x."PaidAmount", x."PaymentMethod",
           x."PaymentChannel", x."PaidAtUtc", x."ApplyStatus", x."ApplyError", x."AppliedIn", x."AppliedAmount", x."ExternalID",
           x."ReceiptMessageStatus", x."ReceiptNo"
      from public."XenditPayments" x
     where v_search is null
        or x."OrderRef" ilike '%' || v_search || '%'
        or x."OnlineOrderID" ilike '%' || v_search || '%'
        or x."ExternalID" ilike '%' || v_search || '%'
        or x."ReceiptNo" ilike '%' || v_search || '%'
     order by x."CreatedAtUtc" desc
     limit greatest(coalesce(p_limit, 200), 1);
end;
$$;

grant execute on function public.admin_list_xendit_payments(text, text, text, int) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: every paid payment with its new receipt number.
select x."ReceiptNo" as receipt_no, x."OrderRef" as order_ref, x."Purpose" as purpose,
       x."PaidAmount" as amount, case when x."IsTest" then 'TEST' else 'Live' end as mode, x."PaidAtUtc" as paid_at
  from public."XenditPayments" x
 where x."Status" = 'Paid'
 order by x."PaidAtUtc";
