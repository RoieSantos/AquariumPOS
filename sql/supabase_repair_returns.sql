-- Repair Returns: a store sends a broken item (e.g. an aquarium) to our own makers / production warehouse
-- for repair, and gets it back afterwards - per "build a process that will return the items from store..
-- i got some aquariums need to return for repairs" (repaired by our own makers, full flow).
--
--   Send      staff_create_repair_return      Store Manager (own location) or Super User.
--                                             Photo + problem required. Posts a Negative Adjmt. at the store
--                                             (document type "Repair Shipment", document no. RPR-000001),
--                                             refused if the store doesn't have that many. Picked serials go
--                                             IN_REPAIR, located at the production warehouse. Status = Sent.
--   Receive   action 'receive'                Production Manager / Super User, assigning the maker (Tank /
--                                             Stand Maker, staff_list_order_makers). Sent -> In Repair.
--   Assign    action 'assign'                 Production Manager / Super User - change the maker while In Repair.
--   Repaired  action 'repaired'               Production Manager / Super User or the assigned maker, with what
--                                             was done. -> Repaired. A maker sees only their own repairs.
--   Return    action 'return'                 Production Manager / Super User. Posts a Positive Adjmt. at the
--                                             chosen store (default: where it came from, document type
--                                             "Repair Return"); serials back IN_STOCK there. -> Returned.
--   Scrap     action 'scrap'                  Super User only, with a reason (In Repair / Repaired). No stock
--                                             entry - it already left the store at Send. Serials SCRAPPED.
--   Cancel    action 'cancel'                 The sender or a Super User, only while Sent (not yet received).
--                                             Posts the stock back at the store; serials restored.
--
-- While out for repair the item is in NO warehouse on the Item Ledger, so it isn't sellable anywhere
-- (Stock On Hand, Order Now and the bot follow Items."QuantityInStock" = ledger total) - the Repair
-- Returns page is where it is. Photos reuse the Defect Items bucket and upload RPC
-- (staff_create_defect_photo_upload). Ledger entries of these two document types can't be reversed from
-- Item Ledger Entries (cancel / return the repair instead) - _ile_on_reversed below.
--
-- Run AFTER supabase_defect_reports.sql, supabase_production_orders.sql and
-- supabase_serial_reservation_on_hand.sql (this file replaces _ile_on_reversed with a copy of that file's
-- version + the Repair guard - don't re-run that file afterwards, or the guard is lost). Safe to re-run.

-- ============================================================================
-- 1. Tables
-- ============================================================================

create sequence if not exists public.repair_return_no_seq;

create table if not exists public."RepairReturns" (
    "Id" serial primary key,
    "RepairNo" varchar(30) not null unique,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100),
    "FromWarehouseId" varchar(100) not null,
    "RepairWarehouseId" varchar(100) not null,
    "Quantity" numeric(18, 4) not null check ("Quantity" > 0),
    "Problem" varchar(100) not null,
    "Note" varchar(1000),
    "PhotoPath" varchar(500),
    "PhotoUrl" varchar(1000),
    "Status" varchar(20) not null default 'Sent'
        check ("Status" in ('Sent', 'In Repair', 'Repaired', 'Returned', 'Scrapped', 'Cancelled')),
    "SentBy" varchar(100) not null,
    "SentAtUtc" timestamptz not null default now(),
    "SentTransactionNo" bigint,
    "ReceivedBy" varchar(100),
    "ReceivedAtUtc" timestamptz,
    -- The Tank / Stand Maker doing the repair (StaffUsers.Username).
    "Maker" varchar(100),
    "AssignedBy" varchar(100),
    "AssignedAtUtc" timestamptz,
    "RepairedBy" varchar(100),
    "RepairedAtUtc" timestamptz,
    "RepairNote" varchar(1000),
    "ReturnWarehouseId" varchar(100),
    "ReturnedBy" varchar(100),
    "ReturnedAtUtc" timestamptz,
    "ReturnTransactionNo" bigint,
    -- Why it was scrapped / cancelled.
    "ClosedBy" varchar(100),
    "ClosedAtUtc" timestamptz,
    "ClosedNote" varchar(1000)
);

