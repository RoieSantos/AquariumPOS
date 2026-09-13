// GMA Conversations page logic (super users only) - our own inbox over ChatbotConversations/
// ChatbotMessages (see supabase_chatbot_conversations_tables.sql), which are otherwise locked to
// the facebook-messenger-webhook Edge Function's service-role client. Per direct request, this is
// the in-house replacement for a third-party inbox (Pancake) for the AI bot's Facebook Page - same
// Messenger channel underneath, just our own interface: view every conversation, pause the AI per
// conversation, and now reply directly as staff.
//
// Renamed from AI Bot Messages (docs/js/aiBotMessages.js) - same list/pause functionality, now with
// a reply box wired to the new chatbot-staff-reply Edge Function (supabase/functions/chatbot-staff-
// reply), which validates the admin session, logs the message (Role='staff', see supabase_chatbot_
// staff_reply.sql), auto-pauses the conversation, and sends it on Messenger via the Graph API.
let currentSession = null;
let conversations = [];
let selectedPsid = null;

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatRelativeTime(isoString) {
  if (!isoString) return '';
  const diffMs = Date.now() - new Date(isoString).getTime();
  const minutes = Math.round(diffMs / 60000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return new Date(isoString).toLocaleDateString();
}

async function loadConversations() {
  const listEl = document.getElementById('conversationListEl');
  const { data, error } = await supabaseClient.rpc('admin_list_chatbot_conversations', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_page: 1,
    p_page_size: 100
  });

  if (error) {
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }

  conversations = data || [];
  renderConversationList();
}

function renderConversationList() {
  const listEl = document.getElementById('conversationListEl');

  if (conversations.length === 0) {
    listEl.innerHTML = '<div class="inbox-empty-state">No conversations yet.</div>';
    return;
  }

  listEl.innerHTML = conversations.map((c) => {
    const badges = [
      c.status === 'Escalated' ? '<span class="inbox-badge inbox-badge-escalated">Escalated</span>' : '',
      c.is_paused ? '<span class="inbox-badge inbox-badge-paused">Paused</span>' : ''
    ].join('');

    return `
      <div class="inbox-conv-item${c.psid === selectedPsid ? ' active' : ''}" data-psid="${escapeHtml(c.psid)}">
        <div class="inbox-conv-top">
          <span class="inbox-conv-psid">${escapeHtml(c.customer_name || c.psid)}${badges}</span>
          <span class="inbox-conv-time">${formatRelativeTime(c.last_message_at_utc)}</span>
        </div>
        <div class="inbox-conv-preview">${escapeHtml(c.last_message_preview || '(no messages)')}</div>
      </div>
    `;
  }).join('');

  listEl.querySelectorAll('.inbox-conv-item').forEach((el) => {
    el.addEventListener('click', () => openConversation(el.dataset.psid));
  });
}

function renderThreadHeader(conv) {
  const headerEl = document.getElementById('threadHeaderEl');
  headerEl.innerHTML = `
    <span style="font-size:12px; font-weight:600;">${escapeHtml(conv.customer_name || conv.psid)}</span>
    <button class="btn ${conv.is_paused ? 'btn-success' : 'btn-secondary'} btn-sm" id="togglePauseBtn" type="button">
      ${conv.is_paused ? '▶ Resume AI' : '⏸ Pause AI'}
    </button>
  `;
  document.getElementById('togglePauseBtn').addEventListener('click', () => togglePause(conv));

  document.getElementById('replyRowEl').classList.remove('hidden');
}

async function togglePause(conv) {
  const btn = document.getElementById('togglePauseBtn');
  btn.disabled = true;
  const nextPaused = !conv.is_paused;

  const { error } = await supabaseClient.rpc('admin_set_chatbot_conversation_paused', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: conv.psid,
    p_is_paused: nextPaused
  });

  if (error) {
    alert(`Could not update pause state: ${error.message}`);
    btn.disabled = false;
    return;
  }

  conv.is_paused = nextPaused;
  renderThreadHeader(conv);
  renderConversationList();
}

function messageSenderLabel(m) {
  if (m.role === 'staff') return m.sent_by_username ? `Staff (${m.sent_by_username})` : 'Staff';
  if (m.role === 'assistant') return 'AI Bot';
  return null;
}

