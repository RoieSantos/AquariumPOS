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
let conversationSearchTerm = '';

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
    p_page_size: 100,
    p_search: conversationSearchTerm.trim() || null
  });

  if (error) {
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }

  conversations = data || [];
  renderConversationList();
}

// Per direct request: "same way we search from meta too" - matches customer name (the primary
// case, like Messenger's own contact search) or message content, server-side (admin_list_chatbot_
// conversations, see supabase_chatbot_conversations_search.sql), same debounce pattern as the
// phone-match/product-search inputs elsewhere on this page.
let conversationSearchDebounce = null;

function onConversationSearchInput(term) {
  conversationSearchTerm = term;
  clearTimeout(conversationSearchDebounce);
  conversationSearchDebounce = setTimeout(loadConversations, 300);
}

function renderConversationList() {
  const listEl = document.getElementById('conversationListEl');

  if (conversations.length === 0) {
    listEl.innerHTML = conversationSearchTerm.trim()
      ? `<div class="inbox-empty-state">No conversations match "${escapeHtml(conversationSearchTerm.trim())}".</div>`
      : '<div class="inbox-empty-state">No conversations yet.</div>';
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

// Centered "September 14, 2026" divider whenever the day changes between consecutive messages -
// per direct request to see the date of the conversation, not just relative/bare timestamps.
function formatDateDivider(iso) {
  return new Date(iso).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
}

function formatMessageTime(iso) {
  return new Date(iso).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

// Per direct request: show whether our own message was sent, failed, or has been seen by the
// customer. Only meaningful for our own outbound rows (assistant/staff) - an inbound 'user' row's
// mere existence here already proves it was received, so nothing is shown for those.
function messageStatusLabel(m) {
  if (m.role === 'user') return '';
  if (m.seen_at_utc) return '<span class="inbox-msg-status inbox-msg-status-seen">Seen</span>';
  if (m.delivery_status === 'Failed') return '<span class="inbox-msg-status inbox-msg-status-failed">Failed to send</span>';
  if (m.delivery_status === 'Sent') return '<span class="inbox-msg-status inbox-msg-status-sent">Sent</span>';
  return '';
}

function messageGroupKey(m) {
  return `${m.role}|${m.sent_by_username || ''}`;
}

// Messenger-style grouping: consecutive messages from the same sender (and same day) are drawn as
// one visual cluster - sender label only on the first bubble, timestamp/status only on the last -
// instead of repeating both on every single message, which is what made the thread so tall before.
function renderMessages(rows) {
  const messagesEl = document.getElementById('threadMessagesEl');

  if (rows.length === 0) {
    messagesEl.innerHTML = '<div class="inbox-empty-state">No messages yet.</div>';
    return;
  }

  let lastDateKey = null;
  const parts = [];

  rows.forEach((m, i) => {
    const dateKey = m.created_at_utc ? new Date(m.created_at_utc).toDateString() : null;
    const dateChanged = dateKey && dateKey !== lastDateKey;
    if (dateChanged) {
      parts.push(`<div class="inbox-date-divider"><span>${escapeHtml(formatDateDivider(m.created_at_utc))}</span></div>`);
      lastDateKey = dateKey;
    }

    const prev = rows[i - 1];
    const next = rows[i + 1];
    const isGroupStart = dateChanged || !prev || messageGroupKey(prev) !== messageGroupKey(m);
    const isGroupEnd = !next || (next.created_at_utc && new Date(next.created_at_utc).toDateString() !== dateKey) || messageGroupKey(next) !== messageGroupKey(m);

    const rowClass = m.role === 'staff' ? 'inbox-msg-row-staff' : m.role === 'assistant' ? 'inbox-msg-row-assistant' : 'inbox-msg-row-user';
    const bubbleClass = m.role === 'staff' ? 'inbox-msg-staff' : m.role === 'assistant' ? 'inbox-msg-assistant' : 'inbox-msg-user';
    const sender = isGroupStart ? messageSenderLabel(m) : null;
    const hasImage = m.attachment_type === 'image' && m.attachment_url;
    // '[Photo]' is just the placeholder Content the webhook stamps on an image with no caption
    // (ChatbotMessages.Content is NOT NULL) - skip showing it as redundant text under the image.
    const showText = m.content && m.content !== '[Photo]';
    // Claude's vision pass (extractPaymentDetails in the webhook) flags this as a likely payment
    // screenshot - a SUGGESTION only, never auto-applied to any order's payments. Staff confirms by
    // clicking through to the Add Payment form (see useDetectedPayment below).
    const hasDetectedPayment = m.detected_payment_amount !== null && m.detected_payment_amount !== undefined;
    const timeLabel = m.created_at_utc ? formatMessageTime(m.created_at_utc) : '';
    const statusLabel = messageStatusLabel(m);

    // .inbox-msg uses white-space:pre-wrap so a customer/bot's OWN line breaks render correctly -
    // which also means any incidental newlines/indentation from a multi-line template literal
    // would render as extra blank lines inside the bubble. So its inner content is built as a
    // single concatenated string with no embedded template-literal whitespace, unlike the row
    // wrapper around it (not pre-wrap, safe to format normally).
    const imageHtml = hasImage
      ? `<a href="${escapeHtml(m.attachment_url)}" target="_blank" rel="noopener"><img class="inbox-msg-image" src="${escapeHtml(m.attachment_url)}" alt="Photo sent by customer"></a>`
      : '';
    const textHtml = showText ? escapeHtml(m.content) : '';
    const paymentHtml = hasDetectedPayment
      ? '<div class="inbox-payment-detected">' +
        '<div class="inbox-payment-detected-title">Detected Payment (unconfirmed)</div>' +
        `<div>Amount: ${Number(m.detected_payment_amount).toFixed(2)}</div>` +
        (m.detected_payment_method ? `<div>Method: ${escapeHtml(m.detected_payment_method)}</div>` : '') +
        (m.detected_payment_reference ? `<div>Ref: ${escapeHtml(m.detected_payment_reference)}</div>` : '') +
        (m.detected_payment_sender_name ? `<div>From: ${escapeHtml(m.detected_payment_sender_name)}</div>` : '') +
        `<button type="button" class="btn btn-secondary btn-sm inbox-use-payment-btn" data-amount="${Number(m.detected_payment_amount)}" data-method="${escapeHtml(m.detected_payment_method || '')}" data-reference="${escapeHtml(m.detected_payment_reference || '')}">Use in Add Payment</button>` +
        '</div>'
      : '';
    const bubbleHtml = `<div class="inbox-msg ${bubbleClass}">${imageHtml}${textHtml}${paymentHtml}</div>`;

    parts.push(`
      <div class="inbox-msg-row ${rowClass}${isGroupStart ? ' inbox-msg-group-start' : ''}">
        ${sender ? `<span class="inbox-msg-sender">${escapeHtml(sender)}</span>` : ''}
        ${bubbleHtml}
        ${isGroupEnd ? `<div class="inbox-msg-meta">${escapeHtml(timeLabel)}${statusLabel}</div>` : ''}
      </div>
    `);
  });

  messagesEl.innerHTML = parts.join('');

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
  autoResizeReplyInput();
  setPendingReplyImages([]);
  toggleQuickRepliesPanel(false);
  toggleProductLookupPanel(false);
  toggleMediaLibraryPanel(false);
  resetProductLookup();

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

// One-time (safe to re-run) pull of Page conversation history via the Conversations Graph API -
// see supabase/functions/facebook-conversations-backfill. Mainly useful while pages_messaging is
// still awaiting Meta App Review (the live webhook only fires for Testers/Admins until then) or
// to catch anything that happened before the webhook existed at all.
async function importFacebookHistory() {
  const btn = document.getElementById('importHistoryBtn');
  const statusEl = document.getElementById('importHistoryStatus');

  if (!confirm('Import conversation history from the Facebook Page? This can take a while for a large inbox, and is safe to run more than once.')) return;

  btn.disabled = true;
  statusEl.classList.remove('hidden');
  statusEl.textContent = 'Importing... this may take a minute.';

  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/facebook-conversations-backfill`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password
      })
    });

    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      statusEl.textContent = `Import failed: ${result.error || response.status}`;
      return;
    }

    let summary = `Imported ${result.conversationsSeen} conversation(s), ${result.messagesProcessed} message(s), ${result.imagesStored} photo(s).`;
    if (result.note) summary += ` ${result.note}`;
    statusEl.textContent = summary;
    await loadConversations();
  } catch (err) {
    statusEl.textContent = `Import failed: ${err instanceof Error ? err.message : 'network error'}`;
  } finally {
    btn.disabled = false;
  }
}

// Core send path shared by Enter-to-send in the textarea, a quick-reply/product-list pick, an
// ad-hoc attachment, and the Like button below - all are "staff sends this to the customer right
// now", just with a different source/payload. `images` accepts plain URL strings (Quick Reply/
// Product List - no Storage object we own to clean up later) or {url, path} objects (an ad-hoc
// attachment - path lets the server record AttachmentPath so the existing 60-day cleanup cron can
// delete it). `like` sends Messenger's own native thumbs-up sticker instead of text/images - see
// chatbot-staff-reply's LIKE_STICKER_ID. Returns true on success (caller decides what to clear/
// reset).
async function sendMessageToCustomer(message, images, like) {
  const errorEl = document.getElementById('replyErrorEl');
  errorEl.classList.add('hidden');
  const normalized = normalizePendingImages(images);
  if (!selectedPsid || (!message && normalized.length === 0 && !like)) return false;

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
        message,
        images: normalized,
        like: !!like
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
      return false;
    }

    await loadConversations();
    const conv = conversations.find((c) => c.psid === selectedPsid);
    if (conv) renderThreadHeader(conv);
    await loadMessages(selectedPsid);
    return true;
  } catch (err) {
    errorEl.textContent = err instanceof Error ? err.message : 'Could not reach the send function.';
    errorEl.classList.remove('hidden');
    return false;
  }
}

// Set when a quick reply/product photo (or an ad-hoc attachment) is loaded into the textbox (see
// useQuickReply/onAttachmentFileChange below) - held here rather than on the textarea itself since a
// <textarea> has nowhere to carry a second value, and sent alongside whatever text is typed when
// Send is actually pressed. Each entry is {url, path, type} - path is only non-null for an ad-hoc
// attachment (see onAttachmentFileChange), letting it be recorded as ChatbotMessages.AttachmentPath
// so the existing 60-day cleanup cron can delete that Storage object later; a Quick Reply/Product
// List image has no path, since those live in permanent/external storage the cron shouldn't touch.
// type is 'image' (default) or 'video' - only an ad-hoc attachment can be a video (see
// ATTACHMENT_ACCEPTED_TYPES) - and decides both how it's previewed here and what Facebook attachment
// type chatbot-staff-reply sends it as.
let pendingReplyImageUrls = [];

// Accepts plain URL strings (Quick Reply/Product List images) or {url, path, type} objects (ad-hoc
// attachments) and normalizes to the latter, dropping anything without a usable url.
function normalizePendingImages(images) {
  return (Array.isArray(images) ? images : [])
    .map((img) => (typeof img === 'string' ? { url: img, path: null, type: 'image' } : img))
    .filter((img) => img && typeof img.url === 'string' && img.url)
    .map((img) => ({ url: img.url, path: img.path ?? null, type: img.type === 'video' ? 'video' : 'image' }));
}

// Grows the reply textbox to fit a long quick reply (or anything typed/pasted) and shrinks it back
// down for a short one, capped at REPLY_INPUT_MAX_HEIGHT (scrolls internally past that) - per direct
// request, rather than a fixed 2-row box that leaves a long quick reply mostly hidden.
const REPLY_INPUT_MAX_HEIGHT = 220;

function autoResizeReplyInput() {
  const input = document.getElementById('replyInput');
  input.style.height = 'auto';
  const newHeight = Math.min(input.scrollHeight, REPLY_INPUT_MAX_HEIGHT);
  input.style.height = newHeight + 'px';
  input.style.overflowY = input.scrollHeight > REPLY_INPUT_MAX_HEIGHT ? 'auto' : 'hidden';
}

function setPendingReplyImages(images) {
  pendingReplyImageUrls = normalizePendingImages(images);
  const wrap = document.getElementById('pendingAttachmentEl');
  const listEl = document.getElementById('pendingAttachmentList');

  if (pendingReplyImageUrls.length === 0) {
    wrap.classList.add('hidden');
    listEl.innerHTML = '';
    return;
  }

  wrap.classList.remove('hidden');
  listEl.innerHTML = pendingReplyImageUrls.map((img, i) => `
    <div class="qr-image-thumb-wrap">
      ${img.type === 'video'
        ? '<span class="qr-image-thumb-video-placeholder">&#127909;</span>'
        : `<img src="${escapeHtml(img.url)}" alt="" />`}
      <button type="button" class="qr-image-thumb-remove" data-index="${i}" title="Remove this ${img.type === 'video' ? 'video' : 'photo'}">&times;</button>
    </div>
  `).join('');
  listEl.querySelectorAll('.qr-image-thumb-remove').forEach((btn) => {
    btn.addEventListener('click', () => {
      const next = pendingReplyImageUrls.slice();
      next.splice(Number(btn.dataset.index), 1);
      setPendingReplyImages(next);
    });
  });
}

// Per direct request: no more explicit Send button for typed text - Enter (see the replyInput
// keydown listener in init()) is the only way to send it now, same as most chat apps.
async function sendReply() {
  const input = document.getElementById('replyInput');
  const message = input.value.trim();
  const images = pendingReplyImageUrls;
  if (!message && images.length === 0) return;

  input.disabled = true;
  const ok = await sendMessageToCustomer(message, images);
  input.disabled = false;
  if (ok) {
    input.value = '';
    autoResizeReplyInput();
    setPendingReplyImages([]);
  }
  input.focus();
}

// The button that replaced Send in the toolbar - per direct request, matches Messenger's own
// composer: a filled thumbs-up that sends Facebook's native "like" sticker on its own, independent
// of whatever text/photos might currently be sitting in the box (those still only go out via Enter).
async function sendLike() {
  const btn = document.getElementById('likeBtn');
  btn.disabled = true;
  await sendMessageToCustomer('', [], true);
  btn.disabled = false;
}

// Ad-hoc attachment - per direct request, a generic "attach a photo (or, per direct follow-up,
// video) from my device" feature alongside Quick Reply/Product list, for a one-off file that isn't a
// reusable template or catalog item. Reuses the same pendingReplyImageUrls staging area/UI as those
// two - once uploaded, an attachment behaves identically to one picked from a Quick Reply (shown in
// the same removable-thumbnail strip, sent alongside whatever text is typed).
//
// 25MB matches the chatbot-attachments bucket's own limit (supabase_chatbot_attachment_video_
// support.sql) - Facebook's own documented cap for a Send API attachment delivered by URL.
const ATTACHMENT_MAX_BYTES = 25 * 1024 * 1024;

async function onAttachmentFileChange() {
  const input = document.getElementById('attachmentFileInput');
  const errorEl = document.getElementById('replyErrorEl');
  const btn = document.getElementById('toggleAttachmentBtn');
  const files = Array.from(input.files || []);
  input.value = '';
  if (files.length === 0) return;

  errorEl.classList.add('hidden');

  const oversized = files.find((f) => f.size > ATTACHMENT_MAX_BYTES);
  if (oversized) {
    errorEl.textContent = `"${oversized.name}" is too large - max 25 MB per file.`;
    errorEl.classList.remove('hidden');
    return;
  }

  btn.disabled = true;
  const uploaded = [];
  try {
    for (const file of files) {
      const type = file.type.startsWith('video/') ? 'video' : 'image';

      const { data: uploadRows, error: signError } = await supabaseClient.rpc('admin_create_chatbot_attachment_upload', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_file_name: file.name
      });
      const uploadInfo = uploadRows && uploadRows[0];
      if (signError || !uploadInfo) throw signError || new Error('Could not prepare upload.');

      const { error: uploadError } = await supabaseClient.storage
        .from('chatbot-attachments')
        .uploadToSignedUrl(uploadInfo.storage_path, uploadInfo.upload_token, file);
      if (uploadError) throw uploadError;

      const { data: signedUrl, error: urlError } = await supabaseClient.rpc('admin_get_chatbot_attachment_signed_url', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_storage_path: uploadInfo.storage_path
      });
      if (urlError || !signedUrl) throw urlError || new Error('Could not prepare file for sending.');

      // path is kept alongside the url (unlike a Quick Reply/Product List image) so the eventual
      // send records ChatbotMessages.AttachmentPath - this is a one-off file in the private
      // chatbot-attachments bucket, and the existing 60-day cleanup cron needs that path to know
      // which Storage object to delete later. type tells chatbot-staff-reply whether to send it to
      // Facebook as an 'image' or 'video' attachment.
      uploaded.push({ url: signedUrl, path: uploadInfo.storage_path, type });
    }
  } catch (err) {
    errorEl.textContent = err?.message || 'Could not attach file.';
    errorEl.classList.remove('hidden');
  }

  btn.disabled = false;
  if (uploaded.length > 0) {
    setPendingReplyImages([...pendingReplyImageUrls, ...uploaded]);
  }
}

// Media Library - per direct request ("a compilation of images and videos saved so they can resend
// it to the customer when needed"), mirroring the "Media" icon in Facebook's own Page inbox toolbar.
// A plain, growing library of reusable photos/videos (no label/text attached, unlike a Quick Reply) -
// staff pick one or several, which load into the reply box for review (same pendingReplyImageUrls
// staging area as everything else), never sent instantly. Library items live in the permanent public
// chatbot-media-library bucket (supabase_chatbot_media_library.sql), so - same as a Quick Reply/
// Product List image - they're staged with path: null, keeping them out of the 60-day ad-hoc-
// attachment cleanup cron, which only ever touches chatbot-attachments.
let mediaLibraryItems = [];
let mediaLibrarySelected = new Set();

function toggleMediaLibraryPanel(show) {
  const panel = document.getElementById('mediaLibraryPanel');
  const btn = document.getElementById('toggleMediaLibraryBtn');
  const willShow = show === undefined ? panel.classList.contains('hidden') : show;

  panel.classList.toggle('hidden', !willShow);
  btn.classList.toggle('active', willShow);
  if (willShow) {
    toggleQuickRepliesPanel(false);
    toggleProductLookupPanel(false);
    loadMediaLibrary();
  } else {
    mediaLibrarySelected.clear();
  }
}

async function loadMediaLibrary() {
  const gridEl = document.getElementById('mediaLibraryGrid');
  const { data, error } = await supabaseClient.rpc('admin_list_chatbot_media_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    gridEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }

  mediaLibraryItems = data || [];
  renderMediaLibraryGrid();
}

function renderMediaLibraryGrid() {
  const gridEl = document.getElementById('mediaLibraryGrid');
  const countEl = document.getElementById('mediaLibrarySelectedCount');
  countEl.textContent = `${mediaLibrarySelected.size} selected`;

  if (mediaLibraryItems.length === 0) {
    gridEl.innerHTML = '<div class="inbox-empty-state">No media saved yet - click + Add.</div>';
    return;
  }

  gridEl.innerHTML = mediaLibraryItems.map((item) => `
    <div class="inbox-media-library-item${mediaLibrarySelected.has(item.id) ? ' selected' : ''}" data-id="${item.id}">
      <span class="inbox-media-library-item-check">&#10003;</span>
      ${item.media_type === 'video'
        ? '<span class="inbox-media-library-video-placeholder">&#127909;</span>'
        : `<img src="${escapeHtml(item.media_url)}" alt="" />`}
      <button type="button" class="inbox-media-library-item-remove" data-id="${item.id}" title="Remove from library">&times;</button>
    </div>
  `).join('');

  gridEl.querySelectorAll('.inbox-media-library-item').forEach((el) => {
    el.addEventListener('click', () => toggleMediaLibraryItemSelected(Number(el.dataset.id)));
  });
  gridEl.querySelectorAll('.inbox-media-library-item-remove').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      deleteMediaLibraryItem(Number(btn.dataset.id));
    });
  });
}

function toggleMediaLibraryItemSelected(id) {
  if (mediaLibrarySelected.has(id)) {
    mediaLibrarySelected.delete(id);
  } else {
    mediaLibrarySelected.add(id);
  }
  renderMediaLibraryGrid();
}

async function deleteMediaLibraryItem(id) {
  if (!confirm('Remove this item from the media library?')) return;

  const { error } = await supabaseClient.rpc('admin_delete_chatbot_media_item', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_media_id: id
  });
  if (error) {
    alert(`Could not remove: ${error.message}`);
    return;
  }

  mediaLibrarySelected.delete(id);
  await loadMediaLibrary();
}

async function onMediaLibraryFileChange() {
  const input = document.getElementById('mediaLibraryFileInput');
  const errorEl = document.getElementById('mediaLibraryError');
  const addBtn = document.getElementById('addMediaLibraryBtn');
  const files = Array.from(input.files || []);
  input.value = '';
  if (files.length === 0) return;

  errorEl.classList.add('hidden');

  const oversized = files.find((f) => f.size > ATTACHMENT_MAX_BYTES);
  if (oversized) {
    errorEl.textContent = `"${oversized.name}" is too large - max 25 MB per file.`;
    errorEl.classList.remove('hidden');
    return;
  }

  addBtn.disabled = true;
  try {
    for (const file of files) {
      const type = file.type.startsWith('video/') ? 'video' : 'image';

      const { data: uploadRows, error: signError } = await supabaseClient.rpc('admin_create_chatbot_media_upload', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_file_name: file.name
      });
      const uploadInfo = uploadRows && uploadRows[0];
      if (signError || !uploadInfo) throw signError || new Error('Could not prepare upload.');

      const { error: uploadError } = await supabaseClient.storage
        .from('chatbot-media-library')
        .uploadToSignedUrl(uploadInfo.storage_path, uploadInfo.upload_token, file);
      if (uploadError) throw uploadError;

      const { error: addError } = await supabaseClient.rpc('admin_add_chatbot_media_item', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_storage_path: uploadInfo.storage_path,
        p_media_url: uploadInfo.public_url,
        p_media_type: type,
        p_file_name: file.name
      });
      if (addError) throw addError;
    }
  } catch (err) {
    errorEl.textContent = err?.message || 'Could not add to media library.';
    errorEl.classList.remove('hidden');
  }

  addBtn.disabled = false;
  await loadMediaLibrary();
}

// Adds every currently-checked library item into the reply box's pending-attachment strip (same
// staging area a Quick Reply's photo(s) load into) - path: null so, same as a Quick Reply/Product
// List image, it's never mistaken for a one-off attachment the cleanup cron should delete.
function useMediaLibrarySelection() {
  const selected = mediaLibraryItems.filter((item) => mediaLibrarySelected.has(item.id));
  if (selected.length === 0) return;

  const toAdd = selected.map((item) => ({ url: item.media_url, path: null, type: item.media_type }));
  setPendingReplyImages([...pendingReplyImageUrls, ...toAdd]);
  mediaLibrarySelected.clear();
  toggleMediaLibraryPanel(false);
  document.getElementById('replyInput').focus();
}

// Quick Replies: a staff-managed, fully-customizable library of canned messages (see
// supabase_chatbot_quick_replies.sql / admin_list_chatbot_quick_replies) - clicking the icon shows
// the list; clicking an item sends it to the customer immediately, no extra typing or confirmation
// (matches Meta's own "Quick reply" composer icon behavior). Not to be confused with Facebook's own
// quick_reply BUTTONS feature (tappable options shown to the CUSTOMER) - this is purely a staff-side
// shortcut for things staff type often.
let quickReplies = [];

// admin_list_chatbot_quick_replies returns image_urls as an array of {id, image_url} objects
// (supabase_chatbot_quick_reply_multi_images.sql) - this pulls out just the plain URL strings,
// which is all the Send API / <img src> need.
function qrImageUrls(q) {
  return Array.isArray(q.image_urls) ? q.image_urls.map((img) => img.image_url) : [];
}

async function loadQuickReplies() {
  const listEl = document.getElementById('quickRepliesList');
  listEl.innerHTML = '<div class="inbox-empty-state">Loading...</div>';

  const { data, error } = await supabaseClient.rpc('admin_list_chatbot_quick_replies', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }

  quickReplies = data || [];
  renderQuickRepliesList();
  renderManageQuickRepliesList();
}

// Table layout (#, Shortcut, Topic, Message) matching Meta's own "Quick reply template" picker in
// Business Suite, per direct request to mirror that UI - "Topic" here shows the first photo
// thumbnail when the quick reply has one or more (with a "+N" badge if there's more than one), or a
// placeholder icon otherwise, since we don't have a separate topic/category concept of our own.
function renderQuickRepliesList() {
  const listEl = document.getElementById('quickRepliesList');

  if (quickReplies.length === 0) {
    listEl.innerHTML = '<div class="inbox-empty-state">No quick replies yet - add one below.</div>';
    return;
  }

  const rows = quickReplies.map((q, i) => {
    const urls = qrImageUrls(q);
    const topicCell = urls.length === 0
      ? '<span class="inbox-quick-reply-topic-placeholder">&#128172;</span>'
      : `<span class="inbox-quick-reply-thumb-wrap"><img class="inbox-quick-reply-thumb" src="${escapeHtml(urls[0])}" alt="" />${urls.length > 1 ? `<span class="inbox-quick-reply-thumb-count">+${urls.length - 1}</span>` : ''}</span>`;
    return `
    <tr data-id="${q.id}">
      <td class="inbox-quick-reply-index">${i + 1}.</td>
      <td class="inbox-quick-reply-shortcut">${escapeHtml(q.label)}</td>
      <td class="inbox-quick-reply-topic">${topicCell}</td>
      <td class="inbox-quick-reply-message">${escapeHtml(q.message_text || (urls.length > 0 ? '(photo only)' : ''))}</td>
      <td><button type="button" class="inbox-quick-reply-delete" data-id="${q.id}" title="Delete this quick reply">&times;</button></td>
    </tr>
  `;
  }).join('');

  listEl.innerHTML = `
    <table>
      <thead>
        <tr>
          <th></th>
          <th>Shortcut</th>
          <th>Topic</th>
          <th>Message</th>
          <th></th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>
  `;

  listEl.querySelectorAll('tbody tr').forEach((el) => {
    el.addEventListener('click', (e) => {
      if (e.target.closest('.inbox-quick-reply-delete')) return;
      const q = quickReplies.find((qr) => String(qr.id) === el.dataset.id);
      if (q) useQuickReply(q.message_text, qrImageUrls(q));
    });
  });

  listEl.querySelectorAll('.inbox-quick-reply-delete').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      deleteQuickReply(btn.dataset.id);
    });
  });
}

// Per direct request: picking a quick reply loads it into the textbox for review/editing instead of
// sending it straight away - staff can tweak the text (or remove any of its photos) before actually
// hitting Send, same as typing a reply normally.
function useQuickReply(messageText, imageUrls) {
  toggleQuickRepliesPanel(false);
  const input = document.getElementById('replyInput');
  input.value = messageText || '';
  autoResizeReplyInput();
  setPendingReplyImages(imageUrls || []);
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

const QUICK_REPLY_IMAGE_MAX_BYTES = 5 * 1024 * 1024;

async function addQuickReply() {
  const labelInput = document.getElementById('newQuickReplyLabel');
  const textInput = document.getElementById('newQuickReplyText');
  const fileInput = document.getElementById('newQuickReplyImage');
  const errorEl = document.getElementById('quickRepliesAddError');
  const addBtn = document.getElementById('addQuickReplyBtn');
  errorEl.classList.add('hidden');

  const label = labelInput.value.trim();
  const messageText = textInput.value.trim();
  const file = fileInput.files && fileInput.files[0];

  if (!label || (!messageText && !file)) {
    errorEl.textContent = 'Add a label, and either a message or a photo.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (file && file.size > QUICK_REPLY_IMAGE_MAX_BYTES) {
    errorEl.textContent = 'That photo is too large - max 5 MB.';
    errorEl.classList.remove('hidden');
    return;
  }

  addBtn.disabled = true;
  addBtn.textContent = 'Saving...';
  try {
    const { data: newId, error: upsertError } = await supabaseClient.rpc('admin_upsert_chatbot_quick_reply', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_id: null,
      p_label: label,
      p_message_text: messageText
    });
    if (upsertError) throw upsertError;

    if (file) {
      const { data: uploadRows, error: signError } = await supabaseClient.rpc('admin_create_quick_reply_image_upload', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_file_name: file.name
      });
      const uploadInfo = uploadRows && uploadRows[0];
      if (signError || !uploadInfo) throw signError || new Error('Could not prepare photo upload.');

      const { error: uploadError } = await supabaseClient.storage
        .from('quick-reply-images')
        .uploadToSignedUrl(uploadInfo.storage_path, uploadInfo.upload_token, file);
      if (uploadError) throw uploadError;

      const { error: addImageError } = await supabaseClient.rpc('admin_add_chatbot_quick_reply_image', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_quick_reply_id: newId,
        p_image_path: uploadInfo.storage_path,
        p_image_url: uploadInfo.public_url
      });
      if (addImageError) throw addImageError;
    }
  } catch (err) {
    errorEl.textContent = err?.message || 'Could not save quick reply.';
    errorEl.classList.remove('hidden');
    addBtn.disabled = false;
    addBtn.textContent = '+ Add Quick Reply';
    return;
  }
  addBtn.disabled = false;
  addBtn.textContent = '+ Add Quick Reply';

  labelInput.value = '';
  fileInput.value = '';
  textInput.value = '';
  await loadQuickReplies();
}

async function deleteQuickReply(id) {
  if (!confirm('Delete this quick reply?')) return;

  const { error } = await supabaseClient.rpc('admin_delete_chatbot_quick_reply', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_id: Number(id)
  });

  if (error) {
    alert(`Could not delete quick reply: ${error.message}`);
    return;
  }

  if (editingQuickReplyId !== null && String(editingQuickReplyId) === String(id)) {
    resetManageQuickReplyForm();
  }
  await loadQuickReplies();
}

// show: true to open (and load the latest list), false to close, omitted to toggle.
function toggleQuickRepliesPanel(show) {
  const panel = document.getElementById('quickRepliesPanel');
  const btn = document.getElementById('toggleQuickRepliesBtn');
  const willShow = show === undefined ? panel.classList.contains('hidden') : show;

  panel.classList.toggle('hidden', !willShow);
  btn.classList.toggle('active', willShow);
  if (willShow) {
    toggleProductLookupPanel(false);
    toggleMediaLibraryPanel(false);
    loadQuickReplies();
  }
}

// Product list lookup - per direct request, mirrors Pancake's own "search products, check several,
// hit Send" panel. Reuses public_search_items (sql/supabase_chatbot_search_items_variants.sql,
// latest definition - same as the Create Order tab's own product search further up this file, plus
// a has_variants flag) - anon-granted, no admin session needed for the search itself.
//
// Per direct follow-up request, a product with variants (e.g. different sizes/colors) can't be
// selected directly - it expands (click to toggle, via public_list_item_variants) into its own
// variant rows instead, each individually checkable, since staff need to send a SPECIFIC variant to
// the customer, not just "the product" with no size/color specified.
//
// productLookupSelected is keyed "item:<code>" or "variant:<variationId>" (not just a bare code) so
// the two id spaces can never collide, and every entry is normalized to the same
// {name, price, quantity_in_stock, images} shape regardless of which kind it is - so
// buildProductListMessage/sendProductList below don't need to know or care which.
let productLookupResults = [];
let productLookupSelected = new Map();
let productLookupSearchDebounce = null;
let productLookupExpanded = new Set(); // item codes currently showing their variant list
let productLookupVariantsCache = new Map(); // item code -> variants array (or undefined = not fetched yet)

// Items."Images"/Variants."Images" are a comma-separated list of URLs (populated by Pancake sync) -
// same helper as docs/js/orderNow.js and docs/js/landing.js, just not shared code between pages.
function firstImageUrl(images) {
  if (!images) return null;
  const first = String(images).split(',')[0].trim();
  return first || null;
}

function toggleProductLookupPanel(show) {
  const panel = document.getElementById('productLookupPanel');
  const btn = document.getElementById('toggleProductLookupBtn');
  const willShow = show === undefined ? panel.classList.contains('hidden') : show;

  panel.classList.toggle('hidden', !willShow);
  btn.classList.toggle('active', willShow);
  if (willShow) {
    toggleQuickRepliesPanel(false);
    toggleMediaLibraryPanel(false);
  }
}

function onProductLookupSearchInput(term) {
  clearTimeout(productLookupSearchDebounce);
  productLookupSearchDebounce = setTimeout(() => runProductLookupSearch(term.trim()), 300);
}

async function runProductLookupSearch(term) {
  const listEl = document.getElementById('productLookupList');
  if (!term) {
    productLookupResults = [];
    listEl.innerHTML = '<div class="inbox-empty-state">Type to search products...</div>';
    return;
  }

  listEl.innerHTML = '<div class="inbox-empty-state">Searching...</div>';
  const { data, error } = await supabaseClient.rpc('public_search_items', { p_query: term });

  if (error) {
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }

  productLookupResults = data || [];
  renderProductLookupList();
}

function productLookupThumbHtml(images) {
  const img = firstImageUrl(images);
  return img
    ? `<img class="inbox-product-lookup-thumb" src="${escapeHtml(img)}" alt="" />`
    : '<span class="inbox-product-lookup-thumb-placeholder">&#128230;</span>';
}

function productLookupStockLabel(quantityInStock) {
  const inStock = Number(quantityInStock || 0) > 0;
  return { inStock, label: inStock ? `${quantityInStock} left` : 'Out of stock' };
}

function renderProductLookupList() {
  const listEl = document.getElementById('productLookupList');

  if (productLookupResults.length === 0) {
    listEl.innerHTML = '<div class="inbox-empty-state">No matching products.</div>';
    return;
  }

  listEl.innerHTML = productLookupResults.map((item) => renderProductLookupItemHtml(item)).join('');

  listEl.querySelectorAll('.inbox-product-lookup-parent').forEach((el) => {
    el.addEventListener('click', () => toggleProductLookupExpand(el.dataset.expandCode));
  });
  listEl.querySelectorAll('.inbox-product-lookup-checkbox').forEach((cb) => {
    cb.addEventListener('change', () => onProductLookupCheckboxChange(cb));
  });
  updateProductLookupSelectedCount();
}

function renderProductLookupItemHtml(item) {
  if (item.has_variants) {
    const expanded = productLookupExpanded.has(item.code);
    return `
      <div class="inbox-product-lookup-group">
        <div class="inbox-product-lookup-row inbox-product-lookup-parent" data-expand-code="${escapeHtml(item.code)}">
          <span class="inbox-product-lookup-chevron">${expanded ? '▾' : '▸'}</span>
          ${productLookupThumbHtml(item.images)}
          <span class="inbox-product-lookup-info">
            <span class="inbox-product-lookup-name">${escapeHtml(item.name)}</span>
            <span class="inbox-product-lookup-meta"><span class="muted">Tap to choose a variant</span></span>
          </span>
        </div>
        ${expanded ? renderProductLookupVariantsHtml(productLookupVariantsCache.get(item.code)) : ''}
      </div>
    `;
  }

  const { inStock, label } = productLookupStockLabel(item.quantity_in_stock);
  const key = `item:${item.code}`;
  const checked = productLookupSelected.has(key) ? 'checked' : '';
  return `
    <label class="inbox-product-lookup-row">
      <input type="checkbox" class="inbox-product-lookup-checkbox" data-key="${escapeHtml(key)}" ${checked} />
      ${productLookupThumbHtml(item.images)}
      <span class="inbox-product-lookup-info">
        <span class="inbox-product-lookup-name">${escapeHtml(item.name)}</span>
        <span class="inbox-product-lookup-meta">
          <span class="inbox-product-lookup-stock${inStock ? '' : ' out-of-stock'}">${escapeHtml(label)}</span>
          <span class="inbox-product-lookup-price">&#8369;${Number(item.price || 0).toLocaleString()}</span>
        </span>
      </span>
    </label>
  `;
}

function renderProductLookupVariantsHtml(variants) {
  if (variants === undefined) {
    return '<div class="inbox-product-lookup-variants"><div class="inbox-empty-state">Loading variants...</div></div>';
  }
  if (variants.length === 0) {
    return '<div class="inbox-product-lookup-variants"><div class="inbox-empty-state">No variants found.</div></div>';
  }
  const rows = variants.map((v) => {
    const { inStock, label } = productLookupStockLabel(v.quantity_in_stock);
    const key = `variant:${v.variation_id}`;
    const checked = productLookupSelected.has(key) ? 'checked' : '';
    return `
      <label class="inbox-product-lookup-row inbox-product-lookup-variant-row">
        <input type="checkbox" class="inbox-product-lookup-checkbox" data-key="${escapeHtml(key)}" ${checked} />
        ${productLookupThumbHtml(v.images)}
        <span class="inbox-product-lookup-info">
          <span class="inbox-product-lookup-name">${escapeHtml(v.variant_name)}</span>
          ${v.sku ? `<span class="inbox-product-lookup-sku">${escapeHtml(v.sku)}</span>` : ''}
          <span class="inbox-product-lookup-meta">
            <span class="inbox-product-lookup-stock${inStock ? '' : ' out-of-stock'}">${escapeHtml(label)}</span>
            <span class="inbox-product-lookup-price">&#8369;${Number(v.price || 0).toLocaleString()}</span>
          </span>
        </span>
      </label>
    `;
  }).join('');
  return `<div class="inbox-product-lookup-variants">${rows}</div>`;
}

async function toggleProductLookupExpand(code) {
  if (productLookupExpanded.has(code)) {
    productLookupExpanded.delete(code);
    renderProductLookupList();
    return;
  }

  productLookupExpanded.add(code);
  renderProductLookupList(); // shows "Loading variants..." immediately

  if (!productLookupVariantsCache.has(code)) {
    const { data, error } = await supabaseClient.rpc('public_list_item_variants', { p_item_code: code });
    productLookupVariantsCache.set(code, error ? [] : (data || []));
  }
  renderProductLookupList();
}

function onProductLookupCheckboxChange(cb) {
  const key = cb.dataset.key;
  if (cb.checked) {
    const entry = resolveProductLookupEntry(key);
    if (entry) productLookupSelected.set(key, entry);
  } else {
    productLookupSelected.delete(key);
  }
  updateProductLookupSelectedCount();
}

// Normalizes a selected item or variant into the same {name, price, quantity_in_stock, images}
// shape, so the send path below never needs to know which kind of row it came from.
function resolveProductLookupEntry(key) {
  const separatorIndex = key.indexOf(':');
  const kind = key.slice(0, separatorIndex);
  const id = key.slice(separatorIndex + 1);

  if (kind === 'item') {
    const item = productLookupResults.find((r) => r.code === id);
    if (!item) return null;
    return { name: item.name, price: item.price, quantity_in_stock: item.quantity_in_stock, images: item.images };
  }

  if (kind === 'variant') {
    for (const [itemCode, variants] of productLookupVariantsCache.entries()) {
      const v = (variants || []).find((vv) => vv.variation_id === id);
      if (v) {
        const parent = productLookupResults.find((r) => r.code === itemCode);
        // VariantName alone is frequently IDENTICAL across a product's variants (e.g. two sealant
        // colors both named "AQ-028 - STANDARD-75G (...)") - only the SKU actually distinguishes
        // them (per direct report, staff couldn't tell which sealant color was selected), so it's
        // appended here whenever present rather than relying on VariantName alone.
        const variantLabel = v.sku ? `${v.variant_name} - ${v.sku}` : v.variant_name;
        const name = parent ? `${parent.name} (${variantLabel})` : variantLabel;
        return { name, price: v.price, quantity_in_stock: v.quantity_in_stock, images: v.images };
      }
    }
  }

  return null;
}

function updateProductLookupSelectedCount() {
  document.getElementById('productLookupSelectedCount').textContent = `${productLookupSelected.size} selected`;
}

function resetProductLookup() {
  productLookupResults = [];
  productLookupSelected = new Map();
  productLookupExpanded = new Set();
  productLookupVariantsCache = new Map();
  document.getElementById('productLookupSearchInput').value = '';
  document.getElementById('productLookupList').innerHTML = '<div class="inbox-empty-state">Type to search products...</div>';
  updateProductLookupSelectedCount();
}

// One line per selected product (name, price, stock) - sent as the message text, with each
// product's own photo (if it has one) sent alongside as image_urls, same as a multi-photo Quick
// Reply (see sendMessageToCustomer/chatbot-staff-reply).
function buildProductListMessage(items) {
  return items.map((item) => {
    const inStock = Number(item.quantity_in_stock || 0) > 0;
    const stockLabel = inStock ? `${item.quantity_in_stock} left` : 'Out of stock';
    return `${item.name}\n₱${Number(item.price || 0).toLocaleString()} - ${stockLabel}`;
  }).join('\n\n');
}

async function sendProductList() {
  if (productLookupSelected.size === 0) return;
  const btn = document.getElementById('sendProductListBtn');
  const items = Array.from(productLookupSelected.values());
  const message = buildProductListMessage(items);
  const imageUrls = items.map((item) => firstImageUrl(item.images)).filter(Boolean);

  btn.disabled = true;
  btn.textContent = 'Sending...';
  const ok = await sendMessageToCustomer(message, imageUrls);
  btn.disabled = false;
  btn.textContent = 'Send';

  if (ok) {
    toggleProductLookupPanel(false);
    resetProductLookup();
  }
}

// Manage Quick Replies modal (opened via the pencil icon in the popover header, per direct request
// for a dedicated view to manage the full list) - same underlying quickReplies cache/table as the
// popover, plus an add/edit form the popover itself doesn't have (it only supports quick add +
// click-to-send). editingQuickReplyId is null while adding a new entry, or the id being edited.
let editingQuickReplyId = null;
let existingQrImages = []; // [{id, image_url}] already saved on the entry being edited
let stagedQrFiles = []; // [{file, previewUrl}] newly picked, not yet uploaded (add or edit mode)

function openManageQuickRepliesModal() {
  toggleQuickRepliesPanel(false);
  resetManageQuickReplyForm();
  toggleBulkImportPanel(false);
  document.getElementById('manageQuickRepliesModal').classList.remove('hidden');
  loadQuickReplies();
}

function closeManageQuickRepliesModal() {
  document.getElementById('manageQuickRepliesModal').classList.add('hidden');
}

// Renders both already-saved images (existingQrImages - removing one deletes it for real,
// immediately) and newly staged files not yet uploaded (stagedQrFiles - removing one just drops it
// locally), side by side in the same thumbnail row.
function renderManageQrImages() {
  const row = document.getElementById('manageQrImagesRow');
  const existingHtml = existingQrImages.map((img) => `
    <div class="qr-image-thumb-wrap">
      <img src="${escapeHtml(img.image_url)}" alt="" />
      <button type="button" class="qr-image-thumb-remove" data-existing-id="${img.id}" title="Remove this photo">&times;</button>
    </div>
  `).join('');
  const stagedHtml = stagedQrFiles.map((item, i) => `
    <div class="qr-image-thumb-wrap">
      <img src="${item.previewUrl}" alt="" />
      <button type="button" class="qr-image-thumb-remove" data-staged-index="${i}" title="Remove this photo">&times;</button>
    </div>
  `).join('');
  row.innerHTML = existingHtml + stagedHtml;

  row.querySelectorAll('.qr-image-thumb-remove[data-existing-id]').forEach((btn) => {
    btn.addEventListener('click', () => removeExistingQrImage(Number(btn.dataset.existingId)));
  });
  row.querySelectorAll('.qr-image-thumb-remove[data-staged-index]').forEach((btn) => {
    btn.addEventListener('click', () => removeStagedQrFile(Number(btn.dataset.stagedIndex)));
  });
}

function clearStagedQrFiles() {
  stagedQrFiles.forEach((item) => URL.revokeObjectURL(item.previewUrl));
  stagedQrFiles = [];
}

function removeStagedQrFile(index) {
  const item = stagedQrFiles[index];
  if (item) URL.revokeObjectURL(item.previewUrl);
  stagedQrFiles.splice(index, 1);
  renderManageQrImages();
}

// Deletes an already-saved photo right away (not staged) - it's a real row in
// ChatbotQuickReplyImages, so there's nothing meaningful to "undo" by waiting for Save.
async function removeExistingQrImage(imageId) {
  if (!confirm('Remove this photo?')) return;

  const { error } = await supabaseClient.rpc('admin_delete_chatbot_quick_reply_image', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_image_id: imageId
  });
  if (error) {
    alert(`Could not remove photo: ${error.message}`);
    return;
  }

  existingQrImages = existingQrImages.filter((img) => img.id !== imageId);
  renderManageQrImages();
  await loadQuickReplies();
}

function resetManageQuickReplyForm() {
  editingQuickReplyId = null;
  existingQrImages = [];
  clearStagedQrFiles();
  document.getElementById('manageQrFormTitle').textContent = 'Add Quick Reply';
  document.getElementById('manageQrLabel').value = '';
  document.getElementById('manageQrMessage').value = '';
  document.getElementById('manageQrImage').value = '';
  renderManageQrImages();
  document.getElementById('manageQrError').classList.add('hidden');
  document.getElementById('manageQrCancelEditBtn').classList.add('hidden');
  document.getElementById('manageQrSaveBtn').textContent = '+ Add Quick Reply';
}

function startEditQuickReply(q) {
  editingQuickReplyId = q.id;
  existingQrImages = Array.isArray(q.image_urls) ? q.image_urls.slice() : [];
  clearStagedQrFiles();
  document.getElementById('manageQrFormTitle').textContent = `Edit Quick Reply: ${q.label}`;
  document.getElementById('manageQrLabel').value = q.label || '';
  document.getElementById('manageQrMessage').value = q.message_text || '';
  document.getElementById('manageQrImage').value = '';
  renderManageQrImages();

  document.getElementById('manageQrError').classList.add('hidden');
  document.getElementById('manageQrCancelEditBtn').classList.remove('hidden');
  document.getElementById('manageQrSaveBtn').textContent = 'Save Changes';
  document.getElementById('manageQuickRepliesModal').scrollTop = 0;
}

// Stages newly picked file(s) locally (added to whatever's already staged, so picking files across
// several change events accumulates rather than replaces) - they're only actually uploaded when
// Save is pressed, same as before, just now for any number of files instead of one.
function onManageQrImageChange() {
  const input = document.getElementById('manageQrImage');
  const files = Array.from(input.files || []);
  for (const file of files) {
    stagedQrFiles.push({ file, previewUrl: URL.createObjectURL(file) });
  }
  input.value = '';
  renderManageQrImages();
}

async function saveManageQuickReply() {
  const labelInput = document.getElementById('manageQrLabel');
  const textInput = document.getElementById('manageQrMessage');
  const errorEl = document.getElementById('manageQrError');
  const saveBtn = document.getElementById('manageQrSaveBtn');
  errorEl.classList.add('hidden');

  const label = labelInput.value.trim();
  const messageText = textInput.value.trim();
  const willHaveImage = existingQrImages.length > 0 || stagedQrFiles.length > 0;

  if (!label || (!messageText && !willHaveImage)) {
    errorEl.textContent = 'Add a label, and either a message or a photo.';
    errorEl.classList.remove('hidden');
    return;
  }
  const oversized = stagedQrFiles.find((item) => item.file.size > QUICK_REPLY_IMAGE_MAX_BYTES);
  if (oversized) {
    errorEl.textContent = `"${oversized.file.name}" is too large - max 5 MB per photo.`;
    errorEl.classList.remove('hidden');
    return;
  }

  const savingLabel = editingQuickReplyId ? 'Save Changes' : '+ Add Quick Reply';
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';
  try {
    const { data: quickReplyId, error: upsertError } = await supabaseClient.rpc('admin_upsert_chatbot_quick_reply', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_id: editingQuickReplyId,
      p_label: label,
      p_message_text: messageText
    });
    if (upsertError) throw upsertError;

    for (const item of stagedQrFiles) {
      const { data: uploadRows, error: signError } = await supabaseClient.rpc('admin_create_quick_reply_image_upload', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_file_name: item.file.name
      });
      const uploadInfo = uploadRows && uploadRows[0];
      if (signError || !uploadInfo) throw signError || new Error('Could not prepare photo upload.');

      const { error: uploadError } = await supabaseClient.storage
        .from('quick-reply-images')
        .uploadToSignedUrl(uploadInfo.storage_path, uploadInfo.upload_token, item.file);
      if (uploadError) throw uploadError;

      const { error: addImageError } = await supabaseClient.rpc('admin_add_chatbot_quick_reply_image', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_quick_reply_id: quickReplyId,
        p_image_path: uploadInfo.storage_path,
        p_image_url: uploadInfo.public_url
      });
      if (addImageError) throw addImageError;
    }
  } catch (err) {
    errorEl.textContent = err?.message || 'Could not save quick reply.';
    errorEl.classList.remove('hidden');
    saveBtn.disabled = false;
    saveBtn.textContent = savingLabel;
    return;
  }

  saveBtn.disabled = false;
  resetManageQuickReplyForm();
  await loadQuickReplies();
}

// Bigger, plain-table rendering of the same quickReplies cache (row numbers, Shortcut, a Photo
// thumbnail when present, the full Message text, and Edit/Delete actions) - unlike the popover's
// list, rows here aren't click-to-send, since this view is for management, not composing.
function renderManageQuickRepliesList() {
  const listEl = document.getElementById('manageQuickRepliesList');
  if (!listEl) return;

  if (quickReplies.length === 0) {
    listEl.innerHTML = '<tr><td colspan="5" class="muted">No quick replies yet - add one above.</td></tr>';
    return;
  }

  listEl.innerHTML = quickReplies.map((q, i) => {
    const urls = qrImageUrls(q);
    const photoCell = urls.length === 0
      ? ''
      : `<span class="manage-qr-row-thumb-wrap"><img class="manage-qr-row-thumb" src="${escapeHtml(urls[0])}" alt="" />${urls.length > 1 ? `<span class="manage-qr-row-thumb-count">+${urls.length - 1}</span>` : ''}</span>`;
    return `
    <tr>
      <td>${i + 1}.</td>
      <td><strong>${escapeHtml(q.label)}</strong></td>
      <td>${photoCell}</td>
      <td>${escapeHtml(q.message_text || (urls.length > 0 ? '(photo only)' : ''))}</td>
      <td>
        <div class="manage-qr-row-actions">
          <button type="button" class="manage-qr-edit-btn" data-id="${q.id}" title="Edit this quick reply">
            <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M13.5 2.5 17 6l-9.5 9.5-4 1 1-4Z" stroke-linejoin="round" stroke-linecap="round" /></svg>
          </button>
          <button type="button" class="manage-qr-delete-btn" data-id="${q.id}" title="Delete this quick reply">&times;</button>
        </div>
      </td>
    </tr>
  `;
  }).join('');

  listEl.querySelectorAll('.manage-qr-edit-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const q = quickReplies.find((qr) => String(qr.id) === btn.dataset.id);
      if (q) startEditQuickReply(q);
    });
  });
  listEl.querySelectorAll('.manage-qr-delete-btn').forEach((btn) => {
    btn.addEventListener('click', () => deleteQuickReply(btn.dataset.id));
  });
}

// Bulk Import - confirmed Pancake's own public API has no endpoint to list/export a page's saved
// Quick Reply content (only a send endpoint exists - see
// sql/supabase_debug_pancake_quick_reply_endpoints.sql), so there's no automated pull to build.
// This is the practical fallback: paste several "Label: .../Message: ..." blocks (copied by hand
// from wherever they're being migrated from) separated by a "---" line, and create them all in one
// go instead of one form submission per item. Text only - a photo still needs the form above, added
// per entry, since pasted plain text can't carry an image.
function toggleBulkImportPanel(show) {
  const body = document.getElementById('bulkImportBody');
  const willShow = show === undefined ? body.classList.contains('hidden') : show;
  body.classList.toggle('hidden', !willShow);
  document.getElementById('bulkImportError').classList.add('hidden');
  document.getElementById('bulkImportSuccess').classList.add('hidden');
}

function parseBulkQuickReplies(rawText) {
  const blocks = rawText.split(/^-{3,}\s*$/m).map((b) => b.trim()).filter((b) => b.length > 0);
  const entries = [];
  const errors = [];

  blocks.forEach((block, i) => {
    const labelMatch = block.match(/^label\s*:\s*(.+)$/im);
    const messageMatch = block.match(/^message\s*:\s*([\s\S]*)$/im);
    const label = labelMatch ? labelMatch[1].trim() : '';
    const message = messageMatch ? messageMatch[1].trim() : '';

    if (!label || !message) {
      errors.push(`Entry ${i + 1}: needs both a "Label:" line and a "Message:" line.`);
      return;
    }
    entries.push({ label, message });
  });

  return { entries, errors };
}

async function runBulkImport() {
  const textarea = document.getElementById('bulkImportText');
  const errorEl = document.getElementById('bulkImportError');
  const successEl = document.getElementById('bulkImportSuccess');
  const btn = document.getElementById('runBulkImportBtn');
  errorEl.classList.add('hidden');
  successEl.classList.add('hidden');

  const rawText = textarea.value.trim();
  if (!rawText) {
    errorEl.textContent = 'Paste at least one quick reply first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const { entries, errors } = parseBulkQuickReplies(rawText);
  if (errors.length > 0) {
    errorEl.innerHTML = `Fix these before importing:<br>${errors.map(escapeHtml).join('<br>')}`;
    errorEl.classList.remove('hidden');
    return;
  }

  btn.disabled = true;
  btn.textContent = 'Importing...';
  let successCount = 0;
  const failures = [];
  for (const entry of entries) {
    const { error } = await supabaseClient.rpc('admin_upsert_chatbot_quick_reply', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_id: null,
      p_label: entry.label,
      p_message_text: entry.message
    });
    if (error) {
      failures.push(`${entry.label}: ${error.message}`);
    } else {
      successCount++;
    }
  }
  btn.disabled = false;
  btn.textContent = 'Import All';

  if (failures.length > 0) {
    errorEl.innerHTML = `Imported ${successCount} of ${entries.length}. Failed:<br>${failures.map(escapeHtml).join('<br>')}`;
    errorEl.classList.remove('hidden');
  } else {
    successEl.textContent = `Imported ${successCount} quick ${successCount === 1 ? 'reply' : 'replies'}.`;
    successEl.classList.remove('hidden');
    textarea.value = '';
  }

  await loadQuickReplies();
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
  document.getElementById('importHistoryBtn').addEventListener('click', importFacebookHistory);
  document.getElementById('conversationSearchInput').addEventListener('input', (e) => onConversationSearchInput(e.target.value));
  document.getElementById('toggleQuickRepliesBtn').addEventListener('click', () => toggleQuickRepliesPanel());
  document.getElementById('toggleAttachmentBtn').addEventListener('click', () => document.getElementById('attachmentFileInput').click());
  document.getElementById('attachmentFileInput').addEventListener('change', onAttachmentFileChange);
  document.getElementById('toggleProductLookupBtn').addEventListener('click', () => toggleProductLookupPanel());
  document.getElementById('productLookupSearchInput').addEventListener('input', (e) => onProductLookupSearchInput(e.target.value));
  document.getElementById('sendProductListBtn').addEventListener('click', sendProductList);
  document.getElementById('toggleMediaLibraryBtn').addEventListener('click', () => toggleMediaLibraryPanel());
  document.getElementById('addMediaLibraryBtn').addEventListener('click', () => document.getElementById('mediaLibraryFileInput').click());
  document.getElementById('mediaLibraryFileInput').addEventListener('change', onMediaLibraryFileChange);
  document.getElementById('useMediaLibrarySelectionBtn').addEventListener('click', useMediaLibrarySelection);
  document.getElementById('addQuickReplyBtn').addEventListener('click', addQuickReply);
  document.getElementById('manageQuickRepliesBtn').addEventListener('click', openManageQuickRepliesModal);
  document.getElementById('closeManageQuickRepliesBtn').addEventListener('click', closeManageQuickRepliesModal);
  document.getElementById('manageQrCancelEditBtn').addEventListener('click', resetManageQuickReplyForm);
  document.getElementById('manageQrSaveBtn').addEventListener('click', saveManageQuickReply);
  document.getElementById('manageQrImage').addEventListener('change', onManageQrImageChange);
  document.getElementById('toggleBulkImportBtn').addEventListener('click', () => toggleBulkImportPanel());
  document.getElementById('cancelBulkImportBtn').addEventListener('click', () => toggleBulkImportPanel(false));
  document.getElementById('runBulkImportBtn').addEventListener('click', runBulkImport);
  document.getElementById('likeBtn').addEventListener('click', sendLike);
  document.getElementById('replyInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendReply();
    }
  });
  document.getElementById('replyInput').addEventListener('input', autoResizeReplyInput);

  setupRealtimeInbox();
  await loadConversations();
})();
