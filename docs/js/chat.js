// Messenger-style DM widget - floating bubble present on every authenticated page (mounted by
// nav.js's renderTopNav so no per-page wiring is needed). See supabase_portal_chat_tables.sql for
// the schema/RPCs and its header comment for why message delivery uses Realtime Broadcast
// (per-conversation channels) instead of postgres_changes.
//
// Groups are not built yet - DMs only for now (see chat conversation with the user about scope).

let chatSession = null;
let chatDirectory = []; // [{ username, display_name }] - everyone else, cached for the lifetime of the tab
let chatDirectoryByUsername = new Map();
let chatConversations = []; // last list_my_chat_conversations() result
let chatOnlineUsernames = new Set(); // from presence sync
let chatOpenConversationId = null; // conversation currently shown in the thread view, if any
let chatPresenceChannel = null;
let chatInboxChannel = null;
const chatConversationChannels = new Map(); // conversationId -> RealtimeChannel
const chatReceipts = new Map(); // conversationId -> { deliveredUpTo: iso|null, seenUpTo: iso|null } for the OTHER participant
const chatLastMineAt = new Map(); // conversationId -> ISO timestamp of the last message *I* sent in it

function chatOtherDisplayName(username) {
  if (!username) return 'Someone';
  const entry = chatDirectoryByUsername.get(username);
  return entry ? entry.display_name : username;
}

function chatUnreadCount() {
  return chatConversations.filter((c) => c.unread).length;
}

function chatUpdateBubbleBadge() {
  const badge = document.getElementById('chatWidgetBadge');
  if (!badge) return;
  const count = chatUnreadCount();
  badge.textContent = count > 9 ? '9+' : String(count);
  badge.classList.toggle('hidden', count === 0);
}

function chatFormatTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  return sameDay
    ? d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
    : d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

function chatEscapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text ?? '';
  return div.innerHTML;
}

// ---------------------------------------------------------------------------
// Data loading

async function chatLoadDirectory() {
  const { data, error } = await supabaseClient.rpc('staff_list_chat_directory', {
    p_admin_username: chatSession.username,
    p_admin_password: chatSession.password
  });
  if (error) throw new Error(error.message);
  chatDirectory = data || [];
  chatDirectoryByUsername = new Map(chatDirectory.map((u) => [u.username, u]));
}

async function chatLoadConversations() {
  const { data, error } = await supabaseClient.rpc('list_my_chat_conversations', {
    p_username: chatSession.username
  });
  if (error) throw new Error(error.message);
  chatConversations = data || [];

  // Join a broadcast channel per conversation so a message sent while the widget is open (but the
  // thread not necessarily focused) still updates the list live - see the SQL file's header
  // comment for why Broadcast (not postgres_changes) carries live messages.
  chatConversations.forEach((c) => chatJoinConversationChannel(c.conversation_id));

  chatRenderConversationList();
  chatUpdateBubbleBadge();
}

// ---------------------------------------------------------------------------
// Realtime: presence ("who's online") + per-conversation broadcast + a personal inbox channel so
// a brand-new conversation someone just started with me shows up without a manual refresh.

function chatSetupPresence() {
  chatPresenceChannel = supabaseClient.channel('presence:portal-staff', {
    config: { presence: { key: chatSession.username } }
  });

  chatPresenceChannel
    .on('presence', { event: 'sync' }, () => {
      chatOnlineUsernames = new Set(Object.keys(chatPresenceChannel.presenceState()));
      chatRenderConversationList();
      if (chatOpenConversationId) chatRenderThreadHeader(chatOpenConversationId);
    })
    .subscribe((status) => {
      if (status === 'SUBSCRIBED') {
        chatPresenceChannel.track({ username: chatSession.username, displayName: chatSession.displayName });
      }
    });
}

function chatSetupInboxChannel() {
  chatInboxChannel = supabaseClient.channel(`chat:inbox:${chatSession.username}`);
  chatInboxChannel
    .on('broadcast', { event: 'new_conversation' }, ({ payload }) => {
      chatJoinConversationChannel(payload.conversationId);
      chatLoadConversations().catch(() => {});
    })
    .subscribe();
}

