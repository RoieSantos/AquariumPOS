-- Fixes the Web Portal's Custom Calculator Light/Pump dropdowns returning "No items found"
-- even when matching Items exist. staff_list_items_by_category (see
-- supabase_warehouses_items_tables.sql) was filtering on i."IsActive" is true, but the desktop's
-- own Submersible Light/Pump combo-box queries (MainForm.cs's submersibleLightItemCombo /
-- submersiblePumpItemCombo populate blocks) never filter on IsActive at all - they list every
-- Items row under CategoryCode = 'LIGHTS' / 'PUMP' regardless of active status. Items with
-- IsActive unset/false locally were therefore showing up in the desktop app but silently
-- disappearing from the portal dropdowns. This re-creates the function without that extra
-- filter so it matches the desktop behavior exactly, as the function's own comment already
-- claimed it did.
drop function if exists public.staff_list_items_by_category(text, text, text);

create or replace function public.staff_list_items_by_category(p_admin_username text, p_admin_password text, p_category_code text)
returns table(code text, item_name text, price numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      i."Code"::text,
      coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text as item_name,
      coalesce(i."Price", 0)::numeric as price
    from public."Items" i
    where trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
    order by item_name;
end;
$$;

grant execute on function public.staff_list_items_by_category(text, text, text) to anon;
