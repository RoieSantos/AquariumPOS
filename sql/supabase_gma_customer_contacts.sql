-- Customer contacts & addresses (several per customer) - per "will it save mutiple contacts? and
-- multiple address?" -> "yes please".
--
-- Before: one ChatbotConversations.CustomerPhone / CustomerAddress per customer - a new one
-- overwrote the old. Now every number / address a customer has used is kept in
-- ChatbotCustomerContacts (like BC's ship-to addresses), one row per value, with where it came from
-- (Chat / Order / Pancake / Staff), first / last seen, an optional label (Home, Work, ...) and ONE
-- default per kind.
--
-- The default IS ChatbotConversations.CustomerPhone / CustomerAddress - those columns stay as they
-- were, so the Customers list, Create Order, the bot's save_customer_info / order-privacy check and
-- the chat auto-fill (facebook-messenger-webhook/mood.ts) need no change to keep working. A trigger
-- copies whatever lands in them into the list and marks it default; the old value stays in the list.
-- Another trigger adds every order's number / delivery address (not as default).
-- Staff manage the list on the Customer Card (docs/customers.html): add, edit, label, set default,
-- delete. "Set default" just writes the value back into CustomerPhone / CustomerAddress.
--
-- Backfills from existing chats (default), every past order, and Pancake customers.
-- Run AFTER supabase_gma_customer_card.sql. Safe to re-run. Needs docs/js/customers.js ?v=5 and the
-- facebook-messenger-webhook deploy (it saves every number a customer gives, not just one).

create table if not exists public."ChatbotCustomerContacts" (
  "Id" bigint generated always as identity primary key,
  "Psid" text not null,
  "Kind" varchar(10) not null check ("Kind" in ('Phone', 'Address')),
  "Value" varchar(500) not null,
  "ValueKey" text not null,              -- normalized for de-duplication (see gma_contact_value_key)
  "Label" varchar(50),
  "Source" varchar(20) not null default 'Chat',
  "IsDefault" boolean not null default false,
  "FirstSeenAtUtc" timestamptz not null default now(),
  "LastSeenAtUtc" timestamptz not null default now(),
  "UpdatedBy" varchar(100)
);
create unique index if not exists "UX_ChatbotCustomerContacts_Value" on public."ChatbotCustomerContacts" ("Psid", "Kind", "ValueKey");
create unique index if not exists "UX_ChatbotCustomerContacts_Default" on public."ChatbotCustomerContacts" ("Psid", "Kind") where "IsDefault";

-- Only reachable through the security-definer functions below.
alter table public."ChatbotCustomerContacts" enable row level security;

comment on table public."ChatbotCustomerContacts" is 'Every contact number / address a Messenger customer has used. The default per kind mirrors ChatbotConversations.CustomerPhone / CustomerAddress (kept in sync by trg_chatbot_conversations_contacts).';


-- 09xxxxxxxxx for a PH mobile in any common form; otherwise the trimmed value.
create or replace function public.gma_normalize_phone(p_value text)
returns text
language sql
immutable
as $$
  select case
    when d ~ '^09[0-9]{9}$' then d
    when d ~ '^639[0-9]{9}$' then '0' || substr(d, 3)
    when d ~ '^9[0-9]{9}$' then '0' || d
    else trim(coalesce(p_value, ''))
  end
  from (select regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g') as d) x;
$$;

create or replace function public.gma_contact_value_key(p_kind text, p_value text)
returns text
language sql
immutable
as $$
  select case when p_kind = 'Phone'
    then regexp_replace(public.gma_normalize_phone(p_value), '[^0-9]', '', 'g')
    else lower(regexp_replace(trim(coalesce(p_value, '')), '[\s,.]+', ' ', 'g'))
  end;
$$;


-- Add (or touch) one contact; optionally make it that kind's default. Internal - used by the
-- triggers, the staff RPCs and the webhook (service role).
create or replace function public.gma_upsert_customer_contact(
  p_psid text,
  p_kind text,
  p_value text,
  p_source text,
  p_make_default boolean,
  p_seen_at timestamptz default now()
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_value text := left(case when p_kind = 'Phone' then public.gma_normalize_phone(p_value)
                            else regexp_replace(trim(coalesce(p_value, '')), '\s+', ' ', 'g') end, 500);
  v_key text := public.gma_contact_value_key(p_kind, p_value);
  v_seen timestamptz := coalesce(p_seen_at, now());
  v_id bigint;
begin
  if coalesce(trim(p_psid), '') = '' or p_kind not in ('Phone', 'Address') or v_key = '' then
    return null;
  end if;

  insert into public."ChatbotCustomerContacts" ("Psid", "Kind", "Value", "ValueKey", "Source", "FirstSeenAtUtc", "LastSeenAtUtc")
  values (trim(p_psid), p_kind, v_value, v_key, coalesce(nullif(trim(p_source), ''), 'Chat'), v_seen, v_seen)
  on conflict ("Psid", "Kind", "ValueKey") do update
    set "FirstSeenAtUtc" = least(public."ChatbotCustomerContacts"."FirstSeenAtUtc", excluded."FirstSeenAtUtc"),
        "LastSeenAtUtc" = greatest(public."ChatbotCustomerContacts"."LastSeenAtUtc", excluded."LastSeenAtUtc")
  returning "Id" into v_id;

  if p_make_default then
    -- Two statements: the one-default-per-kind index is checked row by row.
    update public."ChatbotCustomerContacts" set "IsDefault" = false
    where "Psid" = trim(p_psid) and "Kind" = p_kind and "IsDefault" and "Id" <> v_id;
    update public."ChatbotCustomerContacts" set "IsDefault" = true where "Id" = v_id and not "IsDefault";
  end if;
  return v_id;
end;
$$;

revoke all on function public.gma_upsert_customer_contact(text, text, text, text, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.gma_upsert_customer_contact(text, text, text, text, boolean, timestamptz) to service_role;


-- CustomerPhone / CustomerAddress changed (bot, auto-fill, Customer Card, Set Default...) -> into
-- the list as the default. Source: 'Staff' when a staff RPC set app.contact_source, else 'Chat'.
-- Cleared -> nothing is default for that kind (the old row stays in the list).
create or replace function public.trg_chatbot_conversations_contacts()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_source text := coalesce(nullif(current_setting('app.contact_source', true), ''), 'Chat');
begin
  if tg_op = 'INSERT' or new."CustomerPhone" is distinct from old."CustomerPhone" then
    if nullif(trim(new."CustomerPhone"), '') is null then
      update public."ChatbotCustomerContacts" set "IsDefault" = false where "Psid" = new."Psid" and "Kind" = 'Phone' and "IsDefault";
    else
      perform public.gma_upsert_customer_contact(new."Psid", 'Phone', new."CustomerPhone", v_source, true);
    end if;
  end if;
  if tg_op = 'INSERT' or new."CustomerAddress" is distinct from old."CustomerAddress" then
    if nullif(trim(new."CustomerAddress"), '') is null then
      update public."ChatbotCustomerContacts" set "IsDefault" = false where "Psid" = new."Psid" and "Kind" = 'Address' and "IsDefault";
    else
      perform public.gma_upsert_customer_contact(new."Psid", 'Address', new."CustomerAddress", v_source, true);
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_chatbot_conversations_contacts on public."ChatbotConversations";
create trigger trg_chatbot_conversations_contacts
  after insert or update of "CustomerPhone", "CustomerAddress" on public."ChatbotConversations"
  for each row execute function public.trg_chatbot_conversations_contacts();


-- Every order's number / delivery address joins the customer's list (not as default).
create or replace function public.trg_automated_orders_contacts()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_psid text := coalesce(nullif(trim(new."GmaPsid"), ''), nullif(trim(new."Psid"), ''));
begin
  if v_psid is null or not exists (select 1 from public."ChatbotConversations" c where c."Psid" = v_psid) then
    return null;
  end if;
  perform public.gma_upsert_customer_contact(v_psid, 'Phone', new."CustomerPhone", 'Order', false, new."CreatedAtUtc");
  perform public.gma_upsert_customer_contact(v_psid, 'Address', new."DeliveryAddress", 'Order', false, new."CreatedAtUtc");
  return null;
exception when others then
  -- Never block saving an order over the contact list.
  raise warning 'trg_automated_orders_contacts: %', sqlerrm;
  return null;
end;
$$;

drop trigger if exists trg_automated_orders_contacts on public."AutomatedOrders";
create trigger trg_automated_orders_contacts
  after insert or update of "CustomerPhone", "DeliveryAddress", "GmaPsid", "Psid" on public."AutomatedOrders"
  for each row execute function public.trg_automated_orders_contacts();


-- ---------------------------------------------------------------------------
-- Backfill (re-run safe - upserts only touch first/last seen).
-- ---------------------------------------------------------------------------
select count(public.gma_upsert_customer_contact(c."Psid", k.kind, k.value, 'Order', false, o."CreatedAtUtc"))
from public."AutomatedOrders" o
join public."ChatbotConversations" c
  on (o."GmaPsid" = c."Psid" and o."GmaPageId" = c."PageId") or o."Psid" = c."Psid"
cross join lateral (values ('Phone', o."CustomerPhone"), ('Address', o."DeliveryAddress")) k(kind, value)
where nullif(trim(k.value), '') is not null;

select count(public.gma_upsert_customer_contact(c."Psid", k.kind, k.value, 'Pancake', false, coalesce(oc."UpdatedAt", now())))
from public."ChatbotConversations" c
join public."OnlineCustomers" oc on oc."FbID" = c."Psid" or oc."FbID" = c."PageId" || '_' || c."Psid"
cross join lateral (values ('Phone', oc."PrimaryPhoneNumber"), ('Address', oc."PrimaryAddress")) k(kind, value)
where nullif(trim(k.value), '') is not null;

-- The record's current values are the defaults.
select count(public.gma_upsert_customer_contact(c."Psid", k.kind, k.value, 'Chat', true, coalesce(c."LastCustomerMessageAtUtc", c."CreatedAtUtc")))
from public."ChatbotConversations" c
cross join lateral (values ('Phone', c."CustomerPhone"), ('Address', c."CustomerAddress")) k(kind, value)
where nullif(trim(k.value), '') is not null;


-- ---------------------------------------------------------------------------
-- Staff RPCs for the Customer Card - super users only, like the Customers page.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_gma_customer_contacts(text, text, text);

create or replace function public.admin_list_gma_customer_contacts(
  p_admin_username text,
  p_admin_password text,
  p_psid text
)
returns table(id bigint, kind text, value text, label text, source text, is_default boolean,
              first_seen_at_utc timestamptz, last_seen_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select x."Id", x."Kind"::text, x."Value"::text, x."Label"::text, x."Source"::text, x."IsDefault",
           x."FirstSeenAtUtc", x."LastSeenAtUtc"
    from public."ChatbotCustomerContacts" x
    where x."Psid" = trim(coalesce(p_psid, ''))
    order by x."Kind" desc, x."IsDefault" desc, x."LastSeenAtUtc" desc;   -- Phone first, then Address
end;
$$;

grant execute on function public.admin_list_gma_customer_contacts(text, text, text) to anon;


-- Add (p_id null) or edit a contact; p_make_default also makes it the customer's default.
drop function if exists public.admin_save_gma_customer_contact(text, text, text, bigint, text, text, text, boolean);

create or replace function public.admin_save_gma_customer_contact(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_id bigint,
  p_kind text,
  p_value text,
  p_label text,
  p_make_default boolean
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_psid text := trim(coalesce(p_psid, ''));
  v_value text := regexp_replace(trim(coalesce(p_value, '')), '\s+', ' ', 'g');
  v_label text := nullif(trim(coalesce(p_label, '')), '');
  v_key text;
  v_id bigint := p_id;
  v_was_default boolean := false;
  v_kind text := p_kind;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not exists (select 1 from public."ChatbotConversations" where "Psid" = v_psid) then
    raise exception 'Customer not found.';
  end if;
  if v_id is not null then
    select "Kind", "IsDefault" into v_kind, v_was_default
    from public."ChatbotCustomerContacts" where "Id" = v_id and "Psid" = v_psid;
    if not found then raise exception 'That contact no longer exists - reload the card.'; end if;
  end if;
  if v_kind not in ('Phone', 'Address') then raise exception 'Kind must be Phone or Address.'; end if;
  if v_value = '' then raise exception 'Enter a value.'; end if;
  if v_kind = 'Phone' and regexp_replace(v_value, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Contact No. must be a mobile number like 09171234567.';
  end if;
  if length(v_value) > 500 then raise exception 'Address is too long (500 characters max).'; end if;
  if length(coalesce(v_label, '')) > 50 then raise exception 'Label is too long (50 characters max).'; end if;

  v_key := public.gma_contact_value_key(v_kind, v_value);
  if exists (select 1 from public."ChatbotCustomerContacts"
             where "Psid" = v_psid and "Kind" = v_kind and "ValueKey" = v_key and "Id" is distinct from v_id) then
    raise exception 'This customer already has that %.', case when v_kind = 'Phone' then 'number' else 'address' end;
  end if;

  if v_kind = 'Phone' then v_value := public.gma_normalize_phone(v_value); end if;

  if v_id is null then
    insert into public."ChatbotCustomerContacts" ("Psid", "Kind", "Value", "ValueKey", "Label", "Source", "UpdatedBy")
    values (v_psid, v_kind, left(v_value, 500), v_key, v_label, 'Staff', p_admin_username)
    returning "Id" into v_id;
  else
    update public."ChatbotCustomerContacts"
    set "Value" = left(v_value, 500), "ValueKey" = v_key, "Label" = v_label, "UpdatedBy" = p_admin_username
    where "Id" = v_id;
  end if;

  -- The default lives on the conversation record; the trigger marks the row default from it.
  if coalesce(p_make_default, false) or v_was_default then
    perform set_config('app.contact_source', 'Staff', true);
    if v_kind = 'Phone' then
      update public."ChatbotConversations" set "CustomerPhone" = v_value where "Psid" = v_psid;
    else
      update public."ChatbotConversations" set "CustomerAddress" = v_value where "Psid" = v_psid;
    end if;
  end if;
  return v_id;
end;
$$;

grant execute on function public.admin_save_gma_customer_contact(text, text, text, bigint, text, text, text, boolean) to anon;


-- Delete a contact. Deleting the default makes the most recently used remaining one the default
-- (or clears it when none are left).
drop function if exists public.admin_delete_gma_customer_contact(text, text, text, bigint);

create or replace function public.admin_delete_gma_customer_contact(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_psid text := trim(coalesce(p_psid, ''));
  v_kind text;
  v_was_default boolean;
  v_next text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  delete from public."ChatbotCustomerContacts" where "Id" = p_id and "Psid" = v_psid
  returning "Kind", "IsDefault" into v_kind, v_was_default;
  if not found or not v_was_default then
    return;
  end if;

  select "Value" into v_next from public."ChatbotCustomerContacts"
  where "Psid" = v_psid and "Kind" = v_kind
  order by "LastSeenAtUtc" desc limit 1;
  perform set_config('app.contact_source', 'Staff', true);
  if v_kind = 'Phone' then
    update public."ChatbotConversations" set "CustomerPhone" = v_next where "Psid" = v_psid;
  else
    update public."ChatbotConversations" set "CustomerAddress" = v_next where "Psid" = v_psid;
  end if;
end;
$$;

grant execute on function public.admin_delete_gma_customer_contact(text, text, text, bigint) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'Contacts saved' as section, count(*)::text as value from public."ChatbotCustomerContacts"
union all
select 'Customers with 2+ numbers', count(*)::text from (
  select "Psid" from public."ChatbotCustomerContacts" where "Kind" = 'Phone' group by "Psid" having count(*) > 1) x
union all
select 'Customers with 2+ addresses', count(*)::text from (
  select "Psid" from public."ChatbotCustomerContacts" where "Kind" = 'Address' group by "Psid" having count(*) > 1) x;
