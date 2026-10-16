-- Production Shelf Map - DEMAND FORECAST + SUGGESTED MINIMUMS (Phases 1-2), per "can we build
-- forecasting?" -> "okay lets build this". Phase 0 (supabase_forecast_data_check.sql) showed ~12
-- months of order history at Amaya and ~7 at GMA - enough for recency-weighted forecasts, not yet for
-- yearly seasonality.
--
-- WHAT IT DOES
-- Nightly (pg_cron, 02:30 Manila), for every product linked to a rack at each location - the same
-- grouping as the page's Stock list / Minimums view, keyed (WarehouseId, ItemCode, VariantId):
--   1. Weekly units sold at that location over the last HistoryWeeks complete weeks (default 26),
--      from OnlineOrders + OnlineOrderLines (walk-ins included), same "counts as a sale" rule as
--      ledger sales posting (_ile_order_counts_as_sale), dated by the order's "Date". Weeks before the
--      product's first sale at the location are left out, so a new product isn't diluted by zeros.
--      Lines match a rack the way the page matches serials (unitFitsSpot): a one-variant rack -> that
--      VariationId; an "Any variant" rack -> every line of the item or its variants.
--   2. Demand pattern + method:
--        smooth       - sold in at least half the weeks -> simple exponential smoothing (alpha 0.2)
--        intermittent - sold in 3+ weeks, under half    -> Croston / SBA (alpha 0.1), built for
--                                                           sporadic demand like 0, 0, 2, 0, 1
--        rare         - sold in 1-2 weeks               -> average shown, no suggestion (keep manual)
--        new          - under 4 weeks since first sale  -> average shown, no suggestion yet
--        no sales     - nothing in the window
--   3. Build lead time, from Production Order history (created -> finished, last 180 days, median):
--      this product's own orders into this location if there are 3+, else every order into the
--      location if 3+, else DefaultLeadTimeDays. The source is stored so the page can say which.
--   4. Suggested minimum = what sells during (lead time + review days) + safety stock:
--        ceil( daily x cover + Z x daily-std-dev x sqrt(cover) ),  cover = lead time + ReviewDays
--      Z 1.65 = enough stock for ~95% of build cycles.
--
-- NOTHING EXISTING CHANGES. The page only SHOWS the suggestion next to the minimum; a minimum changes
-- only when a Super User / Production Manager presses "Use" and then Save (the existing
-- admin_save_production_shelf_minimums). Low-stock status, auto production orders and the item ledger
-- are untouched.
--
-- ACCURACY: each run also keeps that week's forecast in ProductionForecastLog (one row per product per
-- week), so forecast vs actual can be measured once a few weeks have built up.
--
--   staff_list_production_forecast(p_warehouse_id)   - any staff who can open the page.
--   admin_refresh_production_forecast()               - Super User / Production Manager ("Recalculate").
--   ProductionForecastSetup                           - DefaultLeadTimeDays / ReviewDays / ServiceZ /
--                                                       HistoryWeeks; edit with an update, then refresh.
--
-- KNOWN LIMIT: weeks a product was out of stock show as zero sales, so a product that is often out
-- is under-forecast. Advance orders taken in the POS aren't counted yet.
--
-- Run AFTER supabase_production_shelf_minimums.sql, supabase_item_ledger_sales.sql
-- (_ile_order_counts_as_sale) and supabase_production_orders.sql. Safe to re-run.

-- ============================================================================
-- 1. Tables
-- ============================================================================

create table if not exists public."ProductionForecastSetup" (
    "Id" boolean primary key default true check ("Id"),
    "DefaultLeadTimeDays" int not null default 7 check ("DefaultLeadTimeDays" between 0 and 120),
    "ReviewDays" int not null default 7 check ("ReviewDays" between 0 and 60),
    "ServiceZ" numeric(5, 2) not null default 1.65 check ("ServiceZ" between 0 and 4),
    "HistoryWeeks" int not null default 26 check ("HistoryWeeks" between 4 and 104),
    "UpdatedAtUtc" timestamptz not null default now()
);

insert into public."ProductionForecastSetup" ("Id") values (true) on conflict ("Id") do nothing;

