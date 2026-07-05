using System;
using System.Collections.Generic;
using System.Data.SqlClient;

namespace AquariumPOS
{
    internal static class CompleteAquariumSetData
    {
        internal sealed class PackageHeader
        {
            public string PackageName { get; init; } = string.Empty;
            public decimal PackagePrice { get; init; }
            public string VariantID { get; init; } = string.Empty;

            public string DisplayText => $"{PackageName} ({PackagePrice:N2})";
        }

        internal sealed class PackageLine
        {
            public string PackageName { get; init; } = string.Empty;
            public string ItemNo { get; init; } = string.Empty;
            public string ItemName { get; init; } = string.Empty;
            public decimal Quantity { get; init; }
            public decimal Price { get; init; }
        }

        public const string HeaderTableName = "CompleteAquariumSetHeader";
        public const string LineTableName = "CompleteAquariumSetLine";

        public static void EnsureTablesExist(string connectionString)
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using var command = new SqlCommand(@"
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CompleteAquariumSetHeader')
BEGIN
    CREATE TABLE dbo.CompleteAquariumSetHeader (
        PackageName NVARCHAR(100) NOT NULL PRIMARY KEY,
        PackagePrice DECIMAL(18,2) NOT NULL CONSTRAINT DF_CompleteAquariumSetHeader_PackagePrice DEFAULT 0,
        VariantID NVARCHAR(200) NULL,
        CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_CompleteAquariumSetHeader_CreatedDate DEFAULT GETDATE(),
        UpdatedDate DATETIME2 NOT NULL CONSTRAINT DF_CompleteAquariumSetHeader_UpdatedDate DEFAULT GETDATE()
    )
END

IF COL_LENGTH('CompleteAquariumSetHeader', 'PackagePrice') IS NULL
BEGIN
    ALTER TABLE dbo.CompleteAquariumSetHeader ADD PackagePrice DECIMAL(18,2) NOT NULL CONSTRAINT DF_CompleteAquariumSetHeader_PackagePrice_Legacy DEFAULT 0;
END

IF COL_LENGTH('CompleteAquariumSetHeader', 'VariantID') IS NULL
BEGIN
    ALTER TABLE dbo.CompleteAquariumSetHeader ADD VariantID NVARCHAR(200) NULL;
END

IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CompleteAquariumSetLine')
BEGIN
    CREATE TABLE dbo.CompleteAquariumSetLine (
        EntryNo INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        PackageName NVARCHAR(100) NOT NULL,
        ItemNo NVARCHAR(50) NOT NULL,
        ItemName NVARCHAR(255) NULL,
        Quantity DECIMAL(18,2) NOT NULL CONSTRAINT DF_CompleteAquariumSetLine_Quantity DEFAULT 1,
        Price DECIMAL(18,2) NOT NULL CONSTRAINT DF_CompleteAquariumSetLine_Price DEFAULT 0,
        CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_CompleteAquariumSetLine_CreatedDate DEFAULT GETDATE(),
        UpdatedDate DATETIME2 NOT NULL CONSTRAINT DF_CompleteAquariumSetLine_UpdatedDate DEFAULT GETDATE(),
        CONSTRAINT FK_CompleteAquariumSetLine_Header FOREIGN KEY (PackageName)
            REFERENCES dbo.CompleteAquariumSetHeader (PackageName) ON DELETE CASCADE
    );

    CREATE INDEX IX_CompleteAquariumSetLine_PackageName ON dbo.CompleteAquariumSetLine (PackageName);
END

IF COL_LENGTH('CompleteAquariumSetLine', 'ItemNo') IS NULL
BEGIN
    ALTER TABLE dbo.CompleteAquariumSetLine ADD ItemNo NVARCHAR(50) NOT NULL CONSTRAINT DF_CompleteAquariumSetLine_ItemNo DEFAULT '';
END

IF COL_LENGTH('CompleteAquariumSetLine', 'ItemName') IS NULL
BEGIN
    ALTER TABLE dbo.CompleteAquariumSetLine ADD ItemName NVARCHAR(255) NULL;
END

IF COL_LENGTH('CompleteAquariumSetLine', 'Quantity') IS NULL
BEGIN
    ALTER TABLE dbo.CompleteAquariumSetLine ADD Quantity DECIMAL(18,2) NOT NULL CONSTRAINT DF_CompleteAquariumSetLine_Quantity_Legacy DEFAULT 1;
END

IF COL_LENGTH('CompleteAquariumSetLine', 'Price') IS NULL
BEGIN
    ALTER TABLE dbo.CompleteAquariumSetLine ADD Price DECIMAL(18,2) NOT NULL CONSTRAINT DF_CompleteAquariumSetLine_Price_Legacy DEFAULT 0;
END

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_CompleteAquariumSetLine_PackageName'
      AND object_id = OBJECT_ID('dbo.CompleteAquariumSetLine'))
BEGIN
    CREATE INDEX IX_CompleteAquariumSetLine_PackageName ON dbo.CompleteAquariumSetLine (PackageName);
END
", connection);