function chatJoinConversationChannel(conversationId) {
  if (chatConversationChannels.has(conversationId)) return;

  const channel = supabaseClient.channel(`chat:${conversationId}`);
  channel
    .on('broadcast', { event: 'message' }, ({ payload }) => {
      chatHandleIncomingMessage(conversationId, payload);
    })
    .on('broadcast', { event: 'delivered' }, ({ payload }) => {
      chatApplyReceipt(conversationId, 'deliveredUpTo', payload.upTo);
    })
    .on('broadcast', { event: 'seen' }, ({ payload }) => {
      chatApplyReceipt(conversationId, 'seenUpTo', payload.upTo);
    })
    .subscribe();

  chatConversationChannels.set(conversationId, channel);
}

function chatHandleIncomingMessage(conversationId, message) {
  const isOpenAndVisible = chatOpenConversationId === conversationId && chatIsPanelOpen();

  const existing = chatConversations.find((c) => c.conversation_id === conversationId);
  if (existing) {
    existing.last_message = message.body;
    existing.last_message_at = message.createdAtUtc;
    existing.last_message_sender = message.senderUsername;
    existing.unread = !isOpenAndVisible && message.senderUsername !== chatSession.username;
  }
  chatRenderConversationList();
  chatUpdateBubbleBadge();

  // Someone else's message reaching my open tab live means it just got delivered to me - ack it
  // back on the same channel so the sender's thread can flip from "Sent" to "Delivered" instantly.
  if (message.senderUsername !== chatSession.username) {
    chatConversationChannels.get(conversationId)?.send({
      type: 'broadcast',
      event: 'delivered',
      payload: { upTo: message.createdAtUtc }
    });
  }

  if (isOpenAndVisible) {
    chatAppendMessageBubble(message);
    chatMarkConversationRead(conversationId);
  }
}

// ---------------------------------------------------------------------------
// Sent/Delivered/Seen receipts for the last message *I* sent in a conversation. "Seen" is backed
// by ChatConversationMembers."LastReadAtUtc" (persisted, so it survives a reload); "Delivered" is
// live-only via broadcast - there's no persisted counterpart, so it resets to "Sent" on reload
// until either a fresh delivery ack or a "seen" arrives (which implies delivered too).

function chatApplyReceipt(conversationId, field, upToIso) {
  const receipt = chatReceipts.get(conversationId) || { deliveredUpTo: null, seenUpTo: null };
  if (!receipt[field] || new Date(upToIso) > new Date(receipt[field])) {
    receipt[field] = upToIso;
  }
  if (field === 'seenUpTo' && (!receipt.deliveredUpTo || new Date(upToIso) > new Date(receipt.deliveredUpTo))) {
    receipt.deliveredUpTo = upToIso;
  }
  chatReceipts.set(conversationId, receipt);

  if (chatOpenConversationId === conversationId) chatRenderReceiptStatus(conversationId);
}

function chatRenderReceiptStatus(conversationId) {
  const el = document.getElementById('chatThreadReceipt');
  if (!el) return;

  const lastMine = chatLastMineAt.get(conversationId);
  if (!lastMine) {
    el.textContent = '';
    return;
  }

  const receipt = chatReceipts.get(conversationId) || {};
  if (receipt.seenUpTo && new Date(receipt.seenUpTo) >= new Date(lastMine)) {
    el.textContent = `Seen ${chatFormatTime(receipt.seenUpTo)}`;
  } else if (receipt.deliveredUpTo && new Date(receipt.deliveredUpTo) >= new Date(lastMine)) {
    el.textContent = 'Delivered';
  } else {
    el.textContent = 'Sent';
  }
}

// ---------------------------------------------------------------------------
// UI: widget shell (bubble + panel), injected once into <body>.

function chatIsPanelOpen() {
  const panel = document.getElementById('chatWidgetPanel');
  return !!panel && !panel.classList.contains('hidden');
}