function renderMessages(rows) {
  const messagesEl = document.getElementById('threadMessagesEl');

  if (rows.length === 0) {
    messagesEl.innerHTML = '<div class="inbox-empty-state">No messages yet.</div>';
    return;
  }

  messagesEl.innerHTML = rows.map((m) => {
    const bubbleClass = m.role === 'staff' ? 'inbox-msg-staff' : m.role === 'assistant' ? 'inbox-msg-assistant' : 'inbox-msg-user';
    const sender = messageSenderLabel(m);
    const hasImage = m.attachment_type === 'image' && m.attachment_url;
    // '[Photo]' is just the placeholder Content the webhook stamps on an image with no caption
    // (ChatbotMessages.Content is NOT NULL) - skip showing it as redundant text under the image.
    const showText = m.content && m.content !== '[Photo]';
    // Claude's vision pass (extractPaymentDetails in the webhook) flags this as a likely payment
    // screenshot - a SUGGESTION only, never auto-applied to any order's payments. Staff confirms by
    // clicking through to the Add Payment form (see useDetectedPayment below).
    const hasDetectedPayment = m.detected_payment_amount !== null && m.detected_payment_amount !== undefined;
    return `
      <div class="inbox-msg ${bubbleClass}">
        ${sender ? `<span class="inbox-msg-sender">${escapeHtml(sender)}</span>` : ''}
        ${hasImage ? `<a href="${escapeHtml(m.attachment_url)}" target="_blank" rel="noopener"><img class="inbox-msg-image" src="${escapeHtml(m.attachment_url)}" alt="Photo sent by customer"></a>` : ''}
        ${showText ? escapeHtml(m.content) : ''}
        ${hasDetectedPayment ? `
          <div class="inbox-payment-detected">
            <div class="inbox-payment-detected-title">Detected Payment (unconfirmed)</div>
            <div>Amount: ${Number(m.detected_payment_amount).toFixed(2)}</div>
            ${m.detected_payment_method ? `<div>Method: ${escapeHtml(m.detected_payment_method)}</div>` : ''}
            ${m.detected_payment_reference ? `<div>Ref: ${escapeHtml(m.detected_payment_reference)}</div>` : ''}
            ${m.detected_payment_sender_name ? `<div>From: ${escapeHtml(m.detected_payment_sender_name)}</div>` : ''}
            <button type="button" class="btn btn-secondary btn-sm inbox-use-payment-btn"
              data-amount="${Number(m.detected_payment_amount)}"
              data-method="${escapeHtml(m.detected_payment_method || '')}"
              data-reference="${escapeHtml(m.detected_payment_reference || '')}">Use in Add Payment</button>
          </div>
        ` : ''}
      </div>
    `;
  }).join('');

  messagesEl.querySelectorAll('.inbox-use-payment-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      useDetectedPayment(parseFloat(btn.dataset.amount) || null, btn.dataset.method || null, btn.dataset.reference || null);
    });
  });

  messagesEl.scrollTop = messagesEl.scrollHeight;
}

// Reads what Claude's vision pass detected on a payment screenshot and hands it to the
// Information tab's existing Add Payment inputs (per order, see loadConversationOrders) - never
// posts the payment itself, staff still has to review the pre-filled values and click Add Payment.
// Since those inputs don't exist until loadConversationOrders' async fetch finishes rendering them,
// this stashes the values in pendingDetectedPayment and loadConversationOrders applies them once the
// order rows are actually in the DOM.
let pendingDetectedPayment = null;

function useDetectedPayment(amount, method, reference) {
  const conv = conversations.find((c) => c.psid === selectedPsid);
  if (!conv) return;
  pendingDetectedPayment = { amount, method, reference };
  activeCustomerTab = 'info';
  renderCustomerPanel(conv);
}

async function loadMessages(psid) {
  const messagesEl = document.getElementById('threadMessagesEl');
  messagesEl.innerHTML = '<div class="inbox-empty-state">Loading messages...</div>';

  const { data, error } = await supabaseClient.rpc('admin_get_chatbot_conversation_messages', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: psid,
    p_limit: 200
  });

  if (error) {
    messagesEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }

  renderMessages(data || []);
}

