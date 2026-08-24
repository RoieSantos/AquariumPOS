-- "Export to Excel" / "Import from Excel" for Item Setup - per direct request ("can we export to
-- excel so I can add the vendor"). Same round-trip convention already established for Vendor
-- Setup (supabase_vendor_bulk_import.sql): export gives a CSV with Item Code/Name/Category/Vendor
-- Code/Price, staff edit the Vendor Code column in Excel, Import reads that same file back in.
--
-- Deliberately narrower than the vendor import though - this only ever touches Items."VendorCode",
-- never Name/Category/Price, even though those columns are present in the exported file (they're
-- there for the person editing to see which item is which, not meant to be editable via this
-- path - Item Setup's own factbox/detail editing already owns those fields). Keyed by Item Code,
-- which must already exist (unlike vendor import, this never inserts new Items - only Pancake sync
-- creates items).
drop function if exists public.admin_bulk_set_item_vendors(text, text, jsonb);

create or replace function public.admin_bulk_set_item_vendors(
  p_admin_username text,
  p_admin_password text,
  p_items jsonb
)
returns table(updated_count int, skipped_count int, errors text[])
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row jsonb;
  v_item_code text;
  v_vendor_code text;
  v_updated int := 0;
  v_skipped int := 0;
  v_errors text[] := array[]::text[];
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a JSON array.';
  end if;

  for v_row in select * from jsonb_array_elements(p_items)
  loop
    v_item_code := trim(coalesce(v_row ->> 'item_code', ''));
    v_vendor_code := nullif(trim(coalesce(v_row ->> 'vendor_code', '')), '');

    if v_item_code = '' then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || 'Skipped a row with no Item Code.';
      continue;
    end if;

    if not exists (select 1 from public."Items" where "Code" = v_item_code) then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || (v_item_code || ': item not found - skipped.');
      continue;
    end if;

    if v_vendor_code is not null and not exists (select 1 from public."Vendors" where "VendorCode" = v_vendor_code) then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || (v_item_code || ': vendor code "' || v_vendor_code || '" not found on Vendor Setup - skipped.');
      continue;
    end if;

    update public."Items" set "VendorCode" = v_vendor_code where "Code" = v_item_code;
    v_updated := v_updated + 1;
  end loop;

  return query select v_updated, v_skipped, v_errors;
end;
$$;

grant execute on function public.admin_bulk_set_item_vendors(text, text, jsonb) to anon;
