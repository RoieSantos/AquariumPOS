// Messenger-style chat widget - floating bubble present on every authenticated page (mounted by
// nav.js's renderTopNav so no per-page wiring is needed). See supabase_portal_chat_tables.sql for
// the schema/RPCs and its header comment for why message delivery uses Realtime Broadcast
// (per-conversation channels) instead of postgres_changes.
//
// Groups (supabase_portal_chat_groups_and_alice.sql's create_group_conversation) and Alice, the AI
// bot, as an addressable contact (same file - a StaffUsers row 'alice' that shows up in the normal
// directory) were added per "i want alice and the GC to live only in the portal" - DM her directly
// (always replies) or add her to a group and type "@Alice" (only replies when mentioned there,
// never to ordinary staff chatter). See supabase/functions/portal-chat-alice-reply for the actual
// reply logic - it runs in `simulate: true` mode, so nothing said to her here is a real action.

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
const chatConversationHasAlice = new Map(); // conversationId -> boolean, refreshed each time a thread is opened
const chatConversationIsGroup = new Map(); // conversationId -> boolean, so send-time logic doesn't need to re-find it in chatConversations
const chatConversationMemberCount = new Map(); // conversationId -> member count, for the group thread header's "N members"
const CHAT_GROUP_WINDOW_MS = 5 * 60 * 1000; // consecutive messages from one sender within this window stack as one block
let chatNewMode = 'dm'; // 'dm' | 'group' - which tab is active in the "New" view
const chatSelectedGroupMembers = new Set(); // usernames picked so far while chatNewMode === 'group'
const ALICE_USERNAME = 'alice';
const ALICE_MENTION_RE = /@alice\b/i;

// @mention autocomplete for the open thread's input - per "when I put @ there are no users to be
// tagged", so staff can actually find/tag Alice (or each other) instead of having to know to type
// her exact username from memory.
let chatMentionCandidates = []; // [{ username, displayName }] - members of the OPEN conversation, minus me
let chatMentionMatches = []; // currently filtered subset shown in the dropdown
let chatMentionStartIndex = -1; // index of the triggering '@' in the input's current value
let chatMentionHighlightIndex = 0;

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
  document.getElementById('chatWidgetBubble')?.classList.toggle('chat-widget-bubble-unread', count > 0);
  const listBadge = document.getElementById('chatListUnread');
  if (listBadge) {
    listBadge.textContent = count === 0 ? '' : `${count} unread`;
  }
}

// Inline SVG icons (stroke = currentColor) - replaces the old emoji buttons, which rendered
// differently per OS and looked out of place next to the rest of the portal's UI.
const CHAT_ICONS = {
  chat: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 9 9 0 0 1-3.8-.8L3 20.5l1.4-4.3A8.2 8.2 0 0 1 3 11.5 8.4 8.4 0 0 1 12 3a8.4 8.4 0 0 1 9 8.5z"/></svg>',
  chevronDown: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6"/></svg>',
  close: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M18 6L6 18M6 6l12 12"/></svg>',
  back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>',
  compose: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
  send: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3.4 20.4l17.4-7.5a1 1 0 0 0 0-1.8L3.4 3.6a1 1 0 0 0-1.4 1.2L4.2 11 13 12l-8.8 1-2.2 6.2a1 1 0 0 0 1.4 1.2z"/></svg>',
  search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>',
  group: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8"/></svg>',
  check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6L9 17l-5-5"/></svg>'
};

function chatInitials(name) {
  const words = String(name || '?').replace(/\(.*?\)/g, '').trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return '?';
  return (words[0][0] + (words.length > 1 ? words[words.length - 1][0] : '')).toUpperCase();
}

// Stable per-person color, so the same staff member always gets the same avatar color.
function chatAvatarHue(key) {
  let hash = 0;
  for (const ch of String(key || '')) hash = (hash * 31 + ch.charCodeAt(0)) | 0;
  return Math.abs(hash) % 360;
}

// presence: undefined = don't show a presence dot at all (groups, Alice), true/false = online/offline.
function chatAvatarHtml({ username, name, isGroup, presence, small }) {
  const sizeClass = small ? ' chat-avatar-sm' : '';
  const dot = presence === undefined ? '' : `<span class="chat-presence${presence ? ' chat-online' : ''}"></span>`;
  if (isGroup) {
    return `<span class="chat-avatar chat-avatar-group${sizeClass}">${CHAT_ICONS.group}</span>`;
  }
  if (username === ALICE_USERNAME) {
    return `<span class="chat-avatar chat-avatar-alice${sizeClass}">AI</span>`;
  }
  return `<span class="chat-avatar${sizeClass}" style="--chat-avatar-hue:${chatAvatarHue(username)}">${chatEscapeHtml(chatInitials(name))}${dot}</span>`;
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

function chatFormatClock(iso) {
  return iso ? new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) : '';
}

