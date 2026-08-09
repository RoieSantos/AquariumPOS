using System;
using System.Drawing;
using System.Globalization;
using System.Text.Json;
using System.Windows.Forms;

namespace AquariumPOS
{
    public sealed class MonthEndViewForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly DataGridView headerGrid;
        private readonly DataGridView lineGrid;
        private readonly TextBox detailsTextBox;
        private readonly Button resendButton;
        private readonly Button showLastErrorButton;

        public MonthEndViewForm()
        {
            Text = "Month End Posted Data";
            StartPosition = FormStartPosition.CenterParent;
            WindowState = FormWindowState.Maximized;
            BackColor = Color.White;

            var topPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 56,
                Padding = new Padding(12),
                BackColor = Color.WhiteSmoke
            };

            var refreshButton = new Button
            {
                Text = "Refresh",
                Dock = DockStyle.Left,
                Width = 120,
                BackColor = Color.SteelBlue,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            refreshButton.Click += (_, _) => LoadHeaders();

            var closeButton = new Button
            {
                Text = "Close",
                Dock = DockStyle.Right,
                Width = 120,
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            closeButton.Click += (_, _) => Close();

            topPanel.Controls.Add(refreshButton);
            topPanel.Controls.Add(closeButton);

            headerGrid = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.AllCells,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                RowHeadersVisible = false,
                BackgroundColor = Color.White,
                GridColor = Color.LightGray,
                EnableHeadersVisualStyles = false,
                ColumnHeadersDefaultCellStyle = new DataGridViewCellStyle
                {
                    BackColor = Color.WhiteSmoke,
                    ForeColor = Color.Black,
                    Font = new Font("Arial", 10, FontStyle.Bold)
                }
            };

            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "DocumentNo", HeaderText = "Month End No." });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "WorksheetDocumentNo", HeaderText = "Worksheet No." });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "PostedAtUtc", HeaderText = "Posted At" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "PostedBy", HeaderText = "Posted By" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "WarehouseName", HeaderText = "Warehouse" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "FromDate", HeaderText = "From Date" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ToDate", HeaderText = "To Date" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "TotalLines", HeaderText = "Total Lines" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "CloudPatchedLines", HeaderText = "Cloud Patched" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "CloudSkippedLines", HeaderText = "Cloud Skipped" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "CloudFailedLines", HeaderText = "Cloud Failed" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "CloudSyncSuccess", HeaderText = "Success" });
            headerGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "SentToCloud", HeaderText = "Sent To Cloud" });
            headerGrid.SelectionChanged += HeaderGrid_SelectionChanged;

            lineGrid = new DataGridView
            {
                Dock = DockStyle.Fill,
                ReadOnly = true,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.AllCells,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                RowHeadersVisible = false,
                BackgroundColor = Color.White,
                GridColor = Color.LightGray,
                EnableHeadersVisualStyles = false,
                ColumnHeadersDefaultCellStyle = new DataGridViewCellStyle
                {
                    BackColor = Color.WhiteSmoke,
                    ForeColor = Color.Black,
                    Font = new Font("Arial", 10, FontStyle.Bold)
                }
            };

            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "LineNo", HeaderText = "Line No." });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ItemNo", HeaderText = "Item No." });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Description", HeaderText = "Description", Width = 260 });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "OpeningStock", HeaderText = "Opening Stock" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyTransferred", HeaderText = "Qty Transferred" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "LocalSales", HeaderText = "Local Sales" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "OnlineSales", HeaderText = "Online Sales" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "TotalSalesCount", HeaderText = "Total Sales Count" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "QtyOnHand", HeaderText = "Qty On Hand" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "PhysicalQtyOnHand", HeaderText = "Physical Qty On Hand" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Variance", HeaderText = "Variance" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "ShrinkagePercent", HeaderText = "Shrinkage %" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "CloudPatchStatus", HeaderText = "Cloud Status" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "SentToOnline", HeaderText = "Sent to Online" });
            lineGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "VariationId", HeaderText = "Variation ID" });

            foreach (string columnName in new[] { "OpeningStock", "QtyTransferred", "LocalSales", "OnlineSales", "TotalSalesCount", "QtyOnHand", "PhysicalQtyOnHand", "Variance", "ShrinkagePercent" })
            {
                lineGrid.Columns[columnName].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            }

            detailsTextBox = new TextBox
            {
                Dock = DockStyle.Fill,
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                Font = new Font("Consolas", 10F),
                BackColor = Color.White
            };

            lineGrid.SelectionChanged += (_, _) => UpdateLineDetails();

            var lineActionsPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 48,
                Padding = new Padding(8),
                BackColor = Color.WhiteSmoke
            };

            var lineButtonsPanel = new FlowLayoutPanel
            {
                Dock = DockStyle.Left,
                FlowDirection = FlowDirection.LeftToRight,
                AutoSize = true,
                WrapContents = false
            };

            resendButton = new Button
            {
                Text = "Resend",
                Width = 140,
                Height = 32,
                Margin = new Padding(0, 0, 8, 0),
                BackColor = Color.DarkOrange,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            resendButton.Click += ResendButton_Click;

            showLastErrorButton = new Button
            {
                Text = "Show Last Error",
                Width = 160,
                Height = 32,
                BackColor = Color.Firebrick,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };
            showLastErrorButton.Click += ShowLastErrorButton_Click;

            lineButtonsPanel.Controls.Add(resendButton);
            lineButtonsPanel.Controls.Add(showLastErrorButton);
            lineActionsPanel.Controls.Add(lineButtonsPanel);

            var linePanel = new Panel { Dock = DockStyle.Fill };
            linePanel.Controls.Add(lineGrid);
            linePanel.Controls.Add(lineActionsPanel);

            var lowerSplit = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Horizontal,
                SplitterDistance = 320
            };
            lowerSplit.Panel1.Controls.Add(linePanel);
            lowerSplit.Panel2.Controls.Add(detailsTextBox);

            var mainSplit = new SplitContainer
            {
                Dock = DockStyle.Fill,
                Orientation = Orientation.Horizontal,
                SplitterDistance = 260
            };
            mainSplit.Panel1.Controls.Add(headerGrid);
            mainSplit.Panel2.Controls.Add(lowerSplit);

            Controls.Add(mainSplit);
            Controls.Add(topPanel);

            Load += (_, _) => LoadHeaders();
        }

        private void LoadHeaders()
        {
            try
            {
                headerGrid.Rows.Clear();
                lineGrid.Rows.Clear();
                detailsTextBox.Clear();

                foreach (var header in ItemVariantSalesWorksheetData.GetMonthEndHeaders(connectionString))
                {
                    int rowIndex = headerGrid.Rows.Add(
                        header.DocumentNo,
                        header.WorksheetDocumentNo,
                        header.PostedAtUtc == DateTime.MinValue ? string.Empty : header.PostedAtUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss"),
                        header.PostedBy,
                        header.WarehouseName,
                        header.FromDate == DateTime.MinValue ? string.Empty : header.FromDate.ToString("yyyy-MM-dd"),
                        header.ToDate == DateTime.MinValue ? string.Empty : header.ToDate.ToString("yyyy-MM-dd"),
                        header.TotalLines,
                        header.CloudPatchedLines,
                        header.CloudSkippedLines,
                        header.CloudFailedLines,
                        header.CloudSyncSuccess ? "Yes" : "No",
                        header.SentToCloud ? "Yes" : "No");

                    var successCell = headerGrid.Rows[rowIndex].Cells["CloudSyncSuccess"];
                    successCell.Style.ForeColor = header.CloudSyncSuccess ? Color.DarkGreen : Color.DarkRed;
                    successCell.Style.Font = new Font("Arial", 9, FontStyle.Bold);

                    var sentToCloudCell = headerGrid.Rows[rowIndex].Cells["SentToCloud"];
                    sentToCloudCell.Style.ForeColor = header.SentToCloud ? Color.DarkGreen : Color.DarkRed;
                    sentToCloudCell.Style.Font = new Font("Arial", 9, FontStyle.Bold);
                }

                if (headerGrid.Rows.Count > 0)
                {
                    headerGrid.Rows[0].Selected = true;
                    LoadLinesForSelectedHeader();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load month end data: {ex.Message}", "Month End", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void HeaderGrid_SelectionChanged(object? sender, EventArgs e)
        {
            LoadLinesForSelectedHeader();
        }

        private void LoadLinesForSelectedHeader()
        {
            try
            {
                lineGrid.Rows.Clear();
                detailsTextBox.Clear();

                if (headerGrid.SelectedRows.Count == 0)
                    return;

                string documentNo = headerGrid.SelectedRows[0].Cells["DocumentNo"].Value?.ToString()?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(documentNo))
                    return;

                foreach (var line in ItemVariantSalesWorksheetData.GetMonthEndLines(connectionString, documentNo))
                {
                    lineGrid.Rows.Add(
                        line.LineNo,
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
                        line.ShrinkagePercent.HasValue ? line.ShrinkagePercent.Value.ToString("N2", CultureInfo.InvariantCulture) + "%" : string.Empty,
                        line.CloudPatchStatus,
                        line.SentToOnline ? "Yes" : "No",
                        line.VariationId);
                }

                if (lineGrid.Rows.Count > 0)
                {
                    lineGrid.Rows[0].Selected = true;
                    UpdateLineDetails();
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load month end lines: {ex.Message}", "Month End", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void UpdateLineDetails()
        {
            if (headerGrid.SelectedRows.Count == 0 || lineGrid.SelectedRows.Count == 0)
            {
                detailsTextBox.Clear();
                return;
            }

            string documentNo = headerGrid.SelectedRows[0].Cells["DocumentNo"].Value?.ToString()?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(documentNo))
            {
                detailsTextBox.Clear();
                return;
            }

            int lineNo = 0;
            try { lineNo = Convert.ToInt32(lineGrid.SelectedRows[0].Cells["LineNo"].Value); } catch { lineNo = 0; }
            if (lineNo <= 0)
            {
                detailsTextBox.Clear();
                return;
            }

            var line = ItemVariantSalesWorksheetData.GetMonthEndLines(connectionString, documentNo).Find(item => item.LineNo == lineNo);
            if (line == null)
            {
                detailsTextBox.Clear();
                return;
            }

            detailsTextBox.Text =
                $"Month End No.: {documentNo}{Environment.NewLine}" +
                $"Line No.: {line.LineNo}{Environment.NewLine}" +
                $"Report Key: {line.ReportKey}{Environment.NewLine}" +
                $"Variation ID: {line.VariationId}{Environment.NewLine}" +
                $"Product ID: {line.ProductId}{Environment.NewLine}" +
                $"Cloud Warehouse ID: {line.CloudWarehouseId}{Environment.NewLine}" +
                $"Cloud Previous Qty On Hand: {(line.CloudPreviousQtyOnHand.HasValue ? line.CloudPreviousQtyOnHand.Value.ToString("N2", CultureInfo.InvariantCulture) : string.Empty)}{Environment.NewLine}" +
                $"Cloud Updated Qty On Hand: {(line.CloudUpdatedQtyOnHand.HasValue ? line.CloudUpdatedQtyOnHand.Value.ToString("N2", CultureInfo.InvariantCulture) : string.Empty)}{Environment.NewLine}" +
                $"Cloud Patch Status: {line.CloudPatchStatus}{Environment.NewLine}" +
                $"Sent to Online: {(line.SentToOnline ? "Yes" : "No")}{Environment.NewLine}" +
                $"Cloud Patch Message: {line.CloudPatchMessage}";
        }

        private async void ResendButton_Click(object? sender, EventArgs e)
        {
            if (headerGrid.SelectedRows.Count == 0 || lineGrid.SelectedRows.Count == 0)
            {
                MessageBox.Show(this, "Select a month end line to resend.", "Resend", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string documentNo = headerGrid.SelectedRows[0].Cells["DocumentNo"].Value?.ToString()?.Trim() ?? string.Empty;
            int lineNo = 0;
            try { lineNo = Convert.ToInt32(lineGrid.SelectedRows[0].Cells["LineNo"].Value); } catch { lineNo = 0; }

            if (string.IsNullOrWhiteSpace(documentNo) || lineNo <= 0)
            {
                MessageBox.Show(this, "Select a month end line to resend.", "Resend", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string cloudSyncSuccess = headerGrid.SelectedRows[0].Cells["CloudSyncSuccess"].Value?.ToString()?.Trim() ?? string.Empty;
            string sentToCloud = headerGrid.SelectedRows[0].Cells["SentToCloud"].Value?.ToString()?.Trim() ?? string.Empty;
            bool fullyPatchedToPancake = string.Equals(cloudSyncSuccess, "Yes", StringComparison.OrdinalIgnoreCase);
            bool fullySentToSupabase = string.Equals(sentToCloud, "Yes", StringComparison.OrdinalIgnoreCase);
            if (fullyPatchedToPancake && fullySentToSupabase)
            {
                MessageBox.Show(this, "Month End has been closed and fully synced to Pancake and Supabase. Resending is not allowed.", "Resend Not Allowed", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string description = lineGrid.SelectedRows[0].Cells["Description"].Value?.ToString() ?? string.Empty;

            resendButton.Enabled = false;

            try
            {
                // If Pancake is already fully synced but Supabase isn't, only retry the Supabase sync.
                if (fullyPatchedToPancake && !fullySentToSupabase)
                {
                    using var supabaseOnlyProgressForm = new ItemVariantWorksheetProgressForm("Resending to Supabase...");
                    supabaseOnlyProgressForm.Show(this);
                    var supabaseOnlyProgress = new Progress<string>(status => supabaseOnlyProgressForm.UpdateStatus(status));
                    var supabaseOnlyResult = await PostingEvents.ResendMonthEndHeaderToSupabaseAsync(documentNo, supabaseOnlyProgress).ConfigureAwait(true);
                    supabaseOnlyProgressForm.Close();

                    string supabaseOnlyMessage = supabaseOnlyResult.Success
                        ? "Supabase sync: Success."
                        : $"Supabase sync: Failed - {supabaseOnlyResult.Message}";
                    MessageBox.Show(this, supabaseOnlyMessage, supabaseOnlyResult.Success ? "Resend Successful" : "Resend Failed", MessageBoxButtons.OK, supabaseOnlyResult.Success ? MessageBoxIcon.Information : MessageBoxIcon.Error);
                    RefreshHeaderAndReselect(documentNo);
                    return;
                }

                OnlinefunctionsEvents.MonthEndAdjustmentRequestPreview preview;
                using (var previewProgressForm = new ItemVariantWorksheetProgressForm("Preparing adjustment preview..."))
                {
                    previewProgressForm.Show(this);
                    preview = await PostingEvents.GetMonthEndLineResendPreviewAsync(documentNo, lineNo).ConfigureAwait(true);
                    previewProgressForm.Close();
                }

                if (ShowUpdateQuantityPreviewDialog(documentNo, lineNo, description, preview) != DialogResult.Yes)
                    return;

                if (!string.IsNullOrWhiteSpace(preview.ErrorMessage))
                    return;

                using var progressForm = new ItemVariantWorksheetProgressForm("Resending to cloud...");
                progressForm.Show(this);
                var progress = new Progress<string>(status => progressForm.UpdateStatus(status));
                var updatedLine = await PostingEvents.ResendMonthEndLineToCloudAsync(documentNo, lineNo, progress).ConfigureAwait(true);

                string resultMessage = $"Line resent successfully.\n\n{updatedLine.CloudPatchMessage}";
                if (!fullySentToSupabase)
                {
                    var supabaseResult = await PostingEvents.ResendMonthEndHeaderToSupabaseAsync(documentNo, progress).ConfigureAwait(true);
                    resultMessage += supabaseResult.Success
                        ? "\n\nSupabase sync: Success."
                        : $"\n\nSupabase sync: Failed - {supabaseResult.Message}";
                }

                progressForm.Close();
                MessageBox.Show(this, resultMessage, "Resend Successful", MessageBoxButtons.OK, MessageBoxIcon.Information);
                RefreshHeaderAndReselect(documentNo);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to resend line to the cloud: {ex.Message}", "Resend Failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                resendButton.Enabled = true;
            }

            LoadLinesForSelectedHeader();
        }

        private void RefreshHeaderAndReselect(string documentNo)
        {
            LoadHeaders();
            foreach (DataGridViewRow row in headerGrid.Rows)
            {
                if (string.Equals(row.Cells["DocumentNo"].Value?.ToString()?.Trim(), documentNo, StringComparison.OrdinalIgnoreCase))
                {
                    row.Selected = true;
                    headerGrid.CurrentCell = row.Cells[0];
                    break;
                }
            }
        }

        private void ShowLastErrorButton_Click(object? sender, EventArgs e)
        {
            if (headerGrid.SelectedRows.Count == 0 || lineGrid.SelectedRows.Count == 0)
            {
                MessageBox.Show(this, "Select a month end line to view its last error.", "Show Last Error", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string documentNo = headerGrid.SelectedRows[0].Cells["DocumentNo"].Value?.ToString()?.Trim() ?? string.Empty;
            int lineNo = 0;
            try { lineNo = Convert.ToInt32(lineGrid.SelectedRows[0].Cells["LineNo"].Value); } catch { lineNo = 0; }

            if (string.IsNullOrWhiteSpace(documentNo) || lineNo <= 0)
            {
                MessageBox.Show(this, "Select a month end line to view its last error.", "Show Last Error", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            MonthEndLine? line;
            try
            {
                line = ItemVariantSalesWorksheetData.GetMonthEndLines(connectionString, documentNo).Find(item => item.LineNo == lineNo);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load line details: {ex.Message}", "Show Last Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (line == null)
            {
                MessageBox.Show(this, "Line not found.", "Show Last Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (string.IsNullOrWhiteSpace(line.LastErrorMessage) && string.IsNullOrWhiteSpace(line.LastErrorEndpoint) && string.IsNullOrWhiteSpace(line.LastErrorPayload))
            {
                MessageBox.Show(this, "No error has been recorded for this line.", "Show Last Error", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string payloadDisplay = line.LastErrorPayload;
            if (!string.IsNullOrWhiteSpace(payloadDisplay))
            {
                try
                {
                    using var doc = JsonDocument.Parse(payloadDisplay);
                    payloadDisplay = JsonSerializer.Serialize(doc, new JsonSerializerOptions { WriteIndented = true });
                }
                catch
                {
                    // Keep the raw payload text if it isn't valid JSON.
                }
            }

            string details =
                $"Endpoint:{Environment.NewLine}{(string.IsNullOrWhiteSpace(line.LastErrorEndpoint) ? "(not available)" : line.LastErrorEndpoint)}{Environment.NewLine}{Environment.NewLine}" +
                $"Payload:{Environment.NewLine}{(string.IsNullOrWhiteSpace(payloadDisplay) ? "(not available)" : payloadDisplay)}{Environment.NewLine}{Environment.NewLine}" +
                $"Error Message:{Environment.NewLine}{(string.IsNullOrWhiteSpace(line.LastErrorMessage) ? "(not available)" : line.LastErrorMessage)}";

            MessageBox.Show(this, details, $"Last Error - Line {lineNo}", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private DialogResult ShowUpdateQuantityPreviewDialog(string documentNo, int lineNo, string description, OnlinefunctionsEvents.MonthEndAdjustmentRequestPreview preview)
        {
            string formattedPayload = preview.PayloadJson;
            if (!string.IsNullOrWhiteSpace(formattedPayload))
            {
                try
                {
                    using var doc = JsonDocument.Parse(formattedPayload);
                    formattedPayload = JsonSerializer.Serialize(doc, new JsonSerializerOptions { WriteIndented = true });
                }
                catch
                {
                }
            }

            using var dialog = new Form
            {
                Text = $"Confirm {(string.IsNullOrWhiteSpace(preview.ActionType) ? "Adjustment" : preview.ActionType)} Request",
                StartPosition = FormStartPosition.CenterParent,
                Size = new Size(900, 650),
                MinimizeBox = false,
                MaximizeBox = false,
                FormBorderStyle = FormBorderStyle.SizableToolWindow,
                BackColor = Color.White
            };

            var buttonPanel = new Panel
            {
                Dock = DockStyle.Bottom,
                Height = 56,
                Padding = new Padding(12),
                BackColor = Color.WhiteSmoke
            };

            var sendButton = new Button
            {
                Text = "Send",
                DialogResult = DialogResult.Yes,
                Dock = DockStyle.Right,
                Width = 120,
                BackColor = Color.DarkOrange,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            bool canSend = string.IsNullOrWhiteSpace(preview.ErrorMessage);
            sendButton.Enabled = canSend;

            var cancelButton = new Button
            {
                Text = canSend ? "Cancel" : "Close",
                DialogResult = DialogResult.No,
                Dock = DockStyle.Right,
                Width = 120,
                BackColor = Color.Gray,
                ForeColor = Color.White,
                Font = new Font("Arial", 10, FontStyle.Bold)
            };

            var contentBox = new TextBox
            {
                Dock = DockStyle.Fill,
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Both,
                WordWrap = false,
                Font = new Font("Consolas", 10F),
                BackColor = Color.White,
                Text =
                    $"Month End No: {documentNo}{Environment.NewLine}" +
                    $"Line No: {lineNo}{Environment.NewLine}" +
                    $"Item: {description}{Environment.NewLine}" +
                    $"Action: {(string.IsNullOrWhiteSpace(preview.ActionType) ? "(none)" : preview.ActionType)}{Environment.NewLine}" +
                    $"Adjustment Quantity: {preview.Quantity:N2}{Environment.NewLine}" +
                    $"Variation ID: {preview.VariationId}{Environment.NewLine}" +
                    $"Warehouse ID: {preview.WarehouseId}{Environment.NewLine}{Environment.NewLine}" +
                    $"Endpoint:{Environment.NewLine}{preview.Endpoint}{Environment.NewLine}{Environment.NewLine}" +
                    $"Payload:{Environment.NewLine}{formattedPayload}{Environment.NewLine}{Environment.NewLine}" +
                    (canSend
                        ? $"Send this {preview.ActionType} request to the cloud?"
                        : $"Cannot send yet:{Environment.NewLine}{preview.ErrorMessage}")
            };

            buttonPanel.Controls.Add(sendButton);
            buttonPanel.Controls.Add(cancelButton);

            dialog.Controls.Add(contentBox);
            dialog.Controls.Add(buttonPanel);
            dialog.AcceptButton = sendButton;
            dialog.CancelButton = cancelButton;

            return dialog.ShowDialog(this);
        }
    }
}