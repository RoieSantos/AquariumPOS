using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Drawing;
using System.Drawing.Printing;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace AquariumPOS
{
    // This class is for storing global functions and event helpers
    public static class FunctionEvents
    {
        // Deletes all data from key tables after confirmation
        public static void ConfirmAndDeleteAllTables(Form? owner = null)
        {
            var confirmDelete = MessageBox.Show(owner,
                "Are you sure you want to delete ALL data from key tables? This action cannot be undone.",
                "Confirm Data Deletion",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (confirmDelete == DialogResult.Yes)
            {
                try
                {
                    using (var connection = new SqlConnection(connectionString))
                    {
                        connection.Open();
                        var tables = new[] {
                            "AdvanceOrderHeader",
                            "AdvanceOrderLines",
                            "CashFloatLines",
                            "ItemLedgerEntry",
                            "LoginLogs",
                            "Prod_Order_Header",
                            "Prod_Order_Lines",
                            "TenderDeclLines",
                            "TransactionHeader",
                            "TransPaymentEntry"
                        };
                        foreach (var table in tables)
                        {
                            var cmd = new SqlCommand($"DELETE FROM [{table}]", connection);
                            cmd.ExecuteNonQuery();
                        }
                    }
                    MessageBox.Show(owner,
                        "All specified tables have been cleared.",
                        "Data Deleted",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(owner,
                        $"Error deleting data: {ex.Message}",
                        "Error",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                }
            }
        }

        // Updates EODID in all related tables where EODID is blank or NULL
        public static void UpdateEODIDForAllTables(SqlConnection connection, string eodID)
        {
            string[] updateSqls = new string[] {
                "UPDATE TransactionHeader SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')",
                "UPDATE TransPaymentEntry SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')",
                "UPDATE TenderDeclLines SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')",
                "UPDATE ItemLedgerEntry SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')",
                "UPDATE CashFloatLines SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')",
                // Advance order tables
                "UPDATE AdvanceOrderHeader SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')",
                "UPDATE AdvanceOrderLines SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')",
                // Production order tables
                "UPDATE Prod_Order_Header SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')",
                "UPDATE Prod_Order_Lines SET EODID = @EODID WHERE (EODID IS NULL OR LTRIM(RTRIM(EODID)) = '')"
            };
            foreach (var sql in updateSqls)
            {
                using (var updateCmd = new SqlCommand(sql, connection))
                {
                    updateCmd.Parameters.AddWithValue("@EODID", eodID);
                    updateCmd.ExecuteNonQuery();
                }
            }
        }
        public static readonly string connectionString = GlobalSettings.ConnectionString;

        // Prompts for customer name before posting
        public static string PromptForCustomerName(Form? owner = null, string? initialCustomerName = null)
        {
            using (var customerForm = new Form())
            {
                customerForm.Text = "Enter Customer Name";
                customerForm.Size = new System.Drawing.Size(700, 400);
                customerForm.StartPosition = FormStartPosition.CenterParent;
                customerForm.FormBorderStyle = FormBorderStyle.None; // Remove title bar (no close button)
                customerForm.MaximizeBox = false;
                customerForm.MinimizeBox = false;

                var label = new Label
                {
                    Text = "Customer Name:",
                    Left = 40,
                    Top = 20,
                    Width = 600,
                    Height = 60,
                    Font = new System.Drawing.Font("Arial", 32, System.Drawing.FontStyle.Bold)
                };
                var textBox = new TextBox
                {
                    Left = 40,
                    Top = 100,
                    Width = 600,
                    Height = 120,
                    Font = new System.Drawing.Font("Arial", 28),
                    Multiline = true,
                    ScrollBars = ScrollBars.Vertical
                };
                textBox.Text = string.IsNullOrWhiteSpace(initialCustomerName) ? string.Empty : initialCustomerName.Trim();
                // Force all caps as user types
                textBox.TextChanged += (s, e) =>
                {
                    int selStart = textBox.SelectionStart;
                    int selLength = textBox.SelectionLength;
                    string upper = textBox.Text.ToUpper();
                    if (textBox.Text != upper)
                    {
                        textBox.Text = upper;
                        textBox.SelectionStart = selStart;
                        textBox.SelectionLength = selLength;
                    }
                };
                var okButton = new Button
                {
                    Text = "OK",
                    Left = 260,
                    Top = 250,
                    Width = 180,
                    Height = 70,
                    Font = new System.Drawing.Font("Arial", 24, System.Drawing.FontStyle.Bold),
                    DialogResult = DialogResult.OK
                };
                customerForm.Controls.Add(label);
                customerForm.Controls.Add(textBox);
                customerForm.Controls.Add(okButton);
                customerForm.AcceptButton = okButton;
                customerForm.Shown += (s, e) =>
                {
                    try
                    {
                        textBox.Focus();
                        textBox.SelectAll();
                    }
                    catch { }
                };

                string customerName = string.Empty;
                okButton.Click += (s, e) =>
                {
                    string input = textBox.Text.Trim();
                    if (string.IsNullOrEmpty(input))
                    {
                        MessageBox.Show("Please enter a customer name before posting.", "Missing Customer Name", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        textBox.Focus();
                    }
                    else
                    {
                        customerName = input;
                        customerForm.DialogResult = DialogResult.OK;
                        customerForm.Close();
                    }
                };
                // Prevent closing by intercepting form closing event
                customerForm.FormClosing += (s, e) =>
                {
                    if (customerForm.DialogResult != DialogResult.OK || string.IsNullOrWhiteSpace(customerName))
                    {
                        e.Cancel = true;
                        MessageBox.Show("You must enter and confirm customer name before closing.", "Customer Name Required", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                };
                if (owner != null)
                    customerForm.ShowDialog(owner);
                else
                    customerForm.ShowDialog();
                return customerName;
            }
        }


        // Prompts for order description before posting
        public static string PromptForOrderDescription(Form? owner = null, string? initialOrderDescription = null)
        {
            using (var descForm = new Form())
            {
                descForm.Text = "Enter Order Description";
                descForm.Size = new System.Drawing.Size(900, 500);
                descForm.StartPosition = FormStartPosition.CenterParent;
                descForm.FormBorderStyle = FormBorderStyle.None; // Remove title bar (no close button)
                descForm.MaximizeBox = false;
                descForm.MinimizeBox = false;

                var label = new Label
                {
                    Text = "Order Description:",
                    Left = 40,
                    Top = 20,
                    Width = 800,
                    Height = 80,
                    Font = new System.Drawing.Font("Arial", 40, System.Drawing.FontStyle.Bold)
                };
                var textBox = new TextBox
                {
                    Left = 40,
                    Top = 120,
                    Width = 800,
                    Height = 200,
                    Font = new System.Drawing.Font("Arial", 32),
                    Multiline = true,
                    ScrollBars = ScrollBars.Vertical
                };
                textBox.Text = string.IsNullOrWhiteSpace(initialOrderDescription) ? string.Empty : initialOrderDescription.Trim();
                // Force all caps as user types
                textBox.TextChanged += (s, e) =>
                {
                    int selStart = textBox.SelectionStart;
                    int selLength = textBox.SelectionLength;
                    string upper = textBox.Text.ToUpper();
                    if (textBox.Text != upper)
                    {
                        textBox.Text = upper;
                        textBox.SelectionStart = selStart;
                        textBox.SelectionLength = selLength;
                    }
                };
                var okButton = new Button
                {
                    Text = "OK",
                    Left = 350,
                    Top = 350,
                    Width = 200,
                    Height = 80,
                    Font = new System.Drawing.Font("Arial", 32, System.Drawing.FontStyle.Bold),
                    DialogResult = DialogResult.OK
                };
                descForm.Controls.Add(label);
                descForm.Controls.Add(textBox);
                descForm.Controls.Add(okButton);
                descForm.AcceptButton = okButton;
                descForm.Shown += (s, e) =>
                {
                    try
                    {
                        textBox.Focus();
                        textBox.SelectAll();
                    }
                    catch { }
                };

                string orderDesc = string.Empty;
                okButton.Click += (s, e) =>
                {
                    string input = textBox.Text.Trim();
                    if (string.IsNullOrEmpty(input))
                    {
                        MessageBox.Show("Please enter an order description before posting.", "Missing Order Description", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        textBox.Focus();
                    }
                    else
                    {
                        orderDesc = input;
                        descForm.DialogResult = DialogResult.OK;
                        descForm.Close();
                    }
                };
                // Prevent closing by intercepting form closing event
                descForm.FormClosing += (s, e) =>
                {
                    if (descForm.DialogResult != DialogResult.OK || string.IsNullOrWhiteSpace(orderDesc))
                    {
                        e.Cancel = true;
                        MessageBox.Show("You must enter and confirm order description before closing.", "Order Description Required", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                };
                if (owner != null)
                    descForm.ShowDialog(owner);
                else
                    descForm.ShowDialog();
                return orderDesc;
            }
        }



        // Example: Show a message box
        public static void ShowInfo(string message, string title = "Info")
        {
            MessageBox.Show(message, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        // Convert a string to an ASCII-only representation suitable for printing.
        // This removes diacritics and common Unicode punctuation, mapping them to ASCII equivalents.
        public static string ToAscii(string input)
        {
            if (string.IsNullOrEmpty(input))
                return input ?? "";

            // Normalize to decompose combined characters (e.g., é -> e + ´)
            string normalized = input.Normalize(System.Text.NormalizationForm.FormD);
            var sb = new System.Text.StringBuilder();
            foreach (char ch in normalized)
            {
                var cat = System.Globalization.CharUnicodeInfo.GetUnicodeCategory(ch);
                // Skip non-spacing marks (diacritics)
                if (cat == System.Globalization.UnicodeCategory.NonSpacingMark)
                    continue;

                if (ch <= 127)
                {
                    // Basic ASCII, keep as-is
                    sb.Append(ch);
                }
                else
                {
                    // Map a few common Unicode punctuation characters to ASCII equivalents
                    switch (ch)
                    {
                        case '\u2013': // en dash
                        case '\u2014': // em dash
                            sb.Append('-');
                            break;
                        case '\u2018': // left single quote
                        case '\u2019': // right single quote
                            sb.Append('\'');
                            break;
                        case '\u201C': // left double quote
                        case '\u201D': // right double quote
                            sb.Append('"');
                            break;
                        case '\u2026': // ellipsis
                            sb.Append("...");
                            break;
                        default:
                            // For other characters, attempt to use the ASCII fallback if possible
                            // otherwise ignore the character
                            break;
                    }
                }
            }

            string result = sb.ToString();
            // Replace any remaining control characters with spaces
            result = System.Text.RegularExpressions.Regex.Replace(result, "[\u0000-\u001F\u007F]+", " ");
            return result;
        }


        // Generates the next ProdOrderNo in the format 'PROD_0000000001'
        public static string GenerateNextProdOrderNo()
        {
            long nextNumber = 1;
            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                var cmd = new SqlCommand("SELECT MAX(ProdOrderNo) FROM Prod_Order_Header WHERE ProdOrderNo LIKE 'PROD_%'", connection);
                var result = cmd.ExecuteScalar();
                if (result != null && result != DBNull.Value)
                {
                    string maxProdOrderNo = result?.ToString() ?? string.Empty;
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

        // Centralized method to generate receipt numbers for all transactions.
        // This will consult TransactionHeader for the last RS- receipt number and
        // advance the ReceiptNumberSequence accordingly. Returns a formatted "RS-<Location>-XXXXXX".
        public static string GenerateCentralizedReceiptNumber()
        {
            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                using (var transaction = connection.BeginTransaction())
                {
                    try
                    {
                        long nextNumber = 0;
                        string locationCode = GetCurrentWarehouseReceiptCode(connection, transaction);

                        // Try to get the last numeric suffix of receipts stored in TransactionHeader using RS- prefix
                        try
                        {
                            var getLastCmd = new SqlCommand(@"SELECT MAX(TRY_CAST(RIGHT(ReceiptNo, CHARINDEX('-', REVERSE(ReceiptNo)) - 1) AS BIGINT))
FROM TransactionHeader
WHERE ReceiptNo LIKE 'RS-%' AND CHARINDEX('-', REVERSE(ReceiptNo)) > 0", connection, transaction);
                            var result = getLastCmd.ExecuteScalar();
                            if (result != null && result != DBNull.Value)
                            {
                                long lastFromHeader = Convert.ToInt64(result);
                                nextNumber = lastFromHeader + 1;

                                // Sync ReceiptNumberSequence to this number to keep sequence table consistent
                                var syncCmd = new SqlCommand("UPDATE ReceiptNumberSequence SET LastReceiptNumber = @num", connection, transaction);
                                syncCmd.Parameters.AddWithValue("@num", nextNumber);
                                syncCmd.ExecuteNonQuery();
                            }
                        }
                        catch
                        {
                            // ignore parsing errors and fall back to sequence table
                            nextNumber = 0;
                        }

                        if (nextNumber == 0)
                        {
                            // Fallback: increment ReceiptNumberSequence in a thread-safe way
                            var updateCmd = new SqlCommand(@"UPDATE ReceiptNumberSequence SET LastReceiptNumber = LastReceiptNumber + 1 OUTPUT INSERTED.LastReceiptNumber", connection, transaction);
                            nextNumber = Convert.ToInt64(updateCmd.ExecuteScalar());
                        }

                        transaction.Commit();
                        return FormatReceiptNumber(locationCode, nextNumber);
                    }
                    catch
                    {
                        transaction.Rollback();
                        throw;
                    }
                }
            }
        }

        private static string GetCurrentWarehouseReceiptCode(SqlConnection connection, SqlTransaction transaction)
        {
            try
            {
                using var cmd = new SqlCommand(@"SELECT TOP 1 Name
FROM dbo.Warehouses
WHERE ISNULL(Current_Warehouse, 0) = 1
ORDER BY Name", connection, transaction);
                var result = cmd.ExecuteScalar()?.ToString()?.Trim() ?? string.Empty;
                var cleaned = new string(result.Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();
                if (string.IsNullOrWhiteSpace(cleaned))
                    return "MAIN";

                return cleaned.Length <= 3 ? cleaned : cleaned.Substring(0, 3);
            }
            catch
            {
                return "MAIN";
            }
        }

        private static string FormatReceiptNumber(string locationCode, long nextNumber)
        {
            string safeLocationCode = string.IsNullOrWhiteSpace(locationCode)
                ? "MAIN"
                : new string(locationCode.Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();

            if (string.IsNullOrWhiteSpace(safeLocationCode))
                safeLocationCode = "MAIN";

            if (safeLocationCode.Length > 3)
                safeLocationCode = safeLocationCode.Substring(0, 3);

            return $"RS-{safeLocationCode}-{nextNumber:D10}";
        }


        // Gets the production status code for stage 1
        public static string Get1stProductionStatusCode()
        {
            string prodStatusCode = "Completed"; // Default value
            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                var cmd = new SqlCommand("SELECT TOP 1 Code FROM ProductionStatus WHERE Stages = '1' ORDER BY Code", connection);
                var result = cmd.ExecuteScalar();
                if (result != null)
                    prodStatusCode = result.ToString() ?? "Completed";
            }
            return prodStatusCode;
        }

        // Returns the total quantity of non-payment items in a ListView
        public static int GetNonPaymentItemCount(ListView salesListView)
        {
            return salesListView.Items.Cast<ListViewItem>()
                .Where(item => item.Tag?.ToString() != "PAYMENT"
                    && item.Tag?.ToString() != "AQUARIUM_SET_DISCOUNT"
                    && item.Tag?.ToString() != "AQUARIUM_SET_ACCESSORY")
                .Sum(item => int.Parse(item.SubItems[1].Text));
        }

        // Returns the total value of AQUARIUM category items in a ListView
        public static decimal GetAquariumCategoryTotal(ListView salesListView, string connectionString)
        {
            decimal aquariumTotal = 0;
            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                foreach (ListViewItem item in salesListView.Items)
                {
                    if (item.Tag?.ToString() != "PAYMENT")
                    {
                        if (item.Tag?.ToString() == "AQUARIUM_SET_DISCOUNT"
                            || item.Tag?.ToString() == "AQUARIUM_SET_ACCESSORY")
                        {
                            continue;
                        }

                        string itemName = item.Text;
                        int quantity = int.Parse(item.SubItems[1].Text);
                        decimal unitPrice = decimal.Parse(item.SubItems[2].Text.Replace("₱", ""));

                        var categoryCmd = new SqlCommand("SELECT CategoryCode FROM Items WHERE Name = @itemName", connection);
                        categoryCmd.Parameters.AddWithValue("@itemName", itemName);
                        var categoryResult = categoryCmd.ExecuteScalar();

                        if (categoryResult != null && categoryResult.ToString()?.ToUpper() == "AQUARIUM")
                        {
                            aquariumTotal += unitPrice * quantity;
                        }
                    }
                }
            }
            return aquariumTotal;
        }

        /// <summary>
        /// Create positive inventory adjustment lines for AQUARIUM category items found on the specified source document.
        /// The new lines are inserted into ItemLedgerEntry with Quantity = absolute(original.Quantity) and DocumentNo = offsetDocumentNo (or source + "-POS_ADJ").
        /// This method runs inside a DB transaction. If an external SqlConnection is provided it will be used, otherwise a new connection is opened.
        /// </summary>
        /// <param name="sourceDocumentNo">The document number to read existing item ledger rows from.</param>
        /// <param name="offsetDocumentNo">Optional destination document number for the adjustment lines. If null the method uses sourceDocumentNo + "-POS_ADJ".</param>
        /// <param name="externalConnection">Optional open SqlConnection to use. If provided the connection is NOT closed by this method.</param>
        public static void offsetaquariuminventory(string sourceDocumentNo, string? offsetDocumentNo = null, SqlConnection? externalConnection = null)
        {
            if (string.IsNullOrWhiteSpace(sourceDocumentNo))
                throw new ArgumentException("sourceDocumentNo must be provided", nameof(sourceDocumentNo));

            bool ownConnection = externalConnection == null;
            SqlConnection? conn = externalConnection;
            if (ownConnection) conn = new SqlConnection(connectionString);

            try
            {
                if (conn.State != System.Data.ConnectionState.Open)
                    conn.Open();

                using (var tx = conn.BeginTransaction())
                {
                    // Select aquarium category lines for the given document
                    var selectSql = @"SELECT ile.ItemCode, ile.Description, ile.Quantity
FROM ItemLedgerEntry ile
LEFT JOIN Items i ON ile.ItemCode = i.Code
WHERE (ile.DocumentNo = @doc) AND (ISNULL(i.CategoryCode,'') LIKE '%AQUARIUM%')";

                    var rows = new List<(string ItemCode, string Description, decimal Quantity)>();
                    using (var sel = new SqlCommand(selectSql, conn, tx))
                    {
                        sel.Parameters.AddWithValue("@doc", sourceDocumentNo);
                        using (var r = sel.ExecuteReader())
                        {
                            while (r.Read())
                            {
                                try
                                {
                                    var code = r["ItemCode"]?.ToString() ?? string.Empty;
                                    var desc = r["Description"]?.ToString() ?? string.Empty;
                                    decimal qty = 0m;
                                    try { qty = r["Quantity"] != DBNull.Value ? Convert.ToDecimal(r["Quantity"]) : 0m; } catch { qty = 0m; }
                                    if (!string.IsNullOrWhiteSpace(code) && qty != 0m)
                                        rows.Add((code, desc, qty));
                                }
                                catch { /* ignore row parse errors */ }
                            }
                        }
                    }

                    if (rows.Count == 0)
                    {
                        tx.Commit();
                        return;
                    }

                    string destDoc = offsetDocumentNo ?? (sourceDocumentNo + "-POS_ADJ");

                    // Insert positive adjustment lines
                    var insertSql = @"INSERT INTO ItemLedgerEntry (ItemCode, Description, Quantity, DocumentNo, [Date]) VALUES (@ItemCode, @Description, @Quantity, @DocumentNo, @Date)";
                    using (var ins = new SqlCommand(insertSql, conn, tx))
                    {
                        ins.Parameters.Add(new SqlParameter("@ItemCode", System.Data.SqlDbType.NVarChar, 200));
                        ins.Parameters.Add(new SqlParameter("@Description", System.Data.SqlDbType.NVarChar, 1000));
                        ins.Parameters.Add(new SqlParameter("@Quantity", System.Data.SqlDbType.Decimal));
                        ins.Parameters.Add(new SqlParameter("@DocumentNo", System.Data.SqlDbType.NVarChar, 200));
                        ins.Parameters.Add(new SqlParameter("@Date", System.Data.SqlDbType.DateTime));

                        foreach (var row in rows)
                        {
                            ins.Parameters["@ItemCode"].Value = row.ItemCode;
                            ins.Parameters["@Description"].Value = row.Description;
                            // write positive adjustment: absolute of original quantity
                            ins.Parameters["@Quantity"].Value = Math.Abs(row.Quantity);
                            ins.Parameters["@DocumentNo"].Value = destDoc;
                            ins.Parameters["@Date"].Value = DateTime.Now;
                            ins.ExecuteNonQuery();
                        }
                    }

                    tx.Commit();
                }
            }
            catch (Exception ex)
            {
                try
                {
                    MessageBox.Show($"Failed to create positive adjustment lines: {ex.Message}", "Offset Inventory Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                catch { }
                throw;
            }
            finally
            {
                if (ownConnection && conn != null)
                {
                    try { conn.Close(); } catch { }
                }
            }
        }

        // Prints a Job Order for the given receipt number. Owner is optional and used for dialogs.
        public static void PrintJobOrder(string receiptNo, Form? owner = null)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                throw new ArgumentException("receiptNo must be provided", nameof(receiptNo));

            var lines = new List<string>();
            string cashier = string.Empty;
            string customer = string.Empty;
            string orderDesc = string.Empty;
            DateTime date = DateTime.Now;
            // (debugTrace removed) lightweight trace collection removed for production

            // Load posted items (ItemLedgerEntry) and AdvanceOrderLines; also try to fetch customer / order description
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();

                    // Try to read header info first (TransactionHeader and AdvanceOrderHeader) to gather cashier, customer and order description
                    string transactionNo = string.Empty;
                    try
                    {
                        using (var th = new SqlCommand("SELECT TOP 1 UserID, Date, Description FROM TransactionHeader WHERE ReceiptNo = @ReceiptNo", conn))
                        {
                            th.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                            using (var r = th.ExecuteReader())
                            {
                                if (r.Read())
                                {
                                    cashier = r["UserID"]?.ToString() ?? string.Empty;
                                    try { date = Convert.ToDateTime(r["Date"]); } catch { }
                                    orderDesc = r["Description"]?.ToString() ?? string.Empty;
                                    // transaction header read
                                }
                                else { /* no transaction header row found */ }
                            }
                        }
                    }
                    catch { }

                    try
                    {
                        using (var ah = new SqlCommand("SELECT TOP 1 TransactionNo, UserID AS Customer, Description FROM AdvanceOrderHeader WHERE ReceiptNo = @ReceiptNo OR TransactionNo = @ReceiptNo", conn))
                        {
                            ah.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                            using (var r = ah.ExecuteReader())
                            {
                                if (r.Read())
                                {
                                    transactionNo = r["TransactionNo"]?.ToString() ?? string.Empty;
                                    // legacy systems stored customer in UserID
                                    customer = r["Customer"]?.ToString() ?? customer;
                                    // prefer advance order description if available
                                    var aDesc = r["Description"]?.ToString();
                                    if (!string.IsNullOrWhiteSpace(aDesc)) orderDesc = aDesc;
                                    // advance order header read
                                }
                                else { /* no advance order header row found */ }
                            }
                        }
                    }
                    catch { }

                    // categorized items map with preserved insertion order
                    var categorized = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
                    var categoryOrder = new List<string>();
                    // track whether we read any AdvanceOrderLines for this receipt
                    bool aolFound = false;

                    // 1) ItemLedgerEntry rows (posted items)
                    try
                    {
                        using (var cmd = new SqlCommand(@"SELECT ile.ItemCode, ile.Description, ile.Quantity, ISNULL(i.CategoryCode, '') AS CategoryCode FROM ItemLedgerEntry ile LEFT JOIN Items i ON ile.ItemCode = i.Code WHERE (ile.DocumentNo = @ReceiptNo OR ile.DocumentNo = @ReceiptRev OR ile.DocumentNo = @TransactionNo) ORDER BY ISNULL(i.CategoryCode,''), ile.ID", conn))
                        {
                            cmd.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                            cmd.Parameters.AddWithValue("@ReceiptRev", receiptNo + "-REV");
                            cmd.Parameters.AddWithValue("@TransactionNo", transactionNo ?? string.Empty);
                            using (var rdr = cmd.ExecuteReader())
                            {
                                while (rdr.Read())
                                {
                                    int qty = 1;
                                    try { qty = rdr["Quantity"] != DBNull.Value ? Convert.ToInt32(rdr["Quantity"]) : 1; } catch { qty = 1; }
                                    string desc = rdr["Description"]?.ToString() ?? rdr["ItemCode"]?.ToString() ?? string.Empty;
                                    string cat = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"]?.ToString() ?? string.Empty : string.Empty;
                                    if (string.IsNullOrWhiteSpace(cat)) cat = "GENERAL";
                                    if (!categorized.ContainsKey(cat)) { categorized[cat] = new List<string>(); categoryOrder.Add(cat); }
                                    categorized[cat].Add($"{Math.Abs(qty).ToString().PadRight(4)} {desc}");
                                }
                            }
                        }
                    }
                    catch { }

                    // 2) AdvanceOrderLines (include items from advance orders). Exclude PAYMENT type rows.
                    // Use a flexible reader (SELECT *) and map likely column names; if we find an item code we try to get CategoryCode from Items table.
                    try
                    {
                        using (var aol = new SqlCommand(@"SELECT * FROM AdvanceOrderLines WHERE (CAST(ReceiptNo AS NVARCHAR(200)) = @ReceiptNo OR CAST(TransactionNo AS NVARCHAR(200)) = @ReceiptNo OR CAST(ReceiptNo AS NVARCHAR(200)) = @TransactionNo OR CAST(TransactionNo AS NVARCHAR(200)) = @TransactionNo)", conn))
                        {
                            aol.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                            aol.Parameters.AddWithValue("@TransactionNo", transactionNo ?? string.Empty);
                            // helper to try multiple potential column names (defined outside row loop so we don't nest readers)
                            string GetStringField(SqlDataReader r, params string[] names)
                            {
                                foreach (var n in names)
                                {
                                    try
                                    {
                                        int idx = r.GetOrdinal(n);
                                        if (!r.IsDBNull(idx)) return r.GetValue(idx)?.ToString() ?? string.Empty;
                                    }
                                    catch { }
                                }
                                return string.Empty;
                            }

                            int GetIntField(SqlDataReader r, params string[] names)
                            {
                                foreach (var n in names)
                                {
                                    try
                                    {
                                        int idx = r.GetOrdinal(n);
                                        if (!r.IsDBNull(idx)) return Convert.ToInt32(r.GetValue(idx));
                                    }
                                    catch { }
                                }
                                return 1;
                            }

                            // First pass: collect rows into memory without issuing nested DB calls
                            var aolRows = new List<(string ItemCode, string Desc, int Qty, string Type, string CatField)>();
                            using (var rdr = aol.ExecuteReader())
                            {
                                bool aolRowLogged = false;
                                while (rdr.Read())
                                {
                                    aolFound = true;
                                    if (!aolRowLogged)
                                    {
                                        aolRowLogged = true;
                                    }
                                    try
                                    {
                                        string type = GetStringField(rdr, "Type", "AOLType", "LineType");
                                        if (!string.IsNullOrWhiteSpace(type) && type.Equals("PAYMENT", StringComparison.OrdinalIgnoreCase))
                                            continue;

                                        int qty = GetIntField(rdr, "Quantity", "Qty", "QTY");
                                        string desc = GetStringField(rdr, "Description", "Desc", "Order_Description", "OrderDesc");
                                        string itemCode = GetStringField(rdr, "No.", "No", "ItemCode", "ItemNo", "Item", "[No.]");
                                        string catField = GetStringField(rdr, "CategoryCode", "Category", "Cat");
                                        if (string.IsNullOrWhiteSpace(desc) && !string.IsNullOrWhiteSpace(itemCode)) desc = itemCode;

                                        aolRows.Add((itemCode, desc, qty, type, catField));
                                    }
                                    catch
                                    {
                                        // ignore row parse errors for production
                                    }
                                }
                            }

                            // Second pass: resolve categories for any item codes we found using a single query to avoid nested readers
                            try
                            {
                                var codeMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                                var codes = aolRows.Select(r => r.ItemCode).Where(c => !string.IsNullOrWhiteSpace(c)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                                if (codes.Count > 0)
                                {
                                    // build dynamic IN clause with parameters
                                    var inParams = new List<string>();
                                    for (int i = 0; i < codes.Count; i++)
                                    {
                                        var pname = "@code" + i;
                                        inParams.Add(pname);
                                        // add param to command below
                                    }
                                    var sql = $"SELECT Code, ISNULL(CategoryCode,'') AS CategoryCode FROM Items WHERE Code IN (" + string.Join(",", inParams) + ")";
                                    using (var icmd = new SqlCommand(sql, conn))
                                    {
                                        for (int i = 0; i < codes.Count; i++) icmd.Parameters.AddWithValue("@code" + i, codes[i]);
                                        using (var ir = icmd.ExecuteReader())
                                        {
                                            while (ir.Read())
                                            {
                                                try
                                                {
                                                    var code = ir["Code"]?.ToString() ?? string.Empty;
                                                    var ccat = ir["CategoryCode"]?.ToString() ?? string.Empty;
                                                    if (!string.IsNullOrWhiteSpace(code) && !codeMap.ContainsKey(code)) codeMap[code] = ccat;
                                                }
                                                catch { }
                                            }
                                        }
                                    }
                                }

                                // Populate categorized using resolved categories or the fallback catField
                                foreach (var row in aolRows)
                                {
                                    string cat = string.Empty;
                                    if (!string.IsNullOrWhiteSpace(row.ItemCode) && codeMap.TryGetValue(row.ItemCode, out var mappedCat)) cat = mappedCat;
                                    if (string.IsNullOrWhiteSpace(cat)) cat = row.CatField;
                                    if (string.IsNullOrWhiteSpace(cat)) cat = "GENERAL";
                                    if (!categorized.ContainsKey(cat)) { categorized[cat] = new List<string>(); categoryOrder.Add(cat); }
                                    categorized[cat].Add($"{Math.Abs(row.Qty).ToString().PadRight(4)} {row.Desc}");
                                }
                            }
                            catch (Exception)
                            {
                                // ignore mapping failures
                            }
                        }
                    }
                    catch
                    {
                        // ignore AdvanceOrderLines query errors in production
                    }

                    // If this was an Advance Order (we found AdvanceOrderLines), try to read customer / order description
                    // from Prod_Order_Header and prefer those values when present. This helps ensure AdvanceOrders
                    // display the production header customer and description when the advance lines exist.
                    if (aolFound)
                    {
                        try
                        {
                            using (var phAdvance = new SqlCommand("SELECT TOP 1 CustomerName, Order_Description FROM Prod_Order_Header WHERE (CAST(ReceiptNo AS NVARCHAR(200)) = @ReceiptNo OR CAST(TransactionNo AS NVARCHAR(200)) = @ReceiptNo)", conn))
                            {
                                phAdvance.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                                bool phRowFound = false;
                                using (var rph = phAdvance.ExecuteReader())
                                {
                                    if (rph.Read())
                                    {
                                        phRowFound = true;
                                        var prodCustomer = rph["CustomerName"]?.ToString();
                                        var prodOrderDesc = rph["Order_Description"]?.ToString();
                                        if (!string.IsNullOrWhiteSpace(prodCustomer))
                                        {
                                            customer = prodCustomer;
                                        }
                                        else
                                        {
                                            // Prod_Order_Header returned no customer; ignore in production
                                        }
                                        if (!string.IsNullOrWhiteSpace(prodOrderDesc))
                                        {
                                            orderDesc = prodOrderDesc;
                                        }
                                        else
                                        {
                                            // Prod_Order_Header returned no order description; ignore
                                        }
                                    }
                                }
                                if (!phRowFound)
                                {
                                    // no Prod_Order_Header row found for this receipt/transaction
                                }
                            }
                        }
                        catch
                        {
                            // Prod_Order_Header query failed; ignore in production
                        }
                    }

                    // (debugTrace removed) no debug trace appended in production

                    // 3) Prod_Order_Lines (fallback for production job orders)
                    try
                    {
                        using (var pol = new SqlCommand(@"SELECT [Type], [No.], ISNULL(Qty,1) AS Qty, ISNULL(Order_Description,'') AS OrderDesc, ISNULL(Category,'') AS CategoryCode FROM Prod_Order_Lines WHERE (ReceiptNo = @ReceiptNo OR TransactionNo = @ReceiptNo OR ReceiptNo = @TransactionNo OR TransactionNo = @TransactionNo) ORDER BY [LineNo]", conn))
                        {
                            pol.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                            pol.Parameters.AddWithValue("@TransactionNo", transactionNo ?? string.Empty);
                            using (var rdr = pol.ExecuteReader())
                            {
                                while (rdr.Read())
                                {
                                    string type = rdr["Type"]?.ToString() ?? string.Empty;
                                    if (!string.IsNullOrWhiteSpace(type) && type.Equals("PAYMENT", StringComparison.OrdinalIgnoreCase))
                                        continue;

                                    int qty = 1;
                                    try { qty = rdr["Qty"] != DBNull.Value ? Convert.ToInt32(rdr["Qty"]) : 1; } catch { qty = 1; }
                                    string desc = rdr["OrderDesc"]?.ToString() ?? rdr["No."]?.ToString() ?? string.Empty;
                                    string cat = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"]?.ToString() ?? string.Empty : string.Empty;
                                    if (string.IsNullOrWhiteSpace(cat)) cat = "GENERAL";
                                    if (!categorized.ContainsKey(cat)) { categorized[cat] = new List<string>(); categoryOrder.Add(cat); }
                                    categorized[cat].Add($"{Math.Abs(qty).ToString().PadRight(4)} {desc}");
                                }
                            }
                        }
                    }
                    catch { }

                    // (debugTrace removed) no debug trace appended in production

                    // Try fetching customer / order description from Prod_Order_Header if still missing
                    if (string.IsNullOrWhiteSpace(customer) || string.IsNullOrWhiteSpace(orderDesc))
                    {
                        try
                        {
                            using (var ph = new SqlCommand("SELECT TOP 1 CustomerName, Order_Description FROM Prod_Order_Header WHERE (CAST(ReceiptNo AS NVARCHAR(200)) = @ReceiptNo OR CAST(TransactionNo AS NVARCHAR(200)) = @ReceiptNo)", conn))
                            {
                                ph.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                                using (var r = ph.ExecuteReader())
                                {
                                    if (r.Read())
                                    {
                                        if (string.IsNullOrWhiteSpace(customer)) customer = r["CustomerName"]?.ToString() ?? customer;
                                        var prodDesc = r["Order_Description"]?.ToString();
                                        if (!string.IsNullOrWhiteSpace(prodDesc) && string.IsNullOrWhiteSpace(orderDesc)) orderDesc = prodDesc;
                                    }
                                }
                            }
                        }
                        catch { }
                    }

                    // Flatten categorized items into lines with category markers (sorted by category)
                    if (categorized.Count > 0)
                    {
                        foreach (var cat in categoryOrder)
                        {
                            lines.Add("[CAT]" + cat.ToUpperInvariant());
                            foreach (var itemLine in categorized[cat]) lines.Add(itemLine);
                        }
                    }

                    // If still empty, fallback to TransactionHeader description or orderDesc that we read earlier
                    if (lines.Count == 0)
                    {
                        if (!string.IsNullOrWhiteSpace(orderDesc))
                            lines.Add(orderDesc);
                        else
                        {
                            try
                            {
                                using (var th = new SqlCommand(@"SELECT TOP 1 UserID, Date, Description FROM TransactionHeader WHERE ReceiptNo = @ReceiptNo", conn))
                                {
                                    th.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                                    using (var r = th.ExecuteReader())
                                    {
                                        if (r.Read())
                                        {
                                            cashier = r["UserID"]?.ToString() ?? string.Empty;
                                            try { date = Convert.ToDateTime(r["Date"]); } catch { }
                                            var descField = r["Description"]?.ToString() ?? string.Empty;
                                            if (!string.IsNullOrWhiteSpace(descField)) lines.Add(descField);
                                        }
                                    }
                                }
                            }
                            catch { }
                        }
                    }
                }
            }
            catch
            {
                // ignore DB errors for printing
            }

            // Build content
            var content = new StringBuilder();
            content.AppendLine("[CAT]JOB ORDER");
            content.AppendLine($"[CAT]Receipt: {receiptNo}");
            content.AppendLine($"[CAT]Date: {date:yyyy-MM-dd}");
            if (!string.IsNullOrWhiteSpace(cashier)) content.AppendLine($"[CAT]Cashier: {cashier}");
            if (!string.IsNullOrWhiteSpace(customer)) content.AppendLine($"[CAT]Customer: {customer}");
            if (!string.IsNullOrWhiteSpace(orderDesc))
            {
                // Put the label as a bold category header, and the description on the following lines
                // so the print-time wrapping will break long descriptions into multiple lines.
                content.AppendLine("[CAT]Order:");
                // Preserve existing newlines in orderDesc but ensure CR characters removed
                var odLines = orderDesc.Replace("\r", "").Split('\n');
                foreach (var od in odLines) content.AppendLine(od);
            }
            // Number of item lines (exclude category headers marked with "[CAT]")
            int itemCount = 0;
            foreach (var _l in lines)
            {
                if (!_l.StartsWith("[CAT]", StringComparison.OrdinalIgnoreCase)) itemCount++;
            }
            content.AppendLine($"[CAT]Items: {itemCount}");
            content.AppendLine(new string('-', GlobalSettings.ReceiptWidth - 3));
            // Mark as category header so PrintPage will render this line in bold
            content.AppendLine("[CAT]Qty  Description");
            content.AppendLine(new string('-', GlobalSettings.ReceiptWidth - 3));
            foreach (var l in lines)
                content.AppendLine(l);

            // Fallback if nothing found
            if (lines.Count == 0)
            {
                content.AppendLine("(no items found)");
            }

            // Important customer note: glass cover policy (printed at bottom of Job Order)
            content.AppendLine("");
            content.AppendLine("");
            content.AppendLine(new string('-', GlobalSettings.ReceiptWidth - 3));
            content.AppendLine("Aquarium glass cover will be given only on Tanks with Braces - We don't give free Glass Covers for Rimless Tanks Thank you");

            // Prepare print document
            var pd = new PrintDocument();
            pd.DocumentName = $"JobOrder_{receiptNo}";
            pd.DefaultPageSettings.PaperSize = new PaperSize("58mm", (int)(GlobalSettings.PaperWidthInches * 100), (int)(GlobalSettings.PaperHeightInches * 100));
            // Maximize printable width: keep left/top margins but allow right/bottom to be minimal to reduce unused space
            pd.DefaultPageSettings.Margins = new Margins(
                (int)(GlobalSettings.LeftMarginInches * 100), // left
                0, // right - set to 0 to allow printer to use full width where supported
                (int)(GlobalSettings.TopMarginInches * 100), // top
                0  // bottom
            );

            // Split on newline only to avoid accidental empty entries from CRLF splitting
            var receiptLines = content.ToString().Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries).Select(x => x.TrimEnd('\r')).ToList();
            int currentLine = 0;

            pd.PrintPage += (s, e) =>
            {
                if (e.Graphics == null)
                {
                    e.HasMorePages = false;
                    return;
                }

                using (var font = new Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle))
                {
                    float y = e.MarginBounds.Top;
                    float x = e.MarginBounds.Left;
                    float lineHeight = font.GetHeight(e.Graphics);

                    // Measure approximate character width and compute max chars per line based on margin width
                    // approximate character width using a representative sample to get a better average
                    string sample = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -.,";
                    float avgCharWidth = 6f;
                    try
                    {
                        var sampleSize = e.Graphics.MeasureString(sample, font);
                        avgCharWidth = Math.Max(1f, sampleSize.Width / Math.Max(1, sample.Length));
                    }
                    catch { }
                    // compute max chars per line based on available page width (use PageBounds.Right to avoid unused right area)
                    float leftX = e.MarginBounds.Left;
                    float rightEdge = e.PageBounds.Right;
                    // small safety padding (in pixels) to avoid clipping on some printers
                    float safetyPadding = Math.Max(2f, avgCharWidth);
                    float availableWidth = Math.Max(1f, rightEdge - leftX - safetyPadding);
                    int maxChars = Math.Max(1, (int)(availableWidth / avgCharWidth));

                    var printable = new List<(string Text, bool IsHeader)>();
                    foreach (var rl in receiptLines)
                    {
                        if (rl.StartsWith("[CAT]"))
                        {
                            printable.Add((rl.Substring(5), true));
                            continue;
                        }

                        string rem = rl;
                        while (rem.Length > maxChars)
                        {
                            int splitAt = rem.LastIndexOf(' ', maxChars);
                            if (splitAt <= 0) splitAt = maxChars;
                            printable.Add((rem.Substring(0, splitAt), false));
                            rem = rem.Substring(splitAt).TrimStart();
                        }
                        if (rem.Length > 0) printable.Add((rem, false));
                    }

                    while (currentLine < printable.Count)
                    {
                        var (text, isHeader) = printable[currentLine];
                        if (y + lineHeight > e.MarginBounds.Bottom)
                        {
                            e.HasMorePages = true;
                            break;
                        }
                        // Print all lines using bold font per request
                        e.Graphics.DrawString(ToAscii(text), font, Brushes.Black, x, y);
                        y += lineHeight;
                        currentLine++;
                    }

                    if (currentLine >= printable.Count)
                    {
                        e.HasMorePages = false;
                        currentLine = 0; // reset for next print
                    }
                    else
                    {
                        e.HasMorePages = true;
                    }
                }
            };

            // Try to use main app's configured printer name if available
            try
            {
                string? appPrinter = null;
                try
                {
                    foreach (Form f in Application.OpenForms)
                    {
                        if (f is MainForm mf)
                        {
                            var fd = typeof(MainForm).GetField("printDocument", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                            if (fd != null)
                            {
                                var pf = fd.GetValue(mf) as PrintDocument;
                                if (pf != null && !string.IsNullOrWhiteSpace(pf.PrinterSettings.PrinterName)) { appPrinter = pf.PrinterSettings.PrinterName; break; }
                            }
                        }
                    }
                }
                catch { }
                if (!string.IsNullOrWhiteSpace(appPrinter)) pd.PrinterSettings.PrinterName = appPrinter!;
            }
            catch { }

            try
            {
                if (!string.IsNullOrWhiteSpace(pd.PrinterSettings.PrinterName) && !pd.PrinterSettings.IsValid)
                {
                    MessageBox.Show(owner ?? Application.OpenForms[0], $"Configured printer '{pd.PrinterSettings.PrinterName}' is not available.", "Printer Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                pd.Print();
            }
            catch (Exception ex)
            {
                try
                {
                    MessageBox.Show(owner ?? Application.OpenForms[0], $"Printing job order failed: {ex.Message}\nOpening preview as fallback.", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    using (var preview = new PrintPreviewDialog()) { preview.Document = pd; preview.ShowDialog(owner); }
                }
                catch { }
            }
        }
        // Print cash float receipt
        public static void PrintCashFloatReceipt(string receiptNo, string userId, decimal grandTotal, List<TextBox> coinTextBoxes, List<TextBox> noteTextBoxes)
        {
            try
            {
                var receipt = new System.Text.StringBuilder();
                string line = new string('=', GlobalSettings.ReceiptWidth);
                decimal[] coinDenominations = { 0.25m, 0.5m, 1, 2, 5, 10 };
                decimal[] noteDenominations = { 20, 50, 100, 200, 500, 1000 };

                // Header - formatted for 58mm
                receipt.AppendLine(line);
                receipt.AppendLine("      RS PET STOP");
                receipt.AppendLine("  AQUARIUM PRODUCTS");
                receipt.AppendLine("   & SOLUTIONS");
                receipt.AppendLine(line);
                receipt.AppendLine($"Receipt No: {receiptNo}");
                receipt.AppendLine($"Date: {DateTime.Now:yyyy-MM-dd}");
                receipt.AppendLine($"Time: {DateTime.Now:HH:mm:ss}");
                receipt.AppendLine($"Cashier: {userId}");
                receipt.AppendLine(line);
                receipt.AppendLine("  CASH FLOAT DECLARATION");
                receipt.AppendLine(line);
                receipt.AppendLine();

                // Coins section
                receipt.AppendLine("COINS:");
                receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                decimal coinsTotal = 0;
                for (int i = 0; i < coinTextBoxes.Count; i++)
                {
                    int qty = 0;
                    int.TryParse(coinTextBoxes[i].Text, out qty);
                    if (qty > 0)
                    {
                        decimal lineTotal = coinDenominations[i] * qty;
                        coinsTotal += lineTotal;
                        receipt.AppendLine($"P{coinDenominations[i]:F2} x {qty,3} = P{lineTotal,6:F2}");
                    }
                }
                receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                receipt.AppendLine($"Coins Total:   P{coinsTotal,8:F2}");
                receipt.AppendLine();

                // Notes section
                receipt.AppendLine("NOTES:");
                receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                decimal notesTotal = 0;
                for (int i = 0; i < noteTextBoxes.Count; i++)
                {
                    int qty = 0;
                    int.TryParse(noteTextBoxes[i].Text, out qty);
                    if (qty > 0)
                    {
                        decimal lineTotal = noteDenominations[i] * qty;
                        notesTotal += lineTotal;
                        receipt.AppendLine($"P{noteDenominations[i]:F0} x {qty,3} = P{lineTotal,7:F2}");
                    }
                }
                receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                receipt.AppendLine($"Notes Total:   P{notesTotal,8:F2}");
                receipt.AppendLine();

                // Grand total
                receipt.AppendLine(line);
                receipt.AppendLine($"GRAND TOTAL:   P{grandTotal,8:F2}");
                receipt.AppendLine(line);
                receipt.AppendLine();
                receipt.AppendLine("  Thank you for using");
                receipt.AppendLine("    Aquarium POS!");
                receipt.AppendLine($"Printed: {DateTime.Now:yyyy-MM-dd HH:mm}");
                receipt.AppendLine(line);

                // Create and configure print document for 58mm thermal printer
                var printDocument = new System.Drawing.Printing.PrintDocument();
                    var bodyFont = new System.Drawing.Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);
                // Make header and footer larger than body for emphasis on cash float receipts
                var headerFont = new System.Drawing.Font(GlobalSettings.ReceiptFont, Math.Max(8f, GlobalSettings.ReceiptFontSize + 2), GlobalSettings.ReceiptFontStyle);
                var footerFont = new System.Drawing.Font(GlobalSettings.ReceiptFont, Math.Max(7f, GlobalSettings.ReceiptFontSize + 1), GlobalSettings.ReceiptFontStyle);

                // Configure for 58mm thermal printer
                printDocument.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("58mm",
                    (int)(GlobalSettings.PaperWidthInches * 100),
                    (int)(GlobalSettings.PaperHeightInches * 100));
                printDocument.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins(
                    (int)(GlobalSettings.LeftMarginInches * 100),
                    (int)(GlobalSettings.LeftMarginInches * 100),
                    (int)(GlobalSettings.TopMarginInches * 100),
                    (int)(GlobalSettings.TopMarginInches * 100));

                var receiptContent = receipt.ToString();

                printDocument.PrintPage += (sender, e) =>
                {
                    if (e.Graphics != null)
                    {
                        float yPos = e.MarginBounds.Top;
                        float leftMargin = e.MarginBounds.Left;

                        var lines = receiptContent.Split('\n').Select(l => l.TrimEnd('\r')).ToArray();

                        // Find header end (first blank line after header) and footer start (line containing GRAND TOTAL or last separator)
                        int headerEndIndex = 0;
                        for (int i = 0; i < lines.Length; i++)
                        {
                            if (string.IsNullOrWhiteSpace(lines[i]) && i > 0)
                            {
                                headerEndIndex = i;
                                break;
                            }
                        }
                        int footerStartIndex = Array.FindIndex(lines, l => l != null && l.IndexOf("GRAND TOTAL", StringComparison.OrdinalIgnoreCase) >= 0);
                        if (footerStartIndex < 0)
                        {
                            footerStartIndex = Array.FindLastIndex(lines, l => l != null && (l.TrimStart().StartsWith("=") || l.TrimStart().StartsWith("-")));
                            if (footerStartIndex < 0) footerStartIndex = lines.Length - 1;
                        }

                        for (int idx = 0; idx < lines.Length; idx++)
                        {
                            var lineText = lines[idx];
                            Font useFont = bodyFont;
                            if (idx < headerEndIndex) useFont = headerFont;
                            else if (idx >= footerStartIndex) useFont = footerFont;

                            float lineHeight = useFont.GetHeight(e.Graphics);
                            if (yPos + lineHeight > e.MarginBounds.Bottom)
                            {
                                e.HasMorePages = true;
                                return;
                            }

                            string processedLine = lineText;
                            if (processedLine.Length > GlobalSettings.ReceiptWidth)
                                processedLine = processedLine.Substring(0, GlobalSettings.ReceiptWidth);

                            e.Graphics.DrawString(ToAscii(processedLine), useFont, System.Drawing.Brushes.Black, leftMargin, yPos);
                            yPos += lineHeight;
                        }

                        e.HasMorePages = false;
                    }
                };

                // Print directly without preview
                printDocument.Print();
                headerFont.Dispose();
                bodyFont.Dispose();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error printing receipt: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // Print expense receipt
        // expenseItems: ListView items where
        //   item.Text = Description
        //   SubItems[1] = Qty
        //   SubItems[2] = Unit Price
        //   SubItems[3] = Line Total (optional)
        //   SubItems[5] = Code (optional)
        public static void PrintExpenseReceipt(string receiptNo, string userId, List<ListViewItem> expenseItems, decimal grandTotal, string remarks = "")
        {
            try
            {
                var receipt = new System.Text.StringBuilder();
                string line = new string('=', GlobalSettings.ReceiptWidth);

                // Header
                receipt.AppendLine(line);
                receipt.AppendLine("      RS PET STOP");
                receipt.AppendLine("  AQUARIUM PRODUCTS");
                receipt.AppendLine("   & SOLUTIONS");
                receipt.AppendLine(line);
                receipt.AppendLine($"Receipt No: {receiptNo}");
                receipt.AppendLine($"Date: {DateTime.Now:yyyy-MM-dd}");
                receipt.AppendLine($"Time: {DateTime.Now:HH:mm:ss}");
                receipt.AppendLine($"Cashier: {userId}");
                receipt.AppendLine(line);
                receipt.AppendLine("  EXPENSE DETAILS");
                receipt.AppendLine(line);
                receipt.AppendLine();

                // Column headers (expense requirement: show only Item Code, Qty, Amount)
                receipt.AppendLine("Code                 Qty        Amount");
                receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                // Items
                foreach (var item in expenseItems)
                {
                    string desc = item.Text ?? "";
                    int qty = 0;
                    decimal price = 0m;
                    decimal lineTotal = 0m;

                    // Prefer Item Code (SubItems[5]) when available.
                    string code = "";
                    if (item.SubItems.Count > 5)
                        code = item.SubItems[5].Text ?? "";

                    // Fallback: first token of description (often formatted like "CODE Name...")
                    if (string.IsNullOrWhiteSpace(code) && !string.IsNullOrWhiteSpace(desc))
                    {
                        var firstToken = desc.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
                        if (!string.IsNullOrWhiteSpace(firstToken))
                            code = firstToken;
                    }

                    // If this is an incidental placeholder line, do not print the line at all.
                    if (string.Equals(code?.Trim(), "INC_EXP", StringComparison.OrdinalIgnoreCase))
                        continue;

                    if (string.IsNullOrWhiteSpace(code))
                        code = "";

                    if (item.SubItems.Count > 1)
                        int.TryParse(item.SubItems[1].Text, out qty);
                    if (item.SubItems.Count > 2)
                        Decimal.TryParse(item.SubItems[2].Text.Replace("₱", "").Replace("?", ""), out price);
                    if (item.SubItems.Count > 3)
                        Decimal.TryParse(item.SubItems[3].Text.Replace("₱", "").Replace("?", ""), out lineTotal);

                    if (lineTotal == 0m)
                        lineTotal = qty * price;

                    // Build: CODE | QTY | AMOUNT (line total)
                    int totalWidth = GlobalSettings.ReceiptWidth;
                    string amountPart = $"P{lineTotal,8:F2}";
                    string qtyPart = $"{qty,3}";
                    string numericPart = $"{qtyPart}  {amountPart}";
                    int codeWidth = Math.Max(0, totalWidth - numericPart.Length - 1);
                    string shortCode = codeWidth > 0 ? (code.Length > codeWidth ? code.Substring(0, codeWidth) : code.PadRight(codeWidth)) : string.Empty;
                    receipt.AppendLine($"{shortCode} {numericPart}");
                }

                receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                receipt.AppendLine($"GRAND TOTAL:   P{grandTotal,8:F2}");
                // Append tender type (payment) totals for this receipt, if any
                try
                {
                    var paymentSummaries = new List<(string TenderCode, decimal Total)>();
                    using (var conn = new SqlConnection(connectionString))
                    {
                        conn.Open();
                        var payCmd = new SqlCommand(@"SELECT TenderTypeCode, SUM(Amount) AS Total FROM TransPaymentEntry WHERE ReceiptNo = @receiptNo GROUP BY TenderTypeCode", conn);
                        payCmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                        using (var rdr = payCmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                string tcode = rdr["TenderTypeCode"]?.ToString() ?? "";
                                decimal tot = rdr["Total"] != DBNull.Value ? Convert.ToDecimal(rdr["Total"]) : 0m;
                                paymentSummaries.Add((tcode, tot));
                            }
                        }
                    }

                    if (paymentSummaries.Count > 0)
                    {
                        receipt.AppendLine();
                        receipt.AppendLine("PAYMENTS:");
                        receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                        int totalWidth = GlobalSettings.ReceiptWidth;
                        foreach (var p in paymentSummaries)
                        {
                            // Format: TenderCode (max 9 chars) ... Pxxxx.xx (right aligned amount)
                            string left = p.TenderCode ?? "";
                            if (left.Length > 9) left = left.Substring(0, 9);
                            string paddedLeft = left.PadRight(Math.Max(0, totalWidth - 21));
                            receipt.AppendLine($"{paddedLeft} P{p.Total,8:F2}");
                        }
                    }
                }
                catch
                {
                    // ignore payment summary failures to avoid print interruption
                }

                // Determine order description to print. Use provided remarks if present,
                // otherwise try to pull the order description from TransactionHeader by receipt no.
                string orderDescription = remarks;
                try
                {
                    if (string.IsNullOrWhiteSpace(orderDescription))
                    {
                        using (var conn = new SqlConnection(connectionString))
                        {
                            conn.Open();
                            // Try common column names in order of preference.
                            var tryCols = new[] { "OrderDescription", "Description", "Remarks" };
                            foreach (var col in tryCols)
                            {
                                var descCmd = new SqlCommand($"SELECT TOP 1 [{col}] FROM TransactionHeader WHERE ReceiptNo = @receiptNo", conn);
                                descCmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                                var obj = descCmd.ExecuteScalar();
                                if (obj != null && obj != DBNull.Value)
                                {
                                    orderDescription = obj?.ToString() ?? string.Empty;
                                    break;
                                }
                            }
                        }
                    }
                }
                catch
                {
                    // ignore DB errors and fall back to remarks or empty
                }

                if (!string.IsNullOrWhiteSpace(orderDescription))
                {
                    // Normalize line breaks and excessive whitespace to avoid missing characters when printed
                    orderDescription = orderDescription.Replace("\r\n", " ").Replace("\n", " ").Replace("\r", " ");
                    // Collapse multiple spaces into single spaces
                    var parts = orderDescription.Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                    orderDescription = string.Join(" ", parts).Trim();

                    receipt.AppendLine();
                    receipt.AppendLine("Order Description:");
                    // wrap description to receipt width
                    var remLines = SplitByWidth(orderDescription, GlobalSettings.ReceiptWidth);
                    foreach (var rl in remLines)
                        receipt.AppendLine(rl);
                }
                receipt.AppendLine(line);

                var printDocument = new System.Drawing.Printing.PrintDocument();
                var printFont = new System.Drawing.Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);

                printDocument.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("58mm", (int)(GlobalSettings.PaperWidthInches * 100), (int)(GlobalSettings.PaperHeightInches * 100));
                printDocument.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins((int)(GlobalSettings.LeftMarginInches * 100), (int)(GlobalSettings.LeftMarginInches * 100), (int)(GlobalSettings.TopMarginInches * 100), (int)(GlobalSettings.TopMarginInches * 100));

                var receiptContent = receipt.ToString();

                printDocument.PrintPage += (sender, e) =>
                {
                    if (e.Graphics != null)
                    {
                        float yPos = e.MarginBounds.Top;
                        float leftMargin = e.MarginBounds.Left;
                        float lineHeight = printFont.GetHeight(e.Graphics);

                        var lines = receiptContent.Split('\n');
                        foreach (var l in lines)
                        {
                            var lineText = l.TrimEnd('\r');
                            if (yPos + lineHeight > e.MarginBounds.Bottom)
                            {
                                e.HasMorePages = true;
                                return;
                            }

                            string processedLine = lineText;
                            if (processedLine.Length > GlobalSettings.ReceiptWidth)
                                processedLine = processedLine.Substring(0, GlobalSettings.ReceiptWidth);

                            e.Graphics.DrawString(ToAscii(processedLine), printFont, System.Drawing.Brushes.Black, leftMargin, yPos);
                            yPos += lineHeight;
                        }

                        e.HasMorePages = false;
                    }
                };

                printDocument.Print();
                printFont.Dispose();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error printing expense receipt: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // Print income receipt (mirrors expense receipt layout)
        public static void PrintIncomeReceipt(string receiptNo, string userId, List<ListViewItem> incomeItems, decimal grandTotal, string remarks = "")
        {
            try
            {
                var receipt = new System.Text.StringBuilder();
                string line = new string('=', GlobalSettings.ReceiptWidth);

                // Header
                receipt.AppendLine(line);
                receipt.AppendLine("      RS PET STOP");
                receipt.AppendLine("  AQUARIUM PRODUCTS");
                receipt.AppendLine("   & SOLUTIONS");
                receipt.AppendLine(line);
                receipt.AppendLine($"Receipt No: {receiptNo}");
                receipt.AppendLine($"Date: {DateTime.Now:yyyy-MM-dd}");
                receipt.AppendLine($"Time: {DateTime.Now:HH:mm:ss}");
                receipt.AppendLine($"Cashier: {userId}");
                receipt.AppendLine(line);
                receipt.AppendLine("  INCOME DETAILS");
                receipt.AppendLine(line);
                receipt.AppendLine();

                // Column headers
                receipt.AppendLine("Item      QTY   Total");
                receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                // Items
                foreach (var item in incomeItems)
                {
                    // Show only: description (max 6 chars), qty and line total
                    string desc = item.Text ?? "";
                    int qty = 0;
                    decimal price = 0m;
                    decimal lineTotal = 0m;

                    if (item.SubItems.Count > 1)
                        int.TryParse(item.SubItems[1].Text, out qty);
                    if (item.SubItems.Count > 2)
                        Decimal.TryParse(item.SubItems[2].Text.Replace("₱", "").Replace("?", ""), out price);
                    if (item.SubItems.Count > 3)
                        Decimal.TryParse(item.SubItems[3].Text.Replace("₱", "").Replace("?", ""), out lineTotal);

                    if (lineTotal == 0m)
                        lineTotal = qty * price;

                    // Limit description to 6 characters to fit receipt layout
                    string shortDesc = desc.Length > 6 ? desc.Substring(0, 6) : desc.PadRight(6);
                    receipt.AppendLine($"{shortDesc} {qty,3}    P{lineTotal,8:F2}");
                }

                // Append tender type (payment) totals for this receipt, if any (mirror expense receipt)
                try
                {
                    var paymentSummaries = new List<(string TenderCode, decimal Total)>();
                    using (var conn = new SqlConnection(connectionString))
                    {
                        conn.Open();
                        var payCmd = new SqlCommand(@"SELECT TenderTypeCode, SUM(Amount) AS Total FROM TransPaymentEntry WHERE ReceiptNo = @receiptNo GROUP BY TenderTypeCode", conn);
                        payCmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                        using (var rdr = payCmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                string tcode = rdr["TenderTypeCode"]?.ToString() ?? "";
                                decimal tot = rdr["Total"] != DBNull.Value ? Convert.ToDecimal(rdr["Total"]) : 0m;
                                paymentSummaries.Add((tcode, tot));
                            }
                        }
                    }

                    if (paymentSummaries.Count > 0)
                    {
                        receipt.AppendLine();
                        receipt.AppendLine("PAYMENTS:");
                        receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                        int totalWidth = GlobalSettings.ReceiptWidth;
                        foreach (var p in paymentSummaries)
                        {
                            string left = p.TenderCode ?? "";
                            if (left.Length > 9) left = left.Substring(0, 9);
                            string paddedLeft = left.PadRight(Math.Max(0, totalWidth - 21));
                            receipt.AppendLine($"{paddedLeft} P{p.Total,8:F2}");
                        }
                    }
                }
                catch
                {
                    // ignore payment summary failures to avoid print interruption
                }


                receipt.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                receipt.AppendLine($"GRAND TOTAL:   P{grandTotal,8:F2}");
                // Determine order description to print. Use provided remarks if present,
                // otherwise try to pull the order description from TransactionHeader by receipt no.
                string orderDescription = remarks;
                try
                {
                    if (string.IsNullOrWhiteSpace(orderDescription))
                    {
                        using (var conn = new SqlConnection(connectionString))
                        {
                            conn.Open();
                            // Try common column names in order of preference.
                            var tryCols = new[] { "OrderDescription", "Description", "Remarks" };
                            foreach (var col in tryCols)
                            {
                                var descCmd = new SqlCommand($"SELECT TOP 1 [{col}] FROM TransactionHeader WHERE ReceiptNo = @receiptNo", conn);
                                descCmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                                var obj = descCmd.ExecuteScalar();
                                if (obj != null && obj != DBNull.Value)
                                {
                                    orderDescription = obj?.ToString() ?? string.Empty;
                                    break;
                                }
                            }
                        }
                    }
                }
                catch
                {
                    // ignore DB errors and fall back to remarks or empty
                }

                if (!string.IsNullOrWhiteSpace(orderDescription))
                {
                    receipt.AppendLine();
                    receipt.AppendLine("Order Description:");
                    // wrap description to receipt width
                    var remLines = SplitByWidth(orderDescription, GlobalSettings.ReceiptWidth);
                    foreach (var rl in remLines)
                        receipt.AppendLine(rl);
                }
                receipt.AppendLine(line);

                var printDocument = new System.Drawing.Printing.PrintDocument();
                var printFont = new System.Drawing.Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);

                printDocument.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("58mm", (int)(GlobalSettings.PaperWidthInches * 100), (int)(GlobalSettings.PaperHeightInches * 100));
                printDocument.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins((int)(GlobalSettings.LeftMarginInches * 100), (int)(GlobalSettings.LeftMarginInches * 100), (int)(GlobalSettings.TopMarginInches * 100), (int)(GlobalSettings.TopMarginInches * 100));

                var receiptContent = receipt.ToString();

                printDocument.PrintPage += (sender, e) =>
                {
                    if (e.Graphics != null)
                    {
                        float yPos = e.MarginBounds.Top;
                        float leftMargin = e.MarginBounds.Left;
                        float lineHeight = printFont.GetHeight(e.Graphics);

                        var lines = receiptContent.Split('\n');
                        foreach (var l in lines)
                        {
                            var lineText = l.TrimEnd('\r');
                            if (yPos + lineHeight > e.MarginBounds.Bottom)
                            {
                                e.HasMorePages = true;
                                return;
                            }

                            string processedLine = lineText;
                            if (processedLine.Length > GlobalSettings.ReceiptWidth)
                                processedLine = processedLine.Substring(0, GlobalSettings.ReceiptWidth);

                            e.Graphics.DrawString(ToAscii(processedLine), printFont, System.Drawing.Brushes.Black, leftMargin, yPos);
                            yPos += lineHeight;
                        }

                        e.HasMorePages = false;
                    }
                };

                printDocument.Print();
                printFont.Dispose();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error printing income receipt: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // Helper to split long text into lines of specified width
        private static IEnumerable<string> SplitByWidth(string text, int width)
        {
            if (string.IsNullOrEmpty(text)) yield break;
            int pos = 0;
            while (pos < text.Length)
            {
                int len = Math.Min(width, text.Length - pos);
                yield return text.Substring(pos, len);
                pos += len;
            }
        }

        /// <summary>
        /// Safety validation for custom aquarium glass selection.
        /// Inputs: length, width, height and gallons. The method will always convert the provided dimensions
        /// into inches based on the unit parameter and validate the provided glass thickness (example "3mm").
        /// Returns a tuple: (Allowed, Recommended, Message, TeamCheck).
        /// </summary>
        /// <param name="length">Length of aquarium in given unit</param>
        /// <param name="width">Width of aquarium in given unit</param>
        /// <param name="height">Height of aquarium in given unit</param>
        /// <param name="gallons">Tank volume in gallons (can be approximate)</param>
        /// <param name="glass">Glass thickness string, e.g. "3mm" or "6"</param>
        /// <param name="unit">Unit of length inputs: "in", "cm", "mm", "ft" (case-insensitive). Defaults to "in".</param>
        /// <param name="rimless">True if tank is rimless</param>
        /// <param name="withBrace">True if tank has braces
        /// </param>
        public static (bool Allowed, string Recommended, string Message, bool TeamCheck) safetyrules(decimal length, decimal width, decimal height, decimal gallons, string glass, string unit = "in", bool rimless = false, bool withBrace = false)
        {
            // helpers: convert to inches
            decimal ToInches(decimal value, string u)
            {
                if (string.IsNullOrWhiteSpace(u)) u = "in";
                u = u.Trim().ToLowerInvariant();
                return u switch
                {
                    "in" or "inch" or "inches" => value,
                    "cm" or "centimeter" or "centimeters" => value / 2.54m,
                    "mm" or "millimeter" or "millimeters" => value / 25.4m,
                    "m" or "meter" or "meters" => value * 39.3700787m,
                    "ft" or "feet" or "foot" => value * 12m,
                    _ => value
                };
            }

            var L = ToInches(length, unit);
            var W = ToInches(width, unit);
            var H = ToInches(height, unit);

            // normalize glass input to integer mm if possible
            int glassMm = 0;
            try
            {
                if (!string.IsNullOrWhiteSpace(glass))
                {
                    var s = glass.Trim().ToLowerInvariant().Replace("mm", "").Replace(" ", "");
                    int.TryParse(s, out glassMm);
                }
            }
            catch { glassMm = 0; }

            bool teamCheck = false;
            var messages = new List<string>();
            string recommended = string.Empty;

            // Team-check thresholds
            if (gallons >= 670m || H > 36m || W > 36m)
            {
                teamCheck = true;
                recommended = ">=19mm tempered (team check required)";
                messages.Add("Tank large or tall — requires 19mm+ tempered glass and team pricing review.");
                return (false, recommended, string.Join(" ", messages), teamCheck);
            }

            if (gallons >= 370m && H <= 36m && W <= 36m)
            {
                teamCheck = true;
                recommended = ">=12mm tempered (team check required)";
                messages.Add("Large volume (>=370G) — minimum 12mm tempered and consult team for pricing.");
                // continue to evaluate stricter rejections below
            }

            // Rimless/Brace small-gallon rules (2.5G–100G special rules)
            if (gallons >= 2.5m && gallons <= 100m)
            {
                if (gallons >= 2.5m && gallons <= 5m)
                {
                    // Rimless: 3mm allowed
                    recommended = recommended == string.Empty ? "3mm" : recommended;
                    messages.Add("2.5–5G: 3mm allowed (rimless acceptable).");
                }
                else if (gallons >= 10m && gallons <= 15m)
                {
                    if (withBrace)
                    {
                        recommended = recommended == string.Empty ? "3mm" : recommended;
                        messages.Add("10–15G with brace: 3mm allowed.");
                    }
                    else if (rimless)
                    {
                        recommended = recommended == string.Empty ? "6mm" : recommended;
                        messages.Add("10–15G rimless: must use 6mm.");
                    }
                }
                else if (gallons >= 20m && gallons <= 25m)
                {
                    recommended = recommended == string.Empty ? "6mm" : recommended;
                    messages.Add("20–25G: 6mm glass recommended.");
                }
                else if (gallons >= 30m && gallons <= 100m)
                {
                    if (withBrace)
                    {
                        recommended = recommended == string.Empty ? "6mm" : recommended;
                        messages.Add("30–100G with brace: 6mm glass allowed.");
                    }
                    else if (rimless)
                    {
                        recommended = recommended == string.Empty ? "10mm" : recommended;
                        messages.Add("30–100G rimless: minimum 10mm.");
                    }
                }
            }

            // Rule 1: 3mm only for tanks 15 gallons or below and dims <= limits
            bool rule1_ok = (gallons <= 15m && L <= 24m && W <= 12m && H <= 12m);
            // Rule 2: 6mm allowed if dims within limits
            bool rule2_ok = (L <= 60m && W <= 20m && H <= 20m);
            // Rule 3: 10mm required if L <=72 OR H >24 OR W >24 (user text); interpret practically: prefer 10mm for larger dims
            bool rule3_needed = (L <= 72m || H > 24m || W > 24m);
            // Rule 4: 12mm required if gallons >=180
            bool rule4_needed = (gallons >= 180m);
            // Rule 5: 19mm required if H >36 or W >36
            bool rule5_needed = (H > 36m || W > 36m);

            // Evaluate recommended thickness if not set by small-gallon rules or team-check
            if (string.IsNullOrWhiteSpace(recommended))
            {
                if (rule5_needed)
                {
                    recommended = "19mm (team check)";
                    teamCheck = true;
                }
                else if (rule4_needed)
                {
                    recommended = "12mm";
                }
                else if (rule3_needed)
                {
                    recommended = "10mm";
                }
                else if (rule2_ok)
                {
                    recommended = "6mm";
                }
                else if (rule1_ok)
                {
                    recommended = "3mm";
                }
                else
                {
                    // Fallback conservative recommendation
                    recommended = "10mm";
                }
            }

            // Apply rejection rules explicitly
            bool allowed = true;

            if (glassMm == 3)
            {
                if (gallons > 15m || L > 24m || W > 12m || H > 12m)
                {
                    allowed = false;
                    messages.Add("3mm glass is not allowed for tanks above 15G or exceeding 24" + " x 12" + " x 12\".");
                }
            }

            if (glassMm == 6)
            {
                if (L > 60m || W > 20m || H > 20m)
                {
                    allowed = false;
                    messages.Add("6mm glass is not allowed when any dimension exceeds L>60" + " or W>20" + " or H>20\".");
                }
            }

            if ((L > 60m || W > 20m || H > 20m) && (glassMm == 3 || glassMm == 6))
            {
                allowed = false;
                messages.Add("Dimensions exceed 60\"/20\"/20\" - 3mm/6mm cannot be used.");
            }

            if (glassMm == 10)
            {
                if (gallons > 100m || L > 72m || W >= 30m || H >= 30m)
                {
                    allowed = false;
                    messages.Add("10mm is not suitable for tanks >100G or dimensions larger than 72" + " (L) or >=30" + " (W/H).");
                }
            }

            if (glassMm == 12)
            {
                if (gallons > 170m || L > 72m || W >= 30m || H >= 30m)
                {
                    allowed = false;
                    messages.Add("12mm may not be suitable for very large tanks (see team rules for >170G or large dimensions).");
                }
            }

            // Additional general rules
            if (gallons >= 670m || H > 36m || W > 36m)
            {
                allowed = false;
                teamCheck = true;
                messages.Add("Very large tank — requires team review and 19mm+ tempered glass.");
            }

            // Final recommendation vs provided glass: if provided glass is less than recommended, reject
            int recMm = 0;
            if (recommended != null)
            {
                try
                {
                    var r = recommended;
                    // extract leading number
                    var nums = new string(r.TakeWhile(c => char.IsDigit(c)).ToArray());
                    int.TryParse(nums, out recMm);
                }
                catch { recMm = 0; }
            }

            if (recMm > 0 && glassMm > 0 && glassMm < recMm)
            {
                allowed = false;
                messages.Add($"Selected glass {glassMm}mm is below recommended minimum of {recMm}mm.");
            }

            // If any team check was set earlier, mark teamCheck
            if (teamCheck) messages.Add("Team check required.");

            var message = messages.Count == 0 ? ("Recommended: " + recommended) : string.Join(" ", messages) + " Recommended: " + recommended;
            return (allowed, recommended, message, teamCheck);
        }

        // Add more global functions here as needed
        /// <summary>
        /// Validate aquarium dimensions against glass thickness and safety rules.
        /// Returns (isSafe, message). If isSafe==false, message contains the user-facing explanation.
        /// </summary>
        public static (bool IsSafe, string Message, string? AutoChangeTo) safetyrules(double lengthInInches, double widthInInches, double heightInInches, string glassThicknessMm, bool isTempered)
        {
            try
            {
                // Normalize thickness string (e.g., "6mm" -> "6mm")
                string t = (glassThicknessMm ?? string.Empty).Trim().ToLowerInvariant();
                // Compute approx gallons for contextual rules
                double gallons = (lengthInInches * widthInInches * heightInInches) / 231.0;

                // Auto-upgrade rule: if user selected 3mm but length alone exceeds 24", suggest/auto-change to 6mm
                if (t == "3mm" && lengthInInches > 24.0)
                {
                    // Return a special auto-change hint. Caller should update UI and recalculate.
                    return (false, "Length exceeds 24\" for 3mm glass. Auto-upgrading glass to 6mm.", "6mm");
                }

                // Enforce: if width or height reaches 36 inches, tempered glass is mandatory.
                try
                {
                    if (widthInInches >= 36.0 || heightInInches >= 36.0)
                    {
                        if (!isTempered)
                        {
                            return (false, "Width or height is 36 inches or more. Tempered glass is mandatory for this custom aquarium.", null);
                        }
                    }
                }
                catch { }

                // Rule 1: 3mm glass is only for very small tanks. If >15 gallons and any major dimension is over small limits, require thicker glass
                if (t == "3mm")
                {
                    if (gallons > 15.0 && (lengthInInches > 24.0 || widthInInches > 12.0 || heightInInches > 12.0))
                    {
                        return (false, "Tank exceeds safe limits for 3mm glass. Please select 10mm or 12mm glass.", null);
                    }
                }

                // General rule: if any dimension is very large then 3mm/6mm are unsafe. For 6mm require >50 gal threshold
                if ((lengthInInches > 60.0 || widthInInches > 20.0 || heightInInches > 20.0))
                {
                    if (t == "3mm" || (t == "6mm" && gallons > 50.0))
                    {
                        return (false, "Tank dimensions exceed safe limits for selected glass. Please choose 10mm or 12mm glass.", null);
                    }
                }

                // 10mm rule: for very large tanks require 12mm
                if (t == "10mm")
                {
                    if (gallons > 180.0 || lengthInInches > 72.0 || widthInInches > 30.0 || heightInInches > 30.0)
                    {
                        return (false, "Tank volume/dimensions require 12mm glass. Please select 12mm glass to calculate.", null);
                    }
                }

                // If tempered glass is selected, some marginal cases may be allowed, but we keep rules conservative
                // (no additional allow-listing; tempered reduces risk but design decisions still prefer thicker glass)

                return (true, string.Empty, null);
            }
            catch (Exception ex)
            {
                // On unexpected error, return not safe with diagnostic message
                return (false, "Safety validation failed: " + ex.Message, null);
            }
        }
        /// <summary>
        /// Overload that considers rimless tanks. If rimless==true, applies stricter rimless guidelines
        /// (10-15G rimless -> min 6mm, 30-100G rimless -> min 10mm, etc.).
        /// </summary>
        public static (bool IsSafe, string Message, string? AutoChangeTo) safetyrules(double lengthInInches, double widthInInches, double heightInInches, string glassThicknessMm, bool isTempered, bool rimless)
        {
            // First apply the base checks
            var baseResult = safetyrules(lengthInInches, widthInInches, heightInInches, glassThicknessMm, isTempered);
            if (!rimless || !baseResult.IsSafe)
            {
                // If not rimless, or base already failed, just return base result
                return baseResult;
            }

            try
            {
                double gallons = (lengthInInches * widthInInches * heightInInches) / 231.0;
                // Normalize thickness like "6mm" -> 6
                int glassMm = 0;
                if (!string.IsNullOrWhiteSpace(glassThicknessMm))
                {
                    var s = glassThicknessMm.Trim().ToLowerInvariant().Replace("mm", "").Replace(" ", "");
                    int.TryParse(s, out glassMm);
                }

                // Rimless-specific requirements
                if (gallons >= 10.0 && gallons <= 15.0)
                {
            if (glassMm < 6)
                return (false, "Rimless 10–15G tanks require minimum 6mm glass.", null);
                }

                if (gallons >= 30.0 && gallons <= 100.0)
                {
                    if (glassMm < 10)
                        return (false, "Rimless 30–100G tanks require minimum 10mm glass.", null);
                }

                // 2.5–5G rimless: 3mm allowed (no restriction)
                // 20–25G rimless: 6mm allowed (no extra restriction beyond base)

                // For tanks >100G, base rules will handle conservatively; recommend team check if needed
                return baseResult;
            }
            catch (Exception ex)
            {
                return (false, "Rimless safety validation failed: " + ex.Message, null);
            }
        }
        /// <summary>
        /// Insert an ItemLedgerEntry to offset inventory for an item (useful for corrections).
        /// Method name intentionally matches request: offsetaquariuminventory
        /// Returns true on success, false on failure.
        /// </summary>
        /// <param name="itemCode">Item code to offset</param>
        /// <param name="quantity">Quantity to offset (positive number). Will be negated for decrease unless increase=true.</param>
        /// <param name="increase">If true, inventory will be increased; otherwise decreased.</param>
        /// <param name="documentNo">Document number for the ItemLedgerEntry record (defaults to "OFFSET").</param>
        /// <param name="userId">User performing the offset (defaults to "SYSTEM").</param>
        /// <param name="owner">Optional owner form for user-facing messages.</param>
        public static bool offsetaquariuminventory(string itemCode, int quantity, bool increase = false, string documentNo = "OFFSET", string userId = "SYSTEM", Form? owner = null)
        {
            if (string.IsNullOrWhiteSpace(itemCode))
            {
                if (owner != null) MessageBox.Show(owner, "Item code is required.", "Offset Inventory", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            if (quantity == 0)
            {
                if (owner != null) MessageBox.Show(owner, "Quantity must be non-zero.", "Offset Inventory", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            int qtyToWrite = increase ? Math.Abs(quantity) : -Math.Abs(quantity);

            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    // Try to resolve a friendly description from Items table if available
                    string desc = itemCode;
                    try
                    {
                        using (var cmd = new SqlCommand("SELECT TOP 1 ISNULL(Name, ISNULL(Description, '')) FROM Items WHERE Code = @code", conn))
                        {
                            cmd.Parameters.AddWithValue("@code", itemCode);
                            var obj = cmd.ExecuteScalar();
                            if (obj != null && obj != DBNull.Value)
                            {
                                var s = obj.ToString();
                                if (!string.IsNullOrWhiteSpace(s)) desc = s!;
                            }
                        }
                    }
                    catch
                    {
                        // ignore; fallback to itemCode
                    }

                    using (var tran = conn.BeginTransaction())
                    {
                        try
                        {
                            // Insert offset entry and tag SentToOnline = 1 so these corrections are never pushed online.
                            // Use the full ItemLedgerEntry schema: DocumentType is required, EntryDate is the timestamp.
                            var insert = new SqlCommand(@"INSERT INTO ItemLedgerEntry
    (EntryDate, ItemCode, DocumentType, DocumentNo, Quantity, UnitCost, TotalCost, Description, UserID, SentToOnline)
    VALUES (@date, @item, @docType, @doc, @qty, @unitCost, @totalCost, @desc, @user, @sent)", conn, tran);

                            insert.Parameters.AddWithValue("@date", DateTime.Now);
                            insert.Parameters.AddWithValue("@item", itemCode);
                            insert.Parameters.AddWithValue("@docType", "ADJUSTMENT");
                            insert.Parameters.AddWithValue("@doc", string.IsNullOrWhiteSpace(documentNo) ? (object)DBNull.Value : documentNo);
                            insert.Parameters.AddWithValue("@qty", qtyToWrite);
                            insert.Parameters.AddWithValue("@unitCost", 0m);
                            insert.Parameters.AddWithValue("@totalCost", 0m);
                            insert.Parameters.AddWithValue("@desc", desc);
                            insert.Parameters.AddWithValue("@user", string.IsNullOrWhiteSpace(userId) ? (object)DBNull.Value : userId);
                            insert.Parameters.AddWithValue("@sent", true);
                            insert.ExecuteNonQuery();

                            tran.Commit();
                            return true;
                        }
                        catch (Exception ex)
                        {
                            try { tran.Rollback(); } catch { }
                            if (owner != null)
                                MessageBox.Show(owner, $"Failed to insert inventory offset: {ex.Message}", "Offset Inventory Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                            return false;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                if (owner != null)
                    MessageBox.Show(owner, $"Database error while offsetting inventory: {ex.Message}", "Offset Inventory Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        /// <summary>
        /// Dry-run: return a list of aquarium items where the net ItemLedgerEntry quantity is negative.
        /// Each tuple contains: ItemCode, ItemName, NetQuantity (negative), NeededPositiveAdjustment (positive integer)
        /// </summary>
        public static List<(string ItemCode, string ItemName, int NetQuantity, int Needed)> GetAquariumNegativeBalances()
        {
            var results = new List<(string, string, int, int)>();
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    // Aggregate ledger quantities per item for items in AQUARIUM category
                    var sql = @"
                        SELECT i.Code AS ItemCode,
                               ISNULL(i.Name, ISNULL(i.Description, i.Code)) AS ItemName,
                               ISNULL(SUM(ISNULL(ile.Quantity,0)),0) AS NetQty
                        FROM Items i
                        LEFT JOIN ItemLedgerEntry ile ON ile.ItemCode = i.Code
                        WHERE ISNULL(i.CategoryCode,'') LIKE '%AQUARIUM%'
                        GROUP BY i.Code, ISNULL(i.Name, ISNULL(i.Description, i.Code))
                        HAVING ISNULL(SUM(ISNULL(ile.Quantity,0)),0) < 0
                    ";
                    using (var cmd = new SqlCommand(sql, conn))
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read())
                        {
                            try
                            {
                                string code = rdr["ItemCode"]?.ToString() ?? string.Empty;
                                string name = rdr["ItemName"]?.ToString() ?? code;
                                int net = rdr["NetQty"] != DBNull.Value ? Convert.ToInt32(rdr["NetQty"]) : 0;
                                int needed = Math.Abs(net);
                                if (!string.IsNullOrWhiteSpace(code) && needed > 0)
                                    results.Add((code, name, net, needed));
                            }
                            catch { }
                        }
                    }
                }
            }
            catch
            {
                // ignore errors for dry-run; caller may show message
            }
            return results;
        }

        /// <summary>
        /// Apply positive adjustments for aquarium items that have negative net balances.
        /// Inserts one ItemLedgerEntry per item with Quantity = Needed (positive), Description prefixed with "positive_adj".
        /// Returns the number of inserted rows.
        /// </summary>
        public static int ApplyPositiveAdjustmentsForAquarium(Form? owner = null, string documentNo = "POSITIVE_ADJ", string userId = "SYSTEM")
        {
            var list = GetAquariumNegativeBalances();
            if (list.Count == 0)
            {
                if (owner != null) MessageBox.Show(owner, "No aquarium items with negative balance were found.", "Positive Adjustments", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }

            int inserted = 0;
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var tran = conn.BeginTransaction())
                    {
                        try
                        {
                            foreach (var (code, name, net, needed) in list)
                            {
                                if (needed <= 0) continue;
                                // Build friendly description
                                string desc = $"positive_adj - {name}";

                                var insert = new SqlCommand("INSERT INTO ItemLedgerEntry (ItemCode, Description, Quantity, DocumentNo, Date, UserID) VALUES (@item, @desc, @qty, @doc, @date, @user)", conn, tran);
                                insert.Parameters.AddWithValue("@item", code);
                                insert.Parameters.AddWithValue("@desc", desc);
                                insert.Parameters.AddWithValue("@qty", needed);
                                insert.Parameters.AddWithValue("@doc", documentNo ?? (object)DBNull.Value);
                                insert.Parameters.AddWithValue("@date", DateTime.Now);
                                insert.Parameters.AddWithValue("@user", userId ?? (object)DBNull.Value);
                                insert.ExecuteNonQuery();
                                inserted++;
                            }

                            tran.Commit();
                        }
                        catch (Exception ex)
                        {
                            try { tran.Rollback(); } catch { }
                            if (owner != null) MessageBox.Show(owner, $"Failed applying positive adjustments: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                            return inserted;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                if (owner != null) MessageBox.Show(owner, $"Database error while applying adjustments: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }

            if (owner != null)
                MessageBox.Show(owner, $"Applied positive adjustments for {inserted} item(s).", "Positive Adjustments", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return inserted;
        }

        /// <summary>
        /// Build a plan of positive adjustments required for items whose CategoryCode contains 'AQUARIUM'.
        /// Returns a list of tuples: (ItemCode, ItemName, NeededQuantity)
        /// </summary>
        public static List<(string ItemCode, string ItemName, int Needed)> GetAquariumPositiveAdjustmentPlan()
        {
            var result = new List<(string, string, int)>();
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    // Get all items in aquarium category
                    using (var cmd = new SqlCommand("SELECT Code, ISNULL(Name,'') AS Name FROM Items WHERE ISNULL(CategoryCode,'') LIKE '%AQUARIUM%'", conn))
                    {
                        using (var rdr = cmd.ExecuteReader())
                        {
                            var items = new List<(string Code, string Name)>();
                            while (rdr.Read())
                            {
                                var code = rdr["Code"]?.ToString() ?? string.Empty;
                                var name = rdr["Name"]?.ToString() ?? string.Empty;
                                
                                if (!string.IsNullOrWhiteSpace(code)) items.Add((code, name));
                            }

                            foreach (var it in items)
                            {
                                try
                                {
                                    using (var sumCmd = new SqlCommand("SELECT ISNULL(SUM(Quantity),0) FROM ItemLedgerEntry WHERE ItemCode = @code", conn))
                                    {
                                        sumCmd.Parameters.AddWithValue("@code", it.Code);
                                        var obj = sumCmd.ExecuteScalar();
                                        long net = 0;
                                        if (obj != null && obj != DBNull.Value) net = Convert.ToInt64(obj);
                                        if (net < 0)
                                        {
                                            int needed = (int)(-net);
                                            MessageBox.Show($"Item {it.Name} ({it.Code}) needs positive adjustment of {needed}. net = {net}");
                                            result.Add((it.Code, it.Name, needed));
                                        }
                                    }
                                }
                                catch { }
                            }
                        }
                    }
                }
            }
            catch { }
            return result;
        }

        /// <summary>
        /// Apply positive adjustments for the provided plan. Inserts ItemLedgerEntry rows with Description 'positive_adj - {ItemName}'.
        /// Returns number of inserted rows.
        /// </summary>
        public static int ApplyAquariumPositiveAdjustments(List<(string ItemCode, string ItemName, int Needed)> plan, string documentNo = "POSITIVE_ADJ", string userId = "SYSTEM", Form? owner = null)
        {
            if (plan == null || plan.Count == 0) return 0;
            int inserted = 0;
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var tran = conn.BeginTransaction())
                    {
                        try
                        {
                            foreach (var p in plan)
                            {
                                var desc = $"positive_adj - {p.ItemName}";
                                var cmd = new SqlCommand("INSERT INTO ItemLedgerEntry (ItemCode, Description, Quantity, DocumentNo, Date, UserID) VALUES (@code, @desc, @qty, @doc, @date, @user)", conn, tran);
                                cmd.Parameters.AddWithValue("@code", p.ItemCode);
                                cmd.Parameters.AddWithValue("@desc", desc ?? (object)DBNull.Value);
                                cmd.Parameters.AddWithValue("@qty", p.Needed);
                                cmd.Parameters.AddWithValue("@doc", documentNo ?? (object)DBNull.Value);
                                cmd.Parameters.AddWithValue("@date", DateTime.Now);
                                cmd.Parameters.AddWithValue("@user", userId ?? (object)DBNull.Value);
                                cmd.ExecuteNonQuery();
                                inserted++;
                            }
                            tran.Commit();
                        }
                        catch (Exception ex)
                        {
                            try { tran.Rollback(); } catch { }
                            if (owner != null) MessageBox.Show(owner, $"Failed to apply adjustments: {ex.Message}", "Positive Adj Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                            return inserted;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                if (owner != null) MessageBox.Show(owner, $"Database error while applying adjustments: {ex.Message}", "Positive Adj Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            return inserted;
        }
        /// <summary>
        /// Revert the MainForm checkout button back to normal SALES mode.
        /// Looks for MainForm via owner or Application.OpenForms and updates checkout UI safely.
        /// </summary>
        public static void RevertCheckoutToSales(Form? owner = null)
        {
            try
            {
                MainForm? mainFormInstance = null;
                if (owner is MainForm ownerMain)
                    mainFormInstance = ownerMain;
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
                // Try to set using public properties if available, otherwise fallback to reflection
                try
                {
                    var checkoutField = typeof(MainForm).GetField("checkoutButton", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
                    if (checkoutField != null)
                    {
                        var btn = checkoutField.GetValue(mainFormInstance) as Button;
                        if (btn != null)
                        {
                            btn.Text = "CHECKOUT";
                            btn.Tag = "SALES";
                            try { btn.BackColor = Color.Green; } catch { }
                        }
                    }
                    // also hide tender panel and reset flags if fields exist
                    try
                    {
                        var tenderPanelField = typeof(MainForm).GetField("tenderTypesPanel", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
                        tenderPanelField?.SetValue(mainFormInstance, false);
                    }
                    catch { }
                }
                catch
                {
                    // ignore any reflection/UI errors
                }
                // }
            }
            catch
            {
                // ignore top-level errors
            }
        }
    }
}
