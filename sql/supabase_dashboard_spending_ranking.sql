-- Dashboard "Purchase, Expense & Payroll" group - per "under purchase / expense and payroll.. can
-- you show me a report there what is the biggest purchase and expense by ranking". Read-only,
-- current month (Asia/Manila), top 10 per ranking, for docs/js/dashboard.js's loadSpendingRanking.
--
-- Uses the SAME rules as the cards above it, so a ranking's rows add up toward the card's total:
--   Purchase - admin_get_purchase_summary (supabase_purchase_summary_by_posted_date.sql): posted
--              POs by PostedAtUtc, UnitCost x QtyReceived per line, warehouse from the LINE.
--   Expense  - admin_get_expense_entry_summary (supabase_expense_journal_tables.sql): POS expenses
--              (ExpenseEntryHeader by "Date") + Expense Journal (ExpenseJournalEntries by "EntryDate").
--
-- Rankings (dimension):
--   Purchase: 'category' (item/variant category), 'vendor', 'item', 'po' (biggest single POs)
--   Expense:  'category' (Expense Category), 'entry' (biggest single expense entries)
-- share = this row's amount / the source's month total (0-1).
--
-- Super users only (is_admin_authorized). Safe to re-run (create or replace).

create or replace function public.admin_get_dashboard_spending_ranking(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(
  source text,
  dimension text,
  rank int,
  name text,
  detail text,
  amount numeric,
  entry_count int,
  share numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_all_wh boolean := p_warehouse_name is null or trim(p_warehouse_name) = '';
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
    with purchase_lines as (
      select l."PONo"::text as po_no,
             (h."PostedAtUtc" at time zone 'Asia/Manila')::date as posted_date,
             coalesce(nullif(trim(vd."Name"), ''), nullif(trim(h."VendorCode"), ''), '(No vendor)')::text as vendor_name,
             coalesce(nullif(trim(c."Description"), ''), nullif(trim(v."CategoryCode"), ''), nullif(trim(i."CategoryCode"), ''), '(Uncategorized)')::text as category,
             (coalesce(nullif(trim(l."ItemName"), ''), l."ItemCode")
               || case when nullif(trim(l."VariantName"), '') is not null then ' - ' || trim(l."VariantName") else '' end)::text as item_name,
             round(coalesce(l."UnitCost", 0) * coalesce(l."QtyReceived", 0), 2) as amount
      from public."PostedPurchaseOrderLines" l
      join public."PostedPurchaseOrders" h on h."PONo" = l."PONo"
      left join public."Vendors" vd on vd."VendorCode" = h."VendorCode"
      left join public."Variants" v on v."VariationId" = l."VariantCode"
      left join public."Items" i on i."Code" = l."ItemCode"
      left join public."Categories" c on c."Code" = coalesce(nullif(trim(v."CategoryCode"), ''), nullif(trim(i."CategoryCode"), ''))
      where (h."PostedAtUtc" at time zone 'Asia/Manila')::date >= v_month_start
        and (h."PostedAtUtc" at time zone 'Asia/Manila')::date < v_month_end
        and coalesce(l."QtyReceived", 0) > 0
        and (v_all_wh or l."WarehouseName" = p_warehouse_name)
    ),
    expense_rows as (
      select ('POS-' || coalesce(e."ReceiptNo"::text, ''))::text as doc_no,
             e."Date" as entry_date,
             coalesce(nullif(trim(e."ExpenseCategory"), ''), '(No category)')::text as category,
             coalesce(nullif(trim(e."Description"), ''), '(No description)')::text as description,
             coalesce(nullif(trim(e."Warehouse"), ''), '(No warehouse)')::text as warehouse_name,
             coalesce(e."NetAmount", 0)::numeric as amount
      from public."ExpenseEntryHeader" e
      where e."Date" >= v_month_start and e."Date" < v_month_end
        and (v_all_wh or e."Warehouse" = p_warehouse_name)
      union all
      select ('EJ-' || j."EntryID"::text)::text,
             j."EntryDate",
             coalesce(nullif(trim(j."ExpenseCategory"), ''), '(No category)')::text,
             coalesce(nullif(trim(j."Description"), ''), '(No description)')::text,
             coalesce(nullif(trim(j."Warehouse"), ''), '(No warehouse)')::text,
             coalesce(j."Amount", 0)::numeric
      from public."ExpenseJournalEntries" j
      where j."EntryDate" >= v_month_start and j."EntryDate" < v_month_end
        and (v_all_wh or j."Warehouse" = p_warehouse_name)
    ),
    grouped as (
      select 'Purchase'::text as src, 'category'::text as dim, p.category as nm, null::text as dt,
             sum(p.amount) as amt, count(distinct p.po_no)::int as cnt
        from purchase_lines p group by p.category
      union all
      select 'Purchase', 'vendor', p.vendor_name, null, sum(p.amount), count(distinct p.po_no)::int
        from purchase_lines p group by p.vendor_name
      union all
      select 'Purchase', 'item', p.item_name, null, sum(p.amount), count(distinct p.po_no)::int
        from purchase_lines p group by p.item_name
      union all
      select 'Purchase', 'po', p.po_no,
             max(p.vendor_name) || ' · ' || to_char(max(p.posted_date), 'Mon DD'),
             sum(p.amount), count(*)::int
        from purchase_lines p group by p.po_no
      union all
      select 'Expense', 'category', x.category, null, sum(x.amount), count(*)::int
        from expense_rows x group by x.category
      union all
      select 'Expense', 'entry', x.description,
             x.category || ' · ' || x.warehouse_name || ' · ' || to_char(x.entry_date, 'Mon DD'),
             x.amount, 1
        from expense_rows x
    ),
    totals as (
      select 'Purchase'::text as src, coalesce(sum(p.amount), 0) as total from purchase_lines p
      union all
      select 'Expense', coalesce(sum(x.amount), 0) from expense_rows x
    ),
    ranked as (
      select g.*, row_number() over (partition by g.src, g.dim order by g.amt desc, g.nm) as rn
      from grouped g
    )
    select r.src, r.dim, r.rn::int, r.nm, r.dt, r.amt::numeric, r.cnt,
           case when t.total > 0 then round(r.amt / t.total, 4) else 0 end::numeric
    from ranked r
    join totals t on t.src = r.src
    where r.rn <= 10
    order by r.src, r.dim, r.rn;
end;
$$;

grant execute on function public.admin_get_dashboard_spending_ranking(text, text, text) to anon;

notify pgrst, 'reload schema';
