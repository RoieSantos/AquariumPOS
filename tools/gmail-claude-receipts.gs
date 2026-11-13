/**
 * Gmail -> RS Pet Stop portal: auto-log Anthropic (Claude) receipts as expenses.
 *
 * Runs inside YOUR Google account (script.google.com), every 15 minutes. It finds Anthropic receipt
 * emails, reads the receipt number / date / USD amounts, and sends them to the portal's
 * claude-receipt-log Edge Function, which converts to pesos and adds an Expense Journal entry.
 * Each logged email gets the Gmail label "Portal/Claude logged"; one it can't read gets
 * "Portal/Claude needs review" (log that one by hand).
 *
 * SETUP (once):
 *   1. script.google.com -> New project -> paste this whole file -> Save.
 *   2. Project Settings (gear) -> Script Properties -> add:
 *        PORTAL_RECEIPT_URL    = https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/claude-receipt-log
 *        PORTAL_RECEIPT_SECRET = (the same value you set as the CLAUDE_RECEIPT_SECRET secret in Supabase)
 *        START_DATE            = 2026-11-01   (optional - receipts paid BEFORE this date are
 *                                              skipped; defaults to 2026-11-01, the first month
 *                                              tracked)
 *   3. Run dryRun() and check the log: it shows what it WOULD send for your recent receipts, without
 *      sending anything. Approve the Gmail permission prompt the first time.
 *   4. Run installTrigger() once - from then on it runs by itself every 15 minutes.
 *
 * The same receipt can never be logged twice (the portal keys on Anthropic's receipt number), so
 * re-running is always safe.
 */

// Anthropic receipts are sent through Stripe - match either sender domain. If dryRun() finds
// nothing, open one receipt in Gmail, check its "from" address, and adjust this line.
const SEARCH_QUERY = 'subject:receipt (from:anthropic.com OR (from:stripe.com Anthropic)) newer_than:60d';
const LABEL_DONE = 'Portal/Claude logged';
const LABEL_REVIEW = 'Portal/Claude needs review';

function run() {
  processReceipts_(false);
}

function dryRun() {
  processReceipts_(true);
}

