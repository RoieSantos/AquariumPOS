using System;
using System.Data;
using System.Linq;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;
using System.Collections.Generic;

namespace AquariumPOS
{
    public class StockCountsForm : Form
    {
        private DataGridView dgv = null!;
        private TextBox txtSearch = null!;
        private Button btnSave = null!;
        private Button btnCancel = null!;

        public StockCountsForm()
        {
            Text = "Stock Counts - Products";
            // Open centered and maximized
            StartPosition = FormStartPosition.CenterScreen;
            Width = 900;
            Height = 600;
            InitializeComponent();

            // If the application's main form is available, match its size/location; otherwise maximize
            try
            {
                var main = System.Windows.Forms.Application.OpenForms.Cast<Form>().FirstOrDefault(f => f.GetType().Name == "MainForm");
                if (main != null)
                {
                    // Match bounds and window state of main form so StockCounts appears the same size
                    StartPosition = FormStartPosition.Manual;
                    this.Bounds = main.Bounds;
                    this.WindowState = main.WindowState;
                    // Make sure the form is shown on the same screen as the main form
                    this.Location = main.Location;
                }
                else
                {
                    // Make the form full screen (maximized) as a fallback
                    WindowState = FormWindowState.Maximized;
                }
            }
            catch { WindowState = FormWindowState.Maximized; }

            // Make all text bold by setting the form font and propagating to child controls
            try
            {
                this.Font = new Font(this.Font, FontStyle.Bold);
            }
            catch { }

            // Apply bold fonts to DataGridView and buttons (some controls created in InitializeComponent)
            try
            {
                if (dgv != null)
                {
                    dgv.Font = new Font(this.Font, FontStyle.Bold);
                    dgv.ColumnHeadersDefaultCellStyle.Font = new Font(this.Font, FontStyle.Bold);
                    dgv.RowsDefaultCellStyle.Font = new Font(this.Font, FontStyle.Bold);
                }
                if (btnSave != null) btnSave.Font = new Font(this.Font, FontStyle.Bold);
                if (btnCancel != null) btnCancel.Font = new Font(this.Font, FontStyle.Bold);
            }
            catch { }

            Load += StockCountsForm_Load;
        }

        private void InitializeComponent()
        {
            txtSearch = new TextBox
            {
                Dock = DockStyle.Fill,
                Font = new Font("Arial", 10, FontStyle.Bold),
                PlaceholderText = "Search item code, description, or category..."
            };
            txtSearch.TextChanged += TxtSearch_TextChanged;

            var searchLabel = new Label
            {
                Text = "Search:",
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleLeft,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var topPanel = new Panel { Dock = DockStyle.Top, Height = 44, Padding = new Padding(10, 8, 10, 4) };
            var searchLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
            searchLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 72F));
            searchLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            searchLayout.Controls.Add(searchLabel, 0, 0);
            searchLayout.Controls.Add(txtSearch, 1, 0);
            topPanel.Controls.Add(searchLayout);

            dgv = new DataGridView
            {
                Dock = DockStyle.Fill,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                RowHeadersVisible = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill
            };
            dgv.DataError += Dgv_DataError;

            // When a row is entered, move focus into the Count cell and begin edit for quick typing
            dgv.RowEnter += Dgv_RowEnter;

