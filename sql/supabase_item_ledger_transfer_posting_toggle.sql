-- Adds an on/off switch for Transfer Order -> Item Ledger posting, on General Setup, per direct
-- request: "can you post this routine for now? i mean add a setup under general setup to enable
-- 'item ledger writing for transfer order'".
--
-- WHY THIS IS USEFUL: right now Transfer Order Ship/Receive ALWAYS posts to the ledger the instant
-- Qty Shipped/Received changes (supabase_item_ledger_hooks.sql's "TR_Transfer_Line_ItemLedger"
-- trigger) - the only way to turn that off has been manually disabling the trigger in the SQL
-- editor (exactly what supabase_item_ledger_wipe_test_data.sql had to do for its own cleanup this
-- session). This gives a real switch for it instead, mirroring the existing "Start Posting Sales
-- From Now" pattern (ItemLedgerSetup) but as a plain toggle rather than a one-way start.
--
-- DEFAULT: ON (true) - preserves today's already-designed behaviour exactly as-is. Nothing changes
-- for you unless you actually flip it off on General Setup.
--
-- WHEN OFF: Ship/Receive still update Transfer_Line's own Qty Shipped/Received normally (no error,
-- documents still progress) - the trigger just skips posting to the ledger, which ALSO means the
-- "not enough stock at the source warehouse" check is skipped while off (that check only exists
-- because a ledger post happens - see supabase_item_ledger_hooks.sql's own comment on it).
--
-- Run AFTER supabase_item_ledger_hooks.sql.

alter table public."ItemLedgerSetup" add column if not exists "TransferPostingEnabled" boolean not null default true;

-- ============================================================================
-- 1. Gate the trigger on the new flag
-- ============================================================================

create or replace function public._ile_transfer_line_post()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ship_delta numeric;
  v_recv_delta numeric;
  v_header record;
  v_actor text := coalesce(nullif(trim(coalesce(new."Last Actor", '')), ''), 'system');
  v_variant text := nullif(trim(coalesce(new."Variant ID", '')), '');
begin
  if not coalesce((select s."TransferPostingEnabled" from public."ItemLedgerSetup" s limit 1), true) then
    return new;
  end if;

  v_ship_delta := coalesce(new."Qty Shipped", 0) - case when tg_op = 'UPDATE' then coalesce(old."Qty Shipped", 0) else 0 end;
  v_recv_delta := coalesce(new."Qty Received", 0) - case when tg_op = 'UPDATE' then coalesce(old."Qty Received", 0) else 0 end;

  if coalesce(new."Qty Shipped", 0) <= 0 then
    v_recv_delta := 0;
  end if;

  if v_ship_delta = 0 and v_recv_delta = 0 then
    return new;
  end if;

  select "From Warehouse ID" as from_id, "From Warehouse" as from_name,
         "To Warehouse ID" as to_id, "To Warehouse" as to_name
    into v_header
    from public."Transfer_Header" where "No." = new."Document No.";

  if v_ship_delta <> 0 then
    perform public._ile_post(
      'Transfer', new."Item No.", v_variant, coalesce(v_header.from_id, ''), -v_ship_delta,
      public._ile_today(), 'Transfer Shipment', new."Document No.",
      'Shipped to ' || coalesce(v_header.to_name, v_header.to_id, '?'), null, v_actor,
      null, true
    );
  end if;

  if v_recv_delta <> 0 then
    perform public._ile_post(
      'Transfer', new."Item No.", v_variant, coalesce(v_header.to_id, ''), v_recv_delta,
      public._ile_today(), 'Transfer Receipt', new."Document No.",
      'Received from ' || coalesce(v_header.from_name, v_header.from_id, '?'), null, v_actor
    );
  end if;

  return new;
end;
$$;

-- (trigger itself is unchanged - still fires on the same columns; only the function body changed)

-- ============================================================================
-- 2. General Setup read/write
-- ============================================================================

drop function if exists public.admin_get_item_ledger_transfer_posting_enabled(text, text);

create or replace function public.admin_get_item_ledger_transfer_posting_enabled(
  p_admin_username text,
  p_admin_password text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return coalesce((select s."TransferPostingEnabled" from public."ItemLedgerSetup" s limit 1), true);
end;
$$;

grant execute on function public.admin_get_item_ledger_transfer_posting_enabled(text, text) to anon;

drop function if exists public.admin_set_item_ledger_transfer_posting_enabled(text, text, boolean);

create or replace function public.admin_set_item_ledger_transfer_posting_enabled(
  p_admin_username text,
  p_admin_password text,
  p_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."ItemLedgerSetup" set "TransferPostingEnabled" = coalesce(p_enabled, true), "UpdatedAtUtc" = now();
end;
$$;

grant execute on function public.admin_set_item_ledger_transfer_posting_enabled(text, text, boolean) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect 2 rows, has_anon_execute = true, and the column to exist.
select column_name, data_type, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'ItemLedgerSetup' and column_name = 'TransferPostingEnabled';

select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_get_item_ledger_transfer_posting_enabled', 'admin_set_item_ledger_transfer_posting_enabled')
order by p.proname;
