-- Lets the desktop POS pull item wholesale prices from the portal (SyncItemWholesalePricesFromSupabaseAsync
-- in OnlinefunctionsEvents.cs), fixing the first live try, which failed with:
--   401 {"code":"42501","message":"permission denied for table Items",
--        "hint":"Grant the required privileges to the current role with: GRANT SELECT ON public.\"Items\" TO anon;"}
--
-- The POS talks to Supabase with the anon/publishable key (GlobalSettings.TransferHeaderSupabaseApiKey), and
-- anon has no SELECT on public."Items" (RLS on, no policy, no grant - only the order/serial/transfer/expense
-- tables were opened to anon, e.g. supabase_allow_anon_order_sync.sql). Granting SELECT on the whole table
-- was rejected on purpose: that key is committed in this repo, so it would expose Cost and every other Items
-- column to anyone who reads the repo.
--
-- Instead this exposes ONE narrow read: Code + WholesalePrice, and only for items that have a wholesale price
-- (blank ones are not listed at all). It is a SECURITY DEFINER function, so no table privilege or RLS policy
-- changes are needed. Still: anyone holding the anon key can call it and read the wholesale prices - the same
-- trust tier as the other anon-open tables (see supabase_web_portal_rls_policies.sql). If wholesale prices
-- must be private from someone with the repo, this needs a real per-terminal secret instead.
--
-- Paged (p_limit/p_offset) because PostgREST caps a response at its max-rows setting (1000 by default).

drop function if exists public.pos_list_item_wholesale_prices(int, int);

create or replace function public.pos_list_item_wholesale_prices(
  p_limit int default 1000,
  p_offset int default 0
)
returns table(code text, wholesale_price numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select i."Code"::text, i."WholesalePrice"
  from public."Items" i
  where i."WholesalePrice" is not null
  order by i."Code"
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

revoke all on function public.pos_list_item_wholesale_prices(int, int) from public;
grant execute on function public.pos_list_item_wholesale_prices(int, int) to anon;
