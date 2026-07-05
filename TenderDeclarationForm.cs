using System;
using System.Drawing;
using System.Windows.Forms;
using System.Collections.Generic;

namespace AquariumPOS
{
    public class TenderDeclarationForm : Form
    {
        private Dictionary<decimal, TextBox> denominationInputs = new Dictionary<decimal, TextBox>();
        private Dictionary<decimal, Label> denominationTotalLabels = new Dictionary<decimal, Label>();
        private Label grandTotalLabel;
        private Button postButton;
        private Button cancelButton;

        private decimal[] coinDenominations = new decimal[] { 0.25m, 0.50m, 1.00m, 2.00m, 5.00m, 10.00m };
        private decimal[] noteDenominations = new decimal[] { 20.00m, 50.00m, 100.00m, 200.00m, 500.00m, 1000.00m };

        private string receiptNo;

        public TenderDeclarationForm(string receiptNo)
        {
            KeyPreview = true;
            this.KeyDown += TenderDeclarationForm_KeyDown;

            this.receiptNo = receiptNo;
            this.Text = "Tender Declaration";
            this.Size = new Size(1340, 800);
            this.StartPosition = FormStartPosition.CenterParent;
            this.BackColor = Color.White;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.MinimizeBox = false;

            // Header panel
            var headerPanel = new Panel
            {
                Location = new Point(30, 30),
                Size = new Size(1280, 70),
                BackColor = Color.LightBlue,
                BorderStyle = BorderStyle.None
            };

            var titleLabel = new Label
            {
                Text = "Tender Declaration",
                Font = new Font("Arial", 18, FontStyle.Bold),
                ForeColor = Color.DarkBlue,
                Location = new Point(0, 0),
                Size = new Size(1280, 70),
                TextAlign = ContentAlignment.MiddleCenter,
                BackColor = Color.LightBlue
            };
            headerPanel.Controls.Add(titleLabel);
            this.Controls.Add(headerPanel);

            // Coins panel
            var coinsPanel = new Panel
            {
                Location = new Point(50, 140),
                Size = new Size(1240, 240),
                BackColor = Color.Gainsboro,
                BorderStyle = BorderStyle.FixedSingle
            };

            var coinsLabel = new Label
            {
                Text = "COINS",
                Font = new Font("Arial", 20, FontStyle.Bold),
                ForeColor = Color.DarkBlue,
                Location = new Point(75, 15),
                Size = new Size(150, 35)
            };
            coinsPanel.Controls.Add(coinsLabel);

            // Coin denominations layout - 3 rows of 2 columns
            CreateDenominationControls(coinsPanel, coinDenominations, 80, Color.Gainsboro);
            this.Controls.Add(coinsPanel);

            // Notes panel
            var notesPanel = new Panel
            {
                Location = new Point(50, 400),
                Size = new Size(1240, 240),
                BackColor = Color.LemonChiffon,
                BorderStyle = BorderStyle.FixedSingle
            };

            var notesLabel = new Label
            {
                Text = "NOTES",
                Font = new Font("Arial", 20, FontStyle.Bold),
                ForeColor = Color.DarkRed,
                Location = new Point(75, 15),
                Size = new Size(150, 35)
            };
            notesPanel.Controls.Add(notesLabel);

            // Note denominations layout - 3 rows of 2 columns  
            CreateDenominationControls(notesPanel, noteDenominations, 80, Color.LemonChiffon);
            this.Controls.Add(notesPanel);

            // Grand total panel
            grandTotalLabel = new Label
            {
                Text = "GRAND TOTAL: P0.00",
                Font = new Font("Arial", 20, FontStyle.Bold),
                ForeColor = Color.Black,
                BackColor = Color.LightGreen,
                Location = new Point(50, 660),
                Size = new Size(535, 50),
                TextAlign = ContentAlignment.MiddleLeft,
                BorderStyle = BorderStyle.None
            };
            this.Controls.Add(grandTotalLabel);

            // Buttons
            postButton = new Button
            {
                Text = "POST DECLARATION",
                Location = new Point(50, 730),
                Size = new Size(180, 40),
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 12, FontStyle.Bold),
                FlatStyle = FlatStyle.Flat
            };
            postButton.Click += (s, e) => PostDeclaration();
            this.Controls.Add(postButton);

            cancelButton = new Button
            {
                Text = "CANCEL",
                Location = new Point(250, 730),
                Size = new Size(120, 40),
                BackColor = Color.DarkGray,
                ForeColor = Color.White,
                Font = new Font("Arial", 12, FontStyle.Bold),
                FlatStyle = FlatStyle.Flat
            };
            cancelButton.Click += (s, e) => this.Close();
            this.Controls.Add(cancelButton);

            // REPORTS button
            // var reportsButton = new Button
            // {
            //     Text = "REPORTS",
            //     Location = new Point(400, 730),
            //     Size = new Size(140, 40),
            //     BackColor = Color.MediumSlateBlue,
            //     ForeColor = Color.White,
            //     Font = new Font("Arial", 12, FontStyle.Bold),
            //     FlatStyle = FlatStyle.Flat
            // };
            // reportsButton.Click += (s, e) => AquariumPOS.PostingEvents.PrintXReport(receiptNo);
            // this.Controls.Add(reportsButton);
        }

