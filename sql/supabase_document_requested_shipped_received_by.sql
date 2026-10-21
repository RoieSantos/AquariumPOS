-- Who requested / shipped / received - per "in the purchase order and transfer order i want to see
-- who request / shipped and received it".
--
-- TRANSFER ORDERS
--   Requested By / Shipped By already exist (supabase_transfer_orders_staff_columns.sql). This adds
--   "Received By" on Transfer_Header + Posted_Transfer_Header. The Transfer Orders page sets it with
--   Receive Date when the order is received (js/transferOrders.js), and the archive copies it across.
--   A BEFORE INSERT trigger on Posted_Transfer_Header fills it (and Shipped By) when an archive path
--   didn't carry it - the SQL clean-up routines list their columns and don't know the new one - from
--   the live header, else from the Item Ledger's Transfer Receipt entries.
--   Older posted transfers are backfilled from the ledger (who posted the Transfer Receipt /
--   Transfer Shipment entries for that document) - only where the ledger has them.
--
-- PURCHASE ORDERS
--   Requested = CreatedBy, Posted = PostedBy (both already stored). Received By isn't stored on the
--   PO; every receipt already posts an Item Ledger 'Purchase Receipt' entry crediting the person who
--   received, so it is read from there (falls back to the Pancake receipt log for receipts from
--   before the ledger). staff_get_purchase_order_people(p_po_nos[]) returns all three for open and
--   posted POs, so no existing PO function is redefined.
--
-- Names: stored usernames are shown as the staff member's Display Name (User Setup) when there is one.
--
-- Run AFTER supabase_transfer_orders_staff_columns.sql, supabase_item_ledger_hooks.sql and
-- supabase_purchase_order_pancake_sync.sql. Needs transfer-orders / posted-transfer-orders /
-- purchase-orders / posted-purchase-orders pages at cache v=whoby1. Safe to re-run.

alter table public."Transfer_Header" add column if not exists "Received By" varchar(200);
alter table public."Posted_Transfer_Header" add column if not exists "Received By" varchar(200);

-- Username -> Display Name (unchanged when it's already a display name or unknown).
create or replace function public._staff_display_name(p_who text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select nullif(trim(u."DisplayName"), '') from public."StaffUsers" u
      where lower(u."Username") = lower(trim(p_who)) limit 1),
    nullif(trim(p_who), ''));
$$;

revoke execute on function public._staff_display_name(text) from public, anon, authenticated;

