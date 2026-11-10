using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Data.SqlClient;

namespace AquariumPOS
{
    /// <summary>
    /// Online Pay - per "give me a Online Pay then ask for the order id that they are paying .. once they
    /// input the orderid it will lookup the portal's online order id then show the details that they are
    /// paying.. once confirmed they can now pay it base on the tender type".
    ///
    /// The order is read live from the portal (pos_get_online_order_for_payment) - nothing about it is
    /// stored locally. The payment goes to the portal / Pancake first (pos_record_online_order_payment);
    /// only once that succeeds is the local till entry written (TransactionHeader + TransPaymentEntry, same
    /// rows the old Online Orders PAY wrote, so the cash drawer / EOD still balance) and the receipt printed.
    /// No internet = no payment. See sql/supabase_pos_online_pay.sql.
    ///
    /// Card tenders add the same CardMarkupPercent fee as checkout, on top of the amount: only the amount
    /// comes off the order's balance, the fee goes to the portal as card_fee, and the till records both.
    /// </summary>
    public class OnlinePayForm : ThemedForm
    {
        private sealed class OrderLine
        {
            public string Description = string.Empty;
            public decimal Qty;
            public decimal Price;
            public decimal Amount;
        }

        private sealed class OnlineOrderInfo
        {
            public string OrderId = string.Empty;
            public string CustomerName = string.Empty;
            public string Phone = string.Empty;
            public string Status = string.Empty;
            public string Warehouse = string.Empty;
            public decimal Total;
            public decimal Discount;
            public decimal DeliveryFee;
            public decimal AmountPaid;
            public decimal Balance;
            public bool PortalOnly;
            public bool Fresh;
            public bool CanPay;
            public string BlockReason = string.Empty;
            public string UnfinishedPayment = string.Empty;
            public List<OrderLine> Lines = new();
        }

        private sealed class TenderType
        {
            public string Code = string.Empty;
            public string Description = string.Empty;
            public string BankId = string.Empty;
            public decimal FeePercent;
            public override string ToString() => Description;
        }

        // Amount = what comes off the order's balance; Charged = what the customer pays (Amount + Fee).
        // XenditPaymentId: set when this part was already paid by the Xendit QR (money taken before recording).
        private sealed record TenderPick(TenderType Tender, decimal Amount, decimal Fee, string? XenditPaymentId = null)
        {
            public decimal Charged => Amount + Fee;
            public bool PaidByQr => !string.IsNullOrEmpty(XenditPaymentId);
        }

        private static string QrPaidText(IEnumerable<TenderPick> picks)
            => picks.Where(p => p.PaidByQr).Sum(p => p.Amount).ToString("N2");

        private sealed class PaymentResult
        {
            public bool Ok;
            public string Error = string.Empty;
            public decimal Amount;
            public decimal AmountPaidBefore;
            public decimal AmountPaidAfter;
            public decimal BalanceAfter;
            public bool PortalUpdated;
        }

        private const string NoInternetMessage = "No internet connection - Online Pay needs the internet to look up and record the payment.\n\nNo payment was taken.";

        private readonly MainForm? _mainForm;
        private readonly TextBox _orderIdBox;
        private readonly Button _findButton;
        private readonly Label _infoLabel;
        private readonly ListView _linesList;
        private readonly Label _totalsLabel;
        private readonly Label _balanceLabel;
        private readonly Label _warningLabel;
        private readonly Button _payButton;
        private OnlineOrderInfo? _order;

