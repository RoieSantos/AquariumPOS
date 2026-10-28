-- Public "Best Sellers" for the customer website (docs/index.html) - per "in the website can you
-- show our best seller and promotion on going".
--
-- Same ranking as the staff Top Selling Items report (admin_get_top_selling_items in
-- supabase_top_selling_items_rpc.sql): qty sold from OnlineOrderLines + OnlineOrders over a date
-- range, cancelled orders left out. Differences, since this is called with no login:
--   * Only the RANK is exposed - no qty sold, revenue or order counts (sales figures stay staff-only).
--   * Only items a customer can actually see: active, not HideFromSet, priced > 0 and with a photo
--     (same filters landing.js already applies to "From Our Shelves").
--   * Window is the last p_days days (default 90), capped at 365; limit capped at 24.
--   * SETs are left out - they have their own ranking, public_get_best_selling_sets (below).
--   * Also returns the item Description, for the product popup a customer sees on clicking a card.
--
-- public_get_best_selling_sets - "Best-Selling Complete Sets" on the website, per "can you show best
-- sellers complete set". Ranks only aquarium sets. Older set sales were recorded under the retired
-- Pancake AS-xxx items (now HideFromSet), newer ones under the portal SET-xxx codes
-- (supabase_aquarium_sets_portal_owned.sql) - every SET-category line is resolved to its Customer
-- Aquarium package with _resolve_set_package (same as set explosion), so both count toward the
-- package's current SET-xxx item. Only packages sold online (Items row active, not hidden, priced).
-- A photo is NOT required here (sets often have none yet) - the website shows a placeholder.
-- Unlike the item list, sets DO return qty_sold (sets sold in the window, shown as "N sold" on the
-- card) - per "can you show the total set sold".
--
-- Run AFTER supabase_aquarium_sets_portal_owned.sql. Safe to re-run.

drop function if exists public.public_get_best_sellers(int, int);

create or replace function public.public_get_best_sellers(p_days int default 90, p_limit int default 8)
returns table(code text, name text, category_code text, price numeric, images text, rank int, description text)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with sold as (
    select l."ItemCode" as item_code, sum(l."Quantity") as qty
    from public."OnlineOrderLines" l
    join public."OnlineOrders" o on o."OrderID" = l."OrderID"
    where l."ItemCode" is not null
      and o."Date" >= (now() at time zone 'Asia/Manila')::date - least(greatest(coalesce(p_days, 90), 7), 365)
      and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled')
    group by l."ItemCode"
    having sum(l."Quantity") > 0
  )
  select
    i."Code"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text,
    upper(trim(coalesce(i."CategoryCode", '')))::text,
    coalesce(i."RetailPrice", i."Price", 0)::numeric,
    i."Images"::text,
    (row_number() over (order by s.qty desc, i."Code"))::int,
    i."Description"::text
  from sold s
  join public."Items" i on i."Code" = s.item_code
  where i."IsActive" is true
    and i."HideFromSet" is not true
    and upper(trim(coalesce(i."CategoryCode", ''))) <> 'SET'
    and coalesce(i."RetailPrice", i."Price", 0) > 0
    and nullif(trim(coalesce(i."Images", '')), '') is not null
  order by s.qty desc, i."Code"
  limit least(greatest(coalesce(p_limit, 8), 1), 24);
$$;

grant execute on function public.public_get_best_sellers(int, int) to anon;

drop function if exists public.public_get_best_selling_sets(int, int);

create or replace function public.public_get_best_selling_sets(p_days int default 365, p_limit int default 6)
returns table(code text, name text, description text, price numeric, images text, rank int, qty_sold int)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with set_lines as (
    select public._resolve_set_package(coalesce(nullif(l."VariationId", ''), si."VariationId"), l."ItemCode") as package_name,
           l."Quantity" as qty
    from public."OnlineOrderLines" l
    join public."OnlineOrders" o on o."OrderID" = l."OrderID"
    join public."Items" si on si."Code" = l."ItemCode"
    where upper(trim(coalesce(si."CategoryCode", ''))) = 'SET'
      and o."Date" >= (now() at time zone 'Asia/Manila')::date - least(greatest(coalesce(p_days, 365), 7), 730)
      and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled')
  ),
  sold as (
    select h."SetCode" as set_code, sum(sl.qty) as qty
    from set_lines sl
    join public."CompleteAquariumSetHeader" h on h."PackageName" = sl.package_name
    where nullif(trim(h."SetCode"), '') is not null
    group by h."SetCode"
    having sum(sl.qty) > 0
  )
  select
    i."Code"::text,
    coalesce(nullif(trim(i."Name"), ''), i."Code")::text,
    i."Description"::text,
    coalesce(i."RetailPrice", i."Price", 0)::numeric,
    i."Images"::text,
    (row_number() over (order by s.qty desc, i."Code"))::int,
    round(s.qty)::int
  from sold s
  join public."Items" i on i."Code" = s.set_code
  where i."IsActive" is true
    and i."HideFromSet" is not true
    and coalesce(i."RetailPrice", i."Price", 0) > 0
  order by s.qty desc, i."Code"
  limit least(greatest(coalesce(p_limit, 6), 1), 24);
$$;

grant execute on function public.public_get_best_selling_sets(int, int) to anon;

notify pgrst, 'reload schema';

-- Check: what the website will show (both lists in one result).
select 'best sellers (90 days)' as section, rank, code, name, category_code, price, null::int as qty_sold
from public.public_get_best_sellers(90, 8)
union all
select 'complete sets (365 days)', rank, code, name, 'SET', price, qty_sold
from public.public_get_best_selling_sets(365, 6)
order by 1, 2;
