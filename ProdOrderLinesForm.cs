using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class ProdOrderLinesForm : Form
    {
    private readonly string connectionString = GlobalSettings.ConnectionString;
        private ListView aquariumListView, standListView;
        private TextBox searchTextBox;
        private Button searchButton, refreshButton;
        private Label aquariumLabel, standLabel;

        public ProdOrderLinesForm()
        {
            KeyPreview = true;
            this.KeyDown += ProdOrderLinesForm_KeyDown;

            Text = "Production Order Lines";
            WindowState = FormWindowState.Maximized;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.White;

            // // Search controls at top
            // searchTextBox = new TextBox
            // {
            //     PlaceholderText = "Search by Transaction No, Receipt No, ProdOrderNo, CustomerName...",
            //     Dock = DockStyle.Top,
            //     Height = 30,
            //     Font = new Font("Arial", 10)
            // };

            // searchButton = new Button
            // {
            //     Text = "Search",
            //     Dock = DockStyle.Top,
            //     Height = 40,
            //     BackColor = Color.DarkBlue,
            //     ForeColor = Color.White,
            //     Font = new Font("Arial", 10, FontStyle.Bold)
            // };
            // searchButton.Click += (s, e) => LoadOrderLines(searchTextBox.Text);

            // refreshButton = new Button
            // {
            //     Text = "Refresh",
            //     Dock = DockStyle.Top,
            //     Height = 40,
            //     BackColor = Color.Gray,
            //     ForeColor = Color.White,
            //     Font = new Font("Arial", 10, FontStyle.Bold)
            // };
            // refreshButton.Click += (s, e) => LoadOrderLines("");

            // Create split layout with two ListViews
            var splitContainer = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Vertical
            };

            // Set splitter distance after form is shown
            this.Shown += (s, e) =>
            {
                if (splitContainer.Width > 400)
                {
                    splitContainer.SplitterDistance = splitContainer.Width / 2;
                }
            };

            // AQUARIUM ListView with label
            aquariumLabel = new Label
            {
                Text = "AQUARIUM",
                Dock = DockStyle.Top,
                Height = 30,
                BackColor = Color.LightBlue,
                Font = new Font("Arial", 12, FontStyle.Bold),
                TextAlign = ContentAlignment.MiddleCenter
            };

            aquariumListView = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                GridLines = true,
                Font = new Font("Arial", 10)
            };
            SetupListViewColumns(aquariumListView);

            // STAND ListView with label
            standLabel = new Label
            {
                Text = "STAND",
                Dock = DockStyle.Top,
                Height = 30,
                BackColor = Color.LightGreen,
                Font = new Font("Arial", 12, FontStyle.Bold),
                TextAlign = ContentAlignment.MiddleCenter
            };

            standListView = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                GridLines = true,
                Font = new Font("Arial", 10)
            };
            SetupListViewColumns(standListView);

            // Add controls to split container
            splitContainer.Panel1.Controls.Add(aquariumListView);
            splitContainer.Panel1.Controls.Add(aquariumLabel);
            splitContainer.Panel2.Controls.Add(standListView);
            splitContainer.Panel2.Controls.Add(standLabel);

            // Add controls to form
            Controls.Add(splitContainer);
            Controls.Add(refreshButton);
            Controls.Add(searchButton);
            Controls.Add(searchTextBox);

            LoadOrderLines("");
        }

        private void SetupListViewColumns(ListView listView)
        {
            listView.Columns.Clear();
            listView.Columns.Add("Order Description", 370);
            listView.Columns.Add("Category", 90);
            listView.Columns.Add("Customer Name", 120);
            listView.Columns.Add("Date", 100);
            listView.Columns.Add("Due Date", 150);
        }

        private void LoadOrderLines(string searchTerm)
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    string query = "SELECT Order_Description, Category, CustomerName, Date, Time, DUEDate FROM Prod_Order_Lines";
                    if (!string.IsNullOrWhiteSpace(searchTerm))
                    {
                        query += " WHERE ReceiptNo LIKE @search OR CustomerName LIKE @search";
                    }
                    query += " ORDER BY TransactionNo ASC";
                    var command = new SqlCommand(query, connection);
                    if (!string.IsNullOrWhiteSpace(searchTerm))
                    {
                        command.Parameters.AddWithValue("@search", "%" + searchTerm + "%");
                    }
                    var adapter = new SqlDataAdapter(command);
                    var table = new DataTable();
                    adapter.Fill(table);

                    // Clear both ListViews
                    aquariumListView.Items.Clear();
                    standListView.Items.Clear();

                    // Populate ListViews based on Category
                    foreach (DataRow row in table.Rows)
                    {
                        string category = row["Category"]?.ToString() ?? "";
                        var item = new ListViewItem(row["Order_Description"]?.ToString() ?? "");
                        item.SubItems.Add(category);
                        item.SubItems.Add(row["CustomerName"]?.ToString() ?? "");
                        // Format Date
                        string dateStr = row["Date"]?.ToString() ?? "";
                        if (DateTime.TryParse(dateStr, out DateTime dateVal))
                            dateStr = dateVal.ToString("yyyy-MM-dd");
                        item.SubItems.Add(dateStr);
                        // Format Due Date
                        string dueDateStr = row["DUEDate"]?.ToString() ?? "";
                        if (DateTime.TryParse(dueDateStr, out DateTime dueDateVal))
                            dueDateStr = dueDateVal.ToString("yyyy-MM-dd");
                        item.SubItems.Add(dueDateStr);

                        if (category.Equals("AQUARIUM", StringComparison.OrdinalIgnoreCase))
                        {
                            aquariumListView.Items.Add(item);
                        }
                        else if (category.Equals("STAND", StringComparison.OrdinalIgnoreCase))
                        {
                            standListView.Items.Add(item);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading Production Order Lines: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        public void LoadOrderLinesByTransaction(string transactionNo)
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    // First, get the status code from Prod_Order_Header for this transaction
                    string headerQuery = @"SELECT Status FROM Prod_Order_Header WHERE TransactionNo = @TransactionNo";
                    var headerCmd = new SqlCommand(headerQuery, connection);
                    headerCmd.Parameters.AddWithValue("@TransactionNo", transactionNo);
                    var statusCode = headerCmd.ExecuteScalar()?.ToString() ?? "";

                    // Get the stage for this status from ProductionStatus
                    int stage = -1;
                    if (!string.IsNullOrEmpty(statusCode))
                    {
                        string stageQuery = @"SELECT Stages FROM ProductionStatus WHERE Code = @Code";
                        var stageCmd = new SqlCommand(stageQuery, connection);
                        stageCmd.Parameters.AddWithValue("@Code", statusCode);
                        var stageObj = stageCmd.ExecuteScalar();
                        if (stageObj != null && int.TryParse(stageObj.ToString(), out int s))
                            stage = s;
                    }

                    // Only show lines if stage == 1
                    if (stage == 1)
                    {
                        string query = "SELECT Order_Description, Category, CustomerName, Date, Time, DUEDate FROM Prod_Order_Lines WHERE TransactionNo = @transactionNo ORDER BY [LineNo] ASC";
                        var command = new SqlCommand(query, connection);
                        command.Parameters.AddWithValue("@transactionNo", transactionNo);
                        var adapter = new SqlDataAdapter(command);
                        var table = new DataTable();
                        adapter.Fill(table);

                        // Clear both ListViews
                        aquariumListView.Items.Clear();
                        standListView.Items.Clear();

                        // Populate ListViews based on Category
                        foreach (DataRow row in table.Rows)
                        {
                            string category = row["Category"]?.ToString() ?? "";
                            var item = new ListViewItem(row["Order_Description"]?.ToString() ?? "");
                            item.SubItems.Add(category);
                            item.SubItems.Add(row["CustomerName"]?.ToString() ?? "");
                            // Format Date
                            string dateStr = row["Date"]?.ToString() ?? "";
                            if (DateTime.TryParse(dateStr, out DateTime dateVal))
                                dateStr = dateVal.ToString("yyyy-MM-dd");
                            item.SubItems.Add(dateStr);
                            // Format Due Date
                            string dueDateStr = row["DUEDate"]?.ToString() ?? "";
                            if (DateTime.TryParse(dueDateStr, out DateTime dueDateVal))
                                dueDateStr = dueDateVal.ToString("yyyy-MM-dd");
                            item.SubItems.Add(dueDateStr);

                            if (category.Equals("AQUARIUM", StringComparison.OrdinalIgnoreCase))
                            {
                                aquariumListView.Items.Add(item);
                            }
                            else if (category.Equals("STAND", StringComparison.OrdinalIgnoreCase))
                            {
                                standListView.Items.Add(item);
                            }
                        }
                    }
                    else
                    {
                        // Clear both ListViews or show a message
                        aquariumListView.Items.Clear();
                        standListView.Items.Clear();
                        //MessageBox.Show("No Orders to Build", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading Production Order Lines for Transaction {transactionNo}: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ProdOrderLinesForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }
    }
}
