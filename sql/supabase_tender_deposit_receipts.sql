-- Tender Declarations: bank deposit receipts. Per "my managers are doing deposit on the declared cash..
-- i want a feature to be able to attach the receipt on the declared cash".
--
-- A Store Manager (own store only) or Super User attaches one or more deposits to a posted declaration:
-- a photo of the deposit slip + Deposit Amount, Deposit Date and an optional bank reference no. / note.
-- Only on the day's LATEST declaration - if the cashier re-declared, the earlier one is refused and
-- shows no "No deposit" tag.
-- The Tender Declarations page shows the deposited total per declaration and flags any whose deposits
-- don't add up to its Declared Cash.
--
-- The same slip can't go on two deposits, per "how can we make sure that it will not import same deposit
-- slip into difference declaration?": the Edge Function tender-deposit-read-slip stores the photo and
-- records its fingerprint and the slip's ID in TenderDepositSlipReads, and unique indexes on the deposits
-- refuse a repeat of either, at any store. A slip it can't read saves as "Slip not read" for a super user
-- to check; a super user can allow a real duplicate (recorded). Deploy that function with this file.
--
--   * TenderDeclarationDeposits - one row per deposit slip, keyed to TenderDeclarationHeader
--     (Warehouse + EODID), cascade-deleted with it.
--   * Storage bucket "tender-deposit-receipts" is PRIVATE (deposit slips show bank account details):
--     the photos are shown through short-lived signed URLs from staff_list_tender_deposits. Needs the
--     Vault secret "supabase_service_role_key" (supabase_configure_service_role_key.sql).
--
-- Also opens the page to Store Managers: admin_list_tender_declarations / admin_list_tender_declaration_lines
-- now live HERE (moved out of supabase_tender_declaration_tables.sql) and accept a Super User (every
-- store) or a Store Manager (their own store's declarations only, by StaffUsers.WarehouseName), via
-- is_phys_journal_authorized (supabase_phys_journal_store_manager_access.sql). The list also returns
-- deposit_total / deposit_count per row, total_deposited, and a p_deposit filter.
--
-- Run AFTER supabase_tender_declaration_tables.sql and supabase_phys_journal_store_manager_access.sql.
-- Safe to re-run. Needs js/tenderDeclarations.js ?v=tenderdeposit5 and js/auth.js / js/nav.js ?v=tenderdeposit1.

-- ============================================================================
-- 1. Storage bucket, table
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'tender-deposit-receipts',
  'tender-deposit-receipts',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

create table if not exists public."TenderDeclarationDeposits" (
    "Id" serial primary key,
    "Warehouse" varchar(200) not null,
    "EODID" varchar(50) not null,
    "DepositAmount" numeric(18, 2) not null check ("DepositAmount" > 0),
    "DepositDate" date not null,
    "ReferenceNo" varchar(100),
    "Note" varchar(500),
    "PhotoPath" varchar(500) not null,
    "UploadedBy" varchar(100) not null,
    "UploadedAtUtc" timestamptz not null default now(),
    constraint "FK_TenderDeclarationDeposits_Header" foreign key ("Warehouse", "EODID")
        references public."TenderDeclarationHeader" ("Warehouse", "EODID") on delete cascade
);

create index if not exists "IX_TenderDeclarationDeposits_Decl" on public."TenderDeclarationDeposits" ("Warehouse", "EODID");

alter table public."TenderDeclarationDeposits" enable row level security;
revoke all on public."TenderDeclarationDeposits" from anon, authenticated;

comment on table public."TenderDeclarationDeposits" is 'Bank deposit slips attached to a posted Tender Declaration (photo in the private tender-deposit-receipts bucket).';

-- One row per photo stored and read by the Edge Function tender-deposit-read-slip, before any deposit
-- is saved. Written only by that function (service role), so the slip's ID and fingerprint can't be
-- changed from the browser.
create table if not exists public."TenderDepositSlipReads" (
    "Id" uuid primary key default gen_random_uuid(),
    "Warehouse" varchar(200) not null,
    "EODID" varchar(50) not null,
    "PhotoPath" varchar(500) not null,
    "ImageSha256" varchar(64) not null,
    "SlipKey" varchar(150),
    "ReadReference" varchar(100),
    "ReadBy" varchar(100) not null,
    "ReadAtUtc" timestamptz not null default now(),
    constraint "FK_TenderDepositSlipReads_Header" foreign key ("Warehouse", "EODID")
        references public."TenderDeclarationHeader" ("Warehouse", "EODID") on delete cascade
);

alter table public."TenderDepositSlipReads" enable row level security;
revoke all on public."TenderDepositSlipReads" from anon, authenticated;
grant select, insert on public."TenderDepositSlipReads" to service_role;

comment on table public."TenderDepositSlipReads" is 'What tender-deposit-read-slip stored and read from each deposit slip photo. SlipKey = the slip''s ID (reference or machine line, letters and digits only), null if not read.';

-- Copied from the read when the deposit is saved. Null SlipKey = "Slip not read".
alter table public."TenderDeclarationDeposits" add column if not exists "ReadId" uuid references public."TenderDepositSlipReads" ("Id") on delete set null;
alter table public."TenderDeclarationDeposits" add column if not exists "SlipKey" varchar(150);
alter table public."TenderDeclarationDeposits" add column if not exists "ImageSha256" varchar(64);
-- A super user allowed this slip although it is already attached elsewhere.
alter table public."TenderDeclarationDeposits" add column if not exists "DuplicateAllowedBy" varchar(100);
alter table public."TenderDeclarationDeposits" add column if not exists "DuplicateAllowedAtUtc" timestamptz;

-- One slip on one deposit, at any store. Removing a deposit frees its slip.
create unique index if not exists "UX_TenderDeclarationDeposits_SlipKey" on public."TenderDeclarationDeposits" ("SlipKey")
  where "SlipKey" is not null and "DuplicateAllowedBy" is null;
create unique index if not exists "UX_TenderDeclarationDeposits_ImageSha256" on public."TenderDeclarationDeposits" ("ImageSha256")
  where "ImageSha256" is not null and "DuplicateAllowedBy" is null;
create unique index if not exists "UX_TenderDeclarationDeposits_ReadId" on public."TenderDeclarationDeposits" ("ReadId")
  where "ReadId" is not null;

-- ============================================================================
-- 2. Who is calling
-- ============================================================================

-- Raises unless the caller is a Super User or Store Manager. Returns whether they are a super user
-- and, for a store manager, the warehouse (by name) they are assigned to.
drop function if exists public._tender_decl_caller(text, text);

create or replace function public._tender_decl_caller(p_username text, p_password text)
returns table(is_super boolean, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_is_super boolean;
  v_warehouse text;
begin
  if not public.is_phys_journal_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce(u."SuperUser", false), nullif(trim(coalesce(u."WarehouseName", '')), '')
    into v_is_super, v_warehouse
    from public."StaffUsers" u
   where u."Username" = p_username;

  if not v_is_super and v_warehouse is null then
    raise exception 'Your account has no store assigned - ask a super user to set your warehouse.';
  end if;

  is_super := v_is_super;
  warehouse_name := v_warehouse;
  return next;
end;
$$;

revoke execute on function public._tender_decl_caller(text, text) from public, anon, authenticated;

-- Raises unless the caller may see / attach to this declaration (it exists, and a store manager
-- only for their own store).
drop function if exists public._tender_decl_check_access(text, text, text, text);

create or replace function public._tender_decl_check_access(p_username text, p_password text, p_warehouse text, p_eod_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_is_super boolean;
  v_caller_warehouse text;
begin
  select c.is_super, c.warehouse_name into v_is_super, v_caller_warehouse
    from public._tender_decl_caller(p_username, p_password) c;

  if not exists (select 1 from public."TenderDeclarationHeader"
                  where "Warehouse" = p_warehouse and "EODID" = p_eod_id) then
    raise exception 'Tender declaration % not found.', p_eod_id;
  end if;
  if not v_is_super and lower(trim(v_caller_warehouse)) <> lower(trim(p_warehouse)) then
    raise exception 'You can only open your own store''s declarations.';
  end if;
end;
$$;

revoke execute on function public._tender_decl_check_access(text, text, text, text) from public, anon, authenticated;

-- A day's deposit goes on that day's LATEST declaration (the "counted" one in the list - highest EODID
-- per Warehouse + DeclDate), so a cashier's earlier re-declared count can't take it. Raises otherwise.
drop function if exists public._tender_decl_require_latest(text, text);

create or replace function public._tender_decl_require_latest(p_warehouse text, p_eod_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_latest text;
begin
  select l."EODID" into v_latest
    from public."TenderDeclarationHeader" h
    join public."TenderDeclarationHeader" l
      on l."Warehouse" = h."Warehouse" and l."DeclDate" is not distinct from h."DeclDate"
   where h."Warehouse" = p_warehouse and h."EODID" = p_eod_id
   order by l."EODID" desc
   limit 1;

  if v_latest is not null and v_latest <> p_eod_id then
    raise exception '% was re-declared later that day - attach the deposit to the latest declaration, %.', p_eod_id, v_latest;
  end if;
end;
$$;

revoke execute on function public._tender_decl_require_latest(text, text) from public, anon, authenticated;

-- Folder for one declaration's slips: decl/<warehouse>/<EODID>/
drop function if exists public._tender_deposit_folder(text, text);

create or replace function public._tender_deposit_folder(p_warehouse text, p_eod_id text)
returns text
language sql
immutable
as $$
  select 'decl/' || regexp_replace(trim(coalesce(p_warehouse, '')), '[^A-Za-z0-9._-]+', '_', 'g')
      || '/' || regexp_replace(trim(coalesce(p_eod_id, '')), '[^A-Za-z0-9._-]+', '_', 'g') || '/';
$$;

-- ============================================================================
-- 3. Slip read (Edge Function tender-deposit-read-slip)
-- ============================================================================

-- The browser no longer uploads the photo itself - the function stores it along with the read.
drop function if exists public.staff_create_tender_deposit_upload(text, text, text, text, text);

-- Raises unless this login may attach to this declaration. Returns the folder for its photos.
-- Service role only: called by the Edge Function.
drop function if exists public._tender_deposit_prepare_read(text, text, text, text);

create or replace function public._tender_deposit_prepare_read(p_username text, p_password text, p_warehouse text, p_eod_id text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._tender_decl_check_access(p_username, p_password, p_warehouse, p_eod_id);
  perform public._tender_decl_require_latest(p_warehouse, p_eod_id);
  return public._tender_deposit_folder(p_warehouse, p_eod_id);
end;
$$;

revoke execute on function public._tender_deposit_prepare_read(text, text, text, text) from public, anon, authenticated;
grant execute on function public._tender_deposit_prepare_read(text, text, text, text) to service_role;

-- ============================================================================
-- 4. Add / list / delete deposits
-- ============================================================================

drop function if exists public.staff_add_tender_deposit(text, text, text, text, numeric, date, text, text, text);
drop function if exists public.staff_add_tender_deposit(text, text, text, text, numeric, date, text, text, uuid, boolean);

-- p_read_id: from tender-deposit-read-slip. A slip already on a deposit is refused (errcode RSDUP, so
-- the page can offer the override); p_allow_duplicate lets a super user save it anyway, recorded.
create or replace function public.staff_add_tender_deposit(
  p_admin_username text,
  p_admin_password text,
  p_warehouse text,
  p_eod_id text,
  p_amount numeric,
  p_deposit_date date,
  p_reference_no text,
  p_note text,
  p_read_id uuid,
  p_allow_duplicate boolean default false
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id int;
  v_is_super boolean;
  v_read public."TenderDepositSlipReads";
  v_duplicate_of text;
  v_allow boolean := false;
begin
  perform public._tender_decl_check_access(p_admin_username, p_admin_password, p_warehouse, p_eod_id);
  select c.is_super into v_is_super from public._tender_decl_caller(p_admin_username, p_admin_password) c;
  perform public._tender_decl_require_latest(p_warehouse, p_eod_id);

  if p_amount is null or p_amount <= 0 then
    raise exception 'Deposit Amount must be more than zero.';
  end if;
  if p_deposit_date is null then
    raise exception 'Deposit Date is required.';
  end if;
  if p_deposit_date > (now() at time zone 'Asia/Manila')::date then
    raise exception 'Deposit Date can''t be in the future.';
  end if;
  -- The photo must be one the Edge Function stored for THIS declaration, and not on a deposit already.
  select * into v_read from public."TenderDepositSlipReads" r
   where r."Id" = p_read_id and r."Warehouse" = p_warehouse and r."EODID" = p_eod_id;
  if not found or exists (select 1 from public."TenderDeclarationDeposits" d where d."ReadId" = p_read_id) then
    raise exception 'The receipt photo didn''t upload - attach it again.';
  end if;

  select d."EODID" into v_duplicate_of
    from public."TenderDeclarationDeposits" d
   where d."DuplicateAllowedBy" is null
     and (d."ImageSha256" = v_read."ImageSha256" or d."SlipKey" = v_read."SlipKey")
   limit 1;
  if v_duplicate_of is not null then
    if not (v_is_super and coalesce(p_allow_duplicate, false)) then
      raise exception 'This slip is already attached to %.', v_duplicate_of using errcode = 'RSDUP';
    end if;
    v_allow := true;
  end if;

  begin
    insert into public."TenderDeclarationDeposits"
      ("Warehouse", "EODID", "DepositAmount", "DepositDate", "ReferenceNo", "Note", "PhotoPath", "UploadedBy",
       "ReadId", "SlipKey", "ImageSha256", "DuplicateAllowedBy", "DuplicateAllowedAtUtc")
    values (p_warehouse, p_eod_id, round(p_amount, 2), p_deposit_date,
            left(nullif(trim(coalesce(p_reference_no, '')), ''), 100),
            left(nullif(trim(coalesce(p_note, '')), ''), 500),
            v_read."PhotoPath", p_admin_username,
            v_read."Id", v_read."SlipKey", v_read."ImageSha256",
            case when v_allow then p_admin_username end, case when v_allow then now() end)
    returning "Id" into v_id;
  exception when unique_violation then
    -- Two people saving the same slip at once: the check above passed for both.
    raise exception 'This slip was just attached to another deposit.' using errcode = 'RSDUP';
  end;

  return v_id;
end;
$$;

grant execute on function public.staff_add_tender_deposit(text, text, text, text, numeric, date, text, text, uuid, boolean) to anon;

-- One declaration's deposits, each with a signed photo URL good for an hour.
drop function if exists public.staff_list_tender_deposits(text, text, text, text);

create or replace function public.staff_list_tender_deposits(
  p_admin_username text,
  p_admin_password text,
  p_warehouse text,
  p_eod_id text
)
returns table(
  id int,
  deposit_amount numeric,
  deposit_date date,
  reference_no text,
  note text,
  photo_url text,
  uploaded_by text,
  uploaded_at_utc timestamptz,
  can_delete boolean,
  slip_not_read boolean,
  duplicate_allowed_by text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'tender-deposit-receipts';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_is_super boolean;
  v_response extensions.http_response;
  v_body jsonb;
  v_signed_path text;
  r record;
begin
  perform public._tender_decl_check_access(p_admin_username, p_admin_password, p_warehouse, p_eod_id);
  select c.is_super into v_is_super from public._tender_decl_caller(p_admin_username, p_admin_password) c;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  for r in
    select d.* from public."TenderDeclarationDeposits" d
     where d."Warehouse" = p_warehouse and d."EODID" = p_eod_id
     order by d."DepositDate", d."Id"
  loop
    photo_url := null;
    if coalesce(trim(v_service_role_key), '') <> '' then
      begin
        select * into v_response from extensions.http((
          'POST',
          v_base_url || '/storage/v1/object/sign/' || v_bucket || '/' || r."PhotoPath",
          array[
            extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
            extensions.http_header('apikey', v_service_role_key)
          ],
          'application/json',
          jsonb_build_object('expiresIn', 60 * 60)::text
        )::extensions.http_request);
        if v_response.status between 200 and 299 then
          v_body := v_response.content::jsonb;
          v_signed_path := coalesce(nullif(v_body ->> 'signedURL', ''), nullif(v_body ->> 'signedUrl', ''));
          if v_signed_path is not null then
            photo_url := v_base_url || '/storage/v1' || v_signed_path;
          end if;
        end if;
      exception when others then
        photo_url := null; -- still list the deposit; the page shows "photo unavailable"
      end;
    end if;

    id := r."Id";
    deposit_amount := r."DepositAmount";
    deposit_date := r."DepositDate";
    reference_no := r."ReferenceNo";
    note := r."Note";
    uploaded_by := r."UploadedBy";
    uploaded_at_utc := r."UploadedAtUtc";
    can_delete := v_is_super or r."UploadedBy" = p_admin_username;
    slip_not_read := r."SlipKey" is null;
    duplicate_allowed_by := r."DuplicateAllowedBy";
    return next;
  end loop;
end;
$$;

grant execute on function public.staff_list_tender_deposits(text, text, text, text) to anon;

-- The uploader or a super user can remove a deposit (wrong photo / amount - delete and attach again).
drop function if exists public.staff_delete_tender_deposit(text, text, int);

create or replace function public.staff_delete_tender_deposit(
  p_admin_username text,
  p_admin_password text,
  p_deposit_id int
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'tender-deposit-receipts';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_is_super boolean;
  d public."TenderDeclarationDeposits";
begin
  select * into d from public."TenderDeclarationDeposits" where "Id" = p_deposit_id;
  if not found then
    return;
  end if;

  perform public._tender_decl_check_access(p_admin_username, p_admin_password, d."Warehouse", d."EODID");
  select c.is_super into v_is_super from public._tender_decl_caller(p_admin_username, p_admin_password) c;
  if not v_is_super and d."UploadedBy" <> p_admin_username then
    raise exception 'Only % (who attached it) or a super user can remove this deposit.', d."UploadedBy";
  end if;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
    perform extensions.http((
      'POST',
      v_base_url || '/storage/v1/object/remove/' || v_bucket,
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
        extensions.http_header('apikey', v_service_role_key)
      ],
      'application/json',
      jsonb_build_object('prefixes', jsonb_build_array(d."PhotoPath"))::text
    )::extensions.http_request);
  exception when others then
    null; -- storage-side cleanup is best-effort; still remove the row below
  end;

  delete from public."TenderDeclarationDeposits" where "Id" = p_deposit_id;
  delete from public."TenderDepositSlipReads" where "Id" = d."ReadId";
end;
$$;

grant execute on function public.staff_delete_tender_deposit(text, text, int) to anon;

-- ============================================================================
-- 5. Portal list (moved from supabase_tender_declaration_tables.sql) - Super Users see every store,
--    Store Managers only their own (p_warehouse is ignored for them).
-- p_result: 'short' / 'over' / 'balanced' filter on Variance. p_from / p_to: DeclDate range.
-- p_deposit: 'none' (latest declaration of the day with no deposit), 'mismatch' (deposits <> Declared
-- Cash), 'matched'.
-- Cashiers sometimes declare twice in a day: is_counted marks the LATEST declaration per Warehouse +
-- DeclDate (highest EODID - the POS running number), decided over all rows before the filters apply, and
-- total_declared sums only those - the earlier one of a re-declare is listed but not added in.
-- ============================================================================

drop function if exists public.admin_list_tender_declarations(text, text, text, text, date, date, text, int, int);
drop function if exists public.admin_list_tender_declarations(text, text, text, text, date, date, text, text, int, int);

create or replace function public.admin_list_tender_declarations(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_warehouse text default null,
  p_from date default null,
  p_to date default null,
  p_result text default null,
  p_deposit text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  warehouse text,
  eod_id text,
  receipt_no text,
  user_id text,
  decl_date date,
  decl_time text,
  float_amount numeric,
  cash_sales numeric,
  cash_income numeric,
  cash_expense numeric,
  expected_cash numeric,
  declared_cash numeric,
  variance numeric,
  variance_reason text,
  advance_collections numeric,
  sales_by_tender jsonb,
  from_history_upload boolean,
  synced_at_utc timestamptz,
  deposit_total numeric,
  deposit_count int,
  deposit_unread_count int,
  total_count bigint,
  total_short numeric,
  total_over numeric,
  total_declared numeric,
  total_deposited numeric,
  is_counted boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_warehouse text := nullif(trim(coalesce(p_warehouse, '')), '');
  v_result text := lower(nullif(trim(coalesce(p_result, '')), ''));
  v_deposit text := lower(nullif(trim(coalesce(p_deposit, '')), ''));
  v_is_super boolean;
  v_caller_warehouse text;
begin
  select c.is_super, c.warehouse_name into v_is_super, v_caller_warehouse
    from public._tender_decl_caller(p_admin_username, p_admin_password) c;
  if not v_is_super then
    v_warehouse := v_caller_warehouse;
  end if;

  return query
    with ranked as (
      select d.*,
             row_number() over (partition by d."Warehouse", d."DeclDate"
                                order by d."EODID" desc) = 1 as counted
        from public."TenderDeclarationHeader" d
    ),
    deposits as (
      select p."Warehouse", p."EODID", sum(p."DepositAmount") as amt, count(*)::int as cnt,
             (count(*) filter (where p."SlipKey" is null))::int as unread
        from public."TenderDeclarationDeposits" p
       group by p."Warehouse", p."EODID"
    ),
    joined as (
      select h.*, coalesce(dp.amt, 0) as dep_amt, coalesce(dp.cnt, 0) as dep_cnt, coalesce(dp.unread, 0) as dep_unread
        from ranked h
        left join deposits dp on dp."Warehouse" = h."Warehouse" and dp."EODID" = h."EODID"
    )
    select
      h."Warehouse"::text, h."EODID"::text, h."ReceiptNo"::text, h."UserID"::text, h."DeclDate", h."DeclTime"::text,
      h."FloatAmount", h."CashSales", h."CashIncome", h."CashExpense", h."ExpectedCash", h."DeclaredCash",
      h."Variance", h."VarianceReason"::text, h."AdvanceCollections", h."SalesByTender", h."FromHistoryUpload", h."SyncedAtUtc",
      h.dep_amt, h.dep_cnt, h.dep_unread,
      count(*) over(),
      coalesce(sum(case when h."Variance" < 0 then -h."Variance" else 0 end) over(), 0),
      coalesce(sum(case when h."Variance" > 0 then h."Variance" else 0 end) over(), 0),
      coalesce(sum(h."DeclaredCash") filter (where h.counted) over(), 0),
      coalesce(sum(h.dep_amt) over(), 0),
      h.counted
    from joined h
    where (v_warehouse is null or lower(trim(h."Warehouse")) = lower(v_warehouse))
      and (p_from is null or h."DeclDate" >= p_from)
      and (p_to is null or h."DeclDate" <= p_to)
      and (
        v_result is null
        or (v_result = 'short' and h."Variance" < 0)
        or (v_result = 'over' and h."Variance" > 0)
        or (v_result = 'balanced' and h."Variance" = 0)
      )
      and (
        v_deposit is null
        -- An earlier re-declared count never needs its own deposit (it goes on the latest one).
        or (v_deposit = 'none' and h.dep_cnt = 0 and h.counted)
        or (v_deposit = 'mismatch' and h.dep_cnt > 0 and h.dep_amt <> h."DeclaredCash")
        or (v_deposit = 'matched' and h.dep_cnt > 0 and h.dep_amt = h."DeclaredCash")
      )
      and (
        v_search is null
        or h."EODID" ilike '%' || v_search || '%'
        or h."ReceiptNo" ilike '%' || v_search || '%'
        or h."UserID" ilike '%' || v_search || '%'
        or h."Warehouse" ilike '%' || v_search || '%'
        or h."VarianceReason" ilike '%' || v_search || '%'
      )
    order by h."DeclDate" desc nulls last, h."EODID" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- One declaration's denomination lines (moved from supabase_tender_declaration_tables.sql).
drop function if exists public.admin_list_tender_declaration_lines(text, text, text, text);

create or replace function public.admin_list_tender_declaration_lines(
  p_admin_username text,
  p_admin_password text,
  p_warehouse text,
  p_eod_id text
)
returns table(
  entry_no int,
  line_no int,
  denomination numeric,
  qty int,
  total_amount numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._tender_decl_check_access(p_admin_username, p_admin_password, p_warehouse, p_eod_id);

  return query
    select l."EntryNo", l."LineNo", l."Denomination", l."Qty", l."TotalAmount"
    from public."TenderDeclarationLines" l
    where l."Warehouse" = p_warehouse and l."EODID" = p_eod_id
    order by l."Denomination" desc;
end;
$$;

grant execute on function public.admin_list_tender_declarations(text, text, text, text, date, date, text, text, int, int) to anon;
grant execute on function public.admin_list_tender_declaration_lines(text, text, text, text) to anon;

notify pgrst, 'reload schema';
