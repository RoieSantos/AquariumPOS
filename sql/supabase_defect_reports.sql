-- Defect Items: a store manager reports a broken/defective item WITH A PHOTO, a super user approves
-- or rejects it, and only an approved report takes the stock out of the Item Ledger. Per direct
-- request ("yes build approval and photo added").
--
--   Report   staff_submit_defect_report        Store Manager (own location only) or Super User.
--                                              Status = Pending. A photo is required. No stock moves.
--   Approve  admin_decide_defect_report(true)  Super User only. Posts a Negative Adjmt. to the Item
--                                              Ledger (document type "Defect", document no = the
--                                              report no.), refused if the location doesn't have that
--                                              much on hand. Status = Approved.
--   Reject   admin_decide_defect_report(false) Super User only, with a reason. Status = Rejected.
--   Withdraw staff_withdraw_defect_report      The reporter (or a super user) while still Pending.
--
-- Photos go to the public Storage bucket "defect-photos" through the same signed-upload flow as
-- supabase_online_order_status_photo.sql (needs the Vault secret "supabase_service_role_key", see
-- supabase_configure_service_role_key.sql): the browser never gets direct write access to the bucket.
--
-- Reuses is_phys_journal_authorized() (Super User OR Store Manager, see
-- supabase_phys_journal_store_manager_access.sql) for reporting. Run AFTER that file and
-- supabase_item_ledger_entries.sql / supabase_item_ledger_hooks.sql.

-- ============================================================================
-- 1. Storage bucket, table
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'defect-photos',
  'defect-photos',
  true,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

create sequence if not exists public.defect_report_no_seq;

create table if not exists public."DefectReports" (
    "Id" serial primary key,
    "ReportNo" varchar(30) not null unique,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100),
    "WarehouseId" varchar(100) not null,
    "Quantity" numeric(18, 4) not null check ("Quantity" > 0),
    "Reason" varchar(100) not null,
    "Note" varchar(1000),
    "PhotoPath" varchar(500),
    "PhotoUrl" varchar(1000),
    "Status" varchar(20) not null default 'Pending'
        check ("Status" in ('Pending', 'Approved', 'Rejected', 'Withdrawn')),
    "ReportedBy" varchar(100) not null,
    "ReportedAtUtc" timestamptz not null default now(),
    "DecidedBy" varchar(100),
    "DecidedAtUtc" timestamptz,
    "DecisionNote" varchar(1000),
    -- The Item Ledger transaction an approval posted (null until approved).
    "TransactionNo" bigint
);

create index if not exists "IX_DefectReports_Status" on public."DefectReports" ("Status");
create index if not exists "IX_DefectReports_Warehouse" on public."DefectReports" ("WarehouseId");

alter table public."DefectReports" enable row level security;
revoke all on public."DefectReports" from anon, authenticated;

-- ============================================================================
-- 2. Who is calling
-- ============================================================================

-- Raises unless the caller is a Super User or Store Manager. Returns whether they are a super user
-- and, for a store manager, the warehouse (by name) they are assigned to.
drop function if exists public._defect_caller(text, text);

