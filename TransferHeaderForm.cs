using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class TransferHeaderForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly TransferOrderData.DocumentTableContext documentContext;
        private readonly List<TransferListRow> transferRows = new();
        private DataGridView grid = null!;
        private TextBox searchTextBox = null!;
        private Button newButton = null!;
        private Button deleteButton = null!;
        private Button refreshButton = null!;
        private Button syncButton = null!;
        private Button closeButton = null!;

        private sealed class TransferListRow
        {
            public string No { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string CreatedDate { get; init; } = string.Empty;
            public string Status { get; init; } = string.Empty;
            public string FromWarehouse { get; init; } = string.Empty;
            public string ToWarehouse { get; init; } = string.Empty;
            public string TransferDate { get; init; } = string.Empty;
            public string ReceiveDate { get; init; } = string.Empty;
        }

        public TransferHeaderForm()
            : this(TransferOrderData.PostedTransferOrders)
        {
        }

        internal TransferHeaderForm(TransferOrderData.DocumentTableContext documentContext)
        {
            this.documentContext = documentContext;
            InitializeComponent();
            EnsureTables();
            SyncTransferRequestsOnOpen();
            LoadData();
        }

        private void SyncTransferRequestsOnOpen()
        {
            if (!ReferenceEquals(documentContext, TransferOrderData.TransferRequests))
                return;

            try
            {
                UseWaitCursor = true;
                PostingEvents.SyncTransferRequestsFromSupabaseToLocalDb();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Transfer request sync failed: {ex.Message}", "Transfer Request Sync", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            finally
            {
                UseWaitCursor = false;
            }
        }

        private void InitializeComponent()
        {
            Text = documentContext.ListTitle;
            Size = new Size(1180, 600);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            var searchPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 52,
                Padding = new Padding(12, 12, 12, 8)
            };

            var searchLabel = new Label
            {
                Text = "Search:",
                AutoSize = true,
                Location = new Point(12, 15),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            searchTextBox = new TextBox
            {
                Location = new Point(80, 11),
                Width = 320,
                Font = new Font("Arial", 10)
            };
            searchTextBox.TextChanged += (s, e) => ApplySearchFilter();

            searchPanel.Controls.Add(searchLabel);
            searchPanel.Controls.Add(searchTextBox);

            grid = new DataGridView
            {
                Dock = DockStyle.Fill,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                ReadOnly = true,
                EditMode = DataGridViewEditMode.EditProgrammatically,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells
            };

            grid.CellDoubleClick += Grid_CellDoubleClick;

            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "No", HeaderText = "No.", Width = 140 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Description", HeaderText = "Description", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "CreatedDate", HeaderText = "Created Date", Width = 130 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Status", HeaderText = "Status", Width = 150 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "FromWarehouse", HeaderText = "From Warehouse", Width = 170 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ToWarehouse", HeaderText = "To Warehouse", Width = 170 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "TransferDate", HeaderText = "Transfer Date", Width = 140 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ReceiveDate", HeaderText = "Receive Date", Width = 140 });

            var panel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 64,
                FlowDirection = FlowDirection.LeftToRight,
                Padding = new Padding(8)
            };

            newButton = new Button { Text = "New", Size = new Size(100, 44) };
            deleteButton = new Button { Text = "Delete", Size = new Size(100, 44) };
            refreshButton = new Button { Text = "Refresh", Size = new Size(100, 44) };
            syncButton = new Button { Text = "Sync", Size = new Size(100, 44) };
            closeButton = new Button { Text = "Close", Size = new Size(100, 44) };

            newButton.Click += NewButton_Click;
            deleteButton.Click += DeleteButton_Click;
            refreshButton.Click += (s, e) => LoadData();
            syncButton.Click += SyncButton_Click;
            closeButton.Click += (s, e) => Close();
            newButton.Visible = !documentContext.IsReadOnly;
            deleteButton.Visible = !documentContext.IsReadOnly;
            syncButton.Visible = documentContext.AllowSync;

            panel.Controls.AddRange(new Control[] { newButton, deleteButton, refreshButton, syncButton, closeButton });

            Controls.Add(grid);
            Controls.Add(searchPanel);
            Controls.Add(panel);
        }

        private void EnsureTables()
        {
            TransferOrderData.EnsureTablesExist(connectionString);
        }

        private void LoadData()
        {
            try
            {
                transferRows.Clear();
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                var currentWarehouse = TransferOrderData.GetCurrentWarehouse(connectionString);
                string sql = $"SELECT [No.], [Description], [Created Date], [Status], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse], [Transfer Date], [Receive Date] FROM {documentContext.HeaderTableName}";

                bool filterByFromWarehouse = currentWarehouse != null && (currentWarehouse.IsProductionWarehouse || currentWarehouse.IsStockWarehouse);
                bool filterByToWarehouse = currentWarehouse != null && !currentWarehouse.IsProductionWarehouse && !currentWarehouse.IsStockWarehouse;

                if (filterByFromWarehouse)
                {
                    sql += " WHERE (ISNULL([From Warehouse ID], '') = @CurrentWarehouseId OR ISNULL([From Warehouse], '') = @CurrentWarehouseName)";
                }
                else if (filterByToWarehouse)
                {
                    sql += " WHERE (ISNULL([To Warehouse ID], '') = @CurrentWarehouseId OR ISNULL([To Warehouse], '') = @CurrentWarehouseName)";
                }

                sql += " ORDER BY [No.]";

                using var cmd = new SqlCommand(sql, conn);
                if ((filterByFromWarehouse || filterByToWarehouse) && currentWarehouse != null)
                {
                    cmd.Parameters.AddWithValue("@CurrentWarehouseId", string.IsNullOrWhiteSpace(currentWarehouse.Id) ? string.Empty : currentWarehouse.Id);
                    cmd.Parameters.AddWithValue("@CurrentWarehouseName", string.IsNullOrWhiteSpace(currentWarehouse.Name) ? string.Empty : currentWarehouse.Name);
                }

                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string no = rdr["No."] != DBNull.Value ? rdr["No."].ToString() ?? "" : "";
                    string desc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                    string createdDate = "";
                    try { if (rdr["Created Date"] != DBNull.Value) createdDate = Convert.ToDateTime(rdr["Created Date"]).ToString("yyyy-MM-dd"); } catch { }
                    string status = rdr["Status"] != DBNull.Value ? rdr["Status"].ToString() ?? "" : "";
                    string fromWarehouse = rdr["From Warehouse"] != DBNull.Value ? rdr["From Warehouse"].ToString() ?? "" : "";
                    string toWarehouse = rdr["To Warehouse"] != DBNull.Value ? rdr["To Warehouse"].ToString() ?? "" : "";
                    string transferDate = "";
                    string receiveDate = "";
                    try { if (rdr["Transfer Date"] != DBNull.Value) transferDate = Convert.ToDateTime(rdr["Transfer Date"]).ToString("yyyy-MM-dd"); } catch { }
                    try { if (rdr["Receive Date"] != DBNull.Value) receiveDate = Convert.ToDateTime(rdr["Receive Date"]).ToString("yyyy-MM-dd"); } catch { }
                    transferRows.Add(new TransferListRow
                    {
                        No = no,
                        Description = desc,
                        CreatedDate = createdDate,
                        Status = status,
                        FromWarehouse = fromWarehouse,
                        ToWarehouse = toWarehouse,
                        TransferDate = transferDate,
                        ReceiveDate = receiveDate
                    });
                }

                ApplySearchFilter();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load {documentContext.DocumentTitle}: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ApplySearchFilter()
        {
            string filter = searchTextBox?.Text?.Trim() ?? string.Empty;
            IEnumerable<TransferListRow> filteredRows = transferRows;

            if (!string.IsNullOrWhiteSpace(filter))
            {
                filteredRows = transferRows.Where(row =>
                    row.No.Contains(filter, StringComparison.OrdinalIgnoreCase)
                    || row.Description.Contains(filter, StringComparison.OrdinalIgnoreCase)
                    || row.CreatedDate.Contains(filter, StringComparison.OrdinalIgnoreCase)
                    || row.Status.Contains(filter, StringComparison.OrdinalIgnoreCase)
                    || row.FromWarehouse.Contains(filter, StringComparison.OrdinalIgnoreCase)
                    || row.ToWarehouse.Contains(filter, StringComparison.OrdinalIgnoreCase)
                    || row.TransferDate.Contains(filter, StringComparison.OrdinalIgnoreCase)
                    || row.ReceiveDate.Contains(filter, StringComparison.OrdinalIgnoreCase));
            }

            grid.Rows.Clear();
            foreach (var row in filteredRows)
            {
                grid.Rows.Add(row.No, row.Description, row.CreatedDate, row.Status, row.FromWarehouse, row.ToWarehouse, row.TransferDate, row.ReceiveDate);
            }
        }

        private void Grid_CellDoubleClick(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (e.RowIndex < 0) return;
                var row = grid.Rows[e.RowIndex];
                string no = (row.Cells["No"].Value ?? string.Empty).ToString() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(no)) return;

                using var doc = new TransferOrdersForm(no, documentContext);
                doc.ShowDialog(this);
                LoadData();
            }
            catch (Exception ex)
            {
                try { MessageBox.Show(this, $"Failed to open {documentContext.DocumentTitle}: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private void NewButton_Click(object? sender, EventArgs e)
        {
            try
            {
                string newNo = CreateNewTransferHeader();
                using var doc = new TransferOrdersForm(newNo, documentContext);
                doc.ShowDialog(this);
                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to create {documentContext.DocumentTitle}: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private string CreateNewTransferHeader()
        {
            string prefix = documentContext.NumberPrefix;
            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(connectionString);
            DateTime today = DateTime.Today;
            int prefixValueStartIndex = prefix.Length + 1;

            using var conn = new SqlConnection(connectionString);
            conn.Open();
            using var tx = conn.BeginTransaction(System.Data.IsolationLevel.Serializable);

            int lastNo = 0;
            using (var cmd = new SqlCommand(@"
SELECT MAX(TRY_CONVERT(int, SUBSTRING([No.], " + prefixValueStartIndex + @", 50)))
FROM " + documentContext.HeaderTableName + @"
WHERE [No.] LIKE @PrefixPattern", conn, tx))
            {
                cmd.Parameters.AddWithValue("@PrefixPattern", prefix + "%");
                object? obj = cmd.ExecuteScalar();
                if (obj != null && obj != DBNull.Value)
                {
                    try { lastNo = Convert.ToInt32(obj); } catch { lastNo = 0; }
                }
            }

            string newNo = prefix + (lastNo + 1).ToString("D8");
            int requestNumberToday = 1;
            using (var countCmd = new SqlCommand(@"
SELECT COUNT(1)
FROM " + documentContext.HeaderTableName + @"
WHERE CAST([Created At] AS date) = @Today", conn, tx))
            {
                countCmd.Parameters.AddWithValue("@Today", today);
                requestNumberToday = Convert.ToInt32(countCmd.ExecuteScalar() ?? 0) + 1;
            }

            string description = $"{requestNumberToday} {documentContext.NewDescriptionLabel} for {today:yyyy-MM-dd}";
            using (var ins = new SqlCommand(@"
INSERT INTO " + documentContext.HeaderTableName + @" ([No.], [Description], [Created Date], [Status], [Transfer Date], [Receive Date], [To Warehouse ID], [To Warehouse])
VALUES (@No, @Description, @CreatedDate, @Status, @TransferDate, @ReceiveDate, @ToWarehouseId, @ToWarehouse)", conn, tx))
            {
                ins.Parameters.AddWithValue("@No", newNo);
                ins.Parameters.AddWithValue("@Description", description);
                ins.Parameters.AddWithValue("@CreatedDate", today);
                ins.Parameters.AddWithValue("@Status", DBNull.Value);
                ins.Parameters.AddWithValue("@TransferDate", today);
                ins.Parameters.AddWithValue("@ReceiveDate", DBNull.Value);
                ins.Parameters.AddWithValue("@ToWarehouseId", string.IsNullOrWhiteSpace(currentWarehouse?.Id) ? (object)DBNull.Value : currentWarehouse!.Id);
                ins.Parameters.AddWithValue("@ToWarehouse", string.IsNullOrWhiteSpace(currentWarehouse?.Name) ? (object)DBNull.Value : currentWarehouse!.Name);
                ins.ExecuteNonQuery();
            }

            tx.Commit();
            return newNo;
        }

        private void DeleteButton_Click(object? sender, EventArgs e)
        {
            if (grid.SelectedRows.Count == 0)
            {
                MessageBox.Show(this, $"Select a {documentContext.DocumentDisplayName} to delete.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var row = grid.SelectedRows[0];
            string no = (row.Cells["No"].Value ?? string.Empty).ToString() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(no)) return;

            if (MessageBox.Show(this, $"Delete {documentContext.DocumentDisplayName} {no}?", "Confirm Delete", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
                return;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var tx = conn.BeginTransaction();
                using (var deleteLines = new SqlCommand($"DELETE FROM {documentContext.LineTableName} WHERE [Document No.] = @No", conn, tx))
                {
                    deleteLines.Parameters.AddWithValue("@No", no);
                    deleteLines.ExecuteNonQuery();
                }

                using (var deleteHeader = new SqlCommand($"DELETE FROM {documentContext.HeaderTableName} WHERE [No.] = @No", conn, tx))
                {
                    deleteHeader.Parameters.AddWithValue("@No", no);
                    deleteHeader.ExecuteNonQuery();
                }

                tx.Commit();
                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to delete {documentContext.DocumentDisplayName}: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void SyncButton_Click(object? sender, EventArgs e)
        {
            if (!documentContext.AllowSync)
                return;

            try
            {
                UseWaitCursor = true;
                syncButton.Enabled = false;

                var result = PostingEvents.SyncLatestTransfersToLocalDb();
                LoadData();

                MessageBox.Show(
                    this,
                    $"Transfer sync completed.\n\nUpdated/New: {result.SyncedCount}\nUnchanged Skipped: {result.SkippedCount}",
                    "Transfer Sync",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Transfer sync failed: {ex.Message}", "Transfer Sync", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                UseWaitCursor = false;
                syncButton.Enabled = true;
            }
        }
    }
}