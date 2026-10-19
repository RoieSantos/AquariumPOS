-- Read-only check: what Tender Declarations have reached Supabase, per warehouse.
-- Run AFTER supabase_tender_declaration_tables.sql and the POS "UPLOAD TENDER DECL HISTORY" button.

select
  h."Warehouse"                                        as warehouse,
  count(*)                                             as declarations,
  count(*) filter (where h."FromHistoryUpload")        as from_history_upload,
  min(h."DeclDate")                                    as first_date,
  max(h."DeclDate")                                    as last_date,
  (select count(*) from public."TenderDeclarationLines" l where l."Warehouse" = h."Warehouse") as denomination_lines,
  count(*) filter (where h."Variance" < 0)             as short_count,
  count(*) filter (where h."Variance" > 0)             as over_count,
  max(h."SyncedAtUtc")                                 as last_synced_utc
from public."TenderDeclarationHeader" h
group by h."Warehouse"
order by h."Warehouse";
