-- Manually applies the same migration ProductSerialTrackingForm.EnsureSerialTrackingTable runs
-- automatically on this store's local SQL Server database (dbo.ItemSerialTracking). Use this if
-- the self-migration in the app isn't taking effect on a given unit (e.g. it's still running a
-- build older than the fix, or you just want to apply it directly).
--
-- Safe to run any number of times, and safe regardless of the table's current state - every step
-- is guarded (IF OBJECT_ID/COL_LENGTH IS NULL) so it only adds what's actually missing.
--
-- Each step below is its own batch (separated by GO) on purpose - the computed column near the
-- bottom references LastSyncedAtUtc/UpdatedAtUtc/CreatedAtUtc, and SQL Server can bind that
-- expression against stale pre-ALTER metadata if it's compiled in the same batch as the ALTER
-- that just added those columns. Keep the GO separators when running this in SSMS/sqlcmd.

IF OBJECT_ID('dbo.ItemSerialTracking', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ItemSerialTracking (
        RunningSerialNo BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        SerialNo NVARCHAR(120) NOT NULL,
        ItemCode NVARCHAR(100) NOT NULL,
        ItemDescription NVARCHAR(255) NULL,
        Location NVARCHAR(255) NULL,
        Status NVARCHAR(30) NOT NULL CONSTRAINT DF_ItemSerialTracking_Status DEFAULT('IN_STOCK'),
        SourceDocumentNo NVARCHAR(100) NULL,
        CreatedAtUtc DATETIME2 NOT NULL CONSTRAINT DF_ItemSerialTracking_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        CreatedBy NVARCHAR(100) NULL,
        UpdatedAtUtc DATETIME2 NULL
    );

    CREATE UNIQUE INDEX UX_ItemSerialTracking_SerialNo ON dbo.ItemSerialTracking(SerialNo);
    CREATE INDEX IX_ItemSerialTracking_ItemCode_Status ON dbo.ItemSerialTracking(ItemCode, Status);
END
GO

IF COL_LENGTH('dbo.ItemSerialTracking', 'VariantCode') IS NULL
BEGIN
    ALTER TABLE dbo.ItemSerialTracking ADD VariantCode NVARCHAR(200) NULL;
END

IF COL_LENGTH('dbo.ItemSerialTracking', 'Location') IS NULL
BEGIN
    ALTER TABLE dbo.ItemSerialTracking ADD Location NVARCHAR(255) NULL;
END

IF COL_LENGTH('dbo.ItemSerialTracking', 'SoldReceiptNo') IS NULL
BEGIN
    ALTER TABLE dbo.ItemSerialTracking ADD SoldReceiptNo NVARCHAR(100) NULL;
END

IF COL_LENGTH('dbo.ItemSerialTracking', 'SoldOnlineOrderId') IS NULL
BEGIN
    ALTER TABLE dbo.ItemSerialTracking ADD SoldOnlineOrderId NVARCHAR(100) NULL;
END

IF COL_LENGTH('dbo.ItemSerialTracking', 'LastSyncedAtUtc') IS NULL
BEGIN
    ALTER TABLE dbo.ItemSerialTracking ADD LastSyncedAtUtc DATETIME2 NULL;
END

IF COL_LENGTH('dbo.ItemSerialTracking', 'UpdatedBy') IS NULL
BEGIN
    ALTER TABLE dbo.ItemSerialTracking ADD UpdatedBy NVARCHAR(200) NULL;
END
GO

IF COL_LENGTH('dbo.ItemSerialTracking', 'SyncedToSupabase') IS NULL
BEGIN
    ALTER TABLE dbo.ItemSerialTracking ADD SyncedToSupabase AS (
        CASE WHEN LastSyncedAtUtc IS NOT NULL AND LastSyncedAtUtc >= COALESCE(UpdatedAtUtc, CreatedAtUtc)
             THEN CONVERT(BIT, 1) ELSE CONVERT(BIT, 0) END
    );
END
GO

IF EXISTS (
    SELECT 1
    FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ItemSerialTracking')
      AND name = 'Status'
      AND max_length < 510
)
BEGIN
    ALTER TABLE dbo.ItemSerialTracking ALTER COLUMN Status NVARCHAR(255) NOT NULL;
END

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_ItemSerialTracking_ItemCode_VariantCode_Status'
      AND object_id = OBJECT_ID('dbo.ItemSerialTracking'))
BEGIN
    CREATE INDEX IX_ItemSerialTracking_ItemCode_VariantCode_Status
        ON dbo.ItemSerialTracking(ItemCode, VariantCode, Status);
END
GO