function chatBuildWidgetShell() {
  if (document.getElementById('chatWidgetRoot')) return;

  const root = document.createElement('div');
  root.id = 'chatWidgetRoot';
  root.innerHTML = `
    <button id="chatWidgetBubble" class="chat-widget-bubble" type="button" aria-label="Messages">
      💬
      <span id="chatWidgetBadge" class="chat-widget-badge hidden">0</span>
    </button>
    <div id="chatWidgetPanel" class="chat-widget-panel hidden">
      <div id="chatListView" class="chat-view">
        <div class="chat-widget-header">
          <span>Messages</span>
          <div>
            <button id="chatNewBtn" class="chat-icon-btn" type="button" title="New message">✏️</button>
            <button id="chatCloseBtn" class="chat-icon-btn" type="button" title="Close">✕</button>
          </div>
        </div>
        <div id="chatConversationList" class="chat-widget-body"></div>
      </div>
      <div id="chatThreadView" class="chat-view hidden">
        <div class="chat-widget-header">
          <button id="chatBackBtn" class="chat-icon-btn" type="button" title="Back">←</button>
          <span id="chatThreadTitle"></span>
          <button id="chatThreadCloseBtn" class="chat-icon-btn" type="button" title="Close">✕</button>
        </div>
        <div id="chatThreadMessages" class="chat-widget-body chat-thread-messages"></div>
        <div id="chatThreadReceipt" class="chat-thread-receipt"></div>
        <form id="chatThreadForm" class="chat-thread-input-row">
          <input id="chatThreadInput" type="text" placeholder="Type a message..." maxlength="4000" autocomplete="off" />
          <button type="submit" class="btn btn-primary btn-sm">Send</button>
        </form>
      </div>
      <div id="chatNewView" class="chat-view hidden">
        <div class="chat-widget-header">
          <button id="chatNewBackBtn" class="chat-icon-btn" type="button" title="Back">←</button>
          <span>New Message</span>
          <button id="chatNewCloseBtn" class="chat-icon-btn" type="button" title="Close">✕</button>
        </div>
        <div class="chat-widget-search">
          <input id="chatDirectorySearch" type="text" placeholder="Search staff..." autocomplete="off" />
        </div>
        <div id="chatDirectoryList" class="chat-widget-body"></div>
      </div>
    </div>
  `;
  document.body.appendChild(root);

  document.getElementById('chatWidgetBubble').addEventListener('click', chatOpenPanel);
  document.getElementById('chatCloseBtn').addEventListener('click', chatClosePanel);
  document.getElementById('chatThreadCloseBtn').addEventListener('click', chatClosePanel);
  document.getElementById('chatNewCloseBtn').addEventListener('click', chatClosePanel);
  document.getElementById('chatBackBtn').addEventListener('click', chatShowListView);
  document.getElementById('chatNewBackBtn').addEventListener('click', chatShowListView);
  document.getElementById('chatNewBtn').addEventListener('click', chatShowNewView);
  document.getElementById('chatDirectorySearch').addEventListener('input', chatRenderDirectoryList);
  document.getElementById('chatThreadForm').addEventListener('submit', chatHandleSendMessage);
}

function chatOpenPanel() {
  document.getElementById('chatWidgetPanel').classList.remove('hidden');
  chatShowListView();
  chatLoadConversations().catch((err) => console.error('Chat: failed to load conversations', err));
}

function chatClosePanel() {
  document.getElementById('chatWidgetPanel').classList.add('hidden');
  chatOpenConversationId = null;
}

function chatShowListView() {
  chatOpenConversationId = null;
  document.getElementById('chatListView').classList.remove('hidden');
  document.getElementById('chatThreadView').classList.add('hidden');
  document.getElementById('chatNewView').classList.add('hidden');
}

function chatShowNewView() {
  document.getElementById('chatListView').classList.add('hidden');
  document.getElementById('chatNewView').classList.remove('hidden');
  document.getElementById('chatDirectorySearch').value = '';
  chatRenderDirectoryList();
}

// ---------------------------------------------------------------------------
// UI: conversation list + "new message" staff directory

function chatRenderConversationList() {
  const container = document.getElementById('chatConversationList');
  if (!container) return;

  if (chatConversations.length === 0) {
    container.innerHTML = '<p class="muted" style="padding:16px;">No conversations yet. Tap ✏️ to message someone.</p>';
    return;
  }

  container.innerHTML = chatConversations
    .map((c) => {
      const name = c.is_group ? (c.name || 'Group') : chatOtherDisplayName(c.other_username);
      const isOnline = !c.is_group && chatOnlineUsernames.has(c.other_username);
      const preview = c.last_message
        ? `${c.last_message_sender === chatSession.username ? 'You: ' : ''}${chatEscapeHtml(c.last_message)}`
        : 'Say hello!';
      return `
        <div class="chat-conv-item${c.unread ? ' chat-conv-unread' : ''}" data-conversation-id="${c.conversation_id}">
          <span class="chat-avatar-dot${isOnline ? ' chat-online' : ''}"></span>
          <div class="chat-conv-text">
            <div class="chat-conv-name">${chatEscapeHtml(name)}</div>
            <div class="chat-conv-preview">${preview}</div>
          </div>
          <div class="chat-conv-time">${chatFormatTime(c.last_message_at)}</div>
        </div>
      `;
    })
    .join('');

  container.querySelectorAll('.chat-conv-item').forEach((el) => {
    el.addEventListener('click', () => chatOpenThread(el.dataset.conversationId));
  });
}