async function openConversation(psid) {
  selectedPsid = psid;
  renderConversationList();

  const conv = conversations.find((c) => c.psid === psid);
  if (!conv) return;
  renderThreadHeader(conv);
  document.getElementById('replyErrorEl').classList.add('hidden');
  document.getElementById('replyInput').value = '';

  // Switching to a different customer's conversation - don't carry over a stale cart/tab from
  // whoever was open before.
  activeCustomerTab = 'info';
  newOrderLines = [];
  renderCustomerPanel(conv);
  await loadMessages(psid);
}

// Right-panel layout (Information / Create Order tabs, inline order form, phone-match lookup)
// mirrors Pancake's own conversation view per direct reference screenshot - GMA runs on its own
// separate Facebook Page from the Pancake-connected one that online orders come through though, so
// there's no shared id to auto-match a conversation to PRE-EXISTING orders (the manual name/phone
// search in the Information tab covers those). Orders CREATED from the Create Order tab
// (admin_create_gma_conversation_order) stamp GmaPsid/GmaPageId at insert time, so those show up
// automatically via admin_list_automated_orders_by_gma_conversation, no searching needed.
let activeCustomerTab = 'info';

function renderCustomerPanel(conv) {
  newOrderConv = conv;
  const panelEl = document.getElementById('customerPanelEl');

  panelEl.innerHTML = `
    <h3>${escapeHtml(conv.customer_name || 'Unknown Customer')}</h3>
    <div class="panel-tabs">
      <button type="button" class="panel-tab-btn${activeCustomerTab === 'info' ? ' active' : ''}" data-tab="info">Information</button>
      <button type="button" class="panel-tab-btn${activeCustomerTab === 'create' ? ' active' : ''}" data-tab="create">Create Order</button>
    </div>
    <div id="panelTabBody"></div>
  `;

  panelEl.querySelectorAll('.panel-tab-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      activeCustomerTab = btn.dataset.tab;
      renderCustomerPanel(conv);
    });
  });

  if (activeCustomerTab === 'create') {
    renderCreateOrderTab(conv);
  } else {
    renderInformationTab(conv);
  }
}

function renderInformationTab(conv) {
  const bodyEl = document.getElementById('panelTabBody');
  const conversationId = `${conv.page_id || ''}_${conv.psid}`;

  bodyEl.innerHTML = `
    <div class="inbox-customer-id">
      PSID: ${escapeHtml(conv.psid)}<br>
      Page ID: ${escapeHtml(conv.page_id || '(unknown)')}<br>
      Conversation ID: ${escapeHtml(conversationId)}
    </div>
    <h3>Orders From This Conversation</h3>
    <div id="conversationOrdersEl" class="inbox-empty-state">Loading...</div>

    <h3>Look Up Other Orders</h3>
    <div class="inbox-customer-search">
      <input type="text" id="customerOrderSearchInput" placeholder="Customer name or phone...">
      <button class="btn btn-secondary btn-sm" id="customerOrderSearchBtn" type="button">Search</button>
    </div>
    <div id="customerOrderResultsEl" class="inbox-empty-state">Not linked to a customer record - search by name or phone.</div>
  `;

  document.getElementById('customerOrderSearchBtn').addEventListener('click', searchCustomerOrders);
  document.getElementById('customerOrderSearchInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      searchCustomerOrders();
    }
  });

  loadConversationOrders(conv);
}

