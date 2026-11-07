-- READ-ONLY preview for supabase_vendor_3693_petshop_import.sql - run this FIRST, nothing is changed.
--
-- One row per product on 3693 Petshop's price list (55 fish/shrimp/snails, cost = their price),
-- showing what the import will do with it:
--   EXISTING  - matched to an item you already have (same name, ignoring case/punctuation/word
--               order, "&" = "and"). Import keeps its price as is, only adds 3693 Petshop as a vendor.
--   AMBIGUOUS - more than one item matches equally well. Import STOPS until you put the right
--               item code in that row's map_to column in the import file.
--   NEW       - no match. Import creates it under category FISH at new_price.
--
-- new_price (NEW items only) = the HIGHER of cost x 4 and family_price.
--   family_price = the most common price among your active FISH / AVAILABLE FISH items whose name
--   matches the row's family wildcard (e.g. %barb% -> your barbs at 50, %glo%tetra% -> your glo/glow
--   tetras at 40). Ties go to the higher price. family_items shows what it looked at.
--
-- possible_existing lists fish items with similar words (e.g. "Glow Tetra Neon" for
-- "Neon Glow Tetra") - if one of them IS the same fish, put its code in the import file's
-- map_to column for that row so it isn't created twice.

with supplier(sort_no, section, name, cost, family, family_not) as (
  values
    (1,'Other Fish','Rainbow Shark',25,'%rainbow%shark%',null),
    (2,'Other Fish','Albino Rainbow Shark',25,'%rainbow%shark%',null),
    (3,'Other Fish','Red Tiger Barb',12,'%barb%',null),
    (4,'Other Fish','Pink Tiger Barb',12,'%barb%',null),
    (5,'Other Fish','Green Sumatra Barb',10,'%barb%',null),
    (6,'Other Fish','Albino Tiger Barb',6,'%barb%',null),
    (7,'Other Fish','Golden Rosie Barb',3.5,'%barb%',null),
    (8,'Other Fish','Albino Bristlenose Longfin',90,'%bristlenose%',null),
    (9,'Other Fish','Black Hammerhead',15,'%hammerhead%',null),
    (10,'Other Fish','Albino Hammerhead 3-4"',40,'%hammerhead%',null),
    (11,'Other Fish','Albino Hammerhead 3"',30,'%hammerhead%',null),
    (12,'Angel Fish','Angel Fish (Breeder)',100,'%angel%',null),
    (13,'Angel Fish','Marble Angel Fish',15,'%angel%',null),
    (14,'Tetra','Yellow Glow Tetra',9,'%glo%tetra%',null),
    (15,'Tetra','Neon Glow Tetra',9,'%glo%tetra%',null),
    (16,'Tetra','Dark Green Glow Tetra',9,'%glo%tetra%',null),
    (17,'Tetra','Red Glow Tetra',9,'%glo%tetra%',null),
    (18,'Tetra','Black Skirt Tetra',3.5,'%skirt%tetra%',null),
    (19,'Tetra','Albino Skirt Tetra',3.5,'%skirt%tetra%',null),
    (20,'Tetra','Pristella Tetra',9,'%pristella%',null),
    (21,'Tetra','Albino Pristella Tetra',9,'%pristella%',null),
    (22,'Tetra','Red Cross',3.5,'%red%cross%',null),
    (23,'Zebra / Danio','Pink Zebra',2.5,'%zebra%','pleco'),
    (24,'Zebra / Danio','Leopard Zebra',6,'%zebra%','pleco'),
    (25,'Zebra / Danio','Cosmic Blue Zebra',6,'%zebra%','pleco'),
    (26,'Zebra / Danio','Green Zebra',9,'%zebra%','pleco'),
    (27,'Zebra / Danio','Leopard Blue Danio',6,'%danio%',null),
    (28,'Zebra / Danio','Orange Danio',6,'%danio%',null),
    (29,'Others','Albino Tinfoil',30,'%tinfoil%',null),
    (30,'Others','Red Paco',15,'%paco%',null),
    (31,'Others','Koi',100,'%koi%',null),
    (32,'Others','Green Terror',12,'%terror%',null),
    (33,'Others','Albino Butterfly Pleco (5-6")',250,'%butterfly%pleco%',null),
    (34,'Others','Longfin Tiger Oscar (3")',150,'%oscar%',null),
    (35,'Others','Tiger Oscar (3")',120,'%oscar%',null),
    (36,'Others','Red Tiger Oscar',90,'%oscar%',null),
    (37,'Others','Red & White Ranchu',180,'%ranchu%',null),
    (38,'Others','Red and White Thai Ranchu',150,'%ranchu%',null),
    (39,'Others','Golden Gourami',18,'%gourami%','dwarf'),
    (40,'Others','Red Dwarf Gourami (M)',40,'%dwarf%gourami%',null),
    (41,'Others','Red Dwarf Gourami (Fem)',8,'%dwarf%gourami%',null),
    (42,'Shrimps','Blue Shrimp',15,'%shrimp%',null),
    (43,'Shrimps','Red Shrimp',12,'%shrimp%',null),
    (44,'Shrimps','Orange Shrimp',12,'%shrimp%',null),
    (45,'Shrimps','Black / Chocolate Shrimp',12,'%shrimp%',null),
    (46,'Shrimps','Fire Red Shrimp',8,'%shrimp%',null),
    (47,'Cleaners','Apple Snail',8,'%snail%',null),
    (48,'Cleaners','Bronze Corydora',15,'%cory%',null),
    (49,'Cleaners','Julii Corydora',25,'%cory%',null),
    (50,'Cleaners','Pygmy Cory',25,'%cory%',null),
    (51,'Cleaners','Albino Pleco',10,'%pleco%','butterfly|zebra|bristlenose'),
    (52,'Cleaners','Black Pleco',5,'%pleco%','butterfly|zebra|bristlenose'),
    (53,'Betta','Halfmoon Betta Male',70,'%betta%',null),
    (54,'Betta','Double Tail Betta',60,'%betta%',null),
    (55,'Betta','Veil Tail Betta',40,'%betta%',null)
),
s as (
  select sp.*,
         (select string_agg(w, ' ' order by w) from unnest(string_to_array(trim(regexp_replace(lower(replace(sp.name, '&', ' and ')), '[^a-z0-9]+', ' ', 'g')), ' ')) w) as wordkey,
         string_to_array(trim(regexp_replace(lower(replace(sp.name, '&', ' and ')), '[^a-z0-9]+', ' ', 'g')), ' ') as words
  from supplier sp
),
i as (
  select it."Code", it."Name", it."CategoryCode", it."Price", it."Cost", it."VendorCode", coalesce(it."IsActive", true) as active,
         upper(coalesce(it."CategoryCode", '')) in ('FISH', 'AVAILABLE FISH') as is_fish,
         (select string_agg(w, ' ' order by w) from unnest(string_to_array(trim(regexp_replace(lower(replace(coalesce(it."Name", ''), '&', ' and ')), '[^a-z0-9]+', ' ', 'g')), ' ')) w) as wordkey,
         string_to_array(trim(regexp_replace(lower(replace(coalesce(it."Name", ''), '&', ' and ')), '[^a-z0-9]+', ' ', 'g')), ' ') as words
  from public."Items" it
),
ranked as (
  select s.sort_no, i.*,
         rank() over (partition by s.sort_no order by i.active desc, i.is_fish desc) as rnk
  from s join i on i.wordkey = s.wordkey
),
best as (
  select sort_no, count(*) filter (where rnk = 1) as top_count,
         string_agg("Code" || ' "' || "Name" || '"' || case when not active then ' [inactive]' else '' end, ' | ') filter (where rnk = 1) as top_matches,
         max("Code") filter (where rnk = 1) as code
  from ranked group by sort_no
),
fam_items as (
  select s.sort_no, i."Code", i."Name", i."Price"
  from s join i on i.is_fish and i.active and coalesce(i."Price", 0) > 0
               and i."Name" ilike s.family
               and (s.family_not is null or i."Name" !~* s.family_not)
),
fam as (
  select f.sort_no,
         (select f2."Price" from fam_items f2 where f2.sort_no = f.sort_no
          group by f2."Price" order by count(*) desc, f2."Price" desc limit 1) as family_price,
         left(string_agg(f."Name" || ' ' || round(f."Price", 2), ' | ' order by f."Price" desc, f."Name"), 400) as family_items
  from fam_items f group by f.sort_no
),
hints as (
  select s.sort_no,
         string_agg(i."Code" || ' "' || i."Name" || '"', ' | ' order by i."Name") as possible_existing
  from s join i on i.is_fish
               and i.wordkey is distinct from s.wordkey
               and (select count(*) from unnest(s.words) w where w = any(i.words) and w !~ '^[0-9]+$')
                   >= greatest(1, cardinality(s.words) - 1)
  group by s.sort_no
)
select s.sort_no as "#", s.section, s.name as supplier_name, s.cost,
       case when b.top_count > 1 then 'AMBIGUOUS' when b.top_count = 1 then 'EXISTING' else 'NEW' end as action,
       case when coalesce(b.top_count, 0) = 0 then greatest(s.cost * 4, coalesce(fm.family_price, 0)) end as new_price,
       s.family, fm.family_price, coalesce(fm.family_items, '') as family_items,
       coalesce(b.top_matches, '') as matched_item,
       it."Price" as current_price, it."VendorCode" as current_primary_vendor,
       left(coalesce(h.possible_existing, ''), 400) as possible_existing
from s
left join best b on b.sort_no = s.sort_no
left join public."Items" it on it."Code" = b.code and b.top_count = 1
left join fam fm on fm.sort_no = s.sort_no
left join hints h on h.sort_no = s.sort_no
union all
select null, 'INFO', 'FISH category code prefix / next new code',
       null, 'INFO', null, null, null,
       case when exists (select 1 from public."Vendors" where "VendorCode" = '3693PETSHOP') then 'vendor 3693PETSHOP already exists' else 'vendor 3693PETSHOP will be created' end,
       coalesce(nullif(trim(c."CodePrefix"), ''), '(none - import will use FSH)') || ' -> ' ||
         public._next_item_code(coalesce(nullif(trim(c."CodePrefix"), ''), 'FSH')),
       null, null, ''
from public."Categories" c where c."Code" = 'FISH'
order by 1 nulls first;
