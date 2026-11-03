-- Delivery: combined drops also match by the customer's Messenger PSID - per "can we use PSID? is that
-- fair" -> "yes thats correct". Rule: same person + same day + same place = one trip, one fee.
--
-- Before (supabase_delivery_combined_drops.sql): a drop = same date + same customer NAME + same address.
-- "Christopher Salaver" and "Christopher T. Salaver", or an order with no address typed, never combined.
--
-- Now, on one date:
--   1. Stops with the same PSID and the same address are one drop, whatever the names say.
--   2. A PSID stop with NO address joins that PSID's address on the date - only when the PSID has exactly
--      one address that day (two different addresses = two trips, so a blank one stays on its own).
--   3. Same PSID, different addresses = separate drops (separate fees).
--   4. No PSID (untagged walk-in / advance, old Pancake orders) = name + address, exactly as before.
-- The drop key stays "<name>|<address>" - a PSID drop uses the name on its first-booked order - so the
-- drops that already existed keep their key (and their Charge once / Per order choice).
--
-- PSID per stop: OnlineOrders."WalkinPsid" (POS walk-in tagged), AdvanceOrders."CustomerPsid" (advance
-- tagged), AutomatedOrders."GmaPsid" / "Psid" (bot, Conversations "+ New Order", Order Now - for a
-- confirmed order through OrderNo = OrderID, or PancakeReceiptNo for Pancake-era ones). PSIDs are
-- page-scoped: the same person on two pages has two PSIDs, which only means a missed match (a fee as
-- before), never a wrong one.
--
-- 1. _delivery_drop_address (new) - the address half of _delivery_drop_key.
-- 2. _delivery_drop_keys(start, end) (new) - every stop's drop key, worked out per date.
-- 3. _delivery_drop_members - drop_key from (2). Otherwise unchanged.
-- 4. admin_list_delivery_stops - drop_key from (2). Otherwise unchanged (same columns).
-- 5. Rebalance also when a walk-in / advance order gets tagged to a customer (WalkinPsid / CustomerPsid).
-- 6. Re-combines the drops from today on.
--
-- Run AFTER supabase_delivery_combined_drops.sql. If that is re-run, run this one again. Safe to re-run.
-- No page change needed (delivery.js already groups by drop_key). Ends with one result query.

-- ---------------------------------------------------------------------------
-- 1. Address half of the drop key (same rule as _delivery_drop_key: placeholder -> geocoded address).

create or replace function public._delivery_drop_address(p_address text, p_geocoded text)
returns text
language sql
immutable
as $$
  select nullif(regexp_replace(lower(
           case when lower(trim(coalesce(p_address, ''))) in ('', 'walkin') then coalesce(p_geocoded, '') else p_address end
         ), '[^a-z0-9]+', '', 'g'), '');
$$;

-- ---------------------------------------------------------------------------
-- 2. Every stop's drop key in [p_start, p_end). Null = never grouped.

