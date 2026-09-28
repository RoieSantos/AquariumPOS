-- Glass turnaround days editable on the portal's Pricing Setup page - per "where is the setup of glass
-- turnaround days?" / "yes please".
--
-- GlassPricingSetup."TurnAroundDays" (added by supabase_online_order_assigned_status.sql) is what
-- Assigning a custom order uses for its Estimated Delivery Date (today + the turnaround days of the
-- order's thickest glass). Until now it could only be set with SQL. This adds it to the Glass Thickness
-- Pricing table on pricing-setup.html:
--   - admin_list_glass_pricing now also returns turnaround_days (re-created - return columns change).
--   - admin_set_glass_turnaround_days saves it for one thickness (blank clears it).
-- Run AFTER supabase_pricing_setup_tables.sql and supabase_online_order_assigned_status.sql.
-- Replaces/adds functions only - no table locks.

drop function if exists public.admin_list_glass_pricing(text, text);

create or replace function public.admin_list_glass_pricing(p_admin_username text, p_admin_password text)
returns table(thickness text, price_per_sqft numeric, turnaround_days text, updated_at_utc timestamptz, updated_by text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Thickness"::text, "PricePerSqFt", "TurnAroundDays"::text, "UpdatedAtUtc", "UpdatedBy"::text
    from public."GlassPricingSetup"
    where upper("Uom") = 'MM'
    order by ("Thickness")::int;
end;
$$;

grant execute on function public.admin_list_glass_pricing(text, text) to anon;

drop function if exists public.admin_set_glass_turnaround_days(text, text, text, int);

create or replace function public.admin_set_glass_turnaround_days(
  p_admin_username text,
  p_admin_password text,
  p_thickness text,
  p_days int
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
  if p_days is not null and (p_days < 0 or p_days > 365) then
    raise exception 'Turnaround days must be between 0 and 365.';
  end if;

  update public."GlassPricingSetup"
  set "TurnAroundDays" = p_days::text, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
  where upper("Uom") = 'MM' and "Thickness" = trim(p_thickness);

  if not found then
    raise exception 'No glass pricing row for %mm.', p_thickness;
  end if;
end;
$$;

grant execute on function public.admin_set_glass_turnaround_days(text, text, text, int) to anon;
