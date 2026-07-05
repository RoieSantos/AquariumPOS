using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Linq;
using System.Runtime.Versioning;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AquariumPOS
{
    /// <summary>
    /// Warehouse Setup form backed by the existing Warehouses table.
    /// - Displays all columns
    /// - Only allows editing Current_Warehouse, Is_Production_Warehouse, Is_Warehouse_Stocks, and Default_Customer
    /// - Auto-saves those flag changes to DB
    /// </summary>
    [SupportedOSPlatform("windows")]
    public class WarehouseSetupForm : Form
    {
        private static readonly string[] EditableColumnNames = new[]
        {
            "Current_Warehouse",
            "Is_Production_Warehouse",
            "Is_Warehouse_Stocks",
            "Default_Customer",
        };

        private readonly DataGridView dgv = new DataGridView();
        private readonly Button btnSync = new Button();
        private readonly Button btnRefresh = new Button();

        private readonly DataTable table = new DataTable();
        private readonly BindingSource binding = new BindingSource();
        private SqlDataAdapter adapter = null!;
        private List<string> customerLookupNames = new List<string>();
        private readonly Dictionary<string, string> customerLookupIdsByName = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        private readonly string connectionString = GlobalSettings.ConnectionString;
        private bool isLoading;
        private object? editOriginalValue;
        private string warehousesTableName = "dbo.Warehouses";

        public WarehouseSetupForm()
        {
            Text = "Warehouse Setup";
            Size = new Size(1000, 650);
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.Sizable;
            InitializeComponent();
        }

        private void InitializeComponent()
        {
            dgv.Dock = DockStyle.Top;
            dgv.Height = ClientSize.Height - 80;
            dgv.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
            dgv.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            dgv.MultiSelect = false;
            dgv.AllowUserToAddRows = false;
            dgv.AllowUserToDeleteRows = false;
            dgv.ReadOnly = false; // per-column read-only rules applied after binding
            dgv.CellBeginEdit += Dgv_CellBeginEdit;
            dgv.CellEndEdit += Dgv_CellEndEdit;
            dgv.DataError += (s, e) => { e.ThrowException = false; };

            btnSync.Text = "Sync";
            btnSync.Size = new Size(110, 36);
            btnSync.Location = new Point(10, ClientSize.Height - 70);
            btnSync.Anchor = AnchorStyles.Left | AnchorStyles.Bottom;
            btnSync.BackColor = Color.SteelBlue;
            btnSync.ForeColor = Color.White;
            btnSync.Font = new Font("Arial", 9, FontStyle.Bold);
            btnSync.Click += async (s, e) => await BtnSync_ClickAsync();

            btnRefresh.Text = "Refresh";
            btnRefresh.Size = new Size(110, 36);
            btnRefresh.Location = new Point(130, ClientSize.Height - 70);
            btnRefresh.Anchor = AnchorStyles.Left | AnchorStyles.Bottom;
            btnRefresh.Click += (s, e) => LoadData();

            Controls.Add(dgv);
            Controls.AddRange(new Control[] { btnSync, btnRefresh });

            Load += (s, e) => LoadData();
            Resize += (s, e) =>
            {
                dgv.Height = ClientSize.Height - 80;
                btnSync.Location = new Point(10, ClientSize.Height - 70);
                btnRefresh.Location = new Point(130, ClientSize.Height - 70);
            };
        }

        private void LoadData()
        {
            try
            {
                isLoading = true;
                table.Clear();

                EnsureDefaultCustomerColumnExists();

                adapter = new SqlDataAdapter("SELECT * FROM dbo.Warehouses", connectionString);
                adapter.MissingSchemaAction = MissingSchemaAction.AddWithKey;

                try { adapter.FillSchema(table, SchemaType.Source); } catch { }

                try
                {
                    adapter.Fill(table);
                    warehousesTableName = "dbo.Warehouses";
                }
                catch
                {
                    table.Clear();
                    adapter = new SqlDataAdapter("SELECT * FROM Warehouses", connectionString);
                    adapter.MissingSchemaAction = MissingSchemaAction.AddWithKey;
                    try { adapter.FillSchema(table, SchemaType.Source); } catch { }
                    adapter.Fill(table);
                    warehousesTableName = "Warehouses";
                }

                binding.DataSource = table;
                dgv.DataSource = binding;

                EnsureEditableFlagColumnsAreCheckboxes();
                EnsureDefaultCustomerColumnIsLookup();
                EnsureDefaultCustomerIdColumnPresentation();

                ApplyColumnEditRules();

                foreach (DataGridViewColumn col in dgv.Columns)
                {
                    col.SortMode = DataGridViewColumnSortMode.NotSortable;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load Warehouses: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                isLoading = false;
            }
        }

        private void EnsureCurrentWarehouseColumnIsCheckbox()
        {
            try
            {
                // legacy method retained for compatibility; now handled by EnsureEditableFlagColumnsAreCheckboxes
            }
            catch
            {
                // best-effort
            }
        }

        private void EnsureEditableFlagColumnsAreCheckboxes()
        {
            try
            {
                foreach (var columnName in EditableColumnNames)
                {
                    if (string.Equals(columnName, "Default_Customer", StringComparison.OrdinalIgnoreCase))
                        continue;
                    try { EnsureEditableFlagColumnIsCheckbox(columnName); } catch { }
                }
            }
            catch
            {
                // best-effort
            }
        }

        private void EnsureEditableFlagColumnIsCheckbox(string columnName)
        {
            if (string.IsNullOrWhiteSpace(columnName)) return;
            if (!table.Columns.Contains(columnName) || !dgv.Columns.Contains(columnName)) return;

            // If the backing DB column is a BIT, a checkbox column avoids blank/cleared rendering.
            bool shouldBeCheckbox = false;
            var dc = table.Columns[columnName];
            if (dc == null) return;

            if (dc.DataType == typeof(bool))
            {
                shouldBeCheckbox = true;
            }
            else
            {
                var sqlType = GetSqlDbTypeForColumn(columnName);
                if (sqlType == SqlDbType.Bit)
                    shouldBeCheckbox = true;
            }

            if (!shouldBeCheckbox) return;

            if (dgv.Columns[columnName] is DataGridViewCheckBoxColumn)
                return;

            int displayIndex = dgv.Columns[columnName].DisplayIndex;
            string headerText = dgv.Columns[columnName].HeaderText;
            dgv.Columns.Remove(columnName);

            var chk = new DataGridViewCheckBoxColumn()
            {
                Name = columnName,
                DataPropertyName = columnName,
                HeaderText = headerText,
                ValueType = typeof(bool),
                TrueValue = true,
                FalseValue = false,
                IndeterminateValue = false,
                ThreeState = false,
                AutoSizeMode = DataGridViewAutoSizeColumnMode.None,
                Width = 140,
            };
            chk.DefaultCellStyle.NullValue = false;
            dgv.Columns.Insert(Math.Min(displayIndex, dgv.Columns.Count), chk);
        }

        private void EnsureDefaultCustomerColumnExists()
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();

            const string sql = @"
IF OBJECT_ID('dbo.Warehouses', 'U') IS NOT NULL AND COL_LENGTH('dbo.Warehouses', 'Is_Warehouse_Stocks') IS NULL
BEGIN
    ALTER TABLE dbo.Warehouses ADD Is_Warehouse_Stocks BIT NOT NULL CONSTRAINT DF_Warehouses_IsWarehouseStocks DEFAULT 0;
END

IF OBJECT_ID('dbo.Warehouses', 'U') IS NOT NULL AND COL_LENGTH('dbo.Warehouses', 'Default_Customer') IS NULL
BEGIN
    ALTER TABLE dbo.Warehouses ADD Default_Customer NVARCHAR(255) NULL;
END

IF OBJECT_ID('dbo.Warehouses', 'U') IS NOT NULL AND COL_LENGTH('dbo.Warehouses', 'Default_Customer_ID') IS NULL
BEGIN
    ALTER TABLE dbo.Warehouses ADD Default_Customer_ID NVARCHAR(100) NULL;
END

IF OBJECT_ID('Warehouses', 'U') IS NOT NULL AND COL_LENGTH('Warehouses', 'Default_Customer') IS NULL
BEGIN
    ALTER TABLE Warehouses ADD Default_Customer NVARCHAR(255) NULL;
END

IF OBJECT_ID('Warehouses', 'U') IS NOT NULL AND COL_LENGTH('Warehouses', 'Is_Warehouse_Stocks') IS NULL
BEGIN
    ALTER TABLE Warehouses ADD Is_Warehouse_Stocks BIT NOT NULL CONSTRAINT DF_Warehouses_IsWarehouseStocks_Legacy DEFAULT 0;
END

IF OBJECT_ID('Warehouses', 'U') IS NOT NULL AND COL_LENGTH('Warehouses', 'Default_Customer_ID') IS NULL
BEGIN
    ALTER TABLE Warehouses ADD Default_Customer_ID NVARCHAR(100) NULL;
END";

            using var cmd = new SqlCommand(sql, conn);
            cmd.ExecuteNonQuery();
        }

        private void EnsureDefaultCustomerColumnIsLookup()
        {
            const string columnName = "Default_Customer";
            if (!table.Columns.Contains(columnName) || !dgv.Columns.Contains(columnName))
                return;

            customerLookupNames = LoadCustomerLookupNames();

            if (dgv.Columns[columnName] is DataGridViewComboBoxColumn existingCombo)
            {
                existingCombo.DataSource = null;
                existingCombo.Items.Clear();
                existingCombo.Items.AddRange(customerLookupNames.Cast<object>().ToArray());
                existingCombo.HeaderText = "Default Customer";
                return;
            }

            int displayIndex = dgv.Columns[columnName].DisplayIndex;
            dgv.Columns.Remove(columnName);

            var combo = new DataGridViewComboBoxColumn
            {
                Name = columnName,
                DataPropertyName = columnName,
                HeaderText = "Default Customer",
                DisplayStyle = DataGridViewComboBoxDisplayStyle.DropDownButton,
                FlatStyle = FlatStyle.Flat,
                AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill,
                FillWeight = 180,
                DataSource = customerLookupNames.ToList()
            };

            dgv.Columns.Insert(Math.Min(displayIndex, dgv.Columns.Count), combo);
        }

        private void EnsureDefaultCustomerIdColumnPresentation()
        {
            const string columnName = "Default_Customer_ID";
            if (!table.Columns.Contains(columnName) || !dgv.Columns.Contains(columnName))
                return;

            var column = dgv.Columns[columnName];
            column.HeaderText = "Default Customer ID";
            column.ReadOnly = true;
            column.AutoSizeMode = DataGridViewAutoSizeColumnMode.AllCells;
            column.DefaultCellStyle.BackColor = Color.WhiteSmoke;
        }

        private List<string> LoadCustomerLookupNames()
        {
            var names = new List<string> { string.Empty };
            customerLookupIdsByName.Clear();

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                const string sql = @"
IF OBJECT_ID('dbo.OnlineCustomers', 'U') IS NULL
BEGIN
    SELECT CAST(NULL AS NVARCHAR(255)) AS Name, CAST(NULL AS NVARCHAR(100)) AS CustomerID WHERE 1 = 0;
END
ELSE
BEGIN
    SELECT
        LTRIM(RTRIM(ISNULL(Name, ''))) AS Name,
        LTRIM(RTRIM(ISNULL(CustomerID, ''))) AS CustomerID
    FROM dbo.OnlineCustomers
    WHERE LTRIM(RTRIM(ISNULL(Name, ''))) <> ''
    ORDER BY Name, UpdatedAt DESC, LastSyncedUtc DESC;
END";

                using var cmd = new SqlCommand(sql, conn);
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    var name = reader["Name"]?.ToString()?.Trim() ?? string.Empty;
                    var customerId = reader["CustomerID"]?.ToString()?.Trim() ?? string.Empty;
                    if (!string.IsNullOrWhiteSpace(name) && !names.Any(existing => string.Equals(existing, name, StringComparison.OrdinalIgnoreCase)))
                    {
                        names.Add(name);
                    }

                    if (!string.IsNullOrWhiteSpace(name) && !customerLookupIdsByName.ContainsKey(name))
                    {
                        customerLookupIdsByName[name] = customerId;
                    }
                }
            }
            catch
            {
                // Best-effort lookup population. The column still remains editable even if no customers are available.
            }

            foreach (DataRow row in table.Rows)
            {
                if (!table.Columns.Contains("Default_Customer"))
                    break;

                var existingValue = row["Default_Customer"]?.ToString()?.Trim() ?? string.Empty;
                if (!string.IsNullOrWhiteSpace(existingValue) && !names.Any(existing => string.Equals(existing, existingValue, StringComparison.OrdinalIgnoreCase)))
                {
                    names.Add(existingValue);
                }
            }

            return names
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(name => string.IsNullOrWhiteSpace(name) ? string.Empty : name)
                .ToList();
        }

        private string ResolveCustomerIdByName(string? customerName)
        {
            string normalizedName = customerName?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(normalizedName))
                return string.Empty;

            return customerLookupIdsByName.TryGetValue(normalizedName, out var customerId)
                ? customerId?.Trim() ?? string.Empty
                : string.Empty;
        }

        private void SyncDefaultCustomerIdForRow(DataRow row)
        {
            if (row == null || !table.Columns.Contains("Default_Customer_ID"))
                return;

            string customerName = table.Columns.Contains("Default_Customer")
                ? row["Default_Customer"]?.ToString()?.Trim() ?? string.Empty
                : string.Empty;
            string customerId = ResolveCustomerIdByName(customerName);
            row["Default_Customer_ID"] = string.IsNullOrWhiteSpace(customerId)
                ? (object)DBNull.Value
                : customerId;
        }

        private void ApplyColumnEditRules()
        {
            foreach (DataGridViewColumn col in dgv.Columns)
            {
                bool isEditable = IsEditableFlagColumn(col);

                col.ReadOnly = !isEditable;
                if (isEditable)
                {
                    col.DefaultCellStyle.BackColor = Color.LightYellow;
                }
            }
        }

        private bool IsEditableFlagColumn(DataGridViewColumn col)
        {
            if (col == null) return false;
            foreach (var editable in EditableColumnNames)
            {
                if (string.Equals(col.DataPropertyName, editable, StringComparison.OrdinalIgnoreCase)) return true;
                if (string.Equals(col.Name, editable, StringComparison.OrdinalIgnoreCase)) return true;
                if (string.Equals(col.HeaderText, editable, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private void Dgv_CellBeginEdit(object? sender, DataGridViewCellCancelEventArgs e)
        {
            try
            {
                var col = dgv.Columns[e.ColumnIndex];
                bool isEditable = IsEditableFlagColumn(col);

                if (!isEditable)
                {
                    e.Cancel = true;
                    return;
                }

                editOriginalValue = dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value;
            }
            catch
            {
                e.Cancel = true;
            }
        }

        private void Dgv_CellEndEdit(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (isLoading)
                    return;

                var col = dgv.Columns[e.ColumnIndex];
                bool isEditable = IsEditableFlagColumn(col);
                if (!isEditable)
                    return;

                string editedColumnName = col.DataPropertyName;
                if (string.IsNullOrWhiteSpace(editedColumnName)) editedColumnName = col.Name;
                if (string.IsNullOrWhiteSpace(editedColumnName)) editedColumnName = string.Empty;

                dgv.CommitEdit(DataGridViewDataErrorContexts.Commit);
                binding.EndEdit();

                var newValue = dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value;
                bool changed;
                if (editOriginalValue == null && newValue == null) changed = false;
                else if (editOriginalValue == null || newValue == null) changed = true;
                else changed = !string.Equals(Convert.ToString(editOriginalValue), Convert.ToString(newValue), StringComparison.Ordinal);

                if (!changed)
                    return;

                if (dgv.Rows[e.RowIndex].DataBoundItem is not DataRowView drv)
                    return;

                if (string.Equals(editedColumnName, "Default_Customer", StringComparison.OrdinalIgnoreCase))
                {
                    SyncDefaultCustomerIdForRow(drv.Row);
                }

                SaveWarehouseFlag(drv, editedColumnName);
                drv.Row.AcceptChanges();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this,
                    $"Failed to save warehouse flag change.\n\n{ex.Message}",
                    "Save Error",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);

                try
                {
                    table.RejectChanges();
                    binding.ResetBindings(false);
                }
                catch { }
            }
        }

        private void SaveWarehouseFlag(DataRowView row, string columnName)
        {
            if (string.IsNullOrWhiteSpace(columnName))
                throw new InvalidOperationException("Unable to determine which column was edited.");

            // Only allow saving for explicitly editable flag columns
            bool allowed = false;
            foreach (var editable in EditableColumnNames)
            {
                if (string.Equals(editable, columnName, StringComparison.OrdinalIgnoreCase)) { allowed = true; break; }
            }
            if (!allowed)
                throw new InvalidOperationException($"Column '{columnName}' is not editable.");

            var flagCol = table.Columns.Cast<DataColumn>()
                .FirstOrDefault(c => string.Equals(c.ColumnName, columnName, StringComparison.OrdinalIgnoreCase));
            if (flagCol == null)
                throw new InvalidOperationException($"Column '{columnName}' not found in Warehouses table.");

            // Determine key columns: prefer PK from FillSchema.
            var keyColumns = new List<DataColumn>();
            if (table.PrimaryKey != null && table.PrimaryKey.Length > 0)
            {
                keyColumns.AddRange(table.PrimaryKey);
            }
            else
            {
                // Best-effort keys
                string[] preferred = { "ShopID", "ShopId", "ID", "WarehouseID", "WarehouseId", "warehouse_id" };
                foreach (var name in preferred)
                {
                    var c = table.Columns.Cast<DataColumn>().FirstOrDefault(x => string.Equals(x.ColumnName, name, StringComparison.OrdinalIgnoreCase));
                    if (c != null) keyColumns.Add(c);
                }

                if (!keyColumns.Any(c => string.Equals(c.ColumnName, "ID", StringComparison.OrdinalIgnoreCase)
                                      || string.Equals(c.ColumnName, "WarehouseID", StringComparison.OrdinalIgnoreCase)
                                      || string.Equals(c.ColumnName, "warehouse_id", StringComparison.OrdinalIgnoreCase)))
                {
                    throw new InvalidOperationException("Unable to determine key columns for Warehouses. Add a primary key to dbo.Warehouses.");
                }
            }

            string where = string.Join(" AND ", keyColumns.Select(c => $"[{c.ColumnName}] = @{c.ColumnName}"));
            bool saveDefaultCustomerId = string.Equals(flagCol.ColumnName, "Default_Customer", StringComparison.OrdinalIgnoreCase)
                && table.Columns.Contains("Default_Customer_ID");
            string setClause = saveDefaultCustomerId
                ? $"[{flagCol.ColumnName}] = @Value, [Default_Customer_ID] = @DefaultCustomerId"
                : $"[{flagCol.ColumnName}] = @Value";
            string sql = $"UPDATE {warehousesTableName} SET {setClause} WHERE {where}";

            using (var conn = new SqlConnection(connectionString))
            {
                conn.Open();
                using (var cmd = new SqlCommand(sql, conn))
                {
                    var sqlType = GetSqlDbTypeForColumn(flagCol.ColumnName);
                    if (sqlType == SqlDbType.Bit)
                    {
                        object val = row.Row.IsNull(flagCol) ? DBNull.Value : row.Row[flagCol];
                        if (val != DBNull.Value)
                            val = CoerceToBool(val);
                        cmd.Parameters.Add("@Value", SqlDbType.Bit).Value = val;
                    }
                    else
                    {
                        // fallback for non-bit schemas
                        cmd.Parameters.Add("@Value", sqlType == SqlDbType.Variant ? SqlDbType.Variant : sqlType)
                            .Value = row.Row.IsNull(flagCol) ? DBNull.Value : row.Row[flagCol];
                    }

                    if (saveDefaultCustomerId)
                    {
                        object customerIdValue = row.Row.IsNull("Default_Customer_ID") ? DBNull.Value : row.Row["Default_Customer_ID"];
                        cmd.Parameters.Add("@DefaultCustomerId", SqlDbType.NVarChar, 100).Value = customerIdValue;
                    }

                    foreach (var k in keyColumns)
                    {
                        var keySqlType = GetSqlDbTypeForColumn(k.ColumnName);
                        if (keySqlType == SqlDbType.Bit)
                        {
                            object val = row.Row.IsNull(k) ? DBNull.Value : row.Row[k];
                            if (val != DBNull.Value)
                                val = CoerceToBool(val);
                            cmd.Parameters.Add("@" + k.ColumnName, SqlDbType.Bit).Value = val;
                        }
                        else
                        {
                            cmd.Parameters.Add("@" + k.ColumnName, keySqlType == SqlDbType.Variant ? SqlDbType.Variant : keySqlType)
                                .Value = row.Row.IsNull(k) ? DBNull.Value : row.Row[k];
                        }
                    }

                    int affected = cmd.ExecuteNonQuery();
                    if (affected <= 0)
                        throw new InvalidOperationException("No rows were updated. Check Warehouses key columns / primary key.");
                }
            }
        }

        private bool CoerceToBool(object value)
        {
            if (value is bool b) return b;
            if (value is byte by) return by != 0;
            if (value is short s) return s != 0;
            if (value is int i) return i != 0;
            if (value is long l) return l != 0;
            if (value is decimal d) return d != 0m;

            var str = Convert.ToString(value)?.Trim();
            if (string.IsNullOrEmpty(str)) return false;

            if (bool.TryParse(str, out var parsed)) return parsed;
            if (string.Equals(str, "1", StringComparison.OrdinalIgnoreCase)) return true;
            if (string.Equals(str, "0", StringComparison.OrdinalIgnoreCase)) return false;
            if (string.Equals(str, "Y", StringComparison.OrdinalIgnoreCase) || string.Equals(str, "YES", StringComparison.OrdinalIgnoreCase)) return true;
            if (string.Equals(str, "N", StringComparison.OrdinalIgnoreCase) || string.Equals(str, "NO", StringComparison.OrdinalIgnoreCase)) return false;

            return false;
        }

        private (string Schema, string Table) GetWarehousesSchemaAndName()
        {
            var s = warehousesTableName?.Trim() ?? "dbo.Warehouses";
            if (s.Contains("."))
            {
                var parts = s.Split(new[] { '.' }, 2);
                return (parts[0].Trim('[', ']', ' '), parts[1].Trim('[', ']', ' '));
            }
            return ("dbo", s.Trim('[', ']', ' '));
        }

        private SqlDbType GetSqlDbTypeForColumn(string columnName)
        {
            // Prefer mapping from live DB schema to avoid sql_variant parameter issues.
            try
            {
                var (schema, tableName) = GetWarehousesSchemaAndName();
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();

                    string? dataType = null;
                    using (var cmd = new SqlCommand(@"SELECT TOP 1 DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND COLUMN_NAME=@c AND (TABLE_SCHEMA=@s OR @s IS NULL)", conn))
                    {
                        cmd.Parameters.AddWithValue("@t", tableName);
                        cmd.Parameters.AddWithValue("@c", columnName);
                        cmd.Parameters.AddWithValue("@s", schema);
                        dataType = cmd.ExecuteScalar()?.ToString();
                    }

                    if (string.IsNullOrWhiteSpace(dataType))
                    {
                        // fallback: ignore schema
                        using (var cmd2 = new SqlCommand(@"SELECT TOP 1 DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND COLUMN_NAME=@c", conn))
                        {
                            cmd2.Parameters.AddWithValue("@t", tableName);
                            cmd2.Parameters.AddWithValue("@c", columnName);
                            dataType = cmd2.ExecuteScalar()?.ToString();
                        }
                    }

                    return MapSqlTypeNameToDbType(dataType);
                }
            }
            catch
            {
                // last resort: map from DataColumn
                var col = table.Columns.Cast<DataColumn>().FirstOrDefault(c => string.Equals(c.ColumnName, columnName, StringComparison.OrdinalIgnoreCase));
                if (col != null)
                    return MapDotNetTypeToSqlDbType(col.DataType);
                return SqlDbType.Variant;
            }
        }

        private SqlDbType MapSqlTypeNameToDbType(string? sqlType)
        {
            if (string.IsNullOrWhiteSpace(sqlType)) return SqlDbType.Variant;
            switch (sqlType.Trim().ToLowerInvariant())
            {
                case "bit": return SqlDbType.Bit;
                case "int": return SqlDbType.Int;
                case "bigint": return SqlDbType.BigInt;
                case "smallint": return SqlDbType.SmallInt;
                case "tinyint": return SqlDbType.TinyInt;
                case "decimal":
                case "numeric": return SqlDbType.Decimal;
                case "float": return SqlDbType.Float;
                case "real": return SqlDbType.Real;
                case "date": return SqlDbType.Date;
                case "datetime": return SqlDbType.DateTime;
                case "datetime2": return SqlDbType.DateTime2;
                case "smalldatetime": return SqlDbType.SmallDateTime;
                case "uniqueidentifier": return SqlDbType.UniqueIdentifier;
                case "nvarchar": return SqlDbType.NVarChar;
                case "varchar": return SqlDbType.VarChar;
                case "nchar": return SqlDbType.NChar;
                case "char": return SqlDbType.Char;
                case "text": return SqlDbType.Text;
                case "ntext": return SqlDbType.NText;
                case "sql_variant": return SqlDbType.Variant;
                default: return SqlDbType.Variant;
            }
        }

        private SqlDbType MapDotNetTypeToSqlDbType(Type t)
        {
            if (t == typeof(bool)) return SqlDbType.Bit;
            if (t == typeof(int)) return SqlDbType.Int;
            if (t == typeof(long)) return SqlDbType.BigInt;
            if (t == typeof(short)) return SqlDbType.SmallInt;
            if (t == typeof(byte)) return SqlDbType.TinyInt;
            if (t == typeof(decimal)) return SqlDbType.Decimal;
            if (t == typeof(double)) return SqlDbType.Float;
            if (t == typeof(float)) return SqlDbType.Real;
            if (t == typeof(DateTime)) return SqlDbType.DateTime2;
            if (t == typeof(Guid)) return SqlDbType.UniqueIdentifier;
            if (t == typeof(string)) return SqlDbType.NVarChar;
            return SqlDbType.Variant;
        }

        private async Task BtnSync_ClickAsync()
        {
            btnSync.Enabled = false;
            var prevCursor = Cursor;
            Cursor = Cursors.WaitCursor;

            try
            {
                int synced = await OnlinefunctionsEvents.SyncWarehouseAsync().ConfigureAwait(true);
                LoadData();
                MessageBox.Show(this, $"Synced {synced} warehouse(s).", "Warehouse Setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to sync warehouses: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                Cursor = prevCursor;
                btnSync.Enabled = true;
            }
        }
    }
}
