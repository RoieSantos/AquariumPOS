-- Retry: remove line 8 ("SERVICES - Product for - 1", qty 100, 0.00) from advance order
-- 10627 / RS-0000011380 - supabase_remove_advance_order_10627_services_line.sql matched nothing
-- (its raw "No" / "Type" didn't equal SERVICES / ITEM). This one targets the line by LineNo 8 +
-- its description, and puts the line's ACTUAL "No" into AdvanceOrderLineSkips so the POS 5-minute
-- sync can't re-insert it (trigger trg_advance_order_line_skip from that earlier file - run it first).
--
-- Guarded: only line 8 of 10627 whose description starts with SERVICES and amount is 0. Safe to re-run.

do $$
declare
  v_no text;
begin
  select trim(coalesce(l."No"::text, '')) into v_no
  from public."AdvanceOrderLines" l
  where trim(l."TransactionNo"::text) = '10627'
    and trim(l."LineNo"::text) = '8'
    and l."Description" ilike 'SERVICES%'
    and coalesce(l."NetAmount", 0) = 0
  limit 1;

  if found then
    insert into public."AdvanceOrderLineSkips" ("TransactionNo", "No", "Reason")
    values ('10627', v_no, 'Stray 0.00 SERVICES line 8 (qty 100) on RS-0000011380')
    on conflict do nothing;

    delete from public."AdvanceOrderLines" l
    where trim(l."TransactionNo"::text) = '10627'
      and trim(l."LineNo"::text) = '8'
      and l."Description" ilike 'SERVICES%'
      and coalesce(l."NetAmount", 0) = 0;
  end if;
end $$;

-- Result: remaining lines for the order (line 8 should be gone, CASH payment line kept).
select "TransactionNo", "LineNo", "Type", "No", "Description", "Quantity", "Price", "NetAmount"
from public."AdvanceOrderLines"
where trim("TransactionNo"::text) = '10627'
order by case when "LineNo"::text ~ '^\d+$' then "LineNo"::text::numeric end nulls last, "LineNo"::text;
