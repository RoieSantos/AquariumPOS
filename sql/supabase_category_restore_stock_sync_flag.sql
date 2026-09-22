-- Restores the "Include in Stock Sync" checkbox on Category Setup, per direct request: "i remember
-- in the categories we have include on stock count right? can we revert that back with the data?"
-- Follow-up answer: just the Category Setup checkbox, nothing else - Stock On Hand and the
-- Physical Inventory Journal keep covering every item (see supabase_category_drop_stock_sync_flag.sql
-- and supabase_item_ledger_phys_inventory_journal.sql), matching "everything monitored as of the
-- moment". This does not undo that - it only brings the field back into view.
--
-- "WITH THE DATA": the Categories."IncludeInStockSync" column was never dropped when the checkbox
-- was removed (supabase_category_drop_stock_sync_flag.sql said so explicitly) - whatever was
-- checked before that change is still sitting in the column, untouched. Restoring the two RPCs
-- below to read/write it again makes those old values reappear exactly as they were left.
--
-- Run AFTER supabase_category_drop_stock_sync_flag.sql, then deploy the matching
-- docs/js/categorySetup.js.

drop function if exists public.admin_list_categories(text, text);

create or replace function public.admin_list_categories(p_admin_username text, p_admin_password text)
returns table(
  code text, description text, is_production_category boolean, exclude_in_transfer_orders boolean,
  is_wholesale_applicable boolean, include_in_stock_sync boolean, item_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."CategoryCode"::text, c."Description"::text, coalesce(c."IsProductionCategory", false),
           coalesce(c."ExcludeInTransferOrders", false),
           coalesce(c."IsWholesaleApplicable", false), coalesce(c."IncludeInStockSync", false), count(*)
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where i."CategoryCode" is not null and trim(i."CategoryCode") <> ''
    group by i."CategoryCode", c."Description", c."IsProductionCategory", c."ExcludeInTransferOrders",
             c."IsWholesaleApplicable", c."IncludeInStockSync"
    order by i."CategoryCode";
end;
$$;

drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean);

create or replace function public.admin_update_category_flags(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_description text,
  p_is_production_category boolean,
  p_exclude_in_transfer_orders boolean,
  p_is_wholesale_applicable boolean,
  p_include_in_stock_sync boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  insert into public."Categories" (
    "Code", "Description", "IsProductionCategory", "ExcludeInTransferOrders", "IsWholesaleApplicable", "IncludeInStockSync"
  )
  values (
    p_code, nullif(trim(p_description), ''), coalesce(p_is_production_category, false),
    coalesce(p_exclude_in_transfer_orders, false), coalesce(p_is_wholesale_applicable, false),
    coalesce(p_include_in_stock_sync, false)
  )
  on conflict ("Code") do update
    set "Description" = excluded."Description",
        "IsProductionCategory" = excluded."IsProductionCategory",
        "ExcludeInTransferOrders" = excluded."ExcludeInTransferOrders",
        "IsWholesaleApplicable" = excluded."IsWholesaleApplicable",
        "IncludeInStockSync" = excluded."IncludeInStockSync";
end;
$$;

grant execute on function public.admin_list_categories(text, text) to anon;
grant execute on function public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean) to anon;

notify pgrst, 'reload schema';