        private void CreateDenominationControls(Panel parentPanel, decimal[] denominations, int startY, Color backgroundColor)
        {
            int x1 = 100;  // First column X position
            int x2 = 620;  // Second column X position  
            int currentY = startY;
            int rowHeight = 50;

            for (int i = 0; i < denominations.Length; i++)
            {
                decimal denom = denominations[i];
                int xPos = (i % 2 == 0) ? x1 : x2;  // Alternate between columns

                // Denomination label
                var denomLabel = new Label
                {
                    Text = $"P{denom:F2}",
                    Font = new Font("Arial", 16, FontStyle.Bold),
                    Location = new Point(xPos, currentY),
                    Size = new Size(100, 40),
                    TextAlign = ContentAlignment.MiddleLeft,
                    BackColor = backgroundColor
                };
                parentPanel.Controls.Add(denomLabel);

                // Quantity input textbox
                var input = new TextBox
                {
                    Text = "0",
                    Location = new Point(xPos + 120, currentY + 5),
                    Size = new Size(80, 30),
                    TextAlign = HorizontalAlignment.Center,
                    Font = new Font("Arial", 14),
                    BorderStyle = BorderStyle.FixedSingle
                };
                parentPanel.Controls.Add(input);
                denominationInputs[denom] = input;

                // Total amount label
                var totalLabel = new Label
                {
                    Text = "P0.00",
                    Font = new Font("Arial", 16, FontStyle.Bold),
                    ForeColor = Color.Green,
                    Location = new Point(xPos + 220, currentY),
                    Size = new Size(100, 40),
                    TextAlign = ContentAlignment.MiddleLeft,
                    BackColor = backgroundColor
                };
                parentPanel.Controls.Add(totalLabel);
                denominationTotalLabels[denom] = totalLabel;

                input.TextChanged += (s, e) => UpdateTotals();

                // Move to next row after every 2 items
                if (i % 2 == 1)
                {
                    currentY += rowHeight;
                }
            }
        }

        private void UpdateTotals()
        {
            decimal grandTotal = 0;

            foreach (var kvp in denominationInputs)
            {
                decimal denom = kvp.Key;
                int qty = 0;
                int.TryParse(kvp.Value.Text, out qty);
                decimal subtotal = denom * qty;
                grandTotal += subtotal;

                // Update the corresponding total label
                if (denominationTotalLabels.ContainsKey(denom))
                {
                    denominationTotalLabels[denom].Text = $"P{subtotal:F2}";
                }
            }

            grandTotalLabel.Text = $"GRAND TOTAL: P{grandTotal:F2}";
        }

