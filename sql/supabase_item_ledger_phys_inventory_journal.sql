-- Item Ledger Entries - PHYSICAL INVENTORY JOURNAL, per direct request: "can you create me a
-- physical inventory journal same as business central UI UX and behaviour? this way we can do
-- physical count easily".
--
-- Run AFTER supabase_item_ledger_entries.sql and supabase_item_ledger_hooks.sql.
--
-- WHAT THIS IS, VS. THE EXISTING CSV "LOAD OR COUNT STOCK" TOOL
-- The CSV tool (supabase_item_ledger_stock_count.sql) is a one-shot import: upload a finished count,
-- preview, post. This is the other half of Business Central's workflow - an on-screen WORKSHEET you
-- build up while you are actually walking the shop:
--   1. CALCULATE INVENTORY for a location (optionally filtered by category/search) - pulls in a line
--      per item/variant with the system's current quantity as "Qty. (Calculated)", a stable
--      reference number that does NOT change while you count (even if calculating again later, e.g.
--      to add items received after you started - it only touches lines that don't have a count yet).
--   2. Type what you actually counted into "Qty. (Phys. Inventory)" as you go, one item/cell at a
--      time, in any order, over as long as it takes. Add a line by hand for anything Calculate
--      missed. Delete a line that doesn't belong.
--   3. POST. Only lines that have been given a count are posted (as Positive/Negative Adjmt.
--      entries, one per line with a real difference) and then cleared from the worksheet - lines you
--      haven't gotten to yet stay for next time.
--
-- ONE DELIBERATE DEPARTURE FROM LITERAL BC: BC computes the posted quantity as
-- (Qty. Phys. Inventory - Qty. Calculated), using whatever Qty. Calculated happened to be frozen at
-- - so if stock moves between Calculate and Post (a sale, a PO receipt), the posted delta can be
-- stale. Given "the portal is the source of truth ... monitored as of the moment" (the whole point
-- of this ledger), posting here instead always diffs against the LIVE balance at the moment you
-- click Post - Qty. (Calculated) is shown only as your counting reference, never used for the
-- posted math. The result: after posting, the ledger balance always equals exactly what you typed,
-- no matter what else happened in between.
--
-- BATCHES: a lightweight name (like BC's journal batch), typed freely - e.g. one per person/aisle/
-- day. A batch exists as soon as a line is in it and disappears once its lines are gone. No separate
-- "create batch" step.

-- ============================================================================
-- 1. The worksheet table
-- ============================================================================

-- Deliberately NOT foreign keys to Items/Variants/Warehouses, same reasoning as ItemLedgerEntries:
-- those are synced/mirrored tables. Validated at write time instead.
create table if not exists public."PhysInventoryJournalLines" (
    "LineID" bigserial primary key,
    "BatchName" varchar(50) not null default 'DEFAULT',
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100),
    "WarehouseId" varchar(100) not null,
    -- Frozen at Calculate Inventory (or New Line) time - the counting reference. Never used to
    -- compute what actually posts (see note above).
    "QtyCalculated" numeric(18, 4) not null default 0,
    -- Null = not counted yet. Posting only touches a line once this is filled in.
    "QtyCounted" numeric(18, 4),
    "UpdatedAtUtc" timestamptz not null default now(),
    "UpdatedBy" varchar(100)
);

alter table public."PhysInventoryJournalLines" enable row level security;
revoke all on public."PhysInventoryJournalLines" from anon, authenticated;

-- One line per item+variant+warehouse per batch - Calculate/New Line update this same row rather
-- than duplicating it. VariantId is normalised through coalesce(..,'') because two NULLs never
-- collide under a plain unique index.
create unique index if not exists "UX_PhysInventoryJournalLines_Key"
    on public."PhysInventoryJournalLines" ("BatchName", "ItemCode", (coalesce("VariantId", '')), "WarehouseId");

create index if not exists "IX_PhysInventoryJournalLines_Batch" on public."PhysInventoryJournalLines" ("BatchName");

-- ============================================================================
-- 2. Read the worksheet (shared by the grid and by Post)
-- ============================================================================

-- One row per journal line, with names resolved, the live balance, and the quantity that WOULD post
-- (qty_counted - qty_current) - null while qty_counted is null. Internal building block only.
create or replace function public._ile_phys_journal_rows(p_batch_name text)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  qty_calculated numeric, qty_counted numeric, qty_current numeric, quantity numeric,
  updated_at_utc timestamptz, updated_by text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    l."LineID", l."ItemCode"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), l."ItemCode")::text,
    l."VariantId"::text, v."VariantName"::text,
    l."WarehouseId"::text, coalesce(w."Name", l."WarehouseId")::text,
    l."QtyCalculated", l."QtyCounted",
    public._ile_balance(l."ItemCode", l."VariantId", l."WarehouseId"),
    case when l."QtyCounted" is null then null
         else l."QtyCounted" - public._ile_balance(l."ItemCode", l."VariantId", l."WarehouseId") end,
    l."UpdatedAtUtc", l."UpdatedBy"::text
  from public."PhysInventoryJournalLines" l
  left join public."Items" i on i."Code" = l."ItemCode"
  left join public."Variants" v on v."VariationId" = l."VariantId"
  left join public."Warehouses" w on w."ID" = l."WarehouseId"
  where l."BatchName" = p_batch_name
