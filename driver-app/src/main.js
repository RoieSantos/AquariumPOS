import { createClient } from '@supabase/supabase-js';
import { registerPlugin } from '@capacitor/core';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

// Custom native plugin (android/app/src/main/java/com/rspetstop/driverapp/DriverTrackingPlugin.java)
// backed by DriverTrackingService, a standalone Android foreground service that owns GPS watching
// and HTTP reporting to Supabase entirely on its own - independent of this WebView/JS being alive.
// That's deliberate: this app replaced @capacitor-community/background-geolocation specifically
// because its JS-bridge architecture stopped tracking the instant the app was swiped away from
// Recents (see the plan doc / that plugin's own issue #59 for why). Once startTracking() below
// resolves, the actual location loop is out of JS's hands - nothing else in this file drives it.
const DriverTracking = registerPlugin('DriverTracking');

const supabaseClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Same credential-replay session model as the web portal's js/auth.js - there's no JWT/Supabase
// Auth in this project (see supabase_staff_users_table.sql), every RPC call re-sends
// username/password and is re-verified server-side. Persisted in localStorage (not
// sessionStorage) so the app stays logged in across app restarts, since a driver shouldn't have
// to log back in every time they reopen the app mid-shift. DriverTrackingPlugin.startTracking
// separately saves the same credentials into native SharedPreferences, since DriverTrackingService
// needs to read them without any WebView/JS involved at all - the two copies are written together
// but read independently.
const SESSION_KEY = 'driver_session';

let trackingStarted = false; // guards against double-starting; actual tracking state lives in the
// native service now, not here - see DriverTracking.isTracking() if a real status readout is ever
// needed instead of this local guard flag.

function getSession() {
  try {
    return JSON.parse(localStorage.getItem(SESSION_KEY) || 'null');
  } catch {
    return null;
  }
}

function setSession(session) {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session));
}

function clearSession() {
  localStorage.removeItem(SESSION_KEY);
}

function showScreen(screenId) {
  document.querySelectorAll('.screen').forEach((el) => el.classList.add('hidden'));
  document.getElementById(screenId).classList.remove('hidden');
}

function setStatus(text) {
  document.getElementById('statusText').textContent = text;
}

async function login(username, password) {
  const { data, error } = await supabaseClient.rpc('verify_login', { p_username: username, p_password: password });
  const result = Array.isArray(data) ? data[0] : data;

  if (error || !result || !result.success) {
    throw new Error(result?.message || error?.message || 'Login failed.');
  }

  // driver_update_location (see supabase_driver_locations_table.sql) itself rejects anyone
  // without DeliveryTeam - this check just gives a clearer error before even trying to track.
  if (!result.is_delivery_team && !result.is_super_user) {
    throw new Error('This account is not set up as a delivery driver. Ask a super user to enable Delivery Team on your account.');
  }

  setSession({ username, password, displayName: result.display_name || username });
}

// Called automatically (never from a button - see wireUpTrackingScreen/init below) whenever the
// app opens with a saved session: a normal reopen, or right after a fresh login. Guarded against
// double-starting since more than one of those can plausibly fire close together. Once this
// resolves, DriverTrackingService keeps running on its own even if the app is swiped away -
// there's no ongoing per-location JS callback anymore, so there's no live "last update" status to
// show here beyond a static confirmation.
async function startTracking() {
  const session = getSession();
  if (!session || trackingStarted) return;
  trackingStarted = true;

  setStatus('Starting...');

  try {
    await DriverTracking.startTracking({ username: session.username, password: session.password });
    setStatus('Tracking active - keeps running even if you switch apps, lock the screen, or swipe this app away.');
  } catch (err) {
    trackingStarted = false;
    if (err?.code === 'NOT_AUTHORIZED') {
      setStatus('Location permission denied. Enable it for this app in phone Settings, then reopen the app.');
    } else {
      setStatus(`Could not start tracking: ${err.message}`);
    }
  }
}

// Only reachable via "Log Out" now - there's no separate "pause tracking but stay logged in"
// state, since the whole point of auto-starting is that the driver never has to think about it.
// Logging out is the one deliberate way to turn it off.
async function stopTracking() {
  const session = getSession();

  await DriverTracking.stopTracking();
  trackingStarted = false;
  setStatus('Stopped.');

  if (session) {
    await supabaseClient.rpc('driver_stop_tracking', { p_username: session.username, p_password: session.password });
  }
}

function wireUpTrackingScreen(session) {
  document.getElementById('driverName').textContent = session.displayName;
  document.getElementById('logoutBtn').addEventListener('click', async () => {
    await stopTracking();
    clearSession();
    showScreen('loginScreen');
  });
}

function wireUpLoginScreen() {
  document.getElementById('loginForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const username = document.getElementById('usernameInput').value.trim();
    const password = document.getElementById('passwordInput').value;
    const errorEl = document.getElementById('loginError');
    errorEl.classList.add('hidden');

    try {
      await login(username, password);
      wireUpTrackingScreen(getSession());
      showScreen('trackingScreen');
      await startTracking();
    } catch (err) {
      errorEl.textContent = err.message;
      errorEl.classList.remove('hidden');
    }
  });
}

// Runs every time the app's WebView starts fresh - a normal open, or a resume after Android killed
// the process and recreated it. Tracking auto-starts here whenever a session is already saved - no
// button, no daily reminder needed from the driver. A fresh login (see wireUpLoginScreen above)
// starts it directly instead, since no session exists yet at the time this runs. Note: after a
// phone restart, BootReceiver.java now starts DriverTrackingService directly without opening this
// UI at all - this init() only runs if/when the driver (or the OS) actually opens the app.
(function init() {
  wireUpLoginScreen();

  const session = getSession();
  if (session) {
    wireUpTrackingScreen(session);
    showScreen('trackingScreen');
    startTracking();
  } else {
    showScreen('loginScreen');
  }
})();
