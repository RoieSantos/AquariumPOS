using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class AdvanceOrdersHeaderForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView dataGridView;
        private TextBox searchTextBox;
        private Button searchButton;
        private Button refreshButton;

        private Button payInFullButton;
        private Button resendToPancakeButton;
        private Button resendToPortalButton;
        private Button showErrorsButton;

        public AdvanceOrdersHeaderForm()
        {
            KeyPreview = true;
            this.KeyDown += AdvanceOrdersHeaderForm_KeyDown;

            Text = "Advance Orders Header";
            WindowState = FormWindowState.Maximized;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.White;

            dataGridView = new DataGridView
            {
                Dock = DockStyle.Top,
                Height = 500,
                ReadOnly = true,
                // Fill mode forces every column to share the grid's total width equally-ish - with
                // this many columns that meant every header/value was truncated to 2-3 characters
                // (per "fix the column ui so it can be readable and presentable"). AllCells instead
                // sizes each column to fit its own header text and cell contents, so nothing gets
                // cut off; if the total exceeds the visible width the grid just gets a horizontal
                // scrollbar, which is far more readable than uniformly-crushed columns.
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.AllCells,
                ColumnHeadersDefaultCellStyle = new DataGridViewCellStyle
                {
                    Font = new Font("Arial", 10, FontStyle.Bold),
                    BackColor = Color.LightGray,
                    ForeColor = Color.Black
                },
                DefaultCellStyle = new DataGridViewCellStyle
                {
                    Font = new Font("Arial", 10, FontStyle.Regular)
                }
            };

            searchTextBox = new TextBox
            {
                PlaceholderText = "Search by Transaction No, Receipt No, or UserID...",
                Dock = DockStyle.Top,
                Height = 30,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            searchButton = new Button
            {
                Text = "Search",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.DarkBlue,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            searchButton.Click += (s, e) => LoadAdvanceOrdersHeader(searchTextBox.Text);

            // Initialize refreshButton to satisfy non-nullable field and provide manual refresh
            refreshButton = new Button
            {
                Text = "Refresh",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.Blue,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            refreshButton.Click += (s, e) => LoadAdvanceOrdersHeader(searchTextBox.Text);

            payInFullButton = new Button
            {
                Text = "Pay In Full",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.DarkGreen,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            payInFullButton.Click += PayInFullButton_Click;

            resendToPancakeButton = new Button
            {
                Text = "Resend to Pancake",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.DarkOrange,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            resendToPancakeButton.Click += async (s, e) => await ResendToPancakeButton_ClickAsync();

            resendToPortalButton = new Button
            {
                Text = "Resend to Portal",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.DarkOrange,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            resendToPortalButton.Click += async (s, e) => await ResendToPortalButton_ClickAsync();

            showErrorsButton = new Button
            {
                Text = "Show Errors",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.Firebrick,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            showErrorsButton.Click += ShowErrorsButton_Click;

            Controls.Add(showErrorsButton);
            Controls.Add(resendToPortalButton);
            Controls.Add(resendToPancakeButton);
            Controls.Add(payInFullButton);
            Controls.Add(refreshButton);
            Controls.Add(searchButton);
            Controls.Add(searchTextBox);
            Controls.Add(dataGridView);

            // wire events and load all advance order headers on open
            dataGridView.CellDoubleClick += DataGridView_CellDoubleClick;
            dataGridView.CellFormatting += DataGridView_CellFormatting;
            LoadAdvanceOrdersHeader("");

        }

        // Shared by ResendToPancakeButton_ClickAsync/ResendToPortalButton_ClickAsync/ShowErrorsButton_Click
        // so all three agree on which row "the selected order" means (full row selection or just a
        // clicked cell), instead of triplicating this lookup.
        private bool TryGetSelectedReceiptNo(out string receiptNo)
        {
            receiptNo = string.Empty;

            DataGridViewRow row;
            if (dataGridView.SelectedRows.Count > 0)
            {
                row = dataGridView.SelectedRows[0];
            }
            else if (dataGridView.SelectedCells.Count > 0)
            {
                int rowIndex = dataGridView.SelectedCells[0].RowIndex;
                row = dataGridView.Rows[rowIndex];
            }
            else
            {
                MessageBox.Show("Please select an advance order.", "Select Order", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            receiptNo = row.Cells["ReceiptNo"].Value?.ToString() ?? "";
            if (string.IsNullOrWhiteSpace(receiptNo))
            {
                MessageBox.Show("Selected row does not contain a ReceiptNo.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }

            return true;
        }

        // Resends the selected order's current state to Pancake on demand - reuses the exact
        // OnlinefunctionsEvents.SyncAdvanceOrderToCloudAsync call the automatic (silent)
        // triggers already use, so it's safe to call repeatedly (idempotent UPDATE once a prior
        // successful CREATE has recorded a Pancake order id in dbo.InstoreOnlineOrderMap).
        private async Task ResendToPancakeButton_ClickAsync()
        {
            if (!TryGetSelectedReceiptNo(out string receiptNo))
                return;

            resendToPancakeButton.Enabled = false;
            var previousCursor = Cursor;
            Cursor = Cursors.WaitCursor;
            try
            {
                await OnlinefunctionsEvents.SyncAdvanceOrderToCloudAsync(receiptNo).ConfigureAwait(true);
                MessageBox.Show(this, $"Advance order {receiptNo} was resent to Pancake successfully.", "Resend Complete", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to resend {receiptNo} to Pancake.\n\nError: {ex.Message}", "Resend Failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                Cursor = previousCursor;
                resendToPancakeButton.Enabled = true;
                LoadAdvanceOrdersHeader(searchTextBox.Text);
            }
        }

        // Same idea as ResendToPancakeButton_ClickAsync above, but for the separate Supabase portal
        // push (OnlinefunctionsEvents.SyncSingleAdvanceOrderToSupabaseAsync) - independent status,
        // independent resend.
        private async Task ResendToPortalButton_ClickAsync()
        {
            if (!TryGetSelectedReceiptNo(out string receiptNo))
                return;

            resendToPortalButton.Enabled = false;
            var previousCursor = Cursor;
            Cursor = Cursors.WaitCursor;
            try
            {
                await OnlinefunctionsEvents.SyncSingleAdvanceOrderToSupabaseAsync(receiptNo).ConfigureAwait(true);
                MessageBox.Show(this, $"Advance order {receiptNo} was resent to the Portal successfully.", "Resend Complete", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to resend {receiptNo} to the Portal.\n\nError: {ex.Message}", "Resend Failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                Cursor = previousCursor;
                resendToPortalButton.Enabled = true;
                LoadAdvanceOrdersHeader(searchTextBox.Text);
            }
        }

        // Shows the full LastResponse text (successful API response, or the exception detail on
        // failure) recorded for the selected order by both the Pancake sync
        // (dbo.InstoreOnlineOrderMap) and the Portal sync (dbo.AdvanceOrderPortalSyncMap), so staff
        // can see exactly why a "Failed" status happened without having to read server logs.
        private void ShowErrorsButton_Click(object? sender, EventArgs e)
        {
            if (!TryGetSelectedReceiptNo(out string receiptNo))
                return;

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
                        cmd.Parameters.AddWithValue("@receiptNo", receiptNo);
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
                        cmd.Parameters.AddWithValue("@receiptNo", receiptNo);
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

                ShowSyncDetailsDialog(receiptNo, details);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load sync details for {receiptNo}.\n\nError: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ShowSyncDetailsDialog(string receiptNo, string details)
        {
            using var dlg = new Form
            {
                Text = $"Sync Details - {receiptNo}",
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

            var closeButton = new Button
            {
                Text = "Close",
                Dock = DockStyle.Bottom,
                Height = 35,
                DialogResult = DialogResult.Cancel
            };

            dlg.Controls.Add(textBox);
            dlg.Controls.Add(closeButton);
            dlg.CancelButton = closeButton;
            dlg.ShowDialog(this);
        }

        private void PayInFullButton_Click(object? sender, EventArgs e)
        {
            DataGridViewRow row;
            // Allow selection by full row or by clicking any cell in the row
            if (dataGridView.SelectedRows.Count > 0)
            {
                row = dataGridView.SelectedRows[0];
            }
            else if (dataGridView.SelectedCells.Count > 0)
            {
                int rowIndex = dataGridView.SelectedCells[0].RowIndex;
                row = dataGridView.Rows[rowIndex];
            }
            else
            {
                MessageBox.Show("Please select an advance order to pay.", "Select Order", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            string transactionNo = row.Cells["TransactionNo"].Value?.ToString() ?? "";
            if (string.IsNullOrEmpty(transactionNo))
            {
                MessageBox.Show("Selected row does not contain a TransactionNo.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Fetch header info
            string receiptNo = "";
            string userId = "";
            decimal balance = 0m;
            decimal downpayment = 0m;
            // keep originals to compute grand total (NetAmount)
            decimal originalDownpayment = 0m;
            decimal originalBalance = 0m;
            decimal grandTotal = 0m;
            using (var conn = new SqlConnection(connectionString))
            {
                conn.Open();
                var cmd = new SqlCommand("SELECT ReceiptNo, UserID, Downpayment, Balance FROM AdvanceOrderHeader WHERE TransactionNo = @tn", conn);
                cmd.Parameters.AddWithValue("@tn", transactionNo);
                using (var rdr = cmd.ExecuteReader())
                {
                    if (rdr.Read())
                    {
                        receiptNo = rdr["ReceiptNo"]?.ToString() ?? "";
                        userId = rdr["UserID"]?.ToString() ?? "";
                        downpayment = rdr["Downpayment"] != DBNull.Value ? Convert.ToDecimal(rdr["Downpayment"]) : 0m;
                        balance = rdr["Balance"] != DBNull.Value ? Convert.ToDecimal(rdr["Balance"]) : 0m;
                        // capture originals to compute grand total (NetAmount = downpayment + balance)
                        originalDownpayment = downpayment;
                        originalBalance = balance;
                        grandTotal = originalDownpayment + originalBalance;
                    }
                    else
                    {
                        MessageBox.Show("Advance order header not found.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                }
            }

            if (balance <= 0m)
            {
                MessageBox.Show("Order has no outstanding balance.", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            // Let user pick tender type first
            string chosenTender = "CASH";
            try
            {
                var tenders = new System.Collections.Generic.List<string>();
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    var cmd = new SqlCommand("SELECT Code FROM TenderTypes ORDER BY Code", conn);
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read())
                        {
                            var code = rdr[0]?.ToString();
                            if (!string.IsNullOrEmpty(code)) tenders.Add(code);
                        }
                    }
                }

                if (tenders.Count > 0)
                {
                    using (var tenderForm = new Form())
                    {
                        tenderForm.Text = "Select Tender Type";
                        tenderForm.Size = new Size(300, 400);
                        tenderForm.StartPosition = FormStartPosition.CenterParent;
                        tenderForm.FormBorderStyle = FormBorderStyle.FixedDialog;
                        tenderForm.MaximizeBox = false;
                        tenderForm.MinimizeBox = false;

                        // Larger, bold tender list for easier selection
                        var list = new ListBox
                        {
                            Dock = DockStyle.Fill,
                            Font = new Font("Segoe UI", 14, FontStyle.Bold),
                            ItemHeight = 34,
                            SelectionMode = SelectionMode.One,
                            BorderStyle = BorderStyle.FixedSingle,
                            IntegralHeight = false
                        };
                        list.Items.AddRange(tenders.ToArray());

                        var ok = new Button { Text = "OK", Dock = DockStyle.Bottom, Height = 44, BackColor = Color.DarkGreen, ForeColor = Color.White, Font = new Font("Segoe UI", 11, FontStyle.Bold) };
                        var cancel = new Button { Text = "Cancel", Dock = DockStyle.Bottom, Height = 44, BackColor = Color.Gray, ForeColor = Color.White, Font = new Font("Segoe UI", 11, FontStyle.Bold) };

                        ok.Click += (s, e) => { if (list.SelectedItem != null) tenderForm.DialogResult = DialogResult.OK; else MessageBox.Show("Please select a tender type.", "Select Tender", MessageBoxButtons.OK, MessageBoxIcon.Warning); };
                        cancel.Click += (s, e) => { tenderForm.DialogResult = DialogResult.Cancel; };

                        tenderForm.Controls.Add(list);
                        tenderForm.Controls.Add(ok);
                        tenderForm.Controls.Add(cancel);

                        if (tenderForm.ShowDialog(this) == DialogResult.OK && list.SelectedItem != null)
                        {
                            chosenTender = list.SelectedItem.ToString() ?? "CASH";
                        }
                        else
                        {
                            // User cancelled tender selection
                            return;
                        }
                    }
                }
            }
            catch
            {
                // On error default to CASH
                chosenTender = "CASH";
            }

            // Prompt for payment of the full balance
            using (var paymentForm = new PaymentEntryForm(chosenTender, balance))
            {
                if (paymentForm.ShowDialog(this) != DialogResult.OK)
                    return;

                decimal paid = paymentForm.Amount;
                string tenderCode = paymentForm.TenderType ?? chosenTender ?? "CASH";
                decimal appliedAmount = Math.Min(paid, balance);
                decimal changeDue = Math.Max(0m, paid - balance);

                // Require full payment here: don't allow partial payments in this flow
                if (paid < balance)
                {
                    MessageBox.Show($"Payment must be for the full outstanding balance of {balance:F2}. Partial payments are not allowed here.", "Full Payment Required", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                try
                {
                    int nextLine = 0;
                    using (var conn = new SqlConnection(connectionString))
                    {
                        conn.Open();
                        using (var tx = conn.BeginTransaction())
                        {
                            // insert payment line into AdvanceOrderLines
                            var getLineNo = new SqlCommand("SELECT ISNULL(MAX([LineNo]),0) + 1 FROM AdvanceOrderLines WHERE TransactionNo = @tn", conn, tx);
                            getLineNo.Parameters.AddWithValue("@tn", transactionNo);
                            nextLine = Convert.ToInt32(getLineNo.ExecuteScalar());

                            var insert = new SqlCommand(@"
                                INSERT INTO AdvanceOrderLines (StoreNo, POSTerminalNo, TransactionNo, [LineNo], ReceiptNo, Type, [No.], Description, Quantity, Price, Discount, GrossAmount, NetAmount, Date, Time, EODID)
                                VALUES ('1','1',@tn,@ln,@rc,'PAYMENT',@no,@desc,1,@amt,0,@amt,@amt,@date,@time,'')
                            ", conn, tx);
                            insert.Parameters.AddWithValue("@tn", transactionNo);
                            insert.Parameters.AddWithValue("@ln", nextLine);
                            insert.Parameters.AddWithValue("@rc", receiptNo);
                            insert.Parameters.AddWithValue("@no", tenderCode);
                            insert.Parameters.AddWithValue("@desc", $"Payment {tenderCode}");
                            insert.Parameters.AddWithValue("@amt", appliedAmount);
                            // insert.Parameters.AddWithValue("@UserID", userId);
                            insert.Parameters.AddWithValue("@date", DateTime.Now.ToString("yyyy-MM-dd"));
                            insert.Parameters.AddWithValue("@time", DateTime.Now.ToString("hh:mm:ss tt"));
                            insert.ExecuteNonQuery();

                            // FullyPaid/DatePaid are optional columns (see sql_advance_order_paid_
                            // status.sql) - not every install will have run that script yet, so check
                            // before referencing them. This flow always pays off the full remaining
                            // balance (partial payments are rejected above), so reaching this point
                            // means the order is now fully paid, unconditionally.
                            bool hasFullyPaidColumns = false;
                            using (var checkCmd = new SqlCommand("SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'AdvanceOrderHeader' AND COLUMN_NAME IN ('FullyPaid', 'DatePaid')", conn, tx))
                            {
                                hasFullyPaidColumns = Convert.ToInt32(checkCmd.ExecuteScalar()) == 2;
                            }

                            // Update AdvanceOrderHeader downpayment and recompute balance as NetAmount - (Downpayment + paid)
                            string updateSql = @"
                                UPDATE AdvanceOrderHeader
                                SET Downpayment = CASE
                                        WHEN ISNULL(Downpayment,0) + @paid > ISNULL(NetAmount,0) THEN ISNULL(NetAmount,0)
                                        ELSE ISNULL(Downpayment,0) + @paid
                                    END,
                                    Balance = CASE
                                        WHEN ISNULL(NetAmount,0) - (ISNULL(Downpayment,0) + @paid) < 0 THEN 0
                                        ELSE ISNULL(NetAmount,0) - (ISNULL(Downpayment,0) + @paid)
                                    END" +
                                (hasFullyPaidColumns ? ", FullyPaid = 1, DatePaid = SYSUTCDATETIME()" : "") + @"
                                WHERE TransactionNo = @tn";
                            var update = new SqlCommand(updateSql, conn, tx);
                            update.Parameters.AddWithValue("@paid", appliedAmount);
                            update.Parameters.AddWithValue("@tn", transactionNo);
                            update.ExecuteNonQuery();

                            tx.Commit();
                        }
                    }

                    // Re-fetch updated values and print receipt
                    using (var conn2 = new SqlConnection(connectionString))
                    {
                        conn2.Open();
                        var cmd2 = new SqlCommand("SELECT Downpayment, Balance FROM AdvanceOrderHeader WHERE TransactionNo = @tn", conn2);
                        cmd2.Parameters.AddWithValue("@tn", transactionNo);
                        using (var rdr2 = cmd2.ExecuteReader())
                        {
                            if (rdr2.Read())
                            {
                                downpayment = rdr2["Downpayment"] != DBNull.Value ? Convert.ToDecimal(rdr2["Downpayment"]) : downpayment;
                                balance = rdr2["Balance"] != DBNull.Value ? Convert.ToDecimal(rdr2["Balance"]) : balance;
                            }
                        }
                    }
                    //MessageBox.Show($"0after owner's recording balance {balance}");
                    bool receiptPrinted = false;
                    bool transactionLogged = false;
                    string? paymentWarning = null;

                    // If the order is now fully paid, log a sales transaction header for the grand total
                    try
                    {
                        if (balance <= 0m)
                        {
                            MainForm? mainFormForWrite = null;
                            if (this.Owner is MainForm ownerMain2)
                            {
                                mainFormForWrite = ownerMain2;
                            }
                            else
                            {
                                foreach (Form f in Application.OpenForms)
                                {
                                    if (f is MainForm mf2)
                                    {
                                        mainFormForWrite = mf2;
                                        break;
                                    }
                                }
                            }
                            if (mainFormForWrite != null)
                            {
                                var mi = typeof(MainForm).GetMethod("WriteSalesTransactionHeader", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                                mi?.Invoke(mainFormForWrite, new object[] { receiptNo, "SALES", grandTotal, "", "", "" });
                                transactionLogged = true;
                            }
                            else
                            {
                                var staticMi = typeof(MainForm).GetMethod("WriteSalesTransactionHeader", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                                staticMi?.Invoke(null, new object[] { receiptNo, "SALES", grandTotal, "", "", "" });
                                transactionLogged = true;

                            }
                            //Record Payment

                            // Also ask the MainForm instance to record this payment entry so TransPaymentEntry is populated
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

                                if (mainFormInstance != null)
                                {
                                    var mi = typeof(MainForm).GetMethod("RecordAdvanceOrderPayment", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                                    if (mi != null)
                                    {
                                        try
                                        {
                                            // Use the current transactionNo from the selected advance order header and pass the AdvanceOrderLines line number
                                            mi.Invoke(mainFormInstance, new object[] { receiptNo, transactionNo, tenderCode, appliedAmount, null, DateTime.Now, nextLine });
                                        }
                                        catch
                                        {
                                            paymentWarning = string.IsNullOrWhiteSpace(paymentWarning)
                                                ? "Payment entry mirroring into TransPaymentEntry failed."
                                                : paymentWarning + Environment.NewLine + "Payment entry mirroring into TransPaymentEntry failed.";
                                        }
                                    }
                                }
                            }
                            catch
                            {
                                paymentWarning = string.IsNullOrWhiteSpace(paymentWarning)
                                    ? "Payment entry mirroring into TransPaymentEntry failed."
                                    : paymentWarning + Environment.NewLine + "Payment entry mirroring into TransPaymentEntry failed.";
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



                            try
                            {
                                // Prefer calling MainForm's PrintReceiptDirect so printing is centralized
                                MainForm? mainFormForPrint = mainFormForWrite;
                                if (mainFormForPrint == null)
                                {
                                    foreach (Form f in Application.OpenForms)
                                    {
                                        if (f is MainForm mf)
                                        {
                                            mainFormForPrint = mf;
                                            break;
                                        }
                                    }
                                }

                                if (mainFormForPrint != null)
                                {
                                    // Prefer the centralized fully-paid advance order printer
                                    var pm = typeof(MainForm).GetMethod("PrintFullyPaidAdvanceOrderReceipt", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                                    pm?.Invoke(mainFormForPrint, new object[] { receiptNo });
                                    receiptPrinted = true;
                                }
                                else
                                {
                                    // Fallback: try to call a static PrintFullyPaidAdvanceOrderReceipt if implemented as static
                                    var staticPm = typeof(MainForm).GetMethod("PrintFullyPaidAdvanceOrderReceipt", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                                    staticPm?.Invoke(null, new object[] { receiptNo });
                                    receiptPrinted = true;
                                }
                            }
                            catch (Exception ex)
                            {
                                paymentWarning = string.IsNullOrWhiteSpace(paymentWarning)
                                    ? $"Receipt printing failed: {ex.Message}"
                                    : paymentWarning + Environment.NewLine + $"Receipt printing failed: {ex.Message}";
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        paymentWarning = string.IsNullOrWhiteSpace(paymentWarning)
                            ? $"Transaction logging failed: {ex.Message}"
                            : paymentWarning + Environment.NewLine + $"Transaction logging failed: {ex.Message}";
                    }

                    // Update the grid row in-place instead of reloading the entire dataset
                    try
                    {
                        if (dataGridView.Columns.Contains("Downpayment"))
                            row.Cells["Downpayment"].Value = downpayment;
                        if (dataGridView.Columns.Contains("Balance"))
                            row.Cells["Balance"].Value = balance;
                    }
                    catch
                    {
                        // ignore UI update errors and fall back to not refreshing
                    }


                    // revert owner's checkout button back to "CHECKOUT" for partial/downpayment (balance > 0)
                    try
                    {
                        if (balance > 0m)
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

                            if (mainFormInstance != null)
                            {
                                var field = typeof(MainForm).GetField("checkoutButton", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
                                if (field != null)
                                {
                                    var btn = field.GetValue(mainFormInstance) as Button;
                                    if (btn != null)
                                    {
                                        btn.Text = "CHECKOUT";
                                        btn.Tag = "SALES";
                                        try { btn.BackColor = SystemColors.ControlDark; } catch { }
                                    }
                                }
                            }
                        }
                    }
                    catch
                    {
                        // ignore UI update failures
                    }


                    // Always invoke PrintAdvanceOrderReceipt on the MainForm instance when possible
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

                        // if (mainFormInstance != null)
                        // {
                        //     // Use reflection to call the method whether it's public or not
                        //     var mi = typeof(MainForm).GetMethod("PrintAdvanceOrderReceipt", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                        //     mi?.Invoke(mainFormInstance, new object[] { receiptNo, userId, "", downpayment, balance });
                        // }
                        // else
                        // {
                        //     // As a fallback, try a static invocation if the method was implemented as static
                        //     var staticMi = typeof(MainForm).GetMethod("PrintAdvanceOrderReceipt", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                        //     staticMi?.Invoke(null, new object[] { receiptNo, userId, "", downpayment, balance });
                        // }
                    }
                    catch
                    {
                        // Ignore printing errors to avoid breaking the payment flow
                    }
                    if (balance <= 0m)
                    {
                        if (receiptPrinted && transactionLogged)
                        {
                            string successMessage = changeDue > 0m
                                ? $"Payment recorded, receipt printed, and transaction logged. Change due: {changeDue:F2}"
                                : "Payment recorded, receipt printed, and transaction logged.";
                            MessageBox.Show(successMessage, "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        }
                        else
                        {
                            MessageBox.Show(
                                "Payment was recorded, but the receipt print or transaction logging did not complete."
                                + Environment.NewLine + Environment.NewLine
                                + (paymentWarning ?? "Please review the transaction list and receipt output."),
                                "Payment Warning",
                                MessageBoxButtons.OK,
                                MessageBoxIcon.Warning);
                        }
                    }
                    else
                    {
                        string successMessage = changeDue > 0m
                            ? $"Payment recorded. Change due: {changeDue:F2}"
                            : "Payment recorded.";
                        MessageBox.Show(successMessage, "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Failed to record payment: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }

            // refresh handled by calling LoadAdvanceOrdersHeader after successful payment above
        }

        private void LoadAdvanceOrdersHeader(string searchTerm)
        {
            try
            {
                // Defensive - dbo.InstoreOnlineOrderMap/dbo.AdvanceOrderPortalSyncMap may not exist yet
                // on a fresh install if no Pancake/portal sync has ever run, and the LEFT JOINs below
                // would fail without them.
                OnlinefunctionsEvents.EnsureInstoreOnlineOrderMapTable();
                OnlinefunctionsEvents.EnsureAdvanceOrderPortalSyncMapTable();

                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    // PancakeSyncStatus: joined from dbo.InstoreOnlineOrderMap.LastAction - raw value is
                    // translated to friendly text/color in DataGridView_CellFormatting below. Null means
                    // this order has never been synced to Pancake at all.
                    // PortalStatus: same idea, joined from dbo.AdvanceOrderPortalSyncMap.LastAction -
                    // tracks the separate push into Supabase's AdvanceOrders/AdvanceOrderLines tables
                    // that feeds the web portal (SyncSingleAdvanceOrderToSupabase), independent of the
                    // Pancake sync above.
                    string query = "SELECT h.*, m.LastAction AS PancakeSyncStatus, p.LastAction AS PortalStatus FROM AdvanceOrderHeader h LEFT JOIN dbo.InstoreOnlineOrderMap m ON m.LocalReceiptNo = h.ReceiptNo LEFT JOIN dbo.AdvanceOrderPortalSyncMap p ON p.ReceiptNo = h.ReceiptNo";
                    if (!string.IsNullOrWhiteSpace(searchTerm))
                    {
                        query += " WHERE h.TransactionNo LIKE @search OR h.ReceiptNo LIKE @search OR h.UserID LIKE @search";
                    }
                    query += " ORDER BY h.TransactionNo DESC";
                    var command = new SqlCommand(query, connection);
                    if (!string.IsNullOrWhiteSpace(searchTerm))
                    {
                        command.Parameters.AddWithValue("@search", "%" + searchTerm + "%");
                    }
                    var adapter = new SqlDataAdapter(command);
                    var table = new DataTable();
                    adapter.Fill(table);
                    dataGridView.DataSource = table;

                    // Hide technical columns that are not needed in the header view (defensive)
                    if (dataGridView.Columns.Contains("StoreNo"))
                    {
                        var c = dataGridView.Columns["StoreNo"];
                        if (c != null)
                        {
                            try { c.Visible = false; } catch { }
                        }
                    }
                    if (dataGridView.Columns.Contains("POSTerminalNo"))
                    {
                        var c = dataGridView.Columns["POSTerminalNo"];
                        if (c != null)
                        {
                            try { c.Visible = false; } catch { }
                        }
                    }
                    if (dataGridView.Columns.Contains("TransactionNo"))
                    {
                        var c = dataGridView.Columns["TransactionNo"];
                        if (c != null)
                        {
                            try { c.Visible = false; } catch { }
                        }
                    }

                    // Page ID / Conversation ID are rarely-needed technical columns per "squeeze the
                    // ui so it can be readable.. hide the page ID and Conversation ID" - hiding them
                    // (AutoSizeColumnsMode.Fill on this grid) automatically lets the remaining columns
                    // expand into the freed space. Tries a few plausible underlying column-name
                    // spellings defensively since this table's exact schema isn't defined anywhere in
                    // source (it was evidently altered directly against the live database).
                    HideColumnIfPresent("Page ID", "Page_ID", "PageID");
                    HideColumnIfPresent("Conversation ID", "Conversation_ID", "ConversationID");

                    // Make ReceiptNo column wider for readability (defensive) - AllCells already
                    // sizes it to fit "RS-0000006687"-style values, MinimumWidth is just a safety
                    // net so it never shrinks back down on a narrow result set.
                    if (dataGridView.Columns.Contains("ReceiptNo"))
                    {
                        var rc = dataGridView.Columns["ReceiptNo"];
                        if (rc != null)
                        {
                            try
                            {
                                if (rc.MinimumWidth < 130) rc.MinimumWidth = 130;
                            }
                            catch
                            {
                                // ignore any column-thickness related errors (avoid crashing the form)
                            }
                        }
                    }

                    if (dataGridView.Columns.Contains("PancakeSyncStatus"))
                    {
                        var psc = dataGridView.Columns["PancakeSyncStatus"];
                        if (psc != null)
                        {
                            try { psc.HeaderText = "Pancake Status"; psc.MinimumWidth = 130; } catch { }
                        }
                    }

                    if (dataGridView.Columns.Contains("PortalStatus"))
                    {
                        var pst = dataGridView.Columns["PortalStatus"];
                        if (pst != null)
                        {
                            try { pst.HeaderText = "Portal Status"; pst.MinimumWidth = 130; } catch { }
                        }
                    }

                    // OnlineOrderID: h.* already includes AdvanceOrderHeader's own OnlineOrderID
                    // column (populated by OnlinefunctionsEvents.SyncAdvanceOrderToCloud on every
                    // successful CREATE/UPDATE) - just relabel it for readability, mirroring
                    // PancakeSyncStatus above.
                    if (dataGridView.Columns.Contains("OnlineOrderID"))
                    {
                        var ooc = dataGridView.Columns["OnlineOrderID"];
                        if (ooc != null)
                        {
                            try { ooc.HeaderText = "Pancake Order ID"; ooc.MinimumWidth = 120; } catch { }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                // Show full exception including stack trace to help diagnose the null reference
                MessageBox.Show($"Error loading AdvanceOrdersHeader:\n{ex}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // Hides the first candidate column name that actually exists on dataGridView - lets a
        // caller try a few plausible spellings of an underlying SQL column without needing to know
        // its exact name up front.
        private void HideColumnIfPresent(params string[] candidateNames)
        {
            foreach (var name in candidateNames)
            {
                if (dataGridView.Columns.Contains(name))
                {
                    var c = dataGridView.Columns[name];
                    if (c != null)
                    {
                        try { c.Visible = false; } catch { }
                    }
                    return;
                }
            }
        }

        private void DataGridView_CellFormatting(object? sender, DataGridViewCellFormattingEventArgs e)
        {
            if (dataGridView.Columns[e.ColumnIndex].Name == "PancakeSyncStatus")
            {
                string rawStatus = e.Value?.ToString()?.Trim() ?? "";
                Color statusColor;
                switch (rawStatus.ToUpperInvariant())
                {
                    case "CREATE":
                    case "UPDATE":
                        e.Value = "Synced";
                        statusColor = Color.DarkGreen;
                        break;
                    case "SYNC_FAILED":
                        e.Value = "Failed";
                        statusColor = Color.DarkRed;
                        break;
                    default:
                        e.Value = "Not Sent";
                        statusColor = Color.Gray;
                        break;
                }
                if (e.CellStyle != null)
                {
                    e.CellStyle.ForeColor = statusColor;
                    e.CellStyle.Font = new Font("Arial", 10, FontStyle.Bold);
                }
                e.FormattingApplied = true;
                return;
            }

            if (dataGridView.Columns[e.ColumnIndex].Name == "PortalStatus")
            {
                string rawStatus = e.Value?.ToString()?.Trim() ?? "";
                Color statusColor;
                switch (rawStatus.ToUpperInvariant())
                {
                    case "SYNCED":
                        e.Value = "Synced";
                        statusColor = Color.DarkGreen;
                        break;
                    case "SYNC_FAILED":
                        e.Value = "Failed";
                        statusColor = Color.DarkRed;
                        break;
                    default:
                        e.Value = "Not Sent";
                        statusColor = Color.Gray;
                        break;
                }
                if (e.CellStyle != null)
                {
                    e.CellStyle.ForeColor = statusColor;
                    e.CellStyle.Font = new Font("Arial", 10, FontStyle.Bold);
                }
                e.FormattingApplied = true;
                return;
            }

            if (dataGridView.Columns[e.ColumnIndex].Name == "Time" && e.Value != null)
            {
                // Try to format as AM/PM if value is DateTime or TimeSpan
                if (e.Value is DateTime dt)
                {
                    e.Value = dt.ToString("hh:mm:ss tt");
                    e.FormattingApplied = true;
                }
                else if (e.Value is TimeSpan ts)
                {
                    // Convert TimeSpan to DateTime for formatting
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
        }

        private void AdvanceOrdersHeaderForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }

        private void DataGridView_CellDoubleClick(object? sender, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex >= 0 && dataGridView.Rows[e.RowIndex].DataBoundItem is DataRowView rowView)
            {
                var row = rowView.Row;
                string storeNo = row["StoreNo"].ToString() ?? "";
                string posTerminalNo = row["POSTerminalNo"].ToString() ?? "";
                string transactionNo = row["TransactionNo"].ToString() ?? "";

                var linesForm = new AdvanceOrderLinesForm(storeNo, posTerminalNo, transactionNo);
                linesForm.ShowDialog(this);
            }
        }
    }
}
