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

        private TextBox txtNo = null!;
        private TextBox txtDescription = null!;
        private DateTimePicker dtpTransferDate = null!;
        private DateTimePicker dtpReceiveDate = null!;
        private ComboBox cmbFromWarehouse = null!;
        private ComboBox cmbToWarehouse = null!;
        private CheckBox chkProductionCategory = null!;
        private Button btnSave = null!;
        private Button btnClose = null!;

        private readonly System.Collections.Generic.List<DataRow> rows = new();
        private readonly System.Collections.Generic.List<TransferOrderData.WarehouseOption> warehouseOptions = new();
        private int currentIndex = -1;
        private TransferOrderLinesForm? linesForm;
        private bool suppressProductionCategoryChange;
        private bool? lockedUseProductionCategory;

        public TransferOrdersForm()
        {
            InitializeForm(loadAllRecords: true);
            if (rows.Count > 0)
            {
                currentIndex = 0;
                ShowCurrentRecord();
            }
        }

        public TransferOrdersForm(string no)
        {
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
            Text = "Transfer Order";
            Size = new Size(900, 360);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.White;

            var lblNo = new Label { Text = "No.:", Location = new Point(20, 20), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            txtNo = new TextBox { Location = new Point(150, 20), Size = new Size(520, 28), Font = new Font("Arial", 10), ReadOnly = true };

            var lblDesc = new Label { Text = "Description:", Location = new Point(20, 64), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            txtDescription = new TextBox { Location = new Point(150, 64), Size = new Size(520, 48), Font = new Font("Arial", 10), Multiline = true, ScrollBars = ScrollBars.Vertical };

            var lblTransferDate = new Label { Text = "Transfer Date:", Location = new Point(20, 120), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            dtpTransferDate = new DateTimePicker { Location = new Point(150, 120), Size = new Size(220, 28) };
            dtpTransferDate.ValueChanged += (s, e) => { try { ShowDate(dtpTransferDate); } catch { } };

            var lblReceiveDate = new Label { Text = "Receive Date:", Location = new Point(380, 120), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            dtpReceiveDate = new DateTimePicker { Location = new Point(510, 120), Size = new Size(160, 28) };
            dtpReceiveDate.ValueChanged += (s, e) => { try { ShowDate(dtpReceiveDate); } catch { } };

            var lblFromWarehouse = new Label { Text = "From Warehouse:", Location = new Point(20, 160), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            cmbFromWarehouse = new ComboBox { Location = new Point(150, 160), Size = new Size(220, 28), DropDownStyle = ComboBoxStyle.DropDownList, Font = new Font("Arial", 10), Enabled = false };

            var lblToWarehouse = new Label { Text = "To Warehouse:", Location = new Point(380, 160), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            cmbToWarehouse = new ComboBox { Location = new Point(510, 160), Size = new Size(160, 28), DropDownStyle = ComboBoxStyle.DropDownList, Font = new Font("Arial", 10), Enabled = false };

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

            btnSave = new Button { Text = "Save", Size = new Size(100, 40), BackColor = Color.MediumBlue, ForeColor = Color.White };
            btnClose = new Button { Text = "Close", Size = new Size(100, 40) };
            btnSave.Click += BtnSave_Click;
            btnClose.Click += (s, e) => Close();

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
            actionPanel.Controls.AddRange(new Control[] { btnSave, btnClose });

            Controls.AddRange(new Control[] { lblNo, txtNo, lblDesc, txtDescription, lblTransferDate, dtpTransferDate, lblReceiveDate, dtpReceiveDate, lblFromWarehouse, cmbFromWarehouse, lblToWarehouse, cmbToWarehouse, chkProductionCategory, actionPanel });

            try
            {
                var tf = new TransferOrderLinesForm
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
        }

        private void LoadWarehouseOptions()
        {
            warehouseOptions.Clear();
            warehouseOptions.AddRange(TransferOrderData.GetWarehouseOptions(connectionString));

            cmbFromWarehouse.DataSource = null;
            cmbToWarehouse.DataSource = null;

            cmbFromWarehouse.DisplayMember = nameof(TransferOrderData.WarehouseOption.Name);
            cmbFromWarehouse.ValueMember = nameof(TransferOrderData.WarehouseOption.Id);
            cmbFromWarehouse.DataSource = new System.Collections.Generic.List<TransferOrderData.WarehouseOption>(warehouseOptions);

            cmbToWarehouse.DisplayMember = nameof(TransferOrderData.WarehouseOption.Name);
            cmbToWarehouse.ValueMember = nameof(TransferOrderData.WarehouseOption.Id);
            cmbToWarehouse.DataSource = new System.Collections.Generic.List<TransferOrderData.WarehouseOption>(warehouseOptions);

            ApplyDefaultCurrentWarehouseToSelection();
            ApplyPreferredFromWarehouse(forceSelection: true);
        }

        private void ApplyDefaultCurrentWarehouseToSelection()
        {
            var currentWarehouse = TransferOrderData.GetCurrentWarehouse(connectionString);
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
                using var cmd = new SqlCommand("SELECT [No.], [Description], [Transfer Date], [Receive Date], [Use Production Category], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse] FROM [Transfer Header] ORDER BY [No.]", conn);
                using var da = new SqlDataAdapter(cmd);
                var dt = new DataTable();
                da.Fill(dt);
                foreach (DataRow row in dt.Rows) rows.Add(row);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load Transfer Header records: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private bool TryLoadSingleRecord(string no)
        {
            rows.Clear();

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT [No.], [Description], [Transfer Date], [Receive Date], [Use Production Category], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse] FROM [Transfer Header] WHERE [No.] = @No", conn);
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
                MessageBox.Show(this, $"Failed to load Transfer Order {no}: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
            if (string.IsNullOrWhiteSpace(fromWarehouseId) && string.IsNullOrWhiteSpace(fromWarehouseName))
                ApplyPreferredFromWarehouse(forceSelection: true);

            SyncUseProductionCategoryToLines();
            SyncSourceWarehouseToLines();
            try { linesForm?.LoadForDocument(txtNo.Text); } catch { }
            UpdateCategoryChangeAvailability();
        }

        private void ClearFields()
        {
            txtNo.Text = string.Empty;
            txtDescription.Text = string.Empty;
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
        }

        private void BtnSave_Click(object? sender, EventArgs e)
        {
            string no = txtNo.Text.Trim();
            string desc = txtDescription.Text.Trim();
            DateTime? transferDate = IsBlankDate(dtpTransferDate) ? (DateTime?)null : dtpTransferDate.Value;
            DateTime? receiveDate = IsBlankDate(dtpReceiveDate) ? (DateTime?)null : dtpReceiveDate.Value;
            var fromWarehouse = GetSelectedWarehouse(cmbFromWarehouse);
            var toWarehouse = GetSelectedWarehouse(cmbToWarehouse);
            bool useProductionCategory = GetUseProductionCategory();

            if (string.IsNullOrWhiteSpace(no))
            {
                MessageBox.Show(this, "No. is required.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            if (fromWarehouse == null)
            {
                MessageBox.Show(this, "Please select a From Warehouse.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                cmbFromWarehouse.Focus();
                return;
            }

            if (IsSameWarehouse(fromWarehouse, toWarehouse))
            {
                MessageBox.Show(this, "From Warehouse cannot be the same as To Warehouse.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                cmbFromWarehouse.Focus();
                return;
            }

            try
            {
                using var conn = new SqlConnection(connectionString);
                conn.Open();
                using var check = new SqlCommand("SELECT COUNT(1) FROM [Transfer Header] WHERE [No.] = @No", conn);
                check.Parameters.AddWithValue("@No", no);
                bool exists = Convert.ToInt32(check.ExecuteScalar() ?? 0) > 0;

                string sql = exists
                    ? "UPDATE [Transfer Header] SET [Description] = @Description, [Transfer Date] = @TransferDate, [Receive Date] = @ReceiveDate, [Use Production Category] = @UseProductionCategory, [Category Code] = NULL, [From Warehouse ID] = @FromWarehouseId, [From Warehouse] = @FromWarehouse, [To Warehouse ID] = @ToWarehouseId, [To Warehouse] = @ToWarehouse WHERE [No.] = @No"
                    : "INSERT INTO [Transfer Header] ([No.], [Description], [Transfer Date], [Receive Date], [Use Production Category], [Category Code], [From Warehouse ID], [From Warehouse], [To Warehouse ID], [To Warehouse]) VALUES (@No, @Description, @TransferDate, @ReceiveDate, @UseProductionCategory, NULL, @FromWarehouseId, @FromWarehouse, @ToWarehouseId, @ToWarehouse)";

                using var cmd = new SqlCommand(sql, conn);
                cmd.Parameters.AddWithValue("@No", no);
                cmd.Parameters.AddWithValue("@Description", desc);
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
                MessageBox.Show(this, "Saved.", "Saved", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to save Transfer Order: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
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
    }
}