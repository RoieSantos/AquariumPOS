using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class ItemVariantSalesWorksheetForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly string documentNo;
        private readonly TextBox documentNoTextBox;
        private readonly TextBox generatedDateTextBox;
        private readonly TextBox warehouseTextBox;
        private readonly TextBox dateCoveredTextBox;
        private readonly DataGridView grid;
        private bool suppressAutoSave;

        public ItemVariantSalesWorksheetForm(string documentNo)
        {
            this.documentNo = documentNo;

            Text = "Item Variant Sales Worksheet";
            StartPosition = FormStartPosition.CenterParent;
            WindowState = FormWindowState.Maximized;
            BackColor = Color.White;

            var headerLayout = new TableLayoutPanel
            {
                Dock = DockStyle.Top,
                Height = 150,
                ColumnCount = 4,
                RowCount = 3,
                Padding = new Padding(12),
                BackColor = Color.WhiteSmoke
            };
            headerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 140F));
            headerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            headerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 140F));
            headerLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));

            headerLayout.Controls.Add(CreateHeaderLabel("Document No."), 0, 0);
            documentNoTextBox = CreateHeaderValueTextBox();
            headerLayout.Controls.Add(documentNoTextBox, 1, 0);

            headerLayout.Controls.Add(CreateHeaderLabel("Date Generated"), 2, 0);
            generatedDateTextBox = CreateHeaderValueTextBox();
            headerLayout.Controls.Add(generatedDateTextBox, 3, 0);

            headerLayout.Controls.Add(CreateHeaderLabel("Warehouse"), 0, 1);
            warehouseTextBox = CreateHeaderValueTextBox();
            headerLayout.SetColumnSpan(warehouseTextBox, 3);
            headerLayout.Controls.Add(warehouseTextBox, 1, 1);

            headerLayout.Controls.Add(CreateHeaderLabel("Date Covered"), 0, 2);
            dateCoveredTextBox = CreateHeaderValueTextBox();
            headerLayout.SetColumnSpan(dateCoveredTextBox, 3);
            headerLayout.Controls.Add(dateCoveredTextBox, 1, 2);

            grid = new DataGridView
            {
                Dock = DockStyle.Fill,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells,
                BackgroundColor = Color.White,
                GridColor = Color.LightGray,
                EnableHeadersVisualStyles = false,
                DefaultCellStyle = new DataGridViewCellStyle
                {
                    BackColor = Color.White,
                    ForeColor = Color.Black,
                    SelectionBackColor = Color.SteelBlue,
                    SelectionForeColor = Color.White
                },
                ColumnHeadersDefaultCellStyle = new DataGridViewCellStyle
                {
                    BackColor = Color.WhiteSmoke,
                    ForeColor = Color.Black,
                    Font = new Font("Arial", 10, FontStyle.Bold)
                }
            };

            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "LineNo", HeaderText = "Line No.", Visible = false });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ReportKey", HeaderText = "Report Key", Visible = false });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ItemNo", HeaderText = "Item No.", ReadOnly = true, Width = 160 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Description", HeaderText = "Description", ReadOnly = true, Width = 420 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "OpeningStock", HeaderText = "Opening Stock", ReadOnly = true, Width = 130 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyTransferred", HeaderText = "Qty Transferred", ReadOnly = true, Width = 130 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "LocalSales", HeaderText = "Local Sales", ReadOnly = true, Width = 130 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "OnlineSales", HeaderText = "Online Sales", ReadOnly = true, Width = 130 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "TotalSalesCount", HeaderText = "Total Sales Count", ReadOnly = true, Width = 140 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyOnHand", HeaderText = "Qty on Hand", ReadOnly = true, Width = 130 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "PhysicalQtyOnHand", HeaderText = "Physical Qty on Hand", Width = 170 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Variance", HeaderText = "Variance", ReadOnly = true, Width = 130 });
            grid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ShrinkagePercent", HeaderText = "Shrinkage %", ReadOnly = true, Width = 130 });

            foreach (string columnName in new[] { "OpeningStock", "QtyTransferred", "LocalSales", "OnlineSales", "TotalSalesCount", "QtyOnHand", "PhysicalQtyOnHand", "Variance", "ShrinkagePercent" })
            {
                grid.Columns[columnName].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            }

            grid.CellEndEdit += Grid_CellEndEdit;

            var closeButton = new Button
            {
                Text = "Close",
                Dock = DockStyle.Right,
                Width = 120,
                Height = 42,
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold),
                Margin = new Padding(8)
            };
            closeButton.Click += (_, _) => Close();

            var printButton = new Button
            {
                Text = "Print",
                Dock = DockStyle.Right,
                Width = 120,
                Height = 42,
                BackColor = Color.Green,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold),
                Margin = new Padding(8)
            };
            printButton.Click += PrintButton_Click;

            var postButton = new Button
            {
                Text = "POST",
                Dock = DockStyle.Right,
                Width = 120,
                Height = 42,
                BackColor = Color.SeaGreen,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold),
                Margin = new Padding(8)
            };
            postButton.Click += PostButton_Click;

            var footerPanel = new Panel
            {
                Dock = DockStyle.Bottom,
                Height = 62,
                Padding = new Padding(12),
                BackColor = Color.WhiteSmoke
            };
            footerPanel.Controls.Add(closeButton);
            footerPanel.Controls.Add(printButton);
            footerPanel.Controls.Add(postButton);

            Controls.Add(grid);
            Controls.Add(footerPanel);
            Controls.Add(headerLayout);

            Load += ItemVariantSalesWorksheetForm_Load;
        }

        private void ItemVariantSalesWorksheetForm_Load(object? sender, EventArgs e)
        {
            LoadWorksheet();
        }

        private Label CreateHeaderLabel(string text)
        {
            return new Label
            {
                Text = text,
                Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleLeft,
                Font = new Font("Arial", 11, FontStyle.Bold)
            };
        }

        private TextBox CreateHeaderValueTextBox()
        {
            return new TextBox
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                BackColor = Color.White,
                Font = new Font("Arial", 11, FontStyle.Regular)
            };
        }

        private void LoadWorksheet()
        {
            try
            {
                suppressAutoSave = true;
                ItemVariantSalesWorksheetData.EnsureTablesExist(connectionString);

                var header = ItemVariantSalesWorksheetData.GetWorksheetHeader(connectionString, documentNo);
                if (header == null)
                {
                    MessageBox.Show(this, $"Worksheet '{documentNo}' was not found.", "Worksheet Not Found", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    Close();
                    return;
                }

                documentNoTextBox.Text = header.DocumentNo;
                generatedDateTextBox.Text = header.GeneratedDate == DateTime.MinValue
                    ? string.Empty
                    : header.GeneratedDate.ToString("yyyy-MM-dd HH:mm:ss");
                warehouseTextBox.Text = header.WarehouseName;
                dateCoveredTextBox.Text = $"{header.FromDate:yyyy-MM-dd} to {header.ToDate:yyyy-MM-dd}";

                grid.Rows.Clear();
                foreach (var line in ItemVariantSalesWorksheetData.GetWorksheetLines(connectionString, documentNo))
                {
                    grid.Rows.Add(
                        line.LineNo,
                        line.ReportKey,
                        line.ItemNo,
                        line.Description,
                        line.OpeningStock.ToString("N2", CultureInfo.InvariantCulture),
                        line.QtyTransferred.ToString("N2", CultureInfo.InvariantCulture),
                        line.LocalSales.ToString("N2", CultureInfo.InvariantCulture),
                        line.OnlineSales.ToString("N2", CultureInfo.InvariantCulture),
                        line.TotalSalesCount.ToString("N2", CultureInfo.InvariantCulture),
                        line.QtyOnHand.ToString("N2", CultureInfo.InvariantCulture),
                        line.PhysicalQtyOnHand.HasValue ? line.PhysicalQtyOnHand.Value.ToString("N2", CultureInfo.InvariantCulture) : string.Empty,
                        line.Variance.HasValue ? line.Variance.Value.ToString("N2", CultureInfo.InvariantCulture) : string.Empty,
                        line.ShrinkagePercent.HasValue ? line.ShrinkagePercent.Value.ToString("N2", CultureInfo.InvariantCulture) + "%" : string.Empty);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load worksheet: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Close();
            }
            finally
            {
                suppressAutoSave = false;
            }
        }

        private void Grid_CellEndEdit(object? sender, DataGridViewCellEventArgs e)
        {
            try
            {
                if (suppressAutoSave || e.RowIndex < 0 || e.ColumnIndex < 0)
                    return;

                if (!string.Equals(grid.Columns[e.ColumnIndex].Name, "PhysicalQtyOnHand", StringComparison.Ordinal))
                    return;

                var row = grid.Rows[e.RowIndex];
                if (row.IsNewRow)
                    return;

                int lineNo = row.Cells["LineNo"].Value == null ? 0 : Convert.ToInt32(row.Cells["LineNo"].Value);
                if (lineNo <= 0)
                    return;

                string rawValue = (row.Cells["PhysicalQtyOnHand"].Value ?? string.Empty).ToString()?.Trim() ?? string.Empty;
                decimal? physicalQty = null;
                if (!string.IsNullOrWhiteSpace(rawValue))
                {
                    if (!decimal.TryParse(rawValue, out decimal parsed))
                    {
                        MessageBox.Show(this, "Physical Qty on Hand must be a number.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        LoadWorksheet();
                        return;
                    }

                    physicalQty = parsed;
                }

                ItemVariantSalesWorksheetData.SavePhysicalQtyOnHand(connectionString, documentNo, lineNo, physicalQty);
                row.Cells["PhysicalQtyOnHand"].Value = physicalQty.HasValue
                    ? physicalQty.Value.ToString("N2", CultureInfo.InvariantCulture)
                    : string.Empty;

                decimal qtyOnHand = decimal.TryParse((row.Cells["QtyOnHand"].Value ?? string.Empty).ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out decimal parsedQtyOnHand)
                    ? parsedQtyOnHand
                    : 0m;
                decimal? variance = physicalQty.HasValue ? physicalQty.Value - qtyOnHand : (decimal?)null;
                decimal? shrinkagePercent = variance.HasValue && qtyOnHand != 0 ? (variance.Value / qtyOnHand) * 100m : (decimal?)null;

                row.Cells["Variance"].Value = variance.HasValue
                    ? variance.Value.ToString("N2", CultureInfo.InvariantCulture)
                    : string.Empty;
                row.Cells["ShrinkagePercent"].Value = shrinkagePercent.HasValue
                    ? shrinkagePercent.Value.ToString("N2", CultureInfo.InvariantCulture) + "%"
                    : string.Empty;
            }
            catch (Exception ex)
            {
                try
                {
                    MessageBox.Show(this, $"Failed to save Physical Qty on Hand: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                catch
                {
                }
            }
        }

        private void PrintButton_Click(object? sender, EventArgs e)
        {
            try
            {
                var header = ItemVariantSalesWorksheetData.GetWorksheetHeader(connectionString, documentNo);
                if (header == null)
                {
                    MessageBox.Show(this, $"Worksheet '{documentNo}' was not found.", "Worksheet Not Found", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                var lines = ItemVariantSalesWorksheetData.GetWorksheetLines(connectionString, documentNo);
                PostingEvents.PrintItemVariantSalesWorksheetA4(header, lines, this);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to print worksheet: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private async void PostButton_Click(object? sender, EventArgs e)
        {
            try
            {
                var header = ItemVariantSalesWorksheetData.GetWorksheetHeader(connectionString, documentNo);
                if (header == null)
                {
                    MessageBox.Show(this, $"Worksheet '{documentNo}' was not found.", "Worksheet Not Found", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                var lines = ItemVariantSalesWorksheetData.GetWorksheetLines(connectionString, documentNo);

                string coverage = $"{header.FromDate:yyyy-MM-dd} to {header.ToDate:yyyy-MM-dd}";
                var confirm = MessageBox.Show(
                    this,
                    $"This will POST Month End for {coverage}.\n\nContinue?",
                    "Confirm Month End POST",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);

                if (confirm != DialogResult.Yes)
                    return;

                using var progressForm = new ItemVariantWorksheetProgressForm("Preparing month end POST...");
                progressForm.Show(this);
                var progress = new Progress<string>(status => progressForm.UpdateStatus(status));

                MonthEndHeader postedHeader;
                try
                {
                    postedHeader = await PostingEvents.PostItemVariantSalesWorksheetMonthEndAsync(header, lines, progress);
                }
                finally
                {
                    progressForm.Close();
                }

                string message = $"Month end posted successfully.\n\nMonth End No: {postedHeader.DocumentNo}\nTotal lines logged: {postedHeader.TotalLines:N0}\nCloud patched: {postedHeader.CloudPatchedLines:N0}\nCloud skipped: {postedHeader.CloudSkippedLines:N0}\nCloud failed: {postedHeader.CloudFailedLines:N0}\n\nSupabase sync: {(postedHeader.SentToCloud ? "Success" : $"Failed - {postedHeader.SupabaseSyncMessage}")}";
                bool hasWarnings = postedHeader.CloudFailedLines > 0 || !postedHeader.SentToCloud;
                MessageBox.Show(
                    this,
                    message,
                    hasWarnings ? "POST Completed With Warnings" : "POST Successful",
                    MessageBoxButtons.OK,
                    hasWarnings ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
                Close();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to POST month end worksheet: {ex.Message}", "POST Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

    }
}