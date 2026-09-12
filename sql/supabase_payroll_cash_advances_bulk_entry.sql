-- Lets the payroll officer log each employee's weekly Cash Advance right in the Timesheets weekly
-- grid, alongside their hours, instead of a separate form on Payroll Setup (which stays as the
-- full journal/history view - this is just a friendlier way to log the routine weekly amount).
--
-- One upsert-style call per "Save All" click: for each employee, if they already have an
-- Outstanding advance dated somewhere inside the week being viewed, its Amount is updated (or the
-- row deleted if the cell was cleared back to blank/0); otherwise a new advance is inserted dated
-- p_advance_date (the payroll officer's chosen release day, e.g. that week's Thursday). Mirrors
-- admin_upsert_timesheet_entries_bulk's bulk-upsert shape (supabase_payroll_timesheets_bulk_entry.sql).
--
-- Run this AFTER supabase_payroll_cash_advances.sql.

create or replace function public.admin_upsert_cash_advances_bulk(
  p_admin_username text,
  p_admin_password text,
  p_advance_date date,
  p_week_start date,
  p_week_end date,
  p_entries jsonb
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry jsonb;
  v_username text;
  v_amount numeric;
  v_existing_id uuid;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_advance_date is null or p_week_start is null or p_week_end is null then
    return query select false, 'A valid advance date and week range are required.'::text;
    return;
  end if;

  for v_entry in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb))
  loop
    v_username := v_entry->>'username';
    v_amount := nullif(v_entry->>'amount', '')::numeric;

    if v_username is null or not exists (select 1 from public."StaffUsers" where "Username" = v_username) then
      continue;
    end if;

    select "AdvanceID" into v_existing_id
      from public."PayrollCashAdvances"
      where "Username" = v_username and "Status" = 'Outstanding'
        and "AdvanceDate" between p_week_start and p_week_end
      order by "AdvanceDate"
      limit 1;

    if coalesce(v_amount, 0) > 0 then
      if v_existing_id is not null then
        update public."PayrollCashAdvances" set "Amount" = v_amount where "AdvanceID" = v_existing_id;
      else
        insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "CreatedBy")
        values (v_username, p_advance_date, v_amount, p_admin_username);
      end if;
    else
      if v_existing_id is not null then
        delete from public."PayrollCashAdvances" where "AdvanceID" = v_existing_id;
      end if;
    end if;
  end loop;

  return query select true, 'Cash advances saved.'::text;
end;
$$;

grant execute on function public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb) to anon;
