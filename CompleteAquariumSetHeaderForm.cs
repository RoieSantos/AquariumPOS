using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;
using OfficeOpenXml;

namespace AquariumPOS
{
    public class CompleteAquariumSetHeaderForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView grid = null!;
        private Button btnAdd = null!;
        private Button btnEdit = null!;
        private Button btnDelete = null!;
        private Button btnLines = null!;
        private Button btnSync = null!;
        private Button btnExport = null!;
        private Button btnImport = null!;
        private Button btnRefresh = null!;
        private Button btnClose = null!;

        public CompleteAquariumSetHeaderForm()
        {
            Text = "Complete Aquarium Set Header";
            Size = new Size(850, 560);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            InitializeComponent();
            EnsureTables();
            LoadData();
        }

        private void InitializeComponent()
        {
            grid = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                RowHeadersVisible = false,
                BackgroundColor = Color.White
            };
            grid.DoubleClick += (s, e) => OpenSelectedLines();

            btnAdd = CreateButton("Add", Color.Green, BtnAdd_Click);
            btnEdit = CreateButton("Edit", Color.DarkOrange, BtnEdit_Click);
            btnDelete = CreateButton("Delete", Color.Firebrick, BtnDelete_Click);
            btnLines = CreateButton("Lines", Color.SteelBlue, (s, e) => OpenSelectedLines());
            btnSync = CreateButton("Sync", Color.MediumSlateBlue, BtnSync_Click);
            btnExport = CreateButton("Export", Color.SeaGreen, BtnExport_Click);
            btnImport = CreateButton("Import", Color.Teal, BtnImport_Click);
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
            buttonPanel.Controls.AddRange(new Control[] { btnAdd, btnEdit, btnDelete, btnLines, btnSync, btnExport, btnImport, btnRefresh, btnClose });

            Controls.Add(grid);
            Controls.Add(buttonPanel);
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

