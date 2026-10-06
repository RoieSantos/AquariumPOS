using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace AquariumPOS
{
    // Custom Aquarium screen = the portal's own Aquarium Calculator (docs/WebAquariumCalculator/index.html),
    // shipped with the POS (see the WebCalculator Content items in AquariumPOS.csproj) and shown in
    // WebView2 - same UI, safety rules, drawings, summary and print quote as the portal, fully offline.
    // Prices = the raw rows of the last successful pricing sync (OnlinefunctionsEvents.WebCalculatorPricingCache),
    // lights/pumps = the local Items table. "Add to sale" in the page posts the quote back here and
    // AddWebCalculatorQuoteToSale turns it into the same component sale lines the classic dialog made.
    // Falls back to the classic WinForms dialog (ShowCustomAquariumDialog) if WebView2 or the files are missing.
    public partial class MainForm
    {
        private void ShowWebAquariumCalculatorOrClassic()
        {
            string indexPath = Path.Combine(WebAquariumCalculatorForm.RootFolder, "WebAquariumCalculator", "index.html");
            bool runtimeAvailable;
            try
            {
                runtimeAvailable = !string.IsNullOrWhiteSpace(CoreWebView2Environment.GetAvailableBrowserVersionString());
            }
            catch
            {
                runtimeAvailable = false;
            }

            if (!runtimeAvailable || !File.Exists(indexPath))
            {
                ShowCustomAquariumDialog();
                return;
            }

            bool openClassic = false;
            using (var form = new WebAquariumCalculatorForm(BuildWebCalculatorHostJson(), AddWebCalculatorQuoteToSale))
            {
                form.ClassicRequested += () => openClassic = true;
                form.ShowDialog(this);
            }

            if (openClassic)
            {
                ShowCustomAquariumDialog();
            }
        }

        // window.RSPosHost for the page: { pricing: { glass, tubular, sticker, extra }, items: { LIGHTS, PUMP } }
        // in the same row shapes the portal's Supabase RPCs return, so the page code path is identical.
        private string BuildWebCalculatorHostJson()
        {
            var pricing = new JsonObject
            {
                ["glass"] = LoadCachedPricingRows("glass") ?? BuildLocalGlassPricingRows(),
                ["tubular"] = LoadCachedPricingRows("tubular") ?? new JsonArray(OnlinefunctionsEvents.PricingCache.TubularRatesPerFt
                    .Select(kv => (JsonNode)new JsonObject { ["tubular_size"] = kv.Key, ["price_per_ft"] = kv.Value }).ToArray()),
                ["sticker"] = LoadCachedPricingRows("sticker") ?? BuildLocalStickerPricingRows(),
                ["extra"] = LoadCachedPricingRows("extra") ?? new JsonArray()
            };

            var items = new JsonObject
            {
                ["LIGHTS"] = LoadWebCalculatorItems("LIGHTS"),
                ["PUMP"] = LoadWebCalculatorItems("PUMP")
            };

            return new JsonObject { ["pricing"] = pricing, ["items"] = items }.ToJsonString();
        }

        private static JsonArray? LoadCachedPricingRows(string name)
        {
            try
            {
                string? raw = OnlinefunctionsEvents.WebCalculatorPricingCache.Load(name);
                return string.IsNullOrWhiteSpace(raw) ? null : JsonNode.Parse(raw) as JsonArray;
            }
            catch
            {
                return null;
            }
        }

        // Never synced yet on this terminal: the local GlassPricingSetup table (also what the classic dialog prices from).
        private JsonArray BuildLocalGlassPricingRows()
        {
            var rows = new JsonArray();
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT Units, PricePerSqFt FROM GlassPricingSetup WHERE UOM = 'MM'", conn);
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string units = rdr["Units"]?.ToString() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(units) || rdr["PricePerSqFt"] == DBNull.Value) continue;
                    rows.Add(new JsonObject { ["thickness"] = units.Trim(), ["price_per_sqft"] = Convert.ToDecimal(rdr["PricePerSqFt"]) });
                }
            }
            catch { }
            return rows;
        }

        private static JsonArray BuildLocalStickerPricingRows()
        {
            var rows = new JsonArray
            {
                new JsonObject { ["sticker_type"] = "Plain Sticker", ["price_per_sqft"] = OnlinefunctionsEvents.PricingCache.PlainStickerPricePerSqFt },
                new JsonObject { ["sticker_type"] = "Tiles Sticker", ["price_per_sqft"] = OnlinefunctionsEvents.PricingCache.TilesStickerPricePerSqFt },
                new JsonObject { ["sticker_type"] = "Acrylic", ["price_per_sqft"] = OnlinefunctionsEvents.PricingCache.AcrylicPricePerSqFt },
                new JsonObject { ["sticker_type"] = "Allum TopCover", ["price_per_sqft"] = OnlinefunctionsEvents.PricingCache.AllumTopCoverPricePerSqFt },
                new JsonObject { ["sticker_type"] = "Rubber Matting", ["price_per_sqft"] = OnlinefunctionsEvents.PricingCache.RubberMattingBasePricePerSqFt }
            };
            foreach (var kv in OnlinefunctionsEvents.PricingCache.RubberMattingPricePerSqFt)
            {
                rows.Add(new JsonObject { ["sticker_type"] = "Rubber Matting", ["thickness"] = kv.Key, ["price_per_sqft"] = kv.Value });
            }
            return rows;
        }

        // Same Items lookup as the classic dialog's light/pump pickers, plus Price (the page prices the item at it).
        private JsonArray LoadWebCalculatorItems(string categoryCode)
        {
            var list = new JsonArray();
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT Code, Description, Price FROM Items WHERE CategoryCode = @cat ORDER BY Description", conn);
                cmd.Parameters.AddWithValue("@cat", categoryCode);
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string code = rdr["Code"]?.ToString() ?? string.Empty;
                    string desc = rdr["Description"]?.ToString() ?? string.Empty;
                    if (string.IsNullOrWhiteSpace(code)) continue;
                    decimal price = rdr["Price"] == DBNull.Value ? 0m : Convert.ToDecimal(rdr["Price"]);
                    list.Add(new JsonObject
                    {
                        ["code"] = code,
                        ["item_name"] = string.IsNullOrWhiteSpace(desc) ? code : desc,
                        ["price"] = price
                    });
                }
            }
            catch { }
            return list;
        }

        private static string LookupItemDescription(string connectionStr, string code)
        {
            try
            {
                using var conn = new SqlConnection(connectionStr);
                conn.Open();
                using var cmd = new SqlCommand("SELECT Description FROM Items WHERE Code = @code", conn);
                cmd.Parameters.AddWithValue("@code", code);
                var desc = cmd.ExecuteScalar() as string;
                return string.IsNullOrWhiteSpace(desc) ? code : desc.Trim();
            }
            catch
            {
                return code;
            }
        }

        /// <summary>
        /// The page's "Add to sale" message -> sale lines, same shape as the classic dialog: one line per
        /// priced component (Aquarium Build, High Strip, Sump Glass, Filter Medias, Light/Pump with their
        /// item codes, Overflow Box, Piping, Top Cover, Stickers, Aquascape...), the quoted total spread
        /// across them as whole pesos, plus the stand as its own line. Quantities follow the page:
        /// aquarium lines x Quantity, sump lines x Sump Quantity (when the sump is priced separately), stand x Stand Quantity.
        /// </summary>
        private bool AddWebCalculatorQuoteToSale(JsonElement msg)
        {
            var result = msg.GetProperty("result");
            var quote = msg.GetProperty("quote");
            var fields = msg.GetProperty("fields");
            var normalized = result.GetProperty("normalized");
            var components = result.TryGetProperty("components", out var c) && c.ValueKind == JsonValueKind.Object ? c : default;

            string Field(string id) => fields.TryGetProperty(id, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? string.Empty).Trim() : string.Empty;
            bool Checked(string id) => fields.TryGetProperty(id, out var v) && v.ValueKind == JsonValueKind.True;
            decimal Num(JsonElement obj, string name) => obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : 0m;
            int IntField(string id) => int.TryParse(Field(id), out var n) ? n : 0;
            string Fmt(decimal d) => d.ToString("0.##");

            bool sumpOnly = result.TryGetProperty("sumpOnly", out var so) && so.ValueKind == JsonValueKind.True;
            decimal gallons = Num(result, "gallons");
            string unit = Field("unit");
            string sumpUnit = string.IsNullOrWhiteSpace(Field("sumpUnit")) ? unit : Field("sumpUnit");

            string tankSizeDetail = sumpOnly ? string.Empty : $"Tank {Field("length")}x{Field("width")}x{Field("height")} {unit} ({gallons:F1} gal)";
            string sumpSizeDetail = (sumpOnly || Checked("sumpEnabled")) && !string.IsNullOrWhiteSpace(Field("sumpLength"))
                ? $"Sump {Field("sumpLength")}x{Field("sumpWidth")}x{Field("sumpHeight")} {sumpUnit}"
                : string.Empty;
            string sumpType = sumpOnly && normalized.TryGetProperty("sumpOnly", out var soN) && soN.TryGetProperty("type", out var soT)
                ? soT.GetString() ?? "Sump"
                : (string.IsNullOrWhiteSpace(Field("sumpType")) ? "Sump" : Field("sumpType"));
            string option = Field("option");
            string glass = normalized.TryGetProperty("glassThickness", out var g) ? g.GetString() ?? string.Empty : Field("glass");
            bool tempered = normalized.TryGetProperty("temperedGlass", out var t) && t.ValueKind == JsonValueKind.True;
            bool rimless = normalized.TryGetProperty("rimless", out var r) && r.ValueKind == JsonValueKind.True;

            int holeCount = IntField("holeCount");
            int dividerCount = IntField("dividerCount");
            string glassBuildDetail = BuildDetailedSaleDescription(
                "Aquarium Build",
                tankSizeDetail,
                $"Glass {glass}",
                $"{(string.IsNullOrWhiteSpace(Field("sealant")) ? "Clear" : Field("sealant"))} sealant",
                option,
                Checked("lowIron") ? "Low Iron" : null,
                tempered ? "Tempered" : null,
                Checked("aio") ? "AIO" : null,
                Checked("enclosure") ? "Enclosure" : null,
                Checked("turtleTank") ? "Turtle Tank" : null,
                rimless ? "Rimless" : null);

            string lightCode = msg.TryGetProperty("light", out var li) && li.ValueKind == JsonValueKind.Object ? li.GetProperty("code").GetString() ?? string.Empty : string.Empty;
            string pumpCode = msg.TryGetProperty("pump", out var pu) && pu.ValueKind == JsonValueKind.Object ? pu.GetProperty("code").GetString() ?? string.Empty : string.Empty;
            int lightQty = Math.Max(1, IntField("lightQuantity"));
            int pumpQty = Math.Max(1, IntField("pumpQuantity"));

            string StickerType(string id) => string.IsNullOrWhiteSpace(Field(id)) ? "Plain" : Field(id);

            // (component key, description, item code, part of the sump group)
            var specs = new List<(string Key, string Description, string ItemCode, bool Sump)>
            {
                ("glass", glassBuildDetail, "", false),
                ("highStrip", BuildDetailedSaleDescription("High Strip", tankSizeDetail), "", false),
                ("holes", BuildDetailedSaleDescription($"Aquarium Build - {holeCount} Hole(s)", tankSizeDetail), "", false),
                ("divider", BuildDetailedSaleDescription($"Aquarium Build - {dividerCount} Divider(s)", tankSizeDetail), "", false),
                ("sumpGlass", BuildDetailedSaleDescription($"{sumpType} Glass", sumpSizeDetail, $"Glass {(string.IsNullOrWhiteSpace(Field("sumpGlass")) ? glass : Field("sumpGlass"))}", tankSizeDetail), "", true),
                ("filterMedia", BuildDetailedSaleDescription("Filter Medias", sumpSizeDetail), "", true),
                ("light", string.IsNullOrWhiteSpace(lightCode) ? "Submersible Light" : LookupItemDescription(connectionString, lightCode) + (lightQty > 1 ? $" x{lightQty}" : ""), lightCode, true),
                ("overflowBox", BuildDetailedSaleDescription("Overflow Box", sumpSizeDetail, tankSizeDetail), "", true),
                ("piping", BuildDetailedSaleDescription("Set of Piping", sumpSizeDetail, tankSizeDetail), "", true),
                ("pump", string.IsNullOrWhiteSpace(pumpCode) ? "Submersible Pump" : LookupItemDescription(connectionString, pumpCode) + (pumpQty > 1 ? $" x{pumpQty}" : ""), pumpCode, true),
                ("allumTopCover", BuildDetailedSaleDescription("Allum Top Cover", sumpSizeDetail, tankSizeDetail), "", true),
                ("stickerBackground", BuildDetailedSaleDescription(Checked("allSides")
                    ? $"Sticker Background ({StickerType("stickerBackgroundType")}, All Sides)"
                    : $"Sticker Background ({StickerType("stickerBackgroundType")})", tankSizeDetail), "", false),
                ("stickerBottom", BuildDetailedSaleDescription($"Sticker Bottom ({StickerType("stickerBottomType")})", tankSizeDetail), "", false),
                ("aquascapeService", BuildDetailedSaleDescription("Aquascape service", tankSizeDetail), "", false)
            };

            decimal sumpUnitPrice = Num(quote, "sumpUnitPrice");
            bool sumpSeparate = sumpOnly || (quote.TryGetProperty("sumpEnabled", out var se) && se.ValueKind == JsonValueKind.True && sumpUnitPrice > 0m);
            int aquariumQty = Math.Max(1, (int)Num(quote, "aquariumQty"));
            int sumpQty = Math.Max(1, (int)Num(quote, "sumpQty"));

            var aquariumGroup = new List<(string Description, decimal Amount, string ItemCode)>();
            var sumpGroup = new List<(string Description, decimal Amount, string ItemCode)>();
            foreach (var spec in specs)
            {
                decimal amount = Num(components, spec.Key);
                if (amount <= 0m) continue;
                if (sumpOnly || (sumpSeparate && spec.Sump)) sumpGroup.Add((spec.Description, amount, spec.ItemCode));
                else aquariumGroup.Add((spec.Description, amount, spec.ItemCode));
            }

            int linesAdded = 0;
            if (!sumpOnly)
            {
                linesAdded += AddAllocatedComponentLines(aquariumGroup, Num(quote, "perAquariumTotal"), aquariumQty);
            }
            if (sumpSeparate)
            {
                linesAdded += AddAllocatedComponentLines(sumpGroup, sumpUnitPrice, sumpQty);
            }

            // Stand as its own line (not part of the aquarium allocation), same as the classic dialog.
            decimal standUnitPrice = Num(quote, "standUnitPrice");
            if (!sumpOnly && standUnitPrice > 0m && normalized.TryGetProperty("stand", out var stand) && stand.ValueKind == JsonValueKind.Object)
            {
                string tubular = stand.TryGetProperty("tubular", out var tb) ? tb.GetString() ?? string.Empty : string.Empty;
                var standBits = new List<string?>
                {
                    $"{(int)Num(stand, "layers")}-Layer {tubular} Tubular{(stand.TryGetProperty("stainless", out var ss) && ss.ValueKind == JsonValueKind.True ? " (Stainless)" : "")}",
                    $"{Fmt(Num(stand, "heightInches"))}in height",
                    stand.TryGetProperty("cabinet", out var cb) && cb.ValueKind == JsonValueKind.True ? "Cabinet" : null,
                    stand.TryGetProperty("canopy", out var cn) && cn.ValueKind == JsonValueKind.True ? "Canopy" : null,
                    stand.TryGetProperty("sumpHolder", out var sh) && sh.ValueKind == JsonValueKind.True ? $"Sump Holder ({Fmt(Num(stand, "sumpWidth"))}in)" : null,
                    tankSizeDetail
                };
                string standDesc = FunctionEvents.ToAscii(BuildDetailedSaleDescription("Stand", standBits.ToArray()));
                string standCategory = ResolveCustomAquariumCalculatorCategory(standDesc, "CUSTOM_STAND");
                string standCode = ShouldResolveCustomAquariumCatalogVariation(standCategory) ? standCategory : "CUSTOM_STAND";
                int standQty = Math.Max(1, (int)Num(quote, "standQty"));
                decimal displayStandPrice = Math.Max(0m, Math.Round(standUnitPrice, 0, MidpointRounding.AwayFromZero));
                AddToSale("  " + standDesc, standQty, displayStandPrice, standCategory, standCode, null, "  " + standDesc, true);
                linesAdded++;
            }

            if (linesAdded == 0)
            {
                MessageBox.Show("Nothing to add - the calculator has no priced items yet.", "Custom Aquarium", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return false;
            }

            pendingCustomAquariumSpecialNote = NormalizeSaleDetailText(Field("specialNote"));
            UpdateTotal();

            decimal grandTotal = Num(quote, "grandTotal");
            string name = sumpOnly ? $"Custom {sumpType} Sump" : $"Custom Aquarium {tankSizeDetail.Replace("Tank ", "")}";
            MessageBox.Show(FunctionEvents.ToAscii($"Added {name} to sale!\nPrice: {grandTotal:N2}"), "Custom Aquarium Added", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return true;
        }

        // Spreads targetTotal (one unit's price) across the components as whole pesos with no negatives -
        // same allocation as the classic dialog - and adds each as its own sale line x quantity.
        private int AddAllocatedComponentLines(List<(string Description, decimal Amount, string ItemCode)> components, decimal targetTotal, int quantity)
        {
            if (components.Count == 0 || targetTotal <= 0m) return 0;

            targetTotal = Math.Round(targetTotal, 0, MidpointRounding.AwayFromZero);
            decimal baseSum = components.Sum(x => x.Amount);
            var allocated = new decimal[components.Count];
            var rawShares = new decimal[components.Count];

            if (baseSum <= 0m)
            {
                allocated[0] = targetTotal;
            }
            else
            {
                for (int i = 0; i < components.Count; i++)
                {
                    rawShares[i] = targetTotal * (components[i].Amount / baseSum);
                    allocated[i] = Math.Floor(rawShares[i]);
                }

                decimal remainder = targetTotal - allocated.Sum();
                int steps = (int)Math.Round(Math.Abs(remainder), MidpointRounding.AwayFromZero);
                if (steps > 0)
                {
                    bool add = remainder > 0;
                    int[] order = add
                        ? Enumerable.Range(0, components.Count).OrderByDescending(i => rawShares[i] - Math.Floor(rawShares[i])).ToArray()
                        : Enumerable.Range(0, components.Count).OrderByDescending(i => allocated[i]).ToArray();
                    for (int k = 0; k < steps; k++)
                    {
                        int idx = order[k % order.Length];
                        if (add) allocated[idx] += 1m;
                        else if (allocated[idx] > 0m) allocated[idx] -= 1m;
                    }
                }
            }

            for (int i = 0; i < components.Count; i++)
            {
                string d = FunctionEvents.ToAscii(components[i].Description);
                string category = ResolveCustomAquariumCalculatorCategory(d, components[i].ItemCode);
                string code = ShouldResolveCustomAquariumCatalogVariation(category)
                    ? category
                    : (string.IsNullOrWhiteSpace(components[i].ItemCode) ? "CUSTOM-AQUARIUM" : components[i].ItemCode);
                AddToSale("  " + d, quantity, Math.Max(0m, allocated[i]), category, code, null, "  " + d, true);
            }

            return components.Count;
        }
    }

    /// <summary>WebView2 window hosting the bundled portal Aquarium Calculator (see MainForm.ShowWebAquariumCalculatorOrClassic).</summary>
    public class WebAquariumCalculatorForm : Form
    {
        public static string RootFolder => Path.Combine(AppContext.BaseDirectory, "WebCalculator");
        private const string HostName = "pos-calculator.local";

        private readonly WebView2 webView = new WebView2 { Dock = DockStyle.Fill };
        private readonly string hostJson;
        private readonly Func<JsonElement, bool> addToSale;

        public event Action? ClassicRequested;

        public WebAquariumCalculatorForm(string hostJson, Func<JsonElement, bool> addToSale)
        {
            this.hostJson = hostJson;
            this.addToSale = addToSale;

            Text = "Custom Aquarium Calculator";
            WindowState = FormWindowState.Maximized;
            StartPosition = FormStartPosition.CenterParent;
            MinimumSize = new Size(900, 600);

            var topBar = new Panel { Dock = DockStyle.Top, Height = 40, BackColor = Color.FromArgb(245, 245, 245) };
            var classicButton = new Button
            {
                Text = "Open classic calculator",
                AutoSize = true,
                Font = new Font("Arial", 10),
                Location = new Point(8, 6)
            };
            classicButton.Click += (s, e) =>
            {
                ClassicRequested?.Invoke();
                Close();
            };
            var closeButton = new Button
            {
                Text = "Close",
                AutoSize = true,
                Font = new Font("Arial", 10),
                Anchor = AnchorStyles.Top | AnchorStyles.Right
            };
            closeButton.Click += (s, e) => Close();
            topBar.Controls.Add(classicButton);
            topBar.Controls.Add(closeButton);
            topBar.Resize += (s, e) => closeButton.Location = new Point(topBar.ClientSize.Width - closeButton.Width - 8, 6);

            Controls.Add(webView);
            Controls.Add(topBar);

            Load += async (s, e) => await InitializeAsync();
        }

        private async System.Threading.Tasks.Task InitializeAsync()
        {
            try
            {
                string userData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RSPETSTOP POS", "WebView2");
                var env = await CoreWebView2Environment.CreateAsync(null, userData);
                await webView.EnsureCoreWebView2Async(env);
                var core = webView.CoreWebView2;

                core.SetVirtualHostNameToFolderMapping(HostName, RootFolder, CoreWebView2HostResourceAccessKind.Allow);

                // The page loads supabase-js from a CDN; offline that would fail (and the POS never
                // talks to Supabase from here anyway) - answer it locally with a tiny stand-in.
                core.AddWebResourceRequestedFilter("https://cdn.jsdelivr.net/*", CoreWebView2WebResourceContext.All);
                core.WebResourceRequested += (s, e) =>
                {
                    const string stub = "window.supabase = { createClient: function () { return {}; } };";
                    var stream = new MemoryStream(Encoding.UTF8.GetBytes(stub));
                    e.Response = core.Environment.CreateWebResourceResponse(stream, 200, "OK", "Content-Type: application/javascript");
                };

                await core.AddScriptToExecuteOnDocumentCreatedAsync("window.RSPosHost = " + hostJson + ";");
                core.WebMessageReceived += OnWebMessageReceived;
                core.NavigationCompleted += (s, e) =>
                {
                    if (!e.IsSuccess)
                    {
                        ShowLoadFailure($"The calculator page could not load ({e.WebErrorStatus}).");
                    }
                };

                core.Navigate($"https://{HostName}/WebAquariumCalculator/index.html");
            }
            catch (Exception ex)
            {
                ShowLoadFailure(ex.Message);
            }
        }

        private void ShowLoadFailure(string reason)
        {
            MessageBox.Show(this, $"{reason}\n\nOpening the classic calculator instead.", "Custom Aquarium Calculator", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            ClassicRequested?.Invoke();
            Close();
        }

        private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            try
            {
                using var doc = JsonDocument.Parse(e.WebMessageAsJson);
                var msg = doc.RootElement;
                if (!msg.TryGetProperty("type", out var type) || type.GetString() != "rs-pos-add-to-sale") return;

                if (addToSale(msg))
                {
                    Close();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Could not add this quote to the sale: " + ex.Message, "Custom Aquarium", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
