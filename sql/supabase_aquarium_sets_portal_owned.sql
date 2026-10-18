-- Aquarium SETS become portal-owned - per "i dont want to rely on pancake.. the source truth will be the
-- customer aquarium from portal". The Customer Aquarium package (CompleteAquariumSetHeader/Line) is now the
-- ONE place a set is defined: name, price, contents, description, sold online or not.
--
-- How it works:
--   * Each package gets a SetCode (SET-007, SET-015, ...). Saving a package creates/updates a matching
--     Items row (Code = SetCode, CategoryCode 'SET', Price = PackagePrice) via a trigger, so the website,
--     Alice, Online/Automated Orders keep working unchanged - they all sell by Items code. Those rows are
--     never in Pancake, so the Pancake item sync (upsert by Code) never touches them.
--   * Pancake: a set line is pushed as a ONE-TIME product (name + price, no catalog product) - the same
--     thing the POS already does for in-store sales of a package with no Variant ID. Patched into the
--     live _push_automated_order_to_pancake in place (step 1).
--   * _resolve_set_package matches a SET line by SetCode first, so set explosion / stock / serials
--     resolve portal sets (an order coming back from Pancake carries the SetCode as its item code).
--   * The POS needs no change: it already sells sets from the packages at the Package Price.
--
-- Migration (re-runnable - only touches packages without a SetCode yet):
--   a. deletes EMPTY duplicate packages (0 items, same Variant ID as a package that has items);
--   b. each visible Pancake set item (AS-007...) -> its package gets SetCode SET-007, the item's
--      Description + Images, and the item's CURRENT price (what customers pay today); the AS item is
--      hidden (HideFromSet) so only the portal set is listed;
--   c. every other package gets a code too: Sell online = on if it has no Pancake Variant ID (e.g. the
--      15g Topfilter Package), off if it's a leftover duplicate / a hidden item's package.
--
-- Run AFTER supabase_online_order_set_explode.sql, supabase_aquarium_set_required_parts.sql and
-- supabase_chatbot_list_aquarium_sets_parts.sql. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Pancake push: SET lines with no Pancake product go as one-time products. Patches the LIVE function
--    text (it has been redefined across several files) - stops with an error, before anything else in
--    this file runs, if the expected text isn't there.
do $patch$
declare
  v_def text := pg_get_functiondef('public._push_automated_order_to_pancake(text)'::regprocedure);
  v_new text;
begin
  if v_def like '%one_time_product%' then
    raise notice '_push_automated_order_to_pancake already patched - skipped.';
    return;
  end if;

  v_new := v_def;
  v_new := replace(v_new,
    $s$'variation_id', coalesce(nullif(l."VariationId", ''), i."VariationId"),$s$,
    $s$'one_time_product', (coalesce(nullif(l."VariationId", ''), i."VariationId") is null and i."ProductId" is null),
          'variation_id', coalesce(nullif(l."VariationId", ''), i."VariationId"),$s$);
  if v_new = v_def then raise exception 'Push patch: variation_id snippet not found - nothing changed.'; end if;
  v_def := v_new;

  v_new := replace(v_new,
    $s$'name', l."ItemName",$s$,
    $s$'name', l."ItemName",
            'display_id', i."Code",
            'product_display_id', i."Code",$s$);
  if v_new = v_def then raise exception 'Push patch: variation_info name snippet not found - nothing changed.'; end if;
  v_def := v_new;

  v_new := replace(v_new,
    $s$and (i."VariationId" is not null or i."ProductId" is not null);$s$,
    $s$and (i."VariationId" is not null or i."ProductId" is not null or upper(trim(coalesce(i."CategoryCode", ''))) = 'SET');$s$);
  if v_new = v_def then raise exception 'Push patch: matched-lines filter not found - nothing changed.'; end if;

  execute v_new;
end
$patch$;

-- ---------------------------------------------------------------------------
-- 2. Package columns.
alter table public."CompleteAquariumSetHeader"
  add column if not exists "SetCode" varchar(50),
  add column if not exists "Description" varchar(1000),
  add column if not exists "SellOnline" boolean not null default true,
  add column if not exists "Images" text;