async function loadConversationOrders(conv) {
  const listEl = document.getElementById('conversationOrdersEl');
  if (!listEl) return;
  listEl.className = 'inbox-empty-state';
  listEl.textContent = 'Loading...';

  const { data, error } = await supabaseClient.rpc('admin_list_automated_orders_by_gma_conversation', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: conv.psid,
    p_page_id: conv.page_id
  });

  if (error) {
    listEl.className = 'inbox-empty-state error-text';
    listEl.textContent = error.message;
    return;
  }

  const orders = data || [];
  if (orders.length === 0) {
    listEl.className = 'inbox-empty-state';
    listEl.textContent = 'No orders created from this conversation yet.';
    return;
  }

  listEl.className = '';
  listEl.innerHTML = orders.map((o) => `
    <div class="inbox-order-item">
      <div class="inbox-order-top">
        <a href="online-order-lines.html?order=${encodeURIComponent(o.order_no)}">${escapeHtml(o.order_no)}</a>
        <span>${escapeHtml(o.status || '')}</span>
      </div>
      <div class="inbox-order-meta">${escapeHtml(o.customer_name || '')} - ${escapeHtml(o.fulfillment_type || '')}</div>
      <div class="inbox-order-meta">Total: ${Number(o.estimated_total || 0).toFixed(2)} | Paid: ${Number(o.amount_paid || 0).toFixed(2)} | Balance: ${Number(o.balance || 0).toFixed(2)}</div>
      <div class="inbox-order-meta">Pancake: ${escapeHtml(o.pancake_sync_status || '')}</div>
      <div class="inbox-payment-row">
        <input type="number" min="0.01" step="0.01" placeholder="Amount" id="payAmount-${escapeHtml(o.order_no)}">
        <select id="payMethod-${escapeHtml(o.order_no)}">
          <option value="Cash">Cash</option>
          <option value="GCash">GCash</option>
          <option value="Bank Transfer">Bank Transfer</option>
          <option value="Other">Other</option>
        </select>
        <input type="text" placeholder="Reference (optional)" id="payRef-${escapeHtml(o.order_no)}">
        <button class="btn btn-secondary btn-sm" type="button" data-order="${escapeHtml(o.order_no)}">Add Payment</button>
      </div>
    </div>
  `).join('');

  listEl.querySelectorAll('.inbox-payment-row button').forEach((btn) => {
    btn.addEventListener('click', () => addOrderPayment(btn.dataset.order, conv));
  });

  if (pendingDetectedPayment) {
    if (orders.length === 0) {
      alert(`Detected a payment screenshot (amount: ${pendingDetectedPayment.amount ?? '?'}), but this conversation has no orders yet. Create an order first, then use Add Payment manually.`);
    } else {
      const target = orders[0];
      const amountInput = document.getElementById(`payAmount-${target.order_no}`);
      const methodSelect = document.getElementById(`payMethod-${target.order_no}`);
      const refInput = document.getElementById(`payRef-${target.order_no}`);
      if (amountInput && pendingDetectedPayment.amount !== null) amountInput.value = pendingDetectedPayment.amount;
      if (methodSelect && pendingDetectedPayment.method) {
        const matched = Array.from(methodSelect.options).find((o) => o.value.toLowerCase() === pendingDetectedPayment.method.toLowerCase());
        if (matched) methodSelect.value = matched.value;
      }
      if (refInput && pendingDetectedPayment.reference) refInput.value = pendingDetectedPayment.reference;
      amountInput?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
    pendingDetectedPayment = null;
  }
}

async function addOrderPayment(orderNo, conv) {
  const amountInput = document.getElementById(`payAmount-${orderNo}`);
  const methodSelect = document.getElementById(`payMethod-${orderNo}`);
  const refInput = document.getElementById(`payRef-${orderNo}`);
  const amount = parseFloat(amountInput.value);

  if (!amount || amount <= 0) {
    alert('Enter a valid payment amount.');
    return;
  }

  const { error } = await supabaseClient.rpc('admin_add_automated_order_payment', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo,
    p_amount: amount,
    p_method: methodSelect.value,
    p_reference: refInput.value.trim() || null
  });

  if (error) {
    alert(`Could not record payment: ${error.message}`);
    return;
  }

  await loadConversationOrders(conv);
}

async function searchCustomerOrders() {
  const input = document.getElementById('customerOrderSearchInput');
  const resultsEl = document.getElementById('customerOrderResultsEl');
  const term = input.value.trim();

  if (!term) {
    resultsEl.className = 'inbox-empty-state';
    resultsEl.textContent = 'Type a name or phone number to search.';
    return;
  }

  resultsEl.className = 'inbox-empty-state';
  resultsEl.textContent = 'Searching...';

  const { data, error } = await supabaseClient.rpc('admin_list_online_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: term,
    p_page: 1,
    p_page_size: 20
  });

  if (error) {
    resultsEl.className = 'inbox-empty-state error-text';
    resultsEl.textContent = error.message;
    return;
  }

  const orders = data || [];
  if (orders.length === 0) {
    resultsEl.className = 'inbox-empty-state';
    resultsEl.textContent = 'No matching orders found.';
    return;
  }

  resultsEl.className = '';
  resultsEl.innerHTML = orders.map((o) => `
    <div class="inbox-order-item">
      <div class="inbox-order-top">
        <a href="online-order-lines.html?order=${encodeURIComponent(o.order_id)}">${escapeHtml(o.order_id)}</a>
        <span>${escapeHtml(o.status || '')}</span>
      </div>
      <div class="inbox-order-meta">${escapeHtml(o.customer_name || '')} - ${o.order_date || ''}</div>
      <div class="inbox-order-meta">Balance: ${Number(o.balance || 0).toFixed(2)}</div>
    </div>
  `).join('');
}

