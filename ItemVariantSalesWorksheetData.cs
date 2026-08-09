using System;
using System.Collections.Generic;
using System.Data.SqlClient;

namespace AquariumPOS
{
    public sealed class ItemVariantSalesWorksheetHeader
    {
        public string DocumentNo { get; init; } = string.Empty;
        public DateTime GeneratedDate { get; init; }
        public DateTime FromDate { get; init; }
        public DateTime ToDate { get; init; }
        public string WarehouseName { get; init; } = string.Empty;
        public string ItemVariantFilter { get; init; } = string.Empty;
        public string GeneratedBy { get; init; } = string.Empty;
    }

    public sealed class ItemVariantSalesWorksheetLine
    {
        public int LineNo { get; init; }
        public string ReportKey { get; init; } = string.Empty;
        public string ItemNo { get; init; } = string.Empty;
        public string Description { get; init; } = string.Empty;
        public decimal QtyTransferred { get; init; }
        public decimal LocalSales { get; init; }
        public decimal OnlineSales { get; init; }
        public decimal TotalSalesCount => LocalSales + OnlineSales;
        public decimal QtyOnHand { get; init; }
        public decimal? PhysicalQtyOnHand { get; init; }
        public decimal OpeningStock { get; init; }
        public decimal? Variance => PhysicalQtyOnHand.HasValue ? PhysicalQtyOnHand.Value - QtyOnHand : (decimal?)null;
        public decimal? ShrinkagePercent => Variance.HasValue && QtyOnHand != 0 ? (Variance.Value / QtyOnHand) * 100m : (decimal?)null;
        public string ProductId { get; init; } = string.Empty;
    }

    public sealed class MonthEndHeader
    {
        public string DocumentNo { get; init; } = string.Empty;
        public string WorksheetDocumentNo { get; init; } = string.Empty;
        public DateTime WorksheetGeneratedDate { get; init; }
        public DateTime FromDate { get; init; }
        public DateTime ToDate { get; init; }
        public string WarehouseName { get; init; } = string.Empty;
        public string ItemVariantFilter { get; init; } = string.Empty;
        public string WorksheetGeneratedBy { get; init; } = string.Empty;
        public string PostedBy { get; init; } = string.Empty;
        public DateTime PostedAtUtc { get; init; }
        public int TotalLines { get; init; }
        public int CloudPatchedLines { get; init; }
        public int CloudSkippedLines { get; init; }
        public int CloudFailedLines { get; init; }
        public bool CloudSyncSuccess { get; init; }

        /// <summary>
        /// Tracks whether this header/its lines were successfully sent to Supabase
        /// (dbo.MonthEndHeader.[Sent To Cloud]).
        /// </summary>
        public bool SentToCloud { get; set; }

        /// <summary>
        /// Not persisted - transient detail of the last Supabase sync attempt, used for
        /// immediate UI feedback right after posting/resending.
        /// </summary>
        public string SupabaseSyncMessage { get; set; } = string.Empty;
    }

    public sealed class MonthEndLine
    {
        public int LineNo { get; init; }
        public string ReportKey { get; init; } = string.Empty;
        public string ItemNo { get; init; } = string.Empty;
        public string Description { get; init; } = string.Empty;
        public decimal QtyTransferred { get; init; }
        public decimal LocalSales { get; init; }
        public decimal OnlineSales { get; init; }
        public decimal TotalSalesCount => LocalSales + OnlineSales;
        public decimal QtyOnHand { get; init; }
        public decimal? PhysicalQtyOnHand { get; init; }
        public decimal OpeningStock { get; init; }
        public decimal? Variance => PhysicalQtyOnHand.HasValue ? PhysicalQtyOnHand.Value - QtyOnHand : (decimal?)null;
        public decimal? ShrinkagePercent => Variance.HasValue && QtyOnHand != 0 ? (Variance.Value / QtyOnHand) * 100m : (decimal?)null;
        public string VariationId { get; init; } = string.Empty;
        public string CloudWarehouseId { get; init; } = string.Empty;
        public decimal? CloudPreviousQtyOnHand { get; set; }
        public decimal? CloudUpdatedQtyOnHand { get; set; }
        public string CloudPatchStatus { get; set; } = string.Empty;
        public string CloudPatchMessage { get; set; } = string.Empty;
        public bool SentToOnline { get; set; }
        public string LastErrorEndpoint { get; set; } = string.Empty;
        public string LastErrorPayload { get; set; } = string.Empty;
        public string LastErrorMessage { get; set; } = string.Empty;
        public string ProductId { get; set; } = string.Empty;
    }

