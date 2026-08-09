using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AquariumPOS
{
    public static class PostingEvents
    {
        internal sealed class ExpenseReportLine
        {
            public string Category { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string UserId { get; init; } = string.Empty;
            public string DateText { get; init; } = string.Empty;
            public string TimeText { get; init; } = string.Empty;
            public decimal Quantity { get; init; }
            public decimal Amount { get; init; }
        }

        private sealed class ItemVariantSalesReportLine
        {
            public string ReportKey { get; init; } = string.Empty;
            public string ItemCode { get; init; } = string.Empty;
            public string ItemDescription { get; init; } = string.Empty;
            public decimal TransferredQuantity { get; init; }
            public decimal LocalOrderQuantity { get; init; }
            public decimal OnlineOrderQuantity { get; init; }
            public decimal TotalQuantity => TransferredQuantity - LocalOrderQuantity - OnlineOrderQuantity;
        }

        private sealed class TransferReportAggregate
        {
            public string ReportKey { get; init; } = string.Empty;
            public string ItemCode { get; set; } = string.Empty;
            public string ItemDescription { get; set; } = string.Empty;
            public decimal Quantity { get; set; }
            public int SourceLineCount { get; set; }
        }

        private sealed class ItemVariantSalesReportBuildResult
        {
            public List<ItemVariantSalesReportLine> Lines { get; init; } = new List<ItemVariantSalesReportLine>();
            public int MatchedTransferLineCount { get; init; }
            public int MatchedTransferAggregateCount { get; init; }
        }

        private sealed class TransferReportSyncState
        {
            public DateTime? LastSyncUtc { get; init; }
            public DateTime? StartDate { get; init; }
            public DateTime? EndDate { get; init; }
            public string ReportKeyFilter { get; init; } = string.Empty;
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
                    && item.Tag?.ToString() != "CARD_PROCESSING_FEE"
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
                    && item.Tag?.ToString() != "CARD_PROCESSING_FEE"
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

                try
                {
                    string warehouseName = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString)?.Name ?? string.Empty;
                    OnlinefunctionsEvents.SyncExpenseReportToSupabaseAsync(
                        reportNo,
                        DateTime.Now,
                        startDate,
                        endDate,
                        warehouseName,
                        CurrentUser.Username ?? string.Empty,
                        lines).GetAwaiter().GetResult();
                }
                catch (Exception syncEx)
                {
                    MessageBox.Show($"Expense Report printed, but failed to sync to Supabase: {syncEx.Message}", "Cloud Sync Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
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

        public static async Task OpenItemVariantSalesWorksheet(string reportNo, DateTime startDate, DateTime endDate, string? reportKeyFilter = null, string? itemVariantFilterDisplay = null, IWin32Window? owner = null)
        {
            bool alreadyPosted = ItemVariantSalesWorksheetData.GetMonthEndHeaders(GlobalSettings.ConnectionString)
                .Any(header => header.FromDate.Date == startDate.Date && header.ToDate.Date == endDate.Date);

            if (alreadyPosted)
            {
                MessageBox.Show(
                    owner,
                    $"Month End has already been posted for {startDate:yyyy-MM-dd} to {endDate:yyyy-MM-dd}.\n\nGenerating another worksheet for the same date coverage is not allowed.",
                    "Month End Already Posted",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return;
            }

            using var progressForm = new ItemVariantWorksheetProgressForm("Refreshing completed transfers...");
            if (owner is Control ownerControl)
                progressForm.Show(ownerControl);
            else
                progressForm.Show();

            IProgress<string> progress = new Progress<string>(status => progressForm.UpdateStatus(status));

            try
            {
                ItemVariantSalesReportBuildResult reportBuild = null!;
                List<ItemVariantSalesReportLine> orderedLines = null!;
                Dictionary<string, decimal> cloudQtyByReportKey = null!;

                await Task.Run(() =>
                {
                    progress.Report("Refreshing completed transfers...");
                    SyncCompletedTransfersToLocalDb(startDate, endDate, reportKeyFilter);

                    progress.Report("Building item variant sales lines...");
                    reportBuild = GenerateItemVariantSalesReportLines(GlobalSettings.ConnectionString, startDate, endDate, reportKeyFilter);

                    if (reportBuild.Lines.Count == 0)
                        return;

                    orderedLines = reportBuild.Lines
                        .OrderByDescending(line => line.LocalOrderQuantity + line.OnlineOrderQuantity)
                        .ThenBy(line => string.IsNullOrWhiteSpace(line.ItemDescription) ? line.ItemCode : line.ItemDescription, StringComparer.OrdinalIgnoreCase)
                        .ThenBy(line => line.ItemCode, StringComparer.OrdinalIgnoreCase)
                        .ToList();

                    progress.Report("Validating cloud variant IDs...");
                    orderedLines = ResolveCloudVariationIds(GlobalSettings.ConnectionString, orderedLines);

                    progress.Report($"Fetching cloud quantities for {orderedLines.Count} item(s)...");
                    cloudQtyByReportKey = OnlinefunctionsEvents.GetCloudRemainingQuantitiesByReportKey(
                        orderedLines.Select(line => line.ReportKey),
                        TimeSpan.FromSeconds(30));

                    progress.Report("Resolving product IDs from local item sync...");
                    var productIdByReportKey = GetProductIdsByReportKey(
                        GlobalSettings.ConnectionString,
                        orderedLines.Select(line => (line.ReportKey, line.ItemCode)));

                    progress.Report("Resolving opening stock from prior Month End...");
                    var openingStockByReportKey = ItemVariantSalesWorksheetData.GetOpeningStockByReportKey(GlobalSettings.ConnectionString, startDate.Date);

                    progress.Report("Saving worksheet...");

                    var currentWarehouse = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString);
                    string currentWarehouseDisplay = currentWarehouse?.Name ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(currentWarehouseDisplay))
                        currentWarehouseDisplay = currentWarehouse?.Id ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(currentWarehouseDisplay))
                        currentWarehouseDisplay = "Not Set";

                    ItemVariantSalesWorksheetData.SaveWorksheet(
                        GlobalSettings.ConnectionString,
                        new ItemVariantSalesWorksheetHeader
                        {
                            DocumentNo = reportNo,
                            GeneratedDate = DateTime.Now,
                            FromDate = startDate.Date,
                            ToDate = endDate.Date,
                            WarehouseName = currentWarehouseDisplay,
                            ItemVariantFilter = string.IsNullOrWhiteSpace(itemVariantFilterDisplay) ? string.Empty : itemVariantFilterDisplay,
                            GeneratedBy = CurrentUser.Username ?? string.Empty
                        },
                        orderedLines.Select((line, index) => new ItemVariantSalesWorksheetLine
                        {
                            LineNo = index + 1,
                            ReportKey = line.ReportKey,
                            ItemNo = line.ItemCode,
                            Description = string.IsNullOrWhiteSpace(line.ItemDescription) ? line.ItemCode : line.ItemDescription,
                            QtyTransferred = line.TransferredQuantity,
                            LocalSales = line.LocalOrderQuantity,
                            OnlineSales = line.OnlineOrderQuantity,
                            QtyOnHand = cloudQtyByReportKey.TryGetValue(line.ReportKey, out var cloudQty)
                                ? cloudQty
                                : 0m,
                            PhysicalQtyOnHand = null,
                            OpeningStock = openingStockByReportKey.TryGetValue(line.ReportKey, out var openingStock)
                                ? openingStock
                                : 0m,
                            ProductId = productIdByReportKey.TryGetValue(line.ReportKey, out var productId)
                                ? productId
                                : string.Empty
                        }).ToList());
                });

                progressForm.Close();

                if (reportBuild.Lines.Count == 0)
                {
                    MessageBox.Show("No item variant sales were found for the selected date range.", "No Data", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                using var worksheetForm = new ItemVariantSalesWorksheetForm(reportNo);
                if (owner != null)
                    worksheetForm.ShowDialog(owner);
                else
                    worksheetForm.ShowDialog();
            }
            catch (Exception ex)
            {
                progressForm.Close();
                MessageBox.Show($"Error generating Item Variant Sales Worksheet: {ex.Message}", "Worksheet Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        public static int SyncCompletedTransfersToLocalDb(DateTime startDate, DateTime endDate, string? reportKeyFilter = null)
        {
            var aggregates = GetCompletedTransferReportAggregates(startDate, endDate, reportKeyFilter);
            SaveTransferReportLastSyncUtc(startDate, endDate, reportKeyFilter, DateTime.UtcNow);
            return aggregates.Count;
        }

        public sealed class MonthEndUpdateQuantityPreviewLine
        {
            public int LineNo { get; init; }
            public string ItemNo { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public decimal? PhysicalQtyOnHand { get; init; }
            /// <summary>"DEFECT", "PURCHASE", or "NONE" (Qty on Hand matches Physical Qty On Hand).</summary>
            public string ActionType { get; init; } = string.Empty;
            public decimal AdjustmentQuantity { get; init; }
            public string Endpoint { get; init; } = string.Empty;
            public string PayloadJson { get; init; } = string.Empty;
            public string ErrorMessage { get; init; } = string.Empty;
        }

        public sealed class MonthEndUpdateQuantityPreview
        {
            public string ShopId { get; init; } = string.Empty;
            public string WarehouseId { get; init; } = string.Empty;
            public int TotalLines { get; init; }
            public int EligibleLines { get; init; }
            public int MatchedLines { get; init; }
            public int SkippedLines { get; init; }
            public IReadOnlyList<MonthEndUpdateQuantityPreviewLine> Lines { get; init; } = Array.Empty<MonthEndUpdateQuantityPreviewLine>();
        }

        /// <summary>
        /// Decides which cloud adjustment (if any) applies to a Month End line, based on comparing
        /// the system Qty on Hand to the counted Physical Qty On Hand:
        ///  - Qty on Hand &gt; Physical Qty On Hand  -&gt; DEFECT (write-off the shortage via the export endpoint).
        ///  - Qty on Hand &lt; Physical Qty On Hand  -&gt; PURCHASE (stock-in the surplus via the purchases endpoint).
        ///  - Equal                                 -&gt; NONE (no cloud call needed).
        /// </summary>
        private static OnlinefunctionsEvents.MonthEndAdjustmentRequestPreview? BuildMonthEndLineAdjustmentPreview(
            string shopId, string warehouseId, string variationId, decimal qtyOnHand, decimal physicalQtyOnHand, string note)
        {
            decimal diff = qtyOnHand - physicalQtyOnHand;
            if (diff == 0m)
                return null;

            return diff > 0m
                ? OnlinefunctionsEvents.BuildDefectAdjustmentPreview(shopId, warehouseId, variationId, diff, note)
                : OnlinefunctionsEvents.BuildPurchaseAdjustmentPreview(shopId, warehouseId, variationId, -diff, note);
        }

        public static MonthEndUpdateQuantityPreview BuildItemVariantSalesWorksheetMonthEndPreview(
            ItemVariantSalesWorksheetHeader worksheetHeader,
            IReadOnlyList<ItemVariantSalesWorksheetLine> worksheetLines)
        {
            if (worksheetHeader == null)
                throw new ArgumentNullException(nameof(worksheetHeader));
            if (worksheetLines == null)
                throw new ArgumentNullException(nameof(worksheetLines));

            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            string warehouseId = string.Empty;

            if (!string.IsNullOrWhiteSpace(shopId))
            {
                try
                {
                    warehouseId = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString)?.Id?.Trim() ?? string.Empty;
                }
                catch
                {
                    warehouseId = string.Empty;
                }
            }

            var previewLines = new List<MonthEndUpdateQuantityPreviewLine>(worksheetLines.Count);
            int eligibleLines = 0;
            int matchedLines = 0;
            int skippedLines = 0;

            foreach (var line in worksheetLines)
            {
                string reportKey = line.ReportKey?.Trim() ?? string.Empty;
                string variationId = reportKey.StartsWith("VAR:", StringComparison.OrdinalIgnoreCase)
                    ? reportKey.Substring(4).Trim()
                    : string.Empty;
                string errorMessage = string.Empty;
                string endpoint = string.Empty;
                string payloadJson = string.Empty;
                string actionType = string.Empty;
                decimal adjustmentQuantity = 0m;

                if (!line.PhysicalQtyOnHand.HasValue)
                {
                    errorMessage = "Physical Qty On Hand is blank.";
                }
                else if (string.IsNullOrWhiteSpace(variationId))
                {
                    errorMessage = "Cloud adjustment skipped because the line has no variation ID.";
                }
                else if (string.IsNullOrWhiteSpace(shopId))
                {
                    errorMessage = "OnlineOrdersShopId is not configured.";
                }
                else if (string.IsNullOrWhiteSpace(warehouseId))
                {
                    errorMessage = "No current warehouse is selected for the cloud adjustment.";
                }
                else
                {
                    string note = $"Physical count adjustment ({worksheetHeader.DocumentNo} / line {line.LineNo})";
                    var requestPreview = BuildMonthEndLineAdjustmentPreview(shopId, warehouseId, variationId, line.QtyOnHand, line.PhysicalQtyOnHand.Value, note);
                    if (requestPreview == null)
                    {
                        actionType = "NONE";
                        matchedLines++;
                    }
                    else
                    {
                        endpoint = requestPreview.Endpoint;
                        payloadJson = requestPreview.PayloadJson;
                        actionType = requestPreview.ActionType;
                        adjustmentQuantity = requestPreview.Quantity;
                        eligibleLines++;
                    }
                }

                if (!string.IsNullOrWhiteSpace(errorMessage))
                    skippedLines++;

                previewLines.Add(new MonthEndUpdateQuantityPreviewLine
                {
                    LineNo = line.LineNo,
                    ItemNo = line.ItemNo,
                    Description = line.Description,
                    VariationId = variationId,
                    PhysicalQtyOnHand = line.PhysicalQtyOnHand,
                    ActionType = actionType,
                    AdjustmentQuantity = adjustmentQuantity,
                    Endpoint = endpoint,
                    PayloadJson = payloadJson,
                    ErrorMessage = errorMessage
                });
            }

            return new MonthEndUpdateQuantityPreview
            {
                ShopId = shopId,
                WarehouseId = warehouseId,
                TotalLines = worksheetLines.Count,
                EligibleLines = eligibleLines,
                MatchedLines = matchedLines,
                SkippedLines = skippedLines,
                Lines = previewLines
            };
        }

        public static async Task<MonthEndHeader> PostItemVariantSalesWorksheetMonthEndAsync(ItemVariantSalesWorksheetHeader worksheetHeader, IReadOnlyList<ItemVariantSalesWorksheetLine> worksheetLines, IProgress<string>? progress = null)
        {
            if (worksheetHeader == null)
                throw new ArgumentNullException(nameof(worksheetHeader));
            if (worksheetLines == null)
                throw new ArgumentNullException(nameof(worksheetLines));

            string monthEndNo = $"ME-{DateTime.Now:yyyyMMdd-HHmmss}";
            string postedBy = CurrentUser.Username ?? string.Empty;
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            string warehouseId = string.Empty;

            if (!string.IsNullOrWhiteSpace(shopId))
            {
                try
                {
                    warehouseId = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString)?.Id?.Trim() ?? string.Empty;
                }
                catch
                {
                    warehouseId = string.Empty;
                }
            }

            var postedLines = new List<MonthEndLine>(worksheetLines.Count);
            int patchedCount = 0;
            int skippedCount = 0;
            int failedCount = 0;

            for (int index = 0; index < worksheetLines.Count; index++)
            {
                var line = worksheetLines[index];

                if (!line.PhysicalQtyOnHand.HasValue)
                {
                    // Lines with no Physical Qty On Hand entered are not carried over to the posted Month End data.
                    continue;
                }

                string reportKey = line.ReportKey?.Trim() ?? string.Empty;
                string variationId = reportKey.StartsWith("VAR:", StringComparison.OrdinalIgnoreCase)
                    ? reportKey.Substring(4).Trim()
                    : string.Empty;

                decimal? cloudPreviousQty = null;
                decimal? cloudUpdatedQty = null;
                string cloudPatchStatus;
                string cloudPatchMessage;
                string lastErrorEndpoint = string.Empty;
                string lastErrorPayload = string.Empty;
                bool sentToOnline = false;
                string productId = line.ProductId?.Trim() ?? string.Empty;

                progress?.Report($"Posting month end {index + 1}/{worksheetLines.Count}: {(!string.IsNullOrWhiteSpace(line.Description) ? line.Description : line.ItemNo)}");

                if (string.IsNullOrWhiteSpace(variationId))
                {
                    cloudPatchStatus = "SKIPPED";
                    cloudPatchMessage = "Cloud adjustment skipped because the line has no variation ID.";
                    skippedCount++;
                }

                else if (string.IsNullOrWhiteSpace(shopId))
                {
                    cloudPatchStatus = "FAILED";
                    cloudPatchMessage = "OnlineOrdersShopId is not configured.";
                    failedCount++;
                }
                else if (string.IsNullOrWhiteSpace(warehouseId))
                {
                    cloudPatchStatus = "FAILED";
                    cloudPatchMessage = "No current warehouse is selected for the cloud adjustment.";
                    failedCount++;
                }
                else
                {
                    cloudPreviousQty = line.QtyOnHand;
                    cloudUpdatedQty = line.PhysicalQtyOnHand.Value;

                    string note = $"Physical count adjustment ({monthEndNo} / line {line.LineNo})";
                    var adjustmentPreview = BuildMonthEndLineAdjustmentPreview(shopId, warehouseId, variationId, line.QtyOnHand, line.PhysicalQtyOnHand.Value, note);

                    if (adjustmentPreview == null)
                    {
                        cloudPatchStatus = "MATCHED";
                        cloudPatchMessage = "Qty on Hand matches Physical Qty On Hand. No cloud adjustment needed.";
                        sentToOnline = true;
                    }
                    else
                    {
                        progress?.Report($"Posting {adjustmentPreview.ActionType.ToLowerInvariant()} adjustment {index + 1}/{worksheetLines.Count}: {(!string.IsNullOrWhiteSpace(line.Description) ? line.Description : line.ItemNo)}");

                        try
                        {
                            await OnlinefunctionsEvents.PostMonthEndAdjustmentAsync(adjustmentPreview, TimeSpan.FromSeconds(30)).ConfigureAwait(false);

                            cloudPatchStatus = "PATCHED";
                            cloudPatchMessage = adjustmentPreview.ActionType == "DEFECT"
                                ? $"Defect adjustment posted. {adjustmentPreview.Quantity:N2} unit(s) written off (Qty on Hand {line.QtyOnHand:N2} > Physical {line.PhysicalQtyOnHand.Value:N2})."
                                : $"Purchase adjustment posted. {adjustmentPreview.Quantity:N2} unit(s) added (Physical {line.PhysicalQtyOnHand.Value:N2} > Qty on Hand {line.QtyOnHand:N2}).";
                            sentToOnline = true;
                            patchedCount++;
                        }
                        catch (Exception ex)
                        {
                            cloudPatchStatus = "FAILED";
                            cloudPatchMessage = ex.Message;
                            lastErrorEndpoint = (ex as OnlinefunctionsEvents.MonthEndAdjustmentRequestException)?.Endpoint ?? string.Empty;
                            lastErrorPayload = (ex as OnlinefunctionsEvents.MonthEndAdjustmentRequestException)?.PayloadJson ?? string.Empty;
                            failedCount++;
                        }
                    }
                }

                postedLines.Add(new MonthEndLine
                {
                    LineNo = line.LineNo,
                    ReportKey = reportKey,
                    ItemNo = line.ItemNo,
                    Description = line.Description,
                    QtyTransferred = line.QtyTransferred,
                    LocalSales = line.LocalSales,
                    OnlineSales = line.OnlineSales,
                    QtyOnHand = line.QtyOnHand,
                    PhysicalQtyOnHand = line.PhysicalQtyOnHand,
                    OpeningStock = line.OpeningStock,
                    VariationId = variationId,
                    CloudWarehouseId = warehouseId,
                    CloudPreviousQtyOnHand = cloudPreviousQty,
                    CloudUpdatedQtyOnHand = cloudUpdatedQty,
                    CloudPatchStatus = cloudPatchStatus,
                    CloudPatchMessage = cloudPatchMessage,
                    SentToOnline = sentToOnline,
                    LastErrorEndpoint = lastErrorEndpoint,
                    LastErrorPayload = lastErrorPayload,
                    LastErrorMessage = cloudPatchStatus == "FAILED" ? cloudPatchMessage : string.Empty,
                    ProductId = productId
                });
            }

            var monthEndHeader = new MonthEndHeader
            {
                DocumentNo = monthEndNo,
                WorksheetDocumentNo = worksheetHeader.DocumentNo,
                WorksheetGeneratedDate = worksheetHeader.GeneratedDate,
                FromDate = worksheetHeader.FromDate,
                ToDate = worksheetHeader.ToDate,
                WarehouseName = worksheetHeader.WarehouseName,
                ItemVariantFilter = worksheetHeader.ItemVariantFilter,
                WorksheetGeneratedBy = worksheetHeader.GeneratedBy,
                PostedBy = postedBy,
                PostedAtUtc = DateTime.UtcNow,
                TotalLines = postedLines.Count,
                CloudPatchedLines = patchedCount,
                CloudSkippedLines = skippedCount,
                CloudFailedLines = failedCount
            };

            progress?.Report("Saving month end log...");
            ItemVariantSalesWorksheetData.SaveMonthEndPost(GlobalSettings.ConnectionString, monthEndHeader, postedLines);

            progress?.Report("Sending Month End to cloud (Supabase)...");
            try
            {
                await OnlinefunctionsEvents.SyncMonthEndToSupabaseAsync(monthEndHeader, postedLines).ConfigureAwait(true);
                monthEndHeader.SentToCloud = true;
                monthEndHeader.SupabaseSyncMessage = string.Empty;
            }
            catch (Exception ex)
            {
                monthEndHeader.SentToCloud = false;
                monthEndHeader.SupabaseSyncMessage = ex.Message;
                progress?.Report($"Warning: Month End was posted locally, but syncing to Supabase failed: {ex.Message}");
            }

            ItemVariantSalesWorksheetData.UpdateMonthEndHeaderSentToCloud(GlobalSettings.ConnectionString, monthEndHeader.DocumentNo, monthEndHeader.SentToCloud);

            return monthEndHeader;
        }

        /// <summary>
        /// Re-attempts sending a previously posted Month End header (and its lines) to Supabase.
        /// Used by the Resend button when the header has not yet been successfully sent to the cloud.
        /// </summary>
        public static async Task<(bool Success, string Message)> ResendMonthEndHeaderToSupabaseAsync(string documentNo, IProgress<string>? progress = null)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                throw new ArgumentException("Document No. is required.", nameof(documentNo));

            var header = ItemVariantSalesWorksheetData.GetMonthEndHeaders(GlobalSettings.ConnectionString)
                .FirstOrDefault(h => string.Equals(h.DocumentNo, documentNo, StringComparison.OrdinalIgnoreCase))
                ?? throw new InvalidOperationException($"Month end header '{documentNo}' was not found.");

            var lines = ItemVariantSalesWorksheetData.GetMonthEndLines(GlobalSettings.ConnectionString, documentNo);

            try
            {
                progress?.Report("Resending Month End to Supabase...");
                await OnlinefunctionsEvents.SyncMonthEndToSupabaseAsync(header, lines).ConfigureAwait(false);
                ItemVariantSalesWorksheetData.UpdateMonthEndHeaderSentToCloud(GlobalSettings.ConnectionString, documentNo, true);
                return (true, string.Empty);
            }
            catch (Exception ex)
            {
                ItemVariantSalesWorksheetData.UpdateMonthEndHeaderSentToCloud(GlobalSettings.ConnectionString, documentNo, false);
                return (false, ex.Message);
            }
        }

        public static async Task<MonthEndLine> ResendMonthEndLineToCloudAsync(string documentNo, int lineNo, IProgress<string>? progress = null)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                throw new ArgumentException("Document No. is required.", nameof(documentNo));

            var lines = ItemVariantSalesWorksheetData.GetMonthEndLines(GlobalSettings.ConnectionString, documentNo);
            var line = lines.FirstOrDefault(l => l.LineNo == lineNo)
                ?? throw new InvalidOperationException($"Month end line {lineNo} was not found for document '{documentNo}'.");

            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            string warehouseId = line.CloudWarehouseId?.Trim() ?? string.Empty;
            string variationId = line.VariationId?.Trim() ?? string.Empty;

            if (!line.PhysicalQtyOnHand.HasValue)
                throw new InvalidOperationException("Physical Qty On Hand is blank for this line; nothing to resend.");
            if (string.IsNullOrWhiteSpace(variationId))
                throw new InvalidOperationException("This line has no variation ID and cannot be resent to the cloud.");
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new InvalidOperationException("This line has no cloud warehouse ID recorded and cannot be resent.");

            decimal? cloudPreviousQty = line.QtyOnHand;
            decimal cloudUpdatedQty = line.PhysicalQtyOnHand.Value;
            string cloudPatchStatus;
            string cloudPatchMessage;
            bool sentToOnline;
            string lastErrorEndpoint = line.LastErrorEndpoint;
            string lastErrorPayload = line.LastErrorPayload;
            string lastErrorMessage = line.LastErrorMessage;
            string productId = line.ProductId?.Trim() ?? string.Empty;

            string note = $"Physical count adjustment resend ({documentNo} / line {lineNo})";
            var adjustmentPreview = BuildMonthEndLineAdjustmentPreview(shopId, warehouseId, variationId, line.QtyOnHand, cloudUpdatedQty, note);

            if (adjustmentPreview == null)
            {
                cloudPatchStatus = "MATCHED";
                cloudPatchMessage = "Qty on Hand matches Physical Qty On Hand. No cloud adjustment needed.";
                sentToOnline = true;
                lastErrorEndpoint = string.Empty;
                lastErrorPayload = string.Empty;
                lastErrorMessage = string.Empty;
            }
            else
            {
                try
                {
                    progress?.Report($"Posting {adjustmentPreview.ActionType.ToLowerInvariant()} adjustment...");
                    await OnlinefunctionsEvents.PostMonthEndAdjustmentAsync(adjustmentPreview, TimeSpan.FromSeconds(30)).ConfigureAwait(false);

                    cloudPatchStatus = "PATCHED";
                    cloudPatchMessage = adjustmentPreview.ActionType == "DEFECT"
                        ? $"Defect adjustment posted. {adjustmentPreview.Quantity:N2} unit(s) written off (Qty on Hand {line.QtyOnHand:N2} > Physical {cloudUpdatedQty:N2})."
                        : $"Purchase adjustment posted. {adjustmentPreview.Quantity:N2} unit(s) added (Physical {cloudUpdatedQty:N2} > Qty on Hand {line.QtyOnHand:N2}).";
                    sentToOnline = true;
                }
                catch (Exception ex)
                {
                    cloudPatchStatus = "FAILED";
                    cloudPatchMessage = ex.Message;
                    sentToOnline = false;
                    lastErrorEndpoint = (ex as OnlinefunctionsEvents.MonthEndAdjustmentRequestException)?.Endpoint ?? string.Empty;
                    lastErrorPayload = (ex as OnlinefunctionsEvents.MonthEndAdjustmentRequestException)?.PayloadJson ?? string.Empty;
                    lastErrorMessage = ex.Message;
                }
            }

            ItemVariantSalesWorksheetData.UpdateMonthEndLineCloudStatus(
                GlobalSettings.ConnectionString,
                documentNo,
                lineNo,
                cloudPreviousQty,
                cloudUpdatedQty,
                cloudPatchStatus,
                cloudPatchMessage,
                sentToOnline,
                lastErrorEndpoint,
                lastErrorPayload,
                lastErrorMessage,
                productId);

            line.CloudPreviousQtyOnHand = cloudPreviousQty;
            line.CloudUpdatedQtyOnHand = cloudUpdatedQty;
            line.CloudPatchStatus = cloudPatchStatus;
            line.CloudPatchMessage = cloudPatchMessage;
            line.SentToOnline = sentToOnline;
            line.LastErrorEndpoint = lastErrorEndpoint;
            line.LastErrorPayload = lastErrorPayload;
            line.LastErrorMessage = lastErrorMessage;
            if (!string.IsNullOrWhiteSpace(productId))
                line.ProductId = productId;

            if (!sentToOnline)
                throw new InvalidOperationException(cloudPatchMessage);

            return line;
        }

        public static Task<OnlinefunctionsEvents.MonthEndAdjustmentRequestPreview> GetMonthEndLineResendPreviewAsync(string documentNo, int lineNo)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                throw new ArgumentException("Document No. is required.", nameof(documentNo));

            var lines = ItemVariantSalesWorksheetData.GetMonthEndLines(GlobalSettings.ConnectionString, documentNo);
            var line = lines.FirstOrDefault(l => l.LineNo == lineNo)
                ?? throw new InvalidOperationException($"Month end line {lineNo} was not found for document '{documentNo}'.");

            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            string warehouseId = line.CloudWarehouseId?.Trim() ?? string.Empty;
            string variationId = line.VariationId?.Trim() ?? string.Empty;

            if (!line.PhysicalQtyOnHand.HasValue)
                throw new InvalidOperationException("Physical Qty On Hand is blank for this line; nothing to resend.");
            if (string.IsNullOrWhiteSpace(variationId))
                throw new InvalidOperationException("This line has no variation ID and cannot be resent to the cloud.");
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new InvalidOperationException("This line has no cloud warehouse ID recorded and cannot be resent.");

            string note = $"Physical count adjustment resend ({documentNo} / line {lineNo})";
            var adjustmentPreview = BuildMonthEndLineAdjustmentPreview(shopId, warehouseId, variationId, line.QtyOnHand, line.PhysicalQtyOnHand.Value, note);

            if (adjustmentPreview == null)
            {
                return Task.FromResult(new OnlinefunctionsEvents.MonthEndAdjustmentRequestPreview
                {
                    VariationId = variationId,
                    WarehouseId = warehouseId,
                    Quantity = 0m,
                    ActionType = "NONE",
                    ErrorMessage = "Qty on Hand matches Physical Qty On Hand. No cloud adjustment is needed for this line."
                });
            }

            return Task.FromResult(adjustmentPreview);
        }

        public static DateTime? GetLastTransferReportSyncUtc()
        {
            return GetTransferReportLastSyncState().LastSyncUtc;
        }

        private static TransferReportSyncState GetTransferReportLastSyncState()
        {
            try
            {
                using var connection = new SqlConnection(GlobalSettings.ConnectionString);
                connection.Open();
                EnsureTransferReportSyncTable(connection);

                using var command = new SqlCommand(@"
SELECT TOP 1 LastSyncUtc, StartDate, EndDate, ReportKeyFilter
FROM dbo.TransferReportSync
ORDER BY Id DESC", connection);
                using var reader = command.ExecuteReader();
                if (!reader.Read())
                    return new TransferReportSyncState();

                return new TransferReportSyncState
                {
                    LastSyncUtc = reader["LastSyncUtc"] == DBNull.Value ? null : Convert.ToDateTime(reader["LastSyncUtc"]).ToUniversalTime(),
                    StartDate = reader["StartDate"] == DBNull.Value ? null : Convert.ToDateTime(reader["StartDate"]),
                    EndDate = reader["EndDate"] == DBNull.Value ? null : Convert.ToDateTime(reader["EndDate"]),
                    ReportKeyFilter = reader["ReportKeyFilter"]?.ToString()?.Trim() ?? string.Empty
                };
            }
            catch
            {
                return new TransferReportSyncState();
            }
        }

        private static void SaveTransferReportLastSyncUtc(DateTime startDate, DateTime endDate, string? reportKeyFilter, DateTime lastSyncUtc)
        {
            using var connection = new SqlConnection(GlobalSettings.ConnectionString);
            connection.Open();
            EnsureTransferReportSyncTable(connection);

            using var command = new SqlCommand(@"
INSERT INTO dbo.TransferReportSync (LastSyncUtc, StartDate, EndDate, ReportKeyFilter)
VALUES (@LastSyncUtc, @StartDate, @EndDate, @ReportKeyFilter)", connection);
            command.Parameters.AddWithValue("@LastSyncUtc", lastSyncUtc);
            command.Parameters.AddWithValue("@StartDate", startDate.Date);
            command.Parameters.AddWithValue("@EndDate", endDate.Date);
            command.Parameters.AddWithValue("@ReportKeyFilter", string.IsNullOrWhiteSpace(reportKeyFilter) ? (object)DBNull.Value : reportKeyFilter.Trim());
            command.ExecuteNonQuery();
        }

        private static void EnsureTransferReportSyncTable(SqlConnection connection)
        {
            using var command = new SqlCommand(@"
IF OBJECT_ID('dbo.TransferReportSync', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.TransferReportSync (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        LastSyncUtc DATETIME2 NOT NULL,
        StartDate DATE NULL,
        EndDate DATE NULL,
        ReportKeyFilter NVARCHAR(200) NULL,
        CreatedAtUtc DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    )
END", connection);
            command.ExecuteNonQuery();
        }

        public static (int SyncedCount, int SkippedCount) SyncLatestTransfersToLocalDb()
        {
            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            TransferOrderData.EnsureTablesExist(GlobalSettings.ConnectionString);

            int syncedCount = 0;
            int skippedCount = 0;
            int page = 1;

            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            while (true)
            {
                string url = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/transfers?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000&page={page}";
                using var response = http.GetAsync(url).GetAwaiter().GetResult();
                var responseText = response.Content.ReadAsStringAsync().GetAwaiter().GetResult() ?? string.Empty;
                if (!response.IsSuccessStatusCode)
                    throw new HttpRequestException($"Transfers GET failed: {(int)response.StatusCode} {response.ReasonPhrase}. Response: {responseText}");

                using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(responseText) ? "[]" : responseText);
                List<JsonElement> transferItems = GetRootCollectionItems(document.RootElement, "transfers", "data", "items");
                if (transferItems.Count == 0)
                    break;

                foreach (var transfer in transferItems)
                {
                    if (transfer.ValueKind != JsonValueKind.Object)
                        continue;

                    if (SyncTransferToLocalTables(GlobalSettings.ConnectionString, transfer))
                        syncedCount++;
                    else
                        skippedCount++;
                }

                if (transferItems.Count < 1000)
                    break;

                page++;
            }

            return (syncedCount, skippedCount);
        }

        public static int SyncTransferRequestsFromSupabaseToLocalDb()
        {
            string headerEndpoint = GlobalSettings.TransferHeaderSupabaseEndpoint?.Trim() ?? string.Empty;
            string lineEndpoint = GlobalSettings.TransferLineSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(headerEndpoint))
                throw new InvalidOperationException("TransferHeaderSupabaseEndpoint is not configured.");
            if (string.IsNullOrWhiteSpace(lineEndpoint))
                throw new InvalidOperationException("TransferLineSupabaseEndpoint is not configured.");

            TransferOrderData.EnsureTablesExist(GlobalSettings.ConnectionString);

            var headerRows = GetSupabaseRows(headerEndpoint);
            var lineRows = GetSupabaseRows(lineEndpoint);
            var linesByDocument = new Dictionary<string, List<JsonElement>>(StringComparer.OrdinalIgnoreCase);

            foreach (var lineRow in lineRows)
            {
                if (lineRow.ValueKind != JsonValueKind.Object)
                    continue;

                string documentNo = GetJsonString(lineRow, "Document No.", "document_no", "documentNo", "No.", "no");
                if (string.IsNullOrWhiteSpace(documentNo))
                    continue;

                documentNo = documentNo.Trim();
                if (!linesByDocument.TryGetValue(documentNo, out var documentLines))
                {
                    documentLines = new List<JsonElement>();
                    linesByDocument.Add(documentNo, documentLines);
                }

                documentLines.Add(lineRow);
            }

            int syncedCount = 0;
            foreach (var headerRow in headerRows)
            {
                if (headerRow.ValueKind != JsonValueKind.Object)
                    continue;

                string status = GetJsonString(headerRow, "Status", "status");
                if (string.IsNullOrWhiteSpace(status))
                    continue;

                string documentNo = GetJsonString(headerRow, "No.", "no", "note", "document_no", "documentNo");
                if (string.IsNullOrWhiteSpace(documentNo))
                    continue;

                documentNo = documentNo.Trim();
                linesByDocument.TryGetValue(documentNo, out var documentLines);
                if (SyncTransferRequestToLocalTables(GlobalSettings.ConnectionString, headerRow, documentLines ?? new List<JsonElement>()))
                    syncedCount++;
            }

            return syncedCount;
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

        private static bool TableExists(SqlConnection connection, string tableName)
        {
            using var command = new SqlCommand(@"SELECT COUNT(*)
                                                FROM INFORMATION_SCHEMA.TABLES
                                                WHERE TABLE_NAME = @tableName", connection);
            command.Parameters.AddWithValue("@tableName", tableName);
            return Convert.ToInt32(command.ExecuteScalar()) > 0;
        }

        private static List<TransferReportAggregate> GetCompletedTransferReportAggregates(DateTime startDate, DateTime endDate, string? reportKeyFilter)
        {
            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString)
                ?? throw new InvalidOperationException("No current warehouse is selected. Open Warehouse Setup and tick Current_Warehouse.");

            string currentWarehouseId = NormalizeComparisonValue(currentWarehouse.Id);
            string currentWarehouseName = NormalizeComparisonValue(currentWarehouse.Name);
            string normalizedReportKeyFilter = NormalizeComparisonValue(reportKeyFilter);
            DateTime start = startDate.Date;
            DateTime end = endDate.Date;
            var aggregates = new Dictionary<string, TransferReportAggregate>(StringComparer.OrdinalIgnoreCase);

            TransferOrderData.EnsureTablesExist(GlobalSettings.ConnectionString);

            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            int page = 1;

            while (true)
            {
                string url = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/transfers?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000&page={page}";
                using var response = http.GetAsync(url).GetAwaiter().GetResult();
                var responseText = response.Content.ReadAsStringAsync().GetAwaiter().GetResult() ?? string.Empty;
                if (!response.IsSuccessStatusCode)
                    throw new HttpRequestException($"Transfers GET failed: {(int)response.StatusCode} {response.ReasonPhrase}. Response: {responseText}");

                using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(responseText) ? "[]" : responseText);
                List<JsonElement> transferItems = GetRootCollectionItems(document.RootElement, "transfers", "data", "items");
                if (transferItems.Count == 0)
                    break;

                foreach (var transfer in transferItems)
                {
                    if (transfer.ValueKind != JsonValueKind.Object)
                        continue;

                    SyncTransferToLocalTables(GlobalSettings.ConnectionString, transfer);

                    DateTime? completedDate = GetJsonDateValue(transfer,
                        "completed_at", "completedAt",
                        "date_completed", "dateCompleted",
                        "receive_date", "receiveDate",
                        "date_of_completion", "dateOfCompletion",
                        "transfer_date", "transferDate",
                        "date");
                    if (!completedDate.HasValue)
                        continue;

                    DateTime reportDate = completedDate.Value.Date;
                    if (reportDate < start || reportDate > end)
                        continue;

                    if (!MatchesCurrentWarehouseDestination(transfer, currentWarehouseId, currentWarehouseName))
                        continue;

                    foreach (var transferLine in GetTransferLineItems(transfer))
                    {
                        if (transferLine.ValueKind != JsonValueKind.Object)
                            continue;

                        string variationId = GetJsonString(transferLine,
                            "variation_id", "variationId",
                            "variant_id", "variantId",
                            "VariationId", "Variant ID");
                        string itemCode = GetJsonString(transferLine,
                            "item_code", "itemCode",
                            "product_display_id", "productDisplayId",
                            "display_id", "displayId",
                            "sku", "code", "item_no", "itemNo", "Item No.");
                        decimal quantity = GetJsonDecimal(transferLine,
                            "quantity", "qty",
                            "completed_quantity", "completedQuantity",
                            "received_quantity", "receivedQuantity",
                            "qty_received", "qtyReceived",
                            "qty_to_receive", "qtyToReceive");
                        if (quantity == 0m)
                            continue;

                        string reportKey = !string.IsNullOrWhiteSpace(variationId)
                            ? "VAR:" + variationId.Trim()
                            : !string.IsNullOrWhiteSpace(itemCode)
                                ? "ITEM:" + itemCode.Trim()
                                : string.Empty;
                        if (string.IsNullOrWhiteSpace(reportKey))
                            continue;

                        if (!string.IsNullOrWhiteSpace(normalizedReportKeyFilter)
                            && !string.Equals(reportKey, normalizedReportKeyFilter, StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }

                        string description = GetJsonString(transferLine,
                            "variant_name", "variantName",
                            "item_name", "itemName",
                            "product_name", "productName",
                            "description", "name");
                        if (string.IsNullOrWhiteSpace(description))
                            description = !string.IsNullOrWhiteSpace(itemCode) ? itemCode.Trim() : variationId.Trim();

                        if (!aggregates.TryGetValue(reportKey, out var aggregate))
                        {
                            aggregate = new TransferReportAggregate
                            {
                                ReportKey = reportKey,
                                ItemCode = !string.IsNullOrWhiteSpace(itemCode) ? itemCode.Trim() : variationId.Trim(),
                                ItemDescription = description.Trim()
                            };
                            aggregates.Add(reportKey, aggregate);
                        }

                        if (string.IsNullOrWhiteSpace(aggregate.ItemCode) && !string.IsNullOrWhiteSpace(itemCode))
                            aggregate.ItemCode = itemCode.Trim();
                        if (string.IsNullOrWhiteSpace(aggregate.ItemDescription) && !string.IsNullOrWhiteSpace(description))
                            aggregate.ItemDescription = description.Trim();

                        aggregate.Quantity += Math.Abs(quantity);
                    }
                }

                if (transferItems.Count < 1000)
                    break;

                page++;
            }

            return aggregates.Values
                .OrderBy(item => string.IsNullOrWhiteSpace(item.ItemDescription) ? item.ItemCode : item.ItemDescription, StringComparer.OrdinalIgnoreCase)
                .ThenBy(item => item.ItemCode, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private static bool SyncTransferToLocalTables(string connectionString, JsonElement transfer)
        {
            string documentNo = GetTransferDocumentNo(transfer);
            if (string.IsNullOrWhiteSpace(documentNo))
                return false;

            string remoteTransferId = GetJsonString(transfer, "id", "transfer_id", "transferId");

            DateTime? requestedDate = GetJsonDateValue(transfer,
                "requested_date", "requestedDate",
                "created_at", "createdAt",
                "inserted_at", "insertedAt");
            DateTime? estimatedDeliveryDate = GetJsonDateValue(transfer,
                "estimated_delivery_date", "estimatedDeliveryDate",
                "eta", "delivery_date", "deliveryDate");
            DateTime? transferDate = GetJsonDateValue(transfer,
                "transfer_date", "transferDate",
                "created_at", "createdAt",
                "inserted_at", "insertedAt");
            DateTime? receiveDate = GetJsonDateValue(transfer,
                "completed_at", "completedAt",
                "date_completed", "dateCompleted",
                "receive_date", "receiveDate",
                "updated_status_at", "updatedStatusAt");
            DateTime? postedDate = GetJsonDateValue(transfer,
                "updated_status_at", "updatedStatusAt",
                "completed_at", "completedAt",
                "date_completed", "dateCompleted");
            DateTime? remoteUpdatedAt = NormalizeSyncTimestamp(GetJsonDateValue(transfer,
                "updated_status_at", "updatedStatusAt",
                "updated_at", "updatedAt",
                "completed_at", "completedAt",
                "date_completed", "dateCompleted",
                "receive_date", "receiveDate"));
            string fromWarehouseId = GetJsonString(transfer,
                "from_warehouse_id", "fromWarehouseId",
                "warehouse_from_id", "warehouseFromId");
            string fromWarehouse = GetJsonString(transfer,
                "from_warehouse_name", "fromWarehouseName",
                "warehouse_from_name", "warehouseFromName",
                "from_warehouse", "fromWarehouse");
            string toWarehouseId = GetJsonString(transfer,
                "to_warehouse_id", "toWarehouseId",
                "warehouse_to_id", "warehouseToId",
                "destination_warehouse_id", "destinationWarehouseId");
            string toWarehouse = GetJsonString(transfer,
                "to_warehouse_name", "toWarehouseName",
                "warehouse_to_name", "warehouseToName",
                "destination_warehouse_name", "destinationWarehouseName",
                "to_warehouse", "toWarehouse");
            string description = GetJsonString(transfer,
                "description", "name");
            if (string.IsNullOrWhiteSpace(description))
            {
                description = !string.IsNullOrWhiteSpace(fromWarehouse) || !string.IsNullOrWhiteSpace(toWarehouse)
                    ? $"{fromWarehouse} to {toWarehouse}".Trim()
                    : documentNo;
            }

            string status = MapTransferApiStatus(transfer, receiveDate);
            string rawTransferJson = transfer.GetRawText();
            var lineItems = GetTransferLineItems(transfer);

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            using (var existingCommand = new SqlCommand("SELECT [Remote Transfer ID], [Remote Updated At] FROM [Transfer Header] WHERE [No.] = @No", connection))
            {
                existingCommand.Parameters.AddWithValue("@No", documentNo);
                using var reader = existingCommand.ExecuteReader();
                if (reader.Read())
                {
                    string existingRemoteTransferId = reader["Remote Transfer ID"] == DBNull.Value ? string.Empty : reader["Remote Transfer ID"].ToString()?.Trim() ?? string.Empty;
                    DateTime? existingRemoteUpdatedAt = reader["Remote Updated At"] == DBNull.Value ? null : NormalizeSyncTimestamp(Convert.ToDateTime(reader["Remote Updated At"]));

                    bool sameRemoteTransferId = string.Equals(existingRemoteTransferId, remoteTransferId?.Trim() ?? string.Empty, StringComparison.OrdinalIgnoreCase);
                    bool sameRemoteUpdatedAt = existingRemoteUpdatedAt == remoteUpdatedAt;
                    if (sameRemoteTransferId && sameRemoteUpdatedAt && !string.IsNullOrWhiteSpace(existingRemoteTransferId))
                        return false;
                }
            }

            using var transaction = connection.BeginTransaction();

            using (var headerCommand = new SqlCommand(@"
IF EXISTS (SELECT 1 FROM [Transfer Header] WHERE [No.] = @No)
BEGIN
    UPDATE [Transfer Header]
    SET [Description] = @Description,
        [Status] = @Status,
        [Requested Date] = @RequestedDate,
        [Estimated Delivery Date] = @EstimatedDeliveryDate,
        [Transfer Date] = @TransferDate,
        [Receive Date] = @ReceiveDate,
        [Posted Date] = @PostedDate,
        [Sent To Online] = 1,
        [Use Production Category] = 0,
        [Category Code] = NULL,
        [From Warehouse ID] = @FromWarehouseId,
        [From Warehouse] = @FromWarehouse,
        [To Warehouse ID] = @ToWarehouseId,
        [To Warehouse] = @ToWarehouse,
        [Remote Transfer ID] = @RemoteTransferId,
        [Remote Updated At] = @RemoteUpdatedAt,
        [Online Transfer Response] = @OnlineTransferResponse
    WHERE [No.] = @No;
END
ELSE
BEGIN
    INSERT INTO [Transfer Header]
    (
        [No.], [Description], [Status], [Requested Date], [Estimated Delivery Date], [Transfer Date], [Receive Date], [Posted Date],
        [Sent To Online], [Use Production Category], [Category Code], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse], [Remote Transfer ID], [Remote Updated At], [Online Transfer Response]
    )
    VALUES
    (
        @No, @Description, @Status, @RequestedDate, @EstimatedDeliveryDate, @TransferDate, @ReceiveDate, @PostedDate,
        1, 0, NULL, @FromWarehouseId, @FromWarehouse, @ToWarehouseId, @ToWarehouse, @RemoteTransferId, @RemoteUpdatedAt, @OnlineTransferResponse
    );
END", connection, transaction))
            {
                headerCommand.Parameters.AddWithValue("@No", documentNo);
                headerCommand.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(description) ? (object)DBNull.Value : description);
                headerCommand.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(status) ? (object)DBNull.Value : status);
                headerCommand.Parameters.AddWithValue("@RequestedDate", (object?)requestedDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@EstimatedDeliveryDate", (object?)estimatedDeliveryDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@TransferDate", (object?)transferDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@ReceiveDate", (object?)receiveDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@PostedDate", (object?)postedDate ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@FromWarehouseId", string.IsNullOrWhiteSpace(fromWarehouseId) ? (object)DBNull.Value : fromWarehouseId);
                headerCommand.Parameters.AddWithValue("@FromWarehouse", string.IsNullOrWhiteSpace(fromWarehouse) ? (object)DBNull.Value : fromWarehouse);
                headerCommand.Parameters.AddWithValue("@ToWarehouseId", string.IsNullOrWhiteSpace(toWarehouseId) ? (object)DBNull.Value : toWarehouseId);
                headerCommand.Parameters.AddWithValue("@ToWarehouse", string.IsNullOrWhiteSpace(toWarehouse) ? (object)DBNull.Value : toWarehouse);
                headerCommand.Parameters.AddWithValue("@RemoteTransferId", string.IsNullOrWhiteSpace(remoteTransferId) ? (object)DBNull.Value : remoteTransferId.Trim());
                headerCommand.Parameters.AddWithValue("@RemoteUpdatedAt", (object?)remoteUpdatedAt ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@OnlineTransferResponse", rawTransferJson);
                headerCommand.ExecuteNonQuery();
            }

            using (var deleteLinesCommand = new SqlCommand("DELETE FROM [Transfer Line] WHERE [Document No.] = @DocumentNo", connection, transaction))
            {
                deleteLinesCommand.Parameters.AddWithValue("@DocumentNo", documentNo);
                deleteLinesCommand.ExecuteNonQuery();
            }

            int lineNo = 1;
            foreach (var lineItem in lineItems)
            {
                if (lineItem.ValueKind != JsonValueKind.Object)
                    continue;

                string itemNo = GetTransferLineItemCode(lineItem);
                string variantId = GetJsonString(lineItem,
                    "variation_id", "variationId",
                    "variant_id", "variantId",
                    "VariationId", "Variant ID");
                string lineDescription = GetJsonString(lineItem,
                    "product_name", "productName",
                    "item_name", "itemName",
                    "description", "name",
                    "note");
                string categoryCode = GetJsonString(lineItem,
                    "category_code", "categoryCode");
                decimal quantity = Math.Abs(GetJsonDecimal(lineItem,
                    "quantity", "qty",
                    "completed_quantity", "completedQuantity",
                    "received_quantity", "receivedQuantity",
                    "qty_received", "qtyReceived",
                    "qty_to_receive", "qtyToReceive"));

                if (string.IsNullOrWhiteSpace(itemNo) && string.IsNullOrWhiteSpace(variantId) && quantity == 0m)
                    continue;

                decimal? qtyToTransfer = quantity == 0m ? null : quantity;
                decimal? qtyToReceive = quantity == 0m ? null : quantity;
                decimal? qtyReceived = string.Equals(status, "Received", StringComparison.OrdinalIgnoreCase) && quantity != 0m
                    ? quantity
                    : null;

                using var lineCommand = new SqlCommand(@"
INSERT INTO [Transfer Line]
(
    [Document No.], [Item No.], [Variant ID], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty To Transfer], [Qty To Receive], [Qty Received]
)
VALUES
(
    @DocumentNo, @ItemNo, @VariantId, @Description, @CategoryCode, @LineNo, @AvailableQty, @QtyToTransfer, @QtyToReceive, @QtyReceived
)", connection, transaction);
                lineCommand.Parameters.AddWithValue("@DocumentNo", documentNo);
                lineCommand.Parameters.AddWithValue("@ItemNo", string.IsNullOrWhiteSpace(itemNo) ? (object)DBNull.Value : itemNo);
                lineCommand.Parameters.AddWithValue("@VariantId", string.IsNullOrWhiteSpace(variantId) ? (object)DBNull.Value : variantId);
                lineCommand.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(lineDescription) ? (object)DBNull.Value : lineDescription);
                lineCommand.Parameters.AddWithValue("@CategoryCode", string.IsNullOrWhiteSpace(categoryCode) ? (object)DBNull.Value : categoryCode);
                lineCommand.Parameters.AddWithValue("@LineNo", lineNo);
                lineCommand.Parameters.AddWithValue("@AvailableQty", DBNull.Value);
                lineCommand.Parameters.AddWithValue("@QtyToTransfer", (object?)qtyToTransfer ?? DBNull.Value);
                lineCommand.Parameters.AddWithValue("@QtyToReceive", (object?)qtyToReceive ?? DBNull.Value);
                lineCommand.Parameters.AddWithValue("@QtyReceived", (object?)qtyReceived ?? DBNull.Value);
                lineCommand.ExecuteNonQuery();
                lineNo++;
            }

            transaction.Commit();
            return true;
        }

        private static bool SyncTransferRequestToLocalTables(string connectionString, JsonElement headerRow, IReadOnlyList<JsonElement> lineItems)
        {
            string documentNo = GetJsonString(headerRow, "No.", "no", "note", "document_no", "documentNo");
            if (string.IsNullOrWhiteSpace(documentNo))
                return false;

            documentNo = documentNo.Trim();
            string description = GetJsonString(headerRow, "Description", "description", "name");
            string status = GetJsonString(headerRow, "Status", "status");
            DateTime? createdDate = GetJsonDateValue(headerRow, "Created Date", "created_date", "createdDate", "Created At", "created_at", "createdAt");
            DateTime? requestedDate = GetJsonDateValue(headerRow, "Requested Date", "requested_date", "requestedDate");
            DateTime? estimatedDeliveryDate = GetJsonDateValue(headerRow, "Estimated Delivery Date", "estimated_delivery_date", "estimatedDeliveryDate");
            DateTime? transferDate = GetJsonDateValue(headerRow, "Transfer Date", "transfer_date", "transferDate");
            DateTime? receiveDate = GetJsonDateValue(headerRow, "Receive Date", "receive_date", "receiveDate");
            DateTime? postedDate = GetJsonDateValue(headerRow, "Posted Date", "posted_date", "postedDate");
            DateTime? remoteUpdatedAt = NormalizeSyncTimestamp(GetJsonDateValue(headerRow, "Remote Updated At", "remote_updated_at", "remoteUpdatedAt", "updated_at", "updatedAt"));
            string fromWarehouseId = GetJsonString(headerRow, "From Warehouse ID", "from_warehouse_id", "fromWarehouseId");
            string fromWarehouse = GetJsonString(headerRow, "From Warehouse", "from_warehouse", "fromWarehouse");
            string toWarehouseId = GetJsonString(headerRow, "To Warehouse ID", "to_warehouse_id", "toWarehouseId");
            string toWarehouse = GetJsonString(headerRow, "To Warehouse", "to_warehouse", "toWarehouse");
            string categoryCode = GetJsonString(headerRow, "Category Code", "category_code", "categoryCode");
            string remoteTransferId = GetJsonString(headerRow, "Remote Transfer ID", "remote_transfer_id", "remoteTransferId", "id");
            bool sentToOnline = GetJsonBooleanValue(headerRow, "Sent To Online", "sent_to_online", "sentToOnline") ?? true;
            bool useProductionCategory = GetJsonBooleanValue(headerRow, "Use Production Category", "use_production_category", "useProductionCategory") ?? false;
            string rawTransferJson = headerRow.GetRawText();

            if (!createdDate.HasValue)
                createdDate = requestedDate?.Date ?? transferDate?.Date;

            using var connection = new SqlConnection(connectionString);
            connection.Open();
            using var transaction = connection.BeginTransaction();

            using (var headerCommand = new SqlCommand(@"
IF EXISTS (SELECT 1 FROM [Transfer Request Header] WHERE [No.] = @No)
BEGIN
    UPDATE [Transfer Request Header]
    SET [Description] = @Description,
        [Created Date] = @CreatedDate,
        [Status] = @Status,
        [Requested Date] = @RequestedDate,
        [Estimated Delivery Date] = @EstimatedDeliveryDate,
        [Transfer Date] = @TransferDate,
        [Receive Date] = @ReceiveDate,
        [Posted Date] = @PostedDate,
        [Sent To Online] = @SentToOnline,
        [Use Production Category] = @UseProductionCategory,
        [Category Code] = @CategoryCode,
        [From Warehouse ID] = @FromWarehouseId,
        [From Warehouse] = @FromWarehouse,
        [To Warehouse ID] = @ToWarehouseId,
        [To Warehouse] = @ToWarehouse,
        [Remote Transfer ID] = @RemoteTransferId,
        [Remote Updated At] = @RemoteUpdatedAt,
        [Online Transfer Response] = @OnlineTransferResponse
    WHERE [No.] = @No;
END
ELSE
BEGIN
    INSERT INTO [Transfer Request Header]
    (
        [No.], [Description], [Created Date], [Status], [Requested Date], [Estimated Delivery Date], [Transfer Date], [Receive Date], [Posted Date],
        [Sent To Online], [Use Production Category], [Category Code], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse], [Remote Transfer ID], [Remote Updated At], [Online Transfer Response]
    )
    VALUES
    (
        @No, @Description, @CreatedDate, @Status, @RequestedDate, @EstimatedDeliveryDate, @TransferDate, @ReceiveDate, @PostedDate,
        @SentToOnline, @UseProductionCategory, @CategoryCode, @FromWarehouseId, @FromWarehouse, @ToWarehouseId, @ToWarehouse, @RemoteTransferId, @RemoteUpdatedAt, @OnlineTransferResponse
    );
END", connection, transaction))
            {
                headerCommand.Parameters.AddWithValue("@No", documentNo);
                headerCommand.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(description) ? (object)DBNull.Value : description);
                headerCommand.Parameters.AddWithValue("@CreatedDate", (object?)createdDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(status) ? (object)DBNull.Value : status);
                headerCommand.Parameters.AddWithValue("@RequestedDate", (object?)requestedDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@EstimatedDeliveryDate", (object?)estimatedDeliveryDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@TransferDate", (object?)transferDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@ReceiveDate", (object?)receiveDate?.Date ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@PostedDate", (object?)postedDate ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@SentToOnline", sentToOnline);
                headerCommand.Parameters.AddWithValue("@UseProductionCategory", useProductionCategory);
                headerCommand.Parameters.AddWithValue("@CategoryCode", string.IsNullOrWhiteSpace(categoryCode) ? (object)DBNull.Value : categoryCode);
                headerCommand.Parameters.AddWithValue("@FromWarehouseId", string.IsNullOrWhiteSpace(fromWarehouseId) ? (object)DBNull.Value : fromWarehouseId);
                headerCommand.Parameters.AddWithValue("@FromWarehouse", string.IsNullOrWhiteSpace(fromWarehouse) ? (object)DBNull.Value : fromWarehouse);
                headerCommand.Parameters.AddWithValue("@ToWarehouseId", string.IsNullOrWhiteSpace(toWarehouseId) ? (object)DBNull.Value : toWarehouseId);
                headerCommand.Parameters.AddWithValue("@ToWarehouse", string.IsNullOrWhiteSpace(toWarehouse) ? (object)DBNull.Value : toWarehouse);
                headerCommand.Parameters.AddWithValue("@RemoteTransferId", string.IsNullOrWhiteSpace(remoteTransferId) ? (object)DBNull.Value : remoteTransferId);
                headerCommand.Parameters.AddWithValue("@RemoteUpdatedAt", (object?)remoteUpdatedAt ?? DBNull.Value);
                headerCommand.Parameters.AddWithValue("@OnlineTransferResponse", rawTransferJson);
                headerCommand.ExecuteNonQuery();
            }

            using (var deleteLinesCommand = new SqlCommand("DELETE FROM [Transfer Request Line] WHERE [Document No.] = @DocumentNo", connection, transaction))
            {
                deleteLinesCommand.Parameters.AddWithValue("@DocumentNo", documentNo);
                deleteLinesCommand.ExecuteNonQuery();
            }

            int nextLineNo = 1;
            foreach (var lineItem in lineItems)
            {
                if (lineItem.ValueKind != JsonValueKind.Object)
                    continue;

                string itemNo = GetJsonString(lineItem, "Item No.", "item_no", "itemNo");
                string variantId = GetJsonString(lineItem, "Variant ID", "variant_id", "variantId", "VariationId", "variation_id");
                string lineDescription = GetJsonString(lineItem, "Description", "description", "name", "product_name", "productName");
                string lineCategoryCode = GetJsonString(lineItem, "CategoryCode", "Category Code", "category_code", "categoryCode");
                decimal? availableQty = GetNullableJsonDecimalValue(lineItem, "Available QTY", "available_qty", "availableQty");
                decimal? qtyToTransfer = GetNullableJsonDecimalValue(lineItem, "Qty To Transfer", "qty_to_transfer", "qtyToTransfer");
                decimal? qtyToReceive = GetNullableJsonDecimalValue(lineItem, "Qty To Receive", "qty_to_receive", "qtyToReceive");
                decimal? qtyReceived = GetNullableJsonDecimalValue(lineItem, "Qty Received", "qty_received", "qtyReceived");

                int lineNo = nextLineNo;
                string rawLineNo = GetJsonString(lineItem, "Line No.", "line_no", "lineNo");
                if (int.TryParse(rawLineNo, NumberStyles.Any, CultureInfo.InvariantCulture, out int parsedLineNo) && parsedLineNo > 0)
                    lineNo = parsedLineNo;

                using var lineCommand = new SqlCommand(@"
INSERT INTO [Transfer Request Line]
(
    [Document No.], [Item No.], [Variant ID], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty To Transfer], [Qty To Receive], [Qty Received]
)
VALUES
(
    @DocumentNo, @ItemNo, @VariantId, @Description, @CategoryCode, @LineNo, @AvailableQty, @QtyToTransfer, @QtyToReceive, @QtyReceived
)", connection, transaction);
                lineCommand.Parameters.AddWithValue("@DocumentNo", documentNo);
                lineCommand.Parameters.AddWithValue("@ItemNo", string.IsNullOrWhiteSpace(itemNo) ? (object)DBNull.Value : itemNo);
                lineCommand.Parameters.AddWithValue("@VariantId", string.IsNullOrWhiteSpace(variantId) ? (object)DBNull.Value : variantId);
                lineCommand.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(lineDescription) ? (object)DBNull.Value : lineDescription);
                lineCommand.Parameters.AddWithValue("@CategoryCode", string.IsNullOrWhiteSpace(lineCategoryCode) ? (object)DBNull.Value : lineCategoryCode);
                lineCommand.Parameters.AddWithValue("@LineNo", lineNo);
                lineCommand.Parameters.AddWithValue("@AvailableQty", (object?)availableQty ?? DBNull.Value);
                lineCommand.Parameters.AddWithValue("@QtyToTransfer", (object?)qtyToTransfer ?? DBNull.Value);
                lineCommand.Parameters.AddWithValue("@QtyToReceive", (object?)qtyToReceive ?? DBNull.Value);
                lineCommand.Parameters.AddWithValue("@QtyReceived", (object?)qtyReceived ?? DBNull.Value);
                lineCommand.ExecuteNonQuery();

                if (lineNo >= nextLineNo)
                    nextLineNo = lineNo + 1;
            }

            transaction.Commit();
            return true;
        }

        private static List<JsonElement> GetSupabaseRows(string endpointUrl)
        {
            const int pageSize = 1000;
            var rows = new List<JsonElement>();
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

            for (int offset = 0; ; offset += pageSize)
            {
                string separator = endpointUrl.Contains("?", StringComparison.Ordinal) ? "&" : "?";
                string url = endpointUrl + separator + "select=*&limit=" + pageSize.ToString(CultureInfo.InvariantCulture) + "&offset=" + offset.ToString(CultureInfo.InvariantCulture);
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.TryAddWithoutValidation("apikey", GlobalSettings.TransferHeaderSupabaseApiKey);
                request.Headers.TryAddWithoutValidation("Authorization", GlobalSettings.TransferHeaderSupabaseAuthorization);

                using var response = http.SendAsync(request).GetAwaiter().GetResult();
                string responseText = response.Content.ReadAsStringAsync().GetAwaiter().GetResult() ?? string.Empty;
                if (!response.IsSuccessStatusCode)
                    throw new HttpRequestException($"Transfer Supabase GET failed for '{endpointUrl}': {(int)response.StatusCode} {response.ReasonPhrase}. Response: {responseText}");

                using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(responseText) ? "[]" : responseText);
                var batch = GetRootCollectionItems(document.RootElement, "data", "items");
                foreach (var item in batch)
                {
                    rows.Add(item.Clone());
                }

                if (batch.Count < pageSize)
                    break;
            }

            return rows;
        }

        private static decimal? GetNullableJsonDecimalValue(JsonElement element, params string[] propertyNames)
        {
            foreach (string raw in GetJsonCandidateValues(element, propertyNames))
            {
                if (string.IsNullOrWhiteSpace(raw))
                    continue;

                if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out decimal value))
                    return value;
                if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.CurrentCulture, out value))
                    return value;
            }

            return null;
        }

        private static bool? GetJsonBooleanValue(JsonElement element, params string[] propertyNames)
        {
            foreach (string raw in GetJsonCandidateValues(element, propertyNames))
            {
                if (string.IsNullOrWhiteSpace(raw))
                    continue;

                if (bool.TryParse(raw, out bool boolValue))
                    return boolValue;
                if (int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out int intValue))
                    return intValue != 0;
            }

            return null;
        }

        private static DateTime? NormalizeSyncTimestamp(DateTime? value)
        {
            if (!value.HasValue)
                return null;

            long ticks = value.Value.Ticks - (value.Value.Ticks % TimeSpan.TicksPerSecond);
            return new DateTime(ticks, value.Value.Kind);
        }

        private static string GetTransferDocumentNo(JsonElement transfer)
        {
            string documentNo = GetJsonString(transfer,
                "note", "no", "document_no", "documentNo", "transfer_no", "transferNo", "custom_id", "customId");
            if (!string.IsNullOrWhiteSpace(documentNo))
                return documentNo.Trim();

            string displayId = GetJsonString(transfer,
                "display_id_original", "displayIdOriginal",
                "display_id", "displayId",
                "id");
            if (string.IsNullOrWhiteSpace(displayId))
                return string.Empty;

            displayId = displayId.Trim();
            return displayId.StartsWith("TO-", StringComparison.OrdinalIgnoreCase)
                ? displayId
                : $"TO-{displayId}";
        }

        private static string GetTransferLineItemCode(JsonElement lineItem)
        {
            string itemCode = GetJsonString(lineItem,
                "item_code", "itemCode",
                "product_display_id", "productDisplayId",
                "display_id", "displayId",
                "sku", "code", "item_no", "itemNo", "Item No.");
            if (!string.IsNullOrWhiteSpace(itemCode))
                return itemCode.Trim();

            if (TryGetPropertyIgnoreCase(lineItem, "variation", out JsonElement variation))
            {
                itemCode = GetJsonString(variation,
                    "display_id", "displayId",
                    "product_display_id", "productDisplayId");
                if (!string.IsNullOrWhiteSpace(itemCode))
                    return itemCode.Trim();

                if (TryGetPropertyIgnoreCase(variation, "product", out JsonElement product))
                {
                    itemCode = GetJsonString(product,
                        "display_id", "displayId",
                        "code");
                    if (!string.IsNullOrWhiteSpace(itemCode))
                        return itemCode.Trim();
                }
            }

            return string.Empty;
        }

        private static string MapTransferApiStatus(JsonElement transfer, DateTime? receiveDate)
        {
            if (receiveDate.HasValue)
                return "Received";

            string rawStatus = GetJsonString(transfer, "status", "transfer_status", "transferStatus");
            if (string.IsNullOrWhiteSpace(rawStatus))
                return "Requested";

            string normalizedStatus = rawStatus.Trim();
            if (int.TryParse(normalizedStatus, NumberStyles.Integer, CultureInfo.InvariantCulture, out int numericStatus))
            {
                return numericStatus switch
                {
                    2 => "Received",
                    1 => "Shipped",
                    _ => "Requested"
                };
            }

            if (string.Equals(normalizedStatus, "completed", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedStatus, "received", StringComparison.OrdinalIgnoreCase))
            {
                return "Received";
            }

            if (string.Equals(normalizedStatus, "shipped", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedStatus, "in-transit", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedStatus, "in_transit", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedStatus, "transferred", StringComparison.OrdinalIgnoreCase))
            {
                return "Shipped";
            }

            if (string.Equals(normalizedStatus, "partially-shipped", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedStatus, "partially_shipped", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedStatus, "partial", StringComparison.OrdinalIgnoreCase))
            {
                return "Partially-Shipped";
            }

            return "Requested";
        }

        private static List<JsonElement> GetTransferLineItems(JsonElement transfer)
        {
            return GetRootCollectionItems(transfer,
                "items", "transfer_lines", "transferLines", "lines", "details", "products");
        }

        private static List<JsonElement> GetRootCollectionItems(JsonElement root, params string[] collectionNames)
        {
            if (root.ValueKind == JsonValueKind.Array)
                return root.EnumerateArray().ToList();

            if (root.ValueKind != JsonValueKind.Object)
                return new List<JsonElement>();

            foreach (string collectionName in collectionNames)
            {
                if (TryGetPropertyIgnoreCase(root, collectionName, out JsonElement collectionValue))
                {
                    if (collectionValue.ValueKind == JsonValueKind.Array)
                        return collectionValue.EnumerateArray().ToList();

                    if (collectionValue.ValueKind == JsonValueKind.Object)
                    {
                        foreach (string nestedCollectionName in collectionNames)
                        {
                            if (TryGetPropertyIgnoreCase(collectionValue, nestedCollectionName, out JsonElement nestedValue)
                                && nestedValue.ValueKind == JsonValueKind.Array)
                            {
                                return nestedValue.EnumerateArray().ToList();
                            }
                        }
                    }
                }
            }

            return new List<JsonElement>();
        }

        private static bool MatchesCurrentWarehouseDestination(JsonElement transfer, string currentWarehouseId, string currentWarehouseName)
        {
            foreach (string candidate in GetJsonCandidateValues(transfer,
                "warehouse_to_id", "warehouseToId",
                "to_warehouse_id", "toWarehouseId",
                "destination_warehouse_id", "destinationWarehouseId",
                "warehouse_to", "warehouseTo",
                "to_warehouse", "toWarehouse",
                "destination_warehouse", "destinationWarehouse"))
            {
                string normalized = NormalizeComparisonValue(candidate);
                if (string.IsNullOrWhiteSpace(normalized))
                    continue;

                if ((!string.IsNullOrWhiteSpace(currentWarehouseId) && string.Equals(normalized, currentWarehouseId, StringComparison.OrdinalIgnoreCase))
                    || (!string.IsNullOrWhiteSpace(currentWarehouseName) && string.Equals(normalized, currentWarehouseName, StringComparison.OrdinalIgnoreCase)))
                {
                    return true;
                }
            }

            return false;
        }

        private static IEnumerable<string> GetJsonCandidateValues(JsonElement element, params string[] propertyNames)
        {
            if (element.ValueKind != JsonValueKind.Object)
                yield break;

            foreach (string propertyName in propertyNames)
            {
                if (!TryGetPropertyIgnoreCase(element, propertyName, out JsonElement value))
                    continue;

                foreach (string candidate in FlattenJsonValue(value))
                {
                    if (!string.IsNullOrWhiteSpace(candidate))
                        yield return candidate;
                }
            }
        }

        private static IEnumerable<string> FlattenJsonValue(JsonElement value)
        {
            switch (value.ValueKind)
            {
                case JsonValueKind.String:
                    yield return value.GetString() ?? string.Empty;
                    yield break;
                case JsonValueKind.Number:
                case JsonValueKind.True:
                case JsonValueKind.False:
                    yield return value.ToString();
                    yield break;
                case JsonValueKind.Object:
                    foreach (string nestedName in new[] { "id", "ID", "name", "Name", "code", "Code", "warehouse_id", "warehouseId" })
                    {
                        if (TryGetPropertyIgnoreCase(value, nestedName, out JsonElement nestedValue))
                        {
                            foreach (string nestedCandidate in FlattenJsonValue(nestedValue))
                                yield return nestedCandidate;
                        }
                    }
                    yield break;
                case JsonValueKind.Array:
                    foreach (JsonElement arrayItem in value.EnumerateArray())
                    {
                        foreach (string arrayCandidate in FlattenJsonValue(arrayItem))
                            yield return arrayCandidate;
                    }
                    yield break;
            }
        }

        private static string GetJsonString(JsonElement element, params string[] propertyNames)
        {
            if (element.ValueKind != JsonValueKind.Object)
                return string.Empty;

            foreach (string propertyName in propertyNames)
            {
                if (!TryGetPropertyIgnoreCase(element, propertyName, out JsonElement value))
                    continue;

                switch (value.ValueKind)
                {
                    case JsonValueKind.String:
                        return value.GetString()?.Trim() ?? string.Empty;
                    case JsonValueKind.Number:
                    case JsonValueKind.True:
                    case JsonValueKind.False:
                        return value.ToString().Trim();
                    case JsonValueKind.Object:
                        foreach (string nestedCandidate in FlattenJsonValue(value))
                        {
                            if (!string.IsNullOrWhiteSpace(nestedCandidate))
                                return nestedCandidate.Trim();
                        }
                        break;
                }
            }

            return string.Empty;
        }

        private static decimal GetJsonDecimal(JsonElement element, params string[] propertyNames)
        {
            foreach (string raw in GetJsonCandidateValues(element, propertyNames))
            {
                if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out decimal value))
                    return value;
                if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.CurrentCulture, out value))
                    return value;
            }

            return 0m;
        }

        private static DateTime? GetJsonDateValue(JsonElement element, params string[] propertyNames)
        {
            foreach (string raw in GetJsonCandidateValues(element, propertyNames))
            {
                if (string.IsNullOrWhiteSpace(raw))
                    continue;

                if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out DateTimeOffset dtoRoundtrip))
                    return dtoRoundtrip.LocalDateTime;
                if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out DateTimeOffset dtoUtc))
                    return dtoUtc.LocalDateTime;
                if (DateTime.TryParseExact(raw, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTime exactDate))
                    return exactDate.Date;
                if (DateTime.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTime parsedDate))
                    return parsedDate;
                if (DateTime.TryParse(raw, out parsedDate))
                    return parsedDate;
            }

            return null;
        }

        private static bool TryGetPropertyIgnoreCase(JsonElement element, string propertyName, out JsonElement value)
        {
            if (element.ValueKind == JsonValueKind.Object)
            {
                foreach (JsonProperty property in element.EnumerateObject())
                {
                    if (string.Equals(property.Name, propertyName, StringComparison.OrdinalIgnoreCase))
                    {
                        value = property.Value;
                        return true;
                    }
                }
            }

            value = default;
            return false;
        }

        private static string NormalizeComparisonValue(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return string.Empty;

            return string.Join(" ", value.Trim().Split(new[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries));
        }

        /// <summary>
        /// Ensures every "VAR:" report key on a worksheet line resolves to a real GUID variant ID
        /// recorded in the cloud-synced dbo.[Variant] table (the local cache of variant data pulled
        /// from the online store). If a line's recorded variation ID isn't a valid GUID present in
        /// dbo.[Variant], this tries to resolve the correct cloud variation ID by item code; if none
        /// can be found, the line is demoted to an "ITEM:" (non-variant) report key so it is treated
        /// as having no cloud variant instead of sending an incorrect ID to the cloud.
        /// </summary>
        private static List<ItemVariantSalesReportLine> ResolveCloudVariationIds(string connectionString, List<ItemVariantSalesReportLine> lines)
        {
            if (lines.Count == 0)
                return lines;

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            if (!TableExists(connection, "Variant"))
                return lines;

            var cloudVariationIdByItemCode = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var validCloudVariationIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            using (var command = new SqlCommand("SELECT ItemCode, VariationId FROM dbo.[Variant] WHERE ISNULL(VariationId, '') <> ''", connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    string itemCode = reader["ItemCode"]?.ToString()?.Trim() ?? string.Empty;
                    string variationId = reader["VariationId"]?.ToString()?.Trim() ?? string.Empty;

                    if (string.IsNullOrWhiteSpace(variationId) || !Guid.TryParse(variationId, out _))
                        continue;

                    validCloudVariationIds.Add(variationId);

                    if (!string.IsNullOrWhiteSpace(itemCode) && !cloudVariationIdByItemCode.ContainsKey(itemCode))
                        cloudVariationIdByItemCode[itemCode] = variationId;
                }
            }

            var resolvedLines = new List<ItemVariantSalesReportLine>(lines.Count);
            foreach (var line in lines)
            {
                string reportKey = line.ReportKey;

                if (reportKey.StartsWith("VAR:", StringComparison.OrdinalIgnoreCase))
                {
                    string existingVariationId = reportKey.Substring(4).Trim();

                    if (!(Guid.TryParse(existingVariationId, out _) && validCloudVariationIds.Contains(existingVariationId)))
                    {
                        string itemCode = line.ItemCode?.Trim() ?? string.Empty;
                        reportKey = cloudVariationIdByItemCode.TryGetValue(itemCode, out var resolvedVariationId)
                            ? "VAR:" + resolvedVariationId
                            : (!string.IsNullOrWhiteSpace(itemCode) ? "ITEM:" + itemCode : reportKey);
                    }
                }

                resolvedLines.Add(reportKey == line.ReportKey
                    ? line
                    : new ItemVariantSalesReportLine
                    {
                        ReportKey = reportKey,
                        ItemCode = line.ItemCode,
                        ItemDescription = line.ItemDescription,
                        TransferredQuantity = line.TransferredQuantity,
                        LocalOrderQuantity = line.LocalOrderQuantity,
                        OnlineOrderQuantity = line.OnlineOrderQuantity
                    });
            }

            return resolvedLines;
        }

        private static Dictionary<string, string> GetProductIdsByReportKey(string connectionString, IEnumerable<(string ReportKey, string ItemCode)> lines)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var lineList = lines.Where(l => !string.IsNullOrWhiteSpace(l.ReportKey)).ToList();
            if (lineList.Count == 0)
                return result;

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            if (!TableExists(connection, "Items") || !TableHasColumn(connection, "Items", "ProductId"))
                return result;

            bool hasVariationIdColumn = TableHasColumn(connection, "Items", "VariationId");

            var productIdByVariationId = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var productIdByItemCode = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            string selectSql = hasVariationIdColumn
                ? "SELECT Code, VariationId, ProductId FROM dbo.Items WHERE ProductId IS NOT NULL AND ProductId <> ''"
                : "SELECT Code, ProductId FROM dbo.Items WHERE ProductId IS NOT NULL AND ProductId <> ''";

            using (var command = new SqlCommand(selectSql, connection))
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    string productId = reader["ProductId"]?.ToString()?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(productId))
                        continue;

                    string code = reader["Code"]?.ToString()?.Trim() ?? string.Empty;
                    if (!string.IsNullOrWhiteSpace(code) && !productIdByItemCode.ContainsKey(code))
                        productIdByItemCode[code] = productId;

                    if (hasVariationIdColumn)
                    {
                        string variationId = reader["VariationId"]?.ToString()?.Trim() ?? string.Empty;
                        if (!string.IsNullOrWhiteSpace(variationId) && !productIdByVariationId.ContainsKey(variationId))
                            productIdByVariationId[variationId] = productId;
                    }
                }
            }

            foreach (var (reportKey, itemCode) in lineList)
            {
                string variationId = reportKey.StartsWith("VAR:", StringComparison.OrdinalIgnoreCase)
                    ? reportKey.Substring(4).Trim()
                    : string.Empty;

                if (!string.IsNullOrWhiteSpace(variationId) && productIdByVariationId.TryGetValue(variationId, out var productIdByVar))
                {
                    result[reportKey] = productIdByVar;
                }
                else if (!string.IsNullOrWhiteSpace(itemCode) && productIdByItemCode.TryGetValue(itemCode.Trim(), out var productIdByCode))
                {
                    result[reportKey] = productIdByCode;
                }
            }

            return result;
        }

        private static ItemVariantSalesReportBuildResult GenerateItemVariantSalesReportLines(string connectionString, DateTime startDate, DateTime endDate, string? reportKeyFilter)
        {
            var lineMap = new Dictionary<string, ItemVariantSalesReportLine>(StringComparer.OrdinalIgnoreCase);
            var transferAggregates = GetCompletedTransferLocalAggregates(connectionString, startDate, endDate, reportKeyFilter);
            string normalizedReportKeyFilter = NormalizeComparisonValue(reportKeyFilter);
            int matchedTransferLineCount = 0;

            foreach (var transferAggregate in transferAggregates)
            {
                if (string.IsNullOrWhiteSpace(transferAggregate.ReportKey))
                    continue;

                matchedTransferLineCount += transferAggregate.SourceLineCount;

                lineMap[transferAggregate.ReportKey] = new ItemVariantSalesReportLine
                {
                    ReportKey = transferAggregate.ReportKey,
                    ItemCode = transferAggregate.ItemCode,
                    ItemDescription = transferAggregate.ItemDescription,
                    TransferredQuantity = transferAggregate.Quantity,
                    LocalOrderQuantity = 0m,
                    OnlineOrderQuantity = 0m
                };
            }

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            bool hasOnlineOrderHeader = TableExists(connection, "OnlineOrderHeader");
            bool hasOnlineOrderLines = TableExists(connection, "OnlineOrderLines");
            bool hasOnlineCompletionDate = hasOnlineOrderHeader && TableHasColumn(connection, "OnlineOrderHeader", "Date of Completion");
            bool hasVariantTable = TableExists(connection, "Variant");
            bool hasOnlineCustomers = TableExists(connection, "OnlineCustomers");
            bool hasOnlineCustomerExcludeOnInventoryReport = hasOnlineCustomers && TableHasColumn(connection, "OnlineCustomers", "ExcludeOnInventoryReport");
            DateTime endExclusive = endDate.Date.AddDays(1);

            string onlineCustomerExclusionFilter = hasOnlineCustomerExcludeOnInventoryReport
                ? @"
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.OnlineCustomers oc
          WHERE ISNULL(oc.ExcludeOnInventoryReport, 0) = 1
            AND LTRIM(RTRIM(UPPER(ISNULL(oc.Name, '')))) <> ''
            AND LTRIM(RTRIM(UPPER(ISNULL(oc.Name, '')))) = LTRIM(RTRIM(UPPER(ISNULL(ooh.CustomerName, ''))))
      )"
                : string.Empty;

            string onlineDateExpression = hasOnlineCompletionDate
                ? "COALESCE(ooh.[Date of Completion], ooh.[Date])"
                : "ooh.[Date]";

            string localReportKeyExpression = @"CASE
            WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(ile.VariationId, '')))
            ELSE 'ITEM:' + LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))
        END";

            string onlineReportKeyExpression = @"CASE
            WHEN LTRIM(RTRIM(ISNULL(ol.VariationId, ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(ol.VariationId, '')))
            ELSE 'ITEM:' + LTRIM(RTRIM(COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''), '')))
        END";

            string localVariantJoin = hasVariantTable
                ? @"
    LEFT JOIN dbo.[Variant] v ON v.VariationId = ile.VariationId
    LEFT JOIN Items variantItem ON variantItem.Code = ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)
    LEFT JOIN Items mainItem ON mainItem.Code = v.MainItemCode"
                : string.Empty;

            string localCategoryJoin = hasVariantTable
                ? @"
    LEFT JOIN Category localCategory ON localCategory.Code = COALESCE(NULLIF(v.CategoryCode, ''), NULLIF(variantItem.CategoryCode, ''), NULLIF(mainItem.CategoryCode, ''), NULLIF(i.CategoryCode, ''))"
                : @"
    LEFT JOIN Category localCategory ON localCategory.Code = i.CategoryCode";

            string localVariantDescription = hasVariantTable
                ? "CASE WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN COALESCE(NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(mainItem.[Description], ''), NULLIF(mainItem.[Name], ''), NULLIF(variantItem.[Description], ''), NULLIF(variantItem.[Name], ''), NULLIF(i.[Description], ''), NULLIF(i.[Name], ''), ''))), '') + CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(v.VariantName, ''))), '') IS NOT NULL THEN ' - ' + LTRIM(RTRIM(ISNULL(v.VariantName, ''))) ELSE '' END, NULLIF(LTRIM(RTRIM(ISNULL(v.VariantName, ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(ile.Description, ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(i.Description, ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(i.[Name], ''))), ''), LTRIM(RTRIM(ISNULL(ile.VariationId, '')))) ELSE COALESCE(NULLIF(ile.Description, ''), NULLIF(i.Description, ''), NULLIF(i.[Name], ''), LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))) END"
                : "COALESCE(NULLIF(ile.Description, ''), NULLIF(i.Description, ''), NULLIF(i.[Name], ''), CASE WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) ELSE LTRIM(RTRIM(ISNULL(ile.ItemCode, ''))) END)";

            string localDisplayItemCode = hasVariantTable
                ? "LTRIM(RTRIM(COALESCE(NULLIF(v.ItemCode, ''), NULLIF(v.MainItemCode, ''), ISNULL(ile.ItemCode, ''))))"
                : "LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))";

            string onlineVariantJoin = hasVariantTable
                ? @"
    LEFT JOIN dbo.[Variant] v ON v.VariationId = ol.VariationId
    LEFT JOIN Items variantItem ON variantItem.Code = ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)
    LEFT JOIN Items mainItem ON mainItem.Code = v.MainItemCode"
                : string.Empty;

            string onlineCategoryJoin = hasVariantTable
                ? @"
    LEFT JOIN Category onlineCategory ON onlineCategory.Code = COALESCE(NULLIF(v.CategoryCode, ''), NULLIF(variantItem.CategoryCode, ''), NULLIF(mainItem.CategoryCode, ''), NULLIF(i.CategoryCode, ''))"
                : @"
    LEFT JOIN Category onlineCategory ON onlineCategory.Code = i.CategoryCode";

            string onlineVariantDescription = hasVariantTable
                ? "CASE WHEN LTRIM(RTRIM(ISNULL(ol.VariationId, ''))) <> '' THEN COALESCE(NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(mainItem.[Description], ''), NULLIF(mainItem.[Name], ''), NULLIF(variantItem.[Description], ''), NULLIF(variantItem.[Name], ''), NULLIF(i.[Description], ''), NULLIF(i.[Name], ''), ''))), '') + CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(v.VariantName, ''))), '') IS NOT NULL THEN ' - ' + LTRIM(RTRIM(ISNULL(v.VariantName, ''))) ELSE '' END, NULLIF(LTRIM(RTRIM(ISNULL(v.VariantName, ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(ol.Description, ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(i.Description, ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(i.[Name], ''))), ''), LTRIM(RTRIM(ISNULL(ol.VariationId, '')))) ELSE COALESCE(NULLIF(ol.Description, ''), NULLIF(i.Description, ''), NULLIF(i.[Name], ''), LTRIM(RTRIM(COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''), '')))) END"
                : "COALESCE(NULLIF(ol.Description, ''), NULLIF(i.Description, ''), NULLIF(i.[Name], ''), CASE WHEN LTRIM(RTRIM(ISNULL(ol.VariationId, ''))) <> '' THEN LTRIM(RTRIM(ISNULL(ol.VariationId, ''))) ELSE LTRIM(RTRIM(COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''), ''))) END)";

            string onlineDisplayItemCode = hasVariantTable
                ? "LTRIM(RTRIM(COALESCE(NULLIF(v.ItemCode, ''), NULLIF(v.MainItemCode, ''), COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''), ''))))"
                : "LTRIM(RTRIM(COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''), '')))";

            string query = hasOnlineOrderHeader && hasOnlineOrderLines
                ? $@"
