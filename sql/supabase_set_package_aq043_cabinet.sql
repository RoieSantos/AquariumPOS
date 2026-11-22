-- One-off: give AQ-043 "75 Gallon Aquarium with CABINET Package - CLEARANCE SALE" a set BOM.
--
-- AQ-043 is a SET-category item (sold on advance order AO-00279) but no Customer Aquarium package
-- pointed at it, so the Online Orders "Assemble" dialog had no parts to explode. This creates the
-- package with Set Code AQ-043 (_resolve_set_package matches SetCode first), so staff get these parts:
--
--   AQ-028  STANDARD-75G (48x18x20in, 6MM GLASS)   - aquarium (staff pick the sealant colour)
--   L-027   FROK-SUBMERSIBLE-LIGHT (4FT-WHITE)     - lights
--   S-009   UNDERSUMP (50GAL)                      - undersump
--   P-005   A4000-SUBMERSIBLE-PUMP (24W)           - submersible pump
--   AQS-014 CERAMIC-RING (1KG)                     - medias
--   MD-001  ACTIVATED-CARBON (1KG)                 - medias
--   MD-002  WASHABLE-FILTER-MATT                   - medias
--
-- No stand: the cabinet is the stand, so RequireStand = false (and RequirePipe = false - no pipe line).
-- The header trigger re-writes the AQ-043 Items row from the package, so the package copies the item's
-- current name, description, price (40,000), image and online status - the item doesn't change.
--
-- Safe to re-run: the header is upserted and its lines replaced.

do $$
declare
  v_item public."Items"%rowtype;
  v_pkg  text;
begin
  select * into v_item from public."Items" where "Code" = 'AQ-043';
  if not found then raise exception 'AQ-043 not found in Items'; end if;
  v_pkg := v_item."Name";

  insert into public."CompleteAquariumSetHeader"
    ("PackageName", "PackagePrice", "VariantID", "CreatedDate", "UpdatedDate",
     "RequireSump", "RequireStand", "RequireLights", "RequirePump", "RequirePipe",
     "SetCode", "Description", "SellOnline", "Images")
  values
    (v_pkg, v_item."Price", v_item."VariationId", now(), now(),
     true, false, true, true, false,
     'AQ-043', v_item."Description", coalesce(v_item."IsActive", true) and not coalesce(v_item."HideFromSet", false), v_item."Images")
  on conflict ("PackageName") do update set
    "PackagePrice" = excluded."PackagePrice",
    "VariantID"    = excluded."VariantID",
    "UpdatedDate"  = now(),
    "RequireSump"  = true,  "RequireStand" = false, "RequireLights" = true,
    "RequirePump"  = true,  "RequirePipe"  = false,
    "SetCode"      = 'AQ-043',
    "Description"  = excluded."Description",
    "SellOnline"   = excluded."SellOnline",
    "Images"       = excluded."Images";

  delete from public."CompleteAquariumSetLine" where "PackageName" = v_pkg;

  insert into public."CompleteAquariumSetLine" ("PackageName", "ItemNo", "ItemName", "Quantity", "Price", "CreatedDate", "UpdatedDate")
  select v_pkg, i."Code", i."Name", 1, coalesce(i."Price", 0), now(), now()
  from (values (1, 'AQ-028'), (2, 'L-027'), (3, 'S-009'), (4, 'P-005'), (5, 'AQS-014'), (6, 'MD-001'), (7, 'MD-002')) p(ord, code)
  join public."Items" i on i."Code" = p.code
  order by p.ord;

  if (select count(*) from public."CompleteAquariumSetLine" where "PackageName" = v_pkg) <> 7 then
    raise exception 'Expected 7 package lines - an item code is missing';
  end if;
end
$$;

-- Result: the package and its parts.
select h."SetCode", h."PackageName", h."PackagePrice", h."RequireStand", l."ItemNo", l."ItemName", l."Quantity", l."Price"
from public."CompleteAquariumSetHeader" h
join public."CompleteAquariumSetLine" l on l."PackageName" = h."PackageName"
where h."SetCode" = 'AQ-043'
order by l."EntryNo";