create table if not exists public."ProductionForecast" (
    "WarehouseId" varchar(100) not null,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100) not null default '',
    "Pattern" varchar(20) not null,
    "Method" varchar(30) not null,
    "WeeksInWindow" int not null,
    "WeeksSold" int not null,
    "UnitsInWindow" numeric(18, 2) not null,
    "WeeklyDemand" numeric(18, 3) not null,
    "WeeklyStdDev" numeric(18, 3) not null,
    "LeadTimeDays" int not null,
    "LeadTimeSource" varchar(20) not null,
    "ReviewDays" int not null,
    "SuggestedMin" int,
    "FirstSaleDate" date,
    "LastSaleDate" date,
    "ComputedAtUtc" timestamptz not null default now(),
    constraint "PK_ProductionForecast" primary key ("WarehouseId", "ItemCode", "VariantId")
);

-- The weekly units the forecast was made from (one per week from SeriesStart, Monday-based), so the
-- page's Forecast charts need no second query over the order history.
alter table public."ProductionForecast" add column if not exists "SeriesStart" date;
alter table public."ProductionForecast" add column if not exists "WeeklySeries" numeric[];

create table if not exists public."ProductionForecastLog" (
    "WeekStart" date not null,
    "WarehouseId" varchar(100) not null,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100) not null default '',
    "Method" varchar(30) not null,
    "WeeklyDemand" numeric(18, 3) not null,
    "ComputedAtUtc" timestamptz not null default now(),
    constraint "PK_ProductionForecastLog" primary key ("WeekStart", "WarehouseId", "ItemCode", "VariantId")
);

alter table public."ProductionForecastSetup" enable row level security;
alter table public."ProductionForecast" enable row level security;
alter table public."ProductionForecastLog" enable row level security;
revoke all on public."ProductionForecastSetup", public."ProductionForecast", public."ProductionForecastLog" from anon, authenticated;

-- ============================================================================
-- 2. Refresh (internal - run by cron and by admin_refresh_production_forecast)
-- ============================================================================

create or replace function public._production_forecast_refresh()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_setup record;
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_week_end date;     -- start of the current (incomplete) week - excluded
  v_week_start date;   -- first week in the window
  r record;
  v_n int;
  v_nz int;
  v_total numeric;
  v_mean numeric;
  v_sd numeric;
  v_x numeric;
  v_level numeric;
  v_z numeric;
  v_p numeric;
  v_q int;
  v_seen boolean;
  v_i int;
  v_pattern text;
  v_method text;
  v_fc numeric;
  v_lead int;
  v_lead_src text;
  v_cover numeric;
  v_suggest int;
  v_count int := 0;
