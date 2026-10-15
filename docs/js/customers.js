// Customers page (super users only, same tier as GMA Conversations/AI Bot Sandbox - this data
// carries Messenger PII) - browses public."ChatbotConversations" as the AI bot's CRM record: one
// row per Facebook PSID. admin_list_gma_customers (sql/supabase_gma_customers_enriched.sql) fills
// a contact the bot never captured from their latest order, then their Pancake customer, and says
// which (phone_source / address_source). Business Central list layout (css/bc-list.css), same as
// Purchase Orders: a row click selects it into the FactBox, the name / a double-click opens the
// Customer Card (see below).
let currentSession = null;
let customerSearchDebounceHandle = null;
let loadGeneration = 0;
let currentPage = 1;
let currentPageSize = 50;
let currentFilter = 'all';
let currentRows = [];
let selectedPsid = null;

const NAME_SOURCE_LABEL = {
  CustomerProvided: 'Typed by customer',
  FacebookProfile: 'Facebook profile',
  Staff: 'Entered by staff'
};

// Same Pages / moods as js/gmaConversations.js (PAGE_LABELS / MOODS).
const PAGE_CHIPS = {
  '1272627559275402': { label: 'GMA', cls: 'cust-chip-page-gma' },
  '195716644410829': { label: 'RS Pet Stop', cls: 'cust-chip-page-rs' },
  website: { label: 'Website', cls: 'cust-chip-page-web' }
};

const MOODS = {
  angry: { emoji: '😠', label: 'Angry' },
  impatient: { emoji: '⏰', label: 'Impatient' },
  sad: { emoji: '😟', label: 'Sad' },
  unsure: { emoji: '🤔', label: 'Unsure' },
  neutral: { emoji: '😐', label: 'Neutral' },
  happy: { emoji: '😊', label: 'Happy' },
  excited: { emoji: '🤩', label: 'Excited' },
  ready_to_buy: { emoji: '🛒', label: 'Ready to buy' }
};

const SOURCE_TITLE = {
  Chat: 'Told to the bot in chat',
  Order: 'From their latest order',
  Pancake: 'From their Pancake customer record'
};

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function money(n) {
  return Number(n || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function initials(name) {
  const words = String(name || '?').trim().split(/\s+/).filter(Boolean);
  return ((words[0]?.[0] || '?') + (words.length > 1 ? words[words.length - 1][0] : '')).toUpperCase();
}

function avatarColor(key) {
  let h = 0;
  for (const ch of String(key)) h = (h * 31 + ch.charCodeAt(0)) % 360;
  return `hsl(${h}, 55%, 42%)`;
}

function dateTime(iso) {
  return iso ? new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
}

function shortDate(iso) {
  return iso ? new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }) : '';
}

function sourceTagHtml(source) {
  if (!source) return '';
  return `<span class="cust-src${source === 'Chat' ? ' cust-src-chat' : ''}" title="${escapeHtml(SOURCE_TITLE[source] || source)}">${escapeHtml(source)}</span>`;
}

function pageChipHtml(pageId) {
  const page = PAGE_CHIPS[pageId];
  return page ? `<span class="cust-chip ${page.cls}">${escapeHtml(page.label)}</span>` : '';
}

function tagChipsHtml(tags) {
  return (Array.isArray(tags) ? tags : [])
    .map((t) => `<span class="cust-chip" style="background:${escapeHtml(t.color || '#64748b')}">${escapeHtml(t.name)}</span>`)
    .join('');
}

function chatUrl(c) {
  return `gma-conversations.html?psid=${encodeURIComponent(c.psid)}&name=${encodeURIComponent(c.customer_name || '')}`;
}

// ---------------------------------------------------------------------------
// Profile picture for the FactBox - same chatbot-profile-pics Edge Function as GMA Conversations;
// nothing is saved, and if Facebook refuses (needs Meta access) the initials stay.
const profilePics = new Map();

