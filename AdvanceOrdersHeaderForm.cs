using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class AdvanceOrdersHeaderForm : ThemedForm
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView dataGridView;
        private TextBox searchTextBox;
        private Button searchButton;
        private Button refreshButton;

        private Button payInFullButton;
        private Button voidOrderButton;
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

            // Wrongly punched order: full refund, same day (before EOD) only - VoidOrderButton_ClickAsync.
            voidOrderButton = new Button
            {
                Text = "Void Order (Full Refund)",
                Dock = DockStyle.Top,
                Height = 40,
                BackColor = Color.DarkRed,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            voidOrderButton.Click += async (s, e) => await VoidOrderButton_ClickAsync();

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
            // Advance orders are portal-only now (no Pancake order) - kept but hidden.
            resendToPancakeButton.Visible = false;

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
            Controls.Add(voidOrderButton);
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
            using var dlg = new ThemedForm
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

            if (IsAdvanceOrderVoided(connectionString, transactionNo))
            {
                MessageBox.Show("This advance order was voided - it can't be paid.", "Voided Order", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
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
                    using (var tenderForm = new ThemedForm())
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

                // Reaching here always means this order is about to become fully paid (partial
                // payments were rejected just above), so this is the moment to collect serials for
                // any serial-tracked lines - per "once the advance order is fully paid, ask for the
                // serial no.". Runs BEFORE any money/DB state changes below, and returns out of the
                // whole click handler (blocking the payment entirely) if staff cancels a picker that
                // had real choices to make - matches "block payment until serials are chosen" rather
                // than letting the order get marked paid with tracking left incomplete.
                if (!TryCollectSerialsForFullyPaidOrder(transactionNo, out var serialsToMarkSold))
                {
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

                    // Payment is committed at this point - serial tracking is best-effort from here
                    // on (a failure here shouldn't look like the payment itself failed, since it
                    // didn't). serialsToMarkSold came from TryCollectSerialsForFullyPaidOrder above,
                    // before payment: real in-stock serials the user picked. Units with no serial to
                    // pick are left untagged - the POS no longer creates serials; the Web Portal tags
                    // them at Ready to Ship (staff_advance_order_to_ship_with_serials).
                    try
                    {
                        if (serialsToMarkSold.Count > 0)
                        {
                            ProductSerialTrackingForm.MarkSerialsSold(serialsToMarkSold, receiptNo, AdvanceOrderSerialLink(transactionNo));
                        }
                    }
                    catch (Exception serialEx)
                    {
                        MessageBox.Show(this, $"Order was paid, but serial tracking failed: {serialEx.Message}", "Serial Tracking Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
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
                                    // Portal only - advance orders are no longer pushed to Pancake.
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

        // ---- Void Order - per "if a cashier wrongly punch a transaction (advance order) how can they reverse
        // it?": full refund, the cashier approves it themselves (who / when / why kept on the header and in the
        // portal's AdvanceOrderVoids), for an order from today or yesterday (per "can we allow next day").
        // Nothing is deleted: the refund is negative TransPaymentEntry rows on the same receipt, dated now and
        // in the open shift - so a same-day void nets to zero, and a next-day one comes out of today's drawer /
        // EOD (yesterday's closed EOD is left as it was). The header gets IsVoid,
        // which the normal sync sends up - the portal then frees its serials, delivery stops and makers
        // (supabase_advance_order_void.sql). Refused once the portal has it at Ready to Ship or later.

        internal static void EnsureAdvanceOrderVoidColumns(SqlConnection connection)
        {
            using var cmd = new SqlCommand(@"
IF OBJECT_ID('dbo.AdvanceOrderHeader', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.AdvanceOrderHeader', 'IsVoid') IS NULL
        ALTER TABLE dbo.AdvanceOrderHeader ADD IsVoid BIT NOT NULL CONSTRAINT DF_AdvanceOrderHeader_IsVoid DEFAULT (0);
    IF COL_LENGTH('dbo.AdvanceOrderHeader', 'VoidedAtUtc') IS NULL
        ALTER TABLE dbo.AdvanceOrderHeader ADD VoidedAtUtc DATETIME2 NULL;
    IF COL_LENGTH('dbo.AdvanceOrderHeader', 'VoidedBy') IS NULL
        ALTER TABLE dbo.AdvanceOrderHeader ADD VoidedBy NVARCHAR(100) NULL;
    IF COL_LENGTH('dbo.AdvanceOrderHeader', 'VoidReason') IS NULL
        ALTER TABLE dbo.AdvanceOrderHeader ADD VoidReason NVARCHAR(500) NULL;
    IF COL_LENGTH('dbo.AdvanceOrderHeader', 'VoidRefund') IS NULL
        ALTER TABLE dbo.AdvanceOrderHeader ADD VoidRefund DECIMAL(18, 2) NULL;
END", connection);
            cmd.ExecuteNonQuery();
        }

        internal static bool IsAdvanceOrderVoided(string connectionString, string transactionNo)
        {
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                EnsureAdvanceOrderVoidColumns(conn);
                using var cmd = new SqlCommand("SELECT COUNT(*) FROM dbo.AdvanceOrderHeader WHERE TransactionNo = @tn AND IsVoid = 1", conn);
                cmd.Parameters.AddWithValue("@tn", transactionNo);
                return Convert.ToInt32(cmd.ExecuteScalar()) > 0;
            }
            catch
            {
                return false;
            }
        }

        private bool TryGetSelectedOrderKeys(out string transactionNo, out string receiptNo)
        {
            transactionNo = string.Empty;
            receiptNo = string.Empty;
            if (!TryGetSelectedReceiptNo(out receiptNo))
                return false;

            var row = dataGridView.SelectedRows.Count > 0
                ? dataGridView.SelectedRows[0]
                : dataGridView.Rows[dataGridView.SelectedCells[0].RowIndex];
            transactionNo = row.Cells["TransactionNo"].Value?.ToString()?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(transactionNo))
            {
                MessageBox.Show("Selected row does not contain a TransactionNo.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
            return true;
        }

        private async Task VoidOrderButton_ClickAsync()
        {
            if (!TryGetSelectedOrderKeys(out string transactionNo, out string receiptNo))
                return;

            string customerName = string.Empty;
            string orderDescription = string.Empty;
            decimal netAmount = 0m;
            bool fromYesterday = false;
            // One refund per tender the customer paid with, on the same payment transaction it came in on.
            var refunds = new List<(string StoreNo, string PosTerminalNo, string PaymentTransactionNo, string TenderTypeCode, decimal Amount)>();

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                EnsureAdvanceOrderVoidColumns(conn);

                using (var cmd = new SqlCommand(@"
SELECT CustomerName, Order_Description, NetAmount, IsVoid,
       CASE WHEN TRY_CAST([Date] AS date) = CAST(GETDATE() AS date) THEN 0
            WHEN TRY_CAST([Date] AS date) = DATEADD(day, -1, CAST(GETDATE() AS date)) THEN 1
            ELSE NULL END AS DaysAgo,
       ISNULL(CONVERT(nvarchar(10), TRY_CAST([Date] AS date), 23), '') AS OrderDate
FROM dbo.AdvanceOrderHeader
WHERE TransactionNo = @tn", conn))
                {
                    cmd.Parameters.AddWithValue("@tn", transactionNo);
                    using var rdr = cmd.ExecuteReader();
                    if (!rdr.Read())
                    {
                        MessageBox.Show(this, "Advance order header not found.", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }
                    if (rdr["IsVoid"] is bool alreadyVoid && alreadyVoid)
                    {
                        MessageBox.Show(this, $"Advance order {receiptNo} is already voided.", "Void Order", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return;
                    }
                    if (rdr["DaysAgo"] == DBNull.Value)
                    {
                        MessageBox.Show(this, $"Only advance orders from today or yesterday can be voided.\n\nAdvance order {receiptNo} is from {rdr["OrderDate"]}.", "Can't Void", MessageBoxButtons.OK, MessageBoxIcon.Stop);
                        return;
                    }
                    fromYesterday = Convert.ToInt32(rdr["DaysAgo"]) == 1;
                    customerName = rdr["CustomerName"]?.ToString()?.Trim() ?? string.Empty;
                    orderDescription = rdr["Order_Description"]?.ToString()?.Trim() ?? string.Empty;
                    netAmount = rdr["NetAmount"] != DBNull.Value ? Convert.ToDecimal(rdr["NetAmount"]) : 0m;
                }

                // Payments already in a closed EOD are refunded too - the refund rows are new, in the open shift.
                using (var cmd = new SqlCommand(@"
SELECT StoreNo, POSTerminalNo, TransactionNo, TenderTypeCode, SUM(Amount) AS Amount
FROM dbo.TransPaymentEntry
WHERE ReceiptNo = @rc
GROUP BY StoreNo, POSTerminalNo, TransactionNo, TenderTypeCode", conn))
                {
                    cmd.Parameters.AddWithValue("@rc", receiptNo);
                    using var rdr = cmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        decimal amount = rdr["Amount"] != DBNull.Value ? Convert.ToDecimal(rdr["Amount"]) : 0m;
                        if (amount <= 0m)
                            continue;
                        refunds.Add((rdr["StoreNo"]?.ToString() ?? string.Empty,
                                     rdr["POSTerminalNo"]?.ToString() ?? string.Empty,
                                     rdr["TransactionNo"]?.ToString() ?? string.Empty,
                                     rdr["TenderTypeCode"]?.ToString() ?? string.Empty,
                                     amount));
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Couldn't load advance order {receiptNo}.\n\nError: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // The portal may already be building / shipping it - must be online to void.
            (bool Ok, string Message) portal;
            var previousCursor = Cursor;
            Cursor = Cursors.WaitCursor;
            voidOrderButton.Enabled = false;
            try
            {
                portal = await OnlinefunctionsEvents.CheckAdvanceOrderVoidOnPortalAsync(transactionNo).ConfigureAwait(true);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this,
                    $"Couldn't check advance order {receiptNo} on the portal, so it was NOT voided.\n\n" +
                    "The POS has to be online to void an advance order (the portal may already be working on it). Try again in a moment.\n\n" +
                    $"Error: {ex.Message}",
                    "Can't Void", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            finally
            {
                Cursor = previousCursor;
                voidOrderButton.Enabled = true;
            }
            if (!portal.Ok)
            {
                MessageBox.Show(this, string.IsNullOrWhiteSpace(portal.Message) ? $"The portal refused to void advance order {receiptNo}." : portal.Message,
                    "Can't Void", MessageBoxButtons.OK, MessageBoxIcon.Stop);
                return;
            }

            string? reason = PromptForVoidReason(receiptNo);
            if (reason == null)
                return;

            decimal totalRefund = refunds.Sum(r => r.Amount);
            string refundLines = refunds.Count == 0
                ? "  (no payment recorded - nothing to give back)"
                : string.Join("\n", refunds.Select(r => $"  {r.TenderTypeCode}: P{r.Amount:N2}"));
            string portalNote = portal.Message is "OK" or "Not on the portal yet." or "Already voided on the portal." or ""
                ? string.Empty
                : $"\n\nNote: {portal.Message}";
            if (MessageBox.Show(this,
                    $"VOID advance order {receiptNo}{(string.IsNullOrWhiteSpace(customerName) ? "" : " - " + customerName)}?\n\n" +
                    $"Order total: P{netAmount:N2}\n" +
                    $"Give back to the customer (full refund):\n{refundLines}\n" +
                    $"Total refund: P{totalRefund:N2}\n" +
                    (fromYesterday ? "This order is from yesterday - the refund comes out of TODAY's drawer and shows on today's EOD.\n" : string.Empty) +
                    $"\nReason: {reason}\n\n" +
                    "This can't be undone. The void is recorded under your name." + portalNote,
                    "Confirm Void", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                return;

            string voidedBy = CurrentUser.Username ?? "POS_SYSTEM";
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var tx = conn.BeginTransaction();

                DateTime now = DateTime.Now;
                foreach (var refund in refunds)
                {
                    using var lineCmd = new SqlCommand(@"
SELECT ISNULL(MAX([LineNo]), 0) + 1 FROM dbo.TransPaymentEntry
WHERE StoreNo = @storeNo AND POSTerminalNo = @posTerminalNo AND TransactionNo = @transactionNo", conn, tx);
                    lineCmd.Parameters.AddWithValue("@storeNo", refund.StoreNo);
                    lineCmd.Parameters.AddWithValue("@posTerminalNo", refund.PosTerminalNo);
                    lineCmd.Parameters.AddWithValue("@transactionNo", refund.PaymentTransactionNo);
                    int lineNo = Convert.ToInt32(lineCmd.ExecuteScalar());

                    using var insert = new SqlCommand(@"
INSERT INTO dbo.TransPaymentEntry (StoreNo, POSTerminalNo, TransactionNo, TenderTypeCode, [LineNo], ReceiptNo, Description, Amount, UserID, Date, Time, CreatedDate)
VALUES (@storeNo, @posTerminalNo, @transactionNo, @tenderTypeCode, @lineNo, @receiptNo, @description, @amount, @userID, @date, @time, @createdDate)", conn, tx);
                    insert.Parameters.AddWithValue("@storeNo", refund.StoreNo);
                    insert.Parameters.AddWithValue("@posTerminalNo", refund.PosTerminalNo);
                    insert.Parameters.AddWithValue("@transactionNo", refund.PaymentTransactionNo);
                    insert.Parameters.AddWithValue("@tenderTypeCode", refund.TenderTypeCode);
                    insert.Parameters.AddWithValue("@lineNo", lineNo);
                    insert.Parameters.AddWithValue("@receiptNo", receiptNo);
                    insert.Parameters.AddWithValue("@description", "VOID REFUND");
                    insert.Parameters.AddWithValue("@amount", -refund.Amount);
                    insert.Parameters.AddWithValue("@userID", voidedBy);
                    insert.Parameters.AddWithValue("@date", now.Date);
                    insert.Parameters.AddWithValue("@time", now.TimeOfDay);
                    insert.Parameters.AddWithValue("@createdDate", now);
                    insert.ExecuteNonQuery();
                }

                using (var update = new SqlCommand(@"
UPDATE dbo.AdvanceOrderHeader
SET IsVoid = 1, VoidedAtUtc = SYSUTCDATETIME(), VoidedBy = @by, VoidReason = @reason, VoidRefund = @refund
WHERE TransactionNo = @tn AND IsVoid = 0", conn, tx))
                {
                    update.Parameters.AddWithValue("@by", voidedBy.Length > 100 ? voidedBy.Substring(0, 100) : voidedBy);
                    update.Parameters.AddWithValue("@reason", reason.Length > 500 ? reason.Substring(0, 500) : reason);
                    update.Parameters.AddWithValue("@refund", totalRefund);
                    update.Parameters.AddWithValue("@tn", transactionNo);
                    if (update.ExecuteNonQuery() == 0)
                    {
                        tx.Rollback();
                        MessageBox.Show(this, $"Advance order {receiptNo} was already voided - nothing was refunded.", "Void Order", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        LoadAdvanceOrdersHeader(searchTextBox.Text);
                        return;
                    }
                }

                tx.Commit();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to void advance order {receiptNo} - nothing was changed.\n\nError: {ex.Message}", "Void Failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Units the cashier picked at posting (SOLD to 'ADV-<no>') go back on the shelf. The portal frees
            // them too when the void arrives; this keeps the local list right in the meantime.
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand(@"
IF OBJECT_ID('dbo.ItemSerialTracking', 'U') IS NOT NULL
    UPDATE dbo.ItemSerialTracking
    SET Status = 'IN_STOCK', SoldOnlineOrderId = NULL, SoldReceiptNo = NULL,
        UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @by
    WHERE Status = 'SOLD' AND SoldOnlineOrderId = @link", conn);
                cmd.Parameters.AddWithValue("@by", voidedBy);
                cmd.Parameters.AddWithValue("@link", AdvanceOrderSerialLink(transactionNo));
                if (cmd.ExecuteNonQuery() > 0)
                    ProductSerialTrackingForm.TriggerCloudSyncFireAndForget();
            }
            catch (Exception serialEx)
            {
                System.Diagnostics.Debug.WriteLine($"Void {receiptNo}: releasing local serials failed: {serialEx.Message}");
            }

            string syncNote;
            Cursor = Cursors.WaitCursor;
            try
            {
                await OnlinefunctionsEvents.SyncSingleAdvanceOrderToSupabaseAsync(receiptNo).ConfigureAwait(true);
                syncNote = "The portal has been updated.";
            }
            catch (Exception ex)
            {
                syncNote = $"The portal couldn't be updated just now ({ex.Message}). The POS retries every 5 minutes - no need to do anything.";
            }
            finally
            {
                Cursor = previousCursor;
            }

            PrintAdvanceOrderVoidSlip(receiptNo, customerName, orderDescription, netAmount, refunds.Select(r => (r.TenderTypeCode, r.Amount)).ToList(), reason, voidedBy);

            MessageBox.Show(this,
                $"Advance order {receiptNo} is VOIDED.\n\n" +
                $"GIVE BACK TO THE CUSTOMER:\n{refundLines}\n" +
                $"Total refund: P{totalRefund:N2}\n\n" +
                syncNote,
                "Order Voided", MessageBoxButtons.OK, MessageBoxIcon.Information);
            LoadAdvanceOrdersHeader(searchTextBox.Text);
        }

        // Required, at least 5 characters - it's the record of why the money went back.
        private string? PromptForVoidReason(string receiptNo)
        {
            using var dialog = new ThemedForm
            {
                Text = $"Void {receiptNo} - Reason",
                StartPosition = FormStartPosition.CenterParent,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MinimizeBox = false,
                MaximizeBox = false,
                ShowInTaskbar = false,
                Size = new Size(520, 300),
                BackColor = Color.White
            };
            var label = new Label
            {
                Text = "Why is this advance order being voided? (e.g. wrong item punched, wrong customer, duplicate)",
                Location = new Point(16, 16),
                Size = new Size(470, 40),
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            var reasonBox = new TextBox
            {
                Location = new Point(16, 60),
                Size = new Size(470, 110),
                Multiline = true,
                MaxLength = 500,
                Font = new Font("Arial", 11, FontStyle.Regular)
            };
            var okButton = new Button
            {
                Text = "Continue",
                Location = new Point(246, 190),
                Size = new Size(116, 40),
                BackColor = Color.DarkRed,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            var cancelButton = new Button
            {
                Text = "Cancel",
                Location = new Point(370, 190),
                Size = new Size(116, 40),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold),
                DialogResult = DialogResult.Cancel
            };
            okButton.Click += (_, _) =>
            {
                if (reasonBox.Text.Trim().Length < 5)
                {
                    MessageBox.Show(dialog, "Please type the reason (at least 5 characters).", "Reason Required", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                dialog.DialogResult = DialogResult.OK;
                dialog.Close();
            };
            dialog.Controls.Add(label);
            dialog.Controls.Add(reasonBox);
            dialog.Controls.Add(okButton);
            dialog.Controls.Add(cancelButton);
            dialog.CancelButton = cancelButton;

            return dialog.ShowDialog(this) == DialogResult.OK ? reasonBox.Text.Trim() : null;
        }

        // Paper record for the drawer: what was given back, why, and who did it (same layout as the
        // income / expense receipts in FunctionEvents). Best-effort - the void itself is already saved.
        private void PrintAdvanceOrderVoidSlip(string receiptNo, string customerName, string orderDescription, decimal netAmount,
            List<(string TenderTypeCode, decimal Amount)> refunds, string reason, string voidedBy)
        {
            try
            {
                int width = GlobalSettings.ReceiptWidth;
                string line = new string('=', width);
                var slip = new System.Text.StringBuilder();
                slip.AppendLine(line);
                slip.AppendLine("      RS PET STOP");
                slip.AppendLine(line);
                slip.AppendLine("  ADVANCE ORDER VOID");
                slip.AppendLine(line);
                slip.AppendLine($"Receipt No: {receiptNo}");
                slip.AppendLine($"Date: {DateTime.Now:yyyy-MM-dd}");
                slip.AppendLine($"Time: {DateTime.Now:HH:mm:ss}");
                slip.AppendLine($"Voided by: {voidedBy}");
                if (!string.IsNullOrWhiteSpace(customerName))
                    slip.AppendLine($"Customer: {customerName}");
                slip.AppendLine($"Order total: P{netAmount,8:F2}");
                slip.AppendLine(new string('-', width));
                slip.AppendLine("REFUNDED:");
                foreach (var refund in refunds)
                {
                    string tender = refund.TenderTypeCode.Length > 9 ? refund.TenderTypeCode.Substring(0, 9) : refund.TenderTypeCode;
                    slip.AppendLine($"{tender.PadRight(Math.Max(0, width - 11))}P{refund.Amount,9:F2}");
                }
                slip.AppendLine(new string('-', width));
                slip.AppendLine($"TOTAL REFUND:  P{refunds.Sum(r => r.Amount),8:F2}");
                slip.AppendLine();
                slip.AppendLine("Reason:");
                foreach (string chunk in ChunkText(reason, width))
                    slip.AppendLine(chunk);
                if (!string.IsNullOrWhiteSpace(orderDescription))
                {
                    slip.AppendLine("Order:");
                    foreach (string chunk in ChunkText(orderDescription, width))
                        slip.AppendLine(chunk);
                }
                slip.AppendLine();
                slip.AppendLine("Customer signature:");
                slip.AppendLine();
                slip.AppendLine(new string('_', width));
                slip.AppendLine(line);

                string content = slip.ToString();
                using var printDocument = new System.Drawing.Printing.PrintDocument();
                using var printFont = new Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);
                printDocument.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("58mm", (int)(GlobalSettings.PaperWidthInches * 100), (int)(GlobalSettings.PaperHeightInches * 100));
                printDocument.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins((int)(GlobalSettings.LeftMarginInches * 100), (int)(GlobalSettings.LeftMarginInches * 100), (int)(GlobalSettings.TopMarginInches * 100), (int)(GlobalSettings.TopMarginInches * 100));
                printDocument.PrintPage += (sender, e) =>
                {
                    if (e.Graphics == null) return;
                    float yPos = e.MarginBounds.Top;
                    float lineHeight = printFont.GetHeight(e.Graphics);
                    foreach (var raw in content.Split('\n'))
                    {
                        string text = raw.TrimEnd('\r');
                        if (text.Length > width) text = text.Substring(0, width);
                        e.Graphics.DrawString(FunctionEvents.ToAscii(text), printFont, Brushes.Black, e.MarginBounds.Left, yPos);
                        yPos += lineHeight;
                    }
                    e.HasMorePages = false;
                };
                printDocument.Print();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"The order was voided, but the void slip didn't print: {ex.Message}", "Print Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private static IEnumerable<string> ChunkText(string text, int width)
        {
            for (int pos = 0; pos < (text ?? string.Empty).Length; pos += width)
                yield return text!.Substring(pos, Math.Min(width, text.Length - pos));
        }

        private sealed class SerialTrackedAdvanceOrderLine
        {
            public string ItemCode { get; init; } = string.Empty;
            public string VariantCode { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public int Quantity { get; init; }
        }

        // Same serial-tracking rule MainForm's live checkout uses (ShouldRequireAquariumSerialSelection/
        // IsProductionCategoryCode) - deliberately duplicated locally rather than widening those
        // MainForm instance methods, since MainForm's version also unconditionally folds in whatever
        // is sitting in the live salesListView cart via GetSelectedSaleSerialNumbers(), which has
        // nothing to do with an advance order being paid off here and would be the wrong exclusion
        // set to reuse.
        private static bool IsSerialTrackedAdvanceOrderItemCode(string? itemCode, bool isProductionCategory)
        {
            string normalizedItemCode = itemCode?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(normalizedItemCode))
                return false;

            // Custom stickers are cut to size, not built - no serials (aol.[No.] holds the line's
            // Category, so the Custom Stickers dialog's lines arrive here as "CUSTOM-STICKER").
            if (string.Equals(normalizedItemCode, "CUSTOM-STICKER", StringComparison.OrdinalIgnoreCase))
                return false;

            return normalizedItemCode.StartsWith("AQ-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM-", StringComparison.OrdinalIgnoreCase)
                || normalizedItemCode.StartsWith("CUSTOM_", StringComparison.OrdinalIgnoreCase)
                || isProductionCategory;
        }

        // Loads this order's ITEM lines (skips PAYMENT lines) joined to Items/Category to figure out
        // which ones need a serial picked, and how many units each needs.
        private List<SerialTrackedAdvanceOrderLine> LoadSerialTrackedLines(string transactionNo)
        {
            var lines = new List<SerialTrackedAdvanceOrderLine>();

            using var conn = new SqlConnection(connectionString);
            conn.Open();

            // AdvanceOrderLines.VariationId may not exist on every install (same defensive check
            // LoadAdvanceOrderCloudContext already does for the Pancake sync) - fall back to Items'
            // variationid alone when it's missing.
            bool advanceOrderLinesHasVariationId;
            using (var checkVariationCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'AdvanceOrderLines' AND COLUMN_NAME = 'VariationId'", conn))
            {
                advanceOrderLinesHasVariationId = checkVariationCmd.ExecuteScalar() != null;
            }

            string variantCodeSql = advanceOrderLinesHasVariationId
                ? "ISNULL(NULLIF(aol.VariationId, ''), ISNULL(i.variationid, ''))"
                : "ISNULL(i.variationid, '')";

            using var cmd = new SqlCommand($@"
SELECT aol.[No.] AS ItemCode, aol.Description, aol.Quantity,
       {variantCodeSql} AS VariantCode,
       ISNULL(c.IsProductionCategory, 0) AS IsProductionCategory
FROM AdvanceOrderLines aol
LEFT JOIN Items i ON i.Code = aol.[No.]
LEFT JOIN Category c ON c.Code = i.CategoryCode
WHERE aol.TransactionNo = @tn AND UPPER(ISNULL(aol.Type, '')) = 'ITEM'
ORDER BY aol.[LineNo]", conn);
            cmd.Parameters.AddWithValue("@tn", transactionNo);

            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string itemCode = rdr["ItemCode"]?.ToString()?.Trim() ?? string.Empty;
                bool isProductionCategory = rdr["IsProductionCategory"] != DBNull.Value && Convert.ToBoolean(rdr["IsProductionCategory"]);
                if (!IsSerialTrackedAdvanceOrderItemCode(itemCode, isProductionCategory))
                    continue;

                int quantity = rdr["Quantity"] != DBNull.Value ? Convert.ToInt32(rdr["Quantity"]) : 0;
                if (quantity <= 0)
                    continue;

                lines.Add(new SerialTrackedAdvanceOrderLine
                {
                    ItemCode = itemCode,
                    VariantCode = rdr["VariantCode"]?.ToString()?.Trim() ?? string.Empty,
                    Description = rdr["Description"]?.ToString()?.Trim() ?? string.Empty,
                    Quantity = quantity
                });
            }

            return lines;
        }

        // Collects serials for every serial-tracked line on this order, BEFORE any payment/DB state
        // changes - so cancelling here (a picker with real choices dismissed) cleanly aborts the
        // whole "Pay In Full" action, per "block payment until serials are chosen". A line with no
        // (or not enough) available serials doesn't block: the POS no longer creates serials (per
        // "all local pos dont create serials.. only in the portal can"), so the missing units stay
        // untagged and the Web Portal tags them at Ready to Ship (staff_advance_order_to_ship_with_serials).
        private bool TryCollectSerialsForFullyPaidOrder(
            string transactionNo,
            out List<string> serialsToMarkSold)
        {
            serialsToMarkSold = new List<string>();

            // Non-production stores don't ask at all - advance orders are exactly how made-to-order
            // builds get sold there (never a regular sale) and the physical unit typically doesn't
            // exist yet. Whatever gets built ends up tagged in the Web Portal. Production warehouses
            // keep the picker for units already on hand.
            bool isProductionWarehouse = IsCurrentWarehouseProduction();
            if (!isProductionWarehouse)
                return true;

            var lines = LoadSerialTrackedLines(transactionNo);
            if (lines.Count == 0)
                return true;

            // Units already tagged to this order (SOLD to its ReceiptNo) aren't asked for again - e.g.
            // picked or created in the Web Portal at Ready to Ship (supabase_advance_order_serials.sql),
            // pulled down by SyncItemSerialTrackingFromSupabaseAsync.
            lines = SubtractAlreadyTaggedUnits(transactionNo, lines);
            if (lines.Count == 0)
                return true;

            var alreadyPicked = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var line in lines)
            {
                var available = ProductSerialTrackingForm.GetAvailableSerials(line.ItemCode, line.VariantCode, alreadyPicked);
                int required = line.Quantity;
                int missing = Math.Max(0, required - available.Count);

                if (missing > 0)
                {
                    MessageBox.Show(this,
                        $"Only {available.Count} serial-tracked unit(s) are available for {line.ItemCode}, but {required} were requested. The remaining {missing} stay untagged - tag them in the Web Portal at Ready to Ship (the POS doesn't create serials).",
                        "Serial Tracking",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                }

                int pickCount = Math.Min(required, available.Count);
                for (int index = 0; index < pickCount; index++)
                {
                    var remainingOptions = available
                        .Where(option => !alreadyPicked.Contains(option.SerialNo))
                        .ToList();

                    var chosen = PromptForAdvanceOrderSerial(line.ItemCode, line.VariantCode, line.Description, index + 1, pickCount, remainingOptions);
                    if (chosen == null)
                    {
                        return false;
                    }

                    alreadyPicked.Add(chosen.SerialNo);
                    serialsToMarkSold.Add(chosen.SerialNo);
                }
            }

            return true;
        }

        // What ties a serial to an advance order (ItemSerialTracking.SoldOnlineOrderId) - same value the Web
        // Portal writes at Ready to Ship (supabase_advance_order_serials.sql). The 'ADV-' prefix never
        // matches a Pancake online order ID.
        private static string AdvanceOrderSerialLink(string transactionNo) => "ADV-" + (transactionNo ?? string.Empty).Trim();

        // Drops units that already have a SOLD serial tied to this order, per item/variant,
        // spread over the lines in order. Best-effort: if the lookup fails, every unit is asked for as before.
        private List<SerialTrackedAdvanceOrderLine> SubtractAlreadyTaggedUnits(string transactionNo, List<SerialTrackedAdvanceOrderLine> lines)
        {
            var tagged = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                // Linked by SoldOnlineOrderId = 'ADV-<TransactionNo>' (AdvanceOrderSerialLink), not the
                // receipt: receipt numbers repeat across stores, and serials from every store are pulled here.
                using var cmd = new SqlCommand(@"
SELECT s.ItemCode, ISNULL(s.VariantCode, '') AS VariantCode, COUNT(*) AS Tagged
FROM dbo.ItemSerialTracking s
WHERE s.SoldOnlineOrderId = @link AND s.Status = 'SOLD'
GROUP BY s.ItemCode, ISNULL(s.VariantCode, '')", conn);
                cmd.Parameters.AddWithValue("@link", AdvanceOrderSerialLink(transactionNo));
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string key = (rdr["ItemCode"]?.ToString()?.Trim() ?? string.Empty) + "|" + (rdr["VariantCode"]?.ToString()?.Trim() ?? string.Empty);
                    tagged[key] = Convert.ToInt32(rdr["Tagged"]);
                }
            }
            catch
            {
                return lines;
            }

            var remaining = new List<SerialTrackedAdvanceOrderLine>();
            foreach (var line in lines)
            {
                string key = line.ItemCode + "|" + line.VariantCode;
                int alreadyTagged = tagged.TryGetValue(key, out var count) ? count : 0;
                int covered = Math.Min(alreadyTagged, line.Quantity);
                if (covered > 0)
                    tagged[key] = alreadyTagged - covered;
                if (line.Quantity - covered > 0)
                {
                    remaining.Add(new SerialTrackedAdvanceOrderLine
                    {
                        ItemCode = line.ItemCode,
                        VariantCode = line.VariantCode,
                        Description = line.Description,
                        Quantity = line.Quantity - covered
                    });
                }
            }
            return remaining;
        }

        private bool IsCurrentWarehouseProduction()
        {
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT TOP 1 ISNULL(Is_Production_Warehouse, 0) FROM dbo.Warehouses WHERE Current_Warehouse = 1 ORDER BY [ID]", conn);
                var result = cmd.ExecuteScalar();
                return result != null && result != DBNull.Value && Convert.ToBoolean(result);
            }
            catch
            {
                return false;
            }
        }

        // Same picker UI as MainForm.PromptForAquariumSaleSerial, reproduced locally for the same
        // reason PromptForAquariumSaleSerials/ShouldRequireAquariumSerialSelection are - a self-
        // contained dialog is simpler than reusing a MainForm instance method whose only other
        // caller is coupled to the live sale cart.
        private ProductSerialTrackingForm.AvailableSerialRecord? PromptForAdvanceOrderSerial(
            string itemCode,
            string? variantCode,
            string? itemDescription,
            int selectionIndex,
            int totalSelections,
            List<ProductSerialTrackingForm.AvailableSerialRecord> availableSerials)
        {
            if (availableSerials == null || availableSerials.Count == 0)
                return null;

            using var dialog = new ThemedForm
            {
                Text = "Select Item Serial",
                StartPosition = FormStartPosition.CenterParent,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MinimizeBox = false,
                MaximizeBox = false,
                ShowInTaskbar = false,
                Size = new Size(720, 520),
                BackColor = Color.White
            };

            var titleLabel = new Label
            {
                Text = totalSelections > 1
                    ? $"Select item {selectionIndex} of {totalSelections}"
                    : "Select the item to sell",
                Location = new Point(20, 20),
                Size = new Size(660, 28),
                Font = new Font("Arial", 12, FontStyle.Bold),
                ForeColor = Color.DarkBlue
            };

            var infoLabel = new Label
            {
                Text = string.IsNullOrWhiteSpace(itemDescription)
                    ? (string.IsNullOrWhiteSpace(variantCode)
                        ? $"Choose an available serial-tracked item for {itemCode}."
                        : $"Choose an available serial-tracked item for {itemCode} variant {variantCode}.")
                    : (string.IsNullOrWhiteSpace(variantCode)
                        ? $"Choose an available serial-tracked item for {itemDescription} ({itemCode})."
                        : $"Choose an available serial-tracked item for {itemDescription} ({itemCode} / {variantCode})."),
                Location = new Point(20, 54),
                Size = new Size(660, 34),
                Font = new Font("Arial", 9, FontStyle.Regular),
                ForeColor = Color.DimGray
            };

            var listBox = new ListBox
            {
                Location = new Point(20, 96),
                Size = new Size(660, 320),
                Font = new Font("Arial", 10, FontStyle.Regular),
                DisplayMember = nameof(ProductSerialTrackingForm.AvailableSerialRecord.DisplayText)
            };

            foreach (var availableSerial in availableSerials)
            {
                listBox.Items.Add(availableSerial);
            }

            if (listBox.Items.Count > 0)
            {
                listBox.SelectedIndex = 0;
            }

            var okButton = new Button
            {
                Text = "Select",
                Location = new Point(430, 430),
                Size = new Size(120, 38),
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var cancelButton = new Button
            {
                Text = "Cancel",
                Location = new Point(560, 430),
                Size = new Size(120, 38),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            ProductSerialTrackingForm.AvailableSerialRecord? selectedSerial = null;
            okButton.Click += (_, _) =>
            {
                if (listBox.SelectedItem is not ProductSerialTrackingForm.AvailableSerialRecord choice)
                {
                    MessageBox.Show(dialog,
                        "Select an available serial first.",
                        "Serial Tracking",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                    return;
                }

                selectedSerial = choice;
                dialog.DialogResult = DialogResult.OK;
                dialog.Close();
            };

            cancelButton.Click += (_, _) =>
            {
                dialog.DialogResult = DialogResult.Cancel;
                dialog.Close();
            };

            listBox.DoubleClick += (_, _) =>
            {
                okButton.PerformClick();
            };

            dialog.AcceptButton = okButton;
            dialog.CancelButton = cancelButton;
            dialog.Controls.Add(titleLabel);
            dialog.Controls.Add(infoLabel);
            dialog.Controls.Add(listBox);
            dialog.Controls.Add(okButton);
            dialog.Controls.Add(cancelButton);

            return dialog.ShowDialog(this) == DialogResult.OK ? selectedSerial : null;
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
                    // Messenger PSID from the advance-order customer box - just the chat link, not for the grid.
                    HideColumnIfPresent("CustomerPsid");

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

                    if (dataGridView.Columns.Contains("IsVoid"))
                    {
                        var vc = dataGridView.Columns["IsVoid"];
                        if (vc != null)
                        {
                            try { vc.HeaderText = "Voided"; } catch { }
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
            // Voided orders (Void Order) stand out in red on every cell.
            if (e.RowIndex >= 0 && e.CellStyle != null && dataGridView.Columns.Contains("IsVoid")
                && dataGridView.Rows[e.RowIndex].Cells["IsVoid"].Value is bool rowVoid && rowVoid)
            {
                e.CellStyle.BackColor = Color.MistyRose;
                e.CellStyle.ForeColor = Color.DarkRed;
            }

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
