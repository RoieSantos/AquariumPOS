-- Item Ledger Entries - per direct request: "i want to be able to track all inventory movements ..
-- Item Ledger Entries feature from Business Central" and "forget about pancake now. i want to
-- implement item ledger entry in this portal first".
--
-- Until now the portal had no record of stock movement at all: Items.QuantityInStock is a single
-- global number mirrored from elsewhere, and posting a PO or Transfer Order archives the document
-- without moving any stock. This adds the ledger that stock will be driven from.
--
-- MODELLED ON BUSINESS CENTRAL'S ITEM LEDGER ENTRY, same way GLEntries models G/L Entry
-- (supabase_general_ledger.sql):
--   * APPEND-ONLY. A row is never updated or deleted - a mistake is corrected by posting a
--     reversing entry. Enforced by trigger below, not just by convention.
--   * One signed Quantity per row (receipts positive, issues negative). On-hand stock is simply
--     SUM(Quantity) for an item/variant/warehouse - there is no separate "current stock" column to
--     drift out of step with the history.
--   * EntryType is BC's own set: Purchase, Sale, Positive Adjmt., Negative Adjmt., Transfer.
--     (Consumption/Output are BC's manufacturing types - nothing here uses them.)
--   * TransactionNo groups the rows one posting wrote (an adjustment batch, one PO receive click),
--     so they are shown and reversed as a unit.
--   * Per VARIANT: every row carries an optional VariantId, and balances are kept per
--     item + variant + warehouse. A row with no variant is the plain item.
--
-- WHAT WRITES HERE
--   * Manual Positive/Negative Adjustments (admin_post_item_adjustments) - also how opening
--     balances get loaded.
--   * Reversals (admin_reverse_item_ledger_transaction).
--   * Purchase Order receiving and Transfer Order ship/receive - wired up in
--     supabase_item_ledger_hooks.sql (run that after this file).
--   * Sales are NOT hooked in yet - see the note at the bottom of that file.
--
-- NEGATIVE STOCK. Where someone is choosing to take stock out (a transfer shipment, a negative
-- adjustment) the movement is refused if it would take the balance below zero. Where it can't be
-- refused (a sale that already happened, a reversal) it is allowed, and the balances report shows
-- the negative in red so it can be investigated.

-- ============================================================================
-- 1. Item Ledger Entries
-- ============================================================================

-- Groups the one-or-more rows that make up one posting.
create sequence if not exists public.ile_transaction_no_seq as bigint;

-- "Today" for posting dates is the shop's day (Manila), not the database server's UTC day - an
-- evening receipt would otherwise post as tomorrow's date.
create or replace function public._ile_today()
returns date
language sql
stable
as $$ select (now() at time zone 'Asia/Manila')::date $$;

create table if not exists public."ItemLedgerEntries" (
    "EntryNo" bigint generated always as identity primary key,
    "TransactionNo" bigint not null,
    "PostingDate" date not null,
    "EntryType" varchar(20) not null check ("EntryType" in ('Purchase', 'Sale', 'Positive Adjmt.', 'Negative Adjmt.', 'Transfer')),
    -- Deliberately NOT foreign keys to Items/Variants/Warehouses: those tables are mirrored/synced
    -- and can be re-synced or pruned, and a ledger row must outlive that. _ile_post validates them
    -- at write time instead.
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100),
    "WarehouseId" varchar(100) not null,
    -- Signed: receipts positive, issues negative. numeric(18,4) rather than 2dp so a fractional
    -- unit-of-measure conversion never gets rounded away in the ledger.
    "Quantity" numeric(18, 4) not null check ("Quantity" <> 0),
    "DocumentType" varchar(40),
    "DocumentNo" varchar(50),
    "Description" varchar(500),
    -- Set only on a reversing entry: the original entry it cancels out.
    "ReversesEntryNo" bigint references public."ItemLedgerEntries" ("EntryNo"),
    "PostedBy" varchar(100),
    "PostedAtUtc" timestamptz not null default now()
);

alter table public."ItemLedgerEntries" enable row level security;
revoke all on public."ItemLedgerEntries" from anon, authenticated;

