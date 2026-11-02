using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;
using ZXing;
using ZXing.Common;

namespace AquariumPOS
{
    /// <summary>
    /// Xendit tender at checkout - per "my goal for now is to implement xendit on my local pos.. this is for my
    /// new transaction walkin orders". Shows a QR Ph code for the customer to scan in GCash, Maya or their bank
    /// app, and closes with OK only once Xendit itself says it's Paid (Edge Function xendit-pos-payment,
    /// sql/supabase_xendit_pos_walkin.sql). The sale is completed by the caller after that.
    /// </summary>
    public class XenditPayForm : ThemedForm
    {
        private const int PollMilliseconds = 3000;
        private const string WaitingText = "Ask the customer to scan this QR Ph code in GCash, Maya or their bank app.\nWaiting for payment...";

        private readonly decimal _amount;
        private readonly Label _statusLabel;
        private readonly Label _testLabel;
        private readonly PictureBox _qrBox;
        private readonly Button _simulateButton;
        private readonly Button _cancelButton;
        private readonly System.Windows.Forms.Timer _pollTimer;
        private bool _polling;
        private bool _cancelling;
        private bool _finished;

        public string PaymentId { get; private set; } = string.Empty;
        public string Channel { get; private set; } = string.Empty;

        public XenditPayForm(decimal amount)
        {
            _amount = amount;
            Text = "Xendit Payment";
            StartPosition = FormStartPosition.CenterParent;
            ClientSize = new Size(440, 590);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            Font = new Font("Arial", 11);

            var amountLabel = new Label
            {
                Location = new Point(16, 12),
                Size = new Size(408, 40),
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font("Arial", 20, FontStyle.Bold),
                Text = $"P{amount:N2}"
            };
            _testLabel = new Label
            {
                Location = new Point(16, 54),
                Size = new Size(408, 24),
                TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font("Arial", 10, FontStyle.Bold),
                ForeColor = Color.Firebrick,
                Text = "TEST MODE - no real money",
                Visible = false
            };
            _qrBox = new PictureBox
            {
                Location = new Point(60, 84),
                Size = new Size(320, 320),
                BackColor = Color.White,
                SizeMode = PictureBoxSizeMode.CenterImage
            };
            _statusLabel = new Label
            {
                Location = new Point(16, 412),
                Size = new Size(408, 96),
                TextAlign = ContentAlignment.MiddleCenter,
                Text = "Creating the payment..."
            };
            // Test mode only: a real GCash / bank app can't pay a test QR.
            _simulateButton = new Button { Text = "Simulate Paid (TEST)", Location = new Point(16, 524), Size = new Size(200, 48), Visible = false };
            _simulateButton.Click += async (s, e) => await SimulateAsync();
            _cancelButton = new Button { Text = "Cancel Payment", Location = new Point(264, 524), Size = new Size(160, 48) };
            _cancelButton.Click += async (s, e) => await CancelAsync();
            Controls.AddRange(new Control[] { amountLabel, _testLabel, _qrBox, _statusLabel, _simulateButton, _cancelButton });

            _pollTimer = new System.Windows.Forms.Timer { Interval = PollMilliseconds };
            _pollTimer.Tick += async (s, e) => await PollAsync();
        }

        protected override async void OnShown(EventArgs e)
        {
            base.OnShown(e);
            await CreateInvoiceAsync();
        }

