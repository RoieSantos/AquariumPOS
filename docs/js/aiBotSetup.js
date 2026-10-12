// AI Bot Setup page logic (super users only). Three separate things live here:
//   - Bot Identity & Behavior (public.ChatbotAiSettings, see supabase_chatbot_ai_settings_table.sql)
//     - name/tone/greeting/custom directions/AI model, the persona + model knobs. Read directly by
//     supabase/functions/facebook-messenger-webhook's buildSystemPrompt on every customer message.
//   - Store Info / FAQ (public.ChatbotStoreInfo, see supabase_chatbot_store_info_table.sql) -
//     hours/delivery/payment/pickup, recited to customers as-is. Also read by buildSystemPrompt.
//   - Follow-Ups (public.ChatbotFollowUpSettings, see supabase_chatbot_followup_settings.sql) -
//     on/off + delay per follow-up type, and tone directions for composing them. Read by
//     supabase/functions/chatbot-followup-dispatcher (the pg_cron-triggered function that actually
//     detects and sends follow-ups - see supabase_chatbot_followups.sql) and by the webhook's
//     schedule_follow_up tool.
//   - Facebook Posts (public.FacebookPostSettings, see supabase_facebook_post_settings.sql) -
//     standing AI caption directions + default watermark for facebook-post-test.html.
// Same trust model as General Setup: super user status alone is enough, reusing session.password
// captured at login (see auth.js) for the is_admin_authorized-gated RPCs below.
let currentSession = null;

async function loadAiSettings() {
  const { data, error } = await supabaseClient
    .from('ChatbotAiSettings')
    .select('*')
    .eq('"Id"', 1)
    .limit(1);

  const info = !error && data && data[0];
  document.getElementById('botNameInput').value = (info && info['BotName']) || '';
  document.getElementById('aiModelInput').value = (info && info['AiModel']) || 'claude-sonnet-5';
  document.getElementById('communicationStyleInput').value = (info && info['CommunicationStyle']) || '';
  document.getElementById('greetingMessageInput').value = (info && info['GreetingMessage']) || '';
  document.getElementById('customDirectionsInput').value = (info && info['CustomDirections']) || '';
  document.getElementById('defaultLocationInput').value = (info && info['DefaultLocation']) || 'GMA';
  document.getElementById('commentAutoReplyEnabledInput').checked = !info || info['CommentAutoReplyEnabled'] !== false;
  renderBotSchedule(info);
}

// Messenger bot schedule hours (ChatbotAiSettings.BotScheduleEnabled / BotSchedule, see
// supabase_chatbot_bot_schedule.sql). Days are index 0 = Sunday, matching
// supabase/functions/_shared/bot-schedule.ts, which the webhook and follow-up dispatcher use.
const BOT_SCHEDULE_DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

function renderBotSchedule(info) {
  const schedule = Array.isArray(info && info['BotSchedule']) && info['BotSchedule'].length === 7
    ? info['BotSchedule']
    : BOT_SCHEDULE_DAYS.map(() => ({ on: true, start: '20:00', end: '08:00' }));
  document.getElementById('botScheduleEnabledInput').checked = !!(info && info['BotScheduleEnabled']);

  const container = document.getElementById('botScheduleDays');
  container.innerHTML = '';
  BOT_SCHEDULE_DAYS.forEach((name, i) => {
    const day = schedule[i] || {};
    const label = document.createElement('label');
    label.style.cssText = 'display:flex; align-items:center; gap:6px; margin:0;';
    label.innerHTML = `<input type="checkbox" data-day-on="${i}" style="width:auto;" /> <span>${name}</span>`;
    label.querySelector('input').checked = day.on !== false;

    const start = document.createElement('input');
    start.type = 'time';
    start.dataset.dayStart = i;
    start.value = day.start || '20:00';

    const end = document.createElement('input');
    end.type = 'time';
    end.dataset.dayEnd = i;
    end.value = day.end || '08:00';

    container.append(label, start, end);
  });
  updateBotScheduleNow();
}

function readBotSchedule() {
  return BOT_SCHEDULE_DAYS.map((_, i) => ({
    on: document.querySelector(`[data-day-on="${i}"]`).checked,
    start: document.querySelector(`[data-day-start="${i}"]`).value,
    end: document.querySelector(`[data-day-end="${i}"]`).value
  }));
}

