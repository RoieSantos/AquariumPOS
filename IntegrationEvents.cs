using System;
using System.Data;
using System.Net.Http;
using System.Data.SqlClient;
using System.Text.Json;
using System.Threading.Tasks;
using System.Globalization;

namespace AquariumPOS
{
    public static class IntegrationEvents
    {
        private static readonly TimeSpan BusinessUtcOffset = TimeSpan.FromHours(8);

        private static bool TryParseApiTimestampUtc(string raw, out DateTime utcDateTime)
        {
            utcDateTime = default;
            if (string.IsNullOrWhiteSpace(raw))
                return false;

            if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var dtoRoundtrip))
            {
                utcDateTime = dtoRoundtrip.ToUniversalTime().UtcDateTime;
                return true;
            }

            if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var dtoAssumeUtc))
            {
                utcDateTime = dtoAssumeUtc.UtcDateTime;
                return true;
            }

            if (DateTime.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var dtAssumeUtc))
            {
                utcDateTime = DateTime.SpecifyKind(dtAssumeUtc, DateTimeKind.Utc);
                return true;
            }

            if (DateTime.TryParse(raw, out var dtFallback))
            {
                utcDateTime = DateTime.SpecifyKind(dtFallback, DateTimeKind.Local).ToUniversalTime();
                return true;
            }

            return false;
        }

        private static DateTime ConvertUtcToBusinessLocal(DateTime utcDateTime)
        {
            var utcOffset = new DateTimeOffset(DateTime.SpecifyKind(utcDateTime, DateTimeKind.Utc));
            return utcOffset.ToOffset(BusinessUtcOffset).DateTime;
        }

        private static DateTime? ParseApiDateToBusinessDate(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw))
                return null;

            var trimmed = raw.Trim();
            if (DateTime.TryParseExact(trimmed, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var dateOnly))
                return dateOnly.Date;

            if (TryParseApiTimestampUtc(trimmed, out var parsedUtc))
                return ConvertUtcToBusinessLocal(parsedUtc).Date;

            if (DateTime.TryParse(trimmed, out var fallback))
                return fallback.Date;

            return null;
        }

        /// <summary>
        /// Fetches online orders from configured API and returns a DataTable with columns:
        /// ReceiptNo, TransactionNo, Date, Time, CustomerName
        /// </summary>
        public static async Task<DataTable> SyncOrderListAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;

            // Read last sync timestamp from DB (if present) so we only request new/updated orders
            DateTime? lastSyncUtc = null;
            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();
                    string createSyncTable = @"
                        IF OBJECT_ID('dbo.OnlineOrderSync', 'U') IS NULL
                        BEGIN
                            CREATE TABLE dbo.OnlineOrderSync (
                                Id INT IDENTITY(1,1) PRIMARY KEY,
                                LastSyncUtc DATETIME2 NULL,
                                CreatedAtUtc DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
                            )
                        END
                    ";
                    using (var ccmd = new SqlCommand(createSyncTable, conn)) ccmd.ExecuteNonQuery();

                    using (var cmd = new SqlCommand("SELECT TOP 1 LastSyncUtc FROM dbo.OnlineOrderSync ORDER BY Id DESC", conn))
                    {
                        var obj = cmd.ExecuteScalar();
                        if (obj != null && obj != DBNull.Value)
                        {
                            try { lastSyncUtc = Convert.ToDateTime(obj).ToUniversalTime(); } catch { lastSyncUtc = null; }
                        }
                    }
                }
            }
            catch { lastSyncUtc = null; }

            // Prepare result table up front so we can accumulate rows across pages
            var table = new DataTable();
            table.Columns.Add("OrderID", typeof(string));
            table.Columns.Add("TransactionNo", typeof(string));
            table.Columns.Add("Date", typeof(string));
            table.Columns.Add("Time", typeof(string));
            table.Columns.Add("CustomerName", typeof(string));
            // Order status from upstream
            table.Columns.Add("Status", typeof(string));
            // Upstream platform ids
            table.Columns.Add("Page_ID", typeof(string));
            table.Columns.Add("Conversation_ID", typeof(string));
            // Local location mapping from upstream warehouse_id
            table.Columns.Add("LocationID", typeof(string));
            // Financial fields
            table.Columns.Add("MoneyToCollect", typeof(decimal));
            table.Columns.Add("AmountPaid", typeof(decimal));
            table.Columns.Add("Balance", typeof(decimal));
            // Optional fields added later in rows
            table.Columns.Add("Discount", typeof(decimal));
            table.Columns.Add("Last_Updated_At", typeof(string));
            table.Columns.Add("LastPaid_Date", typeof(string));
            table.Columns.Add("LastPaid_Time", typeof(string));
            table.Columns.Add("For Delivery", typeof(bool));
            table.Columns.Add("Shipping Address", typeof(string));
            table.Columns.Add("Estimated Delivery Date", typeof(string));

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            // Generic paging: try common query params and common response shapes.
            int page = 1;
            const int pageSize = 1000;
            bool sawAnyItems = false;
            while (true)
            {
                // Build a flexible request path that includes several common page-size/query names.
                // If we have a last sync timestamp, include several common 'updated/created since' params
                string sinceQs = string.Empty;
                if (lastSyncUtc.HasValue)
                {
                    var iso = Uri.EscapeDataString(lastSyncUtc.Value.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"));
                    // include multiple common parameter names; upstream will ignore unknown ones
                    sinceQs = $"&updated_after={iso}&updatedAfter={iso}&created_after={iso}&createdAfter={iso}&since={iso}";
                }

                string reqPath = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders?api_key={Uri.EscapeDataString(apiKey)}&page_size={pageSize}&page={page}{sinceQs}";
                // Emit the request path for diagnostics so callers can inspect which page/URL is fetched
                //                 try { System.Diagnostics.Trace.TraceInformation($"SyncOrderListAsync requesting: {reqPath}"); } catch { }
                // #if DEBUG
                //                 try { System.Windows.Forms.MessageBox.Show(reqPath, "SyncOrderListAsync - reqPath", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                // #endif
                using var resp = await http.GetAsync(reqPath).ConfigureAwait(false);
                resp.EnsureSuccessStatusCode();
                var json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);

                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                JsonElement itemsElement = default;
                bool haveItems = false;

                if (root.ValueKind == JsonValueKind.Array)
                {
                    itemsElement = root;
                    haveItems = true;
                }
                else if (root.ValueKind == JsonValueKind.Object)
                {
                    if (root.TryGetProperty("data", out var dataProp) && dataProp.ValueKind == JsonValueKind.Array)
                    {
                        itemsElement = dataProp;
                        haveItems = true;
                    }
                    else if (root.TryGetProperty("orders", out var ordersProp) && ordersProp.ValueKind == JsonValueKind.Array)
                    {
                        itemsElement = ordersProp;
                        haveItems = true;
                    }
                    else
                    {
                        foreach (var p in root.EnumerateObject())
                        {
                            if (p.Value.ValueKind == JsonValueKind.Array)
                            {
                                itemsElement = p.Value;
                                haveItems = true;
                                break;
                            }
                        }
                    }
                }

                if (!haveItems)
                {
                    // Nothing on this page; stop paging
                    break;
                }

                int itemsThisPage = 0;

                // Process items for this page (reuse original parsing logic)
                foreach (var item in itemsElement.EnumerateArray())
                {
                    itemsThisPage++;
                    string GetFirstString(JsonElement el, params string[] names)
                    {
                        foreach (var n in names)
                        {
                            if (el.ValueKind == JsonValueKind.Object && el.TryGetProperty(n, out var v) && v.ValueKind != JsonValueKind.Null)
                                return v.ToString() ?? string.Empty;
                        }
                        return string.Empty;
                    }

                    string GetChangeFieldNewValue(JsonElement el, params string[] names)
                    {
                        foreach (var n in names)
                        {
                            if (el.ValueKind != JsonValueKind.Object || !el.TryGetProperty(n, out var v) || v.ValueKind == JsonValueKind.Null)
                                continue;

                            if (v.ValueKind == JsonValueKind.Object && v.TryGetProperty("new", out var newValue) && newValue.ValueKind != JsonValueKind.Null)
                                return newValue.ToString() ?? string.Empty;

                            return v.ToString() ?? string.Empty;
                        }

                        return string.Empty;
                    }

                    // Only include orders explicitly marked received_at_shop == "false"
                    try
                    {
                        string recFlag = GetFirstString(item, "received_at_shop", "receivedAtShop")?.Trim() ?? string.Empty;
                        if (!string.Equals(recFlag, "false", StringComparison.OrdinalIgnoreCase))
                        {
                            // skip orders that are not explicitly false
                            continue;
                        }
                    }
                    catch { }

                    string receipt = GetFirstString(item, "receipt_no", "receiptNo", "receipt", "id", "order_number", "number");
                    string trans = GetFirstString(item, "transaction_no", "transactionNo", "transaction", "transaction_id", "id");
                    // Prefer inserted_at when available, then created_at or other common timestamp fields
                    string created = GetFirstString(item, "inserted_at", "insertedAt", "created_at", "createdAt", "date", "created");

                    string customer = string.Empty;
                    if (item.ValueKind == JsonValueKind.Object)
                    {
                        if (item.TryGetProperty("customer", out var custProp) && custProp.ValueKind == JsonValueKind.Object)
                        {
                            customer = GetFirstString(custProp, "name", "customer_name", "full_name");
                        }
                        if (string.IsNullOrWhiteSpace(customer))
                            customer = GetFirstString(item, "customer_name", "customer", "client_name", "buyer_name");
                    }

                    string date = string.Empty, time = string.Empty;
                    if (!string.IsNullOrWhiteSpace(created) && TryParseApiTimestampUtc(created, out var createdUtc))
                    {
                        var createdLocal = ConvertUtcToBusinessLocal(createdUtc);
                        date = createdLocal.ToString("yyyy-MM-dd");
                        time = createdLocal.ToString("HH:mm:ss");
                    }
                    if (string.IsNullOrWhiteSpace(receipt)) receipt = trans;

                    // Money fields mapping
                    decimal moneyToCollect = 0m;
                    decimal amountPaid = 0m; // prepaid
                    decimal balance = 0m; // cod

                    string moneyStr = GetFirstString(item, "money_to_collect", "moneyToCollect", "total_price", "total", "amount", "money");
                    string prepaidStr = GetFirstString(item, "prepaid", "prepaid_amount", "pre_paid", "deposit", "prepayment");
                    string codStr = GetFirstString(item, "cod", "cash_on_delivery", "balance", "due", "amount_due");
                    // Discount, LastPaid and Status
                    string discountStr = GetFirstString(item, "discount", "discount_amount", "discounted_amount");
                    string statusStr = GetFirstString(item, "status_name", "status", "state", "order_status");
                    string lastPaidStr = GetFirstString(item, "last_paid_at", "lastPaidAt", "last_payment", "last_paid", "last_payment_at");
                    string lastUpdatedStr = GetFirstString(item, "updated_at", "updatedAt", "last_updated_at", "lastUpdatedAt");

                    // If we have a last sync timestamp, and the payload includes an updated_at timestamp,
                    // skip processing this order if it's not newer than the last sync. This avoids reprocessing
                    // unchanged orders and speeds up sync.
                    try
                    {
                        if (lastSyncUtc.HasValue && !string.IsNullOrWhiteSpace(lastUpdatedStr))
                        {
                            if (TryParseApiTimestampUtc(lastUpdatedStr, out var parsedLastUpdatedUtc))
                            {
                                if (parsedLastUpdatedUtc <= lastSyncUtc.Value)
                                {
                                    // upstream order wasn't updated since our last sync - skip it
                                    continue;
                                }
                            }
                        }
                    }
                    catch { /* silently continue processing if parsing/comparison fails */ }
                    // Optional upstream conversation/page identifiers
                    string pageIdStr = GetFirstString(item, "page_id", "pageId", "page");
                    string conversationIdStr = GetFirstString(item, "conversation_id", "conversationId", "conversation", "thread_id", "threadId");
                    // Map upstream warehouse_id to local LocationID
                    string locationIdStr = GetFirstString(item, "warehouse_id", "warehouseId");
                    string forDeliveryRaw = GetFirstString(item, "is_free_shipping", "isFreeShipping");
                    string shippingAddress = string.Empty;
                    string estimatedDeliveryDateStr = GetChangeFieldNewValue(item, "estimate_delivery_date", "estimated_delivery_date", "estimatedDeliveryDate", "delivery_date", "deliveryDate");
                    try
                    {
                        var normalizedEstimatedDeliveryDate = ParseApiDateToBusinessDate(estimatedDeliveryDateStr);
                        if (normalizedEstimatedDeliveryDate.HasValue)
                            estimatedDeliveryDateStr = normalizedEstimatedDeliveryDate.Value.ToString("yyyy-MM-dd");
                    }
                    catch { }

                    decimal ParseDecimal(string s)
                    {
                        if (string.IsNullOrWhiteSpace(s)) return 0m;
                        // Remove common currency characters and whitespace
                        var cleaned = s.Replace(",", string.Empty).Replace("$", string.Empty).Replace("€", string.Empty).Replace("₱", string.Empty).Trim();
                        // Try direct parse with invariant culture
                        if (decimal.TryParse(cleaned, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var v))
                            return v;
                        // Try parse with current culture as fallback
                        if (decimal.TryParse(cleaned, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out v))
                            return v;
                        // Last resort: extract digits and dot
                        var sb = new System.Text.StringBuilder();
                        foreach (char c in cleaned)
                        {
                            if (char.IsDigit(c) || c == '.' || c == '-') sb.Append(c);
                        }
                        if (decimal.TryParse(sb.ToString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out v))
                            return v;
                        return 0m;
                    }

                    bool ParseBoolean(string s)
                    {
                        if (string.IsNullOrWhiteSpace(s)) return false;

                        var cleaned = s.Trim();
                        if (bool.TryParse(cleaned, out var boolValue))
                            return boolValue;
                        if (int.TryParse(cleaned, out var intValue))
                            return intValue != 0;

                        return string.Equals(cleaned, "yes", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(cleaned, "y", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(cleaned, "on", StringComparison.OrdinalIgnoreCase);
                    }

                    // If fields are nested objects, prefer their amount properties
                    if (item.ValueKind == JsonValueKind.Object)
                    {
                        if (item.TryGetProperty("money_to_collect", out var mt) && mt.ValueKind == JsonValueKind.Object)
                            moneyStr = GetFirstString(mt, "amount", "value", "total");
                        if (item.TryGetProperty("prepaid", out var pp) && pp.ValueKind == JsonValueKind.Object)
                            prepaidStr = GetFirstString(pp, "amount", "value");
                        if (item.TryGetProperty("cod", out var cd) && cd.ValueKind == JsonValueKind.Object)
                            codStr = GetFirstString(cd, "amount", "value");
                    }

                    moneyToCollect = ParseDecimal(moneyStr);
                    amountPaid = ParseDecimal(prepaidStr);
                    balance = ParseDecimal(codStr);
                    bool forDelivery = ParseBoolean(forDeliveryRaw);

                    try
                    {
                        if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("is_free_shipping", out var freeShippingProp))
                        {
                            if (freeShippingProp.ValueKind == JsonValueKind.True) forDelivery = true;
                            else if (freeShippingProp.ValueKind == JsonValueKind.False) forDelivery = false;
                            else if (freeShippingProp.ValueKind == JsonValueKind.Number && freeShippingProp.TryGetInt32(out var freeShippingInt)) forDelivery = freeShippingInt != 0;
                        }
                    }
                    catch { }

                    try
                    {
                        if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("shipping_address", out var shippingAddressProp) && shippingAddressProp.ValueKind == JsonValueKind.Object)
                        {
                            shippingAddress = GetFirstString(shippingAddressProp, "full_address", "fullAddress", "address", "formatted_address", "formattedAddress");
                        }

                        if (string.IsNullOrWhiteSpace(shippingAddress))
                            shippingAddress = GetFirstString(item, "shipping_address_full", "shippingAddressFull", "full_address", "fullAddress");
                    }
                    catch { shippingAddress = string.Empty; }

                    decimal discount = ParseDecimal(discountStr);

                    string lastPaidDate = string.Empty, lastPaidTime = string.Empty;
                    if (!string.IsNullOrWhiteSpace(lastPaidStr) && TryParseApiTimestampUtc(lastPaidStr, out var lastPaidUtc))
                    {
                        var lastPaidLocal = ConvertUtcToBusinessLocal(lastPaidUtc);
                        lastPaidDate = lastPaidLocal.ToString("yyyy-MM-dd");
                        lastPaidTime = lastPaidLocal.ToString("HH:mm:ss");
                    }
                    else if (amountPaid > 0 && !string.IsNullOrWhiteSpace(date) && !string.IsNullOrWhiteSpace(time))
                    {
                        // Use created timestamp as last paid if prepaid present and no explicit lastPaid
                        lastPaidDate = date;
                        lastPaidTime = time;
                    }

                    // Normalize certain statuses: map 'submitted' -> 'Confirmed', 'packing' -> 'To Ship',
                    // 'pending' -> 'Pending Transfer', and shipped tokens -> 'Shipped'.
                    if (!string.IsNullOrWhiteSpace(statusStr))
                    {
                        var s = statusStr.Trim();
                        if (string.Equals(s, "submitted", StringComparison.OrdinalIgnoreCase))
                        {
                            statusStr = "Confirmed";
                        }
                        else if (string.Equals(s, "packing", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "packed", StringComparison.OrdinalIgnoreCase))
                        {
                            statusStr = "To Ship";
                        }
                        else if (string.Equals(s, "pending", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "9", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "pending_transfer", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "pending transfer", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "waiting_for_pickup", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "waiting for pickup", StringComparison.OrdinalIgnoreCase))
                        {
                            statusStr = "Pending Transfer";
                        }
                        else if (string.Equals(s, "12", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "wait_print", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "wait print", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "in_transit", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "in-transit", StringComparison.OrdinalIgnoreCase))
                        {
                            statusStr = "In-Transit";
                        }
                        else if (string.Equals(s, "shipped", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "delivered", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "2", StringComparison.OrdinalIgnoreCase))
                        {
                            statusStr = "Shipped";
                        }
                        else if (string.Equals(s, "received", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(s, "3", StringComparison.OrdinalIgnoreCase))
                        {
                            statusStr = "Received";
                        }
                        else if (string.Equals(s, "Printed", StringComparison.OrdinalIgnoreCase))
                        {
                            statusStr = "Printed";
                        }
                    }

                    // First column is OrderID (was ReceiptNo previously)
                    // Sync all orders except those whose upstream status is 'New'
                    // Keep lastUpdated as the raw string from payload; DB layer will parse into DATETIME when persisting
                    var st = statusStr?.Trim();
                    if (string.Equals(st, "new", StringComparison.OrdinalIgnoreCase))
                    {
                        // skip NEW orders
                        continue;
                    }

                    table.Rows.Add(receipt ?? string.Empty, trans ?? string.Empty, date, time, customer ?? string.Empty, statusStr ?? string.Empty, pageIdStr ?? string.Empty, conversationIdStr ?? string.Empty, locationIdStr ?? string.Empty, moneyToCollect, amountPaid, balance, discount, lastUpdatedStr ?? string.Empty, lastPaidDate, lastPaidTime, forDelivery, shippingAddress ?? string.Empty, estimatedDeliveryDateStr ?? string.Empty);
                }

                sawAnyItems = sawAnyItems || itemsThisPage > 0;

                // Attempt to detect whether more pages exist using common metadata shapes
                bool hasNext = false;
                if (root.ValueKind == JsonValueKind.Object)
                {
                    if (root.TryGetProperty("next", out var nextProp) && nextProp.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(nextProp.GetString()))
                    {
                        // some APIs return a URL to the next page
                        var nextUrl = nextProp.GetString();
                        if (!string.IsNullOrWhiteSpace(nextUrl))
                        {
                            // If nextUrl is absolute, perform a direct request next iteration by updating http.BaseAddress is not needed;
                            // we'll simply increment page and continue as a fallback. Prefer numeric/page-based pagination below.
                            hasNext = true;
                        }
                    }

                    if (!hasNext && root.TryGetProperty("meta", out var meta) && meta.ValueKind == JsonValueKind.Object)
                    {
                        if (meta.TryGetProperty("has_more", out var hm) && hm.ValueKind == JsonValueKind.True) hasNext = true;
                        else if (meta.TryGetProperty("next_page", out var np) && (np.ValueKind == JsonValueKind.Number || np.ValueKind == JsonValueKind.String))
                        {
                            // If next_page is numeric, set page accordingly
                            if (np.ValueKind == JsonValueKind.Number && np.TryGetInt32(out var nextIdx)) { page = nextIdx; hasNext = true; }
                            else if (np.ValueKind == JsonValueKind.String && int.TryParse(np.GetString(), out var nextIdx2)) { page = nextIdx2; hasNext = true; }
                        }
                        else if (meta.TryGetProperty("total_pages", out var tp) && tp.ValueKind == JsonValueKind.Number && tp.TryGetInt32(out var totalPages))
                        {
                            if (page < totalPages) hasNext = true;
                        }
                    }
                }

                // Fallback: if the page returned fewer items than pageSize, assume we've reached the end
                if (!hasNext)
                {
                    if (itemsThisPage >= pageSize)
                    {
                        // likely more pages, continue by incrementing
                        hasNext = true;
                    }
                }

                if (!hasNext) break;

                // If meta provided a next page numeric value we already set 'page'; otherwise increment
                page++;
            }

            // If no items were found at all, return empty table early
            if (!sawAnyItems)
            {
                return table;
            }



            // Track orders whose status transitions into specific states during this sync
            var newlyCanceledOrderIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var newlyConfirmedOrderIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);

            // Persist into OnlineOrderHeader table (create if not exists)
            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();

                    // Create table if not exists and ensure LocationID column is present
                    string createSql = @"
                        IF OBJECT_ID('dbo.OnlineOrderHeader', 'U') IS NULL
                        BEGIN
                            CREATE TABLE dbo.OnlineOrderHeader (
                                OrderID NVARCHAR(100) NOT NULL PRIMARY KEY,
                                Date DATE NULL,
                                Time NVARCHAR(12) NULL,
                                                Status NVARCHAR(100) NULL,
                                CustomerName NVARCHAR(200) NULL,
                                Page_ID NVARCHAR(200) NULL,
                                Conversation_ID NVARCHAR(200) NULL,
                                LocationID NVARCHAR(200) NULL,
                                MoneyToCollect DECIMAL(18,2) NULL,
                                AmountPaid DECIMAL(18,2) NULL,
                                Discount DECIMAL(18,2) NULL,
                                Balance DECIMAL(18,2) NULL,
                                [For Delivery] BIT NOT NULL DEFAULT 0,
                                [Shipping Address] NVARCHAR(1000) NULL,
                                [Estimated Delivery Date] DATE NULL,
                                PrintCount INT NOT NULL DEFAULT 0,
                                Last_Updated_At DATETIME2 NULL,
                                Converted_LastUpdated_At DATE NULL,
                                LastPaid_Date DATE NULL,
                                LastPaid_Time NVARCHAR(12) NULL
                            )
                        END
                        IF COL_LENGTH('dbo.OnlineOrderHeader', 'LocationID') IS NULL
                        BEGIN
                            ALTER TABLE dbo.OnlineOrderHeader ADD LocationID NVARCHAR(200) NULL
                        END
                        IF COL_LENGTH('dbo.OnlineOrderHeader', 'PrintCount') IS NULL
                        BEGIN
                            ALTER TABLE dbo.OnlineOrderHeader ADD PrintCount INT NOT NULL CONSTRAINT DF_OnlineOrderHeader_PrintCount DEFAULT (0)
                        END
                        IF COL_LENGTH('dbo.OnlineOrderHeader', 'For Delivery') IS NULL
                        BEGIN
                            ALTER TABLE dbo.OnlineOrderHeader ADD [For Delivery] BIT NOT NULL CONSTRAINT DF_OnlineOrderHeader_ForDelivery DEFAULT (0)
                        END
                        IF COL_LENGTH('dbo.OnlineOrderHeader', 'Shipping Address') IS NULL
                        BEGIN
                            ALTER TABLE dbo.OnlineOrderHeader ADD [Shipping Address] NVARCHAR(1000) NULL
                        END
                        IF COL_LENGTH('dbo.OnlineOrderHeader', 'Estimated Delivery Date') IS NULL
                        BEGIN
                            ALTER TABLE dbo.OnlineOrderHeader ADD [Estimated Delivery Date] DATE NULL
                        END
                        ";
                    using (var createCmd = new SqlCommand(createSql, conn))
                        createCmd.ExecuteNonQuery();

                    using (var tran = conn.BeginTransaction())
                    {
                        foreach (DataRow r in table.Rows)
                        {

                            string orderId = (r["OrderID"] as string) ?? string.Empty;
                            string d = (r["Date"] as string) ?? string.Empty;
                            string t = (r["Time"] as string) ?? string.Empty;
                            string cust = (r["CustomerName"] as string) ?? string.Empty;
                            decimal mtc = r["MoneyToCollect"] is DBNull ? 0m : Convert.ToDecimal(r["MoneyToCollect"]);
                            decimal ap = r["AmountPaid"] is DBNull ? 0m : Convert.ToDecimal(r["AmountPaid"]);
                            decimal bal = r["Balance"] is DBNull ? 0m : Convert.ToDecimal(r["Balance"]);
                            decimal disc = r.Table.Columns.Contains("Discount") && r["Discount"] is not DBNull ? Convert.ToDecimal(r["Discount"]) : 0m;
                            string lastUpdated = r.Table.Columns.Contains("Last_Updated_At") ? (r["Last_Updated_At"] as string ?? string.Empty) : string.Empty;
                            // Parse lastUpdated into DateTime and also compute the converted date (date-only) for storage
                            DateTime? lastUpdatedDt = null;
                            DateTime? convertedLastUpdatedDate = null;
                            try
                            {
                                if (!string.IsNullOrWhiteSpace(lastUpdated) && TryParseApiTimestampUtc(lastUpdated, out var parsedLastUpdatedUtc))
                                {
                                    lastUpdatedDt = parsedLastUpdatedUtc;
                                    convertedLastUpdatedDate = ConvertUtcToBusinessLocal(parsedLastUpdatedUtc).Date;
                                }
                            }
                            catch { lastUpdatedDt = null; convertedLastUpdatedDate = null; }
                            string lpDate = r.Table.Columns.Contains("LastPaid_Date") ? (r["LastPaid_Date"] as string ?? string.Empty) : string.Empty;
                            string lpTime = r.Table.Columns.Contains("LastPaid_Time") ? (r["LastPaid_Time"] as string ?? string.Empty) : string.Empty;
                            string status = r.Table.Columns.Contains("Status") ? (r["Status"] as string ?? string.Empty) : string.Empty;
                            string pageId = r.Table.Columns.Contains("Page_ID") ? (r["Page_ID"] as string ?? string.Empty) : string.Empty;
                            string conversationId = r.Table.Columns.Contains("Conversation_ID") ? (r["Conversation_ID"] as string ?? string.Empty) : string.Empty;
                            string locationId = r.Table.Columns.Contains("LocationID") ? (r["LocationID"] as string ?? string.Empty) : string.Empty;
                            bool forDelivery = r.Table.Columns.Contains("For Delivery") && r["For Delivery"] is not DBNull && Convert.ToBoolean(r["For Delivery"]);
                            string shippingAddress = r.Table.Columns.Contains("Shipping Address") ? (r["Shipping Address"] as string ?? string.Empty) : string.Empty;
                            string estimatedDeliveryDateRaw = r.Table.Columns.Contains("Estimated Delivery Date") ? (r["Estimated Delivery Date"] as string ?? string.Empty) : string.Empty;
                            DateTime? estimatedDeliveryDate = null;
                            try
                            {
                                estimatedDeliveryDate = ParseApiDateToBusinessDate(estimatedDeliveryDateRaw);
                            }
                            catch { estimatedDeliveryDate = null; }

                            // Read previous status so we can detect a transition into a canceled state
                            string previousStatus = string.Empty;
                            bool existedBefore = false;
                            try
                            {
                                using (var sel = new SqlCommand("SELECT Status FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", conn, tran))
                                {
                                    sel.Parameters.AddWithValue("@OrderID", orderId);
                                    var prev = sel.ExecuteScalar();
                                    if (prev != null && prev != DBNull.Value)
                                    {
                                        previousStatus = prev.ToString() ?? string.Empty;
                                        existedBefore = true;
                                    }
                                }
                            }
                            catch
                            {
                                previousStatus = string.Empty;
                                existedBefore = false;
                            }

                            // Try update
                            string updateSql = @"UPDATE dbo.OnlineOrderHeader SET Date=@Date, Time=@Time, CustomerName=@CustomerName, Status=@Status, Page_ID=@Page_ID, Conversation_ID=@Conversation_ID, LocationID=@LocationID, MoneyToCollect=@MoneyToCollect, AmountPaid=@AmountPaid, Discount=@Discount, Balance=@Balance, [For Delivery]=@ForDelivery, [Shipping Address]=@ShippingAddress, [Estimated Delivery Date]=@EstimatedDeliveryDate, Last_Updated_At=@LastUpdatedAt, Converted_LastUpdated_At=@ConvertedLastUpdated, LastPaid_Date=@LastPaidDate, LastPaid_Time=@LastPaidTime WHERE OrderID=@OrderID";
                            using (var upCmd = new SqlCommand(updateSql, conn, tran))
                            {
                                upCmd.Parameters.AddWithValue("@Date", string.IsNullOrWhiteSpace(d) ? (object)DBNull.Value : DateTime.Parse(d));
                                upCmd.Parameters.AddWithValue("@Time", string.IsNullOrWhiteSpace(t) ? (object)DBNull.Value : (object)t);
                                upCmd.Parameters.AddWithValue("@CustomerName", string.IsNullOrWhiteSpace(cust) ? (object)DBNull.Value : (object)cust);
                                upCmd.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(status) ? (object)DBNull.Value : (object)status);
                                upCmd.Parameters.AddWithValue("@Page_ID", string.IsNullOrWhiteSpace(pageId) ? (object)DBNull.Value : (object)pageId);
                                upCmd.Parameters.AddWithValue("@Conversation_ID", string.IsNullOrWhiteSpace(conversationId) ? (object)DBNull.Value : (object)conversationId);
                                upCmd.Parameters.AddWithValue("@LocationID", string.IsNullOrWhiteSpace(locationId) ? (object)DBNull.Value : (object)locationId);
                                upCmd.Parameters.AddWithValue("@MoneyToCollect", mtc);
                                upCmd.Parameters.AddWithValue("@AmountPaid", ap);
                                upCmd.Parameters.AddWithValue("@Discount", disc);
                                upCmd.Parameters.AddWithValue("@Balance", bal);
                                upCmd.Parameters.AddWithValue("@ForDelivery", forDelivery);
                                upCmd.Parameters.AddWithValue("@ShippingAddress", string.IsNullOrWhiteSpace(shippingAddress) ? (object)DBNull.Value : shippingAddress);
                                upCmd.Parameters.AddWithValue("@EstimatedDeliveryDate", estimatedDeliveryDate.HasValue ? (object)estimatedDeliveryDate.Value : (object)DBNull.Value);
                                upCmd.Parameters.AddWithValue("@LastUpdatedAt", lastUpdatedDt.HasValue ? (object)lastUpdatedDt.Value : (object)DBNull.Value);
                                upCmd.Parameters.AddWithValue("@ConvertedLastUpdated", convertedLastUpdatedDate.HasValue ? (object)convertedLastUpdatedDate.Value : (object)DBNull.Value);
                                upCmd.Parameters.AddWithValue("@LastPaidDate", string.IsNullOrWhiteSpace(lpDate) ? (object)DBNull.Value : DateTime.Parse(lpDate));
                                upCmd.Parameters.AddWithValue("@LastPaidTime", string.IsNullOrWhiteSpace(lpTime) ? (object)DBNull.Value : (object)lpTime);
                                upCmd.Parameters.AddWithValue("@OrderID", orderId);

                                int affected = upCmd.ExecuteNonQuery();
                                if (affected == 0)
                                {
                                    string insertSql = @"INSERT INTO dbo.OnlineOrderHeader (OrderID, Date, Time, CustomerName, Status, Page_ID, Conversation_ID, LocationID, MoneyToCollect, AmountPaid, Discount, Balance, [For Delivery], [Shipping Address], [Estimated Delivery Date], Last_Updated_At, Converted_LastUpdated_At, LastPaid_Date, LastPaid_Time) VALUES (@ORDERIDPLACEHOLDER, @Date, @Time, @CustomerName, @Status, @Page_ID, @Conversation_ID, @LocationID, @MoneyToCollect, @AmountPaid, @Discount, @Balance, @ForDelivery, @ShippingAddress, @EstimatedDeliveryDate, @LastUpdatedAt, @ConvertedLastUpdated, @LastPaidDate, @LastPaidTime)";
                                    insertSql = insertSql.Replace("@ORDERIDPLACEHOLDER", "@OrderID");
                                    using (var insCmd = new SqlCommand(insertSql, conn, tran))
                                    {
                                        insCmd.Parameters.AddWithValue("@OrderID", orderId);
                                        insCmd.Parameters.AddWithValue("@Date", string.IsNullOrWhiteSpace(d) ? (object)DBNull.Value : DateTime.Parse(d));
                                        insCmd.Parameters.AddWithValue("@Time", string.IsNullOrWhiteSpace(t) ? (object)DBNull.Value : (object)t);
                                        insCmd.Parameters.AddWithValue("@CustomerName", string.IsNullOrWhiteSpace(cust) ? (object)DBNull.Value : (object)cust);
                                        insCmd.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(status) ? (object)DBNull.Value : (object)status);
                                        insCmd.Parameters.AddWithValue("@Page_ID", string.IsNullOrWhiteSpace(pageId) ? (object)DBNull.Value : (object)pageId);
                                        insCmd.Parameters.AddWithValue("@Conversation_ID", string.IsNullOrWhiteSpace(conversationId) ? (object)DBNull.Value : (object)conversationId);
                                        insCmd.Parameters.AddWithValue("@LocationID", string.IsNullOrWhiteSpace(locationId) ? (object)DBNull.Value : (object)locationId);
                                        insCmd.Parameters.AddWithValue("@MoneyToCollect", mtc);
                                        insCmd.Parameters.AddWithValue("@AmountPaid", ap);
                                        insCmd.Parameters.AddWithValue("@Discount", disc);
                                        insCmd.Parameters.AddWithValue("@Balance", bal);
                                        insCmd.Parameters.AddWithValue("@ForDelivery", forDelivery);
                                        insCmd.Parameters.AddWithValue("@ShippingAddress", string.IsNullOrWhiteSpace(shippingAddress) ? (object)DBNull.Value : shippingAddress);
                                        insCmd.Parameters.AddWithValue("@EstimatedDeliveryDate", estimatedDeliveryDate.HasValue ? (object)estimatedDeliveryDate.Value : (object)DBNull.Value);
                                        insCmd.Parameters.AddWithValue("@LastUpdatedAt", lastUpdatedDt.HasValue ? (object)lastUpdatedDt.Value : (object)DBNull.Value);
                                        insCmd.Parameters.AddWithValue("@ConvertedLastUpdated", convertedLastUpdatedDate.HasValue ? (object)convertedLastUpdatedDate.Value : (object)DBNull.Value);
                                        insCmd.Parameters.AddWithValue("@LastPaidDate", string.IsNullOrWhiteSpace(lpDate) ? (object)DBNull.Value : DateTime.Parse(lpDate));
                                        insCmd.Parameters.AddWithValue("@LastPaidTime", string.IsNullOrWhiteSpace(lpTime) ? (object)DBNull.Value : (object)lpTime);
                                        insCmd.ExecuteNonQuery();
                                    }
                                }

                                // If an order is newly inserted in a canceled/Confirmed state,
                                // or an existing order transitions into those states, queue it
                                // for inventory movement. This ensures new Confirmed orders also
                                // post inventory, without double-posting on later syncs.
                                bool oldIsCanceled = string.Equals(previousStatus, "canceled", StringComparison.OrdinalIgnoreCase) ||
                                                     string.Equals(previousStatus, "cancelled", StringComparison.OrdinalIgnoreCase);
                                bool newIsCanceled = string.Equals(status, "canceled", StringComparison.OrdinalIgnoreCase) ||
                                                     string.Equals(status, "cancelled", StringComparison.OrdinalIgnoreCase);

                                bool oldIsConfirmed = string.Equals(previousStatus, "Confirmed", StringComparison.OrdinalIgnoreCase);
                                bool newIsConfirmed = string.Equals(status, "Confirmed", StringComparison.OrdinalIgnoreCase);

                                if (!string.IsNullOrWhiteSpace(orderId))
                                {
                                    // Newly inserted canceled OR transition into canceled
                                    if (newIsCanceled && (!existedBefore || !oldIsCanceled))
                                    {
                                        newlyCanceledOrderIds.Add(orderId);
                                    }

                                    // Newly inserted Confirmed OR transition into Confirmed
                                    if (newIsConfirmed && (!existedBefore || !oldIsConfirmed))
                                    {
                                        newlyConfirmedOrderIds.Add(orderId);
                                    }
                                }
                                // Fetch and persist order lines immediately so orderlines are updated at once
                                try
                                {
                                    var fetchedLines = await FetchOrderLinesAsync(orderId).ConfigureAwait(false);
                                    if (fetchedLines != null && fetchedLines.Rows.Count > 0)
                                    {
                                        foreach (DataRow lr2 in fetchedLines.Rows)
                                        {
                                            string lineId2 = lr2.Table.Columns.Contains("LineID") ? (lr2["LineID"] as string ?? string.Empty) : string.Empty;
                                            string product_display2 = lr2.Table.Columns.Contains("product_display_id") ? (lr2["product_display_id"] as string ?? string.Empty) : string.Empty;
                                            string variationId2 = lr2.Table.Columns.Contains("VariationId") ? (lr2["VariationId"] as string ?? string.Empty) : string.Empty;
                                            decimal qty2 = lr2.Table.Columns.Contains("Quantity") && lr2["Quantity"] is not DBNull ? Convert.ToDecimal(lr2["Quantity"]) : 0m;
                                            decimal? unitCost2 = lr2.Table.Columns.Contains("UnitCost") && lr2["UnitCost"] is not DBNull ? Convert.ToDecimal(lr2["UnitCost"]) : (decimal?)null;
                                            decimal price2 = lr2.Table.Columns.Contains("Price") && lr2["Price"] is not DBNull ? Convert.ToDecimal(lr2["Price"]) : 0m;
                                            string note2 = lr2.Table.Columns.Contains("Note") ? (lr2["Note"] as string ?? string.Empty) : string.Empty;
                                            string desc2 = lr2.Table.Columns.Contains("Description") ? (lr2["Description"] as string ?? string.Empty) : string.Empty;
                                            try { WriteintoOnlineOrderLines(orderId, lineId2, product_display2, qty2, unitCost2, price2, note2, desc2, variationId2); } catch { }
                                        }
                                    }
                                }
                                catch { }


                            }
                        }
                        tran.Commit();
                    }
                }
            }
            catch (Exception ex)
            {
                // Surface DB connection/SQL errors to caller so the UI can notify the user.
                try { System.Diagnostics.Trace.TraceError($"SyncOrderListAsync - OnlineOrderHeader persistence failed: {ex}"); } catch { }
                throw new InvalidOperationException("Database error while persisting online order headers. See inner exception for details.", ex);
            }

            // Persist order lines for each fetched order (separate try so header persistence doesn't block lines)
            try
            {
                using (var conn2 = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn2.Open();

                    string createLinesSql = @"
                            IF OBJECT_ID('dbo.OnlineOrderLines', 'U') IS NULL
                            BEGIN
                                CREATE TABLE dbo.OnlineOrderLines (
                                    OrderID NVARCHAR(100) NOT NULL,
                                    LineID NVARCHAR(100) NOT NULL,
                                    ItemCode NVARCHAR(200) NULL,
                                    product_display_id NVARCHAR(200) NULL,
                                    VariationId NVARCHAR(200) NULL,
                                    Quantity DECIMAL(18,2) NULL,
                                    UnitCost DECIMAL(18,2) NULL,
                                    Price DECIMAL(18,2) NULL,
                                    Discount DECIMAL(18,2) NULL,
                                    GrossAmount DECIMAL(18,2) NULL,
                                    NetAmount DECIMAL(18,2) NULL,
                                    CONSTRAINT PK_OnlineOrderLines PRIMARY KEY (OrderID, LineID)
                                )
                            END
                            ";
                    using (var createCmd2 = new SqlCommand(createLinesSql, conn2))
                        createCmd2.ExecuteNonQuery();

                    using (var tran2 = conn2.BeginTransaction())
                    {
                        foreach (DataRow r in table.Rows)
                        {
                            string orderId = (r["OrderID"] as string) ?? string.Empty;
                            if (string.IsNullOrWhiteSpace(orderId)) continue;

                            DataTable? lines = null;
                            try
                            {
                                lines = await FetchOrderLinesAsync(orderId).ConfigureAwait(false);
                            }
                            catch
                            {
                                lines = null;
                            }

                            if (lines == null || lines.Rows.Count == 0) continue;

                            foreach (DataRow lr in lines.Rows)
                            {
                                string lineId = lr.Table.Columns.Contains("LineID") ? (lr["LineID"] as string ?? string.Empty) : string.Empty;
                                string product_display = lr.Table.Columns.Contains("product_display_id") ? (lr["product_display_id"] as string ?? string.Empty) : string.Empty;
                                string variationId = lr.Table.Columns.Contains("VariationId") ? (lr["VariationId"] as string ?? string.Empty) : string.Empty;
                                string itemCode = product_display;
                                decimal qty = lr.Table.Columns.Contains("Quantity") && lr["Quantity"] is not DBNull ? Convert.ToDecimal(lr["Quantity"]) : 0m;
                                // UnitCost per mapping should be null if not provided
                                object unitCostDb = (lr.Table.Columns.Contains("UnitCost") && lr["UnitCost"] is not DBNull) ? (object)Convert.ToDecimal(lr["UnitCost"]) : (object)DBNull.Value;
                                decimal price = lr.Table.Columns.Contains("Price") && lr["Price"] is not DBNull ? Convert.ToDecimal(lr["Price"]) : 0m;
                                decimal discount = lr.Table.Columns.Contains("Discount") && lr["Discount"] is not DBNull ? Convert.ToDecimal(lr["Discount"]) : 0m;
                                // Compute gross as price * qty per mapping if not provided
                                decimal gross = lr.Table.Columns.Contains("GrossAmount") && lr["GrossAmount"] is not DBNull ? Convert.ToDecimal(lr["GrossAmount"]) : (price * qty);
                                decimal net = lr.Table.Columns.Contains("NetAmount") && lr["NetAmount"] is not DBNull ? Convert.ToDecimal(lr["NetAmount"]) : 0m;

                                string updateLinesSql = @"UPDATE dbo.OnlineOrderLines SET ItemCode=@ItemCode, product_display_id=@product_display_id, VariationId=@VariationId, Quantity=@Quantity, UnitCost=@UnitCost, Price=@Price, Discount=@Discount, GrossAmount=@GrossAmount, NetAmount=@NetAmount WHERE OrderID=@OrderID AND LineID=@LineID";
                                using (var upCmd = new SqlCommand(updateLinesSql, conn2, tran2))
                                {
                                    upCmd.Parameters.AddWithValue("@ItemCode", string.IsNullOrWhiteSpace(itemCode) ? (object)DBNull.Value : (object)itemCode);
                                    upCmd.Parameters.AddWithValue("@product_display_id", string.IsNullOrWhiteSpace(product_display) ? (object)DBNull.Value : (object)product_display);
                                    upCmd.Parameters.AddWithValue("@VariationId", string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : (object)variationId);
                                    upCmd.Parameters.AddWithValue("@Quantity", qty);
                                    upCmd.Parameters.AddWithValue("@UnitCost", unitCostDb);
                                    upCmd.Parameters.AddWithValue("@Price", price);
                                    upCmd.Parameters.AddWithValue("@Discount", discount);
                                    upCmd.Parameters.AddWithValue("@GrossAmount", gross);
                                    upCmd.Parameters.AddWithValue("@NetAmount", net);
                                    upCmd.Parameters.AddWithValue("@OrderID", orderId);
                                    upCmd.Parameters.AddWithValue("@LineID", lineId);

                                    int affected = upCmd.ExecuteNonQuery();
                                    if (affected == 0)
                                    {
                                        string insertLinesSql = @"INSERT INTO dbo.OnlineOrderLines (OrderID, LineID, ItemCode, product_display_id, VariationId, Quantity, UnitCost, Price, Discount, GrossAmount, NetAmount) VALUES (@OrderID, @LineID, @ItemCode, @product_display_id, @VariationId, @Quantity, @UnitCost, @Price, @Discount, @GrossAmount, @NetAmount)";
                                        using (var insCmd = new SqlCommand(insertLinesSql, conn2, tran2))
                                        {
                                            insCmd.Parameters.AddWithValue("@OrderID", orderId);
                                            insCmd.Parameters.AddWithValue("@LineID", lineId);
                                            insCmd.Parameters.AddWithValue("@ItemCode", string.IsNullOrWhiteSpace(itemCode) ? (object)DBNull.Value : (object)itemCode);
                                            insCmd.Parameters.AddWithValue("@product_display_id", string.IsNullOrWhiteSpace(product_display) ? (object)DBNull.Value : (object)product_display);
                                            insCmd.Parameters.AddWithValue("@VariationId", string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : (object)variationId);
                                            insCmd.Parameters.AddWithValue("@Quantity", qty);
                                            insCmd.Parameters.AddWithValue("@UnitCost", unitCostDb);
                                            insCmd.Parameters.AddWithValue("@Price", price);
                                            insCmd.Parameters.AddWithValue("@Discount", discount);
                                            insCmd.Parameters.AddWithValue("@GrossAmount", gross);
                                            insCmd.Parameters.AddWithValue("@NetAmount", net);
                                            insCmd.ExecuteNonQuery();
                                        }
                                    }
                                }
                            }
                        }

                        tran2.Commit();
                    }
                }
            }
            catch (Exception ex)
            {
                // Surface DB connection/SQL errors to caller so the UI can notify the user.
                try { System.Diagnostics.Trace.TraceError($"SyncOrderListAsync - OnlineOrderLines persistence failed: {ex}"); } catch { }
                throw new InvalidOperationException("Database error while persisting online order lines. See inner exception for details.", ex);
            }

            // For orders that became canceled during this sync, apply local inventory movement once their lines are persisted
            if (newlyCanceledOrderIds.Count > 0)
            {
                try
                {
                    using (var invConn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        invConn.Open();
                        foreach (var canceledOrderId in newlyCanceledOrderIds)
                        {
                            try
                            {
                                using (var invCmd = new SqlCommand("SELECT product_display_id, Quantity, Price, Discount FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID", invConn))
                                {
                                    invCmd.Parameters.AddWithValue("@OrderID", canceledOrderId);
                                    using (var reader = invCmd.ExecuteReader())
                                    {
                                        while (reader.Read())
                                        {
                                            string variationId = string.Empty;
                                            decimal lineQty = 0m;
                                            try
                                            {
                                                variationId = reader["product_display_id"]?.ToString() ?? string.Empty;
                                            }
                                            catch { variationId = string.Empty; }

                                            try
                                            {
                                                if (reader["Quantity"] != DBNull.Value)
                                                    lineQty = Convert.ToDecimal(reader["Quantity"]);
                                            }
                                            catch { lineQty = 0m; }

                                            decimal linePrice = 0m;
                                            decimal lineDiscount = 0m;
                                            try
                                            {
                                                if (reader["Price"] != DBNull.Value)
                                                    linePrice = Convert.ToDecimal(reader["Price"]);
                                            }
                                            catch { linePrice = 0m; }

                                            try
                                            {
                                                if (reader["Discount"] != DBNull.Value)
                                                    lineDiscount = Convert.ToDecimal(reader["Discount"]);
                                            }
                                            catch { lineDiscount = 0m; }

                                            if (!string.IsNullOrWhiteSpace(variationId) && lineQty != 0m)
                                            {
                                                try { LocalInventoryMovement(canceledOrderId, variationId, lineQty, "canceled", linePrice, lineDiscount); } catch { }
                                            }
                                        }
                                    }
                                }
                            }
                            catch (Exception orderEx)
                            {
                                try { System.Diagnostics.Trace.TraceError($"SyncOrderListAsync - inventory movement failed for canceled order {canceledOrderId}: {orderEx}"); } catch { }
                            }
                        }
                    }
                }
                catch (Exception invRootEx)
                {
                    try { System.Diagnostics.Trace.TraceError($"SyncOrderListAsync - inventory movement batch failed: {invRootEx}"); } catch { }
                }
            }

            // For orders that became Confirmed during this sync, apply local inventory movement (sales) once their lines are persisted
            if (newlyConfirmedOrderIds.Count > 0)
            {
                try
                {
                    using (var invConn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        invConn.Open();
                        foreach (var confirmedOrderId in newlyConfirmedOrderIds)
                        {
                            try
                            {
                                using (var invCmd = new SqlCommand("SELECT product_display_id, Quantity, Price, Discount FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID", invConn))
                                {
                                    invCmd.Parameters.AddWithValue("@OrderID", confirmedOrderId);
                                    using (var reader = invCmd.ExecuteReader())
                                    {
                                        while (reader.Read())
                                        {
                                            string variationId = string.Empty;
                                            decimal lineQty = 0m;
                                            try
                                            {
                                                variationId = reader["product_display_id"]?.ToString() ?? string.Empty;
                                            }
                                            catch { variationId = string.Empty; }

                                            try
                                            {
                                                if (reader["Quantity"] != DBNull.Value)
                                                    lineQty = Convert.ToDecimal(reader["Quantity"]);
                                            }
                                            catch { lineQty = 0m; }

                                            decimal linePrice = 0m;
                                            decimal lineDiscount = 0m;
                                            try
                                            {
                                                if (reader["Price"] != DBNull.Value)
                                                    linePrice = Convert.ToDecimal(reader["Price"]);
                                            }
                                            catch { linePrice = 0m; }

                                            try
                                            {
                                                if (reader["Discount"] != DBNull.Value)
                                                    lineDiscount = Convert.ToDecimal(reader["Discount"]);
                                            }
                                            catch { lineDiscount = 0m; }

                                            if (!string.IsNullOrWhiteSpace(variationId) && lineQty != 0m)
                                            {
                                                try { LocalInventoryMovement(confirmedOrderId, variationId, lineQty, "Confirmed", linePrice, lineDiscount); } catch { }
                                            }
                                        }
                                    }
                                }
                            }
                            catch (Exception orderEx)
                            {
                                try { System.Diagnostics.Trace.TraceError($"SyncOrderListAsync - inventory movement failed for confirmed order {confirmedOrderId}: {orderEx}"); } catch { }
                            }
                        }
                    }
                }
                catch (Exception invRootEx)
                {
                    try { System.Diagnostics.Trace.TraceError($"SyncOrderListAsync - inventory movement batch (confirmed) failed: {invRootEx}"); } catch { }
                }
            }

            // Persist last sync timestamp so subsequent runs can request only new/updated orders
            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();
                    using (var ins = new SqlCommand("INSERT INTO dbo.OnlineOrderSync (LastSyncUtc) VALUES (@Last)", conn))
                    {
                        ins.Parameters.AddWithValue("@Last", DateTime.UtcNow);
                        ins.ExecuteNonQuery();
                    }
                }
            }
            catch { }

            return table;
        }

        /// <summary>
        /// Placeholder for local inventory movement logic related to online integrations.
        /// Implement this to record inventory movements in local tables (e.g. ItemLedgerEntry)
        /// when processing or fulfilling online orders.
        /// </summary>
        /// <param name="orderId">Online order identifier used to build local DocumentNo.</param>
        /// <param name="variationId">Online product variation identifier.</param>
        /// <param name="qty">Quantity to move (positive or negative).</param>
        /// <param name="onlineStatus">Online status or reason for the movement.</param>
        /// <param name="price">Retail price from online (used for Price/Gross/Net).</param>
        /// <param name="discount">Discount amount from online (per line).</param>
        public static void LocalInventoryMovement(string orderId, string variationId, decimal qty, string onlineStatus, decimal price, decimal discount)
        {
            // Basic validation
            if (string.IsNullOrWhiteSpace(variationId)) return;
            if (qty == 0) return;

            string normalizedStatus = (onlineStatus ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(normalizedStatus)) return;

            // Determine document type and quantity sign based on online status
            string documentType;
            decimal movementQty;

            if (string.Equals(normalizedStatus, "Confirmed", StringComparison.OrdinalIgnoreCase))
            {
                // Outbound movement: sale
                documentType = "SALES";
                movementQty = -Math.Abs(qty); // deduct stock
            }
            else if (string.Equals(normalizedStatus, "canceled", StringComparison.OrdinalIgnoreCase) ||
                     string.Equals(normalizedStatus, "cancelled", StringComparison.OrdinalIgnoreCase))
            {
                // Inbound movement: return/cancellation
                documentType = "Return";
                movementQty = Math.Abs(qty); // add stock back
            }
            else
            {
                // For now only handle Confirmed / canceled states
                return;
            }

            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();
                    using (var tx = conn.BeginTransaction())
                    {
                        try
                        {
                            string itemCode = string.Empty;
                            decimal unitCost = 0m;
                            string itemDescription = string.Empty;

                            // Try to resolve local item by VariationId first, then by Code as fallback
                            using (var cmd = new SqlCommand(@"SELECT TOP 1 Code, ISNULL(Cost, 0), ISNULL(Description, '') FROM Items WHERE VariationId = @variationId OR Code = @variationId", conn, tx))
                            {
                                cmd.Parameters.AddWithValue("@variationId", variationId);
                                using (var reader = cmd.ExecuteReader())
                                {
                                    if (reader.Read())
                                    {
                                        itemCode = reader.GetString(0);
                                        unitCost = reader.IsDBNull(1) ? 0m : reader.GetDecimal(1);
                                        itemDescription = reader.IsDBNull(2) ? string.Empty : reader.GetString(2);
                                    }
                                }
                            }

                            if (string.IsNullOrWhiteSpace(itemCode))
                            {
                                // No matching local item found - nothing to post
                                tx.Rollback();
                                return;
                            }

                            decimal totalCost = unitCost * Math.Abs(movementQty);

                            // For API-driven inventory movements, stamp a fixed UserID and compute pricing fields
                            // based on online retail price and discount.
                            string userId = "API";
                            decimal absQty = Math.Abs(movementQty);
                            decimal grossAmount = price * absQty;
                            decimal netAmount = grossAmount - discount;
                            string documentNo = string.IsNullOrWhiteSpace(orderId) ? string.Empty : orderId;
                            string description = string.IsNullOrWhiteSpace(orderId)
                                ? "Online Order"
                                : $"Online Order {orderId}";

                            // Insert ItemLedgerEntry row
                            using (var ledgerCmd = new SqlCommand(@"
                        INSERT INTO ItemLedgerEntry (EntryDate, ItemCode, DocumentType, DocumentNo, Quantity, UnitCost, TotalCost, Price, Discount, GrossAmount, NetAmount, Description, UserID, VariationId, FromOnlineOrder, SentToOnline)
                        VALUES (GETDATE(), @itemCode, @docType, @docNo, @quantity, @unitCost, @totalCost, @price, @discount, @grossAmount, @netAmount, @description, @userId, @variationId, @fromOnlineOrder, @sentToOnline)", conn, tx))
                            {
                                ledgerCmd.Parameters.AddWithValue("@itemCode", itemCode);
                                ledgerCmd.Parameters.AddWithValue("@docType", documentType);
                                ledgerCmd.Parameters.AddWithValue("@docNo", documentNo);
                                ledgerCmd.Parameters.AddWithValue("@quantity", movementQty);
                                ledgerCmd.Parameters.AddWithValue("@unitCost", unitCost);
                                ledgerCmd.Parameters.AddWithValue("@totalCost", totalCost);
                                ledgerCmd.Parameters.AddWithValue("@price", price);
                                ledgerCmd.Parameters.AddWithValue("@discount", discount);
                                ledgerCmd.Parameters.AddWithValue("@grossAmount", grossAmount);
                                ledgerCmd.Parameters.AddWithValue("@netAmount", netAmount);
                                ledgerCmd.Parameters.AddWithValue("@description", description);
                                ledgerCmd.Parameters.AddWithValue("@userId", userId);
                                ledgerCmd.Parameters.AddWithValue("@variationId", variationId);
                                ledgerCmd.Parameters.AddWithValue("@fromOnlineOrder", true);
                                ledgerCmd.Parameters.AddWithValue("@sentToOnline", true);
                                ledgerCmd.ExecuteNonQuery();
                            }

                            // Update local stock for the resolved item
                            using (var upd = new SqlCommand("UPDATE Items SET QuantityInStock = ISNULL(QuantityInStock, 0) + @qty WHERE Code = @code", conn, tx))
                            {
                                upd.Parameters.AddWithValue("@qty", movementQty);
                                upd.Parameters.AddWithValue("@code", itemCode);
                                upd.ExecuteNonQuery();
                            }

                            tx.Commit();
                        }
                        catch (Exception ex)
                        {
                            try { System.Diagnostics.Trace.TraceError($"LocalInventoryMovement failed: {ex}"); } catch { }
                            tx.Rollback();
                            throw;
                        }
                    }
                }
            }
            catch
            {
                // Swallow exceptions here so that integration callers can decide on error handling
                // while errors are still logged via Trace.
            }
        }

        /// <summary>
        /// Fetch a single order by OrderID from the upstream API and return its line items as a DataTable.
        /// Columns: OrderID, LineID, product_display_id, Quantity, UnitCost, Price, Discount, GrossAmount, NetAmount
        /// </summary>
        public static async Task<DataTable> FetchOrderLinesAsync(string orderId, TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);
            var table = new DataTable();
            table.Columns.Add("OrderID", typeof(string));
            table.Columns.Add("LineID", typeof(string));
            table.Columns.Add("product_display_id", typeof(string));
            table.Columns.Add("VariationId", typeof(string));
            table.Columns.Add("Quantity", typeof(decimal));
            table.Columns.Add("UnitCost", typeof(decimal));
            table.Columns.Add("Price", typeof(decimal));
            table.Columns.Add("Discount", typeof(decimal));
            table.Columns.Add("GrossAmount", typeof(decimal));
            table.Columns.Add("NetAmount", typeof(decimal));

            // Local parser used by item-level enumeration (handles currency formatting)
            decimal ParseStringDecimal(string s)
            {
                if (string.IsNullOrWhiteSpace(s)) return 0m;
                var cleaned = s.Replace(",", string.Empty).Replace("$", string.Empty).Replace("€", string.Empty).Replace("₱", string.Empty).Trim();
                if (decimal.TryParse(cleaned, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var v)) return v;
                if (decimal.TryParse(cleaned, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out v)) return v;
                var sb = new System.Text.StringBuilder();
                foreach (char c in cleaned) if (char.IsDigit(c) || c == '.' || c == '-') sb.Append(c);
                if (decimal.TryParse(sb.ToString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out v)) return v;
                return 0m;
            }

            if (string.IsNullOrWhiteSpace(orderId)) return table;

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl;
            string apiKey = GlobalSettings.OnlineOrdersApiKey;
            string shopId = GlobalSettings.OnlineOrdersShopId;
            string requestPath = $"{baseUrl}/shops/{shopId}/orders/{Uri.EscapeDataString(orderId)}?api_key={apiKey}&page_size=1000";
            // Message(requestPath);
            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };
            using var resp = await http.GetAsync(requestPath).ConfigureAwait(false);
            resp.EnsureSuccessStatusCode();
            var json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            JsonElement orderEl = default;
            if (root.ValueKind == JsonValueKind.Object)
            {
                // If root looks like an order object, use it; otherwise try common wrappers
                if (root.TryGetProperty("data", out var dataProp))
                {
                    // data may be an object (single order) or an array (one or more orders)
                    if (dataProp.ValueKind == JsonValueKind.Object)
                    {
                        orderEl = dataProp;
                        // Debug: show the resolved order element for inspection
                        try
                        {

                            // If the resolved data object contains an 'items' child, show it too for debugging
                            try
                            {
                                if (orderEl.ValueKind == JsonValueKind.Object && orderEl.TryGetProperty("items", out var itemsProp))
                                {
                                    try
                                    {
                                        // If items is an array, show each element for inspection
                                        if (itemsProp.ValueKind == JsonValueKind.Array)
                                        {
                                            int idx = 0;
                                            foreach (var it in itemsProp.EnumerateArray())
                                            {
                                                //try { System.Windows.Forms.MessageBox.Show(it.ToString(), $"FetchOrderLines - itemsProp[{idx}]", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                try
                                                {
                                                    // Extract common quantity, variation_id and retail/price fields from the item for debugging
                                                    string pdVal = string.Empty;

                                                    string qtyVal = string.Empty;
                                                    string rpVal = string.Empty;
                                                    string nameVal = string.Empty;
                                                    string variationIdVal = string.Empty;
                                                    if (it.ValueKind == JsonValueKind.Object)
                                                    {
                                                        // Prefer variation_info values when present
                                                        if (it.TryGetProperty("variation_info", out var vi) && vi.ValueKind == JsonValueKind.Object)
                                                        {
                                                            if (vi.TryGetProperty("retail_price", out var rv) && rv.ValueKind != JsonValueKind.Null)
                                                                rpVal = rv.ToString() ?? string.Empty;
                                                            // Extract variation name when present
                                                            if (vi.TryGetProperty("name", out var nameProp) && nameProp.ValueKind != JsonValueKind.Null)
                                                                nameVal = nameProp.ToString() ?? string.Empty;
                                                            // Extract variation_id when present under variation_info
                                                            if (vi.TryGetProperty("variation_id", out var vId) && vId.ValueKind != JsonValueKind.Null)
                                                                variationIdVal = vId.ToString() ?? string.Empty;
                                                            // try { System.Windows.Forms.MessageBox.Show($"rpVal: {rpVal}\nname: {nameVal}", $"1FetchOrderLines - rpVal/name[{idx}]", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                            if (vi.TryGetProperty("product_display_id", out var pd2) && pd2.ValueKind != JsonValueKind.Null)
                                                                pdVal = pd2.ToString() ?? string.Empty;
                                                        }

                                                        // Fallback to top-level properties if variation_info didn't provide them
                                                        if (string.IsNullOrWhiteSpace(pdVal) && it.TryGetProperty("product_display_id", out var pd) && pd.ValueKind != JsonValueKind.Null)
                                                            pdVal = pd.ToString() ?? string.Empty;

                                                        // Fallbacks for variation_id at top level
                                                        if (string.IsNullOrWhiteSpace(variationIdVal) && it.TryGetProperty("variation_id", out var vTop) && vTop.ValueKind != JsonValueKind.Null)
                                                            variationIdVal = vTop.ToString() ?? string.Empty;
                                                        else if (string.IsNullOrWhiteSpace(variationIdVal) && it.TryGetProperty("variationId", out var vTop2) && vTop2.ValueKind != JsonValueKind.Null)
                                                            variationIdVal = vTop2.ToString() ?? string.Empty;

                                                        if (string.IsNullOrWhiteSpace(qtyVal) && it.TryGetProperty("quantity", out var q1) && q1.ValueKind != JsonValueKind.Null) qtyVal = q1.ToString() ?? string.Empty;
                                                        // else if (it.TryGetProperty("qty", out var q2) && q2.ValueKind != JsonValueKind.Null) qtyVal = q2.ToString() ?? string.Empty;
                                                        // else if (it.TryGetProperty("amount", out var q3) && q3.ValueKind != JsonValueKind.Null) qtyVal = q3.ToString() ?? string.Empty;

                                                        if (string.IsNullOrWhiteSpace(rpVal) && it.TryGetProperty("retail_price", out var r1) && r1.ValueKind != JsonValueKind.Null) rpVal = r1.ToString() ?? string.Empty;
                                                        // If name wasn't found under variation_info, try top-level name
                                                        if (string.IsNullOrWhiteSpace(nameVal) && it.TryGetProperty("name", out var topName) && topName.ValueKind != JsonValueKind.Null)
                                                            nameVal = topName.ToString() ?? string.Empty;
                                                        // try { System.Windows.Forms.MessageBox.Show($"rpVal: {rpVal}\nname: {nameVal}", $"2FetchOrderLines - rpVal/name[{idx}]", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                    }

                                                    // try
                                                    // {
                                                    //     if (it.ValueKind == JsonValueKind.Object)
                                                    //     {
                                                    //         if (it.TryGetProperty("quantity", out var q1) && q1.ValueKind != JsonValueKind.Null) qtyVal = q1.ToString() ?? string.Empty;
                                                    //         else if (it.TryGetProperty("qty", out var q2) && q2.ValueKind != JsonValueKind.Null) qtyVal = q2.ToString() ?? string.Empty;
                                                    //         else if (it.TryGetProperty("amount", out var q3) && q3.ValueKind != JsonValueKind.Null) qtyVal = q3.ToString() ?? string.Empty;

                                                    //         if (it.TryGetProperty("retail_price", out var r1) && r1.ValueKind != JsonValueKind.Null) rpVal = r1.ToString() ?? string.Empty;
                                                    //         else if (it.TryGetProperty("retailPrice", out var r2) && r2.ValueKind != JsonValueKind.Null) rpVal = r2.ToString() ?? string.Empty;
                                                    //         else if (it.TryGetProperty("price", out var r3) && r3.ValueKind != JsonValueKind.Null) rpVal = r3.ToString() ?? string.Empty;
                                                    //         else if (it.TryGetProperty("unit_price", out var r4) && r4.ValueKind != JsonValueKind.Null) rpVal = r4.ToString() ?? string.Empty;
                                                    //         else if (it.TryGetProperty("unitPrice", out var r5) && r5.ValueKind != JsonValueKind.Null) rpVal = r5.ToString() ?? string.Empty;
                                                    //     }
                                                    // }
                                                    // catch { }
                                                    if (!string.IsNullOrWhiteSpace(pdVal))
                                                    {
                                                        try
                                                        {
                                                            decimal parsedQty = ParseStringDecimal(qtyVal);
                                                            // try { System.Windows.Forms.MessageBox.Show($"rpVal: {rpVal}", $"3FetchOrderLines - rpVal[{idx}]", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                            decimal parsedPrice = ParseStringDecimal(rpVal);
                                                            string noteValLocal = string.Empty;
                                                            if (it.ValueKind == JsonValueKind.Object && it.TryGetProperty("note", out var notePropLocal) && notePropLocal.ValueKind != JsonValueKind.Null)
                                                                noteValLocal = notePropLocal.ToString() ?? string.Empty;
                                                            string lineIdLocal = string.Empty;
                                                            if (it.ValueKind == JsonValueKind.Object)
                                                            {
                                                                if (it.TryGetProperty("line_id", out var lidA) && lidA.ValueKind != JsonValueKind.Null) lineIdLocal = lidA.ToString() ?? string.Empty;
                                                                else if (it.TryGetProperty("id", out var lidB) && lidB.ValueKind != JsonValueKind.Null) lineIdLocal = lidB.ToString() ?? string.Empty;
                                                                else if (it.TryGetProperty("order_line_id", out var lidC) && lidC.ValueKind != JsonValueKind.Null) lineIdLocal = lidC.ToString() ?? string.Empty;
                                                                else if (it.TryGetProperty("order_item_id", out var lidD) && lidD.ValueKind != JsonValueKind.Null) lineIdLocal = lidD.ToString() ?? string.Empty;
                                                                else if (it.TryGetProperty("item_id", out var lidE) && lidE.ValueKind != JsonValueKind.Null) lineIdLocal = lidE.ToString() ?? string.Empty;
                                                            }
                                                            //try { System.Windows.Forms.MessageBox.Show($"parsedPrice: {parsedPrice}", $"3FetchOrderLines - parsedPrice[{idx}]", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                            WriteintoOnlineOrderLines(orderId, string.IsNullOrWhiteSpace(lineIdLocal) ? string.Empty : lineIdLocal, pdVal ?? string.Empty, parsedQty, null, parsedPrice, noteValLocal ?? string.Empty, nameVal ?? string.Empty, variationIdVal ?? string.Empty);
                                                        }
                                                        catch { }


                                                    }
                                                }
                                                catch { }
                                                idx++;
                                            }
                                        }
                                        else
                                        {
                                            try { System.Windows.Forms.MessageBox.Show(itemsProp.ToString(), "FetchOrderLines - itemsProp", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                        }
                                    }
                                    catch { }
                                }
                            }
                            catch { }
                        }
                        catch { }
                    }
                    else if (dataProp.ValueKind == JsonValueKind.Array)
                    {
                        // Try to find the array element that matches the requested orderId by common id fields.
                        JsonElement firstEl = default;
                        bool haveFirst = false;
                        bool foundMatch = false;
                        foreach (var el in dataProp.EnumerateArray())
                        {
                            if (!haveFirst) { firstEl = el; haveFirst = true; }
                            if (el.ValueKind != JsonValueKind.Object) continue;

                            string candidate = string.Empty;
                            if (el.TryGetProperty("order_id", out var v) && v.ValueKind != JsonValueKind.Null) candidate = v.ToString() ?? string.Empty;
                            else if (el.TryGetProperty("id", out v) && v.ValueKind != JsonValueKind.Null) candidate = v.ToString() ?? string.Empty;
                            else if (el.TryGetProperty("receipt_no", out v) && v.ValueKind != JsonValueKind.Null) candidate = v.ToString() ?? string.Empty;
                            else if (el.TryGetProperty("order_number", out v) && v.ValueKind != JsonValueKind.Null) candidate = v.ToString() ?? string.Empty;
                            else if (el.TryGetProperty("number", out v) && v.ValueKind != JsonValueKind.Null) candidate = v.ToString() ?? string.Empty;

                            if (!string.IsNullOrWhiteSpace(candidate) && string.Equals(candidate, orderId, StringComparison.OrdinalIgnoreCase))
                            {
                                orderEl = el;
                                foundMatch = true;
                                break;
                            }
                        }

                        if (!foundMatch)
                        {
                            if (haveFirst)
                                orderEl = firstEl; // fallback to first element
                            else
                                return table; // empty array
                        }

                        // Debug: if the resolved orderEl contains an 'items' child, show it for inspection
                        try
                        {
                            if (orderEl.ValueKind == JsonValueKind.Object && orderEl.TryGetProperty("items", out var itemsProp))
                            {
                                try
                                {
                                    if (itemsProp.ValueKind == JsonValueKind.Array)
                                    {
                                        //Items looping in here take note
                                        int idx2 = 0;
                                        foreach (var it in itemsProp.EnumerateArray())
                                        {
                                            //try { System.Windows.Forms.MessageBox.Show(it.ToString(), $"FetchOrderLines - itemsProp[{idx2}]", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                            try
                                            {

                                                string pdVal = string.Empty;
                                                string variationId2 = string.Empty;
                                                if (it.ValueKind == JsonValueKind.Object)
                                                {
                                                    if (it.TryGetProperty("product_display_id", out var pd) && pd.ValueKind != JsonValueKind.Null)
                                                        pdVal = pd.ToString() ?? string.Empty;
                                                    else if (it.TryGetProperty("variation_info", out var vi) && vi.ValueKind == JsonValueKind.Object && vi.TryGetProperty("product_display_id", out var pd2) && pd2.ValueKind != JsonValueKind.Null)
                                                        pdVal = pd2.ToString() ?? string.Empty;
                                                    // variation_id can be on the item or inside variation_info
                                                    if (string.IsNullOrWhiteSpace(variationId2) && it.TryGetProperty("variation_id", out var vId) && vId.ValueKind != JsonValueKind.Null)
                                                        variationId2 = vId.ToString() ?? string.Empty;
                                                    else if (string.IsNullOrWhiteSpace(variationId2) && it.TryGetProperty("variationId", out var vId2) && vId2.ValueKind != JsonValueKind.Null)
                                                        variationId2 = vId2.ToString() ?? string.Empty;
                                                    else if (string.IsNullOrWhiteSpace(variationId2) && it.TryGetProperty("variation_info", out var vi2) && vi2.ValueKind == JsonValueKind.Object && vi2.TryGetProperty("variation_id", out var vId3) && vId3.ValueKind != JsonValueKind.Null)
                                                        variationId2 = vId3.ToString() ?? string.Empty;
                                                }
                                                // Extract common quantity and retail/price fields from the item for debugging
                                                string qtyVal2 = string.Empty;
                                                string rpVal2 = string.Empty;
                                                try
                                                {
                                                    if (it.ValueKind == JsonValueKind.Object)
                                                    {
                                                        // Prefer variation_info first
                                                        if (it.TryGetProperty("variation_info", out var vi2) && vi2.ValueKind == JsonValueKind.Object)
                                                        {
                                                            if (vi2.TryGetProperty("retail_price", out var rv2) && rv2.ValueKind != JsonValueKind.Null)
                                                                rpVal2 = rv2.ToString() ?? string.Empty;
                                                        }

                                                        // Fallbacks
                                                        if (string.IsNullOrWhiteSpace(qtyVal2) && it.TryGetProperty("quantity", out var q1) && q1.ValueKind != JsonValueKind.Null) qtyVal2 = q1.ToString() ?? string.Empty;
                                                        else if (string.IsNullOrWhiteSpace(qtyVal2) && it.TryGetProperty("qty", out var q2) && q2.ValueKind != JsonValueKind.Null) qtyVal2 = q2.ToString() ?? string.Empty;
                                                        else if (string.IsNullOrWhiteSpace(qtyVal2) && it.TryGetProperty("amount", out var q3) && q3.ValueKind != JsonValueKind.Null) qtyVal2 = q3.ToString() ?? string.Empty;

                                                        if (string.IsNullOrWhiteSpace(rpVal2))
                                                        {
                                                            if (it.TryGetProperty("retail_price", out var r1) && r1.ValueKind != JsonValueKind.Null) rpVal2 = r1.ToString() ?? string.Empty;
                                                            else if (it.TryGetProperty("retailPrice", out var r2) && r2.ValueKind != JsonValueKind.Null) rpVal2 = r2.ToString() ?? string.Empty;
                                                            else if (it.TryGetProperty("price", out var r3) && r3.ValueKind != JsonValueKind.Null) rpVal2 = r3.ToString() ?? string.Empty;
                                                            else if (it.TryGetProperty("unit_price", out var r4) && r4.ValueKind != JsonValueKind.Null) rpVal2 = r4.ToString() ?? string.Empty;
                                                            else if (it.TryGetProperty("unitPrice", out var r5) && r5.ValueKind != JsonValueKind.Null) rpVal2 = r5.ToString() ?? string.Empty;
                                                        }
                                                    }
                                                }
                                                catch { }
                                                if (!string.IsNullOrWhiteSpace(pdVal))
                                                {
                                                    var msg2 = $"product_display_id: {pdVal}\nqty: {qtyVal2}\nretail_price: {rpVal2}";
                                                    // try { System.Windows.Forms.MessageBox.Show(msg2, $"FetchOrderLines - 1itemsProp[{idx2}]", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                }
                                                else
                                                {
                                                    var msg2 = $"product_display_id: (not found)\nqty: {qtyVal2}\nretail_price: {rpVal2}";
                                                    // try { System.Windows.Forms.MessageBox.Show(msg2, $"FetchOrderLines - 2itemsProp[{idx2}]", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                }
                                                // Write the discovered values into the result DataTable so SyncOrderListAsync can persist them
                                                try
                                                {
                                                    decimal dQty = ParseStringDecimal(qtyVal2);
                                                    decimal dPrice = ParseStringDecimal(rpVal2);
                                                    decimal dGross = dQty * dPrice;
                                                    // attempt to get id from this item element
                                                    string rowLineId = string.Empty;
                                                    if (it.ValueKind == JsonValueKind.Object)
                                                    {
                                                        if (it.TryGetProperty("line_id", out var lid) && lid.ValueKind != JsonValueKind.Null) rowLineId = lid.ToString() ?? string.Empty;
                                                        else if (it.TryGetProperty("id", out var lid2) && lid2.ValueKind != JsonValueKind.Null) rowLineId = lid2.ToString() ?? string.Empty;
                                                        else if (it.TryGetProperty("order_line_id", out var lid3) && lid3.ValueKind != JsonValueKind.Null) rowLineId = lid3.ToString() ?? string.Empty;
                                                        else if (it.TryGetProperty("order_item_id", out var lid4) && lid4.ValueKind != JsonValueKind.Null) rowLineId = lid4.ToString() ?? string.Empty;
                                                        else if (it.TryGetProperty("item_id", out var lid5) && lid5.ValueKind != JsonValueKind.Null) rowLineId = lid5.ToString() ?? string.Empty;
                                                    }
                                                    var row = table.NewRow();
                                                    row["OrderID"] = orderId;
                                                    row["LineID"] = string.IsNullOrWhiteSpace(rowLineId) ? string.Empty : rowLineId;
                                                    row["product_display_id"] = pdVal ?? string.Empty;
                                                    row["VariationId"] = string.IsNullOrWhiteSpace(variationId2) ? (object)DBNull.Value : variationId2;
                                                    row["Quantity"] = dQty;
                                                    row["UnitCost"] = DBNull.Value;
                                                    row["Price"] = dPrice;
                                                    row["Discount"] = 0m;
                                                    row["GrossAmount"] = dGross;
                                                    row["NetAmount"] = 0m;
                                                    table.Rows.Add(row);
                                                }
                                                catch { }
                                                try
                                                {
                                                    if (it.ValueKind == JsonValueKind.Object && it.TryGetProperty("note", out var noteProp) && noteProp.ValueKind != JsonValueKind.Null)
                                                    {
                                                        var noteVal = noteProp.ToString() ?? string.Empty;
                                                        // try { System.Windows.Forms.MessageBox.Show(noteVal, $"FetchOrderLines - 3itemsProp[{idx2}] note", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                    }
                                                    else
                                                    {
                                                        // try { System.Windows.Forms.MessageBox.Show("note not found", $"FetchOrderLines - 4itemsProp[{idx2}] note", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                                    }
                                                }
                                                catch { }
                                            }
                                            catch { }
                                            idx2++;
                                        }
                                    }
                                    else
                                    {
                                        try { System.Windows.Forms.MessageBox.Show(itemsProp.ToString(), "FetchOrderLines - xitemsProp", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Information); } catch { }
                                    }
                                }
                                catch { }
                            }
                        }
                        catch { }

                    }
                }
                else if (root.TryGetProperty("order", out var orderProp) && orderProp.ValueKind == JsonValueKind.Object)
                    orderEl = orderProp;
                else
                    orderEl = root;
            }
            else
            {
                return table;
            }



            return table;
        }

        /// <summary>
        /// Upsert a single line into dbo.OnlineOrderLines, including the local VariationId mapping.
        /// </summary>
        public static void WriteintoOnlineOrderLines(string OrderID, string LineID, string product_display_id, decimal Quantity, decimal? UnitCost, decimal Price, string note, string description, string variationId)
        {
            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();

                    // Ensure VariationId column exists (for upgraded databases)
                    try
                    {
                        string alterSql = @"IF COL_LENGTH('dbo.OnlineOrderLines','VariationId') IS NULL
                                            BEGIN
                                                ALTER TABLE dbo.OnlineOrderLines ADD VariationId NVARCHAR(200) NULL
                                            END";
                        using (var alterCmd = new SqlCommand(alterSql, conn))
                        {
                            alterCmd.ExecuteNonQuery();
                        }
                    }
                    catch { }

                    // Upsert: prefer the exact OrderID+LineID match, then fall back to an existing
                    // row for the same OrderID+VariationId so the same item is not duplicated when
                    // upstream changes the line id during sync.
                    string updateSql = @"UPDATE dbo.OnlineOrderLines SET ItemCode=@ItemCode, product_display_id=@product_display_id, VariationId=@VariationId, Quantity=@Quantity, UnitCost=@UnitCost, Price=@Price, GrossAmount=@GrossAmount, Note=@Note, Description=@Description WHERE OrderID=@OrderID AND LineID=@LineID";
                    using (var upCmd = new SqlCommand(updateSql, conn))
                    {
                        upCmd.Parameters.AddWithValue("@ItemCode", string.IsNullOrWhiteSpace(product_display_id) ? (object)DBNull.Value : (object)product_display_id);
                        upCmd.Parameters.AddWithValue("@product_display_id", string.IsNullOrWhiteSpace(product_display_id) ? (object)DBNull.Value : (object)product_display_id);
                        upCmd.Parameters.AddWithValue("@VariationId", string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : (object)variationId);
                        upCmd.Parameters.AddWithValue("@Quantity", Quantity);
                        upCmd.Parameters.AddWithValue("@UnitCost", UnitCost.HasValue ? (object)UnitCost.Value : (object)DBNull.Value);
                        upCmd.Parameters.AddWithValue("@Price", Price);
                        upCmd.Parameters.AddWithValue("@Note", string.IsNullOrWhiteSpace(note) ? (object)DBNull.Value : (object)note);
                        upCmd.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(description) ? (object)DBNull.Value : (object)description);
                        upCmd.Parameters.AddWithValue("@OrderID", string.IsNullOrWhiteSpace(OrderID) ? (object)DBNull.Value : (object)OrderID);
                        upCmd.Parameters.AddWithValue("@LineID", string.IsNullOrWhiteSpace(LineID) ? (object)DBNull.Value : (object)LineID);
                        // GrossAmount is price * quantity per mapping
                        upCmd.Parameters.AddWithValue("@GrossAmount", Price * Quantity);

                        int affected = upCmd.ExecuteNonQuery();
                        if (affected == 0 && !string.IsNullOrWhiteSpace(OrderID) && !string.IsNullOrWhiteSpace(variationId))
                        {
                            string updateByVariationSql = @"
UPDATE target
SET
    LineID = @LineID,
    ItemCode = @ItemCode,
    product_display_id = @product_display_id,
    VariationId = @VariationId,
    Quantity = @Quantity,
    UnitCost = @UnitCost,
    Price = @Price,
    GrossAmount = @GrossAmount,
    Note = @Note,
    Description = @Description
FROM dbo.OnlineOrderLines AS target
INNER JOIN (
    SELECT TOP (1) OrderID, LineID
    FROM dbo.OnlineOrderLines
    WHERE OrderID = @OrderID AND VariationId = @VariationId
    ORDER BY LineID
) AS existingRow
    ON target.OrderID = existingRow.OrderID AND target.LineID = existingRow.LineID";

                            using (var variationCmd = new SqlCommand(updateByVariationSql, conn))
                            {
                                variationCmd.Parameters.AddWithValue("@ItemCode", string.IsNullOrWhiteSpace(product_display_id) ? (object)DBNull.Value : (object)product_display_id);
                                variationCmd.Parameters.AddWithValue("@product_display_id", string.IsNullOrWhiteSpace(product_display_id) ? (object)DBNull.Value : (object)product_display_id);
                                variationCmd.Parameters.AddWithValue("@VariationId", (object)variationId);
                                variationCmd.Parameters.AddWithValue("@Quantity", Quantity);
                                variationCmd.Parameters.AddWithValue("@UnitCost", UnitCost.HasValue ? (object)UnitCost.Value : (object)DBNull.Value);
                                variationCmd.Parameters.AddWithValue("@Price", Price);
                                variationCmd.Parameters.AddWithValue("@Note", string.IsNullOrWhiteSpace(note) ? (object)DBNull.Value : (object)note);
                                variationCmd.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(description) ? (object)DBNull.Value : (object)description);
                                variationCmd.Parameters.AddWithValue("@OrderID", (object)OrderID);
                                variationCmd.Parameters.AddWithValue("@LineID", string.IsNullOrWhiteSpace(LineID) ? (object)DBNull.Value : (object)LineID);
                                variationCmd.Parameters.AddWithValue("@GrossAmount", Price * Quantity);
                                affected = variationCmd.ExecuteNonQuery();
                            }
                        }

                        if (affected == 0)
                        {
                            string insertSql = @"INSERT INTO dbo.OnlineOrderLines (OrderID, LineID, ItemCode, product_display_id, VariationId, Quantity, UnitCost, Price, GrossAmount, Note, Description) VALUES (@OrderID, @LineID, @ItemCode, @product_display_id, @VariationId, @Quantity, @UnitCost, @Price, @GrossAmount, @Note, @Description)";
                            using (var insCmd = new SqlCommand(insertSql, conn))
                            {
                                insCmd.Parameters.AddWithValue("@OrderID", string.IsNullOrWhiteSpace(OrderID) ? (object)DBNull.Value : (object)OrderID);
                                insCmd.Parameters.AddWithValue("@LineID", string.IsNullOrWhiteSpace(LineID) ? (object)DBNull.Value : (object)LineID);
                                insCmd.Parameters.AddWithValue("@ItemCode", string.IsNullOrWhiteSpace(product_display_id) ? (object)DBNull.Value : (object)product_display_id);
                                insCmd.Parameters.AddWithValue("@product_display_id", string.IsNullOrWhiteSpace(product_display_id) ? (object)DBNull.Value : (object)product_display_id);
                                insCmd.Parameters.AddWithValue("@VariationId", string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : (object)variationId);
                                insCmd.Parameters.AddWithValue("@Quantity", Quantity);
                                insCmd.Parameters.AddWithValue("@UnitCost", UnitCost.HasValue ? (object)UnitCost.Value : (object)DBNull.Value);
                                insCmd.Parameters.AddWithValue("@Price", Price);
                                insCmd.Parameters.AddWithValue("@GrossAmount", Price * Quantity);
                                insCmd.Parameters.AddWithValue("@Note", string.IsNullOrWhiteSpace(note) ? (object)DBNull.Value : (object)note);
                                insCmd.Parameters.AddWithValue("@Description", string.IsNullOrWhiteSpace(description) ? (object)DBNull.Value : (object)description);
                                insCmd.ExecuteNonQuery();
                            }
                        }

                        if (!string.IsNullOrWhiteSpace(OrderID) && !string.IsNullOrWhiteSpace(variationId) && !string.IsNullOrWhiteSpace(LineID))
                        {
                            string deleteDuplicateVariationSql = @"
DELETE FROM dbo.OnlineOrderLines
WHERE OrderID = @OrderID
  AND VariationId = @VariationId
  AND LineID <> @LineID";

                            using (var cleanupCmd = new SqlCommand(deleteDuplicateVariationSql, conn))
                            {
                                cleanupCmd.Parameters.AddWithValue("@OrderID", OrderID);
                                cleanupCmd.Parameters.AddWithValue("@VariationId", variationId);
                                cleanupCmd.Parameters.AddWithValue("@LineID", LineID);
                                cleanupCmd.ExecuteNonQuery();
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                // Surface the error for debugging: write to trace and show a message box if possible
                try
                {
                    System.Diagnostics.Trace.TraceError($"WriteintoOnlineOrderLines error: {ex}");
                }
                catch { }

                try
                {
                    System.Windows.Forms.MessageBox.Show($"WriteintoOnlineOrderLines failed:\n{ex.Message}", "IntegrationEvents", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
                }
                catch { }
            }
        }

        /// <summary>
        /// Send a message to a customer's conversation via the public pages API.
        /// URL pattern: {PublicURL}/pages/{PageID}/conversations/{ConversationID}/messages?page_access_token={PublicApiKey}
        /// Returns the response body on success, or throws on failure.
        /// </summary>
        public static async Task<string> SendMessageToCustomer(string orderId, string pageId, string conversationId, string messageText)
        {
            if (string.IsNullOrWhiteSpace(pageId) || string.IsNullOrWhiteSpace(conversationId))
                throw new ArgumentException("pageId and conversationId are required");

            var baseUrl = GlobalSettings.PublicURL?.TrimEnd('/') ?? string.Empty;
            var qsKey = Uri.EscapeDataString(GlobalSettings.PublicApiKey ?? string.Empty);
            var url = $"{baseUrl}/pages/{Uri.EscapeDataString(pageId)}/conversations/{Uri.EscapeDataString(conversationId)}/messages?page_access_token={qsKey}";
            //MessageBox.Show($"url: {url}", "SendMessageToCustomer", MessageBoxButtons.OK, MessageBoxIcon.Information);
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

            // Per upstream API requirements, send the action and message fields
            var payload = new { action = "reply_inbox", message = messageText };
            var json = System.Text.Json.JsonSerializer.Serialize(payload);
            using var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");

            using var resp = await http.PostAsync(url, content).ConfigureAwait(false);
            var respBody = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                throw new HttpRequestException($"SendMessageToCustomer failed: {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respBody}");
            }

            return respBody;
        }

        /// <summary>
        /// Same as sendneworderupdatetoADMIN but intended for notifying ADMIN about a new order update.
        /// URL pattern: {PublicURL}/pages/{PageID}/conversations/{ConversationID}/messages?page_access_token={PublicApiKey}
        /// Returns the response body on success, or throws on failure.
        /// </summary>
        public static async Task<string> sendneworderupdatetoADMIN(string orderId, string pageId, string conversationId, string messageText)
        {
            if (string.IsNullOrWhiteSpace(pageId) || string.IsNullOrWhiteSpace(conversationId))
                throw new ArgumentException("pageId and conversationId are required");

            var baseUrl = GlobalSettings.PublicURL?.TrimEnd('/') ?? string.Empty;
            var qsKey = Uri.EscapeDataString(GlobalSettings.PublicApiKey ?? string.Empty);
            var url = $"{baseUrl}/pages/{Uri.EscapeDataString(pageId)}/conversations/{Uri.EscapeDataString(conversationId)}/messages?page_access_token={qsKey}";
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

            // Per upstream API requirements, send the action and message fields
            var payload = new { action = "reply_inbox", message = messageText };
            var json = System.Text.Json.JsonSerializer.Serialize(payload);
            using var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");

            using var resp = await http.PostAsync(url, content).ConfigureAwait(false);
            var respBody = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                throw new HttpRequestException($"sendneworderupdatetoADMIN failed: {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respBody}");
            }

            return respBody;
        }

        public static async Task<string> UpdateStatusPayload(string orderId, string status, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(orderId)) throw new ArgumentException("orderId is required", nameof(orderId));
            if (string.IsNullOrWhiteSpace(status)) throw new ArgumentException("status is required", nameof(status));

            var payload = new Dictionary<string, object?>
            {
                ["status"] = status
            };
            return await SendOnlineOrderUpdatePayload(orderId, JsonSerializer.Serialize(payload), timeout).ConfigureAwait(false);
        }

        public static async Task<string> UpdateEstimatedDeliveryDatePayload(string orderId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(orderId)) throw new ArgumentException("orderId is required", nameof(orderId));

            DateTime estimatedDeliveryDate = LoadLocalEstimatedDeliveryDate(orderId);
            if (estimatedDeliveryDate == DateTime.MinValue)
                throw new InvalidOperationException($"No local Estimated Delivery Date found for order {orderId}.");

            var payload = new Dictionary<string, object?>
            {
                ["estimate_delivery_date"] = FormatEstimatedDeliveryDateForEndpoint(estimatedDeliveryDate)
            };

            return await SendOnlineOrderUpdatePayload(orderId, JsonSerializer.Serialize(payload), timeout).ConfigureAwait(false);
        }

        public static async Task<string> UpdatePrintedOrderPayload(string orderId, string status, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(orderId)) throw new ArgumentException("orderId is required", nameof(orderId));
            if (string.IsNullOrWhiteSpace(status)) throw new ArgumentException("status is required", nameof(status));

            var payload = new Dictionary<string, object?>
            {
                ["status"] = status
            };

            DateTime estimatedDeliveryDate = LoadLocalEstimatedDeliveryDate(orderId);
            if (estimatedDeliveryDate != DateTime.MinValue)
            {
                payload["estimate_delivery_date"] = FormatEstimatedDeliveryDateForEndpoint(estimatedDeliveryDate);
            }

            return await SendOnlineOrderUpdatePayload(orderId, JsonSerializer.Serialize(payload), timeout).ConfigureAwait(false);
        }

        private static async Task<string> SendOnlineOrderUpdatePayload(string orderId, string payloadJson, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(orderId)) throw new ArgumentException("orderId is required", nameof(orderId));
            if (string.IsNullOrWhiteSpace(payloadJson)) throw new ArgumentException("payloadJson is required", nameof(payloadJson));

            timeout ??= TimeSpan.FromSeconds(30);
            var baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            var url = BuildOnlineOrderUpdateEndpoint(orderId);

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };
            string? bankPaymentsJson = await GetBankPaymentsSnapshotAsync(http, url).ConfigureAwait(false);

            async Task<HttpResponseMessage> SendAsync(HttpMethod method)
            {
                var request = new HttpRequestMessage(method, url)
                {
                    Content = new StringContent(payloadJson, System.Text.Encoding.UTF8, "application/json")
                };
                return await http.SendAsync(request).ConfigureAwait(false);
            }

            using var patchResp = await SendAsync(new HttpMethod("PATCH")).ConfigureAwait(false);
            var patchText = await patchResp.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (patchResp.IsSuccessStatusCode)
            {
                if (!string.IsNullOrWhiteSpace(bankPaymentsJson))
                    await RestoreBankPaymentsAsync(http, url, bankPaymentsJson).ConfigureAwait(false);
                return patchText;
            }

            if ((int)patchResp.StatusCode == 404 || (int)patchResp.StatusCode == 405)
            {
                using var putResp = await SendAsync(HttpMethod.Put).ConfigureAwait(false);
                var putText = await putResp.Content.ReadAsStringAsync().ConfigureAwait(false);
                if (putResp.IsSuccessStatusCode)
                {
                    if (!string.IsNullOrWhiteSpace(bankPaymentsJson))
                        await RestoreBankPaymentsAsync(http, url, bankPaymentsJson).ConfigureAwait(false);
                    return putText;
                }

                throw new HttpRequestException($"Online order update failed: PATCH {(int)patchResp.StatusCode} {patchResp.ReasonPhrase}. Response: {patchText}. PUT {(int)putResp.StatusCode} {putResp.ReasonPhrase}. Response: {putText}");
            }

            throw new HttpRequestException($"Online order update failed: PATCH {(int)patchResp.StatusCode} {patchResp.ReasonPhrase}. Response: {patchText}");
        }

        public static string BuildEstimatedDeliveryDatePayloadPreview(string orderId)
        {
            if (string.IsNullOrWhiteSpace(orderId))
                return "Order ID is blank. No payload can be built.";

            DateTime estimatedDeliveryDate = LoadLocalEstimatedDeliveryDate(orderId);
            if (estimatedDeliveryDate == DateTime.MinValue)
                return $"Order {orderId}\r\nEstimated Delivery Date in OnlineOrderHeader is NULL.\r\nPayload not sent.";

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            string endpointUrl = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders/{Uri.EscapeDataString(orderId)}?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000";
            string formattedDate = FormatEstimatedDeliveryDateForEndpoint(estimatedDeliveryDate);
            string payloadJson = JsonSerializer.Serialize(new
            {
                estimate_delivery_date = formattedDate
            });

            return $"Order ID: {orderId}\r\nHTTP Method: PATCH\r\nFallback Method: PUT (only if PATCH returns 404/405)\r\nEndpoint URL:\r\n{endpointUrl}\r\nSaved Estimated Delivery Date: {estimatedDeliveryDate:yyyy-MM-dd}\r\nEndpoint Date Value: {formattedDate}\r\nIncluded In Payload: YES\r\nExact Request Body:\r\n{payloadJson}";
        }

        public static string BuildPrintedOrderPayloadPreview(string orderId, string status)
        {
            if (string.IsNullOrWhiteSpace(orderId))
                return "Order ID is blank. No payload can be built.";

            string endpointUrl = BuildOnlineOrderUpdateEndpoint(orderId);
            DateTime estimatedDeliveryDate = LoadLocalEstimatedDeliveryDate(orderId);
            var payload = new Dictionary<string, object?>
            {
                ["status"] = status
            };

            string included = "NO";
            string endpointDateValue = "NULL";
            if (estimatedDeliveryDate != DateTime.MinValue)
            {
                endpointDateValue = FormatEstimatedDeliveryDateForEndpoint(estimatedDeliveryDate);
                payload["estimate_delivery_date"] = endpointDateValue;
                included = "YES";
            }

            string payloadJson = JsonSerializer.Serialize(payload);
            string savedDateText = estimatedDeliveryDate == DateTime.MinValue ? "NULL" : estimatedDeliveryDate.ToString("yyyy-MM-dd");
            return $"Order ID: {orderId}\r\nHTTP Method: PATCH\r\nFallback Method: PUT (only if PATCH returns 404/405)\r\nEndpoint URL:\r\n{endpointUrl}\r\nStatus Value: {status}\r\nSaved Estimated Delivery Date: {savedDateText}\r\nEndpoint Date Value: {endpointDateValue}\r\nEstimated Date Included In Payload: {included}\r\nExact Request Body:\r\n{payloadJson}";
        }

        private static string BuildOnlineOrderUpdateEndpoint(string orderId)
        {
            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            return $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders/{Uri.EscapeDataString(orderId)}?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000";
        }

        private static DateTime LoadLocalEstimatedDeliveryDate(string orderId)
        {
            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();
            using var cmd = new SqlCommand("SELECT TOP 1 [Estimated Delivery Date] FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", conn);
            cmd.Parameters.AddWithValue("@OrderID", orderId);
            var result = cmd.ExecuteScalar();
            if (result == null || result == DBNull.Value)
                return DateTime.MinValue;

            try
            {
                return Convert.ToDateTime(result).Date;
            }
            catch
            {
                return DateTime.MinValue;
            }
        }

        private static string FormatEstimatedDeliveryDateForEndpoint(DateTime estimatedDeliveryDate)
        {
            var localMidnight = new DateTimeOffset(
                estimatedDeliveryDate.Date,
                TimeSpan.FromHours(8));
            var utcEquivalent = localMidnight.ToUniversalTime();
            return utcEquivalent.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        }

        // Helper to snapshot the current bank_payments object for an order from the cloud.
        // Returns the raw JSON for bank_payments or null if not present/failed.
        private static async Task<string?> GetBankPaymentsSnapshotAsync(HttpClient http, string url)
        {
            try
            {
                using var getResp = await http.GetAsync(url).ConfigureAwait(false);
                if (!getResp.IsSuccessStatusCode) return null;

                var getBody = await getResp.Content.ReadAsStringAsync().ConfigureAwait(false);
                using var doc = JsonDocument.Parse(getBody);
                var root = doc.RootElement;

                JsonElement orderEl = default;
                bool haveOrder = false;

                if (root.ValueKind == JsonValueKind.Object)
                {
                    if (root.TryGetProperty("data", out var dataProp))
                    {
                        if (dataProp.ValueKind == JsonValueKind.Object)
                        {
                            orderEl = dataProp;
                            haveOrder = true;
                        }
                        else if (dataProp.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var el in dataProp.EnumerateArray())
                            {
                                if (el.ValueKind == JsonValueKind.Object)
                                {
                                    orderEl = el;
                                    haveOrder = true;
                                    break;
                                }
                            }
                        }
                    }
                    else if (root.TryGetProperty("order", out var orderProp) && orderProp.ValueKind == JsonValueKind.Object)
                    {
                        orderEl = orderProp;
                        haveOrder = true;
                    }
                    else
                    {
                        orderEl = root;
                        haveOrder = true;
                    }
                }
                else if (root.ValueKind == JsonValueKind.Array)
                {
                    foreach (var el in root.EnumerateArray())
                    {
                        if (el.ValueKind == JsonValueKind.Object)
                        {
                            orderEl = el;
                            haveOrder = true;
                            break;
                        }
                    }
                }

                if (haveOrder && orderEl.ValueKind == JsonValueKind.Object && orderEl.TryGetProperty("bank_payments", out var bankPaymentsEl) && bankPaymentsEl.ValueKind == JsonValueKind.Object)
                {
                    return bankPaymentsEl.GetRawText();
                }
            }
            catch
            {
                // Best effort only
            }

            return null;
        }

        // Helper to PATCH a previously captured bank_payments JSON back to the cloud order.
        private static async Task RestoreBankPaymentsAsync(HttpClient http, string url, string bankPaymentsJson)
        {
            if (string.IsNullOrWhiteSpace(bankPaymentsJson)) return;

            try
            {
                var bpBody = "{\"bank_payments\": " + bankPaymentsJson + "}";
                using var bpContent = new StringContent(bpBody, System.Text.Encoding.UTF8, "application/json");
                var bpRequest = new HttpRequestMessage(new HttpMethod("PATCH"), url) { Content = bpContent };
                using var bpResp = await http.SendAsync(bpRequest).ConfigureAwait(false);
                // Ignore bpResp status; failure here should not break the main status change
            }
            catch
            {
                // Swallow errors for the bank_payments restore; main status change already succeeded
            }
        }

        /// <summary>
        /// Stage persisted dbo.OnlineOrderLines for a given order into the main POS tables so a cashier
        /// can later complete/transact it. This will create a TransactionHeader and ItemLedgerEntry rows
        /// but will not automatically record payments or perform inventory posting.
        /// By default this stages as an ADVANCEORDERS entry and does NOT create a payment row.
        /// Returns (success, message).
        /// </summary>
        public static (bool success, string message) PushOnlineOrderToPos(
            string orderId,
            string? receiptNo = null,
            string type = "ADVANCEORDERS",
            string storeNo = "001",
            string posTerminalNo = "001",
            string tenderCode = "ONLINE",
            bool createPaymentEntry = false,
            System.Collections.Generic.List<(string tenderCode, decimal amount)>? splitPayments = null)
        {
            if (string.IsNullOrWhiteSpace(orderId)) return (false, "orderId is required");

            try
            {
                // Ensure we have a receipt number for the staged sale
                if (string.IsNullOrWhiteSpace(receiptNo))
                {
                    // Simple default receipt pattern for staged online orders
                    receiptNo = "ONL-" + orderId;
                }

                // Try to find an open MainForm instance so we can stage into the UI
                foreach (System.Windows.Forms.Form f in System.Windows.Forms.Application.OpenForms)
                {
                    if (f is MainForm mf)
                    {
                        // Invoke on UI thread to safely stage the order into the POS UI.
                        // This sets currentTransNo/currentReceiptNo context used by payment recording.
                        try
                        {
                            mf.Invoke(new Action(() => mf.StageOnlineOrderIntoSalesList(orderId, receiptNo!)));
                        }
                        catch (Exception exInvoke)
                        {
                            try { System.Diagnostics.Trace.TraceError($"PushOnlineOrderToPos - invoke failed: {exInvoke}"); } catch { }
                            return (false, "Failed to stage order into POS UI (invoke error)");
                        }

                        // After staging into the UI, if the online order has an AmountPaid > 0,
                        // Persist the receipt number to the online order header so the
                        // staged POS receipt can be linked back to the upstream order.
                        try
                        {
                            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                            {
                                conn.Open();

                                // Ensure the ReceiptNo column exists (safe to run repeatedly)
                                string addColSql = @"
                                        IF COL_LENGTH('dbo.OnlineOrderHeader','ReceiptNo') IS NULL
                                        BEGIN
                                            ALTER TABLE dbo.OnlineOrderHeader ADD ReceiptNo NVARCHAR(100) NULL
                                        END
                                    ";
                                using (var addCmd = new SqlCommand(addColSql, conn))
                                    addCmd.ExecuteNonQuery();

                                // Update the ReceiptNo for this order
                                using (var upd = new SqlCommand("UPDATE dbo.OnlineOrderHeader SET ReceiptNo = @ReceiptNo WHERE OrderID = @OrderID", conn))
                                {
                                    upd.Parameters.AddWithValue("@ReceiptNo", string.IsNullOrWhiteSpace(receiptNo) ? (object)DBNull.Value : (object)receiptNo);
                                    upd.Parameters.AddWithValue("@OrderID", orderId);
                                    try { upd.ExecuteNonQuery(); } catch { }
                                }
                            }
                        }
                        catch (Exception exWrite)
                        {
                            try { System.Diagnostics.Trace.TraceError($"PushOnlineOrderToPos - failed to write ReceiptNo: {exWrite}"); } catch { }
                        }

                        // After persisting the ReceiptNo, read the outstanding Balance and stage a UI payment line if needed.
                        try
                        {
                            decimal balance = 0m;
                            try
                            {
                                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                                {
                                    conn.Open();
                                    using var cmd = new SqlCommand("SELECT Balance FROM dbo.OnlineOrderHeader WHERE OrderID = @OrderID", conn);
                                    cmd.Parameters.AddWithValue("@OrderID", orderId);
                                    var obj = cmd.ExecuteScalar();
                                    if (obj != null && obj != DBNull.Value) balance = Convert.ToDecimal(obj);
                                }
                            }
                            catch (Exception exRead)
                            {
                                try { System.Diagnostics.Trace.TraceError($"PushOnlineOrderToPos - failed to read Balance: {exRead}"); } catch { }
                                balance = 0m;
                            }

                            // if (balance > 0m)
                            // {
                            //     try
                            //     {
                            //         // Stage a payment line on the MainForm UI (tagged as PAYMENT). Use the provided tenderCode.
                            //                 mf.Invoke(new Action(() =>
                            //                 {
                            //                     try
                            //                     {
                            //                         mf.StagePaymentOnUI(tenderCode, balance);
                            //                     }
                            //                     catch { }
                            //                 }));
                            //     }
                            //     catch { }
                            // }

                            // If requested, persist TransactionHeader + TransPaymentEntry row(s) and print the receipt immediately.
                            // When splitPayments is provided, one TransPaymentEntry is created per tender/amount.
                            var paymentsToPost = new System.Collections.Generic.List<(string tenderCode, decimal amount)>();
                            try
                            {
                                if (splitPayments != null && splitPayments.Count > 0)
                                {
                                    foreach (var p in splitPayments)
                                    {
                                        if (!string.IsNullOrWhiteSpace(p.tenderCode) && p.amount > 0m)
                                            paymentsToPost.Add((p.tenderCode, p.amount));
                                    }
                                }
                                else
                                {
                                    if (!string.IsNullOrWhiteSpace(tenderCode) && balance > 0m)
                                        paymentsToPost.Add((tenderCode, balance));
                                }
                            }
                            catch { }

                            if (createPaymentEntry && paymentsToPost.Count > 0)
                            {
                                try
                                {
                                    // Record payment entry/entries and print on the POS UI thread to ensure currentReceiptNo/currentTransNo are available
                                    mf.Invoke(new Action(() =>
                                    {
                                        try
                                        {
                                            foreach (var p in paymentsToPost)
                                            {
                                                // Pass the online OrderID as Description so the payment row records it
                                                mf.RecordAdvanceOrderPayment(receiptNo!, string.Empty, p.tenderCode, p.amount, orderId, DateTime.Now, null);
                                            }
                                            try { mf.PrintReceiptDirect(receiptNo!); } catch { }
                                        }
                                        catch { }
                                    }));
                                }
                                catch { }

                                // After payment, call cloud GET and capture data.bank_transfer locally (best-effort)
                                try
                                {
                                    var bankTransferJson = TryFetchCloudBankTransferJson(orderId);
                                    if (!string.IsNullOrWhiteSpace(bankTransferJson))
                                    {
                                        PersistBankTransferJsonToLocal(orderId, bankTransferJson!);
                                    }
                                }
                                catch { }
                            }
                        }
                        catch { }

                        return (true, $"Order {orderId} staged into POS with receipt {receiptNo}");
                    }
                }

                // If no MainForm is open, return informative message so caller/UI can decide next steps
                return (false, "Main POS is not open; cannot stage order into sales UI. Please open the main POS screen and try again.");
            }
            catch (Exception ex)
            {
                try { System.Diagnostics.Trace.TraceError($"PushOnlineOrderToPos error: {ex}"); } catch { }
                return (false, "Unexpected error while attempting to stage online order. See application log for details.");
            }
        }

        private static string? TryFetchCloudBankTransferJson(string orderId)
        {
            try
            {
                var baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
                var apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
                var shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
                if (string.IsNullOrWhiteSpace(baseUrl) || string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(shopId))
                    return null;

                var url = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders/{Uri.EscapeDataString(orderId)}?api_key={Uri.EscapeDataString(apiKey)}";
                using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(30) };
                using var resp = http.GetAsync(url).GetAwaiter().GetResult();
                if (!resp.IsSuccessStatusCode) return null;
                var body = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                if (string.IsNullOrWhiteSpace(body)) return null;

                using var doc = System.Text.Json.JsonDocument.Parse(body);
                var root = doc.RootElement;

                // Many endpoints wrap in { data: {...} } or { order: {...} }
                System.Text.Json.JsonElement dataEl;
                bool haveData = false;
                if (root.ValueKind == System.Text.Json.JsonValueKind.Object && root.TryGetProperty("data", out dataEl)) haveData = true;
                else if (root.ValueKind == System.Text.Json.JsonValueKind.Object && root.TryGetProperty("order", out dataEl)) haveData = true;
                else dataEl = root;

                if (haveData && dataEl.ValueKind == System.Text.Json.JsonValueKind.Object && dataEl.TryGetProperty("bank_transfer", out var btEl))
                {
                    // Preserve raw JSON (could be object/array/string)
                    return btEl.GetRawText();
                }

                // Fallback: try root.bank_transfer
                if (root.ValueKind == System.Text.Json.JsonValueKind.Object && root.TryGetProperty("bank_transfer", out var btEl2))
                {
                    return btEl2.GetRawText();
                }
            }
            catch (Exception ex)
            {
                try { System.Diagnostics.Trace.TraceWarning($"TryFetchCloudBankTransferJson failed for {orderId}: {ex.Message}"); } catch { }
            }
            return null;
        }

        private static void PersistBankTransferJsonToLocal(string orderId, string bankTransferJson)
        {
            if (string.IsNullOrWhiteSpace(orderId) || string.IsNullOrWhiteSpace(bankTransferJson)) return;

            try
            {
                using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                conn.Open();

                // Ensure the column exists (safe to run repeatedly)
                string addColSql = @"
                    IF COL_LENGTH('dbo.OnlineOrderHeader','BankTransferJson') IS NULL
                    BEGIN
                        ALTER TABLE dbo.OnlineOrderHeader ADD BankTransferJson NVARCHAR(MAX) NULL
                    END
                ";
                using (var addCmd = new SqlCommand(addColSql, conn))
                    addCmd.ExecuteNonQuery();

                using var upd = new SqlCommand("UPDATE dbo.OnlineOrderHeader SET BankTransferJson = @Json WHERE OrderID = @OrderID", conn);
                upd.Parameters.AddWithValue("@Json", bankTransferJson);
                upd.Parameters.AddWithValue("@OrderID", orderId);
                try { upd.ExecuteNonQuery(); } catch { }
            }
            catch (Exception ex)
            {
                try { System.Diagnostics.Trace.TraceWarning($"PersistBankTransferJsonToLocal failed for {orderId}: {ex.Message}"); } catch { }
            }
        }
    }
}
