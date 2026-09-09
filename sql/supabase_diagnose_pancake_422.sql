-- Diagnostics for the "portal 422s but the same payload succeeds in Postman" Pancake
-- order-creation failure (AO-00006, AO-00011, ...). Run these AFTER re-running
-- supabase_automated_orders_tables.sql (which adds AutomatedOrders."PancakeLastPayload",
-- suppresses libcurl's automatic Expect: 100-continue, and sets a real User-Agent).

-- ---------------------------------------------------------------------------
-- 1. Did the header/Expect change fix it? Latest push outcome per order.
-- ---------------------------------------------------------------------------
select "OrderNo", "PancakeSyncStatus", "PancakeOrderId", left("PancakeSyncError", 200) as error_head, "CreatedAtUtc"
from public."AutomatedOrders"
order by "CreatedAtUtc" desc
limit 10;

-- ---------------------------------------------------------------------------
-- 2. The EXACT bytes we sent, plus the two numbers that matter for the
--    Expect: 100-continue theory (libcurl adds that header unprompted once the
--    body exceeds 1024 bytes - if octet_length is over ~1024, that header was
--    in play on every previous attempt).
-- ---------------------------------------------------------------------------
select
  "OrderNo",
  "PancakeSyncStatus",
  octet_length("PancakeLastPayload") as payload_bytes,
  length("PancakeLastPayload")       as payload_chars,
  md5("PancakeLastPayload")          as payload_md5,
  "PancakeLastPayload"
from public."AutomatedOrders"
where "PancakeLastPayload" is not null
order by "CreatedAtUtc" desc
limit 1;

-- ---------------------------------------------------------------------------
-- 3. Byte-for-byte comparison against what Postman actually sent.
--    Paste the body you used in Postman between the $pm$ markers below, then run.
--    Matching md5 => the bodies are identical and the difference really is
--    transport-level (headers/Expect/User-Agent), not content.
--    Differing md5 => the diff output shows exactly which characters differ.
-- ---------------------------------------------------------------------------
with ours as (
  select "PancakeLastPayload" as body
  from public."AutomatedOrders"
  where "PancakeLastPayload" is not null
  order by "CreatedAtUtc" desc
  limit 1
),
postman as (
  select $pm$PASTE_YOUR_POSTMAN_BODY_HERE$pm$::text as body
)
select
  md5(ours.body)                as ours_md5,
  md5(postman.body)             as postman_md5,
  md5(ours.body) = md5(postman.body) as bodies_identical,
  octet_length(ours.body)       as ours_bytes,
  octet_length(postman.body)    as postman_bytes
from ours, postman;

-- ---------------------------------------------------------------------------
-- 4. Non-ASCII / control characters in the payload we sent - a stray character
--    that renders invisibly on screen (so looks identical when copied into
--    Postman by eye) would show up here as a real difference.
-- ---------------------------------------------------------------------------
select
  "OrderNo",
  regexp_replace("PancakeLastPayload", '[ -~]', '', 'g') as non_ascii_chars_only
from public."AutomatedOrders"
where "PancakeLastPayload" is not null
order by "CreatedAtUtc" desc
limit 1;
