using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using System.Linq;

namespace AquariumPOS
{
    /// <summary>
    /// Online/cloud-related helper functions. Kept separate from FunctionEvents to avoid mixing UI/DB helpers with API calls.
    /// </summary>
    public static class OnlinefunctionsEvents
    {
        private const string InstoreOnlineOrderMapTable = "dbo.InstoreOnlineOrderMap";
        // Separate from InstoreOnlineOrderMapTable (which tracks the Pancake order sync and is keyed
        // by ReceiptNo as its PK) because this tracks a different, independent sync - AdvanceOrderHeader/
        // Lines rows pushed to Supabase's AdvanceOrders/AdvanceOrderLines tables for the web portal.
        // Reusing InstoreOnlineOrderMapTable would mean the Pancake and portal statuses for the same
        // receipt fight over the same row.
        private const string AdvanceOrderPortalSyncMapTable = "dbo.AdvanceOrderPortalSyncMap";
        private const string AdvanceOrderTransferVariationId = "1e412dc9-ffde-4b4d-af91-10606f355963";
        public static Action<string>? HttpRequestDebugNotifier { get; set; }

        private static void NotifyHttpRequestDebug(string method, string endpoint, string payloadJson)
        {
            try
            {
                var handler = HttpRequestDebugNotifier;
                if (handler == null)
                    return;

                string bodyText = string.IsNullOrWhiteSpace(payloadJson) ? "(no payload)" : payloadJson;
                handler(
                    $"Method: {method}{Environment.NewLine}{Environment.NewLine}" +
                    $"Endpoint:{Environment.NewLine}{endpoint}{Environment.NewLine}{Environment.NewLine}" +
                    $"Payload:{Environment.NewLine}{bodyText}");
            }
            catch
            {
            }
        }

        public readonly struct TransferOnlineOrderRequestPreview
        {
            public TransferOnlineOrderRequestPreview(string headerMethod, string headerEndpointUrl, string headerPayloadJson, string lineEndpointUrl, string linePayloadJson, string lineRequestPreviewText, string previewWarning)
            {
                HeaderMethod = string.IsNullOrWhiteSpace(headerMethod) ? "POST" : headerMethod.Trim().ToUpperInvariant();
                HeaderEndpointUrl = headerEndpointUrl ?? string.Empty;
                HeaderPayloadJson = headerPayloadJson ?? string.Empty;
                LineEndpointUrl = lineEndpointUrl ?? string.Empty;
                LinePayloadJson = linePayloadJson ?? string.Empty;
                LineRequestPreviewText = lineRequestPreviewText ?? string.Empty;
                PreviewWarning = previewWarning ?? string.Empty;
            }

            public string HeaderMethod { get; }
            public string HeaderEndpointUrl { get; }
            public string HeaderPayloadJson { get; }
            public string LineEndpointUrl { get; }
            public string LinePayloadJson { get; }
            public string LineRequestPreviewText { get; }
            public string PreviewWarning { get; }
        }

        public readonly struct SerialTrackingSyncSummary
        {
            public SerialTrackingSyncSummary(int syncedCount, int insertedCount, int updatedCount, int skippedDueToConflictCount = 0)
            {
                SyncedCount = syncedCount;
                InsertedCount = insertedCount;
                UpdatedCount = updatedCount;
                SkippedDueToConflictCount = skippedDueToConflictCount;
            }

            public int SyncedCount { get; }
            public int InsertedCount { get; }
            public int UpdatedCount { get; }

            /// <summary>
            /// Rows not pushed because Supabase's own UpdatedAtUtc was already newer than this
            /// row's local modification (e.g. the Portal tagged it IN_TRANSIT after this local
            /// row went dirty but before this sync ran) - see SyncItemSerialTrackingToSupabaseAsync.
            /// Left dirty locally on purpose so SyncItemSerialTrackingFromSupabaseAsync's next run
            /// pulls the newer Supabase state down instead.
            /// </summary>
            public int SkippedDueToConflictCount { get; }
        }

        private static async Task<string> PostJsonWithHeadersAsync(string endpointUrl, string payloadJson, TimeSpan timeout)
        {
            using var http = new HttpClient { Timeout = timeout };
            using var req = new HttpRequestMessage(HttpMethod.Post, endpointUrl);
            req.Headers.TryAddWithoutValidation("apikey", GlobalSettings.TransferHeaderSupabaseApiKey);
            req.Headers.TryAddWithoutValidation("Authorization", GlobalSettings.TransferHeaderSupabaseAuthorization);
            req.Content = new StringContent(payloadJson, Encoding.UTF8, "application/json");

            using var resp = await http.SendAsync(req).ConfigureAwait(false);
            var respText = string.Empty;
            try { respText = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { respText = string.Empty; }

            if (!resp.IsSuccessStatusCode)
                throw new HttpRequestException($"Transfer POST failed for '{endpointUrl}': {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respText}");

            return respText ?? string.Empty;
        }

        private static async Task<string> PatchJsonWithHeadersAsync(string endpointUrl, string payloadJson, TimeSpan timeout)
        {
            using var http = new HttpClient { Timeout = timeout };
            using var req = new HttpRequestMessage(new HttpMethod("PATCH"), endpointUrl);
            req.Headers.TryAddWithoutValidation("apikey", GlobalSettings.TransferHeaderSupabaseApiKey);
            req.Headers.TryAddWithoutValidation("Authorization", GlobalSettings.TransferHeaderSupabaseAuthorization);
            req.Content = new StringContent(payloadJson, Encoding.UTF8, "application/json");

            using var resp = await http.SendAsync(req).ConfigureAwait(false);
            var respText = string.Empty;
            try { respText = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { respText = string.Empty; }

            if (!resp.IsSuccessStatusCode)
                throw new HttpRequestException($"Transfer PATCH failed for '{endpointUrl}': {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respText}");

            return respText ?? string.Empty;
        }

        private static string AppendApiKeyIfMissing(string url, string apiKeyValue)
        {
            if (string.IsNullOrWhiteSpace(url)) return url;
            if (url.IndexOf("api_key=", StringComparison.OrdinalIgnoreCase) >= 0) return url;
            var sep = url.Contains("?") ? "&" : "?";
            return url + sep + "api_key=" + Uri.EscapeDataString(apiKeyValue ?? string.Empty);
        }

        private static string ResolveApiUrl(string urlOrPath)
        {
            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string url;
            if (urlOrPath.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || urlOrPath.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                url = urlOrPath.Trim();
            else
                url = baseUrl + "/" + urlOrPath.TrimStart('/');

            return AppendApiKeyIfMissing(url, apiKey);
        }

        /// <summary>
        /// Generic helper for calling the configured online API for purchase-related operations.
        ///
        /// - If <paramref name="urlOrPath"/> is a relative path, it is combined with GlobalSettings.OnlineOrdersApiBaseUrl.
        /// - If the URL/path does not already include an api_key query parameter, GlobalSettings.OnlineOrdersApiKey is appended.
        /// - If <paramref name="bodyJson"/> is provided, it is sent as application/json.
        ///
        /// Returns the response body as a string (throws on non-success HTTP status).
        /// </summary>
        public static string PurchaseApiCall(
            string urlOrPath,
            HttpMethod? method = null,
            string? bodyJson = null,
            TimeSpan? timeout = null)
        {
            return PurchaseApiCallAsync(urlOrPath, method, bodyJson, timeout).GetAwaiter().GetResult();
        }

        public static async Task<string> PurchaseApiCallAsync(
            string urlOrPath,
            HttpMethod? method = null,
            string? bodyJson = null,
            TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(urlOrPath))
                throw new ArgumentException("urlOrPath is required", nameof(urlOrPath));

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            method ??= HttpMethod.Post;
            timeout ??= TimeSpan.FromSeconds(30);

            string url = ResolveApiUrl(urlOrPath);

            using var http = new HttpClient { Timeout = timeout.Value };
            using var req = new HttpRequestMessage(method, url);
            if (bodyJson != null)
            {
                req.Content = new StringContent(bodyJson, Encoding.UTF8, "application/json");
            }

            using var resp = await http.SendAsync(req).ConfigureAwait(false);
            var respText = string.Empty;
            try { respText = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { respText = string.Empty; }

            if (!resp.IsSuccessStatusCode)
                throw new HttpRequestException($"PurchaseApiCall failed: {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respText}");

            return respText ?? string.Empty;
        }

        public static async Task<string> SyncOnlineOrderItemsFromLocalLinesAsync(string orderId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(orderId))
                throw new ArgumentException("orderId is required", nameof(orderId));

            timeout ??= TimeSpan.FromSeconds(30);
            var baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            var apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
            var shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            var itemsPayload = BuildOnlineOrderItemsPayloadFromLocalLines(orderId);
            if (itemsPayload.Count == 0)
                throw new InvalidOperationException($"No local OnlineOrderLines could be mapped for OrderID '{orderId}'.");

            string url = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders/{Uri.EscapeDataString(orderId)}?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000";
            using var http = new HttpClient { Timeout = timeout.Value };

            string? bankPaymentsJson = await GetBankPaymentsSnapshotAsync(http, url).ConfigureAwait(false);
            string bodyJson = JsonSerializer.Serialize(new { items = itemsPayload.ToArray() }, new JsonSerializerOptions
            {
                DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
            });

            async Task<HttpResponseMessage> SendAsync(HttpMethod method)
            {
                var req = new HttpRequestMessage(method, url)
                {
                    Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
                };
                return await http.SendAsync(req).ConfigureAwait(false);
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
                if (!putResp.IsSuccessStatusCode)
                    throw new HttpRequestException($"SyncOnlineOrderItemsFromLocalLines failed: PATCH {(int)patchResp.StatusCode} {patchResp.ReasonPhrase}. Response: {patchText}. PUT {(int)putResp.StatusCode} {putResp.ReasonPhrase}. Response: {putText}");

                if (!string.IsNullOrWhiteSpace(bankPaymentsJson))
                    await RestoreBankPaymentsAsync(http, url, bankPaymentsJson).ConfigureAwait(false);
                return putText;
            }

            throw new HttpRequestException($"SyncOnlineOrderItemsFromLocalLines failed: {(int)patchResp.StatusCode} {patchResp.ReasonPhrase}. Response: {patchText}");
        }

        private static List<object> BuildOnlineOrderItemsPayloadFromLocalLines(string orderId)
        {
            var lines = new List<(string LineId, string ItemCode, string VariationId, decimal Quantity, decimal Price, string Description, string Note)>();

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                conn.Open();
                using var cmd = new SqlCommand("SELECT LineID, ItemCode, product_display_id, VariationId, Quantity, Price, Description, Note FROM dbo.OnlineOrderLines WHERE OrderID = @OrderID ORDER BY LineID", conn);
                cmd.Parameters.AddWithValue("@OrderID", orderId);
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string lineId = string.Empty;
                    string itemCode = string.Empty;
                    string variationId = string.Empty;
                    string description = string.Empty;
                    string note = string.Empty;
                    decimal quantity = 0m;
                    decimal price = 0m;

                    try { lineId = rdr["LineID"]?.ToString()?.Trim() ?? string.Empty; } catch { }
                    try { itemCode = rdr["ItemCode"]?.ToString()?.Trim() ?? string.Empty; } catch { }
                    if (string.IsNullOrWhiteSpace(itemCode))
                    {
                        try { itemCode = rdr["product_display_id"]?.ToString()?.Trim() ?? string.Empty; } catch { }
                    }

                    try { variationId = rdr["VariationId"]?.ToString()?.Trim() ?? string.Empty; } catch { }
                    try { description = rdr["Description"]?.ToString()?.Trim() ?? string.Empty; } catch { }
                    try { note = rdr["Note"]?.ToString()?.Trim() ?? string.Empty; } catch { }
                    try { if (rdr["Quantity"] != DBNull.Value) quantity = Convert.ToDecimal(rdr["Quantity"]); } catch { }
                    try { if (rdr["Price"] != DBNull.Value) price = Convert.ToDecimal(rdr["Price"]); } catch { }

                    lines.Add((lineId, itemCode, variationId, quantity, price, description, note));
                }
            }

            var dedupedLines = new List<(string LineId, string ItemCode, string VariationId, decimal Quantity, decimal Price, string Description, string Note)>();
            var seenKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var line in lines)
            {
                string identity = !string.IsNullOrWhiteSpace(line.VariationId)
                    ? line.VariationId.Trim()
                    : (!string.IsNullOrWhiteSpace(line.ItemCode) ? line.ItemCode.Trim() : (line.Description ?? string.Empty).Trim());
                string dedupeKey = string.Join("|",
                    identity,
                    line.Note?.Trim() ?? string.Empty,
                    line.Description?.Trim() ?? string.Empty,
                    line.Quantity.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture),
                    line.Price.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture));

                if (seenKeys.Contains(dedupeKey))
                {
                    continue;
                }

                seenKeys.Add(dedupeKey);
                dedupedLines.Add(line);
            }

            var payload = new List<object>();
            foreach (var line in dedupedLines)
            {
                string lineId = line.LineId;
                string itemCode = line.ItemCode;
                string variationId = line.VariationId;
                string description = line.Description;
                string note = line.Note;
                decimal quantity = Math.Abs(line.Quantity);
                decimal price = Math.Round(line.Price, 0, MidpointRounding.AwayFromZero);

                if (quantity == 0m)
                    quantity = 1m;

                if (string.IsNullOrWhiteSpace(variationId) && !string.IsNullOrWhiteSpace(itemCode))
                {
                    try
                    {
                        using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                        conn.Open();
                        using var cmd = new SqlCommand("SELECT TOP 1 ISNULL(VariationId, '') FROM dbo.Items WHERE Code = @Code OR VariationId = @Code", conn);
                        cmd.Parameters.AddWithValue("@Code", itemCode);
                        var value = cmd.ExecuteScalar();
                        variationId = value == null || value == DBNull.Value ? string.Empty : (value.ToString()?.Trim() ?? string.Empty);
                    }
                    catch { }
                }

                string lineName = !string.IsNullOrWhiteSpace(description)
                    ? description
                    : (!string.IsNullOrWhiteSpace(itemCode) ? itemCode : "Online Item");

                bool isOneTimeProduct = string.IsNullOrWhiteSpace(variationId);
                payload.Add(new
                {
                    line_id = string.IsNullOrWhiteSpace(lineId) ? null : lineId,
                    discount_each_product = 0,
                    is_bonus_product = false,
                    is_discount_percent = false,
                    is_wholesale = false,
                    one_time_product = isOneTimeProduct,
                    quantity = quantity,
                    variation_id = isOneTimeProduct ? null : variationId,
                    note = string.IsNullOrWhiteSpace(note) ? null : note,
                    variation_info = new
                    {
                        detail = description,
                        fields = (object?)null,
                        display_id = string.IsNullOrWhiteSpace(itemCode) ? null : itemCode,
                        name = lineName,
                        product_display_id = string.IsNullOrWhiteSpace(itemCode) ? null : itemCode,
                        retail_price = price,
                        weight = 100
                    }
                });
            }

            return payload;
        }

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
            }

            return null;
        }

        private static async Task RestoreBankPaymentsAsync(HttpClient http, string url, string bankPaymentsJson)
        {
            if (string.IsNullOrWhiteSpace(bankPaymentsJson))
                return;

            try
            {
                var bpBody = "{\"bank_payments\": " + bankPaymentsJson + "}";
                using var bpContent = new StringContent(bpBody, Encoding.UTF8, "application/json");
                var bpRequest = new HttpRequestMessage(new HttpMethod("PATCH"), url) { Content = bpContent };
                using var bpResp = await http.SendAsync(bpRequest).ConfigureAwait(false);
            }
            catch
            {
            }
        }

        // Widened from private to internal so callers outside this class (AdvanceOrdersHeaderForm,
        // AdvanceOrderLinesForm) can defensively ensure this table exists before querying it
        // directly for Pancake sync status display - a fresh install may not have it yet if no
        // sync has ever run.
        internal static void EnsureInstoreOnlineOrderMapTable()
        {
            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();

            var sql = $@"
IF OBJECT_ID('{InstoreOnlineOrderMapTable}', 'U') IS NULL
BEGIN
    CREATE TABLE {InstoreOnlineOrderMapTable} (
        LocalReceiptNo NVARCHAR(100) NOT NULL PRIMARY KEY,
        OnlineOrderId NVARCHAR(100) NULL,
        LocalType NVARCHAR(50) NULL,
        LastAction NVARCHAR(20) NULL,
        LastResponse NVARCHAR(MAX) NULL,
        CreatedAtUtc DATETIME2 NOT NULL CONSTRAINT DF_InstoreOnlineOrderMap_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        UpdatedAtUtc DATETIME2 NOT NULL CONSTRAINT DF_InstoreOnlineOrderMap_UpdatedAtUtc DEFAULT SYSUTCDATETIME()
    );
END";

            using var cmd = new SqlCommand(sql, conn);
            cmd.ExecuteNonQuery();
        }

        private static string ExtractOnlineOrderId(string responseText)
        {
            if (string.IsNullOrWhiteSpace(responseText))
                return string.Empty;

            static bool LooksLikeLocalReceiptNo(string? value)
            {
                if (string.IsNullOrWhiteSpace(value))
                    return false;

                return value.Trim().StartsWith("RS-", StringComparison.OrdinalIgnoreCase);
            }

            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var name in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var value))
                        {
                            if (value.ValueKind == JsonValueKind.String)
                                return value.GetString() ?? string.Empty;
                            if (value.ValueKind == JsonValueKind.Number)
                                return value.ToString();
                        }
                    }
                    catch { }
                }

                return string.Empty;
            }

            try
            {
                using var doc = JsonDocument.Parse(responseText);
                var root = doc.RootElement;
                string id;

                if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("data", out var dataProp))
                {
                    if (dataProp.ValueKind == JsonValueKind.Object)
                    {
                        id = GetString(dataProp, "order_id", "OrderID", "id", "ID");
                        if (!string.IsNullOrWhiteSpace(id))
                            return id.Trim();
                    }
                    else if (dataProp.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var item in dataProp.EnumerateArray())
                        {
                            id = GetString(item, "order_id", "OrderID", "id", "ID");
                            if (!string.IsNullOrWhiteSpace(id) && !LooksLikeLocalReceiptNo(id))
                                return id.Trim();
                        }
                    }
                }

                if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("order", out var orderProp) && orderProp.ValueKind == JsonValueKind.Object)
                {
                    id = GetString(orderProp, "order_id", "OrderID", "id", "ID");
                    if (!string.IsNullOrWhiteSpace(id) && !LooksLikeLocalReceiptNo(id))
                        return id.Trim();
                }

                id = GetString(root, "order_id", "OrderID", "id", "ID");
                if (!string.IsNullOrWhiteSpace(id))
                    return id.Trim();
            }
            catch
            {
                // Ignore parse errors and return empty.
            }

            return string.Empty;
        }

        private static string ExtractOnlineOrderIdByCustomId(string responseText, string customId)
        {
            if (string.IsNullOrWhiteSpace(responseText) || string.IsNullOrWhiteSpace(customId))
                return string.Empty;

            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var name in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var value))
                        {
                            if (value.ValueKind == JsonValueKind.String)
                                return value.GetString() ?? string.Empty;
                            if (value.ValueKind == JsonValueKind.Number)
                                return value.ToString();
                        }
                    }
                    catch { }
                }

                return string.Empty;
            }

            static string FindMatchingOrderId(JsonElement element, string expectedCustomId)
            {
                try
                {
                    if (element.ValueKind == JsonValueKind.Object)
                    {
                        string elementCustomId = GetString(element, "custom_id", "customId").Trim();
                        string elementOrderId = GetString(element, "order_id", "OrderID", "id", "ID").Trim();
                        if (!string.IsNullOrWhiteSpace(elementCustomId)
                            && string.Equals(elementCustomId, expectedCustomId, StringComparison.OrdinalIgnoreCase)
                            && !string.IsNullOrWhiteSpace(elementOrderId))
                        {
                            return elementOrderId;
                        }

                        foreach (var prop in element.EnumerateObject())
                        {
                            string nested = FindMatchingOrderId(prop.Value, expectedCustomId);
                            if (!string.IsNullOrWhiteSpace(nested))
                                return nested;
                        }
                    }
                    else if (element.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var item in element.EnumerateArray())
                        {
                            string nested = FindMatchingOrderId(item, expectedCustomId);
                            if (!string.IsNullOrWhiteSpace(nested))
                                return nested;
                        }
                    }
                }
                catch { }

                return string.Empty;
            }

            try
            {
                using var doc = JsonDocument.Parse(responseText);
                return FindMatchingOrderId(doc.RootElement, customId.Trim());
            }
            catch
            {
                return string.Empty;
            }
        }

        private static async Task<string> FindOnlineOrderIdByCustomIdAsync(string baseUrl, string apiKey, string shopId, string customId, TimeSpan timeout)
        {
            if (string.IsNullOrWhiteSpace(baseUrl)
                || string.IsNullOrWhiteSpace(apiKey)
                || string.IsNullOrWhiteSpace(shopId)
                || string.IsNullOrWhiteSpace(customId))
            {
                return string.Empty;
            }

            using var http = new HttpClient { Timeout = timeout };

            async Task<string> TryLookupAsync(string url)
            {
                try
                {
                    using var resp = await http.GetAsync(url).ConfigureAwait(false);
                    if (!resp.IsSuccessStatusCode)
                        return string.Empty;

                    string responseText = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    return ExtractOnlineOrderIdByCustomId(responseText, customId);
                }
                catch
                {
                    return string.Empty;
                }
            }

            string escapedShopId = Uri.EscapeDataString(shopId);
            string escapedApiKey = Uri.EscapeDataString(apiKey);
            string escapedCustomId = Uri.EscapeDataString(customId);
            string[] candidateUrls =
            {
                $"{baseUrl}/shops/{escapedShopId}/orders?custom_id={escapedCustomId}&api_key={escapedApiKey}",
                $"{baseUrl}/shops/{escapedShopId}/orders?keyword={escapedCustomId}&api_key={escapedApiKey}",
                $"{baseUrl}/shops/{escapedShopId}/orders?api_key={escapedApiKey}"
            };

            foreach (var url in candidateUrls)
            {
                string onlineOrderId = await TryLookupAsync(url).ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(onlineOrderId))
                    return onlineOrderId;
            }

            return string.Empty;
        }

        private static string GetMappedOnlineOrderId(string receiptNo)
        {
            EnsureInstoreOnlineOrderMapTable();

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();
            using var cmd = new SqlCommand($"SELECT TOP 1 OnlineOrderId, LastResponse FROM {InstoreOnlineOrderMapTable} WHERE LocalReceiptNo = @receiptNo", conn);
            cmd.Parameters.AddWithValue("@receiptNo", receiptNo ?? string.Empty);
            using var rdr = cmd.ExecuteReader();
            if (!rdr.Read())
                return string.Empty;

            string mappedOrderId = rdr["OnlineOrderId"]?.ToString()?.Trim() ?? string.Empty;
            string lastResponse = rdr["LastResponse"]?.ToString() ?? string.Empty;

            bool looksLikeLocalReceipt = !string.IsNullOrWhiteSpace(mappedOrderId)
                && mappedOrderId.StartsWith("RS-", StringComparison.OrdinalIgnoreCase);

            if (!looksLikeLocalReceipt)
                return mappedOrderId;

            string extractedOrderId = ExtractOnlineOrderId(lastResponse);
            if (string.IsNullOrWhiteSpace(extractedOrderId) || extractedOrderId.StartsWith("RS-", StringComparison.OrdinalIgnoreCase))
                return mappedOrderId;

            rdr.Close();
            using var fixCmd = new SqlCommand($"UPDATE {InstoreOnlineOrderMapTable} SET OnlineOrderId = @onlineOrderId, UpdatedAtUtc = SYSUTCDATETIME() WHERE LocalReceiptNo = @receiptNo", conn);
            fixCmd.Parameters.AddWithValue("@onlineOrderId", extractedOrderId);
            fixCmd.Parameters.AddWithValue("@receiptNo", receiptNo ?? string.Empty);
            fixCmd.ExecuteNonQuery();
            return extractedOrderId;
        }

        public static string GetMappedOnlineOrderIdForReceipt(string receiptNo)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                return string.Empty;

            try
            {
                return GetMappedOnlineOrderId(receiptNo);
            }
            catch
            {
                return string.Empty;
            }
        }

        private static void UpsertInstoreOnlineOrderMap(string receiptNo, string onlineOrderId, string localType, string lastAction, string responseText)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                return;

            EnsureInstoreOnlineOrderMapTable();

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();

            var sql = $@"
MERGE {InstoreOnlineOrderMapTable} AS target
USING (SELECT @LocalReceiptNo AS LocalReceiptNo) AS source
ON target.LocalReceiptNo = source.LocalReceiptNo
WHEN MATCHED THEN
    UPDATE SET
        OnlineOrderId = CASE WHEN NULLIF(@OnlineOrderId, '') IS NULL THEN target.OnlineOrderId ELSE @OnlineOrderId END,
        LocalType = @LocalType,
        LastAction = @LastAction,
        LastResponse = @LastResponse,
        UpdatedAtUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (LocalReceiptNo, OnlineOrderId, LocalType, LastAction, LastResponse, CreatedAtUtc, UpdatedAtUtc)
    VALUES (@LocalReceiptNo, NULLIF(@OnlineOrderId, ''), @LocalType, @LastAction, @LastResponse, SYSUTCDATETIME(), SYSUTCDATETIME());";

            using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("@LocalReceiptNo", receiptNo.Trim());
            cmd.Parameters.AddWithValue("@OnlineOrderId", (object?)(onlineOrderId?.Trim() ?? string.Empty) ?? string.Empty);
            cmd.Parameters.AddWithValue("@LocalType", (object?)(localType ?? string.Empty) ?? string.Empty);
            cmd.Parameters.AddWithValue("@LastAction", (object?)(lastAction ?? string.Empty) ?? string.Empty);
            cmd.Parameters.AddWithValue("@LastResponse", (object?)(responseText ?? string.Empty) ?? string.Empty);
            cmd.ExecuteNonQuery();
        }

        // AdvanceOrderHeader has its own OnlineOrderID column (added directly against the live DB,
        // not present in every install) separate from dbo.InstoreOnlineOrderMap's mapping row - the
        // latter is what SyncAdvanceOrderToCloud actually keys off of to decide CREATE vs UPDATE, but
        // callers displaying/reporting on AdvanceOrderHeader directly (grids, Supabase sync) had no
        // way to see the Pancake order id without also joining that side table. Best-effort/no-op if
        // the column doesn't exist on this install - never masks the real sync success/failure.
        private static void UpdateAdvanceOrderHeaderOnlineOrderId(string receiptNo, string onlineOrderId)
        {
            if (string.IsNullOrWhiteSpace(receiptNo) || string.IsNullOrWhiteSpace(onlineOrderId))
                return;

            try
            {
                using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                conn.Open();

                using var checkCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'AdvanceOrderHeader' AND COLUMN_NAME = 'OnlineOrderID'", conn);
                if (checkCmd.ExecuteScalar() == null)
                    return;

                using var cmd = new SqlCommand("UPDATE dbo.AdvanceOrderHeader SET OnlineOrderID = @OnlineOrderId WHERE ReceiptNo = @ReceiptNo", conn);
                cmd.Parameters.AddWithValue("@OnlineOrderId", onlineOrderId.Trim());
                cmd.Parameters.AddWithValue("@ReceiptNo", receiptNo.Trim());
                cmd.ExecuteNonQuery();
            }
            catch
            {
                // best-effort - never mask the original sync success/failure
            }
        }

        // Widened from private to internal for the same reason as EnsureInstoreOnlineOrderMapTable
        // above - AdvanceOrdersHeaderForm/AdvanceOrderLinesForm need to defensively ensure this
        // table exists before querying it directly for the "Portal Status" display, since a fresh
        // install (or one that's never posted an advance order since this shipped) may not have it.
        internal static void EnsureAdvanceOrderPortalSyncMapTable()
        {
            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();

            var sql = $@"
IF OBJECT_ID('{AdvanceOrderPortalSyncMapTable}', 'U') IS NULL
BEGIN
    CREATE TABLE {AdvanceOrderPortalSyncMapTable} (
        ReceiptNo NVARCHAR(100) NOT NULL PRIMARY KEY,
        LastAction NVARCHAR(20) NULL,
        LastResponse NVARCHAR(MAX) NULL,
        CreatedAtUtc DATETIME2 NOT NULL CONSTRAINT DF_AdvanceOrderPortalSyncMap_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        UpdatedAtUtc DATETIME2 NOT NULL CONSTRAINT DF_AdvanceOrderPortalSyncMap_UpdatedAtUtc DEFAULT SYSUTCDATETIME()
    );
END";

            using var cmd = new SqlCommand(sql, conn);
            cmd.ExecuteNonQuery();
        }

        private static void UpsertAdvanceOrderPortalSyncStatus(string receiptNo, string lastAction, string responseText)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                return;

            EnsureAdvanceOrderPortalSyncMapTable();

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();

            var sql = $@"
MERGE {AdvanceOrderPortalSyncMapTable} AS target
USING (SELECT @ReceiptNo AS ReceiptNo) AS source
ON target.ReceiptNo = source.ReceiptNo
WHEN MATCHED THEN
    UPDATE SET
        LastAction = @LastAction,
        LastResponse = @LastResponse,
        UpdatedAtUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (ReceiptNo, LastAction, LastResponse, CreatedAtUtc, UpdatedAtUtc)
    VALUES (@ReceiptNo, @LastAction, @LastResponse, SYSUTCDATETIME(), SYSUTCDATETIME());";

            using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("@ReceiptNo", receiptNo.Trim());
            cmd.Parameters.AddWithValue("@LastAction", (object?)(lastAction ?? string.Empty) ?? string.Empty);
            cmd.Parameters.AddWithValue("@LastResponse", (object?)(responseText ?? string.Empty) ?? string.Empty);
            cmd.ExecuteNonQuery();
        }

        private static void MarkReceiptSentToOnline(string receiptNo)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                return;

            try
            {
                using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                conn.Open();
                using var cmd = new SqlCommand("UPDATE TransactionHeader SET SentToOnline = 1 WHERE ReceiptNo = @ReceiptNo", conn);
                cmd.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                cmd.ExecuteNonQuery();
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Failed to mark advance receipt '{receiptNo}' as sent to online: {ex.Message}");
            }
        }

        private sealed class AdvanceOrderCloudContext
        {
            public string ReceiptNo { get; set; } = string.Empty;
            public string TransactionNo { get; set; } = string.Empty;
            public string UserId { get; set; } = string.Empty;
            public string CustomerName { get; set; } = string.Empty;
            public string OrderDescription { get; set; } = string.Empty;
            public string OrderDate { get; set; } = string.Empty;
            public string OrderTime { get; set; } = string.Empty;
            public decimal Discount { get; set; }
            public decimal NetAmount { get; set; }
            public decimal Downpayment { get; set; }
            public decimal Balance { get; set; }
            public decimal GrossAmount { get; set; }
            public List<AdvanceOrderCloudItemLine> ItemLines { get; } = new List<AdvanceOrderCloudItemLine>();
            public List<object> ItemsPayload { get; } = new List<object>();
            public Dictionary<string, decimal> BankPayments { get; } = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
            public decimal CashAmount { get; set; }
            public string StateLabel => Balance <= 0m ? "PAID IN FULL" : "PARTIALLY PAID";
        }

        private sealed class AdvanceOrderCloudItemLine
        {
            public string ItemCode { get; set; } = string.Empty;
            public string Description { get; set; } = string.Empty;
            public decimal Quantity { get; set; }
            public decimal Price { get; set; }
            public decimal Discount { get; set; }
            public decimal GrossAmount { get; set; }
            public decimal NetAmount { get; set; }
            public string VariationId { get; set; } = string.Empty;
        }

        private sealed class WarehouseDefaultCustomerProfile
        {
            public string CustomerId { get; set; } = string.Empty;
            public string Name { get; set; } = string.Empty;
            public string PhoneNumber { get; set; } = string.Empty;
            public string EmailAddress { get; set; } = string.Empty;
            public string Address { get; set; } = string.Empty;
        }

        private sealed class WarehouseDefaultCustomerLookupResult
        {
            public string WarehouseTableName { get; set; } = string.Empty;
            public string WarehouseDefaultCustomerId { get; set; } = string.Empty;
            public string WarehouseDefaultCustomerName { get; set; } = string.Empty;
            public string StatusMessage { get; set; } = string.Empty;
            public WarehouseDefaultCustomerProfile? Profile { get; set; }
        }

        private static AdvanceOrderCloudContext LoadAdvanceOrderCloudContext(string receiptNo)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                throw new ArgumentException("receiptNo is required", nameof(receiptNo));

            var context = new AdvanceOrderCloudContext
            {
                ReceiptNo = receiptNo.Trim()
            };

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();

            bool headerLoaded = false;
            try
            {
                using var cmd = new SqlCommand(@"
SELECT TOP 1 TransactionNo, ReceiptNo, UserID, Discount, NetAmount, Downpayment, Balance, CustomerName, Order_Description, [Date], [Time]
FROM AdvanceOrderHeader
WHERE ReceiptNo = @ReceiptNo
ORDER BY TransactionNo DESC", conn);
                cmd.Parameters.AddWithValue("@ReceiptNo", context.ReceiptNo);

                using var rdr = cmd.ExecuteReader();
                if (rdr.Read())
                {
                    context.TransactionNo = rdr["TransactionNo"]?.ToString()?.Trim() ?? string.Empty;
                    context.ReceiptNo = rdr["ReceiptNo"]?.ToString()?.Trim() ?? context.ReceiptNo;
                    context.UserId = rdr["UserID"]?.ToString()?.Trim() ?? string.Empty;
                    context.CustomerName = rdr["CustomerName"]?.ToString()?.Trim() ?? string.Empty;
                    context.OrderDescription = rdr["Order_Description"]?.ToString()?.Trim() ?? string.Empty;
                    context.OrderDate = rdr["Date"]?.ToString()?.Trim() ?? string.Empty;
                    context.OrderTime = rdr["Time"]?.ToString()?.Trim() ?? string.Empty;
                    context.Discount = rdr["Discount"] != DBNull.Value ? Convert.ToDecimal(rdr["Discount"]) : 0m;
                    context.NetAmount = rdr["NetAmount"] != DBNull.Value ? Convert.ToDecimal(rdr["NetAmount"]) : 0m;
                    context.Downpayment = rdr["Downpayment"] != DBNull.Value ? Convert.ToDecimal(rdr["Downpayment"]) : 0m;
                    context.Balance = rdr["Balance"] != DBNull.Value ? Convert.ToDecimal(rdr["Balance"]) : 0m;
                    context.GrossAmount = context.NetAmount + context.Discount;
                    headerLoaded = true;
                }
            }
            catch
            {
                using var cmd = new SqlCommand(@"
SELECT TOP 1 TransactionNo, ReceiptNo, UserID, Discount, NetAmount, Downpayment, Balance, [Date], [Time]
FROM AdvanceOrderHeader
WHERE ReceiptNo = @ReceiptNo
ORDER BY TransactionNo DESC", conn);
                cmd.Parameters.AddWithValue("@ReceiptNo", context.ReceiptNo);

                using var rdr = cmd.ExecuteReader();
                if (rdr.Read())
                {
                    context.TransactionNo = rdr["TransactionNo"]?.ToString()?.Trim() ?? string.Empty;
                    context.ReceiptNo = rdr["ReceiptNo"]?.ToString()?.Trim() ?? context.ReceiptNo;
                    context.UserId = rdr["UserID"]?.ToString()?.Trim() ?? string.Empty;
                    context.OrderDate = rdr["Date"]?.ToString()?.Trim() ?? string.Empty;
                    context.OrderTime = rdr["Time"]?.ToString()?.Trim() ?? string.Empty;
                    context.Discount = rdr["Discount"] != DBNull.Value ? Convert.ToDecimal(rdr["Discount"]) : 0m;
                    context.NetAmount = rdr["NetAmount"] != DBNull.Value ? Convert.ToDecimal(rdr["NetAmount"]) : 0m;
                    context.Downpayment = rdr["Downpayment"] != DBNull.Value ? Convert.ToDecimal(rdr["Downpayment"]) : 0m;
                    context.Balance = rdr["Balance"] != DBNull.Value ? Convert.ToDecimal(rdr["Balance"]) : 0m;
                    context.GrossAmount = context.NetAmount + context.Discount;
                    headerLoaded = true;
                }
            }

            if (!headerLoaded)
                throw new InvalidOperationException($"AdvanceOrderHeader not found for receipt '{receiptNo}'.");

            bool advanceOrderLinesHasVariationId = false;
            try
            {
                using var checkVariationCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'AdvanceOrderLines' AND COLUMN_NAME = 'VariationId'", conn);
                advanceOrderLinesHasVariationId = checkVariationCmd.ExecuteScalar() != null;
            }
            catch
            {
                advanceOrderLinesHasVariationId = false;
            }

            string itemsSql = advanceOrderLinesHasVariationId
                ? @"
SELECT aol.[No.], aol.Description, aol.Quantity, aol.Price, aol.Discount, aol.GrossAmount, aol.NetAmount,
       ISNULL(NULLIF(aol.VariationId, ''), ISNULL(i.VariationId, '')) AS VariationId
FROM AdvanceOrderLines aol
LEFT JOIN Items i ON i.Code = aol.[No.]
WHERE aol.ReceiptNo = @ReceiptNo AND UPPER(ISNULL(aol.Type, '')) = 'ITEM'
ORDER BY aol.[LineNo]"
                : @"
SELECT aol.[No.], aol.Description, aol.Quantity, aol.Price, aol.Discount, aol.GrossAmount, aol.NetAmount,
       ISNULL(i.VariationId, '') AS VariationId
FROM AdvanceOrderLines aol
LEFT JOIN Items i ON i.Code = aol.[No.]
WHERE aol.ReceiptNo = @ReceiptNo AND UPPER(ISNULL(aol.Type, '')) = 'ITEM'
ORDER BY aol.[LineNo]";

            using (var itemsCmd = new SqlCommand(itemsSql, conn))
            {
                itemsCmd.Parameters.AddWithValue("@ReceiptNo", context.ReceiptNo);
                using var itemsRdr = itemsCmd.ExecuteReader();
                while (itemsRdr.Read())
                {
                    string itemCode = itemsRdr[0]?.ToString()?.Trim() ?? string.Empty;
                    string description = itemsRdr[1]?.ToString()?.Trim() ?? string.Empty;
                    decimal quantity = itemsRdr[2] != DBNull.Value ? Convert.ToDecimal(itemsRdr[2]) : 1m;
                    decimal price = itemsRdr[3] != DBNull.Value ? Convert.ToDecimal(itemsRdr[3]) : 0m;
                    decimal discount = itemsRdr[4] != DBNull.Value ? Convert.ToDecimal(itemsRdr[4]) : 0m;
                    decimal grossAmount = itemsRdr[5] != DBNull.Value ? Convert.ToDecimal(itemsRdr[5]) : price * quantity;
                    decimal netAmount = itemsRdr[6] != DBNull.Value ? Convert.ToDecimal(itemsRdr[6]) : grossAmount;

                    if (quantity == 0m)
                        quantity = 1m;

                    string variationId = itemsRdr[7]?.ToString()?.Trim() ?? string.Empty;
                    context.ItemLines.Add(new AdvanceOrderCloudItemLine
                    {
                        ItemCode = itemCode,
                        Description = description,
                        Quantity = quantity,
                        Price = price,
                        Discount = discount,
                        GrossAmount = grossAmount,
                        NetAmount = netAmount,
                        VariationId = variationId
                    });

                    var unitRetailPriceValue = price != 0m ? Math.Abs(price) : (Math.Abs(quantity) != 0m ? (Math.Abs(grossAmount != 0m ? grossAmount : netAmount) / Math.Abs(quantity)) : Math.Abs(netAmount));
                unitRetailPriceValue = Math.Round(unitRetailPriceValue, 0, MidpointRounding.AwayFromZero);

                    var lineName = !string.IsNullOrWhiteSpace(description)
                        ? description
                        : (!string.IsNullOrWhiteSpace(itemCode) ? itemCode : "Advance Item");
                    string? lineNote = !string.IsNullOrWhiteSpace(description)
                        ? description
                        : (!string.IsNullOrWhiteSpace(itemCode) ? itemCode : null);

                    bool isOneTimeProduct = string.IsNullOrWhiteSpace(variationId);

                    context.ItemsPayload.Add(new
                    {
                        discount_each_product = 0,
                        is_bonus_product = false,
                        is_discount_percent = false,
                        is_wholesale = false,
                        one_time_product = isOneTimeProduct,
                        quantity = Math.Abs(quantity),
                        variation_id = isOneTimeProduct ? null : variationId,
                        note = lineNote,
                        variation_info = new
                        {
                            detail = description,
                            fields = (object?)null,
                            display_id = string.IsNullOrWhiteSpace(itemCode) ? null : itemCode,
                            name = lineName,
                            product_display_id = string.IsNullOrWhiteSpace(itemCode) ? null : itemCode,
                            retail_price = unitRetailPriceValue,
                            weight = 100
                        }
                    });
                }
            }

            if (context.ItemsPayload.Count == 0)
                throw new InvalidOperationException($"No advance-order item lines found for receipt '{receiptNo}'.");

            void AccumulatePayment(string tenderCode, string posBankId, decimal amount)
            {
                if (amount == 0m)
                    return;

                if (string.Equals(tenderCode, "CASH", StringComparison.OrdinalIgnoreCase))
                {
                    context.CashAmount += Math.Abs(amount);
                    return;
                }

                if (string.IsNullOrWhiteSpace(posBankId))
                    return;

                if (context.BankPayments.TryGetValue(posBankId, out var existing))
                    context.BankPayments[posBankId] = existing + Math.Abs(amount);
                else
                    context.BankPayments[posBankId] = Math.Abs(amount);
            }

            bool loadedFromTransPaymentEntry = false;
            using (var payCmd = new SqlCommand(@"
SELECT tpe.TenderTypeCode, tt.POSBankID, tpe.Amount
FROM TransPaymentEntry tpe
LEFT JOIN TenderTypes tt ON tt.Code = tpe.TenderTypeCode
WHERE tpe.ReceiptNo = @ReceiptNo", conn))
            {
                payCmd.Parameters.AddWithValue("@ReceiptNo", context.ReceiptNo);
                using var payRdr = payCmd.ExecuteReader();
                while (payRdr.Read())
                {
                    loadedFromTransPaymentEntry = true;
                    string tenderCode = payRdr["TenderTypeCode"]?.ToString()?.Trim() ?? string.Empty;
                    string posBankId = payRdr["POSBankID"]?.ToString()?.Trim() ?? string.Empty;
                    decimal amount = payRdr["Amount"] != DBNull.Value ? Convert.ToDecimal(payRdr["Amount"]) : 0m;
                    AccumulatePayment(tenderCode, posBankId, amount);
                }
            }

            if (!loadedFromTransPaymentEntry)
            {
                using var payCmd = new SqlCommand(@"
SELECT aol.[No.] AS TenderTypeCode, tt.POSBankID, aol.NetAmount
FROM AdvanceOrderLines aol
LEFT JOIN TenderTypes tt ON tt.Code = aol.[No.]
WHERE aol.ReceiptNo = @ReceiptNo AND UPPER(ISNULL(aol.Type, '')) = 'PAYMENT'", conn);
                payCmd.Parameters.AddWithValue("@ReceiptNo", context.ReceiptNo);
                using var payRdr = payCmd.ExecuteReader();
                while (payRdr.Read())
                {
                    string tenderCode = payRdr["TenderTypeCode"]?.ToString()?.Trim() ?? string.Empty;
                    string posBankId = payRdr["POSBankID"]?.ToString()?.Trim() ?? string.Empty;
                    decimal amount = payRdr["NetAmount"] != DBNull.Value ? Convert.ToDecimal(payRdr["NetAmount"]) : 0m;
                    AccumulatePayment(tenderCode, posBankId, amount);
                }
            }

            return context;
        }

        private static string BuildAdvanceOrderCloudPayload(string shopId, string warehouseId, AdvanceOrderCloudContext context, WarehouseDefaultCustomerProfile? customerProfile, bool includeLineLevelDiscounts, bool addTransferProduct)
        {
            string paymentSummary = BuildAdvanceOrderPaymentSummary(context);
            string customerName = string.IsNullOrWhiteSpace(customerProfile?.Name) ? "ADVANCE-ORDER-CUSTOMER" : customerProfile!.Name.Trim();
            string? customerId = string.IsNullOrWhiteSpace(customerProfile?.CustomerId) ? null : customerProfile!.CustomerId.Trim();
            string? phoneNumber = string.IsNullOrWhiteSpace(customerProfile?.PhoneNumber) ? null : customerProfile!.PhoneNumber.Trim();
            string? emailAddress = string.IsNullOrWhiteSpace(customerProfile?.EmailAddress) ? null : customerProfile!.EmailAddress.Trim();
            string fullAddress = string.IsNullOrWhiteSpace(customerProfile?.Address) ? customerName : customerProfile!.Address.Trim();
            string note = $"Advance Order Ref: {context.ReceiptNo}";
            if (!string.IsNullOrWhiteSpace(context.CustomerName))
                note += $" | Customer: {context.CustomerName}";
            if (!string.IsNullOrWhiteSpace(context.OrderDescription))
                note += $" | Order: {context.OrderDescription}";
            if (!string.IsNullOrWhiteSpace(context.OrderDate) || !string.IsNullOrWhiteSpace(context.OrderTime))
                note += $" | Date: {context.OrderDate} {context.OrderTime}".TrimEnd();
            if (!string.IsNullOrWhiteSpace(context.UserId))
                note += $" | Cashier: {context.UserId}";
            note += $" | State: {context.StateLabel}";
            if (!string.IsNullOrWhiteSpace(paymentSummary))
                note += $" | Payments: {paymentSummary}";

            var bodyPayload = new
            {
                customer_id = customerId,
                bill_full_name = customerName,
                bill_phone_number = phoneNumber,
                bill_email = emailAddress,
                email = emailAddress,
                received_at_shop = false,
                is_free_shipping = false,
                assigning_seller_id = string.Empty,
                items = BuildAdvanceOrderItemsPayload(context, includeLineLevelDiscounts, addTransferProduct),
                note = note,
                note_print = (object?)null,
                merge_order = false,
                returned_reason = 1,
                warehouse_id = warehouseId,
                shipping_address = new
                {
                    address = fullAddress,
                    full_address = fullAddress,
                    full_name = customerName,
                    phone_number = phoneNumber
                },
                shipping_fee = 0,
                shop_id = shopId,
                status = 0,
                bank_payments = context.BankPayments,
                cash = Math.Round(Math.Abs(context.CashAmount), 0, MidpointRounding.AwayFromZero)
            };

            return JsonSerializer.Serialize(bodyPayload, new JsonSerializerOptions
            {
                DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
            });
        }

        private static async Task<WarehouseDefaultCustomerLookupResult> GetCurrentWarehouseDefaultCustomerProfileAsync(string shopId)
        {
            string[] candidates = { "dbo.Warehouses", "Warehouses" };
            string lastStatusMessage = "No warehouse default customer lookup was attempted.";

            foreach (var tableName in candidates)
            {
                try
                {
                    using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                    await conn.OpenAsync().ConfigureAwait(false);

                    string? schema = null;
                    string bareTableName = tableName;
                    if (tableName.Contains('.'))
                    {
                        var parts = tableName.Split(new[] { '.' }, 2);
                        schema = parts[0];
                        bareTableName = parts[1];
                    }

                    bool hasCurrentLocation = false;
                    bool hasCurrentWarehouse = false;
                    bool hasDefaultCustomer = false;
                    bool hasDefaultCustomerId = false;
                    string shopCol = string.Empty;

                    using (var colCmd = new SqlCommand(@"SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND (TABLE_SCHEMA=@s OR @s IS NULL)", conn))
                    {
                        colCmd.Parameters.AddWithValue("@t", bareTableName);
                        colCmd.Parameters.AddWithValue("@s", (object?)schema ?? DBNull.Value);
                        using var rdr = await colCmd.ExecuteReaderAsync().ConfigureAwait(false);
                        while (await rdr.ReadAsync().ConfigureAwait(false))
                        {
                            var c = rdr[0]?.ToString() ?? string.Empty;
                            if (c.Equals("Current_Location", StringComparison.OrdinalIgnoreCase)) hasCurrentLocation = true;
                            if (c.Equals("Current_Warehouse", StringComparison.OrdinalIgnoreCase)) hasCurrentWarehouse = true;
                            if (c.Equals("Default_Customer", StringComparison.OrdinalIgnoreCase)) hasDefaultCustomer = true;
                            if (c.Equals("Default_Customer_ID", StringComparison.OrdinalIgnoreCase)) hasDefaultCustomerId = true;
                            if (c.Equals("ShopID", StringComparison.OrdinalIgnoreCase)) shopCol = "ShopID";
                            else if (string.IsNullOrEmpty(shopCol) && c.Equals("ShopId", StringComparison.OrdinalIgnoreCase)) shopCol = "ShopId";
                        }
                    }

                    if (!hasDefaultCustomer && !hasDefaultCustomerId)
                    {
                        lastStatusMessage = $"{tableName} does not contain Default_Customer or Default_Customer_ID.";
                        continue;
                    }

                    var currentFlagColumn = hasCurrentLocation ? "Current_Location" : (hasCurrentWarehouse ? "Current_Warehouse" : string.Empty);
                    if (string.IsNullOrWhiteSpace(currentFlagColumn))
                    {
                        lastStatusMessage = $"{tableName} does not contain Current_Warehouse/Current_Location.";
                        continue;
                    }

                    bool hasShop = !string.IsNullOrWhiteSpace(shopCol);
                    string selectedNameSql = hasDefaultCustomer ? "Default_Customer" : "CAST(NULL AS NVARCHAR(255)) AS Default_Customer";
                    string selectedIdSql = hasDefaultCustomerId ? "Default_Customer_ID" : "CAST(NULL AS NVARCHAR(100)) AS Default_Customer_ID";
                    string sql = hasShop
                        ? $@"SELECT TOP 1 {selectedNameSql}, {selectedIdSql} FROM {tableName} WHERE [{currentFlagColumn}] = 1 AND [{shopCol}] = @ShopId ORDER BY [ID]"
                        : $@"SELECT TOP 1 {selectedNameSql}, {selectedIdSql} FROM {tableName} WHERE [{currentFlagColumn}] = 1 ORDER BY [ID]";

                    string defaultCustomerName = string.Empty;
                    string defaultCustomerId = string.Empty;
                    using (var cmd = new SqlCommand(sql, conn))
                    {
                        if (hasShop)
                            cmd.Parameters.AddWithValue("@ShopId", shopId);

                        using var reader = await cmd.ExecuteReaderAsync().ConfigureAwait(false);
                        if (await reader.ReadAsync().ConfigureAwait(false))
                        {
                            defaultCustomerName = reader["Default_Customer"]?.ToString()?.Trim() ?? string.Empty;
                            defaultCustomerId = reader["Default_Customer_ID"]?.ToString()?.Trim() ?? string.Empty;
                        }
                    }

                    if (string.IsNullOrWhiteSpace(defaultCustomerName) && string.IsNullOrWhiteSpace(defaultCustomerId))
                    {
                        return new WarehouseDefaultCustomerLookupResult
                        {
                            WarehouseTableName = tableName,
                            WarehouseDefaultCustomerId = string.Empty,
                            WarehouseDefaultCustomerName = string.Empty,
                            StatusMessage = $"{tableName} current warehouse row has no Default_Customer or Default_Customer_ID value.",
                            Profile = null
                        };
                    }

                    WarehouseDefaultCustomerProfile? profile = null;
                    if (!string.IsNullOrWhiteSpace(defaultCustomerId))
                    {
                        profile = await LoadCustomerProfileByCustomerIdAsync(conn, defaultCustomerId).ConfigureAwait(false);
                    }

                    if (profile == null && !string.IsNullOrWhiteSpace(defaultCustomerName))
                    {
                        profile = await LoadCustomerProfileByNameAsync(conn, defaultCustomerName).ConfigureAwait(false);
                    }

                    if (profile != null)
                    {
                        return new WarehouseDefaultCustomerLookupResult
                        {
                            WarehouseTableName = tableName,
                            WarehouseDefaultCustomerId = defaultCustomerId,
                            WarehouseDefaultCustomerName = defaultCustomerName,
                            StatusMessage = !string.IsNullOrWhiteSpace(defaultCustomerId)
                                ? $"Matched warehouse Default_Customer_ID '{defaultCustomerId}' to dbo.OnlineCustomers."
                                : $"Matched warehouse Default_Customer '{defaultCustomerName}' to dbo.OnlineCustomers.",
                            Profile = profile
                        };
                    }

                    return new WarehouseDefaultCustomerLookupResult
                    {
                        WarehouseTableName = tableName,
                        WarehouseDefaultCustomerId = defaultCustomerId,
                        WarehouseDefaultCustomerName = defaultCustomerName,
                        StatusMessage = !string.IsNullOrWhiteSpace(defaultCustomerId)
                            ? $"Warehouse Default_Customer_ID '{defaultCustomerId}' was found, but no matching row exists in dbo.OnlineCustomers."
                            : $"Warehouse Default_Customer '{defaultCustomerName}' was found, but no matching row exists in dbo.OnlineCustomers.",
                        Profile = new WarehouseDefaultCustomerProfile { CustomerId = defaultCustomerId, Name = defaultCustomerName }
                    };
                }
                catch (Exception ex)
                {
                    lastStatusMessage = $"Lookup against {tableName} failed: {ex.Message}";
                }
            }

            return new WarehouseDefaultCustomerLookupResult
            {
                WarehouseTableName = string.Empty,
                WarehouseDefaultCustomerId = string.Empty,
                WarehouseDefaultCustomerName = string.Empty,
                StatusMessage = lastStatusMessage,
                Profile = null
            };
        }

        private static async Task<WarehouseDefaultCustomerProfile?> LoadCustomerProfileByCustomerIdAsync(SqlConnection conn, string customerId)
        {
            if (string.IsNullOrWhiteSpace(customerId))
                return null;

            const string sql = @"
IF OBJECT_ID('dbo.OnlineCustomers', 'U') IS NULL
BEGIN
    SELECT CAST(NULL AS NVARCHAR(100)) AS CustomerID, CAST(NULL AS NVARCHAR(255)) AS Name, CAST(NULL AS NVARCHAR(100)) AS PrimaryPhoneNumber, CAST(NULL AS NVARCHAR(255)) AS PrimaryEmail, CAST(NULL AS NVARCHAR(1000)) AS PrimaryAddress
    WHERE 1 = 0;
END
ELSE
BEGIN
    SELECT TOP 1
        ISNULL(CustomerID, '') AS CustomerID,
        ISNULL(Name, '') AS Name,
        ISNULL(PrimaryPhoneNumber, '') AS PrimaryPhoneNumber,
        ISNULL(PrimaryEmail, '') AS PrimaryEmail,
        ISNULL(PrimaryAddress, '') AS PrimaryAddress
    FROM dbo.OnlineCustomers
    WHERE LTRIM(RTRIM(ISNULL(CustomerID, ''))) = @CustomerId
    ORDER BY UpdatedAt DESC, LastSyncedUtc DESC;
END";

            using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("@CustomerId", customerId.Trim());
            using var rdr = await cmd.ExecuteReaderAsync().ConfigureAwait(false);
            if (!await rdr.ReadAsync().ConfigureAwait(false))
                return null;

            return new WarehouseDefaultCustomerProfile
            {
                CustomerId = rdr["CustomerID"]?.ToString()?.Trim() ?? customerId.Trim(),
                Name = rdr["Name"]?.ToString()?.Trim() ?? string.Empty,
                PhoneNumber = rdr["PrimaryPhoneNumber"]?.ToString()?.Trim() ?? string.Empty,
                EmailAddress = rdr["PrimaryEmail"]?.ToString()?.Trim() ?? string.Empty,
                Address = rdr["PrimaryAddress"]?.ToString()?.Trim() ?? string.Empty,
            };
        }

        private static async Task<WarehouseDefaultCustomerProfile?> LoadCustomerProfileByNameAsync(SqlConnection conn, string customerName)
        {
            if (string.IsNullOrWhiteSpace(customerName))
                return null;

            const string sql = @"
IF OBJECT_ID('dbo.OnlineCustomers', 'U') IS NULL
BEGIN
    SELECT CAST(NULL AS NVARCHAR(100)) AS CustomerID, CAST(NULL AS NVARCHAR(255)) AS Name, CAST(NULL AS NVARCHAR(100)) AS PrimaryPhoneNumber, CAST(NULL AS NVARCHAR(255)) AS PrimaryEmail, CAST(NULL AS NVARCHAR(1000)) AS PrimaryAddress
    WHERE 1 = 0;
END
ELSE
BEGIN
    SELECT TOP 1
        ISNULL(CustomerID, '') AS CustomerID,
        ISNULL(Name, '') AS Name,
        ISNULL(PrimaryPhoneNumber, '') AS PrimaryPhoneNumber,
        ISNULL(PrimaryEmail, '') AS PrimaryEmail,
        ISNULL(PrimaryAddress, '') AS PrimaryAddress
    FROM dbo.OnlineCustomers
    WHERE LTRIM(RTRIM(ISNULL(Name, ''))) = @CustomerName
    ORDER BY UpdatedAt DESC, LastSyncedUtc DESC;
END";

            using var cmd = new SqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("@CustomerName", customerName.Trim());
            using var rdr = await cmd.ExecuteReaderAsync().ConfigureAwait(false);
            if (!await rdr.ReadAsync().ConfigureAwait(false))
                return null;

            return new WarehouseDefaultCustomerProfile
            {
                CustomerId = rdr["CustomerID"]?.ToString()?.Trim() ?? string.Empty,
                Name = rdr["Name"]?.ToString()?.Trim() ?? customerName.Trim(),
                PhoneNumber = rdr["PrimaryPhoneNumber"]?.ToString()?.Trim() ?? string.Empty,
                EmailAddress = rdr["PrimaryEmail"]?.ToString()?.Trim() ?? string.Empty,
                Address = rdr["PrimaryAddress"]?.ToString()?.Trim() ?? string.Empty,
            };
        }

        private static string BuildAdvanceOrderPaymentSummary(AdvanceOrderCloudContext context)
        {
            var parts = new List<string>();

            if (context.CashAmount > 0m)
                parts.Add($"CASH={context.CashAmount:F2}");

            foreach (var kv in context.BankPayments.OrderBy(k => k.Key, StringComparer.OrdinalIgnoreCase))
            {
                if (kv.Value > 0m)
                    parts.Add($"{kv.Key}={kv.Value:F2}");
            }

            if (parts.Count == 0 && context.Downpayment > 0m)
                parts.Add($"DOWNPAYMENT={context.Downpayment:F2}");

            return string.Join(", ", parts);
        }

        private static List<object> BuildAdvanceOrderItemsPayload(AdvanceOrderCloudContext context, bool includeLineLevelDiscounts, bool addTransferProduct)
        {
            var items = new List<object>(context.ItemsPayload);

            if (addTransferProduct && !HasAdvanceOrderTransferMarker(context))
            {
                items.Add(new
                {
                    discount_each_product = 0,
                    is_bonus_product = false,
                    is_discount_percent = false,
                    is_wholesale = false,
                    one_time_product = false,
                    quantity = 1,
                    variation_id = AdvanceOrderTransferVariationId,
                    note = "TRANSFER",
                    variation_info = new
                    {
                        detail = "TRANSFER",
                        fields = (object?)null,
                        display_id = "CI-010",
                        name = "TRANSFER",
                        product_display_id = "CI-010",
                        retail_price = 0,
                        weight = 100
                    }
                });
            }

            return items;
        }

        private static bool HasAdvanceOrderTransferMarker(AdvanceOrderCloudContext context)
        {
            foreach (var line in context.ItemLines)
            {
                string itemCode = line.ItemCode?.Trim() ?? string.Empty;
                string description = line.Description?.Trim() ?? string.Empty;

                if (string.Equals(itemCode, "CI-010", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(description, "TRANSFER", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }

            return false;
        }

        private static async Task<bool> ShouldAddAdvanceOrderTransferProductAsync(string shopId)
        {
            string[] candidates = { "dbo.Warehouses", "Warehouses" };

            foreach (var tableName in candidates)
            {
                try
                {
                    using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                    await conn.OpenAsync().ConfigureAwait(false);

                    string? schema = null;
                    string bareTableName = tableName;
                    if (tableName.Contains('.'))
                    {
                        var parts = tableName.Split(new[] { '.' }, 2);
                        schema = parts[0];
                        bareTableName = parts[1];
                    }

                    bool hasCurrentLocation = false;
                    bool hasCurrentWarehouse = false;
                    bool hasProductionWarehouse = false;
                    string shopCol = string.Empty;

                    using (var colCmd = new SqlCommand(@"SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND (TABLE_SCHEMA=@s OR @s IS NULL)", conn))
                    {
                        colCmd.Parameters.AddWithValue("@t", bareTableName);
                        colCmd.Parameters.AddWithValue("@s", (object?)schema ?? DBNull.Value);
                        using var rdr = await colCmd.ExecuteReaderAsync().ConfigureAwait(false);
                        while (await rdr.ReadAsync().ConfigureAwait(false))
                        {
                            var c = rdr[0]?.ToString() ?? string.Empty;
                            if (c.Equals("Current_Location", StringComparison.OrdinalIgnoreCase)) hasCurrentLocation = true;
                            if (c.Equals("Current_Warehouse", StringComparison.OrdinalIgnoreCase)) hasCurrentWarehouse = true;
                            if (c.Equals("Is_Production_Warehouse", StringComparison.OrdinalIgnoreCase)) hasProductionWarehouse = true;
                            if (c.Equals("ShopID", StringComparison.OrdinalIgnoreCase)) shopCol = "ShopID";
                            else if (string.IsNullOrEmpty(shopCol) && c.Equals("ShopId", StringComparison.OrdinalIgnoreCase)) shopCol = "ShopId";
                        }
                    }

                    var currentFlagColumn = hasCurrentLocation ? "Current_Location" : (hasCurrentWarehouse ? "Current_Warehouse" : string.Empty);
                    if (string.IsNullOrWhiteSpace(currentFlagColumn) || !hasProductionWarehouse)
                        continue;

                    bool hasShop = !string.IsNullOrWhiteSpace(shopCol);
                    string sql = hasShop
                        ? $@"SELECT TOP 1 ISNULL(CAST([Is_Production_Warehouse] AS INT), 0)
                             FROM {tableName}
                             WHERE [{currentFlagColumn}] = 1 AND [{shopCol}] = @ShopId
                             ORDER BY [ID]"
                        : $@"SELECT TOP 1 ISNULL(CAST([Is_Production_Warehouse] AS INT), 0)
                             FROM {tableName}
                             WHERE [{currentFlagColumn}] = 1
                             ORDER BY [ID]";

                    using var cmd = new SqlCommand(sql, conn);
                    if (hasShop)
                        cmd.Parameters.AddWithValue("@ShopId", shopId);

                    var result = await cmd.ExecuteScalarAsync().ConfigureAwait(false);
                    if (result == null || result == DBNull.Value)
                        continue;

                    return Convert.ToInt32(result) == 0;
                }
                catch
                {
                    // Best-effort. If warehouse detection fails, do not force a transfer line.
                }
            }

            return false;
        }

        private static async Task<string> SyncAdvanceOrderPaymentsAsync(HttpClient http, string baseUrl, string apiKey, string shopId, AdvanceOrderCloudContext context, string onlineOrderId)
        {
            var paymentsPayload = new
            {
                bank_payments = context.BankPayments,
                cash = Math.Round(Math.Abs(context.CashAmount), 0, MidpointRounding.AwayFromZero)
            };

            string paymentsJson = JsonSerializer.Serialize(paymentsPayload, new JsonSerializerOptions
            {
                DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
            });

            string updateUrl = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders/{Uri.EscapeDataString(onlineOrderId)}?api_key={Uri.EscapeDataString(apiKey)}";

            async Task<HttpResponseMessage> SendPaymentUpdateAsync(HttpMethod method)
            {
                var req = new HttpRequestMessage(method, updateUrl)
                {
                    Content = new StringContent(paymentsJson, Encoding.UTF8, "application/json")
                };
                return await http.SendAsync(req).ConfigureAwait(false);
            }

            using var putResp = await SendPaymentUpdateAsync(HttpMethod.Put).ConfigureAwait(false);
            var putText = await putResp.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (putResp.IsSuccessStatusCode)
                return putText;

            using var patchResp = await SendPaymentUpdateAsync(new HttpMethod("PATCH")).ConfigureAwait(false);
            var patchText = await patchResp.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (patchResp.IsSuccessStatusCode)
                return patchText;

            throw new HttpRequestException($"SyncAdvanceOrderPayments failed: PUT {(int)putResp.StatusCode} {putResp.ReasonPhrase}. Response: {putText}. PATCH {(int)patchResp.StatusCode} {patchResp.ReasonPhrase}. Response: {patchText}");
        }

        public static string SyncAdvanceOrderToCloud(string receiptNo)
        {
            return SyncAdvanceOrderToCloudAsync(receiptNo).GetAwaiter().GetResult();
        }

        // Short delays between automatic retry attempts for transient Pancake sync failures (network
        // blip, momentary 5xx, request timeout). 2 retries (3 attempts total) with a growing delay -
        // enough to ride out a brief outage without the caller (silent auto-sync triggers, or a
        // staff member clicking "Resend to Pancake") waiting too long for a doomed call to give up.
        private static readonly TimeSpan[] AdvanceOrderSyncRetryDelays = { TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5) };

        // Only retry failures that are plausibly transient. Everything else (missing receipt,
        // missing AdvanceOrderHeader row, bad API key/shop config, a 4xx the API will reject again
        // identically) would just fail the same way 3 times in a row, so there's no point delaying
        // the error - fail fast and let it be recorded/surfaced immediately.
        private static bool IsTransientAdvanceOrderSyncFailure(Exception ex)
        {
            return ex is HttpRequestException
                || ex is TaskCanceledException
                || ex is TimeoutException
                || ex is System.Net.Sockets.SocketException;
        }

        // Persists a SYNC_FAILED status to dbo.InstoreOnlineOrderMap once retries are exhausted (or
        // immediately for a non-transient failure) - the core logic below has 3 throw points plus
        // whatever LoadAdvanceOrderCloudContext/GetCurrentWarehouseIdAsync/JSON building/network
        // calls can throw, and previously none of them left any trace in InstoreOnlineOrderMap (only
        // successes were ever recorded there). Mirrors the existing CREATE_FAILED pattern already
        // used for regular in-store orders in CreateInstoreOnlineOrder's catch block. Passing an
        // empty onlineOrderId is safe - UpsertInstoreOnlineOrderMap's MERGE preserves the existing
        // OnlineOrderId when passed blank, so a failed resend after a prior success can't wipe out
        // the real Pancake order id (and the next resend still correctly takes the idempotent UPDATE
        // path instead of creating a duplicate order).
        public static async Task<string> SyncAdvanceOrderToCloudAsync(string receiptNo, TimeSpan? timeout = null)
        {
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    return await SyncAdvanceOrderToCloudCoreAsync(receiptNo, timeout).ConfigureAwait(false);
                }
                catch (Exception ex) when (attempt < AdvanceOrderSyncRetryDelays.Length && IsTransientAdvanceOrderSyncFailure(ex))
                {
                    await Task.Delay(AdvanceOrderSyncRetryDelays[attempt]).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    try
                    {
                        UpsertInstoreOnlineOrderMap(receiptNo?.Trim() ?? string.Empty, string.Empty, "ADVANCEORDER", "SYNC_FAILED", ex.ToString());
                    }
                    catch { /* best-effort status write, never mask the original failure */ }
                    throw;
                }
            }
        }

        private static async Task<string> SyncAdvanceOrderToCloudCoreAsync(string receiptNo, TimeSpan? timeout)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                throw new ArgumentException("receiptNo is required", nameof(receiptNo));

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            timeout ??= TimeSpan.FromSeconds(30);

            static void DumpAdvanceOrderPayload(string receipt, string stage, string bodyJson)
            {
                try
                {
                    string payloadDumpPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, $"last_advance_order_payload_{receipt}_{stage}.json");
                    File.WriteAllText(payloadDumpPath, bodyJson ?? string.Empty, Encoding.UTF8);
                    System.Diagnostics.Debug.WriteLine($"SyncAdvanceOrderToCloud {stage} body saved to: {payloadDumpPath}");
                    System.Diagnostics.Debug.WriteLine(bodyJson ?? string.Empty);
                    System.Diagnostics.Trace.TraceInformation($"SyncAdvanceOrderToCloud {stage} body saved to: {payloadDumpPath}\n{bodyJson}");
                }
                catch { }
            }

            var context = LoadAdvanceOrderCloudContext(receiptNo.Trim());
            string warehouseId = await GetCurrentWarehouseIdAsync(shopId).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(warehouseId))
                warehouseId = "{{WarehouseIDAmaya}}";

            bool addTransferProduct = await ShouldAddAdvanceOrderTransferProductAsync(shopId).ConfigureAwait(false);
            var customerLookup = await GetCurrentWarehouseDefaultCustomerProfileAsync(shopId).ConfigureAwait(false);
            string createBodyJson = BuildAdvanceOrderCloudPayload(shopId, warehouseId, context, customerLookup.Profile, includeLineLevelDiscounts: false, addTransferProduct: addTransferProduct);
            string updateBodyJson = BuildAdvanceOrderCloudPayload(shopId, warehouseId, context, customerLookup.Profile, includeLineLevelDiscounts: true, addTransferProduct: addTransferProduct);
            DumpAdvanceOrderPayload(receiptNo.Trim(), "create", createBodyJson);
            DumpAdvanceOrderPayload(receiptNo.Trim(), "update", updateBodyJson);
            string mappedOrderId = GetMappedOnlineOrderId(context.ReceiptNo);

            using var http = new HttpClient { Timeout = timeout.Value };

            async Task<string> SendAdvanceOrderUpdateAsync(string onlineOrderId)
            {
                string updateUrl = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders/{Uri.EscapeDataString(onlineOrderId)}?api_key={Uri.EscapeDataString(apiKey)}";

                async Task<HttpResponseMessage> SendUpdateAsync(HttpMethod method)
                {
                    var req = new HttpRequestMessage(method, updateUrl)
                    {
                        Content = new StringContent(updateBodyJson, Encoding.UTF8, "application/json")
                    };
                    return await http.SendAsync(req).ConfigureAwait(false);
                }

                using var putResp = await SendUpdateAsync(HttpMethod.Put).ConfigureAwait(false);
                if (putResp.IsSuccessStatusCode)
                {
                    var updateText = await putResp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    await SyncAdvanceOrderPaymentsAsync(http, baseUrl, apiKey, shopId, context, onlineOrderId).ConfigureAwait(false);
                    UpsertInstoreOnlineOrderMap(context.ReceiptNo, onlineOrderId, "ADVANCEORDER", "UPDATE", updateText);
                    UpdateAdvanceOrderHeaderOnlineOrderId(context.ReceiptNo, onlineOrderId);
                    MarkReceiptSentToOnline(context.ReceiptNo);
                    return updateText;
                }

                if ((int)putResp.StatusCode == 404 || (int)putResp.StatusCode == 405)
                {
                    using var patchResp = await SendUpdateAsync(new HttpMethod("PATCH")).ConfigureAwait(false);
                    var patchText = await patchResp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    if (!patchResp.IsSuccessStatusCode)
                        throw new HttpRequestException($"SyncAdvanceOrderToCloud update failed: {(int)patchResp.StatusCode} {patchResp.ReasonPhrase}. Response: {patchText}");

                    await SyncAdvanceOrderPaymentsAsync(http, baseUrl, apiKey, shopId, context, onlineOrderId).ConfigureAwait(false);
                    UpsertInstoreOnlineOrderMap(context.ReceiptNo, onlineOrderId, "ADVANCEORDER", "UPDATE", patchText);
                    UpdateAdvanceOrderHeaderOnlineOrderId(context.ReceiptNo, onlineOrderId);
                    MarkReceiptSentToOnline(context.ReceiptNo);
                    return patchText;
                }

                var putText = await putResp.Content.ReadAsStringAsync().ConfigureAwait(false);
                throw new HttpRequestException($"SyncAdvanceOrderToCloud update failed: {(int)putResp.StatusCode} {putResp.ReasonPhrase}. Response: {putText}");
            }

            if (string.IsNullOrWhiteSpace(mappedOrderId))
            {
                string createUrl = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders?api_key={Uri.EscapeDataString(apiKey)}";
                using var createReq = new HttpRequestMessage(HttpMethod.Post, createUrl)
                {
                    Content = new StringContent(createBodyJson, Encoding.UTF8, "application/json")
                };

                using var createResp = await http.SendAsync(createReq).ConfigureAwait(false);
                var createRespText = await createResp.Content.ReadAsStringAsync().ConfigureAwait(false);
                if (!createResp.IsSuccessStatusCode)
                    throw new HttpRequestException($"SyncAdvanceOrderToCloud create failed: {(int)createResp.StatusCode} {createResp.ReasonPhrase}. Response: {createRespText}");

                string createdOrderId = ExtractOnlineOrderId(createRespText);
                UpsertInstoreOnlineOrderMap(context.ReceiptNo, createdOrderId, "ADVANCEORDERS", "CREATE", createRespText);
                UpdateAdvanceOrderHeaderOnlineOrderId(context.ReceiptNo, createdOrderId);
                MarkReceiptSentToOnline(context.ReceiptNo);
                if (string.IsNullOrWhiteSpace(createdOrderId))
                    return createRespText;

                return await SendAdvanceOrderUpdateAsync(createdOrderId).ConfigureAwait(false);
            }

            return await SendAdvanceOrderUpdateAsync(mappedOrderId).ConfigureAwait(false);
        }

        /// <summary>
        /// Create an online (cloud) order based on an in-store receipt.
        /// This is intended for “walk-in” orders so the cloud platform can reflect in-store sales.
        ///
        /// Parameter:
        /// - ReceiptNo: local POS receipt number (TransactionHeader.ReceiptNo / ItemLedgerEntry.ReceiptNo)
        ///
        /// Returns the created upstream OrderID.
        /// </summary>
        public static string CreateInstoreOnlineOrder(string ReceiptNo)
        {
            if (string.IsNullOrWhiteSpace(ReceiptNo))
                throw new ArgumentException("ReceiptNo is required", nameof(ReceiptNo));

            try
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

                // Endpoint requested by user. Do not create request body here (per instructions).
                string url = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/orders?api_key={Uri.EscapeDataString(apiKey)}";

                // Verify the receipt exists and read TransactionHeader.Description, Discount, NetAmount and Type for the given ReceiptNo
                string noteText = string.Empty;
                string discountDescription = string.Empty;
                decimal transactionDiscount = 0m;
                decimal transactionNetAmount = 0m;
                string transactionReceiptNo = string.Empty;
                string transactionUserId = string.Empty;
                string transactionType = string.Empty;
                try
                {
                    using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        conn.Open();
                        using (var cmd = new SqlCommand("SELECT TOP 1 TransactionNo, ReceiptNo, Description, DiscountDescription, Discount, NetAmount, UserID, Type FROM TransactionHeader WHERE ReceiptNo = @ReceiptNo", conn))
                        {
                            cmd.Parameters.AddWithValue("@ReceiptNo", ReceiptNo);
                            using (var rdr = cmd.ExecuteReader())
                            {
                                if (!rdr.Read())
                                    throw new InvalidOperationException($"Receipt '{ReceiptNo}' not found in TransactionHeader.");

                                try { noteText = rdr["Description"]?.ToString() ?? string.Empty; } catch { noteText = string.Empty; }
                                try { discountDescription = rdr["DiscountDescription"]?.ToString() ?? string.Empty; } catch { discountDescription = string.Empty; }
                                try { transactionReceiptNo = rdr["ReceiptNo"]?.ToString() ?? string.Empty; } catch { transactionReceiptNo = string.Empty; }
                                try { transactionUserId = rdr["UserID"]?.ToString() ?? string.Empty; } catch { transactionUserId = string.Empty; }
                                try { transactionType = rdr["Type"]?.ToString() ?? string.Empty; } catch { transactionType = string.Empty; }
                                try
                                {
                                    var dv = rdr["Discount"];
                                    if (dv != null && dv != DBNull.Value)
                                    {
                                        decimal.TryParse(dv.ToString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out transactionDiscount);
                                    }
                                }
                                catch { transactionDiscount = 0m; }
                                try
                                {
                                    var nv = rdr["NetAmount"];
                                    if (nv != null && nv != DBNull.Value)
                                    {
                                        decimal.TryParse(nv.ToString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out transactionNetAmount);
                                    }
                                }
                                catch { transactionNetAmount = 0m; }
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    throw new InvalidOperationException("Failed to verify receipt in TransactionHeader: " + ex.Message, ex);
                }

                // Only create an online order for SALES transactions. Skip otherwise.
                if (!string.Equals(transactionType, "SALES", StringComparison.OrdinalIgnoreCase))
                {
                    System.Diagnostics.Debug.WriteLine($"CreateInstoreOnlineOrder: Skipping Receipt '{ReceiptNo}' because TransactionHeader.Type='{transactionType}'.");
                    UpsertInstoreOnlineOrderMap(ReceiptNo, string.Empty, "INSTORE", "SKIP", $"Skipped because TransactionHeader.Type='{transactionType}'.");
                    return string.Empty;
                }

                // Combine DocumentNo and UserID into note text and safely serialize for embedding into our raw JSON string
                string combinedNoteBase = string.IsNullOrWhiteSpace(transactionReceiptNo)
                    ? (noteText ?? string.Empty)
                    : (transactionReceiptNo + " - " + (noteText ?? string.Empty));

                string combinedNote = string.IsNullOrWhiteSpace(transactionUserId)
                    ? combinedNoteBase
                    : (combinedNoteBase + " | Cashier: " + transactionUserId);

                bool isWholesaleTransaction = string.Equals(discountDescription?.Trim(), "Wholesale Discount", StringComparison.OrdinalIgnoreCase);
                if (isWholesaleTransaction)
                {
                    combinedNote = string.IsNullOrWhiteSpace(combinedNote)
                        ? "Discount Type: Wholesale Discount"
                        : combinedNote + " | Discount Type: Wholesale Discount";
                }

                if (Math.Abs(transactionDiscount) > 0m)
                    combinedNote = string.IsNullOrWhiteSpace(combinedNote)
                        ? $"POS Discount: {Math.Abs(transactionDiscount):0.##}"
                        : combinedNote + $" | POS Discount: {Math.Abs(transactionDiscount):0.##}";

                using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) })
                {
                // Resolve warehouse id if possible, otherwise keep placeholder
                string warehouseId = "{{WarehouseIDAmaya}}";
                try { warehouseId = GetCurrentWarehouseIdAsync(shopId).GetAwaiter().GetResult(); } catch { }

                // Query ItemLedgerEntry where DocumentNo = ReceiptNo (parameter)
                // Pull fields we need to build the order lines.
                var itemLines = new System.Collections.Generic.List<(string VariationId, string ItemCode, string Description, string CategoryCode, string CategoryName, decimal Quantity, decimal Discount, decimal NetAmount, decimal GrossAmount, decimal Price)>();
                try
                {
                    using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        conn.Open();
                        using (var cmd = new SqlCommand(@"SELECT ile.VariationId, ile.ItemCode, ile.Description, ISNULL(i.CategoryCode, '') AS CategoryCode, ISNULL(c.Description, '') AS CategoryName, ile.Quantity, ile.Discount, ile.NetAmount, ile.GrossAmount, ile.Price
FROM ItemLedgerEntry ile
LEFT JOIN Items i ON i.Code = ile.ItemCode
LEFT JOIN Category c ON c.Code = i.CategoryCode
WHERE ile.DocumentNo = @DocNo", conn))
                        {
                            cmd.Parameters.AddWithValue("@DocNo", ReceiptNo);
                            using (var rdr = cmd.ExecuteReader())
                            {
                                while (rdr.Read())
                                {
                                    string variationId = string.Empty;
                                    string itemCode = string.Empty;
                                    string description = string.Empty;
                                    string categoryCode = string.Empty;
                                    string categoryName = string.Empty;
                                    try { variationId = rdr["VariationId"]?.ToString() ?? string.Empty; } catch { variationId = string.Empty; }
                                    try { itemCode = rdr["ItemCode"]?.ToString() ?? string.Empty; } catch { itemCode = string.Empty; }
                                    try { description = rdr["Description"]?.ToString() ?? string.Empty; } catch { description = string.Empty; }
                                    try { categoryCode = rdr["CategoryCode"]?.ToString() ?? string.Empty; } catch { categoryCode = string.Empty; }
                                    try { categoryName = rdr["CategoryName"]?.ToString() ?? string.Empty; } catch { categoryName = string.Empty; }

                                    decimal qty = 1m;
                                    try
                                    {
                                        var qv = rdr["Quantity"];
                                        if (qv != null && qv != DBNull.Value)
                                            decimal.TryParse(qv.ToString(), out qty);
                                    }
                                    catch { qty = 1m; }

                                    decimal discount = 0m;
                                    try
                                    {
                                        var dv = rdr["Discount"];
                                        if (dv != null && dv != DBNull.Value)
                                            decimal.TryParse(dv.ToString(), out discount);
                                    }
                                    catch { discount = 0m; }

                                    decimal netAmount = 0m;
                                    try
                                    {
                                        var nv = rdr["NetAmount"];
                                        if (nv != null && nv != DBNull.Value)
                                            decimal.TryParse(nv.ToString(), out netAmount);
                                    }
                                    catch { netAmount = 0m; }

                                    decimal grossAmount = 0m;
                                    try
                                    {
                                        var gv = rdr["GrossAmount"];
                                        if (gv != null && gv != DBNull.Value)
                                            decimal.TryParse(gv.ToString(), out grossAmount);
                                    }
                                    catch { grossAmount = 0m; }

                                    decimal price = 0m;
                                    try
                                    {
                                        var pv = rdr["Price"];
                                        if (pv != null && pv != DBNull.Value)
                                            decimal.TryParse(pv.ToString(), out price);
                                    }
                                    catch { price = 0m; }

                                    itemLines.Add((variationId, itemCode, description, categoryCode, categoryName, qty, discount, netAmount, grossAmount, price));
                                }
                            }
                        }
                    }
                }
                catch
                {
                    // Ignore failures here; itemLines will be empty
                }

                // Build items array from itemLines.
                var itemsPayload = new System.Collections.Generic.List<object>();
                var customItemNotesToSend = new System.Collections.Generic.List<string>();
                decimal effectiveTransactionDiscount = Math.Abs(transactionDiscount);
                decimal totalGrossForDiscountAllocation = 0m;
                bool hasPersistedLineDiscounts = false;

                if (itemLines != null && itemLines.Count > 0)
                {
                    foreach (var line in itemLines)
                    {
                        decimal quantityAbs = Math.Abs(line.Quantity);
                        if (quantityAbs == 0m)
                            quantityAbs = 1m;

                        decimal grossValue = Math.Abs(line.GrossAmount);
                        decimal netValue = Math.Abs(line.NetAmount);
                        decimal baseValue = grossValue != 0m
                            ? grossValue
                            : (line.Price != 0m ? Math.Abs(line.Price) * quantityAbs : netValue);

                        totalGrossForDiscountAllocation += baseValue;
                        if (Math.Abs(line.Discount) > 0m)
                            hasPersistedLineDiscounts = true;
                    }
                }

                bool useLineLevelDiscounts = itemLines != null
                    && itemLines.Count > 0
                    && (hasPersistedLineDiscounts || effectiveTransactionDiscount > 0m);
                bool allocateFallbackLineDiscounts = useLineLevelDiscounts && !hasPersistedLineDiscounts && effectiveTransactionDiscount > 0m && totalGrossForDiscountAllocation > 0m;
                decimal remainingFallbackDiscount = effectiveTransactionDiscount;

                var customCatalogReferenceCache = new Dictionary<string, (string ItemCode, string ItemName, string VariationId)>(StringComparer.OrdinalIgnoreCase);

                if (itemLines != null && itemLines.Count > 0)
                {
                    for (int i = 0; i < itemLines.Count; i++)
                    {
                        var it = itemLines[i];
                        var qtyValueDecimal = Math.Abs(it.Quantity);
                        if (qtyValueDecimal == 0m) qtyValueDecimal = 1m;

                        int qtyValue;
                        try
                        {
                            qtyValue = Math.Max(1, decimal.ToInt32(decimal.Round(qtyValueDecimal, 0, MidpointRounding.AwayFromZero)));
                        }
                        catch
                        {
                            qtyValue = 1;
                        }

                        var unitRetailPriceValue = 0m;
                        decimal lineBaseValue = 0m;
                        try
                        {
                            // Prefer GrossAmount for price (pre-discount), fallback to NetAmount.
                            var grossValue = Math.Abs(it.GrossAmount);
                            var netValue = Math.Abs(it.NetAmount);
                            var baseValue = grossValue != 0m ? grossValue : netValue;
                            lineBaseValue = baseValue;

                            // Prefer explicit Price column when present; otherwise derive from baseValue/qty.
                            var computed = it.Price != 0m ? Math.Abs(it.Price) : (qtyValueDecimal != 0m ? (baseValue / qtyValueDecimal) : baseValue);

                            // Round to nearest whole number (away from zero) and format without decimals.
                            unitRetailPriceValue = Math.Round(computed, 0, MidpointRounding.AwayFromZero);
                        }
                        catch { unitRetailPriceValue = 0m; }

                        decimal lineDiscountTotal = Math.Abs(it.Discount);
                        if (lineDiscountTotal <= 0m && allocateFallbackLineDiscounts)
                        {
                            if (i == itemLines.Count - 1)
                            {
                                lineDiscountTotal = remainingFallbackDiscount;
                            }
                            else
                            {
                                decimal proportionalDiscount = totalGrossForDiscountAllocation > 0m
                                    ? effectiveTransactionDiscount * (lineBaseValue / totalGrossForDiscountAllocation)
                                    : 0m;
                                lineDiscountTotal = Math.Round(proportionalDiscount, 2, MidpointRounding.AwayFromZero);
                                if (lineDiscountTotal > remainingFallbackDiscount)
                                    lineDiscountTotal = remainingFallbackDiscount;
                                remainingFallbackDiscount -= lineDiscountTotal;
                            }
                        }

                        decimal discountEachProductValue = 0m;
                        if (lineDiscountTotal > 0m)
                        {
                            decimal quantityForDiscount = qtyValueDecimal == 0m ? 1m : qtyValueDecimal;
                            discountEachProductValue = Math.Round(lineDiscountTotal / quantityForDiscount, 2, MidpointRounding.AwayFromZero);
                        }

                        string lineItemCode = (it.ItemCode ?? string.Empty).Trim();
                        string lineDescription = (it.Description ?? string.Empty).Trim();
                        string lineCategoryCode = (it.CategoryCode ?? string.Empty).Trim();
                        string lineCategoryName = (it.CategoryName ?? string.Empty).Trim();
                        string variationId = (it.VariationId ?? string.Empty).Trim();
                        string mappedCloudItemCode = ResolveInstoreCloudMappedItemCode(lineCategoryCode, lineCategoryName, lineDescription, lineItemCode);
                        string customCatalogCacheKey = string.Join("|", mappedCloudItemCode, lineCategoryCode, lineCategoryName);
                        var resolvedCustomCatalogReference = (ItemCode: string.Empty, ItemName: string.Empty, VariationId: string.Empty);
                        if (!string.IsNullOrWhiteSpace(mappedCloudItemCode))
                        {
                            if (!customCatalogReferenceCache.TryGetValue(customCatalogCacheKey, out resolvedCustomCatalogReference))
                            {
                                resolvedCustomCatalogReference = ResolveCustomCatalogReference(mappedCloudItemCode, lineCategoryCode, lineCategoryName);
                                customCatalogReferenceCache[customCatalogCacheKey] = resolvedCustomCatalogReference;
                            }
                        }

                        string effectiveVariationId = !string.IsNullOrWhiteSpace(resolvedCustomCatalogReference.VariationId)
                            ? resolvedCustomCatalogReference.VariationId
                            : variationId;
                        string effectiveProductDisplayId = !string.IsNullOrWhiteSpace(resolvedCustomCatalogReference.ItemCode)
                            ? resolvedCustomCatalogReference.ItemCode
                            : (string.IsNullOrWhiteSpace(mappedCloudItemCode)
                                ? (string.IsNullOrWhiteSpace(lineItemCode) ? string.Empty : lineItemCode)
                                : mappedCloudItemCode);
                        string lineName = !string.IsNullOrWhiteSpace(lineDescription)
                            ? lineDescription
                            : (!string.IsNullOrWhiteSpace(lineItemCode) ? lineItemCode : "Custom Item");
                        string effectiveCatalogName = !string.IsNullOrWhiteSpace(resolvedCustomCatalogReference.ItemName)
                            ? resolvedCustomCatalogReference.ItemName
                            : lineName;
                        bool isCustomCatalogLine = !string.IsNullOrWhiteSpace(mappedCloudItemCode);
                        bool hasMeaningfulLineDescription = !string.IsNullOrWhiteSpace(lineDescription)
                            && !lineDescription.StartsWith("Online Order ", StringComparison.OrdinalIgnoreCase)
                            && !string.Equals(lineDescription, mappedCloudItemCode, StringComparison.OrdinalIgnoreCase)
                            && !string.Equals(lineDescription, lineItemCode, StringComparison.OrdinalIgnoreCase);
                        string? lineNote = null;
                        if (isCustomCatalogLine)
                        {
                            lineNote = hasMeaningfulLineDescription
                                ? lineDescription
                                : (string.IsNullOrWhiteSpace(noteText) ? null : noteText.Trim());
                        }
                        if (!string.IsNullOrWhiteSpace(lineNote))
                        {
                            string noteIdentity = string.IsNullOrWhiteSpace(effectiveVariationId) ? effectiveProductDisplayId : effectiveVariationId;
                            customItemNotesToSend.Add($"{(string.IsNullOrWhiteSpace(mappedCloudItemCode) ? lineItemCode : mappedCloudItemCode)} [{noteIdentity}]: {lineNote}");
                        }

                        bool isCustomLine = isCustomCatalogLine
                            || string.IsNullOrWhiteSpace(variationId)
                            || string.Equals(lineItemCode, "CUSTOM", StringComparison.OrdinalIgnoreCase)
                            || lineDescription.IndexOf("Custom Aquarium", StringComparison.OrdinalIgnoreCase) >= 0;

                        if (isCustomLine)
                        {
                            string distinctDisplayIdBase = !string.IsNullOrWhiteSpace(effectiveProductDisplayId)
                                ? effectiveProductDisplayId
                                : (!string.IsNullOrWhiteSpace(mappedCloudItemCode) ? mappedCloudItemCode : "POS-CUSTOM");
                            string distinctDisplayId = $"{distinctDisplayIdBase}-LINE-{i + 1}";
                            string? effectiveLineNote = !string.IsNullOrWhiteSpace(lineNote)
                                ? lineNote
                                : (string.IsNullOrWhiteSpace(lineDescription) ? null : lineDescription);

                            itemsPayload.Add(new
                            {
                                discount_each_product = discountEachProductValue,
                                is_bonus_product = false,
                                is_discount_percent = false,
                                is_wholesale = isWholesaleTransaction,
                                one_time_product = true,
                                quantity = qtyValue,
                                variation_id = (string?)null,
                                note = effectiveLineNote,
                                variation_info = new
                                {
                                    detail = lineDescription,
                                    fields = (object?)null,
                                    display_id = distinctDisplayId,
                                    name = lineName,
                                    product_display_id = distinctDisplayId,
                                    retail_price = unitRetailPriceValue
                                }
                            });
                        }
                        else
                        {
                            itemsPayload.Add(new
                            {
                                discount_each_product = discountEachProductValue,
                                is_bonus_product = false,
                                is_discount_percent = false,
                                is_wholesale = isWholesaleTransaction,
                                one_time_product = false,
                                quantity = qtyValue,
                                variation_id = variationId,
                                note = lineNote,
                                variation_info = new
                                {
                                    detail = (object?)null,
                                    fields = (object?)null,
                                    display_id = string.IsNullOrWhiteSpace(lineItemCode) ? null : lineItemCode,
                                    name = lineName,
                                    product_display_id = string.IsNullOrWhiteSpace(lineItemCode) ? null : lineItemCode,
                                    retail_price = unitRetailPriceValue
                                }
                            });
                        }
                    }
                }
                else
                {
                    itemsPayload.Add(new
                    {
                        discount_each_product = 0,
                        is_bonus_product = false,
                        is_discount_percent = false,
                        is_wholesale = isWholesaleTransaction,
                        one_time_product = true,
                        quantity = 1,
                        variation_info = new
                        {
                            detail = "POS fallback item",
                            fields = (object?)null,
                            display_id = "POS-FALLBACK",
                            name = "POS fallback item",
                            product_display_id = "POS-FALLBACK",
                            retail_price = 1m
                        }
                    });
                }

                // Load payment entries for this receipt and map to TenderTypes to get POSBankID
                var paymentLines = new System.Collections.Generic.List<(string TenderTypeCode, string POSBankID, decimal Amount)>();
                try
                {
                    using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        conn.Open();
                        var paySql = @"SELECT tp.TenderTypeCode, tp.Amount, tt.POSBankID
                                        FROM TransPaymentEntry tp
                                        LEFT JOIN TenderTypes tt ON tt.Code = tp.TenderTypeCode
                                        WHERE tp.ReceiptNo = @ReceiptNo";
                        using (var cmd = new SqlCommand(paySql, conn))
                        {
                            cmd.Parameters.AddWithValue("@ReceiptNo", ReceiptNo);
                            using (var rdr = cmd.ExecuteReader())
                            {
                                while (rdr.Read())
                                {
                                    string tenderCode = string.Empty;
                                    string posBankId = string.Empty;
                                    decimal amount = 0m;
                                    try { tenderCode = rdr["TenderTypeCode"]?.ToString() ?? string.Empty; } catch { tenderCode = string.Empty; }
                                    try { posBankId = rdr["POSBankID"]?.ToString() ?? string.Empty; } catch { posBankId = string.Empty; }
                                    try
                                    {
                                        var av = rdr["Amount"];
                                        if (av != null && av != DBNull.Value)
                                            decimal.TryParse(av.ToString(), out amount);
                                    }
                                    catch { amount = 0m; }

                                    if (!string.IsNullOrWhiteSpace(tenderCode) || amount != 0m || !string.IsNullOrWhiteSpace(posBankId))
                                        paymentLines.Add((tenderCode, posBankId, amount));
                                }
                            }
                        }
                    }
                }
                catch
                {
                    // best-effort; missing TransPaymentEntry or TenderTypes should not block order creation
                }

                // Determine cash amount **only** from payments where TenderTypeCode = 'CASH' (case-insensitive).
                // If there are no CASH payment lines, cashAmount will be 0.
                decimal cashAmount = 0m;
                if (paymentLines.Count > 0)
                {
                    foreach (var p in paymentLines)
                    {
                        if (string.Equals(p.TenderTypeCode, "CASH", StringComparison.OrdinalIgnoreCase))
                        {
                            cashAmount += p.Amount;
                        }
                    }
                }

                // Prepare JSON for bank_payments: { "<POSBankID>": amount, ... }
                string bankPaymentsJson;
                if (paymentLines.Count > 0)
                {
                    var bankPayments = new System.Collections.Generic.Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
                    foreach (var p in paymentLines)
                    {
                        // Exclude pure cash tenders from bank_payments; they are represented via the cash field.
                        if (string.Equals(p.TenderTypeCode, "CASH", StringComparison.OrdinalIgnoreCase))
                            continue;

                        if (string.IsNullOrWhiteSpace(p.POSBankID))
                            continue;

                        var key = p.POSBankID.Trim();
                        if (string.IsNullOrEmpty(key))
                            continue;

                        if (!bankPayments.TryGetValue(key, out var existing))
                            existing = 0m;

                        bankPayments[key] = existing + p.Amount;
                    }

                    bankPaymentsJson = bankPayments.Count > 0
                        ? JsonSerializer.Serialize(bankPayments)
                        : "{}";
                }
                else
                {
                    bankPaymentsJson = "{}";
                }

                if (customItemNotesToSend.Count > 0)
                {
                    string notesDebugText = string.Join("\n", customItemNotesToSend.Distinct(StringComparer.OrdinalIgnoreCase));
                    try { System.Diagnostics.Debug.WriteLine("CreateInstoreOnlineOrder custom item notes:\n" + notesDebugText); } catch { }
                    try { System.Diagnostics.Trace.TraceInformation("CreateInstoreOnlineOrder custom item notes:\n" + notesDebugText); } catch { }
                }

                var bodyPayload = new
                {
                    bill_full_name = "POS WALKIN ORDERS",
                    bill_phone_number = "11111",
                    received_at_shop = true,
                    assigning_seller_id = string.Empty,
                    items = itemsPayload,
                    note = combinedNote,
                    note_print = (object?)null,
                    returned_reason = 1,
                    warehouse_id = warehouseId,
                    shipping_address = new
                    {
                        address = "Walkin",
                        full_address = string.Empty,
                        phone_number = string.Empty
                    },
                    shipping_fee = 0,
                    shop_id = shopId,
                    total_discount = useLineLevelDiscounts ? 0m : Math.Round(Math.Abs(transactionDiscount), 2, MidpointRounding.AwayFromZero),
                    status = 2,
                    bank_payments = string.IsNullOrWhiteSpace(bankPaymentsJson)
                        ? new System.Collections.Generic.Dictionary<string, decimal>()
                        : JsonSerializer.Deserialize<System.Collections.Generic.Dictionary<string, decimal>>(bankPaymentsJson) ?? new System.Collections.Generic.Dictionary<string, decimal>(),
                    cash = Math.Round(Math.Abs(cashAmount), 0, MidpointRounding.AwayFromZero)
                };
                var bodyJson = JsonSerializer.Serialize(bodyPayload, new JsonSerializerOptions
                {
                    DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
                });
                try
                {
                    string payloadDumpPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, $"last_instore_order_payload_{ReceiptNo}.json");
                    File.WriteAllText(payloadDumpPath, bodyJson, Encoding.UTF8);
                    System.Diagnostics.Debug.WriteLine($"CreateInstoreOnlineOrder request body saved to: {payloadDumpPath}");
                    System.Diagnostics.Debug.WriteLine(bodyJson);
                    System.Diagnostics.Trace.TraceInformation($"CreateInstoreOnlineOrder request body saved to: {payloadDumpPath}\n{bodyJson}");
                }
                catch { }
                var req = new HttpRequestMessage(HttpMethod.Post, url)
                {
                    Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
                };

                using var resp = http.SendAsync(req).GetAwaiter().GetResult();
                var respText = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();

                    if (!resp.IsSuccessStatusCode)
                    {
                        throw new HttpRequestException($"CreateInstoreOnlineOrder failed: {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respText}");
                    }

                    string createdOrderId = ExtractOnlineOrderId(respText ?? string.Empty);
                    try
                    {
                        UpsertInstoreOnlineOrderMap(ReceiptNo, createdOrderId, "INSTORE", "CREATE", respText ?? string.Empty);
                    }
                    catch { }

                // Mark the local TransactionHeader and ItemLedgerEntry as sent to online (best-effort).
                try
                {
                    using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        conn.Open();
                        using (var cmd = new SqlCommand("UPDATE TransactionHeader SET SentToOnline = 1 WHERE ReceiptNo = @ReceiptNo", conn))
                        {
                            cmd.Parameters.AddWithValue("@ReceiptNo", ReceiptNo);
                            cmd.ExecuteNonQuery();
                        }

                        // Also mark matching ItemLedgerEntry rows (by ReceiptNo) as sent online
                        try
                        {
                            using (var cmd2 = new SqlCommand("UPDATE ItemLedgerEntry SET SentToOnline = 1 WHERE ReceiptNo = @ReceiptNo", conn))
                            {
                                cmd2.Parameters.AddWithValue("@ReceiptNo", ReceiptNo);
                                cmd2.ExecuteNonQuery();
                            }
                        }
                        catch (Exception ex2)
                        {
                            System.Diagnostics.Debug.WriteLine($"Failed to mark ItemLedgerEntry.SentToOnline for Receipt '{ReceiptNo}': {ex2.Message}");
                        }
                    }
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"Failed to mark SentToOnline for Receipt '{ReceiptNo}': {ex.Message}");
                }

                    return respText ?? string.Empty;
                }
            }
            catch (Exception ex)
            {
                try
                {
                    UpsertInstoreOnlineOrderMap(ReceiptNo, string.Empty, "INSTORE", "CREATE_FAILED", ex.ToString());
                }
                catch { }

                throw;
            }
        }

        private static string ResolveInstoreCloudMappedItemCode(string? categoryCode, string? categoryName, string? description, string? itemCode)
        {
            string normalizedCategory = (categoryCode ?? string.Empty).Trim().ToUpperInvariant();
            string normalizedCategoryName = (categoryName ?? string.Empty).Trim().ToUpperInvariant();
            string upperDescription = (description ?? string.Empty).Trim().ToUpperInvariant();
            string normalizedItemCode = (itemCode ?? string.Empty).Trim().ToUpperInvariant();

            string mappedFromCategoryName = ResolveCustomCategoryNameToCloudItemCode(normalizedCategoryName, upperDescription);
            if (!string.IsNullOrWhiteSpace(mappedFromCategoryName))
                return mappedFromCategoryName;

            string mappedFromCategoryCode = ResolveCustomCategoryNameToCloudItemCode(normalizedCategory, upperDescription);
            if (!string.IsNullOrWhiteSpace(mappedFromCategoryCode))
                return mappedFromCategoryCode;

            if (string.Equals(normalizedItemCode, "CUSTOM-AQUARIUM", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-AQUARIUM";

            if (string.Equals(normalizedItemCode, "CUSTOM-STAND", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedItemCode, "CUSTOM_STAND", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-STAND";

            if (string.Equals(normalizedItemCode, "CUSTOM-MEDIAS", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-MEDIAS";

            if (string.Equals(normalizedItemCode, "CUSTOM-PIPINGS", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-PIPINGS";

            if (string.Equals(normalizedItemCode, "CUSTOM-SUMP", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedItemCode, "CUSTOM_SUMP", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-SUMP";

            if (string.Equals(normalizedItemCode, "CUSTOM-OVERFLOWBOX", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-OVERFLOWBOX";

            if (string.Equals(normalizedItemCode, "CUSTOM-TOPCOVER", StringComparison.OrdinalIgnoreCase)
                || string.Equals(normalizedItemCode, "CUSTOM-STICKER", StringComparison.OrdinalIgnoreCase))
                return normalizedItemCode;

            return string.Empty;
        }

        private static (string ItemCode, string ItemName, string VariationId) ResolveCustomCatalogReference(string mappedCloudItemCode, string categoryCode, string categoryName)
        {
            string mappedItemName = ResolveMappedCustomItemName(mappedCloudItemCode, categoryName);

            try
            {
                using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                conn.Open();

                using var cmd = new SqlCommand(@"
SELECT TOP 1
    ISNULL(Code, '') AS Code,
    ISNULL(Name, '') AS Name,
    ISNULL(VariationId, '') AS VariationId
FROM dbo.Items
WHERE ISNULL(VariationId, '') <> ''
  AND (
        Code = @MappedCode
        OR CategoryCode = @MappedCode
        OR CategoryCode = @CategoryCode
        OR Name = @MappedItemName
        OR Description = @MappedItemName
        OR Name = @CategoryName
        OR Description = @CategoryName
      )
ORDER BY
    CASE
        WHEN Name = @MappedItemName THEN 0
        WHEN Description = @MappedItemName THEN 1
        WHEN Name = @CategoryName THEN 2
        WHEN Description = @CategoryName THEN 3
        WHEN Code = @MappedCode THEN 4
        WHEN CategoryCode = @MappedCode THEN 5
        WHEN CategoryCode = @CategoryCode THEN 6
        ELSE 7
    END,
    Code", conn);

                cmd.Parameters.AddWithValue("@MappedCode", mappedCloudItemCode ?? string.Empty);
                cmd.Parameters.AddWithValue("@CategoryCode", categoryCode ?? string.Empty);
                cmd.Parameters.AddWithValue("@MappedItemName", mappedItemName ?? string.Empty);
                cmd.Parameters.AddWithValue("@CategoryName", categoryName ?? string.Empty);

                using var reader = cmd.ExecuteReader();
                if (reader.Read())
                {
                    return (
                        reader["Code"]?.ToString()?.Trim() ?? string.Empty,
                        reader["Name"]?.ToString()?.Trim() ?? string.Empty,
                        reader["VariationId"]?.ToString()?.Trim() ?? string.Empty);
                }
            }
            catch
            {
            }

            return (string.Empty, string.Empty, string.Empty);
        }

        private static string ResolveMappedCustomItemName(string mappedCloudItemCode, string categoryName)
        {
            if (!string.IsNullOrWhiteSpace(categoryName))
                return categoryName.Trim();

            string normalized = (mappedCloudItemCode ?? string.Empty).Trim().ToUpperInvariant();
            return normalized switch
            {
                "CUSTOM-AQUARIUM" => "Custom Aquarium",
                "CUSTOM-STAND" => "Custom Stand",
                "CUSTOM-SUMP" => "Custom Sump",
                "CUSTOM-TOPCOVER" => "Custom TopCover",
                "CUSTOM-STICKER" => "Custom Sticker",
                "CUSTOM-MEDIAS" => "Custom Medias",
                "CUSTOM-PIPINGS" => "Custom Pipings",
                "CUSTOM-OVERFLOWBOX" => "Custom Overflow Box",
                _ => mappedCloudItemCode?.Trim() ?? string.Empty
            };
        }

        private static string ResolveCustomCategoryNameToCloudItemCode(string normalizedCategoryName, string upperDescription)
        {
            if (string.IsNullOrWhiteSpace(normalizedCategoryName))
                return string.Empty;

            if (normalizedCategoryName.Contains("CUSTOM AQUARIUM") || normalizedCategoryName.Equals("CUSTOM-AQUARIUM", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-AQUARIUM";

            if (normalizedCategoryName.Contains("CUSTOM STAND") || normalizedCategoryName.Equals("CUSTOM-STAND", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-STAND";

            if (normalizedCategoryName.Contains("CUSTOM SUMP") || normalizedCategoryName.Equals("CUSTOM-SUMP", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-SUMP";

            if (normalizedCategoryName.Contains("CUSTOM TOPCOVER") || normalizedCategoryName.Contains("CUSTOM TOP COVER")
                || normalizedCategoryName.Equals("CUSTOM-TOPCOVER", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-TOPCOVER";

            if (normalizedCategoryName.Contains("CUSTOM STICKER") || normalizedCategoryName.Equals("CUSTOM-STICKER", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-STICKER";

            if (normalizedCategoryName.Contains("CUSTOM MEDIAS") || normalizedCategoryName.Contains("CUSTOM MEDIA")
                || normalizedCategoryName.Equals("CUSTOM-MEDIAS", StringComparison.OrdinalIgnoreCase))
            {
                if (upperDescription.Contains("OVERFLOW BOX") || upperDescription.Contains("OVERFLOWBOX") || upperDescription.Contains("OVERFLOX BOX") || upperDescription.Contains("OVERFLOXBOX"))
                    return "CUSTOM-OVERFLOWBOX";

                return "CUSTOM-MEDIAS";
            }

            if (normalizedCategoryName.Contains("CUSTOM PIPINGS") || normalizedCategoryName.Contains("CUSTOM PIPING")
                || normalizedCategoryName.Equals("CUSTOM-PIPINGS", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-PIPINGS";

            if (normalizedCategoryName.Contains("CUSTOM OVERFLOW BOX") || normalizedCategoryName.Contains("CUSTOM OVERFLOWBOX")
                || normalizedCategoryName.Equals("CUSTOM-OVERFLOWBOX", StringComparison.OrdinalIgnoreCase))
                return "CUSTOM-OVERFLOWBOX";

            return string.Empty;
        }

        /// <summary>
        /// Create an online purchase order using the upstream purchases endpoint.
        ///
        /// This uses the configured OnlineOrdersApiBaseUrl, OnlineOrdersApiKey and
        /// OnlineOrdersShopId, and posts to:
        ///   {BaseURL}/shops/{ShopId}/purchases?api_key={ApiKey}
        ///
        /// Returns the raw response body as string.
        ///
        /// Parameters:
        /// - documentNo: local purchase document number to send upstream
        ///   (only ItemLedgerEntry rows for this DocumentNo and DocumentType='PURCHASE' are used).
        /// </summary>
        public static string CreatePurchaseOnlineOrder(string documentNo)
        {
            return CreatePurchaseOnlineOrderAsync(documentNo).GetAwaiter().GetResult();
        }

        public static async Task<string> CreatePurchaseOnlineOrderAsync(string documentNo, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                throw new ArgumentException("documentNo is required", nameof(documentNo));

            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            timeout ??= TimeSpan.FromSeconds(30);

            // Resolve warehouse for this shop (current warehouse).
            string warehouseId = await GetCurrentWarehouseIdAsync(shopId).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new InvalidOperationException("No current warehouse is selected.");

            // Load ItemLedgerEntry purchase rows for this specific document that have not been sent online yet.
            var itemLines = new List<(string VariationId, decimal Quantity)>();
            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();

                    var sql = new StringBuilder();
                    sql.Append("SELECT VariationId, Quantity FROM ItemLedgerEntry WHERE ISNULL(SentToOnline,0) = 0 AND DocumentType = 'PURCHASE' AND DocumentNo = @DocNo");
                    
                    using (var cmd = new SqlCommand(sql.ToString(), conn))
                    {
                        cmd.Parameters.AddWithValue("@DocNo", documentNo);

                        using (var rdr = cmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                string lineVariationId = string.Empty;
                                try { lineVariationId = rdr["variationid"]?.ToString() ?? string.Empty; } catch { lineVariationId = string.Empty; }

                                decimal qty = 0m;
                                try
                                {
                                    var qv = rdr["Quantity"];
                                    if (qv != null && qv != DBNull.Value)
                                        decimal.TryParse(qv.ToString(), out qty);
                                }
                                catch { qty = 0m; }

                                itemLines.Add((lineVariationId, qty));
                                MessageBox.Show($"Loaded ItemLedgerEntry line for DocumentNo '{documentNo}': VariationId='{lineVariationId}', Quantity={qty}.", "Loaded Line", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException("Failed to read ItemLedgerEntry purchase rows: " + ex.Message, ex);
            }

            // Build items array for the payload using ItemLedgerEntry rows.
            var itemsList = new List<object>();
            int index = 0;

            if (itemLines.Count > 0)
            {
                foreach (var line in itemLines)
                {
                    if (string.IsNullOrWhiteSpace(line.VariationId))
                        continue;

                    var qtyValue = Math.Abs(line.Quantity);
                    if (qtyValue == 0m) qtyValue = 1m;

                    itemsList.Add(new
                    {
                        quantity = qtyValue,
                        variation_id = line.VariationId,
                        index = index++
                    });
                }
            }

            if (itemsList.Count == 0)
                throw new InvalidOperationException("No purchase ItemLedgerEntry rows found with SentToOnline = 0 and DocumentType = 'PURCHASE' for DocumentNo='" + documentNo + "'.");

            // Call the upstream purchases endpoint:
            //   {BaseURL}/shops/{ShopId}/purchases?api_key={ApiKey}
            // Base URL and API key handling are done inside PurchaseApiCallAsync.
            string path = $"shops/{Uri.EscapeDataString(shopId)}/purchases";

            var payload = new
            {
                purchase = new
                {
                    note = string.IsNullOrWhiteSpace(documentNo) ? "" : documentNo,
                    status = 1,
                    not_create_transaction = true,
                    auto_create_debts = true,
                    shop_id = shopId,
                    warehouse_id = warehouseId,
                    change_received_at = true,
                    items = itemsList.ToArray()
                }
            };

            string bodyJson = JsonSerializer.Serialize(payload);

            return await PurchaseApiCallAsync(path, HttpMethod.Post, bodyJson, timeout).ConfigureAwait(false);
        }

        public static string CreateTransferOnlineOrder(string documentNo)
        {
            return CreateTransferOnlineOrderAsync(documentNo).GetAwaiter().GetResult();
        }

        public static TransferOnlineOrderRequestPreview GetTransferOnlineOrderRequestPreview(string documentNo)
        {
            return GetTransferOnlineOrderRequestPreviewAsync(documentNo).GetAwaiter().GetResult();
        }

        internal static TransferOnlineOrderRequestPreview GetTransferOnlineOrderRequestPreview(string documentNo, TransferOrderData.DocumentTableContext documentContext)
        {
            return GetTransferOnlineOrderRequestPreviewAsync(documentNo, documentContext).GetAwaiter().GetResult();
        }

        public static async Task<TransferOnlineOrderRequestPreview> GetTransferOnlineOrderRequestPreviewAsync(string documentNo)
        {
            var request = await BuildTransferOnlineOrderRequestAsync(documentNo).ConfigureAwait(false);
            return request;
        }

        internal static async Task<TransferOnlineOrderRequestPreview> GetTransferOnlineOrderRequestPreviewAsync(string documentNo, TransferOrderData.DocumentTableContext documentContext)
        {
            var request = await BuildTransferOnlineOrderRequestAsync(documentNo, documentContext).ConfigureAwait(false);
            return request;
        }

        public static async Task<string> CreateTransferOnlineOrderAsync(string documentNo, TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            var request = await BuildTransferOnlineOrderRequestAsync(documentNo).ConfigureAwait(false);
            string headerResponse = await PostJsonWithHeadersAsync(request.HeaderEndpointUrl, request.HeaderPayloadJson, timeout.Value).ConfigureAwait(false);
            string lineResponse = await PostJsonWithHeadersAsync(request.LineEndpointUrl, request.LinePayloadJson, timeout.Value).ConfigureAwait(false);
            return $"Header Response:{Environment.NewLine}{headerResponse}{Environment.NewLine}{Environment.NewLine}Line Response:{Environment.NewLine}{lineResponse}";
        }

        internal static string CreateTransferOnlineOrder(string documentNo, TransferOrderData.DocumentTableContext documentContext)
        {
            return CreateTransferOnlineOrderAsync(documentNo, documentContext).GetAwaiter().GetResult();
        }

        internal static async Task<string> CreateTransferOnlineOrderAsync(string documentNo, TransferOrderData.DocumentTableContext documentContext, TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            var request = await BuildTransferOnlineOrderRequestAsync(documentNo, documentContext).ConfigureAwait(false);
            using var headerLookup = await GetSupabaseRowsAsync(request.HeaderEndpointUrl, timeout.Value, ("No.", documentNo.Trim())).ConfigureAwait(false);
            bool headerExists = headerLookup.RootElement.ValueKind == JsonValueKind.Array && headerLookup.RootElement.GetArrayLength() > 0;
            string headerResponse = headerExists
                ? await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(request.HeaderEndpointUrl, ("No.", documentNo.Trim())), request.HeaderPayloadJson, timeout.Value).ConfigureAwait(false)
                : await PostJsonWithHeadersAsync(request.HeaderEndpointUrl, request.HeaderPayloadJson, timeout.Value).ConfigureAwait(false);

            string lineResponse = await SyncTransferLinePayloadAsync(request.LineEndpointUrl, request.LinePayloadJson, timeout.Value).ConfigureAwait(false);
            return $"Header Response:{Environment.NewLine}{headerResponse}{Environment.NewLine}{Environment.NewLine}Line Response:{Environment.NewLine}{lineResponse}";
        }

        private static async Task<string> SyncTransferLinePayloadAsync(string endpointUrl, string payloadJson, TimeSpan timeout)
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payloadJson) ? "[]" : payloadJson);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
                return string.Empty;

            var responses = new List<string>();
            foreach (JsonElement line in document.RootElement.EnumerateArray())
            {
                string documentNo = GetTransferSupabaseJsonString(line, "Document No.", "document_no", "documentNo");
                string lineNo = GetTransferSupabaseJsonString(line, "Line No.", "line_no", "lineNo");
                string lineJson = line.GetRawText();

                bool lineExists = !string.IsNullOrWhiteSpace(documentNo)
                    && !string.IsNullOrWhiteSpace(lineNo)
                    && await SupabaseRecordExistsAsync(endpointUrl, timeout, ("Document No.", documentNo), ("Line No.", lineNo)).ConfigureAwait(false);

                string response = lineExists
                    ? await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(endpointUrl, ("Document No.", documentNo), ("Line No.", lineNo)), lineJson, timeout).ConfigureAwait(false)
                    : await PostJsonWithHeadersAsync(endpointUrl, lineJson, timeout).ConfigureAwait(false);

                if (!string.IsNullOrWhiteSpace(response))
                    responses.Add(response);
            }

            return string.Join(Environment.NewLine + Environment.NewLine, responses);
        }

        private static async Task<JsonDocument> GetSupabaseRowsAsync(string endpointUrl, TimeSpan timeout, params (string ColumnName, string Value)[] filters)
        {
            using var http = new HttpClient { Timeout = timeout };
            string filteredUrl = BuildSupabaseFilteredUrl(endpointUrl, filters);
            string separator = filteredUrl.Contains("?", StringComparison.Ordinal) ? "&" : "?";
            string requestUrl = filteredUrl + separator + "select=*&limit=1";
            using var req = new HttpRequestMessage(HttpMethod.Get, requestUrl);
            req.Headers.TryAddWithoutValidation("apikey", GlobalSettings.TransferHeaderSupabaseApiKey);
            req.Headers.TryAddWithoutValidation("Authorization", GlobalSettings.TransferHeaderSupabaseAuthorization);

            using var resp = await http.SendAsync(req).ConfigureAwait(false);
            string respText = string.Empty;
            try { respText = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { respText = string.Empty; }

            if (!resp.IsSuccessStatusCode)
                throw new HttpRequestException($"Transfer Supabase GET failed for '{endpointUrl}': {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respText}");

            return JsonDocument.Parse(string.IsNullOrWhiteSpace(respText) ? "[]" : respText);
        }

        private static async Task<bool> SupabaseRecordExistsAsync(string endpointUrl, TimeSpan timeout, params (string ColumnName, string Value)[] filters)
        {
            using var document = await GetSupabaseRowsAsync(endpointUrl, timeout, filters).ConfigureAwait(false);
            return document.RootElement.ValueKind == JsonValueKind.Array && document.RootElement.GetArrayLength() > 0;
        }

        private static string BuildSupabaseFilteredUrl(string endpointUrl, params (string ColumnName, string Value)[] filters)
        {
            string result = endpointUrl ?? string.Empty;
            foreach (var filter in filters)
            {
                string separator = result.Contains("?", StringComparison.Ordinal) ? "&" : "?";
                result += separator
                    + Uri.EscapeDataString(FormatSupabaseFilterColumnName(filter.ColumnName))
                    + "=eq."
                    + Uri.EscapeDataString(filter.Value ?? string.Empty);
            }

            return result;
        }

        private static string FormatSupabaseFilterColumnName(string columnName)
        {
            string resolved = columnName?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(resolved))
                return string.Empty;

            bool requiresQuoting = false;
            foreach (char ch in resolved)
            {
                if (!(char.IsLetterOrDigit(ch) || ch == '_'))
                {
                    requiresQuoting = true;
                    break;
                }
            }

            if (!requiresQuoting)
                return resolved;

            return "\"" + resolved.Replace("\"", "\"\"") + "\"";
        }

        private static string GetTransferSupabaseJsonString(JsonElement element, params string[] propertyNames)
        {
            if (element.ValueKind != JsonValueKind.Object)
                return string.Empty;

            foreach (string propertyName in propertyNames)
            {
                if (!TryGetTransferSupabasePropertyIgnoreCase(element, propertyName, out JsonElement value))
                    continue;

                switch (value.ValueKind)
                {
                    case JsonValueKind.String:
                        return value.GetString()?.Trim() ?? string.Empty;
                    case JsonValueKind.Number:
                    case JsonValueKind.True:
                    case JsonValueKind.False:
                        return value.ToString().Trim();
                }
            }

            return string.Empty;
        }

        private static bool TryGetTransferSupabasePropertyIgnoreCase(JsonElement element, string propertyName, out JsonElement value)
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

        private static async Task<TransferOnlineOrderRequestPreview> BuildTransferOnlineOrderRequestAsync(string documentNo)
        {
            return await BuildTransferOnlineOrderRequestAsync(documentNo, TransferOrderData.PostedTransferOrders).ConfigureAwait(false);
        }

        private static async Task<TransferOnlineOrderRequestPreview> BuildTransferOnlineOrderRequestAsync(string documentNo, TransferOrderData.DocumentTableContext documentContext)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                throw new ArgumentException("documentNo is required", nameof(documentNo));

            string no = documentNo.Trim();
            string? description = null;
            string? status = null;
            DateTime? requestedDate = null;
            DateTime? estimatedDeliveryDate = null;
            DateTime? transferDate = null;
            DateTime? receiveDate = null;
            string? fromWarehouseId = null;
            string? fromWarehouse = null;
            string? toWarehouseId = null;
            string? toWarehouse = null;
            string? categoryCode = null;
            bool? useProductionCategory = null;
            DateTime? postedDate = null;
            bool? sentToOnline = null;
            var linePayload = new List<Dictionary<string, object?>>();

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                await conn.OpenAsync().ConfigureAwait(false);

                using (var headerCmd = new SqlCommand(@"
SELECT TOP 1 [No.], [Description], [Status], [Requested Date], [Estimated Delivery Date], [Transfer Date], [Receive Date], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse], [Category Code], [Use Production Category], [Posted Date], [Sent To Online]
FROM " + documentContext.HeaderTableName + @"
WHERE [No.] = @DocNo", conn))
                {
                    headerCmd.Parameters.AddWithValue("@DocNo", documentNo);
                    using var rdr = await headerCmd.ExecuteReaderAsync().ConfigureAwait(false);
                    if (!await rdr.ReadAsync().ConfigureAwait(false))
                        throw new InvalidOperationException($"{documentContext.DocumentTitle} '{documentNo}' was not found.");

                    no = rdr[0] != DBNull.Value ? rdr[0].ToString()?.Trim() ?? no : no;
                    description = rdr[1] != DBNull.Value ? rdr[1].ToString()?.Trim() : null;
                    status = rdr[2] != DBNull.Value ? rdr[2].ToString()?.Trim() : null;
                    try { if (rdr[3] != DBNull.Value) requestedDate = Convert.ToDateTime(rdr[3]); } catch { requestedDate = null; }
                    try { if (rdr[4] != DBNull.Value) estimatedDeliveryDate = Convert.ToDateTime(rdr[4]); } catch { estimatedDeliveryDate = null; }
                    try { if (rdr[5] != DBNull.Value) transferDate = Convert.ToDateTime(rdr[5]); } catch { transferDate = null; }
                    try { if (rdr[6] != DBNull.Value) receiveDate = Convert.ToDateTime(rdr[6]); } catch { receiveDate = null; }
                    fromWarehouseId = rdr[7] != DBNull.Value ? rdr[7].ToString()?.Trim() : null;
                    fromWarehouse = rdr[8] != DBNull.Value ? rdr[8].ToString()?.Trim() : null;
                    toWarehouseId = rdr[9] != DBNull.Value ? rdr[9].ToString()?.Trim() : null;
                    toWarehouse = rdr[10] != DBNull.Value ? rdr[10].ToString()?.Trim() : null;
                    categoryCode = rdr[11] != DBNull.Value ? rdr[11].ToString()?.Trim() : null;
                    try { if (rdr[12] != DBNull.Value) useProductionCategory = Convert.ToBoolean(rdr[12]); } catch { useProductionCategory = null; }
                    try { if (rdr[13] != DBNull.Value) postedDate = Convert.ToDateTime(rdr[13]); } catch { postedDate = null; }
                    try { if (rdr[14] != DBNull.Value) sentToOnline = Convert.ToBoolean(rdr[14]); } catch { sentToOnline = null; }
                }

                using (var lineCmd = new SqlCommand(@"
SELECT [Document No.], [Item No.], [Variant ID], [Description], [CategoryCode], [Line No.], [Available QTY], [Qty To Transfer], [Qty To Receive], [Qty Received]
FROM " + documentContext.LineTableName + @"
WHERE [Document No.] = @DocNo
ORDER BY [Line No.]", conn))
                {
                    lineCmd.Parameters.AddWithValue("@DocNo", documentNo);
                    using var rdr = await lineCmd.ExecuteReaderAsync().ConfigureAwait(false);
                    while (await rdr.ReadAsync().ConfigureAwait(false))
                    {
                        var line = new Dictionary<string, object?>
                        {
                            ["Document No."] = rdr[0] != DBNull.Value ? rdr[0].ToString()?.Trim() : null,
                            ["Item No."] = rdr[1] != DBNull.Value ? rdr[1].ToString()?.Trim() : null,
                            ["Variant ID"] = rdr[2] != DBNull.Value ? rdr[2].ToString()?.Trim() : null,
                            ["Description"] = rdr[3] != DBNull.Value ? rdr[3].ToString()?.Trim() : null,
                            ["CategoryCode"] = rdr[4] != DBNull.Value ? rdr[4].ToString()?.Trim() : null,
                            ["Line No."] = rdr[5] != DBNull.Value ? Convert.ToInt32(rdr[5]) : null,
                            ["Available QTY"] = rdr[6] != DBNull.Value ? Convert.ToDecimal(rdr[6]) : null,
                            ["Qty To Transfer"] = rdr[7] != DBNull.Value ? Convert.ToDecimal(rdr[7]) : null,
                            ["Qty To Receive"] = rdr[8] != DBNull.Value ? Convert.ToDecimal(rdr[8]) : null,
                            ["Qty Received"] = rdr[9] != DBNull.Value ? Convert.ToDecimal(rdr[9]) : null
                        };

                        linePayload.Add(line);
                    }
                }
            }

            var payload = new Dictionary<string, object?>
            {
                ["No."] = no,
                ["Description"] = string.IsNullOrWhiteSpace(description) ? null : description,
                ["Status"] = string.IsNullOrWhiteSpace(status) ? null : status,
                ["Requested Date"] = requestedDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                ["Estimated Delivery Date"] = estimatedDeliveryDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                ["Transfer Date"] = transferDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                ["Receive Date"] = receiveDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                ["From Warehouse ID"] = string.IsNullOrWhiteSpace(fromWarehouseId) ? null : fromWarehouseId,
                ["From Warehouse"] = string.IsNullOrWhiteSpace(fromWarehouse) ? null : fromWarehouse,
                ["To Warehouse ID"] = string.IsNullOrWhiteSpace(toWarehouseId) ? null : toWarehouseId,
                ["To Warehouse"] = string.IsNullOrWhiteSpace(toWarehouse) ? null : toWarehouse,
                ["Category Code"] = string.IsNullOrWhiteSpace(categoryCode) ? null : categoryCode,
                ["Use Production Category"] = useProductionCategory,
                ["Posted Date"] = postedDate?.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture),
                ["Sent To Online"] = sentToOnline
            };

            string headerBodyJson = JsonSerializer.Serialize(payload);
            string lineBodyJson = JsonSerializer.Serialize(linePayload);
            string headerEndpointUrl = GlobalSettings.TransferHeaderSupabaseEndpoint;
            string lineEndpointUrl = GlobalSettings.TransferLineSupabaseEndpoint;
            string resolvedHeaderMethod = "POST";
            string resolvedHeaderEndpointUrl = headerEndpointUrl;
            string lineRequestPreviewText;
            string previewWarning = string.Empty;

            try
            {
                using var headerLookup = await GetSupabaseRowsAsync(headerEndpointUrl, TimeSpan.FromSeconds(30), ("No.", no)).ConfigureAwait(false);
                bool headerExists = headerLookup.RootElement.ValueKind == JsonValueKind.Array && headerLookup.RootElement.GetArrayLength() > 0;
                resolvedHeaderMethod = headerExists ? "PATCH" : "POST";
                resolvedHeaderEndpointUrl = headerExists
                    ? BuildSupabaseFilteredUrl(headerEndpointUrl, ("No.", no))
                    : headerEndpointUrl;
                lineRequestPreviewText = await BuildTransferLineRequestPreviewTextAsync(lineEndpointUrl, lineBodyJson, TimeSpan.FromSeconds(30)).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                resolvedHeaderMethod = "POST/PATCH (unresolved)";
                resolvedHeaderEndpointUrl = headerEndpointUrl;
                lineRequestPreviewText = BuildFallbackTransferLineRequestPreviewText(lineEndpointUrl, lineBodyJson);
                previewWarning = "Preview could not confirm whether this will POST or PATCH before sending. Reason: " + ex.Message;
            }

            return new TransferOnlineOrderRequestPreview(resolvedHeaderMethod, resolvedHeaderEndpointUrl, headerBodyJson, lineEndpointUrl, lineBodyJson, lineRequestPreviewText, previewWarning);
        }

        private static async Task<string> BuildTransferLineRequestPreviewTextAsync(string endpointUrl, string payloadJson, TimeSpan timeout)
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payloadJson) ? "[]" : payloadJson);
            if (document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() == 0)
                return "No line requests will be sent.";

            var sections = new List<string>();
            int lineIndex = 0;
            foreach (JsonElement line in document.RootElement.EnumerateArray())
            {
                lineIndex++;
                string documentNo = GetTransferSupabaseJsonString(line, "Document No.", "document_no", "documentNo");
                string lineNo = GetTransferSupabaseJsonString(line, "Line No.", "line_no", "lineNo");
                bool lineExists = !string.IsNullOrWhiteSpace(documentNo)
                    && !string.IsNullOrWhiteSpace(lineNo)
                    && await SupabaseRecordExistsAsync(endpointUrl, timeout, ("Document No.", documentNo), ("Line No.", lineNo)).ConfigureAwait(false);

                string method = lineExists ? "PATCH" : "POST";
                string resolvedEndpointUrl = lineExists
                    ? BuildSupabaseFilteredUrl(endpointUrl, ("Document No.", documentNo), ("Line No.", lineNo))
                    : endpointUrl;

                sections.Add(
                    $"Line {lineIndex}\nMethod: {method}\nEndpoint:\n{resolvedEndpointUrl}\nPayload:\n{line.GetRawText()}");
            }

            return string.Join(Environment.NewLine + Environment.NewLine, sections);
        }

        private static string BuildFallbackTransferLineRequestPreviewText(string endpointUrl, string payloadJson)
        {
            using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(payloadJson) ? "[]" : payloadJson);
            if (document.RootElement.ValueKind != JsonValueKind.Array || document.RootElement.GetArrayLength() == 0)
                return "No line requests will be sent.";

            var sections = new List<string>();
            int lineIndex = 0;
            foreach (JsonElement line in document.RootElement.EnumerateArray())
            {
                lineIndex++;
                sections.Add(
                    $"Line {lineIndex}\nMethod: POST/PATCH (unresolved)\nEndpoint:\n{endpointUrl}\nPayload:\n{line.GetRawText()}");
            }

            return string.Join(Environment.NewLine + Environment.NewLine, sections);
        }

        public static SerialTrackingSyncSummary SyncItemSerialTrackingToSupabase()
        {
            return SyncItemSerialTrackingToSupabaseAsync().GetAwaiter().GetResult();
        }

        public static async Task<SerialTrackingSyncSummary> SyncItemSerialTrackingToSupabaseAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string endpointUrl = GlobalSettings.ItemSerialTrackingSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(endpointUrl))
                throw new InvalidOperationException("ItemSerialTrackingSupabaseEndpoint is not configured.");

            var serialRecords = LoadItemSerialTrackingRows();
            int insertedCount = 0;
            int updatedCount = 0;
            int skippedDueToConflictCount = 0;

            using var markSyncedConn = new SqlConnection(GlobalSettings.ConnectionString);
            markSyncedConn.Open();
            using var markSyncedCmd = new SqlCommand(
                "UPDATE dbo.ItemSerialTracking SET LastSyncedAtUtc = @LastSyncedAtUtc WHERE RunningSerialNo = @RunningSerialNo", markSyncedConn);
            markSyncedCmd.Parameters.Add("@LastSyncedAtUtc", System.Data.SqlDbType.DateTime2);
            markSyncedCmd.Parameters.Add("@RunningSerialNo", System.Data.SqlDbType.BigInt);

            foreach (var serialRecord in serialRecords)
            {
                string payloadJson = JsonSerializer.Serialize(serialRecord.Payload);

                using var existingDoc = await GetSupabaseRowsAsync(endpointUrl, timeout.Value, ("SerialNo", serialRecord.SerialNo)).ConfigureAwait(false);
                bool exists = existingDoc.RootElement.ValueKind == JsonValueKind.Array && existingDoc.RootElement.GetArrayLength() > 0;

                if (exists)
                {
                    var existingRow = existingDoc.RootElement[0];

                    // Last-writer-wins against the Portal's own direct writes to this same
                    // Supabase row (e.g. staff_claim_serials_for_transfer_shipment tagging a
                    // serial IN_TRANSIT) - if Supabase's own UpdatedAtUtc is already newer than
                    // what this local row knew about when it went dirty, blindly PATCHing now
                    // would clobber that with stale local data. Skip it and leave the row dirty -
                    // SyncItemSerialTrackingFromSupabaseAsync's own next run will pull Supabase's
                    // newer state down locally (which also clears the dirty flag naturally).
                    if (existingRow.TryGetProperty("UpdatedAtUtc", out var existingUpdatedAtProp)
                        && existingUpdatedAtProp.ValueKind == JsonValueKind.String
                        && TryParseSupabaseTimestamp(existingUpdatedAtProp.GetString(), out DateTime existingUpdatedAtUtc)
                        && existingUpdatedAtUtc > serialRecord.ModifiedAtUtc)
                    {
                        skippedDueToConflictCount++;
                        continue;
                    }

                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(endpointUrl, ("SerialNo", serialRecord.SerialNo)), payloadJson, timeout.Value).ConfigureAwait(false);
                    updatedCount++;
                }
                else
                {
                    await PostJsonWithHeadersAsync(endpointUrl, payloadJson, timeout.Value).ConfigureAwait(false);
                    insertedCount++;
                }

                // Stamp with the modified-at value that was actually just synced (not "now") - if the
                // row gets modified again between this read and this write, its ModifiedAtUtc will end
                // up newer than what we stamp here, so the next sync picks it up again instead of it
                // being silently skipped as already-current.
                markSyncedCmd.Parameters["@LastSyncedAtUtc"].Value = serialRecord.ModifiedAtUtc;
                markSyncedCmd.Parameters["@RunningSerialNo"].Value = serialRecord.RunningSerialNo;
                markSyncedCmd.ExecuteNonQuery();
            }

            return new SerialTrackingSyncSummary(serialRecords.Count, insertedCount, updatedCount, skippedDueToConflictCount);
        }

        /// <summary>
        /// Parses a PostgREST/Postgres timestamptz string (e.g. "2026-08-09T10:00:00.123456+00:00")
        /// into a UTC DateTime. Shared by the ItemSerialTracking push (conflict check against
        /// Supabase's own UpdatedAtUtc) and pull (applying/watermarking rows) below.
        /// </summary>
        private static bool TryParseSupabaseTimestamp(string? raw, out DateTime utcValue)
        {
            if (!string.IsNullOrWhiteSpace(raw)
                && DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var dto))
            {
                utcValue = dto.UtcDateTime;
                return true;
            }

            utcValue = default;
            return false;
        }

        /// <summary>
        /// Pulls ItemSerialTracking changes made directly in Supabase (currently just the
        /// Portal's Transfer Order Ship flow tagging a serial IN_TRANSIT, and Receive releasing it
        /// back to IN_STOCK at the destination - see staff_claim_serials_for_transfer_shipment and
        /// releaseReceivedSerials) down into the matching local dbo.ItemSerialTracking row. Unlike
        /// SyncCategoryProductionFlagsFromSupabaseAsync (a single owner, Supabase always wins),
        /// this table is written from both sides, so this applies a Supabase row only when its
        /// own UpdatedAtUtc is strictly newer than the local row's - a plain last-writer-wins
        /// merge, matching the conflict check SyncItemSerialTrackingToSupabaseAsync does in the
        /// opposite direction.
        ///
        /// Matched by SerialNo (globally unique - see UX_ItemSerialTracking_SerialNo), NOT
        /// RunningSerialNo. Every store runs its own separate local SQL Server database (see the
        /// per-machine Server= entries in GlobalSettings.ConnectionString's history), each with
        /// its own independent RunningSerialNo IDENTITY sequence - a serial created at the
        /// production warehouse's database has a RunningSerialNo that means nothing in a different
        /// store's database. If a Supabase row's SerialNo has no local match at all (e.g. this
        /// store just received a shipment tagged/created at a different store), this now INSERTs a
        /// brand-new local row instead of skipping it, so a receiving store's own
        /// GetAvailableSerials/PromptForAquariumSaleSerials can actually find and sell it. Without
        /// this, a non-production store required to pick a serial at sale (see
        /// ShouldRequireAquariumSerialSelection) would never have anything to pick from serials
        /// that physically arrived via Transfer Order.
        ///
        /// Uses a small local watermark table (dbo.ItemSerialTrackingPullState) instead of Category's
        /// full-table-every-time approach, since ItemSerialTracking can grow far larger than the
        /// handful of Categories - only rows Supabase reports changed since the last successful
        /// pull are fetched. Note this does mean every store's local database eventually ends up
        /// with a full replica of every serial system-wide has ever touched it or not, not just its
        /// own - simpler and more robust than trying to filter server-side by "is this store's
        /// warehouse name", at the cost of some redundant local storage.
        /// </summary>
        public static async Task<int> SyncItemSerialTrackingFromSupabaseAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string endpointUrl = GlobalSettings.ItemSerialTrackingSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(endpointUrl))
                throw new InvalidOperationException("ItemSerialTrackingSupabaseEndpoint is not configured.");

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();
            ProductSerialTrackingForm.EnsureSerialTrackingTable(conn, null);
            EnsureItemSerialTrackingPullStateTable(conn);

            DateTime watermarkUtc = GetItemSerialTrackingPullWatermarkUtc(conn);
            string watermarkFilterValue = watermarkUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ", CultureInfo.InvariantCulture);

            using var http = new HttpClient { Timeout = timeout.Value };
            string requestUrl = endpointUrl
                + "?select=SerialNo,ItemCode,ItemDescription,VariantCode,Location,Status,SourceDocumentNo,CreatedAtUtc,CreatedBy,UpdatedAtUtc,UpdatedBy,SoldReceiptNo,SoldOnlineOrderId"
                + "&UpdatedAtUtc=gt." + Uri.EscapeDataString(watermarkFilterValue)
                + "&order=UpdatedAtUtc.asc&limit=1000";
            using var req = new HttpRequestMessage(HttpMethod.Get, requestUrl);
            req.Headers.TryAddWithoutValidation("apikey", GlobalSettings.TransferHeaderSupabaseApiKey);
            req.Headers.TryAddWithoutValidation("Authorization", GlobalSettings.TransferHeaderSupabaseAuthorization);

            using var resp = await http.SendAsync(req).ConfigureAwait(false);
            string respText = string.Empty;
            try { respText = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { respText = string.Empty; }

            if (!resp.IsSuccessStatusCode)
                throw new HttpRequestException($"ItemSerialTracking Supabase GET failed: {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respText}");

            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(respText) ? "[]" : respText);
            if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0)
                return 0;

            int appliedCount = 0;
            DateTime? maxUpdatedAtUtcSeen = null;

            using var localLookupCmd = new SqlCommand(
                "SELECT COALESCE(UpdatedAtUtc, CreatedAtUtc) FROM dbo.ItemSerialTracking WHERE SerialNo = @SerialNo", conn);
            localLookupCmd.Parameters.Add("@SerialNo", System.Data.SqlDbType.NVarChar, 120);

            using var updateCmd = new SqlCommand(@"
UPDATE dbo.ItemSerialTracking
SET Status = @Status,
    Location = @Location,
    SourceDocumentNo = @SourceDocumentNo,
    VariantCode = @VariantCode,
    SoldReceiptNo = @SoldReceiptNo,
    SoldOnlineOrderId = @SoldOnlineOrderId,
    UpdatedAtUtc = @UpdatedAtUtc,
    UpdatedBy = @UpdatedBy,
    LastSyncedAtUtc = @UpdatedAtUtc
WHERE SerialNo = @SerialNo", conn);
            updateCmd.Parameters.Add("@Status", System.Data.SqlDbType.NVarChar, 255);
            updateCmd.Parameters.Add("@Location", System.Data.SqlDbType.NVarChar, 255);
            updateCmd.Parameters.Add("@SourceDocumentNo", System.Data.SqlDbType.NVarChar, 100);
            updateCmd.Parameters.Add("@VariantCode", System.Data.SqlDbType.NVarChar, 200);
            updateCmd.Parameters.Add("@SoldReceiptNo", System.Data.SqlDbType.NVarChar, 100);
            updateCmd.Parameters.Add("@SoldOnlineOrderId", System.Data.SqlDbType.NVarChar, 100);
            updateCmd.Parameters.Add("@UpdatedAtUtc", System.Data.SqlDbType.DateTime2);
            updateCmd.Parameters.Add("@UpdatedBy", System.Data.SqlDbType.NVarChar, 200);
            updateCmd.Parameters.Add("@SerialNo", System.Data.SqlDbType.NVarChar, 120);

            using var insertCmd = new SqlCommand(@"
INSERT INTO dbo.ItemSerialTracking
    (SerialNo, ItemCode, ItemDescription, VariantCode, Location, Status, SourceDocumentNo,
     CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, SoldReceiptNo, SoldOnlineOrderId, LastSyncedAtUtc)
VALUES
    (@SerialNo, @ItemCode, @ItemDescription, @VariantCode, @Location, @Status, @SourceDocumentNo,
     @CreatedAtUtc, @CreatedBy, @UpdatedAtUtc, @UpdatedBy, @SoldReceiptNo, @SoldOnlineOrderId, @UpdatedAtUtc)", conn);
            insertCmd.Parameters.Add("@SerialNo", System.Data.SqlDbType.NVarChar, 120);
            insertCmd.Parameters.Add("@ItemCode", System.Data.SqlDbType.NVarChar, 100);
            insertCmd.Parameters.Add("@ItemDescription", System.Data.SqlDbType.NVarChar, 255);
            insertCmd.Parameters.Add("@VariantCode", System.Data.SqlDbType.NVarChar, 200);
            insertCmd.Parameters.Add("@Location", System.Data.SqlDbType.NVarChar, 255);
            insertCmd.Parameters.Add("@Status", System.Data.SqlDbType.NVarChar, 255);
            insertCmd.Parameters.Add("@SourceDocumentNo", System.Data.SqlDbType.NVarChar, 100);
            insertCmd.Parameters.Add("@CreatedAtUtc", System.Data.SqlDbType.DateTime2);
            insertCmd.Parameters.Add("@CreatedBy", System.Data.SqlDbType.NVarChar, 100);
            insertCmd.Parameters.Add("@UpdatedAtUtc", System.Data.SqlDbType.DateTime2);
            insertCmd.Parameters.Add("@UpdatedBy", System.Data.SqlDbType.NVarChar, 200);
            insertCmd.Parameters.Add("@SoldReceiptNo", System.Data.SqlDbType.NVarChar, 100);
            insertCmd.Parameters.Add("@SoldOnlineOrderId", System.Data.SqlDbType.NVarChar, 100);

            foreach (var row in doc.RootElement.EnumerateArray())
            {
                if (row.ValueKind != JsonValueKind.Object) continue;

                string serialNo = row.TryGetProperty("SerialNo", out var serialNoProp) && serialNoProp.ValueKind == JsonValueKind.String
                    ? serialNoProp.GetString()?.Trim() ?? string.Empty
                    : string.Empty;
                string itemCode = row.TryGetProperty("ItemCode", out var itemCodeProp) && itemCodeProp.ValueKind == JsonValueKind.String
                    ? itemCodeProp.GetString()?.Trim() ?? string.Empty
                    : string.Empty;
                if (string.IsNullOrWhiteSpace(serialNo) || string.IsNullOrWhiteSpace(itemCode))
                    continue; // can't insert - SerialNo/ItemCode are NOT NULL locally

                string? updatedAtRaw = row.TryGetProperty("UpdatedAtUtc", out var updatedAtProp) && updatedAtProp.ValueKind == JsonValueKind.String
                    ? updatedAtProp.GetString()
                    : null;
                if (!TryParseSupabaseTimestamp(updatedAtRaw, out DateTime supabaseUpdatedAtUtc))
                    continue;

                if (maxUpdatedAtUtcSeen == null || supabaseUpdatedAtUtc > maxUpdatedAtUtcSeen.Value)
                    maxUpdatedAtUtcSeen = supabaseUpdatedAtUtc;

                localLookupCmd.Parameters["@SerialNo"].Value = serialNo;
                object? localModifiedObj = localLookupCmd.ExecuteScalar();

                string? status = row.TryGetProperty("Status", out var statusProp) && statusProp.ValueKind == JsonValueKind.String ? statusProp.GetString() : "IN_STOCK";
                object location = row.TryGetProperty("Location", out var locProp) && locProp.ValueKind == JsonValueKind.String ? (object)locProp.GetString()! : DBNull.Value;
                object sourceDocumentNo = row.TryGetProperty("SourceDocumentNo", out var srcProp) && srcProp.ValueKind == JsonValueKind.String ? (object)srcProp.GetString()! : DBNull.Value;
                object variantCode = row.TryGetProperty("VariantCode", out var varProp) && varProp.ValueKind == JsonValueKind.String ? (object)varProp.GetString()! : DBNull.Value;
                object soldReceiptNo = row.TryGetProperty("SoldReceiptNo", out var soldReceiptProp) && soldReceiptProp.ValueKind == JsonValueKind.String ? (object)soldReceiptProp.GetString()! : DBNull.Value;
                object soldOnlineOrderId = row.TryGetProperty("SoldOnlineOrderId", out var soldOnlineProp) && soldOnlineProp.ValueKind == JsonValueKind.String ? (object)soldOnlineProp.GetString()! : DBNull.Value;
                object updatedBy = row.TryGetProperty("UpdatedBy", out var updatedByProp) && updatedByProp.ValueKind == JsonValueKind.String ? (object)updatedByProp.GetString()! : DBNull.Value;

                if (localModifiedObj == null || localModifiedObj == DBNull.Value)
                {
                    // No local row for this SerialNo at all - this store has never seen it before
                    // (created and/or last touched at a different store's database). Insert it
                    // fresh rather than skipping, so it becomes pickable here.
                    string itemDescription = row.TryGetProperty("ItemDescription", out var descProp) && descProp.ValueKind == JsonValueKind.String ? descProp.GetString() ?? string.Empty : string.Empty;
                    string createdBy = row.TryGetProperty("CreatedBy", out var createdByProp) && createdByProp.ValueKind == JsonValueKind.String ? createdByProp.GetString() ?? string.Empty : string.Empty;
                    string? createdAtRaw = row.TryGetProperty("CreatedAtUtc", out var createdAtProp) && createdAtProp.ValueKind == JsonValueKind.String ? createdAtProp.GetString() : null;
                    DateTime createdAtUtc = TryParseSupabaseTimestamp(createdAtRaw, out DateTime parsedCreatedAtUtc) ? parsedCreatedAtUtc : supabaseUpdatedAtUtc;

                    insertCmd.Parameters["@SerialNo"].Value = serialNo;
                    insertCmd.Parameters["@ItemCode"].Value = itemCode;
                    insertCmd.Parameters["@ItemDescription"].Value = string.IsNullOrWhiteSpace(itemDescription) ? (object)DBNull.Value : itemDescription;
                    insertCmd.Parameters["@VariantCode"].Value = variantCode;
                    insertCmd.Parameters["@Location"].Value = location;
                    insertCmd.Parameters["@Status"].Value = status;
                    insertCmd.Parameters["@SourceDocumentNo"].Value = sourceDocumentNo;
                    insertCmd.Parameters["@CreatedAtUtc"].Value = createdAtUtc;
                    insertCmd.Parameters["@CreatedBy"].Value = string.IsNullOrWhiteSpace(createdBy) ? (object)DBNull.Value : createdBy;
                    insertCmd.Parameters["@UpdatedAtUtc"].Value = supabaseUpdatedAtUtc;
                    insertCmd.Parameters["@UpdatedBy"].Value = updatedBy;
                    insertCmd.Parameters["@SoldReceiptNo"].Value = soldReceiptNo;
                    insertCmd.Parameters["@SoldOnlineOrderId"].Value = soldOnlineOrderId;
                    appliedCount += insertCmd.ExecuteNonQuery();
                    continue;
                }

                DateTime localModifiedAtUtc = Convert.ToDateTime(localModifiedObj, CultureInfo.InvariantCulture);

                // Last-writer-wins: only apply Supabase's version if it's strictly newer than
                // what's already local - otherwise local's own (equal-or-newer) state is correct
                // and the push side will (re)send it up, so overwriting here would be self-defeating.
                if (supabaseUpdatedAtUtc <= localModifiedAtUtc)
                    continue;

                updateCmd.Parameters["@Status"].Value = status;
                updateCmd.Parameters["@Location"].Value = location;
                updateCmd.Parameters["@SourceDocumentNo"].Value = sourceDocumentNo;
                updateCmd.Parameters["@VariantCode"].Value = variantCode;
                updateCmd.Parameters["@SoldReceiptNo"].Value = soldReceiptNo;
                updateCmd.Parameters["@SoldOnlineOrderId"].Value = soldOnlineOrderId;
                updateCmd.Parameters["@UpdatedAtUtc"].Value = supabaseUpdatedAtUtc;
                updateCmd.Parameters["@UpdatedBy"].Value = updatedBy;
                updateCmd.Parameters["@SerialNo"].Value = serialNo;
                appliedCount += updateCmd.ExecuteNonQuery();
            }

            if (maxUpdatedAtUtcSeen.HasValue)
                SetItemSerialTrackingPullWatermarkUtc(conn, maxUpdatedAtUtcSeen.Value);

            return appliedCount;
        }

        private static void EnsureItemSerialTrackingPullStateTable(SqlConnection conn)
        {
            const string sql = @"
IF OBJECT_ID('dbo.ItemSerialTrackingPullState', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ItemSerialTrackingPullState (
        Id INT NOT NULL PRIMARY KEY CHECK (Id = 1),
        LastPulledUpdatedAtUtc DATETIME2 NULL
    );
    INSERT INTO dbo.ItemSerialTrackingPullState (Id, LastPulledUpdatedAtUtc) VALUES (1, NULL);
END";
            using var cmd = new SqlCommand(sql, conn);
            cmd.ExecuteNonQuery();
        }

        private static DateTime GetItemSerialTrackingPullWatermarkUtc(SqlConnection conn)
        {
            using var cmd = new SqlCommand("SELECT LastPulledUpdatedAtUtc FROM dbo.ItemSerialTrackingPullState WHERE Id = 1", conn);
            object? result = cmd.ExecuteScalar();
            // Default far enough in the past to capture every existing Supabase row on the very
            // first pull ever run on this machine.
            return result == null || result == DBNull.Value
                ? new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc)
                : DateTime.SpecifyKind(Convert.ToDateTime(result, CultureInfo.InvariantCulture), DateTimeKind.Utc);
        }

        private static void SetItemSerialTrackingPullWatermarkUtc(SqlConnection conn, DateTime lastPulledUpdatedAtUtc)
        {
            using var cmd = new SqlCommand("UPDATE dbo.ItemSerialTrackingPullState SET LastPulledUpdatedAtUtc = @Value WHERE Id = 1", conn);
            cmd.Parameters.Add("@Value", System.Data.SqlDbType.DateTime2).Value = lastPulledUpdatedAtUtc;
            cmd.ExecuteNonQuery();
        }

        // Only rows modified since their last successful sync (see SyncItemSerialTrackingToSupabaseAsync's
        // LastSyncedAtUtc stamping) - lets this run cheaply and often (e.g. from a timer/cron), instead of
        // re-checking every serial ever tracked on every call.
        private static List<ItemSerialTrackingSupabaseRow> LoadItemSerialTrackingRows()
        {
            var serialRecords = new List<ItemSerialTrackingSupabaseRow>();
            using var connection = new SqlConnection(GlobalSettings.ConnectionString);
            connection.Open();
            ProductSerialTrackingForm.EnsureSerialTrackingTable(connection, null);

            using var cmd = new SqlCommand(@"
SELECT [RunningSerialNo], [SerialNo], [ItemCode], ISNULL([VariantCode], '') AS [VariantCode],
    [ItemDescription], ISNULL([Location], '') AS [Location], [Status], [SourceDocumentNo], [CreatedAtUtc], [CreatedBy],
       [UpdatedAtUtc], [UpdatedBy], [SoldReceiptNo], [SoldOnlineOrderId],
       COALESCE([UpdatedAtUtc], [CreatedAtUtc]) AS [ModifiedAtUtc]
FROM dbo.ItemSerialTracking
WHERE ISNULL([SerialNo], '') <> ''
  AND ([LastSyncedAtUtc] IS NULL OR COALESCE([UpdatedAtUtc], [CreatedAtUtc]) > [LastSyncedAtUtc])
ORDER BY [RunningSerialNo]", connection);

            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string serialNo = rdr["SerialNo"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(serialNo))
                    continue;

                long runningSerialNo = rdr["RunningSerialNo"] != DBNull.Value ? Convert.ToInt64(rdr["RunningSerialNo"], CultureInfo.InvariantCulture) : 0;
                DateTime modifiedAtUtc = Convert.ToDateTime(rdr["ModifiedAtUtc"], CultureInfo.InvariantCulture);

                serialRecords.Add(new ItemSerialTrackingSupabaseRow(
                    serialNo,
                    runningSerialNo,
                    modifiedAtUtc,
                    new Dictionary<string, object?>
                    {
                        ["RunningSerialNo"] = rdr["RunningSerialNo"] != DBNull.Value ? Convert.ToInt64(rdr["RunningSerialNo"], CultureInfo.InvariantCulture) : null,
                        ["SerialNo"] = serialNo,
                        ["ItemCode"] = rdr["ItemCode"]?.ToString()?.Trim() ?? string.Empty,
                        ["VariantCode"] = rdr["VariantCode"]?.ToString()?.Trim() ?? string.Empty,
                        ["ItemDescription"] = rdr["ItemDescription"] != DBNull.Value ? rdr["ItemDescription"]?.ToString() : null,
                        ["Location"] = rdr["Location"]?.ToString()?.Trim() ?? string.Empty,
                        ["Status"] = rdr["Status"]?.ToString()?.Trim() ?? "IN_STOCK",
                        ["SourceDocumentNo"] = rdr["SourceDocumentNo"] != DBNull.Value ? rdr["SourceDocumentNo"]?.ToString() : null,
                        ["CreatedAtUtc"] = rdr["CreatedAtUtc"] != DBNull.Value ? Convert.ToDateTime(rdr["CreatedAtUtc"], CultureInfo.InvariantCulture).ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture) : null,
                        ["CreatedBy"] = rdr["CreatedBy"] != DBNull.Value ? rdr["CreatedBy"]?.ToString() : null,
                        ["UpdatedAtUtc"] = rdr["UpdatedAtUtc"] != DBNull.Value ? Convert.ToDateTime(rdr["UpdatedAtUtc"], CultureInfo.InvariantCulture).ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture) : null,
                        ["UpdatedBy"] = rdr["UpdatedBy"] != DBNull.Value ? rdr["UpdatedBy"]?.ToString() : null,
                        ["SoldReceiptNo"] = rdr["SoldReceiptNo"] != DBNull.Value ? rdr["SoldReceiptNo"]?.ToString() : null,
                        ["SoldOnlineOrderId"] = rdr["SoldOnlineOrderId"] != DBNull.Value ? rdr["SoldOnlineOrderId"]?.ToString() : null
                    }));
            }

            return serialRecords;
        }

        private readonly struct ItemSerialTrackingSupabaseRow
        {
            public ItemSerialTrackingSupabaseRow(string serialNo, long runningSerialNo, DateTime modifiedAtUtc, Dictionary<string, object?> payload)
            {
                SerialNo = serialNo;
                RunningSerialNo = runningSerialNo;
                ModifiedAtUtc = modifiedAtUtc;
                Payload = payload;
            }

            public string SerialNo { get; }
            public long RunningSerialNo { get; }
            public DateTime ModifiedAtUtc { get; }
            public Dictionary<string, object?> Payload { get; }
        }

        public readonly struct MasterDataSyncSummary
        {
            public MasterDataSyncSummary(int syncedCount, int insertedCount, int updatedCount)
            {
                SyncedCount = syncedCount;
                InsertedCount = insertedCount;
                UpdatedCount = updatedCount;
            }

            public int SyncedCount { get; }
            public int InsertedCount { get; }
            public int UpdatedCount { get; }
        }

        /// <summary>
        /// Pushes the local Warehouses table (dbo.Warehouses, resolved the same flexible way as
        /// TransferOrderData.GetWarehouseOptions) up to Supabase, inserting new rows or patching
        /// existing ones (matched by ID) so re-running the sync is always safe.
        /// </summary>
        public static MasterDataSyncSummary SyncWarehousesToSupabase()
        {
            return SyncWarehousesToSupabaseAsync().GetAwaiter().GetResult();
        }

        public static async Task<MasterDataSyncSummary> SyncWarehousesToSupabaseAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string endpointUrl = GlobalSettings.WarehousesSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(endpointUrl))
                throw new InvalidOperationException("WarehousesSupabaseEndpoint is not configured.");

            var warehouses = TransferOrderData.GetWarehouseOptions(GlobalSettings.ConnectionString);
            int insertedCount = 0;
            int updatedCount = 0;

            foreach (var warehouse in warehouses)
            {
                if (string.IsNullOrWhiteSpace(warehouse.Id))
                    continue;

                var payload = new Dictionary<string, object?>
                {
                    ["ID"] = warehouse.Id,
                    ["Name"] = warehouse.Name,
                    ["IsProductionWarehouse"] = warehouse.IsProductionWarehouse,
                    ["IsStockWarehouse"] = warehouse.IsStockWarehouse,
                    ["SyncedAtUtc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture)
                };
                string payloadJson = JsonSerializer.Serialize(payload);

                bool exists = await SupabaseRecordExistsAsync(endpointUrl, timeout.Value, ("ID", warehouse.Id)).ConfigureAwait(false);
                if (exists)
                {
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(endpointUrl, ("ID", warehouse.Id)), payloadJson, timeout.Value).ConfigureAwait(false);
                    updatedCount++;
                }
                else
                {
                    await PostJsonWithHeadersAsync(endpointUrl, payloadJson, timeout.Value).ConfigureAwait(false);
                    insertedCount++;
                }
            }

            return new MasterDataSyncSummary(warehouses.Count, insertedCount, updatedCount);
        }

        /// <summary>
        /// Pushes the local Items table (dbo.Items - product master data) up to Supabase, inserting
        /// new rows or patching existing ones (matched by Code) so re-running the sync is always
        /// safe. Only columns that actually exist on the local Items table are read/sent, since the
        /// exact column set can vary slightly between installs (VariationId/ProductId etc. are
        /// added by other sync features on demand).
        /// </summary>
        public static MasterDataSyncSummary SyncItemsToSupabase()
        {
            return SyncItemsToSupabaseAsync().GetAwaiter().GetResult();
        }

        public static async Task<MasterDataSyncSummary> SyncItemsToSupabaseAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string endpointUrl = GlobalSettings.ItemsSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(endpointUrl))
                throw new InvalidOperationException("ItemsSupabaseEndpoint is not configured.");

            var itemRows = LoadItemRows();
            int insertedCount = 0;
            int updatedCount = 0;

            foreach (var itemRow in itemRows)
            {
                string payloadJson = JsonSerializer.Serialize(itemRow.Payload);
                bool exists = await SupabaseRecordExistsAsync(endpointUrl, timeout.Value, ("Code", itemRow.Code)).ConfigureAwait(false);
                if (exists)
                {
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(endpointUrl, ("Code", itemRow.Code)), payloadJson, timeout.Value).ConfigureAwait(false);
                    updatedCount++;
                }
                else
                {
                    await PostJsonWithHeadersAsync(endpointUrl, payloadJson, timeout.Value).ConfigureAwait(false);
                    insertedCount++;
                }
            }

            return new MasterDataSyncSummary(itemRows.Count, insertedCount, updatedCount);
        }

        private static readonly string[] OptionalItemColumns = new[]
        {
            "Description", "Cost", "Price", "WholesalePrice", "RetailPrice", "PromoPrice",
            "CategoryCode", "Brand", "SKU", "QuantityInStock", "MinimumStock", "IsActive",
            "VariationId", "ProductId"
        };

        private static List<(string Code, Dictionary<string, object?> Payload)> LoadItemRows()
        {
            var rows = new List<(string Code, Dictionary<string, object?> Payload)>();
            using var connection = new SqlConnection(GlobalSettings.ConnectionString);
            connection.Open();

            var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var colCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Items'", connection))
            using (var colRdr = colCmd.ExecuteReader())
            {
                while (colRdr.Read())
                {
                    string columnName = colRdr[0]?.ToString() ?? string.Empty;
                    if (!string.IsNullOrWhiteSpace(columnName))
                        columns.Add(columnName);
                }
            }

            if (!columns.Contains("Code"))
                return rows;

            var presentOptionalColumns = OptionalItemColumns.Where(c => columns.Contains(c)).ToList();
            string selectColumns = "[Code]"
                + (columns.Contains("Name") ? ", [Name]" : string.Empty)
                + (presentOptionalColumns.Count > 0 ? ", [" + string.Join("], [", presentOptionalColumns) + "]" : string.Empty);

            using var cmd = new SqlCommand($"SELECT {selectColumns} FROM dbo.Items", connection);
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string code = rdr["Code"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(code))
                    continue;

                var payload = new Dictionary<string, object?> { ["Code"] = code };
                if (columns.Contains("Name"))
                    payload["Name"] = rdr["Name"] != DBNull.Value ? rdr["Name"]?.ToString() : null;

                foreach (var column in presentOptionalColumns)
                {
                    var value = rdr[column];
                    payload[column] = value == DBNull.Value ? null : value;
                }

                payload["SyncedAtUtc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture);

                rows.Add((code, payload));
            }

            return rows;
        }

        /// <summary>
        /// Pushes the local Online Orders tables (dbo.OnlineOrderHeader/dbo.OnlineOrderLines - Pancake
        /// customer orders) up to Supabase, inserting new rows or patching existing ones (matched by
        /// OrderID, and OrderID+LineID for lines) so re-running the sync is always safe. Only columns
        /// that actually exist locally are read/sent, since some (LocationID, PrintCount, Note, etc.)
        /// were added to the schema over time and may be missing on older installs.
        /// </summary>
        public static MasterDataSyncSummary SyncOnlineOrdersToSupabase()
        {
            return SyncOnlineOrdersToSupabaseAsync().GetAwaiter().GetResult();
        }

        public static async Task<MasterDataSyncSummary> SyncOnlineOrdersToSupabaseAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string headerEndpoint = GlobalSettings.OnlineOrdersSupabaseEndpoint?.Trim() ?? string.Empty;
            string lineEndpoint = GlobalSettings.OnlineOrderLinesSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(headerEndpoint))
                throw new InvalidOperationException("OnlineOrdersSupabaseEndpoint is not configured.");
            if (string.IsNullOrWhiteSpace(lineEndpoint))
                throw new InvalidOperationException("OnlineOrderLinesSupabaseEndpoint is not configured.");

            var headerRows = LoadOnlineOrderHeaderRows();
            int insertedCount = 0;
            int updatedCount = 0;

            foreach (var headerRow in headerRows)
            {
                string payloadJson = JsonSerializer.Serialize(headerRow.Payload);
                bool exists = await SupabaseRecordExistsAsync(headerEndpoint, timeout.Value, ("OrderID", headerRow.OrderId)).ConfigureAwait(false);
                if (exists)
                {
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(headerEndpoint, ("OrderID", headerRow.OrderId)), payloadJson, timeout.Value).ConfigureAwait(false);
                    updatedCount++;
                }
                else
                {
                    await PostJsonWithHeadersAsync(headerEndpoint, payloadJson, timeout.Value).ConfigureAwait(false);
                    insertedCount++;
                }
            }

            var lineRows = LoadOnlineOrderLineRows();
            foreach (var lineRow in lineRows)
            {
                string payloadJson = JsonSerializer.Serialize(lineRow.Payload);
                bool exists = await SupabaseRecordExistsAsync(lineEndpoint, timeout.Value, ("OrderID", lineRow.OrderId), ("LineID", lineRow.LineId)).ConfigureAwait(false);
                if (exists)
                {
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(lineEndpoint, ("OrderID", lineRow.OrderId), ("LineID", lineRow.LineId)), payloadJson, timeout.Value).ConfigureAwait(false);
                    updatedCount++;
                }
                else
                {
                    await PostJsonWithHeadersAsync(lineEndpoint, payloadJson, timeout.Value).ConfigureAwait(false);
                    insertedCount++;
                }
            }

            return new MasterDataSyncSummary(headerRows.Count + lineRows.Count, insertedCount, updatedCount);
        }

        private static readonly string[] OptionalOnlineOrderHeaderColumns = new[]
        {
            "Date", "Time", "Status", "CustomerName", "Page_ID", "Conversation_ID", "LocationID",
            "MoneyToCollect", "AmountPaid", "Discount", "Balance", "For Delivery", "Shipping Address",
            "Estimated Delivery Date", "PrintCount", "Last_Updated_At", "Converted_LastUpdated_At",
            "LastPaid_Date", "LastPaid_Time", "Date of Completion"
        };

        private static List<(string OrderId, Dictionary<string, object?> Payload)> LoadOnlineOrderHeaderRows()
        {
            var rows = new List<(string OrderId, Dictionary<string, object?> Payload)>();
            using var connection = new SqlConnection(GlobalSettings.ConnectionString);
            connection.Open();

            var columns = LoadTableColumnNames(connection, "OnlineOrderHeader");
            if (!columns.Contains("OrderID"))
                return rows;

            var presentColumns = OptionalOnlineOrderHeaderColumns.Where(c => columns.Contains(c)).ToList();
            string selectColumns = "[OrderID]" + (presentColumns.Count > 0 ? ", [" + string.Join("], [", presentColumns) + "]" : string.Empty);

            using var cmd = new SqlCommand($"SELECT {selectColumns} FROM dbo.OnlineOrderHeader", connection);
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string orderId = rdr["OrderID"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(orderId))
                    continue;

                var payload = new Dictionary<string, object?> { ["OrderID"] = orderId };
                foreach (var column in presentColumns)
                {
                    var value = rdr[column];
                    payload[SanitizeSupabaseColumnName(column)] = value == DBNull.Value ? null : ConvertSupabaseValue(value);
                }
                payload["SyncedAtUtc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture);

                rows.Add((orderId, payload));
            }

            return rows;
        }

        private static readonly string[] OptionalOnlineOrderLineColumns = new[]
        {
            "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price",
            "Discount", "GrossAmount", "NetAmount", "Note", "Description"
        };

        private static List<(string OrderId, string LineId, Dictionary<string, object?> Payload)> LoadOnlineOrderLineRows()
        {
            var rows = new List<(string OrderId, string LineId, Dictionary<string, object?> Payload)>();
            using var connection = new SqlConnection(GlobalSettings.ConnectionString);
            connection.Open();

            var columns = LoadTableColumnNames(connection, "OnlineOrderLines");
            if (!columns.Contains("OrderID") || !columns.Contains("LineID"))
                return rows;

            var presentColumns = OptionalOnlineOrderLineColumns.Where(c => columns.Contains(c)).ToList();
            string selectColumns = "[OrderID], [LineID]" + (presentColumns.Count > 0 ? ", [" + string.Join("], [", presentColumns) + "]" : string.Empty);

            using var cmd = new SqlCommand($"SELECT {selectColumns} FROM dbo.OnlineOrderLines", connection);
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string orderId = rdr["OrderID"]?.ToString()?.Trim() ?? string.Empty;
                string lineId = rdr["LineID"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(orderId) || string.IsNullOrWhiteSpace(lineId))
                    continue;

                var payload = new Dictionary<string, object?> { ["OrderID"] = orderId, ["LineID"] = lineId };
                foreach (var column in presentColumns)
                {
                    var value = rdr[column];
                    payload[SanitizeSupabaseColumnName(column)] = value == DBNull.Value ? null : ConvertSupabaseValue(value);
                }
                payload["SyncedAtUtc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture);

                rows.Add((orderId, lineId, payload));
            }

            return rows;
        }

        /// <summary>
        /// Pushes the local Advance Orders tables (dbo.AdvanceOrderHeader/dbo.AdvanceOrderLines -
        /// customer deposit/downpayment orders) up to Supabase, inserting new rows or patching
        /// existing ones (matched by TransactionNo, and TransactionNo+LineNo for lines).
        /// </summary>
        public static MasterDataSyncSummary SyncAdvanceOrdersToSupabase()
        {
            return SyncAdvanceOrdersToSupabaseAsync().GetAwaiter().GetResult();
        }

        public static async Task<MasterDataSyncSummary> SyncAdvanceOrdersToSupabaseAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string headerEndpoint = GlobalSettings.AdvanceOrdersSupabaseEndpoint?.Trim() ?? string.Empty;
            string lineEndpoint = GlobalSettings.AdvanceOrderLinesSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(headerEndpoint))
                throw new InvalidOperationException("AdvanceOrdersSupabaseEndpoint is not configured.");
            if (string.IsNullOrWhiteSpace(lineEndpoint))
                throw new InvalidOperationException("AdvanceOrderLinesSupabaseEndpoint is not configured.");

            var headerRows = LoadAdvanceOrderHeaderRows();
            ApplyCurrentWarehouseToHeaderRows(headerRows);
            var (headerInserted, headerUpdated) = await UpsertAdvanceOrderHeaderRowsAsync(headerEndpoint, headerRows, timeout.Value).ConfigureAwait(false);

            var lineRows = LoadAdvanceOrderLineRows();
            var (lineInserted, lineUpdated) = await UpsertAdvanceOrderLineRowsAsync(lineEndpoint, lineRows, timeout.Value).ConfigureAwait(false);

            return new MasterDataSyncSummary(headerRows.Count + lineRows.Count, headerInserted + lineInserted, headerUpdated + lineUpdated);
        }

        public static string SyncSingleAdvanceOrderToSupabase(string receiptNo)
        {
            return SyncSingleAdvanceOrderToSupabaseAsync(receiptNo).GetAwaiter().GetResult();
        }

        // Pushes just one advance order's header + lines to Supabase right after it's posted, instead
        // of waiting for the next masterDataSyncTimer tick (every 5 minutes - see MainForm.
        // MasterDataSyncTimer_Tick) to pick it up. Records the outcome into
        // dbo.AdvanceOrderPortalSyncMap so AdvanceOrdersHeaderForm/AdvanceOrderLinesForm can show a
        // "Portal Status" the same way they already show "Pancake Status" from
        // dbo.InstoreOnlineOrderMap. The periodic bulk sync above still runs regardless, as a safety
        // net for anything this per-receipt push missed or failed.
        public static async Task<string> SyncSingleAdvanceOrderToSupabaseAsync(string receiptNo, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(receiptNo))
                throw new ArgumentException("receiptNo is required", nameof(receiptNo));

            timeout ??= TimeSpan.FromSeconds(30);
            receiptNo = receiptNo.Trim();

            try
            {
                string headerEndpoint = GlobalSettings.AdvanceOrdersSupabaseEndpoint?.Trim() ?? string.Empty;
                string lineEndpoint = GlobalSettings.AdvanceOrderLinesSupabaseEndpoint?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(headerEndpoint))
                    throw new InvalidOperationException("AdvanceOrdersSupabaseEndpoint is not configured.");
                if (string.IsNullOrWhiteSpace(lineEndpoint))
                    throw new InvalidOperationException("AdvanceOrderLinesSupabaseEndpoint is not configured.");

                var headerRows = LoadAdvanceOrderHeaderRows(receiptNo);
                ApplyCurrentWarehouseToHeaderRows(headerRows);
                var (headerInserted, headerUpdated) = await UpsertAdvanceOrderHeaderRowsAsync(headerEndpoint, headerRows, timeout.Value).ConfigureAwait(false);

                var lineRows = LoadAdvanceOrderLineRows(receiptNo);
                var (lineInserted, lineUpdated) = await UpsertAdvanceOrderLineRowsAsync(lineEndpoint, lineRows, timeout.Value).ConfigureAwait(false);

                string summary = $"{headerInserted + lineInserted} inserted, {headerUpdated + lineUpdated} updated";
                UpsertAdvanceOrderPortalSyncStatus(receiptNo, "SYNCED", summary);
                return summary;
            }
            catch (Exception ex)
            {
                try
                {
                    UpsertAdvanceOrderPortalSyncStatus(receiptNo, "SYNC_FAILED", ex.ToString());
                }
                catch { /* best-effort status write, never mask the original failure */ }
                throw;
            }
        }

        private static async Task<(int Inserted, int Updated)> UpsertAdvanceOrderHeaderRowsAsync(string headerEndpoint, List<(string TransactionNo, Dictionary<string, object?> Payload)> headerRows, TimeSpan timeout)
        {
            int inserted = 0;
            int updated = 0;

            foreach (var headerRow in headerRows)
            {
                string payloadJson = JsonSerializer.Serialize(headerRow.Payload);
                bool exists = await SupabaseRecordExistsAsync(headerEndpoint, timeout, ("TransactionNo", headerRow.TransactionNo)).ConfigureAwait(false);
                if (exists)
                {
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(headerEndpoint, ("TransactionNo", headerRow.TransactionNo)), payloadJson, timeout).ConfigureAwait(false);
                    updated++;
                }
                else
                {
                    await PostJsonWithHeadersAsync(headerEndpoint, payloadJson, timeout).ConfigureAwait(false);
                    inserted++;
                }
            }

            return (inserted, updated);
        }

        private static async Task<(int Inserted, int Updated)> UpsertAdvanceOrderLineRowsAsync(string lineEndpoint, List<(string TransactionNo, string LineNo, Dictionary<string, object?> Payload)> lineRows, TimeSpan timeout)
        {
            int inserted = 0;
            int updated = 0;

            foreach (var lineRow in lineRows)
            {
                string payloadJson = JsonSerializer.Serialize(lineRow.Payload);
                bool exists = await SupabaseRecordExistsAsync(lineEndpoint, timeout, ("TransactionNo", lineRow.TransactionNo), ("LineNo", lineRow.LineNo)).ConfigureAwait(false);
                if (exists)
                {
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(lineEndpoint, ("TransactionNo", lineRow.TransactionNo), ("LineNo", lineRow.LineNo)), payloadJson, timeout).ConfigureAwait(false);
                    updated++;
                }
                else
                {
                    await PostJsonWithHeadersAsync(lineEndpoint, payloadJson, timeout).ConfigureAwait(false);
                    inserted++;
                }
            }

            return (inserted, updated);
        }

        private static readonly string[] OptionalAdvanceOrderHeaderColumns = new[]
        {
            "StoreNo", "POSTerminalNo", "ReceiptNo", "Type", "Quantity", "Price", "Discount",
            "GrossAmount", "NetAmount", "Date", "Time", "UserID", "Downpayment", "Balance",
            "CustomerName", "Order_Description", "EODID",
            // OnlineOrderID: written by UpdateAdvanceOrderHeaderOnlineOrderId on every successful
            // Pancake sync. FullyPaid/DatePaid: written by MainForm's advance-order posting (paid in
            // full upfront) and AdvanceOrdersHeaderForm's PayInFullButton_Click (paid later) - see
            // sql_advance_order_paid_status.sql/supabase_advance_orders_paid_status_fields.sql. Safe
            // to list here unconditionally: the column-presence check below just omits them from the
            // payload on any install where that SQL hasn't been run yet.
            //
            // Warehouse is deliberately NOT here / not a local column at all - per "make sure the
            // warehouse is being sent too without logging it on local DB, I just want to see it on
            // the portal", it's looked up live from dbo.Warehouses and stitched into the payload at
            // sync time instead (see GetCurrentAdvanceOrderWarehouseName below).
            "OnlineOrderID", "FullyPaid", "DatePaid"
        };

        // "Current warehouse" for tagging Advance Orders in the Portal - deliberately not persisted
        // onto dbo.AdvanceOrderHeader (see OptionalAdvanceOrderHeaderColumns above); looked up fresh
        // every sync instead, same Current_Warehouse flag GetCurrentWarehouseIdAsync uses for the
        // Pancake sync, but returning the human-readable Name rather than the Pancake warehouse GUID
        // since that's what's actually useful to read/filter by in the Portal.
        private static string GetCurrentAdvanceOrderWarehouseName()
        {
            try
            {
                using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT TOP 1 Name FROM dbo.Warehouses WHERE Current_Warehouse = 1 ORDER BY [ID]", conn);
                return cmd.ExecuteScalar()?.ToString()?.Trim() ?? string.Empty;
            }
            catch
            {
                return string.Empty;
            }
        }

        // Stitches "Warehouse" into every row's payload right before it's sent, since it isn't a real
        // local column LoadAdvanceOrderHeaderRows could have picked up on its own. One lookup shared
        // across all rows in a batch (not one query per row) since it's the same "current warehouse"
        // for the whole sync run regardless of how many orders are in it.
        private static void ApplyCurrentWarehouseToHeaderRows(List<(string TransactionNo, Dictionary<string, object?> Payload)> headerRows)
        {
            if (headerRows.Count == 0)
                return;

            string warehouseName = GetCurrentAdvanceOrderWarehouseName();
            object? warehouseValue = string.IsNullOrWhiteSpace(warehouseName) ? null : warehouseName;
            foreach (var headerRow in headerRows)
            {
                headerRow.Payload["Warehouse"] = warehouseValue;
            }
        }

        // receiptNoFilter: when provided (and the ReceiptNo column exists), restricts the result to
        // just that one advance order - used by SyncSingleAdvanceOrderToSupabaseAsync so posting an
        // order doesn't have to push every advance order in the table to sync just the one that
        // changed. Null/omitted (the periodic bulk sync's usage) loads every row, as before.
        private static List<(string TransactionNo, Dictionary<string, object?> Payload)> LoadAdvanceOrderHeaderRows(string? receiptNoFilter = null)
        {
            var rows = new List<(string TransactionNo, Dictionary<string, object?> Payload)>();
            using var connection = new SqlConnection(GlobalSettings.ConnectionString);
            connection.Open();

            var columns = LoadTableColumnNames(connection, "AdvanceOrderHeader");
            if (!columns.Contains("TransactionNo"))
                return rows;

            var presentColumns = OptionalAdvanceOrderHeaderColumns.Where(c => columns.Contains(c)).ToList();
            string selectColumns = "[TransactionNo]" + (presentColumns.Count > 0 ? ", [" + string.Join("], [", presentColumns) + "]" : string.Empty);

            bool filterByReceipt = !string.IsNullOrWhiteSpace(receiptNoFilter) && columns.Contains("ReceiptNo");
            string sql = $"SELECT {selectColumns} FROM dbo.AdvanceOrderHeader" + (filterByReceipt ? " WHERE ReceiptNo = @ReceiptNo" : string.Empty);

            using var cmd = new SqlCommand(sql, connection);
            if (filterByReceipt)
                cmd.Parameters.AddWithValue("@ReceiptNo", receiptNoFilter!.Trim());
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string transactionNo = rdr["TransactionNo"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(transactionNo))
                    continue;

                var payload = new Dictionary<string, object?> { ["TransactionNo"] = transactionNo };
                foreach (var column in presentColumns)
                {
                    var value = rdr[column];
                    payload[SanitizeSupabaseColumnName(column)] = value == DBNull.Value ? null : ConvertSupabaseValue(value);
                }
                payload["SyncedAtUtc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture);

                rows.Add((transactionNo, payload));
            }

            return rows;
        }

        private static readonly string[] OptionalAdvanceOrderLineColumns = new[]
        {
            "StoreNo", "POSTerminalNo", "ReceiptNo", "Type", "No.", "Description", "Quantity",
            "Price", "Discount", "GrossAmount", "NetAmount", "Date", "Time", "EODID", "UserID",
            "VariationId"
        };

        // receiptNoFilter: see LoadAdvanceOrderHeaderRows above - same single-order filtering purpose.
        private static List<(string TransactionNo, string LineNo, Dictionary<string, object?> Payload)> LoadAdvanceOrderLineRows(string? receiptNoFilter = null)
        {
            var rows = new List<(string TransactionNo, string LineNo, Dictionary<string, object?> Payload)>();
            using var connection = new SqlConnection(GlobalSettings.ConnectionString);
            connection.Open();

            var columns = LoadTableColumnNames(connection, "AdvanceOrderLines");
            if (!columns.Contains("TransactionNo") || !columns.Contains("LineNo"))
                return rows;

            var presentColumns = OptionalAdvanceOrderLineColumns.Where(c => columns.Contains(c)).ToList();
            string selectColumns = "[TransactionNo], [LineNo]" + (presentColumns.Count > 0 ? ", [" + string.Join("], [", presentColumns) + "]" : string.Empty);

            bool filterByReceipt = !string.IsNullOrWhiteSpace(receiptNoFilter) && columns.Contains("ReceiptNo");
            string sql = $"SELECT {selectColumns} FROM dbo.AdvanceOrderLines" + (filterByReceipt ? " WHERE ReceiptNo = @ReceiptNo" : string.Empty);

            using var cmd = new SqlCommand(sql, connection);
            if (filterByReceipt)
                cmd.Parameters.AddWithValue("@ReceiptNo", receiptNoFilter!.Trim());
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string transactionNo = rdr["TransactionNo"]?.ToString()?.Trim() ?? string.Empty;
                string lineNo = rdr["LineNo"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(transactionNo) || string.IsNullOrWhiteSpace(lineNo))
                    continue;

                var payload = new Dictionary<string, object?> { ["TransactionNo"] = transactionNo, ["LineNo"] = lineNo };
                foreach (var column in presentColumns)
                {
                    var value = rdr[column];
                    payload[SanitizeSupabaseColumnName(column)] = value == DBNull.Value ? null : ConvertSupabaseValue(value);
                }
                payload["SyncedAtUtc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture);

                rows.Add((transactionNo, lineNo, payload));
            }

            return rows;
        }

        /// <summary>
        /// Returns the set of column names that exist on a local table, used to defensively build
        /// SELECT lists for tables whose schema has grown incrementally over time (ALTER TABLE ADD
        /// COLUMN IF NOT EXISTS-style migrations spread across the codebase).
        /// </summary>
        private static HashSet<string> LoadTableColumnNames(SqlConnection connection, string tableName)
        {
            var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using var colCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @TableName", connection);
            colCmd.Parameters.AddWithValue("@TableName", tableName);
            using var colRdr = colCmd.ExecuteReader();
            while (colRdr.Read())
            {
                string columnName = colRdr[0]?.ToString() ?? string.Empty;
                if (!string.IsNullOrWhiteSpace(columnName))
                    columns.Add(columnName);
            }
            return columns;
        }

        /// <summary>
        /// Supabase/Postgres column names can't contain spaces or dots, so square-bracketed local
        /// column names like "For Delivery" or "No." are converted to a safe identifier (spaces and
        /// dots removed) when building the JSON payload sent to Supabase.
        /// </summary>
        private static string SanitizeSupabaseColumnName(string columnName)
        {
            return columnName.Replace(" ", string.Empty).Replace(".", string.Empty);
        }

        private static object? ConvertSupabaseValue(object value)
        {
            switch (value)
            {
                case DateTime dt:
                    return dt.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture);
                case bool b:
                    return b;
                case decimal or double or float or int or long or short:
                    return value;
                default:
                    return value.ToString();
            }
        }

        /// <summary>
        /// Sends a posted Month End header and its lines to Supabase (MonthEndHeader/MonthEndLines
        /// endpoints), inserting new rows or patching existing ones (matched by DocumentNo, and
        /// DocumentNo+LineNo for lines) so re-running a sync after a partial failure is safe.
        /// </summary>
        public static async Task SyncMonthEndToSupabaseAsync(MonthEndHeader header, IReadOnlyList<MonthEndLine> lines, TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string headerEndpoint = GlobalSettings.MonthEndHeaderSupabaseEndpoint?.Trim() ?? string.Empty;
            string lineEndpoint = GlobalSettings.MonthEndLinesSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(headerEndpoint))
                throw new InvalidOperationException("MonthEndHeaderSupabaseEndpoint is not configured.");
            if (string.IsNullOrWhiteSpace(lineEndpoint))
                throw new InvalidOperationException("MonthEndLinesSupabaseEndpoint is not configured.");

            var headerPayload = new Dictionary<string, object?>
            {
                ["DocumentNo"] = header.DocumentNo,
                ["WorksheetDocumentNo"] = header.WorksheetDocumentNo,
                ["WorksheetGeneratedDate"] = header.WorksheetGeneratedDate == default ? null : header.WorksheetGeneratedDate.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture),
                ["FromDate"] = header.FromDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                ["ToDate"] = header.ToDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                ["WarehouseName"] = string.IsNullOrWhiteSpace(header.WarehouseName) ? null : header.WarehouseName,
                ["ItemVariantFilter"] = string.IsNullOrWhiteSpace(header.ItemVariantFilter) ? null : header.ItemVariantFilter,
                ["WorksheetGeneratedBy"] = string.IsNullOrWhiteSpace(header.WorksheetGeneratedBy) ? null : header.WorksheetGeneratedBy,
                ["PostedBy"] = string.IsNullOrWhiteSpace(header.PostedBy) ? null : header.PostedBy,
                ["PostedAtUtc"] = (header.PostedAtUtc == default ? DateTime.UtcNow : header.PostedAtUtc).ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture),
                ["TotalLines"] = header.TotalLines,
                ["CloudPatchedLines"] = header.CloudPatchedLines,
                ["CloudSkippedLines"] = header.CloudSkippedLines,
                ["CloudFailedLines"] = header.CloudFailedLines
            };

            string headerJson = JsonSerializer.Serialize(headerPayload);
            bool headerExists = await SupabaseRecordExistsAsync(headerEndpoint, timeout.Value, ("DocumentNo", header.DocumentNo)).ConfigureAwait(false);
            if (headerExists)
                await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(headerEndpoint, ("DocumentNo", header.DocumentNo)), headerJson, timeout.Value).ConfigureAwait(false);
            else
                await PostJsonWithHeadersAsync(headerEndpoint, headerJson, timeout.Value).ConfigureAwait(false);

            foreach (var line in lines)
            {
                var linePayload = new Dictionary<string, object?>
                {
                    ["DocumentNo"] = header.DocumentNo,
                    ["LineNo"] = line.LineNo,
                    ["ReportKey"] = string.IsNullOrWhiteSpace(line.ReportKey) ? null : line.ReportKey,
                    ["ItemNo"] = string.IsNullOrWhiteSpace(line.ItemNo) ? null : line.ItemNo,
                    ["Description"] = string.IsNullOrWhiteSpace(line.Description) ? null : line.Description,
                    ["QtyTransferred"] = line.QtyTransferred,
                    ["LocalSales"] = line.LocalSales,
                    ["OnlineSales"] = line.OnlineSales,
                    ["QtyOnHand"] = line.QtyOnHand,
                    ["PhysicalQtyOnHand"] = line.PhysicalQtyOnHand,
                    ["OpeningStock"] = line.OpeningStock,
                    ["Variance"] = line.Variance,
                    ["ShrinkagePercent"] = line.ShrinkagePercent,
                    ["VariationId"] = string.IsNullOrWhiteSpace(line.VariationId) ? null : line.VariationId,
                    ["CloudWarehouseId"] = string.IsNullOrWhiteSpace(line.CloudWarehouseId) ? null : line.CloudWarehouseId,
                    ["CloudPreviousQtyOnHand"] = line.CloudPreviousQtyOnHand,
                    ["CloudUpdatedQtyOnHand"] = line.CloudUpdatedQtyOnHand,
                    ["CloudPatchStatus"] = string.IsNullOrWhiteSpace(line.CloudPatchStatus) ? null : line.CloudPatchStatus,
                    ["CloudPatchMessage"] = string.IsNullOrWhiteSpace(line.CloudPatchMessage) ? null : line.CloudPatchMessage,
                    ["SentToOnline"] = line.SentToOnline,
                    ["LastErrorEndpoint"] = string.IsNullOrWhiteSpace(line.LastErrorEndpoint) ? null : line.LastErrorEndpoint,
                    ["LastErrorPayload"] = string.IsNullOrWhiteSpace(line.LastErrorPayload) ? null : line.LastErrorPayload,
                    ["LastErrorMessage"] = string.IsNullOrWhiteSpace(line.LastErrorMessage) ? null : line.LastErrorMessage,
                    ["ProductId"] = string.IsNullOrWhiteSpace(line.ProductId) ? null : line.ProductId
                };

                string lineJson = JsonSerializer.Serialize(linePayload);
                string lineNoText = line.LineNo.ToString(CultureInfo.InvariantCulture);
                bool lineExists = await SupabaseRecordExistsAsync(lineEndpoint, timeout.Value, ("DocumentNo", header.DocumentNo), ("LineNo", lineNoText)).ConfigureAwait(false);
                if (lineExists)
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(lineEndpoint, ("DocumentNo", header.DocumentNo), ("LineNo", lineNoText)), lineJson, timeout.Value).ConfigureAwait(false);
                else
                    await PostJsonWithHeadersAsync(lineEndpoint, lineJson, timeout.Value).ConfigureAwait(false);
            }
        }

        /// <summary>
        /// Sends a generated Expense Report (header + lines) to Supabase (ExpenseReportHeader/ExpenseReportLines
        /// endpoints), inserting new rows or patching existing ones (matched by DocumentNo, and
        /// DocumentNo+LineNo for lines) so re-running a sync after a partial failure is safe.
        /// </summary>
        internal static async Task SyncExpenseReportToSupabaseAsync(
            string documentNo,
            DateTime generatedDate,
            DateTime fromDate,
            DateTime toDate,
            string? warehouseName,
            string? generatedBy,
            IReadOnlyList<PostingEvents.ExpenseReportLine> lines,
            TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string headerEndpoint = GlobalSettings.ExpenseReportHeaderSupabaseEndpoint?.Trim() ?? string.Empty;
            string lineEndpoint = GlobalSettings.ExpenseReportLinesSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(headerEndpoint))
                throw new InvalidOperationException("ExpenseReportHeaderSupabaseEndpoint is not configured.");
            if (string.IsNullOrWhiteSpace(lineEndpoint))
                throw new InvalidOperationException("ExpenseReportLinesSupabaseEndpoint is not configured.");

            decimal grandTotal = lines.Sum(line => line.Amount);

            var headerPayload = new Dictionary<string, object?>
            {
                ["DocumentNo"] = documentNo,
                ["GeneratedDate"] = generatedDate.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture),
                ["FromDate"] = fromDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                ["ToDate"] = toDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                ["WarehouseName"] = string.IsNullOrWhiteSpace(warehouseName) ? null : warehouseName,
                ["GeneratedBy"] = string.IsNullOrWhiteSpace(generatedBy) ? null : generatedBy,
                ["TotalLines"] = lines.Count,
                ["GrandTotal"] = grandTotal
            };

            string headerJson = JsonSerializer.Serialize(headerPayload);
            bool headerExists = await SupabaseRecordExistsAsync(headerEndpoint, timeout.Value, ("DocumentNo", documentNo)).ConfigureAwait(false);
            if (headerExists)
                await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(headerEndpoint, ("DocumentNo", documentNo)), headerJson, timeout.Value).ConfigureAwait(false);
            else
                await PostJsonWithHeadersAsync(headerEndpoint, headerJson, timeout.Value).ConfigureAwait(false);

            int lineNo = 0;
            foreach (var line in lines)
            {
                lineNo++;
                DateTime? transactionDate = DateTime.TryParseExact(line.DateText, "MM/dd/yyyy", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsedDate)
                    ? parsedDate
                    : (DateTime?)null;

                var linePayload = new Dictionary<string, object?>
                {
                    ["DocumentNo"] = documentNo,
                    ["LineNo"] = lineNo,
                    ["Category"] = string.IsNullOrWhiteSpace(line.Category) ? null : line.Category,
                    ["Description"] = string.IsNullOrWhiteSpace(line.Description) ? null : line.Description,
                    ["UserId"] = string.IsNullOrWhiteSpace(line.UserId) ? null : line.UserId,
                    ["TransactionDate"] = transactionDate.HasValue ? transactionDate.Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : null,
                    ["TransactionTime"] = string.IsNullOrWhiteSpace(line.TimeText) ? null : line.TimeText,
                    ["Quantity"] = line.Quantity,
                    ["Amount"] = line.Amount
                };

                string lineJson = JsonSerializer.Serialize(linePayload);
                string lineNoText = lineNo.ToString(CultureInfo.InvariantCulture);
                bool lineExists = await SupabaseRecordExistsAsync(lineEndpoint, timeout.Value, ("DocumentNo", documentNo), ("LineNo", lineNoText)).ConfigureAwait(false);
                if (lineExists)
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(lineEndpoint, ("DocumentNo", documentNo), ("LineNo", lineNoText)), lineJson, timeout.Value).ConfigureAwait(false);
                else
                    await PostJsonWithHeadersAsync(lineEndpoint, lineJson, timeout.Value).ConfigureAwait(false);
            }
        }

        /// <summary>
        /// Sends a single just-posted Expense Entry to Supabase (ExpenseEntryHeader/ExpenseEntryLines
        /// endpoints - see supabase_expense_entry_tables.sql), inserting new rows or patching existing
        /// ones (matched by ReceiptNo, and ReceiptNo+LineID for lines) so re-calling this after a
        /// partial failure is safe. Distinct from SyncExpenseReportToSupabaseAsync above, which mirrors
        /// the aggregated, printed Expense Report instead of one individual posted entry.
        ///
        /// Reads straight from the two local tables MainForm.PostPendingExpenses just wrote to
        /// (rather than taking the posted data as parameters), so the Supabase copy always reflects
        /// exactly what was actually persisted locally:
        ///   Header <- dbo.TransactionHeader WHERE ReceiptNo = @receiptNo AND Type = 'EXPENSE'
        ///   Lines  <- dbo.ItemLedgerEntry WHERE DocumentNo = @receiptNo AND DocumentType = 'EXPENSE'
        ///     (ItemLedgerEntry.ID, a local IDENTITY column, becomes each line's LineID).
        ///
        /// warehouseName: the machine's current warehouse at POST time (caller passes
        /// TransferOrderData.GetCurrentWarehouse(...)?.Name - same source PostingEvents.
        /// PrintExpenseReport already uses for ExpenseReportHeader.WarehouseName), written to the
        /// header-level ExpenseEntryHeader.Warehouse column. Not resolved in here since this method
        /// only has a SqlConnection open against the local DB, not any UI/session context.
        /// </summary>
        public static async Task SyncExpenseEntryToSupabaseAsync(string receiptNo, string? warehouseName = null, TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            if (string.IsNullOrWhiteSpace(receiptNo))
                throw new ArgumentException("receiptNo is required.", nameof(receiptNo));

            string headerEndpoint = GlobalSettings.ExpenseEntryHeaderSupabaseEndpoint?.Trim() ?? string.Empty;
            string lineEndpoint = GlobalSettings.ExpenseEntryLinesSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(headerEndpoint))
                throw new InvalidOperationException("ExpenseEntryHeaderSupabaseEndpoint is not configured.");
            if (string.IsNullOrWhiteSpace(lineEndpoint))
                throw new InvalidOperationException("ExpenseEntryLinesSupabaseEndpoint is not configured.");

            string syncedAtUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture);
            Dictionary<string, object?>? headerPayload = null;
            var linePayloads = new List<(string LineId, Dictionary<string, object?> Payload)>();

            using (var connection = new SqlConnection(GlobalSettings.ConnectionString))
            {
                connection.Open();

                using (var headerCmd = new SqlCommand(@"
SELECT TOP 1 StoreNo, POSTerminalNo, TransactionNo, Quantity, Price, Discount, GrossAmount, NetAmount,
       [Date], [Time], UserID, Description, EODID, ExpenseCategory
FROM dbo.TransactionHeader
WHERE ReceiptNo = @ReceiptNo AND Type = 'EXPENSE'
ORDER BY TransactionNo DESC", connection))
                {
                    headerCmd.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                    using var rdr = headerCmd.ExecuteReader();
                    if (rdr.Read())
                    {
                        headerPayload = new Dictionary<string, object?>
                        {
                            ["ReceiptNo"] = receiptNo,
                            ["Type"] = "EXPENSE",
                            ["Warehouse"] = string.IsNullOrWhiteSpace(warehouseName) ? null : warehouseName,
                            ["StoreNo"] = rdr["StoreNo"] == DBNull.Value ? null : Convert.ToString(rdr["StoreNo"]),
                            ["POSTerminalNo"] = rdr["POSTerminalNo"] == DBNull.Value ? null : Convert.ToString(rdr["POSTerminalNo"]),
                            ["TransactionNo"] = rdr["TransactionNo"] == DBNull.Value ? null : Convert.ToString(rdr["TransactionNo"]),
                            ["Quantity"] = rdr["Quantity"] == DBNull.Value ? null : Convert.ToDecimal(rdr["Quantity"]),
                            ["Price"] = rdr["Price"] == DBNull.Value ? null : Convert.ToDecimal(rdr["Price"]),
                            ["Discount"] = rdr["Discount"] == DBNull.Value ? null : Convert.ToDecimal(rdr["Discount"]),
                            ["GrossAmount"] = rdr["GrossAmount"] == DBNull.Value ? null : Convert.ToDecimal(rdr["GrossAmount"]),
                            ["NetAmount"] = rdr["NetAmount"] == DBNull.Value ? null : Convert.ToDecimal(rdr["NetAmount"]),
                            ["Date"] = rdr["Date"] == DBNull.Value ? null : Convert.ToDateTime(rdr["Date"]).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                            ["Time"] = rdr["Time"] == DBNull.Value ? null : Convert.ToString(rdr["Time"]),
                            ["UserID"] = rdr["UserID"] == DBNull.Value ? null : Convert.ToString(rdr["UserID"]),
                            ["Description"] = rdr["Description"] == DBNull.Value ? null : Convert.ToString(rdr["Description"]),
                            ["EODID"] = rdr["EODID"] == DBNull.Value ? null : Convert.ToString(rdr["EODID"]),
                            ["ExpenseCategory"] = rdr["ExpenseCategory"] == DBNull.Value ? null : Convert.ToString(rdr["ExpenseCategory"]),
                            ["SyncedAtUtc"] = syncedAtUtc
                        };
                    }
                }

                if (headerPayload == null)
                    throw new InvalidOperationException($"No posted EXPENSE TransactionHeader row found for ReceiptNo '{receiptNo}'.");

                using (var lineCmd = new SqlCommand(@"
SELECT ID, EntryDate, ItemCode, VariationId, StoreNo, PosTerminalNo, Quantity, UnitCost, TotalCost, Price, Discount, GrossAmount, NetAmount, Description, UserID
FROM dbo.ItemLedgerEntry
WHERE DocumentNo = @ReceiptNo AND DocumentType = 'EXPENSE'
ORDER BY ID", connection))
                {
                    lineCmd.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                    using var rdr = lineCmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        string lineId = rdr["ID"] == DBNull.Value ? string.Empty : Convert.ToString(rdr["ID"]) ?? string.Empty;
                        if (string.IsNullOrWhiteSpace(lineId))
                            continue;

                        var linePayload = new Dictionary<string, object?>
                        {
                            ["ReceiptNo"] = receiptNo,
                            ["LineID"] = lineId,
                            ["EntryDate"] = rdr["EntryDate"] == DBNull.Value ? null : Convert.ToDateTime(rdr["EntryDate"]).ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture),
                            ["ItemCode"] = rdr["ItemCode"] == DBNull.Value ? null : Convert.ToString(rdr["ItemCode"]),
                            ["VariationId"] = rdr["VariationId"] == DBNull.Value ? null : Convert.ToString(rdr["VariationId"]),
                            ["StoreNo"] = rdr["StoreNo"] == DBNull.Value ? null : Convert.ToString(rdr["StoreNo"]),
                            ["POSTerminalNo"] = rdr["PosTerminalNo"] == DBNull.Value ? null : Convert.ToString(rdr["PosTerminalNo"]),
                            ["Quantity"] = rdr["Quantity"] == DBNull.Value ? null : Convert.ToDecimal(rdr["Quantity"]),
                            ["UnitCost"] = rdr["UnitCost"] == DBNull.Value ? null : Convert.ToDecimal(rdr["UnitCost"]),
                            ["TotalCost"] = rdr["TotalCost"] == DBNull.Value ? null : Convert.ToDecimal(rdr["TotalCost"]),
                            ["Price"] = rdr["Price"] == DBNull.Value ? null : Convert.ToDecimal(rdr["Price"]),
                            ["Discount"] = rdr["Discount"] == DBNull.Value ? null : Convert.ToDecimal(rdr["Discount"]),
                            ["GrossAmount"] = rdr["GrossAmount"] == DBNull.Value ? null : Convert.ToDecimal(rdr["GrossAmount"]),
                            ["NetAmount"] = rdr["NetAmount"] == DBNull.Value ? null : Convert.ToDecimal(rdr["NetAmount"]),
                            ["Description"] = rdr["Description"] == DBNull.Value ? null : Convert.ToString(rdr["Description"]),
                            ["UserID"] = rdr["UserID"] == DBNull.Value ? null : Convert.ToString(rdr["UserID"]),
                            ["SyncedAtUtc"] = syncedAtUtc
                        };

                        linePayloads.Add((lineId, linePayload));
                    }
                }
            }

            string headerJson = JsonSerializer.Serialize(headerPayload);
            bool headerExists = await SupabaseRecordExistsAsync(headerEndpoint, timeout.Value, ("ReceiptNo", receiptNo)).ConfigureAwait(false);
            if (headerExists)
                await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(headerEndpoint, ("ReceiptNo", receiptNo)), headerJson, timeout.Value).ConfigureAwait(false);
            else
                await PostJsonWithHeadersAsync(headerEndpoint, headerJson, timeout.Value).ConfigureAwait(false);

            foreach (var (lineId, payload) in linePayloads)
            {
                string lineJson = JsonSerializer.Serialize(payload);
                bool lineExists = await SupabaseRecordExistsAsync(lineEndpoint, timeout.Value, ("ReceiptNo", receiptNo), ("LineID", lineId)).ConfigureAwait(false);
                if (lineExists)
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(lineEndpoint, ("ReceiptNo", receiptNo), ("LineID", lineId)), lineJson, timeout.Value).ConfigureAwait(false);
                else
                    await PostJsonWithHeadersAsync(lineEndpoint, lineJson, timeout.Value).ConfigureAwait(false);
            }
        }

        /// <summary>
        /// Create an online purchase order from local stock-count adjustments.
        ///
        /// This reads ItemLedgerEntry rows for the given DocumentNo where
        /// DocumentType = 'POSITIVE_ADJ' and ISNULL(SentToOnline,0) = 0, attempts
        /// to map the local ItemCode to an upstream VariationId via the Items
        /// table, and posts the payload to the purchases endpoint.
        ///
        /// Returns the raw response body as string.
        /// </summary>
        public static string CreatePurchaseOnlineOrderFromStockCounts(string documentNo)
        {
            return CreatePurchaseOnlineOrderFromStockCountsAsync(documentNo).GetAwaiter().GetResult();
        }

        public static async Task<string> CreatePurchaseOnlineOrderFromStockCountsAsync(string documentNo, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                throw new ArgumentException("documentNo is required", nameof(documentNo));

            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            timeout ??= TimeSpan.FromSeconds(30);

            // Resolve warehouse for this shop (current warehouse).
            string warehouseId = await GetCurrentWarehouseIdAsync(shopId).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new InvalidOperationException("No current warehouse is selected.");

            // Load ItemLedgerEntry POSITIVE_ADJ rows for this specific document that have not been sent online yet.
            // ItemLedgerEntry.VariationId (when present) was already resolved correctly at Stock Count save time
            // via dbo.[Variant] (see StockCountsForm.cs LoadProducts/BtnSave_Click) - carry it through here so a
            // multi-variant item's real Pancake variation id isn't lost/guessed again below.
            var itemLines = new List<(string ItemCode, decimal Quantity, string VariationId)>();
            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();

                    bool ledgerHasVariationId;
                    using (var colCmd = new SqlCommand("SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'ItemLedgerEntry' AND COLUMN_NAME = 'VariationId'", conn))
                    {
                        ledgerHasVariationId = Convert.ToInt32(colCmd.ExecuteScalar()) > 0;
                    }

                    var sql = new StringBuilder();
                    sql.Append(ledgerHasVariationId
                        ? "SELECT ItemCode, Quantity, VariationId FROM ItemLedgerEntry WHERE ISNULL(SentToOnline,0) = 0 AND DocumentType = 'POSITIVE_ADJ' AND DocumentNo = @DocNo"
                        : "SELECT ItemCode, Quantity FROM ItemLedgerEntry WHERE ISNULL(SentToOnline,0) = 0 AND DocumentType = 'POSITIVE_ADJ' AND DocumentNo = @DocNo");

                    using (var cmd = new SqlCommand(sql.ToString(), conn))
                    {
                        cmd.Parameters.AddWithValue("@DocNo", documentNo);

                        using (var rdr = cmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                string lineItemCode = string.Empty;
                                try { lineItemCode = rdr["ItemCode"]?.ToString() ?? string.Empty; } catch { lineItemCode = string.Empty; }

                                decimal qty = 0m;
                                try
                                {
                                    var qv = rdr["Quantity"];
                                    if (qv != null && qv != DBNull.Value)
                                        decimal.TryParse(qv.ToString(), out qty);
                                }
                                catch { qty = 0m; }

                                string lineVariationId = string.Empty;
                                if (ledgerHasVariationId)
                                {
                                    try { lineVariationId = rdr["VariationId"]?.ToString() ?? string.Empty; } catch { lineVariationId = string.Empty; }
                                }

                                itemLines.Add((lineItemCode, qty, lineVariationId));
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException("Failed to read POSITIVE_ADJ ItemLedgerEntry rows: " + ex.Message, ex);
            }

            try { System.Diagnostics.Trace.TraceInformation($"Loaded {itemLines.Count} POSITIVE_ADJ line(s) for DocumentNo '{documentNo}'."); } catch { }

            // Build items array for the payload using mapped variation ids.
            var itemsList = new List<object>();
            int index = 0;

            if (itemLines.Count > 0)
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();

                    // Multi-variant items (see StockCountsForm.LoadProducts) store their real Pancake
                    // variation id on dbo.[Variant], not dbo.Items - Items.VariationId is often blank or
                    // holds a different/default variation for those items. Check for it first, same
                    // priority order LoadProducts and FinancePurchasePayroll's ResolveCloudVariationId use.
                    bool hasVariantTable;
                    using (var existsCmd = new SqlCommand("SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Variant'", conn))
                    {
                        hasVariantTable = Convert.ToInt32(existsCmd.ExecuteScalar()) > 0;
                    }

                    string ResolveVariantTableVariationId(string itemCode)
                    {
                        if (!hasVariantTable || string.IsNullOrWhiteSpace(itemCode)) return string.Empty;
                        try
                        {
                            using (var vcmd = new SqlCommand(
                                "SELECT TOP 1 VariationId FROM dbo.[Variant] WHERE ItemCode = @code OR (ISNULL(ItemCode,'') = '' AND MainItemCode = @code)", conn))
                            {
                                vcmd.Parameters.AddWithValue("@code", itemCode);
                                var ov = vcmd.ExecuteScalar();
                                return (ov != null && ov != DBNull.Value) ? (ov.ToString() ?? string.Empty) : string.Empty;
                            }
                        }
                        catch { return string.Empty; }
                    }

                    // Discover Items table columns so we can:
                    //  - detect the correct variation-id column
                    //  - detect all usable item-code columns for matching
                    var availableCols = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    try
                    {
                        using (var colCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Items'", conn))
                        using (var rdrCols = colCmd.ExecuteReader())
                        {
                            while (rdrCols.Read())
                            {
                                var cn = rdrCols[0]?.ToString();
                                if (!string.IsNullOrEmpty(cn)) availableCols.Add(cn);
                            }
                        }
                    }
                    catch { }

                    string PickColumn(params string[] candidates)
                    {
                        foreach (var c in candidates)
                            if (availableCols.Contains(c)) return c;
                        return string.Empty;
                    }

                    // variation id column (try common variants; fall back to any column containing 'Variation')
                    string variationColumn = PickColumn("VariationId", "VariantId", "variation_id");
                    if (string.IsNullOrEmpty(variationColumn))
                    {
                        try
                        {
                            using (var colCmd = new SqlCommand("SELECT TOP 1 COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Items' AND UPPER(COLUMN_NAME) LIKE '%VARIATION%'", conn))
                            {
                                var cv = colCmd.ExecuteScalar();
                                if (cv != null && cv != DBNull.Value)
                                {
                                    var name = cv.ToString();
                                    if (!string.IsNullOrWhiteSpace(name)) variationColumn = name;
                                }
                            }
                        }
                        catch { }
                    }

                    // candidate item code columns, mirroring LoadProducts: ItemCode, Code, Item_No, No, SKU
                    var codeColumns = new System.Collections.Generic.List<string>();
                    foreach (var cc in new[] { "ItemCode", "Code", "Item_No", "No", "SKU" })
                    {
                        if (availableCols.Contains(cc)) codeColumns.Add(cc);
                    }

                    foreach (var line in itemLines)
                    {
                        if (string.IsNullOrWhiteSpace(line.ItemCode))
                            continue;

                        var qtyValue = Math.Abs(line.Quantity);
                        if (qtyValue == 0m) qtyValue = 1m;

                        // Prefer the VariationId already captured on the ledger row at Stock Count save
                        // time (resolved via dbo.[Variant] then - see StockCountsForm.cs BtnSave_Click).
                        // Only re-resolve here for older rows saved before that column existed.
                        string variationId = line.VariationId ?? string.Empty;

                        if (string.IsNullOrWhiteSpace(variationId))
                        {
                            variationId = ResolveVariantTableVariationId(line.ItemCode);
                        }

                        if (string.IsNullOrWhiteSpace(variationId))
                        {
                            // Last resort: Items table, mirroring LoadProducts' own fallback when no
                            // Variant row exists for this item at all.
                            try
                            {
                                if (!string.IsNullOrEmpty(variationColumn) && codeColumns.Count > 0)
                                {
                                    var whereParts = codeColumns.Select(c => c + " = @code").ToArray();
                                    var sqlVar = $"SELECT TOP 1 {variationColumn} FROM Items WHERE " + string.Join(" OR ", whereParts);
                                    using (var vcmd = new SqlCommand(sqlVar, conn))
                                    {
                                        vcmd.Parameters.AddWithValue("@code", line.ItemCode);
                                        var ov = vcmd.ExecuteScalar();
                                        if (ov != null && ov != DBNull.Value) variationId = ov.ToString() ?? string.Empty;
                                    }
                                }
                            }
                            catch { variationId = string.Empty; }
                        }

                        try { System.Diagnostics.Trace.TraceInformation($"ItemCode='{line.ItemCode}' -> VariationId='{variationId}', Qty={line.Quantity}"); } catch { }

                        if (string.IsNullOrWhiteSpace(variationId))
                            continue;

                        itemsList.Add(new
                        {
                            quantity = qtyValue,
                            variation_id = variationId,
                            index = index++
                        });
                    }
                }
            }

            if (itemsList.Count == 0)
                throw new InvalidOperationException("No POSITIVE_ADJ ItemLedgerEntry rows with mappable VariationId found for DocumentNo='" + documentNo + "'.");

            // Call the upstream purchases endpoint.
            string path = $"shops/{Uri.EscapeDataString(shopId)}/purchases";

            var payload = new
            {
                purchase = new
                {
                    note = string.IsNullOrWhiteSpace(documentNo) ? "" : documentNo,
                    status = 1,
                    not_create_transaction = true,
                    auto_create_debts = true,
                    shop_id = shopId,
                    warehouse_id = warehouseId,
                    change_received_at = true,
                    items = itemsList.ToArray()
                }
            };

            string bodyJson = JsonSerializer.Serialize(payload);

            try
            {
                try { System.Diagnostics.Trace.TraceInformation($"Posting {itemsList.Count} item(s) to purchases for DocumentNo '{documentNo}'"); } catch { }
                var respText = await PurchaseApiCallAsync(path, HttpMethod.Post, bodyJson, timeout).ConfigureAwait(false);
                try { System.Diagnostics.Trace.TraceInformation($"Purchase API response for '{documentNo}': {respText}"); } catch { }

                // Mark matching ItemLedgerEntry rows as sent to online (best-effort)
                try
                {
                    using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        conn.Open();
                        using (var cmd = new SqlCommand("UPDATE ItemLedgerEntry SET SentToOnline = 1 WHERE DocumentType = 'POSITIVE_ADJ' AND DocumentNo = @DocNo", conn))
                        {
                            cmd.Parameters.AddWithValue("@DocNo", documentNo);
                            cmd.ExecuteNonQuery();
                        }
                    }
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"CreatePurchaseOnlineOrderFromStockCounts: Failed to mark SentToOnline for '{documentNo}': {ex.Message}");
                    try { MessageBox.Show($"Warning: failed to mark SentToOnline for '{documentNo}': {ex.Message}", "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
                }

                return respText ?? string.Empty;
            }
            catch (Exception ex)
            {
                try { MessageBox.Show($"CreatePurchaseOnlineOrderFromStockCounts failed for '{documentNo}': {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
                throw;
            }
        }

        public static string SendStockJournalAdjustmentsOnline(string documentNo)
        {
            return SendStockJournalAdjustmentsOnlineAsync(documentNo).GetAwaiter().GetResult();
        }

        public static async Task<string> SendStockJournalAdjustmentsOnlineAsync(string documentNo, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                throw new ArgumentException("documentNo is required", nameof(documentNo));

            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopId))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            timeout ??= TimeSpan.FromSeconds(30);

            var unsentLines = new List<(string ItemCode, string VariationId, decimal Quantity)>();
            var resolvedVariationByItemCode = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                await conn.OpenAsync().ConfigureAwait(false);

                using (var cmd = new SqlCommand(@"
SELECT ItemCode, VariationId, Quantity
FROM ItemLedgerEntry
WHERE ISNULL(SentToOnline,0) = 0
  AND DocumentType = 'STOCK_ADJ'
  AND DocumentNo = @DocNo", conn))
                {
                    cmd.Parameters.AddWithValue("@DocNo", documentNo);

                    using (var rdr = await cmd.ExecuteReaderAsync().ConfigureAwait(false))
                    {
                        while (await rdr.ReadAsync().ConfigureAwait(false))
                        {
                            string itemCode = string.Empty;
                            string variationId = string.Empty;
                            decimal quantity = 0m;

                            try { itemCode = rdr["ItemCode"]?.ToString() ?? string.Empty; } catch { itemCode = string.Empty; }
                            try { variationId = rdr["VariationId"]?.ToString() ?? string.Empty; } catch { variationId = string.Empty; }
                            try
                            {
                                var qv = rdr["Quantity"];
                                if (qv != null && qv != DBNull.Value)
                                    decimal.TryParse(qv.ToString(), out quantity);
                            }
                            catch { quantity = 0m; }

                            if (quantity == 0m)
                                continue;

                            unsentLines.Add((itemCode.Trim(), variationId.Trim(), quantity));
                        }
                    }
                }

                if (unsentLines.Count == 0)
                    throw new InvalidOperationException($"No unsent STOCK_ADJ ItemLedgerEntry rows found for DocumentNo='{documentNo}'.");

                using (var resolveCmd = new SqlCommand("SELECT TOP 1 VariationId FROM Items WHERE Code = @Code", conn))
                {
                    resolveCmd.Parameters.Add("@Code", System.Data.SqlDbType.NVarChar, 100);

                    for (int i = 0; i < unsentLines.Count; i++)
                    {
                        var line = unsentLines[i];
                        if (!string.IsNullOrWhiteSpace(line.VariationId))
                            continue;

                        if (string.IsNullOrWhiteSpace(line.ItemCode))
                            continue;

                        if (!resolvedVariationByItemCode.TryGetValue(line.ItemCode, out var resolvedVariationId))
                        {
                            resolveCmd.Parameters["@Code"].Value = line.ItemCode;
                            var scalar = await resolveCmd.ExecuteScalarAsync().ConfigureAwait(false);
                            resolvedVariationId = scalar?.ToString()?.Trim() ?? string.Empty;
                            resolvedVariationByItemCode[line.ItemCode] = resolvedVariationId;
                        }

                        unsentLines[i] = (line.ItemCode, resolvedVariationId, line.Quantity);
                    }
                }
            }

            string warehouseId = await GetCurrentWarehouseIdAsync(shopId).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new InvalidOperationException("No current warehouse is selected.");

            var positiveItems = new List<object>();
            var negativeQtyByVariation = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
            int positiveIndex = 0;

            foreach (var line in unsentLines)
            {
                if (string.IsNullOrWhiteSpace(line.VariationId))
                    continue;

                if (line.Quantity > 0)
                {
                    positiveItems.Add(new
                    {
                        quantity = Math.Abs(line.Quantity),
                        variation_id = line.VariationId,
                        index = positiveIndex++
                    });
                }
                else if (line.Quantity < 0)
                {
                    var qty = Math.Abs(line.Quantity);
                    if (negativeQtyByVariation.TryGetValue(line.VariationId, out var existing))
                        negativeQtyByVariation[line.VariationId] = existing + qty;
                    else
                        negativeQtyByVariation[line.VariationId] = qty;
                }
            }

            if (positiveItems.Count == 0 && negativeQtyByVariation.Count == 0)
                throw new InvalidOperationException($"No mappable VariationId values found for STOCK_ADJ DocumentNo='{documentNo}'.");

            var responseMessages = new List<string>();

            if (positiveItems.Count > 0)
            {
                string path = $"shops/{Uri.EscapeDataString(shopId)}/purchases";
                var payload = new
                {
                    purchase = new
                    {
                        note = documentNo,
                        status = 1,
                        not_create_transaction = true,
                        auto_create_debts = true,
                        shop_id = shopId,
                        warehouse_id = warehouseId,
                        change_received_at = true,
                        items = positiveItems.ToArray()
                    }
                };

                string bodyJson = JsonSerializer.Serialize(payload);
                var purchaseResponse = await PurchaseApiCallAsync(path, HttpMethod.Post, bodyJson, timeout).ConfigureAwait(false);
                responseMessages.Add($"purchase:{purchaseResponse}");
            }

            foreach (var kv in negativeQtyByVariation)
            {
                await DeductCloudInventoryAsync(shopId, kv.Key, kv.Value, timeout).ConfigureAwait(false);
                responseMessages.Add($"deduct:{kv.Key}:{kv.Value}");
            }

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                await conn.OpenAsync().ConfigureAwait(false);
                using (var cmd = new SqlCommand("UPDATE ItemLedgerEntry SET SentToOnline = 1 WHERE DocumentType = 'STOCK_ADJ' AND DocumentNo = @DocNo", conn))
                {
                    cmd.Parameters.AddWithValue("@DocNo", documentNo);
                    await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
                }
            }

            return string.Join(Environment.NewLine, responseMessages);
        }

        /// <summary>
        /// Sends ItemLedgerEntry rows where SentToOnline = 0 to the online system.
        ///
        /// For each distinct DocumentNo in ItemLedgerEntry with ISNULL(SentToOnline,0)=0,
        /// this calls CreateInstoreOnlineOrder(DocumentNo) and, on success, marks all
        /// matching ItemLedgerEntry rows as SentToOnline = 1. Returns the number of
        /// successfully sent distinct documents.
        /// </summary>
        public static int SendItemLedgerEntryToOnline()
        {
            int successes = 0;
            try
            {
                // using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                // {
                //     conn.Open();
                //     using (var cmd = new SqlCommand("SELECT DISTINCT DocumentNo FROM ItemLedgerEntry WHERE ISNULL(SentToOnline,0) = 0", conn))

                // }
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException("Failed to enumerate unsent ItemLedgerEntry rows: " + ex.Message, ex);
            }

            return successes;
        }

        /// <summary>
        /// SendCreateInstoreOnlineOrder for all local TransactionHeader rows where SentToOnline = 0.
        /// Returns the number of successfully sent transactions.
        /// </summary>
        public static int SendFailedTransactionToCloud()
        {
            int successes = 0;
            try
            {
                using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    conn.Open();
                    using (var cmd = new SqlCommand("SELECT ReceiptNo FROM TransactionHeader WHERE ISNULL(SentToOnline,0) = 0", conn))
                    using (var rdr = cmd.ExecuteReader())
                    {
                        var receipts = new System.Collections.Generic.List<string>();
                        while (rdr.Read())
                        {
                            try
                            {
                                var r = rdr[0]?.ToString() ?? string.Empty;
                                if (!string.IsNullOrWhiteSpace(r)) receipts.Add(r);
                            }
                            catch { }
                        }

                        foreach (var receipt in receipts)
                        {
                            try
                            {
                                // Reuse existing CreateInstoreOnlineOrder which marks SentToOnline on success
                                var resp = CreateInstoreOnlineOrder(receipt);
                                System.Diagnostics.Debug.WriteLine($"SendFailedTransactionToCloud: Sent receipt {receipt}. Response: {resp}");
                                successes++;
                            }
                            catch (Exception ex)
                            {
                                System.Diagnostics.Debug.WriteLine($"SendFailedTransactionToCloud: Failed to send receipt {receipt}: {ex.Message}");
                                // continue with next
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException("Failed to enumerate unsent transactions: " + ex.Message, ex);
            }

            return successes;
        }

        private static async Task<string> GetCurrentWarehouseIdAsync(string shopId)
        {
            // Uses the local Warehouses table. Expect a bit column Current_Location and an ID column.
            // We prefer dbo.Warehouses but fall back to Warehouses if schema is not dbo.
            string[] candidates = { "dbo.Warehouses", "Warehouses" };
            Exception? lastEx = null;

            foreach (var tableName in candidates)
            {
                try
                {
                    using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
                    {
                        await conn.OpenAsync().ConfigureAwait(false);

                        // Verify required columns exist
                        string? schema = null;
                        string tname = tableName;
                        if (tableName.Contains("."))
                        {
                            var parts = tableName.Split(new[] { '.' }, 2);
                            schema = parts[0];
                            tname = parts[1];
                        }

                        bool hasCurrentLocation = false;
                        bool hasCurrentWarehouse = false;
                        bool hasId = false;
                        string shopCol = string.Empty;
                        using (var colCmd = new SqlCommand(@"SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND (TABLE_SCHEMA=@s OR @s IS NULL)", conn))
                        {
                            colCmd.Parameters.AddWithValue("@t", tname);
                            colCmd.Parameters.AddWithValue("@s", (object?)schema ?? DBNull.Value);
                            using (var rdr = await colCmd.ExecuteReaderAsync().ConfigureAwait(false))
                            {
                                while (await rdr.ReadAsync().ConfigureAwait(false))
                                {
                                    var c = rdr[0]?.ToString() ?? string.Empty;
                                    if (c.Equals("Current_Location", StringComparison.OrdinalIgnoreCase)) hasCurrentLocation = true;
                                    if (c.Equals("Current_Warehouse", StringComparison.OrdinalIgnoreCase)) hasCurrentWarehouse = true;
                                    if (c.Equals("ID", StringComparison.OrdinalIgnoreCase)) hasId = true;
                                    if (c.Equals("ShopID", StringComparison.OrdinalIgnoreCase)) shopCol = "ShopID";
                                    else if (string.IsNullOrEmpty(shopCol) && c.Equals("ShopId", StringComparison.OrdinalIgnoreCase)) shopCol = "ShopId";
                                }
                            }
                        }

                        var currentFlagColumn = hasCurrentLocation ? "Current_Location" : (hasCurrentWarehouse ? "Current_Warehouse" : string.Empty);
                        if (string.IsNullOrWhiteSpace(currentFlagColumn) || !hasId)
                            continue;

                        bool hasShop = !string.IsNullOrWhiteSpace(shopCol);
                        string sql = hasShop
                            ? $"SELECT TOP 1 [ID] FROM {tableName} WHERE ([{currentFlagColumn}] = 1) AND ([{shopCol}] = @ShopId) ORDER BY [ID]"
                            : $"SELECT TOP 1 [ID] FROM {tableName} WHERE ([{currentFlagColumn}] = 1) ORDER BY [ID]";

                        using (var cmd = new SqlCommand(sql, conn))
                        {
                            if (hasShop)
                                cmd.Parameters.AddWithValue("@ShopId", shopId);
                            var result = await cmd.ExecuteScalarAsync().ConfigureAwait(false);
                            var id = result?.ToString() ?? string.Empty;
                            if (!string.IsNullOrWhiteSpace(id))
                                return id.Trim();
                        }
                    }
                }
                catch (Exception ex)
                {
                    lastEx = ex;
                }
            }

            throw new InvalidOperationException("No current warehouse is selected. Open Warehouse Setup and tick Current_Warehouse for the desired warehouse.", lastEx);
        }

        /// <summary>
        /// Deduct inventory for a specific online product variation.
        /// 
        /// Parameters:
        /// - ShopID: upstream shop identifier
        /// - VariationID: upstream variation identifier
        /// - QtytoDeduct: quantity to deduct (must be &gt; 0)
        /// 
        /// Note: The exact endpoint/path depends on the upstream API. This method uses the configured
        /// GlobalSettings.OnlineOrdersApiBaseUrl and OnlineOrdersApiKey and posts a JSON body.
        /// </summary>
        public static bool DeductCloudInventory(string ShopID, string VariationID, decimal QtytoDeduct)
        {
            return DeductCloudInventoryAsync(ShopID, VariationID, QtytoDeduct).GetAwaiter().GetResult();
        }

        public static decimal? GetCloudVariationAvailableQuantity(string variationId, TimeSpan? timeout = null)
        {
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopId) || string.IsNullOrWhiteSpace(variationId))
                return null;

            return GetCloudVariationAvailableQuantityAsync(shopId, variationId, timeout).GetAwaiter().GetResult();
        }

        public static decimal? GetCloudVariationAvailableQuantityForWarehouse(string variationId, string warehouseId, TimeSpan? timeout = null)
        {
            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopId) || string.IsNullOrWhiteSpace(variationId) || string.IsNullOrWhiteSpace(warehouseId))
                return null;

            return GetCloudVariationAvailableQuantityForWarehouseAsync(shopId, variationId, warehouseId, timeout).GetAwaiter().GetResult();
        }

        public static async Task<decimal?> GetCloudVariationAvailableQuantityAsync(string shopId, string variationId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(shopId) || string.IsNullOrWhiteSpace(variationId))
                return null;

            timeout ??= TimeSpan.FromSeconds(15);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl) || string.IsNullOrWhiteSpace(apiKey))
                return null;

            string warehouseId;
            try
            {
                warehouseId = await GetCurrentWarehouseIdAsync(shopId).ConfigureAwait(false);
            }
            catch
            {
                return null;
            }

            return await GetCloudVariationAvailableQuantityForWarehouseAsync(shopId, variationId, warehouseId, timeout).ConfigureAwait(false);
        }

        public static async Task<decimal?> GetCloudVariationAvailableQuantityForWarehouseAsync(string shopId, string variationId, string warehouseId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(shopId) || string.IsNullOrWhiteSpace(variationId) || string.IsNullOrWhiteSpace(warehouseId))
                return null;

            if (string.IsNullOrWhiteSpace(warehouseId))
                return null;

            timeout ??= TimeSpan.FromSeconds(15);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl) || string.IsNullOrWhiteSpace(apiKey))
                return null;

            string endpoint = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/variations/{Uri.EscapeDataString(variationId)}?api_key={Uri.EscapeDataString(apiKey)}";

            static decimal? GetDecimal(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.Number && v.TryGetDecimal(out var d)) return d;
                            if (v.ValueKind == JsonValueKind.String)
                            {
                                var s = v.GetString();
                                if (!string.IsNullOrWhiteSpace(s) && decimal.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var dd))
                                    return dd;
                                if (!string.IsNullOrWhiteSpace(s) && decimal.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out dd))
                                    return dd;
                            }
                        }
                    }
                    catch { }
                }

                return null;
            }

            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
                            if (v.ValueKind == JsonValueKind.Number) return v.ToString();
                            if (v.ValueKind == JsonValueKind.True) return "true";
                            if (v.ValueKind == JsonValueKind.False) return "false";
                            if (v.ValueKind == JsonValueKind.Null) return string.Empty;
                            return v.ToString();
                        }
                    }
                    catch { }
                }

                return string.Empty;
            }

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            try
            {
                using var readReq = new HttpRequestMessage(HttpMethod.Post, endpoint);
                NotifyHttpRequestDebug(HttpMethod.Post.Method, endpoint, string.Empty);
                using var postResp = await http.SendAsync(readReq).ConfigureAwait(false);

                HttpResponseMessage respToParse = postResp;
                if (!postResp.IsSuccessStatusCode && ((int)postResp.StatusCode == 404 || (int)postResp.StatusCode == 405))
                {
                    NotifyHttpRequestDebug(HttpMethod.Get.Method, endpoint, string.Empty);
                    var getResp = await http.GetAsync(endpoint).ConfigureAwait(false);
                    if (getResp.IsSuccessStatusCode)
                        respToParse = getResp;
                }

                if (!respToParse.IsSuccessStatusCode)
                    return null;

                var json = await respToParse.Content.ReadAsStringAsync().ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(json))
                    return null;

                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                JsonElement vw = default;
                bool found = false;
                if (root.ValueKind == JsonValueKind.Object)
                {
                    if (root.TryGetProperty("variations_warehouses", out vw) && vw.ValueKind == JsonValueKind.Array) found = true;
                    else if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object && data.TryGetProperty("variations_warehouses", out vw) && vw.ValueKind == JsonValueKind.Array) found = true;
                    else if (root.TryGetProperty("variation", out var variation) && variation.ValueKind == JsonValueKind.Object && variation.TryGetProperty("variations_warehouses", out vw) && vw.ValueKind == JsonValueKind.Array) found = true;
                }

                if (!found)
                    return null;

                foreach (var item in vw.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object)
                        continue;

                    var wid = GetString(item, "warehouse_id", "warehouseId", "id", "ID").Trim();
                    if (!string.Equals(wid, warehouseId, StringComparison.OrdinalIgnoreCase))
                        continue;

                    return GetDecimal(item, "remain_quantity", "remainQuantity", "quantity", "qty");
                }
            }
            catch
            {
            }

            return null;
        }

        public sealed class CloudVariationDetails
        {
            public string ProductId { get; init; } = string.Empty;
            public decimal? RemainQuantity { get; init; }
        }

        public static async Task<CloudVariationDetails> GetCloudVariationDetailsForWarehouseAsync(string shopId, string variationId, string warehouseId, TimeSpan? timeout = null)
        {
            var empty = new CloudVariationDetails();

            if (string.IsNullOrWhiteSpace(shopId) || string.IsNullOrWhiteSpace(variationId) || string.IsNullOrWhiteSpace(warehouseId))
                return empty;

            timeout ??= TimeSpan.FromSeconds(15);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl) || string.IsNullOrWhiteSpace(apiKey))
                return empty;

            string endpoint = BuildCloudVariationDetailsEndpoint(shopId, variationId);

            static decimal? GetDecimal(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.Number && v.TryGetDecimal(out var d)) return d;
                            if (v.ValueKind == JsonValueKind.String)
                            {
                                var s = v.GetString();
                                if (!string.IsNullOrWhiteSpace(s) && decimal.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var dd))
                                    return dd;
                                if (!string.IsNullOrWhiteSpace(s) && decimal.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out dd))
                                    return dd;
                            }
                        }
                    }
                    catch { }
                }

                return null;
            }

            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
                            if (v.ValueKind == JsonValueKind.Number) return v.ToString();
                            if (v.ValueKind == JsonValueKind.True) return "true";
                            if (v.ValueKind == JsonValueKind.False) return "false";
                            if (v.ValueKind == JsonValueKind.Null) return string.Empty;
                            return v.ToString();
                        }
                    }
                    catch { }
                }

                return string.Empty;
            }

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            try
            {
                using var readReq = new HttpRequestMessage(HttpMethod.Post, endpoint);
                using var postResp = await http.SendAsync(readReq).ConfigureAwait(false);

                HttpResponseMessage respToParse = postResp;
                if (!postResp.IsSuccessStatusCode && ((int)postResp.StatusCode == 404 || (int)postResp.StatusCode == 405))
                {
                    var getResp = await http.GetAsync(endpoint).ConfigureAwait(false);
                    if (getResp.IsSuccessStatusCode)
                        respToParse = getResp;
                }

                if (!respToParse.IsSuccessStatusCode)
                    return empty;

                var json = await respToParse.Content.ReadAsStringAsync().ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(json))
                    return empty;

                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                JsonElement container = root;
                if (root.ValueKind == JsonValueKind.Object)
                {
                    if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object)
                        container = data;
                    else if (root.TryGetProperty("variation", out var variation) && variation.ValueKind == JsonValueKind.Object)
                        container = variation;
                }

                string productId = GetString(container, "product_id", "productId", "ProductId");
                decimal? remainQuantity = null;

                if (container.ValueKind == JsonValueKind.Object && container.TryGetProperty("variations_warehouses", out var vw) && vw.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in vw.EnumerateArray())
                    {
                        if (item.ValueKind != JsonValueKind.Object)
                            continue;

                        var wid = GetString(item, "warehouse_id", "warehouseId", "id", "ID").Trim();
                        if (!string.Equals(wid, warehouseId, StringComparison.OrdinalIgnoreCase))
                            continue;

                        remainQuantity = GetDecimal(item, "remain_quantity", "remainQuantity", "quantity", "qty");
                        break;
                    }
                }

                return new CloudVariationDetails { ProductId = productId, RemainQuantity = remainQuantity };
            }
            catch
            {
                return empty;
            }
        }

        public sealed class StocktakingItem
        {
            public string ProductId { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public decimal ActualQuantity { get; init; }
        }

        public sealed class StocktakingRequestException : Exception
        {
            public string Endpoint { get; }
            public string PayloadJson { get; }

            public StocktakingRequestException(string message, string endpoint, string payloadJson, Exception? innerException = null)
                : base(message, innerException)
            {
                Endpoint = endpoint ?? string.Empty;
                PayloadJson = payloadJson ?? string.Empty;
            }
        }

        public sealed class StocktakingRequestPreview
        {
            public string LookupEndpoint { get; init; } = string.Empty;
            public string Endpoint { get; init; } = string.Empty;
            public string PayloadJson { get; init; } = string.Empty;
            public string ProductId { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public string ErrorMessage { get; init; } = string.Empty;
        }

        public static string BuildCloudVariationDetailsEndpoint(string shopId, string variationId)
        {
            if (string.IsNullOrWhiteSpace(shopId))
                throw new ArgumentException("ShopId is required", nameof(shopId));
            if (string.IsNullOrWhiteSpace(variationId))
                throw new ArgumentException("VariationId is required", nameof(variationId));

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            return $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/variations/{Uri.EscapeDataString(variationId)}?api_key={Uri.EscapeDataString(apiKey)}";
        }

        public sealed class UpdateQuantityRequestException : Exception
        {
            public string Endpoint { get; }
            public string PayloadJson { get; }

            public UpdateQuantityRequestException(string message, string endpoint, string payloadJson, Exception? innerException = null)
                : base(message, innerException)
            {
                Endpoint = endpoint ?? string.Empty;
                PayloadJson = payloadJson ?? string.Empty;
            }
        }

        public sealed class UpdateQuantityRequestPreview
        {
            public string LookupEndpoint { get; init; } = string.Empty;
            public string Endpoint { get; init; } = string.Empty;
            public string PayloadJson { get; init; } = string.Empty;
            public string ProductId { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public string WarehouseId { get; init; } = string.Empty;
            public string ErrorMessage { get; init; } = string.Empty;
        }

        public static UpdateQuantityRequestPreview BuildUpdateQuantityPreview(string shopId, string variationId, string warehouseId, decimal actualQuantity)
        {
            if (string.IsNullOrWhiteSpace(shopId))
                throw new ArgumentException("ShopId is required", nameof(shopId));
            if (string.IsNullOrWhiteSpace(variationId))
                throw new ArgumentException("VariationId is required", nameof(variationId));
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new ArgumentException("WarehouseId is required", nameof(warehouseId));

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string endpoint = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/variations/{Uri.EscapeDataString(variationId)}/update_quantity?api_key={Uri.EscapeDataString(apiKey)}";

            decimal remainQuantity = actualQuantity < 0m ? 0m : actualQuantity;
            var payload = new
            {
                variations_warehouses = new object[]
                {
                    new
                    {
                        remain_quantity = remainQuantity,
                        warehouse_id = warehouseId
                    }
                }
            };

            return new UpdateQuantityRequestPreview
            {
                Endpoint = endpoint,
                PayloadJson = JsonSerializer.Serialize(payload),
                VariationId = variationId,
                WarehouseId = warehouseId
            };
        }

        public static void PostUpdateQuantity(string shopId, string variationId, string warehouseId, decimal actualQuantity, TimeSpan? timeout = null)
        {
            PostUpdateQuantityAsync(shopId, variationId, warehouseId, actualQuantity, timeout).GetAwaiter().GetResult();
        }

        public static async Task PostUpdateQuantityAsync(string shopId, string variationId, string warehouseId, decimal actualQuantity, TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);
            var preview = BuildUpdateQuantityPreview(shopId, variationId, warehouseId, actualQuantity);
            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string endpoint = preview.Endpoint;
            string bodyJson = preview.PayloadJson;

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            async Task<HttpResponseMessage> SendAsync(HttpMethod method)
            {
                var req = new HttpRequestMessage(method, endpoint)
                {
                    Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
                };
                NotifyHttpRequestDebug(method.Method, endpoint, bodyJson);
                return await http.SendAsync(req).ConfigureAwait(false);
            }

            try
            {
                using var postResp = await SendAsync(HttpMethod.Post).ConfigureAwait(false);
                if (postResp.IsSuccessStatusCode)
                    return;

                if ((int)postResp.StatusCode == 404 || (int)postResp.StatusCode == 405)
                {
                    using var putResp = await SendAsync(HttpMethod.Put).ConfigureAwait(false);
                    if (putResp.IsSuccessStatusCode)
                        return;

                    if ((int)putResp.StatusCode == 404 || (int)putResp.StatusCode == 405)
                    {
                        using var patchResp = await SendAsync(new HttpMethod("PATCH")).ConfigureAwait(false);
                        if (patchResp.IsSuccessStatusCode)
                            return;

                        var patchText = string.Empty;
                        try { patchText = await patchResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                        throw new UpdateQuantityRequestException($"Quantity update failed ({(int)patchResp.StatusCode} {patchResp.ReasonPhrase}). {patchText}", endpoint, bodyJson);
                    }

                    var putText = string.Empty;
                    try { putText = await putResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                    throw new UpdateQuantityRequestException($"Quantity update failed ({(int)putResp.StatusCode} {putResp.ReasonPhrase}). {putText}", endpoint, bodyJson);
                }

                var responseText = string.Empty;
                try { responseText = await postResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                throw new UpdateQuantityRequestException($"Quantity update failed ({(int)postResp.StatusCode} {postResp.ReasonPhrase}). {responseText}", endpoint, bodyJson);
            }
            catch (UpdateQuantityRequestException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new UpdateQuantityRequestException($"Quantity update request failed: {ex.Message}", endpoint, bodyJson, ex);
            }
        }

        public sealed class MonthEndAdjustmentRequestException : Exception
        {
            public string Endpoint { get; }
            public string PayloadJson { get; }

            public MonthEndAdjustmentRequestException(string message, string endpoint, string payloadJson, Exception? innerException = null)
                : base(message, innerException)
            {
                Endpoint = endpoint ?? string.Empty;
                PayloadJson = payloadJson ?? string.Empty;
            }
        }

        public sealed class MonthEndAdjustmentRequestPreview
        {
            public string Endpoint { get; init; } = string.Empty;
            public string PayloadJson { get; init; } = string.Empty;
            public string VariationId { get; init; } = string.Empty;
            public string WarehouseId { get; init; } = string.Empty;
            public decimal Quantity { get; init; }
            /// <summary>"DEFECT" (export/write-off), "PURCHASE" (stock-in), or "NONE" (no adjustment needed).</summary>
            public string ActionType { get; init; } = string.Empty;
            public string ErrorMessage { get; init; } = string.Empty;
        }

        /// <summary>
        /// Builds a request to write off (defect) inventory via the export endpoint:
        ///   {BaseUrl}/shops/{ShopId}/export?api_key={ApiKey}
        /// Used when Qty on Hand (system) is greater than the counted Physical Qty on Hand.
        /// </summary>
        public static MonthEndAdjustmentRequestPreview BuildDefectAdjustmentPreview(string shopId, string warehouseId, string variationId, decimal quantity, string note, decimal importedPrice = 0m)
        {
            if (string.IsNullOrWhiteSpace(shopId))
                throw new ArgumentException("ShopId is required", nameof(shopId));
            if (string.IsNullOrWhiteSpace(variationId))
                throw new ArgumentException("VariationId is required", nameof(variationId));
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new ArgumentException("WarehouseId is required", nameof(warehouseId));

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string endpoint = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/export?api_key={Uri.EscapeDataString(apiKey)}";

            decimal exportQuantity = quantity < 0m ? 0m : quantity;
            var payload = new
            {
                export_list = new
                {
                    note = note ?? string.Empty,
                    tags = new[] { 1 },
                    status = 1,
                    type = 0,
                    warehouse_id = warehouseId,
                    export_items = new object[]
                    {
                        new
                        {
                            imported_price = importedPrice,
                            quantity = exportQuantity,
                            variation_id = variationId
                        }
                    }
                }
            };

            return new MonthEndAdjustmentRequestPreview
            {
                Endpoint = endpoint,
                PayloadJson = JsonSerializer.Serialize(payload),
                VariationId = variationId,
                WarehouseId = warehouseId,
                Quantity = exportQuantity,
                ActionType = "DEFECT"
            };
        }

        /// <summary>
        /// Builds a request to add stock via the purchase endpoint:
        ///   {BaseUrl}/shops/{ShopId}/purchases?api_key={ApiKey}
        /// Used when the counted Physical Qty on Hand is greater than Qty on Hand (system).
        /// </summary>
        public static MonthEndAdjustmentRequestPreview BuildPurchaseAdjustmentPreview(string shopId, string warehouseId, string variationId, decimal quantity, string note)
        {
            if (string.IsNullOrWhiteSpace(shopId))
                throw new ArgumentException("ShopId is required", nameof(shopId));
            if (string.IsNullOrWhiteSpace(variationId))
                throw new ArgumentException("VariationId is required", nameof(variationId));
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new ArgumentException("WarehouseId is required", nameof(warehouseId));

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string endpoint = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/purchases?api_key={Uri.EscapeDataString(apiKey)}";

            decimal purchaseQuantity = quantity < 0m ? 0m : quantity;
            var payload = new
            {
                purchase = new
                {
                    note = note ?? string.Empty,
                    status = 1,
                    not_create_transaction = true,
                    auto_create_debts = true,
                    shop_id = shopId,
                    warehouse_id = warehouseId,
                    change_received_at = true,
                    items = new object[]
                    {
                        new
                        {
                            quantity = purchaseQuantity,
                            variation_id = variationId,
                            index = 0
                        }
                    }
                }
            };

            return new MonthEndAdjustmentRequestPreview
            {
                Endpoint = endpoint,
                PayloadJson = JsonSerializer.Serialize(payload),
                VariationId = variationId,
                WarehouseId = warehouseId,
                Quantity = purchaseQuantity,
                ActionType = "PURCHASE"
            };
        }

        public static void PostMonthEndAdjustment(MonthEndAdjustmentRequestPreview preview, TimeSpan? timeout = null)
        {
            PostMonthEndAdjustmentAsync(preview, timeout).GetAwaiter().GetResult();
        }

        public static async Task PostMonthEndAdjustmentAsync(MonthEndAdjustmentRequestPreview preview, TimeSpan? timeout = null)
        {
            if (preview == null)
                throw new ArgumentNullException(nameof(preview));

            timeout ??= TimeSpan.FromSeconds(30);
            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string endpoint = preview.Endpoint;
            string bodyJson = preview.PayloadJson;

            try
            {
                using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };
                using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
                {
                    Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
                };

                NotifyHttpRequestDebug(HttpMethod.Post.Method, endpoint, bodyJson);

                using var response = await http.SendAsync(request).ConfigureAwait(false);
                if (response.IsSuccessStatusCode)
                    return;

                var responseText = string.Empty;
                try { responseText = await response.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                throw new MonthEndAdjustmentRequestException(
                    $"{preview.ActionType} adjustment failed ({(int)response.StatusCode} {response.ReasonPhrase}). {responseText}",
                    endpoint,
                    bodyJson);
            }
            catch (MonthEndAdjustmentRequestException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new MonthEndAdjustmentRequestException($"{preview.ActionType} adjustment request failed: {ex.Message}", endpoint, bodyJson, ex);
            }
        }

        public static void PostStocktakingAdjustment(string shopId, string warehouseId, string remarks, IReadOnlyList<StocktakingItem> items, TimeSpan? timeout = null)
        {
            PostStocktakingAdjustmentAsync(shopId, warehouseId, remarks, items, timeout).GetAwaiter().GetResult();
        }

        public static StocktakingRequestPreview BuildStocktakingAdjustmentPreview(string shopId, string warehouseId, string remarks, IReadOnlyList<StocktakingItem> items)
        {
            if (string.IsNullOrWhiteSpace(shopId))
                throw new ArgumentException("ShopId is required", nameof(shopId));
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new ArgumentException("WarehouseId is required", nameof(warehouseId));
            if (items == null || items.Count == 0)
                throw new ArgumentException("At least one stocktaking item is required.", nameof(items));

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string endpoint = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/stocktaking?api_key={Uri.EscapeDataString(apiKey)}";

            static object IdOrString(string value)
            {
                if (long.TryParse(value, out var idNumber))
                    return idNumber;
                return value;
            }

            var payload = new
            {
                warehouse_id = IdOrString(warehouseId),
                remarks = remarks ?? string.Empty,
                items = items.Select(item => new
                {
                    product_id = IdOrString(item.ProductId),
                    variation_id = IdOrString(item.VariationId),
                    actual_quantity = item.ActualQuantity
                }).ToArray()
            };

            return new StocktakingRequestPreview
            {
                Endpoint = endpoint,
                PayloadJson = JsonSerializer.Serialize(payload)
            };
        }

        public static async Task PostStocktakingAdjustmentAsync(string shopId, string warehouseId, string remarks, IReadOnlyList<StocktakingItem> items, TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(60);
            var preview = BuildStocktakingAdjustmentPreview(shopId, warehouseId, remarks, items);
            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string endpoint = preview.Endpoint;
            string bodyJson = preview.PayloadJson;

            try
            {
                using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };
                using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
                {
                    Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
                };

                using var response = await http.SendAsync(request).ConfigureAwait(false);
                if (response.IsSuccessStatusCode)
                    return;

                var responseText = string.Empty;
                try { responseText = await response.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                throw new StocktakingRequestException(
                    $"Stocktaking adjustment failed ({(int)response.StatusCode} {response.ReasonPhrase}). {responseText}",
                    endpoint,
                    bodyJson);
            }
            catch (StocktakingRequestException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new StocktakingRequestException($"Stocktaking adjustment request failed: {ex.Message}", endpoint, bodyJson, ex);
            }
        }

        public static Dictionary<string, decimal> GetCloudRemainingQuantitiesByReportKey(IEnumerable<string> reportKeys, TimeSpan? timeout = null)
        {
            return GetCloudRemainingQuantitiesByReportKeyAsync(reportKeys, timeout).GetAwaiter().GetResult();
        }

        public static async Task<Dictionary<string, decimal>> GetCloudRemainingQuantitiesByReportKeyAsync(IEnumerable<string> reportKeys, TimeSpan? timeout = null)
        {
            var result = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
            if (reportKeys == null)
                return result;

            var normalizedKeys = reportKeys
                .Where(key => !string.IsNullOrWhiteSpace(key))
                .Select(key => key.Trim())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

            if (normalizedKeys.Count == 0)
                return result;

            string shopId = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopId))
                return result;

            string warehouseId;
            try
            {
                warehouseId = await GetCurrentWarehouseIdAsync(shopId).ConfigureAwait(false);
            }
            catch
            {
                return result;
            }

            var variationKeys = normalizedKeys
                .Where(key => key.StartsWith("VAR:", StringComparison.OrdinalIgnoreCase))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

            if (variationKeys.Count == 0)
                return result;

            timeout ??= TimeSpan.FromSeconds(30);

            const int maxConcurrentRequests = 8;
            var syncRoot = new object();
            using var semaphore = new SemaphoreSlim(maxConcurrentRequests, maxConcurrentRequests);
            var fetchTasks = variationKeys.Select(async reportKey =>
            {
                string variationId = reportKey.Substring(4).Trim();
                if (string.IsNullOrWhiteSpace(variationId))
                    return;

                await semaphore.WaitAsync().ConfigureAwait(false);
                try
                {
                    decimal? remainQuantity = await GetCloudVariationAvailableQuantityForWarehouseAsync(shopId, variationId, warehouseId, timeout).ConfigureAwait(false);
                    if (!remainQuantity.HasValue)
                        return;

                    lock (syncRoot)
                    {
                        result[reportKey] = remainQuantity.Value;
                    }
                }
                catch
                {
                }
                finally
                {
                    semaphore.Release();
                }
            }).ToList();

            await Task.WhenAll(fetchTasks).ConfigureAwait(false);

            return result;
        }

        public static async Task<bool> DeductCloudInventoryAsync(string ShopID, string VariationID, decimal QtytoDeduct, TimeSpan? timeout = null)
        {

            if (string.IsNullOrWhiteSpace(ShopID))
                throw new ArgumentException("ShopID is required", nameof(ShopID));
            if (string.IsNullOrWhiteSpace(VariationID))
                throw new ArgumentException("VariationID is required", nameof(VariationID));
            if (QtytoDeduct <= 0)
                return true;

            timeout ??= TimeSpan.FromSeconds(30);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string warehouseId = await GetCurrentWarehouseIdAsync(ShopID).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(warehouseId))
                throw new InvalidOperationException("No current warehouse is selected.");

            string endpoint = $"{baseUrl}/shops/{Uri.EscapeDataString(ShopID)}/variations/{Uri.EscapeDataString(VariationID)}/update_quantity?api_key={Uri.EscapeDataString(apiKey)}";

            static decimal? GetDecimal(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.Number && v.TryGetDecimal(out var d)) return d;
                            if (v.ValueKind == JsonValueKind.String)
                            {
                                var s = v.GetString();
                                if (!string.IsNullOrWhiteSpace(s) && decimal.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var dd))
                                    return dd;
                                if (!string.IsNullOrWhiteSpace(s) && decimal.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out dd))
                                    return dd;
                            }
                        }
                    }
                    catch { }
                }
                return null;
            }

            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
                            if (v.ValueKind == JsonValueKind.Number) return v.ToString();
                            if (v.ValueKind == JsonValueKind.True) return "true";
                            if (v.ValueKind == JsonValueKind.False) return "false";
                            if (v.ValueKind == JsonValueKind.Null) return string.Empty;
                            return v.ToString();
                        }
                    }
                    catch { }
                }
                return string.Empty;
            }

            // 1) Read current remain_quantity from the cloud for the current warehouse (best-effort)
            decimal currentRemain = 0m;
            using (var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value })
            {
                try
                {
                    // Upstream API expects POST on this endpoint.
                    using var readReq = new HttpRequestMessage(HttpMethod.Post, endpoint);
                    using var getResp = await http.SendAsync(readReq).ConfigureAwait(false);

                    // Fallback to GET if POST isn't allowed.
                    HttpResponseMessage? respToParse = getResp;
                    if (!getResp.IsSuccessStatusCode && ((int)getResp.StatusCode == 404 || (int)getResp.StatusCode == 405))
                    {
                        try
                        {
                            var getFallback = await http.GetAsync(endpoint).ConfigureAwait(false);
                            if (getFallback.IsSuccessStatusCode)
                                respToParse = getFallback;
                        }
                        catch { }
                    }

                    if (respToParse.IsSuccessStatusCode)
                    {
                        var json = await respToParse.Content.ReadAsStringAsync().ConfigureAwait(false);
                        if (!string.IsNullOrWhiteSpace(json))
                        {
                            using var doc = JsonDocument.Parse(json);
                            var root = doc.RootElement;

                            // Try to find variations_warehouses on root, data, or variation.
                            JsonElement vw = default;
                            bool found = false;
                            if (root.ValueKind == JsonValueKind.Object)
                            {
                                if (root.TryGetProperty("variations_warehouses", out vw) && vw.ValueKind == JsonValueKind.Array) found = true;
                                else if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object && data.TryGetProperty("variations_warehouses", out vw) && vw.ValueKind == JsonValueKind.Array) found = true;
                                else if (root.TryGetProperty("variation", out var variation) && variation.ValueKind == JsonValueKind.Object && variation.TryGetProperty("variations_warehouses", out vw) && vw.ValueKind == JsonValueKind.Array) found = true;
                            }

                            if (found)
                            {
                                foreach (var item in vw.EnumerateArray())
                                {
                                    if (item.ValueKind != JsonValueKind.Object) continue;
                                    var wid = GetString(item, "warehouse_id", "warehouseId", "id", "ID").Trim();
                                    if (string.Equals(wid, warehouseId, StringComparison.OrdinalIgnoreCase))
                                    {
                                        var rq = GetDecimal(item, "remain_quantity", "remainQuantity", "quantity", "qty");
                                        if (rq.HasValue) currentRemain = rq.Value;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
                catch
                {
                    // Best-effort GET. If it fails, we'll still try to update using the computed remain quantity from 0.
                }

                // 2) Compute the new remaining quantity and update the cloud
                //MessageBox.Show($"Current remain_quantity for VariationID '{VariationID}' in WarehouseID '{warehouseId}' is {currentRemain}. Deducting {QtytoDeduct}.", "Cloud Inventory", MessageBoxButtons.OK, MessageBoxIcon.Information);
                decimal newRemain = currentRemain - QtytoDeduct;
                if (newRemain < 0m) newRemain = 0m;

                var payload = new
                {
                    variations_warehouses = new object[]
                    {
                        new
                        {
                            remain_quantity = newRemain,
                            warehouse_id = warehouseId
                        }
                    }
                };

                var bodyJson = JsonSerializer.Serialize(payload);

                async Task<HttpResponseMessage> SendAsync(HttpMethod method)
                {
                    var req = new HttpRequestMessage(method, endpoint)
                    {
                        Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
                    };
                    return await http.SendAsync(req).ConfigureAwait(false);
                }

                // 3) Update the cloud using POST + variations_warehouses body.
                using var postResp = await SendAsync(HttpMethod.Post).ConfigureAwait(false);
                if (postResp.IsSuccessStatusCode)
                    return true;

                // Some APIs use PATCH for partial updates.
                if ((int)postResp.StatusCode == 404 || (int)postResp.StatusCode == 405)
                {
                    // Fallback to PUT
                    using var putResp = await SendAsync(HttpMethod.Put).ConfigureAwait(false);
                    if (putResp.IsSuccessStatusCode)
                        return true;

                    // Fallback to PATCH
                    if ((int)putResp.StatusCode == 404 || (int)putResp.StatusCode == 405)
                    {
                        using var patchResp = await SendAsync(new HttpMethod("PATCH")).ConfigureAwait(false);
                        if (patchResp.IsSuccessStatusCode)
                            return true;

                        var patchText = string.Empty;
                        try { patchText = await patchResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                        throw new HttpRequestException($"Cloud inventory update failed ({(int)patchResp.StatusCode} {patchResp.ReasonPhrase}). {patchText}");
                    }

                    var putText = string.Empty;
                    try { putText = await putResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                    throw new HttpRequestException($"Cloud inventory update failed ({(int)putResp.StatusCode} {putResp.ReasonPhrase}). {putText}");
                }

                var responseText = string.Empty;
                try { responseText = await postResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                throw new HttpRequestException($"Cloud inventory update failed ({(int)postResp.StatusCode} {postResp.ReasonPhrase}). {responseText}");
            }
        }

        public static bool SetCloudInventoryForWarehouse(string ShopID, string VariationID, string WarehouseID, decimal newRemainQuantity, TimeSpan? timeout = null)
        {
            return SetCloudInventoryForWarehouseAsync(ShopID, VariationID, WarehouseID, newRemainQuantity, timeout).GetAwaiter().GetResult();
        }

        public static async Task<bool> SetCloudInventoryForWarehouseAsync(string ShopID, string VariationID, string WarehouseID, decimal newRemainQuantity, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(ShopID))
                throw new ArgumentException("ShopID is required", nameof(ShopID));
            if (string.IsNullOrWhiteSpace(VariationID))
                throw new ArgumentException("VariationID is required", nameof(VariationID));
            if (string.IsNullOrWhiteSpace(WarehouseID))
                throw new ArgumentException("WarehouseID is required", nameof(WarehouseID));

            if (newRemainQuantity < 0m)
                newRemainQuantity = 0m;

            timeout ??= TimeSpan.FromSeconds(30);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string endpoint = $"{baseUrl}/shops/{Uri.EscapeDataString(ShopID)}/variations/{Uri.EscapeDataString(VariationID)}/update_quantity?api_key={Uri.EscapeDataString(apiKey)}";

            var payload = new
            {
                variations_warehouses = new object[]
                {
                    new
                    {
                        remain_quantity = newRemainQuantity,
                        warehouse_id = WarehouseID
                    }
                }
            };

            string bodyJson = JsonSerializer.Serialize(payload);

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            async Task<HttpResponseMessage> SendAsync(HttpMethod method)
            {
                var req = new HttpRequestMessage(method, endpoint)
                {
                    Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
                };
                return await http.SendAsync(req).ConfigureAwait(false);
            }

            using var postResp = await SendAsync(HttpMethod.Post).ConfigureAwait(false);
            if (postResp.IsSuccessStatusCode)
                return true;

            if ((int)postResp.StatusCode == 404 || (int)postResp.StatusCode == 405)
            {
                using var putResp = await SendAsync(HttpMethod.Put).ConfigureAwait(false);
                if (putResp.IsSuccessStatusCode)
                    return true;

                if ((int)putResp.StatusCode == 404 || (int)putResp.StatusCode == 405)
                {
                    using var patchResp = await SendAsync(new HttpMethod("PATCH")).ConfigureAwait(false);
                    if (patchResp.IsSuccessStatusCode)
                        return true;

                    var patchText = string.Empty;
                    try { patchText = await patchResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                    throw new HttpRequestException($"Cloud inventory set failed ({(int)patchResp.StatusCode} {patchResp.ReasonPhrase}). {patchText}");
                }

                var putText = string.Empty;
                try { putText = await putResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                throw new HttpRequestException($"Cloud inventory set failed ({(int)putResp.StatusCode} {putResp.ReasonPhrase}). {putText}");
            }

            var postText = string.Empty;
            try { postText = await postResp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
            throw new HttpRequestException($"Cloud inventory set failed ({(int)postResp.StatusCode} {postResp.ReasonPhrase}). {postText}");
        }




        /// <summary>
        /// Sync warehouses for a given shop from the upstream API endpoint:
        /// {BaseURL}/shops/{ShopId}/warehouses?api_key={ApiKey}
        ///
        /// Mapping:
        /// - ID = id
        /// - Name = name
        /// - Address = full_address
        /// - Phone_Number = phone_number
        ///
        /// Warehouses are upserted into dbo.Warehouses.
        /// </summary>
        public static int SyncWarehouse()
        {
            return SyncWarehouseAsync().GetAwaiter().GetResult();
        }

        public static async Task<int> SyncWarehouseAsync(TimeSpan? timeout = null)
        {
            string shopIdFromSettings = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopIdFromSettings))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            return await SyncWarehouseAsync(shopIdFromSettings, timeout).ConfigureAwait(false);
        }

        public static int SyncWarehouse(string ShopId)
        {
            return SyncWarehouseAsync(ShopId).GetAwaiter().GetResult();
        }

        public static async Task<int> SyncWarehouseAsync(string ShopId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(ShopId))
                throw new ArgumentException("ShopId is required", nameof(ShopId));

            timeout ??= TimeSpan.FromSeconds(30);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string reqPath = $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/warehouses?api_key={Uri.EscapeDataString(apiKey)}";

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };
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
                else if (root.TryGetProperty("warehouses", out var whProp) && whProp.ValueKind == JsonValueKind.Array)
                {
                    itemsElement = whProp;
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
                return 0;

            string GetString(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
                            if (v.ValueKind == JsonValueKind.Number) return v.ToString();
                            if (v.ValueKind == JsonValueKind.True) return "true";
                            if (v.ValueKind == JsonValueKind.False) return "false";
                            if (v.ValueKind == JsonValueKind.Null) return string.Empty;
                            return v.ToString();
                        }
                    }
                    catch { }
                }
                return string.Empty;
            }

            var warehouses = new List<(string Id, string Name, string Address, string Phone)>();
            foreach (var item in itemsElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;

                var id = GetString(item, "id", "ID", "warehouse_id", "warehouseId");
                if (string.IsNullOrWhiteSpace(id)) continue;

                var name = GetString(item, "name", "Name");
                var address = GetString(item, "full_address", "fullAddress", "address", "Address");
                var phone = GetString(item, "phone_number", "phoneNumber", "phone", "Phone_Number", "Phone");

                warehouses.Add((id.Trim(), name?.Trim() ?? string.Empty, address?.Trim() ?? string.Empty, phone?.Trim() ?? string.Empty));
            }

            if (warehouses.Count == 0)
                return 0;

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                await conn.OpenAsync().ConfigureAwait(false);

                // Use existing dbo.Warehouses table (do not create/alter schema here).
                int tableExists = 0;
                using (var existsCmd = new SqlCommand("SELECT CASE WHEN OBJECT_ID('dbo.Warehouses','U') IS NULL THEN 0 ELSE 1 END", conn))
                {
                    var scalar = await existsCmd.ExecuteScalarAsync().ConfigureAwait(false);
                    try { tableExists = Convert.ToInt32(scalar); } catch { tableExists = 0; }
                }
                if (tableExists == 0)
                    throw new InvalidOperationException("dbo.Warehouses table does not exist. Please create it first.");

                var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                using (var colCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='dbo' AND TABLE_NAME='Warehouses'", conn))
                using (var rdr = await colCmd.ExecuteReaderAsync().ConfigureAwait(false))
                {
                    while (await rdr.ReadAsync().ConfigureAwait(false))
                    {
                        try
                        {
                            var c = rdr[0]?.ToString();
                            if (!string.IsNullOrWhiteSpace(c)) columns.Add(c);
                        }
                        catch { }
                    }
                }

                string idColumn = columns.Contains("ID") ? "ID"
                    : columns.Contains("WarehouseID") ? "WarehouseID"
                    : columns.Contains("WarehouseId") ? "WarehouseId"
                    : columns.Contains("warehouse_id") ? "warehouse_id"
                    : string.Empty;
                if (string.IsNullOrWhiteSpace(idColumn))
                    throw new InvalidOperationException("dbo.Warehouses must contain an ID column (expected 'ID').");

                bool hasShopIdColumn = columns.Contains("ShopID") || columns.Contains("ShopId");
                string shopIdColumn = columns.Contains("ShopID") ? "ShopID" : (columns.Contains("ShopId") ? "ShopId" : "ShopID");

                string nameColumn = columns.Contains("Name") ? "Name" : (columns.Contains("WarehouseName") ? "WarehouseName" : string.Empty);
                string addressColumn = columns.Contains("Address") ? "Address" : (columns.Contains("Full_Address") ? "Full_Address" : (columns.Contains("FullAddress") ? "FullAddress" : string.Empty));
                string phoneColumn = columns.Contains("Phone_Number") ? "Phone_Number" : (columns.Contains("PhoneNumber") ? "PhoneNumber" : (columns.Contains("Phone") ? "Phone" : string.Empty));
                string lastSyncedColumn = columns.Contains("LastSyncedUtc") ? "LastSyncedUtc" : (columns.Contains("LastSynced") ? "LastSynced" : string.Empty);

                var insertColumns = new List<string>();
                var insertValues = new List<string>();
                var updateSets = new List<string>();

                // Keys
                if (hasShopIdColumn)
                {
                    insertColumns.Add($"[{shopIdColumn}]");
                    insertValues.Add("@ShopID");
                }
                insertColumns.Add($"[{idColumn}]");
                insertValues.Add("@ID");

                // Optional mapped fields
                if (!string.IsNullOrWhiteSpace(nameColumn))
                {
                    insertColumns.Add($"[{nameColumn}]");
                    insertValues.Add("@Name");
                    updateSets.Add($"[{nameColumn}] = @Name");
                }
                if (!string.IsNullOrWhiteSpace(addressColumn))
                {
                    insertColumns.Add($"[{addressColumn}]");
                    insertValues.Add("@Address");
                    updateSets.Add($"[{addressColumn}] = @Address");
                }
                if (!string.IsNullOrWhiteSpace(phoneColumn))
                {
                    insertColumns.Add($"[{phoneColumn}]");
                    insertValues.Add("@Phone_Number");
                    updateSets.Add($"[{phoneColumn}] = @Phone_Number");
                }
                if (!string.IsNullOrWhiteSpace(lastSyncedColumn))
                {
                    insertColumns.Add($"[{lastSyncedColumn}]");
                    insertValues.Add("SYSUTCDATETIME()");
                    updateSets.Add($"[{lastSyncedColumn}] = SYSUTCDATETIME()");
                }

                using (var tx = conn.BeginTransaction())
                {
                    string onClause = hasShopIdColumn
                        ? $"(target.[{shopIdColumn}] = source.[{shopIdColumn}] AND target.[{idColumn}] = source.[{idColumn}])"
                        : $"(target.[{idColumn}] = source.[{idColumn}])";

                    string sourceSelect = hasShopIdColumn
                        ? $"SELECT @ShopID AS [{shopIdColumn}], @ID AS [{idColumn}]"
                        : $"SELECT @ID AS [{idColumn}]";

                    string updateClause = updateSets.Count > 0 ? ("UPDATE SET " + string.Join(", ", updateSets)) : "UPDATE SET " + $"[{idColumn}] = target.[{idColumn}]";
                    string insertClause = $"INSERT (" + string.Join(", ", insertColumns) + ") VALUES (" + string.Join(", ", insertValues) + ")";

                    string upsertSql = $@"
MERGE dbo.Warehouses AS target
USING ({sourceSelect}) AS source
ON {onClause}
WHEN MATCHED THEN
    {updateClause}
WHEN NOT MATCHED THEN
    {insertClause};";

                    using (var cmd = new SqlCommand(upsertSql, conn, tx))
                    {
                        if (hasShopIdColumn)
                            cmd.Parameters.Add(new SqlParameter("@ShopID", System.Data.SqlDbType.NVarChar, 100));
                        cmd.Parameters.Add(new SqlParameter("@ID", System.Data.SqlDbType.NVarChar, 100));
                        if (!string.IsNullOrWhiteSpace(nameColumn))
                            cmd.Parameters.Add(new SqlParameter("@Name", System.Data.SqlDbType.NVarChar, 255));
                        if (!string.IsNullOrWhiteSpace(addressColumn))
                            cmd.Parameters.Add(new SqlParameter("@Address", System.Data.SqlDbType.NVarChar, 500));
                        if (!string.IsNullOrWhiteSpace(phoneColumn))
                            cmd.Parameters.Add(new SqlParameter("@Phone_Number", System.Data.SqlDbType.NVarChar, 50));

                        foreach (var w in warehouses)
                        {
                            if (hasShopIdColumn)
                                cmd.Parameters["@ShopID"].Value = ShopId;
                            cmd.Parameters["@ID"].Value = w.Id;
                            if (!string.IsNullOrWhiteSpace(nameColumn))
                                cmd.Parameters["@Name"].Value = (object?)w.Name ?? DBNull.Value;
                            if (!string.IsNullOrWhiteSpace(addressColumn))
                                cmd.Parameters["@Address"].Value = (object?)w.Address ?? DBNull.Value;
                            if (!string.IsNullOrWhiteSpace(phoneColumn))
                                cmd.Parameters["@Phone_Number"].Value = (object?)w.Phone ?? DBNull.Value;

                            await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
                        }
                    }

                    tx.Commit();
                }
            }

            return warehouses.Count;
        }



        /// <summary>
        /// Sync customers from the upstream API endpoint:
        /// {BaseURL}/shops/{ShopId}/customers?api_key={ApiKey}&page_size=1000&Page={N}
        ///
        /// Paging continues until a page returns no customer rows.
        ///
        /// Customers are staged into dbo.OnlineCustomers so the POS can preserve
        /// both flattened primitive fields and the original nested payload JSON.
        /// </summary>
        public static int SyncCustomers()
        {
            return SyncCustomersAsync().GetAwaiter().GetResult();
        }

        public static async Task<int> SyncCustomersAsync(TimeSpan? timeout = null)
        {
            string shopIdFromSettings = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopIdFromSettings))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            return await SyncCustomersAsync(shopIdFromSettings, timeout).ConfigureAwait(false);
        }

        public static int SyncCustomers(string ShopId)
        {
            return SyncCustomersAsync(ShopId).GetAwaiter().GetResult();
        }

        public static async Task<int> SyncCustomersAsync(string ShopId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(ShopId))
                throw new ArgumentException("ShopId is required", nameof(ShopId));

            timeout ??= TimeSpan.FromSeconds(30);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            DateTime? lastSyncUtc = null;
            try
            {
                using (var syncConn = new SqlConnection(GlobalSettings.ConnectionString))
                {
                    await syncConn.OpenAsync().ConfigureAwait(false);
                    string createSyncTable = @"
IF OBJECT_ID('dbo.OnlineCustomerSync', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.OnlineCustomerSync (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        ShopId NVARCHAR(100) NULL,
        LastSyncUtc DATETIME2 NULL,
        CreatedAtUtc DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    )
END";
                    using (var createCmd = new SqlCommand(createSyncTable, syncConn))
                        await createCmd.ExecuteNonQueryAsync().ConfigureAwait(false);

                    using (var readCmd = new SqlCommand("SELECT TOP 1 LastSyncUtc FROM dbo.OnlineCustomerSync WHERE ShopId = @ShopId OR ShopId IS NULL ORDER BY Id DESC", syncConn))
                    {
                        readCmd.Parameters.AddWithValue("@ShopId", ShopId.Trim());
                        var obj = await readCmd.ExecuteScalarAsync().ConfigureAwait(false);
                        if (obj != null && obj != DBNull.Value)
                        {
                            try { lastSyncUtc = Convert.ToDateTime(obj).ToUniversalTime(); } catch { lastSyncUtc = null; }
                        }
                    }
                }
            }
            catch { lastSyncUtc = null; }

            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
                            if (v.ValueKind == JsonValueKind.Number) return v.ToString();
                            if (v.ValueKind == JsonValueKind.True) return "true";
                            if (v.ValueKind == JsonValueKind.False) return "false";
                            if (v.ValueKind == JsonValueKind.Null) return string.Empty;
                            return v.ToString();
                        }
                    }
                    catch { }
                }

                return string.Empty;
            }

            static string GetJson(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v) && v.ValueKind != JsonValueKind.Undefined && v.ValueKind != JsonValueKind.Null)
                            return v.GetRawText();
                    }
                    catch { }
                }

                return string.Empty;
            }

            static bool? GetNullableBool(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(n, out var v))
                            continue;

                        if (v.ValueKind == JsonValueKind.True) return true;
                        if (v.ValueKind == JsonValueKind.False) return false;
                        if (v.ValueKind == JsonValueKind.Null) return null;

                        var s = v.ToString();
                        if (bool.TryParse(s, out var parsed)) return parsed;
                        if (string.Equals(s, "1", StringComparison.OrdinalIgnoreCase)) return true;
                        if (string.Equals(s, "0", StringComparison.OrdinalIgnoreCase)) return false;
                    }
                    catch { }
                }

                return null;
            }

            static int? GetNullableInt(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(n, out var v))
                            continue;

                        if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var num)) return num;
                        if (v.ValueKind == JsonValueKind.Null) return null;

                        var s = v.ToString();
                        if (int.TryParse(s, out var parsed)) return parsed;
                    }
                    catch { }
                }

                return null;
            }

            static decimal? GetNullableDecimal(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(n, out var v))
                            continue;

                        if (v.ValueKind == JsonValueKind.Number && v.TryGetDecimal(out var num)) return num;
                        if (v.ValueKind == JsonValueKind.Null) return null;

                        var s = v.ToString();
                        if (decimal.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var parsed))
                            return parsed;
                        if (decimal.TryParse(s, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out parsed))
                            return parsed;
                    }
                    catch { }
                }

                return null;
            }

            static DateTime? GetNullableDateTime(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(n, out var v))
                            continue;

                        if (v.ValueKind == JsonValueKind.Null) return null;
                        var s = v.ToString();
                        if (DateTime.TryParse(s, out var parsed)) return parsed;
                    }
                    catch { }
                }

                return null;
            }

            static string GetFirstArrayScalarOrCommonProperty(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(n, out var arr) || arr.ValueKind != JsonValueKind.Array)
                            continue;

                        foreach (var item in arr.EnumerateArray())
                        {
                            if (item.ValueKind == JsonValueKind.String)
                                return item.GetString() ?? string.Empty;
                            if (item.ValueKind == JsonValueKind.Number)
                                return item.ToString();
                            if (item.ValueKind == JsonValueKind.Object)
                            {
                                var nested = GetString(item, "email", "value", "address", "phone_number", "phoneNumber", "phone", "name", "full_address", "fullAddress");
                                if (!string.IsNullOrWhiteSpace(nested))
                                    return nested;
                            }
                        }
                    }
                    catch { }
                }

                return string.Empty;
            }

            static bool TryGetItemsArray(JsonElement root, out JsonElement itemsElement)
            {
                itemsElement = default;

                if (root.ValueKind == JsonValueKind.Array)
                {
                    itemsElement = root;
                    return true;
                }

                if (root.ValueKind != JsonValueKind.Object)
                    return false;

                if (root.TryGetProperty("data", out var dataProp) && dataProp.ValueKind == JsonValueKind.Array)
                {
                    itemsElement = dataProp;
                    return true;
                }

                if (root.TryGetProperty("customers", out var customersProp) && customersProp.ValueKind == JsonValueKind.Array)
                {
                    itemsElement = customersProp;
                    return true;
                }

                if (root.TryGetProperty("items", out var itemsProp) && itemsProp.ValueKind == JsonValueKind.Array)
                {
                    itemsElement = itemsProp;
                    return true;
                }

                foreach (var p in root.EnumerateObject())
                {
                    if (p.Value.ValueKind == JsonValueKind.Array)
                    {
                        itemsElement = p.Value;
                        return true;
                    }
                }

                return false;
            }

            static DateTime? GetChangeTimestampUtc(JsonElement item)
            {
                try
                {
                    var updated = GetNullableDateTime(item, "updated_at", "updatedAt");
                    if (updated.HasValue)
                        return updated.Value.ToUniversalTime();

                    var inserted = GetNullableDateTime(item, "inserted_at", "insertedAt", "created_at", "createdAt");
                    if (inserted.HasValue)
                        return inserted.Value.ToUniversalTime();
                }
                catch { }

                return null;
            }

            var rows = new List<Dictionary<string, object?>>();
            DateTime? newestSeenUtc = lastSyncUtc;

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            for (int page = 1; ; page++)
            {
                string sinceQs = string.Empty;
                if (lastSyncUtc.HasValue)
                {
                    var iso = Uri.EscapeDataString(lastSyncUtc.Value.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"));
                    sinceQs = $"&updated_after={iso}&updatedAfter={iso}&created_after={iso}&createdAfter={iso}&since={iso}";
                }

                string reqPath = $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/customers?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000&page={page}&Page={page}{sinceQs}";

                using var resp = await http.GetAsync(reqPath).ConfigureAwait(false);
                resp.EnsureSuccessStatusCode();

                var json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                using var doc = JsonDocument.Parse(json);

                if (!TryGetItemsArray(doc.RootElement, out var itemsElement))
                    break;

                int itemsThisPage = 0;
                foreach (var item in itemsElement.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object)
                        continue;

                    itemsThisPage++;

                    var changeTimestampUtc = GetChangeTimestampUtc(item);
                    if (changeTimestampUtc.HasValue && (!newestSeenUtc.HasValue || changeTimestampUtc.Value > newestSeenUtc.Value))
                        newestSeenUtc = changeTimestampUtc.Value;

                    if (lastSyncUtc.HasValue && changeTimestampUtc.HasValue && changeTimestampUtc.Value <= lastSyncUtc.Value)
                        continue;

                    string id = GetString(item, "id", "customer_id", "customerId").Trim();
                    if (string.IsNullOrWhiteSpace(id))
                        continue;

                    string creatorJson = GetJson(item, "creator");
                    string creatorName = string.Empty;
                    string creatorPhone = string.Empty;
                    string creatorFbId = string.Empty;
                    string creatorAvatarUrl = string.Empty;
                    if (!string.IsNullOrWhiteSpace(creatorJson))
                    {
                        try
                        {
                            using var creatorDoc = JsonDocument.Parse(creatorJson);
                            creatorName = GetString(creatorDoc.RootElement, "name").Trim();
                            creatorPhone = GetString(creatorDoc.RootElement, "phone_number", "phoneNumber", "phone").Trim();
                            creatorFbId = GetString(creatorDoc.RootElement, "fb_id", "fbId").Trim();
                            creatorAvatarUrl = GetString(creatorDoc.RootElement, "avatar_url", "avatarUrl").Trim();
                        }
                        catch { }
                    }

                    string pagesCustomersJson = GetJson(item, "pages_customers");
                    string primaryPageId = string.Empty;
                    string primaryPageName = string.Empty;
                    string primaryPagePlatform = string.Empty;
                    if (!string.IsNullOrWhiteSpace(pagesCustomersJson))
                    {
                        try
                        {
                            using var pagesDoc = JsonDocument.Parse(pagesCustomersJson);
                            if (pagesDoc.RootElement.ValueKind == JsonValueKind.Array)
                            {
                                foreach (var pageItem in pagesDoc.RootElement.EnumerateArray())
                                {
                                    if (pageItem.ValueKind != JsonValueKind.Object)
                                        continue;

                                    primaryPageId = GetString(pageItem, "id", "page_id", "pageId").Trim();
                                    primaryPageName = GetString(pageItem, "name").Trim();
                                    primaryPagePlatform = GetString(pageItem, "platform").Trim();
                                    break;
                                }
                            }
                        }
                        catch { }
                    }

                    string addressesJson = GetJson(item, "shop_customer_addresses");
                    string primaryAddress = string.Empty;
                    if (!string.IsNullOrWhiteSpace(addressesJson))
                    {
                        try
                        {
                            using var addressesDoc = JsonDocument.Parse(addressesJson);
                            if (addressesDoc.RootElement.ValueKind == JsonValueKind.Array)
                            {
                                foreach (var addressItem in addressesDoc.RootElement.EnumerateArray())
                                {
                                    if (addressItem.ValueKind != JsonValueKind.Object)
                                        continue;

                                    primaryAddress = GetString(addressItem, "full_address", "fullAddress", "address", "name").Trim();
                                    if (!string.IsNullOrWhiteSpace(primaryAddress))
                                        break;
                                }
                            }
                        }
                        catch { }
                    }

                    string emailsJson = GetJson(item, "emails");
                    string phoneNumbersJson = GetJson(item, "phone_numbers", "phoneNumbers");

                    rows.Add(new Dictionary<string, object?>
                    {
                        ["Id"] = id,
                        ["CustomerID"] = GetString(item, "customer_id", "customerId").Trim(),
                        ["ShopID"] = GetString(item, "shop_id", "shopId").Trim(),
                        ["Name"] = GetString(item, "name").Trim(),
                        ["Username"] = GetString(item, "username").Trim(),
                        ["Gender"] = GetString(item, "gender").Trim(),
                        ["FbID"] = GetString(item, "fb_id", "fbId").Trim(),
                        ["IdentityCode"] = GetString(item, "identity_code", "identityCode").Trim(),
                        ["ReferralCode"] = GetString(item, "referral_code", "referralCode").Trim(),
                        ["Currency"] = GetString(item, "currency").Trim(),
                        ["ConversationLink"] = GetString(item, "conversation_link", "conversationLink").Trim(),
                        ["CreatorID"] = GetString(item, "creator_id", "creatorId").Trim(),
                        ["CreatorName"] = creatorName,
                        ["CreatorPhoneNumber"] = creatorPhone,
                        ["CreatorFbID"] = creatorFbId,
                        ["CreatorAvatarUrl"] = creatorAvatarUrl,
                        ["AssignedUserID"] = GetString(item, "assigned_user_id", "assignedUserId").Trim(),
                        ["UserBlockID"] = GetString(item, "user_block_id", "userBlockId").Trim(),
                        ["LevelJson"] = GetJson(item, "level"),
                        ["CompanyInfoJson"] = GetJson(item, "company_info", "companyInfo"),
                        ["ConversationTagsJson"] = GetJson(item, "conversation_tags", "conversationTags"),
                        ["OrderSourcesJson"] = GetJson(item, "order_sources", "orderSources"),
                        ["NotesJson"] = GetJson(item, "notes"),
                        ["TagsJson"] = GetJson(item, "tags"),
                        ["ListVoucherJson"] = GetJson(item, "list_voucher", "listVoucher"),
                        ["PagesCustomersJson"] = pagesCustomersJson,
                        ["ShopCustomerAddressesJson"] = addressesJson,
                        ["EmailsJson"] = emailsJson,
                        ["PhoneNumbersJson"] = phoneNumbersJson,
                        ["PrimaryEmail"] = GetFirstArrayScalarOrCommonProperty(item, "emails"),
                        ["PrimaryPhoneNumber"] = GetFirstArrayScalarOrCommonProperty(item, "phone_numbers", "phoneNumbers"),
                        ["PrimaryAddress"] = primaryAddress,
                        ["PrimaryPageID"] = primaryPageId,
                        ["PrimaryPageName"] = primaryPageName,
                        ["PrimaryPagePlatform"] = primaryPagePlatform,
                        ["CurrentDebts"] = GetNullableDecimal(item, "current_debts", "currentDebts"),
                        ["PurchasedAmount"] = GetNullableDecimal(item, "purchased_amount", "purchasedAmount"),
                        ["OrderCount"] = GetNullableInt(item, "order_count", "orderCount"),
                        ["SucceedOrderCount"] = GetNullableInt(item, "succeed_order_count", "succeedOrderCount"),
                        ["ReturnedOrderCount"] = GetNullableInt(item, "returned_order_count", "returnedOrderCount"),
                        ["RewardPoint"] = GetNullableDecimal(item, "reward_point", "rewardPoint"),
                        ["UsedRewardPoint"] = GetNullableDecimal(item, "used_reward_point", "usedRewardPoint"),
                        ["CountReferrals"] = GetNullableInt(item, "count_referrals", "countReferrals"),
                        ["TotalAmountReferred"] = GetNullableDecimal(item, "total_amount_referred", "totalAmountReferred"),
                        ["IsBlock"] = GetNullableBool(item, "is_block", "isBlock"),
                        ["IsDiscountByLevel"] = GetNullableBool(item, "is_discount_by_level", "isDiscountByLevel"),
                        ["IsAdjustDebts"] = GetNullableBool(item, "is_adjust_debts", "isAdjustDebts"),
                        ["ActiveLeveraPay"] = GetNullableBool(item, "active_levera_pay", "activeLeveraPay"),
                        ["InsertedAt"] = GetNullableDateTime(item, "inserted_at", "insertedAt"),
                        ["UpdatedAt"] = GetNullableDateTime(item, "updated_at", "updatedAt"),
                        ["LastOrderAt"] = GetNullableDateTime(item, "last_order_at", "lastOrderAt"),
                        ["DateOfBirth"] = GetNullableDateTime(item, "date_of_birth", "dateOfBirth"),
                        ["RawJson"] = item.GetRawText()
                    });
                }

                if (itemsThisPage == 0)
                    break;
            }

            if (rows.Count == 0)
            {
                try
                {
                    using var syncConn = new SqlConnection(GlobalSettings.ConnectionString);
                    await syncConn.OpenAsync().ConfigureAwait(false);
                    using var syncCmd = new SqlCommand("INSERT INTO dbo.OnlineCustomerSync (ShopId, LastSyncUtc) VALUES (@ShopId, @LastSyncUtc)", syncConn);
                    syncCmd.Parameters.AddWithValue("@ShopId", ShopId.Trim());
                    syncCmd.Parameters.AddWithValue("@LastSyncUtc", newestSeenUtc.HasValue ? newestSeenUtc.Value : DateTime.UtcNow);
                    await syncCmd.ExecuteNonQueryAsync().ConfigureAwait(false);
                }
                catch { }

                return 0;
            }

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            await conn.OpenAsync().ConfigureAwait(false);

            string createSql = @"
IF OBJECT_ID('dbo.OnlineCustomers', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.OnlineCustomers (
        Id NVARCHAR(100) NOT NULL PRIMARY KEY,
        CustomerID NVARCHAR(100) NULL,
        ShopID NVARCHAR(100) NULL,
        Name NVARCHAR(255) NULL,
        Username NVARCHAR(255) NULL,
        Gender NVARCHAR(50) NULL,
        FbID NVARCHAR(255) NULL,
        IdentityCode NVARCHAR(255) NULL,
        ReferralCode NVARCHAR(100) NULL,
        Currency NVARCHAR(20) NULL,
        ConversationLink NVARCHAR(1000) NULL,
        CreatorID NVARCHAR(100) NULL,
        CreatorName NVARCHAR(255) NULL,
        CreatorPhoneNumber NVARCHAR(100) NULL,
        CreatorFbID NVARCHAR(255) NULL,
        CreatorAvatarUrl NVARCHAR(1000) NULL,
        AssignedUserID NVARCHAR(100) NULL,
        UserBlockID NVARCHAR(100) NULL,
        LevelJson NVARCHAR(MAX) NULL,
        CompanyInfoJson NVARCHAR(MAX) NULL,
        ConversationTagsJson NVARCHAR(MAX) NULL,
        OrderSourcesJson NVARCHAR(MAX) NULL,
        NotesJson NVARCHAR(MAX) NULL,
        TagsJson NVARCHAR(MAX) NULL,
        ListVoucherJson NVARCHAR(MAX) NULL,
        PagesCustomersJson NVARCHAR(MAX) NULL,
        ShopCustomerAddressesJson NVARCHAR(MAX) NULL,
        EmailsJson NVARCHAR(MAX) NULL,
        PhoneNumbersJson NVARCHAR(MAX) NULL,
        PrimaryEmail NVARCHAR(255) NULL,
        PrimaryPhoneNumber NVARCHAR(100) NULL,
        PrimaryAddress NVARCHAR(1000) NULL,
        PrimaryPageID NVARCHAR(100) NULL,
        PrimaryPageName NVARCHAR(255) NULL,
        PrimaryPagePlatform NVARCHAR(50) NULL,
        CurrentDebts DECIMAL(18, 2) NULL,
        PurchasedAmount DECIMAL(18, 2) NULL,
        OrderCount INT NULL,
        SucceedOrderCount INT NULL,
        ReturnedOrderCount INT NULL,
        RewardPoint DECIMAL(18, 2) NULL,
        UsedRewardPoint DECIMAL(18, 2) NULL,
        CountReferrals INT NULL,
        TotalAmountReferred DECIMAL(18, 2) NULL,
        IsBlock BIT NULL,
        IsDiscountByLevel BIT NULL,
        IsAdjustDebts BIT NULL,
        ActiveLeveraPay BIT NULL,
        InsertedAt DATETIME2 NULL,
        UpdatedAt DATETIME2 NULL,
        LastOrderAt DATETIME2 NULL,
        DateOfBirth DATETIME2 NULL,
        RawJson NVARCHAR(MAX) NULL,
        ExcludeOnInventoryReport BIT NOT NULL CONSTRAINT DF_OnlineCustomers_ExcludeOnInventoryReport DEFAULT(0),
        LastSyncedUtc DATETIME2 NOT NULL CONSTRAINT DF_OnlineCustomers_LastSyncedUtc DEFAULT SYSUTCDATETIME()
    )

    CREATE INDEX IX_OnlineCustomers_CustomerID ON dbo.OnlineCustomers(CustomerID)
    CREATE INDEX IX_OnlineCustomers_Name ON dbo.OnlineCustomers(Name)
    CREATE INDEX IX_OnlineCustomers_UpdatedAt ON dbo.OnlineCustomers(UpdatedAt)
END";

            using (var createCmd = new SqlCommand(createSql, conn))
                await createCmd.ExecuteNonQueryAsync().ConfigureAwait(false);

            using (var ensureExcludeColumnCmd = new SqlCommand(@"
IF OBJECT_ID('dbo.OnlineCustomers', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.OnlineCustomers', 'ExcludeOnInventoryReport') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineCustomers
    ADD ExcludeOnInventoryReport BIT NOT NULL
        CONSTRAINT DF_OnlineCustomers_ExcludeOnInventoryReport DEFAULT(0)
END", conn))
            {
                await ensureExcludeColumnCmd.ExecuteNonQueryAsync().ConfigureAwait(false);
            }

            using var tx = conn.BeginTransaction();

            string upsertSql = @"
MERGE dbo.OnlineCustomers AS target
USING (SELECT @Id AS Id) AS source
ON target.Id = source.Id
WHEN MATCHED THEN
    UPDATE SET
        CustomerID = @CustomerID,
        ShopID = @ShopID,
        Name = @Name,
        Username = @Username,
        Gender = @Gender,
        FbID = @FbID,
        IdentityCode = @IdentityCode,
        ReferralCode = @ReferralCode,
        Currency = @Currency,
        ConversationLink = @ConversationLink,
        CreatorID = @CreatorID,
        CreatorName = @CreatorName,
        CreatorPhoneNumber = @CreatorPhoneNumber,
        CreatorFbID = @CreatorFbID,
        CreatorAvatarUrl = @CreatorAvatarUrl,
        AssignedUserID = @AssignedUserID,
        UserBlockID = @UserBlockID,
        LevelJson = @LevelJson,
        CompanyInfoJson = @CompanyInfoJson,
        ConversationTagsJson = @ConversationTagsJson,
        OrderSourcesJson = @OrderSourcesJson,
        NotesJson = @NotesJson,
        TagsJson = @TagsJson,
        ListVoucherJson = @ListVoucherJson,
        PagesCustomersJson = @PagesCustomersJson,
        ShopCustomerAddressesJson = @ShopCustomerAddressesJson,
        EmailsJson = @EmailsJson,
        PhoneNumbersJson = @PhoneNumbersJson,
        PrimaryEmail = @PrimaryEmail,
        PrimaryPhoneNumber = @PrimaryPhoneNumber,
        PrimaryAddress = @PrimaryAddress,
        PrimaryPageID = @PrimaryPageID,
        PrimaryPageName = @PrimaryPageName,
        PrimaryPagePlatform = @PrimaryPagePlatform,
        CurrentDebts = @CurrentDebts,
        PurchasedAmount = @PurchasedAmount,
        OrderCount = @OrderCount,
        SucceedOrderCount = @SucceedOrderCount,
        ReturnedOrderCount = @ReturnedOrderCount,
        RewardPoint = @RewardPoint,
        UsedRewardPoint = @UsedRewardPoint,
        CountReferrals = @CountReferrals,
        TotalAmountReferred = @TotalAmountReferred,
        IsBlock = @IsBlock,
        IsDiscountByLevel = @IsDiscountByLevel,
        IsAdjustDebts = @IsAdjustDebts,
        ActiveLeveraPay = @ActiveLeveraPay,
        InsertedAt = @InsertedAt,
        UpdatedAt = @UpdatedAt,
        LastOrderAt = @LastOrderAt,
        DateOfBirth = @DateOfBirth,
        RawJson = @RawJson,
        LastSyncedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (
        Id, CustomerID, ShopID, Name, Username, Gender, FbID, IdentityCode, ReferralCode, Currency, ConversationLink,
        CreatorID, CreatorName, CreatorPhoneNumber, CreatorFbID, CreatorAvatarUrl, AssignedUserID, UserBlockID,
        LevelJson, CompanyInfoJson, ConversationTagsJson, OrderSourcesJson, NotesJson, TagsJson, ListVoucherJson,
        PagesCustomersJson, ShopCustomerAddressesJson, EmailsJson, PhoneNumbersJson,
        PrimaryEmail, PrimaryPhoneNumber, PrimaryAddress, PrimaryPageID, PrimaryPageName, PrimaryPagePlatform,
        CurrentDebts, PurchasedAmount, OrderCount, SucceedOrderCount, ReturnedOrderCount, RewardPoint, UsedRewardPoint,
        CountReferrals, TotalAmountReferred, IsBlock, IsDiscountByLevel, IsAdjustDebts, ActiveLeveraPay,
        InsertedAt, UpdatedAt, LastOrderAt, DateOfBirth, RawJson, ExcludeOnInventoryReport, LastSyncedUtc
    )
    VALUES (
        @Id, @CustomerID, @ShopID, @Name, @Username, @Gender, @FbID, @IdentityCode, @ReferralCode, @Currency, @ConversationLink,
        @CreatorID, @CreatorName, @CreatorPhoneNumber, @CreatorFbID, @CreatorAvatarUrl, @AssignedUserID, @UserBlockID,
        @LevelJson, @CompanyInfoJson, @ConversationTagsJson, @OrderSourcesJson, @NotesJson, @TagsJson, @ListVoucherJson,
        @PagesCustomersJson, @ShopCustomerAddressesJson, @EmailsJson, @PhoneNumbersJson,
        @PrimaryEmail, @PrimaryPhoneNumber, @PrimaryAddress, @PrimaryPageID, @PrimaryPageName, @PrimaryPagePlatform,
        @CurrentDebts, @PurchasedAmount, @OrderCount, @SucceedOrderCount, @ReturnedOrderCount, @RewardPoint, @UsedRewardPoint,
        @CountReferrals, @TotalAmountReferred, @IsBlock, @IsDiscountByLevel, @IsAdjustDebts, @ActiveLeveraPay,
        @InsertedAt, @UpdatedAt, @LastOrderAt, @DateOfBirth, @RawJson, 0, SYSUTCDATETIME()
    );";

            using var cmd = new SqlCommand(upsertSql, conn, tx);
            cmd.Parameters.Add(new SqlParameter("@Id", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@CustomerID", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@ShopID", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@Name", System.Data.SqlDbType.NVarChar, 255));
            cmd.Parameters.Add(new SqlParameter("@Username", System.Data.SqlDbType.NVarChar, 255));
            cmd.Parameters.Add(new SqlParameter("@Gender", System.Data.SqlDbType.NVarChar, 50));
            cmd.Parameters.Add(new SqlParameter("@FbID", System.Data.SqlDbType.NVarChar, 255));
            cmd.Parameters.Add(new SqlParameter("@IdentityCode", System.Data.SqlDbType.NVarChar, 255));
            cmd.Parameters.Add(new SqlParameter("@ReferralCode", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@Currency", System.Data.SqlDbType.NVarChar, 20));
            cmd.Parameters.Add(new SqlParameter("@ConversationLink", System.Data.SqlDbType.NVarChar, 1000));
            cmd.Parameters.Add(new SqlParameter("@CreatorID", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@CreatorName", System.Data.SqlDbType.NVarChar, 255));
            cmd.Parameters.Add(new SqlParameter("@CreatorPhoneNumber", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@CreatorFbID", System.Data.SqlDbType.NVarChar, 255));
            cmd.Parameters.Add(new SqlParameter("@CreatorAvatarUrl", System.Data.SqlDbType.NVarChar, 1000));
            cmd.Parameters.Add(new SqlParameter("@AssignedUserID", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@UserBlockID", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@LevelJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@CompanyInfoJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@ConversationTagsJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@OrderSourcesJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@NotesJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@TagsJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@ListVoucherJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@PagesCustomersJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@ShopCustomerAddressesJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@EmailsJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@PhoneNumbersJson", System.Data.SqlDbType.NVarChar, -1));
            cmd.Parameters.Add(new SqlParameter("@PrimaryEmail", System.Data.SqlDbType.NVarChar, 255));
            cmd.Parameters.Add(new SqlParameter("@PrimaryPhoneNumber", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@PrimaryAddress", System.Data.SqlDbType.NVarChar, 1000));
            cmd.Parameters.Add(new SqlParameter("@PrimaryPageID", System.Data.SqlDbType.NVarChar, 100));
            cmd.Parameters.Add(new SqlParameter("@PrimaryPageName", System.Data.SqlDbType.NVarChar, 255));
            cmd.Parameters.Add(new SqlParameter("@PrimaryPagePlatform", System.Data.SqlDbType.NVarChar, 50));
            cmd.Parameters.Add(new SqlParameter("@CurrentDebts", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 });
            cmd.Parameters.Add(new SqlParameter("@PurchasedAmount", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 });
            cmd.Parameters.Add(new SqlParameter("@OrderCount", System.Data.SqlDbType.Int));
            cmd.Parameters.Add(new SqlParameter("@SucceedOrderCount", System.Data.SqlDbType.Int));
            cmd.Parameters.Add(new SqlParameter("@ReturnedOrderCount", System.Data.SqlDbType.Int));
            cmd.Parameters.Add(new SqlParameter("@RewardPoint", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 });
            cmd.Parameters.Add(new SqlParameter("@UsedRewardPoint", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 });
            cmd.Parameters.Add(new SqlParameter("@CountReferrals", System.Data.SqlDbType.Int));
            cmd.Parameters.Add(new SqlParameter("@TotalAmountReferred", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 });
            cmd.Parameters.Add(new SqlParameter("@IsBlock", System.Data.SqlDbType.Bit));
            cmd.Parameters.Add(new SqlParameter("@IsDiscountByLevel", System.Data.SqlDbType.Bit));
            cmd.Parameters.Add(new SqlParameter("@IsAdjustDebts", System.Data.SqlDbType.Bit));
            cmd.Parameters.Add(new SqlParameter("@ActiveLeveraPay", System.Data.SqlDbType.Bit));
            cmd.Parameters.Add(new SqlParameter("@InsertedAt", System.Data.SqlDbType.DateTime2));
            cmd.Parameters.Add(new SqlParameter("@UpdatedAt", System.Data.SqlDbType.DateTime2));
            cmd.Parameters.Add(new SqlParameter("@LastOrderAt", System.Data.SqlDbType.DateTime2));
            cmd.Parameters.Add(new SqlParameter("@DateOfBirth", System.Data.SqlDbType.DateTime2));
            cmd.Parameters.Add(new SqlParameter("@RawJson", System.Data.SqlDbType.NVarChar, -1));

            static object ToDbValue(object? value)
            {
                if (value == null)
                    return DBNull.Value;

                if (value is string s)
                    return string.IsNullOrWhiteSpace(s) ? DBNull.Value : s;

                return value;
            }

            foreach (var row in rows)
            {
                foreach (SqlParameter parameter in cmd.Parameters)
                {
                    string key = parameter.ParameterName.TrimStart('@');
                    parameter.Value = row.TryGetValue(key, out var value) ? ToDbValue(value) : DBNull.Value;
                }

                await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
            }

            tx.Commit();

            try
            {
                using var syncConn = new SqlConnection(GlobalSettings.ConnectionString);
                await syncConn.OpenAsync().ConfigureAwait(false);
                using var syncCmd = new SqlCommand("INSERT INTO dbo.OnlineCustomerSync (ShopId, LastSyncUtc) VALUES (@ShopId, @LastSyncUtc)", syncConn);
                syncCmd.Parameters.AddWithValue("@ShopId", ShopId.Trim());
                syncCmd.Parameters.AddWithValue("@LastSyncUtc", newestSeenUtc.HasValue ? newestSeenUtc.Value : DateTime.UtcNow);
                await syncCmd.ExecuteNonQueryAsync().ConfigureAwait(false);
            }
            catch { }

            return rows.Count;
        }

        /// <summary>
        /// Pushes the local dbo.OnlineCustomers table (Pancake customer records, incl. FbID/PSID -
        /// see SyncCustomersAsync above) up to Supabase public."OnlineCustomers", inserting new rows
        /// or patching existing ones (matched by Id) so re-running the sync is always safe. Only a
        /// lean, directly-useful subset of columns is sent (not the *Json blobs/RawJson) - this
        /// table exists so staff can look up which Pancake customer/PSID a Messenger-originated
        /// order-now.html visit or order belongs to, not as a full customer master mirror.
        /// </summary>
        public static MasterDataSyncSummary SyncCustomersToSupabase()
        {
            return SyncCustomersToSupabaseAsync().GetAwaiter().GetResult();
        }

        public static async Task<MasterDataSyncSummary> SyncCustomersToSupabaseAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string endpointUrl = GlobalSettings.OnlineCustomersSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(endpointUrl))
                throw new InvalidOperationException("OnlineCustomersSupabaseEndpoint is not configured.");

            var customerRows = LoadOnlineCustomerRows();
            int insertedCount = 0;
            int updatedCount = 0;

            foreach (var customerRow in customerRows)
            {
                string payloadJson = JsonSerializer.Serialize(customerRow.Payload);
                bool exists = await SupabaseRecordExistsAsync(endpointUrl, timeout.Value, ("Id", customerRow.Id)).ConfigureAwait(false);
                if (exists)
                {
                    await PatchJsonWithHeadersAsync(BuildSupabaseFilteredUrl(endpointUrl, ("Id", customerRow.Id)), payloadJson, timeout.Value).ConfigureAwait(false);
                    updatedCount++;
                }
                else
                {
                    await PostJsonWithHeadersAsync(endpointUrl, payloadJson, timeout.Value).ConfigureAwait(false);
                    insertedCount++;
                }
            }

            return new MasterDataSyncSummary(customerRows.Count, insertedCount, updatedCount);
        }

        private static List<(string Id, Dictionary<string, object?> Payload)> LoadOnlineCustomerRows()
        {
            var rows = new List<(string Id, Dictionary<string, object?> Payload)>();
            using var connection = new SqlConnection(GlobalSettings.ConnectionString);
            connection.Open();

            using var checkCmd = new SqlCommand("SELECT OBJECT_ID('dbo.OnlineCustomers', 'U')", connection);
            if (checkCmd.ExecuteScalar() is DBNull or null)
                return rows;

            const string selectColumns =
                "[Id], [CustomerID], [ShopID], [Name], [FbID], [PrimaryEmail], [PrimaryPhoneNumber], " +
                "[PrimaryAddress], [ConversationLink], [OrderCount], [PurchasedAmount], [LastOrderAt], [UpdatedAt], [InsertedAt]";
            using var cmd = new SqlCommand($"SELECT {selectColumns} FROM dbo.OnlineCustomers", connection);
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string id = rdr["Id"]?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(id))
                    continue;

                static object? Col(SqlDataReader r, string name) => r[name] == DBNull.Value ? null : r[name];

                var payload = new Dictionary<string, object?>
                {
                    ["Id"] = id,
                    ["CustomerID"] = Col(rdr, "CustomerID"),
                    ["ShopID"] = Col(rdr, "ShopID"),
                    ["Name"] = Col(rdr, "Name"),
                    ["FbID"] = Col(rdr, "FbID"),
                    ["PrimaryEmail"] = Col(rdr, "PrimaryEmail"),
                    ["PrimaryPhoneNumber"] = Col(rdr, "PrimaryPhoneNumber"),
                    ["PrimaryAddress"] = Col(rdr, "PrimaryAddress"),
                    ["ConversationLink"] = Col(rdr, "ConversationLink"),
                    ["OrderCount"] = Col(rdr, "OrderCount"),
                    ["PurchasedAmount"] = Col(rdr, "PurchasedAmount"),
                    ["LastOrderAt"] = rdr["LastOrderAt"] == DBNull.Value ? null : Convert.ToDateTime(rdr["LastOrderAt"]).ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture),
                    ["UpdatedAt"] = rdr["UpdatedAt"] == DBNull.Value ? null : Convert.ToDateTime(rdr["UpdatedAt"]).ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture),
                    ["InsertedAt"] = rdr["InsertedAt"] == DBNull.Value ? null : Convert.ToDateTime(rdr["InsertedAt"]).ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture),
                    ["SyncedAtUtc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffK", CultureInfo.InvariantCulture)
                };

                rows.Add((id, payload));
            }

            return rows;
        }

        /// <summary>
        /// Sync product variations from the upstream API and update local Items.VariationId.
        ///
        /// This attempts to map upstream variation identifiers to local items using either:
        /// - product_display_id  -> Items.Code
        /// - sku                -> Items.SKU
        ///
        /// Returns the number of local Items rows updated.
        /// </summary>
        public static int SyncProductVariations()
        {
            return SyncProductVariationsAsync().GetAwaiter().GetResult();
        }

        /// <summary>
        /// Pulls "Production Category" from Supabase public."Categories" down into local
        /// dbo.Category, keyed by Code - the Web Portal's Category Setup screen is the only place
        /// staff can actually toggle this flag (writes to Supabase via admin_update_category_flags,
        /// see WebPortal/js/categorySetup.js). Local dbo.Category otherwise only ever gets Code/
        /// Description from SyncCategoriesAsync's Pancake pull below, which has no equivalent field
        /// and never touches this column - without this pull, checking the box in the portal would
        /// silently never reach Stock Counts' own "WHERE IsProductionCategory = 1" filter (see
        /// StockCountsForm.LoadProducts). Update-only (never inserts) - a Code that doesn't exist
        /// locally yet (not seen by the Pancake sync) just has nothing to update.
        /// Uses the same GET-with-secret-key pattern as GetSupabaseRowsAsync above, but unfiltered
        /// (every category, not a single lookup) since this needs the full set each run.
        /// </summary>
        public static async Task<int> SyncCategoryProductionFlagsFromSupabaseAsync(TimeSpan? timeout = null)
        {
            timeout ??= TimeSpan.FromSeconds(30);

            string endpointUrl = GlobalSettings.CategoriesSupabaseEndpoint?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(endpointUrl))
                throw new InvalidOperationException("CategoriesSupabaseEndpoint is not configured.");

            using var http = new HttpClient { Timeout = timeout.Value };
            using var req = new HttpRequestMessage(HttpMethod.Get, endpointUrl + "?select=Code,IsProductionCategory");
            req.Headers.TryAddWithoutValidation("apikey", GlobalSettings.TransferHeaderSupabaseApiKey);
            req.Headers.TryAddWithoutValidation("Authorization", GlobalSettings.TransferHeaderSupabaseAuthorization);

            using var resp = await http.SendAsync(req).ConfigureAwait(false);
            string respText = string.Empty;
            try { respText = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { respText = string.Empty; }

            if (!resp.IsSuccessStatusCode)
                throw new HttpRequestException($"Categories Supabase GET failed: {(int)resp.StatusCode} {resp.ReasonPhrase}. Response: {respText}");

            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(respText) ? "[]" : respText);
            if (doc.RootElement.ValueKind != JsonValueKind.Array)
                return 0;

            int updatedCount = 0;
            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();

            using var cmd = new SqlCommand("UPDATE dbo.Category SET IsProductionCategory = @IsProductionCategory WHERE Code = @Code", conn);
            cmd.Parameters.Add("@Code", System.Data.SqlDbType.NVarChar, 100);
            cmd.Parameters.Add("@IsProductionCategory", System.Data.SqlDbType.Bit);

            foreach (var row in doc.RootElement.EnumerateArray())
            {
                if (row.ValueKind != JsonValueKind.Object) continue;

                string code = row.TryGetProperty("Code", out var codeProp) && codeProp.ValueKind == JsonValueKind.String
                    ? codeProp.GetString() ?? string.Empty
                    : string.Empty;
                if (string.IsNullOrWhiteSpace(code)) continue;

                bool isProduction = row.TryGetProperty("IsProductionCategory", out var prodProp) && prodProp.ValueKind == JsonValueKind.True;

                cmd.Parameters["@Code"].Value = code;
                cmd.Parameters["@IsProductionCategory"].Value = isProduction;
                updatedCount += cmd.ExecuteNonQuery();
            }

            return updatedCount;
        }

        public static async Task<int> SyncCategoriesAsync(TimeSpan? timeout = null)
        {
            string shopIdFromSettings = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopIdFromSettings))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            return await SyncCategoriesAsync(shopIdFromSettings, timeout).ConfigureAwait(false);
        }

        public static async Task<int> SyncCategoriesAsync(string shopId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(shopId))
                throw new ArgumentException("ShopId is required", nameof(shopId));

            timeout ??= TimeSpan.FromSeconds(60);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
                            if (v.ValueKind == JsonValueKind.Number) return v.ToString();
                            if (v.ValueKind == JsonValueKind.True) return "true";
                            if (v.ValueKind == JsonValueKind.False) return "false";
                            if (v.ValueKind == JsonValueKind.Null) return string.Empty;
                            return v.ToString();
                        }
                    }
                    catch { }
                }

                return string.Empty;
            }

            static bool TryExtractItemsArray(JsonElement root, out JsonElement itemsElement)
            {
                itemsElement = default;

                if (root.ValueKind == JsonValueKind.Array)
                {
                    itemsElement = root;
                    return true;
                }

                if (root.ValueKind == JsonValueKind.Object)
                {
                    if (root.TryGetProperty("data", out var dataProp) && dataProp.ValueKind == JsonValueKind.Array)
                    {
                        itemsElement = dataProp;
                        return true;
                    }

                    if (root.TryGetProperty("variations", out var variationsProp) && variationsProp.ValueKind == JsonValueKind.Array)
                    {
                        itemsElement = variationsProp;
                        return true;
                    }

                    foreach (var property in root.EnumerateObject())
                    {
                        if (property.Value.ValueKind == JsonValueKind.Array)
                        {
                            itemsElement = property.Value;
                            return true;
                        }
                    }
                }

                return false;
            }

            static void AddCategoryName(HashSet<string> categories, string rawName)
            {
                string normalized = rawName?.Trim() ?? string.Empty;
                if (!string.IsNullOrWhiteSpace(normalized))
                {
                    categories.Add(normalized);
                }
            }

            static void AddCategoriesFromNode(HashSet<string> categories, JsonElement source, Func<JsonElement, string[], string> getString)
            {
                if (source.ValueKind != JsonValueKind.Object)
                    return;

                AddCategoryName(categories, getString(source, new[] { "category", "Category", "category_name", "categoryName" }));

                if (source.TryGetProperty("categories", out var nestedCategories))
                {
                    if (nestedCategories.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var nestedCategory in nestedCategories.EnumerateArray())
                        {
                            if (nestedCategory.ValueKind == JsonValueKind.Object)
                            {
                                AddCategoryName(categories, getString(nestedCategory, new[] { "name", "Name", "title", "Title", "category", "Category" }));
                            }
                            else if (nestedCategory.ValueKind == JsonValueKind.String)
                            {
                                AddCategoryName(categories, nestedCategory.GetString() ?? string.Empty);
                            }
                        }
                    }
                    else if (nestedCategories.ValueKind == JsonValueKind.Object)
                    {
                        AddCategoryName(categories, getString(nestedCategories, new[] { "name", "Name", "title", "Title", "category", "Category" }));
                    }
                    else if (nestedCategories.ValueKind == JsonValueKind.String)
                    {
                        AddCategoryName(categories, nestedCategories.GetString() ?? string.Empty);
                    }
                }
            }

            static void AddCategoriesFromItems(JsonElement itemsArray, HashSet<string> categories, Func<JsonElement, string[], string> getString)
            {
                if (itemsArray.ValueKind != JsonValueKind.Array)
                    return;

                foreach (var item in itemsArray.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object)
                        continue;

                    AddCategoriesFromNode(categories, item, getString);

                    if (item.TryGetProperty("product", out var productNode) && productNode.ValueKind == JsonValueKind.Object)
                    {
                        AddCategoriesFromNode(categories, productNode, getString);
                    }

                    if (item.TryGetProperty("variations", out var variationsNode) && variationsNode.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var variation in variationsNode.EnumerateArray())
                        {
                            if (variation.ValueKind != JsonValueKind.Object)
                                continue;

                            AddCategoriesFromNode(categories, variation, getString);
                            AddCategoriesFromNode(categories, item, getString);
                        }
                    }
                }
            }

            string GetStringWrapper(JsonElement obj, string[] names) => GetString(obj, names);

            string[] defaultHiddenCategories = new[]
            {
                "CUSTOM-AQUARIUM",
                "CUSTOMIZED-ITEM",
                "CUSTOM-MEDIAS",
                "CUSTOM-OVERFLOWBOX",
                "CUSTOM-PIPINGS",
                "CUSTOM-STAND",
                "CUSTOM-STICKER",
                "CUSTOM-SUMP",
                "CUSTOM-TOPCOVER"
            };
            var hiddenCategorySet = new HashSet<string>(defaultHiddenCategories, StringComparer.OrdinalIgnoreCase);
            var categories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Exception? lastEx = null;

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            const int pageSize = 10000;
            const int maxPages = 1000;

            for (int page = 1; page <= maxPages; page++)
            {
                string path = $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/products/variations?api_key={Uri.EscapeDataString(apiKey)}&page={page}&pagesize={pageSize}";
                try
                {
                    using var resp = await http.GetAsync(path).ConfigureAwait(false);
                    if (!resp.IsSuccessStatusCode)
                    {
                        if (page == 1)
                            lastEx = new HttpRequestException($"Fetch category variations failed ({(int)resp.StatusCode} {resp.ReasonPhrase}) at page {page}.");
                        break;
                    }

                    var jsonPage = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    if (string.IsNullOrWhiteSpace(jsonPage))
                        break;

                    using var docPage = JsonDocument.Parse(jsonPage);
                    if (!TryExtractItemsArray(docPage.RootElement, out var pageItems))
                        break;

                    if (pageItems.ValueKind != JsonValueKind.Array || pageItems.GetArrayLength() == 0)
                        break;

                    AddCategoriesFromItems(pageItems, categories, GetStringWrapper);
                }
                catch (Exception ex)
                {
                    lastEx = ex;
                    break;
                }
            }

            if (categories.Count == 0)
            {
                string[] candidatePaths = new[]
                {
                    $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/products?api_key={Uri.EscapeDataString(apiKey)}&page=1&pagesize=1000",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/products?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/products?api_key={Uri.EscapeDataString(apiKey)}",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/variations?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/variations?api_key={Uri.EscapeDataString(apiKey)}",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/products/variations?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(shopId)}/products/variations?api_key={Uri.EscapeDataString(apiKey)}"
                };

                foreach (var path in candidatePaths)
                {
                    try
                    {
                        using var resp = await http.GetAsync(path).ConfigureAwait(false);
                        if (!resp.IsSuccessStatusCode)
                            continue;

                        var json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                        if (string.IsNullOrWhiteSpace(json))
                            continue;

                        using var doc = JsonDocument.Parse(json);
                        if (!TryExtractItemsArray(doc.RootElement, out var itemsElement))
                            continue;

                        AddCategoriesFromItems(itemsElement, categories, GetStringWrapper);
                        if (categories.Count > 0)
                            break;
                    }
                    catch (Exception ex)
                    {
                        lastEx = ex;
                    }
                }
            }

            int cloudCategoryCount = categories.Count;
            foreach (var hiddenCategory in defaultHiddenCategories)
            {
                AddCategoryName(categories, hiddenCategory);
            }

            if (cloudCategoryCount == 0)
            {
                if (lastEx != null)
                    throw new InvalidOperationException("Unable to fetch categories from the online API.", lastEx);

                return 0;
            }

            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            await conn.OpenAsync().ConfigureAwait(false);

            using (var ensureCategoryTable = new SqlCommand(@"
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Category')
BEGIN
    CREATE TABLE Category (
        Code NVARCHAR(50) PRIMARY KEY,
        Description NVARCHAR(255) NOT NULL,
        WholeSale BIT NOT NULL CONSTRAINT DF_Category_WholeSale DEFAULT(0),
        DisableChangePrice BIT NOT NULL CONSTRAINT DF_Category_DisableChangePrice DEFAULT(0),
        IsProductionCategory BIT NOT NULL CONSTRAINT DF_Category_IsProductionCategory DEFAULT(0),
        ShowInMainPos BIT NOT NULL CONSTRAINT DF_Category_ShowInMainPos DEFAULT(1),
        ExcludeOnInventoryReport BIT NOT NULL CONSTRAINT DF_Category_ExcludeOnInventoryReport DEFAULT(0),
        CreatedDate DATETIME2 DEFAULT GETDATE(),
        UpdatedDate DATETIME2 DEFAULT GETDATE()
    )
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Category' AND COLUMN_NAME = 'WholeSale')
    BEGIN
        ALTER TABLE Category ADD WholeSale BIT NOT NULL CONSTRAINT DF_Category_WholeSale DEFAULT(0)
    END

    IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Category' AND COLUMN_NAME = 'DisableChangePrice')
    BEGIN
        ALTER TABLE Category ADD DisableChangePrice BIT NOT NULL CONSTRAINT DF_Category_DisableChangePrice DEFAULT(0)
    END

    IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Category' AND COLUMN_NAME = 'IsProductionCategory')
    BEGIN
        ALTER TABLE Category ADD IsProductionCategory BIT NOT NULL CONSTRAINT DF_Category_IsProductionCategory DEFAULT(0)
    END

    IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Category' AND COLUMN_NAME = 'ShowInMainPos')
    BEGIN
        ALTER TABLE Category ADD ShowInMainPos BIT NOT NULL CONSTRAINT DF_Category_ShowInMainPos DEFAULT(1)
    END

    IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Category' AND COLUMN_NAME = 'ExcludeOnInventoryReport')
    BEGIN
        ALTER TABLE Category ADD ExcludeOnInventoryReport BIT NOT NULL CONSTRAINT DF_Category_ExcludeOnInventoryReport DEFAULT(0)
    END
END", conn))
            {
                await ensureCategoryTable.ExecuteNonQueryAsync().ConfigureAwait(false);
            }

            int inserted = 0;
            using var tx = conn.BeginTransaction();
            using var upsertCategory = new SqlCommand(@"
IF NOT EXISTS (SELECT 1 FROM Category WHERE Code = @Code)
BEGIN
    INSERT INTO Category (Code, Description, ShowInMainPos, CreatedDate, UpdatedDate)
    VALUES (@Code, @Description, @ShowInMainPos, GETDATE(), GETDATE())
END
ELSE IF @ShowInMainPos = 0
BEGIN
    UPDATE Category
    SET ShowInMainPos = 0,
        UpdatedDate = GETDATE()
    WHERE Code = @Code
      AND ISNULL(ShowInMainPos, 1) <> 0
END", conn, tx);
            upsertCategory.Parameters.Add(new SqlParameter("@Code", System.Data.SqlDbType.NVarChar, 50));
            upsertCategory.Parameters.Add(new SqlParameter("@Description", System.Data.SqlDbType.NVarChar, 255));
            upsertCategory.Parameters.Add(new SqlParameter("@ShowInMainPos", System.Data.SqlDbType.Bit));

            try
            {
                foreach (string categoryName in categories.OrderBy(name => name, StringComparer.OrdinalIgnoreCase))
                {
                    string categoryCode = categoryName.Trim();
                    if (categoryCode.Length > 50)
                        categoryCode = categoryCode.Substring(0, 50).Trim();

                    string description = categoryName.Trim();
                    if (description.Length > 255)
                        description = description.Substring(0, 255).Trim();

                    if (string.IsNullOrWhiteSpace(categoryCode) || string.IsNullOrWhiteSpace(description))
                        continue;

                    upsertCategory.Parameters["@Code"].Value = categoryCode;
                    upsertCategory.Parameters["@Description"].Value = description;
                    upsertCategory.Parameters["@ShowInMainPos"].Value = hiddenCategorySet.Contains(categoryCode) ? 0 : 1;
                    inserted += await upsertCategory.ExecuteNonQueryAsync().ConfigureAwait(false);
                }

                await tx.CommitAsync().ConfigureAwait(false);
            }
            catch
            {
                try { await tx.RollbackAsync().ConfigureAwait(false); } catch { }
                throw;
            }

            return inserted;
        }

        public static async Task<int> SyncProductVariationsAsync(TimeSpan? timeout = null)
        {
            string shopIdFromSettings = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopIdFromSettings))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            return await SyncProductVariationsAsync(shopIdFromSettings, timeout).ConfigureAwait(false);
        }

        public static int SyncProductVariations(string ShopId)
        {
            return SyncProductVariationsAsync(ShopId).GetAwaiter().GetResult();
        }

        public static async Task<int> SyncProductVariationsAsync(string ShopId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(ShopId))
                throw new ArgumentException("ShopId is required", nameof(ShopId));

            timeout ??= TimeSpan.FromSeconds(30);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");
            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
                            if (v.ValueKind == JsonValueKind.Number) return v.ToString();
                            if (v.ValueKind == JsonValueKind.True) return "true";
                            if (v.ValueKind == JsonValueKind.False) return "false";
                            if (v.ValueKind == JsonValueKind.Null) return string.Empty;
                            return v.ToString();
                        }
                    }
                    catch { }
                }
                return string.Empty;
            }

            static bool TryExtractItemsArray(JsonElement root, out JsonElement itemsElement)
            {
                itemsElement = default;

                if (root.ValueKind == JsonValueKind.Array)
                {
                    itemsElement = root;
                    return true;
                }

                if (root.ValueKind == JsonValueKind.Object)
                {
                    if (root.TryGetProperty("data", out var dataProp) && dataProp.ValueKind == JsonValueKind.Array)
                    {
                        itemsElement = dataProp;
                        return true;
                    }
                    if (root.TryGetProperty("variations", out var varProp) && varProp.ValueKind == JsonValueKind.Array)
                    {
                        itemsElement = varProp;
                        return true;
                    }

                    foreach (var p in root.EnumerateObject())
                    {
                        if (p.Value.ValueKind == JsonValueKind.Array)
                        {
                            itemsElement = p.Value;
                            return true;
                        }
                    }
                }

                return false;
            }

            static string ExtractFirstImageReference(JsonElement element)
            {
                try
                {
                    switch (element.ValueKind)
                    {
                        case JsonValueKind.String:
                            return element.GetString() ?? string.Empty;

                        case JsonValueKind.Array:
                            foreach (var child in element.EnumerateArray())
                            {
                                var found = ExtractFirstImageReference(child);
                                if (!string.IsNullOrWhiteSpace(found))
                                    return found.Trim();
                            }
                            break;

                        case JsonValueKind.Object:
                            foreach (var preferred in new[]
                            {
                                "images", "Images", "image", "Image", "image_url", "imageUrl", "thumbnail",
                                "thumbnail_url", "photo", "photos", "media", "attachments", "url", "src"
                            })
                            {
                                if (element.TryGetProperty(preferred, out var direct))
                                {
                                    var found = ExtractFirstImageReference(direct);
                                    if (!string.IsNullOrWhiteSpace(found))
                                        return found.Trim();
                                }
                            }

                            foreach (var prop in element.EnumerateObject())
                            {
                                var lower = prop.Name.ToLowerInvariant();
                                if (lower.Contains("image") || lower.Contains("photo") || lower.Contains("thumb"))
                                {
                                    var found = ExtractFirstImageReference(prop.Value);
                                    if (!string.IsNullOrWhiteSpace(found))
                                        return found.Trim();
                                }
                            }
                            break;
                    }
                }
                catch { }

                return string.Empty;
            }

            static void AddMappingsFromItems(JsonElement itemsArray, List<(string VariationId, string ProductId, string ProductDisplayId, string DisplayId, string Sku, string Name, string Images)> mappings, HashSet<string> seen, Func<JsonElement, string[], string> getString)
            {
                if (itemsArray.ValueKind != JsonValueKind.Array)
                    return;

                static void AddMapping(
                    JsonElement source,
                    JsonElement? parentProduct,
                    List<(string VariationId, string ProductId, string ProductDisplayId, string DisplayId, string Sku, string Name, string Images)> mappings,
                    HashSet<string> seen,
                    Func<JsonElement, string[], string> getString)
                {
                    var variationId = getString(source, new[] { "variation_id", "VariationID", "VariationId", "id", "ID" }).Trim();
                    if (string.IsNullOrWhiteSpace(variationId))
                        return;

                    var productId = getString(source, new[] { "product_id", "productId", "ProductId" }).Trim();
                    var displayId = getString(source, new[] { "display_id", "displayId" }).Trim();
                    var productDisplayId = getString(source, new[] { "product_display_id", "productDisplayId", "product_display", "product_code" }).Trim();
                    var sku = getString(source, new[] { "sku", "SKU" }).Trim();
                    var name = getString(source, new[] { "name", "Name", "variation_name", "variationName", "title", "Title" }).Trim();
                    var retailPriceRaw = getString(source, new[] { "retail_price", "retailPrice", "price", "Price" }).Trim();
                    var categoryName = getString(source, new[] { "category", "Category", "category_name", "categoryName" }).Trim();
                    var images = ExtractFirstImageReference(source).Trim();

                    if (parentProduct.HasValue && parentProduct.Value.ValueKind == JsonValueKind.Object)
                    {
                        var product = parentProduct.Value;

                        if (string.IsNullOrWhiteSpace(productId))
                            productId = getString(product, new[] { "product_id", "productId", "ProductId", "id", "ID" }).Trim();

                        if (string.IsNullOrWhiteSpace(productDisplayId))
                            productDisplayId = getString(product, new[] { "display_id", "displayId", "product_display_id", "productDisplayId", "product_display", "product_code", "code" }).Trim();

                        if (string.IsNullOrWhiteSpace(sku))
                            sku = getString(product, new[] { "sku", "SKU" }).Trim();

                        var parentName = getString(product, new[] { "name", "Name", "title", "Title" }).Trim();
                        if (string.IsNullOrWhiteSpace(name))
                            name = parentName;

                        if (string.IsNullOrWhiteSpace(retailPriceRaw))
                            retailPriceRaw = getString(product, new[] { "retail_price", "retailPrice", "price", "Price" }).Trim();

                        if (string.IsNullOrWhiteSpace(images))
                            images = ExtractFirstImageReference(product).Trim();

                        if (string.IsNullOrWhiteSpace(categoryName) && product.TryGetProperty("categories", out var cats))
                        {
                            if (cats.ValueKind == JsonValueKind.Array)
                            {
                                foreach (var c in cats.EnumerateArray())
                                {
                                    if (c.ValueKind != JsonValueKind.Object) continue;
                                    var cn = getString(c, new[] { "name", "Name", "title", "Title" }).Trim();
                                    if (!string.IsNullOrWhiteSpace(cn))
                                    {
                                        categoryName = cn;
                                        break;
                                    }
                                }
                            }
                            else if (cats.ValueKind == JsonValueKind.Object)
                            {
                                var cn = getString(cats, new[] { "name", "Name", "title", "Title" }).Trim();
                                if (!string.IsNullOrWhiteSpace(cn))
                                    categoryName = cn;
                            }
                        }
                    }

                    try
                    {
                        if (source.TryGetProperty("product", out var prod) && prod.ValueKind == JsonValueKind.Object)
                        {
                            if (string.IsNullOrWhiteSpace(productId))
                                productId = getString(prod, new[] { "product_id", "productId", "ProductId", "id", "ID" }).Trim();

                            var disp = getString(prod, new[] { "display_id", "displayId", "product_display_id", "productDisplayId", "product_display", "product_code", "code" }).Trim();
                            if (!string.IsNullOrWhiteSpace(disp))
                                productDisplayId = disp;

                            if (string.IsNullOrWhiteSpace(name))
                                name = getString(prod, new[] { "name", "Name", "title", "Title" }).Trim();

                            if (string.IsNullOrWhiteSpace(retailPriceRaw))
                                retailPriceRaw = getString(prod, new[] { "retail_price", "retailPrice", "price", "Price" }).Trim();

                            if (string.IsNullOrWhiteSpace(images))
                                images = ExtractFirstImageReference(prod).Trim();
                        }
                    }
                    catch { }

                    try
                    {
                        if (source.TryGetProperty("variation_info", out var vi) && vi.ValueKind == JsonValueKind.Object)
                        {
                            if (string.IsNullOrWhiteSpace(productId)) productId = getString(vi, new[] { "product_id", "productId", "ProductId" }).Trim();
                            if (string.IsNullOrWhiteSpace(productDisplayId)) productDisplayId = getString(vi, new[] { "product_display_id", "productDisplayId" }).Trim();
                            if (string.IsNullOrWhiteSpace(displayId)) displayId = getString(vi, new[] { "display_id", "displayId" }).Trim();
                            if (string.IsNullOrWhiteSpace(sku)) sku = getString(vi, new[] { "sku", "SKU" }).Trim();
                            if (string.IsNullOrWhiteSpace(name)) name = getString(vi, new[] { "name", "Name" }).Trim();
                            if (string.IsNullOrWhiteSpace(images)) images = ExtractFirstImageReference(vi).Trim();
                            if (string.IsNullOrWhiteSpace(retailPriceRaw)) retailPriceRaw = getString(vi, new[] { "retail_price", "retailPrice", "price", "Price" }).Trim();
                        }
                    }
                    catch { }

                    if (string.IsNullOrWhiteSpace(productDisplayId) && !parentProduct.HasValue && !string.IsNullOrWhiteSpace(displayId))
                        productDisplayId = displayId;

                    var key = $"{variationId}|{productDisplayId}|{sku}";
                    if (!seen.Add(key))
                        return;

                    mappings.Add((variationId, productId, productDisplayId, displayId, sku, name + "\u0001" + retailPriceRaw + "\u0001" + categoryName, images));
                }

                foreach (var item in itemsArray.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object) continue;

                    // Product payloads may include nested variations per product.
                    if (item.TryGetProperty("variations", out var nestedVariations)
                        && nestedVariations.ValueKind == JsonValueKind.Array
                        && nestedVariations.GetArrayLength() > 0)
                    {
                        foreach (var variation in nestedVariations.EnumerateArray())
                        {
                            if (variation.ValueKind != JsonValueKind.Object) continue;
                            AddMapping(variation, item, mappings, seen, getString);
                        }
                    }

                    // Also support flat variation rows.
                    AddMapping(item, null, mappings, seen, getString);
                }
            }

            string GetStringWrapper(JsonElement obj, string[] names) => GetString(obj, names);

            var mappings = new List<(string VariationId, string ProductId, string ProductDisplayId, string DisplayId, string Sku, string Name, string Images)>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            Exception? lastEx = null;
            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            // Preferred endpoint: page from 1..N until the response contains no items.
            const int pageSize = 10000;
            const int maxPages = 1000;

            for (int page = 1; page <= maxPages; page++)
            {
                string path = $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/products/variations?api_key={Uri.EscapeDataString(apiKey)}&page={page}&pagesize={pageSize}";
                try
                {
                    using var resp = await http.GetAsync(path).ConfigureAwait(false);
                    if (!resp.IsSuccessStatusCode)
                    {
                        if (page == 1)
                            lastEx = new HttpRequestException($"Fetch variations failed ({(int)resp.StatusCode} {resp.ReasonPhrase}) at page {page}.");
                        break;
                    }

                    var jsonPage = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    if (string.IsNullOrWhiteSpace(jsonPage))
                        break;

                    using var docPage = JsonDocument.Parse(jsonPage);
                    if (!TryExtractItemsArray(docPage.RootElement, out var pageItems))
                        break;

                    if (pageItems.ValueKind != JsonValueKind.Array || pageItems.GetArrayLength() == 0)
                        break;

                    AddMappingsFromItems(pageItems, mappings, seen, GetStringWrapper);
                }
                catch (Exception ex)
                {
                    lastEx = ex;
                    break;
                }
            }

            // Fallback: try other candidate endpoints if the paged endpoint wasn't reachable.
            if (mappings.Count == 0)
            {
                string[] candidatePaths = new[]
                {
                    $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/products?api_key={Uri.EscapeDataString(apiKey)}&page=1&pagesize=1000",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/products?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/products?api_key={Uri.EscapeDataString(apiKey)}",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/variations?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/variations?api_key={Uri.EscapeDataString(apiKey)}",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/products/variations?api_key={Uri.EscapeDataString(apiKey)}&page_size=1000",
                    $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/products/variations?api_key={Uri.EscapeDataString(apiKey)}"
                };

                string? json = null;
                foreach (var path in candidatePaths)
                {
                    try
                    {
                        using var resp = await http.GetAsync(path).ConfigureAwait(false);
                        if (!resp.IsSuccessStatusCode)
                            continue;
                        json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                        if (!string.IsNullOrWhiteSpace(json))
                            break;
                    }
                    catch (Exception ex)
                    {
                        lastEx = ex;
                    }
                }

                if (string.IsNullOrWhiteSpace(json))
                    throw new InvalidOperationException("Unable to fetch product variations from the online API (no successful endpoint response).", lastEx);

                using var doc = JsonDocument.Parse(json);
                if (!TryExtractItemsArray(doc.RootElement, out var itemsElement))
                    return 0;

                AddMappingsFromItems(itemsElement, mappings, seen, GetStringWrapper);
            }

            if (mappings.Count == 0)
                return 0;

            static decimal? TryParseDecimalInvariant(string raw)
            {
                if (string.IsNullOrWhiteSpace(raw))
                    return null;

                raw = raw.Trim();
                if (decimal.TryParse(raw, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var d))
                    return d;

                // Fallback: current culture
                if (decimal.TryParse(raw, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out d))
                    return d;

                return null;
            }

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                await conn.OpenAsync().ConfigureAwait(false);

                // Ensure Items exists
                int tableExists = 0;
                using (var existsCmd = new SqlCommand("SELECT CASE WHEN OBJECT_ID('dbo.Items','U') IS NULL AND OBJECT_ID('Items','U') IS NULL THEN 0 ELSE 1 END", conn))
                {
                    var scalar = await existsCmd.ExecuteScalarAsync().ConfigureAwait(false);
                    try { tableExists = Convert.ToInt32(scalar); } catch { tableExists = 0; }
                }
                if (tableExists == 0)
                    throw new InvalidOperationException("Items table does not exist.");

                // Prefer dbo.Items but fall back to Items.
                string itemsTable = "dbo.Items";
                using (var dboExists = new SqlCommand("SELECT CASE WHEN OBJECT_ID('dbo.Items','U') IS NULL THEN 0 ELSE 1 END", conn))
                {
                    var scalar = await dboExists.ExecuteScalarAsync().ConfigureAwait(false);
                    int dboTable = 0;
                    try { dboTable = Convert.ToInt32(scalar); } catch { dboTable = 0; }
                    itemsTable = dboTable == 1 ? "dbo.Items" : "Items";
                }

                // Add VariationId column if missing
                using (var addCol = new SqlCommand($@"
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Items' AND COLUMN_NAME = 'VariationId')
BEGIN
    ALTER TABLE {itemsTable} ADD VariationId NVARCHAR(50)
END
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Items' AND COLUMN_NAME = 'ProductId')
BEGIN
    ALTER TABLE {itemsTable} ADD ProductId NVARCHAR(100)
END
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Items' AND COLUMN_NAME = 'Images')
BEGIN
    ALTER TABLE {itemsTable} ADD Images NVARCHAR(MAX)
END", conn))
                {
                    await addCol.ExecuteNonQueryAsync().ConfigureAwait(false);
                }

                using (var ensureVariantTable = new SqlCommand(@"
IF OBJECT_ID(N'dbo.[Variant]', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[Variant] (
        VariantEntryNo INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        VariationId NVARCHAR(50) NOT NULL,
        MainItemCode NVARCHAR(50) NOT NULL,
        ItemCode NVARCHAR(50) NULL,
        SKU NVARCHAR(100) NULL,
        VariantName NVARCHAR(255) NULL,
        Price DECIMAL(18,2) NULL,
        CategoryCode NVARCHAR(50) NULL,
        Images NVARCHAR(MAX) NULL,
        CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_Variant_CreatedDate DEFAULT GETDATE(),
        UpdatedDate DATETIME2 NOT NULL CONSTRAINT DF_Variant_UpdatedDate DEFAULT GETDATE()
    )
END
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'MainItemCode')
    ALTER TABLE dbo.[Variant] ADD MainItemCode NVARCHAR(50) NOT NULL CONSTRAINT DF_Variant_MainItemCode DEFAULT ''
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'ItemCode')
    ALTER TABLE dbo.[Variant] ADD ItemCode NVARCHAR(50) NULL
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'SKU')
    ALTER TABLE dbo.[Variant] ADD SKU NVARCHAR(100) NULL
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'VariantName')
    ALTER TABLE dbo.[Variant] ADD VariantName NVARCHAR(255) NULL
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'Price')
    ALTER TABLE dbo.[Variant] ADD Price DECIMAL(18,2) NULL
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'CategoryCode')
    ALTER TABLE dbo.[Variant] ADD CategoryCode NVARCHAR(50) NULL
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'Images')
    ALTER TABLE dbo.[Variant] ADD Images NVARCHAR(MAX) NULL
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'CreatedDate')
    ALTER TABLE dbo.[Variant] ADD CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_Variant_CreatedDate_Runtime DEFAULT GETDATE()
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Variant' AND COLUMN_NAME = 'UpdatedDate')
    ALTER TABLE dbo.[Variant] ADD UpdatedDate DATETIME2 NOT NULL CONSTRAINT DF_Variant_UpdatedDate_Runtime DEFAULT GETDATE()
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Variant_VariationId' AND object_id = OBJECT_ID(N'dbo.[Variant]'))
    CREATE UNIQUE INDEX UX_Variant_VariationId ON dbo.[Variant](VariationId)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Variant_MainItemCode' AND object_id = OBJECT_ID(N'dbo.[Variant]'))
    CREATE INDEX IX_Variant_MainItemCode ON dbo.[Variant](MainItemCode)
", conn))
                {
                    await ensureVariantTable.ExecuteNonQueryAsync().ConfigureAwait(false);
                }

                // Detect columns availability
                var itemColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                using (var colCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='Items'", conn))
                using (var rdr = await colCmd.ExecuteReaderAsync().ConfigureAwait(false))
                {
                    while (await rdr.ReadAsync().ConfigureAwait(false))
                    {
                        try
                        {
                            var c = rdr[0]?.ToString();
                            if (!string.IsNullOrWhiteSpace(c)) itemColumns.Add(c);
                        }
                        catch { }
                    }
                }

                bool hasSku = itemColumns.Contains("SKU");
                bool hasCode = itemColumns.Contains("Code");
                bool hasName = itemColumns.Contains("Name");
                bool hasDescription = itemColumns.Contains("Description");
                bool hasPrice = itemColumns.Contains("Price");
                bool hasProductId = itemColumns.Contains("ProductId");
                bool hasCategoryCode = itemColumns.Contains("CategoryCode");
                bool hasImages = itemColumns.Contains("Images");

                // CategoryCode has a FK to Category(Code) in many installs.
                // To keep sync resilient (and avoid FK violations), ensure the category exists before updating Items.CategoryCode.
                bool categoryTableExists = false;
                if (hasCategoryCode)
                {
                    using var catExistsCmd = new SqlCommand("SELECT CASE WHEN OBJECT_ID('dbo.Category','U') IS NULL AND OBJECT_ID('Category','U') IS NULL THEN 0 ELSE 1 END", conn);
                    var scalar = await catExistsCmd.ExecuteScalarAsync().ConfigureAwait(false);
                    try { categoryTableExists = Convert.ToInt32(scalar) == 1; } catch { categoryTableExists = false; }
                }

                int updated = 0;
                using (var tx = conn.BeginTransaction())
                {
                    SqlCommand? ensureCategory = null;
                    var ensuredCategories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    if (hasCategoryCode && categoryTableExists)
                    {
                        // Use unqualified Category to respect environments and avoid hardcoding dbo.
                        ensureCategory = new SqlCommand(
                            "IF NOT EXISTS (SELECT 1 FROM Category WHERE Code=@Code)\n" +
                            "BEGIN\n" +
                            "    INSERT INTO Category (Code, Description) VALUES (@Code, @Description)\n" +
                            "END",
                            conn,
                            tx);
                        ensureCategory.Parameters.Add(new SqlParameter("@Code", System.Data.SqlDbType.NVarChar, 50));
                        ensureCategory.Parameters.Add(new SqlParameter("@Description", System.Data.SqlDbType.NVarChar, 255));
                    }

                    string byCodeSql = $"UPDATE {itemsTable} SET VariationId=@VariationId" +
                        (hasProductId ? ", ProductId = COALESCE(NULLIF(@ProductId,''), ProductId)" : string.Empty) +
                        (hasPrice ? ", Price = COALESCE(@Price, Price)" : string.Empty) +
                        (hasImages ? ", Images = COALESCE(NULLIF(@Images,''), Images)" : string.Empty) +
                        (hasCategoryCode ? ", CategoryCode = COALESCE(NULLIF(@CategoryCode,''), CategoryCode)" : string.Empty) +
                        " WHERE Code=@Code";
                    using var byCode = new SqlCommand(byCodeSql, conn, tx);
                    byCode.Parameters.Add(new SqlParameter("@VariationId", System.Data.SqlDbType.NVarChar, 50));
                    byCode.Parameters.Add(new SqlParameter("@Code", System.Data.SqlDbType.NVarChar, 50));
                    if (hasProductId)
                        byCode.Parameters.Add(new SqlParameter("@ProductId", System.Data.SqlDbType.NVarChar, 100));
                    if (hasPrice)
                    {
                        var p = new SqlParameter("@Price", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 };
                        byCode.Parameters.Add(p);
                    }
                    if (hasImages)
                        byCode.Parameters.Add(new SqlParameter("@Images", System.Data.SqlDbType.NVarChar, -1));
                    if (hasCategoryCode)
                        byCode.Parameters.Add(new SqlParameter("@CategoryCode", System.Data.SqlDbType.NVarChar, 255));

                    SqlCommand? bySku = null;
                    if (hasSku)
                    {
                        string bySkuSql = $"UPDATE {itemsTable} SET VariationId=@VariationId" +
                            (hasProductId ? ", ProductId = COALESCE(NULLIF(@ProductId,''), ProductId)" : string.Empty) +
                            (hasPrice ? ", Price = COALESCE(@Price, Price)" : string.Empty) +
                            (hasImages ? ", Images = COALESCE(NULLIF(@Images,''), Images)" : string.Empty) +
                            (hasCategoryCode ? ", CategoryCode = COALESCE(NULLIF(@CategoryCode,''), CategoryCode)" : string.Empty) +
                            " WHERE SKU=@SKU";
                        bySku = new SqlCommand(bySkuSql, conn, tx);
                        bySku.Parameters.Add(new SqlParameter("@VariationId", System.Data.SqlDbType.NVarChar, 50));
                        bySku.Parameters.Add(new SqlParameter("@SKU", System.Data.SqlDbType.NVarChar, 100));
                        if (hasProductId)
                            bySku.Parameters.Add(new SqlParameter("@ProductId", System.Data.SqlDbType.NVarChar, 100));
                        if (hasPrice)
                        {
                            var p = new SqlParameter("@Price", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 };
                            bySku.Parameters.Add(p);
                        }
                        if (hasImages)
                            bySku.Parameters.Add(new SqlParameter("@Images", System.Data.SqlDbType.NVarChar, -1));
                        if (hasCategoryCode)
                            bySku.Parameters.Add(new SqlParameter("@CategoryCode", System.Data.SqlDbType.NVarChar, 255));
                    }

                    SqlCommand? resolveItemCodeBySku = null;
                    if (hasSku)
                    {
                        resolveItemCodeBySku = new SqlCommand($"SELECT TOP 1 Code FROM {itemsTable} WHERE SKU=@SKU ORDER BY Code", conn, tx);
                        resolveItemCodeBySku.Parameters.Add(new SqlParameter("@SKU", System.Data.SqlDbType.NVarChar, 100));
                    }

                    SqlCommand? resolveItemCodeByVariationId = null;
                    if (itemColumns.Contains("VariationId"))
                    {
                        resolveItemCodeByVariationId = new SqlCommand($"SELECT TOP 1 Code FROM {itemsTable} WHERE VariationId=@VariationId ORDER BY Code", conn, tx);
                        resolveItemCodeByVariationId.Parameters.Add(new SqlParameter("@VariationId", System.Data.SqlDbType.NVarChar, 50));
                    }

                    using var upsertVariant = new SqlCommand(@"
IF EXISTS (SELECT 1 FROM dbo.[Variant] WHERE VariationId=@VariationId)
BEGIN
    UPDATE dbo.[Variant]
       SET MainItemCode=@MainItemCode,
           ItemCode=@ItemCode,
           SKU=@SKU,
           VariantName=@VariantName,
           Price=@Price,
           CategoryCode=@CategoryCode,
           Images=@Images,
           UpdatedDate=GETDATE()
     WHERE VariationId=@VariationId
END
ELSE
BEGIN
    INSERT INTO dbo.[Variant] (VariationId, MainItemCode, ItemCode, SKU, VariantName, Price, CategoryCode, Images)
    VALUES (@VariationId, @MainItemCode, @ItemCode, @SKU, @VariantName, @Price, @CategoryCode, @Images)
END", conn, tx);
                    upsertVariant.Parameters.Add(new SqlParameter("@VariationId", System.Data.SqlDbType.NVarChar, 50));
                    upsertVariant.Parameters.Add(new SqlParameter("@MainItemCode", System.Data.SqlDbType.NVarChar, 50));
                    upsertVariant.Parameters.Add(new SqlParameter("@ItemCode", System.Data.SqlDbType.NVarChar, 50));
                    upsertVariant.Parameters.Add(new SqlParameter("@SKU", System.Data.SqlDbType.NVarChar, 100));
                    upsertVariant.Parameters.Add(new SqlParameter("@VariantName", System.Data.SqlDbType.NVarChar, 255));
                    upsertVariant.Parameters.Add(new SqlParameter("@Price", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 });
                    upsertVariant.Parameters.Add(new SqlParameter("@CategoryCode", System.Data.SqlDbType.NVarChar, 50));
                    upsertVariant.Parameters.Add(new SqlParameter("@Images", System.Data.SqlDbType.NVarChar, -1));

                    // Optional insert when item doesn't exist yet
                    SqlCommand? insertItem = null;
                    if (hasCode)
                    {
                        var insertCols = new List<string> { "[Code]" };
                        var insertVals = new List<string> { "@Code" };
                        var insertParams = new List<SqlParameter>
                        {
                            new SqlParameter("@Code", System.Data.SqlDbType.NVarChar, 50)
                        };

                        if (itemColumns.Contains("VariationId"))
                        {
                            insertCols.Add("[VariationId]");
                            insertVals.Add("@VariationId");
                            insertParams.Add(new SqlParameter("@VariationId", System.Data.SqlDbType.NVarChar, 50));
                        }
                        if (hasProductId)
                        {
                            insertCols.Add("[ProductId]");
                            insertVals.Add("@ProductId");
                            insertParams.Add(new SqlParameter("@ProductId", System.Data.SqlDbType.NVarChar, 100));
                        }
                        if (hasName)
                        {
                            insertCols.Add("[Name]");
                            insertVals.Add("@Name");
                            insertParams.Add(new SqlParameter("@Name", System.Data.SqlDbType.NVarChar, 255));
                        }
                        if (hasDescription)
                        {
                            insertCols.Add("[Description]");
                            insertVals.Add("@Description");
                            insertParams.Add(new SqlParameter("@Description", System.Data.SqlDbType.NVarChar, 1000));
                        }
                        if (hasPrice)
                        {
                            insertCols.Add("[Price]");
                            insertVals.Add("@Price");
                            var p = new SqlParameter("@Price", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 };
                            insertParams.Add(p);
                        }
                        if (hasImages)
                        {
                            insertCols.Add("[Images]");
                            insertVals.Add("@Images");
                            insertParams.Add(new SqlParameter("@Images", System.Data.SqlDbType.NVarChar, -1));
                        }

                        if (hasCategoryCode)
                        {
                            insertCols.Add("[CategoryCode]");
                            insertVals.Add("@CategoryCode");
                            insertParams.Add(new SqlParameter("@CategoryCode", System.Data.SqlDbType.NVarChar, 255));
                        }

                        // Only insert if Code doesn't already exist
                        string insertSql =
                            $"IF NOT EXISTS (SELECT 1 FROM {itemsTable} WHERE Code=@Code)\n" +
                            $"BEGIN\n" +
                            $"    INSERT INTO {itemsTable} ({string.Join(", ", insertCols)}) VALUES ({string.Join(", ", insertVals)})\n" +
                            $"END";

                        insertItem = new SqlCommand(insertSql, conn, tx);
                        insertItem.Parameters.AddRange(insertParams.ToArray());
                    }

                    foreach (var m in mappings)
                    {
                        int affected = 0;
                        string linkedItemCode = string.Empty;

                        // Name field is carrying: "Name\u0001RetailPrice\u0001CategoryName"
                        string name = m.Name;
                        string retailPriceRaw = string.Empty;
                        string categoryName = string.Empty;
                        var parts = name.Split('\u0001');
                        if (parts.Length > 0) name = parts[0];
                        if (parts.Length > 1) retailPriceRaw = parts[1];
                        if (parts.Length > 2) categoryName = parts[2];

                        // Prefer SKU match (more specific) if available; otherwise fall back to Code (product display_id).
                        string categoryCode = (categoryName ?? string.Empty).Trim();
                        if (categoryCode.Length > 50)
                            categoryCode = categoryCode.Substring(0, 50);

                        decimal? retailPrice = null;
                        if (hasPrice)
                            retailPrice = TryParseDecimalInvariant(retailPriceRaw);

                        string variantName = !string.IsNullOrWhiteSpace(m.DisplayId)
                            ? m.DisplayId.Trim()
                            : name;

                        if (resolveItemCodeBySku != null && !string.IsNullOrWhiteSpace(m.Sku))
                        {
                            resolveItemCodeBySku.Parameters["@SKU"].Value = m.Sku;
                            var existingCode = await resolveItemCodeBySku.ExecuteScalarAsync().ConfigureAwait(false);
                            if (existingCode != null && existingCode != DBNull.Value)
                                linkedItemCode = existingCode.ToString() ?? string.Empty;
                        }

                        if (ensureCategory != null && !string.IsNullOrWhiteSpace(categoryCode) && ensuredCategories.Add(categoryCode))
                        {
                            ensureCategory.Parameters["@Code"].Value = categoryCode;
                            ensureCategory.Parameters["@Description"].Value = categoryCode;
                            await ensureCategory.ExecuteNonQueryAsync().ConfigureAwait(false);
                        }

                        if (bySku != null && !string.IsNullOrWhiteSpace(m.Sku))
                        {
                            bySku.Parameters["@VariationId"].Value = m.VariationId;
                            bySku.Parameters["@SKU"].Value = m.Sku;
                            if (hasProductId)
                                bySku.Parameters["@ProductId"].Value = string.IsNullOrWhiteSpace(m.ProductId) ? DBNull.Value : m.ProductId;
                            if (hasPrice)
                                bySku.Parameters["@Price"].Value = retailPrice.HasValue ? retailPrice.Value : DBNull.Value;
                            if (hasImages)
                                bySku.Parameters["@Images"].Value = string.IsNullOrWhiteSpace(m.Images) ? DBNull.Value : m.Images;
                            if (hasCategoryCode)
                                bySku.Parameters["@CategoryCode"].Value = categoryCode;
                            affected = await bySku.ExecuteNonQueryAsync().ConfigureAwait(false);
                        }

                        if (affected == 0 && !string.IsNullOrWhiteSpace(m.ProductDisplayId))
                        {
                            byCode.Parameters["@VariationId"].Value = m.VariationId;
                            byCode.Parameters["@Code"].Value = m.ProductDisplayId;
                            if (hasProductId)
                                byCode.Parameters["@ProductId"].Value = string.IsNullOrWhiteSpace(m.ProductId) ? DBNull.Value : m.ProductId;
                            if (hasPrice)
                                byCode.Parameters["@Price"].Value = retailPrice.HasValue ? retailPrice.Value : DBNull.Value;
                            if (hasImages)
                                byCode.Parameters["@Images"].Value = string.IsNullOrWhiteSpace(m.Images) ? DBNull.Value : m.Images;
                            if (hasCategoryCode)
                                byCode.Parameters["@CategoryCode"].Value = categoryCode;
                            affected = await byCode.ExecuteNonQueryAsync().ConfigureAwait(false);
                        }

                        if (string.IsNullOrWhiteSpace(linkedItemCode) && !string.IsNullOrWhiteSpace(m.ProductDisplayId))
                            linkedItemCode = m.ProductDisplayId;

                        // If no match by SKU/Code, auto-add item using mapping:
                        // product.display_id -> Code
                        // id -> VariationId
                        // product.name -> Name & Description
                        // retail_price -> Price
                        if (affected == 0 && insertItem != null && !string.IsNullOrWhiteSpace(m.ProductDisplayId))
                        {
                            insertItem.Parameters["@Code"].Value = m.ProductDisplayId;

                            if (insertItem.Parameters.Contains("@VariationId"))
                                insertItem.Parameters["@VariationId"].Value = (object?)m.VariationId ?? DBNull.Value;
                            if (insertItem.Parameters.Contains("@ProductId"))
                                insertItem.Parameters["@ProductId"].Value = string.IsNullOrWhiteSpace(m.ProductId) ? DBNull.Value : m.ProductId;
                            if (insertItem.Parameters.Contains("@Name"))
                                insertItem.Parameters["@Name"].Value = (object?)name ?? DBNull.Value;
                            if (insertItem.Parameters.Contains("@Description"))
                                insertItem.Parameters["@Description"].Value = (object?)name ?? DBNull.Value;
                            if (insertItem.Parameters.Contains("@Price"))
                            {
                                var dec = TryParseDecimalInvariant(retailPriceRaw);
                                insertItem.Parameters["@Price"].Value = dec.HasValue ? dec.Value : DBNull.Value;
                            }
                            if (insertItem.Parameters.Contains("@Images"))
                                insertItem.Parameters["@Images"].Value = string.IsNullOrWhiteSpace(m.Images) ? DBNull.Value : m.Images;

                            if (insertItem.Parameters.Contains("@CategoryCode"))
                            {
                                // Ensure the Category exists before assigning CategoryCode to avoid FK violations.
                                try
                                {
                                    if (!string.IsNullOrWhiteSpace(categoryCode))
                                    {
                                        using var chk = new SqlCommand("SELECT COUNT(1) FROM Category WHERE Code=@c", conn, tx);
                                        chk.Parameters.AddWithValue("@c", categoryCode);
                                        var cntObj = await chk.ExecuteScalarAsync().ConfigureAwait(false);
                                        int cnt = 0;
                                        try { cnt = Convert.ToInt32(cntObj); } catch { cnt = 0; }
                                        if (cnt == 0)
                                        {
                                            // Category not present despite earlier ensure attempt; avoid FK failure by leaving CategoryCode NULL
                                            insertItem.Parameters["@CategoryCode"].Value = DBNull.Value;
                                        }
                                        else
                                        {
                                            insertItem.Parameters["@CategoryCode"].Value = categoryCode;
                                        }
                                    }
                                    else
                                    {
                                        insertItem.Parameters["@CategoryCode"].Value = DBNull.Value;
                                    }
                                }
                                catch
                                {
                                    // If any error occurs while checking category, null out CategoryCode to avoid FK errors
                                    insertItem.Parameters["@CategoryCode"].Value = DBNull.Value;
                                }
                            }

                            int inserted = await insertItem.ExecuteNonQueryAsync().ConfigureAwait(false);
                            if (inserted > 0)
                            {
                                linkedItemCode = m.ProductDisplayId;

                                string mainItemCodeForVariant = !string.IsNullOrWhiteSpace(m.ProductDisplayId)
                                    ? m.ProductDisplayId.Trim()
                                    : linkedItemCode.Trim();

                                if (!string.IsNullOrWhiteSpace(m.VariationId) && !string.IsNullOrWhiteSpace(mainItemCodeForVariant))
                                {
                                    upsertVariant.Parameters["@VariationId"].Value = m.VariationId;
                                    upsertVariant.Parameters["@MainItemCode"].Value = mainItemCodeForVariant;
                                    upsertVariant.Parameters["@ItemCode"].Value = string.IsNullOrWhiteSpace(linkedItemCode) ? DBNull.Value : linkedItemCode;
                                    upsertVariant.Parameters["@SKU"].Value = string.IsNullOrWhiteSpace(m.Sku) ? DBNull.Value : m.Sku;
                                    upsertVariant.Parameters["@VariantName"].Value = string.IsNullOrWhiteSpace(variantName) ? DBNull.Value : variantName;
                                    upsertVariant.Parameters["@Price"].Value = retailPrice.HasValue ? retailPrice.Value : DBNull.Value;
                                    upsertVariant.Parameters["@CategoryCode"].Value = string.IsNullOrWhiteSpace(categoryCode) ? DBNull.Value : categoryCode;
                                    upsertVariant.Parameters["@Images"].Value = string.IsNullOrWhiteSpace(m.Images) ? DBNull.Value : m.Images;
                                    await upsertVariant.ExecuteNonQueryAsync().ConfigureAwait(false);
                                }

                                // Count insert as an update for reporting purposes
                                updated += 1;
                                continue;
                            }
                        }

                        if (string.IsNullOrWhiteSpace(linkedItemCode) && resolveItemCodeByVariationId != null)
                        {
                            resolveItemCodeByVariationId.Parameters["@VariationId"].Value = m.VariationId;
                            var codeByVariation = await resolveItemCodeByVariationId.ExecuteScalarAsync().ConfigureAwait(false);
                            if (codeByVariation != null && codeByVariation != DBNull.Value)
                                linkedItemCode = codeByVariation.ToString() ?? string.Empty;
                        }

                        string mainItemCode = !string.IsNullOrWhiteSpace(m.ProductDisplayId)
                            ? m.ProductDisplayId.Trim()
                            : linkedItemCode.Trim();

                        if (!string.IsNullOrWhiteSpace(m.VariationId) && !string.IsNullOrWhiteSpace(mainItemCode))
                        {
                            upsertVariant.Parameters["@VariationId"].Value = m.VariationId;
                            upsertVariant.Parameters["@MainItemCode"].Value = mainItemCode;
                            upsertVariant.Parameters["@ItemCode"].Value = string.IsNullOrWhiteSpace(linkedItemCode) ? DBNull.Value : linkedItemCode;
                            upsertVariant.Parameters["@SKU"].Value = string.IsNullOrWhiteSpace(m.Sku) ? DBNull.Value : m.Sku;
                            upsertVariant.Parameters["@VariantName"].Value = string.IsNullOrWhiteSpace(variantName) ? DBNull.Value : variantName;
                            upsertVariant.Parameters["@Price"].Value = retailPrice.HasValue ? retailPrice.Value : DBNull.Value;
                            upsertVariant.Parameters["@CategoryCode"].Value = string.IsNullOrWhiteSpace(categoryCode) ? DBNull.Value : categoryCode;
                            upsertVariant.Parameters["@Images"].Value = string.IsNullOrWhiteSpace(m.Images) ? DBNull.Value : m.Images;
                            await upsertVariant.ExecuteNonQueryAsync().ConfigureAwait(false);
                        }

                        if (affected > 0)
                            updated += affected;
                    }

                    tx.Commit();
                }

                return updated;
            }
        }

        /// <summary>
        /// Create missing products in the cloud for local Items rows that have a blank VariationId.
        ///
        /// Mapping:
        /// - product.name         = Items.Code
        /// - product.note_product = Items.Description
        /// - variation.retail_price / price_at_counter = Items.Price
        /// - variation.last_imported_price            = Items.Cost (if column exists)
        /// - variations_warehouses.remain_quantity    = Items.QuantityInStock (if column exists)
        /// - variations_warehouses.warehouse_id       = current warehouse ID (from local Warehouses table)
        ///
        /// After creating the product, updates Items.VariationId with the created variation id (if found in response).
        /// Returns the number of local Items rows updated with a new VariationId.
        /// </summary>
        public static int SyncUpProducts()
        {
            return SyncUpProductsAsync().GetAwaiter().GetResult();
        }

        public static async Task<int> SyncUpProductsAsync(TimeSpan? timeout = null)
        {
            string shopIdFromSettings = GlobalSettings.OnlineOrdersShopId ?? string.Empty;
            if (string.IsNullOrWhiteSpace(shopIdFromSettings))
                throw new InvalidOperationException("OnlineOrdersShopId is not configured.");

            return await SyncUpProductsAsync(shopIdFromSettings, timeout).ConfigureAwait(false);
        }

        public static int SyncUpProducts(string ShopId)
        {
            return SyncUpProductsAsync(ShopId).GetAwaiter().GetResult();
        }

        public static async Task<int> SyncUpProductsAsync(string ShopId, TimeSpan? timeout = null)
        {
            if (string.IsNullOrWhiteSpace(ShopId))
                throw new ArgumentException("ShopId is required", nameof(ShopId));

            timeout ??= TimeSpan.FromSeconds(60);

            string baseUrl = GlobalSettings.OnlineOrdersApiBaseUrl?.TrimEnd('/') ?? string.Empty;
            string apiKey = GlobalSettings.OnlineOrdersApiKey ?? string.Empty;

            if (string.IsNullOrWhiteSpace(baseUrl))
                throw new InvalidOperationException("OnlineOrdersApiBaseUrl is not configured.");
            if (string.IsNullOrWhiteSpace(apiKey))
                throw new InvalidOperationException("OnlineOrdersApiKey is not configured.");

            string endpoint = $"{baseUrl}/shops/{Uri.EscapeDataString(ShopId)}/products?api_key={Uri.EscapeDataString(apiKey)}";

            static string GetString(JsonElement obj, params string[] names)
            {
                foreach (var n in names)
                {
                    try
                    {
                        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(n, out var v))
                        {
                            if (v.ValueKind == JsonValueKind.String) return v.GetString() ?? string.Empty;
                            if (v.ValueKind == JsonValueKind.Number) return v.ToString();
                            if (v.ValueKind == JsonValueKind.True) return "true";
                            if (v.ValueKind == JsonValueKind.False) return "false";
                            if (v.ValueKind == JsonValueKind.Null) return string.Empty;
                            return v.ToString();
                        }
                    }
                    catch { }
                }
                return string.Empty;
            }

            static string ExtractVariationId(JsonElement root)
            {
                // Try common shapes:
                // { product: { variations: [ { id: ... } ] } }
                // { variations: [ { id: ... } ] }
                // { data: { ... } }
                try
                {
                    if (root.ValueKind == JsonValueKind.Object)
                    {
                        if (root.TryGetProperty("product", out var product) && product.ValueKind == JsonValueKind.Object)
                        {
                            if (product.TryGetProperty("variations", out var vars) && vars.ValueKind == JsonValueKind.Array && vars.GetArrayLength() > 0)
                            {
                                var v0 = vars[0];
                                var id = GetString(v0, "variation_id", "VariationId", "id", "ID");
                                if (!string.IsNullOrWhiteSpace(id)) return id.Trim();
                            }
                        }

                        if (root.TryGetProperty("variations", out var vars2) && vars2.ValueKind == JsonValueKind.Array && vars2.GetArrayLength() > 0)
                        {
                            var v0 = vars2[0];
                            var id = GetString(v0, "variation_id", "VariationId", "id", "ID");
                            if (!string.IsNullOrWhiteSpace(id)) return id.Trim();
                        }

                        if (root.TryGetProperty("data", out var data) && data.ValueKind != JsonValueKind.Null)
                        {
                            return ExtractVariationId(data);
                        }
                    }
                }
                catch { }
                return string.Empty;
            }

            static decimal? ExtractRetailPrice(JsonElement root)
            {
                // Try common shapes:
                // { product: { variations: [ { retail_price: ... } ] } }
                // { variations: [ { retail_price: ... } ] }
                // { data: { ... } }
                try
                {
                    if (root.ValueKind == JsonValueKind.Object)
                    {
                        if (root.TryGetProperty("product", out var product) && product.ValueKind == JsonValueKind.Object)
                        {
                            if (product.TryGetProperty("variations", out var vars) && vars.ValueKind == JsonValueKind.Array && vars.GetArrayLength() > 0)
                            {
                                var v0 = vars[0];
                                var priceRaw = GetString(v0, "retail_price", "retailPrice", "price", "Price");
                                if (decimal.TryParse(priceRaw, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var d))
                                    return d;
                                if (decimal.TryParse(priceRaw, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out d))
                                    return d;
                            }
                        }

                        if (root.TryGetProperty("variations", out var vars2) && vars2.ValueKind == JsonValueKind.Array && vars2.GetArrayLength() > 0)
                        {
                            var v0 = vars2[0];
                            var priceRaw = GetString(v0, "retail_price", "retailPrice", "price", "Price");
                            if (decimal.TryParse(priceRaw, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var d))
                                return d;
                            if (decimal.TryParse(priceRaw, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.CurrentCulture, out d))
                                return d;
                        }

                        if (root.TryGetProperty("data", out var data) && data.ValueKind != JsonValueKind.Null)
                        {
                            return ExtractRetailPrice(data);
                        }
                    }
                }
                catch { }

                return null;
            }

            static bool IsPlaceholderProductCode(string code)
            {
                var normalized = code?.Trim() ?? string.Empty;
                return string.Equals(normalized, "CUSTOM", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(normalized, "INC_EXP", StringComparison.OrdinalIgnoreCase);
            }

            static bool IsDuplicateCustomIdResponse(System.Net.HttpStatusCode statusCode, string responseText)
            {
                if ((int)statusCode != 422)
                    return false;

                if (string.IsNullOrWhiteSpace(responseText))
                    return false;

                return responseText.IndexOf("already exists", StringComparison.OrdinalIgnoreCase) >= 0
                    || responseText.IndexOf("Custom Product ID already exists", StringComparison.OrdinalIgnoreCase) >= 0;
            }

            // Resolve current warehouse ID (best effort; if not available we skip warehouse quantities)
            string warehouseId = string.Empty;
            try { warehouseId = await GetCurrentWarehouseIdAsync(ShopId).ConfigureAwait(false); } catch { warehouseId = string.Empty; }

            using var http = new HttpClient { BaseAddress = new Uri(baseUrl), Timeout = timeout.Value };

            using (var conn = new SqlConnection(GlobalSettings.ConnectionString))
            {
                await conn.OpenAsync().ConfigureAwait(false);

                // Prefer dbo.Items but fall back to Items.
                string itemsTable = "dbo.Items";
                using (var dboExists = new SqlCommand("SELECT CASE WHEN OBJECT_ID('dbo.Items','U') IS NULL THEN 0 ELSE 1 END", conn))
                {
                    var scalar = await dboExists.ExecuteScalarAsync().ConfigureAwait(false);
                    int dboTable = 0;
                    try { dboTable = Convert.ToInt32(scalar); } catch { dboTable = 0; }
                    itemsTable = dboTable == 1 ? "dbo.Items" : "Items";
                }

                // Ensure VariationId column exists
                using (var addCol = new SqlCommand($@"
                IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Items' AND COLUMN_NAME = 'VariationId')
                BEGIN
                    ALTER TABLE {itemsTable} ADD VariationId NVARCHAR(50)
                END", conn))
                {
                    await addCol.ExecuteNonQueryAsync().ConfigureAwait(false);
                }

                // Detect columns availability
                var itemColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                using (var colCmd = new SqlCommand("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='Items'", conn))
                using (var rdr = await colCmd.ExecuteReaderAsync().ConfigureAwait(false))
                {
                    while (await rdr.ReadAsync().ConfigureAwait(false))
                    {
                        try
                        {
                            var c = rdr[0]?.ToString();
                            if (!string.IsNullOrWhiteSpace(c)) itemColumns.Add(c);
                        }
                        catch { }
                    }
                }

                if (!itemColumns.Contains("Code"))
                    throw new InvalidOperationException("Items table must contain a 'Code' column.");

                bool hasDescription = itemColumns.Contains("Description");
                bool hasPrice = itemColumns.Contains("Price");
                bool hasCost = itemColumns.Contains("Cost");
                bool hasQty = itemColumns.Contains("QuantityInStock");
                bool hasImages = itemColumns.Contains("Images");

                string selectSql = $"SELECT Code" +
                    (hasDescription ? ", Description" : ", CAST('' AS NVARCHAR(MAX)) AS Description") +
                    (hasPrice ? ", Price" : ", CAST(0 AS DECIMAL(18,2)) AS Price") +
                    (hasCost ? ", Cost" : ", CAST(0 AS DECIMAL(18,2)) AS Cost") +
                    (hasQty ? ", QuantityInStock" : ", CAST(0 AS INT) AS QuantityInStock") +
                    (hasImages ? ", Images" : ", CAST('' AS NVARCHAR(MAX)) AS Images") +
                    $" FROM {itemsTable} WHERE (VariationId IS NULL OR LTRIM(RTRIM(VariationId)) = '')";

                var toCreate = new List<(string Code, string Description, decimal Price, decimal Cost, int Qty, string Images)>();
                using (var cmd = new SqlCommand(selectSql, conn))
                using (var rdr = await cmd.ExecuteReaderAsync().ConfigureAwait(false))
                {
                    while (await rdr.ReadAsync().ConfigureAwait(false))
                    {
                        string code = rdr[0]?.ToString() ?? string.Empty;
                        if (string.IsNullOrWhiteSpace(code)) continue;
                        if (IsPlaceholderProductCode(code)) continue;

                        string desc = rdr[1]?.ToString() ?? string.Empty;
                        decimal price = 0m;
                        decimal cost = 0m;
                        int qty = 0;
                        string images = string.Empty;

                        try { price = Convert.ToDecimal(rdr[2]); } catch { price = 0m; }
                        try { cost = Convert.ToDecimal(rdr[3]); } catch { cost = 0m; }
                        try { qty = Convert.ToInt32(rdr[4]); } catch { qty = 0; }
                        try { images = rdr[5]?.ToString() ?? string.Empty; } catch { images = string.Empty; }

                        toCreate.Add((code.Trim(), desc ?? string.Empty, price, cost, qty, images.Trim()));
                    }
                }

                if (toCreate.Count == 0)
                    return 0;

                int updated = 0;

                using (var tx = conn.BeginTransaction())
                {
                    using var updateLocal = new SqlCommand(
                        hasPrice
                            ? $"UPDATE {itemsTable} SET VariationId=@VariationId, Price=@Price WHERE Code=@Code AND (VariationId IS NULL OR LTRIM(RTRIM(VariationId))='')"
                            : $"UPDATE {itemsTable} SET VariationId=@VariationId WHERE Code=@Code AND (VariationId IS NULL OR LTRIM(RTRIM(VariationId))='')",
                        conn,
                        tx);
                    updateLocal.Parameters.Add(new SqlParameter("@VariationId", System.Data.SqlDbType.NVarChar, 50));
                    updateLocal.Parameters.Add(new SqlParameter("@Code", System.Data.SqlDbType.NVarChar, 50));
                    if (hasPrice)
                        updateLocal.Parameters.Add(new SqlParameter("@Price", System.Data.SqlDbType.Decimal) { Precision = 18, Scale = 2 });

                    foreach (var item in toCreate)
                    {
                        var payload = new
                        {
                            product = new
                            {
                                name = item.Code,
                                note_product = item.Description,
                                custom_id = item.Code,
                                Images = string.IsNullOrWhiteSpace(item.Images) ? null : new[] { item.Images },
                                is_published = true,
                                variations = new object[]
                                {
                                    new
                                    {
                                        retail_price = item.Price,
                                        price_at_counter = item.Price,
                                        last_imported_price = item.Cost,
                                        custom_id = item.Code,
                                        is_hidden = false
                                    }
                                },
                                variations_warehouses = string.IsNullOrWhiteSpace(warehouseId)
                                    ? null
                                    : new object[]
                                    {
                                        new
                                        {
                                            remain_quantity = item.Qty,
                                            warehouse_id = warehouseId
                                        }
                                    }
                            }
                        };

                        var bodyJson = JsonSerializer.Serialize(payload, new JsonSerializerOptions
                        {
                            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
                        });

                        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint)
                        {
                            Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
                        };

                        using var resp = await http.SendAsync(req).ConfigureAwait(false);
                        if (!resp.IsSuccessStatusCode)
                        {
                            var responseText = string.Empty;
                            try { responseText = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }

                            if (IsDuplicateCustomIdResponse(resp.StatusCode, responseText))
                            {
                                continue;
                            }

                            throw new HttpRequestException($"Sync Up failed creating product for Code '{item.Code}' ({(int)resp.StatusCode} {resp.ReasonPhrase}). {responseText}");
                        }

                        var respJson = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                        var variationId = string.Empty;
                        decimal? retailPrice = null;
                        if (!string.IsNullOrWhiteSpace(respJson))
                        {
                            try
                            {
                                using var doc = JsonDocument.Parse(respJson);
                                variationId = ExtractVariationId(doc.RootElement);
                                retailPrice = ExtractRetailPrice(doc.RootElement);
                                if (string.IsNullOrWhiteSpace(variationId))
                                {
                                    // Some APIs might return it directly
                                    variationId = GetString(doc.RootElement, "variation_id", "VariationId", "id", "ID").Trim();
                                }
                            }
                            catch { }
                        }

                        // If we couldn't parse a variation id, leave it blank; user can run Sync to back-fill.
                        if (!string.IsNullOrWhiteSpace(variationId))
                        {
                            updateLocal.Parameters["@VariationId"].Value = variationId;
                            updateLocal.Parameters["@Code"].Value = item.Code;
                            if (hasPrice)
                                updateLocal.Parameters["@Price"].Value = (object?)(retailPrice ?? item.Price) ?? DBNull.Value;
                            int affected = await updateLocal.ExecuteNonQueryAsync().ConfigureAwait(false);
                            if (affected > 0)
                                updated += affected;
                        }
                    }

                    tx.Commit();
                }

                return updated;
            }
        }
    }
}
