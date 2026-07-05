using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Drawing.Printing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class ProductionOrdersForm : Form

    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView dataGridView;
        private TextBox searchTextBox;
        private ComboBox statusComboBox;
        private Button searchButton, refreshButton, changeStatusButton, transactionListButton;

        public ProductionOrdersForm()
        {
            KeyPreview = true;
            this.KeyDown += ProductionOrdersForm_KeyDown;

            Text = "Production Orders";
            WindowState = FormWindowState.Maximized;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.White;

            dataGridView = new DataGridView
            {
                Dock = DockStyle.Top,
                Height = 500,
                ReadOnly = true,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false
            };
            // Set larger, bold font for column headers
            dataGridView.ColumnHeadersDefaultCellStyle.Font = new Font("Arial", 12, FontStyle.Bold);

            searchTextBox = new TextBox
            {
                PlaceholderText = "Search by Transaction No, Receipt No, ProdOrderNo, CustomerName...",
                Dock = DockStyle.Top,
                Height = 30,
                Font = new Font("Arial", 10)
            };

            // Status filter combo (load available statuses from DB)
            statusComboBox = new ComboBox
            {
                Dock = DockStyle.Top,
                Height = 48,
                Font = new Font("Arial", 16, FontStyle.Bold),
                DropDownStyle = ComboBoxStyle.DropDownList,
                IntegralHeight = false,
                DropDownHeight = 200
            };
            statusComboBox.Items.Add("All");
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    var cmd = new SqlCommand("SELECT Code FROM ProductionStatus ORDER BY Stages, Code", conn);
                    using (var reader = cmd.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            var code = reader["Code"]?.ToString() ?? "";
                            if (!string.IsNullOrWhiteSpace(code) && !statusComboBox.Items.Contains(code))
                                statusComboBox.Items.Add(code);
                        }
                    }
                }
            }
            catch
            {
                // Ignore DB errors when populating status list; fallback to minimal options
            }
            // Default to TO_BUILD if available otherwise 'All'
            statusComboBox.SelectedItem = statusComboBox.Items.Contains("TO_BUILD") ? (object)"TO_BUILD" : statusComboBox.Items[0];
            statusComboBox.SelectedIndexChanged += (s, e) => LoadProductionOrders(searchTextBox.Text, statusComboBox.SelectedItem?.ToString());

            searchButton = new Button
            {
                Text = "Search",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.DarkBlue,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            // wire search button to include status filter
            // (later we also add the same handler after wiring controls; keep only this)
            searchButton.Click += (s, e) => LoadProductionOrders(searchTextBox.Text, statusComboBox.SelectedItem?.ToString());

            refreshButton = new Button
            {
                Text = "Refresh",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            // refresh should respect current status filter
            refreshButton.Click += (s, e) => LoadProductionOrders("", statusComboBox.SelectedItem?.ToString());


            changeStatusButton = new Button
            {
                Text = "Change Status",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.Orange,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            changeStatusButton.Click += ChangeStatusButton_Click;

            // Transaction List button (opens TransactionList for selected ReceiptNo)
            transactionListButton = new Button
            {
                Text = "Transaction List",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.Teal,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            transactionListButton.Click += TransactionListButton_Click;

            // Add controls (transaction list, change status, refresh, search)
            Controls.Add(transactionListButton);
            Controls.Add(changeStatusButton);
            Controls.Add(refreshButton);
            Controls.Add(searchButton);
            Controls.Add(statusComboBox);
            Controls.Add(searchTextBox);
            // duplicate handlers removed above; handlers already wired to include status
            Controls.Add(dataGridView);

            dataGridView.CellFormatting += DataGridView_CellFormatting;

            // Double-click to show order lines for selected order
            dataGridView.CellDoubleClick += DataGridView_CellDoubleClick;

            // Click any cell to select the entire row (makes printing by clicking any column easier)
            dataGridView.CellClick += DataGridView_CellClick;

            // Adjust column widths after data is loaded
            dataGridView.DataBindingComplete += (s, e) =>
            {
                foreach (DataGridViewColumn col in dataGridView.Columns)
                {
                    // Squeeze width but ensure header text is visible
                    int headerWidth = TextRenderer.MeasureText(col.HeaderText, dataGridView.ColumnHeadersDefaultCellStyle.Font).Width + 24;
                    switch (col.Name)
                    {
                        case "ReceiptNo":
                            col.Width = Math.Max(headerWidth, 110);
                            break;
                        case "Order_Description":
                            col.Width = Math.Max(headerWidth, 140);
                            break;
                        case "Status":
                            col.Width = Math.Max(headerWidth, 90);
                            col.DefaultCellStyle.Font = new Font("Arial", 12, FontStyle.Bold);
                            break;
                        case "DUEDate":
                            col.Width = Math.Max(headerWidth, 90);
                            break;
                        case "Date":
                            col.Width = Math.Max(headerWidth, 90);
                            break;
                        case "Time":
                            col.Width = Math.Max(headerWidth, 70);
                            break;
                        default:
                            col.Width = Math.Max(headerWidth, 60);
                            break;
                    }
                }
            };

            // Load page default with only TO_BUILD orders shown
            LoadProductionOrders("", statusComboBox.SelectedItem?.ToString() ?? "TO_BUILD");
        }



        private void DataGridView_CellClick(object? sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex >= 0)
            {
                dataGridView.ClearSelection();
                dataGridView.Rows[e.RowIndex].Selected = true;
            }
        }

        private void DataGridView_CellDoubleClick(object? sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex >= 0)
            {
                var row = dataGridView.Rows[e.RowIndex];
                string transactionNo = row.Cells["TransactionNo"].Value?.ToString() ?? "";

                // Check if the production stage is 1 before showing ProdOrderLinesForm
                string statusCode = "";
                int stage = -1;
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    // Get status code from Prod_Order_Header
                    string headerQuery = "SELECT Status FROM Prod_Order_Header WHERE TransactionNo = @TransactionNo";
                    var headerCmd = new SqlCommand(headerQuery, connection);
                    headerCmd.Parameters.AddWithValue("@TransactionNo", transactionNo);
                    statusCode = headerCmd.ExecuteScalar()?.ToString() ?? "";

                    // Get stage from ProductionStatus
                    if (!string.IsNullOrEmpty(statusCode))
                    {
                        string stageQuery = "SELECT Stages FROM ProductionStatus WHERE Code = @Code";
                        var stageCmd = new SqlCommand(stageQuery, connection);
                        stageCmd.Parameters.AddWithValue("@Code", statusCode);
                        var stageObj = stageCmd.ExecuteScalar();
                        if (stageObj != null && int.TryParse(stageObj.ToString(), out int s))
                            stage = s;
                    }
                }

                if (stage == 1)
                {
                    var linesForm = new ProdOrderLinesForm();
                    linesForm.Text = $"Order Lines for TransactionNo: {transactionNo}";
                    linesForm.LoadOrderLinesByTransaction(transactionNo);
                    linesForm.Show();
                }
                else
                {
                    MessageBox.Show("Order lines are only visible when the order status is at Stage 1.", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
            }
        }

        private void TransactionListButton_Click(object? sender, EventArgs e)
        {
            string receiptNo = string.Empty;
            if (dataGridView.SelectedRows.Count > 0)
            {
                var row = dataGridView.SelectedRows[0];
                receiptNo = row.Cells["ReceiptNo"]?.Value?.ToString() ?? string.Empty;
            }

            if (string.IsNullOrWhiteSpace(receiptNo))
            {
                MessageBox.Show("Please select a production order row to open its Transaction List (by Receipt No).", "No Selection", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            try
            {
                var tForm = new TransactionListForm();
                // Prefer setting a public property if the form exposes it
                try
                {
                    var prop = typeof(TransactionListForm).GetProperty("InitialReceiptNo", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public);
                    if (prop != null && prop.CanWrite)
                    {
                        prop.SetValue(tForm, receiptNo);
                    }
                    else
                    {
                        // try a field fallback
                        var field = typeof(TransactionListForm).GetField("initialReceiptNo", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
                        if (field != null) field.SetValue(tForm, receiptNo);
                    }
                }
                catch { }

                tForm.Show();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Unable to open Transaction List: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void LoadProductionOrders(string searchTerm, string? statusFilter)
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    // Build query with optional search and status filters
                    var whereClauses = new List<string>();
                    if (!string.IsNullOrWhiteSpace(searchTerm))
                    {
                        whereClauses.Add("(TransactionNo LIKE @search OR ReceiptNo LIKE @search OR ProdOrderNo LIKE @search OR CustomerName LIKE @search)");
                    }
                    if (!string.IsNullOrWhiteSpace(statusFilter) && statusFilter != "All")
                    {
                        whereClauses.Add("Status = @status");
                    }

                    string query = "SELECT TransactionNo, ReceiptNo, ProdOrderNo, [No. of Items], Date, Time, DUEDate, CustomerName, Order_Description, Status, Category FROM Prod_Order_Header";
                    if (whereClauses.Count > 0)
                    {
                        query += " WHERE " + string.Join(" AND ", whereClauses);
                    }
                    // Sort by due date ascending so nearest due orders are shown first
                    query += " ORDER BY DUEDate ASC, TransactionNo DESC";

                    var command = new SqlCommand(query, connection);
                    if (!string.IsNullOrWhiteSpace(searchTerm))
                    {
                        command.Parameters.AddWithValue("@search", "%" + searchTerm + "%");
                    }
                    if (!string.IsNullOrWhiteSpace(statusFilter) && statusFilter != "All")
                    {
                        command.Parameters.AddWithValue("@status", statusFilter);
                    }
                    var adapter = new SqlDataAdapter(command);
                    var table = new DataTable();
                    adapter.Fill(table);
                    dataGridView.DataSource = table;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading Production Orders: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void DataGridView_CellFormatting(object? sender, DataGridViewCellFormattingEventArgs e)
        {
            var colName = dataGridView.Columns[e.ColumnIndex].Name;
            if (colName == "Time" && e.Value != null)
            {
                if (e.Value is DateTime dt)
                {
                    e.Value = dt.ToString("hh:mm:ss tt");
                    e.FormattingApplied = true;
                }
                else if (e.Value is TimeSpan ts)
                {
                    DateTime dtValue = DateTime.Today.Add(ts);
                    e.Value = dtValue.ToString("hh:mm:ss tt");
                    e.FormattingApplied = true;
                }
                else if (DateTime.TryParse(e.Value.ToString(), out DateTime parsedTime))
                {
                    e.Value = parsedTime.ToString("hh:mm:ss tt");
                    e.FormattingApplied = true;
                }
            }

            // Due date color logic
            if (colName == "DUEDate" && e.Value != null)
            {
                DateTime dueDate;
                if (DateTime.TryParse(e.Value.ToString(), out dueDate))
                {
                    DateTime today = DateTime.Today;
                    var cell = dataGridView.Rows[e.RowIndex].Cells[e.ColumnIndex];
                    // Get Status value for this row
                    var statusValue = dataGridView.Rows[e.RowIndex].Cells["Status"].Value?.ToString();
                    if (statusValue == "Completed")
                    {
                        cell.Style.BackColor = Color.Green;
                        cell.Style.ForeColor = Color.White;
                    }
                    else if (dueDate.Date <= today)
                    {
                        cell.Style.BackColor = Color.Red;
                        cell.Style.ForeColor = Color.White;
                    }
                    else if ((dueDate.Date - today).TotalDays <= 2)
                    {
                        cell.Style.BackColor = Color.Yellow;
                        cell.Style.ForeColor = Color.Black;
                    }
                }
            }
        }


        // Example function to write data from salesListView totals into Prod_Order_Header
        // Call this from MainForm or wherever salesListView and totals are available
        public void WriteSalesTotalsToProdOrderHeader(
            string storeNo,
            string posTerminalNo,
            string transactionNo,
            string receiptNo,
            string prodOrderNo,
            string type,
            int noOfItems,
            DateTime date,
            TimeSpan time,
            string customerName,
            string orderDescription,
            string eodid,
            string status,
            DateTime dueDate,
            string category)
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    string query = @"INSERT INTO Prod_Order_Header
                        (StoreNo, POSTerminalNo, TransactionNo, ReceiptNo, ProdOrderNo, Type, [No. of Items], Date, Time, CustomerName, Order_Description, EODID, Status, DUEDate, Category)
                        VALUES
                        (@StoreNo, @POSTerminalNo, @TransactionNo, @ReceiptNo, @ProdOrderNo, @Type, @NoOfItems, @Date, @Time, @CustomerName, @Order_Description, @EODID, @Status, @DUEDate, @Category)";
                    var command = new SqlCommand(query, connection);
                    command.Parameters.AddWithValue("@StoreNo", storeNo);
                    command.Parameters.AddWithValue("@POSTerminalNo", posTerminalNo);
                    command.Parameters.AddWithValue("@TransactionNo", transactionNo);
                    command.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                    command.Parameters.AddWithValue("@ProdOrderNo", prodOrderNo);
                    command.Parameters.AddWithValue("@Type", type);
                    command.Parameters.AddWithValue("@NoOfItems", noOfItems);
                    command.Parameters.AddWithValue("@Date", date);
                    command.Parameters.AddWithValue("@Time", time);
                    command.Parameters.AddWithValue("@CustomerName", customerName);
                    command.Parameters.AddWithValue("@Order_Description", orderDescription);
                    command.Parameters.AddWithValue("@EODID", eodid);
                    command.Parameters.AddWithValue("@Status", status);
                    command.Parameters.AddWithValue("@DUEDate", dueDate);
                    command.Parameters.AddWithValue("@Category", category);
                    command.ExecuteNonQuery();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error writing to Prod_Order_Header: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // Function to write sales line items into Prod_Order_Lines
        public void WriteSalesTotalsToProdOrderLines(
            string storeNo,
            string posTerminalNo,
            string transactionNo,
            string receiptNo,
            string prodOrderNo,
            int lineNo,
            string type,
            string no,
            decimal qty,
            DateTime date,
            TimeSpan time,
            DateTime dueDate,
            string category,
            string customerName,
            string orderDescription)
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    string query = @"INSERT INTO Prod_Order_Lines
                        (StoreNo, POSTerminalNo, TransactionNo, ReceiptNo, ProdOrderNo, [LineNo], Type, [No.], Qty, Date, Time, DUEDate, Category, CustomerName, Order_Description)
                        VALUES
                        (@StoreNo, @POSTerminalNo, @TransactionNo, @ReceiptNo, @ProdOrderNo, @LineNo, @Type, @No, @Qty, @Date, @Time, @DUEDate, @Category, @CustomerName, @Order_Description)";
                    var command = new SqlCommand(query, connection);

                    command.Parameters.AddWithValue("@StoreNo", storeNo);
                    command.Parameters.AddWithValue("@POSTerminalNo", posTerminalNo);
                    command.Parameters.AddWithValue("@TransactionNo", transactionNo);
                    command.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                    command.Parameters.AddWithValue("@ProdOrderNo", prodOrderNo);
                    command.Parameters.AddWithValue("@LineNo", lineNo);
                    command.Parameters.AddWithValue("@Type", type);

                    // Truncate all string fields to prevent SQL truncation error
                    var noNonNull = no ?? string.Empty;
                    var categoryNonNull = category ?? string.Empty;
                    var customerNameNonNull = customerName ?? string.Empty;
                    var orderDescNonNull = orderDescription ?? string.Empty;

                    string safeNo = noNonNull.Length > 255 ? noNonNull.Substring(0, 255) : noNonNull;
                    string safeCategory = categoryNonNull.Length > 50 ? categoryNonNull.Substring(0, 50) : categoryNonNull;
                    string safeCustomerName = customerNameNonNull.Length > 100 ? customerNameNonNull.Substring(0, 100) : customerNameNonNull;
                    string safeOrderDescription = orderDescNonNull.Length > 1000 ? orderDescNonNull.Substring(0, 1000) : orderDescNonNull;

                    command.Parameters.AddWithValue("@No", safeNo);
                    command.Parameters.AddWithValue("@Qty", qty);
                    command.Parameters.AddWithValue("@Date", date.ToString("MM/dd/yyyy"));
                    command.Parameters.AddWithValue("@Time", time);
                    command.Parameters.AddWithValue("@DUEDate", dueDate.ToString("MM/dd/yyyy"));
                    command.Parameters.AddWithValue("@Category", safeCategory);
                    command.Parameters.AddWithValue("@CustomerName", safeCustomerName);
                    command.Parameters.AddWithValue("@Order_Description", safeOrderDescription);
                    command.ExecuteNonQuery();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error writing to Prod_Order_Lines: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ChangeStatusButton_Click(object? sender, EventArgs e)
        {
            DataGridViewRow? row = null;
            if (dataGridView.SelectedRows.Count == 1)
            {
                row = dataGridView.SelectedRows[0];
            }
            else if (dataGridView.SelectedCells.Count == 1)
            {
                row = dataGridView.Rows[dataGridView.SelectedCells[0].RowIndex];
            }
            if (row != null)
            {
                string prodOrderNo = row.Cells["ProdOrderNo"].Value?.ToString() ?? "";
                string currentStatus = row.Cells["Status"].Value?.ToString() ?? "";

                // Fetch available statuses from ProductionStatus table sorted by Stages
                var statusList = new List<(string Code, string Description, int Stages)>();
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    var cmd = new SqlCommand("SELECT Code, Description, Stages FROM ProductionStatus ORDER BY Stages, Code", connection);
                    using (var reader = cmd.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            string code = reader["Code"].ToString() ?? "";
                            string description = reader["Description"].ToString() ?? "";
                            int stages = reader["Stages"] != DBNull.Value ? Convert.ToInt32(reader["Stages"]) : 0;
                            statusList.Add((code, description, stages));
                        }
                    }
                }

                // Show status selection dialog
                var statusForm = new Form
                {
                    Text = "Change Order Status",
                    // Larger, more readable dialog
                    Size = new Size(1100, 600),
                    StartPosition = FormStartPosition.CenterParent,
                    BackColor = Color.White,
                    FormBorderStyle = FormBorderStyle.FixedDialog,
                    MaximizeBox = false,
                    MinimizeBox = false
                };

                string receiptNo = row.Cells["ReceiptNo"].Value?.ToString() ?? "";
                var orderLabel = new Label
                {
                    Text = $"Receipt No.: {receiptNo}",
                    Left = 40,
                    Top = 30,
                    Width = statusForm.ClientSize.Width - 80,
                    // Use fixed height and disable AutoSize so large fonts don't collapse
                    AutoSize = false,
                    Height = 80,
                    Font = new Font("Arial", 36, FontStyle.Bold)
                };

                var currentLabel = new Label
                {
                    Text = $"Current Status: {currentStatus}",
                    Left = 40,
                    // Position below orderLabel
                    Top = orderLabel.Top + orderLabel.Height + 10,
                    Width = statusForm.ClientSize.Width - 80,
                    AutoSize = false,
                    Height = 56,
                    Font = new Font("Arial", 28, FontStyle.Regular)
                };

                var newLabel = new Label
                {
                    Text = "Select new status:",
                    Left = 40,
                    // Position below currentLabel
                    Top = currentLabel.Top + currentLabel.Height + 20,
                    Width = 350,
                    AutoSize = false,
                    Height = 36,
                    Font = new Font("Arial", 24, FontStyle.Regular)
                };

                var comboBox = new ComboBox
                {
                    Left = newLabel.Left + newLabel.Width + 30,
                    // Align vertically with newLabel
                    Top = newLabel.Top,
                    Width = statusForm.ClientSize.Width - (newLabel.Left + newLabel.Width + 80),
                    Font = new Font("Arial", 24),
                    DropDownStyle = ComboBoxStyle.DropDownList
                };

                // Add items with stage information
                foreach (var status in statusList)
                {
                    string displayText = $"Stage {status.Stages}: {status.Code} - {status.Description}";
                    comboBox.Items.Add(new { Text = displayText, Value = status.Code });
                }
                comboBox.DisplayMember = "Text";

                // Select current status
                for (int i = 0; i < comboBox.Items.Count; i++)
                {
                    dynamic item = comboBox.Items[i];
                    if (item.Value == currentStatus)
                    {
                        comboBox.SelectedIndex = i;
                        break;
                    }
                }

                // Place buttons centered and below the comboBox
                var okButton = new Button
                {
                    Text = "OK",
                    Width = 220,
                    Height = 90,
                    Font = new Font("Arial", 24, FontStyle.Bold),
                    DialogResult = DialogResult.OK
                };
                var cancelButton = new Button
                {
                    Text = "Cancel",
                    Width = 220,
                    Height = 90,
                    Font = new Font("Arial", 24, FontStyle.Bold),
                    DialogResult = DialogResult.Cancel
                };

                // Position buttons after the comboBox is sized and laid out
                okButton.Left = statusForm.ClientSize.Width / 2 - okButton.Width - 20;
                cancelButton.Left = statusForm.ClientSize.Width / 2 + 20;
                okButton.Top = comboBox.Top + comboBox.Height + 40;
                cancelButton.Top = okButton.Top;

                statusForm.Controls.Add(orderLabel);
                statusForm.Controls.Add(currentLabel);
                statusForm.Controls.Add(newLabel);
                statusForm.Controls.Add(comboBox);
                statusForm.Controls.Add(okButton);
                statusForm.Controls.Add(cancelButton);
                statusForm.AcceptButton = okButton;
                statusForm.CancelButton = cancelButton;

                if (statusForm.ShowDialog(this) == DialogResult.OK && comboBox.SelectedItem != null)
                {
                    dynamic selectedItem = comboBox.SelectedItem;
                    string newStatus = selectedItem.Value;

                    if (newStatus != currentStatus)
                    {
                        // Update status in database
                        try
                        {
                            using (var connection = new SqlConnection(connectionString))
                            {
                                connection.Open();
                                var cmd = new SqlCommand("UPDATE Prod_Order_Header SET Status = @Status WHERE ProdOrderNo = @ProdOrderNo", connection);
                                cmd.Parameters.AddWithValue("@Status", newStatus);
                                cmd.Parameters.AddWithValue("@ProdOrderNo", prodOrderNo);
                                cmd.ExecuteNonQuery();
                            }
                            LoadProductionOrders("", statusComboBox.SelectedItem?.ToString());
                            MessageBox.Show($"Status updated to: {newStatus}", "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        }
                        catch (Exception ex)
                        {
                            MessageBox.Show($"Error updating status: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                }
            }
            else
            {
                MessageBox.Show("Please select a single order to change status.", "Select Order", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        // Generates the next ProdOrderNo in the format 'PROD_0000000001'
        public static string GenerateNextProdOrderNo()
        {
            long nextNumber = 1;
            string connectionString = GlobalSettings.ConnectionString;
            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                var cmd = new SqlCommand("SELECT MAX(ProdOrderNo) FROM Prod_Order_Header WHERE ProdOrderNo LIKE 'PROD_%'", connection);
                var result = cmd.ExecuteScalar();
                if (result != null && result != DBNull.Value)
                {
                    string? maxProdOrderNo = result.ToString();
                    if (!string.IsNullOrEmpty(maxProdOrderNo) && maxProdOrderNo.StartsWith("PROD_"))
                    {
                        string numberPart = maxProdOrderNo.Substring(5);
                        if (long.TryParse(numberPart, out long lastNumber))
                        {
                            nextNumber = lastNumber + 1;
                        }
                    }
                }
            }
            return $"PROD_{nextNumber.ToString().PadLeft(10, '0')}";
        }

        private void ProductionOrdersForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }

        // Ensure the form is maximized when it is shown
        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            try
            {
                this.WindowState = FormWindowState.Maximized;
            }
            catch
            {
                // ignore any issues setting window state at runtime
            }
        }
    }
}