WITH LocalSales AS (
    SELECT
        CASE
            WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(ile.VariationId, '')))
            ELSE 'ITEM:' + LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))
        END AS ReportKey,
        {localDisplayItemCode} AS ItemCode,
        {localVariantDescription} AS ItemDescription,
        SUM(ABS(CAST(ISNULL(ile.Quantity, 0) AS DECIMAL(18, 2)))) AS LocalOrderQuantity
    FROM ItemLedgerEntry ile
    LEFT JOIN Items i ON i.Code = ile.ItemCode
    {localVariantJoin}
        {localCategoryJoin}
    WHERE UPPER(ISNULL(ile.DocumentType, '')) = 'SALES'
      AND ile.EntryDate >= @startDate
      AND ile.EntryDate < @endExclusive
      AND ISNULL(ile.Quantity, 0) <> 0
            AND ISNULL(localCategory.ExcludeOnInventoryReport, 0) = 0
            AND LTRIM(RTRIM(ISNULL(ile.ItemCode, ''))) <> ''
            AND (@reportKeyFilter = '' OR {localReportKeyExpression} = @reportKeyFilter)
    GROUP BY
        CASE
            WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(ile.VariationId, '')))
            ELSE 'ITEM:' + LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))
        END,
        {localDisplayItemCode},
        {localVariantDescription}
),
OnlineSales AS (
    SELECT
        CASE
            WHEN LTRIM(RTRIM(ISNULL(ol.VariationId, ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(ol.VariationId, '')))
            ELSE 'ITEM:' + LTRIM(RTRIM(COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''), '')))
        END AS ReportKey,
        {onlineDisplayItemCode} AS ItemCode,
        {onlineVariantDescription} AS ItemDescription,
        SUM(ABS(CAST(ISNULL(ol.Quantity, 0) AS DECIMAL(18, 2)))) AS OnlineOrderQuantity
    FROM dbo.OnlineOrderLines ol
    INNER JOIN dbo.OnlineOrderHeader ooh ON CONVERT(NVARCHAR(100), ooh.OrderID) = CONVERT(NVARCHAR(100), ol.OrderID)
    LEFT JOIN Items i ON i.Code = COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''))
    {onlineVariantJoin}
        {onlineCategoryJoin}
    WHERE {onlineDateExpression} >= @startDate
      AND {onlineDateExpression} < @endExclusive
      AND ISNULL(ol.Quantity, 0) <> 0
            AND ISNULL(onlineCategory.ExcludeOnInventoryReport, 0) = 0
      AND LTRIM(RTRIM(COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''), ''))) <> ''
        AND (@reportKeyFilter = '' OR {onlineReportKeyExpression} = @reportKeyFilter)
      AND UPPER(ISNULL(ooh.Status, '')) NOT IN ('CANCELED', 'CANCELLED')
            {onlineCustomerExclusionFilter}
    GROUP BY
        CASE
            WHEN LTRIM(RTRIM(ISNULL(ol.VariationId, ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(ol.VariationId, '')))
            ELSE 'ITEM:' + LTRIM(RTRIM(COALESCE(NULLIF(ol.ItemCode, ''), NULLIF(ol.product_display_id, ''), '')))
        END,
        {onlineDisplayItemCode},
        {onlineVariantDescription}
)
SELECT
    COALESCE(ls.ReportKey, os.ReportKey) AS ReportKey,
    COALESCE(ls.ItemCode, os.ItemCode) AS ItemCode,
    COALESCE(NULLIF(ls.ItemDescription, ''), NULLIF(os.ItemDescription, ''), COALESCE(ls.ItemCode, os.ItemCode)) AS ItemDescription,
    ISNULL(ls.LocalOrderQuantity, 0) AS LocalOrderQuantity,
    ISNULL(os.OnlineOrderQuantity, 0) AS OnlineOrderQuantity
