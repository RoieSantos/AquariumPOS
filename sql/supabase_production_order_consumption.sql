-- Production Orders: MATERIALS USED (consumption) - per "in the production order.. can we log how many
-- sealant / rubber matting and glass material that we spend?" (Option A: enter what was actually used;
-- materials are tracked per pc).
--
-- Business Central's Consumption: the Production Manager enters the materials an order used (sealant,
-- rubber matting, glass ... any item, in pcs) and posts them. Each line becomes an Item Ledger entry of
-- the new type 'Consumption' (negative quantity) at the order's warehouse, so the material leaves stock,
-- and a row in ProductionOrderConsumption ties it to the order (and to the Tank / Stand part, i.e. the
-- maker who used it).
--
--   ItemLedgerEntries.EntryType               + 'Consumption' (DocumentType 'Production Consumption').
--   ProductionOrderConsumption                 - one row per posted material line.
--   staff_post_production_consumption(...)     - post materials used (Production Manager / Super User),
--                                                on a Released or Finished order. Whole pcs only.
--   staff_list_production_order_consumption()  - an order's posted materials (incl. whether reversed).
--
-- A wrong entry is corrected like any other: Item Ledger Entries > Reverse (the whole posting), then
-- post the right amounts. Stock is allowed to go negative (like the rest of the ledger), so a material
-- whose on-hand wasn't loaded yet can still be logged.
--
-- Run AFTER supabase_production_orders.sql. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Item Ledger: allow 'Consumption' (keeps every type allowed so far).
do $$
declare
  v_name text;
begin
  for v_name in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'public."ItemLedgerEntries"'::regclass
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%EntryType%'
  loop
    execute format('alter table public."ItemLedgerEntries" drop constraint %I', v_name);
  end loop;
end;
$$;

alter table public."ItemLedgerEntries"
  add constraint "CK_ItemLedgerEntries_EntryType"
  check ("EntryType" in ('Purchase', 'Sale', 'Positive Adjmt.', 'Negative Adjmt.', 'Transfer', 'Output', 'Consumption'));

-- ---------------------------------------------------------------------------
-- 2. Table
create table if not exists public."ProductionOrderConsumption" (
    "EntryNo" bigint primary key references public."ItemLedgerEntries" ("EntryNo"),
    "ProdOrderNo" varchar(20) not null references public."ProductionOrders" ("No") on delete cascade,
    "TransactionNo" bigint not null,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100),
    -- Pcs used (positive; the ledger entry carries the negative).
    "Quantity" numeric(18, 4) not null check ("Quantity" > 0),
    -- Which part used it - 'tank' or 'stand' - so usage can be read per maker.
    "Part" varchar(10) not null default 'tank' check ("Part" in ('tank', 'stand')),
    "PostedBy" varchar(100),
    "PostedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_ProductionOrderConsumption_Order" on public."ProductionOrderConsumption" ("ProdOrderNo");
create index if not exists "IX_ProductionOrderConsumption_Item" on public."ProductionOrderConsumption" ("ItemCode", "PostedAtUtc");

alter table public."ProductionOrderConsumption" enable row level security;
revoke all on public."ProductionOrderConsumption" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Post materials used
drop function if exists public.staff_post_production_consumption(text, text, text, jsonb, date);

