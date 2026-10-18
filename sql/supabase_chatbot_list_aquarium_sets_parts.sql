-- Alice ("list_aquarium_sets" tool): teach the bot what each ready-made SET actually comes with, per
-- "can we teach ai bot.. regarding on the sets of aquarium we have in our setups?".
--
-- Replaces public_list_aquarium_sets() from supabase_chatbot_list_aquarium_sets.sql with:
--   includes        - the package's fixed parts as real item NAMES + qty. CompleteAquariumSetLine.ItemName
--                     is often just the code ("P-013"), code+variant ("AQ-011-BlackSealant") or "1", so those
--                     fall back to the Items name (e.g. "STANDARD-100G ( 72x18x18in, 6MM GLASS)"). Never
--                     the per-line Price - a set is sold at its own price only.
--   store_selected  - parts the set comes with but that aren't fixed in the package: the STORE picks the
--                     model when preparing the set (the POS set dialog's required Sump / Stand / Lights /
--                     Pump / Pipe pickers). The customer doesn't choose.
--   not_included    - parts the package marks as not required (Customer Aquarium page "Required at the
--                     POS" unticked) and doesn't contain - the set does NOT come with them.
-- A part counts as already in the package when one of its lines is that kind of item: by Items category
-- (SUMP / STAND / LIGHTS / PUMP) or by name (SUMP, STAND/CABINET, LIGHT, PUMP, PIPE).
-- A set with no linked package returns includes/store_selected/not_included = null (bot uses Description).
-- The package (Customer Aquarium page) is the CONTENTS source; the Description only adds details the
-- package doesn't list. The PRICE stays the item's price - that's what POS and online orders charge.
--
-- Run AFTER supabase_chatbot_list_aquarium_sets.sql and supabase_aquarium_set_required_parts.sql.
-- Safe to re-run.

drop function if exists public.public_list_aquarium_sets();

create or replace function public.public_list_aquarium_sets()
returns table(code text, name text, description text, price numeric, quantity_in_stock int,
              includes jsonb, store_selected jsonb, not_included jsonb)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with s as (
    select i.*, public._resolve_set_package(i."VariationId", i."Code") as pkg
    from public."Items" i
    where i."IsActive" is true
      and upper(trim(coalesce(i."CategoryCode", ''))) = 'SET'
      and i."HideFromSet" is not true
  ),
  -- Each package line with a customer-facing name and the kind of part it is.
  pl as (
    select l."PackageName", l."EntryNo", l."Quantity",
      case
        when nullif(trim(l."ItemName"), '') is null
          or trim(l."ItemName") ~ '^[0-9.]+$'
          or upper(trim(l."ItemName")) like upper(trim(l."ItemNo")) || '%'
          then coalesce(nullif(trim(it."Name"), ''), nullif(trim(it."Description"), ''), 'part')
        else trim(l."ItemName")
      end as item_name,
      upper(coalesce(it."CategoryCode", '')) as cat,
      upper(coalesce(l."ItemName", '') || ' ' || coalesce(it."Name", '')) as words
    from public."CompleteAquariumSetLine" l
    left join public."Items" it on it."Code" = l."ItemNo"
    where trim(coalesce(l."ItemNo", '')) <> ''
  ),
  p as (
    select s.*, h."RequireSump", h."RequireStand", h."RequireLights", h."RequirePump", h."RequirePipe",
      exists (select 1 from pl where pl."PackageName" = s.pkg and (pl.cat like '%SUMP%' or pl.words like '%SUMP%')) as has_sump,
      exists (select 1 from pl where pl."PackageName" = s.pkg and (pl.cat like '%STAND%' or pl.words like '%STAND%' or pl.words like '%CABINET%')) as has_stand,
      exists (select 1 from pl where pl."PackageName" = s.pkg and (pl.cat like '%LIGHT%' or pl.words like '%LIGHT%')) as has_lights,
      exists (select 1 from pl where pl."PackageName" = s.pkg and (pl.cat like '%PUMP%' or pl.words like '%PUMP%')) as has_pump,
      exists (select 1 from pl where pl."PackageName" = s.pkg and pl.words like '%PIPE%') as has_pipe
    from s
    left join public."CompleteAquariumSetHeader" h on h."PackageName" = s.pkg
  )
  select
    p."Code"::text,
    coalesce(nullif(trim(p."Name"), ''), nullif(trim(p."Description"), ''), p."Code")::text,
    p."Description"::text,
    coalesce(p."RetailPrice", p."Price", 0)::numeric,
    p."QuantityInStock",
    (select jsonb_agg(jsonb_build_object('item', pl.item_name, 'qty', pl."Quantity") order by pl."EntryNo")
       from pl where pl."PackageName" = p.pkg),
    case when p.pkg is null then null else to_jsonb(array_remove(array[
      case when not p.has_sump   and p."RequireSump"   then 'Sump'   end,
      case when not p.has_stand  and p."RequireStand"  then 'Stand'  end,
      case when not p.has_lights and p."RequireLights" then 'Lights' end,
      case when not p.has_pump   and p."RequirePump"   then 'Pump'   end,
      case when not p.has_pipe   and p."RequirePipe"   then 'Pipes'  end
    ], null)) end,
    case when p.pkg is null then null else to_jsonb(array_remove(array[
      case when not p.has_sump   and not p."RequireSump"   then 'Sump'   end,
      case when not p.has_stand  and not p."RequireStand"  then 'Stand'  end,
      case when not p.has_lights and not p."RequireLights" then 'Lights' end,
      case when not p.has_pump   and not p."RequirePump"   then 'Pump'   end,
      case when not p.has_pipe   and not p."RequirePipe"   then 'Pipes'  end
    ], null)) end
  from p
  order by 2;
$$;
grant execute on function public.public_list_aquarium_sets() to anon;

-- Result: every set, what the bot / Conversations set picker will say it comes with (the Customer
-- Aquarium package is the contents source), and what to fix on the portal:
--   PRICE MISMATCH  - orders charge the item price (Item Setup / Pancake); the package price is display-only.
--   ONLY THE TANK   - the package has 1 line, so filter media / overflow box / stickers etc. won't be listed.
--   NO PACKAGE      - the set item isn't linked to any package (contents fall back to its Description).
select s.code, s.name, s.price as item_price, h."PackageName" as package_name, h."PackagePrice" as package_price,
       coalesce(jsonb_array_length(s.includes), 0) as package_lines, s.store_selected, s.not_included,
       concat_ws(', ',
         case when h."PackageName" is null then 'NO PACKAGE' end,
         case when h."PackagePrice" is not null and h."PackagePrice" <> s.price then 'PRICE MISMATCH' end,
         case when jsonb_array_length(s.includes) = 1 then 'ONLY THE TANK' end) as to_fix
from public.public_list_aquarium_sets() s
left join public."Items" i on i."Code" = s.code
left join public."CompleteAquariumSetHeader" h on h."PackageName" = public._resolve_set_package(i."VariationId", i."Code")
order by s.name;