-- Who posted a document's ledger entries of one type (latest first, distinct), as display names.
create or replace function public._ledger_document_actors(p_document_type text, p_document_no text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select string_agg(x.who, ', ' order by x.last_at desc)
    from (
      select public._staff_display_name(e."PostedBy") as who, max(e."PostedAtUtc") as last_at
        from public."ItemLedgerEntries" e
       where e."DocumentType" = p_document_type and e."DocumentNo" = p_document_no
         and e."ReversesEntryNo" is null
         and nullif(trim(coalesce(e."PostedBy", '')), '') is not null
         and lower(e."PostedBy") <> 'system'
       group by 1
    ) x;
$$;

revoke execute on function public._ledger_document_actors(text, text) from public, anon, authenticated;

-- ============================================================================
-- Transfer: fill Received By / Shipped By on archive when the writer didn't
-- ============================================================================

create or replace function public._posted_transfer_fill_people()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if nullif(trim(coalesce(new."Received By", '')), '') is null then
    new."Received By" := (select nullif(trim(h."Received By"), '')
                            from public."Transfer_Header" h where h."No." = new."No.");
    if new."Received By" is null then
      new."Received By" := left(public._ledger_document_actors('Transfer Receipt', new."No."), 200);
    end if;
  end if;
  if nullif(trim(coalesce(new."Shipped By", '')), '') is null then
    new."Shipped By" := left(public._ledger_document_actors('Transfer Shipment', new."No."), 200);
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_Posted_Transfer_Header_FillPeople" on public."Posted_Transfer_Header";
create trigger "TR_Posted_Transfer_Header_FillPeople"
  before insert on public."Posted_Transfer_Header"
  for each row execute function public._posted_transfer_fill_people();

-- Backfill older posted transfers from the ledger (only blanks are filled).
update public."Posted_Transfer_Header" h
   set "Received By" = left(public._ledger_document_actors('Transfer Receipt', h."No."), 200)
 where nullif(trim(coalesce(h."Received By", '')), '') is null
   and public._ledger_document_actors('Transfer Receipt', h."No.") is not null;

update public."Posted_Transfer_Header" h
   set "Shipped By" = left(public._ledger_document_actors('Transfer Shipment', h."No."), 200)
 where nullif(trim(coalesce(h."Shipped By", '')), '') is null
   and public._ledger_document_actors('Transfer Shipment', h."No.") is not null;

-- Open transfers already partly received (rare - receiving normally posts and archives at once).
update public."Transfer_Header" h
   set "Received By" = left(public._ledger_document_actors('Transfer Receipt', h."No."), 200)
 where nullif(trim(coalesce(h."Received By", '')), '') is null
   and public._ledger_document_actors('Transfer Receipt', h."No.") is not null;

-- ============================================================================
-- Purchase Orders: requested / received / posted by
-- ============================================================================

drop function if exists public.staff_get_purchase_order_people(text, text, text[]);

create or replace function public.staff_get_purchase_order_people(
  p_admin_username text,
  p_admin_password text,
  p_po_nos text[]
)
returns table(po_no text, requested_by text, requested_at timestamptz, received_by text,
              received_at timestamptz, posted_by text, posted_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with nos as (
      select distinct trim(n) as no from unnest(coalesce(p_po_nos, array[]::text[])) n
       where nullif(trim(n), '') is not null
    ),
    heads as (
      select po."PONo" as no, po."CreatedBy" as created_by, po."CreatedAtUtc" as created_at,
             null::text as posted_by, null::timestamptz as posted_at
        from public."PurchaseOrders" po where po."PONo" in (select no from nos)
      union all
      select pp."PONo", pp."CreatedBy", pp."CreatedAtUtc", pp."PostedBy", pp."PostedAtUtc"
        from public."PostedPurchaseOrders" pp where pp."PONo" in (select no from nos)
    ),
    -- Every receipt: the ledger's Purchase Receipt entries, plus the Pancake receipt log (older
    -- receipts from before the ledger existed only live there).
    receipts as (
      select e."DocumentNo" as no, e."PostedBy" as who, e."PostedAtUtc" as at
        from public."ItemLedgerEntries" e
       where e."DocumentType" = 'Purchase Receipt' and e."DocumentNo" in (select no from nos)
         and e."ReversesEntryNo" is null and e."Quantity" > 0
      union all
      select r."PONo", r."ReceivedBy", r."ReceivedAtUtc"
        from public."PurchaseOrder_Pancake_Purchases" r
       where r."PONo" in (select no from nos)
    ),
    rcv as (
      select x.no, string_agg(x.name, ', ' order by x.last_at desc) as names, max(x.last_at) as last_at
        from (
          select r.no, public._staff_display_name(r.who) as name, max(r.at) as last_at
            from receipts r
           where nullif(trim(coalesce(r.who, '')), '') is not null
           group by 1, 2
        ) x
       group by x.no
    )
    select h.no::text, public._staff_display_name(h.created_by), h.created_at,
           r.names, r.last_at,
           public._staff_display_name(h.posted_by), h.posted_at
      from heads h
      left join rcv r on r.no = h.no;
end;
$$;

grant execute on function public.staff_get_purchase_order_people(text, text, text[]) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: columns, trigger, function, and how many documents have names now.
select 'column' as section, table_name::text as item, column_name::text as value
  from information_schema.columns
 where table_schema = 'public' and column_name = 'Received By'
   and table_name in ('Transfer_Header', 'Posted_Transfer_Header')
union all
select 'trigger', tgname::text, case when tgenabled <> 'D' then 'enabled' else 'DISABLED' end
  from pg_trigger where tgname = 'TR_Posted_Transfer_Header_FillPeople'
union all
select 'function', p.proname::text,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon ok' else 'NOT GRANTED' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'staff_get_purchase_order_people'
union all
select 'posted transfers', 'with Received By / total',
       count(*) filter (where nullif(trim(coalesce("Received By", '')), '') is not null)::text || ' / ' || count(*)::text
  from public."Posted_Transfer_Header"
union all
select 'posted transfers', 'with Shipped By / total',
       count(*) filter (where nullif(trim(coalesce("Shipped By", '')), '') is not null)::text || ' / ' || count(*)::text
  from public."Posted_Transfer_Header";
