using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Linq;

namespace AquariumPOS
{
    // Voided advance order -> its payment applied to a new order (per "they are voiding the transaction then
    // the payment now is floating. can we apply that payment into a new order?").
    //
    // Two kinds of voided order can give credit:
    //   * HELD  - voided with "Keep as credit" (AdvanceOrderHeader.VoidCredit set): no refund was written, the
    //             money is still on the voided receipt. Available = net TransPaymentEntry on that receipt per
    //             tender. Applying it writes a negative "CREDIT TO <new receipt>" row there (same tender, same
    //             payment transaction - like a void refund) and the new order gets the positive row, so the
    //             drawer / EOD / Dashboard tender split never move: the money just changes order.
    //   * REFUNDED - voided the old way (full refund written) but the customer never actually took the money.
    //             Available = the VOID REFUND rows minus what was already applied (AdvanceOrderVoidCreditUse).
    //             Applying only writes the new order's positive row (it cancels the refund that never
    //             happened). Needs a Super User and only for voids in the last RefundedCreditDays days.
    // Every use is logged in dbo.AdvanceOrderVoidCreditUse and totalled on the header (VoidCreditUsed /
    // VoidCreditUsedOn), which syncs to the portal with the other void columns.
    internal static class VoidOrderCredit
    {
        internal const int RefundedCreditDays = 30;
        internal const string CreditFromPrefix = "CREDIT FROM ";
        internal const string CreditToPrefix = "CREDIT TO ";

        internal sealed class Tender
        {
            public string StoreNo { get; init; } = string.Empty;
            public string PosTerminalNo { get; init; } = string.Empty;
            public string PaymentTransactionNo { get; init; } = string.Empty;
            public string TenderTypeCode { get; init; } = string.Empty;
            public decimal Available { get; set; }
        }

        internal sealed class Source
        {
            public string TransactionNo { get; init; } = string.Empty;
            public string ReceiptNo { get; init; } = string.Empty;
            public string CustomerName { get; init; } = string.Empty;
            public string CustomerMobile { get; init; } = string.Empty;
            public string CustomerPsid { get; init; } = string.Empty;
            public string CustomerAddress { get; init; } = string.Empty;
            public DateTime? VoidedAtUtc { get; init; }
            public string VoidReason { get; init; } = string.Empty;
            public bool Held { get; init; }
            public List<Tender> Tenders { get; } = new();
            public decimal Available => Tenders.Sum(t => t.Available);
        }

        // One credit line staged on the current sale (MainForm.pendingVoidCredits), written by Commit once the
        // sale's payments are recorded.
        internal sealed class Pending
        {
            public PaymentEntry Payment { get; init; } = null!;
            public Source Source { get; init; } = null!;
            public Tender Tender { get; init; } = null!;
            public string? ApprovedBy { get; init; }
        }

