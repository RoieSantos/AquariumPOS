-- Manager KPI - scoring + dashboard (per the "Manager KPI Scorecard System Requirements").
--
-- _manager_kpi(month, branch) scores one branch manager for one month. Weights (GP's 10% moved to Sales until
-- item costs are filled in - owner's call):
--   Financial   Sales Achievement 30%   actual / target (current month: vs target pro-rated to today)
--                                       110%+ = 100, 100-109 = 90, 90-99 = 70, below 90 = 50
--               Gross Profit       0%   OFF - only ~10% of sales have an item cost
--   Operations  Inventory Accuracy 15%  counted lines that matched / lines counted (InventoryCountLog)
--                                       99%+ = 100, 98% = 90, 95-97% = 70, below 95% = 50; no count in a closed month = 50
--               Stock Availability 15%  shelf SKUs in stock at month end / shelf SKUs the branch moved in the last
--                                       90 days (active items; sets, customized items, production items left out)
--   People      Team Attendance    10%  days with a timesheet / scheduled days (StandardWorkDaysPerMonth, pro-rated
--                                       to the days employed) - team = the branch's staff who are real employees
--               Employee Retention 10%  of the employees on the team at the start of the month, how many are still
--                                       active on it at the end (StaffStatusLog)
--   Leadership  SOP Compliance     10%  done / required: per open day before today, Opening + Closing + Cleaning
--                                       checklists (from the day checklists started) + POS end-of-day (Daily Sales
--                                       Report & Cash Reconciliation); plus 1 inventory count per closed month
--               Leadership         10%  owner's 1-5 rating on 6 areas, average / 5
-- KPIs with no proper target (availability 95%, attendance 97%, retention 90%, SOP 100%) score proportionally:
-- actual / target x 100, capped at 100.
-- A KPI that can't be measured (no target set, log not started yet, no team, not rated yet) is "No data" and its
-- weight is spread over the others - so an old month isn't failed for data the system didn't keep.
-- Final -> rating: 95+ Exceptional, 90-94 Outstanding, 80-89 Exceeds, 70-79 Meets, 60-69 Needs Improvement, <60
-- Unsatisfactory. Bonus: 95+ 100%, 90-94 75%, 80-89 50%, 70-79 25%, below 70 none (Super Users only).
--
-- Scores of a closed month are frozen with admin_close_manager_kpi_month (ManagerKpiSnapshots), so a later edit
-- to an old sale or count doesn't change a bonus already decided. Open months are calculated live.
--
-- Run AFTER supabase_manager_kpi_capture.sql, supabase_manager_report.sql (SalesTargets) and
-- supabase_monthly_sales_report.sql (_sales_totals_by_branch). Safe to re-run. Ends with ONE result.

create table if not exists public."ManagerKpiSnapshots" (
  "Month" date not null,
  "Warehouse" text not null,
  "Result" jsonb not null,
  "ClosedBy" text,
  "ClosedAtUtc" timestamptz not null default now(),
  primary key ("Month", "Warehouse")
);
alter table public."ManagerKpiSnapshots" enable row level security;
revoke all on table public."ManagerKpiSnapshots" from anon, authenticated;

-- First month the KPI is scored: the month the Item Ledger (portal stock) started. Earlier months only have
-- partial old data and would score as failures. Change the value in ManagerKpiSettings to move it.
insert into public."ManagerKpiSettings" ("Key", "Value")
select 'KPI_START', to_char(date_trunc('month', min(e."PostingDate")), 'YYYY-MM-DD')
from public."ItemLedgerEntries" e
having min(e."PostingDate") is not null
on conflict ("Key") do nothing;

create or replace function public._kpi_band_rating(p_score numeric)
returns text language sql immutable as $$
  select case when p_score is null then null
              when p_score >= 95 then 'Exceptional' when p_score >= 90 then 'Outstanding'
              when p_score >= 80 then 'Exceeds Expectations' when p_score >= 70 then 'Meets Expectations'
              when p_score >= 60 then 'Needs Improvement' else 'Unsatisfactory' end;
$$;

create or replace function public._kpi_bonus_pct(p_score numeric)
returns int language sql immutable as $$
  select case when p_score is null then null when p_score >= 95 then 100 when p_score >= 90 then 75
              when p_score >= 80 then 50 when p_score >= 70 then 25 else 0 end;
$$;

create or replace function public._manager_kpi(p_month date, p_wh text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_from date := date_trunc('month', p_month)::date;
  v_to date;
  v_end date;
  v_days_in int;
  v_days int;
  v_current boolean;
  v_wh_ids text[];
  v_count_start date;
  v_staff_start date;
  v_check_start date;
  v_std_days numeric;
  v_att_end date;
  k jsonb := '[]'::jsonb;
  -- working values
  v_a numeric; v_b numeric; v_c numeric; v_pct numeric; v_score numeric; v_note text;
  v_total numeric := 0; v_weight numeric := 0; v_final numeric;
  r record;
begin
  v_to := (v_from + interval '1 month')::date;
  v_end := least(v_to, v_today + 1);
  v_days_in := v_to - v_from;
  v_days := greatest(v_end - v_from, 0);
  v_current := v_end < v_to;
  v_wh_ids := array(select w."ID"::text from public."Warehouses" w where trim(w."Name") = p_wh);
  select "Value"::date into v_count_start from public."ManagerKpiSettings" where "Key" = 'COUNT_LOG_START';
  select "Value"::date into v_staff_start from public."ManagerKpiSettings" where "Key" = 'STAFF_LOG_START';
  select "Value"::date into v_check_start from public."ManagerKpiSettings" where "Key" = 'CHECKLIST_START';
  select coalesce(max("StandardWorkDaysPerMonth"), 26) into v_std_days from public."PayrollCutoffSettings";

  if v_from < coalesce((select "Value"::date from public."ManagerKpiSettings" where "Key" = 'KPI_START'), v_from) then
    return jsonb_build_object('month', v_from, 'through', v_end - 1, 'is_current', v_current, 'branch', p_wh,
                              'kpis', '[]'::jsonb, 'final', null, 'measured_weight', 0, 'rating', null, 'bonus_pct', null,
                              'note', 'Before the portal was in use - not scored');
  end if;

  -- ---------------------------------------------------------------- Sales Achievement (30%)
  select coalesce(sum(t.online_sales + t.walkin_sales), 0) into v_a
  from public._sales_totals_by_branch(v_from, v_end) t where t.warehouse = p_wh;
  select coalesce(sum(t."TargetAmount"), 0) into v_b from public."SalesTargets" t where t."Month" = v_from and t."Warehouse" = p_wh;
  if v_b > 0 then
    v_c := case when v_current then v_b * v_days / v_days_in else v_b end;
    v_pct := round(v_a / nullif(v_c, 0) * 100, 1);
    v_score := case when v_pct >= 110 then 100 when v_pct >= 100 then 90 when v_pct >= 90 then 70 else 50 end;
    v_note := case when v_current then format('%s sold vs %s expected by today (target %s)', round(v_a), round(v_c), round(v_b))
                   else format('%s sold of %s target', round(v_a), round(v_b)) end;
  else
    v_pct := null; v_score := null; v_note := 'No sales target set for this month';
  end if;
  k := k || jsonb_build_object('key', 'sales', 'category', 'Financial', 'name', 'Sales Achievement', 'weight', 30,
         'target', '100% of target', 'actual', v_pct, 'unit', '%', 'score', v_score, 'note', v_note,
         'sales', v_a, 'sales_target', v_b);

  -- ---------------------------------------------------------------- Gross Profit (off)
  k := k || jsonb_build_object('key', 'gp', 'category', 'Financial', 'name', 'Gross Profit', 'weight', 0,
         'target', '-', 'actual', null, 'unit', '%', 'score', null, 'off', true,
         'note', 'Off until item costs are filled in - its 10% is on Sales Achievement');

  -- ---------------------------------------------------------------- Inventory Accuracy (15%)
  select count(*), count(*) filter (where l."Difference" = 0) into v_a, v_b
  from public."InventoryCountLog" l
  where l."WarehouseId" = any(v_wh_ids) and l."PostingDate" >= v_from and l."PostingDate" < v_end;
  if v_a > 0 then
    v_pct := round(v_b / v_a * 100, 1);
    v_score := case when v_pct >= 99 then 100 when v_pct >= 98 then 90 when v_pct >= 95 then 70 else 50 end;
    v_note := format('%s of %s counted lines matched the system', v_b, v_a);
  elsif v_count_start is null or v_count_start > v_from then
    v_pct := null; v_score := null; v_note := format('Count log started %s', coalesce(v_count_start::text, '-'));
  elsif v_current then
    v_pct := null; v_score := null; v_note := 'No count posted yet this month';
  else
    v_pct := null; v_score := 50; v_note := 'No count posted this month';
  end if;
  k := k || jsonb_build_object('key', 'accuracy', 'category', 'Operations', 'name', 'Inventory Accuracy', 'weight', 15,
         'target', '99%+', 'actual', v_pct, 'unit', '%', 'score', v_score, 'note', v_note);

  -- ---------------------------------------------------------------- Stock Availability (15%)
  select count(*) filter (where s.recent), count(*) filter (where s.recent and s.bal > 0) into v_a, v_b
  from (
    select e."ItemCode", sum(e."Quantity") as bal, bool_or(e."PostingDate" >= v_end - 90) as recent
    from public."ItemLedgerEntries" e
    join public."Items" i on i."Code" = e."ItemCode"
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where e."WarehouseId" = any(v_wh_ids) and e."PostingDate" < v_end and coalesce(i."IsActive", true)
      and e."ItemCode" <> 'INC_EXP'
      and upper(e."ItemCode") !~ '^(CUSTOM|SERVICES|POS-FALLBACK|SET-)'
      and regexp_replace(upper(coalesce(c."Description", '')), '[^A-Z]', '', 'g') not in ('SET', 'CUSTOMIZEDITEM', 'SERVICES', 'PRODUCTIONITEM')
      and regexp_replace(upper(coalesce(i."CategoryCode", '')), '[^A-Z]', '', 'g') not in ('SET', 'CUSTOMIZEDITEM', 'SERVICES', 'PRODUCTIONITEM')
    group by e."ItemCode"
  ) s;
  if v_a > 0 then
    v_pct := round(v_b / v_a * 100, 1);
    v_score := least(100, round(v_pct / 95 * 100, 1));
    v_note := format('%s of %s shelf items in stock on %s', v_b, v_a, v_end - 1);
  else
    v_pct := null; v_score := null; v_note := 'No stock movements at this branch';
  end if;
  k := k || jsonb_build_object('key', 'availability', 'category', 'Operations', 'name', 'Stock Availability', 'weight', 15,
         'target', '95%+', 'actual', v_pct, 'unit', '%', 'score', v_score, 'note', v_note);

  -- ---------------------------------------------------------------- Team Attendance (10%)
  -- Timesheets are entered at the payroll cut-off, so a live month is only measured up to the latest timesheet
  -- date entered for anyone (otherwise the days not keyed in yet would count as absences).
  v_a := 0; v_b := 0; v_c := 0;
  v_att_end := v_end;
  if v_current then
    v_att_end := least(v_end, coalesce((select max(t."WorkDate") + 1 from public."PayrollTimesheetEntries" t
                                        where t."WorkDate" >= v_from and t."WorkDate" < v_end), v_from));
  end if;
  for r in
    select s."Username", greatest(v_from, coalesce(s."HireDate", v_from)) as start_day
    from public."StaffUsers" s
    where trim(s."WarehouseName") = p_wh and coalesce(s."IsActive", true)
      and public._kpi_is_employee(s."Username")
      and (s."HireDate" is null or s."HireDate" < v_att_end)
  loop
    v_c := v_c + 1;
    v_b := v_b + v_std_days * greatest(v_att_end - r.start_day, 0) / v_days_in;
    v_a := v_a + (select count(distinct t."WorkDate") from public."PayrollTimesheetEntries" t
                  where t."Username" = r."Username" and t."WorkDate" >= r.start_day and t."WorkDate" < v_att_end
                    and coalesce(t."HoursWorked", 1) > 0);
  end loop;
  if v_b > 0 then
    v_pct := round(v_a / v_b * 100, 1);
    v_score := least(100, round(v_pct / 97 * 100, 1));
    v_note := format('%s days worked of %s scheduled, %s staff%s', v_a, round(v_b, 1), v_c,
                     case when v_att_end < v_end then format(' (timesheets entered through %s)', v_att_end - 1) else '' end);
  elsif v_c > 0 then
    v_pct := null; v_score := null; v_note := 'No timesheets entered yet this month';
  else
    v_pct := null; v_score := null; v_note := 'No employees set to this branch in User Setup';
  end if;
  k := k || jsonb_build_object('key', 'attendance', 'category', 'People', 'name', 'Team Attendance', 'weight', 10,
         'target', '97%+', 'actual', v_pct, 'unit', '%', 'score', v_score, 'note', v_note);

  -- ---------------------------------------------------------------- Employee Retention (10%)
  if v_staff_start is null or v_staff_start > v_from then
    v_pct := null; v_score := null; v_note := format('Staff log started %s', coalesce(v_staff_start::text, '-'));
  else
    with at_start as (
      select distinct on (l."Username") l."Username", l."IsActive", l."WarehouseName"
      from public."StaffStatusLog" l
      where l."ChangedAtUtc" < (v_from::timestamp at time zone 'Asia/Manila')
      order by l."Username", l."ChangedAtUtc" desc, l."Id" desc
    ), at_end as (
      select distinct on (l."Username") l."Username", l."IsActive", l."WarehouseName"
      from public."StaffStatusLog" l
      where l."ChangedAtUtc" < (v_end::timestamp at time zone 'Asia/Manila')
      order by l."Username", l."ChangedAtUtc" desc, l."Id" desc
    )
    select count(*), count(*) filter (where e."IsActive" and trim(e."WarehouseName") = p_wh) into v_a, v_b
    from at_start s
    left join at_end e on e."Username" = s."Username"
    where s."IsActive" and trim(s."WarehouseName") = p_wh and public._kpi_is_employee(s."Username");
    if v_a > 0 then
      v_pct := round(v_b / v_a * 100, 1);
      v_score := least(100, round(v_pct / 90 * 100, 1));
      v_note := format('%s of %s employees still on the team', v_b, v_a);
    else
      v_pct := null; v_score := null; v_note := 'No employees on this branch at the start of the month';
    end if;
  end if;
  k := k || jsonb_build_object('key', 'retention', 'category', 'People', 'name', 'Employee Retention', 'weight', 10,
         'target', '90%+', 'actual', v_pct, 'unit', '%', 'score', v_score, 'note', v_note);

  -- ---------------------------------------------------------------- SOP Compliance (10%)
  with days as (
    select d from public._kpi_open_days(p_wh, v_from, v_end) d where d < v_today
  ), req as (
    select d,
           1 as eod_req,
           (select count(*) from public."TenderDeclarationHeader" h where trim(h."Warehouse") = p_wh and h."DeclDate" = days.d) > 0 as eod_done,
           case when v_check_start is not null and d >= v_check_start then 3 else 0 end as chk_req,
           case when v_check_start is not null and d >= v_check_start
                then (select count(*) from public."BranchChecklistEntries" e where e."Warehouse" = p_wh and e."CheckDate" = days.d) else 0 end as chk_done
    from days
  )
  select coalesce(sum(eod_req + chk_req), 0), coalesce(sum((eod_done::int) + chk_done), 0), count(*) into v_a, v_b, v_c from req;
  -- Monthly inventory count (closed months; the current month only counts once it's done).
  if exists (select 1 from public."InventoryCountLog" l where l."WarehouseId" = any(v_wh_ids) and l."PostingDate" >= v_from and l."PostingDate" < v_end)
     or exists (select 1 from public."ItemLedgerEntries" e where e."WarehouseId" = any(v_wh_ids)
                and e."DocumentType" in ('Phys. Inventory', 'Serial Phys. Inventory') and e."PostingDate" >= v_from and e."PostingDate" < v_end) then
    v_a := v_a + 1; v_b := v_b + 1;
  elsif not v_current then
    v_a := v_a + 1;
  end if;
  if v_a > 0 then
    v_pct := round(v_b / v_a * 100, 1);
    v_score := least(100, v_pct);
    v_note := format('%s of %s required tasks done over %s open days', v_b, v_a, v_c);
  else
    v_pct := null; v_score := null; v_note := 'No open days yet';
  end if;
  k := k || jsonb_build_object('key', 'sop', 'category', 'Leadership', 'name', 'SOP Compliance', 'weight', 10,
         'target', '100%', 'actual', v_pct, 'unit', '%', 'score', v_score, 'note', v_note);

  -- ---------------------------------------------------------------- Leadership & Initiative (10%)
  select * into r from public."ManagerLeadershipRatings" lr where lr."Month" = v_from and lr."Warehouse" = p_wh;
  if found then
    v_a := (r."ProblemSolving" + r."DecisionMaking" + r."TeamCoaching" + r."ProcessImprovement" + r."CustomerHandling" + r."Initiative") / 6.0;
    v_pct := round(v_a, 2);
    v_score := round(v_a / 5 * 100, 1);
    v_note := 'Average of 6 areas, rated by the owner';
  else
    v_pct := null; v_score := null; v_note := 'Not rated yet this month';
  end if;
  k := k || jsonb_build_object('key', 'leadership', 'category', 'Leadership', 'name', 'Leadership & Initiative', 'weight', 10,
         'target', '5 = Outstanding', 'actual', v_pct, 'unit', '/5', 'score', v_score, 'note', v_note,
         'rating', case when found then jsonb_build_object(
            'problem_solving', r."ProblemSolving", 'decision_making', r."DecisionMaking", 'team_coaching', r."TeamCoaching",
            'process_improvement', r."ProcessImprovement", 'customer_handling', r."CustomerHandling",
            'initiative', r."Initiative", 'notes', r."Notes") end);

  -- ---------------------------------------------------------------- Final
  select coalesce(sum((x->>'score')::numeric * (x->>'weight')::numeric), 0),
         coalesce(sum((x->>'weight')::numeric) filter (where x->>'score' is not null), 0)
    into v_total, v_weight
  from jsonb_array_elements(k) x where (x->>'weight')::numeric > 0 and x->>'score' is not null;
  v_final := case when v_weight > 0 then round(v_total / v_weight, 1) end;

  -- Weighted score per KPI on the re-spread weights (what each actually contributed to the final).
  k := (select jsonb_agg(x || jsonb_build_object(
          'effective_weight', case when x->>'score' is not null and v_weight > 0 then round((x->>'weight')::numeric / v_weight * 100, 1) else 0 end,
          'weighted_score', case when x->>'score' is not null and v_weight > 0
                                 then round((x->>'score')::numeric * (x->>'weight')::numeric / v_weight, 1) else null end))
        from jsonb_array_elements(k) x);

  return jsonb_build_object(
    'month', v_from, 'through', v_end - 1, 'is_current', v_current, 'branch', p_wh,
    'manager', public._kpi_branch_manager(p_wh),
    'manager_name', (select string_agg(coalesce(nullif(trim(s."DisplayName"), ''), s."Username"), ', ' order by s."Username")
                     from public."StaffUsers" s
                     where coalesce(s."StoreManager", false) and coalesce(s."IsActive", true)
                       and trim(s."WarehouseName") = p_wh and public._kpi_is_employee(s."Username")),
    'kpis', k, 'final', v_final, 'measured_weight', v_weight,
    'rating', public._kpi_band_rating(v_final), 'bonus_pct', public._kpi_bonus_pct(v_final)
  );
end;
$$;
revoke all on function public._manager_kpi(date, text) from public, anon, authenticated;

-- Branches that are scored: have a Store Manager, or a sales target that month.
create or replace function public._kpi_branches(p_month date)
returns setof text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select distinct trim(w."Name")::text
  from public."Warehouses" w
  where trim(w."Name") not ilike 'TESTING%'
    and (public._kpi_branch_manager(trim(w."Name")) is not null
         or exists (select 1 from public."SalesTargets" t where t."Month" = date_trunc('month', p_month)::date
                    and t."Warehouse" = trim(w."Name") and t."TargetAmount" > 0))
  order by 1;
$$;
revoke all on function public._kpi_branches(date) from public, anon, authenticated;

-- Frozen snapshot if the month was closed, else live.
create or replace function public._manager_kpi_result(p_month date, p_wh text)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(
    (select s."Result" || jsonb_build_object('closed_by', s."ClosedBy", 'closed_at', s."ClosedAtUtc")
     from public."ManagerKpiSnapshots" s where s."Month" = date_trunc('month', p_month)::date and s."Warehouse" = p_wh),
    public._manager_kpi(p_month, p_wh));
$$;
revoke all on function public._manager_kpi_result(date, text) from public, anon, authenticated;

drop function if exists public.staff_get_manager_kpi(text, text, date, text);

create or replace function public.staff_get_manager_kpi(
  p_admin_username text,
  p_admin_password text,
  p_month date,
  p_warehouse text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_month date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Manila')::date))::date;
  v_wh text;
  v_ranking jsonb;
  v_detail jsonb;
  v_trend jsonb := '[]'::jsonb;
  v_res jsonb;
  m date;
begin
  select * into c from public._kpi_caller(p_admin_username, p_admin_password);

  -- Ranking: every scored branch this month.
  select coalesce(jsonb_agg(x order by (x->>'final')::numeric desc nulls last, x->>'branch'), '[]'::jsonb) into v_ranking
  from (select public._manager_kpi_result(v_month, b) as x from public._kpi_branches(v_month) b) z;

  if c.is_super then
    v_wh := nullif(trim(p_warehouse), '');
    if v_wh is null or not exists (select 1 from jsonb_array_elements(v_ranking) x where x->>'branch' = v_wh) then
      v_wh := coalesce(v_ranking->0->>'branch', c.branch);
    end if;
  else
    if c.branch is null then
      raise exception 'Your account has no branch set - ask a Super User to set your branch in User Setup.';
    end if;
    v_wh := c.branch;
  end if;
  if v_wh is null then
    raise exception 'No branch to score yet - set a Store Manager''s branch or a sales target.';
  end if;

  select x into v_detail from jsonb_array_elements(v_ranking) x where x->>'branch' = v_wh;
  if v_detail is null then
    v_detail := public._manager_kpi_result(v_month, v_wh);
  end if;

  -- 12-month trend for the branch (oldest first).
  for m in select generate_series(v_month - interval '11 months', v_month, interval '1 month')::date loop
    v_res := case when m = v_month then v_detail else public._manager_kpi_result(m, v_wh) end;
    v_trend := v_trend || jsonb_build_object(
      'month', m, 'final', v_res->'final',
      'sales', (select x->'sales' from jsonb_array_elements(v_res->'kpis') x where x->>'key' = 'sales'),
      'sales_pct', (select x->'actual' from jsonb_array_elements(v_res->'kpis') x where x->>'key' = 'sales'),
      'attendance_pct', (select x->'actual' from jsonb_array_elements(v_res->'kpis') x where x->>'key' = 'attendance'),
      'accuracy_pct', (select x->'actual' from jsonb_array_elements(v_res->'kpis') x where x->>'key' = 'accuracy'));
  end loop;

  -- Store Managers don't see bonus %.
  if not c.is_super then
    v_detail := v_detail - 'bonus_pct';
    v_ranking := (select coalesce(jsonb_agg((x - 'bonus_pct' - 'kpis') || jsonb_build_object('kpis', '[]'::jsonb)), '[]'::jsonb)
                  from jsonb_array_elements(v_ranking) x);
  end if;

  return jsonb_build_object(
    'month', v_month,
    'branch', v_wh,
    'is_super', c.is_super,
    'detail', v_detail,
    'ranking', (select coalesce(jsonb_agg(jsonb_build_object('branch', x->'branch', 'manager_name', x->'manager_name',
                       'final', x->'final', 'rating', x->'rating', 'bonus_pct', x->'bonus_pct', 'closed_at', x->'closed_at')
                       order by (x->>'final')::numeric desc nulls last, x->>'branch'), '[]'::jsonb)
                from jsonb_array_elements(v_ranking) x),
    'trend', v_trend,
    'previous', (select t from jsonb_array_elements(v_trend) t where (t->>'month')::date = (v_month - interval '1 month')::date)
  );
end;
$$;

grant execute on function public.staff_get_manager_kpi(text, text, date, text) to anon;

-- Freeze a finished month's scores for every scored branch (re-running overwrites).
drop function if exists public.admin_close_manager_kpi_month(text, text, date);

create or replace function public.admin_close_manager_kpi_month(
  p_admin_username text,
  p_admin_password text,
  p_month date
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_count int := 0;
  b text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_month >= date_trunc('month', (now() at time zone 'Asia/Manila'))::date then
    raise exception 'Only a finished month can be closed.';
  end if;

  for b in select * from public._kpi_branches(v_month) loop
    insert into public."ManagerKpiSnapshots" ("Month", "Warehouse", "Result", "ClosedBy", "ClosedAtUtc")
    values (v_month, b, public._manager_kpi(v_month, b), p_admin_username, now())
    on conflict ("Month", "Warehouse") do update
      set "Result" = excluded."Result", "ClosedBy" = excluded."ClosedBy", "ClosedAtUtc" = now();
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

grant execute on function public.admin_close_manager_kpi_month(text, text, date) to anon;

-- Re-open a closed month (back to live numbers).
drop function if exists public.admin_reopen_manager_kpi_month(text, text, date);

create or replace function public.admin_reopen_manager_kpi_month(
  p_admin_username text,
  p_admin_password text,
  p_month date
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
  delete from public."ManagerKpiSnapshots" where "Month" = date_trunc('month', p_month)::date;
end;
$$;

grant execute on function public.admin_reopen_manager_kpi_month(text, text, date) to anon;

notify pgrst, 'reload schema';

-- Check - one result: this month's live score per scored branch.
select b as section,
       coalesce((public._manager_kpi((now() at time zone 'Asia/Manila')::date, b)->>'final') || ' - '
                || (public._manager_kpi((now() at time zone 'Asia/Manila')::date, b)->>'rating'), 'no score yet') as value
from public._kpi_branches((now() at time zone 'Asia/Manila')::date) b
union all
select 'dashboard function',
       case when to_regprocedure('public.staff_get_manager_kpi(text, text, date, text)') is not null then 'ready' else 'MISSING' end;