// Same rules as _shared/bot-schedule.ts, so the "right now" line matches what the bot will do.
function isWithinSchedule(enabled, schedule, now = new Date()) {
  if (!enabled) return true;
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Manila', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  const get = (type) => (parts.find((p) => p.type === type) || {}).value || '';
  const day = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(get('weekday'));
  const minute = Number(get('hour')) * 60 + Number(get('minute'));
  const toMin = (s) => (/^\d{2}:\d{2}$/.test(s || '') ? Number(s.slice(0, 2)) * 60 + Number(s.slice(3)) : null);
  const today = schedule[day];
  const yesterday = schedule[(day + 6) % 7];
  const ts = toMin(today.start), te = toMin(today.end);
  if (today.on && ts !== null && te !== null && (te > ts ? minute >= ts && minute < te : minute >= ts)) return true;
  const ys = toMin(yesterday.start), ye = toMin(yesterday.end);
  return !!(yesterday.on && ys !== null && ye !== null && ye <= ys && minute < ye);
}

function updateBotScheduleNow() {
  const on = isWithinSchedule(document.getElementById('botScheduleEnabledInput').checked, readBotSchedule());
  document.getElementById('botScheduleNow').textContent = on
    ? 'With these settings, the bot is answering right now.'
    : 'With these settings, the bot is OFF right now - staff answer from Conversations.';
}

async function saveBotSchedule() {
  const errorEl = document.getElementById('botScheduleError');
  const savedEl = document.getElementById('botScheduleSaved');
  const saveBtn = document.getElementById('saveBotScheduleBtn');
  errorEl.classList.add('hidden');
  savedEl.classList.add('hidden');

  const schedule = readBotSchedule();
  const missing = schedule.findIndex((d) => d.on && (!d.start || !d.end));
  if (missing >= 0) {
    errorEl.textContent = `${BOT_SCHEDULE_DAYS[missing]} needs a start and end time.`;
    errorEl.classList.remove('hidden');
    return;
  }

  saveBtn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('admin_set_chatbot_bot_schedule', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_enabled: document.getElementById('botScheduleEnabledInput').checked,
      p_schedule: schedule
    });
    if (error) {
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
      return;
    }
    savedEl.classList.remove('hidden');
  } finally {
    saveBtn.disabled = false;
  }
}

// Facebook post comment auto-reply on/off (ChatbotAiSettings.CommentAutoReplyEnabled, see
// supabase_facebook_comment_auto_reply.sql) - saved immediately on toggle, separate from Save Bot Settings.
async function saveCommentAutoReply() {
  const input = document.getElementById('commentAutoReplyEnabledInput');
  const errorEl = document.getElementById('commentAutoReplyError');
  errorEl.classList.add('hidden');
  input.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('admin_set_chatbot_comment_auto_reply', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_enabled: input.checked
    });
    if (error) {
      input.checked = !input.checked;
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
    }
  } finally {
    input.disabled = false;
  }
}

async function saveAiSettings() {
  const errorEl = document.getElementById('aiSettingsError');
  const saveBtn = document.getElementById('saveAiSettingsBtn');
  errorEl.classList.add('hidden');

  saveBtn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('admin_upsert_chatbot_ai_settings', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_bot_name: document.getElementById('botNameInput').value.trim() || null,
      p_communication_style: document.getElementById('communicationStyleInput').value.trim() || null,
      p_greeting_message: document.getElementById('greetingMessageInput').value.trim() || null,
      p_custom_directions: document.getElementById('customDirectionsInput').value.trim() || null,
      p_ai_model: document.getElementById('aiModelInput').value || null,
      p_default_location: document.getElementById('defaultLocationInput').value || null
    });

    if (error) {
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
      return;
    }

    await loadAiSettings();
  } finally {
    saveBtn.disabled = false;
  }
}

async function loadStoreInfo() {
  const { data, error } = await supabaseClient
    .from('ChatbotStoreInfo')
    .select('*')
    .eq('"Id"', 1)
    .limit(1);

  const info = !error && data && data[0];
  document.getElementById('businessHoursInput').value = (info && info['BusinessHours']) || '';
  document.getElementById('deliveryPolicyInput').value = (info && info['DeliveryPolicy']) || '';
  document.getElementById('paymentMethodsInput').value = (info && info['PaymentMethods']) || '';
  document.getElementById('pickupLocationsInput').value = (info && info['PickupLocations']) || '';
  document.getElementById('additionalNotesInput').value = (info && info['AdditionalNotes']) || '';
}

