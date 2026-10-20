-- Disk IO budget fix: skip "updates" that change nothing.
--
-- supabase_diagnose_disk_io.sql showed the IO is almost all WRITES from syncs that rewrite every row on
-- every run even when nothing changed - only "SyncedAtUtc" moves:
--   cron_sync_items_from_pancake (Items + Variants, every 5 min)        ~6.3 GB dirtied / 16 days
--   cron_sync_online_customers_from_pancake (every 5 min)               ~4.8 GB
--   POS 5-minute push of EVERY advance order header/line (each PC)      ~1.1 GB, 2.4M line PATCHes
--   POS online-order line push (older POS builds) / detail sync         ~1.4 GB, 1.26M line PATCHes
-- Each such update writes a whole new row version + index entries + WAL, needs vacuuming later, and
-- fires the AFTER triggers (e.g. the item ledger re-reconciling an advance order on every POS push).
--
-- Fix: one BEFORE UPDATE trigger per table that cancels the update (returns null) when the row is
-- identical apart from "SyncedAtUtc". Callers see success as usual (PostgREST still answers 2xx; the
-- row just isn't rewritten). Real changes go through exactly as before.
--
-- Named "zz_..." so it runs AFTER the tables' other BEFORE triggers (Postgres fires them in name
-- order) and compares the final row - e.g. after TR_AdvanceOrderLines_VariantOverride has put the
-- portal's variant back.
--
-- NOT applied to "OnlineOrders": its open-order rotation picks the oldest "SyncedAtUtc" next, so that
-- timestamp must keep moving there. "OnlineOrderPayments" is delete + re-insert, not update, so this
-- doesn't cover it either.
--
-- Trade-off: on these tables "SyncedAtUtc" now means "last time the data actually changed", not "last
-- time a sync touched it".
--
-- Safe to re-run. Ends with one check result: which tables have the trigger.

create or replace function public._skip_noop_sync_update()
returns trigger
language plpgsql
as $$
begin
  if (to_jsonb(new) - 'SyncedAtUtc') = (to_jsonb(old) - 'SyncedAtUtc') then
    return null; -- nothing but the sync timestamp changed: skip the write
  end if;
  return new;
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'Items', 'Variants', 'OnlineCustomers',
    'AdvanceOrders', 'AdvanceOrderLines', 'AdvanceOrderPayments',
    'OnlineOrderLines'
  ] loop
    if to_regclass(format('public.%I', v_table)) is not null then
      execute format('drop trigger if exists zz_skip_noop_sync_update on public.%I', v_table);
      execute format(
        'create trigger zz_skip_noop_sync_update before update on public.%I '
        'for each row execute function public._skip_noop_sync_update()', v_table);
    end if;
  end loop;
end;
$$;

select c.relname as table_name,
       case when t.tgname is null then 'MISSING' else 'installed' end as skip_noop_trigger
from pg_class c
join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
left join pg_trigger t on t.tgrelid = c.oid and t.tgname = 'zz_skip_noop_sync_update'
where c.relname in ('Items', 'Variants', 'OnlineCustomers', 'AdvanceOrders', 'AdvanceOrderLines',
                    'AdvanceOrderPayments', 'OnlineOrderLines')
  and c.relkind = 'r'
order by 1;
