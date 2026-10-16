-- Replacement serials - per "can i produce a barcode thats for replacement?" / "its a new one
-- replacement we will get the aquarium back from the customer (this has no serials yet because we
-- dont have system previously) then we change it a brand new".
--
-- A customer who bought before the system existed brings a unit back (it never had a serial) and gets a
-- brand-new one. That new unit needs a serial + label, but none of the normal ways of making one fit
-- (Post Output = built for stock, Ready to Ship = an online order, Serial Journal = a count). So:
--
--   "SerialReplacements"        - one row per replacement: RPL-000001, the new serial, the customer,
--                                 what they had before (old receipt / description, free text - there's
--                                 no record of the old sale), why, who, when.
--   admin_create_replacement_serial(...)  - SUPER USER ONLY. Creates the new serial (same numbering as
--                                 every other serial: RS-<ItemCode>-<YY>-000001), SOLD at the chosen
--                                 location, SourceDocumentNo = the RPL- number (so the label prints
--                                 "REPLACEMENT" and the Serial Tracker shows it). Optionally takes 1 out
--                                 of stock there (Item Ledger Negative Adjmt., refused if it would go
--                                 below zero) - tick it when the new unit came off the shelf / out of the
--                                 counted stock; leave it off when the ledger never had it.
--   staff_get_serial_replacement(serial) - the replacement details for the Serial Tracker card.
--
-- The returned (old) unit is not given a serial here.
--
-- Run AFTER supabase_production_orders.sql (_production_next_serial_no, _production_item_needs_serial)
-- and supabase_item_ledger_entries.sql (_ile_post). Safe to re-run. Needs serialTracker.js ?v=replace1.

create sequence if not exists public.serial_replacement_no_seq as bigint;

