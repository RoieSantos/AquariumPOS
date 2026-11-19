-- Manager Scorecard (manager-scorecard.html) - per "i want to have a view / report for my manager so i can say im
-- gauging him/her with this numbers" (items on hand / sold / approximated inventory count).
--
-- The Manager's Report's data (_manager_report_data, supabase_manager_report.sql) for ONE branch, with every
-- money-side figure the manager shouldn't see taken out: no purchases, expenses, bills, payroll, margin, item
-- costs or stock values. What stays is what the manager is measured on:
--   sales per day + target + last month's same days, cash count short/over, Item Ledger movements per item
--   (on hand, sold, received, transferred, missing in counts, written off), transfers not received, defect
--   reports (qty only), top sellers, and whether the branch posted a physical count this month.
--   Sets, customized (made-to-order) items and placeholder codes are left out of the item list (not shelf stock).
--
-- Who sees what:
--   * Store Manager - ONLY their own branch (StaffUsers."WarehouseName"); p_warehouse is ignored.
--   * Super User    - any branch (p_warehouse), first branch with sales if none is given.
--
-- Run AFTER supabase_manager_report.sql. Safe to re-run. Needs manager-scorecard.html /
-- js/managerScorecard.js ?v=scorecard1. Ends with ONE result.

drop function if exists public.staff_get_manager_scorecard(text, text, date, text);

create or replace function public.staff_get_manager_scorecard(
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
  v_super boolean;
  v_manager boolean;
  v_own text;
  v_wh text;
  v_data jsonb;
  v_from date;
  v_to date;
  v_branches jsonb;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce(s."SuperUser", false), coalesce(s."StoreManager", false), nullif(trim(s."WarehouseName"), '')
    into v_super, v_manager, v_own
  from public."StaffUsers" s
  where s."Username" = p_admin_username and coalesce(s."IsActive", true);

  if not coalesce(v_super, false) and not coalesce(v_manager, false) then
    raise exception 'Not authorized.';
  end if;

  v_data := public._manager_report_data(p_month);
  v_from := (v_data->>'month')::date;
  v_to := (v_from + interval '1 month')::date;

  if v_super then
    v_branches := v_data->'warehouses';
    v_wh := nullif(trim(p_warehouse), '');
    if v_wh is null or not (v_branches ? v_wh) then
      -- Default to the branch with the most sales this month.
      select d->>'warehouse' into v_wh
      from jsonb_array_elements(v_data->'sales_days') d
      group by 1 order by sum((d->>'amount')::numeric) desc limit 1;
      v_wh := coalesce(v_wh, v_branches->>0);
    end if;
  else
    if v_own is null then
      raise exception 'Your account has no branch set - ask a Super User to set your branch in User Setup.';
    end if;
    v_wh := v_own;
    v_branches := jsonb_build_array(v_own);
  end if;

  return jsonb_build_object(
    'month', v_data->'month',
    'month_end', v_data->'month_end',
    'through', v_data->'through',
    'days_in_month', v_data->'days_in_month',
    'days_elapsed', v_data->'days_elapsed',
    'branch', v_wh,
    'branches', v_branches,
    'can_pick_branch', v_super,
    'target', coalesce((select sum((t->>'target')::numeric) from jsonb_array_elements(v_data->'targets') t
                        where t->>'warehouse' = v_wh), 0),
    'sales_days', coalesce((select jsonb_agg(jsonb_build_object('date', d->'date', 'amount', d->'amount', 'count', d->'count'))
                            from jsonb_array_elements(v_data->'sales_days') d where d->>'warehouse' = v_wh), '[]'::jsonb),
    'prev_same_days', coalesce((select sum((c->>'amount')::numeric) from jsonb_array_elements(v_data->'compare'->'prev') c
                                where c->>'warehouse' = v_wh), 0),
    'prev_full_month', coalesce((select sum((c->>'amount')::numeric) from jsonb_array_elements(v_data->'compare'->'prev_full') c
                                 where c->>'warehouse' = v_wh), 0),
    'cash', coalesce((select c - 'warehouse' from jsonb_array_elements(v_data->'cash') c where c->>'warehouse' = v_wh limit 1), '{}'::jsonb),
    -- Shelf stock only: sets, customized (made-to-order) items and placeholder codes (CUSTOM, SERVICES, ...)
    -- always run below zero and aren't counted, so they'd score against the manager unfairly.
    'items', coalesce((select jsonb_agg(i - 'cost' - 'warehouse')
                       from jsonb_array_elements(v_data->'items') i
                       where i->>'warehouse' = v_wh
                         and regexp_replace(upper(coalesce(i->>'category', '')), '[^A-Z]', '', 'g') not in ('SET', 'CUSTOMIZEDITEM', 'SERVICES')
                         and upper(i->>'code') !~ '^(CUSTOM|SERVICES|POS-FALLBACK|SET-)'), '[]'::jsonb),
    'transfer_gaps', coalesce((select jsonb_agg(g - 'value')
                               from jsonb_array_elements(v_data->'transfer_gaps') g
                               where g->>'from' = v_wh or g->>'to' = v_wh), '[]'::jsonb),
    'defects', coalesce((select jsonb_agg(d - 'value' - 'warehouse')
                         from jsonb_array_elements(v_data->'defects') d where d->>'warehouse' = v_wh), '[]'::jsonb),
    'top_items', coalesce((select jsonb_agg(t - 'warehouse')
                           from jsonb_array_elements(v_data->'top_items') t where t->>'warehouse' = v_wh), '[]'::jsonb),
    -- Physical counting done this month. Posting a count deletes its journal lines and only writes ledger
    -- entries for items whose count differed, so: days with posted count adjustments + lines counted but
    -- not posted yet. (A count where every item matched leaves no trace.)
    'count_days', (select count(distinct e."PostingDate") from public."ItemLedgerEntries" e
                   join public."Warehouses" w on w."ID"::text = e."WarehouseId"
                   where trim(w."Name") = v_wh and e."DocumentType" in ('Phys. Inventory', 'Serial Phys. Inventory')
                     and e."PostingDate" >= v_from and e."PostingDate" < v_to),
    'count_open_lines', (select count(*) from public."PhysInventoryJournalLines" l
                         join public."Warehouses" w on w."ID"::text = l."WarehouseId"::text
                         where trim(w."Name") = v_wh and l."QtyCounted" is not null
                           and (l."UpdatedAtUtc" at time zone 'Asia/Manila')::date >= v_from
                           and (l."UpdatedAtUtc" at time zone 'Asia/Manila')::date < v_to)
  );
end;
$$;

grant execute on function public.staff_get_manager_scorecard(text, text, date, text) to anon;

notify pgrst, 'reload schema';

-- Check - one result.
select 'scorecard function' as section,
       case when to_regprocedure('public.staff_get_manager_scorecard(text, text, date, text)') is not null then 'ready' else 'MISSING' end as value
union all
select 'needs report data function',
       case when to_regprocedure('public._manager_report_data(date)') is not null then 'ok' else 'RUN supabase_manager_report.sql' end
union all
select 'store managers with a branch',
       (select count(*) filter (where nullif(trim("WarehouseName"), '') is not null) || ' of ' || count(*)
        from public."StaffUsers" where coalesce("StoreManager", false) and coalesce("IsActive", true));