create unique index if not exists "UX_CompleteAquariumSetHeader_SetCode"
  on public."CompleteAquariumSetHeader" ("SetCode") where "SetCode" is not null;

-- ---------------------------------------------------------------------------
-- 3. Package -> Items row (and a SetCode for a new package).
create or replace function public._set_package_sync_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if nullif(trim(old."SetCode"), '') is not null then
      update public."Items" set "IsActive" = false, "HideFromSet" = true where "Code" = old."SetCode";
    end if;
    return old;
  end if;

  if nullif(trim(new."SetCode"), '') is null then
    select 'SET-' || lpad((coalesce(max(substring(h."SetCode" from '^SET-(\d+)$')::int), 0) + 1)::text, 3, '0')
      into new."SetCode"
      from public."CompleteAquariumSetHeader" h;
  end if;

  insert into public."Items" ("Code", "Name", "Description", "Price", "RetailPrice", "CategoryCode",
                              "IsActive", "HideFromSet", "Images", "QuantityInStock", "SyncedAtUtc")
  values (new."SetCode", new."PackageName", left(coalesce(nullif(trim(new."Description"), ''), new."PackageName"), 1000),
          new."PackagePrice", new."PackagePrice", 'SET',
          new."SellOnline", not new."SellOnline", new."Images", 0, now())
  on conflict ("Code") do update set
    "Name" = excluded."Name",
    "Description" = excluded."Description",
    "Price" = excluded."Price",
    "RetailPrice" = excluded."RetailPrice",
    "CategoryCode" = 'SET',
    "IsActive" = excluded."IsActive",
    "HideFromSet" = excluded."HideFromSet",
    "Images" = coalesce(excluded."Images", public."Items"."Images"),
    "SyncedAtUtc" = now();
  return new;
end;
$$;

drop trigger if exists "TR_CompleteAquariumSetHeader_SyncItem" on public."CompleteAquariumSetHeader";
create trigger "TR_CompleteAquariumSetHeader_SyncItem"
  before insert or update on public."CompleteAquariumSetHeader"
  for each row execute function public._set_package_sync_item();

drop trigger if exists "TR_CompleteAquariumSetHeader_DeleteItem" on public."CompleteAquariumSetHeader";
create trigger "TR_CompleteAquariumSetHeader_DeleteItem"
  after delete on public."CompleteAquariumSetHeader"
  for each row execute function public._set_package_sync_item();

-- ---------------------------------------------------------------------------
-- 4. Package for a SET line: the package's own SetCode first, then (as before) header VariantID =
--    VariationId, a saved mapping by VariationId, then by ItemCode. Only packages with lines count.
create or replace function public._resolve_set_package(p_variation_id text, p_item_code text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select h."PackageName" from public."CompleteAquariumSetHeader" h
      where nullif(trim(p_item_code), '') is not null
        and lower(trim(coalesce(h."SetCode", ''))) = lower(trim(p_item_code))
        and public._set_package_has_lines(h."PackageName")
      limit 1),
    (select h."PackageName" from public."CompleteAquariumSetHeader" h
      where nullif(trim(p_variation_id), '') is not null
        and lower(trim(coalesce(h."VariantID", ''))) = lower(trim(p_variation_id))
        and public._set_package_has_lines(h."PackageName")
      order by h."PackageName"
      limit 1),
    (select h."PackageName" from public."OnlineOrderSetPackageMap" m
      join public."CompleteAquariumSetHeader" h on lower(trim(h."PackageName")) = lower(trim(m."PackageName"))
      where nullif(trim(p_variation_id), '') is not null
        and m."MatchType" = 'VariationId' and m."MatchValue" = trim(p_variation_id)
        and public._set_package_has_lines(h."PackageName")
      limit 1),
    (select h."PackageName" from public."OnlineOrderSetPackageMap" m
      join public."CompleteAquariumSetHeader" h on lower(trim(h."PackageName")) = lower(trim(m."PackageName"))
      where nullif(trim(p_item_code), '') is not null
        and m."MatchType" = 'ItemCode' and m."MatchValue" = trim(p_item_code)
        and public._set_package_has_lines(h."PackageName")
      limit 1)
  );
