// AI Spend page (super users only) - Claude receipts (auto-logged from Gmail), usage by feature /
// model / day, and an estimated remaining API credit balance. See sql/supabase_claude_spend_tracking.sql.
let currentSession = null;
let loadGeneration = 0;

const SOURCE_LABELS = {
  'facebook-messenger-webhook': 'Messenger bot (Alice)',
  'chatbot-web-reply': 'Website chat (Alice)',
  'telegram-alice-webhook': 'Telegram (Alice)',
  'portal-chat-alice-reply': 'Portal chat (Alice)',
  'chatbot-followup-dispatcher': 'Follow-up messages',
  'chatbot-suggest-reply': 'Suggested replies',
  'chatbot-sandbox-reply': 'AI Bot Sandbox',
  'facebook-page-post': 'Facebook page posts',
  'tender-deposit-read-slip': 'Deposit slip reading',
  'video-ad-generate': 'Video ads'
};

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

function usd(value, digits = 2) {
  if (value === null || value === undefined || value === '') return '-';
  return '$' + Number(value).toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

function php(value) {
  if (value === null || value === undefined || value === '') return '-';
  return '₱' + Number(value).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function isoDate(d) {
  // Local (Manila) calendar date, not UTC.
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

function rowsOrEmpty(tbodyId, rows, colspan, emptyText) {
  document.getElementById(tbodyId).innerHTML = rows.length
    ? rows.join('')
    : `<tr><td colspan="${colspan}" class="muted">${emptyText}</td></tr>`;
}

function render(data) {
  const totals = data.totals || {};
  const balance = data.balance || {};
  const receipts = data.receipts || [];
  const latestRate = receipts.find((r) => r.exchange_rate)?.exchange_rate || null;

  // Balance
  if (balance.estimated_usd === null || balance.estimated_usd === undefined) {
    document.getElementById('balanceValue').textContent = 'Not set';
    document.getElementById('balanceNote').textContent = 'Enter your Console balance below to start the estimate.';
  } else {
    document.getElementById('balanceValue').textContent = usd(balance.estimated_usd);
    const avg = Number(balance.avg_daily_usd_7d || 0);
    const daysLeft = avg > 0 ? Math.floor(Number(balance.estimated_usd) / avg) : null;
    document.getElementById('balanceNote').textContent =
      `${usd(balance.anchor_usd)} set ${new Date(balance.anchor_at).toLocaleString()}` +
      ` + ${usd(balance.topups_since_usd)} top-ups - ${usd(balance.usage_since_usd)} used` +
      (daysLeft !== null ? ` · about ${daysLeft} day${daysLeft === 1 ? '' : 's'} left at the current pace` : '');
  }

  // Usage in range
  document.getElementById('usageValue').textContent = usd(totals.cost_usd);
  document.getElementById('usageNote').textContent =
    `${Number(totals.requests || 0).toLocaleString()} AI calls` +
    (latestRate ? ` · ≈ ${php(Number(totals.cost_usd || 0) * Number(latestRate))}` : '');

  // Paid in range
  const paidUsd = receipts.reduce((s, r) => s + Number(r.total_usd || 0), 0);
  const paidPhp = receipts.reduce((s, r) => s + Number(r.amount_php || 0), 0);
  document.getElementById('paidValue').textContent = php(paidPhp);
  document.getElementById('paidNote').textContent = `${usd(paidUsd)} · ${receipts.length} receipt${receipts.length === 1 ? '' : 's'}`;

  // 7-day average
  document.getElementById('avgValue').textContent = usd(balance.avg_daily_usd_7d);
  document.getElementById('avgNote').textContent = latestRate ? `≈ ${php(Number(balance.avg_daily_usd_7d || 0) * Number(latestRate))} per day` : '';

  // Receipts
  rowsOrEmpty('receiptTableBody', receipts.map((r) => `
    <tr>
      <td>${escapeHtml(r.date_paid)}</td>
      <td>${r.kind === 'api_credits' ? 'API credits' : 'Subscription'}</td>
      <td>${escapeHtml(r.receipt_number)}</td>
      <td>${usd(r.subtotal_usd)}${r.item ? `<div class="muted">${escapeHtml(r.item)}</div>` : ''}</td>
      <td>${usd(r.tax_usd)}</td>
      <td>${usd(r.total_usd)}</td>
      <td>${Number(r.exchange_rate).toFixed(4)}</td>
      <td>${php(r.amount_php)}</td>
      <td>${escapeHtml(r.expense_receipt_no || '(deleted)')}</td>
      <td><button class="btn btn-secondary btn-sm" type="button" data-fix-receipt="${escapeHtml(r.receipt_number)}" data-current-php="${r.amount_php}">Fix PHP</button></td>
    </tr>`), 10, 'No Anthropic receipts in this range.');

  document.querySelectorAll('[data-fix-receipt]').forEach((btn) => {
    btn.addEventListener('click', () => fixReceiptPhp(btn.getAttribute('data-fix-receipt'), btn.getAttribute('data-current-php')));
  });

  // By feature
  const totalCost = Number(totals.cost_usd || 0);
  rowsOrEmpty('sourceTableBody', (data.by_source || []).map((s) => `
    <tr>
      <td>${escapeHtml(SOURCE_LABELS[s.source] || s.source)}</td>
      <td>${Number(s.requests).toLocaleString()}</td>
      <td>${usd(s.cost_usd, 4)}</td>
      <td>${totalCost > 0 ? Math.round((Number(s.cost_usd) / totalCost) * 100) + '%' : '-'}</td>
    </tr>`), 4, 'No AI usage recorded in this range yet.');

  // By model
  rowsOrEmpty('modelTableBody', (data.by_model || []).map((m) => `
    <tr>
      <td>${escapeHtml(m.model || '(unknown)')}${m.priced ? '' : ' <span class="error-text">(no price set - counted as $0)</span>'}</td>
      <td>${Number(m.requests).toLocaleString()}</td>
      <td>${usd(m.cost_usd, 4)}</td>
    </tr>`), 3, 'No AI usage recorded in this range yet.');

  // By day (newest first)
  rowsOrEmpty('dayTableBody', [...(data.by_day || [])].reverse().map((d) => `
    <tr>
      <td>${escapeHtml(d.day)}</td>
      <td>${Number(d.requests).toLocaleString()}</td>
      <td>${usd(d.cost_usd, 4)}</td>
    </tr>`), 3, 'No AI usage recorded in this range yet.');

  // Pricing
  rowsOrEmpty('pricingTableBody', (data.pricing || []).map((p) => `
    <tr>
      <td>${escapeHtml(p.model)}</td>
      <td>${usd(p.input)}</td>
      <td>${usd(p.output)}</td>
      <td>${usd(p.cache_write, 3)}</td>
      <td>${usd(p.cache_read)}</td>
      <td><button class="btn btn-secondary btn-sm" type="button" data-edit-model="${escapeHtml(p.model)}">Edit</button></td>
    </tr>`), 6, 'No prices set.');

  document.querySelectorAll('[data-edit-model]').forEach((btn) => {
    const model = btn.getAttribute('data-edit-model');
    btn.addEventListener('click', () => editPricing((data.pricing || []).find((p) => p.model === model)));
  });
}

async function loadSpend() {
  const errorBox = document.getElementById('loadError');
  errorBox.classList.add('hidden');
  const thisGeneration = ++loadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_get_ai_spend', {
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
  render(data || {});
}

async function fixReceiptPhp(receiptNumber, currentPhp) {
  const input = window.prompt(`Peso amount your bank/card actually charged for Anthropic receipt ${receiptNumber}:`, currentPhp || '');
  if (input === null) return;
  const amount = Number(String(input).replace(/[₱,\s]/g, ''));
  if (!(amount > 0)) {
    window.alert('Enter a peso amount greater than zero.');
    return;
  }

  const { error } = await supabaseClient.rpc('admin_set_claude_receipt_php', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_receipt_number: receiptNumber,
    p_amount_php: amount
  });
  if (error) {
    window.alert('Update failed: ' + error.message);
    return;
  }
  await loadSpend();
}

async function editPricing(row) {
  if (!row) return;
  const ask = (label, value) => window.prompt(`${row.model} - ${label} (USD per million tokens):`, value);
  const input = ask('Input', row.input); if (input === null) return;
  const output = ask('Output', row.output); if (output === null) return;
  const cacheWrite = ask('Cache write', row.cache_write); if (cacheWrite === null) return;
  const cacheRead = ask('Cache read', row.cache_read); if (cacheRead === null) return;

  const { error } = await supabaseClient.rpc('admin_upsert_ai_model_pricing', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_model: row.model,
    p_input: Number(input),
    p_output: Number(output),
    p_cache_write: Number(cacheWrite),
    p_cache_read: Number(cacheRead)
  });
  if (error) {
    window.alert('Update failed: ' + error.message);
    return;
  }
  await loadSpend();
}

async function submitBalance(e) {
  e.preventDefault();
  const errorBox = document.getElementById('balanceError');
  errorBox.classList.add('hidden');
  const value = Number(document.getElementById('balanceInput').value);
  if (!(value >= 0)) {
    errorBox.textContent = 'Enter the balance shown in the Claude Console.';
    errorBox.classList.remove('hidden');
    return;
  }

  const btn = document.getElementById('balanceBtn');
  btn.disabled = true;
  const { error } = await supabaseClient.rpc('admin_set_ai_credit_balance', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_balance_usd: value
  });
  btn.disabled = false;

  if (error) {
    errorBox.textContent = error.message;
    errorBox.classList.remove('hidden');
    return;
  }
  document.getElementById('balanceForm').reset();
  await loadSpend();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('AI Spend');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view AI Spend.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  setRange('month');
  document.querySelectorAll('[data-range]').forEach((btn) => {
    btn.addEventListener('click', () => { setRange(btn.getAttribute('data-range')); loadSpend(); });
  });
  document.getElementById('fromInput').addEventListener('change', loadSpend);
  document.getElementById('toInput').addEventListener('change', loadSpend);
  document.getElementById('balanceForm').addEventListener('submit', submitBalance);
  await loadSpend();
})();
