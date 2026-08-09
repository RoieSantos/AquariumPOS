using System;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Runtime.Versioning;
using System.Windows.Forms;

namespace AquariumPOS
{
    [SupportedOSPlatform("windows")]
    public class TransferOrdersForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;
        private readonly TransferOrderData.DocumentTableContext documentContext;

        private TextBox txtNo = null!;
        private TextBox txtDescription = null!;
        private TextBox txtCreatedDate = null!;
        private ComboBox cmbStatus = null!;
        private DateTimePicker dtpRequestedDate = null!;
        private DateTimePicker dtpEstimatedDeliveryDate = null!;
        private DateTimePicker dtpTransferDate = null!;
        private DateTimePicker dtpReceiveDate = null!;
        private ComboBox cmbFromWarehouse = null!;
        private ComboBox cmbToWarehouse = null!;
        private CheckBox chkProductionCategory = null!;
        private Button btnSave = null!;
        private Button btnPost = null!;
        private Button btnClose = null!;

        private readonly System.Collections.Generic.List<DataRow> rows = new();
        private readonly System.Collections.Generic.List<TransferOrderData.WarehouseOption> warehouseOptions = new();
        private int currentIndex = -1;
        private TransferOrderLinesForm? linesForm;
        private bool suppressProductionCategoryChange;
        private bool? lockedUseProductionCategory;
        private bool suppressAutoSaveOnClose;

        private static readonly string[] TransferStatuses = new[]
        {
            "",
            "Requested",
            "Shipped",
            "Partial Shipped",
            "Partially-Shipped",
            "Received"
        };

        public TransferOrdersForm()
            : this(TransferOrderData.PostedTransferOrders)
        {
        }

        internal TransferOrdersForm(TransferOrderData.DocumentTableContext documentContext)
        {
            this.documentContext = documentContext;
            InitializeForm(loadAllRecords: true);
            if (rows.Count > 0)
            {
                currentIndex = 0;
                ShowCurrentRecord();
            }
        }

        public TransferOrdersForm(string no)
            : this(no, TransferOrderData.PostedTransferOrders)
        {
        }

        internal TransferOrdersForm(string no, TransferOrderData.DocumentTableContext documentContext)
        {
            this.documentContext = documentContext;
            InitializeForm(loadAllRecords: false);

            try
            {
                if (string.IsNullOrWhiteSpace(no)) return;

                if (!TryLoadSingleRecord(no))
                {
                    ClearFields();
                    txtNo.Text = no;
                    currentIndex = -1;
                    try { linesForm?.LoadForDocument(txtNo.Text); } catch { }
                }
            }
            catch { }
        }

        private void InitializeForm(bool loadAllRecords)
        {
            InitializeComponent();
            WindowState = FormWindowState.Maximized;
            TransferOrderData.EnsureTablesExist(connectionString);
            LoadWarehouseOptions();
            if (loadAllRecords)
            {
                LoadAllRecords();
            }
        }