            // Columns: ItemCode (readonly), Description (readonly), Category (readonly), Count (editable), VariationId (hidden)
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "ItemCode", HeaderText = "Item Code", ReadOnly = true });
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "Description", HeaderText = "Description", ReadOnly = true });
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "Category", HeaderText = "Category", ReadOnly = true });
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "Count", HeaderText = "Count", ValueType = typeof(int) });
            // Hidden variation id column for integration with online inventory
            dgv.Columns.Add(new DataGridViewTextBoxColumn { Name = "VariationId", HeaderText = "VariationId", Visible = false });

            // Adjust column relative widths (using FillWeight since AutoSizeColumnsMode = Fill)
            // Make Description the widest, ItemCode and Category narrow
            try
            {
                dgv.Columns["ItemCode"].FillWeight = 50;   // narrow
                dgv.Columns["Description"].FillWeight = 260; // wide
                dgv.Columns["Category"].FillWeight = 60;   // narrow
                dgv.Columns["Count"].FillWeight = 30;      // small
            }
            catch { }

            // POST button centered and larger; Cancel remains on the right
            btnSave = new Button { Text = "POST", Size = new Size(140, 48), BackColor = Color.SeaGreen, ForeColor = Color.White, Margin = new Padding(8) };
            btnCancel = new Button { Text = "Cancel", Size = new Size(120, 48), BackColor = Color.Gray, ForeColor = Color.White, Margin = new Padding(8) };

            btnSave.Click += BtnSave_Click;
            btnCancel.Click += (s, e) => Close();

            // Bottom panel with table layout: center the POST button, keep Cancel on the right
            var bottomPanel = new Panel { Dock = DockStyle.Bottom, Height = 80 };
            var table = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1 };
            // Use two flexible side columns and an AutoSize middle column to center the button group
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            table.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            table.RowStyles.Add(new RowStyle(SizeType.Absolute, 80F));

            // Flow panel to hold both buttons centered in the middle column
            var centerFlow = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false,
                AutoSize = true,
                Anchor = AnchorStyles.None,
                Padding = new Padding(8)
            };
            centerFlow.Controls.Add(btnSave);
            centerFlow.Controls.Add(btnCancel);

            // Place the centerFlow in the middle column (index 1)
            table.Controls.Add(centerFlow, 1, 0);
            bottomPanel.Controls.Add(table);

            Controls.Add(dgv);
            Controls.Add(topPanel);
            Controls.Add(bottomPanel);
        }

        private void StockCountsForm_Load(object? sender, EventArgs e)
        {
            LoadProducts();
            FocusFirstVisibleCountCell();
        }

        private void Dgv_RowEnter(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (txtSearch != null && txtSearch.Focused)
                {
                    return;
                }

                if (e.RowIndex >= 0 && e.RowIndex < dgv.Rows.Count && dgv.Columns.Count > 3)
                {
                    var row = dgv.Rows[e.RowIndex];
                    if (!row.IsNewRow)
                    {
                        dgv.CurrentCell = row.Cells[3];
                        dgv.BeginEdit(true);
                        var ctrl = dgv.EditingControl as TextBox;
                        if (ctrl != null) ctrl.SelectAll();
                    }
                }
            }
            catch { }
        }

        private void TxtSearch_TextChanged(object? sender, EventArgs e)
        {
            ApplySearchFilter();
        }

        private void ApplySearchFilter()
        {
            string searchText = txtSearch?.Text?.Trim() ?? string.Empty;
            bool hasFilter = !string.IsNullOrWhiteSpace(searchText);

            foreach (DataGridViewRow row in dgv.Rows)
            {
                if (row.IsNewRow)
                {
                    continue;
                }

                if (!hasFilter)
                {
                    row.Visible = true;
                    continue;
                }

                string itemCode = row.Cells["ItemCode"].Value?.ToString() ?? string.Empty;
                string description = row.Cells["Description"].Value?.ToString() ?? string.Empty;
                string category = row.Cells["Category"].Value?.ToString() ?? string.Empty;

                row.Visible = itemCode.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0
                    || description.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0
                    || category.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0;
            }
        }

        private void FocusFirstVisibleCountCell()
        {
            try
            {
                if (txtSearch != null && txtSearch.Focused)
                {
                    return;
                }

                if (dgv.Columns.Count <= 3)
                {
                    return;
                }

                var firstVisibleRow = dgv.Rows.Cast<DataGridViewRow>()
                    .FirstOrDefault(row => !row.IsNewRow && row.Visible);

                if (firstVisibleRow == null)
                {
                    return;
                }

                dgv.CurrentCell = firstVisibleRow.Cells[3];
                dgv.Focus();
                dgv.BeginEdit(true);
                var ctrl = dgv.EditingControl as TextBox;
                if (ctrl != null)
                {
                    ctrl.SelectAll();
                }
            }
            catch { }
        }

        private void Dgv_DataError(object? sender, DataGridViewDataErrorEventArgs e)
        {
            e.ThrowException = false;
            e.Cancel = false;
        }

        private static string BuildStockCountDescription(string itemCode, string itemName, string itemDescription, string mainItemCode, string mainItemName)
        {
            var parts = new List<string>();

            void AddPart(string? value)
            {
                string normalized = (value ?? string.Empty).Trim();
                if (string.IsNullOrWhiteSpace(normalized))
                {
                    return;
                }

                if (!parts.Any(existing => string.Equals(existing, normalized, StringComparison.OrdinalIgnoreCase)))
                {
                    parts.Add(normalized);
                }
            }

            AddPart(itemName);
            AddPart(itemDescription);

            if (!string.IsNullOrWhiteSpace(mainItemCode)
                && !string.Equals(mainItemCode.Trim(), itemCode?.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                AddPart($"Base: {mainItemCode.Trim()}");
            }

            if (!string.IsNullOrWhiteSpace(mainItemName)
                && !string.Equals(mainItemName.Trim(), itemName?.Trim(), StringComparison.OrdinalIgnoreCase)
                && !string.Equals(mainItemName.Trim(), itemDescription?.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                AddPart(mainItemName.Trim());
            }

            if (parts.Count == 0)
            {
                return itemCode?.Trim() ?? string.Empty;
            }

            return string.Join(" | ", parts);
        }

        private void LoadProducts()
        {
            dgv.Rows.Clear();
            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();

                    bool hasVariantTable;
                    using (var existsCmd = new SqlCommand("SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Variant'", conn))
                    {
                        hasVariantTable = Convert.ToInt32(existsCmd.ExecuteScalar()) > 0;
                    }

                    string sql = hasVariantTable
                        ? @"
SELECT
    ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode) AS Code,
    ISNULL(NULLIF(v.VariantName, ''), ISNULL(NULLIF(variantItem.[Name], ''), ISNULL(NULLIF(variantItem.[Description], ''), ISNULL(NULLIF(mainItem.[Name], ''), ISNULL(mainItem.[Description], ''))))) AS ItemName,
    ISNULL(NULLIF(variantItem.[Description], ''), ISNULL(NULLIF(mainItem.[Description], ''), '')) AS ItemDescription,
    ISNULL(c.[Description], ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))) AS Category,
    ISNULL(v.MainItemCode, '') AS MainItemCode,
    ISNULL(NULLIF(mainItem.[Name], ''), ISNULL(mainItem.[Description], '')) AS MainItemName,
    ISNULL(v.VariationId, '') AS VariationId