-- For a table created by the first version of this file.
alter table public."RepairReturns" add column if not exists "Maker" varchar(100);
alter table public."RepairReturns" add column if not exists "AssignedBy" varchar(100);
alter table public."RepairReturns" add column if not exists "AssignedAtUtc" timestamptz;

create index if not exists "IX_RepairReturns_Status" on public."RepairReturns" ("Status");
create index if not exists "IX_RepairReturns_Maker" on public."RepairReturns" ("Maker");
create index if not exists "IX_RepairReturns_From" on public."RepairReturns" ("FromWarehouseId");

-- The serial-tracked units on a repair, with where they were before (for Cancel).
create table if not exists public."RepairReturnSerials" (
    "RepairId" int not null references public."RepairReturns" ("Id") on delete cascade,
    "RunningSerialNo" bigint not null references public."ItemSerialTracking" ("RunningSerialNo"),
    "PrevStatus" varchar(255),
    "PrevLocation" varchar(255),
    primary key ("RepairId", "RunningSerialNo")
);

alter table public."RepairReturns" enable row level security;
alter table public."RepairReturnSerials" enable row level security;
revoke all on public."RepairReturns" from anon, authenticated;
revoke all on public."RepairReturnSerials" from anon, authenticated;

-- ============================================================================
-- 2. Who is calling
-- ============================================================================

drop function if exists public._repair_caller(text, text);

