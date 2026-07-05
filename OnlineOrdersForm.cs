using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Drawing.Printing;
using System.Net.Http;
using System.Text.Json;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class OnlineOrdersForm : Form
    {
        private const string OnlineSetPackageMapTable = "dbo.OnlineOrderSetPackageMap";
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly bool _showNonCurrentLocationsOnly;
        private DataGridView dgv = null!;
        private Button syncButton = null!;
        private Button forDeliveryButton = null!;
        private Button receiveOrderButton = null!;
        private Button linesButton = null!;
        private Button sendUpdateButton = null!;
        private Button payButton = null!;
        private Button printButton = null!;
        private Button toShipButton = null!;
        private Button productionDoneButton = null!;
        private ContextMenuStrip statusMenu = null!;
        private Label statusLabel = null!;
        private ProgressBar progressBar = null!;
        private ComboBox statusFilterCombo = null!;
        private Panel topPanel = null!;
        private TextBox customerFilterTextBox = null!;
        private Label customerFilterLabel = null!;
        private TextBox orderIdFilterTextBox = null!;
        private Label orderIdFilterLabel = null!;
        // Auto-sync timer (fires on UI thread)
        private System.Windows.Forms.Timer? autoSyncTimer = null;
        // Prevent overlapping automatic syncs
        private volatile bool _isAutoSyncRunning = false;
        private volatile bool _isOrderSyncRunning = false;
        // Keep original Status value while editing so we can revert safely without persisting unwanted changes
        private System.Collections.Generic.Dictionary<int, string> _originalStatus = new System.Collections.Generic.Dictionary<int, string>();

        private System.Collections.Generic.Dictionary<string, string> TryGetWarehouseNamesById(System.Collections.Generic.IEnumerable<string> locationIds)
        {
            var result = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var ids = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (var id in locationIds)
                {
                    var t = (id ?? string.Empty).Trim();
                    if (!string.IsNullOrWhiteSpace(t)) ids.Add(t);
                }
            }
            catch { }

            if (ids.Count == 0) return result;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                static string Bracket(string name) => string.IsNullOrWhiteSpace(name) ? string.Empty : (name.StartsWith("[") ? name : $"[{name}]");

                bool TryResolveSchema(string schema, string table, out string fullTableName, out string idColumn, out string nameColumn)
                {
                    fullTableName = string.Empty;
                    idColumn = string.Empty;
                    nameColumn = string.Empty;

                    try
                    {
                        var columns = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        string colSql;
                        using var colCmd = new SqlCommand();
                        colCmd.Connection = conn;
                        if (string.IsNullOrWhiteSpace(schema))
                        {
                            colSql = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@T";
                            colCmd.CommandText = colSql;
                            colCmd.Parameters.AddWithValue("@T", table);
                        }
                        else
                        {
                            colSql = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA=@S AND TABLE_NAME=@T";
                            colCmd.CommandText = colSql;
                            colCmd.Parameters.AddWithValue("@S", schema);
                            colCmd.Parameters.AddWithValue("@T", table);
                        }

                        using (var rdr = colCmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                try
                                {
                                    var c = rdr[0]?.ToString();
                                    if (!string.IsNullOrWhiteSpace(c)) columns.Add(c);
                                }
                                catch { }
                            }
                        }

                        if (columns.Count == 0) return false;

                        idColumn = columns.Contains("ID") ? "ID"
                            : columns.Contains("WarehouseID") ? "WarehouseID"
                            : columns.Contains("WarehouseId") ? "WarehouseId"
                            : columns.Contains("warehouse_id") ? "warehouse_id"
                            : string.Empty;

                        // Prefer the requested "L Name" column (and common variants), then fall back.
                        nameColumn = columns.Contains("L Name") ? "L Name"
                            : columns.Contains("L_Name") ? "L_Name"
                            : columns.Contains("LName") ? "LName"
                            : columns.Contains("LocationName") ? "LocationName"
                            : columns.Contains("Name") ? "Name"
                            : columns.Contains("WarehouseName") ? "WarehouseName"
                            : string.Empty;

                        if (string.IsNullOrWhiteSpace(idColumn) || string.IsNullOrWhiteSpace(nameColumn))
                            return false;

                        fullTableName = string.IsNullOrWhiteSpace(schema) ? table : $"{schema}.{table}";
                        return true;
                    }
                    catch
                    {
                        return false;
                    }
                }

                string fullTable = string.Empty;
                string idCol = string.Empty;
                string nameCol = string.Empty;

                // Prefer dbo.Warehouses, then Warehouses, then dbo.Warehouse / Warehouse.
                if (!TryResolveSchema("dbo", "Warehouses", out fullTable, out idCol, out nameCol)
                    && !TryResolveSchema(string.Empty, "Warehouses", out fullTable, out idCol, out nameCol)
                    && !TryResolveSchema("dbo", "Warehouse", out fullTable, out idCol, out nameCol)
                    && !TryResolveSchema(string.Empty, "Warehouse", out fullTable, out idCol, out nameCol))
                {
                    return result;
                }

                var idList = new System.Collections.Generic.List<string>(ids);
                var paramNames = new System.Collections.Generic.List<string>(idList.Count);
                using var cmd = new SqlCommand();
                cmd.Connection = conn;
                for (int i = 0; i < idList.Count; i++)
                {
                    string pn = "@p" + i;
                    paramNames.Add(pn);
                    cmd.Parameters.AddWithValue(pn, idList[i]);
                }

                cmd.CommandText = $"SELECT {Bracket(idCol)} AS [ID], {Bracket(nameCol)} AS [Name] FROM {fullTable} WHERE {Bracket(idCol)} IN ({string.Join(",", paramNames)})";

                using var r2 = cmd.ExecuteReader();
                while (r2.Read())
                {
                    try
                    {
                        string id = r2["ID"]?.ToString() ?? string.Empty;
                        string nm = r2["Name"]?.ToString() ?? string.Empty;
                        id = id.Trim();
                        nm = nm.Trim();
                        if (!string.IsNullOrWhiteSpace(id) && !result.ContainsKey(id))
                            result[id] = nm;
                    }
                    catch { }
                }
            }
            catch
            {
                // best-effort
            }

            return result;
        }

        private System.Collections.Generic.HashSet<string> TryGetCurrentWarehouseIds()
        {
            var result = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                static string Bracket(string name) => string.IsNullOrWhiteSpace(name) ? string.Empty : (name.StartsWith("[") ? name : $"[{name}]");

                bool TryResolveSchema(string schema, string table, out string fullTableName, out string idColumn, out string currentFlagColumn, out string shopColumn)
                {
                    fullTableName = string.Empty;
                    idColumn = string.Empty;
                    currentFlagColumn = string.Empty;
                    shopColumn = string.Empty;

                    try
                    {
                        string tname = table;
                        string? tschema = null;
                        if (!string.IsNullOrWhiteSpace(schema))
                            tschema = schema;

                        using var colCmd = new SqlCommand(@"SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND (TABLE_SCHEMA=@s OR @s IS NULL)", conn);
                        colCmd.Parameters.AddWithValue("@t", tname);
                        colCmd.Parameters.AddWithValue("@s", (object?)tschema ?? DBNull.Value);

                        var columns = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        using (var rdr = colCmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                var c = rdr[0]?.ToString() ?? string.Empty;
                                if (!string.IsNullOrWhiteSpace(c))
                                    columns.Add(c);
                            }
                        }

                        if (columns.Count == 0)
                            return false;

                        // Identify ID column
                        if (columns.Contains("ID")) idColumn = "ID";
                        else if (columns.Contains("WarehouseID")) idColumn = "WarehouseID";
                        else if (columns.Contains("WarehouseId")) idColumn = "WarehouseId";
                        else if (columns.Contains("warehouse_id")) idColumn = "warehouse_id";

                        // Identify current flag column
                        if (columns.Contains("Current_Warehouse")) currentFlagColumn = "Current_Warehouse";
                        else if (columns.Contains("Current_Location")) currentFlagColumn = "Current_Location";

                        // Identify optional shop column
                        if (columns.Contains("ShopID")) shopColumn = "ShopID";
                        else if (columns.Contains("ShopId")) shopColumn = "ShopId";

                        if (string.IsNullOrWhiteSpace(idColumn) || string.IsNullOrWhiteSpace(currentFlagColumn))
                            return false;

                        fullTableName = string.IsNullOrWhiteSpace(schema) ? Bracket(table) : $"{Bracket(schema)}.{Bracket(table)}";
                        return true;
                    }
                    catch
                    {
                        return false;
                    }
                }

                string fullTable = string.Empty;
                string idCol = string.Empty;
                string flagCol = string.Empty;
                string shopCol = string.Empty;

                // Prefer dbo.Warehouses, then Warehouses, then dbo.Warehouse / Warehouse.
                if (!TryResolveSchema("dbo", "Warehouses", out fullTable, out idCol, out flagCol, out shopCol)
                    && !TryResolveSchema(string.Empty, "Warehouses", out fullTable, out idCol, out flagCol, out shopCol)
                    && !TryResolveSchema("dbo", "Warehouse", out fullTable, out idCol, out flagCol, out shopCol)
                    && !TryResolveSchema(string.Empty, "Warehouse", out fullTable, out idCol, out flagCol, out shopCol))
                {
                    return result;
                }

                bool hasShop = !string.IsNullOrWhiteSpace(shopCol);
                var shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;

                string sql = hasShop
                    ? $"SELECT {Bracket(idCol)} FROM {fullTable} WHERE ({Bracket(flagCol)} = 1) AND ({Bracket(shopCol)} = @ShopId)"
                    : $"SELECT {Bracket(idCol)} FROM {fullTable} WHERE ({Bracket(flagCol)} = 1)";

                using var cmd = new SqlCommand(sql, conn);
                if (hasShop)
                    cmd.Parameters.AddWithValue("@ShopId", shopId);

                using var rdr2 = cmd.ExecuteReader();
                while (rdr2.Read())
                {
                    try
                    {
                        var id = rdr2[0]?.ToString() ?? string.Empty;
                        id = id.Trim();
                        if (!string.IsNullOrWhiteSpace(id))
                            result.Add(id);
                    }
                    catch { }
                }
            }
            catch
            {
                // best-effort
            }

            return result;
        }

        private bool TryIsProductionWarehouseSelected(System.Collections.Generic.HashSet<string> currentWarehouseIds)
        {
            if (currentWarehouseIds == null || currentWarehouseIds.Count == 0) return false;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                static string Bracket(string name) => string.IsNullOrWhiteSpace(name) ? string.Empty : (name.StartsWith("[") ? name : $"[{name}]");

                bool TryResolveSchema(string schema, string table, out string fullTableName, out string idColumn, out string currentFlagColumn, out string shopColumn, out string prodColumn)
                {
                    fullTableName = string.Empty;
                    idColumn = string.Empty;
                    currentFlagColumn = string.Empty;
                    shopColumn = string.Empty;
                    prodColumn = string.Empty;

                    try
                    {
                        string tname = table;
                        string? tschema = null;
                        if (!string.IsNullOrWhiteSpace(schema))
                            tschema = schema;

                        using var colCmd = new SqlCommand(@"SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND (TABLE_SCHEMA=@s OR @s IS NULL)", conn);
                        colCmd.Parameters.AddWithValue("@t", tname);
                        colCmd.Parameters.AddWithValue("@s", (object?)tschema ?? DBNull.Value);

                        var columns = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        using (var rdr = colCmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                var c = rdr[0]?.ToString() ?? string.Empty;
                                if (!string.IsNullOrWhiteSpace(c))
                                    columns.Add(c);
                            }
                        }

                        if (columns.Count == 0)
                            return false;

                        if (columns.Contains("ID")) idColumn = "ID";
                        else if (columns.Contains("WarehouseID")) idColumn = "WarehouseID";
                        else if (columns.Contains("WarehouseId")) idColumn = "WarehouseId";
                        else if (columns.Contains("warehouse_id")) idColumn = "warehouse_id";

                        if (columns.Contains("Current_Warehouse")) currentFlagColumn = "Current_Warehouse";
                        else if (columns.Contains("Current_Location")) currentFlagColumn = "Current_Location";

                        if (columns.Contains("ShopID")) shopColumn = "ShopID";
                        else if (columns.Contains("ShopId")) shopColumn = "ShopId";

                        // Production-warehouse flag column (best-effort)
                        if (columns.Contains("Is_Production_Warehouse")) prodColumn = "Is_Production_Warehouse";
                        else if (columns.Contains("IsProductionWarehouse")) prodColumn = "IsProductionWarehouse";
                        else if (columns.Contains("Production_Warehouse")) prodColumn = "Production_Warehouse";
                        else if (columns.Contains("IsProduction")) prodColumn = "IsProduction";

                        if (string.IsNullOrWhiteSpace(idColumn) || string.IsNullOrWhiteSpace(currentFlagColumn) || string.IsNullOrWhiteSpace(prodColumn))
                            return false;

                        fullTableName = string.IsNullOrWhiteSpace(schema) ? Bracket(table) : $"{Bracket(schema)}.{Bracket(table)}";
                        return true;
                    }
                    catch
                    {
                        return false;
                    }
                }

                string fullTable = string.Empty;
                string idCol = string.Empty;
                string flagCol = string.Empty;
                string shopCol = string.Empty;
                string prodCol = string.Empty;

                if (!TryResolveSchema("dbo", "Warehouses", out fullTable, out idCol, out flagCol, out shopCol, out prodCol)
                    && !TryResolveSchema(string.Empty, "Warehouses", out fullTable, out idCol, out flagCol, out shopCol, out prodCol)
                    && !TryResolveSchema("dbo", "Warehouse", out fullTable, out idCol, out flagCol, out shopCol, out prodCol)
                    && !TryResolveSchema(string.Empty, "Warehouse", out fullTable, out idCol, out flagCol, out shopCol, out prodCol))
                {
                    return false;
                }

                var idList = new System.Collections.Generic.List<string>(currentWarehouseIds);
                if (idList.Count == 0) return false;

                var shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
                bool hasShop = !string.IsNullOrWhiteSpace(shopCol) && !string.IsNullOrWhiteSpace(shopId);

                // Chunk to keep parameter counts safe
                const int chunkSize = 400;
                for (int offset = 0; offset < idList.Count; offset += chunkSize)
                {
                    var chunk = idList.GetRange(offset, Math.Min(chunkSize, idList.Count - offset));
                    using var cmd = new SqlCommand();
                    cmd.Connection = conn;

                    var paramNames = new System.Collections.Generic.List<string>(chunk.Count);
                    for (int i = 0; i < chunk.Count; i++)
                    {
                        var pn = "@p" + i;
                        paramNames.Add(pn);
                        cmd.Parameters.AddWithValue(pn, chunk[i]);
                    }

                    if (hasShop)
                        cmd.Parameters.AddWithValue("@ShopId", shopId);

                    string inClause = string.Join(",", paramNames);
                    cmd.CommandText = hasShop
                        ? $"SELECT TOP 1 1 FROM {fullTable} WHERE ({Bracket(flagCol)} = 1) AND ({Bracket(prodCol)} = 1) AND ({Bracket(idCol)} IN ({inClause})) AND ({Bracket(shopCol)} = @ShopId)"
                        : $"SELECT TOP 1 1 FROM {fullTable} WHERE ({Bracket(flagCol)} = 1) AND ({Bracket(prodCol)} = 1) AND ({Bracket(idCol)} IN ({inClause}))";

                    var obj = cmd.ExecuteScalar();
                    if (obj != null && obj != DBNull.Value)
                        return true;
                }
            }
            catch
            {
                // best-effort
            }

            return false;
        }

        private System.Collections.Generic.HashSet<string> TryGetOrderIdsWithCustomLines(System.Collections.Generic.IEnumerable<string> orderIds)
        {
            var result = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (orderIds == null) return result;

            var ids = new System.Collections.Generic.List<string>();
            try
            {
                foreach (var id in orderIds)
                {
                    var t = (id ?? string.Empty).Trim();
                    if (!string.IsNullOrWhiteSpace(t)) ids.Add(t);
                }
            }
            catch { }

            if (ids.Count == 0) return result;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                bool hasNote = false;
                bool hasDescription = false;
                try
                {
                    using var colCmd = new SqlCommand(@"SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='dbo' AND TABLE_NAME='OnlineOrderLines'", conn);
                    using var rdr = colCmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        var c = rdr[0]?.ToString() ?? string.Empty;
                        if (c.Equals("Note", StringComparison.OrdinalIgnoreCase)) hasNote = true;
                        if (c.Equals("Description", StringComparison.OrdinalIgnoreCase)) hasDescription = true;
                    }
                }
                catch { }

                const int chunkSize = 400;
                for (int offset = 0; offset < ids.Count; offset += chunkSize)
                {
                    var chunk = ids.GetRange(offset, Math.Min(chunkSize, ids.Count - offset));
                    using var cmd = new SqlCommand();
                    cmd.Connection = conn;

                    var paramNames = new System.Collections.Generic.List<string>(chunk.Count);
                    for (int i = 0; i < chunk.Count; i++)
                    {
                        var pn = "@p" + i;
                        paramNames.Add(pn);
                        cmd.Parameters.AddWithValue(pn, chunk[i]);
                    }

                    // Heuristic: production warehouses should keep cross-location orders when lines indicate
                    // custom work or transfer work. Match custom item codes plus explicit TRANSFER / CI-010 lines.
                    var inClause = string.Join(",", paramNames);
                    var customPredicates = new System.Collections.Generic.List<string>
                    {
                        "(ItemCode LIKE 'CUSTOM%' OR product_display_id LIKE 'CUSTOM%')",
                        "(UPPER(LTRIM(RTRIM(ISNULL(ItemCode, '')))) = 'CI-010' OR UPPER(LTRIM(RTRIM(ISNULL(product_display_id, '')))) = 'CI-010')"
                    };
                    if (hasDescription) customPredicates.Add("(Description LIKE '%custom%' OR Description LIKE '%CUSTOM%')");
                    if (hasDescription) customPredicates.Add("(UPPER(LTRIM(RTRIM(ISNULL(Description, '')))) = 'TRANSFER')");
                    if (hasNote) customPredicates.Add("(Note LIKE '%custom%' OR Note LIKE '%CUSTOM%')");

                    cmd.CommandText = $@"SELECT DISTINCT OrderID
FROM dbo.OnlineOrderLines
WHERE OrderID IN ({inClause})
  AND ({string.Join(" OR ", customPredicates)})";

                    using var r2 = cmd.ExecuteReader();
                    while (r2.Read())
                    {
                        try
                        {
                            var oid = r2[0]?.ToString() ?? string.Empty;
                            oid = oid.Trim();
                            if (!string.IsNullOrWhiteSpace(oid)) result.Add(oid);
                        }
                        catch { }
                    }
                }
            }
            catch
            {
                // best-effort
            }

            return result;
        }

        private void DeleteOnlineOrdersById(System.Collections.Generic.IEnumerable<string> orderIds)
        {
            if (orderIds == null) return;

            var ids = new System.Collections.Generic.List<string>();
            try
            {
                foreach (var id in orderIds)
                {
                    var t = (id ?? string.Empty).Trim();
                    if (!string.IsNullOrWhiteSpace(t)) ids.Add(t);
                }
            }
            catch { }

            if (ids.Count == 0) return;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                // Delete in chunks to avoid SQL parameter limits
                const int chunkSize = 400;
                for (int offset = 0; offset < ids.Count; offset += chunkSize)
                {
                    var chunk = ids.GetRange(offset, Math.Min(chunkSize, ids.Count - offset));
                    var paramNames = new System.Collections.Generic.List<string>(chunk.Count);
                    using var cmdLines = new SqlCommand();
                    cmdLines.Connection = conn;
                    for (int i = 0; i < chunk.Count; i++)
                    {
                        var pn = "@p" + i;
                        paramNames.Add(pn);
                        cmdLines.Parameters.AddWithValue(pn, chunk[i]);
                    }

                    var inClause = string.Join(",", paramNames);
                    cmdLines.CommandText = $"DELETE FROM dbo.OnlineOrderLines WHERE OrderID IN ({inClause}); DELETE FROM dbo.OnlineOrderHeader WHERE OrderID IN ({inClause});";
                    cmdLines.ExecuteNonQuery();
                }
            }
            catch
            {
                // best-effort
            }
        }

        private void ValidateAndPersistLocationNames(System.Data.DataTable? syncedTable, System.Collections.Generic.Dictionary<string, string> warehouseNameById)
        {
            if (syncedTable == null) return;
            if (warehouseNameById == null || warehouseNameById.Count == 0) return;

            try
            {
                if (!syncedTable.Columns.Contains("OrderID") || !syncedTable.Columns.Contains("LocationID"))
                    return;

                using var conn = new SqlConnection(connectionString);
                conn.Open();

                // Ensure Location_Name column exists (best-effort)
                try
                {
                    string ensureCol = @"
IF COL_LENGTH('dbo.OnlineOrderHeader', 'Location_Name') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD Location_Name NVARCHAR(255) NULL
END";
                    using var ensureCmd = new SqlCommand(ensureCol, conn);
                    ensureCmd.ExecuteNonQuery();
                }
                catch { }

                using var cmd = new SqlCommand(@"UPDATE dbo.OnlineOrderHeader
SET Location_Name = @LocationName
WHERE OrderID = @OrderID
  AND (@LocationName IS NOT NULL AND LTRIM(RTRIM(@LocationName)) <> '')
  AND (Location_Name IS NULL OR LTRIM(RTRIM(Location_Name)) <> LTRIM(RTRIM(@LocationName)))", conn);

                var pOrderId = cmd.Parameters.Add("@OrderID", SqlDbType.NVarChar, 100);
                var pLocationName = cmd.Parameters.Add("@LocationName", SqlDbType.NVarChar, 255);

                foreach (System.Data.DataRow rr in syncedTable.Rows)
                {
                    try
                    {
                        string orderId = (rr["OrderID"] as string) ?? string.Empty;
                        string locationId = (rr["LocationID"] as string) ?? string.Empty;

                        orderId = orderId.Trim();
                        locationId = locationId.Trim();
                        if (string.IsNullOrWhiteSpace(orderId) || string.IsNullOrWhiteSpace(locationId)) continue;

                        if (!warehouseNameById.TryGetValue(locationId, out var locationName)) continue;
                        if (string.IsNullOrWhiteSpace(locationName)) continue;

                        pOrderId.Value = orderId;
                        pLocationName.Value = locationName.Trim();
                        cmd.ExecuteNonQuery();
                    }
                    catch { }
                }
            }
            catch
            {
                // best-effort
            }
        }

        public OnlineOrdersForm(bool showNonCurrentLocationsOnly = false)
        {
            _showNonCurrentLocationsOnly = showNonCurrentLocationsOnly;
            Text = _showNonCurrentLocationsOnly ? "DELIVERY TRACKING" : "ONLINE ORDERS";
            // Start maximized and use larger bold fonts for readability
            WindowState = FormWindowState.Maximized;
            StartPosition = FormStartPosition.CenterParent;
            this.Font = new Font(this.Font.FontFamily, 11f, FontStyle.Bold);

            // Top panel for action buttons
            topPanel = new Panel
            {
                Dock = DockStyle.Top,
                // reduce the panel height so the grid has more vertical room
                Height = 40,
                BackColor = SystemColors.Control
            };

            syncButton = new Button
            {
                Text = "Sync",
                // slightly larger so bold caption fits comfortably
                Size = new Size(84, 26),
                BackColor = Color.DarkCyan,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold)
            };
            // docked to the right so it appears alongside other action buttons
            syncButton.Dock = DockStyle.Right;
            syncButton.Click += SyncButton_Click;

            forDeliveryButton = new Button
            {
                Text = "For Delivery",
                Size = new Size(130, 26),
                BackColor = Color.Firebrick,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold),
                Dock = DockStyle.Right,
                Visible = _showNonCurrentLocationsOnly
            };
            forDeliveryButton.Click += ForDeliveryButton_Click;

            receiveOrderButton = new Button
            {
                Text = "Receive Order",
                Size = new Size(140, 26),
                BackColor = Color.Teal,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold),
                Dock = DockStyle.Right,
                Visible = _showNonCurrentLocationsOnly
            };
            receiveOrderButton.Click += ReceiveOrderButton_Click;

            // Status label and progress bar to indicate background sync activity
            statusLabel = new Label
            {
                AutoSize = true,
                Location = new Point(340, 12),
                Text = string.Empty,
                ForeColor = Color.Black,
                Font = new Font(this.Font.FontFamily, 9f, FontStyle.Regular)
            };

            progressBar = new ProgressBar
            {
                Size = new Size(100, 16),
                Location = new Point(340, 14),
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 30,
                Visible = false
            };

            // OrderID filter label + textbox (left side)
            orderIdFilterLabel = new Label
            {
                AutoSize = true,
                Text = "Order ID:",
                Font = new Font(this.Font.FontFamily, 9f, FontStyle.Regular),
                ForeColor = Color.Black,
                TextAlign = ContentAlignment.MiddleLeft,
                Location = new Point(8, 12)
            };

            orderIdFilterTextBox = new TextBox
            {
                Width = 120,
                Anchor = AnchorStyles.Left | AnchorStyles.Top,
                PlaceholderText = "Filter order id...",
                Location = new Point(80, 8),
                Margin = new Padding(4, 8, 4, 6)
            };
            orderIdFilterTextBox.TextChanged += OrderIdFilterTextBox_TextChanged;

            customerFilterLabel = new Label
            {
                AutoSize = true,
                Text = "Name:",
                Font = new Font(this.Font.FontFamily, 9f, FontStyle.Regular),
                ForeColor = Color.Black,
                TextAlign = ContentAlignment.MiddleLeft,
                Location = new Point(220, 12)
            };

            customerFilterTextBox = new TextBox
            {
                Width = 180,
                Anchor = AnchorStyles.Left | AnchorStyles.Top,
                PlaceholderText = "Filter customer name...",
                Location = new Point(270, 8),
                Margin = new Padding(4, 8, 4, 6)
            };
            customerFilterTextBox.TextChanged += CustomerFilterTextBox_TextChanged;

            // Status filter combo (All + distinct statuses)
            statusFilterCombo = new ComboBox
            {
                DropDownStyle = ComboBoxStyle.DropDownList,
                Width = 160,
                // Dock to the right so it groups with the action buttons
                Dock = DockStyle.Right,
                Visible = true,
                Margin = new Padding(6, 12, 6, 6)
            };
            statusFilterCombo.SelectedIndexChanged += StatusFilterCombo_SelectedIndexChanged;

            // Right-side button to open lines for the selected order (same as double-click)
            linesButton = new Button
            {
                Text = "Lines",
                Size = new Size(75, 26),
                BackColor = Color.DarkBlue,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold)
            };
            // dock to the right so it groups with other action buttons
            linesButton.Dock = DockStyle.Right;
            linesButton.Click += LinesButton_Click;

            // Button to send an update to the customer for the selected order
            sendUpdateButton = new Button
            {
                Text = "Advise",
                Size = new Size(90, 26),
                BackColor = Color.SeaGreen,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold)
            };
            // dock to the right so it groups with other action buttons
            sendUpdateButton.Dock = DockStyle.Right;
            sendUpdateButton.Click += SendUpdateToCustomer_Click;

            // // Button to initiate payment flow (placeholder)
            // Button to initiate payment flow
            payButton = new Button
            {
                Text = "PAY",
                Size = new Size(80, 26),
                BackColor = Color.Orange,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold)
            };
            payButton.Dock = DockStyle.Right;
            payButton.Click += PayButton_Click;

            // Print button for printing selected order's items to POS58 printer
            printButton = new Button
            {
                Text = "Print",
                Size = new Size(70, 26),
                BackColor = Color.DarkSlateGray,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold)
            };
            printButton.Dock = DockStyle.Right;
            printButton.Click += PrintButton_Click;

            toShipButton = new Button
            {
                Text = "To Ship",
                Size = new Size(90, 26),
                BackColor = Color.SteelBlue,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold),
                Visible = false
            };
            toShipButton.Dock = DockStyle.Right;
            toShipButton.Click += ToShipButton_Click;

            productionDoneButton = new Button
            {
                Text = "Production Done",
                Size = new Size(150, 26),
                BackColor = Color.MediumPurple,
                ForeColor = Color.White,
                Font = new Font(this.Font.FontFamily, 10f, FontStyle.Bold)
            };
            productionDoneButton.Dock = DockStyle.Right;
            productionDoneButton.Click += ProductionDoneButton_Click;

            // Add status label and progress bar first (left side), then add status filter and buttons docked to the right
            topPanel.Controls.Add(orderIdFilterLabel);
            topPanel.Controls.Add(orderIdFilterTextBox);
            topPanel.Controls.Add(customerFilterLabel);
            topPanel.Controls.Add(customerFilterTextBox);
            topPanel.Controls.Add(statusLabel);
            topPanel.Controls.Add(statusFilterCombo);
            topPanel.Controls.Add(progressBar);
            if (!_showNonCurrentLocationsOnly)
            {
                // Add action buttons in the order where the first added will appear at the far right
                topPanel.Controls.Add(linesButton);       // far-right
                topPanel.Controls.Add(payButton);         // beside Lines
                topPanel.Controls.Add(sendUpdateButton); // middle-right
                topPanel.Controls.Add(toShipButton);     // non-production shortcut
                topPanel.Controls.Add(productionDoneButton); // production status shortcut
                topPanel.Controls.Add(printButton);     // print button
                topPanel.Controls.Add(syncButton);       // left-most of the right group
            }
            else
            {
                topPanel.Controls.Add(printButton);
                topPanel.Controls.Add(receiveOrderButton);
                topPanel.Controls.Add(forDeliveryButton);
            }

            UpdateProductionDoneButtonVisibility();
            UpdateToShipButtonVisibility();

            dgv = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = true
            };
            // Handle data errors to avoid the default dialog (we also merge DB values into the combo list below)
            dgv.DataError += Dgv_DataError;
            dgv.Font = new Font(dgv.Font.FontFamily, 10f, FontStyle.Bold);
            // Improve header readability: larger bold header font and taller header row
            try
            {
                dgv.EnableHeadersVisualStyles = false;
                // Larger header font for improved readability
                dgv.ColumnHeadersDefaultCellStyle.Font = new Font(this.Font.FontFamily, 13f, FontStyle.Bold);
                dgv.ColumnHeadersDefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleCenter;
                dgv.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.EnableResizing;
                // Increase header height substantially for multiline/truncated values
                dgv.ColumnHeadersHeight = Math.Max(64, dgv.ColumnHeadersHeight);
            }
            catch { }
            dgv.CellDoubleClick += Dgv_CellDoubleClick;
            dgv.CellMouseDown += Dgv_CellMouseDown;
            dgv.CellContentClick += Dgv_CellContentClick;
            dgv.CellEndEdit += Dgv_CellEndEdit;
            dgv.CellBeginEdit += Dgv_CellBeginEdit;
            dgv.EditingControlShowing += Dgv_EditingControlShowing;
            dgv.CurrentCellDirtyStateChanged += Dgv_CurrentCellDirtyStateChanged;
            dgv.SelectionChanged += Dgv_SelectionChanged;
            dgv.RowPrePaint += Dgv_RowPrePaint;

            // Build context menu for status updates
            statusMenu = new ContextMenuStrip();
            var submittedItem = new ToolStripMenuItem("Submitted");
            var newItem = new ToolStripMenuItem("new");
            var confirmedItem = new ToolStripMenuItem("Confirmed");
            var pendingTransferItem = new ToolStripMenuItem("Pending Transfer");
            var inTransitItem = new ToolStripMenuItem("In-Transit");
            var receivedItem = new ToolStripMenuItem("Received");
            var productionDoneItem = new ToolStripMenuItem("Production Done");
            var toShipItem = new ToolStripMenuItem("To Ship");
            var shippedItem = new ToolStripMenuItem("Shipped");
            var printedItem = new ToolStripMenuItem("Printed");

            // Async click handlers (async void event handlers are acceptable for UI events)
            submittedItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                // Prevent changing if current status is 'new'
                try
                {
                    // If the persisted status is 'new', do not allow any changes and show a clear instruction
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be ship please ask Sales team to confirm order before shipping out Thank you", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                string orderId = GetOrderIdForRow(idx);
                if (!string.IsNullOrWhiteSpace(orderId)) await ChangeOrderStatusAsync(idx, orderId, "Submitted");
            };

            newItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                try
                {
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be ship please ask Sales team to confirm order before shipping out Thank you", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                string orderId = GetOrderIdForRow(idx);
                if (!string.IsNullOrWhiteSpace(orderId)) await ChangeOrderStatusAsync(idx, orderId, "new");
            };

            confirmedItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                try
                {
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be ship please ask Sales team to confirm order before shipping out Thank you", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                string orderId = GetOrderIdForRow(idx);
                if (!string.IsNullOrWhiteSpace(orderId)) await ChangeOrderStatusAsync(idx, orderId, "Confirmed");
            };
            pendingTransferItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                try
                {
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be ship please ask Sales team to confirm order before shipping out Thank you", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                await MarkRowAsPendingTransferAsync(idx).ConfigureAwait(false);
            };
            inTransitItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                try
                {
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be ship please ask Sales team to confirm order before shipping out Thank you", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                string orderId = GetOrderIdForRow(idx);
                if (!string.IsNullOrWhiteSpace(orderId)) await ChangeOrderStatusAsync(idx, orderId, "In-Transit");
            };
            receivedItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                try
                {
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be ship please ask Sales team to confirm order before shipping out Thank you", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                string orderId = GetOrderIdForRow(idx);
                if (!string.IsNullOrWhiteSpace(orderId)) await ChangeOrderStatusAsync(idx, orderId, "Received");
            };
            productionDoneItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!IsPrintedStatusForRow(idx))
                {
                    try { MessageBox.Show("Update not allowed status is not \"printed\"", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                try
                {
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be marked production done. Please ask Sales team to confirm order first.", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                string orderId = GetOrderIdForRow(idx);
                if (!string.IsNullOrWhiteSpace(orderId)) await ChangeOrderStatusAsync(idx, orderId, "Production Done");
            };
            toShipItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                await MarkRowAsToShipAsync(idx).ConfigureAwait(false);
            };
            shippedItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                try
                {
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be ship please ask Sales team to confirm order before shipping out Thank you", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                string orderId = GetOrderIdForRow(idx);
                if (!string.IsNullOrWhiteSpace(orderId)) await ChangeOrderStatusAsync(idx, orderId, "Shipped");
            };

            printedItem.Click += async (s, e) =>
            {
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                if (!CanManuallyChangeStatusForRow(idx, out var locationMessage))
                {
                    try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }
                try
                {
                    if (dgv.Columns.Contains("Status") && string.Equals(dgv.CurrentRow.Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("New orders cannot be marked printed. Please ask Sales team to confirm order first.", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                string orderId = GetOrderIdForRow(idx);
                if (!string.IsNullOrWhiteSpace(orderId))
                {
                    await ChangeOrderStatusAsync(idx, orderId, "Printed").ConfigureAwait(false);
                    // Notify customer that their order has been printed
                    _ = System.Threading.Tasks.Task.Run(async () =>
                    {
                        try { await NotifyCustomerOrderPrintedAsync(orderId, idx).ConfigureAwait(false); } catch { }
                    });
                }
            };

            statusMenu.Items.AddRange(new ToolStripItem[] { submittedItem, newItem, confirmedItem, pendingTransferItem, inTransitItem, receivedItem, productionDoneItem, toShipItem, shippedItem, printedItem });
            // Ensure the top panel is added before the grid so it remains at the top of the z-order
            Controls.Add(topPanel);

            // Create a content panel which will host the grid and provide top padding
            var contentPanel = new Panel
            {
                Dock = DockStyle.Fill,
                // ensure the content panel's top padding matches the topPanel height so
                // the DataGridView does not overlap the topPanel when the form is maximized
                Padding = new Padding(0, topPanel.Height + 4, 0, 0), // push content down under the topPanel
                BackColor = SystemColors.Control
            };

            // Place the DataGridView inside the content panel so it respects the padding
            dgv.Dock = DockStyle.Fill;
            contentPanel.Controls.Add(dgv);
            Controls.Add(contentPanel);
            Load += OnlineOrdersForm_Load;
            // Ensure we tidy up the auto-sync timer when the form closes
            this.FormClosing += OnlineOrdersForm_FormClosing;
        }

        // Auto-sync timer tick handler
        private async void AutoSyncTimer_Tick(object? sender, EventArgs e)
        {
            // Prevent overlapping runs
            if (_isAutoSyncRunning) return;
            _isAutoSyncRunning = true;
            try
            {
                await DoSyncAndRefreshAsync().ConfigureAwait(false);
            }
            catch { }
            finally
            {
                _isAutoSyncRunning = false;
            }
        }

        // Ensure timer is stopped and disposed when the form closes
        private void OnlineOrdersForm_FormClosing(object? sender, FormClosingEventArgs e)
        {
            try
            {
                if (autoSyncTimer != null)
                {
                    try { autoSyncTimer.Stop(); } catch { }
                    try { autoSyncTimer.Tick -= AutoSyncTimer_Tick; } catch { }
                    try { autoSyncTimer.Dispose(); } catch { }
                    autoSyncTimer = null;
                }
            }
            catch { }
        }

        // Centers the customerFilterTextBox horizontally within the topPanel
        private void CenterCustomerFilter()
        {
            try
            {
                if (topPanel == null || customerFilterTextBox == null || customerFilterLabel == null) return;
                int panelWidth = topPanel.ClientSize.Width;
                int txtWidth = customerFilterTextBox.Width;
                int lblWidth = customerFilterLabel.PreferredWidth;
                int spacing = 6; // pixels between label and textbox

                int totalWidth = lblWidth + spacing + txtWidth;
                int startX = Math.Max(6, (panelWidth - totalWidth) / 2);
                int y = Math.Max(4, (topPanel.ClientSize.Height - customerFilterTextBox.Height) / 2);

                customerFilterLabel.Location = new Point(startX, Math.Max(0, y + (customerFilterTextBox.Height - customerFilterLabel.Height) / 2));
                customerFilterTextBox.Location = new Point(startX + lblWidth + spacing, y);
            }
            catch { }
        }

        private async void Dgv_CellDoubleClick(object? sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0) return;
            if (!EnsureOrderSyncCompleted("Online Orders")) return;
            await OpenOrderLinesForRowAsync(e.RowIndex).ConfigureAwait(false);
        }

        // Handle end of inline edit; only Status column should be editable
        private async void Dgv_CellEndEdit(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted("Status Update")) return;
                if (e.RowIndex < 0 || e.ColumnIndex < 0) return;
                var col = dgv.Columns[e.ColumnIndex];
                if (col == null) return;
                // Only react to edits on the Status column.
                if (string.Equals(col.Name, "Status", StringComparison.OrdinalIgnoreCase))
                {
                    // When the user edits the Status cell, only allow actionable transitions.
                    string newStatus = dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value?.ToString() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(newStatus)) return;
                    if (!CanManuallyChangeStatusForRow(e.RowIndex, out var locationMessage))
                    {
                        try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                        try
                        {
                            string orig = string.Empty;
                            lock (_originalStatus)
                            {
                                if (_originalStatus.TryGetValue(e.RowIndex, out var v)) orig = v;
                                if (_originalStatus.ContainsKey(e.RowIndex)) _originalStatus.Remove(e.RowIndex);
                            }
                            if (!string.IsNullOrEmpty(orig)) dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = orig;
                        }
                        catch { }
                        return;
                    }
                    // If the persisted/original status is 'new', disallow any change
                    string persistedStatus = string.Empty;
                    try
                    {
                        // Prefer the value from the bound DataTable if available
                        var dt = dgv.DataSource as DataTable;
                        if (dt != null && dt.Rows.Count > e.RowIndex && dt.Columns.Contains("Status"))
                            persistedStatus = dt.Rows[e.RowIndex]["Status"]?.ToString() ?? string.Empty;
                    }
                    catch { }

                    if (string.Equals(persistedStatus, "new", StringComparison.OrdinalIgnoreCase))
                    {
                        try { MessageBox.Show("Cannot change status for orders with status 'new' please ask online sales team to confirmed the order first", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                        // revert to original
                        try
                        {
                            string orig = string.Empty;
                            lock (_originalStatus)
                            {
                                if (_originalStatus.TryGetValue(e.RowIndex, out var v)) orig = v;
                                if (_originalStatus.ContainsKey(e.RowIndex)) _originalStatus.Remove(e.RowIndex);
                            }
                            if (!string.IsNullOrEmpty(orig)) dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = orig;
                            else if (!string.IsNullOrWhiteSpace(persistedStatus)) dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = persistedStatus;
                        }
                        catch { }
                        return;
                    }

                    // Only accept transitions to the actionable states from the UI.
                    // In Online Orders, manual change is limited to Shipped only.
                    bool isAllowedManualStatus = _showNonCurrentLocationsOnly
                        ? string.Equals(newStatus, "To Ship", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(newStatus, "Shipped", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(newStatus, "Pending Transfer", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(newStatus, "In-Transit", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(newStatus, "Received", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(newStatus, "Production Done", StringComparison.OrdinalIgnoreCase)
                        : string.Equals(newStatus, "Shipped", StringComparison.OrdinalIgnoreCase);

                    if (!isAllowedManualStatus)
                    {
                        // Inform user and revert to the persisted value to avoid invalid user edits
                        try
                        {
                            MessageBox.Show(
                                _showNonCurrentLocationsOnly
                                    ? "You can only change status from this grid to 'To Ship', 'Shipped', 'Pending Transfer', 'In-Transit', 'Received' or 'Production Done'. Use the context menu or sync for other status changes."
                                    : "In Online Orders, manual status change is only allowed to 'Shipped'.",
                                "Invalid Status",
                                MessageBoxButtons.OK,
                                MessageBoxIcon.Warning);
                        }
                        catch { }
                        try
                        {
                            string orig = string.Empty;
                            lock (_originalStatus)
                            {
                                if (_originalStatus.TryGetValue(e.RowIndex, out var v)) orig = v;
                                // remove stored original after use
                                if (_originalStatus.ContainsKey(e.RowIndex)) _originalStatus.Remove(e.RowIndex);
                            }
                            if (!string.IsNullOrEmpty(orig))
                            {
                                dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = orig;
                            }
                            else
                            {
                                var dt = dgv.DataSource as DataTable;
                                if (dt != null && dt.Rows.Count > e.RowIndex && dt.Columns.Contains("Status"))
                                {
                                    dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = dt.Rows[e.RowIndex]["Status"]?.ToString() ?? string.Empty;
                                }
                            }
                        }
                        catch { }
                        return;
                    }

                    if (string.Equals(newStatus, "Production Done", StringComparison.OrdinalIgnoreCase)
                        && !IsPrintedStatusForRow(e.RowIndex))
                    {
                        try { MessageBox.Show("Update not allowed status is not \"printed\"", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                        try
                        {
                            string orig = string.Empty;
                            lock (_originalStatus)
                            {
                                if (_originalStatus.TryGetValue(e.RowIndex, out var v)) orig = v;
                                if (_originalStatus.ContainsKey(e.RowIndex)) _originalStatus.Remove(e.RowIndex);
                            }
                            if (!string.IsNullOrEmpty(orig))
                            {
                                dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = orig;
                            }
                            else
                            {
                                var dt = dgv.DataSource as DataTable;
                                if (dt != null && dt.Rows.Count > e.RowIndex && dt.Columns.Contains("Status"))
                                {
                                    dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = dt.Rows[e.RowIndex]["Status"]?.ToString() ?? string.Empty;
                                }
                            }
                        }
                        catch { }
                        return;
                    }

                    string orderId = GetOrderIdForRow(e.RowIndex);
                    if (string.IsNullOrWhiteSpace(orderId)) return;
                    await ChangeOrderStatusAsync(e.RowIndex, orderId, newStatus).ConfigureAwait(false);

                    // If status changed to 'To Ship', ask whether to notify the customer
                    try
                    {
                        if (string.Equals(newStatus, "To Ship", StringComparison.OrdinalIgnoreCase))
                        {
                            var confirm = MessageBox.Show("Order complete? Do you want to update the customer?", "Confirm", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                            if (confirm == DialogResult.Yes)
                            {
                                _ = SendUpdateToCustomerForRowAsync(e.RowIndex);
                            }
                        }
                        else if (string.Equals(newStatus, "Pending Transfer", StringComparison.OrdinalIgnoreCase))
                        {
                            _ = SendUpdateToCustomerForRowAsync(e.RowIndex, GlobalSettings.ScheduledTransferReadyMessage);
                        }
                    }
                    catch { }

                    return;
                }
            }
            catch { }
        }

        // Capture original status when editing begins so we can revert if the user picks an invalid option
        private void Dgv_CellBeginEdit(object? sender, DataGridViewCellCancelEventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted("Status Update"))
                {
                    e.Cancel = true;
                    return;
                }

                if (e.RowIndex < 0 || e.ColumnIndex < 0) return;
                var col = dgv.Columns[e.ColumnIndex];
                if (col == null) return;
                if (string.Equals(col.Name, "Status", StringComparison.OrdinalIgnoreCase))
                {
                    ShowManualStatusChangeDisabledMessage();
                    e.Cancel = true;
                    return;
                }
            }
            catch { }
        }

        // Ensure ComboBox editing control doesn't allow typing for the Status column.
        // Keep the full set of statuses visible; enforce allowed transitions in CellEndEdit.
        private void Dgv_EditingControlShowing(object? sender, DataGridViewEditingControlShowingEventArgs e)
        {
            try
            {
                var colName = dgv.CurrentCell?.OwningColumn?.Name;
                if (string.Equals(colName, "Status", StringComparison.OrdinalIgnoreCase))
                {
                    if (e.Control is ComboBox cb)
                    {
                        cb.DropDownStyle = ComboBoxStyle.DropDownList; // prevent typing
                                                                       // do not modify cb.DataSource here so existing values remain selectable
                    }
                }
            }
            catch { }
        }

        // Right-click support: select row and show context menu
        private void Dgv_CellMouseDown(object? sender, DataGridViewCellMouseEventArgs e)
        {
            if (e.Button == MouseButtons.Right && e.RowIndex >= 0)
            {
                if (!EnsureOrderSyncCompleted("Status Update")) return;
                try
                {
                    dgv.ClearSelection();
                    dgv.Rows[e.RowIndex].Selected = true;
                    dgv.CurrentCell = dgv.Rows[e.RowIndex].Cells[0];
                    ShowManualStatusChangeDisabledMessage();
                }
                catch { }
            }
        }

        private void ShowManualStatusChangeDisabledMessage()
        {
            try
            {
                MessageBox.Show("Manual status changes from Online Orders are disabled. Use the dedicated workflow buttons instead.", "Status Update", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch { }
        }

        // Suppress the default DataGridView error dialog for combo binding issues and log them instead
        private void Dgv_DataError(object? sender, DataGridViewDataErrorEventArgs e)
        {
            try
            {
                System.Diagnostics.Trace.TraceWarning($"DataGridView data error at row {e.RowIndex}, column {e.ColumnIndex}: {e.Exception?.Message}");
                // Mark the error as handled so the default dialog is not shown
                e.ThrowException = false;
            }
            catch { }
        }

        // Returns the OrderID for a given row index (tries DataGridView binding first, falls back to DataTable)
        private string GetOrderIdForRow(int rowIndex)
        {
            try
            {
                if (dgv.Columns.Contains("OrderID"))
                {
                    return dgv.Rows[rowIndex].Cells["OrderID"].Value?.ToString() ?? string.Empty;
                }
                else if (dgv.Rows[rowIndex].Cells.Count > 0)
                {
                    return dgv.Rows[rowIndex].Cells[0].Value?.ToString() ?? string.Empty;
                }
            }
            catch { }

            try
            {
                var dt = dgv.DataSource as DataTable;
                if (dt != null && dt.Rows.Count > rowIndex && dt.Columns.Contains("OrderID"))
                    return dt.Rows[rowIndex]["OrderID"] as string ?? string.Empty;
            }
            catch { }
            return string.Empty;
        }

        private bool IsRowInCurrentLocation(int rowIndex, out string failureMessage)
        {
            failureMessage = string.Empty;

            try
            {
                var currentWarehouseIds = TryGetCurrentWarehouseIds();
                if (currentWarehouseIds == null || currentWarehouseIds.Count == 0)
                {
                    failureMessage = "No current location is configured. Open Warehouse Setup and select the current location first.";
                    return false;
                }

                string orderId = GetOrderIdForRow(rowIndex);
                if (string.IsNullOrWhiteSpace(orderId))
                {
                    failureMessage = "Unable to determine the selected order.";
                    return false;
                }

                string orderLocationId = string.Empty;
                string orderLocationName = string.Empty;

                try
                {
                    if (dgv.Columns.Contains("Location_Name"))
                        orderLocationName = dgv.Rows[rowIndex].Cells["Location_Name"].Value?.ToString() ?? string.Empty;
                }
                catch { }

                try
                {
                    var dt = dgv.DataSource as DataTable;
                    if (dt != null && dt.Rows.Count > rowIndex)
                    {
                        if (dt.Columns.Contains("LocationID"))
                            orderLocationId = dt.Rows[rowIndex]["LocationID"]?.ToString() ?? string.Empty;
                        if (string.IsNullOrWhiteSpace(orderLocationName) && dt.Columns.Contains("Location_Name"))
                            orderLocationName = dt.Rows[rowIndex]["Location_Name"]?.ToString() ?? string.Empty;
                    }
                }
                catch { }

                if (string.IsNullOrWhiteSpace(orderLocationId) || string.IsNullOrWhiteSpace(orderLocationName))
                {
                    try
                    {
                        using var conn = new SqlConnection(connectionString);
                        conn.Open();
                        using var cmd = new SqlCommand("SELECT TOP 1 LocationID, Location_Name FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", conn);
                        cmd.Parameters.AddWithValue("@OrderID", orderId);
                        using var rdr = cmd.ExecuteReader();
                        if (rdr.Read())
                        {
                            if (string.IsNullOrWhiteSpace(orderLocationId))
                                orderLocationId = rdr["LocationID"]?.ToString() ?? string.Empty;
                            if (string.IsNullOrWhiteSpace(orderLocationName))
                                orderLocationName = rdr["Location_Name"]?.ToString() ?? string.Empty;
                        }
                    }
                    catch { }
                }

                orderLocationId = (orderLocationId ?? string.Empty).Trim();
                orderLocationName = (orderLocationName ?? string.Empty).Trim();

                if (!string.IsNullOrWhiteSpace(orderLocationId) && currentWarehouseIds.Contains(orderLocationId))
                    return true;

                var currentWarehouseNamesById = TryGetWarehouseNamesById(currentWarehouseIds);
                var currentLocationNames = new System.Collections.Generic.HashSet<string>(System.StringComparer.OrdinalIgnoreCase);
                foreach (var pair in currentWarehouseNamesById)
                {
                    var name = (pair.Value ?? string.Empty).Trim();
                    if (!string.IsNullOrWhiteSpace(name))
                        currentLocationNames.Add(name);
                }

                if (!string.IsNullOrWhiteSpace(orderLocationName) && currentLocationNames.Contains(orderLocationName))
                    return true;

                string currentLocationsDisplay = currentLocationNames.Count > 0
                    ? string.Join(", ", currentLocationNames)
                    : string.Join(", ", currentWarehouseIds);

                failureMessage = !string.IsNullOrWhiteSpace(orderLocationName)
                    ? $"You can only change status for orders assigned to your current location. This order belongs to '{orderLocationName}'. Current location: {currentLocationsDisplay}."
                    : "You can only change status for orders assigned to your current location.";
                return false;
            }
            catch
            {
                failureMessage = "You can only change status for orders assigned to your current location.";
                return false;
            }
        }

        private bool CanManuallyChangeStatusForRow(int rowIndex, out string failureMessage)
        {
            if (!IsRowInCurrentLocation(rowIndex, out failureMessage))
                return false;

            try
            {
                if (!_showNonCurrentLocationsOnly)
                {
                    var currentStatus = GetStatusForRow(rowIndex);
                    if (string.Equals(currentStatus, "Shipped", StringComparison.OrdinalIgnoreCase))
                    {
                        failureMessage = "order is already shipped no futher changes can be done";
                        return false;
                    }
                }
            }
            catch { }

            return true;
        }

        private bool IsOrderSyncInProgress()
        {
            return _isOrderSyncRunning || _isAutoSyncRunning;
        }

        private bool EnsureOrderSyncCompleted(string actionName)
        {
            if (!IsOrderSyncInProgress())
                return true;

            try { MessageBox.Show("Orders are still syncing. Please wait until sync is complete.", actionName, MessageBoxButtons.OK, MessageBoxIcon.Information); } catch { }
            return false;
        }

        private void SetActionControlsEnabled(bool enabled)
        {
            try { if (syncButton != null) syncButton.Enabled = enabled; } catch { }
            try { if (forDeliveryButton != null) forDeliveryButton.Enabled = enabled; } catch { }
            try { if (receiveOrderButton != null) receiveOrderButton.Enabled = enabled; } catch { }
            try { if (linesButton != null) linesButton.Enabled = enabled; } catch { }
            try { if (sendUpdateButton != null) sendUpdateButton.Enabled = enabled; } catch { }
            try { if (payButton != null) payButton.Enabled = enabled; } catch { }
            try { if (printButton != null) printButton.Enabled = enabled; } catch { }
            try { if (toShipButton != null) toShipButton.Enabled = enabled; } catch { }
            try { if (productionDoneButton != null) productionDoneButton.Enabled = enabled; } catch { }
            try { if (statusFilterCombo != null) statusFilterCombo.Enabled = enabled; } catch { }
            try { if (dgv != null) dgv.Enabled = enabled; } catch { }
        }

        private void UpdateOrderStatusLocal(int rowIndex, string orderId, string newStatus)
        {
            if (string.IsNullOrWhiteSpace(orderId)) return;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using (var ensureCmd = new SqlCommand(@"
IF COL_LENGTH('dbo.OnlineOrderHeader', 'Date of Completion') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD [Date of Completion] DATE NULL
END", conn))
                {
                    ensureCmd.ExecuteNonQuery();
                }

                bool shouldStampCompletionDate = string.Equals(newStatus, "To Ship", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(newStatus, "Production Done", StringComparison.OrdinalIgnoreCase);
                DateTime? completionDate = shouldStampCompletionDate ? DateTime.Today : null;

                using var cmd = new SqlCommand(@"
UPDATE dbo.OnlineOrderHeader
SET Status = @Status,
    [Date of Completion] = CASE
        WHEN @SetCompletionDate = 1 THEN @CompletionDate
        ELSE [Date of Completion]
    END
WHERE OrderID = @OrderID", conn);
                cmd.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(newStatus) ? (object)DBNull.Value : (object)newStatus);
                cmd.Parameters.AddWithValue("@SetCompletionDate", shouldStampCompletionDate);
                cmd.Parameters.AddWithValue("@CompletionDate", completionDate.HasValue ? (object)completionDate.Value : DBNull.Value);
                cmd.Parameters.AddWithValue("@OrderID", orderId);
                cmd.ExecuteNonQuery();
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Failed to update local status: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }

            try
            {
                if (this.IsHandleCreated)
                {
                    this.Invoke(new Action(() =>
                    {
                        try
                        {
                            if (dgv.Columns.Contains("Status")) dgv.Rows[rowIndex].Cells["Status"].Value = newStatus;
                            if ((string.Equals(newStatus, "To Ship", StringComparison.OrdinalIgnoreCase)
                                || string.Equals(newStatus, "Production Done", StringComparison.OrdinalIgnoreCase))
                                && dgv.Columns.Contains("Date of Completion"))
                            {
                                dgv.Rows[rowIndex].Cells["Date of Completion"].Value = DateTime.Today;
                            }
                            UpdateProductionDoneButtonVisibility();
                        }
                        catch { }
                    }));
                }
            }
            catch { }
        }

        // Change status locally and attempt to update upstream. Runs DB update synchronously but calls upstream API in background.
        private Task ChangeOrderStatusAsync(int rowIndex, string orderId, string newStatus)
        {
            if (string.IsNullOrWhiteSpace(orderId)) return Task.CompletedTask;
            UpdateOrderStatusLocal(rowIndex, orderId, newStatus);

            // Call upstream API but don't block UI — capture exceptions to trace
            _ = Task.Run(async () =>
            {
                try
                {
                    // Map the friendly UI status to the API-expected token (many APIs require specific slugs)
                    string apiStatus = MapStatusForApi(newStatus);
                    try
                    {
                        await IntegrationEvents.UpdateStatusPayload(orderId, apiStatus).ConfigureAwait(false);
                    }
                    catch (HttpRequestException) when (!string.Equals(apiStatus, newStatus, StringComparison.OrdinalIgnoreCase))
                    {
                        // Retry with a safe normalized form (lowercase, underscores) if mapping didn't work
                        var normalized = newStatus.Trim().ToLowerInvariant().Replace(' ', '_');
                        await IntegrationEvents.UpdateStatusPayload(orderId, normalized).ConfigureAwait(false);
                    }
                }
                catch (Exception ex)
                {
                    try { System.Diagnostics.Trace.TraceError($"Failed to update upstream status for {orderId}: {ex}"); } catch { }
                    // Surface a clearer error to the user including the response if available
                    try { this.Invoke(new Action(() => MessageBox.Show($"Failed to update upstream status: {ex.Message}", "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning))); } catch { }
                }
            });

            return Task.CompletedTask;
        }

        // Convert user-visible status strings into API-friendly tokens.
        // If the API expects different tokens, extend this map accordingly.
        private static string MapStatusForApi(string displayStatus)
        {
            if (string.IsNullOrWhiteSpace(displayStatus)) return displayStatus ?? string.Empty;
            var map = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "Submitted", "submitted" },
                { "new", "new" },
                { "Confirmed", "submitted" },
                { "Pending Transfer", "9" },
                { "In-Transit", "12" },
                { "Received", "3" },
                { "Production Done", "production_done" },
                { "To Ship", "8" },
                { "Shipped", "2" },
                { "Printed", "13" }
            };

            if (map.TryGetValue(displayStatus.Trim(), out var api)) return api;
            // Fallback: normalize (lowercase, replace spaces with underscores)
            return displayStatus.Trim().ToLowerInvariant().Replace(' ', '_');
        }

        private async void ProductionDoneButton_Click(object? sender, EventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted(productionDoneButton?.Text ?? "Production Done")) return;
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                string orderId = GetOrderIdForRow(idx);
                if (string.IsNullOrWhiteSpace(orderId)) return;

                string currentStatus = GetStatusForRow(idx);
                bool markAsShipped = string.Equals(currentStatus, "To Ship", StringComparison.OrdinalIgnoreCase);

                if (markAsShipped)
                {
                    if (!CanManuallyChangeStatusForRow(idx, out var shippedMessage))
                    {
                        try { MessageBox.Show(shippedMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                        return;
                    }

                    try
                    {
                        var confirmShip = MessageBox.Show("Mark this order as shipped?", "Shipped", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                        if (confirmShip != DialogResult.Yes)
                            return;
                    }
                    catch { }

                    await ChangeOrderStatusAsync(idx, orderId, "Shipped").ConfigureAwait(false);
                    return;
                }

                if (string.Equals(currentStatus, "In-Transit", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(currentStatus, "Shipped", StringComparison.OrdinalIgnoreCase))
                {
                    try { MessageBox.Show("Update not allowed for In-Transit or Shipped orders.", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }

                if (!IsPrintedStatusForRow(idx))
                {
                    try { MessageBox.Show("Update not allowed status is not \"printed\"", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }

                try
                {
                    var confirm = MessageBox.Show("Is the order done?", "Production Done", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                    if (confirm != DialogResult.Yes)
                        return;
                }
                catch { }

                bool isForDelivery = IsForDeliveryForRow(idx);

                if (IsRowInCurrentLocation(idx, out var locationMessage))
                {
                    var processed = isForDelivery
                        ? await MarkRowAsPendingTransferAsync(idx, sendCustomerUpdate: true).ConfigureAwait(false)
                        : await MarkRowAsToShipAsync(idx, promptToUpdateCustomer: false, sendCustomerUpdate: true).ConfigureAwait(false);
                    if (processed)
                    {
                        try { MessageBox.Show("Message sent to the customer. Status has been updated.", "Production Done", MessageBoxButtons.OK, MessageBoxIcon.Information); } catch { }
                    }
                    return;
                }

                if (string.IsNullOrWhiteSpace(locationMessage) || locationMessage.StartsWith("No current location is configured", StringComparison.OrdinalIgnoreCase))
                {
                    try { MessageBox.Show(string.IsNullOrWhiteSpace(locationMessage) ? "No current location is configured." : locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                    return;
                }

                var pendingTransferProcessed = await MarkRowAsPendingTransferAsync(idx, sendCustomerUpdate: true).ConfigureAwait(false);
                if (pendingTransferProcessed)
                {
                    try { MessageBox.Show("Message sent to the customer. Status has been updated.", "Production Done", MessageBoxButtons.OK, MessageBoxIcon.Information); } catch { }
                }
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Failed to process Production Done: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private sealed class OnlineSetAssemblyLine
        {
            public string LineId { get; init; } = string.Empty;
            public string ItemCode { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public decimal Quantity { get; init; }
            public string CategoryCode { get; init; } = string.Empty;
            public string ExistingNote { get; init; } = string.Empty;
            public string ResolvedPackageName { get; set; } = string.Empty;
            public string ShipmentMaterialsNote { get; set; } = string.Empty;
            public List<MainForm.AquariumSetShipmentMaterial> SelectedMaterials { get; } = new();
        }

        private sealed class OnlineSetAssemblyScanDebugLine
        {
            public string LineId { get; init; } = string.Empty;
            public string ItemCode { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string CategoryCode { get; init; } = string.Empty;
        }

        private sealed class OnlineOrderSerialTrackingLine
        {
            public string LineId { get; init; } = string.Empty;
            public string ItemCode { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string CategoryCode { get; init; } = string.Empty;
            public decimal Quantity { get; init; }
            public string ExistingNote { get; init; } = string.Empty;
        }

        private const string OnlineOrderSerialNotePrefix = "Serial No:";

        private bool PrepareSetAssemblyForOrder(string orderId, string actionLabel)
        {
            var setLines = LoadOnlineSetAssemblyLines(orderId, out var scannedLines);

            if (setLines.Count == 0)
            {
                return true;
            }

            try
            {
                CompleteAquariumSetData.EnsureTablesExist(connectionString);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to initialize aquarium set packages: {ex.Message}", "SET Assembly", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }

            List<CompleteAquariumSetData.PackageHeader> packageHeaders;
            try
            {
                packageHeaders = CompleteAquariumSetData.GetPackageHeaders(connectionString);
                var packageNamesWithLines = CompleteAquariumSetData.GetPackageNamesWithLines(connectionString);
                packageHeaders = packageHeaders
                    .Where(header => !string.IsNullOrWhiteSpace(header.PackageName)
                        && packageNamesWithLines.Contains(header.PackageName.Trim()))
                    .ToList();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load aquarium set packages: {ex.Message}", "SET Assembly", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }

            if (packageHeaders.Count == 0)
            {
                MessageBox.Show(this,
                    "This order contains SET lines, but no aquarium set packages with BOM lines are configured yet.",
                    "SET Assembly",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return false;
            }

            try
            {
                EnsureOnlineSetPackageMapTable();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to initialize SET package mappings: {ex.Message}", "SET Assembly", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }

            var resolvedPackagesByKey = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            foreach (var line in setLines)
            {
                if (TryResolveSetPackageMapping(line, packageHeaders, out var packageName))
                {
                    line.ResolvedPackageName = packageName;
                    resolvedPackagesByKey[BuildSetMappingKey(line)] = packageName;
                }
            }

            foreach (var line in setLines)
            {
                if (!string.IsNullOrWhiteSpace(line.ResolvedPackageName))
                {
                    continue;
                }

                string mappingKey = BuildSetMappingKey(line);
                if (resolvedPackagesByKey.TryGetValue(mappingKey, out var existingPackageName))
                {
                    line.ResolvedPackageName = existingPackageName;
                    continue;
                }

                if (!PromptForSetPackageMapping(line, packageHeaders, out var selectedPackageName))
                {
                    return false;
                }

                try
                {
                    SaveSetPackageMapping(line, selectedPackageName);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, $"Failed to save SET package mapping: {ex.Message}", "SET Assembly", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return false;
                }

                line.ResolvedPackageName = selectedPackageName;
                resolvedPackagesByKey[mappingKey] = selectedPackageName;
            }

            foreach (var line in setLines)
            {
                if (!TryConvertSetAssemblyQuantity(line.Quantity, out var setQuantity))
                {
                    MessageBox.Show(this,
                        $"The SET line '{BuildSetLineDisplayText(line)}' has an invalid quantity '{FormatSetQuantity(line.Quantity)}'.",
                        "SET Assembly",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                    return false;
                }

                if (!MainForm.TryPromptAquariumSetShipmentMaterials(line.ResolvedPackageName, setQuantity, out var materials, out var pickerMessage))
                {
                    if (!string.Equals(pickerMessage, "Selection was cancelled.", StringComparison.OrdinalIgnoreCase)
                        && !string.IsNullOrWhiteSpace(pickerMessage))
                    {
                        MessageBox.Show(this, pickerMessage, "SET Assembly", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }

                    return false;
                }

                line.SelectedMaterials.Clear();
                line.SelectedMaterials.AddRange(materials);
                line.ShipmentMaterialsNote = BuildSetShipmentMaterialsNote(materials, line.ExistingNote);
            }

            string summary = BuildSetAssemblySummary(setLines);
            if (string.IsNullOrWhiteSpace(summary))
            {
                return true;
            }

            var confirmSummary = MessageBox.Show(this,
                "This order contains SET lines. The following BOM package(s) will be assembled:\n\n"
                + summary
                + $"\n\nContinue with {actionLabel}?",
                "SET Assembly",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question);

            if (confirmSummary != DialogResult.Yes)
            {
                return false;
            }

            try
            {
                SaveSetAssemblySelections(orderId, setLines);
                OnlinefunctionsEvents.SyncOnlineOrderItemsFromLocalLinesAsync(orderId).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to save SET shipment materials: {ex.Message}", "SET Assembly", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }

            return true;
        }

        private System.Collections.Generic.List<OnlineSetAssemblyLine> LoadOnlineSetAssemblyLines(string orderId, out System.Collections.Generic.List<OnlineSetAssemblyScanDebugLine> scannedLines)
        {
            var result = new System.Collections.Generic.List<OnlineSetAssemblyLine>();
            scannedLines = new System.Collections.Generic.List<OnlineSetAssemblyScanDebugLine>();

            if (string.IsNullOrWhiteSpace(orderId))
            {
                return result;
            }

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            using var cmd = new SqlCommand("SELECT * FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID ORDER BY LineID", conn);
            cmd.Parameters.AddWithValue("@OrderID", orderId);

            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                string SafeGetString(IDataRecord record, string fieldName)
                {
                    for (int fieldIndex = 0; fieldIndex < record.FieldCount; fieldIndex++)
                    {
                        if (string.Equals(record.GetName(fieldIndex), fieldName, StringComparison.OrdinalIgnoreCase))
                        {
                            if (!record.IsDBNull(fieldIndex))
                            {
                                return record.GetValue(fieldIndex)?.ToString()?.Trim() ?? string.Empty;
                            }

                            return string.Empty;
                        }
                    }

                    return string.Empty;
                }

                decimal SafeGetDecimal(IDataRecord record, string fieldName)
                {
                    string raw = SafeGetString(record, fieldName);
                    if (decimal.TryParse(raw, out var parsed))
                    {
                        return parsed;
                    }

                    return 0m;
                }

                string itemCode = SafeGetString(reader, "ItemCode");
                if (string.IsNullOrWhiteSpace(itemCode))
                {
                    itemCode = SafeGetString(reader, "product_display_id");
                }

                string variationId = SafeGetString(reader, "VariationId");
                string categoryCode = ResolveOnlineLineCategoryCode(conn, variationId, itemCode);
                scannedLines.Add(new OnlineSetAssemblyScanDebugLine
                {
                    LineId = SafeGetString(reader, "LineID"),
                    ItemCode = itemCode,
                    VariationId = variationId,
                    Description = SafeGetString(reader, "Description"),
                    CategoryCode = categoryCode
                });

                if (!string.Equals(categoryCode, "SET", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                result.Add(new OnlineSetAssemblyLine
                {
                    LineId = SafeGetString(reader, "LineID"),
                    ItemCode = itemCode,
                    VariationId = variationId,
                    Description = SafeGetString(reader, "Description"),
                    Quantity = SafeGetDecimal(reader, "Quantity"),
                    CategoryCode = categoryCode,
                    ExistingNote = SafeGetString(reader, "Note")
                });
            }

            return result;
        }

        private string ResolveOnlineLineCategoryCode(SqlConnection _, string variationId, string itemCode)
        {
            string ExecuteScalarString(string sql, Action<SqlParameterCollection> addParameters)
            {
                try
                {
                    using var lookupConnection = new SqlConnection(connectionString);
                    lookupConnection.Open();
                    using var cmd = new SqlCommand(sql, lookupConnection);
                    addParameters(cmd.Parameters);
                    var value = cmd.ExecuteScalar();
                    return value == null || value == DBNull.Value ? string.Empty : (value.ToString()?.Trim() ?? string.Empty);
                }
                catch
                {
                    return string.Empty;
                }
            }

            if (!string.IsNullOrWhiteSpace(variationId))
            {
                string variantCategory = ExecuteScalarString(
                    "SELECT TOP 1 ISNULL(CategoryCode, '') FROM dbo.[Variant] WHERE VariationId = @VariationId",
                    parameters => parameters.AddWithValue("@VariationId", variationId));
                if (!string.IsNullOrWhiteSpace(variantCategory))
                {
                    return variantCategory;
                }

                string itemVariationCategory = ExecuteScalarString(
                    "SELECT TOP 1 ISNULL(CategoryCode, '') FROM dbo.Items WHERE VariationId = @VariationId",
                    parameters => parameters.AddWithValue("@VariationId", variationId));
                if (!string.IsNullOrWhiteSpace(itemVariationCategory))
                {
                    return itemVariationCategory;
                }
            }

            if (!string.IsNullOrWhiteSpace(itemCode))
            {
                string itemCodeCategory = ExecuteScalarString(
                    "SELECT TOP 1 ISNULL(CategoryCode, '') FROM dbo.Items WHERE Code = @ItemCode OR VariationId = @ItemCode",
                    parameters => parameters.AddWithValue("@ItemCode", itemCode));
                if (!string.IsNullOrWhiteSpace(itemCodeCategory))
                {
                    return itemCodeCategory;
                }
            }

            return string.Empty;
        }

        private void EnsureOnlineOrderLinesColumns(SqlConnection conn, SqlTransaction? tran = null)
        {
            using var cmd = new SqlCommand(@"
IF COL_LENGTH('dbo.OnlineOrderLines', 'VariationId') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderLines ADD VariationId NVARCHAR(200) NULL;
END

IF COL_LENGTH('dbo.OnlineOrderLines', 'Note') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderLines ADD Note NVARCHAR(MAX) NULL;
END
ELSE IF EXISTS (
    SELECT 1
    FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.OnlineOrderLines')
      AND name = 'Note'
      AND max_length <> -1
)
BEGIN
    ALTER TABLE dbo.OnlineOrderLines ALTER COLUMN Note NVARCHAR(MAX) NULL;
END

IF COL_LENGTH('dbo.OnlineOrderLines', 'Description') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderLines ADD Description NVARCHAR(500) NULL;
END
ELSE IF EXISTS (
    SELECT 1
    FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.OnlineOrderLines')
      AND name = 'Description'
      AND max_length > 0
      AND max_length < 1000
)
BEGIN
    ALTER TABLE dbo.OnlineOrderLines ALTER COLUMN Description NVARCHAR(500) NULL;
END
", conn, tran);
            cmd.ExecuteNonQuery();
        }

        private bool ShouldRequireOnlineOrderSerialSelection(string? categoryCode, string? itemCode)
        {
            string normalizedCategory = categoryCode?.Trim() ?? string.Empty;
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;

            if (string.IsNullOrWhiteSpace(normalizedItemCode))
            {
                return false;
            }

            return string.Equals(normalizedCategory, "AQUARIUM", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedCategory, "STAND", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedCategory, "SUMP", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("AQ-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-AQUARIUM", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_STAND", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-SUMP", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_SUMP", StringComparison.OrdinalIgnoreCase);
        }

        private static List<string> ParseOnlineOrderLineSerialNumbers(string note)
        {
            foreach (var line in (note ?? string.Empty).Split(new[] { "\r\n", "\n" }, StringSplitOptions.None))
            {
                string trimmedLine = line?.Trim() ?? string.Empty;
                if (!trimmedLine.StartsWith(OnlineOrderSerialNotePrefix, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                return trimmedLine.Substring(OnlineOrderSerialNotePrefix.Length)
                    .Split(new[] { ';', ',' }, StringSplitOptions.RemoveEmptyEntries)
                    .Select(serialNo => serialNo?.Trim() ?? string.Empty)
                    .Where(serialNo => !string.IsNullOrWhiteSpace(serialNo))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToList();
            }

            return new List<string>();
        }

        private static string BuildOnlineOrderSerialTrackingNote(string existingNote, IEnumerable<string> serialNumbers)
        {
            var normalizedSerials = serialNumbers?
                .Select(serialNo => serialNo?.Trim() ?? string.Empty)
                .Where(serialNo => !string.IsNullOrWhiteSpace(serialNo))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList() ?? new List<string>();

            var preservedLines = (existingNote ?? string.Empty)
                .Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)
                .Where(line => !string.IsNullOrWhiteSpace(line) && !line.TrimStart().StartsWith(OnlineOrderSerialNotePrefix, StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (normalizedSerials.Count > 0)
            {
                preservedLines.Add($"{OnlineOrderSerialNotePrefix} {string.Join("; ", normalizedSerials)}");
            }

            return string.Join(Environment.NewLine, preservedLines);
        }

        private System.Collections.Generic.List<OnlineOrderSerialTrackingLine> LoadOnlineOrderSerialTrackingLines(string orderId)
        {
            var result = new System.Collections.Generic.List<OnlineOrderSerialTrackingLine>();
            if (string.IsNullOrWhiteSpace(orderId))
            {
                return result;
            }

            using var conn = new SqlConnection(connectionString);
            conn.Open();
            EnsureOnlineOrderLinesColumns(conn);

            using var cmd = new SqlCommand("SELECT * FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID ORDER BY LineID", conn);
            cmd.Parameters.AddWithValue("@OrderID", orderId);

            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                string SafeGetString(IDataRecord record, string fieldName)
                {
                    for (int fieldIndex = 0; fieldIndex < record.FieldCount; fieldIndex++)
                    {
                        if (!string.Equals(record.GetName(fieldIndex), fieldName, StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }

                        return record.IsDBNull(fieldIndex)
                            ? string.Empty
                            : record.GetValue(fieldIndex)?.ToString()?.Trim() ?? string.Empty;
                    }

                    return string.Empty;
                }

                decimal SafeGetDecimal(IDataRecord record, string fieldName)
                {
                    string raw = SafeGetString(record, fieldName);
                    return decimal.TryParse(raw, out var parsed) ? parsed : 0m;
                }

                string itemCode = SafeGetString(reader, "ItemCode");
                if (string.IsNullOrWhiteSpace(itemCode))
                {
                    itemCode = SafeGetString(reader, "product_display_id");
                }

                string variationId = SafeGetString(reader, "VariationId");
                string categoryCode = ResolveOnlineLineCategoryCode(conn, variationId, itemCode);
                if (!ShouldRequireOnlineOrderSerialSelection(categoryCode, itemCode))
                {
                    continue;
                }

                decimal quantity = SafeGetDecimal(reader, "Quantity");
                if (quantity <= 0m)
                {
                    continue;
                }

                result.Add(new OnlineOrderSerialTrackingLine
                {
                    LineId = SafeGetString(reader, "LineID"),
                    ItemCode = itemCode,
                    VariationId = variationId,
                    Description = SafeGetString(reader, "Description"),
                    CategoryCode = categoryCode,
                    Quantity = quantity,
                    ExistingNote = SafeGetString(reader, "Note")
                });
            }

            return result;
        }

        private List<ProductSerialTrackingForm.AvailableSerialRecord>? PromptForOnlineOrderSerials(OnlineOrderSerialTrackingLine line, int quantityNeeded, IEnumerable<string>? additionalExcludedSerialNumbers = null)
        {
            if (!IsCurrentWarehouseProduction())
            {
                return new List<ProductSerialTrackingForm.AvailableSerialRecord>();
            }

            int requiredQuantity = Math.Max(1, quantityNeeded);
            var excludedSerials = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string serialNo in additionalExcludedSerialNumbers ?? Enumerable.Empty<string>())
            {
                string normalizedSerialNo = serialNo?.Trim() ?? string.Empty;
                if (!string.IsNullOrWhiteSpace(normalizedSerialNo))
                {
                    excludedSerials.Add(normalizedSerialNo);
                }
            }

            var availableSerials = ProductSerialTrackingForm.GetAvailableSerials(line.ItemCode, line.VariationId, excludedSerials);
            if (availableSerials.Count < requiredQuantity)
            {
                MessageBox.Show(this,
                    string.IsNullOrWhiteSpace(line.VariationId)
                        ? $"This order needs {requiredQuantity} serial-tracked unit(s) for {line.ItemCode}, but only {availableSerials.Count} are available. The missing serials will be auto-created and labels will be printed."
                        : $"This order needs {requiredQuantity} serial-tracked unit(s) for {line.ItemCode} variant {line.VariationId}, but only {availableSerials.Count} are available. The missing serials will be auto-created and labels will be printed.",
                    "Serial Tracking",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                requiredQuantity = availableSerials.Count;
            }

            var selectedSerials = new List<ProductSerialTrackingForm.AvailableSerialRecord>();
            for (int index = 0; index < requiredQuantity; index++)
            {
                var remainingOptions = availableSerials
                    .Where(option => !selectedSerials.Any(selected => string.Equals(selected.SerialNo, option.SerialNo, StringComparison.OrdinalIgnoreCase)))
                    .ToList();

                var selectedSerial = PromptForOnlineOrderSerial(line, index + 1, requiredQuantity, remainingOptions);
                if (selectedSerial == null)
                {
                    return null;
                }

                selectedSerials.Add(selectedSerial);
            }

            return selectedSerials;
        }

        private ProductSerialTrackingForm.AvailableSerialRecord? PromptForOnlineOrderSerial(
            OnlineOrderSerialTrackingLine line,
            int selectionIndex,
            int totalSelections,
            List<ProductSerialTrackingForm.AvailableSerialRecord> availableSerials)
        {
            if (availableSerials == null || availableSerials.Count == 0)
            {
                return null;
            }

            using var dialog = new Form
            {
                Text = "Select Order Serial",
                StartPosition = FormStartPosition.CenterParent,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MinimizeBox = false,
                MaximizeBox = false,
                ShowInTaskbar = false,
                Size = new Size(720, 520),
                BackColor = Color.White
            };

            var titleLabel = new Label
            {
                Text = totalSelections > 1
                    ? $"Select serial {selectionIndex} of {totalSelections}"
                    : "Select the serial for this order line",
                Location = new Point(20, 20),
                Size = new Size(660, 34),
                Font = new Font("Arial", 14, FontStyle.Bold),
                ForeColor = Color.DarkBlue
            };

            var infoLabel = new Label
            {
                Text = string.IsNullOrWhiteSpace(line.Description)
                    ? $"Choose a serial for {line.ItemCode}{(string.IsNullOrWhiteSpace(line.VariationId) ? string.Empty : $" / {line.VariationId}")}."
                    : $"Choose a serial for {line.Description} ({line.ItemCode}{(string.IsNullOrWhiteSpace(line.VariationId) ? string.Empty : $" / {line.VariationId}")}).",
                Location = new Point(20, 58),
                Size = new Size(660, 50),
                Font = new Font("Arial", 11, FontStyle.Bold),
                ForeColor = Color.DimGray
            };

            var listBox = new ListBox
            {
                Location = new Point(20, 112),
                Size = new Size(660, 304),
                Font = new Font("Arial", 10, FontStyle.Regular),
                DisplayMember = nameof(ProductSerialTrackingForm.AvailableSerialRecord.SerialNo)
            };

            foreach (var availableSerial in availableSerials)
            {
                listBox.Items.Add(availableSerial);
            }

            if (listBox.Items.Count > 0)
            {
                listBox.SelectedIndex = 0;
            }

            var okButton = new Button
            {
                Text = "Select",
                Location = new Point(430, 430),
                Size = new Size(120, 38),
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var cancelButton = new Button
            {
                Text = "Cancel",
                Location = new Point(560, 430),
                Size = new Size(120, 38),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            ProductSerialTrackingForm.AvailableSerialRecord? selectedSerial = null;
            okButton.Click += (_, _) =>
            {
                if (listBox.SelectedItem is not ProductSerialTrackingForm.AvailableSerialRecord choice)
                {
                    MessageBox.Show(dialog,
                        "Select an available serial first.",
                        "Serial Tracking",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                    return;
                }

                selectedSerial = choice;
                dialog.DialogResult = DialogResult.OK;
                dialog.Close();
            };

            cancelButton.Click += (_, _) =>
            {
                dialog.DialogResult = DialogResult.Cancel;
                dialog.Close();
            };

            listBox.DoubleClick += (_, _) => okButton.PerformClick();

            dialog.Controls.Add(titleLabel);
            dialog.Controls.Add(infoLabel);
            dialog.Controls.Add(listBox);
            dialog.Controls.Add(okButton);
            dialog.Controls.Add(cancelButton);
            dialog.AcceptButton = okButton;
            dialog.CancelButton = cancelButton;

            return dialog.ShowDialog(this) == DialogResult.OK ? selectedSerial : null;
        }

        private void SaveOnlineOrderSerialTrackingNote(string orderId, string lineId, string note)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();
            EnsureOnlineOrderLinesColumns(conn);

            using var cmd = new SqlCommand("UPDATE dbo.OnlineOrderLines SET Note = @Note WHERE OrderID = @OrderID AND LineID = @LineID", conn);
            cmd.Parameters.AddWithValue("@OrderID", orderId);
            cmd.Parameters.AddWithValue("@LineID", lineId);
            cmd.Parameters.AddWithValue("@Note", string.IsNullOrWhiteSpace(note) ? (object)DBNull.Value : note);
            cmd.ExecuteNonQuery();
        }

        private List<string> LoadTrackedSerialNumbersForOrder(string orderId)
        {
            var serialNumbers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (string.IsNullOrWhiteSpace(orderId))
            {
                return serialNumbers.ToList();
            }

            using var conn = new SqlConnection(connectionString);
            conn.Open();
            EnsureOnlineOrderLinesColumns(conn);

            using var cmd = new SqlCommand("SELECT Note FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID", conn);
            cmd.Parameters.AddWithValue("@OrderID", orderId);
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string note = rdr["Note"]?.ToString() ?? string.Empty;
                foreach (string serialNo in ParseOnlineOrderLineSerialNumbers(note))
                {
                    serialNumbers.Add(serialNo);
                }
            }

            return serialNumbers.ToList();
        }

        private async Task<bool> EnsureOrderSerialTrackingAsync(string orderId, string actionLabel)
        {
            if (string.IsNullOrWhiteSpace(orderId))
            {
                return true;
            }

            if (!IsCurrentWarehouseProduction())
            {
                return true;
            }

            try
            {
                await FetchAndPersistOrderLinesAsync(orderId).ConfigureAwait(false);
            }
            catch { }

            var serialTrackedLines = LoadOnlineOrderSerialTrackingLines(orderId);
            if (serialTrackedLines.Count == 0)
            {
                return true;
            }

            var assignedSerialsAcrossOrder = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var trackedLine in serialTrackedLines)
            {
                foreach (string serialNo in ParseOnlineOrderLineSerialNumbers(trackedLine.ExistingNote))
                {
                    assignedSerialsAcrossOrder.Add(serialNo);
                }
            }

            var generatedSerialLabels = new List<(string SerialNo, string ItemCode, string Description)>();
            foreach (var line in serialTrackedLines)
            {
                int requiredQuantity = Math.Max(1, (int)Math.Ceiling(line.Quantity));
                var assignedSerials = ParseOnlineOrderLineSerialNumbers(line.ExistingNote);
                if (assignedSerials.Count >= requiredQuantity)
                {
                    continue;
                }

                int quantityNeeded = requiredQuantity - assignedSerials.Count;
                var excludedSerials = assignedSerialsAcrossOrder
                    .Where(serialNo => !assignedSerials.Contains(serialNo, StringComparer.OrdinalIgnoreCase))
                    .ToList();
                var selectedSerials = PromptForOnlineOrderSerials(line, quantityNeeded, excludedSerials);
                if (selectedSerials == null)
                {
                    MessageBox.Show(this,
                        $"{actionLabel} was cancelled because serial numbers are still required for {line.ItemCode}.",
                        "Serial Tracking",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                    return false;
                }

                int missingSerialCount = Math.Max(0, quantityNeeded - selectedSerials.Count);
                var generatedSerialsForLine = new List<(string SerialNo, string ItemCode, string Description)>();
                if (missingSerialCount > 0)
                {
                    using var serialConn = new SqlConnection(connectionString);
                    serialConn.Open();
                    generatedSerialsForLine = ProductSerialTrackingForm.CreateSoldSerialRecords(
                        serialConn,
                        null,
                        line.ItemCode,
                        line.VariationId,
                        string.IsNullOrWhiteSpace(line.Description) ? line.ItemCode : line.Description,
                        orderId,
                        orderId,
                        CurrentUser.GetEffectiveUsername("POS_SYSTEM"),
                        missingSerialCount);
                    generatedSerialLabels.AddRange(generatedSerialsForLine);
                }

                var finalSerials = assignedSerials
                    .Concat(selectedSerials.Select(serial => serial.SerialNo))
                    .Concat(generatedSerialsForLine.Select(generated => generated.SerialNo))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToList();

                SaveOnlineOrderSerialTrackingNote(orderId, line.LineId, BuildOnlineOrderSerialTrackingNote(line.ExistingNote, finalSerials));
                ProductSerialTrackingForm.MarkSerialsSold(selectedSerials.Select(serial => serial.SerialNo), null, orderId);
                foreach (string serialNo in finalSerials)
                {
                    assignedSerialsAcrossOrder.Add(serialNo);
                }
            }

            if (generatedSerialLabels.Count > 0)
            {
                try
                {
                    MainForm.PrintSerialNumberLabels(generatedSerialLabels);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this,
                        $"{actionLabel} continued, but printing the generated serial labels failed: {ex.Message}",
                        "Label Print Warning",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                }
            }

            return true;
        }

        private void EnsureOnlineSetPackageMapTable()
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();
            EnsureOnlineSetPackageMapTable(connection);
        }

        private static void EnsureOnlineSetPackageMapTable(SqlConnection connection)
        {
            using var cmd = new SqlCommand($@"
IF OBJECT_ID(N'{OnlineSetPackageMapTable}', N'U') IS NULL
BEGIN
    CREATE TABLE {OnlineSetPackageMapTable} (
        MatchType NVARCHAR(30) NOT NULL,
        MatchValue NVARCHAR(200) NOT NULL,
        PackageName NVARCHAR(100) NOT NULL,
        SourceDescription NVARCHAR(255) NULL,
        UpdatedDate DATETIME2 NOT NULL CONSTRAINT DF_OnlineSetPackageMap_UpdatedDate DEFAULT GETDATE(),
        CONSTRAINT PK_OnlineSetPackageMap PRIMARY KEY (MatchType, MatchValue)
    )
END

IF COL_LENGTH('{OnlineSetPackageMapTable}', 'SourceDescription') IS NULL
BEGIN
    ALTER TABLE {OnlineSetPackageMapTable} ADD SourceDescription NVARCHAR(255) NULL
END

IF COL_LENGTH('{OnlineSetPackageMapTable}', 'UpdatedDate') IS NULL
BEGIN
    ALTER TABLE {OnlineSetPackageMapTable} ADD UpdatedDate DATETIME2 NOT NULL CONSTRAINT DF_OnlineSetPackageMap_UpdatedDate_Runtime DEFAULT GETDATE()
END", connection);
            cmd.ExecuteNonQuery();
        }

        private bool TryResolveSetPackageMapping(OnlineSetAssemblyLine line, System.Collections.Generic.List<CompleteAquariumSetData.PackageHeader> packageHeaders, out string packageName)
        {
            packageName = string.Empty;

            if (!string.IsNullOrWhiteSpace(line.VariationId))
            {
                var directVariantMatch = packageHeaders.FirstOrDefault(header =>
                    !string.IsNullOrWhiteSpace(header.VariantID)
                    && string.Equals(header.VariantID.Trim(), line.VariationId.Trim(), StringComparison.OrdinalIgnoreCase));
                if (directVariantMatch != null && !string.IsNullOrWhiteSpace(directVariantMatch.PackageName))
                {
                    packageName = directVariantMatch.PackageName.Trim();
                    return true;
                }
            }

            if (!string.IsNullOrWhiteSpace(line.VariationId)
                && TryGetMappedPackageName("VariationId", line.VariationId, out packageName)
                && PackageExists(packageHeaders, packageName))
            {
                return true;
            }

            if (!string.IsNullOrWhiteSpace(line.ItemCode)
                && TryGetMappedPackageName("ItemCode", line.ItemCode, out packageName)
                && PackageExists(packageHeaders, packageName))
            {
                return true;
            }

            packageName = string.Empty;
            return false;
        }

        private bool TryGetMappedPackageName(string matchType, string matchValue, out string packageName)
        {
            packageName = string.Empty;
            if (string.IsNullOrWhiteSpace(matchType) || string.IsNullOrWhiteSpace(matchValue))
            {
                return false;
            }

            using var connection = new SqlConnection(connectionString);
            connection.Open();
            EnsureOnlineSetPackageMapTable(connection);

            using var cmd = new SqlCommand($"SELECT TOP 1 PackageName FROM {OnlineSetPackageMapTable} WHERE MatchType = @MatchType AND MatchValue = @MatchValue", connection);
            cmd.Parameters.AddWithValue("@MatchType", matchType.Trim());
            cmd.Parameters.AddWithValue("@MatchValue", matchValue.Trim());

            var value = cmd.ExecuteScalar();
            packageName = value == null || value == DBNull.Value ? string.Empty : (value.ToString()?.Trim() ?? string.Empty);
            return !string.IsNullOrWhiteSpace(packageName);
        }

        private void SaveSetPackageMapping(OnlineSetAssemblyLine line, string packageName)
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();
            EnsureOnlineSetPackageMapTable(connection);

            void UpsertMapping(string matchType, string matchValue)
            {
                if (string.IsNullOrWhiteSpace(matchValue))
                {
                    return;
                }

                using var cmd = new SqlCommand($@"
MERGE {OnlineSetPackageMapTable} AS target
USING (SELECT @MatchType AS MatchType, @MatchValue AS MatchValue) AS source
ON target.MatchType = source.MatchType AND target.MatchValue = source.MatchValue
WHEN MATCHED THEN
    UPDATE SET PackageName = @PackageName, SourceDescription = @SourceDescription, UpdatedDate = GETDATE()
WHEN NOT MATCHED THEN
    INSERT (MatchType, MatchValue, PackageName, SourceDescription, UpdatedDate)
    VALUES (@MatchType, @MatchValue, @PackageName, @SourceDescription, GETDATE());", connection);
                cmd.Parameters.AddWithValue("@MatchType", matchType);
                cmd.Parameters.AddWithValue("@MatchValue", matchValue.Trim());
                cmd.Parameters.AddWithValue("@PackageName", packageName.Trim());
                cmd.Parameters.AddWithValue("@SourceDescription", string.IsNullOrWhiteSpace(line.Description) ? (object)DBNull.Value : line.Description.Trim());
                cmd.ExecuteNonQuery();
            }

            UpsertMapping("VariationId", line.VariationId);
            UpsertMapping("ItemCode", line.ItemCode);
        }

        private bool PromptForSetPackageMapping(OnlineSetAssemblyLine line, System.Collections.Generic.List<CompleteAquariumSetData.PackageHeader> packageHeaders, out string packageName)
        {
            packageName = string.Empty;
            string selectedPackageName = string.Empty;

            using var dialog = new Form();
            dialog.Text = "Map SET Line To BOM Package";
            dialog.StartPosition = FormStartPosition.CenterParent;
            dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
            dialog.MinimizeBox = false;
            dialog.MaximizeBox = false;
            dialog.ShowInTaskbar = false;
            dialog.ClientSize = new Size(720, 250);

            var titleLabel = new Label
            {
                Left = 20,
                Top = 20,
                Width = 660,
                Height = 24,
                Font = new Font("Arial", 11, FontStyle.Bold),
                Text = "Select the BOM package to use for this SET order line."
            };

            var detailsLabel = new Label
            {
                Left = 20,
                Top = 55,
                Width = 660,
                Height = 84,
                Font = new Font("Arial", 10, FontStyle.Regular),
                Text = $"Description: {BuildSetLineDisplayText(line)}\n"
                    + $"Quantity: {FormatSetQuantity(line.Quantity)}\n"
                    + $"Item Code: {(string.IsNullOrWhiteSpace(line.ItemCode) ? "(blank)" : line.ItemCode)}\n"
                    + $"Variation ID: {(string.IsNullOrWhiteSpace(line.VariationId) ? "(blank)" : line.VariationId)}"
            };

            var comboLabel = new Label
            {
                Left = 20,
                Top = 148,
                Width = 140,
                Height = 22,
                Font = new Font("Arial", 10, FontStyle.Bold),
                Text = "BOM Package"
            };

            var packageCombo = new ComboBox
            {
                Left = 165,
                Top = 144,
                Width = 515,
                DropDownStyle = ComboBoxStyle.DropDownList,
                FormattingEnabled = true,
                DataSource = packageHeaders,
                DisplayMember = nameof(CompleteAquariumSetData.PackageHeader.DisplayText)
            };

            string displayText = BuildSetLineDisplayText(line);
            for (int index = 0; index < packageHeaders.Count; index++)
            {
                var candidate = packageHeaders[index];
                if (string.Equals(candidate.PackageName, displayText, StringComparison.OrdinalIgnoreCase)
                    || (!string.IsNullOrWhiteSpace(displayText) && displayText.IndexOf(candidate.PackageName, StringComparison.OrdinalIgnoreCase) >= 0))
                {
                    packageCombo.SelectedItem = candidate;
                    break;
                }
            }

            var hintLabel = new Label
            {
                Left = 20,
                Top = 178,
                Width = 660,
                Height = 22,
                Font = new Font("Arial", 9, FontStyle.Italic),
                ForeColor = Color.DimGray,
                Text = "This mapping will be remembered and reused automatically for future online orders."
            };

            var okButton = new Button
            {
                Text = "Save Mapping",
                Left = 430,
                Top = 205,
                Width = 120,
                Height = 32,
                DialogResult = DialogResult.None
            };
            okButton.Click += (sender, args) =>
            {
                if (packageCombo.SelectedItem is not CompleteAquariumSetData.PackageHeader selectedPackage)
                {
                    MessageBox.Show(dialog, "Please select a BOM package.", "SET Assembly", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                selectedPackageName = selectedPackage.PackageName?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(selectedPackageName))
                {
                    MessageBox.Show(dialog, "Please select a valid BOM package.", "SET Assembly", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                dialog.DialogResult = DialogResult.OK;
                dialog.Close();
            };

            var cancelButton = new Button
            {
                Text = "Cancel",
                Left = 560,
                Top = 205,
                Width = 120,
                Height = 32,
                DialogResult = DialogResult.Cancel
            };

            dialog.Controls.Add(titleLabel);
            dialog.Controls.Add(detailsLabel);
            dialog.Controls.Add(comboLabel);
            dialog.Controls.Add(packageCombo);
            dialog.Controls.Add(hintLabel);
            dialog.Controls.Add(okButton);
            dialog.Controls.Add(cancelButton);
            dialog.AcceptButton = okButton;
            dialog.CancelButton = cancelButton;

            bool accepted = dialog.ShowDialog(this) == DialogResult.OK && !string.IsNullOrWhiteSpace(selectedPackageName);
            if (accepted)
            {
                packageName = selectedPackageName;
            }

            return accepted;
        }

        private string BuildSetAssemblySummary(System.Collections.Generic.List<OnlineSetAssemblyLine> setLines)
        {
            var summary = new StringBuilder();
            foreach (var line in setLines)
            {
                if (string.IsNullOrWhiteSpace(line.ResolvedPackageName))
                {
                    continue;
                }

                summary.Append("- ");
                summary.Append(line.ResolvedPackageName);
                summary.Append(" x ");
                summary.Append(FormatSetQuantity(line.Quantity <= 0m ? 1m : line.Quantity));
                summary.Append(" for ");
                summary.Append(BuildSetLineDisplayText(line));
                if (!string.IsNullOrWhiteSpace(line.ShipmentMaterialsNote))
                {
                    summary.Append(" => ");
                    summary.Append(line.ShipmentMaterialsNote);
                }

                summary.AppendLine();
            }

            return summary.ToString().Trim();
        }

        private static bool TryConvertSetAssemblyQuantity(decimal quantity, out int setQuantity)
        {
            setQuantity = 0;
            if (quantity <= 0m || decimal.Truncate(quantity) != quantity)
            {
                return false;
            }

            try
            {
                setQuantity = decimal.ToInt32(quantity);
                return setQuantity > 0;
            }
            catch
            {
                setQuantity = 0;
                return false;
            }
        }

        private static string BuildSetShipmentMaterialsNote(List<MainForm.AquariumSetShipmentMaterial> materials, string existingNote)
        {
            const string prefix = "SET Materials:";

            var materialSummary = string.Join("; ", materials
                .Where(material => material != null && material.Quantity > 0)
                .GroupBy(material => string.IsNullOrWhiteSpace(material.Description)
                    ? (!string.IsNullOrWhiteSpace(material.ItemName) ? material.ItemName : material.ItemCode)
                    : material.Description,
                    StringComparer.OrdinalIgnoreCase)
                .Select(group => $"{group.Key} x {group.Sum(material => material.Quantity):N0}"));

            if (string.IsNullOrWhiteSpace(materialSummary))
            {
                return existingNote?.Trim() ?? string.Empty;
            }

            var preservedLines = (existingNote ?? string.Empty)
                .Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)
                .Where(line => !string.IsNullOrWhiteSpace(line) && !line.TrimStart().StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                .ToList();

            preservedLines.Add($"{prefix} {materialSummary}");
            return string.Join(Environment.NewLine, preservedLines);
        }

        private void SaveSetAssemblySelections(string orderId, System.Collections.Generic.List<OnlineSetAssemblyLine> setLines)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();

            foreach (var line in setLines)
            {
                if (string.IsNullOrWhiteSpace(line.LineId))
                {
                    continue;
                }

                using var cmd = new SqlCommand("UPDATE dbo.OnlineOrderLines SET Note = @Note WHERE OrderID = @OrderID AND LineID = @LineID", conn);
                cmd.Parameters.AddWithValue("@OrderID", orderId);
                cmd.Parameters.AddWithValue("@LineID", line.LineId);
                cmd.Parameters.AddWithValue("@Note", string.IsNullOrWhiteSpace(line.ShipmentMaterialsNote) ? (object)DBNull.Value : line.ShipmentMaterialsNote);
                cmd.ExecuteNonQuery();

                string generatedPrefix = BuildSetMaterialGeneratedLinePrefix(line);
                string generatedNote = $"SET Material for {BuildSetLineDisplayText(line)}";
                using (var deleteCmd = new SqlCommand("DELETE FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID AND LineID LIKE @LinePrefix", conn))
                {
                    deleteCmd.Parameters.AddWithValue("@OrderID", orderId);
                    deleteCmd.Parameters.AddWithValue("@LinePrefix", generatedPrefix + "%");
                    deleteCmd.ExecuteNonQuery();
                }

                using (var deleteSyncedDuplicatesCmd = new SqlCommand("DELETE FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID AND LineID NOT LIKE @LinePrefix AND Note = @Note", conn))
                {
                    deleteSyncedDuplicatesCmd.Parameters.AddWithValue("@OrderID", orderId);
                    deleteSyncedDuplicatesCmd.Parameters.AddWithValue("@LinePrefix", generatedPrefix + "%");
                    deleteSyncedDuplicatesCmd.Parameters.AddWithValue("@Note", generatedNote);
                    deleteSyncedDuplicatesCmd.ExecuteNonQuery();
                }

                for (int index = 0; index < line.SelectedMaterials.Count; index++)
                {
                    var material = line.SelectedMaterials[index];
                    if (material == null || material.Quantity <= 0)
                    {
                        continue;
                    }

                    string resolvedVariationId = ResolveSetMaterialVariationId(material);
                    string resolvedItemCode = ResolveSetMaterialItemCode(material, resolvedVariationId);
                    string description = string.IsNullOrWhiteSpace(material.Description)
                        ? (!string.IsNullOrWhiteSpace(material.ItemName) ? material.ItemName : resolvedItemCode)
                        : material.Description;
                    string note = generatedNote;
                    decimal price = 0m;

                    IntegrationEvents.WriteintoOnlineOrderLines(
                        orderId,
                        BuildSetMaterialGeneratedLineId(line, index),
                        resolvedItemCode,
                        material.Quantity,
                        null,
                        price,
                        note,
                        description,
                        resolvedVariationId);
                }
            }
        }

        private static string BuildSetMaterialGeneratedLinePrefix(OnlineSetAssemblyLine line)
        {
            string lineId = string.IsNullOrWhiteSpace(line.LineId) ? BuildSetLineDisplayText(line) : line.LineId.Trim();
            return lineId + "~SETMAT~";
        }

        private static string BuildSetMaterialGeneratedLineId(OnlineSetAssemblyLine line, int index)
        {
            return BuildSetMaterialGeneratedLinePrefix(line) + (index + 1).ToString("D2");
        }

        private string ResolveSetMaterialVariationId(MainForm.AquariumSetShipmentMaterial material)
        {
            if (!string.IsNullOrWhiteSpace(material.VariationId))
            {
                return material.VariationId.Trim();
            }

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            using var cmd = new SqlCommand(@"
SELECT TOP 1 ISNULL(VariationId, '')
FROM dbo.Items
WHERE Code = @Code
   OR VariationId = @Code
   OR Name = @Name
   OR Description = @Description", conn);
            cmd.Parameters.AddWithValue("@Code", (material.ItemCode ?? string.Empty).Trim());
            cmd.Parameters.AddWithValue("@Name", (material.ItemName ?? string.Empty).Trim());
            cmd.Parameters.AddWithValue("@Description", (material.Description ?? string.Empty).Trim());

            var value = cmd.ExecuteScalar();
            return value == null || value == DBNull.Value ? string.Empty : (value.ToString()?.Trim() ?? string.Empty);
        }

        private string ResolveSetMaterialItemCode(MainForm.AquariumSetShipmentMaterial material, string resolvedVariationId)
        {
            if (!string.IsNullOrWhiteSpace(material.ItemCode))
            {
                return material.ItemCode.Trim();
            }

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            using var cmd = new SqlCommand(@"
SELECT TOP 1 ISNULL(Code, '')
FROM dbo.Items
WHERE VariationId = @VariationId
   OR Name = @Name
   OR Description = @Description", conn);
            cmd.Parameters.AddWithValue("@VariationId", (resolvedVariationId ?? string.Empty).Trim());
            cmd.Parameters.AddWithValue("@Name", (material.ItemName ?? string.Empty).Trim());
            cmd.Parameters.AddWithValue("@Description", (material.Description ?? string.Empty).Trim());

            var value = cmd.ExecuteScalar();
            return value == null || value == DBNull.Value ? string.Empty : (value.ToString()?.Trim() ?? string.Empty);
        }

        private decimal ResolveSetMaterialPrice(MainForm.AquariumSetShipmentMaterial material, string resolvedItemCode, string resolvedVariationId)
        {
            if (material.Price > 0m)
            {
                return material.Price;
            }

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            using var cmd = new SqlCommand(@"
SELECT TOP 1 ISNULL(Price, 0)
FROM dbo.Items
WHERE Code = @Code
   OR VariationId = @VariationId
   OR Name = @Name
   OR Description = @Description", conn);
            cmd.Parameters.AddWithValue("@Code", (resolvedItemCode ?? string.Empty).Trim());
            cmd.Parameters.AddWithValue("@VariationId", (resolvedVariationId ?? string.Empty).Trim());
            cmd.Parameters.AddWithValue("@Name", (material.ItemName ?? string.Empty).Trim());
            cmd.Parameters.AddWithValue("@Description", (material.Description ?? string.Empty).Trim());

            var value = cmd.ExecuteScalar();
            if (value == null || value == DBNull.Value)
            {
                return 0m;
            }

            try
            {
                return Convert.ToDecimal(value);
            }
            catch
            {
                return 0m;
            }
        }

        private static string BuildSetLineDisplayText(OnlineSetAssemblyLine line)
        {
            if (!string.IsNullOrWhiteSpace(line.Description))
            {
                return line.Description.Trim();
            }

            if (!string.IsNullOrWhiteSpace(line.ItemCode))
            {
                return line.ItemCode.Trim();
            }

            if (!string.IsNullOrWhiteSpace(line.VariationId))
            {
                return line.VariationId.Trim();
            }

            return $"SET Line {line.LineId}";
        }

        private static string BuildSetMappingKey(OnlineSetAssemblyLine line)
        {
            if (!string.IsNullOrWhiteSpace(line.VariationId))
            {
                return "VariationId:" + line.VariationId.Trim();
            }

            return "ItemCode:" + (line.ItemCode?.Trim() ?? string.Empty);
        }

        private static bool PackageExists(System.Collections.Generic.List<CompleteAquariumSetData.PackageHeader> packageHeaders, string packageName)
        {
            foreach (var header in packageHeaders)
            {
                if (string.Equals(header.PackageName, packageName, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private static string FormatSetQuantity(decimal quantity)
        {
            if (decimal.Truncate(quantity) == quantity)
            {
                return quantity.ToString("N0");
            }

            return quantity.ToString("N2");
        }

        private bool IsPrintedStatusForRow(int rowIndex)
        {
            if (rowIndex < 0 || rowIndex >= dgv.Rows.Count)
                return false;

            try
            {
                string status = string.Empty;
                if (dgv.Columns.Contains("Status"))
                    status = dgv.Rows[rowIndex].Cells["Status"].Value?.ToString() ?? string.Empty;

                if (string.IsNullOrWhiteSpace(status))
                {
                    var dt = dgv.DataSource as DataTable;
                    if (dt != null && dt.Rows.Count > rowIndex && dt.Columns.Contains("Status"))
                        status = dt.Rows[rowIndex]["Status"]?.ToString() ?? string.Empty;
                }

                return string.Equals(status?.Trim(), "Printed", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private DateTime? GetEstimatedDeliveryDateForRow(int rowIndex)
        {
            if (rowIndex < 0 || rowIndex >= dgv.Rows.Count)
                return null;

            static DateTime? ParseDate(object? value)
            {
                try
                {
                    if (value == null || value == DBNull.Value)
                        return null;

                    if (value is DateTime dt)
                        return dt.Date;

                    var text = value.ToString()?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(text))
                        return null;

                    if (DateTime.TryParse(text, out var parsed))
                        return parsed.Date;
                }
                catch { }

                return null;
            }

            try
            {
                if (dgv.Columns.Contains("Estimated Delivery Date"))
                {
                    var parsed = ParseDate(dgv.Rows[rowIndex].Cells["Estimated Delivery Date"].Value);
                    if (parsed.HasValue)
                        return parsed.Value;
                }
            }
            catch { }

            try
            {
                var dt = dgv.DataSource as DataTable;
                if (dt != null && dt.Rows.Count > rowIndex && dt.Columns.Contains("Estimated Delivery Date"))
                    return ParseDate(dt.Rows[rowIndex]["Estimated Delivery Date"]);
            }
            catch { }

            return null;
        }

        private void ApplyOrderRowFormatting(DataGridViewRow row)
        {
            if (row == null || row.Index < 0)
                return;

            try
            {
                var estimatedDeliveryDate = GetEstimatedDeliveryDateForRow(row.Index);
                bool highlightTodayPrinted = IsPrintedStatusForRow(row.Index)
                    && estimatedDeliveryDate.HasValue
                    && estimatedDeliveryDate.Value.Date <= DateTime.Today;

                Color foreColor = highlightTodayPrinted ? Color.Red : dgv.DefaultCellStyle.ForeColor;
                row.DefaultCellStyle.ForeColor = foreColor;
                row.DefaultCellStyle.SelectionForeColor = foreColor;
            }
            catch { }
        }

        private void Dgv_RowPrePaint(object? sender, DataGridViewRowPrePaintEventArgs e)
        {
            if (e.RowIndex < 0 || e.RowIndex >= dgv.Rows.Count)
                return;

            try
            {
                ApplyOrderRowFormatting(dgv.Rows[e.RowIndex]);
            }
            catch { }
        }

        private bool IsForDeliveryForRow(int rowIndex)
        {
            if (rowIndex < 0 || rowIndex >= dgv.Rows.Count)
                return false;

            static bool ParseBoolValue(object? value)
            {
                try
                {
                    if (value == null || value == DBNull.Value)
                        return false;

                    if (value is bool boolValue)
                        return boolValue;
                    if (value is byte byteValue)
                        return byteValue != 0;
                    if (value is short shortValue)
                        return shortValue != 0;
                    if (value is int intValue)
                        return intValue != 0;
                    if (value is long longValue)
                        return longValue != 0;

                    var text = value.ToString()?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(text))
                        return false;

                    if (bool.TryParse(text, out var parsedBool))
                        return parsedBool;
                    if (int.TryParse(text, out var parsedInt))
                        return parsedInt != 0;

                    return string.Equals(text, "yes", StringComparison.OrdinalIgnoreCase)
                        || string.Equals(text, "y", StringComparison.OrdinalIgnoreCase)
                        || string.Equals(text, "on", StringComparison.OrdinalIgnoreCase);
                }
                catch
                {
                    return false;
                }
            }

            try
            {
                if (dgv.Columns.Contains("For Delivery"))
                    return ParseBoolValue(dgv.Rows[rowIndex].Cells["For Delivery"].Value);
            }
            catch { }

            try
            {
                var dt = dgv.DataSource as DataTable;
                if (dt != null && dt.Rows.Count > rowIndex && dt.Columns.Contains("For Delivery"))
                    return ParseBoolValue(dt.Rows[rowIndex]["For Delivery"]);
            }
            catch { }

            try
            {
                string orderId = GetOrderIdForRow(rowIndex);
                if (!string.IsNullOrWhiteSpace(orderId))
                {
                    using var conn = new SqlConnection(connectionString);
                    conn.Open();
                    using var cmd = new SqlCommand("SELECT TOP 1 ISNULL([For Delivery], 0) FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", conn);
                    cmd.Parameters.AddWithValue("@OrderID", orderId);
                    return ParseBoolValue(cmd.ExecuteScalar());
                }
            }
            catch { }

            return false;
        }

        private string GetStatusForRow(int rowIndex)
        {
            if (rowIndex < 0 || rowIndex >= dgv.Rows.Count)
                return string.Empty;

            try
            {
                string status = string.Empty;
                if (dgv.Columns.Contains("Status"))
                    status = dgv.Rows[rowIndex].Cells["Status"].Value?.ToString() ?? string.Empty;

                if (string.IsNullOrWhiteSpace(status))
                {
                    var dt = dgv.DataSource as DataTable;
                    if (dt != null && dt.Rows.Count > rowIndex && dt.Columns.Contains("Status"))
                        status = dt.Rows[rowIndex]["Status"]?.ToString() ?? string.Empty;
                }

                return status?.Trim() ?? string.Empty;
            }
            catch
            {
                return string.Empty;
            }
        }

        private void UpdateProductionDoneButtonVisibility()
        {
            try
            {
                if (_showNonCurrentLocationsOnly || productionDoneButton == null)
                    return;

                bool isProductionWarehouse = false;
                try
                {
                    var currentWarehouseIds = TryGetCurrentWarehouseIds();
                    isProductionWarehouse = currentWarehouseIds != null
                        && currentWarehouseIds.Count > 0
                        && TryIsProductionWarehouseSelected(currentWarehouseIds);
                }
                catch
                {
                    isProductionWarehouse = false;
                }

                productionDoneButton.Visible = isProductionWarehouse;
                productionDoneButton.Text = ShouldUseShippedButtonText() ? "Shipped" : "Production Done";
            }
            catch { }
        }

        private bool ShouldUseShippedButtonText()
        {
            try
            {
                if (dgv?.CurrentRow == null)
                    return false;

                return string.Equals(GetStatusForRow(dgv.CurrentRow.Index), "To Ship", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private void Dgv_SelectionChanged(object? sender, EventArgs e)
        {
            try
            {
                UpdateProductionDoneButtonVisibility();
                UpdateToShipButtonVisibility();
            }
            catch { }
        }

        private void UpdateToShipButtonVisibility()
        {
            try
            {
                if (_showNonCurrentLocationsOnly || toShipButton == null)
                    return;

                bool hasCurrentWarehouse = false;
                bool isProductionWarehouse = false;

                try
                {
                    var currentWarehouseIds = TryGetCurrentWarehouseIds();
                    hasCurrentWarehouse = currentWarehouseIds != null && currentWarehouseIds.Count > 0;
                    isProductionWarehouse = hasCurrentWarehouse && currentWarehouseIds != null && TryIsProductionWarehouseSelected(currentWarehouseIds);
                }
                catch
                {
                    hasCurrentWarehouse = false;
                    isProductionWarehouse = false;
                }

                toShipButton.Visible = hasCurrentWarehouse && !isProductionWarehouse;
                toShipButton.Text = ShouldUseShippedButtonText() ? "Shipped" : "To Ship";
            }
            catch { }
        }

        private bool IsCurrentWarehouseProduction()
        {
            try
            {
                var currentWarehouseIds = TryGetCurrentWarehouseIds();
                return currentWarehouseIds != null
                    && currentWarehouseIds.Count > 0
                    && TryIsProductionWarehouseSelected(currentWarehouseIds);
            }
            catch
            {
                return false;
            }
        }

        private void UpdateDeliveryButtonsVisibility()
        {
            try
            {
                if (!_showNonCurrentLocationsOnly)
                    return;

                bool isProductionWarehouse = IsCurrentWarehouseProduction();

                if (forDeliveryButton != null)
                    forDeliveryButton.Visible = isProductionWarehouse;

                if (receiveOrderButton != null)
                    receiveOrderButton.Visible = !isProductionWarehouse;
            }
            catch { }
        }

        private bool IsAdviseBlockedStatusForRow(int rowIndex)
        {
            if (rowIndex < 0 || rowIndex >= dgv.Rows.Count)
                return true;

            try
            {
                string status = string.Empty;
                if (dgv.Columns.Contains("Status"))
                    status = dgv.Rows[rowIndex].Cells["Status"].Value?.ToString() ?? string.Empty;

                if (string.IsNullOrWhiteSpace(status))
                {
                    var dt = dgv.DataSource as DataTable;
                    if (dt != null && dt.Rows.Count > rowIndex && dt.Columns.Contains("Status"))
                        status = dt.Rows[rowIndex]["Status"]?.ToString() ?? string.Empty;
                }

                return string.Equals(status?.Trim(), "Confirmed", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status?.Trim(), "cancel", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status?.Trim(), "canceled", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status?.Trim(), "cancelled", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return true;
            }
        }

        private async Task<bool> MarkRowAsToShipAsync(int rowIndex, bool promptToUpdateCustomer = true, bool sendCustomerUpdate = false, bool setAssemblyPrepared = false)
        {
            if (rowIndex < 0 || rowIndex >= dgv.Rows.Count) return false;

            if (!IsPrintedStatusForRow(rowIndex))
            {
                try { MessageBox.Show("Update not allowed status is not \"printed\"", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                return false;
            }

            if (!CanManuallyChangeStatusForRow(rowIndex, out var locationMessage))
            {
                try { MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                return false;
            }

            try
            {
                if (dgv.Columns.Contains("Status") && string.Equals(dgv.Rows[rowIndex].Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                {
                    MessageBox.Show("New orders cannot be shipped. Please ask Sales team to confirm order before shipping out. Thank you.", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return false;
                }
            }
            catch { }

            string orderId = GetOrderIdForRow(rowIndex);
            if (string.IsNullOrWhiteSpace(orderId)) return false;

            if (!setAssemblyPrepared && !PrepareSetAssemblyForOrder(orderId, "To Ship"))
            {
                return false;
            }

            if (!await EnsureOrderSerialTrackingAsync(orderId, "To Ship").ConfigureAwait(false))
            {
                return false;
            }

            await ChangeOrderStatusAsync(rowIndex, orderId, "To Ship").ConfigureAwait(false);

            try
            {
                if (promptToUpdateCustomer)
                {
                    var confirm = MessageBox.Show("Order complete? Do you want to update the customer?", "Confirm", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                    if (confirm == DialogResult.Yes)
                    {
                        await SendUpdateToCustomerForRowAsync(rowIndex).ConfigureAwait(false);
                    }
                }
                else if (sendCustomerUpdate)
                {
                    await SendUpdateToCustomerForRowAsync(rowIndex).ConfigureAwait(false);
                }
            }
            catch { }

            return true;
        }

        private async void ToShipButton_Click(object? sender, EventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted(toShipButton?.Text ?? "To Ship")) return;
                if (dgv.CurrentRow == null) return;

                int idx = dgv.CurrentRow.Index;
                string currentStatus = GetStatusForRow(idx);
                if (string.Equals(currentStatus, "To Ship", StringComparison.OrdinalIgnoreCase))
                {
                    if (!CanManuallyChangeStatusForRow(idx, out var shippedMessage))
                    {
                        try { MessageBox.Show(shippedMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                        return;
                    }

                    string orderId = GetOrderIdForRow(idx);
                    if (string.IsNullOrWhiteSpace(orderId)) return;

                    try
                    {
                        var confirmShip = MessageBox.Show("Mark this order as shipped?", "Shipped", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                        if (confirmShip != DialogResult.Yes)
                            return;
                    }
                    catch { }

                    await ChangeOrderStatusAsync(idx, orderId, "Shipped").ConfigureAwait(false);
                    return;
                }

                await MarkRowAsToShipAsync(idx).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Failed to update order status: {ex.Message}", toShipButton?.Text ?? "To Ship", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private async Task<bool> MarkRowAsPendingTransferAsync(int rowIndex, bool sendCustomerUpdate = true)
        {
            if (rowIndex < 0 || rowIndex >= dgv.Rows.Count) return false;

            try
            {
                if (dgv.Columns.Contains("Status") && string.Equals(dgv.Rows[rowIndex].Cells["Status"].Value?.ToString(), "new", StringComparison.OrdinalIgnoreCase))
                {
                    MessageBox.Show("New orders cannot be shipped. Please ask Sales team to confirm order before shipping out. Thank you.", "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return false;
                }
            }
            catch { }

            string orderId = GetOrderIdForRow(rowIndex);
            if (string.IsNullOrWhiteSpace(orderId)) return false;

            await ChangeOrderStatusAsync(rowIndex, orderId, "Pending Transfer").ConfigureAwait(false);

            try
            {
                if (sendCustomerUpdate)
                {
                    await SendUpdateToCustomerForRowAsync(rowIndex, GlobalSettings.ScheduledTransferReadyMessage).ConfigureAwait(false);
                }
            }
            catch { }

            return true;
        }

        // Click handler for the right-side Lines button
        private async void LinesButton_Click(object? sender, EventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted("Lines")) return;
                if (dgv.CurrentRow == null) return;
                int idx = dgv.CurrentRow.Index;
                await OpenOrderLinesForRowAsync(idx).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error opening order lines: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // Click handler for Pay button - push the selected online order into POS tables
        private void PayButton_Click(object? sender, EventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted("PAY")) return;
                if (dgv.CurrentRow == null)
                {
                    MessageBox.Show("Please select an order to pay/post.", "No Order Selected", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                // Prevent initiating a payment while an automatic or global online sync is running
                try
                {
                    if (_isAutoSyncRunning)
                    {
                        MessageBox.Show("Cannot post payment while orders are syncing. Please wait for sync to finish.", "Sync In Progress", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }

                    // If MainForm is performing an online sync, block payments too (use reflection to read private flag)
                    MainForm? mainForm = null;
                    foreach (Form f in Application.OpenForms)
                    {
                        if (f is MainForm mf) { mainForm = mf; break; }
                    }
                    if (mainForm != null)
                    {
                        var fi = mainForm.GetType().GetField("_isOnlineSyncRunning", BindingFlags.Instance | BindingFlags.NonPublic);
                        if (fi != null)
                        {
                            var val = fi.GetValue(mainForm);
                            if (val is bool b && b)
                            {
                                MessageBox.Show("Cannot post payment while the system is syncing online orders. Please try again later.", "Sync In Progress", MessageBoxButtons.OK, MessageBoxIcon.Information);
                                return;
                            }
                        }
                    }
                }
                catch { }

                string orderId = GetOrderIdForRow(dgv.CurrentRow.Index);
                // Only allow posting to POS when the upstream order is Confirmed
                try
                {
                    string status = string.Empty;
                    if (dgv.Columns.Contains("Status"))
                        status = dgv.CurrentRow.Cells["Status"].Value?.ToString() ?? string.Empty;
                    else
                    {
                        var dt = dgv.DataSource as DataTable;
                        if (dt != null && dt.Rows.Count > dgv.CurrentRow.Index && dt.Columns.Contains("Status"))
                            status = dt.Rows[dgv.CurrentRow.Index]["Status"]?.ToString() ?? string.Empty;
                    }

                    var sTrim = status?.Trim();
                    if (!string.Equals(sTrim, "Confirmed", StringComparison.OrdinalIgnoreCase)
                        && !string.Equals(sTrim, "Printed", StringComparison.OrdinalIgnoreCase)
                        && !string.Equals(sTrim, "To Ship", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show("Only orders with status 'Confirmed', 'Printed' or 'To Ship' can be paid/posted to POS. Please confirm, print or mark the order to ship first.", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                catch { }
                if (string.IsNullOrWhiteSpace(orderId))
                {
                    MessageBox.Show("Selected row does not contain a valid OrderID.", "Invalid Order", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                // Ask user for tender type(s) and amount(s) until the full balance is covered
                string selectedTenderCode = "CASH";
                var splitPayments = new System.Collections.Generic.List<(string tenderCode, decimal amount)>();
                try
                {
                    var tenderList = new System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<string, string>>();
                    try
                    {
                        using var conn = new SqlConnection(connectionString);
                        conn.Open();
                        using var cmd = new SqlCommand("SELECT Code, Description FROM TenderTypes ORDER BY Code", conn);
                        using var rdr = cmd.ExecuteReader();
                        while (rdr.Read())
                        {
                            string code = System.Convert.ToString(rdr["Code"]) ?? string.Empty;
                            string? desc = System.Convert.ToString(rdr["Description"]);
                            if (string.IsNullOrWhiteSpace(desc)) desc = code;
                            // Skip unwanted option "Advance Orders" shown in some DBs
                            if (string.Equals((desc ?? string.Empty).Trim(), "Advance Orders", StringComparison.OrdinalIgnoreCase)) continue;
                            if (!string.IsNullOrWhiteSpace(code)) tenderList.Add(new System.Collections.Generic.KeyValuePair<string, string>(code, desc ?? string.Empty));
                        }
                    }
                    catch { }

                    if (tenderList.Count == 0)
                    {
                        tenderList.Add(new System.Collections.Generic.KeyValuePair<string, string>("CASH", "Cash"));
                        tenderList.Add(new System.Collections.Generic.KeyValuePair<string, string>("CREDIT", "Credit Card"));
                        tenderList.Add(new System.Collections.Generic.KeyValuePair<string, string>("DEBIT", "Debit Card"));
                        tenderList.Add(new System.Collections.Generic.KeyValuePair<string, string>("BANK", "Bank Transfer"));
                    }

                    // Determine outstanding balance
                    decimal balance = 0m;
                    bool hasGridBalance = false;
                    try
                    {
                        if (dgv.CurrentRow != null)
                        {
                            // Prefer reading from the bound DataRowView (handles sorting/filtering)
                            try
                            {
                                if (dgv.CurrentRow.DataBoundItem is DataRowView drv)
                                {
                                    if (drv.Row.Table.Columns.Contains("Balance"))
                                    {
                                        var bval = drv["Balance"];
                                        if (bval != DBNull.Value && bval != null)
                                        {
                                            balance = Convert.ToDecimal(bval);
                                            hasGridBalance = true;
                                        }
                                    }
                                }
                            }
                            catch { }

                            // Fallback to using the DataTable by row index if not bound or DataRowView not available
                            if (!hasGridBalance)
                            {
                                var dt = dgv.DataSource as DataTable;
                                if (dt != null)
                                {
                                    int idx = dgv.CurrentRow.Index;
                                    if (dt.Rows.Count > idx && dt.Columns.Contains("Balance"))
                                    {
                                        var bval = dt.Rows[idx]["Balance"];
                                        if (bval != DBNull.Value && bval != null)
                                        {
                                            balance = Convert.ToDecimal(bval);
                                            hasGridBalance = true;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    catch { balance = 0m; }

                    if (hasGridBalance)
                    {
                        // If the grid shows zero or negative balance, do not allow PAY
                        if (balance <= 0m)
                        {
                            MessageBox.Show("Selected order has no outstanding balance to pay.", "Nothing To Pay", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            return;
                        }
                    }
                    else
                    {
                        // Fallback: no balance value in the grid, look it up in the DB
                        try
                        {
                            using var conn2 = new SqlConnection(connectionString);
                            conn2.Open();
                            using var cmd2 = new SqlCommand("SELECT Balance FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", conn2);
                            cmd2.Parameters.AddWithValue("@OrderID", orderId);
                            var obj = cmd2.ExecuteScalar();
                            if (obj != null && obj != DBNull.Value) balance = Convert.ToDecimal(obj);
                        }
                        catch { balance = 0m; }

                        if (balance <= 0m)
                        {
                            MessageBox.Show("Selected order has no outstanding balance to pay.", "Nothing To Pay", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            return;
                        }
                    }

                    decimal remaining = balance;
                    string lastTenderCode = selectedTenderCode;

                    while (remaining > 0m)
                    {
                        using var dlg = new Form
                        {
                            Text = "Enter Tender Amount",
                            StartPosition = FormStartPosition.CenterParent,
                            ClientSize = new Size(600, 320),
                            FormBorderStyle = FormBorderStyle.FixedDialog,
                            MaximizeBox = false,
                            MinimizeBox = false
                        };

                        var lblRemaining = new Label
                        {
                            AutoSize = false,
                            Location = new Point(16, 16),
                            Size = new Size(560, 30),
                            Text = $"Remaining balance: {remaining:N2}",
                            Font = new Font(this.Font.FontFamily, 12f, FontStyle.Bold)
                        };

                        var cmb = new ComboBox
                        {
                            Location = new Point(16, 56),
                            Size = new Size(560, 44),
                            DropDownStyle = ComboBoxStyle.DropDownList,
                            DrawMode = DrawMode.OwnerDrawFixed
                        };
                        cmb.DisplayMember = "Value";
                        cmb.ValueMember = "Key";
                        cmb.DataSource = new BindingSource(tenderList, null);

                        // Make items larger and render the selected item bold and bigger
                        try
                        {
                            cmb.ItemHeight = (int)Math.Ceiling(this.Font.Height * 3.0);
                            try { cmb.DropDownHeight = Math.Max(cmb.ItemHeight * Math.Min(6, tenderList.Count), cmb.ItemHeight * 2); } catch { }
                            cmb.DrawItem += (s, e) =>
                            {
                                try
                                {
                                    e.DrawBackground();
                                    var cbSender = s as ComboBox;
                                    if (cbSender == null) return;
                                    var g = e.Graphics;
                                    object? itemObj = null;
                                    if (e.Index >= 0)
                                        itemObj = cbSender.Items[e.Index];
                                    else
                                        itemObj = cbSender.SelectedItem;

                                    string text = string.Empty;
                                    if (itemObj is System.Collections.Generic.KeyValuePair<string, string> kv)
                                        text = kv.Value ?? string.Empty;
                                    else
                                        text = itemObj?.ToString() ?? string.Empty;

                                    bool isSelected = (e.State & DrawItemState.Selected) == DrawItemState.Selected;
                                    float baseSize = Math.Max(10f, this.Font.Size);
                                    using (var f = new Font(this.Font.FontFamily, isSelected ? baseSize * 1.8f : baseSize * 1.3f, isSelected ? FontStyle.Bold : FontStyle.Regular))
                                    using (var br = new SolidBrush(isSelected ? SystemColors.HighlightText : SystemColors.ControlText))
                                    {
                                        var rect = e.Bounds;
                                        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
                                        g.DrawString(text, f, br, rect.Left + 8, rect.Top + (rect.Height - f.Height) / 2);
                                    }

                                    e.DrawFocusRectangle();
                                }
                                catch { }
                            };
                        }
                        catch { }

                        // Preselect last tender if present
                        try
                        {
                            for (int i = 0; i < cmb.Items.Count; i++)
                            {
                                if (cmb.Items[i] is System.Collections.Generic.KeyValuePair<string, string> kv && string.Equals(kv.Key, lastTenderCode, StringComparison.OrdinalIgnoreCase))
                                {
                                    cmb.SelectedIndex = i;
                                    break;
                                }
                            }
                        }
                        catch { }

                        // Layout below controls based on actual combo box height to avoid overlap
                        int amountRowY = cmb.Bottom + 14;

                        var lblAmount = new Label
                        {
                            AutoSize = false,
                            Location = new Point(16, amountRowY),
                            Size = new Size(200, 28),
                            Text = "Amount:",
                            Font = new Font(this.Font.FontFamily, 11f, FontStyle.Bold)
                        };

                        var nudAmount = new NumericUpDown
                        {
                            Location = new Point(220, amountRowY - 4),
                            Size = new Size(180, 34),
                            DecimalPlaces = 2,
                            Minimum = 0.01m,
                            Maximum = remaining,
                            Value = remaining,
                            Increment = 1m
                        };
                        try { nudAmount.Increment = 0.50m; } catch { }

                        // Ensure the dialog is tall enough for the amount row and buttons
                        int buttonsRowY = nudAmount.Bottom + 22;
                        int neededClientHeight = buttonsRowY + 44 + 16;
                        if (dlg.ClientSize.Height < neededClientHeight)
                        {
                            dlg.ClientSize = new Size(dlg.ClientSize.Width, neededClientHeight);
                        }

                        var btnOk = new Button { Text = "OK", DialogResult = DialogResult.OK, Size = new Size(110, 44) };
                        var btnCancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Size = new Size(110, 44) };
                        try
                        {
                            int totalButtonsWidth = btnOk.Width + 16 + btnCancel.Width;
                            int startX = Math.Max(16, (dlg.ClientSize.Width - totalButtonsWidth) / 2);
                            int btnY = buttonsRowY;
                            btnOk.Location = new Point(startX, btnY);
                            btnCancel.Location = new Point(startX + btnOk.Width + 16, btnY);
                        }
                        catch
                        {
                            btnOk.Location = new Point(280, 220);
                            btnCancel.Location = new Point(400, 220);
                        }

                        dlg.Controls.AddRange(new Control[] { lblRemaining, cmb, lblAmount, nudAmount, btnOk, btnCancel });
                        dlg.AcceptButton = btnOk;
                        dlg.CancelButton = btnCancel;

                        if (dlg.ShowDialog(this) != DialogResult.OK)
                        {
                            return; // user cancelled, do not post anything
                        }

                        string tender = lastTenderCode;
                        try
                        {
                            if (cmb.SelectedItem is System.Collections.Generic.KeyValuePair<string, string> kv)
                                tender = kv.Key;
                        }
                        catch { }

                        decimal amt = 0m;
                        try { amt = nudAmount.Value; } catch { amt = 0m; }
                        if (amt <= 0m)
                        {
                            MessageBox.Show("Amount must be greater than zero.", "Invalid Amount", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                            continue;
                        }
                        if (amt > remaining) amt = remaining;

                        splitPayments.Add((tender, amt));
                        lastTenderCode = tender;
                        remaining -= amt;
                        if (remaining < 0m) remaining = 0m;
                    }

                    // use the last tender selected as the primary tender code parameter
                    selectedTenderCode = string.IsNullOrWhiteSpace(lastTenderCode) ? selectedTenderCode : lastTenderCode;
                }
                catch { }

                // Disable UI while processing
                try { this.Invoke(new Action(() => { payButton.Enabled = false; statusLabel.Text = "Posting to POS..."; progressBar.Visible = true; Cursor.Current = Cursors.WaitCursor; })); } catch { }

                // Run push operation on background thread to avoid blocking UI
                System.Threading.Tasks.Task.Run(() =>
                {
                    try
                    {
                        // Best-effort: fetch upstream order JSON and capture data.bank_payments so we can preserve online payments
                        try
                        {
                            try
                            {
                                var baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
                                var apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
                                var shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
                                if (!string.IsNullOrWhiteSpace(baseUrl) && !string.IsNullOrWhiteSpace(apiKey) && !string.IsNullOrWhiteSpace(shopId))
                                {
                                    var url = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders/{Uri.EscapeDataString(orderId)}?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000";
                                    using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(30) };
                                    using var resp = http.GetAsync(url).GetAwaiter().GetResult();
                                    if (resp.IsSuccessStatusCode)
                                    {
                                        var body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                                        try
                                        {
                                            var doc = System.Text.Json.JsonDocument.Parse(body);
                                            var root = doc.RootElement;
                                            System.Text.Json.JsonElement dataEl;
                                            bool hasData = false;
                                            if (root.ValueKind == System.Text.Json.JsonValueKind.Object && root.TryGetProperty("data", out dataEl)) hasData = true;
                                            else if (root.ValueKind == System.Text.Json.JsonValueKind.Object && root.TryGetProperty("order", out dataEl)) hasData = true; // fallback
                                            else dataEl = root;

                                            if (hasData && dataEl.ValueKind == System.Text.Json.JsonValueKind.Object && dataEl.TryGetProperty("bank_payments", out var bpEl))
                                            {
                                                var bpJson = bpEl.GetRawText();

                                                try
                                                {
                                                    // Parse existing bank_payments JSON into a dictionary keyed by POS bank id
                                                    var mergedBankPayments = new System.Collections.Generic.Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
                                                    try
                                                    {
                                                        if (!string.IsNullOrWhiteSpace(bpJson))
                                                        {
                                                            using var bpDoc = System.Text.Json.JsonDocument.Parse(bpJson);
                                                            var bpRoot = bpDoc.RootElement;
                                                            if (bpRoot.ValueKind == System.Text.Json.JsonValueKind.Object)
                                                            {
                                                                foreach (var prop in bpRoot.EnumerateObject())
                                                                {
                                                                    try
                                                                    {
                                                                        decimal val = 0m;
                                                                        if (prop.Value.ValueKind == System.Text.Json.JsonValueKind.Number && prop.Value.TryGetDecimal(out var dv))
                                                                        {
                                                                            val = dv;
                                                                        }
                                                                        else if (prop.Value.ValueKind == System.Text.Json.JsonValueKind.String)
                                                                        {
                                                                            if (!decimal.TryParse(prop.Value.GetString(), out val)) val = 0m;
                                                                        }

                                                                        if (val != 0m)
                                                                        {
                                                                            mergedBankPayments[prop.Name] = val;
                                                                        }
                                                                    }
                                                                    catch { }
                                                                }
                                                            }
                                                        }
                                                    }
                                                    catch { }

                                                    // Determine the payments we just took in POS (split payments or single tender/balance)
                                                    var paymentsForBank = new System.Collections.Generic.List<(string tenderCode, decimal amount)>();
                                                    decimal cashAmount = 0m;
                                                    try
                                                    {
                                                        if (splitPayments != null && splitPayments.Count > 0)
                                                        {
                                                            foreach (var p in splitPayments)
                                                            {
                                                                if (!string.IsNullOrWhiteSpace(p.tenderCode) && p.amount > 0m)
                                                                {
                                                                    if (string.Equals(p.tenderCode, "CASH", StringComparison.OrdinalIgnoreCase))
                                                                        cashAmount += p.amount;
                                                                    paymentsForBank.Add((p.tenderCode, p.amount));
                                                                }
                                                            }
                                                        }
                                                        else
                                                        {
                                                            // No split payments captured; best-effort fallback to full Balance with the selected tender
                                                            decimal balForBank = 0m;
                                                            try
                                                            {
                                                                using var connB = new SqlConnection(connectionString);
                                                                connB.Open();
                                                                using var cmdB = new SqlCommand("SELECT Balance FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", connB);
                                                                cmdB.Parameters.AddWithValue("@OrderID", orderId);
                                                                var objB = cmdB.ExecuteScalar();
                                                                if (objB != null && objB != DBNull.Value) balForBank = Convert.ToDecimal(objB);
                                                            }
                                                            catch { balForBank = 0m; }

                                                            if (balForBank > 0m && !string.IsNullOrWhiteSpace(selectedTenderCode))
                                                            {
                                                                if (string.Equals(selectedTenderCode, "CASH", StringComparison.OrdinalIgnoreCase))
                                                                    cashAmount += balForBank;
                                                                paymentsForBank.Add((selectedTenderCode, balForBank));
                                                            }
                                                        }
                                                    }
                                                    catch { }

                                                    if (paymentsForBank.Count > 0)
                                                    {
                                                        // Map tender codes to POSBankID from TenderTypes
                                                        var tenderBankMap = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                                                        try
                                                        {
                                                            using var connT = new SqlConnection(connectionString);
                                                            connT.Open();
                                                            using var cmdT = new SqlCommand("SELECT Code, POSBankID FROM TenderTypes", connT);
                                                            using var rdrT = cmdT.ExecuteReader();
                                                            while (rdrT.Read())
                                                            {
                                                                var code = rdrT["Code"]?.ToString() ?? string.Empty;
                                                                var posBankId = rdrT["POSBankID"]?.ToString() ?? string.Empty;
                                                                if (!string.IsNullOrWhiteSpace(code) && !string.IsNullOrWhiteSpace(posBankId))
                                                                {
                                                                    tenderBankMap[code] = posBankId;
                                                                }
                                                            }
                                                        }
                                                        catch { }

                                                        // Merge new POS payments into the bank_payments dictionary
                                                        foreach (var p in paymentsForBank)
                                                        {
                                                            try
                                                            {
                                                                // Exclude pure cash tenders from bank_payments; they are represented via the cash field upstream
                                                                if (string.Equals(p.tenderCode, "CASH", StringComparison.OrdinalIgnoreCase))
                                                                    continue;

                                                                if (!tenderBankMap.TryGetValue(p.tenderCode, out var bankId) || string.IsNullOrWhiteSpace(bankId))
                                                                    continue;

                                                                var key = bankId.Trim();
                                                                if (string.IsNullOrEmpty(key))
                                                                    continue;

                                                                if (!mergedBankPayments.TryGetValue(key, out var existing))
                                                                    existing = 0m;

                                                                mergedBankPayments[key] = existing + p.amount;
                                                            }
                                                            catch { }
                                                        }
                                                    }

                                                    string mergedJson;
                                                    try
                                                    {
                                                        mergedJson = System.Text.Json.JsonSerializer.Serialize(mergedBankPayments);
                                                    }
                                                    catch
                                                    {
                                                        mergedJson = bpJson ?? "{}";
                                                    }

                                                    // Replace bpJson with merged bank_payments JSON so any downstream logic can use it
                                                    bpJson = mergedJson;

                                                    // Send merged bank_payments back to the cloud order via PUT
                                                    try
                                                    {
                                                        var baseUrl2 = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
                                                        var apiKey2 = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
                                                        var shopId2 = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
                                                        if (!string.IsNullOrWhiteSpace(baseUrl2) && !string.IsNullOrWhiteSpace(apiKey2) && !string.IsNullOrWhiteSpace(shopId2))
                                                        {
                                                            var putUrl = $"{baseUrl2}/shops/{Uri.EscapeDataString(shopId2)}/orders/{Uri.EscapeDataString(orderId)}?api_key={Uri.EscapeDataString(apiKey2)}";
                                                            var bankJsonForBody = string.IsNullOrWhiteSpace(bpJson) ? "{}" : bpJson;
                                                            string cashFragment = string.Empty;
                                                            try
                                                            {
                                                                if (cashAmount > 0m)
                                                                    cashFragment = ", \"cash\": " + cashAmount.ToString("F0", System.Globalization.CultureInfo.InvariantCulture);
                                                            }
                                                            catch { cashFragment = string.Empty; }

                                                            var bodyJson = "{\"bank_payments\": " + bankJsonForBody + cashFragment + "}";
                                                            using var httpPut = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(30) };
                                                            using var content = new System.Net.Http.StringContent(bodyJson, System.Text.Encoding.UTF8, "application/json");
                                                            using var putResp = httpPut.PutAsync(putUrl, content).GetAwaiter().GetResult();
                                                            var putRespBody = putResp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                                                            try { System.Diagnostics.Trace.TraceInformation($"PUT bank_payments for order {orderId}: {(int)putResp.StatusCode} {putResp.ReasonPhrase} {putRespBody}"); } catch { }
                                                        }
                                                    }
                                                    catch { }

                                                    try
                                                    {
                                                        System.Diagnostics.Trace.TraceInformation($"Merged bank_payments for order {orderId}: {bpJson}");
                                                    }
                                                    catch { }
                                                }
                                                catch { }
                                            }
                                        }
                                        catch { }
                                    }
                                }
                            }
                            catch { }
                        }
                        catch { }

                        // Do not request automatic creation of a payment entry in the main journal
                        // for online orders; we only stage the order and optionally update the cloud.
                        var result = IntegrationEvents.PushOnlineOrderToPos(orderId, receiptNo: null, type: "ADVANCEORDERS", storeNo: "001", posTerminalNo: "001", tenderCode: selectedTenderCode, createPaymentEntry: true, splitPayments: splitPayments);
                        try
                        {
                            this.Invoke(new Action(() =>
                            {
                                progressBar.Visible = false;
                                Cursor.Current = Cursors.Default;
                                payButton.Enabled = true;
                                statusLabel.Text = result.success ? "Posted to POS" : "Post failed";
                                if (result.success)
                                {
                                    // Silent success: refresh grid and close this form
                                    RefreshGridFromDb();
                                    try { this.Close(); } catch { }

                                    // After successful payment posting, log off the POS (return to login screen)
                                    try
                                    {
                                        foreach (Form f in Application.OpenForms)
                                        {
                                            if (f is MainForm mf)
                                            {
                                                mf.ForceLogoutAfterPayment();
                                                break;
                                            }
                                        }
                                    }
                                    catch { }
                                }
                                else
                                {
                                    MessageBox.Show(result.message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                                }
                            }));
                        }
                        catch { }
                    }
                    catch (Exception ex)
                    {
                        try { this.Invoke(new Action(() => { progressBar.Visible = false; payButton.Enabled = true; Cursor.Current = Cursors.Default; MessageBox.Show($"Failed to post order: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); })); } catch { }
                    }
                });
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Error starting payment/post operation: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        // Shared logic to open lines for a given row index (used by double-click and Lines button)
        private async Task OpenOrderLinesForRowAsync(int rowIndex)
        {
            try
            {
                string orderId = string.Empty;
                try
                {
                    // Strictly prefer OrderID (the persisted table uses OrderID)
                    if (dgv.Columns.Contains("OrderID"))
                    {
                        orderId = dgv.Rows[rowIndex].Cells["OrderID"].Value?.ToString() ?? string.Empty;
                    }
                    else
                    {
                        // Fallback: use first visible cell value
                        orderId = dgv.Rows[rowIndex].Cells.Count > 0 ? dgv.Rows[rowIndex].Cells[0].Value?.ToString() ?? string.Empty : string.Empty;
                    }
                }
                catch
                {
                    var dt = dgv.DataSource as DataTable;
                    if (dt != null && dt.Rows.Count > rowIndex)
                    {
                        var row = dt.Rows[rowIndex];
                        if (dt.Columns.Contains("OrderID")) orderId = row["OrderID"] as string ?? string.Empty;
                    }
                }

                if (string.IsNullOrWhiteSpace(orderId)) return;

                // Fetch lines from upstream and persist locally (non-blocking to UI)
                try
                {
                    // Notify user we're syncing lines for this order
                    try { this.Invoke(new Action(() => { statusLabel.Text = "Syncing lines..."; progressBar.Visible = true; linesButton.Enabled = false; syncButton.Enabled = false; Cursor.Current = Cursors.WaitCursor; })); } catch { }
                    await FetchAndPersistOrderLinesAsync(orderId).ConfigureAwait(false);
                    try { this.Invoke(new Action(() => { statusLabel.Text = "Lines synced"; progressBar.Visible = false; linesButton.Enabled = true; syncButton.Enabled = true; })); } catch { }
                }
                catch (Exception ex)
                {
                    // show warning but continue to open the lines form
                    try { this.Invoke(new Action(() => MessageBox.Show($"Warning: couldn't fetch/persist order lines: {ex.Message}", "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning))); } catch { }
                    try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; linesButton.Enabled = true; syncButton.Enabled = true; Cursor.Current = Cursors.Default; })); } catch { }
                }

                // Open the DB-backed form on the UI thread so it displays persisted lines
                if (this.IsHandleCreated)
                {
                    this.Invoke(new Action(() =>
                    {
                        var linesForm = new OnlineOrderLinesForm(orderId);
                        linesForm.ShowDialog(this);
                    }));
                }
            }
            catch (Exception ex)
            {
                try { this.Invoke(new Action(() => MessageBox.Show($"Error opening order lines: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error))); } catch { }
            }
        }

        private void OnlineOrdersForm_Load(object? sender, EventArgs e)
        {
            // Backfill Converted_LastUpdated_At for legacy rows where it's null
            try
            {
                using var connBack = new SqlConnection(connectionString);
                connBack.Open();
                using var upd = new SqlCommand("UPDATE dbo.OnlineOrderHeader SET Converted_LastUpdated_At = CAST(Last_Updated_At AS date) WHERE Converted_LastUpdated_At IS NULL AND Last_Updated_At IS NOT NULL", connBack);
                try { upd.ExecuteNonQuery(); } catch { }
            }
            catch { }

            RefreshGridFromDb();
            // Start a background sync when the form opens
            try { _ = DoSyncAndRefreshAsync(); } catch { }

            // // Initialize auto-sync timer to run every 10 seconds (UI thread timer)
            // try
            // {
            //     if (autoSyncTimer == null)
            //     {
            //         autoSyncTimer = new System.Windows.Forms.Timer();
            //         autoSyncTimer.Interval = 10000; // 10 seconds
            //         autoSyncTimer.Tick += AutoSyncTimer_Tick;
            //         autoSyncTimer.Start();
            //     }
            // }
            // catch { }
            // Also persist lines for the currently selected (or first) order without opening the lines dialog
            try
            {
                _ = Task.Run(async () =>
                {
                    try
                    {
                        await Task.Delay(200).ConfigureAwait(false); // allow UI binding to settle
                        int idx = -1;
                        if (this.IsHandleCreated)
                        {
                            this.Invoke(new Action(() =>
                            {
                                if (dgv.CurrentRow != null) idx = dgv.CurrentRow.Index;
                                else if (dgv.Rows.Count > 0) idx = 0;
                            }));
                        }

                        if (idx >= 0)
                        {
                            string orderId = string.Empty;
                            try
                            {
                                if (this.IsHandleCreated)
                                {
                                    this.Invoke(new Action(() =>
                                    {
                                        try
                                        {
                                            if (dgv.Columns.Contains("OrderID"))
                                                orderId = dgv.Rows[idx].Cells["OrderID"].Value?.ToString() ?? string.Empty;
                                            else if (dgv.Rows[idx].Cells.Count > 0)
                                                orderId = dgv.Rows[idx].Cells[0].Value?.ToString() ?? string.Empty;
                                        }
                                        catch { }
                                    }));
                                }
                            }
                            catch { }

                            if (string.IsNullOrWhiteSpace(orderId))
                            {
                                try
                                {
                                    var dt = dgv.DataSource as DataTable;
                                    if (dt != null && dt.Rows.Count > idx && dt.Columns.Contains("OrderID"))
                                        orderId = dt.Rows[idx]["OrderID"] as string ?? string.Empty;
                                }
                                catch { }
                            }

                            if (!string.IsNullOrWhiteSpace(orderId))
                            {
                                try
                                {
                                    await FetchAndPersistOrderLinesAsync(orderId).ConfigureAwait(false);
                                }
                                catch { }
                            }
                        }
                    }
                    catch { }
                });
            }
            catch { }
        }

        // Click handler for SendUpdateToCustomer button
        private async void SendUpdateToCustomer_Click(object? sender, EventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted("Advise")) return;
                if (dgv.CurrentRow == null)
                {
                    MessageBox.Show("Please select an order to send an update.", "No Order Selected", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                if (IsAdviseBlockedStatusForRow(dgv.CurrentRow.Index))
                {
                    MessageBox.Show("Update not allowed for Confirmed or canceled orders.", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                string orderId = string.Empty;
                if (dgv.CurrentRow != null)
                {
                    if (dgv.Columns.Contains("OrderID"))
                        orderId = dgv.CurrentRow.Cells["OrderID"].Value?.ToString() ?? string.Empty;
                    else if (dgv.CurrentRow.Cells.Count > 0)
                        orderId = dgv.CurrentRow.Cells[0].Value?.ToString() ?? string.Empty;
                }

                if (string.IsNullOrWhiteSpace(orderId))
                {
                    MessageBox.Show("Please select an order to send an update.", "No Order Selected", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                // Placeholder: show confirmation. Implement API call to PublicURL/PublicApiKey later.
                var confirm = MessageBox.Show($"Send update to customer for Order {orderId}?", "Confirm", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (confirm == DialogResult.Yes)
                {
                    // Show a short feedback while sending
                    try { this.Invoke(new Action(() => { statusLabel.Text = "Sending update..."; progressBar.Visible = true; linesButton.Enabled = false; sendUpdateButton.Enabled = false; })); } catch { }

                    // Retrieve Page_ID and Conversation_ID from the bound DataTable if available
                    string pageId = string.Empty;
                    string conversationId = string.Empty;
                    try
                    {
                        if (dgv.CurrentRow != null)
                        {
                            var cells = dgv.CurrentRow.Cells;
                            if (dgv.Columns.Contains("Page_ID")) pageId = cells["Page_ID"].Value?.ToString() ?? string.Empty;
                            if (dgv.Columns.Contains("Conversation_ID")) conversationId = cells["Conversation_ID"].Value?.ToString() ?? string.Empty;
                        }
                    }
                    catch { }

                    if (string.IsNullOrWhiteSpace(pageId) || string.IsNullOrWhiteSpace(conversationId))
                    {
                        try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; linesButton.Enabled = true; sendUpdateButton.Enabled = true; })); } catch { }
                        MessageBox.Show("Missing Page_ID or Conversation_ID for the selected order. Cannot send update.", "Missing Data", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                    else
                    {
                        try
                        {


                            // Use the configured pickup-ready template from GlobalSettings and inject the customer's name if available.
                            string customerName = string.Empty;
                            try
                            {
                                if (dgv.CurrentRow != null && dgv.Columns.Contains("CustomerName"))
                                {
                                    customerName = dgv.CurrentRow.Cells["CustomerName"].Value?.ToString() ?? string.Empty;
                                }
                                else
                                {
                                    var dt = dgv.DataSource as DataTable;
                                    if (dt != null && dgv.CurrentRow != null)
                                    {
                                        int idx = dgv.CurrentRow.Index;
                                        if (dt.Rows.Count > idx && dt.Columns.Contains("CustomerName"))
                                            customerName = dt.Rows[idx]["CustomerName"] as string ?? string.Empty;
                                    }
                                }
                            }
                            catch { }

                            var template = GlobalSettings.PickupReadyMessage ?? string.Empty;
                            var locationName = GetLocationNameForRow(dgv.CurrentRow?.Index ?? -1, orderId);
                            // Replace both brace and bracket variants to be safe for customer name, order id and location
                            var messageText = template
                                .Replace("{Customer Name}", customerName)
                                .Replace("[Customer Name]", customerName)
                                .Replace("{Order ID}", orderId)
                                .Replace("[Order ID]", orderId)
                                .Replace("{location}", locationName)
                                .Replace("[location]", locationName)
                                .Replace("{Location}", locationName)
                                .Replace("[Location]", locationName);

                            // If the template contains a {Payment} placeholder, replace it with a payment instruction
                            // when the order has an outstanding balance. We prefer reading the Balance from the
                            // bound DataTable row for the current order; if not available, query the header table.
                            try
                            {
                                bool hasPaymentPlaceholder = messageText.Contains("{Payment}") || messageText.Contains("[Payment]");
                                if (hasPaymentPlaceholder)
                                {
                                    decimal balance = 0m;
                                    try
                                    {
                                        // Try to read Balance from the bound DataTable first
                                        if (dgv.CurrentRow != null)
                                        {
                                            var dt = dgv.DataSource as DataTable;
                                            if (dt != null)
                                            {
                                                int idx = dgv.CurrentRow.Index;
                                                if (dt.Rows.Count > idx && dt.Columns.Contains("Balance"))
                                                {
                                                    var bval = dt.Rows[idx]["Balance"];
                                                    if (bval != DBNull.Value && bval != null) balance = Convert.ToDecimal(bval);
                                                }
                                            }
                                        }
                                    }
                                    catch { balance = 0m; }

                                    // Fallback: query the header table for the balance if we couldn't get it from the grid
                                    if (balance == 0m)
                                    {
                                        try
                                        {
                                            using var connB = new SqlConnection(connectionString);
                                            connB.Open();
                                            using var cmdB = new SqlCommand("SELECT Balance FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", connB);
                                            cmdB.Parameters.AddWithValue("@OrderID", orderId);
                                            var obj = cmdB.ExecuteScalar();
                                            if (obj != null && obj != DBNull.Value) balance = Convert.ToDecimal(obj);
                                        }
                                        catch { balance = 0m; }
                                    }

                                    if (balance > 0m)
                                    {
                                        string balFormatted = balance.ToString("N2");
                                        string paymentMsg = $"Please settle remaining balance to continue on the delivery.{Environment.NewLine}{Environment.NewLine}Balance : {balFormatted}";
                                        messageText = messageText.Replace("{Payment}", paymentMsg).Replace("[Payment]", paymentMsg);
                                    }
                                    else
                                    {
                                        // No outstanding balance; remove the placeholder
                                        messageText = messageText.Replace("{Payment}", string.Empty).Replace("[Payment]", string.Empty);
                                    }
                                }
                            }
                            catch { }

                            // Build items list from the local dbo.OnlineOrderLines table (fast local read)
                            string itemsText = string.Empty;
                            string notesText = string.Empty;
                            try
                            {
                                using var conn = new SqlConnection(connectionString);
                                conn.Open();
                                using var cmd = new SqlCommand("SELECT * FROM dbo.OnlineOrderLines WHERE OrderID=@OrderID", conn);
                                cmd.Parameters.AddWithValue("@OrderID", orderId);
                                // MessageBox.Show($"Fetching items for Order ID: {orderId}");
                                var sb = new System.Text.StringBuilder();
                                var sbNotes = new System.Text.StringBuilder();
                                using (var reader = cmd.ExecuteReader())
                                {
                                    int _lineDebugCounter = 0;
                                    while (reader.Read())
                                    {
                                        // MessageBox.Show($"Fetching items for Order ID: {orderId}");
                                        // Helper: safely get a column value by name (case-insensitive) without throwing
                                        string SafeGetString(IDataRecord rec, string fieldName)
                                        {
                                            for (int fi = 0; fi < rec.FieldCount; fi++)
                                            {
                                                if (string.Equals(rec.GetName(fi), fieldName, StringComparison.OrdinalIgnoreCase))
                                                {
                                                    if (!rec.IsDBNull(fi)) return rec.GetValue(fi)?.ToString() ?? string.Empty;
                                                    return string.Empty;
                                                }
                                            }
                                            return string.Empty;
                                        }

                                        string name = string.Empty;
                                        try
                                        {
                                            name = SafeGetString(reader, "Description");
                                        }
                                        catch { }

                                        if (string.IsNullOrWhiteSpace(name))
                                        {
                                            try { name = SafeGetString(reader, "ItemCode"); } catch { }
                                        }

                                        decimal q = 0m;
                                        try
                                        {
                                            var qStrRaw = SafeGetString(reader, "Quantity");
                                            if (!string.IsNullOrWhiteSpace(qStrRaw)) q = Convert.ToDecimal(qStrRaw);
                                        }
                                        catch { }

                                        if (string.IsNullOrWhiteSpace(name)) continue;

                                        string qStr = q % 1 == 0 ? ((long)q).ToString() : q.ToString("0.##");

                                        string noteVal = string.Empty;
                                        try { noteVal = SafeGetString(reader, "Note"); } catch { }

                                        var itemLine = string.IsNullOrWhiteSpace(noteVal) ? $"✅ {qStr} x {name}" : $"✅ {qStr} x {name} 🧾 Note : {noteVal}";

                                        if (sb.Length > 0) sb.Append(Environment.NewLine);
                                        sb.Append(itemLine);

                                        if (!string.IsNullOrWhiteSpace(noteVal))
                                        {
                                            if (sbNotes.Length > 0) sbNotes.Append(Environment.NewLine);
                                            sbNotes.Append($"{name}: {noteVal}");
                                        }
                                        // Debug: emit a trace line for each row and occasionally update the UI status
                                        try
                                        {
                                            _lineDebugCounter++;
                                            System.Diagnostics.Trace.TraceInformation($"OnlineOrdersForm: Order={orderId} Line={_lineDebugCounter} Name='{name}' Qty={q} Note='{noteVal}'");
                                            if ((_lineDebugCounter % 10) == 0)
                                            {
                                                if (this.IsHandleCreated)
                                                {
                                                    try { this.Invoke(new Action(() => { statusLabel.Text = $"Processing lines: {_lineDebugCounter}"; })); } catch { }
                                                }
                                            }
                                        }
                                        catch { }
                                    }
                                }

                                itemsText = sb.ToString();
                                notesText = sbNotes.Length > 0 ? sbNotes.ToString() : string.Empty;
                            }
                            catch { itemsText = string.Empty; }

                            // Replace {Items} placeholder if present
                            if (!string.IsNullOrWhiteSpace(itemsText))
                                messageText = messageText.Replace("{Items}", itemsText).Replace("[Items]", itemsText);
                            // Replace {Note} placeholder with per-line notes if available
                            // if (!string.IsNullOrWhiteSpace(notesText))
                            //     messageText = messageText.Replace("{Note}", notesText).Replace("[Note]", notesText);
                            bool sendSucceeded = false;
                            string respBody = string.Empty;
                            try
                            {
                                respBody = await IntegrationEvents.SendMessageToCustomer(orderId, pageId, conversationId, messageText).ConfigureAwait(false);
                                sendSucceeded = true;
                            }
                            catch
                            {
                                sendSucceeded = false;
                            }

                            // Mark Message_Update_Sent flag on local lines table depending on send result
                            try
                            {
                                using var conn2 = new SqlConnection(connectionString);
                                conn2.Open();
                                using var upCmd2 = new SqlCommand("UPDATE dbo.OnlineOrderLines SET Message_Update_Sent = @Sent WHERE OrderID = @OrderID", conn2);
                                upCmd2.Parameters.AddWithValue("@Sent", sendSucceeded ? 1 : 0);
                                upCmd2.Parameters.AddWithValue("@OrderID", orderId);
                                upCmd2.ExecuteNonQuery();
                            }
                            catch (Exception ex)
                            {
                                // Log failure to update flag but do not block the main flow
                                try { System.Diagnostics.Trace.TraceError($"Failed to update Message_Update_Sent for Order {orderId}: {ex}"); } catch { }
                            }

                            if (sendSucceeded)
                            {
                                try { this.Invoke(new Action(() => { statusLabel.Text = "Update sent"; progressBar.Visible = false; linesButton.Enabled = true; sendUpdateButton.Enabled = true; })); } catch { }
                                //try { this.Invoke(new Action(() => MessageBox.Show($"Update sent to conversation. Response: {respBody}", "Sent", MessageBoxButtons.OK, MessageBoxIcon.Information))); } catch { }
                            }
                            else
                            {
                                try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; linesButton.Enabled = true; sendUpdateButton.Enabled = true; })); } catch { }
                                //try { this.Invoke(new Action(() => MessageBox.Show($"Failed to send update to conversation. See logs for details.", "Send Failed", MessageBoxButtons.OK, MessageBoxIcon.Error))); } catch { }
                            }
                        }
                        catch (Exception ex)
                        {
                            try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; linesButton.Enabled = true; sendUpdateButton.Enabled = true; })); } catch { }
                            try { this.Invoke(new Action(() => MessageBox.Show($"Error sending update: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error))); } catch { }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error sending update: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private string GetLocationNameForRow(int rowIndex, string orderId)
        {
            string locationName = string.Empty;

            try
            {
                if (rowIndex >= 0 && rowIndex < dgv.Rows.Count && dgv.Columns.Contains("Location_Name"))
                    locationName = dgv.Rows[rowIndex].Cells["Location_Name"].Value?.ToString() ?? string.Empty;
            }
            catch { }

            try
            {
                if (string.IsNullOrWhiteSpace(locationName))
                {
                    var dt = dgv.DataSource as DataTable;
                    if (dt != null && rowIndex >= 0 && rowIndex < dt.Rows.Count && dt.Columns.Contains("Location_Name"))
                        locationName = dt.Rows[rowIndex]["Location_Name"]?.ToString() ?? string.Empty;
                }
            }
            catch { }

            try
            {
                if (string.IsNullOrWhiteSpace(locationName) && !string.IsNullOrWhiteSpace(orderId))
                {
                    using var conn = new SqlConnection(connectionString);
                    conn.Open();
                    using var cmd = new SqlCommand("SELECT TOP 1 Location_Name FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", conn);
                    cmd.Parameters.AddWithValue("@OrderID", orderId);
                    var obj = cmd.ExecuteScalar();
                    if (obj != null && obj != DBNull.Value)
                        locationName = obj.ToString() ?? string.Empty;
                }
            }
            catch { }

            return (locationName ?? string.Empty).Trim();
        }

        // Send update for a specific row index (used after status change confirmation)
        private async Task<bool> SendUpdateToCustomerForRowAsync(int rowIndex, string? templateOverride = null)
        {
            try
            {
                string orderId = string.Empty;
                if (rowIndex >= 0 && rowIndex < dgv.Rows.Count)
                {
                    if (dgv.Columns.Contains("OrderID"))
                        orderId = dgv.Rows[rowIndex].Cells["OrderID"].Value?.ToString() ?? string.Empty;
                    else if (dgv.Rows[rowIndex].Cells.Count > 0)
                        orderId = dgv.Rows[rowIndex].Cells[0].Value?.ToString() ?? string.Empty;
                }

                if (string.IsNullOrWhiteSpace(orderId)) return false;

                // Retrieve Page_ID and Conversation_ID from the bound DataTable if available
                string pageId = string.Empty;
                string conversationId = string.Empty;
                try
                {
                    var cells = dgv.Rows[rowIndex].Cells;
                    if (dgv.Columns.Contains("Page_ID")) pageId = cells["Page_ID"].Value?.ToString() ?? string.Empty;
                    if (dgv.Columns.Contains("Conversation_ID")) conversationId = cells["Conversation_ID"].Value?.ToString() ?? string.Empty;
                }
                catch { }

                if (string.IsNullOrWhiteSpace(pageId) || string.IsNullOrWhiteSpace(conversationId))
                {
                    try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; linesButton.Enabled = true; sendUpdateButton.Enabled = true; })); } catch { }
                    try { this.Invoke(new Action(() => MessageBox.Show("Missing Page_ID or Conversation_ID for the selected order. Cannot send update.", "Missing Data", MessageBoxButtons.OK, MessageBoxIcon.Warning))); } catch { }
                    return false;
                }

                // Use the configured message template from GlobalSettings and inject the customer's name if available.
                string customerName = string.Empty;
                try
                {
                    if (dgv.Rows[rowIndex] != null && dgv.Columns.Contains("CustomerName"))
                    {
                        customerName = dgv.Rows[rowIndex].Cells["CustomerName"].Value?.ToString() ?? string.Empty;
                    }
                    else
                    {
                        var dt = dgv.DataSource as DataTable;
                        if (dt != null && dt.Rows.Count > rowIndex && dt.Columns.Contains("CustomerName"))
                            customerName = dt.Rows[rowIndex]["CustomerName"] as string ?? string.Empty;
                    }
                }
                catch { }

                var template = string.IsNullOrWhiteSpace(templateOverride)
                    ? (GlobalSettings.PickupReadyMessage ?? string.Empty)
                    : templateOverride;
                var locationName = GetLocationNameForRow(rowIndex, orderId);
                var messageText = template
                    .Replace("{Customer Name}", customerName)
                    .Replace("[Customer Name]", customerName)
                    .Replace("{Order ID}", orderId)
                    .Replace("[Order ID]", orderId)
                    .Replace("{location}", locationName)
                    .Replace("[location]", locationName)
                    .Replace("{Location}", locationName)
                    .Replace("[Location]", locationName);

                // If the template contains a {Payment} placeholder, replace it with a payment instruction
                // when the order has an outstanding balance, same behavior as the main SendUpdate handler.
                try
                {
                    bool hasPaymentPlaceholder = messageText.Contains("{Payment}") || messageText.Contains("[Payment]");
                    if (hasPaymentPlaceholder)
                    {
                        decimal balance = 0m;

                        // Try to read Balance from the bound DataTable first
                        try
                        {
                            var dt = dgv.DataSource as DataTable;
                            if (dt != null && dt.Rows.Count > rowIndex && dt.Columns.Contains("Balance"))
                            {
                                var bval = dt.Rows[rowIndex]["Balance"];
                                if (bval != DBNull.Value && bval != null) balance = Convert.ToDecimal(bval);
                            }
                        }
                        catch { balance = 0m; }

                        // Fallback: query the header table for the balance if we couldn't get it from the grid
                        if (balance == 0m)
                        {
                            try
                            {
                                using var connB = new SqlConnection(connectionString);
                                connB.Open();
                                using var cmdB = new SqlCommand("SELECT Balance FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", connB);
                                cmdB.Parameters.AddWithValue("@OrderID", orderId);
                                var obj = cmdB.ExecuteScalar();
                                if (obj != null && obj != DBNull.Value) balance = Convert.ToDecimal(obj);
                            }
                            catch { balance = 0m; }
                        }

                        if (balance > 0m)
                        {
                            string balFormatted = balance.ToString("N2");
                            string paymentMsg = $"Please settle remaining balance to continue on the delivery.{Environment.NewLine}{Environment.NewLine}Balance : {balFormatted}";
                            messageText = messageText.Replace("{Payment}", paymentMsg).Replace("[Payment]", paymentMsg);
                        }
                        else
                        {
                            // No outstanding balance; remove the placeholder
                            messageText = messageText.Replace("{Payment}", string.Empty).Replace("[Payment]", string.Empty);
                        }
                    }
                }
                catch { }

                // Build items list from the local dbo.OnlineOrderLines table
                string itemsText = string.Empty;
                try
                {
                    using var conn = new SqlConnection(connectionString);
                    conn.Open();
                    using var cmd = new SqlCommand("SELECT * FROM dbo.OnlineOrderLines WHERE OrderID=@OrderID", conn);
                    cmd.Parameters.AddWithValue("@OrderID", orderId);
                    var sb = new System.Text.StringBuilder();
                    using (var reader = cmd.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            string desc = string.Empty;
                            try { desc = reader["Description"]?.ToString() ?? reader["ItemCode"]?.ToString() ?? string.Empty; } catch { }
                            string note = string.Empty;
                            try { note = reader["Note"]?.ToString() ?? string.Empty; } catch { }
                            decimal q = 0m;
                            try { if (reader["Quantity"] != DBNull.Value) q = Convert.ToDecimal(reader["Quantity"]); } catch { }
                            if (string.IsNullOrWhiteSpace(desc)) continue;
                            string qStr = q % 1 == 0 ? ((long)q).ToString() : q.ToString("0.##");
                            if (sb.Length > 0) sb.Append(Environment.NewLine);
                            if (string.IsNullOrWhiteSpace(note))
                                sb.Append($"✅ {qStr} x {desc}");
                            else
                                sb.Append($"✅ {qStr} x {desc} 🧾 Note : {note}");
                        }
                    }
                    itemsText = sb.ToString();
                }
                catch { itemsText = string.Empty; }

                if (!string.IsNullOrWhiteSpace(itemsText)) messageText = messageText.Replace("{Items}", itemsText).Replace("[Items]", itemsText);

                try
                {
                    var resp = await IntegrationEvents.SendMessageToCustomer(orderId, pageId, conversationId, messageText).ConfigureAwait(false);
                    try { this.Invoke(new Action(() => { statusLabel.Text = "Update sent"; progressBar.Visible = false; linesButton.Enabled = true; sendUpdateButton.Enabled = true; })); } catch { }
                    return true;
                }
                catch (Exception ex)
                {
                    try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; linesButton.Enabled = true; sendUpdateButton.Enabled = true; })); } catch { }
                    try { this.Invoke(new Action(() => MessageBox.Show($"Failed to send update to customer: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error))); } catch { }
                    return false;
                }
            }
            catch { }

            return false;
        }

        // Notify customer that their order was printed with a short message
        private async Task NotifyCustomerOrderPrintedAsync(string orderId, int rowIndex = -1)
        {
            if (string.IsNullOrWhiteSpace(orderId)) return;

            string pageId = string.Empty;
            string conversationId = string.Empty;

            try
            {
                if (rowIndex >= 0 && rowIndex < dgv.Rows.Count)
                {
                    try
                    {
                        if (dgv.Columns.Contains("Page_ID")) pageId = dgv.Rows[rowIndex].Cells["Page_ID"].Value?.ToString() ?? string.Empty;
                        if (dgv.Columns.Contains("Conversation_ID")) conversationId = dgv.Rows[rowIndex].Cells["Conversation_ID"].Value?.ToString() ?? string.Empty;
                    }
                    catch { }
                }
            }
            catch { }

            // If not available in grid, query the header table
            if (string.IsNullOrWhiteSpace(pageId) || string.IsNullOrWhiteSpace(conversationId))
            {
                try
                {
                    using var conn = new SqlConnection(connectionString);
                    conn.Open();
                    using var cmd = new SqlCommand("SELECT TOP 1 Page_ID, Conversation_ID FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", conn);
                    cmd.Parameters.AddWithValue("@OrderID", orderId);
                    using var rdr = cmd.ExecuteReader();
                    if (rdr.Read())
                    {
                        try { if (!rdr.IsDBNull(rdr.GetOrdinal("Page_ID"))) pageId = rdr["Page_ID"]?.ToString() ?? string.Empty; } catch { }
                        try { if (!rdr.IsDBNull(rdr.GetOrdinal("Conversation_ID"))) conversationId = rdr["Conversation_ID"]?.ToString() ?? string.Empty; } catch { }
                    }
                }
                catch { }
            }

            if (string.IsNullOrWhiteSpace(pageId) || string.IsNullOrWhiteSpace(conversationId)) return;

            // Build per-line Description + Note list from local lines table and inject before the closing line
            string itemsListText = string.Empty;
            try
            {
                var sbLines = new System.Text.StringBuilder();
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT Description, Note FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID ORDER BY LineID", conn);
                cmd.Parameters.AddWithValue("@OrderID", orderId);
                using var rdr = cmd.ExecuteReader();
                bool any = false;
                while (rdr.Read())
                {
                    string desc = string.Empty;
                    string note = string.Empty;
                    try { desc = rdr["Description"]?.ToString() ?? string.Empty; } catch { }
                    try { note = rdr["Note"]?.ToString() ?? string.Empty; } catch { }
                    if (string.IsNullOrWhiteSpace(desc) && string.IsNullOrWhiteSpace(note)) continue;
                    if (sbLines.Length > 0) sbLines.Append(Environment.NewLine);
                    // Format each line as: Description + Note
                    if (string.IsNullOrWhiteSpace(note)) sbLines.Append($"Description: {desc}");
                    else sbLines.Append($"Description: {desc} | Note: {note}");
                    any = true;
                }

                if (any) itemsListText = sbLines.ToString();
            }
            catch { itemsListText = string.Empty; }

            // Compose final message. Insert items list (if any) before the closing friendly line.
            var sb = new System.Text.StringBuilder();
            sb.Append($"Your order {orderId} is printed the processing of your items will start very soon. we will keep you updated. Any urgent matters you can call our shop or drop us message here.");
            if (!string.IsNullOrWhiteSpace(itemsListText))
            {
                sb.Append(Environment.NewLine);
                sb.Append(Environment.NewLine);
                sb.Append(itemsListText);
            }
            sb.Append(Environment.NewLine);
            sb.Append(Environment.NewLine);
            sb.Append("Happy fish keeping 🐟 😊");

            string messageText = sb.ToString();

            try
            {
                await IntegrationEvents.SendMessageToCustomer(orderId, pageId, conversationId, messageText).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                try { System.Diagnostics.Trace.TraceError($"NotifyCustomerOrderPrintedAsync failed for {orderId}: {ex}"); } catch { }
            }
        }

        // Load persisted rows from dbo.OnlineOrderHeader and bind to grid.
        // By default we load the latest 500 rows for responsiveness.
        // When an OrderID or customer-name search is supplied, query matching rows directly so older orders can still be found.
        private void RefreshGridFromDb(string? orderIdSearch = null, string? customerNameSearch = null)
        {
            try
            {
                UpdateProductionDoneButtonVisibility();
                UpdateToShipButtonVisibility();
                UpdateDeliveryButtonsVisibility();
                UpdateDeliveryButtonsVisibility();

                bool isProductionWarehouseForDelivery = _showNonCurrentLocationsOnly && IsCurrentWarehouseProduction();

                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    try
                    {
                        using var ensureCmd = new SqlCommand(@"
IF COL_LENGTH('dbo.OnlineOrderHeader', 'PrintCount') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD PrintCount INT NOT NULL CONSTRAINT DF_OnlineOrderHeader_PrintCount_Runtime DEFAULT (0)
END
IF COL_LENGTH('dbo.OnlineOrderHeader', 'For Delivery') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD [For Delivery] BIT NOT NULL CONSTRAINT DF_OnlineOrderHeader_ForDelivery_Runtime DEFAULT (0)
END
IF COL_LENGTH('dbo.OnlineOrderHeader', 'Shipping Address') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD [Shipping Address] NVARCHAR(1000) NULL
END
IF COL_LENGTH('dbo.OnlineOrderHeader', 'Estimated Delivery Date') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD [Estimated Delivery Date] DATE NULL
END
IF COL_LENGTH('dbo.OnlineOrderHeader', 'Date of Completion') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD [Date of Completion] DATE NULL
END", conn);
                        ensureCmd.ExecuteNonQuery();
                    }
                    catch { }

                    var dt = new DataTable();
                    string trimmedOrderIdSearch = (orderIdSearch ?? string.Empty).Trim();
                    string trimmedCustomerNameSearch = (customerNameSearch ?? string.Empty).Trim();
                    string previousStatusSelection = statusFilterCombo?.SelectedItem?.ToString() ?? "All";
                    bool hasExpandedSearch = !string.IsNullOrWhiteSpace(trimmedOrderIdSearch) || !string.IsNullOrWhiteSpace(trimmedCustomerNameSearch);

                    string BuildSearchWhereClause()
                    {
                        var clauses = new System.Collections.Generic.List<string>
                        {
                            "UPPER(ISNULL(Status, '')) NOT IN ('SALES', 'ADVANCEORDER', 'ADVANCEORDERS')"
                        };

                        if (!string.IsNullOrWhiteSpace(trimmedOrderIdSearch))
                            clauses.Add("CONVERT(NVARCHAR(200), OrderID) LIKE @OrderIdSearch");

                        if (!string.IsNullOrWhiteSpace(trimmedCustomerNameSearch))
                            clauses.Add("ISNULL(CustomerName, '') LIKE @CustomerNameSearch");

                        return string.Join(" AND ", clauses);
                    }

                    void AddSearchParameters(SqlCommand command)
                    {
                        if (!string.IsNullOrWhiteSpace(trimmedOrderIdSearch))
                            command.Parameters.AddWithValue("@OrderIdSearch", $"%{trimmedOrderIdSearch}%");

                        if (!string.IsNullOrWhiteSpace(trimmedCustomerNameSearch))
                            command.Parameters.AddWithValue("@CustomerNameSearch", $"%{trimmedCustomerNameSearch}%");
                    }

                    // Location_Name may not exist in older DBs; try to select it, else fall back.
                    try
                    {
                        SqlCommand cmd;
                        if (hasExpandedSearch)
                        {
                            cmd = new SqlCommand($"SELECT OrderID, Date, Time, LocationID, Location_Name, Status, CustomerName, Page_ID, Conversation_ID, MoneyToCollect, AmountPaid, Discount, Balance, ISNULL([For Delivery], 0) AS [For Delivery], [Shipping Address], [Estimated Delivery Date], [Date of Completion], ISNULL(PrintCount, 0) AS PrintCount, LastPaid_Date, LastPaid_Time, Last_Updated_At, Converted_LastUpdated_At FROM dbo.OnlineOrderHeader WHERE {BuildSearchWhereClause()} ORDER BY Converted_LastUpdated_At DESC, OrderID DESC", conn);
                            AddSearchParameters(cmd);
                        }
                        else
                        {
                            cmd = new SqlCommand("SELECT TOP 500 OrderID, Date, Time, LocationID, Location_Name, Status, CustomerName, Page_ID, Conversation_ID, MoneyToCollect, AmountPaid, Discount, Balance, ISNULL([For Delivery], 0) AS [For Delivery], [Shipping Address], [Estimated Delivery Date], [Date of Completion], ISNULL(PrintCount, 0) AS PrintCount, LastPaid_Date, LastPaid_Time, Last_Updated_At, Converted_LastUpdated_At FROM dbo.OnlineOrderHeader WHERE UPPER(ISNULL(Status, '')) NOT IN ('SALES', 'ADVANCEORDER', 'ADVANCEORDERS') ORDER BY Converted_LastUpdated_At DESC, OrderID DESC", conn);
                        }
                        var adapter = new SqlDataAdapter(cmd);
                        adapter.Fill(dt);
                    }
                    catch
                    {
                        dt.Clear();
                        SqlCommand cmd;
                        if (hasExpandedSearch)
                        {
                            cmd = new SqlCommand($"SELECT OrderID, Date, Time, LocationID, Status, CustomerName, Page_ID, Conversation_ID, MoneyToCollect, AmountPaid, Discount, Balance, ISNULL([For Delivery], 0) AS [For Delivery], [Shipping Address], [Estimated Delivery Date], [Date of Completion], ISNULL(PrintCount, 0) AS PrintCount, LastPaid_Date, LastPaid_Time, Last_Updated_At, Converted_LastUpdated_At FROM dbo.OnlineOrderHeader WHERE {BuildSearchWhereClause()} ORDER BY Converted_LastUpdated_At DESC, OrderID DESC", conn);
                            AddSearchParameters(cmd);
                        }
                        else
                        {
                            cmd = new SqlCommand("SELECT TOP 500 OrderID, Date, Time, LocationID, Status, CustomerName, Page_ID, Conversation_ID, MoneyToCollect, AmountPaid, Discount, Balance, ISNULL([For Delivery], 0) AS [For Delivery], [Shipping Address], [Estimated Delivery Date], [Date of Completion], ISNULL(PrintCount, 0) AS PrintCount, LastPaid_Date, LastPaid_Time, Last_Updated_At, Converted_LastUpdated_At FROM dbo.OnlineOrderHeader WHERE UPPER(ISNULL(Status, '')) NOT IN ('SALES', 'ADVANCEORDER', 'ADVANCEORDERS') ORDER BY Converted_LastUpdated_At DESC, OrderID DESC", conn);
                        }
                        var adapter = new SqlDataAdapter(cmd);
                        adapter.Fill(dt);
                    }

                    try
                    {
                        if (dt.Columns.Contains("Status"))
                        {
                            foreach (DataRow row in dt.Rows)
                            {
                                try
                                {
                                    var rawStatus = row["Status"]?.ToString()?.Trim() ?? string.Empty;
                                    if (string.Equals(rawStatus, "pending", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "9", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "pending_transfer", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "pending transfer", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "waiting_for_pickup", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "waiting for pickup", StringComparison.OrdinalIgnoreCase))
                                    {
                                        row["Status"] = "Pending Transfer";
                                    }
                                    else if (string.Equals(rawStatus, "12", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "wait_print", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "wait print", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "in_transit", StringComparison.OrdinalIgnoreCase)
                                        || string.Equals(rawStatus, "in-transit", StringComparison.OrdinalIgnoreCase))
                                    {
                                        row["Status"] = "In-Transit";
                                    }
                                }
                                catch { }
                            }
                        }
                    }
                    catch { }

                    ApplyLocationScopeFilter(dt);

                    // Populate status filter with distinct statuses (include 'All')
                    try
                    {
                        var statuses = new System.Collections.Generic.SortedSet<string>(StringComparer.OrdinalIgnoreCase) { "All" };
                        // Ensure common application statuses are always available in the filter
                        try { statuses.Add("To Ship"); } catch { }
                        if (_showNonCurrentLocationsOnly)
                        {
                            try { statuses.Add("Pending Transfer"); } catch { }
                            try { statuses.Add("In-Transit"); } catch { }
                            if (!isProductionWarehouseForDelivery)
                            {
                                try { statuses.Add("Received"); } catch { }
                            }
                        }
                        if (dt.Columns.Contains("Status"))
                        {
                            foreach (DataRow r in dt.Rows)
                            {
                                try { var s = r["Status"]?.ToString() ?? string.Empty; if (!string.IsNullOrWhiteSpace(s)) statuses.Add(s); } catch { }
                            }
                        }
                        try
                        {
                            if (statusFilterCombo != null)
                            {
                                statusFilterCombo.BeginInvoke(new Action(() =>
                                {
                                    statusFilterCombo.Items.Clear();
                                    if (_showNonCurrentLocationsOnly)
                                    {
                                        foreach (var statusToRemove in statuses.Where(s =>
                                            !string.Equals(s, "All", StringComparison.OrdinalIgnoreCase) &&
                                            !string.Equals(s, "Pending Transfer", StringComparison.OrdinalIgnoreCase) &&
                                            !string.Equals(s, "In-Transit", StringComparison.OrdinalIgnoreCase) &&
                                            (!string.Equals(s, "Received", StringComparison.OrdinalIgnoreCase) || isProductionWarehouseForDelivery)).ToList())
                                        {
                                            statuses.Remove(statusToRemove);
                                        }
                                    }
                                    foreach (var s in statuses) statusFilterCombo.Items.Add(s);
                                    int previousIndex = statusFilterCombo.FindStringExact(previousStatusSelection);
                                    statusFilterCombo.SelectedIndex = previousIndex >= 0 ? previousIndex : 0;
                                }));
                            }
                        }
                        catch { }
                    }
                    catch { }
                    // Create display columns for Date and Time to avoid DataGridView format errors
                    try
                    {
                        if (dt.Columns.Contains("Date") && !dt.Columns.Contains("DateDisplay"))
                        {
                            dt.Columns.Add("DateDisplay", typeof(string));
                            foreach (DataRow r in dt.Rows)
                            {
                                var raw = r["Date"]?.ToString() ?? string.Empty;
                                if (DateTime.TryParse(raw, out var dval))
                                {
                                    r["DateDisplay"] = dval.ToString("MMMM dd, yyyy");
                                }
                                else
                                {
                                    // fallback: leave original string
                                    r["DateDisplay"] = raw;
                                }
                            }
                        }

                        if (dt.Columns.Contains("Time") && !dt.Columns.Contains("TimeDisplay"))
                        {
                            dt.Columns.Add("TimeDisplay", typeof(string));
                            foreach (DataRow r in dt.Rows)
                            {
                                var raw = r["Time"]?.ToString() ?? string.Empty;
                                // Try TimeSpan first (common for DB time-only columns), then DateTime
                                if (TimeSpan.TryParse(raw, out var tspan))
                                {
                                    var tmp = DateTime.Today.Add(tspan);
                                    r["TimeDisplay"] = tmp.ToString("hh:mm tt");
                                }
                                else if (DateTime.TryParse(raw, out var dtval))
                                {
                                    r["TimeDisplay"] = dtval.ToString("hh:mm tt");
                                }
                                else
                                {
                                    // fallback: use raw string
                                    r["TimeDisplay"] = raw;
                                }
                            }
                        }

                        dgv.DataSource = dt;
                        // Allow editing only for the Status column. Make grid editable but mark all columns read-only except Status.
                        try
                        {
                            dgv.ReadOnly = false;
                            dgv.AllowUserToAddRows = false;
                            dgv.AllowUserToDeleteRows = false;
                            foreach (DataGridViewColumn col in dgv.Columns)
                            {
                                try
                                {
                                    col.ReadOnly = true; // default to read-only
                                }
                                catch { }
                            }

                            if (_showNonCurrentLocationsOnly && !dgv.Columns.Contains("ForDeliverySelect"))
                            {
                                var selectColumn = new DataGridViewCheckBoxColumn
                                {
                                    Name = "ForDeliverySelect",
                                    HeaderText = "Select",
                                    Width = 60,
                                    ReadOnly = false,
                                    TrueValue = true,
                                    FalseValue = false
                                };

                                try
                                {
                                    dgv.Columns.Insert(0, selectColumn);
                                }
                                catch
                                {
                                    dgv.Columns.Add(selectColumn);
                                }
                            }

                            // Replace auto-generated Status column with a ComboBox column to restrict choices
                            if (dgv.Columns.Contains("Status"))
                            {
                                // capture display/index/width to restore layout
                                int dispIndex = dgv.Columns["Status"].DisplayIndex;
                                int colIndex = dgv.Columns["Status"].Index;
                                int colWidth = dgv.Columns["Status"].Width;
                                // remove the auto column
                                try { dgv.Columns.RemoveAt(colIndex); } catch { }

                                // Base allowed statuses
                                var baseStatuses = new System.Collections.Generic.List<string> { "Submitted", "new", "Confirmed", "Pending Transfer", "In-Transit", "Received", "Production Done", "To Ship", "Shipped", "Printed" };
                                if (_showNonCurrentLocationsOnly)
                                    baseStatuses.RemoveAll(x =>
                                        !string.Equals(x, "Pending Transfer", StringComparison.OrdinalIgnoreCase)
                                        && !string.Equals(x, "In-Transit", StringComparison.OrdinalIgnoreCase)
                                        && (!string.Equals(x, "Received", StringComparison.OrdinalIgnoreCase) || isProductionWarehouseForDelivery));

                                // Merge any distinct statuses found in the DataTable so existing values are valid in the combo
                                try
                                {
                                    var dtStatuses = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                                    var boundDt = dgv.DataSource as DataTable;
                                    if (boundDt != null && boundDt.Columns.Contains("Status"))
                                    {
                                        foreach (DataRow r in boundDt.Rows)
                                        {
                                            try
                                            {
                                                var s = r["Status"]?.ToString();
                                                if (!string.IsNullOrWhiteSpace(s) && !dtStatuses.Contains(s)) dtStatuses.Add(s);
                                            }
                                            catch { }
                                        }
                                    }

                                    foreach (var s in dtStatuses)
                                    {
                                        if (!baseStatuses.Exists(x => string.Equals(x, s, StringComparison.OrdinalIgnoreCase))) baseStatuses.Add(s);
                                    }

                                    if (_showNonCurrentLocationsOnly)
                                        baseStatuses.RemoveAll(x =>
                                            !string.Equals(x, "Pending Transfer", StringComparison.OrdinalIgnoreCase)
                                            && !string.Equals(x, "In-Transit", StringComparison.OrdinalIgnoreCase)
                                            && (!string.Equals(x, "Received", StringComparison.OrdinalIgnoreCase) || isProductionWarehouseForDelivery));
                                }
                                catch { }

                                var combo = new DataGridViewComboBoxColumn()
                                {
                                    Name = "Status",
                                    HeaderText = "Status",
                                    DataPropertyName = "Status",
                                    ValueType = typeof(string),
                                    DataSource = baseStatuses.ToArray(),
                                    FlatStyle = FlatStyle.Flat,
                                    DisplayStyle = DataGridViewComboBoxDisplayStyle.Nothing,
                                };
                                combo.ReadOnly = true;
                                // insert at the original index
                                try { dgv.Columns.Insert(colIndex, combo); combo.DisplayIndex = dispIndex; combo.Width = colWidth; } catch { dgv.Columns.Add(combo); }
                                // No separate ChangeTo column any more — users edit Status directly.
                            }
                        }
                        catch { dgv.ReadOnly = true; }

                        // If we added display columns, hide the raw ones and move display columns into their place
                        if (dgv.Columns.Contains("DateDisplay"))
                        {
                            try
                            {
                                if (dgv.Columns.Contains("Date"))
                                {
                                    dgv.Columns["DateDisplay"].DisplayIndex = dgv.Columns["Date"].DisplayIndex;
                                    dgv.Columns["Date"].Visible = false;
                                }
                                dgv.Columns["DateDisplay"].HeaderText = "Date";
                            }
                            catch { }
                        }
                        if (dgv.Columns.Contains("TimeDisplay"))
                        {
                            try
                            {
                                if (dgv.Columns.Contains("Time"))
                                {
                                    dgv.Columns["TimeDisplay"].DisplayIndex = dgv.Columns["Time"].DisplayIndex;
                                    dgv.Columns["Time"].Visible = false;
                                }
                                dgv.Columns["TimeDisplay"].HeaderText = "Time";
                                // Per request: remove the Time column from the grid/UI
                                dgv.Columns["TimeDisplay"].Visible = false;
                            }
                            catch { }
                        }

                        // Show Location_Name and move it next to Time (prefer TimeDisplay if present)
                        try
                        {
                            if (dgv.Columns.Contains("Location_Name"))
                            {
                                dgv.Columns["Location_Name"].HeaderText = "Location";

                                // Move next to Time if it's visible; otherwise move next to Date.
                                string anchorColName = string.Empty;
                                try
                                {
                                    if (dgv.Columns.Contains("TimeDisplay") && dgv.Columns["TimeDisplay"].Visible)
                                        anchorColName = "TimeDisplay";
                                    else if (dgv.Columns.Contains("Time") && dgv.Columns["Time"].Visible)
                                        anchorColName = "Time";
                                    else if (dgv.Columns.Contains("DateDisplay") && dgv.Columns["DateDisplay"].Visible)
                                        anchorColName = "DateDisplay";
                                    else if (dgv.Columns.Contains("Date") && dgv.Columns["Date"].Visible)
                                        anchorColName = "Date";
                                }
                                catch { anchorColName = string.Empty; }

                                if (!string.IsNullOrWhiteSpace(anchorColName) && dgv.Columns.Contains(anchorColName))
                                {
                                    int targetIndex = dgv.Columns[anchorColName].DisplayIndex + 1;
                                    dgv.Columns["Location_Name"].DisplayIndex = Math.Min(targetIndex, dgv.Columns.Count - 1);
                                }
                            }
                        }
                        catch { }

                        // Ensure alignment for numeric/date columns
                        if (dgv.Columns.Contains("MoneyToCollect"))
                        {
                            dgv.Columns["MoneyToCollect"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                            dgv.Columns["MoneyToCollect"].DefaultCellStyle.Format = "N2"; // show thousands separators and 2 decimals
                            // change caption per request
                            dgv.Columns["MoneyToCollect"].HeaderText = "Total Amount";
                        }
                        if (dgv.Columns.Contains("AmountPaid"))
                        {
                            dgv.Columns["AmountPaid"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                            dgv.Columns["AmountPaid"].DefaultCellStyle.Format = "N2";
                        }
                        if (dgv.Columns.Contains("Balance"))
                        {
                            dgv.Columns["Balance"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                            dgv.Columns["Balance"].DefaultCellStyle.Format = "N2";
                        }
                        if (dgv.Columns.Contains("Discount"))
                        {
                            dgv.Columns["Discount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                            dgv.Columns["Discount"].DefaultCellStyle.Format = "N2";
                        }
                        if (dgv.Columns.Contains("PrintCount"))
                        {
                            dgv.Columns["PrintCount"].HeaderText = "Print Count";
                            dgv.Columns["PrintCount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleCenter;
                            dgv.Columns["PrintCount"].Width = Math.Max(dgv.Columns["PrintCount"].Width, 80);
                            if (_showNonCurrentLocationsOnly)
                                dgv.Columns["PrintCount"].Visible = false;
                        }
                        if (dgv.Columns.Contains("For Delivery"))
                        {
                            dgv.Columns["For Delivery"].HeaderText = "For Delivery";
                            dgv.Columns["For Delivery"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleCenter;
                            dgv.Columns["For Delivery"].Width = Math.Max(dgv.Columns["For Delivery"].Width, 90);
                        }
                        if (dgv.Columns.Contains("Shipping Address"))
                        {
                            dgv.Columns["Shipping Address"].HeaderText = "Shipping Address";
                            dgv.Columns["Shipping Address"].Width = Math.Max(dgv.Columns["Shipping Address"].Width, 220);
                        }
                        if (dgv.Columns.Contains("Estimated Delivery Date"))
                        {
                            dgv.Columns["Estimated Delivery Date"].HeaderText = "Estimated Delivery Date";
                            dgv.Columns["Estimated Delivery Date"].DefaultCellStyle.Format = "MMMM dd, yyyy";
                            dgv.Columns["Estimated Delivery Date"].Width = Math.Max(dgv.Columns["Estimated Delivery Date"].Width, 140);
                        }
                        if (dgv.Columns.Contains("Date of Completion"))
                        {
                            dgv.Columns["Date of Completion"].HeaderText = "Date of Completion";
                            dgv.Columns["Date of Completion"].DefaultCellStyle.Format = "MMMM dd, yyyy";
                            dgv.Columns["Date of Completion"].Width = Math.Max(dgv.Columns["Date of Completion"].Width, 140);
                        }
                        // Show Message_Update_Sent as 'Message Sent' if present
                        if (dgv.Columns.Contains("Message_Update_Sent"))
                        {
                            try
                            {
                                dgv.Columns["Message_Update_Sent"].HeaderText = "Message Sent";
                                dgv.Columns["Message_Update_Sent"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleCenter;
                                // treat as boolean-ish column if it contains 0/1
                            }
                            catch { }
                        }
                        // Hide internal identifiers (persisted but not shown)
                        try
                        {
                            if (dgv.Columns.Contains("ForDeliverySelect"))
                            {
                                dgv.Columns["ForDeliverySelect"].Frozen = true;
                                dgv.Columns["ForDeliverySelect"].DisplayIndex = 0;
                            }
                            if (_showNonCurrentLocationsOnly && dgv.Columns.Contains("LastPaid_Date")) dgv.Columns["LastPaid_Date"].Visible = false;
                            if (dgv.Columns.Contains("LastPaid_Time")) dgv.Columns["LastPaid_Time"].Visible = false;
                            if (dgv.Columns.Contains("Last_Updated_At")) dgv.Columns["Last_Updated_At"].Visible = false;
                            if (dgv.Columns.Contains("Converted_LastUpdated_At")) dgv.Columns["Converted_LastUpdated_At"].Visible = false;
                            if (dgv.Columns.Contains("Page_ID")) dgv.Columns["Page_ID"].Visible = false;
                            if (dgv.Columns.Contains("Conversation_ID")) dgv.Columns["Conversation_ID"].Visible = false;
                            if (dgv.Columns.Contains("LocationID")) dgv.Columns["LocationID"].Visible = false;
                        }
                        catch { }
                    }
                    catch { dgv.DataSource = dt; }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading online orders: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ApplyLocationScopeFilter(DataTable dt)
        {
            if (!_showNonCurrentLocationsOnly || dt.Rows.Count == 0)
                return;

            bool isProductionWarehouse = IsCurrentWarehouseProduction();

            for (int i = dt.Rows.Count - 1; i >= 0; i--)
            {
                var row = dt.Rows[i];
                var status = dt.Columns.Contains("Status") ? row["Status"]?.ToString()?.Trim() ?? string.Empty : string.Empty;

                bool isAllowedDeliveryStatus =
                    string.Equals(status, "Pending Transfer", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status, "In-Transit", StringComparison.OrdinalIgnoreCase)
                    || (!isProductionWarehouse && string.Equals(status, "Received", StringComparison.OrdinalIgnoreCase));

                if (!isAllowedDeliveryStatus)
                    row.Delete();
            }

            dt.AcceptChanges();

            try
            {
                if (statusLabel != null)
                    statusLabel.Text = isProductionWarehouse
                        ? "Showing orders with Pending Transfer or In-Transit status."
                        : "Showing orders with Pending Transfer, In-Transit, or Received status.";
            }
            catch { }
        }

        private void StatusFilterCombo_SelectedIndexChanged(object? sender, EventArgs e)
        {
            try
            {
                ApplyCombinedFilter();
            }
            catch { }
        }

        private void CustomerFilterTextBox_TextChanged(object? sender, EventArgs e)
        {
            try
            {
                string orderIdFilter = orderIdFilterTextBox?.Text ?? string.Empty;
                string customerFilter = customerFilterTextBox?.Text ?? string.Empty;
                RefreshGridFromDb(orderIdFilter, customerFilter);
                ApplyCombinedFilter();
            }
            catch { }
        }

        private void OrderIdFilterTextBox_TextChanged(object? sender, EventArgs e)
        {
            try
            {
                string orderIdFilter = orderIdFilterTextBox?.Text ?? string.Empty;
                string customerFilter = customerFilterTextBox?.Text ?? string.Empty;
                RefreshGridFromDb(orderIdFilter, customerFilter);
                ApplyCombinedFilter();
            }
            catch { }
        }

        private async void ForDeliveryButton_Click(object? sender, EventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted("For Delivery")) return;
                try
                {
                    if (dgv.IsCurrentCellDirty)
                        dgv.CommitEdit(DataGridViewDataErrorContexts.Commit);
                }
                catch { }

                var selectedRows = new System.Collections.Generic.List<DataGridViewRow>();
                if (dgv.Columns.Contains("ForDeliverySelect"))
                {
                    foreach (DataGridViewRow row in dgv.Rows)
                    {
                        try
                        {
                            if (row.IsNewRow) continue;
                            bool isChecked = false;
                            var value = row.Cells["ForDeliverySelect"].Value;
                            if (value is bool b) isChecked = b;
                            else if (value != null && bool.TryParse(value.ToString(), out var parsed)) isChecked = parsed;
                            if (isChecked) selectedRows.Add(row);
                        }
                        catch { }
                    }
                }

                if (selectedRows.Count == 0 && dgv.CurrentRow != null)
                    selectedRows.Add(dgv.CurrentRow);

                if (selectedRows.Count == 0)
                {
                    MessageBox.Show("Please choose at least one order for delivery.", "For Delivery", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                var confirmReady = MessageBox.Show(
                    "Are the selected orders ready for delivery?",
                    "For Delivery",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);
                if (confirmReady != DialogResult.Yes)
                    return;

                int updatedCount = 0;
                int messageSentCount = 0;
                foreach (var row in selectedRows)
                {
                    int rowIndex = row.Index;
                    string orderId = GetOrderIdForRow(rowIndex);
                    if (string.IsNullOrWhiteSpace(orderId))
                        continue;

                    string currentStatus = string.Empty;
                    try
                    {
                        if (dgv.Columns.Contains("Status"))
                            currentStatus = dgv.Rows[rowIndex].Cells["Status"].Value?.ToString() ?? string.Empty;
                    }
                    catch { }

                    if (string.Equals(currentStatus, "new", StringComparison.OrdinalIgnoreCase))
                        continue;

                    if (!await EnsureOrderSerialTrackingAsync(orderId, "For Delivery").ConfigureAwait(false))
                        continue;

                    await ChangeOrderStatusAsync(rowIndex, orderId, "In-Transit").ConfigureAwait(false);

                    string locationName = GetLocationNameForRow(rowIndex, orderId);
                    string transferredStatus = string.IsNullOrWhiteSpace(locationName)
                        ? "TRANSFERRED-TO"
                        : $"TRANSFERRED-TO {locationName}";
                    ProductSerialTrackingForm.UpdateSerialStatus(LoadTrackedSerialNumbersForOrder(orderId), transferredStatus);

                    updatedCount++;

                    bool messageSent = await SendUpdateToCustomerForRowAsync(rowIndex, GlobalSettings.InTransitMessage).ConfigureAwait(false);
                    if (messageSent)
                        messageSentCount++;

                    try
                    {
                        if (dgv.Columns.Contains("ForDeliverySelect"))
                            dgv.Rows[rowIndex].Cells["ForDeliverySelect"].Value = false;
                    }
                    catch { }
                }

                if (updatedCount == 0)
                {
                    MessageBox.Show("No eligible orders were marked for delivery.", "For Delivery", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                if (messageSentCount == updatedCount)
                {
                    MessageBox.Show("Status updated , Message sent to the customer", "For Delivery", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                else
                {
                    MessageBox.Show($"Status updated for {updatedCount} order(s), but only {messageSentCount} customer message(s) were sent.", "For Delivery", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Failed to mark order for delivery: {ex.Message}", "For Delivery", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private async void ReceiveOrderButton_Click(object? sender, EventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted("Receive Order")) return;
                try
                {
                    if (dgv.IsCurrentCellDirty)
                        dgv.CommitEdit(DataGridViewDataErrorContexts.Commit);
                }
                catch { }

                var selectedRows = new System.Collections.Generic.List<DataGridViewRow>();
                if (dgv.Columns.Contains("ForDeliverySelect"))
                {
                    foreach (DataGridViewRow row in dgv.Rows)
                    {
                        try
                        {
                            if (row.IsNewRow) continue;
                            bool isChecked = false;
                            var value = row.Cells["ForDeliverySelect"].Value;
                            if (value is bool b) isChecked = b;
                            else if (value != null && bool.TryParse(value.ToString(), out var parsed)) isChecked = parsed;
                            if (isChecked) selectedRows.Add(row);
                        }
                        catch { }
                    }
                }

                if (selectedRows.Count == 0 && dgv.CurrentRow != null)
                    selectedRows.Add(dgv.CurrentRow);

                if (selectedRows.Count == 0)
                {
                    MessageBox.Show("Please choose at least one order to receive.", "Receive Order", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                var confirmReceive = MessageBox.Show(
                    "Are the selected orders already received?",
                    "Receive Order",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);
                if (confirmReceive != DialogResult.Yes)
                    return;

                int updatedCount = 0;
                int messageSentCount = 0;
                foreach (var row in selectedRows)
                {
                    int rowIndex = row.Index;
                    string orderId = GetOrderIdForRow(rowIndex);
                    if (string.IsNullOrWhiteSpace(orderId))
                        continue;

                    if (!CanManuallyChangeStatusForRow(rowIndex, out var locationMessage))
                    {
                        MessageBox.Show(locationMessage, "Invalid Operation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        continue;
                    }

                    string currentStatus = GetStatusForRow(rowIndex);
                    if (!string.Equals(currentStatus, "In-Transit", StringComparison.OrdinalIgnoreCase))
                        continue;

                    await ChangeOrderStatusAsync(rowIndex, orderId, "Received").ConfigureAwait(false);
                    updatedCount++;

                    bool messageSent = await SendUpdateToCustomerForRowAsync(rowIndex, GlobalSettings.ReceivedMessage).ConfigureAwait(false);
                    if (messageSent)
                        messageSentCount++;

                    try
                    {
                        if (dgv.Columns.Contains("ForDeliverySelect"))
                            dgv.Rows[rowIndex].Cells["ForDeliverySelect"].Value = false;
                    }
                    catch { }
                }

                if (updatedCount == 0)
                {
                    MessageBox.Show("No eligible In-Transit orders were marked as Received.", "Receive Order", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                if (messageSentCount == updatedCount)
                {
                    MessageBox.Show("Status updated , Message sent to the customer", "Receive Order", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                else
                {
                    MessageBox.Show($"Marked {updatedCount} order(s) as Received, but only {messageSentCount} customer message(s) were sent.", "Receive Order", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Failed to receive order: {ex.Message}", "Receive Order", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        // Apply combined filters (status + customer name) to the bound DataTable's DefaultView
        private void ApplyCombinedFilter()
        {
            var dt = dgv.DataSource as DataTable;
            if (dt == null) return;

            var statusSel = statusFilterCombo.SelectedItem?.ToString() ?? string.Empty;
            var orderIdFilter = orderIdFilterTextBox != null ? orderIdFilterTextBox.Text ?? string.Empty : string.Empty;
            var customerFilter = customerFilterTextBox != null ? customerFilterTextBox.Text ?? string.Empty : string.Empty;

            var filters = new System.Collections.Generic.List<string>();

            // Status filter
            if (!string.IsNullOrWhiteSpace(statusSel) && !string.Equals(statusSel, "All", StringComparison.OrdinalIgnoreCase))
            {
                var escaped = statusSel.Replace("'", "''");
                filters.Add($"Status = '{escaped}'");
            }

            // OrderID filter - simple contains filter. Use Convert(..,'System.String') so it works even if
            // the underlying column type is numeric.
            if (!string.IsNullOrWhiteSpace(orderIdFilter))
            {
                var input = orderIdFilter.Replace("'", "''").Trim();
                filters.Add($"Convert(OrderID, 'System.String') LIKE '%{input}%'");
            }

            if (!string.IsNullOrWhiteSpace(customerFilter) && dt.Columns.Contains("CustomerName"))
            {
                var input = customerFilter.Replace("'", "''").Trim();
                filters.Add($"Convert(CustomerName, 'System.String') LIKE '%{input}%'");
            }

            var final = string.Empty;
            if (filters.Count > 0) final = string.Join(" AND ", filters);
            try
            {
                dt.DefaultView.RowFilter = final;
            }
            catch (Exception ex)
            {
                // If filter fails (e.g., column missing), clear filter to avoid leaving an invalid filter
                System.Diagnostics.Trace.TraceWarning($"Failed to apply row filter '{final}': {ex.Message}");
                try { dt.DefaultView.RowFilter = string.Empty; } catch { }
            }
        }

        // Fetch lines from upstream API and persist into dbo.OnlineOrderLines. Returns true if any lines were fetched.
        private async Task<bool> FetchAndPersistOrderLinesAsync(string orderId)
        {
            if (string.IsNullOrWhiteSpace(orderId)) return false;

            DataTable? fetched = null;
            try
            {
                fetched = await IntegrationEvents.FetchOrderLinesAsync(orderId, TimeSpan.FromSeconds(15)).ConfigureAwait(false);
            }
            catch
            {
                fetched = null;
            }

            if (fetched == null || fetched.Rows.Count == 0) return false;

            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    string createLinesSql = @"
                        IF OBJECT_ID('dbo.OnlineOrderLines', 'U') IS NULL
                        BEGIN
                            CREATE TABLE dbo.OnlineOrderLines (
                                OrderID NVARCHAR(100) NOT NULL,
                                LineID NVARCHAR(100) NOT NULL,
                                ItemCode NVARCHAR(200) NULL,
                                product_display_id NVARCHAR(200) NULL,
                                VariationId NVARCHAR(200) NULL,
                                Quantity DECIMAL(18,2) NULL,
                                UnitCost DECIMAL(18,2) NULL,
                                Price DECIMAL(18,2) NULL,
                                Discount DECIMAL(18,2) NULL,
                                GrossAmount DECIMAL(18,2) NULL,
                                NetAmount DECIMAL(18,2) NULL,
                                Note NVARCHAR(MAX) NULL,
                                Description NVARCHAR(500) NULL,
                                CONSTRAINT PK_OnlineOrderLines PRIMARY KEY (OrderID, LineID)
                            )
                        END
                        ";
                    using (var createCmd = new SqlCommand(createLinesSql, conn)) createCmd.ExecuteNonQuery();
                    EnsureOnlineOrderLinesColumns(conn);

                    using (var tran = conn.BeginTransaction())
                    {
                        foreach (DataRow lr in fetched.Rows)
                        {
                            string lineId = lr.Table.Columns.Contains("LineID") ? (lr["LineID"] as string ?? string.Empty) : string.Empty;
                            string product_display = lr.Table.Columns.Contains("product_display_id") ? (lr["product_display_id"] as string ?? string.Empty) : string.Empty;
                            string itemCode = product_display;
                            string variationId = lr.Table.Columns.Contains("VariationId") ? (lr["VariationId"] as string ?? string.Empty) : string.Empty;
                            decimal qty = lr.Table.Columns.Contains("Quantity") && lr["Quantity"] is not DBNull ? Convert.ToDecimal(lr["Quantity"]) : 0m;
                            decimal unitCost = lr.Table.Columns.Contains("UnitCost") && lr["UnitCost"] is not DBNull ? Convert.ToDecimal(lr["UnitCost"]) : 0m;
                            decimal price = lr.Table.Columns.Contains("Price") && lr["Price"] is not DBNull ? Convert.ToDecimal(lr["Price"]) : 0m;
                            decimal discount = lr.Table.Columns.Contains("Discount") && lr["Discount"] is not DBNull ? Convert.ToDecimal(lr["Discount"]) : 0m;
                            decimal gross = lr.Table.Columns.Contains("GrossAmount") && lr["GrossAmount"] is not DBNull ? Convert.ToDecimal(lr["GrossAmount"]) : 0m;
                            decimal net = lr.Table.Columns.Contains("NetAmount") && lr["NetAmount"] is not DBNull ? Convert.ToDecimal(lr["NetAmount"]) : 0m;
                            string note = lr.Table.Columns.Contains("Note") ? (lr["Note"] as string ?? string.Empty) : string.Empty;
                            string description = lr.Table.Columns.Contains("Description") ? (lr["Description"] as string ?? string.Empty) : string.Empty;

                            string updateLinesSql = @"UPDATE dbo.OnlineOrderLines SET ItemCode=@ItemCode, product_display_id=@product_display_id, VariationId=@VariationId, Quantity=@Quantity, UnitCost=@UnitCost, Price=@Price, Discount=@Discount, GrossAmount=@GrossAmount, NetAmount=@NetAmount, Note = CASE WHEN NULLIF(@Note, '') IS NULL THEN Note ELSE @Note END, Description = CASE WHEN NULLIF(@Description, '') IS NULL THEN Description ELSE @Description END WHERE OrderID=@OrderID AND LineID=@LineID";
                            using (var upCmd = new SqlCommand(updateLinesSql, conn, tran))
                            {
                                upCmd.Parameters.AddWithValue("@ItemCode", string.IsNullOrWhiteSpace(itemCode) ? (object)DBNull.Value : (object)itemCode);
                                upCmd.Parameters.AddWithValue("@product_display_id", string.IsNullOrWhiteSpace(product_display) ? (object)DBNull.Value : (object)product_display);
                                upCmd.Parameters.AddWithValue("@VariationId", string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : (object)variationId);
                                upCmd.Parameters.AddWithValue("@Quantity", qty);
                                upCmd.Parameters.AddWithValue("@UnitCost", unitCost);
                                upCmd.Parameters.AddWithValue("@Price", price);
                                upCmd.Parameters.AddWithValue("@Discount", discount);
                                upCmd.Parameters.AddWithValue("@GrossAmount", gross);
                                upCmd.Parameters.AddWithValue("@NetAmount", net);
                                upCmd.Parameters.AddWithValue("@Note", string.IsNullOrWhiteSpace(note) ? (object)DBNull.Value : (object)note);
                                upCmd.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(description) ? (object)DBNull.Value : (object)description);
                                upCmd.Parameters.AddWithValue("@OrderID", orderId);
                                upCmd.Parameters.AddWithValue("@LineID", lineId);

                                int affected = upCmd.ExecuteNonQuery();
                                if (affected == 0)
                                {
                                    string insertLinesSql = @"INSERT INTO dbo.OnlineOrderLines (OrderID, LineID, ItemCode, product_display_id, VariationId, Quantity, UnitCost, Price, Discount, GrossAmount, NetAmount, Note, Description) VALUES (@OrderID, @LineID, @ItemCode, @product_display_id, @VariationId, @Quantity, @UnitCost, @Price, @Discount, @GrossAmount, @NetAmount, @Note, @Description)";
                                    using (var insCmd = new SqlCommand(insertLinesSql, conn, tran))
                                    {
                                        insCmd.Parameters.AddWithValue("@OrderID", orderId);
                                        insCmd.Parameters.AddWithValue("@LineID", lineId);
                                        insCmd.Parameters.AddWithValue("@ItemCode", string.IsNullOrWhiteSpace(itemCode) ? (object)DBNull.Value : (object)itemCode);
                                        insCmd.Parameters.AddWithValue("@product_display_id", string.IsNullOrWhiteSpace(product_display) ? (object)DBNull.Value : (object)product_display);
                                        insCmd.Parameters.AddWithValue("@VariationId", string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : (object)variationId);
                                        insCmd.Parameters.AddWithValue("@Quantity", qty);
                                        insCmd.Parameters.AddWithValue("@UnitCost", unitCost);
                                        insCmd.Parameters.AddWithValue("@Price", price);
                                        insCmd.Parameters.AddWithValue("@Discount", discount);
                                        insCmd.Parameters.AddWithValue("@GrossAmount", gross);
                                        insCmd.Parameters.AddWithValue("@NetAmount", net);
                                        insCmd.Parameters.AddWithValue("@Note", string.IsNullOrWhiteSpace(note) ? (object)DBNull.Value : (object)note);
                                        insCmd.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(description) ? (object)DBNull.Value : (object)description);
                                        insCmd.ExecuteNonQuery();
                                    }
                                }
                            }
                        }

                        tran.Commit();
                    }
                }
            }
            catch (Exception ex)
            {
                // Surface DB connection/SQL errors so calling code (UI) can inform the user
                try { System.Diagnostics.Trace.TraceError($"FetchAndPersistOrderLinesAsync DB error: {ex}"); } catch { }
                throw new InvalidOperationException("Database error while persisting fetched order lines. See inner exception for details.", ex);
            }

            return true;
        }

        private async void SyncButton_Click(object? sender, EventArgs e)
        {
            // Trigger resend of any failed local transactions immediately when the user clicks Sync.
            try
            {
                _ = System.Threading.Tasks.Task.Run(() =>
                {
                    try
                    {
                        int sent = OnlinefunctionsEvents.SendFailedTransactionToCloud();
                        try { System.Diagnostics.Trace.TraceInformation($"SyncButton_Click: Resent {sent} failed local transactions."); } catch { }
                    }
                    catch (Exception ex)
                    {
                        try { System.Diagnostics.Trace.TraceError($"SyncButton_Click: resend failed: {ex}"); } catch { }
                    }
                });
            }
            catch { }

            await DoSyncAndRefreshAsync();
        }

        private void Dgv_CurrentCellDirtyStateChanged(object? sender, EventArgs e)
        {
            try
            {
                if (_showNonCurrentLocationsOnly && dgv.CurrentCell is DataGridViewCheckBoxCell)
                    dgv.CommitEdit(DataGridViewDataErrorContexts.Commit);
            }
            catch { }
        }

        private void Dgv_CellContentClick(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (!_showNonCurrentLocationsOnly || e.RowIndex < 0 || e.ColumnIndex < 0)
                    return;

                var col = dgv.Columns[e.ColumnIndex];
                if (col == null || !string.Equals(col.Name, "ForDeliverySelect", StringComparison.OrdinalIgnoreCase))
                    return;

                var cell = dgv.Rows[e.RowIndex].Cells[e.ColumnIndex];
                bool currentValue = false;
                try
                {
                    if (cell.Value is bool b) currentValue = b;
                    else if (cell.Value != null && bool.TryParse(cell.Value.ToString(), out var parsed)) currentValue = parsed;
                }
                catch { }

                cell.Value = !currentValue;
            }
            catch { }
        }

        // Click handler for Print button: build order lines text and print to POS58 or show preview
        private void PrintButton_Click(object? sender, EventArgs e)
        {
            try
            {
                if (!EnsureOrderSyncCompleted("Print")) return;
                // Prefer configured POS printer name, then heuristic, then system default
                var targetPrinter = GlobalSettings.PosPrinterName;
                if (string.IsNullOrWhiteSpace(targetPrinter)) targetPrinter = FindPos58Printer();
                if (string.IsNullOrWhiteSpace(targetPrinter))
                {
                    try { targetPrinter = new System.Drawing.Printing.PrinterSettings().PrinterName; } catch { targetPrinter = string.Empty; }
                }
                if (!string.IsNullOrWhiteSpace(targetPrinter))
                {
                    var rowsToPrint = new System.Collections.Generic.List<int>();

                    if (_showNonCurrentLocationsOnly && dgv.Columns.Contains("ForDeliverySelect"))
                    {
                        foreach (DataGridViewRow row in dgv.Rows)
                        {
                            try
                            {
                                if (row.IsNewRow) continue;
                                bool isChecked = false;
                                var value = row.Cells["ForDeliverySelect"].Value;
                                if (value is bool b) isChecked = b;
                                else if (value != null && bool.TryParse(value.ToString(), out var parsed)) isChecked = parsed;
                                if (isChecked) rowsToPrint.Add(row.Index);
                            }
                            catch { }
                        }
                    }

                    if (rowsToPrint.Count == 0)
                    {
                        if (dgv.CurrentRow == null)
                        {
                            MessageBox.Show("Please select an order first.", "Print", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            return;
                        }

                        rowsToPrint.Add(dgv.CurrentRow.Index);
                    }

                    int printedCount = 0;
                    bool showPerOrderMessage = rowsToPrint.Count == 1;
                    foreach (var rowIdx in rowsToPrint)
                    {
                        if (PrintOrderForRow(rowIdx, targetPrinter, showPerOrderMessage))
                            printedCount++;
                    }

                    if (!showPerOrderMessage)
                    {
                        if (printedCount > 0)
                            MessageBox.Show($"Sent {printedCount} order(s) to printer: {targetPrinter}", "Printing", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        else
                            MessageBox.Show("No eligible selected orders were printed.", "Print", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                }
                else
                {
                    MessageBox.Show("No printer available on this system. Please check that a default printer is configured.", "Printer Not Found", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Print operation failed: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private bool PrintOrderForRow(int rowIdx, string targetPrinter, bool showSuccessMessage = true)
        {
            try
            {
                if (rowIdx < 0 || rowIdx >= dgv.Rows.Count)
                    return false;

                string orderId = GetOrderIdForRow(rowIdx);
                if (string.IsNullOrWhiteSpace(orderId))
                    return false;

                string status = GetStatusForRow(rowIdx);
                if (string.Equals(status, "new", StringComparison.OrdinalIgnoreCase))
                {
                    if (showSuccessMessage)
                        MessageBox.Show("Cannot print orders with status 'new'. Please ask Sales to confirm the order first.", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return false;
                }

                if (string.Equals(status, "cancel", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status, "canceled", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status, "cancelled", StringComparison.OrdinalIgnoreCase))
                {
                    if (showSuccessMessage)
                        MessageBox.Show("Cannot print orders with status 'canceled'.", "Invalid Status", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return false;
                }

                string customerName = string.Empty;
                try
                {
                    if (dgv.Columns.Contains("CustomerName"))
                        customerName = dgv.Rows[rowIdx].Cells["CustomerName"].Value?.ToString() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(customerName))
                    {
                        using var cn = new SqlConnection(connectionString);
                        cn.Open();
                        using var ccmd = new SqlCommand("SELECT TOP 1 CustomerName FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", cn);
                        ccmd.Parameters.AddWithValue("@OrderID", orderId);
                        var res = ccmd.ExecuteScalar();
                        if (res != null && res != DBNull.Value) customerName = res.ToString() ?? string.Empty;
                    }
                }
                catch { customerName = string.Empty; }

                string locationName = string.Empty;
                try
                {
                    if (dgv.Columns.Contains("Location_Name"))
                        locationName = dgv.Rows[rowIdx].Cells["Location_Name"].Value?.ToString() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(locationName))
                    {
                        using var cn = new SqlConnection(connectionString);
                        cn.Open();
                        using var ccmd = new SqlCommand("SELECT TOP 1 Location_Name FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", cn);
                        ccmd.Parameters.AddWithValue("@OrderID", orderId);
                        var res = ccmd.ExecuteScalar();
                        if (res != null && res != DBNull.Value) locationName = res.ToString() ?? string.Empty;
                    }
                }
                catch { locationName = string.Empty; }

                string body = BuildOrderItemsText(orderId, customerName, locationName);
                if (string.IsNullOrWhiteSpace(body))
                {
                    if (showSuccessMessage)
                        MessageBox.Show("No items found for the selected order.", "No Items", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return false;
                }

                using var pd = new System.Drawing.Printing.PrintDocument();
                pd.DocumentName = $"ONLINE_ORDER_{orderId}";

                float paperWidthInches = AquariumPOS.GlobalSettings.PaperWidthInches;
                try { if (!string.IsNullOrWhiteSpace(targetPrinter) && targetPrinter.ToLowerInvariant().Contains("59")) paperWidthInches = 2.32f; } catch { }

                try
                {
                    var linesToMeasure = body.Replace("\r", "").Split('\n');
                    using (var bmp = new System.Drawing.Bitmap(1, 1))
                    using (var g = System.Drawing.Graphics.FromImage(bmp))
                    {
                        float baseSize = Math.Max(6f, AquariumPOS.GlobalSettings.ReceiptFontSize);
                        float bodySize = baseSize * 1.25f;
                        float headerSize = baseSize * 1.5f;

                        using (var headerFont = new System.Drawing.Font(AquariumPOS.GlobalSettings.ReceiptFont, headerSize, System.Drawing.FontStyle.Bold))
                        using (var bodyFont = new System.Drawing.Font(AquariumPOS.GlobalSettings.ReceiptFont, bodySize, System.Drawing.FontStyle.Bold))
                        {
                            float dpiY = g.DpiY;
                            float dpiX = g.DpiX;
                            float totalPx = 0f;

                            int startIndex = 0;
                            if (linesToMeasure.Length > 0 && !string.IsNullOrWhiteSpace(linesToMeasure[0]))
                            {
                                totalPx += headerFont.GetHeight(g) + 2;
                                startIndex = 1;
                            }

                            while (startIndex < linesToMeasure.Length && string.IsNullOrWhiteSpace(linesToMeasure[startIndex])) startIndex++;
                            if (startIndex < linesToMeasure.Length)
                            {
                                totalPx += bodyFont.GetHeight(g) + 2;
                                startIndex++;
                            }

                            while (startIndex < linesToMeasure.Length && string.IsNullOrWhiteSpace(linesToMeasure[startIndex])) startIndex++;
                            if (startIndex < linesToMeasure.Length)
                            {
                                var maybeLocation = linesToMeasure[startIndex] ?? string.Empty;
                                if (maybeLocation.TrimStart().StartsWith("Location:", StringComparison.OrdinalIgnoreCase))
                                {
                                    totalPx += bodyFont.GetHeight(g) + 2;
                                    startIndex++;
                                }
                            }

                            totalPx += bodyFont.GetHeight(g) + 2;

                            float printableWidthPx = Math.Max(1f, (paperWidthInches - (AquariumPOS.GlobalSettings.LeftMarginInches * 2f)) * dpiX);
                            for (int i = startIndex; i < linesToMeasure.Length; i++)
                            {
                                var ln = linesToMeasure[i] ?? string.Empty;
                                var measured = g.MeasureString(ln, bodyFont, (int)printableWidthPx);
                                totalPx += measured.Height + 1;
                            }

                            totalPx += bodyFont.GetHeight(g) + 2;
                            totalPx += (AquariumPOS.GlobalSettings.TopMarginInches + AquariumPOS.GlobalSettings.LeftMarginInches) * dpiY;

                            float totalInches = Math.Max(3.0f, totalPx / dpiY);
                            int width = (int)(paperWidthInches * 100f);
                            int height = (int)Math.Ceiling(totalInches * 100f);
                            pd.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("POS58", width, height);
                            pd.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins((int)(AquariumPOS.GlobalSettings.LeftMarginInches * 100f), (int)(AquariumPOS.GlobalSettings.LeftMarginInches * 100f), (int)(AquariumPOS.GlobalSettings.TopMarginInches * 100f), (int)(AquariumPOS.GlobalSettings.TopMarginInches * 100f));
                        }
                    }
                }
                catch { }

                pd.PrintPage += (s, pe) =>
                {
                    var g = pe.Graphics;
                    var area = pe.MarginBounds;
                    float y = area.Top;
                    if (g == null) { pe.HasMorePages = false; return; }

                    float baseSize = Math.Max(6f, AquariumPOS.GlobalSettings.ReceiptFontSize);
                    using (var headerFont = new System.Drawing.Font(AquariumPOS.GlobalSettings.ReceiptFont, baseSize * 1.5f, AquariumPOS.GlobalSettings.ReceiptFontStyle))
                    using (var bodyFont = new System.Drawing.Font(AquariumPOS.GlobalSettings.ReceiptFont, baseSize * 1.2f, AquariumPOS.GlobalSettings.ReceiptFontStyle))
                    {
                        var lines = body.Replace("\r", "").Split('\n');
                        int idx = 0;

                        if (lines.Length > 0 && !string.IsNullOrWhiteSpace(lines[0]))
                        {
                            g.DrawString(lines[0], headerFont, Brushes.Black, area.Left, y);
                            y += headerFont.GetHeight(g) + 2;
                            idx = 1;
                        }

                        while (idx < lines.Length && string.IsNullOrWhiteSpace(lines[idx])) idx++;
                        if (idx < lines.Length)
                        {
                            g.DrawString(lines[idx], bodyFont, Brushes.Black, area.Left, y);
                            y += bodyFont.GetHeight(g) + 2;
                            idx++;
                        }

                        while (idx < lines.Length && string.IsNullOrWhiteSpace(lines[idx])) idx++;
                        if (idx < lines.Length)
                        {
                            var maybeLocation = lines[idx] ?? string.Empty;
                            if (maybeLocation.TrimStart().StartsWith("Location:", StringComparison.OrdinalIgnoreCase))
                            {
                                g.DrawString(maybeLocation, bodyFont, Brushes.Black, area.Left, y);
                                y += bodyFont.GetHeight(g) + 2;
                                idx++;
                            }
                        }

                        try { var sep = new string('-', AquariumPOS.GlobalSettings.ReceiptWidth); g.DrawString(sep, bodyFont, Brushes.Black, new RectangleF(area.Left, y, area.Width, bodyFont.GetHeight(g))); y += bodyFont.GetHeight(g) + 2; } catch { }

                        for (int i = idx; i < lines.Length; i++)
                        {
                            var ln = lines[i] ?? string.Empty;
                            var layout = new RectangleF(area.Left, y, area.Width, area.Bottom - y);
                            var measured = g.MeasureString(ln, bodyFont, new SizeF(area.Width, area.Bottom - y));
                            float h = measured.Height; if (h <= 0) h = bodyFont.GetHeight(g) + 1;
                            g.DrawString(ln, bodyFont, Brushes.Black, layout);
                            y += h + 1;
                            if (y > area.Bottom - 1) { pe.HasMorePages = true; return; }
                        }
                        pe.HasMorePages = false;
                    }
                };

                pd.PrinterSettings.PrinterName = targetPrinter;
                pd.Print();
                int currentPrintCount = IncrementOnlineOrderPrintCount(orderId, rowIdx);
                bool isFirstPrint = currentPrintCount <= 1;
                UpdateEstimatedDeliveryDateForPrintedOrder(orderId, rowIdx, !isFirstPrint);
                try
                {
                    string previewTitle = isFirstPrint ? "Printed Order Payload" : "Estimated Delivery Payload";
                    string previewText = isFirstPrint
                        ? IntegrationEvents.BuildPrintedOrderPayloadPreview(orderId, MapStatusForApi("Printed"))
                        : IntegrationEvents.BuildEstimatedDeliveryDatePayloadPreview(orderId);

                    MessageBox.Show(
                        previewText,
                        previewTitle,
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }
                catch { }
                if (showSuccessMessage)
                    MessageBox.Show($"Sent to printer: {targetPrinter}", "Printing", MessageBoxButtons.OK, MessageBoxIcon.Information);

                _ = System.Threading.Tasks.Task.Run(async () =>
                {
                    try
                    {
                        if (isFirstPrint)
                        {
                            UpdateOrderStatusLocal(rowIdx, orderId, "Printed");
                            try
                            {
                                await IntegrationEvents.UpdatePrintedOrderPayload(orderId, MapStatusForApi("Printed")).ConfigureAwait(false);
                            }
                            catch (Exception ex)
                            {
                                try { System.Diagnostics.Trace.TraceError($"Failed to update printed order payload for {orderId}: {ex}"); } catch { }
                                try { this.Invoke(new Action(() => MessageBox.Show($"Failed to update upstream printed order payload: {ex.Message}", "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning))); } catch { }
                            }
                            await NotifyCustomerOrderPrintedAsync(orderId, rowIdx).ConfigureAwait(false);
                        }
                    }
                    catch { }
                });

                return true;
            }
            catch (Exception ex)
            {
                if (showSuccessMessage)
                    MessageBox.Show($"Failed to print order: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        private int IncrementOnlineOrderPrintCount(string orderId, int rowIndex = -1)
        {
            if (string.IsNullOrWhiteSpace(orderId))
                return 0;

            try
            {
                int updatedCount = 0;
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();

                    using (var ensureCmd = new SqlCommand(@"
IF COL_LENGTH('dbo.OnlineOrderHeader', 'PrintCount') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD PrintCount INT NOT NULL CONSTRAINT DF_OnlineOrderHeader_PrintCount_Click DEFAULT (0)
END", conn))
                    {
                        ensureCmd.ExecuteNonQuery();
                    }

                    using (var updateCmd = new SqlCommand(@"
UPDATE dbo.OnlineOrderHeader
SET PrintCount = ISNULL(PrintCount, 0) + 1
WHERE OrderID = @OrderID;

SELECT ISNULL(PrintCount, 0)
FROM dbo.OnlineOrderHeader
WHERE OrderID = @OrderID;", conn))
                    {
                        updateCmd.Parameters.AddWithValue("@OrderID", orderId);
                        var result = updateCmd.ExecuteScalar();
                        if (result != null && result != DBNull.Value)
                            updatedCount = Convert.ToInt32(result);
                    }
                }

                try
                {
                    var dt = dgv.DataSource as DataTable;
                    if (dt != null && dt.Columns.Contains("PrintCount") && rowIndex >= 0 && rowIndex < dt.Rows.Count)
                    {
                        dt.Rows[rowIndex]["PrintCount"] = updatedCount;
                    }
                    if (dgv.Columns.Contains("PrintCount") && rowIndex >= 0 && rowIndex < dgv.Rows.Count)
                    {
                        dgv.Rows[rowIndex].Cells["PrintCount"].Value = updatedCount;
                    }
                }
                catch { }

                return updatedCount;
            }
            catch { }

            return 0;
        }

        private void UpdateEstimatedDeliveryDateForPrintedOrder(string orderId, int rowIndex = -1, bool pushUpstream = true)
        {
            if (string.IsNullOrWhiteSpace(orderId))
                return;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                using (var ensureColumnCmd = new SqlCommand(@"
IF COL_LENGTH('dbo.OnlineOrderHeader', 'Estimated Delivery Date') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineOrderHeader ADD [Estimated Delivery Date] DATE NULL
END", conn))
                {
                    ensureColumnCmd.ExecuteNonQuery();
                }

                DateTime? existingEstimatedDeliveryDate = null;
                using (var existingDateCmd = new SqlCommand(@"
SELECT TOP 1 [Estimated Delivery Date]
FROM dbo.OnlineOrderHeader
WHERE OrderID = @OrderID;", conn))
                {
                    existingDateCmd.Parameters.AddWithValue("@OrderID", orderId);
                    var existingValue = existingDateCmd.ExecuteScalar();
                    if (existingValue != null && existingValue != DBNull.Value)
                        existingEstimatedDeliveryDate = Convert.ToDateTime(existingValue).Date;
                }

                DateTime estimatedDeliveryDate;
                if (existingEstimatedDeliveryDate.HasValue)
                {
                    estimatedDeliveryDate = existingEstimatedDeliveryDate.Value;
                }
                else
                {
                    EnsureGlassPricingSetupTurnAroundSchema(conn);

                    string prioritizedThickness = DetectPriorityGlassThickness(conn, orderId);
                    if (string.IsNullOrWhiteSpace(prioritizedThickness))
                        return;

                    string turnAroundDaysText = LoadTurnAroundDaysForThickness(conn, prioritizedThickness);
                    int leadDays = ParseTurnAroundLeadDays(turnAroundDaysText);
                    if (leadDays <= 0)
                        return;

                    estimatedDeliveryDate = DateTime.Today.AddDays(leadDays).Date;
                    using var updateCmd = new SqlCommand(@"
UPDATE dbo.OnlineOrderHeader
SET [Estimated Delivery Date] = @EstimatedDeliveryDate
WHERE OrderID = @OrderID;", conn);
                    updateCmd.Parameters.AddWithValue("@EstimatedDeliveryDate", estimatedDeliveryDate);
                    updateCmd.Parameters.AddWithValue("@OrderID", orderId);
                    updateCmd.ExecuteNonQuery();
                }

                if (pushUpstream)
                {
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            await IntegrationEvents.UpdateEstimatedDeliveryDatePayload(orderId).ConfigureAwait(false);
                        }
                        catch (Exception ex)
                        {
                            try { System.Diagnostics.Trace.TraceError($"Failed to update upstream estimated delivery date for {orderId}: {ex}"); } catch { }
                        }
                    });
                }

                try
                {
                    var dt = dgv.DataSource as DataTable;
                    if (dt != null && dt.Columns.Contains("Estimated Delivery Date") && rowIndex >= 0 && rowIndex < dt.Rows.Count)
                        dt.Rows[rowIndex]["Estimated Delivery Date"] = estimatedDeliveryDate.Date;

                    if (dgv.Columns.Contains("Estimated Delivery Date") && rowIndex >= 0 && rowIndex < dgv.Rows.Count)
                        dgv.Rows[rowIndex].Cells["Estimated Delivery Date"].Value = estimatedDeliveryDate.Date;
                }
                catch { }
            }
            catch { }
        }

        private void EnsureGlassPricingSetupTurnAroundSchema(SqlConnection conn)
        {
            using var cmd = new SqlCommand(@"
IF OBJECT_ID('dbo.GlassPricingSetup', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.GlassPricingSetup (
        UOM NVARCHAR(50) NOT NULL,
        Units NVARCHAR(100) NOT NULL,
        PricePerSqFt DECIMAL(18,2) NOT NULL,
        TurnAroundDays NVARCHAR(100) NULL
    )
END
IF COL_LENGTH('dbo.GlassPricingSetup', 'TurnAroundDays') IS NULL
BEGIN
    ALTER TABLE dbo.GlassPricingSetup ADD TurnAroundDays NVARCHAR(100) NULL
END", conn);
            cmd.ExecuteNonQuery();
        }

        private string DetectPriorityGlassThickness(SqlConnection conn, string orderId)
        {
            const string query = "SELECT Description, Note, ItemCode FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID ORDER BY LineID";
            using var cmd = new SqlCommand(query, conn);
            cmd.Parameters.AddWithValue("@OrderID", orderId);

            bool has3mm = false;
            bool has6mm = false;
            bool has10mm = false;
            bool has12mm = false;

            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string combined = string.Join(" ", new[]
                {
                    rdr["Description"]?.ToString() ?? string.Empty,
                    rdr["Note"]?.ToString() ?? string.Empty,
                    rdr["ItemCode"]?.ToString() ?? string.Empty
                });

                if (ContainsGlassThickness(combined, "12mm")) has12mm = true;
                if (ContainsGlassThickness(combined, "10mm")) has10mm = true;
                if (ContainsGlassThickness(combined, "6mm")) has6mm = true;
                if (ContainsGlassThickness(combined, "3mm")) has3mm = true;
            }

            if (has12mm) return "12mm";
            if (has10mm) return "10mm";
            if (has6mm) return "6mm";
            if (has3mm) return "3mm";
            return string.Empty;
        }

        private static bool ContainsGlassThickness(string source, string thickness)
        {
            if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(thickness))
                return false;

            string normalizedSource = Regex.Replace(source, @"\s+", string.Empty);
            string normalizedThickness = Regex.Replace(thickness, @"\s+", string.Empty);
            return normalizedSource.IndexOf(normalizedThickness, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private string LoadTurnAroundDaysForThickness(SqlConnection conn, string thickness)
        {
            if (string.IsNullOrWhiteSpace(thickness))
                return string.Empty;

            string normalizedThickness = Regex.Replace(thickness, @"\s+", string.Empty).ToUpperInvariant();
            string numericThickness = Regex.Replace(thickness, "[^0-9]", string.Empty);

            using var cmd = new SqlCommand(@"
SELECT TOP 1 ISNULL(TurnAroundDays, '')
FROM dbo.GlassPricingSetup
WHERE REPLACE(UPPER(ISNULL(Units, '')), ' ', '') IN (@Thickness, @NumericThickness)
ORDER BY CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(TurnAroundDays, ''))), '') IS NULL THEN 1 ELSE 0 END,
         UOM,
         Units", conn);
            cmd.Parameters.AddWithValue("@Thickness", normalizedThickness);
            cmd.Parameters.AddWithValue("@NumericThickness", numericThickness);

            var result = cmd.ExecuteScalar();
            return result == null || result == DBNull.Value ? string.Empty : result.ToString() ?? string.Empty;
        }

        private static int ParseTurnAroundLeadDays(string turnAroundDaysText)
        {
            if (string.IsNullOrWhiteSpace(turnAroundDaysText))
                return 0;

            var matches = Regex.Matches(turnAroundDaysText, @"\d+");
            int maxValue = 0;
            foreach (Match match in matches)
            {
                if (int.TryParse(match.Value, out int parsedValue) && parsedValue > maxValue)
                    maxValue = parsedValue;
            }

            return maxValue;
        }

        // Build simple items text for printing
        private string BuildOrderItemsText(string orderId, string? customerName = null, string? locationName = null)
        {
            var sb = new StringBuilder();
            try
            {
                sb.AppendLine(GlobalSettings.CompanyName);
                sb.AppendLine(GlobalSettings.CompanyTagline);
                if (!string.IsNullOrWhiteSpace(locationName))
                    sb.AppendLine($"Location: {locationName}");
                sb.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                if (!string.IsNullOrWhiteSpace(customerName))
                {
                    sb.AppendLine($"Customer: {customerName}");
                    sb.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                }
                sb.AppendLine($"ORDER: {orderId}");
                sb.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT Quantity, Description, ItemCode, Price, Note FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID ORDER BY LineID", conn);
                cmd.Parameters.AddWithValue("@OrderID", orderId);
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    decimal qty = rdr["Quantity"] != DBNull.Value ? Convert.ToDecimal(rdr["Quantity"]) : 0m;
                    string desc = rdr["Description"]?.ToString() ?? string.Empty;
                    string code = rdr["ItemCode"]?.ToString() ?? string.Empty;
                    decimal price = rdr["Price"] != DBNull.Value ? Convert.ToDecimal(rdr["Price"]) : 0m;
                    string note = rdr["Note"]?.ToString() ?? string.Empty;

                    string qtyStr = qty % 1 == 0 ? ((long)qty).ToString() : qty.ToString("0.##");
                    sb.AppendLine($"{qtyStr} x {desc}");
                    // if (!string.IsNullOrWhiteSpace(code)) sb.AppendLine($"  [{code}] @ {price:0.##}");
                    if (!string.IsNullOrWhiteSpace(note)) sb.AppendLine($"  Note: {note}");
                    // Add an empty line after each item for better separation on receipts
                    // sb.AppendLine();
                }
                sb.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                sb.AppendLine("Thank you for your order!");
            }
            catch { }
            return sb.ToString();
        }

        // Find a likely POS58 printer
        private string? FindPos58Printer()
        {
            try
            {
                foreach (string pn in System.Drawing.Printing.PrinterSettings.InstalledPrinters)
                {
                    var low = pn.ToLowerInvariant();
                    if (low.Contains("58") || low.Contains("pos") || low.Contains("thermal") || low.Contains("epson") || low.Contains("tm"))
                        return pn;
                }
            }
            catch { }
            return null;
        }

        // Shared worker used by the Sync button and on-open sync
        private async Task DoSyncAndRefreshAsync()
        {
            _isOrderSyncRunning = true;
            SetActionControlsEnabled(false);
            var previousCursor = Cursor.Current;
            Cursor.Current = Cursors.WaitCursor;
            try
            {
                // Determine current warehouse selection (best-effort). If none is selected, do not sync.
                var currentWarehouseIds = TryGetCurrentWarehouseIds();
                if (currentWarehouseIds == null || currentWarehouseIds.Count == 0)
                {
                    try
                    {
                        this.Invoke(new Action(() =>
                        {
                            progressBar.Visible = false;
                            statusLabel.Text = "No current warehouse selected. Open Warehouse Setup and tick Current_Warehouse.";
                            try { statusLabel.Font = new System.Drawing.Font(statusLabel.Font.FontFamily, 10.0f, System.Drawing.FontStyle.Bold); } catch { }
                        }));
                    }
                    catch { }

                    try { System.Diagnostics.Trace.TraceWarning("OnlineOrdersForm: Skipping sync because no Current_Warehouse is selected in Warehouses."); } catch { }
                    return;
                }

                bool isProductionWarehouse = false;
                try { isProductionWarehouse = TryIsProductionWarehouseSelected(currentWarehouseIds); } catch { isProductionWarehouse = false; }

                // Show status on UI (make it prominent)
                try
                {
                    this.Invoke(new Action(() =>
                    {
                        statusLabel.Text = "Syncing orders...";
                        progressBar.Visible = true;
                        try { statusLabel.Font = new System.Drawing.Font(statusLabel.Font.FontFamily, 12.0f, System.Drawing.FontStyle.Bold); } catch { }
                    }));
                }
                catch { }

                var sw = System.Diagnostics.Stopwatch.StartNew();
                var table = await IntegrationEvents.SyncOrderListAsync(TimeSpan.FromSeconds(30)).ConfigureAwait(false);
                sw.Stop();

                // Filter to current warehouse and remove non-matching orders from local DB (best-effort)
                int skippedOtherWarehouseCount = 0;
                try
                {
                    if (table != null && table.Rows.Count > 0)
                    {
                        bool hasLoc = table.Columns.Contains("LocationID");
                        bool hasOrderId = table.Columns.Contains("OrderID");

                        if (hasLoc && hasOrderId)
                        {
                            // If production warehouse: keep all current-location orders; also keep cross-location orders
                            // if they have a custom/transfer line override (based on persisted dbo.OnlineOrderLines).
                            System.Collections.Generic.HashSet<string> customOrderIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                            if (isProductionWarehouse)
                            {
                                try
                                {
                                    var allOrderIds = new System.Collections.Generic.List<string>();
                                    foreach (System.Data.DataRow rr in table.Rows)
                                    {
                                        try
                                        {
                                            var oid0 = (rr["OrderID"] as string) ?? string.Empty;
                                            oid0 = oid0.Trim();
                                            if (!string.IsNullOrWhiteSpace(oid0)) allOrderIds.Add(oid0);
                                        }
                                        catch { }
                                    }

                                    if (allOrderIds.Count > 0)
                                        customOrderIds = TryGetOrderIdsWithCustomLines(allOrderIds);
                                }
                                catch { }
                            }

                            var keep = table.Clone();
                            var toDeleteOrderIds = new System.Collections.Generic.List<string>();

                            foreach (System.Data.DataRow rr in table.Rows)
                            {
                                string loc = string.Empty;
                                string oid = string.Empty;
                                try { loc = (rr["LocationID"] as string) ?? string.Empty; } catch { loc = string.Empty; }
                                try { oid = (rr["OrderID"] as string) ?? string.Empty; } catch { oid = string.Empty; }
                                loc = (loc ?? string.Empty).Trim();
                                oid = (oid ?? string.Empty).Trim();

                                bool isCurrentLocation = !string.IsNullOrWhiteSpace(loc) && currentWarehouseIds.Contains(loc);
                                bool keepRow = isCurrentLocation;

                                if (!keepRow && isProductionWarehouse)
                                {
                                    // In production mode, keep cross-location orders with custom/transfer lines.
                                    try
                                    {
                                        if (!string.IsNullOrWhiteSpace(oid) && customOrderIds.Contains(oid))
                                            keepRow = true;
                                    }
                                    catch { }
                                }

                                if (keepRow)
                                {
                                    try { keep.ImportRow(rr); } catch { }
                                }
                                else
                                {
                                    skippedOtherWarehouseCount++;
                                    if (!string.IsNullOrWhiteSpace(oid))
                                        toDeleteOrderIds.Add(oid);
                                }
                            }

                            // Remove any non-matching orders that were persisted by the sync
                            try { DeleteOnlineOrdersById(toDeleteOrderIds); } catch { }

                            table = keep;
                        }
                        else
                        {
                            try { System.Diagnostics.Trace.TraceWarning("OnlineOrdersForm: Sync table missing LocationID/OrderID; cannot filter by current warehouse."); } catch { }
                        }
                    }
                }
                catch
                {
                    // best-effort
                }

                // Validate LocationID -> Warehouse Name mapping (best-effort)
                var warehouseNameById = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                var unknownLocationIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                try
                {
                    var locationIds = new System.Collections.Generic.List<string>();
                    if (table != null && table.Columns.Contains("LocationID") && table.Rows.Count > 0)
                    {
                        foreach (System.Data.DataRow rr in table.Rows)
                        {
                            try
                            {
                                var loc = (rr["LocationID"] as string) ?? string.Empty;
                                if (!string.IsNullOrWhiteSpace(loc)) locationIds.Add(loc);
                            }
                            catch { }
                        }
                    }

                    if (locationIds.Count > 0)
                    {
                        warehouseNameById = TryGetWarehouseNamesById(locationIds);
                        foreach (var loc in locationIds)
                        {
                            try
                            {
                                var key = (loc ?? string.Empty).Trim();
                                if (string.IsNullOrWhiteSpace(key)) continue;
                                if (!warehouseNameById.TryGetValue(key, out var nm) || string.IsNullOrWhiteSpace(nm))
                                    unknownLocationIds.Add(key);
                            }
                            catch { }
                        }
                    }
                }
                catch { }

                // Persist validated location names into OnlineOrderHeader (Location_Name column)
                try
                {
                    ValidateAndPersistLocationNames(table, warehouseNameById);
                }
                catch { }

                // Collect OrderIDs and CustomerName for rows with Status == "Confirmed" (case-insensitive)
                int confirmedCount = 0;
                var confirmedOrderPairs = new System.Collections.Generic.List<string>();
                try
                {
                    if (table != null && table.Rows.Count > 0)
                    {
                        foreach (System.Data.DataRow rr in table.Rows)
                        {
                            var s = (rr["Status"] as string) ?? string.Empty;
                            if (string.Equals(s, "Confirmed", StringComparison.OrdinalIgnoreCase))
                            {
                                confirmedCount++;
                                try
                                {
                                    var oid = rr.Table.Columns.Contains("OrderID") ? (rr["OrderID"] as string ?? string.Empty) : string.Empty;
                                    var cname = rr.Table.Columns.Contains("CustomerName") ? (rr["CustomerName"] as string ?? string.Empty) : string.Empty;
                                    var locId = rr.Table.Columns.Contains("LocationID") ? (rr["LocationID"] as string ?? string.Empty) : string.Empty;
                                    var locName = string.Empty;
                                    try
                                    {
                                        var lk = (locId ?? string.Empty).Trim();
                                        if (!string.IsNullOrWhiteSpace(lk))
                                            warehouseNameById.TryGetValue(lk, out locName);
                                    }
                                    catch { locName = string.Empty; }

                                    // Prefer a Location_Name column from the sync payload if present.
                                    try
                                    {
                                        if (string.IsNullOrWhiteSpace(locName) && rr.Table.Columns.Contains("Location_Name"))
                                        {
                                            var ln = (rr["Location_Name"] as string) ?? string.Empty;
                                            if (!string.IsNullOrWhiteSpace(ln)) locName = ln;
                                        }
                                    }
                                    catch { }
                                    string pair = oid;
                                    if (!string.IsNullOrWhiteSpace(cname))
                                    {
                                        pair = string.IsNullOrWhiteSpace(oid) ? cname : $"{oid} ({cname})";
                                    }

                                    // Append warehouse/location name if we can resolve it
                                    if (!string.IsNullOrWhiteSpace(locName))
                                    {
                                        pair = string.IsNullOrWhiteSpace(pair) ? locName : $"{pair} - {locName}";
                                    }
                                    if (!string.IsNullOrWhiteSpace(pair)) confirmedOrderPairs.Add(pair);
                                }
                                catch { }
                            }
                        }
                    }
                }
                catch { }

                // Format elapsed time succinctly
                string elapsedStr;
                try
                {
                    var ts = sw.Elapsed;
                    if (ts.TotalMinutes >= 1)
                        elapsedStr = $"{(int)ts.TotalMinutes}m {ts.Seconds}s";
                    else
                        elapsedStr = $"{ts.Seconds}s";
                }
                catch { elapsedStr = "-"; }

                // Refresh grid and update status with completion (include elapsed time)
                if (this.IsHandleCreated)
                {
                    this.Invoke(new Action(() =>
                    {
                        RefreshGridFromDb();
                        string warn = string.Empty;
                        try
                        {
                            if (unknownLocationIds != null && unknownLocationIds.Count > 0)
                                warn = $" - {unknownLocationIds.Count} unknown LocationID(s)";
                        }
                        catch { warn = string.Empty; }

                        try
                        {
                            if (skippedOtherWarehouseCount > 0)
                                warn = string.IsNullOrWhiteSpace(warn) ? $" - skipped {skippedOtherWarehouseCount} other location order(s)" : (warn + $" - skipped {skippedOtherWarehouseCount} other location order(s)");
                        }
                        catch { }

                        statusLabel.Text = $"Last sync: {DateTime.Now:MMMM dd, yyyy HH:mm} (took {elapsedStr}){warn}";
                        try
                        {
                            // Make the last-sync status more prominent
                            statusLabel.Font = new System.Drawing.Font(statusLabel.Font.FontFamily, 11.0f, System.Drawing.FontStyle.Bold);
                        }
                        catch { }
                        progressBar.Visible = false;
                        // keep the message box for manual sync only
                        // MessageBox.Show($"Synchronized {table.Rows.Count} online orders (persisted).", "Sync Complete", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }));

                    // Trace unknown locations for diagnostics (best-effort)
                    try
                    {
                        if (unknownLocationIds != null && unknownLocationIds.Count > 0)
                        {
                            string idsCsv = string.Empty;
                            try { idsCsv = string.Join(", ", new System.Collections.Generic.List<string>(unknownLocationIds)); } catch { idsCsv = string.Empty; }
                            System.Diagnostics.Trace.TraceWarning($"OnlineOrdersForm: Unknown LocationID(s) found during sync: {idsCsv}");
                        }
                    }
                    catch { }

                    // After a successful sync, attempt to resend any local transactions that previously failed to send.
                    try
                    {
                        _ = System.Threading.Tasks.Task.Run(() =>
                        {
                            try
                            {
                                int sent = OnlinefunctionsEvents.SendFailedTransactionToCloud();
                                try { System.Diagnostics.Trace.TraceInformation($"OnlineOrdersForm: Resent {sent} failed local transactions to cloud after sync."); } catch { }
                            }
                            catch (Exception ex)
                            {
                                try { System.Diagnostics.Trace.TraceError($"OnlineOrdersForm: Resend failed transactions failed: {ex}"); } catch { }
                            }
                        });
                    }
                    catch { }
                }

                // If there were any newly-synced Confirmed orders, notify admin (if configured)
                try
                {
                    if (confirmedCount > 0)
                    {
                        _ = Task.Run(async () =>
                        {
                            try
                            {
                                if (!string.IsNullOrWhiteSpace(GlobalSettings.AdminPageId) && GlobalSettings.AdminConversationIds != null && GlobalSettings.AdminConversationIds.Length > 0)
                                {
                                    string idsCsv = string.Empty;
                                    try { idsCsv = string.Join(", ", confirmedOrderPairs); } catch { idsCsv = string.Empty; }
                                    string extra = "Please pull this order in the POS and follow next steps. Thank you";
                                    string header = confirmedCount > 0
                                        ? $"Hi Admin, There are {confirmedCount} new confirmed online orders{(string.IsNullOrWhiteSpace(idsCsv) ? "." : $": {idsCsv}")}"
                                        : "There are new confirmed online orders.";
                                    string msg = header + Environment.NewLine + extra;
                                    // Pass the first OrderID (raw id) in the orderId parameter for traceability.
                                    var firstOrderId = string.Empty;
                                    try
                                    {
                                        if (confirmedOrderPairs.Count > 0)
                                        {
                                            var p = confirmedOrderPairs[0] ?? string.Empty;
                                            var idx = p.IndexOf(" (");
                                            firstOrderId = idx > 0 ? p.Substring(0, idx) : p;
                                        }
                                    }
                                    catch { firstOrderId = string.Empty; }
                                    // Send to all configured admin conversation IDs
                                    foreach (var conv in GlobalSettings.AdminConversationIds)
                                    {
                                        try
                                        {
                                            if (string.IsNullOrWhiteSpace(conv)) continue;
                                            await IntegrationEvents.sendneworderupdatetoADMIN(firstOrderId, GlobalSettings.AdminPageId, conv, msg).ConfigureAwait(false);
                                        }
                                        catch (Exception ex)
                                        {
                                            try { System.Diagnostics.Trace.TraceError($"sendneworderupdatetoADMIN to {conv} failed: {ex}"); } catch { }
                                        }
                                    }
                                }
                                else
                                {
                                    try { System.Diagnostics.Trace.TraceInformation("AdminPageId or AdminConversationId not configured; skipping admin notification."); } catch { }
                                }
                            }
                            catch (Exception ex)
                            {
                                try { System.Diagnostics.Trace.TraceError($"sendneworderupdatetoADMIN failed: {ex}"); } catch { }
                            }
                        });
                    }
                }
                catch { }
            }
            catch (HttpRequestException hre)
            {
                try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; MessageBox.Show($"Network error while syncing: {hre.Message}", "Sync Error", MessageBoxButtons.OK, MessageBoxIcon.Error); })); } catch { }
            }
            catch (TaskCanceledException)
            {
                try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; MessageBox.Show("Request timed out while syncing orders.", "Sync Error", MessageBoxButtons.OK, MessageBoxIcon.Error); })); } catch { }
            }
            catch (InvalidOperationException ioe) when (ioe.Message?.StartsWith("Database error", StringComparison.OrdinalIgnoreCase) == true)
            {
                // This indicates a DB connection/persistence failure surfaced from IntegrationEvents or FetchAndPersistOrderLinesAsync
                try { this.Invoke(new Action(() => { statusLabel.Text = "Database error during sync"; progressBar.Visible = false; MessageBox.Show($"Database error while syncing orders: {ioe.InnerException?.Message ?? ioe.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error); })); } catch { }
            }
            catch (Exception ex)
            {
                try { this.Invoke(new Action(() => { statusLabel.Text = string.Empty; progressBar.Visible = false; MessageBox.Show($"Error syncing online orders: {ex.Message}", "Sync Error", MessageBoxButtons.OK, MessageBoxIcon.Error); })); } catch { }
            }
            finally
            {
                _isOrderSyncRunning = false;
                try { SetActionControlsEnabled(true); } catch { }
                try { Cursor.Current = previousCursor; } catch { }
            }
        }
    }
}
