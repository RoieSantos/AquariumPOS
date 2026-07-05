using System;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class TransferHeaderForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView grid = null!;
        private Button newButton = null!;
        private Button deleteButton = null!;
        private Button refreshButton = null!;
        private Button closeButton = null!;

        public TransferHeaderForm()
        {
            InitializeComponent();
            EnsureTables();
            LoadData();
        }

        private void InitializeComponent()
        {
            Text = "Transfer Order List";
            Size = new Size(1180, 600);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            grid = new DataGridView
            {
                Dock = DockStyle.Top,
                Height = 460,
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
            closeButton = new Button { Text = "Close", Size = new Size(100, 44) };

            newButton.Click += NewButton_Click;
            deleteButton.Click += DeleteButton_Click;
            refreshButton.Click += (s, e) => LoadData();
            closeButton.Click += (s, e) => Close();

            panel.Controls.AddRange(new Control[] { newButton, deleteButton, refreshButton, closeButton });

            Controls.Add(grid);
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
                grid.Rows.Clear();
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT [No.], [Description], [From Warehouse], [To Warehouse], [Transfer Date], [Receive Date] FROM [Transfer Header] ORDER BY [No.]", conn);
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string no = rdr["No."] != DBNull.Value ? rdr["No."].ToString() ?? "" : "";
                    string desc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                    string fromWarehouse = rdr["From Warehouse"] != DBNull.Value ? rdr["From Warehouse"].ToString() ?? "" : "";
                    string toWarehouse = rdr["To Warehouse"] != DBNull.Value ? rdr["To Warehouse"].ToString() ?? "" : "";
                    string transferDate = "";
                    string receiveDate = "";
                    try { if (rdr["Transfer Date"] != DBNull.Value) transferDate = Convert.ToDateTime(rdr["Transfer Date"]).ToString("yyyy-MM-dd"); } catch { }
                    try { if (rdr["Receive Date"] != DBNull.Value) receiveDate = Convert.ToDateTime(rdr["Receive Date"]).ToString("yyyy-MM-dd"); } catch { }
                    grid.Rows.Add(no, desc, fromWarehouse, toWarehouse, transferDate, receiveDate);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load Transfer Header: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
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

                using var doc = new TransferOrdersForm(no);
                doc.ShowDialog(this);
                LoadData();
            }
            catch (Exception ex)
            {
                try { MessageBox.Show(this, $"Failed to open Transfer Order: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private void NewButton_Click(object? sender, EventArgs e)
        {
            try
            {
                string newNo = CreateNewTransferHeader();
                using var doc = new TransferOrdersForm(newNo);
                doc.ShowDialog(this);
                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to create Transfer Order: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private string CreateNewTransferHeader()
        {
            const string prefix = "TO-";
            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(connectionString);

            using var conn = new SqlConnection(connectionString);
            conn.Open();
            using var tx = conn.BeginTransaction(System.Data.IsolationLevel.Serializable);

            int lastNo = 0;
            using (var cmd = new SqlCommand(@"
SELECT MAX(TRY_CONVERT(int, SUBSTRING([No.], 4, 50)))
FROM [Transfer Header]
WHERE [No.] LIKE 'TO-%'", conn, tx))
            {
                object? obj = cmd.ExecuteScalar();
                if (obj != null && obj != DBNull.Value)
                {
                    try { lastNo = Convert.ToInt32(obj); } catch { lastNo = 0; }
                }
            }

            string newNo = prefix + (lastNo + 1).ToString("D8");
            using (var ins = new SqlCommand(@"
INSERT INTO [Transfer Header] ([No.], [Description], [Transfer Date], [Receive Date], [To Warehouse ID], [To Warehouse])
VALUES (@No, @Description, @TransferDate, @ReceiveDate, @ToWarehouseId, @ToWarehouse)", conn, tx))
            {
                ins.Parameters.AddWithValue("@No", newNo);
                ins.Parameters.AddWithValue("@Description", "");
                ins.Parameters.AddWithValue("@TransferDate", DateTime.Today);
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
                MessageBox.Show(this, "Select a transfer order to delete.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var row = grid.SelectedRows[0];
            string no = (row.Cells["No"].Value ?? string.Empty).ToString() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(no)) return;

            if (MessageBox.Show(this, $"Delete transfer order {no}?", "Confirm Delete", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
                return;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var tx = conn.BeginTransaction();
                using (var deleteLines = new SqlCommand("DELETE FROM [Transfer Line] WHERE [Document No.] = @No", conn, tx))
                {
                    deleteLines.Parameters.AddWithValue("@No", no);
                    deleteLines.ExecuteNonQuery();
                }

                using (var deleteHeader = new SqlCommand("DELETE FROM [Transfer Header] WHERE [No.] = @No", conn, tx))
                {
                    deleteHeader.Parameters.AddWithValue("@No", no);
                    deleteHeader.ExecuteNonQuery();
                }

                tx.Commit();
                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to delete transfer order: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}