using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class CustomersViewForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataTable customersTable = new DataTable();
        private DataGridView grid = null!;
        private Label summaryLabel = null!;
        private TextBox searchTextBox = null!;
        private Button refreshButton = null!;
        private Button closeButton = null!;

        public CustomersViewForm()
        {
            Text = "Customers";
            Size = new Size(980, 620);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            InitializeComponent();
            LoadData();
        }

        private void InitializeComponent()
        {
            summaryLabel = new Label
            {
                Dock = DockStyle.Top,
                Height = 32,
                Padding = new Padding(12, 8, 12, 0),
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.FromArgb(45, 45, 45),
                Text = "Loading customers..."
            };

            var searchPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 44,
                Padding = new Padding(12, 6, 12, 6),
                BackColor = Color.White
            };

            var searchLabel = new Label
            {
                Dock = DockStyle.Left,
                Width = 70,
                Text = "Search:",
                TextAlign = ContentAlignment.MiddleLeft,
                Font = new Font("Arial", 9, FontStyle.Bold),
                ForeColor = Color.FromArgb(45, 45, 45)
            };

            searchTextBox = new TextBox
            {
                Dock = DockStyle.Fill,
                Font = new Font("Arial", 10, FontStyle.Regular)
            };
            searchTextBox.TextChanged += (s, e) => ApplySearchFilter();

            searchPanel.Controls.Add(searchTextBox);
            searchPanel.Controls.Add(searchLabel);

            grid = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                RowHeadersVisible = false,
                BackgroundColor = Color.White,
                BorderStyle = BorderStyle.None
            };

            refreshButton = CreateButton("Refresh", Color.RoyalBlue, (s, e) => LoadData());
            closeButton = CreateButton("Close", Color.DimGray, (s, e) => Close());

            var buttonPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Bottom,
                Height = 64,
                Padding = new Padding(8),
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false
            };
            buttonPanel.Controls.AddRange(new Control[] { refreshButton, closeButton });

            Controls.Add(grid);
            Controls.Add(searchPanel);
            Controls.Add(summaryLabel);
            Controls.Add(buttonPanel);
        }

        private Button CreateButton(string text, Color backColor, EventHandler onClick)
        {
            var button = new Button
            {
                Text = text,
                Size = new Size(110, 40),
                BackColor = backColor,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold),
                UseVisualStyleBackColor = false,
                Margin = new Padding(6)
            };
            button.Click += onClick;
            return button;
        }

        private void LoadData()
        {
            try
            {
                using var connection = new SqlConnection(connectionString);
                connection.Open();

                using (var existsCmd = new SqlCommand("SELECT OBJECT_ID('dbo.OnlineCustomers', 'U')", connection))
                {
                    var tableId = existsCmd.ExecuteScalar();
                    if (tableId == DBNull.Value || tableId == null)
                    {
                        customersTable = new DataTable();
                        grid.DataSource = customersTable;
                        ApplySearchFilter();
                        return;
                    }
                }

                using var adapter = new SqlDataAdapter(@"
SELECT
    ISNULL(Name, '') AS [Name],
    ISNULL(PrimaryPhoneNumber, '') AS [Phone Number],
    ISNULL(PrimaryEmail, '') AS [Email],
    ISNULL(PrimaryAddress, '') AS [Address],
    ISNULL(OrderCount, 0) AS [Orders],
    ISNULL(CustomerID, '') AS [Customer ID],
    UpdatedAt AS [Updated At],
    LastSyncedUtc AS [Last Synced UTC]
FROM dbo.OnlineCustomers
ORDER BY ISNULL(Name, ''), ISNULL(PrimaryPhoneNumber, ''), ISNULL(CustomerID, '')", connection);

                customersTable = new DataTable();
                adapter.Fill(customersTable);
                grid.DataSource = customersTable;

                ApplySearchFilter();

                if (grid.Columns.Contains("Name"))
                {
                    grid.Columns["Name"].FillWeight = 190;
                }

                if (grid.Columns.Contains("Phone Number"))
                {
                    grid.Columns["Phone Number"].FillWeight = 110;
                }

                if (grid.Columns.Contains("Email"))
                {
                    grid.Columns["Email"].FillWeight = 180;
                }

                if (grid.Columns.Contains("Address"))
                {
                    grid.Columns["Address"].FillWeight = 220;
                }

                if (grid.Columns.Contains("Orders"))
                {
                    grid.Columns["Orders"].FillWeight = 65;
                    grid.Columns["Orders"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
                }

                if (grid.Columns.Contains("Customer ID"))
                {
                    grid.Columns["Customer ID"].FillWeight = 90;
                }

                if (grid.Columns.Contains("Updated At"))
                {
                    grid.Columns["Updated At"].FillWeight = 95;
                    grid.Columns["Updated At"].DefaultCellStyle.Format = "g";
                }

                if (grid.Columns.Contains("Last Synced UTC"))
                {
                    grid.Columns["Last Synced UTC"].FillWeight = 95;
                    grid.Columns["Last Synced UTC"].DefaultCellStyle.Format = "g";
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load customers: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ApplySearchFilter()
        {
            if (customersTable == null)
            {
                return;
            }

            var text = searchTextBox?.Text.Replace("'", "''") ?? string.Empty;
            if (string.IsNullOrWhiteSpace(text))
            {
                customersTable.DefaultView.RowFilter = string.Empty;
            }
            else
            {
                customersTable.DefaultView.RowFilter = $"[Name] LIKE '%{text}%'";
            }

            summaryLabel.Text = $"Customers ({customersTable.DefaultView.Count} records)";
        }
    }
}