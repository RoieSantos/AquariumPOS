// Print counter for the Transfer Order / Production Order printouts - per "can we put no. of time printed
// and who print the TO?" and "i dont want to count cancelled prints". Loads how many times this document was
// already printed (staff_get_transfer_print_log, sql/supabase_transfer_print_log.sql; cancelled prints don't
// count) and stamps the page with the copy number this print will be ("Original" / "Copy #3 (reprint)"), who
// is printing and when.
//
// The browser can't tell a real print from a cancelled dialog, so:
//   beforeprint (Print button or Ctrl+P) - logs the attempt as 'Unconfirmed' (staff_log_transfer_print)
//   afterprint - asks "Did it print?": Yes -> 'Printed', No -> 'Cancelled' (staff_set_transfer_print_result)
// Unanswered stays 'Unconfirmed' and counts, so closing the tab can't hide a print. If the SQL isn't run yet
// the stamp stays hidden and printing works as before.
function setupTransferPrintLog(session, docNo, printType, stampEl) {
  if (!session?.username || !docNo || !stampEl) return;
  let printedSoFar = null; // non-cancelled prints; null until the history loads - nothing is stamped or logged before then
  let pendingLog = null;   // promise of the current attempt's log_id, until "Did it print?" is answered

  const whoNow = () => session.displayName || session.username;
  const fmt = (d) => new Date(d).toLocaleString('en-PH', {
    year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
  });
  const label = printType === 'Production' ? 'Production Order' : 'Transfer Order';

  function renderStamp(copyNo, by, at) {
    stampEl.textContent = `${copyNo === 1 ? 'Original' : `Copy #${copyNo} (reprint)`} - Printed by ${by} - ${fmt(at)}`;
    stampEl.classList.remove('hidden');
  }

  function rpc(name, args) {
    return supabaseClient.rpc(name, { p_admin_username: session.username, p_admin_password: session.password, ...args });
  }

  (async () => {
    try {
      const { data, error } = await rpc('staff_get_transfer_print_log', { p_document_no: docNo });
      if (error) return;
      printedSoFar = (data || []).filter((r) => r.print_type === printType && r.result !== 'Cancelled').length;
      renderStamp(printedSoFar + 1, whoNow(), new Date());
    } catch (e) {
      /* no stamp - printing still works */
    }
  })();

  // An attempt nobody answered (printed again with the question still open) stays Unconfirmed and counts.
  function abandonPending() {
    if (!pendingLog) return;
    pendingLog = null;
    printedSoFar += 1;
    document.getElementById('printConfirmBox')?.remove();
  }

  window.addEventListener('beforeprint', () => {
    if (printedSoFar === null) return;
    abandonPending();
    // Synchronous so the page being printed right now carries this copy's number.
    renderStamp(printedSoFar + 1, whoNow(), new Date());
    pendingLog = rpc('staff_log_transfer_print', { p_document_no: docNo, p_print_type: printType })
      .then(({ data, error }) => {
        if (error) { console.error('Logging the print failed:', error); return null; }
        return (data || [])[0]?.log_id ?? null;
      })
      .catch((err) => { console.error('Logging the print failed:', err); return null; });
  });

  window.addEventListener('afterprint', () => {
    if (!pendingLog) return;
    const thisLog = pendingLog;
    showConfirm(async (printed) => {
      if (pendingLog !== thisLog) return; // superseded by another print
      pendingLog = null;
      if (printed) printedSoFar += 1;
      renderStamp(printedSoFar + 1, whoNow(), new Date());
      const logId = await thisLog;
      if (logId == null) return;
      const { error } = await rpc('staff_set_transfer_print_result', { p_log_id: logId, p_result: printed ? 'Printed' : 'Cancelled' });
      if (error) console.error('Saving the print answer failed:', error);
    });
  });

  function showConfirm(onAnswer) {
    document.getElementById('printConfirmBox')?.remove();
    const box = document.createElement('div');
    box.id = 'printConfirmBox';
    box.className = 'no-print';
    box.setAttribute('role', 'alertdialog');
    box.setAttribute('aria-modal', 'true');
    box.style.cssText = 'position:fixed;inset:0;z-index:100000;background:rgba(0,0,0,0.55);display:flex;'
      + 'align-items:center;justify-content:center;padding:16px;box-sizing:border-box;';
    box.innerHTML = `
      <div style="background:var(--panel-bg,#fff);color:var(--text-main,#111);border-radius:10px;box-shadow:var(--shadow);
                  max-width:400px;width:100%;padding:20px;box-sizing:border-box;">
        <h2 style="margin:0 0 8px;font-size:18px;">Did ${payoutNoticeEscape(label)} ${payoutNoticeEscape(docNo)} print?</h2>
        <p class="muted" style="margin:0 0 16px;font-size:14px;">Only prints that went through are counted. A cancelled print is kept in the history but not counted.</p>
        <div style="display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;">
          <button type="button" class="btn btn-secondary" data-printed="no">No, I cancelled</button>
          <button type="button" class="btn btn-primary" data-printed="yes">Yes, it printed</button>
        </div>
      </div>`;
    box.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-printed]');
      if (!btn) return;
      box.remove();
      onAnswer(btn.dataset.printed === 'yes');
    });
    document.body.appendChild(box);
    box.querySelector('[data-printed="yes"]').focus();
  }
}