$$;
revoke all on function public._resolve_set_package(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Migration (a, b, c above). Logged to a temp table for the result.
drop table if exists _set_migration_log;
create temp table _set_migration_log (package_name text, action text, detail text);

do $migrate$
declare
  r record;
  v_code text;
begin
  -- a. Empty duplicates.
  with gone as (
    delete from public."CompleteAquariumSetHeader" h
    where not public._set_package_has_lines(h."PackageName")
      and nullif(trim(h."SetCode"), '') is null
      and nullif(trim(h."VariantID"), '') is not null
      and exists (select 1 from public."CompleteAquariumSetHeader" h2
                   where h2."PackageName" <> h."PackageName"
                     and lower(trim(coalesce(h2."VariantID", ''))) = lower(trim(h."VariantID"))
                     and public._set_package_has_lines(h2."PackageName"))
    returning h."PackageName", h."PackagePrice"
  )
  insert into _set_migration_log select "PackageName", 'DELETED', 'empty duplicate (0 items), was ' || "PackagePrice" from gone;

  -- b. Pancake set items -> their packages.
  for r in
    select i."Code", coalesce(i."RetailPrice", i."Price", 0) as price, i."Description", i."Images",
           public._resolve_set_package(i."VariationId", i."Code") as pkg
    from public."Items" i
    where i."IsActive" is true
      and upper(trim(coalesce(i."CategoryCode", ''))) = 'SET'
      and i."HideFromSet" is not true
      and not exists (select 1 from public."CompleteAquariumSetHeader" h where h."SetCode" = i."Code")
  loop
    if r.pkg is null then
      insert into _set_migration_log values (r."Code", 'NOT MIGRATED', 'Pancake set item with no package - left as is');
      continue;
    end if;
    if exists (select 1 from public."CompleteAquariumSetHeader" h
                where h."PackageName" = r.pkg and nullif(trim(h."SetCode"), '') is not null) then
      continue;
    end if;
    v_code := 'SET-' || regexp_replace(r."Code", '^[A-Za-z]+-', '');
    insert into _set_migration_log
      select r.pkg, 'MIGRATED', 'from ' || r."Code" || ' -> ' || v_code
             || case when h."PackagePrice" <> r.price and r.price > 0
                     then ', price ' || h."PackagePrice" || ' -> ' || r.price || ' (item price kept)' else '' end
      from public."CompleteAquariumSetHeader" h where h."PackageName" = r.pkg;
    update public."CompleteAquariumSetHeader"
       set "SetCode" = v_code,
           "Description" = coalesce(nullif(trim(r."Description"), ''), "Description"),
           "Images" = coalesce(r."Images", "Images"),
           "PackagePrice" = case when r.price > 0 then r.price else "PackagePrice" end,
           "SellOnline" = true,
           "UpdatedDate" = now()
     where "PackageName" = r.pkg;
    update public."Items" set "HideFromSet" = true where "Code" = r."Code";
  end loop;

  -- c. Every other package.
  for r in select "PackageName", "VariantID" from public."CompleteAquariumSetHeader"
           where nullif(trim("SetCode"), '') is null
  loop
    update public."CompleteAquariumSetHeader"
       set "SellOnline" = nullif(trim(r."VariantID"), '') is null
     where "PackageName" = r."PackageName";
    insert into _set_migration_log values (r."PackageName",
      case when nullif(trim(r."VariantID"), '') is null then 'NEW ONLINE SET' else 'NOT SOLD ONLINE' end,
      case when nullif(trim(r."VariantID"), '') is null then 'portal-only package - now sold online'
           else 'duplicate / hidden item''s package - tick Sell online on the page if it should be offered' end);
  end loop;
end
$migrate$;

-- Result: every package after the migration, plus what was deleted.
select coalesce(h."PackageName", g.package_name) as package_name,
       h."SetCode" as set_code,
       h."SellOnline" as sell_online,
       h."PackagePrice" as package_price,
       (select count(*) from public."CompleteAquariumSetLine" l where l."PackageName" = h."PackageName") as items,
       coalesce(g.action, 'unchanged') as action,
       g.detail
from public."CompleteAquariumSetHeader" h
full join _set_migration_log g on g.package_name = h."PackageName"
order by (h."PackageName" is null), coalesce(h."SetCode", 'zzz'), 1;
