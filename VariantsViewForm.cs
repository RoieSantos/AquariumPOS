using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class VariantsViewForm : Form
    {
        private readonly string connectionString;
        private readonly DataGridView productsGrid;
        private readonly DataGridView variantsGrid;
        private readonly TextBox searchBox;
        private readonly Label summaryLabel;
        private readonly Label detailLabel;
        private readonly Button refreshButton;
        private readonly Button closeButton;

        private List<VariantItemRow> allVariantRows = new();
        private string? selectedMainItemCode;

        public VariantsViewForm(string connectionString)
        {
            this.connectionString = connectionString;

            Text = "Product Variants";
            StartPosition = FormStartPosition.CenterParent;
            Size = new Size(1400, 820);
            BackColor = Color.White;
            MinimizeBox = false;

            var searchLabel = new Label
            {
                Text = "Search:",
                Location = new Point(20, 18),
                Size = new Size(60, 24),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            searchBox = new TextBox
            {
                Location = new Point(85, 15),
                Size = new Size(380, 28),
                Font = new Font("Arial", 10),
                PlaceholderText = "Search product, code, SKU, category, or variation ID..."
            };
            searchBox.TextChanged += (s, e) => BindProductsGrid();

            refreshButton = new Button
            {
                Text = "Refresh",
                Location = new Point(480, 13),
                Size = new Size(90, 32),
                BackColor = Color.RoyalBlue,
                ForeColor = Color.White,
                Font = new Font("Arial", 9, FontStyle.Bold),
                UseVisualStyleBackColor = false
            };
            refreshButton.Click += (s, e) => LoadData();

            closeButton = new Button
            {
                Text = "Close",
                Location = new Point(585, 13),
                Size = new Size(90, 32),
                BackColor = Color.DimGray,
                ForeColor = Color.White,
                Font = new Font("Arial", 9, FontStyle.Bold),
                UseVisualStyleBackColor = false
            };
            closeButton.Click += (s, e) => Close();

            summaryLabel = new Label
            {
                Location = new Point(20, 55),
                Size = new Size(900, 24),
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.DarkBlue
            };

            var productsLabel = new Label
            {
                Text = "Products",
                Location = new Point(20, 88),
                Size = new Size(200, 24),
                Font = new Font("Arial", 11, FontStyle.Bold),
                ForeColor = Color.DarkGreen
            };

            productsGrid = new DataGridView
            {
                Location = new Point(20, 115),
                Size = new Size(1340, 280),
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                RowHeadersVisible = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                BackgroundColor = Color.White,
                BorderStyle = BorderStyle.Fixed3D,
                MultiSelect = false
            };
            productsGrid.Columns.Add("ProductName", "Product Name");
            productsGrid.Columns.Add("Category", "Category");
            productsGrid.Columns.Add("VariantCount", "Total Variants");
            productsGrid.Columns.Add("SyncedCount", "With Variation ID");
            productsGrid.Columns.Add("MissingCount", "Missing Variation ID");
            productsGrid.Columns.Add("Codes", "Item Codes");
            productsGrid.CellClick += (s, e) => ShowSelectedProductVariants();

            detailLabel = new Label
            {
                Text = "Variants",
                Location = new Point(20, 410),
                Size = new Size(900, 24),
                Font = new Font("Arial", 11, FontStyle.Bold),
                ForeColor = Color.DarkGreen
            };

            variantsGrid = new DataGridView
            {
                Location = new Point(20, 438),
                Size = new Size(1340, 320),
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                RowHeadersVisible = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                BackgroundColor = Color.White,
                BorderStyle = BorderStyle.Fixed3D,
                MultiSelect = false
            };
            variantsGrid.Columns.Add("Code", "Code");
            variantsGrid.Columns.Add("Name", "Name");
            variantsGrid.Columns.Add("Description", "Description");
            variantsGrid.Columns.Add("SKU", "SKU");
            variantsGrid.Columns.Add("CategoryCode", "Category");
            variantsGrid.Columns.Add("VariationId", "Variation ID");
            variantsGrid.Columns.Add("Price", "Price");
            variantsGrid.Columns.Add("Stock", "Stock");
            variantsGrid.Columns.Add("Active", "Active");
            variantsGrid.Columns["Price"].DefaultCellStyle.Format = "N2";

            Controls.Add(searchLabel);
            Controls.Add(searchBox);
            Controls.Add(refreshButton);
            Controls.Add(closeButton);
            Controls.Add(summaryLabel);
            Controls.Add(productsLabel);
            Controls.Add(productsGrid);
            Controls.Add(detailLabel);
            Controls.Add(variantsGrid);

            Load += (s, e) => LoadData();
        }

        private void LoadData()
        {
            allVariantRows.Clear();

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();

                bool hasVariantTable;
                using (var variantTableCmd = new SqlCommand(@"
                    SELECT COUNT(*)
                    FROM INFORMATION_SCHEMA.TABLES
                    WHERE TABLE_NAME = 'Variant'", conn))
                {
                    hasVariantTable = Convert.ToInt32(variantTableCmd.ExecuteScalar()) > 0;
                }

                bool hasVariationId;
                using (var schemaCmd = new SqlCommand(@"
                    SELECT COUNT(*)
                    FROM INFORMATION_SCHEMA.COLUMNS
                    WHERE TABLE_NAME = 'Items' AND COLUMN_NAME = 'VariationId'", conn))
                {
                    hasVariationId = Convert.ToInt32(schemaCmd.ExecuteScalar()) > 0;
                }

                var sql = hasVariantTable
                    ? @"
                    SELECT
                        ISNULL(v.MainItemCode, '') AS MainItemCode,
                        ISNULL(NULLIF(mainItem.Name, ''), ISNULL(NULLIF(mainItem.Description, ''), ISNULL(v.MainItemCode, ''))) AS MainItemName,
                        ISNULL(NULLIF(v.ItemCode, ''), ISNULL(v.MainItemCode, '')) AS ItemCode,
                        ISNULL(NULLIF(v.VariantName, ''), ISNULL(NULLIF(variantItem.Name, ''), ISNULL(NULLIF(variantItem.Description, ''), ''))) AS VariantName,
                        ISNULL(variantItem.Description, '') AS ItemDescription,
                        ISNULL(NULLIF(v.SKU, ''), ISNULL(variantItem.SKU, '')) AS SKU,
                        ISNULL(NULLIF(v.CategoryCode, ''), ISNULL(NULLIF(variantItem.CategoryCode, ''), ISNULL(mainItem.CategoryCode, ''))) AS CategoryCode,
                        ISNULL(v.VariationId, '') AS VariationId,
                        ISNULL(v.Price, ISNULL(variantItem.Price, 0)) AS Price,
                        ISNULL(variantItem.QuantityInStock, 0) AS QuantityInStock,
                        ISNULL(variantItem.IsActive, 1) AS IsActive
                    FROM dbo.[Variant] v
                    LEFT JOIN Items mainItem ON mainItem.Code = v.MainItemCode
                    LEFT JOIN Items variantItem ON variantItem.Code = ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)
                    ORDER BY MainItemName, ItemCode, VariationId"
                    : @"
                    SELECT
                        ISNULL(Code, '') AS MainItemCode,
                        ISNULL(NULLIF(Name, ''), ISNULL(NULLIF(Description, ''), ISNULL(Code, ''))) AS MainItemName,
                        ISNULL(Code, '') AS ItemCode,
                        ISNULL(NULLIF(Name, ''), ISNULL(NULLIF(Description, ''), ISNULL(Code, ''))) AS VariantName,
                        ISNULL(Description, '') AS ItemDescription,
                        ISNULL(SKU, '') AS SKU,
                        ISNULL(CategoryCode, '') AS CategoryCode,
                        " + (hasVariationId ? "ISNULL(VariationId, '')" : "''") + @" AS VariationId,
                        ISNULL(Price, 0) AS Price,
                        ISNULL(QuantityInStock, 0) AS QuantityInStock,
                        ISNULL(IsActive, 1) AS IsActive
                    FROM Items
                    ORDER BY MainItemName, ItemCode";

                using var cmd = new SqlCommand(sql, conn);
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    var row = new VariantItemRow
                    {
                        MainItemCode = reader["MainItemCode"]?.ToString() ?? string.Empty,
                        MainItemName = reader["MainItemName"]?.ToString() ?? string.Empty,
                        ItemCode = reader["ItemCode"]?.ToString() ?? string.Empty,
                        Name = reader["VariantName"]?.ToString() ?? string.Empty,
                        Description = reader["ItemDescription"]?.ToString() ?? string.Empty,
                        SKU = reader["SKU"]?.ToString() ?? string.Empty,
                        CategoryCode = reader["CategoryCode"]?.ToString() ?? string.Empty,
                        VariationId = reader["VariationId"]?.ToString() ?? string.Empty,
                        Price = reader["Price"] != DBNull.Value ? Convert.ToDecimal(reader["Price"]) : 0m,
                        Stock = reader["QuantityInStock"] != DBNull.Value ? Convert.ToInt32(reader["QuantityInStock"]) : 0,
                        IsActive = reader["IsActive"] != DBNull.Value && Convert.ToBoolean(reader["IsActive"]),
                    };

                    allVariantRows.Add(row);
                }

                selectedMainItemCode = null;
                BindProductsGrid();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to load product variants: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BindProductsGrid()
        {
            productsGrid.Rows.Clear();
            variantsGrid.Rows.Clear();

            string filter = (searchBox.Text ?? string.Empty).Trim();
            IEnumerable<VariantItemRow> filteredRows = allVariantRows;

            if (!string.IsNullOrWhiteSpace(filter))
            {
                filteredRows = filteredRows.Where(r =>
                    ContainsText(r.MainItemName, filter) ||
                    ContainsText(r.MainItemCode, filter) ||
                    ContainsText(r.ItemCode, filter) ||
                    ContainsText(r.SKU, filter) ||
                    ContainsText(r.CategoryCode, filter) ||
                    ContainsText(r.VariationId, filter) ||
                    ContainsText(r.Description, filter) ||
                    ContainsText(r.Name, filter));
            }

            var groupedProducts = filteredRows
                .GroupBy(r => r.MainItemCode, StringComparer.OrdinalIgnoreCase)
                .OrderBy(g => g.Select(x => x.MainItemName).FirstOrDefault())
                .Select(g => new
                {
                    MainItemCode = g.Key,
                    ProductName = g.Select(x => x.MainItemName).FirstOrDefault() ?? g.Key,
                    Category = string.Join(", ", g.Select(x => x.CategoryCode).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct().OrderBy(x => x)),
                    VariantCount = g.Count(),
                    SyncedCount = g.Count(x => !string.IsNullOrWhiteSpace(x.VariationId)),
                    MissingCount = g.Count(x => string.IsNullOrWhiteSpace(x.VariationId)),
                    Codes = string.Join(", ", g.Select(x => x.ItemCode).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct().OrderBy(x => x))
                })
                .ToList();

            foreach (var product in groupedProducts)
            {
                int rowIndex = productsGrid.Rows.Add(
                    product.ProductName,
                    product.Category,
                    product.VariantCount,
                    product.SyncedCount,
                    product.MissingCount,
                    product.Codes);
                productsGrid.Rows[rowIndex].Tag = product.MainItemCode;

                if (product.MissingCount > 0)
                {
                    productsGrid.Rows[rowIndex].DefaultCellStyle.BackColor = Color.MistyRose;
                    productsGrid.Rows[rowIndex].DefaultCellStyle.ForeColor = Color.DarkRed;
                }
            }

            int totalVariants = filteredRows.Count();
            int totalProducts = groupedProducts.Count;
            int syncedVariants = filteredRows.Count(x => !string.IsNullOrWhiteSpace(x.VariationId));
            summaryLabel.Text = $"Products: {totalProducts} | Variant rows: {totalVariants} | With Variation ID: {syncedVariants} | Missing Variation ID: {totalVariants - syncedVariants}";

            if (productsGrid.Rows.Count > 0)
            {
                int selectedIndex = 0;
                if (!string.IsNullOrWhiteSpace(selectedMainItemCode))
                {
                    for (int i = 0; i < productsGrid.Rows.Count; i++)
                    {
                        if (string.Equals(productsGrid.Rows[i].Tag?.ToString(), selectedMainItemCode, StringComparison.OrdinalIgnoreCase))
                        {
                            selectedIndex = i;
                            break;
                        }
                    }
                }

                productsGrid.Rows[selectedIndex].Selected = true;
                ShowSelectedProductVariants();
            }
            else
            {
                detailLabel.Text = "Variants";
            }
        }

        private void ShowSelectedProductVariants()
        {
            variantsGrid.Rows.Clear();

            if (productsGrid.SelectedRows.Count == 0)
            {
                detailLabel.Text = "Variants";
                return;
            }

            selectedMainItemCode = productsGrid.SelectedRows[0].Tag?.ToString() ?? string.Empty;
            var selectedProductName = productsGrid.SelectedRows[0].Cells["ProductName"].Value?.ToString() ?? string.Empty;
            detailLabel.Text = $"Variants for: {selectedProductName}";

            var rows = allVariantRows
                .Where(r => string.Equals(r.MainItemCode, selectedMainItemCode, StringComparison.OrdinalIgnoreCase))
                .OrderBy(r => r.ItemCode)
                .ToList();

            foreach (var row in rows)
            {
                int rowIndex = variantsGrid.Rows.Add(
                    row.ItemCode,
                    row.Name,
                    row.Description,
                    row.SKU,
                    row.CategoryCode,
                    row.VariationId,
                    row.Price,
                    row.Stock,
                    row.IsActive ? "Active" : "Inactive");

                if (string.IsNullOrWhiteSpace(row.VariationId))
                {
                    variantsGrid.Rows[rowIndex].DefaultCellStyle.BackColor = Color.LemonChiffon;
                    variantsGrid.Rows[rowIndex].DefaultCellStyle.ForeColor = Color.DarkGoldenrod;
                }
            }
        }

        private static bool ContainsText(string source, string value)
        {
            return source?.IndexOf(value, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private sealed class VariantItemRow
        {
            public string MainItemCode { get; set; } = string.Empty;
            public string MainItemName { get; set; } = string.Empty;
            public string ItemCode { get; set; } = string.Empty;
            public string Name { get; set; } = string.Empty;
            public string Description { get; set; } = string.Empty;
            public string SKU { get; set; } = string.Empty;
            public string CategoryCode { get; set; } = string.Empty;
            public string VariationId { get; set; } = string.Empty;
            public decimal Price { get; set; }
            public int Stock { get; set; }
            public bool IsActive { get; set; }
        }
    }
}
