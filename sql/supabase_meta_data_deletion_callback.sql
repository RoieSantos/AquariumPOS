-- Meta Data Deletion Callback (app RSPetStopMessenger) - backend for the
-- supabase/functions/meta-data-deletion Edge Function.
--
-- When a user removes the app / asks Facebook to delete their data, Meta POSTs a signed_request
-- to the Edge Function. The function verifies it, calls meta_delete_user_data(<user_id>) below,
-- and answers Meta with a confirmation code + status URL (logged in MetaDataDeletionRequests).
--
-- What gets removed for an ID (matched against our Messenger PSID columns):
--   * Chat data - deleted outright (conversation, messages, follow-ups, reads, tags, contacts,
--     tool calls, ad referrals, calls, post comments, receipt acks, order-now tokens).
--   * Orders / sales records - KEPT (BIR), but the Facebook ID is blanked so the order is no
--     longer linked to the person's Facebook account. OnlineCustomers.FbID is blanked too.
-- Meta sends an APP-scoped ID; our tables store PAGE-scoped PSIDs. They are often different,
-- so a callback may legitimately find nothing - that's still a valid "completed" response.
--
-- Safe to re-run (create or replace / if not exists). Service role only - no anon/authenticated.

create table if not exists public."MetaDataDeletionRequests" (
  "ConfirmationCode" text primary key,
  "UserIdHash"       text not null,          -- sha256 of Meta's user_id; the raw ID is not kept
  "RequestedAtUtc"   timestamptz not null default now(),
  "CompletedAtUtc"   timestamptz,
  "Status"           text not null default 'Pending',   -- Pending / Completed / Failed
  "RowsAffected"     jsonb,
  "Error"            text
);

alter table public."MetaDataDeletionRequests" enable row level security;
revoke all on public."MetaDataDeletionRequests" from anon, authenticated;

create or replace function public.meta_delete_user_data(p_user_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id   text := trim(coalesce(p_user_id, ''));
  v_out  jsonb := '{}'::jsonb;
  v_n    integer;
begin
  if v_id = '' or v_id !~ '^[0-9]+$' then
    raise exception 'meta_delete_user_data: invalid user id';
  end if;

  -- Chat data: delete. Children first (most also cascade from ChatbotConversations).
  delete from "ChatbotMessages"          where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotMessages', v_n);
  delete from "ChatbotFollowUps"         where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotFollowUps', v_n);
  delete from "ChatbotLocationRequests"  where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotLocationRequests', v_n);
  delete from "ChatbotConversationReads" where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotConversationReads', v_n);
  delete from "ChatbotConversationTags"  where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotConversationTags', v_n);
  delete from "ChatbotCustomerContacts"  where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotCustomerContacts', v_n);
  delete from "ChatbotToolCalls"         where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotToolCalls', v_n);
  delete from "ChatbotAdReferrals"       where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotAdReferrals', v_n);
  delete from "ChatbotCalls"             where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotCalls', v_n);
  delete from "FacebookPostComments"     where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('FacebookPostComments', v_n);
  delete from "ReceiptAcknowledgements"  where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ReceiptAcknowledgements', v_n);
  delete from "OrderNowSessionTokens"    where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('OrderNowSessionTokens', v_n);
  delete from "ChatbotConversations"     where "Psid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('ChatbotConversations', v_n);

  -- Business records: keep the order, unlink the Facebook ID.
  update "AdvanceOrders"   set "CustomerPsid" = null where "CustomerPsid" = v_id; get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('AdvanceOrders.CustomerPsid', v_n);
  update "AutomatedOrders" set "Psid" = null        where "Psid" = v_id;         get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('AutomatedOrders.Psid', v_n);
  update "AutomatedOrders" set "GmaPsid" = null     where "GmaPsid" = v_id;      get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('AutomatedOrders.GmaPsid', v_n);
  update "OnlineOrders"    set "WalkinPsid" = null  where "WalkinPsid" = v_id;   get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('OnlineOrders.WalkinPsid', v_n);
  update "OnlineCustomers" set "FbID" = null        where "FbID" = v_id;         get diagnostics v_n = row_count; v_out := v_out || jsonb_build_object('OnlineCustomers.FbID', v_n);

  return v_out;
end;
$$;

revoke all on function public.meta_delete_user_data(text) from public, anon, authenticated;
grant execute on function public.meta_delete_user_data(text) to service_role;

-- Check: confirm both objects exist (ONE result).
select 'table' as section, count(*)::text as found from information_schema.tables where table_schema = 'public' and table_name = 'MetaDataDeletionRequests'
union all
select 'function', count(*)::text from pg_proc where proname = 'meta_delete_user_data';
