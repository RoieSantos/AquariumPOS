-- Vendor Master (Web Portal, super users only) - per "is it possible to create me a vendor
-- table master? this will allow me to pay them / tag the item and etc". Nothing like this exists
-- anywhere else in the codebase - Items only has a free-text "Brand" field, no structured
-- supplier concept, no accounts-payable tracking of any kind.
--
-- Three pieces:
--   1. public."Vendors" - the master list (Code/Name/contact info), soft-deactivated via
--      IsActive rather than hard-deleted (same convention as public."StaffUsers").
--   2. public."Items"."VendorCode" - tags each item to exactly ONE vendor (per explicit
--      request - not a many-to-many join table), same unenforced-by-FK convention already used
--      for Items."CategoryCode" (supabase_warehouses_items_tables.sql has no `references`
--      anywhere in that table's definition).
--   3. public."VendorBills"/"VendorPayments" - full accounts payable: a Bill records what's
--      owed, a Payment records what's been paid, optionally applied against a specific bill.
--      Both are soft-voided via IsVoid (never hard-deleted) so the ledger stays auditable - a
--      voided payment simply stops counting toward its bill's paid amount, and a bill can only
--      be voided while it still has zero non-void payments applied (enforced in
--      admin_void_vendor_bill below), so a bill's history can't be erased out from under real
--      money already recorded against it.
--
-- Numbering for Bill No./Payment No. reuses the existing generic "No. Series" running-number
-- system (supabase_no_series_tables.sql, already used for Transfer Order Document No.) instead
-- of inventing a new scheme - see the two NoSeries rows seeded below and
-- public._next_no_series_number(), called directly from admin_create_vendor_bill/
-- admin_create_vendor_payment.
--
-- Run supabase_no_series_tables.sql BEFORE this file (it already exists in the repo).

create table if not exists public."Vendors" (
    "VendorCode" varchar(50) primary key,
    "Name" varchar(255) not null,
    "ContactPerson" varchar(200),
    "Phone" varchar(50),
    "Email" varchar(200),
    "Address" varchar(500),
    "PaymentTerms" varchar(200),
    "Notes" varchar(1000),
    "IsActive" boolean not null default true,
    "CreatedAtUtc" timestamptz not null default now(),
    "UpdatedAtUtc" timestamptz
);

alter table public."Vendors" enable row level security;
revoke all on public."Vendors" from anon, authenticated;

-- No FK constraint to public."Vendors" - matches the existing unenforced convention for
-- Items."CategoryCode" in this codebase. Nullable so an item can go untagged.
alter table public."Items" add column if not exists "VendorCode" varchar(50);

create table if not exists public."VendorBills" (
    "BillNo" varchar(50) primary key,
    "VendorCode" varchar(50) not null,
    "BillDate" date not null,
    "DueDate" date,
    "ReferenceNo" varchar(200),
    "Amount" numeric(18, 2) not null,
    "Notes" varchar(1000),
    "IsVoid" boolean not null default false,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now()
);

alter table public."VendorBills" enable row level security;
revoke all on public."VendorBills" from anon, authenticated;
create index if not exists "IX_VendorBills_VendorCode" on public."VendorBills" ("VendorCode");

create table if not exists public."VendorPayments" (
    "PaymentNo" varchar(50) primary key,
    "VendorCode" varchar(50) not null,
    "BillNo" varchar(50),
    "PaymentDate" date not null,
    "Amount" numeric(18, 2) not null,
    "Method" varchar(50),
    "ReferenceNo" varchar(200),
    "Notes" varchar(1000),
    "IsVoid" boolean not null default false,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now()
);

alter table public."VendorPayments" enable row level security;
revoke all on public."VendorPayments" from anon, authenticated;
create index if not exists "IX_VendorPayments_VendorCode" on public."VendorPayments" ("VendorCode");
create index if not exists "IX_VendorPayments_BillNo" on public."VendorPayments" ("BillNo");

-- Seed the two numbering series, same idempotent "insert ... where not exists" idiom already
-- used for 'TRANSFER-ORDER' in supabase_no_series_tables.sql. Neither is warehouse-scoped -
-- vendor bills/payments aren't tied to a warehouse.
insert into public."NoSeries" ("SeriesCode", "Description", "Prefix", "Padding", "StartingNo", "WarehouseScoped")
select 'VENDOR-BILL', 'Vendor Bill No.', 'VB-', 6, 1, false
where not exists (select 1 from public."NoSeries" where "SeriesCode" = 'VENDOR-BILL');

insert into public."NoSeries" ("SeriesCode", "Description", "Prefix", "Padding", "StartingNo", "WarehouseScoped")
select 'VENDOR-PAYMENT', 'Vendor Payment No.', 'VP-', 6, 1, false
where not exists (select 1 from public."NoSeries" where "SeriesCode" = 'VENDOR-PAYMENT');

-- ============================================================================
-- Vendor CRUD (super users only, is_admin_authorized - same gate as every other Setup page:
-- Category/Warehouse/Item/Variant/User Setup).

drop function if exists public.admin_list_vendors(text, text, text, int, int);

-- total_billed/total_paid/balance are computed from non-void VendorBills/VendorPayments -
-- this is what lets the Vendor Setup list show each vendor's outstanding balance without a
-- separate call per row.
create or replace function public.admin_list_vendors(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  vendor_code text,
  name text,
  contact_person text,
  phone text,
  email text,
  address text,
  payment_terms text,
  notes text,
  is_active boolean,
  total_billed numeric,
  total_paid numeric,
  balance numeric,
  created_at_utc timestamptz,
  updated_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 500);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      v."VendorCode"::text, v."Name"::text, v."ContactPerson"::text, v."Phone"::text, v."Email"::text,
      v."Address"::text, v."PaymentTerms"::text, v."Notes"::text, v."IsActive",
      coalesce(b.total_billed, 0)::numeric,
      coalesce(p.total_paid, 0)::numeric,
      (coalesce(b.total_billed, 0) - coalesce(p.total_paid, 0))::numeric,
      v."CreatedAtUtc", v."UpdatedAtUtc",
      count(*) over()
    from public."Vendors" v
    left join (
      select "VendorCode", sum("Amount") as total_billed
      from public."VendorBills" where not "IsVoid" group by "VendorCode"
    ) b on b."VendorCode" = v."VendorCode"
    left join (
      select "VendorCode", sum("Amount") as total_paid
      from public."VendorPayments" where not "IsVoid" group by "VendorCode"
    ) p on p."VendorCode" = v."VendorCode"
    where p_search is null or trim(p_search) = ''
      or v."VendorCode" ilike '%' || p_search || '%'
      or v."Name" ilike '%' || p_search || '%'
      or v."ContactPerson" ilike '%' || p_search || '%'
    order by v."Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_create_vendor(text, text, text, text, text, text, text, text, text, text);

create or replace function public.admin_create_vendor(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_name text,
  p_contact_person text default null,
  p_phone text default null,
  p_email text default null,
  p_address text default null,
  p_payment_terms text default null,
  p_notes text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text; return;
  end if;

  if p_vendor_code is null or trim(p_vendor_code) = '' then
    return query select false, 'Vendor Code is required.'::text; return;
  end if;

  if p_name is null or trim(p_name) = '' then
    return query select false, 'Vendor Name is required.'::text; return;
  end if;

  if exists (select 1 from public."Vendors" where "VendorCode" = upper(trim(p_vendor_code))) then
    return query select false, 'That Vendor Code already exists.'::text; return;
  end if;

  insert into public."Vendors" ("VendorCode", "Name", "ContactPerson", "Phone", "Email", "Address", "PaymentTerms", "Notes")
  values (upper(trim(p_vendor_code)), trim(p_name), nullif(trim(p_contact_person), ''), nullif(trim(p_phone), ''),
          nullif(trim(p_email), ''), nullif(trim(p_address), ''), nullif(trim(p_payment_terms), ''), nullif(trim(p_notes), ''));

  return query select true, 'Vendor created.'::text;
end;
$$;

drop function if exists public.admin_update_vendor(text, text, text, text, text, text, text, text, text, text, boolean);

create or replace function public.admin_update_vendor(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_name text,
  p_contact_person text,
  p_phone text,
  p_email text,
  p_address text,
  p_payment_terms text,
  p_notes text,
  p_is_active boolean
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text; return;
  end if;

  if not exists (select 1 from public."Vendors" where "VendorCode" = p_vendor_code) then
    return query select false, 'That vendor no longer exists.'::text; return;
  end if;

  if p_name is null or trim(p_name) = '' then
    return query select false, 'Vendor Name is required.'::text; return;
  end if;

  update public."Vendors"
    set "Name" = trim(p_name),
        "ContactPerson" = nullif(trim(p_contact_person), ''),
        "Phone" = nullif(trim(p_phone), ''),
        "Email" = nullif(trim(p_email), ''),
        "Address" = nullif(trim(p_address), ''),
        "PaymentTerms" = nullif(trim(p_payment_terms), ''),
        "Notes" = nullif(trim(p_notes), ''),
        "IsActive" = coalesce(p_is_active, true),
        "UpdatedAtUtc" = now()
    where "VendorCode" = p_vendor_code;

  return query select true, 'Vendor updated.'::text;
end;
$$;

-- ============================================================================
-- Vendor Bills (what's owed).

drop function if exists public.admin_list_vendor_bills(text, text, text, int, int);

create or replace function public.admin_list_vendor_bills(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  bill_no text,
  vendor_code text,
  vendor_name text,
  bill_date date,
  due_date date,
  reference_no text,
  amount numeric,
  paid_amount numeric,
  balance numeric,
  is_void boolean,
  notes text,
  created_by text,
  created_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      bl."BillNo"::text, bl."VendorCode"::text, v."Name"::text, bl."BillDate", bl."DueDate", bl."ReferenceNo"::text,
      bl."Amount",
      coalesce(pd.paid_amount, 0)::numeric,
      (bl."Amount" - coalesce(pd.paid_amount, 0))::numeric,
      bl."IsVoid", bl."Notes"::text, bl."CreatedBy"::text, bl."CreatedAtUtc",
      count(*) over()
    from public."VendorBills" bl
    left join public."Vendors" v on v."VendorCode" = bl."VendorCode"
    left join (
      select "BillNo", sum("Amount") as paid_amount
      from public."VendorPayments" where not "IsVoid" and "BillNo" is not null group by "BillNo"
    ) pd on pd."BillNo" = bl."BillNo"
    where p_vendor_code is null or trim(p_vendor_code) = '' or bl."VendorCode" = p_vendor_code
    order by bl."BillDate" desc, bl."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_create_vendor_bill(text, text, text, date, date, text, numeric, text);

create or replace function public.admin_create_vendor_bill(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_bill_date date,
  p_due_date date default null,
  p_reference_no text default null,
  p_amount numeric default null,
  p_notes text default null
)
returns table(success boolean, message text, bill_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bill_no text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text, null::text; return;
  end if;

  if not exists (select 1 from public."Vendors" where "VendorCode" = p_vendor_code) then
    return query select false, 'That vendor no longer exists.'::text, null::text; return;
  end if;

  if p_bill_date is null then
    return query select false, 'Bill Date is required.'::text, null::text; return;
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return query select false, 'Amount must be greater than zero.'::text, null::text; return;
  end if;

  v_bill_no := public._next_no_series_number('VENDOR-BILL', '');

  insert into public."VendorBills" ("BillNo", "VendorCode", "BillDate", "DueDate", "ReferenceNo", "Amount", "Notes", "CreatedBy")
  values (v_bill_no, p_vendor_code, p_bill_date, p_due_date, nullif(trim(p_reference_no), ''), p_amount, nullif(trim(p_notes), ''), p_admin_username);

  return query select true, 'Bill added.'::text, v_bill_no;
end;
$$;

drop function if exists public.admin_void_vendor_bill(text, text, text);

create or replace function public.admin_void_vendor_bill(
  p_admin_username text,
  p_admin_password text,
  p_bill_no text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text; return;
  end if;

  if not exists (select 1 from public."VendorBills" where "BillNo" = p_bill_no) then
    return query select false, 'That bill no longer exists.'::text; return;
  end if;

  if exists (select 1 from public."VendorPayments" where "BillNo" = p_bill_no and not "IsVoid") then
    return query select false, 'This bill still has payments applied to it - void those payments first.'::text; return;
  end if;

  update public."VendorBills" set "IsVoid" = true where "BillNo" = p_bill_no;

  return query select true, 'Bill voided.'::text;
end;
$$;

-- ============================================================================
-- Vendor Payments (what's been paid, optionally applied against a specific bill).

drop function if exists public.admin_list_vendor_payments(text, text, text, text, int, int);

create or replace function public.admin_list_vendor_payments(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text default null,
  p_bill_no text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  payment_no text,
  vendor_code text,
  vendor_name text,
  bill_no text,
  payment_date date,
  amount numeric,
  method text,
  reference_no text,
  notes text,
  is_void boolean,
  created_by text,
  created_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      pm."PaymentNo"::text, pm."VendorCode"::text, v."Name"::text, pm."BillNo"::text, pm."PaymentDate",
      pm."Amount", pm."Method"::text, pm."ReferenceNo"::text, pm."Notes"::text, pm."IsVoid",
      pm."CreatedBy"::text, pm."CreatedAtUtc",
      count(*) over()
    from public."VendorPayments" pm
    left join public."Vendors" v on v."VendorCode" = pm."VendorCode"
    where (p_vendor_code is null or trim(p_vendor_code) = '' or pm."VendorCode" = p_vendor_code)
      and (p_bill_no is null or trim(p_bill_no) = '' or pm."BillNo" = p_bill_no)
    order by pm."PaymentDate" desc, pm."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_create_vendor_payment(text, text, text, text, date, numeric, text, text, text);

create or replace function public.admin_create_vendor_payment(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_bill_no text default null,
  p_payment_date date default null,
  p_amount numeric default null,
  p_method text default null,
  p_reference_no text default null,
  p_notes text default null
)
returns table(success boolean, message text, payment_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_payment_no text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text, null::text; return;
  end if;

  if not exists (select 1 from public."Vendors" where "VendorCode" = p_vendor_code) then
    return query select false, 'That vendor no longer exists.'::text, null::text; return;
  end if;

  if p_bill_no is not null and trim(p_bill_no) <> '' then
    if not exists (select 1 from public."VendorBills" where "BillNo" = p_bill_no and "VendorCode" = p_vendor_code and not "IsVoid") then
      return query select false, 'That bill does not belong to this vendor, or is void.'::text, null::text; return;
    end if;
  end if;

  if p_payment_date is null then
    return query select false, 'Payment Date is required.'::text, null::text; return;
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return query select false, 'Amount must be greater than zero.'::text, null::text; return;
  end if;

  v_payment_no := public._next_no_series_number('VENDOR-PAYMENT', '');

  insert into public."VendorPayments" ("PaymentNo", "VendorCode", "BillNo", "PaymentDate", "Amount", "Method", "ReferenceNo", "Notes", "CreatedBy")
  values (v_payment_no, p_vendor_code, nullif(trim(p_bill_no), ''), p_payment_date, p_amount, nullif(trim(p_method), ''), nullif(trim(p_reference_no), ''), nullif(trim(p_notes), ''), p_admin_username);

  return query select true, 'Payment recorded.'::text, v_payment_no;
end;
$$;

drop function if exists public.admin_void_vendor_payment(text, text, text);

create or replace function public.admin_void_vendor_payment(
  p_admin_username text,
  p_admin_password text,
  p_payment_no text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text; return;
  end if;

  if not exists (select 1 from public."VendorPayments" where "PaymentNo" = p_payment_no) then
    return query select false, 'That payment no longer exists.'::text; return;
  end if;

  update public."VendorPayments" set "IsVoid" = true where "PaymentNo" = p_payment_no;

  return query select true, 'Payment voided.'::text;
end;
$$;

-- ============================================================================
-- Item tagging - links exactly one vendor to an item, edited from the Item Setup factbox.

drop function if exists public.admin_set_item_vendor(text, text, text, text);

create or replace function public.admin_set_item_vendor(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_vendor_code text default null
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

  update public."Items" set "VendorCode" = nullif(trim(p_vendor_code), '') where "Code" = p_item_code;
end;
$$;

grant execute on function public.admin_list_vendors(text, text, text, int, int) to anon;
grant execute on function public.admin_create_vendor(text, text, text, text, text, text, text, text, text, text) to anon;
grant execute on function public.admin_update_vendor(text, text, text, text, text, text, text, text, text, text, boolean) to anon;
grant execute on function public.admin_list_vendor_bills(text, text, text, int, int) to anon;
grant execute on function public.admin_create_vendor_bill(text, text, text, date, date, text, numeric, text) to anon;
grant execute on function public.admin_void_vendor_bill(text, text, text) to anon;
grant execute on function public.admin_list_vendor_payments(text, text, text, text, int, int) to anon;
grant execute on function public.admin_create_vendor_payment(text, text, text, text, date, numeric, text, text, text) to anon;
grant execute on function public.admin_void_vendor_payment(text, text, text) to anon;
grant execute on function public.admin_set_item_vendor(text, text, text, text) to anon;
