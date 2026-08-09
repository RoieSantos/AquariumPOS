using System;
using System.Collections.Generic;
using System.Data.SqlClient;

namespace AquariumPOS
{
    internal static class TransferOrderData
    {
        public const string HeaderTableName = "dbo.[Transfer Header]";
        public const string LineTableName = "dbo.[Transfer Line]";
        public const string RequestHeaderTableName = "dbo.[Transfer Request Header]";
        public const string RequestLineTableName = "dbo.[Transfer Request Line]";

        internal sealed class DocumentTableContext
        {
            public string HeaderTableName { get; init; } = string.Empty;
            public string LineTableName { get; init; } = string.Empty;
            public string ListTitle { get; init; } = string.Empty;
            public string DocumentTitle { get; init; } = string.Empty;
            public string DocumentDisplayName { get; init; } = "transfer order";
            public string NumberPrefix { get; init; } = "TO-";
            public string NewDescriptionLabel { get; init; } = "Transfer request";
            public bool AllowSync { get; init; }
            public bool IsReadOnly { get; init; }
        }

        public static DocumentTableContext PostedTransferOrders { get; } = new()
        {
            HeaderTableName = HeaderTableName,
            LineTableName = LineTableName,
            ListTitle = "Posted Transfer Order List",
            DocumentTitle = "Transfer Order",
            DocumentDisplayName = "transfer order",
            NumberPrefix = "TO-",
            NewDescriptionLabel = "Transfer request",
            AllowSync = true,
            IsReadOnly = true
        };

        public static DocumentTableContext TransferRequests { get; } = new()
        {
            HeaderTableName = RequestHeaderTableName,
            LineTableName = RequestLineTableName,
            ListTitle = "Transfer Request List",
            DocumentTitle = "Transfer Request",
            DocumentDisplayName = "transfer request",
            NumberPrefix = "TR-",
            NewDescriptionLabel = "Transfer request",
            AllowSync = false,
            IsReadOnly = false
        };

        internal sealed class WarehouseOption
        {
            public string Id { get; init; } = string.Empty;
            public string Name { get; init; } = string.Empty;
            public bool IsProductionWarehouse { get; init; }
            public bool IsStockWarehouse { get; init; }
            public override string ToString() => Name;
        }

        internal sealed class LocalTransferSyncSummary
        {
            public int HeaderCount { get; init; }
            public DateTime? LatestSyncAt { get; init; }
        }

        public static void EnsureTablesExist(string connectionString)
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using var command = new SqlCommand(@"
IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[Transfer Header]
    (
        [No.] NVARCHAR(50) NOT NULL PRIMARY KEY,
        [Description] NVARCHAR(255) NULL,
        [Created Date] DATE NULL,
        [Status] NVARCHAR(50) NULL,
        [Requested Date] DATE NULL,
        [Estimated Delivery Date] DATE NULL,
        [Transfer Date] DATE NULL,
        [Receive Date] DATE NULL,
        [Posted Date] DATETIME2(0) NULL,
        [Sent To Online] BIT NOT NULL CONSTRAINT DF_TransferHeader_SentToOnline DEFAULT 0,
        [Use Production Category] BIT NOT NULL CONSTRAINT DF_TransferHeader_UseProductionCategory DEFAULT 0,
        [Category Code] NVARCHAR(100) NULL,
        [From Warehouse ID] NVARCHAR(100) NULL,
        [From Warehouse] NVARCHAR(255) NULL,
        [To Warehouse ID] NVARCHAR(100) NULL,
        [To Warehouse] NVARCHAR(255) NULL,
        [Remote Transfer ID] NVARCHAR(100) NULL,
        [Remote Updated At] DATETIME2(0) NULL,
        [Online Transfer Response] NVARCHAR(MAX) NULL,
        [Created At] DATETIME2(0) NOT NULL CONSTRAINT DF_TransferHeader_CreatedAt DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Posted Date') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Posted Date] DATETIME2(0) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Status') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Status] NVARCHAR(50) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Created Date') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Created Date] DATE NULL;
    EXEC(N'
        UPDATE dbo.[Transfer Header]
        SET [Created Date] = CAST([Created At] AS DATE)
        WHERE [Created Date] IS NULL AND [Created At] IS NOT NULL;
    ');
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Requested Date') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Requested Date] DATE NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Estimated Delivery Date') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Estimated Delivery Date] DATE NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Sent To Online') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Sent To Online] BIT NOT NULL CONSTRAINT DF_TransferHeader_SentToOnline_Legacy DEFAULT 0;
    EXEC(N'
        UPDATE dbo.[Transfer Header]
        SET [Sent To Online] = 1
        WHERE [Posted Date] IS NOT NULL;
    ');
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Online Transfer Response') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Online Transfer Response] NVARCHAR(MAX) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'From Warehouse ID') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [From Warehouse ID] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Category Code') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Category Code] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Use Production Category') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Use Production Category] BIT NOT NULL CONSTRAINT DF_TransferHeader_UseProductionCategory_Legacy DEFAULT 0;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'From Warehouse') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [From Warehouse] NVARCHAR(255) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'To Warehouse ID') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [To Warehouse ID] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'To Warehouse') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [To Warehouse] NVARCHAR(255) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Remote Transfer ID') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Remote Transfer ID] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Header]', N'Remote Updated At') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Header] ADD [Remote Updated At] DATETIME2(0) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Line]', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[Transfer Line]
    (
        [Document No.] NVARCHAR(50) NOT NULL,
        [Item No.] NVARCHAR(100) NULL,
        [Variant ID] NVARCHAR(200) NULL,
        [Description] NVARCHAR(255) NULL,
        [CategoryCode] NVARCHAR(100) NULL,
        [Line No.] INT NOT NULL,
        [Available QTY] DECIMAL(18, 2) NULL,
        [Qty To Transfer] DECIMAL(18, 2) NULL,
        [Qty To Receive] DECIMAL(18, 2) NULL,
        [Qty Received] DECIMAL(18, 2) NULL,
        CONSTRAINT PK_TransferLine PRIMARY KEY ([Document No.], [Line No.])
    );
