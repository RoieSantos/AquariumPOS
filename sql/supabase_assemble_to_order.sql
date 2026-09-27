-- Assemble-to-Order items (BOM).
--
-- A parent item flagged "Assemble to Order" is never stocked at the source warehouse - it is built
-- from its BOM components when a Transfer Order asks for it. Item Setup (item card > Assemble to
-- Order) holds the flag and the component list (component + quantity per parent).
--
-- What this adds:
--   1. Items."AssembleToOrder" + public."ItemBOM" (parent, component, qty per) and their RPCs.
--   2. staff_get_transfer_bom(doc): the BOM exploded for a Transfer Order - per ATO line, each
--      component, the quantity required and what the From warehouse has. The Manage modal shows it
--      and "Create PO" buys the shortfall from it.
--   3. staff_get_transfer_line_stock now reports an ATO line's Available as
--      (parent on hand) + (how many can be built from the components on hand), so the Available
--      column and the pre-ship stock check are right without any change to the page.
--   4. Shipping an ATO line posts the assembly to the Item Ledger, at the FROM warehouse, right
--      before the shipment itself:  components out (Negative Adjmt.), parent in (Positive Adjmt.),
--      both document type 'Assembly' under one TransactionNo; then the normal Transfer Shipment
--      takes the parent out. Only the SHORTFALL is built - any parent already on hand at the From
--      warehouse is shipped first. Shipping is refused (whole shipment rolls back) if a component
--      is short. Built quantity is not un-built if a shipment is later corrected downwards.
--
--   5. The BOM is SNAPSHOTTED onto the order when it is requested (public."Transfer_Line_BOM", saved by
--      the New Transfer Order screen via staff_save_transfer_bom_snapshot). The exploded BOM shown on the
--      order, its Available, Create PO and the assembly at shipping all use that snapshot, so a later
--      edit to the item BOM does not change an order already requested. Orders without a snapshot
--      (created in the desktop app, or before this) fall back to the item's current BOM.
--
-- ONE LEVEL ONLY: a component cannot itself be an Assemble-to-Order item.
-- Only takes effect while Transfer Orders post to the Item Ledger (General Setup > Item Ledger).
--
-- Run AFTER supabase_item_ledger_hooks.sql and supabase_item_ledger_transfer_posting_toggle.sql.

alter table public."Items" add column if not exists "AssembleToOrder" boolean not null default false;

create table if not exists public."ItemBOM" (
    "ParentItemCode"    varchar(200) not null references public."Items"("Code") on delete cascade,
    "ComponentItemCode" varchar(200) not null references public."Items"("Code") on delete cascade,
    "QtyPer"            numeric(18, 4) not null check ("QtyPer" > 0),
    "UpdatedAtUtc"      timestamptz not null default now(),
    primary key ("ParentItemCode", "ComponentItemCode"),
    check ("ParentItemCode" <> "ComponentItemCode")
);

create index if not exists "IX_ItemBOM_Component" on public."ItemBOM" ("ComponentItemCode");

alter table public."ItemBOM" enable row level security;
revoke all on public."ItemBOM" from anon, authenticated;

create table if not exists public."Transfer_Line_BOM" (
    "Document No."       varchar(50)  not null,
    "Line No."           bigint       not null,
    "Component Item No." varchar(200) not null,
    "Qty Per"            numeric(18, 4) not null check ("Qty Per" > 0),
    primary key ("Document No.", "Line No.", "Component Item No.")
);

alter table public."Transfer_Line_BOM" enable row level security;
revoke all on public."Transfer_Line_BOM" from anon, authenticated;

