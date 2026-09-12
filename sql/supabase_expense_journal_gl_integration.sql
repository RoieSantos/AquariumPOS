-- Folds the portal Expense Journal (supabase_expense_journal_tables.sql) into the General Ledger
-- side, same way it was already folded into the Dashboard's Expense Today/This Month totals and the
-- Posted Expenses list. Per direct follow-up ("why in the GL Setup there are no expense added on the
-- journal? how can we mapped it") - admin_list_gl_expense_category_map (gl-setup.html's "Expense
-- Categories" mapping table) and admin_post_expenses_to_gl (gl-entries.html's "Post Expenses to G/L"
-- button) both only ever read from ExpenseEntryHeader (the desktop-synced table) - a journal-only
-- category like META-ADS-EXPENSE had nothing to map, and a journal entry could never actually post
-- to the ledger, regardless of mapping.
--
-- Journal entries post using their own EXP-000000001-style ReceiptNo (supabase_expense_journal_
-- receipt_numbers.sql) as GLEntries.DocumentNo - distinct from the desktop's RS- receipts, so the
-- existing "already posted, skip it" idempotency check (DocumentType = 'Expense' AND DocumentNo =
-- <receipt>) can never collide between the two sources sharing one ledger.
--
-- Run this in the Supabase SQL Editor AFTER supabase_expense_journal_receipt_numbers.sql (needs
-- ExpenseJournalEntries.ReceiptNo to exist).

-- ---------------------------------------------------------------------------
-- admin_list_gl_expense_category_map: redefined (same signature) to union in categories that have
-- appeared on a journal entry, alongside the pre-existing desktop-synced source.

create or replace function public.admin_list_gl_expense_category_map(p_admin_username text, p_admin_password text)
returns table(expense_category text, account_no text, account_name text, is_mapped boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select c.category::text,
           m."AccountNo"::text,
           a."Name"::text,
           (m."AccountNo" is not null)
    from (
      select distinct nullif(trim(coalesce("ExpenseCategory", '')), '') as category
      from public."ExpenseEntryHeader"
      where nullif(trim(coalesce("ExpenseCategory", '')), '') is not null
      union
      select distinct nullif(trim(coalesce("ExpenseCategory", '')), '') as category
      from public."ExpenseJournalEntries"
      where nullif(trim(coalesce("ExpenseCategory", '')), '') is not null
    ) c
    left join public."GLExpenseCategoryMap" m on m."ExpenseCategory" = c.category
    left join public."GLAccounts" a on a."AccountNo" = m."AccountNo"
    order by (m."AccountNo" is not null), c.category;
end;
$$;

grant execute on function public.admin_list_gl_expense_category_map(text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_post_expenses_to_gl: redefined (same signature) - unchanged desktop-expense loop, plus a
-- second loop posting ExpenseJournalEntries the same way (EntryDate instead of Date, Amount instead
-- of NetAmount, its own ReceiptNo instead of the desktop one). Mapping/default-account resolution
-- (_gl_expense_account) and the actual double-entry posting (_gl_post) are exactly the same shared
-- helpers the desktop-expense loop already uses, so a journal entry posts identically to a
-- desktop-posted one once its category is mapped (or falls to the Default Expense account if not).

create or replace function public.admin_post_expenses_to_gl(
  p_admin_username text,
  p_admin_password text,
  p_from_date date,
  p_to_date date
)
returns table(posted_count int, skipped_count int, total_amount numeric, messages text[])
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_expense record;
  v_cash_account text;
  v_expense_account text;
  v_amount numeric;
  v_posted int := 0;
  v_skipped int := 0;
  v_total numeric := 0;
  v_messages text[] := array[]::text[];
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_from_date is null or p_to_date is null then
    raise exception 'A From and To date are both required.';
  end if;

  select s."CashAccountNo" into v_cash_account from public."GLSetup" s limit 1;
  if v_cash_account is null then
    raise exception 'No Cash account is configured. Set one in G/L Setup.';
  end if;

  for v_expense in
    select h."ReceiptNo", h."Date", h."NetAmount", h."Description", h."ExpenseCategory"
    from public."ExpenseEntryHeader" h
    where h."Date" >= p_from_date
      and h."Date" <= p_to_date
      and not exists (
        select 1 from public."GLEntries" e
        where e."DocumentType" = 'Expense' and e."DocumentNo" = h."ReceiptNo"
      )
    order by h."Date", h."ReceiptNo"
  loop
    v_amount := round(coalesce(v_expense."NetAmount", 0), 2);

    -- A zero or negative expense has nothing meaningful to post and would fail _gl_post's
    -- zero-amount check, so it is skipped by name rather than aborting the whole run.
    if v_amount <= 0 then
      v_skipped := v_skipped + 1;
      v_messages := v_messages || (v_expense."ReceiptNo" || ': amount is ' || v_amount || ' - skipped.');
      continue;
    end if;

    v_expense_account := public._gl_expense_account(v_expense."ExpenseCategory");

    perform public._gl_post(
      v_expense."Date",
      'Expense',
      v_expense."ReceiptNo",
      coalesce(nullif(trim(coalesce(v_expense."Description", '')), ''), 'Expense ' || v_expense."ReceiptNo"),
      'Expense',
      nullif(trim(coalesce(v_expense."ExpenseCategory", '')), ''),
      jsonb_build_array(
        jsonb_build_object('account_no', v_expense_account, 'amount', v_amount),
        jsonb_build_object('account_no', v_cash_account, 'amount', -v_amount)
      ),
      p_admin_username
    );

    v_posted := v_posted + 1;
    v_total := v_total + v_amount;
  end loop;

  -- Portal Expense Journal entries - same posting logic as above, just EntryDate/Amount/its own
  -- ReceiptNo in place of the desktop columns.
  for v_expense in
    select j."ReceiptNo", j."EntryDate" as "Date", j."Amount" as "NetAmount", j."Description", j."ExpenseCategory"
    from public."ExpenseJournalEntries" j
    where j."ReceiptNo" is not null
      and j."EntryDate" >= p_from_date
      and j."EntryDate" <= p_to_date
      and not exists (
        select 1 from public."GLEntries" e
        where e."DocumentType" = 'Expense' and e."DocumentNo" = j."ReceiptNo"
      )
    order by j."EntryDate", j."ReceiptNo"
  loop
    v_amount := round(coalesce(v_expense."NetAmount", 0), 2);

    if v_amount <= 0 then
      v_skipped := v_skipped + 1;
      v_messages := v_messages || (v_expense."ReceiptNo" || ': amount is ' || v_amount || ' - skipped.');
      continue;
    end if;

    v_expense_account := public._gl_expense_account(v_expense."ExpenseCategory");

    perform public._gl_post(
      v_expense."Date",
      'Expense',
      v_expense."ReceiptNo",
      coalesce(nullif(trim(coalesce(v_expense."Description", '')), ''), 'Expense ' || v_expense."ReceiptNo"),
      'Expense',
      nullif(trim(coalesce(v_expense."ExpenseCategory", '')), ''),
      jsonb_build_array(
        jsonb_build_object('account_no', v_expense_account, 'amount', v_amount),
        jsonb_build_object('account_no', v_cash_account, 'amount', -v_amount)
      ),
      p_admin_username
    );

    v_posted := v_posted + 1;
    v_total := v_total + v_amount;
  end loop;

  return query select v_posted, v_skipped, v_total, v_messages;
end;
$$;

grant execute on function public.admin_post_expenses_to_gl(text, text, date, date) to anon;
