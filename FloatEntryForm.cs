using System;
using System.Data.SqlClient;
using System.Drawing;
using System.Drawing.Printing;
using System.Text;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class FloatEntryForm : Form
    {
    private readonly string connectionString = GlobalSettings.ConnectionString;
        private Label? titleLabel;
        private List<TextBox> coinTextBoxes = new();
        private List<TextBox> noteTextBoxes = new();
        private Form? loginFormToClose;
        private List<Label> coinLabels = new();
        private List<Label> noteLabels = new();
        private List<Label> coinTotalLabels = new();
        private List<Label> noteTotalLabels = new();
        private Label? grandTotalLabel;
        private Button? postButton;
        private Button? cancelButton;
        private decimal grandTotal = 0m;
        private string userId;

        public FloatEntryForm(string userId, Form? loginForm = null)
        {
            KeyPreview = true;
            this.KeyDown += FloatEntryForm_KeyDown;
            this.userId = userId;
            loginFormToClose = loginForm;
            InitializeComponent();
            this.Text = "Float Entry";
            this.StartPosition = FormStartPosition.CenterParent;
            this.Size = new Size(1400, 800);
            this.MinimumSize = new Size(1400, 800);
            if (titleLabel != null)
                titleLabel.Text = $"Float Entry for {userId}";
        }

        private void InitializeComponent()
        {
            titleLabel = new Label
            {
                Text = "Float Entry",
                Location = new Point(30, 20),
                Size = new Size(1340, 40),
                Font = new Font("Arial", 18, FontStyle.Bold),
                TextAlign = ContentAlignment.MiddleCenter,
                BackColor = Color.LightBlue
            };

            int startY = 80;
            int labelX = 50, spacingY = 60;
            int coinCount = 0, noteCount = 0;

            decimal[] coinDenominations = { 0.25m, 0.5m, 1, 2, 5, 10 };
            decimal[] noteDenominations = { 20, 50, 100, 200, 500, 1000 };

            // Coin Panel
            var coinPanel = new Panel
            {
                Location = new Point(labelX, startY),
                Size = new Size(1300, coinDenominations.Length / 2 * spacingY + 80),
                BorderStyle = BorderStyle.FixedSingle,
                BackColor = Color.LightGray
            };
            var coinHeader = new Label
            {
                Text = "COINS",
                Location = new Point(20, 15),
                Size = new Size(200, 35),
                Font = new Font("Arial", 16, FontStyle.Bold),
                ForeColor = Color.DarkBlue
            };
            coinPanel.Controls.Add(coinHeader);

            for (int i = 0; i < coinDenominations.Length; i++)
            {
                int col = i % 2;
                int row = i / 2;
                int yOffset = 60 + row * spacingY;
                var lbl = new Label
                {
                    Text = $"P{coinDenominations[i]:F2}",
                    Location = new Point(50 + col * 650, yOffset),
                    Size = new Size(200, 35),
                    Font = new Font("Arial", 14, FontStyle.Bold),
                    TextAlign = ContentAlignment.MiddleLeft
                };
                var tb = new TextBox
                {
                    Location = new Point(260 + col * 650, yOffset),
                    Size = new Size(150, 35),
                    Font = new Font("Arial", 14),
                    Text = "0",
                    TextAlign = HorizontalAlignment.Center
                };
                var totalLbl = new Label
                {
                    Text = "P0.00",
                    Location = new Point(420 + col * 650, yOffset),
                    Size = new Size(150, 35),
                    Font = new Font("Arial", 14, FontStyle.Bold),
                    ForeColor = Color.DarkGreen,
                    TextAlign = ContentAlignment.MiddleLeft
                };
                tb.TextChanged += (s, e) => UpdateGrandTotal();
                coinLabels.Add(lbl);
                coinTextBoxes.Add(tb);
                coinTotalLabels.Add(totalLbl);
                coinPanel.Controls.Add(lbl);
                coinPanel.Controls.Add(tb);
                coinPanel.Controls.Add(totalLbl);
                coinCount++;
            }

            // Note Panel
            var notePanel = new Panel
            {
                Location = new Point(labelX, startY + coinPanel.Height + 30),
                Size = new Size(1300, noteDenominations.Length / 2 * spacingY + 80),
                BorderStyle = BorderStyle.FixedSingle,
                BackColor = Color.LightYellow
            };
            var noteHeader = new Label
            {
                Text = "NOTES",
                Location = new Point(20, 15),
                Size = new Size(200, 35),
                Font = new Font("Arial", 16, FontStyle.Bold),
                ForeColor = Color.DarkRed
            };
            notePanel.Controls.Add(noteHeader);

            for (int i = 0; i < noteDenominations.Length; i++)
            {
                int col = i % 2;
                int row = i / 2;
                int yOffset = 60 + row * spacingY;
                var lbl = new Label
                {
                    Text = $"P{noteDenominations[i]:F2}",
                    Location = new Point(50 + col * 650, yOffset),
                    Size = new Size(200, 35),
                    Font = new Font("Arial", 14, FontStyle.Bold),
                    TextAlign = ContentAlignment.MiddleLeft
                };
                var tb = new TextBox
                {
                    Location = new Point(260 + col * 650, yOffset),
                    Size = new Size(150, 35),
                    Font = new Font("Arial", 14),
                    Text = "0",
                    TextAlign = HorizontalAlignment.Center
                };
                var totalLbl = new Label
                {
                    Text = "P0.00",
                    Location = new Point(420 + col * 650, yOffset),
                    Size = new Size(150, 35),
                    Font = new Font("Arial", 14, FontStyle.Bold),
                    ForeColor = Color.DarkGreen,
                    TextAlign = ContentAlignment.MiddleLeft
                };
                tb.TextChanged += (s, e) => UpdateGrandTotal();
                noteLabels.Add(lbl);
                noteTextBoxes.Add(tb);
                noteTotalLabels.Add(totalLbl);
                notePanel.Controls.Add(lbl);
                notePanel.Controls.Add(tb);
                notePanel.Controls.Add(totalLbl);
                noteCount++;
            }

            grandTotalLabel = new Label
            {
                Text = "GRAND TOTAL: P0.00",
                Location = new Point(labelX, notePanel.Location.Y + notePanel.Height + 30),
                Size = new Size(500, 40),
                Font = new Font("Arial", 16, FontStyle.Bold),
                ForeColor = Color.DarkGreen,
                TextAlign = ContentAlignment.MiddleLeft,
                BackColor = Color.LightGreen
            };

            postButton = new Button
            {
                Text = "POST FLOAT",
                Location = new Point(labelX, notePanel.Location.Y + notePanel.Height + 90),
                Size = new Size(150, 45),
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 12, FontStyle.Bold)
            };
            postButton.Click += PostButton_Click;

            cancelButton = new Button
            {
                Text = "CANCEL",
                Location = new Point(labelX + 170, notePanel.Location.Y + notePanel.Height + 90),
                Size = new Size(150, 45),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 12, FontStyle.Bold)
            };
            cancelButton.Click += (s, e) => { this.DialogResult = DialogResult.Cancel; this.Close(); };

            this.Controls.Add(titleLabel);
            this.Controls.Add(coinPanel);
            this.Controls.Add(notePanel);
            this.Controls.Add(grandTotalLabel);
            this.Controls.Add(postButton);
            this.Controls.Add(cancelButton);
        }

        private void Grid_EditingControlShowing(object sender, DataGridViewEditingControlShowingEventArgs e)
        {
            var grid = sender as DataGridView;
            if (grid != null && grid.CurrentCell.ColumnIndex == 1)
            {
                var tb = e.Control as TextBox;
                if (tb != null)
                {
                    tb.KeyPress -= GridCount_KeyPress;
                    tb.KeyPress += GridCount_KeyPress;
                }
            }
        }

        private void GridCount_KeyPress(object? sender, KeyPressEventArgs e)
        {
            if (!char.IsControl(e.KeyChar) && !char.IsDigit(e.KeyChar))
            {
                e.Handled = true;
            }
        }

        private void Grid_CellValueChanged(object? sender, DataGridViewCellEventArgs e)
        {
            var grid = sender as DataGridView;
            if (grid != null && e.RowIndex >= 0 && e.ColumnIndex == 1)
            {
                decimal denom = Convert.ToDecimal(grid.Rows[e.RowIndex].Cells[0].Value);
                int count = 0;
                int.TryParse(grid.Rows[e.RowIndex].Cells[1].Value?.ToString(), out count);
                grid.Rows[e.RowIndex].Cells[2].Value = (denom * count).ToString("F2");
                UpdateGrandTotal();
            }
        }

        private void UpdateGrandTotal()
        {
            grandTotal = 0m;
            decimal[] coinDenominations = { 0.25m, 0.5m, 1, 2, 5, 10 };
            decimal[] noteDenominations = { 20, 50, 100, 200, 500, 1000 };
            for (int i = 0; i < coinTextBoxes.Count; i++)
            {
                int count = 0;
                int.TryParse(coinTextBoxes[i].Text, out count);
                decimal lineTotal = coinDenominations[i] * count;
                coinTotalLabels[i].Text = $"P{lineTotal:F2}";
                grandTotal += lineTotal;
            }
            for (int i = 0; i < noteTextBoxes.Count; i++)
            {
                int count = 0;
                int.TryParse(noteTextBoxes[i].Text, out count);
                decimal lineTotal = noteDenominations[i] * count;
                noteTotalLabels[i].Text = $"P{lineTotal:F2}";
                grandTotal += lineTotal;
            }
            if (grandTotalLabel != null)
                grandTotalLabel.Text = $"GRAND TOTAL: P{grandTotal:F2}";
        }

        private void PostButton_Click(object? sender, EventArgs e)
        {
            try
            {
                // Use centralized receipt number generator so float entries are in the main RS- sequence
                string receiptNo = FunctionEvents.GenerateCentralizedReceiptNumber();
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    decimal[] coinDenominations = { 0.25m, 0.5m, 1, 2, 5, 10 };
                    decimal[] noteDenominations = { 20, 50, 100, 200, 500, 1000 };
                    int lineNo = 1;
                    string date = DateTime.Now.ToString("yyyy-MM-dd");
                    string time = DateTime.Now.ToString("HH:mm:ss");
                    string createdDate = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
                    for (int i = 0; i < coinTextBoxes.Count; i++)
                    {
                        int qty = 0;
                        int.TryParse(coinTextBoxes[i].Text, out qty);
                        decimal totalAmount = coinDenominations[i] * qty;
                        if (qty > 0)
                        {
                            var cmd = new SqlCommand(@"INSERT INTO CashFloatLines (Date, time, UserID, ReceiptNo, [LineNo], Denomination, Qty, TotalAmount, CreatedDate) VALUES (@date, @time, @userid, @receiptno, @lineno, @denom, @qty, @totalamount, @createddate)", connection);
                            cmd.Parameters.AddWithValue("@date", date);
                            cmd.Parameters.AddWithValue("@time", time);
                            cmd.Parameters.AddWithValue("@userid", userId);
                            cmd.Parameters.AddWithValue("@receiptno", receiptNo);
                            cmd.Parameters.AddWithValue("@lineno", lineNo);
                            cmd.Parameters.AddWithValue("@denom", coinDenominations[i]);
                            cmd.Parameters.AddWithValue("@qty", qty);
                            cmd.Parameters.AddWithValue("@totalamount", totalAmount);
                            cmd.Parameters.AddWithValue("@createddate", createdDate);
                            cmd.ExecuteNonQuery();
                            lineNo++;
                        }
                    }
                    for (int i = 0; i < noteTextBoxes.Count; i++)
                    {
                        int qty = 0;
                        int.TryParse(noteTextBoxes[i].Text, out qty);
                        decimal totalAmount = noteDenominations[i] * qty;
                        if (qty > 0)
                        {
                            var cmd = new SqlCommand(@"INSERT INTO CashFloatLines (Date, time, UserID, ReceiptNo, [LineNo], Denomination, Qty, TotalAmount, CreatedDate) VALUES (@date, @time, @userid, @receiptno, @lineno, @denom, @qty, @totalamount, @createddate)", connection);
                            cmd.Parameters.AddWithValue("@date", date);
                            cmd.Parameters.AddWithValue("@time", time);
                            cmd.Parameters.AddWithValue("@userid", userId);
                            cmd.Parameters.AddWithValue("@receiptno", receiptNo);
                            cmd.Parameters.AddWithValue("@lineno", lineNo);
                            cmd.Parameters.AddWithValue("@denom", noteDenominations[i]);
                            cmd.Parameters.AddWithValue("@qty", qty);
                            cmd.Parameters.AddWithValue("@totalamount", totalAmount);
                            cmd.Parameters.AddWithValue("@createddate", createdDate);
                            cmd.ExecuteNonQuery();
                            lineNo++;
                        }
                    }

                    // --- Call TransactionListForm to write transaction header ---
                    int storeNo = 1; // TODO: Replace with actual store number logic
                    int posTerminalNo = 1; // TODO: Replace with actual POS terminal number logic
                    int transactionNo = 1;
                    // Get next transaction number for this storeNo and posTerminalNo
                    var transCmd = new SqlCommand(@"SELECT ISNULL(MAX(TransactionNo), 0) + 1 FROM TransactionHeader WHERE StoreNo = @storeNo AND POSTerminalNo = @posTerminalNo", connection);
                    transCmd.Parameters.AddWithValue("@storeNo", storeNo);
                    transCmd.Parameters.AddWithValue("@posTerminalNo", posTerminalNo);
                    transactionNo = Convert.ToInt32(transCmd.ExecuteScalar());

                    var transactionForm = new TransactionListForm();
                    transactionForm.WriteCashFloatEntryTransactionHeader(
                        storeNo,
                        posTerminalNo,
                        transactionNo,
                        receiptNo, // Pass the receiptNo
                        userId,
                        grandTotal,
                        "Float entry posted"
                    );
                }

                // Print the cash float receipt
                FunctionEvents.PrintCashFloatReceipt(receiptNo, userId, grandTotal, coinTextBoxes, noteTextBoxes);

                MessageBox.Show($"Float entry posted successfully.\nGrand Total: P{grandTotal:F2}", "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
                this.DialogResult = DialogResult.OK;
                this.Close();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error posting float entry: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void FloatEntryForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }
    }
}