        // Closing with the X is the same as Cancel Payment - an open QR must never be left behind unnoticed.
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!_finished && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                _ = CancelAsync();
                return;
            }
            _pollTimer.Stop();
            base.OnFormClosing(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _pollTimer.Dispose();
                _qrBox.Image?.Dispose();
            }
            base.Dispose(disposing);
        }

        private async Task CreateInvoiceAsync()
        {
            try
            {
                string warehouseId = string.Empty;
                try { warehouseId = await Task.Run(OnlinefunctionsEvents.GetCurrentWarehouseIdForPosAsync); } catch { }

                using var doc = await CallAsync(new
                {
                    action = "create",
                    posKey = GlobalSettings.PosApiKey,
                    amount = _amount,
                    warehouseId,
                    cashier = CurrentUser.GetEffectiveUsername("POS_SYSTEM"),
                    terminal = Environment.MachineName
                }, TimeSpan.FromSeconds(30));
                var root = doc.RootElement;
                PaymentId = GetString(root, "paymentId");
                bool isTest = root.TryGetProperty("isTest", out var test) && test.ValueKind == JsonValueKind.True;
                _testLabel.Visible = isTest;
                _simulateButton.Visible = isTest;
                _qrBox.Image = CreateQrBitmap(GetString(root, "qrString"), _qrBox.Width);
                _statusLabel.Text = WaitingText;
                _pollTimer.Start();
            }
            catch (Exception ex)
            {
                _finished = true;
                MessageBox.Show(this, "The Xendit payment could not be started:\n\n" + Describe(ex) + "\n\nNo money was taken. Pick another tender or try again.", "Xendit Payment", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                DialogResult = DialogResult.Cancel;
                Close();
            }
        }

        private async Task PollAsync()
        {
            if (_polling || _cancelling || _finished) return;
            _polling = true;
            try
            {
                using var doc = await CallAsync(new { action = "status", posKey = GlobalSettings.PosApiKey, paymentId = PaymentId }, TimeSpan.FromSeconds(15));
                if (_cancelling || _finished) return;
                HandleStatus(doc.RootElement);
                if (!_finished) _statusLabel.Text = WaitingText;
            }
            catch (Exception ex)
            {
                // A dropped connection doesn't lose the payment - keep asking until it comes back.
                _statusLabel.Text = "Can't reach Xendit right now - still trying...\n" + Describe(ex);
            }
            finally
            {
                _polling = false;
            }
        }

        // The result comes back through the normal polling.
        private async Task SimulateAsync()
        {
            _simulateButton.Enabled = false;
            try
            {
                using var doc = await CallAsync(new { action = "simulate", posKey = GlobalSettings.PosApiKey, paymentId = PaymentId }, TimeSpan.FromSeconds(20));
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Simulate failed:\n\n" + Describe(ex), "Xendit Payment", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                _simulateButton.Enabled = true;
            }
        }

        private async Task CancelAsync()
        {
            if (_cancelling || _finished) return;
            if (string.IsNullOrEmpty(PaymentId))
            {
                // Still being created: leave it to CreateInvoiceAsync, so a new invoice isn't left open behind this.
                return;
            }

            _cancelling = true;
            _pollTimer.Stop();
            _cancelButton.Enabled = false;
            _statusLabel.Text = "Cancelling the payment...";
            while (true)
            {
                try
                {
                    using var doc = await CallAsync(new { action = "cancel", posKey = GlobalSettings.PosApiKey, paymentId = PaymentId }, TimeSpan.FromSeconds(20));
                    HandleStatus(doc.RootElement);
                    if (_finished) return;
                    // Still open at Xendit, which shouldn't happen after an expire - treat as not cancelled.
                    throw new InvalidOperationException("Xendit says the payment is still open.");
                }
                catch (Exception ex)
                {
                    var choice = MessageBox.Show(this,
                        "The payment could NOT be cancelled:\n\n" + Describe(ex) + "\n\n"
                        + "Retry tries again.\n"
                        + "Cancel closes this window, but the customer could still pay this QR. "
                        + "Check Xendit Payments on the portal before taking another payment.",
                        "Xendit Payment", MessageBoxButtons.RetryCancel, MessageBoxIcon.Warning);
                    if (choice == DialogResult.Retry) continue;
                    _finished = true;
                    DialogResult = DialogResult.Cancel;
                    Close();
                    return;
                }
            }
        }

        private void HandleStatus(JsonElement root)
        {
            string status = GetString(root, "status");
            if (string.Equals(status, "Paid", StringComparison.OrdinalIgnoreCase))
            {
                Channel = GetString(root, "channel");
                _finished = true;
                _pollTimer.Stop();
                DialogResult = DialogResult.OK;
                Close();
            }
            else if (string.Equals(status, "Expired", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase))
            {
                bool wasCancelling = _cancelling;
                _finished = true;
                _pollTimer.Stop();
                if (!wasCancelling)
                    MessageBox.Show(this, "This QR has expired and no money was taken. Start the payment again.", "Xendit Payment", MessageBoxButtons.OK, MessageBoxIcon.Information);
                DialogResult = DialogResult.Cancel;
                Close();
            }
        }

        // Saves the sale's receipt no. on the payment. Best-effort: the money is safe either way, and a
        // payment left without one shows up on the Xendit Payments page.
        public static async Task LinkToReceiptAsync(string paymentId, string receiptNo)
        {
            try
            {
                using var doc = await CallAsync(new { action = "link", posKey = GlobalSettings.PosApiKey, paymentId, receiptNo }, TimeSpan.FromSeconds(30));
            }
            catch { }
        }

        // Any answer from the function, even "method not allowed" to this GET, means the POS is online. Waits
        // at most 5 seconds. Runs off the UI thread, so the caller can block on it.
        public static bool CanReachXenditFunction()
        {
            try
            {
                return Task.Run(async () =>
                {
                    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
                    using var resp = await http.GetAsync(GlobalSettings.XenditPosPaymentEndpoint).ConfigureAwait(false);
                    return true;
                }).GetAwaiter().GetResult();
            }
            catch
            {
                return false;
            }
        }

        private static string Describe(Exception ex) => ex switch
        {
            HttpRequestException => "No internet connection.",
            TaskCanceledException => "Xendit didn't answer in time.",
            _ => ex.Message
        };

        private static async Task<JsonDocument> CallAsync(object payload, TimeSpan timeout)
        {
            using var http = new HttpClient { Timeout = timeout };
            using var req = new HttpRequestMessage(HttpMethod.Post, GlobalSettings.XenditPosPaymentEndpoint);
            req.Headers.TryAddWithoutValidation("apikey", GlobalSettings.TransferHeaderSupabaseApiKey);
            req.Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            using var resp = await http.SendAsync(req).ConfigureAwait(true);
            string text = await resp.Content.ReadAsStringAsync().ConfigureAwait(true);
            if (!resp.IsSuccessStatusCode)
            {
                string message = text;
                try
                {
                    using var err = JsonDocument.Parse(text);
                    if (err.RootElement.ValueKind == JsonValueKind.Object && err.RootElement.TryGetProperty("error", out var e))
                        message = e.GetString() ?? text;
                }
                catch { }
                throw new InvalidOperationException(message);
            }
            return JsonDocument.Parse(text);
        }

        private static string GetString(JsonElement root, string name)
            => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? string.Empty : string.Empty;

        private static Bitmap CreateQrBitmap(string value, int size)
        {
            var writer = new BarcodeWriterPixelData
            {
                Format = BarcodeFormat.QR_CODE,
                Options = new EncodingOptions { Width = size, Height = size, Margin = 2 }
            };
            var pixelData = writer.Write(value);
            var bitmap = new Bitmap(pixelData.Width, pixelData.Height, PixelFormat.Format32bppRgb);
            var bitmapData = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
            try
            {
                Marshal.Copy(pixelData.Pixels, 0, bitmapData.Scan0, pixelData.Pixels.Length);
            }
            finally
            {
                bitmap.UnlockBits(bitmapData);
            }
            return bitmap;
        }
    }
}
