using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class OnlineOrderLinesForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly string orderId;
        private DataGridView dgv = null!;

        public OnlineOrderLinesForm(string orderId)
        {
            this.orderId = orderId ?? string.Empty;
            Text = $"Order Lines - {orderId}";
            // Start maximized and use larger bold fonts for readability
            WindowState = FormWindowState.Maximized;
            StartPosition = FormStartPosition.CenterParent;
            this.Font = new Font(this.Font.FontFamily, 11f, FontStyle.Bold);

            dgv = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect
            };
            dgv.Font = new Font(dgv.Font.FontFamily, 10f, FontStyle.Bold);

            Controls.Add(dgv);
            Load += OnlineOrderLinesForm_Load;
        }

        // The form now always loads its data from the dbo.OnlineOrderLines table using the OrderID constructor.

        private void OnlineOrderLinesForm_Load(object? sender, EventArgs e)
        {
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    var sql = @"SELECT OrderID, ItemCode, Description , Note , Quantity , Price, Discount, GrossAmount FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID ORDER BY LineID";
                    using (var cmd = new SqlCommand(sql, conn))
                    {
                        cmd.Parameters.AddWithValue("@OrderID", orderId);
                        var adapter = new SqlDataAdapter(cmd);
                        var dt = new DataTable();
                        adapter.Fill(dt);
                        EnsureItemCodeColumn(dt);
                        dgv.DataSource = dt;
                        // Make ItemCode column more visible and place it after LineID if present
                        if (dgv.Columns.Contains("ItemCode"))
                        {
                            dgv.Columns["ItemCode"].HeaderText = "ItemCode";
                            try { dgv.Columns["ItemCode"].DisplayIndex = Math.Min(2, dgv.Columns.Count - 1); } catch { }
                        }
                        // Adjust column widths: use Fill mode but tune FillWeight for relative sizing
                        try
                        {
                            dgv.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
                            // Default small weight
                            int small = 60;
                            int large = 300;

                            if (dgv.Columns.Contains("OrderID"))
                            {
                                dgv.Columns["OrderID"].FillWeight = small; // smaller
                                dgv.Columns["OrderID"].HeaderText = "OrderID";
                            }
                            if (dgv.Columns.Contains("Description"))
                            {
                                dgv.Columns["Description"].FillWeight = large; // wider
                                dgv.Columns["Description"].HeaderText = "Description";
                            }
                            if (dgv.Columns.Contains("ItemCode"))
                            {
                                dgv.Columns["ItemCode"].FillWeight = small; // smaller
                            }
                            if (dgv.Columns.Contains("Note"))
                            {
                                dgv.Columns["Note"].FillWeight = large; // wider
                            }
                            if (dgv.Columns.Contains("Quantity"))
                            {
                                dgv.Columns["Quantity"].FillWeight = small; // smaller
                                dgv.Columns["Quantity"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                                dgv.Columns["Quantity"].DefaultCellStyle.Format = "N0"; // thousands separator, no decimals
                            }
                            if (dgv.Columns.Contains("Price"))
                            {
                                dgv.Columns["Price"].FillWeight = small; // smaller
                                dgv.Columns["Price"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                                dgv.Columns["Price"].DefaultCellStyle.Format = "N2"; // thousands separator, 2 decimals
                            }
                            if (dgv.Columns.Contains("Discount"))
                            {
                                dgv.Columns["Discount"].FillWeight = small; // smaller
                                dgv.Columns["Discount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                                dgv.Columns["Discount"].DefaultCellStyle.Format = "N2";
                            }
                            if (dgv.Columns.Contains("GrossAmount"))
                            {
                                dgv.Columns["GrossAmount"].FillWeight = small; // smaller
                                dgv.Columns["GrossAmount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                                dgv.Columns["GrossAmount"].DefaultCellStyle.Format = "N2";
                            }
                            // Also format NetAmount and UnitCost if present
                            if (dgv.Columns.Contains("NetAmount"))
                            {
                                dgv.Columns["NetAmount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                                dgv.Columns["NetAmount"].DefaultCellStyle.Format = "N2";
                                dgv.Columns["NetAmount"].FillWeight = small;
                            }
                            if (dgv.Columns.Contains("UnitCost"))
                            {
                                dgv.Columns["UnitCost"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                                dgv.Columns["UnitCost"].DefaultCellStyle.Format = "N2";
                                dgv.Columns["UnitCost"].FillWeight = small;
                            }
                        }
                        catch { }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading order lines: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // Ensure the DataTable has an ItemCode column. If it's missing, try to create it from
        // product_display_id or product_id if present.
        private void EnsureItemCodeColumn(DataTable dt)
        {
            if (dt == null) return;

            // Prefer product_display_id, then product_id as the source for ItemCode
            string? sourceCol = null;
            if (dt.Columns.Contains("product_display_id")) sourceCol = "product_display_id";
            else if (dt.Columns.Contains("product_id")) sourceCol = "product_id";

            // If ItemCode column does not exist, add it and populate from sourceCol
            if (!dt.Columns.Contains("ItemCode"))
            {
                var col = new DataColumn("ItemCode", typeof(string));
                dt.Columns.Add(col);

                if (!string.IsNullOrEmpty(sourceCol))
                {
                    foreach (DataRow r in dt.Rows)
                    {
                        try { r["ItemCode"] = r[sourceCol]?.ToString() ?? string.Empty; }
                        catch { r["ItemCode"] = string.Empty; }
                    }
                }
            }
            else
            {
                // If ItemCode exists but is entirely empty/null, populate it from sourceCol
                bool allEmpty = true;
                foreach (DataRow r in dt.Rows)
                {
                    var v = r["ItemCode"]?.ToString();
                    if (!string.IsNullOrWhiteSpace(v))
                    {
                        allEmpty = false; break;
                    }
                }

                if (allEmpty && !string.IsNullOrEmpty(sourceCol))
                {
                    foreach (DataRow r in dt.Rows)
                    {
                        try { r["ItemCode"] = r[sourceCol]?.ToString() ?? string.Empty; }
                        catch { r["ItemCode"] = string.Empty; }
                    }
                }
            }
        }
    }
}