FROM LocalSales ls
FULL OUTER JOIN OnlineSales os ON os.ReportKey = ls.ReportKey
ORDER BY COALESCE(NULLIF(ls.ItemDescription, ''), NULLIF(os.ItemDescription, ''), COALESCE(ls.ItemCode, os.ItemCode)), COALESCE(ls.ItemCode, os.ItemCode)"
                : @"
SELECT
    CASE
        WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN LTRIM(RTRIM(ISNULL(ile.VariationId, '')))
        ELSE LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))
    END AS ReportKey,
    CASE
        WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN LTRIM(RTRIM(ISNULL(ile.VariationId, '')))
        ELSE LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))
    END AS ItemCode,
    MAX(NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(ile.Description, ''), NULLIF(i.Description, ''), ''))), '')) AS ItemDescription,
    SUM(ABS(CAST(ISNULL(ile.Quantity, 0) AS DECIMAL(18, 2)))) AS LocalOrderQuantity,
    CAST(0 AS DECIMAL(18, 2)) AS OnlineOrderQuantity
FROM ItemLedgerEntry ile
LEFT JOIN Items i ON i.Code = ile.ItemCode
LEFT JOIN Category localCategory ON localCategory.Code = i.CategoryCode
WHERE UPPER(ISNULL(ile.DocumentType, '')) = 'SALES'
  AND ile.EntryDate >= @startDate
  AND ile.EntryDate < @endExclusive
  AND ISNULL(ile.Quantity, 0) <> 0
    AND ISNULL(localCategory.ExcludeOnInventoryReport, 0) = 0
  AND LTRIM(RTRIM(ISNULL(ile.ItemCode, ''))) <> ''
    AND (@reportKeyFilter = '' OR CASE
                WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(ile.VariationId, '')))
                ELSE 'ITEM:' + LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))
        END = @reportKeyFilter)
