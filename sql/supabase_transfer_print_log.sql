-- Transfer Order print log - per "can we put no. of time printed and who print the TO?" and
-- "i dont want to count cancelled prints".
--
-- Every time a Transfer Order (transfer-order-print.html) or its Production Order packing list
-- (transfer-order-print-production.html) print dialog opens, one row is logged here with who and when,
-- as 'Unconfirmed'. When the dialog closes, the page asks "Did it print?":
--   Yes -> 'Printed'     No -> 'Cancelled' (kept in the history, NOT counted)
-- No answer (tab closed) stays 'Unconfirmed' and IS counted, so closing the tab can't hide a print.
-- The printout shows its copy number ("Original" / "Copy #3") and the Manage modal on Transfer Orders
-- shows how many times each was printed and by whom.
--
-- Keyed by document number with no foreign key, so the history survives the order being received
-- and moved to Posted Transfers (Posted_Transfer_Header).
--
-- Safe to re-run. Run AFTER supabase_staff_session_tokens.sql (is_staff_authorized accepts tokens).

create table if not exists public."Transfer_Print_Log" (
    "Id"                  bigserial    primary key,
    "Document No."        varchar(50)  not null,
    "Print Type"          varchar(20)  not null check ("Print Type" in ('Transfer', 'Production')),
    "Printed By"          text         not null,
    "Printed By Username" text         not null,
    "Printed At"          timestamptz  not null default now()
);

alter table public."Transfer_Print_Log" add column if not exists "Result" varchar(20) not null default 'Unconfirmed';
alter table public."Transfer_Print_Log" drop constraint if exists "CK_Transfer_Print_Log_Result";
alter table public."Transfer_Print_Log" add constraint "CK_Transfer_Print_Log_Result"
  check ("Result" in ('Unconfirmed', 'Printed', 'Cancelled'));

create index if not exists "IX_Transfer_Print_Log_Doc" on public."Transfer_Print_Log" ("Document No.", "Printed At");

alter table public."Transfer_Print_Log" enable row level security;
revoke all on public."Transfer_Print_Log" from anon, authenticated;

-- Logs one print attempt ('Unconfirmed') and returns its id plus the copy number it will be
-- (prints of that document + type that weren't cancelled, this one included).
drop function if exists public.staff_log_transfer_print(text, text, text, text);
create or replace function public.staff_log_transfer_print(
  p_admin_username text, p_admin_password text, p_document_no text, p_print_type text
)
returns table(log_id bigint, print_no integer, printed_by text, printed_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
  v_id bigint;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if coalesce(trim(p_document_no), '') = '' then
    raise exception 'Document No. is required.';
  end if;
  if p_print_type not in ('Transfer', 'Production') then
    raise exception 'Print type must be Transfer or Production.';
  end if;

  select coalesce(nullif(trim(u."DisplayName"), ''), u."Username") into v_name
  from public."StaffUsers" u where u."Username" = p_admin_username;

  insert into public."Transfer_Print_Log" ("Document No.", "Print Type", "Printed By", "Printed By Username", "Result")
  values (trim(p_document_no), p_print_type, coalesce(v_name, p_admin_username), p_admin_username, 'Unconfirmed')
  returning "Id" into v_id;

  return query
  select v_id, count(*)::integer, coalesce(v_name, p_admin_username), now()
  from public."Transfer_Print_Log" l
  where l."Document No." = trim(p_document_no) and l."Print Type" = p_print_type and l."Result" <> 'Cancelled';
end;
$$;

-- The "Did it print?" answer. Only the person who printed can answer, and only once (Unconfirmed -> Printed/Cancelled).
create or replace function public.staff_set_transfer_print_result(
  p_admin_username text, p_admin_password text, p_log_id bigint, p_result text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_result not in ('Printed', 'Cancelled') then
    raise exception 'Result must be Printed or Cancelled.';
  end if;

  update public."Transfer_Print_Log"
  set "Result" = p_result
  where "Id" = p_log_id and "Printed By Username" = p_admin_username and "Result" = 'Unconfirmed';
end;
$$;

-- Full print history for one document, newest first (cancelled ones included - the page leaves them out of the count).
drop function if exists public.staff_get_transfer_print_log(text, text, text);
create or replace function public.staff_get_transfer_print_log(
  p_admin_username text, p_admin_password text, p_document_no text
)
returns table(print_type text, printed_by text, printed_at timestamptz, result text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  select l."Print Type"::text, l."Printed By", l."Printed At", l."Result"::text
  from public."Transfer_Print_Log" l
  where l."Document No." = trim(p_document_no)
  order by l."Printed At" desc;
end;
$$;

revoke all on function public.staff_log_transfer_print(text, text, text, text) from public;
revoke all on function public.staff_set_transfer_print_result(text, text, bigint, text) from public;
revoke all on function public.staff_get_transfer_print_log(text, text, text) from public;
grant execute on function public.staff_log_transfer_print(text, text, text, text) to anon, authenticated;
grant execute on function public.staff_set_transfer_print_result(text, text, bigint, text) to anon, authenticated;
grant execute on function public.staff_get_transfer_print_log(text, text, text) to anon, authenticated;
