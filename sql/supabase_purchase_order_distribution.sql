-- Purchase Order DISTRIBUTION - per "now that I bought the products, is it possible that we split the TO
-- base on the store need?" -> decisions: stores with no shelf level get a share by their sales; send
-- everything (no warehouse buffer); partial receipts allowed; the TOs are created as Requested.
--
-- Purchase Orders (open or posted) > "Distribute to Stores". For each item received on the PO, per store
-- the PO's warehouse supplies (anything it has ever sent a transfer to, same network as Suggest Lines):
--
--   available to send = received on this PO - already sent from it (its own distribution TOs)
--                       capped by the warehouse's on hand - what it already owes on open TOs
--   store need        = the Transfer Order request cap (_tr_request_cap): maintaining qty - on hand -
--                       on the way. The same number the TO trigger enforces, so the lines are never refused.
--   no level          = store sales in the last p_sales_days days -> the page splits whatever is left
--                       after the level needs by sales share.
--
-- The split itself is done by the page (js/poDistribution.js) so staff can edit it before creating;
-- staff_create_po_distribution_transfers re-checks "available" and the cap trigger re-checks every line,
-- all in one transaction (one refused line = nothing is created).
--
-- Each TO created carries "Source PO No." (live and posted headers), so running Distribute again only
-- offers what hasn't been sent yet.
--
-- Run AFTER supabase_transfer_request_cap.sql, supabase_purchase_order_line_variant.sql and
-- supabase_item_ledger_entries.sql. Needs js/poDistribution.js ?v=podist1. Safe to re-run.

alter table public."Transfer_Header" add column if not exists "Source PO No." varchar(30);
alter table public."Posted_Transfer_Header" add column if not exists "Source PO No." varchar(30);

create index if not exists "IX_Transfer_Header_SourcePO"
  on public."Transfer_Header" ("Source PO No.") where "Source PO No." is not null;
create index if not exists "IX_Posted_Transfer_Header_SourcePO"
  on public."Posted_Transfer_Header" ("Source PO No.") where "Source PO No." is not null;

-- The Transfer Orders page archives a received TO by inserting the posted header with an explicit
-- column list - this carries the link over without touching that code.
create or replace function public._posted_transfer_header_fill_source_po()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new."Source PO No." is null then
    select h."Source PO No." into new."Source PO No."
      from public."Transfer_Header" h where h."No." = new."No.";
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_Posted_Transfer_Header_FillSourcePO" on public."Posted_Transfer_Header";
create trigger "TR_Posted_Transfer_Header_FillSourcePO"
  before insert on public."Posted_Transfer_Header"
  for each row execute function public._posted_transfer_header_fill_source_po();

-- ---------------------------------------------------------------------------
-- What each received PO line (per warehouse + item + variant) still has to give out.

drop function if exists public._po_distribution_sources(text);

create or replace function public._po_distribution_sources(p_po_no text)
returns table(from_wh_id text, from_wh_name text, item_code text, variant_id text, item_name text,
              variant_name text, key_item text, key_variant text, received numeric, sent numeric,
              wh_on_hand numeric, wh_outbound numeric, available numeric)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  r record;
  v_key record;
  v_items text[];