GROUP BY CASE
        WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN LTRIM(RTRIM(ISNULL(ile.VariationId, '')))
        ELSE LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))
    END
ORDER BY MAX(NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(ile.Description, ''), NULLIF(i.Description, ''), ''))), '')), CASE
        WHEN LTRIM(RTRIM(ISNULL(ile.VariationId, ''))) <> '' THEN LTRIM(RTRIM(ISNULL(ile.VariationId, '')))
        ELSE LTRIM(RTRIM(ISNULL(ile.ItemCode, '')))
    END";

            using (var command = new SqlCommand(query, connection))
            {
                command.Parameters.AddWithValue("@startDate", startDate.Date);
                command.Parameters.AddWithValue("@endExclusive", endExclusive);
                command.Parameters.AddWithValue("@reportKeyFilter", normalizedReportKeyFilter);

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                decimal localQty = reader["LocalOrderQuantity"] != DBNull.Value ? Convert.ToDecimal(reader["LocalOrderQuantity"]) : 0m;
                decimal onlineQty = reader["OnlineOrderQuantity"] != DBNull.Value ? Convert.ToDecimal(reader["OnlineOrderQuantity"]) : 0m;

                if (localQty == 0m && onlineQty == 0m)
                {
                    continue;
                }

                string itemCode = reader["ItemCode"]?.ToString()?.Trim() ?? string.Empty;
                string itemDescription = reader["ItemDescription"]?.ToString()?.Trim() ?? string.Empty;
                string reportKey = reader["ReportKey"]?.ToString()?.Trim() ?? string.Empty;

                if (string.IsNullOrWhiteSpace(itemDescription))
                {
                    itemDescription = itemCode;
                }

                if (!string.IsNullOrWhiteSpace(reportKey)
                    && reportKey.IndexOf("VAR:", StringComparison.OrdinalIgnoreCase) != 0
                    && reportKey.IndexOf("ITEM:", StringComparison.OrdinalIgnoreCase) != 0)
                {
                    reportKey = itemCode.IndexOf(reportKey, StringComparison.OrdinalIgnoreCase) >= 0 && lineMap.ContainsKey("VAR:" + reportKey)
                        ? "VAR:" + reportKey
                        : "ITEM:" + reportKey;
                }

                if (string.IsNullOrWhiteSpace(reportKey))
                    reportKey = !string.IsNullOrWhiteSpace(itemCode) ? "ITEM:" + itemCode : itemDescription;

                if (lineMap.TryGetValue(reportKey, out var existingLine))
                {
                    lineMap[reportKey] = new ItemVariantSalesReportLine
                    {
                        ReportKey = reportKey,
                        ItemCode = string.IsNullOrWhiteSpace(existingLine.ItemCode) ? itemCode : existingLine.ItemCode,
                        ItemDescription = string.IsNullOrWhiteSpace(existingLine.ItemDescription) ? itemDescription : existingLine.ItemDescription,
                        TransferredQuantity = existingLine.TransferredQuantity,
                        LocalOrderQuantity = localQty,
                        OnlineOrderQuantity = onlineQty
                    };
                }
                else
                {
                    lineMap[reportKey] = new ItemVariantSalesReportLine
                    {
                        ReportKey = reportKey,
                        ItemCode = itemCode,
                        ItemDescription = itemDescription,
                        TransferredQuantity = 0m,
                        LocalOrderQuantity = localQty,
                        OnlineOrderQuantity = onlineQty
                    };
                }
            }
            }

            // Include items/variants that have no transfer or sales activity at all, so the
            // worksheet shows the complete item/variant list rather than only lines with data.
            if (hasVariantTable)
            {
                const string masterVariantQuery = @"
SELECT
    'VAR:' + v.VariationId AS ReportKey,
    LTRIM(RTRIM(COALESCE(NULLIF(v.ItemCode, ''), NULLIF(v.MainItemCode, ''), ''))) AS ItemCode,
    COALESCE(NULLIF(v.VariantName, ''), NULLIF(variantItem.[Description], ''), NULLIF(variantItem.[Name], ''), NULLIF(mainItem.[Description], ''), NULLIF(mainItem.[Name], ''), v.VariationId) AS ItemDescription
FROM dbo.[Variant] v
LEFT JOIN Items variantItem ON variantItem.Code = ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)
LEFT JOIN Items mainItem ON mainItem.Code = v.MainItemCode
LEFT JOIN Category cat ON cat.Code = COALESCE(NULLIF(v.CategoryCode, ''), NULLIF(variantItem.CategoryCode, ''), NULLIF(mainItem.CategoryCode, ''))
WHERE ISNULL(NULLIF(v.VariationId, ''), '') <> ''
  AND ISNULL(variantItem.IsActive, ISNULL(mainItem.IsActive, 1)) = 1
  AND ISNULL(cat.ExcludeOnInventoryReport, 0) = 0
  AND (@reportKeyFilter = '' OR 'VAR:' + v.VariationId = @reportKeyFilter)";

                using var masterVariantCommand = new SqlCommand(masterVariantQuery, connection);
                masterVariantCommand.Parameters.AddWithValue("@reportKeyFilter", normalizedReportKeyFilter);
                using var masterVariantReader = masterVariantCommand.ExecuteReader();
                while (masterVariantReader.Read())
                {
                    string reportKey = masterVariantReader["ReportKey"]?.ToString()?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(reportKey) || lineMap.ContainsKey(reportKey))
                        continue;

                    string itemCode = masterVariantReader["ItemCode"]?.ToString()?.Trim() ?? string.Empty;
                    string itemDescription = masterVariantReader["ItemDescription"]?.ToString()?.Trim() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(itemDescription))
                        itemDescription = itemCode;

                    lineMap[reportKey] = new ItemVariantSalesReportLine
                    {
                        ReportKey = reportKey,
                        ItemCode = itemCode,
                        ItemDescription = itemDescription,
                        TransferredQuantity = 0m,
                        LocalOrderQuantity = 0m,
                        OnlineOrderQuantity = 0m
                    };
                }
            }

            const string masterItemQuery = @"