async function loadProfilePic(c) {
  if (!c.psid || c.page_id === 'website' || profilePics.has(c.psid)) return applyProfilePic();
  profilePics.set(c.psid, null);
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-profile-pics`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({ admin_username: currentSession.username, admin_password: currentSession.password, psids: [c.psid] })
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
    profilePics.set(c.psid, result.pictures?.[c.psid] || null);
  } catch (err) {
    console.warn('Profile picture unavailable:', err instanceof Error ? err.message : err);
  }
  applyProfilePic();
}

// List FactBox and Customer Card avatars.
function applyProfilePic() {
  document.querySelectorAll('.cust-avatar[data-psid]').forEach((el) => {
    const url = profilePics.get(el.dataset.psid);
    if (!url || el.querySelector('img')) return;
    el.insertAdjacentHTML('afterbegin', `<img src="${escapeHtml(url)}" alt="" referrerpolicy="no-referrer" onerror="this.remove()">`);
  });
}

// ---------------------------------------------------------------------------

function customerRowsHtml(customers) {
  return customers
    .map((c) => {
      const mood = MOODS[c.customer_mood];
      const count = Number(c.order_count || 0);
      const name = c.customer_name
        ? escapeHtml(c.customer_name)
        : '<span class="muted">(no name)</span>';
      return `
      <tr data-psid="${escapeHtml(c.psid)}"${c.psid === selectedPsid ? ' class="selected"' : ''}>
        <td class="cell-text"><button type="button" class="bc-link" data-open-card>${name}</button>${mood ? ` <span title="${escapeHtml(mood.label)} (AI guess)">${mood.emoji}</span>` : ''}</td>
        <td>${pageChipHtml(c.page_id)}</td>
        <td>${escapeHtml(c.customer_phone || '')}</td>
        <td>${sourceTagHtml(c.phone_source)}</td>
        <td class="cell-text">${escapeHtml(c.customer_email || '')}</td>
        <td class="cell-text" title="${escapeHtml(c.customer_address || '')}">${escapeHtml(c.customer_address || '')}</td>
        <td>${tagChipsHtml(c.tags)}</td>
        <td class="num">${count || ''}</td>
        <td class="num">${count ? money(c.order_value) : ''}</td>
        <td>${escapeHtml(shortDate(c.last_order_at_utc))}</td>
        <td>${escapeHtml(dateTime(c.last_message_at_utc))}</td>
        <td>${escapeHtml(shortDate(c.created_at_utc))}</td>
      </tr>`;
    })
    .join('');
}

function factsHtml(pairs) {
  return `<dl class="bc-facts">${pairs.map(([k, v]) => `<dt>${escapeHtml(k)}</dt><dd>${v || '<span class="muted">-</span>'}</dd>`).join('')}</dl>`;
}

function renderFactBox() {
  const body = document.getElementById('customerFactBody');
  const c = currentRows.find((r) => r.psid === selectedPsid);
  document.getElementById('openChatBtn').disabled = !c || c.page_id === 'website';
  document.getElementById('copyPhoneBtn').disabled = !c?.customer_phone;
  if (!c) {
    body.innerHTML = '<p class="bc-fact-empty">Select a row to see the customer.</p>';
    return;
  }
  const mood = MOODS[c.customer_mood];
  const name = c.customer_name || '(no name)';
  body.innerHTML = `
    <div class="cust-fact-head">
      <span class="cust-avatar" data-psid="${escapeHtml(c.psid)}" style="background:${avatarColor(c.customer_name || c.psid)}">${escapeHtml(initials(name))}</span>
      <div>
        <div class="cust-fact-name">${escapeHtml(name)}</div>
        <div class="cust-fact-sub">${pageChipHtml(c.page_id)}${c.is_paused ? '<span class="cust-chip cust-chip-paused" title="Staff are handling this chat">Bot paused</span>' : ''}</div>
      </div>
    </div>
    ${factsHtml([
      ['Name from', escapeHtml(NAME_SOURCE_LABEL[c.customer_name_source] || c.customer_name_source || '')],
      ['Contact No.', c.customer_phone ? `${escapeHtml(c.customer_phone)} ${sourceTagHtml(c.phone_source)}` : ''],
      ['Email', escapeHtml(c.customer_email || '')],
      ['Address', c.customer_address ? `${escapeHtml(c.customer_address)} ${sourceTagHtml(c.address_source)}` : ''],
      ['Mood', mood ? `${mood.emoji} ${escapeHtml(mood.label)}${c.customer_mood_reason ? ` - ${escapeHtml(c.customer_mood_reason)}` : ''}` : ''],
      ['Tags', tagChipsHtml(c.tags)],
      ['Orders', Number(c.order_count || 0) ? `${c.order_count} · ₱${money(c.order_value)}` : ''],
      ['Last Order', escapeHtml(dateTime(c.last_order_at_utc))],
      ['Pancake', Number(c.pancake_order_count || 0) ? `${c.pancake_order_count} orders · ₱${money(c.pancake_purchased)}` : ''],
      ['Customer Wrote', escapeHtml(dateTime(c.last_customer_message_at_utc))],
      ['First Seen', escapeHtml(dateTime(c.created_at_utc))],
      ['PSID', `<code>${escapeHtml(c.psid)}</code>`]
    ])}`;
  loadProfilePic(c);
}

// Tab counts + Summary FactBox - over the search, not the tab, so they come from any returned row.
function renderStats(row) {
  if (!row) return;
  const total = Number(row.stat_total || 0);
  const withPhone = Number(row.stat_with_phone || 0);
  const ordered = Number(row.stat_ordered || 0);
  const counts = { all: total, has_phone: withPhone, no_phone: total - withPhone, ordered };
  document.querySelectorAll('#customerFilters [data-count]').forEach((el) => {
    el.textContent = (counts[el.dataset.count] ?? 0).toLocaleString();
  });
  const pct = (n) => (total > 0 ? ` <span class="muted">(${Math.round((n / total) * 100)}%)</span>` : '');
  document.getElementById('customerSummaryBody').innerHTML = factsHtml([
    ['Customers', total.toLocaleString()],
    ['With Contact No.', `${withPhone.toLocaleString()}${pct(withPhone)}`],
    ['Have Ordered', `${ordered.toLocaleString()}${pct(ordered)}`],
    ['Order Value', `₱${money(row.stat_order_value)}`]
  ]);
}

async function loadCustomers() {
  const myGeneration = ++loadGeneration;
  const tbody = document.getElementById('customerTableBody');
  const search = document.getElementById('customerSearchInput').value.trim();

  const { data, error } = await supabaseClient.rpc('admin_list_gma_customers', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: search || null,
    p_page: currentPage,
    p_page_size: currentPageSize,
    p_filter: currentFilter
  });

  if (myGeneration !== loadGeneration) return;

  if (error) {
    const message = /could not find the function|schema cache/i.test(error.message)
      ? 'The new Customers list isn\'t set up yet - run sql/supabase_gma_customers_enriched.sql.'
      : error.message;
    tbody.innerHTML = `<tr><td colspan="12" class="cell-msg error-text">${escapeHtml(message)}</td></tr>`;
    return;
  }

  currentRows = data || [];
  tbody.innerHTML = currentRows.length === 0
    ? '<tr><td colspan="12" class="cell-msg">No customers found.</td></tr>'
    : customerRowsHtml(currentRows);
  renderStats(currentRows[0]);
  renderFactBox();

  renderPaginationBar(
    document.getElementById('customerPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: currentRows[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadCustomers(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadCustomers(); }
    }
  );
}

function wireCustomerPage() {
  const searchInput = document.getElementById('customerSearchInput');
  searchInput.addEventListener('input', () => {
    currentPage = 1;
    clearTimeout(customerSearchDebounceHandle);
    customerSearchDebounceHandle = setTimeout(loadCustomers, 300);
  });

  document.querySelectorAll('#customerFilters .bc-tab').forEach((btn) => {
    btn.addEventListener('click', () => {
      currentFilter = btn.dataset.filter;
      currentPage = 1;
      document.querySelectorAll('#customerFilters .bc-tab').forEach((b) => b.classList.toggle('active', b === btn));
      loadCustomers();
    });
  });

  const tbody = document.getElementById('customerTableBody');
  tbody.addEventListener('click', (e) => {
    const row = e.target.closest('tr[data-psid]');
    if (!row) return;
    selectedPsid = row.dataset.psid;
    tbody.querySelectorAll('tr.selected').forEach((tr) => tr.classList.remove('selected'));
    row.classList.add('selected');
    renderFactBox();
  });
  // BC: the name (or a double-click) opens the Customer Card.
  tbody.addEventListener('click', (e) => {
    const row = e.target.closest('[data-open-card]') && e.target.closest('tr[data-psid]');
    if (row) openCustomerCard(row.dataset.psid);
  });
  tbody.addEventListener('dblclick', (e) => {
    const row = e.target.closest('tr[data-psid]');
    if (row) openCustomerCard(row.dataset.psid);
  });
  wireCustomerCard();

  document.getElementById('openChatBtn').addEventListener('click', () => {
    const c = currentRows.find((r) => r.psid === selectedPsid);
    if (c) location.href = chatUrl(c);
  });
  document.getElementById('copyPhoneBtn').addEventListener('click', async () => {
    const c = currentRows.find((r) => r.psid === selectedPsid);
    if (!c?.customer_phone) return;
    try {
      await navigator.clipboard.writeText(c.customer_phone);
    } catch {
      window.prompt('Copy the contact no.:', c.customer_phone);
    }
  });
  document.getElementById('refreshBtn').addEventListener('click', loadCustomers);
}

// ---------------------------------------------------------------------------
// Customer Card (BC document, #custCardModal). Name / Contact No. / Address are editable and saved
// to the CRM record the bot also uses (admin_update_gma_customer, sql/supabase_gma_customer_card.sql).
// A contact filled from an order / Pancake is prefilled too, so Save also copies it onto the record.
const CUST_CARD_MAXIMIZED_KEY = 'customer-card-maximized';
let cardCustomer = null;
let cardOrdersGeneration = 0;

const ORDER_STATUS_BADGE = {
  New: 'badge-primary',
  Contacted: 'badge-warning',
  Confirmed: 'badge-purple',
  Completed: 'badge-success',
  Cancelled: 'badge-danger'
};

function readStoredFlag(key, fallback) {
  try {
    const value = localStorage.getItem(key);
    return value === null ? fallback : value === '1';
  } catch (err) {
    return fallback;
  }
}

function writeStoredFlag(key, on) {
  try { localStorage.setItem(key, on ? '1' : '0'); } catch (err) { /* not remembered - fine */ }
}

function applyCardMaximized(maximized) {
  const modal = document.getElementById('custCardModal');
  modal.classList.toggle('modal-maximized', maximized);
  modal.querySelector('.modal-panel').classList.toggle('modal-maximized', maximized);
  const btn = document.getElementById('custCardMaximizeBtn');
  btn.textContent = maximized ? 'Restore' : 'Maximize';
  btn.title = maximized ? 'Restore this card to a window' : 'Maximize this card to fill the window';
}

function setCardValue(id, html) {
  document.getElementById(id).innerHTML = html || '<span class="muted">-</span>';
}

// Contact No. / Address on the card are the defaults (read-only - changed in Contacts & Addresses).
// One shown from an order / Pancake means there's no default yet.
function sourceHintText(source) {
  return source && source !== 'Chat' ? `${SOURCE_TITLE[source]} - no default yet. Use Set Default below.` : '';
}

// The record's own default (not an order / Pancake fallback) - sent back unchanged on Save.
function recordValue(c, field, sourceField) {
  return c[sourceField] === 'Chat' ? (c[field] || '') : '';
}

// Save on the card is for the Name only now.
function cardIsDirty() {
  const c = cardCustomer;
  return !!c && document.getElementById('custCardName').value.trim() !== (c.customer_name || '');
}

function syncCardSummaries() {
  document.getElementById('custCardSaveBtn').disabled = !cardIsDirty();
  document.getElementById('custCardGeneralSummary').textContent = document.getElementById('custCardName').value.trim();
  document.getElementById('custCardCommSummary').textContent = cardCustomer?.customer_phone || '';
}

// ---------------------------------------------------------------------------
// Contacts & Addresses part (ChatbotCustomerContacts, sql/supabase_gma_customer_contacts.sql). One
// row in edit mode at a time: an existing row's id, or 'new-Phone' / 'new-Address' for a new one.
let cardContacts = [];
let contactEditing = null;
let contactsGeneration = 0;

const CONTACT_SOURCE_TITLE = {
  Chat: 'Given in chat / the record',
  Order: 'From an order',
  Pancake: 'From Pancake',
  Staff: 'Entered by staff'
};

async function loadCardContacts(c) {
  const myGeneration = ++contactsGeneration;
  contactEditing = null;
  const body = document.getElementById('custContactsBody');
  body.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';
  const { data, error } = await supabaseClient.rpc('admin_list_gma_customer_contacts', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: c.psid
  });
  if (myGeneration !== contactsGeneration) return;
  if (error) {
    const message = /could not find the function|schema cache/i.test(error.message)
      ? 'Contacts & Addresses isn\'t set up yet - run sql/supabase_gma_customer_contacts.sql.'
      : error.message;
    body.innerHTML = `<tr><td colspan="7" class="error-text">${escapeHtml(message)}</td></tr>`;
    return;
  }
  cardContacts = data || [];
  renderCardContacts();
}

function contactEditRowHtml(kind, row) {
  const value = row ? row.value : '';
  const input = kind === 'Phone'
    ? `<input type="text" data-contact-field="value" maxlength="50" placeholder="09171234567" value="${escapeHtml(value)}">`
    : `<textarea data-contact-field="value" rows="2" maxlength="500" placeholder="House no., street, barangay, city">${escapeHtml(value)}</textarea>`;
  return `
    <tr class="editing" data-contact-edit="${row ? row.id : `new-${kind}`}" data-kind="${kind}">
      <td>${row?.is_default ? '<span class="cust-default-star">★</span>' : ''}</td>
      <td>${kind === 'Phone' ? 'Contact No.' : 'Address'}</td>
      <td class="cust-contact-value">${input}</td>
      <td><input type="text" data-contact-field="label" maxlength="50" placeholder="e.g. Home, Work" value="${escapeHtml(row?.label || '')}"></td>
      <td colspan="2">${row?.is_default ? '<span class="muted">Default</span>' : `<label class="muted"><input type="checkbox" data-contact-field="default"> Make default</label>`}</td>
      <td class="cust-contact-actions">
        <button type="button" data-contact-action="save">Save</button>
        <button type="button" data-contact-action="cancel">Cancel</button>
      </td>
    </tr>`;
}

function renderCardContacts() {
  const body = document.getElementById('custContactsBody');
  const phones = cardContacts.filter((x) => x.kind === 'Phone').length;
  const addresses = cardContacts.length - phones;
  document.getElementById('custContactsCount').textContent = cardContacts.length
    ? `(${phones} no.${phones === 1 ? '' : 's'}, ${addresses} address${addresses === 1 ? '' : 'es'})` : '';

  const rows = [];
  if (contactEditing === 'new-Phone' || contactEditing === 'new-Address') rows.push(contactEditRowHtml(contactEditing.slice(4), null));
  cardContacts.forEach((x) => {
    if (String(x.id) === String(contactEditing)) {
      rows.push(contactEditRowHtml(x.kind, x));
      return;
    }
    rows.push(`
      <tr data-contact-id="${x.id}">
        <td>${x.is_default ? '<span class="cust-default-star" title="Default - used by the list, Create Order and the bot">★</span>' : ''}</td>
        <td>${x.kind === 'Phone' ? 'Contact No.' : 'Address'}</td>
        <td class="cust-contact-value">${escapeHtml(x.value)}</td>
        <td>${escapeHtml(x.label || '')}</td>
        <td><span class="cust-src${x.source === 'Chat' ? ' cust-src-chat' : ''}" title="${escapeHtml(CONTACT_SOURCE_TITLE[x.source] || x.source)}">${escapeHtml(x.source)}</span></td>
        <td title="First seen ${escapeHtml(dateTime(x.first_seen_at_utc))}">${escapeHtml(shortDate(x.last_seen_at_utc))}</td>
        <td class="cust-contact-actions">
          ${x.is_default ? '' : '<button type="button" data-contact-action="default">Set Default</button>'}
          <button type="button" data-contact-action="edit">Edit</button>
          <button type="button" class="danger" data-contact-action="delete">Delete</button>
        </td>
      </tr>`);
  });
  body.innerHTML = rows.length ? rows.join('') : '<tr><td colspan="7" class="muted">No contact numbers or addresses yet.</td></tr>';
  body.querySelector('tr.editing [data-contact-field="value"]')?.focus();
}

async function saveCardContact(args) {
  const c = cardCustomer;
  if (!c) return false;
  cardError('');
  const { error } = await supabaseClient.rpc('admin_save_gma_customer_contact', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: c.psid,
    ...args
  });
  if (error) {
    cardError(error.message);
    return false;
  }
  await refreshCardAfterContactChange(c.psid);
  return true;
}

// A default changed -> the list row (and the card's Contact No. / Address) changed too.
async function refreshCardAfterContactChange(psid) {
  await loadCustomers();
  if (currentRows.some((r) => r.psid === psid)) openCustomerCard(psid, { keepOpenState: true });
  else if (cardCustomer) loadCardContacts(cardCustomer);
}

async function onContactAction(e) {
  const btn = e.target.closest('[data-contact-action]');
  if (!btn || !cardCustomer) return;
  const action = btn.dataset.contactAction;
  const tr = btn.closest('tr');

  if (action === 'cancel') {
    contactEditing = null;
    renderCardContacts();
    return;
  }
  if (action === 'save') {
    const id = tr.dataset.contactEdit;
    const isNew = id.startsWith('new-');
    btn.disabled = true;
    const ok = await saveCardContact({
      p_id: isNew ? null : Number(id),
      p_kind: tr.dataset.kind,
      p_value: tr.querySelector('[data-contact-field="value"]').value.trim(),
      p_label: tr.querySelector('[data-contact-field="label"]').value.trim(),
      p_make_default: !!tr.querySelector('[data-contact-field="default"]')?.checked
    });
    if (!ok) btn.disabled = false;
    return;
  }

  const x = cardContacts.find((r) => String(r.id) === tr.dataset.contactId);
  if (!x) return;
  if (action === 'edit') {
    contactEditing = String(x.id);
    renderCardContacts();
  } else if (action === 'default') {
    btn.disabled = true;
    if (!await saveCardContact({ p_id: x.id, p_kind: x.kind, p_value: x.value, p_label: x.label, p_make_default: true })) btn.disabled = false;
  } else if (action === 'delete') {
    const what = x.kind === 'Phone' ? 'contact no.' : 'address';
    if (!confirm(`Delete this ${what}?\n\n${x.value}${x.is_default ? `\n\nIt's the default - the most recently used other ${what} becomes the default.` : ''}`)) return;
    btn.disabled = true;
    const { error } = await supabaseClient.rpc('admin_delete_gma_customer_contact', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_psid: cardCustomer.psid,
      p_id: x.id
    });
    if (error) {
      btn.disabled = false;
      cardError(error.message);
      return;
    }
    await refreshCardAfterContactChange(cardCustomer.psid);
  }
}

function cardError(message) {
  const el = document.getElementById('custCardError');
  el.textContent = message || '';
  el.classList.toggle('hidden', !message);
}

function renderCardStats(c, orders) {
  const live = (orders || []).filter((o) => o.status !== 'Cancelled');
  const sum = (key) => live.reduce((t, o) => t + Number(o[key] || 0), 0);
  const rows = orders === null
    ? [['Orders', '...']]
    : [
      ['Orders', String(orders.length)],
      ['Cancelled', String(orders.length - live.length)],
      ['Order Value', `₱${money(sum('total'))}`],
      ['Paid', `₱${money(sum('amount_paid'))}`],
      ['Balance Due', `₱${money(sum('balance'))}`],
      ['Last Order', escapeHtml(shortDate(orders[0]?.created_at_utc)) || '-']
    ];
  if (Number(c.pancake_order_count || 0) > 0) {
    rows.push(['sep'], ['Pancake Orders', String(c.pancake_order_count)], ['Pancake Spend', `₱${money(c.pancake_purchased)}`]);
  }
  document.getElementById('custCardStats').innerHTML = `
    <div class="cust-stat-head">
      <span class="cust-avatar" data-psid="${escapeHtml(c.psid)}" style="background:${avatarColor(c.customer_name || c.psid)}">${escapeHtml(initials(c.customer_name || '?'))}</span>
      <div class="cust-fact-name">${escapeHtml(c.customer_name || '(no name)')}</div>
    </div>
    <dl class="cust-stats">${rows.map(([k, v]) => (k === 'sep' ? '<div class="cust-stat-sep"></div>' : `<dt>${escapeHtml(k)}</dt><dd>${v}</dd>`)).join('')}</dl>`;
  applyProfilePic();
}

async function loadCardOrders(c) {
  const myGeneration = ++cardOrdersGeneration;
  const body = document.getElementById('custCardOrdersBody');
  body.innerHTML = '<tr><td colspan="10" class="muted">Loading...</td></tr>';
  document.getElementById('custCardOrdersCount').textContent = '';
  renderCardStats(c, null);

  const { data, error } = await supabaseClient.rpc('admin_list_gma_customer_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: c.psid,
    p_page_id: c.page_id
  });
  if (myGeneration !== cardOrdersGeneration) return;
  if (error) {
    const message = /could not find the function|schema cache/i.test(error.message)
      ? 'The Customer Card isn\'t set up yet - run sql/supabase_gma_customer_card.sql.'
      : error.message;
    body.innerHTML = `<tr><td colspan="10" class="error-text">${escapeHtml(message)}</td></tr>`;
    renderCardStats(c, []);
    return;
  }
  const orders = data || [];
  document.getElementById('custCardOrdersCount').textContent = orders.length ? `(${orders.length})` : '';
  body.innerHTML = orders.length === 0
    ? '<tr><td colspan="10" class="muted">No orders yet.</td></tr>'
    : orders.map((o) => `
      <tr>
        <td>${escapeHtml(o.order_no)}</td>
        <td>${escapeHtml(shortDate(o.created_at_utc))}</td>
        <td><span class="badge ${ORDER_STATUS_BADGE[o.status] || 'badge-neutral'}">${escapeHtml(o.status || 'New')}</span></td>
        <td>${escapeHtml(o.online_order_status || '')}</td>
        <td>${escapeHtml(o.fulfillment_type || '')}</td>
        <td>${escapeHtml(o.location || '')}</td>
        <td class="num">${Number(o.item_count || 0)}</td>
        <td class="num">${money(o.total)}</td>
        <td class="num">${money(o.amount_paid)}</td>
        <td class="num">${Number(o.balance || 0) > 0 ? money(o.balance) : '<span class="muted">0.00</span>'}</td>
      </tr>`).join('');
  renderCardStats(c, orders);
}

// opts.keepOpenState: re-opened after a contact change - keeps a Name being typed.
function openCustomerCard(psid, opts = {}) {
  const c = currentRows.find((r) => r.psid === psid);
  if (!c) return;
  const typedName = opts.keepOpenState && cardCustomer?.psid === psid ? document.getElementById('custCardName').value : null;
  cardCustomer = c;
  cardError('');
  const mood = MOODS[c.customer_mood];

  document.getElementById('custCardTitle').textContent = c.customer_name || '(no name)';
  document.getElementById('custCardBadges').innerHTML = pageChipHtml(c.page_id)
    + (c.is_paused ? '<span class="cust-chip cust-chip-paused">Bot paused</span>' : '');
  document.getElementById('custCardName').value = typedName ?? (c.customer_name || '');
  setCardValue('custCardNameSource', escapeHtml(NAME_SOURCE_LABEL[c.customer_name_source] || c.customer_name_source || ''));
  setCardValue('custCardPage', pageChipHtml(c.page_id));
  setCardValue('custCardPsid', `<code>${escapeHtml(c.psid)}</code>`);
  setCardValue('custCardMood', mood ? `${mood.emoji} ${escapeHtml(mood.label)}${c.customer_mood_reason ? ` - ${escapeHtml(c.customer_mood_reason)}` : ''}` : '');
  setCardValue('custCardTags', tagChipsHtml(c.tags));
  setCardValue('custCardBot', c.is_paused ? 'Paused - staff are handling this chat' : 'Active');
  setCardValue('custCardFirstSeen', escapeHtml(dateTime(c.created_at_utc)));
  setCardValue('custCardLastMessage', escapeHtml(dateTime(c.last_message_at_utc)));
  setCardValue('custCardPhone', escapeHtml(c.customer_phone || ''));
  document.getElementById('custCardPhoneSrc').textContent = sourceHintText(c.phone_source);
  setCardValue('custCardEmail', escapeHtml(c.customer_email || ''));
  setCardValue('custCardAddress', escapeHtml(c.customer_address || ''));
  document.getElementById('custCardAddressSrc').textContent = sourceHintText(c.address_source);
  document.getElementById('custCardChatBtn').disabled = c.page_id === 'website';
  document.getElementById('custCardCopyBtn').disabled = !c.customer_phone;
  syncCardSummaries();

  applyCardMaximized(readStoredFlag(CUST_CARD_MAXIMIZED_KEY, false));
  document.getElementById('custCardModal').classList.remove('hidden');
  loadProfilePic(c);
  loadCardContacts(c);
  loadCardOrders(c);
}

function closeCustomerCard() {
  if (cardIsDirty() && document.getElementById('custCardSaveBtn').dataset.userEdited === '1'
    && !confirm('Discard your changes to this customer?')) return;
  document.getElementById('custCardSaveBtn').dataset.userEdited = '';
  document.getElementById('custCardModal').classList.add('hidden');
  cardCustomer = null;
}

async function saveCustomerCard() {
  const c = cardCustomer;
  if (!c) return;
  const btn = document.getElementById('custCardSaveBtn');
  btn.disabled = true;
  cardError('');
  const { error } = await supabaseClient.rpc('admin_update_gma_customer', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: c.psid,
    p_page_id: c.page_id,
    p_name: document.getElementById('custCardName').value.trim(),
    // Defaults are managed in Contacts & Addresses - sent back as they are on the record.
    p_phone: recordValue(c, 'customer_phone', 'phone_source'),
    p_address: recordValue(c, 'customer_address', 'address_source')
  });
  if (error) {
    btn.disabled = false;
    cardError(/could not find the function|schema cache/i.test(error.message)
      ? 'Saving isn\'t set up yet - run sql/supabase_gma_customer_card.sql.'
      : error.message);
    return;
  }
  btn.dataset.userEdited = '';
  await loadCustomers();
  if (currentRows.some((r) => r.psid === c.psid)) openCustomerCard(c.psid);
  else closeCustomerCard();
}

function wireCustomerCard() {
  document.getElementById('custCardName').addEventListener('input', () => {
    document.getElementById('custCardSaveBtn').dataset.userEdited = '1';
    syncCardSummaries();
  });
  document.getElementById('custContactsBody').addEventListener('click', onContactAction);
  document.getElementById('custContactNewPhoneBtn').addEventListener('click', () => {
    contactEditing = 'new-Phone';
    renderCardContacts();
  });
  document.getElementById('custContactNewAddressBtn').addEventListener('click', () => {
    contactEditing = 'new-Address';
    renderCardContacts();
  });
  document.getElementById('custCardSaveBtn').addEventListener('click', saveCustomerCard);
  document.getElementById('custCardCloseBtn').addEventListener('click', closeCustomerCard);
  document.getElementById('custCardModal').addEventListener('click', (e) => {
    if (e.target.id === 'custCardModal') closeCustomerCard();
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !document.getElementById('custCardModal').classList.contains('hidden')) closeCustomerCard();
  });
  document.getElementById('custCardMaximizeBtn').addEventListener('click', () => {
    const nowMaximized = !document.getElementById('custCardModal').classList.contains('modal-maximized');
    applyCardMaximized(nowMaximized);
    writeStoredFlag(CUST_CARD_MAXIMIZED_KEY, nowMaximized);
  });
  document.getElementById('custCardChatBtn').addEventListener('click', () => {
    if (cardCustomer) location.href = chatUrl(cardCustomer);
  });
  document.getElementById('custCardCopyBtn').addEventListener('click', async () => {
    const phone = cardCustomer?.customer_phone || '';
    if (!phone) return;
    try {
      await navigator.clipboard.writeText(phone);
    } catch {
      window.prompt('Copy the contact no.:', phone);
    }
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Customers');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Customers.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('customersContent').classList.remove('hidden');
  wireCustomerPage();
  await loadCustomers();
})();
