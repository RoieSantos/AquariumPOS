-- Per-date Vendor assignment on the Delivery Calendar (super users only) - lets a super user tag a
-- Vendor to one SPECIFIC calendar date (e.g. "Aug 29: pick up from Vendor X"), distinct from the
-- weekly RECURRING vendor tags in supabase_delivery_route_schedule.sql
-- (DeliveryRouteScheduleVendors, "every Tuesday = Vendor X"). Per "in the delivery calendar if im
-- a super user can I assign vendors" -> "yes per day i want super user to be able to assign
-- vendors" - this is a one-off per-date tag, not a change to the recurring weekly schedule, and
-- both are shown side by side on the calendar/day-detail view (docs/js/delivery.js).
--
-- Add-one/remove-one semantics (like assigning/removing an order via DeliveryStops), NOT the
-- weekly schedule's "replace the whole set on every save" semantics - a super user picks vendors
-- for a date one at a time and can remove them one at a time.
--
-- No FK on VendorCode - matches the existing unenforced-reference convention already used by
-- DeliveryRouteScheduleVendors/Items.VendorCode (supabase_delivery_route_schedule.sql/
-- supabase_vendor_tables.sql).

create table if not exists public."DeliveryDateVendors" (
    "DeliveryDate" date not null,
    "VendorCode" varchar(50) not null,
    "AssignedBy" varchar(100),
    "AssignedAtUtc" timestamptz not null default now(),
    primary key ("DeliveryDate", "VendorCode")
);

alter table public."DeliveryDateVendors" enable row level security;
revoke all on public."DeliveryDateVendors" from anon, authenticated;

create index if not exists "IX_DeliveryDateVendors_Date" on public."DeliveryDateVendors" ("DeliveryDate");

comment on table public."DeliveryDateVendors" is 'Vendors assigned to one specific delivery date (super-user-only, ad hoc) - not the weekly recurring DeliveryRouteScheduleVendors schedule.';

drop function if exists public.staff_list_delivery_date_vendors(text, text, date, date);

-- Read-only, any-staff (same tier as admin_list_delivery_stops) so every staff member browsing the
-- calendar sees these date-vendor tags, even though only a super user can add/remove them - same
-- read-vs-write split already used for admin_delete_delivery_stop (write, super-user-only) vs the
-- rest of this page's RPCs (read/create, any staff).
create or replace function public.staff_list_delivery_date_vendors(
  p_admin_username text,
  p_admin_password text,
  p_start_date date,
  p_end_date date
)
returns table(
  delivery_date date,
  vendor_code text,
  vendor_name text,
  assigned_by text,
  assigned_at_utc timestamptz
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
    select dv."DeliveryDate", dv."VendorCode"::text, coalesce(v."Name", dv."VendorCode")::text,
           dv."AssignedBy"::text, dv."AssignedAtUtc"
    from public."DeliveryDateVendors" dv
    left join public."Vendors" v on v."VendorCode" = dv."VendorCode"
    where dv."DeliveryDate" >= p_start_date and dv."DeliveryDate" < p_end_date
    order by dv."DeliveryDate", vendor_name;
end;
$$;

drop function if exists public.admin_assign_delivery_date_vendor(text, text, date, text);

-- Super-user-only write (is_admin_authorized) - mirrors admin_delete_delivery_stop's gate ("if
-- the user is not super user dont allow removing the stops in the delivery"), applied here to
-- assigning/removing a date-vendor tag instead. Blocks Mondays, same rule already enforced for
-- order stops (admin_create_delivery_stop) and the weekly schedule
-- (admin_upsert_delivery_route_schedule) - no truck runs Mondays.
create or replace function public.admin_assign_delivery_date_vendor(
  p_admin_username text,
  p_admin_password text,
  p_delivery_date date,
  p_vendor_code text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_vendor_code text := nullif(trim(p_vendor_code), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text; return;
  end if;

  if p_delivery_date is null or v_vendor_code is null then
    return query select false, 'Delivery date and vendor are required.'::text; return;
  end if;

  if extract(dow from p_delivery_date) = 1 then
    return query select false, 'Mondays are not available for delivery.'::text; return;
  end if;

  insert into public."DeliveryDateVendors" ("DeliveryDate", "VendorCode", "AssignedBy")
  values (p_delivery_date, v_vendor_code, p_admin_username)
  on conflict ("DeliveryDate", "VendorCode") do nothing;

  if not found then
    return query select false, 'Vendor already assigned to this date.'::text; return;
  end if;

  return query select true, 'Vendor assigned.'::text;
end;
$$;

drop function if exists public.admin_remove_delivery_date_vendor(text, text, date, text);

create or replace function public.admin_remove_delivery_date_vendor(
  p_admin_username text,
  p_admin_password text,
  p_delivery_date date,
  p_vendor_code text
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

  delete from public."DeliveryDateVendors"
  where "DeliveryDate" = p_delivery_date and "VendorCode" = p_vendor_code;
end;
$$;

grant execute on function public.staff_list_delivery_date_vendors(text, text, date, date) to anon;
grant execute on function public.admin_assign_delivery_date_vendor(text, text, date, text) to anon;
grant execute on function public.admin_remove_delivery_date_vendor(text, text, date, text) to anon;
