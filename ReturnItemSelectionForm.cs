using System;
using System.Collections.Generic;
using System.Data;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public class ReturnItemSelectionForm : Form
    {
        public class ReturnItem
        {
            public string ItemCode { get; set; } = string.Empty;
            public string Description { get; set; } = string.Empty;
            public int Quantity { get; set; }
            public int QuantityToReturn { get; set; }
            public decimal UnitPrice { get; set; }
            public decimal LineAmount { get; set; }
        }

        private DataGridView dgvItems;
        private Button btnOK;
        private Button btnCancel;
        public List<ReturnItem> SelectedItems { get; private set; } = new List<ReturnItem>();

        public ReturnItemSelectionForm(List<ReturnItem> items)
        {
            this.Text = "Select Items for Return";
            this.Size = new Size(700, 400);
            this.StartPosition = FormStartPosition.CenterParent;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.MinimizeBox = false;

            dgvItems = new DataGridView();
            dgvItems.Dock = DockStyle.Top;
            dgvItems.Height = 300;
            dgvItems.AutoGenerateColumns = false;
            dgvItems.AllowUserToAddRows = false;
            dgvItems.AllowUserToDeleteRows = false;
            dgvItems.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            dgvItems.MultiSelect = false;

            // Ensure checkbox edits commit immediately (otherwise clicking OK may not capture the last tick).
            dgvItems.CurrentCellDirtyStateChanged += (s, e) =>
            {
                if (dgvItems.IsCurrentCellDirty)
                {
                    dgvItems.CommitEdit(DataGridViewDataErrorContexts.Commit);
                }
            };

            var colSelect = new DataGridViewCheckBoxColumn { HeaderText = "Return", Width = 60 };
            dgvItems.Columns.Add(colSelect);
            dgvItems.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = "Item Code", DataPropertyName = "ItemCode", ReadOnly = true });
            dgvItems.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = "Description", DataPropertyName = "Description", ReadOnly = true, Width = 200 });
            dgvItems.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = "Sold Qty", DataPropertyName = "Quantity", ReadOnly = true });
            dgvItems.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = "Unit Price", DataPropertyName = "UnitPrice", ReadOnly = true });
            dgvItems.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = "Line Amount", DataPropertyName = "LineAmount", ReadOnly = true });
            dgvItems.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = "Return Qty", DataPropertyName = "QuantityToReturn" });

            dgvItems.CellValueChanged += (s, e) =>
            {
                if (e.ColumnIndex == 0 && e.RowIndex >= 0)
                {
                    var row = dgvItems.Rows[e.RowIndex];
                    bool selected = Convert.ToBoolean(row.Cells[0].Value ?? false);
                    int currentReturnQty = 0;
                    int.TryParse(row.Cells[6].Value?.ToString(), out currentReturnQty);

                    if (selected && currentReturnQty == 0)
                    {
                        row.Cells[6].Value = row.Cells[3].Value; // default to full qty
                    }
                }
            };

            dgvItems.DataError += (s, e) =>
            {
                // Prevent invalid numeric entry from throwing
                e.ThrowException = false;
            };

            var bindingList = new BindingSource();
            bindingList.DataSource = items;
            dgvItems.DataSource = bindingList;

            btnOK = new Button { Text = "OK", DialogResult = DialogResult.OK, Width = 100, Height = 40, Left = 400, Top = 320 };
            btnCancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = 100, Height = 40, Left = 520, Top = 320 };

            btnOK.Click += (s, e) =>
            {
                // Make sure the last checkbox/edited cell is committed before reading values.
                try
                {
                    dgvItems.EndEdit();
                    dgvItems.CommitEdit(DataGridViewDataErrorContexts.Commit);
                }
                catch { }

                SelectedItems.Clear();
                foreach (DataGridViewRow row in dgvItems.Rows)
                {
                    bool selected = Convert.ToBoolean(row.Cells[0].Value ?? false);
                    int qtyToReturn = 0;
                    int.TryParse(row.Cells[6].Value?.ToString(), out qtyToReturn);
                    if (selected && qtyToReturn > 0)
                    {
                        int soldQty = 0;
                        try { soldQty = Convert.ToInt32(row.Cells[3].Value ?? 0); } catch { soldQty = 0; }
                        soldQty = Math.Abs(soldQty);
                        if (soldQty > 0 && qtyToReturn > soldQty)
                        {
                            qtyToReturn = soldQty;
                        }

                        SelectedItems.Add(new ReturnItem
                        {
                            ItemCode = row.Cells[1].Value?.ToString() ?? string.Empty,
                            Description = row.Cells[2].Value?.ToString() ?? string.Empty,
                            Quantity = soldQty,
                            QuantityToReturn = qtyToReturn,
                            UnitPrice = Convert.ToDecimal(row.Cells[4].Value ?? 0),
                            LineAmount = Convert.ToDecimal(row.Cells[5].Value ?? 0)
                        });
                    }
                }
                this.DialogResult = DialogResult.OK;
                this.Close();
            };
            btnCancel.Click += (s, e) => { this.DialogResult = DialogResult.Cancel; this.Close(); };

            this.Controls.Add(dgvItems);
            this.Controls.Add(btnOK);
            this.Controls.Add(btnCancel);
        }
    }
}
