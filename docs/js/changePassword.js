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

    successEl.textContent = 'Password changed. Redirecting...';
    successEl.classList.remove('hidden');
    setTimeout(() => { window.location.href = 'dashboard.html'; }, 800);
  });
})();