function chatFormatDayLabel(iso) {
  const d = new Date(iso);
  const today = new Date();
  const yesterday = new Date();
  yesterday.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return 'Today';
  if (d.toDateString() === yesterday.toDateString()) return 'Yesterday';
  return d.toLocaleDateString([], {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    ...(d.getFullYear() !== today.getFullYear() ? { year: 'numeric' } : {})
  });
}

function chatOnlineCount() {
  return Array.from(chatOnlineUsernames).filter((u) => u !== chatSession?.username).length;
}

function chatEscapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text ?? '';
  return div.innerHTML;
}

// Escapes first (so a message can never inject markup), then turns bare URLs into real links -
// per "can you make the link clickable always", since Alice's quote replies often end with a
// drawing/preview link (see chatbot-engine.ts's compute_aquarium_quote tool) that was previously
// just inert text staff had to manually copy.
function chatLinkify(text) {
  const escaped = chatEscapeHtml(text);
  return escaped.replace(/(https?:\/\/[^\s<]+)/g, (match) => {
    // Trailing sentence punctuation (a period ending the message, a closing parenthesis, etc.)
    // is more often prose than part of the URL - keep it outside the link.
    const trailingMatch = match.match(/[.,!?;:)\]]+$/);
    const trailing = trailingMatch ? trailingMatch[0] : '';
    const url = trailing ? match.slice(0, -trailing.length) : match;
    return `<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>${trailing}`;
  });
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
    chatAppendMessageBubble(message, chatConversationIsGroup.get(conversationId));
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
    <button id="chatWidgetBubble" class="chat-widget-bubble" type="button" aria-label="Messages" aria-expanded="false" aria-controls="chatWidgetPanel">
      <span class="chat-bubble-icon chat-bubble-icon-chat">${CHAT_ICONS.chat}</span>
      <span class="chat-bubble-icon chat-bubble-icon-close">${CHAT_ICONS.chevronDown}</span>
      <span id="chatWidgetBadge" class="chat-widget-badge hidden">0</span>
    </button>
    <div id="chatWidgetPanel" class="chat-widget-panel hidden" role="dialog" aria-label="Messages">
      <div id="chatListView" class="chat-view">
        <div class="chat-widget-header">
          <div class="chat-header-text">
            <div class="chat-header-title">Messages</div>
            <div class="chat-header-sub"><span id="chatListOnline"></span><span id="chatListUnread" class="chat-header-unread"></span></div>
          </div>
          <div class="chat-header-actions">
            <button id="chatNewBtn" class="chat-icon-btn" type="button" title="New message" aria-label="New message">${CHAT_ICONS.compose}</button>
            <button id="chatCloseBtn" class="chat-icon-btn" type="button" title="Close (Esc)" aria-label="Close">${CHAT_ICONS.close}</button>
          </div>
        </div>
        <div class="chat-widget-search">
          <label class="chat-search-field">
            ${CHAT_ICONS.search}
            <input id="chatConversationSearch" type="text" placeholder="Search conversations" autocomplete="off" />
          </label>
        </div>
        <div id="chatConversationList" class="chat-widget-body"></div>
      </div>
      <div id="chatThreadView" class="chat-view hidden">
        <div class="chat-widget-header">
          <button id="chatBackBtn" class="chat-icon-btn" type="button" title="Back" aria-label="Back">${CHAT_ICONS.back}</button>
          <span id="chatThreadAvatar" class="chat-header-avatar"></span>
          <div class="chat-header-text">
            <div id="chatThreadTitle" class="chat-header-title"></div>
            <div id="chatThreadStatus" class="chat-header-sub"></div>
          </div>
          <button id="chatThreadCloseBtn" class="chat-icon-btn" type="button" title="Close (Esc)" aria-label="Close">${CHAT_ICONS.close}</button>
        </div>
        <div id="chatThreadMessages" class="chat-widget-body chat-thread-messages" aria-live="polite"></div>
        <div id="chatThreadReceipt" class="chat-thread-receipt"></div>
        <form id="chatThreadForm" class="chat-thread-input-row chat-composer">
          <div id="chatMentionDropdown" class="chat-mention-dropdown hidden"></div>
          <textarea id="chatThreadInput" rows="1" placeholder="Message... (@ to mention)" maxlength="4000" autocomplete="off"></textarea>
          <button id="chatSendBtn" type="submit" class="chat-send-btn" title="Send (Enter)" aria-label="Send" disabled>${CHAT_ICONS.send}</button>
        </form>
        <div class="chat-composer-hint">Enter to send · Shift+Enter for a new line</div>
      </div>
      <div id="chatNewView" class="chat-view hidden">
        <div class="chat-widget-header">
          <button id="chatNewBackBtn" class="chat-icon-btn" type="button" title="Back" aria-label="Back">${CHAT_ICONS.back}</button>
          <div class="chat-header-text">
            <div class="chat-header-title">New conversation</div>
          </div>
          <button id="chatNewCloseBtn" class="chat-icon-btn" type="button" title="Close (Esc)" aria-label="Close">${CHAT_ICONS.close}</button>
        </div>
        <div class="chat-new-tabs" role="tablist">
          <button type="button" class="chat-new-tab active" data-mode="dm" role="tab">Direct message</button>
          <button type="button" class="chat-new-tab" data-mode="group" role="tab">New group</button>
        </div>
        <div id="chatGroupNameRow" class="chat-widget-search hidden">
          <input id="chatGroupNameInput" class="chat-plain-input" type="text" placeholder="Group name (e.g. Sales Team)" autocomplete="off" />
        </div>
        <div class="chat-widget-search">
          <label class="chat-search-field">
            ${CHAT_ICONS.search}
            <input id="chatDirectorySearch" type="text" placeholder="Search staff" autocomplete="off" />
          </label>
        </div>
        <div id="chatDirectoryList" class="chat-widget-body"></div>
        <div id="chatGroupCreateRow" class="chat-thread-input-row hidden">
          <button id="chatCreateGroupBtn" class="chat-primary-btn" type="button" disabled>Create group</button>
        </div>
      </div>
    </div>
  `;
  document.body.appendChild(root);

  document.getElementById('chatWidgetBubble').addEventListener('click', () => {
    if (chatIsPanelOpen()) chatClosePanel();
    else chatOpenPanel();
  });
  document.getElementById('chatConversationSearch').addEventListener('input', chatRenderConversationList);
  document.getElementById('chatThreadInput').addEventListener('input', chatAutosizeComposer);
  document.addEventListener('keydown', (evt) => {
    if (evt.key === 'Escape' && !evt.defaultPrevented && chatIsPanelOpen()) chatClosePanel();
  });
  document.getElementById('chatCloseBtn').addEventListener('click', chatClosePanel);
  document.getElementById('chatThreadCloseBtn').addEventListener('click', chatClosePanel);
  document.getElementById('chatNewCloseBtn').addEventListener('click', chatClosePanel);
  document.getElementById('chatBackBtn').addEventListener('click', chatShowListView);
  document.getElementById('chatNewBackBtn').addEventListener('click', chatShowListView);
  document.getElementById('chatNewBtn').addEventListener('click', chatShowNewView);
  document.getElementById('chatDirectorySearch').addEventListener('input', chatRenderDirectoryList);
  document.getElementById('chatThreadForm').addEventListener('submit', chatHandleSendMessage);
  document.getElementById('chatThreadInput').addEventListener('input', chatHandleThreadInputForMentions);
  document.getElementById('chatThreadInput').addEventListener('keydown', chatHandleThreadInputKeydown);
  document.getElementById('chatThreadInput').addEventListener('blur', () => setTimeout(chatHideMentionDropdown, 150));
  document.getElementById('chatCreateGroupBtn').addEventListener('click', chatCreateGroup);
  document.querySelectorAll('.chat-new-tab').forEach((btn) => {
    btn.addEventListener('click', () => chatSetNewMode(btn.dataset.mode));
  });
}

function chatSetNewMode(mode) {
  chatNewMode = mode;
  chatSelectedGroupMembers.clear();
  document.querySelectorAll('.chat-new-tab').forEach((btn) => {
    btn.classList.toggle('active', btn.dataset.mode === mode);
  });
  document.getElementById('chatGroupNameRow').classList.toggle('hidden', mode !== 'group');
  document.getElementById('chatGroupCreateRow').classList.toggle('hidden', mode !== 'group');
  chatRenderDirectoryList();
}

function chatSetBubbleOpenState(isOpen) {
  const bubble = document.getElementById('chatWidgetBubble');
  bubble.classList.toggle('chat-widget-bubble-open', isOpen);
  bubble.setAttribute('aria-expanded', String(isOpen));
  bubble.setAttribute('aria-label', isOpen ? 'Close messages' : 'Messages');
}

function chatOpenPanel() {
  document.getElementById('chatWidgetPanel').classList.remove('hidden');
  chatSetBubbleOpenState(true);
  chatShowListView();
  chatLoadConversations().catch((err) => console.error('Chat: failed to load conversations', err));
}

function chatClosePanel() {
  document.getElementById('chatWidgetPanel').classList.add('hidden');
  chatSetBubbleOpenState(false);
  chatOpenConversationId = null;
  chatHideMentionDropdown();
}

// The composer is a textarea (so Shift+Enter can add a line break) that grows with its content up
// to a few lines, then scrolls - the send button only enables once there's something to send.
function chatAutosizeComposer() {
  const input = document.getElementById('chatThreadInput');
  input.style.height = 'auto';
  // +2 for the 1px top/bottom border (box-sizing: border-box), else a stray scrollbar appears.
  const fullHeight = input.scrollHeight + 2;
  input.style.height = `${Math.min(fullHeight, 120)}px`;
  input.style.overflowY = fullHeight > 120 ? 'auto' : 'hidden';
  document.getElementById('chatSendBtn').disabled = input.value.trim() === '';
}

function chatShowListView() {
  chatOpenConversationId = null;
  document.getElementById('chatListView').classList.remove('hidden');
  document.getElementById('chatThreadView').classList.add('hidden');
  document.getElementById('chatNewView').classList.add('hidden');
  chatHideMentionDropdown();
}

function chatShowNewView() {
  document.getElementById('chatListView').classList.add('hidden');
  document.getElementById('chatNewView').classList.remove('hidden');
  document.getElementById('chatDirectorySearch').value = '';
  document.getElementById('chatGroupNameInput').value = '';
  chatSetNewMode('dm');
}

// ---------------------------------------------------------------------------
// UI: conversation list + "new message" staff directory

function chatRenderConversationList() {
  const container = document.getElementById('chatConversationList');
  if (!container) return;

  const onlineEl = document.getElementById('chatListOnline');
  if (onlineEl) {
    const online = chatOnlineCount();
    onlineEl.textContent = online === 0 ? 'No one else online' : `${online} online`;
  }

  if (chatConversations.length === 0) {
    container.innerHTML = `
      <div class="chat-empty">
        <span class="chat-empty-icon">${CHAT_ICONS.chat}</span>
        <div class="chat-empty-title">No conversations yet</div>
        <div class="chat-empty-sub">Message a teammate or start a group.</div>
        <button type="button" class="chat-primary-btn chat-empty-action" data-action="new">${CHAT_ICONS.compose} New message</button>
      </div>`;
    container.querySelector('[data-action="new"]').addEventListener('click', chatShowNewView);
    return;
  }

  const search = (document.getElementById('chatConversationSearch')?.value || '').trim().toLowerCase();
  const rows = chatConversations
    .map((c) => ({ c, name: c.is_group ? (c.name || 'Group') : chatOtherDisplayName(c.other_username) }))
    .filter(({ c, name }) => !search || name.toLowerCase().includes(search) || (c.last_message || '').toLowerCase().includes(search))
    // Newest activity first - a live message updates last_message_at in place, so re-sort here
    // rather than leaving a just-active conversation stuck where the last load put it.
    .sort((a, b) => new Date(b.c.last_message_at || 0) - new Date(a.c.last_message_at || 0));

  if (rows.length === 0) {
    container.innerHTML = `<div class="chat-empty"><div class="chat-empty-sub">No conversations match "${chatEscapeHtml(search)}".</div></div>`;
    return;
  }

  container.innerHTML = rows
    .map(({ c, name }) => {
      const isAlice = !c.is_group && c.other_username === ALICE_USERNAME;
      const presence = c.is_group || isAlice ? undefined : chatOnlineUsernames.has(c.other_username);
      let senderPrefix = '';
      if (c.last_message && c.last_message_sender === chatSession.username) senderPrefix = 'You: ';
      else if (c.last_message && c.is_group && c.last_message_sender) senderPrefix = `${chatOtherDisplayName(c.last_message_sender).split(' ')[0]}: `;
      const preview = c.last_message ? `${chatEscapeHtml(senderPrefix)}${chatEscapeHtml(c.last_message)}` : '<em>Say hello 👋</em>';
      return `
        <button type="button" class="chat-conv-item${c.unread ? ' chat-conv-unread' : ''}" data-conversation-id="${c.conversation_id}">
          ${chatAvatarHtml({ username: c.other_username, name, isGroup: c.is_group, presence })}
          <div class="chat-conv-text">
            <div class="chat-conv-top">
              <span class="chat-conv-name">${chatEscapeHtml(name)}</span>
              <span class="chat-conv-time">${chatFormatTime(c.last_message_at)}</span>
            </div>
            <div class="chat-conv-bottom">
              <span class="chat-conv-preview">${preview}</span>
              ${c.unread ? '<span class="chat-unread-dot" aria-label="Unread"></span>' : ''}
            </div>
          </div>
        </button>
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
  const isGroupMode = chatNewMode === 'group';

  // Per direct request: only super users can DM Alice 1:1 - everyone else can still @mention her
  // inside a group they create. Hidden here from the "Message" tab entirely rather than shown-then-
  // rejected, so non-super users aren't left wondering why she never replies; portal-chat-alice-
  // reply enforces the actual rule server-side too, this is just so the UI matches that reality.
  const candidates = (isGroupMode || chatSession.isSuperUser)
    ? chatDirectory
    : chatDirectory.filter((u) => u.username !== ALICE_USERNAME);
  const filtered = candidates.filter((u) => !search || u.display_name.toLowerCase().includes(search));

  const createBtn = document.getElementById('chatCreateGroupBtn');
  if (createBtn) {
    const picked = chatSelectedGroupMembers.size;
    createBtn.disabled = picked === 0;
    createBtn.textContent = picked === 0 ? 'Pick people to add' : `Create group · ${picked + 1} people`;
  }

  if (filtered.length === 0) {
    container.innerHTML = '<div class="chat-empty"><div class="chat-empty-sub">No staff found.</div></div>';
    return;
  }

  // Online people first, then alphabetical - the person you want to reach right now is usually online.
  const sorted = filtered.slice().sort((a, b) => {
    const onlineDiff = Number(chatOnlineUsernames.has(b.username)) - Number(chatOnlineUsernames.has(a.username));
    return onlineDiff || a.display_name.localeCompare(b.display_name);
  });

  container.innerHTML = sorted
    .map((u) => {
      const isAlice = u.username === ALICE_USERNAME;
      const isOnline = chatOnlineUsernames.has(u.username);
      const checked = chatSelectedGroupMembers.has(u.username);
      const status = isAlice ? 'AI assistant' : (isOnline ? 'Online' : 'Offline');
      return `
        <button type="button" class="chat-conv-item${isGroupMode && checked ? ' chat-conv-selected' : ''}" data-username="${chatEscapeHtml(u.username)}"${isGroupMode ? ` aria-pressed="${checked}"` : ''}>
          ${chatAvatarHtml({ username: u.username, name: u.display_name, presence: isAlice ? undefined : isOnline })}
          <div class="chat-conv-text">
            <div class="chat-conv-name">${chatEscapeHtml(u.display_name)}</div>
            <div class="chat-conv-preview">${status}</div>
          </div>
          ${isGroupMode ? `<span class="chat-check${checked ? ' chat-check-on' : ''}">${checked ? CHAT_ICONS.check : ''}</span>` : ''}
        </button>
      `;
    })
    .join('');

  container.querySelectorAll('.chat-conv-item').forEach((el) => {
    el.addEventListener('click', () => {
      if (isGroupMode) {
        chatToggleGroupMember(el.dataset.username);
      } else {
        chatStartConversationWith(el.dataset.username);
      }
    });
  });
}

