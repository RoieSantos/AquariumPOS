-- Companion to staff_get_serial_category_counts_by_location (see
-- supabase_serial_category_counts_by_location.sql) - same Aquarium/Stand/Sump bucketing, but
-- broken down per product (ItemCode/Description) x Location instead of rolled up to just the
-- category totals. Per "I want to be able to see it per product".
--
-- Run this AFTER supabase_serial_category_counts_by_location.sql (shares its bucketing logic).

drop function if exists public.staff_get_serial_item_counts_by_location(text, text, text, text);

create or replace function public.staff_get_serial_item_counts_by_location(
  p_admin_username text,
  p_admin_password text,
  p_status text default 'IN_STOCK',
  p_category text default null
)
returns table(
  item_code text,
  item_description text,
  category text,
  location text,
  unit_count bigint
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
      x.bucketed_item_code::text,
      max(x.bucketed_description)::text,
      x.bucket::text,
      x.bucketed_location::text,
      count(*)
    from (
      select
        s."ItemCode" as bucketed_item_code,
        s."ItemDescription" as bucketed_description,
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
    ) x
    where x.bucket is not null
      and (p_category is null or trim(p_category) = '' or x.bucket = upper(p_category))
    group by x.bucketed_item_code, x.bucket, x.bucketed_location
    order by x.bucket, x.bucketed_item_code, x.bucketed_location;
end;
$$;

grant execute on function public.staff_get_serial_item_counts_by_location(text, text, text, text) to anon;
