-- Bills & Dues (Web Portal, super users only) - per "create me a new feature showing all the
-- business mandatory bills to pay". The recurring obligations the business must pay on schedule
-- (rent, electricity, water, internet, BIR taxes, SSS/PhilHealth/Pag-IBIG, business permit,
-- insurance, loans...) - NOT supplier bills, those stay on Vendors (VendorBills/VendorPayments).
--
--   1. public."BusinessBills" - one row per obligation: what, who to pay, account no., branch,
--      how often (Monthly/Quarterly/Semi-Annual/Yearly/One-time), the first due date (every later
--      due date = FirstDueDate + N x the frequency, so a "due every 15th" monthly bill just starts
--      on a 15th), the usual amount, and how many days ahead it should start showing "Due Soon".
--   2. public."BusinessBillPayments" - one row per period paid, keyed to that period's DueDate.
--      Soft-voided (IsVoid) like VendorPayments. Optionally also logs an Expense Journal entry
--      (ExpenseJournalEntryID) so the payment shows in Expenses / Dashboard / G/L too; voiding the
--      payment deletes that linked journal entry again.
--
-- RPCs: admin_list_business_bills (each bill + next unpaid due date + status), admin_save_business_bill,
-- admin_list_business_bill_schedule (every due date in a date range, paid or not),
-- admin_list_business_bill_payments, admin_pay_business_bill, admin_void_business_bill_payment.
--
-- Run AFTER supabase_expense_journal_receipt_numbers.sql (uses admin_add_expense_journal_entry).
-- Safe to re-run.

create table if not exists public."BusinessBills" (
    "BillID" uuid primary key default gen_random_uuid(),
    "Name" varchar(200) not null,
    "Category" varchar(100),
    "Payee" varchar(200),
    "AccountNo" varchar(200),
    "Warehouse" text,                                  -- null = company-wide
    "Frequency" varchar(20) not null default 'Monthly', -- Monthly/Quarterly/Semi-Annual/Yearly/One-time
    "FirstDueDate" date not null,
    "ExpectedAmount" numeric(18, 2),
    "RemindDaysBefore" int not null default 7,
    "ExpenseCategory" varchar(100),                    -- default category when logging to Expense Journal
    "Notes" varchar(1000),
    "IsActive" boolean not null default true,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now(),
    "UpdatedAtUtc" timestamptz
);

alter table public."BusinessBills" enable row level security;
revoke all on public."BusinessBills" from anon, authenticated;

create table if not exists public."BusinessBillPayments" (
    "PaymentID" uuid primary key default gen_random_uuid(),
    "BillID" uuid not null,
    "DueDate" date not null,          -- the period this payment covers
    "PaidDate" date not null,
    "Amount" numeric(18, 2) not null,
    "Method" varchar(100),
    "ReferenceNo" varchar(200),
    "Notes" varchar(1000),
    "ExpenseJournalEntryID" uuid,
    "IsVoid" boolean not null default false,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now()
);

alter table public."BusinessBillPayments" enable row level security;
revoke all on public."BusinessBillPayments" from anon, authenticated;
create index if not exists "IX_BusinessBillPayments_Bill" on public."BusinessBillPayments" ("BillID", "DueDate");
create index if not exists "IX_BusinessBillPayments_PaidDate" on public."BusinessBillPayments" ("PaidDate");

-- ---------------------------------------------------------------------------
-- Months between due dates for a frequency (0 = One-time).
create or replace function public._business_bill_step_months(p_frequency text)
returns int
language sql
immutable
as $$
  select case p_frequency
    when 'Monthly' then 1
    when 'Quarterly' then 3
    when 'Semi-Annual' then 6
    when 'Yearly' then 12
    else 0
  end;
$$;

