using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Diagnostics;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace AquariumPOS
{
    public static class PostingEvents
    {
        private sealed class ExpenseReportLine
        {
            public string Category { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string UserId { get; init; } = string.Empty;
            public string DateText { get; init; } = string.Empty;
            public string TimeText { get; init; } = string.Empty;
            public decimal Quantity { get; init; }
            public decimal Amount { get; init; }
        }

        private static string FormatExpenseReportTime(object? rawTime)
        {
            if (rawTime == null || rawTime == DBNull.Value)
            {
                return string.Empty;
            }

            if (rawTime is DateTime dateTimeValue)
            {
                return dateTimeValue.ToString("hh:mm tt").ToLowerInvariant();
            }

            if (rawTime is TimeSpan timeSpanValue)
            {
                return DateTime.Today.Add(timeSpanValue).ToString("hh:mm tt").ToLowerInvariant();
            }

            string text = rawTime.ToString()?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(text))
            {
                return string.Empty;
            }

            if (DateTime.TryParse(text, out DateTime parsedDateTime))
            {
                return parsedDateTime.ToString("hh:mm tt").ToLowerInvariant();
            }

            if (TimeSpan.TryParse(text, out TimeSpan parsedTimeSpan))
            {
                return DateTime.Today.Add(parsedTimeSpan).ToString("hh:mm tt").ToLowerInvariant();
            }

            return text;
        }

        // Helper: return CHARACTER_MAXIMUM_LENGTH for a given table/column, or -1 for NVARCHAR(MAX)/no-limit or when unknown
        private static int GetColumnMaxLength(SqlConnection conn, string tableName, string columnName)
        {
            try
            {
                using var cmd = new SqlCommand(@"SELECT CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @table AND COLUMN_NAME = @column", conn);
                cmd.Parameters.AddWithValue("@table", tableName);
                cmd.Parameters.AddWithValue("@column", columnName);
                var obj = cmd.ExecuteScalar();
                if (obj == null || obj == DBNull.Value) return -1;
                return Convert.ToInt32(obj);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"GetColumnMaxLength failed: {ex.Message}");
                return -1;
            }
        }

        // Diagnose which parameters exceed column lengths for a given table. Returns a human readable report (empty if none found).
        private static string DiagnoseParamLengths(SqlConnection conn, string tableName, SqlParameterCollection parameters)
        {
            try
            {
                // Load columns for the table
                var cols = new List<string>();
                using (var ccmd = new SqlCommand(@"SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @table", conn))
                {
                    ccmd.Parameters.AddWithValue("@table", tableName);
                    using var r = ccmd.ExecuteReader();
                    while (r.Read()) cols.Add(r.GetString(0));
                }

                if (cols.Count == 0) return "(no schema information found)";

                string Normalize(string s) => new string(s.Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();

                var report = new StringBuilder();
                foreach (SqlParameter p in parameters)
                {
                    if (p.Value == null || p.Value == DBNull.Value) continue;
                    if (p.Value is string sVal)
                    {
                        var normParam = Normalize(p.ParameterName.TrimStart('@'));
                        // try to match a column by normalized name
                        var match = cols.FirstOrDefault(c => Normalize(c) == normParam);
                        if (match == null)
                        {
                            // fuzzy match: param contained in column or vice-versa
                            match = cols.FirstOrDefault(c => Normalize(c).Contains(normParam) || normParam.Contains(Normalize(c)));
                        }

                        if (match != null)
                        {
                            int maxLen = GetColumnMaxLength(conn, tableName, match);
                            if (maxLen > 0 && sVal.Length > maxLen)
                            {
                                report.AppendLine($"Column {match} max={maxLen} but parameter {p.ParameterName} length={sVal.Length}");
                            }
                        }
                    }
                }

                return report.ToString();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"DiagnoseParamLengths failed: {ex.Message}");
                return "(diagnosis failed)";
            }
        }
        public static void PostProductionOrders(
            string connectionString,
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
            decimal aquariumTotal,
            ListView salesListView)
        {
            // Determine due date based on aquarium total
            DateTime dueDate;
            if (aquariumTotal > 60000)
                dueDate = DateTime.Now.Date.AddDays(9);
            else if (aquariumTotal > 25000)
                dueDate = DateTime.Now.Date.AddDays(15);
            else if (aquariumTotal > 8000)
                dueDate = DateTime.Now.Date.AddDays(9);
            else
                dueDate = DateTime.Now.Date.AddDays(4);

            static string GetSaleLineCategory(ListViewItem item)
            {
                return item.SubItems.Count > 4 ? item.SubItems[4].Text?.Trim() ?? string.Empty : string.Empty;
            }

            static string GetSaleLineCode(ListViewItem item)
            {
                return item.SubItems.Count > 5 ? item.SubItems[5].Text?.Trim() ?? string.Empty : string.Empty;
            }

            // Get category from first non-payment item
            string category = salesListView.Items.Cast<ListViewItem>()
                .Where(item => item.Tag?.ToString() != "PAYMENT"
                    && item.Tag?.ToString() != "AQUARIUM_SET_DISCOUNT"
                    && item.Tag?.ToString() != "AQUARIUM_SET_ACCESSORY")
                .Select(item =>
                {
                    var itemCategory = GetSaleLineCategory(item);
                    if (!string.IsNullOrWhiteSpace(itemCategory))
                    {
                        return itemCategory;
                    }

                    var itemCode = GetSaleLineCode(item);
                    using (var connection = new SqlConnection(connectionString))
                    {
                        connection.Open();

                        if (!string.IsNullOrWhiteSpace(itemCode))
                        {
                            var codeCmd = new SqlCommand("SELECT CategoryCode FROM Items WHERE Code = @itemCode", connection);
                            codeCmd.Parameters.AddWithValue("@itemCode", itemCode);
                            var codeResult = codeCmd.ExecuteScalar();
                            if (codeResult != null)
                            {
                                return codeResult.ToString() ?? "General";
                            }
                        }

                        var nameCmd = new SqlCommand("SELECT CategoryCode FROM Items WHERE Name = @itemName", connection);
                        nameCmd.Parameters.AddWithValue("@itemName", item.Text);
                        var nameResult = nameCmd.ExecuteScalar();
                        return nameResult?.ToString() ?? "General";
                    }
                })
                .FirstOrDefault() ?? "General";

            // Post header
            // If category is not one of the allowed types, do not write header/lines
            var categoryUpper = (category ?? "").Trim().ToUpperInvariant();
            // Allow AQUARIUM, STAND, SUMP and GENERAL to be posted
            if (!(categoryUpper == "AQUARIUM" || categoryUpper == "STAND" || categoryUpper == "SUMP" || categoryUpper == "GENERAL"))
            {
                // Nothing to post for other categories
                return;
            }

            PostProductionOrderHeader(
                connectionString,
                storeNo,
                posTerminalNo,
                transactionNo,
                receiptNo,
                prodOrderNo,
                type,
                noOfItems,
                date,
                time,
                customerName,
                orderDescription,
                eodid,
                status,
                dueDate,
                category ?? "");

            // Post lines
            int lineNo = 1;
            foreach (ListViewItem item in salesListView.Items)
            {
                if (item.Tag?.ToString() != "PAYMENT"
                    && item.Tag?.ToString() != "AQUARIUM_SET_DISCOUNT"
                    && item.Tag?.ToString() != "AQUARIUM_SET_ACCESSORY")
                {
                    string itemName = item.Text;
                    int quantity = int.Parse(item.SubItems[1].Text);
                    string itemCategory = GetSaleLineCategory(item);
                    if (string.IsNullOrWhiteSpace(itemCategory))
                    {
                        itemCategory = "General";
                    }

                    string itemCodeOrCustom = GetSaleLineCode(item);
                    if (string.IsNullOrWhiteSpace(itemCodeOrCustom))
                    {
                        itemCodeOrCustom = itemName;
                    }

                    // Use the Description field from salesListView (try named column first, fallback to index)
                    string itemDescription = "";
                    int descIndex = 0; // Hardcoded index for Description field
                    if (item.SubItems.Count > descIndex)
                        itemDescription = item.SubItems[descIndex].Text;
                    else
                        itemDescription = orderDescription;

                    using (var connection = new SqlConnection(connectionString))
                    {
                        connection.Open();
                        var cmd = new SqlCommand("SELECT COUNT(*) FROM Items WHERE Code = @code", connection);
                        cmd.Parameters.AddWithValue("@code", itemCodeOrCustom);
                        int exists = Convert.ToInt32(cmd.ExecuteScalar());
                        if (exists == 0 && itemCategory.ToUpper() == "AQUARIUM")
                        {
                            itemCodeOrCustom = "Custom Aquarium";
                        }
                         if (exists == 0 && itemCategory.ToUpper() == "STAND")
                        {
                            itemCodeOrCustom = "Custom Stand";
                        }
                    }
                    PostProductionOrderLine(
                        connectionString,
                        storeNo,
                        posTerminalNo,
                        transactionNo,
                        receiptNo,
                        prodOrderNo,
                        lineNo,
                        "ITEM",
                        itemCodeOrCustom,
                        quantity,
                        date,
                        time,
                        dueDate,
                        itemCategory,
                        customerName,
                        itemDescription);
                    lineNo++;
                }
            }
        }

        public static void PostProductionOrderHeader(
                string connectionString,
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
            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                var cmd = new SqlCommand(@"
                    INSERT INTO Prod_Order_Header (
                        StoreNo, POSTerminalNo, TransactionNo, ReceiptNo, ProdOrderNo, Type, [No. of Items], Date, Time, CustomerName, Order_Description, EODID, Status, DueDate, Category
                    ) VALUES (
                        @storeNo, @posTerminalNo, @transactionNo, @receiptNo, @prodOrderNo, @type, @noOfItems, @date, @time, @customerName, @orderDescription, @eodid, @status, @dueDate, @category
                    )", connection);
                cmd.Parameters.AddWithValue("@storeNo", storeNo);
                cmd.Parameters.AddWithValue("@posTerminalNo", posTerminalNo);
                cmd.Parameters.AddWithValue("@transactionNo", transactionNo);
                cmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                cmd.Parameters.AddWithValue("@prodOrderNo", prodOrderNo);
                cmd.Parameters.AddWithValue("@type", type);
                cmd.Parameters.AddWithValue("@noOfItems", noOfItems);
                cmd.Parameters.AddWithValue("@date", date);
                cmd.Parameters.AddWithValue("@time", time);
                cmd.Parameters.AddWithValue("@customerName", customerName);
                cmd.Parameters.AddWithValue("@orderDescription", orderDescription);
                cmd.Parameters.AddWithValue("@eodid", eodid);
                cmd.Parameters.AddWithValue("@status", status);
                cmd.Parameters.AddWithValue("@dueDate", dueDate);
                cmd.Parameters.AddWithValue("@category", category);
                try
                {
                    cmd.ExecuteNonQuery();
                }
                catch (SqlException ex)
                {
                    string diag = DiagnoseParamLengths(connection, "Prod_Order_Header", cmd.Parameters);
                    string msg = $"SQL Error inserting into Prod_Order_Header: {ex.Message}\n\nDiagnosis:\n{diag}";
                    Debug.WriteLine(msg);
                    MessageBox.Show(msg, "DB Insert Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    throw;
                }
            }
        }

        public static void PostProductionOrderLine(
            string connectionString,
            string storeNo,
            string posTerminalNo,
            string transactionNo,
            string receiptNo,
            string prodOrderNo,
            int lineNo,
            string type,
            string no,
            int qty,
            DateTime date,
            TimeSpan time,
            DateTime dueDate,
            string category,
            string customerName,
            string orderDescription)
        {
            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                var cmd = new SqlCommand(@"
                    INSERT INTO Prod_Order_Lines (
                        StoreNo, POSTerminalNo, TransactionNo, ReceiptNo, ProdOrderNo, [LineNo], [Type], [No.], [Qty], [Date], [Time], [DueDate], [Category], [CustomerName], [Order_Description]
                    ) VALUES (
                        @storeNo, @posTerminalNo, @transactionNo, @receiptNo, @prodOrderNo, @lineNo, @type, @no, @qty, @date, @time, @dueDate, @category, @customerName, @orderDescription
                    )", connection);
                cmd.Parameters.AddWithValue("@storeNo", storeNo);
                cmd.Parameters.AddWithValue("@posTerminalNo", posTerminalNo);
                cmd.Parameters.AddWithValue("@transactionNo", transactionNo);
                cmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                cmd.Parameters.AddWithValue("@prodOrderNo", prodOrderNo);
                cmd.Parameters.AddWithValue("@lineNo", lineNo);
                cmd.Parameters.AddWithValue("@type", type);
                cmd.Parameters.AddWithValue("@no", no);
                cmd.Parameters.AddWithValue("@qty", qty);
                cmd.Parameters.AddWithValue("@date", date);
                cmd.Parameters.AddWithValue("@time", time);
                cmd.Parameters.AddWithValue("@dueDate", dueDate);
                cmd.Parameters.AddWithValue("@category", category);
                cmd.Parameters.AddWithValue("@customerName", customerName);
                cmd.Parameters.AddWithValue("@orderDescription", orderDescription);
                try
                {
                    cmd.ExecuteNonQuery();
                }
                catch (SqlException ex)
                {
                    string diag = DiagnoseParamLengths(connection, "Prod_Order_Lines", cmd.Parameters);
                    string msg = $"SQL Error inserting into Prod_Order_Lines: {ex.Message}\n\nDiagnosis:\n{diag}";
                    Debug.WriteLine(msg);
                    MessageBox.Show(msg, "DB Insert Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    throw;
                }
            }
        }

        public static void PrintXReport(string receiptNo)
        {
            try
            {
                string connectionString = GlobalSettings.ConnectionString;

                // Create and configure print document for 58mm thermal printer
                var printDocument = new System.Drawing.Printing.PrintDocument();
                var printFont = new System.Drawing.Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);

                // Configure for 58mm thermal printer
                printDocument.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("58mm",
                    (int)(GlobalSettings.PaperWidthInches * 100),
                    (int)(GlobalSettings.PaperHeightInches * 100));
                printDocument.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins(
                    (int)(GlobalSettings.LeftMarginInches * 100),
                    (int)(GlobalSettings.LeftMarginInches * 100),
                    (int)(GlobalSettings.TopMarginInches * 100),
                    (int)(GlobalSettings.TopMarginInches * 100));

                string reportContent = "";

                // Generate X Report content
                reportContent = GenerateXReportContent(connectionString, receiptNo);

                // Split content into lines for pagination
                string[] lines = reportContent.Split('\n');
                int currentLineIndex = 0;

                // Print event handler
                printDocument.PrintPage += (sender, e) =>
                {
                    if (e.Graphics != null)
                    {
                        float yPosition = 10;
                        float lineHeight = printFont.GetHeight();

                        while (currentLineIndex < lines.Length)
                        {
                            // Check if we need a new page before printing the line
                            if (yPosition + lineHeight > e.MarginBounds.Height - 50)
                            {
                                e.HasMorePages = true;
                                return;
                            }

                            e.Graphics.DrawString(FunctionEvents.ToAscii(lines[currentLineIndex]), printFont, System.Drawing.Brushes.Black, 10, yPosition);
                            yPosition += lineHeight;
                            currentLineIndex++;
                        }

                        e.HasMorePages = false;
                    }
                };

                // Print the document
                printDocument.Print();
                printFont.Dispose();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error printing X Report: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        public static void PrintExpenseReport(string reportNo, DateTime startDate, DateTime endDate)
        {
            try
            {
                var lines = GenerateExpenseReportLines(GlobalSettings.ConnectionString, startDate, endDate);
                PrintExpenseReportA4(reportNo, startDate, endDate, lines);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error printing Expense Report: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        public static void PrintProfitAndLossReport(string reportNo, DateTime startDate, DateTime endDate)
        {
            try
            {
                string content = GenerateProfitAndLossReportContent(GlobalSettings.ConnectionString, reportNo, startDate, endDate);
                PrintReceiptContent(content, "Profit and Loss Report");
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error printing Profit and Loss Report: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static void PrintReceiptContent(string content, string reportTitle)
        {
            var printDocument = new System.Drawing.Printing.PrintDocument();
            var printFont = new System.Drawing.Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);

            printDocument.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("58mm",
                (int)(GlobalSettings.PaperWidthInches * 100),
                (int)(GlobalSettings.PaperHeightInches * 100));
            printDocument.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins(
                (int)(GlobalSettings.LeftMarginInches * 100),
                (int)(GlobalSettings.LeftMarginInches * 100),
                (int)(GlobalSettings.TopMarginInches * 100),
                (int)(GlobalSettings.TopMarginInches * 100));

            string receiptPrinterName = MainForm.ResolveReceiptPrinterName();
            if (!string.IsNullOrWhiteSpace(receiptPrinterName))
            {
                printDocument.PrinterSettings.PrinterName = receiptPrinterName;
            }

            string[] lines = content.Split('\n');
            int currentLineIndex = 0;

            printDocument.PrintPage += (sender, e) =>
            {
                if (e.Graphics == null)
                {
                    e.HasMorePages = false;
                    return;
                }

                float yPosition = 10;
                float lineHeight = printFont.GetHeight();

                while (currentLineIndex < lines.Length)
                {
                    if (yPosition + lineHeight > e.MarginBounds.Height - 50)
                    {
                        e.HasMorePages = true;
                        return;
                    }

                    e.Graphics.DrawString(FunctionEvents.ToAscii(lines[currentLineIndex]), printFont, System.Drawing.Brushes.Black, 10, yPosition);
                    yPosition += lineHeight;
                    currentLineIndex++;
                }

                e.HasMorePages = false;
            };

            try
            {
                printDocument.Print();
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException($"{reportTitle} could not be printed: {ex.Message}", ex);
            }
            finally
            {
                printFont.Dispose();
                printDocument.Dispose();
            }
        }

        private static bool TableHasColumn(SqlConnection connection, string tableName, string columnName)
        {
            using var command = new SqlCommand(@"SELECT COUNT(*)
                                                FROM INFORMATION_SCHEMA.COLUMNS
                                                WHERE TABLE_NAME = @tableName AND COLUMN_NAME = @columnName", connection);
            command.Parameters.AddWithValue("@tableName", tableName);
            command.Parameters.AddWithValue("@columnName", columnName);
            return Convert.ToInt32(command.ExecuteScalar()) > 0;
        }

        private static List<ExpenseReportLine> GenerateExpenseReportLines(string connectionString, DateTime startDate, DateTime endDate)
        {
            var lines = new List<ExpenseReportLine>();

            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                bool hasExpenseCategory = TableHasColumn(connection, "TransactionHeader", "ExpenseCategory");
                DateTime endExclusive = endDate.Date.AddDays(1);

                string categorySql = hasExpenseCategory ? "ISNULL(ExpenseCategory, 'Uncategorized')" : "'Uncategorized'";

                string query = $@"SELECT {categorySql} AS ExpenseCategory,
                                          ISNULL(Description, '') AS Description,
                                          ISNULL(UserID, '') AS UserID,
                                          ISNULL(Quantity, 0) AS Quantity,
                                          [Date],
                                          [Time],
                                          ISNULL(GrossAmount, 0) AS TotalAmount
                                   FROM TransactionHeader
                                   WHERE Type = 'EXPENSE'
                                     AND (EODID IS NULL OR EODID = '')
                                     AND [Date] >= @startDate
                                     AND [Date] < @endExclusive
                                   ORDER BY ExpenseCategory, [Date], [Time], TransactionNo";

                using (var command = new SqlCommand(query, connection))
                {
                    command.Parameters.AddWithValue("@startDate", startDate.Date);
                    command.Parameters.AddWithValue("@endExclusive", endExclusive);
                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            string category = reader["ExpenseCategory"]?.ToString() ?? "Uncategorized";
                            string description = reader["Description"]?.ToString() ?? string.Empty;
                            string userId = reader["UserID"]?.ToString() ?? string.Empty;
                            decimal quantity = reader["Quantity"] != DBNull.Value ? Convert.ToDecimal(reader["Quantity"]) : 0m;
                            string dateText = reader["Date"] != DBNull.Value
                                ? Convert.ToDateTime(reader["Date"]).ToString("MM/dd/yyyy")
                                : string.Empty;
                            string timeText = FormatExpenseReportTime(reader["Time"]);
                            decimal totalAmount = reader["TotalAmount"] != DBNull.Value ? Convert.ToDecimal(reader["TotalAmount"]) : 0m;
                            lines.Add(new ExpenseReportLine
                            {
                                Category = category,
                                Description = description,
                                UserId = userId,
                                Quantity = quantity,
                                DateText = dateText,
                                TimeText = timeText,
                                Amount = totalAmount
                            });
                        }
                    }
                }
            }

            return lines;
        }

        private static void PrintExpenseReportA4(string reportNo, DateTime startDate, DateTime endDate, List<ExpenseReportLine> lines)
        {
            using var printDocument = new System.Drawing.Printing.PrintDocument();
            ApplyA4PageSettings(printDocument);

            using var titleFont = new System.Drawing.Font("Arial", 16, System.Drawing.FontStyle.Bold);
            using var headerFont = new System.Drawing.Font("Arial", 11, System.Drawing.FontStyle.Regular);
            using var columnFont = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Bold);
            using var bodyFont = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Regular);
            using var categoryFont = new System.Drawing.Font("Arial", 11, System.Drawing.FontStyle.Bold);

            int rowIndex = 0;
            decimal grandTotal = lines.Sum(line => line.Amount);
            string currentWarehouseName = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString)?.Name ?? "Not Set";

            printDocument.PrintPage += (sender, e) =>
            {
                if (e.Graphics == null)
                {
                    e.HasMorePages = false;
                    return;
                }

                var graphics = e.Graphics;
                var bounds = e.MarginBounds;
                float y = bounds.Top;
                float singleLineRowHeight = bodyFont.GetHeight(graphics) + 8f;
                float maxDescriptionRowHeight = (bodyFont.GetHeight(graphics) * 2f) + 8f;
                float descriptionWidth = 320f;
                float qtyWidth = 55f;
                float userWidth = 90f;
                float dateWidth = 80f;
                float timeWidth = 80f;
                float amountWidth = Math.Max(90f, bounds.Width - descriptionWidth - qtyWidth - userWidth - dateWidth - timeWidth);
                using var descriptionFormat = new System.Drawing.StringFormat
                {
                    Trimming = System.Drawing.StringTrimming.EllipsisWord,
                    FormatFlags = System.Drawing.StringFormatFlags.LineLimit
                };

                float GetRowHeight(string descriptionText)
                {
                    SizeF measured = graphics.MeasureString(descriptionText, bodyFont, new SizeF(descriptionWidth, maxDescriptionRowHeight), descriptionFormat);
                    return Math.Max(singleLineRowHeight, Math.Min(maxDescriptionRowHeight, measured.Height + 4f));
                }

                graphics.DrawString(GlobalSettings.CompanyName, titleFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += titleFont.GetHeight(graphics);
                graphics.DrawString(GlobalSettings.CompanyTagline, headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics) + 8f;
                graphics.DrawString("EXPENSE REPORT", titleFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += titleFont.GetHeight(graphics) + 8f;
                graphics.DrawString($"Report No: {reportNo}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                graphics.DrawString($"Date Range: {startDate:yyyy-MM-dd} to {endDate:yyyy-MM-dd}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                graphics.DrawString($"Store: {currentWarehouseName}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                graphics.DrawString($"Printed By: {CurrentUser.Username ?? string.Empty}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics) + 12f;

                while (rowIndex < lines.Count)
                {
                    string currentCategory = string.IsNullOrWhiteSpace(lines[rowIndex].Category) ? "Uncategorized" : lines[rowIndex].Category;
                    var categoryLines = new List<ExpenseReportLine>();
                    while (rowIndex < lines.Count)
                    {
                        string rowCategory = string.IsNullOrWhiteSpace(lines[rowIndex].Category) ? "Uncategorized" : lines[rowIndex].Category;
                        if (!string.Equals(rowCategory, currentCategory, StringComparison.OrdinalIgnoreCase))
                        {
                            break;
                        }
                        categoryLines.Add(lines[rowIndex]);
                        rowIndex++;
                    }

                    float linesHeight = categoryLines.Sum(line => GetRowHeight(string.IsNullOrWhiteSpace(line.Description) ? "(No Description)" : line.Description));
                    float estimatedHeight = categoryFont.GetHeight(graphics) + columnFont.GetHeight(graphics) + 20f + linesHeight + singleLineRowHeight + 12f;
                    if (y + estimatedHeight > bounds.Bottom - 20 && y > bounds.Top + 50)
                    {
                        e.HasMorePages = true;
                        return;
                    }

                    graphics.DrawString($"Category: {currentCategory}", categoryFont, System.Drawing.Brushes.Black, bounds.Left, y);
                    y += categoryFont.GetHeight(graphics) + 4f;
                    graphics.DrawString("Description", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left, y, descriptionWidth, singleLineRowHeight));
                    graphics.DrawString("Qty", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth, y, qtyWidth, singleLineRowHeight));
                    graphics.DrawString("User", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth, y, userWidth, singleLineRowHeight));
                    graphics.DrawString("Date", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth, y, dateWidth, singleLineRowHeight));
                    graphics.DrawString("Time", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth + dateWidth, y, timeWidth, singleLineRowHeight));
                    graphics.DrawString("Amount", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth + dateWidth + timeWidth, y, amountWidth, singleLineRowHeight), new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Far });
                    y += columnFont.GetHeight(graphics) + 4f;
                    graphics.DrawLine(System.Drawing.Pens.Black, bounds.Left, y, bounds.Right, y);
                    y += 6f;

                    decimal categoryTotal = 0m;
                    foreach (var line in categoryLines)
                    {
                        string description = string.IsNullOrWhiteSpace(line.Description) ? "(No Description)" : line.Description;
                        float rowHeight = GetRowHeight(description);
                        graphics.DrawString(description, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left, y, descriptionWidth, rowHeight), descriptionFormat);
                        graphics.DrawString($"{line.Quantity:N0}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth, y, qtyWidth, rowHeight));
                        graphics.DrawString(line.UserId, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth, y, userWidth, rowHeight));
                        graphics.DrawString(line.DateText, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth, y, dateWidth, rowHeight));
                        graphics.DrawString(line.TimeText, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth + dateWidth, y, timeWidth, rowHeight));
                        graphics.DrawString($"{line.Amount:N2}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth + dateWidth + timeWidth, y, amountWidth, rowHeight), new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Far });
                        y += rowHeight;
                        categoryTotal += line.Amount;
                    }

                    graphics.DrawLine(System.Drawing.Pens.Gray, bounds.Left, y, bounds.Right, y);
                    y += 4f;
                    graphics.DrawString($"Subtotal - {currentCategory}", columnFont, System.Drawing.Brushes.Black, bounds.Left, y);
                    graphics.DrawString($"{categoryTotal:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth + dateWidth + timeWidth, y, amountWidth, singleLineRowHeight), new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Far });
                    y += singleLineRowHeight + 8f;
                }

                if (y + singleLineRowHeight * 2 <= bounds.Bottom)
                {
                    graphics.DrawLine(System.Drawing.Pens.Black, bounds.Left, y, bounds.Right, y);
                    y += 8f;
                    graphics.DrawString("Grand Total", columnFont, System.Drawing.Brushes.Black, bounds.Left, y);
                    graphics.DrawString($"{grandTotal:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Right - amountWidth, y, amountWidth, singleLineRowHeight), new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Far });
                }

                e.HasMorePages = false;
            };

            using var printDialog = new PrintDialog
            {
                Document = printDocument,
                UseEXDialog = true,
                AllowSomePages = false,
                AllowSelection = false
            };

            if (printDialog.ShowDialog() != DialogResult.OK)
            {
                return;
            }

            printDocument.Print();
        }

        private static void ApplyA4PageSettings(System.Drawing.Printing.PrintDocument printDocument)
        {
            try
            {
                System.Drawing.Printing.PaperSize? a4 = null;
                try
                {
                    foreach (System.Drawing.Printing.PaperSize ps in printDocument.PrinterSettings.PaperSizes)
                    {
                        if (ps.Kind == System.Drawing.Printing.PaperKind.A4 || (ps.PaperName ?? string.Empty).IndexOf("A4", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            a4 = ps;
                            break;
                        }
                    }
                }
                catch { }

                printDocument.DefaultPageSettings.PaperSize = a4 ?? new System.Drawing.Printing.PaperSize("A4", 827, 1169);
                printDocument.DefaultPageSettings.Landscape = false;
                printDocument.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins(60, 60, 60, 60);
            }
            catch
            {
            }
        }

        private static string GenerateProfitAndLossReportContent(string connectionString, string reportNo, DateTime startDate, DateTime endDate)
        {
            var content = new StringBuilder();
            string line = new string('=', GlobalSettings.ReceiptWidth);
            DateTime endExclusive = endDate.Date.AddDays(1);

            content.AppendLine(line);
            content.AppendLine("     PROFIT AND LOSS");
            content.AppendLine(line);
            content.AppendLine($"Report No: {reportNo}");
            content.AppendLine($"Printed By: {CurrentUser.Username ?? string.Empty}");
            content.AppendLine($"Date Range:");
            content.AppendLine($"{startDate:yyyy-MM-dd} to {endDate:yyyy-MM-dd}");
            content.AppendLine(line);

            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();

                decimal totalSales = ExecuteDecimal(connection, @"SELECT ISNULL(SUM(GrossAmount), 0)
                                                                    FROM TransactionHeader
                                                                    WHERE Type = 'SALES'
                                                                      AND (EODID IS NULL OR EODID = '')
                                                                      AND [Date] >= @startDate
                                                                      AND [Date] < @endExclusive", startDate.Date, endExclusive);

                decimal totalIncomes = ExecuteDecimal(connection, @"SELECT ISNULL(SUM(GrossAmount), 0)
                                                                      FROM TransactionHeader
                                                                      WHERE Type = 'INCOME'
                                                                        AND (EODID IS NULL OR EODID = '')
                                                                        AND [Date] >= @startDate
                                                                        AND [Date] < @endExclusive", startDate.Date, endExclusive);

                decimal totalExpenses = ExecuteDecimal(connection, @"SELECT ISNULL(SUM(GrossAmount), 0)
                                                                       FROM TransactionHeader
                                                                       WHERE Type = 'EXPENSE'
                                                                         AND (EODID IS NULL OR EODID = '')
                                                                         AND [Date] >= @startDate
                                                                         AND [Date] < @endExclusive", startDate.Date, endExclusive);

                decimal totalDiscounts = ExecuteDecimal(connection, @"SELECT ISNULL(SUM(Discount), 0)
                                                                        FROM TransactionHeader
                                                                        WHERE (EODID IS NULL OR EODID = '')
                                                                          AND [Date] >= @startDate
                                                                          AND [Date] < @endExclusive", startDate.Date, endExclusive);

                decimal netProfitLoss = totalSales + totalIncomes - totalExpenses - totalDiscounts;

                content.AppendLine($"Total Sales   : ₱{totalSales,8:F2}");
                content.AppendLine($"Other Income  : ₱{totalIncomes,8:F2}");
                content.AppendLine($"Expenses      : ₱{totalExpenses,8:F2}");
                content.AppendLine($"Discounts     : ₱{totalDiscounts,8:F2}");
                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                content.AppendLine($"Net P/L       : ₱{netProfitLoss,8:F2}");
            }

            content.AppendLine(line);
            return content.ToString();
        }

        private static decimal ExecuteDecimal(SqlConnection connection, string query, DateTime? startDate = null, DateTime? endExclusive = null)
        {
            using var command = new SqlCommand(query, connection);
            if (startDate.HasValue)
            {
                command.Parameters.AddWithValue("@startDate", startDate.Value);
            }
            if (endExclusive.HasValue)
            {
                command.Parameters.AddWithValue("@endExclusive", endExclusive.Value);
            }
            object? result = command.ExecuteScalar();
            return result != null && result != DBNull.Value ? Convert.ToDecimal(result) : 0m;
        }

        private static string GenerateXReportContent(string connectionString, string receiptNo)
        {
            var content = new System.Text.StringBuilder();
            string line = new string('=', GlobalSettings.ReceiptWidth);

            // Header
            content.AppendLine(line);
            content.AppendLine("       X REPORT SUMMARY");
            content.AppendLine(line);
            content.AppendLine($"Report No: {receiptNo}");
            content.AppendLine($"Cashier: {CurrentUser.Username ?? ""}");
            content.AppendLine($"Date: {DateTime.Now:yyyy-MM-dd}");
            content.AppendLine($"Time: {DateTime.Now:hh:mm:ss tt}");
            content.AppendLine(line);
            content.AppendLine();

            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();

                // ITEMS TRANSACTION SOLD
                content.AppendLine("ITEMS SOLD:");
                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                decimal totalSales = 0;
                int totalItemsSold = 0;

                var itemsCmd = new SqlCommand(@"
                    SELECT th.Description, SUM(th.Quantity * -1) as TotalQty, SUM(th.GrossAmount) as TotalAmount
                    FROM ItemLedgerEntry th
                    WHERE  (th.EODID IS NULL OR th.EODID = '')
                    GROUP BY th.Description, th.GrossAmount
                    ORDER BY th.Description", connection);

                using (var reader = itemsCmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        string itemName = reader["Description"].ToString() ?? "";
                        int qty = Convert.ToInt32(reader["TotalQty"]);
                        decimal amount = Convert.ToDecimal(reader["TotalAmount"]);

                        // Wrap long item names for 58mm (limit to 12 chars for name)
                        if (itemName.Length > 12)
                        {
                            itemName = itemName.Substring(0, 12);
                        }

                        // Format for 58mm width (name: 12, qty: 3, amount: 8)
                        content.AppendLine($"{itemName,-12}{qty,3}{amount,10:F2}");

                        totalSales += amount;
                        totalItemsSold += qty;
                    }
                } // Close the items reader here

                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                content.AppendLine($"Total Items Sold: {totalItemsSold}");
                content.AppendLine($"Total Sales: ₱{totalSales:N2}");
                content.AppendLine();

                // PAYMENTS TENDERED
                content.AppendLine("PAYMENTS TENDERED:");
                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                decimal totalPayments = 0;
                var paymentsCmd = new SqlCommand(@"
                    SELECT tp.TenderTypeCode, SUM(tp.Amount) as TotalAmount, COUNT(*) as Count
                    FROM TransPaymentEntry tp
                    WHERE (tp.EODID IS NULL OR tp.EODID = '')
                    GROUP BY tp.TenderTypeCode
                    ORDER BY tp.TenderTypeCode", connection);

                using (var paymentsReader = paymentsCmd.ExecuteReader())
                {
                    while (paymentsReader.Read())
                    {
                        string tenderType = paymentsReader["TenderTypeCode"].ToString() ?? "";
                        decimal amount = Convert.ToDecimal(paymentsReader["TotalAmount"]);
                        int count = Convert.ToInt32(paymentsReader["Count"]);

                        // Format for 58mm width
                        content.AppendLine($"{tenderType,-6} ({count,3})₱{amount,12:F2}");
                        totalPayments += amount;
                    }
                } // Close the payments reader here

                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                content.AppendLine($"Tot Payments:₱{totalPayments:N2}");
                content.AppendLine(line);

                // ADVANCE ORDER COLLECTIONS (payments only, based on TransPaymentEntry rows still open for current EOD)
                content.AppendLine("ADV ORDER COLLECTIONS:");
                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                decimal advanceCollectionTotal = 0m;
                int advanceCollectionCount = 0;
                var advanceCollectionsCmd = new SqlCommand(@"
                    SELECT tp.TenderTypeCode, SUM(tp.Amount) as TotalAmount, COUNT(*) as Count
                    FROM TransPaymentEntry tp
                    WHERE (tp.EODID IS NULL OR tp.EODID = '')
                      AND EXISTS (
                          SELECT 1
                          FROM AdvanceOrderHeader ah
                          WHERE ah.ReceiptNo = tp.ReceiptNo
                      )
                    GROUP BY tp.TenderTypeCode
                    ORDER BY tp.TenderTypeCode", connection);

                using (var advanceCollectionsReader = advanceCollectionsCmd.ExecuteReader())
                {
                    while (advanceCollectionsReader.Read())
                    {
                        string tenderType = advanceCollectionsReader["TenderTypeCode"].ToString() ?? "";
                        decimal amount = Convert.ToDecimal(advanceCollectionsReader["TotalAmount"]);
                        int count = Convert.ToInt32(advanceCollectionsReader["Count"]);

                        content.AppendLine($"{tenderType,-6} ({count,3})₱{amount,12:F2}");
                        advanceCollectionTotal += amount;
                        advanceCollectionCount += count;
                    }
                }

                if (advanceCollectionCount == 0)
                {
                    content.AppendLine("No advance collections.");
                }

                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                content.AppendLine($"Adv Collections:₱{advanceCollectionTotal:N2}");
                content.AppendLine();

                // ADVANCE ORDERS SUMMARY
                content.AppendLine("ADVANCE ORDERS:");
                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                // Totals from AdvanceOrderLines (per-line quantities and sales for ITEM lines)
                decimal advanceLinesSales = 0m;
                int advanceLinesQty = 0;
                var advLinesCmd = new SqlCommand(@"
                    SELECT ISNULL(SUM(CASE WHEN [Type] = 'ITEM' THEN Quantity ELSE 0 END),0) as TotalQty,
                           ISNULL(SUM(CASE WHEN [Type] = 'ITEM' THEN NetAmount ELSE 0 END),0) as TotalSales
                    FROM AdvanceOrderLines
                    WHERE (EODID IS NULL OR EODID = '')", connection);
                using (var advLinesReader = advLinesCmd.ExecuteReader())
                {
                    if (advLinesReader.Read())
                    {
                        advanceLinesQty = advLinesReader["TotalQty"] != DBNull.Value ? Convert.ToInt32(advLinesReader["TotalQty"]) : 0;
                        advanceLinesSales = advLinesReader["TotalSales"] != DBNull.Value ? Convert.ToDecimal(advLinesReader["TotalSales"]) : 0m;
                    }
                }

                // Totals from AdvanceOrderHeader (count of advance orders and header-level sales/net amount)
                int advanceHeadersCount = 0;
                decimal advanceHeadersSales = 0m;
                var advHdrCmd = new SqlCommand(@"
                    SELECT ISNULL(COUNT(*),0) as OrderCount, ISNULL(SUM(NetAmount),0) as OrderSales
                    FROM AdvanceOrderHeader
                    WHERE (EODID IS NULL OR EODID = '')", connection);
                using (var advHdrReader = advHdrCmd.ExecuteReader())
                {
                    if (advHdrReader.Read())
                    {
                        advanceHeadersCount = advHdrReader["OrderCount"] != DBNull.Value ? Convert.ToInt32(advHdrReader["OrderCount"]) : 0;
                        advanceHeadersSales = advHdrReader["OrderSales"] != DBNull.Value ? Convert.ToDecimal(advHdrReader["OrderSales"]) : 0m;
                    }
                }

                // Append formatted advance order lines and header totals
                content.AppendLine($"Adv Lines Sold: {advanceLinesQty}");
                content.AppendLine($"Adv Lines Sales: ₱{advanceLinesSales:N2}");
                content.AppendLine($"Adv Orders Count: {advanceHeadersCount}");
                content.AppendLine($"Adv Orders Sales: ₱{advanceHeadersSales:N2}");
                content.AppendLine();

                // EXPENSES MADE
                content.AppendLine("EXPENSES MADE:");
                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                decimal totalExpenses = 0;
                int expenseCount = 0;

                var expensesCmd = new SqlCommand(@"
                    SELECT Description, Quantity, GrossAmount, Date
                    FROM TransactionHeader
                    WHERE Type = 'EXPENSE'
                    AND (EODID IS NULL OR EODID = '')
                    ORDER BY Date", connection);

                using (var expenseReader = expensesCmd.ExecuteReader())
                {
                    while (expenseReader.Read())
                    {
                        string description = expenseReader["Description"].ToString() ?? "";
                        int quantity = Convert.ToInt32(expenseReader["Quantity"]);
                        decimal grossAmount = Convert.ToDecimal(expenseReader["GrossAmount"]);
                        DateTime expenseDate = Convert.ToDateTime(expenseReader["Date"]);

                        // Truncate long descriptions for 58mm width (12 chars)
                        if (description.Length > 12)
                            description = description.Substring(0, 12);

                        content.AppendLine($"{description,-12} ₱{grossAmount,11:F2}");
                        totalExpenses += grossAmount;
                        expenseCount++;
                    }
                } // Close the expenses reader here

                if (expenseCount == 0)
                {
                    content.AppendLine("No expenses recorded today.");
                }

                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                content.AppendLine($"Total Expenses: ₱{totalExpenses:F2}");
                content.AppendLine();

                // INCOME TOTALS
                content.AppendLine("INCOME TOTALS:");
                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));

                decimal totalIncomes = 0m;
                int incomeCount = 0;
                var incomesCmd = new SqlCommand(@"
                    SELECT Description, Quantity, GrossAmount, Date
                    FROM TransactionHeader
                    WHERE Type = 'INCOME'
                    AND (EODID IS NULL OR EODID = '')
                    ORDER BY Date", connection);

                using (var incomesReader = incomesCmd.ExecuteReader())
                {
                    while (incomesReader.Read())
                    {
                        string description = incomesReader["Description"].ToString() ?? "";
                        int quantity = incomesReader["Quantity"] != DBNull.Value ? Convert.ToInt32(incomesReader["Quantity"]) : 0;
                        decimal grossAmount = incomesReader["GrossAmount"] != DBNull.Value ? Convert.ToDecimal(incomesReader["GrossAmount"]) : 0m;

                        // Truncate long descriptions for 58mm width (12 chars)
                        if (description.Length > 12)
                            description = description.Substring(0, 12);

                        content.AppendLine($"{description,-12} ₱{grossAmount,11:F2}");
                        totalIncomes += grossAmount;
                        incomeCount++;
                    }
                }

                if (incomeCount == 0)
                {
                    content.AppendLine("No incomes recorded today.");
                }

                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                content.AppendLine($"Total Incomes: ₱{totalIncomes:F2}");
                content.AppendLine();

                // NUMBER OF TRANSACTIONS
                content.AppendLine("TRANSACTION SUMMARY:");
                content.AppendLine(new string('-', GlobalSettings.ReceiptWidth));
                var transCountCmd = new SqlCommand(@"
                    SELECT COUNT(DISTINCT TransactionNo) as TransCount
                    FROM TransactionHeader
                    WHERE (EODID IS NULL OR EODID = '')", connection);

                int transactionCount = Convert.ToInt32(transCountCmd.ExecuteScalar());
                content.AppendLine($"Num of Trans: {transactionCount}");

                // Calculate averages
                if (transactionCount > 0)
                {
                    decimal avgTransactionValue = totalSales / transactionCount;
                    content.AppendLine($"Average Value: ₱{avgTransactionValue:F2}");
                }

                content.AppendLine();

                // SUMMARY TOTALS
                content.AppendLine(new string('=', GlobalSettings.ReceiptWidth));
                content.AppendLine("DAILY SUMMARY:");
                content.AppendLine(new string('=', GlobalSettings.ReceiptWidth));
                content.AppendLine($"Total Sales:   ₱{totalSales,8:F2}");
                // Total discounts for the day: sum of Discount from TransactionHeader and AdvanceOrderHeader
                decimal totalDiscounts = 0m;
                // Sum discounts from TransactionHeader
                var tranDiscCmd = new SqlCommand(@"
                    SELECT ISNULL(SUM(Discount),0) as TotalDiscounts
                    FROM TransactionHeader
                    WHERE (EODID IS NULL OR EODID = '')", connection);
                var tranDiscObj = tranDiscCmd.ExecuteScalar();
                if (tranDiscObj != null && tranDiscObj != DBNull.Value)
                    totalDiscounts += Convert.ToDecimal(tranDiscObj);

                // Sum discounts from AdvanceOrderHeader
                var advHdrDiscCmd = new SqlCommand(@"
                    SELECT ISNULL(SUM(Discount),0) as TotalDiscounts
                    FROM AdvanceOrderHeader
                    WHERE (EODID IS NULL OR EODID = '')", connection);
                var advHdrDiscObj = advHdrDiscCmd.ExecuteScalar();
                if (advHdrDiscObj != null && advHdrDiscObj != DBNull.Value)
                    totalDiscounts += Convert.ToDecimal(advHdrDiscObj);

                content.AppendLine($"Total Discounts: ₱{totalDiscounts,8:F2}");
                content.AppendLine($"Total Payments:₱{totalPayments,8:F2}");
                content.AppendLine($"Total Incomes: ₱{totalIncomes,8:F2}");
                content.AppendLine($"Total Expenses:₱{totalExpenses,8:F2}");
                // Net Payments Flow now includes incomes as incoming cash aside from payments
                content.AppendLine($"Net Payments Flow: ₱{(totalPayments + totalIncomes - totalExpenses),8:F2}");
                content.AppendLine($"Gross Profit:  ₱{(totalSales + totalIncomes - totalExpenses),8:F2}");
                content.AppendLine(new string('=', GlobalSettings.ReceiptWidth));



                content.AppendLine();
                content.AppendLine($"Report: {DateTime.Now:yyyy-MM-dd HH:mm}");
                content.AppendLine($"Terminal: {Environment.MachineName}");
                content.AppendLine(new string('=', GlobalSettings.ReceiptWidth));
            }

            return content.ToString();
        }

        // Print a simple stock counts receipt for a batch
        public static void PrintStockCounts(string batchDocNo, System.Collections.Generic.List<(string Code, string Description, int Count)> lines)
        {
            try
            {
                if (lines == null || lines.Count == 0) return;

                // Create and configure print document for 58mm thermal printer
                var printDocument = new System.Drawing.Printing.PrintDocument();
                var printFont = new System.Drawing.Font(GlobalSettings.ReceiptFont, GlobalSettings.ReceiptFontSize, GlobalSettings.ReceiptFontStyle);

                printDocument.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("58mm",
                    (int)(GlobalSettings.PaperWidthInches * 100),
                    (int)(GlobalSettings.PaperHeightInches * 100));
                printDocument.DefaultPageSettings.Margins = new System.Drawing.Printing.Margins(
                    (int)(GlobalSettings.LeftMarginInches * 100),
                    (int)(GlobalSettings.LeftMarginInches * 100),
                    (int)(GlobalSettings.TopMarginInches * 100),
                    (int)(GlobalSettings.TopMarginInches * 100));

                string receiptPrinterName = MainForm.ResolveReceiptPrinterName();
                if (!string.IsNullOrWhiteSpace(receiptPrinterName))
                {
                    printDocument.PrinterSettings.PrinterName = receiptPrinterName;
                }

                var content = new System.Text.StringBuilder();
                string lineSep = new string('=', GlobalSettings.ReceiptWidth);
                content.AppendLine(lineSep);
                content.AppendLine("       STOCK COUNTS POST");
                content.AppendLine(lineSep);
                content.AppendLine($"Batch: {batchDocNo}");
                content.AppendLine($"User: {CurrentUser.Username ?? ""}");
                content.AppendLine($"Date: {DateTime.Now:yyyy-MM-dd}");
                content.AppendLine($"Time: {DateTime.Now:hh:mm:ss tt}");
                content.AppendLine(lineSep);
                content.AppendLine($"Item Code       Qty");

                // Lines: left = Code (max 14), qty right-aligned (6), desc truncated to remaining width
                foreach (var l in lines)
                {
                    string code = (l.Code ?? string.Empty).Trim();
                    string desc = (l.Description ?? string.Empty).Trim();
                    string codePart = code.Length > 14 ? code.Substring(0, 14) : code.PadRight(14);
                    string qtyPart = l.Count.ToString().PadLeft(6);
                    // remaining width for description
                    int rem = Math.Max(0, GlobalSettings.ReceiptWidth - 14 - 6);
                    if (desc.Length > rem) desc = desc.Substring(0, rem);
                    content.AppendLine($"{codePart}{qtyPart}");
                }

                content.AppendLine(lineSep);

                string[] linesToPrint = content.ToString().Split('\n');
                int currentLineIndex = 0;

                printDocument.PrintPage += (sender, e) =>
                {
                    if (e.Graphics != null)
                    {
                        float yPosition = 10;
                        float lineHeight = printFont.GetHeight();

                        while (currentLineIndex < linesToPrint.Length)
                        {
                            if (yPosition + lineHeight > e.MarginBounds.Height - 50)
                            {
                                e.HasMorePages = true;
                                return;
                            }

                            e.Graphics.DrawString(FunctionEvents.ToAscii(linesToPrint[currentLineIndex]), printFont, System.Drawing.Brushes.Black, 10, yPosition);
                            yPosition += lineHeight;
                            currentLineIndex++;
                        }

                        e.HasMorePages = false;
                    }
                };

                printDocument.Print();
                printFont.Dispose();
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"Error printing Stock Counts: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
            }
        }

    }
}