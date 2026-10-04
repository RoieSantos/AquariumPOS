-- RUN THIS IN SSMS AGAINST THE LOCAL POS DATABASE (SQL Server) - NOT in Supabase.
--
-- Copies the POS's aquarium SET packages (dbo.CompleteAquariumSetHeader / dbo.CompleteAquariumSetLine)
-- to Supabase, so the portal's SET explosion (supabase_online_order_set_explode.sql) and the Customer
-- Aquarium page see the same packages the POS uses. It doesn't change anything locally - it OUTPUTS a
-- Postgres script, one statement per row:
--
--   1. Run this in SSMS (Results to Grid).
--   2. Click the column header to select the whole column, Ctrl+C.
--   3. Paste into the Supabase SQL editor and Run. (If SSMS also copies the column header, that's fine -
--      it's a SQL comment.)
--
-- Re-runnable: packages are upserted and each copied package's BOM lines are replaced, so running it
-- again after editing packages in the POS just brings Supabase up to date. Packages that exist only in
-- Supabase are left alone. The last statement shows the package / BOM line counts.

SET NOCOUNT ON;

SELECT x.stmt AS [-- paste everything below into the Supabase SQL editor]
FROM (
    SELECT 1 AS sort, h.PackageName AS pkg, 0 AS entry,
        N'insert into public."CompleteAquariumSetHeader" ("PackageName", "PackagePrice", "VariantID") values ('
        + N'''' + REPLACE(LTRIM(RTRIM(h.PackageName)), N'''', N'''''') + N''', '
        + CONVERT(nvarchar(40), ISNULL(h.PackagePrice, 0)) + N', '
        + CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(h.VariantID, N''))), N'') IS NULL THEN N'null'
               ELSE N'''' + REPLACE(LTRIM(RTRIM(h.VariantID)), N'''', N'''''') + N'''' END
        + N') on conflict ("PackageName") do update set "PackagePrice" = excluded."PackagePrice", '
        + N'"VariantID" = excluded."VariantID", "UpdatedDate" = timezone(''utc'', now());' AS stmt
    FROM dbo.CompleteAquariumSetHeader h

    UNION ALL

    SELECT 2, h.PackageName, 0,
        N'delete from public."CompleteAquariumSetLine" where "PackageName" = '''
        + REPLACE(LTRIM(RTRIM(h.PackageName)), N'''', N'''''') + N''';'
    FROM dbo.CompleteAquariumSetHeader h

    UNION ALL

    SELECT 3, l.PackageName, l.EntryNo,
        N'insert into public."CompleteAquariumSetLine" ("PackageName", "ItemNo", "ItemName", "Quantity", "Price") values ('
        + N'''' + REPLACE(LTRIM(RTRIM(l.PackageName)), N'''', N'''''') + N''', '
        + N'''' + REPLACE(LTRIM(RTRIM(ISNULL(l.ItemNo, N''))), N'''', N'''''') + N''', '
        + CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(l.ItemName, N''))), N'') IS NULL THEN N'null'
               ELSE N'''' + REPLACE(LTRIM(RTRIM(l.ItemName)), N'''', N'''''') + N'''' END + N', '
        + CONVERT(nvarchar(40), ISNULL(l.Quantity, 1)) + N', '
        + CONVERT(nvarchar(40), ISNULL(l.Price, 0)) + N');'
    FROM dbo.CompleteAquariumSetLine l
    WHERE EXISTS (SELECT 1 FROM dbo.CompleteAquariumSetHeader h WHERE h.PackageName = l.PackageName)

    UNION ALL

    SELECT 9, N'', 0,
        N'select (select count(*) from public."CompleteAquariumSetHeader") as packages, '
        + N'(select count(*) from public."CompleteAquariumSetLine") as bom_lines;'
) x
ORDER BY x.sort, x.pkg, x.entry;
