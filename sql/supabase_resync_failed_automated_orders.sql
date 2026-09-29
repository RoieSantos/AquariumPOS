-- Bulk "Retry Push to Pancake" for every Automated Order (GMA Conversations / Order Now / bot) stuck as
-- PancakeSyncStatus = 'Failed' - per "is there a way we can resync all the orders?", instead of pressing
-- Retry on each one.
--
-- DUPLICATE SAFETY: an order is only auto-retried when its last error happened BEFORE anything was sent
-- to Pancake (no line matched / partial match / no warehouse) or Pancake explicitly rejected it (HTTP
-- 4xx/5xx) - in both cases no Pancake order exists, so a retry can't create a second one. Any other
-- error (e.g. a network timeout mid-call, where Pancake may have created the order but we never saw the
-- reply) is listed in step 2 as 'CHECK PANCAKE FIRST' and skipped - search Pancake for "Web order
-- AO-xxxxx" before pressing Retry on those by hand.
--
-- Run in the Supabase SQL editor, in order:
--   0. supabase_fix_gma_custom_aquarium_lines.sql step 3 first (repairs GMA Custom Aquarium/Stand lines
--      saved the old way - otherwise those orders just fail again with "1 of 2 lines matched").
--   1. Create the functions (once).  2. Preview.  3. Run - repeat until it returns no rows.

-- ---------------------------------------------------------------------------
-- 1. CREATE (run once).

create or replace function public._automated_order_safe_to_retry(p_error text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_error, '') ~* (
    'matched a known Pancake product'           -- "None of ..." / "N of M ... refusing a partial push" (pre-send)
    || '|No Warehouses row matches'             -- pre-send
    || '|AutomatedOrders row .* not found'      -- pre-send
    || '|Pancake order creation failed \(HTTP'  -- Pancake answered with an error, so no order was created
  );
$$;

-- True when every line on the order maps to a Pancake product - same match _push_automated_order_to_pancake
-- uses (supabase_gma_conversation_order_line_variant_selection.sql). False = the push would fail again.
create or replace function public._automated_order_lines_all_matched(p_order_no text)
returns boolean
language sql
stable
as $$
  select not exists (
    select 1 from public."AutomatedOrderLines" l
    where l."OrderNo" = p_order_no
      and not exists (
        select 1 from public."Items" i
        where (i."Code" = coalesce(nullif(l."ItemCode", ''), nullif(l."CategoryCode", ''))
               or (l."ItemCode" is null and i."Name" = nullif(l."CategoryCode", '')))
          and (i."VariationId" is not null or i."ProductId" is not null)));
$$;

-- Retries up to p_limit Failed orders (oldest first) and returns each one's new status. Kept small per
-- run so one call stays well inside its time limit even if Pancake is slow (each push can take up to
-- ~60s worst case, normally a few seconds) - just run it again for the next batch.
create or replace function public.admin_resync_failed_automated_orders(p_limit int default 10)
returns table(order_no text, new_status text, error text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '600000'
as $$
declare
  v_order_no text;
begin
  for v_order_no in
    select o."OrderNo" from public."AutomatedOrders" o
    where o."PancakeSyncStatus" = 'Failed'
      and public._automated_order_safe_to_retry(o."PancakeSyncError")
      and public._automated_order_lines_all_matched(o."OrderNo")
      -- Not tried in the last 10 minutes (the push stamps PancakeLastAttemptAtUtc), so an order that
      -- fails again isn't re-picked on every run and "repeat until no rows" actually finishes.
      and coalesce(o."PancakeLastAttemptAtUtc", '-infinity') < now() - interval '10 minutes'
    order by o."OrderNo"
    limit least(greatest(coalesce(p_limit, 10), 1), 25)
  loop
    perform public._push_automated_order_to_pancake(v_order_no); -- never raises; records Synced/Failed itself
    return query
      select o."OrderNo"::text, o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
      from public."AutomatedOrders" o where o."OrderNo" = v_order_no;
  end loop;
end;
$$;

-- Pushes to Pancake with the live API key - SQL editor / admins only, never the anon website role.
revoke execute on function public.admin_resync_failed_automated_orders(int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. PREVIEW: every Failed order and what step 3 will do with it.
select o."OrderNo", o."CreatedAtUtc", o."CustomerName", o."PancakeSyncError",
       case
         when not public._automated_order_safe_to_retry(o."PancakeSyncError") then 'CHECK PANCAKE FIRST'
         when not public._automated_order_lines_all_matched(o."OrderNo") then 'SKIP - a line has no Pancake product'
         else 'auto-retry'
       end as action
from public."AutomatedOrders" o
where o."PancakeSyncStatus" = 'Failed'
order by o."OrderNo";

-- ---------------------------------------------------------------------------
-- 3. RUN: repeat until it returns no rows. Anything that comes back 'Failed' again is left alone for 10
--    minutes - check its error in step 2 (usually an item that still isn't mapped to a Pancake product).
select * from public.admin_resync_failed_automated_orders(10);