// Create Order tab - creates a real AutomatedOrders row stamped with this conversation's
// GmaPsid/GmaPageId (admin_create_gma_conversation_order). Item search uses public_search_items
// (free-text, anon, name/price/stock only - same safe field set as public_list_order_items) instead
// of order-now.html's category-then-item cascading dropdowns, matching Pancake's single product
// search box. newOrderLines persists across tab switches (only reset by Clear or a successful
// submit) so flipping to Information and back doesn't lose an in-progress cart.
let newOrderConv = null;
let newOrderLines = [];
let productSearchDebounce = null;
let productSearchResultsCache = [];
let phoneMatchDebounce = null;

function renderCreateOrderTab(conv) {
  const bodyEl = document.getElementById('panelTabBody');

  bodyEl.innerHTML = `
    <p class="error-text hidden" id="newOrderError"></p>

    <div class="form-group">
      <div class="form-group-title">Customer</div>
      <div class="form-grid">
        <div class="form-row">
          <label>Name</label>
          <input type="text" id="newOrderCustomerName">
        </div>
        <div class="form-row">
          <label>Phone</label>
          <input type="text" id="newOrderCustomerPhone" placeholder="09171234567">
        </div>
      </div>
      <div id="phoneMatchArea"></div>
      <div class="form-grid">
        <div class="form-row">
          <label>Email (optional)</label>
          <input type="text" id="newOrderCustomerEmail">
        </div>
        <div class="form-row">
          <label>Location</label>
          <select id="newOrderLocation">
            <option value="Amaya">Amaya</option>
            <option value="GMA">GMA</option>
          </select>
        </div>
      </div>
      <div class="form-grid">
        <div class="form-row">
          <label>Fulfillment</label>
          <select id="newOrderFulfillment">
            <option value="Pickup">Pickup</option>
            <option value="Delivery">Delivery</option>
          </select>
        </div>
        <div class="form-row hidden" id="newOrderDeliveryAddressRow">
          <label>Delivery Address</label>
          <input type="text" id="newOrderDeliveryAddress">
        </div>
      </div>
      <div class="form-row" style="margin-bottom:0;">
        <label>Notes (optional)</label>
        <input type="text" id="newOrderNotes">
      </div>
    </div>

    <div class="form-group">
      <div class="form-group-title">Product</div>
      <div class="product-search-wrap">
        <input type="text" id="productSearchInput" placeholder="Search product by name...">
        <div id="productSearchResults" class="product-search-results hidden"></div>
      </div>

      <table class="new-order-lines-table">
        <thead><tr><th>Item</th><th>Qty</th><th>Price</th><th>Total</th><th></th></tr></thead>
        <tbody id="newOrderLinesBody"></tbody>
      </table>

      <div class="new-order-total-bar">
        <span class="new-order-total-label">Order Total</span>
        <span class="new-order-total-value" id="newOrderTotalEl">0.00</span>
      </div>
    </div>

    <div style="display:flex; gap:10px; justify-content:flex-end;">
      <button type="button" class="btn btn-secondary" id="newOrderClearBtn">Clear</button>
      <button type="button" class="btn btn-primary" id="newOrderSubmitBtn">Create</button>
    </div>
  `;

  // Prefilled from their Facebook profile name (ChatbotConversations.CustomerName - see
  // fetchFacebookProfileName in the webhook), not authoritative - staff can still edit it.
  document.getElementById('newOrderCustomerName').value = conv.customer_name || '';

  document.getElementById('newOrderClearBtn').addEventListener('click', () => {
    newOrderLines = [];
    renderCreateOrderTab(conv);
  });
  document.getElementById('newOrderSubmitBtn').addEventListener('click', submitNewOrder);
  document.getElementById('newOrderFulfillment').addEventListener('change', (e) => {
    document.getElementById('newOrderDeliveryAddressRow').classList.toggle('hidden', e.target.value !== 'Delivery');
  });

  const phoneInput = document.getElementById('newOrderCustomerPhone');
  phoneInput.addEventListener('input', () => {
    clearTimeout(phoneMatchDebounce);
    phoneMatchDebounce = setTimeout(checkPhoneMatch, 500);
  });

  const searchInput = document.getElementById('productSearchInput');
  searchInput.addEventListener('input', (e) => {
    clearTimeout(productSearchDebounce);
    const term = e.target.value.trim();
    if (!term) {
      document.getElementById('productSearchResults').classList.add('hidden');
      return;
    }
    productSearchDebounce = setTimeout(() => runProductSearch(term), 300);
  });
  searchInput.addEventListener('focus', () => {
    if (productSearchResultsCache.length > 0 && searchInput.value.trim()) {
      document.getElementById('productSearchResults').classList.remove('hidden');
    }
  });
  searchInput.addEventListener('blur', () => {
    // Delayed so a mousedown on a result (which also preventDefaults, see runProductSearch) has
    // already run before the dropdown disappears.
    setTimeout(() => document.getElementById('productSearchResults')?.classList.add('hidden'), 150);
  });

  renderNewOrderLines();
}

