-- Save contact numbers found in past Messenger chats into the customers' Contacts & Addresses -
-- per "is there a way that we can run a query to grab the details of the previous customers? so we
-- can save it to customer master table?".
--
-- One-off backfill for chats from before the live auto-fill (facebook-messenger-webhook/mood.ts).
-- Same rules as that auto-fill and as supabase_gma_customer_contacts_chat_scan_preview.sql (run the
-- preview first to see exactly what this adds):
--   * only PH mobile numbers the CUSTOMER typed;
--   * never the shop's numbers (Company / branch Contact No., staff phones, Store Info numbers);
--   * never a number the store / bot / staff sent in that chat before the customer typed it.
-- Each number is added to the list (Source 'Chat', first / last used = when they typed it). A
-- customer with no Contact No. yet gets their most recently typed one as the default; an existing
-- default is never changed. Addresses aren't scanned (free text needs the AI).
--
-- Run AFTER supabase_gma_customer_contacts.sql. Safe to re-run (already-saved numbers are only
-- touched, never duplicated).

with shop_numbers as (
  select distinct public.gma_normalize_phone(m[1]) as phone
  from (
    select "ContactNo" as t from public."CompanyInfo"
    union all select "ContactNo" from public."Warehouses"
    union all select "PhoneNumber" from public."StaffUsers"
    union all select row_to_json(s)::text from public."ChatbotStoreInfo" s
  ) src
  cross join lateral regexp_matches(coalesce(src.t, ''), '(?:\+?63|0)?[ -]*9[0-9]{2}[ -]*[0-9]{3}[ -]*[0-9]{4}', 'g') m
),
mentions as (
  select msg."Psid", msg."Role", msg."CreatedAtUtc",
         public.gma_normalize_phone(m[1]) as phone
  from public."ChatbotMessages" msg
  cross join lateral regexp_matches(msg."Content", '(?:^|[^0-9])((?:\+?63|0)?[ -]*9[0-9]{2}[ -]*[0-9]{3}[ -]*[0-9]{4})(?![0-9])', 'g') m
),
first_mention as (
  select distinct on ("Psid", phone) "Psid", phone, "Role" as first_role
  from mentions
  where phone ~ '^09[0-9]{9}$'
  order by "Psid", phone, "CreatedAtUtc"
),
found as (
  select mn."Psid", mn.phone, min(mn."CreatedAtUtc") as first_said, max(mn."CreatedAtUtc") as last_said
  from mentions mn
  join first_mention f on f."Psid" = mn."Psid" and f.phone = mn.phone and f.first_role = 'user'
  where mn."Role" = 'user'
    and not exists (select 1 from shop_numbers s where s.phone = mn.phone)
  group by mn."Psid", mn.phone
)
select count(public.gma_upsert_customer_contact(f."Psid", 'Phone', f.phone, 'Chat', false, f.first_said))
     + count(public.gma_upsert_customer_contact(f."Psid", 'Phone', f.phone, 'Chat', false, f.last_said)) as touched
from found f
join public."ChatbotConversations" c on c."Psid" = f."Psid";

-- Customers with no Contact No. yet: their most recently typed number becomes the default (the
-- trigger marks it default in the list).
update public."ChatbotConversations" c
set "CustomerPhone" = x."Value"
from (
  select distinct on (cc."Psid") cc."Psid", cc."Value"
  from public."ChatbotCustomerContacts" cc
  where cc."Kind" = 'Phone' and cc."Source" = 'Chat'
  order by cc."Psid", cc."LastSeenAtUtc" desc
) x
where x."Psid" = c."Psid" and nullif(trim(c."CustomerPhone"), '') is null;

-- Result - one row.
select (select count(*) from public."ChatbotCustomerContacts" where "Kind" = 'Phone') as numbers_in_list,
       (select count(*) from public."ChatbotConversations" where nullif(trim("CustomerPhone"), '') is not null) as customers_with_contact_no,
       (select count(*) from public."ChatbotConversations") as customers_total;
