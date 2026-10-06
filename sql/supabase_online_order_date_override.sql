-- Portal-only order date override - per "walkin order 111233 i want to change the date from today to
-- yesterday ... we can change this on the portal only for now" (today's sales were showing it).
--
-- Why a column + trigger instead of a plain update: OnlineOrders."Date" is Pancake's created-at
-- (Manila date), and every Pancake sync upsert does "Date" = excluded."Date" - a plain update would
-- flip back to today on the next sync of that order. Pancake itself can't change created-at.
--
-- "DateOverride" is portal-only (no sync writes it). While it's set, the trigger below forces "Date"
-- to it on every insert/update, so the sync can't undo it - and since every dashboard / sales
-- report already reads "Date", nothing else needs changing. Clear it (set null) and the next sync
-- puts Pancake's own date back.
--
-- Not moved: Item Ledger Entries (append-only - posting date stays the day it was punched),
-- LastPaid_Date (not used by the dashboard/sales totals), and Pancake / the POS themselves.
--
-- Safe to re-run. Adds a nullable column (brief lock - if it times out waiting for the sync, run again).

begin;
set local lock_timeout = '30s';

alter table public."OnlineOrders" add column if not exists "DateOverride" date;

create or replace function public._online_order_apply_date_override()
returns trigger
language plpgsql
as $$
begin
  if new."DateOverride" is not null then
    new."Date" := new."DateOverride";
  end if;
  return new;
end;
$$;

drop trigger if exists trg_online_orders_date_override on public."OnlineOrders";
create trigger trg_online_orders_date_override
  before insert or update on public."OnlineOrders"
  for each row execute function public._online_order_apply_date_override();

-- Walk-in 111233: punched 2026-10-06, belongs to 2026-10-05.
update public."OnlineOrders"
set "DateOverride" = date '2026-10-05'
where "OrderID" = '111233';

commit;

select "OrderID", "Date", "DateOverride", "Time", "Status", "CustomerName", "MoneyToCollect", "AmountPaid"
from public."OnlineOrders"
where "OrderID" = '111233';
