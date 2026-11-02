-- READ-ONLY. Did every aquarium set go up in the price increase? Per "in the set there is an SET that did not
-- increase.. can you check". Nothing is changed.
--
-- One row per SET-category item and per package with a SetCode, problems first.
--   status          CHECK - ... needs a look / NOTE - ... worth knowing / OK - ... nothing to do
--   package_price   the real set price (Customer Aquarium page); blank = no package uses this code
--   item_price      Items."Price", the trigger-maintained copy of package_price
--   twin_code       old AS-xxx <-> new SET-xxx, matched on the number
--   pct_vs_twin     this row's price against its twin's, shown on the SET row
--   old_price / new_price / pct_raised / batch_id   the last Applied price change line for this set
--
-- A package raised by hand on Customer Aquarium has no batch line, so it shows NO INCREASE ON RECORD: compare
-- pct_vs_twin before treating that as a miss.

with pkg as (
  select trim(h."SetCode") as code, h."PackageName" as name, round(h."PackagePrice", 2) as package_price,
         coalesce(h."SellOnline", false) as sell_online
    from public."CompleteAquariumSetHeader" h
   where nullif(trim(h."SetCode"), '') is not null
),
itm as (
  select trim(i."Code") as code, i."Name" as name, round(i."Price", 2) as item_price,
         round(i."RetailPrice", 2) as retail_price, coalesce(i."IsActive", false) as active,
         coalesce(i."HideFromSet", false) as hidden
    from public."Items" i
   where upper(trim(coalesce(i."CategoryCode", ''))) = 'SET'
),
latest as (
  select max(b."BatchId") as batch_id
    from public."PriceChangeBatches" b
    join public."PriceChangeBatchLines" l on l."BatchId" = b."BatchId"
   where b."Status" = 'Applied' and l."Kind" = 'set' and not l."Skipped"
),
base as (
  select coalesce(p.code, i.code) as code, coalesce(p.name, i.name) as name,
         p.code is not null as has_package,
         p.package_price, i.item_price, i.retail_price, coalesce(i.active, false) as active,
         coalesce(i.hidden, false) as hidden, coalesce(p.sell_online, false) as sell_online,
         case when coalesce(p.code, i.code) ilike 'AS-%' then 'SET-' || substr(coalesce(p.code, i.code), 4)
              when coalesce(p.code, i.code) ilike 'SET-%' then 'AS-' || substr(coalesce(p.code, i.code), 5) end as twin_code
    from pkg p
    full join itm i on lower(i.code) = lower(p.code)
),
joined as (
  select b.*, tp.package_price as twin_package_price, ti.item_price as twin_item_price,
         l."OldPrice" as old_price, l."NewPrice" as new_price, l."BatchId" as batch_id,
         l."Skipped" as skipped, l."SkipReason" as skip_reason,
         (select batch_id from latest) as latest_batch_id
    from base b
    left join pkg tp on lower(tp.code) = lower(b.twin_code)
    left join itm ti on lower(ti.code) = lower(b.twin_code)
    left join lateral (
      select x."OldPrice", x."NewPrice", x."BatchId", x."Skipped", x."SkipReason"
        from public."PriceChangeBatchLines" x
        join public."PriceChangeBatches" hdr on hdr."BatchId" = x."BatchId"
       where hdr."Status" = 'Applied' and x."Kind" = 'set' and lower(x."ItemCode") = lower(b.code)
       order by x."BatchId" desc
       limit 1
    ) l on true
),
rated as (
  select j.*,
         case
           when not has_package and active and not hidden then 'CHECK - CUSTOMERS AND STAFF SEE OLD PRICE (no package)'
           -- HideFromSet only covers Order Now and Alice's set list: staff_search_items_wildcard filters on IsActive alone.
           when not has_package and active then 'CHECK - STAFF CAN STILL PICK AT OLD PRICE (Conversations, Online Orders)'
           when not has_package and twin_package_price is not null then 'OK - old AS item, inactive, replaced by its SET'
           when not has_package then 'NOTE - inactive item with no package'
           when coalesce(package_price, 0) <= 0 then 'CHECK - PACKAGE PRICE IS ZERO'
           when item_price is distinct from package_price or retail_price is distinct from package_price
             then 'CHECK - ITEM PRICE DIFFERS FROM PACKAGE'
           when batch_id is null then 'CHECK - NO INCREASE ON RECORD'
           when skipped then 'CHECK - SKIPPED: ' || coalesce(skip_reason, 'no reason saved')
           when batch_id < latest_batch_id then 'CHECK - MISSED THE LATEST INCREASE'
           when round(new_price, 2) is distinct from package_price then 'NOTE - package edited after the increase'
           else 'OK - increased'
         end as status
    from joined j
)
select status, code, name, active, hidden, sell_online, package_price, item_price, retail_price,
       twin_code, coalesce(twin_package_price, twin_item_price) as twin_price,
       case when has_package and coalesce(twin_package_price, twin_item_price) > 0
            then round((package_price / coalesce(twin_package_price, twin_item_price) - 1) * 100, 1) end as pct_vs_twin,
       round(old_price, 2) as old_price, round(new_price, 2) as new_price,
       case when old_price > 0 then round((new_price / old_price - 1) * 100, 1) end as pct_raised,
       batch_id
  from rated
 order by case when status like 'CHECK%' then 1 when status like 'NOTE%' then 2 else 3 end, status, code;
