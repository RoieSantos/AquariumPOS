-- Adds a Category filter to Item Setup - per direct request ("in the item setup can we filter by
-- category"). admin_list_items previously only supported free-text search; this adds an optional
-- p_category_code, exact match against Items."CategoryCode", combinable with the existing search
-- box (both apply together when both are set).
drop function if exists public.admin_list_items(text, text, text, int, int);

create or replace function public.admin_list_items(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50,
  p_category_code text default null
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
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text, i."Name"::text, i."Description"::text, i."Cost", i."Price", i."WholesalePrice", i."RetailPrice", i."PromoPrice",
           i."CategoryCode"::text, i."Brand"::text, i."SKU"::text, i."QuantityInStock", i."MinimumStock", i."IsActive", i."Images"::text, i."SyncedAtUtc",
           i."VendorCode"::text, v."Name"::text,
           count(*) over()
    from public."Items" i
    left join public."Vendors" v on v."VendorCode" = i."VendorCode"
    where (p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%')
      and (p_category_code is null or trim(p_category_code) = '' or i."CategoryCode" = p_category_code)
    order by i."Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_items(text, text, text, int, int, text) to anon;
