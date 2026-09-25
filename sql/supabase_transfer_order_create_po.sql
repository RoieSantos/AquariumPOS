-- Transfer Order > "Create PO": buy the items the From warehouse is short of, one Purchase Order per
-- supplier. The PO itself is created with the existing staff_create_purchase_order; the only thing
-- missing was a way to ask "which vendor supplies these items?" for a list of item codes.
--
-- Uses the item's PRIMARY vendor (Items."VendorCode") - the same one Stock On Hand groups by and
-- Create Purchase Order there uses. Items with no vendor come back with a null vendor_code so the
-- page can list them as "no supplier set" instead of silently dropping them.
--
-- Run in the Supabase SQL Editor.

drop function if exists public.staff_get_items_vendor_info(text, text, text[]);

create or replace function public.staff_get_items_vendor_info(
  p_admin_username text,
  p_admin_password text,
  p_item_codes text[]
)
returns table(item_code text, item_name text, vendor_code text, vendor_name text, unit_cost numeric)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text,
           coalesce(nullif(trim(i."Name"), ''), i."Code")::text,
           nullif(trim(coalesce(i."VendorCode", '')), '')::text,
           v."Name"::text,
           i."Cost"
    from public."Items" i
    left join public."Vendors" v on v."VendorCode" = i."VendorCode"
    where i."Code" = any(p_item_codes);
end;
$$;

grant execute on function public.staff_get_items_vendor_info(text, text, text[]) to anon;

notify pgrst, 'reload schema';
