-- Fixes "canceling statement due to statement timeout" on GMA Conversations' Create Order - per "why i
-- cannot create an order on gma conversations".
--
-- admin_create_gma_conversation_order (and admin_update_automated_order, used by Edit Order) push the
-- order to Pancake synchronously via _push_automated_order_to_pancake: up to 3 attempts x 20s call
-- timeout + 1.5s pauses (~63s worst case, a few seconds normally). Neither function overrides
-- statement_timeout, so they run under the anon role's short default (a few seconds) - whenever Pancake
-- is slow, Postgres cancels the whole call and rolls it back (no order is created, so retrying is safe).
-- Same fix the other Pancake-calling RPCs already use (e.g. admin_update_online_order_status): set the
-- timeout on the function itself.
--
-- ALTER only - bodies unchanged, no table locks. Re-creating either function (CREATE OR REPLACE without
-- a SET clause, or DROP + CREATE) clears this setting - re-run this file after any file that redefines
-- them (e.g. supabase_gma_conversations_staff_rpc_access.sql).

alter function public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb)
  set statement_timeout = '90000';

alter function public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb)
  set statement_timeout = '90000';

-- The order popup's "Retry Push to Pancake" button - same synchronous push, same problem (AO-00023
-- retry: "canceling statement due to statement timeout"). A cancelled retry rolls back, so the order
-- just stays Failed and can be retried again.
alter function public.admin_retry_automated_order_pancake_push(text, text, text)
  set statement_timeout = '90000';
