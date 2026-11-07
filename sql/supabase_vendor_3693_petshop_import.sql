-- New vendor 3693 Petshop (fish supplier) + their 55-product price list.
-- Run AFTER checking supabase_vendor_3693_petshop_preview.sql (read-only).
--
-- What it does, all inside one DO block (any error = nothing changed):
--   1. Creates vendor 3693PETSHOP "3693 Petshop" (left alone if it already exists).
--   2. Matches each product to an existing item by name (ignoring case/punctuation/word order,
--      "&" = "and"), or to the item code you put in its map_to column below.
--        - EXISTING: price/cost NOT changed. 3693 Petshop is only added to the item's vendor
--          catalog with their cost (so a PO to them prefills it), and becomes the item's PRIMARY
--          vendor only if the item has no vendor yet.
--        - NEW: created under category FISH with the category's code prefix (FSH if it has none,
--          saved on the category like Item Setup does), Cost = their cost, primary vendor
--          3693PETSHOP, and Price = the HIGHER of:
--              cost x 4, and
--              the most common price of your active FISH / AVAILABLE FISH items matching the
--              row's family wildcard (e.g. %barb% -> 50, %glo%tetra% -> 40); ties -> higher.
--          Family prices are read BEFORE any new item is created, so new items don't feed into
--          each other's price.
--   3. STOPS with an error if a product matches more than one item equally - put the right code
--      in that row's map_to and run again.
--
-- To stop a product from being created as new because it's really an existing item under another
-- name (see the preview's possible_existing column), put that item's Code in map_to.
-- Safe to re-run: re-matches by name, so items created on the first run are found, not duplicated.

create temp table if not exists _v3693 (
  sort_no int, section text, name text, cost numeric, family text, family_not text, map_to text,
  action text, item_code text, family_price numeric, old_price numeric, new_price numeric, note text
);
truncate _v3693;

--                                                                    family_not: regex of names to leave out of the family
--                                                                    map_to: '' = match by name
insert into _v3693 (sort_no, section, name, cost, family, family_not, map_to) values
  (1,'Other Fish','Rainbow Shark',25,'%rainbow%shark%',null,''),
  (2,'Other Fish','Albino Rainbow Shark',25,'%rainbow%shark%',null,''),
  (3,'Other Fish','Red Tiger Barb',12,'%barb%',null,''),
  (4,'Other Fish','Pink Tiger Barb',12,'%barb%',null,''),
  (5,'Other Fish','Green Sumatra Barb',10,'%barb%',null,''),
  (6,'Other Fish','Albino Tiger Barb',6,'%barb%',null,''),
  (7,'Other Fish','Golden Rosie Barb',3.5,'%barb%',null,''),
  (8,'Other Fish','Albino Bristlenose Longfin',90,'%bristlenose%',null,''),
  (9,'Other Fish','Black Hammerhead',15,'%hammerhead%',null,''),
  (10,'Other Fish','Albino Hammerhead 3-4"',40,'%hammerhead%',null,''),
  (11,'Other Fish','Albino Hammerhead 3"',30,'%hammerhead%',null,''),
  (12,'Angel Fish','Angel Fish (Breeder)',100,'%angel%',null,''),
  (13,'Angel Fish','Marble Angel Fish',15,'%angel%',null,''),
  (14,'Tetra','Yellow Glow Tetra',9,'%glo%tetra%',null,''),
  (15,'Tetra','Neon Glow Tetra',9,'%glo%tetra%',null,''),
  (16,'Tetra','Dark Green Glow Tetra',9,'%glo%tetra%',null,''),
  (17,'Tetra','Red Glow Tetra',9,'%glo%tetra%',null,''),
  (18,'Tetra','Black Skirt Tetra',3.5,'%skirt%tetra%',null,''),
  (19,'Tetra','Albino Skirt Tetra',3.5,'%skirt%tetra%',null,''),
  (20,'Tetra','Pristella Tetra',9,'%pristella%',null,''),
  (21,'Tetra','Albino Pristella Tetra',9,'%pristella%',null,''),
  (22,'Tetra','Red Cross',3.5,'%red%cross%',null,''),
  (23,'Zebra / Danio','Pink Zebra',2.5,'%zebra%','pleco',''),
  (24,'Zebra / Danio','Leopard Zebra',6,'%zebra%','pleco',''),
  (25,'Zebra / Danio','Cosmic Blue Zebra',6,'%zebra%','pleco',''),
  (26,'Zebra / Danio','Green Zebra',9,'%zebra%','pleco',''),
  (27,'Zebra / Danio','Leopard Blue Danio',6,'%danio%',null,''),
  (28,'Zebra / Danio','Orange Danio',6,'%danio%',null,''),
  (29,'Others','Albino Tinfoil',30,'%tinfoil%',null,''),
  (30,'Others','Red Paco',15,'%paco%',null,''),
  (31,'Others','Koi',100,'%koi%',null,''),
  (32,'Others','Green Terror',12,'%terror%',null,''),
  (33,'Others','Albino Butterfly Pleco (5-6")',250,'%butterfly%pleco%',null,''),
  (34,'Others','Longfin Tiger Oscar (3")',150,'%oscar%',null,''),
  (35,'Others','Tiger Oscar (3")',120,'%oscar%',null,''),
  (36,'Others','Red Tiger Oscar',90,'%oscar%',null,''),
  (37,'Others','Red & White Ranchu',180,'%ranchu%',null,''),
  (38,'Others','Red and White Thai Ranchu',150,'%ranchu%',null,''),
  (39,'Others','Golden Gourami',18,'%gourami%','dwarf',''),
  (40,'Others','Red Dwarf Gourami (M)',40,'%dwarf%gourami%',null,''),
  (41,'Others','Red Dwarf Gourami (Fem)',8,'%dwarf%gourami%',null,''),
  (42,'Shrimps','Blue Shrimp',15,'%shrimp%',null,''),
  (43,'Shrimps','Red Shrimp',12,'%shrimp%',null,''),
  (44,'Shrimps','Orange Shrimp',12,'%shrimp%',null,''),
  (45,'Shrimps','Black / Chocolate Shrimp',12,'%shrimp%',null,''),
  (46,'Shrimps','Fire Red Shrimp',8,'%shrimp%',null,''),
  (47,'Cleaners','Apple Snail',8,'%snail%',null,''),
  (48,'Cleaners','Bronze Corydora',15,'%cory%',null,''),
  (49,'Cleaners','Julii Corydora',25,'%cory%',null,''),
  (50,'Cleaners','Pygmy Cory',25,'%cory%',null,''),
  (51,'Cleaners','Albino Pleco',10,'%pleco%','butterfly|zebra|bristlenose',''),
  (52,'Cleaners','Black Pleco',5,'%pleco%','butterfly|zebra|bristlenose',''),
  (53,'Betta','Halfmoon Betta Male',70,'%betta%',null,''),
  (54,'Betta','Double Tail Betta',60,'%betta%',null,''),
  (55,'Betta','Veil Tail Betta',40,'%betta%',null,'');

do $$
declare
  r record;
  v_key text;
  v_top int;
  v_code text;
  v_list text;
  v_prefix text;
  v_vid text;
  v_price numeric;
  v_ambiguous text := '';
begin
  perform public._require_items_portal_owned();

  -- 1. Vendor
  insert into public."Vendors" ("VendorCode", "Name", "Notes", "IsActive")
  values ('3693PETSHOP', '3693 Petshop', 'Fish supplier', true)
  on conflict ("VendorCode") do nothing;

  -- FISH category + code prefix for new items
  if not exists (select 1 from public."Categories" where "Code" = 'FISH') then
    raise exception 'Category FISH not found.';
  end if;
  select upper(coalesce(nullif(trim("CodePrefix"), ''), 'FSH')) into v_prefix from public."Categories" where "Code" = 'FISH';
  update public."Categories" set "CodePrefix" = v_prefix where "Code" = 'FISH' and nullif(trim(coalesce("CodePrefix", '')), '') is null;

  -- 2. Match + family price (all read before anything is created)
  for r in select * from _v3693 order by sort_no loop
    update _v3693 t
       set family_price = (
         select it."Price"
         from public."Items" it
         where coalesce(it."IsActive", true)
           and upper(coalesce(it."CategoryCode", '')) in ('FISH', 'AVAILABLE FISH')
           and coalesce(it."Price", 0) > 0
           and it."Name" ilike r.family
           and (r.family_not is null or it."Name" !~* r.family_not)
         group by it."Price"
         order by count(*) desc, it."Price" desc
         limit 1)
     where t.sort_no = r.sort_no;

    if nullif(trim(r.map_to), '') is not null then
      if not exists (select 1 from public."Items" where "Code" = trim(r.map_to)) then
        raise exception 'Row % (%): map_to item % not found.', r.sort_no, r.name, r.map_to;
      end if;
      update _v3693 set action = 'EXISTING', item_code = trim(r.map_to), note = 'mapped by hand' where sort_no = r.sort_no;
      continue;
    end if;

    v_key := (select string_agg(w, ' ' order by w) from unnest(string_to_array(trim(regexp_replace(lower(replace(r.name, '&', ' and ')), '[^a-z0-9]+', ' ', 'g')), ' ')) w);

    with m as (
      select it."Code", it."Name",
             rank() over (order by coalesce(it."IsActive", true) desc, (upper(coalesce(it."CategoryCode", '')) in ('FISH', 'AVAILABLE FISH')) desc) as rnk
      from public."Items" it
      where (select string_agg(w, ' ' order by w) from unnest(string_to_array(trim(regexp_replace(lower(replace(coalesce(it."Name", ''), '&', ' and ')), '[^a-z0-9]+', ' ', 'g')), ' ')) w) = v_key
    )
    select count(*) filter (where rnk = 1), max("Code") filter (where rnk = 1),
           string_agg("Code" || ' "' || "Name" || '"', ', ') filter (where rnk = 1)
      into v_top, v_code, v_list
    from m;

    if v_top > 1 then
      v_ambiguous := v_ambiguous || format(E'\n  row %s %s -> %s', r.sort_no, r.name, v_list);
    elsif v_top = 1 then
      update _v3693 set action = 'EXISTING', item_code = v_code where sort_no = r.sort_no;
    else
      update _v3693 set action = 'NEW' where sort_no = r.sort_no;
    end if;
  end loop;

  if v_ambiguous <> '' then
    raise exception 'Nothing changed - these match more than one item, put the right code in map_to:%', v_ambiguous;
  end if;

  -- 3. Apply
  for r in select * from _v3693 order by sort_no loop
    if r.action = 'EXISTING' then
      -- Existing items: price, cost and variants are NOT touched - only the vendor is added.
      update _v3693 set old_price = (select "Price" from public."Items" where "Code" = r.item_code)
       where sort_no = r.sort_no;

      update public."Items"
         set "VendorCode" = '3693PETSHOP',
             "PortalEditedAtUtc" = now(), "PortalEditedBy" = '3693 Petshop import'
       where "Code" = r.item_code
         and nullif(trim(coalesce("VendorCode", '')), '') is null;

      if (select "VendorCode" from public."Items" where "Code" = r.item_code) <> '3693PETSHOP' then
        update _v3693 set note = coalesce(note || '; ', '') || 'primary vendor stays ' || (select "VendorCode" from public."Items" where "Code" = r.item_code)
         where sort_no = r.sort_no;
      end if;
    else
      v_price := round(greatest(r.cost * 4, coalesce(r.family_price, 0)), 2);

      perform pg_advisory_xact_lock(hashtext('item-code|' || v_prefix));
      v_code := public._next_item_code(v_prefix);
      v_vid := gen_random_uuid()::text;

      insert into public."Items" (
        "Code", "Name", "Description", "CategoryCode", "SKU", "Price", "Cost", "IsActive",
        "VariationId", "VendorCode", "PortalEditedAtUtc", "PortalEditedBy"
      ) values (
        v_code, r.name, r.name, 'FISH', v_code, v_price, r.cost, true,
        v_vid, '3693PETSHOP', now(), '3693 Petshop import'
      );

      insert into public."Variants" ("VariationId", "MainItemCode", "ItemCode", "SKU", "VariantName", "Price", "CategoryCode")
      values (v_vid, v_code, v_code, v_code, r.name, v_price, 'FISH');

      update _v3693
         set item_code = v_code, new_price = v_price,
             note = case when coalesce(r.family_price, 0) > r.cost * 4 then 'family price ' || round(r.family_price, 2) || ' used (cost x 4 = ' || round(r.cost * 4, 2) || ')' else 'cost x 4' end
       where sort_no = r.sort_no;
    end if;

    -- Vendor catalog row with 3693 Petshop's cost (every item, existing or new)
    insert into public."ItemVendors" ("ItemCode", "VendorCode", "Cost", "UpdatedAtUtc")
    values ((select item_code from _v3693 where sort_no = r.sort_no), '3693PETSHOP', r.cost, now())
    on conflict ("ItemCode", "VendorCode") do update set "Cost" = excluded."Cost", "UpdatedAtUtc" = now();
  end loop;
end;
$$;

select sort_no as "#", section, name as supplier_name, action, item_code, cost,
       old_price as existing_price_kept, new_price, coalesce(note, '') as note
from _v3693
order by sort_no;
