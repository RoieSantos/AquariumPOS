using System;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class FloatEntryViewForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private Label? titleLabel;
        private DataGridView? dgvFloatEntryLines;
        private Label? grandTotalLabel;
        private Button? closeButton;
        private int storeNo;
        private int posTerminalNo;
        private int transactionNo;
        private string userId;

        public FloatEntryViewForm(int storeNo, int posTerminalNo, int transactionNo, string userId)
        {
            KeyPreview = true;
            this.KeyDown += FloatEntryViewForm_KeyDown;

            this.storeNo = storeNo;
            this.posTerminalNo = posTerminalNo;
            this.transactionNo = transactionNo;
            this.userId = userId;
            InitializeComponent();
            LoadFloatEntryData();
            this.Text = "Float Entry Details";
            this.StartPosition = FormStartPosition.CenterParent;
            this.Size = new Size(1000, 600);
            this.MinimumSize = new Size(800, 500);
        }

        private void InitializeComponent()
        {
            titleLabel = new Label
            {
                Text = $"Float Entry Details - Transaction #{transactionNo}",
                Location = new Point(20, 20),
                Size = new Size(940, 40),
                Font = new Font("Arial", 16, FontStyle.Bold),
                TextAlign = ContentAlignment.MiddleCenter,
                BackColor = Color.LightBlue
            };

            dgvFloatEntryLines = new DataGridView
            {
                Location = new Point(20, 80),
                Size = new Size(940, 400),
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                BackgroundColor = Color.White,
                BorderStyle = BorderStyle.Fixed3D
            };

            grandTotalLabel = new Label
            {
                Text = "Grand Total: $0.00",
                Location = new Point(20, 500),
                Size = new Size(400, 30),
                Font = new Font("Arial", 14, FontStyle.Bold),
                ForeColor = Color.DarkGreen,
                TextAlign = ContentAlignment.MiddleLeft
            };

            closeButton = new Button
            {
                Text = "Close",
                Location = new Point(840, 500),
                Size = new Size(120, 40),
                Font = new Font("Arial", 12),
                BackColor = Color.Gray,
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat
            };
            closeButton.Click += CloseButton_Click;

            this.Controls.Add(titleLabel);
            this.Controls.Add(dgvFloatEntryLines);
            this.Controls.Add(grandTotalLabel);
            this.Controls.Add(closeButton);
        }

        private void LoadFloatEntryData()
        {
            try
            {
                using (SqlConnection connection = new SqlConnection(connectionString))
                {
                    connection.Open();

                    // Get the ReceiptNo from the TransactionHeader first
                    string receiptNo = "";
                    var headerCmd = new SqlCommand(@"
                        SELECT ReceiptNo, SubTotal 
                        FROM TransactionHeader 
                        WHERE StoreNo = @storeNo 
                        AND POSTerminalNo = @posTerminalNo 
                        AND TransactionNo = @transactionNo 
                        AND Type = 'float_entry'", connection);
                    headerCmd.Parameters.AddWithValue("@storeNo", storeNo);
                    headerCmd.Parameters.AddWithValue("@posTerminalNo", posTerminalNo);
                    headerCmd.Parameters.AddWithValue("@transactionNo", transactionNo);

                    using (var reader = headerCmd.ExecuteReader())
                    {
                        if (reader.Read())
                        {
                            receiptNo = reader["ReceiptNo"].ToString() ?? "";
                            decimal subTotal = Convert.ToDecimal(reader["SubTotal"]);
                            if (grandTotalLabel != null)
                                grandTotalLabel.Text = $"Grand Total: ${subTotal:F2}";
                        }
                        else
                        {
                            MessageBox.Show("No float entry transaction found with the specified details.", "Not Found", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                            return;
                        }
                    }

                    // Now load the cash float entry lines
                    var linesCmd = new SqlCommand(@"
                        SELECT 
                            LineNo,
                            Denomination,
                            Qty,
                            TotalAmount,
                            CASE 
                                WHEN Time IS NULL THEN ''
                                ELSE CONVERT(VARCHAR(8), Time, 108)
                            END AS Time,
                            Date
                        FROM CashFloatLines 
                        WHERE ReceiptNo = @receiptNo 
                        AND UserID = @userId
                        ORDER BY LineNo", connection);
                    linesCmd.Parameters.AddWithValue("@receiptNo", receiptNo);
                    linesCmd.Parameters.AddWithValue("@userId", userId);

                    var adapter = new SqlDataAdapter(linesCmd);
                    var dataTable = new System.Data.DataTable();
                    adapter.Fill(dataTable);

                    if (dgvFloatEntryLines != null)
                    {
                        dgvFloatEntryLines.DataSource = dataTable;

                        // Format columns
                        if (dgvFloatEntryLines.Columns["LineNo"] != null)
                        {
                            dgvFloatEntryLines.Columns["LineNo"].HeaderText = "Line #";
                            dgvFloatEntryLines.Columns["LineNo"].Width = 80;
                        }
                        if (dgvFloatEntryLines.Columns["Denomination"] != null)
                        {
                            dgvFloatEntryLines.Columns["Denomination"].HeaderText = "Denomination";
                            dgvFloatEntryLines.Columns["Denomination"].DefaultCellStyle.Format = "C2";
                        }
                        if (dgvFloatEntryLines.Columns["Qty"] != null)
                        {
                            dgvFloatEntryLines.Columns["Qty"].HeaderText = "Quantity";
                            dgvFloatEntryLines.Columns["Qty"].Width = 100;
                        }
                        if (dgvFloatEntryLines.Columns["TotalAmount"] != null)
                        {
                            dgvFloatEntryLines.Columns["TotalAmount"].HeaderText = "Total Amount";
                            dgvFloatEntryLines.Columns["TotalAmount"].DefaultCellStyle.Format = "C2";
                        }
                        if (dgvFloatEntryLines.Columns["Time"] != null)
                        {
                            dgvFloatEntryLines.Columns["Time"].HeaderText = "Time";
                            dgvFloatEntryLines.Columns["Time"].Width = 100;
                        }
                        if (dgvFloatEntryLines.Columns["Date"] != null)
                        {
                            dgvFloatEntryLines.Columns["Date"].HeaderText = "Date";
                            dgvFloatEntryLines.Columns["Date"].DefaultCellStyle.Format = "MM/dd/yyyy";
                        }
                    }

                    // Update title to show receipt number
                    if (titleLabel != null)
                        titleLabel.Text = $"Float Entry Details - Transaction #{transactionNo} (Receipt: {receiptNo})";
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading float entry data: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void CloseButton_Click(object sender, EventArgs e)
        {
            this.Close();
        }

        private void FloatEntryViewForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }
    }
}
