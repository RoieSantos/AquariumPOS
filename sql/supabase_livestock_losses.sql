-- Livestock Losses - per direct request: "how can the user declare dead fishes? i want to track all
-- the fish / plants that is dying so i can trace my inventory" -> "full livestock".
--
-- Built for daily tank checks, and self-service - per "dont rely on the superuser.. i want them to
-- do it themselves" there is NO approval step:
--   * One report = one location + one loss date + SEVERAL lines (item, qty, cause), so a morning
--     check of five tanks is one report, not five.
--   * Any active staff account with a location can report for its own location (Super Users: any).
--     A photo is optional (one per report).
--   * Submitting POSTS straight away: one Negative Adjmt. per line to the Item Ledger (document type
--     "Livestock Loss", document no = report no., posting date = the loss date), all in one ledger
--     transaction. Status = Posted. The item's unit cost is kept on the line so the loss value
--     doesn't move later.
--   * Not refused when the ledger shows fewer on hand than died - the fish are gone either way, and
--     staff can't fix counts themselves. The on-hand before posting is kept on the line and the
--     page flags it, so the count gap is visible (the ledger shows the negative in red).
--   * A mistake is undone with Reverse (staff_reverse_livestock_loss): posts the matching Positive
--     Adjmt. entries (ReversesEntryNo set, document type "Livestock Loss Reversal"), status =
--     Reversed, with a reason. The reporter, or a Store Manager of that location, can reverse within
--     3 days; a Super User any time.
--   * Only items in a category ticked "Livestock" (new Category Setup flag, seeded below) can be
--     reported here. Everything else still goes through Defect Items.
--   * staff_livestock_loss_summary: posted (not reversed) losses by item / category / supplier / location /
--     cause for a date range, with the quantity received in the same period (Purchase receipts, plus
--     Transfer receipts when looking at one location or grouping by location) and loss %. Loss
--     value (cost) is returned to Super Users only.
--
-- Run AFTER supabase_item_ledger_entries.sql, supabase_category_skip_transfer_stock_check.sql (this
-- file replaces its two Category Setup RPCs with versions that also carry IsLivestock) and
-- supabase_staff_session_tokens.sql. Safe to re-run.

-- ============================================================================
-- 1. Category flag
-- ============================================================================

alter table public."Categories" add column if not exists "IsLivestock" boolean not null default false;

-- Seed: the live-animal and plant categories in use today. Untick/tick more in Category Setup.
update public."Categories"
   set "IsLivestock" = true
 where "Code" in ('FISH', 'PLANTS', 'TETRA', 'CICHLIDS', 'AVAILABLE FISH', 'FEEDERS')
   and not "IsLivestock";

drop function if exists public.admin_list_categories(text, text);

create or replace function public.admin_list_categories(p_admin_username text, p_admin_password text)
returns table(
  code text, description text, is_production_category boolean, exclude_in_transfer_orders boolean,
  is_wholesale_applicable boolean, include_in_stock_sync boolean, skip_transfer_stock_check boolean,
  is_livestock boolean, item_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."CategoryCode"::text, c."Description"::text, coalesce(c."IsProductionCategory", false),
           coalesce(c."ExcludeInTransferOrders", false),
           coalesce(c."IsWholesaleApplicable", false), coalesce(c."IncludeInStockSync", false),
           coalesce(c."SkipTransferStockCheck", false), coalesce(c."IsLivestock", false), count(*)
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where i."CategoryCode" is not null and trim(i."CategoryCode") <> ''
    group by i."CategoryCode", c."Description", c."IsProductionCategory", c."ExcludeInTransferOrders",
             c."IsWholesaleApplicable", c."IncludeInStockSync", c."SkipTransferStockCheck", c."IsLivestock"
    order by i."CategoryCode";
end;
$$;

drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean, boolean);
drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean, boolean, boolean);