        private void InitializeComponent()
        {
            Text = documentContext.DocumentTitle;
            Size = new Size(980, 420);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            var lblNo = new Label { Text = "No.:", Location = new Point(20, 20), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            txtNo = new TextBox { Location = new Point(150, 20), Size = new Size(520, 28), Font = new Font("Arial", 10), ReadOnly = true };

            var lblDesc = new Label { Text = "Description:", Location = new Point(20, 64), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            txtDescription = new TextBox { Location = new Point(150, 64), Size = new Size(520, 48), Font = new Font("Arial", 10), Multiline = true, ScrollBars = ScrollBars.Vertical };

            var lblCreatedDate = new Label { Text = "Created Date:", Location = new Point(690, 64), Size = new Size(110, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            txtCreatedDate = new TextBox { Location = new Point(810, 64), Size = new Size(120, 28), Font = new Font("Arial", 10), ReadOnly = true };

            var lblStatus = new Label { Text = "Status:", Location = new Point(690, 20), Size = new Size(80, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            cmbStatus = new ComboBox { Location = new Point(770, 20), Size = new Size(160, 28), DropDownStyle = ComboBoxStyle.DropDownList, Font = new Font("Arial", 10) };
            cmbStatus.Items.AddRange(TransferStatuses);
            cmbStatus.SelectedIndex = 0;
            cmbStatus.Enabled = false;

            var lblTransferDate = new Label { Text = "Transfer Date:", Location = new Point(20, 120), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            dtpTransferDate = new DateTimePicker { Location = new Point(150, 120), Size = new Size(220, 28) };
            dtpTransferDate.ValueChanged += (s, e) => { try { ShowDate(dtpTransferDate); } catch { } };

            var lblReceiveDate = new Label { Text = "Receive Date:", Location = new Point(380, 120), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            dtpReceiveDate = new DateTimePicker { Location = new Point(510, 120), Size = new Size(160, 28) };
            dtpReceiveDate.ValueChanged += (s, e) => { try { ShowDate(dtpReceiveDate); UpdatePostButtonEnabledState(); } catch { } };

            var lblRequestedDate = new Label { Text = "Requested Date:", Location = new Point(690, 120), Size = new Size(110, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            dtpRequestedDate = new DateTimePicker { Location = new Point(810, 120), Size = new Size(120, 28) };
            dtpRequestedDate.ValueChanged += (s, e) => { try { ShowDate(dtpRequestedDate); } catch { } };

            var lblFromWarehouse = new Label { Text = "From Warehouse:", Location = new Point(20, 160), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            cmbFromWarehouse = new ComboBox { Location = new Point(150, 160), Size = new Size(220, 28), DropDownStyle = ComboBoxStyle.DropDownList, Font = new Font("Arial", 10), Enabled = false };

            var lblToWarehouse = new Label { Text = "To Warehouse:", Location = new Point(380, 160), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            cmbToWarehouse = new ComboBox { Location = new Point(510, 160), Size = new Size(160, 28), DropDownStyle = ComboBoxStyle.DropDownList, Font = new Font("Arial", 10), Enabled = false };

            var lblEstimatedDeliveryDate = new Label { Text = "Estimated Delivery Date:", Location = new Point(690, 160), Size = new Size(150, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            dtpEstimatedDeliveryDate = new DateTimePicker { Location = new Point(840, 160), Size = new Size(90, 28) };
            dtpEstimatedDeliveryDate.ValueChanged += (s, e) => { try { ShowDate(dtpEstimatedDeliveryDate); } catch { } };

            chkProductionCategory = new CheckBox
            {
                Text = "Production Category",
                Location = new Point(150, 204),
                Size = new Size(220, 24),
                Font = new Font("Arial", 10, FontStyle.Regular),
                Checked = false
            };
            chkProductionCategory.CheckedChanged += ChkProductionCategory_CheckedChanged;

            BlankDate(dtpTransferDate);
            BlankDate(dtpReceiveDate);
            BlankDate(dtpRequestedDate);
            BlankDate(dtpEstimatedDeliveryDate);

            btnSave = new Button { Text = "Save", Size = new Size(100, 40), BackColor = Color.MediumBlue, ForeColor = Color.White };
            btnPost = new Button { Text = "POST", Size = new Size(100, 40), BackColor = Color.SeaGreen, ForeColor = Color.White };
            btnClose = new Button { Text = "Close", Size = new Size(100, 40) };
            btnSave.Click += BtnSave_Click;
            btnPost.Click += BtnPost_Click;
            btnClose.Click += (s, e) => Close();
            btnSave.Visible = !documentContext.IsReadOnly;
            btnPost.Visible = !documentContext.IsReadOnly;

            var actionPanel = new FlowLayoutPanel
            {
                Location = new Point(150, 248),
                Size = new Size(520, 52),
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false,
                Padding = new Padding(0),
                Margin = new Padding(0),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right
            };
            actionPanel.Controls.AddRange(new Control[] { btnSave, btnPost, btnClose });

            Controls.AddRange(new Control[] { lblNo, txtNo, lblStatus, cmbStatus, lblDesc, txtDescription, lblCreatedDate, txtCreatedDate, lblTransferDate, dtpTransferDate, lblReceiveDate, dtpReceiveDate, lblRequestedDate, dtpRequestedDate, lblFromWarehouse, cmbFromWarehouse, lblToWarehouse, cmbToWarehouse, lblEstimatedDeliveryDate, dtpEstimatedDeliveryDate, chkProductionCategory, actionPanel });

            try
            {
                var tf = new TransferOrderLinesForm(documentContext)
                {
                    TopLevel = false,
                    FormBorderStyle = FormBorderStyle.None,
                    Dock = DockStyle.Bottom,
                    Height = Math.Max(300, ClientSize.Height - 308)
                };
                Controls.Add(tf);
                tf.Show();
                linesForm = tf;
                Resize += (s, e) => { try { tf.Height = Math.Max(300, ClientSize.Height - 308); } catch { } };
            }
            catch { }

            FormClosing += TransferOrdersForm_FormClosing;
            ApplyReadOnlyState();
            UpdatePostButtonEnabledState();
        }

        private void ApplyReadOnlyState()
        {
            if (!documentContext.IsReadOnly)
                return;

            txtDescription.ReadOnly = true;
            dtpTransferDate.Enabled = false;
            dtpReceiveDate.Enabled = false;
            dtpRequestedDate.Enabled = false;
            dtpEstimatedDeliveryDate.Enabled = false;
            cmbFromWarehouse.Enabled = false;
            cmbToWarehouse.Enabled = false;
            chkProductionCategory.Enabled = false;
        }

        private void LoadWarehouseOptions()
        {
            warehouseOptions.Clear();
            warehouseOptions.AddRange(TransferOrderData.GetWarehouseOptions(connectionString));

            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(connectionString);
            var fromWarehouseOptions = BuildFromWarehouseOptions(currentWarehouse);
            var toWarehouseOptions = BuildToWarehouseOptions(currentWarehouse);

            cmbFromWarehouse.DataSource = null;
            cmbToWarehouse.DataSource = null;

            cmbFromWarehouse.DisplayMember = nameof(TransferOrderData.WarehouseOption.Name);
            cmbFromWarehouse.ValueMember = nameof(TransferOrderData.WarehouseOption.Id);
            cmbFromWarehouse.DataSource = fromWarehouseOptions;

            cmbToWarehouse.DisplayMember = nameof(TransferOrderData.WarehouseOption.Name);
            cmbToWarehouse.ValueMember = nameof(TransferOrderData.WarehouseOption.Id);
            cmbToWarehouse.DataSource = toWarehouseOptions;

            ApplyDefaultCurrentWarehouseToSelection(currentWarehouse);
            ApplyPreferredFromWarehouse(forceSelection: true);
        }

        private System.Collections.Generic.List<TransferOrderData.WarehouseOption> BuildFromWarehouseOptions(TransferOrderData.WarehouseOption? currentWarehouse)
        {
            if (IsTransferRequestContext()
                && currentWarehouse != null
                && (currentWarehouse.IsProductionWarehouse || currentWarehouse.IsStockWarehouse))
            {
                var currentMatch = warehouseOptions.Find(option => string.Equals(option.Id, currentWarehouse.Id, StringComparison.OrdinalIgnoreCase));
                if (currentMatch != null)
                    return new System.Collections.Generic.List<TransferOrderData.WarehouseOption> { currentMatch };
            }

            if (currentWarehouse != null
                && currentWarehouse.IsProductionWarehouse)
            {
                var currentMatch = warehouseOptions.Find(option => string.Equals(option.Id, currentWarehouse.Id, StringComparison.OrdinalIgnoreCase));
                if (currentMatch != null)
                    return new System.Collections.Generic.List<TransferOrderData.WarehouseOption> { currentMatch };
            }

            return new System.Collections.Generic.List<TransferOrderData.WarehouseOption>(warehouseOptions);
        }

        private bool IsTransferRequestContext()
        {
            return string.Equals(documentContext.HeaderTableName, TransferOrderData.TransferRequests.HeaderTableName, StringComparison.OrdinalIgnoreCase);
        }

        private System.Collections.Generic.List<TransferOrderData.WarehouseOption> BuildToWarehouseOptions(TransferOrderData.WarehouseOption? currentWarehouse)
        {
            if (currentWarehouse != null
                && !IsTransferRequestContext()
                && !currentWarehouse.IsProductionWarehouse
                && currentWarehouse.IsStockWarehouse)
            {
                var currentMatch = warehouseOptions.Find(option => string.Equals(option.Id, currentWarehouse.Id, StringComparison.OrdinalIgnoreCase));
                if (currentMatch != null)
                    return new System.Collections.Generic.List<TransferOrderData.WarehouseOption> { currentMatch };
            }

            return new System.Collections.Generic.List<TransferOrderData.WarehouseOption>(warehouseOptions);
        }

        private void ApplyDefaultCurrentWarehouseToSelection(TransferOrderData.WarehouseOption? currentWarehouse = null)
        {
            currentWarehouse ??= TransferOrderData.GetCurrentWarehouse(connectionString);
            if (currentWarehouse == null)
                return;

            SelectWarehouse(cmbToWarehouse, currentWarehouse.Id, currentWarehouse.Name);
        }

        private void CmbFromWarehouse_SelectedIndexChanged(object? sender, EventArgs e)
        {
            if (IsSameWarehouse(GetSelectedWarehouse(cmbFromWarehouse), GetSelectedWarehouse(cmbToWarehouse)))
            {
                if (cmbFromWarehouse.Focused)
                {
                    MessageBox.Show(this, "From Warehouse cannot be the same as To Warehouse.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }

                cmbFromWarehouse.SelectedIndex = -1;
                SyncSourceWarehouseToLines();
                return;
            }

            SyncSourceWarehouseToLines();
        }

        private void ChkProductionCategory_CheckedChanged(object? sender, EventArgs e)
        {
            if (suppressProductionCategoryChange)
                return;

            bool useProductionCategory = GetUseProductionCategory();
            if (linesForm?.HasLines() == true && lockedUseProductionCategory.HasValue && useProductionCategory != lockedUseProductionCategory.Value)
            {
                suppressProductionCategoryChange = true;
                try
                {
                    chkProductionCategory.Checked = lockedUseProductionCategory.Value;
                }
                finally
                {
                    suppressProductionCategoryChange = false;
                }

                MessageBox.Show(this, "You cannot change the Production Category setting after transfer lines have been inserted.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            lockedUseProductionCategory = useProductionCategory;
            ApplyPreferredFromWarehouse(forceSelection: true);
            SyncUseProductionCategoryToLines();
            UpdateCategoryChangeAvailability();
        }

        private bool GetUseProductionCategory()
        {
            return chkProductionCategory?.Checked == true;
        }

        private void UpdateCategoryChangeAvailability()
        {
            bool hasLines = linesForm?.HasLines() == true;
            chkProductionCategory.Enabled = !hasLines;
        }

        private static void SelectWarehouse(ComboBox comboBox, string? warehouseId, string? warehouseName)
        {
            if (comboBox.DataSource == null) return;

            if (!string.IsNullOrWhiteSpace(warehouseId))
            {
                comboBox.SelectedValue = warehouseId;
                if (string.Equals(comboBox.SelectedValue?.ToString(), warehouseId, StringComparison.OrdinalIgnoreCase))
                    return;
            }

            if (string.IsNullOrWhiteSpace(warehouseName)) return;

            for (int i = 0; i < comboBox.Items.Count; i++)
            {
                if (comboBox.Items[i] is TransferOrderData.WarehouseOption option
                    && string.Equals(option.Name, warehouseName, StringComparison.OrdinalIgnoreCase))
                {
                    comboBox.SelectedIndex = i;
                    return;
                }
            }
        }

        private TransferOrderData.WarehouseOption? GetSelectedWarehouse(ComboBox comboBox)
        {
            return comboBox.SelectedItem as TransferOrderData.WarehouseOption;
        }

        private void SyncSourceWarehouseToLines()
        {
            try
            {
                linesForm?.SetSourceWarehouse(GetSelectedWarehouse(cmbFromWarehouse)?.Id);
            }
            catch { }
        }

        private void SyncUseProductionCategoryToLines()
        {
            try
            {
                linesForm?.SetUseProductionCategory(GetUseProductionCategory());
                UpdateCategoryChangeAvailability();
            }
            catch { }
        }

        private void ApplyPreferredFromWarehouse(bool forceSelection)
        {
            var preferredWarehouse = TransferOrderData.GetPreferredFromWarehouse(connectionString, GetUseProductionCategory());
            if (preferredWarehouse == null)
                return;

            var currentWarehouse = GetSelectedWarehouse(cmbFromWarehouse);
            if (!forceSelection && currentWarehouse != null)
                return;

            SelectWarehouse(cmbFromWarehouse, preferredWarehouse.Id, preferredWarehouse.Name);
        }

        private static bool IsSameWarehouse(TransferOrderData.WarehouseOption? fromWarehouse, TransferOrderData.WarehouseOption? toWarehouse)
        {
            if (fromWarehouse == null || toWarehouse == null)
                return false;

            if (!string.IsNullOrWhiteSpace(fromWarehouse.Id) && !string.IsNullOrWhiteSpace(toWarehouse.Id))
            {
                return string.Equals(fromWarehouse.Id, toWarehouse.Id, StringComparison.OrdinalIgnoreCase);
            }

            return string.Equals(fromWarehouse.Name, toWarehouse.Name, StringComparison.OrdinalIgnoreCase);
        }


        private void LoadAllRecords()
        {
            rows.Clear();
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand($"SELECT [No.], [Description], [Created Date], [Status], [Requested Date], [Estimated Delivery Date], [Transfer Date], [Receive Date], [Posted Date], [Use Production Category], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse] FROM {documentContext.HeaderTableName} ORDER BY [No.]", conn);
                using var da = new SqlDataAdapter(cmd);
                var dt = new DataTable();
                da.Fill(dt);
                foreach (DataRow row in dt.Rows) rows.Add(row);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load {documentContext.DocumentTitle} records: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private bool TryLoadSingleRecord(string no)
        {
            rows.Clear();

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand($"SELECT [No.], [Description], [Created Date], [Status], [Requested Date], [Estimated Delivery Date], [Transfer Date], [Receive Date], [Posted Date], [Use Production Category], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse] FROM {documentContext.HeaderTableName} WHERE [No.] = @No", conn);
                cmd.Parameters.AddWithValue("@No", no);
                using var da = new SqlDataAdapter(cmd);
                var dt = new DataTable();
                da.Fill(dt);
                foreach (DataRow row in dt.Rows) rows.Add(row);

                if (rows.Count == 0)
                    return false;

                currentIndex = 0;
                ShowCurrentRecord();
                return true;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load {documentContext.DocumentTitle} {no}: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        private void ShowCurrentRecord()
        {
            if (currentIndex < 0 || currentIndex >= rows.Count)
            {
                ClearFields();
                return;
            }

            var row = rows[currentIndex];
            txtNo.Text = row.Table.Columns.Contains("No.") && row["No."] != DBNull.Value ? row["No."].ToString() ?? string.Empty : string.Empty;
            txtDescription.Text = row.Table.Columns.Contains("Description") && row["Description"] != DBNull.Value ? row["Description"].ToString() ?? string.Empty : string.Empty;
            txtCreatedDate.Text = row.Table.Columns.Contains("Created Date") && row["Created Date"] != DBNull.Value
                ? Convert.ToDateTime(row["Created Date"]).ToString("yyyy-MM-dd")
                : string.Empty;
            string currentStatus = row.Table.Columns.Contains("Status") && row["Status"] != DBNull.Value ? row["Status"].ToString() ?? string.Empty : string.Empty;
            SetStatusValue(currentStatus);

            if (row.Table.Columns.Contains("Requested Date") && row["Requested Date"] != DBNull.Value)
            {
                try { SetDate(dtpRequestedDate, Convert.ToDateTime(row["Requested Date"])); } catch { BlankDate(dtpRequestedDate); }
            }
            else
            {
                BlankDate(dtpRequestedDate);
            }

            if (row.Table.Columns.Contains("Estimated Delivery Date") && row["Estimated Delivery Date"] != DBNull.Value)
            {
                try { SetDate(dtpEstimatedDeliveryDate, Convert.ToDateTime(row["Estimated Delivery Date"])); } catch { BlankDate(dtpEstimatedDeliveryDate); }
            }
            else
            {
                BlankDate(dtpEstimatedDeliveryDate);
            }

            if (row.Table.Columns.Contains("Transfer Date") && row["Transfer Date"] != DBNull.Value)
            {
                try { SetDate(dtpTransferDate, Convert.ToDateTime(row["Transfer Date"])); } catch { BlankDate(dtpTransferDate); }
            }
            else
            {
                BlankDate(dtpTransferDate);
            }

            if (row.Table.Columns.Contains("Receive Date") && row["Receive Date"] != DBNull.Value)
            {
                try { SetDate(dtpReceiveDate, Convert.ToDateTime(row["Receive Date"])); } catch { BlankDate(dtpReceiveDate); }
            }
            else
            {
                BlankDate(dtpReceiveDate);
            }

            SelectWarehouse(
                cmbFromWarehouse,
                row.Table.Columns.Contains("From Warehouse ID") && row["From Warehouse ID"] != DBNull.Value ? row["From Warehouse ID"].ToString() : null,
                row.Table.Columns.Contains("From Warehouse") && row["From Warehouse"] != DBNull.Value ? row["From Warehouse"].ToString() : null);

            var toWarehouseId = row.Table.Columns.Contains("To Warehouse ID") && row["To Warehouse ID"] != DBNull.Value ? row["To Warehouse ID"].ToString() : null;
            var toWarehouseName = row.Table.Columns.Contains("To Warehouse") && row["To Warehouse"] != DBNull.Value ? row["To Warehouse"].ToString() : null;
            if (string.IsNullOrWhiteSpace(toWarehouseId) && string.IsNullOrWhiteSpace(toWarehouseName))
                ApplyDefaultCurrentWarehouseToSelection();
            else
                SelectWarehouse(cmbToWarehouse, toWarehouseId, toWarehouseName);

            bool useProductionCategory = row.Table.Columns.Contains("Use Production Category") && row["Use Production Category"] != DBNull.Value && Convert.ToBoolean(row["Use Production Category"]);
            suppressProductionCategoryChange = true;
            try
            {
                chkProductionCategory.Checked = useProductionCategory;
            }
            finally
            {
                suppressProductionCategoryChange = false;
            }

            lockedUseProductionCategory = GetUseProductionCategory();

            var fromWarehouseId = row.Table.Columns.Contains("From Warehouse ID") && row["From Warehouse ID"] != DBNull.Value ? row["From Warehouse ID"].ToString() : null;
            var fromWarehouseName = row.Table.Columns.Contains("From Warehouse") && row["From Warehouse"] != DBNull.Value ? row["From Warehouse"].ToString() : null;
            bool shouldAutoAssignFromWarehouse = string.IsNullOrWhiteSpace(currentStatus);
            if (shouldAutoAssignFromWarehouse
                && string.IsNullOrWhiteSpace(fromWarehouseId)
                && string.IsNullOrWhiteSpace(fromWarehouseName))
                ApplyPreferredFromWarehouse(forceSelection: true);

            SyncUseProductionCategoryToLines();
            SyncSourceWarehouseToLines();
            try { linesForm?.LoadForDocument(txtNo.Text); } catch { }
            UpdateCategoryChangeAvailability();
            UpdatePostButtonEnabledState();
        }

        private void ClearFields()
        {
            txtNo.Text = string.Empty;
            txtDescription.Text = string.Empty;
            txtCreatedDate.Text = string.Empty;
            SetStatusValue(null);
            BlankDate(dtpRequestedDate);
            BlankDate(dtpEstimatedDeliveryDate);
            BlankDate(dtpTransferDate);
            BlankDate(dtpReceiveDate);
            if (cmbFromWarehouse.Items.Count > 0) cmbFromWarehouse.SelectedIndex = -1;
            suppressProductionCategoryChange = true;
            try
            {
                chkProductionCategory.Checked = false;
            }
            finally
            {
                suppressProductionCategoryChange = false;
            }
            lockedUseProductionCategory = false;
            ApplyDefaultCurrentWarehouseToSelection();
            ApplyPreferredFromWarehouse(forceSelection: true);
            SyncUseProductionCategoryToLines();
            SyncSourceWarehouseToLines();
            UpdateCategoryChangeAvailability();
            UpdatePostButtonEnabledState();
        }

        private void BtnSave_Click(object? sender, EventArgs e)
        {
            if (documentContext.IsReadOnly)
                return;

            SaveCurrentRecord(showSuccessMessage: true);
        }

        private bool SaveCurrentRecord(bool showSuccessMessage)
        {
            if (documentContext.IsReadOnly)
                return true;

            string no = txtNo.Text.Trim();
            string desc = txtDescription.Text.Trim();
            string status = GetSelectedStatus();
            DateTime? requestedDate = IsBlankDate(dtpRequestedDate) ? (DateTime?)null : dtpRequestedDate.Value;
            DateTime? estimatedDeliveryDate = IsBlankDate(dtpEstimatedDeliveryDate) ? (DateTime?)null : dtpEstimatedDeliveryDate.Value;
            DateTime? transferDate = IsBlankDate(dtpTransferDate) ? (DateTime?)null : dtpTransferDate.Value;
            DateTime? receiveDate = IsBlankDate(dtpReceiveDate) ? (DateTime?)null : dtpReceiveDate.Value;
            var fromWarehouse = GetSelectedWarehouse(cmbFromWarehouse);
            var toWarehouse = GetSelectedWarehouse(cmbToWarehouse);
            bool useProductionCategory = GetUseProductionCategory();

            if (string.IsNullOrWhiteSpace(no))
            {
                MessageBox.Show(this, "No. is required.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            if (fromWarehouse == null)
            {
                MessageBox.Show(this, "Please select a From Warehouse.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                cmbFromWarehouse.Focus();
                return false;
            }

            if (IsSameWarehouse(fromWarehouse, toWarehouse))
            {
                MessageBox.Show(this, "From Warehouse cannot be the same as To Warehouse.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                cmbFromWarehouse.Focus();
                return false;
            }

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var check = new SqlCommand($"SELECT COUNT(1) FROM {documentContext.HeaderTableName} WHERE [No.] = @No", conn);
                check.Parameters.AddWithValue("@No", no);
                bool exists = Convert.ToInt32(check.ExecuteScalar() ?? 0) > 0;

                string sql = exists
                    ? $"UPDATE {documentContext.HeaderTableName} SET [Description] = @Description, [Status] = @Status, [Requested Date] = @RequestedDate, [Estimated Delivery Date] = @EstimatedDeliveryDate, [Transfer Date] = @TransferDate, [Receive Date] = @ReceiveDate, [Use Production Category] = @UseProductionCategory, [Category Code] = NULL, [From Warehouse ID] = @FromWarehouseId, [From Warehouse] = @FromWarehouse, [To Warehouse ID] = @ToWarehouseId, [To Warehouse] = @ToWarehouse WHERE [No.] = @No"
                    : $"INSERT INTO {documentContext.HeaderTableName} ([No.], [Description], [Created Date], [Status], [Requested Date], [Estimated Delivery Date], [Transfer Date], [Receive Date], [Use Production Category], [Category Code], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse]) VALUES (@No, @Description, @CreatedDate, @Status, @RequestedDate, @EstimatedDeliveryDate, @TransferDate, @ReceiveDate, @UseProductionCategory, NULL, @FromWarehouseId, @FromWarehouse, @ToWarehouseId, @ToWarehouse)";

                using var cmd = new SqlCommand(sql, conn);
                cmd.Parameters.AddWithValue("@No", no);
                cmd.Parameters.AddWithValue("@Description", desc);
                cmd.Parameters.AddWithValue("@CreatedDate", DateTime.Today);
                cmd.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(status) ? (object)DBNull.Value : status);
                cmd.Parameters.AddWithValue("@RequestedDate", (object?)requestedDate ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@EstimatedDeliveryDate", (object?)estimatedDeliveryDate ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@TransferDate", (object?)transferDate ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@ReceiveDate", (object?)receiveDate ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@UseProductionCategory", useProductionCategory);
                cmd.Parameters.AddWithValue("@FromWarehouseId", string.IsNullOrWhiteSpace(fromWarehouse.Id) ? (object)DBNull.Value : fromWarehouse.Id);
                cmd.Parameters.AddWithValue("@FromWarehouse", string.IsNullOrWhiteSpace(fromWarehouse.Name) ? (object)DBNull.Value : fromWarehouse.Name);
                cmd.Parameters.AddWithValue("@ToWarehouseId", string.IsNullOrWhiteSpace(toWarehouse?.Id) ? (object)DBNull.Value : toWarehouse!.Id);
                cmd.Parameters.AddWithValue("@ToWarehouse", string.IsNullOrWhiteSpace(toWarehouse?.Name) ? (object)DBNull.Value : toWarehouse!.Name);
                cmd.ExecuteNonQuery();

                lockedUseProductionCategory = useProductionCategory;
                LoadAllRecords();
                currentIndex = rows.FindIndex(r => (r["No."]?.ToString() ?? string.Empty) == no);
                ShowCurrentRecord();
                if (showSuccessMessage)
                    MessageBox.Show(this, "Saved.", "Saved", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return true;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to save {documentContext.DocumentTitle}: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        private void TransferOrdersForm_FormClosing(object? sender, FormClosingEventArgs e)
        {
            if (documentContext.IsReadOnly)
                return;

            if (suppressAutoSaveOnClose)
                return;

            if (!ShouldAutoSaveOnClose())
                return;

            if (SaveCurrentRecord(showSuccessMessage: false))
                return;

            e.Cancel = true;
        }

        private void BtnPost_Click(object? sender, EventArgs e)
        {
            if (documentContext.IsReadOnly)
                return;

            string documentNo = txtNo.Text.Trim();
            if (string.IsNullOrWhiteSpace(documentNo))
            {
                MessageBox.Show(this, "Document No. is required to POST.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                txtNo.Focus();
                return;
            }

            if (!SaveCurrentRecord(showSuccessMessage: false))
                return;

            if (!IsBlankDate(dtpReceiveDate))
            {
                MessageBox.Show(this, "Cannot POST because Receive Date is already filled.", "POST", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                UpdatePostButtonEnabledState();
                return;
            }

            bool alreadyPosted = IsTransferOrderAlreadyPosted(documentNo);
            string currentStatus = GetSelectedStatus();
            bool isPostShipAction = string.Equals(currentStatus, "Requested", StringComparison.OrdinalIgnoreCase);

            string sourceLocationName = GetSelectedWarehouse(cmbFromWarehouse)?.Name?.Trim() ?? string.Empty;
            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(connectionString);
            string destinationLocationName = currentWarehouse?.Name?.Trim() ?? GetSelectedWarehouse(cmbToWarehouse)?.Name?.Trim() ?? string.Empty;

            if (isPostShipAction)
            {
                var shipmentConfirm = MessageBox.Show(this, "Post shipment?", "Post Ship", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (shipmentConfirm != DialogResult.Yes)
                    return;

                if (linesForm?.HasAnyShipmentToPost() != true)
                {
                    MessageBox.Show(this, "Please fill in Qty To Ship before posting shipment.", "Post Ship", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    try { linesForm?.FocusFirstQtyShippedCell(); } catch { }
                    return;
                }

                try { linesForm?.ApplyCalculatedQtyShippedForPosting(); } catch { }

                string shippedStatus = DetermineShipmentStatus(documentNo);
                if (!string.IsNullOrWhiteSpace(shippedStatus) && !string.Equals(currentStatus, shippedStatus, StringComparison.OrdinalIgnoreCase))
                {
                    SetStatusValue(shippedStatus);
                    currentStatus = shippedStatus;
                    if (!SaveCurrentRecord(showSuccessMessage: false))
                        return;
                }
            }

            if (string.IsNullOrWhiteSpace(currentStatus))
            {
                SetStatusValue("Requested");
                if (IsBlankDate(dtpRequestedDate))
                    SetDate(dtpRequestedDate, DateTime.Today);

                if (!SaveCurrentRecord(showSuccessMessage: false))
                    return;
            }

            try
            {
                var preview = OnlinefunctionsEvents.GetTransferOnlineOrderRequestPreview(documentNo, documentContext);
                var debugConfirm = MessageBox.Show(
                    this,
                    (alreadyPosted
                        ? $"This will update the existing cloud request from location {sourceLocationName} to your current store {destinationLocationName}."
                        : $"This will create a request from location {sourceLocationName} to your current store {destinationLocationName}.")
                    + (string.IsNullOrWhiteSpace(preview.PreviewWarning) ? string.Empty : $"\n\nPreview Warning:\n{preview.PreviewWarning}")
                    + $"\n\nHeader Method: {preview.HeaderMethod}\nHeader Endpoint:\n{preview.HeaderEndpointUrl}\n\nHeader Payload:\n{preview.HeaderPayloadJson}\n\nLine Requests:\n{preview.LineRequestPreviewText}\n\nContinue sending these requests?",
                    "Transfer Cloud Request",
                    MessageBoxButtons.OKCancel,
                    MessageBoxIcon.Information);
                if (debugConfirm != DialogResult.OK)
                    return;

                string response = OnlinefunctionsEvents.CreateTransferOnlineOrder(documentNo, documentContext);
                MarkTransferOrderPosted(documentNo, response);
                TryLoadSingleRecord(documentNo);
                MessageBox.Show(this, alreadyPosted ? $"{documentContext.DocumentTitle} updated in the cloud." : $"{documentContext.DocumentTitle} posted to the cloud.", "POST", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"{documentContext.DocumentTitle} was not posted to the cloud: {ex.Message}", "POST Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private bool IsTransferOrderAlreadyPosted(string documentNo)
        {
            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand($"SELECT COUNT(1) FROM {documentContext.HeaderTableName} WHERE [No.] = @No AND ISNULL([Sent To Online], 0) = 1", conn);
                cmd.Parameters.AddWithValue("@No", documentNo);
                return Convert.ToInt32(cmd.ExecuteScalar() ?? 0) > 0;
            }
            catch
            {
                return false;
            }
        }

        private string DetermineShipmentStatus(string documentNo)
        {
            if (string.IsNullOrWhiteSpace(documentNo))
                return string.Empty;

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand($@"
SELECT [Available QTY], [Qty Received]
FROM {documentContext.LineTableName}
WHERE [Document No.] = @DocNo", conn);
                cmd.Parameters.AddWithValue("@DocNo", documentNo);

                using var rdr = cmd.ExecuteReader();
                bool hasLines = false;
                bool hasAnyShipped = false;
                bool allShipped = true;

                while (rdr.Read())
                {
                    hasLines = true;
                    decimal quantity = 0m;
                    decimal qtyShipped = 0m;

                    try { if (rdr["Available QTY"] != DBNull.Value) quantity = Convert.ToDecimal(rdr["Available QTY"]); } catch { quantity = 0m; }
                    try { if (rdr["Qty Received"] != DBNull.Value) qtyShipped = Convert.ToDecimal(rdr["Qty Received"]); } catch { qtyShipped = 0m; }

                    if (qtyShipped > 0m)
                        hasAnyShipped = true;

                    if (quantity != qtyShipped)
                        allShipped = false;
                }

                if (!hasLines || !hasAnyShipped)
                    return string.Empty;

                return allShipped ? "Shipped" : "Partial Shipped";
            }
            catch
            {
                return string.Empty;
            }
        }

        private void MarkTransferOrderPosted(string documentNo, string response)
        {
            using var conn = new SqlConnection(connectionString);
            conn.Open();
            using var cmd = new SqlCommand(@"
UPDATE " + documentContext.HeaderTableName + @"
SET [Posted Date] = COALESCE([Posted Date], SYSUTCDATETIME()),
    [Sent To Online] = 1,
    [Online Transfer Response] = @Response
WHERE [No.] = @No", conn);
            cmd.Parameters.AddWithValue("@No", documentNo);
            cmd.Parameters.AddWithValue("@Response", string.IsNullOrWhiteSpace(response) ? (object)DBNull.Value : response);
            cmd.ExecuteNonQuery();
        }

        private void UpdatePostButtonEnabledState()
        {
            try
            {
                if (btnPost != null)
                {
                    string currentStatus = GetSelectedStatus();
                    btnPost.Text = string.IsNullOrWhiteSpace(currentStatus)
                        ? "Request"
                        : string.Equals(currentStatus, "Requested", StringComparison.OrdinalIgnoreCase)
                            ? "Post Ship"
                            : "POST";
                }

                if (documentContext.IsReadOnly)
                {
                    if (btnPost != null)
                        btnPost.Enabled = false;
                    return;
                }

                bool receiveDateFilled = !IsBlankDate(dtpReceiveDate);
                if (btnPost != null)
                    btnPost.Enabled = !receiveDateFilled;
            }
            catch { }
        }

        private static void BlankDate(DateTimePicker picker)
        {
            picker.Format = DateTimePickerFormat.Custom;
            picker.CustomFormat = " ";
        }

        private static void ShowDate(DateTimePicker picker)
        {
            picker.Format = DateTimePickerFormat.Custom;
            picker.CustomFormat = "yyyy-MM-dd";
        }

        private static void SetDate(DateTimePicker picker, DateTime value)
        {
            ShowDate(picker);
            picker.Value = value;
        }

        private static bool IsBlankDate(DateTimePicker picker)
        {
            return string.IsNullOrWhiteSpace(picker.CustomFormat) || picker.CustomFormat == " ";
        }

        private bool ShouldAutoSaveOnClose()
        {
            return !string.IsNullOrWhiteSpace(txtNo.Text)
                || !string.IsNullOrWhiteSpace(txtDescription.Text)
                || cmbFromWarehouse.SelectedIndex >= 0
                || cmbToWarehouse.SelectedIndex >= 0;
        }

        private string GetSelectedStatus()
        {
            string status = cmbStatus?.SelectedItem?.ToString()?.Trim() ?? string.Empty;
            foreach (string option in TransferStatuses)
            {
                if (string.Equals(option, status, StringComparison.OrdinalIgnoreCase))
                    return option;
            }

            return string.Empty;
        }

        private void SetStatusValue(string? status)
        {
            string resolved = string.Empty;
            if (!string.IsNullOrWhiteSpace(status))
            {
                foreach (string option in TransferStatuses)
                {
                    if (string.Equals(option, status.Trim(), StringComparison.OrdinalIgnoreCase))
                    {
                        resolved = option;
                        break;
                    }
                }
            }

            if (cmbStatus != null)
                cmbStatus.SelectedItem = resolved;
        }
    }
}