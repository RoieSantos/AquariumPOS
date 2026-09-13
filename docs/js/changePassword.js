// Change Password page logic. Reached two ways:
//   1. Forced - requireAuth() (js/auth.js) redirects here automatically whenever
//      session.mustChangePassword is true (StaffUsers."MustChangePassword", set in User Setup -
//      see supabase_staff_users_table.sql), and keeps redirecting back here from every other
//      page until the password is actually changed.
//   2. Voluntary - this page is in requireAuth()'s exempt list (so it never redirects AWAY from
//      itself), which means any logged-in staff member can also reach it directly to change
//      their password even when it wasn't required.
// Requires the CURRENT password (re-verified server-side in change_own_password), not just
// super-user trust - this is self-service, not an admin action.
(async function init() {
  const session = await requireAuth();
  if (!session) return;
  renderTopNav('Change Password');

  if (!session.mustChangePassword) {
    document.getElementById('changePasswordIntro').textContent = 'Update your password below.';
  }

  document.getElementById('changePasswordLogoutLink').addEventListener('click', (event) => {
    event.preventDefault();
    logout();
  });

  await initBiometricSection(session);

  document.getElementById('changePasswordForm').addEventListener('submit', async (event) => {
    event.preventDefault();

    const errorEl = document.getElementById('changePasswordError');
    const successEl = document.getElementById('changePasswordSuccess');
    errorEl.classList.add('hidden');
    successEl.classList.add('hidden');

    const currentPassword = document.getElementById('currentPassword').value;
    const newPassword = document.getElementById('newPassword').value;
    const confirmNewPassword = document.getElementById('confirmNewPassword').value;

    if (newPassword.length < 6) {
      errorEl.textContent = 'New password must be at least 6 characters.';
      errorEl.classList.remove('hidden');
      return;
    }
    if (newPassword !== confirmNewPassword) {
      errorEl.textContent = 'New password and confirmation do not match.';
      errorEl.classList.remove('hidden');
      return;
    }

    const submitBtn = event.target.querySelector('button[type="submit"]');
    submitBtn.disabled = true;
    submitBtn.textContent = 'Changing...';

    const { data, error } = await supabaseClient.rpc('change_own_password', {
      p_username: session.username,
      p_current_password: currentPassword,
      p_new_password: newPassword
    });

    submitBtn.disabled = false;
    submitBtn.textContent = 'Change Password';

    const result = Array.isArray(data) ? data[0] : data;
    if (error || !result || !result.success) {
      errorEl.textContent = error?.message || result?.message || 'Failed to change password.';
      errorEl.classList.remove('hidden');
      return;
    }

    // The session's cached password/mustChangePassword flag must be updated in lockstep with
    // what the database now has - every other page's RPC calls re-send session.password, so a
    // stale cached password here would lock the user out on their very next click.
    setPortalSession({ ...session, password: newPassword, mustChangePassword: false });

    // Keep this device's Face ID / fingerprint sign-in (if enabled) working with the new
    // password instead of silently starting to fail on the stale one.
    updateBiometricPassword(session.username, newPassword);

    successEl.textContent = 'Password changed. Redirecting...';
    successEl.classList.remove('hidden');
    setTimeout(() => { window.location.href = 'dashboard.html'; }, 800);
  });
})();

/**
 * Shows this device's current Face ID / fingerprint enrollment status for the logged-in
 * account and lets them turn it on/off. Hidden entirely on devices without a platform
 * authenticator (e.g. a desktop browser with no fingerprint reader/webcam biometric).
 *
 * Gated on device authorization, checked against the BACKEND (StaffAuthorizedDevices - see
 * supabase_staff_time_clock.sql), not just a client-side flag - per "how can we distinct that
 * sole device / how can I know the device is authorized in the backend". An ordinary employee
 * can never authorize a device for themselves; only a Super User can, and only while physically
 * holding it (there is no remote/admin-panel equivalent). Once authorized, any employee logged
 * in on that device can enable their own Face ID/fingerprint there.
 */
async function initBiometricSection(session) {
  const card = document.getElementById('biometricCard');
  if (!(await isBiometricAvailable())) return;
  card.classList.remove('hidden');

  const statusEl = document.getElementById('biometricStatus');
  const toggleBtn = document.getElementById('biometricToggleBtn');
  const errorEl = document.getElementById('biometricError');
  const deauthorizeWrap = document.getElementById('biometricDeauthorizeWrap');
  const deauthorizeLink = document.getElementById('biometricDeauthorizeLink');

  let deviceAuthorized = false;

  function render() {
    if (!deviceAuthorized) {
      deauthorizeWrap.classList.add('hidden');
      if (session.isSuperUser) {
        statusEl.textContent = 'This device is not authorized for Face ID / fingerprint sign-in yet.';
        toggleBtn.textContent = 'Authorize This Device';
        toggleBtn.classList.remove('hidden');
      } else {
        statusEl.textContent = 'Face ID / fingerprint sign-in is not set up on this device. Ask a manager to authorize it here first.';
        toggleBtn.classList.add('hidden');
      }
      return;
    }

    const enrolled = !!getBiometricCredentialForUsername(session.username);
    statusEl.textContent = enrolled
      ? 'Face ID / fingerprint sign-in is enabled for your account on this device.'
      : 'Sign in faster next time using Face ID or your fingerprint on this device.';
    toggleBtn.textContent = enrolled ? 'Turn Off' : 'Enable';
    toggleBtn.classList.remove('hidden');
    deauthorizeWrap.classList.toggle('hidden', !session.isSuperUser);
  }

  async function refresh() {
    deviceAuthorized = await isTimeClockDeviceAuthorized();
    render();
  }
  await refresh();

  toggleBtn.addEventListener('click', async () => {
    errorEl.classList.add('hidden');

    if (!deviceAuthorized) {
      const label = window.prompt('Label this device (e.g. "Front Counter Phone") - optional:', '') || null;
      toggleBtn.disabled = true;
      toggleBtn.textContent = 'Authorizing...';
      const result = await authorizeTimeClockDevice(session.username, session.password, label);
      toggleBtn.disabled = false;
      if (!result.success) {
        errorEl.textContent = result.message;
        errorEl.classList.remove('hidden');
      }
      await refresh();
      return;
    }

    const enrolled = !!getBiometricCredentialForUsername(session.username);
    if (enrolled) {
      removeBiometricCredential(session.username);
      render();
      return;
    }

    toggleBtn.disabled = true;
    toggleBtn.textContent = 'Setting up...';
    const result = await enrollBiometricCredential(session.username, session.password, session.displayName);
    toggleBtn.disabled = false;

    if (!result.success) {
      errorEl.textContent = result.message;
      errorEl.classList.remove('hidden');
    }
    render();
  });

  deauthorizeLink.addEventListener('click', async (event) => {
    event.preventDefault();
    errorEl.classList.add('hidden');
    const result = await revokeTimeClockDevice(session.username, session.password);
    if (!result.success) {
      errorEl.textContent = result.message;
      errorEl.classList.remove('hidden');
    }
    await refresh();
  });
}
