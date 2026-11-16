// Meta Ads page (super users only) - wallet balance per store's ad account, loads (= expense) and
// Meta's daily charges. See sql/supabase_meta_ads_page.sql and supabase/functions/meta-ads-sync.
let currentSession = null;
let loadGeneration = 0;
let lastData = null;

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

const SYMBOLS = { PHP: '₱', EUR: '€', USD: '$' };

function money(value, currency = 'PHP') {
  if (value === null || value === undefined || value === '') return '-';
  const sym = SYMBOLS[currency] ?? `${currency} `;
  return sym + Number(value).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function isoDate(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function setRange(kind) {
  const now = new Date();
  let from = new Date(now);
  let to = new Date(now);
  if (kind === '7d') from.setDate(now.getDate() - 6);
  if (kind === 'month') from = new Date(now.getFullYear(), now.getMonth(), 1);
  if (kind === 'lastmonth') {
    from = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    to = new Date(now.getFullYear(), now.getMonth(), 0);
  }
  document.getElementById('fromInput').value = isoDate(from);
  document.getElementById('toInput').value = isoDate(to);
}

function storeLabel(a) {
  return a.store || a.name || `act_${a.ad_account_id}`;
}

function renderCards(accounts) {
  const box = document.getElementById('balanceCards');
  if (!accounts.length) {
    box.innerHTML = '<div class="stat-card"><div class="muted">No ad accounts synced yet.</div></div>';
    return;
  }
  box.innerHTML = accounts.map((a) => {
    const cur = a.currency || 'PHP';
    const bal = a.available_balance;
    const phpEq = cur !== 'PHP' && bal !== null && a.latest_rate ? ` · ≈ ${money(Number(bal) * Number(a.latest_rate))}` : '';
    const avg = Number(a.avg_daily_charge_7d || 0);
    const daysLeft = avg > 0 && bal !== null ? Number(bal) / avg : null;
    const low = daysLeft !== null && daysLeft < 2;
    const daysText = daysLeft === null
      ? 'No charges in the last 7 days'
      : `About ${daysLeft < 1 ? 'less than 1 day' : `${Math.floor(daysLeft)} day${Math.floor(daysLeft) === 1 ? '' : 's'}`} left at ${money(avg, cur)}/day`;
    const failed = String(a.last_sync_result || '').startsWith('error');
    const synced = a.last_sync_at ? new Date(a.last_sync_at).toLocaleString() : 'never';
    return `
      <div class="stat-card">
        <div class="stat-label">${escapeHtml(storeLabel(a))} wallet</div>
        <div class="stat-value">${money(bal, cur)}</div>
        <div class="muted">${escapeHtml(a.name || '')} (act_${escapeHtml(a.ad_account_id)})${phpEq}</div>
        <div class="${low ? 'error-text' : 'muted'}">${escapeHtml(daysText)}${low ? ' - top up soon' : ''}</div>
        <div class="muted">Spent, not yet charged: ${money(a.unbilled_spend, cur)}</div>
        <div class="${failed ? 'error-text' : 'muted'}">Synced ${escapeHtml(synced)}${failed ? ` - ${escapeHtml(a.last_sync_result)}` : ''}</div>
      </div>`;
  }).join('');
}

function renderSummary(accounts) {
  const rows = accounts.map((a) => {
    const cur = a.currency || 'PHP';
    const orig = (v) => (cur !== 'PHP' ? `<div class="muted">${money(v, cur)}</div>` : '');
    return `
      <tr>
        <td>${escapeHtml(storeLabel(a))}</td>
        <td>${Number(a.loads_count || 0)}</td>
        <td>${money(a.loads_php)}${orig(a.loads_original)}</td>
        <td>${money(a.charges_php)}${orig(a.charges_original)}</td>
      </tr>`;
  });
  if (accounts.length > 1) {
    const sum = (k) => accounts.reduce((s, a) => s + Number(a[k] || 0), 0);
    rows.push(`
      <tr>
        <td><strong>Total</strong></td>
        <td><strong>${sum('loads_count')}</strong></td>
        <td><strong>${money(sum('loads_php'))}</strong></td>
        <td><strong>${money(sum('charges_php'))}</strong></td>
      </tr>`);
  }
  document.getElementById('summaryTableBody').innerHTML = rows.length
    ? rows.join('')
    : '<tr><td colspan="4" class="muted">No ad accounts synced yet.</td></tr>';
}

function renderEvents() {
  const events = lastData?.events || [];
  const store = document.getElementById('storeFilter').value;
  const kind = document.getElementById('kindFilter').value;
  const rows = events
    .filter((e) => (!store || e.store === store) && (!kind || e.kind === kind))
    .map((e) => {
      const cur = e.currency || 'PHP';
      const isLoad = e.kind === 'funding';
      const amountNote = !isLoad && e.vat_inclusive_php !== null ? '<div class="muted">net of VAT</div>' : '';
      const phpNote = cur !== 'PHP' ? `<div class="muted">@ ${Number(e.rate).toFixed(4)}</div>`
        : (!isLoad && e.vat_inclusive_php !== null ? '<div class="muted">incl. 12% VAT</div>' : '');
      const phpValue = !isLoad && e.vat_inclusive_php !== null ? e.vat_inclusive_php : e.amount_php;
      return `
        <tr>
          <td>${escapeHtml(e.date)}</td>
          <td>${escapeHtml(e.store || `act_${e.ad_account_id}`)}</td>
          <td>${isLoad ? '<strong>Load</strong>' : 'Charge'}</td>
          <td>${money(e.amount_original, cur)}${amountNote}</td>
          <td>${money(phpValue)}${phpNote}</td>
          <td>${escapeHtml(isLoad ? (e.method || '') : (e.transaction_id || ''))}</td>
          <td>${isLoad ? escapeHtml(e.expense_receipt_no || '') : ''}</td>
        </tr>`;
    });
  document.getElementById('eventTableBody').innerHTML = rows.length
    ? rows.join('')
    : '<tr><td colspan="7" class="muted">No loads or charges in this range.</td></tr>';
}

function fillStoreFilter(accounts) {
  const select = document.getElementById('storeFilter');
  const current = select.value;
  const stores = [...new Set(accounts.map((a) => a.store).filter(Boolean))].sort();
  select.innerHTML = '<option value="">All</option>' +
    stores.map((s) => `<option value="${escapeHtml(s)}">${escapeHtml(s)}</option>`).join('');
  if (stores.includes(current)) select.value = current;
}

async function loadPage() {
  const errorBox = document.getElementById('loadError');
  errorBox.classList.add('hidden');
  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_get_meta_ads', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_from: document.getElementById('fromInput').value,
    p_to: document.getElementById('toInput').value
  });

  if (thisGeneration !== loadGeneration) return;
  if (error) {
    errorBox.textContent = error.message;
    errorBox.classList.remove('hidden');
    return;
  }
  lastData = data || {};
  const accounts = lastData.accounts || [];
  renderCards(accounts);
  renderSummary(accounts);
  fillStoreFilter(accounts);
  renderEvents();
}

