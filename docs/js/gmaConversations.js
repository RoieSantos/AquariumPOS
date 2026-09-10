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
          <span class="inbox-conv-psid">${escapeHtml(c.psid)}${badges}</span>
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
    <span style="font-size:12px; font-weight:600;">${escapeHtml(conv.psid)}</span>
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
    return `
      <div class="inbox-msg ${bubbleClass}">
        ${sender ? `<span class="inbox-msg-sender">${escapeHtml(sender)}</span>` : ''}${escapeHtml(m.content)}
      </div>
    `;
  }).join('');
  messagesEl.scrollTop = messagesEl.scrollHeight;
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

  await loadMessages(psid);
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

  await loadConversations();
})();