function chatRenderDirectoryList() {
  const container = document.getElementById('chatDirectoryList');
  const search = (document.getElementById('chatDirectorySearch').value || '').trim().toLowerCase();
  const filtered = chatDirectory.filter((u) => !search || u.display_name.toLowerCase().includes(search));

  if (filtered.length === 0) {
    container.innerHTML = '<p class="muted" style="padding:16px;">No staff found.</p>';
    return;
  }

  container.innerHTML = filtered
    .map((u) => {
      const isOnline = chatOnlineUsernames.has(u.username);
      return `
        <div class="chat-conv-item" data-username="${chatEscapeHtml(u.username)}">
          <span class="chat-avatar-dot${isOnline ? ' chat-online' : ''}"></span>
          <div class="chat-conv-text">
            <div class="chat-conv-name">${chatEscapeHtml(u.display_name)}</div>
          </div>
        </div>
      `;
    })
    .join('');

  container.querySelectorAll('.chat-conv-item').forEach((el) => {
    el.addEventListener('click', () => chatStartConversationWith(el.dataset.username));
  });
}

async function chatStartConversationWith(username) {
  try {
    const { data: conversationId, error } = await supabaseClient.rpc('get_or_create_dm_conversation', {
      p_username_a: chatSession.username,
      p_username_b: username
    });
    if (error) throw new Error(error.message);

    chatJoinConversationChannel(conversationId);
    if (!chatConversations.some((c) => c.conversation_id === conversationId)) {
      chatInboxBroadcast(username, { type: 'new_conversation', conversationId });
    }
    await chatLoadConversations();
    chatOpenThread(conversationId);
  } catch (err) {
    alert(err.message || 'Could not start that conversation.');
  }
}

// Broadcast requires the channel to actually be joined (SUBSCRIBED) before send() works, so this
// briefly opens its own channel rather than reusing chatConversationChannels (the recipient may
// not have anything open yet for a conversation they don't know exists).
function chatInboxBroadcast(toUsername, event) {
  const channel = supabaseClient.channel(`chat:inbox:${toUsername}`);
  channel.subscribe((status) => {
    if (status === 'SUBSCRIBED') {
      channel.send({ type: 'broadcast', event: event.type, payload: event });
    }
  });
}

// ---------------------------------------------------------------------------
// UI: thread view

function chatRenderThreadHeader(conversationId) {
  const conv = chatConversations.find((c) => c.conversation_id === conversationId);
  if (!conv) return;
  const name = conv.is_group ? (conv.name || 'Group') : chatOtherDisplayName(conv.other_username);
  const isOnline = !conv.is_group && chatOnlineUsernames.has(conv.other_username);
  document.getElementById('chatThreadTitle').textContent = isOnline ? `${name} · Online` : name;
}

async function chatOpenThread(conversationId) {
  chatOpenConversationId = conversationId;
  document.getElementById('chatListView').classList.add('hidden');
  document.getElementById('chatNewView').classList.add('hidden');
  document.getElementById('chatThreadView').classList.remove('hidden');
  chatRenderThreadHeader(conversationId);
  chatJoinConversationChannel(conversationId);

  const messagesEl = document.getElementById('chatThreadMessages');
  messagesEl.innerHTML = '<p class="muted" style="padding:16px;">Loading...</p>';

  const [{ data, error }, { data: memberRows }] = await Promise.all([
    supabaseClient
      .from('ChatMessages')
      .select('MessageID, SenderUsername, Body, CreatedAtUtc')
      .eq('ConversationID', conversationId)
      .order('CreatedAtUtc', { ascending: true }),
    supabaseClient
      .from('ChatConversationMembers')
      .select('Username, LastReadAtUtc')
      .eq('ConversationID', conversationId)
  ]);

  if (error) {
    messagesEl.innerHTML = `<p class="muted" style="padding:16px;">Failed to load messages: ${chatEscapeHtml(error.message)}</p>`;
    return;
  }

  // Seed "Seen" from the other member's persisted LastReadAtUtc so it's correct even on a fresh
  // page load, not just for receipts that arrive live while this tab stays open.
  const otherMember = (memberRows || []).find((m) => m.Username !== chatSession.username);
  if (otherMember?.LastReadAtUtc) {
    chatApplyReceipt(conversationId, 'seenUpTo', otherMember.LastReadAtUtc);
  }

  messagesEl.innerHTML = '';
  let lastMineAt = null;
  (data || []).forEach((m) => {
    chatAppendMessageBubble({ senderUsername: m.SenderUsername, body: m.Body, createdAtUtc: m.CreatedAtUtc });
    if (m.SenderUsername === chatSession.username) lastMineAt = m.CreatedAtUtc;
  });
  if (lastMineAt) chatLastMineAt.set(conversationId, lastMineAt);
  chatRenderReceiptStatus(conversationId);

  await chatMarkConversationRead(conversationId);
  document.getElementById('chatThreadInput').focus();
}

