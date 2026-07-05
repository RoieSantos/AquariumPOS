using System;
using System.Data;
using System.Drawing;
using System.Windows.Forms;
using System.Data.SqlClient;
using System.Runtime.Versioning;

namespace AquariumPOS
{
    [SupportedOSPlatform("windows")]
    public class PurchaseHeaderForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView grid = null!;
        private Button newButton = null!;
        private Button saveButton = null!;
        private Button deleteButton = null!;
        private Button refreshButton = null!;
        private Button closeButton = null!;

        public PurchaseHeaderForm()
        {
            InitializeComponent();
            LoadData();
        }

        private void InitializeComponent()
        {
            this.Text = "Purchase Header";
            this.Size = new Size(900, 600);
            this.StartPosition = FormStartPosition.CenterParent;
            this.BackColor = Color.White;

            grid = new DataGridView()
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
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "PODate", HeaderText = "PO Date", Width = 140 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ReceivedDate", HeaderText = "Received Date", Width = 140 });

            var panel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 64,
                FlowDirection = FlowDirection.LeftToRight,
                Padding = new Padding(8)
            };

            newButton = new Button { Text = "New", Size = new Size(100, 44) };
            saveButton = new Button { Text = "Save", Size = new Size(100, 44) };
            deleteButton = new Button { Text = "Delete", Size = new Size(100, 44) };
            refreshButton = new Button { Text = "Refresh", Size = new Size(100, 44) };
            closeButton = new Button { Text = "Close", Size = new Size(100, 44) };

            newButton.Click += NewButton_Click;
            saveButton.Click += SaveButton_Click;
            deleteButton.Click += DeleteButton_Click;
            refreshButton.Click += (s, e) => LoadData();
            closeButton.Click += (s, e) => this.Close();

            panel.Controls.AddRange(new Control[] { newButton, saveButton, deleteButton, refreshButton, closeButton });