create index if not exists "IX_ItemLedgerEntries_Item_Warehouse" on public."ItemLedgerEntries" ("ItemCode", "WarehouseId");
create index if not exists "IX_ItemLedgerEntries_PostingDate" on public."ItemLedgerEntries" ("PostingDate");
create index if not exists "IX_ItemLedgerEntries_TransactionNo" on public."ItemLedgerEntries" ("TransactionNo");
create index if not exists "IX_ItemLedgerEntries_Document" on public."ItemLedgerEntries" ("DocumentType", "DocumentNo");

-- An entry can be reversed at most once. This also closes the race where two people click Reverse
-- on the same entry at the same moment - the second insert fails instead of double-reversing.
create unique index if not exists "UX_ItemLedgerEntries_ReversesEntryNo"
    on public."ItemLedgerEntries" ("ReversesEntryNo") where "ReversesEntryNo" is not null;

comment on table public."ItemLedgerEntries" is 'Append-only item ledger. Never UPDATE or DELETE a row here - correct a mistake by posting a reversing entry, so stock history stays auditable.';

-- Append-only, enforced. Row-level for UPDATE/DELETE, statement-level for TRUNCATE. A table owner
-- can still ALTER TABLE ... DISABLE TRIGGER in the SQL editor for a deliberate one-off clean-up
-- (e.g. wiping test rows before go-live) - that is the intended escape hatch, and it can't be
-- reached from the portal.
create or replace function public._ile_block_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'TRUNCATE' then
    raise exception 'ItemLedgerEntries is append-only - it cannot be truncated.';
  end if;
  raise exception 'ItemLedgerEntries is append-only - entry % cannot be %d. Post a reversing entry instead.', old."EntryNo", lower(tg_op);
end;
$$;

drop trigger if exists "TR_ItemLedgerEntries_NoUpdateDelete" on public."ItemLedgerEntries";
create trigger "TR_ItemLedgerEntries_NoUpdateDelete"
  before update or delete on public."ItemLedgerEntries"
  for each row execute function public._ile_block_mutation();

drop trigger if exists "TR_ItemLedgerEntries_NoTruncate" on public."ItemLedgerEntries";
create trigger "TR_ItemLedgerEntries_NoTruncate"
  before truncate on public."ItemLedgerEntries"
  for each statement execute function public._ile_block_mutation();

