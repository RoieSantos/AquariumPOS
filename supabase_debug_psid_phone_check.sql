-- Verifies the two-order psid-mismatch test (see supabase_debug_find_psid_test_customer.sql for
-- picking the test customer). Fill in both OrderNo values below - Test 1 (typed the customer's
-- real on-file phone) should show a non-null Psid; Test 2 (typed a different/made-up phone) should
-- show Psid = NULL. Safe to re-run, read-only.

select "OrderNo", "CustomerPhone", "Psid",
  case when "Psid" is not null then 'kept (phone matched)' else 'dropped (phone did not match)' end as outcome
from public."AutomatedOrders"
where "OrderNo" in ('PUT_TEST1_ORDER_NO_HERE', 'PUT_TEST2_ORDER_NO_HERE')
order by "CreatedAtUtc";
