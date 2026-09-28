// Payment Methods setup page (super users only) - names Pancake's bank-account IDs so the Online
// Order card's Paid Via shows "GCash" instead of a GUID. Table + RPCs:
// sql/supabase_payment_methods_master.sql.
let currentSession = null;
const METHOD_TYPES = ['Cash', 'Bank', 'E-Wallet', 'Card', 'Other'];

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function renderPaymentMethodRows(rows) {
  const tbody = document.getElementById('paymentMethodTableBody');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No payment methods yet - click Sync from Pancake.</td></tr>';
    return;
  }

  tbody.innerHTML = rows.map((r) => {
    const unnamed = !r.name && !r.pancake_name;
    return `
      <tr data-code="${esc(r.code)}">
        <td><input type="text" class="pm-name" value="${esc(r.name)}" placeholder="${esc(r.pancake_name || 'e.g. GCash')}" style="width:200px;${unnamed ? 'border-color:#d97706;' : ''}" /></td>
        <td><select class="pm-type">${METHOD_TYPES.map((t) => `<option ${t === r.method_type ? 'selected' : ''}>${t}</option>`).join('')}</select></td>
        <td><input type="checkbox" class="pm-active" ${r.is_active ? 'checked' : ''} /></td>
        <td><code title="${esc(r.code)}">${esc(r.code)}</code></td>
        <td>${r.pancake_name ? esc(r.pancake_name) : '<span class="muted">-</span>'}</td>
        <td>${r.last_seen_at_utc ? new Date(r.last_seen_at_utc).toLocaleString() : '<span class="muted">-</span>'}</td>
        <td>
          <button class="btn btn-secondary btn-sm" data-action="save" type="button">Save</button>
          <span class="pm-saved muted hidden">Saved</span>
        </td>
      </tr>`;
  }).join('');

  tbody.querySelectorAll('button[data-action="save"]').forEach((btn) => {
    btn.addEventListener('click', () => savePaymentMethod(btn.closest('tr')));
  });
  // Active auto-saves on toggle, same as Warehouse Setup's flags.
  tbody.querySelectorAll('.pm-active').forEach((cb) => {
    cb.addEventListener('change', () => savePaymentMethod(cb.closest('tr')));
  });
}

async function savePaymentMethod(row) {
  const { error } = await supabaseClient.rpc('admin_update_payment_method', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_code: row.dataset.code,
    p_name: row.querySelector('.pm-name').value,
    p_method_type: row.querySelector('.pm-type').value,
    p_is_active: row.querySelector('.pm-active').checked
  });
  if (error) {
    window.alert(`Failed to save: ${error.message}`);
    await loadPaymentMethods();
    return;
  }
  const saved = row.querySelector('.pm-saved');
  saved.classList.remove('hidden');
  setTimeout(() => saved.classList.add('hidden'), 1500);
}

async function loadPaymentMethods() {
  const tbody = document.getElementById('paymentMethodTableBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';
  const { data, error } = await supabaseClient.rpc('admin_list_payment_methods', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${esc(error.message)}</td></tr>`;
    return;
  }
  renderPaymentMethodRows(data);
}

// One Pancake call per request (admin_sync_payment_methods_step, supabase_payment_methods_sync_steps.sql)
// so no single request hits the statement timeout: step 1 reads Pancake's /bank_payments list with
// the names, steps 2-4 collect any other IDs used on the latest 300 orders.
async function syncPaymentMethods() {
  const btn = document.getElementById('syncPaymentMethodsBtn');
  const result = document.getElementById('syncResult');
  btn.disabled = true;
  result.classList.remove('hidden');
  let named = 0;
  let seen = 0;
  let source = null;
  const failures = [];
  const steps = [1, 2, 3, 4];

  for (const step of steps) {
    btn.textContent = `Syncing ${step}/${steps.length}...`;
    const { data, error } = await supabaseClient.rpc('admin_sync_payment_methods_step', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_step: step
    });
    if (error) {
      failures.push(`step ${step}: ${error.message}`);
      continue;
    }
    const r = (data && data[0]) || {};
    named += r.named_from_pancake || 0;
    seen += r.seen_on_orders || 0;
    source = source || r.pancake_source;
  }

  btn.disabled = false;
  btn.textContent = 'Sync from Pancake';
  result.textContent = `Sync done: ${named ? `${named} names from Pancake (${source})` : 'Pancake did not return any names'}, `
    + `${seen} payments checked on recent orders.${failures.length ? ` Skipped - ${failures.join('; ')}` : ''}`;
  await loadPaymentMethods();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Payment Methods');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }
  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Payment Methods.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('syncPaymentMethodsBtn').addEventListener('click', syncPaymentMethods);
  await loadPaymentMethods();
})();
