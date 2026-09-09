-- Powers the Portal's new "Inventory Summary" page - a user-friendly count of Aquarium/Stand/Sump
-- serial-tracked units, grouped by Location (Warehouse). Per "I want to see a view we can see the
-- count of Aquarium/Stand/Sump based on the serial tracking, base on location/Warehouse".
--
-- Category bucketing mirrors the real item-code data (verified directly against the local DB):
--   - Real catalog codes (AQ-*, AST-*, ST-*, S-*, OH-SUMP-*, etc.) are bucketed via
--     Items.CategoryCode = 'AQUARIUM'/'STAND'/'SUMP' - the same categories already flagged
--     IsProductionCategory locally.
--   - Build-to-order lines from the Custom Aquarium Calculator don't have a real Items row - their
--     ItemCode IS the category placeholder itself ("CUSTOM-AQUARIUM", "CUSTOM_STAND"/"CUSTOM-STAND",
--     "CUSTOM_SUMP"/"CUSTOM-SUMP" - both underscore/dash spellings exist in real data), so those are
--     matched directly by ItemCode instead of going through Items.
--
-- p_status defaults to 'IN_STOCK' (current on-hand inventory) but accepts any ItemSerialTracking
-- Status, or null/blank for every status combined.

drop function if exists public.staff_get_serial_category_counts_by_location(text, text, text);

create or replace function public.staff_get_serial_category_counts_by_location(
  p_admin_username text,
  p_admin_password text,
  p_status text default 'IN_STOCK'
)
returns table(
  location text,
  aquarium_count bigint,
  stand_count bigint,
  sump_count bigint,
  total_count bigint
)
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
      t.bucketed_location as location,
      count(*) filter (where t.bucket = 'AQUARIUM') as aquarium_count,
      count(*) filter (where t.bucket = 'STAND') as stand_count,
      count(*) filter (where t.bucket = 'SUMP') as sump_count,
      count(*) filter (where t.bucket is not null) as total_count
    from (
      select
        coalesce(nullif(trim(s."Location"), ''), '(Unassigned)') as bucketed_location,
        case
          when i."CategoryCode" = 'AQUARIUM' or s."ItemCode" = 'CUSTOM-AQUARIUM' then 'AQUARIUM'
          when i."CategoryCode" = 'STAND' or s."ItemCode" ilike 'CUSTOM%STAND%' then 'STAND'
          when i."CategoryCode" = 'SUMP' or s."ItemCode" ilike 'CUSTOM%SUMP%' then 'SUMP'
          else null
        end as bucket
      from public."ItemSerialTracking" s
      left join public."Items" i on i."Code" = s."ItemCode"
      where p_status is null or trim(p_status) = '' or upper(s."Status") = upper(p_status)
    ) t
    group by t.bucketed_location
    order by t.bucketed_location;
end;
$$;

grant execute on function public.staff_get_serial_category_counts_by_location(text, text, text) to anon;