create table if not exists public."SerialReplacements" (
    "Id" bigint generated always as identity primary key,
    "DocumentNo" varchar(30) not null unique,
    "RunningSerialNo" bigint not null references public."ItemSerialTracking" ("RunningSerialNo"),
    "SerialNo" varchar(120) not null,
    "ItemCode" varchar(100) not null,
    "VariantCode" varchar(200),
    "WarehouseId" varchar(100) not null,
    "WarehouseName" varchar(255),
    "CustomerName" varchar(200) not null,
    "CustomerContact" varchar(200),
    "OriginalReference" varchar(500),
    "Reason" varchar(500) not null,
    "TookFromStock" boolean not null default false,
    "LedgerTransactionNo" bigint,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_SerialReplacements_SerialNo" on public."SerialReplacements" ("SerialNo");

alter table public."SerialReplacements" enable row level security;
revoke all on public."SerialReplacements" from anon, authenticated;

comment on table public."SerialReplacements" is
  'Brand-new units given to a customer in place of a returned one (supabase_serial_replacement.sql). The new serial is SOLD with SourceDocumentNo = DocumentNo.';

-- ---------------------------------------------------------------------------
drop function if exists public.admin_create_replacement_serial(text, text, text, text, text, text, text, text, text, boolean);

create or replace function public.admin_create_replacement_serial(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_variant_id text,
  p_warehouse_id text,
  p_customer_name text,
  p_customer_contact text,
  p_original_reference text,
  p_reason text,
  p_take_from_stock boolean default false
)
returns table(document_no text, serial_no text, item_code text, item_description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_item text := trim(coalesce(p_item_code, ''));
  v_variant text := nullif(trim(coalesce(p_variant_id, '')), '');
  v_serial_variant text;
  v_item_name text;
  v_wh_name text;
  v_doc_no text;
  v_serial_no text;
  v_running bigint;
  v_transaction_no bigint;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can create a replacement serial.';
  end if;

  select coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")
    into v_item_name
    from public."Items" i where i."Code" = v_item;
  if not found then
    raise exception 'Item "%" does not exist.', v_item;
  end if;
  if not public._production_item_needs_serial(v_item, v_variant) then
    raise exception 'Item % is not serial-tracked - replacement serials are only for aquariums / stands / sumps.', v_item;
  end if;

  -- Raises on a variant that doesn't belong to the item, or a missing variant when the item has several.
  perform 1 from public._ile_resolve_stock_key(v_item, v_variant);
  -- Same as the Serial Journal: a single-variant item still stamps its one variant on the serial.
  v_serial_variant := coalesce(v_variant,
    (select min(v."VariationId") from public."Variants" v where v."ItemCode" = v_item having count(*) = 1));

  select w."Name" into v_wh_name from public."Warehouses" w where w."ID" = trim(coalesce(p_warehouse_id, ''));
  if not found then
    raise exception 'Pick the location the new unit is given out from.';
  end if;

  if nullif(trim(coalesce(p_customer_name, '')), '') is null then
    raise exception 'Enter the customer''s name.';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'Enter a reason (e.g. "Warranty - cracked glass").';
  end if;

  v_doc_no := 'RPL-' || lpad(nextval('public.serial_replacement_no_seq')::text, 6, '0');
  v_serial_no := public._production_next_serial_no(v_item);

  insert into public."ItemSerialTracking"
    ("SerialNo", "ItemCode", "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedBy", "VariantCode", "UpdatedAtUtc", "UpdatedBy")
  values (v_serial_no, v_item, left(v_item_name, 255), v_wh_name, 'SOLD', v_doc_no, p_admin_username, v_serial_variant, now(), p_admin_username)
  returning "RunningSerialNo" into v_running;

  if coalesce(p_take_from_stock, false) then
    v_transaction_no := nextval('public.ile_transaction_no_seq');
    perform public._ile_post(
      'Negative Adjmt.', v_item, v_variant, trim(p_warehouse_id), -1,
      public._ile_today(), 'Serial Replacement', v_doc_no,
      left('Replacement for ' || trim(p_customer_name) || ' - ' || trim(p_reason), 500),
      v_transaction_no, p_admin_username, null, true
    );
  end if;

  insert into public."SerialReplacements"
    ("DocumentNo", "RunningSerialNo", "SerialNo", "ItemCode", "VariantCode", "WarehouseId", "WarehouseName",
     "CustomerName", "CustomerContact", "OriginalReference", "Reason", "TookFromStock", "LedgerTransactionNo", "CreatedBy")
  values
    (v_doc_no, v_running, v_serial_no, v_item, v_serial_variant, trim(p_warehouse_id), v_wh_name,
     left(trim(p_customer_name), 200), left(nullif(trim(coalesce(p_customer_contact, '')), ''), 200),
     left(nullif(trim(coalesce(p_original_reference, '')), ''), 500), left(trim(p_reason), 500),
     coalesce(p_take_from_stock, false), v_transaction_no, p_admin_username);

  document_no := v_doc_no;
  serial_no := v_serial_no;
  item_code := v_item;
  item_description := v_item_name;
  return next;
end;
$$;

grant execute on function public.admin_create_replacement_serial(text, text, text, text, text, text, text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_get_serial_replacement(text, text, text);

create or replace function public.staff_get_serial_replacement(
  p_admin_username text,
  p_admin_password text,
  p_serial_no text
)
returns table(document_no text, customer_name text, customer_contact text, original_reference text,
              reason text, warehouse_name text, took_from_stock boolean, created_by text, created_at timestamptz)
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
    select r."DocumentNo"::text, r."CustomerName"::text, r."CustomerContact"::text, r."OriginalReference"::text,
           r."Reason"::text, r."WarehouseName"::text, r."TookFromStock", r."CreatedBy"::text, r."CreatedAtUtc"
    from public."SerialReplacements" r
    where r."SerialNo" = trim(coalesce(p_serial_no, ''))
    order by r."Id" desc
    limit 1;
end;
$$;

grant execute on function public.staff_get_serial_replacement(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, 'ok' as detail
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('admin_create_replacement_serial', 'staff_get_serial_replacement')
union all
select 'replacements so far', 'SerialReplacements', count(*)::text
from public."SerialReplacements"
order by 1, 2;
