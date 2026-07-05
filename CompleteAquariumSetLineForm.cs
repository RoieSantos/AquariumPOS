using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class CompleteAquariumSetLineForm : Form
    {
        internal enum LookupPreference
        {
            Any,
            AquariumVariant,
            SumpVariant,
            StandVariant
        }

        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly string packageName;

        private Label lblTitle = null!;
        private Label lblPackagePrice = null!;
        private Label lblLineTotal = null!;
        private DataGridView grid = null!;
        private Button btnAdd = null!;
        private Button btnLookup = null!;
        private Button btnDelete = null!;
        private Button btnSave = null!;
        private Button btnRefresh = null!;
        private Button btnClose = null!;

        private DataTable table = new DataTable();
        private SqlDataAdapter adapter = null!;
        private BindingSource binding = new BindingSource();

        public CompleteAquariumSetLineForm(string packageName)
        {
            this.packageName = packageName ?? string.Empty;

            Text = "Complete Aquarium Set Line";
            Size = new Size(980, 620);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            InitializeComponent();
            EnsureTables();
            LoadHeaderDetails();
            LoadData();
        }

        private void InitializeComponent()
        {
            lblTitle = new Label
            {
                Text = $"Package: {packageName}",
                Dock = DockStyle.Top,
                Height = 32,
                Font = new Font("Arial", 14, FontStyle.Bold),
                ForeColor = Color.DarkBlue,
                Padding = new Padding(12, 6, 0, 0)
            };

            lblPackagePrice = new Label
            {
                Text = "Package Price: 0.00",
                Dock = DockStyle.Top,
                Height = 24,
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.DarkGreen,
                Padding = new Padding(12, 0, 0, 0)
            };

            lblLineTotal = new Label
            {
                Text = "Included Items Total: 0.00",
                Dock = DockStyle.Top,
                Height = 24,
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.SaddleBrown,
                Padding = new Padding(12, 0, 0, 4)
            };

            grid = new DataGridView
            {
                Dock = DockStyle.Fill,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AutoGenerateColumns = true,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                BackgroundColor = Color.White,
                RowHeadersVisible = false
            };
            grid.CellEndEdit += Grid_CellEndEdit;
            grid.CellDoubleClick += Grid_CellDoubleClick;
            grid.KeyDown += Grid_KeyDown;
            grid.DataError += (s, e) =>
            {
                MessageBox.Show(this, "Please enter a valid value.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                e.Cancel = true;
            };

            btnAdd = CreateButton("Add", Color.Green, BtnAdd_Click);
            btnLookup = CreateButton("Lookup Item", Color.MediumSeaGreen, BtnLookup_Click);
            btnDelete = CreateButton("Delete", Color.Firebrick, BtnDelete_Click);
            btnSave = CreateButton("Save", Color.DarkOrange, BtnSave_Click);
            btnRefresh = CreateButton("Refresh", Color.RoyalBlue, (s, e) => LoadData());
            btnClose = CreateButton("Close", Color.DimGray, (s, e) => Close());

            var buttonPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 64,
                Padding = new Padding(8),
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false
            };
            buttonPanel.Controls.AddRange(new Control[] { btnAdd, btnLookup, btnDelete, btnSave, btnRefresh, btnClose });

            Controls.Add(grid);
            Controls.Add(buttonPanel);
            Controls.Add(lblLineTotal);
            Controls.Add(lblPackagePrice);
            Controls.Add(lblTitle);
        }

        private Button CreateButton(string text, Color backColor, EventHandler onClick)
        {
            var button = new Button
            {
                Text = text,
                Size = new Size(110, 40),
                BackColor = backColor,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold),
                UseVisualStyleBackColor = false,
                Margin = new Padding(6)
            };
            button.Click += onClick;
            return button;
        }

        private void EnsureTables()
        {
            try
            {
                CompleteAquariumSetData.EnsureTablesExist(connectionString);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to initialize aquarium set tables: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void LoadHeaderDetails()
        {
            try
            {
                using var connection = new SqlConnection(connectionString);
                connection.Open();
                using var command = new SqlCommand(@"
SELECT PackagePrice
FROM dbo.CompleteAquariumSetHeader
WHERE PackageName = @PackageName", connection);
                command.Parameters.AddWithValue("@PackageName", packageName);

                var value = command.ExecuteScalar();
                var price = value != null && value != DBNull.Value ? Convert.ToDecimal(value) : 0m;
                lblPackagePrice.Text = $"Package Price: {price:N2}";
            }
            catch
            {
                lblPackagePrice.Text = "Package Price: 0.00";
            }
        }

        private void LoadData()
        {
            try
            {
                table = new DataTable();
                adapter = new SqlDataAdapter(@"
SELECT EntryNo, PackageName, ItemNo, ItemName, Quantity, Price
FROM dbo.CompleteAquariumSetLine
WHERE PackageName = @PackageName
ORDER BY EntryNo", connectionString);
                adapter.SelectCommand.Parameters.AddWithValue("@PackageName", packageName);
                adapter.MissingSchemaAction = MissingSchemaAction.AddWithKey;

                try
                {
                    adapter.FillSchema(table, SchemaType.Source);
                }
                catch
                {
                }

                var builder = new SqlCommandBuilder(adapter);
                adapter.Fill(table);

                if (!table.Columns.Contains("Amount"))
                {
                    table.Columns.Add("Amount", typeof(decimal), "ISNULL(Quantity, 0) * ISNULL(Price, 0)");
                }

                binding.DataSource = table;
                grid.DataSource = binding;
                ConfigureGrid();
                UpdateTotals();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load aquarium set lines: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ConfigureGrid()
        {
            if (grid.Columns.Contains("EntryNo"))
            {
                grid.Columns["EntryNo"].Visible = false;
            }

            if (grid.Columns.Contains("PackageName"))
            {
                grid.Columns["PackageName"].HeaderText = "Package Name";
                grid.Columns["PackageName"].ReadOnly = true;
                grid.Columns["PackageName"].FillWeight = 28;
            }

            if (grid.Columns.Contains("ItemNo"))
            {
                grid.Columns["ItemNo"].HeaderText = "Item No.";
                grid.Columns["ItemNo"].FillWeight = 18;
            }

            if (grid.Columns.Contains("ItemName"))
            {
                grid.Columns["ItemName"].HeaderText = "Item Name";
                grid.Columns["ItemName"].FillWeight = 34;
            }

            if (grid.Columns.Contains("Quantity"))
            {
                grid.Columns["Quantity"].HeaderText = "Quantity";
                grid.Columns["Quantity"].FillWeight = 10;
                grid.Columns["Quantity"].DefaultCellStyle.Format = "N2";
                grid.Columns["Quantity"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            }

            if (grid.Columns.Contains("Price"))
            {
                grid.Columns["Price"].HeaderText = "Price";
                grid.Columns["Price"].FillWeight = 10;
                grid.Columns["Price"].DefaultCellStyle.Format = "N2";
                grid.Columns["Price"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            }

            if (grid.Columns.Contains("Amount"))
            {
                grid.Columns["Amount"].HeaderText = "Amount";
                grid.Columns["Amount"].FillWeight = 10;
                grid.Columns["Amount"].ReadOnly = true;
                grid.Columns["Amount"].DefaultCellStyle.Format = "N2";
                grid.Columns["Amount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            }

            foreach (DataGridViewColumn column in grid.Columns)
            {
                column.SortMode = DataGridViewColumnSortMode.NotSortable;
            }
        }

        private void BtnAdd_Click(object? sender, EventArgs e)
        {
            try
            {
                AddNewLine();

                if (grid.Rows.Count > 0)
                {
                    var gridRow = grid.Rows[grid.Rows.Count - 1];
                    grid.CurrentCell = gridRow.Cells["ItemNo"];
                    grid.BeginEdit(true);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to add line: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private DataRow AddNewLine()
        {
            var row = table.NewRow();
            row["PackageName"] = packageName;
            row["ItemNo"] = string.Empty;
            row["ItemName"] = string.Empty;
            row["Quantity"] = 1m;
            row["Price"] = 0m;
            table.Rows.Add(row);
            return row;
        }

        private void BtnLookup_Click(object? sender, EventArgs e)
        {
            OpenItemLookupForCurrentRow();
        }

        private void BtnDelete_Click(object? sender, EventArgs e)
        {
            if (grid.SelectedRows.Count == 0)
            {
                MessageBox.Show(this, "Please select a line to delete.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var confirm = MessageBox.Show(this, "Delete selected line?", "Confirm Delete", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (confirm != DialogResult.Yes)
            {
                return;
            }

            foreach (DataGridViewRow selectedRow in grid.SelectedRows)
            {
                if (!selectedRow.IsNewRow)
                {
                    grid.Rows.Remove(selectedRow);
                }
            }

            UpdateTotals();
        }

        private void BtnSave_Click(object? sender, EventArgs e)
        {
            try
            {
                ValidateRows();
                binding.EndEdit();
                grid.EndEdit();
                adapter.Update(table);
                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to save package lines: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ValidateRows()
        {
            foreach (var row in table.Rows.Cast<DataRow>().ToList())
            {
                if (row.RowState == DataRowState.Deleted)
                {
                    continue;
                }

                row["PackageName"] = packageName;

                var itemNo = row["ItemNo"]?.ToString()?.Trim() ?? string.Empty;
                var itemName = row["ItemName"]?.ToString()?.Trim() ?? string.Empty;
                var quantityText = row["Quantity"]?.ToString()?.Trim() ?? string.Empty;
                var priceText = row["Price"]?.ToString()?.Trim() ?? string.Empty;

                var isCompletelyBlank = string.IsNullOrWhiteSpace(itemNo)
                    && string.IsNullOrWhiteSpace(itemName)
                    && (string.IsNullOrWhiteSpace(quantityText) || string.Equals(quantityText, "0", StringComparison.OrdinalIgnoreCase) || string.Equals(quantityText, "0.00", StringComparison.OrdinalIgnoreCase))
                    && (string.IsNullOrWhiteSpace(priceText) || string.Equals(priceText, "0", StringComparison.OrdinalIgnoreCase) || string.Equals(priceText, "0.00", StringComparison.OrdinalIgnoreCase));

                if (isCompletelyBlank)
                {
                    row.Delete();
                    continue;
                }

                if (string.IsNullOrWhiteSpace(itemNo))
                {
                    throw new InvalidOperationException("Item No. is required for all saved lines.");
                }

                if (!decimal.TryParse(quantityText, out var quantity) || quantity <= 0)
                {
                    throw new InvalidOperationException($"Quantity must be greater than zero for item '{itemNo}'.");
                }

                if (!decimal.TryParse(priceText, out var price) || price < 0)
                {
                    throw new InvalidOperationException($"Price cannot be negative for item '{itemNo}'.");
                }

                row["Quantity"] = quantity;
                row["Price"] = price;
            }
        }

        private void Grid_CellEndEdit(object? sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0 || e.ColumnIndex < 0)
            {
                return;
            }

            var columnName = grid.Columns[e.ColumnIndex].Name;
            if (!string.Equals(columnName, "ItemNo", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(columnName, "Quantity", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(columnName, "Price", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            try
            {
                var row = ((DataRowView)binding[e.RowIndex]).Row;
                row["PackageName"] = packageName;

                if (string.Equals(columnName, "ItemNo", StringComparison.OrdinalIgnoreCase))
                {
                    var itemNo = row["ItemNo"]?.ToString()?.Trim() ?? string.Empty;
                    if (CompleteAquariumSetData.TryLookupItemDetails(connectionString, itemNo, out var itemName, out var price))
                    {
                        row["ItemName"] = itemName;
                        if (row["Price"] == DBNull.Value || Convert.ToDecimal(row["Price"]) == 0m)
                        {
                            row["Price"] = price;
                        }
                    }
                }
            }
            catch
            {
            }

            UpdateTotals();
        }

        private void Grid_CellDoubleClick(object? sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0 || e.ColumnIndex < 0)
            {
                return;
            }

            var columnName = grid.Columns[e.ColumnIndex].Name;
            if (string.Equals(columnName, "ItemNo", StringComparison.OrdinalIgnoreCase)
                || string.Equals(columnName, "ItemName", StringComparison.OrdinalIgnoreCase))
            {
                OpenItemLookupForCurrentRow(e.RowIndex);
            }
        }

        private void Grid_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode != Keys.F4)
            {
                return;
            }

            OpenItemLookupForCurrentRow();
            e.Handled = true;
            e.SuppressKeyPress = true;
        }

        private void OpenItemLookupForCurrentRow(int? rowIndex = null)
        {
            try
            {
                if (table == null)
                {
                    return;
                }

                var targetRowIndex = rowIndex ?? grid.CurrentCell?.RowIndex ?? -1;
                if (targetRowIndex < 0 || targetRowIndex >= binding.Count)
                {
                    AddNewLine();
                    targetRowIndex = binding.Count - 1;
                }

                if (targetRowIndex < 0 || targetRowIndex >= binding.Count)
                {
                    return;
                }

                var rowView = binding[targetRowIndex] as DataRowView;
                if (rowView == null)
                {
                    return;
                }

                var currentSearch = rowView.Row["ItemNo"]?.ToString()?.Trim();
                if (string.IsNullOrWhiteSpace(currentSearch))
                {
                    currentSearch = rowView.Row["ItemName"]?.ToString()?.Trim();
                }

                var lookupPreference = DetermineLookupPreference(rowView.Row);

                using var dialog = new CompleteAquariumSetItemLookupDialog(connectionString, currentSearch ?? string.Empty, lookupPreference);
                if (dialog.ShowDialog(this) != DialogResult.OK)
                {
                    return;
                }

                rowView.Row["PackageName"] = packageName;
                rowView.Row["ItemNo"] = dialog.SelectedItemNo;
                rowView.Row["ItemName"] = dialog.SelectedItemName;
                rowView.Row["Price"] = dialog.SelectedPrice;

                if (rowView.Row["Quantity"] == DBNull.Value || !decimal.TryParse(rowView.Row["Quantity"]?.ToString(), out var quantity) || quantity <= 0)
                {
                    rowView.Row["Quantity"] = 1m;
                }

                binding.ResetBindings(false);
                if (grid.Columns.Contains("Quantity"))
                {
                    grid.CurrentCell = grid.Rows[targetRowIndex].Cells["Quantity"];
                }

                UpdateTotals();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to lookup item: {ex.Message}", "Lookup Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private LookupPreference DetermineLookupPreference(DataRow row)
        {
            string itemNo = row["ItemNo"]?.ToString()?.Trim() ?? string.Empty;
            string itemName = row["ItemName"]?.ToString()?.Trim() ?? string.Empty;
            string combined = $"{itemNo} {itemName}".ToUpperInvariant();

            if (IsSumpVariantCode(itemNo) || combined.Contains("SUMP"))
            {
                return LookupPreference.SumpVariant;
            }

            if (IsStandVariantCode(itemNo) || combined.Contains("STAND") || combined.Contains("CABINET"))
            {
                return LookupPreference.StandVariant;
            }

            if (IsAquariumVariantCode(itemNo) || combined.Contains("AQUARIUM") || combined.Contains("TANK") || combined.Contains("OVERHEAD") || combined.Contains("RIMLESS"))
            {
                return LookupPreference.AquariumVariant;
            }

            return LookupPreference.Any;
        }

        private static bool IsAquariumVariantCode(string itemCode)
        {
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;
            return normalizedItemCode.StartsWith("AQ-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-AQUARIUM", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_AQUARIUM", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsSumpVariantCode(string itemCode)
        {
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;
            return normalizedItemCode.StartsWith("S-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("SUMP-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-SUMP", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_SUMP", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsStandVariantCode(string itemCode)
        {
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;
            return normalizedItemCode.StartsWith("AST-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("STAND-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CABINET-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-STAND", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_STAND", StringComparison.OrdinalIgnoreCase);
        }

        private void UpdateTotals()
        {
            decimal total = 0m;

            foreach (DataRow row in table.Rows)
            {
                if (row.RowState == DataRowState.Deleted)
                {
                    continue;
                }

                decimal quantity = 0m;
                decimal price = 0m;

                if (row["Quantity"] != DBNull.Value)
                {
                    decimal.TryParse(row["Quantity"].ToString(), out quantity);
                }

                if (row["Price"] != DBNull.Value)
                {
                    decimal.TryParse(row["Price"].ToString(), out price);
                }

                total += quantity * price;
            }

            lblLineTotal.Text = $"Included Items Total: {total:N2}";
        }
    }

    internal sealed class CompleteAquariumSetItemLookupDialog : Form
    {
        private readonly string connectionString;
        private readonly TextBox txtSearch;
        private readonly DataGridView grid;
        private readonly Button btnSelect;
        private readonly Label lblCount;
        private readonly BindingSource binding = new BindingSource();
        private readonly CompleteAquariumSetLineForm.LookupPreference lookupPreference;

        private sealed class LookupRow
        {
            public string ItemNo { get; init; } = string.Empty;
            public string ItemName { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string Category { get; init; } = string.Empty;
            public string MainItemCode { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public decimal Price { get; init; }
            public bool IsVariant { get; init; }
        }

        public string SelectedItemNo { get; private set; } = string.Empty;
        public string SelectedItemName { get; private set; } = string.Empty;
        public decimal SelectedPrice { get; private set; }

        public CompleteAquariumSetItemLookupDialog(string connectionString, string initialSearch = "", CompleteAquariumSetLineForm.LookupPreference lookupPreference = CompleteAquariumSetLineForm.LookupPreference.Any)
        {
            this.connectionString = connectionString;
            this.lookupPreference = lookupPreference;

            Text = "Lookup Item";
            Size = new Size(920, 560);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;
            MinimizeBox = false;

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
                Width = 320,
                Font = new Font("Arial", 10),
                PlaceholderText = "Search by item code, name or description...",
                Text = initialSearch ?? string.Empty
            };

            var btnRefresh = new Button
            {
                Text = "Refresh",
                Left = 440,
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
                Left = 538,
                Top = 10,
                Width = 90,
                Height = 30,
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 9, FontStyle.Bold),
                UseVisualStyleBackColor = false
            };

            var lblMode = new Label
            {
                Left = 640,
                Top = 44,
                Width = 240,
                Height = 18,
                Font = new Font("Arial", 8, FontStyle.Bold),
                ForeColor = Color.MediumVioletRed,
                TextAlign = ContentAlignment.MiddleRight,
                Text = GetLookupModeLabel()
            };

            lblCount = new Label
            {
                Left = 640,
                Top = 16,
                Width = 240,
                Height = 20,
                Font = new Font("Arial", 9, FontStyle.Bold),
                ForeColor = Color.DarkBlue,
                TextAlign = ContentAlignment.MiddleRight
            };

            grid = new DataGridView
            {
                Left = 12,
                Top = 48,
                Width = 876,
                Height = 430,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                RowHeadersVisible = false,
                BackgroundColor = Color.White
            };

            btnSelect = new Button
            {
                Text = "Select",
                Left = 578,
                Top = 488,
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
                Left = 690,
                Top = 488,
                Width = 100,
                Height = 40,
                BackColor = Color.DimGray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold),
                UseVisualStyleBackColor = false
            };

            Controls.AddRange(new Control[]
            {
                lblSearch, txtSearch, btnRefresh, btnClear, lblCount, lblMode, grid, btnSelect, btnClose
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
                if (e.KeyCode == Keys.Down && grid.Rows.Count > 0)
                {
                    grid.Focus();
                    grid.CurrentCell = grid.Rows[0].Cells[0];
                    e.Handled = true;
                    e.SuppressKeyPress = true;
                }
            };
            grid.CellDoubleClick += (s, e) =>
            {
                if (e.RowIndex >= 0)
                {
                    SelectCurrentItem();
                }
            };
            grid.KeyDown += (s, e) =>
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
            try
            {
                var searchText = txtSearch.Text.Trim();
                var lookupRows = LoadLookupRows(searchText);
                var itemsTable = BuildLookupTable(lookupRows);

                binding.DataSource = itemsTable;
                grid.DataSource = binding;

                if (grid.Columns.Contains("Item No."))
                {
                    grid.Columns["Item No."].FillWeight = 18;
                }

                if (grid.Columns.Contains("Item Name"))
                {
                    grid.Columns["Item Name"].FillWeight = 28;
                }

                if (grid.Columns.Contains("Description"))
                {
                    grid.Columns["Description"].FillWeight = 34;
                }

                if (grid.Columns.Contains("Price"))
                {
                    grid.Columns["Price"].FillWeight = 12;
                    grid.Columns["Price"].DefaultCellStyle.Format = "N2";
                    grid.Columns["Price"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                }

                if (grid.Columns.Contains("Category"))
                {
                    grid.Columns["Category"].FillWeight = 18;
                }

                if (grid.Columns.Contains("Type"))
                {
                    grid.Columns["Type"].FillWeight = 12;
                }

                if (grid.Columns.Contains("Main Item"))
                {
                    grid.Columns["Main Item"].FillWeight = 18;
                }

                if (grid.Columns.Contains("Variation ID"))
                {
                    grid.Columns["Variation ID"].FillWeight = 18;
                }

                lblCount.Text = $"Items found: {itemsTable.Rows.Count}";
                if (grid.Rows.Count > 0)
                {
                    grid.CurrentCell = grid.Rows[0].Cells[0];
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load items: {ex.Message}", "Lookup Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private List<LookupRow> LoadLookupRows(string searchText)
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();

            bool hasVariantTable;
            using (var existsCommand = new SqlCommand("SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Variant'", connection))
            {
                hasVariantTable = Convert.ToInt32(existsCommand.ExecuteScalar()) > 0;
            }

            var rows = new List<LookupRow>();
            if (hasVariantTable)
            {
                using var variantCommand = new SqlCommand(@"
SELECT
    ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode) AS ItemNo,
    ISNULL(NULLIF(v.VariantName, ''), ISNULL(NULLIF(variantItem.[Name], ''), ISNULL(NULLIF(variantItem.[Description], ''), ISNULL(NULLIF(mainItem.[Name], ''), ISNULL(mainItem.[Description], ''))))) AS ItemName,
    ISNULL(NULLIF(variantItem.[Description], ''), ISNULL(NULLIF(v.VariantName, ''), ISNULL(NULLIF(mainItem.[Description], ''), ''))) AS ItemDescription,
    ISNULL(v.Price, ISNULL(variantItem.Price, ISNULL(mainItem.Price, 0))) AS Price,
    ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, ''))) AS CategoryCode,
    ISNULL(c.[Description], '') AS CategoryDescription,
    ISNULL(v.MainItemCode, '') AS MainItemCode,
    ISNULL(v.VariationId, '') AS VariationId
FROM dbo.[Variant] v
LEFT JOIN dbo.Items variantItem ON variantItem.Code = ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)
LEFT JOIN dbo.Items mainItem ON mainItem.Code = v.MainItemCode
LEFT JOIN dbo.Category c ON c.Code = ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, '')))
WHERE ISNULL(variantItem.IsActive, ISNULL(mainItem.IsActive, 1)) = 1
  AND (
        @Search = ''
        OR ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode) LIKE @SearchLike
        OR ISNULL(NULLIF(v.VariantName, ''), '') LIKE @SearchLike
        OR ISNULL(NULLIF(variantItem.[Name], ''), '') LIKE @SearchLike
        OR ISNULL(NULLIF(variantItem.[Description], ''), '') LIKE @SearchLike
        OR ISNULL(NULLIF(mainItem.[Name], ''), '') LIKE @SearchLike
        OR ISNULL(NULLIF(mainItem.[Description], ''), '') LIKE @SearchLike
        OR ISNULL(v.VariationId, '') LIKE @SearchLike
      )
ORDER BY
    CASE
        WHEN @Search <> '' AND ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode) = @Search THEN 0
        WHEN @Search <> '' AND ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode) LIKE @StartsWith THEN 1
        WHEN @Search <> '' AND ISNULL(NULLIF(v.VariantName, ''), '') LIKE @StartsWith THEN 2
        ELSE 3
    END,
    ISNULL(NULLIF(v.VariantName, ''), ISNULL(NULLIF(variantItem.[Name], ''), ISNULL(NULLIF(variantItem.[Description], ''), ''))),
    ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)", connection);

                variantCommand.Parameters.AddWithValue("@Search", searchText);
                variantCommand.Parameters.AddWithValue("@SearchLike", $"%{searchText}%");
                variantCommand.Parameters.AddWithValue("@StartsWith", $"{searchText}%");

                using var reader = variantCommand.ExecuteReader();
                while (reader.Read())
                {
                    var itemNo = reader["ItemNo"]?.ToString()?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(itemNo))
                    {
                        continue;
                    }

                    rows.Add(new LookupRow
                    {
                        ItemNo = itemNo,
                        ItemName = reader["ItemName"]?.ToString()?.Trim() ?? itemNo,
                        Description = reader["ItemDescription"]?.ToString()?.Trim() ?? string.Empty,
                        Category = reader["CategoryDescription"]?.ToString()?.Trim() ?? reader["CategoryCode"]?.ToString()?.Trim() ?? string.Empty,
                        MainItemCode = reader["MainItemCode"]?.ToString()?.Trim() ?? string.Empty,
                        VariationId = reader["VariationId"]?.ToString()?.Trim() ?? string.Empty,
                        Price = reader["Price"] != DBNull.Value ? Convert.ToDecimal(reader["Price"]) : 0m,
                        IsVariant = !string.IsNullOrWhiteSpace(reader["VariationId"]?.ToString())
                            || !string.Equals(itemNo, reader["MainItemCode"]?.ToString()?.Trim() ?? string.Empty, StringComparison.OrdinalIgnoreCase)
                    });
                }
            }

            using var itemCommand = new SqlCommand(@"
SELECT
    i.Code,
    ISNULL(NULLIF(i.[Name], ''), ISNULL(i.[Description], '')) AS ItemName,
    ISNULL(i.[Description], '') AS ItemDescription,
    ISNULL(i.[Price], 0) AS Price,
    ISNULL(c.[Description], '') AS CategoryDescription
FROM dbo.Items i
LEFT JOIN dbo.Category c ON c.Code = i.CategoryCode
WHERE i.IsActive = 1
  AND (
        @Search = ''
        OR i.Code LIKE @SearchLike
        OR i.[Name] LIKE @SearchLike
        OR i.[Description] LIKE @SearchLike
      )
ORDER BY
    CASE
        WHEN @Search <> '' AND i.Code = @Search THEN 0
        WHEN @Search <> '' AND i.Code LIKE @StartsWith THEN 1
        WHEN @Search <> '' AND i.[Name] LIKE @StartsWith THEN 2
        ELSE 3
    END,
    i.[Name],
    i.Code", connection);

            itemCommand.Parameters.AddWithValue("@Search", searchText);
            itemCommand.Parameters.AddWithValue("@SearchLike", $"%{searchText}%");
            itemCommand.Parameters.AddWithValue("@StartsWith", $"{searchText}%");

            using (var reader = itemCommand.ExecuteReader())
            {
                while (reader.Read())
                {
                    var itemNo = reader["Code"]?.ToString()?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(itemNo))
                    {
                        continue;
                    }

                    if (rows.Any(row => string.Equals(row.ItemNo, itemNo, StringComparison.OrdinalIgnoreCase)))
                    {
                        continue;
                    }

                    rows.Add(new LookupRow
                    {
                        ItemNo = itemNo,
                        ItemName = reader["ItemName"]?.ToString()?.Trim() ?? itemNo,
                        Description = reader["ItemDescription"]?.ToString()?.Trim() ?? string.Empty,
                        Category = reader["CategoryDescription"]?.ToString()?.Trim() ?? string.Empty,
                        MainItemCode = itemNo,
                        VariationId = string.Empty,
                        Price = reader["Price"] != DBNull.Value ? Convert.ToDecimal(reader["Price"]) : 0m,
                        IsVariant = false
                    });
                }
            }

            return rows
                .OrderBy(row => GetLookupPreferenceRank(row))
                .ThenBy(row => searchText.Length > 0 && string.Equals(row.ItemNo, searchText, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
                .ThenBy(row => searchText.Length > 0 && row.ItemNo.StartsWith(searchText, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
                .ThenBy(row => row.IsVariant ? 0 : 1)
                .ThenBy(row => row.ItemName, StringComparer.OrdinalIgnoreCase)
                .ThenBy(row => row.ItemNo, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private int GetLookupPreferenceRank(LookupRow row)
        {
            bool matchesPreferredComponent = MatchesLookupPreference(row);

            return lookupPreference switch
            {
                CompleteAquariumSetLineForm.LookupPreference.Any => row.IsVariant ? 0 : 1,
                _ when matchesPreferredComponent && row.IsVariant => 0,
                _ when matchesPreferredComponent => 1,
                _ when row.IsVariant => 2,
                _ => 3,
            };
        }

        private bool MatchesLookupPreference(LookupRow row)
        {
            string combined = $"{row.ItemNo} {row.ItemName} {row.Description} {row.Category} {row.MainItemCode}".ToUpperInvariant();

            return lookupPreference switch
            {
                CompleteAquariumSetLineForm.LookupPreference.AquariumVariant => (IsAquariumVariantCode(row.ItemNo) || combined.Contains("AQUARIUM") || combined.Contains("TANK") || combined.Contains("OVERHEAD") || combined.Contains("RIMLESS"))
                    && !combined.Contains("SUMP")
                    && !combined.Contains("STAND")
                    && !combined.Contains("CABINET"),
                CompleteAquariumSetLineForm.LookupPreference.SumpVariant => IsSumpVariantCode(row.ItemNo) || combined.Contains("SUMP"),
                CompleteAquariumSetLineForm.LookupPreference.StandVariant => IsStandVariantCode(row.ItemNo) || combined.Contains("STAND") || combined.Contains("CABINET"),
                _ => true,
            };
        }

        private static bool IsAquariumVariantCode(string itemCode)
        {
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;
            return normalizedItemCode.StartsWith("AQ-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-AQUARIUM", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_AQUARIUM", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsSumpVariantCode(string itemCode)
        {
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;
            return normalizedItemCode.StartsWith("S-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("SUMP-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-SUMP", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_SUMP", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsStandVariantCode(string itemCode)
        {
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;
            return normalizedItemCode.StartsWith("AST-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("STAND-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CABINET-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-STAND", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_STAND", StringComparison.OrdinalIgnoreCase);
        }

        private string GetLookupModeLabel()
        {
            return lookupPreference switch
            {
                CompleteAquariumSetLineForm.LookupPreference.AquariumVariant => "Mode: Aquarium variants first",
                CompleteAquariumSetLineForm.LookupPreference.SumpVariant => "Mode: Sump variants first",
                CompleteAquariumSetLineForm.LookupPreference.StandVariant => "Mode: Stand variants first",
                _ => string.Empty,
            };
        }

        private DataTable BuildLookupTable(IEnumerable<LookupRow> lookupRows)
        {
            var itemsTable = new DataTable();
            itemsTable.Columns.Add("Type", typeof(string));
            itemsTable.Columns.Add("Item No.", typeof(string));
            itemsTable.Columns.Add("Item Name", typeof(string));
            itemsTable.Columns.Add("Description", typeof(string));
            itemsTable.Columns.Add("Price", typeof(decimal));
            itemsTable.Columns.Add("Category", typeof(string));
            itemsTable.Columns.Add("Main Item", typeof(string));
            itemsTable.Columns.Add("Variation ID", typeof(string));

            foreach (var row in lookupRows)
            {
                itemsTable.Rows.Add(
                    row.IsVariant ? "Variant" : "Item",
                    row.ItemNo,
                    row.ItemName,
                    row.Description,
                    row.Price,
                    row.Category,
                    row.MainItemCode,
                    row.VariationId);
            }

            return itemsTable;
        }

        private void SelectCurrentItem()
        {
            if (grid.CurrentRow?.DataBoundItem is not DataRowView rowView)
            {
                MessageBox.Show(this, "Please select an item first.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            SelectedItemNo = rowView.Row["Item No."]?.ToString()?.Trim() ?? string.Empty;
            SelectedItemName = rowView.Row["Item Name"]?.ToString()?.Trim() ?? string.Empty;

            if (rowView.Row["Price"] != DBNull.Value)
            {
                SelectedPrice = Convert.ToDecimal(rowView.Row["Price"]);
            }

            if (string.IsNullOrWhiteSpace(SelectedItemNo))
            {
                MessageBox.Show(this, "Selected item does not have a valid item number.", "Invalid Item", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            DialogResult = DialogResult.OK;
            Close();
        }
    }
}
