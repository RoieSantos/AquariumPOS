import { createClient } from '@supabase/supabase-js';
import { registerPlugin } from '@capacitor/core';
import { LocalNotifications } from '@capacitor/local-notifications';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

// @capacitor-community/background-geolocation ships no JS bundle of its own (just native
// Android/iOS code + type definitions) - this is the plugin's own documented way to get a JS
// handle to it, via Capacitor's registerPlugin, not a default export.
const BackgroundGeolocation = registerPlugin('BackgroundGeolocation');

const supabaseClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Same credential-replay session model as the web portal's js/auth.js - there's no JWT/Supabase
// Auth in this project (see supabase_staff_users_table.sql), every RPC call re-sends
// username/password and is re-verified server-side. Persisted in localStorage (not
// sessionStorage) so the app stays logged in across app restarts, since a driver shouldn't have
// to log back in every time they reopen the app mid-shift.
const SESSION_KEY = 'driver_session';

let watcherId = null;

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

// NOTE: addWatcher/removeWatcher is the @capacitor-community/background-geolocation API as of
// v1.2.x - re-check this against whatever version `npm install` actually resolves (see
// SETUP.md), since plugin APIs can change between majors.
//
// Called automatically (never from a button - see wireUpTrackingScreen/init below) whenever the
// app opens with a saved session: on a normal reopen, after BootReceiver.java relaunches the app
// following a phone restart, or right after a fresh login. Guarded against double-starting since
// more than one of those can plausibly fire close together.
async function startTracking() {
  const session = getSession();
  if (!session || watcherId) return;

  setStatus('Starting...');

  // Android 13+ requires the POST_NOTIFICATIONS runtime permission before the plugin's
  // persistent "tracking active" notification can show - without it, background location
  // updates stop working, not just the notification. Harmless to call on older Android/iOS.
  try {
    await LocalNotifications.requestPermissions();
  } catch {
    // ignore - addWatcher below will still surface a clearer error if location itself is blocked
  }

  watcherId = await BackgroundGeolocation.addWatcher(
    {
      backgroundTitle: 'RS Pet Stop Driver',
      backgroundMessage: "Sharing your location for today's deliveries.",
      requestPermissions: true,
      stale: false,
      distanceFilter: 30 // meters - also fires periodically even when stationary
    },
    async (location, error) => {
      if (error) {
        if (error.code === 'NOT_AUTHORIZED') {
          setStatus('Location permission denied. Enable it for this app in phone Settings, then reopen the app.');
        } else {
          setStatus(`Location error: ${error.message}`);
        }
        return;
      }

      const { error: rpcError } = await supabaseClient.rpc('driver_update_location', {
        p_username: session.username,
        p_password: session.password,
        p_latitude: location.latitude,
        p_longitude: location.longitude,
        p_recorded_at_utc: new Date(location.time).toISOString()
      });

      setStatus(rpcError ? `Tracking (last update failed: ${rpcError.message})` : `Tracking - last update ${new Date().toLocaleTimeString()}`);
    }
  );
}

// Only reachable via "Log Out" now - there's no separate "pause tracking but stay logged in"
// state, since the whole point of auto-starting is that the driver never has to think about it.
// Logging out is the one deliberate way to turn it off.
async function stopTracking() {
  const session = getSession();

  if (watcherId) {
    await BackgroundGeolocation.removeWatcher({ id: watcherId });
    watcherId = null;
  }

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

// Runs every time the app's WebView starts fresh - a normal open, a resume after Android killed
// the process and recreated it, or BootReceiver.java relaunching the app after a phone restart.
// Tracking auto-starts here whenever a session is already saved - no button, no daily reminder
// needed from the driver. A fresh login (see wireUpLoginScreen above) starts it directly instead,
// since no session exists yet at the time this runs.
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