begin
  -- One refresh at a time (cron + a "Recalculate" click).
  if not pg_try_advisory_xact_lock(hashtext('production_forecast_refresh')) then
    return 0;
  end if;

  select * into v_setup from public."ProductionForecastSetup" limit 1;
  v_week_end := date_trunc('week', v_today)::date;
  v_week_start := v_week_end - 7 * v_setup."HistoryWeeks";

  for r in
    with products as (
      select distinct sh."WarehouseId"::text as warehouse_id, sp."ItemCode"::text as item_code,
             coalesce(sp."VariantId", '')::text as variant_id
      from public."ProductionShelfSpots" sp
      join public."ProductionShelves" sh on sh."Id" = sp."ShelfId"
      where nullif(trim(coalesce(sp."ItemCode", '')), '') is not null
    ),
    sale_lines as (
      select coalesce(o."LocationID", '') as warehouse_id, o."Date" as sale_date,
             coalesce(v."ItemCode", l."ItemCode") as item_code, v."MainItemCode" as main_item_code,
             nullif(trim(coalesce(l."VariationId", '')), '') as variation_id, l."Quantity" as qty
      from public."OnlineOrders" o
      join public."OnlineOrderLines" l on l."OrderID" = o."OrderID"
      left join public."Variants" v on v."VariationId" = l."VariationId"
      where public._ile_order_counts_as_sale(o."Status") and o."Date" is not null and o."Date" < v_week_end
        and coalesce(l."Quantity", 0) > 0
    ),
    matched as (
      select p.warehouse_id, p.item_code, p.variant_id, sl.sale_date, sl.qty
      from products p
      join sale_lines sl
        on sl.warehouse_id = p.warehouse_id
       and case when p.variant_id <> '' then sl.variation_id = p.variant_id
                else sl.item_code = p.item_code or sl.main_item_code = p.item_code end
    ),
    firsts as (
      select warehouse_id, item_code, variant_id, min(sale_date) as first_sale, max(sale_date) as last_sale
      from matched group by warehouse_id, item_code, variant_id
    ),
    weekly as (
      select warehouse_id, item_code, variant_id, date_trunc('week', sale_date)::date as wk, sum(qty) as qty
      from matched where sale_date >= v_week_start
      group by warehouse_id, item_code, variant_id, date_trunc('week', sale_date)::date
    )
    select p.warehouse_id, p.item_code, p.variant_id, f.first_sale, f.last_sale,
      greatest(v_week_start, date_trunc('week', coalesce(f.first_sale, v_week_end))::date) as series_start,
      (select array_agg(coalesce(w.qty, 0) order by g.wk)
         from generate_series(greatest(v_week_start, date_trunc('week', coalesce(f.first_sale, v_week_end))::date),
                              v_week_end - 7, interval '7 days') as g(wk)
         left join weekly w on w.warehouse_id = p.warehouse_id and w.item_code = p.item_code
                           and w.variant_id = p.variant_id and w.wk = g.wk::date) as series
    from products p
    left join firsts f on f.warehouse_id = p.warehouse_id and f.item_code = p.item_code and f.variant_id = p.variant_id
  loop
    v_n := coalesce(array_length(r.series, 1), 0);
    v_nz := 0; v_total := 0;
    for v_i in 1 .. v_n loop
      v_total := v_total + r.series[v_i];
      if r.series[v_i] > 0 then v_nz := v_nz + 1; end if;
    end loop;
    v_mean := case when v_n > 0 then v_total / v_n else 0 end;
    v_sd := 0;
    if v_n > 1 then
      for v_i in 1 .. v_n loop
        v_sd := v_sd + (r.series[v_i] - v_mean) ^ 2;
      end loop;
      v_sd := sqrt(v_sd / (v_n - 1));
    end if;

    v_pattern := case
      when v_total = 0 then 'no sales'
      when v_n < 4 then 'new'
      when v_nz * 2 >= v_n then 'smooth'
      when v_nz >= 3 then 'intermittent'
      else 'rare'
    end;

    if v_pattern = 'smooth' then
      -- Simple exponential smoothing, started from the average of the first 4 weeks.
      v_method := 'Exp. smoothing';
      v_level := 0;
      for v_i in 1 .. least(4, v_n) loop v_level := v_level + r.series[v_i]; end loop;
      v_level := v_level / least(4, v_n);
      for v_i in 1 .. v_n loop
        v_level := 0.2 * r.series[v_i] + 0.8 * v_level;
      end loop;
      v_fc := v_level;
    elsif v_pattern = 'intermittent' then
      -- Croston with the Syntetos-Boylan correction: smooth the size of a sale (z) and the weeks
      -- between sales (p) separately; demand per week = (1 - a/2) * z / p.
      v_method := 'Croston (SBA)';
      v_seen := false; v_q := 1;
      for v_i in 1 .. v_n loop
        v_x := r.series[v_i];
        if v_x > 0 then
          if not v_seen then
            v_z := v_x; v_p := v_i; v_seen := true;
          else
            v_z := v_z + 0.1 * (v_x - v_z);
            v_p := v_p + 0.1 * (v_q - v_p);
          end if;
          v_q := 1;
        elsif v_seen then
          v_q := v_q + 1;
        end if;
      end loop;
      v_fc := 0.95 * v_z / greatest(v_p, 1);
    else
      v_method := 'Average only';
      v_fc := v_mean;
    end if;

    -- Build lead time: median days created -> finished over the last 180 days.
    select ceil(percentile_cont(0.5) within group (order by extract(epoch from (po."FinishedAtUtc" - po."CreatedAtUtc")) / 86400)), count(*)
      into v_lead, v_i
    from public."ProductionOrders" po
    where po."WarehouseId" = r.warehouse_id and po."Status" = 'Finished' and po."FinishedAtUtc" is not null
      and po."FinishedAtUtc" > now() - interval '180 days'
      and exists (
        select 1 from public."ProductionOrderLines" pl
        left join public."Variants" v on v."VariationId" = pl."VariantId"
        where pl."ProdOrderNo" = po."No"
          and case when r.variant_id <> '' then pl."VariantId" = r.variant_id
                   else pl."ItemCode" = r.item_code or v."MainItemCode" = r.item_code end
      );
    v_lead_src := 'this product';
    if coalesce(v_i, 0) < 3 then
      select ceil(percentile_cont(0.5) within group (order by extract(epoch from (po."FinishedAtUtc" - po."CreatedAtUtc")) / 86400)), count(*)
        into v_lead, v_i
      from public."ProductionOrders" po
      where po."WarehouseId" = r.warehouse_id and po."Status" = 'Finished' and po."FinishedAtUtc" is not null
        and po."FinishedAtUtc" > now() - interval '180 days';
      v_lead_src := 'location';
    end if;
    if coalesce(v_i, 0) < 3 or v_lead is null then
      v_lead := v_setup."DefaultLeadTimeDays";
      v_lead_src := 'default';
    end if;
    v_lead := least(greatest(v_lead, 1), 120);

    v_cover := v_lead + v_setup."ReviewDays";
    v_suggest := case
      when v_pattern in ('smooth', 'intermittent') and v_fc > 0 then
        greatest(1, ceil((v_fc / 7) * v_cover + v_setup."ServiceZ" * (v_sd / sqrt(7)) * sqrt(v_cover))::int)
    end;

    insert into public."ProductionForecast" (
      "WarehouseId", "ItemCode", "VariantId", "Pattern", "Method", "WeeksInWindow", "WeeksSold", "UnitsInWindow",
      "WeeklyDemand", "WeeklyStdDev", "LeadTimeDays", "LeadTimeSource", "ReviewDays", "SuggestedMin",
      "FirstSaleDate", "LastSaleDate", "SeriesStart", "WeeklySeries", "ComputedAtUtc")
    values (
      r.warehouse_id, r.item_code, r.variant_id, v_pattern, v_method, v_n, v_nz, v_total,
      round(v_fc, 3), round(v_sd, 3), v_lead, v_lead_src, v_setup."ReviewDays", v_suggest,
      r.first_sale, r.last_sale, case when v_n > 0 then r.series_start end, coalesce(r.series, '{}'), now())
    on conflict ("WarehouseId", "ItemCode", "VariantId") do update set
      "Pattern" = excluded."Pattern", "Method" = excluded."Method", "WeeksInWindow" = excluded."WeeksInWindow",
      "WeeksSold" = excluded."WeeksSold", "UnitsInWindow" = excluded."UnitsInWindow",
      "WeeklyDemand" = excluded."WeeklyDemand", "WeeklyStdDev" = excluded."WeeklyStdDev",
      "LeadTimeDays" = excluded."LeadTimeDays", "LeadTimeSource" = excluded."LeadTimeSource",
      "ReviewDays" = excluded."ReviewDays", "SuggestedMin" = excluded."SuggestedMin",
      "FirstSaleDate" = excluded."FirstSaleDate", "LastSaleDate" = excluded."LastSaleDate",
      "SeriesStart" = excluded."SeriesStart", "WeeklySeries" = excluded."WeeklySeries",
      "ComputedAtUtc" = excluded."ComputedAtUtc";

    -- This week's forecast, kept for forecast-vs-actual later (last run of the week wins).
    insert into public."ProductionForecastLog" ("WeekStart", "WarehouseId", "ItemCode", "VariantId", "Method", "WeeklyDemand", "ComputedAtUtc")
    values (v_week_end, r.warehouse_id, r.item_code, r.variant_id, v_method, round(v_fc, 3), now())
    on conflict ("WeekStart", "WarehouseId", "ItemCode", "VariantId") do update set
      "Method" = excluded."Method", "WeeklyDemand" = excluded."WeeklyDemand", "ComputedAtUtc" = excluded."ComputedAtUtc";

    v_count := v_count + 1;
  end loop;

  -- Products no longer linked to any rack.
  delete from public."ProductionForecast" f
  where not exists (
    select 1 from public."ProductionShelfSpots" sp
    join public."ProductionShelves" sh on sh."Id" = sp."ShelfId"
    where sh."WarehouseId" = f."WarehouseId" and sp."ItemCode" = f."ItemCode" and coalesce(sp."VariantId", '') = f."VariantId"
  );

  return v_count;
