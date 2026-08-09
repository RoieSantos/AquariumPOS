using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class TransferOrderLinesForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly TransferOrderData.DocumentTableContext documentContext;
        private DataGridView grid = null!;
        private bool suppressAutoSave;
        private string? currentDocument;
        private string? sourceWarehouseId;
        private bool useProductionCategory;
        private bool documentFixed;
        private List<ItemLookupOption> itemLookupOptions = new();
        private AutoCompleteStringCollection itemLookupSuggestions = new();
        private bool suppressItemNoPopup;
        private string? itemLookupLoadError;

        public TransferOrderLinesForm()
            : this(TransferOrderData.PostedTransferOrders)
        {
        }

        internal TransferOrderLinesForm(TransferOrderData.DocumentTableContext documentContext)
        {
            this.documentContext = documentContext;
            InitializeComponent();
            TransferOrderData.EnsureTablesExist(connectionString);
            ApplyWarehouseColumnVisibility();
            UpdateAddLineAvailability();
        }

        public void LoadForDocument(string? docNo)
        {
            try
            {
                suppressAutoSave = true;
                grid.Rows.Clear();
                currentDocument = docNo;
                documentFixed = !string.IsNullOrWhiteSpace(docNo);
                if (string.IsNullOrWhiteSpace(docNo)) return;

                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand($"SELECT [Document No.], [Item No.], [Variant ID], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty To Transfer], [Qty To Receive], [Qty Received] FROM {documentContext.LineTableName} WHERE [Document No.] = @Doc ORDER BY [Line No.]", conn);
                cmd.Parameters.AddWithValue("@Doc", docNo);
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string doc = rdr["Document No."] != DBNull.Value ? rdr["Document No."].ToString() ?? "" : "";
                    string item = rdr["Item No."] != DBNull.Value ? rdr["Item No."].ToString() ?? "" : "";
                    string variantId = rdr["Variant ID"] != DBNull.Value ? rdr["Variant ID"].ToString() ?? "" : "";
                    string variantName = string.IsNullOrWhiteSpace(item) || string.IsNullOrWhiteSpace(variantId)
                        ? string.Empty
                        : ResolveVariantDisplayName(item, variantId);
                    string desc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                    string cat = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString() ?? "" : "";
                    string line = rdr["Line No."] != DBNull.Value ? rdr["Line No."].ToString() ?? "" : "";
                    string avail = rdr["Available QTY"] != DBNull.Value ? rdr["Available QTY"].ToString() ?? "" : "";
                    string qtyToShip = rdr["Qty To Transfer"] != DBNull.Value ? rdr["Qty To Transfer"].ToString() ?? "" : "";
                    string qtyToReceive = rdr["Qty To Receive"] != DBNull.Value ? rdr["Qty To Receive"].ToString() ?? "" : "";
                    string received = rdr["Qty Received"] != DBNull.Value ? rdr["Qty Received"].ToString() ?? "" : "";
                    string qtyShipped = received;
                    int rowIndex = grid.Rows.Add(doc, item, variantName, variantId, desc, cat, line, avail, qtyToShip, qtyToReceive, qtyShipped, received);
                    if (documentFixed) grid.Rows[rowIndex].Cells[0].ReadOnly = true;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load {documentContext.DocumentTitle} lines for document '{docNo}': {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                suppressAutoSave = false;
            }
        }

        public void SetSourceWarehouse(string? warehouseId)
        {
            sourceWarehouseId = string.IsNullOrWhiteSpace(warehouseId) ? null : warehouseId.Trim();
            UpdateAddLineAvailability();
        }

        public void SetUseProductionCategory(bool useProductionCategory)
        {
            this.useProductionCategory = useProductionCategory;
            RefreshItemLookupOptions();
        }

        private void RefreshItemLookupOptions()
        {
            itemLookupOptions = BuildItemLookupOptions();
            itemLookupSuggestions = BuildItemLookupSuggestions();
            ApplyItemNoDropdownOptions();
        }

        private string GetCurrentRowItemNo()
        {
            return grid?.CurrentCell?.OwningRow != null
                ? NormalizeItemLookupValue((grid.CurrentCell.OwningRow.Cells["ItemNo"].Value ?? string.Empty).ToString())
                : string.Empty;
        }

        private void InitializeComponent()
        {
            Text = documentContext.DocumentTitle + " Lines";
            Size = new Size(1000, 600);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            grid = new DataGridView
            {
                Dock = DockStyle.Top,
                Height = 480,
                AllowUserToAddRows = true,
                AllowUserToDeleteRows = true,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells,
                EditMode = DataGridViewEditMode.EditOnKeystrokeOrF2,
                ReadOnly = false,
                BackgroundColor = Color.White,
                GridColor = Color.LightGray,
                EnableHeadersVisualStyles = false,
                DefaultCellStyle = new DataGridViewCellStyle
                {
                    BackColor = Color.White,
                    ForeColor = Color.Black,
                    SelectionBackColor = Color.SteelBlue,
                    SelectionForeColor = Color.White
                },
                ColumnHeadersDefaultCellStyle = new DataGridViewCellStyle
                {
                    BackColor = Color.WhiteSmoke,
                    ForeColor = Color.Black,
                    SelectionBackColor = Color.WhiteSmoke,
                    SelectionForeColor = Color.Black
                }
            };

            if (documentContext.IsReadOnly)
            {
                grid.AllowUserToAddRows = false;
                grid.AllowUserToDeleteRows = false;
                grid.ReadOnly = true;
                grid.EditMode = DataGridViewEditMode.EditProgrammatically;
            }

            grid.DefaultValuesNeeded += Grid_DefaultValuesNeeded;
            grid.EditingControlShowing += Grid_EditingControlShowing;
            grid.CellEndEdit += Grid_CellEndEdit;
            grid.CellClick += Grid_CellClick;
            grid.KeyDown += Grid_KeyDown;
            grid.KeyPress += Grid_KeyPress;
            grid.DataError += Grid_DataError;

            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "DocumentNo", HeaderText = "Document No.", Width = 160 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ItemNo", HeaderText = "Item No.", Width = 260 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "VariantName", HeaderText = "Variant", Width = 220 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "VariantId", HeaderText = "Variant ID", Width = 220, Visible = false });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Description", HeaderText = "Description", Width = 400 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "CategoryCode", HeaderText = "Category Code", Width = 140 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "LineNo", HeaderText = "Line No.", Width = 120, Visible = false });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "AvailableQty", HeaderText = "Quantity", Width = 120 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyToShip", HeaderText = "Qty To Ship", Width = 120, Visible = false });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyToReceive", HeaderText = "Qty To Receive", Width = 140 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyToShipped", HeaderText = "Qty Shipped", Width = 140, Visible = false });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyReceived", HeaderText = "Qty Received", Width = 120 });

            grid.Columns["DocumentNo"].ReadOnly = true;
            grid.Columns["Description"].ReadOnly = true;
            grid.Columns["CategoryCode"].ReadOnly = true;
            grid.Columns["QtyToShipped"].ReadOnly = true;

            Controls.Add(grid);
            RefreshItemLookupOptions();
        }

        private void ApplyWarehouseColumnVisibility()
        {
            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(connectionString);
            bool useStockWarehouseLayout = currentWarehouse != null
                && !currentWarehouse.IsProductionWarehouse
                && currentWarehouse.IsStockWarehouse;
            bool useTransferRequestShippingLayout = IsTransferRequestShippingLayout(currentWarehouse);

            if (grid.Columns.Contains("DocumentNo"))
            {
                grid.Columns["DocumentNo"].Visible = !useStockWarehouseLayout;
            }

            if (grid.Columns.Contains("AvailableQty"))
            {
                grid.Columns["AvailableQty"].HeaderText = "Quantity";
                if (!documentContext.IsReadOnly)
                    grid.Columns["AvailableQty"].ReadOnly = useTransferRequestShippingLayout;
            }

            if (grid.Columns.Contains("QtyToShip"))
                grid.Columns["QtyToShip"].Visible = useTransferRequestShippingLayout;

            if (grid.Columns.Contains("QtyToReceive"))
                grid.Columns["QtyToReceive"].Visible = !useTransferRequestShippingLayout;

            if (grid.Columns.Contains("QtyToShipped"))
                grid.Columns["QtyToShipped"].Visible = useTransferRequestShippingLayout;

            if (grid.Columns.Contains("QtyReceived"))
                grid.Columns["QtyReceived"].Visible = !useTransferRequestShippingLayout;
        }

        private bool IsTransferRequestShippingLayout(TransferOrderData.WarehouseOption? currentWarehouse = null)
        {
            currentWarehouse ??= TransferOrderData.GetCurrentWarehouse(connectionString);
            return string.Equals(documentContext.HeaderTableName, TransferOrderData.TransferRequests.HeaderTableName, StringComparison.OrdinalIgnoreCase)
                && currentWarehouse != null
                && (currentWarehouse.IsProductionWarehouse || currentWarehouse.IsStockWarehouse);
        }

        private void Grid_EditingControlShowing(object? sender, DataGridViewEditingControlShowingEventArgs e)
        {
            if (grid.CurrentCell == null)
            {
                if (e.Control is TextBox inactiveTextBox)
                {
                    inactiveTextBox.KeyPress -= ItemNoEditingTextBox_KeyPress;
                    inactiveTextBox.KeyPress -= VariantIdEditingTextBox_KeyPress;
                    inactiveTextBox.AutoCompleteMode = AutoCompleteMode.None;
                    inactiveTextBox.AutoCompleteSource = AutoCompleteSource.None;
                    inactiveTextBox.AutoCompleteCustomSource = null;
                }

                return;
            }

            if (e.Control is TextBox textBox)
            {
                textBox.KeyPress -= ItemNoEditingTextBox_KeyPress;
                textBox.KeyPress -= VariantIdEditingTextBox_KeyPress;

                if (string.Equals(grid.CurrentCell.OwningColumn?.Name, "ItemNo", StringComparison.Ordinal))
                {
                    textBox.KeyPress += ItemNoEditingTextBox_KeyPress;
                    textBox.AutoCompleteMode = AutoCompleteMode.SuggestAppend;
                    textBox.AutoCompleteSource = AutoCompleteSource.CustomSource;
                    textBox.AutoCompleteCustomSource = itemLookupSuggestions;
                }
                else if (string.Equals(grid.CurrentCell.OwningColumn?.Name, "VariantName", StringComparison.Ordinal))
                {
                    textBox.KeyPress += VariantIdEditingTextBox_KeyPress;
                    textBox.AutoCompleteMode = AutoCompleteMode.SuggestAppend;
                    textBox.AutoCompleteSource = AutoCompleteSource.CustomSource;
                    textBox.AutoCompleteCustomSource = BuildVariantLookupSuggestions(GetCurrentRowItemNo());
                }
                else
                {
                    textBox.AutoCompleteMode = AutoCompleteMode.None;
                    textBox.AutoCompleteSource = AutoCompleteSource.None;
                    textBox.AutoCompleteCustomSource = null;
                }

                textBox.BackColor = Color.White;
                textBox.ForeColor = Color.Black;
            }
        }

        private void Grid_KeyPress(object? sender, KeyPressEventArgs e)
        {
            if (suppressItemNoPopup || grid.CurrentCell == null)
            {
                return;
            }

            string? columnName = grid.CurrentCell.OwningColumn?.Name;
            if (!string.Equals(columnName, "ItemNo", StringComparison.Ordinal)
                && !string.Equals(columnName, "VariantName", StringComparison.Ordinal))
            {
                return;
            }

            if (!ShouldAutoOpenItemPopup(e.KeyChar))
            {
                return;
            }

            if (string.Equals(columnName, "ItemNo", StringComparison.Ordinal))
                ShowItemNoDropdown(grid.CurrentCell.RowIndex, e.KeyChar.ToString());
            else
                ShowVariantIdDropdown(grid.CurrentCell.RowIndex, e.KeyChar.ToString());
            e.Handled = true;
        }

        private void ItemNoEditingTextBox_KeyPress(object? sender, KeyPressEventArgs e)
        {
            if (suppressItemNoPopup || sender is not TextBox textBox || grid.CurrentCell == null)
            {
                return;
            }

            if (!string.Equals(grid.CurrentCell.OwningColumn?.Name, "ItemNo", StringComparison.Ordinal))
            {
                return;
            }

            if (!ShouldAutoOpenItemPopup(e.KeyChar))
            {
                return;
            }

            ShowItemNoDropdown(grid.CurrentCell.RowIndex, BuildSearchTextFromKeyPress(textBox, e.KeyChar));
            e.Handled = true;
        }

        private void VariantIdEditingTextBox_KeyPress(object? sender, KeyPressEventArgs e)
        {
            if (suppressItemNoPopup || sender is not TextBox textBox || grid.CurrentCell == null)
            {
                return;
            }

            if (!string.Equals(grid.CurrentCell.OwningColumn?.Name, "VariantName", StringComparison.Ordinal))
            {
                return;
            }

            if (!ShouldAutoOpenItemPopup(e.KeyChar))
            {
                return;
            }

            ShowVariantIdDropdown(grid.CurrentCell.RowIndex, BuildSearchTextFromKeyPress(textBox, e.KeyChar));
            e.Handled = true;
        }

        private static bool ShouldAutoOpenItemPopup(char keyChar)
        {
            return !char.IsControl(keyChar);
        }

        private static string BuildSearchTextFromKeyPress(TextBox textBox, char keyChar)
        {
            string currentText = textBox.Text ?? string.Empty;
            int selectionStart = Math.Max(0, textBox.SelectionStart);
            int selectionLength = Math.Max(0, textBox.SelectionLength);

            if (selectionStart > currentText.Length)
            {
                selectionStart = currentText.Length;
            }

            if (selectionStart + selectionLength > currentText.Length)
            {
                selectionLength = currentText.Length - selectionStart;
            }

            return currentText.Remove(selectionStart, selectionLength).Insert(selectionStart, keyChar.ToString());
        }

        private void Grid_CellClick(object? sender, DataGridViewCellEventArgs e)
        {
            if (suppressItemNoPopup || e.RowIndex < 0 || e.ColumnIndex < 0)
            {
                return;
            }

            string? columnName = grid.Columns[e.ColumnIndex]?.Name;
            if (!string.Equals(columnName, "ItemNo", StringComparison.Ordinal)
                && !string.Equals(columnName, "VariantName", StringComparison.Ordinal))
            {
                return;
            }

            if (string.Equals(columnName, "ItemNo", StringComparison.Ordinal))
                ShowItemNoDropdown(e.RowIndex);
            else
                ShowVariantIdDropdown(e.RowIndex);
        }

        private void Grid_KeyDown(object? sender, KeyEventArgs e)
        {
            if (suppressItemNoPopup || grid.CurrentCell == null)
            {
                return;
            }

            string? columnName = grid.CurrentCell.OwningColumn?.Name;
            if (!string.Equals(columnName, "ItemNo", StringComparison.Ordinal)
                && !string.Equals(columnName, "VariantName", StringComparison.Ordinal))
            {
                return;
            }

            if (e.KeyCode == Keys.F4 || (e.KeyCode == Keys.Down && e.Alt))
            {
                if (string.Equals(columnName, "ItemNo", StringComparison.Ordinal))
                    ShowItemNoDropdown(grid.CurrentCell.RowIndex);
                else
                    ShowVariantIdDropdown(grid.CurrentCell.RowIndex);
                e.Handled = true;
                e.SuppressKeyPress = true;
            }
        }

        private void Grid_DataError(object? sender, DataGridViewDataErrorEventArgs e)
        {
            e.ThrowException = false;
        }

        private void UpdateAddLineAvailability()
        {
            bool canAddLines = !string.IsNullOrWhiteSpace(sourceWarehouseId);
            if (grid != null)
            {
                grid.AllowUserToAddRows = canAddLines;
            }
        }

        public bool HasLines()
        {
            if (grid == null)
            {
                return false;
            }

            foreach (DataGridViewRow row in grid.Rows)
            {
                if (row == null || row.IsNewRow)
                {
                    continue;
                }

                string itemNo = (row.Cells["ItemNo"].Value ?? string.Empty).ToString()!.Trim();
                string lineNo = (row.Cells["LineNo"].Value ?? string.Empty).ToString()!.Trim();
                if (!string.IsNullOrWhiteSpace(itemNo) || !string.IsNullOrWhiteSpace(lineNo))
                {
                    return true;
                }
            }

            return false;
        }

        public bool HasAnyQtyShipped()
        {
            if (grid == null)
                return false;

            foreach (DataGridViewRow row in grid.Rows)
            {
                if (row == null || row.IsNewRow)
                    continue;

                decimal? qtyShipped = ParseNullableDecimalSafe((row.Cells["QtyToShipped"].Value ?? string.Empty).ToString());
                if (qtyShipped.HasValue && qtyShipped.Value > 0)
                    return true;
            }

            return false;
        }

        public bool HasAnyShipmentToPost()
        {
            if (grid == null)
                return false;

            foreach (DataGridViewRow row in grid.Rows)
            {
                if (row == null || row.IsNewRow)
                    continue;

                decimal? quantity = ParseNullableDecimalSafe((row.Cells["AvailableQty"].Value ?? string.Empty).ToString());
                decimal? qtyToShip = ParseNullableDecimalSafe((row.Cells["QtyToShip"].Value ?? string.Empty).ToString());
                decimal? qtyShipped = CalculateQtyShipped(quantity, qtyToShip);
                if (qtyShipped.HasValue && qtyShipped.Value > 0)
                    return true;
            }

            return false;
        }

        public void FocusFirstQtyShippedCell()
        {
            if (grid == null)
                return;

            string targetColumn = grid.Columns.Contains("QtyToShip") && grid.Columns["QtyToShip"].Visible
                ? "QtyToShip"
                : grid.Columns.Contains("QtyToShipped")
                    ? "QtyToShipped"
                    : string.Empty;

            if (string.IsNullOrWhiteSpace(targetColumn))
                return;

            foreach (DataGridViewRow row in grid.Rows)
            {
                if (row == null || row.IsNewRow)
                    continue;

                grid.CurrentCell = row.Cells[targetColumn];
                grid.Focus();
                if (!grid.ReadOnly && !row.Cells[targetColumn].ReadOnly)
                    grid.BeginEdit(true);
                return;
            }
        }

        private void Grid_DefaultValuesNeeded(object? sender, DataGridViewRowEventArgs e)
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

        private void Grid_CellEndEdit(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (suppressAutoSave || e.RowIndex < 0 || e.ColumnIndex < 0 || e.RowIndex >= grid.Rows.Count) return;

                var row = grid.Rows[e.RowIndex];
                if (row == null || row.IsNewRow) return;

                var columnName = grid.Columns[e.ColumnIndex]?.Name;
                if (columnName != "ItemNo" && columnName != "VariantName" && columnName != "AvailableQty" && columnName != "QtyToShip" && columnName != "QtyToReceive" && columnName != "QtyReceived") return;

                string doc = (row.Cells["DocumentNo"].Value ?? string.Empty).ToString()!.Trim();
                string lineNo = (row.Cells["LineNo"].Value ?? string.Empty).ToString()!.Trim();
                if (documentFixed && !string.IsNullOrWhiteSpace(currentDocument)) doc = currentDocument!;

                if (columnName == "ItemNo")
                {
                    if (string.IsNullOrWhiteSpace(sourceWarehouseId))
                    {
                        MessageBox.Show(this, "Select a From Warehouse before adding transfer lines.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        row.Cells["ItemNo"].Value = string.Empty;
                        return;
                    }

                    HandleItemNumberEdit(row, doc, lineNo);
                    return;
                }

                if (columnName == "VariantName")
                {
                    HandleVariantIdEdit(row, doc, lineNo);
                    return;
                }

                if (string.IsNullOrWhiteSpace(doc) || string.IsNullOrWhiteSpace(lineNo)) return;

                string currentItemNo = NormalizeItemLookupValue((row.Cells["ItemNo"].Value ?? string.Empty).ToString());
                bool variantRequired = ItemRequiresVariant(currentItemNo);
                string currentVariantId = (row.Cells["VariantId"].Value ?? string.Empty).ToString()!.Trim();
                if (variantRequired && string.IsNullOrWhiteSpace(currentVariantId))
                {
                    MessageBox.Show(this, "Select a Variant before entering quantities for this item.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    if (columnName == "AvailableQty") row.Cells["AvailableQty"].Value = string.Empty;
                    if (columnName == "QtyToShip") row.Cells["QtyToShip"].Value = string.Empty;
                    if (columnName == "QtyToReceive") row.Cells["QtyToReceive"].Value = string.Empty;
                    if (columnName == "QtyToShipped") row.Cells["QtyToShipped"].Value = string.Empty;
                    if (columnName == "QtyReceived") row.Cells["QtyReceived"].Value = string.Empty;
                    if (grid.Columns.Contains("VariantName"))
                    {
                        grid.CurrentCell = row.Cells["VariantName"];
                        grid.BeginEdit(true);
                    }
                    return;
                }

                if (columnName == "AvailableQty")
                {
                    decimal? quantity = ParseNullableDecimal((row.Cells["AvailableQty"].Value ?? string.Empty).ToString());
                    SaveQty(doc, lineNo, "[Available QTY]", quantity);
                    if (!IsTransferRequestShippingLayout())
                    {
                        SaveQty(doc, lineNo, "[Qty To Transfer]", quantity);
                    }
                }
                else if (columnName == "QtyToShip")
                {
                    decimal? qtyToShip = ParseNullableDecimal((row.Cells["QtyToShip"].Value ?? string.Empty).ToString());
                    SaveQty(doc, lineNo, "[Qty To Transfer]", qtyToShip);
                }
                else if (columnName == "QtyToReceive")
                {
                    decimal? qtyToReceive = ParseNullableDecimal((row.Cells["QtyToReceive"].Value ?? string.Empty).ToString());
                    SaveQty(doc, lineNo, "[Qty To Receive]", qtyToReceive);
                }
                else if (columnName == "QtyReceived")
                {
                    decimal? qtyReceived = ParseNullableDecimal((row.Cells["QtyReceived"].Value ?? string.Empty).ToString());
                    row.Cells["QtyToShipped"].Value = row.Cells["QtyReceived"].Value;
                    SaveQty(doc, lineNo, "[Qty Received]", qtyReceived);
                }
            }
            catch (Exception ex)
            {
                try { MessageBox.Show(this, $"Auto-save failed: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

        private void SaveQty(string documentNo, string lineNo, string columnName, decimal? value)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();
            using var cmd = new SqlCommand($"UPDATE {documentContext.LineTableName} SET {columnName} = @Value WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn);
            cmd.Parameters.AddWithValue("@Doc", documentNo);
            cmd.Parameters.AddWithValue("@Line", Convert.ToInt32(lineNo));
            cmd.Parameters.AddWithValue("@Value", (object?)value ?? DBNull.Value);
            cmd.ExecuteNonQuery();
        }

        private void HandleItemNumberEdit(DataGridViewRow row, string documentNo, string lineNo)
        {
            if (row == null || row.IsNewRow || string.IsNullOrWhiteSpace(documentNo)) return;

            string itemNo = NormalizeItemLookupValue((row.Cells["ItemNo"].Value ?? string.Empty).ToString());
            if (string.IsNullOrWhiteSpace(itemNo)) return;

            row.Cells["ItemNo"].Value = itemNo;

            if (string.IsNullOrWhiteSpace(lineNo))
            {
                lineNo = GetNextLineNo(documentNo).ToString();
                row.Cells["LineNo"].Value = lineNo;
            }

            var itemInfo = ResolveItemInfo(itemNo);
            if (itemInfo == null)
            {
                itemInfo = PromptForItemSelection(itemNo);
                if (itemInfo == null)
                {
                    row.Cells["VariantName"].Value = string.Empty;
                    row.Cells["VariantId"].Value = string.Empty;
                    row.Cells["Description"].Value = string.Empty;
                    row.Cells["CategoryCode"].Value = string.Empty;
                    row.Cells["AvailableQty"].Value = string.Empty;

                    if (grid.Columns.Contains("ItemNo"))
                    {
                        grid.CurrentCell = row.Cells["ItemNo"];
                        grid.BeginEdit(true);
                    }

                    return;
                }
            }

            row.Cells["ItemNo"].Value = itemInfo.ItemCode;
            row.Cells["VariantName"].Value = string.Empty;
            row.Cells["VariantId"].Value = string.Empty;
            row.Cells["Description"].Value = itemInfo.Description;
            row.Cells["CategoryCode"].Value = itemInfo.CategoryCode;
            decimal? quantity = ParseNullableDecimal((row.Cells["AvailableQty"].Value ?? string.Empty).ToString());
            decimal? qtyToTransfer = ParseNullableDecimal((row.Cells["QtyToShip"].Value ?? string.Empty).ToString()) ?? quantity;
            decimal? qtyToReceive = ParseNullableDecimal((row.Cells["QtyToReceive"].Value ?? string.Empty).ToString());
            decimal? qtyReceived = ParseNullableDecimal((row.Cells["QtyReceived"].Value ?? string.Empty).ToString());
            row.Cells["QtyToShipped"].Value = qtyReceived?.ToString("0.##") ?? string.Empty;
            UpsertLine(documentNo, Convert.ToInt32(lineNo), itemInfo.ItemCode, null, itemInfo.Description, itemInfo.CategoryCode, quantity, qtyToTransfer, qtyToReceive, qtyReceived);

            if (ItemRequiresVariant(itemInfo.ItemCode) && grid.Columns.Contains("VariantName"))
            {
                grid.CurrentCell = row.Cells["VariantName"];
            }
            else if (grid.Columns.Contains("QtyToShip") && grid.Columns["QtyToShip"].Visible)
            {
                grid.CurrentCell = row.Cells["QtyToShip"];
            }
            else if (grid.Columns.Contains("QtyToReceive"))
            {
                grid.CurrentCell = row.Cells["QtyToReceive"];
            }
        }

        private void HandleVariantIdEdit(DataGridViewRow row, string documentNo, string lineNo)
        {
            if (row == null || row.IsNewRow || string.IsNullOrWhiteSpace(documentNo)) return;

            string itemNo = NormalizeItemLookupValue((row.Cells["ItemNo"].Value ?? string.Empty).ToString());
            if (string.IsNullOrWhiteSpace(itemNo))
            {
                row.Cells["VariantName"].Value = string.Empty;
                row.Cells["VariantId"].Value = string.Empty;
                MessageBox.Show(this, "Select an Item No. before choosing a Variant ID.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            if (string.IsNullOrWhiteSpace(lineNo))
            {
                lineNo = GetNextLineNo(documentNo).ToString();
                row.Cells["LineNo"].Value = lineNo;
            }

            string variantId = NormalizeVariantLookupValue(itemNo, (row.Cells["VariantName"].Value ?? string.Empty).ToString());
            var baseItemInfo = ResolveItemInfo(itemNo);
            if (baseItemInfo == null)
            {
                return;
            }

            TransferItemInfo finalInfo = baseItemInfo;
            string? finalVariantId = null;

            if (!string.IsNullOrWhiteSpace(variantId))
            {
                var variantInfo = ResolveVariantInfo(itemNo, variantId);
                if (variantInfo == null)
                {
                    row.Cells["VariantName"].Value = string.Empty;
                    row.Cells["VariantId"].Value = string.Empty;
                    row.Cells["Description"].Value = baseItemInfo.Description;
                    row.Cells["CategoryCode"].Value = baseItemInfo.CategoryCode;
                    return;
                }

                finalInfo = variantInfo;
                finalVariantId = variantInfo.VariationId;
            }

            row.Cells["ItemNo"].Value = itemNo;
            row.Cells["VariantName"].Value = finalInfo.VariantName;
            row.Cells["VariantId"].Value = finalVariantId ?? string.Empty;
            row.Cells["Description"].Value = finalInfo.Description;
            row.Cells["CategoryCode"].Value = finalInfo.CategoryCode;
            decimal? quantity = ParseNullableDecimal((row.Cells["AvailableQty"].Value ?? string.Empty).ToString());
            decimal? qtyToTransfer = ParseNullableDecimal((row.Cells["QtyToShip"].Value ?? string.Empty).ToString()) ?? quantity;
            decimal? qtyToReceive = ParseNullableDecimal((row.Cells["QtyToReceive"].Value ?? string.Empty).ToString());
            decimal? qtyReceived = ParseNullableDecimal((row.Cells["QtyReceived"].Value ?? string.Empty).ToString());
            row.Cells["QtyToShipped"].Value = qtyReceived?.ToString("0.##") ?? string.Empty;
            UpsertLine(documentNo, Convert.ToInt32(lineNo), itemNo, finalVariantId, finalInfo.Description, finalInfo.CategoryCode, quantity, qtyToTransfer, qtyToReceive, qtyReceived);
        }

        public void ApplyCalculatedQtyShippedForPosting()
        {
            if (grid == null)
                return;

            foreach (DataGridViewRow row in grid.Rows)
            {
                if (row == null || row.IsNewRow)
                    continue;

                string doc = (row.Cells["DocumentNo"].Value ?? string.Empty).ToString()!.Trim();
                string lineNo = (row.Cells["LineNo"].Value ?? string.Empty).ToString()!.Trim();
                if (string.IsNullOrWhiteSpace(doc) || string.IsNullOrWhiteSpace(lineNo))
                    continue;

                decimal? quantity = ParseNullableDecimalSafe((row.Cells["AvailableQty"].Value ?? string.Empty).ToString());
                decimal? qtyToShip = ParseNullableDecimalSafe((row.Cells["QtyToShip"].Value ?? string.Empty).ToString());
                decimal? qtyShipped = CalculateQtyShipped(quantity, qtyToShip);
                string displayValue = qtyShipped?.ToString("0.##") ?? string.Empty;
                row.Cells["QtyToShipped"].Value = displayValue;
                row.Cells["QtyReceived"].Value = displayValue;
                SaveQty(doc, lineNo, "[Qty Received]", qtyShipped);
            }
        }

        private TransferItemInfo? PromptForItemSelection(string initialSearch)
        {
            using var dialog = new TransferItemLookupDialog(connectionString, useProductionCategory, initialSearch);
            if (ShowHostedDialog(dialog) != DialogResult.OK || string.IsNullOrWhiteSpace(dialog.SelectedItemNo))
            {
                return null;
            }

            return ResolveItemInfo(dialog.SelectedItemNo);
        }

        private AutoCompleteStringCollection BuildVariantLookupSuggestions(string? itemNo)
        {
            var suggestions = new AutoCompleteStringCollection();
            foreach (var option in BuildVariantLookupOptions(itemNo))
            {
                suggestions.Add(option.DisplayText);
            }

            return suggestions;
        }

        private bool ItemRequiresVariant(string? itemNo)
        {
            return BuildVariantLookupOptions(itemNo).Count > 0;
        }

        private void RefreshAvailableQtyForCurrentRows()
        {
            if (grid == null || suppressAutoSave) return;

            try
            {
                suppressAutoSave = true;
                foreach (DataGridViewRow row in grid.Rows)
                {
                    if (row == null || row.IsNewRow) continue;

                    string itemNo = (row.Cells["ItemNo"].Value ?? string.Empty).ToString()!.Trim();
                    if (string.IsNullOrWhiteSpace(itemNo)) continue;

                    string variantId = (row.Cells["VariantId"].Value ?? string.Empty).ToString()!.Trim();
                    var itemInfo = string.IsNullOrWhiteSpace(variantId)
                        ? ResolveItemInfo(itemNo)
                        : ResolveVariantInfo(itemNo, variantId);
                    if (itemInfo == null) continue;

                    row.Cells["ItemNo"].Value = itemInfo.ItemCode;
                    row.Cells["VariantName"].Value = itemInfo.VariantName;
                    row.Cells["VariantId"].Value = itemInfo.VariationId;
                    row.Cells["Description"].Value = itemInfo.Description;
                    row.Cells["CategoryCode"].Value = itemInfo.CategoryCode;
                    row.Cells["AvailableQty"].Value = itemInfo.AvailableQty?.ToString("0.##") ?? string.Empty;

                    string doc = (row.Cells["DocumentNo"].Value ?? string.Empty).ToString()!.Trim();
                    string lineNo = (row.Cells["LineNo"].Value ?? string.Empty).ToString()!.Trim();
                    if (!string.IsNullOrWhiteSpace(doc) && !string.IsNullOrWhiteSpace(lineNo))
                    {
                        SaveQty(doc, lineNo, "[Available QTY]", itemInfo.AvailableQty);
                    }
                }
            }
            catch
            {
            }
            finally
            {
                suppressAutoSave = false;
            }
        }

        private void ApplyItemNoDropdownOptions()
        {
        }

        private string NormalizeItemLookupValue(string? rawValue)
        {
            string candidate = rawValue?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(candidate))
            {
                return string.Empty;
            }

            foreach (var option in itemLookupOptions)
            {
                if (string.Equals(option.ItemCode, candidate, StringComparison.OrdinalIgnoreCase)
                    || string.Equals(option.DisplayText, candidate, StringComparison.OrdinalIgnoreCase))
                {
                    return option.ItemCode;
                }
            }

            int separatorIndex = candidate.IndexOf(" - ", StringComparison.Ordinal);
            if (separatorIndex > 0)
            {
                return candidate[..separatorIndex].Trim();
            }

            return candidate;
        }

        private string NormalizeVariantLookupValue(string itemNo, string? rawValue)
        {
            string candidate = rawValue?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(candidate))
            {
                return string.Empty;
            }

            foreach (var option in BuildVariantLookupOptions(itemNo))
            {
                if (string.Equals(option.ItemCode, candidate, StringComparison.OrdinalIgnoreCase)
                    || string.Equals(option.DisplayText, candidate, StringComparison.OrdinalIgnoreCase))
                {
                    return option.ItemCode;
                }
            }

            int separatorIndex = candidate.IndexOf(" - ", StringComparison.Ordinal);
            return separatorIndex > 0 ? candidate[..separatorIndex].Trim() : candidate;
        }

        private void ShowItemNoDropdown(int rowIndex, string? initialSearchText = null)
        {
            if (itemLookupOptions.Count == 0)
            {
                RefreshItemLookupOptions();
            }

            if (itemLookupOptions.Count == 0)
            {
                string productionText = useProductionCategory ? "production categories" : "non-production categories";
                string detail = string.IsNullOrWhiteSpace(itemLookupLoadError)
                    ? "No matching items were loaded for the selected production filter."
                    : $"Lookup load failed: {itemLookupLoadError}";
                MessageBox.Show(this, $"Transfer item lookup is empty for {productionText}.\n\n{detail}", "Item Lookup", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            if (rowIndex < 0 || rowIndex >= grid.Rows.Count)
            {
                return;
            }

            Rectangle cellBounds = grid.GetCellDisplayRectangle(grid.Columns["ItemNo"].Index, rowIndex, true);
            var row = grid.Rows[rowIndex];
            if (row == null)
            {
                return;
            }

            if (row.IsNewRow)
            {
                if (!grid.AllowUserToAddRows)
                {
                    return;
                }

                rowIndex = grid.Rows.Add();
                if (rowIndex < 0 || rowIndex >= grid.Rows.Count)
                {
                    return;
                }

                row = grid.Rows[rowIndex];
                if (row == null)
                {
                    return;
                }

                try
                {
                    grid.CurrentCell = row.Cells["ItemNo"];
                }
                catch
                {
                }
            }

            var cell = row.Cells["ItemNo"];
            string initialItemCode = NormalizeItemLookupValue((cell.Value ?? string.Empty).ToString());
            Point screenLocation = grid.PointToScreen(new Point(cellBounds.Left, cellBounds.Bottom));

            using var popup = new TransferItemDropdownForm(itemLookupOptions, initialItemCode, initialSearchText)
            {
                Location = screenLocation,
                Width = Math.Max(320, cellBounds.Width + 220)
            };

            suppressItemNoPopup = true;
            try
            {
                if (ShowHostedDialog(popup) != DialogResult.OK || string.IsNullOrWhiteSpace(popup.SelectedItemCode))
                {
                    return;
                }

                cell.Value = popup.SelectedItemCode;
                string doc = (row.Cells["DocumentNo"].Value ?? string.Empty).ToString()!.Trim();
                string lineNo = (row.Cells["LineNo"].Value ?? string.Empty).ToString()!.Trim();
                if (documentFixed && !string.IsNullOrWhiteSpace(currentDocument))
                {
                    doc = currentDocument!;
                }

                HandleItemNumberEdit(row, doc, lineNo);
            }
            finally
            {
                suppressItemNoPopup = false;
            }
        }

        private void ShowVariantIdDropdown(int rowIndex, string? initialSearchText = null)
        {
            if (rowIndex < 0 || rowIndex >= grid.Rows.Count)
            {
                return;
            }

            var row = grid.Rows[rowIndex];
            if (row == null)
            {
                return;
            }

            string itemNo = NormalizeItemLookupValue((row.Cells["ItemNo"].Value ?? string.Empty).ToString());
            if (string.IsNullOrWhiteSpace(itemNo))
            {
                MessageBox.Show(this, "Select an Item No. before choosing a Variant ID.", "Variant Lookup", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var variantOptions = BuildVariantLookupOptions(itemNo);
            if (variantOptions.Count == 0)
            {
                MessageBox.Show(this, $"No variants were found for item {itemNo}.", "Variant Lookup", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            Rectangle cellBounds = grid.GetCellDisplayRectangle(grid.Columns["VariantName"].Index, rowIndex, true);
            Point screenLocation = grid.PointToScreen(new Point(cellBounds.Left, cellBounds.Bottom));
            string initialVariantId = NormalizeVariantLookupValue(itemNo, (row.Cells["VariantName"].Value ?? string.Empty).ToString());

            using var popup = new TransferItemDropdownForm(variantOptions, initialVariantId, initialSearchText, "Search variant name...")
            {
                Location = screenLocation,
                Width = Math.Max(320, cellBounds.Width + 220)
            };

            suppressItemNoPopup = true;
            try
            {
                if (ShowHostedDialog(popup) != DialogResult.OK || string.IsNullOrWhiteSpace(popup.SelectedItemCode))
                {
                    return;
                }

                string selectedVariantId = popup.SelectedItemCode;
                string selectedVariantName = variantOptions.Find(option => string.Equals(option.ItemCode, selectedVariantId, StringComparison.OrdinalIgnoreCase))?.DisplayText ?? string.Empty;
                row.Cells["VariantName"].Value = selectedVariantName;
                row.Cells["VariantId"].Value = selectedVariantId;
                string doc = (row.Cells["DocumentNo"].Value ?? string.Empty).ToString()!.Trim();
                string lineNo = (row.Cells["LineNo"].Value ?? string.Empty).ToString()!.Trim();
                if (documentFixed && !string.IsNullOrWhiteSpace(currentDocument))
                {
                    doc = currentDocument!;
                }

                HandleVariantIdEdit(row, doc, lineNo);
            }
            finally
            {
                suppressItemNoPopup = false;
            }
        }

        private DialogResult ShowHostedDialog(Form dialog)
        {
            var owner = FindForm();
            return owner != null && owner != this
                ? dialog.ShowDialog(owner)
                : dialog.ShowDialog();
        }

        private sealed class TransferItemInfo
        {
            public string ItemCode { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string CategoryCode { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public string VariantName { get; init; } = string.Empty;
            public decimal? AvailableQty { get; init; }
        }

        private sealed class ItemLookupOption
        {
            public ItemLookupOption(string itemCode, string description, string variationId = "", string? displayText = null)
            {
                ItemCode = itemCode?.Trim() ?? string.Empty;
                Description = description?.Trim() ?? string.Empty;
                VariationId = variationId?.Trim() ?? string.Empty;
                DisplayTextOverride = displayText?.Trim() ?? string.Empty;
            }

            public string ItemCode { get; }
            public string Description { get; }
            public string VariationId { get; }
            public string DisplayTextOverride { get; }
            public string DisplayText => !string.IsNullOrWhiteSpace(DisplayTextOverride)
                ? DisplayTextOverride
                : string.IsNullOrWhiteSpace(Description) ? ItemCode : $"{ItemCode} - {Description}";

            public override string ToString() => DisplayText;
        }

        private sealed class TransferItemLookupRow
        {
            public string ItemNo { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string CategoryCode { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public decimal? QuantityInStock { get; init; }
        }

        private sealed class TransferItemDropdownForm : Form
        {
            private readonly TextBox txtSearch;
            private readonly ListBox listBox;
            private readonly List<ItemLookupOption> options;

            public string SelectedItemCode { get; private set; } = string.Empty;

            public TransferItemDropdownForm(List<ItemLookupOption> options, string initialItemCode, string? initialSearchText, string placeholderText = "Search item no. or description...")
            {
                this.options = options ?? new List<ItemLookupOption>();

                FormBorderStyle = FormBorderStyle.FixedSingle;
                StartPosition = FormStartPosition.Manual;
                ShowInTaskbar = false;
                MaximizeBox = false;
                MinimizeBox = false;
                BackColor = Color.White;
                Size = new Size(420, 260);

                txtSearch = new TextBox
                {
                    Dock = DockStyle.Top,
                    Height = 30,
                    BorderStyle = BorderStyle.FixedSingle,
                    BackColor = Color.White,
                    ForeColor = Color.Black,
                    Font = new Font("Arial", 9F, FontStyle.Regular),
                    PlaceholderText = placeholderText
                };

                listBox = new ListBox
                {
                    Dock = DockStyle.Fill,
                    BorderStyle = BorderStyle.None,
                    BackColor = Color.White,
                    ForeColor = Color.Black,
                    Font = new Font("Arial", 9F, FontStyle.Regular),
                    IntegralHeight = false,
                    DrawMode = DrawMode.Normal
                };

                txtSearch.TextChanged += (s, e) => ApplyFilter();
                txtSearch.KeyDown += (s, e) =>
                {
                    if (e.KeyCode == Keys.Down && listBox.Items.Count > 0)
                    {
                        listBox.Focus();
                        if (listBox.SelectedIndex < 0)
                        {
                            listBox.SelectedIndex = 0;
                        }
                        e.Handled = true;
                        e.SuppressKeyPress = true;
                    }
                    else if (e.KeyCode == Keys.Enter && listBox.Items.Count > 0)
                    {
                        if (listBox.SelectedIndex < 0)
                        {
                            listBox.SelectedIndex = 0;
                        }
                        SelectCurrentItem();
                        e.Handled = true;
                        e.SuppressKeyPress = true;
                    }
                    else if (e.KeyCode == Keys.Escape)
                    {
                        DialogResult = DialogResult.Cancel;
                        Close();
                        e.Handled = true;
                        e.SuppressKeyPress = true;
                    }
                };

                listBox.DoubleClick += (s, e) => SelectCurrentItem();
                listBox.KeyDown += (s, e) =>
                {
                    if (e.KeyCode == Keys.Enter)
                    {
                        SelectCurrentItem();
                        e.Handled = true;
                    }
                    else if (e.KeyCode == Keys.Escape)
                    {
                        DialogResult = DialogResult.Cancel;
                        Close();
                        e.Handled = true;
                    }
                    else if (e.KeyCode == Keys.Up && listBox.SelectedIndex <= 0)
                    {
                        txtSearch.Focus();
                        txtSearch.SelectionStart = txtSearch.TextLength;
                        e.Handled = true;
                    }
                };

                Controls.Add(listBox);
                Controls.Add(txtSearch);

                Shown += (s, e) =>
                {
                    txtSearch.Text = initialSearchText ?? string.Empty;
                    ApplyFilter(string.IsNullOrWhiteSpace(initialSearchText) ? initialItemCode : null);
                    txtSearch.Focus();
                    txtSearch.SelectionStart = txtSearch.TextLength;
                };

                Deactivate += (s, e) =>
                {
                    if (DialogResult == DialogResult.None)
                    {
                        DialogResult = DialogResult.Cancel;
                        Close();
                    }
                };
            }

            private void ApplyFilter(string? preferredItemCode = null)
            {
                string search = txtSearch.Text.Trim();
                var filtered = string.IsNullOrWhiteSpace(search)
                    ? new List<ItemLookupOption>(options)
                    : options.FindAll(option =>
                        option.ItemCode.Contains(search, StringComparison.OrdinalIgnoreCase)
                        || option.Description.Contains(search, StringComparison.OrdinalIgnoreCase)
                        || option.VariationId.Contains(search, StringComparison.OrdinalIgnoreCase)
                        || option.DisplayText.Contains(search, StringComparison.OrdinalIgnoreCase));

                listBox.BeginUpdate();
                try
                {
                    listBox.Items.Clear();
                    foreach (var option in filtered)
                    {
                        listBox.Items.Add(option);
                    }
                }
                finally
                {
                    listBox.EndUpdate();
                }

                if (!string.IsNullOrWhiteSpace(preferredItemCode))
                {
                    for (int i = 0; i < filtered.Count; i++)
                    {
                        if (string.Equals(filtered[i].ItemCode, preferredItemCode, StringComparison.OrdinalIgnoreCase))
                        {
                            listBox.SelectedIndex = i;
                            return;
                        }
                    }
                }

                if (listBox.Items.Count > 0)
                {
                    listBox.SelectedIndex = 0;
                }
            }

            private void SelectCurrentItem()
            {
                if (listBox.SelectedItem is not ItemLookupOption selected)
                {
                    return;
                }

                SelectedItemCode = selected.ItemCode;
                DialogResult = DialogResult.OK;
                Close();
            }
        }

        public readonly struct CategoryGenerationResult
        {
            public CategoryGenerationResult(int totalMatchingItems, int addedCount, int skippedCount)
            {
                TotalMatchingItems = totalMatchingItems;
                AddedCount = addedCount;
                SkippedCount = skippedCount;
            }

            public int TotalMatchingItems { get; }
            public int AddedCount { get; }
            public int SkippedCount { get; }
        }

        public CategoryGenerationResult AddItemsForCategory(string documentNo, string categoryCode)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                throw new InvalidOperationException("Document No. is required before generating transfer lines.");

            if (string.IsNullOrWhiteSpace(sourceWarehouseId))
                throw new InvalidOperationException("Select a From Warehouse before generating transfer lines.");

            var itemCodes = LoadItemCodesForCategory(categoryCode);
            if (itemCodes.Count == 0)
                return new CategoryGenerationResult(0, 0, 0);

            var existingItems = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (DataGridViewRow row in grid.Rows)
            {
                if (row == null || row.IsNewRow)
                    continue;

                string existingItemNo = (row.Cells["ItemNo"].Value ?? string.Empty).ToString()!.Trim();
                if (!string.IsNullOrWhiteSpace(existingItemNo))
                    existingItems.Add(existingItemNo);
            }

            int lineNo = GetNextLineNo(documentNo);
            int addedCount = 0;
            int skippedCount = 0;

            foreach (string itemCode in itemCodes)
            {
                if (existingItems.Contains(itemCode))
                {
                    skippedCount++;
                    continue;
                }

                var itemInfo = ResolveItemInfo(itemCode);
                if (itemInfo == null)
                {
                    skippedCount++;
                    continue;
                }

                UpsertLine(documentNo, lineNo, itemInfo.ItemCode, null, itemInfo.Description, itemInfo.CategoryCode, null, null, null, null);
                existingItems.Add(itemInfo.ItemCode);
                lineNo++;
                addedCount++;
            }

            LoadForDocument(documentNo);
            return new CategoryGenerationResult(itemCodes.Count, addedCount, skippedCount);
        }

        private List<string> LoadItemCodesForCategory(string categoryCode)
        {
            var itemCodes = new List<string>();

            using var conn = new SqlConnection(connectionString);
            conn.Open();
            using var cmd = new SqlCommand(@"
SELECT [Code]
FROM dbo.Items
WHERE LTRIM(RTRIM(ISNULL([CategoryCode], ''))) = @CategoryCode
ORDER BY ISNULL([Description], ''), [Code]", conn);
            cmd.Parameters.AddWithValue("@CategoryCode", categoryCode.Trim());

            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string itemCode = rdr["Code"] != DBNull.Value ? rdr["Code"].ToString()?.Trim() ?? string.Empty : string.Empty;
                if (!string.IsNullOrWhiteSpace(itemCode))
                    itemCodes.Add(itemCode);
            }

            return itemCodes;
        }

        private TransferItemInfo? ResolveItemInfo(string itemNo)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();

            using var cmd = new SqlCommand(@"
SELECT TOP 1 items.[Code], items.[Description], items.[CategoryCode], items.[QuantityInStock]
FROM dbo.Items items
LEFT JOIN dbo.Category category ON LTRIM(RTRIM(ISNULL(category.Code, ''))) = LTRIM(RTRIM(ISNULL(items.[CategoryCode], '')))
WHERE items.[Code] = @ItemNo
    AND ISNULL(category.IsProductionCategory, 0) = @UseProductionCategory
ORDER BY [Code]", conn);
            cmd.Parameters.AddWithValue("@ItemNo", itemNo);
            cmd.Parameters.AddWithValue("@UseProductionCategory", useProductionCategory);

            using var rdr = cmd.ExecuteReader();
            if (!rdr.Read()) return null;

            string itemCode = rdr["Code"] != DBNull.Value ? rdr["Code"].ToString()?.Trim() ?? string.Empty : string.Empty;
            string description = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString()?.Trim() ?? string.Empty : string.Empty;
            string categoryCode = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString()?.Trim() ?? string.Empty : string.Empty;

            decimal? availableQty = null;
            try
            {
                if (rdr["QuantityInStock"] != DBNull.Value)
                    availableQty = Convert.ToDecimal(rdr["QuantityInStock"]);
            }
            catch
            {
                availableQty = null;
            }

            return new TransferItemInfo
            {
                ItemCode = string.IsNullOrWhiteSpace(itemCode) ? itemNo : itemCode,
                Description = description,
                CategoryCode = categoryCode,
                VariationId = string.Empty,
                VariantName = string.Empty,
                AvailableQty = availableQty
            };
        }

        private TransferItemInfo? ResolveVariantInfo(string itemNo, string variantId)
        {
            if (string.IsNullOrWhiteSpace(itemNo) || string.IsNullOrWhiteSpace(variantId))
            {
                return ResolveItemInfo(itemNo);
            }

            using var conn = new SqlConnection(connectionString);
            conn.Open();
            if (!HasVariantTable(conn))
            {
                return ResolveItemInfo(itemNo);
            }

            using var cmd = new SqlCommand(@"
SELECT TOP 1
    ISNULL(NULLIF(variantItem.[Description], ''), ISNULL(NULLIF(mainItem.[Description], ''), '')) AS ItemDescription,
    ISNULL(NULLIF(v.VariantName, ''), '') AS VariantName,
    ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, ''))) AS CategoryCode,
    ISNULL(variantItem.QuantityInStock, mainItem.QuantityInStock) AS QuantityInStock
FROM dbo.[Variant] v
LEFT JOIN dbo.Items variantItem ON variantItem.Code = NULLIF(v.ItemCode, '')
LEFT JOIN dbo.Items mainItem ON mainItem.Code = v.MainItemCode
LEFT JOIN dbo.Category category ON LTRIM(RTRIM(ISNULL(category.Code, ''))) = LTRIM(RTRIM(ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))))
WHERE ISNULL(v.VariationId, '') = @VariantId
  AND (ISNULL(NULLIF(v.ItemCode, ''), '') = @ItemNo OR ISNULL(v.MainItemCode, '') = @ItemNo)
    AND ISNULL(category.IsProductionCategory, 0) = @UseProductionCategory", conn);
            cmd.Parameters.AddWithValue("@ItemNo", itemNo);
            cmd.Parameters.AddWithValue("@VariantId", variantId);
                        cmd.Parameters.AddWithValue("@UseProductionCategory", useProductionCategory);

            using var rdr = cmd.ExecuteReader();
            if (!rdr.Read())
            {
                return null;
            }

            decimal? availableQty = null;
            try
            {
                if (rdr["QuantityInStock"] != DBNull.Value)
                    availableQty = Convert.ToDecimal(rdr["QuantityInStock"]);
            }
            catch
            {
                availableQty = null;
            }

            if (!string.IsNullOrWhiteSpace(sourceWarehouseId))
            {
                try
                {
                    var cloudQty = OnlinefunctionsEvents.GetCloudVariationAvailableQuantityForWarehouse(variantId, sourceWarehouseId!, TimeSpan.FromSeconds(10));
                    if (cloudQty.HasValue)
                        availableQty = cloudQty.Value;
                }
                catch
                {
                }
            }

            string itemDescription = rdr["ItemDescription"] != DBNull.Value ? rdr["ItemDescription"].ToString()?.Trim() ?? string.Empty : string.Empty;
            string variantName = rdr["VariantName"] != DBNull.Value ? rdr["VariantName"].ToString()?.Trim() ?? string.Empty : string.Empty;
            string combinedDescription = string.IsNullOrWhiteSpace(variantName)
                ? itemDescription
                : string.IsNullOrWhiteSpace(itemDescription)
                    ? variantName
                    : $"{itemDescription} - {variantName}";

            return new TransferItemInfo
            {
                ItemCode = itemNo,
                Description = combinedDescription,
                CategoryCode = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString()?.Trim() ?? string.Empty : string.Empty,
                VariationId = variantId,
                VariantName = variantName,
                AvailableQty = availableQty
            };
        }

        private AutoCompleteStringCollection BuildItemLookupSuggestions()
        {
            var suggestions = new AutoCompleteStringCollection();

            foreach (var item in itemLookupOptions)
            {
                suggestions.Add(item.DisplayText);
                if (!string.Equals(item.DisplayText, item.ItemCode, StringComparison.OrdinalIgnoreCase))
                {
                    suggestions.Add(item.ItemCode);
                }
            }

            return suggestions;
        }

        private List<ItemLookupOption> BuildItemLookupOptions()
        {
            var itemCodes = new List<ItemLookupOption>();
            var seenCodes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            itemLookupLoadError = null;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                try
                {
                    using var cmd = new SqlCommand(@"
SELECT items.[Code], items.[Description]
FROM dbo.Items items
LEFT JOIN dbo.Category category ON LTRIM(RTRIM(ISNULL(category.Code, ''))) = LTRIM(RTRIM(ISNULL(items.[CategoryCode], '')))
WHERE ISNULL(category.IsProductionCategory, 0) = @UseProductionCategory
ORDER BY ISNULL(items.[Description], ''), items.[Code]", conn);
                    cmd.Parameters.AddWithValue("@UseProductionCategory", useProductionCategory);

                    using var rdr = cmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        string itemCode = rdr["Code"] != DBNull.Value ? rdr["Code"].ToString()?.Trim() ?? string.Empty : string.Empty;
                        if (!string.IsNullOrWhiteSpace(itemCode) && seenCodes.Add(itemCode))
                        {
                            string description = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString()?.Trim() ?? string.Empty : string.Empty;
                            itemCodes.Add(new ItemLookupOption(itemCode, description));
                        }
                    }
                }
                catch (Exception ex)
                {
                    itemLookupLoadError = string.IsNullOrWhiteSpace(itemLookupLoadError)
                        ? $"Item query: {ex.Message}"
                        : $"{itemLookupLoadError}; Item query: {ex.Message}";
                }
            }
            catch (Exception ex)
            {
                itemLookupLoadError = $"Connection: {ex.Message}";
            }

            return itemCodes;
        }

        private static bool HasVariantTable(SqlConnection connection)
        {
            using var cmd = new SqlCommand("SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Variant'", connection);
            return Convert.ToInt32(cmd.ExecuteScalar() ?? 0) > 0;
        }

        private List<ItemLookupOption> BuildVariantLookupOptions(string? itemNo)
        {
            var variantOptions = new List<ItemLookupOption>();
            string normalizedItemNo = itemNo?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(normalizedItemNo))
            {
                return variantOptions;
            }

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                if (!HasVariantTable(conn))
                {
                    return variantOptions;
                }

                using var cmd = new SqlCommand(@"
SELECT
    ISNULL(v.VariationId, '') AS VariationId,
    ISNULL(NULLIF(v.VariantName, ''), ISNULL(NULLIF(variantItem.[Description], ''), ISNULL(NULLIF(mainItem.[Description], ''), ''))) AS [Description]
FROM dbo.[Variant] v
LEFT JOIN dbo.Items variantItem ON variantItem.Code = NULLIF(v.ItemCode, '')
LEFT JOIN dbo.Items mainItem ON mainItem.Code = v.MainItemCode
LEFT JOIN dbo.Category category ON LTRIM(RTRIM(ISNULL(category.Code, ''))) = LTRIM(RTRIM(ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))))
WHERE ISNULL(v.VariationId, '') <> ''
  AND (ISNULL(NULLIF(v.ItemCode, ''), '') = @ItemNo OR ISNULL(v.MainItemCode, '') = @ItemNo)
    AND ISNULL(category.IsProductionCategory, 0) = @UseProductionCategory
ORDER BY ISNULL(NULLIF(v.VariantName, ''), ISNULL(NULLIF(variantItem.[Description], ''), ISNULL(NULLIF(mainItem.[Description], ''), ''))),
         ISNULL(v.VariationId, '')", conn);
                cmd.Parameters.AddWithValue("@ItemNo", normalizedItemNo);
                                cmd.Parameters.AddWithValue("@UseProductionCategory", useProductionCategory);

                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string variationId = rdr["VariationId"] != DBNull.Value ? rdr["VariationId"].ToString()?.Trim() ?? string.Empty : string.Empty;
                    if (string.IsNullOrWhiteSpace(variationId))
                    {
                        continue;
                    }

                    string description = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString()?.Trim() ?? string.Empty : string.Empty;
                    string displayText = string.IsNullOrWhiteSpace(description) ? variationId : description;
                    variantOptions.Add(new ItemLookupOption(variationId, description, string.Empty, displayText));
                }
            }
            catch
            {
            }

            return variantOptions;
        }

        private string ResolveVariantDisplayName(string itemNo, string variantId)
        {
            var variantInfo = ResolveVariantInfo(itemNo, variantId);
            if (variantInfo == null)
            {
                return string.Empty;
            }

            return string.IsNullOrWhiteSpace(variantInfo.VariantName)
                ? variantInfo.Description
                : variantInfo.VariantName;
        }

        private sealed class TransferItemLookupDialog : Form
        {
            private readonly string connectionString;
            private readonly bool useProductionCategory;
            private readonly TextBox txtSearch;
            private readonly DataGridView resultsGrid;
            private readonly Label lblCount;

            public string SelectedItemNo { get; private set; } = string.Empty;

            public TransferItemLookupDialog(string connectionString, bool useProductionCategory, string initialSearch)
            {
                this.connectionString = connectionString;
                this.useProductionCategory = useProductionCategory;

                Text = "Lookup Item";
                Size = new Size(860, 540);
                StartPosition = FormStartPosition.CenterParent;
                BackColor = Color.White;
                MinimizeBox = false;
                MaximizeBox = false;

                var lblSearch = new Label
                {
                    Text = "Search Item:",
                    Left = 12,
                    Top = 16,
                    Width = 90,
                    Font = new Font("Arial", 10, FontStyle.Bold)
                };

                txtSearch = new TextBox
                {
                    Left = 108,
                    Top = 12,
                    Width = 360,
                    Font = new Font("Arial", 10),
                    PlaceholderText = "Search by item code or description...",
                    Text = initialSearch ?? string.Empty
                };

                var btnRefresh = new Button
                {
                    Text = "Refresh",
                    Left = 480,
                    Top = 10,
                    Width = 90,
                    Height = 30,
                    BackColor = Color.RoyalBlue,
                    ForeColor = Color.White,
                    Font = new Font("Arial", 9, FontStyle.Bold),
                    UseVisualStyleBackColor = false
                };

                var btnClear = new Button
                {
                    Text = "Clear",
                    Left = 578,
                    Top = 10,
                    Width = 90,
                    Height = 30,
                    BackColor = Color.DimGray,
                    ForeColor = Color.White,
                    Font = new Font("Arial", 9, FontStyle.Bold),
                    UseVisualStyleBackColor = false
                };

                var lblCategory = new Label
                {
                    Left = 12,
                    Top = 46,
                    Width = 420,
                    Height = 18,
                    Font = new Font("Arial", 8, FontStyle.Bold),
                    ForeColor = Color.MediumVioletRed,
                    Text = this.useProductionCategory
                        ? "Category filter: Production categories"
                        : "Category filter: Non-production categories"
                };

                lblCount = new Label
                {
                    Left = 620,
                    Top = 46,
                    Width = 210,
                    Height = 18,
                    Font = new Font("Arial", 9, FontStyle.Bold),
                    ForeColor = Color.DarkBlue,
                    TextAlign = ContentAlignment.MiddleRight
                };

                resultsGrid = new DataGridView
                {
                    Left = 12,
                    Top = 72,
                    Width = 818,
                    Height = 390,
                    ReadOnly = true,
                    AllowUserToAddRows = false,
                    AllowUserToDeleteRows = false,
                    AutoGenerateColumns = false,
                    AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                    SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                    MultiSelect = false,
                    RowHeadersVisible = false,
                    BackgroundColor = Color.White
                };

                resultsGrid.Columns.Add(new DataGridViewTextBoxColumn { DataPropertyName = nameof(TransferItemLookupRow.ItemNo), HeaderText = "Item No.", FillWeight = 22 });
                resultsGrid.Columns.Add(new DataGridViewTextBoxColumn { DataPropertyName = nameof(TransferItemLookupRow.Description), HeaderText = "Description", FillWeight = 44 });
                resultsGrid.Columns.Add(new DataGridViewTextBoxColumn { DataPropertyName = nameof(TransferItemLookupRow.CategoryCode), HeaderText = "Category", FillWeight = 16 });
                resultsGrid.Columns.Add(new DataGridViewTextBoxColumn { DataPropertyName = nameof(TransferItemLookupRow.QuantityInStock), HeaderText = "Stock", FillWeight = 12, DefaultCellStyle = new DataGridViewCellStyle { Format = "N2", Alignment = DataGridViewContentAlignment.MiddleRight } });

                var btnSelect = new Button
                {
                    Text = "Select",
                    Left = 610,
                    Top = 474,
                    Width = 100,
                    Height = 40,
                    BackColor = Color.Green,
                    ForeColor = Color.White,
                    Font = new Font("Arial", 10, FontStyle.Bold),
                    UseVisualStyleBackColor = false
                };

                var btnClose = new Button
                {
                    Text = "Close",
                    Left = 722,
                    Top = 474,
                    Width = 100,
                    Height = 40,
                    BackColor = Color.DimGray,
                    ForeColor = Color.White,
                    Font = new Font("Arial", 10, FontStyle.Bold),
                    UseVisualStyleBackColor = false
                };

                Controls.AddRange(new Control[]
                {
                    lblSearch, txtSearch, btnRefresh, btnClear, lblCategory, lblCount, resultsGrid, btnSelect, btnClose
                });

                btnRefresh.Click += (s, e) => LoadItems();
                btnClear.Click += (s, e) =>
                {
                    txtSearch.Clear();
                    txtSearch.Focus();
                };
                btnSelect.Click += (s, e) => SelectCurrentItem();
                btnClose.Click += (s, e) => Close();
                txtSearch.TextChanged += (s, e) => LoadItems();
                txtSearch.KeyDown += (s, e) =>
                {
                    if ((e.KeyCode == Keys.Enter || e.KeyCode == Keys.Down) && resultsGrid.Rows.Count > 0)
                    {
                        resultsGrid.Focus();
                        resultsGrid.CurrentCell = resultsGrid.Rows[0].Cells[0];
                        e.Handled = true;
                        e.SuppressKeyPress = true;
                    }
                };
                resultsGrid.CellDoubleClick += (s, e) =>
                {
                    if (e.RowIndex >= 0)
                    {
                        SelectCurrentItem();
                    }
                };
                resultsGrid.KeyDown += (s, e) =>
                {
                    if (e.KeyCode == Keys.Enter)
                    {
                        SelectCurrentItem();
                        e.Handled = true;
                        e.SuppressKeyPress = true;
                    }
                };

                Shown += (s, e) =>
                {
                    LoadItems();
                    txtSearch.Focus();
                    txtSearch.SelectionStart = txtSearch.TextLength;
                };
            }

            private void LoadItems()
            {
                var rows = new List<TransferItemLookupRow>();

                using var conn = new SqlConnection(connectionString);
                conn.Open();
                string searchText = txtSearch.Text.Trim();

                using var cmd = new SqlCommand(@"
SELECT TOP 300 items.[Code], items.[Description], items.[CategoryCode], items.[QuantityInStock]
FROM dbo.Items items
LEFT JOIN dbo.Category category ON LTRIM(RTRIM(ISNULL(category.Code, ''))) = LTRIM(RTRIM(ISNULL(items.[CategoryCode], '')))
WHERE ISNULL(items.[IsActive], 1) = 1
    AND ISNULL(category.IsProductionCategory, 0) = @UseProductionCategory
  AND (
        @Search = ''
                OR items.[Code] LIKE @SearchLike
                OR ISNULL(items.[Description], '') LIKE @SearchLike
      )
ORDER BY
    CASE
                WHEN @Search <> '' AND items.[Code] = @Search THEN 0
                WHEN @Search <> '' AND items.[Code] LIKE @StartsWith THEN 1
                WHEN @Search <> '' AND ISNULL(items.[Description], '') LIKE @StartsWith THEN 2
        ELSE 3
    END,
        ISNULL(items.[Description], ''),
        items.[Code]", conn);
                                cmd.Parameters.AddWithValue("@UseProductionCategory", useProductionCategory);
                cmd.Parameters.AddWithValue("@Search", searchText);
                cmd.Parameters.AddWithValue("@SearchLike", $"%{searchText}%");
                cmd.Parameters.AddWithValue("@StartsWith", $"{searchText}%");

                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string itemNo = rdr["Code"] != DBNull.Value ? rdr["Code"].ToString()?.Trim() ?? string.Empty : string.Empty;
                    if (string.IsNullOrWhiteSpace(itemNo) || rows.Exists(row => string.Equals(row.ItemNo, itemNo, StringComparison.OrdinalIgnoreCase)))
                    {
                        continue;
                    }

                    decimal? quantityInStock = null;
                    try
                    {
                        if (rdr["QuantityInStock"] != DBNull.Value)
                        {
                            quantityInStock = Convert.ToDecimal(rdr["QuantityInStock"]);
                        }
                    }
                    catch
                    {
                        quantityInStock = null;
                    }

                    rows.Add(new TransferItemLookupRow
                    {
                        ItemNo = itemNo,
                        Description = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString()?.Trim() ?? string.Empty : string.Empty,
                        CategoryCode = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString()?.Trim() ?? string.Empty : string.Empty,
                        VariationId = string.Empty,
                        QuantityInStock = quantityInStock
                    });
                }

                resultsGrid.DataSource = rows;
                lblCount.Text = $"Items found: {rows.Count}";

                if (resultsGrid.Rows.Count > 0)
                {
                    resultsGrid.CurrentCell = resultsGrid.Rows[0].Cells[0];
                }
            }

            private void SelectCurrentItem()
            {
                if (resultsGrid.CurrentRow?.DataBoundItem is not TransferItemLookupRow row)
                {
                    return;
                }

                SelectedItemNo = row.ItemNo;
                DialogResult = DialogResult.OK;
                Close();
            }
        }

        private int GetNextLineNo(string documentNo)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();
            using var cmd = new SqlCommand($"SELECT ISNULL(MAX([Line No.]), 0) + 1 FROM {documentContext.LineTableName} WHERE [Document No.] = @Doc", conn);
            cmd.Parameters.AddWithValue("@Doc", documentNo);
            object? value = cmd.ExecuteScalar();
            try
            {
                return value != null && value != DBNull.Value ? Convert.ToInt32(value) : 1;
            }
            catch
            {
                return 1;
            }
        }

        private static decimal? ParseNullableDecimal(string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            if (!decimal.TryParse(value.Trim(), out var parsed))
                throw new InvalidOperationException("Quantity must be numeric.");
            return parsed;
        }

        private static decimal? ParseNullableDecimalSafe(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return null;

            return decimal.TryParse(value.Trim(), out var parsed) ? parsed : null;
        }

        private static decimal? CalculateQtyShipped(decimal? quantity, decimal? qtyToShip)
        {
            if (!quantity.HasValue && !qtyToShip.HasValue)
                return null;

            decimal totalQuantity = quantity ?? 0m;
            decimal remainingToShip = qtyToShip ?? 0m;
            decimal shipped = totalQuantity - remainingToShip;
            return shipped < 0m ? 0m : shipped;
        }

        private static string CalculateQtyShippedDisplayValue(string? quantityText, string? qtyToShipText, string? fallbackText)
        {
            decimal? quantity = ParseNullableDecimalSafe(quantityText);
            decimal? qtyToShip = ParseNullableDecimalSafe(qtyToShipText);
            decimal? qtyShipped = CalculateQtyShipped(quantity, qtyToShip);
            if (qtyShipped.HasValue)
                return qtyShipped.Value.ToString("0.##");

            return fallbackText?.Trim() ?? string.Empty;
        }

        private void UpdateCalculatedQtyShipped(DataGridViewRow row, string documentNo, string lineNo)
        {
            if (row == null)
                return;

            decimal? quantity = ParseNullableDecimalSafe((row.Cells["AvailableQty"].Value ?? string.Empty).ToString());
            decimal? qtyToShip = ParseNullableDecimalSafe((row.Cells["QtyToShip"].Value ?? string.Empty).ToString());
            decimal? qtyShipped = CalculateQtyShipped(quantity, qtyToShip);
            string displayValue = qtyShipped?.ToString("0.##") ?? string.Empty;

            row.Cells["QtyToShipped"].Value = displayValue;
            row.Cells["QtyReceived"].Value = displayValue;

            if (!string.IsNullOrWhiteSpace(documentNo) && !string.IsNullOrWhiteSpace(lineNo))
                SaveQty(documentNo, lineNo, "[Qty Received]", qtyShipped);
        }

        private void UpsertLine(string documentNo, int lineNo, string itemNo, string? variantId, string description, string categoryCode, decimal? availableQty, decimal? qtyToTransfer, decimal? qtyToReceive, decimal? qtyReceived)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();

            using var check = new SqlCommand($"SELECT COUNT(1) FROM {documentContext.LineTableName} WHERE [Document No.] = @Doc AND [Line No.] = @Line", conn);
            check.Parameters.AddWithValue("@Doc", documentNo);
            check.Parameters.AddWithValue("@Line", lineNo);
            bool exists = Convert.ToInt32(check.ExecuteScalar() ?? 0) > 0;

            string sql = exists
                ? $"UPDATE {documentContext.LineTableName} SET [Item No.] = @Item, [Variant ID] = @VariantId, [Description] = @Description, [CategoryCode] = @CategoryCode, [Available QTY] = @AvailableQty, [Qty To Transfer] = @QtyToTransfer, [Qty To Receive] = @QtyToReceive, [Qty Received] = @QtyReceived WHERE [Document No.] = @Doc AND [Line No.] = @Line"
                : $"INSERT INTO {documentContext.LineTableName} ([Document No.], [Item No.], [Variant ID], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty To Transfer], [Qty To Receive], [Qty Received]) VALUES (@Doc, @Item, @VariantId, @Description, @CategoryCode, @Line, @AvailableQty, @QtyToTransfer, @QtyToReceive, @QtyReceived)";

            using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("@Doc", documentNo);
            cmd.Parameters.AddWithValue("@Item", itemNo);
            cmd.Parameters.AddWithValue("@VariantId", string.IsNullOrWhiteSpace(variantId) ? (object)DBNull.Value : variantId);
            cmd.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(description) ? (object)DBNull.Value : description);
            cmd.Parameters.AddWithValue("@CategoryCode", string.IsNullOrWhiteSpace(categoryCode) ? (object)DBNull.Value : categoryCode);
            cmd.Parameters.AddWithValue("@Line", lineNo);
            cmd.Parameters.AddWithValue("@AvailableQty", (object?)availableQty ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@QtyToTransfer", (object?)qtyToTransfer ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@QtyToReceive", (object?)qtyToReceive ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@QtyReceived", (object?)qtyReceived ?? DBNull.Value);
            cmd.ExecuteNonQuery();
        }

        private void LoadData()
        {
            try
            {
                grid.Rows.Clear();
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand($"SELECT [Document No.], [Item No.], [Variant ID], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty To Transfer], [Qty To Receive], [Qty Received] FROM {documentContext.LineTableName} ORDER BY [Document No.], [Line No.]", conn);
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string doc = rdr["Document No."] != DBNull.Value ? rdr["Document No."].ToString() ?? "" : "";
                    string item = rdr["Item No."] != DBNull.Value ? rdr["Item No."].ToString() ?? "" : "";
                    string variantId = rdr["Variant ID"] != DBNull.Value ? rdr["Variant ID"].ToString() ?? "" : "";
                    string desc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                    string cat = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString() ?? "" : "";
                    string line = rdr["Line No."] != DBNull.Value ? rdr["Line No."].ToString() ?? "" : "";
                    string avail = rdr["Available QTY"] != DBNull.Value ? rdr["Available QTY"].ToString() ?? "" : "";
                    string qtyToReceive = rdr["Qty To Receive"] != DBNull.Value ? rdr["Qty To Receive"].ToString() ?? "" : "";
                    string received = rdr["Qty Received"] != DBNull.Value ? rdr["Qty Received"].ToString() ?? "" : "";
                    string variantName = string.IsNullOrWhiteSpace(item) || string.IsNullOrWhiteSpace(variantId)
                        ? string.Empty
                        : ResolveVariantDisplayName(item, variantId);
                    grid.Rows.Add(doc, item, variantName, variantId, desc, cat, line, avail, qtyToReceive, received);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load {documentContext.DocumentTitle} lines: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}