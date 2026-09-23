// Custom username/password session handling for the portal.
// Requires: supabaseClient.js to be loaded first.
//
// NOTE: This is a UI-only session (sessionStorage), not a real Supabase Auth
// session/JWT. It does not affect Row Level Security - see
// supabase_web_portal_rls_policies.sql for the security implications.
//
// The login password is also kept in this sessionStorage session (cleared when
// the tab/browser closes) so every page - staff-open pages (Online Orders) and
// super-user-only pages alike (Warehouse/Item/Variant/User/Advance Orders/
// Expenses/General Setup) - can call their re-verifying RPCs without prompting
// again. No page re-asks for the password once logged in; each still re-sends
// it on every RPC call and the database re-verifies it server-side each time.

const PORTAL_SESSION_KEY = 'portal_session';

function getPortalSession() {
  try {
    const raw = sessionStorage.getItem(PORTAL_SESSION_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function setPortalSession(session) {
  sessionStorage.setItem(PORTAL_SESSION_KEY, JSON.stringify(session));
}

/**
 * Verifies username/password against the StaffUsers table via the
 * verify_login() Postgres function (password hashing/checking happens
 * entirely server-side - the hash is never sent to the browser).
 */
async function attemptLogin(username, password) {
  const { data, error } = await supabaseClient.rpc('verify_login', {
    p_username: username,
    p_password: password
  });

  if (error) {
    return { success: false, message: error.message || 'Login failed. Please try again.' };
  }

  const result = Array.isArray(data) ? data[0] : data;
  if (!result || !result.success) {
    return { success: false, message: result?.message || 'Invalid username or password.' };
  }

  setPortalSession({
    username,
    password,
    displayName: result.display_name || username,
    warehouseName: result.warehouse_name || null,
    isSuperUser: !!result.is_super_user,
    isSalesUser: !!result.is_sales_user,
    isSerialAdmin: !!result.is_serial_admin,
    isDeliveryTeam: !!result.is_delivery_team,
    isOnlineOrderStaff: !!result.is_online_order_staff,
    isProductionMember: !!result.is_production_member,
    isPayrollOfficer: !!result.is_payroll_officer,
    isStoreManager: !!result.is_store_manager,
    isConversationsStaff: !!result.is_conversations_staff,
    mustChangePassword: !!result.must_change_password,
    loginAt: new Date().toISOString()
  });
  return { success: true };
}

// Pages that must stay reachable even while a password change is pending - the change-password
// page itself (obviously) and staff-login.html (attemptLogin above already redirects there once
// login succeeds, so requireAuth never actually runs on it, but excluding it here too avoids a
// redirect loop if that ever changes). Note: index.html is now the public customer landing page
// (not part of the staff portal at all), so it's deliberately absent from every list below.
const PASSWORD_CHANGE_EXEMPT_PAGES = ['change-password.html', 'staff-login.html'];

// Per "if the user is on Delivery team they can only see the Delivery calendar that is all" -
// a Delivery Team account is confined to these pages, regardless of any other flag it might also
// carry. change-password.html/staff-login.html stay reachable for the same reason they're exempt
// from the password-change gate above (this check runs after that one, so a Delivery Team account
// that also must change its password reaches change-password.html first anyway). dashboard.html is
// allowed too, but only shows a single "Go to Delivery" link there (#deliveryTeamGoToDeliveryBtn,
// see dashboard.html/js/dashboard.js) instead of the real dashboard content - per "can you atleast
// show a button first, the delivery button, on the dashboard" rather than a silent hard redirect.
// my-payslips.html/my-payslip-print.html added to both lists below per "each employee has login
// i want a portion there that they can access their pay / payslips" - self-service payslips
// (supabase_payroll_self_service_payslips.sql) are for every employee, including these two
// otherwise-locked-down roles, not just Payroll Officers/Super Users.
// delivery-receipt.html/invoice.html/job-order.html added too - all three are opened directly
// from buttons on delivery.html's Stops table (js/delivery.js), so leaving them out would let a
// Delivery Team account see the calendar but get bounced back to it the moment they clicked
// Print/Print Invoice/Print Job Order.
const DELIVERY_TEAM_ALLOWED_PAGES = ['delivery.html', 'delivery-receipt.html', 'invoice.html', 'job-order.html', 'dashboard.html', 'change-password.html', 'staff-login.html', 'my-payslips.html', 'my-payslip-print.html'];

// Same exclusive-lockdown shape as Delivery Team above, per "create me a field in the user setup
// 'Online Order Staff' - when this is tick the user will only see Orders Printed that to be Ship."
// online-order-lines.html is included too since every row's "View" link on Online Orders leads
// there - locking it out would break the one workflow this role exists for. dashboard.html is
// allowed but only shows a "Go to Online Orders" link (#onlineOrderStaffGoToOrdersBtn, see
// dashboard.html/js/dashboard.js), same pattern as Delivery Team's dashboard landing.
const ONLINE_ORDER_STAFF_ALLOWED_PAGES = ['online-orders.html', 'online-order-lines.html', 'dashboard.html', 'change-password.html', 'staff-login.html', 'my-payslips.html', 'my-payslip-print.html'];

// Same exclusive-lockdown shape as Delivery Team/Online Order Staff, but broader - per "Store
// manager, This permission can access Delivery calendar, Payslips, Serial tracker, inventory
// Summary, Stock on hand, Transfer Orders, Calculators, online Orders, Automated Orders"
// (supabase_staff_users_store_manager_field.sql) - later extended to also include Delivery Quote
// per "can you show the Delivery Quote too". Unlike the two single-page roles above, this
// confines the account to a whole ALLOWLIST rather than one hard redirect target - dashboard.html
// shows the normal (trimmed) dashboard, not a single-button landing block, since there's a real
// multi-page nav to use (see js/nav.js's isStoreManager branch). Includes each named area's
// necessary companion/print/drill-down pages (e.g. online-order-lines.html for Online Orders'
// "View" link, transfer-order-print*.html for Transfer Orders' print buttons) - without those,
// clicking into a normal workflow from an allowed page would immediately bounce them out.
const STORE_MANAGER_ALLOWED_PAGES = [
  'dashboard.html', 'change-password.html', 'staff-login.html',
  'my-payslips.html', 'my-payslip-print.html',
  'delivery.html', 'delivery-receipt.html', 'delivery-quote.html', 'invoice.html', 'job-order.html',
  'serial-tracker.html', 'inventory-summary.html',
  'stock-on-hand.html', 'stock-on-hand-print.html',
  'transfer-orders.html', 'transfer-order-print.html', 'transfer-order-print-production.html',
  'stand-calculator.html', 'aquarium-calculator.html', 'repair-calculator.html', 'sticker-calculator.html', 'glass-cut-list.html',
  'online-orders.html', 'online-order-lines.html',
  'automated-orders.html'
];

// Same exclusive-lockdown shape as Delivery Team/Online Order Staff above, for a "plain" account
// with NONE of the permission checkboxes ticked in User Setup - per "why it can see all the
// buttons? it suppose to be My payslips only right?" A plain login otherwise has nothing checked
// that grants it any specific page, so (unlike a Sales User, Super User, Serial Admin, Delivery
// Team, or Online Order Staff account) there is no other portal function it's actually meant to
// use - My Payslips is the one thing built for it. dashboard.html stays reachable, but only shows
// a "Go to My Payslips" link there (#noPermissionGoToPayslipsBtn, see dashboard.html/js/
// dashboard.js), same pattern as the other two roles' dashboard landing.
function hasNoPortalPermission(session) {
  return !session.isSuperUser && !session.isPayrollOfficer && !session.isSalesUser &&
    !session.isSerialAdmin && !session.isDeliveryTeam && !session.isOnlineOrderStaff &&
    !session.isProductionMember && !session.isStoreManager && !session.isConversationsStaff;
}
const NO_PERMISSION_ALLOWED_PAGES = ['my-payslips.html', 'my-payslip-print.html', 'dashboard.html', 'change-password.html', 'staff-login.html'];

function currentPageFileName() {
  return (window.location.pathname.split('/').pop() || '').toLowerCase();
}

async function requireAuth() {
  const session = getPortalSession();
  if (!session) {
    window.location.href = 'staff-login.html';
    return null;
  }

  const refreshed = await refreshPortalSession(session);
  if (!refreshed) return null;

  // Per "Change password - if this field is true then the user will be asked to change their
  // password upon login" - enforced globally here (not just right after login) so it also
  // catches an admin flipping the flag on mid-session, or the user bookmarking/navigating
  // straight to another page instead of going through staff-login.html.
  if (refreshed.mustChangePassword && !PASSWORD_CHANGE_EXEMPT_PAGES.includes(currentPageFileName())) {
    window.location.href = 'change-password.html';
    return null;
  }

  // Same "enforced on every page load, not just at login" reasoning as the password-change gate
  // above - catches an admin flipping the flag on mid-session, and can't be bypassed by
  // bookmarking/typing a different URL directly.
  if (refreshed.isDeliveryTeam && !DELIVERY_TEAM_ALLOWED_PAGES.includes(currentPageFileName())) {
    window.location.href = 'delivery.html';
    return null;
  }

  if (refreshed.isOnlineOrderStaff && !ONLINE_ORDER_STAFF_ALLOWED_PAGES.includes(currentPageFileName())) {
    window.location.href = 'online-orders.html';
    return null;
  }

  // Same "regardless of any other flag" lockdown as Delivery Team/Online Order Staff above, just
  // against a multi-page allowlist instead of one page - per "Store manager, This permission can
  // access Delivery calendar, Payslips, Serial tracker, inventory Summary, Stock on hand, Transfer
  // Orders, Calculators, online Orders, Automated Orders." Redirects to dashboard.html (their real,
  // if trimmed, home) rather than one specific page, since there's no single "the" Store Manager page.
  if (refreshed.isStoreManager && !STORE_MANAGER_ALLOWED_PAGES.includes(currentPageFileName())) {
    window.location.href = 'dashboard.html';
    return null;
  }

  // Same lockdown shape, for a plain account with none of the permission checkboxes ticked -
  // per "why it can see all the buttons? it suppose to be My payslips only right?" Checked after
  // the two role-specific locks above (mutually exclusive with both, since either flag already
  // makes hasNoPortalPermission false).
  if (hasNoPortalPermission(refreshed) && !NO_PERMISSION_ALLOWED_PAGES.includes(currentPageFileName())) {
    window.location.href = 'my-payslips.html';
    return null;
  }

  startIdleLogoutTimer();

  return refreshed;
}

// Auto-logout after 15 minutes with no mouse/keyboard/touch activity, warning the user 60s
// before it happens (with a chance to cancel) rather than logging out silently. Wired up here so
// every authenticated page gets it automatically via its requireAuth() call above - no per-page
// setup needed.
const IDLE_LOGOUT_MS = 15 * 60 * 1000;
const IDLE_WARNING_MS = 60 * 1000;
const IDLE_ACTIVITY_EVENTS = ['mousemove', 'mousedown', 'keydown', 'touchstart', 'scroll'];

let idleTimerStarted = false;
let idleWarnTimer = null;
let idleLogoutTimer = null;
let idleCountdownInterval = null;
let lastIdleActivityAt = 0;

function clearIdleTimers() {
  clearTimeout(idleWarnTimer);
  clearTimeout(idleLogoutTimer);
  clearInterval(idleCountdownInterval);
}

function hideIdleWarning() {
  const modal = document.getElementById('idleWarningModal');
  if (modal) modal.remove();
}

function showIdleWarning() {
  let secondsLeft = Math.round(IDLE_WARNING_MS / 1000);

  const modal = document.createElement('div');
  modal.id = 'idleWarningModal';
  modal.className = 'modal-backdrop';
  modal.innerHTML = `
    <div class="modal-panel" style="max-width:380px; text-align:center;">
      <h2 style="margin-top:0;">Still there?</h2>
      <p class="muted">You've been inactive - for security, you'll be signed out in <strong id="idleCountdown">${secondsLeft}</strong>s.</p>
      <button class="btn btn-primary" id="idleStayBtn" type="button" style="width:100%;">Stay Signed In</button>
    </div>
  `;
  document.body.appendChild(modal);
  document.getElementById('idleStayBtn').addEventListener('click', resetIdleTimer);

  idleCountdownInterval = setInterval(() => {
    secondsLeft -= 1;
    const countdownEl = document.getElementById('idleCountdown');
    if (countdownEl) countdownEl.textContent = secondsLeft;
  }, 1000);

  idleLogoutTimer = setTimeout(() => {
    hideIdleWarning();
    logout();
  }, IDLE_WARNING_MS);
}

function resetIdleTimer() {
  clearIdleTimers();
  hideIdleWarning();
  idleWarnTimer = setTimeout(showIdleWarning, IDLE_LOGOUT_MS - IDLE_WARNING_MS);
}

// Throttled so a mouse-move burst doesn't churn through clearTimeout/setTimeout on every event.
function handleIdleActivity() {
  const now = Date.now();
  if (now - lastIdleActivityAt < 1000) return;
  lastIdleActivityAt = now;
  resetIdleTimer();
}

function startIdleLogoutTimer() {
  if (idleTimerStarted) {
    resetIdleTimer();
    return;
  }
  idleTimerStarted = true;
  resetIdleTimer();
  IDLE_ACTIVITY_EVENTS.forEach((evt) => document.addEventListener(evt, handleIdleActivity, { passive: true }));
}

/**
 * Re-verifies the cached session against StaffUsers on every page load, so an admin
 * changing a user's warehouse/super-user flag mid-session takes effect on their next
 * page visit instead of requiring a manual logout/login to pick up the new values.
 */
async function refreshPortalSession(session) {
  try {
    const { data, error } = await supabaseClient.rpc('verify_login', {
      p_username: session.username,
      p_password: session.password
    });
    if (error) return session;

    const result = Array.isArray(data) ? data[0] : data;
    if (!result || !result.success) {
      // Credentials no longer valid (e.g. account deactivated) - force re-login.
      logout();
      return null;
    }

    const refreshed = {
      ...session,
      displayName: result.display_name || session.displayName,
      warehouseName: result.warehouse_name || null,
      isSuperUser: !!result.is_super_user,
      isSalesUser: !!result.is_sales_user,
      isSerialAdmin: !!result.is_serial_admin,
      isDeliveryTeam: !!result.is_delivery_team,
      isOnlineOrderStaff: !!result.is_online_order_staff,
      isProductionMember: !!result.is_production_member,
      isPayrollOfficer: !!result.is_payroll_officer,
      isStoreManager: !!result.is_store_manager,
      isConversationsStaff: !!result.is_conversations_staff,
      mustChangePassword: !!result.must_change_password
    };
    setPortalSession(refreshed);
    return refreshed;
  } catch {
    return session;
  }
}

// Where a session lands after signing in (or finishing a forced password change) with no more
// specific destination in mind - per "if the user is only active without any permission just show
// the payslips": a plain account with none of the flags below has nothing useful on the full
// Dashboard (no admin/sales/serial tooling), and isn't Delivery Team/Online Order Staff either
// (those already get their own dedicated dashboard.html landing block, unaffected by this - they
// still land on dashboard.html, which then shows that block). Land everyone else on My Payslips
// instead, since that's the one thing built specifically for a plain employee login.
function getDefaultLandingPage(session) {
  if (!session) return 'dashboard.html';
  return hasNoPortalPermission(session) ? 'my-payslips.html' : 'dashboard.html';
}

function logout() {
  sessionStorage.removeItem(PORTAL_SESSION_KEY);
  window.location.href = 'staff-login.html';
}

function wireLogoutButton(buttonId) {
  const btn = document.getElementById(buttonId);
  if (btn) btn.addEventListener('click', logout);
}
