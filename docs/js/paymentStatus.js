// Payment Status page (payment-status.html) - Xendit's live status for the channels we use.
// The fetching / filtering lives in js/nav.js (fetchPaymentChannelStatus) so the top-of-page banner and
// this page always agree. Open to every login (ALL_STAFF_PAGES in js/auth.js).

let paymentStatusSession = null;

function psEscape(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function psWhen(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleString('en-PH', { timeZone: 'Asia/Manila', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function psBadge(status) {
  const sev = paymentStatusSeverity(status);
  const cls = sev === 'ok' ? 'badge-success' : (sev === 'danger' ? 'badge-danger' : 'badge-warning');
  return `<span class="badge ${cls}">${psEscape(XENDIT_STATUS_TEXT[status] || status)}</span>`;
}

function psRows(channels) {
  return channels.map((c) => `<tr><td>${psEscape(c.label)}</td><td>${psBadge(c.status)}</td></tr>`).join('');
}

async function loadPaymentStatus(force) {
  const overall = document.getElementById('overallBox');
  const status = await fetchPaymentChannelStatus(force);
  if (!status) {
    overall.innerHTML = '<span class="error-text">Could not reach Xendit\'s status page. Check the internet connection, or open <a href="https://status.xendit.co/" target="_blank" rel="noopener">status.xendit.co</a>.</span>';
    return;
  }
  const seesPayouts = !!(paymentStatusSession?.isSuperUser || paymentStatusSession?.isPayrollOfficer);
  const payments = status.channels.filter((c) => c.kind === 'payment');
  const payouts = status.channels.filter((c) => c.kind === 'payout');
  const badPayments = payments.filter((c) => c.status !== 'operational');
  const badPayouts = payouts.filter((c) => c.status !== 'operational');

  let headline;
  if (badPayments.length) {
    const color = badPayments.some((c) => paymentStatusSeverity(c.status) === 'danger') ? 'var(--danger)' : '#a6720a';
    headline = `<strong style="color:${color};">Some payment channels have problems:</strong> ${badPayments.map((c) => psEscape(c.label)).join(', ')}. Offer the customer another payment method.`;
  } else {
    headline = '<strong style="color:var(--success);">All payment channels are working</strong> on Xendit\'s side.';
  }
  if (seesPayouts && badPayouts.length) {
    headline += `<br><strong style="color:#a6720a;">Payouts:</strong> ${badPayouts.map((c) => psEscape(c.label)).join(', ')} - a payout may fail or wait; a failed one returns to the Xendit balance.`;
  }
  overall.innerHTML = `${headline}<div class="muted" style="font-size:12px;margin-top:6px;">Checked ${psWhen(new Date().toISOString())}</div>`;

  document.getElementById('paymentRows').innerHTML = psRows(payments) || '<tr><td colspan="2" class="muted">No channels found.</td></tr>';
  document.getElementById('payoutSection').classList.toggle('hidden', !seesPayouts);
  if (seesPayouts) document.getElementById('payoutRows').innerHTML = psRows(payouts);

  // Incidents: hide payout-only ones from staff who don't send payouts.
  const visible = (item) => seesPayouts || item.channels.some((label) => payments.some((p) => p.label === label));
  const incidents = status.incidents.filter(visible);
  document.getElementById('incidentsSection').classList.toggle('hidden', !incidents.length);
  document.getElementById('incidentsList').innerHTML = incidents.map((i) => `
    <div class="card" style="padding:12px 14px;margin-bottom:10px;border-left:4px solid ${i.impact === 'critical' || i.impact === 'major' ? 'var(--danger)' : '#a6720a'};">
      <div><strong>${psEscape(i.name)}</strong> <span class="badge badge-neutral">${psEscape(i.status)}</span></div>
      <div class="muted" style="font-size:13px;margin-top:4px;">Affects: ${psEscape(i.channels.join(', '))} · since ${psWhen(i.started_at)} · updated ${psWhen(i.updated_at)}</div>
      ${i.update ? `<div style="margin-top:6px;font-size:14px;">${psEscape(i.update)}</div>` : ''}
    </div>`).join('');

  // Maintenance: in progress or starting within the next 3 days.
  const horizon = Date.now() + 3 * 24 * 60 * 60 * 1000;
  const maint = status.maintenances
    .filter(visible)
    .filter((m) => m.status === 'in_progress' || new Date(m.scheduled_for).getTime() < horizon)
    .sort((a, b) => new Date(a.scheduled_for) - new Date(b.scheduled_for));
  document.getElementById('maintSection').classList.toggle('hidden', !maint.length);
  document.getElementById('maintRows').innerHTML = maint.map((m) => `<tr>
      <td>${m.status === 'in_progress' ? '<span class="badge badge-warning">Now</span> ' : ''}${psWhen(m.scheduled_for)} - ${psWhen(m.scheduled_until)}</td>
      <td>${psEscape(m.name)}</td>
      <td>${psEscape(m.channels.join(', '))}</td>
    </tr>`).join('');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  paymentStatusSession = session;
  renderTopNav('Payment Status');
  document.getElementById('refreshBtn').addEventListener('click', () => loadPaymentStatus(true));
  await loadPaymentStatus(true);
  setInterval(() => loadPaymentStatus(true), 2 * 60 * 1000);
})();
