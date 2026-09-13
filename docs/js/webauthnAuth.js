// Face ID / fingerprint sign-in, scoped to a single device (e.g. the shop's shared phone).
// Requires: auth.js loaded first (uses attemptLogin/getPortalSession/setPortalSession).
//
// This does NOT add a second server-side auth path - Supabase never sees the biometric
// assertion. Instead, WebAuthn is used purely as a local unlock gate on this device: each
// enrolled employee's username/password (the same credentials verify_login() already checks
// on every RPC - see auth.js) are cached in this browser's localStorage, keyed off a
// platform-authenticator credential tied to their fingerprint/face. A successful biometric
// unlock reveals that cached password and feeds it through the normal attemptLogin() flow,
// so verify_login() still re-verifies it server-side exactly like a typed-password login.
// Credentials are stored in localStorage (not sessionStorage) so enrollment survives closing
// the browser/tab - the whole point is not re-typing a password on this device.
//
// Device authorization gate: per "I only want to use the single phone" / "I want a specific
// device to be able to do login, how can we distinct that sole device" - a website has no
// access to a real hardware id (browsers deliberately block IMEI/serial/MAC for privacy), so
// the only way to identify "this one shop phone" is a random id WE issue and store in its
// localStorage, registered server-side (see supabase_staff_time_clock.sql's
// StaffAuthorizedDevices table) by a Super User while physically holding that phone.
//
// This is enforced by the BACKEND, not just the browser: record_time_punch() re-checks the
// device id against StaffAuthorizedDevices on every single call. The checks in this file
// (isTimeClockDeviceAuthorized/enrollBiometricCredential's gate) are only there to show the
// right UI before someone tries - even if a client-side check were bypassed entirely, an
// unauthorized device's punches would still be rejected server-side.

const BIOMETRIC_CREDENTIALS_KEY = 'portal_biometric_credentials';
const DEVICE_ID_KEY = 'portal_device_id';

function getOrCreateDeviceId() {
  let id = localStorage.getItem(DEVICE_ID_KEY);
  if (!id) {
    id = crypto.randomUUID();
    localStorage.setItem(DEVICE_ID_KEY, id);
  }
  return id;
}

async function isTimeClockDeviceAuthorized() {
  const { data, error } = await supabaseClient.rpc('is_time_clock_device_authorized', {
    p_device_id: getOrCreateDeviceId()
  });
  return !error && data === true;
}

/**
 * Registers this device (identified by its locally-stored device id) as authorized for Time
 * In/Out, using the calling Super User's own already-verified session credentials - only
 * callable meaningfully by someone standing at the device, since there is no remote equivalent.
 */
async function authorizeTimeClockDevice(adminUsername, adminPassword, deviceLabel) {
  const { data, error } = await supabaseClient.rpc('authorize_time_clock_device', {
    p_admin_username: adminUsername,
    p_admin_password: adminPassword,
    p_device_id: getOrCreateDeviceId(),
    p_device_label: deviceLabel || null
  });
  if (error) return { success: false, message: error.message || 'Could not authorize this device.' };
  const result = Array.isArray(data) ? data[0] : data;
  return result || { success: false, message: 'Could not authorize this device.' };
}

/**
 * Revokes this device's authorization and wipes every employee's enrolled Face ID/fingerprint
 * credential on it - once a device is no longer "the shop phone", biometric sign-in previously
 * set up on it should stop working too.
 */
async function revokeTimeClockDevice(adminUsername, adminPassword) {
  const { data, error } = await supabaseClient.rpc('revoke_time_clock_device', {
    p_admin_username: adminUsername,
    p_admin_password: adminPassword,
    p_device_id: getOrCreateDeviceId()
  });
  if (error) return { success: false, message: error.message || 'Could not deauthorize this device.' };
  const result = Array.isArray(data) ? data[0] : data;
  if (result?.success) saveBiometricCredentials([]);
  return result || { success: false, message: 'Could not deauthorize this device.' };
}