async function saveStoreInfo() {
  const errorEl = document.getElementById('storeInfoError');
  const saveBtn = document.getElementById('saveStoreInfoBtn');
  errorEl.classList.add('hidden');

  saveBtn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('admin_upsert_chatbot_store_info', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_business_hours: document.getElementById('businessHoursInput').value.trim() || null,
      p_delivery_policy: document.getElementById('deliveryPolicyInput').value.trim() || null,
      p_payment_methods: document.getElementById('paymentMethodsInput').value.trim() || null,
      p_pickup_locations: document.getElementById('pickupLocationsInput').value.trim() || null,
      p_additional_notes: document.getElementById('additionalNotesInput').value.trim() || null
    });

    if (error) {
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
      return;
    }

    await loadStoreInfo();
  } finally {
    saveBtn.disabled = false;
  }
}

async function loadFollowUpSettings() {
  const { data, error } = await supabaseClient
    .from('ChatbotFollowUpSettings')
    .select('*')
    .eq('"Id"', 1)
    .limit(1);

  const info = !error && data && data[0];
  document.getElementById('followUpAbandonedEnabledInput').checked = Boolean(info && info['AbandonedEnabled']);
  document.getElementById('followUpAbandonedDelayInput').value = (info && info['AbandonedDelayMinutes']) || 180;
  document.getElementById('followUpEscalationEnabledInput').checked = Boolean(info && info['EscalationEnabled']);
  document.getElementById('followUpEscalationDelayInput').value = (info && info['EscalationDelayMinutes']) || 1440;
  document.getElementById('followUpPendingOrderEnabledInput').checked = Boolean(info && info['PendingOrderEnabled']);
  document.getElementById('followUpPendingOrderDelayInput').value = (info && info['PendingOrderDelayMinutes']) || 720;
  document.getElementById('followUpCommittedEnabledInput').checked = info ? Boolean(info['CommittedEnabled']) : true;
  document.getElementById('followUpDirectionsInput').value = (info && info['FollowUpDirections']) || '';
}

async function saveFollowUpSettings() {
  const errorEl = document.getElementById('followUpSettingsError');
  const saveBtn = document.getElementById('saveFollowUpSettingsBtn');
  errorEl.classList.add('hidden');

  saveBtn.disabled = true;
  try {
    const { error } = await supabaseClient.rpc('admin_upsert_chatbot_followup_settings', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_abandoned_enabled: document.getElementById('followUpAbandonedEnabledInput').checked,
      p_abandoned_delay_minutes: parseInt(document.getElementById('followUpAbandonedDelayInput').value, 10) || 180,
      p_escalation_enabled: document.getElementById('followUpEscalationEnabledInput').checked,
      p_escalation_delay_minutes: parseInt(document.getElementById('followUpEscalationDelayInput').value, 10) || 1440,
      p_pending_order_enabled: document.getElementById('followUpPendingOrderEnabledInput').checked,
      p_pending_order_delay_minutes: parseInt(document.getElementById('followUpPendingOrderDelayInput').value, 10) || 720,
      p_committed_enabled: document.getElementById('followUpCommittedEnabledInput').checked,
      p_follow_up_directions: document.getElementById('followUpDirectionsInput').value.trim() || null
    });

    if (error) {
      errorEl.textContent = error.message;
      errorEl.classList.remove('hidden');
      return;
    }

    await loadFollowUpSettings();
  } finally {
    saveBtn.disabled = false;
  }
}

// Facebook Posts section - shared load/save in js/facebookPostSettings.js.
async function loadFbPostSettings() {
  const s = await loadFacebookPostSettings();
  document.getElementById('fbCaptionDirectionsInput').value = s.captionDirections;
  document.getElementById('fbWatermarkEnabledInput').checked = s.watermarkEnabled;
  document.getElementById('fbWatermarkStyleInput').value = s.watermarkStyle;
  document.getElementById('fbWatermarkSizeInput').value = s.watermarkSize;
  document.getElementById('fbWatermarkOpacityInput').value = s.watermarkOpacity;
  document.getElementById('fbWatermarkPositionInput').value = s.watermarkPosition;
  document.getElementById('fbWatermarkTextInput').value = s.watermarkText;
  document.getElementById('fbWatermarkKnockoutInput').checked = s.watermarkKnockout;
}

