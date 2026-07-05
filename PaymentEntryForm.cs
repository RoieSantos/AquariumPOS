using System;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    public partial class PaymentEntryForm : Form
    {
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            // Prevent closing unless confirmed
            if (!IsConfirmed)
            {
                e.Cancel = true;
                MessageBox.Show("You must enter and confirm payment details before closing.", "Payment Required", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            base.OnFormClosing(e);
        }
        public string TenderType { get; private set; } = "";
        public decimal Amount { get; private set; } = 0;
        public bool IsConfirmed { get; private set; } = false;

        private TextBox txtTenderType = null!;
        private TextBox txtAmount = null!;
        private Button btnConfirm = null!;
        private Button btnCancel = null!;
        private Label lblTenderType = null!;
        private Label lblAmount = null!;
        private Label lblTitle = null!;

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            txtAmount.Focus();
        }

        public PaymentEntryForm(string defaultTenderType, decimal defaultAmount)
        {
            KeyPreview = true;
            this.KeyDown += PaymentEntryForm_KeyDown;

            InitializeComponent();
            txtTenderType.Text = defaultTenderType;
            txtAmount.Text = defaultAmount.ToString("F2");
            // Focus is now set in OnShown override
        }

        private void InitializeComponent()
        {
            this.Text = "Payment Entry";
            this.Size = new Size(400, 250);
            this.StartPosition = FormStartPosition.CenterParent;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.MinimizeBox = false;
            this.BackColor = Color.White;

            // Title Label
            lblTitle = new Label
            {
                Text = "Enter Payment Details",
                Font = new Font("Segoe UI", 14, FontStyle.Bold),
                ForeColor = Color.FromArgb(0, 122, 204),
                Location = new Point(20, 20),
                Size = new Size(350, 30),
                TextAlign = ContentAlignment.MiddleCenter
            };

            // Tender Type Label
            lblTenderType = new Label
            {
                Text = "Tender Type:",
                Font = new Font("Segoe UI", 10, FontStyle.Regular),
                Location = new Point(30, 70),
                Size = new Size(100, 25),
                TextAlign = ContentAlignment.MiddleLeft
            };

            // Tender Type TextBox
            txtTenderType = new TextBox
            {
                Font = new Font("Segoe UI", 12, FontStyle.Regular),
                Location = new Point(140, 68),
                Size = new Size(200, 30),
                ReadOnly = true,
                Enabled = false,
                TabIndex = 0
            };

            // Amount Label
            lblAmount = new Label
            {
                Text = "Amount:",
                Font = new Font("Segoe UI", 10, FontStyle.Regular),
                Location = new Point(30, 110),
                Size = new Size(100, 25),
                TextAlign = ContentAlignment.MiddleLeft
            };

            // Amount TextBox
            txtAmount = new TextBox
            {
                Font = new Font("Segoe UI", 12, FontStyle.Regular),
                Location = new Point(140, 108),
                Size = new Size(200, 30),
                TabIndex = 1
            };

            // Confirm Button
            btnConfirm = new Button
            {
                Text = "Confirm",
                Font = new Font("Segoe UI", 10, FontStyle.Bold),
                BackColor = Color.FromArgb(0, 122, 204),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat,
                Location = new Point(180, 160),
                Size = new Size(80, 35),
                TabIndex = 2
            };
            btnConfirm.FlatAppearance.BorderSize = 0;
            btnConfirm.Click += BtnConfirm_Click;

            // Cancel Button
            btnCancel = new Button
            {
                Text = "Cancel",
                Font = new Font("Segoe UI", 10, FontStyle.Regular),
                BackColor = Color.FromArgb(108, 117, 125),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat,
                Location = new Point(270, 160),
                Size = new Size(80, 35),
                TabIndex = 3
            };
            btnCancel.FlatAppearance.BorderSize = 0;
            btnCancel.Click += BtnCancel_Click;

            // Add controls to form
            this.Controls.Add(lblTitle);
            this.Controls.Add(lblTenderType);
            this.Controls.Add(txtTenderType);
            this.Controls.Add(lblAmount);
            this.Controls.Add(txtAmount);
            this.Controls.Add(btnConfirm);
            this.Controls.Add(btnCancel);

            // Set up key events
            this.KeyPreview = true;
            this.KeyDown += PaymentEntryForm_KeyDown;
            txtAmount.KeyPress += TxtAmount_KeyPress;
        }

        private void BtnConfirm_Click(object? sender, EventArgs e)
        {
            if (ValidateInput())
            {
                TenderType = txtTenderType.Text.Trim();
                Amount = decimal.Parse(txtAmount.Text);
                IsConfirmed = true;
                this.DialogResult = DialogResult.OK;
                this.Close();
            }
        }

        private void BtnCancel_Click(object? sender, EventArgs e)
        {
            IsConfirmed = false;
            this.DialogResult = DialogResult.Cancel;
            this.Close();
        }

        private void PaymentEntryForm_KeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter)
            {
                BtnConfirm_Click(sender, e);
            }
            else if (e.KeyCode == Keys.Escape)
            {
                BtnCancel_Click(sender, e);
            }
        }

        private void TxtAmount_KeyPress(object? sender, KeyPressEventArgs e)
        {
            // Only allow digits, decimal point, and control characters
            if (!char.IsDigit(e.KeyChar) && e.KeyChar != '.' && !char.IsControl(e.KeyChar))
            {
                e.Handled = true;
            }

            // Only allow one decimal point
            if (e.KeyChar == '.' && txtAmount.Text.Contains("."))
            {
                e.Handled = true;
            }
        }

        private bool ValidateInput()
        {
            if (string.IsNullOrWhiteSpace(txtTenderType.Text))
            {
                MessageBox.Show("Please enter a tender type.", "Validation Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                txtTenderType.Focus();
                return false;
            }

            if (string.IsNullOrWhiteSpace(txtAmount.Text))
            {
                MessageBox.Show("Please enter an amount.", "Validation Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                txtAmount.Focus();
                return false;
            }

            if (!decimal.TryParse(txtAmount.Text, out decimal amount) || amount <= 0)
            {
                MessageBox.Show("Please enter a valid amount greater than 0.", "Validation Error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                txtAmount.Focus();
                return false;
            }

            return true;
        }
    }
}