        private void LoadData()
        {
            try
            {
                using var connection = new SqlConnection(connectionString);
                using var adapter = new SqlDataAdapter(@"
SELECT PackageName, PackagePrice, ISNULL(VariantID, '') AS VariantID
FROM dbo.CompleteAquariumSetHeader
ORDER BY PackageName", connection);

                var table = new DataTable();
                adapter.Fill(table);
                grid.DataSource = table;

                if (grid.Columns.Contains("PackageName"))
                {
                    grid.Columns["PackageName"].HeaderText = "Package Name";
                    grid.Columns["PackageName"].FillWeight = 65;
                }

                if (grid.Columns.Contains("PackagePrice"))
                {
                    grid.Columns["PackagePrice"].HeaderText = "Package Price";
                    grid.Columns["PackagePrice"].FillWeight = 25;
                    grid.Columns["PackagePrice"].DefaultCellStyle.Format = "N2";
                    grid.Columns["PackagePrice"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                }

                if (grid.Columns.Contains("VariantID"))
                {
                    grid.Columns["VariantID"].HeaderText = "Variant ID";
                    grid.Columns["VariantID"].FillWeight = 30;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load aquarium set headers: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private string GetSelectedPackageName()
        {
            if (grid.CurrentRow?.DataBoundItem is DataRowView view)
            {
                return view.Row["PackageName"]?.ToString()?.Trim() ?? string.Empty;
            }

            if (grid.SelectedRows.Count > 0)
            {
                return grid.SelectedRows[0].Cells["PackageName"].Value?.ToString()?.Trim() ?? string.Empty;
            }

            return string.Empty;
        }

        private decimal GetSelectedPackagePrice()
        {
            if (grid.CurrentRow?.DataBoundItem is DataRowView view && view.Row["PackagePrice"] != DBNull.Value)
            {
                return Convert.ToDecimal(view.Row["PackagePrice"]);
            }

            if (grid.SelectedRows.Count > 0 && grid.SelectedRows[0].Cells["PackagePrice"].Value != null)
            {
                decimal.TryParse(grid.SelectedRows[0].Cells["PackagePrice"].Value.ToString(), out var price);
                return price;
            }

            return 0m;
        }

        private void BtnAdd_Click(object? sender, EventArgs e)
        {
            using var dialog = new CompleteAquariumSetHeaderEditDialog();
            if (dialog.ShowDialog(this) != DialogResult.OK)
            {
                return;
            }

            try
            {
                using var connection = new SqlConnection(connectionString);
                connection.Open();

                using var checkCommand = new SqlCommand("SELECT COUNT(1) FROM dbo.CompleteAquariumSetHeader WHERE PackageName = @PackageName", connection);
                checkCommand.Parameters.AddWithValue("@PackageName", dialog.PackageName);
                var exists = Convert.ToInt32(checkCommand.ExecuteScalar() ?? 0) > 0;
                if (exists)
                {
                    MessageBox.Show(this, "Package name already exists.", "Duplicate", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                using var insertCommand = new SqlCommand(@"
INSERT INTO dbo.CompleteAquariumSetHeader (PackageName, PackagePrice)
VALUES (@PackageName, @PackagePrice)", connection);
                insertCommand.Parameters.AddWithValue("@PackageName", dialog.PackageName);
                insertCommand.Parameters.AddWithValue("@PackagePrice", dialog.PackagePrice);
                insertCommand.ExecuteNonQuery();

                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to add package header: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnEdit_Click(object? sender, EventArgs e)
        {
            var originalPackageName = GetSelectedPackageName();
            if (string.IsNullOrWhiteSpace(originalPackageName))
            {
                MessageBox.Show(this, "Please select a package to edit.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            using var dialog = new CompleteAquariumSetHeaderEditDialog(originalPackageName, GetSelectedPackagePrice());
            if (dialog.ShowDialog(this) != DialogResult.OK)
            {
                return;
            }

            try
            {
                using var connection = new SqlConnection(connectionString);
                connection.Open();
                using var transaction = connection.BeginTransaction();

                if (!string.Equals(originalPackageName, dialog.PackageName, StringComparison.OrdinalIgnoreCase))
                {
                    using var duplicateCheck = new SqlCommand("SELECT COUNT(1) FROM dbo.CompleteAquariumSetHeader WHERE PackageName = @PackageName", connection, transaction);
                    duplicateCheck.Parameters.AddWithValue("@PackageName", dialog.PackageName);
                    var exists = Convert.ToInt32(duplicateCheck.ExecuteScalar() ?? 0) > 0;
                    if (exists)
                    {
                        transaction.Rollback();
                        MessageBox.Show(this, "The new package name already exists.", "Duplicate", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }

                    using var insertNewHeader = new SqlCommand(@"
INSERT INTO dbo.CompleteAquariumSetHeader (PackageName, PackagePrice)
VALUES (@NewPackageName, @PackagePrice)", connection, transaction);
                    insertNewHeader.Parameters.AddWithValue("@NewPackageName", dialog.PackageName);
                    insertNewHeader.Parameters.AddWithValue("@PackagePrice", dialog.PackagePrice);
                    insertNewHeader.ExecuteNonQuery();

                    using var updateLines = new SqlCommand(@"
UPDATE dbo.CompleteAquariumSetLine
SET PackageName = @NewPackageName
WHERE PackageName = @OldPackageName", connection, transaction);
                    updateLines.Parameters.AddWithValue("@NewPackageName", dialog.PackageName);
                    updateLines.Parameters.AddWithValue("@OldPackageName", originalPackageName);
                    updateLines.ExecuteNonQuery();

                    using var deleteOldHeader = new SqlCommand(@"
DELETE FROM dbo.CompleteAquariumSetHeader
WHERE PackageName = @OldPackageName", connection, transaction);
                    deleteOldHeader.Parameters.AddWithValue("@OldPackageName", originalPackageName);
                    deleteOldHeader.ExecuteNonQuery();
                }
                else
                {
                    using var updateHeader = new SqlCommand(@"
UPDATE dbo.CompleteAquariumSetHeader
SET PackagePrice = @PackagePrice,
    UpdatedDate = GETDATE()
WHERE PackageName = @PackageName", connection, transaction);
                    updateHeader.Parameters.AddWithValue("@PackageName", dialog.PackageName);
                    updateHeader.Parameters.AddWithValue("@PackagePrice", dialog.PackagePrice);
                    updateHeader.ExecuteNonQuery();
                }

                transaction.Commit();
                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to update package header: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnDelete_Click(object? sender, EventArgs e)
        {
            var packageName = GetSelectedPackageName();
            if (string.IsNullOrWhiteSpace(packageName))
            {
                MessageBox.Show(this, "Please select a package to delete.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var confirm = MessageBox.Show(this,
                $"Delete package '{packageName}' and all included lines?",
                "Confirm Delete",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes)
            {
                return;
            }

            try
            {
                using var connection = new SqlConnection(connectionString);
                connection.Open();

                using var deleteCommand = new SqlCommand(@"
DELETE FROM dbo.CompleteAquariumSetHeader
WHERE PackageName = @PackageName", connection);
                deleteCommand.Parameters.AddWithValue("@PackageName", packageName);
                deleteCommand.ExecuteNonQuery();

                LoadData();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to delete package header: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async void BtnSync_Click(object? sender, EventArgs e)
        {
            try
            {
                SetSyncState(false);
                Cursor? previousCursor = Cursor.Current;
                Cursor.Current = Cursors.WaitCursor;
                try
                {
                    EnsureTables();

                    int syncedProducts = await OnlinefunctionsEvents.SyncUpProductsAsync(TimeSpan.FromSeconds(90)).ConfigureAwait(true);
                    try
                    {
                        await OnlinefunctionsEvents.SyncProductVariationsAsync(TimeSpan.FromSeconds(90)).ConfigureAwait(true);
                    }
                    catch
                    {
                        // Best effort: SET header sync can still proceed from Items even if variant sync fails.
                    }

                    int importedPackages = SyncSetPackagesFromItems();
                    LoadData();

                    MessageBox.Show(this,
                        $"Cloud sync completed.\n\nProducts synced: {syncedProducts:N0}\nSET packages imported/updated: {importedPackages:N0}",
                        "Sync Complete",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }
                finally
                {
                    Cursor.Current = previousCursor ?? Cursors.Default;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to sync SET packages: {ex.Message}", "Sync Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                SetSyncState(true);
            }
        }

        private void SetSyncState(bool enabled)
        {
            try { if (btnAdd != null) btnAdd.Enabled = enabled; } catch { }
            try { if (btnEdit != null) btnEdit.Enabled = enabled; } catch { }
            try { if (btnDelete != null) btnDelete.Enabled = enabled; } catch { }
            try { if (btnLines != null) btnLines.Enabled = enabled; } catch { }
            try { if (btnSync != null) btnSync.Enabled = enabled; } catch { }
            try { if (btnExport != null) btnExport.Enabled = enabled; } catch { }
            try { if (btnImport != null) btnImport.Enabled = enabled; } catch { }
            try { if (btnRefresh != null) btnRefresh.Enabled = enabled; } catch { }
            try { if (btnClose != null) btnClose.Enabled = enabled; } catch { }
        }

        private void BtnExport_Click(object? sender, EventArgs e)
        {
            try
            {
                EnsureTables();

                var headers = new DataTable();
                var lines = new DataTable();

                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    using (var headerAdapter = new SqlDataAdapter(@"
SELECT PackageName, PackagePrice, ISNULL(VariantID, '') AS VariantID
FROM dbo.CompleteAquariumSetHeader
ORDER BY PackageName", connection))
                    {
                        headerAdapter.Fill(headers);
                    }

                    using (var lineAdapter = new SqlDataAdapter(@"
SELECT PackageName, ItemNo, ItemName, Quantity, Price
FROM dbo.CompleteAquariumSetLine
ORDER BY PackageName, EntryNo", connection))
                    {
                        lineAdapter.Fill(lines);
                    }
                }

                if (headers.Rows.Count == 0 && lines.Rows.Count == 0)
                {
                    MessageBox.Show(this, "No complete aquarium set setup was found to export.", "Complete Aquarium Set", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                using var saveDialog = new SaveFileDialog
                {
                    Title = "Export Complete Aquarium Set Setup",
                    Filter = "Excel Workbook (*.xlsx)|*.xlsx",
                    FileName = $"CompleteAquariumSetSetup_{DateTime.Now:yyyyMMdd_HHmmss}.xlsx"
                };

                if (saveDialog.ShowDialog(this) != DialogResult.OK || string.IsNullOrWhiteSpace(saveDialog.FileName))
                {
                    return;
                }

                ExcelPackage.LicenseContext = LicenseContext.NonCommercial;
                using var package = new ExcelPackage();

                var headerSheet = package.Workbook.Worksheets.Add("Headers");
                headerSheet.Cells[1, 1].LoadFromDataTable(headers, true);
                if (headerSheet.Dimension != null)
                {
                    headerSheet.Cells[headerSheet.Dimension.Address].AutoFitColumns();
                    headerSheet.Cells[1, 1, 1, headers.Columns.Count].Style.Font.Bold = true;
                }

                var lineSheet = package.Workbook.Worksheets.Add("Lines");
                lineSheet.Cells[1, 1].LoadFromDataTable(lines, true);
                if (lineSheet.Dimension != null)
                {
                    lineSheet.Cells[lineSheet.Dimension.Address].AutoFitColumns();
                    lineSheet.Cells[1, 1, 1, lines.Columns.Count].Style.Font.Bold = true;
                }

                package.SaveAs(new System.IO.FileInfo(saveDialog.FileName));

                MessageBox.Show(this,
                    $"Complete aquarium set setup exported successfully.\n\nFile saved: {saveDialog.FileName}\n\nSheets included:\n- Headers\n- Lines",
                    "Export Successful",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to export complete aquarium set setup: {ex.Message}", "Export Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnImport_Click(object? sender, EventArgs e)
        {
            try
            {
                EnsureTables();

                using var openDialog = new OpenFileDialog
                {
                    Title = "Import Complete Aquarium Set Setup",
                    Filter = "Excel Workbook (*.xlsx)|*.xlsx"
                };

                if (openDialog.ShowDialog(this) != DialogResult.OK || string.IsNullOrWhiteSpace(openDialog.FileName))
                {
                    return;
                }

                var confirm = MessageBox.Show(this,
                    "This will replace the existing Complete Aquarium Set headers and lines in this database with the contents of the selected Excel file.\n\nDo you want to continue?",
                    "Confirm Import",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (confirm != DialogResult.Yes)
                {
                    return;
                }

                ExcelPackage.LicenseContext = LicenseContext.NonCommercial;
                using var package = new ExcelPackage(new System.IO.FileInfo(openDialog.FileName));

                var headerSheet = package.Workbook.Worksheets["Headers"];
                var lineSheet = package.Workbook.Worksheets["Lines"];

                if (headerSheet == null || headerSheet.Dimension == null)
                {
                    MessageBox.Show(this, "The workbook is missing the 'Headers' sheet or it is empty.", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                if (lineSheet == null || lineSheet.Dimension == null)
                {
                    MessageBox.Show(this, "The workbook is missing the 'Lines' sheet or it is empty.", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                string header1 = headerSheet.Cells[1, 1].Text?.Trim() ?? string.Empty;
                string header2 = headerSheet.Cells[1, 2].Text?.Trim() ?? string.Empty;
                string header3 = headerSheet.Cells[1, 3].Text?.Trim() ?? string.Empty;
                if (!string.Equals(header1, "PackageName", StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(header2, "PackagePrice", StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(header3, "VariantID", StringComparison.OrdinalIgnoreCase))
                {
                    MessageBox.Show(this, "Invalid Headers sheet format. Expected columns: PackageName, PackagePrice, VariantID.", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                string line1 = lineSheet.Cells[1, 1].Text?.Trim() ?? string.Empty;
                string line2 = lineSheet.Cells[1, 2].Text?.Trim() ?? string.Empty;
                string line3 = lineSheet.Cells[1, 3].Text?.Trim() ?? string.Empty;
                string line4 = lineSheet.Cells[1, 4].Text?.Trim() ?? string.Empty;
                string line5 = lineSheet.Cells[1, 5].Text?.Trim() ?? string.Empty;
                if (!string.Equals(line1, "PackageName", StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(line2, "ItemNo", StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(line3, "ItemName", StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(line4, "Quantity", StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(line5, "Price", StringComparison.OrdinalIgnoreCase))
                {
                    MessageBox.Show(this, "Invalid Lines sheet format. Expected columns: PackageName, ItemNo, ItemName, Quantity, Price.", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                using var connection = new SqlConnection(connectionString);
                connection.Open();
                using var transaction = connection.BeginTransaction();

                using (var deleteLines = new SqlCommand("DELETE FROM dbo.CompleteAquariumSetLine", connection, transaction))
                {
                    deleteLines.ExecuteNonQuery();
                }

                using (var deleteHeaders = new SqlCommand("DELETE FROM dbo.CompleteAquariumSetHeader", connection, transaction))
                {
                    deleteHeaders.ExecuteNonQuery();
                }

                int importedHeaders = 0;
                for (int row = 2; row <= headerSheet.Dimension.End.Row; row++)
                {
                    string packageName = headerSheet.Cells[row, 1].Text?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(packageName))
                    {
                        continue;
                    }

                    decimal packagePrice = 0m;
                    decimal.TryParse(headerSheet.Cells[row, 2].Text?.Trim() ?? string.Empty, out packagePrice);
                    string variantId = headerSheet.Cells[row, 3].Text?.Trim() ?? string.Empty;

                    using var insertHeader = new SqlCommand(@"
INSERT INTO dbo.CompleteAquariumSetHeader (PackageName, PackagePrice, VariantID)
VALUES (@PackageName, @PackagePrice, NULLIF(@VariantID, ''))", connection, transaction);
                    insertHeader.Parameters.AddWithValue("@PackageName", packageName);
                    insertHeader.Parameters.AddWithValue("@PackagePrice", packagePrice);
                    insertHeader.Parameters.AddWithValue("@VariantID", variantId);
                    insertHeader.ExecuteNonQuery();
                    importedHeaders++;
                }

                int importedLines = 0;
                for (int row = 2; row <= lineSheet.Dimension.End.Row; row++)
                {
                    string packageName = lineSheet.Cells[row, 1].Text?.Trim() ?? string.Empty;
                    string itemNo = lineSheet.Cells[row, 2].Text?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(packageName) || string.IsNullOrWhiteSpace(itemNo))
                    {
                        continue;
                    }

                    string itemName = lineSheet.Cells[row, 3].Text?.Trim() ?? string.Empty;
                    decimal quantity = 0m;
                    decimal.TryParse(lineSheet.Cells[row, 4].Text?.Trim() ?? string.Empty, out quantity);
                    decimal price = 0m;
                    decimal.TryParse(lineSheet.Cells[row, 5].Text?.Trim() ?? string.Empty, out price);

                    using var insertLine = new SqlCommand(@"
INSERT INTO dbo.CompleteAquariumSetLine (PackageName, ItemNo, ItemName, Quantity, Price)
VALUES (@PackageName, @ItemNo, @ItemName, @Quantity, @Price)", connection, transaction);
                    insertLine.Parameters.AddWithValue("@PackageName", packageName);
                    insertLine.Parameters.AddWithValue("@ItemNo", itemNo);
                    insertLine.Parameters.AddWithValue("@ItemName", string.IsNullOrWhiteSpace(itemName) ? (object)DBNull.Value : itemName);
                    insertLine.Parameters.AddWithValue("@Quantity", quantity);
                    insertLine.Parameters.AddWithValue("@Price", price);
                    insertLine.ExecuteNonQuery();
                    importedLines++;
                }

                transaction.Commit();
                LoadData();

                MessageBox.Show(this,
                    $"Complete aquarium set setup imported successfully.\n\nHeaders imported: {importedHeaders:N0}\nLines imported: {importedLines:N0}",
                    "Import Successful",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to import complete aquarium set setup: {ex.Message}", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private int SyncSetPackagesFromItems()
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var transaction = connection.BeginTransaction();

            var sourceRows = new DataTable();
            using (var selectCommand = new SqlCommand(@"
SELECT
    LTRIM(RTRIM(ISNULL(NULLIF([Name], ''), ISNULL([Description], '')))) AS PackageName,
        ISNULL([Price], 0) AS PackagePrice,
        LTRIM(RTRIM(ISNULL([VariationId], ''))) AS VariantID
FROM dbo.Items
WHERE UPPER(LTRIM(RTRIM(ISNULL(CategoryCode, '')))) = 'SET'
  AND LTRIM(RTRIM(ISNULL(NULLIF([Name], ''), ISNULL([Description], '')))) <> ''
ORDER BY LTRIM(RTRIM(ISNULL(NULLIF([Name], ''), ISNULL([Description], ''))))", connection, transaction))
            using (var adapter = new SqlDataAdapter(selectCommand))
            {
                adapter.Fill(sourceRows);
            }

            int importedCount = 0;
            foreach (DataRow row in sourceRows.Rows)
            {
                string packageName = row["PackageName"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(packageName))
                {
                    continue;
                }

                decimal packagePrice = row["PackagePrice"] != DBNull.Value ? Convert.ToDecimal(row["PackagePrice"]) : 0m;
                string variantId = row["VariantID"]?.ToString()?.Trim() ?? string.Empty;

                using var mergeCommand = new SqlCommand(@"
MERGE dbo.CompleteAquariumSetHeader AS target
USING (SELECT @PackageName AS PackageName, @PackagePrice AS PackagePrice, @VariantID AS VariantID) AS source
ON target.PackageName = source.PackageName
WHEN MATCHED THEN
    UPDATE SET PackagePrice = source.PackagePrice,
               VariantID = NULLIF(source.VariantID, ''),
               UpdatedDate = GETDATE()
WHEN NOT MATCHED THEN
    INSERT (PackageName, PackagePrice, VariantID)
    VALUES (source.PackageName, source.PackagePrice, NULLIF(source.VariantID, ''));", connection, transaction);
                mergeCommand.Parameters.AddWithValue("@PackageName", packageName);
                mergeCommand.Parameters.AddWithValue("@PackagePrice", packagePrice);
                mergeCommand.Parameters.AddWithValue("@VariantID", variantId);
                mergeCommand.ExecuteNonQuery();
                importedCount++;
            }

            transaction.Commit();
            return importedCount;
        }

        private void OpenSelectedLines()
        {
            var packageName = GetSelectedPackageName();
            if (string.IsNullOrWhiteSpace(packageName))
            {
                MessageBox.Show(this, "Please select a package first.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            using var form = new CompleteAquariumSetLineForm(packageName);
            form.ShowDialog(this);
        }
    }

    internal sealed class CompleteAquariumSetHeaderEditDialog : Form
    {
        private readonly TextBox txtPackageName;
        private readonly NumericUpDown nudPackagePrice;

        public string PackageName => txtPackageName.Text.Trim();
        public decimal PackagePrice => nudPackagePrice.Value;

        public CompleteAquariumSetHeaderEditDialog(string packageName = "", decimal packagePrice = 0m)
        {
            Text = string.IsNullOrWhiteSpace(packageName) ? "Add Aquarium Set Package" : "Edit Aquarium Set Package";
            Size = new Size(420, 220);
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;

            var lblPackageName = new Label
            {
                Text = "Package Name",
                Left = 20,
                Top = 22,
                Width = 120
            };

            txtPackageName = new TextBox
            {
                Left = 150,
                Top = 18,
                Width = 220,
                Text = packageName
            };

            var lblPackagePrice = new Label
            {
                Text = "Package Price",
                Left = 20,
                Top = 68,
                Width = 120
            };

            nudPackagePrice = new NumericUpDown
            {
                Left = 150,
                Top = 64,
                Width = 220,
                DecimalPlaces = 2,
                Maximum = 1000000,
                Minimum = 0,
                Value = packagePrice
            };

            var btnOk = new Button
            {
                Text = "OK",
                Left = 210,
                Top = 118,
                Width = 75,
                DialogResult = DialogResult.OK
            };
            btnOk.Click += BtnOk_Click;

            var btnCancel = new Button
            {
                Text = "Cancel",
                Left = 295,
                Top = 118,
                Width = 75,
                DialogResult = DialogResult.Cancel
            };

            Controls.AddRange(new Control[]
            {
                lblPackageName, txtPackageName,
                lblPackagePrice, nudPackagePrice,
                btnOk, btnCancel
            });

            AcceptButton = btnOk;
            CancelButton = btnCancel;
        }

        private void BtnOk_Click(object? sender, EventArgs e)
        {
            if (string.IsNullOrWhiteSpace(PackageName))
            {
                MessageBox.Show(this, "Package name is required.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                DialogResult = DialogResult.None;
            }
        }
    }
}
