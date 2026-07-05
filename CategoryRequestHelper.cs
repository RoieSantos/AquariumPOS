using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace AquariumPOS
{
    internal static class CategoryRequestHelper
    {
        internal readonly struct CategorySelection
        {
            public CategorySelection(string code, string description)
            {
                Code = code;
                Description = description;
            }

            public string Code { get; }
            public string Description { get; }
        }

        private sealed class CategoryChoice
        {
            public string Code { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;

            public string DisplayText => string.IsNullOrWhiteSpace(Code)
                ? Description
                : $"{Description} ({Code})";
        }

        public static CategorySelection? PromptForGenerateCategory(IWin32Window owner, string connectionString)
        {
            var selectedCategory = PromptForCategorySelection(owner, connectionString);
            if (selectedCategory == null)
                return null;

            return new CategorySelection(selectedCategory.Code, selectedCategory.Description);
        }

        public static List<CategorySelection> GetGenerateCategories(IWin32Window owner, string connectionString, bool? isProductionCategory = null)
        {
            return LoadCategoryChoices(owner, connectionString, isProductionCategory)
                .Select(choice => new CategorySelection(choice.Code, choice.Description))
                .ToList();
        }

        private static CategoryChoice? PromptForCategorySelection(IWin32Window owner, string connectionString)
        {
            var categories = LoadCategoryChoices(owner, connectionString);
            if (categories.Count == 0)
            {
                MessageBox.Show(owner,
                    "No POS categories were found. Mark categories to show in the main POS first, then try again.",
                    "Generate",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return null;
            }

            using var dlg = new Form();
            dlg.Text = "Generate Request";
            dlg.StartPosition = FormStartPosition.CenterParent;
            dlg.FormBorderStyle = FormBorderStyle.FixedDialog;
            dlg.MinimizeBox = false;
            dlg.MaximizeBox = false;
            dlg.ShowInTaskbar = false;
            dlg.Size = new Size(520, 520);

            var searchBox = new TextBox
            {
                PlaceholderText = "Search category...",
                Dock = DockStyle.Top,
                Font = new Font("Arial", 11, FontStyle.Regular),
            };

            var list = new ListBox
            {
                Dock = DockStyle.Fill,
                Font = new Font("Arial", 11, FontStyle.Regular),
                DisplayMember = nameof(CategoryChoice.DisplayText)
            };

            var instructionLabel = new Label
            {
                Text = "Select the category you want to request.",
                Dock = DockStyle.Top,
                Height = 36,
                Padding = new Padding(10, 10, 10, 0),
                Font = new Font("Arial", 9, FontStyle.Regular)
            };

            var buttonsPanel = new Panel
            {
                Dock = DockStyle.Bottom,
                Height = 55,
                Padding = new Padding(10),
            };

            var ok = new Button
            {
                Text = "OK",
                DialogResult = DialogResult.OK,
                Width = 110,
                Height = 32,
                Anchor = AnchorStyles.Right | AnchorStyles.Top,
            };

            var cancel = new Button
            {
                Text = "Cancel",
                DialogResult = DialogResult.Cancel,
                Width = 110,
                Height = 32,
                Anchor = AnchorStyles.Right | AnchorStyles.Top,
            };

            cancel.Location = new Point(buttonsPanel.Width - cancel.Width - 10, 10);
            ok.Location = new Point(cancel.Left - ok.Width - 10, 10);
            buttonsPanel.Resize += (s, e) =>
            {
                cancel.Left = buttonsPanel.Width - cancel.Width - 10;
                ok.Left = cancel.Left - ok.Width - 10;
                ok.Top = cancel.Top = 10;
            };

            buttonsPanel.Controls.Add(ok);
            buttonsPanel.Controls.Add(cancel);

            dlg.AcceptButton = ok;
            dlg.CancelButton = cancel;

            dlg.Controls.Add(list);
            dlg.Controls.Add(buttonsPanel);
            dlg.Controls.Add(instructionLabel);
            dlg.Controls.Add(searchBox);

            void RefreshList(string? filter)
            {
                list.BeginUpdate();
                try
                {
                    list.Items.Clear();
                    var filtered = string.IsNullOrWhiteSpace(filter)
                        ? categories
                        : categories.Where(c => c.Description.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0
                                             || c.Code.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0)
                                    .ToList();

                    foreach (var category in filtered)
                    {
                        list.Items.Add(category);
                    }
                }
                finally
                {
                    list.EndUpdate();
                }
            }

            RefreshList(null);
            if (list.Items.Count > 0)
                list.SelectedIndex = 0;

            searchBox.TextChanged += (s, e) => RefreshList(searchBox.Text);
            list.DoubleClick += (s, e) =>
            {
                if (list.SelectedItem != null)
                    dlg.DialogResult = DialogResult.OK;
            };

            var result = dlg.ShowDialog(owner);
            if (result != DialogResult.OK)
                return null;

            return list.SelectedItem as CategoryChoice;
        }

        private static List<CategoryChoice> LoadCategoryChoices(IWin32Window owner, string connectionString, bool? isProductionCategory = null)
        {
            var categories = new List<CategoryChoice>();

            try
            {
                using var connection = new SqlConnection(connectionString);
                connection.Open();
                EnsureCategoryTableSchema(connection);

                using var command = new SqlCommand(@"
SELECT Code, Description
FROM Category
WHERE ISNULL(Code, '') <> ''
    AND ISNULL(ShowInMainPos, 0) = 1
    AND (@IsProductionCategory IS NULL OR ISNULL(IsProductionCategory, 0) = @IsProductionCategory)
ORDER BY Description, Code", connection);
                command.Parameters.AddWithValue("@IsProductionCategory", isProductionCategory.HasValue ? (object)(isProductionCategory.Value ? 1 : 0) : DBNull.Value);

                using var reader = command.ExecuteReader();
                while (reader.Read())
                {
                    string code = reader["Code"]?.ToString()?.Trim() ?? string.Empty;
                    string description = reader["Description"]?.ToString()?.Trim() ?? string.Empty;

                    categories.Add(new CategoryChoice
                    {
                        Code = code,
                        Description = string.IsNullOrWhiteSpace(description) ? code : description
                    });
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(owner,
                    $"Failed to load categories: {ex.Message}",
                    "Generate",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }

            return categories;
        }

        private static void EnsureCategoryTableSchema(SqlConnection connection)
        {
            using var command = new SqlCommand(@"
IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Category')
BEGIN
    CREATE TABLE Category (
        Code NVARCHAR(50) PRIMARY KEY,
        Description NVARCHAR(255) NOT NULL,
        WholeSale BIT NOT NULL CONSTRAINT DF_Category_WholeSale DEFAULT(0),
        DisableChangePrice BIT NOT NULL CONSTRAINT DF_Category_DisableChangePrice DEFAULT(0),
        IsProductionCategory BIT NOT NULL CONSTRAINT DF_Category_IsProductionCategory DEFAULT(0),
        ShowInMainPos BIT NOT NULL CONSTRAINT DF_Category_ShowInMainPos DEFAULT(1),
        CreatedDate DATETIME2 DEFAULT GETDATE(),
        UpdatedDate DATETIME2 DEFAULT GETDATE()
    )
END
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
END", connection);

            command.ExecuteNonQuery();
        }
    }
}