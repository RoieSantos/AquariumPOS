-- Extends the Timesheets weekly grid's Cash Advance bulk upsert with the same Method (Cash/Digital)
-- field the Payroll Setup form got in supabase_payroll_cash_advance_method_employee_no.sql - each
-- entry now carries its own method, defaulting to Cash when omitted/invalid. An existing Outstanding
-- advance's Method is updated in place along with its Amount (still "draft" until applied to a run,
-- same reasoning as keeping Amount in sync).
--
-- Run this AFTER supabase_payroll_cash_advance_method_employee_no.sql.

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
  v_method text;
  v_existing_id uuid;
  v_new_id uuid;
  v_display_name text;
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
    v_method := v_entry->>'method';
    if coalesce(v_method, '') not in ('Cash', 'Digital') then
      v_method := 'Cash';
    end if;

    select "DisplayName" into v_display_name from public."StaffUsers" where "Username" = v_username;
    if not found then
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
        update public."PayrollCashAdvances" set "Amount" = v_amount, "Method" = v_method where "AdvanceID" = v_existing_id;
        update public."PayrollLedgerEntries" set "Amount" = v_amount where "SourceAdvanceID" = v_existing_id;
      else
        insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Method", "CreatedBy")
        values (v_username, p_advance_date, v_amount, v_method, p_admin_username)
        returning "AdvanceID" into v_new_id;

        insert into public."PayrollLedgerEntries"
          ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "SourceAdvanceID", "PostedBy")
        values (v_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', v_amount, v_new_id, p_admin_username);
      end if;
    else
      if v_existing_id is not null then
        delete from public."PayrollLedgerEntries" where "SourceAdvanceID" = v_existing_id;
        delete from public."PayrollCashAdvances" where "AdvanceID" = v_existing_id;
      end if;
    end if;
  end loop;

  return query select true, 'Cash advances saved.'::text;
end;
$$;

grant execute on function public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb) to anon;