create or replace function public.admin_update_category_flags(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_description text,
  p_is_production_category boolean,
  p_exclude_in_transfer_orders boolean,
  p_is_wholesale_applicable boolean,
  p_include_in_stock_sync boolean,
  p_skip_transfer_stock_check boolean,
  p_is_livestock boolean default null
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

  insert into public."Categories" (
    "Code", "Description", "IsProductionCategory", "ExcludeInTransferOrders", "IsWholesaleApplicable",
    "IncludeInStockSync", "SkipTransferStockCheck", "IsLivestock"
  )
  values (
    p_code, nullif(trim(p_description), ''), coalesce(p_is_production_category, false),
    coalesce(p_exclude_in_transfer_orders, false), coalesce(p_is_wholesale_applicable, false),
    coalesce(p_include_in_stock_sync, false), coalesce(p_skip_transfer_stock_check, false),
    coalesce(p_is_livestock, false)
  )
  on conflict ("Code") do update
    set "Description" = excluded."Description",
        "IsProductionCategory" = excluded."IsProductionCategory",
        "ExcludeInTransferOrders" = excluded."ExcludeInTransferOrders",
        "IsWholesaleApplicable" = excluded."IsWholesaleApplicable",
        "IncludeInStockSync" = excluded."IncludeInStockSync",
        "SkipTransferStockCheck" = excluded."SkipTransferStockCheck",
        -- An older page that doesn't send the flag leaves it alone.
        "IsLivestock" = coalesce(p_is_livestock, public."Categories"."IsLivestock");
end;
$$;

grant execute on function public.admin_list_categories(text, text) to anon;
grant execute on function public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean, boolean, boolean, boolean) to anon;