-- The BOM to use for one transfer line: the snapshot taken when it was requested if there is one,
-- otherwise the item's current BOM.
create or replace function public._ile_line_bom(p_document_no text, p_line_no bigint, p_parent_item text)
returns table(component_code text, qty_per numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s."Component Item No."::text, s."Qty Per"
  from public."Transfer_Line_BOM" s
  where s."Document No." = p_document_no and s."Line No." = p_line_no
  union all
  select b."ComponentItemCode"::text, b."QtyPer"
  from public."ItemBOM" b
  where b."ParentItemCode" = p_parent_item
    and not exists (select 1 from public."Transfer_Line_BOM" s2 where s2."Document No." = p_document_no and s2."Line No." = p_line_no);
$$;

revoke execute on function public._ile_line_bom(text, bigint, text) from public, anon, authenticated;

-- ============================================================================
-- 1. Item Setup RPCs
-- ============================================================================

drop function if exists public.staff_get_item_bom(text, text, text);

create or replace function public.staff_get_item_bom(p_admin_username text, p_admin_password text, p_item_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return jsonb_build_object(
    'assemble_to_order', coalesce((select i."AssembleToOrder" from public."Items" i where i."Code" = p_item_code), false),
    'components', coalesce((
      select jsonb_agg(jsonb_build_object(
               'component_code', b."ComponentItemCode",
               'component_name', coalesce(nullif(trim(ci."Name"), ''), b."ComponentItemCode"),
               'qty_per', b."QtyPer"
             ) order by b."ComponentItemCode")
      from public."ItemBOM" b
      join public."Items" ci on ci."Code" = b."ComponentItemCode"
      where b."ParentItemCode" = p_item_code
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.staff_get_item_bom(text, text, text) to anon;

drop function if exists public.admin_set_item_assemble_to_order(text, text, text, boolean);

create or replace function public.admin_set_item_assemble_to_order(
  p_admin_username text, p_admin_password text, p_item_code text, p_enabled boolean
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

  if coalesce(p_enabled, false) and exists (
    select 1 from public."ItemBOM" b join public."Items" p on p."Code" = b."ParentItemCode" and p."AssembleToOrder"
    where b."ComponentItemCode" = p_item_code
  ) then
    raise exception 'This item is a component of another Assemble-to-Order item, so it cannot be one itself (one BOM level only).';
  end if;

  update public."Items" set "AssembleToOrder" = coalesce(p_enabled, false) where "Code" = p_item_code;
  if not found then raise exception 'Item "%" not found.', p_item_code; end if;
end;
$$;

grant execute on function public.admin_set_item_assemble_to_order(text, text, text, boolean) to anon;

drop function if exists public.admin_upsert_item_bom_component(text, text, text, text, numeric);

create or replace function public.admin_upsert_item_bom_component(
  p_admin_username text, p_admin_password text, p_parent_code text, p_component_code text, p_qty_per numeric
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
  if p_qty_per is null or p_qty_per <= 0 then
    raise exception 'Quantity per must be greater than zero.';
  end if;
  if p_parent_code = p_component_code then
    raise exception 'An item cannot be a component of itself.';
  end if;
  if not exists (select 1 from public."Items" where "Code" = p_parent_code) then
    raise exception 'Item "%" not found.', p_parent_code;
  end if;
  if not exists (select 1 from public."Items" where "Code" = p_component_code) then
    raise exception 'Component item "%" not found.', p_component_code;
  end if;
  if exists (select 1 from public."Items" where "Code" = p_component_code and "AssembleToOrder") then
    raise exception 'Component "%" is itself an Assemble-to-Order item (one BOM level only).', p_component_code;
  end if;

  insert into public."ItemBOM" ("ParentItemCode", "ComponentItemCode", "QtyPer")
  values (p_parent_code, p_component_code, p_qty_per)
  on conflict ("ParentItemCode", "ComponentItemCode") do update set "QtyPer" = excluded."QtyPer", "UpdatedAtUtc" = now();
end;
$$;

grant execute on function public.admin_upsert_item_bom_component(text, text, text, text, numeric) to anon;

drop function if exists public.admin_remove_item_bom_component(text, text, text, text);

create or replace function public.admin_remove_item_bom_component(
  p_admin_username text, p_admin_password text, p_parent_code text, p_component_code text
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
  delete from public."ItemBOM" where "ParentItemCode" = p_parent_code and "ComponentItemCode" = p_component_code;
end;
$$;

grant execute on function public.admin_remove_item_bom_component(text, text, text, text) to anon;

drop function if exists public.staff_save_transfer_bom_snapshot(text, text, text, jsonb);

-- Called by the New Transfer Order screen right after the lines are saved. p_lines:
-- [{"line_no": 10000, "components": [{"component_code": "ELBOW", "qty_per": 2}, ...]}]
-- Replaces whatever snapshot the document had. Staff-level: anyone who can request a transfer.
create or replace function public.staff_save_transfer_bom_snapshot(
  p_admin_username text, p_admin_password text, p_document_no text, p_lines jsonb
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
  if not exists (select 1 from public."Transfer_Header" where "No." = p_document_no) then
    raise exception 'Transfer order "%" not found.', p_document_no;
  end if;

  delete from public."Transfer_Line_BOM" where "Document No." = p_document_no;

  insert into public."Transfer_Line_BOM" ("Document No.", "Line No.", "Component Item No.", "Qty Per")
  select p_document_no, (l->>'line_no')::bigint, c->>'component_code', (c->>'qty_per')::numeric
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) l
  cross join lateral jsonb_array_elements(coalesce(l->'components', '[]'::jsonb)) c
  where (c->>'qty_per')::numeric > 0
    and exists (select 1 from public."Items" i where i."Code" = c->>'component_code');
end;
$$;

grant execute on function public.staff_save_transfer_bom_snapshot(text, text, text, jsonb) to anon;

-- ============================================================================
-- 2. BOM exploded for a Transfer Order
-- ============================================================================

drop function if exists public.staff_get_transfer_bom(text, text, text);

-- One row per (ATO line, component). remaining = still to ship; parent_on_hand = parent already at the
-- From warehouse; to_build = what would have to be assembled; qty_required = to_build x QtyPer;
-- comp_on_hand = the component at the From warehouse (null if it could not be resolved, e.g. a
-- component with several variants).
create or replace function public.staff_get_transfer_bom(p_admin_username text, p_admin_password text, p_document_no text)
returns table(
  line_no bigint, parent_item text, component_code text, component_name text, qty_per numeric,
  remaining numeric, parent_on_hand numeric, to_build numeric, qty_required numeric, comp_on_hand numeric,
  total_required numeric
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_from text;
  v_line record;
  v_comp record;
  v_key record;
  v_parent_on_hand numeric;
  v_comp_on_hand numeric;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "From Warehouse ID" into v_from from public."Transfer_Header" where "No." = p_document_no;

  for v_line in
    select tl."Line No."::bigint as ln, tl."Item No."::text as item_no, nullif(trim(coalesce(tl."Variant ID", '')), '') as variant_id,
           greatest(0, coalesce(tl."Qty To Transfer", 0) - coalesce(tl."Qty Shipped", 0)) as remaining
    from public."Transfer_Line" tl
    join public."Items" i on i."Code" = tl."Item No." and i."AssembleToOrder"
    where tl."Document No." = p_document_no
    order by tl."Line No."
  loop
    begin
      select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(v_line.item_no, v_line.variant_id) k;
      v_parent_on_hand := greatest(0, public._ile_balance(v_key.item_code, v_key.variant_id, coalesce(v_from, '')));
    exception when others then
      v_parent_on_hand := 0;
    end;

    for v_comp in
      select b.component_code as code, coalesce(nullif(trim(ci."Name"), ''), b.component_code) as name, b.qty_per as qty_per
      from public._ile_line_bom(p_document_no, v_line.ln, v_line.item_no) b
      join public."Items" ci on ci."Code" = b.component_code
      order by b.component_code
    loop
      begin
        select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(v_comp.code, null) k;
        v_comp_on_hand := public._ile_balance(v_key.item_code, v_key.variant_id, coalesce(v_from, ''));
      exception when others then
        v_comp_on_hand := null;
      end;

      line_no := v_line.ln;
      parent_item := v_line.item_no;
      component_code := v_comp.code;
      component_name := v_comp.name;
      qty_per := v_comp.qty_per;
      remaining := v_line.remaining;
      parent_on_hand := v_parent_on_hand;
      to_build := greatest(0, v_line.remaining - v_parent_on_hand);
      qty_required := to_build * v_comp.qty_per;
      comp_on_hand := v_comp_on_hand;
      total_required := v_line.remaining * v_comp.qty_per;
      return next;
    end loop;
  end loop;
end;
$$;

grant execute on function public.staff_get_transfer_bom(text, text, text) to anon;

-- ============================================================================
-- 3. Available (Manage modal + pre-ship check) understands Assemble-to-Order lines
-- ============================================================================

drop function if exists public.staff_get_transfer_line_stock(text, text, text);

create or replace function public.staff_get_transfer_line_stock(
  p_admin_username text,
  p_admin_password text,
  p_document_no text
)
returns table(line_no bigint, available_quantity numeric, fetch_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_from text;
  v_line record;
  v_key record;
  v_comp record;
  v_can_build numeric;
  v_buildable numeric;
  v_has_components boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "From Warehouse ID" into v_from from public."Transfer_Header" where "No." = p_document_no;

  for v_line in
    select tl."Line No."::bigint as ln, tl."Item No."::text as item_no, tl."Variant ID"::text as variant_id,
           coalesce(i."AssembleToOrder", false) as ato
    from public."Transfer_Line" tl
    left join public."Items" i on i."Code" = tl."Item No."
    where tl."Document No." = p_document_no
    order by tl."Line No."
  loop
    line_no := v_line.ln;
    available_quantity := null;
    fetch_error := null;

    begin
      select k.item_code, k.variant_id into v_key
        from public._ile_resolve_stock_key(v_line.item_no, nullif(trim(coalesce(v_line.variant_id, '')), '')) k;
      available_quantity := public._ile_balance(v_key.item_code, v_key.variant_id, coalesce(v_from, ''));

      -- Assemble-to-Order: what is on hand PLUS how many more the components can build.
      if v_line.ato then
        v_can_build := null;
        v_has_components := false;
        for v_comp in
          select b.component_code as code, b.qty_per as qty_per from public._ile_line_bom(p_document_no, v_line.ln, v_line.item_no) b
        loop
          v_has_components := true;
          select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(v_comp.code, null) k;
          v_buildable := floor(greatest(0, public._ile_balance(v_key.item_code, v_key.variant_id, coalesce(v_from, ''))) / v_comp.qty_per);
          v_can_build := least(coalesce(v_can_build, v_buildable), v_buildable);
        end loop;
        if not v_has_components then
          fetch_error := 'Assemble-to-Order item has no BOM components set up in Item Setup.';
          available_quantity := null;
        else
          available_quantity := greatest(0, available_quantity) + coalesce(v_can_build, 0);
        end if;
      end if;
    exception when others then
      fetch_error := sqlerrm;
      available_quantity := null;
    end;

    return next;
  end loop;
end;
$$;

grant execute on function public.staff_get_transfer_line_stock(text, text, text) to anon;

-- ============================================================================
-- 4. Shipping an Assemble-to-Order line assembles it first
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
  v_key record;
  v_comp record;
  v_have numeric;
  v_build numeric;
  v_tx bigint;
  v_has_components boolean;
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
    -- Assemble-to-Order: build the shortfall at the From warehouse before it ships.
    if v_ship_delta > 0 and exists (select 1 from public."Items" i where i."Code" = new."Item No." and i."AssembleToOrder") then
      select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(new."Item No.", v_variant) k;
      v_have := greatest(0, public._ile_balance(v_key.item_code, v_key.variant_id, coalesce(v_header.from_id, '')));
      v_build := greatest(0, v_ship_delta - v_have);

      if v_build > 0 then
        v_has_components := false;
        v_tx := nextval('public.ile_transaction_no_seq');

        for v_comp in
          select b.component_code as code, b.qty_per as qty_per from public._ile_line_bom(new."Document No.", new."Line No."::bigint, new."Item No.") b
        loop
          v_has_components := true;
          perform public._ile_post(
            'Negative Adjmt.', v_comp.code, null, coalesce(v_header.from_id, ''), -(v_build * v_comp.qty_per),
            public._ile_today(), 'Assembly', new."Document No.",
            'Assembled ' || v_build || ' x ' || new."Item No." || ' for ' || new."Document No.", v_tx, v_actor,
            null, true
          );
        end loop;

        if not v_has_components then
          raise exception 'Cannot ship % - it is an Assemble-to-Order item but has no BOM components in Item Setup.', new."Item No.";
        end if;

        perform public._ile_post(
          'Positive Adjmt.', new."Item No.", v_variant, coalesce(v_header.from_id, ''), v_build,
          public._ile_today(), 'Assembly', new."Document No.",
          'Assembled for ' || new."Document No.", v_tx, v_actor
        );
      end if;
    end if;

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

notify pgrst, 'reload schema';
