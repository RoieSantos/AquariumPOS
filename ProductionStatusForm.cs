using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class ProductionStatusForm : Form
    {
    private readonly string connectionString = GlobalSettings.ConnectionString;
        private DataGridView dataGridView;
        private Button addButton, editButton, deleteButton, refreshButton;

        public ProductionStatusForm()
        {
            KeyPreview = true;
            this.KeyDown += ProductionStatusForm_KeyDown;

            Text = "Production Status";
            Size = new Size(600, 400);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            dataGridView = new DataGridView
            {
                Dock = DockStyle.Top,
                Height = 250,
                ReadOnly = true,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect
            };

            addButton = new Button { Text = "Add", Dock = DockStyle.Left, Width = 100 };
            editButton = new Button { Text = "Edit", Dock = DockStyle.Left, Width = 100 };
            deleteButton = new Button { Text = "Delete", Dock = DockStyle.Left, Width = 100 };
            refreshButton = new Button { Text = "Refresh", Dock = DockStyle.Left, Width = 100 };

            var buttonPanel = new Panel { Dock = DockStyle.Top, Height = 40 };
            buttonPanel.Controls.Add(addButton);
            buttonPanel.Controls.Add(editButton);
            buttonPanel.Controls.Add(deleteButton);
            buttonPanel.Controls.Add(refreshButton);

            Controls.Add(buttonPanel);
            Controls.Add(dataGridView);

            addButton.Click += AddButton_Click;
            editButton.Click += EditButton_Click;
            deleteButton.Click += DeleteButton_Click;
            refreshButton.Click += (s, e) => LoadProductionStatus();

            LoadProductionStatus();
        }

        private void LoadProductionStatus()
        {
            try
            {
                using (var connection = new SqlConnection(connectionString))
                {
                    connection.Open();
                    string query = "SELECT Code, Description,Stages FROM ProductionStatus ORDER BY Code";
                    var adapter = new SqlDataAdapter(query, connection);
                    var table = new DataTable();
                    adapter.Fill(table);
                    dataGridView.DataSource = table;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Error loading ProductionStatus: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void AddButton_Click(object? sender, EventArgs e)
        {
            var dialog = new ProductionStatusEditDialog();
            if (dialog.ShowDialog(this) == DialogResult.OK)
            {
                try
                {
                    using (var connection = new SqlConnection(connectionString))
                    {
                        connection.Open();
                        string query = "INSERT INTO ProductionStatus (Code, Description, Stages) VALUES (@Code, @Description, @Stages)";
                        var command = new SqlCommand(query, connection);
                        command.Parameters.AddWithValue("@Code", dialog.Code);
                        command.Parameters.AddWithValue("@Description", dialog.Description);
                        command.Parameters.AddWithValue("@Stages", dialog.Stages);
                        command.ExecuteNonQuery();
                    }
                    LoadProductionStatus();
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Error adding ProductionStatus: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void EditButton_Click(object? sender, EventArgs e)
        {
            if (dataGridView.SelectedRows.Count == 1)
            {
                var row = dataGridView.SelectedRows[0];
                string code = row.Cells["Code"].Value?.ToString() ?? "";
                string description = row.Cells["Description"].Value?.ToString() ?? "";
                string stages = row.Cells["Stages"].Value?.ToString() ?? "";
                var dialog = new ProductionStatusEditDialog(code, description);
                // Set stages if editing
                var stagesProp = dialog.GetType().GetProperty("Stages");
                if (stagesProp != null && stagesProp.CanWrite)
                {
                    stagesProp.SetValue(dialog, stages);
                }
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    try
                    {
                        using (var connection = new SqlConnection(connectionString))
                        {
                            connection.Open();
                            string query = "UPDATE ProductionStatus SET Description = @Description, Stages = @Stages WHERE Code = @Code";
                            var command = new SqlCommand(query, connection);
                            command.Parameters.AddWithValue("@Code", dialog.Code);
                            command.Parameters.AddWithValue("@Description", dialog.Description);
                            command.Parameters.AddWithValue("@Stages", dialog.Stages);
                            command.ExecuteNonQuery();
                        }
                        LoadProductionStatus();
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show($"Error editing ProductionStatus: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
        }

        private void DeleteButton_Click(object? sender, EventArgs e)
        {
            if (dataGridView.SelectedRows.Count == 1)
            {
                var row = dataGridView.SelectedRows[0];
                string code = row.Cells["Code"].Value?.ToString() ?? "";
                if (MessageBox.Show($"Delete Production Status '{code}'?", "Confirm Delete", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
                {
                    try
                    {
                        using (var connection = new SqlConnection(connectionString))
                        {
                            connection.Open();
                            string query = "DELETE FROM ProductionStatus WHERE Code = @Code";
                            var command = new SqlCommand(query, connection);
                            command.Parameters.AddWithValue("@Code", code);
                            command.ExecuteNonQuery();
                        }
                        LoadProductionStatus();
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show($"Error deleting ProductionStatus: {ex.Message}", "Database Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
        }

        private void ProductionStatusForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                this.Close();
            }
        }
    }

    public class ProductionStatusEditDialog : Form
    {
    public string Code => codeTextBox.Text.Trim();
    public string Description => descriptionTextBox.Text.Trim();
    public string Stages => stagesTextBox.Text.Trim();
    private TextBox codeTextBox, descriptionTextBox, stagesTextBox;
    private Button okButton, cancelButton;

        public ProductionStatusEditDialog(string code = "", string description = "")
        {
            Text = string.IsNullOrEmpty(code) ? "Add Production Status" : "Edit Production Status";
            Size = new Size(350, 220);
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;

            var codeLabel = new Label { Text = "Code:", Left = 20, Top = 20, Width = 80 };
            codeTextBox = new TextBox { Left = 110, Top = 20, Width = 200, Text = code };
            var descriptionLabel = new Label { Text = "Description:", Left = 20, Top = 60, Width = 80 };
            descriptionTextBox = new TextBox { Left = 110, Top = 60, Width = 200, Text = description };
            var stagesLabel = new Label { Text = "Stages:", Left = 20, Top = 100, Width = 80 };
            stagesTextBox = new TextBox { Left = 110, Top = 100, Width = 200, Text = "" };

            okButton = new Button { Text = "OK", Left = 110, Top = 150, Width = 80, DialogResult = DialogResult.OK };
            cancelButton = new Button { Text = "Cancel", Left = 230, Top = 150, Width = 80, DialogResult = DialogResult.Cancel };

            Controls.Add(codeLabel);
            Controls.Add(codeTextBox);
            Controls.Add(descriptionLabel);
            Controls.Add(descriptionTextBox);
            Controls.Add(stagesLabel);
            Controls.Add(stagesTextBox);
            Controls.Add(okButton);
            Controls.Add(cancelButton);

            AcceptButton = okButton;
            CancelButton = cancelButton;
        }
    }
}
