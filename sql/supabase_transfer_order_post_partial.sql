-- Transfer Orders: every Receive now POSTS the order (moves it to Posted Transfers), even a partial
-- receipt - per "if the order has been received once can we post it as partial receipt .. sometimes
-- the user is not backreading the existing order and they are just creating new ones".
--
-- Anything SHIPPED but NOT received at that point is "short". The sender's stock already went down
-- at Ship and the receiver's only goes up at Receive, so without this the short units would sit in
-- no warehouse at all once the order is posted. The receiver picks one of two settlements in the
-- Receive popup (transferOrders.js receiveTransferOrder), applied here in one transaction:
--
--   'return'   - units never left / will go on a new order:
--                Item Ledger: +qty 'Transfer' at the From Warehouse (DocumentType 'Transfer Return').
--                Serials still IN_TRANSIT on this order -> IN_STOCK at the From Warehouse.
--                Transfer_Line."Qty Returned" += qty.
--   'writeoff' - units really went missing / broke:
--                Item Ledger at the From Warehouse: +qty 'Transfer' ('Transfer Return') then -qty
--                'Negative Adjmt.' ('Transfer Shortage'), same TransactionNo - net zero vs. today,
--                but the ledger now says "N lost on TR-..." against the sender, with who/when.
--                Serials still IN_TRANSIT on this order -> MISSING (the existing Serial Inventory
--                Journal status; Serial Tracker shows it, a FOUND count brings it back).
--                Transfer_Line."Qty Written Off" += qty.
--
-- Never-shipped quantities (Qty To Transfer > Qty Shipped) are NOT short - they never touched stock,
-- the posted order just shows them as not shipped.
--
-- Posted_Transfer_Line gets the same two columns, Posted_Transfer_Header gets "Short Action"
-- ('Returned' / 'Written Off' / null) so Posted Transfers can list/filter orders with shortages.
--
-- If "Transfer posting" is OFF in General Setup, the ledger entries are skipped (same rule as the
-- Ship/Receive trigger) - serials and the Qty columns are still updated.
--
-- Run AFTER supabase_posted_transfer_orders_tables.sql and supabase_item_ledger_transfer_posting_toggle.sql.
-- Safe to re-run. Settling is idempotent: it only ever settles Shipped - Received - Returned -
-- Written Off, so a retry after a failed archive never double-posts.

alter table public."Transfer_Line" add column if not exists "Qty Returned" numeric(18, 2);
alter table public."Transfer_Line" add column if not exists "Qty Written Off" numeric(18, 2);
alter table public."Posted_Transfer_Line" add column if not exists "Qty Returned" numeric(18, 2);
alter table public."Posted_Transfer_Line" add column if not exists "Qty Written Off" numeric(18, 2);
alter table public."Posted_Transfer_Header" add column if not exists "Short Action" varchar(20);

drop function if exists public.staff_settle_transfer_shortage(text, text, text, text, text);

