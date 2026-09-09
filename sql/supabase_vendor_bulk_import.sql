-- Adds "Import from Excel" for Vendor Setup (Export to Excel already exists as CSV; this is the
-- matching bulk insert/update path). Per "can you export to excel and import to excel this way I
-- can update / insert using excel".

drop function if exists public.admin_bulk_upsert_vendors(text, text, jsonb);

-- p_vendors is a JSON array of objects with the same keys admin_list_vendors returns
-- (vendor_code, name, contact_person, phone, email, address, payment_terms, notes, is_active) -
-- matches what Export to Excel produces, so a round-tripped export -> edit -> import just works.
-- Upserts on VendorCode (insert if new, update if it already exists) rather than requiring the
-- caller to know which - vendorSetup.js parses the CSV client-side and doesn't distinguish
-- either. is_active defaults true when omitted/blank, same as admin_create_vendor's column
-- default.
create or replace function public.admin_bulk_upsert_vendors(
  p_admin_username text,
  p_admin_password text,
  p_vendors jsonb
)
returns table(inserted_count int, updated_count int, skipped_count int, errors text[])
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row jsonb;
  v_code text;
  v_name text;
  v_existed boolean;
  v_inserted int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  v_errors text[] := array[]::text[];
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_vendors is null or jsonb_typeof(p_vendors) <> 'array' then
    raise exception 'p_vendors must be a JSON array.';
  end if;

  for v_row in select * from jsonb_array_elements(p_vendors)
  loop
    v_code := upper(trim(coalesce(v_row ->> 'vendor_code', '')));
    v_name := trim(coalesce(v_row ->> 'name', ''));

    if v_code = '' then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || 'Skipped a row with no Vendor Code.';
      continue;
    end if;

    if v_name = '' then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || (v_code || ': skipped, Name is required.');
      continue;
    end if;

    select exists(select 1 from public."Vendors" where "VendorCode" = v_code) into v_existed;

    insert into public."Vendors" ("VendorCode", "Name", "ContactPerson", "Phone", "Email", "Address", "PaymentTerms", "Notes", "IsActive")
    values (
      v_code, v_name,
      nullif(trim(coalesce(v_row ->> 'contact_person', '')), ''),
      nullif(trim(coalesce(v_row ->> 'phone', '')), ''),
      nullif(trim(coalesce(v_row ->> 'email', '')), ''),
      nullif(trim(coalesce(v_row ->> 'address', '')), ''),
      nullif(trim(coalesce(v_row ->> 'payment_terms', '')), ''),
      nullif(trim(coalesce(v_row ->> 'notes', '')), ''),
      coalesce((v_row ->> 'is_active')::boolean, true)
    )
    on conflict ("VendorCode") do update
      set "Name" = excluded."Name",
          "ContactPerson" = excluded."ContactPerson",
          "Phone" = excluded."Phone",
          "Email" = excluded."Email",
          "Address" = excluded."Address",
          "PaymentTerms" = excluded."PaymentTerms",
          "Notes" = excluded."Notes",
          "IsActive" = excluded."IsActive",
          "UpdatedAtUtc" = now();

    if v_existed then
      v_updated := v_updated + 1;
    else
      v_inserted := v_inserted + 1;
    end if;
  end loop;

  return query select v_inserted, v_updated, v_skipped, v_errors;
end;
$$;

grant execute on function public.admin_bulk_upsert_vendors(text, text, jsonb) to anon;