create or replace function public._delivery_drop_keys(p_start date, p_end date)
returns table(stop_id uuid, drop_key text)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with base as (
    select s."StopID" as sid,
           s."DeliveryDate" as d,
           s."CreatedAtUtc" as created_at,
           nullif(nullif(regexp_replace(lower(coalesce(
             coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''),
                      o."CustomerName", a."CustomerName", ao."CustomerName"), '')), '[^a-z0-9]+', '', 'g'), ''),
             'poswalkinorders') as n0,
           public._delivery_drop_address(
             coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress", ao."DeliveryAddress"),
             s."GeocodedAddress") as ad0,
           coalesce(nullif(trim(o."WalkinPsid"), ''), nullif(trim(a."CustomerPsid"), ''),
                    nullif(trim(ao."GmaPsid"), ''), nullif(trim(ao."Psid"), ''),
                    nullif(trim(oa."GmaPsid"), ''), nullif(trim(oa."Psid"), ''),
                    nullif(trim(orc."GmaPsid"), ''), nullif(trim(orc."Psid"), '')) as psid
    from public."DeliveryStops" s
    left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AutomatedOrders" ao on ao."OrderNo" = s."AutomatedOrderNo"
    -- A confirmed AO order keeps its AO number as OnlineOrders.OrderID; Pancake-era ones went by receipt no.
    left join public."AutomatedOrders" oa on oa."OrderNo" = s."OrderID"
    left join lateral (
      select x."GmaPsid", x."Psid" from public."AutomatedOrders" x
      where s."OrderID" is not null and oa."OrderNo" is null and x."PancakeReceiptNo" = s."OrderID"
      limit 1
    ) orc on true
    where s."DeliveryDate" >= p_start and s."DeliveryDate" < p_end
  ),
  -- The one address a PSID has on a date (null when it has none, or more than one).
  psid_addr as (
    select b.d, b.psid, case when count(distinct b.ad0) = 1 then min(b.ad0) end as ad
    from base b
    where b.psid is not null and b.ad0 is not null
    group by b.d, b.psid
  ),
  resolved as (
    select b.*, coalesce(b.ad0, pa.ad) as ad
    from base b
    left join psid_addr pa on pa.d = b.d and pa.psid = b.psid
  ),
  -- One name per PSID + address + date: the first-booked order's.
  canon as (
    select distinct on (r.d, r.psid, r.ad) r.d, r.psid, r.ad, r.n0 as n
    from resolved r
    where r.psid is not null and r.ad is not null and r.n0 is not null
    order by r.d, r.psid, r.ad, r.created_at, r.sid
  )
  select r.sid,
         case when r.ad is null then null
              when r.psid is not null
                then coalesce(c.n, 'psid' || regexp_replace(lower(r.psid), '[^a-z0-9]+', '', 'g')) || '|' || r.ad
              when r.n0 is null then null
              else r.n0 || '|' || r.ad end
  from resolved r
  left join canon c on c.d = r.d and c.psid = r.psid and c.ad = r.ad;
$$;

