-- Physical Inventory Journal - "Delete All Lines", per direct request: "in the physical inventory
-- journal can I delete all the lines?" (the batch had 673 zero-quantity lines from a broad Calculate
-- Inventory run and there was no way to clear it besides deleting one line at a time).
--
-- Run AFTER supabase_item_ledger_phys_inventory_journal.sql.
--
-- This only clears the WORKSHEET for one batch - it never touches the ledger (nothing has posted
-- yet for a line that hasn't been through Post). Any count already typed into a line that hasn't
-- been posted is lost; the page warns before calling this.

drop function if exists public.admin_clear_phys_journal_batch(text, text, text);

create or replace function public.admin_clear_phys_journal_batch(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_count int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_batch = '' then
    raise exception 'A batch name is required.';
  end if;

  delete from public."PhysInventoryJournalLines" where "BatchName" = v_batch;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_clear_phys_journal_batch(text, text, text) to anon;

notify pgrst, 'reload schema';