END;

IF OBJECT_ID(N'dbo.[Transfer Line]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Line]', N'Variant ID') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Line] ADD [Variant ID] NVARCHAR(200) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Line]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Line]', N'Qty To Receive') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Line] ADD [Qty To Receive] DECIMAL(18, 2) NULL;
    EXEC(N'
        UPDATE dbo.[Transfer Line]
        SET [Qty To Receive] = [Qty To Transfer]
        WHERE [Qty To Receive] IS NULL;
    ');
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[Transfer Request Header]
    (
        [No.] NVARCHAR(50) NOT NULL PRIMARY KEY,
        [Description] NVARCHAR(255) NULL,
        [Created Date] DATE NULL,
        [Status] NVARCHAR(50) NULL,
        [Requested Date] DATE NULL,
        [Estimated Delivery Date] DATE NULL,
        [Transfer Date] DATE NULL,
        [Receive Date] DATE NULL,
        [Posted Date] DATETIME2(0) NULL,
        [Sent To Online] BIT NOT NULL CONSTRAINT DF_TransferRequestHeader_SentToOnline DEFAULT 0,
        [Use Production Category] BIT NOT NULL CONSTRAINT DF_TransferRequestHeader_UseProductionCategory DEFAULT 0,
        [Category Code] NVARCHAR(100) NULL,
        [From Warehouse ID] NVARCHAR(100) NULL,
        [From Warehouse] NVARCHAR(255) NULL,
        [To Warehouse ID] NVARCHAR(100) NULL,
        [To Warehouse] NVARCHAR(255) NULL,
        [Remote Transfer ID] NVARCHAR(100) NULL,
        [Remote Updated At] DATETIME2(0) NULL,
        [Online Transfer Response] NVARCHAR(MAX) NULL,
        [Created At] DATETIME2(0) NOT NULL CONSTRAINT DF_TransferRequestHeader_CreatedAt DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Posted Date') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Posted Date] DATETIME2(0) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Status') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Status] NVARCHAR(50) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Created Date') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Created Date] DATE NULL;
    EXEC(N'
        UPDATE dbo.[Transfer Request Header]
        SET [Created Date] = CAST([Created At] AS DATE)
        WHERE [Created Date] IS NULL AND [Created At] IS NOT NULL;
    ');
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Requested Date') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Requested Date] DATE NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Estimated Delivery Date') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Estimated Delivery Date] DATE NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Sent To Online') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Sent To Online] BIT NOT NULL CONSTRAINT DF_TransferRequestHeader_SentToOnline_Legacy DEFAULT 0;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Online Transfer Response') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Online Transfer Response] NVARCHAR(MAX) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'From Warehouse ID') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [From Warehouse ID] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Category Code') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Category Code] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Use Production Category') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Use Production Category] BIT NOT NULL CONSTRAINT DF_TransferRequestHeader_UseProductionCategory_Legacy DEFAULT 0;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'From Warehouse') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [From Warehouse] NVARCHAR(255) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'To Warehouse ID') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [To Warehouse ID] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'To Warehouse') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [To Warehouse] NVARCHAR(255) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Remote Transfer ID') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Remote Transfer ID] NVARCHAR(100) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Header]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Header]', N'Remote Updated At') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Header] ADD [Remote Updated At] DATETIME2(0) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Line]', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[Transfer Request Line]
    (
        [Document No.] NVARCHAR(50) NOT NULL,
        [Item No.] NVARCHAR(100) NULL,
        [Variant ID] NVARCHAR(200) NULL,
        [Description] NVARCHAR(255) NULL,
        [CategoryCode] NVARCHAR(100) NULL,
        [Line No.] INT NOT NULL,
        [Available QTY] DECIMAL(18, 2) NULL,
        [Qty To Transfer] DECIMAL(18, 2) NULL,
        [Qty To Receive] DECIMAL(18, 2) NULL,
        [Qty Received] DECIMAL(18, 2) NULL,
        CONSTRAINT PK_TransferRequestLine PRIMARY KEY ([Document No.], [Line No.])
    );
