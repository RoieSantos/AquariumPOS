using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Drawing.Printing;
using System.Linq;
using System.Text;
using System.Runtime.Versioning;
using System.Windows.Forms;
namespace AquariumPOS
{
    [SupportedOSPlatform("windows")]
    public class PurchaseOrdersForm : Form
    {
        private readonly string connectionString = GlobalSettings.ConnectionString;

        private TextBox txtNo = null!;
        private TextBox txtDescription = null!;
        private DateTimePicker dtpPODate = null!;
        private DateTimePicker dtpReceivedDate = null!;

        private Button btnGenerate = null!;
        private Button btnClear = null!;
        private Button btnPrint = null!;

        private Button btnPost = null!;



        private List<DataRow> rows = new List<DataRow>();
        private int currentIndex = -1;
        private PurchaseOrderLinesForm? linesForm = null;

        public PurchaseOrdersForm()
        {
            InitializeComponent();
            this.WindowState = FormWindowState.Maximized;
            LoadAllRecords();
            if (rows.Count > 0)
            {
                currentIndex = 0;
                ShowCurrentRecord();
            }
        }

        // Open form and show specific record by No.
        public PurchaseOrdersForm(string no) : this()
        {
            try
            {
                if (!string.IsNullOrWhiteSpace(no))
                {
                    int idx = rows.FindIndex(r => (r.Table.Columns.Contains("No.") && (r["No."]?.ToString() ?? "") == no));
                    if (idx >= 0)
                    {
                        currentIndex = idx;
                        ShowCurrentRecord();
                    }
                    else
                    {
                        // If not found, preload No. for quick create and still load any existing lines for that document
                        ClearFields();
                        txtNo.Text = no;
                        currentIndex = -1;
                        try { if (linesForm != null) linesForm.LoadForDocument(txtNo.Text); } catch { }
                    }
                }
            }
            catch { }
        }