-- ============================================================================
-- 2. Posting engine
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Stock key: which "shelf" a movement belongs to.
--
-- The stock unit is ITEM + VARIANT + WAREHOUSE, but a variant only means something when the item
-- actually has several. Two shapes exist in this catalog:
--   * A variant with its OWN Items row (Variants.ItemCode = that row): the item code alone already
--     says which variant it is, so the variant id is redundant and is stored as null.
--   * Several variants that all resolve to ONE Items row (Variants.ItemCode = the parent): here the
--     variant id is the only thing telling them apart, so it is REQUIRED and stored.
-- Normalising like this keeps a plain item's balance in one row instead of splitting it between
-- "no variant" and "its only variant", which would make every balance quietly wrong.
--
-- A variant that has its own Items row but is passed against the parent's code (the Adjustment
-- form's variant picker lists variants by parent) is re-pointed at its own item.
-- ----------------------------------------------------------------------------
create or replace function public._ile_resolve_stock_key(p_item_code text, p_variant_id text)
returns table(item_code text, variant_id text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_item text := trim(coalesce(p_item_code, ''));
  v_variant text := nullif(trim(coalesce(p_variant_id, '')), '');
  v_variant_item text;
  v_variant_main text;
  v_count int;
begin
  if v_variant is not null then
    select v."ItemCode", v."MainItemCode" into v_variant_item, v_variant_main
      from public."Variants" v where v."VariationId" = v_variant;

    if not found then
      raise exception 'Variant "%" does not exist.', v_variant;
    end if;

    if v_variant_item is not null and v_variant_item <> v_item and v_variant_main = v_item then
      v_item := v_variant_item;
    elsif coalesce(v_variant_item, '') <> v_item and coalesce(v_variant_main, '') <> v_item then
      raise exception 'Variant "%" does not belong to item "%".', v_variant, v_item;
    end if;
  end if;

  select count(*) into v_count from public."Variants" v where v."ItemCode" = v_item;

  if v_count >= 2 then
    if v_variant is null then
      raise exception 'Item "%" has % variants - pick which variant.', v_item, v_count;
    end if;
    return query select v_item, v_variant;
  else
    return query select v_item, null::text;
  end if;
end;
$$;

revoke execute on function public._ile_resolve_stock_key(text, text) from public, anon, authenticated;

-- On-hand for one stock key, straight from the ledger. Pass the RESOLVED key.
create or replace function public._ile_balance(p_item_code text, p_variant_id text, p_warehouse_id text)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(sum(e."Quantity"), 0)
  from public."ItemLedgerEntries" e
  where e."ItemCode" = p_item_code
    and e."WarehouseId" = p_warehouse_id
    and coalesce(e."VariantId", '') = coalesce(p_variant_id, '')
$$;

revoke execute on function public._ile_balance(text, text, text) from public, anon, authenticated;

-- The one and only way a row gets written. Every stock-moving workflow (adjustments, PO receiving,
-- transfers, and sales later) calls this rather than inserting directly, so the validation lives
-- in exactly one place.
--
-- Deliberately does NOT check the sign against the entry type: a reversal of a Purchase is a
-- negative Purchase row, exactly as in BC. Callers that want that rule (the adjustment RPC) apply
-- it themselves.
--
-- p_prevent_negative: refuse a movement that would take this stock key below zero. Used where
-- someone is choosing to take stock out (transfer shipments, negative adjustments). Left off for
-- reversals (a correction must always be possible) and for sales (a sale that already happened
-- can't be refused - it just shows as negative stock to be investigated). Serialised per stock key
-- so two simultaneous shipments can't both pass the check against the same stock.
--
-- Not granted to anon - this is an internal building block, and it does no authorization of its
-- own. Only the admin_*/staff_* RPCs (which do) may reach it.
-- The first version had 12 parameters. Left in place next to this 13-parameter one, a call with
-- only the required arguments would match both and fail as ambiguous.
drop function if exists public._ile_post(text, text, text, text, numeric, date, text, text, text, bigint, text, bigint);

create or replace function public._ile_post(
  p_entry_type text,
  p_item_code text,
  p_variant_id text,
  p_warehouse_id text,
  p_quantity numeric,
  p_posting_date date,
  p_document_type text,
  p_document_no text,
  p_description text,
  p_transaction_no bigint,
  p_posted_by text,
  p_reverses_entry_no bigint default null,
  p_prevent_negative boolean default false
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry_no bigint;
  v_item text;
  v_variant text;
  v_warehouse_name text;
  v_on_hand numeric;
begin
  if p_quantity is null or p_quantity = 0 then
    raise exception 'Item % has a zero quantity - nothing to post.', p_item_code;
  end if;

  if not exists (select 1 from public."Items" where "Code" = trim(coalesce(p_item_code, ''))) then
    raise exception 'Item "%" does not exist.', p_item_code;
  end if;

  select w."Name" into v_warehouse_name from public."Warehouses" w where w."ID" = p_warehouse_id;
  if not found then
    raise exception 'Warehouse "%" does not exist.', p_warehouse_id;
  end if;

  select k.item_code, k.variant_id into v_item, v_variant
    from public._ile_resolve_stock_key(p_item_code, p_variant_id) k;

  if not exists (select 1 from public."Items" where "Code" = v_item) then
    raise exception 'Item "%" does not exist.', v_item;
  end if;

  if coalesce(p_prevent_negative, false) and p_quantity < 0 then
    perform pg_advisory_xact_lock(hashtext(v_item || '|' || coalesce(v_variant, '') || '|' || p_warehouse_id));
    v_on_hand := public._ile_balance(v_item, v_variant, p_warehouse_id);
    if v_on_hand + p_quantity < 0 then
      raise exception 'Not enough stock: % has % on hand at %, cannot take out %.',
        v_item || coalesce(' (' || v_variant || ')', ''), v_on_hand, coalesce(v_warehouse_name, p_warehouse_id), -p_quantity;
    end if;
  end if;

  insert into public."ItemLedgerEntries" (
    "TransactionNo", "PostingDate", "EntryType", "ItemCode", "VariantId", "WarehouseId", "Quantity",
    "DocumentType", "DocumentNo", "Description", "ReversesEntryNo", "PostedBy"
  )
  values (
    coalesce(p_transaction_no, nextval('public.ile_transaction_no_seq')),
    coalesce(p_posting_date, public._ile_today()), p_entry_type, v_item, v_variant, p_warehouse_id,
    round(p_quantity, 4), p_document_type, p_document_no, left(p_description, 500),
    p_reverses_entry_no, p_posted_by
  )
  returning "EntryNo" into v_entry_no;

  return v_entry_no;
end;
$$;

revoke execute on function public._ile_post(text, text, text, text, numeric, date, text, text, text, bigint, text, bigint, boolean) from public, anon, authenticated;

-- ============================================================================
-- 3. Manual adjustments (also how opening balances are loaded)
-- ============================================================================

drop function if exists public.admin_post_item_adjustments(text, text, date, text, jsonb);

-- p_lines is [{"item_code": "...", "variant_id": "..." or null, "warehouse_id": "...", "quantity": 12}]
-- with quantity SIGNED (positive adds stock, negative removes it) - the entry type follows from the
-- sign. All lines post under one TransactionNo and one ADJ- document number, and the whole batch is
-- all-or-nothing: a bad line on row 40 leaves nothing written. A reason is mandatory, because an
-- unexplained stock change is exactly what a ledger exists to prevent.
create or replace function public.admin_post_item_adjustments(
  p_admin_username text,
  p_admin_password text,
  p_posting_date date,
  p_description text,
  p_lines jsonb
)
returns table(transaction_no bigint, document_no text, entries_posted int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_transaction_no bigint;
  v_document_no text;
  v_line jsonb;
  v_line_no int := 0;
  v_quantity numeric;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_description is null or trim(p_description) = '' then
    raise exception 'A reason is required for every stock adjustment.';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one adjustment line.';
  end if;

  v_transaction_no := nextval('public.ile_transaction_no_seq');
  v_document_no := 'ADJ-' || lpad(v_transaction_no::text, 6, '0');

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_line_no := v_line_no + 1;
    v_quantity := coalesce((v_line ->> 'quantity')::numeric, 0);

    if v_quantity = 0 then
      raise exception 'Line %: quantity cannot be zero.', v_line_no;
    end if;

    perform public._ile_post(
      case when v_quantity > 0 then 'Positive Adjmt.' else 'Negative Adjmt.' end,
      trim(coalesce(v_line ->> 'item_code', '')),
      v_line ->> 'variant_id',
      trim(coalesce(v_line ->> 'warehouse_id', '')),
      v_quantity,
      p_posting_date,
      'Adjustment',
      v_document_no,
      trim(p_description),
      v_transaction_no,
      p_admin_username,
      null,
      v_quantity < 0
    );
  end loop;

  return query select v_transaction_no, v_document_no, v_line_no;
end;
$$;

grant execute on function public.admin_post_item_adjustments(text, text, date, text, jsonb) to anon;

-- ============================================================================
-- 4. Reversals
-- ============================================================================

drop function if exists public.admin_reverse_item_ledger_transaction(text, text, bigint, text);

-- Extension point called for every entry a reversal cancels. No-op by default - see the call site.
create or replace function public._ile_on_reversed(p_entry public."ItemLedgerEntries")
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  null;
end;
$$;

revoke execute on function public._ile_on_reversed(public."ItemLedgerEntries") from public, anon, authenticated;

-- Reverses the WHOLE transaction the given entry belongs to (an adjustment batch, or everything one
-- PO receive click posted) by posting the mirror image dated today. The original rows are left exactly as they
-- were. A reversal can't itself be reversed - post a fresh entry if the reversal was wrong.
create or replace function public.admin_reverse_item_ledger_transaction(
  p_admin_username text,
  p_admin_password text,
  p_entry_no bigint,
  p_reason text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_transaction_no bigint;
  v_new_transaction_no bigint;
  v_row public."ItemLedgerEntries";
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to reverse a ledger entry.';
  end if;

  select "TransactionNo" into v_transaction_no
    from public."ItemLedgerEntries" where "EntryNo" = p_entry_no;

  if v_transaction_no is null then
    raise exception 'Ledger entry % not found.', p_entry_no;
  end if;

  if exists (select 1 from public."ItemLedgerEntries" where "TransactionNo" = v_transaction_no and "ReversesEntryNo" is not null) then
    raise exception 'Entry % is itself a reversal and cannot be reversed. Post a new adjustment instead.', p_entry_no;
  end if;

  if exists (
    select 1
    from public."ItemLedgerEntries" r
    join public."ItemLedgerEntries" o on o."EntryNo" = r."ReversesEntryNo"
    where o."TransactionNo" = v_transaction_no
  ) then
    raise exception 'This transaction has already been reversed.';
  end if;

  v_new_transaction_no := nextval('public.ile_transaction_no_seq');

  for v_row in
    select * from public."ItemLedgerEntries" where "TransactionNo" = v_transaction_no order by "EntryNo"
  loop
    perform public._ile_post(
      v_row."EntryType",
      v_row."ItemCode",
      v_row."VariantId",
      v_row."WarehouseId",
      -v_row."Quantity",
      public._ile_today(),
      coalesce(v_row."DocumentType", 'Entry') || ' Reversal',
      v_row."DocumentNo",
      'Reversal of entry ' || v_row."EntryNo" || ': ' || trim(p_reason),
      v_new_transaction_no,
      p_admin_username,
      v_row."EntryNo"
    );

    -- Lets the document behind an entry react to being reversed (a PO receipt gives its received
    -- quantity back). A no-op here; supabase_item_ledger_hooks.sql supplies the real behaviour.
    perform public._ile_on_reversed(v_row);
  end loop;

  return v_new_transaction_no;
end;
$$;

grant execute on function public.admin_reverse_item_ledger_transaction(text, text, bigint, text) to anon;

-- ============================================================================
-- 5. Reading the ledger
-- ============================================================================

drop function if exists public.admin_list_item_ledger_entries(text, text, date, date, text, text, text, int, int);

-- p_search matches item code/name, variant name/SKU, document no. and description. total_quantity is a window total
-- over the WHOLE filtered set, not just the page on screen (same idea as the G/L page's totals).
-- is_reversed / is_reversal drive the page's greyed-out styling and hide the Reverse button where
-- it can't apply.
create or replace function public.admin_list_item_ledger_entries(
  p_admin_username text,
  p_admin_password text,
  p_from_date date default null,
  p_to_date date default null,
  p_search text default null,
  p_warehouse_id text default null,
  p_entry_type text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  entry_no bigint, transaction_no bigint, posting_date date, entry_type text,
  item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text, quantity numeric,
  document_type text, document_no text, description text, posted_by text, posted_at_utc timestamptz,
  is_reversed boolean, is_reversal boolean,
  total_count bigint, total_quantity numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      e."EntryNo", e."TransactionNo", e."PostingDate", e."EntryType"::text,
      e."ItemCode"::text, coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), e."ItemCode")::text,
      e."VariantId"::text, v."VariantName"::text,
      e."WarehouseId"::text, coalesce(w."Name", e."WarehouseId")::text, e."Quantity",
      e."DocumentType"::text, e."DocumentNo"::text, e."Description"::text, e."PostedBy"::text, e."PostedAtUtc",
      exists (select 1 from public."ItemLedgerEntries" r where r."ReversesEntryNo" = e."EntryNo"),
      e."ReversesEntryNo" is not null,
      count(*) over(), sum(e."Quantity") over()
    from public."ItemLedgerEntries" e
    left join public."Items" i on i."Code" = e."ItemCode"
    left join public."Variants" v on v."VariationId" = e."VariantId"
    left join public."Warehouses" w on w."ID" = e."WarehouseId"
    where (p_from_date is null or e."PostingDate" >= p_from_date)
      and (p_to_date is null or e."PostingDate" <= p_to_date)
      and (p_warehouse_id is null or trim(p_warehouse_id) = '' or e."WarehouseId" = p_warehouse_id)
      and (p_entry_type is null or trim(p_entry_type) = '' or e."EntryType" = p_entry_type)
      and (
        p_search is null or trim(p_search) = ''
        or e."ItemCode" ilike '%' || trim(p_search) || '%'
        or i."Name" ilike '%' || trim(p_search) || '%'
        or e."DocumentNo" ilike '%' || trim(p_search) || '%'
        or e."Description" ilike '%' || trim(p_search) || '%'
        or v."VariantName" ilike '%' || trim(p_search) || '%'
        or v."SKU" ilike '%' || trim(p_search) || '%'
      )
    order by e."PostingDate" desc, e."EntryNo" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_item_ledger_entries(text, text, date, date, text, text, text, int, int) to anon;

drop function if exists public.admin_get_item_ledger_balances(text, text, date, text, text, int, int);
drop function if exists public.admin_get_item_ledger_balances(text, text, date, text, text, boolean, int, int);

-- On-hand stock per item / variant / warehouse, computed straight from the ledger as of a date
-- (blank = today, i.e. everything posted). qty_in / qty_out are the gross positive / negative
-- movement so a balance of 0 can be told apart from "never moved". total_balance is a window total
-- over the whole filtered set. Only combinations that have at least one entry appear.
--
-- Per variant: by default every item + variant + warehouse is its own row. p_combine_variants
-- rolls an item's variants up into one row per item + warehouse (variant columns come back null) -
-- the item-level on-hand figure Business Central shows on the Item Card.
create or replace function public.admin_get_item_ledger_balances(
  p_admin_username text,
  p_admin_password text,
  p_as_of_date date default null,
  p_search text default null,
  p_warehouse_id text default null,
  p_combine_variants boolean default false,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  qty_in numeric, qty_out numeric, balance numeric,
  total_count bigint, total_balance numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with grouped as (
      select
        e."ItemCode" as g_item_code,
        case when coalesce(p_combine_variants, false) then null else e."VariantId" end as g_variant_id,
        e."WarehouseId" as g_warehouse_id,
        coalesce(sum(e."Quantity") filter (where e."Quantity" > 0), 0) as g_in,
        coalesce(-sum(e."Quantity") filter (where e."Quantity" < 0), 0) as g_out,
        sum(e."Quantity") as g_balance
      from public."ItemLedgerEntries" e
      left join public."Items" i on i."Code" = e."ItemCode"
      left join public."Variants" sv on sv."VariationId" = e."VariantId"
      where (p_as_of_date is null or e."PostingDate" <= p_as_of_date)
        and (p_warehouse_id is null or trim(p_warehouse_id) = '' or e."WarehouseId" = p_warehouse_id)
        and (
          p_search is null or trim(p_search) = ''
          or e."ItemCode" ilike '%' || trim(p_search) || '%'
          or i."Name" ilike '%' || trim(p_search) || '%'
          or sv."VariantName" ilike '%' || trim(p_search) || '%'
          or sv."SKU" ilike '%' || trim(p_search) || '%'
        )
      -- 2 = the g_variant_id expression above (null when variants are combined)
      group by e."ItemCode", 2, e."WarehouseId"
    )
    select
      g.g_item_code::text, coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), g.g_item_code)::text,
      g.g_variant_id::text, v."VariantName"::text,
      g.g_warehouse_id::text, coalesce(w."Name", g.g_warehouse_id)::text,
      g.g_in, g.g_out, g.g_balance,
      count(*) over(), sum(g.g_balance) over()
    from grouped g
    left join public."Items" i on i."Code" = g.g_item_code
    left join public."Variants" v on v."VariationId" = g.g_variant_id
    left join public."Warehouses" w on w."ID" = g.g_warehouse_id
    order by coalesce(nullif(trim(i."Name"), ''), g.g_item_code), v."VariantName", w."Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_get_item_ledger_balances(text, text, date, text, text, boolean, int, int) to anon;