create or replace function public._defect_caller(p_username text, p_password text)
returns table(is_super boolean, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_phys_journal_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select coalesce(u."SuperUser", false), nullif(trim(coalesce(u."WarehouseName", '')), '')::text
    from public."StaffUsers" u
    where u."Username" = p_username;
end;
$$;

revoke execute on function public._defect_caller(text, text) from public, anon, authenticated;

-- ============================================================================
-- 3. Photo upload (signed, one object path)
-- ============================================================================

drop function if exists public.staff_create_defect_photo_upload(text, text, text);

create or replace function public.staff_create_defect_photo_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'defect-photos';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_safe_name text;
  v_path text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
begin
  perform 1 from public._defect_caller(p_admin_username, p_admin_password);

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  v_safe_name := regexp_replace(coalesce(nullif(trim(p_file_name), ''), 'photo.jpg'), '[^A-Za-z0-9._-]+', '_', 'g');
  v_path := to_char(now() at time zone 'utc', 'YYYYMMDD') || '/' || to_char(now() at time zone 'utc', 'HH24MISSMS') || '_' || v_safe_name;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path;

  select * into v_response from extensions.http((
    'POST',
    v_sign_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
      extensions.http_header('apikey', v_service_role_key)
    ],
    'application/json',
    '{}'
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not prepare photo upload (HTTP %): %', v_response.status, v_response.content;
  end if;

  v_body := v_response.content::jsonb;
  v_token := coalesce(nullif(v_body ->> 'token', ''), nullif(split_part(coalesce(v_body ->> 'url', ''), 'token=', 2), ''));

  if v_token is null or v_token = '' then
    raise exception 'Storage did not return an upload token.';
  end if;

  storage_path := v_path;
  upload_token := v_token;
  public_url := v_base_url || '/storage/v1/object/public/' || v_bucket || '/' || v_path;
  return next;
end;
$$;

grant execute on function public.staff_create_defect_photo_upload(text, text, text) to anon;

-- ============================================================================
-- 4. Report a defect
-- ============================================================================

drop function if exists public.staff_submit_defect_report(text, text, text, text, text, numeric, text, text, text, text);

create or replace function public.staff_submit_defect_report(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_variant_id text,
  p_warehouse_id text,
  p_quantity numeric,
  p_reason text,
  p_note text,
  p_photo_path text,
  p_photo_url text
)
returns table(report_id int, report_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_is_super boolean;
  v_caller_warehouse text;
  v_warehouse_name text;
  v_item text;
  v_variant text;
  v_id int;
  v_no text;
begin
  select c.is_super, c.warehouse_name into v_is_super, v_caller_warehouse
    from public._defect_caller(p_admin_username, p_admin_password) c;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Enter how many are defective.';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'Pick a reason.';
  end if;
  if nullif(trim(coalesce(p_photo_path, '')), '') is null or nullif(trim(coalesce(p_photo_url, '')), '') is null then
    raise exception 'A photo of the defective item is required.';
  end if;

  select w."Name" into v_warehouse_name from public."Warehouses" w where w."ID" = trim(coalesce(p_warehouse_id, ''));
  if not found then
    raise exception 'Location not found.';
  end if;

  -- A store manager reports only against their own location.
  if not v_is_super and lower(trim(coalesce(v_caller_warehouse, ''))) <> lower(trim(v_warehouse_name)) then
    raise exception 'You can only report defects at your own location (%).', coalesce(v_caller_warehouse, 'none assigned');
  end if;

  -- Validates the item, and that a variant is given when the item needs one.
  select k.item_code, k.variant_id into v_item, v_variant
    from public._ile_resolve_stock_key(trim(coalesce(p_item_code, '')), nullif(trim(coalesce(p_variant_id, '')), '')) k;

  v_no := 'DEF-' || lpad(nextval('public.defect_report_no_seq')::text, 6, '0');

  insert into public."DefectReports" (
    "ReportNo", "ItemCode", "VariantId", "WarehouseId", "Quantity", "Reason", "Note",
    "PhotoPath", "PhotoUrl", "ReportedBy"
  )
  values (
    v_no, v_item, v_variant, trim(p_warehouse_id), round(p_quantity, 4), trim(p_reason),
    nullif(trim(coalesce(p_note, '')), ''), trim(p_photo_path), trim(p_photo_url), p_admin_username
  )
  returning "Id" into v_id;

  report_id := v_id;
  report_no := v_no;
  return next;
end;
$$;

grant execute on function public.staff_submit_defect_report(text, text, text, text, text, numeric, text, text, text, text) to anon;

-- ============================================================================
-- 5. List
-- ============================================================================

drop function if exists public.staff_list_defect_reports(text, text, text, text, int, int);

create or replace function public.staff_list_defect_reports(
  p_admin_username text,
  p_admin_password text,
  p_status text default null,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 25
)
returns table(
  id int, report_no text, item_code text, item_name text, variant_id text, variant_name text,
  warehouse_id text, warehouse_name text, quantity numeric, reason text, note text, photo_url text,
  status text, reported_by text, reported_at_utc timestamptz, decided_by text, decided_at_utc timestamptz,
  decision_note text, on_hand numeric, total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_is_super boolean;
  v_caller_warehouse text;
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_size int := least(greatest(coalesce(p_page_size, 25), 1), 100);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  select c.is_super, c.warehouse_name into v_is_super, v_caller_warehouse
    from public._defect_caller(p_admin_username, p_admin_password) c;

  return query
    select
      r."Id", r."ReportNo"::text, r."ItemCode"::text, i."Name"::text, r."VariantId"::text, v."VariantName"::text,
      r."WarehouseId"::text, w."Name"::text, r."Quantity", r."Reason"::text, r."Note"::text, r."PhotoUrl"::text,
      r."Status"::text, r."ReportedBy"::text, r."ReportedAtUtc", r."DecidedBy"::text, r."DecidedAtUtc",
      r."DecisionNote"::text,
      coalesce((select sum(e."Quantity") from public."ItemLedgerEntries" e
                where e."ItemCode" = r."ItemCode" and e."WarehouseId" = r."WarehouseId"), 0),
      count(*) over ()
    from public."DefectReports" r
    left join public."Items" i on i."Code" = r."ItemCode"
    left join public."Variants" v on v."VariationId" = r."VariantId"
    left join public."Warehouses" w on w."ID" = r."WarehouseId"
    where (nullif(trim(coalesce(p_status, '')), '') is null or r."Status" = trim(p_status))
      and (v_is_super or lower(trim(coalesce(w."Name", ''))) = lower(trim(coalesce(v_caller_warehouse, '~none~'))))
      and (v_search is null
           or r."ReportNo" ilike '%' || v_search || '%'
           or r."ItemCode" ilike '%' || v_search || '%'
           or i."Name" ilike '%' || v_search || '%')
    order by (r."Status" = 'Pending') desc, r."Id" desc
    limit v_size offset (v_page - 1) * v_size;
end;
$$;

grant execute on function public.staff_list_defect_reports(text, text, text, text, int, int) to anon;

-- ============================================================================
-- 6. Approve / reject (Super User)
-- ============================================================================

drop function if exists public.admin_decide_defect_report(text, text, int, boolean, text);

create or replace function public.admin_decide_defect_report(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_approve boolean,
  p_decision_note text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_report record;
  v_transaction_no bigint;
  v_note text := nullif(trim(coalesce(p_decision_note, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_report from public."DefectReports" where "Id" = p_id for update;
  if not found then
    raise exception 'Defect report not found.';
  end if;
  if v_report."Status" <> 'Pending' then
    raise exception 'This report is already %.', lower(v_report."Status");
  end if;

  if coalesce(p_approve, false) then
    v_transaction_no := nextval('public.ile_transaction_no_seq');

    -- p_prevent_negative = true: refused if the location doesn't have this many, so approving a
    -- report can't push stock below zero.
    perform public._ile_post(
      'Negative Adjmt.',
      v_report."ItemCode",
      v_report."VariantId",
      v_report."WarehouseId",
      -v_report."Quantity",
      public._ile_today(),
      'Defect',
      v_report."ReportNo",
      left('Defect - ' || v_report."Reason" || coalesce(': ' || v_report."Note", '') || ' (reported by ' || v_report."ReportedBy" || ')', 500),
      v_transaction_no,
      p_admin_username,
      null,
      true
    );

    update public."DefectReports"
       set "Status" = 'Approved', "DecidedBy" = p_admin_username, "DecidedAtUtc" = now(),
           "DecisionNote" = v_note, "TransactionNo" = v_transaction_no
     where "Id" = p_id;
    return 'Approved';
  end if;

  if v_note is null then
    raise exception 'Give a reason for rejecting this report.';
  end if;

  update public."DefectReports"
     set "Status" = 'Rejected', "DecidedBy" = p_admin_username, "DecidedAtUtc" = now(), "DecisionNote" = v_note
   where "Id" = p_id;
  return 'Rejected';
end;
$$;

grant execute on function public.admin_decide_defect_report(text, text, int, boolean, text) to anon;

-- ============================================================================
-- 7. Withdraw (reporter, while Pending)
-- ============================================================================

drop function if exists public.staff_withdraw_defect_report(text, text, int);

create or replace function public.staff_withdraw_defect_report(
  p_admin_username text,
  p_admin_password text,
  p_id int
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_is_super boolean;
  v_report record;
begin
  select c.is_super into v_is_super from public._defect_caller(p_admin_username, p_admin_password) c;

  select * into v_report from public."DefectReports" where "Id" = p_id for update;
  if not found then
    raise exception 'Defect report not found.';
  end if;
  if v_report."Status" <> 'Pending' then
    raise exception 'Only a pending report can be withdrawn.';
  end if;
  if not v_is_super and v_report."ReportedBy" <> p_admin_username then
    raise exception 'You can only withdraw your own report.';
  end if;

  update public."DefectReports"
     set "Status" = 'Withdrawn', "DecidedBy" = p_admin_username, "DecidedAtUtc" = now()
   where "Id" = p_id;
end;
$$;

grant execute on function public.staff_withdraw_defect_report(text, text, int) to anon;

notify pgrst, 'reload schema';

select count(*) as defect_reports from public."DefectReports";