SELECT
    'ITEM:' + i.Code AS ReportKey,
    i.Code AS ItemCode,
    COALESCE(NULLIF(i.[Description], ''), NULLIF(i.[Name], ''), i.Code) AS ItemDescription
FROM Items i
LEFT JOIN Category cat ON cat.Code = i.CategoryCode
WHERE ISNULL(i.IsActive, 1) = 1
  AND ISNULL(cat.ExcludeOnInventoryReport, 0) = 0
  AND (@reportKeyFilter = '' OR 'ITEM:' + i.Code = @reportKeyFilter)";

            using var masterItemCommand = new SqlCommand(masterItemQuery, connection);
            masterItemCommand.Parameters.AddWithValue("@reportKeyFilter", normalizedReportKeyFilter);
            using var masterItemReader = masterItemCommand.ExecuteReader();
            while (masterItemReader.Read())
            {
                string reportKey = masterItemReader["ReportKey"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(reportKey) || lineMap.ContainsKey(reportKey))
                    continue;

                string itemCode = masterItemReader["ItemCode"]?.ToString()?.Trim() ?? string.Empty;
                string itemDescription = masterItemReader["ItemDescription"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(itemDescription))
                    itemDescription = itemCode;

                lineMap[reportKey] = new ItemVariantSalesReportLine
                {
                    ReportKey = reportKey,
                    ItemCode = itemCode,
                    ItemDescription = itemDescription,
                    TransferredQuantity = 0m,
                    LocalOrderQuantity = 0m,
                    OnlineOrderQuantity = 0m
                };
            }

            return new ItemVariantSalesReportBuildResult
            {
                Lines = lineMap.Values
                    .OrderBy(line => string.IsNullOrWhiteSpace(line.ItemDescription) ? line.ItemCode : line.ItemDescription, StringComparer.OrdinalIgnoreCase)
                    .ThenBy(line => line.ItemCode, StringComparer.OrdinalIgnoreCase)
                    .ToList(),
                MatchedTransferLineCount = matchedTransferLineCount,
                MatchedTransferAggregateCount = transferAggregates.Count
            };
        }

        private static List<TransferReportAggregate> GetCompletedTransferLocalAggregates(string connectionString, DateTime startDate, DateTime endDate, string? reportKeyFilter)
        {
            TransferOrderData.EnsureTablesExist(connectionString);

            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(connectionString)
                ?? throw new InvalidOperationException("No current warehouse is selected. Open Warehouse Setup and tick Current_Warehouse.");

            string currentWarehouseId = NormalizeComparisonValue(currentWarehouse.Id);
            string currentWarehouseName = NormalizeComparisonValue(currentWarehouse.Name);
            string normalizedReportKeyFilter = NormalizeComparisonValue(reportKeyFilter);
            DateTime endExclusive = endDate.Date.AddDays(1);
            var aggregates = new List<TransferReportAggregate>();

            using var connection = new SqlConnection(connectionString);
            connection.Open();

            bool hasVariantTable = TableExists(connection, "Variant");

            string variantJoin = hasVariantTable
                ? @"
    LEFT JOIN dbo.[Variant] v ON v.VariationId = tl.[Variant ID]
    LEFT JOIN Items variantItem ON variantItem.Code = ISNULL(NULLIF(v.ItemCode, ''), v.MainItemCode)
    LEFT JOIN Items mainItem ON mainItem.Code = v.MainItemCode
    LEFT JOIN Items item ON item.Code = tl.[Item No.]
    LEFT JOIN Category transferCategory ON transferCategory.Code = COALESCE(NULLIF(v.CategoryCode, ''), NULLIF(variantItem.CategoryCode, ''), NULLIF(mainItem.CategoryCode, ''), NULLIF(item.CategoryCode, ''))"
                : @"
    LEFT JOIN Items item ON item.Code = tl.[Item No.]
    LEFT JOIN Category transferCategory ON transferCategory.Code = item.CategoryCode";

            string itemCodeExpression = hasVariantTable
                ? "LTRIM(RTRIM(COALESCE(NULLIF(v.ItemCode, ''), NULLIF(v.MainItemCode, ''), ISNULL(tl.[Item No.], ''))))"
                : "LTRIM(RTRIM(ISNULL(tl.[Item No.], '')))";

            string descriptionExpression = hasVariantTable
                ? "CASE WHEN LTRIM(RTRIM(ISNULL(tl.[Variant ID], ''))) <> '' THEN COALESCE(NULLIF(LTRIM(RTRIM(COALESCE(NULLIF(mainItem.[Description], ''), NULLIF(mainItem.[Name], ''), NULLIF(variantItem.[Description], ''), NULLIF(variantItem.[Name], ''), NULLIF(tl.[Description], ''), ''))), '') + CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(v.VariantName, ''))), '') IS NOT NULL THEN ' - ' + LTRIM(RTRIM(ISNULL(v.VariantName, ''))) ELSE '' END, NULLIF(LTRIM(RTRIM(ISNULL(v.VariantName, ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(tl.[Description], ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(item.[Description], ''))), ''), NULLIF(LTRIM(RTRIM(ISNULL(item.[Name], ''))), ''), LTRIM(RTRIM(ISNULL(tl.[Variant ID], '')))) ELSE COALESCE(NULLIF(tl.[Description], ''), NULLIF(item.[Description], ''), NULLIF(item.[Name], ''), LTRIM(RTRIM(ISNULL(tl.[Item No.], '')))) END"
                : "COALESCE(NULLIF(tl.[Description], ''), NULLIF(item.[Description], ''), NULLIF(item.[Name], ''), CASE WHEN LTRIM(RTRIM(ISNULL(tl.[Variant ID], ''))) <> '' THEN LTRIM(RTRIM(ISNULL(tl.[Variant ID], ''))) ELSE LTRIM(RTRIM(ISNULL(tl.[Item No.], ''))) END)";

            string quantityExpression = "ABS(COALESCE(NULLIF(tl.[Qty Received], 0), NULLIF(tl.[Qty To Receive], 0), NULLIF(tl.[Qty To Transfer], 0), 0))";

            string query = $@"
SELECT
    CASE
        WHEN LTRIM(RTRIM(ISNULL(tl.[Variant ID], ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(tl.[Variant ID], '')))
        ELSE 'ITEM:' + LTRIM(RTRIM(ISNULL(tl.[Item No.], '')))
    END AS ReportKey,
    {itemCodeExpression} AS ItemCode,
    {descriptionExpression} AS ItemDescription,
    SUM(CAST({quantityExpression} AS DECIMAL(18, 2))) AS Quantity,
    COUNT(*) AS SourceLineCount
FROM [Transfer Header] th
INNER JOIN [Transfer Line] tl ON tl.[Document No.] = th.[No.]
{variantJoin}
WHERE th.[Transfer Date] >= @startDate
    AND th.[Transfer Date] < @endExclusive
    AND UPPER(ISNULL(th.[Status], '')) = 'RECEIVED'
    AND ISNULL(transferCategory.ExcludeOnInventoryReport, 0) = 0
  AND (
        (@currentWarehouseId <> '' AND LTRIM(RTRIM(ISNULL(th.[To Warehouse ID], ''))) = @currentWarehouseId)
        OR (@currentWarehouseName <> '' AND LTRIM(RTRIM(ISNULL(th.[To Warehouse], ''))) = @currentWarehouseName)
      )
  AND (
        (@reportKeyFilter = '' AND (LTRIM(RTRIM(ISNULL(tl.[Item No.], ''))) <> '' OR LTRIM(RTRIM(ISNULL(tl.[Variant ID], ''))) <> ''))
        OR CASE
            WHEN LTRIM(RTRIM(ISNULL(tl.[Variant ID], ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(tl.[Variant ID], '')))
            ELSE 'ITEM:' + LTRIM(RTRIM(ISNULL(tl.[Item No.], '')))
           END = @reportKeyFilter
      )
GROUP BY
    CASE
        WHEN LTRIM(RTRIM(ISNULL(tl.[Variant ID], ''))) <> '' THEN 'VAR:' + LTRIM(RTRIM(ISNULL(tl.[Variant ID], '')))
        ELSE 'ITEM:' + LTRIM(RTRIM(ISNULL(tl.[Item No.], '')))
    END,
    {itemCodeExpression},
    {descriptionExpression}
HAVING SUM(CAST({quantityExpression} AS DECIMAL(18, 2))) <> 0
ORDER BY {descriptionExpression}, {itemCodeExpression}";

            using var command = new SqlCommand(query, connection);
            command.Parameters.AddWithValue("@startDate", startDate.Date);
            command.Parameters.AddWithValue("@endExclusive", endExclusive);
            command.Parameters.AddWithValue("@currentWarehouseId", currentWarehouseId);
            command.Parameters.AddWithValue("@currentWarehouseName", currentWarehouseName);
            command.Parameters.AddWithValue("@reportKeyFilter", normalizedReportKeyFilter);

            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                string reportKey = reader["ReportKey"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(reportKey))
                    continue;

                decimal quantity = reader["Quantity"] != DBNull.Value ? Convert.ToDecimal(reader["Quantity"]) : 0m;
                if (quantity == 0m)
                    continue;

                string itemCode = reader["ItemCode"]?.ToString()?.Trim() ?? string.Empty;
                string itemDescription = reader["ItemDescription"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(itemDescription))
                    itemDescription = itemCode;

                aggregates.Add(new TransferReportAggregate
                {
                    ReportKey = reportKey,
                    ItemCode = itemCode,
                    ItemDescription = itemDescription,
                    Quantity = quantity,
                    SourceLineCount = reader["SourceLineCount"] != DBNull.Value ? Convert.ToInt32(reader["SourceLineCount"]) : 0
                });
            }

            return aggregates;
        }

        private static List<ExpenseReportLine> GenerateExpenseReportLines(string connectionString, DateTime startDate, DateTime endDate)
        {
            var lines = new List<ExpenseReportLine>();

            using (var connection = new SqlConnection(connectionString))
            {
                connection.Open();
                bool hasExpenseCategory = TableHasColumn(connection, "TransactionHeader", "ExpenseCategory");
                                bool hasFloatExpense = TableHasColumn(connection, "ExpenseCategorySetup", "Float_Expense");
                DateTime endExclusive = endDate.Date.AddDays(1);

                                string categorySql = hasExpenseCategory ? "ISNULL(th.ExpenseCategory, 'Uncategorized')" : "'Uncategorized'";
                                string fromClause = "FROM TransactionHeader th";
                                string floatExpenseFilter = string.Empty;

                                if (hasExpenseCategory && hasFloatExpense)
                                {
                                        fromClause += @"
LEFT JOIN ExpenseCategorySetup ecs
        ON LTRIM(RTRIM(th.ExpenseCategory)) = LTRIM(RTRIM(ecs.Code))";
                                        floatExpenseFilter = "\n  AND ISNULL(ecs.Float_Expense, 0) = 0";
                                }

                string query = $@"
SELECT {categorySql} AS ExpenseCategory,
             ISNULL(th.Description, '') AS Description,
             ISNULL(th.UserID, '') AS UserID,
             ISNULL(CAST(th.Quantity AS DECIMAL(18, 2)), 1) AS Quantity,
             th.[Date],
             th.[Time],
             ABS(ISNULL(th.GrossAmount, 0)) AS TotalAmount
{fromClause}
WHERE th.Type = 'EXPENSE'
    AND th.[Date] >= @startDate
    AND th.[Date] < @endExclusive{floatExpenseFilter}
ORDER BY ExpenseCategory, [Date], [Time], Description";

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

            decimal grandTotal = lines.Sum(line => line.Amount);
            string currentWarehouseName = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString)?.Name ?? "Not Set";
            var groupedLines = lines
                .GroupBy(line => string.IsNullOrWhiteSpace(line.Category) ? "Uncategorized" : line.Category, StringComparer.OrdinalIgnoreCase)
                .Select(group => new
                {
                    Category = group.First().Category,
                    Lines = group.ToList(),
                    Total = group.Sum(line => line.Amount)
                })
                .ToList();
            int groupIndex = 0;
            int lineIndexInGroup = 0;
            bool groupHeaderPrinted = false;

            printDocument.BeginPrint += (sender, e) =>
            {
                groupIndex = 0;
                lineIndexInGroup = 0;
                groupHeaderPrinted = false;
            };

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

                while (groupIndex < groupedLines.Count)
                {
                    var currentGroup = groupedLines[groupIndex];
                    string currentCategory = string.IsNullOrWhiteSpace(currentGroup.Category) ? "Uncategorized" : currentGroup.Category;

                    if (!groupHeaderPrinted)
                    {
                        float categoryHeaderHeight = categoryFont.GetHeight(graphics) + 4f;
                        float columnHeaderHeight = columnFont.GetHeight(graphics) + 10f;
                        float firstLineHeight = lineIndexInGroup < currentGroup.Lines.Count
                            ? GetRowHeight(string.IsNullOrWhiteSpace(currentGroup.Lines[lineIndexInGroup].Description) ? "(No Description)" : currentGroup.Lines[lineIndexInGroup].Description)
                            : singleLineRowHeight;
                        float requiredSpace = categoryHeaderHeight + columnHeaderHeight + firstLineHeight;
                        if (y + requiredSpace > bounds.Bottom - 20 && y > bounds.Top + 50)
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
                        groupHeaderPrinted = true;
                    }

                    while (lineIndexInGroup < currentGroup.Lines.Count)
                    {
                        var line = currentGroup.Lines[lineIndexInGroup];
                        string description = string.IsNullOrWhiteSpace(line.Description) ? "(No Description)" : line.Description;
                        float rowHeight = GetRowHeight(description);
                        float subtotalHeight = 4f + singleLineRowHeight + 8f;
                        bool isLastLineInGroup = lineIndexInGroup == currentGroup.Lines.Count - 1;
                        float requiredSpace = rowHeight + (isLastLineInGroup ? subtotalHeight : 0f);
                        if (y + requiredSpace > bounds.Bottom - 20 && y > bounds.Top + 50)
                        {
                            e.HasMorePages = true;
                            return;
                        }

                        graphics.DrawString(description, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left, y, descriptionWidth, rowHeight), descriptionFormat);
                        graphics.DrawString($"{line.Quantity:N0}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth, y, qtyWidth, rowHeight));
                        graphics.DrawString(line.UserId, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth, y, userWidth, rowHeight));
                        graphics.DrawString(line.DateText, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth, y, dateWidth, rowHeight));
                        graphics.DrawString(line.TimeText, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth + dateWidth, y, timeWidth, rowHeight));
                        graphics.DrawString($"{line.Amount:N2}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth + dateWidth + timeWidth, y, amountWidth, rowHeight), new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Far });
                        y += rowHeight;
                        lineIndexInGroup++;
                    }

                    graphics.DrawLine(System.Drawing.Pens.Gray, bounds.Left, y, bounds.Right, y);
                    y += 4f;
                    graphics.DrawString($"Subtotal - {currentCategory}", columnFont, System.Drawing.Brushes.Black, bounds.Left, y);
                    graphics.DrawString($"{currentGroup.Total:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + descriptionWidth + qtyWidth + userWidth + dateWidth + timeWidth, y, amountWidth, singleLineRowHeight), new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Far });
                    y += singleLineRowHeight + 8f;
                    groupIndex++;
                    lineIndexInGroup = 0;
                    groupHeaderPrinted = false;
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

            IWin32Window? owner = Application.OpenForms.Count > 0 ? Application.OpenForms[0] : null;
            using var previewForm = new Form
            {
                Text = "Expense Report Preview",
                StartPosition = FormStartPosition.CenterParent,
                WindowState = FormWindowState.Maximized,
                BackColor = Color.White,
                MinimizeBox = true,
                MaximizeBox = true
            };

            var previewControl = new PrintPreviewControl
            {
                Document = printDocument,
                Dock = DockStyle.Fill,
                UseAntiAlias = true,
                AutoZoom = true
            };

            var buttonPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 54,
                BackColor = Color.WhiteSmoke
            };

            var printButton = new Button
            {
                Text = "Print",
                Width = 100,
                Height = 34,
                Left = 12,
                Top = 10,
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var closeButton = new Button
            {
                Text = "Close",
                Width = 100,
                Height = 34,
                Left = 122,
                Top = 10,
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            printButton.Click += (sender, e) =>
            {
                previewForm.DialogResult = DialogResult.OK;
                previewForm.Close();
            };

            closeButton.Click += (sender, e) =>
            {
                previewForm.DialogResult = DialogResult.Cancel;
                previewForm.Close();
            };

            buttonPanel.Controls.Add(printButton);
            buttonPanel.Controls.Add(closeButton);
            previewForm.Controls.Add(previewControl);
            previewForm.Controls.Add(buttonPanel);

            DialogResult previewResult = owner != null ? previewForm.ShowDialog(owner) : previewForm.ShowDialog();
            if (previewResult != DialogResult.OK)
            {
                return;
            }

            using var printDialog = new PrintDialog
            {
                Document = printDocument,
                UseEXDialog = true,
                AllowSomePages = false,
                AllowSelection = false
            };

            DialogResult printDialogResult = owner != null ? printDialog.ShowDialog(owner) : printDialog.ShowDialog();
            if (printDialogResult != DialogResult.OK)
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

        private static void ApplyLandscapeA4PageSettings(System.Drawing.Printing.PrintDocument printDocument)
        {
            try
            {
                ApplyA4PageSettings(printDocument);

                int portraitWidth = printDocument.DefaultPageSettings.PaperSize?.Width ?? 827;
                int portraitHeight = printDocument.DefaultPageSettings.PaperSize?.Height ?? 1169;
                int landscapeWidth = Math.Max(portraitWidth, portraitHeight);
                int landscapeHeight = Math.Min(portraitWidth, portraitHeight);

                // Some printer drivers fail during preview when Landscape is enabled directly.
                // Use a landscape-sized paper instead so the report still renders wide.
                printDocument.DefaultPageSettings.PaperSize = new System.Drawing.Printing.PaperSize("A4 Landscape", landscapeWidth, landscapeHeight);
                printDocument.DefaultPageSettings.Landscape = false;
            }
            catch
            {
            }
        }

        private static void PrintItemVariantSalesReportA4(string reportNo, DateTime startDate, DateTime endDate, List<ItemVariantSalesReportLine> lines, string? reportKeyFilter, string? itemVariantFilterDisplay)
        {
            using var printDocument = new System.Drawing.Printing.PrintDocument();
            ApplyLandscapeA4PageSettings(printDocument);

            using var titleFont = new System.Drawing.Font("Arial", 16, System.Drawing.FontStyle.Bold);
            using var headerFont = new System.Drawing.Font("Arial", 11, System.Drawing.FontStyle.Regular);
            using var columnFont = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Bold);
            using var bodyFont = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Regular);

            string currentWarehouseName = TransferOrderData.GetCurrentWarehouse(GlobalSettings.ConnectionString)?.Name ?? "Not Set";
            string normalizedReportKeyFilter = NormalizeComparisonValue(reportKeyFilter);
            string normalizedItemVariantFilterDisplay = NormalizeComparisonValue(itemVariantFilterDisplay);
            decimal totalLocalQuantity = lines.Sum(line => line.LocalOrderQuantity);
            decimal totalOnlineQuantity = lines.Sum(line => line.OnlineOrderQuantity);
            decimal totalQuantity = lines.Sum(line => line.TotalQuantity);
            int lineIndex = 0;
            int currentPreviewPage = 0;

            printDocument.BeginPrint += (sender, e) =>
            {
                lineIndex = 0;
            };

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
                float rowHeight = bodyFont.GetHeight(graphics) + 8f;
                float headerRowHeight = (columnFont.GetHeight(graphics) * 2f) + 8f;
                float itemCodeWidth = 85f;
                float localWidth = 95f;
                float onlineWidth = 95f;
                float totalWidth = 95f;
                float descriptionWidth = Math.Max(325f, bounds.Width - itemCodeWidth - localWidth - onlineWidth - totalWidth);
                using var rightAlign = new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Far, LineAlignment = System.Drawing.StringAlignment.Center };
                using var leftAlign = new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Near, LineAlignment = System.Drawing.StringAlignment.Center, Trimming = System.Drawing.StringTrimming.EllipsisCharacter };
                using var centerAlign = new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Center, LineAlignment = System.Drawing.StringAlignment.Center };

                graphics.DrawString(GlobalSettings.CompanyName, titleFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += titleFont.GetHeight(graphics);
                graphics.DrawString(GlobalSettings.CompanyTagline, headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics) + 8f;
                graphics.DrawString("ITEM VARIANT SALES REPORT", titleFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += titleFont.GetHeight(graphics) + 8f;
                graphics.DrawString($"Report No: {reportNo}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                graphics.DrawString($"Date Range: {startDate:yyyy-MM-dd} to {endDate:yyyy-MM-dd}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                graphics.DrawString($"To Warehouse: {currentWarehouseName}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                if (!string.IsNullOrWhiteSpace(normalizedReportKeyFilter))
                {
                    graphics.DrawString($"Item Variant Filter: {(string.IsNullOrWhiteSpace(normalizedItemVariantFilterDisplay) ? normalizedReportKeyFilter : normalizedItemVariantFilterDisplay)}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                    y += headerFont.GetHeight(graphics);
                }
                graphics.DrawString($"Printed By: {CurrentUser.Username ?? string.Empty}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics) + 12f;

                graphics.DrawString("Item", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left, y, itemCodeWidth, headerRowHeight), leftAlign);
                graphics.DrawString("Description", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth, y, descriptionWidth, headerRowHeight), leftAlign);
                graphics.DrawString("Local Sales", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth, y, localWidth, headerRowHeight), centerAlign);
                graphics.DrawString("Online Sales", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth + localWidth, y, onlineWidth, headerRowHeight), centerAlign);
                graphics.DrawString("Qty on hand", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth + localWidth + onlineWidth, y, totalWidth, headerRowHeight), centerAlign);
                y += headerRowHeight;
                graphics.DrawLine(System.Drawing.Pens.Black, bounds.Left, y, bounds.Right, y);
                y += 6f;

                if (lines.Count == 0)
                {
                    graphics.DrawString("No sales found for the selected date range.", bodyFont, System.Drawing.Brushes.Black, bounds.Left, y);
                    e.HasMorePages = false;
                    return;
                }

                while (lineIndex < lines.Count)
                {
                    var line = lines[lineIndex];
                    float requiredSpace = rowHeight;
                    bool isLastLine = lineIndex == lines.Count - 1;
                    if (isLastLine)
                    {
                        requiredSpace += rowHeight + 12f;
                    }

                    if (y + requiredSpace > bounds.Bottom - 20 && y > bounds.Top + 50)
                    {
                        e.HasMorePages = true;
                        return;
                    }

                    string description = string.IsNullOrWhiteSpace(line.ItemDescription) ? line.ItemCode : line.ItemDescription;
                    graphics.DrawString(line.ItemCode, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left, y, itemCodeWidth, rowHeight), leftAlign);
                    graphics.DrawString(description, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth, y, descriptionWidth, rowHeight), leftAlign);
                    graphics.DrawString($"{line.LocalOrderQuantity:N0}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth, y, localWidth, rowHeight), rightAlign);
                    graphics.DrawString($"{line.OnlineOrderQuantity:N0}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth + localWidth, y, onlineWidth, rowHeight), rightAlign);
                    graphics.DrawString($"{line.TotalQuantity:N0}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth + localWidth + onlineWidth, y, totalWidth, rowHeight), rightAlign);
                    y += rowHeight;
                    lineIndex++;
                }

                graphics.DrawLine(System.Drawing.Pens.Black, bounds.Left, y, bounds.Right, y);
                y += 8f;
                graphics.DrawString("Totals", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left, y, itemCodeWidth + descriptionWidth, rowHeight), leftAlign);
                graphics.DrawString($"{totalLocalQuantity:N0}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth, y, localWidth, rowHeight), rightAlign);
                graphics.DrawString($"{totalOnlineQuantity:N0}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth + localWidth, y, onlineWidth, rowHeight), rightAlign);
                graphics.DrawString($"{totalQuantity:N0}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(bounds.Left + itemCodeWidth + descriptionWidth + localWidth + onlineWidth, y, totalWidth, rowHeight), rightAlign);

                e.HasMorePages = false;
            };

            IWin32Window? owner = Application.OpenForms.Count > 0 ? Application.OpenForms[0] : null;
            using var previewForm = new Form
            {
                Text = "Item Variant Sales Report Preview",
                StartPosition = FormStartPosition.CenterParent,
                WindowState = FormWindowState.Maximized,
                BackColor = System.Drawing.Color.White,
                MinimizeBox = true,
                MaximizeBox = true
            };

            var previewControl = new PrintPreviewControl
            {
                Document = printDocument,
                Dock = DockStyle.Fill,
                UseAntiAlias = true,
                AutoZoom = true
            };

            var buttonPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 54,
                BackColor = System.Drawing.Color.WhiteSmoke
            };

            var previousPageButton = new Button
            {
                Text = "Previous",
                Width = 100,
                Height = 34,
                Left = 12,
                Top = 10,
                BackColor = System.Drawing.Color.DimGray,
                ForeColor = System.Drawing.Color.White,
                Font = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Bold),
                Enabled = false
            };

            var pageLabel = new Label
            {
                Text = "Page 1",
                AutoSize = false,
                Width = 90,
                Height = 34,
                Left = 122,
                Top = 10,
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Bold),
                ForeColor = System.Drawing.Color.Black
            };

            var nextPageButton = new Button
            {
                Text = "Next",
                Width = 100,
                Height = 34,
                Left = 222,
                Top = 10,
                BackColor = System.Drawing.Color.DimGray,
                ForeColor = System.Drawing.Color.White,
                Font = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Bold)
            };

            var printButton = new Button
            {
                Text = "Print",
                Width = 100,
                Height = 34,
                Left = 332,
                Top = 10,
                BackColor = System.Drawing.Color.Green,
                ForeColor = System.Drawing.Color.White,
                Font = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Bold)
            };

            var closeButton = new Button
            {
                Text = "Close",
                Width = 100,
                Height = 34,
                Left = 442,
                Top = 10,
                BackColor = System.Drawing.Color.Gray,
                ForeColor = System.Drawing.Color.White,
                Font = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Bold)
            };

            void UpdatePreviewPage()
            {
                if (currentPreviewPage < 0)
                {
                    currentPreviewPage = 0;
                }

                previewControl.StartPage = currentPreviewPage;
                pageLabel.Text = $"Page {currentPreviewPage + 1}";
                previousPageButton.Enabled = currentPreviewPage > 0;
            }

            previousPageButton.Click += (sender, e) =>
            {
                if (currentPreviewPage <= 0)
                {
                    return;
                }

                currentPreviewPage--;
                UpdatePreviewPage();
            };

            nextPageButton.Click += (sender, e) =>
            {
                currentPreviewPage++;
                UpdatePreviewPage();
            };

            printButton.Click += (sender, e) =>
            {
                previewForm.DialogResult = DialogResult.OK;
                previewForm.Close();
            };

            closeButton.Click += (sender, e) =>
            {
                previewForm.DialogResult = DialogResult.Cancel;
                previewForm.Close();
            };

            buttonPanel.Controls.Add(previousPageButton);
            buttonPanel.Controls.Add(pageLabel);
            buttonPanel.Controls.Add(nextPageButton);
            buttonPanel.Controls.Add(printButton);
            buttonPanel.Controls.Add(closeButton);
            previewForm.Controls.Add(previewControl);
            previewForm.Controls.Add(buttonPanel);
            UpdatePreviewPage();

            DialogResult previewResult = owner != null ? previewForm.ShowDialog(owner) : previewForm.ShowDialog();
            if (previewResult != DialogResult.OK)
            {
                return;
            }

            using var printDialog = new PrintDialog
            {
                Document = printDocument,
                UseEXDialog = true,
                AllowSomePages = false,
                AllowSelection = false
            };

            DialogResult printDialogResult = owner != null ? printDialog.ShowDialog(owner) : printDialog.ShowDialog();
            if (printDialogResult != DialogResult.OK)
            {
                return;
            }

            printDocument.Print();
        }

        public static void PrintItemVariantSalesWorksheetA4(ItemVariantSalesWorksheetHeader header, List<ItemVariantSalesWorksheetLine> lines, IWin32Window? owner = null)
        {
            using var printDocument = new System.Drawing.Printing.PrintDocument();
            ApplyLandscapeA4PageSettings(printDocument);

            using var titleFont = new System.Drawing.Font("Arial", 16, System.Drawing.FontStyle.Bold);
            using var headerFont = new System.Drawing.Font("Arial", 11, System.Drawing.FontStyle.Regular);
            using var columnFont = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Bold);
            using var bodyFont = new System.Drawing.Font("Arial", 10, System.Drawing.FontStyle.Regular);

            List<ItemVariantSalesWorksheetLine> filteredLines = lines.Where(line => line.TotalSalesCount != 0).ToList();

            decimal totalQtyTransferred = filteredLines.Sum(line => line.QtyTransferred);
            decimal totalLocalSales = filteredLines.Sum(line => line.LocalSales);
            decimal totalOnlineSales = filteredLines.Sum(line => line.OnlineSales);
            decimal totalSalesCount = filteredLines.Sum(line => line.TotalSalesCount);
            decimal totalQtyOnHand = filteredLines.Sum(line => line.QtyOnHand);
            decimal totalPhysicalQtyOnHand = filteredLines.Sum(line => line.PhysicalQtyOnHand ?? 0m);
            int lineIndex = 0;
            int currentPreviewPage = 0;

            printDocument.BeginPrint += (sender, e) =>
            {
                lineIndex = 0;
            };

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
                float rowHeight = bodyFont.GetHeight(graphics) + 14f;
                float headerRowHeight = columnFont.GetHeight(graphics) + 10f;
                float itemCodeWidth = 90f;
                float qtyTransferredWidth = 100f;
                float localWidth = 90f;
                float onlineWidth = 90f;
                float totalSalesWidth = 100f;
                float qtyOnHandWidth = 100f;
                float physicalQtyWidth = 120f;
                float descriptionWidth = Math.Max(220f, bounds.Width - itemCodeWidth - qtyTransferredWidth - localWidth - onlineWidth - totalSalesWidth - qtyOnHandWidth - physicalQtyWidth);
                using var rightAlign = new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Far, LineAlignment = System.Drawing.StringAlignment.Center, FormatFlags = System.Drawing.StringFormatFlags.NoWrap, Trimming = System.Drawing.StringTrimming.EllipsisCharacter };
                using var leftAlign = new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Near, LineAlignment = System.Drawing.StringAlignment.Center, Trimming = System.Drawing.StringTrimming.EllipsisCharacter, FormatFlags = System.Drawing.StringFormatFlags.NoWrap };

                graphics.DrawString(GlobalSettings.CompanyName, titleFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += titleFont.GetHeight(graphics);
                graphics.DrawString(GlobalSettings.CompanyTagline, headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics) + 8f;
                graphics.DrawString("MONTH END SALES", titleFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += titleFont.GetHeight(graphics) + 8f;
                graphics.DrawString($"Document No: {header.DocumentNo}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                graphics.DrawString($"Date Generated: {(header.GeneratedDate == DateTime.MinValue ? string.Empty : header.GeneratedDate.ToString("yyyy-MM-dd HH:mm:ss"))}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                graphics.DrawString($"Date Range: {header.FromDate:yyyy-MM-dd} to {header.ToDate:yyyy-MM-dd}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                graphics.DrawString($"Warehouse: {header.WarehouseName}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics);
                if (!string.IsNullOrWhiteSpace(header.ItemVariantFilter))
                {
                    graphics.DrawString($"Item Variant Filter: {header.ItemVariantFilter}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                    y += headerFont.GetHeight(graphics);
                }
                graphics.DrawString($"Printed By: {CurrentUser.Username ?? string.Empty}", headerFont, System.Drawing.Brushes.Black, bounds.Left, y);
                y += headerFont.GetHeight(graphics) + 12f;

                float col0 = bounds.Left;
                float col1 = col0 + itemCodeWidth;
                float col2 = col1 + descriptionWidth;
                float col3 = col2 + qtyTransferredWidth;
                float col4 = col3 + localWidth;
                float col5 = col4 + onlineWidth;
                float col6 = col5 + totalSalesWidth;
                float col7 = col6 + qtyOnHandWidth;

                graphics.DrawString("Item No.", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col0, y, itemCodeWidth, headerRowHeight), leftAlign);
                graphics.DrawString("Description", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col1, y, descriptionWidth, headerRowHeight), leftAlign);
                graphics.DrawString("Qty Transferred", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col2, y, qtyTransferredWidth, headerRowHeight), rightAlign);
                graphics.DrawString("Local Sales", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col3, y, localWidth, headerRowHeight), rightAlign);
                graphics.DrawString("Online Sales", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col4, y, onlineWidth, headerRowHeight), rightAlign);
                graphics.DrawString("Total Sales", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col5, y, totalSalesWidth, headerRowHeight), rightAlign);
                graphics.DrawString("Qty on Hand", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col6, y, qtyOnHandWidth, headerRowHeight), rightAlign);
                graphics.DrawString("Physical Qty on Hand", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col7, y, physicalQtyWidth, headerRowHeight), rightAlign);
                y += headerRowHeight;
                graphics.DrawLine(System.Drawing.Pens.Black, bounds.Left, y, bounds.Right, y);
                y += 6f;

                if (filteredLines.Count == 0)
                {
                    graphics.DrawString("No lines found for this worksheet.", bodyFont, System.Drawing.Brushes.Black, bounds.Left, y);
                    e.HasMorePages = false;
                    return;
                }

                while (lineIndex < filteredLines.Count)
                {
                    var line = filteredLines[lineIndex];
                    float requiredSpace = rowHeight;
                    bool isLastLine = lineIndex == filteredLines.Count - 1;
                    if (isLastLine)
                    {
                        requiredSpace += rowHeight + 12f;
                    }

                    if (y + requiredSpace > bounds.Bottom - 20 && y > bounds.Top + 50)
                    {
                        e.HasMorePages = true;
                        return;
                    }

                    string description = string.IsNullOrWhiteSpace(line.Description) ? line.ItemNo : line.Description;
                    graphics.DrawString(line.ItemNo, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col0, y, itemCodeWidth, rowHeight), leftAlign);
                    graphics.DrawString(description, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col1, y, descriptionWidth, rowHeight), leftAlign);
                    graphics.DrawString($"{line.QtyTransferred:N2}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col2, y, qtyTransferredWidth, rowHeight), rightAlign);
                    graphics.DrawString($"{line.LocalSales:N2}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col3, y, localWidth, rowHeight), rightAlign);
                    graphics.DrawString($"{line.OnlineSales:N2}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col4, y, onlineWidth, rowHeight), rightAlign);
                    graphics.DrawString($"{line.TotalSalesCount:N2}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col5, y, totalSalesWidth, rowHeight), rightAlign);
                    graphics.DrawString($"{line.QtyOnHand:N2}", bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col6, y, qtyOnHandWidth, rowHeight), rightAlign);
                    graphics.DrawString(line.PhysicalQtyOnHand.HasValue ? $"{line.PhysicalQtyOnHand.Value:N2}" : string.Empty, bodyFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col7, y, physicalQtyWidth, rowHeight), rightAlign);
                    y += rowHeight;
                    graphics.DrawLine(System.Drawing.Pens.LightGray, bounds.Left, y, bounds.Right, y);
                    lineIndex++;
                }

                graphics.DrawLine(System.Drawing.Pens.Black, bounds.Left, y, bounds.Right, y);
                y += 8f;
                graphics.DrawString("Totals", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col0, y, itemCodeWidth + descriptionWidth, rowHeight), leftAlign);
                graphics.DrawString($"{totalQtyTransferred:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col2, y, qtyTransferredWidth, rowHeight), rightAlign);
                graphics.DrawString($"{totalLocalSales:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col3, y, localWidth, rowHeight), rightAlign);
                graphics.DrawString($"{totalOnlineSales:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col4, y, onlineWidth, rowHeight), rightAlign);
                graphics.DrawString($"{totalSalesCount:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col5, y, totalSalesWidth, rowHeight), rightAlign);
                graphics.DrawString($"{totalQtyOnHand:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col6, y, qtyOnHandWidth, rowHeight), rightAlign);
                graphics.DrawString($"{totalPhysicalQtyOnHand:N2}", columnFont, System.Drawing.Brushes.Black, new System.Drawing.RectangleF(col7, y, physicalQtyWidth, rowHeight), rightAlign);

                e.HasMorePages = false;
            };

            using var previewForm = new Form
            {
                Text = "Month End Sales Preview",
                StartPosition = FormStartPosition.CenterParent,
                WindowState = FormWindowState.Maximized,
                BackColor = Color.White,
                MinimizeBox = true,
                MaximizeBox = true
            };

            var previewControl = new PrintPreviewControl
            {
                Document = printDocument,
                Dock = DockStyle.Fill,
                UseAntiAlias = true,
                AutoZoom = true
            };

            var buttonPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 54,
                BackColor = Color.WhiteSmoke
            };

            var previousPageButton = new Button
            {
                Text = "Previous",
                Width = 100,
                Height = 34,
                Left = 12,
                Top = 10,
                BackColor = Color.DimGray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold),
                Enabled = false
            };

            var pageLabel = new Label
            {
                Text = "Page 1",
                AutoSize = false,
                Width = 90,
                Height = 34,
                Left = 122,
                Top = 10,
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.Black
            };

            var nextPageButton = new Button
            {
                Text = "Next",
                Width = 100,
                Height = 34,
                Left = 222,
                Top = 10,
                BackColor = Color.DimGray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var printButton = new Button
            {
                Text = "Print",
                Width = 100,
                Height = 34,
                Left = 332,
                Top = 10,
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var closeButton = new Button
            {
                Text = "Close",
                Width = 100,
                Height = 34,
                Left = 442,
                Top = 10,
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            void UpdatePreviewPage()
            {
                if (currentPreviewPage < 0)
                {
                    currentPreviewPage = 0;
                }

                previewControl.StartPage = currentPreviewPage;
                pageLabel.Text = $"Page {currentPreviewPage + 1}";
                previousPageButton.Enabled = currentPreviewPage > 0;
            }

            previousPageButton.Click += (sender, e) =>
            {
                if (currentPreviewPage <= 0)
                {
                    return;
                }

                currentPreviewPage--;
                UpdatePreviewPage();
            };

            nextPageButton.Click += (sender, e) =>
            {
                currentPreviewPage++;
                UpdatePreviewPage();
            };

            printButton.Click += (sender, e) =>
            {
                previewForm.DialogResult = DialogResult.OK;
                previewForm.Close();
            };

            closeButton.Click += (sender, e) =>
            {
                previewForm.DialogResult = DialogResult.Cancel;
                previewForm.Close();
            };

            buttonPanel.Controls.Add(previousPageButton);
            buttonPanel.Controls.Add(pageLabel);
            buttonPanel.Controls.Add(nextPageButton);
            buttonPanel.Controls.Add(printButton);
            buttonPanel.Controls.Add(closeButton);
            previewForm.Controls.Add(previewControl);
            previewForm.Controls.Add(buttonPanel);
            UpdatePreviewPage();

            DialogResult previewResult = owner != null ? previewForm.ShowDialog(owner) : previewForm.ShowDialog();
            if (previewResult != DialogResult.OK)
            {
                return;
            }

            using var printDialog = new PrintDialog
            {
                Document = printDocument,
                UseEXDialog = true,
                AllowSomePages = false,
                AllowSelection = false
            };

            DialogResult printDialogResult2 = owner != null ? printDialog.ShowDialog(owner) : printDialog.ShowDialog();
            if (printDialogResult2 != DialogResult.OK)
            {
                return;
            }

            printDocument.Print();
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
                bool hasOnlineOrderHeader = TableExists(connection, "OnlineOrderHeader");
                bool hasOnlineOrderReceiptNo = hasOnlineOrderHeader && TableHasColumn(connection, "OnlineOrderHeader", "ReceiptNo");
                bool hasFromOnlineOrder = TableHasColumn(connection, "ItemLedgerEntry", "FromOnlineOrder");
                string excludeOnlineOrderItemsFilter = string.Empty;

                if (hasFromOnlineOrder)
                {
                    excludeOnlineOrderItemsFilter += @"
                      AND ISNULL(th.FromOnlineOrder, 0) = 0";
                }

                if (hasOnlineOrderReceiptNo)
                {
                    excludeOnlineOrderItemsFilter += @"
                      AND NOT EXISTS (
                          SELECT 1
                          FROM dbo.OnlineOrderHeader ooh
                          WHERE (
                                  LTRIM(RTRIM(ISNULL(ooh.ReceiptNo, ''))) <> ''
                              AND LTRIM(RTRIM(ISNULL(ooh.ReceiptNo, ''))) = LTRIM(RTRIM(ISNULL(th.DocumentNo, '')))
                          )
                             OR (
                                  LTRIM(RTRIM(ISNULL(ooh.OrderID, ''))) <> ''
                              AND LTRIM(RTRIM(ISNULL(ooh.OrderID, ''))) = LTRIM(RTRIM(ISNULL(th.DocumentNo, '')))
                          )
                      )";
                }

                var itemsCmd = new SqlCommand(@"
                    SELECT th.Description, SUM(th.Quantity * -1) as TotalQty, SUM(th.GrossAmount) as TotalAmount
                    FROM ItemLedgerEntry th
                    WHERE  (th.EODID IS NULL OR th.EODID = '')
                    " + excludeOnlineOrderItemsFilter + @"
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