function chatToggleGroupMember(username) {
  if (chatSelectedGroupMembers.has(username)) {
    chatSelectedGroupMembers.delete(username);
  } else {
    chatSelectedGroupMembers.add(username);
  }
  chatRenderDirectoryList();
}

async function chatCreateGroup() {
  const nameInput = document.getElementById('chatGroupNameInput');
  const name = nameInput.value.trim();
  const members = Array.from(chatSelectedGroupMembers);

  if (members.length === 0) {
    alert('Pick at least one other person for the group.');
    return;
  }
  if (!name) {
    alert('Give the group a name.');
    return;
  }

  const btn = document.getElementById('chatCreateGroupBtn');
  btn.disabled = true;
  try {
    const { data: conversationId, error } = await supabaseClient.rpc('create_group_conversation', {
      p_username: chatSession.username,
      p_password: chatSession.password,
      p_name: name,
      p_member_usernames: members
    });
    if (error) throw new Error(error.message);

    chatJoinConversationChannel(conversationId);
    members.forEach((username) => {
      if (username !== ALICE_USERNAME) chatInboxBroadcast(username, { type: 'new_conversation', conversationId });
    });
    await chatLoadConversations();
    chatOpenThread(conversationId);
  } catch (err) {
    alert(err.message || 'Could not create that group.');
  } finally {
    btn.disabled = false;
  }
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
  const isAlice = !conv.is_group && conv.other_username === ALICE_USERNAME;
  const isOnline = !conv.is_group && chatOnlineUsernames.has(conv.other_username);

  let status;
  if (conv.is_group) {
    const count = chatConversationMemberCount.get(conversationId);
    status = count ? `${count} members` : 'Group';
  } else if (isAlice) {
    status = 'AI assistant · always available';
  } else {
    status = isOnline ? 'Online' : 'Offline';
  }

  document.getElementById('chatThreadAvatar').innerHTML = chatAvatarHtml({
    username: conv.other_username,
    name,
    isGroup: conv.is_group,
    presence: conv.is_group || isAlice ? undefined : isOnline,
    small: true
  });
  document.getElementById('chatThreadTitle').textContent = name;
  const statusEl = document.getElementById('chatThreadStatus');
  statusEl.textContent = status;
  statusEl.classList.toggle('chat-status-online', isOnline);
}