// Runs the same sync as the 7:00 cron (last 3 days, never double-logs) so the balance is current.
async function refreshFromMeta() {
  const btn = document.getElementById('refreshBtn');
  const note = document.getElementById('refreshNote');
  btn.disabled = true;
  btn.textContent = 'Refreshing...';
  note.classList.add('hidden');

  const { data, error } = await supabaseClient.functions.invoke('meta-ads-sync', { body: {} });

  btn.disabled = false;
  btn.textContent = 'Refresh from Meta';
  const results = data?.accounts || [];
  const failed = results.filter((r) => r.error);
  const newLoads = results.reduce((s, r) => s + Number(r.fundings_logged || 0), 0);
  note.textContent = error && !results.length
    ? `Refresh failed: ${error.message}`
    : `Refreshed. ${newLoads} new load${newLoads === 1 ? '' : 's'} logged.` +
      (failed.length ? ` Failed: ${failed.map((r) => `${r.warehouse || r.ad_account} (${r.error})`).join('; ')}` : '');
  note.className = failed.length || (error && !results.length) ? 'error-text' : 'muted';
  await loadPage();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Meta Ads');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Meta Ads.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  setRange('month');
  document.querySelectorAll('[data-range]').forEach((btn) => {
    btn.addEventListener('click', () => { setRange(btn.getAttribute('data-range')); loadPage(); });
  });
  document.getElementById('fromInput').addEventListener('change', loadPage);
  document.getElementById('toInput').addEventListener('change', loadPage);
  document.getElementById('storeFilter').addEventListener('change', renderEvents);
  document.getElementById('kindFilter').addEventListener('change', renderEvents);
  document.getElementById('refreshBtn').addEventListener('click', refreshFromMeta);
  await loadPage();
})();
