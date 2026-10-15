-- READ-ONLY preview: contact numbers found in past Messenger chats - per "is there a way that we can
-- run a query to grab the details of the previous customers? so we can save it to customer master
-- table?". Nothing is changed - run supabase_gma_customer_contacts_chat_scan.sql to save them.
--
-- Same rules as the live auto-fill (facebook-messenger-webhook/mood.ts):
--   * only PH mobile numbers the CUSTOMER typed (ChatbotMessages.Role = 'user');
--   * never the shop's numbers - Company Information / branch Contact No., staff phone numbers, or
--     any number in AI Bot Setup > Store Info (GCash, bank, pickup contacts);
--   * never a number the store / bot / staff sent in that chat BEFORE the customer typed it (a GCash
--     number the customer repeats back) - one the customer typed first is still theirs.
-- will_be_default = yes for the most recent number of a customer who has no Contact No. yet.
-- Addresses aren't scanned - free text needs the AI, not a pattern.

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
  select msg."Psid", msg."Role", msg."Content", msg."CreatedAtUtc",
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
  select mn."Psid", mn.phone, min(mn."CreatedAtUtc") as first_said, max(mn."CreatedAtUtc") as last_said,
         (array_agg(left(mn."Content", 120) order by mn."CreatedAtUtc" desc))[1] as latest_message
  from mentions mn
  join first_mention f on f."Psid" = mn."Psid" and f.phone = mn.phone and f.first_role = 'user'
  where mn."Role" = 'user'
    and not exists (select 1 from shop_numbers s where s.phone = mn.phone)
  group by mn."Psid", mn.phone
),
ranked as (
  select f.*, row_number() over (partition by f."Psid" order by f.last_said desc) as rn
  from found f
)
select coalesce(c."CustomerName", '(no name)')::text as customer,
       r.phone as contact_no,
       case when exists (select 1 from public."ChatbotCustomerContacts" x
                         where x."Psid" = r."Psid" and x."Kind" = 'Phone' and x."ValueKey" = r.phone)
            then 'already saved' else 'new' end as status,
       case when r.rn = 1 and nullif(trim(c."CustomerPhone"), '') is null then 'yes' else '' end as will_be_default,
       r.first_said, r.last_said, r.latest_message
from ranked r
join public."ChatbotConversations" c on c."Psid" = r."Psid"
order by status desc, r.last_said desc;
