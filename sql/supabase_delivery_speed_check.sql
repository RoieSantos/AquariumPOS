-- READ-ONLY speed check for the Delivery calendar / Driver Route View (no data or functions are changed).
-- Times each database call delivery.html makes when it opens, and lists any warehouse/vendor whose
-- address has no good saved geocode - the page re-geocodes those (Google + a save) on EVERY open of
-- the Driver Route View / day map, one after another.
--
-- HOW TO RUN: replace YOUR_USERNAME / YOUR_PASSWORD below with a real staff login (ideally the
-- account that's slow, e.g. a Delivery Team login), run the whole file, then CLEAR the password
-- back out before saving - the SQL editor keeps query history.
--
-- Results: one table. "ms" = best of 2 runs, in milliseconds. Safe to re-run any time.

create temp table if not exists _dl_speed (seq int, section text, test text, ms numeric, info text);
truncate _dl_speed;

do $$
declare
  v_user text := 'YOUR_USERNAME';
  v_pw   text := 'YOUR_PASSWORD';
  v_from date := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_to   date := (date_trunc('month', (now() at time zone 'Asia/Manila')::date) + interval '1 month')::date;
  v_seq  int := 0;
  v_t    timestamptz;
  v_best numeric;
  v_n    bigint;
  r      int;
  -- Each call the page makes when it opens: label | SQL ($1 user, $2 password, $3 month start, $4 month end)
  v_tests text[][] := array[
    ['password check (is_staff_authorized - runs inside EVERY call)', 'select public.is_staff_authorized($1, $2)::int'],
    ['Google Maps key (background)', 'select count(*) from public.admin_get_public_portal_setting($1, $2, ''GOOGLE_MAPS_API_KEY'')'],
    ['warehouses lookup', 'select count(*) from public.staff_search_warehouses(p_admin_username => $1, p_admin_password => $2, p_search => null, p_limit => 100)'],
    ['vendors lookup', 'select count(*) from public.staff_search_vendors(p_admin_username => $1, p_admin_password => $2, p_search => null, p_limit => 100)'],
    ['route schedule', 'select count(*) from public.staff_get_delivery_route_schedule($1, $2)'],
    ['this month''s stops', 'select count(*) from public.admin_list_delivery_stops($1, $2, $3, $4)'],
    ['this month''s date vendors', 'select count(*) from public.staff_list_delivery_date_vendors($1, $2, $3, $4)'],
    ['driver locations (Driver Route View / today''s map)', 'select count(*) from public.admin_get_driver_locations($1, $2)']
  ];
begin
  if not public.is_staff_authorized(v_user, v_pw) then
    insert into _dl_speed values (0, '0 setup', 'LOGIN FAILED - fill in YOUR_USERNAME / YOUR_PASSWORD at the top', null, null);
    return;
  end if;

  for i in 1 .. array_length(v_tests, 1) loop
    v_best := null;
    begin
      for r in 1 .. 2 loop
        v_t := clock_timestamp();
        execute v_tests[i][2] into v_n using v_user, v_pw, v_from, v_to;
        v_best := least(coalesce(v_best, 1e12), extract(epoch from clock_timestamp() - v_t) * 1000);
      end loop;
      v_seq := v_seq + 1;
      insert into _dl_speed values (v_seq, '1 page-open calls', v_tests[i][1], round(v_best), v_n || ' row(s)');
    exception when others then
      v_seq := v_seq + 1;
      insert into _dl_speed values (v_seq, '1 page-open calls', v_tests[i][1], null, 'ERROR: ' || sqlerrm);
    end;
  end loop;
end;
$$;

select seq, section, test, ms, info from _dl_speed
union all
-- Re-geocoded on every map open (delivery.js resolveFixedRouteWarehouseMarkers): has an Address, but
-- no 'ok' geocode for that exact address.
select 100, '2 warehouses re-geocoded every open', w."Name"::text, null,
       coalesce(w."GeocodeStatus", 'never geocoded') || ' | address: ' || w."Address"
from public."Warehouses" w
where nullif(trim(coalesce(w."Address", '')), '') is not null
  and (w."GeocodeStatus" is distinct from 'ok' or w."GeocodedAddress" is distinct from w."Address")
union all
select 200, '3 vendors re-geocoded every open', v."Name"::text, null,
       coalesce(v."GeocodeStatus", 'never geocoded') || ' | address: ' || v."Address"
from public."Vendors" v
where nullif(trim(coalesce(v."Address", '')), '') is not null
  and (v."GeocodeStatus" is distinct from 'ok' or v."GeocodedAddress" is distinct from v."Address")
union all
select 300, '4 route schedule tags', 'warehouses / vendors on the weekly schedule', null,
       (select count(*) from public."DeliveryRouteScheduleWarehouses") || ' warehouse tag(s) / '
       || (select count(*) from public."DeliveryRouteScheduleVendors") || ' vendor tag(s)'
order by 2, 1, 3;