    public static class ItemVariantSalesWorksheetData
    {
        public static void EnsureTablesExist(string connectionString)
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using var command = new SqlCommand(@"
IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetHeader', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ItemVariantSalesWorksheetHeader (
        [No.] NVARCHAR(50) NOT NULL PRIMARY KEY,
        [Generated Date] DATETIME2 NOT NULL,
        [From Date] DATE NOT NULL,
        [To Date] DATE NOT NULL,
        [Warehouse] NVARCHAR(200) NULL,
        [Item Variant Filter] NVARCHAR(300) NULL,
        [Generated By] NVARCHAR(100) NULL,
        [Created AtUtc] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ItemVariantSalesWorksheetLine (
        [Document No.] NVARCHAR(50) NOT NULL,
        [Line No.] INT NOT NULL,
        [Report Key] NVARCHAR(200) NULL,
        [Item No.] NVARCHAR(200) NULL,
        [Description] NVARCHAR(500) NULL,
        [Qty Transferred] DECIMAL(18, 2) NOT NULL,
        [Local Sales] DECIMAL(18, 2) NOT NULL,
        [Online Sales] DECIMAL(18, 2) NOT NULL,
        [Qty On Hand] DECIMAL(18, 2) NOT NULL,
        [Physical Qty On Hand] DECIMAL(18, 2) NULL,
        [Opening Stock] DECIMAL(18, 2) NOT NULL CONSTRAINT DF_ItemVariantSalesWorksheetLine_OpeningStock DEFAULT(0),
        [Product ID] NVARCHAR(100) NULL,
        CONSTRAINT PK_ItemVariantSalesWorksheetLine PRIMARY KEY ([Document No.], [Line No.])
    );
END;

IF OBJECT_ID(N'dbo.MonthEndHeader', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MonthEndHeader (
        [No.] NVARCHAR(50) NOT NULL PRIMARY KEY,
        [Worksheet No.] NVARCHAR(50) NOT NULL,
        [Worksheet Generated Date] DATETIME2 NULL,
        [From Date] DATE NOT NULL,
        [To Date] DATE NOT NULL,
        [Warehouse] NVARCHAR(200) NULL,
        [Item Variant Filter] NVARCHAR(300) NULL,
        [Worksheet Generated By] NVARCHAR(100) NULL,
        [Posted By] NVARCHAR(100) NULL,
        [Posted AtUtc] DATETIME2 NOT NULL,
        [Total Lines] INT NOT NULL,
        [Cloud Patched Lines] INT NOT NULL,
        [Cloud Skipped Lines] INT NOT NULL,
        [Cloud Failed Lines] INT NOT NULL,
        [Sent To Cloud] BIT NOT NULL CONSTRAINT DF_MonthEndHeader_SentToCloud DEFAULT(0),
        [Created AtUtc] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.MonthEndLines', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MonthEndLines (
        [Document No.] NVARCHAR(50) NOT NULL,
        [Line No.] INT NOT NULL,
        [Report Key] NVARCHAR(200) NULL,
        [Item No.] NVARCHAR(200) NULL,
        [Description] NVARCHAR(500) NULL,
        [Qty Transferred] DECIMAL(18, 2) NOT NULL,
        [Local Sales] DECIMAL(18, 2) NOT NULL,
        [Online Sales] DECIMAL(18, 2) NOT NULL,
        [Qty On Hand] DECIMAL(18, 2) NOT NULL,
        [Physical Qty On Hand] DECIMAL(18, 2) NULL,
        [Opening Stock] DECIMAL(18, 2) NOT NULL CONSTRAINT DF_MonthEndLines_OpeningStock DEFAULT(0),
        [Variation ID] NVARCHAR(100) NULL,
        [Cloud Warehouse ID] NVARCHAR(100) NULL,
        [Cloud Previous Qty On Hand] DECIMAL(18, 2) NULL,
        [Cloud Updated Qty On Hand] DECIMAL(18, 2) NULL,
        [Cloud Patch Status] NVARCHAR(50) NULL,
        [Cloud Patch Message] NVARCHAR(MAX) NULL,
        [Sent To Online] BIT NOT NULL CONSTRAINT DF_MonthEndLines_SentToOnline DEFAULT(0),
        [Last Error Endpoint] NVARCHAR(500) NULL,
        [Last Error Payload] NVARCHAR(MAX) NULL,
        [Last Error Message] NVARCHAR(MAX) NULL,
        [Product ID] NVARCHAR(100) NULL,
        [Created AtUtc] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_MonthEndLines PRIMARY KEY ([Document No.], [Line No.])
    );
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetHeader', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetHeader', N'Warehouse') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetHeader ADD [Warehouse] NVARCHAR(200) NULL;
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetHeader', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetHeader', N'Item Variant Filter') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetHeader ADD [Item Variant Filter] NVARCHAR(300) NULL;
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetHeader', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetHeader', N'Generated By') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetHeader ADD [Generated By] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetLine', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetLine', N'Report Key') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetLine ADD [Report Key] NVARCHAR(200) NULL;
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetLine', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetLine', N'Qty Transferred') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetLine ADD [Qty Transferred] DECIMAL(18, 2) NOT NULL CONSTRAINT DF_ItemVariantSalesWorksheetLine_QtyTransferred DEFAULT(0);
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetLine', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetLine', N'Physical Qty On Hand') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetLine ADD [Physical Qty On Hand] DECIMAL(18, 2) NULL;
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetLine', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetLine', N'Product ID') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetLine ADD [Product ID] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.ItemVariantSalesWorksheetLine', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.ItemVariantSalesWorksheetLine', N'Opening Stock') IS NULL
BEGIN
    ALTER TABLE dbo.ItemVariantSalesWorksheetLine ADD [Opening Stock] DECIMAL(18, 2) NOT NULL CONSTRAINT DF_ItemVariantSalesWorksheetLine_OpeningStock DEFAULT(0);
END;