FROM dbo.[Variant] v
LEFT JOIN dbo.Items variantItem ON variantItem.Code = ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)
LEFT JOIN dbo.Items mainItem ON mainItem.Code = v.MainItemCode
LEFT JOIN dbo.Category c ON c.Code = ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))
WHERE ISNULL(variantItem.IsActive, ISNULL(mainItem.IsActive, 1)) = 1
  AND (
        UPPER(ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))) LIKE '%AQUARIUM%'
        OR UPPER(ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))) LIKE '%STAND%'
        OR UPPER(ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))) LIKE '%SUMP%'
      )
  AND UPPER(ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))) NOT LIKE '%HIGH-STRIP%'
  AND UPPER(ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))) NOT LIKE '%CUSTOM_STAND%'
ORDER BY
    ISNULL(c.[Description], ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))),
    ISNULL(NULLIF(v.VariantName, ''), ISNULL(NULLIF(variantItem.[Name], ''), ISNULL(NULLIF(variantItem.[Description], ''), ISNULL(NULLIF(mainItem.[Name], ''), ISNULL(mainItem.[Description], ''))))),
    ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)"
                        : @"
SELECT
    i.Code,
    ISNULL(NULLIF(i.[Name], ''), ISNULL(i.[Description], '')) AS ItemName,
    ISNULL(i.[Description], '') AS ItemDescription,
    ISNULL(i.CategoryCode, '') AS Category,
    '' AS MainItemCode,
    '' AS MainItemName,
    ISNULL(i.VariationId, '') AS VariationId
