-- LOCAL POS (SQL Server / SSMS) - removes Items and Variants that are not on the portal - per "clean my
-- items / variants on my local POS. i want to remove the items that is not on the portal".
-- Run in SSMS against EACH store's POS database (not Supabase).
--
-- Steps:
--   1. In Supabase, run supabase_export_portal_item_codes_for_pos_cleanup.sql and copy its
--      "paste_into_pos_script" cell into the PASTE HERE section below.
--   2. Run this file as-is (@Apply = 0): PREVIEW only - nothing changes. Check the lists.
--   3. Set @Apply = 1 and run again to delete.
--
-- What it deletes (user chose "delete everything"):
--   - Items whose Code is not in the portal's Items, AND every ItemLedgerEntry row for them (the FK
--     FK_ItemLedgerEntry_Items needs it). That ledger holds SALES / Return / stock-adjustment lines, so
--     past sales reports and EOD history for those items lose those lines.
--   - Variant rows whose VariationId is not in the portal's Variants, and every variant of a deleted item.
-- Never deleted: POS built-in codes (INC_EXP - every income/expense posting; CUSTOM, CUSTOM_STAND...,
-- POS-CUSTOM - custom calculator lines). Add more to #Protected below if needed.
-- Before deleting, every removed row is copied to dbo.zBackup_<table>_<yyyyMMdd_HHmmss> tables.
-- Stops without changing anything if the pasted portal list looks empty / too short.
--
-- NOTE: the 5-minute Pancake product pull still adds any Pancake product missing locally, so items that
-- are still in Pancake will come back (user chose to leave that sync as is).

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Apply bit = 0;            -- 0 = preview only, 1 = delete
DECLARE @MinPortalItems int = 200; -- safety: refuse to run if fewer portal items than this were pasted

IF OBJECT_ID('tempdb..#PortalItems') IS NOT NULL DROP TABLE #PortalItems;
IF OBJECT_ID('tempdb..#PortalVariants') IS NOT NULL DROP TABLE #PortalVariants;
CREATE TABLE #PortalItems (Code nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL);
CREATE TABLE #PortalVariants (VariationId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL);

-- ===================== PASTE HERE (from supabase_export_portal_item_codes_for_pos_cleanup.sql) =====================


-- ===================== END PASTE ===================================================================================

