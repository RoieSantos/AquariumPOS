using System;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;
using System.IO;
using System.Linq;
using OfficeOpenXml;
using OfficeOpenXml.Style;

namespace AquariumPOS
{
    public class ExpenseCategorySetupForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;

        private DataGridView dgvExpenseCategories = null!;
        private Button btnAdd = null!;
        private Button btnEdit = null!;
        private Button btnDelete = null!;
        private Button btnRefresh = null!;
        private Button btnExport = null!;
        private Button btnImport = null!;
        private Button btnClose = null!;
        private Button btnBack = null!;
        private Label lblCount = null!;

        public ExpenseCategorySetupForm()
        {
            KeyPreview = true;
            KeyDown += ExpenseCategorySetupForm_KeyDown;

            InitializeComponent();
            CreateExpenseCategorySetupTable();
            SetupUI();
            LoadExpenseCategories();
        }

        private void InitializeComponent()
        {
            Text = "Expense Category Setup";
            Size = new Size(800, 600);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
        }

        private void SetupUI()
        {
            dgvExpenseCategories = new DataGridView
            {
                Location = new Point(20, 20),
                Size = new Size(740, 400),
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                BackgroundColor = Color.White,
                BorderStyle = BorderStyle.Fixed3D,
                RowHeadersVisible = false,
                MultiSelect = false
            };

            dgvExpenseCategories.Columns.Add("Code", "Code");
            dgvExpenseCategories.Columns.Add("Description", "Description");
            dgvExpenseCategories.Columns.Add("InStoreItems", "In-Store-Items");
            dgvExpenseCategories.Columns["Code"].FillWeight = 25;
            dgvExpenseCategories.Columns["Description"].FillWeight = 50;
            dgvExpenseCategories.Columns["InStoreItems"].FillWeight = 25;

            lblCount = new Label
            {
                Text = "Total Expense Categories: 0",
                Location = new Point(20, 430),
                Size = new Size(260, 20),
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.DarkBlue
            };

            btnAdd = new Button
            {
                Text = "Add",
                Location = new Point(20, 460),
                Size = new Size(80, 35),
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnAdd.Click += BtnAdd_Click;

            btnEdit = new Button
            {
                Text = "Edit",
                Location = new Point(110, 460),
                Size = new Size(80, 35),
                BackColor = Color.Orange,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnEdit.Click += BtnEdit_Click;

            btnDelete = new Button
            {
                Text = "Delete",
                Location = new Point(200, 460),
                Size = new Size(80, 35),
                BackColor = Color.Red,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnDelete.Click += BtnDelete_Click;

            btnRefresh = new Button
            {
                Text = "Refresh",
                Location = new Point(290, 460),
                Size = new Size(80, 35),
                BackColor = Color.Blue,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnRefresh.Click += BtnRefresh_Click;

            btnExport = new Button
            {
                Text = "Export",
                Location = new Point(380, 460),
                Size = new Size(80, 35),
                BackColor = Color.SeaGreen,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnExport.Click += BtnExport_Click;

            btnImport = new Button
            {
                Text = "Import",
                Location = new Point(470, 460),
                Size = new Size(80, 35),
                BackColor = Color.Teal,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnImport.Click += BtnImport_Click;

            btnBack = new Button
            {
                Text = "Back",
                Location = new Point(590, 460),
                Size = new Size(80, 35),
                BackColor = Color.LightGray,
                ForeColor = Color.Black,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnBack.Click += BtnBack_Click;

            btnClose = new Button
            {
                Text = "Close",
                Location = new Point(680, 460),
                Size = new Size(80, 35),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            btnClose.Click += BtnClose_Click;

            Controls.AddRange(new Control[]
            {
                dgvExpenseCategories, lblCount, btnAdd, btnEdit, btnDelete, btnRefresh, btnExport, btnImport, btnBack, btnClose
            });
        }

        private void CreateExpenseCategorySetupTable()
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    var command = new SqlCommand(@"
                        IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ExpenseCategorySetup')
                        BEGIN
                            CREATE TABLE ExpenseCategorySetup (
                                Code NVARCHAR(20) PRIMARY KEY,
                                Description NVARCHAR(100) NOT NULL,
                                InStoreItems BIT NOT NULL DEFAULT 0,
                                CreatedDate DATETIME2 DEFAULT GETDATE(),
                                UpdatedDate DATETIME2 DEFAULT GETDATE()
                            )
                        END

                        IF COL_LENGTH('ExpenseCategorySetup', 'InStoreItems') IS NULL
                        BEGIN
                            ALTER TABLE ExpenseCategorySetup ADD InStoreItems BIT NOT NULL CONSTRAINT DF_ExpenseCategorySetup_InStoreItems DEFAULT 0;
                        END", connection);
                    command.ExecuteNonQuery();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error creating expense category setup table: {ex.Message}", "Database Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void LoadExpenseCategories()
        {
            try
            {
                dgvExpenseCategories.Rows.Clear();
                int count = 0;

                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    var command = new SqlCommand("SELECT Code, Description, ISNULL(InStoreItems, 0) AS InStoreItems FROM ExpenseCategorySetup ORDER BY Code", connection);
                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            string code = reader["Code"]?.ToString() ?? string.Empty;
                            string description = reader["Description"]?.ToString() ?? string.Empty;
                            bool inStoreItems = reader["InStoreItems"] != DBNull.Value && Convert.ToBoolean(reader["InStoreItems"]);
                            dgvExpenseCategories.Rows.Add(code, description, inStoreItems ? "Yes" : "No");
                            count++;
                        }
                    }
                }

                lblCount.Text = $"Total Expense Categories: {count}";
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading expense categories: {ex.Message}", "Database Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnAdd_Click(object? sender, EventArgs e)
        {
            ShowExpenseCategoryDialog();
        }

        private void BtnEdit_Click(object? sender, EventArgs e)
        {
            if (dgvExpenseCategories.SelectedRows.Count == 0)
            {
                MessageBox.Show("Please select an expense category to edit.", "No Selection",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var selectedRow = dgvExpenseCategories.SelectedRows[0];
            string code = selectedRow.Cells["Code"].Value?.ToString() ?? string.Empty;
            string description = selectedRow.Cells["Description"].Value?.ToString() ?? string.Empty;
            bool inStoreItems = string.Equals(selectedRow.Cells["InStoreItems"].Value?.ToString(), "Yes", StringComparison.OrdinalIgnoreCase);
            ShowExpenseCategoryDialog(code, description, inStoreItems);
        }

        private void BtnDelete_Click(object? sender, EventArgs e)
        {
            if (dgvExpenseCategories.SelectedRows.Count == 0)
            {
                MessageBox.Show("Please select an expense category to delete.", "No Selection",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var selectedRow = dgvExpenseCategories.SelectedRows[0];
            string code = selectedRow.Cells["Code"].Value?.ToString() ?? string.Empty;
            string description = selectedRow.Cells["Description"].Value?.ToString() ?? string.Empty;

            var result = MessageBox.Show($"Are you sure you want to delete expense category '{description}'?",
                "Confirm Delete", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (result != DialogResult.Yes)
            {
                return;
            }

            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    var command = new SqlCommand("DELETE FROM ExpenseCategorySetup WHERE Code = @code", connection);
                    command.Parameters.AddWithValue("@code", code);

                    int rowsAffected = command.ExecuteNonQuery();
                    if (rowsAffected > 0)
                    {
                        MessageBox.Show("Expense category deleted successfully!", "Success",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
                        LoadExpenseCategories();
                    }
                    else
                    {
                        MessageBox.Show("Failed to delete expense category.", "Error",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error deleting expense category: {ex.Message}", "Database Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnRefresh_Click(object? sender, EventArgs e)
        {
            LoadExpenseCategories();
        }

        private void BtnExport_Click(object? sender, EventArgs e)
        {
            ExportExpenseCategoriesToExcel();
        }

        private void BtnImport_Click(object? sender, EventArgs e)
        {
            ImportExpenseCategoriesFromExcel();
        }

        private void BtnClose_Click(object? sender, EventArgs e)
        {
            Close();
        }

        private void ExportExpenseCategoriesToExcel()
        {
            try
            {
                ExcelPackage.LicenseContext = LicenseContext.NonCommercial;

                using var saveDialog = new SaveFileDialog
                {
                    Filter = "Excel Files|*.xlsx",
                    Title = "Export Expense Categories",
                    FileName = $"ExpenseCategories_{DateTime.Now:yyyyMMdd_HHmmss}.xlsx"
                };

                if (saveDialog.ShowDialog(this) != DialogResult.OK)
                {
                    return;
                }

                using var package = new ExcelPackage();
                var worksheet = package.Workbook.Worksheets.Add("ExpenseCategories");
                string[] headers = { "Code", "Description", "InStoreItems" };

                for (int i = 0; i < headers.Length; i++)
                {
                    worksheet.Cells[1, i + 1].Value = headers[i];
                    worksheet.Cells[1, i + 1].Style.Font.Bold = true;
                    worksheet.Cells[1, i + 1].Style.Fill.PatternType = ExcelFillStyle.Solid;
                    worksheet.Cells[1, i + 1].Style.Fill.BackgroundColor.SetColor(Color.LightBlue);
                }

                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    using var command = new SqlCommand("SELECT Code, Description, ISNULL(InStoreItems, 0) AS InStoreItems FROM ExpenseCategorySetup ORDER BY Code", connection);
                    using var reader = command.ExecuteReader();

                    int row = 2;
                    while (reader.Read())
                    {
                        worksheet.Cells[row, 1].Value = reader["Code"]?.ToString() ?? string.Empty;
                        worksheet.Cells[row, 2].Value = reader["Description"]?.ToString() ?? string.Empty;
                        worksheet.Cells[row, 3].Value = reader["InStoreItems"] != DBNull.Value && Convert.ToBoolean(reader["InStoreItems"]);
                        row++;
                    }

                    if (row == 2)
                    {
                        worksheet.Cells[row, 1].Value = "GENEXP";
                        worksheet.Cells[row, 2].Value = "General Expense";
                        worksheet.Cells[row, 3].Value = false;
                    }
                }

                if (worksheet.Dimension != null)
                {
                    worksheet.Cells[worksheet.Dimension.Address].AutoFitColumns();
                }

                var inStoreValidation = worksheet.DataValidations.AddListValidation("C:C");
                inStoreValidation.Formula.Values.Add("TRUE");
                inStoreValidation.Formula.Values.Add("FALSE");

                package.SaveAs(new FileInfo(saveDialog.FileName));
                MessageBox.Show(this, $"Expense categories exported successfully.\nFile saved: {saveDialog.FileName}", "Export Successful", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to export expense categories: {ex.Message}", "Export Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ImportExpenseCategoriesFromExcel()
        {
            try
            {
                ExcelPackage.LicenseContext = LicenseContext.NonCommercial;

                using var openDialog = new OpenFileDialog
                {
                    Filter = "Excel Files|*.xlsx;*.xls",
                    Title = "Import Expense Categories"
                };

                if (openDialog.ShowDialog(this) != DialogResult.OK)
                {
                    return;
                }

                using var package = new ExcelPackage(new FileInfo(openDialog.FileName));
                var worksheet = package.Workbook.Worksheets.FirstOrDefault();
                if (worksheet == null)
                {
                    MessageBox.Show(this, "The selected Excel file does not contain any worksheets.", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                int rowCount = worksheet.Dimension?.Rows ?? 0;
                if (rowCount < 2)
                {
                    MessageBox.Show(this, "The Excel file appears to be empty or contains only headers.", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                string[] expectedHeaders = { "Code", "Description", "InStoreItems" };
                for (int i = 0; i < expectedHeaders.Length; i++)
                {
                    string actualHeader = worksheet.Cells[1, i + 1].Text?.Trim() ?? string.Empty;
                    if (!string.Equals(actualHeader, expectedHeaders[i], StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show(this, "Invalid expense category import template. Expected headers: Code, Description, InStoreItems.", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }

                var importResult = MessageBox.Show(this,
                    "Do you want to:\n\nYES = Update existing categories and add new ones\nNO = Only add new categories (skip existing)\nCANCEL = Cancel import",
                    "Import Options",
                    MessageBoxButtons.YesNoCancel,
                    MessageBoxIcon.Question);

                if (importResult == DialogResult.Cancel)
                {
                    return;
                }

                bool updateExisting = importResult == DialogResult.Yes;
                int successCount = 0;
                int skippedCount = 0;
                var errors = new System.Collections.Generic.List<string>();

                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    for (int row = 2; row <= rowCount; row++)
                    {
                        try
                        {
                            string code = worksheet.Cells[row, 1].Text?.Trim().ToUpperInvariant() ?? string.Empty;
                            string description = worksheet.Cells[row, 2].Text?.Trim() ?? string.Empty;
                            string inStoreText = worksheet.Cells[row, 3].Text?.Trim() ?? string.Empty;

                            if (string.IsNullOrWhiteSpace(code))
                            {
                                continue;
                            }

                            if (string.IsNullOrWhiteSpace(description))
                            {
                                throw new InvalidOperationException("Description is required.");
                            }

                            bool inStoreItems = TryParseExcelBoolean(inStoreText, out bool parsedValue) && parsedValue;

                            using var existsCmd = new SqlCommand("SELECT COUNT(*) FROM ExpenseCategorySetup WHERE Code = @code", connection);
                            existsCmd.Parameters.AddWithValue("@code", code);
                            int exists = Convert.ToInt32(existsCmd.ExecuteScalar() ?? 0);

                            if (exists > 0)
                            {
                                if (!updateExisting)
                                {
                                    skippedCount++;
                                    continue;
                                }

                                using var updateCmd = new SqlCommand(@"
UPDATE ExpenseCategorySetup
SET Description = @description,
    InStoreItems = @inStoreItems,
    UpdatedDate = GETDATE()
WHERE Code = @code", connection);
                                updateCmd.Parameters.AddWithValue("@code", code);
                                updateCmd.Parameters.AddWithValue("@description", description);
                                updateCmd.Parameters.AddWithValue("@inStoreItems", inStoreItems);
                                updateCmd.ExecuteNonQuery();
                            }
                            else
                            {
                                using var insertCmd = new SqlCommand(@"
INSERT INTO ExpenseCategorySetup (Code, Description, InStoreItems)
VALUES (@code, @description, @inStoreItems)", connection);
                                insertCmd.Parameters.AddWithValue("@code", code);
                                insertCmd.Parameters.AddWithValue("@description", description);
                                insertCmd.Parameters.AddWithValue("@inStoreItems", inStoreItems);
                                insertCmd.ExecuteNonQuery();
                            }

                            successCount++;
                        }
                        catch (Exception rowEx)
                        {
                            errors.Add($"Row {row}: {rowEx.Message}");
                        }
                    }
                }

                LoadExpenseCategories();

                string resultMessage = $"Import completed!\n\nSuccessful: {successCount} categories\nSkipped: {skippedCount} categories\nErrors: {errors.Count} categories";
                if (errors.Count > 0)
                {
                    resultMessage += "\n\nErrors:\n" + string.Join("\n", errors.Take(10));
                    if (errors.Count > 10)
                    {
                        resultMessage += "\n... and more";
                    }
                }

                MessageBox.Show(this, resultMessage, "Expense Category Import Results", MessageBoxButtons.OK, errors.Count == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to import expense categories: {ex.Message}", "Import Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static bool TryParseExcelBoolean(string? text, out bool value)
        {
            string normalized = (text ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(normalized))
            {
                value = false;
                return false;
            }

            if (bool.TryParse(normalized, out value))
            {
                return true;
            }

            if (string.Equals(normalized, "YES", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(normalized, "Y", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(normalized, "1", StringComparison.OrdinalIgnoreCase))
            {
                value = true;
                return true;
            }

            if (string.Equals(normalized, "NO", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(normalized, "N", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(normalized, "0", StringComparison.OrdinalIgnoreCase))
            {
                value = false;
                return true;
            }

            value = false;
            return false;
        }

        private void ShowExpenseCategoryDialog(string existingCode = "", string existingDescription = "", bool existingInStoreItems = false)
        {
            bool isEdit = !string.IsNullOrWhiteSpace(existingCode);

            var dialog = new Form
            {
                Text = isEdit ? "Edit Expense Category" : "Add Expense Category",
            Size = new Size(420, 280),
                StartPosition = FormStartPosition.CenterParent,
                BackColor = Color.White,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false
            };

            var lblCode = new Label
            {
                Text = "Code:",
                Location = new Point(20, 30),
                Size = new Size(80, 20),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var txtCode = new TextBox
            {
                Location = new Point(110, 28),
                Size = new Size(150, 25),
                Font = new Font("Arial", 10),
                Text = existingCode,
                MaxLength = 20,
                ReadOnly = isEdit
            };

            var lblDescription = new Label
            {
                Text = "Description:",
                Location = new Point(20, 70),
                Size = new Size(80, 20),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var txtDescription = new TextBox
            {
                Location = new Point(110, 68),
                Size = new Size(250, 25),
                Font = new Font("Arial", 10),
                Text = existingDescription,
                MaxLength = 100
            };

            var chkInStoreItems = new CheckBox
            {
                Text = "In-Store-Items",
                Location = new Point(110, 108),
                Size = new Size(180, 25),
                Font = new Font("Arial", 10, FontStyle.Bold),
                Checked = existingInStoreItems
            };

            var btnSave = new Button
            {
                Text = "Save",
                Location = new Point(200, 170),
                Size = new Size(80, 35),
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var btnCancel = new Button
            {
                Text = "Cancel",
                Location = new Point(290, 170),
                Size = new Size(80, 35),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            btnSave.Click += (s, args) =>
            {
                string code = txtCode.Text.Trim().ToUpperInvariant();
                string description = txtDescription.Text.Trim();
                bool inStoreItems = chkInStoreItems.Checked;

                if (string.IsNullOrWhiteSpace(code))
                {
                    MessageBox.Show("Please enter a code.", "Validation Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    txtCode.Focus();
                    return;
                }

                if (string.IsNullOrWhiteSpace(description))
                {
                    MessageBox.Show("Please enter a description.", "Validation Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    txtDescription.Focus();
                    return;
                }

                try
                {
                    using (var connection = new SqlConnection(connectionString))
                    {
                        connection.Open();
                        SqlCommand command;

                        if (isEdit)
                        {
                            command = new SqlCommand(@"
                                UPDATE ExpenseCategorySetup
                                SET Description = @description, InStoreItems = @inStoreItems, UpdatedDate = GETDATE()
                                WHERE Code = @code", connection);
                        }
                        else
                        {
                            var checkCmd = new SqlCommand("SELECT COUNT(*) FROM ExpenseCategorySetup WHERE Code = @code", connection);
                            checkCmd.Parameters.AddWithValue("@code", code);
                            int exists = Convert.ToInt32(checkCmd.ExecuteScalar());
                            if (exists > 0)
                            {
                                MessageBox.Show("An expense category with this code already exists.", "Duplicate Code",
                                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                                txtCode.Focus();
                                return;
                            }

                            command = new SqlCommand(@"
                                INSERT INTO ExpenseCategorySetup (Code, Description, InStoreItems)
                                VALUES (@code, @description, @inStoreItems)", connection);
                        }

                        command.Parameters.AddWithValue("@code", code);
                        command.Parameters.AddWithValue("@description", description);
                        command.Parameters.AddWithValue("@inStoreItems", inStoreItems);

                        int rowsAffected = command.ExecuteNonQuery();
                        if (rowsAffected > 0)
                        {
                            MessageBox.Show($"Expense category {(isEdit ? "updated" : "added")} successfully!", "Success",
                                MessageBoxButtons.OK, MessageBoxIcon.Information);
                            LoadExpenseCategories();
                            dialog.Close();
                        }
                        else
                        {
                            MessageBox.Show($"Failed to {(isEdit ? "update" : "add")} expense category.", "Error",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Error saving expense category: {ex.Message}", "Database Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            };

            btnCancel.Click += (s, args) => dialog.Close();

            dialog.Controls.AddRange(new Control[]
            {
                lblCode, txtCode, lblDescription, txtDescription, chkInStoreItems, btnSave, btnCancel
            });

            dialog.ShowDialog();
        }

        private void ExpenseCategorySetupForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                Close();
            }
        }

        private void BtnBack_Click(object? sender, EventArgs e)
        {
            Close();
        }
    }
}
