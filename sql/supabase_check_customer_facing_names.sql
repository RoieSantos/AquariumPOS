-- READ-ONLY check: customer-facing product names that look like internal codes - per the website
-- review ("75GALLONS-AQUARIUM-6MM (OVERHEAD COMPETE SETUP SET" reads like a warehouse label, not a
-- product). Lists every name a customer can see on rspetstop.com (homepage, product pages, Order
-- Now, set "What's included" lists) that is ALL CAPS, joins words with hyphens, or has an unclosed
-- bracket, plus a rough suggested rewrite to start from. Changes nothing.
--
-- Where to fix each one ("fix_on" column):
--   * Customer Aquarium page  - a SET's name (its Package Name; the SET-xxx item follows it), and
--                               each line of a set's contents ("What's included" shows the line's
--                               Item Name, not the item's own name).
--   * Item Setup              - every other product's Name.
-- Note: the POS pulls names from the portal, so a rename also shows on new receipts.
--
-- "suggested" is mechanical (hyphens -> spaces, Title Case, closes a bracket) - always read it
-- over before using; it won't fix typos like "COMPETE" -> "COMPLETE" (those are flagged in
-- "problems" only when obvious ones are found below).
--
-- Safe to run any time. Ends in ONE result.

with visible_items as (
  -- What the website can show: active, not hidden, and either in an Order Now category or has a
  -- photo (photo items appear in Best Sellers / product pages even when in-store only).
  select i."Code" as code,
         upper(trim(coalesce(i."CategoryCode", ''))) as category,
         coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code") as name
  from public."Items" i
  where i."IsActive" is true
    and i."HideFromSet" is not true
    and (upper(trim(coalesce(i."CategoryCode", ''))) in ('SET', 'AQUARIUM', 'STAND', 'PUMP', 'LIGHTS')
         or nullif(trim(coalesce(i."Images", '')), '') is not null)
),
set_lines as (
  -- Same display-name rule as public_list_aquarium_sets() (supabase_chatbot_list_aquarium_sets_parts.sql),
  -- only for sets sold online.
  select h."SetCode" as set_code, h."PackageName" as package_name, l."EntryNo" as entry_no, l."ItemNo" as item_no,
         case
           when nullif(trim(l."ItemName"), '') is null
             or trim(l."ItemName") ~ '^[0-9.]+$'
             or upper(trim(l."ItemName")) like upper(trim(l."ItemNo")) || '%'
             then coalesce(nullif(trim(it."Name"), ''), nullif(trim(it."Description"), ''), 'part')
           else trim(l."ItemName")
         end as name
  from public."CompleteAquariumSetLine" l
  join public."CompleteAquariumSetHeader" h on h."PackageName" = l."PackageName"
  left join public."Items" it on it."Code" = l."ItemNo"
  where h."SellOnline" is true
    and trim(coalesce(l."ItemNo", '')) <> ''
),
candidates as (
  select case when category = 'SET' then '1. set name' else '2. product name' end as section,
         case when category = 'SET' then 'Customer Aquarium page (Package Name)' else 'Item Setup (Name)' end as fix_on,
         code, category, null::text as used_in_set, name
  from visible_items
  union all
  select '3. set contents line', 'Customer Aquarium page (set line Item Name)',
         item_no, 'SET PART', set_code || ' - ' || package_name, name
  from set_lines
),
checked as (
  select c.*,
    concat_ws(', ',
      case when c.name = upper(c.name) and c.name ~ '[A-Z]{3}' then 'ALL CAPS' end,
      case when c.name ~ '[A-Za-z0-9]-[A-Za-z0-9]' then 'words-joined-by-hyphens' end,
      case when length(regexp_replace(c.name, '[^(]', '', 'g')) <> length(regexp_replace(c.name, '[^)]', '', 'g'))
           then 'unclosed bracket' end,
      case when c.name ~ '\(\s|\s\)|\s{2,}' then 'extra spaces' end,
      case when c.name ~* '\mCOMPETE\M' then 'typo? COMPETE -> COMPLETE' end
    ) as problems
  from candidates c
)
select section, fix_on, code, category, used_in_set, name as current_name, problems,
       -- Mechanical starting point only - read it over before using.
       regexp_replace(regexp_replace(
         initcap(regexp_replace(regexp_replace(name, '\mCOMPETE\M', 'COMPLETE', 'gi'), '-', ' ', 'g'))
         || case when length(regexp_replace(name, '[^(]', '', 'g')) > length(regexp_replace(name, '[^)]', '', 'g')) then ')' else '' end,
         '\(\s+', '(', 'g'), '\s{2,}', ' ', 'g') as suggested
from checked
where problems <> ''
order by section, category, used_in_set nulls first, current_name;
