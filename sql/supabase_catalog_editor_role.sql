-- New Staff Role "Catalog Editor" - per "can you create a new access.. for item setup" (2026-10-24).
-- Ticked in User Setup > Employee > Roles, like Production Manager / All-Branch Fabrication. A Catalog
-- Editor can open Item Setup and maintain the catalog - New Item, name / description / brand /
-- category / active, pictures, New Variant and variant pictures - but NOT money: Unit Cost, vendor
-- costs, selling / wholesale / promo price, units of measure, Assemble to Order and Excel import stay
-- Super User only (those RPCs are untouched and keep is_admin_authorized). Exception: the price typed
-- when creating a New Item / New Variant (an item can't be sold without one); changing it later is
-- Super User only.
--
-- HOW: same idea as is_phys_journal_authorized (supabase_phys_journal_store_manager_access.sql) - a
-- second auth check, is_item_catalog_authorized = Super User OR the CatalogEditor role, swapped in
-- ONLY for the item-catalog RPCs Item Setup needs. Rather than pasting copies of those functions here
-- (they live in several files and copies drift), the DO block below patches the LIVE definitions in
-- place (pg_get_functiondef + replace) and refuses if a function doesn't contain the expected text.
-- Also patched:
--   admin_update_item - "PromoPrice" only changes for a Super User (an editor's save keeps it).
--   admin_list_items  - Unit Cost comes back blank for a non-Super User.
--
-- Re-run this file after re-running any file that redefines one of the patched functions
-- (supabase_item_master_portal_owned.sql, supabase_item_setup_bc_list.sql,
-- supabase_warehouses_items_tables.sql) - those put back the Super-User-only versions.
--
-- Run AFTER supabase_online_order_all_branch_fabrication.sql (current role list),
-- supabase_item_master_portal_owned.sql, supabase_item_setup_bc_list.sql and
-- supabase_staff_session_tokens.sql (_staff_secret_ok). Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Allowed roles (+ CatalogEditor)

alter table public."StaffUsers" drop constraint if exists "CK_StaffUsers_StaffRoles";
alter table public."StaffUsers"
  add constraint "CK_StaffUsers_StaffRoles"
  check ("StaffRoles" <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier', 'ProductionManager', 'AllBranchFabrication', 'CatalogEditor']::text[]);

create or replace function public.admin_set_staff_user_roles(
  p_admin_username text,
  p_admin_password text,
  p_target_username text,
  p_roles text[]
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_roles text[] := coalesce(
    (select array_agg(distinct r order by r) from unnest(coalesce(p_roles, '{}')) r where nullif(trim(r), '') is not null),
    '{}'
  );
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if not (v_roles <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier', 'ProductionManager', 'AllBranchFabrication', 'CatalogEditor']::text[]) then
    return query select false, 'Roles must be Stand Maker, Tank Maker, Dispatcher, Cashier, Production Manager, All-Branch Fabrication, or Catalog Editor.'::text;
    return;
  end if;

  update public."StaffUsers" set "StaffRoles" = v_roles where "Username" = p_target_username;

  if not found then
    return query select false, 'That user no longer exists.'::text;
    return;
  end if;

  return query select true, 'Roles updated.'::text;
end;
$$;

grant execute on function public.admin_set_staff_user_roles(text, text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- 2. Super User OR Catalog Editor

create or replace function public.is_item_catalog_authorized(p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_super_user boolean;
  v_roles text[];
begin
  select "PasswordHash", "IsActive", "SuperUser", "StaffRoles"
    into v_password_hash, v_is_active, v_super_user, v_roles
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active
     or not (coalesce(v_super_user, false) or 'CatalogEditor' = any(coalesce(v_roles, '{}'::text[]))) then
    return false;
  end if;

  -- Accepts the portal's 'stok_' session token as well as the password (supabase_staff_session_tokens.sql).
  return public._staff_secret_ok(p_password, v_password_hash);
end;
$$;

-- Not granted to anon, same as is_admin_authorized() - only called from inside the functions below.

-- ---------------------------------------------------------------------------
-- 3. Patch the item-catalog RPCs in place

do $$
declare
  c_admin constant text := 'public.is_admin_authorized(p_admin_username, p_admin_password)';
  c_catalog constant text := 'public.is_item_catalog_authorized(p_admin_username, p_admin_password)';
  v_names text[] := array[
    'admin_list_items', 'admin_count_variants_by_item', 'admin_list_variants',
    'admin_item_master_status', 'admin_list_item_categories', 'admin_create_item',
    'admin_update_item', 'admin_add_item_variant', 'admin_set_variant_image',
    'admin_create_item_image_upload'
  ];
  v_name text;
  r record;
  v_def text;
  v_new text;
begin
  foreach v_name in array v_names loop
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = v_name) then
      raise exception 'public.% does not exist - run the file that creates it first (see the header).', v_name;
    end if;

    for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = v_name loop
      v_def := pg_get_functiondef(r.oid);
      v_new := replace(v_def, c_admin, c_catalog);

      if v_name = 'admin_update_item' then
        v_new := replace(v_new, '"PromoPrice" = round(p_promo_price, 2),',
          '"PromoPrice" = case when (select ' || c_admin || ') then round(p_promo_price, 2) else "PromoPrice" end,');
      elsif v_name = 'admin_list_items' then
        -- Uncorrelated sub-select: evaluated once per call, not once per row.
        v_new := replace(v_new, 'i."Cost", i."Price"',
          'case when (select ' || c_admin || ') then i."Cost" end, i."Price"');
      end if;

      if v_new <> v_def then
        execute v_new;
      elsif position(c_catalog in v_def) = 0 then
        raise exception 'public.% has no "%" check to widen - not patched. Tell Claude.', v_name, c_admin;
      end if; -- else already patched by an earlier run
    end loop;
  end loop;
end;
$$;

-- One result: each patched function, and whether the Catalog Editor check / money guards are in place.
select p.proname::text as function_name,
       case when p.prosrc like '%is_item_catalog_authorized%' then 'Catalog Editor allowed' else 'NOT PATCHED' end as access,
       case p.proname
         when 'admin_update_item' then case when p.prosrc like '%else "PromoPrice" end%' then 'promo price: Super User only' else 'PROMO GUARD MISSING' end
         when 'admin_list_items' then case when p.prosrc like '%then i."Cost" end%' then 'unit cost: Super User only' else 'COST GUARD MISSING' end
         else '' end as money_guard
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
where p.proname in ('admin_list_items', 'admin_count_variants_by_item', 'admin_list_variants',
                    'admin_item_master_status', 'admin_list_item_categories', 'admin_create_item',
                    'admin_update_item', 'admin_add_item_variant', 'admin_set_variant_image',
                    'admin_create_item_image_upload')
order by 1;
