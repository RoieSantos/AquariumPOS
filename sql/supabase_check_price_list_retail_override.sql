-- Read-only check for the Conversations "Retail price list" button (js/gmaConversations.js insertPriceList).
-- That list quotes coalesce(RetailPrice, Price) - RetailPrice (from the desktop POS) wins whenever it is set,
-- but an Item Setup price edit only changes Price. Rows here are Aquarium / Stand / Sump items whose
-- price list (and Alice / Order Now) would still show the RetailPrice, not the Item Setup Price.
-- Ends with ONE result: a 'summary' row, then one 'item' row per affected item.

select 'summary'::text as section, null::text as code, null::text as name,
       count(*)::text as price, null::text as retail_price_shown
from public."Items"
where "IsActive" is true
  and trim(coalesce("CategoryCode", '')) in ('AQUARIUM', 'STAND', 'SUMP')
  and "RetailPrice" is not null
  and "RetailPrice" <> coalesce("Price", 0)
union all
select 'item', "Code"::text, "Name"::text, "Price"::text, "RetailPrice"::text
from public."Items"
where "IsActive" is true
  and trim(coalesce("CategoryCode", '')) in ('AQUARIUM', 'STAND', 'SUMP')
  and "RetailPrice" is not null
  and "RetailPrice" <> coalesce("Price", 0)
order by 1 desc, 2;