// Mirrors Pancake's phone-linked-order warning: debounced on every keystroke in the Phone field,
// looks the number up against OnlineCustomers (admin_list_online_customers, synced from Pancake -
// order_count/purchased_amount are its own rolled-up stats) and shows a warning + matched-customer
// card when found, auto-filling Name only if the staff hasn't already typed one.
async function checkPhoneMatch() {
  const areaEl = document.getElementById('phoneMatchArea');
  const phoneInput = document.getElementById('newOrderCustomerPhone');
  if (!areaEl || !phoneInput) return;
  const phone = phoneInput.value.trim();

  if (phone.length < 7) {
    areaEl.innerHTML = '';
    return;
  }

  const { data, error } = await supabaseClient.rpc('admin_list_online_customers', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: phone,
    p_page: 1,
    p_page_size: 1
  });

  if (error || !data || data.length === 0) {
    areaEl.innerHTML = '';
    return;
  }

  const match = data[0];
  const nameInput = document.getElementById('newOrderCustomerName');
  if (nameInput && !nameInput.value.trim() && match.name) {
    nameInput.value = match.name;
  }

  const initials = (match.name || '?').trim().charAt(0).toUpperCase() || '?';
  areaEl.innerHTML = `
    ${Number(match.order_count || 0) > 0 ? `
      <div class="phone-match-warning">
        <span>This phone number is linked with ${match.order_count} existing order(s), totaling &#8369;${Number(match.purchased_amount || 0).toLocaleString('en-PH', { minimumFractionDigits: 2 })}.</span>
        <button type="button" id="dismissPhoneMatchBtn" title="Dismiss">&times;</button>
      </div>
    ` : ''}
    <div class="matched-customer-card">
      <div class="matched-customer-avatar">${escapeHtml(initials)}</div>
      <div>
        <div>${escapeHtml(match.name || 'Unnamed customer')}</div>
        <div class="matched-customer-meta">${escapeHtml(match.primary_phone_number || phone)}</div>
      </div>
    </div>
  `;

  const dismissBtn = document.getElementById('dismissPhoneMatchBtn');
  if (dismissBtn) {
    dismissBtn.addEventListener('click', () => areaEl.querySelector('.phone-match-warning')?.remove());
  }
}

