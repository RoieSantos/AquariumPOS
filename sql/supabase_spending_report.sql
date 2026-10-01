-- Purchases & Expenses report - per "can you create me a report of the total expense and what
-- causing the expense percentage.. i want to see purchase and expense".
--
-- One figure for everything the shop spent in a date range, split into what caused it:
--   Purchase - posted Purchase Orders, costed the same way as the Dashboard's "Total Purchase" card
--              (admin_get_purchase_summary, supabase_item_cost_and_po_line_cost.sql): UnitCost x
--              QtyReceived per line, by the PO's "OrderDate", warehouse taken from the LINE. The
--              cause is the item's category - its variant's first ("VariantCode" is the Pancake
--              VariationId), then the item's, else '(Uncategorized)'.
--   Expense  - POS expenses (ExpenseEntryHeader."NetAmount" by "Date") plus the portal's Expense
--              Journal (ExpenseJournalEntries."Amount" by "EntryDate"), the same two sources the
--              Dashboard's "Expense This Month" card sums (admin_get_expense_entry_summary). The
--              cause is the entry's Expense Category.
-- Payroll is NOT in here - it has its own Dashboard card and ledger.
--
-- One row per source x channel x warehouse x cause x vendor x detail (item / description); the page
-- filters, rolls up, works out the percentages and drills down client-side. Returned as one jsonb
-- array rather than a table so a long range isn't cut off at PostgREST's row limit.
--
-- Super users only (is_admin_authorized), same as the Expenses pages and the purchase summary this
-- draws from. Read-only, safe to re-run.

drop function if exists public.admin_get_spending_report(text, text, date, date);

create or replace function public.admin_get_spending_report(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_rows jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_to < p_date_from then
    raise exception 'Pick a valid date range.';
  end if;

  with purchases as (
    select 'Purchase'::text as source,
           'Purchase Order'::text as channel,
           coalesce(nullif(trim(l."WarehouseName"), ''), nullif(trim(h."WarehouseName"), ''), '(No warehouse)')::text as warehouse_name,
           coalesce(nullif(trim(c."Description"), ''), nullif(trim(v."CategoryCode"), ''), nullif(trim(i."CategoryCode"), ''), '(Uncategorized)')::text as cause,
           coalesce(nullif(trim(vd."Name"), ''), nullif(trim(h."VendorCode"), ''), '(No vendor)')::text as vendor_name,
           (coalesce(nullif(trim(l."ItemName"), ''), l."ItemCode")
             || case when nullif(trim(l."VariantName"), '') is not null then ' - ' || trim(l."VariantName") else '' end)::text as detail,
           round(coalesce(l."UnitCost", 0) * coalesce(l."QtyReceived", 0), 2) as amount,
           coalesce(l."QtyReceived", 0) as qty,
           l."PONo"::text as doc_no,
           (l."UnitCost" is null) as uncosted
    from public."PostedPurchaseOrderLines" l
    join public."PostedPurchaseOrders" h on h."PONo" = l."PONo"
    left join public."Vendors" vd on vd."VendorCode" = h."VendorCode"
    left join public."Variants" v on v."VariationId" = l."VariantCode"
    left join public."Items" i on i."Code" = l."ItemCode"
    left join public."Categories" c on c."Code" = coalesce(nullif(trim(v."CategoryCode"), ''), nullif(trim(i."CategoryCode"), ''))
    where h."OrderDate" >= p_date_from and h."OrderDate" <= p_date_to
      and coalesce(l."QtyReceived", 0) > 0
  ),
  expenses as (
    select 'Expense'::text as source,
           'POS Expense'::text as channel,
           coalesce(nullif(trim(e."Warehouse"), ''), '(No warehouse)')::text as warehouse_name,
           coalesce(nullif(trim(e."ExpenseCategory"), ''), '(No category)')::text as cause,
           null::text as vendor_name,
           coalesce(nullif(trim(e."Description"), ''), '(No description)')::text as detail,
           coalesce(e."NetAmount", 0) as amount,
           null::numeric as qty,
           e."ReceiptNo"::text as doc_no,
           false as uncosted
    from public."ExpenseEntryHeader" e
    where e."Date" >= p_date_from and e."Date" <= p_date_to
    union all
    select 'Expense'::text,
           'Expense Journal'::text,
           coalesce(nullif(trim(j."Warehouse"), ''), '(No warehouse)')::text,
           coalesce(nullif(trim(j."ExpenseCategory"), ''), '(No category)')::text,
           null::text,
           coalesce(nullif(trim(j."Description"), ''), '(No description)')::text,
           coalesce(j."Amount", 0),
           null::numeric,
           j."EntryID"::text,
           false
    from public."ExpenseJournalEntries" j
    where j."EntryDate" >= p_date_from and j."EntryDate" <= p_date_to
  ),
  grouped as (
    select x.source, x.channel, x.warehouse_name, x.cause, x.vendor_name, x.detail,
           sum(x.amount)::numeric as amount,
           sum(x.qty)::numeric as qty,
           count(distinct x.doc_no)::int as entry_count,
           (count(*) filter (where x.uncosted))::int as uncosted_lines
    from (select * from purchases union all select * from expenses) x
    group by x.source, x.channel, x.warehouse_name, x.cause, x.vendor_name, x.detail
  )
  select coalesce(jsonb_agg(to_jsonb(g)), '[]'::jsonb) into v_rows from grouped g;

  return v_rows;
end;
$$;

grant execute on function public.admin_get_spending_report(text, text, date, date) to anon;

notify pgrst, 'reload schema';