$$;

revoke execute on function public._ile_phys_journal_rows(text) from public, anon, authenticated;

drop function if exists public.admin_list_phys_journal_batches(text, text);

-- The batch picker: every batch that currently has lines, with progress, newest activity first.
create or replace function public.admin_list_phys_journal_batches(
  p_admin_username text,
  p_admin_password text
)
returns table(batch_name text, line_count bigint, counted_count bigint, last_updated_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."BatchName"::text, count(*), count(*) filter (where l."QtyCounted" is not null), max(l."UpdatedAtUtc")
    from public."PhysInventoryJournalLines" l
    group by l."BatchName"
    order by max(l."UpdatedAtUtc") desc;
end;
$$;

grant execute on function public.admin_list_phys_journal_batches(text, text) to anon;

drop function if exists public.admin_get_phys_journal_lines(text, text, text);

create or replace function public.admin_get_phys_journal_lines(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text
)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text,
  qty_calculated numeric, qty_counted numeric, qty_current numeric, quantity numeric,
  updated_at_utc timestamptz, updated_by text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Aliased and qualified (r.item_name, not item_name) so ORDER BY can't be shadowed by this
  -- function's own OUT parameters, which PL/pgSQL also exposes as plain variables of the same name.
  return query
    select r.* from public._ile_phys_journal_rows(trim(coalesce(p_batch_name, 'DEFAULT'))) r
    order by r.item_name, r.variant_name nulls first, r.warehouse_name;
end;
$$;

grant execute on function public.admin_get_phys_journal_lines(text, text, text) to anon;

-- ============================================================================
-- 3. Calculate Inventory - populate/refresh lines for a location
-- ============================================================================

drop function if exists public.admin_calculate_phys_inventory(text, text, text, text, text, text);

-- Adds a line for every active item (one per variant, for an item that has 2+) at p_warehouse_id
-- that isn't already in the batch, and refreshes Qty. (Calculated) on lines that ARE already there
-- but have not been counted yet (qty_counted is still null) - so re-running it to pick up new items
-- never disturbs a count already in progress. p_category_code/p_search narrow which items, the way
-- you'd calculate one aisle/category at a time.
create or replace function public.admin_calculate_phys_inventory(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_warehouse_id text,
  p_category_code text default null,
  p_search text default null
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_warehouse text := trim(coalesce(p_warehouse_id, ''));
  v_count int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_batch = '' then
    raise exception 'A batch name is required.';
  end if;

  if v_warehouse = '' or not exists (select 1 from public."Warehouses" where "ID" = v_warehouse) then
    raise exception 'Pick a location to calculate inventory for.';
  end if;

  with variant_counts as (
    select v."ItemCode" as item_code, count(*) as cnt from public."Variants" v group by v."ItemCode"
  ),
  keys as (
    -- An item with 2+ variants: one key per variant.
    select i."Code" as item_code, v."VariationId" as variant_id
    from public."Items" i
    join public."Variants" v on v."ItemCode" = i."Code"
    join variant_counts vc on vc.item_code = i."Code" and vc.cnt >= 2
    where coalesce(i."IsActive", true)
    union all
    -- Everything else (no variants, or exactly one - which is really just the item itself): one
    -- key, no variant. Mirrors _ile_resolve_stock_key's own threshold exactly.
    select i."Code", null
    from public."Items" i
    left join variant_counts vc on vc.item_code = i."Code"
    where coalesce(i."IsActive", true) and coalesce(vc.cnt, 0) < 2
  ),
  filtered as (
    select k.item_code, k.variant_id
    from keys k
    join public."Items" i on i."Code" = k.item_code
    left join public."Variants" v on v."VariationId" = k.variant_id
    where (p_category_code is null or trim(p_category_code) = '' or i."CategoryCode" = p_category_code)
      and (
        p_search is null or trim(p_search) = ''
        or k.item_code ilike '%' || trim(p_search) || '%'
        or i."Name" ilike '%' || trim(p_search) || '%'
        or v."VariantName" ilike '%' || trim(p_search) || '%'
      )
  )
  insert into public."PhysInventoryJournalLines"
    ("BatchName", "ItemCode", "VariantId", "WarehouseId", "QtyCalculated", "UpdatedAtUtc", "UpdatedBy")
  select v_batch, f.item_code, f.variant_id, v_warehouse,
         public._ile_balance(f.item_code, f.variant_id, v_warehouse), now(), p_admin_username
  from filtered f
  on conflict ("BatchName", "ItemCode", (coalesce("VariantId", '')), "WarehouseId")
  do update set
    "QtyCalculated" = case when public."PhysInventoryJournalLines"."QtyCounted" is null
                            then excluded."QtyCalculated"
                            else public."PhysInventoryJournalLines"."QtyCalculated" end,
    "UpdatedAtUtc" = now(),
    "UpdatedBy" = excluded."UpdatedBy";

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_calculate_phys_inventory(text, text, text, text, text, text) to anon;

-- ============================================================================
-- 4. Edit lines by hand
-- ============================================================================

drop function if exists public.admin_add_phys_journal_line(text, text, text, text, text, text);

-- "New Line": add (or refresh, if it's already in the batch) one item/variant at a location. Returns
-- the line so the grid can insert/update it in place without a full reload.
create or replace function public.admin_add_phys_journal_line(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_item_code text,
  p_variant_id text,
  p_warehouse_id text
)
returns table(line_id bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_warehouse text := trim(coalesce(p_warehouse_id, ''));
  v_item text;
  v_variant text;
  v_line_id bigint;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_batch = '' then
    raise exception 'A batch name is required.';
  end if;

  if v_warehouse = '' or not exists (select 1 from public."Warehouses" where "ID" = v_warehouse) then
    raise exception 'Pick a location.';
  end if;

  select k.item_code, k.variant_id into v_item, v_variant
    from public._ile_resolve_stock_key(p_item_code, p_variant_id) k;

  insert into public."PhysInventoryJournalLines"
    ("BatchName", "ItemCode", "VariantId", "WarehouseId", "QtyCalculated", "UpdatedAtUtc", "UpdatedBy")
  values (v_batch, v_item, v_variant, v_warehouse, public._ile_balance(v_item, v_variant, v_warehouse), now(), p_admin_username)
  on conflict ("BatchName", "ItemCode", (coalesce("VariantId", '')), "WarehouseId")
  do update set "UpdatedAtUtc" = now(), "UpdatedBy" = excluded."UpdatedBy"
  returning "LineID" into v_line_id;

  return query select v_line_id;
end;
$$;

grant execute on function public.admin_add_phys_journal_line(text, text, text, text, text, text) to anon;

drop function if exists public.admin_set_phys_journal_qty(text, text, bigint, numeric);

-- The inline "type a count into the cell" edit. Null clears a count back to "not counted yet".
create or replace function public.admin_set_phys_journal_qty(
  p_admin_username text,
  p_admin_password text,
  p_line_id bigint,
  p_qty_counted numeric
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

  if p_qty_counted is not null and p_qty_counted < 0 then
    raise exception 'A physical count cannot be negative.';
  end if;

  update public."PhysInventoryJournalLines"
     set "QtyCounted" = p_qty_counted, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
   where "LineID" = p_line_id;

  if not found then
    raise exception 'That line is no longer on the worksheet - someone may have already posted or deleted it. Refresh the page.';
  end if;
end;
$$;

grant execute on function public.admin_set_phys_journal_qty(text, text, bigint, numeric) to anon;

drop function if exists public.admin_delete_phys_journal_line(text, text, bigint);

create or replace function public.admin_delete_phys_journal_line(
  p_admin_username text,
  p_admin_password text,
  p_line_id bigint
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

  delete from public."PhysInventoryJournalLines" where "LineID" = p_line_id;
end;
$$;

grant execute on function public.admin_delete_phys_journal_line(text, text, bigint) to anon;

-- ============================================================================
-- 5. Post
-- ============================================================================

drop function if exists public.admin_post_phys_inventory_journal(text, text, text, date, text, boolean);

-- Posts every counted line (qty_counted is not null) whose live balance differs from what was
-- counted, as one Positive/Negative Adjmt. per line under one transaction (document PHYS-000123),
-- then clears every counted line from the worksheet - including one that matched exactly (nothing to
-- post, but it has been resolved). Lines still waiting to be counted are left for next time.
--
-- p_dry_run = true computes and returns the same rows without writing anything, for a confirmation
-- summary before the real post.
create or replace function public.admin_post_phys_inventory_journal(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_posting_date date,
  p_reason text default null,
  p_dry_run boolean default true
)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text, qty_calculated numeric, qty_counted numeric, quantity numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_transaction_no bigint;
  v_doc_no text;
  v_row record;
  v_ids bigint[] := array[]::bigint[];
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."PhysInventoryJournalLines" where "BatchName" = v_batch and "QtyCounted" is not null) then
    raise exception 'Nothing on this worksheet has a count yet.';
  end if;

  if not coalesce(p_dry_run, true) and (p_reason is null or trim(p_reason) = '') then
    raise exception 'A reason is required (e.g. "Cycle count", "Year-end count").';
  end if;

  if not coalesce(p_dry_run, true) then
    v_transaction_no := nextval('public.ile_transaction_no_seq');
    v_doc_no := 'PHYS-' || lpad(v_transaction_no::text, 6, '0');
  end if;

  for v_row in
    select * from public._ile_phys_journal_rows(v_batch) r where r.qty_counted is not null
  loop
    if not coalesce(p_dry_run, true) then
      if coalesce(v_row.quantity, 0) <> 0 then
        perform public._ile_post(
          case when v_row.quantity > 0 then 'Positive Adjmt.' else 'Negative Adjmt.' end,
          v_row.item_code, v_row.variant_id, v_row.warehouse_id, v_row.quantity,
          coalesce(p_posting_date, public._ile_today()), 'Phys. Inventory', v_doc_no, trim(p_reason),
          v_transaction_no, p_admin_username
        );
      end if;
      v_ids := v_ids || v_row.line_id;
    end if;

    line_id := v_row.line_id; item_code := v_row.item_code; item_name := v_row.item_name;
    variant_id := v_row.variant_id; variant_name := v_row.variant_name;
    warehouse_id := v_row.warehouse_id; warehouse_name := v_row.warehouse_name;
    qty_calculated := v_row.qty_calculated; qty_counted := v_row.qty_counted; quantity := v_row.quantity;
    return next;
  end loop;

  if not coalesce(p_dry_run, true) and array_length(v_ids, 1) > 0 then
    delete from public."PhysInventoryJournalLines" where "LineID" = any(v_ids);
  end if;
end;
$$;

grant execute on function public.admin_post_phys_inventory_journal(text, text, text, date, text, boolean) to anon;

notify pgrst, 'reload schema';