-- Every due date of one bill from p_from to p_to. Computed from FirstDueDate each time (not
-- step-by-step) so a 31st-of-the-month bill clips to Feb 28 but goes back to Mar 31.
create or replace function public._business_bill_due_dates(
  p_first_due date, p_frequency text, p_from date, p_to date
)
returns table(due_date date)
language sql
immutable
as $$
  select p_first_due
  where public._business_bill_step_months(p_frequency) = 0
    and p_first_due between p_from and p_to
  union all
  select (p_first_due + make_interval(months => n * public._business_bill_step_months(p_frequency)))::date
  from generate_series(
         greatest(0, ((extract(year from age(p_from, p_first_due)) * 12 + extract(month from age(p_from, p_first_due)))::int
                      / greatest(public._business_bill_step_months(p_frequency), 1)) - 1),
         ((extract(year from age(p_to, p_first_due)) * 12 + extract(month from age(p_to, p_first_due)))::int
           / greatest(public._business_bill_step_months(p_frequency), 1)) + 1
       ) as n
  where public._business_bill_step_months(p_frequency) > 0
    and (p_first_due + make_interval(months => n * public._business_bill_step_months(p_frequency)))::date between p_from and p_to;
$$;

-- ---------------------------------------------------------------------------
-- List: each bill with its oldest unpaid due date (looking back to FirstDueDate, ahead two periods)
-- and a status: Overdue / Due Soon (within RemindDaysBefore) / Upcoming / Paid (One-time, done).

drop function if exists public.admin_list_business_bills(text, text, boolean);