function chatResetThreadMessages(html) {
  const messagesEl = document.getElementById('chatThreadMessages');
  messagesEl.innerHTML = html || '';
  delete messagesEl.dataset.lastDay;
}

async function chatOpenThread(conversationId) {
  chatOpenConversationId = conversationId;
  document.getElementById('chatListView').classList.add('hidden');
  document.getElementById('chatNewView').classList.add('hidden');
  document.getElementById('chatThreadView').classList.remove('hidden');
  chatRenderThreadHeader(conversationId);
  chatJoinConversationChannel(conversationId);

  const input = document.getElementById('chatThreadInput');
  input.value = '';
  chatAutosizeComposer();

  const messagesEl = document.getElementById('chatThreadMessages');
  chatResetThreadMessages('<div class="chat-loading"><span></span><span></span><span></span></div>');

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

  // The user may have clicked into another conversation while this one was still loading.
  if (chatOpenConversationId !== conversationId) return;

  if (error) {
    chatResetThreadMessages(`<div class="chat-empty"><div class="chat-empty-sub">Failed to load messages: ${chatEscapeHtml(error.message)}</div></div>`);
    return;
  }

  // Seed "Seen" from the other member's persisted LastReadAtUtc so it's correct even on a fresh
  // page load, not just for receipts that arrive live while this tab stays open.
  const otherMember = (memberRows || []).find((m) => m.Username !== chatSession.username);
  if (otherMember?.LastReadAtUtc) {
    chatApplyReceipt(conversationId, 'seenUpTo', otherMember.LastReadAtUtc);
  }

  const conv = chatConversations.find((c) => c.conversation_id === conversationId);
  const isGroup = Boolean(conv?.is_group);
  chatConversationIsGroup.set(conversationId, isGroup);
  chatConversationHasAlice.set(conversationId, (memberRows || []).some((m) => m.Username === ALICE_USERNAME));
  chatConversationMemberCount.set(conversationId, (memberRows || []).length);
  chatRenderThreadHeader(conversationId);
  chatMentionCandidates = (memberRows || [])
    .map((m) => m.Username)
    .filter((u) => u !== chatSession.username)
    .map((u) => ({ username: u, displayName: chatOtherDisplayName(u) }));

  chatResetThreadMessages();
  if (!data || data.length === 0) {
    const otherName = conv?.is_group ? (conv.name || 'the group') : chatOtherDisplayName(conv?.other_username);
    messagesEl.innerHTML = `
      <div class="chat-empty chat-thread-empty">
        ${chatAvatarHtml({ username: conv?.other_username, name: otherName, isGroup: isGroup })}
        <div class="chat-empty-title">${chatEscapeHtml(otherName)}</div>
        <div class="chat-empty-sub">No messages yet - say hello!</div>
      </div>`;
  }
  let lastMineAt = null;
  (data || []).forEach((m) => {
    chatAppendMessageBubble({ senderUsername: m.SenderUsername, body: m.Body, createdAtUtc: m.CreatedAtUtc }, isGroup);
    if (m.SenderUsername === chatSession.username) lastMineAt = m.CreatedAtUtc;
  });
  if (lastMineAt) chatLastMineAt.set(conversationId, lastMineAt);
  chatRenderReceiptStatus(conversationId);

  await chatMarkConversationRead(conversationId);
  document.getElementById('chatThreadInput').focus();
}

