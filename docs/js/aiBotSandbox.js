// AI Bot Sandbox page logic (super users only) - a portal-only test conversation with the real
// Messenger bot logic, via the chatbot-sandbox-reply Edge Function (supabase/functions/
// chatbot-sandbox-reply). Built per direct request to test the bot while Meta messaging is
// unavailable/restricted - every side-effecting tool (escalate_to_staff, send_item_image,
// schedule_follow_up, schedule_delivery_date) runs in simulate mode there, so testing here is safe
// even with real order numbers. History lives in its own ChatbotSandboxMessages table (see
// supabase_chatbot_sandbox_tables.sql), one ongoing conversation per staff username, fully separate
// from the real customer inbox (docs/gma-conversations.html).
let currentSession = null;

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function renderMessages(rows) {
  const messagesEl = document.getElementById('sandboxMessagesEl');

  if (!rows || rows.length === 0) {
    messagesEl.innerHTML = '<div class="sandbox-empty-state">No messages yet - type something below as if you were a customer.</div>';
    return;
  }

  messagesEl.innerHTML = rows.map((m) => {
    const bubbleClass = m.role === 'assistant' ? 'sandbox-msg-assistant' : 'sandbox-msg-user';
    return `<div class="sandbox-msg ${bubbleClass}">${escapeHtml(m.content)}</div>`;
  }).join('');
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

async function loadMessages() {
  const messagesEl = document.getElementById('sandboxMessagesEl');
  messagesEl.innerHTML = '<div class="sandbox-empty-state">Loading...</div>';

  const { data, error } = await supabaseClient.rpc('admin_get_chatbot_sandbox_messages', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    messagesEl.innerHTML = `<div class="sandbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }

  renderMessages(data || []);
}

async function sendSandboxMessage() {
  const input = document.getElementById('sandboxInput');
  const btn = document.getElementById('sandboxSendBtn');
  const errorEl = document.getElementById('sandboxErrorEl');
  const message = input.value.trim();
  errorEl.classList.add('hidden');

  if (!message) return;

  btn.disabled = true;
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-sandbox-reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password,
        message
      })
    });

    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      errorEl.textContent = result.error || `Send failed (${response.status}).`;
      errorEl.classList.remove('hidden');
      return;
    }

    input.value = '';
    await loadMessages();
  } catch (err) {
    errorEl.textContent = err instanceof Error ? err.message : 'Could not reach the sandbox function.';
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
  }
}

async function resetSandbox() {
  if (!confirm('Reset this test conversation? This clears your sandbox history only - nothing real is affected.')) return;

  const { error } = await supabaseClient.rpc('admin_reset_chatbot_sandbox', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    alert(`Could not reset: ${error.message}`);
    return;
  }

  await loadMessages();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('AI Bot Sandbox');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to use the AI Bot Sandbox.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('sandboxContent').classList.remove('hidden');
  document.getElementById('resetSandboxBtn').addEventListener('click', resetSandbox);
  document.getElementById('sandboxSendBtn').addEventListener('click', sendSandboxMessage);
  document.getElementById('sandboxInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendSandboxMessage();
    }
  });

  await loadMessages();
})();
