-- Stop the desktop POS putting back order lines that were removed in Pancake - per "when we are trying
-- to click Ready to Ship the serials asked vs the actual qty of the order is not match" (order 105852:
-- one STANDARD-10G x2 in Pancake, but OnlineOrderLines had TWO AQ-030 x2 rows - LineIDs 11664251580 and
-- 12586148285 - so Select Serials to Ship asked for 2 + 2).
--
-- CAUSE: when an order's items are edited in Pancake the line can get a new LineID. The Pancake syncs
-- here remove the old line (supabase_online_order_sync_edited_lines.sql, _open_refresh_lines.sql,
-- _sync_no_long_locks.sql), but the POS never removes it from its own dbo.OnlineOrderLines - it only
-- updates/inserts by LineID - and SyncOnlineOrdersToSupabaseAsync (OnlinefunctionsEvents.cs) POSTs every
-- local line that's missing in Supabase on every master-data tick. So the old line came straight back.
-- (The order card's Lines grid reads Pancake live, which is why it showed one line.)
-- Stale lines also feed everything else that reads OnlineOrderLines - stock check, Assign roles, the
-- Item Ledger sale posting.
--
-- FIX (no POS rebuild):
--   1. OnlineOrderLinesRemoved remembers each (OrderID, LineID) the syncs delete.
--   2. An insert of a remembered line by the POS (the "anon" role - it writes with the publishable key)
--      is silently skipped. The Pancake syncs and staff RPCs run as the function owner, so if Pancake
--      ever really brings a line back it is still saved - and that clears the memory for it.
--   The POS's own SET-material lines (LineID "...~SETMAT~NN", OnlineOrdersForm.cs) are left out -
--   unchanged behaviour for them.
-- Stale lines already in the table are removed by the syncs' next pass over the order (the open-order
-- refresh rotates through every open order) and then stay removed. Step 4 queues order 105852 now.
--
-- Supersedes supabase_online_order_serial_lines_dedupe.sql's diagnosis (Items had only one AQ-030 row);
-- that file's one-Items-row-per-line change is harmless and can stay.
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Removed lines.
create table if not exists public."OnlineOrderLinesRemoved" (
  "OrderID" text not null,
  "LineID" text not null,
  "RemovedAtUtc" timestamptz not null default now(),
  primary key ("OrderID", "LineID")
);

alter table public."OnlineOrderLinesRemoved" enable row level security;
revoke all on public."OnlineOrderLinesRemoved" from anon, authenticated;

create or replace function public._remember_removed_online_order_line()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD."LineID" is not null and OLD."LineID" not like '%~SETMAT~%' then
    insert into public."OnlineOrderLinesRemoved" ("OrderID", "LineID")
    values (OLD."OrderID", OLD."LineID")
    on conflict ("OrderID", "LineID") do update set "RemovedAtUtc" = now();
  end if;
  return OLD;
end;
$$;

drop trigger if exists trg_remember_removed_online_order_line on public."OnlineOrderLines";
create trigger trg_remember_removed_online_order_line
  after delete on public."OnlineOrderLines"
  for each row
  execute function public._remember_removed_online_order_line();

-- ---------------------------------------------------------------------------
-- 2. Was this line removed? (The insert trigger below runs as the caller, so the lookup is a definer
--    helper - the table itself stays closed to anon.)
create or replace function public._online_order_line_was_removed(p_order_id text, p_line_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public."OnlineOrderLinesRemoved" r
    where r."OrderID" = p_order_id and r."LineID" = p_line_id
  );
$$;

revoke all on function public._online_order_line_was_removed(text, text) from public;
grant execute on function public._online_order_line_was_removed(text, text) to anon;

-- Clears the memory when a line is legitimately saved again (owner-run sync / RPC).
create or replace function public._forget_removed_online_order_line(p_order_id text, p_line_id text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public."OnlineOrderLinesRemoved" where "OrderID" = p_order_id and "LineID" = p_line_id;
$$;

revoke all on function public._forget_removed_online_order_line(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The gate. SECURITY INVOKER on purpose: current_user is 'anon' for the POS's direct REST insert,
--    and the function owner for the Pancake syncs / staff RPCs (security definer).
create or replace function public._skip_resurrected_online_order_line()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if NEW."LineID" is null or NEW."LineID" like '%~SETMAT~%' then
    return NEW;
  end if;

  if current_user = 'anon' then
    if public._online_order_line_was_removed(NEW."OrderID", NEW."LineID") then
      return null; -- removed in Pancake - don't let the POS put it back
    end if;
    return NEW;
  end if;

  perform public._forget_removed_online_order_line(NEW."OrderID", NEW."LineID");
  return NEW;
end;
$$;

drop trigger if exists trg_skip_resurrected_online_order_line on public."OnlineOrderLines";
create trigger trg_skip_resurrected_online_order_line
  before insert on public."OnlineOrderLines"
  for each row
  execute function public._skip_resurrected_online_order_line();

-- ---------------------------------------------------------------------------
-- 4. Order 105852: have the syncs re-read it on their next run (removes the stale line, which is then
--    remembered). Touches only the check timestamps.
update public."OnlineOrders"
set "GlassThicknessCheckedAt" = null, "NotePrintCheckedAt" = null
where "OrderID" = '105852';

-- ---------------------------------------------------------------------------
-- 5. Check (run again after a couple of minutes): 105852 should be down to one line, and the removed
--    LineID listed in OnlineOrderLinesRemoved.
select 'line' as kind, l."LineID", l."ItemCode", l."Quantity", l."SyncedAtUtc" as at_utc
from public."OnlineOrderLines" l where l."OrderID" = '105852'
union all
select 'removed', r."LineID", null, null, r."RemovedAtUtc"
from public."OnlineOrderLinesRemoved" r where r."OrderID" = '105852'
order by 1, 2;
