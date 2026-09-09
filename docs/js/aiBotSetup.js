// AI Bot Setup page logic (super users only). Two separate things live here, both read directly by
// supabase/functions/facebook-messenger-webhook's buildSystemPrompt on every customer message:
//   - Bot Identity & Behavior (public.ChatbotAiSettings, see supabase_chatbot_ai_settings_table.sql)
//     - name/tone/greeting/custom directions, the persona knobs.
//   - Store Info / FAQ (public.ChatbotStoreInfo, see supabase_chatbot_store_info_table.sql) -
//     hours/delivery/payment/pickup, recited to customers as-is.
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
  document.getElementById('communicationStyleInput').value = (info && info['CommunicationStyle']) || '';
  document.getElementById('greetingMessageInput').value = (info && info['GreetingMessage']) || '';
  document.getElementById('customDirectionsInput').value = (info && info['CustomDirections']) || '';
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
      p_custom_directions: document.getElementById('customDirectionsInput').value.trim() || null
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
  document.getElementById('saveStoreInfoBtn').addEventListener('click', saveStoreInfo);

  await loadAiSettings();
  await loadStoreInfo();
})();
