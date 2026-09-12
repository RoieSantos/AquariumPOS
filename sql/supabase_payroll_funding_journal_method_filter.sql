-- Lets the Funding Journal be filtered to one Method - backs the new "click Cash on Hand /
-- Digital on Hand to see everything that makes it up" feature (Funding entries + Payout
-- deductions, including the Cash Advance payouts added in
-- supabase_payroll_cash_advance_funding_ledger.sql). Same signature otherwise, p_method appended
-- with a default so no existing caller breaks.
--
-- Run this AFTER supabase_payroll_cash_advance_funding_ledger.sql.

create or replace function public.admin_list_payroll_funding_entries(
  p_admin_username text,
  p_admin_password text,
  p_page int default 1,
  p_page_size int default 50,
  p_method text default null
)
returns table(
  funding_id uuid,
  entry_type text,
  method text,
  amount numeric,
  notes text,
  run_id uuid,
  posted_by text,
  posted_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "FundingID", "EntryType"::text, "Method"::text, "Amount", "Notes"::text, "RunID", "PostedBy"::text, "PostedAtUtc",
           count(*) over()
    from public."PayrollFundingLedger"
    where (p_method is null or "Method" = p_method)
    order by "PostedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_payroll_funding_entries(text, text, int, int, text) to anon;
