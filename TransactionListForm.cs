using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Drawing.Printing;
using Microsoft.VisualBasic;
using System.Windows.Forms;

namespace AquariumPOS
{
    public partial class TransactionListForm : Form
    {
    // Optional initial receipt number to filter on when the form loads
    public string InitialReceiptNo { get; set; } = string.Empty;
    // When true, the grid will show only a ReceiptNo link column (used when opened from Production Orders)
    public bool ShowOnlyReceiptLink { get; set; } = false;
        private DataGridView? dgvTransactions;
        private Button? btnReverse;
        private Button? btnRefresh;
        private Button? btnAdd;
        private Button? btnEdit;
        private Button? btnDelete;
        private Button? btnClose;
        private Button? btnPaymentEntries;
        private Button? btnReprint;
        private Button? btnPrintJobOrder;
        private Button? btnReturnExchange;
    private Button? btnPayCommission;
        private TextBox? txtSearch;
        private Label? lblSearch;
        private DateTimePicker? dtpFromDate;
        private DateTimePicker? dtpToDate;
        private Label? lblFromDate;
        private Label? lblToDate;
        private Button? btnFilter;

        public void WriteCashFloatEntryTransactionHeader(int storeNo, int posTerminalNo, int transactionNo, string receiptNo, string cashierID, decimal floatAmount, string remarks)
        {
            string connectionString = GlobalSettings.ConnectionString;
            using (SqlConnection conn = new SqlConnection(connectionString))
            {
                conn.Open();
                string query = @"INSERT INTO TransactionHeader (
                        StoreNo, POSTerminalNo, TransactionNo, ReceiptNo, Type, Quantity, Price, Discount, GrossAmount, NetAmount, Date, Time, UserID, Description
                    ) VALUES (
                        @StoreNo, @POSTerminalNo, @TransactionNo, @ReceiptNo, @Type, @Quantity, @Price, @Discount, @GrossAmount, @NetAmount, @Date, @Time, @UserID, @Description
                    )";
                using (SqlCommand cmd = new SqlCommand(query, conn))
                {
                    cmd.Parameters.AddWithValue("@StoreNo", storeNo);
                    cmd.Parameters.AddWithValue("@POSTerminalNo", posTerminalNo);
                    cmd.Parameters.AddWithValue("@TransactionNo", transactionNo);
                    cmd.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                    cmd.Parameters.AddWithValue("@Type", "Float_Entry");
                    cmd.Parameters.AddWithValue("@Quantity", 1);
                    cmd.Parameters.AddWithValue("@Price", floatAmount);
                    cmd.Parameters.AddWithValue("@Discount", 0);
                    cmd.Parameters.AddWithValue("@GrossAmount", floatAmount);
                    cmd.Parameters.AddWithValue("@NetAmount", floatAmount);
                    cmd.Parameters.AddWithValue("@Date", DateTime.Now);
                    cmd.Parameters.AddWithValue("@Time", DateTime.Now.ToString("HH:mm:ss"));
                    cmd.Parameters.AddWithValue("@UserID", cashierID);
                    cmd.Parameters.AddWithValue("@Description", remarks ?? string.Empty);
                    cmd.ExecuteNonQuery();
                }
            }
        }

        public TransactionListForm()
        {
            KeyPreview = true;
            this.KeyDown += TransactionListForm_KeyDown;

            InitializeComponent();
        }

        private void TransactionListForm_Load(object? sender, EventArgs e)
        {
            // Add Status column to TransactionHeader if it doesn't exist
            AddStatusColumnIfNotExists();
            AddStatusColumnToTransPaymentEntryIfNotExists();
            LoadTransactions();
            // If caller provided an initial receipt number, pre-fill search and apply an exact filter
            try
            {
                if (!string.IsNullOrWhiteSpace(InitialReceiptNo) && txtSearch != null)
                {
                    txtSearch.Text = InitialReceiptNo;
                    // If the grid data source is a DataTable, apply an exact RowFilter on ReceiptNo so
                    // only the matching transactions are shown (ignore date filters).
                    try
                    {
                        if (dgvTransactions?.DataSource is DataTable dt)
                        {
                            var safe = InitialReceiptNo.Replace("'", "''");
                            dt.DefaultView.RowFilter = $"ReceiptNo = '{safe}'";
                        }
                        else
                        {
                            // Fallback to the generic filter logic
                            FilterTransactions();
                        }

                        // If caller requested a receipt-link-only view, configure the grid accordingly
                        if (ShowOnlyReceiptLink)
                        {
                            ConfigureReceiptLinkView();
                        }
                        else
                        {
                            // Ensure standard behavior if not in link-only mode
                            FormatGridColumns();
                        }
                    }
                    catch { /* ignore filtering errors */ }
                }
            }
            catch { }
        }

