using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class AdvanceOrderLinesForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView linesGridView;
        private TextBox searchTextBox;
        private Button searchButton;
        private Button closeButton;
        private Button payInFullButton;
        private Label pancakeSyncStatusLabel;
        private Button resendToPancakeButton;
        private Label portalSyncStatusLabel;
        private Button resendToPortalButton;
        private Button showErrorsButton;

        private string filterStoreNo = "";
        private string filterPosTerminalNo = "";
        private string filterTransactionNo = "";
        private string resolvedReceiptNo = ""; // resolved from filterTransactionNo, cached by RefreshPancakeSyncStatus

        // public AdvanceOrderLinesForm()


        public AdvanceOrderLinesForm(string storeNo, string posTerminalNo, string transactionNo)
        {
            KeyPreview = true;
            this.KeyDown += AdvanceOrderLinesForm_KeyDown;

            filterStoreNo = storeNo;
            filterPosTerminalNo = posTerminalNo;
            filterTransactionNo = transactionNo;
            // LoadLines();

            Text = "Advance Order Lines";
            Size = new Size(1200, 700);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;
            FormBorderStyle = FormBorderStyle.Sizable;
            MaximizeBox = true;
            MinimizeBox = true;

            var titleLabel = new Label
            {
                Text = "Advance Order Lines",
                Location = new Point(20, 20),
                Size = new Size(400, 25),
                Font = new Font("Arial", 16, FontStyle.Bold),
                ForeColor = Color.DarkBlue
            };

            searchTextBox = new TextBox
            {
                Location = new Point(20, 60),
                Size = new Size(300, 25),
                Font = new Font("Arial", 11)
            };
            searchButton = new Button
            {
                Text = "Search",
                Location = new Point(330, 60),
                Size = new Size(80, 25),
                BackColor = Color.DarkBlue,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            searchButton.Click += (s, e) => LoadLines();

            linesGridView = new DataGridView
            {
                Location = new Point(20, 100),
                Size = new Size(1140, 500),
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                BackgroundColor = Color.White,
                GridColor = Color.LightGray
            };

            closeButton = new Button
            {
                Text = "Close",
                Location = new Point(1080, 620),
                Size = new Size(80, 30),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            closeButton.Click += (s, e) => Close();

            // payInFullButton = new Button
            // {
            //     Text = "Pay In Full",
            //     Location = new Point(980, 620), 38888888888888888888888888888888888888888
            //     Size = new Size(90, 30),
            //     BackColor = Color.DarkGreen,
            //     ForeColor = Color.White,
            //     Font = new Font("Arial", 10, FontStyle.Bold)
            // };
            // payInFullButton.Click += PayInFullButton_Click;

            pancakeSyncStatusLabel = new Label
            {
                Text = "Pancake: -",
                Location = new Point(20, 625),
                Size = new Size(400, 25),
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.Gray
            };

            portalSyncStatusLabel = new Label
            {
                Text = "Portal: -",
                Location = new Point(20, 650),
                Size = new Size(400, 25),
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.Gray
            };

            resendToPancakeButton = new Button
            {
                Text = "Resend to Pancake",
                Location = new Point(430, 620),
                Size = new Size(160, 30),
                BackColor = Color.DarkOrange,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            resendToPancakeButton.Click += async (s, e) => await ResendToPancakeButton_ClickAsync();

            resendToPortalButton = new Button
            {
                Text = "Resend to Portal",
                Location = new Point(600, 620),
                Size = new Size(160, 30),
                BackColor = Color.DarkOrange,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            resendToPortalButton.Click += async (s, e) => await ResendToPortalButton_ClickAsync();

            showErrorsButton = new Button
            {
                Text = "Show Errors",
                Location = new Point(770, 620),
                Size = new Size(130, 30),
                BackColor = Color.Firebrick,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            showErrorsButton.Click += ShowErrorsButton_Click;

            Controls.Add(titleLabel);
            Controls.Add(searchTextBox);
            Controls.Add(searchButton);
            Controls.Add(linesGridView);
            Controls.Add(payInFullButton);
            Controls.Add(pancakeSyncStatusLabel);
            Controls.Add(portalSyncStatusLabel);
            Controls.Add(resendToPancakeButton);
            Controls.Add(resendToPortalButton);
            Controls.Add(showErrorsButton);
            Controls.Add(closeButton);

            LoadLines();
            RefreshPancakeSyncStatus();
            RefreshPortalSyncStatus();
        }

        // Resolves ReceiptNo from filterTransactionNo (same query PayInFullButton_Click in this
        // form already uses) and refreshes the status label from dbo.InstoreOnlineOrderMap. Same
        // friendly-text/color mapping as AdvanceOrdersHeaderForm's grid column, so both places
        // agree on what "Synced"/"Failed"/"Not Sent" mean.
        private void RefreshPancakeSyncStatus()
        {
            try
            {
                OnlinefunctionsEvents.EnsureInstoreOnlineOrderMapTable();

                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();

                    var headerCmd = new SqlCommand("SELECT ReceiptNo FROM AdvanceOrderHeader WHERE TransactionNo = @tn", conn);
                    headerCmd.Parameters.AddWithValue("@tn", filterTransactionNo);
                    resolvedReceiptNo = headerCmd.ExecuteScalar()?.ToString()?.Trim() ?? "";

                    string rawStatus = "";
                    string onlineOrderId = "";
                    if (!string.IsNullOrWhiteSpace(resolvedReceiptNo))
                    {
                        var statusCmd = new SqlCommand("SELECT LastAction, OnlineOrderId FROM dbo.InstoreOnlineOrderMap WHERE LocalReceiptNo = @receiptNo", conn);
                        statusCmd.Parameters.AddWithValue("@receiptNo", resolvedReceiptNo);
                        using var statusRdr = statusCmd.ExecuteReader();
                        if (statusRdr.Read())
                        {
                            rawStatus = statusRdr["LastAction"]?.ToString()?.Trim() ?? "";
                            onlineOrderId = statusRdr["OnlineOrderId"]?.ToString()?.Trim() ?? "";
                        }
                    }

                    string orderIdSuffix = string.IsNullOrWhiteSpace(onlineOrderId) ? "" : $" (Order #{onlineOrderId})";
                    switch (rawStatus.ToUpperInvariant())
                    {
                        case "CREATE":
                        case "UPDATE":
                            pancakeSyncStatusLabel.Text = $"Pancake: Synced{orderIdSuffix}";
                            pancakeSyncStatusLabel.ForeColor = Color.DarkGreen;
                            break;
                        case "SYNC_FAILED":
                            pancakeSyncStatusLabel.Text = $"Pancake: Failed{orderIdSuffix}";
                            pancakeSyncStatusLabel.ForeColor = Color.DarkRed;
                            break;
                        default:
                            pancakeSyncStatusLabel.Text = "Pancake: Not Sent";
                            pancakeSyncStatusLabel.ForeColor = Color.Gray;
                            break;
                    }
                }
            }
            catch (Exception ex)
            {
                pancakeSyncStatusLabel.Text = "Pancake: Unknown";
                pancakeSyncStatusLabel.ForeColor = Color.Gray;
                System.Diagnostics.Debug.WriteLine($"RefreshPancakeSyncStatus failed: {ex.Message}");
            }
        }

        // Same pattern as RefreshPancakeSyncStatus above, but reads dbo.AdvanceOrderPortalSyncMap -
        // the separate status tracked by SyncSingleAdvanceOrderToSupabase for the push into Supabase's
        // AdvanceOrders/AdvanceOrderLines tables that feeds the web portal. Relies on
        // RefreshPancakeSyncStatus having already resolved resolvedReceiptNo, so call that first.
        private void RefreshPortalSyncStatus()
        {
            try
            {
                OnlinefunctionsEvents.EnsureAdvanceOrderPortalSyncMapTable();

                string rawStatus = "";
                if (!string.IsNullOrWhiteSpace(resolvedReceiptNo))
                {
                    using var conn = new SqlConnection(connectionString);
                    conn.Open();
                    var statusCmd = new SqlCommand("SELECT LastAction FROM dbo.AdvanceOrderPortalSyncMap WHERE ReceiptNo = @receiptNo", conn);
                    statusCmd.Parameters.AddWithValue("@receiptNo", resolvedReceiptNo);
                    rawStatus = statusCmd.ExecuteScalar()?.ToString()?.Trim() ?? "";
                }

                switch (rawStatus.ToUpperInvariant())
                {
                    case "SYNCED":
                        portalSyncStatusLabel.Text = "Portal: Synced";
                        portalSyncStatusLabel.ForeColor = Color.DarkGreen;
                        break;
                    case "SYNC_FAILED":
                        portalSyncStatusLabel.Text = "Portal: Failed";
                        portalSyncStatusLabel.ForeColor = Color.DarkRed;
                        break;
                    default:
                        portalSyncStatusLabel.Text = "Portal: Not Sent";
                        portalSyncStatusLabel.ForeColor = Color.Gray;
                        break;
                }
            }
            catch (Exception ex)
            {
                portalSyncStatusLabel.Text = "Portal: Unknown";
                portalSyncStatusLabel.ForeColor = Color.Gray;
                System.Diagnostics.Debug.WriteLine($"RefreshPortalSyncStatus failed: {ex.Message}");
            }
        }

        private async Task ResendToPancakeButton_ClickAsync()
        {
            if (string.IsNullOrWhiteSpace(resolvedReceiptNo))
            {
                MessageBox.Show(this, "Could not resolve a Receipt No. for this advance order.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            resendToPancakeButton.Enabled = false;
            var previousCursor = Cursor;
            Cursor = Cursors.WaitCursor;
            try
            {
                await OnlinefunctionsEvents.SyncAdvanceOrderToCloudAsync(resolvedReceiptNo).ConfigureAwait(true);
                MessageBox.Show(this, $"Advance order {resolvedReceiptNo} was resent to Pancake successfully.", "Resend Complete", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to resend {resolvedReceiptNo} to Pancake.\n\nError: {ex.Message}", "Resend Failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                Cursor = previousCursor;
                resendToPancakeButton.Enabled = true;
                RefreshPancakeSyncStatus();
                RefreshPortalSyncStatus();
            }
        }

        // Same idea as ResendToPancakeButton_ClickAsync above, but for the separate Supabase portal
        // push (OnlinefunctionsEvents.SyncSingleAdvanceOrderToSupabaseAsync) - independent status,
        // independent resend.
        private async Task ResendToPortalButton_ClickAsync()
        {
            if (string.IsNullOrWhiteSpace(resolvedReceiptNo))
            {
                MessageBox.Show(this, "Could not resolve a Receipt No. for this advance order.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            resendToPortalButton.Enabled = false;
            var previousCursor = Cursor;
            Cursor = Cursors.WaitCursor;
            try
            {
                await OnlinefunctionsEvents.SyncSingleAdvanceOrderToSupabaseAsync(resolvedReceiptNo).ConfigureAwait(true);
                MessageBox.Show(this, $"Advance order {resolvedReceiptNo} was resent to the Portal successfully.", "Resend Complete", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to resend {resolvedReceiptNo} to the Portal.\n\nError: {ex.Message}", "Resend Failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                Cursor = previousCursor;
                resendToPortalButton.Enabled = true;
                RefreshPancakeSyncStatus();
                RefreshPortalSyncStatus();
            }
        }

        // Shows the full LastResponse text (successful API response, or the exception detail on
        // failure) recorded for this advance order by both the Pancake sync
        // (dbo.InstoreOnlineOrderMap) and the Portal sync (dbo.AdvanceOrderPortalSyncMap), so staff
        // can see exactly why a "Failed" status happened without having to read server logs.
        private void ShowErrorsButton_Click(object? sender, EventArgs e)
        {
            if (string.IsNullOrWhiteSpace(resolvedReceiptNo))
            {
                MessageBox.Show(this, "Could not resolve a Receipt No. for this advance order.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            try
            {
                OnlinefunctionsEvents.EnsureInstoreOnlineOrderMapTable();
                OnlinefunctionsEvents.EnsureAdvanceOrderPortalSyncMapTable();

                string pancakeAction = "", pancakeResponse = "", pancakeUpdated = "";
                string portalAction = "", portalResponse = "", portalUpdated = "";

                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();

                    using (var cmd = new SqlCommand("SELECT LastAction, LastResponse, UpdatedAtUtc FROM dbo.InstoreOnlineOrderMap WHERE LocalReceiptNo = @receiptNo", conn))
                    {
                        cmd.Parameters.AddWithValue("@receiptNo", resolvedReceiptNo);
                        using var rdr = cmd.ExecuteReader();
                        if (rdr.Read())
                        {
                            pancakeAction = rdr["LastAction"]?.ToString()?.Trim() ?? "";
                            pancakeResponse = rdr["LastResponse"]?.ToString() ?? "";
                            pancakeUpdated = rdr["UpdatedAtUtc"] is DateTime pdt ? pdt.ToString("yyyy-MM-dd HH:mm:ss") + " UTC" : "";
                        }
                    }

                    using (var cmd = new SqlCommand("SELECT LastAction, LastResponse, UpdatedAtUtc FROM dbo.AdvanceOrderPortalSyncMap WHERE ReceiptNo = @receiptNo", conn))
                    {
                        cmd.Parameters.AddWithValue("@receiptNo", resolvedReceiptNo);
                        using var rdr = cmd.ExecuteReader();
                        if (rdr.Read())
                        {
                            portalAction = rdr["LastAction"]?.ToString()?.Trim() ?? "";
                            portalResponse = rdr["LastResponse"]?.ToString() ?? "";
                            portalUpdated = rdr["UpdatedAtUtc"] is DateTime pdt ? pdt.ToString("yyyy-MM-dd HH:mm:ss") + " UTC" : "";
                        }
                    }
                }

                string details =
                    $"=== Pancake Sync ===\r\n" +
                    $"Status: {(string.IsNullOrWhiteSpace(pancakeAction) ? "Not Sent" : pancakeAction)}\r\n" +
                    $"Last Updated: {(string.IsNullOrWhiteSpace(pancakeUpdated) ? "-" : pancakeUpdated)}\r\n" +
                    $"Details:\r\n{(string.IsNullOrWhiteSpace(pancakeResponse) ? "(none)" : pancakeResponse)}\r\n\r\n" +
                    $"=== Portal (Supabase) Sync ===\r\n" +
                    $"Status: {(string.IsNullOrWhiteSpace(portalAction) ? "Not Sent" : portalAction)}\r\n" +
                    $"Last Updated: {(string.IsNullOrWhiteSpace(portalUpdated) ? "-" : portalUpdated)}\r\n" +
                    $"Details:\r\n{(string.IsNullOrWhiteSpace(portalResponse) ? "(none)" : portalResponse)}";

                ShowSyncDetailsDialog(details);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load sync details for {resolvedReceiptNo}.\n\nError: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ShowSyncDetailsDialog(string details)
        {
            using var dlg = new Form
            {
                Text = $"Sync Details - {resolvedReceiptNo}",
                Size = new Size(700, 500),
                StartPosition = FormStartPosition.CenterParent,
                MinimizeBox = false,
                MaximizeBox = true,
                FormBorderStyle = FormBorderStyle.Sizable
            };

            var textBox = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                Dock = DockStyle.Fill,
                Font = new Font("Consolas", 9),
                Text = details
            };

            var closeBtn = new Button
            {
                Text = "Close",
                Dock = DockStyle.Bottom,
                Height = 35,
                DialogResult = DialogResult.Cancel
            };

            dlg.Controls.Add(textBox);
            dlg.Controls.Add(closeBtn);
            dlg.CancelButton = closeBtn;
            dlg.ShowDialog(this);
        }

        // public AdvanceOrderLinesForm(string storeNo, string posTerminalNo, string transactionNo) : this()
        // {
        //     filterStoreNo = storeNo;
        //     filterPosTerminalNo = posTerminalNo;
        //     filterTransactionNo = transactionNo;
        //     LoadLines();
        // }

        private void LoadLines()
        {
            string filter = searchTextBox.Text.Trim();
            string sql = @"SELECT StoreNo, POSTerminalNo, TransactionNo, [LineNo], ReceiptNo, Type, [No.], Description, Quantity, Price, Discount, GrossAmount, NetAmount, Date, Time, EODID FROM AdvanceOrderLines";
            var whereClauses = new System.Collections.Generic.List<string>();
            if (!string.IsNullOrEmpty(filterStoreNo))
                whereClauses.Add("StoreNo = @storeNo");
            if (!string.IsNullOrEmpty(filterPosTerminalNo))
                whereClauses.Add("POSTerminalNo = @posTerminalNo");
            if (!string.IsNullOrEmpty(filterTransactionNo))
                whereClauses.Add("TransactionNo = @transactionNo");
            if (!string.IsNullOrEmpty(filter))
            {
                whereClauses.Add("(TransactionNo LIKE @filter OR ReceiptNo LIKE @filter OR Type LIKE @filter OR [No.] LIKE @filter OR Description LIKE @filter)");
            }
            if (whereClauses.Count > 0)
            {
                sql += " WHERE " + string.Join(" AND ", whereClauses);
            }
            sql += " ORDER BY TransactionNo DESC, [LineNo] ASC";

            using (var connection = new SqlConnection(connectionString))
            using (var cmd = new SqlCommand(sql, connection))
            {
                if (!string.IsNullOrEmpty(filterStoreNo))
                    cmd.Parameters.AddWithValue("@storeNo", filterStoreNo);
                if (!string.IsNullOrEmpty(filterPosTerminalNo))
                    cmd.Parameters.AddWithValue("@posTerminalNo", filterPosTerminalNo);
                if (!string.IsNullOrEmpty(filterTransactionNo))
                    cmd.Parameters.AddWithValue("@transactionNo", filterTransactionNo);
                if (!string.IsNullOrEmpty(filter))
                    cmd.Parameters.AddWithValue("@filter", "%" + filter + "%");
                var dt = new DataTable();
                connection.Open();
                using (var reader = cmd.ExecuteReader())
                {
                    dt.Load(reader);
                }
                linesGridView.DataSource = dt;
            }
        }

        private void AdvanceOrderLinesForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }

        private void PayInFullButton_Click(object? sender, EventArgs e)
        {
            // Prefer the transaction number passed to the form. If not present, try to read it from the selected row.
            string transactionNo = filterTransactionNo;
            if (string.IsNullOrEmpty(transactionNo))
            {
                if (linesGridView.SelectedRows.Count == 0)
                {
                    MessageBox.Show("Please select a line (or open this form from an Advance Order header) to identify the order.", "Select Order", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                var row = linesGridView.SelectedRows[0];
                if (linesGridView.Columns.Contains("TransactionNo"))
                    transactionNo = row.Cells["TransactionNo"].Value?.ToString() ?? "";
            }

            if (string.IsNullOrEmpty(transactionNo))
            {
                MessageBox.Show("Unable to determine Transaction No for the selected order.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Fetch header info (downpayment, balance, receipt no, customer, description)
            string receiptNo = "";
            string customerName = "";
            string orderDescription = "";
            decimal balance = 0m;
            decimal downpayment = 0m;

            // Prepare variables for UserID handling in AdvanceOrderLines
            bool advanceOrderLinesHasUserId = false;
            string headerUserId = "";

            using (var conn = new SqlConnection(connectionString))
            {
                conn.Open();
                var cmd = new SqlCommand("SELECT ReceiptNo, UserID, Downpayment, Balance, Price FROM AdvanceOrderHeader WHERE TransactionNo = @tn", conn);
                cmd.Parameters.AddWithValue("@tn", transactionNo);
                using (var rdr = cmd.ExecuteReader())
                {
                    if (rdr.Read())
                    {
                        receiptNo = rdr["ReceiptNo"]?.ToString() ?? "";
                        customerName = rdr["UserID"]?.ToString() ?? ""; // legacy: UserID stored here
                        downpayment = rdr["Downpayment"] != DBNull.Value ? Convert.ToDecimal(rdr["Downpayment"]) : 0m;
                        balance = rdr["Balance"] != DBNull.Value ? Convert.ToDecimal(rdr["Balance"]) : 0m;
                        // Price might be total amount
                        // orderDescription not stored in header; keep blank
                    }
                    else
                    {
                        MessageBox.Show("Advance order header not found.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                }

                // Determine whether AdvanceOrderLines table has a UserID column
                var checkLinesCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'AdvanceOrderLines' AND COLUMN_NAME = 'UserID'", conn);
                advanceOrderLinesHasUserId = checkLinesCmd.ExecuteScalar() != null;

                // Use the user id from header if present
                using (var cmdUser = new SqlCommand("SELECT UserID FROM AdvanceOrderHeader WHERE TransactionNo = @tn", conn))
                {
                    cmdUser.Parameters.AddWithValue("@tn", transactionNo);
                    var uid = cmdUser.ExecuteScalar();
                    headerUserId = uid != null ? uid.ToString() ?? "" : "";
                }

            }

            if (balance <= 0)
            {
                MessageBox.Show("Order has no outstanding balance.", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            // Show payment entry for the full balance
            using (var paymentForm = new PaymentEntryForm("Pay In Full", balance))
            {
                if (paymentForm.ShowDialog(this) != DialogResult.OK)
                    return;

                decimal paidAmount = paymentForm.Amount;
                string tenderCode = paymentForm.TenderType; // assume this maps to TenderTypes.Code
                int nextLine = 0;

                try
                {
                    using (var conn = new SqlConnection(connectionString))
                    {
                        conn.Open();
                        using (var tx = conn.BeginTransaction())
                        {

                            // Insert payment line into AdvanceOrderLines (include UserID when available)
                            string insertSql = advanceOrderLinesHasUserId ? @"
                                INSERT INTO AdvanceOrderLines (StoreNo, POSTerminalNo, TransactionNo, [LineNo], ReceiptNo, Type, [No.], Description, Quantity, Price, Discount, GrossAmount, NetAmount, Date, Time, EODID, UserID)
                                VALUES ('1','1',@transactionNo, @lineNo, @receiptNo, 'PAYMENT', @tenderCode, @description, 1, @amount, 0, @amount, @amount, @date, @time, '', @UserID)" : @"
                                INSERT INTO AdvanceOrderLines (StoreNo, POSTerminalNo, TransactionNo, [LineNo], ReceiptNo, Type, [No.], Description, Quantity, Price, Discount, GrossAmount, NetAmount, Date, Time, EODID)
                                VALUES ('1','1',@transactionNo, @lineNo, @receiptNo, 'PAYMENT', @tenderCode, @description, 1, @amount, 0, @amount, @amount, @date, @time, '')";

                            var insert = new SqlCommand(insertSql, conn, tx);

                            // Determine next line no
                            var getLineNo = new SqlCommand("SELECT ISNULL(MAX([LineNo]),0) + 1 FROM AdvanceOrderLines WHERE TransactionNo = @tn", conn, tx);
                            getLineNo.Parameters.AddWithValue("@tn", transactionNo);
                            nextLine = Convert.ToInt32(getLineNo.ExecuteScalar());

                            insert.Parameters.AddWithValue("@transactionNo", transactionNo);
                            insert.Parameters.AddWithValue("@lineNo", nextLine);
                            insert.Parameters.AddWithValue("@receiptNo", receiptNo);
                            insert.Parameters.AddWithValue("@tenderCode", tenderCode ?? "CASH");
                            insert.Parameters.AddWithValue("@description", $"Payment {tenderCode}");
                            insert.Parameters.AddWithValue("@amount", paidAmount);
                            insert.Parameters.AddWithValue("@date", DateTime.Now.ToString("yyyy-MM-dd"));
                            insert.Parameters.AddWithValue("@time", DateTime.Now.ToString("hh:mm:ss tt"));
                            if (advanceOrderLinesHasUserId)
                                insert.Parameters.AddWithValue("@UserID", headerUserId);
                            insert.ExecuteNonQuery();

                            // Update AdvanceOrderHeader downpayment and balance
                            // Update AdvanceOrderHeader downpayment and recompute balance as NetAmount - (Downpayment + paid)
                            var update = new SqlCommand(@"
                                UPDATE AdvanceOrderHeader
                                SET Downpayment = ISNULL(Downpayment,0) + @paid,
                                    Balance = ISNULL(NetAmount,0) - (ISNULL(Downpayment,0) + @paid)
                                WHERE TransactionNo = @tn", conn, tx);
                            update.Parameters.AddWithValue("@paid", paidAmount);
                            update.Parameters.AddWithValue("@tn", transactionNo);
                            update.ExecuteNonQuery();

                            tx.Commit();
                        }
                    }

                    // Print advance order receipt for the updated values
                    // Fetch updated downpayment and balance
                    using (var conn2 = new SqlConnection(connectionString))
                    {
                        conn2.Open();
                        var cmd2 = new SqlCommand("SELECT Downpayment, Balance FROM AdvanceOrderHeader WHERE TransactionNo = @tn", conn2);
                        cmd2.Parameters.AddWithValue("@tn", transactionNo);
                        using (var rdr = cmd2.ExecuteReader())
                        {
                            if (rdr.Read())
                            {
                                downpayment = rdr["Downpayment"] != DBNull.Value ? Convert.ToDecimal(rdr["Downpayment"]) : downpayment;
                                balance = rdr["Balance"] != DBNull.Value ? Convert.ToDecimal(rdr["Balance"]) : balance;
                            }
                        }
                    }

                    bool receiptPrinted = false;
                    bool transactionLogged = false;
                    string? warningMessage = null;

                    // Print receipt and mirror payment via MainForm when possible.
                    var mainForm = ResolveMainForm();
                    if (mainForm != null)
                    {
                        try
                        {
                            mainForm.PrintAdvanceOrderReceipt(receiptNo, customerName, orderDescription, downpayment, balance);
                            receiptPrinted = true;
                        }
                        catch (Exception exPrint)
                        {
                            warningMessage = $"Receipt printing failed: {exPrint.Message}";
                        }

                        try
                        {
                            mainForm.RecordAdvanceOrderPayment(receiptNo, transactionNo, tenderCode ?? "CASH", paidAmount, null, DateTime.Now, nextLine);
                            transactionLogged = true;
                        }
                        catch (Exception exLog)
                        {
                            warningMessage = string.IsNullOrWhiteSpace(warningMessage)
                                ? $"Transaction logging failed: {exLog.Message}"
                                : warningMessage + Environment.NewLine + $"Transaction logging failed: {exLog.Message}";
                        }
                    }
                    else
                    {
                        warningMessage = "Main POS form was not available, so the receipt was not printed and the transaction list was not updated.";
                    }

                    try
                    {
                        _ = System.Threading.Tasks.Task.Run(() =>
                        {
                            try
                            {
                                var resp = OnlinefunctionsEvents.SyncAdvanceOrderToCloud(receiptNo);
                                System.Diagnostics.Debug.WriteLine($"SyncAdvanceOrderToCloud(update) response for {receiptNo}: {resp}");
                            }
                            catch (Exception exSync)
                            {
                                System.Diagnostics.Debug.WriteLine($"SyncAdvanceOrderToCloud(update) failed for {receiptNo}: {exSync.Message}");
                            }

                            try
                            {
                                var portalResp = OnlinefunctionsEvents.SyncSingleAdvanceOrderToSupabase(receiptNo);
                                System.Diagnostics.Debug.WriteLine($"SyncSingleAdvanceOrderToSupabase(update) response for {receiptNo}: {portalResp}");
                            }
                            catch (Exception portalSyncEx)
                            {
                                System.Diagnostics.Debug.WriteLine($"SyncSingleAdvanceOrderToSupabase(update) failed for {receiptNo}: {portalSyncEx.Message}");
                            }
                        });
                    }
                    catch
                    {
                        // Ignore cloud sync scheduling failures.
                    }

                    if (receiptPrinted && transactionLogged)
                    {
                        MessageBox.Show("Payment recorded, receipt printed, and transaction logged.", "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                    else
                    {
                        MessageBox.Show(
                            "Payment was recorded, but the receipt print or transaction logging did not complete."
                            + Environment.NewLine + Environment.NewLine
                            + (warningMessage ?? "Please review the advance order and transaction list before proceeding."),
                            "Payment Warning",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Warning);
                    }
                    LoadLines();
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Failed to record payment: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private MainForm? ResolveMainForm()
        {
            Form? current = this;
            while (current != null)
            {
                if (current is MainForm mainForm)
                {
                    return mainForm;
                }

                current = current.Owner;
            }

            foreach (Form form in Application.OpenForms)
            {
                if (form is MainForm openMainForm)
                {
                    return openMainForm;
                }
            }

            return null;
        }
    }
}
