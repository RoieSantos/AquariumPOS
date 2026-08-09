using System;
using System.Data;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;
using System.Data.SqlClient;

namespace AquariumPOS
{
    public partial class TenderTypesForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;

        private DataGridView dgvTenderTypes = null!;
        private Button btnAdd = null!;
        private Button btnEdit = null!;
        private Button btnDelete = null!;
        private Button btnRefresh = null!;
        private Button btnClose = null!;
        private Button btnBack = null!;
        private Label lblCount = null!;

        public TenderTypesForm()
        {
            KeyPreview = true;
            this.KeyDown += TenderTypesForm_KeyDown;

            InitializeComponent();
            CreateTenderTypesTable();
            SetupUI();
            LoadTenderTypes();
        }

        private void InitializeComponent()
        {
            this.Text = "Tender Types Management";
            this.Size = new Size(800, 600);
            this.StartPosition = FormStartPosition.CenterParent;
            this.BackColor = Color.White;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.MinimizeBox = false;
        }

        private void SetupUI()
        {
            // DataGridView for tender types
            dgvTenderTypes = new DataGridView
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
                RowHeadersVisible = false
            };

            // Add columns
            dgvTenderTypes.Columns.Add("Code", "Code");
            dgvTenderTypes.Columns.Add("Description", "Description");
            dgvTenderTypes.Columns.Add("POSBankID", "POS Bank ID");
            dgvTenderTypes.Columns.Add("IsCardPayment", "Is Card Payment");

            // Set column widths
            dgvTenderTypes.Columns["Code"].FillWeight = 25;
            dgvTenderTypes.Columns["Description"].FillWeight = 45;
            dgvTenderTypes.Columns["POSBankID"].FillWeight = 20;
            dgvTenderTypes.Columns["IsCardPayment"].FillWeight = 10;

            // Count label
            lblCount = new Label
            {
                Text = "Total Tender Types: 0",
                Location = new Point(20, 430),
                Size = new Size(200, 20),
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.DarkBlue
            };

            // Buttons
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