function base64UrlEncode(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlDecode(value) {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(value.length / 4) * 4, '=');
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function getStoredBiometricCredentials() {
  try {
    const raw = localStorage.getItem(BIOMETRIC_CREDENTIALS_KEY);
    const list = raw ? JSON.parse(raw) : [];
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

function saveBiometricCredentials(list) {
  localStorage.setItem(BIOMETRIC_CREDENTIALS_KEY, JSON.stringify(list));
}

function getBiometricCredentialForUsername(username) {
  return getStoredBiometricCredentials().find((entry) => entry.username === username) || null;
}

async function isBiometricAvailable() {
  if (!window.PublicKeyCredential || !navigator.credentials) return false;
  try {
    return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
  } catch {
    return false;
  }
}

/**
 * Registers this device's fingerprint/Face ID for the given account, caching the
 * username/password locally so loginWithBiometric() can replay them through the normal
 * verify_login() RPC. Overwrites any prior enrollment for the same username on this device.
 */
async function enrollBiometricCredential(username, password, displayName) {
  if (!(await isTimeClockDeviceAuthorized())) {
    return { success: false, message: 'A manager needs to authorize this device for Face ID / fingerprint sign-in first.' };
  }
  if (!(await isBiometricAvailable())) {
    return { success: false, message: 'Face ID / fingerprint sign-in is not available on this device.' };
  }

  const existing = getStoredBiometricCredentials();
  const challenge = crypto.getRandomValues(new Uint8Array(32));

  let credential;
  try {
    credential = await navigator.credentials.create({
      publicKey: {
        challenge,
        rp: { name: 'RS Pet Stop Portal', id: window.location.hostname },
        user: {
          id: new TextEncoder().encode(username),
          name: username,
          displayName: displayName || username
        },
        pubKeyCredParams: [
          { type: 'public-key', alg: -7 },
          { type: 'public-key', alg: -257 }
        ],
        authenticatorSelection: {
          authenticatorAttachment: 'platform',
          userVerification: 'required',
          residentKey: 'preferred'
        },
        excludeCredentials: existing
          .filter((entry) => entry.username === username)
          .map((entry) => ({ id: base64UrlDecode(entry.credentialId), type: 'public-key' })),
        attestation: 'none',
        timeout: 60000
      }
    });
  } catch (err) {
    return { success: false, message: err.name === 'NotAllowedError' ? 'Face ID / fingerprint setup was cancelled.' : (err.message || 'Could not set up Face ID / fingerprint sign-in.') };
  }

  const credentialId = base64UrlEncode(credential.rawId);
  const withoutThisUser = existing.filter((entry) => entry.username !== username);
  withoutThisUser.push({ username, password, displayName: displayName || username, credentialId });
  saveBiometricCredentials(withoutThisUser);

  return { success: true };
}

function removeBiometricCredential(username) {
  saveBiometricCredentials(getStoredBiometricCredentials().filter((entry) => entry.username !== username));
}

/**
 * Keeps the locally-cached password in sync after a password change, so biometric sign-in
 * doesn't silently start failing verify_login() with a stale password.
 */
function updateBiometricPassword(username, newPassword) {
  const list = getStoredBiometricCredentials();
  const entry = list.find((item) => item.username === username);
  if (!entry) return;
  entry.password = newPassword;
  saveBiometricCredentials(list);
}

/**
 * Prompts the device's Face ID / fingerprint sensor and resolves which enrolled account (if
 * any) it matched, without doing anything else - shared by loginWithBiometric() (full portal
 * sign-in) and punchTimeClock() (a Time In/Out attendance punch), which each do something
 * different with the identified account.
 */
async function identifyBiometricAccount() {
  const enrolled = getStoredBiometricCredentials();
  if (enrolled.length === 0) {
    return { success: false, message: 'Face ID / fingerprint sign-in has not been set up on this device yet.' };
  }
  if (!(await isBiometricAvailable())) {
    return { success: false, message: 'Face ID / fingerprint sign-in is not available on this device.' };
  }

  const challenge = crypto.getRandomValues(new Uint8Array(32));

  let assertion;
  try {
    assertion = await navigator.credentials.get({
      publicKey: {
        challenge,
        allowCredentials: enrolled.map((entry) => ({ id: base64UrlDecode(entry.credentialId), type: 'public-key' })),
        userVerification: 'required',
        timeout: 60000
      }
    });
  } catch (err) {
    return { success: false, message: err.name === 'NotAllowedError' ? 'Face ID / fingerprint sign-in was cancelled.' : (err.message || 'Face ID / fingerprint sign-in failed.') };
  }

  const matchedCredentialId = base64UrlEncode(assertion.rawId);
  const entry = enrolled.find((item) => item.credentialId === matchedCredentialId);
  if (!entry) {
    return { success: false, message: 'This Face ID / fingerprint is not linked to an account on this device.' };
  }

  return { success: true, entry };
}

/**
 * Prompts the device's Face ID / fingerprint sensor, then replays the matched account's
 * cached username/password through the exact same attemptLogin() used by the password form.
 */
async function loginWithBiometric() {
  const identified = await identifyBiometricAccount();
  if (!identified.success) return identified;

  const result = await attemptLogin(identified.entry.username, identified.entry.password);
  if (!result.success) {
    // Most likely cause: the password was changed elsewhere (e.g. by an admin) since this
    // device's biometric sign-in was set up - fall back to the password form.
    return { success: false, message: 'Saved sign-in details are out of date. Please sign in with your password.' };
  }
  return result;
}

/**
 * Prompts Face ID / fingerprint, identifies the employee from the credential matched on this
 * device, and records a Time In/Out attendance punch (see supabase_staff_time_clock.sql) -
 * independent of whether that employee is currently logged into the portal on this device.
 */
async function punchTimeClock(punchType) {
  const identified = await identifyBiometricAccount();
  if (!identified.success) return identified;

  const { data, error } = await supabaseClient.rpc('record_time_punch', {
    p_username: identified.entry.username,
    p_password: identified.entry.password,
    p_punch_type: punchType,
    p_device_id: getOrCreateDeviceId()
  });

  if (error) {
    return { success: false, message: error.message || 'Could not record the time punch.' };
  }

  const result = Array.isArray(data) ? data[0] : data;
  if (!result || !result.success) {
    return { success: false, message: result?.message || 'Could not record the time punch.' };
  }

  return {
    success: true,
    message: result.message,
    username: identified.entry.username,
    displayName: identified.entry.displayName,
    punchAtUtc: result.punch_at_utc
  };
}