        internal static void EnsureSchema(SqlConnection connection, SqlTransaction? tx = null)
        {
            AdvanceOrdersHeaderForm.EnsureAdvanceOrderVoidColumns(connection, tx);
            using var cmd = new SqlCommand(@"
IF OBJECT_ID('dbo.AdvanceOrderVoidCreditUse', 'U') IS NULL
    CREATE TABLE dbo.AdvanceOrderVoidCreditUse (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        VoidTransactionNo NVARCHAR(20) NOT NULL,
        VoidReceiptNo NVARCHAR(20) NOT NULL,
        SourceStoreNo NVARCHAR(10) NOT NULL,
        SourcePOSTerminalNo NVARCHAR(10) NOT NULL,
        SourcePaymentTransactionNo NVARCHAR(20) NOT NULL,
        TenderTypeCode NVARCHAR(10) NOT NULL,
        Amount DECIMAL(18,2) NOT NULL,
        AppliedReceiptNo NVARCHAR(20) NOT NULL,
        AppliedTransactionNo NVARCHAR(20) NULL,
        Held BIT NOT NULL,
        AppliedBy NVARCHAR(100) NULL,
        ApprovedBy NVARCHAR(100) NULL,
        AppliedAt DATETIME2 NOT NULL CONSTRAINT DF_AdvanceOrderVoidCreditUse_AppliedAt DEFAULT (SYSDATETIME())
    );", connection, tx);
            cmd.ExecuteNonQuery();
        }

        // Voided orders that still have credit to give, newest void first. excludeOrPending: amounts already
        // staged on the current sale, keyed by Key(source, tender), taken off what's shown.
        internal static List<Source> LoadAvailable(string connectionString, IReadOnlyDictionary<string, decimal>? staged = null)
        {
            var sources = new Dictionary<string, Source>(StringComparer.OrdinalIgnoreCase);
            using var conn = new SqlConnection(connectionString);
            conn.Open();
            EnsureSchema(conn);
            AdvanceOrdersHeaderForm.EnsureCustomerTagColumns(conn);

            using var cmd = new SqlCommand(@"
WITH v AS (
    SELECT h.TransactionNo, h.ReceiptNo, h.CustomerName, h.CustomerMobile, h.CustomerPsid, h.CustomerAddress,
           h.VoidedAtUtc, h.VoidReason, CAST(CASE WHEN h.VoidCredit IS NOT NULL THEN 1 ELSE 0 END AS bit) AS Held
    FROM dbo.AdvanceOrderHeader h
    WHERE h.IsVoid = 1 AND ISNULL(h.ReceiptNo, '') <> ''
      AND (h.VoidCredit IS NOT NULL
           OR (ISNULL(h.VoidRefund, 0) > 0 AND h.VoidedAtUtc >= DATEADD(day, -@days, SYSUTCDATETIME())))
),
t AS (
    -- HELD: what is still on the voided receipt.
    SELECT v.TransactionNo, p.StoreNo, p.POSTerminalNo, p.TransactionNo AS PayTx, p.TenderTypeCode, SUM(p.Amount) AS Available
    FROM v JOIN dbo.TransPaymentEntry p ON p.ReceiptNo = v.ReceiptNo
    WHERE v.Held = 1
    GROUP BY v.TransactionNo, p.StoreNo, p.POSTerminalNo, p.TransactionNo, p.TenderTypeCode
    UNION ALL
    -- REFUNDED: the void refund, less what was already applied.
    SELECT v.TransactionNo, p.StoreNo, p.POSTerminalNo, p.TransactionNo, p.TenderTypeCode,
           -SUM(p.Amount) - ISNULL((SELECT SUM(u.Amount) FROM dbo.AdvanceOrderVoidCreditUse u
                                    WHERE u.VoidTransactionNo = v.TransactionNo AND u.SourceStoreNo = p.StoreNo
                                      AND u.SourcePOSTerminalNo = p.POSTerminalNo
                                      AND u.SourcePaymentTransactionNo = p.TransactionNo
                                      AND u.TenderTypeCode = p.TenderTypeCode), 0)
    FROM v JOIN dbo.TransPaymentEntry p ON p.ReceiptNo = v.ReceiptNo AND p.Description = 'VOID REFUND'
    WHERE v.Held = 0
    GROUP BY v.TransactionNo, p.StoreNo, p.POSTerminalNo, p.TransactionNo, p.TenderTypeCode
)
SELECT v.TransactionNo, v.ReceiptNo, v.CustomerName, v.CustomerMobile, v.CustomerPsid, v.CustomerAddress,
       v.VoidedAtUtc, v.VoidReason, v.Held, t.StoreNo, t.POSTerminalNo, t.PayTx, t.TenderTypeCode, t.Available
FROM v JOIN t ON t.TransactionNo = v.TransactionNo
WHERE t.Available > 0
ORDER BY v.VoidedAtUtc DESC, v.TransactionNo, t.TenderTypeCode", conn);
            cmd.Parameters.AddWithValue("@days", RefundedCreditDays);
            using var rdr = cmd.ExecuteReader();
            while (rdr.Read())
            {
                string tn = Str(rdr["TransactionNo"]);
                if (!sources.TryGetValue(tn, out var source))
                {
                    source = new Source
                    {
                        TransactionNo = tn,
                        ReceiptNo = Str(rdr["ReceiptNo"]),
                        CustomerName = Str(rdr["CustomerName"]),
                        CustomerMobile = Str(rdr["CustomerMobile"]),
                        CustomerPsid = Str(rdr["CustomerPsid"]),
                        CustomerAddress = Str(rdr["CustomerAddress"]),
                        VoidedAtUtc = rdr["VoidedAtUtc"] is DateTime d ? d : null,
                        VoidReason = Str(rdr["VoidReason"]),
                        Held = rdr["Held"] is bool b && b
                    };
                    sources[tn] = source;
                }
                var tender = new Tender
                {
                    StoreNo = Str(rdr["StoreNo"]),
                    PosTerminalNo = Str(rdr["POSTerminalNo"]),
                    PaymentTransactionNo = Str(rdr["PayTx"]),
                    TenderTypeCode = Str(rdr["TenderTypeCode"]),
                    Available = Convert.ToDecimal(rdr["Available"])
                };
                if (staged != null && staged.TryGetValue(Key(source, tender), out decimal already))
                    tender.Available -= already;
                if (tender.Available > 0m)
                    source.Tenders.Add(tender);
            }

            return sources.Values.Where(s => s.Available > 0m).ToList();
        }

        // What may still be spent of `local` once the portal's own uses ("New Order from Credit",
        // supabase_advance_order_credit_order.sql) are taken off. Not on the portal yet (just voided, not synced) =
        // nothing used there.
        internal static decimal AllowedAfterPortal(decimal local, string transactionNo,
            IReadOnlyDictionary<string, (bool Found, decimal PortalUsed, decimal Left)> portal)
        {
            if (!portal.TryGetValue(transactionNo, out var p) || !p.Found)
                return Math.Max(0m, local);
            return Math.Max(0m, Math.Min(local - p.PortalUsed, p.Left));
        }

        // Trims the tenders (last first) so they add up to no more than `allowed`.
        internal static void TrimTenders(List<Tender> tenders, decimal allowed)
        {
            decimal excess = tenders.Sum(t => t.Available) - Math.Max(0m, allowed);
            for (int i = tenders.Count - 1; i >= 0 && excess > 0m; i--)
            {
                decimal cut = Math.Min(tenders[i].Available, excess);
                tenders[i].Available -= cut;
                excess -= cut;
            }
            tenders.RemoveAll(t => t.Available <= 0m);
        }

        // LoadAvailable, capped by what the portal already used. Throws when the portal can't be reached.
        internal static List<Source> LoadAvailableCheckedWithPortal(string connectionString, IReadOnlyDictionary<string, decimal>? staged = null)
        {
            var sources = LoadAvailable(connectionString, staged);
            if (sources.Count == 0)
                return sources;
            var portal = System.Threading.Tasks.Task.Run(() => OnlinefunctionsEvents.GetAdvanceOrderPortalCreditAsync(sources.Select(s => s.TransactionNo)))
                .GetAwaiter().GetResult();
            foreach (var s in sources)
            {
                // Staged amounts on this sale were already taken off by LoadAvailable; take them off `local` too.
                decimal stagedHere = staged == null ? 0m : staged.Where(kv => kv.Key.StartsWith(s.TransactionNo + "|", StringComparison.OrdinalIgnoreCase)).Sum(kv => kv.Value);
                decimal allowed = AllowedAfterPortal(s.Available + stagedHere, s.TransactionNo, portal) - stagedHere;
                TrimTenders(s.Tenders, allowed);
            }
            return sources.Where(s => s.Available > 0m).ToList();
        }

        internal static string Key(Source source, Tender tender) =>
            $"{source.TransactionNo}|{tender.StoreNo}|{tender.PosTerminalNo}|{tender.PaymentTransactionNo}|{tender.TenderTypeCode}";

        // Writes the use of each staged credit the sale actually recorded (amount = the PaymentEntry's amount
        // after any change was taken off). Called by MainForm.RecordPaymentEntry on the same connection, right
        // after the sale's TransPaymentEntry rows. Returns the voided receipts touched (to sync to the portal).
        internal static List<string> Commit(SqlConnection connection, IEnumerable<Pending> pending, IReadOnlyCollection<PaymentEntry> recorded,
            string appliedReceiptNo, string? appliedTransactionNo, string userId)
        {
            var touched = new List<string>();
            var list = pending.Where(p => recorded.Contains(p.Payment) && p.Payment.Amount > 0m).ToList();
            if (list.Count == 0)
                return touched;

            using var tx = connection.BeginTransaction();
            EnsureSchema(connection, tx);
            DateTime now = DateTime.Now;
            foreach (var p in list)
            {
                decimal amount = Math.Round(p.Payment.Amount, 2);

                if (p.Source.Held)
                {
                    // Move the money off the voided receipt (same tender + payment transaction it came in on).
                    using var lineCmd = new SqlCommand(@"
SELECT ISNULL(MAX([LineNo]), 0) + 1 FROM dbo.TransPaymentEntry
WHERE StoreNo = @storeNo AND POSTerminalNo = @posTerminalNo AND TransactionNo = @transactionNo", connection, tx);
                    lineCmd.Parameters.AddWithValue("@storeNo", p.Tender.StoreNo);
                    lineCmd.Parameters.AddWithValue("@posTerminalNo", p.Tender.PosTerminalNo);
                    lineCmd.Parameters.AddWithValue("@transactionNo", p.Tender.PaymentTransactionNo);
                    int lineNo = Convert.ToInt32(lineCmd.ExecuteScalar());

                    using var insert = new SqlCommand(@"
INSERT INTO dbo.TransPaymentEntry (StoreNo, POSTerminalNo, TransactionNo, TenderTypeCode, [LineNo], ReceiptNo, Description, Amount, UserID, Date, Time, CreatedDate)
VALUES (@storeNo, @posTerminalNo, @transactionNo, @tenderTypeCode, @lineNo, @receiptNo, @description, @amount, @userID, @date, @time, @createdDate)", connection, tx);
                    insert.Parameters.AddWithValue("@storeNo", p.Tender.StoreNo);
                    insert.Parameters.AddWithValue("@posTerminalNo", p.Tender.PosTerminalNo);
                    insert.Parameters.AddWithValue("@transactionNo", p.Tender.PaymentTransactionNo);
                    insert.Parameters.AddWithValue("@tenderTypeCode", p.Tender.TenderTypeCode);
                    insert.Parameters.AddWithValue("@lineNo", lineNo);
                    insert.Parameters.AddWithValue("@receiptNo", p.Source.ReceiptNo);
                    insert.Parameters.AddWithValue("@description", CreditToPrefix + appliedReceiptNo);
                    insert.Parameters.AddWithValue("@amount", -amount);
                    insert.Parameters.AddWithValue("@userID", userId);
                    insert.Parameters.AddWithValue("@date", now.Date);
                    insert.Parameters.AddWithValue("@time", now.TimeOfDay);
                    insert.Parameters.AddWithValue("@createdDate", now);
                    insert.ExecuteNonQuery();
                }

                using (var use = new SqlCommand(@"
INSERT INTO dbo.AdvanceOrderVoidCreditUse (VoidTransactionNo, VoidReceiptNo, SourceStoreNo, SourcePOSTerminalNo, SourcePaymentTransactionNo,
    TenderTypeCode, Amount, AppliedReceiptNo, AppliedTransactionNo, Held, AppliedBy, ApprovedBy)
VALUES (@vtn, @vrc, @store, @pos, @ptx, @tender, @amount, @arc, @atn, @held, @by, @approvedBy)", connection, tx))
                {
                    use.Parameters.AddWithValue("@vtn", p.Source.TransactionNo);
                    use.Parameters.AddWithValue("@vrc", p.Source.ReceiptNo);
                    use.Parameters.AddWithValue("@store", p.Tender.StoreNo);
                    use.Parameters.AddWithValue("@pos", p.Tender.PosTerminalNo);
                    use.Parameters.AddWithValue("@ptx", p.Tender.PaymentTransactionNo);
                    use.Parameters.AddWithValue("@tender", p.Tender.TenderTypeCode);
                    use.Parameters.AddWithValue("@amount", amount);
                    use.Parameters.AddWithValue("@arc", appliedReceiptNo);
                    use.Parameters.AddWithValue("@atn", (object?)appliedTransactionNo ?? DBNull.Value);
                    use.Parameters.AddWithValue("@held", p.Source.Held);
                    use.Parameters.AddWithValue("@by", userId);
                    use.Parameters.AddWithValue("@approvedBy", (object?)p.ApprovedBy ?? DBNull.Value);
                    use.ExecuteNonQuery();
                }

                if (!touched.Contains(p.Source.ReceiptNo, StringComparer.OrdinalIgnoreCase))
                    touched.Add(p.Source.ReceiptNo);
            }

            // Header totals (synced to the portal): used so far + which receipts it went to.
            foreach (var tn in list.Select(p => p.Source.TransactionNo).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                using var update = new SqlCommand(@"
UPDATE dbo.AdvanceOrderHeader
SET VoidCreditUsed = (SELECT SUM(Amount) FROM dbo.AdvanceOrderVoidCreditUse WHERE VoidTransactionNo = @tn),
    VoidCreditUsedOn = LEFT(STUFF((SELECT DISTINCT ', ' + AppliedReceiptNo FROM dbo.AdvanceOrderVoidCreditUse
                                   WHERE VoidTransactionNo = @tn FOR XML PATH('')), 1, 2, ''), 200)
WHERE TransactionNo = @tn", connection, tx);
                update.Parameters.AddWithValue("@tn", tn);
                update.ExecuteNonQuery();
            }

            tx.Commit();
            return touched;
        }

        private static string Str(object? value) => value == null || value == DBNull.Value ? string.Empty : value.ToString()?.Trim() ?? string.Empty;
    }
}
