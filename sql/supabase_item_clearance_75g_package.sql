-- Clearance sale item - per "can you create the item for that promo?" (75 gallon package, PHP 55,000 -> 40,000,
-- only 1 unit left).
--
--   - Creates ONE portal item in the AQUARIUM category, the same way Item Setup > New Item does
--     (admin_create_item): next code from the category's prefix, matching Variants row, active.
--   - Price is the SALE price (40,000) itself, not Promo Price: the bot and Order Now never see PromoPrice, so
--     a 55,000 price with a 40,000 promo would be quoted at 55,000.
--   - Picture = the flyer on rspetstop.com (docs/icons/promo-clearance-75g.jpg) - it shows once that file is
--     pushed. The bot's send_item_image then sends the flyer for this item too.
--   - Stock is NOT set here: add the 1 unit at its branch on the Physical Inventory Journal page, so it goes
--     through the item ledger like any other stock.
--
-- Safe to re-run: if an item with this exact name already exists it is left alone. Ends with ONE result.

do $$
declare
  v_name text := '75 Gallon Aquarium with CABINET Package - CLEARANCE SALE';
  v_prefix text;
  v_code text;
  v_variation_id text := gen_random_uuid()::text;
  v_image text := 'https://rspetstop.com/icons/promo-clearance-75g.jpg';
  v_description text :=
    'CLEARANCE SALE - only 1 unit left. 75 gallon aquarium with cabinet and canopy, undersump filtration system (3ft), '
    || 'overflow box, set of pipings and submersible pump. Was PHP 55,000, now PHP 40,000. FREE installation. '
    || 'PHP 100 delivery fee within NCR and Cavite.';
begin
  -- Already created under the first name (before CABINET was added) -> just rename it, don't make a second item.
  update public."Items" set "Name" = v_name, "PortalEditedAtUtc" = now(), "PortalEditedBy" = 'sql: clearance 75g'
  where "Name" = '75 Gallon Aquarium Package - CLEARANCE SALE';
  update public."Variants" set "VariantName" = v_name
  where "VariantName" = '75 Gallon Aquarium Package - CLEARANCE SALE';

  if exists (select 1 from public."Items" where "Name" = v_name) then
    raise notice 'Item already exists - nothing changed.';
    return;
  end if;

  select upper(nullif(trim("CodePrefix"), '')) into v_prefix from public."Categories" where "Code" = 'AQUARIUM';
  if v_prefix is null then
    raise exception 'Category AQUARIUM not found or has no code prefix - create the item on Item Setup > New Item instead.';
  end if;

  perform pg_advisory_xact_lock(hashtext('item-code|' || v_prefix));
  v_code := public._next_item_code(v_prefix);

  insert into public."Items" (
    "Code", "Name", "Description", "Brand", "CategoryCode", "SKU", "Price", "IsActive",
    "VariationId", "Images", "PortalEditedAtUtc", "PortalEditedBy"
  )
  values (
    v_code, v_name, v_description, null, 'AQUARIUM', v_code, 40000, true,
    v_variation_id, v_image, now(), 'sql: clearance 75g'
  );

  insert into public."Variants" ("VariationId", "MainItemCode", "ItemCode", "SKU", "VariantName", "Price", "CategoryCode", "Images")
  values (v_variation_id, v_code, v_code, v_code, v_name, 40000, 'AQUARIUM', v_image);
end;
$$;

-- Check - one result.
select i."Code" as item_code, i."Name" as name, i."Price" as price, i."IsActive" as active, i."CategoryCode" as category,
       (select count(*) from public."Variants" v where v."MainItemCode" = i."Code") as variants
from public."Items" i
where i."Name" = '75 Gallon Aquarium with CABINET Package - CLEARANCE SALE';