create or replace function public._repair_caller(p_username text, p_password text)
returns table(is_super boolean, is_store_manager boolean, is_production boolean, is_maker boolean, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user record;
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce(u."SuperUser", false) as su,
         coalesce(u."StoreManager", false) as sm,
         'ProductionManager' = any(coalesce(u."StaffRoles", '{}')) as pm,
         coalesce(u."StaffRoles", '{}') && array['TankMaker', 'StandMaker']::text[] as mk,
         nullif(trim(coalesce(u."WarehouseName", '')), '')::text as wh
    into v_user
    from public."StaffUsers" u
   where u."Username" = p_username;

  if not (v_user.su or v_user.sm or v_user.pm or v_user.mk) then
    raise exception 'Not authorized.';
  end if;

  return query select v_user.su, v_user.sm, (v_user.su or v_user.pm), v_user.mk, v_user.wh;
end;
$$;

revoke execute on function public._repair_caller(text, text) from public, anon, authenticated;

-- ============================================================================
-- 3. Serials that can go (In Stock at the store)
-- ============================================================================

drop function if exists public.staff_list_repair_serials(text, text, text, text, text);

create or replace function public.staff_list_repair_serials(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_variant_id text,
  p_warehouse_id text
)
returns table(running_serial_no bigint, serial_no text, variant_code text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  perform 1 from public._repair_caller(p_admin_username, p_admin_password);

  return query
    select s."RunningSerialNo", s."SerialNo"::text, s."VariantCode"::text
    from public."ItemSerialTracking" s
    join public."Warehouses" w on w."ID" = trim(coalesce(p_warehouse_id, ''))
    where s."ItemCode" = trim(coalesce(p_item_code, ''))
      and (nullif(trim(coalesce(p_variant_id, '')), '') is null or s."VariantCode" = trim(p_variant_id))
      and s."Status" = 'IN_STOCK'
      and public._sij_same_location(s."Location", w."Name")
    order by s."SerialNo";
end;
$$;

grant execute on function public.staff_list_repair_serials(text, text, text, text, text) to anon;

-- ============================================================================
-- 4. Send for repair
-- ============================================================================

drop function if exists public.staff_create_repair_return(text, text, text, text, text, text, numeric, text, text, text, text, bigint[]);

create or replace function public.staff_create_repair_return(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_variant_id text,
  p_from_warehouse_id text,
  p_repair_warehouse_id text,
  p_quantity numeric,
  p_problem text,
  p_note text,
  p_photo_path text,
  p_photo_url text,
  p_running_serial_nos bigint[] default null
)
returns table(repair_id int, repair_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caller record;
  v_from_name text;
  v_repair record;
  v_item text;
  v_variant text;
  v_serials bigint[] := coalesce(p_running_serial_nos, '{}');
  v_serial_count int;
  v_bad record;
  v_id int;
  v_no text;
  v_transaction_no bigint;
begin
  select * into v_caller from public._repair_caller(p_admin_username, p_admin_password);

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Enter how many are going for repair.';
  end if;
  if nullif(trim(coalesce(p_problem, '')), '') is null then
    raise exception 'Pick what is wrong with it.';
  end if;
  if nullif(trim(coalesce(p_photo_path, '')), '') is null or nullif(trim(coalesce(p_photo_url, '')), '') is null then
    raise exception 'A photo of the damage is required.';
  end if;

  select w."Name" into v_from_name from public."Warehouses" w where w."ID" = trim(coalesce(p_from_warehouse_id, ''));
  if not found then
    raise exception 'Store not found.';
  end if;

  -- Same people as Defect Items (its photo upload RPC is reused); a store manager sends only from their
  -- own store.
  if not v_caller.is_super and not v_caller.is_store_manager then
    raise exception 'Only a Store Manager or Super User can send items for repair.';
  end if;
  if not v_caller.is_super
     and lower(trim(coalesce(v_caller.warehouse_name, ''))) <> lower(trim(v_from_name)) then
    raise exception 'You can only send items from your own location (%).', coalesce(v_caller.warehouse_name, 'none assigned');
  end if;

  select w."ID", w."Name", coalesce(w."IsProductionWarehouse", false) as is_prod into v_repair
    from public."Warehouses" w where w."ID" = trim(coalesce(p_repair_warehouse_id, ''));
  if not found then
    raise exception 'Pick the production warehouse doing the repair.';
  end if;
  if not v_repair.is_prod then
    raise exception '% is not a production warehouse - repairs go to our makers.', v_repair."Name";
  end if;

  select k.item_code, k.variant_id into v_item, v_variant
    from public._ile_resolve_stock_key(trim(coalesce(p_item_code, '')), nullif(trim(coalesce(p_variant_id, '')), '')) k;

  v_serials := array(select distinct unnest(v_serials));
  v_serial_count := coalesce(array_length(v_serials, 1), 0);
  if v_serial_count > p_quantity then
    raise exception 'You picked % serials for % unit(s).', v_serial_count, p_quantity;
  end if;

  if v_serial_count > 0 then
    select s."SerialNo", s."Status", s."Location", s."ItemCode" into v_bad
      from public."ItemSerialTracking" s
     where s."RunningSerialNo" = any(v_serials)
       and (s."ItemCode" <> v_item
            or (v_variant is not null and coalesce(s."VariantCode", '') <> v_variant)
            or s."Status" <> 'IN_STOCK'
            or not public._sij_same_location(s."Location", v_from_name))
     limit 1;
    if found then
      raise exception 'Serial % is % at % (item %) - pick serials that are In Stock at % for this item.',
        v_bad."SerialNo", v_bad."Status", coalesce(v_bad."Location", '(no location)'), v_bad."ItemCode", v_from_name;
    end if;
    if (select count(*) from public."ItemSerialTracking" where "RunningSerialNo" = any(v_serials)) <> v_serial_count then
      raise exception 'One of the picked serials no longer exists - refresh and pick again.';
    end if;
  end if;

  v_no := 'RPR-' || lpad(nextval('public.repair_return_no_seq')::text, 6, '0');
  v_transaction_no := nextval('public.ile_transaction_no_seq');

  -- Refused if the store doesn't have this many (p_prevent_negative = true).
  perform public._ile_post(
    'Negative Adjmt.', v_item, v_variant, trim(p_from_warehouse_id), -round(p_quantity, 4),
    public._ile_today(), 'Repair Shipment', v_no,
    left('Sent for repair to ' || v_repair."Name" || ' - ' || trim(p_problem) || coalesce(': ' || nullif(trim(coalesce(p_note, '')), ''), ''), 500),
    v_transaction_no, p_admin_username, null, true
  );

  insert into public."RepairReturns" (
    "RepairNo", "ItemCode", "VariantId", "FromWarehouseId", "RepairWarehouseId", "Quantity", "Problem", "Note",
    "PhotoPath", "PhotoUrl", "SentBy", "SentTransactionNo"
  )
  values (
    v_no, v_item, v_variant, trim(p_from_warehouse_id), v_repair."ID", round(p_quantity, 4), trim(p_problem),
    nullif(trim(coalesce(p_note, '')), ''), trim(p_photo_path), trim(p_photo_url), p_admin_username, v_transaction_no
  )
  returning "Id" into v_id;

  if v_serial_count > 0 then
    insert into public."RepairReturnSerials" ("RepairId", "RunningSerialNo", "PrevStatus", "PrevLocation")
      select v_id, s."RunningSerialNo", s."Status", s."Location"
        from public."ItemSerialTracking" s where s."RunningSerialNo" = any(v_serials);

    -- Location is always a plain warehouse name (see supabase_transfer_order_serial_tagging.sql) - the
    -- status says it's being repaired, not sellable.
    update public."ItemSerialTracking"
       set "Status" = 'IN_REPAIR', "Location" = v_repair."Name", "SourceDocumentNo" = v_no, "UpdatedAtUtc" = now()
     where "RunningSerialNo" = any(v_serials);
  end if;

  repair_id := v_id;
  repair_no := v_no;
  return next;
end;
$$;

grant execute on function public.staff_create_repair_return(text, text, text, text, text, text, numeric, text, text, text, text, bigint[]) to anon;

-- ============================================================================
-- 5. List
-- ============================================================================

drop function if exists public.staff_list_repair_returns(text, text, text, text, int, int);

create or replace function public.staff_list_repair_returns(
  p_admin_username text,
  p_admin_password text,
  p_status text default null,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 25
)
returns table(
  id int, repair_no text, item_code text, item_name text, variant_id text, variant_name text,
  from_warehouse_id text, from_warehouse_name text, repair_warehouse_name text, quantity numeric,
  problem text, note text, photo_url text, status text, serial_nos text,
  sent_by text, sent_at_utc timestamptz, received_by text, received_at_utc timestamptz,
  maker text, maker_name text, repaired_by text, repaired_at_utc timestamptz, repair_note text,
  return_warehouse_name text, returned_by text, returned_at_utc timestamptz,
  closed_by text, closed_at_utc timestamptz, closed_note text, total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_caller record;
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_size int := least(greatest(coalesce(p_page_size, 25), 1), 100);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_status text := nullif(trim(coalesce(p_status, '')), '');
begin
  select * into v_caller from public._repair_caller(p_admin_username, p_admin_password);

  return query
    select
      r."Id", r."RepairNo"::text, r."ItemCode"::text, i."Name"::text, r."VariantId"::text, v."VariantName"::text,
      r."FromWarehouseId"::text, wf."Name"::text, wr."Name"::text, r."Quantity",
      r."Problem"::text, r."Note"::text, r."PhotoUrl"::text, r."Status"::text,
      (select string_agg(s."SerialNo", ', ' order by s."SerialNo")
         from public."RepairReturnSerials" rs
         join public."ItemSerialTracking" s on s."RunningSerialNo" = rs."RunningSerialNo"
        where rs."RepairId" = r."Id")::text,
      r."SentBy"::text, r."SentAtUtc", r."ReceivedBy"::text, r."ReceivedAtUtc",
      r."Maker"::text, coalesce(nullif(trim(mk."DisplayName"), ''), r."Maker")::text, r."RepairedBy"::text, r."RepairedAtUtc", r."RepairNote"::text,
      wt."Name"::text, r."ReturnedBy"::text, r."ReturnedAtUtc",
      r."ClosedBy"::text, r."ClosedAtUtc", r."ClosedNote"::text,
      count(*) over ()
    from public."RepairReturns" r
    left join public."Items" i on i."Code" = r."ItemCode"
    left join public."Variants" v on v."VariationId" = r."VariantId"
    left join public."Warehouses" wf on wf."ID" = r."FromWarehouseId"
    left join public."Warehouses" wr on wr."ID" = r."RepairWarehouseId"
    left join public."Warehouses" wt on wt."ID" = r."ReturnWarehouseId"
    left join public."StaffUsers" mk on mk."Username" = r."Maker"
    where (v_status is null
           or (v_status = 'Open' and r."Status" in ('Sent', 'In Repair', 'Repaired'))
           or r."Status" = v_status)
      -- A plain store manager sees what their store sent or got back; a maker, what's assigned to them.
      and (v_caller.is_super or v_caller.is_production
           or (v_caller.is_store_manager
               and (lower(trim(coalesce(wf."Name", ''))) = lower(trim(coalesce(v_caller.warehouse_name, '~none~')))
                    or lower(trim(coalesce(wt."Name", ''))) = lower(trim(coalesce(v_caller.warehouse_name, '~none~')))))
           or (v_caller.is_maker and r."Maker" = p_admin_username))
      and (v_search is null
           or r."RepairNo" ilike '%' || v_search || '%'
           or r."ItemCode" ilike '%' || v_search || '%'
           or i."Name" ilike '%' || v_search || '%'
           or exists (select 1 from public."RepairReturnSerials" rs
                        join public."ItemSerialTracking" s on s."RunningSerialNo" = rs."RunningSerialNo"
                       where rs."RepairId" = r."Id" and s."SerialNo" ilike '%' || v_search || '%'))
    order by (r."Status" in ('Sent', 'In Repair', 'Repaired')) desc, r."Id" desc
    limit v_size offset (v_page - 1) * v_size;
end;
$$;

grant execute on function public.staff_list_repair_returns(text, text, text, text, int, int) to anon;

-- ============================================================================
-- 6. Move it along: receive / repaired / return / scrap / cancel
-- ============================================================================

drop function if exists public.staff_repair_return_action(text, text, int, text, text, text);
drop function if exists public.staff_repair_return_action(text, text, int, text, text, text, text);

create or replace function public.staff_repair_return_action(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_action text,
  p_return_warehouse_id text default null,
  p_note text default null,
  p_maker text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_caller record;
  v_r public."RepairReturns";
  v_action text := lower(trim(coalesce(p_action, '')));
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_to record;
  v_transaction_no bigint;
  v_maker text := nullif(trim(coalesce(p_maker, '')), '');
begin
  select * into v_caller from public._repair_caller(p_admin_username, p_admin_password);

  select * into v_r from public."RepairReturns" where "Id" = p_id for update;
  if not found then
    raise exception 'Repair not found.';
  end if;

  -- The assigned maker may mark their own repair done; everything else at production is the manager's.
  if v_action in ('receive', 'assign', 'return') and not v_caller.is_production then
    raise exception 'Only a Production Manager or Super User can do that.';
  end if;
  if v_action = 'repaired' and not v_caller.is_production
     and not (v_caller.is_maker and v_r."Maker" = p_admin_username) then
    raise exception 'Only the assigned maker, a Production Manager or a Super User can mark this repaired.';
  end if;

  if v_action in ('receive', 'assign') then
    if v_maker is null then
      raise exception 'Pick the maker doing the repair.';
    end if;
    if not exists (select 1 from public."StaffUsers"
                    where "Username" = v_maker and "IsActive"
                      and coalesce("StaffRoles", '{}') && array['TankMaker', 'StandMaker']::text[]) then
      raise exception '% is not an active Tank / Stand Maker.', v_maker;
    end if;
  end if;

  if v_action = 'receive' then
    if v_r."Status" <> 'Sent' then
      raise exception '% is already %.', v_r."RepairNo", lower(v_r."Status");
    end if;
    update public."RepairReturns"
       set "Status" = 'In Repair', "ReceivedBy" = p_admin_username, "ReceivedAtUtc" = now(),
           "Maker" = v_maker, "AssignedBy" = p_admin_username, "AssignedAtUtc" = now()
     where "Id" = p_id;
    return 'In Repair';
  end if;

  if v_action = 'assign' then
    if v_r."Status" <> 'In Repair' then
      raise exception 'The maker can only be changed while % is In Repair (it is %).', v_r."RepairNo", lower(v_r."Status");
    end if;
    update public."RepairReturns"
       set "Maker" = v_maker, "AssignedBy" = p_admin_username, "AssignedAtUtc" = now()
     where "Id" = p_id;
    return 'In Repair';
  end if;

  if v_action = 'repaired' then
    if v_r."Status" <> 'In Repair' then
      raise exception 'Only an item that is In Repair can be marked repaired (% is %).', v_r."RepairNo", lower(v_r."Status");
    end if;
    if v_note is null then
      raise exception 'Say what was repaired.';
    end if;
    update public."RepairReturns"
       set "Status" = 'Repaired', "RepairedBy" = p_admin_username, "RepairedAtUtc" = now(), "RepairNote" = left(v_note, 1000)
     where "Id" = p_id;
    return 'Repaired';
  end if;

  if v_action = 'return' then
    if v_r."Status" <> 'Repaired' then
      raise exception 'Mark % repaired before returning it.', v_r."RepairNo";
    end if;
    select w."ID", w."Name" into v_to
      from public."Warehouses" w
     where w."ID" = coalesce(nullif(trim(coalesce(p_return_warehouse_id, '')), ''), v_r."FromWarehouseId");
    if not found then
      raise exception 'Pick the store it goes back to.';
    end if;

    v_transaction_no := nextval('public.ile_transaction_no_seq');
    perform public._ile_post(
      'Positive Adjmt.', v_r."ItemCode", v_r."VariantId", v_to."ID", v_r."Quantity",
      public._ile_today(), 'Repair Return', v_r."RepairNo",
      left('Back from repair - ' || coalesce(v_r."RepairNote", v_r."Problem"), 500),
      v_transaction_no, p_admin_username, null, false
    );

    update public."ItemSerialTracking" s
       set "Status" = 'IN_STOCK', "Location" = v_to."Name", "SourceDocumentNo" = v_r."RepairNo", "UpdatedAtUtc" = now()
      from public."RepairReturnSerials" rs
     where rs."RepairId" = p_id and s."RunningSerialNo" = rs."RunningSerialNo" and s."Status" = 'IN_REPAIR';

    update public."RepairReturns"
       set "Status" = 'Returned', "ReturnWarehouseId" = v_to."ID", "ReturnedBy" = p_admin_username,
           "ReturnedAtUtc" = now(), "ReturnTransactionNo" = v_transaction_no
     where "Id" = p_id;
    return 'Returned';
  end if;

  if v_action = 'scrap' then
    if not v_caller.is_super then
      raise exception 'Only a Super User can scrap a repair.';
    end if;
    if v_r."Status" not in ('In Repair', 'Repaired') then
      raise exception 'Only an item at production (In Repair / Repaired) can be scrapped - % is %.', v_r."RepairNo", lower(v_r."Status");
    end if;
    if v_note is null then
      raise exception 'Say why it can''t be repaired.';
    end if;

    -- No ledger entry: the stock already left the store when it was sent.
    update public."ItemSerialTracking" s
       set "Status" = 'SCRAPPED', "SourceDocumentNo" = v_r."RepairNo", "UpdatedAtUtc" = now()
      from public."RepairReturnSerials" rs
     where rs."RepairId" = p_id and s."RunningSerialNo" = rs."RunningSerialNo" and s."Status" = 'IN_REPAIR';

    update public."RepairReturns"
       set "Status" = 'Scrapped', "ClosedBy" = p_admin_username, "ClosedAtUtc" = now(), "ClosedNote" = left(v_note, 1000)
     where "Id" = p_id;
    return 'Scrapped';
  end if;

  if v_action = 'cancel' then
    if v_r."Status" <> 'Sent' then
      raise exception 'Only a repair not yet received at production can be cancelled - % is %.', v_r."RepairNo", lower(v_r."Status");
    end if;
    if not v_caller.is_super and v_r."SentBy" <> p_admin_username then
      raise exception 'Only the person who sent it (or a Super User) can cancel it.';
    end if;

    v_transaction_no := nextval('public.ile_transaction_no_seq');
    perform public._ile_post(
      'Positive Adjmt.', v_r."ItemCode", v_r."VariantId", v_r."FromWarehouseId", v_r."Quantity",
      public._ile_today(), 'Repair Return', v_r."RepairNo",
      left('Repair cancelled - not sent' || coalesce(': ' || v_note, ''), 500),
      v_transaction_no, p_admin_username, null, false
    );

    update public."ItemSerialTracking" s
       set "Status" = coalesce(rs."PrevStatus", 'IN_STOCK'), "Location" = rs."PrevLocation", "UpdatedAtUtc" = now()
      from public."RepairReturnSerials" rs
     where rs."RepairId" = p_id and s."RunningSerialNo" = rs."RunningSerialNo" and s."Status" = 'IN_REPAIR';

    update public."RepairReturns"
       set "Status" = 'Cancelled', "ClosedBy" = p_admin_username, "ClosedAtUtc" = now(), "ClosedNote" = v_note,
           "ReturnWarehouseId" = v_r."FromWarehouseId", "ReturnTransactionNo" = v_transaction_no
     where "Id" = p_id;
    return 'Cancelled';
  end if;

  raise exception 'Unknown action "%".', p_action;
end;
$$;

grant execute on function public.staff_repair_return_action(text, text, int, text, text, text, text) to anon;

-- ============================================================================
-- 7. Item Ledger Entries > Reverse: refuse repair entries
-- ============================================================================

-- Copied from supabase_serial_reservation_on_hand.sql unchanged, plus the Repair guard at the top.
create or replace function public._ile_on_reversed(p_entry public."ItemLedgerEntries")
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line record;
  v_key record;
  v_left numeric;
  v_take numeric;
  v_output public."ProductionOrderOutputs";
  v_warehouse_name text;
  v_bad record;
  v_ps record;
begin
  -- Repair Returns (supabase_repair_returns.sql): the repair document would still say the item is out
  -- for repair / back at the store.
  if p_entry."DocumentType" in ('Repair Shipment', 'Repair Return') then
    raise exception 'Repair entries cannot be reversed here - cancel or return the repair on the Repair Returns page instead.';
  end if;

  if p_entry."DocumentType" in ('Transfer Shipment', 'Transfer Receipt') then
    raise exception 'Transfer entries cannot be reversed here - the transfer document would still say the goods moved. Correct the stock with an adjustment instead.';
  end if;

  -- Sales follow their order automatically (supabase_item_ledger_sales.sql): a hand-made reversal
  -- would be undone on the next pass, since the order would still say the item was sold.
  if p_entry."DocumentType" = 'Sales Order' then
    raise exception 'Sales entries follow their order automatically - cancel or edit the order, or post an adjustment.';
  end if;

  if p_entry."DocumentType" = 'Purchase Receipt' and p_entry."Quantity" > 0 then
    v_left := p_entry."Quantity";

    for v_line in
      select "EntryNo", "ItemCode", "VariantCode", "QtyReceived"
      from public."PurchaseOrderLines"
      where "PONo" = p_entry."DocumentNo"
        and "WarehouseId" = p_entry."WarehouseId"
        and "QtyReceived" > 0
      order by "EntryNo"
    loop
      exit when v_left <= 0;

      begin
        select k.item_code, k.variant_id into v_key
          from public._ile_resolve_stock_key(v_line."ItemCode", nullif(trim(coalesce(v_line."VariantCode", '')), '')) k;
      exception when others then
        continue;
      end;

      if v_key.item_code = p_entry."ItemCode" and coalesce(v_key.variant_id, '') = coalesce(p_entry."VariantId", '') then
        v_take := least(v_left, v_line."QtyReceived");
        update public."PurchaseOrderLines" set "QtyReceived" = "QtyReceived" - v_take where "EntryNo" = v_line."EntryNo";
        v_left := v_left - v_take;
      end if;
    end loop;
  end if;

  -- Production output (supabase_production_orders.sql).
  if p_entry."DocumentType" = 'Production Output' and p_entry."Quantity" > 0 then
    select * into v_output from public."ProductionOrderOutputs" where "EntryNo" = p_entry."EntryNo";
    if found then
      select "Name" into v_warehouse_name from public."Warehouses" where "ID" = p_entry."WarehouseId";

      select s."SerialNo", s."Status", s."Location" into v_bad
        from public."ProductionOrderOutputSerials" os
        join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
        where os."EntryNo" = p_entry."EntryNo"
          and (s."Status" not in ('IN_STOCK', 'RESERVED') or coalesce(s."Location", '') <> coalesce(v_warehouse_name, ''))
        limit 1;
      if found then
        raise exception 'Serial % from this output is already % at % - it can''t be reversed. Correct the stock with an adjustment instead.',
          v_bad."SerialNo", v_bad."Status", coalesce(v_bad."Location", '(no location)');
      end if;

      update public."ItemSerialTracking" s
        set "Status" = 'REVERSED', "UpdatedAtUtc" = now()
        from public."ProductionOrderOutputSerials" os
        where os."EntryNo" = p_entry."EntryNo" and s."RunningSerialNo" = os."RunningSerialNo";

      update public."ProductionOrderLines"
        set "QtyOutput" = greatest(0, "QtyOutput" - v_output."Quantity")
        where "LineNo" = v_output."LineNo";

      update public."ProductionOrders"
        set "Status" = 'Released', "FinishedAtUtc" = null, "UpdatedAtUtc" = now()
        where "No" = v_output."ProdOrderNo" and "Status" = 'Finished';
    end if;
  end if;

  -- Serial Inventory Journal (supabase_serial_inventory_journal.sql).
  if p_entry."DocumentType" = 'Serial Phys. Inventory' then
    for v_ps in
      select ps.*, s."Status" as cur_status, s."Location" as cur_location, s."SerialNo" as serial_no, w."Name" as wh_name
      from public."SerialJournalPostedSerials" ps
      join public."ItemSerialTracking" s on s."RunningSerialNo" = ps."RunningSerialNo"
      left join public."Warehouses" w on w."ID" = ps."WarehouseId"
      where ps."TransactionNo" = p_entry."TransactionNo" and ps."UndoneAtUtc" is null
      order by ps."Id"
      for update of ps, s
    loop
      if v_ps."Action" in ('NEW', 'FOUND') then
        if v_ps.cur_status not in ('IN_STOCK', 'RESERVED') or not public._sij_same_location(v_ps.cur_location, v_ps.wh_name) then
          raise exception 'Serial % from this count is already % at % - it can''t be reversed. Count again instead.',
            v_ps.serial_no, v_ps.cur_status, coalesce(v_ps.cur_location, '(no location)');
        end if;
      elsif v_ps.cur_status <> 'MISSING' then
        raise exception 'Serial % (marked Missing by this count) is now % - it can''t be reversed. Count again instead.',
          v_ps.serial_no, v_ps.cur_status;
      end if;

      update public."ItemSerialTracking"
        set "Status" = case when v_ps."Action" = 'NEW' then 'REVERSED' else v_ps."PrevStatus" end,
            "Location" = case when v_ps."Action" = 'NEW' then "Location" else v_ps."PrevLocation" end,
            "UpdatedAtUtc" = now()
        where "RunningSerialNo" = v_ps."RunningSerialNo";
      update public."SerialJournalPostedSerials" set "UndoneAtUtc" = now() where "Id" = v_ps."Id";
    end loop;
  end if;
end;
$$;

revoke execute on function public._ile_on_reversed(public."ItemLedgerEntries") from public, anon, authenticated;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name,
       case when p.proname like '\_%' then 'internal'
            when has_function_privilege('anon', p.oid, 'EXECUTE') then 'callable by the portal (login checked inside)'
            else 'CHECK GRANTS' end as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('_repair_caller', 'staff_list_repair_serials', 'staff_create_repair_return',
                     'staff_list_repair_returns', 'staff_repair_return_action', '_ile_on_reversed')
union all
select 'RepairReturns table', count(*)::text || ' repair(s)' from public."RepairReturns";
