-- Payment change history on portal orders (AO-xxxxx) - per "can you put a history who change the payments?".
--
-- AutomatedOrderPaymentChanges (supabase_ao_order_payment_edit.sql) already logs every Edit / Delete, but
-- nothing showed it, and Adds weren't logged at all (a deleted payment lost who first recorded it). This:
--   * logs every new AutomatedOrderPayments row as an 'Add' (trigger - covers every insert path: staff Add
--     payment / Settle balance, POS online pay, GMA conversation payments, without redefining those RPCs),
--   * backfills an 'Add' row for payments recorded before this ran (skips ones already logged),
--   * admin_list_automated_order_payment_changes - the order's history, newest first, for the Payments
--     "History" toggle (js/onlineNewOrders.js) on the New dialog and the Online Orders card.
--
-- Run AFTER supabase_ao_order_payment_edit.sql. Safe to re-run.
-- Needs online-orders.html with js/onlineNewOrders.js ?v=payhist1.

-- ---------------------------------------------------------------------------
-- 1. Log every new payment as an 'Add'

create or replace function public._ao_payment_log_add()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into public."AutomatedOrderPaymentChanges"
    ("PaymentId", "OrderNo", "Action", "NewAmount", "NewMethod", "NewReference", "ChangedBy", "ChangedAtUtc")
  values
    (new."PaymentId", new."OrderNo", 'Add', new."Amount", new."Method", new."Reference", new."RecordedBy", new."RecordedAtUtc");
  return new;
end;
$$;

revoke all on function public._ao_payment_log_add() from public, anon, authenticated;

drop trigger if exists "TR_AutomatedOrderPayments_LogAdd" on public."AutomatedOrderPayments";
create trigger "TR_AutomatedOrderPayments_LogAdd"
  after insert on public."AutomatedOrderPayments"
  for each row execute function public._ao_payment_log_add();

-- ---------------------------------------------------------------------------
-- 2. Backfill: payments that already exist. Their current values are the best record left - a payment that
-- was edited since shows its edited values here, the Edit row still holds the original.

insert into public."AutomatedOrderPaymentChanges"
  ("PaymentId", "OrderNo", "Action", "NewAmount", "NewMethod", "NewReference", "ChangedBy", "ChangedAtUtc")
select p."PaymentId", p."OrderNo", 'Add',
       coalesce(e."OldAmount", p."Amount"), coalesce(e."OldMethod", p."Method"),
       case when e."ChangeId" is null then p."Reference" else e."OldReference" end,
       p."RecordedBy", p."RecordedAtUtc"
from public."AutomatedOrderPayments" p
-- the first Edit's Old* values are what was originally added
left join lateral (
  select c."ChangeId", c."OldAmount", c."OldMethod", c."OldReference"
  from public."AutomatedOrderPaymentChanges" c
  where c."PaymentId" = p."PaymentId" and c."Action" = 'Edit'
  order by c."ChangedAtUtc", c."ChangeId"
  limit 1
) e on true
where not exists (
  select 1 from public."AutomatedOrderPaymentChanges" c where c."PaymentId" = p."PaymentId" and c."Action" = 'Add'
);

-- ---------------------------------------------------------------------------
-- 3. Read an order's payment history

drop function if exists public.admin_list_automated_order_payment_changes(text, text, text);

create or replace function public.admin_list_automated_order_payment_changes(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(
  change_id bigint, payment_id bigint, action text,
  old_amount numeric, old_method text, old_reference text,
  new_amount numeric, new_method text, new_reference text,
  changed_by text, changed_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select c."ChangeId", c."PaymentId", c."Action"::text,
           c."OldAmount", c."OldMethod"::text, c."OldReference"::text,
           c."NewAmount", c."NewMethod"::text, c."NewReference"::text,
           c."ChangedBy"::text, c."ChangedAtUtc"
    from public."AutomatedOrderPaymentChanges" c
    where c."OrderNo" = p_order_no
    order by c."ChangedAtUtc" desc, c."ChangeId" desc;
end;
$$;

grant execute on function public.admin_list_automated_order_payment_changes(text, text, text) to anon;

notify pgrst, 'reload schema';