        private void PostDeclaration()
        {
            try
            {
                if (GlobalSettings.IsTenderDeclarationRestrictedTime(DateTime.Now))
                {
                    throw new InvalidOperationException(GlobalSettings.TenderDeclarationRestrictedMessage);
                }

                string connectionString = GlobalSettings.ConnectionString;

                using (var connection = new System.Data.SqlClient.SqlConnection(connectionString))
                {
                    connection.Open();

                    // Use structured arrays like POST FLOAT
                    decimal[] coinDenominations = { 0.25m, 0.5m, 1, 2, 5, 10 };
                    decimal[] noteDenominations = { 20, 50, 100, 200, 500, 1000 };
                    int lineNo = 1;
                    string date = DateTime.Now.ToString("yyyy-MM-dd");
                    string time = DateTime.Now.ToString("HH:mm:ss");
                    string createdDate = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");

                    // Generate EODID using running number from TransactionHeader
                    string eodID = "EOD-RS000000001";
                    string? lastEODID = string.Empty;
                    using (var eodConnection = new System.Data.SqlClient.SqlConnection(connectionString))
                    {
                        eodConnection.Open();
                        string sql = "SELECT TOP 1 EODID FROM TransactionHeader WHERE EODID IS NOT NULL AND EODID <> '' ORDER BY EODID DESC";
                        using (var cmd = new System.Data.SqlClient.SqlCommand(sql, eodConnection))
                        {
                            var result = cmd.ExecuteScalar();
                            if (result != null && result != DBNull.Value)
                            {
                                lastEODID = result?.ToString();
                            }
                        }
                    }
                    if (!string.IsNullOrEmpty(lastEODID))
                    {
                        var match = System.Text.RegularExpressions.Regex.Match(lastEODID, @"EOD-RS(\d{9})");
                        if (match.Success)
                        {
                            long lastNum = long.Parse(match.Groups[1].Value);
                            eodID = $"EOD-RS{(lastNum + 1):D9}";
                        }
                    }

                    // Get next EntryNo
                    int nextEntryNo = 1;
                    using (var entryNoCmd = new System.Data.SqlClient.SqlCommand("SELECT ISNULL(MAX(EntryNo), 0) + 1 FROM TenderDeclLines", connection))
                    {
                        var result = entryNoCmd.ExecuteScalar();
                        if (result != null && int.TryParse(result.ToString(), out int val))
                            nextEntryNo = val;
                    }

                    // Process coin denominations
                    for (int i = 0; i < coinDenominations.Length; i++)
                    {
                        int qty = 0;
                        if (denominationInputs.ContainsKey(coinDenominations[i]))
                        {
                            int.TryParse(denominationInputs[coinDenominations[i]].Text, out qty);
                        }
                        decimal totalAmount = coinDenominations[i] * qty;
                        if (qty > 0)
                        {
                            var cmd = new System.Data.SqlClient.SqlCommand(@"INSERT INTO TenderDeclLines (EntryNo, Date, Time, UserID, ReceiptNo, [LineNo], [Denomination], [Qty], [TotalAmount], [CreatedDate], [EODID]) VALUES (@EntryNo, @Date, @Time, @UserID, @ReceiptNo, @LineNo, @Denomination, @Qty, @TotalAmount, @CreatedDate, @EODID)", connection);
                            cmd.Parameters.AddWithValue("@EntryNo", nextEntryNo);
                            cmd.Parameters.AddWithValue("@Date", date);
                            cmd.Parameters.AddWithValue("@Time", time);
                            cmd.Parameters.AddWithValue("@UserID", "admin");
                            cmd.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                            cmd.Parameters.AddWithValue("@LineNo", lineNo);
                            cmd.Parameters.AddWithValue("@Denomination", coinDenominations[i]);
                            cmd.Parameters.AddWithValue("@Qty", qty);
                            cmd.Parameters.AddWithValue("@TotalAmount", totalAmount);
                            cmd.Parameters.AddWithValue("@CreatedDate", createdDate);
                            cmd.Parameters.AddWithValue("@EODID", eodID);
                            cmd.ExecuteNonQuery();
                            nextEntryNo++;
                            lineNo++;
                        }
                    }

                    // Process note denominations
                    for (int i = 0; i < noteDenominations.Length; i++)
                    {
                        int qty = 0;
                        if (denominationInputs.ContainsKey(noteDenominations[i]))
                        {
                            int.TryParse(denominationInputs[noteDenominations[i]].Text, out qty);
                        }
                        decimal totalAmount = noteDenominations[i] * qty;
                        if (qty > 0)
                        {
                            var cmd = new System.Data.SqlClient.SqlCommand(@"INSERT INTO TenderDeclLines (EntryNo, Date, Time, UserID, ReceiptNo, [LineNo], [Denomination], [Qty], [TotalAmount], [CreatedDate], [EODID]) VALUES (@EntryNo, @Date, @Time, @UserID, @ReceiptNo, @LineNo, @Denomination, @Qty, @TotalAmount, @CreatedDate, @EODID)", connection);
                            cmd.Parameters.AddWithValue("@EntryNo", nextEntryNo);
                            cmd.Parameters.AddWithValue("@Date", date);
                            cmd.Parameters.AddWithValue("@Time", time);
                            cmd.Parameters.AddWithValue("@UserID", "admin");
                            cmd.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                            cmd.Parameters.AddWithValue("@LineNo", lineNo);
                            cmd.Parameters.AddWithValue("@Denomination", noteDenominations[i]);
                            cmd.Parameters.AddWithValue("@Qty", qty);
                            cmd.Parameters.AddWithValue("@TotalAmount", totalAmount);
                            cmd.Parameters.AddWithValue("@CreatedDate", createdDate);
                            cmd.Parameters.AddWithValue("@EODID", eodID);
                            cmd.ExecuteNonQuery();
                            nextEntryNo++;
                            lineNo++;
                        }
                    }

                    // Calculate total declared amount
                    decimal totalDeclared = 0;
                    foreach (var kvp in denominationInputs)
                    {
                        int qty = 0;
                        int.TryParse(kvp.Value.Text, out qty);
                        totalDeclared += kvp.Key * qty;
                    }


                    // Call WriteSalesTransactionHeader with type = 'TenderDecl'
                    var mainForm = this.Owner as AquariumPOS.MainForm;
                    if (mainForm != null)
                    {
                        mainForm.WriteSalesTransactionHeader(receiptNo, "TenderDecl", totalDeclared, eodID, "");
                        // Print receipt after tender declaration
                        mainForm.PrintTenderDeclReceipt(receiptNo);
                        // Print X Report after tender declaration
                        AquariumPOS.PostingEvents.PrintXReport(receiptNo);
                        FunctionEvents.UpdateEODIDForAllTables(connection, eodID);
                    }
                    else
                    {
                        MessageBox.Show("Warning: Could not create transaction header - MainForm reference not found.",
                                      "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }

                    MessageBox.Show($"Tender declaration posted successfully!\n\nReceipt No: {receiptNo}\nEOD ID: {eodID}\nTotal Declared: P{totalDeclared:F2}",
                                  "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    this.Close();
                    if (mainForm != null)
                    {
                        mainForm.Close();

                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error posting tender declaration: {ex.Message}", "Error",
                              MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void TenderDeclarationForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }
    }
}