DECLARE @PortalItemCount int = (SELECT COUNT(*) FROM #PortalItems);
DECLARE @PortalVariantCount int = (SELECT COUNT(*) FROM #PortalVariants);

IF @PortalItemCount < @MinPortalItems
BEGIN
    RAISERROR('Only %d portal items were pasted (minimum %d) - paste the full export from Supabase first (it must start with INSERT INTO #PortalItems, not with --). Nothing was changed.', 16, 1, @PortalItemCount, @MinPortalItems);
    RETURN;
END

-- POS built-in codes - never deleted, even though they are not on the portal.
IF OBJECT_ID('tempdb..#Protected') IS NOT NULL DROP TABLE #Protected;
CREATE TABLE #Protected (Code nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL);
INSERT INTO #Protected (Code) VALUES (N'INC_EXP'), (N'CUSTOM'), (N'POS-CUSTOM');

IF OBJECT_ID('tempdb..#DelItems') IS NOT NULL DROP TABLE #DelItems;
SELECT i.Code
  INTO #DelItems
  FROM dbo.Items i
 WHERE NOT EXISTS (SELECT 1 FROM #PortalItems p WHERE p.Code = LTRIM(RTRIM(i.Code)))
   AND NOT EXISTS (SELECT 1 FROM #Protected x WHERE x.Code = LTRIM(RTRIM(i.Code)))
   AND LTRIM(i.Code) NOT LIKE N'CUSTOM[_]STAND%';

-- Variants: not on the portal, or belonging to an item being deleted. Variants of protected items stay.
-- If the export had no variants at all, only variants of deleted items are removed.
IF OBJECT_ID('tempdb..#DelVariants') IS NOT NULL DROP TABLE #DelVariants;
SELECT v.VariationId
  INTO #DelVariants
  FROM dbo.[Variant] v
 WHERE (
         (@PortalVariantCount > 0 AND NOT EXISTS (SELECT 1 FROM #PortalVariants p WHERE p.VariationId = LTRIM(RTRIM(v.VariationId))))
         OR EXISTS (SELECT 1 FROM #DelItems d WHERE d.Code IN (v.ItemCode, v.MainItemCode))
       )
   AND NOT EXISTS (SELECT 1 FROM #Protected x WHERE x.Code IN (LTRIM(RTRIM(v.ItemCode)), LTRIM(RTRIM(v.MainItemCode))))
   AND ISNULL(LTRIM(v.ItemCode), N'') NOT LIKE N'CUSTOM[_]STAND%'
   AND ISNULL(LTRIM(v.MainItemCode), N'') NOT LIKE N'CUSTOM[_]STAND%';

-- ---------- Preview (always shown) ----------
SELECT CASE WHEN @Apply = 1 THEN 'APPLYING' ELSE 'PREVIEW ONLY - nothing changed (set @Apply = 1 to delete)' END AS mode,
       @PortalItemCount AS portal_items_pasted,
       @PortalVariantCount AS portal_variants_pasted,
       (SELECT COUNT(*) FROM dbo.Items) AS local_items,
       (SELECT COUNT(*) FROM #DelItems) AS items_to_delete,
       (SELECT COUNT(*) FROM dbo.[Variant]) AS local_variants,
       (SELECT COUNT(*) FROM #DelVariants) AS variants_to_delete,
       (SELECT COUNT(*) FROM dbo.ItemLedgerEntry l WHERE l.ItemCode IN (SELECT Code FROM #DelItems)) AS ledger_rows_to_delete;

-- Ledger rows that go with the deleted items, by type (SALES = past sales lines).
SELECT l.DocumentType, COUNT(*) AS rows_to_delete, SUM(ISNULL(l.NetAmount, 0)) AS net_amount,
       MIN(l.EntryDate) AS first_entry, MAX(l.EntryDate) AS last_entry
  FROM dbo.ItemLedgerEntry l
 WHERE l.ItemCode IN (SELECT Code FROM #DelItems)
 GROUP BY l.DocumentType
 ORDER BY rows_to_delete DESC;

-- Items to delete.
SELECT i.Code, i.Name, i.CategoryCode, i.Price, i.QuantityInStock, i.IsActive,
       (SELECT COUNT(*) FROM dbo.ItemLedgerEntry l WHERE l.ItemCode = i.Code) AS ledger_rows,
       (SELECT MAX(l.EntryDate) FROM dbo.ItemLedgerEntry l WHERE l.ItemCode = i.Code) AS last_ledger_entry
  FROM dbo.Items i
 WHERE i.Code IN (SELECT Code FROM #DelItems)
 ORDER BY i.CategoryCode, i.Code;

-- Variants to delete.
SELECT v.VariationId, v.MainItemCode, v.ItemCode, v.SKU, v.VariantName, v.Price,
       CASE WHEN EXISTS (SELECT 1 FROM #DelItems d WHERE d.Code IN (v.ItemCode, v.MainItemCode))
            THEN 'item deleted' ELSE 'variant not on portal' END AS reason
  FROM dbo.[Variant] v
 WHERE v.VariationId IN (SELECT VariationId FROM #DelVariants)
 ORDER BY v.MainItemCode, v.ItemCode;

IF @Apply = 0 RETURN;

-- ---------- Apply ----------
DECLARE @Stamp nvarchar(20) = FORMAT(GETDATE(), 'yyyyMMdd_HHmmss');
DECLARE @Sql nvarchar(max);

BEGIN TRANSACTION;

    -- Backups of everything removed (temp tables are visible to this dynamic SQL - same session).
    SET @Sql = N'SELECT * INTO dbo.' + QUOTENAME(N'zBackup_Items_' + @Stamp) + N' FROM dbo.Items WHERE Code IN (SELECT Code FROM #DelItems);'
             + N'SELECT * INTO dbo.' + QUOTENAME(N'zBackup_Variant_' + @Stamp) + N' FROM dbo.[Variant] WHERE VariationId IN (SELECT VariationId FROM #DelVariants);'
             + N'SELECT * INTO dbo.' + QUOTENAME(N'zBackup_ItemLedgerEntry_' + @Stamp) + N' FROM dbo.ItemLedgerEntry WHERE ItemCode IN (SELECT Code FROM #DelItems);';
    EXEC sp_executesql @Sql;

    DELETE FROM dbo.ItemLedgerEntry WHERE ItemCode IN (SELECT Code FROM #DelItems);
    DECLARE @LedgerDeleted int = @@ROWCOUNT;
    DELETE FROM dbo.[Variant] WHERE VariationId IN (SELECT VariationId FROM #DelVariants);
    DECLARE @VariantsDeleted int = @@ROWCOUNT;
    DELETE FROM dbo.Items WHERE Code IN (SELECT Code FROM #DelItems);
    DECLARE @ItemsDeleted int = @@ROWCOUNT;

COMMIT TRANSACTION;

SELECT 'DONE' AS result, @ItemsDeleted AS items_deleted, @VariantsDeleted AS variants_deleted,
       @LedgerDeleted AS ledger_rows_deleted, N'dbo.zBackup_*_' + @Stamp AS backup_tables;