revoke all on function public._delivery_drop_keys(date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Drop members - drop_key from _delivery_drop_keys. Otherwise as supabase_delivery_combined_drops.sql.

create or replace function public._delivery_drop_members(p_date date)
returns table(
  stop_id uuid,
  drop_key text,
  kind text,
  order_id text,
  created_at timestamptz,
  manual_fee numeric,
  order_fee numeric,
  current_fee numeric,
  waived numeric,
  waived_on text,
  combined_with uuid,
  balance numeric,
  is_done boolean,
  is_closed boolean,
  order_editable boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s."StopID",
         dk.drop_key,
         case when s."AdvanceTransactionNo" is not null then 'advance'
              when s."AutomatedOrderNo" is not null then 'automated'
              else 'online' end,
         s."OrderID"::text,
         s."CreatedAtUtc",
         s."ManualDeliveryFee",
         o."DeliveryFee",
         case when s."AdvanceTransactionNo" is not null then coalesce(s."ManualDeliveryFee", 0)
              else coalesce(s."ManualDeliveryFee", o."DeliveryFee", 0) end,
         s."CombinedFeeWaived",
         s."CombinedFeeWaivedOn"::text,
         s."FeeCombinedWithStopID",
         -- Same balance the stops list shows.
         coalesce(o."Balance", a."Balance") + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
         exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID")
           or o."DeliveredAtUtc" is not null or p."DeliveredAtUtc" is not null,
         lower(trim(coalesce(o."Status", ''))) in ('cancelled', 'canceled', 'cancel', 'returned', 'returning'),
         -- Same rule as admin_set_portal_order_delivery_fee.
         case when o."OrderID" is null then false
              when coalesce(o."ReceivedAtShop", false)
                then lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled', 'returned', 'returning')
                     and o."PickedUpAtUtc" is null and o."DeliveredAtUtc" is null
              else lower(trim(coalesce(o."Status", ''))) not in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning')
         end
  from public."DeliveryStops" s
  left join public._delivery_drop_keys(p_date, p_date + 1) dk on dk.stop_id = s."StopID"
  left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
  left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
  left join public."AdvanceOrderProduction" p on p."TransactionNo" = s."AdvanceTransactionNo"
  where s."DeliveryDate" = p_date;
$$;

revoke all on function public._delivery_drop_members(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Stops list - drop_key from _delivery_drop_keys. Otherwise as supabase_delivery_combined_drops.sql.

create or replace function public.admin_list_delivery_stops(p_admin_username text, p_admin_password text, p_start_date date, p_end_date date)
returns table(
  stop_id uuid,
  delivery_date date,
  truck_id uuid,
  truck_name text,
  stop_sequence int,
  order_id text,
  customer_name text,
  status text,
  shipping_address text,
  money_to_collect numeric,
  balance numeric,
  notes text,
  latitude numeric,
  longitude numeric,
  geocode_status text,
  geocoded_address text,
  route_name text,
  created_by text,
  note_print text,
  contact_number text,
  is_manual_address boolean,
  source text,
  delivery_fee numeric,
  is_manual_delivery_fee boolean,
  drop_key text,
  drop_fee_mode text,
  fee_combined_with text,
  combined_fee_waived numeric
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
    select s."StopID", s."DeliveryDate", s."TruckID", t."TruckName"::text, s."StopSequence",
           coalesce(o."OrderID", 'ADV-' || a."TransactionNo", ao."OrderNo")::text,
           coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''),
                    o."CustomerName", a."CustomerName", ao."CustomerName")::text,
           case when a."TransactionNo" is not null
                  then 'Advance' || coalesce(' - ' || public._advance_order_prod_status(p), '')
                when ao."OrderNo" is not null
                  then ao."Status" || public._automated_order_pending_label(ao."PancakeSyncStatus")
                else o."Status" end::text,
           coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress", ao."DeliveryAddress")::text,
           -- + (manual fee - the order's own fee) once a manual fee is set.
           coalesce(o."MoneyToCollect", a."Balance", public._automated_order_total(ao."OrderNo"))
             + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
           coalesce(o."Balance", a."Balance", public._automated_order_total(ao."OrderNo"))
             + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
           s."Notes"::text,
           s."Latitude", s."Longitude", s."GeocodeStatus"::text, s."GeocodedAddress"::text,
           s."RouteName"::text, s."CreatedBy"::text,
           coalesce(
             nullif(trim(s."ManualNotePrint"), ''),
             nullif(trim(o."NotePrint"::text), ''),
             (select string_agg(nullif(trim(l."Note"::text), ''), '; ' order by l."LineID")
                from public."OnlineOrderLines" l
                where l."OrderID" = o."OrderID" and nullif(trim(l."Note"::text), '') is not null),
             nullif(trim(a."Order_Description"::text), ''),
             nullif(trim(ao."Notes"::text), '')
           ) as note_print,
           coalesce(nullif(trim(s."ManualContactNumber"), ''), nullif(trim(o."WalkinCustomerPhone"), ''),
                    nullif(trim(ao."CustomerPhone"), ''))::text as contact_number,
           (nullif(trim(s."ManualAddress"), '') is not null) as is_manual_address,
           case when a."TransactionNo" is not null then 'advance'
                when ao."OrderNo" is not null then 'automated'
                else 'online' end::text,
           coalesce(s."ManualDeliveryFee", o."DeliveryFee"),
           s."ManualDeliveryFee" is not null,
           dk.drop_key,
           case when dk.drop_key is null then null else coalesce(fm."FeeMode", 'once') end::text,
           coalesce(cs."OrderID", 'ADV-' || cs."AdvanceTransactionNo", cs."AutomatedOrderNo")::text,
           s."CombinedFeeWaived"
    from public."DeliveryStops" s
    left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AdvanceOrderProduction" p on p."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AutomatedOrders" ao on ao."OrderNo" = s."AutomatedOrderNo"
    join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
    left join public._delivery_drop_keys(p_start_date, p_end_date) dk on dk.stop_id = s."StopID"
    left join public."DeliveryDropFeeModes" fm on fm."DeliveryDate" = s."DeliveryDate" and fm."DropKey" = dk.drop_key
    left join public."DeliveryStops" cs on cs."StopID" = s."FeeCombinedWithStopID"
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
      and (o."OrderID" is not null or a."TransactionNo" is not null or ao."OrderNo" is not null)
    order by s."DeliveryDate", s."StopSequence";
end;
$$;

grant execute on function public.admin_list_delivery_stops(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- 5. Rebalance when an order gets tagged to (or untagged from) a customer.

drop trigger if exists "TR_OnlineOrders_RebalanceDrops" on public."OnlineOrders";
create trigger "TR_OnlineOrders_RebalanceDrops"
  after update of "Status", "PortalDeliveryFee", "CustomerName", "WalkinCustomerName", "ShippingAddress", "WalkinPsid"
  on public."OnlineOrders"
  for each row
  when (OLD."Status" is distinct from NEW."Status"
     or OLD."PortalDeliveryFee" is distinct from NEW."PortalDeliveryFee"
     or OLD."CustomerName" is distinct from NEW."CustomerName"
     or OLD."WalkinCustomerName" is distinct from NEW."WalkinCustomerName"
     or OLD."ShippingAddress" is distinct from NEW."ShippingAddress"
     or OLD."WalkinPsid" is distinct from NEW."WalkinPsid")
  execute function public._online_orders_rebalance_drops();

create or replace function public._advance_orders_rebalance_drops()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_date date;
begin
  if coalesce(current_setting('rspet.delivery_drop_rebalance', true), 'off') = 'on' then
    return null;
  end if;
  begin
    for v_date in
      select distinct s."DeliveryDate" from public."DeliveryStops" s
      where s."AdvanceTransactionNo" = NEW."TransactionNo"
        and s."DeliveryDate" >= (now() at time zone 'Asia/Manila')::date - 7
    loop
      perform public._delivery_rebalance_date(v_date);
    end loop;
  exception when others then
    perform set_config('rspet.delivery_drop_rebalance', 'off', true);
    raise warning 'Delivery drop fee rebalance failed for advance order %: %', NEW."TransactionNo", sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists "TR_AdvanceOrders_RebalanceDrops" on public."AdvanceOrders";
create trigger "TR_AdvanceOrders_RebalanceDrops"
  after update of "CustomerPsid", "CustomerName" on public."AdvanceOrders"
  for each row
  when (OLD."CustomerPsid" is distinct from NEW."CustomerPsid"
     or OLD."CustomerName" is distinct from NEW."CustomerName")
  execute function public._advance_orders_rebalance_drops();

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 6. Re-combine the drops already on the calendar from today on (stops already Done are left alone).

do $$
declare
  v_date date;
begin
  for v_date in
    select distinct "DeliveryDate" from public."DeliveryStops"
    where "DeliveryDate" >= (now() at time zone 'Asia/Manila')::date
    order by 1
  loop
    perform public._delivery_rebalance_date(v_date);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Verification - one result: pieces in place, then every combined drop from today on.

select 'setup' as section, x.item, x.ok as detail
from (values
  ('function _delivery_drop_keys', (to_regprocedure('public._delivery_drop_keys(date, date)') is not null)::text),
  ('_delivery_drop_members uses it',
     (pg_get_functiondef('public._delivery_drop_members(date)'::regprocedure) like '%_delivery_drop_keys%')::text),
  ('admin_list_delivery_stops uses it',
     (pg_get_functiondef('public.admin_list_delivery_stops(text, text, date, date)'::regprocedure) like '%_delivery_drop_keys%')::text),
  ('trigger TR_AdvanceOrders_RebalanceDrops',
     exists (select 1 from pg_trigger where tgname = 'TR_AdvanceOrders_RebalanceDrops')::text)
) as x(item, ok)
union all
select 'combined drop ' || s."DeliveryDate"::text,
       coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo"),
       case when s."FeeCombinedWithStopID" is null then 'carries the fee'
            else 'combined with ' || coalesce(c."OrderID", 'ADV-' || c."AdvanceTransactionNo", c."AutomatedOrderNo")
                 || coalesce(' - fee ' || s."CombinedFeeWaived"::text || ' taken off', '')
       end || ' [' || k.drop_key || ']'
from public."DeliveryStops" s
join public._delivery_drop_keys((now() at time zone 'Asia/Manila')::date, (now() at time zone 'Asia/Manila')::date + 60) k
  on k.stop_id = s."StopID"
left join public."DeliveryStops" c on c."StopID" = s."FeeCombinedWithStopID"
where k.drop_key is not null
  and (select count(*) from public._delivery_drop_keys(s."DeliveryDate", s."DeliveryDate" + 1) k2
       where k2.drop_key = k.drop_key) >= 2;
