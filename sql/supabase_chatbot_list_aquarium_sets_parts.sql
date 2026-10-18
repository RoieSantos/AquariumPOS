-- Alice ("list_aquarium_sets" tool): teach the bot what each ready-made SET actually comes with, per
-- "can we teach ai bot.. regarding on the sets of aquarium we have in our setups?".
--
-- Replaces public_list_aquarium_sets() from supabase_chatbot_list_aquarium_sets.sql with:
--   includes        - the package's fixed parts as item NAMES + qty (falls back to the Items name, never
--                     the raw code; never the per-line Price - a set is sold at its own price only).
--   store_selected  - parts the set comes with whose exact model the STORE picks when the set is
--                     prepared (the POS set dialog's required Lights / Pump / Pipe, and Sump / Stand when
--                     the package has no sump/stand line of its own). The customer doesn't choose.
--   not_included    - parts the package marks as not required (Customer Aquarium page "Required at the
--                     POS" unticked) - the set does NOT come with them; they can be bought separately.
-- Sump/Stand lines are detected the same way as the POS (MainForm.BuildAquariumVariantFieldLabel):
-- code/name containing SUMP, or STAND/CABINET.
-- A set with no linked package returns includes/store_selected/not_included = null (bot uses Description).
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
  p as (
    select s.*, h."RequireSump", h."RequireStand", h."RequireLights", h."RequirePump", h."RequirePipe",
      exists (select 1 from public."CompleteAquariumSetLine" l
               where l."PackageName" = s.pkg
                 and upper(coalesce(l."ItemNo", '') || ' ' || coalesce(l."ItemName", '')) like '%SUMP%') as has_sump,
      exists (select 1 from public."CompleteAquariumSetLine" l
               where l."PackageName" = s.pkg
                 and (upper(coalesce(l."ItemNo", '') || ' ' || coalesce(l."ItemName", '')) like '%STAND%'
                   or upper(coalesce(l."ItemNo", '') || ' ' || coalesce(l."ItemName", '')) like '%CABINET%')) as has_stand
    from s
    left join public."CompleteAquariumSetHeader" h on h."PackageName" = s.pkg
  )
  select
    p."Code"::text,
    coalesce(nullif(trim(p."Name"), ''), nullif(trim(p."Description"), ''), p."Code")::text,
    p."Description"::text,
    coalesce(p."RetailPrice", p."Price", 0)::numeric,
    p."QuantityInStock",
    (select jsonb_agg(jsonb_build_object(
              'item', coalesce(nullif(trim(l."ItemName"), ''), nullif(trim(it."Name"), ''), nullif(trim(it."Description"), ''), 'part'),
              'qty', l."Quantity")
            order by l."EntryNo")
       from public."CompleteAquariumSetLine" l
       left join public."Items" it on it."Code" = l."ItemNo"
      where l."PackageName" = p.pkg
        and trim(coalesce(l."ItemNo", '')) <> ''),
    case when p.pkg is null then null else to_jsonb(array_remove(array[
      case when not p.has_sump  and p."RequireSump"   then 'Sump'   end,
      case when not p.has_stand and p."RequireStand"  then 'Stand'  end,
      case when p."RequireLights" then 'Lights' end,
      case when p."RequirePump"   then 'Pump'   end,
      case when p."RequirePipe"   then 'Pipes'  end
    ], null)) end,
    case when p.pkg is null then null else to_jsonb(array_remove(array[
      case when not p.has_sump  and not p."RequireSump"   then 'Sump'   end,
      case when not p.has_stand and not p."RequireStand"  then 'Stand'  end,
      case when not p."RequireLights" then 'Lights' end,
      case when not p."RequirePump"   then 'Pump'   end,
      case when not p."RequirePipe"   then 'Pipes'  end
    ], null)) end
  from p
  order by 2;
$$;
grant execute on function public.public_list_aquarium_sets() to anon;

-- Result: every set and what the bot will now say it comes with.
select code, name, price, quantity_in_stock,
       includes, store_selected, not_included
from public.public_list_aquarium_sets();
