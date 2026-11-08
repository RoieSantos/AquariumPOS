using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    // Size-based pricing (e.g. fish: SHBRTG 8,500, a 10-11" one 10,000) - set up on the Web Portal's
    // Size Pricing page (sql/supabase_item_size_pricing.sql) and pulled into dbo.ItemSizeTier by
    // OnlinefunctionsEvents.SyncItemSizeTiersFromPortalAsync. When a size-priced item is added to a sale,
    // AddToSale asks for the size and the price comes from the formula - staff never type it. Stock is
    // not split: the line keeps the same item code / variation, only the price and name change.
    public partial class MainForm
    {
        private sealed class SaleSizeTier
        {
            public string Label { get; set; } = string.Empty;
            public decimal Price { get; set; }
        }

        private sealed class SaleSizeChoice
        {
            public bool IsCancelled { get; set; }
            public string? Label { get; set; } // null = Standard size
            public decimal Price { get; set; }
        }

        // Same formula as the portal's public._size_tier_price: base + % + fixed amount, rounded to the
        // nearest RoundTo (0 = to the centavo), never below the base price.
        internal static decimal ComputeSizeTierPrice(decimal basePrice, decimal markupPercent, decimal markupAmount, decimal roundTo)
        {
            decimal raw = basePrice * (1m + markupPercent / 100m) + markupAmount;
            decimal price = roundTo > 0
                ? Math.Round(raw / roundTo, MidpointRounding.AwayFromZero) * roundTo
                : Math.Round(raw, 2, MidpointRounding.AwayFromZero);
            return Math.Max(basePrice, price);
        }

        private List<SaleSizeTier> LoadSaleSizeTiers(string? itemCode, decimal basePrice)
        {
            var tiers = new List<SaleSizeTier>();
            if (string.IsNullOrWhiteSpace(itemCode))
                return tiers;

            try
            {
                using var connection = new SqlConnection(connectionString);
                connection.Open();
                using var cmd = new SqlCommand(@"
IF OBJECT_ID('dbo.ItemSizeTier', 'U') IS NOT NULL
    SELECT SizeLabel, MarkupPercent, MarkupAmount, RoundTo
    FROM dbo.ItemSizeTier
    WHERE ItemCode = @itemCode
    ORDER BY SortOrder", connection);
                cmd.Parameters.AddWithValue("@itemCode", itemCode.Trim());
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    tiers.Add(new SaleSizeTier
                    {
                        Label = reader["SizeLabel"]?.ToString() ?? string.Empty,
                        Price = ComputeSizeTierPrice(basePrice,
                            Convert.ToDecimal(reader["MarkupPercent"]),
                            Convert.ToDecimal(reader["MarkupAmount"]),
                            Convert.ToDecimal(reader["RoundTo"]))
                    });
                }
            }
            catch
            {
                // Size pricing is optional - never block a sale over it.
                tiers.Clear();
            }

            return tiers;
        }

        // null = the item is not size-priced (add as usual).
        private SaleSizeChoice? PromptForSaleSize(string? itemCode, string itemName, decimal basePrice)
        {
            var tiers = LoadSaleSizeTiers(itemCode, basePrice);
            if (tiers.Count == 0)
                return null;

            var options = new List<SaleSizeTier> { new SaleSizeTier { Label = string.Empty, Price = basePrice } };
            options.AddRange(tiers);

            SaleSizeChoice choice = new SaleSizeChoice { IsCancelled = true };

            using var form = new ThemedForm
            {
                Text = "Choose Size",
                Size = new Size(520, Math.Min(160 + options.Count * 62, 620)),
                StartPosition = FormStartPosition.CenterParent,
                BackColor = Color.White,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false
            };

            var titleLabel = new Label
            {
                Text = $"Size for: {itemName}",
                Location = new Point(20, 15),
                Size = new Size(470, 28),
                Font = new Font("Arial", 12, FontStyle.Bold)
            };

            var flow = new FlowLayoutPanel
            {
                Location = new Point(20, 50),
                Size = new Size(470, options.Count * 62 + 10),
                AutoScroll = true,
                FlowDirection = FlowDirection.TopDown,
                WrapContents = false
            };
            flow.MaximumSize = new Size(470, 460);

            foreach (var option in options)
            {
                bool isStandard = option.Label.Length == 0;
                var button = new Button
                {
                    Text = (isStandard ? "STANDARD SIZE" : $"SIZE {option.Label}") + $"   -   P{option.Price:N2}",
                    Size = new Size(440, 52),
                    Margin = new Padding(0, 0, 0, 8),
                    BackColor = isStandard ? Color.DimGray : Color.MediumSlateBlue,
                    ForeColor = Color.White,
                    Font = new Font("Arial", 11, FontStyle.Bold),
                    UseVisualStyleBackColor = false,
                    Tag = option
                };
                button.Click += (s, e) =>
                {
                    var picked = (SaleSizeTier)((Button)s!).Tag!;
                    choice = new SaleSizeChoice
                    {
                        IsCancelled = false,
                        Label = picked.Label.Length == 0 ? null : picked.Label,
                        Price = picked.Price
                    };
                    form.DialogResult = DialogResult.OK;
                    form.Close();
                };
                flow.Controls.Add(button);
            }

            var cancelButton = new Button
            {
                Text = "Cancel",
                Size = new Size(100, 35),
                Location = new Point(390, flow.Bottom + 8),
                BackColor = Color.DimGray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            cancelButton.Click += (s, e) => form.Close();
            form.ClientSize = new Size(form.ClientSize.Width, cancelButton.Bottom + 15);

            form.Controls.Add(titleLabel);
            form.Controls.Add(flow);
            form.Controls.Add(cancelButton);
            form.CancelButton = cancelButton;

            form.ShowDialog(this);
            return choice;
        }

        // "SHBRTG" + 10-11" -> "SHBRTG - Size 10-11"" (same naming as the portal's sizeLineName).
        private static string AppendSizeToName(string? name, string sizeLabel)
        {
            string baseName = name?.Trim() ?? string.Empty;
            return baseName.Length == 0 ? $"Size {sizeLabel}" : $"{baseName} - Size {sizeLabel}";
        }
    }
}
