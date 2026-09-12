-- Expense Journal category management - per direct follow-up request: the Expense Journal's
-- Category field (supabase_expense_journal_tables.sql) only ever offered categories already seen on
-- a real posted expense, typed straight into that field. That works but there was no way to add a
-- brand-new category up front, before any expense using it existed - this adds exactly that: a small
-- Code + Description list a super user manages directly, in the same "CODE - Description" shape
-- already shown in the Category suggestions (e.g. "FLOAT - Float Expense"), which is how the
-- desktop's own ExpenseCategorySetup table (ExpenseCategorySetupForm.cs, stays local, never synced)
-- has always displayed its categories.
--
-- This does NOT replace the "categories already used" source added in supabase_expense_journal_
-- tables.sql - admin_list_expense_journal_categories (redefined below) now unions both, so nothing
-- already in use as a suggestion disappears.
--
-- Run this in the Supabase SQL Editor AFTER supabase_expense_journal_tables.sql.

create table if not exists public."ExpenseJournalCategories" (
    "Code" varchar(50) primary key,
    "Description" varchar(200) not null,
    "CreatedBy" varchar(100) not null,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."ExpenseJournalCategories" enable row level security;
revoke all on public."ExpenseJournalCategories" from anon, authenticated;

comment on table public."ExpenseJournalCategories" is 'Super-user-managed Code/Description list for the Expense Journal Category field, formatted as "Code - Description" in suggestions - independent of, and additive to, categories already seen on real posted expenses.';

-- ---------------------------------------------------------------------------
-- admin_list_expense_journal_category_setup: the raw managed list itself, for the "Manage
-- Categories" panel (add/delete) - as opposed to admin_list_expense_journal_categories below, which
-- is the combined, already-formatted list the Add Expense field's suggestions are built from.

drop function if exists public.admin_list_expense_journal_category_setup(text, text);

create or replace function public.admin_list_expense_journal_category_setup(p_admin_username text, p_admin_password text)
returns table(code text, description text, created_by text, created_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Code"::text, "Description"::text, "CreatedBy"::text, "CreatedAtUtc"
    from public."ExpenseJournalCategories"
    order by "Code";
end;
$$;

grant execute on function public.admin_list_expense_journal_category_setup(text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_add_expense_journal_category: Code is uppercased for a consistent look next to the
-- desktop-style codes already seen in suggestions (FLOAT, FOOD, INSTORE, LALAMOVE, ...).

drop function if exists public.admin_add_expense_journal_category(text, text, text, text);

create or replace function public.admin_add_expense_journal_category(p_admin_username text, p_admin_password text, p_code text, p_description text)
returns table(code text, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_description text := trim(coalesce(p_description, ''));
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_code = '' then
    raise exception 'Category code is required.';
  end if;

  if v_description = '' then
    raise exception 'Category description is required.';
  end if;

  if exists (select 1 from public."ExpenseJournalCategories" where "Code" = v_code) then
    raise exception 'A category with code "%" already exists.', v_code;
  end if;

  return query
    insert into public."ExpenseJournalCategories" ("Code", "Description", "CreatedBy")
    values (v_code, v_description, p_admin_username)
    returning "Code"::text, "Description"::text;
end;
$$;

grant execute on function public.admin_add_expense_journal_category(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_delete_expense_journal_category: removes a category from the managed list only - past
-- journal entries already store their own category as a plain text snapshot (ExpenseJournalEntries.
-- "ExpenseCategory"), so deleting it here never touches or orphans any existing entry.

drop function if exists public.admin_delete_expense_journal_category(text, text, text);

create or replace function public.admin_delete_expense_journal_category(p_admin_username text, p_admin_password text, p_code text)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  delete from public."ExpenseJournalCategories" where "Code" = upper(trim(coalesce(p_code, '')));

  if not found then
    return query select false, 'Category not found.'::text;
    return;
  end if;

  return query select true, 'Category deleted.'::text;
end;
$$;

grant execute on function public.admin_delete_expense_journal_category(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_list_expense_journal_categories: redefined (same signature) to union the managed list above
-- (formatted "Code - Description") with the pre-existing "categories already used" source, so a
-- category is offered as a suggestion whether it was set up ahead of time here or just typed once on
-- a real entry.

create or replace function public.admin_list_expense_journal_categories(p_admin_username text, p_admin_password text)
returns table(category text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select distinct c.category from (
      select ("Code" || ' - ' || "Description") as category from public."ExpenseJournalCategories"
      union
      select trim("ExpenseCategory") as category from public."ExpenseEntryHeader"
      union
      select trim("ExpenseCategory") as category from public."ExpenseJournalEntries"
    ) c
    where c.category is not null and c.category <> ''
    order by 1;
end;
$$;

grant execute on function public.admin_list_expense_journal_categories(text, text) to anon;
