-- Manual SQL Server script for the Opening Stock / Variance / Shrinkage % feature.
-- NOTE: The app already applies this automatically at startup via
-- ItemVariantSalesWorksheetData.EnsureTablesExist. This script is provided
-- for manual review / running directly against the database if preferred.
--
-- Only [Opening Stock] is a real, persisted column. Variance and Shrinkage %
-- are NOT stored in SQL Server - they are computed on the fly in C#
-- (Variance = Physical Qty On Hand - Qty On Hand,
--  Shrinkage % = Variance / Qty On Hand * 100) and are only sent to Supabase
-- as computed values in the sync payload.
--
-- dbo.MonthEndHeader requires no changes for this feature.

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetLine', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetLine', N'Opening Stock') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetLine
        ADD [Opening Stock] DECIMAL(18, 2) NOT NULL
            CONSTRAINT DF_ItemVariantSalesWorksheetLine_OpeningStock DEFAULT (0);
END;
GO

IF OBJECT_ID(N'dbo.MonthEndLines', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.MonthEndLines', N'Opening Stock') IS NULL
BEGIN
    ALTER TABLE dbo.MonthEndLines
        ADD [Opening Stock] DECIMAL(18, 2) NOT NULL
            CONSTRAINT DF_MonthEndLines_OpeningStock DEFAULT (0);
END;
GO