begin
  for r in
    with src as (
      select l."WarehouseId"::text as wh, l."ItemCode"::text as item,
             nullif(trim(coalesce(l."VariantCode", '')), '') as variant,
             l."ItemName"::text as iname, l."VariantName"::text as vname, coalesce(l."QtyReceived", 0) as qty
        from public."PurchaseOrderLines" l
       where l."PONo" = p_po_no
      union all
      select l."WarehouseId"::text, l."ItemCode"::text,
             nullif(trim(coalesce(l."VariantCode", '')), ''),
             l."ItemName"::text, l."VariantName"::text, coalesce(l."QtyReceived", 0)
        from public."PostedPurchaseOrderLines" l
       where l."PONo" = p_po_no
         and not exists (select 1 from public."PurchaseOrderLines" x where x."PONo" = p_po_no)
    )
    select s.wh, max(w."Name")::text as whname, s.item, s.variant,
           max(s.iname) as iname, max(s.vname) as vname, sum(s.qty) as qty
      from src s
      left join public."Warehouses" w on w."ID"::text = s.wh
     where nullif(trim(coalesce(s.wh, '')), '') is not null
       and nullif(trim(coalesce(s.item, '')), '') is not null
     group by s.wh, s.item, s.variant
    having sum(s.qty) > 0
     order by max(s.iname), max(s.vname)
  loop
    from_wh_id := r.wh;
    from_wh_name := r.whname;
    item_code := r.item;
    variant_id := r.variant;
    item_name := r.iname;
    variant_name := r.vname;
    received := r.qty;

    -- Same stock key the ledger used when the PO was received.
    begin
      select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(r.item, r.variant) k;
      key_item := v_key.item_code;
      key_variant := v_key.variant_id;
    exception when others then
      key_item := r.item;
      key_variant := r.variant;
    end;
    v_items := public._tr_item_keys(r.item, r.variant);

    -- Already given out by this PO's own distribution TOs (cancelled ones don't count; a posted TO counts
    -- what actually left, less anything returned).
    select coalesce(sum(x.q), 0) into sent
      from (
        select coalesce(l."Qty To Transfer", 0) as q
          from public."Transfer_Line" l
          join public."Transfer_Header" h on h."No." = l."Document No."
         where h."Source PO No." = p_po_no
           and h."From Warehouse ID"::text = r.wh
           and coalesce(h."Status", '') <> 'Cancelled'
           and case when key_variant is not null then l."Variant ID" = key_variant
                    else l."Item No." = any(v_items) end
        union all
        select greatest(0, coalesce(l."Qty Shipped", 0) - coalesce(l."Qty Returned", 0))
          from public."Posted_Transfer_Line" l
          join public."Posted_Transfer_Header" h on h."No." = l."Document No."
         where h."Source PO No." = p_po_no
           and h."From Warehouse ID"::text = r.wh
           and coalesce(h."Status", '') <> 'Cancelled'
           and case when key_variant is not null then l."Variant ID" = key_variant
                    else l."Item No." = any(v_items) end
      ) x;

    wh_on_hand := greatest(0, public._ile_balance(key_item, key_variant, r.wh));

    -- Requested from this warehouse, not shipped yet (includes this PO's own unshipped TOs).
    select coalesce(sum(greatest(0, coalesce(l."Qty To Transfer", 0) - coalesce(l."Qty Shipped", 0))), 0)
      into wh_outbound
      from public."Transfer_Line" l
      join public."Transfer_Header" h on h."No." = l."Document No."
     where h."From Warehouse ID"::text = r.wh
       and coalesce(h."Status", '') not in ('Received', 'Cancelled')
       and case when key_variant is not null then l."Variant ID" = key_variant
                else l."Item No." = any(v_items) end;

    available := greatest(0, least(received - sent, wh_on_hand - wh_outbound));
    return next;
  end loop;
end;
$$;

revoke execute on function public._po_distribution_sources(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The plan: one row per received item x store the warehouse supplies (store columns null when it
-- supplies none). Read-only.

drop function if exists public.staff_get_po_distribution_plan(text, text, text, int);

create or replace function public.staff_get_po_distribution_plan(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_sales_days int default 30
)
returns table(from_wh_id text, from_wh_name text, item_code text, variant_id text, item_name text,
              variant_name text, sku text, received numeric, sent numeric, wh_on_hand numeric,
              wh_outbound numeric, available numeric, store_id text, store_name text, rule text,
              scope text, scope_key text, maintain numeric, store_on_hand numeric, on_the_way numeric,
              allowed numeric, sold_qty numeric, po_transfers text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_po text := nullif(trim(coalesce(p_po_no, '')), '');
  v_from date := (now() at time zone 'Asia/Manila')::date - least(greatest(coalesce(p_sales_days, 30), 1), 365);
  v_docs text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_po is null
     or (not exists (select 1 from public."PurchaseOrders" where "PONo" = v_po)
         and not exists (select 1 from public."PostedPurchaseOrders" where "PONo" = v_po)) then
    raise exception 'Purchase Order "%" not found.', coalesce(v_po, '');
  end if;

  select string_agg(x.no || ' (' || x.st || ')', ', ' order by x.no) into v_docs
    from (
      select h."No."::text as no, coalesce(h."Status", '')::text as st from public."Transfer_Header" h where h."Source PO No." = v_po
      union all
      select h."No."::text, 'Posted' from public."Posted_Transfer_Header" h where h."Source PO No." = v_po
    ) x;

  return query
    with s as (
      select * from public._po_distribution_sources(v_po)
    ),
    net as (
      select distinct h."From Warehouse ID"::text as f, h."To Warehouse ID"::text as t
        from public."Transfer_Header" h where coalesce(h."Status", '') <> 'Cancelled'
      union
      select distinct h."From Warehouse ID"::text, h."To Warehouse ID"::text
        from public."Posted_Transfer_Header" h where coalesce(h."Status", '') <> 'Cancelled'
    ),
    st as (
      select s.*, w."ID"::text as sid, w."Name"::text as sname
        from s
        left join net on net.f = s.from_wh_id and net.t is not null and net.t <> s.from_wh_id
        left join public."Warehouses" w on w."ID"::text = net.t and coalesce(w."IsActive", true)
       where net.t is null or w."ID" is not null
    )
    select st.from_wh_id, st.from_wh_name, st.item_code, st.variant_id, st.item_name, st.variant_name,
           coalesce(nullif(trim(v."SKU"), ''), nullif(trim(i."SKU"), ''))::text,
           st.received, st.sent, st.wh_on_hand, st.wh_outbound, st.available,
           st.sid, st.sname, cap.rule, cap.scope, cap.scope_key, cap.maintain,
           case when cap.rule is not null then cap.on_hand
                when st.sid is not null then greatest(0, public._ile_balance(st.key_item, st.key_variant, st.sid)) end,
           cap.on_the_way, cap.allowed,
           case when st.sid is not null then
             greatest(0, coalesce((select -sum(e."Quantity") from public."ItemLedgerEntries" e
                                    where e."WarehouseId" = st.sid and e."EntryType" = 'Sale'
                                      and e."PostingDate" > v_from
                                      and e."ItemCode" = st.key_item
                                      and coalesce(e."VariantId", '') = coalesce(st.key_variant, '')), 0)) end,
           v_docs
      from st
      left join public."Variants" v on v."VariationId" = st.variant_id
      left join public."Items" i on i."Code" = st.item_code
      left join lateral public._tr_request_cap(null, null, st.sid, st.item_code, st.variant_id) cap on st.sid is not null
     order by st.item_name, st.variant_name, st.from_wh_name, st.sname;
end;
$$;

grant execute on function public.staff_get_po_distribution_plan(text, text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- Create the TOs: one Requested TO per (from warehouse, store), all in one transaction.
-- p_lines: [{from_wh_id, to_wh_id, item_code, variant_id, qty}] in base units.

drop function if exists public.staff_create_po_distribution_transfers(text, text, text, jsonb);

create or replace function public.staff_create_po_distribution_transfers(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_lines jsonb
)
returns table(doc_no text, to_warehouse text, line_count int, total_qty numeric)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '90000'
as $$
declare
  v_po text := nullif(trim(coalesce(p_po_no, '')), '');
  v_vendor text;
  v_by text;
  v_bad record;
  v_pair record;
  v_line record;
  v_doc text;
  v_line_no int;
  v_variant_name text;
  v_descr text;
  v_legacy_prefix text;
  v_legacy_max int;
  v_prod boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce(nullif(trim(vd."Name"), ''), po."VendorCode") into v_vendor
    from (select "VendorCode" from public."PurchaseOrders" where "PONo" = v_po
          union all
          select "VendorCode" from public."PostedPurchaseOrders" where "PONo" = v_po) po
    left join public."Vendors" vd on vd."VendorCode" = po."VendorCode"
   limit 1;
  if not found then
    raise exception 'Purchase Order "%" not found.', coalesce(v_po, '');
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array'
     or not exists (select 1 from jsonb_array_elements(p_lines) e where coalesce(nullif(e->>'qty', '')::numeric, 0) > 0) then
    raise exception 'Enter a quantity for at least one store.';
  end if;

  -- One distribution of a PO at a time, so two clicks can't both send the same stock.
  perform pg_advisory_xact_lock(hashtext('po-distribution:' || v_po));

  create temp table if not exists _po_dist_lines (
    from_wh text, to_wh text, item text, variant text, qty numeric
  ) on commit drop;
  truncate _po_dist_lines;

  insert into _po_dist_lines
  select trim(e->>'from_wh_id'), trim(e->>'to_wh_id'), trim(e->>'item_code'),
         nullif(trim(coalesce(e->>'variant_id', '')), ''), coalesce(nullif(e->>'qty', '')::numeric, 0)
    from jsonb_array_elements(p_lines) e
   where coalesce(nullif(e->>'qty', '')::numeric, 0) > 0;

  if exists (select 1 from _po_dist_lines where qty <> trunc(qty)) then
    raise exception 'Quantities must be whole units.';
  end if;
  if exists (select 1 from _po_dist_lines where coalesce(from_wh, '') = '' or coalesce(to_wh, '') = '' or coalesce(item, '') = '') then
    raise exception 'Each line needs a from warehouse, a store and an item.';
  end if;
  if exists (select 1 from _po_dist_lines where from_wh = to_wh) then
    raise exception 'A store can''t be the warehouse it is sent from.';
  end if;
  select l.to_wh into v_bad from _po_dist_lines l
   where not exists (select 1 from public."Warehouses" w where w."ID"::text = l.to_wh) limit 1;
  if found then
    raise exception 'Store "%" not found.', v_bad.to_wh;
  end if;

  -- Never more than this PO still has to give out (re-checked now - the page's numbers may be stale).
  select x.item, x.variant, x.q, coalesce(s.available, 0) as avail,
         coalesce(s.item_name, x.item) || coalesce(' - ' || s.variant_name, '') as label
    into v_bad
    from (select l.from_wh, l.item, l.variant, sum(l.qty) as q from _po_dist_lines l group by 1, 2, 3) x
    left join public._po_distribution_sources(v_po) s
      on s.from_wh_id = x.from_wh and s.item_code = x.item and s.variant_id is not distinct from x.variant
   where s.item_code is null or x.q > s.available
   limit 1;
  if found then
    raise exception '% - % to send but only % left to give out from %. Reload and try again.',
      v_bad.label, v_bad.q, v_bad.avail, v_po;
  end if;

  select coalesce(nullif(trim(u."DisplayName"), ''), u."Username") into v_by
    from public."StaffUsers" u where u."Username" = p_admin_username;
  v_by := coalesce(v_by, p_admin_username);

  for v_pair in
    select l.from_wh, fw."Name"::text as from_name, l.to_wh, tw."Name"::text as to_name,
           coalesce(fw."IsProductionWarehouse", false) as prod
      from (select distinct from_wh, to_wh from _po_dist_lines) l
      join public."Warehouses" fw on fw."ID"::text = l.from_wh
      join public."Warehouses" tw on tw."ID"::text = l.to_wh
     order by tw."Name"
  loop
    -- Same numbering as the Transfer Orders page (staff_next_transfer_no), scoped to the To Warehouse.
    v_legacy_prefix := 'TR-' || v_pair.to_name;
    select coalesce(max(substring(h."No." from length(v_legacy_prefix) + 1)::int), 0) into v_legacy_max
      from public."Transfer_Header" h
     where h."No." like v_legacy_prefix || '%'
       and substring(h."No." from length(v_legacy_prefix) + 1) ~ '^[0-9]+$';
    v_doc := public._next_no_series_number('TRANSFER-ORDER', v_pair.to_name, v_legacy_max);

    insert into public."Transfer_Header" (
      "No.", "Description", "Status", "Requested Date", "From Warehouse ID", "From Warehouse",
      "To Warehouse ID", "To Warehouse", "Use Production Category", "Requested By",
      "Is Locked", "Locked At", "Locked By", "Source PO No.")
    values (
      v_doc, left('From PO ' || v_po || coalesce(' - ' || v_vendor, ''), 100),
      'Requested', (now() at time zone 'Asia/Manila')::date, v_pair.from_wh, v_pair.from_name,
      v_pair.to_wh, v_pair.to_name, v_pair.prod, v_by,
      true, now(), v_by, v_po);

    v_line_no := 0;
    for v_line in
      select l.item, l.variant, sum(l.qty) as qty
        from _po_dist_lines l
       where l.from_wh = v_pair.from_wh and l.to_wh = v_pair.to_wh
       group by l.item, l.variant
       order by l.item, l.variant
    loop
      v_line_no := v_line_no + 10000;
      v_variant_name := null;
      select nullif(trim(v."VariantName"), '') into v_variant_name from public."Variants" v where v."VariationId" = v_line.variant;
      v_descr := null;
      select coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), '')) into v_descr
        from public."Items" i where i."Code" = v_line.item;
      -- The request cap trigger (TR_Transfer_Line_RequestCap) refuses a line over the store's level ->
      -- everything rolls back with its message.
      insert into public."Transfer_Line" (
        "Document No.", "Line No.", "Item No.", "Variant ID", "Variant Name", "Description", "Qty To Transfer")
      values (v_doc, v_line_no, v_line.item, v_line.variant, v_variant_name, v_descr, v_line.qty);
    end loop;

    doc_no := v_doc;
    to_warehouse := v_pair.to_name;
    select count(*)::int, coalesce(sum(l."Qty To Transfer"), 0) into line_count, total_qty
      from public."Transfer_Line" l where l."Document No." = v_doc;
    return next;
  end loop;
end;
$$;

grant execute on function public.staff_create_po_distribution_transfers(text, text, text, jsonb) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: columns, trigger, functions.
select 'column' as section, (table_name || '."' || column_name || '"')::text as item, data_type::text as value
from information_schema.columns
where table_schema = 'public' and column_name = 'Source PO No.'
  and table_name in ('Transfer_Header', 'Posted_Transfer_Header')
union all
select 'trigger', tgname::text, case when tgenabled <> 'D' then 'enabled' else 'DISABLED' end
from pg_trigger where tgrelid = 'public."Posted_Transfer_Header"'::regclass and tgname = 'TR_Posted_Transfer_Header_FillSourcePO'
union all
select 'function', p.proname::text,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon ok' else 'internal' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  '_po_distribution_sources', 'staff_get_po_distribution_plan', 'staff_create_po_distribution_transfers',
  '_posted_transfer_header_fill_source_po');
