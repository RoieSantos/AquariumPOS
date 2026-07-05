using System;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public partial class TransactionDetailForm : Form
    {
        private TextBox txtStoreNo;
        private TextBox txtPOSTerminalNo;
        private TextBox txtTransactionNo;
        private TextBox txtReceiptNo;
        private ComboBox cmbType;
        private NumericUpDown nudQuantity;
        private NumericUpDown nudPrice;
        private NumericUpDown nudDiscount;
        private NumericUpDown nudGrossAmount;
        private NumericUpDown nudNetAmount;
        private DateTimePicker dtpDate;
        private DateTimePicker dtpTime;
        private TextBox txtUserID;
        private TextBox txtDescription;
        private TextBox txtExpenseCategory;
        
        private Button btnSave;
        private Button btnCancel;
        private Button btnCalculate;
        
        private bool isEditMode = false;
        private int originalStoreNo, originalPOSTerminalNo, originalTransactionNo;

        public TransactionDetailForm()
        {
            KeyPreview = true;
            this.KeyDown += TransactionDetailForm_KeyDown;

            InitializeComponent();
            SetupNewTransaction();
        }

        public TransactionDetailForm(int storeNo, int posTerminalNo, int transactionNo)
        {
            KeyPreview = true;
            this.KeyDown += TransactionDetailForm_KeyDown;

            InitializeComponent();
            isEditMode = true;
            originalStoreNo = storeNo;
            originalPOSTerminalNo = posTerminalNo;
            originalTransactionNo = transactionNo;
            LoadTransaction(storeNo, posTerminalNo, transactionNo);
        }

        private void InitializeComponent()
        {
            this.SuspendLayout();

            // Form properties
            this.Text = "Transaction Details";
            this.Size = new Size(500, 720);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.FormBorderStyle = FormBorderStyle.FixedSingle;
            this.MaximizeBox = false;

            int yPos = 20;
            int labelWidth = 120;
            int controlWidth = 200;
            int spacing = 35;

            // Store No
            Label lblStoreNo = new Label();
            lblStoreNo.Text = "Store No:";
            lblStoreNo.Location = new Point(20, yPos);
            lblStoreNo.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblStoreNo);

            txtStoreNo = new TextBox();
            txtStoreNo.Location = new Point(150, yPos);
            txtStoreNo.Size = new Size(controlWidth, 23);
            this.Controls.Add(txtStoreNo);

            yPos += spacing;

            // POS Terminal No
            Label lblPOSTerminalNo = new Label();
            lblPOSTerminalNo.Text = "POS Terminal No:";
            lblPOSTerminalNo.Location = new Point(20, yPos);
            lblPOSTerminalNo.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblPOSTerminalNo);

            txtPOSTerminalNo = new TextBox();
            txtPOSTerminalNo.Location = new Point(150, yPos);
            txtPOSTerminalNo.Size = new Size(controlWidth, 23);
            this.Controls.Add(txtPOSTerminalNo);

            yPos += spacing;

            // Transaction No
            Label lblTransactionNo = new Label();
            lblTransactionNo.Text = "Transaction No:";
            lblTransactionNo.Location = new Point(20, yPos);
            lblTransactionNo.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblTransactionNo);

            txtTransactionNo = new TextBox();
            txtTransactionNo.Location = new Point(150, yPos);
            txtTransactionNo.Size = new Size(controlWidth, 23);
            this.Controls.Add(txtTransactionNo);

            yPos += spacing;

            // Receipt No
            Label lblReceiptNo = new Label();
            lblReceiptNo.Text = "Receipt No:";
            lblReceiptNo.Location = new Point(20, yPos);
            lblReceiptNo.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblReceiptNo);

            txtReceiptNo = new TextBox();
            txtReceiptNo.Location = new Point(150, yPos);
            txtReceiptNo.Size = new Size(controlWidth, 23);
            this.Controls.Add(txtReceiptNo);

            yPos += spacing;

            // Type
            Label lblType = new Label();
            lblType.Text = "Type:";
            lblType.Location = new Point(20, yPos);
            lblType.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblType);

            cmbType = new ComboBox();
            cmbType.Location = new Point(150, yPos);
            cmbType.Size = new Size(controlWidth, 23);
            cmbType.DropDownStyle = ComboBoxStyle.DropDownList;
            cmbType.Items.AddRange(new string[] { "Sale", "Return", "Void", "Refund", "Exchange" });
            this.Controls.Add(cmbType);

            yPos += spacing;

            // Quantity
            Label lblQuantity = new Label();
            lblQuantity.Text = "Quantity:";
            lblQuantity.Location = new Point(20, yPos);
            lblQuantity.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblQuantity);

            nudQuantity = new NumericUpDown();
            nudQuantity.Location = new Point(150, yPos);
            nudQuantity.Size = new Size(controlWidth, 23);
            nudQuantity.DecimalPlaces = 2;
            nudQuantity.Maximum = 999999;
            nudQuantity.ValueChanged += CalculateAmounts;
            this.Controls.Add(nudQuantity);

            yPos += spacing;

            // Price
            Label lblPrice = new Label();
            lblPrice.Text = "Price:";
            lblPrice.Location = new Point(20, yPos);
            lblPrice.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblPrice);

            nudPrice = new NumericUpDown();
            nudPrice.Location = new Point(150, yPos);
            nudPrice.Size = new Size(controlWidth, 23);
            nudPrice.DecimalPlaces = 2;
            nudPrice.Maximum = 999999;
            nudPrice.ValueChanged += CalculateAmounts;
            this.Controls.Add(nudPrice);

            yPos += spacing;

            // Discount
            Label lblDiscount = new Label();
            lblDiscount.Text = "Discount:";
            lblDiscount.Location = new Point(20, yPos);
            lblDiscount.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblDiscount);

            nudDiscount = new NumericUpDown();
            nudDiscount.Location = new Point(150, yPos);
            nudDiscount.Size = new Size(controlWidth, 23);
            nudDiscount.DecimalPlaces = 2;
            nudDiscount.Maximum = 999999;
            nudDiscount.ValueChanged += CalculateAmounts;
            this.Controls.Add(nudDiscount);

            yPos += spacing;

            // Gross Amount
            Label lblGrossAmount = new Label();
            lblGrossAmount.Text = "Gross Amount:";
            lblGrossAmount.Location = new Point(20, yPos);
            lblGrossAmount.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblGrossAmount);

            nudGrossAmount = new NumericUpDown();
            nudGrossAmount.Location = new Point(150, yPos);
            nudGrossAmount.Size = new Size(controlWidth, 23);
            nudGrossAmount.DecimalPlaces = 2;
            nudGrossAmount.Maximum = 999999;
            nudGrossAmount.ReadOnly = true;
            nudGrossAmount.BackColor = Color.LightGray;
            this.Controls.Add(nudGrossAmount);

            yPos += spacing;

            // Net Amount
            Label lblNetAmount = new Label();
            lblNetAmount.Text = "Net Amount:";
            lblNetAmount.Location = new Point(20, yPos);
            lblNetAmount.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblNetAmount);

            nudNetAmount = new NumericUpDown();
            nudNetAmount.Location = new Point(150, yPos);
            nudNetAmount.Size = new Size(controlWidth, 23);
            nudNetAmount.DecimalPlaces = 2;
            nudNetAmount.Maximum = 999999;
            nudNetAmount.ReadOnly = true;
            nudNetAmount.BackColor = Color.LightGray;
            this.Controls.Add(nudNetAmount);

            yPos += spacing;

            // Date
            Label lblDate = new Label();
            lblDate.Text = "Date:";
            lblDate.Location = new Point(20, yPos);
            lblDate.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblDate);

            dtpDate = new DateTimePicker();
            dtpDate.Location = new Point(150, yPos);
            dtpDate.Size = new Size(controlWidth, 23);
            dtpDate.Format = DateTimePickerFormat.Short;
            this.Controls.Add(dtpDate);

            yPos += spacing;

            // Time
            Label lblTime = new Label();
            lblTime.Text = "Time:";
            lblTime.Location = new Point(20, yPos);
            lblTime.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblTime);

            dtpTime = new DateTimePicker();
            dtpTime.Location = new Point(150, yPos);
            dtpTime.Size = new Size(controlWidth, 23);
            dtpTime.Format = DateTimePickerFormat.Time;
            dtpTime.ShowUpDown = true;
            this.Controls.Add(dtpTime);

            yPos += spacing;

            // User ID
            Label lblUserID = new Label();
            lblUserID.Text = "User ID:";
            lblUserID.Location = new Point(20, yPos);
            lblUserID.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblUserID);

            txtUserID = new TextBox();
            txtUserID.Location = new Point(150, yPos);
            txtUserID.Size = new Size(controlWidth, 23);
            this.Controls.Add(txtUserID);

            yPos += spacing;

            // Description
            Label lblDescription = new Label();
            lblDescription.Text = "Description:";
            lblDescription.Location = new Point(20, yPos);
            lblDescription.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblDescription);

            txtDescription = new TextBox();
            txtDescription.Location = new Point(150, yPos);
            txtDescription.Size = new Size(controlWidth, 60);
            txtDescription.Multiline = true;
            this.Controls.Add(txtDescription);

            yPos += 80;

            // Expense Category
            Label lblExpenseCategory = new Label();
            lblExpenseCategory.Text = "Expense Category:";
            lblExpenseCategory.Location = new Point(20, yPos);
            lblExpenseCategory.Size = new Size(labelWidth, 23);
            this.Controls.Add(lblExpenseCategory);

            txtExpenseCategory = new TextBox();
            txtExpenseCategory.Location = new Point(150, yPos);
            txtExpenseCategory.Size = new Size(controlWidth, 23);
            this.Controls.Add(txtExpenseCategory);

            yPos += spacing;

            // Calculate button
            btnCalculate = new Button();
            btnCalculate.Text = "Calculate";
            btnCalculate.Location = new Point(150, yPos);
            btnCalculate.Size = new Size(80, 30);
            btnCalculate.BackColor = Color.LightYellow;
            btnCalculate.Click += BtnCalculate_Click;
            this.Controls.Add(btnCalculate);

            yPos += 40;

            // Buttons
            btnSave = new Button();
            btnSave.Text = "Save";
            btnSave.Location = new Point(150, yPos);
            btnSave.Size = new Size(80, 35);
            btnSave.BackColor = Color.LightGreen;
            btnSave.Click += BtnSave_Click;
            this.Controls.Add(btnSave);

            btnCancel = new Button();
            btnCancel.Text = "Cancel";
            btnCancel.Location = new Point(270, yPos);
            btnCancel.Size = new Size(80, 35);
            btnCancel.BackColor = Color.LightCoral;
            btnCancel.Click += BtnCancel_Click;
            this.Controls.Add(btnCancel);

            this.ResumeLayout(false);
            this.PerformLayout();
        }

        private void SetupNewTransaction()
        {
            this.Text = "New Transaction";
            dtpDate.Value = DateTime.Now;
            dtpTime.Value = DateTime.Now;
            txtUserID.Text = CurrentUser.Username; // Assuming CurrentUser class exists
            cmbType.SelectedIndex = 0; // Default to "Sale"
            
            // Set default values for primary key fields
            txtStoreNo.Text = "1";
            txtPOSTerminalNo.Text = "1";
            
            // Generate next transaction number
            GenerateNextTransactionNumber();
        }

        private void GenerateNextTransactionNumber()
        {
            try
            {
                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    string query = "SELECT ISNULL(MAX(TransactionNo), 0) + 1 FROM TransactionHeader WHERE StoreNo = @storeNo AND POSTerminalNo = @posTerminalNo";
                    
                    SqlCommand command = new SqlCommand(query, connection);
                    command.Parameters.AddWithValue("@storeNo", int.Parse(txtStoreNo.Text));
                    command.Parameters.AddWithValue("@posTerminalNo", int.Parse(txtPOSTerminalNo.Text));
                    
                    int nextTransactionNo = (int)command.ExecuteScalar();
                    txtTransactionNo.Text = nextTransactionNo.ToString();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error generating transaction number: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                txtTransactionNo.Text = "1";
            }
        }

        private void LoadTransaction(int storeNo, int posTerminalNo, int transactionNo)
        {
            try
            {
                this.Text = "Edit Transaction";
                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    string query = @"SELECT * FROM TransactionHeader 
                                   WHERE StoreNo = @storeNo AND POSTerminalNo = @posTerminalNo AND TransactionNo = @transactionNo";
                    
                    SqlCommand command = new SqlCommand(query, connection);
                    command.Parameters.AddWithValue("@storeNo", storeNo);
                    command.Parameters.AddWithValue("@posTerminalNo", posTerminalNo);
                    command.Parameters.AddWithValue("@transactionNo", transactionNo);
                    
                    SqlDataReader reader = command.ExecuteReader();
                    if (reader.Read())
                    {
                        txtStoreNo.Text = reader["StoreNo"].ToString();
                        txtPOSTerminalNo.Text = reader["POSTerminalNo"].ToString();
                        txtTransactionNo.Text = reader["TransactionNo"].ToString();
                        txtReceiptNo.Text = reader["ReceiptNo"].ToString();
                        cmbType.Text = reader["Type"].ToString();
                        nudQuantity.Value = Convert.ToDecimal(reader["Quantity"]);
                        nudPrice.Value = Convert.ToDecimal(reader["Price"]);
                        nudDiscount.Value = Convert.ToDecimal(reader["Discount"]);
                        nudGrossAmount.Value = Convert.ToDecimal(reader["GrossAmount"]);
                        nudNetAmount.Value = Convert.ToDecimal(reader["NetAmount"]);
                        dtpDate.Value = Convert.ToDateTime(reader["Date"]);
                        dtpTime.Value = Convert.ToDateTime(reader["Time"]);
                        txtUserID.Text = reader["UserID"].ToString();
                        txtDescription.Text = reader["Description"].ToString();
                        txtExpenseCategory.Text = HasColumn(reader, "ExpenseCategory") ? reader["ExpenseCategory"]?.ToString() ?? string.Empty : string.Empty;
                        
                        // Disable primary key fields in edit mode
                        txtStoreNo.ReadOnly = true;
                        txtPOSTerminalNo.ReadOnly = true;
                        txtTransactionNo.ReadOnly = true;
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading transaction: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void CalculateAmounts(object sender, EventArgs e)
        {
            decimal quantity = nudQuantity.Value;
            decimal price = nudPrice.Value;
            decimal discount = nudDiscount.Value;
            
            decimal grossAmount = quantity * price;
            decimal netAmount = grossAmount - discount;
            
            nudGrossAmount.Value = grossAmount;
            nudNetAmount.Value = netAmount;
        }

        private void BtnCalculate_Click(object sender, EventArgs e)
        {
            CalculateAmounts(sender, e);
        }

        private void BtnSave_Click(object sender, EventArgs e)
        {
            if (ValidateInput())
            {
                SaveTransaction();
            }
        }

        private bool ValidateInput()
        {
            if (string.IsNullOrEmpty(txtStoreNo.Text) || string.IsNullOrEmpty(txtPOSTerminalNo.Text) || string.IsNullOrEmpty(txtTransactionNo.Text))
            {
                MessageBox.Show("Store No, POS Terminal No, and Transaction No are required.", "Validation Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            if (cmbType.SelectedIndex == -1)
            {
                MessageBox.Show("Please select a transaction type.", "Validation Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            return true;
        }

        private void SaveTransaction()
        {
            try
            {
                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    bool hasExpenseCategoryColumn = TransactionHeaderHasColumn(connection, "ExpenseCategory");
                    
                    string query;
                    if (isEditMode)
                    {
                        query = @"UPDATE TransactionHeader SET 
                                ReceiptNo = @receiptNo,
                                Type = @type,
                                Quantity = @quantity,
                                Price = @price,
                                Discount = @discount,
                                GrossAmount = @grossAmount,
                                NetAmount = @netAmount,
                                Date = @date,
                                Time = @time,
                                UserID = @userID,
                                Description = @description" +
                                (hasExpenseCategoryColumn ? ", ExpenseCategory = @expenseCategory" : string.Empty) +
                                " WHERE StoreNo = @storeNo AND POSTerminalNo = @posTerminalNo AND TransactionNo = @transactionNo";
                    }
                    else
                    {
                            query = "INSERT INTO TransactionHeader " +
                                "(StoreNo, POSTerminalNo, TransactionNo, ReceiptNo, Type, Quantity, Price, Discount, GrossAmount, NetAmount, Date, Time, UserID, Description" +
                                (hasExpenseCategoryColumn ? ", ExpenseCategory" : string.Empty) +
                                ") VALUES " +
                                "(@storeNo, @posTerminalNo, @transactionNo, @receiptNo, @type, @quantity, @price, @discount, @grossAmount, @netAmount, @date, @time, @userID, @description" +
                                (hasExpenseCategoryColumn ? ", @expenseCategory" : string.Empty) +
                                ")";
                    }
                    
                    SqlCommand command = new SqlCommand(query, connection);
                    command.Parameters.AddWithValue("@storeNo", int.Parse(txtStoreNo.Text));
                    command.Parameters.AddWithValue("@posTerminalNo", int.Parse(txtPOSTerminalNo.Text));
                    command.Parameters.AddWithValue("@transactionNo", int.Parse(txtTransactionNo.Text));
                    command.Parameters.AddWithValue("@receiptNo", txtReceiptNo.Text);
                    command.Parameters.AddWithValue("@type", cmbType.Text);
                    command.Parameters.AddWithValue("@quantity", nudQuantity.Value);
                    command.Parameters.AddWithValue("@price", nudPrice.Value);
                    command.Parameters.AddWithValue("@discount", nudDiscount.Value);
                    command.Parameters.AddWithValue("@grossAmount", nudGrossAmount.Value);
                    command.Parameters.AddWithValue("@netAmount", nudNetAmount.Value);
                    command.Parameters.AddWithValue("@date", dtpDate.Value.Date);
                    command.Parameters.AddWithValue("@time", dtpTime.Value);
                    command.Parameters.AddWithValue("@userID", txtUserID.Text);
                    command.Parameters.AddWithValue("@description", txtDescription.Text);
                    if (hasExpenseCategoryColumn)
                    {
                        command.Parameters.AddWithValue("@expenseCategory", string.IsNullOrWhiteSpace(txtExpenseCategory.Text) ? (object)DBNull.Value : txtExpenseCategory.Text.Trim());
                    }
                    
                    command.ExecuteNonQuery();
                    
                    MessageBox.Show("Transaction saved successfully.", "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    this.DialogResult = DialogResult.OK;
                    this.Close();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error saving transaction: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnCancel_Click(object sender, EventArgs e)
        {
            this.DialogResult = DialogResult.Cancel;
            this.Close();
        }

        private void TransactionDetailForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }

        private static bool TransactionHeaderHasColumn(SqlConnection connection, string columnName)
        {
            using (var command = new SqlCommand(@"SELECT COUNT(*)
                                                FROM INFORMATION_SCHEMA.COLUMNS
                                                WHERE TABLE_NAME = 'TransactionHeader' AND COLUMN_NAME = @columnName", connection))
            {
                command.Parameters.AddWithValue("@columnName", columnName);
                return Convert.ToInt32(command.ExecuteScalar()) > 0;
            }
        }

        private static bool HasColumn(SqlDataReader reader, string columnName)
        {
            for (int index = 0; index < reader.FieldCount; index++)
            {
                if (string.Equals(reader.GetName(index), columnName, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }
    }
}