        public OnlinePayForm(MainForm? mainForm)
        {
            _mainForm = mainForm;

            Text = "Online Pay";
            StartPosition = FormStartPosition.CenterParent;
            ClientSize = new Size(720, 600);
            MinimumSize = new Size(640, 520);
            Font = new Font("Arial", 10);
            KeyPreview = true;

            var orderLabel = new Label { Text = "Order ID:", Location = new Point(16, 20), AutoSize = true, Font = new Font("Arial", 12, FontStyle.Bold) };
            _orderIdBox = new TextBox { Location = new Point(120, 16), Width = 260, Font = new Font("Arial", 14) };
            _findButton = new Button { Text = "Find", Location = new Point(392, 14), Size = new Size(110, 36), BackColor = Color.SteelBlue, ForeColor = Color.White, Font = new Font("Arial", 10, FontStyle.Bold) };
            _findButton.Click += async (s, e) => await FindOrderAsync();
            _orderIdBox.KeyDown += async (s, e) =>
            {
                if (e.KeyCode != Keys.Enter) return;
                e.SuppressKeyPress = true;
                await FindOrderAsync();
            };

            _infoLabel = new Label { Location = new Point(16, 64), Size = new Size(688, 66), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right, Text = "Type the Order ID the customer is paying for, then press Enter." };

            _linesList = new ListView
            {
                Location = new Point(16, 134),
                Size = new Size(688, 250),
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                View = View.Details,
                FullRowSelect = true,
                GridLines = true
            };
            _linesList.Columns.Add("Item", 380);
            _linesList.Columns.Add("Qty", 70, HorizontalAlignment.Right);
            _linesList.Columns.Add("Price", 100, HorizontalAlignment.Right);
            _linesList.Columns.Add("Amount", 110, HorizontalAlignment.Right);

            _totalsLabel = new Label { Location = new Point(16, 392), Size = new Size(688, 48), Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right };
            _balanceLabel = new Label { Location = new Point(16, 440), Size = new Size(688, 32), Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right, Font = new Font("Arial", 16, FontStyle.Bold) };
            _warningLabel = new Label { Location = new Point(16, 474), Size = new Size(688, 54), Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right, ForeColor = Color.Firebrick };

            _payButton = new Button { Text = "PAY", Location = new Point(468, 540), Size = new Size(120, 44), Anchor = AnchorStyles.Bottom | AnchorStyles.Right, BackColor = Color.MediumSeaGreen, ForeColor = Color.White, Font = new Font("Arial", 12, FontStyle.Bold), Enabled = false };
            _payButton.Click += async (s, e) => await PayAsync();
            var closeButton = new Button { Text = "Close", Location = new Point(596, 540), Size = new Size(108, 44), Anchor = AnchorStyles.Bottom | AnchorStyles.Right, DialogResult = DialogResult.Cancel };

            Controls.AddRange(new Control[] { orderLabel, _orderIdBox, _findButton, _infoLabel, _linesList, _totalsLabel, _balanceLabel, _warningLabel, _payButton, closeButton });
            CancelButton = closeButton;
            Shown += (s, e) => _orderIdBox.Focus();
        }

        // ------------------------------------------------------------------ Lookup