END;

IF OBJECT_ID(N'dbo.[Transfer Request Line]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Line]', N'Variant ID') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Line] ADD [Variant ID] NVARCHAR(200) NULL;
END;

IF OBJECT_ID(N'dbo.[Transfer Request Line]', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.[Transfer Request Line]', N'Qty To Receive') IS NULL
BEGIN
    ALTER TABLE dbo.[Transfer Request Line] ADD [Qty To Receive] DECIMAL(18, 2) NULL;
    EXEC(N'
        UPDATE dbo.[Transfer Request Line]
        SET [Qty To Receive] = [Qty To Transfer]
        WHERE [Qty To Receive] IS NULL;
    ');
END;", connection);
            command.ExecuteNonQuery();
        }

        public static List<WarehouseOption> GetWarehouseOptions(string connectionString)
        {
            var result = new List<WarehouseOption>();

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            static string Bracket(string name) => string.IsNullOrWhiteSpace(name) ? string.Empty : (name.StartsWith("[") ? name : $"[{name}]");

            if (!TryResolveWarehouseSchema(conn, out string fullTable, out string idColumn, out string nameColumn, out _, out string productionFlagColumn, out string stockFlagColumn))
                return result;

            string productionSelect = string.IsNullOrWhiteSpace(productionFlagColumn)
                ? "CAST(0 AS BIT) AS [IsProductionWarehouse]"
                : $"ISNULL({Bracket(productionFlagColumn)}, 0) AS [IsProductionWarehouse]";
            string stockSelect = string.IsNullOrWhiteSpace(stockFlagColumn)
                ? "CAST(0 AS BIT) AS [IsStockWarehouse]"
                : $"ISNULL({Bracket(stockFlagColumn)}, 0) AS [IsStockWarehouse]";

            using var cmd = new SqlCommand($"SELECT {Bracket(idColumn)} AS [ID], {Bracket(nameColumn)} AS [Name], {productionSelect}, {stockSelect} FROM {fullTable} ORDER BY {Bracket(nameColumn)}, {Bracket(idColumn)}", conn);
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string id = rdr["ID"]?.ToString()?.Trim() ?? string.Empty;
                string name = rdr["Name"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(id) && string.IsNullOrWhiteSpace(name))
                    continue;

                result.Add(new WarehouseOption
                {
                    Id = id,
                    Name = string.IsNullOrWhiteSpace(name) ? id : name,
                    IsProductionWarehouse = rdr["IsProductionWarehouse"] != DBNull.Value && Convert.ToBoolean(rdr["IsProductionWarehouse"]),
                    IsStockWarehouse = rdr["IsStockWarehouse"] != DBNull.Value && Convert.ToBoolean(rdr["IsStockWarehouse"])
                });
            }

            return result;
        }

        public static WarehouseOption? GetPreferredFromWarehouse(string connectionString, bool useProductionCategory)
        {
            foreach (var warehouse in GetWarehouseOptions(connectionString))
            {
                if (useProductionCategory && warehouse.IsProductionWarehouse)
                    return warehouse;

                if (!useProductionCategory && warehouse.IsStockWarehouse)
                    return warehouse;
            }

            return null;
        }

        public static WarehouseOption? GetCurrentWarehouse(string connectionString)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();

            static string Bracket(string name) => string.IsNullOrWhiteSpace(name) ? string.Empty : (name.StartsWith("[") ? name : $"[{name}]");

            if (!TryResolveWarehouseSchema(conn, out string fullTable, out string idColumn, out string nameColumn, out string currentFlagColumn, out string productionFlagColumn, out string stockFlagColumn)
                || string.IsNullOrWhiteSpace(currentFlagColumn))
                return null;

            string productionSelect = string.IsNullOrWhiteSpace(productionFlagColumn)
                ? "CAST(0 AS BIT) AS [IsProductionWarehouse]"
                : $"ISNULL({Bracket(productionFlagColumn)}, 0) AS [IsProductionWarehouse]";
            string stockSelect = string.IsNullOrWhiteSpace(stockFlagColumn)
                ? "CAST(0 AS BIT) AS [IsStockWarehouse]"
                : $"ISNULL({Bracket(stockFlagColumn)}, 0) AS [IsStockWarehouse]";

            using var cmd = new SqlCommand($"SELECT TOP 1 {Bracket(idColumn)} AS [ID], {Bracket(nameColumn)} AS [Name], {productionSelect}, {stockSelect} FROM {fullTable} WHERE ISNULL({Bracket(currentFlagColumn)}, 0) = 1 ORDER BY {Bracket(nameColumn)}, {Bracket(idColumn)}", conn);
            using var rdr = cmd.ExecuteReader();
            if (!rdr.Read())
                return null;

            string id = rdr["ID"]?.ToString()?.Trim() ?? string.Empty;
            string name = rdr["Name"]?.ToString()?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(id) && string.IsNullOrWhiteSpace(name))
                return null;

            return new WarehouseOption
            {
                Id = id,
                Name = string.IsNullOrWhiteSpace(name) ? id : name,
                IsProductionWarehouse = rdr["IsProductionWarehouse"] != DBNull.Value && Convert.ToBoolean(rdr["IsProductionWarehouse"]),
                IsStockWarehouse = rdr["IsStockWarehouse"] != DBNull.Value && Convert.ToBoolean(rdr["IsStockWarehouse"])
            };
        }

        public static LocalTransferSyncSummary GetLocalTransferSyncSummary(string connectionString, string? currentWarehouseId, string? currentWarehouseName)
        {
            EnsureTablesExist(connectionString);

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            string normalizedWarehouseId = (currentWarehouseId ?? string.Empty).Trim();
            string normalizedWarehouseName = (currentWarehouseName ?? string.Empty).Trim();

            using var cmd = new SqlCommand(@"
SELECT
    COUNT(*) AS HeaderCount,
    MAX(COALESCE([Remote Updated At], [Created At], [Posted Date], CAST([Receive Date] AS DATETIME2(0)), CAST([Transfer Date] AS DATETIME2(0)))) AS LatestSyncAt
FROM [Transfer Header]
WHERE (
        (@warehouseId <> '' AND LTRIM(RTRIM(ISNULL([To Warehouse ID], ''))) = @warehouseId)
        OR (@warehouseName <> '' AND LTRIM(RTRIM(ISNULL([To Warehouse], ''))) = @warehouseName)
      )", conn);
            cmd.Parameters.AddWithValue("@warehouseId", normalizedWarehouseId);
            cmd.Parameters.AddWithValue("@warehouseName", normalizedWarehouseName);

            using var reader = cmd.ExecuteReader();
            if (!reader.Read())
            {
                return new LocalTransferSyncSummary();
            }

            return new LocalTransferSyncSummary
            {
                HeaderCount = reader["HeaderCount"] != DBNull.Value ? Convert.ToInt32(reader["HeaderCount"]) : 0,
                LatestSyncAt = reader["LatestSyncAt"] != DBNull.Value ? Convert.ToDateTime(reader["LatestSyncAt"]) : null
            };
        }

        private static bool TryResolveWarehouseSchema(SqlConnection conn, out string fullTableName, out string idColumn, out string nameColumn, out string currentFlagColumn, out string productionFlagColumn, out string stockFlagColumn)
        {
            fullTableName = string.Empty;
            idColumn = string.Empty;
            nameColumn = string.Empty;
            currentFlagColumn = string.Empty;
            productionFlagColumn = string.Empty;
            stockFlagColumn = string.Empty;

            bool TryResolveSchema(string schema, string table, out string resolvedFullTableName, out string resolvedIdColumn, out string resolvedNameColumn, out string resolvedCurrentFlagColumn, out string resolvedProductionFlagColumn, out string resolvedStockFlagColumn)
            {
                resolvedFullTableName = string.Empty;
                resolvedIdColumn = string.Empty;
                resolvedNameColumn = string.Empty;
                resolvedCurrentFlagColumn = string.Empty;
                resolvedProductionFlagColumn = string.Empty;
                resolvedStockFlagColumn = string.Empty;

                try
                {
                    using var colCmd = new SqlCommand(@"SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND (TABLE_SCHEMA=@s OR @s IS NULL)", conn);
                    colCmd.Parameters.AddWithValue("@t", table);
                    colCmd.Parameters.AddWithValue("@s", string.IsNullOrWhiteSpace(schema) ? (object)DBNull.Value : schema);

                    var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    using var rdr = colCmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        var columnName = rdr[0]?.ToString() ?? string.Empty;
                        if (!string.IsNullOrWhiteSpace(columnName))
                            columns.Add(columnName);
                    }

                    if (columns.Count == 0)
                        return false;

                    resolvedIdColumn = columns.Contains("ID") ? "ID"
                        : columns.Contains("Id") ? "Id"
                        : columns.Contains("WarehouseID") ? "WarehouseID"
                        : columns.Contains("LocationID") ? "LocationID"
                        : string.Empty;

                    resolvedNameColumn = columns.Contains("Name") ? "Name"
                        : columns.Contains("L_Name") ? "L_Name"
                        : columns.Contains("LName") ? "LName"
                        : columns.Contains("LocationName") ? "LocationName"
                        : columns.Contains("WarehouseName") ? "WarehouseName"
                        : columns.Contains("Description") ? "Description"
                        : string.Empty;

                    resolvedCurrentFlagColumn = columns.Contains("Current_Warehouse") ? "Current_Warehouse"
                        : columns.Contains("Current_Location") ? "Current_Location"
                        : string.Empty;

                    resolvedProductionFlagColumn = columns.Contains("Is_Production_Warehouse") ? "Is_Production_Warehouse" : string.Empty;
                    resolvedStockFlagColumn = columns.Contains("Is_Warehouse_Stocks") ? "Is_Warehouse_Stocks" : string.Empty;

                    if (string.IsNullOrWhiteSpace(resolvedIdColumn) || string.IsNullOrWhiteSpace(resolvedNameColumn))
                        return false;

                    resolvedFullTableName = string.IsNullOrWhiteSpace(schema) ? table : $"{schema}.{table}";
                    return true;
                }
                catch
                {
                    return false;
                }
            }

            if (TryResolveSchema("dbo", "Warehouses", out fullTableName, out idColumn, out nameColumn, out currentFlagColumn, out productionFlagColumn, out stockFlagColumn)
                || TryResolveSchema(string.Empty, "Warehouses", out fullTableName, out idColumn, out nameColumn, out currentFlagColumn, out productionFlagColumn, out stockFlagColumn)
                || TryResolveSchema("dbo", "Warehouse", out fullTableName, out idColumn, out nameColumn, out currentFlagColumn, out productionFlagColumn, out stockFlagColumn)
                || TryResolveSchema(string.Empty, "Warehouse", out fullTableName, out idColumn, out nameColumn, out currentFlagColumn, out productionFlagColumn, out stockFlagColumn))
            {
                return true;
            }

            fullTableName = string.Empty;
            idColumn = string.Empty;
            nameColumn = string.Empty;
            currentFlagColumn = string.Empty;
            productionFlagColumn = string.Empty;
            stockFlagColumn = string.Empty;
            return false;
        }
    }
}