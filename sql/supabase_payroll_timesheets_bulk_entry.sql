-- Bulk timesheet entry, per: "in the employee timesheets.. can we do it across all employee
-- instead of filling each employee everytime" and then "I want to be able to show the whole
-- week... Employee x Monday/Tuesday/etc... log it as hours." Adds one RPC that upserts however
-- many (employee, date, hours) cells the officer filled in across the whole week grid
-- (payroll-timesheets.html) in a single call, instead of one round trip per cell.
--
-- Each entry now carries its OWN work_date (not a single shared date), since the grid is a full
-- week of columns per employee row, not one day for everyone.
--
-- Deliberately non-destructive: a cell the officer leaves blank is just skipped (not deleted) even
-- if that employee already had an entry for that date - removing an entry still goes through
-- admin_delete_timesheet_entry (the existing per-row Delete button on the list below the grid),
-- never implicitly through a bulk save.
--
-- Run this AFTER supabase_payroll_timesheets.sql (reuses is_payroll_authorized and the
-- PayrollTimesheetEntries table from that file).

drop function if exists public.admin_upsert_timesheet_entries_for_date(text, text, date, jsonb);

create or replace function public.admin_upsert_timesheet_entries_bulk(
  p_admin_username text,
  p_admin_password text,
  p_entries jsonb
)
returns table(success boolean, message text, saved_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry jsonb;
  v_username text;
  v_work_date date;
  v_hours_worked numeric;
  v_notes text;
  v_saved int := 0;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text, 0;
    return;
  end if;

  for v_entry in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb))
  loop
    v_username := v_entry->>'username';
    v_work_date := nullif(v_entry->>'work_date', '')::date;
    v_hours_worked := nullif(v_entry->>'hours_worked', '')::numeric;
    v_notes := nullif(trim(v_entry->>'notes'), '');

    -- Skip incomplete/blank cells rather than failing the whole batch over one row.
    if v_username is null or v_work_date is null or v_hours_worked is null then
      continue;
    end if;
    if v_hours_worked <= 0 or v_hours_worked > 24 then
      continue;
    end if;
    if not exists (select 1 from public."StaffUsers" where "Username" = v_username) then
      continue;
    end if;

    insert into public."PayrollTimesheetEntries" ("Username", "WorkDate", "HoursWorked", "Notes", "CreatedBy")
    values (v_username, v_work_date, v_hours_worked, v_notes, p_admin_username)
    on conflict ("Username", "WorkDate") do update
      set "HoursWorked" = excluded."HoursWorked",
          "Notes" = excluded."Notes",
          "UpdatedAtUtc" = timezone('utc', now());

    v_saved := v_saved + 1;
  end loop;

  return query select true, ('Saved ' || v_saved || ' timesheet entr' || case when v_saved = 1 then 'y' else 'ies' end || '.')::text, v_saved;
end;
$$;

grant execute on function public.admin_upsert_timesheet_entries_bulk(text, text, jsonb) to anon;