        private async Task FindOrderAsync()
        {
            string orderId = _orderIdBox.Text.Trim();
            if (orderId.Length == 0) return;

            ShowOrder(null);
            SetBusy(true, "Looking up order " + orderId + " on the portal...");
            try
            {
                using var doc = await CallRpcAsync(GlobalSettings.OnlinePayLookupRpcEndpoint, new { p_pos_key = GlobalSettings.PosApiKey, p_order_id = orderId }, TimeSpan.FromSeconds(45));
                var root = doc.RootElement;
                if (!GetBool(root, "found"))
                {
                    _infoLabel.Text = $"Order {orderId} was not found on the portal. Check the number - a brand-new order can take a minute to appear.";
                    return;
                }
                ShowOrder(ParseOrder(root));
            }
            catch (HttpRequestException) { _infoLabel.Text = string.Empty; MessageBox.Show(this, NoInternetMessage, "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
            catch (TaskCanceledException) { _infoLabel.Text = string.Empty; MessageBox.Show(this, NoInternetMessage, "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
            catch (Exception ex) { _infoLabel.Text = string.Empty; MessageBox.Show(this, "Could not look up the order: " + ex.Message, "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            finally { SetBusy(false, null); }
        }

        private static OnlineOrderInfo ParseOrder(JsonElement root)
        {
            var o = new OnlineOrderInfo
            {
                OrderId = GetString(root, "order_id"),
                CustomerName = GetString(root, "customer_name"),
                Phone = GetString(root, "phone"),
                Status = GetString(root, "status"),
                Warehouse = GetString(root, "warehouse"),
                Total = GetDecimal(root, "total"),
                Discount = GetDecimal(root, "discount"),
                DeliveryFee = GetDecimal(root, "delivery_fee"),
                AmountPaid = GetDecimal(root, "amount_paid"),
                Balance = GetDecimal(root, "balance"),
                PortalOnly = GetBool(root, "portal_only"),
                Fresh = GetBool(root, "fresh"),
                CanPay = GetBool(root, "can_pay"),
                BlockReason = GetString(root, "block_reason"),
                UnfinishedPayment = GetString(root, "unfinished_payment")
            };
            if (root.TryGetProperty("lines", out var lines) && lines.ValueKind == JsonValueKind.Array)
            {
                foreach (var l in lines.EnumerateArray())
                {
                    o.Lines.Add(new OrderLine
                    {
                        Description = GetString(l, "description"),
                        Qty = GetDecimal(l, "qty"),
                        Price = GetDecimal(l, "price"),
                        Amount = GetDecimal(l, "amount")
                    });
                }
            }
            return o;
        }

        private void ShowOrder(OnlineOrderInfo? o)
        {
            _order = o;
            _linesList.Items.Clear();
            _totalsLabel.Text = string.Empty;
            _balanceLabel.Text = string.Empty;
            _warningLabel.Text = string.Empty;
            _payButton.Enabled = false;
            if (o == null) return;

            _infoLabel.Text = $"Order {o.OrderId}   ·   {o.Status}   ·   {(string.IsNullOrWhiteSpace(o.Warehouse) ? "no branch" : o.Warehouse)}\n"
                + $"Customer: {o.CustomerName}{(string.IsNullOrWhiteSpace(o.Phone) ? string.Empty : "   ·   " + o.Phone)}";

            foreach (var l in o.Lines)
            {
                var item = new ListViewItem(l.Description);
                item.SubItems.Add(FormatQty(l.Qty));
                item.SubItems.Add(l.Price.ToString("N2", CultureInfo.InvariantCulture));
                item.SubItems.Add(l.Amount.ToString("N2", CultureInfo.InvariantCulture));
                _linesList.Items.Add(item);
            }

            var totals = new StringBuilder();
            if (o.DeliveryFee > 0) totals.Append($"Delivery Fee: {o.DeliveryFee:N2}     ");
            if (o.Discount > 0) totals.Append($"Discount: {o.Discount:N2}     ");
            totals.Append($"Order Total: {o.Total:N2}\nAmount Paid: {o.AmountPaid:N2}");
            _totalsLabel.Text = totals.ToString();
            _balanceLabel.Text = $"BALANCE: {o.Balance:N2}";

            var warnings = new List<string>();
            if (!o.CanPay) warnings.Add(string.IsNullOrWhiteSpace(o.BlockReason) ? "This order can't be paid." : o.BlockReason);
            if (!string.IsNullOrWhiteSpace(o.UnfinishedPayment)) warnings.Add(o.UnfinishedPayment);
            if (!o.Fresh) warnings.Add("Couldn't re-check this order with Pancake just now - the balance shown may be out of date. It is checked again when you pay.");
            _warningLabel.Text = string.Join("\n", warnings);
            _payButton.Enabled = o.CanPay && o.Balance > 0;
            if (_payButton.Enabled) _payButton.Focus();
        }

        // ------------------------------------------------------------------ Pay

        private async Task PayAsync()
        {
            var order = _order;
            if (order == null || !order.CanPay || order.Balance <= 0) return;

            var tenders = LoadTenderTypes();
            if (_mainForm != null)
            {
                foreach (var t in tenders) t.FeePercent = _mainForm.GetCardFeePercentForTender(t.Code, t.Description);
            }
            var picks = PickTenders(order, tenders);
            if (picks == null || picks.Count == 0) return;
            decimal total = picks.Sum(p => p.Amount);
            decimal totalFee = picks.Sum(p => p.Fee);

            var confirm = new StringBuilder();
            confirm.AppendLine($"Receive payment for order {order.OrderId} ({order.CustomerName})?");
            confirm.AppendLine();
            foreach (var p in picks)
            {
                confirm.AppendLine($"   {p.Tender.Description}: {p.Amount:N2}");
                if (p.Fee > 0m) confirm.AppendLine($"      + {p.Tender.FeePercent:0.##}% card fee: {p.Fee:N2}  =  charge {p.Charged:N2}");
            }
            confirm.AppendLine($"   Total: {total:N2}");
            if (totalFee > 0m) confirm.AppendLine($"   Total to charge the customer: {total + totalFee:N2}");
            confirm.AppendLine();
            confirm.AppendLine($"Balance after this payment: {Math.Max(0m, order.Balance - total):N2}");
            bool anyQr = picks.Any(p => p.PaidByQr);
            if (anyQr)
            {
                // Already paid by QR - no "No" here, it has to be recorded.
                confirm.AppendLine();
                confirm.AppendLine($"P{QrPaidText(picks)} is already PAID by Xendit QR - recording it now.");
                MessageBox.Show(this, confirm.ToString(), "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            else if (MessageBox.Show(this, confirm.ToString(), "Online Pay", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;

            // Same ID on every retry, so the server never records it twice.
            Guid paymentId = Guid.NewGuid();
            string receiptNo = "ONL-" + order.OrderId;
            var tenderPayload = picks.Select(p => new
            {
                tender_code = p.Tender.Code,
                tender_name = p.Tender.Description,
                bank_key = string.IsNullOrWhiteSpace(p.Tender.BankId) ? null : p.Tender.BankId.Trim(),
                amount = p.Amount,
                card_fee = p.Fee
            }).ToArray();

            PaymentResult? result = null;
            while (result == null)
            {
                SetBusy(true, "Recording the payment on the portal...");
                string? failure = null;
                try
                {
                    using var doc = await CallRpcAsync(GlobalSettings.OnlinePayRecordRpcEndpoint, new
                    {
                        p_pos_key = GlobalSettings.PosApiKey,
                        p_payment_id = paymentId,
                        p_order_id = order.OrderId,
                        p_tenders = tenderPayload,
                        p_cashier = CurrentUser.GetEffectiveUsername("POS_SYSTEM"),
                        p_terminal = Environment.MachineName,
                        p_receipt_no = receiptNo
                    }, TimeSpan.FromSeconds(100));
                    var root = doc.RootElement;
                    if (GetBool(root, "ok"))
                    {
                        result = new PaymentResult
                        {
                            Ok = true,
                            Amount = GetDecimal(root, "amount"),
                            AmountPaidBefore = GetDecimal(root, "amount_paid_before"),
                            AmountPaidAfter = GetDecimal(root, "amount_paid_after"),
                            BalanceAfter = GetDecimal(root, "balance_after"),
                            PortalUpdated = GetBool(root, "portal_updated")
                        };
                    }
                    else
                    {
                        failure = GetString(root, "error");
                    }
                }
                catch (HttpRequestException ex) { failure = "No internet connection (" + ex.Message + ")."; }
                catch (TaskCanceledException) { failure = "The portal didn't answer in time (no internet or a slow connection)."; }
                catch (Exception ex)
                {
                    // A refusal (Cancelled, more than the balance, no POS Bank ID...) - nothing was recorded.
                    SetBusy(false, null);
                    MessageBox.Show(this, anyQr
                            ? $"The portal refused the payment:\n\n{ex.Message}\n\nBUT the customer already PAID P{QrPaidText(picks)} by Xendit QR - do NOT ask them to pay that again. "
                              + $"Tell a Super User: it's on the Xendit Payments page (receipt ONL-{order.OrderId}), and they add it on the order by hand."
                            : "The payment was NOT recorded:\n\n" + ex.Message + "\n\nDon't take the money for this payment.",
                        "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    LinkQrPayments(picks, receiptNo);
                    return;
                }
                finally { SetBusy(false, null); }

                if (result != null) break;
                var choice = MessageBox.Show(this,
                    "The payment was NOT confirmed:\n\n" + (failure ?? "Unknown error.") + "\n\n"
                    + (anyQr ? $"The customer already PAID P{QrPaidText(picks)} by Xendit QR - keep pressing Retry until it's recorded; never ask them to pay again.\n" : string.Empty)
                    + "Retry sends the same payment again - it can never be counted twice.\n"
                    + "If you Cancel, check the order on the portal before taking payment again.",
                    "Online Pay", MessageBoxButtons.RetryCancel, MessageBoxIcon.Warning);
                if (choice != DialogResult.Retry)
                {
                    LinkQrPayments(picks, receiptNo);
                    return;
                }
            }

            LinkQrPayments(picks, receiptNo);

            // Recorded online - now the till entry and the receipt.
            try
            {
                SaveLocalPayment(receiptNo, order.OrderId, picks);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this,
                    $"The payment IS recorded on the portal, but the POS couldn't save it locally:\n\n{ex.Message}\n\n"
                    + $"Write it down for the end-of-day: order {order.OrderId}, {string.Join(", ", picks.Select(p => p.Tender.Description + " " + p.Charged.ToString("N2") + (p.Fee > 0m ? " (card fee " + p.Fee.ToString("N2") + ")" : string.Empty)))}.",
                    "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }

            try
            {
                _mainForm?.PrintTextReceipt(BuildReceipt(order, picks, result, receiptNo));
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Payment recorded, but the receipt didn't print: " + ex.Message, "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }

            string done = result.BalanceAfter > 0
                ? $"Payment recorded. Remaining balance: {result.BalanceAfter:N2}"
                : "Payment recorded. The order is now fully paid.";
            if (!result.PortalUpdated)
                done += "\n\nThe portal's Amount Paid may take a few minutes to show it.";
            MessageBox.Show(this, done, "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Information);

            // Same as the old Online Orders PAY: back to the login screen after a payment.
            Close();
            _mainForm?.ForceLogoutAfterPayment();
        }

        // Tender + amount, repeated until the balance is covered (split payment) or the cashier stops
        // (part payment). Same dialog shape as the old Online Orders PAY.
        private List<TenderPick>? PickTenders(OnlineOrderInfo order, List<TenderType> tenders)
        {
            var picks = new List<TenderPick>();
            decimal remaining = order.Balance;
            TenderType? last = null;

            while (remaining > 0m)
            {
                using var dlg = new ThemedForm
                {
                    Text = "Enter Tender Amount",
                    StartPosition = FormStartPosition.CenterParent,
                    ClientSize = new Size(560, 230),
                    FormBorderStyle = FormBorderStyle.FixedDialog,
                    MaximizeBox = false,
                    MinimizeBox = false,
                    Font = new Font("Arial", 11)
                };
                var lblRemaining = new Label { Location = new Point(16, 14), Size = new Size(528, 28), Font = new Font("Arial", 12, FontStyle.Bold), Text = $"Remaining balance: {remaining:N2}" };
                var cmb = new ComboBox { Location = new Point(16, 52), Size = new Size(528, 30), DropDownStyle = ComboBoxStyle.DropDownList, Font = new Font("Arial", 13) };
                cmb.Items.AddRange(tenders.Cast<object>().ToArray());
                cmb.SelectedItem = last ?? tenders.FirstOrDefault(t => string.Equals(t.Code, "CASH", StringComparison.OrdinalIgnoreCase)) ?? tenders.FirstOrDefault();
                var lblAmount = new Label { Location = new Point(16, 108), Size = new Size(100, 28), Text = "Amount:", Font = new Font("Arial", 11, FontStyle.Bold) };
                var nud = new NumericUpDown { Location = new Point(120, 104), Size = new Size(200, 32), DecimalPlaces = 2, Minimum = 0.01m, Maximum = remaining, Value = remaining, Increment = 0.50m, ThousandsSeparator = true, Font = new Font("Arial", 13) };
                var lblFee = new Label { Location = new Point(16, 140), Size = new Size(528, 24), ForeColor = Color.Firebrick, Font = new Font("Arial", 11, FontStyle.Bold) };
                void ShowFee()
                {
                    var t = cmb.SelectedItem as TenderType;
                    decimal fee = t == null ? 0m : CardFee(nud.Value, t);
                    lblFee.Text = fee > 0m ? $"+ {t!.FeePercent:0.##}% card fee {fee:N2}  =  CHARGE {nud.Value + fee:N2}" : string.Empty;
                }
                cmb.SelectedIndexChanged += (s, e) => ShowFee();
                nud.ValueChanged += (s, e) => ShowFee();
                ShowFee();
                var btnOk = new Button { Text = "OK", DialogResult = DialogResult.OK, Location = new Point(316, 168), Size = new Size(110, 44) };
                var btnCancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(434, 168), Size = new Size(110, 44) };
                dlg.Controls.AddRange(new Control[] { lblRemaining, cmb, lblAmount, nud, lblFee, btnOk, btnCancel });
                dlg.AcceptButton = btnOk;
                dlg.CancelButton = btnCancel;

                if (dlg.ShowDialog(this) != DialogResult.OK)
                {
                    if (picks.Count == 0) return null;
                    // Money already taken by QR can't be cancelled - record what's been entered.
                    if (picks.Any(p => p.PaidByQr))
                    {
                        MessageBox.Show(this, $"P{QrPaidText(picks)} was already PAID by Xendit QR, so this records the {picks.Sum(p => p.Amount):N2} entered so far (part payment).", "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return picks;
                    }
                    // Stop here and pay what's been entered so far (a part payment), or cancel everything.
                    var partial = MessageBox.Show(this, $"Pay only {picks.Sum(p => p.Amount):N2} now (part payment)?\n\nNo = cancel the whole payment.", "Online Pay", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                    return partial == DialogResult.Yes ? picks : null;
                }

                if (cmb.SelectedItem is not TenderType tender) continue;
                decimal amount = Math.Min(nud.Value, remaining);
                if (amount <= 0m) continue;

                // Pancake keeps non-cash payments under the bank account set as the tender's POS Bank ID
                // (Tender Types); without one it can't be recorded. Portal-only orders don't use Pancake.
                if (!order.PortalOnly
                    && !string.Equals(tender.Code, "CASH", StringComparison.OrdinalIgnoreCase)
                    && string.IsNullOrWhiteSpace(tender.BankId))
                {
                    MessageBox.Show(this, $"\"{tender.Description}\" has no POS Bank ID in Tender Types, so the payment can't be recorded in Pancake.\n\nPick another tender, or set its POS Bank ID first.", "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    continue;
                }

                // Xendit QR - per "the pay online on the local POS.. can that accept QR (Xendit too?)": XENDIT /
                // GCash / QR Ph / Bank Transfer open the Xendit QR when online, like checkout (MainForm.PayWithXendit).
                // The customer pays first; only then is the part added, as XENDIT with no card fee (QR Ph has none).
                // A bigger amount is split: enter up to P50,000, then add another QR / tender for the rest.
                bool isXenditCode = string.Equals(tender.Code, MainForm.XenditTenderCode, StringComparison.OrdinalIgnoreCase);
                if (order.PortalOnly && (isXenditCode || MainForm.IsXenditRoutedTender(tender.Code, tender.Description)))
                {
                    if (!MainForm.IsXenditOnline())
                    {
                        if (isXenditCode)
                        {
                            MessageBox.Show(this, "No internet connection, so Xendit can't be used right now.\n\nNo money was taken. Please pick another tender.", "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                            continue;
                        }
                        if (MessageBox.Show(this,
                                $"The POS is offline, so the Xendit QR can't be used.\n\n"
                                + $"OK = record a manual {tender.Description}. Only continue once you see the money in OUR "
                                + $"{tender.Description} account - never accept a screenshot as proof.",
                                "Offline - manual payment", MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK)
                            continue;
                    }
                    else if (amount < MainForm.XenditMinAmount || amount > MainForm.XenditMaxAmount)
                    {
                        MessageBox.Show(this, $"A QR Ph payment must be between P{MainForm.XenditMinAmount:N2} and P{MainForm.XenditMaxAmount:N2}.\n\nEnter up to P{MainForm.XenditMaxAmount:N2} now, then add another QR (or tender) for the rest.", "Online Pay", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        continue;
                    }
                    else
                    {
                        using var xenditForm = new XenditPayForm(amount);
                        if (xenditForm.ShowDialog(this) != DialogResult.OK) continue;
                        var xenditTender = new TenderType { Code = MainForm.XenditTenderCode, Description = "Xendit" };
                        picks.Add(new TenderPick(xenditTender, amount, 0m, xenditForm.PaymentId));
                        last = tender;
                        remaining -= amount;
                        continue;
                    }
                }

                picks.Add(new TenderPick(tender, amount, CardFee(amount, tender)));
                last = tender;
                remaining -= amount;
            }
            return picks;
        }

        // Saves "ONL-<order>" on each QR payment, so the Xendit Payments page shows which order it was for.
        private static void LinkQrPayments(IEnumerable<TenderPick> picks, string receiptNo)
        {
            foreach (var p in picks.Where(p => p.PaidByQr))
                _ = XenditPayForm.LinkToReceiptAsync(p.XenditPaymentId!, receiptNo);
        }

        private static decimal CardFee(decimal amount, TenderType tender)
            => MainForm.ApplyMarkupPercent(amount, tender.FeePercent) - amount;

        private static List<TenderType> LoadTenderTypes()
        {
            var list = new List<TenderType>();
            try
            {
                using var conn = new SqlConnection(GlobalSettings.ConnectionString);
                conn.Open();
                using var cmd = new SqlCommand("SELECT Code, Description, POSBankID FROM TenderTypes ORDER BY Code", conn);
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    string code = Convert.ToString(rdr["Code"])?.Trim() ?? string.Empty;
                    string desc = Convert.ToString(rdr["Description"])?.Trim() ?? string.Empty;
                    if (code.Length == 0) continue;
                    if (string.IsNullOrWhiteSpace(desc)) desc = code;
                    // Same skip as the old PAY - not a real tender.
                    if (string.Equals(desc, "Advance Orders", StringComparison.OrdinalIgnoreCase)) continue;
                    list.Add(new TenderType { Code = code, Description = desc, BankId = Convert.ToString(rdr["POSBankID"])?.Trim() ?? string.Empty });
                }
            }
            catch { }
            if (list.Count == 0) list.Add(new TenderType { Code = "CASH", Description = "Cash" });
            return list;
        }

        // The till entry - same rows the old Online Orders PAY wrote (RecordAdvanceOrderPayment): one
        // TransactionHeader (Type SALES, Description = order ID) and one TransPaymentEntry per tender, under
        // receipt ONL-<order>. One header for the whole payment, in one SQL transaction. Amounts include the
        // card fee, so the till matches the card terminal. Description stays the order ID: the "| CardFee:"
        // marker is for receipts with item lines (a reprint of this one would show only the fee).
        private static void SaveLocalPayment(string receiptNo, string orderId, List<TenderPick> picks)
        {
            decimal total = picks.Sum(p => p.Charged);
            using var conn = new SqlConnection(GlobalSettings.ConnectionString);
            conn.Open();
            using var tx = conn.BeginTransaction();
            string user = CurrentUser.Username ?? "POS_SYSTEM";
            DateTime now = DateTime.Now;

            long txNo = 1;
            using (var cmd = new SqlCommand("SELECT TOP 1 TransactionNo FROM TransactionHeader WITH (UPDLOCK, HOLDLOCK) ORDER BY TransactionNo DESC", conn, tx))
            {
                var last = cmd.ExecuteScalar();
                if (last != null && last != DBNull.Value && long.TryParse(last.ToString(), out long lastNo)) txNo = lastNo + 1;
            }

            using (var hdr = new SqlCommand(@"
                INSERT INTO TransactionHeader (StoreNo, POSTerminalNo, TransactionNo, ReceiptNo, Type, Quantity, Price, Discount, GrossAmount, NetAmount, Date, Time, UserID, Description)
                VALUES ('001', '001', @TransactionNo, @ReceiptNo, 'SALES', 1, @Amount, 0, @Amount, @Amount, @Date, @Time, @UserID, @Description)", conn, tx))
            {
                hdr.Parameters.AddWithValue("@TransactionNo", txNo);
                hdr.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                hdr.Parameters.AddWithValue("@Amount", total);
                hdr.Parameters.AddWithValue("@Date", now);
                hdr.Parameters.AddWithValue("@Time", now.ToString("HH:mm:ss"));
                hdr.Parameters.AddWithValue("@UserID", user);
                hdr.Parameters.AddWithValue("@Description", orderId);
                hdr.ExecuteNonQuery();
            }

            int lineNo = 1;
            foreach (var p in picks)
            {
                using var pay = new SqlCommand(@"
                    INSERT INTO TransPaymentEntry (StoreNo, POSTerminalNo, TransactionNo, TenderTypeCode, [LineNo], ReceiptNo, Description, Amount, UserID, Date, Time, CreatedDate)
                    VALUES ('001', '001', @TransactionNo, @TenderTypeCode, @LineNo, @ReceiptNo, @Description, @Amount, @UserID, @Date, @Time, @CreatedDate)", conn, tx);
                pay.Parameters.AddWithValue("@TransactionNo", txNo.ToString(CultureInfo.InvariantCulture));
                pay.Parameters.AddWithValue("@TenderTypeCode", p.Tender.Code);
                pay.Parameters.AddWithValue("@LineNo", lineNo++);
                pay.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                pay.Parameters.AddWithValue("@Description", orderId);
                pay.Parameters.AddWithValue("@Amount", p.Charged);
                pay.Parameters.AddWithValue("@UserID", user);
                pay.Parameters.AddWithValue("@Date", now.Date);
                pay.Parameters.AddWithValue("@Time", now.TimeOfDay);
                pay.Parameters.AddWithValue("@CreatedDate", now);
                pay.ExecuteNonQuery();
            }

            tx.Commit();

            // Same log as checkout; like checkout, a failure here never undoes the payment.
            try
            {
                foreach (var p in picks.Where(p => p.Fee > 0m))
                {
                    MainForm.EnsureCardProcessingFeeLogTable(conn);
                    using var log = new SqlCommand(@"
                        INSERT INTO CardProcessingFeeLog (StoreNo, POSTerminalNo, TransactionNo, ReceiptNo, TenderTypeCode, FeeAmount, SaleAmount, MarkupPercent, UserID)
                        VALUES ('001', '001', @TransactionNo, @ReceiptNo, @TenderTypeCode, @FeeAmount, @SaleAmount, @MarkupPercent, @UserID)", conn);
                    log.Parameters.AddWithValue("@TransactionNo", txNo.ToString(CultureInfo.InvariantCulture));
                    log.Parameters.AddWithValue("@ReceiptNo", receiptNo);
                    log.Parameters.AddWithValue("@TenderTypeCode", p.Tender.Code);
                    log.Parameters.AddWithValue("@FeeAmount", p.Fee);
                    log.Parameters.AddWithValue("@SaleAmount", p.Charged);
                    log.Parameters.AddWithValue("@MarkupPercent", p.Tender.FeePercent);
                    log.Parameters.AddWithValue("@UserID", user);
                    log.ExecuteNonQuery();
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Card processing fee log warning: {ex.Message}");
            }
        }

        // 58mm receipt, same header / item layout as the old online-order receipt, built from the live order.
        private static string BuildReceipt(OnlineOrderInfo order, List<TenderPick> picks, PaymentResult result, string receiptNo)
        {
            int width = GlobalSettings.ReceiptWidth;
            string line = new string('-', width);
            string Row(string label, decimal amount)
            {
                string value = amount.ToString("N2", CultureInfo.InvariantCulture);
                return label.Length + value.Length + 1 > width ? label + " " + value : label + value.PadLeft(width - label.Length);
            }

            var r = new StringBuilder();
            r.AppendLine("      RS PET STOP");
            r.AppendLine("  AQUARIUM PRODUCTS");
            r.AppendLine("   & SOLUTIONS");
            r.AppendLine(line);
            r.AppendLine($"Date: {DateTime.Now:yyyy-MM-dd HH:mm}");
            r.AppendLine($"Receipt #: {receiptNo}");
            r.AppendLine($"Online Order ID: {order.OrderId}");
            r.AppendLine($"Cashier: {CurrentUser.GetEffectiveUsername("POS_SYSTEM")}");
            r.AppendLine(line);
            if (!string.IsNullOrWhiteSpace(order.CustomerName))
            {
                r.AppendLine($"Customer: {order.CustomerName}");
                r.AppendLine(line);
            }

            r.AppendLine("ITEMS:");
            r.AppendLine($"{"Item",-12} {"Qty",-3} {"Amount",8}");
            r.AppendLine(line);
            const int wrap = 12;
            foreach (var l in order.Lines)
            {
                string desc = string.IsNullOrWhiteSpace(l.Description) ? "-" : l.Description.Trim();
                for (int i = 0; i < desc.Length; i += wrap)
                {
                    string part = desc.Substring(i, Math.Min(wrap, desc.Length - i));
                    r.AppendLine(i == 0 ? $"{part,-12} {FormatQty(l.Qty),-3} {l.Amount,8:N2}" : part);
                }
            }
            r.AppendLine(line);

            if (order.DeliveryFee > 0) r.AppendLine(Row("Delivery Fee:", order.DeliveryFee));
            if (order.Discount > 0) r.AppendLine(Row("Discount:", order.Discount));
            r.AppendLine(Row("ORDER TOTAL:", order.Total));
            r.AppendLine(line);
            r.AppendLine(Row("Previous Payment:", result.AmountPaidBefore));
            foreach (var p in picks)
            {
                r.AppendLine(Row(p.Tender.Description + ":", p.Amount));
                if (p.Fee > 0m)
                {
                    r.AppendLine(Row($"Card Fee {p.Tender.FeePercent:0.##}%:", p.Fee));
                    r.AppendLine(Row("Charged:", p.Charged));
                }
            }
            r.AppendLine(Row("Total Paid:", result.AmountPaidAfter));
            r.AppendLine(result.BalanceAfter > 0 ? Row("BALANCE:", result.BalanceAfter) : "BALANCE: FULLY PAID");
            r.AppendLine(line);
            r.AppendLine();
            r.AppendLine("    THANK YOU!");
            r.AppendLine("  COME AGAIN SOON!");
            r.AppendLine(line);
            return r.ToString();
        }

        // ------------------------------------------------------------------ Helpers

        // POST to a Supabase RPC. A refusal from the SQL (raise exception) comes back as an exception with
        // its message; no connection throws HttpRequestException / TaskCanceledException.
        private static async Task<JsonDocument> CallRpcAsync(string url, object payload, TimeSpan timeout)
        {
            using var http = new HttpClient { Timeout = timeout };
            using var req = new HttpRequestMessage(HttpMethod.Post, url);
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
                    if (err.RootElement.ValueKind == JsonValueKind.Object && err.RootElement.TryGetProperty("message", out var m))
                        message = m.GetString() ?? text;
                }
                catch { }
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(message) ? $"HTTP {(int)resp.StatusCode}" : message);
            }
            return JsonDocument.Parse(string.IsNullOrWhiteSpace(text) ? "{}" : text);
        }

        private void SetBusy(bool busy, string? message)
        {
            UseWaitCursor = busy;
            _findButton.Enabled = !busy;
            _orderIdBox.Enabled = !busy;
            if (busy)
            {
                _payButton.Enabled = false;
                if (message != null) _infoLabel.Text = message;
            }
            else if (_order != null)
            {
                _payButton.Enabled = _order.CanPay && _order.Balance > 0;
            }
        }

        private static string FormatQty(decimal qty) => qty % 1 == 0 ? ((long)qty).ToString(CultureInfo.InvariantCulture) : qty.ToString("0.##", CultureInfo.InvariantCulture);

        private static string GetString(JsonElement e, string name)
            => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null
                ? (v.ValueKind == JsonValueKind.String ? v.GetString() ?? string.Empty : v.GetRawText())
                : string.Empty;

        private static bool GetBool(JsonElement e, string name)
            => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

        private static decimal GetDecimal(JsonElement e, string name)
        {
            if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(name, out var v)) return 0m;
            if (v.ValueKind == JsonValueKind.Number && v.TryGetDecimal(out var d)) return d;
            if (v.ValueKind == JsonValueKind.String && decimal.TryParse(v.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var s)) return s;
            return 0m;
        }
    }
}
