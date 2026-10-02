-- Serial Inventory Journal: show each serial's variant SKU in the Serial Nos. dialog, per "in this view
-- can you show the SKU to be able to identify if its clear and black sealant".
--
-- The Black / Clear sealant colour only lives in the variant's SKU (e.g. "AQ-002-ClearSealant", Pancake's
-- variation display_id) - VariantName is "<code> - <product name>" with no colour (same gap as
-- supabase_production_shelf_serial_sku_colour.sql). Same RPC as supabase_serial_inventory_journal.sql plus
-- a variant_sku column; docs/js/serialInventoryJournal.js shows it (and still works before this is run).
--
-- Run AFTER supabase_serial_inventory_journal.sql. Safe to re-run.

drop function if exists public.admin_get_serial_journal_line_serials(text, text, bigint);

create or replace function public.admin_get_serial_journal_line_serials(
  p_admin_username text,
  p_admin_password text,
  p_line_id bigint
)
returns table(
  running_serial_no bigint, serial_no text, item_code text, variant_code text, status text, location text,
  source_document_no text, created_at_utc timestamptz, mark text, in_stock_here boolean, variant_sku text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line public."SerialJournalLines";
  v_wh_name text;
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_line from public."SerialJournalLines" where "LineID" = p_line_id;
  if not found then
    raise exception 'That line is no longer on the worksheet. Refresh the page.';
  end if;
  select "Name" into v_wh_name from public."Warehouses" where "ID" = v_line."WarehouseId";

  return query
    select s."RunningSerialNo", s."SerialNo"::text, s."ItemCode"::text, s."VariantCode"::text,
           s."Status"::text, s."Location"::text, s."SourceDocumentNo"::text, s."CreatedAtUtc",
           m."Mark"::text,
           (s."Status" = 'IN_STOCK' and public._sij_same_location(s."Location", v_wh_name)),
           nullif(trim(v."SKU"), '')::text
    from public."ItemSerialTracking" s
    left join public."SerialJournalLineSerials" m on m."LineID" = p_line_id and m."RunningSerialNo" = s."RunningSerialNo"
    left join public."Variants" v on v."VariationId" = s."VariantCode"
    where (s."Status" = 'IN_STOCK' and public._sij_same_location(s."Location", v_wh_name)
           and s."ItemCode" = v_line."ItemCode"
           and (v_line."VariantId" is null or s."VariantCode" = v_line."VariantId"))
       or m."Mark" is not null
    order by (m."Mark" = 'FOUND') nulls first, s."SerialNo";
end;
$$;

grant execute on function public.admin_get_serial_journal_line_serials(text, text, bigint) to anon;

notify pgrst, 'reload schema';
