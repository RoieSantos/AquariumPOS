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
        private bool suppressGridEvents;
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
                ReadOnly = false,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                RowHeadersVisible = false,
                BackgroundColor = Color.White,
                BorderStyle = BorderStyle.None
            };
            grid.CurrentCellDirtyStateChanged += Grid_CurrentCellDirtyStateChanged;
            grid.CellValueChanged += Grid_CellValueChanged;
            grid.DataError += Grid_DataError;

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
                EnsureOnlineCustomersSchema(connection);

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
    ISNULL(Id, '') AS [RowId],
    ISNULL(Name, '') AS [Name],
    ISNULL(PrimaryPhoneNumber, '') AS [Phone Number],
    ISNULL(PrimaryEmail, '') AS [Email],
    ISNULL(PrimaryAddress, '') AS [Address],
    ISNULL(OrderCount, 0) AS [Orders],
    ISNULL(CustomerID, '') AS [Customer ID],
    CAST(ISNULL(ExcludeOnInventoryReport, 0) AS bit) AS [Exclude on Inventory Report],
    UpdatedAt AS [Updated At],
    LastSyncedUtc AS [Last Synced UTC]
FROM dbo.OnlineCustomers
ORDER BY ISNULL(Name, ''), ISNULL(PrimaryPhoneNumber, ''), ISNULL(CustomerID, '')", connection);

                suppressGridEvents = true;
                customersTable = new DataTable();
                adapter.Fill(customersTable);
                grid.DataSource = customersTable;

                ApplySearchFilter();
                ConfigureGridColumns();

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

                if (grid.Columns.Contains("Exclude on Inventory Report"))
                {
                    grid.Columns["Exclude on Inventory Report"].FillWeight = 90;
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

                suppressGridEvents = false;
            }
            catch (Exception ex)
            {
                suppressGridEvents = false;
                MessageBox.Show(this, $"Failed to load customers: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void EnsureOnlineCustomersSchema(SqlConnection connection)
        {
            using var command = new SqlCommand(@"
IF OBJECT_ID('dbo.OnlineCustomers', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.OnlineCustomers', 'ExcludeOnInventoryReport') IS NULL
BEGIN
    ALTER TABLE dbo.OnlineCustomers
    ADD ExcludeOnInventoryReport BIT NOT NULL
        CONSTRAINT DF_OnlineCustomers_ExcludeOnInventoryReport DEFAULT(0)
END", connection);
            command.ExecuteNonQuery();
        }

        private void ConfigureGridColumns()
        {
            foreach (DataGridViewColumn column in grid.Columns)
            {
                column.ReadOnly = true;
            }

            if (grid.Columns.Contains("RowId"))
            {
                grid.Columns["RowId"].Visible = false;
            }

            if (grid.Columns.Contains("Exclude on Inventory Report"))
            {
                var excludeColumn = grid.Columns["Exclude on Inventory Report"];
                excludeColumn.ReadOnly = false;
            }
        }

        private void Grid_CurrentCellDirtyStateChanged(object? sender, EventArgs e)
        {
            if (grid.IsCurrentCellDirty && grid.CurrentCell is DataGridViewCheckBoxCell)
            {
                grid.CommitEdit(DataGridViewDataErrorContexts.Commit);
            }
        }

        private void Grid_CellValueChanged(object? sender, DataGridViewCellEventArgs e)
        {
            if (suppressGridEvents || e.RowIndex < 0)
            {
                return;
            }

            if (!string.Equals(grid.Columns[e.ColumnIndex].Name, "Exclude on Inventory Report", StringComparison.Ordinal))
            {
                return;
            }

            var row = grid.Rows[e.RowIndex];
            var rowId = Convert.ToString(row.Cells["RowId"].Value)?.Trim();
            if (string.IsNullOrWhiteSpace(rowId))
            {
                return;
            }

            bool excludeOnInventoryReport = false;
            if (row.Cells["Exclude on Inventory Report"].Value != null && row.Cells["Exclude on Inventory Report"].Value != DBNull.Value)
            {
                excludeOnInventoryReport = Convert.ToBoolean(row.Cells["Exclude on Inventory Report"].Value);
            }

            try
            {
                UpdateExcludeOnInventoryReport(rowId, excludeOnInventoryReport);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to update customer flag: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                LoadData();
            }
        }

        private void Grid_DataError(object? sender, DataGridViewDataErrorEventArgs e)
        {
            e.ThrowException = false;
        }

        private void UpdateExcludeOnInventoryReport(string rowId, bool excludeOnInventoryReport)
        {
            using var connection = new SqlConnection(connectionString);
            connection.Open();
            EnsureOnlineCustomersSchema(connection);

            using var command = new SqlCommand(@"
UPDATE dbo.OnlineCustomers
SET ExcludeOnInventoryReport = @ExcludeOnInventoryReport
WHERE Id = @Id", connection);
            command.Parameters.AddWithValue("@Id", rowId);
            command.Parameters.AddWithValue("@ExcludeOnInventoryReport", excludeOnInventoryReport);

            if (command.ExecuteNonQuery() <= 0)
            {
                throw new InvalidOperationException("Customer record was not found.");
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