            // Add controls to form
            this.Controls.AddRange(new Control[] {
                dgvTenderTypes, lblCount, btnAdd, btnEdit, btnDelete, btnRefresh, btnBack, btnClose
            });
        }

        private void CreateTenderTypesTable()
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    var createTableCmd = new SqlCommand(@"
                        IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'TenderTypes')
                        BEGIN
                            EXEC(N'
                                CREATE TABLE TenderTypes (
                                    Code NVARCHAR(20) PRIMARY KEY,
                                    Description NVARCHAR(100) NOT NULL,
                                    POSBankID NVARCHAR(50) NULL,
                                    Is_Card_Payment BIT NOT NULL CONSTRAINT DF_TenderTypes_Is_Card_Payment DEFAULT(0),
                                    CreatedDate DATETIME2 DEFAULT GETDATE(),
                                    UpdatedDate DATETIME2 DEFAULT GETDATE()
                                );

                                INSERT INTO TenderTypes (Code, Description, Is_Card_Payment) VALUES
                                (''CASH'', ''Cash'', 0),
                                (''CREDIT'', ''Credit Card'', 1),
                                (''DEBIT'', ''Debit Card'', 1),
                                (''GCASH'', ''GCash'', 0),
                                (''BANK'', ''Bank Transfer'', 0);
                            ')
                        END

                        -- Ensure POSBankID column exists for existing databases
                        IF COL_LENGTH('TenderTypes', 'POSBankID') IS NULL
                        BEGIN
                            ALTER TABLE TenderTypes ADD POSBankID NVARCHAR(50) NULL;
                        END

                        -- Ensure Is_Card_Payment column exists for existing databases
                        IF COL_LENGTH('TenderTypes', 'Is_Card_Payment') IS NULL
                        BEGIN
                            EXEC('ALTER TABLE TenderTypes ADD Is_Card_Payment BIT NOT NULL CONSTRAINT DF_TenderTypes_Is_Card_Payment_Default DEFAULT(0)');
                        END", connection);
                    createTableCmd.ExecuteNonQuery();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error creating tender types table: {ex.Message}", "Database Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void LoadTenderTypes()
        {
            try
            {
                dgvTenderTypes.Rows.Clear();
                int count = 0;

                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    bool hasIsCardPaymentColumn = TenderTypesHasColumn(connection, "Is_Card_Payment");
                    string query = hasIsCardPaymentColumn
                        ? "SELECT Code, Description, POSBankID, ISNULL(Is_Card_Payment, 0) AS Is_Card_Payment FROM TenderTypes ORDER BY Code"
                        : "SELECT Code, Description, POSBankID FROM TenderTypes ORDER BY Code";
                    var command = new SqlCommand(query, connection);

                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            string code = reader["Code"].ToString() ?? "";
                            string description = reader["Description"].ToString() ?? "";
                            string posBankId = reader["POSBankID"].ToString() ?? "";
                            bool isCardPayment = hasIsCardPaymentColumn
                                && reader["Is_Card_Payment"] != DBNull.Value
                                && Convert.ToBoolean(reader["Is_Card_Payment"]);

                            dgvTenderTypes.Rows.Add(code, description, posBankId, isCardPayment ? "Yes" : "No");
                            count++;
                        }
                    }
                }

                lblCount.Text = $"Total Tender Types: {count}";
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading tender types: {ex.Message}", "Database Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnAdd_Click(object? sender, EventArgs e)
        {
            ShowTenderTypeDialog();
        }

        private void BtnEdit_Click(object? sender, EventArgs e)
        {
            if (dgvTenderTypes.SelectedRows.Count == 0)
            {
                MessageBox.Show("Please select a tender type to edit.", "No Selection",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var selectedRow = dgvTenderTypes.SelectedRows[0];
            string code = selectedRow.Cells["Code"].Value.ToString() ?? "";
            string description = selectedRow.Cells["Description"].Value.ToString() ?? "";
            string posBankId = selectedRow.Cells["POSBankID"].Value?.ToString() ?? "";
            bool isCardPayment = string.Equals(selectedRow.Cells["IsCardPayment"].Value?.ToString(), "Yes", StringComparison.OrdinalIgnoreCase);

            ShowTenderTypeDialog(code, description, posBankId, isCardPayment);
        }

        private void BtnDelete_Click(object? sender, EventArgs e)
        {
            if (dgvTenderTypes.SelectedRows.Count == 0)
            {
                MessageBox.Show("Please select a tender type to delete.", "No Selection",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var selectedRow = dgvTenderTypes.SelectedRows[0];
            string code = selectedRow.Cells["Code"].Value.ToString() ?? "";
            string description = selectedRow.Cells["Description"].Value.ToString() ?? "";

            var result = MessageBox.Show($"Are you sure you want to delete tender type '{description}'?",
                "Confirm Delete", MessageBoxButtons.YesNo, MessageBoxIcon.Question);

            if (result == DialogResult.Yes)
            {
                try
                {
                    using (var connection = new SqlConnection(connectionString))
                    {
                        connection.Open();
                        var command = new SqlCommand("DELETE FROM TenderTypes WHERE Code = @code", connection);
                        command.Parameters.AddWithValue("@code", code);

                        int rowsAffected = command.ExecuteNonQuery();

                        if (rowsAffected > 0)
                        {
                            MessageBox.Show("Tender type deleted successfully!", "Success",
                                MessageBoxButtons.OK, MessageBoxIcon.Information);
                            LoadTenderTypes();
                        }
                        else
                        {
                            MessageBox.Show("Failed to delete tender type.", "Error",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Error deleting tender type: {ex.Message}", "Database Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void BtnRefresh_Click(object? sender, EventArgs e)
        {
            LoadTenderTypes();
        }

        private void BtnClose_Click(object? sender, EventArgs e)
        {
            this.Close();
        }

        private void ShowTenderTypeDialog(string existingCode = "", string existingDescription = "", string existingPOSBankID = "", bool existingIsCardPayment = false)
        {
            bool isEdit = !string.IsNullOrEmpty(existingCode);

            var dialog = new Form
            {
                Text = isEdit ? "Edit Tender Type" : "Add Tender Type",
                Size = new Size(420, 290),
                StartPosition = FormStartPosition.CenterParent,
                BackColor = Color.White,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false
            };

            // Code input
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
                ReadOnly = isEdit // Code cannot be changed when editing
            };

            // Description input
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

            // POSBankID input
            var lblPOSBankID = new Label
            {
                Text = "POS Bank ID:",
                Location = new Point(20, 110),
                Size = new Size(90, 20),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var txtPOSBankID = new TextBox
            {
                Location = new Point(110, 108),
                Size = new Size(250, 25),
                Font = new Font("Arial", 10),
                Text = existingPOSBankID,
                MaxLength = 50
            };

            var chkIsCardPayment = new CheckBox
            {
                Text = "Is Card Payment",
                Location = new Point(110, 142),
                Size = new Size(180, 24),
                Font = new Font("Arial", 10, FontStyle.Bold),
                Checked = existingIsCardPayment
            };

            // Buttons
            var btnSave = new Button
            {
                Text = "Save",
                Location = new Point(200, 188),
                Size = new Size(80, 35),
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var btnCancel = new Button
            {
                Text = "Cancel",
                Location = new Point(290, 188),
                Size = new Size(80, 35),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            btnSave.Click += (s, args) =>
            {
                string code = txtCode.Text.Trim().ToUpper();
                string description = txtDescription.Text.Trim();
                string posBankId = txtPOSBankID.Text.Trim();
                bool isCardPayment = chkIsCardPayment.Checked;

                if (string.IsNullOrEmpty(code))
                {
                    MessageBox.Show("Please enter a code.", "Validation Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    txtCode.Focus();
                    return;
                }

                if (string.IsNullOrEmpty(description))
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
                        bool hasIsCardPaymentColumn = TenderTypesHasColumn(connection, "Is_Card_Payment");
                        SqlCommand command;

                        if (isEdit)
                        {
                            string updateSql = hasIsCardPaymentColumn
                                ? @"
                                UPDATE TenderTypes 
                                SET Description = @description, POSBankID = @posBankID, Is_Card_Payment = @isCardPayment, UpdatedDate = GETDATE() 
                                WHERE Code = @code"
                                : @"
                                UPDATE TenderTypes 
                                SET Description = @description, POSBankID = @posBankID, UpdatedDate = GETDATE() 
                                WHERE Code = @code";
                            command = new SqlCommand(updateSql, connection);
                        }
                        else
                        {
                            // Check if code already exists
                            var checkCmd = new SqlCommand("SELECT COUNT(*) FROM TenderTypes WHERE Code = @code", connection);
                            checkCmd.Parameters.AddWithValue("@code", code);
                            int exists = Convert.ToInt32(checkCmd.ExecuteScalar());

                            if (exists > 0)
                            {
                                MessageBox.Show("A tender type with this code already exists.", "Duplicate Code",
                                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                                txtCode.Focus();
                                return;
                            }

                            string insertSql = hasIsCardPaymentColumn
                                ? @"
                                INSERT INTO TenderTypes (Code, Description, POSBankID, Is_Card_Payment) 
                                VALUES (@code, @description, @posBankID, @isCardPayment)"
                                : @"
                                INSERT INTO TenderTypes (Code, Description, POSBankID) 
                                VALUES (@code, @description, @posBankID)";
                            command = new SqlCommand(insertSql, connection);
                        }

                        command.Parameters.AddWithValue("@code", code);
                        command.Parameters.AddWithValue("@description", description);
                        command.Parameters.AddWithValue("@posBankID", string.IsNullOrWhiteSpace(posBankId) ? (object)DBNull.Value : posBankId);
                        if (hasIsCardPaymentColumn)
                        {
                            command.Parameters.AddWithValue("@isCardPayment", isCardPayment);
                        }

                        int rowsAffected = command.ExecuteNonQuery();

                        if (rowsAffected > 0)
                        {
                            MessageBox.Show($"Tender type {(isEdit ? "updated" : "added")} successfully!", "Success",
                                MessageBoxButtons.OK, MessageBoxIcon.Information);
                            LoadTenderTypes();
                            dialog.Close();
                        }
                        else
                        {
                            MessageBox.Show($"Failed to {(isEdit ? "update" : "add")} tender type.", "Error",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Error saving tender type: {ex.Message}", "Database Error",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            };

            btnCancel.Click += (s, args) => dialog.Close();

            dialog.Controls.AddRange(new Control[] {
                lblCode, txtCode, lblDescription, txtDescription, lblPOSBankID, txtPOSBankID, chkIsCardPayment, btnSave, btnCancel
            });

            dialog.ShowDialog();
        }

        private static bool TenderTypesHasColumn(SqlConnection connection, string columnName)
        {
            using var command = new SqlCommand(@"SELECT COUNT(*)
                                                 FROM INFORMATION_SCHEMA.COLUMNS
                                                 WHERE TABLE_NAME = 'TenderTypes' AND COLUMN_NAME = @columnName", connection);
            command.Parameters.AddWithValue("@columnName", columnName);
            return Convert.ToInt32(command.ExecuteScalar()) > 0;
        }

        private void TenderTypesForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }

        private void BtnBack_Click(object? sender, EventArgs e)
        {
            try
            {
                MainForm? mainFormInstance = null;
                if (this.Owner is MainForm ownerMain)
                {
                    mainFormInstance = ownerMain;
                }
                else
                {
                    foreach (Form f in Application.OpenForms)
                    {
                        if (f is MainForm mf)
                        {
                            mainFormInstance = mf;
                            break;
                        }
                    }
                }

                // After printing reports that may have been triggered during checkout flows,
                // // ensure the main form's checkout button is reverted back to SALES mode.
                // try
                // {
                //     // Pass the owner (if any) so RevertCheckoutToSales can detect MainForm directly
                //     FunctionEvents.RevertCheckoutToSales(this.Owner);
                // }
                // catch
                // {
                //     // swallow any UI errors to avoid breaking report printing
                // }

                // if (mainFormInstance != null)
                // {
                //     var field = typeof(MainForm).GetField("checkoutButton", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
                //     if (field != null)
                //     {
                //         var btn = field.GetValue(mainFormInstance) as Button;
                //         if (btn != null)
                //         {
                //             btn.Text = "CHECKOUT";
                //             btn.Tag = "SALES";
                //             try { btn.BackColor = SystemColors.ControlDark; } catch { }
                //         }
                //     }
                // }
            }
            catch
            {
                // ignore UI update failures
            }

            this.Close();
        }
    }
}