            command.ExecuteNonQuery();
        }

        public static bool TryLookupItemDetails(string connectionString, string itemNo, out string itemName, out decimal price)
        {
            itemName = string.Empty;
            price = 0m;

            if (string.IsNullOrWhiteSpace(itemNo))
            {
                return false;
            }

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using var command = new SqlCommand(@"
SELECT TOP 1
    ISNULL(NULLIF([Name], ''), ISNULL([Description], '')) AS ItemName,
    ISNULL([Price], 0) AS Price
FROM dbo.Items
WHERE [Code] = @ItemNo", connection);
            command.Parameters.AddWithValue("@ItemNo", itemNo.Trim());

            using var reader = command.ExecuteReader();
            if (!reader.Read())
            {
                return false;
            }

            itemName = reader["ItemName"]?.ToString() ?? string.Empty;
            if (reader["Price"] != DBNull.Value)
            {
                price = Convert.ToDecimal(reader["Price"]);
            }

            return true;
        }

        public static List<PackageHeader> GetPackageHeaders(string connectionString)
        {
            var packages = new List<PackageHeader>();

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using var command = new SqlCommand(@"
SELECT PackageName, PackagePrice, ISNULL(VariantID, '') AS VariantID
FROM dbo.CompleteAquariumSetHeader
ORDER BY PackageName", connection);

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                packages.Add(new PackageHeader
                {
                    PackageName = reader["PackageName"]?.ToString()?.Trim() ?? string.Empty,
                    PackagePrice = reader["PackagePrice"] != DBNull.Value ? Convert.ToDecimal(reader["PackagePrice"]) : 0m,
                    VariantID = reader["VariantID"]?.ToString()?.Trim() ?? string.Empty
                });
            }

            return packages;
        }

        public static HashSet<string> GetPackageNamesWithLines(string connectionString)
        {
            var packageNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using var command = new SqlCommand(@"
SELECT DISTINCT PackageName
FROM dbo.CompleteAquariumSetLine
WHERE ISNULL(PackageName, '') <> ''", connection);

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                string packageName = reader["PackageName"]?.ToString()?.Trim() ?? string.Empty;
                if (!string.IsNullOrWhiteSpace(packageName))
                {
                    packageNames.Add(packageName);
                }
            }

            return packageNames;
        }

        public static List<PackageLine> GetPackageLines(string connectionString, string packageName)
        {
            var lines = new List<PackageLine>();

            if (string.IsNullOrWhiteSpace(packageName))
            {
                return lines;
            }

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using var command = new SqlCommand(@"
SELECT PackageName, ItemNo, ItemName, Quantity, Price
FROM dbo.CompleteAquariumSetLine
WHERE PackageName = @PackageName
ORDER BY EntryNo", connection);
            command.Parameters.AddWithValue("@PackageName", packageName.Trim());

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                lines.Add(new PackageLine
                {
                    PackageName = reader["PackageName"]?.ToString()?.Trim() ?? string.Empty,
                    ItemNo = reader["ItemNo"]?.ToString()?.Trim() ?? string.Empty,
                    ItemName = reader["ItemName"]?.ToString()?.Trim() ?? string.Empty,
                    Quantity = reader["Quantity"] != DBNull.Value ? Convert.ToDecimal(reader["Quantity"]) : 0m,
                    Price = reader["Price"] != DBNull.Value ? Convert.ToDecimal(reader["Price"]) : 0m
                });
            }

            return lines;
        }
    }
}
