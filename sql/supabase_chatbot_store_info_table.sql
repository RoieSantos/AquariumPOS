-- AI Messenger chatbot: store info the bot recites to customers (hours/delivery/payment/pickup),
-- kept editable by staff without a code deploy. Deliberately separate from public."CompanyInfo"
-- (supabase_company_info_table.sql) rather than adding columns there - CompanyInfo is letterhead
-- data shown on printed documents/Login page; this is conversational content specific to the
-- chatbot, and keeping it in its own table means editing one doesn't risk the other.
--
-- Single-row settings table, same shape/trust posture as CompanyInfo: public read (this is
-- exactly what the bot is meant to tell any customer who asks), write only through a staff-gated
-- RPC. Read by supabase/functions/facebook-messenger-webhook once per request (alongside
-- CompanyInfo) and folded into Claude's system prompt as plain text - never exposed as an LLM
-- tool, since it's small and near-static and belongs in the cached prompt prefix rather than a
-- live round trip.

create table if not exists public."ChatbotStoreInfo" (
    "Id" smallint primary key default 1 check ("Id" = 1),
    "BusinessHours" text,
    "DeliveryPolicy" text,
    "PaymentMethods" text,
    "PickupLocations" text,
    "AdditionalNotes" text,
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

alter table public."ChatbotStoreInfo" enable row level security;

drop policy if exists "Public read" on public."ChatbotStoreInfo";
create policy "Public read" on public."ChatbotStoreInfo"
    for select to anon, authenticated using (true);

-- No insert/update/delete policy for anon/authenticated - writes only via the RPC below.
revoke insert, update, delete on public."ChatbotStoreInfo" from anon, authenticated;

comment on table public."ChatbotStoreInfo" is 'Single-row chatbot FAQ content (hours/delivery/payment/pickup) - publicly readable, edited only via admin_upsert_chatbot_store_info.';

drop function if exists public.admin_upsert_chatbot_store_info(text, text, text, text, text, text, text);

create or replace function public.admin_upsert_chatbot_store_info(
  p_admin_username text,
  p_admin_password text,
  p_business_hours text,
  p_delivery_policy text,
  p_payment_methods text,
  p_pickup_locations text,
  p_additional_notes text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  insert into public."ChatbotStoreInfo"
    ("Id", "BusinessHours", "DeliveryPolicy", "PaymentMethods", "PickupLocations", "AdditionalNotes", "UpdatedBy", "UpdatedAtUtc")
  values
    (1, p_business_hours, p_delivery_policy, p_payment_methods, p_pickup_locations, p_additional_notes, p_admin_username, now())
  on conflict ("Id") do update set
    "BusinessHours" = excluded."BusinessHours",
    "DeliveryPolicy" = excluded."DeliveryPolicy",
    "PaymentMethods" = excluded."PaymentMethods",
    "PickupLocations" = excluded."PickupLocations",
    "AdditionalNotes" = excluded."AdditionalNotes",
    "UpdatedBy" = excluded."UpdatedBy",
    "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

grant execute on function public.admin_upsert_chatbot_store_info(text, text, text, text, text, text, text) to anon;
