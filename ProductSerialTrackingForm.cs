using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using System.Threading;
using System.Threading.Tasks;

namespace AquariumPOS
{
    public class ProductSerialTrackingForm : Form
    {
        public sealed class AvailableSerialRecord
        {
            public long RunningSerialNo { get; init; }
            public string SerialNo { get; init; } = string.Empty;
            public string ItemCode { get; init; } = string.Empty;
            public string VariantCode { get; init; } = string.Empty;
            public string ItemDescription { get; init; } = string.Empty;
            public string SourceDocumentNo { get; init; } = string.Empty;
            public string DisplayText
            {
                get
                {
                    string itemSuffix = string.IsNullOrWhiteSpace(VariantCode)
                        ? ItemCode
                        : $"{ItemCode} / {VariantCode}";

                    return string.IsNullOrWhiteSpace(ItemDescription)
                        ? $"{SerialNo} ({itemSuffix})"
                        : $"{SerialNo} | {ItemDescription} ({itemSuffix})";
                }
            }
        }

        // Guards against a stampede of overlapping auto-syncs when several mutation points fire in
        // quick succession (e.g. a stock-count batch commit followed immediately by a sale) - if a
        // sync is already in flight, this trigger is skipped rather than queued, since the next
        // mutation's own trigger call will catch up anyway. Best-effort, same tolerance as every
        // other background sync in this app (masterDataSyncTimer, SendFailedTransactionToCloud).
        private static int isAutoCloudSyncRunning = 0;

        // Fires an automatic "Sync Cloud" (same call the manual button makes) in the background
        // after any local ItemSerialTracking write completes - so the Web Portal's Serial Tracker
        // (js/serialTracker.js) stays current without staff needing to remember to click Sync Cloud.
        // Must only be called AFTER the write is durable (auto-commit, or past an explicit
        // tran.Commit()) - never from inside a still-open transaction, since a rollback after this
        // fires would push data that then reverts locally.
        internal static void TriggerCloudSyncFireAndForget()
        {
            if (Interlocked.Exchange(ref isAutoCloudSyncRunning, 1) == 1)
                return;

            _ = Task.Run(async () =>
            {
                try
                {
                    await OnlinefunctionsEvents.SyncItemSerialTrackingToSupabaseAsync(TimeSpan.FromSeconds(30)).ConfigureAwait(false);
                }
                catch
                {
                    // Best-effort - the next mutation's trigger, or the manual "Sync Cloud" button, will retry.
                }
                finally
                {
                    Interlocked.Exchange(ref isAutoCloudSyncRunning, 0);
                }
            });
        }

        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly Dictionary<string, string> itemDescriptionsByCode = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> itemVariantCodesByCode = new(StringComparer.OrdinalIgnoreCase);

        private ComboBox cboItem = null!;
        private TextBox txtSourceDocument = null!;
        private TextBox txtCustomSerial = null!;
        private NumericUpDown nudQuantity = null!;
        private TextBox txtSearch = null!;
        private ComboBox cboStatusFilter = null!;
        private DataGridView dgvSerials = null!;
        private Label lblSummary = null!;
        private Button btnAddSerials = null!;
        private Button btnRefresh = null!;
        private Button btnMarkSold = null!;
        private Button btnMarkInStock = null!;
        private Button btnSyncCloud = null!;
        private Button btnDeleteSerial = null!;
        private Button btnClose = null!;

        public ProductSerialTrackingForm()
        {
            Text = "Product Serial Tracker";
            StartPosition = FormStartPosition.CenterParent;
            Size = new Size(1280, 760);
            MinimumSize = new Size(1100, 680);
            BackColor = Color.White;

            InitializeComponent();
            Load += ProductSerialTrackingForm_Load;
        }

