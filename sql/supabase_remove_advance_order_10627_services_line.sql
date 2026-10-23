-- Remove the stray "SERVICES - Product for - 1" line (qty 100, 0.00) from advance order
-- 10627 / RS-0000011380 (AARON JOAQUIN), per "remove the item services line" - portal side only.
--
-- The POS still has the line locally, and its 5-minute bulk sync (SyncAdvanceOrdersToSupabaseAsync)
-- re-sends EVERY local AdvanceOrderLines row: it checks if TransactionNo+LineNo exists and inserts
-- it if not. So a plain delete would come back. AdvanceOrderLineSkips lists POS lines the portal
-- ignores; a BEFORE INSERT trigger drops any insert matching one (the POS gets a normal success, so
-- the order is not marked SYNC_FAILED). To hide another junk line later, just add a row to the table.
--
-- Guarded: only a 0-amount ITEM line whose No. is SERVICES on this transaction. Safe to re-run.

create table if not exists public."AdvanceOrderLineSkips" (
  "TransactionNo" text not null,
  "No" text not null,
  "Reason" text,
  "CreatedAtUtc" timestamptz not null default now(),
  primary key ("TransactionNo", "No")
);
alter table public."AdvanceOrderLineSkips" enable row level security;   -- no policies: not readable via the API

create or replace function public._advance_order_line_skip()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public."AdvanceOrderLineSkips" s
    where s."TransactionNo" = trim(new."TransactionNo")
      and upper(s."No") = upper(trim(coalesce(new."No", '')))
  ) and coalesce(new."NetAmount", 0) = 0 then
    return null;   -- skip the insert
  end if;
  return new;
end;
$$;

drop trigger if exists trg_advance_order_line_skip on public."AdvanceOrderLines";
create trigger trg_advance_order_line_skip
before insert on public."AdvanceOrderLines"
for each row execute function public._advance_order_line_skip();

insert into public."AdvanceOrderLineSkips" ("TransactionNo", "No", "Reason")
values ('10627', 'SERVICES', 'Stray 0.00 SERVICES line (qty 100) on RS-0000011380')
on conflict do nothing;

delete from public."AdvanceOrderLines"
where "TransactionNo" = '10627'
  and upper(trim("Type")) = 'ITEM'
  and upper(trim("No")) = 'SERVICES'
  and coalesce("NetAmount", 0) = 0;

-- Result: remaining lines for the order (SERVICES should be gone, CASH payment line kept).
select "LineNo", "Type", "No", "Description", "Quantity", "Price", "NetAmount"
from public."AdvanceOrderLines"
where "TransactionNo" = '10627'
order by case when "LineNo" ~ '^\d+$' then "LineNo"::numeric end nulls last, "LineNo";
