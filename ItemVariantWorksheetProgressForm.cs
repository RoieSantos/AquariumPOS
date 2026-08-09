using System;
using System.Drawing;
using System.Windows.Forms;

namespace AquariumPOS
{
    /// <summary>
    /// Lightweight modeless progress dialog shown while the Item Variant Sales
    /// Worksheet is generated (syncing transfers, building report lines,
    /// fetching cloud quantities, and saving the worksheet). The exact
    /// duration cannot be predicted up front (it depends on network latency
    /// and how many variations must be queried), so this shows the current
    /// stage plus a running elapsed-time counter to keep the user informed
    /// while they wait.
    /// </summary>
    internal sealed class ItemVariantWorksheetProgressForm : Form
    {
        private readonly Label statusLabel;
        private readonly Label elapsedLabel;
        private readonly ProgressBar progressBar;
        private readonly System.Windows.Forms.Timer elapsedTimer;
        private readonly DateTime startedAtUtc;

        public ItemVariantWorksheetProgressForm(string initialStatus)
        {
            startedAtUtc = DateTime.UtcNow;

            Text = "Generating Item Variant Sales Worksheet";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MinimizeBox = false;
            MaximizeBox = false;
            ControlBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(420, 130);

            statusLabel = new Label
            {
                Text = initialStatus,
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                Location = new Point(20, 18),
                Size = new Size(380, 40),
                Font = new Font("Segoe UI", 10F)
            };

            progressBar = new ProgressBar
            {
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 30,
                Location = new Point(20, 65),
                Size = new Size(380, 20)
            };

            elapsedLabel = new Label
            {
                Text = "Elapsed: 0:00",
                AutoSize = false,
                TextAlign = ContentAlignment.MiddleLeft,
                Location = new Point(20, 95),
                Size = new Size(380, 20),
                ForeColor = Color.DimGray,
                Font = new Font("Segoe UI", 8.5F)
            };

            Controls.Add(statusLabel);
            Controls.Add(progressBar);
            Controls.Add(elapsedLabel);

            elapsedTimer = new System.Windows.Forms.Timer { Interval = 1000 };
            elapsedTimer.Tick += (s, e) => UpdateElapsedLabel();
            elapsedTimer.Start();
        }

        public void UpdateStatus(string text)
        {
            if (IsDisposed)
                return;

            if (InvokeRequired)
            {
                try { BeginInvoke(new Action(() => UpdateStatus(text))); } catch { }
                return;
            }

            statusLabel.Text = text;
        }

        private void UpdateElapsedLabel()
        {
            if (IsDisposed)
                return;

            var elapsed = DateTime.UtcNow - startedAtUtc;
            elapsedLabel.Text = $"Elapsed: {(int)elapsed.TotalMinutes}:{elapsed.Seconds:D2}";
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                elapsedTimer.Stop();
                elapsedTimer.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
