-- To-Ship customer messages failing with "HTTP request cancelled" - per "can you check this sent
-- to-ship message it did not sent to customer" / "once the user click ready-to ship ... it did not send
-- to customer the message.. is it connection issue?" (order 105852).
--
-- "HTTP request cancelled" is the http extension being stopped by the database time limit mid-call,
-- not a Pancake reply:
--   - admin_send_online_order_message (the To-Ship Message dialog's Send) had no statement_timeout of
--     its own, so it ran under the website role's default of a few seconds - a slow Pancake messaging
--     call was cut off. It now gets 30s (its own curl timeout is 15s).
--   - Ready to Ship sends the message LAST inside admin_update_online_order_status /
--     admin_ship_online_order_from_stock (50-60s limit), after the Pancake status update and its
--     payment snapshot/write-back. When Pancake is slow the time runs out on the message. That's handled
--     on the page (js/onlineOrders.js): if the message didn't go, it's re-sent right away as its own call
--     (this function), and if that fails too the To-Ship Message dialog opens prefilled.
--
-- Same body - only the time limit changes. Safe to re-run.

alter function public.admin_send_online_order_message(text, text, text, text) set statement_timeout = '30000';
alter function public.admin_render_online_order_to_ship_message(text, text, text) set statement_timeout = '15000';
