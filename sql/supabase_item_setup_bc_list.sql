-- Item Setup as a Business Central list page (docs/item-setup.html): "Filter list by" pane on the left,
-- FactBox on the right, sortable columns. admin_list_items gets the pane's filters and a sort, all
-- optional with defaults, so every other caller (Item Ledger Entries, Physical / Serial Inventory
-- Journal, Serial Tracker - named p_search / p_page / p_page_size) works unchanged.
--
-- New parameters:
--   p_status           'active' | 'inactive'            (null = all)
--   p_vendor_code      a vendor code, or '-' = no primary vendor tagged
--   p_brand            part of the brand (ilike)
--   p_cost_filter      'costed' | 'not_costed'
--   p_wholesale_filter 'set' | 'not_set'
--   p_price_from / p_price_to   selling price range
--   p_sort             code | name | category | brand | vendor | cost | price | wholesale | status
--   p_sort_desc        reverse the sort
-- Default order stays Name.
--
-- Also returns hide_from_set again (supabase_item_hide_from_set.sql added it, but
-- supabase_item_setup_category_filter.sql redefined the function without it, so the Item Card's
-- "Hide from Order Now SET listing" box could show unticked for a hidden item).
--
-- Run AFTER supabase_item_hide_from_set.sql and supabase_item_setup_category_filter.sql. Safe to re-run.

-- Normally already there (supabase_item_hide_from_set.sql); repeated so the function never fails on it.
alter table public."Items" add column if not exists "HideFromSet" boolean not null default false;

drop function if exists public.admin_list_items(text, text, text, int, int);
drop function if exists public.admin_list_items(text, text, text, int, int, text);
drop function if exists public.admin_list_items(text, text, text, int, int, text, text, text, text, text, text, numeric, numeric, text, boolean);

create or replace function public.admin_list_items(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50,
  p_category_code text default null,
  p_status text default null,
  p_vendor_code text default null,
  p_brand text default null,
  p_cost_filter text default null,
  p_wholesale_filter text default null,
  p_price_from numeric default null,
  p_price_to numeric default null,
  p_sort text default null,
  p_sort_desc boolean default false
)
returns table(
  code text,
  name text,
  description text,
  cost numeric,
  price numeric,
  wholesale_price numeric,
  retail_price numeric,
  promo_price numeric,
  category_code text,
  brand text,
  sku text,
  quantity_in_stock int,
  minimum_stock int,
  is_active boolean,
  images text,
  synced_at_utc timestamptz,
  vendor_code text,
  vendor_name text,
  hide_from_set boolean,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_sort text := lower(coalesce(nullif(trim(p_sort), ''), 'name'));
  v_desc boolean := coalesce(p_sort_desc, false);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_brand text := nullif(trim(coalesce(p_brand, '')), '');
  v_vendor text := nullif(trim(coalesce(p_vendor_code, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text, i."Name"::text, i."Description"::text, i."Cost", i."Price", i."WholesalePrice", i."RetailPrice", i."PromoPrice",
           i."CategoryCode"::text, i."Brand"::text, i."SKU"::text, i."QuantityInStock", i."MinimumStock", i."IsActive", i."Images"::text, i."SyncedAtUtc",
           i."VendorCode"::text, v."Name"::text, i."HideFromSet",
           count(*) over()
    from public."Items" i
    left join public."Vendors" v on v."VendorCode" = i."VendorCode"
    where (v_search is null or i."Code" ilike '%' || v_search || '%' or i."Name" ilike '%' || v_search || '%')
      and (p_category_code is null or trim(p_category_code) = '' or i."CategoryCode" = p_category_code)
      and (p_status is null or (p_status = 'active' and i."IsActive" is not false)
                            or (p_status = 'inactive' and i."IsActive" is false))
      and (v_vendor is null or (v_vendor = '-' and coalesce(i."VendorCode", '') = '')
                            or i."VendorCode" = v_vendor)
      and (v_brand is null or i."Brand" ilike '%' || v_brand || '%')
      and (p_cost_filter is null or (p_cost_filter = 'costed' and i."Cost" is not null)
                                 or (p_cost_filter = 'not_costed' and i."Cost" is null))
      and (p_wholesale_filter is null or (p_wholesale_filter = 'set' and i."WholesalePrice" is not null)
                                      or (p_wholesale_filter = 'not_set' and i."WholesalePrice" is null))
      and (p_price_from is null or i."Price" >= p_price_from)
      and (p_price_to is null or i."Price" <= p_price_to)
    order by
      case when not v_desc then
        case v_sort when 'code' then i."Code"::text when 'name' then i."Name"::text
                    when 'category' then i."CategoryCode"::text when 'brand' then i."Brand"::text
                    when 'vendor' then v."Name"::text end
      end asc nulls last,
      case when v_desc then
        case v_sort when 'code' then i."Code"::text when 'name' then i."Name"::text
                    when 'category' then i."CategoryCode"::text when 'brand' then i."Brand"::text
                    when 'vendor' then v."Name"::text end
      end desc nulls last,
      case when not v_desc then
        case v_sort when 'cost' then i."Cost" when 'price' then i."Price" when 'wholesale' then i."WholesalePrice"
                    when 'status' then case when i."IsActive" is false then 1 else 0 end end
      end asc nulls last,
      case when v_desc then
        case v_sort when 'cost' then i."Cost" when 'price' then i."Price" when 'wholesale' then i."WholesalePrice"
                    when 'status' then case when i."IsActive" is false then 1 else 0 end end
      end desc nulls last,
      i."Name", i."Code"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- One result: every admin_list_items left in the database (should be exactly one, with 15 arguments).
select p.oid::regprocedure::text as function_signature, p.pronargs as arguments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
where p.proname = 'admin_list_items';
