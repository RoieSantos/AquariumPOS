-- Edit / delete a payment on a portal order (AO-xxxxx), New or Confirmed - per "can we also let the user
-- to modify the payment in the order even though its new and confirmed".
--
-- AutomatedOrderPayments (supabase_gma_conversation_orders.sql) only had Add (admin_add_automated_order_payment),
-- so a wrong / doubled payment (e.g. AO-00048: Paid 16,600 on an 8,300 order) couldn't be fixed. This adds:
--   * admin_update_automated_order_payment - change a payment's amount / method / reference,
--   * admin_delete_automated_order_payment - remove a payment,
-- for orders that never went to Pancake: New (PancakeSyncStatus 'Not Pushed') and confirmed portal orders
-- ('Portal') that are still open (not Shipped / Delivered / Completed / Cancelled / Returned). An old Pancake
-- order's payments were also written to Pancake's bank_payments, so editing only the portal copy would put
-- the two out of step - those are refused.
-- A confirmed order's Online Orders Amount Paid / Balance are recomputed from the payments (the same sum
-- admin_add_automated_order_payment uses). Every edit / delete is logged in AutomatedOrderPaymentChanges
-- (old + new values, who, when) - money changes shouldn't vanish without a trace.
--
-- New table + 3 functions. Run AFTER supabase_bot_orders_portal_confirm.sql. Safe to re-run.
-- Needs js/onlineNewOrders.js ?v=pay1, js/onlineOrders.js ?v=pay1.

create table if not exists public."AutomatedOrderPaymentChanges" (
  "ChangeId" bigint generated always as identity primary key,
  "PaymentId" bigint not null,
  "OrderNo" varchar(50) not null,
  "Action" varchar(10) not null,             -- 'Edit' / 'Delete'
  "OldAmount" numeric(18, 4),
  "OldMethod" varchar(30),
  "OldReference" varchar(200),
  "NewAmount" numeric(18, 4),
  "NewMethod" varchar(30),
  "NewReference" varchar(200),
  "ChangedBy" varchar(100),
  "ChangedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_AutomatedOrderPaymentChanges_OrderNo" on public."AutomatedOrderPaymentChanges" ("OrderNo");

alter table public."AutomatedOrderPaymentChanges" enable row level security;
revoke all on public."AutomatedOrderPaymentChanges" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Shared: can this order's payments be changed? Locks + returns the AutomatedOrders row's OrderNo.

create or replace function public._ao_payment_editable_order(p_payment_id bigint)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
  v_order public."AutomatedOrders"%rowtype;
  v_online_status text;
begin
  select "OrderNo" into v_order_no from public."AutomatedOrderPayments" where "PaymentId" = p_payment_id;
  if v_order_no is null then
    raise exception 'Payment % not found.', p_payment_id;
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = v_order_no for update;
  if v_order."Status" in ('Cancelled', 'Completed') then
    raise exception 'Order % is %, its payments can no longer be changed.', v_order_no, v_order."Status";
  end if;
  if coalesce(v_order."PancakeSyncStatus", '') not in ('Not Pushed', 'Portal') then
    raise exception 'Order % is a Pancake order - its payments are also in Pancake, fix them there.', v_order_no;
  end if;
  if v_order."PancakeSyncStatus" = 'Portal' then
    select lower(trim(coalesce("Status", ''))) into v_online_status from public."OnlineOrders" where "OrderID" = v_order_no;
    if v_online_status in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning') then
      raise exception 'Order % is %, its payments can no longer be changed.', v_order_no, v_online_status;
    end if;
  end if;
  return v_order_no;
end;
$$;

revoke all on function public._ao_payment_editable_order(bigint) from public, anon, authenticated;

-- Confirmed portal order: Amount Paid / Balance from the payments (same as admin_add_automated_order_payment).
create or replace function public._ao_refresh_portal_order_paid(p_order_no text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  update public."OnlineOrders" o
  set "AmountPaid" = coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = p_order_no), 0),
      "Balance" = coalesce(o."MoneyToCollect", 0)
                  - coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = p_order_no), 0),
      "Last_Updated_At" = now()
  where o."OrderID" = p_order_no and o."Source" = 'Portal';
$$;

revoke all on function public._ao_refresh_portal_order_paid(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Edit a payment

drop function if exists public.admin_update_automated_order_payment(text, text, bigint, numeric, text, text);

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
set lock_timeout = '10000'
as $$
declare
  v_order_no text;
  v_old public."AutomatedOrderPayments"%rowtype;
  v_method text := coalesce(nullif(trim(p_method), ''), 'Cash');
  v_reference text := nullif(trim(coalesce(p_reference, '')), '');
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'Amount is required.';
  end if;

  v_order_no := public._ao_payment_editable_order(p_payment_id);
  select * into v_old from public."AutomatedOrderPayments" where "PaymentId" = p_payment_id;

  update public."AutomatedOrderPayments"
  set "Amount" = p_amount, "Method" = v_method, "Reference" = v_reference
  where "PaymentId" = p_payment_id;

  insert into public."AutomatedOrderPaymentChanges"
    ("PaymentId", "OrderNo", "Action", "OldAmount", "OldMethod", "OldReference", "NewAmount", "NewMethod", "NewReference", "ChangedBy")
  values
    (p_payment_id, v_order_no, 'Edit', v_old."Amount", v_old."Method", v_old."Reference", p_amount, v_method, v_reference, p_admin_username);

  perform public._ao_refresh_portal_order_paid(v_order_no);
end;
$$;

grant execute on function public.admin_update_automated_order_payment(text, text, bigint, numeric, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Delete a payment

drop function if exists public.admin_delete_automated_order_payment(text, text, bigint);

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
set lock_timeout = '10000'
as $$
declare
  v_order_no text;
  v_old public."AutomatedOrderPayments"%rowtype;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_order_no := public._ao_payment_editable_order(p_payment_id);
  select * into v_old from public."AutomatedOrderPayments" where "PaymentId" = p_payment_id;

  delete from public."AutomatedOrderPayments" where "PaymentId" = p_payment_id;

  insert into public."AutomatedOrderPaymentChanges"
    ("PaymentId", "OrderNo", "Action", "OldAmount", "OldMethod", "OldReference", "ChangedBy")
  values
    (p_payment_id, v_order_no, 'Delete', v_old."Amount", v_old."Method", v_old."Reference", p_admin_username);

  perform public._ao_refresh_portal_order_paid(v_order_no);
end;
$$;

grant execute on function public.admin_delete_automated_order_payment(text, text, bigint) to anon;

notify pgrst, 'reload schema';