end;
$$;

revoke execute on function public._production_forecast_refresh() from public, anon, authenticated;

create or replace function public.cron_refresh_production_forecast()
returns void
language sql
security definer
set search_path = public, extensions
as $$
  select public._production_forecast_refresh();
$$;

revoke execute on function public.cron_refresh_production_forecast() from public, anon, authenticated;

-- 02:30 Manila = 18:30 UTC. Re-running this file updates the same named job.
select cron.schedule(
  'refresh-production-forecast',
  '30 18 * * *',
  $$select public.cron_refresh_production_forecast();$$
);

-- ============================================================================
-- 3. RPCs for the page
-- ============================================================================

drop function if exists public.staff_list_production_forecast(text, text, text);

create or replace function public.staff_list_production_forecast(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(
  item_code text, variant_id text, pattern text, method text, weeks_in_window int, weeks_sold int,
  units_in_window numeric, weekly_demand numeric, weekly_std_dev numeric, lead_time_days int,
  lead_time_source text, review_days int, suggested_min int, first_sale_date date, last_sale_date date,
  series_start date, weekly_series numeric[], computed_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select f."ItemCode"::text, f."VariantId"::text, f."Pattern"::text, f."Method"::text, f."WeeksInWindow", f."WeeksSold",
           f."UnitsInWindow", f."WeeklyDemand", f."WeeklyStdDev", f."LeadTimeDays", f."LeadTimeSource"::text, f."ReviewDays",
           f."SuggestedMin", f."FirstSaleDate", f."LastSaleDate", f."SeriesStart", f."WeeklySeries", f."ComputedAtUtc"
    from public."ProductionForecast" f
    where f."WarehouseId" = p_warehouse_id;
end;
$$;

grant execute on function public.staff_list_production_forecast(text, text, text) to anon;

drop function if exists public.admin_refresh_production_forecast(text, text);

create or replace function public.admin_refresh_production_forecast(
  p_admin_username text,
  p_admin_password text
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can recalculate the forecast.';
  end if;
  return public._production_forecast_refresh();
end;
$$;

grant execute on function public.admin_refresh_production_forecast(text, text) to anon;

notify pgrst, 'reload schema';

-- First run now, so the page has numbers without waiting for tonight.
select public._production_forecast_refresh();

-- Verification - one result: every product's forecast, by location.
select coalesce(w."Name", f."WarehouseId")::text as location, f."ItemCode"::text as item_code,
       case when f."VariantId" = '' then 'any variant' else coalesce(v."SKU", f."VariantId") end::text as variant,
       f."Pattern"::text as pattern, f."Method"::text as method, f."WeeksSold" || ' of ' || f."WeeksInWindow" as weeks_sold,
       f."UnitsInWindow" as units, f."WeeklyDemand" as per_week, f."LeadTimeDays" as lead_days,
       f."LeadTimeSource"::text as lead_source, f."SuggestedMin" as suggested_min, m."MinQty" as current_min
from public."ProductionForecast" f
left join public."Warehouses" w on w."ID" = f."WarehouseId"
left join public."Variants" v on v."VariationId" = nullif(f."VariantId", '')
left join public."ProductionShelfMinimums" m
  on m."WarehouseId" = f."WarehouseId" and m."ItemCode" = f."ItemCode" and m."VariantId" = f."VariantId"
order by 1, f."WeeklyDemand" desc;