async function runProductSearch(term) {
  const resultsEl = document.getElementById('productSearchResults');
  if (!resultsEl) return;

  const { data, error } = await supabaseClient.rpc('public_search_items', { p_query: term });

  if (error) {
    productSearchResultsCache = [];
    resultsEl.innerHTML = `<div class="product-search-result-item">${escapeHtml(error.message)}</div>`;
    resultsEl.classList.remove('hidden');
    return;
  }

  productSearchResultsCache = data || [];
  if (productSearchResultsCache.length === 0) {
    resultsEl.innerHTML = '<div class="product-search-result-item">No matching items.</div>';
    resultsEl.classList.remove('hidden');
    return;
  }

  resultsEl.innerHTML = productSearchResultsCache.map((item, index) => `
    <div class="product-search-result-item" data-index="${index}">
      <span class="product-search-result-name">${escapeHtml(item.name)}</span>
      <span class="product-search-result-price">${Number(item.price || 0).toFixed(2)}</span>
    </div>
  `).join('');
  resultsEl.classList.remove('hidden');

  resultsEl.querySelectorAll('.product-search-result-item[data-index]').forEach((el) => {
    // mousedown (not click) + preventDefault - fires before the search input's blur handler hides
    // this dropdown, so the click actually registers instead of losing the race.
    el.addEventListener('mousedown', (e) => {
      e.preventDefault();
      addProductToOrder(productSearchResultsCache[parseInt(el.dataset.index, 10)]);
    });
  });
}

function addProductToOrder(item) {
  const existing = newOrderLines.find((line) => line.item_code === item.code);
  if (existing) {
    existing.quantity += 1;
  } else {
    newOrderLines.push({
      category_code: item.category_code,
      item_code: item.code,
      item_name: item.name,
      price: Number(item.price || 0),
      quantity: 1
    });
  }

  const searchInput = document.getElementById('productSearchInput');
  searchInput.value = '';
  document.getElementById('productSearchResults').classList.add('hidden');
  renderNewOrderLines();
}

function removeNewOrderLine(index) {
  newOrderLines.splice(index, 1);
  renderNewOrderLines();
}

// Qty/Price are editable (staff sometimes needs to discount or correct a mismatched catalog
// price/quantity right in the cart) - each keystroke updates the data model and just that row's
// own total + the overall total bar directly (updateLineField/updateOrderTotal below), rather than
// re-rendering the whole table, which would otherwise steal focus out of the input on every key.
function renderNewOrderLines() {
  const bodyEl = document.getElementById('newOrderLinesBody');
  const totalEl = document.getElementById('newOrderTotalEl');
  if (!bodyEl || !totalEl) return;

  if (newOrderLines.length === 0) {
    bodyEl.innerHTML = '<tr><td colspan="5" class="muted">No items added yet.</td></tr>';
    totalEl.textContent = '0.00';
    return;
  }

  bodyEl.innerHTML = newOrderLines.map((line, index) => `
    <tr data-row="${index}">
      <td>${escapeHtml(line.item_name)}</td>
      <td><input type="number" class="line-qty-input" data-index="${index}" value="${line.quantity}" min="1" step="1"></td>
      <td><input type="number" class="line-price-input" data-index="${index}" value="${line.price}" min="0" step="0.01"></td>
      <td class="line-total-cell">${(line.price * line.quantity).toFixed(2)}</td>
      <td><button type="button" class="btn btn-secondary line-remove-btn" title="Remove this item" data-index="${index}">&times;</button></td>
    </tr>
  `).join('');

  updateOrderTotal();

  bodyEl.querySelectorAll('.line-remove-btn').forEach((btn) => {
    btn.addEventListener('click', () => removeNewOrderLine(parseInt(btn.dataset.index, 10)));
  });
  bodyEl.querySelectorAll('.line-qty-input').forEach((input) => {
    input.addEventListener('input', () => updateLineField(parseInt(input.dataset.index, 10), 'quantity', input.value));
  });
  bodyEl.querySelectorAll('.line-price-input').forEach((input) => {
    input.addEventListener('input', () => updateLineField(parseInt(input.dataset.index, 10), 'price', input.value));
  });
}

function updateLineField(index, field, rawValue) {
  const line = newOrderLines[index];
  if (!line) return;

  line[field] = field === 'quantity'
    ? Math.max(parseInt(rawValue, 10) || 1, 1)
    : Math.max(parseFloat(rawValue) || 0, 0);

  const row = document.querySelector(`#newOrderLinesBody tr[data-row="${index}"]`);
  if (row) row.querySelector('.line-total-cell').textContent = (line.price * line.quantity).toFixed(2);

  updateOrderTotal();
}

