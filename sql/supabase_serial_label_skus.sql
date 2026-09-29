-- SKU on serial barcode labels - per "in the printout of serials can you make it show the SKU?".
--
--   staff_get_serial_skus(user, pass, serial_nos[]) -> serial_no, sku
--     The serial's variant SKU (Variants.SKU of ItemSerialTracking.VariantCode), else its item's SKU
--     (Items.SKU). Serials with neither are left out.
--
-- docs/js/labelPrinter.js calls it once per print for the labels being printed, so every place that
-- prints serial labels (Production Orders after Post Output / Print Serial Labels, Online Orders'
-- Ready to Ship / Print Serial Labels) shows the SKU without changing their own RPCs.
--
-- Safe to re-run.

drop function if exists public.staff_get_serial_skus(text, text, text[]);

create or replace function public.staff_get_serial_skus(
  p_admin_username text,
  p_admin_password text,
  p_serial_nos text[]
)
returns table(serial_no text, sku text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."SerialNo"::text,
           coalesce(nullif(trim(v."SKU"), ''), nullif(trim(i."SKU"), ''))::text
    from public."ItemSerialTracking" s
    left join public."Variants" v on v."VariationId" = s."VariantCode"
    left join public."Items" i on i."Code" = s."ItemCode"
    where s."SerialNo" = any(coalesce(p_serial_nos, '{}'))
      and coalesce(nullif(trim(v."SKU"), ''), nullif(trim(i."SKU"), '')) is not null;
end;
$$;

grant execute on function public.staff_get_serial_skus(text, text, text[]) to anon;

notify pgrst, 'reload schema';