create or replace function public.admin_list_business_bills(
  p_admin_username text,
  p_admin_password text,
  p_include_inactive boolean default false
)
returns table(
  bill_id uuid,
  name text,
  category text,
  payee text,
  account_no text,
  warehouse text,
  frequency text,
  first_due_date date,
  expected_amount numeric,
  remind_days_before int,
  expense_category text,
  notes text,
  is_active boolean,
  next_due_date date,
  overdue_count int,
  status text,
  last_paid_date date,
  last_paid_amount numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with unpaid as (
      select b."BillID", d.due_date
      from public."BusinessBills" b
      cross join lateral public._business_bill_due_dates(
        b."FirstDueDate", b."Frequency", b."FirstDueDate",
        -- two periods ahead, so paying the current one early still leaves the next one "Upcoming"
        (greatest(v_today, b."FirstDueDate") + make_interval(months => 2 * greatest(public._business_bill_step_months(b."Frequency"), 1)))::date
      ) d
      where not exists (
        select 1 from public."BusinessBillPayments" p
        where p."BillID" = b."BillID" and p."DueDate" = d.due_date and not p."IsVoid"
      )
    ),
    agg as (
      select u."BillID",
             min(u.due_date) as next_due,
             count(*) filter (where u.due_date < v_today)::int as overdue_n
      from unpaid u
      group by u."BillID"
    ),
    last_pay as (
      select distinct on (p."BillID") p."BillID", p."PaidDate", p."Amount"
      from public."BusinessBillPayments" p
      where not p."IsVoid"
      order by p."BillID", p."PaidDate" desc, p."CreatedAtUtc" desc
    )
    select b."BillID", b."Name"::text, b."Category"::text, b."Payee"::text, b."AccountNo"::text,
           b."Warehouse", b."Frequency"::text, b."FirstDueDate", b."ExpectedAmount",
           b."RemindDaysBefore", b."ExpenseCategory"::text, b."Notes"::text, b."IsActive",
           a.next_due,
           coalesce(a.overdue_n, 0),
           case
             when a.next_due is null then 'Paid'
             when a.next_due < v_today then 'Overdue'
             when a.next_due <= v_today + b."RemindDaysBefore" then 'Due Soon'
             else 'Upcoming'
           end::text,
           lp."PaidDate", lp."Amount"
    from public."BusinessBills" b
    left join agg a on a."BillID" = b."BillID"
    left join last_pay lp on lp."BillID" = b."BillID"
    where coalesce(p_include_inactive, false) or b."IsActive"
    order by (a.next_due is null), a.next_due, b."Name";
end;
$$;

grant execute on function public.admin_list_business_bills(text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Create (p_bill_id null) or update.

drop function if exists public.admin_save_business_bill(text, text, uuid, text, text, text, text, text, text, date, numeric, int, text, text, boolean);

create or replace function public.admin_save_business_bill(
  p_admin_username text,
  p_admin_password text,
  p_bill_id uuid,
  p_name text,
  p_category text,
  p_payee text,
  p_account_no text,
  p_warehouse text,
  p_frequency text,
  p_first_due_date date,
  p_expected_amount numeric,
  p_remind_days_before int,
  p_expense_category text,
  p_notes text,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if trim(coalesce(p_name, '')) = '' then
    raise exception 'Bill name is required.';
  end if;
  if p_frequency not in ('Monthly', 'Quarterly', 'Semi-Annual', 'Yearly', 'One-time') then
    raise exception 'Invalid frequency: %', p_frequency;
  end if;
  if p_first_due_date is null then
    raise exception 'First due date is required.';
  end if;

  if p_bill_id is null then
    insert into public."BusinessBills"
      ("Name", "Category", "Payee", "AccountNo", "Warehouse", "Frequency", "FirstDueDate",
       "ExpectedAmount", "RemindDaysBefore", "ExpenseCategory", "Notes", "IsActive", "CreatedBy")
    values
      (trim(p_name), nullif(trim(coalesce(p_category, '')), ''), nullif(trim(coalesce(p_payee, '')), ''),
       nullif(trim(coalesce(p_account_no, '')), ''), nullif(trim(coalesce(p_warehouse, '')), ''),
       p_frequency, p_first_due_date, p_expected_amount, greatest(coalesce(p_remind_days_before, 7), 0),
       nullif(trim(coalesce(p_expense_category, '')), ''), nullif(trim(coalesce(p_notes, '')), ''),
       coalesce(p_is_active, true), p_admin_username)
    returning "BillID" into v_id;
  else
    update public."BusinessBills" set
      "Name" = trim(p_name),
      "Category" = nullif(trim(coalesce(p_category, '')), ''),
      "Payee" = nullif(trim(coalesce(p_payee, '')), ''),
      "AccountNo" = nullif(trim(coalesce(p_account_no, '')), ''),
      "Warehouse" = nullif(trim(coalesce(p_warehouse, '')), ''),
      "Frequency" = p_frequency,
      "FirstDueDate" = p_first_due_date,
      "ExpectedAmount" = p_expected_amount,
      "RemindDaysBefore" = greatest(coalesce(p_remind_days_before, 7), 0),
      "ExpenseCategory" = nullif(trim(coalesce(p_expense_category, '')), ''),
      "Notes" = nullif(trim(coalesce(p_notes, '')), ''),
      "IsActive" = coalesce(p_is_active, true),
      "UpdatedAtUtc" = now()
    where "BillID" = p_bill_id
    returning "BillID" into v_id;
    if v_id is null then
      raise exception 'Bill not found.';
    end if;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_save_business_bill(text, text, uuid, text, text, text, text, text, text, date, numeric, int, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Schedule: every due date of every active bill between p_from and p_to, plus what was paid for it.

drop function if exists public.admin_list_business_bill_schedule(text, text, date, date);

create or replace function public.admin_list_business_bill_schedule(
  p_admin_username text,
  p_admin_password text,
  p_from date,
  p_to date
)
returns table(
  bill_id uuid,
  name text,
  category text,
  payee text,
  warehouse text,
  frequency text,
  due_date date,
  expected_amount numeric,
  paid_amount numeric,
  paid_date date,
  payment_id uuid,
  is_paid boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select b."BillID", b."Name"::text, b."Category"::text, b."Payee"::text, b."Warehouse",
           b."Frequency"::text, d.due_date, b."ExpectedAmount",
           p.paid_amount, p.paid_date, p.payment_id,
           (p.payment_id is not null)
    from public."BusinessBills" b
    cross join lateral public._business_bill_due_dates(b."FirstDueDate", b."Frequency", p_from, p_to) d
    left join lateral (
      select sum(x."Amount") as paid_amount, max(x."PaidDate") as paid_date,
             (array_agg(x."PaymentID" order by x."CreatedAtUtc" desc))[1] as payment_id
      from public."BusinessBillPayments" x
      where x."BillID" = b."BillID" and x."DueDate" = d.due_date and not x."IsVoid"
      having count(*) > 0
    ) p on true
    where b."IsActive"
    order by d.due_date, b."Name";
end;
$$;

grant execute on function public.admin_list_business_bill_schedule(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- Payment history (one bill, or all when p_bill_id is null).

drop function if exists public.admin_list_business_bill_payments(text, text, uuid, int);

create or replace function public.admin_list_business_bill_payments(
  p_admin_username text,
  p_admin_password text,
  p_bill_id uuid default null,
  p_limit int default 200
)
returns table(
  payment_id uuid,
  bill_id uuid,
  bill_name text,
  due_date date,
  paid_date date,
  amount numeric,
  method text,
  reference_no text,
  notes text,
  expense_receipt_no text,
  is_void boolean,
  created_by text,
  created_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select p."PaymentID", p."BillID", b."Name"::text, p."DueDate", p."PaidDate", p."Amount",
           p."Method"::text, p."ReferenceNo"::text, p."Notes"::text, j."ReceiptNo"::text,
           p."IsVoid", p."CreatedBy"::text, p."CreatedAtUtc"
    from public."BusinessBillPayments" p
    join public."BusinessBills" b on b."BillID" = p."BillID"
    left join public."ExpenseJournalEntries" j on j."EntryID" = p."ExpenseJournalEntryID"
    where p_bill_id is null or p."BillID" = p_bill_id
    order by p."PaidDate" desc, p."CreatedAtUtc" desc
    limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end;
$$;

grant execute on function public.admin_list_business_bill_payments(text, text, uuid, int) to anon;

-- ---------------------------------------------------------------------------
-- Pay one period. p_expense_category not null -> also logs an Expense Journal entry (EXP- receipt)
-- dated the paid date, for the bill's branch.

drop function if exists public.admin_pay_business_bill(text, text, uuid, date, date, numeric, text, text, text, text);

create or replace function public.admin_pay_business_bill(
  p_admin_username text,
  p_admin_password text,
  p_bill_id uuid,
  p_due_date date,
  p_paid_date date,
  p_amount numeric,
  p_method text default null,
  p_reference_no text default null,
  p_notes text default null,
  p_expense_category text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bill public."BusinessBills"%rowtype;
  v_entry uuid;
  v_id uuid;
  v_paid_date date := coalesce(p_paid_date, (now() at time zone 'Asia/Manila')::date);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_bill from public."BusinessBills" where "BillID" = p_bill_id;
  if not found then
    raise exception 'Bill not found.';
  end if;
  if p_due_date is null then
    raise exception 'Due date (period) is required.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero.';
  end if;

  if nullif(trim(coalesce(p_expense_category, '')), '') is not null then
    select e.entry_id into v_entry
    from public.admin_add_expense_journal_entry(
      p_admin_username, p_admin_password, trim(p_expense_category),
      v_bill."Name" || ' - due ' || to_char(p_due_date, 'Mon DD, YYYY')
        || coalesce(' (' || nullif(trim(coalesce(p_reference_no, '')), '') || ')', ''),
      p_amount, v_paid_date, v_bill."Warehouse"
    ) e;
  end if;

  insert into public."BusinessBillPayments"
    ("BillID", "DueDate", "PaidDate", "Amount", "Method", "ReferenceNo", "Notes", "ExpenseJournalEntryID", "CreatedBy")
  values
    (p_bill_id, p_due_date, v_paid_date, p_amount, nullif(trim(coalesce(p_method, '')), ''),
     nullif(trim(coalesce(p_reference_no, '')), ''), nullif(trim(coalesce(p_notes, '')), ''),
     v_entry, p_admin_username)
  returning "PaymentID" into v_id;

  return v_id;
end;
$$;

grant execute on function public.admin_pay_business_bill(text, text, uuid, date, date, numeric, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Void a payment (the period goes back to unpaid) and remove its linked Expense Journal entry.

drop function if exists public.admin_void_business_bill_payment(text, text, uuid);

create or replace function public.admin_void_business_bill_payment(
  p_admin_username text,
  p_admin_password text,
  p_payment_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry uuid;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."BusinessBillPayments" set "IsVoid" = true
  where "PaymentID" = p_payment_id and not "IsVoid"
  returning "ExpenseJournalEntryID" into v_entry;

  if not found then
    raise exception 'Payment not found or already voided.';
  end if;

  if v_entry is not null then
    perform public.admin_delete_expense_journal_entry(p_admin_username, p_admin_password, v_entry);
  end if;
end;
$$;

grant execute on function public.admin_void_business_bill_payment(text, text, uuid) to anon;