async function saveFbPostSettings() {
  const errorEl = document.getElementById('fbPostSettingsError');
  const saveBtn = document.getElementById('saveFbPostSettingsBtn');
  errorEl.classList.add('hidden');

  saveBtn.disabled = true;
  try {
    const message = await saveFacebookPostSettings(currentSession, {
      captionDirections: document.getElementById('fbCaptionDirectionsInput').value.trim(),
      watermarkEnabled: document.getElementById('fbWatermarkEnabledInput').checked,
      watermarkStyle: document.getElementById('fbWatermarkStyleInput').value,
      watermarkSize: document.getElementById('fbWatermarkSizeInput').value,
      watermarkOpacity: document.getElementById('fbWatermarkOpacityInput').value,
      watermarkPosition: document.getElementById('fbWatermarkPositionInput').value,
      watermarkText: document.getElementById('fbWatermarkTextInput').value.trim(),
      watermarkKnockout: document.getElementById('fbWatermarkKnockoutInput').checked
    });

    if (message) {
      errorEl.textContent = message;
      errorEl.classList.remove('hidden');
      return;
    }

    await loadFbPostSettings();
  } finally {
    saveBtn.disabled = false;
  }
}

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

const CAPABILITY_GAP_STATUSES = ['new', 'planned', 'done', 'wontfix'];

async function loadCapabilityGaps() {
  const tbody = document.getElementById('capabilityGapsTableBody');
  const errorEl = document.getElementById('capabilityGapsError');
  errorEl.classList.add('hidden');
  tbody.innerHTML = '<tr><td colspan="4" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_bot_capability_gaps', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    tbody.innerHTML = '';
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" class="muted">Nothing logged yet - this fills up whenever Alice is honest that she can\'t help with something.</td></tr>';
    return;
  }

  tbody.innerHTML = rows.map((row) => {
    const date = row.CreatedAtUtc ? new Date(row.CreatedAtUtc).toLocaleString() : '-';
    const options = CAPABILITY_GAP_STATUSES
      .map((s) => `<option value="${s}"${s === row.Status ? ' selected' : ''}>${s}</option>`)
      .join('');
    return `
      <tr>
        <td>${escapeHtml(date)}</td>
        <td>${escapeHtml(row.Channel)}</td>
        <td>${escapeHtml(row.Question)}</td>
        <td><select data-gap-id="${row.Id}" class="capability-gap-status">${options}</select></td>
      </tr>
    `;
  }).join('');

  tbody.querySelectorAll('.capability-gap-status').forEach((select) => {
    select.addEventListener('change', () => updateCapabilityGapStatus(select.dataset.gapId, select.value));
  });
}

async function updateCapabilityGapStatus(id, status) {
  const errorEl = document.getElementById('capabilityGapsError');
  errorEl.classList.add('hidden');

  const { error } = await supabaseClient.rpc('admin_update_bot_capability_gap_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_id: Number(id),
    p_status: status
  });

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
  }
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('AI Bot Setup');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view AI Bot Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  document.getElementById('saveAiSettingsBtn').addEventListener('click', saveAiSettings);
  document.getElementById('commentAutoReplyEnabledInput').addEventListener('change', saveCommentAutoReply);
  document.getElementById('saveBotScheduleBtn').addEventListener('click', saveBotSchedule);
  document.getElementById('botScheduleEnabledInput').addEventListener('change', updateBotScheduleNow);
  document.getElementById('botScheduleDays').addEventListener('input', updateBotScheduleNow);
  document.getElementById('botScheduleDays').addEventListener('change', updateBotScheduleNow);
  document.getElementById('saveStoreInfoBtn').addEventListener('click', saveStoreInfo);
  document.getElementById('saveFollowUpSettingsBtn').addEventListener('click', saveFollowUpSettings);
  document.getElementById('saveFbPostSettingsBtn').addEventListener('click', saveFbPostSettings);
  document.getElementById('refreshCapabilityGapsBtn').addEventListener('click', loadCapabilityGaps);

  await loadAiSettings();
  await loadStoreInfo();
  await loadFollowUpSettings();
  await loadFbPostSettings();
  await loadCapabilityGaps();
})();
