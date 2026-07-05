using System;
using System.Data;
using System.Drawing;
using System.Windows.Forms;
using System.Data.SqlClient;

namespace AquariumPOS
{
    public class PurchaseOrderLinesForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView grid = null!;

        private bool suppressAutoSave = false;

        private string? currentDocument = null;
        private bool documentFixed = false;

        public PurchaseOrderLinesForm()
        {
            InitializeComponent();
            LoadData();
        }

        // Load only lines for a specific document. If docNo is null or empty, the grid will be cleared.
        public void LoadForDocument(string? docNo)
        {
            try
            {
                suppressAutoSave = true;
                grid.Rows.Clear();
                currentDocument = docNo;
                documentFixed = !string.IsNullOrWhiteSpace(docNo);
                if (string.IsNullOrWhiteSpace(docNo)) return;
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var cmd = new SqlCommand("SELECT [Document No.], [Item No.], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty Needed], [Qty Received] FROM PurchaseLine WHERE [Document No.] = @Doc ORDER BY [Line No.]", conn))
                    {
                        cmd.Parameters.AddWithValue("@Doc", docNo);
                        using (var rdr = cmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                string doc = rdr["Document No."] != DBNull.Value ? rdr["Document No."].ToString() ?? "" : "";
                                string item = rdr["Item No."] != DBNull.Value ? rdr["Item No."].ToString() ?? "" : "";
                                string desc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                                string cat = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString() ?? "" : "";
                                string line = rdr["Line No."] != DBNull.Value ? rdr["Line No."].ToString() ?? "" : "";
                                string avail = rdr["Available QTY"] != DBNull.Value ? rdr["Available QTY"].ToString() ?? "" : "";
                                string need = rdr["Qty Needed"] != DBNull.Value ? rdr["Qty Needed"].ToString() ?? "" : "";
                                string recv = rdr["Qty Received"] != DBNull.Value ? rdr["Qty Received"].ToString() ?? "" : "";
                                int rowIndex = grid.Rows.Add(doc, item, desc, cat, line, avail, need, recv);
                                if (documentFixed) grid.Rows[rowIndex].Cells[0].ReadOnly = true;
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load PurchaseLine for document '{docNo}': {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                suppressAutoSave = false;
            }
        }

        private void InitializeComponent()
        {
            this.Text = "Purchase Order Lines";
            this.Size = new Size(1000, 600);
            this.StartPosition = FormStartPosition.CenterParent;
            this.BackColor = Color.White;

            grid = new DataGridView()
            {
                Dock = DockStyle.Top,
                Height = 480,
                AllowUserToAddRows = true,
                AllowUserToDeleteRows = true,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells,
                EditMode = DataGridViewEditMode.EditOnKeystrokeOrF2,
                ReadOnly = false
            };

            grid.DefaultValuesNeeded += Grid_DefaultValuesNeeded;
            grid.CellEndEdit += Grid_CellEndEdit;

            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "DocumentNo", HeaderText = "Document No.", Width = 160 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ItemNo", HeaderText = "Item No.", Width = 200 });
            // show description and category code after Item No.
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Description", HeaderText = "Description", Width = 400 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "CategoryCode", HeaderText = "Category Code", Width = 140 });
            // keep LineNo for data/storage but hide it from the page view
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "LineNo", HeaderText = "Line No.", Width = 120, Visible = false });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "AvailableQty", HeaderText = "Available QTY", Width = 120 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyNeeded", HeaderText = "Qty Needed", Width = 120 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyReceived", HeaderText = "Qty Received", Width = 120 });

            // Make AvailableQty read-only so it's not editable in the grid
            grid.Columns["AvailableQty"].ReadOnly = true;
            // Make document/description/category uneditable in the grid.
            // Item No. stays editable so users can key in the product manually.
            grid.Columns["DocumentNo"].ReadOnly = true;
            grid.Columns["Description"].ReadOnly = true;
            grid.Columns["CategoryCode"].ReadOnly = true;

            this.Controls.Add(grid);
        }

        private void Grid_CellEndEdit(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (suppressAutoSave) return;
                if (e.RowIndex < 0 || e.ColumnIndex < 0) return;
                if (grid.Rows == null || e.RowIndex >= grid.Rows.Count) return;

                var row = grid.Rows[e.RowIndex];
                if (row == null || row.IsNewRow) return;

                var columnName = grid.Columns[e.ColumnIndex]?.Name;
                if (columnName != "ItemNo" && columnName != "QtyNeeded" && columnName != "QtyReceived") return;

                string doc = (row.Cells["DocumentNo"].Value ?? string.Empty).ToString()!.Trim();
                string lineNo = (row.Cells["LineNo"].Value ?? string.Empty).ToString()!.Trim();
                if (documentFixed && !string.IsNullOrWhiteSpace(currentDocument)) doc = currentDocument!;

                if (columnName == "ItemNo")
                {
                    HandleItemNumberEdit(row, doc, lineNo);
                    return;
                }

                if (string.IsNullOrWhiteSpace(doc) || string.IsNullOrWhiteSpace(lineNo)) return;

                if (columnName == "QtyNeeded")
                {
                    string qtyText = (row.Cells["QtyNeeded"].Value ?? string.Empty).ToString()!.Trim();
                    decimal? qtyNeeded = null;
                    if (!string.IsNullOrWhiteSpace(qtyText))
                    {
                        if (decimal.TryParse(qtyText, out var parsed)) qtyNeeded = parsed;
                        else
                        {
                            MessageBox.Show(this, "Qty Needed must be a number.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                            return;
                        }
                    }

                    SaveQtyNeeded(doc, lineNo, qtyNeeded);
                }
                else if (columnName == "QtyReceived")
                {
                    string qtyText = (row.Cells["QtyReceived"].Value ?? string.Empty).ToString()!.Trim();
                    decimal? qtyReceived = null;
                    if (!string.IsNullOrWhiteSpace(qtyText))
                    {
                        if (decimal.TryParse(qtyText, out var parsed)) qtyReceived = parsed;
                        else
                        {
                            MessageBox.Show(this, "Qty Received must be a number.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                            return;
                        }
                    }

                    SaveQtyReceived(doc, lineNo, qtyReceived);
                }
            }
            catch (Exception ex)
            {
                try { MessageBox.Show(this, $"Auto-save failed: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private void SaveQtyNeeded(string documentNo, string lineNo, decimal? qtyNeeded)
        {
            using (var conn = new SqlConnection(connectionString))
            {
                conn.Open();
                using (var cmd = new SqlCommand("UPDATE PurchaseLine SET [Qty Needed] = @Needed WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn))
                {
                    cmd.Parameters.AddWithValue("@Doc", documentNo);
                    cmd.Parameters.AddWithValue("@Line", lineNo);
                    cmd.Parameters.AddWithValue("@Needed", (object?)qtyNeeded ?? DBNull.Value);
                    cmd.ExecuteNonQuery();
                }
            }
        }

        private void SaveQtyReceived(string documentNo, string lineNo, decimal? qtyReceived)
        {
            using (var conn = new SqlConnection(connectionString))
            {
                conn.Open();
                using (var cmd = new SqlCommand("UPDATE PurchaseLine SET [Qty Received] = @Received WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn))
                {
                    cmd.Parameters.AddWithValue("@Doc", documentNo);
                    cmd.Parameters.AddWithValue("@Line", lineNo);
                    cmd.Parameters.AddWithValue("@Received", (object?)qtyReceived ?? DBNull.Value);
                    cmd.ExecuteNonQuery();
                }
            }
        }

        private void Grid_DefaultValuesNeeded(object sender, DataGridViewRowEventArgs e)
        {
            try
            {
                if (!string.IsNullOrWhiteSpace(currentDocument))
                {
                    e.Row.Cells["DocumentNo"].Value = currentDocument;
                    if (documentFixed) e.Row.Cells["DocumentNo"].ReadOnly = true;
                }
            }
            catch { }
        }

        private void HandleItemNumberEdit(DataGridViewRow row, string documentNo, string lineNo)
        {
            if (row == null || row.IsNewRow)
                return;

            string itemNo = (row.Cells["ItemNo"].Value ?? string.Empty).ToString()!.Trim();
            if (string.IsNullOrWhiteSpace(documentNo) || string.IsNullOrWhiteSpace(itemNo))
                return;

            if (string.IsNullOrWhiteSpace(lineNo))
            {
                lineNo = GetNextLineNo(documentNo);
                row.Cells["LineNo"].Value = lineNo;
            }

            var itemInfo = ResolvePurchaseItemInfo(itemNo);
            if (itemInfo == null)
            {
                MessageBox.Show(this, $"Item '{itemNo}' was not found.", "Item Not Found", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            row.Cells["ItemNo"].Value = itemInfo.ItemCode;
            row.Cells["Description"].Value = itemInfo.Description;
            row.Cells["CategoryCode"].Value = itemInfo.CategoryCode;
            row.Cells["AvailableQty"].Value = itemInfo.AvailableQty?.ToString("0.##") ?? string.Empty;

            decimal? qtyNeeded = ParseNullableDecimal((row.Cells["QtyNeeded"].Value ?? string.Empty).ToString());
            decimal? qtyReceived = ParseNullableDecimal((row.Cells["QtyReceived"].Value ?? string.Empty).ToString());
            UpsertPurchaseLine(documentNo, lineNo, itemInfo.ItemCode, itemInfo.Description, itemInfo.CategoryCode, itemInfo.AvailableQty, qtyNeeded, qtyReceived);
        }

        private sealed class PurchaseItemInfo
        {
            public string ItemCode { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string CategoryCode { get; init; } = string.Empty;
            public decimal? AvailableQty { get; init; }
        }

        private PurchaseItemInfo? ResolvePurchaseItemInfo(string itemNo)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();

            using var cmd = new SqlCommand(@"
SELECT TOP 1 [Code], [Description], [CategoryCode], [VariationId], [QuantityInStock]
FROM dbo.Items
WHERE [Code] = @ItemNo
   OR [VariationId] = @ItemNo
ORDER BY CASE WHEN [Code] = @ItemNo THEN 0 ELSE 1 END", conn);
            cmd.Parameters.AddWithValue("@ItemNo", itemNo);

            using var rdr = cmd.ExecuteReader();
            if (!rdr.Read())
                return null;

            string itemCode = rdr["Code"] != DBNull.Value ? rdr["Code"].ToString()?.Trim() ?? string.Empty : string.Empty;
            string description = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString()?.Trim() ?? string.Empty : string.Empty;
            string categoryCode = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString()?.Trim() ?? string.Empty : string.Empty;
            string variationId = rdr["VariationId"] != DBNull.Value ? rdr["VariationId"].ToString()?.Trim() ?? string.Empty : string.Empty;

            decimal? localQty = null;
            try
            {
                if (rdr["QuantityInStock"] != DBNull.Value)
                    localQty = Convert.ToDecimal(rdr["QuantityInStock"]);
            }
            catch
            {
                localQty = null;
            }

            decimal? availableQty = localQty;
            if (!string.IsNullOrWhiteSpace(variationId))
            {
                try
                {
                    var cloudQty = OnlinefunctionsEvents.GetCloudVariationAvailableQuantity(variationId, TimeSpan.FromSeconds(10));
                    if (cloudQty.HasValue)
                        availableQty = cloudQty.Value;
                }
                catch
                {
                }
            }

            return new PurchaseItemInfo
            {
                ItemCode = string.IsNullOrWhiteSpace(itemCode) ? itemNo : itemCode,
                Description = description,
                CategoryCode = categoryCode,
                AvailableQty = availableQty
            };
        }

        private string GetNextLineNo(string documentNo)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();
            using var cmd = new SqlCommand("SELECT ISNULL(MAX(TRY_CONVERT(INT, [Line No.])), 0) + 1 FROM PurchaseLine WHERE [Document No.] = @Doc", conn);
            cmd.Parameters.AddWithValue("@Doc", documentNo);
            var value = cmd.ExecuteScalar();
            int nextLine = 1;
            try
            {
                if (value != null && value != DBNull.Value)
                    nextLine = Convert.ToInt32(value);
            }
            catch
            {
                nextLine = 1;
            }

            return nextLine.ToString();
        }

        private static decimal? ParseNullableDecimal(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return null;

            return decimal.TryParse(value.Trim(), out var parsed) ? parsed : null;
        }

        private void UpsertPurchaseLine(string documentNo, string lineNo, string itemNo, string description, string categoryCode, decimal? availableQty, decimal? qtyNeeded, decimal? qtyReceived)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();

            using var check = new SqlCommand("SELECT COUNT(1) FROM PurchaseLine WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn);
            check.Parameters.AddWithValue("@Doc", documentNo);
            check.Parameters.AddWithValue("@Line", lineNo);
            bool exists = Convert.ToInt32(check.ExecuteScalar() ?? 0) > 0;

            if (exists)
            {
                using var upd = new SqlCommand("UPDATE PurchaseLine SET [Item No.] = @Item, [Description] = @Desc, [CategoryCode] = @Category, [Available QTY] = @Avail, [Qty Needed] = @Needed, [Qty Received] = @Received WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn);
                upd.Parameters.AddWithValue("@Item", itemNo);
                upd.Parameters.AddWithValue("@Desc", string.IsNullOrEmpty(description) ? (object)DBNull.Value : description);
                upd.Parameters.AddWithValue("@Category", string.IsNullOrEmpty(categoryCode) ? (object)DBNull.Value : categoryCode);
                upd.Parameters.AddWithValue("@Avail", (object?)availableQty ?? DBNull.Value);
                upd.Parameters.AddWithValue("@Needed", (object?)qtyNeeded ?? DBNull.Value);
                upd.Parameters.AddWithValue("@Received", (object?)qtyReceived ?? DBNull.Value);
                upd.Parameters.AddWithValue("@Doc", documentNo);
                upd.Parameters.AddWithValue("@Line", lineNo);
                upd.ExecuteNonQuery();
                return;
            }

            using var ins = new SqlCommand("INSERT INTO PurchaseLine ([Document No.], [Item No.], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty Needed], [Qty Received]) VALUES (@Doc, @Item, @Desc, @Category, @Line, @Avail, @Needed, @Received)", conn);
            ins.Parameters.AddWithValue("@Doc", documentNo);
            ins.Parameters.AddWithValue("@Item", itemNo);
            ins.Parameters.AddWithValue("@Desc", string.IsNullOrEmpty(description) ? (object)DBNull.Value : description);
            ins.Parameters.AddWithValue("@Category", string.IsNullOrEmpty(categoryCode) ? (object)DBNull.Value : categoryCode);
            ins.Parameters.AddWithValue("@Line", lineNo);
            ins.Parameters.AddWithValue("@Avail", (object?)availableQty ?? DBNull.Value);
            ins.Parameters.AddWithValue("@Needed", (object?)qtyNeeded ?? DBNull.Value);
            ins.Parameters.AddWithValue("@Received", (object?)qtyReceived ?? DBNull.Value);
            ins.ExecuteNonQuery();
        }

        private void LoadData()
        {
            try
            {
                grid.Rows.Clear();
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var cmd = new SqlCommand("SELECT [Document No.], [Item No.], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty Needed], [Qty Received] FROM PurchaseLine ORDER BY [Document No.], [Line No.]", conn))
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read())
                        {
                            string doc = rdr["Document No."] != DBNull.Value ? rdr["Document No."].ToString() ?? "" : "";
                            string item = rdr["Item No."] != DBNull.Value ? rdr["Item No."].ToString() ?? "" : "";
                            string desc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                            string cat = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString() ?? "" : "";
                            string line = rdr["Line No."] != DBNull.Value ? rdr["Line No."].ToString() ?? "" : "";
                            string avail = rdr["Available QTY"] != DBNull.Value ? rdr["Available QTY"].ToString() ?? "" : "";
                            string need = rdr["Qty Needed"] != DBNull.Value ? rdr["Qty Needed"].ToString() ?? "" : "";
                            string recv = rdr["Qty Received"] != DBNull.Value ? rdr["Qty Received"].ToString() ?? "" : "";
                            grid.Rows.Add(doc, item, desc, cat, line, avail, need, recv);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load PurchaseLine: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void NewButton_Click(object? sender, EventArgs e)
        {
            string doc = currentDocument ?? "";
            // insert empty row matching new column order: Doc, Item, Description, CategoryCode, Line, Avail, Needed, Received
            grid.Rows.Insert(0, doc, "", "", "", "", "", "", "");
            if (grid.Rows.Count > 0)
            {
                if (documentFixed) grid.Rows[0].Cells[0].ReadOnly = true;
                grid.CurrentCell = grid.Rows[0].Cells[1];
                grid.BeginEdit(true);
            }
        }

        private void SaveButton_Click(object? sender, EventArgs e)
        {
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                        foreach (DataGridViewRow row in grid.Rows)
                    {
                        if (row.IsNewRow) continue;
                        string doc = (row.Cells[0].Value ?? string.Empty).ToString().Trim();
                        string item = (row.Cells[1].Value ?? string.Empty).ToString().Trim();
                        string description = (row.Cells[2].Value ?? string.Empty).ToString().Trim();
                        string category = (row.Cells[3].Value ?? string.Empty).ToString().Trim();
                        string line = (row.Cells[4].Value ?? string.Empty).ToString().Trim();
                        string availTxt = (row.Cells[5].Value ?? string.Empty).ToString().Trim();
                        string needTxt = (row.Cells[6].Value ?? string.Empty).ToString().Trim();
                        string recvTxt = (row.Cells[7].Value ?? string.Empty).ToString().Trim();

                        if (string.IsNullOrWhiteSpace(doc) && !string.IsNullOrWhiteSpace(currentDocument)) doc = currentDocument!;
                        // enforce documentFixed: override any attempted change and use currentDocument
                        if (documentFixed && !string.IsNullOrWhiteSpace(currentDocument)) doc = currentDocument!;
                        if (string.IsNullOrWhiteSpace(doc) || string.IsNullOrWhiteSpace(line)) continue; // skip incomplete rows

                        decimal? avail = null, need = null, recv = null;
                        if (!string.IsNullOrWhiteSpace(availTxt)) { if (decimal.TryParse(availTxt, out var d)) avail = d; }
                        if (!string.IsNullOrWhiteSpace(needTxt)) { if (decimal.TryParse(needTxt, out var d2)) need = d2; }
                        if (!string.IsNullOrWhiteSpace(recvTxt)) { if (decimal.TryParse(recvTxt, out var d3)) recv = d3; }

                        using (var check = new SqlCommand("SELECT COUNT(1) FROM PurchaseLine WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn))
                        {
                            check.Parameters.AddWithValue("@Doc", doc);
                            check.Parameters.AddWithValue("@Line", line);
                            var exists = Convert.ToInt32(check.ExecuteScalar() ?? 0) > 0;
                            if (exists)
                            {
                                using (var upd = new SqlCommand("UPDATE PurchaseLine SET [Item No.] = @Item, [Description] = @Desc, [CategoryCode] = @Category, [Available QTY] = @Avail, [Qty Needed] = @Needed, [Qty Received] = @Received WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn))
                                {
                                    upd.Parameters.AddWithValue("@Item", item);
                                    upd.Parameters.AddWithValue("@Desc", string.IsNullOrEmpty(description) ? (object)DBNull.Value : description);
                                    upd.Parameters.AddWithValue("@Category", string.IsNullOrEmpty(category) ? (object)DBNull.Value : category);
                                    upd.Parameters.AddWithValue("@Avail", (object?)avail ?? DBNull.Value);
                                    upd.Parameters.AddWithValue("@Needed", (object?)need ?? DBNull.Value);
                                    upd.Parameters.AddWithValue("@Received", (object?)recv ?? DBNull.Value);
                                    upd.Parameters.AddWithValue("@Doc", doc);
                                    upd.Parameters.AddWithValue("@Line", line);
                                    upd.ExecuteNonQuery();
                                }
                            }
                            else
                            {
                                using (var ins = new SqlCommand("INSERT INTO PurchaseLine ([Document No.], [Item No.], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty Needed], [Qty Received]) VALUES (@Doc, @Item, @Desc, @Category, @Line, @Avail, @Needed, @Received)", conn))
                                {
                                    ins.Parameters.AddWithValue("@Doc", doc);
                                    ins.Parameters.AddWithValue("@Item", item);
                                    ins.Parameters.AddWithValue("@Desc", string.IsNullOrEmpty(description) ? (object)DBNull.Value : description);
                                    ins.Parameters.AddWithValue("@Category", string.IsNullOrEmpty(category) ? (object)DBNull.Value : category);
                                    ins.Parameters.AddWithValue("@Line", line);
                                    ins.Parameters.AddWithValue("@Avail", (object?)avail ?? DBNull.Value);
                                    ins.Parameters.AddWithValue("@Needed", (object?)need ?? DBNull.Value);
                                    ins.Parameters.AddWithValue("@Received", (object?)recv ?? DBNull.Value);
                                    ins.ExecuteNonQuery();
                                }
                            }
                        }
                    }
                }

                MessageBox.Show(this, "Saved.", "Saved", MessageBoxButtons.OK, MessageBoxIcon.Information);
                // reload using current filter
                LoadForDocument(currentDocument);
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
            string doc = (row.Cells[0].Value ?? string.Empty).ToString().Trim();
            string line = (row.Cells[4].Value ?? string.Empty).ToString().Trim();
            if (string.IsNullOrWhiteSpace(doc) || string.IsNullOrWhiteSpace(line))
            {
                MessageBox.Show(this, "Selected row has empty Document No. or Line No.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var dr = MessageBox.Show(this, $"Delete Purchase line '{doc}' / '{line}'?", "Confirm", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (dr != DialogResult.Yes) return;

            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var del = new SqlCommand("DELETE FROM PurchaseLine WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn))
                    {
                        del.Parameters.AddWithValue("@Doc", doc);
                        del.Parameters.AddWithValue("@Line", line);
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