function updateOrderTotal() {
  const totalEl = document.getElementById('newOrderTotalEl');
  if (!totalEl) return;
  const total = newOrderLines.reduce((sum, line) => sum + (line.price * line.quantity), 0);
  totalEl.textContent = total.toFixed(2);
}

async function submitNewOrder() {
  const errorEl = document.getElementById('newOrderError');
  errorEl.classList.add('hidden');

  const fulfillment = document.getElementById('newOrderFulfillment').value;
  const submitBtn = document.getElementById('newOrderSubmitBtn');
  submitBtn.disabled = true;

  const { data, error } = await supabaseClient.rpc('admin_create_gma_conversation_order', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: newOrderConv.psid,
    p_page_id: newOrderConv.page_id,
    p_customer_name: document.getElementById('newOrderCustomerName').value.trim(),
    p_customer_phone: document.getElementById('newOrderCustomerPhone').value.trim(),
    p_customer_email: document.getElementById('newOrderCustomerEmail').value.trim() || null,
    p_fulfillment_type: fulfillment,
    p_delivery_address: fulfillment === 'Delivery' ? document.getElementById('newOrderDeliveryAddress').value.trim() : null,
    p_notes: document.getElementById('newOrderNotes').value.trim() || null,
    p_location: document.getElementById('newOrderLocation').value,
    p_lines: newOrderLines
  });

  submitBtn.disabled = false;

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  const result = (data || [])[0];
  newOrderLines = [];
  activeCustomerTab = 'info';
  renderCustomerPanel(newOrderConv);
  if (result && result.pancake_sync_status === 'Failed') {
    alert(`Order ${result.order_no} was created, but the Pancake push failed: ${result.pancake_sync_error || '(no error detail)'}. It can be retried from the Automated Orders page.`);
  }
}

async function sendReply() {
  const input = document.getElementById('replyInput');
  const btn = document.getElementById('sendReplyBtn');
  const errorEl = document.getElementById('replyErrorEl');
  const message = input.value.trim();
  errorEl.classList.add('hidden');

  if (!selectedPsid || !message) return;

  btn.disabled = true;
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-staff-reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password,
        psid: selectedPsid,
        message
      })
    });

    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      errorEl.textContent = result.error || `Send failed (${response.status}).`;
      errorEl.classList.remove('hidden');
      // A loggedOnly failure (Facebook delivery rejected) still recorded the message and
      // auto-paused the conversation server-side - refresh so the portal reflects that.
      if (result.loggedOnly) {
        await loadConversations();
        await loadMessages(selectedPsid);
      }
      return;
    }

    input.value = '';
    await loadConversations();
    const conv = conversations.find((c) => c.psid === selectedPsid);
    if (conv) renderThreadHeader(conv);
    await loadMessages(selectedPsid);
  } catch (err) {
    errorEl.textContent = err instanceof Error ? err.message : 'Could not reach the send function.';
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

// Live updates without polling - facebook-messenger-webhook and chatbot-staff-reply both broadcast
// a 'new_message' event on the shared 'gma-inbox' channel after every ChatbotMessages insert (see
// broadcastGmaEvent in either function). One conversation list refresh covers previews/ordering for
// everyone; the open thread's own messages only reload when the event is actually about the
// conversation currently on screen, so switching threads doesn't get interrupted by unrelated chatter.
function setupRealtimeInbox() {
  supabaseClient
    .channel('gma-inbox')
    .on('broadcast', { event: 'new_message' }, ({ payload }) => {
      handleGmaInboxEvent(payload);
    })
    .subscribe();
}

async function handleGmaInboxEvent(payload) {
  await loadConversations();

  if (payload?.psid && payload.psid === selectedPsid) {
    await loadMessages(selectedPsid);
    const conv = conversations.find((c) => c.psid === selectedPsid);
    if (conv) renderThreadHeader(conv);
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('GMA Conversations');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view GMA Conversations.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('inboxContent').classList.remove('hidden');
  document.getElementById('refreshInboxBtn').addEventListener('click', loadConversations);
  document.getElementById('sendReplyBtn').addEventListener('click', sendReply);
  document.getElementById('replyInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendReply();
    }
  });

  setupRealtimeInbox();
  await loadConversations();
})();
