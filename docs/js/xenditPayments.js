// Xendit Payments page (super users only) - the log of online payments made through pay.html, with
// Retry for a paid invoice that couldn't be added to its order, the Xendit settings, and a pay-link
// maker. Table + RPCs: sql/supabase_xendit_payments.sql.
let currentSession = null;
let searchTimer = null;
let savedEnabled = false; // as last loaded - the confirm only asks when switching it ON
let savedLiveMode = false; // as last loaded - the mode only saves, and confirms, when it changes

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function peso(value) {
  return value == null ? '-' : '₱' + Number(value).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function when(value) {
  return value ? new Date(value).toLocaleString() : '<span class="muted">-</span>';
}

function authArgs() {
  return { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
}

function payLinkFor(orderRef) {
  return new URL(`pay.html?order=${encodeURIComponent(orderRef)}`, window.location.href).href;
}

// POS walk-in payments (sql/supabase_xendit_pos_walkin.sql) have no pay link or receipt page of their own -
// the POS prints the receipt. Paid with no receipt no. = the sale wasn't finished at the counter.
function orderCell(r) {
  if (r.source !== 'POS') {
    return `<a href="${esc(payLinkFor(r.order_ref))}" target="_blank" rel="noopener">${esc(r.order_ref)}</a>${r.online_order_id && r.online_order_id !== r.order_ref ? `<div class="muted" style="font-size:12px;">#${esc(r.online_order_id)}</div>` : ''}`;
  }
  const detail = [r.walkin_order_id, r.pos_receipt_no, r.pos_cashier].filter(Boolean).join(' · ');
  return `${esc(r.walkin_order_id || r.order_ref)}<div class="muted" style="font-size:12px;">POS${detail ? ' · ' + esc(detail) : ''}</div>`
    + (r.status === 'Paid' && !r.pos_receipt_no ? '<div class="error-text" style="font-size:12px;">Paid, but no sale linked - check with the cashier</div>' : '');
}

function applyCell(r) {
  if (r.status !== 'Paid') return '<span class="muted">-</span>';
  const color = r.apply_status === 'Applied' ? '#15803d' : r.apply_status === 'Failed' ? '#b91c1c' : '#b45309';
  let html = `<strong style="color:${color};">${esc(r.apply_status)}</strong>`;
  if (r.applied_in) html += `<div class="muted" style="font-size:12px;">${esc(r.applied_in)}${r.applied_amount != null ? ' - ' + peso(r.applied_amount) : ''}</div>`;
  if (r.apply_error) html += `<div class="error-text" style="font-size:12px;">${esc(r.apply_error)}</div>`;
  // "Payment received" Messenger message (sql/supabase_xendit_payment_receipt_message.sql).
  if (r.receipt_message_status) {
    const failed = r.receipt_message_status.startsWith('Failed');
    html += `<div class="${failed ? 'error-text' : 'muted'}" style="font-size:12px;">Customer message: ${esc(r.receipt_message_status)}</div>`;
  }
  return html;
}

function renderRows(rows) {
  const tbody = document.getElementById('xenditTableBody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="10" class="muted">No online payments yet.</td></tr>';
    return;
  }
  tbody.innerHTML = rows.map((r) => {
    const status = r.status === 'Failed' && r.create_error
      ? `Failed<div class="error-text" style="font-size:12px;">${esc(r.create_error)}</div>`
      : r.status === 'Pending' && r.invoice_url
        ? `<a href="${esc(r.invoice_url)}" target="_blank" rel="noopener">Pending</a><div class="muted" style="font-size:12px;">expires ${new Date(r.expires_at).toLocaleString()}</div>`
        : esc(r.status);
    return `
      <tr>
        <td>${when(r.created_at)}</td>
        <td>${orderCell(r)}</td>
        <td>${esc(r.purpose)}</td>
        <td>${peso(r.amount)}</td>
        <td>${r.is_test ? '<strong style="color:#b45309;">TEST</strong>' : 'Live'}</td>
        <td>${status}</td>
        <td>${esc([r.payment_channel, r.payment_method].filter(Boolean).join(' / ')) || '<span class="muted">-</span>'}</td>
        <td>${r.paid_at ? `${peso(r.paid_amount)}${Number(r.card_fee) > 0 ? `<div class="muted" style="font-size:12px;">+ ${peso(r.card_fee)} card fee</div>` : ''}<div class="muted" style="font-size:12px;">${new Date(r.paid_at).toLocaleString()}</div>${r.source === 'POS' ? `<span class="muted" style="font-size:12px;">${esc(r.receipt_no || '')}</span>` : `<a href="payment-receipt.html?id=${encodeURIComponent(r.payment_id)}" target="_blank" rel="noopener" style="font-size:12px;">🧾 ${esc(r.receipt_no || 'Receipt')}</a>`}` : '<span class="muted">-</span>'}</td>
        <td>${applyCell(r)}</td>
        <td>${r.status === 'Paid' && r.apply_status === 'Failed' ? `<button class="btn btn-secondary btn-sm" data-retry="${esc(r.payment_id)}" type="button">Retry</button>` : ''}</td>
      </tr>`;
  }).join('');

  tbody.querySelectorAll('button[data-retry]').forEach((btn) => {
    btn.addEventListener('click', () => retryPayment(btn));
  });
}

async function loadPayments() {
  const tbody = document.getElementById('xenditTableBody');
  const { data, error } = await supabaseClient.rpc('admin_list_xendit_payments', {
    ...authArgs(),
    p_search: document.getElementById('searchBox').value,
    p_limit: 200
  });
  if (error) {
    tbody.innerHTML = `<tr><td colspan="10" class="error-text">${esc(error.message)}</td></tr>`;
    return;
  }
  renderRows(data);
}

async function retryPayment(btn) {
  btn.disabled = true;
  btn.textContent = 'Retrying...';
  const { data, error } = await supabaseClient.rpc('admin_retry_xendit_payment', { ...authArgs(), p_payment_id: btn.dataset.retry });
  if (error) {
    window.alert(`Retry failed: ${error.message}`);
  } else {
    const r = (data && data[0]) || {};
    if (r.apply_status !== 'Applied') window.alert(`Still not added: ${r.apply_error || r.apply_status}`);
  }
  await loadPayments();
}

async function loadSettings() {
  const { data, error } = await supabaseClient.rpc('admin_get_xendit_settings', authArgs());
  if (error) {
    document.getElementById('settingsUpdated').textContent = `Could not load settings: ${error.message}`;
    return;
  }
  const s = (data && data[0]) || {};
  savedEnabled = !!s.enabled;
  document.getElementById('xenditEnabled').checked = savedEnabled;
  document.getElementById('showOnOrderNow').checked = !!s.show_on_order_now;
  document.getElementById('xenditPosEnabled').checked = !!s.pos_enabled;
  document.getElementById('xenditCardFeePercent').value = s.card_fee_percent ?? 0;
  savedLiveMode = !!s.live_mode;
  document.getElementById('xenditLiveMode').checked = savedLiveMode;
  renderLiveModeHint();
  renderEnabledHint();
  document.getElementById('settingsUpdated').textContent = s.updated_at
    ? `Last changed by ${s.updated_by} on ${new Date(s.updated_at).toLocaleString()}` : '';
}

function renderEnabledHint() {
  const on = document.getElementById('xenditEnabled').checked;
  document.getElementById('enabledHint').textContent = on
    ? 'ON - customers can pay on pay.html.'
    : 'OFF - customers see "Online payment isn\'t available yet". You can still test pay links while logged in here as a super user.';
}

function renderLiveModeHint() {
  const on = document.getElementById('xenditLiveMode').checked;
  document.getElementById('liveModeHint').textContent = on
    ? 'LIVE - new payments use the live key and take real money.'
    : 'TEST - new payments use the test key (no real money). Only a logged-in super user can pay on pay.html, whatever the switch below says.';
}

async function saveSettings() {
  const enabled = document.getElementById('xenditEnabled').checked;
  const liveMode = document.getElementById('xenditLiveMode').checked;
  if (liveMode !== savedLiveMode) {
    const question = liveMode
      ? 'Switch to LIVE mode? New payments will take real money.'
      : 'Switch to TEST mode? Customers won\'t be able to pay online, and the POS switch will turn off.';
    if (!window.confirm(question)) return;
  }
  if (enabled && !savedEnabled && !window.confirm('Turn on Xendit online payment for customers?')) return;
  if (liveMode !== savedLiveMode) {
    const { error: modeError } = await supabaseClient.rpc('admin_set_xendit_live_mode', { ...authArgs(), p_live_mode: liveMode });
    if (modeError) {
      window.alert(`Failed to save the mode: ${modeError.message}`);
      return;
    }
    if (!liveMode) document.getElementById('xenditPosEnabled').checked = false;
  }
  const { error } = await supabaseClient.rpc('admin_update_xendit_settings', {
    ...authArgs(),
    p_enabled: enabled,
    p_show_on_order_now: document.getElementById('showOnOrderNow').checked
  });
  if (error) {
    window.alert(`Failed to save: ${error.message}`);
    return;
  }
  const { error: posError } = await supabaseClient.rpc('admin_set_xendit_pos_enabled', {
    ...authArgs(),
    p_pos_enabled: document.getElementById('xenditPosEnabled').checked
  });
  if (posError) {
    window.alert(`Failed to save the POS setting: ${posError.message}`);
    return;
  }
  const { error: feeError } = await supabaseClient.rpc('admin_set_xendit_card_fee', {
    ...authArgs(),
    p_percent: Number(document.getElementById('xenditCardFeePercent').value)
  });
  if (feeError) {
    window.alert(`Failed to save the card fee: ${feeError.message}`);
    return;
  }
  const saved = document.getElementById('settingsSaved');
  saved.classList.remove('hidden');
  setTimeout(() => saved.classList.add('hidden'), 1500);
  await loadSettings();
}

async function copyPayLink() {
  const order = document.getElementById('payLinkOrder').value.trim().toUpperCase();
  const result = document.getElementById('payLinkResult');
  if (!order) return;
  const link = payLinkFor(order);
  document.getElementById('payLinkOpen').href = link;
  try {
    await navigator.clipboard.writeText(link);
    result.textContent = `Copied: ${link}`;
  } catch {
    result.textContent = link;
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Xendit Payments');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }
  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Xendit Payments.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('saveSettingsBtn').addEventListener('click', saveSettings);
  document.getElementById('xenditEnabled').addEventListener('change', renderEnabledHint);
  document.getElementById('xenditLiveMode').addEventListener('change', renderLiveModeHint);
  document.getElementById('refreshBtn').addEventListener('click', loadPayments);
  document.getElementById('payLinkBtn').addEventListener('click', copyPayLink);
  document.getElementById('searchBox').addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(loadPayments, 300);
  });
  await Promise.all([loadSettings(), loadPayments()]);
})();