-- p_lines: [{"item_code": "SEAL-BLK", "variant_id": null, "quantity": 3, "part": "tank"}, ...]
-- All-or-nothing: one bad line posts nothing.
create or replace function public.staff_post_production_consumption(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_lines jsonb,
  p_posting_date date default null
)
returns table(entry_no bigint, item_code text, variant_id text, quantity numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."ProductionOrders";
  v_tx bigint;
  v_req jsonb;
  v_item text;
  v_variant text;
  v_qty numeric;
  v_part text;
  v_entry bigint;
  v_posted int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Production Manager can post materials used.';
  end if;

  select * into v_order from public."ProductionOrders" where "No" = p_no for update;
  if not found then
    raise exception 'Production order % not found.', p_no;
  end if;
  if v_order."Status" not in ('Released', 'Finished') then
    raise exception 'Materials can be posted once % is Released (it is %).', p_no, v_order."Status";
  end if;

  v_tx := nextval('public.ile_transaction_no_seq');

  for v_req in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_item := nullif(trim(coalesce(v_req->>'item_code', '')), '');
    v_variant := nullif(trim(coalesce(v_req->>'variant_id', '')), '');
    v_qty := coalesce(nullif(v_req->>'quantity', '')::numeric, 0);
    v_part := lower(coalesce(nullif(trim(v_req->>'part'), ''), 'tank'));
    continue when v_item is null and v_qty = 0;

    if v_item is null then
      raise exception 'Pick an item on every materials line.';
    end if;
    if v_qty <= 0 or v_qty <> trunc(v_qty) then
      raise exception '% - enter the pcs used as a whole number above 0.', v_item;
    end if;
    if v_part not in ('tank', 'stand') then
      raise exception 'Part must be Tank or Stand.';
    end if;

    v_entry := public._ile_post(
      'Consumption', v_item, v_variant, v_order."WarehouseId", -v_qty,
      coalesce(p_posting_date, public._ile_today()), 'Production Consumption', p_no,
      'Used on ' || p_no || coalesce(' - ' || nullif(trim(v_order."Description"), ''), ''), v_tx, p_admin_username
    );

    -- The ledger stores the resolved item / variant - keep the same on the order's row.
    insert into public."ProductionOrderConsumption" ("EntryNo", "ProdOrderNo", "TransactionNo", "ItemCode", "VariantId", "Quantity", "Part", "PostedBy")
    select e."EntryNo", p_no, v_tx, e."ItemCode", e."VariantId", v_qty, v_part, p_admin_username
    from public."ItemLedgerEntries" e where e."EntryNo" = v_entry;

    v_posted := v_posted + 1;
    select e."EntryNo", e."ItemCode"::text, e."VariantId"::text, v_qty
      into entry_no, item_code, variant_id, quantity
      from public."ItemLedgerEntries" e where e."EntryNo" = v_entry;
    return next;
  end loop;

  if v_posted = 0 then
    raise exception 'Add at least one material with the pcs used.';
  end if;

  update public."ProductionOrders" set "UpdatedAtUtc" = now() where "No" = p_no;
end;
$$;

grant execute on function public.staff_post_production_consumption(text, text, text, jsonb, date) to anon;

-- ---------------------------------------------------------------------------
-- 4. An order's posted materials
drop function if exists public.staff_list_production_order_consumption(text, text, text);

create or replace function public.staff_list_production_order_consumption(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(entry_no bigint, transaction_no bigint, item_code text, item_name text, variant_id text, variant_name text,
              quantity numeric, part text, posted_by text, posted_by_name text, posted_at timestamptz, reversed boolean)
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
    select c."EntryNo", c."TransactionNo", c."ItemCode"::text, i."Name"::text, c."VariantId"::text,
           coalesce(nullif(trim(v."VariantName"), ''), v."SKU")::text,
           c."Quantity", c."Part"::text, c."PostedBy"::text,
           coalesce(nullif(trim(su."DisplayName"), ''), c."PostedBy")::text,
           c."PostedAtUtc",
           exists (select 1 from public."ItemLedgerEntries" r where r."ReversesEntryNo" = c."EntryNo")
    from public."ProductionOrderConsumption" c
    left join public."Items" i on i."Code" = c."ItemCode"
    left join public."Variants" v on v."VariationId" = c."VariantId"
    left join public."StaffUsers" su on su."Username" = c."PostedBy"
    where c."ProdOrderNo" = p_no
    order by c."EntryNo";
end;
$$;

grant execute on function public.staff_list_production_order_consumption(text, text, text) to anon;

notify pgrst, 'reload schema';