function chatAppendMessageBubble(message) {
  const messagesEl = document.getElementById('chatThreadMessages');
  if (!messagesEl) return;

  const mine = message.senderUsername === chatSession.username;
  const bubble = document.createElement('div');
  bubble.className = `chat-msg${mine ? ' chat-msg-mine' : ' chat-msg-theirs'}`;
  bubble.innerHTML = `
    <div class="chat-msg-bubble">${chatEscapeHtml(message.body)}</div>
    <div class="chat-msg-time">${chatFormatTime(message.createdAtUtc)}</div>
  `;
  messagesEl.appendChild(bubble);
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

async function chatMarkConversationRead(conversationId) {
  const conv = chatConversations.find((c) => c.conversation_id === conversationId);
  if (conv) conv.unread = false;
  chatUpdateBubbleBadge();
  chatRenderConversationList();

  const nowIso = new Date().toISOString();
  try {
    await supabaseClient
      .from('ChatConversationMembers')
      .update({ LastReadAtUtc: nowIso })
      .eq('ConversationID', conversationId)
      .eq('Username', chatSession.username);
  } catch {
    // Best-effort - a failed read-receipt write just means the unread badge may reappear next load.
  }

  // Tell whoever is on the other end their message was seen - live, so their open thread (if any)
  // flips from "Sent"/"Delivered" to "Seen" immediately instead of waiting for their next reload.
  chatConversationChannels.get(conversationId)?.send({
    type: 'broadcast',
    event: 'seen',
    payload: { upTo: nowIso }
  });
}

async function chatHandleSendMessage(evt) {
  evt.preventDefault();
  const input = document.getElementById('chatThreadInput');
  const body = input.value.trim();
  if (!body || !chatOpenConversationId) return;

  input.value = '';
  const conversationId = chatOpenConversationId;
  const nowIso = new Date().toISOString();

  const { error } = await supabaseClient.from('ChatMessages').insert({
    ConversationID: conversationId,
    SenderUsername: chatSession.username,
    Body: body
  });

  if (error) {
    alert('Failed to send: ' + error.message);
    input.value = body;
    return;
  }

  const message = { senderUsername: chatSession.username, body, createdAtUtc: nowIso };
  chatAppendMessageBubble(message);
  chatLastMineAt.set(conversationId, nowIso);
  chatRenderReceiptStatus(conversationId);

  const conv = chatConversations.find((c) => c.conversation_id === conversationId);
  if (conv) {
    conv.last_message = body;
    conv.last_message_at = nowIso;
    conv.last_message_sender = chatSession.username;
  }
  chatRenderConversationList();

  chatJoinConversationChannel(conversationId);
  chatConversationChannels.get(conversationId)?.send({ type: 'broadcast', event: 'message', payload: message });
}

// ---------------------------------------------------------------------------
// Entry point - called from nav.js's renderTopNav once a session exists.

function initChatWidget(session) {
  if (!session || document.getElementById('chatWidgetRoot')) return;

  chatSession = session;
  chatBuildWidgetShell();
  chatSetupPresence();
  chatSetupInboxChannel();

  // Directory loads first - conversation names/dots are looked up from it, so loading conversations
  // before it resolves would briefly render raw usernames instead of display names.
  chatLoadDirectory()
    .then(() => chatLoadConversations())
    .catch((err) => console.error('Chat: failed to load chat widget data', err));
}