        private void InitializeComponent()
        {
            this.Text = "Purchase Orders";
            this.Size = new Size(900, 360);
            this.StartPosition = FormStartPosition.CenterParent;
            this.BackColor = Color.White;

            var lblNo = new Label { Text = "No.:", Location = new Point(20, 20), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            txtNo = new TextBox { Location = new Point(150, 20), Size = new Size(520, 28), Font = new Font("Arial", 10) };

            var lblDesc = new Label { Text = "Description:", Location = new Point(20, 64), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            // Make the description smaller so there's more room for the buttons area
            txtDescription = new TextBox { Location = new Point(150, 64), Size = new Size(520, 48), Font = new Font("Arial", 10), Multiline = true, ScrollBars = ScrollBars.Vertical };

            // Shift PO/Received controls upward to fit the reduced description area
            var lblPODate = new Label { Text = "PO Date:", Location = new Point(20, 120), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            dtpPODate = new DateTimePicker { Location = new Point(150, 120), Size = new Size(220, 28) };
            dtpPODate.ValueChanged += (s, e) => { try { ShowDate(dtpPODate); } catch { } };

            var lblReceived = new Label { Text = "Received Date:", Location = new Point(380, 120), Size = new Size(120, 28), Font = new Font("Arial", 10, FontStyle.Bold) };
            dtpReceivedDate = new DateTimePicker { Location = new Point(510, 120), Size = new Size(160, 28) };
            dtpReceivedDate.ValueChanged += (s, e) => { try { ShowDate(dtpReceivedDate); UpdatePostButtonEnabledState(); } catch { } };

            // Default new Purchase Orders to blank dates.
            BlankDate(dtpPODate);
            BlankDate(dtpReceivedDate);

            // Add Generate button for document-level generation actions
            btnGenerate = new Button { Text = "Generate", Size = new Size(100, 40) };
            btnGenerate.Click += BtnGenerate_Click;

            // Add Clear button to remove generated/remaining lines for the current document
            btnClear = new Button { Text = "Clear", Size = new Size(100, 40) };
            btnClear.Click += BtnClear_Click;

            // Add Print button to print the current purchase order
            btnPrint = new Button { Text = "Print", Size = new Size(100, 40) };
            btnPrint.Click += BtnPrint_Click;

            // Add POST button to post the current purchase order (inventory posting)
            btnPost = new Button { Text = "POST", Size = new Size(100, 40), BackColor = Color.SeaGreen, ForeColor = Color.White };
            btnPost.Click += BtnPost_Click;

            var actionPanel = new FlowLayoutPanel
            {
                Location = new Point(150, 160),
                Size = new Size(520, 52),
                FlowDirection = FlowDirection.LeftToRight,
                WrapContents = false,
                Padding = new Padding(0),
                Margin = new Padding(0),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right
            };
            actionPanel.Controls.AddRange(new Control[] { btnPost, btnPrint, btnGenerate, btnClear });

            this.Controls.AddRange(new Control[] { lblNo, txtNo, lblDesc, txtDescription, lblPODate, dtpPODate, lblReceived, dtpReceivedDate, actionPanel });

            // Embed the PurchaseOrderLinesForm below this document form so lines for the current document are visible
            try
            {
                var pf = new PurchaseOrderLinesForm();
                pf.TopLevel = false;
                pf.FormBorderStyle = FormBorderStyle.None;
                pf.Dock = DockStyle.Bottom;
                // Make the lines panel larger and adapt to form size so more lines are visible
                pf.Height = Math.Max(300, this.ClientSize.Height - 220);
                this.Controls.Add(pf);
                pf.Show();
                linesForm = pf;
                // Adjust the lines panel height when the form is resized (including maximize)
                this.Resize += (s, e) => { try { pf.Height = Math.Max(300, this.ClientSize.Height - 220); } catch { } };
            }
            catch { }

            UpdatePostButtonEnabledState();
        }

        private void LoadAllRecords()
        {
            rows.Clear();
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var cmd = new SqlCommand("SELECT [No.], [Description], [PO Date], [Received Date] FROM PurchaseHeader ORDER BY [No.]", conn))
                    using (var da = new SqlDataAdapter(cmd))
                    {
                        var dt = new DataTable();
                        da.Fill(dt);
                        foreach (DataRow r in dt.Rows) rows.Add(r);
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load PurchaseHeader records: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void ShowCurrentRecord()
        {
            if (currentIndex < 0 || currentIndex >= rows.Count)
            {
                ClearFields();
                return;
            }

            var r = rows[currentIndex];
            txtNo.Text = r.Table.Columns.Contains("No.") && r["No."] != DBNull.Value ? r["No."].ToString() ?? "" : "";
            txtDescription.Text = r.Table.Columns.Contains("Description") && r["Description"] != DBNull.Value ? r["Description"].ToString() ?? "" : "";
            if (r.Table.Columns.Contains("PO Date") && r["PO Date"] != DBNull.Value)
            {
                try { SetDate(dtpPODate, Convert.ToDateTime(r["PO Date"])); } catch { BlankDate(dtpPODate); }
            }
            else
            {
                BlankDate(dtpPODate);
            }

            if (r.Table.Columns.Contains("Received Date") && r["Received Date"] != DBNull.Value)
            {
                try { SetDate(dtpReceivedDate, Convert.ToDateTime(r["Received Date"])); } catch { BlankDate(dtpReceivedDate); }
            }
            else
            {
                BlankDate(dtpReceivedDate);
            }

            // Refresh lines panel for this document
            try { if (linesForm != null) linesForm.LoadForDocument(txtNo.Text); } catch { }

            UpdatePostButtonEnabledState();
        }

        private void ClearFields()
        {
            txtNo.Text = "";
            txtDescription.Text = "";
            BlankDate(dtpPODate);
            BlankDate(dtpReceivedDate);

            UpdatePostButtonEnabledState();
        }

        private void UpdatePostButtonEnabledState()
        {
            try
            {
                if (dtpReceivedDate == null) return;

                // If Received Date is filled, treat as already received/posted and block POST.
                bool receivedDateFilled = !IsBlankDate(dtpReceivedDate);
                if (btnPost != null) btnPost.Enabled = !receivedDateFilled;
                if (btnClear != null) btnClear.Enabled = !receivedDateFilled;
                if (btnGenerate != null) btnGenerate.Enabled = !receivedDateFilled;
            }
            catch { }
        }

        private void BtnNew_Click(object? sender, EventArgs e)
        {
            ClearFields();
            txtNo.Focus();
            currentIndex = -1;
        }

        private void BtnSave_Click(object? sender, EventArgs e)
        {
            string no = txtNo.Text.Trim();
            string desc = txtDescription.Text.Trim();
            DateTime? po = IsBlankDate(dtpPODate) ? (DateTime?)null : dtpPODate.Value;
            DateTime? recv = IsBlankDate(dtpReceivedDate) ? (DateTime?)null : dtpReceivedDate.Value;

            if (string.IsNullOrWhiteSpace(no)) { MessageBox.Show(this, "No. is required.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning); txtNo.Focus(); return; }

            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var check = new SqlCommand("SELECT COUNT(1) FROM PurchaseHeader WHERE [No.] = @No", conn))
                    {
                        check.Parameters.AddWithValue("@No", no);
                        var exists = Convert.ToInt32(check.ExecuteScalar() ?? 0) > 0;
                        if (exists)
                        {
                            using (var upd = new SqlCommand("UPDATE PurchaseHeader SET [Description] = @Desc, [PO Date] = @PODate, [Received Date] = @ReceivedDate WHERE [No.] = @No", conn))
                            {
                                upd.Parameters.AddWithValue("@Desc", desc);
                                upd.Parameters.AddWithValue("@PODate", (object?)po ?? DBNull.Value);
                                upd.Parameters.AddWithValue("@ReceivedDate", (object?)recv ?? DBNull.Value);
                                upd.Parameters.AddWithValue("@No", no);
                                upd.ExecuteNonQuery();
                            }
                        }
                        else
                        {
                            using (var ins = new SqlCommand("INSERT INTO PurchaseHeader ([No.], [Description], [PO Date], [Received Date]) VALUES (@No, @Desc, @PODate, @ReceivedDate)", conn))
                            {
                                ins.Parameters.AddWithValue("@No", no);
                                ins.Parameters.AddWithValue("@Desc", desc);
                                ins.Parameters.AddWithValue("@PODate", (object?)po ?? DBNull.Value);
                                ins.Parameters.AddWithValue("@ReceivedDate", (object?)recv ?? DBNull.Value);
                                ins.ExecuteNonQuery();
                            }
                        }
                    }
                }

                LoadAllRecords();
                // Set index to saved record
                currentIndex = rows.FindIndex(r => (r["No."]?.ToString() ?? "") == no);
                if (currentIndex < 0 && rows.Count > 0) currentIndex = 0;
                ShowCurrentRecord();
                MessageBox.Show(this, "Saved.", "Saved", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to save: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnDelete_Click(object? sender, EventArgs e)
        {
            string no = txtNo.Text.Trim();
            if (string.IsNullOrWhiteSpace(no)) { MessageBox.Show(this, "No. required to delete.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }

            // Do not allow delete if Received Date is already filled (treat as received/posted).
            if (!IsBlankDate(dtpReceivedDate))
            {
                MessageBox.Show(this, "Cannot delete because Document is already received (Received Date is already filled).", "Delete", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var dr = MessageBox.Show(this, $"Delete Purchase '{no}'?", "Confirm", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (dr != DialogResult.Yes) return;

            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var del = new SqlCommand("DELETE FROM PurchaseHeader WHERE [No.] = @No", conn))
                    {
                        del.Parameters.AddWithValue("@No", no);
                        del.ExecuteNonQuery();
                    }
                }

                LoadAllRecords();
                if (rows.Count > 0) currentIndex = Math.Min(currentIndex, rows.Count - 1); else currentIndex = -1;
                ShowCurrentRecord();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to delete: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnGenerate_Click(object? sender, EventArgs e)
        {
            string doc = txtNo.Text?.Trim() ?? "";
            if (string.IsNullOrWhiteSpace(doc))
            {
                MessageBox.Show(this, "Document No. is required to generate lines.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                txtNo.Focus();
                return;
            }

            // Do not allow Generate if Received Date is already filled (treat as received/posted).
            if (!IsBlankDate(dtpReceivedDate))
            {
                MessageBox.Show(this, "Cannot Generate because Received Date is already filled.", "Generate", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                UpdatePostButtonEnabledState();
                return;
            }

            // Load available categories
            var categories = new List<string>();
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var cmd = new SqlCommand("SELECT DISTINCT [CategoryCode] FROM dbo.Items WHERE [CategoryCode] IS NOT NULL AND [CategoryCode] <> '' ORDER BY [CategoryCode]", conn))
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read()) categories.Add(rdr[0]?.ToString() ?? "");
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to load categories: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (categories.Count == 0)
            {
                MessageBox.Show(this, "No categories found to select.", "Generate", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            // Show category selection dialog
            var dlg = new Form { Text = "Select Categories", Size = new Size(420, 420), StartPosition = FormStartPosition.CenterParent };
            var clb = new CheckedListBox { Dock = DockStyle.Top, Height = 300, CheckOnClick = true };
            clb.Items.AddRange(categories.ToArray());
            var btnPanel = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 56, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8) };
            var okBtn = new Button { Text = "OK", DialogResult = DialogResult.OK, Size = new Size(90, 34), Margin = new Padding(6) };
            var cancelBtn = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Size = new Size(90, 34), Margin = new Padding(6) };
            btnPanel.Controls.Add(okBtn);
            btnPanel.Controls.Add(cancelBtn);
            dlg.Controls.Add(clb);
            dlg.Controls.Add(btnPanel);
            dlg.AcceptButton = okBtn;
            dlg.CancelButton = cancelBtn;

            if (dlg.ShowDialog(this) != DialogResult.OK) return;

            var selectedCategories = clb.CheckedItems.Cast<string>().ToList();
            if (selectedCategories.Count == 0)
            {
                MessageBox.Show(this, "No categories selected.", "Generate", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            try
            {
                int inserted = 0;
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var tx = conn.BeginTransaction())
                    {
                        // Remove existing lines for this document
                        using (var del = new SqlCommand("DELETE FROM PurchaseLine WHERE [Document No.] = @Doc", conn, tx))
                        {
                            del.Parameters.AddWithValue("@Doc", doc);
                            del.ExecuteNonQuery();
                        }

                        // Read items matching selected categories into memory.
                        // Prefer cloud remain_quantity by VariationId for Available QTY, with local stock as fallback.
                        var items = new List<(string Code, string VariationId, decimal? Qty, string Description, string CategoryCode)>();
                        var inParams = string.Join(",", selectedCategories.Select((c, i) => "@c" + i));
                        var selSql = $"SELECT [Code], [VariationId], [QuantityInStock], [Description], [CategoryCode] FROM dbo.Items WHERE [CategoryCode] IN ({inParams}) ORDER BY [Code]";
                        using (var sel = new SqlCommand(selSql, conn, tx))
                        {
                            for (int i = 0; i < selectedCategories.Count; i++) sel.Parameters.AddWithValue("@c" + i, selectedCategories[i]);
                            using (var rdr = sel.ExecuteReader())
                            {
                                while (rdr.Read())
                                {
                                    var itemCode = rdr["Code"] != DBNull.Value ? rdr["Code"].ToString() ?? "" : "";
                                    var variationId = rdr["VariationId"] != DBNull.Value ? rdr["VariationId"].ToString() ?? "" : "";
                                    decimal? qty = null;
                                    try { if (rdr["QuantityInStock"] != DBNull.Value) qty = Convert.ToDecimal(rdr["QuantityInStock"]); } catch { qty = null; }
                                    var itemDesc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                                    var cat = rdr["CategoryCode"] != DBNull.Value ? rdr["CategoryCode"].ToString() ?? "" : "";
                                    items.Add((itemCode, variationId, qty, itemDesc, cat));
                                }
                            }
                        }

                        for (int i = 0; i < items.Count; i++)
                        {
                            var item = items[i];
                            if (string.IsNullOrWhiteSpace(item.VariationId))
                                continue;

                            decimal? cloudQty = null;
                            try
                            {
                                cloudQty = OnlinefunctionsEvents.GetCloudVariationAvailableQuantity(item.VariationId, TimeSpan.FromSeconds(10));
                            }
                            catch
                            {
                                cloudQty = null;
                            }

                            if (cloudQty.HasValue)
                                items[i] = (item.Code, item.VariationId, cloudQty.Value, item.Description, item.CategoryCode);
                        }

                        using (var ins = new SqlCommand("INSERT INTO PurchaseLine ([Document No.], [Item No.], [Line No.], [Available QTY], [Qty Needed], [Qty Received], [Description], [CategoryCode]) VALUES (@Doc, @Item, @Line, @Avail, @Needed, @Received, @Desc, @Category)", conn, tx))
                        {
                            ins.Parameters.Add(new SqlParameter("@Doc", SqlDbType.NVarChar, 100));
                            ins.Parameters.Add(new SqlParameter("@Item", SqlDbType.NVarChar, 100));
                            ins.Parameters.Add(new SqlParameter("@Line", SqlDbType.NVarChar, 50));
                            ins.Parameters.Add(new SqlParameter("@Avail", SqlDbType.Decimal));
                            ins.Parameters.Add(new SqlParameter("@Needed", SqlDbType.Decimal));
                            ins.Parameters.Add(new SqlParameter("@Received", SqlDbType.Decimal));
                            ins.Parameters.Add(new SqlParameter("@Desc", SqlDbType.NVarChar, 400));
                            ins.Parameters.Add(new SqlParameter("@Category", SqlDbType.NVarChar, 100));

                            int lineNo = 1;
                            foreach (var it in items)
                            {
                                ins.Parameters["@Doc"].Value = doc;
                                ins.Parameters["@Item"].Value = it.Code;
                                ins.Parameters["@Line"].Value = lineNo.ToString();
                                if (it.Qty.HasValue) ins.Parameters["@Avail"].Value = it.Qty.Value; else ins.Parameters["@Avail"].Value = DBNull.Value;
                                ins.Parameters["@Needed"].Value = DBNull.Value;
                                ins.Parameters["@Received"].Value = DBNull.Value;
                                ins.Parameters["@Desc"].Value = string.IsNullOrEmpty(it.Description) ? (object)DBNull.Value : it.Description;
                                ins.Parameters["@Category"].Value = string.IsNullOrEmpty(it.CategoryCode) ? (object)DBNull.Value : it.CategoryCode;

                                ins.ExecuteNonQuery();
                                inserted++;
                                lineNo++;
                            }
                        }

                        tx.Commit();
                    }
                }

                try { if (linesForm != null) linesForm.LoadForDocument(doc); } catch { }

                MessageBox.Show(this, $"Generated {inserted} lines for document '{doc}'.", "Generate", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to generate lines: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnClear_Click(object? sender, EventArgs e)
        {
            string doc = txtNo.Text?.Trim() ?? "";
            if (string.IsNullOrWhiteSpace(doc))
            {
                MessageBox.Show(this, "Document No. is required to clear lines.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                txtNo.Focus();
                return;
            }

            if (!IsBlankDate(dtpReceivedDate))
            {
                MessageBox.Show(this, "Cannot Clear because Received Date is already filled.", "Clear", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                UpdatePostButtonEnabledState();
                return;
            }

            var dr = MessageBox.Show(this, $"Delete all lines for document '{doc}'?", "Confirm Clear", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (dr != DialogResult.Yes) return;

            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var del = new SqlCommand("DELETE FROM PurchaseLine WHERE [Document No.] = @Doc", conn))
                    {
                        del.Parameters.AddWithValue("@Doc", doc);
                        del.ExecuteNonQuery();
                    }
                }

                try { if (linesForm != null) linesForm.LoadForDocument(doc); } catch { }
                MessageBox.Show(this, $"Cleared lines for document '{doc}'.", "Cleared", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to clear lines: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnPrint_Click(object? sender, EventArgs e)
        {
            string doc = txtNo.Text?.Trim() ?? "";
            if (string.IsNullOrWhiteSpace(doc))
            {
                MessageBox.Show(this, "Document No. is required to print.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                txtNo.Focus();
                return;
            }

            try
            {
                // Load header and lines from DB to ensure we print saved state
                string description = txtDescription.Text?.Trim() ?? "";
                DateTime poDate = dtpPODate.Value;
                DateTime receivedDate = dtpReceivedDate.Value;

                var lines = new List<(string ItemNo, string Description, decimal? QtyNeeded, decimal? QtyReceived)>();
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var cmd = new SqlCommand(@"SELECT [Item No.], [Description], [Qty Needed], [Qty Received]
FROM PurchaseLine
WHERE [Document No.] = @Doc
ORDER BY TRY_CONVERT(int, [Line No.]), [Line No.]", conn))
                    {
                        cmd.Parameters.AddWithValue("@Doc", doc);
                        using (var rdr = cmd.ExecuteReader())
                        {
                            while (rdr.Read())
                            {
                                string item = rdr["Item No."] != DBNull.Value ? rdr["Item No."].ToString() ?? "" : "";
                                string desc = rdr["Description"] != DBNull.Value ? rdr["Description"].ToString() ?? "" : "";
                                decimal? need = null;
                                decimal? recv = null;
                                try { if (rdr["Qty Needed"] != DBNull.Value) need = Convert.ToDecimal(rdr["Qty Needed"]); } catch { }
                                try { if (rdr["Qty Received"] != DBNull.Value) recv = Convert.ToDecimal(rdr["Qty Received"]); } catch { }
                                lines.Add((item, desc, need, recv));
                            }
                        }
                    }
                }

                if (lines.Count == 0)
                {
                    MessageBox.Show(this, $"No lines found to print for document '{doc}'.", "Print", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                PrintPOtoA4Document(doc, description, poDate, receivedDate, lines);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"Failed to print Purchase Order: {ex.Message}", "Print Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void BtnPost_Click(object? sender, EventArgs e)
        {
            string doc = txtNo.Text?.Trim() ?? "";
            if (string.IsNullOrWhiteSpace(doc))
            {
                MessageBox.Show(this, "Document No. is required to POST.", "Validation", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                txtNo.Focus();
                return;
            }

            if (!IsBlankDate(dtpReceivedDate))
            {
                MessageBox.Show(this, "Cannot POST because Received Date is already filled.", "POST", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                UpdatePostButtonEnabledState();
                return;
            }

            // First confirmation: irreversible action
            var confirm = MessageBox.Show(
                this,
                "Do you want to proceed?\n\nPosting entries cannot be reversed.",
                "Confirm POST",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;

            // Second confirmation if it looks already posted (avoid accidental double-posting)
            try
            {
                if (IsPurchaseOrderAlreadyPosted(doc))
                {
                    var confirm2 = MessageBox.Show(
                        this,
                        "This Purchase Order already has posted inventory entries.\nPosting again will DUPLICATE inventory quantities.\n\nContinue anyway?",
                        "Already Posted",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Warning);
                    if (confirm2 != DialogResult.Yes) return;
                }
            }
            catch { /* best-effort */ }

            try
            {
                int postedLines = PostPurchaseOrderToInventory(doc);
                if (postedLines <= 0)
                {
                    MessageBox.Show(this, "Nothing to post. Enter Qty Received on at least one line.", "POST", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                // After successful posting, send this specific purchase order to the online system
                // based on ItemLedgerEntry rows (SentToOnline = 0, DocumentType = 'PURCHASE', DocumentNo = doc).
                try
                {
                    var resp = OnlinefunctionsEvents.CreatePurchaseOnlineOrder(doc);
                    System.Diagnostics.Debug.WriteLine($"CreatePurchaseOnlineOrder for PO '{doc}' response: {resp}");
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"CreatePurchaseOnlineOrder failed for PO '{doc}': {ex.Message}");
                    // Do not rollback local posting if online call fails; just inform the user.
                    MessageBox.Show(this, "Purchase Order posted locally, but sending to online purchases failed: " + ex.Message, "Online Sync Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }

                try { if (linesForm != null) linesForm.LoadForDocument(doc); } catch { }

                // After successful posting we stamp Received Date; keep UI consistent and block further POST.
                try { SetDate(dtpReceivedDate, DateTime.Today); } catch { }
                UpdatePostButtonEnabledState();
                MessageBox.Show(this, $"POST completed. {postedLines} line(s) posted.", "POST", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"POST failed: {ex.Message}", "POST Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private bool IsPurchaseOrderAlreadyPosted(string documentNo)
        {
            try
            {
                using (var conn = new SqlConnection(connectionString))
                {
                    conn.Open();
                    using (var cmd = new SqlCommand(@"SELECT COUNT(1) FROM ItemLedgerEntry WHERE DocumentNo = @Doc AND DocumentType = 'PURCHASE'", conn))
                    {
                        cmd.Parameters.AddWithValue("@Doc", documentNo);
                        var count = Convert.ToInt32(cmd.ExecuteScalar() ?? 0);
                        return count > 0;
                    }
                }
            }
            catch
            {
                return false;
            }
        }

        private int PostPurchaseOrderToInventory(string documentNo)
        {
            // Uses PurchaseLine.[Qty Received] as the quantity to add to inventory.
            // Writes ItemLedgerEntry rows with DocumentType='PURCHASE' and DocumentNo=documentNo.

            var lines = new List<(string ItemNo, string Description, decimal QtyReceived)>();
            using (var conn = new SqlConnection(connectionString))
            {
                conn.Open();

                using (var cmd = new SqlCommand(@"
                SELECT [Item No.], [Description], [Qty Received]
                FROM PurchaseLine
                WHERE [Document No.] = @Doc
                AND [Qty Received] IS NOT NULL
                AND TRY_CONVERT(decimal(18,4), [Qty Received]) IS NOT NULL
                AND TRY_CONVERT(decimal(18,4), [Qty Received]) <> 0
                ORDER BY TRY_CONVERT(int, [Line No.]), [Line No.]", conn))
                {
                    cmd.Parameters.AddWithValue("@Doc", documentNo);
                    using (var rdr = cmd.ExecuteReader())
                    {
                        while (rdr.Read())
                        {
                            string item = rdr[0] != DBNull.Value ? rdr[0].ToString() ?? "" : "";
                            string desc = rdr[1] != DBNull.Value ? rdr[1].ToString() ?? "" : "";
                            decimal qty = 0m;
                            try { if (rdr[2] != DBNull.Value) qty = Convert.ToDecimal(rdr[2]); } catch { qty = 0m; }
                            if (string.IsNullOrWhiteSpace(item)) continue;
                            if (qty == 0m) continue;
                            lines.Add((item.Trim(), desc, qty));
                        }
                    }
                }

                if (lines.Count == 0) return 0;

                string userId = (CurrentUser.Username ?? "").Trim();
                if (string.IsNullOrWhiteSpace(userId))
                {
                    try { userId = Environment.UserName; } catch { userId = "SYSTEM"; }
                }

                using (var tx = conn.BeginTransaction())
                {
                    // Prevent accidental duplicates inside the same operation.
                    using (var already = new SqlCommand("SELECT COUNT(1) FROM ItemLedgerEntry WHERE DocumentNo = @Doc AND DocumentType = 'PURCHASE'", conn, tx))
                    {
                        already.Parameters.AddWithValue("@Doc", documentNo);
                        int count = Convert.ToInt32(already.ExecuteScalar() ?? 0);
                        if (count > 0)
                        {
                            throw new InvalidOperationException("This Purchase Order already has posted entries (DocumentType='PURCHASE').");
                        }
                    }

                    int posted = 0;
                    foreach (var line in lines)
                    {
                        if (line.QtyReceived < 0m)
                            throw new InvalidOperationException($"Qty Received cannot be negative for item '{line.ItemNo}'.");

                        // Lookup unit cost (best-effort)
                        decimal unitCost = 0m;
                        string variationId = string.Empty;
                        try
                        {
                            using (var costCmd = new SqlCommand("SELECT TOP 1 Cost FROM Items WHERE Code = @code", conn, tx))
                            {
                                costCmd.Parameters.AddWithValue("@code", line.ItemNo);
                                var oc = costCmd.ExecuteScalar();
                                if (oc != null && oc != DBNull.Value)
                                {
                                    try { unitCost = Convert.ToDecimal(oc); } catch { unitCost = 0m; }
                                }
                            }
                        }
                        catch { unitCost = 0m; }

                        // Lookup VariationId from Items (best-effort)
                        try
                        {
                            using (var varCmd = new SqlCommand("SELECT TOP 1 VariationId FROM Items WHERE Code = @code", conn, tx))
                            {
                                varCmd.Parameters.AddWithValue("@code", line.ItemNo);
                                var ov = varCmd.ExecuteScalar();
                                if (ov != null && ov != DBNull.Value)
                                {
                                    try { variationId = ov.ToString() ?? string.Empty; } catch { variationId = string.Empty; }
                                }
                            }
                        }
                        catch { variationId = string.Empty; }

                        // Insert ItemLedgerEntry
                        using (var ledgerCmd = new SqlCommand(@"
                        INSERT INTO ItemLedgerEntry (EntryDate, ItemCode, DocumentType, DocumentNo, Quantity, UnitCost, TotalCost, Description, UserID, VariationId)
                        VALUES (GETDATE(), @itemCode, @docType, @docNo, @quantity, @unitCost, @totalCost, @description, @userId, @variationId)", conn, tx))
                        {
                            ledgerCmd.Parameters.AddWithValue("@itemCode", line.ItemNo);
                            ledgerCmd.Parameters.AddWithValue("@docType", "PURCHASE");
                            ledgerCmd.Parameters.AddWithValue("@docNo", documentNo);
                            ledgerCmd.Parameters.AddWithValue("@quantity", line.QtyReceived);
                            ledgerCmd.Parameters.AddWithValue("@unitCost", unitCost);
                            ledgerCmd.Parameters.AddWithValue("@totalCost", unitCost * Math.Abs(line.QtyReceived));
                            ledgerCmd.Parameters.AddWithValue("@description", string.IsNullOrWhiteSpace(line.Description) ? $"Purchase Order {documentNo}" : line.Description);
                            ledgerCmd.Parameters.AddWithValue("@userId", string.IsNullOrWhiteSpace(userId) ? (object)DBNull.Value : userId);
                            ledgerCmd.Parameters.AddWithValue("@variationId", string.IsNullOrWhiteSpace(variationId) ? (object)DBNull.Value : variationId);
                            ledgerCmd.ExecuteNonQuery();
                        }

                        // Update inventory
                        using (var upd = new SqlCommand("UPDATE Items SET QuantityInStock = ISNULL(QuantityInStock, 0) + @qty WHERE Code = @code", conn, tx))
                        {
                            upd.Parameters.AddWithValue("@qty", line.QtyReceived);
                            upd.Parameters.AddWithValue("@code", line.ItemNo);
                            upd.ExecuteNonQuery();
                        }

                        posted++;
                    }

                    // Stamp Received Date if it's blank
                    try
                    {
                        using (var updHeader = new SqlCommand("UPDATE PurchaseHeader SET [Received Date] = COALESCE([Received Date], @today) WHERE [No.] = @No", conn, tx))
                        {
                            updHeader.Parameters.AddWithValue("@today", DateTime.Today);
                            updHeader.Parameters.AddWithValue("@No", documentNo);
                            updHeader.ExecuteNonQuery();
                        }
                    }
                    catch { }

                    tx.Commit();
                    return posted;
                }
            }
        }

        private static void BlankDate(DateTimePicker picker)
        {
            picker.Format = DateTimePickerFormat.Custom;
            picker.CustomFormat = " ";
        }

        private static void ShowDate(DateTimePicker picker)
        {
            if (!IsBlankDate(picker)) return;
            picker.Format = DateTimePickerFormat.Short;
            picker.CustomFormat = "";
        }

        private static void SetDate(DateTimePicker picker, DateTime value)
        {
            picker.Format = DateTimePickerFormat.Short;
            picker.CustomFormat = "";
            picker.Value = value;
        }

        private static bool IsBlankDate(DateTimePicker picker)
        {
            return picker.Format == DateTimePickerFormat.Custom && picker.CustomFormat == " ";
        }

        private void PrintPOtoA4Document(
            string doc,
            string description,
            DateTime poDate,
            DateTime receivedDate,
            List<(string ItemNo, string Description, decimal? QtyNeeded, decimal? QtyReceived)> lines)
        {
            if (string.IsNullOrWhiteSpace(doc))
                throw new ArgumentException("Document No. is required.", nameof(doc));
            if (lines == null || lines.Count == 0)
                throw new ArgumentException("At least one line is required.", nameof(lines));

            using var printDocument = new PrintDocument();
            printDocument.DocumentName = $"Purchase Order {doc}";

            // Keep print progress local to this print job.
            int rowIndex = 0;

            printDocument.BeginPrint += (s, e) => { rowIndex = 0; };
            printDocument.PrintPage += (s, e) =>
            {
                if (e.Graphics == null) return;

                using var titleFont = new Font("Arial", 18, FontStyle.Bold);
                using var headerFont = new Font("Arial", 12, FontStyle.Regular);
                using var tableHeaderFont = new Font("Arial", 11, FontStyle.Bold);
                using var bodyFont = new Font("Arial", 10, FontStyle.Regular);

                float left = e.MarginBounds.Left;
                float top = e.MarginBounds.Top;
                float right = e.MarginBounds.Right;
                float bottom = e.MarginBounds.Bottom;
                float width = e.MarginBounds.Width;

                float y = top;
                var black = Brushes.Black;

                // Title
                string title = "PURCHASE ORDER";
                var titleSize = e.Graphics.MeasureString(title, titleFont);
                e.Graphics.DrawString(title, titleFont, black, left + (width - titleSize.Width) / 2, y);
                y += titleSize.Height + 6;

                // Header block (2 columns)
                string user = CurrentUser.Username ?? "";
                float colGap = 24;
                float colWidth = Math.Max(100, (width - colGap) / 2);
                float leftColX = left;
                float rightColX = left + colWidth + colGap;

                float leftY = y;
                float rightY = y;

                // Left column: document + description
                e.Graphics.DrawString($"Document No.: {doc}", headerFont, black, leftColX, leftY);
                leftY += headerFont.GetHeight(e.Graphics) + 4;

                if (!string.IsNullOrWhiteSpace(description))
                {
                    string descText = $"Description: {description}";
                    float descHeight = e.Graphics.MeasureString(descText, headerFont, (int)colWidth).Height;
                    var descRect = new RectangleF(leftColX, leftY, colWidth, descHeight);
                    e.Graphics.DrawString(descText, headerFont, black, descRect);
                    leftY += descRect.Height + 4;
                }

                // Right column: dates + printed/user
                e.Graphics.DrawString($"PO Date: {poDate:yyyy-MM-dd}", headerFont, black, rightColX, rightY);
                rightY += headerFont.GetHeight(e.Graphics) + 4;
                e.Graphics.DrawString($"Received Date: {receivedDate:yyyy-MM-dd}", headerFont, black, rightColX, rightY);
                rightY += headerFont.GetHeight(e.Graphics) + 4;
                e.Graphics.DrawString($"Printed: {DateTime.Now:yyyy-MM-dd HH:mm}", headerFont, black, rightColX, rightY);
                rightY += headerFont.GetHeight(e.Graphics) + 4;
                e.Graphics.DrawString($"User: {user}", headerFont, black, rightColX, rightY);
                rightY += headerFont.GetHeight(e.Graphics) + 4;

                y = Math.Max(leftY, rightY) + 12;

                // Table layout (requested order: Item No, Description, Qty Need)
                float gap = 8;
                float itemCol = 240;
                float qtyNeedCol = 90;
                float descCol = Math.Max(160, width - itemCol - qtyNeedCol - gap * 2);

                float xItem = left;
                float xDesc = xItem + itemCol + gap;
                float xNeed = xDesc + descCol + gap;

                // Table header
                float lineY = y;
                e.Graphics.DrawLine(Pens.Black, left, lineY, right, lineY);
                y += 4;
                e.Graphics.DrawString("Item No.", tableHeaderFont, black, new RectangleF(xItem, y, itemCol, 100));
                e.Graphics.DrawString("Description", tableHeaderFont, black, new RectangleF(xDesc, y, descCol, 100));
                e.Graphics.DrawString("Qty Need", tableHeaderFont, black, new RectangleF(xNeed, y, qtyNeedCol, 100), RightAlign());
                y += tableHeaderFont.GetHeight(e.Graphics) + 6;
                e.Graphics.DrawLine(Pens.Black, left, y, right, y);
                y += 6;

                // Rows
                float rowPadding = 4;
                while (rowIndex < lines.Count)
                {
                    var l = lines[rowIndex];
                    string item = (l.ItemNo ?? string.Empty).Trim();
                    string needTxt = l.QtyNeeded.HasValue ? l.QtyNeeded.Value.ToString("0.##") : "";
                    string lineDesc = (l.Description ?? string.Empty).Trim();

                    float descHeight = string.IsNullOrWhiteSpace(lineDesc)
                        ? bodyFont.GetHeight(e.Graphics)
                        : e.Graphics.MeasureString(lineDesc, bodyFont, (int)descCol).Height;
                    float rowHeight = Math.Max(bodyFont.GetHeight(e.Graphics), descHeight) + rowPadding;

                    if (y + rowHeight > bottom)
                    {
                        e.HasMorePages = true;
                        return;
                    }

                    e.Graphics.DrawString(item, bodyFont, black, new RectangleF(xItem, y, itemCol, rowHeight), NoWrapEllipsis());
                    if (!string.IsNullOrWhiteSpace(lineDesc))
                    {
                        e.Graphics.DrawString(lineDesc, bodyFont, black, new RectangleF(xDesc, y, descCol, rowHeight));
                    }
                    e.Graphics.DrawString(needTxt, bodyFont, black, new RectangleF(xNeed, y, qtyNeedCol, rowHeight), RightAlign());

                    y += rowHeight;
                    rowIndex++;
                }

                e.HasMorePages = false;
            };

            // Configure paper and margins before preview so it matches what will print.
            ApplyA4PageSettings(printDocument);

            using (var preview = new PrintPreviewDialog
            {
                Document = printDocument,
                UseAntiAlias = true,
                WindowState = FormWindowState.Maximized
            })
            {
                preview.ShowDialog(this);
            }

            // Optional: print after preview.
            var printNow = MessageBox.Show(this, "Print this Purchase Order now?", "Print", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (printNow != DialogResult.Yes) return;

            using var dlg = new PrintDialog
            {
                Document = printDocument,
                UseEXDialog = true,
                AllowSomePages = false,
                AllowSelection = false
            };

            if (dlg.ShowDialog(this) != DialogResult.OK) return;
            printDocument.Print();
        }

        private static StringFormat RightAlign()
        {
            return new StringFormat { Alignment = StringAlignment.Far, LineAlignment = StringAlignment.Near, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap };
        }

        private static StringFormat NoWrapEllipsis()
        {
            return new StringFormat { Alignment = StringAlignment.Near, LineAlignment = StringAlignment.Near, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap };
        }

        private static void ApplyA4PageSettings(PrintDocument printDocument)
        {
            try
            {
                // Try to use printer's A4 paper size if supported.
                PaperSize? a4 = null;
                try
                {
                    foreach (PaperSize ps in printDocument.PrinterSettings.PaperSizes)
                    {
                        if (ps.Kind == PaperKind.A4 || (ps.PaperName ?? string.Empty).IndexOf("A4", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            a4 = ps;
                            break;
                        }
                    }
                }
                catch { }

                // Fallback A4 size in hundredths of an inch: 8.27 x 11.69 => 827 x 1169.
                printDocument.DefaultPageSettings.PaperSize = a4 ?? new PaperSize("A4", 827, 1169);
                printDocument.DefaultPageSettings.Landscape = false;

                // ~15mm margins.
                printDocument.DefaultPageSettings.Margins = new Margins(60, 60, 60, 60);
            }
            catch
            {
                // If the driver rejects settings, keep defaults.
            }
        }
    }
}
