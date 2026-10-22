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

// Phone layout (<=800px, see the matching @media block in gma-conversations.html) works like the
// Messenger app: one full-screen view at a time - 'list' (chats) -> 'chat' (thread + composer) ->
// 'info' (customer/orders panel). Each step forward pushes a history entry so the phone's own Back
// button/gesture steps back through them instead of leaving the page. Ignored by the desktop CSS.
const MOBILE_INBOX_QUERY = window.matchMedia('(max-width: 800px)');
let mobileView = 'list';

function isMobileInbox() {
  return MOBILE_INBOX_QUERY.matches;
}

function setMobileView(view) {
  const leavingChat = mobileView !== 'list' && view === 'list';
  mobileView = view;
  document.body.dataset.inboxView = view;
  if (view !== 'chat') closeReactPicker();
  // Back on the chat list = no longer looking at that conversation, so it shouldn't count as
  // "viewing" (presence) or get new messages auto-marked read (markOpenConversationReadIfVisible).
  if (leavingChat && isMobileInbox() && selectedPsid) {
    selectedPsid = null;
    trackPresence();
    renderConversationList();
  }
}

function showMobileView(view) {
  if (!isMobileInbox() || view === mobileView) return;
  // Info -> Chat (e.g. a call banner opening another conversation) = step back, not a new entry.
  if (mobileView === 'info' && view === 'chat' && history.state?.inboxView === 'info') {
    history.back();
    return;
  }
  history.pushState({ inboxView: view }, '');
  setMobileView(view);
}

function mobileBack() {
  if (history.state?.inboxView) history.back();
  else setMobileView(mobileView === 'info' ? 'chat' : 'list');
}

window.addEventListener('popstate', (e) => {
  setMobileView(e.state?.inboxView || 'list');
});

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

// The list loads 100 at a time; "Load more" at the bottom adds the next 100. Every reload (live
// updates, pin, tag...) refetches all the pages already shown, so the extra rows don't disappear.
// A new search/filter starts again from the first 100.
const CONVERSATION_PAGE_SIZE = 100;
let conversationPagesLoaded = 1;
let conversationTotalCount = 0;
let conversationFilterKey = '';

async function loadConversations() {
  const listEl = document.getElementById('conversationListEl');
  const filterKey = JSON.stringify([conversationSearchTerm.trim(), conversationTagFilter, conversationReadFilter, conversationMoodFilter]);
  if (filterKey !== conversationFilterKey) {
    conversationFilterKey = filterKey;
    conversationPagesLoaded = 1;
  }
  const pageResults = await Promise.all(Array.from({ length: conversationPagesLoaded }, (_, i) =>
    supabaseClient.rpc('admin_list_chatbot_conversations', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_page: i + 1,
      p_page_size: CONVERSATION_PAGE_SIZE,
      p_search: conversationSearchTerm.trim() || null,
      // Only sent when filtering, so the list still loads before supabase_gma_conversation_tags.sql is run.
      ...(conversationTagFilter ? { p_tag_id: conversationTagFilter } : {}),
      // Same for the All / Unread / Read pills (supabase_gma_conversation_mark_unread.sql).
      ...(conversationReadFilter ? { p_read_filter: conversationReadFilter } : {}),
      // And the mood filter (supabase_gma_conversation_mood.sql).
      ...(conversationMoodFilter ? { p_mood: conversationMoodFilter } : {})
    })
  ));
  const error = pageResults.find((r) => r.error)?.error;
  // A conversation can move between pages while they load - keep its first appearance only.
  const seenPsids = new Set();
  const data = pageResults.flatMap((r) => r.data || []).filter((c) => !seenPsids.has(c.psid) && seenPsids.add(c.psid));
  conversationTotalCount = Number(pageResults[0]?.data?.[0]?.total_count ?? 0);

  if (error) {
    let message = error.message;
    if (error.code === 'PGRST202' && conversationMoodFilter) {
      message = 'The mood filter needs sql/supabase_gma_conversation_mood.sql to be run first. Pick "All moods" to see the list.';
    } else if (error.code === 'PGRST202' && conversationReadFilter) {
      message = 'The Unread / Read filter needs sql/supabase_gma_conversation_mark_unread.sql to be run first. Click "All" to see the list.';
    }
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(message)}</div>`;
    return;
  }

  const previousSelected = conversations.find((c) => c.psid === selectedPsid);
  // Show the customer's real Facebook name everywhere in the inbox (sql/supabase_gma_conversation_facebook_name.sql)
  // - CustomerName is the CRM/order name the bot, auto-fill and Customer Card change, which confused
  // staff. That name stays as crm_name for prefilling new orders.
  conversations = (data || []).map((c) => ({ ...c, crm_name: c.customer_name, customer_name: c.facebook_name || c.customer_name }));
  // Unread view: opening a conversation marks it read, so the next reload would drop it - keep the
  // one that's open in the list until staff move on (like Messenger's Unread tab).
  if (conversationReadFilter && previousSelected && !conversations.some((c) => c.psid === selectedPsid)) {
    conversations.unshift(previousSelected);
  }
  // The open conversation's mood may have just been updated (mood.ts broadcasts after saving it).
  const selectedNow = conversations.find((c) => c.psid === selectedPsid);
  if (selectedNow && previousSelected && (selectedNow.customer_mood !== previousSelected.customer_mood
    || selectedNow.customer_mood_reason !== previousSelected.customer_mood_reason)) {
    renderThreadMood(selectedNow);
  }
  renderConversationList();
  loadConversationAds(); // not awaited - the "📣 Ad" badges fill in after
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

// Customer tags (supabase_gma_conversation_tags.sql): customizable name + color, shared by the team.
// Shown as chips in the list and thread header; picked/managed from the header's 🏷 menu
// (openTagMenu); the list can be filtered to one tag.
let allTags = []; // [{ tag_id, name, color, conversation_count }]
let conversationTagFilter = null; // tag_id or null
const TAG_COLORS = ['#dc2626', '#ea580c', '#ca8a04', '#16a34a', '#0891b2', '#2563eb', '#7c3aed', '#db2777', '#64748b'];

async function loadTags() {
  const { data, error } = await supabaseClient.rpc('admin_list_chatbot_tags', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  allTags = error ? [] : (data || []); // error = SQL not run yet - tags just stay hidden
  renderTagFilter();
}

function renderTagFilter() {
  const select = document.getElementById('conversationTagFilter');
  if (!select) return;
  if (conversationTagFilter && !allTags.some((t) => t.tag_id === conversationTagFilter)) conversationTagFilter = null;
  select.classList.toggle('hidden', allTags.length === 0);
  select.innerHTML = '<option value="">All tags</option>' + allTags
    .map((t) => `<option value="${t.tag_id}"${t.tag_id === conversationTagFilter ? ' selected' : ''}>${escapeHtml(t.name)} (${Number(t.conversation_count) || 0})</option>`)
    .join('');
}

// Customer mood (supabase_gma_conversation_mood.sql) - the webhook's mood.ts reads the customer's
// latest messages with a cheap AI model ~30s after they stop typing. A hint for staff, not a fact.
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
let conversationMoodFilter = null; // a MOODS key or null

function moodTitle(c) {
  const mood = MOODS[c.customer_mood];
  if (!mood) return '';
  const when = c.customer_mood_at_utc ? ` · ${formatRelativeTime(c.customer_mood_at_utc)}` : '';
  return `Customer seems ${mood.label.toLowerCase()}${c.customer_mood_reason ? `: ${c.customer_mood_reason}` : ''}${when} (AI guess)`;
}

function moodBadgeHtml(c) {
  const mood = MOODS[c.customer_mood];
  if (!mood) return '';
  return `<span class="inbox-mood inbox-mood-${escapeHtml(c.customer_mood)}" title="${escapeHtml(moodTitle(c))}">${mood.emoji}</span>`;
}

// Thread header: emoji + label; click shows the reason underneath (no hover on a phone).
function threadMoodHtml(c) {
  const mood = MOODS[c.customer_mood];
  if (!mood) return '';
  return `<button type="button" class="inbox-thread-mood inbox-mood-${escapeHtml(c.customer_mood)}" title="${escapeHtml(moodTitle(c))}">${mood.emoji}<span class="inbox-thread-mood-label"> ${escapeHtml(mood.label)}</span></button>`
    + (c.customer_mood_reason ? `<span class="inbox-thread-mood-reason hidden">${escapeHtml(c.customer_mood_reason)}</span>` : '');
}

function renderThreadMood(conv) {
  const el = document.getElementById('threadMoodEl');
  if (!el) return;
  el.innerHTML = threadMoodHtml(conv);
  el.querySelector('.inbox-thread-mood')?.addEventListener('click', () => {
    el.querySelector('.inbox-thread-mood-reason')?.classList.toggle('hidden');
  });
}

function renderMoodFilter() {
  const select = document.getElementById('conversationMoodFilter');
  if (!select) return;
  select.innerHTML = '<option value="">All moods</option>' + Object.entries(MOODS)
    .map(([key, m]) => `<option value="${key}"${key === conversationMoodFilter ? ' selected' : ''}>${m.emoji} ${escapeHtml(m.label)}</option>`)
    .join('');
}

function onConversationMoodFilterChange(value) {
  conversationMoodFilter = value || null;
  loadConversations();
}

function tagChipsHtml(tags) {
  return (Array.isArray(tags) ? tags : [])
    .map((t) => `<span class="inbox-tag-chip" style="background:${escapeHtml(t.color || '#64748b')}">${escapeHtml(t.name)}</span>`)
    .join('');
}

// Tags menu - a popover under the header's 🏷 button: tick tags on/off for this conversation, and
// add / rename / recolor / delete tags (affects every conversation). editingTagId: null = list,
// 'new' = add form, a tag_id = that tag's edit form.
let tagMenuEditing = null;

function closeTagMenu() {
  document.getElementById('inboxTagMenu')?.remove();
  tagMenuEditing = null;
}

function openTagMenu() {
  if (document.getElementById('inboxTagMenu')) {
    closeTagMenu();
    return;
  }
  const menu = document.createElement('div');
  menu.id = 'inboxTagMenu';
  menu.className = 'inbox-tag-menu';
  document.body.appendChild(menu);
  menu.addEventListener('click', onTagMenuClick);
  menu.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target.matches('input[type="text"]')) {
      e.preventDefault();
      menu.querySelector('[data-tag-save]')?.click();
    } else if (e.key === 'Escape') {
      closeTagMenu();
    }
  });
  renderTagMenu();
}

function tagColorSwatchesHtml(selected) {
  return `<div class="inbox-tag-colors">${TAG_COLORS.map((c) =>
    `<button type="button" class="inbox-tag-color${c === selected ? ' active' : ''}" data-tag-color="${c}" style="background:${c}" aria-label="Color ${c}"></button>`).join('')}</div>`;
}

function renderTagMenu() {
  const menu = document.getElementById('inboxTagMenu');
  const conv = conversations.find((c) => c.psid === selectedPsid);
  if (!menu || !conv) return closeTagMenu();
  const onIds = new Set((conv.tags || []).map((t) => t.id));

  if (tagMenuEditing !== null) {
    const tag = tagMenuEditing === 'new' ? null : allTags.find((t) => t.tag_id === tagMenuEditing);
    const color = menu.dataset.pickedColor || tag?.color || TAG_COLORS[0];
    menu.dataset.pickedColor = color;
    menu.innerHTML = `
      <div class="inbox-tag-menu-title">${tag ? 'Edit tag' : 'New tag'}</div>
      <input type="text" class="inbox-tag-name-input" maxlength="40" placeholder="Tag name (e.g. Urgent)" value="${escapeHtml(tag?.name || '')}" />
      ${tagColorSwatchesHtml(color)}
      <div class="inbox-tag-menu-error error-text hidden"></div>
      <div class="inbox-tag-menu-actions">
        ${tag ? `<button type="button" class="btn btn-danger btn-sm" data-tag-delete="${tag.tag_id}">Delete</button>` : ''}
        <span style="flex:1"></span>
        <button type="button" class="btn btn-secondary btn-sm" data-tag-cancel>Cancel</button>
        <button type="button" class="btn btn-primary btn-sm" data-tag-save>${tag ? 'Save' : 'Add'}</button>
      </div>`;
    menu.querySelector('.inbox-tag-name-input').focus();
  } else {
    delete menu.dataset.pickedColor;
    menu.innerHTML = `
      <div class="inbox-tag-menu-title">Tags</div>
      <div class="inbox-tag-menu-list">
        ${allTags.length ? allTags.map((t) => `
          <div class="inbox-tag-menu-row">
            <label>
              <input type="checkbox" data-tag-toggle="${t.tag_id}"${onIds.has(t.tag_id) ? ' checked' : ''} />
              <span class="inbox-tag-chip" style="background:${escapeHtml(t.color)}">${escapeHtml(t.name)}</span>
            </label>
            <button type="button" class="inbox-tag-edit-btn" data-tag-edit="${t.tag_id}" title="Rename / recolor / delete">✎</button>
          </div>`).join('') : '<div class="muted" style="padding:4px 2px;">No tags yet.</div>'}
      </div>
      <div class="inbox-tag-menu-error error-text hidden"></div>
      <button type="button" class="inbox-tag-new-btn" data-tag-new>+ New tag</button>`;
  }

  const btn = document.getElementById('tagMenuBtn');
  if (btn) {
    const rect = btn.getBoundingClientRect();
    menu.style.top = `${Math.min(window.innerHeight - menu.offsetHeight - 8, rect.bottom + 6)}px`;
    menu.style.left = `${Math.min(window.innerWidth - menu.offsetWidth - 8, Math.max(8, rect.right - menu.offsetWidth))}px`;
  }
}

function showTagMenuError(message) {
  const el = document.querySelector('#inboxTagMenu .inbox-tag-menu-error');
  if (!el) return alert(message);
  el.textContent = message;
  el.classList.remove('hidden');
}

async function onTagMenuClick(e) {
  e.stopPropagation();
  const t = e.target;
  const menu = document.getElementById('inboxTagMenu');
  const auth = { p_admin_username: currentSession.username, p_admin_password: currentSession.password };

  const toggle = t.closest('[data-tag-toggle]');
  if (toggle) {
    const conv = conversations.find((c) => c.psid === selectedPsid);
    if (!conv) return;
    const tagId = Number(toggle.dataset.tagToggle);
    const on = toggle.checked;
    toggle.disabled = true;
    const { error } = await supabaseClient.rpc('admin_set_chatbot_conversation_tag', { ...auth, p_psid: conv.psid, p_tag_id: tagId, p_is_tagged: on });
    toggle.disabled = false;
    if (error) {
      toggle.checked = !on;
      return showTagMenuError(`Could not update tag: ${error.message}`);
    }
    const tag = allTags.find((x) => x.tag_id === tagId);
    const others = (conv.tags || []).filter((x) => x.id !== tagId);
    conv.tags = on && tag ? [...others, { id: tag.tag_id, name: tag.name, color: tag.color }].sort((a, b) => a.name.localeCompare(b.name)) : others;
    if (tag) tag.conversation_count = Math.max(0, (Number(tag.conversation_count) || 0) + (on ? 1 : -1));
    renderTagFilter();
    renderConversationList();
    renderThreadHeaderTags(conv);
    gmaInboxChannel?.send({ type: 'broadcast', event: 'conversation_tagged', payload: { psid: conv.psid } });
    return;
  }

  if (t.closest('[data-tag-new]')) {
    tagMenuEditing = 'new';
    return renderTagMenu();
  }
  const edit = t.closest('[data-tag-edit]');
  if (edit) {
    tagMenuEditing = Number(edit.dataset.tagEdit);
    return renderTagMenu();
  }
  if (t.closest('[data-tag-cancel]')) {
    tagMenuEditing = null;
    return renderTagMenu();
  }
  const swatch = t.closest('[data-tag-color]');
  if (swatch) {
    menu.dataset.pickedColor = swatch.dataset.tagColor;
    menu.querySelectorAll('[data-tag-color]').forEach((b) => b.classList.toggle('active', b === swatch));
    return;
  }

  const save = t.closest('[data-tag-save]');
  const del = t.closest('[data-tag-delete]');
  if (!save && !del) return;
  let error;
  if (save) {
    const name = menu.querySelector('.inbox-tag-name-input').value.trim();
    if (!name) return showTagMenuError('Type a tag name.');
    save.disabled = true;
    ({ error } = await supabaseClient.rpc('admin_save_chatbot_tag', {
      ...auth,
      p_tag_id: tagMenuEditing === 'new' ? null : tagMenuEditing,
      p_name: name,
      p_color: menu.dataset.pickedColor || TAG_COLORS[0]
    }));
    save.disabled = false;
  } else {
    const tag = allTags.find((x) => x.tag_id === Number(del.dataset.tagDelete));
    const used = Number(tag?.conversation_count) || 0;
    if (!confirm(`Delete the tag "${tag?.name}"?${used ? ` It will be removed from ${used} conversation${used === 1 ? '' : 's'}.` : ''}`)) return;
    ({ error } = await supabaseClient.rpc('admin_delete_chatbot_tag', { ...auth, p_tag_id: Number(del.dataset.tagDelete) }));
  }
  if (error) {
    return showTagMenuError(error.code === 'PGRST202' ? 'Tags need sql/supabase_gma_conversation_tags.sql to be run first.' : error.message);
  }
  tagMenuEditing = null;
  await refreshAfterTagChange();
  renderTagMenu();
  gmaInboxChannel?.send({ type: 'broadcast', event: 'tags_changed', payload: {} });
}

// A tag was added/renamed/recolored/deleted (here or in another tab) - names/colors on every
// conversation may have changed, so reload both lists.
async function refreshAfterTagChange() {
  await loadTags();
  await loadConversations();
  const conv = conversations.find((c) => c.psid === selectedPsid);
  if (conv) renderThreadHeaderTags(conv);
}

function onConversationTagFilterChange(value) {
  conversationTagFilter = value ? Number(value) : null;
  loadConversations();
}

// All / Unread / Read pills above the list - filtered server-side so it isn't limited to the 100
// conversations already loaded.
let conversationReadFilter = null; // null | 'unread' | 'read'

function onConversationReadFilterClick(e) {
  const btn = e.target.closest('[data-read-filter], [data-list-mode]');
  if (!btn) return;
  document.querySelectorAll('#conversationReadFilter button').forEach((b) => {
    b.classList.toggle('active', b === btn);
  });
  // Comments / Calls tabs - see setInboxListMode.
  if (btn.dataset.listMode) {
    setInboxListMode(btn.dataset.listMode);
    return;
  }
  conversationReadFilter = btn.dataset.readFilter || null;
  if (inboxListMode !== 'chats') setInboxListMode('chats');
  loadConversations();
}

document.addEventListener('click', (e) => {
  if (!e.target.closest('#inboxTagMenu, #tagMenuBtn')) closeTagMenu();
});

function renderThreadHeaderTags(conv) {
  const el = document.getElementById('threadTagsEl');
  if (el) el.innerHTML = tagChipsHtml(conv.tags);
  document.getElementById('tagMenuBtn')?.classList.toggle('tagged', (conv.tags || []).length > 0);
}

// Which Facebook Page a conversation came in on - one Messenger app now serves several Pages (see
// supabase/functions/_shared/page-tokens.ts), all landing in this one inbox. Add a Page here when
// another one is connected; an unlisted Page still shows as "Page …1234".
const PAGE_LABELS = {
  '1272627559275402': { label: 'GMA', cls: 'inbox-badge-page-gma' },
  '195716644410829': { label: 'RS Pet Stop', cls: 'inbox-badge-page-rspetstop' },
  website: { label: 'Website', cls: '' }
};

function pageBadgeHtml(pageId) {
  if (!pageId) return '';
  const known = PAGE_LABELS[pageId];
  const label = known ? known.label : `Page …${String(pageId).slice(-4)}`;
  return `<span class="inbox-badge inbox-badge-page ${known?.cls || ''}" title="Facebook Page ${escapeHtml(pageId)}">${escapeHtml(label)}</span>`;
}

const MOBILE_BACK_ICON = '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="M15 5l-7 7 7 7" stroke-linecap="round" stroke-linejoin="round"/></svg>';

// Messenger-style round initials avatar - same name always gets the same color, via viewerColor's
// hash. The small corner dot is the Page's color (GMA blue / RS green). The customer's Facebook
// profile picture is laid over it once known (profilePics below); if it can't load, the initials show.
function conversationAvatarHtml(c, extraClass = '') {
  const name = c.customer_name || '';
  const pageCls = PAGE_LABELS[c.page_id]?.cls || '';
  return `<span class="inbox-conv-avatar ${extraClass}" data-avatar-psid="${escapeHtml(c.psid)}" style="background:${viewerColor(name || c.psid)}">${profilePicImgHtml(c.psid)}${escapeHtml(viewerInitials(name || '?'))}${pageCls ? `<span class="inbox-conv-avatar-page ${pageCls}"></span>` : ''}</span>`;
}

// Customer profile pictures, straight from Facebook (chatbot-profile-pics Edge Function) - nothing is
// saved; the URL lives only in this Map for the open tab. null = no picture (website visitor, or
// Facebook refused - needs Meta's Business Asset User Profile Access), so it isn't asked again.
const profilePics = new Map();
const profilePicsInFlight = new Set();

function profilePicImgHtml(psid) {
  const url = profilePics.get(psid);
  return url ? `<img class="inbox-conv-avatar-img" src="${escapeHtml(url)}" alt="" referrerpolicy="no-referrer" onerror="this.remove()">` : '';
}

function applyProfilePics() {
  document.querySelectorAll('.inbox-conv-avatar[data-avatar-psid]').forEach((el) => {
    if (el.querySelector('.inbox-conv-avatar-img')) return;
    const html = profilePicImgHtml(el.dataset.avatarPsid);
    if (html) el.insertAdjacentHTML('afterbegin', html);
  });
}

async function ensureProfilePics(list) {
  const psids = list
    .filter((c) => c.psid && c.page_id !== 'website' && !profilePics.has(c.psid) && !profilePicsInFlight.has(c.psid))
    .map((c) => c.psid);
  if (psids.length === 0) return;
  psids.forEach((p) => profilePicsInFlight.add(p));
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-profile-pics`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({ admin_username: currentSession.username, admin_password: currentSession.password, psids })
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
    psids.forEach((p) => profilePics.set(p, result.pictures?.[p] || null));
    const errors = Object.values(result.errors || {});
    if (errors.length > 0) console.warn(`Profile pictures: Facebook refused ${errors.length} of ${psids.length} -`, errors[0]);
    applyProfilePics();
  } catch (err) {
    // Marked "no picture" for this tab so every live re-render doesn't retry; a page reload does.
    psids.forEach((p) => profilePics.set(p, null));
    console.warn('Profile pictures unavailable:', err instanceof Error ? err.message : err);
  } finally {
    psids.forEach((p) => profilePicsInFlight.delete(p));
  }
}

// ---------------------------------------------------------------------------
// Click-to-Messenger ads (sql/supabase_chatbot_ad_referrals.sql, saved by facebook-messenger-webhook
// recordReferral): a "📣 Ad" badge on the conversation, and the ad drawn above the message the customer
// sent after tapping it. Only taps from when the webhook started saving them are known.
const conversationAds = new Map(); // psid -> latest ad { ad_title, ad_id, referred_at_utc }
const adsCheckedAt = new Map(); // psid -> last_message_at_utc when last checked
let adRpcMissing = false;
const adReferralsByPsid = new Map(); // psid -> [ad referral rows]

async function loadConversationAds() {
  if (adRpcMissing) return;
  const psids = conversations.filter((c) => adsCheckedAt.get(c.psid) !== c.last_message_at_utc).map((c) => c.psid);
  if (!psids.length) return;
  const stamps = new Map(conversations.map((c) => [c.psid, c.last_message_at_utc]));
  const { data, error } = await supabaseClient.rpc('admin_list_chatbot_conversation_ads', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psids: psids
  });
  if (error) {
    if (error.code === 'PGRST202') adRpcMissing = true; // SQL not run yet - no badges
    return;
  }
  psids.forEach((p) => adsCheckedAt.set(p, stamps.get(p)));
  let changed = false;
  (data || []).forEach((a) => {
    const prev = conversationAds.get(a.psid);
    if (!prev || prev.referred_at_utc !== a.referred_at_utc) changed = true;
    conversationAds.set(a.psid, a);
  });
  if (changed) {
    renderConversationList();
    const conv = conversations.find((c) => c.psid === selectedPsid);
    if (conv) renderThreadHeader(conv);
  }
}

async function loadAdReferrals(psid) {
  if (adRpcMissing) return;
  const { data, error } = await supabaseClient.rpc('admin_list_chatbot_ad_referrals', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: psid
  });
  if (error) {
    if (error.code === 'PGRST202') adRpcMissing = true;
    return;
  }
  const rows = data || [];
  const before = (adReferralsByPsid.get(psid) || []).map((a) => a.id).join(',');
  adReferralsByPsid.set(psid, rows);
  if (rows.length && !conversationAds.has(psid)) {
    const latest = rows[rows.length - 1];
    conversationAds.set(psid, { psid, ad_title: latest.ad_title, ad_id: latest.ad_id, referred_at_utc: latest.referred_at_utc });
  }
  if (psid === selectedPsid && before !== rows.map((a) => a.id).join(',') && messageCache.has(psid)) {
    renderMessages(messageCache.get(psid));
  }
}

function adTitleText(ad) {
  return ad?.ad_title || (ad?.ad_id ? `Ad ${ad.ad_id}` : 'a Facebook ad');
}

function adListBadgeHtml(psid) {
  const ad = conversationAds.get(psid);
  if (!ad) return '';
  return `<span class="inbox-badge inbox-badge-ad" title="${escapeHtml(`Came from ${adTitleText(ad)} · ${new Date(ad.referred_at_utc).toLocaleString()}`)}">📣 Ad</span>`;
}

// Which row each ad tap is drawn above: the message it came with, else the first message after it.
function adReferralAnchors(rows) {
  const map = new Map();
  (adReferralsByPsid.get(selectedPsid) || []).forEach((ad) => {
    let idx = ad.message_id ? rows.findIndex((r) => r.message_id === ad.message_id) : -1;
    if (idx < 0) idx = rows.findIndex((r) => r.created_at_utc && new Date(r.created_at_utc) >= new Date(ad.referred_at_utc));
    if (idx < 0) idx = rows.length - 1;
    map.set(idx, [...(map.get(idx) || []), ad]);
  });
  return map;
}

function adReferralCardHtml(ad) {
  const thumb = ad.photo_url ? `<img class="inbox-ad-card-photo" src="${escapeHtml(ad.photo_url)}" alt="">` : '';
  const link = ad.post_id ? `<a href="https://www.facebook.com/${encodeURIComponent(ad.post_id)}" target="_blank" rel="noopener">View ad post ↗</a>` : '';
  return `<div class="inbox-ad-card">
    ${thumb}
    <div class="inbox-ad-card-body">
      <div class="inbox-ad-card-label">📣 Came from an ad · ${escapeHtml(formatMessageTime(ad.referred_at_utc))}</div>
      <div class="inbox-ad-card-title">${escapeHtml(adTitleText(ad))}</div>
      ${link}
    </div>
  </div>`;
}

function renderConversationList() {
  const listEl = document.getElementById('conversationListEl');
  if (inboxListMode === 'comments') return renderCommentList(listEl);
  if (inboxListMode === 'calls') return renderCallList(listEl);

  if (conversations.length === 0) {
    listEl.innerHTML = conversationSearchTerm.trim()
      ? `<div class="inbox-empty-state">No conversations match "${escapeHtml(conversationSearchTerm.trim())}".</div>`
      : '<div class="inbox-empty-state">No conversations yet.</div>';
    return;
  }

  listEl.innerHTML = conversations.map((c) => {
    const badges = [
      moodBadgeHtml(c),
      c.pinned_at_utc ? `<span class="inbox-pin-icon" title="${escapeHtml(pinnedTitle(c))}">📌</span>` : '',
      pageBadgeHtml(c.page_id),
      c.status === 'Escalated' ? '<span class="inbox-badge inbox-badge-escalated">Escalated</span>' : '',
      c.is_paused ? '<span class="inbox-badge inbox-badge-paused">Paused</span>' : ''
    ].join('');

    // Bold + blue dot until a staff member opens it (supabase_gma_conversation_unread_seen_by.sql) -
    // never on the one currently open, since that's being read right now.
    const unread = c.is_unread && c.psid !== selectedPsid;

    return `
      <div class="inbox-conv-item${c.psid === selectedPsid ? ' active' : ''}${unread ? ' inbox-conv-unread' : ''}" data-psid="${escapeHtml(c.psid)}">
        ${conversationAvatarHtml(c)}
        <div class="inbox-conv-body">
          <div class="inbox-conv-top">
            <span class="inbox-conv-psid">${escapeHtml(c.customer_name || c.psid)}${badges}</span>
            <span class="inbox-conv-time">${viewerBadgesHtml(c.psid)}${formatRelativeTime(c.last_message_at_utc)}${unread ? '<span class="inbox-unread-dot" title="Unread"></span>' : ''}</span>
          </div>
          <div class="inbox-conv-preview">${adListBadgeHtml(c.psid)}${escapeHtml(c.last_message_preview || '(no messages)')}</div>
          ${c.tags?.length ? `<div class="inbox-conv-tags">${tagChipsHtml(c.tags)}</div>` : ''}
        </div>
      </div>
    `;
  }).join('') + (conversationTotalCount > conversationPagesLoaded * CONVERSATION_PAGE_SIZE ? `
      <div class="inbox-load-more">
        <span class="inbox-load-more-count">Showing ${conversationPagesLoaded * CONVERSATION_PAGE_SIZE} of ${conversationTotalCount}</span>
        <button type="button" class="btn btn-secondary btn-sm" id="conversationLoadMoreBtn">Load more</button>
      </div>
    ` : '');

  listEl.querySelectorAll('.inbox-conv-item').forEach((el) => {
    el.addEventListener('click', () => openConversation(el.dataset.psid));
  });
  document.getElementById('conversationLoadMoreBtn')?.addEventListener('click', loadMoreConversations);
  ensureProfilePics(conversations);
}

async function loadMoreConversations(e) {
  const btn = e.currentTarget;
  btn.disabled = true;
  btn.textContent = 'Loading...';
  const scrollTop = document.getElementById('conversationListEl').scrollTop;
  conversationPagesLoaded++;
  await loadConversations();
  document.getElementById('conversationListEl').scrollTop = scrollTop;
}

function renderThreadHeader(conv) {
  const headerEl = document.getElementById('threadHeaderEl');
  // Paused by a staff reply -> the AI comes back by itself at auto_resume_at_utc if staff go quiet
  // (supabase_gma_bot_auto_resume.sql); a manual Pause AI has no timer.
  let pauseNote = '';
  if (conv.is_paused) {
    pauseNote = conv.auto_resume_at_utc && !conv.paused_manually
      ? `AI back at ${formatMessageTime(conv.auto_resume_at_utc)} if no staff reply`
      : 'AI paused until resumed';
  }
  // Back arrow, avatar and the info (i) button only show on the phone layout (see the max-width:800px
  // CSS) - on desktop the list and customer panel are already on screen beside the thread.
  headerEl.innerHTML = `
    <button type="button" class="inbox-mobile-back" id="threadBackBtn" aria-label="Back to chats">${MOBILE_BACK_ICON}</button>
    <span class="inbox-thread-title">
      ${conversationAvatarHtml(conv, 'inbox-thread-avatar')}
      <span class="inbox-thread-title-text">
        <span class="inbox-thread-name">${escapeHtml(conv.customer_name || conv.psid)}${pageBadgeHtml(conv.page_id)}${adListBadgeHtml(conv.psid)}<span class="inbox-thread-mood-wrap" id="threadMoodEl"></span><span class="inbox-thread-tags" id="threadTagsEl">${tagChipsHtml(conv.tags)}</span></span>
        ${pauseNote ? `<span class="inbox-thread-sub">${escapeHtml(pauseNote)}</span>` : ''}
      </span>
    </span>
    <span class="inbox-thread-viewers" id="threadViewersEl"></span>
    <span class="inbox-header-actions">
      ${pauseNote ? `<span class="inbox-pause-note">${escapeHtml(pauseNote)}</span>` : ''}
      <button class="btn btn-secondary btn-sm" id="threadSearchBtn" type="button" title="Search in this conversation">
        🔍<span class="inbox-hdr-btn-label"> Search</span>
      </button>
      <button class="btn btn-secondary btn-sm inbox-tag-btn${conv.tags?.length ? ' tagged' : ''}" id="tagMenuBtn" type="button" title="Tag this customer (Urgent, Issue, ...)">
        🏷<span class="inbox-hdr-btn-label"> Tags</span>
      </button>
      <button class="btn btn-secondary btn-sm inbox-pin-btn${conv.pinned_at_utc ? ' pinned' : ''}" id="togglePinBtn" type="button" title="${escapeHtml(conv.pinned_at_utc ? pinnedTitle(conv) + ' - click to unpin' : 'Pin to the top of the list for everyone')}">
        📌<span class="inbox-hdr-btn-label"> ${conv.pinned_at_utc ? 'Unpin' : 'Pin'}</span>
      </button>
      <button class="btn btn-secondary btn-sm" id="markUnreadBtn" type="button" title="Mark as unread for everyone and close it - goes bold again until someone opens it">
        ✉<span class="inbox-hdr-btn-label"> Unread</span>
      </button>
      <button class="btn ${conv.is_paused ? 'btn-success' : 'btn-secondary'} btn-sm" id="togglePauseBtn" type="button" title="${currentSession?.isSuperUser ? (conv.is_paused ? 'Resume AI' : 'Pause AI') : 'Only a Super User can pause or resume the AI'}"${currentSession?.isSuperUser ? '' : ' disabled style="opacity:.55; cursor:not-allowed;"'}>
        ${conv.is_paused ? '▶' : '⏸'}<span class="inbox-hdr-btn-label"> ${conv.is_paused ? 'Resume AI' : 'Pause AI'}</span>
      </button>
      <button type="button" class="inbox-mobile-info-btn" id="threadInfoBtn" aria-label="Customer info and orders">
        <svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor" aria-hidden="true"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm1 15h-2v-6h2v6Zm0-8h-2V7h2v2Z"/></svg>
      </button>
    </span>
  `;
  document.getElementById('togglePauseBtn').addEventListener('click', () => togglePause(conv));
  document.getElementById('togglePinBtn').addEventListener('click', () => togglePin(conv));
  document.getElementById('markUnreadBtn').addEventListener('click', () => markConversationUnread(conv));
  document.getElementById('tagMenuBtn').addEventListener('click', openTagMenu);
  document.getElementById('threadSearchBtn').addEventListener('click', () => {
    if (document.getElementById('threadSearchBar').classList.contains('hidden')) openThreadSearch();
    else closeThreadSearch();
  });
  document.getElementById('threadBackBtn').addEventListener('click', mobileBack);
  document.getElementById('threadInfoBtn').addEventListener('click', () => showMobileView('info'));
  renderThreadMood(conv);
  renderThreadViewers();

  document.getElementById('replyRowEl').classList.remove('hidden');
}

// Pin to top (supabase_gma_conversation_pin.sql) - shared by the team, newest pin first. Other open
// GMA tabs re-sort via the 'conversation_pinned' broadcast.
function pinnedTitle(c) {
  const when = c.pinned_at_utc ? new Date(c.pinned_at_utc).toLocaleString() : '';
  return `Pinned${c.pinned_by ? ` by ${c.pinned_by}` : ''}${when ? ` · ${when}` : ''}`;
}

async function togglePin(conv) {
  const btn = document.getElementById('togglePinBtn');
  btn.disabled = true;
  const nextPinned = !conv.pinned_at_utc;

  const { error } = await supabaseClient.rpc('admin_set_chatbot_conversation_pinned', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: conv.psid,
    p_is_pinned: nextPinned
  });

  if (error) {
    alert(error.code === 'PGRST202'
      ? 'Pinning needs sql/supabase_gma_conversation_pin.sql to be run first.'
      : `Could not update pin: ${error.message}`);
    btn.disabled = false;
    return;
  }

  gmaInboxChannel?.send({ type: 'broadcast', event: 'conversation_pinned', payload: { psid: conv.psid } });
  await loadConversations();
  const fresh = conversations.find((c) => c.psid === conv.psid);
  if (fresh && conv.psid === selectedPsid) renderThreadHeader(fresh);
}

// Super User only (supabase_gma_pause_ai_superuser_only.sql) - the button is disabled for other staff.
async function togglePause(conv) {
  if (!currentSession?.isSuperUser) return;
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
  conv.paused_manually = nextPaused;
  conv.auto_resume_at_utc = null;
  renderThreadHeader(conv);
  renderConversationList();
}

function messageSenderLabel(m) {
  if (m.role === 'staff') return m.sent_by_username ? `Staff (${m.sent_by_username})` : 'Staff';
  if (m.role === 'assistant') return 'Vic';
  return null;
}

// Quoted replies (supabase_chatbot_message_reply_to.sql): who the quoted message is from, and a
// one-line preview of it - used by the quote above a bubble and the composer's "Replying to" bar.
function replyAuthorLabel(role) {
  if (role === 'user') return conversations.find((c) => c.psid === selectedPsid)?.customer_name || 'Customer';
  if (role === 'assistant') return 'Vic';
  if (role === 'staff') return 'Staff';
  return 'a message';
}

function replySnippet(content, attachmentType) {
  const text = String(content || '').trim();
  if (text && !MEDIA_PLACEHOLDER_TEXT.has(text)) return text.length > 90 ? `${text.slice(0, 90)}…` : text;
  if (attachmentType === 'video') return 'Video';
  if (attachmentType === 'image') return 'Photo';
  return text || 'Message';
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
  if (m.pending === 'sending') return '<span class="inbox-msg-status inbox-msg-status-sending">Sending...</span>';
  if (m.pending === 'failed') {
    return '<span class="inbox-msg-status inbox-msg-status-failed">Not sent</span>' +
      `<button type="button" class="inbox-msg-retry-btn" data-send-id="${escapeHtml(m.send_id)}">Retry</button>`;
  }
  if (m.seen_at_utc) return '<span class="inbox-msg-status inbox-msg-status-seen">Seen</span>';
  if (m.delivery_status === 'Failed') return '<span class="inbox-msg-status inbox-msg-status-failed">Failed to send</span>';
  if (m.delivery_status === 'Sent') return '<span class="inbox-msg-status inbox-msg-status-sent">Sent</span>';
  return '';
}

function messageGroupKey(m) {
  return `${m.role}|${m.sent_by_username || ''}`;
}

function messageDayKey(m) {
  return m.created_at_utc ? new Date(m.created_at_utc).toDateString() : null;
}

// Content the webhook stamps on a caption-less photo/video row (ChatbotMessages.Content is NOT NULL) -
// hidden when the media itself is shown, but kept as text when the file couldn't be stored.
const MEDIA_PLACEHOLDER_TEXT = new Set(['[Photo]', '[Video]', '[Voice message]', '[File]', '[Attachment]']);

// Per "when a customer ask for a quote ... and send over the dimension.. convert that into a quote":
// finds the first L x W x H in a customer message - "36x18x18", "36 x 18 x 18 inches", "36\"x18\"x18\"",
// "90cm x 45cm x 45cm", "3ft by 1.5 by 1.5", "36*18*18". Separators: x / × / * / by. Unit = the last
// one written (in / " / cm / mm / ft / '), Inches if none. Each side must work out to 4-240 inches,
// so things like "2x2x2 tubular" or "1x1" don't trigger it. Returns the calculator's own unit
// option names (Inches / CM / MM / Ft), or null.
const DIM_NUM = '(\\d+(?:\\.\\d+)?)';
const DIM_UNIT = '\\s*(inches|inch|in\\b|"|\u201D|\u2033|cm\\b|mm\\b|ft\\b|feet|foot|\'|\u2019|\u2032)?';
const DIM_SEP = '\\s*(?:x|\u00D7|\\*|by)\\s*';
const DIM_PATTERN = new RegExp(`${DIM_NUM}${DIM_UNIT}${DIM_SEP}${DIM_NUM}${DIM_UNIT}${DIM_SEP}${DIM_NUM}${DIM_UNIT}`, 'i');

function dimUnitName(token) {
  const t = String(token || '').toLowerCase();
  if (!t) return null;
  if (t === 'cm') return 'CM';
  if (t === 'mm') return 'MM';
  if (['ft', 'feet', 'foot', "'", '\u2019', '\u2032'].includes(t)) return 'Ft';
  return 'Inches';
}

function parseCustomerDimensions(text) {
  const match = DIM_PATTERN.exec(String(text || ''));
  if (!match) return null;
  const [length, width, height] = [match[1], match[3], match[5]].map(Number);
  const unit = dimUnitName(match[6]) || dimUnitName(match[4]) || dimUnitName(match[2]) || 'Inches';
  const toIn = { Inches: 1, CM: 1 / 2.54, MM: 1 / 25.4, Ft: 12 }[unit];
  if (![length, width, height].every((v) => v * toIn >= 4 && v * toIn <= 240)) return null;
  return { length, width, height, unit };
}

function quoteChipHtml(text) {
  const d = parseCustomerDimensions(text);
  if (!d) return '';
  const unitLabel = { Inches: 'in', CM: 'cm', MM: 'mm', Ft: 'ft' }[d.unit];
  return `<button type="button" class="inbox-quote-chip" data-length="${d.length}" data-width="${d.width}" data-height="${d.height}" data-unit="${d.unit}" title="Open the Custom Aquarium calculator with these dimensions">` +
    `\uD83D\uDCD0 Quote this: ${d.length} x ${d.width} x ${d.height} ${unitLabel}</button>`;
}

// Per "if we are sending links.. can you hyperlink it": escapes the text and turns every http(s)://
// or www. link into a clickable link (new tab). Trailing punctuation (a sentence's "." or ")") is
// left outside the link.
const LINK_PATTERN = /\b(?:https?:\/\/|www\.)[^\s<>"']+/gi;
function linkifyText(text) {
  const s = String(text || '');
  let out = '';
  let last = 0;
  for (const match of s.matchAll(LINK_PATTERN)) {
    let url = match[0];
    const trail = url.match(/[.,!?;:)\]}]+$/);
    if (trail) url = url.slice(0, -trail[0].length);
    out += escapeHtml(s.slice(last, match.index));
    const href = /^https?:\/\//i.test(url) ? url : `https://${url}`;
    out += `<a href="${escapeHtml(href)}" target="_blank" rel="noopener noreferrer">${escapeHtml(url)}</a>`;
    last = match.index + url.length;
  }
  return out + escapeHtml(s.slice(last));
}

// Message text as HTML: a location pin (webhook writes "[Location] <maps link>") reads as a map
// link; everything else is linkified text.
function messageTextHtml(text) {
  const loc = String(text || '').match(/^\[Location\]\s+(https?:\/\/\S+)\s*$/);
  if (loc) {
    return `📍 Shared a location · <a href="${escapeHtml(loc[1])}" target="_blank" rel="noopener noreferrer">Open in Google Maps</a>`;
  }
  return linkifyText(text);
}

// Original file name from a stored file's signed URL - the webhook saves files as
// "<psid>/<ms>-<rand8>-<Name>.<ext>" (facebook-messenger-webhook storeChatbotAttachment).
function attachmentFileName(url) {
  try {
    const last = decodeURIComponent(new URL(url).pathname.split('/').pop() || '');
    const name = last.replace(/^\d+-[0-9a-f]{8}-?/i, '');
    return name.startsWith('.') || !name ? `File${name}` : name;
  } catch {
    return 'File';
  }
}

// Voice message -> inline player; file -> a download chip with its name. (Photos/videos: mediaTileHtml.)
function attachmentExtraHtml(m) {
  if (!m.attachment_url) return '';
  const url = escapeHtml(m.attachment_url);
  if (m.attachment_type === 'audio') {
    return `<audio class="inbox-msg-audio" src="${url}" controls preload="none"></audio>`;
  }
  if (m.attachment_type === 'file') {
    return `<a class="inbox-msg-file" href="${url}" target="_blank" rel="noopener noreferrer" download>📄 <span>${escapeHtml(attachmentFileName(m.attachment_url))}</span></a>`;
  }
  return '';
}

// A photo/video with no caption and no detected-payment card - drawn the Messenger way, as the bare
// media (no colored bubble around it), and consecutive ones from the same sender are merged into one
// grid instead of a tall stack of separate bubbles.
function isMediaOnlyMessage(m) {
  const isMedia = (m.attachment_type === 'image' || m.attachment_type === 'video') && m.attachment_url;
  const hasText = m.content && !(isMedia && MEDIA_PLACEHOLDER_TEXT.has(m.content));
  return !!isMedia && !hasText && (m.detected_payment_amount === null || m.detected_payment_amount === undefined);
}

// A short emoji-only message (e.g. the Like button's 👍) is shown big with no bubble, like Messenger.
function isEmojiOnlyText(text) {
  const t = (text || '').trim();
  return !!t && [...t].length <= 8 && /^(?:\p{Extended_Pictographic}|\p{Emoji_Modifier}|️|‍|\s)+$/u.test(t);
}

function mediaTileHtml(m) {
  const url = escapeHtml(m.attachment_url);
  return m.attachment_type === 'video'
    ? `<video class="inbox-msg-video" src="${url}" controls preload="metadata" playsinline></video>`
    : `<img class="inbox-msg-image" src="${url}" alt="Photo" data-lightbox-src="${url}">`;
}

// Per "make the conversation flow work like Meta": the thread keeps a per-conversation cache (switching
// back to a conversation is instant, then refreshes quietly), staff sends appear immediately as
// "Sending..." bubbles (pendingOutgoing) instead of waiting on Facebook, and a refresh only redraws
// when something actually changed - and never yanks the scroll down while staff is reading older
// messages.
const messageCache = new Map(); // psid -> server rows (oldest first)
const MESSAGE_CACHE_MAX = 30;
const messageLoadSeq = new Map(); // psid -> seq of the newest load STARTED
const messageAppliedSeq = new Map(); // psid -> seq of the newest load APPLIED
let pendingOutgoing = []; // optimistic staff rows not yet confirmed by the server
let lastThreadSignature = '';
let threadStickToBottom = true;

function threadIsNearBottom(el) {
  return el.scrollHeight - el.scrollTop - el.clientHeight < 120;
}

function scrollThreadToBottom() {
  const el = document.getElementById('threadMessagesEl');
  el.scrollTop = el.scrollHeight;
}

function renderThread(opts) {
  if (!selectedPsid) return;
  renderMessages(messageCache.get(selectedPsid) || [], opts);
}

// Messenger-style grouping: consecutive messages from the same sender (and same day) are drawn as
// one visual cluster - sender label only on the first bubble, timestamp/status only on the last -
// instead of repeating both on every single message, which is what made the thread so tall before.
function renderMessages(serverRows, opts = {}) {
  const messagesEl = document.getElementById('threadMessagesEl');
  const rows = serverRows.concat(pendingOutgoing.filter((p) => p.psid === selectedPsid));

  const seenByHtml = seenByLineHtml(rows);
  const signature = selectedPsid + '#' + rows.map((m) =>
    [m.message_id ?? m.temp_id, m.delivery_status, m.seen_at_utc, m.detected_payment_amount, m.detected_payment_applied_at_utc, m.pending, m.customer_reaction, m.staff_reaction, m.reply_to_mid, m.reply_to_message_id].join('|')
  ).join(';') + '#' + seenByHtml + '#ads' + (adReferralsByPsid.get(selectedPsid) || []).map((a) => a.id).join(',');
  if (signature === lastThreadSignature) {
    if (opts.forceBottom) {
      threadStickToBottom = true;
      scrollThreadToBottom();
    }
    return;
  }
  lastThreadSignature = signature;

  if (rows.length === 0) {
    messagesEl.innerHTML = '<div class="inbox-empty-state">No messages yet.</div>';
    return;
  }

  const stick = opts.forceBottom || threadIsNearBottom(messagesEl);
  const prevScrollTop = messagesEl.scrollTop;

  let lastDateKey = null;
  const parts = [];
  const adsByRowIndex = adReferralAnchors(rows);

  let i = 0;
  while (i < rows.length) {
    const m = rows[i];
    const dateKey = messageDayKey(m);
    const dateChanged = dateKey && dateKey !== lastDateKey;
    if (dateChanged) {
      parts.push(`<div class="inbox-date-divider"><span>${escapeHtml(formatDateDivider(m.created_at_utc))}</span></div>`);
      lastDateKey = dateKey;
    }

    // A run of caption-less photos/videos from the same sender collapses into one grid.
    const run = [m];
    if (isMediaOnlyMessage(m)) {
      while (i + run.length < rows.length) {
        const n = rows[i + run.length];
        if (!isMediaOnlyMessage(n) || messageGroupKey(n) !== messageGroupKey(m) || messageDayKey(n) !== dateKey) break;
        run.push(n);
      }
    }
    // "📣 From ad" card above the message the customer sent after tapping the ad.
    for (let k = i; k < i + run.length; k++) (adsByRowIndex.get(k) || []).forEach((ad) => parts.push(adReferralCardHtml(ad)));
    const last = run[run.length - 1];
    const prev = rows[i - 1];
    const next = rows[i + run.length];
    const isGroupStart = dateChanged || !prev || messageGroupKey(prev) !== messageGroupKey(m);
    const isGroupEnd = !next || messageDayKey(next) !== dateKey || messageGroupKey(next) !== messageGroupKey(m);

    const rowClass = m.role === 'staff' ? 'inbox-msg-row-staff' : m.role === 'assistant' ? 'inbox-msg-row-assistant' : 'inbox-msg-row-user';
    const bubbleClass = m.role === 'staff' ? 'inbox-msg-staff' : m.role === 'assistant' ? 'inbox-msg-assistant' : 'inbox-msg-user';
    const sender = isGroupStart ? messageSenderLabel(m) : null;
    const timeLabel = last.created_at_utc ? formatMessageTime(last.created_at_utc) : '';
    // A failed/sending item anywhere in a merged media run decides the status shown under it.
    const statusSource = run.find((r) => r.pending === 'failed') || run.find((r) => r.pending === 'sending') || last;
    const statusLabel = messageStatusLabel(statusSource);
    const isPending = run.some((r) => r.pending);

    let bubbleHtml;
    let bubbleChipHtml = '';
    if (isMediaOnlyMessage(m)) {
      const gridClass = run.length === 1 ? '' : (run.length === 2 || run.length === 4) ? ' inbox-msg-media-grid' : ' inbox-msg-media-grid inbox-msg-media-grid-3';
      bubbleHtml = `<div class="inbox-msg-media${gridClass}">${run.map(mediaTileHtml).join('')}</div>`;
    } else if (!m.attachment_url && isEmojiOnlyText(m.content)) {
      bubbleHtml = `<div class="inbox-msg-emoji">${escapeHtml(m.content.trim())}</div>`;
    } else {
      const hasMedia = (m.attachment_type === 'image' || m.attachment_type === 'video') && m.attachment_url;
      const extraHtml = attachmentExtraHtml(m);
      // '[Photo]' / '[Video]' / '[Voice message]' / '[File]' is just the placeholder Content the webhook
      // stamps on an attachment with no caption (ChatbotMessages.Content is NOT NULL) - skip showing it
      // as redundant text when the attachment itself is shown.
      const showText = m.content && !((hasMedia || extraHtml) && MEDIA_PLACEHOLDER_TEXT.has(m.content));
      // Claude's vision pass (extractPaymentDetails in the webhook) flags this as a likely payment
      // screenshot - a SUGGESTION only, never auto-applied to any order's payments. Staff confirms by
      // clicking through to the Add Payment form (see useDetectedPayment below).
      const hasDetectedPayment = m.detected_payment_amount !== null && m.detected_payment_amount !== undefined;

      // .inbox-msg uses white-space:pre-wrap so a customer/bot's OWN line breaks render correctly -
      // which also means any incidental newlines/indentation from a multi-line template literal
      // would render as extra blank lines inside the bubble. So its inner content is built as a
      // single concatenated string with no embedded template-literal whitespace, unlike the row
      // wrapper around it (not pre-wrap, safe to format normally).
      const mediaHtml = hasMedia ? mediaTileHtml(m) : '';
      const textHtml = showText ? messageTextHtml(m.content) : '';
      const paymentApplied = !!m.detected_payment_applied_at_utc;
      const paymentHtml = hasDetectedPayment
        ? '<div class="inbox-payment-detected">' +
          `<div class="inbox-payment-detected-title">Detected Payment (${paymentApplied ? 'confirmed' : 'unconfirmed'})</div>` +
          `<div>Amount: ${Number(m.detected_payment_amount).toFixed(2)}</div>` +
          (m.detected_payment_method ? `<div>Method: ${escapeHtml(m.detected_payment_method)}</div>` : '') +
          (m.detected_payment_reference ? `<div>Ref: ${escapeHtml(m.detected_payment_reference)}</div>` : '') +
          (m.detected_payment_sender_name ? `<div>From: ${escapeHtml(m.detected_payment_sender_name)}</div>` : '') +
          (m.detected_payment_at_text ? `<div>Paid on screenshot: ${escapeHtml(m.detected_payment_at_text)}</div>` : '') +
          (paymentApplied
            ? ''
            : `<button type="button" class="btn btn-secondary btn-sm inbox-use-payment-btn" data-message-id="${m.message_id}" data-amount="${Number(m.detected_payment_amount)}" data-method="${escapeHtml(m.detected_payment_method || '')}" data-reference="${escapeHtml(m.detected_payment_reference || '')}">Use in Add Payment</button>`) +
          '</div>'
        : '';
      // A pin sent from pin-location.html - offer to book it on the Delivery Calendar (bookDeliveryFromPin).
      const pin = m.role === 'user' ? parsePinnedLocation(m.content) : null;
      const pinHtml = pin
        ? '<div class="inbox-payment-detected">' +
          '<div class="inbox-payment-detected-title">Pinned delivery location</div>' +
          `<div class="inbox-pin-fee" data-pin-key="${pin.lat},${pin.lng}">Delivery fee: calculating...</div>` +
          // Customer arranging their own Lalamove: a live quote to the pin for the chosen vehicle.
          `<div class="inbox-pin-lalamove" data-pin-key="${pin.lat},${pin.lng}">` +
          '<select class="inbox-pin-lala-vehicle" aria-label="Lalamove vehicle">' +
          '<option value="MOTORCYCLE">Motorcycle</option><option value="SEDAN">Sedan</option><option value="MPV" selected>MPV</option>' +
          '<option value="TRUCK330">Small truck (L300)</option><option value="2000KG_ALUMINUM">2-ton truck</option></select>' +
          '<button type="button" class="btn btn-secondary btn-sm inbox-pin-lala-btn">Lalamove price</button>' +
          '<span class="inbox-pin-lala-result"></span></div>' +
          `<button type="button" class="btn btn-secondary btn-sm inbox-pin-book-btn" data-message-id="${m.message_id}">📅 Schedule delivery with this pin</button>` +
          '</div>'
        : '';
      bubbleHtml = `<div class="inbox-msg ${bubbleClass}">${mediaHtml}${extraHtml}${textHtml}${paymentHtml}${pinHtml}</div>`;
      // Customer sent tank dimensions ("36x18x18", "90cm x 45 x 45") - "Quote this" chip under the
      // bubble opens the Custom Aquarium calculator pre-filled (quoteChipHtml / parseCustomerDimensions).
      if (m.role === 'user' && showText) bubbleChipHtml = quoteChipHtml(m.content);
    }

    // Reactions (supabase_chatbot_message_reactions.sql): the customer's on our messages, staff's on
    // the customer's. Customer messages get a hover "react" button (openReactPicker).
    const reactions = run.flatMap((r) => [r.customer_reaction, r.staff_reaction]).filter(Boolean);
    const reactionsHtml = reactions.length ? `<div class="inbox-msg-reactions" title="Reactions">${reactions.map(escapeHtml).join('')}</div>` : '';
    // Map pins come from pin-location.html, not Messenger - no Facebook message to react to.
    const canReact = m.role === 'user' && !isPending && m.message_id && !parsePinnedLocation(m.content);
    const reactBtnHtml = canReact ? `<button type="button" class="inbox-react-btn" data-react-id="${m.message_id}" data-current="${escapeHtml(m.staff_reaction || '')}" title="React">☺</button>` : '';
    // Hover "Reply" on any saved message (startReplyTo) - the next typed send quotes it in Messenger.
    const replyBtnHtml = !isPending && m.message_id ? `<button type="button" class="inbox-reply-to-btn" data-reply-id="${m.message_id}" title="Reply">↩</button>` : '';
    bubbleHtml = `<div class="inbox-msg-bubble-wrap${reactions.length ? ' has-reactions' : ''}">${bubbleHtml}${reactionsHtml}${reactBtnHtml}${replyBtnHtml}</div>`;

    // The message this one replies to, drawn above the bubble like Messenger; click jumps to it.
    const quoteFound = !!m.reply_to_message_id;
    const quoteHtml = m.reply_to_mid
      ? `<div class="inbox-msg-quote"${quoteFound ? ` data-jump-id="${m.reply_to_message_id}" title="Show original message"` : ''}>` +
        `<span class="inbox-msg-quote-label">↩ Replied to ${escapeHtml(quoteFound ? replyAuthorLabel(m.reply_to_role) : 'a message')}</span>` +
        `<span class="inbox-msg-quote-text">${escapeHtml(quoteFound ? replySnippet(m.reply_to_content, m.reply_to_attachment_type) : 'Original message not loaded')}</span>` +
        '</div>'
      : '';

    parts.push(`
      <div class="inbox-msg-row ${rowClass}${isGroupStart ? ' inbox-msg-group-start' : ''}${isPending ? ' inbox-msg-row-pending' : ''}"${m.message_id ? ` data-msg-id="${m.message_id}"` : ''}>
        ${sender ? `<span class="inbox-msg-sender">${escapeHtml(sender)}</span>` : ''}
        ${quoteHtml}
        ${bubbleHtml}
        ${bubbleChipHtml}
        ${isGroupEnd || isPending ? `<div class="inbox-msg-meta">${escapeHtml(timeLabel)}${statusLabel}</div>` : ''}
      </div>
    `);

    i += run.length;
  }

  messagesEl.innerHTML = parts.join('') + seenByHtml;

  messagesEl.querySelectorAll('.inbox-use-payment-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      useDetectedPayment(
        parseFloat(btn.dataset.amount) || null,
        btn.dataset.method || null,
        btn.dataset.reference || null,
        btn.dataset.messageId ? Number(btn.dataset.messageId) : null
      );
      showMobileView('info'); // phone: the Add Payment form is on the customer screen
    });
  });
  messagesEl.querySelectorAll('.inbox-pin-fee').forEach((el) => {
    const [lat, lng] = el.dataset.pinKey.split(',').map(Number);
    getPinFees(lat, lng).then((quotes) => { el.innerHTML = pinFeesHtml(quotes); });
  });
  messagesEl.querySelectorAll('.inbox-pin-lala-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const box = btn.closest('.inbox-pin-lalamove');
      const [lat, lng] = box.dataset.pinKey.split(',').map(Number);
      const vehicle = box.querySelector('.inbox-pin-lala-vehicle').value;
      const resultEl = box.querySelector('.inbox-pin-lala-result');
      btn.disabled = true;
      resultEl.textContent = 'Asking Lalamove...';
      const quotes = await getPinFees(lat, lng, vehicle);
      btn.disabled = false;
      resultEl.innerHTML = pinFeesHtml(quotes, 'Lalamove');
    });
  });
  messagesEl.querySelectorAll('.inbox-pin-book-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const msg = (messageCache.get(selectedPsid) || []).find((r) => String(r.message_id) === btn.dataset.messageId);
      const pin = msg ? parsePinnedLocation(msg.content) : null;
      if (pin) openDeliveryCalendar(pin);
    });
  });
  messagesEl.querySelectorAll('.inbox-msg-retry-btn').forEach((btn) => {
    btn.addEventListener('click', () => retryPendingSend(btn.dataset.sendId));
  });
  messagesEl.querySelectorAll('.inbox-react-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      openReactPicker(btn);
    });
  });
  messagesEl.querySelectorAll('.inbox-reply-to-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      startReplyTo(Number(btn.dataset.replyId));
    });
  });
  messagesEl.querySelectorAll('.inbox-msg-quote[data-jump-id]').forEach((el) => {
    el.addEventListener('click', () => jumpToMessage(el.dataset.jumpId));
  });

  threadStickToBottom = stick;
  if (stick) scrollThreadToBottom();
  else messagesEl.scrollTop = prevScrollTop;
  // A redraw (new message, status change) wipes the search highlights - put them back, same match.
  if (threadSearchTerm) highlightThreadSearch();
}

// Search in this conversation (🔍 in the thread header), like Messenger's "Search in conversation":
// highlights every match in the loaded messages (the newest 200, see loadMessages' p_limit) and steps
// through them, starting from the newest. Enter = older match, Shift+Enter = newer, Esc closes.
// Browser-only - finding a conversation by its messages is the list's search box (p_search).
let threadSearchTerm = '';
let threadSearchIndex = -1; // into the marks, oldest first
let threadSearchTimer = null;

function threadSearchMarks() {
  return [...document.querySelectorAll('#threadMessagesEl mark.inbox-search-hit')];
}

function openThreadSearch() {
  document.getElementById('threadSearchBar').classList.remove('hidden');
  const input = document.getElementById('threadSearchInput');
  input.focus();
  input.select();
}

function closeThreadSearch() {
  clearTimeout(threadSearchTimer);
  document.getElementById('threadSearchBar').classList.add('hidden');
  document.getElementById('threadSearchInput').value = '';
  threadSearchTerm = '';
  threadSearchIndex = -1;
  highlightThreadSearch();
}

// Wraps each match inside a message bubble in <mark> - text only, never inside a button/select
// (the payment and pin boxes), so their labels and handlers stay untouched.
function highlightThreadSearch() {
  const messagesEl = document.getElementById('threadMessagesEl');
  messagesEl.querySelectorAll('mark.inbox-search-hit').forEach((mark) => mark.replaceWith(mark.textContent));
  messagesEl.normalize();

  const term = threadSearchTerm.toLowerCase();
  if (term) {
    const walker = document.createTreeWalker(messagesEl, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => node.parentElement.closest('.inbox-msg, .inbox-msg-emoji') && !node.parentElement.closest('button, select')
        ? NodeFilter.FILTER_ACCEPT
        : NodeFilter.FILTER_REJECT
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach((node) => {
      const text = node.nodeValue;
      const lower = text.toLowerCase();
      let at = lower.indexOf(term);
      if (at < 0) return;
      const frag = document.createDocumentFragment();
      let from = 0;
      while (at >= 0) {
        frag.append(text.slice(from, at));
        const mark = document.createElement('mark');
        mark.className = 'inbox-search-hit';
        mark.textContent = text.slice(at, at + term.length);
        frag.append(mark);
        from = at + term.length;
        at = lower.indexOf(term, from);
      }
      frag.append(text.slice(from));
      node.replaceWith(frag);
    });
  }

  const marks = threadSearchMarks();
  if (threadSearchIndex >= marks.length) threadSearchIndex = marks.length - 1;
  marks[threadSearchIndex]?.classList.add('current');
  updateThreadSearchCount(marks.length);
}

function updateThreadSearchCount(total) {
  const countEl = document.getElementById('threadSearchCount');
  const loaded = (messageCache.get(selectedPsid) || []).length;
  if (!threadSearchTerm) countEl.textContent = '';
  else if (!total) countEl.textContent = loaded >= 200 ? 'No results in the latest 200 messages' : 'No results';
  else countEl.textContent = `${total - threadSearchIndex} of ${total}`; // 1 = newest
  document.getElementById('threadSearchOlderBtn').disabled = total < 2;
  document.getElementById('threadSearchNewerBtn').disabled = total < 2;
}

function onThreadSearchInput(value) {
  clearTimeout(threadSearchTimer);
  threadSearchTimer = setTimeout(() => {
    threadSearchTerm = value.trim();
    threadSearchIndex = Number.MAX_SAFE_INTEGER; // clamped to the newest match
    highlightThreadSearch();
    showThreadSearchMatch(threadSearchIndex);
  }, 200);
}

// Makes match `index` (oldest first) the current one and scrolls to it; wraps around at either end.
function showThreadSearchMatch(index) {
  const marks = threadSearchMarks();
  if (!marks.length) return;
  threadSearchIndex = (index + marks.length) % marks.length;
  marks.forEach((mark, i) => mark.classList.toggle('current', i === threadSearchIndex));
  marks[threadSearchIndex].scrollIntoView({ block: 'center', behavior: 'smooth' });
  updateThreadSearchCount(marks.length);
}

function initThreadSearch() {
  const input = document.getElementById('threadSearchInput');
  input.addEventListener('input', (e) => onThreadSearchInput(e.target.value));
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      closeThreadSearch();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      // Typed faster than the 200ms wait - search now instead of stepping through stale matches.
      if (input.value.trim() !== threadSearchTerm) onThreadSearchInput(input.value);
      else showThreadSearchMatch(threadSearchIndex + (e.shiftKey ? 1 : -1));
    }
  });
  document.getElementById('threadSearchOlderBtn').addEventListener('click', () => showThreadSearchMatch(threadSearchIndex - 1));
  document.getElementById('threadSearchNewerBtn').addEventListener('click', () => showThreadSearchMatch(threadSearchIndex + 1));
  document.getElementById('threadSearchCloseBtn').addEventListener('click', closeThreadSearch);
}

// Staff reaction picker for a customer's message. Sends through chatbot-staff-reply's react mode;
// Facebook may refuse Page reactions on Messenger (only documented for Instagram) - its exact reason
// is shown if so. Picking the reaction already set removes it.
const REACTION_CHOICES = [['love', '❤️'], ['like', '👍'], ['smile', '😆'], ['wow', '😮'], ['sad', '😢'], ['angry', '😠']];

function closeReactPicker() {
  document.getElementById('inboxReactPicker')?.remove();
}

let reactPickerOpenedAt = 0;

// opts.anchor - element to float above (defaults to the ☺ button); opts.copyText - long-press on a
// phone also offers Copy, since holding the bubble no longer selects its text; opts.replyId - and
// Reply (the hover ↩ button is hidden on the phone layout). btn is null for our own messages (no
// reactions, just Reply/Copy).
function openReactPicker(btn, opts = {}) {
  closeReactPicker();
  reactPickerOpenedAt = Date.now();
  const messageId = btn ? Number(btn.dataset.reactId) : null;
  const current = btn?.dataset.current || '';
  const picker = document.createElement('div');
  picker.id = 'inboxReactPicker';
  picker.className = 'inbox-react-picker';
  picker.innerHTML = (btn ? REACTION_CHOICES
    .map(([name, emoji]) => `<button type="button" data-reaction="${name}" class="${emoji === current ? 'active' : ''}" title="${emoji === current ? 'Remove reaction' : name}">${emoji}</button>`)
    .join('') : '') +
    (opts.replyId ? '<button type="button" class="inbox-react-copy" data-reply>Reply</button>' : '') +
    (opts.copyText ? '<button type="button" class="inbox-react-copy" data-copy>Copy</button>' : '');
  picker.addEventListener('click', (e) => {
    if (e.target.closest('[data-reply]')) {
      closeReactPicker();
      startReplyTo(Number(opts.replyId));
      return;
    }
    if (e.target.closest('[data-copy]')) {
      navigator.clipboard?.writeText(opts.copyText).catch(() => {});
      closeReactPicker();
      return;
    }
    const choice = e.target.closest('[data-reaction]');
    if (!choice) return;
    const emoji = REACTION_CHOICES.find(([n]) => n === choice.dataset.reaction)?.[1];
    closeReactPicker();
    reactToMessage(messageId, emoji === current ? null : choice.dataset.reaction);
  });
  document.body.appendChild(picker);
  const anchor = opts.anchor || btn;
  if (!anchor) return;
  const rect = anchor.getBoundingClientRect();
  const left = opts.anchor ? rect.left : rect.left - picker.offsetWidth / 2;
  picker.style.top = `${Math.max(8, rect.top - picker.offsetHeight - 6)}px`;
  picker.style.left = `${Math.min(window.innerWidth - picker.offsetWidth - 8, Math.max(8, left))}px`;
}

document.addEventListener('click', (e) => {
  // The tap that ends a long-press can arrive as a click right after the picker opens - ignore it.
  if (Date.now() - reactPickerOpenedAt < 600) return;
  if (!e.target.closest('#inboxReactPicker')) closeReactPicker();
});

// "Reply" to one specific message: held here until the next typed send (sendReply), which passes it
// as reply_to_message_id so chatbot-staff-reply sends it as a Messenger quoted reply. Cleared on
// send, on the composer's ×, on Escape, or when switching conversation.
let replyingTo = null; // { psid, messageId, role, content, attachmentType }

function startReplyTo(messageId) {
  const m = (messageCache.get(selectedPsid) || []).find((r) => r.message_id === messageId);
  if (!m) return;
  replyingTo = { psid: selectedPsid, messageId, role: m.role, content: m.content, attachmentType: m.attachment_type };
  renderReplyingTo();
  document.getElementById('replyInput').focus();
}

function clearReplyTo() {
  replyingTo = null;
  renderReplyingTo();
}

function renderReplyingTo() {
  const el = document.getElementById('replyingToEl');
  if (!el) return;
  el.classList.toggle('hidden', !replyingTo);
  if (!replyingTo) return;
  document.getElementById('replyingToLabel').textContent = `Replying to ${replyAuthorLabel(replyingTo.role)}`;
  document.getElementById('replyingToText').textContent = replySnippet(replyingTo.content, replyingTo.attachmentType);
}

function jumpToMessage(messageId) {
  const row = document.querySelector(`#threadMessagesEl [data-msg-id="${Number(messageId)}"]`);
  if (!row) return;
  row.scrollIntoView({ block: 'center', behavior: 'smooth' });
  row.classList.remove('inbox-msg-row-flash');
  void row.offsetWidth; // restart the highlight animation on a repeat click
  row.classList.add('inbox-msg-row-flash');
}

// Shown instantly (like Messenger), then sent in the background; put back if Facebook refuses.
function setCachedStaffReaction(psid, messageId, emoji) {
  const row = (messageCache.get(psid) || []).find((m) => m.message_id === messageId);
  if (!row) return undefined;
  const previous = row.staff_reaction ?? null;
  row.staff_reaction = emoji;
  if (psid === selectedPsid) renderThread();
  return previous;
}

async function reactToMessage(messageId, reaction) {
  const psid = selectedPsid;
  const emoji = reaction ? REACTION_CHOICES.find(([n]) => n === reaction)?.[1] ?? null : null;
  const previous = setCachedStaffReaction(psid, messageId, emoji);
  let result = {};
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
        psid,
        react: { message_id: messageId, reaction }
      })
    });
    result = await response.json().catch(() => ({}));
    if (!response.ok || result.ok === false) throw new Error(result.error || `HTTP ${response.status}`);
  } catch (err) {
    if (previous !== undefined) setCachedStaffReaction(psid, messageId, previous);
    alert(`Could not react: ${err instanceof Error ? err.message : err}`);
  }
}

// Reads what Claude's vision pass detected on a payment screenshot and hands it to the
// Information tab's existing Add Payment inputs (per order, see loadConversationOrders) - never
// posts the payment itself, staff still has to review the pre-filled values and click Add Payment.
// Since those inputs don't exist until loadConversationOrders' async fetch finishes rendering them,
// this stashes the values in pendingDetectedPayment and loadConversationOrders applies them once the
// order rows are actually in the DOM.
let pendingDetectedPayment = null;

// Most recent detected payment for the open conversation that staff hasn't confirmed yet (null if
// none, or if the latest one was already applied) - set by loadMessages below, and applied
// automatically by openConversation so the Information tab's order panel is already pre-filled and
// flagged the moment staff opens the conversation, no click on the message bubble required.
let latestDetectedPayment = null;

function useDetectedPayment(amount, method, reference, messageId) {
  const conv = conversations.find((c) => c.psid === selectedPsid);
  if (!conv) return;
  pendingDetectedPayment = { amount, method, reference, messageId: messageId ?? null };
  activeCustomerTab = 'info';
  renderCustomerPanel(conv);
}

// opts.forceBottom - jump to the newest message (opening a conversation / own send).
// opts.beforeApply - runs just before the fresh rows are cached/drawn (or on error), so a send can
// swap its "Sending..." placeholders for the real rows in one redraw with no flicker.
async function loadMessages(psid, opts = {}) {
  const messagesEl = document.getElementById('threadMessagesEl');
  const seq = (messageLoadSeq.get(psid) || 0) + 1;
  messageLoadSeq.set(psid, seq);

  if (psid === selectedPsid) {
    if (messageCache.has(psid)) renderThread({ forceBottom: opts.forceBottom });
    else {
      lastThreadSignature = '';
      messagesEl.innerHTML = '<div class="inbox-empty-state">Loading messages...</div>';
    }
  }

  const { data, error } = await supabaseClient.rpc('admin_get_chatbot_conversation_messages', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: psid,
    p_limit: 200
  });

  if (opts.beforeApply) opts.beforeApply();

  if (error) {
    if (psid !== selectedPsid) return;
    if (messageCache.has(psid)) renderThread();
    else {
      lastThreadSignature = '';
      messagesEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    }
    return;
  }

  // An older request finishing after a newer one already landed would roll the thread back.
  if (seq < (messageAppliedSeq.get(psid) || 0)) {
    if (psid === selectedPsid) renderThread();
    return;
  }
  messageAppliedSeq.set(psid, seq);

  const rows = data || [];
  // Re-insert so the Map's order is least-recently-loaded first, then keep only the last
  // MESSAGE_CACHE_MAX conversations - a tab left open all day shouldn't hold every thread in memory.
  messageCache.delete(psid);
  messageCache.set(psid, rows);
  for (const key of messageCache.keys()) {
    if (messageCache.size <= MESSAGE_CACHE_MAX) break;
    if (key !== selectedPsid) messageCache.delete(key);
  }
  if (psid !== selectedPsid) return;
  renderMessages(rows, { forceBottom: opts.forceBottom });

  // Walk backwards (rows are oldest-first) for the latest still-unconfirmed detection.
  latestDetectedPayment = null;
  for (let i = rows.length - 1; i >= 0; i--) {
    const m = rows[i];
    if (m.detected_payment_amount != null && !m.detected_payment_applied_at_utc) {
      latestDetectedPayment = { amount: m.detected_payment_amount, method: m.detected_payment_method, reference: m.detected_payment_reference, messageId: m.message_id };
      break;
    }
  }
}

// Click-to-zoom photo viewer (Messenger's own behavior) instead of opening each photo in a new tab -
// arrows / Left-Right keys step through every photo in the open thread, Esc or a backdrop click closes.
let lightboxState = { srcs: [], index: 0 };

function ensureLightbox() {
  let box = document.getElementById('inboxLightbox');
  if (box) return box;
  box = document.createElement('div');
  box.id = 'inboxLightbox';
  box.className = 'inbox-lightbox hidden';
  box.innerHTML = `
    <button type="button" class="inbox-lightbox-btn inbox-lightbox-close" data-action="close" title="Close (Esc)">&times;</button>
    <button type="button" class="inbox-lightbox-btn inbox-lightbox-prev" data-action="prev" title="Previous">&#8249;</button>
    <img class="inbox-lightbox-img" alt="">
    <button type="button" class="inbox-lightbox-btn inbox-lightbox-next" data-action="next" title="Next">&#8250;</button>
    <div class="inbox-lightbox-footer">
      <span class="inbox-lightbox-count"></span>
      <a class="inbox-lightbox-open" target="_blank" rel="noopener">Open full size</a>
    </div>
  `;
  box.addEventListener('click', (e) => {
    const action = e.target.closest('[data-action]')?.dataset.action;
    if (action === 'close' || e.target === box) closeLightbox();
    else if (action === 'prev') stepLightbox(-1);
    else if (action === 'next') stepLightbox(1);
  });
  document.body.appendChild(box);
  return box;
}

function openLightbox(src) {
  const srcs = Array.from(document.querySelectorAll('#threadMessagesEl [data-lightbox-src]')).map((el) => el.dataset.lightboxSrc);
  lightboxState = { srcs: srcs.length ? srcs : [src], index: Math.max(0, srcs.indexOf(src)) };
  ensureLightbox().classList.remove('hidden');
  showLightboxImage();
}

function showLightboxImage() {
  const box = ensureLightbox();
  const { srcs, index } = lightboxState;
  box.querySelector('.inbox-lightbox-img').src = srcs[index];
  box.querySelector('.inbox-lightbox-open').href = srcs[index];
  box.querySelector('.inbox-lightbox-count').textContent = srcs.length > 1 ? `${index + 1} / ${srcs.length}` : '';
  box.querySelector('.inbox-lightbox-prev').classList.toggle('hidden', srcs.length < 2);
  box.querySelector('.inbox-lightbox-next').classList.toggle('hidden', srcs.length < 2);
}

function stepLightbox(delta) {
  const n = lightboxState.srcs.length;
  if (n < 2) return;
  lightboxState.index = (lightboxState.index + delta + n) % n;
  showLightboxImage();
}

function closeLightbox() {
  document.getElementById('inboxLightbox')?.classList.add('hidden');
}

function lightboxIsOpen() {
  const box = document.getElementById('inboxLightbox');
  return !!box && !box.classList.contains('hidden');
}

async function openConversation(psid) {
  selectedCommentId = null;
  if (inboxListMode !== 'chats') activateChatsMode();
  selectedPsid = psid;
  trackPresence();
  renderConversationList();

  const conv = conversations.find((c) => c.psid === psid);
  if (!conv) return;
  renderThreadHeader(conv);
  showMobileView('chat');
  document.getElementById('replyErrorEl').classList.add('hidden');
  document.getElementById('replyInput').value = '';
  autoResizeReplyInput();
  setPendingReplyImages([]);
  clearReplyTo();
  closeTagMenu();
  closeThreadSearch();
  toggleQuickRepliesPanel(false);
  toggleProductLookupPanel(false);
  toggleMediaLibraryPanel(false);
  resetProductLookup();

  // Switching to a different customer's conversation - don't carry over a stale cart/tab from
  // whoever was open before.
  activeCustomerTab = 'info';
  newOrderLines = [];
  editingOrder = null;
  conversationOrders = [];
  conversationOrdersConv = null;
  expandedOrderNos = new Set();
  expandedPaymentOrderNos = new Set();
  latestDetectedPayment = null;
  flaggedOrderNo = null;
  activeDetectedPaymentMessageId = null;
  renderCustomerPanel(conv);
  markConversationRead(psid); // not awaited - marks read + loads "Seen by" alongside the messages
  loadAdReferrals(psid); // not awaited - draws the "📣 From ad" card when it lands
  await loadMessages(psid, { forceBottom: true });
  if (selectedPsid !== psid) return; // staff already moved on to another conversation

  // If the latest inbound photo detected an unconfirmed payment, pre-fill and flag it right away -
  // same effect as staff clicking "Use in Add Payment" on the message bubble, just automatic so
  // nobody has to scroll the thread looking for it.
  if (latestDetectedPayment) {
    useDetectedPayment(latestDetectedPayment.amount, latestDetectedPayment.method, latestDetectedPayment.reference, latestDetectedPayment.messageId);
  }
}

// Right-panel layout (Information / Create Order tabs, inline order form, phone-match lookup)
// mirrors Pancake's own conversation view per direct reference screenshot - GMA runs on its own
// separate Facebook Page from the Pancake-connected one that online orders come through though, so
// there's no shared id to auto-match a conversation to PRE-EXISTING orders (the manual name/phone
// search in the Information tab covers those). Orders CREATED from the Create Order tab
// (admin_create_gma_conversation_order) stamp GmaPsid/GmaPageId at insert time, so those show up
// automatically via admin_list_automated_orders_by_gma_conversation, no searching needed.
let activeCustomerTab = 'info';

// Same badge vocabulary as Automated Orders (docs/js/automatedOrders.js) - reused rather than
// inventing a separate color set, so a status reads the same way everywhere in the portal.
const ORDER_STATUS_BADGE_CLASS = {
  New: 'badge-primary',
  Contacted: 'badge-warning',
  Confirmed: 'badge-purple',
  Completed: 'badge-success',
  Cancelled: 'badge-danger'
};
const PANCAKE_SYNC_BADGE_CLASS = {
  Synced: 'badge-success',
  Failed: 'badge-danger',
  Pending: 'badge-neutral',
  // AI bot orders wait here until staff click "Confirm Order" (confirmBotOrder), then go straight into
  // Online Orders with no Pancake order ('Portal') - sql/supabase_bot_orders_portal_confirm.sql.
  'Not Pushed': 'badge-warning',
  Portal: 'badge-success'
};
const PANCAKE_SYNC_BADGE_LABEL = {
  'Not Pushed': 'Awaiting Confirm',
  Portal: 'In Online Orders'
};

// Same vocabulary/colors as the Online Orders status-summary-bar (docs/online-orders.html) - this
// is the REAL fulfillment status of the synced Pancake order (once one exists), a completely
// different lifecycle from AutomatedOrders.Status above. Read-only here (see admin_list_automated_
// orders_by_gma_conversation's online_order_status column, sql/supabase_gma_conversation_online_
// order_status.sql) - unlike the editable AutomatedOrders status select, this can't be freely set
// (admin_update_online_order_status only allows manually moving Printed -> To Ship; everything else
// is driven by the background Pancake sync), so there's no select/RPC wiring for it here.
const ONLINE_ORDER_STATUS_BADGE_CLASS = {
  Confirmed: 'badge-primary',
  Printed: 'badge-warning',
  'To Ship': 'badge-purple',
  Shipped: 'badge-success',
  Cancelled: 'badge-danger'
};

// Per direct follow-up request ("this status I dont want... just show the actual status from
// pancake") - replaces the old editable AutomatedOrders status select entirely. While an order
// hasn't synced to Pancake yet there's nothing real to show, so this falls back to the push-attempt
// badge (Pending/Failed); once synced, it shows the LIVE Pancake status (fetched up front for every
// order by loadConversationOrders, not lazily on expand, since this now renders on the collapsed
// card too) instead of the generic "Synced".
function pancakeStatusBadgeHtml(o) {
  if (o.pancake_sync_status !== 'Synced') return pancakeSyncBadgeHtml(o.pancake_sync_status);

  const live = orderPancakeStatusCache.get(o.order_no);
  if (!live || live === 'loading') return '<span class="badge badge-neutral">Checking Pancake...</span>';
  if (live.error) return `<span class="badge badge-danger" title="${escapeHtml(live.error)}">Pancake error</span>`;

  // No Printed stage on screen any more (same as Online Orders' orderDisplayStatus) - shows as Confirmed.
  const status = live.status === 'Printed' ? 'Confirmed' : live.status;
  const cls = ONLINE_ORDER_STATUS_BADGE_CLASS[status] || (status === 'New' ? 'badge-primary' : 'badge-neutral');
  return `<span class="badge ${cls}">${escapeHtml(status || 'Unknown')}</span>`;
}

function orderStatusBadgeHtml(status) {
  const cls = ORDER_STATUS_BADGE_CLASS[status] || 'badge-neutral';
  return `<span class="badge ${cls}">${escapeHtml(status || 'New')}</span>`;
}

function pancakeSyncBadgeHtml(status) {
  if (!status) return '';
  const cls = PANCAKE_SYNC_BADGE_CLASS[status] || 'badge-neutral';
  return `<span class="badge ${cls}">${escapeHtml(PANCAKE_SYNC_BADGE_LABEL[status] || status)}</span>`;
}

function customerInitials(name) {
  return (name || '?').trim().charAt(0).toUpperCase() || '?';
}

function renderCustomerPanel(conv) {
  newOrderConv = conv;
  const panelEl = document.getElementById('customerPanelEl');
  const name = conv.customer_name || 'Unknown Customer';
  // Accent the whole panel while building an order, so it stands out from the chat (see .is-create-mode).
  panelEl.classList.toggle('is-create-mode', activeCustomerTab === 'create');

  panelEl.innerHTML = `
    <div class="inbox-mobile-panel-bar">
      <button type="button" class="inbox-mobile-back" data-mobile-back aria-label="Back to chat">${MOBILE_BACK_ICON}</button>
      <span>Customer &amp; orders</span>
    </div>
    <div class="inbox-customer-header">
      <div class="inbox-customer-avatar">${escapeHtml(customerInitials(name))}</div>
      <div class="inbox-customer-header-name">
        <h3>${escapeHtml(name)}</h3>
        <div class="inbox-customer-header-sub">Messenger customer</div>
      </div>
    </div>
    <div class="panel-tabs">
      <button type="button" class="panel-tab-btn${activeCustomerTab === 'info' ? ' active' : ''}" data-tab="info">
        <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="10" cy="10" r="7.3"/><path d="M10 9.2v4.4" stroke-linecap="round"/><circle cx="10" cy="6.5" r="0.9" fill="currentColor" stroke="none"/></svg>
        Information
      </button>
      <button type="button" class="panel-tab-btn${activeCustomerTab === 'create' ? ' active' : ''}" data-tab="create">
        <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M2.5 3.5h2l1.4 8.4a1.5 1.5 0 0 0 1.48 1.26h6.24a1.5 1.5 0 0 0 1.47-1.2L16.5 6.5h-11" stroke-linecap="round" stroke-linejoin="round"/><circle cx="8" cy="16.5" r="1" fill="currentColor" stroke="none"/><circle cx="14" cy="16.5" r="1" fill="currentColor" stroke="none"/></svg>
        Create Order
      </button>
    </div>
    <div id="panelTabBody"></div>
  `;

  panelEl.querySelector('[data-mobile-back]').addEventListener('click', mobileBack);
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
    <div class="inbox-panel-section">
      <div class="inbox-section-label">
        <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="3" y="3.5" width="14" height="13" rx="2"/><path d="M3 7.5h14" /></svg>
        <span>Conversation details</span>
      </div>
      <div class="inbox-customer-id">
        <div><span>PSID</span><code>${escapeHtml(conv.psid)}</code></div>
        <div><span>Page ID</span><code>${escapeHtml(conv.page_id || '(unknown)')}</code></div>
        <div><span>Conversation ID</span><code>${escapeHtml(conversationId)}</code></div>
      </div>
    </div>

    <div class="inbox-panel-section">
      <div class="inbox-section-label">
        <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M4 5.5h12M4 10h12M4 14.5h8" stroke-linecap="round"/></svg>
        <span>Orders from this conversation</span>
      </div>
      <div id="conversationOrdersEl" class="inbox-empty-state">Loading...</div>
    </div>

    <div class="inbox-panel-section">
      <div class="inbox-section-label">
        <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="8.5" cy="8.5" r="5"/><path d="M12.5 12.5 17 17" stroke-linecap="round"/></svg>
        <span>Look up other orders</span>
      </div>
      <div class="inbox-customer-search">
        <input type="text" id="customerOrderSearchInput" placeholder="Customer name or phone...">
        <button class="btn btn-secondary btn-sm" id="customerOrderSearchBtn" type="button">Search</button>
      </div>
      <div id="customerOrderResultsEl" class="inbox-empty-state">Not linked to a customer record - search by name or phone.</div>
    </div>
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
  conversationOrders = orders;
  conversationOrdersConv = conv;

  if (orders.length === 0) {
    listEl.className = 'inbox-empty-state';
    listEl.textContent = 'No orders created from this conversation yet.';
    // Nothing to prefill/flag without an order - clear it here too, or it would wrongly get
    // applied to whichever order gets created next.
    if (pendingDetectedPayment) {
      alert(`Detected a payment screenshot (amount: ${pendingDetectedPayment.amount ?? '?'}), but this conversation has no orders yet. Create an order first, then use Add Payment manually.`);
      pendingDetectedPayment = null;
    }
    return;
  }

  // A detected-payment screenshot needs to prefill and scroll to its target order's payment form
  // (below), so that order's card AND payment form are opened up-front rather than left collapsed
  // and unreachable. flaggedOrderNo is set here (before the render below) so the "Payment to
  // confirm" badge shows up in the same pass.
  if (pendingDetectedPayment) {
    expandedOrderNos.add(orders[0].order_no);
    expandedPaymentOrderNos.add(orders[0].order_no);
    flaggedOrderNo = orders[0].order_no;
    activeDetectedPaymentMessageId = pendingDetectedPayment.messageId ?? null;
  }

  listEl.className = '';
  renderConversationOrderCards();
  orders.forEach((o) => {
    if (expandedOrderNos.has(o.order_no)) loadOrderExpandedDetails(o.order_no);
  });
  // Fire-and-forget: the real Pancake status now shows on the COLLAPSED card too (per direct
  // follow-up request replacing the old editable status select), so it can't wait for a card to be
  // expanded the way lines/payments do - fetch every synced order's live status up front instead.
  fetchLivePancakeStatuses(orders);

  if (pendingDetectedPayment) {
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
    pendingDetectedPayment = null;
  }
}

// Fetches admin_get_gma_order_pancake_status for every synced order not already cached, in
// parallel, then re-renders once. Safe to call repeatedly (e.g. every loadConversationOrders
// refresh after adding a payment) - already-cached orders are skipped, and this coexists fine with
// loadOrderExpandedDetails's own narrower per-order fetch (same cache, same has()-before-set guard,
// so whichever runs first just wins and the other no-ops).
async function fetchLivePancakeStatuses(orders) {
  const targets = orders.filter((o) => o.pancake_sync_status === 'Synced' && !orderPancakeStatusCache.has(o.order_no));
  if (targets.length === 0) return;

  targets.forEach((o) => orderPancakeStatusCache.set(o.order_no, 'loading'));
  renderConversationOrderCards();

  await Promise.all(targets.map(async (o) => {
    const { data, error } = await supabaseClient.rpc('admin_get_gma_order_pancake_status', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_no: o.order_no
    });
    orderPancakeStatusCache.set(o.order_no, error ? { error: error.message } : { status: data?.[0]?.pancake_status || null });
  }));

  renderConversationOrderCards();
}

// Per direct follow-up request ("i want this to be expandable... at first show the order no and
// status... hide the rest... show products, payment, address etc when clicked") - each card now
// collapses to just its order number + status badges by default, expanding on click to reveal
// everything else. Products/payment history are lazy-loaded the first time a card is expanded (not
// returned by admin_list_automated_orders_by_gma_conversation itself) and cached by OrderNo - a
// globally unique key, so no need to scope the cache per-conversation - via the already-existing
// admin_list_automated_order_lines (supabase_automated_orders_tables.sql) and
// admin_list_automated_order_payments (supabase_gma_conversation_orders.sql) RPCs.
//
// State/render both live at module level (conversationOrders/conversationOrdersConv, mirroring
// newOrderLines elsewhere in this file) rather than threaded through every function's parameters -
// simpler once payment-add/cache-invalidate/toggle all need to trigger the same re-render.
let conversationOrders = [];
let conversationOrdersConv = null;
let expandedOrderNos = new Set();
let expandedPaymentOrderNos = new Set();
let orderLinesCache = new Map();
let orderPaymentsCache = new Map();
// Live Pancake status per order (fetched on demand, see loadOrderExpandedDetails below) - NOT the
// same as o.online_order_status (a mirror of the periodic Pancake -> OnlineOrders sync, which
// deliberately skips orders still 'new' in Pancake - see supabase_pancake_manual_sync.sql). This
// hits Pancake's API directly instead, so it works for a freshly-pushed, not-yet-confirmed order
// too - the exact state a GMA order starts in.
let orderPancakeStatusCache = new Map();

// order_no currently showing the "Payment to confirm" badge (the target of the auto/manual
// detected-payment prefill above) and the ChatbotMessages.Id it came from - cleared once staff
// actually submits that payment (see addOrderPayment), which also marks the message applied server-
// side (admin_mark_chatbot_payment_applied) so the flag doesn't reappear next time this conversation
// is opened.
let flaggedOrderNo = null;
let activeDetectedPaymentMessageId = null;

function orderLinesHtml(orderNo) {
  const lines = orderLinesCache.get(orderNo);
  if (!lines || lines === 'loading') return '<div class="inbox-empty-state">Loading...</div>';
  if (lines.error) return `<div class="inbox-empty-state error-text">${escapeHtml(lines.error)}</div>`;
  if (lines.length === 0) return '<div class="inbox-empty-state">No items.</div>';
  return lines.map((l) => `
    <div class="inbox-order-line-row">
      <div>
        <div>${escapeHtml(l.item_name)} &times;${l.quantity}</div>
        <div class="inbox-order-line-variant">Variation ID: ${l.variation_id ? escapeHtml(l.variation_id) : 'no Pancake match'}</div>
      </div>
      <span>${(Number(l.price) * Number(l.quantity)).toFixed(2)}</span>
    </div>
  `).join('');
}

function orderPaymentsHtml(orderNo) {
  const payments = orderPaymentsCache.get(orderNo);
  if (!payments || payments === 'loading') return '<div class="inbox-empty-state">Loading...</div>';
  if (payments.error) return `<div class="inbox-empty-state error-text">${escapeHtml(payments.error)}</div>`;
  if (payments.length === 0) return '<div class="inbox-empty-state">No payments recorded yet.</div>';
  return payments.map((p) => `
    <div class="inbox-order-payment-row">
      <span>${escapeHtml(p.method || '')}${p.reference ? ' &middot; ' + escapeHtml(p.reference) : ''}</span>
      <span>${Number(p.amount).toFixed(2)}</span>
    </div>
  `).join('');
}

// Expanded-card Pancake row: just the real order id/link (already in `o`, no extra fetch needed -
// same fields automatedOrders.js's pancakeBadgeWithLinkHtml uses) and, only while the live status is
// 'New' or 'Confirmed', the one matching write action - the status itself is shown once, on the
// collapsed card's top badge (pancakeStatusBadgeHtml), not repeated here. Only rendered once
// PancakeSyncStatus is 'Synced' (before that there's no Pancake order to check at all).
function pancakeLiveStatusHtml(o) {
  // AI bot orders are saved as 'Not Pushed' drafts - staff review them here, then Confirm Order puts
  // them straight into Online Orders, no Pancake (sql/supabase_bot_orders_portal_confirm.sql).
  if (o.pancake_sync_status === 'Not Pushed') {
    return `
    <div class="inbox-order-pancake-row">
      <button type="button" class="btn btn-primary btn-sm inbox-confirm-bot-order-btn" data-order="${escapeHtml(o.order_no)}">Confirm Order</button>
    </div>
  `;
  }
  if (o.pancake_sync_status === 'Portal') {
    return `
    <div class="inbox-order-pancake-row">
      <a href="online-orders.html" target="_blank" rel="noopener" title="Open Online Orders">Online Order ${escapeHtml(o.order_no)} &#8599;</a>
    </div>
  `;
  }
  if (o.pancake_sync_status !== 'Synced') return '';

  const idLink = o.pancake_order_id && o.pancake_order_link
    ? `<a href="${o.pancake_order_link}" target="_blank" rel="noopener" title="Open this order in Pancake">#${escapeHtml(o.pancake_order_id)} &#8599;</a>`
    : '';

  const live = orderPancakeStatusCache.get(o.order_no);
  const liveOk = live && live !== 'loading' && !live.error;
  const confirmBtnHtml = liveOk && live.status === 'New'
    ? `<button type="button" class="btn btn-secondary btn-sm inbox-confirm-pancake-btn" data-order="${escapeHtml(o.order_no)}">Confirm in Pancake</button>`
    : '';
  // Per direct follow-up request: once confirmed, staff can cancel it too - same single-transition
  // narrowness as Confirm (only Confirmed -> Cancelled, nothing else, enforced server-side).
  const cancelBtnHtml = liveOk && live.status === 'Confirmed'
    ? `<button type="button" class="btn btn-secondary btn-sm inbox-cancel-pancake-btn" data-order="${escapeHtml(o.order_no)}">Cancel in Pancake</button>`
    : '';

  if (!idLink && !confirmBtnHtml && !cancelBtnHtml) return '';

  return `
    <div class="inbox-order-pancake-row">
      ${idLink}
      ${confirmBtnHtml}
      ${cancelBtnHtml}
    </div>
  `;
}

function orderAddressHtml(o) {
  const rows = [`<div><span>Phone</span><span>${escapeHtml(o.customer_phone || '-')}</span></div>`];
  if (o.customer_email) rows.push(`<div><span>Email</span><span>${escapeHtml(o.customer_email)}</span></div>`);
  if (o.fulfillment_type === 'Delivery') {
    rows.push(`<div><span>Address</span><span>${escapeHtml(o.delivery_address || '(not provided)')}</span></div>`);
    rows.push(`<div><span>Delivery Fee</span><span>${Number(o.delivery_fee || 0) > 0 ? Number(o.delivery_fee).toFixed(2) : 'None'}</span></div>`);
  } else if (o.location) {
    rows.push(`<div><span>Pickup at</span><span>${escapeHtml(o.location)}</span></div>`);
  }
  if (o.notes) rows.push(`<div><span>Notes</span><span>${escapeHtml(o.notes)}</span></div>`);
  return `<div class="inbox-order-kv">${rows.join('')}</div>`;
}

function renderConversationOrderCards() {
  const listEl = document.getElementById('conversationOrdersEl');
  if (!listEl) return;
  const orders = conversationOrders;

  listEl.innerHTML = orders.map((o) => {
    const balance = Number(o.balance || 0);
    const cardExpanded = expandedOrderNos.has(o.order_no);
    const paymentExpanded = expandedPaymentOrderNos.has(o.order_no);
    const pancakeHtml = cardExpanded ? pancakeLiveStatusHtml(o) : '';
    return `
    <div class="inbox-order-item${cardExpanded ? ' expanded' : ''}">
      <div class="inbox-order-top" data-order="${escapeHtml(o.order_no)}">
        <div class="inbox-order-top-left">
          <svg class="inbox-order-chevron" viewBox="0 0 20 20" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2"><path d="M7 5l5 5-5 5" stroke-linecap="round" stroke-linejoin="round"/></svg>
          <span class="inbox-order-no">${escapeHtml(o.order_no)}</span>
        </div>
        <div class="inbox-order-badges">
          ${pageBadgeHtml(conversationOrdersConv?.page_id)}
          ${pancakeStatusBadgeHtml(o)}
          ${o.order_no === flaggedOrderNo ? '<span class="badge badge-danger">Payment to confirm</span>' : ''}
          ${o.status === 'New' && o.receipt_confirmed_at_utc ? '<span class="badge badge-success">Customer confirmed - ready for Order ID</span>' : ''}
        </div>
      </div>
      ${cardExpanded ? `
      <div class="inbox-order-details">
        <div class="inbox-order-meta">${escapeHtml(o.customer_name || '')} - ${escapeHtml(o.fulfillment_type || '')}</div>

        <div class="inbox-order-subsection">
          <div class="inbox-order-stats">
            <div class="inbox-order-stat">
              <span class="inbox-order-stat-label">Total</span>
              <span class="inbox-order-stat-value">${Number(o.estimated_total || 0).toFixed(2)}</span>
            </div>
            <div class="inbox-order-stat">
              <span class="inbox-order-stat-label">Paid</span>
              <span class="inbox-order-stat-value">${Number(o.amount_paid || 0).toFixed(2)}</span>
            </div>
            <div class="inbox-order-stat">
              <span class="inbox-order-stat-label">Balance</span>
              <span class="inbox-order-stat-value ${balance > 0 ? 'balance-due' : 'balance-clear'}">${balance.toFixed(2)}</span>
            </div>
          </div>
        </div>

        <div class="inbox-order-subsection">
          <div class="inbox-order-detail-label">Actions</div>
          ${pancakeHtml}
          ${o.status !== 'Completed' && o.status !== 'Cancelled' && o.pancake_sync_status !== 'Portal' ? `
          <div class="inbox-order-edit-row">
            <button type="button" class="btn btn-secondary btn-sm inbox-edit-order-btn" data-order="${escapeHtml(o.order_no)}">Edit Order</button>
          </div>
          ` : ''}
          <div class="inbox-order-print-row">
            <a href="online-order-receipt.html?order=${encodeURIComponent(o.order_no)}" target="_blank" rel="noopener">Order Confirmation</a>
            <a href="gma-order-invoice.html?order=${encodeURIComponent(o.order_no)}" onclick="window.open(this.href, '_blank'); return false;">Invoice</a>
          </div>
          <div class="inbox-order-send-row">
            <span>Send to customer:</span>
            <button type="button" class="btn-text inbox-send-receipt-btn" data-order="${escapeHtml(o.order_no)}" data-kind="confirmation">Order Confirmation</button>
            <button type="button" class="btn-text inbox-send-receipt-btn" data-order="${escapeHtml(o.order_no)}" data-kind="invoice">Invoice</button>
            ${canSendPayLink(o, balance) ? `<button type="button" class="btn-text inbox-send-paylink-btn" data-order="${escapeHtml(o.order_no)}">💳 Pay link${xenditEnabled ? '' : ' (test)'}</button>` : ''}
          </div>
        </div>

        <div class="inbox-order-subsection">
          <div class="inbox-order-detail-label">Products</div>
          <div class="inbox-order-lines">${orderLinesHtml(o.order_no)}</div>
        </div>

        <div class="inbox-order-subsection">
          <div class="inbox-order-detail-label">${o.fulfillment_type === 'Delivery' ? 'Delivery details' : 'Pickup details'}</div>
          ${orderAddressHtml(o)}
        </div>

        <div class="inbox-order-subsection">
          <div class="inbox-order-detail-label">Payments</div>
          <div class="inbox-order-payments">${orderPaymentsHtml(o.order_no)}</div>
          ${paymentExpanded ? `
          <div class="inbox-payment-row">
            <input type="number" min="0.01" step="0.01" placeholder="Amount" id="payAmount-${escapeHtml(o.order_no)}">
            <select id="payMethod-${escapeHtml(o.order_no)}">
              <option value="Cash">Cash</option>
              <option value="GCash">GCash</option>
              <option value="BDO">BDO</option>
              <option value="Metrobank">Metrobank</option>
              <option value="Bank Transfer">Bank Transfer</option>
              <option value="Other">Other</option>
            </select>
            <input type="text" placeholder="Reference (optional)" id="payRef-${escapeHtml(o.order_no)}">
            <button type="button" class="btn-text inbox-payment-cancel" data-order="${escapeHtml(o.order_no)}">Cancel</button>
            <button class="btn btn-secondary btn-sm" type="button" data-order="${escapeHtml(o.order_no)}">Add Payment</button>
          </div>
          ` : `
          <button type="button" class="inbox-add-payment-toggle" data-order="${escapeHtml(o.order_no)}">
            <svg viewBox="0 0 20 20" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M10 4.5v11M4.5 10h11" stroke-linecap="round"/></svg>
            Add Payment
          </button>
          `}
        </div>
      </div>
      ` : ''}
    </div>
  `;
  }).join('');

  listEl.querySelectorAll('.inbox-order-top').forEach((row) => {
    row.addEventListener('click', (e) => {
      if (e.target.closest('a') || e.target.closest('select')) return;
      toggleOrderCardExpanded(row.dataset.order);
    });
  });
  listEl.querySelectorAll('.inbox-payment-row button[data-order]:not(.inbox-payment-cancel)').forEach((btn) => {
    btn.addEventListener('click', () => addOrderPayment(btn.dataset.order, conversationOrdersConv));
  });
  listEl.querySelectorAll('.inbox-payment-cancel').forEach((btn) => {
    btn.addEventListener('click', () => {
      expandedPaymentOrderNos.delete(btn.dataset.order);
      renderConversationOrderCards();
    });
  });
  listEl.querySelectorAll('.inbox-add-payment-toggle').forEach((btn) => {
    btn.addEventListener('click', () => {
      expandedPaymentOrderNos.add(btn.dataset.order);
      renderConversationOrderCards();
    });
  });
  listEl.querySelectorAll('.inbox-send-receipt-btn').forEach((btn) => {
    btn.addEventListener('click', () => sendReceiptToCustomer(btn.dataset.order, btn.dataset.kind, btn));
  });
  listEl.querySelectorAll('.inbox-send-paylink-btn').forEach((btn) => {
    const order = conversationOrders.find((o) => o.order_no === btn.dataset.order);
    btn.addEventListener('click', () => sendPayLinkToCustomer(order, btn));
  });
  listEl.querySelectorAll('.inbox-edit-order-btn').forEach((btn) => {
    btn.addEventListener('click', () => editOrder(btn.dataset.order, btn));
  });
  listEl.querySelectorAll('.inbox-confirm-pancake-btn').forEach((btn) => {
    btn.addEventListener('click', () => confirmOrderInPancake(btn.dataset.order, btn));
  });
  listEl.querySelectorAll('.inbox-cancel-pancake-btn').forEach((btn) => {
    btn.addEventListener('click', () => cancelOrderInPancake(btn.dataset.order, btn));
  });
  listEl.querySelectorAll('.inbox-confirm-bot-order-btn').forEach((btn) => {
    btn.addEventListener('click', () => confirmBotOrder(btn.dataset.order, btn));
  });
}

function toggleOrderCardExpanded(orderNo) {
  if (expandedOrderNos.has(orderNo)) {
    expandedOrderNos.delete(orderNo);
    renderConversationOrderCards();
    return;
  }
  expandedOrderNos.add(orderNo);
  renderConversationOrderCards();
  loadOrderExpandedDetails(orderNo);
}

async function loadOrderExpandedDetails(orderNo) {
  const needsLines = !orderLinesCache.has(orderNo);
  const needsPayments = !orderPaymentsCache.has(orderNo);
  // Only worth checking Pancake at all once the order has actually been pushed there - see
  // pancakeLiveStatusHtml's own matching gate.
  const order = conversationOrders.find((o) => o.order_no === orderNo);
  const needsPancake = order?.pancake_sync_status === 'Synced' && !orderPancakeStatusCache.has(orderNo);
  if (!needsLines && !needsPayments && !needsPancake) return;

  if (needsLines) orderLinesCache.set(orderNo, 'loading');
  if (needsPayments) orderPaymentsCache.set(orderNo, 'loading');
  if (needsPancake) orderPancakeStatusCache.set(orderNo, 'loading');
  if (expandedOrderNos.has(orderNo)) renderConversationOrderCards();

  const [linesRes, paymentsRes, pancakeRes] = await Promise.all([
    needsLines
      ? supabaseClient.rpc('admin_list_automated_order_lines', {
          p_admin_username: currentSession.username,
          p_admin_password: currentSession.password,
          p_order_no: orderNo
        })
      : Promise.resolve(null),
    needsPayments
      ? supabaseClient.rpc('admin_list_automated_order_payments', {
          p_admin_username: currentSession.username,
          p_admin_password: currentSession.password,
          p_order_no: orderNo
        })
      : Promise.resolve(null),
    needsPancake
      ? supabaseClient.rpc('admin_get_gma_order_pancake_status', {
          p_admin_username: currentSession.username,
          p_admin_password: currentSession.password,
          p_order_no: orderNo
        })
      : Promise.resolve(null)
  ]);

  if (linesRes) orderLinesCache.set(orderNo, linesRes.error ? { error: linesRes.error.message } : (linesRes.data || []));
  if (paymentsRes) orderPaymentsCache.set(orderNo, paymentsRes.error ? { error: paymentsRes.error.message } : (paymentsRes.data || []));
  if (pancakeRes) {
    orderPancakeStatusCache.set(orderNo, pancakeRes.error
      ? { error: pancakeRes.error.message }
      : { status: pancakeRes.data?.[0]?.pancake_status || null });
  }

  // The card may have been collapsed again by the time this resolves - only re-render if it's
  // still expanded, so a quick expand/collapse/expand doesn't fight itself with stale renders.
  if (expandedOrderNos.has(orderNo)) renderConversationOrderCards();
}

// Switches the panel to the Create Order tab in "edit mode" for an already-created order - per
// direct follow-up request ("if the order is created can we modify it still?"). Re-fetches the
// order's lines fresh (rather than trusting orderLinesCache, which may be stale if this order's
// card hasn't been expanded/reloaded recently) so the prefilled cart always matches the database.
// See editingOrderNo/renderCreateOrderTab below for how the form itself switches into edit mode, and
// admin_update_automated_order (supabase_gma_conversation_order_edit.sql) for the save path.
async function editOrder(orderNo, btn) {
  const order = conversationOrders.find((o) => o.order_no === orderNo);
  if (!order) return;

  if (btn) btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_list_automated_order_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo
  });
  if (btn) btn.disabled = false;

  if (error) {
    alert(`Could not load this order's items: ${error.message}`);
    return;
  }

  editingOrder = order;
  newOrderLines = (data || []).map((l) => ({
    category_code: l.category_code || null,
    item_code: l.item_code || null,
    item_name: l.item_name,
    price: Number(l.price) || 0,
    quantity: Number(l.quantity) || 1,
    note: l.notes || null,
    variation_id: l.variation_id || null
  }));

  // Saved pricing flag + which lines are already on their wholesale price.
  editingOrderWasWholesale = (await loadWholesaleInfo(orderNo)) === true;
  newOrderWholesale = editingOrderWasWholesale;
  if (newOrderWholesale) {
    newOrderLines.forEach((line) => {
      const info = wholesaleInfoByCode.get(line.item_code);
      if (info && Math.abs(line.price - info.wholesale_price) < 0.005) {
        line.wholesale_applied = true;
        line.retail_price = info.retail_price;
      }
    });
  }

  activeCustomerTab = 'create';
  renderCustomerPanel(conversationOrdersConv);
}

// Called from the "Confirm in Pancake" button (pancakeLiveStatusHtml) - only ever shown while the
// live-fetched status is 'New', matching admin_confirm_gma_order_in_pancake's own server-side guard
// (it refuses to run against any order that isn't currently 'New' in Pancake, same conservative
// "no free-form status editor" philosophy as admin_update_online_order_status's To-Ship-only gate).
async function confirmOrderInPancake(orderNo, btn) {
  if (!confirm(`Confirm order ${orderNo} in Pancake? This notifies Pancake directly and cannot be undone from here.`)) return;

  btn.disabled = true;
  btn.textContent = 'Confirming...';

  const { error } = await supabaseClient.rpc('admin_confirm_gma_order_in_pancake', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo
  });

  if (error) {
    alert(`Could not confirm in Pancake: ${error.message}`);
    btn.disabled = false;
    btn.textContent = 'Confirm in Pancake';
    return;
  }

  // Let the customer know right away, with a link to their order confirmation (same public
  // receipt page/URL pattern as sendReceiptToCustomer's 'receipt' kind) - best-effort like
  // sendReceiptToCustomer/addOrderPayment's Pancake sync: the Pancake confirm above is the part
  // that must not fail silently, so a send failure here doesn't block or alert on top of it.
  const receiptLink = `https://rspetstop.com/online-order-receipt.html?order=${encodeURIComponent(orderNo)}`;
  await sendMessageToCustomer(
    `Your order has been confirmed, Please see receipt for your reference. We will keep you posted on the status of your order. Any concerns please let us know :) #HFK\n${receiptLink}`,
    []
  );

  // Force a fresh live fetch rather than trusting the RPC's own return value, so the badge reflects
  // exactly what Pancake now reports.
  orderPancakeStatusCache.delete(orderNo);
  await loadOrderExpandedDetails(orderNo);
}

// Called from the "Confirm Order" button (pancakeLiveStatusHtml) on an AI bot draft ('Not Pushed').
// admin_confirm_bot_order creates the Online Orders entry directly - no Pancake order
// (sql/supabase_bot_orders_portal_confirm.sql). On success the customer gets the same "order
// confirmed" message as Confirm in Pancake.
async function confirmBotOrder(orderNo, btn) {
  if (!confirm(`Confirm order ${orderNo}? Check the items, prices and customer details first - it goes straight into Online Orders and can't be edited here afterwards.`)) return;

  btn.disabled = true;
  btn.textContent = 'Confirming...';

  const { error } = await supabaseClient.rpc('admin_confirm_bot_order', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo
  });

  if (error) {
    alert(`Could not confirm the order: ${error.message}`);
    btn.disabled = false;
    btn.textContent = 'Confirm Order';
    return;
  }

  const receiptLink = `https://rspetstop.com/online-order-receipt.html?order=${encodeURIComponent(orderNo)}`;
  await sendMessageToCustomer(
    `Your order has been confirmed, Please see receipt for your reference. We will keep you posted on the status of your order. Any concerns please let us know :) #HFK\n${receiptLink}`,
    []
  );

  orderPancakeStatusCache.delete(orderNo);
  await loadConversationOrders(conversationOrdersConv);
}

// Called from the "Cancel in Pancake" button - only ever shown while the live-fetched status is
// 'Confirmed', matching admin_cancel_gma_order_in_pancake's own server-side guard. Per direct
// follow-up request. Note: the Cancelled status token this RPC sends to Pancake is an unverified
// guess (see that function's own header comment) - if Pancake rejects it, the alert below will show
// Pancake's real error message so the actual code can be found the same way Confirm's was.
async function cancelOrderInPancake(orderNo, btn) {
  if (!confirm(`Cancel order ${orderNo} in Pancake? This notifies Pancake directly and cannot be undone from here.`)) return;

  btn.disabled = true;
  btn.textContent = 'Cancelling...';

  const { error } = await supabaseClient.rpc('admin_cancel_gma_order_in_pancake', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo
  });

  if (error) {
    alert(`Could not cancel in Pancake: ${error.message}`);
    btn.disabled = false;
    btn.textContent = 'Cancel in Pancake';
    return;
  }

  orderPancakeStatusCache.delete(orderNo);
  await loadOrderExpandedDetails(orderNo);
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

  const { data, error } = await supabaseClient.rpc('admin_add_automated_order_payment', {
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

  // The payment itself is always recorded above regardless of this - Pancake sync is best-effort
  // (see admin_add_automated_order_payment in sql/supabase_gma_conversation_payment_pancake_sync.sql).
  const pancakeSyncError = (data || [])[0]?.pancake_sync_error;
  if (pancakeSyncError) {
    alert(`Payment recorded, but could not flow it to Pancake: ${pancakeSyncError}. It can be added on the Pancake order manually.`);
  }

  // This payment came from a flagged detection - mark that message applied so the "Payment to
  // confirm" badge and the message bubble's own "Use in Add Payment" button don't come back next
  // time this conversation is opened.
  if (activeDetectedPaymentMessageId && orderNo === flaggedOrderNo) {
    await supabaseClient.rpc('admin_mark_chatbot_payment_applied', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_message_id: activeDetectedPaymentMessageId
    });
    flaggedOrderNo = null;
    activeDetectedPaymentMessageId = null;
    await loadMessages(conv.psid);
  }

  // Payment history is stale now - drop the cache entry so orderPaymentsHtml shows "Loading..."
  // until loadOrderExpandedDetails (triggered below, via loadConversationOrders) refetches it. The
  // form itself collapses back to the toggle, same as a fresh card - nothing left sitting in it to
  // resubmit by accident.
  orderPaymentsCache.delete(orderNo);
  expandedPaymentOrderNos.delete(orderNo);
  await loadConversationOrders(conv);
}

// Per direct follow-up request - lets staff send the customer a link to either printable document
// (docs/online-order-receipt.html's plain "Order Confirmation", or docs/online-order-invoice.html's
// more formal "Invoice" - both public/no-login, safe to hand straight to a customer, unlike the
// staff-only docs/gma-order-invoice.html this same order card also links to for printing). Goes
// through the same sendMessageToCustomer used by the reply composer (targets whichever conversation
// is currently open - every order in this list belongs to it), so it's logged/broadcast/refreshed
// exactly like any other staff reply, not a separate one-off send path.
async function sendReceiptToCustomer(orderNo, kind, btn) {
  const isInvoice = kind === 'invoice';
  const link = `https://rspetstop.com/${isInvoice ? 'online-order-invoice.html' : 'online-order-receipt.html'}?order=${encodeURIComponent(orderNo)}`;
  const message = `Here's your ${isInvoice ? 'invoice' : 'order receipt'} for Order No: ${orderNo}\n${link}`;

  if (btn) btn.disabled = true;
  await sendMessageToCustomer(message, []);
  if (btn) btn.disabled = false;
}

// Xendit online payment link (pay.html, sql/supabase_xendit_payments.sql). While Xendit is switched off
// only super users see the button (marked "test") - customers opening the link are told online payment
// isn't available yet. The payment lands on the order on its own and xendit-webhook messages the customer.
let xenditEnabled = false;
Promise.resolve(supabaseClient.rpc('public_get_xendit_settings')).then(({ data, error }) => {
  xenditEnabled = !error && !!(data && data[0] && data[0].enabled);
  if (xenditEnabled && conversationOrders.length) renderConversationOrderCards();
}).catch(() => {});

// Portal orders only (drafts and confirmed portal orders) - online payment refuses old Pancake orders.
function canSendPayLink(o, balance) {
  if (!o || balance <= 0 || o.status === 'Completed' || o.status === 'Cancelled') return false;
  if (o.pancake_sync_status !== 'Not Pushed' && o.pancake_sync_status !== 'Portal') return false;
  return xenditEnabled || !!currentSession?.isSuperUser;
}

function payLinkPeso(value) {
  return '₱' + Number(value || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

async function sendPayLinkToCustomer(o, btn) {
  if (!o) return;
  const total = Number(o.estimated_total || 0);
  const paid = Number(o.amount_paid || 0);
  const balance = Number(o.balance || 0);
  // Same 50% rule as the pay page (_xendit_down_payment_due).
  const downDue = Math.min(Math.max(Math.ceil(total / 2) - paid, 0), balance);
  const link = `https://rspetstop.com/pay.html?order=${encodeURIComponent(o.order_no)}`;
  const amounts = downDue > 0 && downDue < balance
    ? `Down payment (50%): ${payLinkPeso(downDue)}\nFull balance: ${payLinkPeso(balance)}`
    : `Balance: ${payLinkPeso(balance)}`;
  const message = `💳 You can pay for your order ${o.order_no} online here:\n${link}\n\n${amounts}\n\n`
    + 'Pay with GCash, Maya, card, QR Ph or online banking (secured by Xendit). Your payment shows on your order automatically.';

  const offNote = xenditEnabled ? '' : '\n\n⚠️ Xendit is switched OFF - the customer will see "Online payment isn\'t available yet". Only send this to a test chat.';
  if (!window.confirm(`Send this to the customer?\n\n${message}${offNote}`)) return;

  if (btn) btn.disabled = true;
  await sendMessageToCustomer(message, []);
  if (btn) btn.disabled = false;
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
  resultsEl.innerHTML = orders.map((o) => {
    const balance = Number(o.balance || 0);
    return `
    <div class="inbox-order-item">
      <div class="inbox-order-top">
        <a href="online-order-lines.html?order=${encodeURIComponent(o.order_id)}">${escapeHtml(o.order_id)}</a>
        <div class="inbox-order-badges">${orderStatusBadgeHtml(o.status)}</div>
      </div>
      <div class="inbox-order-meta">${escapeHtml(o.customer_name || '')} - ${o.order_date || ''}</div>
      <div class="inbox-order-stats">
        <div class="inbox-order-stat">
          <span class="inbox-order-stat-label">Balance</span>
          <span class="inbox-order-stat-value ${balance > 0 ? 'balance-due' : 'balance-clear'}">${balance.toFixed(2)}</span>
        </div>
      </div>
    </div>
  `;
  }).join('');
}

// Create Order tab - creates a real AutomatedOrders row stamped with this conversation's
// GmaPsid/GmaPageId (admin_create_gma_conversation_order). Item search uses staff_search_items_wildcard
// (free-text, anon, name/price/stock only - same safe field set as public_list_order_items) instead
// of order-now.html's category-then-item cascading dropdowns, matching Pancake's single product
// search box. newOrderLines persists across tab switches (only reset by Clear or a successful
// submit) so flipping to Information and back doesn't lose an in-progress cart.
let newOrderConv = null;
let newOrderLines = [];
// Set by editOrder() (see above) to the full AutomatedOrders row (from conversationOrders) being
// edited - switches renderCreateOrderTab/submitNewOrder into "edit an existing order" mode instead
// of "create a new order". Null in the normal create flow.
let editingOrder = null;
// Wholesale pricing switch (sql/supabase_bot_order_wholesale_pricing.sql) - on: eligible lines
// (Aquarium/Stand/Sump with a wholesale price) carry their wholesale price, and the order must reach
// WHOLESALE_MIN_TOTAL on those lines. Lines keep retail_price so switching off restores it.
const WHOLESALE_MIN_TOTAL = 5000;
let newOrderWholesale = false;
let editingOrderWasWholesale = false;
const wholesaleInfoByCode = new Map(); // item code -> { wholesale_price, retail_price }, eligible only
const wholesaleCheckedCodes = new Set(); // codes already looked up (eligible or not)
let lineNoteModalIndex = null;
let productSearchDebounce = null;
let productSearchResultsCache = [];
let phoneMatchDebounce = null;

function renderCreateOrderTab(conv) {
  const bodyEl = document.getElementById('panelTabBody');

  bodyEl.innerHTML = `
    <p class="error-text hidden" id="newOrderError"></p>

    ${editingOrder ? `
    <div class="inbox-order-edit-banner">
      <span>Editing order ${escapeHtml(editingOrder.order_no)}</span>
      <button type="button" class="btn-text" id="cancelEditOrderBtn">Cancel edit</button>
    </div>
    ` : ''}

    <div class="form-group og-customer">
      <div class="form-group-title">
        <span class="og-step">1</span>
        <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="10" cy="6.5" r="3"/><path d="M3.5 16.5c0-3.3 2.9-5.5 6.5-5.5s6.5 2.2 6.5 5.5" stroke-linecap="round"/></svg>
        Customer
      </div>
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
            <option value="GMA" selected>GMA</option>
          </select>
        </div>
      </div>
      <div class="form-grid">
        <div class="form-row">
          <label>Fulfillment</label>
          <div class="fulfillment-toggle" id="newOrderFulfillmentToggle">
            <button type="button" class="fulfillment-toggle-btn active" data-value="Pickup">Pickup</button>
            <button type="button" class="fulfillment-toggle-btn" data-value="Delivery">Delivery</button>
          </div>
          <input type="hidden" id="newOrderFulfillment" value="Pickup">
        </div>
        <div class="form-row hidden" id="newOrderDeliveryAddressRow">
          <label>Delivery Address</label>
          <input type="text" id="newOrderDeliveryAddress">
        </div>
        <div class="form-row hidden" id="newOrderDeliveryFeeRow">
          <label>Delivery Fee</label>
          <input type="number" min="0" step="0.01" id="newOrderDeliveryFee" placeholder="0.00">
        </div>
      </div>
      <div class="form-row" style="margin-bottom:0;">
        <label>Notes (optional)</label>
        <input type="text" id="newOrderNotes">
      </div>
    </div>

    <div class="form-group og-product">
      <div class="form-group-title">
        <span class="og-step">2</span>
        <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6">
          <path d="M3 6.5 10 3l7 3.5-7 3.5-7-3.5Z" stroke-linejoin="round" stroke-linecap="round" />
          <path d="M3 6.5v7L10 17l7-3.5v-7" stroke-linejoin="round" stroke-linecap="round" />
          <path d="M10 10v7" stroke-linecap="round" />
        </svg>
        Products
      </div>
      <label class="wholesale-toggle">
        <input type="checkbox" id="newOrderWholesale">
        <span>Wholesale pricing</span>
        <small>Aquarium / Stand / Sump only &middot; min &#8369;${WHOLESALE_MIN_TOTAL.toLocaleString()}</small>
      </label>
      <div class="product-search-wrap">
        <input type="text" id="productSearchInput" placeholder="Search product by name...">
        <div id="productSearchResults" class="product-search-results hidden"></div>
      </div>
      <div class="custom-build-label">Or build a custom item</div>
      <div class="custom-build-grid">
        <button type="button" class="custom-build-tile tile-aquarium" id="openCustomQuoteBtn">
          <span class="tile-icon"><svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="2.5" y="4" width="15" height="11" rx="1.2"/><path d="M2.5 11c2-1.2 3.5-1.2 5 0s3 1.2 5 0 3.5-1.2 5 0" stroke-linecap="round"/><path d="M5 17.5h10" stroke-linecap="round"/></svg></span>
          Custom Aquarium
          <small>+ stand, sump, stickers</small>
        </button>
        <button type="button" class="custom-build-tile tile-stand" id="openCustomStandBtn">
          <span class="tile-icon"><svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M3 4.5h14M3 10h14M4 4.5v12M16 4.5v12" stroke-linecap="round"/></svg></span>
          Custom Stand
          <small>stand only</small>
        </button>
        <button type="button" class="custom-build-tile tile-sticker" id="openCustomStickerBtn">
          <span class="tile-icon"><svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M4 3.5h8.5l4 4V16a.5.5 0 0 1-.5.5H4a.5.5 0 0 1-.5-.5V4a.5.5 0 0 1 .5-.5Z" stroke-linejoin="round"/><path d="M12.5 3.5v4h4" stroke-linejoin="round"/></svg></span>
          Stickers
          <small>accessories, glass, mats</small>
        </button>
      </div>

      <div class="order-lines-list" id="newOrderLinesBody"></div>
      <div class="wholesale-meter hidden" id="newOrderWholesaleMeter"></div>
    </div>

    <div class="form-group og-payment">
      <div class="form-group-title">
        <span class="og-step">3</span>
        <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="2.5" y="5" width="15" height="10" rx="1.5"/><path d="M2.5 8.5h15" stroke-linecap="round"/></svg>
        Payment (optional)
      </div>
      <div class="form-grid">
        <div class="form-row">
          <label>Amount</label>
          <input type="number" min="0.01" step="0.01" id="newOrderPayAmount" placeholder="0.00">
        </div>
        <div class="form-row">
          <label>Method</label>
          <select id="newOrderPayMethod">
            <option value="Cash">Cash</option>
            <option value="GCash">GCash</option>
            <option value="BDO">BDO</option>
            <option value="Metrobank">Metrobank</option>
            <option value="Bank Transfer">Bank Transfer</option>
            <option value="Other">Other</option>
          </select>
        </div>
      </div>
      <div class="form-row" style="margin-bottom:0;">
        <label>Reference (optional)</label>
        <input type="text" id="newOrderPayReference">
      </div>
    </div>

    <div class="inbox-order-sticky-footer">
      <div class="new-order-total-bar">
        <span class="new-order-total-label">Order Total</span>
        <span class="new-order-total-value" id="newOrderTotalEl">0.00</span>
      </div>
      <div class="inbox-order-actions">
        ${editingOrder ? '' : '<button type="button" class="btn btn-secondary" id="newOrderClearBtn">Clear</button>'}
        <button type="button" class="btn btn-primary" id="newOrderSubmitBtn">${editingOrder ? 'Save Changes' : 'Create'}</button>
      </div>
    </div>
  `;

  if (editingOrder) {
    // Prefills every field this same form lets staff set on creation - admin_update_automated_order
    // fully replaces the order's header/lines with whatever's submitted, so anything left blank here
    // would actually clear it server-side, not just leave it unchanged.
    document.getElementById('newOrderCustomerName').value = editingOrder.customer_name || '';
    document.getElementById('newOrderCustomerPhone').value = editingOrder.customer_phone || '';
    document.getElementById('newOrderCustomerEmail').value = editingOrder.customer_email || '';
    document.getElementById('newOrderLocation').value = editingOrder.location || 'Amaya';
    document.getElementById('newOrderNotes').value = editingOrder.notes || '';
    if (editingOrder.fulfillment_type === 'Delivery') {
      document.querySelectorAll('#newOrderFulfillmentToggle .fulfillment-toggle-btn').forEach((b) => b.classList.toggle('active', b.dataset.value === 'Delivery'));
      document.getElementById('newOrderFulfillment').value = 'Delivery';
      document.getElementById('newOrderDeliveryAddressRow').classList.remove('hidden');
      document.getElementById('newOrderDeliveryAddress').value = editingOrder.delivery_address || '';
      document.getElementById('newOrderDeliveryFeeRow').classList.remove('hidden');
      document.getElementById('newOrderDeliveryFee').value = Number(editingOrder.delivery_fee || 0) > 0 ? Number(editingOrder.delivery_fee).toFixed(2) : '';
    }
  } else {
    // Prefilled from the CRM name (ChatbotConversations.CustomerName - the name they gave for orders,
    // else their Facebook name), not authoritative - staff can still edit it.
    document.getElementById('newOrderCustomerName').value = conv.crm_name || conv.customer_name || '';
    prefillCreateOrderFromCustomer(conv);
  }

  const wholesaleInput = document.getElementById('newOrderWholesale');
  wholesaleInput.checked = newOrderWholesale;
  wholesaleInput.addEventListener('change', () => setNewOrderWholesale(wholesaleInput.checked));

  document.getElementById('newOrderClearBtn')?.addEventListener('click', () => {
    newOrderLines = [];
    newOrderWholesale = false;
    renderCreateOrderTab(conv);
  });
  document.getElementById('cancelEditOrderBtn')?.addEventListener('click', () => {
    editingOrder = null;
    newOrderWholesale = false;
    newOrderLines = [];
    activeCustomerTab = 'info';
    renderCustomerPanel(conv);
  });
  document.getElementById('newOrderSubmitBtn').addEventListener('click', submitNewOrder);
  document.getElementById('openCustomQuoteBtn').addEventListener('click', () => openCalcEmbedModal('aquarium'));
  document.getElementById('openCustomStandBtn').addEventListener('click', () => openCalcEmbedModal('stand'));
  document.getElementById('openCustomStickerBtn').addEventListener('click', openCustomStickerModal);
  document.querySelectorAll('#newOrderFulfillmentToggle .fulfillment-toggle-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('#newOrderFulfillmentToggle .fulfillment-toggle-btn').forEach((b) => b.classList.toggle('active', b === btn));
      document.getElementById('newOrderFulfillment').value = btn.dataset.value;
      document.getElementById('newOrderDeliveryAddressRow').classList.toggle('hidden', btn.dataset.value !== 'Delivery');
      document.getElementById('newOrderDeliveryFeeRow').classList.toggle('hidden', btn.dataset.value !== 'Delivery');
      updateOrderTotal();
    });
  });
  document.getElementById('newOrderDeliveryFee').addEventListener('input', updateOrderTotal);

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

// Create Order pre-fill - per "when the user creates new order this will fill in Phone or contact
// number / email and location". staff_get_gma_customer_prefill (sql/supabase_gma_create_order_prefill.sql)
// returns the customer's saved Contacts & Addresses (default first), email and last order's branch.
// Only empty fields are filled (never what staff already typed), and only on a new order. A customer
// with more than one number / address gets the others as one-click chips under the field.
async function prefillCreateOrderFromCustomer(conv) {
  if (!conv?.psid || conv.page_id === 'website') return;
  const { data, error } = await supabaseClient.rpc('staff_get_gma_customer_prefill', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: conv.psid,
    p_page_id: conv.page_id
  });
  if (error) {
    // Not set up yet (SQL not run) or no access - the form just stays blank, as before.
    console.warn('Create Order pre-fill unavailable:', error.message);
    return;
  }
  // Switched conversation / tab, or started editing an order, while this was loading.
  const phoneInput = document.getElementById('newOrderCustomerPhone');
  if (!phoneInput || editingOrder || newOrderConv?.psid !== conv.psid) return;

  const rows = data || [];
  const ofKind = (kind) => rows.filter((r) => r.kind === kind && r.value);
  const phones = ofKind('Phone');
  const addresses = ofKind('Address');
  const email = ofKind('Email')[0];
  const location = ofKind('Location')[0];

  const fillIfEmpty = (input, value) => {
    if (!input || !value || input.value.trim()) return false;
    input.value = value;
    return true;
  };

  if (fillIfEmpty(phoneInput, phones[0]?.value)) checkPhoneMatch();
  // A chip fires the field's input event, so the phone-match check runs on its own.
  renderPrefillAlternatives(phoneInput, phones, 'number');

  fillIfEmpty(document.getElementById('newOrderCustomerEmail'), email?.value);

  const addressInput = document.getElementById('newOrderDeliveryAddress');
  fillIfEmpty(addressInput, addresses[0]?.value);
  renderPrefillAlternatives(addressInput, addresses, 'address');

  if (location) {
    const select = document.getElementById('newOrderLocation');
    if (select && [...select.options].some((o) => o.value === location.value)) {
      select.value = location.value;
      let note = document.getElementById('newOrderLocationNote');
      if (!note) {
        select.insertAdjacentHTML('afterend', '<div class="prefill-note" id="newOrderLocationNote"></div>');
        note = document.getElementById('newOrderLocationNote');
      }
      note.textContent = 'Same branch as their last order';
    }
  }
}

// "Saved numbers: [0917... ★] [0918...]" under a field - click one to use it instead.
function renderPrefillAlternatives(input, entries, noun) {
  if (!input) return;
  input.parentElement.querySelector('.prefill-alts')?.remove();
  if (entries.length < 2) return;
  input.insertAdjacentHTML('afterend', `
    <div class="prefill-alts">
      <span>Saved ${noun === 'number' ? 'numbers' : 'addresses'}:</span>
      ${entries.map((e) => `<button type="button" data-prefill-value="${escapeHtml(e.value)}" title="${escapeHtml(e.value)}">${escapeHtml(e.label ? `${e.label}: ${e.value}` : e.value)}${e.is_default ? ' ★' : ''}</button>`).join('')}
    </div>`);
  input.parentElement.querySelectorAll('.prefill-alts [data-prefill-value]').forEach((btn) => {
    btn.addEventListener('click', () => {
      input.value = btn.dataset.prefillValue;
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
  });
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

  const { data, error } = await supabaseClient.rpc('staff_search_items_wildcard', { p_query: term });

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

// Per direct follow-up request (screenshot of this exact search box): a product WITH variants
// (color/size/etc - has_variants, see sql/supabase_chatbot_search_items_variants.sql) opens the
// variant picker modal instead of adding the generic parent product straight away - staff need to
// choose which specific one before it's added.
function addProductToOrder(item) {
  if (item.has_variants) {
    openVariantPickerModal(item);
    return;
  }
  addOrderLineFromProduct(item, null);
}

// Shared by addProductToOrder (no variants) and selectVariantForOrder (a variant WAS chosen) -
// variant is null for a plain product add. Naming ("Product (Variant - SKU)") and the SKU-appended-
// when-present rule match resolveProductLookupEntry's own variant handling in the reply composer's
// separate Product List panel, for the same reason it exists there: VariantName alone is frequently
// IDENTICAL across a product's variants (e.g. two sealant colors), only the SKU actually
// distinguishes them.
function addOrderLineFromProduct(item, variant) {
  const variantLabel = variant ? (variant.sku ? `${variant.variant_name} - ${variant.sku}` : variant.variant_name) : null;
  const itemName = variant ? `${item.name} (${variantLabel})` : item.name;
  const price = variant ? Number(variant.price || 0) : Number(item.price || 0);
  const variationId = variant ? variant.variation_id : null;

  // Dedupe by the specific variant when one was chosen (two different variants of the same product
  // must stay separate lines) - falls back to item_code for a plain product add, same as before.
  const dedupeKey = variationId || item.code;
  const existing = newOrderLines.find((line) => (line.variation_id || line.item_code) === dedupeKey);
  if (existing) {
    existing.quantity += 1;
  } else {
    newOrderLines.push({
      category_code: item.category_code,
      item_code: item.code,
      item_name: itemName,
      price,
      quantity: 1,
      note: '',
      variation_id: variationId
    });
  }

  const searchInput = document.getElementById('productSearchInput');
  if (searchInput) searchInput.value = '';
  document.getElementById('productSearchResults')?.classList.add('hidden');
  renderNewOrderLines();
  if (newOrderWholesale) applyWholesalePrices();
}

// Looks up wholesale prices for any line item codes not checked yet (staff_get_item_wholesale_prices).
// p_order_no also returns that order's saved flag (edit mode). Returns that flag, or null.
async function loadWholesaleInfo(orderNo = null) {
  const codes = [...new Set(newOrderLines.map((l) => l.item_code).filter((c) => c && !wholesaleCheckedCodes.has(c)))];
  if (codes.length === 0 && !orderNo) return null;
  const { data, error } = await supabaseClient.rpc('staff_get_item_wholesale_prices', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_item_codes: codes,
    p_order_no: orderNo
  });
  if (error) {
    console.warn('Wholesale prices unavailable:', error.message);
    return null;
  }
  codes.forEach((c) => wholesaleCheckedCodes.add(c));
  (data?.items || []).forEach((it) => wholesaleInfoByCode.set(it.code, {
    wholesale_price: Number(it.wholesale_price) || 0,
    retail_price: Number(it.retail_price) || 0
  }));
  return data?.is_wholesale ?? null;
}

// Puts every eligible line on its wholesale price (switch on) - lines added later get it from
// addOrderLineFromProduct. A line staff already re-priced by hand while on wholesale is left alone.
async function applyWholesalePrices() {
  await loadWholesaleInfo();
  if (!newOrderWholesale) return;
  newOrderLines.forEach((line) => {
    const info = wholesaleInfoByCode.get(line.item_code);
    if (!info || line.wholesale_applied) return;
    line.retail_price = line.price;
    line.price = info.wholesale_price;
    line.wholesale_applied = true;
  });
  renderNewOrderLines();
}

function setNewOrderWholesale(on) {
  newOrderWholesale = on;
  if (on) {
    applyWholesalePrices();
    return;
  }
  newOrderLines.forEach((line) => {
    if (!line.wholesale_applied) return;
    line.price = line.retail_price ?? wholesaleInfoByCode.get(line.item_code)?.retail_price ?? line.price;
    line.wholesale_applied = false;
  });
  renderNewOrderLines();
}

function newOrderWholesaleTotal() {
  return newOrderLines.filter((l) => l.wholesale_applied).reduce((sum, l) => sum + l.price * l.quantity, 0);
}

function updateWholesaleMeter() {
  const meterEl = document.getElementById('newOrderWholesaleMeter');
  if (!meterEl) return;
  meterEl.classList.toggle('hidden', !newOrderWholesale);
  if (!newOrderWholesale) return;
  const total = newOrderWholesaleTotal();
  const short = WHOLESALE_MIN_TOTAL - total;
  const peso = (n) => `&#8369;${n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  meterEl.classList.toggle('is-short', short > 0);
  meterEl.innerHTML = newOrderLines.some((l) => l.wholesale_applied)
    ? `Wholesale items ${peso(total)} of ${peso(WHOLESALE_MIN_TOTAL)} minimum${short > 0 ? ` &middot; short by <strong>${peso(short)}</strong>` : ' &middot; minimum reached'}`
    : 'No wholesale-priced items yet - only individual Aquarium / Stand / Sump items with a wholesale price qualify (not Sets or custom builds).';
}

let variantPickerProduct = null;

async function openVariantPickerModal(item) {
  variantPickerProduct = item;
  document.getElementById('variantPickerProductName').textContent = item.name;
  const listEl = document.getElementById('variantPickerList');
  listEl.innerHTML = '<div class="inbox-empty-state">Loading...</div>';
  document.getElementById('variantPickerModal').classList.remove('hidden');

  const { data, error } = await supabaseClient.rpc('public_list_item_variants', { p_item_code: item.code });

  // Superseded by a newer open call (staff clicked a different product) while this was in flight.
  if (variantPickerProduct !== item) return;

  if (error) {
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }

  const variants = data || [];
  if (variants.length === 0) {
    listEl.innerHTML = '<div class="inbox-empty-state">No variants found for this product.</div>';
    return;
  }

  listEl.innerHTML = variants.map((v, index) => {
    const inStock = Number(v.quantity_in_stock || 0) > 0;
    return `
      <div class="variant-picker-row" data-index="${index}">
        <div class="variant-picker-row-info">
          <div class="variant-picker-row-name">${escapeHtml(v.variant_name)}</div>
          ${v.sku ? `<div class="variant-picker-row-sku">${escapeHtml(v.sku)}</div>` : ''}
        </div>
        <div class="variant-picker-row-meta">
          <div class="variant-picker-row-price">${Number(v.price || 0).toFixed(2)}</div>
          <div class="${inStock ? '' : 'out-of-stock'}">${inStock ? `${v.quantity_in_stock} left` : 'Out of stock'}</div>
        </div>
      </div>
    `;
  }).join('');

  listEl.querySelectorAll('.variant-picker-row').forEach((row) => {
    row.addEventListener('click', () => selectVariantForOrder(variants[parseInt(row.dataset.index, 10)]));
  });
}

function closeVariantPickerModal() {
  variantPickerProduct = null;
  document.getElementById('variantPickerModal').classList.add('hidden');
}

function selectVariantForOrder(variant) {
  if (!variantPickerProduct) return;
  addOrderLineFromProduct(variantPickerProduct, variant);
  closeVariantPickerModal();
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
    bodyEl.innerHTML = '<div class="order-lines-empty">No items added yet - search a product or build a custom item above.</div>';
    updateOrderTotal();
    return;
  }

  // One card per line (per "let the user remove per item instead of clear all") - the old 5-column
  // table was wider than this panel, so its last column (the remove button) got clipped out of view.
  bodyEl.innerHTML = newOrderLines.map((line, index) => `
    <div class="order-line-card" data-row="${index}">
      <div class="order-line-top">
        <div class="order-line-name">${escapeHtml(line.item_name)}${line.wholesale_applied ? ' <span class="wholesale-chip">Wholesale</span>' : ''}</div>
        <button type="button" class="line-note-btn${line.note ? ' has-note' : ''}" data-index="${index}" title="${line.note ? escapeHtml(line.note) : 'Add a note'}">&#9998;</button>
        <button type="button" class="line-remove-btn" title="Remove this item" data-index="${index}">
          <svg viewBox="0 0 20 20" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M4 6h12M8 6V4.5h4V6M6 6l.7 10h6.6L14 6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          Remove
        </button>
      </div>
      <div class="order-line-bottom">
        <div class="qty-stepper">
          <button type="button" class="qty-step-btn" data-index="${index}" data-dir="-1" title="Decrease">&minus;</button>
          <input type="number" class="line-qty-input" data-index="${index}" value="${line.quantity}" min="1" step="1">
          <button type="button" class="qty-step-btn" data-index="${index}" data-dir="1" title="Increase">&plus;</button>
        </div>
        <span class="order-line-x">&times;</span>
        <input type="number" class="line-price-input" data-index="${index}" value="${line.price}" min="0" step="0.01" title="Unit price">
        <div class="order-line-total">&#8369; <span class="line-total-cell">${(line.price * line.quantity).toFixed(2)}</span></div>
      </div>
    </div>
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
  bodyEl.querySelectorAll('.line-note-btn').forEach((btn) => {
    btn.addEventListener('click', () => openLineNoteModal(parseInt(btn.dataset.index, 10)));
  });
  bodyEl.querySelectorAll('.qty-step-btn').forEach((btn) => {
    btn.addEventListener('click', () => stepLineQuantity(parseInt(btn.dataset.index, 10), parseInt(btn.dataset.dir, 10)));
  });
}

function openLineNoteModal(index) {
  const line = newOrderLines[index];
  if (!line) return;
  lineNoteModalIndex = index;
  document.getElementById('lineNoteModalItemName').textContent = line.item_name;
  document.getElementById('lineNoteModalTextarea').value = line.note || '';
  document.getElementById('lineNoteModal').classList.remove('hidden');
  document.getElementById('lineNoteModalTextarea').focus();
}

function closeLineNoteModal() {
  lineNoteModalIndex = null;
  document.getElementById('lineNoteModal').classList.add('hidden');
}

// Whatever's typed here is sent to Pancake's line 'note' field exactly as-is (see
// _push_automated_order_to_pancake in sql/supabase_gma_conversation_order_line_notes.sql) - no
// trimming/prefixing, per direct instruction.
function saveLineNoteModal() {
  const line = newOrderLines[lineNoteModalIndex];
  if (line) {
    line.note = document.getElementById('lineNoteModalTextarea').value;
    renderNewOrderLines();
  }
  closeLineNoteModal();
}

// Used by the +/- stepper buttons only - typing directly into the qty input still goes through
// updateLineField above (which deliberately avoids re-rendering the row, so it doesn't steal focus
// mid-keystroke). A button click has no focus to preserve, so this just re-syncs that one row's
// input/total directly.
function stepLineQuantity(index, delta) {
  const line = newOrderLines[index];
  if (!line) return;
  line.quantity = Math.max(line.quantity + delta, 1);

  const row = document.querySelector(`#newOrderLinesBody [data-row="${index}"]`);
  if (row) {
    row.querySelector('.line-qty-input').value = line.quantity;
    row.querySelector('.line-total-cell').textContent = (line.price * line.quantity).toFixed(2);
  }
  updateOrderTotal();
}

function updateLineField(index, field, rawValue) {
  const line = newOrderLines[index];
  if (!line) return;

  line[field] = field === 'quantity'
    ? Math.max(parseInt(rawValue, 10) || 1, 1)
    : Math.max(parseFloat(rawValue) || 0, 0);

  const row = document.querySelector(`#newOrderLinesBody [data-row="${index}"]`);
  if (row) row.querySelector('.line-total-cell').textContent = (line.price * line.quantity).toFixed(2);

  updateOrderTotal();
}

function updateOrderTotal() {
  const totalEl = document.getElementById('newOrderTotalEl');
  if (!totalEl) return;
  const total = newOrderLines.reduce((sum, line) => sum + (line.price * line.quantity), 0) + newOrderDeliveryFee();
  totalEl.textContent = total.toFixed(2);
  updateWholesaleMeter();
}

// Delivery Fee box (Delivery only - Pickup always counts/saves 0, same as the server).
function newOrderDeliveryFee() {
  if (document.getElementById('newOrderFulfillment')?.value !== 'Delivery') return 0;
  const fee = parseFloat(document.getElementById('newOrderDeliveryFee')?.value);
  return fee > 0 ? fee : 0;
}

// Full build sheet helpers for custom line notes - per "do better details on the note if the order is
// customized.. be specific" (used by the sticker modal below; the aquarium/stand builders take theirs
// straight from the embedded calculator - see calcEmbedNote).
const fmtIn = (v) => `${Number(v).toFixed(2).replace(/\.?0+$/, '')}`;

function customEnteredSizeText(unit, values) {
  if (!unit || unit === 'Inches') return '';
  return ` (entered as ${values.map(fmtIn).join(' x ')} ${unit.toLowerCase()})`;
}

// Custom Aquarium / Custom Stand builders - per "we have our custom aquarium calculator and Stand
// calculator can we use that". Instead of a cut-down copy of their fields, the real calculator pages
// (WebAquariumCalculator/index.html and stand.html - every option, the drawing, the glass cut sheet)
// open in a same-origin iframe, the same way the portal's Aquarium/Stand Calculator nav pages embed
// them. The footer reads the calculator's own globals (lastResult, computeQuotedTotal,
// lastDetailRows) so the lines added here are priced exactly as the calculator shows them:
//   Aquarium page -> CUSTOM-AQUARIUM x Quantity, + CUSTOM-STAND x Stand Quantity, + CUSTOM-SUMP x Sump
//                    Quantity (when the sump is priced separately), matching computeQuotedTotal.
//   Stand page    -> CUSTOM-STAND x Qty.
const CALC_EMBED_KINDS = {
  aquarium: {
    src: 'WebAquariumCalculator/index.html?embed=gma',
    title: 'Custom Aquarium',
    quoteTitle: 'Custom Aquarium Quote',
    sub: 'Full calculator - aquarium plus optional stand, sump and stickers. Build it, then Add to Order.'
  },
  stand: {
    src: 'WebAquariumCalculator/stand.html?embed=gma',
    title: 'Custom Stand Only',
    quoteTitle: 'Custom Stand Quote',
    sub: 'A stand with no aquarium - priced off its own length and width. Build it, then Add to Order.'
  },
  // Reply mode only (no Create Order tile - repairs aren't an order line type yet). The portal's own
  // Repair Calculator page; js/repairCalculator.js posts rs-repair-state when ?embed=gma.
  repair: {
    src: 'repair-calculator.html?embed=gma',
    title: 'Repair',
    quoteTitle: 'Repair Quote',
    sub: ''
  }
};
const CALC_TUBULAR_LABELS = { '1x1': '1x1', '1.5x1.5': '1 1/2x1 1/2', '2x2': '2x2' };
let calcEmbedKind = null;
let calcEmbedPollTimer = null;
let calcEmbedPendingLines = [];
let calcEmbedProblem = '';
let calcEmbedFooterKey = '';
// Latest quote the calculator posted (see WebAquariumCalculator/calc-embed-bridge.js). Read via
// postMessage, not contentWindow - the browser treated the iframe as another origin ("Can't read
// the calculator from this page"), which blocks direct access but not messages.
let calcEmbedSnapshot = null;
let calcEmbedOpenedAt = 0;
// 'order' = Create Order tab tiles (Add to Order); 'reply' = the composer's Aquarium quote button
// (Put in reply - customer-facing quote text, no order needed). Same calculator and build either way.
let calcEmbedMode = 'order';

window.addEventListener('message', (event) => {
  const frame = document.getElementById('calcEmbedFrame');
  if (!frame || event.source !== frame.contentWindow) return;
  if (!event.data || (event.data.type !== 'rs-calc-state' && event.data.type !== 'rs-repair-state')) return;
  calcEmbedSnapshot = event.data;
  refreshCalcEmbedFooter();
});

function sendCalcEmbedInit() {
  const frame = document.getElementById('calcEmbedFrame');
  try {
    frame.contentWindow.postMessage({ type: 'rs-calc-embed-init' }, '*');
  } catch (err) {
    // not loaded yet - the next poll retries
  }
}

// prefill (optional, e.g. from a message's "Quote this" chip): { length, width, height, unit } - always
// starts a fresh build, passed as the calculator's own link params (index.html applyLinkedQuoteParams
// fills them and calculates; its glass safety check auto-upgrades the glass for the size).
function openCalcEmbedModal(kind, mode = 'order', prefill = null) {
  const cfg = CALC_EMBED_KINDS[kind];
  if (prefill) calcEmbedKind = null;
  calcEmbedMode = mode;
  document.getElementById('calcEmbedTitle').textContent = mode === 'reply' ? cfg.quoteTitle : cfg.title;
  document.getElementById('calcEmbedSub').textContent = mode === 'reply'
    ? 'Build it, then Put in reply - the price and drawing link go into the reply box for you to check and send.'
    : cfg.sub;
  document.getElementById('addCalcEmbedToOrderBtn').textContent = mode === 'reply' ? 'Put in reply' : 'Add to Order';
  document.getElementById('calcEmbedPanel').classList.toggle('calc-embed-stand', kind === 'stand');
  // Reopening the same calculator keeps what was already typed (e.g. closed by accident); switching
  // calculators, or reopening after Add to Order, starts fresh.
  if (calcEmbedKind !== kind) {
    calcEmbedKind = kind;
    calcEmbedSnapshot = null;
    calcEmbedOpenedAt = Date.now();
    const frame = document.getElementById('calcEmbedFrame');
    frame.onload = sendCalcEmbedInit;
    frame.src = prefill ? `${cfg.src}&${new URLSearchParams(prefill).toString()}` : cfg.src;
  }
  document.getElementById('calcEmbedModal').classList.remove('hidden');
  // Re-sends init every 1.5s while open: covers the iframe finishing its load before/after our
  // handler and the calculator's own Reset (which reloads it). The bridge only posts on change.
  clearInterval(calcEmbedPollTimer);
  calcEmbedPollTimer = setInterval(() => {
    sendCalcEmbedInit();
    refreshCalcEmbedFooter();
  }, 1500);
  sendCalcEmbedInit();
  refreshCalcEmbedFooter();
}

function closeCalcEmbedModal() {
  clearInterval(calcEmbedPollTimer);
  calcEmbedPollTimer = null;
  document.getElementById('calcEmbedModal').classList.add('hidden');
}

function refreshCalcEmbedFooter() {
  const state = readCalcEmbedState();
  calcEmbedPendingLines = state.lines;
  calcEmbedProblem = state.problem;
  renderCalcEmbedFooter();
}

// The posted snapshot dressed up as the calculator window the line builders below expect
// (lastResult / computeQuotedTotal / lastDetailRows / document.getElementById(id).value|checked).
function calcEmbedWinFromSnapshot(s) {
  const fields = s.fields || {};
  const doc = {
    getElementById: (id) => {
      if (!(id in fields)) return null;
      return typeof fields[id] === 'boolean' ? { checked: fields[id], value: '' } : { value: fields[id], checked: false };
    }
  };
  return {
    lastResult: s.result,
    computeQuotedTotal: s.quote ? () => s.quote : undefined,
    lastDetailRows: Array.isArray(s.detailRows) ? s.detailRows : [],
    document: doc
  };
}

// What's stopping Add to Order, in plain words - per "the add to order is still disabled. Can we
// point out the user what is it missing?". Checked in order: has the calculator answered at all,
// required fields, the calculator's own error (e.g. sump holder width), then the priced result.
function readCalcEmbedState() {
  if (!calcEmbedSnapshot) {
    return {
      lines: [],
      problem: Date.now() - calcEmbedOpenedAt < 8000
        ? 'Loading the calculator...'
        : "The calculator isn't responding - press Ctrl+F5 to reload this page, then open it again."
    };
  }
  if (calcEmbedKind === 'repair') {
    const s = calcEmbedSnapshot;
    if (!s.ready) return { lines: [], problem: s.problem || 'Loading repair pricing...' };
    // One line for the whole repair; the per-panel breakdown rides in the note for the reply text.
    return {
      lines: [{
        item_name: s.spec,
        price: Math.round(Number(s.total) * 100) / 100,
        quantity: 1,
        note: (s.rows || []).map((r) => `${r.label} - ${r.value}`).join('\n')
      }],
      problem: ''
    };
  }
  const win = calcEmbedWinFromSnapshot(calcEmbedSnapshot);

  const missing = calcEmbedMissingFields(win.document);
  if (missing.length) return { lines: [], problem: `Missing: ${missing.join(', ')}` };

  const r = win.lastResult;
  if (r && !r.ok) return { lines: [], problem: r.error || 'The calculator could not price this - check its fields.' };
  if (!r) return { lines: [], problem: 'Waiting for a price - press Calculate in the calculator.' };

  try {
    const lines = calcEmbedKind === 'stand' ? buildStandCalcLines(win) : buildAquariumCalcLines(win);
    return lines.length ? { lines, problem: '' } : { lines: [], problem: 'Waiting for a price - press Calculate in the calculator.' };
  } catch (err) {
    return { lines: [], problem: `Could not read the quote: ${err.message}` };
  }
}


function calcEmbedMissingFields(doc) {
  const num = (id) => Number(doc.getElementById(id)?.value) || 0;
  const checked = (id) => Boolean(doc.getElementById(id)?.checked);
  const missing = [];
  // Sump only (aquarium calculator) hides the tank fields - only the sump's own size matters.
  const sumpOnly = calcEmbedKind !== 'stand' && doc.getElementById('option')?.value === 'Sump only';
  // Sealant colour (aquarium calculator, incl. Sump only) - required, same as the POS's Add to sale.
  const noSealant = calcEmbedKind !== 'stand' && !doc.getElementById('sealant')?.value;
  if (sumpOnly) {
    if (!(num('sumpLength') > 0 && num('sumpWidth') > 0 && num('sumpHeight') > 0)) missing.push('Sump length / width / height');
    if (noSealant) missing.push('Sealant color');
    return missing;
  }
  if (!(num('length') > 0)) missing.push('Length');
  if (!(num('width') > 0)) missing.push('Width');
  if (calcEmbedKind !== 'stand' && !(num('height') > 0)) missing.push('Height');
  if (!doc.getElementById('unit')?.value) missing.push('Unit of measure');
  if (calcEmbedKind === 'stand') {
    if (checked('sumpHolder') && !(num('sumpWidth') > 0)) missing.push('Sump Holder width');
    if (!checked('stainless') && !doc.getElementById('paint')?.value) missing.push('Paint color');
  } else {
    if (noSealant) missing.push('Sealant color');
    if (checked('sumpEnabled') && !(num('sumpLength') > 0 && num('sumpWidth') > 0 && num('sumpHeight') > 0)) missing.push('Sump length / width / height');
    if (checked('standEnabled') && checked('standSumpHolder') && !(num('standSumpWidth') > 0)) missing.push('Stand Sump Holder width');
    if (checked('standEnabled') && !checked('standStainless') && !doc.getElementById('standPaint')?.value) missing.push('Stand paint color');
  }
  return missing;
}

function renderCalcEmbedFooter() {
  const lines = calcEmbedPendingLines;
  const key = JSON.stringify([calcEmbedProblem, lines.map((l) => [l.item_name, l.price, l.quantity])]);
  if (key === calcEmbedFooterKey) return; // polled every 600ms - don't redraw (and flicker) when nothing changed
  calcEmbedFooterKey = key;

  const linesEl = document.getElementById('calcEmbedLines');
  const totalEl = document.getElementById('calcEmbedTotal');
  const addBtn = document.getElementById('addCalcEmbedToOrderBtn');
  if (!lines.length) {
    const problem = calcEmbedProblem || 'Fill in the calculator - the lines to add will show here.';
    linesEl.innerHTML = `<div class="calc-embed-problem">&#9888; ${escapeHtml(problem)}</div>`;
    totalEl.textContent = '-';
    addBtn.disabled = true;
    addBtn.title = problem;
    return;
  }
  linesEl.innerHTML = lines.map((line) => `
    <div title="${escapeHtml(line.item_name)}"><strong>${line.quantity} &times;</strong> ${escapeHtml(line.item_name)} - ${(line.price * line.quantity).toFixed(2)}</div>
  `).join('');
  const total = lines.reduce((sum, line) => sum + line.price * line.quantity, 0);
  totalEl.textContent = `\u20B1 ${total.toFixed(2)}`;
  addBtn.disabled = false;
  addBtn.title = '';
}

function buildCalcEmbedLines() {
  return readCalcEmbedState().lines;
}

// lastDetailRows (index.html's Details summary) -> "Label: value" build-sheet lines, minus the price
// rows (makers read this note; prices are already on the line itself).
function calcDetailRowsText(rows, filter) {
  return rows
    .filter(([label]) => !/Price|^↳|^Total/.test(label) && filter(label))
    .map(([label, value]) => (/^(Hole for Aquarium|Divider)/.test(label) ? label : `${label}: ${value}`));
}

function buildAquariumDrawingUrlFrom(n, highStrip) {
  const params = new URLSearchParams({
    length: String(n.lengthInches),
    width: String(n.widthInches),
    height: String(n.heightInches),
    unit: 'Inches',
    glass: String(n.glassThickness)
  });
  if (n.temperedGlass) params.set('tempered', '1');
  if (n.rimless) params.set('rimless', '1');
  if (highStrip) params.set('highStrip', '1');
  if (n.stand) {
    params.set('standEnabled', '1');
    params.set('standLayers', String(n.stand.layers));
    params.set('standTubular', String(n.stand.tubular));
    if (n.stand.stainless) params.set('standStainless', '1');
  }
  return `https://rspetstop.com/WebAquariumCalculator/index.html?${params.toString()}`;
}

function buildAquariumCalcLines(win) {
  const r = win.lastResult;
  if (!r || !r.ok || typeof win.computeQuotedTotal !== 'function') return [];
  const n = r.normalized;
  const doc = win.document;
  const checked = (id) => Boolean(doc.getElementById(id)?.checked);
  const val = (id) => doc.getElementById(id)?.value || '';
  const q = win.computeQuotedTotal(r);
  const rows = Array.isArray(win.lastDetailRows) ? win.lastDetailRows : [];

  // "Sump only" Build type - no aquarium, so the whole quote is one CUSTOM-SUMP line.
  if (r.sumpOnly) {
    const so = n.sumpOnly || {};
    return [{
      category_code: 'CUSTOM-SUMP',
      item_code: null,
      item_name: `Custom ${so.type} Sump (${fmtIn(n.lengthInches)}x${fmtIn(n.widthInches)}x${fmtIn(n.heightInches)}in)`,
      price: Math.round(q.sumpUnitPrice * 100) / 100,
      quantity: q.sumpQty,
      note: ['CUSTOM SUMP / FILTRATION', 'Sump only - no aquarium']
        .concat(calcDetailRowsText(rows, (label) => label !== 'Build type'))
        .join('\n'),
      variation_id: null
    }];
  }

  const sumpSeparate = q.sumpEnabled && q.sumpUnitPrice > 0;
  const standSeparate = q.standEnabled && q.standUnitPrice > 0;
  const size = `${fmtIn(n.lengthInches)} x ${fmtIn(n.widthInches)} x ${fmtIn(n.heightInches)} in`;
  const isSumpRow = (label) => /^(Filtration Sump|Sump )/.test(label);
  const isStandRow = (label) => /^Stand/.test(label);

  const bits = [`${fmtIn(n.lengthInches)}x${fmtIn(n.widthInches)}x${fmtIn(n.heightInches)}in`, n.glassThickness];
  if (n.option && n.option !== 'Aquarium only') bits.unshift(n.option);
  if (n.temperedGlass) bits.push('Tempered');
  if (checked('lowIron')) bits.push('Low-Iron');
  if (n.rimless) bits.push('Rimless');
  if (checked('highStrip')) bits.push('High Strip');
  if (checked('aio')) bits.push('AIO');
  if (checked('enclosure')) bits.push('Enclosure');
  if (checked('turtleTank')) bits.push('Turtle Tank');
  if (checked('aquascape')) bits.push('Aquascape Service');
  if (Number(val('holeCount')) > 0) bits.push(`${val('holeCount')} Hole(s)`);
  if (Number(val('dividerCount')) > 0) bits.push(`${val('dividerCount')} Divider(s)`);
  if (n.sump && !sumpSeparate) bits.push(`${n.sump.type} Filtration`);

  const drawingUrl = buildAquariumDrawingUrlFrom(n, checked('highStrip'));
  const aquariumNote = ['CUSTOM AQUARIUM']
    .concat(calcDetailRowsText(rows, (label) => !isStandRow(label) && !(sumpSeparate && isSumpRow(label))))
    .concat(standSeparate ? ['Stand: Yes - see Custom Stand line'] : ['Stand: None (aquarium only)'])
    .concat(sumpSeparate ? ['Filtration: see Custom Sump line'] : [])
    .concat([`Drawing: ${drawingUrl}`]);

  const lines = [{
    category_code: 'CUSTOM-AQUARIUM',
    item_code: null,
    item_name: `Custom Aquarium (${bits.join(', ')})`,
    price: Math.round(q.perAquariumTotal * 100) / 100,
    quantity: q.aquariumQty,
    note: aquariumNote.join('\n'),
    variation_id: null
  }];

  if (standSeparate) {
    const s = n.stand;
    const standBits = [`${s.layers}-Layer ${CALC_TUBULAR_LABELS[s.tubular] || s.tubular} Tubular${s.stainless ? ' (Stainless)' : ''}`, `${fmtIn(s.heightInches)}in height`];
    // Black / White paint from the aquarium calculator's stand step (spec only) - not for stainless.
    const standPaint = s.stainless ? '' : val('standPaint');
    if (standPaint) standBits.push(`${standPaint} Paint`);
    if (s.cabinet) standBits.push('Cabinet');
    if (s.canopy) standBits.push('Canopy');
    if (s.sumpHolder) standBits.push(`Sump Holder (${fmtIn(s.sumpWidth)}in)`);
    lines.push({
      category_code: 'CUSTOM-STAND',
      item_code: null,
      item_name: `Custom Stand (${standBits.join(', ')})`,
      price: Math.round(q.standUnitPrice * 100) / 100,
      quantity: q.standQty,
      note: ['CUSTOM STAND', `For aquarium: ${size} (stand top = ${fmtIn(n.lengthInches)} x ${fmtIn(n.widthInches)} in)`]
        .concat(calcDetailRowsText(rows, isStandRow))
        .concat([`Drawing: ${drawingUrl}`])
        .join('\n'),
      variation_id: null
    });
  }

  if (sumpSeparate) {
    const sp = n.sump;
    lines.push({
      category_code: 'CUSTOM-SUMP',
      item_code: null,
      item_name: `Custom ${sp.type} Sump (${fmtIn(sp.lengthInches)}x${fmtIn(sp.widthInches)}x${fmtIn(sp.heightInches)}in)`,
      price: Math.round(q.sumpUnitPrice * 100) / 100,
      quantity: q.sumpQty,
      note: ['CUSTOM SUMP / FILTRATION', `For aquarium: ${size}`]
        .concat(calcDetailRowsText(rows, isSumpRow))
        .join('\n'),
      variation_id: null
    });
  }

  return lines;
}

function buildStandCalcLines(win) {
  const r = win.lastResult;
  if (!r || !r.ok) return [];
  const n = r.normalized;
  const doc = win.document;
  const qty = Math.max(1, Math.round(Number(doc.getElementById('qty')?.value) || 1));
  const tubular = CALC_TUBULAR_LABELS[n.tubular] || n.tubular;
  // Black / White paint from the stand calculator (spec only, no price) - not for stainless.
  const paint = n.stainless ? '' : (doc.getElementById('paint')?.value || '');

  const bits = [`${fmtIn(n.lengthInches)}x${fmtIn(n.widthInches)}x${fmtIn(n.heightInches)}in`, `${n.layers}-Layer ${tubular} Tubular${n.stainless ? ' (Stainless)' : ''}`];
  if (paint) bits.push(`${paint} Paint`);
  if (n.cabinet) bits.push('Cabinet');
  if (n.canopy) bits.push('Canopy');
  if (n.sumpHolder) bits.push(`Sump Holder (${fmtIn(n.sumpWidthInches)}in)`);

  const params = new URLSearchParams({
    length: String(n.lengthInches),
    width: String(n.widthInches),
    height: String(n.heightInches),
    unit: 'Inches',
    layers: String(n.layers),
    tubular: String(n.tubular)
  });
  if (n.stainless) params.set('stainless', '1');

  const note = [
    'CUSTOM STAND (stand only - no aquarium)',
    `Top size (L x W): ${fmtIn(n.lengthInches)} x ${fmtIn(n.widthInches)} in`
      + customEnteredSizeText(n.unit, [doc.getElementById('length')?.value, doc.getElementById('width')?.value]),
    `Frame: ${n.layers}-layer, ${tubular} in tubular, ${n.stainless ? 'Stainless steel' : `Standard steel, ${paint ? `${paint.toUpperCase()} PAINT` : 'painted'}`}`,
    `Height: ${fmtIn(n.heightInches)} in total floor-to-top${Number(n.footingInches) > 0 ? ` (includes ${fmtIn(n.footingInches)} in footing)` : ''}`,
    `Cabinet: ${n.cabinet ? `Yes - ${n.cabinetType || ''} ${n.cabinetDoors ? `${n.cabinetDoors} doors` : ''}`.trim() : 'No (open frame)'}`,
    `Canopy: ${n.canopy ? `Yes${n.canopyHeightInches ? ` - ${fmtIn(n.canopyHeightInches)} in high` : ''}` : 'No'}`,
    `Sump Holder: ${n.sumpHolder ? `Yes - ${fmtIn(n.sumpWidthInches)} in wide` : 'No'}`
  ];
  if (r.notice) note.push(`Note: ${r.notice.title} - ${r.notice.message}`);
  note.push(`Drawing: https://rspetstop.com/WebAquariumCalculator/stand.html?${params.toString()}`);

  return [{
    category_code: 'CUSTOM-STAND',
    item_code: null,
    item_name: `Custom Stand (${bits.join(', ')})`,
    price: Math.round(r.totalPrice * 100) / 100,
    quantity: qty,
    note: note.join('\n'),
    variation_id: null
  }];
}

function addCalcEmbedToOrder() {
  const lines = buildCalcEmbedLines();
  if (!lines.length) return;
  if (calcEmbedMode === 'reply') {
    insertCalcQuoteIntoReply(lines);
    return;
  }
  lines.forEach((line) => newOrderLines.push(line));
  renderNewOrderLines();
  closeCalcEmbedModal();
  calcEmbedKind = null; // next open starts a fresh build
}

// Composer quote buttons (Aquarium / Stand / Stickers / Repair) -> customer-facing text in the reply
// box: each priced line, the total, the public drawing link when there is one (pulled from the line's
// build note), then the "order this / more details?" closing. Prices/names come from the same line
// builders as Add to Order, so the chat quote always matches what the order would be. The build is
// kept (calcEmbedKind not cleared) so the matching Create Order tile reopens it as-is.
const quotePeso = (n) => `₱${n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

function insertQuoteTextIntoReply(intro, bullets, total, drawing) {
  const text = [intro]
    .concat(bullets.map((b) => `• ${b}`))
    .concat([`Total: ${quotePeso(total)}`])
    .concat(drawing ? [`Drawing: ${drawing}`] : [])
    .concat(['', 'Would you like to order this, or would you like to know more details? Don\'t hesitate to ask any questions you have in mind.'])
    .join('\n');
  const input = document.getElementById('replyInput');
  input.value = input.value.trim() ? `${input.value.trimEnd()}\n${text}` : text;
  input.dispatchEvent(new Event('input', { bubbles: true }));
  autoResizeReplyInput();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

function quoteLineBullet(line) {
  return `${line.quantity > 1 ? `${line.quantity} x ` : ''}${line.item_name} - ${quotePeso(line.price * line.quantity)}`;
}

function insertCalcQuoteIntoReply(lines) {
  const total = lines.reduce((sum, line) => sum + line.price * line.quantity, 0);
  if (calcEmbedKind === 'repair') {
    // Repair: the spec as the intro detail, then the calculator's own breakdown rows (each panel's
    // price, glass type, reseal size tier) as the bullets.
    const line = lines[0];
    const rows = (line.note || '').split('\n').filter(Boolean);
    insertQuoteTextIntoReply(`Here is the quote for your aquarium repair:\n${line.item_name}`, rows, total, null);
  } else {
    const drawing = lines.map((line) => /^Drawing: (\S+)$/m.exec(line.note || '')?.[1]).find(Boolean);
    insertQuoteTextIntoReply('Here is the quote for your custom build:', lines.map(quoteLineBullet), total, drawing);
  }
  closeCalcEmbedModal();
}

// Second "+" quote button in the Create Order tab, for the desktop POS app's other "CUSTOM
// STICKERS" action button (accessories/stickers/mats/covers with no aquarium attached) - same
// shared pricing engine (calculateStandaloneSticker) and field set as docs/WebAquariumCalculator/
// sticker.html (the reference implementation), and the same CategoryCode = 'CUSTOM-STICKER'
// convention docs/js/orderNow.js's Customize > Accessories/Stickers flow already uses
// (buildStandaloneStickerCartLine) - see supabase_diagnose_custom_sticker_item.sql for the matching
// Items catalog row this needs before it'll push to Pancake successfully.
let customStickerResult = null;
// Cached once per page load (same "load once, reuse" pattern as orderNow.js's
// ensureGlassPricingLoaded) rather than refetched on every keystroke, now that fields auto-calculate
// on change instead of waiting for a manual Calculate click.
let customStickerPricingRows = null;
let customStickerGlassPricingRows = null;
let customStickerPricingLoadPromise = null;
let customStickerCalcDebounce = null;

function ensureCustomStickerPricingLoaded() {
  if (customStickerPricingLoadPromise) return customStickerPricingLoadPromise;
  customStickerPricingLoadPromise = Promise.all([
    supabaseClient.rpc('public_get_sticker_pricing'),
    supabaseClient.rpc('public_get_glass_pricing')
  ]).then(([stickerRes, glassRes]) => {
    customStickerPricingRows = stickerRes.data || [];
    customStickerGlassPricingRows = glassRes.data || [];
  }).catch(() => {
    customStickerPricingRows = [];
    customStickerGlassPricingRows = [];
  });
  return customStickerPricingLoadPromise;
}

// 'order' = Create Order tab's Stickers tile (Add to Sale); 'reply' = composer's Stickers quote button.
let customStickerMode = 'order';

function openCustomStickerModal(mode = 'order') {
  customStickerMode = mode === 'reply' ? 'reply' : 'order';
  document.getElementById('addCustomStickerToSaleBtn').textContent = customStickerMode === 'reply' ? 'Put in reply' : 'Add to Sale';
  document.getElementById('customStickerModal').classList.remove('hidden');
  document.getElementById('customStickerError').classList.add('hidden');
  document.getElementById('customStickerResult').classList.add('hidden');
  document.getElementById('customStickerResult').innerHTML = '';
  document.getElementById('addCustomStickerToSaleBtn').classList.add('hidden');
  customStickerResult = null;
  document.getElementById('customStickerColor').value = '';
  updateCustomStickerVisibility();
  ensureCustomStickerPricingLoaded();
}

function closeCustomStickerModal() {
  document.getElementById('customStickerModal').classList.add('hidden');
}

// Rubber Matting/Glass/Marine Plywood/Laminated Plywood are thickness-priced (with Marine/Laminated
// Plywood only coming in 6/18mm, unlike the other two's 3/6/10/12mm range) - Repair only applies to
// Glass. Mirrors sticker.html's setVisibilityState/updateThicknessOptions exactly, reusing the same
// stickerTypeHasThickness/getStickerThicknessOptions helpers so this dropdown never drifts out of
// sync with what calculateStandaloneSticker actually prices.
function updateCustomStickerVisibility() {
  const type = document.getElementById('customStickerType').value;
  const showThickness = window.CustomAquariumCalculator.stickerTypeHasThickness(type);
  document.getElementById('customStickerThicknessRow').classList.toggle('hidden', !showThickness);

  const select = document.getElementById('customStickerThickness');
  const options = window.CustomAquariumCalculator.getStickerThicknessOptions(type);
  const current = select.value;
  select.innerHTML = options.map((opt) => `<option${opt === current ? ' selected' : ''}>${opt}</option>`).join('');
  if (options.indexOf(current) < 0) {
    select.value = options.indexOf('6mm') >= 0 ? '6mm' : options[0];
  }

  const showRepair = type === 'Glass';
  document.getElementById('customStickerRepairRow').classList.toggle('hidden', !showRepair);
  if (!showRepair) document.getElementById('customStickerRepair').checked = false;

  document.getElementById('customStickerColorRow').classList.toggle('hidden', !CUSTOM_STICKER_COLOR_TYPES.includes(type));
}

// Types that come in colors. Color doesn't change the price - it's just carried into the order
// line's name and note so it flows through to the order.
const CUSTOM_STICKER_COLOR_TYPES = ['Tiles Sticker', 'Plain Sticker', 'Acrylic'];

function customStickerColor(type) {
  if (!CUSTOM_STICKER_COLOR_TYPES.includes(type)) return '';
  return document.getElementById('customStickerColor').value.trim();
}

function customStickerSpecText(result) {
  const n = result.normalized;
  const hasThickness = window.CustomAquariumCalculator.stickerTypeHasThickness(n.type);
  const color = customStickerColor(n.type);
  return `${n.type}${color ? ` - ${color}` : ''}${n.isRepair ? ' REPAIR' : ''}${hasThickness ? ` (${n.thickness})` : ''} ${n.lengthInches}in x ${n.widthInches}in`;
}

async function calculateCustomSticker() {
  const errorEl = document.getElementById('customStickerError');
  const resultEl = document.getElementById('customStickerResult');
  const addBtn = document.getElementById('addCustomStickerToSaleBtn');
  errorEl.classList.add('hidden');
  resultEl.classList.add('hidden');
  addBtn.classList.add('hidden');
  customStickerResult = null;

  const length = parseFloat(document.getElementById('customStickerLength').value);
  const width = parseFloat(document.getElementById('customStickerWidth').value);
  if (!(length > 0) || !(width > 0)) {
    errorEl.textContent = 'Enter a valid length and width.';
    errorEl.classList.remove('hidden');
    return;
  }

  try {
    await ensureCustomStickerPricingLoaded();

    const result = window.CustomAquariumCalculator.calculateStandaloneSticker({
      length,
      width,
      unit: document.getElementById('customStickerUnit').value,
      type: document.getElementById('customStickerType').value,
      thickness: document.getElementById('customStickerThickness').value,
      repair: document.getElementById('customStickerRepair').checked,
      stickerPricingSetupRows: customStickerPricingRows || [],
      glassPricingSetupRows: customStickerGlassPricingRows || [],
      glassPricingUom: 'MM'
    });

    if (!result.ok) {
      errorEl.textContent = result.error || 'Could not compute a quote for those dimensions.';
      errorEl.classList.remove('hidden');
      return;
    }

    customStickerResult = result;
    renderCustomStickerResult(result);
  } catch (err) {
    errorEl.textContent = err?.message || 'Could not compute a quote right now.';
    errorEl.classList.remove('hidden');
  }
}

// Auto-validates/recalculates on every field change (per direct follow-up request) instead of
// requiring a manual Calculate click - debounced for the number inputs (length/width/qty) so rapid
// keystrokes don't each trigger their own calculation, immediate for the type/thickness/unit/repair
// controls since those only ever fire on a discrete change, not per-keystroke.
function autoCalculateCustomSticker() {
  clearTimeout(customStickerCalcDebounce);
  customStickerCalcDebounce = setTimeout(calculateCustomSticker, 300);
}

function renderCustomStickerResult(result) {
  const resultEl = document.getElementById('customStickerResult');
  const qty = Math.max(1, Math.round(Number(document.getElementById('customStickerQty').value) || 1));

  resultEl.innerHTML = `
    <div class="custom-quote-line"><span>${escapeHtml(customStickerSpecText(result))}</span><span>${result.totalPrice.toFixed(2)}</span></div>
    <div class="custom-quote-line"><span>Area</span><span>${result.normalized.areaSqFt.toFixed(2)} sq ft</span></div>
    ${qty > 1 ? `<div class="custom-quote-line"><span>Quantity</span><span>&times;${qty}</span></div>` : ''}
    <div class="custom-quote-line custom-quote-total"><span>Total</span><span>${(result.totalPrice * qty).toFixed(2)}</span></div>
  `;
  resultEl.classList.remove('hidden');
  document.getElementById('addCustomStickerToSaleBtn').classList.remove('hidden');
}

// Full build sheet for a custom sticker/accessory line's note (see customAquariumNoteText).
function customStickerNoteText(result, qty) {
  const n = result.normalized;
  const hasThickness = window.CustomAquariumCalculator.stickerTypeHasThickness(n.type);
  const lines = [
    `CUSTOM ${n.isRepair ? 'REPAIR - ' : ''}${String(n.type).toUpperCase()}`,
    `Size (L x W): ${fmtIn(n.lengthInches)} x ${fmtIn(n.widthInches)} in`
      + customEnteredSizeText(n.unit, [document.getElementById('customStickerLength').value, document.getElementById('customStickerWidth')?.value]),
    `Area: ${fmtIn(n.areaSqFt)} sq ft per piece`
  ];
  if (hasThickness) lines.push(`Thickness: ${n.thickness}${n.isTempered ? ', Tempered' : ''}`);
  const color = customStickerColor(n.type);
  if (color) lines.push(`Color: ${color}`);
  if (n.isRepair) lines.push('Job: Repair (existing glass)');
  lines.push(`Quantity: ${qty} piece(s) - ₱${Number(result.totalPrice).toFixed(2)} each`);
  return lines.join('\n');
}

function addCustomStickerToSale() {
  if (!customStickerResult) return;
  const result = customStickerResult;
  // Color is required on an order line for the colored types (a reply quote can go out without it).
  if (customStickerMode !== 'reply' && CUSTOM_STICKER_COLOR_TYPES.includes(result.normalized.type)
      && !customStickerColor(result.normalized.type)) {
    const errorEl = document.getElementById('customStickerError');
    errorEl.textContent = 'Enter the sticker color.';
    errorEl.classList.remove('hidden');
    document.getElementById('customStickerColor').focus();
    return;
  }
  const qty = Math.max(1, Math.round(Number(document.getElementById('customStickerQty').value) || 1));
  const spec = customStickerSpecText(result);
  const line = {
    category_code: 'CUSTOM-STICKER',
    item_code: null,
    item_name: `Custom Accessory/Sticker - ${spec}`,
    price: result.totalPrice,
    quantity: qty,
    note: customStickerNoteText(result, qty),
    variation_id: null
  };

  if (customStickerMode === 'reply') {
    insertQuoteTextIntoReply('Here is the quote for your custom order:', [quoteLineBullet(line)], line.price * qty, null);
    closeCustomStickerModal();
    return;
  }

  newOrderLines.push(line);
  renderNewOrderLines();
  closeCustomStickerModal();
}

async function submitNewOrder() {
  const errorEl = document.getElementById('newOrderError');
  errorEl.classList.add('hidden');

  const fulfillment = document.getElementById('newOrderFulfillment').value;
  const submitBtn = document.getElementById('newOrderSubmitBtn');

  // Same rule as the bot (and admin_set_automated_order_wholesale): no wholesale below the minimum.
  if (newOrderWholesale) {
    const short = WHOLESALE_MIN_TOTAL - newOrderWholesaleTotal();
    if (short > 0) {
      errorEl.textContent = `Wholesale needs at least PHP ${WHOLESALE_MIN_TOTAL.toLocaleString()} of wholesale-priced items - short by PHP ${short.toFixed(2)}. Add items, or turn off Wholesale pricing for retail.`;
      errorEl.classList.remove('hidden');
      return;
    }
  }

  submitBtn.disabled = true;

  const commonFields = {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_customer_name: document.getElementById('newOrderCustomerName').value.trim(),
    p_customer_phone: document.getElementById('newOrderCustomerPhone').value.trim(),
    p_customer_email: document.getElementById('newOrderCustomerEmail').value.trim() || null,
    p_fulfillment_type: fulfillment,
    p_delivery_address: fulfillment === 'Delivery' ? document.getElementById('newOrderDeliveryAddress').value.trim() : null,
    p_notes: document.getElementById('newOrderNotes').value.trim() || null,
    p_location: document.getElementById('newOrderLocation').value,
    p_lines: newOrderLines.map(({ retail_price, wholesale_applied, ...line }) => line),
    p_delivery_fee: newOrderDeliveryFee()
  };

  // admin_update_automated_order (edit) and admin_create_gma_conversation_order (new) return
  // different column sets (estimated_total vs pancake_order_id) - order_no/pancake_sync_status/
  // pancake_sync_error are the only ones both share, which is all the post-save handling below
  // actually needs.
  const { data, error } = editingOrder
    ? await supabaseClient.rpc('admin_update_automated_order', { ...commonFields, p_order_no: editingOrder.order_no })
    : await supabaseClient.rpc('admin_create_gma_conversation_order', { ...commonFields, p_psid: newOrderConv.psid, p_page_id: newOrderConv.page_id });

  submitBtn.disabled = false;

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  const result = (data || [])[0];

  // Pricing flag - only sent when it's wholesale or changed, so a plain retail order never needs it.
  const wholesaleChanged = editingOrder ? newOrderWholesale !== editingOrderWasWholesale : newOrderWholesale;
  if (result && wholesaleChanged) {
    const { data: flagData, error: flagError } = await supabaseClient.rpc('admin_set_automated_order_wholesale', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_no: result.order_no,
      p_is_wholesale: newOrderWholesale
    });
    const flag = (flagData || [])[0];
    if (flagError || !flag?.success) {
      alert(`Order ${result.order_no} was saved with these prices, but its wholesale flag could not be set: ${flagError?.message || flag?.message || 'unknown error'}.`);
    }
  }
  newOrderWholesale = false;
  editingOrderWasWholesale = false;

  const payAmount = parseFloat(document.getElementById('newOrderPayAmount').value);
  if (result && payAmount > 0) {
    const { data: payData, error: payError } = await supabaseClient.rpc('admin_add_automated_order_payment', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_no: result.order_no,
      p_amount: payAmount,
      p_method: document.getElementById('newOrderPayMethod').value,
      p_reference: document.getElementById('newOrderPayReference').value.trim() || null
    });
    if (payError) {
      alert(`Order ${result.order_no} was saved, but the payment could not be recorded: ${payError.message}. Add it manually from the order's Add Payment form.`);
    } else {
      const pancakeSyncError = (payData || [])[0]?.pancake_sync_error;
      if (pancakeSyncError) {
        alert(`Order ${result.order_no} and its payment were recorded, but the payment could not flow to Pancake: ${pancakeSyncError}. It can be added on the Pancake order manually.`);
      }
    }
  }

  const wasEditing = Boolean(editingOrder);
  newOrderLines = [];
  editingOrder = null;
  activeCustomerTab = 'info';

  if (wasEditing) {
    // Local cache would otherwise still show the pre-edit lines/totals until the card is
    // collapsed and re-expanded - drop it so re-expanding (forced right below, via
    // renderCustomerPanel -> renderInformationTab -> loadConversationOrders) fetches fresh.
    orderLinesCache.delete(result.order_no);
    expandedOrderNos.add(result.order_no);
    renderCustomerPanel(conversationOrdersConv);
    if (result.pancake_sync_status === 'Stale') {
      alert(`Order ${result.order_no} was updated, but it had already synced to Pancake - the live Pancake order was NOT changed automatically. ${result.pancake_sync_error || ''}`);
    }
  } else {
    renderCustomerPanel(newOrderConv);
    if (result && result.pancake_sync_status === 'Failed') {
      alert(`Order ${result.order_no} was created, but the Pancake push failed: ${result.pancake_sync_error || '(no error detail)'}. Ask a super user to check it.`);
    }
  }
}

// Super User / Sales User only: sends whatever is typed in the reply box (or "Human Agent test" if it's empty) to
// the open conversation with the HUMAN_AGENT tag forced (chatbot-staff-reply's force_human_agent) -
// the App Dashboard's Human Agent test call, without waiting for a customer to fall outside the 24h
// window. Shows Facebook's exact result in the reply error line. Before Meta approves the feature it
// only succeeds to app admins/testers.
async function testHumanAgent() {
  const psid = selectedPsid;
  if (!psid || !(currentSession?.isSuperUser || currentSession?.isSalesUser)) return;
  const btn = document.getElementById('testHumanAgentBtn');
  const statusEl = document.getElementById('replyErrorEl');
  const input = document.getElementById('replyInput');
  const message = input.value.trim() || 'Human Agent test';
  if (!confirm(`Send this message using the HUMAN_AGENT tag?\n\n"${message}"\n\nUse your own conversation (app admin/tester) - it fails for customers until Meta approves Human Agent.`)) return;

  btn.disabled = true;
  statusEl.classList.remove('hidden');
  statusEl.textContent = 'Sending Human Agent test...';
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
        psid,
        message,
        images: [],
        force_human_agent: true
      })
    });
    const result = await response.json().catch(() => ({}));
    statusEl.textContent = response.ok
      ? 'Human Agent test sent. The App Dashboard counter can take up to 24h to update.'
      : `Human Agent test failed: ${result.error || response.status}`;
    if (response.ok && input.value.trim() === message) {
      input.value = '';
      autoResizeReplyInput();
    }
    if (selectedPsid === psid) await loadMessages(psid);
  } catch (err) {
    statusEl.textContent = `Human Agent test failed: ${err instanceof Error ? err.message : 'network error'}`;
  } finally {
    btn.disabled = false;
  }
}

// "Advise reply": asks AI (supabase/functions/chatbot-suggest-reply) for the best next reply based
// on the conversation and puts it in the reply box - nothing is sent until staff press Enter.
// Whatever staff already typed is sent along as guidance ("decline the discount politely") and is
// replaced by the draft. Ignores the result if staff switched conversations while waiting.
async function adviseReply() {
  const psid = selectedPsid;
  if (!psid || !currentSession?.isSuperUser) return; // Super User only while under maintenance
  const btn = document.getElementById('adviseReplyBtn');
  const label = document.getElementById('adviseReplyLabel');
  const input = document.getElementById('replyInput');
  const errorEl = document.getElementById('replyErrorEl');
  errorEl.classList.add('hidden');

  btn.disabled = true;
  label.textContent = 'Thinking...';
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-suggest-reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password,
        psid,
        instruction: input.value.trim()
      })
    });
    const result = await response.json().catch(() => ({}));
    if (psid !== selectedPsid) return;
    if (!response.ok || !result.suggestion) {
      errorEl.textContent = result.error || 'Could not get a suggestion right now - try again.';
      errorEl.classList.remove('hidden');
      return;
    }
    input.value = result.suggestion;
    autoResizeReplyInput();
    input.focus();
  } catch (err) {
    errorEl.textContent = err instanceof Error ? err.message : 'Could not reach the AI.';
    errorEl.classList.remove('hidden');
  } finally {
    btn.disabled = false;
    label.textContent = 'Advise reply';
  }
}

// Core send path shared by Enter-to-send in the textarea, a quick-reply/product-list pick, an
// ad-hoc attachment, and the Like button below - all are "staff sends this to the customer right
// now", just with a different source/payload. `images` accepts plain URL strings (Quick Reply/
// Product List - no Storage object we own to clean up later) or {url, path} objects (an ad-hoc
// attachment - path lets the server record AttachmentPath so the existing 60-day cleanup cron can
// delete it). `like` sends Messenger's own native thumbs-up sticker instead of text/images - see
// chatbot-staff-reply's LIKE_STICKER_ID.
//
// Messenger-style optimistic send: the message shows up in the thread immediately as a "Sending..."
// bubble and the composer is free again right away; the actual Facebook delivery runs in the
// background through sendQueue (one send at a time, so rapid-fire messages arrive in the order they
// were typed). If it can't be delivered the bubble turns into "Not sent - Retry". Resolves to true
// once delivered (callers that care, like Product List, can still await it).
let sendQueue = Promise.resolve();
let sendBatchSeq = 0;
const sendRequests = new Map(); // send_id -> { psid, message, images, like, replyTo } (for Retry)

// replyTo - a replyingTo snapshot (startReplyTo): the first item goes out as a quoted reply to it.
function sendMessageToCustomer(message, images, like, replyTo = null) {
  const errorEl = document.getElementById('replyErrorEl');
  errorEl.classList.add('hidden');
  const normalized = normalizePendingImages(images);
  const psid = selectedPsid;
  if (!psid || (!message && normalized.length === 0 && !like)) return Promise.resolve(false);

  const sendId = `send-${++sendBatchSeq}`;
  const base = {
    psid,
    send_id: sendId,
    role: 'staff',
    sent_by_username: currentSession.username,
    created_at_utc: new Date().toISOString(),
    pending: 'sending'
  };
  // Same split chatbot-staff-reply does server-side: one bubble per photo/video, then the text.
  const items = like
    ? [{ ...base, temp_id: `${sendId}-like`, content: '👍' }]
    : [
        ...normalized.map((img, i) => ({ ...base, temp_id: `${sendId}-${i}`, content: '', attachment_type: img.type, attachment_url: img.url })),
        ...(message ? [{ ...base, temp_id: `${sendId}-text`, content: message }] : [])
      ];
  const quote = like ? null : replyTo;
  if (quote && items.length) {
    Object.assign(items[0], {
      reply_to_mid: 'pending',
      reply_to_message_id: quote.messageId,
      reply_to_role: quote.role,
      reply_to_content: quote.content,
      reply_to_attachment_type: quote.attachmentType
    });
  }
  pendingOutgoing.push(...items);
  sendRequests.set(sendId, { psid, message, images: normalized, like: !!like, replyTo: quote });
  if (psid === selectedPsid) renderThread({ forceBottom: true });

  const run = sendQueue.then(() => deliverPendingSend(sendId));
  sendQueue = run.catch(() => {});
  return run;
}

async function deliverPendingSend(sendId) {
  const req = sendRequests.get(sendId);
  if (!req) return false;
  const errorEl = document.getElementById('replyErrorEl');

  let response;
  let result = {};
  try {
    response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-staff-reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password,
        psid: req.psid,
        message: req.message,
        images: req.images,
        like: req.like,
        reply_to_message_id: req.replyTo?.messageId ?? null
      })
    });
    result = await response.json().catch(() => ({}));
  } catch (err) {
    markPendingSendFailed(sendId, err instanceof Error ? err.message : 'Could not reach the send function.');
    return false;
  }

  // Not recorded at all server-side (bad session, etc.) - keep the bubble so staff can Retry.
  if (!response.ok && !result.loggedOnly) {
    markPendingSendFailed(sendId, result.error || `Send failed (${response.status}).`);
    return false;
  }

  // Recorded server-side - either delivered, or (loggedOnly) logged with DeliveryStatus 'Failed'
  // and the conversation auto-paused. Either way the real rows replace the placeholders now.
  if (!response.ok && req.psid === selectedPsid) {
    errorEl.textContent = result.error || `Send failed (${response.status}).`;
    errorEl.classList.remove('hidden');
  } else if (result.replyNotQuoted && req.psid === selectedPsid) {
    errorEl.textContent = "Sent, but Facebook didn't accept it as a reply to that message - it went out as a normal message.";
    errorEl.classList.remove('hidden');
  }
  sendRequests.delete(sendId);
  await Promise.all([
    loadConversations().then(() => {
      const conv = conversations.find((c) => c.psid === selectedPsid);
      if (conv && req.psid === selectedPsid) renderThreadHeader(conv);
    }),
    loadMessages(req.psid, {
      forceBottom: req.psid === selectedPsid && threadStickToBottom,
      beforeApply: () => { pendingOutgoing = pendingOutgoing.filter((p) => p.send_id !== sendId); }
    })
  ]);
  return response.ok;
}

function markPendingSendFailed(sendId, message) {
  const req = sendRequests.get(sendId);
  pendingOutgoing.forEach((p) => {
    if (p.send_id === sendId) p.pending = 'failed';
  });
  if (req && req.psid === selectedPsid) {
    const errorEl = document.getElementById('replyErrorEl');
    errorEl.textContent = message;
    errorEl.classList.remove('hidden');
    renderThread();
  }
}

function retryPendingSend(sendId) {
  const req = sendRequests.get(sendId);
  if (!req) return;
  pendingOutgoing = pendingOutgoing.filter((p) => p.send_id !== sendId);
  sendRequests.delete(sendId);
  sendMessageToCustomer(req.message, req.images, req.like, req.replyTo);
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
  // First - folding the phone tool icons away changes the box's width, which changes its height.
  updateComposerState();
  const maxHeight = isMobileInbox() ? 140 : REPLY_INPUT_MAX_HEIGHT; // phone: keep the thread visible
  input.style.height = 'auto';
  const newHeight = Math.min(input.scrollHeight, maxHeight);
  input.style.height = newHeight + 'px';
  input.style.overflowY = input.scrollHeight > maxHeight ? 'auto' : 'hidden';
}

// Messenger composer behaviour: the like button turns into a Send arrow as soon as there's
// something to send. On the phone layout the tool icons stay folded behind a single ">" (per "in
// the phone can you make all the buttons collapsible?") - tap it to open/close them. They fold
// back up when the box empties (message sent / chat switched). Desktop CSS ignores tools-collapsed.
let composerToolsExpanded = false;
let composerHadText = false;

function updateComposerState() {
  const row = document.getElementById('replyRowEl');
  if (!row) return;
  const hasText = document.getElementById('replyInput').value.trim().length > 0;
  const hasContent = hasText || pendingReplyImageUrls.length > 0;
  if (composerHadText && !hasText) composerToolsExpanded = false;
  composerHadText = hasText;
  row.classList.toggle('has-content', hasContent);
  row.classList.toggle('tools-collapsed', !composerToolsExpanded);
  const expandBtn = document.getElementById('composerExpandBtn');
  expandBtn.classList.toggle('is-open', composerToolsExpanded);
  expandBtn.setAttribute('aria-label', composerToolsExpanded ? 'Hide tools' : 'Show tools');
  expandBtn.setAttribute('aria-expanded', String(composerToolsExpanded));
}

// Phones: Enter adds a new line (tap the Send arrow instead), like the Messenger app. A keyboard on
// desktop keeps Enter = send.
function enterKeySends() {
  return !window.matchMedia('(pointer: coarse)').matches;
}

function setPendingReplyImages(images) {
  pendingReplyImageUrls = normalizePendingImages(images);
  const wrap = document.getElementById('pendingAttachmentEl');
  const listEl = document.getElementById('pendingAttachmentList');
  const labelEl = document.getElementById('pendingAttachmentLabel');

  if (labelEl) {
    labelEl.textContent = attachmentUploadsInFlight > 0
      ? `Uploading ${attachmentUploadsInFlight} file${attachmentUploadsInFlight === 1 ? '' : 's'}...`
      : 'Attached - will send with this reply';
  }

  updateComposerState();
  if (pendingReplyImageUrls.length === 0) {
    wrap.classList.toggle('hidden', attachmentUploadsInFlight === 0);
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
// keydown listener in init()) is the only way to send it now, same as most chat apps. The box clears
// instantly (optimistic send), so staff can keep typing the next message while this one goes out.
async function sendReply() {
  const input = document.getElementById('replyInput');
  // Enter pressed while a photo is still uploading - wait for it so it goes out with this message.
  if (attachmentUploadPromise) await attachmentUploadPromise;

  const message = input.value.trim();
  const images = pendingReplyImageUrls;
  if (!message && images.length === 0) return;

  const replyTo = replyingTo && replyingTo.psid === selectedPsid ? replyingTo : null;
  input.value = '';
  autoResizeReplyInput();
  setPendingReplyImages([]);
  clearReplyTo();
  // Keep the phone keyboard up only if it already was (tapping Send keeps focus anyway).
  if (!isMobileInbox() || document.activeElement === input) input.focus();
  sendMessageToCustomer(message, images, false, replyTo);
}

// The button that replaced Send in the toolbar - per direct request, matches Messenger's own
// composer: a filled thumbs-up that sends Facebook's native "like" sticker on its own, independent
// of whatever text/photos might currently be sitting in the box (those still only go out via Enter).
function sendLike() {
  sendMessageToCustomer('', [], true);
}

// Ad-hoc attachment - per direct request, a generic "attach a photo (or, per direct follow-up,
// video) from my device" feature alongside Quick Reply/Product list, for a one-off file that isn't a
// reusable template or catalog item. Reuses the same pendingReplyImageUrls staging area/UI as those
// two - once uploaded, an attachment behaves identically to one picked from a Quick Reply (shown in
// the same removable-thumbnail strip, sent alongside whatever text is typed). Files can also be
// pasted (Ctrl+V a screenshot) or dragged onto the conversation, like Messenger, and several upload
// in parallel.
//
// 25MB matches the chatbot-attachments bucket's own limit (supabase_chatbot_attachment_video_
// support.sql) - Facebook's own documented cap for a Send API attachment delivered by URL.
const ATTACHMENT_MAX_BYTES = 25 * 1024 * 1024;
let attachmentUploadsInFlight = 0;
let attachmentUploadPromise = null;

function onAttachmentFileChange() {
  const input = document.getElementById('attachmentFileInput');
  const files = Array.from(input.files || []);
  input.value = '';
  uploadAttachmentFiles(files);
}

async function uploadOneAttachment(file) {
  const type = file.type.startsWith('video/') ? 'video' : 'image';

  const { data: uploadRows, error: signError } = await supabaseClient.rpc('admin_create_chatbot_attachment_upload', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_file_name: file.name || `pasted-${Date.now()}.${(file.type.split('/')[1] || 'png')}`
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
  return { url: signedUrl, path: uploadInfo.storage_path, type };
}

async function uploadAttachmentFiles(rawFiles) {
  const errorEl = document.getElementById('replyErrorEl');
  const files = (rawFiles || []).filter((f) => f.type.startsWith('image/') || f.type.startsWith('video/'));
  if (files.length === 0 || !selectedPsid) return;

  errorEl.classList.add('hidden');
  const oversized = files.find((f) => f.size > ATTACHMENT_MAX_BYTES);
  if (oversized) {
    errorEl.textContent = `"${oversized.name || 'Pasted file'}" is too large - max 25 MB per file.`;
    errorEl.classList.remove('hidden');
    return;
  }

  attachmentUploadsInFlight += files.length;
  setPendingReplyImages(pendingReplyImageUrls);

  const work = Promise.allSettled(files.map(uploadOneAttachment));
  const tracked = attachmentUploadPromise ? Promise.all([attachmentUploadPromise, work]) : work;
  attachmentUploadPromise = tracked;
  const results = await work;
  if (attachmentUploadPromise === tracked) attachmentUploadPromise = null;
  attachmentUploadsInFlight -= files.length;

  const failed = results.find((r) => r.status === 'rejected');
  if (failed) {
    errorEl.textContent = failed.reason?.message || 'Could not attach file.';
    errorEl.classList.remove('hidden');
  }
  const uploaded = results.filter((r) => r.status === 'fulfilled').map((r) => r.value);
  setPendingReplyImages([...pendingReplyImageUrls, ...uploaded]);
}

// Media Library - per direct request ("a compilation of images and videos saved so they can resend
// it to the customer when needed"), mirroring the "Media" icon in Facebook's own Page inbox toolbar.
// A plain, growing library of reusable photos/videos (no label/text attached, unlike a Quick Reply) -
// staff pick one or several, which load into the reply box for review (same pendingReplyImageUrls
// staging area as everything else), never sent instantly. Library items live in the permanent public
// chatbot-media-library bucket (supabase_chatbot_media_library.sql), so - same as a Quick Reply/
// Product List image - they're staged with path: null, keeping them out of the 60-day ad-hoc-
// attachment cleanup cron, which only ever touches chatbot-attachments.
//
// Folders (supabase_chatbot_media_library_folders.sql): each item has an optional Folder name, shown
// as chips across the top. "+ Add" uploads single photos/videos into the open folder, or a whole
// folder from the computer into a library folder of the same name; files/folders can also be dragged
// onto the panel. Picked items get numbered badges (the order they go into the reply) and can be
// moved or deleted together. A folder exists while it has items - "New folder" keeps an empty one
// locally until something is added to it.
const MEDIA_LIBRARY_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'video/mp4', 'video/quicktime'];
const MEDIA_LIBRARY_FOLDER_KEY = 'gmaMediaLibraryFolder';
const MEDIA_LIBRARY_UPLOAD_CONCURRENCY = 3;
let mediaLibraryItems = [];
let mediaLibrarySelected = []; // ids, in the order picked
let mediaLibraryView = 'all'; // 'all' | 'unsorted' | 'f:<folder name>'
let mediaLibraryEmptyFolders = new Set();
let mediaLibraryUploading = false;
let mediaLibrarySearch = ''; // "Search media by name" box
let mediaLibraryFolderSearch = ''; // sidebar "Search folder" box

function toggleMediaLibraryPanel(show) {
  const panel = document.getElementById('mediaLibraryPanel');
  const btn = document.getElementById('toggleMediaLibraryBtn');
  const willShow = show === undefined ? panel.classList.contains('hidden') : show;

  panel.classList.toggle('hidden', !willShow);
  btn.classList.toggle('active', willShow);
  toggleMediaLibraryAddMenu(false);
  if (willShow) {
    toggleQuickRepliesPanel(false);
    toggleProductLookupPanel(false);
    mediaLibrarySearch = '';
    mediaLibraryFolderSearch = '';
    document.getElementById('mediaLibrarySearchInput').value = '';
    document.getElementById('mediaLibraryFolderSearchInput').value = '';
    try {
      mediaLibraryView = localStorage.getItem(MEDIA_LIBRARY_FOLDER_KEY) || 'all';
    } catch {
      mediaLibraryView = 'all';
    }
    loadMediaLibrary();
  } else {
    mediaLibrarySelected = [];
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
  const ids = new Set(mediaLibraryItems.map((item) => item.id));
  mediaLibrarySelected = mediaLibrarySelected.filter((id) => ids.has(id));
  mediaLibraryItems.forEach((item) => { if (item.folder) mediaLibraryEmptyFolders.delete(item.folder); });
  if (mediaLibraryView.startsWith('f:') && !mediaLibraryFolderNames().includes(mediaLibraryView.slice(2))) {
    setMediaLibraryView('all');
  }
  renderMediaLibrary();
}

function mediaLibraryFolderNames() {
  const names = new Set(mediaLibraryEmptyFolders);
  mediaLibraryItems.forEach((item) => { if (item.folder) names.add(item.folder); });
  return Array.from(names).sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base', numeric: true }));
}

// Folder the open view uploads into - null for All / Unsorted.
function mediaLibraryCurrentFolder() {
  return mediaLibraryView.startsWith('f:') ? mediaLibraryView.slice(2) : null;
}

function mediaLibraryItemName(item) {
  return item.file_name || (item.media_type === 'video' ? 'Video' : 'Photo');
}

// Items in the open folder, narrowed by the "Search media by name" box.
function mediaLibraryItemsInView() {
  const folder = mediaLibraryCurrentFolder();
  const query = mediaLibrarySearch.trim().toLowerCase();
  return mediaLibraryItems.filter((item) => {
    if (mediaLibraryView === 'unsorted' && item.folder) return false;
    if (folder && item.folder !== folder) return false;
    return !query || mediaLibraryItemName(item).toLowerCase().includes(query);
  });
}

function setMediaLibraryView(view) {
  mediaLibraryView = view;
  try {
    localStorage.setItem(MEDIA_LIBRARY_FOLDER_KEY, view);
  } catch {
    // per-viewer convenience only
  }
}

function renderMediaLibrary() {
  renderMediaLibraryFolders();
  renderMediaLibraryFolderBar();
  renderMediaLibraryGrid();
  renderMediaLibraryFooter();
}

function renderMediaLibraryFolders() {
  const el = document.getElementById('mediaLibraryFolders');
  const folderQuery = mediaLibraryFolderSearch.trim().toLowerCase();
  const allFolders = mediaLibraryFolderNames();
  const folders = allFolders.filter((name) => !folderQuery || name.toLowerCase().includes(folderQuery));
  const unsortedCount = mediaLibraryItems.filter((item) => !item.folder).length;
  const folderIcon = '<svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M2.5 5.5A1.5 1.5 0 0 1 4 4h3.6l1.6 1.8H16a1.5 1.5 0 0 1 1.5 1.5v7.2A1.5 1.5 0 0 1 16 16H4a1.5 1.5 0 0 1-1.5-1.5v-9Z" stroke-linejoin="round"/></svg>';
  const allIcon = '<svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><rect x="2.5" y="3.5" width="15" height="13" rx="2" stroke-linejoin="round"/><circle cx="7" cy="8" r="1.4"/><path d="M3 14.5 7.5 10l3 3 2.5-2.5 4 4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const unsortedIcon = '<svg viewBox="0 0 20 20" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M3 11.5h4l1 2h4l1-2h4M3 11.5 5 5h10l2 6.5v3.5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1Z" stroke-linejoin="round"/></svg>';
  const chip = (view, label, count, icon = '') => `
    <button type="button" class="mlib-chip${mediaLibraryView === view ? ' active' : ''}" data-view="${escapeHtml(view)}">
      ${icon}<span class="mlib-chip-label">${escapeHtml(label)}</span><span class="mlib-chip-count">${count}</span>
    </button>`;

  el.innerHTML = [
    folderQuery ? '' : chip('all', 'All media', mediaLibraryItems.length, allIcon),
    ...folders.map((name) => chip(`f:${name}`, name, mediaLibraryItems.filter((item) => item.folder === name).length, folderIcon)),
    !folderQuery && allFolders.length > 0 && unsortedCount > 0 ? chip('unsorted', 'Unsorted', unsortedCount, unsortedIcon) : '',
    folderQuery && folders.length === 0 ? '<div class="mlib-folders-empty">No folder matches.</div>' : ''
  ].join('');

  el.querySelectorAll('.mlib-chip[data-view]').forEach((btn) => {
    btn.addEventListener('click', () => {
      setMediaLibraryView(btn.dataset.view);
      renderMediaLibrary();
    });
  });
  el.querySelector('.mlib-chip.active')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}

function renderMediaLibraryFolderBar() {
  const el = document.getElementById('mediaLibraryFolderBar');
  const inView = mediaLibraryItemsInView();
  const folder = mediaLibraryCurrentFolder();
  const title = folder || (mediaLibraryView === 'unsorted' ? 'Unsorted' : 'All media');
  const allPicked = inView.length > 0 && inView.every((item) => mediaLibrarySelected.includes(item.id));

  el.innerHTML = `
    <span class="mlib-folder-title">${escapeHtml(title)}</span>
    <span class="muted">${inView.length} item${inView.length === 1 ? '' : 's'}</span>
    <span class="mlib-folder-actions">
      ${inView.length > 0 ? `<button type="button" class="mlib-link-btn" id="mediaLibrarySelectAllBtn">${allPicked ? 'Unselect all' : 'Select all'}</button>` : ''}
      ${folder ? `
        <button type="button" class="mlib-link-btn" id="mediaLibraryRenameFolderBtn">Rename</button>
        <button type="button" class="mlib-link-btn mlib-danger" id="mediaLibraryDeleteFolderBtn">Delete folder</button>` : ''}
    </span>`;

  document.getElementById('mediaLibrarySelectAllBtn')?.addEventListener('click', () => {
    const viewIds = inView.map((item) => item.id);
    mediaLibrarySelected = allPicked
      ? mediaLibrarySelected.filter((id) => !viewIds.includes(id))
      : [...mediaLibrarySelected, ...viewIds.filter((id) => !mediaLibrarySelected.includes(id))];
    renderMediaLibrary();
  });
  document.getElementById('mediaLibraryRenameFolderBtn')?.addEventListener('click', renameMediaLibraryFolder);
  document.getElementById('mediaLibraryDeleteFolderBtn')?.addEventListener('click', deleteMediaLibraryFolder);
}

function renderMediaLibraryGrid() {
  const gridEl = document.getElementById('mediaLibraryGrid');
  const inView = mediaLibraryItemsInView();

  if (inView.length === 0) {
    gridEl.innerHTML = `
      <div class="mlib-empty">
        <div class="mlib-empty-icon">&#128444;&#65039;</div>
        <div>${mediaLibraryItems.length === 0 ? 'Your media library is empty.' : mediaLibrarySearch.trim() ? 'No media matches that name.' : 'Nothing in this folder yet.'}</div>
        ${mediaLibrarySearch.trim() ? '' : '<div class="muted">Use <strong>Upload</strong> for photos or videos (<strong>&#8943;</strong> for a whole folder) - or drag them here.</div>'}
      </div>`;
    return;
  }

  gridEl.innerHTML = inView.map((item) => {
    const order = mediaLibrarySelected.indexOf(item.id) + 1;
    const name = mediaLibraryItemName(item);
    return `
      <div class="mlib-item${order ? ' selected' : ''}" data-id="${item.id}" title="${escapeHtml(name)}${item.folder && mediaLibraryView === 'all' ? ` (${escapeHtml(item.folder)})` : ''}">
        <div class="mlib-thumb">
          ${item.media_type === 'video'
            ? `<video src="${escapeHtml(item.media_url)}#t=0.1" muted playsinline preload="metadata"></video><span class="mlib-play">&#9654;</span>`
            : `<img src="${escapeHtml(item.media_url)}" alt="" loading="lazy" />`}
          <span class="mlib-check">${order || ''}</span>
          <a class="mlib-view" href="${escapeHtml(item.media_url)}" target="_blank" rel="noopener" title="Open full size">&#10530;</a>
        </div>
        <div class="mlib-name">${escapeHtml(name)}</div>
      </div>`;
  }).join('');

  gridEl.querySelectorAll('.mlib-item').forEach((el) => {
    el.addEventListener('click', () => toggleMediaLibraryItemSelected(Number(el.dataset.id)));
  });
  gridEl.querySelectorAll('.mlib-view').forEach((a) => a.addEventListener('click', (e) => e.stopPropagation()));
}

function renderMediaLibraryFooter() {
  const count = mediaLibrarySelected.length;
  document.getElementById('mediaLibrarySelectedCount').textContent = count
    ? `${count} selected`
    : 'Click photos to pick them';
  document.getElementById('mediaLibrarySelectionActions').classList.toggle('hidden', count === 0);

  const moveSelect = document.getElementById('mediaLibraryMoveSelect');
  moveSelect.innerHTML = [
    '<option value="">Move to...</option>',
    '<option value="unsorted">Unsorted (no folder)</option>',
    ...mediaLibraryFolderNames().map((name) => `<option value="f:${escapeHtml(name)}">${escapeHtml(name)}</option>`),
    '<option value="new">+ New folder...</option>'
  ].join('');

  const useBtn = document.getElementById('useMediaLibrarySelectionBtn');
  useBtn.disabled = count === 0;
  useBtn.textContent = count ? `Add ${count} to reply` : 'Add to reply';
}

function toggleMediaLibraryItemSelected(id) {
  const index = mediaLibrarySelected.indexOf(id);
  if (index >= 0) {
    mediaLibrarySelected.splice(index, 1);
  } else {
    mediaLibrarySelected.push(id);
  }
  renderMediaLibrary();
}

function promptMediaLibraryFolderName(message, current = '') {
  const name = (prompt(message, current) || '').trim().slice(0, 100);
  return name || null;
}

function createMediaLibraryFolder() {
  const name = promptMediaLibraryFolderName('New folder name (e.g. "Shrimps", "Tank setups"):');
  if (!name) return;
  if (!mediaLibraryFolderNames().includes(name)) mediaLibraryEmptyFolders.add(name);
  setMediaLibraryView(`f:${name}`);
  renderMediaLibrary();
}

async function renameMediaLibraryFolder() {
  const oldName = mediaLibraryCurrentFolder();
  if (!oldName) return;
  const newName = promptMediaLibraryFolderName('Rename folder to:', oldName);
  if (!newName || newName === oldName) return;

  if (mediaLibraryEmptyFolders.has(oldName)) {
    mediaLibraryEmptyFolders.delete(oldName);
    mediaLibraryEmptyFolders.add(newName);
  } else {
    const { error } = await supabaseClient.rpc('admin_rename_chatbot_media_folder', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_old_folder: oldName,
      p_new_folder: newName
    });
    if (error) {
      alert(`Could not rename: ${error.message}`);
      return;
    }
  }
  setMediaLibraryView(`f:${newName}`);
  await loadMediaLibrary();
}

// Deleting a folder never deletes its photos - they just go back to Unsorted.
async function deleteMediaLibraryFolder() {
  const name = mediaLibraryCurrentFolder();
  if (!name) return;
  const count = mediaLibraryItems.filter((item) => item.folder === name).length;
  if (count > 0 && !confirm(`Delete the folder "${name}"?\n\nIts ${count} item${count === 1 ? '' : 's'} stay in the library under Unsorted.`)) return;

  if (count > 0) {
    const { error } = await supabaseClient.rpc('admin_rename_chatbot_media_folder', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_old_folder: name,
      p_new_folder: null
    });
    if (error) {
      alert(`Could not delete folder: ${error.message}`);
      return;
    }
  }
  mediaLibraryEmptyFolders.delete(name);
  setMediaLibraryView(count > 0 ? 'unsorted' : 'all');
  await loadMediaLibrary();
}

async function onMediaLibraryMoveSelectChange() {
  const select = document.getElementById('mediaLibraryMoveSelect');
  const value = select.value;
  select.value = '';
  if (!value || mediaLibrarySelected.length === 0) return;

  let folder = null;
  if (value === 'new') {
    folder = promptMediaLibraryFolderName('Move to a new folder named:');
    if (!folder) return;
  } else if (value.startsWith('f:')) {
    folder = value.slice(2);
  }

  const { error } = await supabaseClient.rpc('admin_move_chatbot_media_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_media_ids: mediaLibrarySelected,
    p_folder: folder
  });
  if (error) {
    alert(`Could not move: ${error.message}`);
    return;
  }
  mediaLibrarySelected = [];
  setMediaLibraryView(folder ? `f:${folder}` : 'unsorted');
  await loadMediaLibrary();
}

async function deleteSelectedMediaLibraryItems() {
  const count = mediaLibrarySelected.length;
  if (count === 0) return;
  if (!confirm(`Remove ${count} item${count === 1 ? '' : 's'} from the media library?`)) return;

  const { error } = await supabaseClient.rpc('admin_delete_chatbot_media_items', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_media_ids: mediaLibrarySelected
  });
  if (error) {
    alert(`Could not remove: ${error.message}`);
    return;
  }
  mediaLibrarySelected = [];
  await loadMediaLibrary();
}

function toggleMediaLibraryAddMenu(show) {
  const menu = document.getElementById('mediaLibraryAddMenu');
  const willShow = show === undefined ? menu.classList.contains('hidden') : show;
  menu.classList.toggle('hidden', !willShow);
}

// "+ Add > Photos or videos" - goes into the open folder (Unsorted from All).
function onMediaLibraryFileChange() {
  const input = document.getElementById('mediaLibraryFileInput');
  const files = Array.from(input.files || []);
  input.value = '';
  uploadMediaLibraryFiles(files.map((file) => ({ file, folder: null })));
}

// "+ Add > A whole folder" - every photo/video in it (subfolders included) goes into a library
// folder named after the chosen folder.
function onMediaLibraryFolderInputChange() {
  const input = document.getElementById('mediaLibraryFolderInput');
  const files = Array.from(input.files || []);
  input.value = '';
  uploadMediaLibraryFiles(files.map((file) => ({
    file,
    folder: (file.webkitRelativePath || '').split('/')[0] || null
  })));
}

// Dropped files go into the open folder; a dropped folder becomes a library folder of its own.
// webkitGetAsEntry has to be read synchronously inside the drop event, before anything awaits.
async function mediaLibraryEntriesFromDrop(dataTransfer) {
  const entries = Array.from(dataTransfer.items || [])
    .map((item) => (item.webkitGetAsEntry ? item.webkitGetAsEntry() : null))
    .filter(Boolean);
  if (entries.length === 0) {
    return Array.from(dataTransfer.files || []).map((file) => ({ file, folder: null }));
  }

  const out = [];
  const walk = async (entry, topFolder) => {
    if (entry.isFile) {
      const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
      out.push({ file, folder: topFolder });
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      let batch;
      do {
        batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
        for (const child of batch) await walk(child, topFolder ?? entry.name);
      } while (batch.length > 0);
    }
  };
  for (const entry of entries) await walk(entry, null);
  return out;
}

async function uploadMediaLibraryFile(file, folder) {
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
    p_media_type: file.type.startsWith('video/') ? 'video' : 'image',
    p_file_name: file.name,
    p_folder: folder
  });
  if (addError) throw addError;
}

// entries: [{ file, folder }] - folder null means "the open folder". Skips (rather than aborts on)
// anything that isn't a supported photo/video or is over 25 MB, uploads a few at a time, and
// reports a summary when done.
async function uploadMediaLibraryFiles(entries) {
  const errorEl = document.getElementById('mediaLibraryError');
  const statusEl = document.getElementById('mediaLibraryStatus');
  const addBtns = [document.getElementById('mediaLibraryUploadBtn'), document.getElementById('addMediaLibraryBtn')];
  if (entries.length === 0 || mediaLibraryUploading) return;

  errorEl.classList.add('hidden');
  const openFolder = mediaLibraryCurrentFolder();
  const valid = entries
    .filter(({ file }) => MEDIA_LIBRARY_TYPES.includes(file.type) && file.size <= ATTACHMENT_MAX_BYTES)
    .map(({ file, folder }) => ({ file, folder: folder ?? openFolder }));
  const skipped = entries.length - valid.length;
  if (valid.length === 0) {
    errorEl.textContent = 'Nothing to add - only photos/videos (JPG, PNG, WEBP, GIF, MP4, MOV) up to 25 MB each.';
    errorEl.classList.remove('hidden');
    return;
  }

  mediaLibraryUploading = true;
  addBtns.forEach((btn) => { btn.disabled = true; });
  statusEl.classList.remove('hidden');
  let done = 0;
  const failures = [];
  const showProgress = () => {
    statusEl.innerHTML = `<span class="mlib-spinner"></span> Uploading ${Math.min(done + 1, valid.length)} of ${valid.length}...`;
  };
  showProgress();

  const queue = [...valid];
  const worker = async () => {
    while (queue.length > 0) {
      const { file, folder } = queue.shift();
      try {
        await uploadMediaLibraryFile(file, folder);
      } catch (err) {
        failures.push(`${file.name}: ${err?.message || 'upload failed'}`);
      }
      done += 1;
      showProgress();
    }
  };
  await Promise.all(Array.from({ length: MEDIA_LIBRARY_UPLOAD_CONCURRENCY }, worker));

  mediaLibraryUploading = false;
  addBtns.forEach((btn) => { btn.disabled = false; });
  const added = valid.length - failures.length;
  statusEl.textContent = `Added ${added} item${added === 1 ? '' : 's'}${skipped ? ` - skipped ${skipped} (not a photo/video, or over 25 MB)` : ''}.`;
  setTimeout(() => statusEl.classList.add('hidden'), 5000);
  if (failures.length > 0) {
    errorEl.textContent = `Could not add ${failures.length}: ${failures.slice(0, 3).join('; ')}${failures.length > 3 ? '...' : ''}`;
    errorEl.classList.remove('hidden');
  }

  // A single uploaded computer folder - open it so staff see what they just added.
  const newFolders = Array.from(new Set(valid.map((v) => v.folder).filter(Boolean)));
  if (newFolders.length === 1 && newFolders[0] !== openFolder) setMediaLibraryView(`f:${newFolders[0]}`);
  await loadMediaLibrary();
}

function initMediaLibrary() {
  const modal = document.getElementById('mediaLibraryPanel');
  const panel = modal.querySelector('.mlib-dialog');
  // Declared inside the composer's markup but shown as a full-page modal - hang it off <body> so no
  // composer ancestor (overflow / stacking context) can clip it.
  document.body.appendChild(modal);
  document.getElementById('toggleMediaLibraryBtn').addEventListener('click', () => toggleMediaLibraryPanel());
  document.getElementById('mediaLibraryCloseBtn').addEventListener('click', () => toggleMediaLibraryPanel(false));
  modal.addEventListener('click', (e) => {
    if (e.target === modal) toggleMediaLibraryPanel(false);
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !modal.classList.contains('hidden')) toggleMediaLibraryPanel(false);
  });
  document.getElementById('mediaLibrarySearchInput').addEventListener('input', (e) => {
    mediaLibrarySearch = e.target.value;
    renderMediaLibraryFolderBar();
    renderMediaLibraryGrid();
  });
  document.getElementById('mediaLibraryFolderSearchInput').addEventListener('input', (e) => {
    mediaLibraryFolderSearch = e.target.value;
    renderMediaLibraryFolders();
  });
  document.getElementById('mediaLibraryNewFolderBtn').addEventListener('click', createMediaLibraryFolder);
  document.getElementById('mediaLibraryUploadBtn').addEventListener('click', () => {
    toggleMediaLibraryAddMenu(false);
    document.getElementById('mediaLibraryFileInput').click();
  });
  document.getElementById('addMediaLibraryBtn').addEventListener('click', (e) => {
    e.stopPropagation();
    toggleMediaLibraryAddMenu();
  });
  document.getElementById('mediaLibraryAddMenu').addEventListener('click', (e) => {
    const action = e.target.closest('[data-add]')?.dataset.add;
    if (!action) return;
    toggleMediaLibraryAddMenu(false);
    if (action === 'files') document.getElementById('mediaLibraryFileInput').click();
    if (action === 'folder') document.getElementById('mediaLibraryFolderInput').click();
    if (action === 'new-folder') createMediaLibraryFolder();
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#mediaLibraryAddMenu')) toggleMediaLibraryAddMenu(false);
  });
  document.getElementById('mediaLibraryFileInput').addEventListener('change', onMediaLibraryFileChange);
  document.getElementById('mediaLibraryFolderInput').addEventListener('change', onMediaLibraryFolderInputChange);
  document.getElementById('useMediaLibrarySelectionBtn').addEventListener('click', useMediaLibrarySelection);
  document.getElementById('mediaLibraryClearSelectionBtn').addEventListener('click', () => {
    mediaLibrarySelected = [];
    renderMediaLibrary();
  });
  document.getElementById('mediaLibraryMoveSelect').addEventListener('change', onMediaLibraryMoveSelectChange);
  document.getElementById('mediaLibraryDeleteSelectedBtn').addEventListener('click', deleteSelectedMediaLibraryItems);

  let dragDepth = 0;
  const isFileDrag = (e) => Array.from(e.dataTransfer?.types || []).includes('Files');
  panel.addEventListener('dragenter', (e) => {
    if (!isFileDrag(e)) return;
    e.preventDefault();
    dragDepth += 1;
    panel.classList.add('is-dragover');
  });
  panel.addEventListener('dragover', (e) => {
    if (isFileDrag(e)) e.preventDefault();
  });
  panel.addEventListener('dragleave', () => {
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0) panel.classList.remove('is-dragover');
  });
  panel.addEventListener('drop', async (e) => {
    if (!isFileDrag(e)) return;
    e.preventDefault();
    dragDepth = 0;
    panel.classList.remove('is-dragover');
    uploadMediaLibraryFiles(await mediaLibraryEntriesFromDrop(e.dataTransfer));
  });
}

// Adds every picked library item (in the order picked) into the reply box's pending-attachment strip
// (same staging area a Quick Reply's photo(s) load into) - path: null so, same as a Quick Reply/
// Product List image, it's never mistaken for a one-off attachment the cleanup cron should delete.
function useMediaLibrarySelection() {
  const byId = new Map(mediaLibraryItems.map((item) => [item.id, item]));
  const selected = mediaLibrarySelected.map((id) => byId.get(id)).filter(Boolean);
  if (selected.length === 0) return;

  const toAdd = selected.map((item) => ({ url: item.media_url, path: null, type: item.media_type }));
  setPendingReplyImages([...pendingReplyImageUrls, ...toAdd]);
  mediaLibrarySelected = [];
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
// hit Send" panel. Uses staff_search_items_wildcard (sql/supabase_gma_product_wildcard_search.sql -
// partial-word matching, same columns as Alice's public_search_items; also used by the Create Order tab,
// plus a has_variants flag) - anon-granted, no admin session needed for the search itself.
//
// Per direct follow-up request, a product with variants (e.g. different sizes/colors) can't be
// selected directly - it expands (click to toggle, via public_list_item_variants) into its own
// variant rows instead, each individually checkable, since staff need to send a SPECIFIC variant to
// the customer, not just "the product" with no size/color specified.
//
// productLookupSelected is keyed "item:<code>" or "variant:<variationId>" (not just a bare code) so
// the two id spaces can never collide, and every entry is normalized to the same
// {name, sku, price, images} shape regardless of which kind it is - so sendProductList below
// doesn't need to know or care which.
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
    // Per "add default product list upon open" - an empty search box loads the best-sellers list.
    if (!document.getElementById('productLookupSearchInput').value.trim()) runProductLookupSearch('');
  }
}

function onProductLookupSearchInput(term) {
  clearTimeout(productLookupSearchDebounce);
  productLookupSearchDebounce = setTimeout(() => runProductLookupSearch(term.trim()), 300);
}

// An empty term loads the default list (staff_search_items_wildcard('') = best sellers, last 90
// days). productLookupSearchSeq drops a slower earlier response (e.g. the default list still loading
// when staff start typing) so it can't overwrite newer results.
let productLookupSearchSeq = 0;
let productLookupDefaultMode = false;

async function runProductLookupSearch(term) {
  const listEl = document.getElementById('productLookupList');
  const seq = ++productLookupSearchSeq;

  listEl.innerHTML = `<div class="inbox-empty-state">${term ? 'Searching...' : 'Loading best sellers...'}</div>`;
  const { data, error } = await supabaseClient.rpc('staff_search_items_wildcard', { p_query: term });
  if (seq !== productLookupSearchSeq) return;
  productLookupDefaultMode = !term;

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

// Per "is it per location?" - the picker shows staff the Amaya / GMA split instead of one combined
// total. Both come from public_search_items (sql/supabase_chatbot_stock_by_variant.sql):
// stock_by_location for a plain item, stock_by_variant (matched on variant_id = VariationId) for a
// variant - public_list_item_variants' own quantity_in_stock is the parent item's combined total,
// not the variant's. Staff-only: none of this goes into the message the customer receives.
function productLookupItemStock(item) {
  const loc = item.stock_by_location;
  if (!loc) return { total: Number(item.quantity_in_stock || 0), branches: null };
  const branches = { Amaya: Number(loc.Amaya || 0), GMA: Number(loc.GMA || 0) };
  return { total: branches.Amaya + branches.GMA, branches };
}

// Prefers public_list_item_variants' own stock_amaya/stock_gma (sql/supabase_gma_product_list_variant_
// stock.sql - also counts stock filed under a variant's own item code, which stock_by_variant misses).
function productLookupVariantStock(parentCode, variant) {
  if (variant.stock_amaya !== undefined) {
    const branches = { Amaya: Number(variant.stock_amaya || 0), GMA: Number(variant.stock_gma || 0) };
    return { total: branches.Amaya + branches.GMA, branches };
  }
  const parent = productLookupResults.find((r) => r.code === parentCode);
  if (!parent || !parent.stock_by_location) return { total: Number(variant.quantity_in_stock || 0), branches: null };
  const row = (parent.stock_by_variant || []).find((s) => s.variant_id === variant.variation_id);
  const branches = { Amaya: Number(row?.Amaya || 0), GMA: Number(row?.GMA || 0) };
  return { total: branches.Amaya + branches.GMA, branches };
}

// Always shows the per-branch split (even 0 · 0) so staff can see where stock is, not just whether.
function productLookupStockLabel({ total, branches }) {
  const inStock = total > 0;
  if (branches) return { inStock, label: `Amaya ${branches.Amaya} · GMA ${branches.GMA}` };
  return { inStock, label: inStock ? `${total} left` : 'Out of stock' };
}

// Parent row of a product with variants: the sum of its variants once they're loaded, else the
// parent's own stock_by_location (blank when that's all zero - variant stock often isn't filed there).
function productLookupParentStockHtml(item) {
  const variants = productLookupVariantsCache.get(item.code);
  let stock = null;
  if (variants && variants.length > 0) {
    const branches = { Amaya: 0, GMA: 0 };
    variants.forEach((v) => {
      const s = productLookupVariantStock(item.code, v);
      branches.Amaya += s.branches ? s.branches.Amaya : 0;
      branches.GMA += s.branches ? s.branches.GMA : 0;
    });
    stock = { total: branches.Amaya + branches.GMA, branches };
  } else {
    const own = productLookupItemStock(item);
    if (own.total > 0) stock = own;
  }
  if (!stock) return '<span class="muted">Tap to choose a variant</span>';
  const { inStock, label } = productLookupStockLabel(stock);
  return `<span class="inbox-product-lookup-stock${inStock ? '' : ' out-of-stock'}">${escapeHtml(label)}</span>`;
}

function renderProductLookupList() {
  const listEl = document.getElementById('productLookupList');

  if (productLookupResults.length === 0) {
    listEl.innerHTML = '<div class="inbox-empty-state">No matching products.</div>';
    return;
  }

  listEl.innerHTML = (productLookupDefaultMode ? '<div class="inbox-product-lookup-section-label">Best sellers · last 90 days</div>' : '')
    + productLookupResults.map((item) => renderProductLookupItemHtml(item)).join('');

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
            <span class="inbox-product-lookup-meta">${productLookupParentStockHtml(item)}</span>
          </span>
        </div>
        ${expanded ? renderProductLookupVariantsHtml(item.code, productLookupVariantsCache.get(item.code)) : ''}
      </div>
    `;
  }

  const { inStock, label } = productLookupStockLabel(productLookupItemStock(item));
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

function renderProductLookupVariantsHtml(parentCode, variants) {
  if (variants === undefined) {
    return '<div class="inbox-product-lookup-variants"><div class="inbox-empty-state">Loading variants...</div></div>';
  }
  if (variants.length === 0) {
    return '<div class="inbox-product-lookup-variants"><div class="inbox-empty-state">No variants found.</div></div>';
  }
  const rows = variants.map((v) => {
    const { inStock, label } = productLookupStockLabel(productLookupVariantStock(parentCode, v));
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

// Variant names often repeat the SKU and the parent name ("AS-002 - 75GALLONS-AQUARIUM-6MM (...)"),
// which read as the same name twice in the customer message. Strip the "SKU - " prefix; if what's left
// is just the parent name again, show the parent name alone, otherwise "Parent - Variant".
function productVariantDisplayName(parentName, variantName, sku) {
  const norm = (s) => String(s || '').trim().toLowerCase();
  let label = String(variantName || '').trim();
  if (sku && norm(label).startsWith(`${norm(sku)} - `)) label = label.slice(String(sku).trim().length + 3).trim();
  if (!parentName) return label || variantName || '';
  if (!label || norm(label) === norm(parentName) || norm(parentName).includes(norm(label))) return parentName;
  if (norm(label).includes(norm(parentName))) return label;
  return `${parentName} - ${label}`;
}

// Normalizes a selected item or variant into the same {name, sku, price, images} shape, so the send
// path below never needs to know which kind of row it came from. No stock in here on purpose - the
// customer message must never show stock counts.
function resolveProductLookupEntry(key) {
  const separatorIndex = key.indexOf(':');
  const kind = key.slice(0, separatorIndex);
  const id = key.slice(separatorIndex + 1);

  if (kind === 'item') {
    const item = productLookupResults.find((r) => r.code === id);
    if (!item) return null;
    return { name: item.name, sku: null, price: item.price, images: item.images, description: item.description };
  }

  if (kind === 'variant') {
    for (const [itemCode, variants] of productLookupVariantsCache.entries()) {
      const v = (variants || []).find((vv) => vv.variation_id === id);
      if (v) {
        const parent = productLookupResults.find((r) => r.code === itemCode);
        return {
          name: productVariantDisplayName(parent?.name, v.variant_name, v.sku),
          sku: v.sku || null,
          price: v.price,
          images: v.images,
          description: parent?.description
        };
      }
    }
  }

  return null;
}

function updateProductLookupSelectedCount() {
  document.getElementById('productLookupSelectedCount').textContent = `${productLookupSelected.size} selected`;
}

function resetProductLookup() {
  productLookupSearchSeq++; // drop any in-flight search
  productLookupResults = [];
  productLookupSelected = new Map();
  productLookupExpanded = new Set();
  productLookupVariantsCache = new Map();
  document.getElementById('productLookupSearchInput').value = '';
  document.getElementById('productLookupList').innerHTML = '<div class="inbox-empty-state">Type to search products...</div>';
  updateProductLookupSelectedCount();
}

// Customer-facing wording for a Product List send - name + price only, never stock (staff see the
// Amaya / GMA split in the picker; the customer doesn't).
const PRODUCT_LIST_INTRO = 'Here are the options for you 🐠';
const PRODUCT_LIST_OUTRO_MULTI = "Just reply with the number of the item you'd like and we'll get it ready for you 😊";
const PRODUCT_LIST_OUTRO_SINGLE = "Let us know if you'd like to order this and we'll get it ready for you 😊";

const PRODUCT_LIST_FULFILLMENT = 'Available for pickup or delivery 🚚';

// Per "can we do one message only and a picture and make the message more informative": one caption
// per product - name, price, item code (so the customer can quote it back), the description when it
// says more than the name, then pickup/delivery. With several products the intro rides on the first
// caption and the closing line on the last, instead of their own separate bubbles.
function productListCaption(item, index, items) {
  const multi = items.length > 1;
  const peso = `₱${Number(item.price || 0).toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
  const norm = (s) => String(s || '').trim().toLowerCase();
  const desc = String(item.description || '').trim();
  const showDesc = desc && !norm(item.name).includes(norm(desc)) && !norm(desc).includes(norm(item.name));

  const lines = [];
  if (multi && index === 0) lines.push(PRODUCT_LIST_INTRO, '');
  lines.push(`${multi ? `${index + 1}. ` : ''}${item.name}`);
  lines.push(`💰 Price: ${peso}`);
  if (item.sku) lines.push(`🏷️ Item code: ${item.sku}`);
  if (showDesc) lines.push(`📝 ${desc}`);
  if (!multi || index === items.length - 1) {
    lines.push('', PRODUCT_LIST_FULFILLMENT, multi ? PRODUCT_LIST_OUTRO_MULTI : PRODUCT_LIST_OUTRO_SINGLE);
  }
  return lines.join('\n');
}

// Each product goes out as its own photo with its caption right under it (one sendMessageToCustomer
// each - chatbot-staff-reply sends the photo first, then the text), so the customer can tell which
// photo is which. Everything rides sendQueue, so the order holds.
async function sendProductList() {
  if (productLookupSelected.size === 0) return;
  const items = Array.from(productLookupSelected.values());

  // Optimistic send - the bubbles appear in the thread immediately (with Retry if delivery fails),
  // so the picker can close right away.
  items.forEach((item, index) => {
    const img = firstImageUrl(item.images);
    sendMessageToCustomer(productListCaption(item, index, items), img ? [img] : []);
  });
  toggleProductLookupPanel(false);
  resetProductLookup();
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
let gmaInboxChannel = null;

function setupRealtimeInbox() {
  gmaInboxChannel = supabaseClient
    .channel('gma-inbox', { config: { presence: { key: `${currentSession.username}:${presenceTabId}` } } })
    .on('presence', { event: 'sync' }, onPresenceSync)
    .on('broadcast', { event: 'new_message' }, ({ payload }) => {
      handleGmaInboxEvent(payload);
    })
    // Another staff member opened a conversation - its bold/unread state and "Seen by" changed.
    .on('broadcast', { event: 'conversation_read' }, ({ payload }) => {
      handleConversationReadEvent(payload);
    })
    // Another staff member marked a conversation unread - bold it here too.
    .on('broadcast', { event: 'conversation_unread' }, ({ payload }) => {
      handleConversationUnreadEvent(payload);
    })
    // A customer is calling a Page / the call ended (facebook-messenger-webhook calls.ts).
    .on('broadcast', { event: 'call_ringing' }, ({ payload }) => {
      addRingingCall(payload);
      loadInboxCalls();
    })
    .on('broadcast', { event: 'call_ended' }, ({ payload }) => {
      removeRingingCall(payload?.call_id);
      handleGmaInboxEvent(payload);
      loadInboxCalls();
    })
    // A post comment arrived / was answered (comments.ts, chatbot-staff-reply comment_reply).
    .on('broadcast', { event: 'comments_changed' }, () => {
      loadPostComments();
    })
    // Another staff member pinned/unpinned a conversation - re-sort the list.
    .on('broadcast', { event: 'conversation_pinned' }, ({ payload }) => {
      loadConversations().then(() => {
        const conv = conversations.find((c) => c.psid === selectedPsid);
        if (conv && payload?.psid === selectedPsid) renderThreadHeader(conv);
      });
    })
    // Another staff member tagged/untagged a conversation, or edited the tag list.
    .on('broadcast', { event: 'conversation_tagged' }, ({ payload }) => {
      loadTags();
      loadConversations().then(() => {
        const conv = conversations.find((c) => c.psid === selectedPsid);
        if (conv && payload?.psid === selectedPsid) {
          renderThreadHeaderTags(conv);
          if (tagMenuEditing === null) renderTagMenu();
        }
      });
    })
    .on('broadcast', { event: 'tags_changed' }, () => {
      refreshAfterTagChange().then(() => { if (tagMenuEditing === null) renderTagMenu(); });
    })
    .subscribe((status) => {
      if (status === 'SUBSCRIBED') {
        trackPresence();
        loadRingingCalls();
      }
    });

  // A hidden/minimized tab isn't "reading" - it drops off the viewers until it's visible again.
  document.addEventListener('visibilitychange', trackPresence);
}

// ---------------------------------------------------------------------------
// Who's viewing - per "show an icon on the conversation if my staff is on that conversation". Supabase
// "📞 Juan is calling the RS Pet Stop Page…" banner (sql/supabase_chatbot_calls.sql). Notify only -
// staff answer in Meta Business Suite / the Facebook app; clicking the banner opens the caller's
// conversation so their history/orders are on screen while they pick up. A call whose 'call_ended'
// never arrives drops off after CALL_BANNER_MAX_MS.
const CALL_BANNER_MAX_MS = 90 * 1000;
const ringingCalls = new Map(); // call_id -> { psid, page_id, customer_name, timer }

function addRingingCall(call) {
  if (!call?.call_id || !call.psid || ringingCalls.has(call.call_id)) return;
  const startedMs = call.started_at_utc ? new Date(call.started_at_utc).getTime() : Date.now();
  const remaining = Math.max(5000, CALL_BANNER_MAX_MS - (Date.now() - startedMs));
  const timer = setTimeout(() => removeRingingCall(call.call_id), remaining);
  ringingCalls.set(call.call_id, { psid: call.psid, page_id: call.page_id, customer_name: call.customer_name, timer });
  renderCallBanner();
}

function removeRingingCall(callId) {
  const call = ringingCalls.get(callId);
  if (!call) return;
  clearTimeout(call.timer);
  ringingCalls.delete(callId);
  renderCallBanner();
}

function renderCallBanner() {
  let el = document.getElementById('inboxCallBanner');
  if (!ringingCalls.size) {
    el?.remove();
    return;
  }
  if (!el) {
    el = document.createElement('div');
    el.id = 'inboxCallBanner';
    el.className = 'inbox-call-banner';
    el.addEventListener('click', async (e) => {
      const item = e.target.closest('[data-call-id]');
      if (!item) return;
      if (e.target.closest('.inbox-call-dismiss')) {
        removeRingingCall(item.dataset.callId);
        return;
      }
      const psid = item.dataset.psid;
      if (!conversations.some((c) => c.psid === psid)) await loadConversations();
      openConversation(psid);
    });
    document.body.appendChild(el);
  }
  el.innerHTML = [...ringingCalls.entries()].map(([callId, c]) => {
    const page = PAGE_LABELS[c.page_id]?.label;
    return `<div class="inbox-call-item" data-call-id="${escapeHtml(callId)}" data-psid="${escapeHtml(c.psid)}" title="Answer in Meta Business Suite or the Facebook app - click to open this customer's conversation">
      <span class="inbox-call-icon">📞</span>
      <span><b>${escapeHtml(c.customer_name || 'A customer')}</b> is calling${page ? ` the ${escapeHtml(page)} Page` : ''}…</span>
      <button type="button" class="inbox-call-dismiss" title="Hide">&times;</button>
    </div>`;
  }).join('');
}

async function loadRingingCalls() {
  const { data, error } = await supabaseClient.rpc('admin_list_ringing_chatbot_calls', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) return; // sql/supabase_chatbot_calls.sql not run yet - live broadcasts still work
  (data || []).forEach(addRingingCall);
}

// ---------------------------------------------------------------------------
// Comments / Calls tabs (pills beside All / Unread / Read - sql/supabase_gma_comments_calls_inbox.sql).
// Comments: every comment on the Pages' posts (facebook-messenger-webhook comments.ts records them all,
// even with auto-reply off). A commenter has no Messenger PSID until a private reply goes out, so a
// comment opens in the thread pane on its own: the post, the comment, the Page's replies, and a box to
// reply publicly or send the ONE private message Facebook allows per comment (chatbot-staff-reply's
// comment_reply mode). Calls: every Messenger call (calls.ts); click = that customer's conversation.
let inboxListMode = 'chats'; // 'chats' | 'comments' | 'calls'
let postComments = [];
let postCommentsError = null;
let selectedCommentId = null;
let inboxCalls = [];
let inboxCallsError = null;

const COMMENT_STATUS_LABEL = {
  Received: ['Needs reply', 'inbox-badge-escalated'],
  Processing: ['Alice replying…', 'inbox-badge-paused'],
  Replied: ['Alice replied', ''],
  Skipped: ['No reply (spam/empty)', 'inbox-badge-paused'],
  Failed: ['Reply failed', 'inbox-badge-escalated']
};

function commentAnswered(c) {
  return !!(c.public_reply_text || c.dm_status === 'Sent' || c.page_replies?.length);
}

function commentStatusBadgeHtml(c) {
  if (c.page_replies?.some((r) => r.replied_by)) return '<span class="inbox-badge">Staff replied</span>';
  if (c.status === 'Received' && commentAnswered(c)) return '<span class="inbox-badge">Page replied</span>';
  const [label, cls] = COMMENT_STATUS_LABEL[c.status] || [c.status, ''];
  return `<span class="inbox-badge ${cls}">${escapeHtml(label)}</span>`;
}

function commentNeedsReply(c) {
  return !commentAnswered(c) && c.status !== 'Skipped' && c.status !== 'Processing';
}

function commentLink(c) {
  return c.post_permalink || `https://www.facebook.com/${encodeURIComponent(c.comment_id)}`;
}

async function loadPostComments() {
  const { data, error } = await supabaseClient.rpc('admin_list_facebook_post_comments', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_limit: 150
  });
  postCommentsError = error
    ? (error.code === 'PGRST202' ? 'The Comments tab needs sql/supabase_gma_comments_calls_inbox.sql to be run first.' : error.message)
    : null;
  postComments = data || [];
  updateListModeCounts();
  if (inboxListMode === 'comments') {
    renderConversationList();
    if (selectedCommentId) renderCommentThread(false);
  }
}

async function loadInboxCalls() {
  const { data, error } = await supabaseClient.rpc('admin_list_chatbot_calls', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_limit: 150
  });
  inboxCallsError = error
    ? (error.code === 'PGRST202' ? 'The Calls tab needs sql/supabase_gma_comments_calls_inbox.sql to be run first.' : error.message)
    : null;
  inboxCalls = data || [];
  updateListModeCounts();
  if (inboxListMode === 'calls') renderConversationList();
}

// Small counts on the pills: comments nobody has answered yet, and missed calls in the last day.
function updateListModeCounts() {
  const set = (mode, n) => {
    const el = document.querySelector(`#conversationReadFilter [data-list-mode="${mode}"] .inbox-mode-count`);
    if (el) el.textContent = n ? String(n) : '';
  };
  set('comments', postComments.filter(commentNeedsReply).length);
  const dayAgo = Date.now() - 24 * 60 * 60 * 1000;
  set('calls', inboxCalls.filter((k) => k.status === 'Missed' && new Date(k.started_at_utc).getTime() > dayAgo).length);
}

function setInboxListMode(mode) {
  if (mode === inboxListMode) return;
  const commentWasOpen = !!selectedCommentId;
  inboxListMode = mode;
  document.body.dataset.inboxListMode = mode;
  if (mode !== 'comments') selectedCommentId = null;
  if (commentWasOpen && !selectedCommentId) clearThreadPane();
  if (mode === 'comments') loadPostComments();
  if (mode === 'calls') loadInboxCalls();
  if (mode !== 'chats' && !selectedCommentId && !selectedPsid) clearThreadPane();
  renderConversationList();
}

function clearThreadPane(message = 'Select a conversation to view its messages.') {
  document.getElementById('threadHeaderEl').innerHTML = `<span class="muted">${escapeHtml(message)}</span>`;
  document.getElementById('threadMessagesEl').innerHTML = '';
  document.getElementById('replyRowEl').classList.add('hidden');
  const customerPanel = document.getElementById('customerPanelEl');
  customerPanel.classList.remove('is-create-mode');
  customerPanel.innerHTML = '<div class="inbox-empty-state">Select a conversation to look up orders.</div>';
}

function renderCommentList(listEl) {
  if (postCommentsError) {
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(postCommentsError)}</div>`;
    return;
  }
  if (!postComments.length) {
    listEl.innerHTML = '<div class="inbox-empty-state">No post comments yet. New comments on the Pages\' posts show here.</div>';
    return;
  }
  listEl.innerHTML = postComments.map((c) => {
    const unanswered = commentNeedsReply(c);
    return `
      <div class="inbox-conv-item${c.comment_id === selectedCommentId ? ' active' : ''}${unanswered ? ' inbox-conv-unread' : ''}" data-comment-id="${escapeHtml(c.comment_id)}">
        ${conversationAvatarHtml({ psid: `comment:${c.from_id}`, customer_name: c.from_name, page_id: c.page_id })}
        <div class="inbox-conv-body">
          <div class="inbox-conv-top">
            <span class="inbox-conv-psid">${escapeHtml(c.from_name || 'Facebook user')}${pageBadgeHtml(c.page_id)}${commentStatusBadgeHtml(c)}</span>
            <span class="inbox-conv-time">${formatRelativeTime(c.received_at_utc)}${unanswered ? '<span class="inbox-unread-dot" title="Not answered yet"></span>' : ''}</span>
          </div>
          <div class="inbox-conv-preview">💬 ${escapeHtml(c.message || (c.photo_url ? '[Photo/sticker]' : '(no text)'))}</div>
          ${c.post_message ? `<div class="inbox-conv-preview inbox-comment-post-line">on: ${escapeHtml(c.post_message.slice(0, 80))}</div>` : ''}
        </div>
      </div>`;
  }).join('');
  listEl.querySelectorAll('[data-comment-id]').forEach((el) => {
    el.addEventListener('click', () => openComment(el.dataset.commentId));
  });
}

function callStatusText(k) {
  if (k.status === 'Answered') return `📞 Voice call · ${formatCallDuration(k.duration_seconds || 0)}`;
  if (k.status === 'Missed') return '📞 Missed call';
  if (k.status === 'Ringing') return '📞 Ringing now…';
  return '📞 Call (no end event received)';
}

function formatCallDuration(seconds) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return m ? `${m} min${s ? ` ${s} s` : ''}` : `${s} s`;
}

function renderCallList(listEl) {
  if (inboxCallsError) {
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(inboxCallsError)}</div>`;
    return;
  }
  if (!inboxCalls.length) {
    listEl.innerHTML = '<div class="inbox-empty-state">No calls recorded yet. Messenger calls to the Pages show here once Facebook sends them (the Page needs the "calls" webhook field ticked in the Meta app).</div>';
    return;
  }
  listEl.innerHTML = inboxCalls.map((k) => `
    <div class="inbox-conv-item${k.status === 'Missed' ? ' inbox-conv-unread' : ''}" data-call-psid="${escapeHtml(k.psid)}" data-call-name="${escapeHtml(k.customer_name || '')}">
      ${conversationAvatarHtml({ psid: k.psid, customer_name: k.customer_name, page_id: k.page_id })}
      <div class="inbox-conv-body">
        <div class="inbox-conv-top">
          <span class="inbox-conv-psid">${escapeHtml(k.customer_name || k.psid)}${pageBadgeHtml(k.page_id)}</span>
          <span class="inbox-conv-time">${formatRelativeTime(k.started_at_utc)}</span>
        </div>
        <div class="inbox-conv-preview${k.status === 'Missed' ? ' inbox-call-missed' : ''}">${escapeHtml(callStatusText(k))} · ${escapeHtml(new Date(k.started_at_utc).toLocaleString())}</div>
      </div>
    </div>`).join('');
  listEl.querySelectorAll('[data-call-psid]').forEach((el) => {
    el.addEventListener('click', () => openConversationByPsid(el.dataset.callPsid, el.dataset.callName));
  });
  ensureProfilePics(inboxCalls.map((k) => ({ psid: k.psid })));
}

// Comments/Calls -> the "All" chats list (e.g. a call banner or "Open Messenger chat" click).
function activateChatsMode() {
  document.querySelectorAll('#conversationReadFilter button').forEach((b) => {
    b.classList.toggle('active', b.dataset.readFilter === '');
  });
  const filterWasOn = !!conversationReadFilter;
  conversationReadFilter = null;
  setInboxListMode('chats');
  if (filterWasOn) loadConversations();
}

// Back to Chats, then open that customer's thread (searching by name if it isn't in the latest 100).
async function openConversationByPsid(psid, name) {
  activateChatsMode();
  if (!conversations.some((c) => c.psid === psid)) {
    await loadConversations();
    if (!conversations.some((c) => c.psid === psid) && name) {
      conversationSearchTerm = name;
      document.getElementById('conversationSearchInput').value = name;
      await loadConversations();
    }
  }
  if (conversations.some((c) => c.psid === psid)) await openConversation(psid);
}

function openComment(commentId) {
  selectedCommentId = commentId;
  selectedPsid = null;
  closeThreadSearch();
  trackPresence();
  renderConversationList();
  renderCommentThread(true);
  showMobileView('chat');
}

function renderCommentThread(resetComposer) {
  const c = postComments.find((x) => x.comment_id === selectedCommentId);
  if (!c) return;
  const draft = resetComposer ? '' : (document.getElementById('commentReplyInput')?.value || '');

  document.getElementById('replyRowEl').classList.add('hidden');
  document.getElementById('threadHeaderEl').innerHTML = `
    <button type="button" class="inbox-mobile-back" id="threadBackBtn" aria-label="Back to comments">${MOBILE_BACK_ICON}</button>
    <span class="inbox-thread-title">
      <span class="inbox-thread-title-text">
        <span class="inbox-thread-name">💬 ${escapeHtml(c.from_name || 'Facebook user')}${pageBadgeHtml(c.page_id)}</span>
        <span class="inbox-thread-sub">Comment on a Page post · ${escapeHtml(new Date(c.received_at_utc).toLocaleString())}</span>
      </span>
    </span>
    <span class="inbox-header-actions">
      <a class="btn btn-secondary btn-sm" href="${escapeHtml(commentLink(c))}" target="_blank" rel="noopener">View on Facebook ↗</a>
      ${c.psid ? '<button class="btn btn-secondary btn-sm" id="commentOpenChatBtn" type="button">Open Messenger chat</button>' : ''}
    </span>`;
  document.getElementById('threadBackBtn').addEventListener('click', mobileBack);
  document.getElementById('commentOpenChatBtn')?.addEventListener('click', () => openConversationByPsid(c.psid, c.from_name));

  const pageRow = (text, sender, cls = 'staff') => `
    <div class="inbox-msg-row inbox-msg-row-${cls} inbox-msg-group-start">
      <span class="inbox-msg-sender">${escapeHtml(sender)}</span>
      <div class="inbox-msg inbox-msg-${cls}">${messageTextHtml(text)}</div>
    </div>`;
  const parts = [];
  const postFetch = postInfoFetches.get(c.comment_id);
  const postMissing = !c.post_message && !c.post_picture;
  let postBody = '';
  if (c.post_picture) postBody += `<a href="${escapeHtml(commentLink(c))}" target="_blank" rel="noopener"><img class="inbox-comment-post-photo" src="${escapeHtml(c.post_picture)}" alt="Post photo"></a>`;
  if (c.post_message) postBody += `<div class="inbox-comment-post-text">${messageTextHtml(c.post_message)}</div>`;
  if (postMissing) {
    postBody += postFetch?.error
      ? `<div class="error-text">Couldn't load the post: ${escapeHtml(postFetch.error)}</div>`
      : postFetch?.done
        ? '<div class="muted">This post has no caption or photo.</div>'
        : '<div class="muted">Loading the post from Facebook…</div>';
  }
  parts.push(`<div class="inbox-comment-post">
    <div class="inbox-comment-post-label">Our post</div>
    ${postBody}
  </div>`);
  parts.push(`
    <div class="inbox-msg-row inbox-msg-row-user inbox-msg-group-start">
      <span class="inbox-msg-sender">${escapeHtml(c.from_name || 'Facebook user')} commented</span>
      <div class="inbox-msg inbox-msg-user">${c.photo_url ? `<img class="inbox-comment-photo" src="${escapeHtml(c.photo_url)}" alt="">` : ''}${messageTextHtml(c.message || (c.photo_url ? '' : '(no text)'))}</div>
    </div>`);
  if (c.public_reply_text) parts.push(pageRow(c.public_reply_text, 'Alice · public reply', 'assistant'));
  (c.page_replies || []).forEach((r) => {
    parts.push(pageRow(r.message || '', `${r.replied_by || 'Page'} · public reply`));
  });
  if (c.dm_text) parts.push(pageRow(c.dm_text, `Private message · ${c.dm_status || ''}`, 'assistant'));
  if (c.error) parts.push(`<div class="inbox-comment-note error-text">${escapeHtml(c.error)}</div>`);

  const dmSent = c.dm_status === 'Sent';
  parts.push(`
    <div class="inbox-comment-composer">
      <textarea id="commentReplyInput" rows="2" placeholder="Write a reply…">${escapeHtml(draft)}</textarea>
      <div class="inbox-comment-composer-actions">
        <button class="btn btn-primary btn-sm" id="commentReplyPublicBtn" type="button" title="Posts under their comment - everyone can see it. Don't put prices here.">Reply publicly</button>
        <button class="btn btn-secondary btn-sm" id="commentReplyPrivateBtn" type="button" ${dmSent ? 'disabled' : ''}
          title="${dmSent ? 'Facebook allows only one private message per comment - already sent. Continue in their Messenger chat once they reply.' : 'Sends a Messenger message tied to this comment (one per comment, within 7 days). It then appears as a normal chat.'}">Send private message</button>
      </div>
      <div class="inbox-comment-note error-text hidden" id="commentReplyErrorEl"></div>
    </div>`);

  const messagesEl = document.getElementById('threadMessagesEl');
  messagesEl.innerHTML = `<div class="inbox-comment-thread">${parts.join('')}</div>`;
  document.getElementById('commentReplyPublicBtn').addEventListener('click', () => sendCommentReply(c, false));
  if (postMissing && !postFetch) fetchPostInfo(c);
  document.getElementById('commentReplyPrivateBtn').addEventListener('click', () => sendCommentReply(c, true));
  const customerPanel = document.getElementById('customerPanelEl');
  customerPanel?.classList.remove('is-create-mode');
  if (customerPanel) customerPanel.innerHTML = '<div class="inbox-empty-state">Customer details and orders appear once they message the Page - send a private message to start a Messenger chat.</div>';
}

// Post caption/photo not saved yet (comments from before comments.ts saved posts) - fetch it once per
// comment from Facebook through chatbot-staff-reply's post_info mode, which also saves it.
const postInfoFetches = new Map(); // comment_id -> { done, error }

async function fetchPostInfo(c) {
  if (postInfoFetches.has(c.comment_id)) return;
  postInfoFetches.set(c.comment_id, { done: false, error: null });
  let state;
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
        post_info: { comment_id: c.comment_id }
      })
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok || result.ok === false) throw new Error(result.error || `HTTP ${response.status}`);
    // Every comment on the same post gets it too.
    postComments.forEach((x) => {
      if (x.comment_id === c.comment_id || (c.post_id && x.post_id === c.post_id)) {
        x.post_message = x.post_message || result.post_message;
        x.post_picture = x.post_picture || result.post_picture;
        x.post_permalink = x.post_permalink || result.post_permalink;
      }
    });
    state = { done: true, error: null };
  } catch (err) {
    state = { done: true, error: err instanceof Error ? err.message : String(err) };
  }
  postInfoFetches.set(c.comment_id, state);
  if (selectedCommentId === c.comment_id) renderCommentThread(false);
}

async function sendCommentReply(c, isPrivate) {
  const input = document.getElementById('commentReplyInput');
  const errorEl = document.getElementById('commentReplyErrorEl');
  const message = input.value.trim();
  if (!message) {
    input.focus();
    return;
  }
  const buttons = [document.getElementById('commentReplyPublicBtn'), document.getElementById('commentReplyPrivateBtn')];
  buttons.forEach((b) => { b.disabled = true; });
  errorEl.classList.add('hidden');
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
        comment_reply: { comment_id: c.comment_id, message, private: isPrivate }
      })
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok || result.ok === false) throw new Error(result.error || `HTTP ${response.status}`);
    input.value = '';
    await loadPostComments();
    renderCommentThread(true);
  } catch (err) {
    errorEl.textContent = err instanceof Error ? err.message : String(err);
    errorEl.classList.remove('hidden');
    buttons.forEach((b) => { b.disabled = false; });
    if (isPrivate && c.dm_status === 'Sent') buttons[1].disabled = true;
  }
}

// Realtime Presence on the same 'gma-inbox' channel (no table/SQL): every open Conversations tab
// announces which conversation it has open (none while the tab is hidden), and Realtime drops a tab by
// itself when it closes or loses connection. Shown as initials badges on the conversation list and a
// "viewing" line in the open thread's header. Your own account isn't shown (you know you're there).
const presenceTabId = Math.random().toString(36).slice(2, 10);
let presenceByPsid = new Map(); // psid -> [{ username, display_name }] - other staff, one per account

function trackPresence() {
  if (!gmaInboxChannel) return;
  gmaInboxChannel.track({
    username: currentSession.username,
    display_name: currentSession.displayName || currentSession.username,
    psid: document.hidden ? null : selectedPsid
  }).catch(() => {});
}

function onPresenceSync() {
  const map = new Map();
  Object.values(gmaInboxChannel.presenceState()).forEach((metas) => {
    metas.forEach((m) => {
      if (!m.psid || m.username === currentSession.username) return;
      const list = map.get(m.psid) || [];
      if (!list.some((x) => x.username === m.username)) list.push({ username: m.username, display_name: m.display_name });
      map.set(m.psid, list);
    });
  });
  presenceByPsid = map;
  renderConversationList();
  renderThreadViewers();
}

function viewerInitials(name) {
  const words = String(name || '?').trim().split(/\s+/).filter(Boolean);
  return ((words[0]?.[0] || '?') + (words.length > 1 ? words[words.length - 1][0] : '')).toUpperCase();
}

// Same account -> same color on every screen.
function viewerColor(username) {
  let h = 0;
  for (const ch of String(username)) h = (h * 31 + ch.charCodeAt(0)) % 360;
  return `hsl(${h}, 55%, 42%)`;
}

function viewerBadgesHtml(psid) {
  const viewers = presenceByPsid.get(psid) || [];
  if (viewers.length === 0) return '';
  const names = viewers.map((v) => v.display_name || v.username);
  const shown = viewers.slice(0, 3).map((v) =>
    `<span class="inbox-viewer-badge" style="background:${viewerColor(v.username)}">${escapeHtml(viewerInitials(v.display_name || v.username))}</span>`
  ).join('');
  const more = viewers.length > 3 ? `<span class="inbox-viewer-badge inbox-viewer-more">+${viewers.length - 3}</span>` : '';
  return `<span class="inbox-viewers" title="${escapeHtml(names.join(', '))} viewing">${shown}${more}</span>`;
}

function renderThreadViewers() {
  const el = document.getElementById('threadViewersEl');
  if (!el) return;
  const viewers = presenceByPsid.get(selectedPsid) || [];
  el.innerHTML = viewers.length === 0
    ? ''
    : `${viewerBadgesHtml(selectedPsid)}<span class="inbox-viewers-label">${escapeHtml(viewers.map((v) => v.display_name || v.username).join(', '))} ${viewers.length === 1 ? 'is' : 'are'} viewing</span>`;
}

// ---------------------------------------------------------------------------
// Unread + "Seen by" (supabase_gma_conversation_unread_seen_by.sql). Unread is shared by the team,
// like a Facebook Page inbox: opening a conversation marks it read for everyone, and the other open
// GMA tabs hear about it over the same 'gma-inbox' channel. Each staff member's open time is kept
// for the "Seen by ..." line under the conversation.
const seenByCache = new Map(); // psid -> [{ username, display_name, last_read_at_utc }]

async function markConversationRead(psid) {
  const conv = conversations.find((c) => c.psid === psid);
  const { error } = await supabaseClient.rpc('admin_mark_chatbot_conversation_read', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: psid
  });
  if (error) return; // SQL not run yet - unread/seen-by just stay off
  if (conv && conv.is_unread) {
    conv.is_unread = false;
    renderConversationList();
  }
  gmaInboxChannel?.send({ type: 'broadcast', event: 'conversation_read', payload: { psid } });
  await loadSeenBy(psid);
}

async function loadSeenBy(psid) {
  const { data, error } = await supabaseClient.rpc('admin_get_chatbot_conversation_seen_by', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: psid
  });
  if (error) return;
  seenByCache.set(psid, data || []);
  // Only redraw once the messages are in - otherwise the "Loading messages..." placeholder would flash
  // to "No messages yet"; loadMessages draws the line itself when it lands.
  if (psid === selectedPsid && messageCache.has(psid)) renderThread();
}

// "Seen by Mark 3:45 PM, You 3:50 PM" - staff who opened the conversation since the customer's
// latest message (an older open didn't see that message). Empty when nobody has yet.
function seenByLineHtml(rows) {
  const lastCustomer = [...rows].reverse().find((m) => m.role === 'user' && m.created_at_utc);
  if (!lastCustomer) return '';
  const since = new Date(lastCustomer.created_at_utc).getTime();
  const seen = (seenByCache.get(selectedPsid) || []).filter((r) => new Date(r.last_read_at_utc).getTime() >= since);
  if (seen.length === 0) return '';
  const names = seen.map((r) => {
    const who = r.username === currentSession.username ? 'You' : (r.display_name || r.username);
    return `${who} ${formatMessageTime(r.last_read_at_utc)}`;
  });
  return `<div class="inbox-seen-by">Seen by ${escapeHtml(names.join(', '))}</div>`;
}

async function handleConversationReadEvent(payload) {
  if (!payload?.psid) return;
  const conv = conversations.find((c) => c.psid === payload.psid);
  if (conversationReadFilter) {
    loadConversations(); // it joins/leaves the filtered list
  } else if (conv && conv.is_unread) {
    conv.is_unread = false;
    renderConversationList();
  }
  if (payload.psid === selectedPsid) await loadSeenBy(payload.psid);
}

// "Mark as unread" (supabase_gma_conversation_mark_unread.sql) - shared like the rest of unread: bold
// for the whole team until someone opens it again. The thread is closed afterwards, otherwise being
// open would keep it read (markOpenConversationReadIfVisible) and the list never shows it bold.
async function markConversationUnread(conv) {
  const btn = document.getElementById('markUnreadBtn');
  btn.disabled = true;
  const { error } = await supabaseClient.rpc('admin_mark_chatbot_conversation_unread', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: conv.psid
  });
  if (error) {
    alert(error.code === 'PGRST202'
      ? 'Mark as unread needs sql/supabase_gma_conversation_mark_unread.sql to be run first.'
      : `Could not mark as unread: ${error.message}`);
    btn.disabled = false;
    return;
  }
  conv.is_unread = true;
  gmaInboxChannel?.send({ type: 'broadcast', event: 'conversation_unread', payload: { psid: conv.psid } });
  closeOpenConversation();
  if (conversationReadFilter) loadConversations(); // e.g. leaves the Read view
}

function closeOpenConversation() {
  if (isMobileInbox() && mobileView !== 'list') {
    mobileBack(); // setMobileView('list') clears selectedPsid + presence and redraws the list
    return;
  }
  selectedPsid = null;
  trackPresence();
  closeTagMenu();
  closeThreadSearch();
  document.getElementById('threadHeaderEl').innerHTML = '<span class="muted">Select a conversation to view its messages.</span>';
  document.getElementById('threadMessagesEl').innerHTML = '';
  document.getElementById('replyRowEl').classList.add('hidden');
  document.getElementById('replyErrorEl').classList.add('hidden');
  document.getElementById('customerPanelEl').innerHTML = '<div class="inbox-empty-state">Select a conversation to look up orders.</div>';
  renderConversationList();
}

function handleConversationUnreadEvent(payload) {
  if (conversationReadFilter) { loadConversations(); return; } // it joins/leaves the filtered list
  const conv = conversations.find((c) => c.psid === payload?.psid);
  if (!conv || conv.is_unread) return;
  conv.is_unread = true;
  renderConversationList();
}

// A message landing in the conversation already open (and on screen) has been seen - mark it read
// so it doesn't go bold for the rest of the team. Also when staff come back to the tab.
function markOpenConversationReadIfVisible() {
  if (!selectedPsid || document.visibilityState !== 'visible') return;
  const conv = conversations.find((c) => c.psid === selectedPsid);
  if (conv && conv.is_unread) markConversationRead(selectedPsid);
}

// "AI back on after staff is quiet for ..." - ChatbotAiSettings.StaffAutoResumeMinutes (see
// supabase_gma_bot_auto_resume.sql). Stays hidden if that SQL hasn't been run yet.
async function setupAutoResumeSetting() {
  const wrap = document.getElementById('autoResumeWrap');
  const select = document.getElementById('autoResumeMinutesSelect');
  const { data, error } = await supabaseClient.rpc('admin_get_chatbot_auto_resume_minutes', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error) return;

  const minutes = String(data ?? 30);
  if (!Array.from(select.options).some((o) => o.value === minutes)) {
    select.add(new Option(`${minutes} min`, minutes));
  }
  select.value = minutes;
  wrap.classList.remove('hidden');

  select.addEventListener('change', async () => {
    select.disabled = true;
    const { error: saveError } = await supabaseClient.rpc('admin_set_chatbot_auto_resume_minutes', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_minutes: Number(select.value)
    });
    select.disabled = false;
    if (saveError) alert(`Could not save: ${saveError.message}`);
  });
}

// List + open thread refresh in parallel (not one after the other) so a new message lands faster.
async function handleGmaInboxEvent(payload) {
  const isOpenThread = payload?.psid && payload.psid === selectedPsid;
  await Promise.all([
    loadConversations(),
    isOpenThread ? loadMessages(selectedPsid) : Promise.resolve(),
    isOpenThread ? loadAdReferrals(selectedPsid) : Promise.resolve()
  ]);

  if (isOpenThread) {
    const conv = conversations.find((c) => c.psid === selectedPsid);
    if (conv) renderThreadHeader(conv);
    markOpenConversationReadIfVisible();
  }
}

// Messenger-feel wiring for the thread: click a photo to zoom, keep pinned to the newest message
// while photos finish loading (only if staff hadn't scrolled up), paste / drag-and-drop to attach.
// Phone: swipe down to refresh (js/pullToRefresh.js) - the window never scrolls here, so it only arms
// when the finger starts on the chat list / open thread while that panel is scrolled to its very top.
function setupPullToRefresh() {
  if (!window.initPullToRefresh) return;
  initPullToRefresh(async () => {
    const tasks = [loadConversations()];
    if (mobileView === 'chat' && selectedPsid) tasks.push(loadMessages(selectedPsid));
    await Promise.all(tasks);
  }, {
    canStart: (e) => {
      const selector = { list: '#conversationListEl', chat: '#threadMessagesEl' }[mobileView];
      if (!selector || !isMobileInbox() || lightboxIsOpen()) return false;
      const scroller = e.target.closest?.(selector);
      return !!scroller && scroller.scrollTop <= 0;
    }
  });
}

function setupThreadInteractions() {
  const messagesEl = document.getElementById('threadMessagesEl');
  messagesEl.addEventListener('click', (e) => {
    const img = e.target.closest('[data-lightbox-src]');
    if (img) openLightbox(img.dataset.lightboxSrc);
    const quoteChip = e.target.closest('.inbox-quote-chip');
    if (quoteChip) {
      const d = quoteChip.dataset;
      const prefill = { length: d.length, width: d.width, height: d.height, unit: d.unit };
      // Thinnest safe glass for the size - what the calculator itself picks when the size is typed in
      // (index.html applyMinimumGlass, which doesn't run for link params). Its safety check still
      // upgrades it if staff then make the tank bigger.
      const calc = window.CustomAquariumCalculator;
      if (calc?.getMinimumGlassForSize) {
        prefill.glass = calc.getMinimumGlassForSize(calc.toInches(d.length, d.unit), calc.toInches(d.width, d.unit), calc.toInches(d.height, d.unit), false).glass;
      }
      openCalcEmbedModal('aquarium', 'reply', prefill);
    }
    // Phone: the tool panels cover the thread, so tapping the conversation closes them.
    if (isMobileInbox()) {
      toggleQuickRepliesPanel(false);
      toggleProductLookupPanel(false);
      toggleMediaLibraryPanel(false);
    }
  });
  messagesEl.addEventListener('scroll', () => {
    threadStickToBottom = threadIsNearBottom(messagesEl);
  });
  // Touch: press and hold a message to react (customer's) / reply / copy, like the Messenger app (the
  // hover ☺ and ↩ buttons are hidden on the phone layout). Cancelled if the finger moves (scrolling).
  let longPressTimer = null;
  const cancelLongPress = () => { clearTimeout(longPressTimer); longPressTimer = null; };
  messagesEl.addEventListener('touchstart', (e) => {
    const wrap = e.target.closest('.inbox-msg-bubble-wrap');
    const btn = wrap?.querySelector('.inbox-react-btn') || null;
    const replyBtn = wrap?.querySelector('.inbox-reply-to-btn');
    if ((!btn && !replyBtn) || e.target.closest('a, button, video, audio')) return;
    cancelLongPress();
    longPressTimer = setTimeout(() => {
      longPressTimer = null;
      navigator.vibrate?.(15);
      const bubble = wrap.querySelector('.inbox-msg, .inbox-msg-media, .inbox-msg-emoji') || btn || replyBtn;
      const text = wrap.querySelector('.inbox-msg')?.innerText.trim() || '';
      openReactPicker(btn, { anchor: bubble, copyText: text, replyId: replyBtn?.dataset.replyId });
    }, 450);
  }, { passive: true });
  ['touchmove', 'touchend', 'touchcancel'].forEach((type) => messagesEl.addEventListener(type, cancelLongPress, { passive: true }));
  // Stop Android's own long-press menu/text selection from fighting the reaction picker.
  messagesEl.addEventListener('contextmenu', (e) => {
    if (isMobileInbox() && e.target.closest('.inbox-msg-bubble-wrap')) e.preventDefault();
  });

  // 'load' doesn't bubble - capture catches every <img>/<video> as it finishes.
  const keepPinned = () => { if (threadStickToBottom) scrollThreadToBottom(); };
  messagesEl.addEventListener('load', keepPinned, true);
  messagesEl.addEventListener('loadedmetadata', keepPinned, true);

  // Coming back to the tab with an unread message in the open conversation = seen now.
  document.addEventListener('visibilitychange', markOpenConversationReadIfVisible);

  document.addEventListener('keydown', (e) => {
    if (!lightboxIsOpen()) return;
    if (e.key === 'Escape') closeLightbox();
    else if (e.key === 'ArrowLeft') stepLightbox(-1);
    else if (e.key === 'ArrowRight') stepLightbox(1);
  });

  document.getElementById('replyInput').addEventListener('paste', (e) => {
    const files = Array.from(e.clipboardData?.files || []).filter((f) => f.type.startsWith('image/') || f.type.startsWith('video/'));
    if (files.length === 0) return; // plain text paste - leave it alone
    e.preventDefault();
    uploadAttachmentFiles(files);
  });

  const threadCard = messagesEl.closest('.inbox-thread-card');
  let dragDepth = 0;
  const hasFiles = (e) => Array.from(e.dataTransfer?.types || []).includes('Files');
  threadCard.addEventListener('dragenter', (e) => {
    if (!hasFiles(e) || !selectedPsid) return;
    e.preventDefault();
    dragDepth++;
    threadCard.classList.add('inbox-drop-active');
  });
  threadCard.addEventListener('dragover', (e) => {
    if (hasFiles(e) && selectedPsid) e.preventDefault();
  });
  threadCard.addEventListener('dragleave', () => {
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0) threadCard.classList.remove('inbox-drop-active');
  });
  threadCard.addEventListener('drop', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth = 0;
    threadCard.classList.remove('inbox-drop-active');
    uploadAttachmentFiles(Array.from(e.dataTransfer.files || []));
  });
}

// Phone layout sizes the inbox to the VISIBLE area (--inbox-vh), which shrinks when the on-screen
// keyboard opens - so the composer rides up on top of the keyboard and the newest messages stay in
// view, like Messenger, instead of the keyboard covering the reply box (iOS doesn't resize the
// layout for the keyboard on its own).
function setupMobileViewportHeight() {
  const vv = window.visualViewport;
  const apply = () => {
    const h = vv ? vv.height : window.innerHeight;
    document.documentElement.style.setProperty('--inbox-vh', `${Math.round(h)}px`);
    if (isMobileInbox() && vv && vv.offsetTop) window.scrollTo(0, 0);
    if (isMobileInbox() && threadStickToBottom && mobileView === 'chat') scrollThreadToBottom();
  };
  apply();
  (vv || window).addEventListener('resize', apply);
  MOBILE_INBOX_QUERY.addEventListener?.('change', apply);
}


// ---------------------------------------------------------------------------
// Delivery calendar - per "in the conversations chatbox.. can we add a new button there a delivery calendar
// so the user can see the calendar availability of delivery". Read-only month view of how booked each
// delivery day is, from the same data as docs/delivery.html: admin_list_delivery_stops (booked stops),
// staff_get_delivery_route_schedule (weekly fixed route) and staff_list_delivery_date_vendors (per-date
// vendor stops). There's no truck capacity on file, so "availability" = how many stops are already
// booked, shaded by DCAL_BUSY_LEVELS. Clicking a day shows its stops; "Offer this date" puts the date into
// the reply box for staff to send.

const DCAL_BUSY_LEVELS = [
  { max: 0, cls: 'is-open' },
  { max: 2, cls: 'is-light' },
  { max: 4, cls: 'is-busy' },
  { max: Infinity, cls: 'is-full' }
];
const DCAL_DAY_OFF_DOW = 1; // Monday - production day off, Super User only (see renderDeliveryCalendarDay)

let dcalMonth = null;                 // Date - first day of the month shown
let dcalSelectedKey = null;
let dcalGeneration = 0;
let dcalStopsByDate = {};
let dcalVendorsByDate = {};
let dcalRouteByDow = null;            // day_of_week -> route row (loaded once)
// Booking mode (opened from a 📍 message's "Schedule delivery" button): the pin being booked, and this
// conversation's orders to pick from. Null = the plain read-only calendar.
let dcalBookingPin = null;            // { lat, lng, address, notes }
let dcalBookingOrders = [];
let dcalBookingQuotes = null;         // per-branch delivery fees to the pin (getPinFees)

// Reads a "📍 My delivery location" message (sql/supabase_gma_location_pin.sql builds it): header line,
// optional address, optional "Landmark / notes:" line, then the Google Maps ?q=lat,lng link.
function parsePinnedLocation(content) {
  const text = String(content || '');
  if (!text.startsWith('📍 My delivery location')) return null;
  const match = text.match(/maps\?q=(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/);
  if (!match) return null;
  const lines = text.split('\n').slice(1).map((l) => l.trim()).filter(Boolean);
  const notesLine = lines.find((l) => l.startsWith('Landmark / notes:'));
  const address = lines.filter((l) => l !== notesLine && !l.startsWith('http')).join(', ');
  return {
    lat: Number(match[1]),
    lng: Number(match[2]),
    address,
    notes: notesLine ? notesLine.replace('Landmark / notes:', '').trim() : ''
  };
}

// Delivery fee to a pin, per branch - delivery-fee-from-pin Edge Function (the bot's official formula,
// measured to the exact pin). Cached per pin for the page's lifetime: the thread re-renders often.
const pinFeeCache = new Map();

// vehicleType set = a live Lalamove quote for that vehicle instead of our own truck's fee.
function getPinFees(lat, lng, vehicleType = null) {
  const key = `${lat},${lng},${vehicleType || 'truck'}`;
  if (!pinFeeCache.has(key)) {
    pinFeeCache.set(key, (async () => {
      try {
        const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-fee-from-pin`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
            'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
          },
          body: JSON.stringify({
            admin_username: currentSession.username,
            admin_password: currentSession.password,
            latitude: lat,
            longitude: lng,
            ...(vehicleType ? { vehicle_type: vehicleType } : {})
          })
        });
        const body = await response.json().catch(() => null);
        if (!response.ok || !body?.quotes) throw new Error(body?.error || `Request failed (${response.status}).`);
        return body.quotes;
      } catch (err) {
        pinFeeCache.delete(key); // let a later render retry
        return { error: err.message };
      }
    })());
  }
  return pinFeeCache.get(key);
}

function pinFeeLabel(q) {
  // Own truck: estimatedFee; Lalamove: total.
  const amount = q && !q.error ? (q.estimatedFee ?? q.total) : null;
  return amount != null
    ? `₱${Number(amount).toLocaleString('en-PH')} <span class="muted">(${q.distanceKm} km)</span>`
    : `<span class="muted" title="${escapeHtml(q?.error || '')}">n/a</span>`;
}

function pinFeesHtml(quotes, label = 'Delivery fee') {
  if (!quotes || quotes.error) return `<span class="muted">${label} unavailable${quotes?.error ? `: ${escapeHtml(quotes.error)}` : ''}</span>`;
  return `${label}: GMA ${pinFeeLabel(quotes.GMA)} &middot; Amaya ${pinFeeLabel(quotes.Amaya)}`;
}

// The selected booking order's branch fee (orders are GMA or Amaya; anything else defaults to GMA).
function bookingFeeFor(order, quotes) {
  const q = quotes?.[order?.location === 'Amaya' ? 'Amaya' : 'GMA'];
  return q && !q.error && q.estimatedFee != null ? Number(q.estimatedFee) : null;
}

function dcalKey(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function dcalTodayKey() {
  return dcalKey(new Date());
}

function openDeliveryCalendar(pin = null) {
  const now = new Date();
  dcalMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  dcalSelectedKey = null;
  dcalBookingPin = pin;
  dcalBookingOrders = [];
  dcalBookingQuotes = null;
  document.getElementById('dcalDay').classList.add('hidden');
  const banner = document.getElementById('dcalBookingBanner');
  banner.classList.toggle('hidden', !pin);
  banner.innerHTML = pin
    ? `<strong>Booking a delivery for this pin:</strong> ${escapeHtml(pin.address || `${pin.lat}, ${pin.lng}`)}` +
      `${pin.notes ? ` &middot; Landmark: ${escapeHtml(pin.notes)}` : ''}` +
      ` &middot; <a href="https://www.google.com/maps?q=${pin.lat},${pin.lng}" target="_blank" rel="noopener">View pin &#8599;</a>` +
      '<div class="dcal-day-meta" id="dcalBookingFee">Delivery fee: calculating...</div>' +
      '<div class="dcal-day-meta">Pick a day below, then choose the order and Book - the fee for the order\'s branch is saved on the order and the calendar.</div>'
    : '';
  document.getElementById('deliveryCalendarModal').classList.remove('hidden');
  loadDeliveryCalendar();
  if (pin) {
    loadBookingOrders();
    getPinFees(pin.lat, pin.lng).then((quotes) => {
      if (dcalBookingPin !== pin) return;
      dcalBookingQuotes = quotes;
      document.getElementById('dcalBookingFee').innerHTML = pinFeesHtml(quotes);
      if (dcalSelectedKey) renderDeliveryCalendarDay(dcalSelectedKey); // order options show each one's fee
    });
  }
}

// This conversation's GMA orders, for the booking mode's order picker.
async function loadBookingOrders() {
  const conv = conversations.find((c) => c.psid === selectedPsid);
  if (!conv) return;
  const { data, error } = await supabaseClient.rpc('admin_list_automated_orders_by_gma_conversation', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: conv.psid,
    p_page_id: conv.page_id
  });
  // Only orders that can still be delivered (newest first, as listed) - not cancelled / completed / pickup.
  dcalBookingOrders = error ? [] : (data || []).filter((o) =>
    !/cancel|complete/i.test(o.status || '') && (o.fulfillment_type || 'Delivery') !== 'Pickup');
  if (dcalSelectedKey) renderDeliveryCalendarDay(dcalSelectedKey);
}

function closeDeliveryCalendar() {
  document.getElementById('deliveryCalendarModal').classList.add('hidden');
}

function shiftDeliveryCalendar(months) {
  dcalMonth = new Date(dcalMonth.getFullYear(), dcalMonth.getMonth() + months, 1);
  dcalSelectedKey = null;
  document.getElementById('dcalDay').classList.add('hidden');
  loadDeliveryCalendar();
}

async function loadDeliveryCalendar() {
  const myGeneration = ++dcalGeneration;
  const start = dcalKey(dcalMonth);
  const end = dcalKey(new Date(dcalMonth.getFullYear(), dcalMonth.getMonth() + 1, 0));
  document.getElementById('dcalMonthLabel').textContent = dcalMonth.toLocaleDateString('en-PH', { month: 'long', year: 'numeric' });
  const msgEl = document.getElementById('dcalMsg');
  msgEl.textContent = 'Loading...';
  msgEl.classList.remove('hidden');

  const auth = { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
  const [stopsRes, vendorsRes, routesRes] = await Promise.all([
    supabaseClient.rpc('admin_list_delivery_stops', { ...auth, p_start_date: start, p_end_date: end }),
    supabaseClient.rpc('staff_list_delivery_date_vendors', { ...auth, p_start_date: start, p_end_date: end }),
    dcalRouteByDow ? Promise.resolve({ data: null, error: null }) : supabaseClient.rpc('staff_get_delivery_route_schedule', auth)
  ]);
  if (myGeneration !== dcalGeneration) return;

  if (stopsRes.error) {
    msgEl.textContent = `Could not load the delivery calendar: ${stopsRes.error.message}`;
    document.getElementById('dcalGrid').innerHTML = '';
    return;
  }
  dcalStopsByDate = {};
  (stopsRes.data || []).forEach((s) => {
    if (!dcalStopsByDate[s.delivery_date]) dcalStopsByDate[s.delivery_date] = [];
    dcalStopsByDate[s.delivery_date].push(s);
  });
  Object.values(dcalStopsByDate).forEach((list) => list.sort((a, b) => (a.stop_sequence ?? 999) - (b.stop_sequence ?? 999)));
  dcalVendorsByDate = {};
  (vendorsRes.data || []).forEach((v) => {
    if (!dcalVendorsByDate[v.delivery_date]) dcalVendorsByDate[v.delivery_date] = [];
    dcalVendorsByDate[v.delivery_date].push(v.vendor_name || v.vendor_code);
  });
  if (!dcalRouteByDow) {
    dcalRouteByDow = {};
    (routesRes.data || []).forEach((r) => { dcalRouteByDow[r.day_of_week] = r; });
  }

  msgEl.classList.add('hidden');
  renderDeliveryCalendar();
  if (dcalSelectedKey) renderDeliveryCalendarDay(dcalSelectedKey);
}

// Weekly fixed-route vendors + this date's own vendor tags, deduped (same idea as delivery.js getDayVendorCodes).
function dcalDayVendors(key, dow) {
  const weekly = dcalRouteByDow?.[dow]?.vendor_names || [];
  return [...new Set([...weekly, ...(dcalVendorsByDate[key] || [])])];
}

function renderDeliveryCalendar() {
  const year = dcalMonth.getFullYear();
  const month = dcalMonth.getMonth();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const todayKey = dcalTodayKey();
  let html = '<span class="dcal-cell is-blank"></span>'.repeat(dcalMonth.getDay());

  for (let day = 1; day <= daysInMonth; day++) {
    const date = new Date(year, month, day);
    const key = dcalKey(date);
    const stops = dcalStopsByDate[key] || [];
    const route = dcalRouteByDow?.[date.getDay()];
    const vendors = dcalDayVendors(key, date.getDay());
    const level = DCAL_BUSY_LEVELS.find((l) => stops.length <= l.max);
    const classes = ['dcal-cell', level.cls];
    if (key < todayKey) classes.push('is-past');
    if (key === todayKey) classes.push('is-today');
    if (key === dcalSelectedKey) classes.push('is-selected');
    const dayOff = date.getDay() === DCAL_DAY_OFF_DOW;
    if (dayOff) classes.push('is-dayoff');
    html += `
      <button type="button" class="${classes.join(' ')}" data-dcal-date="${key}"${dayOff ? ' title="Production day off - only a Super User can book"' : ''}>
        <span class="dcal-num">${day}</span>
        <span class="dcal-count">${stops.length ? `${stops.length} stop${stops.length === 1 ? '' : 's'}` : (dayOff ? 'Day Off' : 'Open')}</span>
        ${route?.route_name ? `<span class="dcal-tag" title="Fixed route">${escapeHtml(route.route_name)}</span>` : ''}
        ${vendors.length ? `<span class="dcal-tag" title="${escapeHtml(vendors.join(', '))}">${vendors.length} vendor</span>` : ''}
      </button>`;
  }
  document.getElementById('dcalGrid').innerHTML = html;
}

function renderDeliveryCalendarDay(key) {
  dcalSelectedKey = key;
  document.querySelectorAll('#dcalGrid .dcal-cell').forEach((c) => c.classList.toggle('is-selected', c.dataset.dcalDate === key));
  const date = new Date(`${key}T00:00:00`);
  const stops = dcalStopsByDate[key] || [];
  const route = dcalRouteByDow?.[date.getDay()];
  const vendors = dcalDayVendors(key, date.getDay());
  // Per "block the monday.. its production day off.. only super user can" - a Monday can't be offered
  // or booked unless you're a Super User (admin_book_delivery_from_pin checks it too).
  const dayOff = date.getDay() === DCAL_DAY_OFF_DOW;
  const cannotBook = key < dcalTodayKey() || (dayOff && !currentSession?.isSuperUser);
  const meta = [
    dayOff ? `<strong>Production day off</strong>${currentSession?.isSuperUser ? ' - Super User override' : ' - only a Super User can book a Monday'}` : '',
    route?.route_name ? `Fixed route: ${escapeHtml(route.route_name)}` : '',
    route?.warehouse_names?.length ? `Warehouses: ${escapeHtml(route.warehouse_names.join(', '))}` : '',
    vendors.length ? `Vendor stops: ${escapeHtml(vendors.join(', '))}` : ''
  ].filter(Boolean);

  const el = document.getElementById('dcalDay');
  el.innerHTML = `
    <div class="dcal-day-head">
      <div class="dcal-day-title">${date.toLocaleDateString('en-PH', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}
        &middot; ${stops.length ? `${stops.length} stop${stops.length === 1 ? '' : 's'} booked` : 'no stops booked yet'}</div>
      ${cannotBook || dcalBookingPin ? '' : '<button type="button" class="btn btn-primary btn-sm" id="dcalOfferBtn">Offer this date</button>'}
    </div>
    ${meta.length ? `<div class="dcal-day-meta">${meta.join(' &middot; ')}</div>` : ''}
    ${dcalBookingPin && !cannotBook ? dcalBookingFormHtml() : ''}
    ${stops.map((s) => `
      <div class="dcal-stop">
        <div class="dcal-stop-main">
          <div>${escapeHtml(s.customer_name || '(no name)')}${s.order_id ? ` <span class="dcal-stop-status">#${escapeHtml(s.order_id)}</span>` : ''}</div>
          <div class="dcal-stop-addr">${escapeHtml(s.shipping_address || '')}</div>
        </div>
        <div class="dcal-stop-status">${escapeHtml([s.truck_name, s.status].filter(Boolean).join(' · '))}</div>
      </div>`).join('')}`;
  el.classList.remove('hidden');
  document.getElementById('dcalOfferBtn')?.addEventListener('click', () => offerDeliveryDate(date));
  document.getElementById('dcalBookBtn')?.addEventListener('click', () => bookDeliveryFromPin(key));
  document.getElementById('dcalBookOrder')?.addEventListener('change', (e) => {
    document.getElementById('dcalBookFee').innerHTML = dcalBookFeeHtml(dcalBookingOrders.find((o) => o.order_no === e.target.value));
  });
}

function dcalBookingFormHtml() {
  if (!dcalBookingOrders.length) {
    return '<div class="dcal-book"><div class="dcal-day-meta">No open delivery orders in this conversation yet - create the order first, then book its delivery here.</div></div>';
  }
  // Just the orders - the fee isn't a choice: it's worked out from the picked order's own branch (dcalBookFeeHtml).
  const options = dcalBookingOrders.map((o) => {
    const total = o.estimated_total != null ? ` · ₱${Number(o.estimated_total).toLocaleString('en-PH', { maximumFractionDigits: 2 })}` : '';
    return `<option value="${escapeHtml(o.order_no)}">${escapeHtml(o.order_no)}${o.customer_name ? ` · ${escapeHtml(o.customer_name)}` : ''}${total}</option>`;
  }).join('');
  return `
    <div class="dcal-book">
      <select id="dcalBookOrder" aria-label="Order to deliver">${options}</select>
      <button type="button" class="btn btn-primary btn-sm" id="dcalBookBtn">Book this date</button>
      <div class="dcal-day-meta" id="dcalBookFee">${dcalBookFeeHtml(dcalBookingOrders[0])}</div>
      <div class="dcal-msg hidden" id="dcalBookMsg"></div>
    </div>`;
}

// The delivery fee that will be saved for this order: to the pin, from the branch tagged on the order.
function dcalBookFeeHtml(order) {
  const branch = order?.location === 'Amaya' ? 'Amaya' : 'GMA';
  if (!dcalBookingQuotes) return `Delivery fee from ${branch}: calculating...`;
  const fee = bookingFeeFor(order, dcalBookingQuotes);
  return fee != null
    ? `Delivery fee: <strong>₱${fee.toLocaleString('en-PH')}</strong> from ${branch} (the order's branch) - saved on the order and the calendar when you book.`
    : `Delivery fee from ${branch} couldn't be calculated - the order's fee will be left as it is.`;
}

// Books the chosen order on this date with the customer's pin as the stop's map location
// (sql/supabase_gma_pin_delivery_booking.sql), then puts a confirmation in the reply box for staff to send.
async function bookDeliveryFromPin(key) {
  const pin = dcalBookingPin;
  const orderNo = document.getElementById('dcalBookOrder')?.value;
  const msgEl = document.getElementById('dcalBookMsg');
  const btn = document.getElementById('dcalBookBtn');
  if (!pin || !orderNo) return;
  const date = new Date(`${key}T00:00:00`);
  const dateLabel = date.toLocaleDateString('en-PH', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' });
  btn.disabled = true;
  btn.textContent = 'Getting fee...';
  const quotes = await getPinFees(pin.lat, pin.lng);
  btn.disabled = false;
  btn.textContent = 'Book this date';
  const order = dcalBookingOrders.find((o) => o.order_no === orderNo);
  const fee = bookingFeeFor(order, quotes);
  const feeText = fee != null ? `₱${fee.toLocaleString('en-PH')}` : null;
  if (!confirm(`Book delivery of order ${orderNo} on ${dateLabel} at the customer's pinned location?\n\n`
    + (feeText ? `Delivery fee ${feeText} will be saved on the order and the calendar.` : 'The delivery fee could not be calculated - the order\'s fee will be left as it is.'))) return;

  btn.disabled = true;
  btn.textContent = 'Booking...';
  const { data: result, error } = await supabaseClient.rpc('admin_book_delivery_from_pin', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_no: orderNo,
    p_delivery_date: key,
    p_latitude: pin.lat,
    p_longitude: pin.lng,
    p_address: pin.address || null,
    p_notes: pin.notes || null,
    p_delivery_fee: fee
  });
  btn.disabled = false;
  btn.textContent = 'Book this date';
  if (error) {
    msgEl.textContent = error.code === 'PGRST202' ? 'Run sql/supabase_gma_pin_delivery_booking.sql first.' : `Could not book: ${error.message}`;
    msgEl.classList.remove('hidden');
    return;
  }
  // Fee couldn't go on the order (Pancake order, cancelled...) - say so; the booking itself went through.
  const feeNote = result?.[0]?.fee_note;
  if (feeNote && feeNote.startsWith('Booked, but')) alert(feeNote);
  // Order card(s) in the customer panel show the new fee / total.
  const conv = conversations.find((c) => c.psid === selectedPsid);
  if (conv && conversationOrdersConv?.psid === conv.psid) loadConversationOrders(conv);

  const input = document.getElementById('replyInput');
  const line = `✅ Your delivery is ${result?.[0]?.moved ? 'now ' : ''}scheduled for ${dateLabel} (Order ${orderNo}).`
    + (feeText && !(feeNote || '').startsWith('Booked, but') ? ` Delivery fee: ${feeText}.` : '')
    + ' We\'ll deliver to the location you pinned.';
  input.value = input.value.trim() ? `${input.value.trimEnd()}\n${line}` : line;
  input.dispatchEvent(new Event('input', { bubbles: true }));
  autoResizeReplyInput();
  closeDeliveryCalendar();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

// Puts the date into the reply box (after anything already typed) for staff to check and send.
function offerDeliveryDate(date) {
  const input = document.getElementById('replyInput');
  const line = `Available delivery date: ${date.toLocaleDateString('en-PH', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}`;
  input.value = input.value.trim() ? `${input.value.trimEnd()}\n${line}` : line;
  input.dispatchEvent(new Event('input', { bubbles: true }));
  autoResizeReplyInput();
  closeDeliveryCalendar();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

// 📍 button: a one-time "pin your delivery location" map link for this conversation
// (sql/supabase_gma_location_pin.sql, docs/pin-location.html), put into the reply box for staff to send.
// The customer's pin comes back into this thread as their own message with a Google Maps link.
async function insertLocationPinLink() {
  if (!selectedPsid) return;
  const btn = document.getElementById('sendLocationPinBtn');
  btn.disabled = true;
  const { data: token, error } = await supabaseClient.rpc('admin_create_location_request', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_psid: selectedPsid
  });
  btn.disabled = false;
  if (error || !token) {
    alert(error?.code === 'PGRST202'
      ? 'Run sql/supabase_gma_location_pin.sql first.'
      : `Couldn't create the map link: ${error?.message || 'unknown error'}`);
    return;
  }
  const link = `https://rspetstop.com/pin-location.html?t=${token}`;
  const text = `To help our delivery team find you, please pin your exact location on the map here 📍\n${link}`;
  const input = document.getElementById('replyInput');
  input.value = input.value.trim() ? `${input.value.trimEnd()}\n${text}` : text;
  input.dispatchEvent(new Event('input', { bubbles: true }));
  autoResizeReplyInput();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

// Price list menu: the retail (public_list_order_items, the same list Alice's list_items_in_category reads)
// or wholesale (public_list_wholesale_items, Alice's list_wholesale_prices) price of every active Aquarium /
// Stand / Sump item, put into the reply box for staff to check and send. One [split] per category -
// chatbot-staff-reply sends each as its own message (Messenger's 2000-char cap).
const PRICE_LIST_CATEGORIES = [
  { code: 'AQUARIUM', title: '🐠 AQUARIUMS' },
  { code: 'STAND', title: '🪵 STANDS' },
  { code: 'SUMP', title: '💧 SUMP FILTRATION' }
];

async function insertPriceList(kind) {
  if (!selectedPsid) return;
  const wholesale = kind === 'wholesale';
  const btn = document.getElementById('insertPriceListBtn');
  btn.disabled = true;
  // Rows normalised to { name, price, category }.
  let rows;
  let loadError = null;
  if (wholesale) {
    const { data, error } = await supabaseClient.rpc('public_list_wholesale_items');
    loadError = error;
    rows = (data || []).map((it) => ({ name: it.name, price: it.wholesale_price, category: it.category_code }));
  } else {
    const results = await Promise.all(PRICE_LIST_CATEGORIES.map((c) =>
      supabaseClient.rpc('public_list_order_items', { p_category_code: c.code })));
    loadError = results.find((r) => r.error)?.error || null;
    rows = results.flatMap((r, i) => (r.data || []).map((it) => ({ name: it.name, price: it.price, category: PRICE_LIST_CATEGORIES[i].code })));
  }
  btn.disabled = false;

  if (loadError) {
    alert(`Couldn't load the price list: ${loadError.message}`);
    return;
  }

  const label = wholesale ? 'Wholesale Price' : 'Retail Price';
  const peso = (n) => `₱${Number(n).toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
  const sections = PRICE_LIST_CATEGORIES.map((c) => {
    const items = rows
      .filter((it) => it.category === c.code && Number(it.price) > 0)
      .sort((a, b) => String(a.name).localeCompare(String(b.name), undefined, { numeric: true, sensitivity: 'base' }));
    if (items.length === 0) return null;
    return `${c.title} - ${label}\n${items.map((it) => `• ${it.name} - ${peso(it.price)}`).join('\n')}`;
  }).filter(Boolean);

  if (sections.length === 0) {
    alert(`No Aquarium / Stand / Sump items with a ${label.toLowerCase()} found.`);
    return;
  }

  // Wholesale terms: same rule as Alice's WHOLESALE PRICING / WHOLESALE_MIN_TOTAL.
  const intro = wholesale
    ? `Here is our wholesale price list for aquariums, stands and sump filtration. Wholesale pricing applies with a minimum of ₱${WHOLESALE_MIN_TOTAL.toLocaleString()} per transaction on these items (individual pieces only - not Sets/packages or custom builds).`
    : 'Here is our retail price list for aquariums, stands and sump filtration:';
  // Closing line - its own message, asks for an easy next step.
  const closing = wholesale
    ? `Which items and how many pieces are you planning to get? Send us your list and we'll total it for you and check it meets the ₱${WHOLESALE_MIN_TOTAL.toLocaleString()} wholesale minimum.`
    : "Which size are you looking at? 😊 Just tell us and we'll check availability and delivery for you. We also do custom sizes if you don't see what you need.";
  const text = `${intro}\n[split]\n${sections.join('\n[split]\n')}\n[split]\n${closing}`;
  const input = document.getElementById('replyInput');
  input.value = input.value.trim() ? `${input.value.trimEnd()}\n${text}` : text;
  input.dispatchEvent(new Event('input', { bubbles: true }));
  autoResizeReplyInput();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

// Share an Aquarium Set - per "the sets can we also share it on the conversations? i mean manually?".
// Same list Alice's list_aquarium_sets reads (public_list_aquarium_sets, price-0 sets left out the same
// way), so staff and the bot quote the same sets. Per "is this set coming from customer aquarium setup?":
// the contents come from the set's Customer Aquarium package (its parts + the parts the store picks);
// only a set with no package falls back to its Description. Price = the item price orders charge.
let setPickerSets = [];

function setTitle(set) {
  // The item name tells the sets apart (size, glass, overhead/undersump) - a Description's first line
  // doesn't always ("150 Gallons Aquarium w/ Rubber Matt" on both 150G sets). Tidy its code style.
  return String(set.name || set.code).replace(/COMPETE/gi, 'COMPLETE').replace(/-/g, ' ').replace(/\s+/g, ' ').trim();
}

function setShareText(set) {
  const peso = `₱${Number(set.price).toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
  let descLines = String(set.description || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  // A first line like "100Gallons Overhead Complete Setup" just repeats the title.
  if (descLines.length > 1 && /\bset(up)?\b/i.test(descLines[0])) descLines = descLines.slice(1);
  let body = '';
  if ((set.includes || []).length > 0) {
    const parts = set.includes.map((p) => `• ${Number(p.qty) > 1 ? `${Number(p.qty)}pcs ` : ''}${p.item}`);
    (set.store_selected || []).forEach((p) => parts.push(`• ${p}`));
    body = `Includes:\n${parts.join('\n')}`;
  } else if (descLines.length > 1) {
    body = descLines.map((l) => (/^[*•\-]/.test(l) || /^all you need/i.test(l) ? l : `• ${l}`)).join('\n');
  }
  const notIncluded = (set.not_included || []).length
    ? `\nNot included in this set: ${set.not_included.join(', ')} (available as an add-on).`
    : '';
  const packageNote = /cannot remove|can't remove/i.test(body) ? '' : '\n*Sold as a complete package - items inside the set cannot be removed or swapped.';
  return `🐠 ${setTitle(set)}\nPackage price: ${peso}\n\n${body}${notIncluded}${packageNote}\n[split]\nWould you like to get this set? 😊 We can check availability and delivery for you.`;
}

function insertTextIntoReply(text) {
  const input = document.getElementById('replyInput');
  input.value = input.value.trim() ? `${input.value.trimEnd()}\n${text}` : text;
  input.dispatchEvent(new Event('input', { bubbles: true }));
  autoResizeReplyInput();
  input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}

function closeSetPicker() {
  document.getElementById('setPickerModal').classList.add('hidden');
}

async function openSetPicker() {
  if (!selectedPsid) return;
  const listEl = document.getElementById('setPickerList');
  listEl.innerHTML = '<div class="inbox-empty-state">Loading...</div>';
  document.getElementById('setPickerModal').classList.remove('hidden');

  const { data, error } = await supabaseClient.rpc('public_list_aquarium_sets');
  if (error) {
    listEl.innerHTML = `<div class="inbox-empty-state error-text">${escapeHtml(error.message)}</div>`;
    return;
  }
  setPickerSets = (data || [])
    .filter((s) => Number(s.price) > 0)
    .sort((a, b) => String(a.name).localeCompare(String(b.name), undefined, { numeric: true, sensitivity: 'base' }));
  if (setPickerSets.length === 0) {
    listEl.innerHTML = '<div class="inbox-empty-state">No aquarium sets with a price found.</div>';
    return;
  }
  listEl.innerHTML = setPickerSets.map((s, index) => `
      <div class="variant-picker-row" data-index="${index}">
        <div class="variant-picker-row-info">
          <div class="variant-picker-row-name">${escapeHtml(setTitle(s))}</div>
          <div class="variant-picker-row-sku">${escapeHtml(s.code)}</div>
        </div>
        <div class="variant-picker-row-meta">
          <div class="variant-picker-row-price">₱${Number(s.price).toLocaleString(undefined, { maximumFractionDigits: 2 })}</div>
        </div>
      </div>
    `).join('');
  listEl.querySelectorAll('.variant-picker-row').forEach((row) => {
    row.addEventListener('click', () => {
      insertTextIntoReply(setShareText(setPickerSets[parseInt(row.dataset.index, 10)]));
      closeSetPicker();
    });
  });
}

function insertAllSetsList() {
  if (setPickerSets.length === 0) return;
  const peso = (n) => `₱${Number(n).toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
  const list = setPickerSets.map((s) => `• ${setTitle(s)} - ${peso(s.price)}`).join('\n');
  insertTextIntoReply(`Here are our ready-made Aquarium Complete Setup Sets (package price, all-in):\n${list}\n[split]\nWhich size are you looking at? 😊 Tell us and we'll send you the full inclusions of that set.`);
  closeSetPicker();
}

// Delivery quote window - per "add a button there delivery quote.. a small delivery quote window that will
// help the staff quote price of delivery". Same official formula as Vic (delivery-fee-from-pin Edge
// Function -> computeDeliveryQuote / computeLalamoveQuote), to a typed address or the customer's latest
// pin in this chat, from both branches; "Put in reply" drops the price into the reply box.
let dqPin = null; // the chat's latest "📍 My delivery location", if any
let dqPsid = null; // the chat the window was last opened for
let dqSeq = 0;      // newest quote request - an older one finishing later is ignored

const DQ_VEHICLE_LABELS = { MOTORCYCLE: 'Motorcycle', SEDAN: 'Sedan', MPV: 'MPV', TRUCK330: 'Small truck (L300)', '2000KG_ALUMINUM': '2-ton truck' };

function openDeliveryQuote() {
  const rows = messageCache.get(selectedPsid) || [];
  dqPin = null;
  for (let i = rows.length - 1; i >= 0 && !dqPin; i--) {
    if (rows[i].role === 'user') dqPin = parsePinnedLocation(rows[i].content);
  }
  document.getElementById('dqPinRow').classList.toggle('hidden', !dqPin);
  document.getElementById('dqUsePin').checked = !!dqPin;
  // Keep what staff typed while it's the same chat; a different chat starts fresh (its pin's address, if any).
  const addressEl = document.getElementById('dqAddress');
  if (dqPsid !== selectedPsid) addressEl.value = dqPin?.address || '';
  dqPsid = selectedPsid;
  document.getElementById('dqResults').innerHTML = '';
  document.getElementById('deliveryQuoteModal').classList.remove('hidden');
  addressEl.focus();
  // Quote straight away when there's already something to quote (a pin, or an address from before).
  if (dqPin || addressEl.value.trim().length >= 5) runDeliveryQuote();
}

function closeDeliveryQuote() {
  clearTimeout(dqTypingTimer);
  dqSeq++; // a quote still loading shouldn't land after the window is closed
  document.getElementById('deliveryQuoteModal').classList.add('hidden');
}

async function runDeliveryQuote() {
  const usePin = !!dqPin && document.getElementById('dqUsePin').checked;
  const address = document.getElementById('dqAddress').value.trim();
  const method = document.getElementById('dqMethod').value;
  const vehicle = method === 'lalamove' ? document.getElementById('dqVehicle').value : null;
  const resultsEl = document.getElementById('dqResults');
  if (!usePin && address.length < 5) {
    dqSeq++; // drop any quote still loading for the old address
    hideDqMap();
    document.getElementById('dqQuoteBtn').disabled = false;
    resultsEl.innerHTML = '<div class="dq-note">Type the full address (street, barangay, city) - the quote updates as you type.</div>';
    return;
  }
  // Auto re-quotes can overlap (a field changed while one was still loading) - only the newest one shows.
  const seq = ++dqSeq;
  const btn = document.getElementById('dqQuoteBtn');
  btn.disabled = true;
  resultsEl.innerHTML = `<div class="dq-note">${vehicle ? 'Asking Lalamove...' : 'Calculating...'}</div>`;
  renderDeliveryQuoteMap(seq, usePin, address); // in parallel with the price - no need to wait for it
  let quotes;
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-fee-from-pin`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password,
        address,
        ...(usePin ? { latitude: dqPin.lat, longitude: dqPin.lng } : {}),
        ...(vehicle ? { vehicle_type: vehicle } : {})
      })
    });
    const body = await response.json().catch(() => null);
    if (seq !== dqSeq) return; // a newer quote is on its way
    if (!response.ok || !body?.quotes) throw new Error(body?.error || `Request failed (${response.status}).`);
    quotes = body.quotes;
  } catch (err) {
    if (seq === dqSeq) resultsEl.innerHTML = `<div class="dq-note error-text">Could not get a quote: ${escapeHtml(err.message)}</div>`;
    return;
  } finally {
    if (seq === dqSeq) btn.disabled = false;
  }

  const place = usePin ? 'your pinned location' : address;
  resultsEl.innerHTML = ['GMA', 'Amaya'].map((branch) => {
    const q = quotes[branch];
    const amount = q && !q.error ? (q.estimatedFee ?? q.total) : null;
    if (amount == null) {
      return `<div class="dq-result"><span><strong>${branch}</strong> &middot; <span class="muted">${escapeHtml(q?.error || 'n/a')}</span></span></div>`;
    }
    const peso = `₱${Number(amount).toLocaleString('en-PH')}`;
    const line = vehicle
      ? `Lalamove (${DQ_VEHICLE_LABELS[vehicle]}) from our ${branch} branch to ${place}: ${q.approximate ? 'approx. ' : ''}${peso} - Lalamove's live rate, may change slightly at booking.`
      : `Delivery fee from our ${branch} branch to ${place}: ${peso}.`;
    return `
      <div class="dq-result">
        <span><strong>${branch}</strong> &middot; ${q.approximate ? 'approx. ' : ''}${peso} <span class="muted">(${q.distanceKm} km${q.tollAmount ? ` incl. ₱${Number(q.tollAmount).toLocaleString('en-PH')} toll` : ''})</span></span>
        <button type="button" class="btn btn-secondary btn-sm dq-insert-btn" data-line="${escapeHtml(line)}">Put in reply</button>
      </div>`;
  }).join('') + (Object.values(quotes).some((q) => q?.approximate)
    ? '<div class="dq-note">Approximate - the address only matched the barangay / area. Ask for the pin for an exact price.</div>'
    : '');
  resultsEl.querySelectorAll('.dq-insert-btn').forEach((b) => b.addEventListener('click', () => {
    const input = document.getElementById('replyInput');
    input.value = input.value.trim() ? `${input.value.trimEnd()}\n${b.dataset.line}` : b.dataset.line;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    autoResizeReplyInput();
    closeDeliveryQuote();
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  }));
}

// Mini map in the Delivery Quote window - per "show a mini map too on the delivery quote": the customer's spot,
// both branches (public_get_warehouse_location - the same branch points the fee is measured from) and the
// driving route from each. Google Maps is only loaded the first time it's needed (key from PortalSettings,
// public_get_google_maps_api_key - same as track-driver.html / pin-location.html). Best-effort: if the map
// can't load, the quote itself still shows.
const DQ_BRANCH_COLORS = { GMA: '#1d4f91', Amaya: '#15803d' };
let dqMapsReady = null;
let dqMap = null;
let dqMapOverlays = [];
let dqBranchPoints = null;
let dqMapKey = null; // the destination the map currently shows

function loadGoogleMapsForQuote() {
  if (window.google?.maps) return Promise.resolve();
  if (!dqMapsReady) {
    dqMapsReady = (async () => {
      const { data: apiKey, error } = await supabaseClient.rpc('public_get_google_maps_api_key');
      if (error || !apiKey) throw new Error('Google Maps is not configured.');
      await new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(apiKey)}`;
        script.async = true;
        script.onload = resolve;
        script.onerror = () => reject(new Error('Google Maps failed to load.'));
        document.head.appendChild(script);
      });
    })().catch((err) => { dqMapsReady = null; throw err; });
  }
  return dqMapsReady;
}

async function getBranchPoints() {
  if (!dqBranchPoints) {
    const rows = await Promise.all(['GMA', 'Amaya'].map((b) => supabaseClient.rpc('public_get_warehouse_location', { p_location: b })));
    dqBranchPoints = {};
    ['GMA', 'Amaya'].forEach((b, i) => {
      const r = rows[i].data?.[0];
      if (r?.latitude != null) dqBranchPoints[b] = { lat: Number(r.latitude), lng: Number(r.longitude) };
    });
  }
  return dqBranchPoints;
}

function hideDqMap() {
  document.getElementById('dqMap').classList.add('hidden');
  document.getElementById('dqMapLegend').classList.add('hidden');
}

// seq: the quote this map belongs to - a newer quote replaces it.
async function renderDeliveryQuoteMap(seq, usePin, address) {
  // Same destination as the map already shows (e.g. only the vehicle / method changed) - keep it, no new
  // geocode / route requests.
  const destKey = usePin ? `pin:${dqPin.lat},${dqPin.lng}` : `addr:${address.toLowerCase()}`;
  if (destKey === dqMapKey && dqMap && !document.getElementById('dqMap').classList.contains('hidden')) return;
  // dqMapKey is only set once a map has fully drawn (below), so an interrupted draw is never "kept".
  try {
    await loadGoogleMapsForQuote();
    const branches = await getBranchPoints();
    let dest = usePin ? { lat: dqPin.lat, lng: dqPin.lng } : null;
    if (!dest) {
      const result = await new Promise((resolve) => new google.maps.Geocoder().geocode(
        { address, componentRestrictions: { country: 'PH' } },
        (results, status) => resolve(status === 'OK' ? results?.[0] : null)));
      if (!result) throw new Error('Address not found on the map.');
      dest = { lat: result.geometry.location.lat(), lng: result.geometry.location.lng() };
    }
    if (seq !== dqSeq) return;

    const mapEl = document.getElementById('dqMap');
    mapEl.classList.remove('hidden');
    document.getElementById('dqMapLegend').classList.remove('hidden');
    if (!dqMap) {
      dqMap = new google.maps.Map(mapEl, { center: dest, zoom: 12, mapTypeControl: false, streetViewControl: false, fullscreenControl: false });
    }
    dqMapOverlays.forEach((o) => o.setMap(null));
    dqMapOverlays = [];

    const bounds = new google.maps.LatLngBounds();
    dqMapOverlays.push(new google.maps.Marker({ map: dqMap, position: dest, title: 'Customer' }));
    bounds.extend(dest);
    const directions = new google.maps.DirectionsService();
    await Promise.all(Object.entries(branches).map(async ([name, point]) => {
      dqMapOverlays.push(new google.maps.Marker({
        map: dqMap, position: point, title: `${name} branch`,
        label: { text: name === 'GMA' ? 'G' : 'A', color: '#fff', fontWeight: '700' },
        icon: { path: google.maps.SymbolPath.CIRCLE, scale: 11, fillColor: DQ_BRANCH_COLORS[name], fillOpacity: 1, strokeColor: '#fff', strokeWeight: 2 }
      }));
      bounds.extend(point);
      try {
        const route = await directions.route({ origin: point, destination: dest, travelMode: google.maps.TravelMode.DRIVING });
        if (seq !== dqSeq) return;
        const renderer = new google.maps.DirectionsRenderer({
          map: dqMap, directions: route, suppressMarkers: true, preserveViewport: true,
          polylineOptions: { strokeColor: DQ_BRANCH_COLORS[name], strokeOpacity: 0.8, strokeWeight: 4 }
        });
        dqMapOverlays.push(renderer);
      } catch {
        // No route drawn for this branch - its marker still shows.
      }
    }));
    if (seq !== dqSeq) return;
    google.maps.event.trigger(dqMap, 'resize');
    dqMap.fitBounds(bounds, 30);
    dqMapKey = destKey;
  } catch {
    if (seq === dqSeq) { hideDqMap(); dqMapKey = null; }
  }
}

// Per "auto validate the delivery quote when a field is changed": method / vehicle / pin re-quote right
// away; the address re-quotes once typing pauses (so Google isn't called on every keystroke).
const DQ_TYPING_PAUSE_MS = 900;
let dqTypingTimer = null;

function initDeliveryQuote() {
  document.getElementById('openDeliveryQuoteBtn')?.addEventListener('click', openDeliveryQuote);
  document.getElementById('closeDeliveryQuoteBtn').addEventListener('click', closeDeliveryQuote);
  document.getElementById('dqQuoteBtn').addEventListener('click', runDeliveryQuote);
  document.getElementById('dqMethod').addEventListener('change', (e) => {
    document.getElementById('dqVehicle').classList.toggle('hidden', e.target.value !== 'lalamove');
    runDeliveryQuote();
  });
  document.getElementById('dqVehicle').addEventListener('change', runDeliveryQuote);
  document.getElementById('dqUsePin').addEventListener('change', (e) => {
    // Unticked = quote the typed address instead (e.g. the customer gave a different place).
    document.getElementById('dqAddress').placeholder = e.target.checked ? 'Using the pinned location' : 'Full address: house no., street, barangay, city';
    runDeliveryQuote();
  });
  document.getElementById('dqAddress').addEventListener('input', () => {
    clearTimeout(dqTypingTimer);
    // With the pin ticked the address is just a label - nothing to re-quote.
    if (dqPin && document.getElementById('dqUsePin').checked) return;
    dqTypingTimer = setTimeout(runDeliveryQuote, DQ_TYPING_PAUSE_MS);
  });
}

function initDeliveryCalendar() {
  document.getElementById('openDeliveryCalendarBtn')?.addEventListener('click', () => openDeliveryCalendar());
  document.getElementById('closeDeliveryCalendarBtn').addEventListener('click', closeDeliveryCalendar);
  document.getElementById('dcalPrevBtn').addEventListener('click', () => shiftDeliveryCalendar(-1));
  document.getElementById('dcalNextBtn').addEventListener('click', () => shiftDeliveryCalendar(1));
  document.getElementById('dcalTodayBtn').addEventListener('click', () => {
    const now = new Date();
    dcalMonth = new Date(now.getFullYear(), now.getMonth(), 1);
    dcalSelectedKey = dcalTodayKey();
    loadDeliveryCalendar();
  });
  document.getElementById('dcalGrid').addEventListener('click', (event) => {
    const cell = event.target.closest('[data-dcal-date]');
    if (cell) renderDeliveryCalendarDay(cell.dataset.dcalDate);
  });
  document.getElementById('deliveryCalendarModal').addEventListener('click', (event) => {
    if (event.target.id === 'deliveryCalendarModal') closeDeliveryCalendar();
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Conversations');

  if (!session.isSuperUser && !session.isConversationsStaff) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Conversations.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('inboxContent').classList.remove('hidden');
  // A reload keeps the old history entry's view, but nothing is open yet - start on the chat list.
  if (history.state?.inboxView) history.replaceState(null, '');
  setMobileView('list');
  setupMobileViewportHeight();
  if (isMobileInbox()) document.getElementById('replyInput').placeholder = 'Aa';
  document.getElementById('conversationSearchInput').addEventListener('input', (e) => onConversationSearchInput(e.target.value));
  initThreadSearch();
  document.getElementById('toggleQuickRepliesBtn').addEventListener('click', () => toggleQuickRepliesPanel());
  document.getElementById('toggleAttachmentBtn').addEventListener('click', () => document.getElementById('attachmentFileInput').click());
  document.getElementById('attachmentFileInput').addEventListener('change', onAttachmentFileChange);
  document.getElementById('toggleProductLookupBtn').addEventListener('click', () => toggleProductLookupPanel());
  initDeliveryCalendar();
  initDeliveryQuote();
  document.getElementById('sendLocationPinBtn').addEventListener('click', insertLocationPinLink);
  // Price list menu (Retail / Wholesale) - same open/close behaviour as the Quote menu below.
  const priceListBtn = document.getElementById('insertPriceListBtn');
  const priceListMenu = document.getElementById('priceListMenuEl');
  const setPriceListMenuOpen = (open) => {
    priceListMenu.classList.toggle('hidden', !open);
    priceListBtn.classList.toggle('active', open);
    priceListBtn.setAttribute('aria-expanded', String(open));
  };
  priceListBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    setPriceListMenuOpen(priceListMenu.classList.contains('hidden'));
  });
  document.addEventListener('click', (e) => {
    if (!priceListMenu.classList.contains('hidden') && !priceListMenu.contains(e.target)) setPriceListMenuOpen(false);
  });
  [['insertRetailPriceListBtn', 'retail'], ['insertWholesalePriceListBtn', 'wholesale']].forEach(([id, kind]) =>
    document.getElementById(id).addEventListener('click', () => {
      setPriceListMenuOpen(false);
      insertPriceList(kind);
    }));
  document.getElementById('openSetPickerBtn').addEventListener('click', () => {
    setPriceListMenuOpen(false);
    openSetPicker();
  });
  document.getElementById('insertAllSetsBtn').addEventListener('click', insertAllSetsList);
  document.getElementById('closeSetPickerBtn').addEventListener('click', closeSetPicker);
  // Composer Quote menu - each item opens its calculator in 'reply' mode (Put in reply).
  const quoteMenuBtn = document.getElementById('openQuoteMenuBtn');
  const quoteMenu = document.getElementById('quoteMenuEl');
  const setQuoteMenuOpen = (open) => {
    quoteMenu.classList.toggle('hidden', !open);
    quoteMenuBtn.classList.toggle('active', open);
    quoteMenuBtn.setAttribute('aria-expanded', String(open));
  };
  quoteMenuBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    setQuoteMenuOpen(quoteMenu.classList.contains('hidden'));
  });
  document.addEventListener('click', (e) => {
    if (!quoteMenu.classList.contains('hidden') && !quoteMenu.contains(e.target)) setQuoteMenuOpen(false);
  });
  [
    ['openCalcQuoteBtn', () => openCalcEmbedModal('aquarium', 'reply')],
    ['openStandQuoteBtn', () => openCalcEmbedModal('stand', 'reply')],
    ['openStickerQuoteBtn', () => openCustomStickerModal('reply')],
    ['openRepairQuoteBtn', () => openCalcEmbedModal('repair', 'reply')]
  ].forEach(([id, open]) => document.getElementById(id).addEventListener('click', () => {
    setQuoteMenuOpen(false);
    open();
  }));
  document.getElementById('productLookupSearchInput').addEventListener('input', (e) => onProductLookupSearchInput(e.target.value));
  document.getElementById('sendProductListBtn').addEventListener('click', sendProductList);
  initMediaLibrary();
  document.getElementById('closeVariantPickerModalBtn').addEventListener('click', closeVariantPickerModal);
  document.getElementById('closeCustomStickerModalBtn').addEventListener('click', closeCustomStickerModal);
  document.getElementById('cancelCustomStickerBtn').addEventListener('click', closeCustomStickerModal);
  document.getElementById('customStickerType').addEventListener('change', () => {
    updateCustomStickerVisibility();
    autoCalculateCustomSticker();
  });
  ['customStickerThickness', 'customStickerUnit'].forEach((id) => {
    document.getElementById(id).addEventListener('change', autoCalculateCustomSticker);
  });
  document.getElementById('customStickerRepair').addEventListener('change', autoCalculateCustomSticker);
  ['customStickerLength', 'customStickerWidth', 'customStickerQty', 'customStickerColor'].forEach((id) => {
    document.getElementById(id).addEventListener('input', autoCalculateCustomSticker);
  });
  document.getElementById('calculateCustomStickerBtn').addEventListener('click', calculateCustomSticker);
  document.getElementById('addCustomStickerToSaleBtn').addEventListener('click', addCustomStickerToSale);
  document.getElementById('closeCalcEmbedBtn').addEventListener('click', closeCalcEmbedModal);
  document.getElementById('addCalcEmbedToOrderBtn').addEventListener('click', addCalcEmbedToOrder);
  document.getElementById('closeLineNoteModalBtn').addEventListener('click', closeLineNoteModal);
  document.getElementById('lineNoteModalCancelBtn').addEventListener('click', closeLineNoteModal);
  document.getElementById('lineNoteModalSaveBtn').addEventListener('click', saveLineNoteModal);
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
  const sendBtn = document.getElementById('sendReplyBtn');
  sendBtn.addEventListener('mousedown', (e) => e.preventDefault()); // keep the phone keyboard open
  sendBtn.addEventListener('click', sendReply);
  const composerExpandBtn = document.getElementById('composerExpandBtn');
  composerExpandBtn.addEventListener('mousedown', (e) => e.preventDefault()); // keep the phone keyboard open
  composerExpandBtn.addEventListener('click', () => {
    composerToolsExpanded = !composerToolsExpanded;
    autoResizeReplyInput();
  });
  updateComposerState(); // start folded on the phone
  const adviseBtn = document.getElementById('adviseReplyBtn');
  if (session.isSuperUser || session.isSalesUser) { // Test Human Agent: Super User + Sales User
    const testHumanAgentBtn = document.getElementById('testHumanAgentBtn');
    testHumanAgentBtn.classList.remove('hidden');
    testHumanAgentBtn.addEventListener('click', testHumanAgent);
  }
  if (session.isSuperUser) {
    adviseBtn.addEventListener('click', adviseReply);
  } else {
    // Advise reply is Super User only for now - everyone else sees it tagged as under maintenance.
    adviseBtn.disabled = true;
    adviseBtn.classList.add('is-maintenance');
    adviseBtn.title = 'Advise reply is under maintenance.';
    document.getElementById('adviseReplyLabel').textContent = 'Under maintenance';
  }
  document.getElementById('replyingToCloseBtn').addEventListener('click', clearReplyTo);
  document.getElementById('replyInput').addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && replyingTo) {
      clearReplyTo();
      return;
    }
    if (e.key === 'Enter' && !e.shiftKey && enterKeySends()) {
      e.preventDefault();
      sendReply();
    }
  });
  document.getElementById('replyInput').addEventListener('input', autoResizeReplyInput);

  setupThreadInteractions();
  setupAutoResumeSetting();
  setupRealtimeInbox();
  setupPullToRefresh();
  document.getElementById('conversationTagFilter').addEventListener('change', (e) => onConversationTagFilterChange(e.target.value));
  document.getElementById('conversationReadFilter').addEventListener('click', onConversationReadFilterClick);
  renderMoodFilter();
  document.getElementById('conversationMoodFilter').addEventListener('change', (e) => onConversationMoodFilterChange(e.target.value));
  loadTags();
  loadPostComments(); // pill counts
  loadInboxCalls();
  await loadConversations();
  await openConversationFromUrl();
})();

// gma-conversations.html?psid=...&name=... - the "View conversation" link on Online Orders (onlineOrders.js
// conversationLinkFor). Opens that customer's thread; if it isn't among the 100 latest, searches their
// name first. The params are then dropped so a reload starts on the plain list.
async function openConversationFromUrl() {
  const params = new URLSearchParams(location.search);
  const psid = params.get('psid');
  if (!psid) return;
  history.replaceState(history.state, '', location.pathname);
  const name = (params.get('name') || '').trim();
  if (!conversations.some((c) => c.psid === psid) && name) {
    conversationSearchTerm = name;
    document.getElementById('conversationSearchInput').value = name;
    await loadConversations();
  }
  if (conversations.some((c) => c.psid === psid)) await openConversation(psid);
}