FROM dbo.Items i
WHERE (
        UPPER(ISNULL(i.CategoryCode, '')) LIKE '%AQUARIUM%'
        OR UPPER(ISNULL(i.CategoryCode, '')) LIKE '%STAND%'
        OR UPPER(ISNULL(i.CategoryCode, '')) LIKE '%SUMP%'
      )
  AND UPPER(ISNULL(i.CategoryCode, '')) NOT LIKE '%HIGH-STRIP%'
  AND UPPER(ISNULL(i.CategoryCode, '')) NOT LIKE '%CUSTOM_STAND%'
ORDER BY ISNULL(i.CategoryCode, ''), ISNULL(NULLIF(i.[Name], ''), ISNULL(i.[Description], '')), i.Code";

                    using (var cmd = new SqlCommand(sql, conn))
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read())
                        {
                            string code = rdr.IsDBNull(0) ? string.Empty : rdr.GetString(0);
                            string itemName = rdr.IsDBNull(1) ? string.Empty : rdr.GetString(1);
                            string itemDescription = rdr.IsDBNull(2) ? string.Empty : rdr.GetString(2);
                            string cat = rdr.IsDBNull(3) ? string.Empty : rdr.GetString(3);
                            string mainItemCode = rdr.IsDBNull(4) ? string.Empty : rdr.GetString(4);
                            string mainItemName = rdr.IsDBNull(5) ? string.Empty : rdr.GetString(5);
                            string desc = BuildStockCountDescription(code, itemName, itemDescription, mainItemCode, mainItemName);
                            string variationId = string.Empty;
                            try
                            {
                                if (!rdr.IsDBNull(6))
                                {
                                    var v = rdr.GetValue(6);
                                    if (v != null && v != DBNull.Value) variationId = v.ToString() ?? string.Empty;
                                }
                            }
                            catch { variationId = string.Empty; }

                            string filterText = $"{code} {desc} {cat}".ToUpperInvariant();
                            if (string.IsNullOrWhiteSpace(code)
                                || filterText.Contains("DIVIDER")
                                || filterText.Contains("HIGH-STRIP")
                                || filterText.Contains("CUSTOM_STAND")
                                || filterText.Contains("10MM")
                                || filterText.Contains("12MM")
                                || filterText.Contains("10 MM")
                                || filterText.Contains("12 MM"))
                            {
                                continue;
                            }

                            int lastCount = 0;
                            try
                            {
                                using (var cmd2 = new SqlCommand(@"
SELECT TOP 1 CountValue
FROM dbo.InventoryStockCounts
WHERE (NULLIF(@variationId, '') IS NOT NULL AND VariationId = @variationId)
   OR ((NULLIF(@variationId, '') IS NULL OR ISNULL(VariationId, '') = '') AND ItemCode = @code)
ORDER BY Id DESC", conn))
                                {
                                    cmd2.Parameters.AddWithValue("@code", code);
                                    cmd2.Parameters.AddWithValue("@variationId", variationId ?? string.Empty);
                                    var o = cmd2.ExecuteScalar();
                                    if (o != null && o != DBNull.Value) lastCount = Convert.ToInt32(o);
                                }
                            }
                            catch { }

                            // Add row and set hidden variation id column
                            int rowIndex = dgv.Rows.Add(code, desc, cat, lastCount);
                            try
                            {
                                dgv.Rows[rowIndex].Cells["VariationId"].Value = variationId;
                            }
                            catch { }
                        }

                        ApplySearchFilter();
                    }
                }
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Failed to load products: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private void BtnSave_Click(object? sender, EventArgs e)
        {
            // Confirm with the user before committing POST
            try
            {
                int rowsToSave = 0;
                int positiveLines = 0;
                try
                {
                    var rows = dgv.Rows.Cast<DataGridViewRow>().Where(r => !r.IsNewRow).ToArray();
                    rowsToSave = rows.Length;
                    positiveLines = rows.Count(r =>
                    {
                        try { return Convert.ToInt32(r.Cells[3].Value ?? 0) > 0; } catch { return false; }
                    });
                }
                catch { rowsToSave = 0; positiveLines = 0; }

                var confirm = MessageBox.Show($"Commit {rowsToSave} stock count line(s)? {positiveLines} line(s) will create POSITIVE_ADJ ledger entries. Continue?", "Confirm POST", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (confirm != DialogResult.Yes) return;

                // Generate a single document number for this POST batch and reuse for
                // all ledger lines and any downstream online-document calls.
                string batchDocNo = $"STOCKCOUNTS_{DateTime.Now:yyyyMMdd_HHmmss}";

                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();

                    string createSql = @"
                        IF OBJECT_ID('dbo.InventoryStockCounts', 'U') IS NULL
                        BEGIN
                            CREATE TABLE dbo.InventoryStockCounts (
                                Id INT IDENTITY(1,1) PRIMARY KEY,
                                ItemCode NVARCHAR(200) NULL,
                                VariationId NVARCHAR(200) NULL,
                                CountValue INT NOT NULL,
                                EnteredAtUtc DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
                                EnteredBy NVARCHAR(200) NULL
                            )
                        END
                        ELSE IF COL_LENGTH('dbo.InventoryStockCounts', 'VariationId') IS NULL
                        BEGIN
                            ALTER TABLE dbo.InventoryStockCounts ADD VariationId NVARCHAR(200) NULL
                        END
                    ";
                    using (var cc = new SqlCommand(createSql, conn)) cc.ExecuteNonQuery();

                    string insertSql = "INSERT INTO dbo.InventoryStockCounts (ItemCode, VariationId, CountValue, EnteredAtUtc, EnteredBy) VALUES (@item, @variationId, @count, SYSUTCDATETIME(), @user)";

                    using (var tran = conn.BeginTransaction())
                    using (var cmd = new SqlCommand(insertSql, conn, tran))
                    {
                        cmd.Parameters.Add(new SqlParameter("@item", System.Data.SqlDbType.NVarChar, 200));
                        cmd.Parameters.Add(new SqlParameter("@variationId", System.Data.SqlDbType.NVarChar, 200));
                        cmd.Parameters.Add(new SqlParameter("@count", System.Data.SqlDbType.Int));
                        cmd.Parameters.Add(new SqlParameter("@user", System.Data.SqlDbType.NVarChar, 200));

                        string user = CurrentUser.GetEffectiveUsername("SYSTEM");
                        // collect saved rows to print later
                        System.Collections.Generic.List<(string Code, string Description, int Count)> savedLines = new();
                        System.Collections.Generic.List<(string SerialNo, string ItemCode, string Description)> createdSerialLabels = new();
                        foreach (DataGridViewRow row in dgv.Rows)
                        {
                            if (row.IsNewRow) continue;
                            var code = row.Cells[0].Value?.ToString() ?? string.Empty;
                            var variationId = row.Cells["VariationId"].Value?.ToString() ?? string.Empty;
                            int count = 0;
                            try { count = Convert.ToInt32(row.Cells[3].Value ?? 0); } catch { count = 0; }

                            // Do not log items with a zero count
                            if (count == 0) continue;

                            // capture description for printing (if available)
                            string desc = string.Empty;
                            try { desc = row.Cells[1].Value?.ToString() ?? string.Empty; } catch { desc = string.Empty; }

                            savedLines.Add((code, desc, count));

                            cmd.Parameters["@item"].Value = string.IsNullOrWhiteSpace(code) ? (object)DBNull.Value : code;
                            cmd.Parameters["@variationId"].Value = string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : variationId;
                            cmd.Parameters["@count"].Value = count;
                            cmd.Parameters["@user"].Value = user;
                            cmd.ExecuteNonQuery();

                            // Create an ItemLedgerEntry POSITIVE_ADJ for declared positive counts
                            try
                            {
                                if (!string.IsNullOrWhiteSpace(code) && count > 0)
                                {
                                    // lookup unit cost from Items table (fallback to 0)
                                    decimal unitCost = 0m;
                                    using (var costCmd = new SqlCommand("SELECT TOP 1 Cost FROM Items WHERE Code = @code", conn, tran))
                                    {
                                        costCmd.Parameters.AddWithValue("@code", code);
                                        var oc = costCmd.ExecuteScalar();
                                        if (oc != null && oc != DBNull.Value)
                                        {
                                            try { unitCost = Convert.ToDecimal(oc); } catch { unitCost = 0m; }
                                        }
                                    }

                                    bool itemLedgerHasVariationId;
                                    using (var columnCheckCmd = new SqlCommand("SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'ItemLedgerEntry' AND COLUMN_NAME = 'VariationId'", conn, tran))
                                    {
                                        itemLedgerHasVariationId = Convert.ToInt32(columnCheckCmd.ExecuteScalar()) > 0;
                                    }

                                    var ledgerCmd = new SqlCommand(itemLedgerHasVariationId
                                        ? @"
                                        INSERT INTO ItemLedgerEntry (EntryDate, ItemCode, DocumentType, DocumentNo, Quantity, UnitCost, TotalCost, Description, UserID, VariationId)
                                        VALUES (GETDATE(), @itemCode, @docType, @docNo, @quantity, @unitCost, @totalCost, @description, @userId, @variationId)"
                                        : @"
                                        INSERT INTO ItemLedgerEntry (EntryDate, ItemCode, DocumentType, DocumentNo, Quantity, UnitCost, TotalCost, Description, UserID)
                                        VALUES (GETDATE(), @itemCode, @docType, @docNo, @quantity, @unitCost, @totalCost, @description, @userId)", conn, tran);

                                    ledgerCmd.Parameters.AddWithValue("@itemCode", code);
                                    ledgerCmd.Parameters.AddWithValue("@docType", "POSITIVE_ADJ");
                                    ledgerCmd.Parameters.AddWithValue("@docNo", batchDocNo);
                                    ledgerCmd.Parameters.AddWithValue("@quantity", count);
                                    ledgerCmd.Parameters.AddWithValue("@unitCost", unitCost);
                                    ledgerCmd.Parameters.AddWithValue("@totalCost", unitCost * Math.Abs(count));
                                    ledgerCmd.Parameters.AddWithValue("@description", $"Stock counts POST adjustment ({user})");
                                    ledgerCmd.Parameters.AddWithValue("@userId", user);
                                    if (itemLedgerHasVariationId)
                                    {
                                        ledgerCmd.Parameters.AddWithValue("@variationId", string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : variationId);
                                    }
                                    ledgerCmd.ExecuteNonQuery();

                                    var serials = ProductSerialTrackingForm.CreateSerialRecords(
                                        conn,
                                        tran,
                                        code,
                                        variationId,
                                        desc,
                                        batchDocNo,
                                        user,
                                        count);
                                    if (serials.Count > 0)
                                    {
                                        createdSerialLabels.AddRange(serials);
                                    }
                                }
                            }
                            catch { /* best-effort; do not break saving on ledger failure */ }
                        }

                        tran.Commit();

                        // Attempt to print the saved stock counts for this batch (do not block on print errors)
                        try
                        {
                            if (savedLines != null && savedLines.Count > 0)
                            {
                                PostingEvents.PrintStockCounts(batchDocNo, savedLines);
                            }
                        }
                        catch { }

                        // Print barcode labels for generated serial numbers using the label printer setup.
                        try
                        {
                            if (createdSerialLabels.Count > 0)
                            {
                                MainForm.PrintSerialNumberLabels(createdSerialLabels);
                            }
                        }
                        catch { }
                    }
                }

                // After successfully posting stock counts, call CreatePurchaseOnlineOrder
                // with the stock count document number. This is best-effort and any
                // errors should not block the UI or saving.
                try
                {
                    var resp = OnlinefunctionsEvents.CreatePurchaseOnlineOrderFromStockCounts(batchDocNo);
                    try { System.Diagnostics.Debug.WriteLine($"StockCountsForm: CreatePurchaseOnlineOrderFromStockCounts for '{batchDocNo}' response: {resp}"); } catch { }
                }
                catch (Exception exSync)
                {
                    try { System.Diagnostics.Debug.WriteLine($"StockCountsForm: CreatePurchaseOnlineOrder failed for '{batchDocNo}': {exSync.Message}"); } catch { }
                    try { MessageBox.Show($"CreatePurchaseOnlineOrderFromStockCounts failed: {exSync.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
                }

                Close();
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Failed to save stock counts: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }
    }
}
