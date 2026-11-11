-- Owner withdrawals through Xendit - per "what if I want to send funds to my own account? how can I do it in the
-- portal" ... "yes option 3".
--
--   - Xendit Ledger Entries > Withdraw to Owner (super users only) sends money from the Xendit balance to one of the
--     owner's own GCash / bank accounts, through the same Payouts API, key, webhook and XenditPayouts table as
--     salary and cash advance payouts (Kind 'Owner').
--   - The accounts are NOT stored or editable in the portal: they live in the XENDIT_OWNER_ACCOUNTS Edge Function
--     secret, so someone who gets into a super user login can't add their own account and send money to it.
--   - Double sends: the page makes one request id per withdrawal; it is the row's PayoutID and Xendit's
--     Idempotency-key, so a double click or a retry after a timeout can't pay twice.
--   - Not a payroll or on-hand ledger entry: the Xendit balance isn't counted in Cash / Digital on Hand, so it
--     shows as money out on Xendit Ledger Entries only (Reference RSPS-PAY-OWN-...).
--
-- Run AFTER supabase_xendit_payroll_payouts.sql and supabase_xendit_cash_advance_payouts.sql (replaces the
-- CK_XenditPayouts_Kind check). Safe to re-run. Needs the xendit-owner-payout Edge Function and
-- js/xenditLedger.js ?v=xowner1. Ends with ONE result.

-- ---------------------------------------------------------------------------
-- XenditPayouts: also holds owner withdrawals.

alter table public."XenditPayouts" add column if not exists "OwnerAccountKey" text;  -- the "key" of the account in XENDIT_OWNER_ACCOUNTS
alter table public."XenditPayouts" add column if not exists "Note" text;

alter table public."XenditPayouts" drop constraint if exists "CK_XenditPayouts_Kind";
alter table public."XenditPayouts"
  add constraint "CK_XenditPayouts_Kind" check (
    ("Kind" = 'Salary' and "RunID" is not null and "LineID" is not null)
    or "Kind" = 'Advance'
    or ("Kind" = 'Owner' and "OwnerAccountKey" is not null));

create index if not exists "IX_XenditPayouts_Owner" on public."XenditPayouts" ("CreatedAtUtc" desc) where "Kind" = 'Owner';

-- ---------------------------------------------------------------------------
-- Service-role helpers for xendit-owner-payout.

-- The row for this withdrawal request. A new request id makes a new row (send = true). The same id again returns
-- the existing row: send = true only while it is stuck at 'Creating' (re-sent with the SAME Idempotency-key);
-- otherwise send = false and the Edge Function reports its status instead of paying again.
create or replace function public._owner_payout_prepare(
  p_request_id uuid,
  p_is_test boolean,
  p_sent_by text,
  p_amount numeric,
  p_account_key text,
  p_channel_code text,
  p_channel_name text,
  p_account_number text,
  p_account_name text,
  p_label text,
  p_note text
)
returns table(payout_id uuid, reference_id text, amount numeric, channel_code text, account_number text,
              account_name text, status text, is_new boolean, send boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."XenditPayouts"%rowtype;
  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);
  v_ref text;
begin
  if p_request_id is null then
    raise exception 'Missing request id - reload the page and try again.';
  end if;

  perform pg_advisory_xact_lock(hashtext('owner-payout'));

  select * into v_row from public."XenditPayouts" where "PayoutID" = p_request_id for update;
  if found then
    if v_row."Kind" <> 'Owner' then
      raise exception 'That request id belongs to another payout - reload the page and try again.';
    end if;
    return query select v_row."PayoutID", v_row."ReferenceID", v_row."Amount", v_row."ChannelCode", v_row."AccountNumber",
                        v_row."AccountName", v_row."Status", false, v_row."Status" = 'Creating';
    return;
  end if;

  if v_amount <= 0 then
    raise exception 'Enter an amount above zero.';
  end if;
  if coalesce(trim(p_account_key), '') = '' or coalesce(trim(p_channel_code), '') = ''
     or coalesce(trim(p_account_number), '') = '' or coalesce(trim(p_account_name), '') = '' then
    raise exception 'The owner account is incomplete - check the XENDIT_OWNER_ACCOUNTS secret.';
  end if;

  v_ref := 'RSPS-PAY-OWN-' || replace(p_request_id::text, '-', '');
  insert into public."XenditPayouts" ("PayoutID", "ReferenceID", "Kind", "OwnerAccountKey", "Username", "DisplayName", "Amount",
                                      "ChannelCode", "ChannelName", "AccountNumber", "AccountName", "IsTest", "SentBy", "Note")
  values (p_request_id, v_ref, 'Owner', p_account_key, p_sent_by, left(coalesce(nullif(trim(p_label), ''), 'Owner'), 100), v_amount,
          p_channel_code, p_channel_name, p_account_number, p_account_name, p_is_test, p_sent_by, left(nullif(trim(p_note), ''), 200));

  return query select p_request_id, v_ref, v_amount, p_channel_code, p_account_number, p_account_name, 'Creating'::text, true, true;
end;
$$;

revoke all on function public._owner_payout_prepare(uuid, boolean, text, numeric, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public._owner_payout_prepare(uuid, boolean, text, numeric, text, text, text, text, text, text, text) to service_role;

-- Owner withdrawals still waiting on Xendit (for "Refresh Status").
create or replace function public._owner_payouts_open()
returns table(payout_id uuid, reference_id text, xendit_payout_id text, is_test boolean, status text, age_seconds numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select "PayoutID", "ReferenceID", "XenditPayoutID", "IsTest", "Status", extract(epoch from now() - "CreatedAtUtc")::numeric
  from public."XenditPayouts"
  where "Kind" = 'Owner' and "Status" in ('Creating', 'ACCEPTED', 'REQUESTED');
$$;

revoke all on function public._owner_payouts_open() from public, anon, authenticated;
grant execute on function public._owner_payouts_open() to service_role;

-- Recent owner withdrawals for the dialog (account number masked to the last 4).
create or replace function public._owner_payouts_recent(p_limit int default 20)
returns table(payout_id uuid, reference_id text, created_at timestamptz, paid_at timestamptz, amount numeric, label text,
              channel_name text, account_last4 text, is_test boolean, status text, failure_code text, error text,
              sent_by text, note text)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select "PayoutID", "ReferenceID", "CreatedAtUtc", "PaidAtUtc", "Amount", "DisplayName", coalesce("ChannelName", "ChannelCode"),
         right("AccountNumber", 4), "IsTest", "Status", "FailureCode", "Error", "SentBy", "Note"
  from public."XenditPayouts"
  where "Kind" = 'Owner'
  order by "CreatedAtUtc" desc
  limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;

revoke all on function public._owner_payouts_recent(int) from public, anon, authenticated;
grant execute on function public._owner_payouts_recent(int) to service_role;

notify pgrst, 'reload schema';

-- Check - one result.
select 'kind check' as section,
       case when pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_XenditPayouts_Kind')) like '%Owner%'
            then 'Owner allowed' else 'MISSING' end as value
union all
select 'helpers', case when to_regprocedure('public._owner_payouts_open()') is not null
                        and to_regprocedure('public._owner_payouts_recent(integer)') is not null
                       then 'ready' else 'MISSING' end
union all
select 'owner withdrawals so far', count(*)::text from public."XenditPayouts" where "Kind" = 'Owner';