IF OBJECT_ID(N'dbo.MonthEndHeader', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.MonthEndHeader', N'Sent To Cloud') IS NULL
BEGIN
    ALTER TABLE dbo.MonthEndHeader ADD [Sent To Cloud] BIT NOT NULL CONSTRAINT DF_MonthEndHeader_SentToCloud DEFAULT(0);
END;

IF OBJECT_ID(N'dbo.MonthEndLines', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.MonthEndLines', N'Sent To Online') IS NULL
BEGIN
    ALTER TABLE dbo.MonthEndLines ADD [Sent To Online] BIT NOT NULL CONSTRAINT DF_MonthEndLines_SentToOnline DEFAULT(0);
END;

IF OBJECT_ID(N'dbo.MonthEndLines', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.MonthEndLines', N'Opening Stock') IS NULL
BEGIN
    ALTER TABLE dbo.MonthEndLines ADD [Opening Stock] DECIMAL(18, 2) NOT NULL CONSTRAINT DF_MonthEndLines_OpeningStock DEFAULT(0);
END;

IF OBJECT_ID(N'dbo.MonthEndLines', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.MonthEndLines', N'Last Error Endpoint') IS NULL
BEGIN
    ALTER TABLE dbo.MonthEndLines ADD [Last Error Endpoint] NVARCHAR(500) NULL;
END;

IF OBJECT_ID(N'dbo.MonthEndLines', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.MonthEndLines', N'Last Error Payload') IS NULL
BEGIN
    ALTER TABLE dbo.MonthEndLines ADD [Last Error Payload] NVARCHAR(MAX) NULL;
END;

IF OBJECT_ID(N'dbo.MonthEndLines', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.MonthEndLines', N'Last Error Message') IS NULL
BEGIN
    ALTER TABLE dbo.MonthEndLines ADD [Last Error Message] NVARCHAR(MAX) NULL;
END;

IF OBJECT_ID(N'dbo.MonthEndLines', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.MonthEndLines', N'Product ID') IS NULL
BEGIN
    ALTER TABLE dbo.MonthEndLines ADD [Product ID] NVARCHAR(100) NULL;
END;", connection);
            command.ExecuteNonQuery();
        }

        public static void SaveWorksheet(string connectionString, ItemVariantSalesWorksheetHeader header, IReadOnlyList<ItemVariantSalesWorksheetLine> lines)
        {
            EnsureTablesExist(connectionString);

            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var transaction = connection.BeginTransaction();

            using (var deleteLines = new SqlCommand("DELETE FROM dbo.ItemVariantSalesWorksheetLine WHERE [Document No.] = @DocumentNo", connection, transaction))
            {
                deleteLines.Parameters.AddWithValue("@DocumentNo", header.DocumentNo);
                deleteLines.ExecuteNonQuery();
            }

            using (var deleteHeader = new SqlCommand("DELETE FROM dbo.ItemVariantSalesWorksheetHeader WHERE [No.] = @DocumentNo", connection, transaction))
            {
                deleteHeader.Parameters.AddWithValue("@DocumentNo", header.DocumentNo);
                deleteHeader.ExecuteNonQuery();
            }

            using (var insertHeader = new SqlCommand(@"
INSERT INTO dbo.ItemVariantSalesWorksheetHeader ([No.], [Generated Date], [From Date], [To Date], [Warehouse], [Item Variant Filter], [Generated By])
VALUES (@DocumentNo, @GeneratedDate, @FromDate, @ToDate, @Warehouse, @ItemVariantFilter, @GeneratedBy)", connection, transaction))
            {
                insertHeader.Parameters.AddWithValue("@DocumentNo", header.DocumentNo);
                insertHeader.Parameters.AddWithValue("@GeneratedDate", header.GeneratedDate);
                insertHeader.Parameters.AddWithValue("@FromDate", header.FromDate.Date);
                insertHeader.Parameters.AddWithValue("@ToDate", header.ToDate.Date);
                insertHeader.Parameters.AddWithValue("@Warehouse", string.IsNullOrWhiteSpace(header.WarehouseName) ? (object)DBNull.Value : header.WarehouseName.Trim());
                insertHeader.Parameters.AddWithValue("@ItemVariantFilter", string.IsNullOrWhiteSpace(header.ItemVariantFilter) ? (object)DBNull.Value : header.ItemVariantFilter.Trim());
                insertHeader.Parameters.AddWithValue("@GeneratedBy", string.IsNullOrWhiteSpace(header.GeneratedBy) ? (object)DBNull.Value : header.GeneratedBy.Trim());
                insertHeader.ExecuteNonQuery();
            }

            using (var insertLine = new SqlCommand(@"
INSERT INTO dbo.ItemVariantSalesWorksheetLine ([Document No.], [Line No.], [Report Key], [Item No.], [Description], [Qty Transferred], [Local Sales], [Online Sales], [Qty On Hand], [Physical Qty On Hand], [Opening Stock], [Product ID])
VALUES (@DocumentNo, @LineNo, @ReportKey, @ItemNo, @Description, @QtyTransferred, @LocalSales, @OnlineSales, @QtyOnHand, @PhysicalQtyOnHand, @OpeningStock, @ProductId)", connection, transaction))
            {
                var documentNoParameter = insertLine.Parameters.Add("@DocumentNo", System.Data.SqlDbType.NVarChar, 50);
                var lineNoParameter = insertLine.Parameters.Add("@LineNo", System.Data.SqlDbType.Int);
                var reportKeyParameter = insertLine.Parameters.Add("@ReportKey", System.Data.SqlDbType.NVarChar, 200);
                var itemNoParameter = insertLine.Parameters.Add("@ItemNo", System.Data.SqlDbType.NVarChar, 200);
                var descriptionParameter = insertLine.Parameters.Add("@Description", System.Data.SqlDbType.NVarChar, 500);
                var qtyTransferredParameter = insertLine.Parameters.Add("@QtyTransferred", System.Data.SqlDbType.Decimal);
                var localSalesParameter = insertLine.Parameters.Add("@LocalSales", System.Data.SqlDbType.Decimal);
                var onlineSalesParameter = insertLine.Parameters.Add("@OnlineSales", System.Data.SqlDbType.Decimal);
                var qtyOnHandParameter = insertLine.Parameters.Add("@QtyOnHand", System.Data.SqlDbType.Decimal);
                var physicalQtyParameter = insertLine.Parameters.Add("@PhysicalQtyOnHand", System.Data.SqlDbType.Decimal);
                var openingStockParameter = insertLine.Parameters.Add("@OpeningStock", System.Data.SqlDbType.Decimal);
                var productIdParameter = insertLine.Parameters.Add("@ProductId", System.Data.SqlDbType.NVarChar, 100);

                qtyTransferredParameter.Precision = 18;
                qtyTransferredParameter.Scale = 2;
                localSalesParameter.Precision = 18;
                localSalesParameter.Scale = 2;
                onlineSalesParameter.Precision = 18;
                onlineSalesParameter.Scale = 2;
                qtyOnHandParameter.Precision = 18;
                qtyOnHandParameter.Scale = 2;
                physicalQtyParameter.Precision = 18;
                physicalQtyParameter.Scale = 2;
                openingStockParameter.Precision = 18;
                openingStockParameter.Scale = 2;

                foreach (var line in lines)
                {
                    documentNoParameter.Value = header.DocumentNo;
                    lineNoParameter.Value = line.LineNo;
                    reportKeyParameter.Value = string.IsNullOrWhiteSpace(line.ReportKey) ? (object)DBNull.Value : line.ReportKey.Trim();
                    itemNoParameter.Value = string.IsNullOrWhiteSpace(line.ItemNo) ? (object)DBNull.Value : line.ItemNo.Trim();
                    descriptionParameter.Value = string.IsNullOrWhiteSpace(line.Description) ? (object)DBNull.Value : line.Description.Trim();
                    qtyTransferredParameter.Value = line.QtyTransferred;
                    localSalesParameter.Value = line.LocalSales;
                    onlineSalesParameter.Value = line.OnlineSales;
                    qtyOnHandParameter.Value = line.QtyOnHand;
                    physicalQtyParameter.Value = line.PhysicalQtyOnHand.HasValue ? line.PhysicalQtyOnHand.Value : DBNull.Value;
                    openingStockParameter.Value = line.OpeningStock;
                    productIdParameter.Value = string.IsNullOrWhiteSpace(line.ProductId) ? (object)DBNull.Value : line.ProductId.Trim();
                    insertLine.ExecuteNonQuery();
                }
            }

            transaction.Commit();
        }

        public static ItemVariantSalesWorksheetHeader? GetWorksheetHeader(string connectionString, string documentNo)
        {
            EnsureTablesExist(connectionString);

            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var command = new SqlCommand(@"
SELECT [No.], [Generated Date], [From Date], [To Date], [Warehouse], [Item Variant Filter], [Generated By]
FROM dbo.ItemVariantSalesWorksheetHeader
WHERE [No.] = @DocumentNo", connection);
            command.Parameters.AddWithValue("@DocumentNo", documentNo);

            using var reader = command.ExecuteReader();
            if (!reader.Read())
                return null;

            return new ItemVariantSalesWorksheetHeader
            {
                DocumentNo = reader["No."]?.ToString()?.Trim() ?? string.Empty,
                GeneratedDate = reader["Generated Date"] == DBNull.Value ? DateTime.MinValue : Convert.ToDateTime(reader["Generated Date"]),
                FromDate = reader["From Date"] == DBNull.Value ? DateTime.MinValue : Convert.ToDateTime(reader["From Date"]),
                ToDate = reader["To Date"] == DBNull.Value ? DateTime.MinValue : Convert.ToDateTime(reader["To Date"]),
                WarehouseName = reader["Warehouse"]?.ToString()?.Trim() ?? string.Empty,
                ItemVariantFilter = reader["Item Variant Filter"]?.ToString()?.Trim() ?? string.Empty,
                GeneratedBy = reader["Generated By"]?.ToString()?.Trim() ?? string.Empty
            };
        }

        public static List<ItemVariantSalesWorksheetLine> GetWorksheetLines(string connectionString, string documentNo)
        {
            EnsureTablesExist(connectionString);

            var lines = new List<ItemVariantSalesWorksheetLine>();
            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var command = new SqlCommand(@"
SELECT [Line No.], [Report Key], [Item No.], [Description], [Qty Transferred], [Local Sales], [Online Sales], [Qty On Hand], [Physical Qty On Hand], [Opening Stock], [Product ID]
FROM dbo.ItemVariantSalesWorksheetLine
WHERE [Document No.] = @DocumentNo
ORDER BY [Line No.]", connection);
            command.Parameters.AddWithValue("@DocumentNo", documentNo);

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                lines.Add(new ItemVariantSalesWorksheetLine
                {
                    LineNo = reader["Line No."] == DBNull.Value ? 0 : Convert.ToInt32(reader["Line No."]),
                    ReportKey = reader["Report Key"]?.ToString()?.Trim() ?? string.Empty,
                    ItemNo = reader["Item No."]?.ToString()?.Trim() ?? string.Empty,
                    Description = reader["Description"]?.ToString()?.Trim() ?? string.Empty,
                    QtyTransferred = reader["Qty Transferred"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Qty Transferred"]),
                    LocalSales = reader["Local Sales"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Local Sales"]),
                    OnlineSales = reader["Online Sales"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Online Sales"]),
                    QtyOnHand = reader["Qty On Hand"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Qty On Hand"]),
                    PhysicalQtyOnHand = reader["Physical Qty On Hand"] == DBNull.Value ? null : Convert.ToDecimal(reader["Physical Qty On Hand"]),
                    OpeningStock = reader["Opening Stock"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Opening Stock"]),
                    ProductId = reader["Product ID"]?.ToString()?.Trim() ?? string.Empty
                });
            }

            return lines
                .OrderByDescending(line => line.TotalSalesCount)
                .ThenBy(line => string.IsNullOrWhiteSpace(line.Description) ? line.ItemNo : line.Description, StringComparer.OrdinalIgnoreCase)
                .ThenBy(line => line.ItemNo, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        public static void SavePhysicalQtyOnHand(string connectionString, string documentNo, int lineNo, decimal? physicalQtyOnHand)
        {
            EnsureTablesExist(connectionString);

            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var command = new SqlCommand(@"
UPDATE dbo.ItemVariantSalesWorksheetLine
SET [Physical Qty On Hand] = @PhysicalQtyOnHand
WHERE [Document No.] = @DocumentNo
  AND [Line No.] = @LineNo", connection);
            command.Parameters.AddWithValue("@DocumentNo", documentNo);
            command.Parameters.AddWithValue("@LineNo", lineNo);
            command.Parameters.AddWithValue("@PhysicalQtyOnHand", physicalQtyOnHand.HasValue ? physicalQtyOnHand.Value : DBNull.Value);
            command.ExecuteNonQuery();
        }

        public static void SaveMonthEndPost(string connectionString, MonthEndHeader header, IReadOnlyList<MonthEndLine> lines)
        {
            EnsureTablesExist(connectionString);

            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var transaction = connection.BeginTransaction();

            using (var deleteLines = new SqlCommand("DELETE FROM dbo.MonthEndLines WHERE [Document No.] = @DocumentNo", connection, transaction))
            {
                deleteLines.Parameters.AddWithValue("@DocumentNo", header.DocumentNo);
                deleteLines.ExecuteNonQuery();
            }

            using (var deleteHeader = new SqlCommand("DELETE FROM dbo.MonthEndHeader WHERE [No.] = @DocumentNo", connection, transaction))
            {
                deleteHeader.Parameters.AddWithValue("@DocumentNo", header.DocumentNo);
                deleteHeader.ExecuteNonQuery();
            }

            using (var insertHeader = new SqlCommand(@"
INSERT INTO dbo.MonthEndHeader ([No.], [Worksheet No.], [Worksheet Generated Date], [From Date], [To Date], [Warehouse], [Item Variant Filter], [Worksheet Generated By], [Posted By], [Posted AtUtc], [Total Lines], [Cloud Patched Lines], [Cloud Skipped Lines], [Cloud Failed Lines])
VALUES (@DocumentNo, @WorksheetDocumentNo, @WorksheetGeneratedDate, @FromDate, @ToDate, @Warehouse, @ItemVariantFilter, @WorksheetGeneratedBy, @PostedBy, @PostedAtUtc, @TotalLines, @CloudPatchedLines, @CloudSkippedLines, @CloudFailedLines)", connection, transaction))
            {
                insertHeader.Parameters.AddWithValue("@DocumentNo", header.DocumentNo);
                insertHeader.Parameters.AddWithValue("@WorksheetDocumentNo", header.WorksheetDocumentNo);
                insertHeader.Parameters.AddWithValue("@WorksheetGeneratedDate", header.WorksheetGeneratedDate == DateTime.MinValue ? (object)DBNull.Value : header.WorksheetGeneratedDate);
                insertHeader.Parameters.AddWithValue("@FromDate", header.FromDate.Date);
                insertHeader.Parameters.AddWithValue("@ToDate", header.ToDate.Date);
                insertHeader.Parameters.AddWithValue("@Warehouse", string.IsNullOrWhiteSpace(header.WarehouseName) ? (object)DBNull.Value : header.WarehouseName.Trim());
                insertHeader.Parameters.AddWithValue("@ItemVariantFilter", string.IsNullOrWhiteSpace(header.ItemVariantFilter) ? (object)DBNull.Value : header.ItemVariantFilter.Trim());
                insertHeader.Parameters.AddWithValue("@WorksheetGeneratedBy", string.IsNullOrWhiteSpace(header.WorksheetGeneratedBy) ? (object)DBNull.Value : header.WorksheetGeneratedBy.Trim());
                insertHeader.Parameters.AddWithValue("@PostedBy", string.IsNullOrWhiteSpace(header.PostedBy) ? (object)DBNull.Value : header.PostedBy.Trim());
                insertHeader.Parameters.AddWithValue("@PostedAtUtc", header.PostedAtUtc == DateTime.MinValue ? DateTime.UtcNow : header.PostedAtUtc);
                insertHeader.Parameters.AddWithValue("@TotalLines", header.TotalLines);
                insertHeader.Parameters.AddWithValue("@CloudPatchedLines", header.CloudPatchedLines);
                insertHeader.Parameters.AddWithValue("@CloudSkippedLines", header.CloudSkippedLines);
                insertHeader.Parameters.AddWithValue("@CloudFailedLines", header.CloudFailedLines);
                insertHeader.ExecuteNonQuery();
            }

            using (var insertLine = new SqlCommand(@"
INSERT INTO dbo.MonthEndLines ([Document No.], [Line No.], [Report Key], [Item No.], [Description], [Qty Transferred], [Local Sales], [Online Sales], [Qty On Hand], [Physical Qty On Hand], [Opening Stock], [Variation ID], [Cloud Warehouse ID], [Cloud Previous Qty On Hand], [Cloud Updated Qty On Hand], [Cloud Patch Status], [Cloud Patch Message], [Sent To Online], [Last Error Endpoint], [Last Error Payload], [Last Error Message], [Product ID])
VALUES (@DocumentNo, @LineNo, @ReportKey, @ItemNo, @Description, @QtyTransferred, @LocalSales, @OnlineSales, @QtyOnHand, @PhysicalQtyOnHand, @OpeningStock, @VariationId, @CloudWarehouseId, @CloudPreviousQtyOnHand, @CloudUpdatedQtyOnHand, @CloudPatchStatus, @CloudPatchMessage, @SentToOnline, @LastErrorEndpoint, @LastErrorPayload, @LastErrorMessage, @ProductId)", connection, transaction))
            {
                var documentNoParameter = insertLine.Parameters.Add("@DocumentNo", System.Data.SqlDbType.NVarChar, 50);
                var lineNoParameter = insertLine.Parameters.Add("@LineNo", System.Data.SqlDbType.Int);
                var reportKeyParameter = insertLine.Parameters.Add("@ReportKey", System.Data.SqlDbType.NVarChar, 200);
                var itemNoParameter = insertLine.Parameters.Add("@ItemNo", System.Data.SqlDbType.NVarChar, 200);
                var descriptionParameter = insertLine.Parameters.Add("@Description", System.Data.SqlDbType.NVarChar, 500);
                var qtyTransferredParameter = insertLine.Parameters.Add("@QtyTransferred", System.Data.SqlDbType.Decimal);
                var localSalesParameter = insertLine.Parameters.Add("@LocalSales", System.Data.SqlDbType.Decimal);
                var onlineSalesParameter = insertLine.Parameters.Add("@OnlineSales", System.Data.SqlDbType.Decimal);
                var qtyOnHandParameter = insertLine.Parameters.Add("@QtyOnHand", System.Data.SqlDbType.Decimal);
                var physicalQtyParameter = insertLine.Parameters.Add("@PhysicalQtyOnHand", System.Data.SqlDbType.Decimal);
                var openingStockParameter = insertLine.Parameters.Add("@OpeningStock", System.Data.SqlDbType.Decimal);
                var variationIdParameter = insertLine.Parameters.Add("@VariationId", System.Data.SqlDbType.NVarChar, 100);
                var cloudWarehouseIdParameter = insertLine.Parameters.Add("@CloudWarehouseId", System.Data.SqlDbType.NVarChar, 100);
                var cloudPreviousQtyParameter = insertLine.Parameters.Add("@CloudPreviousQtyOnHand", System.Data.SqlDbType.Decimal);
                var cloudUpdatedQtyParameter = insertLine.Parameters.Add("@CloudUpdatedQtyOnHand", System.Data.SqlDbType.Decimal);
                var cloudPatchStatusParameter = insertLine.Parameters.Add("@CloudPatchStatus", System.Data.SqlDbType.NVarChar, 50);
                var cloudPatchMessageParameter = insertLine.Parameters.Add("@CloudPatchMessage", System.Data.SqlDbType.NVarChar, -1);
                var sentToOnlineParameter = insertLine.Parameters.Add("@SentToOnline", System.Data.SqlDbType.Bit);
                var lastErrorEndpointParameter = insertLine.Parameters.Add("@LastErrorEndpoint", System.Data.SqlDbType.NVarChar, 500);
                var lastErrorPayloadParameter = insertLine.Parameters.Add("@LastErrorPayload", System.Data.SqlDbType.NVarChar, -1);
                var lastErrorMessageParameter = insertLine.Parameters.Add("@LastErrorMessage", System.Data.SqlDbType.NVarChar, -1);
                var productIdParameter = insertLine.Parameters.Add("@ProductId", System.Data.SqlDbType.NVarChar, 100);

                qtyTransferredParameter.Precision = 18;
                qtyTransferredParameter.Scale = 2;
                localSalesParameter.Precision = 18;
                localSalesParameter.Scale = 2;
                onlineSalesParameter.Precision = 18;
                onlineSalesParameter.Scale = 2;
                qtyOnHandParameter.Precision = 18;
                qtyOnHandParameter.Scale = 2;
                physicalQtyParameter.Precision = 18;
                physicalQtyParameter.Scale = 2;
                openingStockParameter.Precision = 18;
                openingStockParameter.Scale = 2;
                cloudPreviousQtyParameter.Precision = 18;
                cloudPreviousQtyParameter.Scale = 2;
                cloudUpdatedQtyParameter.Precision = 18;
                cloudUpdatedQtyParameter.Scale = 2;

                foreach (var line in lines)
                {
                    documentNoParameter.Value = header.DocumentNo;
                    lineNoParameter.Value = line.LineNo;
                    reportKeyParameter.Value = string.IsNullOrWhiteSpace(line.ReportKey) ? (object)DBNull.Value : line.ReportKey.Trim();
                    itemNoParameter.Value = string.IsNullOrWhiteSpace(line.ItemNo) ? (object)DBNull.Value : line.ItemNo.Trim();
                    descriptionParameter.Value = string.IsNullOrWhiteSpace(line.Description) ? (object)DBNull.Value : line.Description.Trim();
                    qtyTransferredParameter.Value = line.QtyTransferred;
                    localSalesParameter.Value = line.LocalSales;
                    onlineSalesParameter.Value = line.OnlineSales;
                    qtyOnHandParameter.Value = line.QtyOnHand;
                    physicalQtyParameter.Value = line.PhysicalQtyOnHand.HasValue ? line.PhysicalQtyOnHand.Value : DBNull.Value;
                    openingStockParameter.Value = line.OpeningStock;
                    variationIdParameter.Value = string.IsNullOrWhiteSpace(line.VariationId) ? (object)DBNull.Value : line.VariationId.Trim();
                    cloudWarehouseIdParameter.Value = string.IsNullOrWhiteSpace(line.CloudWarehouseId) ? (object)DBNull.Value : line.CloudWarehouseId.Trim();
                    cloudPreviousQtyParameter.Value = line.CloudPreviousQtyOnHand.HasValue ? line.CloudPreviousQtyOnHand.Value : DBNull.Value;
                    cloudUpdatedQtyParameter.Value = line.CloudUpdatedQtyOnHand.HasValue ? line.CloudUpdatedQtyOnHand.Value : DBNull.Value;
                    cloudPatchStatusParameter.Value = string.IsNullOrWhiteSpace(line.CloudPatchStatus) ? (object)DBNull.Value : line.CloudPatchStatus.Trim();
                    cloudPatchMessageParameter.Value = string.IsNullOrWhiteSpace(line.CloudPatchMessage) ? (object)DBNull.Value : line.CloudPatchMessage.Trim();
                    sentToOnlineParameter.Value = line.SentToOnline;
                    lastErrorEndpointParameter.Value = string.IsNullOrWhiteSpace(line.LastErrorEndpoint) ? (object)DBNull.Value : line.LastErrorEndpoint.Trim();
                    lastErrorPayloadParameter.Value = string.IsNullOrWhiteSpace(line.LastErrorPayload) ? (object)DBNull.Value : line.LastErrorPayload.Trim();
                    lastErrorMessageParameter.Value = string.IsNullOrWhiteSpace(line.LastErrorMessage) ? (object)DBNull.Value : line.LastErrorMessage.Trim();
                    productIdParameter.Value = string.IsNullOrWhiteSpace(line.ProductId) ? (object)DBNull.Value : line.ProductId.Trim();
                    insertLine.ExecuteNonQuery();
                }
            }

            transaction.Commit();
        }

        public static List<MonthEndHeader> GetMonthEndHeaders(string connectionString)
        {
            EnsureTablesExist(connectionString);

            var headers = new List<MonthEndHeader>();
            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var command = new SqlCommand(@"
SELECT h.[No.], h.[Worksheet No.], h.[Worksheet Generated Date], h.[From Date], h.[To Date], h.[Warehouse], h.[Item Variant Filter], h.[Worksheet Generated By], h.[Posted By], h.[Posted AtUtc], h.[Total Lines], h.[Cloud Patched Lines], h.[Cloud Skipped Lines], h.[Cloud Failed Lines], h.[Sent To Cloud],
    CASE WHEN EXISTS (
        SELECT 1 FROM dbo.MonthEndLines l
        WHERE l.[Document No.] = h.[No.] AND l.[Cloud Patch Status] = 'FAILED'
    ) THEN 0 ELSE 1 END AS [Cloud Sync Success]
FROM dbo.MonthEndHeader h
ORDER BY h.[Posted AtUtc] DESC, h.[No.] DESC", connection);

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                headers.Add(new MonthEndHeader
                {
                    DocumentNo = reader["No."]?.ToString()?.Trim() ?? string.Empty,
                    WorksheetDocumentNo = reader["Worksheet No."]?.ToString()?.Trim() ?? string.Empty,
                    WorksheetGeneratedDate = reader["Worksheet Generated Date"] == DBNull.Value ? DateTime.MinValue : Convert.ToDateTime(reader["Worksheet Generated Date"]),
                    FromDate = reader["From Date"] == DBNull.Value ? DateTime.MinValue : Convert.ToDateTime(reader["From Date"]),
                    ToDate = reader["To Date"] == DBNull.Value ? DateTime.MinValue : Convert.ToDateTime(reader["To Date"]),
                    WarehouseName = reader["Warehouse"]?.ToString()?.Trim() ?? string.Empty,
                    ItemVariantFilter = reader["Item Variant Filter"]?.ToString()?.Trim() ?? string.Empty,
                    WorksheetGeneratedBy = reader["Worksheet Generated By"]?.ToString()?.Trim() ?? string.Empty,
                    PostedBy = reader["Posted By"]?.ToString()?.Trim() ?? string.Empty,
                    PostedAtUtc = reader["Posted AtUtc"] == DBNull.Value ? DateTime.MinValue : Convert.ToDateTime(reader["Posted AtUtc"]),
                    TotalLines = reader["Total Lines"] == DBNull.Value ? 0 : Convert.ToInt32(reader["Total Lines"]),
                    CloudPatchedLines = reader["Cloud Patched Lines"] == DBNull.Value ? 0 : Convert.ToInt32(reader["Cloud Patched Lines"]),
                    CloudSkippedLines = reader["Cloud Skipped Lines"] == DBNull.Value ? 0 : Convert.ToInt32(reader["Cloud Skipped Lines"]),
                    CloudFailedLines = reader["Cloud Failed Lines"] == DBNull.Value ? 0 : Convert.ToInt32(reader["Cloud Failed Lines"]),
                    SentToCloud = reader["Sent To Cloud"] != DBNull.Value && Convert.ToBoolean(reader["Sent To Cloud"]),
                    CloudSyncSuccess = reader["Cloud Sync Success"] != DBNull.Value && Convert.ToInt32(reader["Cloud Sync Success"]) != 0
                });
            }

            return headers;
        }

        public static List<MonthEndLine> GetMonthEndLines(string connectionString, string documentNo)
        {
            EnsureTablesExist(connectionString);

            var lines = new List<MonthEndLine>();
            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var command = new SqlCommand(@"
SELECT [Line No.], [Report Key], [Item No.], [Description], [Qty Transferred], [Local Sales], [Online Sales], [Qty On Hand], [Physical Qty On Hand], [Opening Stock], [Variation ID], [Cloud Warehouse ID], [Cloud Previous Qty On Hand], [Cloud Updated Qty On Hand], [Cloud Patch Status], [Cloud Patch Message], [Sent To Online], [Last Error Endpoint], [Last Error Payload], [Last Error Message], [Product ID]
FROM dbo.MonthEndLines
WHERE [Document No.] = @DocumentNo
ORDER BY [Line No.]", connection);
            command.Parameters.AddWithValue("@DocumentNo", documentNo);

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                lines.Add(new MonthEndLine
                {
                    LineNo = reader["Line No."] == DBNull.Value ? 0 : Convert.ToInt32(reader["Line No."]),
                    ReportKey = reader["Report Key"]?.ToString()?.Trim() ?? string.Empty,
                    ItemNo = reader["Item No."]?.ToString()?.Trim() ?? string.Empty,
                    Description = reader["Description"]?.ToString()?.Trim() ?? string.Empty,
                    QtyTransferred = reader["Qty Transferred"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Qty Transferred"]),
                    LocalSales = reader["Local Sales"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Local Sales"]),
                    OnlineSales = reader["Online Sales"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Online Sales"]),
                    QtyOnHand = reader["Qty On Hand"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Qty On Hand"]),
                    PhysicalQtyOnHand = reader["Physical Qty On Hand"] == DBNull.Value ? null : Convert.ToDecimal(reader["Physical Qty On Hand"]),
                    OpeningStock = reader["Opening Stock"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["Opening Stock"]),
                    VariationId = reader["Variation ID"]?.ToString()?.Trim() ?? string.Empty,
                    CloudWarehouseId = reader["Cloud Warehouse ID"]?.ToString()?.Trim() ?? string.Empty,
                    CloudPreviousQtyOnHand = reader["Cloud Previous Qty On Hand"] == DBNull.Value ? null : Convert.ToDecimal(reader["Cloud Previous Qty On Hand"]),
                    CloudUpdatedQtyOnHand = reader["Cloud Updated Qty On Hand"] == DBNull.Value ? null : Convert.ToDecimal(reader["Cloud Updated Qty On Hand"]),
                    CloudPatchStatus = reader["Cloud Patch Status"]?.ToString()?.Trim() ?? string.Empty,
                    CloudPatchMessage = reader["Cloud Patch Message"]?.ToString()?.Trim() ?? string.Empty,
                    SentToOnline = reader["Sent To Online"] != DBNull.Value && Convert.ToBoolean(reader["Sent To Online"]),
                    LastErrorEndpoint = reader["Last Error Endpoint"]?.ToString()?.Trim() ?? string.Empty,
                    LastErrorPayload = reader["Last Error Payload"]?.ToString()?.Trim() ?? string.Empty,
                    LastErrorMessage = reader["Last Error Message"]?.ToString()?.Trim() ?? string.Empty,
                    ProductId = reader["Product ID"]?.ToString()?.Trim() ?? string.Empty
                });
            }

            return lines;
        }

        /// <summary>
        /// Returns the Opening Stock (prior month's closing stock) for each Report Key, sourced from
        /// the most recently posted Month End line (dbo.MonthEndLines/MonthEndHeader) whose header
        /// [To Date] is before the given date. Falls back to the posted Qty On Hand when no Physical
        /// Qty On Hand was recorded for that prior line.
        /// </summary>
        public static Dictionary<string, decimal> GetOpeningStockByReportKey(string connectionString, DateTime beforeDate)
        {
            EnsureTablesExist(connectionString);

            var result = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var command = new SqlCommand(@"
;WITH RankedLines AS (
    SELECT l.[Report Key] AS ReportKey,
           l.[Physical Qty On Hand] AS PhysicalQtyOnHand,
           l.[Qty On Hand] AS QtyOnHand,
           ROW_NUMBER() OVER (PARTITION BY l.[Report Key] ORDER BY h.[To Date] DESC, h.[Posted AtUtc] DESC) AS rn
    FROM dbo.MonthEndLines l
    INNER JOIN dbo.MonthEndHeader h ON h.[No.] = l.[Document No.]
    WHERE h.[To Date] < @BeforeDate
      AND l.[Report Key] IS NOT NULL AND l.[Report Key] <> ''
)
SELECT ReportKey, COALESCE(PhysicalQtyOnHand, QtyOnHand) AS OpeningStock
FROM RankedLines
WHERE rn = 1", connection);
            command.Parameters.AddWithValue("@BeforeDate", beforeDate.Date);

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                string reportKey = reader["ReportKey"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(reportKey))
                    continue;

                result[reportKey] = reader["OpeningStock"] == DBNull.Value ? 0m : Convert.ToDecimal(reader["OpeningStock"]);
            }

            return result;
        }

        public static void UpdateMonthEndLineCloudStatus(
            string connectionString,
            string documentNo,
            int lineNo,
            decimal? cloudPreviousQtyOnHand,
            decimal? cloudUpdatedQtyOnHand,
            string cloudPatchStatus,
            string cloudPatchMessage,
            bool sentToOnline,
            string? lastErrorEndpoint = null,
            string? lastErrorPayload = null,
            string? lastErrorMessage = null,
            string? productId = null)
        {
            EnsureTablesExist(connectionString);

            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var command = new SqlCommand(@"
UPDATE dbo.MonthEndLines
SET [Cloud Previous Qty On Hand] = @CloudPreviousQtyOnHand,
    [Cloud Updated Qty On Hand] = @CloudUpdatedQtyOnHand,
    [Cloud Patch Status] = @CloudPatchStatus,
    [Cloud Patch Message] = @CloudPatchMessage,
    [Sent To Online] = @SentToOnline,
    [Last Error Endpoint] = @LastErrorEndpoint,
    [Last Error Payload] = @LastErrorPayload,
    [Last Error Message] = @LastErrorMessage,
    [Product ID] = COALESCE(NULLIF(@ProductId, ''), [Product ID])
WHERE [Document No.] = @DocumentNo
  AND [Line No.] = @LineNo", connection);
            command.Parameters.AddWithValue("@DocumentNo", documentNo);
            command.Parameters.AddWithValue("@LineNo", lineNo);
            command.Parameters.AddWithValue("@CloudPreviousQtyOnHand", cloudPreviousQtyOnHand.HasValue ? cloudPreviousQtyOnHand.Value : (object)DBNull.Value);
            command.Parameters.AddWithValue("@CloudUpdatedQtyOnHand", cloudUpdatedQtyOnHand.HasValue ? cloudUpdatedQtyOnHand.Value : (object)DBNull.Value);
            command.Parameters.AddWithValue("@CloudPatchStatus", string.IsNullOrWhiteSpace(cloudPatchStatus) ? (object)DBNull.Value : cloudPatchStatus.Trim());
            command.Parameters.AddWithValue("@CloudPatchMessage", string.IsNullOrWhiteSpace(cloudPatchMessage) ? (object)DBNull.Value : cloudPatchMessage.Trim());
            command.Parameters.AddWithValue("@SentToOnline", sentToOnline);
            command.Parameters.AddWithValue("@LastErrorEndpoint", string.IsNullOrWhiteSpace(lastErrorEndpoint) ? (object)DBNull.Value : lastErrorEndpoint.Trim());
            command.Parameters.AddWithValue("@LastErrorPayload", string.IsNullOrWhiteSpace(lastErrorPayload) ? (object)DBNull.Value : lastErrorPayload.Trim());
            command.Parameters.AddWithValue("@LastErrorMessage", string.IsNullOrWhiteSpace(lastErrorMessage) ? (object)DBNull.Value : lastErrorMessage.Trim());
            command.Parameters.AddWithValue("@ProductId", string.IsNullOrWhiteSpace(productId) ? string.Empty : productId.Trim());
            command.ExecuteNonQuery();
        }

        /// <summary>
        /// Persists whether the given Month End header (and its lines) were successfully sent to
        /// Supabase (dbo.MonthEndHeader.[Sent To Cloud]).
        /// </summary>
        public static void UpdateMonthEndHeaderSentToCloud(string connectionString, string documentNo, bool sentToCloud)
        {
            EnsureTablesExist(connectionString);

            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var command = new SqlCommand(@"UPDATE dbo.MonthEndHeader SET [Sent To Cloud] = @SentToCloud WHERE [No.] = @DocumentNo", connection);
            command.Parameters.AddWithValue("@DocumentNo", documentNo);
            command.Parameters.AddWithValue("@SentToCloud", sentToCloud);
            command.ExecuteNonQuery();
        }
    }
}