create or replace function public.staff_settle_transfer_shortage(
  p_admin_username text,
  p_admin_password text,
  p_document_no text,
  p_action text,          -- 'return' | 'writeoff'
  p_actor text
)
returns table(line_no int, item_no text, variant_id text, qty numeric, serials_moved int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_action text := lower(trim(coalesce(p_action, '')));
  v_actor text := coalesce(nullif(trim(coalesce(p_actor, '')), ''), p_admin_username, 'system');
  v_posting boolean := coalesce((select s."TransferPostingEnabled" from public."ItemLedgerSetup" s limit 1), true);
  v_header record;
  v_line record;
  v_short numeric;
  v_variant text;
  v_tx bigint;
  v_moved int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_action not in ('return', 'writeoff') then
    raise exception 'Unknown shortage action "%" - expected return or writeoff.', p_action;
  end if;

  select h."From Warehouse ID" as from_id, h."From Warehouse" as from_name, h."To Warehouse" as to_name
    into v_header
    from public."Transfer_Header" h where h."No." = p_document_no;
  if not found then
    raise exception 'Transfer order % not found.', p_document_no;
  end if;

  for v_line in
    select l."Line No." as ln, l."Item No." as item, l."Variant ID" as variant,
           coalesce(l."Qty Shipped", 0) - coalesce(l."Qty Received", 0)
             - coalesce(l."Qty Returned", 0) - coalesce(l."Qty Written Off", 0) as short
    from public."Transfer_Line" l
    where l."Document No." = p_document_no
    order by l."Line No."
    for update
  loop
    v_short := v_line.short;
    continue when v_short is null or v_short <= 0 or nullif(trim(coalesce(v_line.item, '')), '') is null;
    v_variant := nullif(trim(coalesce(v_line.variant, '')), '');

    if v_posting then
      v_tx := nextval('public.ile_transaction_no_seq');
      perform public._ile_post(
        'Transfer', v_line.item, v_variant, coalesce(v_header.from_id, ''), v_short,
        public._ile_today(), 'Transfer Return', p_document_no,
        'Not received at ' || coalesce(v_header.to_name, '?') || ' - returned to sender', v_tx, v_actor
      );
      if v_action = 'writeoff' then
        perform public._ile_post(
          'Negative Adjmt.', v_line.item, v_variant, coalesce(v_header.from_id, ''), -v_short,
          public._ile_today(), 'Transfer Shortage', p_document_no,
          'Written off - shipped to ' || coalesce(v_header.to_name, '?') || ' but not received', v_tx, v_actor
        );
      end if;
    end if;

    with picked as (
      select s."RunningSerialNo"
      from public."ItemSerialTracking" s
      where s."Status" = 'IN_TRANSIT'
        and s."SourceDocumentNo" = p_document_no
        and s."ItemCode" = v_line.item
        and (case when v_variant is null then coalesce(nullif(trim(s."VariantCode"), ''), '') = ''
                  else s."VariantCode" = v_variant end)
      order by s."RunningSerialNo"
      limit ceil(v_short)::int
    ), moved as (
      update public."ItemSerialTracking" s
        set "Status" = case when v_action = 'writeoff' then 'MISSING' else 'IN_STOCK' end,
            "Location" = nullif(trim(coalesce(v_header.from_name, '')), ''),
            "UpdatedAtUtc" = now(),
            "UpdatedBy" = v_actor
        from picked p
        where s."RunningSerialNo" = p."RunningSerialNo"
        returning 1
    )
    select count(*) into v_moved from moved;

    update public."Transfer_Line" l
      set "Qty Returned" = case when v_action = 'return' then coalesce(l."Qty Returned", 0) + v_short else l."Qty Returned" end,
          "Qty Written Off" = case when v_action = 'writeoff' then coalesce(l."Qty Written Off", 0) + v_short else l."Qty Written Off" end,
          "Last Actor" = v_actor
      where l."Document No." = p_document_no and l."Line No." = v_line.ln;

    line_no := v_line.ln::int;
    item_no := v_line.item;
    variant_id := v_variant;
    qty := v_short;
    serials_moved := v_moved;
    return next;
  end loop;
end;
$$;

revoke execute on function public.staff_settle_transfer_shortage(text, text, text, text, text) from public;
grant execute on function public.staff_settle_transfer_shortage(text, text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the 5 new columns and the function (expect 6 rows, all 'ok').
select 'column' as section, table_name || '.' || column_name as item, 'ok' as status
from information_schema.columns
where table_schema = 'public'
  and ((table_name in ('Transfer_Line', 'Posted_Transfer_Line') and column_name in ('Qty Returned', 'Qty Written Off'))
    or (table_name = 'Posted_Transfer_Header' and column_name = 'Short Action'))
union all
select 'function', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'ok' else 'anon cannot execute' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_settle_transfer_shortage';