function chatAppendMessageBubble(message, isGroup) {
  const messagesEl = document.getElementById('chatThreadMessages');
  if (!messagesEl) return;

  messagesEl.querySelector('.chat-thread-empty')?.remove();
  // New messages go above Alice's typing indicator (if showing) so it stays at the bottom.
  const typingEl = document.getElementById('chatAliceTyping');
  const insert = (el) => (typingEl ? messagesEl.insertBefore(el, typingEl) : messagesEl.appendChild(el));

  const createdAt = message.createdAtUtc || new Date().toISOString();
  const dayKey = new Date(createdAt).toDateString();
  if (messagesEl.dataset.lastDay !== dayKey) {
    const separator = document.createElement('div');
    separator.className = 'chat-day-separator';
    separator.innerHTML = `<span>${chatEscapeHtml(chatFormatDayLabel(createdAt))}</span>`;
    insert(separator);
    messagesEl.dataset.lastDay = dayKey;
  }

  // Stack consecutive messages from the same sender (within a few minutes) into one block: the
  // sender name shows once at the top and the time once at the bottom, like Messenger/iMessage.
  const prev = typingEl ? typingEl.previousElementSibling : messagesEl.lastElementChild;
  const continuesPrev = Boolean(
    prev?.classList.contains('chat-msg') &&
    prev.dataset.sender === message.senderUsername &&
    new Date(createdAt) - new Date(prev.dataset.createdAt) < CHAT_GROUP_WINDOW_MS
  );
  if (continuesPrev) prev.classList.add('chat-msg-has-next');

  const mine = message.senderUsername === chatSession.username;
  const bubble = document.createElement('div');
  bubble.className = `chat-msg${mine ? ' chat-msg-mine' : ' chat-msg-theirs'}${continuesPrev ? ' chat-msg-has-prev' : ''}`;
  bubble.dataset.sender = message.senderUsername;
  bubble.dataset.createdAt = createdAt;
  // Sender name label only makes sense in a group (a DM's "theirs" bubble is obviously the other
  // person) - and only on messages that aren't mine.
  const senderLabel = isGroup && !mine && !continuesPrev
    ? `<div class="chat-msg-sender">${chatEscapeHtml(chatOtherDisplayName(message.senderUsername))}</div>`
    : '';
  bubble.innerHTML = `
    ${senderLabel}
    <div class="chat-msg-bubble" title="${chatEscapeHtml(new Date(createdAt).toLocaleString())}">${chatLinkify(message.body)}</div>
    <div class="chat-msg-time">${chatFormatClock(createdAt)}</div>
  `;
  insert(bubble);
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

function chatShowAliceTyping(show) {
  const messagesEl = document.getElementById('chatThreadMessages');
  const existing = document.getElementById('chatAliceTyping');
  if (!show) {
    existing?.remove();
    return;
  }
  if (existing || !messagesEl) return;
  const el = document.createElement('div');
  el.id = 'chatAliceTyping';
  el.className = 'chat-msg chat-msg-theirs chat-typing';
  el.innerHTML = '<div class="chat-msg-bubble" aria-label="Alice is typing"><span></span><span></span><span></span></div>';
  messagesEl.appendChild(el);
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

function chatHideMentionDropdown() {
  chatMentionStartIndex = -1;
  chatMentionMatches = [];
  document.getElementById('chatMentionDropdown').classList.add('hidden');
}

function chatRenderMentionDropdown() {
  const dropdown = document.getElementById('chatMentionDropdown');
  dropdown.innerHTML = chatMentionMatches
    .map((c, i) => `<div class="chat-mention-item${i === chatMentionHighlightIndex ? ' chat-mention-active' : ''}" data-username="${chatEscapeHtml(c.username)}">${chatEscapeHtml(c.displayName)}</div>`)
    .join('');
  dropdown.classList.remove('hidden');

  dropdown.querySelectorAll('.chat-mention-item').forEach((el) => {
    // mousedown (not click) fires before the input loses focus, so selecting an item doesn't first
    // blur-and-close the dropdown out from under the click.
    el.addEventListener('mousedown', (e) => {
      e.preventDefault();
      chatInsertMention(el.dataset.username);
    });
  });
}

function chatHandleThreadInputForMentions() {
  const input = document.getElementById('chatThreadInput');
  const value = input.value;
  const caret = input.selectionStart;
  const uptoCaret = value.slice(0, caret);
  const atIndex = uptoCaret.lastIndexOf('@');

  // No '@' before the caret, or whitespace already typed after it (mention token finished/abandoned)
  // ends the mention - and requiring '@' to be at the very start or right after whitespace keeps
  // this from firing on things like an email address pasted into the message.
  const charBeforeAt = atIndex > 0 ? uptoCaret[atIndex - 1] : ' ';
  if (atIndex === -1 || /\s/.test(uptoCaret.slice(atIndex + 1)) || !/\s/.test(charBeforeAt)) {
    chatHideMentionDropdown();
    return;
  }

  const query = uptoCaret.slice(atIndex + 1).toLowerCase();
  chatMentionMatches = chatMentionCandidates.filter((c) =>
    c.username.toLowerCase().includes(query) || c.displayName.toLowerCase().includes(query)
  );

  if (chatMentionMatches.length === 0) {
    chatHideMentionDropdown();
    return;
  }

  chatMentionStartIndex = atIndex;
  chatMentionHighlightIndex = 0;
  chatRenderMentionDropdown();
}

function chatHandleThreadInputKeydown(evt) {
  if (chatMentionStartIndex === -1 || chatMentionMatches.length === 0) {
    // Enter sends, Shift+Enter adds a new line (isComposing: don't send mid-IME composition).
    if (evt.key === 'Enter' && !evt.shiftKey && !evt.isComposing) {
      evt.preventDefault();
      document.getElementById('chatThreadForm').requestSubmit();
    }
    return;
  }

  if (evt.key === 'ArrowDown') {
    evt.preventDefault();
    chatMentionHighlightIndex = (chatMentionHighlightIndex + 1) % chatMentionMatches.length;
    chatRenderMentionDropdown();
  } else if (evt.key === 'ArrowUp') {
    evt.preventDefault();
    chatMentionHighlightIndex = (chatMentionHighlightIndex - 1 + chatMentionMatches.length) % chatMentionMatches.length;
    chatRenderMentionDropdown();
  } else if (evt.key === 'Enter' || evt.key === 'Tab') {
    evt.preventDefault();
    chatInsertMention(chatMentionMatches[chatMentionHighlightIndex].username);
  } else if (evt.key === 'Escape') {
    evt.preventDefault(); // only close the dropdown, not the whole panel
    chatHideMentionDropdown();
  }
}

function chatInsertMention(username) {
  const input = document.getElementById('chatThreadInput');
  const value = input.value;
  const caret = input.selectionStart;
  const before = value.slice(0, chatMentionStartIndex);
  const after = value.slice(caret);
  // Inserts the raw username (e.g. "@alice"), not the display name - display names can contain
  // spaces/parentheses ("Alice (AI Assistant)") which would break re-parsing the token later, and
  // usernames are exactly what ALICE_MENTION_RE/the server-side re-check match against anyway.
  const inserted = `@${username} `;
  input.value = `${before}${inserted}${after}`;
  const newCaret = before.length + inserted.length;
  input.setSelectionRange(newCaret, newCaret);
  chatHideMentionDropdown();
  chatAutosizeComposer();
  input.focus();
}

async function chatHandleSendMessage(evt) {
  evt.preventDefault();
  const input = document.getElementById('chatThreadInput');
  const body = input.value.trim();
  if (!body || !chatOpenConversationId) return;

  input.value = '';
  chatAutosizeComposer();
  chatHideMentionDropdown();
  const conversationId = chatOpenConversationId;
  const isGroup = Boolean(chatConversationIsGroup.get(conversationId));
  const nowIso = new Date().toISOString();

  const { error } = await supabaseClient.from('ChatMessages').insert({
    ConversationID: conversationId,
    SenderUsername: chatSession.username,
    Body: body
  });

  if (error) {
    alert('Failed to send: ' + error.message);
    input.value = body;
    chatAutosizeComposer();
    return;
  }

  const message = { senderUsername: chatSession.username, body, createdAtUtc: nowIso };
  chatAppendMessageBubble(message, isGroup);
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

  // Alice: a 1:1 DM with her always gets a reply; in a group she's a member of, only when
  // explicitly @mentioned - never for ordinary staff back-and-forth. The Edge Function re-checks
  // both conditions server-side too (see portal-chat-alice-reply), this is just to avoid firing an
  // unnecessary request most of the time.
  const hasAlice = chatConversationHasAlice.get(conversationId);
  const shouldAskAlice = hasAlice && (!isGroup || ALICE_MENTION_RE.test(body));
  if (shouldAskAlice) {
    chatRequestAliceReply(conversationId, isGroup);
  }
}

async function chatRequestAliceReply(conversationId, isGroup) {
  if (chatOpenConversationId === conversationId) chatShowAliceTyping(true);
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/portal-chat-alice-reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: chatSession.username,
        admin_password: chatSession.password,
        conversation_id: conversationId
      })
    });

    const result = await response.json().catch(() => ({}));
    if (chatOpenConversationId === conversationId) chatShowAliceTyping(false);
    if (!response.ok || !result.reply) return;

    const nowIso = new Date().toISOString();
    const message = { senderUsername: ALICE_USERNAME, body: result.reply, createdAtUtc: nowIso };

    if (chatOpenConversationId === conversationId) {
      chatAppendMessageBubble(message, isGroup);
    }
    chatLastMineAt.delete(conversationId); // her reply resets "Sent/Delivered/Seen" tracking for MY last message
    chatRenderReceiptStatus(conversationId);

    const conv = chatConversations.find((c) => c.conversation_id === conversationId);
    if (conv) {
      conv.last_message = result.reply;
      conv.last_message_at = nowIso;
      conv.last_message_sender = ALICE_USERNAME;
      conv.unread = chatOpenConversationId !== conversationId;
    }
    chatRenderConversationList();
    chatUpdateBubbleBadge();

    chatConversationChannels.get(conversationId)?.send({ type: 'broadcast', event: 'message', payload: message });
  } catch (err) {
    if (chatOpenConversationId === conversationId) chatShowAliceTyping(false);
    console.error('Chat: Alice reply failed', err);
  }
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
