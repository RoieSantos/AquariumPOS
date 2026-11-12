-- READ-ONLY check - per "in the xendit reference id i cannot find any reference link into the gcash transaction
-- details.. how can they know if thats the reference no. that we send?"
--
-- Our ReferenceID (RSPS-PAY-...) and Xendit's payout ID never appear in the GCash app - GCash / the bank prints its
-- own Ref No. This shows what Xendit actually sent back (XenditPayouts.LastResponse, saved from the create answer /
-- webhook) for the latest paid salary / advance payouts, so we can see whether it includes the channel's own
-- reference (e.g. a "connector_reference"-style field) to put on the receipt.
--
-- Changes nothing. Safe to run any time. Ends with ONE result.

select x."Kind" as kind,
       coalesce(x."DisplayName", x."Username") as employee,
       x."Amount" as amount,
       coalesce(x."ChannelName", x."ChannelCode") as channel,
       x."PaidAtUtc" as paid_at,
       x."IsTest" as is_test,
       (select string_agg(k, ', ' order by k) from jsonb_object_keys(coalesce(x."LastResponse", '{}'::jsonb)) k) as fields_xendit_sent,
       x."LastResponse" as xendit_reply
from public."XenditPayouts" x
where x."Kind" in ('Salary', 'Advance') and x."Status" = 'SUCCEEDED'
order by x."PaidAtUtc" desc nulls last
limit 10;
