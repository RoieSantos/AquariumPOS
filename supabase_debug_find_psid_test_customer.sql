-- Finds a real customer to test the anti link-sharing psid check with (supabase_automated_order_
-- psid_verification.sql) - picks someone who already has a PSID and a phone number on file in
-- OnlineCustomers, so there's something real to match/mismatch against (unlike last time, where
-- the order's own Psid had already been nulled out by the check before we went looking, so the
-- join against it could never find anything). Safe to re-run, read-only.

select "FbID" as psid_to_use_in_test_url, "Name", "PrimaryPhoneNumber", "SyncedAtUtc"
from public."OnlineCustomers"
where "FbID" is not null
  and nullif(trim(coalesce("PrimaryPhoneNumber", '')), '') is not null
order by "SyncedAtUtc" desc nulls last
limit 10;