        private void AddStatusColumnIfNotExists()
        {
            try
            {
                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    // Check if Status column exists
                    string checkColumnQuery = @"SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS 
                                              WHERE TABLE_NAME = 'TransactionHeader' AND COLUMN_NAME = 'Status'";
                    SqlCommand checkCmd = new SqlCommand(checkColumnQuery, connection);
                    int columnExists = (int)checkCmd.ExecuteScalar();

                    if (columnExists == 0)
                    {
                        // Add Status column
                        string addColumnQuery = "ALTER TABLE TransactionHeader ADD Status NVARCHAR(20) DEFAULT 'ACTIVE'";
                        SqlCommand addCmd = new SqlCommand(addColumnQuery, connection);
                        addCmd.ExecuteNonQuery();
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error adding Status column: {ex.Message}", "Database Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void AddStatusColumnToTransPaymentEntryIfNotExists()
        {
            try
            {
                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    string checkColumnQuery = @"SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS 
                                              WHERE TABLE_NAME = 'TransPaymentEntry' AND COLUMN_NAME = 'Status'";
                    using (SqlCommand checkCmd = new SqlCommand(checkColumnQuery, connection))
                    {
                        int columnExists = Convert.ToInt32(checkCmd.ExecuteScalar() ?? 0);
                        if (columnExists == 0)
                        {
                            string addColumnQuery = "ALTER TABLE TransPaymentEntry ADD Status NVARCHAR(20) DEFAULT 'ACTIVE'";
                            using (SqlCommand addCmd = new SqlCommand(addColumnQuery, connection))
                            {
                                addCmd.ExecuteNonQuery();
                            }
                        }
                    }
                }
            }
            catch
            {
                // Non-blocking - older DBs may not allow this; pay-commission can still proceed without storing paid status on payment lines.
            }
        }

        private void InitializeComponent()
        {
            this.SuspendLayout();

            // Form properties - start maximized to accommodate all fields
            this.Text = "Transaction List";
            this.WindowState = FormWindowState.Maximized;
            this.StartPosition = FormStartPosition.CenterScreen;
            this.FormBorderStyle = FormBorderStyle.Sizable;
            this.MaximizeBox = true;
            this.Load += TransactionListForm_Load;

            // Top panel for search and filters
            Panel topPanel = new Panel();
            topPanel.Dock = DockStyle.Top;
            topPanel.Height = 50;
            topPanel.Padding = new Padding(6);
            topPanel.BackColor = Color.Transparent;

            // Search controls
            lblSearch = new Label();
            lblSearch.Text = "Search:";
            lblSearch.Location = new Point(6, 12);
            lblSearch.AutoSize = true;
            topPanel.Controls.Add(lblSearch);

            txtSearch = new TextBox();
            txtSearch.Location = new Point(64, 10);
            txtSearch.Size = new Size(260, 26);
            txtSearch.Font = new Font("Arial", 10);
            txtSearch.TextChanged += TxtSearch_TextChanged;
            topPanel.Controls.Add(txtSearch);

            // Date filter controls
            lblFromDate = new Label();
            lblFromDate.Text = "From:";
            lblFromDate.Location = new Point(340, 12);
            lblFromDate.AutoSize = true;
            topPanel.Controls.Add(lblFromDate);

            dtpFromDate = new DateTimePicker();
            dtpFromDate.Location = new Point(390, 10);
            dtpFromDate.Size = new Size(120, 26);
            dtpFromDate.Format = DateTimePickerFormat.Short;
            topPanel.Controls.Add(dtpFromDate);

            lblToDate = new Label();
            lblToDate.Text = "To:";
            lblToDate.Location = new Point(520, 12);
            lblToDate.AutoSize = true;
            topPanel.Controls.Add(lblToDate);

            dtpToDate = new DateTimePicker();
            dtpToDate.Location = new Point(550, 10);
            dtpToDate.Size = new Size(120, 26);
            dtpToDate.Format = DateTimePickerFormat.Short;
            topPanel.Controls.Add(dtpToDate);

            btnFilter = new Button();
            btnFilter.Text = "Filter";
            btnFilter.Location = new Point(685, 8);
            btnFilter.Size = new Size(80, 30);
            btnFilter.Click += BtnFilter_Click;
            topPanel.Controls.Add(btnFilter);

            // DataGridView - dock fill to occupy remaining area
            dgvTransactions = new DataGridView();
            dgvTransactions.Dock = DockStyle.Fill;
            dgvTransactions.AllowUserToAddRows = false;
            dgvTransactions.AllowUserToDeleteRows = false;
            dgvTransactions.ReadOnly = true;
            dgvTransactions.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            dgvTransactions.MultiSelect = false;
            dgvTransactions.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
            dgvTransactions.DoubleClick += DgvTransactions_DoubleClick;

            // Bottom panel for action buttons
            Panel bottomPanel = new Panel();
            bottomPanel.Dock = DockStyle.Bottom;
            bottomPanel.Height = 60;
            bottomPanel.Padding = new Padding(6);

            // Buttons
            btnRefresh = new Button();
            btnRefresh.Text = "Refresh";
            btnRefresh.Size = new Size(110, 40);
            btnRefresh.BackColor = Color.LightYellow;
            btnRefresh.Click += BtnRefresh_Click;
            btnRefresh.Location = new Point(6, 10);
            bottomPanel.Controls.Add(btnRefresh);

            btnPaymentEntries = new Button();
            btnPaymentEntries.Text = "Payment Entries";
            btnPaymentEntries.Size = new Size(150, 40);
            btnPaymentEntries.BackColor = Color.DarkGreen;
            btnPaymentEntries.ForeColor = Color.White;
            btnPaymentEntries.Font = new Font("Arial", 10, FontStyle.Bold);
            btnPaymentEntries.Click += BtnPaymentEntries_Click;
            btnPaymentEntries.Location = new Point(126, 10);
            bottomPanel.Controls.Add(btnPaymentEntries);

            btnReprint = new Button();
            btnReprint.Text = "Reprint";
            btnReprint.Size = new Size(110, 40);
            btnReprint.BackColor = Color.SteelBlue;
            btnReprint.ForeColor = Color.White;
            btnReprint.Font = new Font("Arial", 10, FontStyle.Bold);
            btnReprint.Click += BtnReprint_Click;
            btnReprint.Location = new Point(286, 10);
            bottomPanel.Controls.Add(btnReprint);

            btnPayCommission = new Button();
            btnPayCommission.Text = "Pay Comission";
            btnPayCommission.Size = new Size(150, 40);
            btnPayCommission.BackColor = Color.DarkOrange;
            btnPayCommission.ForeColor = Color.Black;
            btnPayCommission.Font = new Font("Arial", 10, FontStyle.Bold);
            btnPayCommission.Click += BtnPayCommission_Click;
            btnPayCommission.Location = new Point(406, 10);
            bottomPanel.Controls.Add(btnPayCommission);

            btnPrintJobOrder = new Button();
            btnPrintJobOrder.Text = "Print Job Order";
            btnPrintJobOrder.Size = new Size(150, 40);
            btnPrintJobOrder.BackColor = Color.MediumPurple;
            btnPrintJobOrder.ForeColor = Color.White;
            btnPrintJobOrder.Font = new Font("Arial", 10, FontStyle.Bold);
            btnPrintJobOrder.Click += BtnPrintJobOrder_Click;
            btnPrintJobOrder.Location = new Point(566, 10);
            bottomPanel.Controls.Add(btnPrintJobOrder);

            btnReturnExchange = new Button();
            btnReturnExchange.Text = "Return / Exchange";
            btnReturnExchange.Size = new Size(160, 40);
            btnReturnExchange.BackColor = Color.Firebrick;
            btnReturnExchange.ForeColor = Color.White;
            btnReturnExchange.Font = new Font("Arial", 10, FontStyle.Bold);
            btnReturnExchange.Click += BtnReturnExchange_Click;
            btnReturnExchange.Location = new Point(726, 10);
            bottomPanel.Controls.Add(btnReturnExchange);

            btnClose = new Button();
            btnClose.Text = "Close";
            btnClose.Size = new Size(110, 40);
            btnClose.BackColor = Color.LightGray;
            btnClose.Click += BtnClose_Click;
            btnClose.Location = new Point(Width - 130, 10);
            btnClose.Anchor = AnchorStyles.Right | AnchorStyles.Top;
            bottomPanel.Controls.Add(btnClose);

            // Add panels and grid to form
            this.Controls.Add(dgvTransactions);
            this.Controls.Add(bottomPanel);
            this.Controls.Add(topPanel);

            this.ResumeLayout(false);
            this.PerformLayout();
        }

        private void BtnPrintJobOrder_Click(object? sender, EventArgs e)
        {
            if (dgvTransactions == null)
            {
                MessageBox.Show("Transactions grid not available.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (dgvTransactions.SelectedRows.Count == 0)
            {
                MessageBox.Show("Please select a transaction to print a job order for.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var selectedRow = dgvTransactions.SelectedRows[0];
            string receiptNo = selectedRow.Cells["ReceiptNo"]?.Value?.ToString() ?? string.Empty;

            if (string.IsNullOrEmpty(receiptNo))
            {
                MessageBox.Show("Selected transaction does not have a Receipt No.", "Invalid Selection", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            try
            {
                FunctionEvents.PrintJobOrder(receiptNo, this);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error printing job order: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnReturnExchange_Click(object? sender, EventArgs e)
        {
            if (dgvTransactions == null)
            {
                MessageBox.Show("Transactions grid not available.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (dgvTransactions.SelectedRows.Count == 0)
            {
                MessageBox.Show("Please select a transaction for return/exchange.", "No Selection",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var selectedRow = dgvTransactions.SelectedRows[0];
            string type = selectedRow.Cells["Type"]?.Value?.ToString() ?? string.Empty;
            if (!string.Equals(type, "SALES", StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show("Please select a SALES transaction for return/exchange.", "Invalid Selection",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string status = selectedRow.Cells["Status"]?.Value?.ToString() ?? "ACTIVE";
            if (string.Equals(status, "REVERSED", StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show("This transaction has already been reversed.", "Already Reversed",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string receiptNo = selectedRow.Cells["ReceiptNo"]?.Value?.ToString() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(receiptNo))
            {
                MessageBox.Show("Cannot process return/exchange: Receipt number is missing.", "Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            DateTime transactionDate;
            if (!TryGetTransactionDate(selectedRow, receiptNo, out transactionDate))
            {
                MessageBox.Show("Cannot process return/exchange: Transaction date could not be determined.", "Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if ((DateTime.Today - transactionDate.Date).TotalDays > 3)
            {
                MessageBox.Show(
                    $"Exchange is only allowed within 3 days of purchase.\n\nPurchase Date: {transactionDate:yyyy-MM-dd}\nToday: {DateTime.Today:yyyy-MM-dd}",
                    "Exchange Period Expired",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return;
            }

            try
            {
                var items = LoadReturnableItems(receiptNo);
                if (items.Count == 0)
                {
                    MessageBox.Show("No sale items were found for this receipt.", "Return / Exchange",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                using var picker = new ReturnItemSelectionForm(items);
                if (picker.ShowDialog(this) != DialogResult.OK)
                    return;

                if (picker.SelectedItems.Count == 0)
                {
                    MessageBox.Show("No return items selected.", "Return / Exchange",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                var mainForm = Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                if (mainForm == null)
                {
                    MessageBox.Show("Main POS screen is not available.", "Return / Exchange",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                bool staged = mainForm.BeginReturnExchange(receiptNo, picker.SelectedItems);
                if (!staged)
                    return;

                try
                {
                    mainForm.BringToFront();
                    mainForm.Activate();
                }
                catch { }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error preparing return/exchange: {ex.Message}", "Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private bool TryGetTransactionDate(DataGridViewRow selectedRow, string receiptNo, out DateTime transactionDate)
        {
            transactionDate = DateTime.MinValue;

            try
            {
                var cellValue = selectedRow.Cells["Date"]?.Value;
                if (cellValue != null && cellValue != DBNull.Value)
                {
                    if (cellValue is DateTime dt)
                    {
                        transactionDate = dt;
                        return true;
                    }

                    if (DateTime.TryParse(cellValue.ToString(), out dt))
                    {
                        transactionDate = dt;
                        return true;
                    }
                }
            }
            catch
            {
                // Fall back to DB lookup below.
            }

            if (string.IsNullOrWhiteSpace(receiptNo))
                return false;

            try
            {
                using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                conn.Open();

                using var cmd = new SqlCommand("SELECT TOP 1 [Date] FROM TransactionHeader WHERE ReceiptNo = @receiptNo ORDER BY [Date] DESC", conn);
                cmd.Parameters.AddWithValue("@receiptNo", receiptNo);

                var result = cmd.ExecuteScalar();
                if (result != null && result != DBNull.Value)
                {
                    transactionDate = Convert.ToDateTime(result);
                    return true;
                }
            }
            catch
            {
                return false;
            }

            return false;
        }

        private List<ReturnItemSelectionForm.ReturnItem> LoadReturnableItems(string receiptNo)
        {
            var items = new List<ReturnItemSelectionForm.ReturnItem>();

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                conn.Open();

                string query = @"SELECT ItemCode, Description, Quantity, Price, GrossAmount, NetAmount
                                 FROM ItemLedgerEntry
                                 WHERE DocumentType = 'SALES' AND DocumentNo = @docNo
                                 ORDER BY ID";

                using (var cmd = new SqlCommand(query, conn))
                {
                    cmd.Parameters.AddWithValue("@docNo", receiptNo);
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read())
                        {
                            string itemCode = rdr["ItemCode"]?.ToString() ?? string.Empty;
                            string description = rdr["Description"]?.ToString() ?? itemCode;
                            int qty = rdr["Quantity"] != DBNull.Value ? Convert.ToInt32(rdr["Quantity"]) : 0;
                            qty = Math.Abs(qty);

                            decimal unitPrice = rdr["Price"] != DBNull.Value ? Convert.ToDecimal(rdr["Price"]) : 0m;
                            decimal grossAmount = rdr["GrossAmount"] != DBNull.Value ? Convert.ToDecimal(rdr["GrossAmount"]) : 0m;
                            decimal netAmount = rdr["NetAmount"] != DBNull.Value ? Convert.ToDecimal(rdr["NetAmount"]) : 0m;
                            decimal lineAmount = netAmount != 0m ? Math.Abs(netAmount)
                                : (grossAmount != 0m ? Math.Abs(grossAmount) : Math.Abs(unitPrice * qty));

                            if (qty <= 0)
                                continue;

                            items.Add(new ReturnItemSelectionForm.ReturnItem
                            {
                                ItemCode = itemCode,
                                Description = description,
                                Quantity = qty,
                                QuantityToReturn = 0,
                                UnitPrice = unitPrice,
                                LineAmount = lineAmount
                            });
                        }
                    }
                }
            }

            return items;
        }

        private void PrintReversalReceipt(string originalReceiptNo)
        {
            if (string.IsNullOrWhiteSpace(originalReceiptNo))
                throw new ArgumentException("Receipt number is required.", nameof(originalReceiptNo));

            string returnDocNo = originalReceiptNo + "-REV";
            string line = new string('-', GlobalSettings.ReceiptWidth);
            var receipt = new System.Text.StringBuilder();

            receipt.AppendLine("      RS PET STOP");
            receipt.AppendLine("  AQUARIUM PRODUCTS");
            receipt.AppendLine("   & SOLUTIONS");
            receipt.AppendLine(line);
            receipt.AppendLine("*** RETURN / EXCHANGE ***");
            receipt.AppendLine($"Date: {DateTime.Now:yyyy-MM-dd HH:mm}");
            receipt.AppendLine($"Orig Receipt #: {originalReceiptNo}");
            receipt.AppendLine($"Return Ref #: {returnDocNo}");
            receipt.AppendLine(line);

            var lines = new List<string>();
            decimal totalReturnAmount = 0m;

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                conn.Open();
                // IMPORTANT: print using the original SALES price/amount columns so the receipt matches the refund value.
                // REVERSAL rows store stock/cost reversal; those amounts may not represent the customer refund.
                string query = @"SELECT ItemCode, Description, Quantity, Price, Discount, GrossAmount, NetAmount
                                 FROM ItemLedgerEntry
                                 WHERE DocumentType = 'SALES' AND DocumentNo = @docNo
                                 ORDER BY ID";

                using (var cmd = new SqlCommand(query, conn))
                {
                    cmd.Parameters.AddWithValue("@docNo", originalReceiptNo);
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read())
                        {
                            string desc = rdr["Description"]?.ToString() ?? rdr["ItemCode"]?.ToString() ?? "";
                            int qty = rdr["Quantity"] != DBNull.Value ? Convert.ToInt32(rdr["Quantity"]) : 0;
                            qty = Math.Abs(qty);
                            decimal price = rdr["Price"] != DBNull.Value ? Convert.ToDecimal(rdr["Price"]) : 0m;
                            decimal grossAmount = rdr["GrossAmount"] != DBNull.Value ? Convert.ToDecimal(rdr["GrossAmount"]) : 0m;
                            decimal netAmount = rdr["NetAmount"] != DBNull.Value ? Convert.ToDecimal(rdr["NetAmount"]) : 0m;

                            decimal lineAmount;
                            if (netAmount != 0m)
                                lineAmount = Math.Abs(netAmount);
                            else if (grossAmount != 0m)
                                lineAmount = Math.Abs(grossAmount);
                            else
                                lineAmount = Math.Abs(qty * price);

                            totalReturnAmount += lineAmount;

                            int wrapWidth = 14;
                            for (int i = 0; i < desc.Length; i += wrapWidth)
                            {
                                string descLine = desc.Substring(i, Math.Min(wrapWidth, desc.Length - i));
                                if (i == 0)
                                    lines.Add($"{descLine,-12} {qty,-3} {lineAmount,8:N2}");
                                else
                                    lines.Add($"{descLine,-12}");
                            }
                        }
                    }
                }
            }

            if (lines.Count == 0)
            {
                receipt.AppendLine("No return lines found.");
                receipt.AppendLine(line);
            }
            else
            {
                receipt.AppendLine("ITEMS RETURNED:");
                receipt.AppendLine($"{"Item",-12} {"Qty",-3} {"Amount",-8}");
                receipt.AppendLine(line);
                foreach (var l in lines) receipt.AppendLine(l);
                receipt.AppendLine(line);
                receipt.AppendLine();
                receipt.AppendLine($"RETURN TOTAL: {totalReturnAmount:N2}");
                receipt.AppendLine(line);
            }

            receipt.AppendLine();
            receipt.AppendLine("    THANK YOU!");
            receipt.AppendLine(line);

            using var printDocument = new PrintDocument();
            using var printFont = new Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);
            string receiptContent = receipt.ToString();

            printDocument.DefaultPageSettings.PaperSize = new PaperSize("58mm",
                (int)(GlobalSettings.PaperWidthInches * 100),
                (int)(GlobalSettings.PaperHeightInches * 100));
            printDocument.DefaultPageSettings.Margins = new Margins(
                (int)(GlobalSettings.LeftMarginInches * 100),
                (int)(GlobalSettings.LeftMarginInches * 100),
                (int)(GlobalSettings.TopMarginInches * 100),
                (int)(GlobalSettings.TopMarginInches * 100));

            printDocument.PrintPage += (s, e) =>
            {
                if (e.Graphics == null) return;

                float yPos = e.MarginBounds.Top;
                float leftMargin = e.MarginBounds.Left;
                float lineHeight = printFont.GetHeight(e.Graphics);
                string[] contentLines = receiptContent.Split('\n');

                foreach (string l in contentLines)
                {
                    if (yPos + lineHeight > e.MarginBounds.Bottom)
                    {
                        e.HasMorePages = true;
                        return;
                    }

                    string clipped = l.TrimEnd('\r');
                    if (clipped.Length > GlobalSettings.ReceiptWidth)
                        clipped = clipped.Substring(0, GlobalSettings.ReceiptWidth);

                    e.Graphics.DrawString(clipped, printFont, Brushes.Black, leftMargin, yPos);
                    yPos += lineHeight;
                }

                e.HasMorePages = false;
            };

            printDocument.Print();
        }

        private void BtnPayCommission_Click(object? sender, EventArgs e)
        {
            if (dgvTransactions == null)
            {
                MessageBox.Show("Transactions grid not available.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (dgvTransactions.SelectedRows.Count == 0)
            {
                MessageBox.Show("Please select a transaction first.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var selectedRow = dgvTransactions.SelectedRows[0];
            string selectedReceiptNo = selectedRow.Cells["ReceiptNo"]?.Value?.ToString() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(selectedReceiptNo))
            {
                MessageBox.Show("Selected transaction does not have a Receipt No.", "Invalid Selection", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string selectedType = selectedRow.Cells["Type"]?.Value?.ToString() ?? string.Empty;
            bool isSales = string.Equals(selectedType, "SALES", StringComparison.OrdinalIgnoreCase);
            bool isExpense = string.Equals(selectedType, "EXPENSE", StringComparison.OrdinalIgnoreCase);
            if (!isSales && !isExpense)
            {
                MessageBox.Show("Please select either a SALES receipt (to find its commission EXPENSE) or select the commission EXPENSE directly.", "Pay Comission",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            try
            {
                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    // If user selected SALES, find the latest linked commission EXPENSE.
                    // If user selected EXPENSE, use it directly.
                    string? expenseReceiptNo = null;
                    decimal expenseAmount = 0m;
                    string expenseStatus = "ACTIVE";
                    string? linkedSalesReceiptNo = null;

                    if (isSales)
                    {
                        linkedSalesReceiptNo = selectedReceiptNo;
                        string findExpenseQuery = @"
                            SELECT TOP 1 ReceiptNo, ISNULL(Price, 0) AS Amount, ISNULL(Status, 'ACTIVE') AS Status,
                                   ISNULL(Description, '') AS Description
                            FROM TransactionHeader
                            WHERE Type = 'EXPENSE'
                              AND Description LIKE '%' + @link + '%'
                            ORDER BY TransactionNo DESC";

                        string linkToken = $"Sales Receipt: {selectedReceiptNo}";
                        using (SqlCommand cmd = new SqlCommand(findExpenseQuery, connection))
                        {
                            cmd.Parameters.AddWithValue("@link", linkToken);
                            using (SqlDataReader reader = cmd.ExecuteReader())
                            {
                                if (reader.Read())
                                {
                                    expenseReceiptNo = reader["ReceiptNo"]?.ToString();
                                    expenseAmount = reader["Amount"] != DBNull.Value ? Convert.ToDecimal(reader["Amount"]) : 0m;
                                    expenseStatus = reader["Status"]?.ToString() ?? "ACTIVE";
                                }
                            }
                        }
                    }
                    else // EXPENSE selected
                    {
                        expenseReceiptNo = selectedReceiptNo;

                        string getExpenseInfoQuery = @"
                            SELECT TOP 1 ISNULL(Price, 0) AS Amount,
                                   ISNULL(Status, 'ACTIVE') AS Status,
                                   ISNULL(Description, '') AS Description
                            FROM TransactionHeader
                            WHERE ReceiptNo = @receiptNo AND Type = 'EXPENSE'
                            ORDER BY TransactionNo DESC";

                        string description = "";
                        using (SqlCommand cmd = new SqlCommand(getExpenseInfoQuery, connection))
                        {
                            cmd.Parameters.AddWithValue("@receiptNo", expenseReceiptNo);
                            using (var reader = cmd.ExecuteReader())
                            {
                                if (reader.Read())
                                {
                                    expenseAmount = reader["Amount"] != DBNull.Value ? Convert.ToDecimal(reader["Amount"]) : 0m;
                                    expenseStatus = reader["Status"]?.ToString() ?? "ACTIVE";
                                    description = reader["Description"]?.ToString() ?? "";
                                }
                            }
                        }

                        // Safety: prevent accidentally paying unrelated expenses.
                        // Commission expenses can be identified by the token written during posting.
                        if (!IsCommissionExpenseDescription(description))
                        {
                            MessageBox.Show(
                                "Selected EXPENSE does not look like a commission expense.\n\n" +
                                "Tip: Select the SALES receipt (recommended) or select the EXPENSE that contains 'Sales Receipt:' / 'COMMISSION' in Description.",
                                "Pay Comission",
                                MessageBoxButtons.OK,
                                MessageBoxIcon.Information);
                            return;
                        }

                        // Best-effort: parse "Sales Receipt: RS-0000000001" out of Description if present.
                        linkedSalesReceiptNo = TryParseLinkedSalesReceiptNo(description);
                    }

                    if (string.IsNullOrWhiteSpace(expenseReceiptNo))
                    {
                        MessageBox.Show("No commission EXPENSE transaction found.", "Pay Comission",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }

                    // If the EXPENSE already has payment entries, do not allow paying again.
                    // This is a stronger guard than Status=PAID (some older DBs might not have Status set correctly).
                    try
                    {
                        using (var checkPaidCmd = new SqlCommand(
                            "SELECT TOP 1 1 FROM TransPaymentEntry WHERE ReceiptNo = @receiptNo", connection))
                        {
                            checkPaidCmd.Parameters.AddWithValue("@receiptNo", expenseReceiptNo);
                            var alreadyHasPayment = checkPaidCmd.ExecuteScalar() != null;
                            if (alreadyHasPayment)
                            {
                                MessageBox.Show(
                                    $"This expense already has Payment Entries.\n\nExpense Receipt: {expenseReceiptNo}",
                                    "Pay Comission",
                                    MessageBoxButtons.OK,
                                    MessageBoxIcon.Information);
                                return;
                            }
                        }
                    }
                    catch
                    {
                        // If the check fails (e.g., table missing), don't block payout.
                    }

                    if (string.Equals(expenseStatus, "PAID", StringComparison.OrdinalIgnoreCase))
                    {
                        MessageBox.Show($"Commission already paid.\nExpense Receipt: {expenseReceiptNo}", "Pay Comission",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }

                    if (expenseAmount <= 0m)
                    {
                        MessageBox.Show("Commission expense amount is 0. Nothing to pay.", "Pay Comission",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }

                    if (MessageBox.Show(
                        $"Pay commission now?\n\nSales Receipt: {(string.IsNullOrWhiteSpace(linkedSalesReceiptNo) ? "(unknown)" : linkedSalesReceiptNo)}\nExpense Receipt: {expenseReceiptNo}\nAmount: {expenseAmount:C2}",
                        "Confirm Pay Comission",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Question) != DialogResult.Yes)
                    {
                        return;
                    }

                    // Let user choose tender type used to pay commission.
                    // We store the selected TenderTypeCode in TransPaymentEntry.
                    var tenderTypeCode = ShowTenderTypePicker(connection);
                    if (string.IsNullOrWhiteSpace(tenderTypeCode))
                    {
                        // User cancelled
                        return;
                    }

                    var paidAt = DateTime.Now;

                    using (SqlTransaction tx = connection.BeginTransaction())
                    {
                        try
                        {
                            // Insert a matching payment entry to mark the commission EXPENSE as paid.
                            // Use TenderTypeCode='CASH' for now, since commissions are usually paid from cash.
                            string getExpenseTransNoQuery = @"SELECT TOP 1 TransactionNo FROM TransactionHeader WHERE ReceiptNo = @receiptNo";
                            string expenseTransNo = "";

                            using (SqlCommand getTransNoCmd = new SqlCommand(getExpenseTransNoQuery, connection, tx))
                            {
                                getTransNoCmd.Parameters.AddWithValue("@receiptNo", expenseReceiptNo);
                                var res = getTransNoCmd.ExecuteScalar();
                                expenseTransNo = res?.ToString() ?? "";
                            }

                            if (string.IsNullOrWhiteSpace(expenseTransNo))
                                expenseTransNo = "0";

                            string getNextLineNoQuery = @"SELECT ISNULL(MAX([LineNo]), 0) + 1 FROM TransPaymentEntry WHERE ReceiptNo = @receiptNo";
                            int nextLineNo = 1;
                            using (SqlCommand lnCmd = new SqlCommand(getNextLineNoQuery, connection, tx))
                            {
                                lnCmd.Parameters.AddWithValue("@receiptNo", expenseReceiptNo);
                                nextLineNo = Convert.ToInt32(lnCmd.ExecuteScalar() ?? 1);
                            }

                            string insertPaymentQuery = @"
                                INSERT INTO TransPaymentEntry
                                    (StoreNo, POSTerminalNo, TransactionNo, TenderTypeCode, [LineNo], ReceiptNo, Description, Amount, UserID, Date, Time, CreatedDate, Status)
                                VALUES
                                    (@storeNo, @posTerminalNo, @transactionNo, @tenderTypeCode, @lineNo, @receiptNo, @description, @amount, @userID, @date, @time, @createdDate, @status)";

                            using (SqlCommand payCmd = new SqlCommand(insertPaymentQuery, connection, tx))
                            {
                                payCmd.Parameters.AddWithValue("@storeNo", "001");
                                payCmd.Parameters.AddWithValue("@posTerminalNo", "001");
                                payCmd.Parameters.AddWithValue("@transactionNo", expenseTransNo);
                                payCmd.Parameters.AddWithValue("@tenderTypeCode", tenderTypeCode);
                                payCmd.Parameters.AddWithValue("@lineNo", nextLineNo);
                                payCmd.Parameters.AddWithValue("@receiptNo", expenseReceiptNo);
                                    payCmd.Parameters.AddWithValue("@description", expenseReceiptNo ?? (object)DBNull.Value);
                                payCmd.Parameters.AddWithValue("@amount", expenseAmount);
                                payCmd.Parameters.AddWithValue("@userID", CurrentUser.Username ?? "POS_SYSTEM");
                                payCmd.Parameters.AddWithValue("@date", paidAt.Date);
                                payCmd.Parameters.AddWithValue("@time", paidAt.TimeOfDay);
                                payCmd.Parameters.AddWithValue("@createdDate", paidAt);
                                payCmd.Parameters.AddWithValue("@status", "PAID");
                                payCmd.ExecuteNonQuery();
                            }

                            // Mark the commission EXPENSE header as paid too.
                            string updateExpenseStatusQuery = @"UPDATE TransactionHeader SET Status = 'PAID' WHERE ReceiptNo = @receiptNo";
                            using (SqlCommand updCmd = new SqlCommand(updateExpenseStatusQuery, connection, tx))
                            {
                                updCmd.Parameters.AddWithValue("@receiptNo", expenseReceiptNo);
                                updCmd.ExecuteNonQuery();
                            }

                            tx.Commit();
                        }
                        catch
                        {
                            tx.Rollback();
                            throw;
                        }
                    }

                    // Print a simple payout confirmation receipt.
                    // Non-blocking: printing errors should not affect the DB commit above.
                    try
                    {
                        PrintCommissionPaidReceipt(
                            salesReceiptNo: linkedSalesReceiptNo ?? "",
                            expenseReceiptNo: expenseReceiptNo,
                            amount: expenseAmount,
                            tenderTypeCode: tenderTypeCode,
                            paidAt: paidAt,
                            paidByUser: CurrentUser.Username ?? "POS_SYSTEM");
                    }
                    catch
                    {
                        // ignore print errors
                    }
                }

                MessageBox.Show("Commission marked as PAID.", "Pay Comission", MessageBoxButtons.OK, MessageBoxIcon.Information);
                LoadTransactions();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error paying commission: {ex.Message}", "Pay Comission",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void PrintCommissionPaidReceipt(string salesReceiptNo, string expenseReceiptNo, decimal amount, string tenderTypeCode, DateTime paidAt, string paidByUser)
        {
            string line = new string('-', GlobalSettings.ReceiptWidth);
            var receipt = new System.Text.StringBuilder();

            receipt.AppendLine("      RS PET STOP");
            receipt.AppendLine("  AQUARIUM PRODUCTS");
            receipt.AppendLine("   & SOLUTIONS");
            receipt.AppendLine(line);
            receipt.AppendLine("   COMMISSION PAID");
            receipt.AppendLine(line);
            receipt.AppendLine($"Date: {paidAt:yyyy-MM-dd HH:mm}");
            receipt.AppendLine($"Paid By: {paidByUser}");
            receipt.AppendLine(line);
            if (!string.IsNullOrWhiteSpace(salesReceiptNo))
                receipt.AppendLine($"Sales Receipt: {salesReceiptNo}");
            receipt.AppendLine($"Expense Rcpt: {expenseReceiptNo}");
            receipt.AppendLine($"Tender: {tenderTypeCode}");
            receipt.AppendLine($"Amount: P{amount:N2}");
            receipt.AppendLine(line);
            receipt.AppendLine("   THANK YOU!");
            receipt.AppendLine(line);

            using var printDocument = new PrintDocument();
            using var printFont = new Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);
            string receiptContent = receipt.ToString();

            // Configure to match MainForm's 58mm configuration
            printDocument.DefaultPageSettings.PaperSize = new PaperSize("58mm",
                (int)(GlobalSettings.PaperWidthInches * 100),
                (int)(GlobalSettings.PaperHeightInches * 100));
            printDocument.DefaultPageSettings.Margins = new Margins(
                (int)(GlobalSettings.LeftMarginInches * 100),
                (int)(GlobalSettings.LeftMarginInches * 100),
                (int)(GlobalSettings.TopMarginInches * 100),
                (int)(GlobalSettings.TopMarginInches * 100));

            printDocument.PrintPage += (s, e) =>
            {
                if (e.Graphics == null) return;

                float yPos = e.MarginBounds.Top;
                float leftMargin = e.MarginBounds.Left;
                float lineHeight = printFont.GetHeight(e.Graphics);
                string[] lines = receiptContent.Split('\n');

                foreach (string l in lines)
                {
                    if (yPos + lineHeight > e.MarginBounds.Bottom)
                    {
                        e.HasMorePages = true;
                        return;
                    }

                    string clipped = l.TrimEnd('\r');
                    if (clipped.Length > GlobalSettings.ReceiptWidth)
                        clipped = clipped.Substring(0, GlobalSettings.ReceiptWidth);

                    e.Graphics.DrawString(clipped, printFont, Brushes.Black, leftMargin, yPos);
                    yPos += lineHeight;
                }

                e.HasMorePages = false;
            };

            printDocument.Print();
        }

        private static string? TryParseLinkedSalesReceiptNo(string? description)
        {
            if (string.IsNullOrWhiteSpace(description))
                return null;

            const string token = "Sales Receipt:";
            int idx = description.IndexOf(token, StringComparison.OrdinalIgnoreCase);
            if (idx < 0)
                return null;

            string after = description.Substring(idx + token.Length).Trim();
            if (string.IsNullOrWhiteSpace(after))
                return null;

            // Stop at ')', ',', or whitespace-run
            int end = after.IndexOfAny(new[] { ')', ',', ';', '\n', '\r' });
            if (end >= 0)
                after = after.Substring(0, end);

            // Often the receipt has no spaces; take first token.
            string candidate = after.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            candidate = candidate.Trim();

            return string.IsNullOrWhiteSpace(candidate) ? null : candidate;
        }

        private static bool IsCommissionExpenseDescription(string? description)
        {
            if (string.IsNullOrWhiteSpace(description))
                return false;

            // Accept either the explicit tag or just the word COMMISSION.
            // Also accept the presence of the link token used to associate it to a sale.
            return description.IndexOf("COMMISSION_EXPENSE", StringComparison.OrdinalIgnoreCase) >= 0
                || description.IndexOf("COMMISSION", StringComparison.OrdinalIgnoreCase) >= 0
                || description.IndexOf("Sales Receipt:", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private string? ShowTenderTypePicker(SqlConnection openConnection)
        {
            try
            {
                // Load tender types from DB (exclude ADVANCEORDERS; that's not a payment tender for payouts).
                var tenderTypes = new List<(string Code, string Description)>();
                using (var cmd = new SqlCommand("SELECT Code, Description FROM TenderTypes WHERE Code <> 'ADVANCEORDERS' ORDER BY Code", openConnection))
                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        string code = reader["Code"]?.ToString() ?? string.Empty;
                        string desc = reader["Description"]?.ToString() ?? string.Empty;
                        if (!string.IsNullOrWhiteSpace(code))
                            tenderTypes.Add((code.Trim(), desc.Trim()));
                    }
                }

                // Fallback if table is empty or query fails.
                if (tenderTypes.Count == 0)
                {
                    var result = Microsoft.VisualBasic.Interaction.InputBox(
                        "Enter tender type code to pay commission (e.g., CASH / GCASH / BANK):",
                        "Tender Type",
                        "CASH");
                    return string.IsNullOrWhiteSpace(result) ? null : result.Trim();
                }

                // Simple selection form
                using (var picker = new Form())
                {
                    picker.Text = "Select Tender Type";
                    picker.StartPosition = FormStartPosition.CenterParent;
                    picker.FormBorderStyle = FormBorderStyle.FixedDialog;
                    picker.MaximizeBox = false;
                    picker.MinimizeBox = false;
                    picker.Size = new Size(420, 420);

                    var list = new ListBox();
                    list.Dock = DockStyle.Top;
                    list.Height = 300;
                    list.Font = new Font("Arial", 12);
                    foreach (var t in tenderTypes)
                    {
                        string display = string.IsNullOrWhiteSpace(t.Description)
                            ? t.Code
                            : $"{t.Code} - {t.Description}";
                        list.Items.Add(display);
                    }
                    if (list.Items.Count > 0) list.SelectedIndex = 0;

                    var btnOk = new Button();
                    btnOk.Text = "OK";
                    btnOk.Width = 100;
                    btnOk.Height = 40;
                    btnOk.Location = new Point(200, 320);
                    btnOk.DialogResult = DialogResult.OK;

                    var btnCancel = new Button();
                    btnCancel.Text = "Cancel";
                    btnCancel.Width = 100;
                    btnCancel.Height = 40;
                    btnCancel.Location = new Point(90, 320);
                    btnCancel.DialogResult = DialogResult.Cancel;

                    picker.Controls.Add(list);
                    picker.Controls.Add(btnOk);
                    picker.Controls.Add(btnCancel);
                    picker.AcceptButton = btnOk;
                    picker.CancelButton = btnCancel;

                    var dr = picker.ShowDialog(this);
                    if (dr != DialogResult.OK)
                        return null;

                    if (list.SelectedItem == null)
                        return null;

                    // Code is always before first ' - '
                    var selected = list.SelectedItem.ToString() ?? "";
                    var codeOnly = selected.Split(new[] { " - " }, StringSplitOptions.None)[0].Trim();
                    return string.IsNullOrWhiteSpace(codeOnly) ? null : codeOnly;
                }
            }
            catch
            {
                // Ultimate fallback: just ask for text
                try
                {
                    var result = Microsoft.VisualBasic.Interaction.InputBox(
                        "Enter tender type code to pay commission (e.g., CASH / GCASH / BANK):",
                        "Tender Type",
                        "CASH");
                    return string.IsNullOrWhiteSpace(result) ? null : result.Trim();
                }
                catch
                {
                    return "CASH";
                }
            }
        }

        // Opens the payment entries view filtered by selected transaction
        private void BtnPaymentEntries_Click(object? sender, EventArgs e)
        {
            // Find the MainForm instance from the open forms
            var mainForm = Application.OpenForms.OfType<MainForm>().FirstOrDefault();
            if (mainForm != null)
            {
                string receiptNo = "";
                if (dgvTransactions != null && dgvTransactions.SelectedRows.Count > 0)
                {
                    var selectedRow = dgvTransactions.SelectedRows[0];
                    receiptNo = selectedRow.Cells["ReceiptNo"].Value?.ToString() ?? "";
                }
                mainForm.ShowTransPaymentEntryForm(receiptNo);
            }
            else
            {
                MessageBox.Show("MainForm is not available.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }


        private void LoadTransactions()
        {
            try
            {
                // Ensure DataGridView is initialized
                if (dgvTransactions == null)
                {
                    MessageBox.Show("DataGridView not initialized.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    // First check if the table exists
                    string checkTableQuery = @"SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES 
                                             WHERE TABLE_NAME = 'TransactionHeader'";
                    SqlCommand checkCmd = new SqlCommand(checkTableQuery, connection);
                    int tableExists = (int)checkCmd.ExecuteScalar();

                    if (tableExists == 0)
                    {
                        // Table doesn't exist, show message and create empty grid
                        MessageBox.Show("TransactionHeader table does not exist yet. Please restart the application to create the table.",
                                      "Table Not Found", MessageBoxButtons.OK, MessageBoxIcon.Information);

                        // Create empty DataTable with proper columns
                        DataTable emptyTable = new DataTable();
                        emptyTable.Columns.Add("StoreNo", typeof(int));
                        emptyTable.Columns.Add("POSTerminalNo", typeof(int));
                        emptyTable.Columns.Add("TransactionNo", typeof(int));
                        emptyTable.Columns.Add("ReceiptNo", typeof(string));
                        emptyTable.Columns.Add("Type", typeof(string));
                        // emptyTable.Columns.Add("Quantity", typeof(decimal));
                        emptyTable.Columns.Add("Price", typeof(decimal));
                        emptyTable.Columns.Add("Discount", typeof(decimal));
                        emptyTable.Columns.Add("GrossAmount", typeof(decimal));
                        emptyTable.Columns.Add("NetAmount", typeof(decimal));
                        emptyTable.Columns.Add("Date", typeof(DateOnly));
                        emptyTable.Columns.Add("Time", typeof(string));
                        emptyTable.Columns.Add("UserID", typeof(string));
                        emptyTable.Columns.Add("Description", typeof(string));
                        emptyTable.Columns.Add("ExpenseCategory", typeof(string));
                        emptyTable.Columns.Add("Status", typeof(string));

                        dgvTransactions.DataSource = emptyTable;
                        FormatGridColumns();
                        return;
                    }

                    // Check if Status column exists, if not include it with default value
                    string statusColumnQuery = @"SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS 
                                               WHERE TABLE_NAME = 'TransactionHeader' AND COLUMN_NAME = 'Status'";
                    SqlCommand statusCmd = new SqlCommand(statusColumnQuery, connection);
                    int statusColumnExists = (int)statusCmd.ExecuteScalar();

                    string expenseCategoryColumnQuery = @"SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS 
                                               WHERE TABLE_NAME = 'TransactionHeader' AND COLUMN_NAME = 'ExpenseCategory'";
                    SqlCommand expenseCategoryCmd = new SqlCommand(expenseCategoryColumnQuery, connection);
                    int expenseCategoryColumnExists = (int)expenseCategoryCmd.ExecuteScalar();

                    string query = @"SELECT 
                                        StoreNo, 
                                        POSTerminalNo, 
                                        TransactionNo, 
                                        ReceiptNo, 
                                        Type, 
                                        Quantity, 
                                        Price, 
                                        Discount, 
                                        GrossAmount, 
                                        NetAmount, 
                                        Date, 
                                        CASE 
                                            WHEN Time IS NULL THEN ''
                                            ELSE FORMAT(CAST(Time AS datetime), 'h:mm:ss tt')
                                        END AS Time, 
                                        UserID, 
                                        Description" +
                                    (expenseCategoryColumnExists > 0 ? ", ISNULL(ExpenseCategory, '') AS ExpenseCategory" : ", '' AS ExpenseCategory") +
                                    (statusColumnExists > 0 ? ", ISNULL(Status, 'ACTIVE') AS Status" : ", 'ACTIVE' AS Status") +
                                    @" FROM TransactionHeader 
                                    ORDER BY TransactionNo DESC";

                    SqlDataAdapter adapter = new SqlDataAdapter(query, connection);
                    DataTable dataTable = new DataTable();
                    adapter.Fill(dataTable);
                    dgvTransactions.DataSource = dataTable;

                    // Format columns
                    FormatGridColumns();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading transactions: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void FormatGridColumns()
        {
            if (dgvTransactions?.DataSource == null) return;
            // Make grid more readable: larger font and row height
            try
            {
                dgvTransactions.ColumnHeadersDefaultCellStyle.Font = new Font("Arial", 10, FontStyle.Bold);
                dgvTransactions.DefaultCellStyle.Font = new Font("Arial", 10);
                dgvTransactions.RowTemplate.Height = 28;
                dgvTransactions.AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.None;
            }
            catch { }

            // Hide housekeeping columns that aren't useful in the list view
            if (dgvTransactions.Columns.Contains("StoreNo"))
                dgvTransactions.Columns["StoreNo"].Visible = false;
            if (dgvTransactions.Columns.Contains("POSTerminalNo"))
                dgvTransactions.Columns["POSTerminalNo"].Visible = false;

            if (dgvTransactions.Columns.Contains("TransactionNo"))
            {
                dgvTransactions.Columns["TransactionNo"].HeaderText = "Trans #";
                dgvTransactions.Columns["TransactionNo"].Width = 90;
                dgvTransactions.Columns["TransactionNo"].MinimumWidth = 80;
                dgvTransactions.Columns["TransactionNo"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleCenter;
                dgvTransactions.Columns["TransactionNo"].FillWeight = 40f;
            }

            // Set column headers and widths
            if (dgvTransactions.Columns.Contains("ReceiptNo"))
            {
                dgvTransactions.Columns["ReceiptNo"].HeaderText = "Receipt No";
                dgvTransactions.Columns["ReceiptNo"].Width = 140;
                dgvTransactions.Columns["ReceiptNo"].MinimumWidth = 120;
                dgvTransactions.Columns["ReceiptNo"].FillWeight = 90f;
            }

            if (dgvTransactions.Columns.Contains("Type"))
            {
                dgvTransactions.Columns["Type"].HeaderText = "Type";
                dgvTransactions.Columns["Type"].Width = 110;
                dgvTransactions.Columns["Type"].MinimumWidth = 100;
                dgvTransactions.Columns["Type"].FillWeight = 50f;
            }

            if (dgvTransactions.Columns.Contains("Quantity"))
            {
                dgvTransactions.Columns["Quantity"].HeaderText = "Qty";
                // Hide quantity column to make room for Status column
                dgvTransactions.Columns["Quantity"].Visible = false;
                dgvTransactions.Columns["Quantity"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            }

            if (dgvTransactions.Columns.Contains("Price"))
            {
                dgvTransactions.Columns["Price"].HeaderText = "Price";
                dgvTransactions.Columns["Price"].Width = 100;
                dgvTransactions.Columns["Price"].MinimumWidth = 90;
                dgvTransactions.Columns["Price"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                dgvTransactions.Columns["Price"].DefaultCellStyle.Format = "C2";
                dgvTransactions.Columns["Price"].DefaultCellStyle.FormatProvider = new CultureInfo("en-PH");
                dgvTransactions.Columns["Price"].FillWeight = 60f;
            }

            if (dgvTransactions.Columns.Contains("Discount"))
            {
                dgvTransactions.Columns["Discount"].HeaderText = "Discount";
                dgvTransactions.Columns["Discount"].Width = 90;
                dgvTransactions.Columns["Discount"].MinimumWidth = 80;
                dgvTransactions.Columns["Discount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                dgvTransactions.Columns["Discount"].DefaultCellStyle.Format = "C2";
                dgvTransactions.Columns["Discount"].DefaultCellStyle.FormatProvider = new CultureInfo("en-PH");
                dgvTransactions.Columns["Discount"].FillWeight = 50f;
            }

            if (dgvTransactions.Columns.Contains("GrossAmount"))
            {
                dgvTransactions.Columns["GrossAmount"].HeaderText = "Gross";
                dgvTransactions.Columns["GrossAmount"].Width = 100;
                dgvTransactions.Columns["GrossAmount"].MinimumWidth = 90;
                dgvTransactions.Columns["GrossAmount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                dgvTransactions.Columns["GrossAmount"].DefaultCellStyle.Format = "C2";
                dgvTransactions.Columns["GrossAmount"].DefaultCellStyle.FormatProvider = new CultureInfo("en-PH");
                dgvTransactions.Columns["GrossAmount"].FillWeight = 60f;
            }

            if (dgvTransactions.Columns.Contains("NetAmount"))
            {
                dgvTransactions.Columns["NetAmount"].HeaderText = "Net Amount";
                dgvTransactions.Columns["NetAmount"].Width = 110;
                dgvTransactions.Columns["NetAmount"].MinimumWidth = 100;
                dgvTransactions.Columns["NetAmount"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                dgvTransactions.Columns["NetAmount"].DefaultCellStyle.Format = "C2";
                dgvTransactions.Columns["NetAmount"].DefaultCellStyle.FormatProvider = new CultureInfo("en-PH");
                dgvTransactions.Columns["NetAmount"].FillWeight = 80f;
            }

            if (dgvTransactions.Columns.Contains("Date"))
            {
                dgvTransactions.Columns["Date"].HeaderText = "Date";
                dgvTransactions.Columns["Date"].Width = 110;
                dgvTransactions.Columns["Date"].MinimumWidth = 100;
                dgvTransactions.Columns["Date"].DefaultCellStyle.Format = "MM/dd/yyyy";
                dgvTransactions.Columns["Date"].FillWeight = 40f;
            }

            if (dgvTransactions.Columns.Contains("Time"))
            {
                dgvTransactions.Columns["Time"].HeaderText = "Time";
                dgvTransactions.Columns["Time"].Width = 90;
                dgvTransactions.Columns["Time"].MinimumWidth = 80;
                dgvTransactions.Columns["Time"].FillWeight = 30f;
            }

            if (dgvTransactions.Columns.Contains("UserID"))
            {
                dgvTransactions.Columns["UserID"].HeaderText = "User";
                dgvTransactions.Columns["UserID"].Width = 100;
                dgvTransactions.Columns["UserID"].MinimumWidth = 90;
                dgvTransactions.Columns["UserID"].FillWeight = 50f;
            }

            if (dgvTransactions.Columns.Contains("Description"))
            {
                dgvTransactions.Columns["Description"].HeaderText = "Description";
                // Make description the largest column so long texts are visible
                dgvTransactions.Columns["Description"].AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill;
                dgvTransactions.Columns["Description"].FillWeight = 300f;
                dgvTransactions.Columns["Description"].MinimumWidth = 300;
                dgvTransactions.Columns["Description"].DefaultCellStyle.WrapMode = DataGridViewTriState.False;
            }

            if (dgvTransactions.Columns.Contains("ExpenseCategory"))
            {
                dgvTransactions.Columns["ExpenseCategory"].HeaderText = "Expense Category";
                dgvTransactions.Columns["ExpenseCategory"].Width = 180;
                dgvTransactions.Columns["ExpenseCategory"].MinimumWidth = 150;
                dgvTransactions.Columns["ExpenseCategory"].FillWeight = 90f;
                try { dgvTransactions.Columns["ExpenseCategory"].DisplayIndex = dgvTransactions.Columns["Description"].DisplayIndex + 1; } catch { }
            }

            if (dgvTransactions.Columns.Contains("Status"))
            {
                dgvTransactions.Columns["Status"].HeaderText = "Status";
                dgvTransactions.Columns["Status"].Width = 110;
                dgvTransactions.Columns["Status"].MinimumWidth = 90;
                dgvTransactions.Columns["Status"].Visible = true;
                // Bring Status near the end so it's visible
                try { dgvTransactions.Columns["Status"].DisplayIndex = Math.Max(0, dgvTransactions.Columns.Count - 2); } catch { }

                // Color-code status column
                foreach (DataGridViewRow row in dgvTransactions.Rows)
                {
                    if (row.Cells["Status"].Value?.ToString() == "REVERSED")
                    {
                        row.DefaultCellStyle.BackColor = Color.LightPink;
                        row.DefaultCellStyle.ForeColor = Color.DarkRed;
                    }
                }
            }
            // Adjust fill weights for other columns so Description retains the majority of space
            try
            {
                if (dgvTransactions.Columns.Contains("ReceiptNo")) dgvTransactions.Columns["ReceiptNo"].FillWeight = 90f;
                if (dgvTransactions.Columns.Contains("Type")) dgvTransactions.Columns["Type"].FillWeight = 50f;
                if (dgvTransactions.Columns.Contains("Quantity")) dgvTransactions.Columns["Quantity"].FillWeight = 30f;
                if (dgvTransactions.Columns.Contains("Price")) dgvTransactions.Columns["Price"].FillWeight = 70f;
                if (dgvTransactions.Columns.Contains("Discount")) dgvTransactions.Columns["Discount"].FillWeight = 50f;
                if (dgvTransactions.Columns.Contains("GrossAmount")) dgvTransactions.Columns["GrossAmount"].FillWeight = 60f;
                if (dgvTransactions.Columns.Contains("NetAmount")) dgvTransactions.Columns["NetAmount"].FillWeight = 100f;
                if (dgvTransactions.Columns.Contains("Date")) dgvTransactions.Columns["Date"].FillWeight = 40f;
                if (dgvTransactions.Columns.Contains("Time")) dgvTransactions.Columns["Time"].FillWeight = 30f;
                if (dgvTransactions.Columns.Contains("UserID")) dgvTransactions.Columns["UserID"].FillWeight = 50f;
                if (dgvTransactions.Columns.Contains("TransactionNo")) dgvTransactions.Columns["TransactionNo"].FillWeight = 40f;
                if (dgvTransactions.Columns.Contains("Status")) dgvTransactions.Columns["Status"].FillWeight = 30f;
            }
            catch
            {
                // ignore any runtime adjustments
            }
        }

        private void TxtSearch_TextChanged(object? sender, EventArgs e)
        {
            FilterTransactions();
        }

        private void BtnFilter_Click(object? sender, EventArgs e)
        {
            FilterTransactions();
        }

        private void FilterTransactions()
        {
            if (dgvTransactions?.DataSource == null) return;

            DataTable dataTable = (DataTable)dgvTransactions.DataSource;
            string filter = "";

            // Apply search filter
            if (!string.IsNullOrWhiteSpace(txtSearch?.Text))
            {
                string searchText = txtSearch.Text.Trim();
                filter += $"(ReceiptNo LIKE '%{searchText}%' OR " +
                         $"Type LIKE '%{searchText}%' OR " +
                         $"UserID LIKE '%{searchText}%' OR " +
                         $"Description LIKE '%{searchText}%')";
            }

            // Apply date range filter
            if (dtpFromDate != null && dtpToDate != null && dtpFromDate.Value.Date <= dtpToDate.Value.Date)
            {
                if (!string.IsNullOrEmpty(filter))
                    filter += " AND ";

                filter += $"Date >= #{dtpFromDate.Value.Date:yyyy-MM-dd}# AND Date <= #{dtpToDate.Value.Date:yyyy-MM-dd}#";
            }

            dataTable.DefaultView.RowFilter = filter;
        }

        private void BtnAdd_Click(object? sender, EventArgs e)
        {
            // Add new transaction functionality
            MessageBox.Show("Add new transaction functionality to be implemented.", "Information",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void BtnEdit_Click(object? sender, EventArgs e)
        {
            EditSelectedTransaction();
        }

        private void DgvTransactions_DoubleClick(object? sender, EventArgs e)
        {
            EditSelectedTransaction();
        }

        private void BtnReverse_Click(object? sender, EventArgs e)
        {
            if (dgvTransactions?.SelectedRows.Count > 0)
            {
                DataGridViewRow selectedRow = dgvTransactions.SelectedRows[0];
                string status = selectedRow.Cells["Status"].Value?.ToString() ?? "ACTIVE";

                if (status == "REVERSED")
                {
                    MessageBox.Show("This transaction has already been reversed.", "Already Reversed",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                if (MessageBox.Show("Are you sure you want to reverse this transaction? This will restore inventory quantities and create reversal entries.", "Confirm Reversal",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                {
                    try
                    {
                        string receiptNo = selectedRow.Cells["ReceiptNo"].Value?.ToString() ?? "";

                        if (string.IsNullOrEmpty(receiptNo))
                        {
                            MessageBox.Show("Cannot reverse transaction: Receipt number is missing.", "Error",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
                            return;
                        }

                        ReverseTransaction(receiptNo);
                        MessageBox.Show("Transaction reversed successfully.", "Success",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
                        LoadTransactions();
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show($"Error reversing transaction: {ex.Message}", "Error",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
            else
            {
                MessageBox.Show("Please select a transaction to reverse.", "No Selection",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void ReverseTransaction(string receiptNo)
        {
            string connectionString = GlobalSettings.ConnectionString;
            using (SqlConnection connection = new SqlConnection(connectionString))
            {
                connection.Open();
                using (SqlTransaction transaction = connection.BeginTransaction())
                {
                    try
                    {
                        // 1. Get all ItemLedgerEntry records for this receipt
                        string getLedgerQuery = @"SELECT ItemCode, Quantity, UnitCost, TotalCost, Description 
                                                FROM ItemLedgerEntry 
                                                WHERE DocumentType = 'SALES' AND DocumentNo = @receiptNo";

                        using (SqlCommand getLedgerCmd = new SqlCommand(getLedgerQuery, connection, transaction))
                        {
                            getLedgerCmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                            using (SqlDataReader reader = getLedgerCmd.ExecuteReader())
                            {
                                var ledgerEntries = new List<(string ItemCode, int Quantity, decimal UnitCost, decimal TotalCost, string Description)>();

                                while (reader.Read())
                                {
                                    ledgerEntries.Add((
                                        reader["ItemCode"].ToString() ?? "",
                                        Convert.ToInt32(reader["Quantity"]),
                                        Convert.ToDecimal(reader["UnitCost"]),
                                        Convert.ToDecimal(reader["TotalCost"]),
                                        reader["Description"].ToString() ?? ""
                                    ));
                                }

                                reader.Close();

                                // 2. Create reversal entries (positive quantities to offset negative sales)
                                foreach (var entry in ledgerEntries)
                                {
                                    // Create positive ItemLedgerEntry to reverse the negative sale
                                    string insertReversalQuery = @"INSERT INTO ItemLedgerEntry 
                                        (ItemCode, DocumentType, DocumentNo, Quantity, UnitCost, TotalCost, Description, UserID)
                                        VALUES (@itemCode, @docType, @docNo, @quantity, @unitCost, @totalCost, @description, @userID)";

                                    using (SqlCommand insertReversalCmd = new SqlCommand(insertReversalQuery, connection, transaction))
                                    {
                                        insertReversalCmd.Parameters.AddWithValue("@itemCode", entry.ItemCode);
                                        insertReversalCmd.Parameters.AddWithValue("@docType", "REVERSAL");
                                        insertReversalCmd.Parameters.AddWithValue("@docNo", receiptNo + "-REV");
                                        insertReversalCmd.Parameters.AddWithValue("@quantity", Math.Abs(entry.Quantity)); // Positive quantity
                                        insertReversalCmd.Parameters.AddWithValue("@unitCost", entry.UnitCost);
                                        insertReversalCmd.Parameters.AddWithValue("@totalCost", Math.Abs(entry.TotalCost)); // Positive cost
                                        insertReversalCmd.Parameters.AddWithValue("@description", $"Reversal of {entry.Description}");
                                        insertReversalCmd.Parameters.AddWithValue("@userID", CurrentUser.Username ?? "SYSTEM");

                                        insertReversalCmd.ExecuteNonQuery();
                                    }

                                    // 3. Restore inventory quantity (add back the sold quantity)
                                    string updateInventoryQuery = @"UPDATE Items 
                                                                  SET QuantityInStock = QuantityInStock + @quantity 
                                                                  WHERE Code = @itemCode";

                                    using (SqlCommand updateInventoryCmd = new SqlCommand(updateInventoryQuery, connection, transaction))
                                    {
                                        updateInventoryCmd.Parameters.AddWithValue("@quantity", Math.Abs(entry.Quantity));
                                        updateInventoryCmd.Parameters.AddWithValue("@itemCode", entry.ItemCode);
                                        updateInventoryCmd.ExecuteNonQuery();
                                    }
                                }
                            }
                        }

                        // 4. Mark the original transaction as reversed
                        string updateTransactionQuery = @"UPDATE TransactionHeader 
                                                        SET Status = 'REVERSED',
                                                            Description = CASE 
                                                                WHEN Description IS NULL OR Description = '' THEN 'REVERSED'
                                                                ELSE Description + ' - REVERSED'
                                                            END
                                                        WHERE ReceiptNo = @receiptNo";

                        using (SqlCommand updateTransactionCmd = new SqlCommand(updateTransactionQuery, connection, transaction))
                        {
                            updateTransactionCmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                            updateTransactionCmd.ExecuteNonQuery();
                        }

                        transaction.Commit();
                    }
                    catch
                    {
                        transaction.Rollback();
                        throw;
                    }
                }
            }
        }

        private void EditSelectedTransaction()
        {
            if (dgvTransactions?.SelectedRows.Count > 0)
            {
                try
                {
                    DataGridViewRow selectedRow = dgvTransactions.SelectedRows[0];
                    string receiptNo = selectedRow.Cells["ReceiptNo"].Value?.ToString() ?? "";
                    string type = selectedRow.Cells["Type"].Value?.ToString() ?? "";

                    if (type == "Float_Entry")
                    {
                        ShowFloatEntryLines(receiptNo);
                    }
                    else if (type == "TenderDecl")
                    {
                        ShowTenderDeclLines(receiptNo);
                    }
                    else if (type == "SALES" || type == "EXPENSE" || type == "INCOME")
                    {
                        // For SALES, EXPENSE, and INCOME types, show the item ledger entries associated with the receipt
                        ShowItemHistory(receiptNo);
                    }
                    else if (type == "ADVANCEORDERS" || type == "ADVANCEORDER")
                    {
                        // Open AdvanceOrderLinesForm filtered to this transaction
                        try
                        {
                            string storeNo = selectedRow.Cells["StoreNo"].Value?.ToString() ?? "1";
                            string posTerminalNo = selectedRow.Cells["POSTerminalNo"].Value?.ToString() ?? "1";
                            string transactionNo = selectedRow.Cells["TransactionNo"].Value?.ToString() ?? "";
                            if (string.IsNullOrEmpty(transactionNo))
                            {
                                MessageBox.Show("Transaction number missing for advance order.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                            }
                            else
                            {
                                var headerForm = new AdvanceOrdersHeaderForm();
                                // pre-filter the header form to the selected transaction number
                                headerForm.GetType().GetMethod("LoadAdvanceOrdersHeader", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public)?.Invoke(headerForm, new object[] { transactionNo });
                                headerForm.ShowDialog(this);
                            }
                        }
                        catch (Exception ex)
                        {
                            MessageBox.Show($"Error opening advance order lines: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                    else
                    {
                        MessageBox.Show($"Transaction details for type '{type}' is not yet implemented.", "Not Implemented",
                                      MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Error editing transaction: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
            else
            {
                MessageBox.Show("Please select a transaction to edit.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void ShowFloatEntryDetails(int storeNo, int posTerminalNo, int transactionNo, string userId)
        {
            string connectionString = GlobalSettings.ConnectionString;
            try
            {
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    string query = @"SELECT ReceiptNo, Type, Quantity, Price, Discount, GrossAmount, NetAmount, 
                                           Date, Time, UserID, Description 
                                    FROM TransactionHeader 
                                    WHERE StoreNo = @storeNo AND POSTerminalNo = @posTerminalNo AND TransactionNo = @transactionNo";

                    using (SqlCommand command = new SqlCommand(query, connection))
                    {
                        command.Parameters.AddWithValue("@storeNo", storeNo);
                        command.Parameters.AddWithValue("@posTerminalNo", posTerminalNo);
                        command.Parameters.AddWithValue("@transactionNo", transactionNo);

                        using (SqlDataReader reader = command.ExecuteReader())
                        {
                            if (reader.Read())
                            {
                                string details = $"Float Entry Details:\n\n" +
                                               $"Receipt No: {reader["ReceiptNo"]}\n" +
                                               $"Type: {reader["Type"]}\n" +
                                               $"Amount: {reader["NetAmount"]:C}\n" +
                                               $"Date: {reader["Date"]}\n" +
                                               $"Time: {reader["Time"]}\n" +
                                               $"User: {reader["UserID"]}\n" +
                                               $"Description: {reader["Description"]}";

                                MessageBox.Show(details, "Float Entry Details", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error retrieving float entry details: {ex.Message}", "Error",
                              MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ShowFloatEntryLines(string receiptNo)
        {
            try
            {
                // Create a new form to display cash float entry lines
                Form floatLinesForm = new Form();
                floatLinesForm.Text = $"Cash Float Entry Lines - Receipt: {receiptNo}";
                floatLinesForm.Size = new Size(1000, 600);
                floatLinesForm.StartPosition = FormStartPosition.CenterParent;

                // Panel to hold DataGridView and Grand Total label
                Panel mainPanel = new Panel();
                mainPanel.Dock = DockStyle.Fill;
                mainPanel.Padding = new Padding(0);

                DataGridView dgvFloatLines = new DataGridView();
                dgvFloatLines.Dock = DockStyle.Fill;
                dgvFloatLines.AllowUserToAddRows = false;
                dgvFloatLines.AllowUserToDeleteRows = false;
                dgvFloatLines.ReadOnly = true;
                dgvFloatLines.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
                dgvFloatLines.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;

                Label totalLabel = new Label();
                totalLabel.Dock = DockStyle.Bottom;
                totalLabel.Font = new Font("Arial", 28, FontStyle.Bold);
                totalLabel.ForeColor = Color.DarkGreen;
                totalLabel.Height = 60;
                totalLabel.TextAlign = ContentAlignment.MiddleCenter;

                // Load cash float entry lines from CashFloatLines table
                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    // Check if CashFloatLines table exists
                    string checkTableQuery = @"SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES 
                                             WHERE TABLE_NAME = 'CashFloatLines'";
                    SqlCommand checkCmd = new SqlCommand(checkTableQuery, connection);
                    int tableExists = (int)checkCmd.ExecuteScalar();

                    if (tableExists > 0)
                    {
                        string query = @"SELECT 
                                            [LineNo] as [Line No],
                                            [Denomination],
                                            [Qty] as [Quantity],
                                            [TotalAmount] as [Line Total],
                                            [Date],
                                            CASE 
                                                WHEN Time IS NULL THEN ''
                                                ELSE CONVERT(VARCHAR(8), Time, 108)
                                            END AS Time,
                                            UserID as Cashier
                                        FROM CashFloatLines 
                                        WHERE ReceiptNo = @receiptNo
                                        ORDER BY [LineNo]";

                        SqlDataAdapter adapter = new SqlDataAdapter(query, connection);
                        adapter.SelectCommand.Parameters.AddWithValue("@receiptNo", receiptNo);

                        DataTable dataTable = new DataTable();
                        adapter.Fill(dataTable);
                        dgvFloatLines.DataSource = dataTable;

                        // Format columns
                        if (dgvFloatLines.Columns.Contains("Line #"))
                        {
                            dgvFloatLines.Columns["Line #"].Width = 80;
                            dgvFloatLines.Columns["Line #"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleCenter;
                        }

                        if (dgvFloatLines.Columns.Contains("Denomination"))
                        {
                            dgvFloatLines.Columns["Denomination"].DefaultCellStyle.Format = "C2";
                            dgvFloatLines.Columns["Denomination"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                            dgvFloatLines.Columns["Denomination"].Width = 120;
                        }

                        if (dgvFloatLines.Columns.Contains("Quantity"))
                        {
                            dgvFloatLines.Columns["Quantity"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleCenter;
                            dgvFloatLines.Columns["Quantity"].Width = 100;
                        }

                        if (dgvFloatLines.Columns.Contains("Line Total"))
                        {
                            dgvFloatLines.Columns["Line Total"].DefaultCellStyle.Format = "C2";
                            dgvFloatLines.Columns["Line Total"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                            dgvFloatLines.Columns["Line Total"].Width = 120;
                        }

                        if (dgvFloatLines.Columns.Contains("Date"))
                        {
                            dgvFloatLines.Columns["Date"].DefaultCellStyle.Format = "MM/dd/yyyy";
                            dgvFloatLines.Columns["Date"].Width = 100;
                        }

                        if (dgvFloatLines.Columns.Contains("Time"))
                        {
                            dgvFloatLines.Columns["Time"].Width = 80;
                        }

                        if (dgvFloatLines.Columns.Contains("Cashier"))
                        {
                            dgvFloatLines.Columns["Cashier"].Width = 100;
                        }

                        // Calculate and display grand total
                        decimal grandTotal = 0;
                        foreach (DataRow row in dataTable.Rows)
                        {
                            grandTotal += Convert.ToDecimal(row["Line Total"]);
                        }
                        totalLabel.Text = $"Grand Total: {grandTotal:C2}";
                    }
                    else
                    {
                        // If CashFloatLines table doesn't exist, show message
                        MessageBox.Show("CashFloatLines table not found. No cash float entry lines available.",
                            "Table Not Found", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }
                }

                mainPanel.Controls.Add(dgvFloatLines);
                mainPanel.Controls.Add(totalLabel);
                floatLinesForm.Controls.Add(mainPanel);
                floatLinesForm.ShowDialog();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error showing cash float entry lines: {ex.Message}", "Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        public void ShowTenderDeclLines(string receiptNo)
        {
            string connectionString = GlobalSettings.ConnectionString;
            DataTable tenderDeclTable = new DataTable();
            using (SqlConnection conn = new SqlConnection(connectionString))
            {
                conn.Open();
                string query = @"SELECT Date, Time, UserID, ReceiptNo, Denomination, Qty, TotalAmount FROM TenderDeclLines WHERE ReceiptNo = @ReceiptNo";
                using (SqlCommand cmd = new SqlCommand(query, conn))
                {
                    cmd.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                    using (SqlDataAdapter adapter = new SqlDataAdapter(cmd))
                    {
                        adapter.Fill(tenderDeclTable);
                    }
                }
            }

            // Calculate grand total
            decimal grandTotal = 0;
            foreach (DataRow row in tenderDeclTable.Rows)
            {
                if (row["TotalAmount"] != DBNull.Value)
                    grandTotal += Convert.ToDecimal(row["TotalAmount"]);
            }

            // Display in a DataGridView and show grand total below
            DataGridView dgvTenderDecl = new DataGridView
            {
                DataSource = tenderDeclTable,
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill
            };

            Label totalLabel = new Label
            {
                Dock = DockStyle.Bottom,
                Font = new Font("Arial", 20, FontStyle.Bold),
                ForeColor = Color.DarkGreen,
                Height = 50,
                TextAlign = ContentAlignment.MiddleCenter,
                Text = $"Grand Total: {grandTotal:C2}"
            };

            Form tenderDeclForm = new Form
            {
                Text = $"Tender Declaration Lines for Receipt {receiptNo}",
                Size = new Size(700, 500)
            };
            tenderDeclForm.Controls.Add(dgvTenderDecl);
            tenderDeclForm.Controls.Add(totalLabel);
            tenderDeclForm.ShowDialog();
        }

        private void ShowItemHistory(string receiptNo)
        {
            try
            {
                // Create a new form to display item history
                Form itemHistoryForm = new Form();
                itemHistoryForm.Text = $"Item History - Receipt: {receiptNo} (Viewed by: {CurrentUser.Username ?? "Unknown"})";
                itemHistoryForm.Size = new Size(1200, 650);
                itemHistoryForm.StartPosition = FormStartPosition.CenterParent;

                // Add a header label showing current user
                Label headerLabel = new Label();
                headerLabel.Text = $"Item History for Receipt: {receiptNo} | Viewed by: {CurrentUser.Username ?? "Unknown User"} | Date: {DateTime.Now:yyyy-MM-dd HH:mm:ss}";
                headerLabel.Font = new Font("Arial", 10, FontStyle.Bold);
                headerLabel.ForeColor = Color.DarkBlue;
                headerLabel.Size = new Size(1180, 25);
                headerLabel.Location = new Point(10, 10);
                headerLabel.TextAlign = ContentAlignment.MiddleLeft;
                itemHistoryForm.Controls.Add(headerLabel);

                DataGridView dgvItemHistory = new DataGridView();
                dgvItemHistory.Location = new Point(0, 40);
                dgvItemHistory.Size = new Size(1200, 570);
                dgvItemHistory.AllowUserToAddRows = false;
                dgvItemHistory.AllowUserToDeleteRows = false;
                dgvItemHistory.ReadOnly = true;
                dgvItemHistory.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
                dgvItemHistory.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;

                // Load item ledger entries for this receipt
                string connectionString = GlobalSettings.ConnectionString;
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    // Check if ItemLedgerEntry table exists and get item history
                    string checkTableQuery = @"SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES 
                                             WHERE TABLE_NAME = 'ItemLedgerEntry'";
                    SqlCommand checkCmd = new SqlCommand(checkTableQuery, connection);
                    int tableExists = (int)checkCmd.ExecuteScalar();

                    if (tableExists > 0)
                    {
                        string query = @"SELECT 
                                            ILE.ItemCode,
                                            ISNULL(I.Description, 'Item not found') as 'Item Description',
                                            ILE.Description as 'Line Description',
                                            ILE.DocumentType as 'Document Type',
                                            ILE.DocumentNo as 'Document No',
                                            ILE.Quantity,                                        
                                            ILE.Price as Price,
                                            ILE.UserID as 'Transaction User',
                                            ILE.EntryDate as 'Entry Date'
                                        FROM ItemLedgerEntry ILE
                                        LEFT JOIN Items I ON ILE.ItemCode = I.Code
                                        WHERE ILE.DocumentNo = @receiptNo OR ILE.DocumentNo = @reversalReceiptNo
                                        ORDER BY ILE.EntryDate, ILE.ItemCode";

                        SqlDataAdapter adapter = new SqlDataAdapter(query, connection);
                        adapter.SelectCommand.Parameters.AddWithValue("@receiptNo", receiptNo);
                        adapter.SelectCommand.Parameters.AddWithValue("@reversalReceiptNo", receiptNo + "-REV");

                        DataTable dataTable = new DataTable();
                        adapter.Fill(dataTable);
                        dgvItemHistory.DataSource = dataTable;

                        // Format numeric columns
                        if (dgvItemHistory.Columns.Contains("Quantity"))
                        {
                            dgvItemHistory.Columns["Quantity"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                        }

                        if (dgvItemHistory.Columns.Contains("Unit Cost"))
                        {
                            dgvItemHistory.Columns["Unit Cost"].DefaultCellStyle.Format = "C2";
                            dgvItemHistory.Columns["Unit Cost"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                        }

                        if (dgvItemHistory.Columns.Contains("Total Cost"))
                        {
                            dgvItemHistory.Columns["Total Cost"].DefaultCellStyle.Format = "C2";
                            dgvItemHistory.Columns["Total Cost"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                        }

                        if (dgvItemHistory.Columns.Contains("Entry Date"))
                        {
                            dgvItemHistory.Columns["Entry Date"].DefaultCellStyle.Format = "yyyy-MM-dd HH:mm:ss";
                        }

                        // Color-code rows based on document type
                        foreach (DataGridViewRow row in dgvItemHistory.Rows)
                        {
                            string? docType = row.Cells["Document Type"].Value?.ToString();
                            if (docType == "SALES")
                            {
                                row.DefaultCellStyle.BackColor = Color.LightBlue;
                            }
                            else if (docType == "REVERSAL")
                            {
                                row.DefaultCellStyle.BackColor = Color.LightCoral;
                            }
                        }
                    }
                    else
                    {
                        // If ItemLedgerEntry table doesn't exist, show message
                        MessageBox.Show("ItemLedgerEntry table not found. No item history available.",
                            "Table Not Found", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }
                }

                itemHistoryForm.Controls.Add(dgvItemHistory);
                itemHistoryForm.ShowDialog();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error showing item history: {ex.Message}", "Error",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnDelete_Click(object? sender, EventArgs e)
        {
            if (dgvTransactions?.SelectedRows.Count > 0)
            {
                if (MessageBox.Show("Are you sure you want to delete this transaction?", "Confirm Delete",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                {
                    try
                    {
                        DataGridViewRow selectedRow = dgvTransactions.SelectedRows[0];

                        int storeNo = Convert.ToInt32(selectedRow.Cells["StoreNo"].Value);
                        int posTerminalNo = Convert.ToInt32(selectedRow.Cells["POSTerminalNo"].Value);
                        int transactionNo = Convert.ToInt32(selectedRow.Cells["TransactionNo"].Value);

                        string connectionString = GlobalSettings.ConnectionString;
                        using (SqlConnection connection = new SqlConnection(connectionString))
                        {
                            connection.Open();
                            string query = "DELETE FROM TransactionHeader WHERE StoreNo = @storeNo AND POSTerminalNo = @posTerminalNo AND TransactionNo = @transactionNo";

                            SqlCommand command = new SqlCommand(query, connection);
                            command.Parameters.AddWithValue("@storeNo", storeNo);
                            command.Parameters.AddWithValue("@posTerminalNo", posTerminalNo);
                            command.Parameters.AddWithValue("@transactionNo", transactionNo);

                            command.ExecuteNonQuery();
                            MessageBox.Show("Transaction deleted successfully.", "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            LoadTransactions();
                        }
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show($"Error deleting transaction: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
            else
            {
                MessageBox.Show("Please select a transaction to delete.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void BtnRefresh_Click(object? sender, EventArgs e)
        {
            LoadTransactions();
        }

        private void BtnClose_Click(object? sender, EventArgs e)
        {
            this.Close();
        }

        // Convert the grid to show only a single ReceiptNo link column and wire click handling
        private void ConfigureReceiptLinkView()
        {
            if (dgvTransactions == null || dgvTransactions.DataSource == null) return;

            try
            {
                DataTable? dt = null;
                if (dgvTransactions.DataSource is DataTable direct)
                    dt = direct;
                else if (dgvTransactions.DataSource is DataView dv)
                    dt = dv.Table;

                if (dt == null) return;

                // Create a new DataTable with only ReceiptNo column
                DataTable linkTable = new DataTable();
                linkTable.Columns.Add("ReceiptNo", typeof(string));

                foreach (DataRow r in dt.Rows)
                {
                    var val = r["ReceiptNo"]?.ToString() ?? string.Empty;
                    linkTable.Rows.Add(val);
                }

                dgvTransactions.Columns.Clear();
                dgvTransactions.DataSource = linkTable;

                var linkCol = new DataGridViewLinkColumn()
                {
                    Name = "ReceiptNo",
                    HeaderText = "Receipt No",
                    DataPropertyName = "ReceiptNo",
                    LinkBehavior = LinkBehavior.HoverUnderline,
                    TrackVisitedState = false,
                    Width = 200
                };
                dgvTransactions.Columns.Add(linkCol);
                dgvTransactions.CellContentClick -= DgvTransactions_CellContentClick_ForLinks;
                dgvTransactions.CellContentClick += DgvTransactions_CellContentClick_ForLinks;
            }
            catch { }
        }

        private void DgvTransactions_CellContentClick_ForLinks(object? sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0) return;
            try
            {
                var cell = dgvTransactions?.Rows[e.RowIndex].Cells[e.ColumnIndex];
                if (cell != null && cell.Value != null)
                {
                    string receiptNo = cell.Value.ToString() ?? string.Empty;
                    if (!string.IsNullOrWhiteSpace(receiptNo))
                    {
                        // Reuse existing edit flow to show the transaction details
                        // Find the first matching row in the original data and invoke edit
                        // For simplicity, open ShowItemHistory for the clicked receipt
                        ShowItemHistory(receiptNo);
                    }
                }
            }
            catch { }
        }

        private void TransactionListForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }

        private void BtnReprint_Click(object? sender, EventArgs e)
        {
            if (dgvTransactions?.SelectedRows.Count > 0)
            {
                try
                {
                    DataGridViewRow selectedRow = dgvTransactions.SelectedRows[0];
                    string receiptNo = selectedRow.Cells["ReceiptNo"].Value?.ToString() ?? "";
                    string type = selectedRow.Cells["Type"].Value?.ToString() ?? "";

                    if (string.IsNullOrEmpty(receiptNo))
                    {
                        MessageBox.Show("Cannot reprint: Receipt number is missing.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }

                    // Route print based on transaction type
                    if (type == "SALES")
                    {
                        // Use MainForm's PrintReceiptDirect via the open MainForm instance
                        var mainForm = Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                        if (mainForm != null)
                        {
                            mainForm.Invoke(new Action(() => mainForm.PrintSaleReceipt(receiptNo)));
                        }
                        else
                        {
                            MessageBox.Show("MainForm not available to print sales receipt.", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        }
                    }
                    else if (type == "EXPENSE")
                    {
                        // Reconstruct expense lines from TransactionHeader (Description stored) and ItemLedgerEntry
                        var expenseItems = LoadExpenseListViewItems(receiptNo);
                        decimal grandTotal = expenseItems.Sum(it =>
                        {
                            decimal val = 0; Decimal.TryParse(it.SubItems.Count > 3 ? it.SubItems[3].Text : "0", out val); return val;
                        });
                        FunctionEvents.PrintExpenseReceipt(receiptNo, CurrentUser.Username ?? "", expenseItems, grandTotal, "Reprint");
                    }
                    else if (type == "Float_Entry")
                    {
                        // Load float lines and call PrintCashFloatReceipt
                        decimal grandTotal = 0;
                        var coinTextBoxes = new List<TextBox>();
                        var noteTextBoxes = new List<TextBox>();

                        // We don't have the original TextBoxes here; instead call PostingEvents.PrintXReport as a fallback for float entries
                        // But there is a dedicated print in FunctionEvents for cash float - attempt to load totals and invoke PrintCashFloatReceipt with minimal data
                        using (SqlConnection conn = new SqlConnection(GlobalSettings.ConnectionString))
                        {
                            conn.Open();
                            string q = "SELECT SUM(TotalAmount) FROM CashFloatLines WHERE ReceiptNo = @receiptNo";
                            using (SqlCommand cmd = new SqlCommand(q, conn))
                            {
                                cmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                                var r = cmd.ExecuteScalar();
                                if (r != null && r != DBNull.Value) grandTotal = Convert.ToDecimal(r);
                            }
                        }

                        // Call PrintXReport as a reasonable fallback for printing float/tender related receipts
                        try
                        {
                            AquariumPOS.PostingEvents.PrintXReport(receiptNo);
                        }
                        catch
                        {
                            // If X Report unavailable, show message
                            MessageBox.Show("Unable to reprint Float Entry via X Report. No direct float reprint available.", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        }
                    }
                    else if (type == "TenderDecl")
                    {
                        var mainForm = Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                        if (mainForm != null)
                        {
                            mainForm.Invoke(new Action(() => mainForm.PrintTenderDeclReceipt(receiptNo)));
                        }
                        else
                        {
                            MessageBox.Show("MainForm not available to print tender declaration.", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        }
                    }
                    else
                    {
                        MessageBox.Show($"Reprint for transaction type '{type}' is not implemented.", "Not Implemented", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Error during reprint: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
            else
            {
                MessageBox.Show("Please select a transaction to reprint.", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        // Load expense items as ListViewItem list to feed PrintExpenseReceipt
        private List<ListViewItem> LoadExpenseListViewItems(string receiptNo)
        {
            var items = new List<ListViewItem>();
            try
            {
                using (SqlConnection conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();
                    // Try to read ItemLedgerEntry rows where DocumentNo = receiptNo and DocumentType = 'EXPENSE' or TransactionHeader rows with Type=EXPENSE
                    string query = @"SELECT ILE.ItemCode, ILE.Quantity, ILE.UnitCost AS Price, ILE.TotalCost, ILE.Description
                                     FROM ItemLedgerEntry ILE
                                     WHERE (ILE.DocumentNo = @receiptNo OR ILE.DocumentNo = @receiptRev)
                                     ORDER BY ILE.ID";

                    using (SqlCommand cmd = new SqlCommand(query, conn))
                    {
                        cmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                        cmd.Parameters.AddWithValue("@receiptRev", receiptNo + "-REV");
                        using (var rdr = cmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                string desc = rdr["Description"]?.ToString() ?? rdr["ItemCode"]?.ToString() ?? "";
                                int qty = rdr["Quantity"] != DBNull.Value ? Convert.ToInt32(rdr["Quantity"]) : 0;
                                decimal price = rdr["Price"] != DBNull.Value ? Convert.ToDecimal(rdr["Price"]) : 0m;
                                decimal total = rdr["TotalCost"] != DBNull.Value ? Convert.ToDecimal(rdr["TotalCost"]) : qty * price;

                                var lvi = new ListViewItem(desc);
                                lvi.SubItems.Add(qty.ToString());
                                lvi.SubItems.Add(price.ToString("F2"));
                                lvi.SubItems.Add(total.ToString("F2"));
                                items.Add(lvi);
                            }
                        }
                    }

                    // If no item ledger entries found, try to read TransactionHeader row for a single-line expense
                    if (items.Count == 0)
                    {
                        string q2 = @"SELECT Description, Quantity, Price, NetAmount FROM TransactionHeader WHERE ReceiptNo = @receiptNo";
                        using (SqlCommand cmd2 = new SqlCommand(q2, conn))
                        {
                            cmd2.Parameters.AddWithValue("@receiptNo", receiptNo);
                            using (var rdr2 = cmd2.ExecuteReader())
                            {
                                while (rdr2.Read())
                                {
                                    string desc = rdr2["Description"]?.ToString() ?? "Expense";
                                    int qty = rdr2["Quantity"] != DBNull.Value ? Convert.ToInt32(rdr2["Quantity"]) : 1;
                                    decimal price = rdr2["Price"] != DBNull.Value ? Convert.ToDecimal(rdr2["Price"]) : 0m;
                                    decimal net = rdr2["NetAmount"] != DBNull.Value ? Convert.ToDecimal(rdr2["NetAmount"]) : qty * price;

                                    var lvi = new ListViewItem(desc);
                                    lvi.SubItems.Add(qty.ToString());
                                    lvi.SubItems.Add(price.ToString("F2"));
                                    lvi.SubItems.Add(net.ToString("F2"));
                                    items.Add(lvi);
                                }
                            }
                        }
                    }
                }
            }
            catch
            {
                // swallow errors and return what we have, printing will show error if empty
            }

            return items;
        }
    }
}
