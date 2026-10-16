-- One-off, per "move this online order id to last month": orders 117795, 117796, 117800-117804 get
-- "Date" = 2026-09-30 (last day of last month; "Time" unchanged).
--
-- The Pancake sync's upsert overwrites "Date" every time, so a plain UPDATE would be undone on the
-- next sync. Instead the date goes into OnlineOrderDateOverrides and a BEFORE INSERT/UPDATE trigger
-- keeps it on every write (same pattern as TRG_OnlineOrders_KeepDelivered).
-- Changing "Date" re-queues the order for the Item Ledger (TR_OnlineOrders_ItemLedgerQueue), so its
-- stock entries follow the new date on the next ledger run.
--
-- To move another order later: insert its OrderID + date into OnlineOrderDateOverrides and touch the
-- order (update ... set "Date" = <date>). To undo one: delete its override row - the next Pancake sync
-- puts the original date back.
-- Safe to re-run. Ends with one result: each order, its old and new date.

-- 1. Override table (portal-only; no RLS policies = only definer functions / service role can read it).
create table if not exists public."OnlineOrderDateOverrides" (
  "OrderID"      text primary key,
  "Date"         date not null,
  "Reason"       text,
  "CreatedAtUtc" timestamptz not null default now()
);
alter table public."OnlineOrderDateOverrides" enable row level security;

-- 2. Trigger: any write to an overridden order keeps the override date.
create or replace function public._online_orders_keep_date_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date;
begin
  select d."Date" into v_date from public."OnlineOrderDateOverrides" d where d."OrderID" = new."OrderID"::text;
  if found then
    new."Date" := v_date;
  end if;
  return new;
end;
$$;

revoke execute on function public._online_orders_keep_date_override() from public, anon, authenticated;

drop trigger if exists "TRG_OnlineOrders_KeepDateOverride" on public."OnlineOrders";
create trigger "TRG_OnlineOrders_KeepDateOverride"
  before insert or update on public."OnlineOrders"
  for each row execute function public._online_orders_keep_date_override();

-- 3. The orders to move.
drop table if exists _move_orders;
create temp table _move_orders as
select o."OrderID"::text as order_id, o."Date" as old_date
from public."OnlineOrders" o
where o."OrderID"::text in ('117795', '117796', '117800', '117801', '117802', '117803', '117804');

insert into public."OnlineOrderDateOverrides" ("OrderID", "Date", "Reason")
select order_id, date '2026-09-30', 'moved to last month (manual request 2026-10-16)' from _move_orders
on conflict ("OrderID") do update set "Date" = excluded."Date", "Reason" = excluded."Reason";

update public."OnlineOrders" o
   set "Date" = date '2026-09-30'
 where o."OrderID"::text in (select order_id from _move_orders);

-- 4. Result.
select m.order_id, m.old_date, o."Date" as new_date, o."Status", o."CustomerName"
from _move_orders m
join public."OnlineOrders" o on o."OrderID"::text = m.order_id
union all
select '(not found)', null, null, null, x.id
from unnest(array['117795', '117796', '117800', '117801', '117802', '117803', '117804']) x(id)
where x.id not in (select order_id from _move_orders)
order by 1;
