-- Read-only: exports the portal's item codes and variation ids as ready-to-paste SQL Server INSERTs, for
-- local_pos_cleanup_items_not_on_portal.sql - per "clean my items / variants on my local POS. i want to
-- remove the items that is not on the portal".
--
-- How to use: run this whole file, click the "paste_into_pos_script" cell of the one result row, copy
-- it, and paste it into the PASTE HERE section of local_pos_cleanup_items_not_on_portal.sql.
-- Every row in public."Items" / public."Variants" counts as "on the portal" (IsActive is not checked).
-- Chunks of 900 rows because SQL Server allows at most 1000 rows per INSERT ... VALUES. Safe to re-run.

with it as (
  select distinct trim("Code") as c from public."Items" where nullif(trim(coalesce("Code", '')), '') is not null
),
vt as (
  select distinct trim("VariationId") as c from public."Variants" where nullif(trim(coalesce("VariationId", '')), '') is not null
),
item_chunks as (
  select g, 'INSERT INTO #PortalItems (Code) VALUES '
            || string_agg('(N''' || replace(c, '''', '''''') || ''')', ',' order by c) || ';' as stmt
    from (select c, (row_number() over (order by c) - 1) / 900 as g from it) x
   group by g
),
variant_chunks as (
  select g, 'INSERT INTO #PortalVariants (VariationId) VALUES '
            || string_agg('(N''' || replace(c, '''', '''''') || ''')', ',' order by c) || ';' as stmt
    from (select c, (row_number() over (order by c) - 1) / 900 as g from vt) x
   group by g
)
select (select count(*) from it) as portal_items,
       (select count(*) from vt) as portal_variants,
       -- No comment line and space-separated: the grid's cell copy can flatten the text onto ONE line,
       -- and a leading "-- ..." comment then swallowed every INSERT (the POS script saw 0 items).
       concat_ws(' ',
         (select string_agg(stmt, ' ' order by g) from item_chunks),
         (select string_agg(stmt, ' ' order by g) from variant_chunks)
       ) as paste_into_pos_script;
