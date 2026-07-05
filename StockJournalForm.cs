using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using System.Collections.Generic;

namespace AquariumPOS
{
    public class StockJournalForm : Form
    {
        private DataGridView dgv;
        private Button btnAddRow;
        private Button btnRemoveRow;
        private Button btnCommit;
        private Button btnCancel;
        private TextBox searchBox;
        private Label searchLabel;
        private Button btnClearSearch;
        private List<string> allItems = new List<string>(); // Store all items for filtering
        private readonly Dictionary<string, List<VariantLookupRow>> variantsByMainItemCode = new Dictionary<string, List<VariantLookupRow>>(StringComparer.OrdinalIgnoreCase);

        private sealed class VariantLookupRow
        {
            public string MainItemCode { get; set; } = string.Empty;
            public string ItemCode { get; set; } = string.Empty;
            public string VariationId { get; set; } = string.Empty;
            public string VariantName { get; set; } = string.Empty;
            public decimal Price { get; set; }
            public string DisplayText => string.IsNullOrWhiteSpace(VariationId)
                ? VariantName
                : $"{VariantName} [{VariationId}]";
        }

        public StockJournalForm()
        {
            Text = "Stock Journal - Batch Adjustments";
            WindowState = FormWindowState.Maximized;
            StartPosition = FormStartPosition.CenterScreen;

            // Add search controls at the top
            searchLabel = new Label
            {
                Text = "Search Items:",
                Location = new Point(20, 15),
                Size = new Size(100, 20),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            searchBox = new TextBox
            {
                Location = new Point(130, 12),
                Size = new Size(400, 25),
                Font = new Font("Arial", 10),
                PlaceholderText = "Type to search item code or description..."
            };
            searchBox.TextChanged += SearchBox_TextChanged;

            btnClearSearch = new Button
            {
                Text = "Clear",
                Location = new Point(540, 11),
                Size = new Size(70, 27),
                Font = new Font("Arial", 9)
            };
            btnClearSearch.Click += (s, e) => {
                searchBox.Text = "";
                searchBox.Focus();
            };

            // Configure grid to behave more like a simple list where user can add many lines
            dgv = new DataGridView
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                Location = new Point(10, 40),
                Size = new Size(this.Width - 40, this.Height - 120), // Full screen minus margins and button area
                AllowUserToAddRows = true,
                RowHeadersVisible = false,
                AllowUserToDeleteRows = true,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                EditMode = DataGridViewEditMode.EditOnEnter,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill // Fill the width
            };

            var colItem = new DataGridViewComboBoxColumn { Name = "ItemCode", HeaderText = "Item Code", MinimumWidth = 250, FillWeight = 25 };
            colItem.AutoComplete = true;
            colItem.FlatStyle = FlatStyle.Flat;
            
            var colDesc = new DataGridViewTextBoxColumn { Name = "Description", HeaderText = "Description", MinimumWidth = 300, FillWeight = 35 };
            var colVariant = new DataGridViewComboBoxColumn { Name = "Variant", HeaderText = "Variant", MinimumWidth = 220, FillWeight = 22 };
            colVariant.AutoComplete = true;
            colVariant.FlatStyle = FlatStyle.Flat;
            var colQty = new DataGridViewTextBoxColumn { Name = "Quantity", HeaderText = "Quantity (±)", ValueType = typeof(decimal), MinimumWidth = 120, FillWeight = 15 };
            var colCost = new DataGridViewTextBoxColumn { Name = "UnitCost", HeaderText = "Unit Cost", ValueType = typeof(decimal), MinimumWidth = 120, FillWeight = 15 };
            var colReason = new DataGridViewTextBoxColumn { Name = "Reason", HeaderText = "Reason/Reference", MinimumWidth = 200, FillWeight = 10 };
            var colVariationId = new DataGridViewTextBoxColumn { Name = "VariationId", HeaderText = "Variation ID", Visible = false };
            var colVariantItemCode = new DataGridViewTextBoxColumn { Name = "VariantItemCode", HeaderText = "Variant Item Code", Visible = false };

            // Load items into dropdown
            LoadItemsIntoDropdown(colItem);
            LoadVariantsLookup();

            // Numeric formatting for columns
            colQty.DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            colQty.DefaultCellStyle.Format = "N2";
            colCost.DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            colCost.DefaultCellStyle.Format = "N2";

            dgv.Columns.AddRange(new DataGridViewColumn[] { colItem, colDesc, colVariant, colQty, colCost, colReason, colVariationId, colVariantItemCode });

            // Position buttons at bottom of maximized form
            btnAddRow = new Button { 
                Text = "Add Line", 
                Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
                Location = new Point(20, this.Height - 80), 
                Size = new Size(120, 35),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            
            btnRemoveRow = new Button { 
                Text = "Remove Line", 
                Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
                Location = new Point(150, this.Height - 80), 
                Size = new Size(120, 35),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            
            btnCommit = new Button { 
                Text = "Post All Adjustments", 
                Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
                Location = new Point(this.Width - 320, this.Height - 80), 
                Size = new Size(180, 35), 
                BackColor = Color.LightGreen,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            
            btnCancel = new Button { 
                Text = "Cancel", 
                Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
                Location = new Point(this.Width - 130, this.Height - 80), 
                Size = new Size(100, 35),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            Controls.Add(searchLabel);
            Controls.Add(searchBox);
            Controls.Add(btnClearSearch);
            Controls.Add(dgv);
            Controls.Add(btnAddRow);
            Controls.Add(btnRemoveRow);
            Controls.Add(btnCommit);
            Controls.Add(btnCancel);

            btnAddRow.Click += BtnAddRow_Click;
            btnRemoveRow.Click += BtnRemoveRow_Click;
            btnCommit.Click += BtnCommit_Click;
            btnCancel.Click += (object? s, EventArgs e) => Close();

            dgv.CellEndEdit += Dgv_CellEndEdit;
            dgv.KeyDown += Dgv_KeyDown;
            dgv.EditingControlShowing += Dgv_EditingControlShowing;
            dgv.DataError += Dgv_DataError;
        }

        private void SearchBox_TextChanged(object? sender, EventArgs e)
        {
            string searchText = searchBox.Text.ToLower();
            var itemCodeColumn = dgv.Columns["ItemCode"] as DataGridViewComboBoxColumn;
            
            if (itemCodeColumn != null)
            {
                // Preserve any currently selected cell values to avoid invalid combobox cell errors
                string? currentCellValue = null;
                if (dgv.CurrentCell?.OwningColumn?.Name == "ItemCode")
                {
                    currentCellValue = dgv.CurrentCell.Value?.ToString();
                }
                itemCodeColumn.Items.Clear();
                if (currentCellValue != null && currentCellValue != "") itemCodeColumn.Items.Add(currentCellValue);
                
                if (string.IsNullOrWhiteSpace(searchText))
                {
                    // Show all items if no search text
                    itemCodeColumn.Items.Add("-- Type to search items --");
                    foreach (var item in allItems.Take(100))
                    {
                        itemCodeColumn.Items.Add(item);
                    }
                }
                else
                {
                    // Filter items based on search text
                    var filteredItems = allItems
                        .Where(item => item.ToLower().Contains(searchText))
                        .OrderBy(item => 
                        {
                            var lowerItem = item.ToLower();
                            if (lowerItem.StartsWith(searchText)) return 1;
                            if (lowerItem.Contains($" - {searchText}")) return 2;
                            return 3;
                        })
                        .Take(50)
                        .ToList();

                    if (filteredItems.Any())
                    {
                        foreach (var item in filteredItems)
                        {
                            if (!itemCodeColumn.Items.Contains(item)) itemCodeColumn.Items.Add(item);
                        }
                    }
                    else
                    {
                        itemCodeColumn.Items.Add("-- No items found --");
                    }
                }
            }
            // If the user is expecting to search from the top box, try to forward the
            // text into the editing combobox for the current ItemCode cell so the
            // dropdown shows filtered results immediately.
            try
            {
                // Ensure we have an ItemCode cell to edit
                if (dgv.CurrentCell?.OwningColumn?.Name != "ItemCode")
                {
                    // If no current cell, move to last row first column (ItemCode)
                    if (dgv.CurrentCell == null)
                    {
                        if (dgv.Rows.Count == 0) dgv.Rows.Add();
                        dgv.CurrentCell = dgv[0, Math.Max(0, dgv.Rows.Count - 1)];
                    }
                    else
                    {
                        dgv.CurrentCell = dgv[0, dgv.CurrentCell.RowIndex];
                    }
                }

                // Begin edit and set the combo text
                if (dgv.CurrentCell?.OwningColumn?.Name == "ItemCode")
                {
                    dgv.BeginEdit(true);
                    var combo = dgv.EditingControl as ComboBox;
                    if (combo != null)
                    {
                        combo.Text = searchBox.Text;
                        combo.SelectionStart = combo.Text.Length;
                        combo.DroppedDown = true;
                    }
                }
            }
            catch
            {
                // ignore any focus/edition errors
            }
        }

        private void Dgv_EditingControlShowing(object? sender, DataGridViewEditingControlShowingEventArgs e)
        {
            if (dgv.CurrentCell?.OwningColumn?.Name == "ItemCode" && e.Control is ComboBox comboBox)
            {
                // Enable autocomplete and filtering
                comboBox.AutoCompleteMode = AutoCompleteMode.SuggestAppend;
                comboBox.AutoCompleteSource = AutoCompleteSource.ListItems;
                comboBox.DropDownStyle = ComboBoxStyle.DropDown;
                
                // Remove existing event handlers to avoid duplicates
                comboBox.TextChanged -= ComboBox_TextChanged;
                comboBox.TextChanged += ComboBox_TextChanged;
            }
            else if (dgv.CurrentCell?.OwningColumn?.Name == "Variant" && e.Control is ComboBox variantComboBox)
            {
                variantComboBox.AutoCompleteMode = AutoCompleteMode.SuggestAppend;
                variantComboBox.AutoCompleteSource = AutoCompleteSource.ListItems;
                variantComboBox.DropDownStyle = ComboBoxStyle.DropDownList;
            }
        }

        private void Dgv_DataError(object? sender, DataGridViewDataErrorEventArgs e)
        {
            // Suppress the default DataGridView error dialog for combobox cells whose value
            // is temporarily not present in the column's Items (happens while filtering).
            try
            {
                if (e.ColumnIndex >= 0 && e.RowIndex >= 0)
                {
                    var col = dgv.Columns[e.ColumnIndex] as DataGridViewComboBoxColumn;
                    var cell = dgv.Rows[e.RowIndex].Cells[e.ColumnIndex];
                    if (col != null && cell?.Value != null)
                    {
                        var val = cell.Value.ToString();
                        // If the current value is missing from the column items, add it so the cell can display it
                        if (!col.Items.Contains(val))
                        {
                            col.Items.Add(val);
                            e.ThrowException = false;
                            return;
                        }
                    }
                }
            }
            catch
            {
                // ignore
            }

            // Prevent the default dialog from showing
            e.ThrowException = false;
        }

        private void ComboBox_TextChanged(object? sender, EventArgs e)
        {
            if (sender is ComboBox comboBox && dgv.CurrentCell?.OwningColumn?.Name == "ItemCode")
            {
                string filterText = comboBox.Text.ToLower();
                
                if (string.IsNullOrWhiteSpace(filterText))
                {
                    // Show all items if no filter
                    return;
                }

                // Find matching items and update dropdown
                try
                {
                    var matchingItems = new List<string>();
                    using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        conn.Open();
                        var cmd = new SqlCommand(@"
                            SELECT TOP 20 Code, Description 
                            FROM Items 
                            WHERE IsActive = 1 
                            AND (Code LIKE @filter OR Description LIKE @filter)
                            ORDER BY 
                                CASE WHEN Code LIKE @exactFilter THEN 1 
                                     WHEN Code LIKE @startsFilter THEN 2 
                                     ELSE 3 END,
                                Code", conn);
                        
                        cmd.Parameters.AddWithValue("@filter", $"%{filterText}%");
                        cmd.Parameters.AddWithValue("@exactFilter", filterText);
                        cmd.Parameters.AddWithValue("@startsFilter", $"{filterText}%");
                        
                        using (var reader = cmd.ExecuteReader())
                        {
                            while (reader.Read())
                            {
                                string code = reader["Code"].ToString() ?? "";
                                string desc = reader["Description"].ToString() ?? "";
                                matchingItems.Add($"{code} - {desc}");
                            }
                        }
                    }

                    // Update the dropdown items
                    var itemCodeColumn = dgv.Columns["ItemCode"] as DataGridViewComboBoxColumn;
                    if (itemCodeColumn != null)
                    {
                        // Preserve current editing cell value
                        string? currentEditingValue = null;
                        if (dgv.CurrentCell != null && dgv.CurrentCell.OwningColumn.Name == "ItemCode")
                            currentEditingValue = dgv.CurrentCell.Value?.ToString();

                        itemCodeColumn.Items.Clear();
                        if (!string.IsNullOrWhiteSpace(currentEditingValue) && !itemCodeColumn.Items.Contains(currentEditingValue))
                            itemCodeColumn.Items.Add(currentEditingValue);

                        foreach (var item in matchingItems)
                        {
                            if (!itemCodeColumn.Items.Contains(item))
                                itemCodeColumn.Items.Add(item);
                        }
                    }
                }
                catch
                {
                    // Ignore errors during filtering
                }
            }
        }

        private void LoadItemsIntoDropdown(DataGridViewComboBoxColumn colItem)
        {
            try
            {
                allItems.Clear();
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();
                    var cmd = new SqlCommand("SELECT Code, Description FROM Items WHERE IsActive = 1 ORDER BY Code", conn);
                    using (var reader = cmd.ExecuteReader())
                    {
                        colItem.Items.Add("-- Type to search items --");
                        while (reader.Read())
                        {
                            string code = reader["Code"].ToString() ?? "";
                            string desc = reader["Description"].ToString() ?? "";
                            // Add as "Code - Description" for easy searching
                            string itemText = $"{code} - {desc}";
                            allItems.Add(itemText);
                            if (colItem.Items.Count < 101) // Limit initial display
                            {
                                colItem.Items.Add(itemText);
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading items: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void LoadVariantsLookup()
        {
            variantsByMainItemCode.Clear();

            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();

                    const string sql = @"
SELECT
    ISNULL(NULLIF(LTRIM(RTRIM(MainItemCode)), ''), '') AS MainItemCode,
    ISNULL(NULLIF(LTRIM(RTRIM(ItemCode)), ''), '') AS ItemCode,
    ISNULL(NULLIF(LTRIM(RTRIM(VariationId)), ''), '') AS VariationId,
    ISNULL(NULLIF(LTRIM(RTRIM(VariantName)), ''), '') AS VariantName,
    ISNULL(Price, 0) AS Price
FROM dbo.[Variant]
WHERE ISNULL(NULLIF(LTRIM(RTRIM(MainItemCode)), ''), '') <> ''
ORDER BY MainItemCode, VariantName, VariationId";

                    using (var cmd = new SqlCommand(sql, conn))
                    using (var reader = cmd.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            var row = new VariantLookupRow
                            {
                                MainItemCode = reader["MainItemCode"]?.ToString() ?? string.Empty,
                                ItemCode = reader["ItemCode"]?.ToString() ?? string.Empty,
                                VariationId = reader["VariationId"]?.ToString() ?? string.Empty,
                                VariantName = reader["VariantName"]?.ToString() ?? string.Empty,
                                Price = reader["Price"] != DBNull.Value ? Convert.ToDecimal(reader["Price"]) : 0m
                            };

                            if (string.IsNullOrWhiteSpace(row.VariantName))
                                row.VariantName = row.ItemCode;

                            if (!variantsByMainItemCode.TryGetValue(row.MainItemCode, out var list))
                            {
                                list = new List<VariantLookupRow>();
                                variantsByMainItemCode[row.MainItemCode] = list;
                            }

                            list.Add(row);
                        }
                    }
                }
            }
            catch
            {
                // Best-effort only; the stock journal still works even if the Variant table is unavailable.
            }
        }

        private void RefreshVariantCellOptions(int rowIndex, string itemCode, bool preserveExistingSelection)
        {
            if (rowIndex < 0 || rowIndex >= dgv.Rows.Count)
                return;

            var cell = dgv.Rows[rowIndex].Cells["Variant"] as DataGridViewComboBoxCell;
            if (cell == null)
                return;

            var existingText = preserveExistingSelection ? (cell.Value?.ToString() ?? string.Empty) : string.Empty;
            var existingVariationId = preserveExistingSelection ? (dgv.Rows[rowIndex].Cells["VariationId"].Value?.ToString() ?? string.Empty) : string.Empty;

            cell.Items.Clear();
            cell.DisplayStyle = DataGridViewComboBoxDisplayStyle.DropDownButton;
            cell.FlatStyle = FlatStyle.Flat;
            cell.Items.Add(string.Empty);

            if (!string.IsNullOrWhiteSpace(itemCode) && variantsByMainItemCode.TryGetValue(itemCode, out var variants) && variants.Count > 0)
            {
                foreach (var variant in variants)
                {
                    if (!cell.Items.Contains(variant.DisplayText))
                        cell.Items.Add(variant.DisplayText);
                }

                var selected = variants.FirstOrDefault(v =>
                    (!string.IsNullOrWhiteSpace(existingVariationId) && string.Equals(v.VariationId, existingVariationId, StringComparison.OrdinalIgnoreCase)) ||
                    (!string.IsNullOrWhiteSpace(existingText) && string.Equals(v.DisplayText, existingText, StringComparison.OrdinalIgnoreCase)));

                if (selected != null)
                {
                    cell.Value = selected.DisplayText;
                    dgv.Rows[rowIndex].Cells["VariationId"].Value = selected.VariationId;
                    dgv.Rows[rowIndex].Cells["VariantItemCode"].Value = selected.ItemCode;
                }
                else
                {
                    cell.Value = string.Empty;
                    dgv.Rows[rowIndex].Cells["VariationId"].Value = string.Empty;
                    dgv.Rows[rowIndex].Cells["VariantItemCode"].Value = string.Empty;
                }
            }
            else
            {
                cell.Value = string.Empty;
                dgv.Rows[rowIndex].Cells["VariationId"].Value = string.Empty;
                dgv.Rows[rowIndex].Cells["VariantItemCode"].Value = string.Empty;
            }
        }

        private VariantLookupRow? FindVariantByDisplayText(string itemCode, string displayText)
        {
            if (string.IsNullOrWhiteSpace(itemCode) || string.IsNullOrWhiteSpace(displayText))
                return null;

            if (!variantsByMainItemCode.TryGetValue(itemCode, out var variants))
                return null;

            return variants.FirstOrDefault(v => string.Equals(v.DisplayText, displayText, StringComparison.OrdinalIgnoreCase));
        }

        private void Dgv_CellEndEdit(object? sender, DataGridViewCellEventArgs e)
        {
            if (dgv.Columns[e.ColumnIndex].Name == "ItemCode")
            {
                var selectedValue = dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value?.ToString();
                if (!string.IsNullOrWhiteSpace(selectedValue) && !selectedValue.StartsWith("--"))
                {
                    // Extract code from "Code - Description" format
                    string code = selectedValue.Contains(" - ") ? selectedValue.Split(new[] { " - " }, StringSplitOptions.None)[0] : selectedValue;
                    
                    // Update the description column automatically
                    if (selectedValue.Contains(" - "))
                    {
                        string desc = selectedValue.Split(new[] { " - " }, StringSplitOptions.RemoveEmptyEntries).Skip(1).FirstOrDefault() ?? "";
                        dgv.Rows[e.RowIndex].Cells["Description"].Value = desc;
                    }

                    RefreshVariantCellOptions(e.RowIndex, code, preserveExistingSelection: false);
                }
                else if (selectedValue?.StartsWith("--") == true)
                {
                    // Clear the cell if placeholder text was selected
                    dgv.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = "";
                    RefreshVariantCellOptions(e.RowIndex, string.Empty, preserveExistingSelection: false);
                }
            }
            else if (dgv.Columns[e.ColumnIndex].Name == "Variant")
            {
                var itemCodeValue = dgv.Rows[e.RowIndex].Cells["ItemCode"].Value?.ToString() ?? string.Empty;
                var itemCode = itemCodeValue.Contains(" - ") ? itemCodeValue.Split(new[] { " - " }, StringSplitOptions.None)[0] : itemCodeValue;
                var selectedVariantText = dgv.Rows[e.RowIndex].Cells["Variant"].Value?.ToString() ?? string.Empty;
                var selectedVariant = FindVariantByDisplayText(itemCode, selectedVariantText);

                dgv.Rows[e.RowIndex].Cells["VariationId"].Value = selectedVariant?.VariationId ?? string.Empty;
                dgv.Rows[e.RowIndex].Cells["VariantItemCode"].Value = selectedVariant?.ItemCode ?? string.Empty;
            }
        }        private void BtnAddRow_Click(object? sender, EventArgs e)
        {
            dgv.Rows.Add();
        }

        private void BtnRemoveRow_Click(object? sender, EventArgs e)
        {
            if (dgv.CurrentRow != null)
                dgv.Rows.Remove(dgv.CurrentRow);
        }

        private void Dgv_KeyDown(object? sender, KeyEventArgs e)
        {
            // Enter to move to next cell / add row when at last cell
            if (e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                var grid = sender as DataGridView;
                if (grid != null)
                {
                    var row = grid.CurrentCell?.RowIndex ?? -1;
                    var col = grid.CurrentCell?.ColumnIndex ?? -1;
                    if (row == grid.Rows.Count - 1 && col == grid.Columns.Count - 1)
                    {
                        // at last cell, add new row and focus first cell
                        grid.Rows.Add();
                        grid.CurrentCell = grid[0, grid.Rows.Count - 1];
                    }
                    else
                    {
                        // move to next cell
                        int nextCol = Math.Min(grid.Columns.Count - 1, col + 1);
                        int nextRow = row;
                        if (nextCol == col) { nextRow = Math.Min(grid.Rows.Count - 1, row + 1); nextCol = 0; }
                        grid.CurrentCell = grid[nextCol, nextRow];
                    }
                }
            }
        }

        private void BtnCommit_Click(object? sender, EventArgs e)
        {
            // Validate rows
            if (dgv.Rows.Count == 0)
            {
                MessageBox.Show("No lines to commit.", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var lines = dgv.Rows.Cast<DataGridViewRow>()
                .Where(r => r.Cells["ItemCode"].Value != null && 
                           !string.IsNullOrWhiteSpace(r.Cells["ItemCode"].Value.ToString()) &&
                           !(r.Cells["ItemCode"].Value.ToString()?.StartsWith("--") ?? false))
                .Select(r => {
                    var itemCodeValue = r.Cells["ItemCode"].Value?.ToString() ?? "";
                    // Extract just the code part from "Code - Description" format
                    var itemCode = itemCodeValue.Contains(" - ") ? itemCodeValue.Split(new[] { " - " }, StringSplitOptions.None)[0] : itemCodeValue;
                    
                    return new
                    {
                        ItemCode = itemCode,
                        VariantItemCode = r.Cells["VariantItemCode"].Value?.ToString() ?? string.Empty,
                        Variant = r.Cells["Variant"].Value?.ToString() ?? string.Empty,
                        VariationId = r.Cells["VariationId"].Value?.ToString() ?? string.Empty,
                        Description = r.Cells["Description"].Value?.ToString() ?? string.Empty,
                        Quantity = ParseDecimalCell(r.Cells["Quantity"].Value),
                        UnitCost = ParseDecimalCell(r.Cells["UnitCost"].Value),
                        Reason = r.Cells["Reason"].Value?.ToString() ?? string.Empty
                    };
                })
                .ToList();

            if (lines.Count == 0)
            {
                MessageBox.Show("No valid lines found. Please enter at least one line with an Item Code.", "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var confirm = MessageBox.Show($"Commit {lines.Count} adjustment line(s)? This will update stock levels.", "Confirm Commit", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (confirm != DialogResult.Yes) return;

            // Commit in a single DB transaction
            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                conn.Open();
                using (var tran = conn.BeginTransaction())
                {
                    try
                    {
                        string documentNo = "SJ-" + DateTime.Now.ToString("yyyyMMdd-HHmmss");
                        foreach (var ln in lines)
                        {
                            // Insert into ItemLedgerEntry
                            using (var cmd = conn.CreateCommand())
                            {
                                cmd.Transaction = tran;
                                cmd.CommandText = @"INSERT INTO ItemLedgerEntry (EntryDate, ItemCode, VariationId, DocumentType, DocumentNo, Quantity, UnitCost, TotalCost, Description, UserID, StoreNo, PosTerminalNo)
VALUES (@EntryDate, @ItemCode, @VariationId, @DocumentType, @DocumentNo, @Quantity, @UnitCost, @TotalCost, @Description, @UserID, @StoreNo, @PosTerminalNo)";
                                cmd.Parameters.AddWithValue("@EntryDate", DateTime.Now);
                                var postingItemCode = !string.IsNullOrWhiteSpace(ln.VariantItemCode) ? ln.VariantItemCode : ln.ItemCode;
                                cmd.Parameters.AddWithValue("@ItemCode", postingItemCode ?? string.Empty);
                                cmd.Parameters.AddWithValue("@VariationId", ln.VariationId ?? string.Empty);
                                cmd.Parameters.AddWithValue("@DocumentType", "STOCK_ADJ");
                                cmd.Parameters.AddWithValue("@DocumentNo", documentNo);
                                cmd.Parameters.AddWithValue("@Quantity", ln.Quantity);
                                cmd.Parameters.AddWithValue("@UnitCost", ln.UnitCost);
                                cmd.Parameters.AddWithValue("@TotalCost", ln.Quantity * ln.UnitCost);
                                var ledgerDescription = string.IsNullOrWhiteSpace(ln.Reason)
                                    ? (string.IsNullOrWhiteSpace(ln.Variant) ? ln.Description : $"{ln.Description} - {ln.Variant}")
                                    : ln.Reason;
                                cmd.Parameters.AddWithValue("@Description", ledgerDescription ?? string.Empty);
                                cmd.Parameters.AddWithValue("@UserID", CurrentUser.Username ?? "SYSTEM");
                                cmd.Parameters.AddWithValue("@StoreNo", GlobalSettings.DefaultStoreNo);
                                cmd.Parameters.AddWithValue("@PosTerminalNo", GlobalSettings.DefaultPosTerminalNo);

                                cmd.ExecuteNonQuery();
                            }

                            // Update Items.QuantityInStock
                            using (var upd = conn.CreateCommand())
                            {
                                upd.Transaction = tran;
                                upd.CommandText = "UPDATE Items SET QuantityInStock = ISNULL(QuantityInStock, 0) + @qty WHERE Code = @code";
                                upd.Parameters.AddWithValue("@qty", ln.Quantity);
                                upd.Parameters.AddWithValue("@code", !string.IsNullOrWhiteSpace(ln.VariantItemCode) ? ln.VariantItemCode : (ln.ItemCode ?? string.Empty));
                                int affected = upd.ExecuteNonQuery();
                                if (affected == 0)
                                {
                                    // If item doesn't exist, rollback
                                    var missingCode = !string.IsNullOrWhiteSpace(ln.VariantItemCode) ? ln.VariantItemCode : ln.ItemCode;
                                    throw new Exception($"Item code not found: {missingCode}");
                                }
                            }
                        }

                        tran.Commit();
                        try
                        {
                            var onlineResponse = OnlinefunctionsEvents.SendStockJournalAdjustmentsOnline(documentNo);
                            MessageBox.Show($"Committed {lines.Count} adjustment line(s) successfully. DocumentNo: {documentNo}\n\nOnline sync completed.\n{onlineResponse}", "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        }
                        catch (Exception onlineEx)
                        {
                            MessageBox.Show($"Committed {lines.Count} adjustment line(s) successfully. DocumentNo: {documentNo}\n\nOnline sync failed: {onlineEx.Message}", "Success with Online Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        }
                        DialogResult = DialogResult.OK;
                        Close();
                    }
                    catch (Exception ex)
                    {
                        try { tran.Rollback(); } catch { }
                        MessageBox.Show("Error committing adjustments: " + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
        }

        private decimal ParseDecimalCell(object value)
        {
            if (value == null) return 0m;
            if (value is decimal d) return d;
            if (decimal.TryParse(value.ToString(), out var r)) return r;
            return 0m;
        }
    }
}