            this.Controls.Add(grid);
            this.Controls.Add(panel);
        }

        private void Grid_CellDoubleClick(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (e.RowIndex < 0) return;
                var row = grid.Rows[e.RowIndex];
                string no = (row.Cells["No"].Value ?? string.Empty).ToString() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(no)) return;

                using (var doc = new PurchaseOrdersForm(no))
                {
                    doc.ShowDialog(this);
                }
            }
            catch (Exception ex)
            {
                try { MessageBox.Show(this, $"Failed to open Purchase Orders: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private void LoadData()
        {
            try
            {
                grid.Rows.Clear();
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var cmd = new SqlCommand("SELECT [No.], [Description], [PO Date], [Received Date] FROM PurchaseHeader ORDER BY [No.]", conn))
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read())
                        {
                            string no = rdr["No."] != DBNull.Value ? rdr["No."].ToString() ?? "" : "";
                            string desc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                            string poDate = "";
                            string recvDate = "";
                            try { if (rdr["PO Date"] != DBNull.Value) poDate = Convert.ToDateTime(rdr["PO Date"]).ToString("yyyy-MM-dd"); } catch { }
                            try { if (rdr["Received Date"] != DBNull.Value) recvDate = Convert.ToDateTime(rdr["Received Date"]).ToString("yyyy-MM-dd"); } catch { }
                            grid.Rows.Add(no, desc, poDate, recvDate);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load PurchaseHeader: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void NewButton_Click(object? sender, EventArgs e)
        {
            try
            {
                string newNo = CreateNewPurchaseOrderHeader();
                LoadData();

                // Select the newly created row and start editing Description
                foreach (DataGridViewRow r in grid.Rows)
                {
                    string no = (r.Cells[0].Value ?? string.Empty).ToString() ?? "";
                    if (string.Equals(no, newNo, StringComparison.OrdinalIgnoreCase))
                    {
                        r.Selected = true;
                        grid.CurrentCell = r.Cells[1]; // Description (read-only)
                        break;
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to create new Purchase Order: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private string CreateNewPurchaseOrderHeader()
        {
            // Number series: PO-00000001
            const string prefix = "PO-";

            using (var conn = new SqlConnection(connectionString))
            {
                conn.Open();
                using (var tx = conn.BeginTransaction(System.Data.IsolationLevel.Serializable))
                {
                    // Get last numeric part for PO- series
                    int lastNo = 0;
                    using (var cmd = new SqlCommand(@"
                        SELECT MAX(TRY_CONVERT(int, SUBSTRING([No.], 4, 50)))
                        FROM PurchaseHeader
                        WHERE [No.] LIKE 'PO-%'", conn, tx))
                    {
                        object? obj = cmd.ExecuteScalar();
                        if (obj != null && obj != DBNull.Value)
                        {
                            try { lastNo = Convert.ToInt32(obj); } catch { lastNo = 0; }
                        }
                    }

                    int next = lastNo + 1;
                    string newNo = prefix + next.ToString("D8");

                    // Insert new header
                    using (var ins = new SqlCommand(@"
INSERT INTO PurchaseHeader ([No.], [Description], [PO Date], [Received Date])
VALUES (@No, @Desc, @PODate, @ReceivedDate)", conn, tx))
                    {
                        ins.Parameters.AddWithValue("@No", newNo);
                        ins.Parameters.AddWithValue("@Desc", "");
                        ins.Parameters.AddWithValue("@PODate", DateTime.Today);
                        ins.Parameters.AddWithValue("@ReceivedDate", DBNull.Value);
                        ins.ExecuteNonQuery();
                    }

                    tx.Commit();
                    return newNo;
                }
            }
        }

        private void SaveButton_Click(object? sender, EventArgs e)
        {
            if (grid.CurrentRow == null && grid.SelectedRows.Count == 0)
            {
                MessageBox.Show(this, "Select a row to save or click New to create one.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var row = grid.CurrentRow ?? grid.SelectedRows[0];
            string no = ((row.Cells[0].Value ?? string.Empty).ToString() ?? string.Empty).Trim();
            string desc = ((row.Cells[1].Value ?? string.Empty).ToString() ?? string.Empty).Trim();
            string poDateTxt = ((row.Cells[2].Value ?? string.Empty).ToString() ?? string.Empty).Trim();
            string recvDateTxt = ((row.Cells[3].Value ?? string.Empty).ToString() ?? string.Empty).Trim();

            if (string.IsNullOrWhiteSpace(no))
            {
                MessageBox.Show(this, "No. is required.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            DateTime? poDate = null;
            DateTime? recvDate = null;
            if (!string.IsNullOrWhiteSpace(poDateTxt)) { if (DateTime.TryParse(poDateTxt, out var dt)) poDate = dt; }
            if (!string.IsNullOrWhiteSpace(recvDateTxt)) { if (DateTime.TryParse(recvDateTxt, out var dt2)) recvDate = dt2; }

            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    // Check existence
                    using (var check = new SqlCommand("SELECT COUNT(1) FROM PurchaseHeader WHERE [No.] = @No", conn))
                    {
                        check.Parameters.AddWithValue("@No", no);
                        var exists = Convert.ToInt32(check.ExecuteScalar() ?? 0) > 0;
                        if (exists)
                        {
                            using (var upd = new SqlCommand("UPDATE PurchaseHeader SET [Description] = @Desc, [PO Date] = @PODate, [Received Date] = @ReceivedDate WHERE [No.] = @No", conn))
                            {
                                upd.Parameters.AddWithValue("@Desc", desc);
                                upd.Parameters.AddWithValue("@PODate", (object?)poDate ?? DBNull.Value);
                                upd.Parameters.AddWithValue("@ReceivedDate", (object?)recvDate ?? DBNull.Value);
                                upd.Parameters.AddWithValue("@No", no);
                                upd.ExecuteNonQuery();
                            }
                        }
                        else
                        {
                            using (var ins = new SqlCommand("INSERT INTO PurchaseHeader ([No.], [Description], [PO Date], [Received Date]) VALUES (@No, @Desc, @PODate, @ReceivedDate)", conn))
                            {
                                ins.Parameters.AddWithValue("@No", no);
                                ins.Parameters.AddWithValue("@Desc", desc);
                                ins.Parameters.AddWithValue("@PODate", (object?)poDate ?? DBNull.Value);
                                ins.Parameters.AddWithValue("@ReceivedDate", (object?)recvDate ?? DBNull.Value);
                                ins.ExecuteNonQuery();
                            }
                        }
                    }
                }

                MessageBox.Show(this, "Saved.", "Saved", MessageBoxButtons.OK, MessageBoxIcon.Information);
                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to save: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void DeleteButton_Click(object? sender, EventArgs e)
        {
            if (grid.SelectedRows.Count == 0)
            {
                MessageBox.Show(this, "Select a row to delete.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var row = grid.SelectedRows[0];
            string no = ((row.Cells[0].Value ?? string.Empty).ToString() ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(no))
            {
                MessageBox.Show(this, "Selected row has empty No.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // Do not allow delete if Received Date is already filled (treat as received/posted).
            string recvDateTxt = ((row.Cells[3].Value ?? string.Empty).ToString() ?? string.Empty).Trim();
            if (!string.IsNullOrWhiteSpace(recvDateTxt))
            {
                MessageBox.Show(this, "Cannot delete because Received Date is already filled.", "Delete", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var dr = MessageBox.Show(this, $"Delete Purchase header '{no}'?", "Confirm", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (dr != DialogResult.Yes) return;

            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var del = new SqlCommand("DELETE FROM PurchaseHeader WHERE [No.] = @No", conn))
                    {
                        del.Parameters.AddWithValue("@No", no);
                        del.ExecuteNonQuery();
                    }
                }
                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to delete: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
