-- Bot orders at wholesale pricing - per "once the customer orders in the conversations can we
-- automatically convert the order to apply wholesale price? with minimum price?".
--
-- Before: create_order (Alice / Vic) always recorded the retail price, so a wholesale order was
-- escalated to staff to key in by hand.
--
-- Now create_order / modify_order take pricing = 'wholesale': the Edge Function (buildBotOrderLines in
-- supabase/functions/_shared/chatbot-engine.ts) prices each line whose category is IsWholesaleApplicable
-- and has a WholesalePrice at that price, keeps everything else at retail, and refuses when the
-- wholesale-priced lines total under PHP 5,000. This column records which pricing the order was placed
-- at, so a later modify_order keeps it (and staff can see it).
--
-- Staff (Conversations > Create / Edit Order) get the same thing: a "Wholesale pricing" switch that
-- swaps eligible lines to their wholesale price, shows the PHP 5,000 minimum, and saves the flag:
--   staff_get_item_wholesale_prices   - wholesale + retail price per item code (eligible items only),
--                                       plus the order's current flag when p_order_no is given.
--   admin_set_automated_order_wholesale - sets the flag after Create / Save; refuses wholesale under
--                                       the minimum (server-side check, same rule as the bot).
--
-- Run BEFORE deploying the chatbot Edge Functions (they write / read this column - without it every
-- bot order would fail). Safe to re-run. Needs js/gmaConversations.js ?v=wholesale1.

alter table public."AutomatedOrders" add column if not exists "IsWholesale" boolean not null default false;

-- ---------------------------------------------------------------------------
-- Wholesale prices for the order form. Same eligibility gate as public_search_items /
-- public_list_wholesale_items: category IsWholesaleApplicable + a WholesalePrice > 0.
create or replace function public.staff_get_item_wholesale_prices(
  p_admin_username text,
  p_admin_password text,
  p_item_codes text[],
  p_order_no text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return jsonb_build_object(
    'is_wholesale', (select o."IsWholesale" from public."AutomatedOrders" o where o."OrderNo" = p_order_no),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', i."Code",
               'wholesale_price', i."WholesalePrice",
               'retail_price', coalesce(i."RetailPrice", i."Price")))
      from public."Items" i
      join public."Categories" c on trim(coalesce(c."Code", '')) = trim(coalesce(i."CategoryCode", ''))
      where i."Code" = any(coalesce(p_item_codes, array[]::text[]))
        and coalesce(c."IsWholesaleApplicable", false)
        and coalesce(i."WholesalePrice", 0) > 0
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.staff_get_item_wholesale_prices(text, text, text[], text) to anon;

-- ---------------------------------------------------------------------------
-- Sets the order's pricing flag. Wholesale needs the eligible lines (qty x the price on the line) to
-- reach PHP 5,000 - the same minimum the bot enforces (WHOLESALE_MIN_TOTAL in chatbot-engine.ts).
create or replace function public.admin_set_automated_order_wholesale(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_is_wholesale boolean
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_min constant numeric := 5000;
  v_status text;
  v_total numeric;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select "Status" into v_status from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    return query select false, format('Order %s not found.', p_order_no)::text;
    return;
  end if;
  if v_status in ('Completed', 'Cancelled') then
    return query select false, format('Order %s is %s.', p_order_no, v_status)::text;
    return;
  end if;

  if coalesce(p_is_wholesale, false) then
    select coalesce(sum(l."Quantity" * l."Price"), 0) into v_total
    from public."AutomatedOrderLines" l
    join public."Items" i on i."Code" = l."ItemCode"
    join public."Categories" c on trim(coalesce(c."Code", '')) = trim(coalesce(i."CategoryCode", ''))
    where l."OrderNo" = p_order_no
      and coalesce(c."IsWholesaleApplicable", false)
      and coalesce(i."WholesalePrice", 0) > 0;

    if v_total < v_min then
      return query select false, format('Wholesale items come to PHP %s - below the PHP %s wholesale minimum (short by PHP %s).',
        to_char(v_total, 'FM999,999,990.00'), to_char(v_min, 'FM999,999,990'), to_char(v_min - v_total, 'FM999,999,990.00'))::text;
      return;
    end if;
  end if;

  update public."AutomatedOrders"
  set "IsWholesale" = coalesce(p_is_wholesale, false), "UpdatedBy" = p_admin_username, "UpdatedAtUtc" = now()
  where "OrderNo" = p_order_no;

  return query select true, (case when p_is_wholesale then 'Wholesale pricing saved.' else 'Retail pricing saved.' end)::text;
end;
$$;
grant execute on function public.admin_set_automated_order_wholesale(text, text, text, boolean) to anon;

notify pgrst, 'reload schema';

-- Check (one result): the column + both functions exist, and how many orders are flagged.
select 'column'::text as section,
       exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'AutomatedOrders' and column_name = 'IsWholesale')::text as detail
union all
select 'function', string_agg(p.proname, ', ' order by p.proname)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('staff_get_item_wholesale_prices', 'admin_set_automated_order_wholesale')
union all
select 'wholesale orders', count(*)::text from public."AutomatedOrders" where "IsWholesale";
