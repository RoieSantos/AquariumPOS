-- AI Messenger chatbot: keyword product search, called by Claude's search_items tool
-- (supabase/functions/facebook-messenger-webhook) whenever a customer asks "do you have X" or
-- about a specific product's price/stock.
--
-- public_list_order_items (supabase_automated_orders_tables.sql:123-141) only lists by exact
-- CategoryCode - there's no free-text search RPC anywhere in this codebase yet, and a chatbot
-- needs one since customers describe what they want in their own words, not by category code.
--
-- Same "never expose Cost/WholesalePrice/PromoPrice" discipline and column set as
-- public_list_order_items - only what's safe to show a customer with no login at all leaves the
-- server. `limit 20` matters here specifically because the result feeds an LLM prompt rather than
-- a paginated UI - an unbounded ILIKE match (e.g. "fish") could return hundreds of rows and blow
-- up token cost on every such message.

drop function if exists public.public_search_items(text);

create or replace function public.public_search_items(p_query text)
returns table(code text, name text, description text, category_code text, price numeric, images text, quantity_in_stock int)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select
    i."Code"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text,
    i."Description"::text,
    i."CategoryCode"::text,
    coalesce(i."RetailPrice", i."Price", 0)::numeric,
    i."Images"::text,
    i."QuantityInStock"
  from public."Items" i
  where i."IsActive" is true
    and (
      i."Name" ilike '%' || p_query || '%'
      or i."Description" ilike '%' || p_query || '%'
      or i."SKU" ilike '%' || p_query || '%'
      or i."Code" ilike '%' || p_query || '%'
    )
  order by i."Name"
  limit 20;
$$;

grant execute on function public.public_search_items(text) to anon;