function installTrigger() {
  ScriptApp.getProjectTriggers()
    .filter((t) => t.getHandlerFunction() === 'run')
    .forEach((t) => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('run').timeBased().everyMinutes(15).create();
  Logger.log('Trigger installed: run() every 15 minutes.');
}

function processReceipts_(dry) {
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('PORTAL_RECEIPT_URL');
  const secret = props.getProperty('PORTAL_RECEIPT_SECRET');
  const startDate = props.getProperty('START_DATE') || '2026-11-01';
  if (!dry && (!url || !secret)) throw new Error('Set PORTAL_RECEIPT_URL and PORTAL_RECEIPT_SECRET in Script Properties.');

  const doneLabel = getOrCreateLabel_(LABEL_DONE);
  const reviewLabel = getOrCreateLabel_(LABEL_REVIEW);
  const query = SEARCH_QUERY + (dry ? '' : ` -label:"${LABEL_DONE}" -label:"${LABEL_REVIEW}"`);

  GmailApp.search(query, 0, 50).forEach((thread) => {
    thread.getMessages().forEach((message) => {
      const receipt = parseReceipt_(message);

      if (!receipt.ok) {
        Logger.log(`NEEDS REVIEW - "${message.getSubject()}": ${receipt.reason}`);
        if (!dry) thread.addLabel(reviewLabel);
        return;
      }
      if (receipt.date_paid < startDate) {
        Logger.log(`skip (before START_DATE ${startDate}) - ${receipt.receipt_number} ${receipt.date_paid} $${receipt.total_usd}`);
        if (!dry) thread.addLabel(doneLabel);
        return;
      }
      if (dry) {
        Logger.log('WOULD SEND: ' + JSON.stringify(receipt));
        return;
      }

      const res = UrlFetchApp.fetch(url, {
        method: 'post',
        contentType: 'application/json',
        headers: { 'x-receipt-secret': secret },
        payload: JSON.stringify(receipt),
        muteHttpExceptions: true
      });
      const code = res.getResponseCode();
      if (code === 200) {
        Logger.log(`${receipt.receipt_number}: ${res.getContentText()}`);
        thread.addLabel(doneLabel);
      } else {
        // Left unlabeled so the next run retries (e.g. exchange rate service briefly down).
        Logger.log(`FAILED ${receipt.receipt_number} (HTTP ${code}): ${res.getContentText()}`);
      }
    });
  });
}

function parseReceipt_(message) {
  const text = (message.getPlainBody() || '').replace(/ /g, ' ');
  const subject = message.getSubject() || '';
  const money = (re) => {
    const m = text.match(re);
    return m ? Number(m[1].replace(/,/g, '')) : null;
  };

  const receiptMatch = text.match(/Receipt\s*(?:number|#|no\.?)\s*:?\s*#?\s*(\d{4}-\d{4}(?:-\d{4})?)/i)
    || subject.match(/#\s*(\d{4}-\d{4}(?:-\d{4})?)/);
  if (!receiptMatch) return { ok: false, reason: 'no receipt number found' };

  const total = money(/Amount paid\s*:?\s*\$\s*([\d,]+\.\d{2})/i) ?? money(/\bTotal\s*:?\s*\$\s*([\d,]+\.\d{2})/i);
  if (!total) return { ok: false, reason: 'no "Amount paid" found' };

  const subtotal = money(/Subtotal\s*:?\s*\$\s*([\d,]+\.\d{2})/i);
  const tax = subtotal != null ? Math.round((total - subtotal) * 100) / 100 : null;

  const invoiceMatch = text.match(/Invoice\s*(?:number|#)\s*:?\s*#?\s*([A-Z0-9]+-\d{3,})/i);

  // Built straight from the text ("November 4, 2026") - no Date object, so no time zone shift.
  const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  const dateMatch = text.match(/(?:Date paid|paid on)\s*:?\s*([A-Za-z]+) (\d{1,2}), (\d{4})/i);
  let datePaid;
  if (dateMatch) {
    const month = MONTHS.indexOf(dateMatch[1].slice(0, 3).toLowerCase()) + 1;
    if (month < 1) return { ok: false, reason: 'could not read the date paid' };
    datePaid = `${dateMatch[3]}-${String(month).padStart(2, '0')}-${dateMatch[2].padStart(2, '0')}`;
  } else {
    datePaid = Utilities.formatDate(message.getDate(), 'Asia/Manila', 'yyyy-MM-dd');
  }

  // Subscription vs API credits. Anything else -> needs review rather than guessing.
  const planMatch = text.match(/Claude\s+(Pro|Max|Team|Enterprise)\b[^\n$]*/i);
  const creditMatch = text.match(/[^\n]*\b(credit|credits|API usage|prepaid)\b[^\n$]*/i);
  let kind = null;
  let item = null;
  if (planMatch) {
    kind = 'subscription';
    item = planMatch[0].trim();
  } else if (creditMatch) {
    kind = 'api_credits';
    item = creditMatch[0].trim();
  }
  if (!kind) return { ok: false, reason: 'could not tell if this is API credits or a subscription' };

  return {
    ok: true,
    receipt_number: receiptMatch[1],
    invoice_number: invoiceMatch ? invoiceMatch[1] : null,
    date_paid: datePaid,
    kind: kind,
    item_description: item ? item.slice(0, 300) : null,
    subtotal_usd: subtotal,
    tax_usd: tax,
    total_usd: total,
    gmail_message_id: message.getId()
  };
}

function getOrCreateLabel_(name) {
  return GmailApp.getUserLabelByName(name) || GmailApp.createLabel(name);
}