        private void InitializeComponent()
        {
            var addPanel = new GroupBox
            {
                Text = "Add Product Serials",
                Location = new Point(12, 10),
                Size = new Size(1240, 120),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var lblItem = new Label
            {
                Text = "Product:",
                Location = new Point(16, 32),
                Size = new Size(70, 22),
                Font = new Font("Arial", 9, FontStyle.Bold)
            };

            cboItem = new ComboBox
            {
                Location = new Point(90, 28),
                Size = new Size(430, 26),
                DropDownStyle = ComboBoxStyle.DropDown,
                AutoCompleteMode = AutoCompleteMode.SuggestAppend,
                AutoCompleteSource = AutoCompleteSource.ListItems,
                Font = new Font("Arial", 9)
            };

            var lblSource = new Label
            {
                Text = "Source Doc:",
                Location = new Point(540, 32),
                Size = new Size(85, 22),
                Font = new Font("Arial", 9, FontStyle.Bold)
            };

            txtSourceDocument = new TextBox
            {
                Location = new Point(625, 28),
                Size = new Size(170, 26),
                Font = new Font("Arial", 9),
                Text = "MANUAL"
            };

            var lblQuantity = new Label
            {
                Text = "Qty:",
                Location = new Point(812, 32),
                Size = new Size(40, 22),
                Font = new Font("Arial", 9, FontStyle.Bold)
            };

            nudQuantity = new NumericUpDown
            {
                Location = new Point(852, 28),
                Size = new Size(70, 26),
                Minimum = 1,
                Maximum = 500,
                Value = 1,
                Font = new Font("Arial", 9)
            };

            var lblCustomSerial = new Label
            {
                Text = "Custom Serial:",
                Location = new Point(16, 72),
                Size = new Size(95, 22),
                Font = new Font("Arial", 9, FontStyle.Bold)
            };

            txtCustomSerial = new TextBox
            {
                Location = new Point(114, 68),
                Size = new Size(240, 26),
                Font = new Font("Arial", 9)
            };

            var lblHint = new Label
            {
                Text = "Leave Custom Serial blank to auto-generate RS-ItemCode-yy-000001 style serials using a running number.",
                Location = new Point(372, 72),
                Size = new Size(600, 22),
                Font = new Font("Arial", 8, FontStyle.Italic),
                ForeColor = Color.DimGray
            };

            btnAddSerials = new Button
            {
                Text = "Add Serials",
                Location = new Point(1050, 28),
                Size = new Size(150, 36),
                BackColor = Color.SeaGreen,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnAddSerials.Click += BtnAddSerials_Click;

            addPanel.Controls.AddRange(new Control[]
            {
                lblItem, cboItem, lblSource, txtSourceDocument, lblQuantity, nudQuantity,
                lblCustomSerial, txtCustomSerial, lblHint, btnAddSerials
            });

            var filterPanel = new GroupBox
            {
                Text = "Tracking List",
                Location = new Point(12, 138),
                Size = new Size(1240, 64),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var lblSearch = new Label
            {
                Text = "Search:",
                Location = new Point(16, 28),
                Size = new Size(60, 22),
                Font = new Font("Arial", 9, FontStyle.Bold)
            };

            txtSearch = new TextBox
            {
                Location = new Point(74, 24),
                Size = new Size(290, 26),
                Font = new Font("Arial", 9),
                PlaceholderText = "Item code, description, or serial no."
            };
            txtSearch.TextChanged += (_, _) => LoadSerials();

            var lblStatus = new Label
            {
                Text = "Status:",
                Location = new Point(384, 28),
                Size = new Size(55, 22),
                Font = new Font("Arial", 9, FontStyle.Bold)
            };

            cboStatusFilter = new ComboBox
            {
                Location = new Point(442, 24),
                Size = new Size(150, 26),
                DropDownStyle = ComboBoxStyle.DropDownList,
                Font = new Font("Arial", 9)
            };
            cboStatusFilter.Items.AddRange(new object[] { "ALL", "IN_STOCK", "SOLD" });
            cboStatusFilter.SelectedIndex = 0;
            cboStatusFilter.SelectedIndexChanged += (_, _) => LoadSerials();

            btnRefresh = new Button
            {
                Text = "Refresh",
                Location = new Point(612, 22),
                Size = new Size(100, 30),
                BackColor = Color.RoyalBlue,
                ForeColor = Color.White,
                Font = new Font("Arial", 9, FontStyle.Bold)
            };
            btnRefresh.Click += (_, _) => LoadSerials();

            btnMarkSold = new Button
            {
                Text = "Mark Selected Sold",
                Location = new Point(728, 22),
                Size = new Size(155, 30),
                BackColor = Color.IndianRed,
                ForeColor = Color.White,
                Font = new Font("Arial", 9, FontStyle.Bold)
            };
            btnMarkSold.Click += (_, _) => UpdateSelectedStatus("SOLD");

            btnMarkInStock = new Button
            {
                Text = "Mark In Stock",
                Location = new Point(895, 22),
                Size = new Size(135, 30),
                BackColor = Color.DarkOliveGreen,
                ForeColor = Color.White,
                Font = new Font("Arial", 9, FontStyle.Bold)
            };
            btnMarkInStock.Click += (_, _) => UpdateSelectedStatus("IN_STOCK");

            btnSyncCloud = new Button
            {
                Text = "Sync Cloud",
                Location = new Point(1042, 22),
                Size = new Size(120, 30),
                BackColor = Color.MediumSlateBlue,
                ForeColor = Color.White,
                Font = new Font("Arial", 9, FontStyle.Bold)
            };
            btnSyncCloud.Click += async (_, _) => await SyncSerialsToCloudAsync();

            btnDeleteSerial = new Button
            {
                Text = "Delete Serial",
                Location = new Point(1042, 22),
                Size = new Size(120, 30),
                BackColor = Color.DarkRed,
                ForeColor = Color.White,
                Font = new Font("Arial", 9, FontStyle.Bold),
                Visible = CurrentUser.IsSuperUser,
                Enabled = CurrentUser.IsSuperUser
            };
            btnDeleteSerial.Click += BtnDeleteSerial_Click;

            lblSummary = new Label
            {
                Text = "0 serials",
                Location = new Point(1042, 28),
                Size = new Size(186, 22),
                Font = new Font("Arial", 9, FontStyle.Bold),
                ForeColor = Color.DarkSlateBlue,
                TextAlign = ContentAlignment.MiddleRight
            };

            filterPanel.Controls.AddRange(new Control[]
            {
                lblSearch, txtSearch, lblStatus, cboStatusFilter, btnRefresh, btnMarkSold, btnMarkInStock, btnSyncCloud, btnDeleteSerial, lblSummary
            });

            if (CurrentUser.IsSuperUser)
            {
                btnDeleteSerial.Location = new Point(912, 22);
                btnSyncCloud.Location = new Point(1042, 22);
            }
            else
            {
                btnSyncCloud.Location = new Point(1042, 22);
            }

            dgvSerials = new DataGridView
            {
                Location = new Point(12, 210),
                Size = new Size(1240, 468),
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                ReadOnly = true,
                RowHeadersVisible = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = true,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                BackgroundColor = Color.White,
                Font = new Font("Arial", 9)
            };

            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "RunningSerialNo", HeaderText = "Running No.", FillWeight = 12 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "SerialNo", HeaderText = "Serial No.", FillWeight = 20 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "ItemCode", HeaderText = "Item Code", FillWeight = 14 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "VariantCode", HeaderText = "Variant Code", FillWeight = 14 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "ItemDescription", HeaderText = "Description", FillWeight = 24 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "Location", HeaderText = "Location", FillWeight = 16 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "Status", HeaderText = "Status", FillWeight = 10 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "SourceDocumentNo", HeaderText = "Source Doc", FillWeight = 12 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "SoldReceiptNo", HeaderText = "Sold Receipt", FillWeight = 12 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "SoldOnlineOrderId", HeaderText = "Sold Online Order", FillWeight = 14 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "CreatedBy", HeaderText = "Created By", FillWeight = 10 });
            dgvSerials.Columns.Add(new DataGridViewTextBoxColumn { Name = "CreatedAtLocal", HeaderText = "Created At", FillWeight = 14 });
            dgvSerials.Columns.Add(new DataGridViewCheckBoxColumn { Name = "SyncedToSupabase", HeaderText = "Synced", FillWeight = 8, ReadOnly = true });

            btnClose = new Button
            {
                Text = "Close",
                Location = new Point(1132, 686),
                Size = new Size(120, 34),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnClose.Click += (_, _) => Close();

            Controls.Add(addPanel);
            Controls.Add(filterPanel);
            Controls.Add(dgvSerials);
            Controls.Add(btnClose);
        }

        private void ProductSerialTrackingForm_Load(object? sender, EventArgs e)
        {
            try
            {
                EnsureSerialTrackingTable();
                LoadItems();
                LoadSerials();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to initialize serial tracking: {ex.Message}", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void EnsureSerialTrackingTable()
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();

            EnsureSerialTrackingTable(conn, null);
        }

        private static bool IsCurrentWarehouseProduction(SqlConnection conn, SqlTransaction? tran)
        {
            if (conn == null) throw new ArgumentNullException(nameof(conn));

            try
            {
                bool hasCurrentWarehouse = false;
                bool hasProductionFlag = false;

                using (var colCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Warehouses'", conn, tran))
                using (var colRdr = colCmd.ExecuteReader())
                {
                    while (colRdr.Read())
                    {
                        string columnName = colRdr[0]?.ToString() ?? string.Empty;
                        if (columnName.Equals("Current_Warehouse", StringComparison.OrdinalIgnoreCase)) hasCurrentWarehouse = true;
                        if (columnName.Equals("Is_Production_Warehouse", StringComparison.OrdinalIgnoreCase)) hasProductionFlag = true;
                    }
                }

                if (!hasCurrentWarehouse || !hasProductionFlag)
                    return false;

                using var cmd = new SqlCommand(@"
SELECT TOP 1 ISNULL(CAST([Is_Production_Warehouse] AS INT), 0)
FROM dbo.Warehouses
WHERE ISNULL([Current_Warehouse], 0) = 1
ORDER BY [Name]", conn, tran);

                var result = cmd.ExecuteScalar();
                return result != null && result != DBNull.Value && Convert.ToInt32(result) != 0;
            }
            catch
            {
                return false;
            }
        }

        public static void EnsureSerialTrackingTable(SqlConnection conn, SqlTransaction? tran)
        {
            if (conn == null) throw new ArgumentNullException(nameof(conn));

            const string sql = @"
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
END";

            const string ensureVariantColumnSql = @"
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

IF COL_LENGTH('dbo.ItemSerialTracking', 'SyncedToSupabase') IS NULL
BEGIN
    -- Computed, not a stored/manually-set flag, so it can never drift out of sync with reality -
    -- true only when LastSyncedAtUtc is set AND is not older than the row's own last modification
    -- (same comparison LoadItemSerialTrackingRows uses to decide what still needs pushing).
    ALTER TABLE dbo.ItemSerialTracking ADD SyncedToSupabase AS (
        CASE WHEN LastSyncedAtUtc IS NOT NULL AND LastSyncedAtUtc >= COALESCE(UpdatedAtUtc, CreatedAtUtc)
             THEN CONVERT(BIT, 1) ELSE CONVERT(BIT, 0) END
    );
END

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
END";

            using var cmd = new SqlCommand(sql, conn, tran);
            cmd.ExecuteNonQuery();

            using var ensureVariantCmd = new SqlCommand(ensureVariantColumnSql, conn, tran);
            ensureVariantCmd.ExecuteNonQuery();
        }

        public static List<AvailableSerialRecord> GetAvailableSerials(string itemCode, string? variantCode = null, IEnumerable<string>? excludedSerialNumbers = null)
        {
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;
            string normalizedVariantCode = variantCode?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(normalizedItemCode))
                return new List<AvailableSerialRecord>();

            var excluded = new HashSet<string>(excludedSerialNumbers ?? Enumerable.Empty<string>(), StringComparer.OrdinalIgnoreCase);
            var availableSerials = new List<AvailableSerialRecord>();

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();
            EnsureSerialTrackingTable(conn, null);

            using var cmd = new SqlCommand(@"
SELECT RunningSerialNo,
             SerialNo,
             ItemCode,
             ISNULL(VariantCode, '') AS VariantCode,
             ItemDescription,
             ISNULL(SourceDocumentNo, '') AS SourceDocumentNo
FROM dbo.ItemSerialTracking
WHERE ItemCode = @ItemCode
    AND (NULLIF(@VariantCode, '') IS NULL OR ISNULL(VariantCode, '') = @VariantCode)
  AND Status = 'IN_STOCK'
ORDER BY RunningSerialNo", conn);
            cmd.Parameters.AddWithValue("@ItemCode", normalizedItemCode);
                        cmd.Parameters.AddWithValue("@VariantCode", normalizedVariantCode);

            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string serialNo = rdr["SerialNo"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(serialNo) || excluded.Contains(serialNo))
                    continue;

                availableSerials.Add(new AvailableSerialRecord
                {
                    RunningSerialNo = rdr["RunningSerialNo"] != DBNull.Value ? Convert.ToInt64(rdr["RunningSerialNo"]) : 0L,
                    SerialNo = serialNo,
                    ItemCode = rdr["ItemCode"]?.ToString()?.Trim() ?? normalizedItemCode,
                    VariantCode = rdr["VariantCode"]?.ToString()?.Trim() ?? string.Empty,
                    ItemDescription = rdr["ItemDescription"]?.ToString()?.Trim() ?? string.Empty,
                    SourceDocumentNo = rdr["SourceDocumentNo"]?.ToString()?.Trim() ?? string.Empty
                });
            }

            return availableSerials;
        }

        public static void MarkSerialsSold(IEnumerable<string> serialNumbers, string? soldReceiptNo = null, string? soldOnlineOrderId = null)
        {
            var serials = serialNumbers?
                .Select(serialNo => serialNo?.Trim() ?? string.Empty)
                .Where(serialNo => !string.IsNullOrWhiteSpace(serialNo))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList() ?? new List<string>();

            if (serials.Count == 0)
                return;

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();
            EnsureSerialTrackingTable(conn, null);

            MarkSerialsSold(conn, null, serials, soldReceiptNo, soldOnlineOrderId);
            TriggerCloudSyncFireAndForget();
        }

        public static void UpdateSerialStatus(IEnumerable<string> serialNumbers, string status)
        {
            var serials = serialNumbers?
                .Select(serialNo => serialNo?.Trim() ?? string.Empty)
                .Where(serialNo => !string.IsNullOrWhiteSpace(serialNo))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList() ?? new List<string>();

            if (serials.Count == 0 || string.IsNullOrWhiteSpace(status))
                return;

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();
            EnsureSerialTrackingTable(conn, null);

            using var cmd = new SqlCommand(@"
UPDATE dbo.ItemSerialTracking
SET Status = @Status,
    UpdatedAtUtc = SYSUTCDATETIME()
WHERE SerialNo = @SerialNo", conn);
            cmd.Parameters.Add("@Status", SqlDbType.NVarChar, 255);
            cmd.Parameters.Add("@SerialNo", SqlDbType.NVarChar, 120);

            foreach (string serialNo in serials)
            {
                cmd.Parameters["@Status"].Value = status;
                cmd.Parameters["@SerialNo"].Value = serialNo;
                cmd.ExecuteNonQuery();
            }

            TriggerCloudSyncFireAndForget();
        }

        public static List<(string SerialNo, string ItemCode, string Description)> CreateSoldSerialRecords(
            SqlConnection conn,
            SqlTransaction? tran,
            string itemCode,
            string? variantCode,
            string itemDescription,
            string sourceDocumentNo,
            string? soldOnlineOrderId,
            string createdBy,
            int quantity)
        {
            var createdSerials = CreateSerialRecords(conn, tran, itemCode, variantCode, itemDescription, sourceDocumentNo, createdBy, quantity);
            if (createdSerials.Count == 0)
            {
                return createdSerials;
            }

            MarkSerialsSold(conn, tran, createdSerials.Select(serial => serial.SerialNo), sourceDocumentNo, soldOnlineOrderId);

            // Safe to fire here unconditionally - every real call site passes tran: null (auto-commit),
            // so both writes above are already durable by the time we reach this line.
            if (tran == null)
            {
                TriggerCloudSyncFireAndForget();
            }

            return createdSerials;
        }

        private static void MarkSerialsSold(SqlConnection conn, SqlTransaction? tran, IEnumerable<string> serialNumbers, string? soldReceiptNo, string? soldOnlineOrderId)
        {
            var serials = serialNumbers?
                .Select(serialNo => serialNo?.Trim() ?? string.Empty)
                .Where(serialNo => !string.IsNullOrWhiteSpace(serialNo))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList() ?? new List<string>();

            if (serials.Count == 0)
                return;

            using var cmd = new SqlCommand(@"
UPDATE dbo.ItemSerialTracking
SET Status = 'SOLD',
    SoldReceiptNo = COALESCE(NULLIF(@SoldReceiptNo, ''), SoldReceiptNo),
    SoldOnlineOrderId = COALESCE(NULLIF(@SoldOnlineOrderId, ''), SoldOnlineOrderId),
    UpdatedAtUtc = SYSUTCDATETIME()
WHERE SerialNo = @SerialNo
  AND Status <> 'SOLD'", conn);
            cmd.Parameters.Add("@SerialNo", SqlDbType.NVarChar, 120);
            cmd.Parameters.Add("@SoldReceiptNo", SqlDbType.NVarChar, 100);
            cmd.Parameters.Add("@SoldOnlineOrderId", SqlDbType.NVarChar, 100);

            foreach (string serialNo in serials)
            {
                cmd.Parameters["@SerialNo"].Value = serialNo;
                cmd.Parameters["@SoldReceiptNo"].Value = soldReceiptNo ?? string.Empty;
                cmd.Parameters["@SoldOnlineOrderId"].Value = soldOnlineOrderId ?? string.Empty;
                cmd.ExecuteNonQuery();
            }
        }

        private void LoadItems()
        {
            cboItem.Items.Clear();
            itemDescriptionsByCode.Clear();
            itemVariantCodesByCode.Clear();

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            var availableColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var colCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Items'", conn))
            using (var colRdr = colCmd.ExecuteReader())
            {
                while (colRdr.Read())
                {
                    string columnName = colRdr[0]?.ToString() ?? string.Empty;
                    if (!string.IsNullOrWhiteSpace(columnName))
                    {
                        availableColumns.Add(columnName);
                    }
                }
            }

            string Pick(params string[] candidates)
            {
                foreach (string candidate in candidates)
                {
                    if (availableColumns.Contains(candidate))
                    {
                        return candidate;
                    }
                }

                return string.Empty;
            }

            string codeColumn = Pick("Code", "ItemCode", "No");
            string displayColumn = Pick("Name", "Description", "ItemName", "ItemDescription");
            string variationColumn = Pick("VariationId", "VariantCode");
            if (string.IsNullOrWhiteSpace(codeColumn))
            {
                return;
            }

            string displayExpression = string.IsNullOrWhiteSpace(displayColumn)
                ? codeColumn
                : $"COALESCE(NULLIF({displayColumn}, ''), {codeColumn})";

            using var cmd = new SqlCommand($@"
SELECT {codeColumn} AS Code,
       {displayExpression} AS DisplayName,
       {(string.IsNullOrWhiteSpace(variationColumn) ? "CAST('' AS NVARCHAR(200))" : $"ISNULL({variationColumn}, '')")} AS VariantCode
FROM Items
WHERE ISNULL({codeColumn}, '') <> ''
ORDER BY {codeColumn}", conn);
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string code = rdr["Code"]?.ToString()?.Trim() ?? string.Empty;
                string displayName = rdr["DisplayName"]?.ToString()?.Trim() ?? code;
                string variantCode = rdr["VariantCode"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(code))
                    continue;

                itemDescriptionsByCode[code] = displayName;
                itemVariantCodesByCode[code] = variantCode;
                cboItem.Items.Add($"{code} - {displayName}");
            }
        }

        private void LoadSerials()
        {
            dgvSerials.Rows.Clear();

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            string searchText = txtSearch.Text?.Trim() ?? string.Empty;
            string status = cboStatusFilter.SelectedItem?.ToString() ?? "ALL";

            using var cmd = new SqlCommand(@"
SELECT RunningSerialNo, SerialNo, ItemCode, ISNULL(VariantCode, '') AS VariantCode, ItemDescription, ISNULL([Location], '') AS [Location], Status,
       SourceDocumentNo, ISNULL(SoldReceiptNo, '') AS SoldReceiptNo, ISNULL(SoldOnlineOrderId, '') AS SoldOnlineOrderId, CreatedBy,
       DATEADD(MINUTE, DATEDIFF(MINUTE, SYSUTCDATETIME(), GETDATE()), CreatedAtUtc) AS CreatedAtLocal,
       SyncedToSupabase
FROM dbo.ItemSerialTracking
WHERE (@search = '' OR ItemCode LIKE @likeSearch OR ISNULL(VariantCode, '') LIKE @likeSearch OR ItemDescription LIKE @likeSearch OR ISNULL([Location], '') LIKE @likeSearch OR SerialNo LIKE @likeSearch)
  AND (@status = 'ALL' OR Status = @status)
ORDER BY RunningSerialNo DESC", conn);
            cmd.Parameters.AddWithValue("@search", searchText);
            cmd.Parameters.AddWithValue("@likeSearch", $"%{searchText}%");
            cmd.Parameters.AddWithValue("@status", status);

            int total = 0;
            int inStock = 0;
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string rowStatus = rdr["Status"]?.ToString() ?? string.Empty;
                dgvSerials.Rows.Add(
                    rdr["RunningSerialNo"],
                    rdr["SerialNo"],
                    rdr["ItemCode"],
                    rdr["VariantCode"],
                    rdr["ItemDescription"],
                    rdr["Location"],
                    rowStatus,
                    rdr["SourceDocumentNo"],
                    rdr["SoldReceiptNo"],
                    rdr["SoldOnlineOrderId"],
                    rdr["CreatedBy"],
                    Convert.ToDateTime(rdr["CreatedAtLocal"]).ToString("yyyy-MM-dd HH:mm"),
                    rdr["SyncedToSupabase"] != DBNull.Value && Convert.ToBoolean(rdr["SyncedToSupabase"]));

                total++;
                if (string.Equals(rowStatus, "IN_STOCK", StringComparison.OrdinalIgnoreCase))
                    inStock++;
            }

            lblSummary.Text = $"{total} serials | {inStock} in stock";
        }

        private void BtnAddSerials_Click(object? sender, EventArgs e)
        {
            try
            {
                string selection = cboItem.Text?.Trim() ?? string.Empty;
                string itemCode = ExtractItemCode(selection);
                if (string.IsNullOrWhiteSpace(itemCode))
                {
                    MessageBox.Show("Select a valid product first.", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                int quantity = Convert.ToInt32(nudQuantity.Value);
                string customSerial = txtCustomSerial.Text?.Trim() ?? string.Empty;
                string sourceDocumentNo = txtSourceDocument.Text?.Trim() ?? string.Empty;
                string itemDescription = itemDescriptionsByCode.TryGetValue(itemCode, out var desc) ? desc : itemCode;
                string variantCode = itemVariantCodesByCode.TryGetValue(itemCode, out var storedVariantCode) ? storedVariantCode : string.Empty;

                if (!string.IsNullOrWhiteSpace(customSerial) && quantity > 1)
                {
                    MessageBox.Show("Custom Serial can only be used when quantity is 1.", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                string userName = CurrentUser.GetEffectiveUsername("SYSTEM");
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                if (!IsCurrentWarehouseProduction(conn, null))
                {
                    MessageBox.Show("Serial creation is only allowed when the current warehouse is marked as Is_Production_Warehouse.", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                List<(string SerialNo, string ItemCode, string Description)> createdSerials = CreateSerialRecords(conn, null, itemCode, variantCode, itemDescription, sourceDocumentNo, userName, quantity, customSerial);
                if (createdSerials.Count > 0)
                {
                    TriggerCloudSyncFireAndForget();
                }

                txtCustomSerial.Clear();
                nudQuantity.Value = 1;
                LoadSerials();
                MessageBox.Show($"Created {createdSerials.Count} serial record(s) for {itemCode}.", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to add serials: {ex.Message}", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async Task SyncSerialsToCloudAsync()
        {
            try
            {
                UseWaitCursor = true;
                ToggleCloudSyncButton(false);

                var result = await Task.Run(() => OnlinefunctionsEvents.SyncItemSerialTrackingToSupabase()).ConfigureAwait(true);
                string skippedNote = result.SkippedDueToConflictCount > 0
                    ? $"\nSkipped (newer in Portal): {result.SkippedDueToConflictCount}"
                    : string.Empty;
                MessageBox.Show(this,
                    $"Serial tracking sync completed.\n\nSynced: {result.SyncedCount}\nInserted: {result.InsertedCount}\nUpdated: {result.UpdatedCount}{skippedNote}",
                    "Serial Tracking Sync",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Serial tracking sync failed: {ex.Message}", "Serial Tracking Sync", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                UseWaitCursor = false;
                ToggleCloudSyncButton(true);
            }
        }

        private void ToggleCloudSyncButton(bool enabled)
        {
            if (btnSyncCloud == null)
                return;

            btnSyncCloud.Enabled = enabled;
            btnSyncCloud.Text = enabled ? "Sync Cloud" : "Syncing...";
        }

        public static List<(string SerialNo, string ItemCode, string Description)> CreateSerialRecords(
            SqlConnection conn,
            SqlTransaction? tran,
            string itemCode,
            string? variantCode,
            string itemDescription,
            string sourceDocumentNo,
            string createdBy,
            int quantity,
            string? requestedSerialNo = null)
        {
            if (conn == null) throw new ArgumentNullException(nameof(conn));
            if (string.IsNullOrWhiteSpace(itemCode) || quantity <= 0)
                return new List<(string SerialNo, string ItemCode, string Description)>();
            if (!IsCurrentWarehouseProduction(conn, tran))
                return new List<(string SerialNo, string ItemCode, string Description)>();

            EnsureSerialTrackingTable(conn, tran);
            string location = GetCurrentSerialTrackingLocation();

            List<(string SerialNo, string ItemCode, string Description)> createdSerials = new();
            for (int index = 0; index < quantity; index++)
            {
                string serialToUse = index == 0 ? (requestedSerialNo ?? string.Empty) : string.Empty;
                string serialNo = InsertSerialRecord(conn, tran, itemCode, variantCode, itemDescription, location, sourceDocumentNo, createdBy, serialToUse);
                if (!string.IsNullOrWhiteSpace(serialNo))
                {
                    createdSerials.Add((serialNo, itemCode, itemDescription));
                }
            }

            return createdSerials;
        }

        private static string GetCurrentSerialTrackingLocation()
        {
            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString);
            if (currentWarehouse == null)
                return string.Empty;

            return !string.IsNullOrWhiteSpace(currentWarehouse.Name)
                ? currentWarehouse.Name.Trim()
                : (currentWarehouse.Id ?? string.Empty).Trim();
        }

        private static string InsertSerialRecord(SqlConnection conn, SqlTransaction? tran, string itemCode, string? variantCode, string itemDescription, string location, string sourceDocumentNo, string createdBy, string requestedSerialNo)
        {
            const string sql = @"
DECLARE @Inserted TABLE (RunningSerialNo BIGINT);

    INSERT INTO dbo.ItemSerialTracking (SerialNo, ItemCode, VariantCode, ItemDescription, Location, Status, SourceDocumentNo, CreatedBy)
OUTPUT INSERTED.RunningSerialNo INTO @Inserted(RunningSerialNo)
    VALUES (@TempSerialNo, @ItemCode, NULLIF(@VariantCode, ''), @ItemDescription, NULLIF(@Location, ''), 'IN_STOCK', NULLIF(@SourceDocumentNo, ''), @CreatedBy);

DECLARE @RunningSerialNo BIGINT = (SELECT TOP 1 RunningSerialNo FROM @Inserted);
DECLARE @SerialYear VARCHAR(2) = RIGHT(CONVERT(VARCHAR(4), DATEPART(YEAR, GETDATE())), 2);
DECLARE @NextItemRunningNo INT = ISNULL(
    (
        SELECT MAX(TRY_CONVERT(INT, RIGHT(SerialNo, 6)))
        FROM dbo.ItemSerialTracking WITH (UPDLOCK, HOLDLOCK)
        WHERE ItemCode = @ItemCode
          AND (
              SerialNo LIKE @ItemCode + '-' + @SerialYear + '-%'
              OR SerialNo LIKE 'RS-' + @ItemCode + '-' + @SerialYear + '-%'
          )
    ),
    0) + 1;
DECLARE @FinalSerialNo NVARCHAR(120) = CASE
    WHEN NULLIF(@RequestedSerialNo, '') IS NOT NULL THEN @RequestedSerialNo
    ELSE 'RS-' + @ItemCode + '-' + @SerialYear + '-' + RIGHT(REPLICATE('0', 6) + CONVERT(VARCHAR(20), @NextItemRunningNo), 6)
END;

IF EXISTS (SELECT 1 FROM dbo.ItemSerialTracking WHERE SerialNo = @FinalSerialNo AND RunningSerialNo <> @RunningSerialNo)
BEGIN
    THROW 51000, 'Serial number already exists.', 1;
END

UPDATE dbo.ItemSerialTracking
SET SerialNo = @FinalSerialNo,
    UpdatedAtUtc = SYSUTCDATETIME()
WHERE RunningSerialNo = @RunningSerialNo;

SELECT @FinalSerialNo;";

            using var cmd = new SqlCommand(sql, conn, tran);
            cmd.Parameters.AddWithValue("@TempSerialNo", $"TEMP-{Guid.NewGuid():N}");
            cmd.Parameters.AddWithValue("@ItemCode", itemCode);
            cmd.Parameters.AddWithValue("@VariantCode", variantCode ?? string.Empty);
            cmd.Parameters.AddWithValue("@ItemDescription", itemDescription);
            cmd.Parameters.AddWithValue("@Location", location ?? string.Empty);
            cmd.Parameters.AddWithValue("@SourceDocumentNo", sourceDocumentNo ?? string.Empty);
            cmd.Parameters.AddWithValue("@CreatedBy", createdBy ?? string.Empty);
            cmd.Parameters.AddWithValue("@RequestedSerialNo", requestedSerialNo ?? string.Empty);
            return cmd.ExecuteScalar()?.ToString() ?? string.Empty;
        }

        private void UpdateSelectedStatus(string status)
        {
            try
            {
                var selectedRows = dgvSerials.SelectedRows.Cast<DataGridViewRow>().ToList();
                if (selectedRows.Count == 0)
                {
                    MessageBox.Show("Select at least one serial record first.", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand(@"
UPDATE dbo.ItemSerialTracking
SET Status = @Status,
    UpdatedAtUtc = SYSUTCDATETIME()
WHERE RunningSerialNo = @RunningSerialNo", conn);
                cmd.Parameters.Add("@Status", SqlDbType.NVarChar, 255);
                cmd.Parameters.Add("@RunningSerialNo", SqlDbType.BigInt);

                foreach (var row in selectedRows)
                {
                    if (row.Cells["RunningSerialNo"].Value == null)
                        continue;

                    cmd.Parameters["@Status"].Value = status;
                    cmd.Parameters["@RunningSerialNo"].Value = Convert.ToInt64(row.Cells["RunningSerialNo"].Value);
                    cmd.ExecuteNonQuery();
                }

                TriggerCloudSyncFireAndForget();
                LoadSerials();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to update status: {ex.Message}", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnDeleteSerial_Click(object? sender, EventArgs e)
        {
            if (!CurrentUser.IsSuperUser)
            {
                MessageBox.Show("Only admin users can delete serial records.", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            try
            {
                var selectedRows = dgvSerials.SelectedRows.Cast<DataGridViewRow>().ToList();
                if (selectedRows.Count == 0)
                {
                    MessageBox.Show("Select at least one serial record first.", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                int serialCount = selectedRows.Count;
                string serialPreview = string.Join(", ",
                    selectedRows
                        .Select(row => row.Cells["SerialNo"].Value?.ToString()?.Trim() ?? string.Empty)
                        .Where(serialNo => !string.IsNullOrWhiteSpace(serialNo))
                        .Take(3));

                string confirmationMessage = serialCount == 1
                    ? $"Delete serial {serialPreview}? This cannot be undone."
                    : $"Delete {serialCount} serial records{(string.IsNullOrWhiteSpace(serialPreview) ? string.Empty : $" including {serialPreview}")}? This cannot be undone.";

                if (MessageBox.Show(this, confirmationMessage, "Delete Serial", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
                {
                    return;
                }

                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand(@"
DELETE FROM dbo.ItemSerialTracking
WHERE RunningSerialNo = @RunningSerialNo", conn);
                cmd.Parameters.Add("@RunningSerialNo", SqlDbType.BigInt);

                int deletedCount = 0;
                foreach (var row in selectedRows)
                {
                    if (row.Cells["RunningSerialNo"].Value == null)
                        continue;

                    cmd.Parameters["@RunningSerialNo"].Value = Convert.ToInt64(row.Cells["RunningSerialNo"].Value);
                    deletedCount += cmd.ExecuteNonQuery();
                }

                if (deletedCount > 0)
                {
                    TriggerCloudSyncFireAndForget();
                }

                LoadSerials();
                MessageBox.Show($"Deleted {deletedCount} serial record(s).", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to delete serial records: {ex.Message}", "Serial Tracker", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static string ExtractItemCode(string selection)
        {
            if (string.IsNullOrWhiteSpace(selection))
                return string.Empty;

            int separatorIndex = selection.IndexOf(" - ", StringComparison.Ordinal);
            if (separatorIndex <= 0)
                return selection.Trim();

            return selection.Substring(0, separatorIndex).Trim();
        }
    }
}