create or replace function public._item_is_livestock(p_item_code text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((
    select c."IsLivestock"
    from public."Items" i
    join public."Categories" c on c."Code" = i."CategoryCode"
    where i."Code" = p_item_code
  ), false);
$$;

revoke execute on function public._item_is_livestock(text) from public, anon, authenticated;

-- ============================================================================
-- 2. Storage bucket, tables
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('livestock-loss-photos', 'livestock-loss-photos', true, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create sequence if not exists public.livestock_loss_no_seq;

create table if not exists public."LivestockLossReports" (
    "Id" serial primary key,
    "ReportNo" varchar(30) not null unique,
    "WarehouseId" varchar(100) not null,
    "LossDate" date not null,
    "Note" varchar(1000),
    "PhotoPath" varchar(500),
    "PhotoUrl" varchar(1000),
    "Status" varchar(20) not null default 'Posted',
    "ReportedBy" varchar(100) not null,
    "ReportedAtUtc" timestamptz not null default now(),
    -- The Item Ledger transaction the report posted.
    "TransactionNo" bigint,
    "ReversedBy" varchar(100),
    "ReversedAtUtc" timestamptz,
    "ReverseReason" varchar(1000),
    "ReverseTransactionNo" bigint
);

-- First version (same day, no rows yet) had an approval step: Pending/Approved/Rejected/Withdrawn
-- and Decided* columns. Bring an existing table to the self-service shape.
alter table public."LivestockLossReports" drop constraint if exists "LivestockLossReports_Status_check";
alter table public."LivestockLossReports" alter column "Status" set default 'Posted';
alter table public."LivestockLossReports" add column if not exists "ReversedBy" varchar(100);
alter table public."LivestockLossReports" add column if not exists "ReversedAtUtc" timestamptz;
alter table public."LivestockLossReports" add column if not exists "ReverseReason" varchar(1000);
alter table public."LivestockLossReports" add column if not exists "ReverseTransactionNo" bigint;
alter table public."LivestockLossReports" drop column if exists "DecidedBy";
alter table public."LivestockLossReports" drop column if exists "DecidedAtUtc";
alter table public."LivestockLossReports" drop column if exists "DecisionNote";
alter table public."LivestockLossReports" add constraint "LivestockLossReports_Status_check"
    check ("Status" in ('Posted', 'Reversed'));

create table if not exists public."LivestockLossLines" (
    "Id" serial primary key,
    "ReportId" int not null references public."LivestockLossReports" ("Id") on delete cascade,
    "LineNo" int not null,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100),
    "Quantity" numeric(18, 4) not null check ("Quantity" > 0),
    "Cause" varchar(100) not null,
    "Note" varchar(500),
    -- Items.Cost when the report was posted.
    "UnitCost" numeric(18, 4),
    -- Ledger on hand at the location just before this line posted; less than Quantity = count gap.
    "OnHandBefore" numeric(18, 4),
    unique ("ReportId", "LineNo")
);

alter table public."LivestockLossLines" add column if not exists "OnHandBefore" numeric(18, 4);

create index if not exists "IX_LivestockLossReports_Status" on public."LivestockLossReports" ("Status");
create index if not exists "IX_LivestockLossReports_Warehouse_Date" on public."LivestockLossReports" ("WarehouseId", "LossDate");
create index if not exists "IX_LivestockLossLines_Report" on public."LivestockLossLines" ("ReportId");
create index if not exists "IX_LivestockLossLines_Item" on public."LivestockLossLines" ("ItemCode");

alter table public."LivestockLossReports" enable row level security;
alter table public."LivestockLossLines" enable row level security;
revoke all on public."LivestockLossReports" from anon, authenticated;
revoke all on public."LivestockLossLines" from anon, authenticated;

-- ============================================================================
-- 3. Who is calling
-- ============================================================================

-- Any active staff account. Returns whether it is a super user / store manager and its location name.
drop function if exists public._livestock_caller(text, text);

create or replace function public._livestock_caller(p_username text, p_password text)
returns table(is_super boolean, is_store_manager boolean, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  -- "available to staff.. except makers" - Tank / Stand Makers / Dispatchers with no other access.
  if public._is_order_maker_only(p_username) then
    raise exception 'Livestock Losses is not available to maker accounts.';
  end if;
  -- "dont include delivery team / and makers".
  if exists (select 1 from public."StaffUsers" u where u."Username" = p_username
              and coalesce(u."DeliveryTeam", false) and not coalesce(u."SuperUser", false)) then
    raise exception 'Livestock Losses is not available to Delivery Team accounts.';
  end if;
  -- "dont allow users without branch".
  if exists (select 1 from public."StaffUsers" u where u."Username" = p_username
              and nullif(trim(coalesce(u."WarehouseName", '')), '') is null and not coalesce(u."SuperUser", false)) then
    raise exception 'Your account has no branch set - ask a Super User to set one in User Setup.';
  end if;

  return query
    select coalesce(u."SuperUser", false), coalesce(u."StoreManager", false),
           nullif(trim(coalesce(u."WarehouseName", '')), '')::text
    from public."StaffUsers" u
    where u."Username" = p_username;
end;
$$;

revoke execute on function public._livestock_caller(text, text) from public, anon, authenticated;

-- ============================================================================
-- 4. Photo upload (signed, optional)
-- ============================================================================

drop function if exists public.staff_create_livestock_loss_photo_upload(text, text, text);

create or replace function public.staff_create_livestock_loss_photo_upload(
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
  v_bucket text := 'livestock-loss-photos';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_safe_name text;
  v_path text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
begin
  perform 1 from public._livestock_caller(p_admin_username, p_admin_password);

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

  select * into v_response from extensions.http((
    'POST',
    v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path,
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

grant execute on function public.staff_create_livestock_loss_photo_upload(text, text, text) to anon;

-- ============================================================================
-- 5. Livestock item search (with on-hand at the chosen location)
-- ============================================================================

drop function if exists public.staff_search_livestock_items(text, text, text, text, int);

create or replace function public.staff_search_livestock_items(
  p_admin_username text,
  p_admin_password text,
  p_search text,
  p_warehouse_id text default null,
  p_limit int default 15
)
returns table(code text, name text, category_code text, on_hand numeric)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  perform 1 from public._livestock_caller(p_admin_username, p_admin_password);

  return query
    select i."Code"::text, i."Name"::text, i."CategoryCode"::text,
           coalesce((select sum(e."Quantity") from public."ItemLedgerEntries" e
                     where e."ItemCode" = i."Code" and e."WarehouseId" = trim(coalesce(p_warehouse_id, ''))), 0)
    from public."Items" i
    join public."Categories" c on c."Code" = i."CategoryCode" and c."IsLivestock"
    where coalesce(i."IsActive", true)
      and (v_search is null or i."Code" ilike '%' || v_search || '%' or i."Name" ilike '%' || v_search || '%')
    order by i."Name"
    limit least(greatest(coalesce(p_limit, 15), 1), 50);
end;
$$;

grant execute on function public.staff_search_livestock_items(text, text, text, text, int) to anon;

-- ============================================================================
-- 6. Report a loss
-- ============================================================================
-- p_lines: [{ "item_code": "...", "variant_id": "..." | null, "quantity": 2, "cause": "...", "note": "..." }]

drop function if exists public.staff_submit_livestock_loss(text, text, text, date, text, text, text, jsonb);

create or replace function public.staff_submit_livestock_loss(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_loss_date date,
  p_note text,
  p_photo_path text,
  p_photo_url text,
  p_lines jsonb
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
  v_date date := coalesce(p_loss_date, public._ile_today());
  v_line jsonb;
  v_line_no int := 0;
  v_item text;
  v_variant text;
  v_qty numeric;
  v_cause text;
  v_note text;
  v_on_hand numeric;
  v_transaction_no bigint := nextval('public.ile_transaction_no_seq');
  v_id int;
  v_no text;
begin
  select c.is_super, c.warehouse_name into v_is_super, v_caller_warehouse
    from public._livestock_caller(p_admin_username, p_admin_password) c;

  select w."Name" into v_warehouse_name from public."Warehouses" w where w."ID" = trim(coalesce(p_warehouse_id, ''));
  if not found then
    raise exception 'Location not found.';
  end if;

  if not v_is_super and lower(trim(coalesce(v_caller_warehouse, ''))) <> lower(trim(v_warehouse_name)) then
    raise exception 'You can only report losses at your own location (%).', coalesce(v_caller_warehouse, 'none assigned');
  end if;

  if v_date > public._ile_today() then
    raise exception 'The loss date cannot be in the future.';
  end if;
  if v_date < public._ile_today() - 14 then
    raise exception 'The loss date can be at most 14 days ago.';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one item.';
  end if;
  if jsonb_array_length(p_lines) > 100 then
    raise exception 'At most 100 lines per report.';
  end if;

  v_no := 'LL-' || lpad(nextval('public.livestock_loss_no_seq')::text, 6, '0');

  insert into public."LivestockLossReports" ("ReportNo", "WarehouseId", "LossDate", "Note", "PhotoPath", "PhotoUrl", "ReportedBy", "Status", "TransactionNo")
  values (
    v_no, trim(p_warehouse_id), v_date, nullif(trim(coalesce(p_note, '')), ''),
    nullif(trim(coalesce(p_photo_path, '')), ''), nullif(trim(coalesce(p_photo_url, '')), ''), p_admin_username,
    'Posted', v_transaction_no
  )
  returning "Id" into v_id;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_line_no := v_line_no + 1;
    v_qty := nullif(trim(coalesce(v_line ->> 'quantity', '')), '')::numeric;
    v_cause := nullif(trim(coalesce(v_line ->> 'cause', '')), '');

    if v_qty is null or v_qty <= 0 then
      raise exception 'Line %: enter how many died.', v_line_no;
    end if;
    -- No approver any more, so a fat-finger (300 for 3) is caught here.
    if v_qty > 500 then
      raise exception 'Line %: % is more than 500 - check the quantity.', v_line_no, v_qty;
    end if;
    if v_cause is null then
      raise exception 'Line %: pick a cause.', v_line_no;
    end if;

    select k.item_code, k.variant_id into v_item, v_variant
      from public._ile_resolve_stock_key(trim(coalesce(v_line ->> 'item_code', '')), nullif(trim(coalesce(v_line ->> 'variant_id', '')), '')) k;

    if not public._item_is_livestock(v_item) then
      raise exception 'Line %: % is not in a Livestock category - use Defect Items for it.', v_line_no, v_item;
    end if;

    v_qty := round(v_qty, 4);
    v_note := nullif(left(trim(coalesce(v_line ->> 'note', '')), 500), '');
    v_on_hand := public._ile_balance(v_item, v_variant, trim(p_warehouse_id));

    insert into public."LivestockLossLines" ("ReportId", "LineNo", "ItemCode", "VariantId", "Quantity", "Cause", "Note", "UnitCost", "OnHandBefore")
    values (
      v_id, v_line_no, v_item, v_variant, v_qty, left(v_cause, 100), v_note,
      (select i."Cost" from public."Items" i where i."Code" = v_item), v_on_hand
    );

    -- Not refused below zero (p_prevent_negative = false): the fish are gone either way.
    perform public._ile_post(
      'Negative Adjmt.', v_item, v_variant, trim(p_warehouse_id), -v_qty, v_date,
      'Livestock Loss', v_no,
      left('Livestock loss - ' || left(v_cause, 100) || coalesce(': ' || v_note, '') || ' (reported by ' || p_admin_username || ')', 500),
      v_transaction_no, p_admin_username, null, false
    );
  end loop;

  report_id := v_id;
  report_no := v_no;
  return next;
end;
$$;

grant execute on function public.staff_submit_livestock_loss(text, text, text, date, text, text, text, jsonb) to anon;

-- ============================================================================
-- 7. List
-- ============================================================================
-- Super Users see every location; everyone else sees their own location's reports.
-- can_reverse: what staff_reverse_livestock_loss would allow this caller (the button's visibility).

drop function if exists public.staff_list_livestock_losses(text, text, text, text, int, int);

create or replace function public.staff_list_livestock_losses(
  p_admin_username text,
  p_admin_password text,
  p_status text default null,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 25
)
returns table(
  id int, report_no text, warehouse_id text, warehouse_name text, loss_date date, note text, photo_url text,
  status text, reported_by text, reported_at_utc timestamptz, reversed_by text, reversed_at_utc timestamptz,
  reverse_reason text, total_qty numeric, lines jsonb, can_reverse boolean, total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_is_super boolean;
  v_is_manager boolean;
  v_caller_warehouse text;
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_size int := least(greatest(coalesce(p_page_size, 25), 1), 100);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  select c.is_super, c.is_store_manager, c.warehouse_name into v_is_super, v_is_manager, v_caller_warehouse
    from public._livestock_caller(p_admin_username, p_admin_password) c;

  return query
    select
      r."Id", r."ReportNo"::text, r."WarehouseId"::text, w."Name"::text, r."LossDate", r."Note"::text, r."PhotoUrl"::text,
      r."Status"::text, r."ReportedBy"::text, r."ReportedAtUtc", r."ReversedBy"::text, r."ReversedAtUtc", r."ReverseReason"::text,
      (select coalesce(sum(l."Quantity"), 0) from public."LivestockLossLines" l where l."ReportId" = r."Id"),
      (select coalesce(jsonb_agg(jsonb_build_object(
                'line_no', l."LineNo", 'item_code', l."ItemCode", 'item_name', i."Name",
                'variant_id', l."VariantId", 'variant_name', v."VariantName",
                'quantity', l."Quantity", 'cause', l."Cause", 'note', l."Note",
                'unit_cost', case when v_is_super then l."UnitCost" end,
                'on_hand_before', l."OnHandBefore"
              ) order by l."LineNo"), '[]'::jsonb)
         from public."LivestockLossLines" l
         left join public."Items" i on i."Code" = l."ItemCode"
         left join public."Variants" v on v."VariationId" = l."VariantId"
        where l."ReportId" = r."Id"),
      (r."Status" = 'Posted' and (v_is_super
        or ((r."ReportedBy" = p_admin_username or v_is_manager) and r."ReportedAtUtc" > now() - interval '3 days'))),
      count(*) over ()
    from public."LivestockLossReports" r
    left join public."Warehouses" w on w."ID" = r."WarehouseId"
    where (nullif(trim(coalesce(p_status, '')), '') is null or r."Status" = trim(p_status))
      and (v_is_super or lower(trim(coalesce(w."Name", ''))) = lower(trim(coalesce(v_caller_warehouse, '~none~'))))
      and (v_search is null
           or r."ReportNo" ilike '%' || v_search || '%'
           or exists (select 1 from public."LivestockLossLines" l
                      left join public."Items" i on i."Code" = l."ItemCode"
                      where l."ReportId" = r."Id"
                        and (l."ItemCode" ilike '%' || v_search || '%' or i."Name" ilike '%' || v_search || '%')))
    order by r."LossDate" desc, r."Id" desc
    limit v_size offset (v_page - 1) * v_size;
end;
$$;

grant execute on function public.staff_list_livestock_losses(text, text, text, text, int, int) to anon;

-- ============================================================================
-- 8. Reverse (undo a mistaken report)
-- ============================================================================
-- The approval-era functions are gone.
drop function if exists public.admin_decide_livestock_loss(text, text, int, boolean, text);
drop function if exists public.staff_withdraw_livestock_loss(text, text, int);
drop function if exists public.staff_reverse_livestock_loss(text, text, int, text);

create or replace function public.staff_reverse_livestock_loss(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_is_super boolean;
  v_is_manager boolean;
  v_caller_warehouse text;
  v_report record;
  v_warehouse_name text;
  v_entry record;
  v_transaction_no bigint;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select c.is_super, c.is_store_manager, c.warehouse_name into v_is_super, v_is_manager, v_caller_warehouse
    from public._livestock_caller(p_admin_username, p_admin_password) c;

  if v_reason is null then
    raise exception 'Give a reason for reversing this report.';
  end if;

  select * into v_report from public."LivestockLossReports" where "Id" = p_id for update;
  if not found then
    raise exception 'Livestock loss report not found.';
  end if;
  if v_report."Status" <> 'Posted' then
    raise exception 'This report is already reversed.';
  end if;

  if not v_is_super then
    select w."Name" into v_warehouse_name from public."Warehouses" w where w."ID" = v_report."WarehouseId";
    if lower(trim(coalesce(v_warehouse_name, ''))) <> lower(trim(coalesce(v_caller_warehouse, '~none~'))) then
      raise exception 'You can only reverse reports at your own location.';
    end if;
    if v_report."ReportedBy" <> p_admin_username and not v_is_manager then
      raise exception 'Only the person who reported it, a Store Manager or a Super User can reverse it.';
    end if;
    if v_report."ReportedAtUtc" <= now() - interval '3 days' then
      raise exception 'Reports older than 3 days can only be reversed by a Super User.';
    end if;
  end if;

  v_transaction_no := nextval('public.ile_transaction_no_seq');

  -- Mirror each original entry back in; ReversesEntryNo's unique index stops a double reversal.
  for v_entry in
    select e.* from public."ItemLedgerEntries" e
    where e."TransactionNo" = v_report."TransactionNo"
      and e."DocumentType" = 'Livestock Loss'
      and e."DocumentNo" = v_report."ReportNo"
    order by e."EntryNo"
  loop
    perform public._ile_post(
      'Positive Adjmt.', v_entry."ItemCode", v_entry."VariantId", v_entry."WarehouseId", -v_entry."Quantity",
      public._ile_today(), 'Livestock Loss Reversal', v_report."ReportNo",
      left('Reversed livestock loss - ' || v_reason || ' (by ' || p_admin_username || ')', 500),
      v_transaction_no, p_admin_username, v_entry."EntryNo", false
    );
  end loop;

  update public."LivestockLossReports"
     set "Status" = 'Reversed', "ReversedBy" = p_admin_username, "ReversedAtUtc" = now(),
         "ReverseReason" = v_reason, "ReverseTransactionNo" = v_transaction_no
   where "Id" = p_id;
end;
$$;

grant execute on function public.staff_reverse_livestock_loss(text, text, int, text) to anon;

-- ============================================================================
-- 9. Loss summary (Super User: all locations + value; Store Manager: own location, no value)
-- ============================================================================
-- p_group_by: 'item' | 'category' | 'vendor' | 'warehouse' | 'cause'
-- received_qty: livestock received in the same period - Purchase entries, plus positive Transfer
-- entries when the view is one location (p_warehouse_id set, or grouped by location). Company-wide
-- views leave transfers out, since a transfer only moves stock between our own stores. Null when
-- grouping by cause. loss_pct = dead / received, a rough indicator (a fish that died this week may
-- have been received last month).

drop function if exists public.staff_livestock_loss_summary(text, text, date, date, text, text);

create or replace function public.staff_livestock_loss_summary(
  p_admin_username text,
  p_admin_password text,
  p_from date,
  p_to date,
  p_group_by text default 'item',
  p_warehouse_id text default null
)
returns table(group_key text, group_label text, reports bigint, dead_qty numeric, loss_value numeric, received_qty numeric, loss_pct numeric)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_is_super boolean;
  v_is_manager boolean;
  v_caller_warehouse text;
  v_warehouse text := nullif(trim(coalesce(p_warehouse_id, '')), '');
  v_group text := lower(coalesce(nullif(trim(p_group_by), ''), 'item'));
  v_from date := coalesce(p_from, public._ile_today() - 30);
  v_to date := coalesce(p_to, public._ile_today());
begin
  select c.is_super, c.is_store_manager, c.warehouse_name into v_is_super, v_is_manager, v_caller_warehouse
    from public._livestock_caller(p_admin_username, p_admin_password) c;

  if not v_is_super and not v_is_manager then
    raise exception 'Only Super Users and Store Managers can view the loss summary.';
  end if;

  -- A store manager is pinned to their own location.
  if not v_is_super then
    select w."ID" into v_warehouse from public."Warehouses" w
     where lower(trim(w."Name")) = lower(trim(coalesce(v_caller_warehouse, '~none~')));
    if v_warehouse is null then
      raise exception 'No location is assigned to your account.';
    end if;
    if v_group = 'warehouse' then
      v_group := 'item';
    end if;
  end if;

  if v_group not in ('item', 'category', 'vendor', 'warehouse', 'cause') then
    raise exception 'Unknown grouping "%".', p_group_by;
  end if;

  return query
    with losses as (
      select
        case v_group
          when 'item' then l."ItemCode"
          when 'category' then coalesce(i."CategoryCode", '(none)')
          when 'vendor' then coalesce(nullif(i."VendorCode", ''), '(none)')
          when 'warehouse' then r."WarehouseId"
          else l."Cause"
        end::text as k,
        r."Id" as report_id,
        l."Quantity" as qty,
        l."Quantity" * coalesce(l."UnitCost", 0) as value
      from public."LivestockLossLines" l
      join public."LivestockLossReports" r on r."Id" = l."ReportId"
      left join public."Items" i on i."Code" = l."ItemCode"
      where r."Status" = 'Posted'
        and r."LossDate" between v_from and v_to
        and (v_warehouse is null or r."WarehouseId" = v_warehouse)
    ),
    loss_agg as (
      select k, count(distinct report_id) as n, sum(qty) as qty, sum(value) as value from losses group by k
    ),
    received as (
      select
        case v_group
          when 'item' then e."ItemCode"
          when 'category' then coalesce(i."CategoryCode", '(none)')
          when 'vendor' then coalesce(nullif(i."VendorCode", ''), '(none)')
          else e."WarehouseId"
        end::text as k,
        sum(e."Quantity") as qty
      from public."ItemLedgerEntries" e
      join public."Items" i on i."Code" = e."ItemCode"
      join public."Categories" c on c."Code" = i."CategoryCode" and c."IsLivestock"
      where v_group <> 'cause'
        and e."PostingDate" between v_from and v_to
        and (v_warehouse is null or e."WarehouseId" = v_warehouse)
        and (e."EntryType" = 'Purchase'
             or (e."EntryType" = 'Transfer' and e."Quantity" > 0 and (v_warehouse is not null or v_group = 'warehouse')))
      group by 1
    )
    select
      a.k,
      case v_group
        when 'item' then (select it."Name" from public."Items" it where it."Code" = a.k)
        when 'category' then (select ct."Description" from public."Categories" ct where ct."Code" = a.k)
        when 'vendor' then (select vd."Name" from public."Vendors" vd where vd."VendorCode" = a.k)
        when 'warehouse' then (select wh."Name" from public."Warehouses" wh where wh."ID" = a.k)
        else a.k
      end::text,
      a.n,
      a.qty,
      case when v_is_super then round(a.value, 2) end,
      case when v_group = 'cause' then null else coalesce(rc.qty, 0) end,
      case when v_group <> 'cause' and coalesce(rc.qty, 0) > 0 then round(a.qty * 100.0 / rc.qty, 1) end
    from loss_agg a
    left join received rc on rc.k = a.k
    order by a.qty desc, a.k;
end;
$$;

grant execute on function public.staff_livestock_loss_summary(text, text, date, date, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification: livestock categories, and every function with anon execute.
select 'livestock category' as section, "Code"::text as name, null::boolean as has_anon_execute
from public."Categories" where "IsLivestock"
union all
select 'function', p.proname::text, has_function_privilege('anon', p.oid, 'EXECUTE')
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_list_categories', 'admin_update_category_flags', 'staff_create_livestock_loss_photo_upload',
                    'staff_search_livestock_items', 'staff_submit_livestock_loss', 'staff_list_livestock_losses',
                    'staff_reverse_livestock_loss', 'staff_livestock_loss_summary')
order by 1, 2;
