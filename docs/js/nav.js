// Production links for the compact navs below - a Delivery Team / Online Order Staff account that is
// also a Production Manager (or Tank / Stand Maker) can open the Production pages (see
// canOpenProductionPage in js/auth.js).
function compactProductionLinks(session, activeLabel) {
  if (!(session?.isProductionManager || session?.isOrderMaker)) {
    // Sales Users get the Shelf Map view-only (canOpenProductionPage in js/auth.js).
    return session?.isSalesUser
      ? `
          <a class="topnav-link${activeLabel === 'Production Shelf Map' ? ' active' : ''}" href="production-shelf-map.html">Shelf Map</a>`
      : '';
  }
  return `
          <a class="topnav-link${activeLabel === 'Production Orders' ? ' active' : ''}" href="production-orders.html">Production Orders</a>${session.isProductionManager ? `
          <a class="topnav-link${activeLabel === 'Finished Production Orders' ? ' active' : ''}" href="production-orders.html?view=finished">Finished</a>` : ''}
          <a class="topnav-link${activeLabel === 'Production Shelf Map' ? ' active' : ''}" href="production-shelf-map.html">Shelf Map</a>${repairLink(session, activeLabel)}`;
}

// Repair Returns for a Tank / Stand Maker (their assigned repairs) or Production Manager - see
// canOpenProductionPage in js/auth.js.
function isRepairMaker(session) {
  return (session?.staffRoles || []).some((r) => r === 'TankMaker' || r === 'StandMaker');
}
function repairLink(session, activeLabel) {
  if (!(session?.isProductionManager || isRepairMaker(session))) return '';
  return `
          <a class="topnav-link${activeLabel === 'Repair Returns' ? ' active' : ''}" href="repair-returns.html">Repairs</a>`;
}

// Pages every staff login can open (ALL_STAFF_PAGES in js/auth.js) - added to the compact navs below,
// since the full nav further down already lists them under Calculators.
// Livestock Losses is open to every staff account except Delivery Team and Tank / Stand Makers /
// Dispatchers with no other access, and non-Super Users with no branch (canOpenStaffExceptMakersPage in js/auth.js) - shown in the compact navs below too.
function livestockLink(session, activeLabel) {
  if (!canOpenStaffExceptMakersPage(session, 'livestock-losses.html')) return '';
  return `
          <a class="topnav-link${activeLabel === 'Livestock Losses' ? ' active' : ''}" href="livestock-losses.html">Livestock Losses</a>`;
}

function allStaffLinks(activeLabel) {
  return `
          <a class="topnav-link${activeLabel === 'Aquarium Calculator' ? ' active' : ''}" href="aquarium-calculator.html">Aquarium Calculator</a>
          <a class="topnav-link${activeLabel === 'Payment Status' ? ' active' : ''}" href="payment-status.html">Payment Status</a>`;
}

// Renders the shared top navigation bar into <div id="topnav"></div>.
// Requires: auth.js to be loaded first (for wireLogoutButton, getPortalSession).
function renderTopNav(activeLabel) {
  renderTopNavLinks(activeLabel);
  mountTellMe();
  mountPayoutNotice(getPortalSession());
  mountTransferReceiveLock(getPortalSession());
  mountPaymentStatusNotice(getPortalSession());
}

// Payment channel status - per "see when a payment channel is down so our staff is aware". Reads Xendit's
// public status page (Atlassian Statuspage, CORS open, no key needed) straight from the browser. Only the
// channels we actually use (xendit-create-invoice's NON_CARD_CHANNELS + cards + the QR Ph POS code, and the
// payout destinations in _shared/xendit-payouts.ts) count. Shared by the banner below and payment-status.html.
// Xendit only reports its own side: a wallet's own scanner being down (e.g. GCash "QRPH will be back soon")
// won't show here.
const XENDIT_STATUS_URL = 'https://status.xendit.co/api/v2/summary.json';
const XENDIT_STATUS_CACHE_KEY = 'xenditStatusCache';
const PAYMENT_STATUS_SKIP_PAGES = ['payment-status.html', 'staff-login.html', 'change-password.html'];
// [Xendit group, Xendit component name, our label, kind]
const XENDIT_WATCHED_CHANNELS = [
  ['Philippines - Payments', 'QR Payments - QRPH', 'QR Ph (scan to pay)', 'payment'],
  ['Philippines - Payments', 'E-Wallets - GCash', 'GCash (pay link)', 'payment'],
  ['Philippines - Payments', 'E-Wallets - Paymaya', 'Maya', 'payment'],
  ['Philippines - Payments', 'E-Wallets - Grabpay', 'GrabPay', 'payment'],
  ['Philippines - Payments', 'E-Wallets - ShopeePay', 'ShopeePay', 'payment'],
  ['Philippines - Payments', 'Credit/Debit Cards', 'Credit / Debit Cards', 'payment'],
  ['Philippines - Payments', 'Direct Debit - BPI', 'BPI Direct Debit', 'payment'],
  ['Philippines - Payments', 'Direct Debit - BPI Online Banking', 'BPI Online Banking', 'payment'],
  ['Philippines - Payments', 'Direct Debit - RCBC', 'RCBC Direct Debit', 'payment'],
  ['Philippines - Payments', 'Direct Debit - RCBC Online Banking', 'RCBC Online Banking', 'payment'],
  ['Philippines - Payments', 'Over-The-Counter Payments - Cebuana', 'Cebuana (over the counter)', 'payment'],
  ['Philippines - Payments', 'Over-The-Counter Payments - LBC', 'LBC (over the counter)', 'payment'],
  ['Callback', null, 'Payment confirmations (callbacks)', 'payment'],
  ['Philippines - Payouts', 'Disbursement - GCASH', 'Payout to GCash', 'payout'],
  ['Philippines - Payouts', 'Disbursement - Paymaya', 'Payout to Maya', 'payout'],
  ['Philippines - Payouts', 'Disbursement - BPI', 'Payout to BPI', 'payout'],
  ['Philippines - Payouts', 'Disbursement - BDO', 'Payout to BDO', 'payout'],
  ['Philippines - Payouts', 'Disbursement - Other Philippines banks and E-Wallets', 'Payout to other banks / wallets', 'payout']
];
const XENDIT_STATUS_TEXT = {
  operational: 'Working',
  degraded_performance: 'Slow',
  partial_outage: 'Partly down',
  major_outage: 'Down',
  under_maintenance: 'Maintenance'
};

// Fetches the summary (cached per tab for 3 minutes unless force) and boils it down to our channels,
// plus incidents / maintenance that touch them. Returns null if Xendit's page can't be reached.
async function fetchPaymentChannelStatus(force) {
  let raw = null;
  if (!force) {
    try {
      const cached = JSON.parse(sessionStorage.getItem(XENDIT_STATUS_CACHE_KEY) || 'null');
      if (cached && Date.now() - cached.at < 3 * 60 * 1000) raw = cached.raw;
    } catch (e) { /* storage blocked / bad JSON */ }
  }
  if (!raw) {
    try {
      const res = await fetch(XENDIT_STATUS_URL, { cache: 'no-store' });
      if (!res.ok) return null;
      const s = await res.json();
      // Keep only what we use - the full summary is ~130 KB.
      raw = {
        components: (s.components || []).map((c) => ({ id: c.id, name: c.name, status: c.status, group_id: c.group_id || null, group: !!c.group })),
        incidents: (s.incidents || []).map((i) => ({ name: i.name, status: i.status, impact: i.impact, shortlink: i.shortlink, started_at: i.started_at || i.created_at, updated_at: i.updated_at, update: i.incident_updates?.[0]?.body || '', components: (i.components || []).map((c) => c.id) })),
        maintenances: (s.scheduled_maintenances || []).map((m) => ({ name: m.name, status: m.status, shortlink: m.shortlink, scheduled_for: m.scheduled_for, scheduled_until: m.scheduled_until, components: (m.components || []).map((c) => c.id) }))
      };
    } catch (e) {
      return null;
    }
    try { sessionStorage.setItem(XENDIT_STATUS_CACHE_KEY, JSON.stringify({ at: Date.now(), raw })); } catch (e) { /* storage blocked */ }
  }

  const groups = {};
  raw.components.filter((c) => c.group).forEach((g) => { groups[g.name] = g; });
  const channels = [];
  XENDIT_WATCHED_CHANNELS.forEach(([groupName, name, label, kind]) => {
    const group = groups[groupName];
    // A top-level component (Callback) or a child of the named group.
    const comp = name
      ? raw.components.find((c) => c.name === name && group && c.group_id === group.id)
      : group;
    if (comp) channels.push({ id: comp.id, label, kind, status: comp.status });
  });
  const ids = new Set(channels.map((c) => c.id));
  const touches = (item) => item.components.some((id) => ids.has(id));
  const labelsFor = (item) => channels.filter((c) => item.components.includes(c.id)).map((c) => c.label);
  const incidents = raw.incidents.filter(touches).map((i) => ({ ...i, channels: labelsFor(i) }));
  const maintenances = raw.maintenances.filter(touches).map((m) => ({ ...m, channels: labelsFor(m) }));
  return { channels, incidents, maintenances };
}

function paymentStatusSeverity(status) {
  return status === 'major_outage' || status === 'partial_outage' ? 'danger' : (status === 'operational' ? 'ok' : 'warning');
}

async function mountPaymentStatusNotice(session) {
  if (!session?.username) return;
  const page = (location.pathname.split('/').pop() || '').toLowerCase();
  if (page.includes('print') || PAYMENT_STATUS_SKIP_PAGES.includes(page)) return;
  const status = await fetchPaymentChannelStatus(false);
  if (!status) return; // fails quiet - never blocks a page
  // Payout problems only matter to whoever sends payouts.
  const seesPayouts = !!(session.isSuperUser || session.isPayrollOfficer);
  const bad = status.channels.filter((c) => c.status !== 'operational' && (c.kind === 'payment' || seesPayouts));
  if (!bad.length) return;
  // Dismiss hides it for this tab until the set of problems changes.
  const signature = bad.map((c) => c.id + ':' + c.status).sort().join('|');
  try { if (sessionStorage.getItem('paymentStatusDismissed') === signature) return; } catch (e) { /* storage blocked */ }

  const anyDown = bad.some((c) => paymentStatusSeverity(c.status) === 'danger');
  const color = anyDown ? 'var(--danger)' : '#a6720a';
  const box = document.createElement('div');
  box.id = 'paymentStatusNotice';
  box.className = 'no-print';
  box.setAttribute('role', 'status');
  box.style.cssText = 'max-width:1200px;margin:10px auto 0;padding:10px 14px;border-radius:8px;'
    + `border:1px solid ${color};background:var(--panel-bg);color:var(--text-main);`
    + 'box-shadow:var(--shadow);display:flex;gap:12px;align-items:flex-start;flex-wrap:wrap;font-size:14px;'
    + 'width:calc(100% - 32px);box-sizing:border-box;';
  const list = bad.map((c) => `${payoutNoticeEscape(c.label)} (${payoutNoticeEscape(XENDIT_STATUS_TEXT[c.status] || c.status)})`).join(', ');
  const customerHint = bad.some((c) => c.kind === 'payment') ? ' Offer the customer another payment method.' : '';
  box.innerHTML = `
    <div style="flex:1 1 260px;min-width:0;">
      <strong style="color:${color};">Payment channel issue:</strong> ${list}.${customerHint}
      <a href="payment-status.html">See payment status</a>
    </div>
    <button type="button" class="btn btn-secondary btn-sm" data-paystatus-dismiss>Dismiss</button>`;
  box.querySelector('[data-paystatus-dismiss]').addEventListener('click', () => {
    try { sessionStorage.setItem('paymentStatusDismissed', signature); } catch (e) { /* storage blocked */ }
    box.remove();
  });
  const nav = document.getElementById('topnav');
  if (nav && nav.parentNode) nav.parentNode.insertBefore(box, nav.nextSibling);
  else document.body.prepend(box);
}

// Overdue-receipt lock - per "the time they ship the goods and they did not receive until next day we can
// lock the portal and force them to go to transfer order and receive it". A transfer shipped to this staff's
// warehouse on an earlier day (Transfer Date = first ship date, set by shipTransferOrder) that's still
// In-Transit / Partial Shipped covers every page with a full-screen block until it's received. Transfer
// Orders itself is left open so they can actually receive. Super users and sales-only users (who can't open
// Transfer Orders) are never locked. Fails open: any error loading transfers means no lock.
const TRANSFER_LOCK_SKIP_PAGES = ['transfer-orders.html', 'staff-login.html', 'change-password.html'];

async function mountTransferReceiveLock(session) {
  if (!session?.username || !session.warehouseName || typeof supabaseClient === 'undefined') return;
  if (session.isSuperUser || session.isSalesUser) return;
  const page = (location.pathname.split('/').pop() || '').toLowerCase();
  if (page.includes('print') || TRANSFER_LOCK_SKIP_PAGES.includes(page)) return;

  let rows;
  try {
    const { data, error } = await supabaseClient
      .from('Transfer_Header')
      .select('*')
      .in('"Status"', ['In-Transit', 'Partial Shipped']);
    if (error) return;
    rows = data || [];
  } catch (e) {
    return;
  }

  const now = new Date();
  const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  const overdue = rows.filter((r) =>
    (r['To Warehouse'] || '') === session.warehouseName &&
    r['Transfer Date'] && String(r['Transfer Date']).slice(0, 10) < today
  ).sort((a, b) => String(a['Transfer Date']).localeCompare(String(b['Transfer Date'])));

  if (overdue.length) renderTransferReceiveLock(overdue);
}

function renderTransferReceiveLock(rows) {
  document.getElementById('transferReceiveLock')?.remove();
  const esc = payoutNoticeEscape;
  const shippedLabel = (d) => {
    const date = new Date(String(d).slice(0, 10) + 'T00:00:00');
    const days = Math.round((new Date().setHours(0, 0, 0, 0) - date.getTime()) / 86400000);
    return `${date.toLocaleDateString('en-PH', { month: 'short', day: 'numeric' })} (${days} day${days === 1 ? '' : 's'} ago)`;
  };

  const overlay = document.createElement('div');
  overlay.id = 'transferReceiveLock';
  overlay.className = 'no-print';
  overlay.setAttribute('role', 'alertdialog');
  overlay.setAttribute('aria-modal', 'true');
  overlay.setAttribute('aria-labelledby', 'transferReceiveLockTitle');
  overlay.style.cssText = 'position:fixed;inset:0;z-index:100000;background:rgba(0,0,0,0.65);'
    + 'display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box;overflow-y:auto;';
  overlay.innerHTML = `
    <div style="background:var(--panel-bg,#fff);color:var(--text-main,#111);border:2px solid var(--danger,#c62828);
                border-radius:10px;box-shadow:var(--shadow);max-width:560px;width:100%;padding:20px;box-sizing:border-box;">
      <h2 id="transferReceiveLockTitle" style="margin:0 0 8px;color:var(--danger,#c62828);font-size:20px;">
        Receive your transfer${rows.length === 1 ? '' : 's'} first
      </h2>
      <p style="margin:0 0 14px;font-size:14px;line-height:1.5;">
        ${rows.length === 1 ? 'This transfer was' : 'These transfers were'} shipped to <strong>${esc(rows[0]['To Warehouse'])}</strong>
        but ${rows.length === 1 ? 'has' : 'have'} not been received in the system. The portal is locked until you receive
        ${rows.length === 1 ? 'it' : 'them'}. If something is missing or damaged, receive what arrived - the Receive screen
        lets you return or write off the rest.
      </p>
      <div style="display:flex;flex-direction:column;gap:8px;">
        ${rows.map((r) => `
          <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:10px;border:1px solid var(--input-border,#ccc);border-radius:8px;">
            <div style="flex:1 1 200px;min-width:0;font-size:14px;">
              <strong>${esc(r['No.'])}</strong> from ${esc(r['From Warehouse'] || '-')}<br>
              <span style="opacity:0.75;">Shipped ${esc(shippedLabel(r['Transfer Date']))}${r['Shipped By'] ? ' by ' + esc(r['Shipped By']) : ''}</span>
            </div>
            <a class="btn btn-primary btn-sm" href="transfer-orders.html?doc=${encodeURIComponent(r['No.'])}">Receive now</a>
          </div>`).join('')}
      </div>
    </div>`;

  document.body.appendChild(overlay);
  // Keep keyboard focus / screen readers out of the locked page underneath.
  Array.from(document.body.children).forEach((el) => { if (el !== overlay) el.inert = true; });
  overlay.querySelector('a')?.focus();
}

// "You've been paid" notice - per "notice can be on the portal". When Xendit confirms a salary / cash advance
// payout, the employee sees a banner under the top nav on every page until they open the receipt or Dismiss
// (my_list_payout_receipts / my_dismiss_payout_notices, sql/supabase_xendit_payout_receipts.sql). The answer is
// cached per tab for 5 minutes so moving between pages doesn't call the server every time; it never blocks the page.
const PAYOUT_NOTICE_CACHE_KEY = 'payoutNoticeCache';
const PAYOUT_NOTICE_SKIP_PAGES = ['payout-receipt.html', 'change-password.html', 'staff-login.html'];

function payoutNoticeEscape(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function clearPayoutNoticeCache() {
  try { sessionStorage.removeItem(PAYOUT_NOTICE_CACHE_KEY); } catch (e) { /* storage blocked */ }
}

async function mountPayoutNotice(session) {
  if (!session?.username || typeof supabaseClient === 'undefined') return;
  const page = (location.pathname.split('/').pop() || '').toLowerCase();
  if (page.includes('print') || PAYOUT_NOTICE_SKIP_PAGES.includes(page)) return;

  let rows = null;
  try {
    const cached = JSON.parse(sessionStorage.getItem(PAYOUT_NOTICE_CACHE_KEY) || 'null');
    if (cached && cached.user === session.username && Date.now() - cached.at < 5 * 60 * 1000) rows = cached.rows;
  } catch (e) { /* storage blocked / bad JSON - just ask the server */ }

  if (!rows) {
    try {
      const { data, error } = await supabaseClient.rpc('my_list_payout_receipts', {
        p_username: session.username,
        p_password: session.password,
        p_unseen_only: true
      });
      if (error) return; // e.g. the SQL isn't run yet - no notice, nothing else breaks
      rows = data || [];
    } catch (e) {
      return;
    }
    try {
      sessionStorage.setItem(PAYOUT_NOTICE_CACHE_KEY, JSON.stringify({ user: session.username, at: Date.now(), rows }));
    } catch (e) { /* storage blocked */ }
  }

  if (rows.length) renderPayoutNotice(session, rows);
}

function renderPayoutNotice(session, rows) {
  document.getElementById('payoutNotice')?.remove();
  const peso = (n) => '₱' + (Number(n) || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const day = (d) => (d ? new Date(String(d).length === 10 ? d + 'T00:00:00' : d).toLocaleDateString('en-PH', { month: 'short', day: 'numeric' }) : '');
  const what = (p) => (p.kind === 'Salary'
    ? `Your salary for ${day(p.period_start)} - ${day(p.period_end)}`
    : `Your cash advance${p.advance_date ? ' of ' + day(p.advance_date) : ''}`);

  const box = document.createElement('div');
  box.id = 'payoutNotice';
  box.className = 'no-print';
  box.setAttribute('role', 'status');
  box.style.cssText = 'max-width:1200px;margin:10px auto 0;padding:10px 14px;border-radius:8px;'
    + 'border:1px solid var(--success);background:var(--panel-bg);color:var(--text-main);'
    + 'box-shadow:var(--shadow);display:flex;gap:12px;align-items:flex-start;flex-wrap:wrap;font-size:14px;'
    + 'width:calc(100% - 32px);box-sizing:border-box;';
  box.innerHTML = `
    <div style="flex:1 1 260px;min-width:0;">
      ${rows.map((p) => `<div style="margin:2px 0;">
        <strong style="color:var(--success);">Paid:</strong> ${payoutNoticeEscape(what(p))} -
        <strong>${peso(p.amount)}</strong> was sent to your ${payoutNoticeEscape(p.channel_name || '')} ${payoutNoticeEscape(p.account_masked || '')}${p.paid_at ? ' on ' + day(p.paid_at) : ''}.
        <a href="payout-receipt.html?id=${encodeURIComponent(p.payout_id)}" data-payout-receipt>View receipt</a>
      </div>`).join('')}
    </div>
    <button type="button" class="btn btn-secondary btn-sm" data-payout-dismiss>Dismiss</button>`;

  box.addEventListener('click', async (e) => {
    if (e.target.closest('[data-payout-receipt]')) {
      clearPayoutNoticeCache(); // opening the receipt clears this one server-side
      return;
    }
    if (!e.target.closest('[data-payout-dismiss]')) return;
    box.remove();
    clearPayoutNoticeCache();
    try {
      await supabaseClient.rpc('my_dismiss_payout_notices', {
        p_username: session.username,
        p_password: session.password,
        p_payout_ids: rows.map((p) => p.payout_id)
      });
    } catch (err) {
      console.error('Payout notice: dismiss failed', err);
    }
  });

  const nav = document.getElementById('topnav');
  if (nav && nav.parentNode) nav.insertAdjacentElement('afterend', box);
  else document.body.prepend(box);
}

function renderTopNavLinks(activeLabel) {
  const nav = document.getElementById('topnav');
  if (!nav) return;

  const session = getPortalSession();
  mountChatWidget(session);

  // Per "if the user is on Delivery team they can only see the Delivery calendar that is all" -
  // js/auth.js's requireAuth() only allows dashboard.html (shows just a "Go to Delivery" link,
  // see js/dashboard.js) and delivery.html itself for this group, so showing the full link list
  // here would just be a wall of dead-end links. Short-circuit to a minimal nav instead -
  // Dashboard + Delivery + Logout, nothing else, no hamburger collapse needed for so few items.
  if (session?.isDeliveryTeam) {
    nav.innerHTML = `
      <div class="topnav-inner">
        <span class="topnav-brand">RS Pet Stop Portal</span>
        <div class="topnav-links topnav-links-compact" id="topnavLinks">
          <a class="topnav-link${activeLabel === 'Dashboard' ? ' active' : ''}" href="dashboard.html">Dashboard</a>
          <a class="topnav-link${activeLabel === 'Delivery' ? ' active' : ''}" href="delivery.html">Delivery</a>${compactProductionLinks(session, activeLabel)}${allStaffLinks(activeLabel)}
          <a class="topnav-link${activeLabel === 'My Payslips' ? ' active' : ''}" href="my-payslips.html">My Payslips</a>
          <button id="logoutBtn" class="topnav-logout" type="button">Logout</button>
        </div>
      </div>
    `;
    wireLogoutButton('logoutBtn');
    return;
  }

  // Same reasoning as Delivery Team above, for "Online Order Staff" - js/auth.js's requireAuth()
  // only allows dashboard.html (shows just a "Go to Online Orders" link, see js/dashboard.js),
  // online-orders.html, and online-order-lines.html (the "View" drill-down) for this group.
  if (session?.isOnlineOrderStaff) {
    nav.innerHTML = `
      <div class="topnav-inner">
        <span class="topnav-brand">RS Pet Stop Portal</span>
        <div class="topnav-links topnav-links-compact" id="topnavLinks">
          <a class="topnav-link${activeLabel === 'Dashboard' ? ' active' : ''}" href="dashboard.html">Dashboard</a>
          <a class="topnav-link${activeLabel === 'Online Orders' ? ' active' : ''}" href="online-orders.html">Online Orders</a>${compactProductionLinks(session, activeLabel)}${livestockLink(session, activeLabel)}${allStaffLinks(activeLabel)}
          <a class="topnav-link${activeLabel === 'My Payslips' ? ' active' : ''}" href="my-payslips.html">My Payslips</a>
          <button id="logoutBtn" class="topnav-logout" type="button">Logout</button>
        </div>
      </div>
    `;
    wireLogoutButton('logoutBtn');
    return;
  }

  // Tank Maker / Stand Maker / Dispatcher with no other access - their assigned orders + payslips
  // (see isOrderMakerOnly in js/auth.js).
  if (isOrderMakerOnly(session)) {
    nav.innerHTML = `
      <div class="topnav-inner">
        <span class="topnav-brand">RS Pet Stop Portal</span>
        <div class="topnav-links topnav-links-compact" id="topnavLinks">
          <a class="topnav-link${activeLabel === 'Online Orders' ? ' active' : ''}" href="online-orders.html">My Assignments</a>
          <a class="topnav-link${activeLabel === 'Production Orders' ? ' active' : ''}" href="production-orders.html">Production Orders</a>
          <a class="topnav-link${activeLabel === 'Production Shelf Map' ? ' active' : ''}" href="production-shelf-map.html">Shelf Map</a>${repairLink(session, activeLabel)}${allStaffLinks(activeLabel)}
          <a class="topnav-link${activeLabel === 'My Payslips' ? ' active' : ''}" href="my-payslips.html">My Payslips</a>
          <button id="logoutBtn" class="topnav-logout" type="button">Logout</button>
        </div>
      </div>
    `;
    wireLogoutButton('logoutBtn');
    return;
  }

  // Same lockdown shape, for a plain account with none of the permission checkboxes ticked - per
  // "why it can see all the buttons? it suppose to be My payslips only right?" js/auth.js's
  // requireAuth() only allows dashboard.html (shows just a "Go to My Payslips" link, see
  // js/dashboard.js), my-payslips.html, and my-payslip-print.html for this group.
  if (session && hasNoPortalPermission(session)) {
    nav.innerHTML = `
      <div class="topnav-inner">
        <span class="topnav-brand">RS Pet Stop Portal</span>
        <div class="topnav-links topnav-links-compact" id="topnavLinks">
          <a class="topnav-link${activeLabel === 'Dashboard' ? ' active' : ''}" href="dashboard.html">Dashboard</a>${livestockLink(session, activeLabel)}${allStaffLinks(activeLabel)}
          <a class="topnav-link${activeLabel === 'My Payslips' ? ' active' : ''}" href="my-payslips.html">My Payslips</a>
          <button id="logoutBtn" class="topnav-logout" type="button">Logout</button>
        </div>
      </div>
    `;
    wireLogoutButton('logoutBtn');
    return;
  }

  // Per "Sales User dont need to see transfer orders and other related notification for
  // transfers - Remove Serial Tracker/Reports/Customer Aquarium" - a Sales User who is NOT also
  // a super user gets a trimmed top nav too, same set dropped as the dashboard's nav-card grid
  // (see js/dashboard.js's isSalesOnlyUser). Posted Transfers is dropped alongside Transfer
  // Orders since it's the same transfer-order workflow, just the read-only posted view.
  const isSalesOnlyUser = session?.isSalesUser && !session?.isSuperUser;
  const isSuperUser = !!session?.isSuperUser;
  const isPayrollOfficer = !!session?.isPayrollOfficer;
  // Store Manager (supabase_staff_users_store_manager_field.sql) gets a curated subset of each
  // group below - Transfer Orders but not Posted Transfers, Delivery (now including Delivery
  // Quote - see js/auth.js's STORE_MANAGER_ALLOWED_PAGES), Serial Tracker/Inventory Summary/Stock
  // On Hand but not Purchase Orders, no Reports/Admin group at all - per the exact list in "Store
  // manager, This permission can access...". Enforced server-side too via js/auth.js's
  // requireAuth() STORE_MANAGER_ALLOWED_PAGES, so hiding these links is convenience, not the
  // control.
  const isStoreManager = !!session?.isStoreManager;
  // Conversations Access (supabase_staff_users_conversations_staff_field.sql) - plain additive tag
  // that just unlocks the GMA Conversations link below, same shape as Payroll Officer.
  const isConversationsStaff = !!session?.isConversationsStaff;

  // Dashboard stands alone (not part of any group) since it's the one link everyone reaches for
  // first. Everything else is bucketed by function so the nav reads as a handful of menus instead
  // of a wall of ~20 flat tabs - see the .topnav-group/.topnav-group-menu styles in css/styles.css.
  // My Payslips stands alone too (not bucketed under Admin) - it's a personal self-service page
  // every login can use, not a functional/admin grouping.
  const standalone = [
    { href: 'dashboard.html', label: 'Dashboard' },
    { href: 'my-payslips.html', label: 'My Payslips' }
  ];

  // Menus are grouped by what the person is doing (sell, stock, build, money, look at numbers, promote,
  // set up), per "can we do a better grouping" - each item carries a `section` shown as a small heading
  // inside its dropdown. Labels are unchanged (pages match activeLabel against them).
  const isProductionManager = !!session?.isProductionManager;
  const canSeeSalesAnalysis = !isSalesOnlyUser && !isStoreManager;

  // Sales: orders and delivery, customers, and the quoting calculators.
  const sales = [];
  sales.push({ section: 'Orders', href: 'online-orders.html', label: 'Online Orders' });
  if (isSuperUser) {
    sales.push({ section: 'Orders', href: 'advance-orders.html', label: 'Advance Orders' });
  }
  // Conversations Access sees GMA Conversations + Customers even without full Super User - same
  // "isSuperUser || is<Flag>" gate the pages themselves enforce in their own init().
  if (isSuperUser || isConversationsStaff) {
    sales.push({ section: 'Customers', href: 'customers.html', label: 'Customers' });
    sales.push({ section: 'Customers', href: 'gma-conversations.html', label: 'Conversations' });
  }
  if (canSeeSalesAnalysis) {
    sales.push({ section: 'Customers', href: 'customer-aquarium.html', label: 'Customer Aquarium' });
  }
  sales.push({ section: 'Quotes & Calculators', href: 'aquarium-calculator.html', label: 'Aquarium Calculator' });
  sales.push({ section: 'Quotes & Calculators', href: 'stand-calculator.html', label: 'Custom Stand' });
  sales.push({ section: 'Quotes & Calculators', href: 'repair-calculator.html', label: 'Repair Calculator' });
  sales.push({ section: 'Quotes & Calculators', href: 'sticker-calculator.html', label: 'Custom Accessories / Stickers' });
  sales.push({ section: 'Quotes & Calculators', href: 'glass-cut-list.html', label: 'Glass Cut List' });
  // Every login can open it (ALL_STAFF_PAGES in js/auth.js) - Xendit's live channel status.
  sales.push({ section: 'Payments', href: 'payment-status.html', label: 'Payment Status' });

  // Delivery: its own menu - the calendar, quoting a delivery fee, and (super users) zones / rates.
  const delivery = [
    { href: 'delivery.html', label: 'Delivery' },
    { href: 'delivery-quote.html', label: 'Delivery Quote' }
  ];
  if (isSuperUser) {
    delivery.push({ href: 'delivery-setup.html', label: 'Delivery Setup' });
  }

  // Inventory: what's on hand, moving it between stores, counting / returns, buying, item setup.
  // Store Manager gets a curated subset (see js/auth.js's STORE_MANAGER_ALLOWED_PAGES) - enforced
  // server-side too, so hiding these links is convenience, not the control.
  const inventory = [];
  inventory.push({ section: 'Stock', href: 'stock-on-hand.html', label: 'Stock On Hand' });
  // Per "let the sales user see it as well" - Inventory Summary stays visible to Sales-only users.
  inventory.push({ section: 'Stock', href: 'inventory-summary.html', label: 'Inventory Summary' });
  inventory.push({ section: 'Stock', href: 'shelf-map.html', label: 'Shelf Map' });
  if (!isSalesOnlyUser) {
    inventory.push({ section: 'Stock', href: 'serial-tracker.html', label: 'Serial Tracker' });
  }
  if (isSuperUser) {
    inventory.push({ section: 'Stock', href: 'item-ledger-entries.html', label: 'Item Ledger Entries' });
  }
  if (isStoreManager) {
    inventory.push({ section: 'Transfers', href: 'transfer-orders.html', label: 'Transfer Orders' });
  } else if (!isSalesOnlyUser) {
    inventory.push({ section: 'Transfers', href: 'transfer-orders.html', label: 'Transfer Orders' });
    inventory.push({ section: 'Transfers', href: 'posted-transfer-orders.html', label: 'Posted Transfers' });
  }
  // Counting - Physical / Serial Inventory Journal RPCs use is_phys_journal_authorized (Super User or
  // Store Manager). Defect Items: Store Managers report (own location), Super Users approve.
  if (isSuperUser || isStoreManager) {
    inventory.push({ section: 'Counts & Returns', href: 'physical-inventory-journal.html', label: 'Physical Inventory Journal' });
    inventory.push({ section: 'Counts & Returns', href: 'serial-inventory-journal.html', label: 'Serial Inventory Journal' });
    inventory.push({ section: 'Counts & Returns', href: 'defect-items.html', label: 'Defect Items' });
  }
  // Livestock Losses (supabase_livestock_losses.sql): every staff account except maker-only accounts
  // (those return early above), Delivery Team and no-branch accounts. The RPCs re-check.
  if (canOpenStaffExceptMakersPage(session, 'livestock-losses.html')) {
    inventory.push({ section: 'Counts & Returns', href: 'livestock-losses.html', label: 'Livestock Losses' });
  }
  // Store sends a damaged item to our makers and gets it back (supabase_repair_returns.sql).
  if (isSuperUser || isStoreManager || isProductionManager) {
    inventory.push({ section: 'Counts & Returns', href: 'repair-returns.html', label: 'Repair Returns' });
  }
  if (!isStoreManager) {
    inventory.push({ section: 'Purchasing', href: 'purchase-orders.html', label: 'Purchase Orders' });
    inventory.push({ section: 'Purchasing', href: 'posted-purchase-orders.html', label: 'Posted Purchase Orders' });
  }
  // Super users only - every RPC behind these re-checks with is_admin_authorized.
  if (isSuperUser) {
    inventory.push({ section: 'Purchasing', href: 'vendor-setup.html', label: 'Vendors' });
    inventory.push({ section: 'Item Setup', href: 'item-setup.html', label: 'Item Setup' });
    inventory.push({ section: 'Item Setup', href: 'variant-setup.html', label: 'Variants' });
    inventory.push({ section: 'Item Setup', href: 'category-setup.html', label: 'Categories' });
    inventory.push({ section: 'Item Setup', href: 'warehouse-setup.html', label: 'Warehouse Setup' });
  } else if (session?.isCatalogEditor) {
    // Catalog Editor role (supabase_catalog_editor_role.sql) - Item Setup only, without prices / cost.
    inventory.push({ section: 'Item Setup', href: 'item-setup.html', label: 'Item Setup' });
  }

  // Production (supabase_production_orders.sql) - restock builds; Super User / Production Manager
  // manage them, a Tank / Stand Maker sees only their own. The RPCs re-check the role.
  const production = [];
  if (isSuperUser || isProductionManager || session?.isOrderMaker) {
    production.push({ href: 'production-orders.html', label: 'Production Orders' });
    if (isSuperUser || isProductionManager) {
      production.push({ href: 'production-orders.html?view=finished', label: 'Finished Production Orders' });
    }
    production.push({ href: 'production-shelf-map.html', label: 'Production Shelf Map' });
    // A maker's assigned repairs - managers already have it under Inventory.
    if (isRepairMaker(session) && !(isSuperUser || isStoreManager || isProductionManager)) {
      production.push({ href: 'repair-returns.html', label: 'Repair Returns' });
    }
  } else if (session?.isSalesUser) {
    // View-only stock availability for Sales Users (canOpenProductionPage in js/auth.js).
    production.push({ href: 'production-shelf-map.html', label: 'Production Shelf Map' });
  }
  if (isSuperUser) {
    production.push({ href: 'maker-assignments.html', label: 'Maker Assignments' });
  }

  // Finance: cash and payments in, money out, accounting, payroll. Super users only except
  // Tender Declarations (Store Managers attach bank deposit slips, supabase_tender_deposit_receipts.sql)
  // and Payroll (Payroll Officer - same "isSuperUser || isPayrollOfficer" gate the pages enforce).
  const finance = [];
  if (isSuperUser) {
    finance.push({ section: 'Cash & Payments', href: 'daily-sales-report.html', label: 'Daily Sales Report' });
    finance.push({ section: 'Cash & Payments', href: 'monthly-sales-report.html', label: 'Monthly Sales Report' });
  }
  if (isSuperUser || isStoreManager) {
    finance.push({ section: 'Cash & Payments', href: 'tender-declarations.html', label: 'Tender Declarations' });
  }
  if (isSuperUser) {
    finance.push({ section: 'Cash & Payments', href: 'payment-method-report.html', label: 'Payment Methods Report' });
    finance.push({ section: 'Cash & Payments', href: 'xendit-payments.html', label: 'Xendit Payments' });
    finance.push({ section: 'Cash & Payments', href: 'xendit-ledger.html', label: 'Xendit Ledger' });
    finance.push({ section: 'Spending', href: 'expense-entries.html', label: 'Expenses' });
    finance.push({ section: 'Spending', href: 'expense-journal.html', label: 'Expense Journal' });
    finance.push({ section: 'Spending', href: 'business-bills.html', label: 'Bills & Dues' });
    finance.push({ section: 'Spending', href: 'ai-spend.html', label: 'AI Spend (Claude)' });
    finance.push({ section: 'Spending', href: 'meta-ads.html', label: 'Meta Ads' });
    finance.push({ section: 'Spending', href: 'spending-report.html', label: 'Purchases & Expenses' });
    finance.push({ section: 'Spending', href: 'owner-funds.html', label: 'Owner Funds' });
    finance.push({ section: 'Accounting', href: 'gl-entries.html', label: 'General Ledger' });
    finance.push({ section: 'Accounting', href: 'bir-sales-report.html', label: 'BIR Sales Report' });
  }
  if (isSuperUser || isPayrollOfficer) {
    finance.push({ section: 'Payroll', href: 'payroll.html', label: 'Payroll' });
    finance.push({ section: 'Payroll', href: 'payroll-timesheets.html', label: 'Timesheets' });
    finance.push({ section: 'Payroll', href: 'payroll-ledger.html', label: 'Payroll Ledger' });
    finance.push({ section: 'Payroll', href: 'payroll-spending-report.html', label: 'Payroll Spending' });
    finance.push({ section: 'Payroll', href: 'payroll-setup.html', label: 'Payroll Setup' });
  }

  // Reports: sales analysis and response times.
  const reports = [];
  if (isSuperUser) {
    // Manager's Report: sales vs target, money in/out, stock missing (sql/supabase_manager_report.sql).
    reports.push({ section: 'Overview', href: 'manager-report.html', label: "Manager's Report" });
  }
  // Super User only for now - hidden from Store Managers while still under construction (2026-11-21).
  // To give it back: (isSuperUser || isStoreManager) here + re-add the 3 pages to
  // STORE_MANAGER_ALLOWED_PAGES in js/auth.js.
  if (isSuperUser) {
    // Manager Scorecard: one branch's goals, no money figures; Store Managers see only their own branch
    // (sql/supabase_manager_scorecard.sql).
    reports.push({ section: 'Overview', href: 'manager-kpi.html', label: 'Manager KPI' });
    reports.push({ section: 'Overview', href: 'manager-scorecard.html', label: 'Manager Scorecard' });
    reports.push({ section: 'Overview', href: 'branch-checklist.html', label: 'Daily Checklist' });
  }
  if (canSeeSalesAnalysis) {
    reports.push({ section: 'Sales', href: 'reports.html', label: 'Reports' });
    reports.push({ section: 'Sales', href: 'top-selling-items.html', label: 'Top Selling Items' });
    reports.push({ section: 'Sales', href: 'slow-fast-moving-items.html', label: 'Slow & Fast Moving' });
    reports.push({ section: 'Sales', href: 'category-sales-report.html', label: 'Category Sales' });
    reports.push({ section: 'Sales', href: 'sealant-sales-report.html', label: 'Sealant Sales' });
  }
  if (isSuperUser) {
    reports.push({ section: 'Speed', href: 'order-timing-dashboard.html', label: 'Order Timing' });
    reports.push({ section: 'Speed', href: 'message-timing.html', label: 'Message Timing' });
  }

  // Marketing: Facebook posting / ads and the AI bot (Alice).
  const marketing = [];
  if (isSuperUser) {
    marketing.push({ section: 'Facebook', href: 'quick-post.html', label: 'Quick Post' });
    marketing.push({ section: 'Facebook', href: 'new-arrivals.html', label: 'New Arrivals' });
    marketing.push({ section: 'Facebook', href: 'video-ad-builder.html', label: 'Video Ad Builder' });
    marketing.push({ section: 'Facebook', href: 'facebook-post-test.html', label: 'Facebook Post Test' });
    marketing.push({ section: 'AI Bot', href: 'ai-bot-setup.html', label: 'AI Bot Setup' });
    marketing.push({ section: 'AI Bot', href: 'ai-bot-sandbox.html', label: 'AI Bot Sandbox' });
  }

  // Admin: prices and system setup.
  const admin = [];
  if (isSuperUser) {
    admin.push({ section: 'Pricing', href: 'pricing-setup.html', label: 'Pricing Setup' });
    admin.push({ section: 'Pricing', href: 'size-pricing.html', label: 'Size Pricing' });
    admin.push({ section: 'Pricing', href: 'price-increase.html', label: 'Price Increase' });
    admin.push({ section: 'Setup', href: 'general-setup.html', label: 'General Setup' });
    admin.push({ section: 'Setup', href: 'user-setup.html', label: 'User Setup' });
    admin.push({ section: 'Setup', href: 'payment-methods.html', label: 'Payment Methods' });
    admin.push({ section: 'Setup', href: 'gl-setup.html', label: 'G/L Setup' });
    // Read-only regression checks (docs/tests/*.js).
    admin.push({ section: 'Tools', href: 'system-tests.html', label: 'System Tests' });
  }

  const groups = [
    { label: 'Sales', items: sales },
    { label: 'Delivery', items: delivery },
    { label: 'Inventory', items: inventory },
    { label: 'Production', items: production },
    { label: 'Finance', items: finance },
    { label: 'Reports', items: reports },
    { label: 'Marketing', items: marketing },
    { label: 'Admin', items: admin },
  ].filter((group) => group.items.length > 0);

  const standaloneHtml = standalone
    .map((item) => {
      const activeClass = item.label === activeLabel ? ' active' : '';
      return `<a class="topnav-link${activeClass}" href="${item.href}">${item.label}</a>`;
    })
    .join('');

  const groupsHtml = groups
    .map((group, index) => {
      const isActiveGroup = group.items.some((item) => item.label === activeLabel);
      // Items in their section order (first appearance); a section heading only when the menu has
      // more than one section.
      const sections = [];
      group.items.forEach((item) => {
        const name = item.section || '';
        let section = sections.find((s) => s.name === name);
        if (!section) {
          section = { name, items: [] };
          sections.push(section);
        }
        section.items.push(item);
      });
      const showHeadings = sections.length > 1;
      const itemsHtml = sections
        .map((section) => {
          const links = section.items
            .map((item) => {
              const activeClass = item.label === activeLabel ? ' active' : '';
              return `<a class="topnav-link${activeClass}" href="${item.href}">${item.label}</a>`;
            })
            .join('');
          const heading = showHeadings && section.name ? `<div class="topnav-menu-heading">${section.name}</div>` : '';
          return `<div class="topnav-menu-section">${heading}${links}</div>`;
        })
        .join('');
      // Long menus (Inventory, Finance for a super user) go two columns so they don't run off the
      // screen; the last few menus open leftward so they stay inside the window.
      const wideClass = group.items.length > 10 && sections.length > 1 ? ' topnav-group-menu-wide' : '';
      const rightClass = index >= groups.length - 3 ? ' topnav-group-menu-right' : '';
      return `
        <div class="topnav-group" data-group-index="${index}">
          <button class="topnav-group-toggle${isActiveGroup ? ' active' : ''}" type="button" aria-expanded="false">
            ${group.label}<span class="topnav-group-caret">&#9662;</span>
          </button>
          <div class="topnav-group-menu${wideClass}${rightClass}">${itemsHtml}</div>
        </div>
      `;
    })
    .join('');

  nav.innerHTML = `
    <div class="topnav-inner">
      <span class="topnav-brand">RS Pet Stop Portal</span>
      <button class="topnav-toggle" id="topnavToggle" type="button" aria-label="Menu" aria-expanded="false">&#9776;</button>
      <div class="topnav-links" id="topnavLinks">
        ${standaloneHtml}
        ${groupsHtml}
        <button id="logoutBtn" class="topnav-logout" type="button">Logout</button>
      </div>
    </div>
  `;

  wireLogoutButton('logoutBtn');

  // Mobile: the link list is a hidden dropdown behind this hamburger button (see the
  // .topnav-toggle/.topnav-links.open media query in css/styles.css) - hidden entirely on wide
  // screens where the links already fit inline, so the click handler is harmless either way.
  const toggle = document.getElementById('topnavToggle');
  const links = document.getElementById('topnavLinks');
  toggle.addEventListener('click', () => {
    const isOpen = links.classList.toggle('open');
    toggle.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
  });

  // Each functional group (Orders/Delivery/Calculators/etc) is its own click-to-open dropdown -
  // opening one closes any other that's open, and clicking anywhere outside closes all of them.
  // Works the same way on the mobile accordion since it's just CSS display, not a separate widget.
  const groupEls = Array.from(nav.querySelectorAll('.topnav-group'));
  groupEls.forEach((groupEl) => {
    const groupToggle = groupEl.querySelector('.topnav-group-toggle');
    groupToggle.addEventListener('click', (event) => {
      event.stopPropagation();
      const isOpen = groupEl.classList.contains('open');
      groupEls.forEach((otherEl) => {
        otherEl.classList.remove('open');
        otherEl.querySelector('.topnav-group-toggle').setAttribute('aria-expanded', 'false');
      });
      if (!isOpen) {
        groupEl.classList.add('open');
        groupToggle.setAttribute('aria-expanded', 'true');
      }
    });
  });
  document.addEventListener('click', (event) => {
    // A click on a link INSIDE an open group must not close it here - closing sets the menu's
    // display to none synchronously while the click is still being processed, and browsers cancel
    // the link's own navigation when its container disappears mid-click. Only clicks truly outside
    // every group need to close anything; clicking a link just navigates the page away anyway.
    if (event.target.closest('.topnav-group')) return;
    groupEls.forEach((groupEl) => {
      groupEl.classList.remove('open');
      groupEl.querySelector('.topnav-group-toggle').setAttribute('aria-expanded', 'false');
    });
  });
}

// "Tell Me" page search, like Business Central's Alt+Q - per "can you let the user search a module..
// same like business central". The search button + Alt+Q / Ctrl+K open a dialog that filters the
// pages in the nav renderTopNavLinks just drew, so each role only ever finds the pages it can open
// (no second permission list to keep in sync). Extra search words per page live in TELL_ME_KEYWORDS.
const TELL_ME_KEYWORDS = {
  'dashboard.html': 'home start main',
  'my-payslips.html': 'salary pay slip payslip wages',
  'transfer-orders.html': 'to move stock branch location transfer',
  'posted-transfer-orders.html': 'to history transfer posted',
  'online-orders.html': 'sales so customer order facebook messenger new assignments',
  'advance-orders.html': 'reservation deposit',
  'delivery.html': 'calendar schedule driver dispatch',
  'delivery-quote.html': 'shipping fee rate',
  'delivery-setup.html': 'shipping zones rates driver',
  'stand-calculator.html': 'price quote cabinet',
  'aquarium-calculator.html': 'price quote tank glass custom',
  'repair-calculator.html': 'price quote fix leak',
  'sticker-calculator.html': 'price quote decal',
  'glass-cut-list.html': 'cutting glass panes',
  'serial-tracker.html': 'serial number sn unit',
  'inventory-summary.html': 'stock qty quantity available',
  'stock-on-hand.html': 'stock qty quantity inventory available',
  'shelf-map.html': 'bin rack location where',
  'purchase-orders.html': 'po buy supplier vendor receive',
  'posted-purchase-orders.html': 'po received history receipt',
  'physical-inventory-journal.html': 'count stocktake adjust phys',
  'defect-items.html': 'damaged broken return',
  'livestock-losses.html': 'dead fish plant mortality died loss',
  'repair-returns.html': 'repair fix broken leak send back aquarium',
  'item-ledger-entries.html': 'ile movements history stock',
  'warehouse-setup.html': 'location branch store',
  'item-setup.html': 'product items price card',
  'variant-setup.html': 'size color option',
  'category-setup.html': 'item group',
  'vendor-setup.html': 'supplier',
  'production-orders.html': 'build make tank stand finished',
  'production-shelf-map.html': 'built units bin rack',
  'maker-assignments.html': 'tank maker stand maker jobs',
  'serial-inventory-journal.html': 'count serial stocktake',
  'reports.html': 'sales report',
  'manager-kpi.html': 'manager kpi score evaluation bonus ranking performance review attendance retention sop leadership',
  'branch-checklist.html': 'opening closing cleaning checklist sop daily photo',
  'manager-scorecard.html': 'manager scorecard kpi goals performance gauge evaluation count sheet expected count on hand sold',
  'manager-report.html': 'manager overview target goal quota profit loss losing missing shrinkage stock summary performance',
  'top-selling-items.html': 'best sellers sales',
  'slow-fast-moving-items.html': 'slow moving fast moving dead stock non-moving aging overstock velocity',
  'sealant-sales-report.html': 'silicone black clear',
  'category-sales-report.html': 'sales by category',
  'customer-aquarium.html': 'customer tanks',
  'order-timing-dashboard.html': 'speed turnaround',
  'message-timing.html': 'reply response time',
  'expense-entries.html': 'spending costs',
  'expense-journal.html': 'spending costs post',
  'ai-spend.html': 'claude anthropic alice bot tokens credits top-up usage',
  'meta-ads.html': 'facebook instagram ads boost wallet balance top-up gcash amaya gma advertising',
  'tender-declarations.html': 'cash count eod short over drawer cashier',
  'business-bills.html': 'rent utilities bir sss dues',
  'owner-funds.html': 'capital drawings loan',
  'spending-report.html': 'purchases expenses costs',
  'gl-entries.html': 'gl accounting ledger finance',
  'payment-method-report.html': 'gcash cash bank collections',
  'bir-sales-report.html': 'bir tax vat walk-in sales journal sales book',
  'daily-sales-report.html': 'eod end of day sales summary today yesterday z report',
  'monthly-sales-report.html': 'month monthly sales summary branch warehouse per day',
  'general-setup.html': 'settings company config',
  'ai-bot-setup.html': 'alice chatbot',
  'gma-conversations.html': 'messages inbox chat messenger',
  'customers.html': 'contacts clients',
  'ai-bot-sandbox.html': 'alice chatbot test',
  'facebook-post-test.html': 'fb social',
  'quick-post.html': 'facebook fb photo social',
  'new-arrivals.html': 'new arrivals fish plants announcement facebook auto post transfer received',
  'video-ad-builder.html': 'video ad reels marketing facebook instagram mp4 promo',
  'pricing-setup.html': 'prices rates',
  'size-pricing.html': 'fish size inch bigger price tier scale',
  'price-increase.html': 'price change raise markup wholesale percent',
  'payment-methods.html': 'gcash cash bank tender',
  'xendit-payments.html': 'online payment gateway gcash card pay link',
  'payment-status.html': 'xendit down outage qrph gcash maya card channel maintenance payout status',
  'xendit-ledger.html': 'xendit balance transactions fees vat withdrawal payout settlement money in out',
  'gl-setup.html': 'accounts chart accounting',
  'user-setup.html': 'staff employees permissions accounts login',
  'system-tests.html': 'test check broken regression health',
  'payroll.html': 'salary wages',
  'payroll-setup.html': 'salary rates employees',
  'payroll-timesheets.html': 'attendance hours time',
  'payroll-ledger.html': 'salary history',
  'payroll-spending-report.html': 'salary cost'
};

let tellMeEntries = [];

function tellMeEscape(text) {
  return String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function tellMeRecent() {
  try { return JSON.parse(localStorage.getItem('tellMeRecent') || '[]'); } catch (_) { return []; }
}

function tellMeRemember(href) {
  try {
    const list = [href].concat(tellMeRecent().filter((h) => h !== href)).slice(0, 5);
    localStorage.setItem('tellMeRecent', JSON.stringify(list));
  } catch (_) { /* private window - no recents, search still works */ }
}

function mountTellMe() {
  const nav = document.getElementById('topnav');
  const inner = nav && nav.querySelector('.topnav-inner');
  if (!inner) return;

  // Every link the nav drew for this user, with its menu group as the category.
  const seen = new Set();
  tellMeEntries = [];
  inner.querySelectorAll('a.topnav-link').forEach((a) => {
    const href = a.getAttribute('href');
    if (!href || seen.has(href)) return;
    seen.add(href);
    const groupBtn = a.closest('.topnav-group')?.querySelector('.topnav-group-toggle');
    const group = groupBtn ? groupBtn.firstChild.textContent.trim() : '';
    const label = a.textContent.trim();
    const keywords = TELL_ME_KEYWORDS[href.split('?')[0]] || '';
    tellMeEntries.push({ href, label, group, haystack: `${label} ${group} ${keywords}`.toLowerCase() });
  });
  if (!tellMeEntries.length) return;

  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'topnav-search';
  btn.title = 'Search pages (Alt+Q)';
  btn.setAttribute('aria-label', 'Search pages');
  btn.innerHTML = '<span aria-hidden="true">&#128269;</span><span class="topnav-search-label">Search</span><kbd>Alt+Q</kbd>';
  btn.addEventListener('click', openTellMe);
  inner.insertBefore(btn, inner.querySelector('.topnav-toggle') || inner.querySelector('.topnav-links'));

  if (!window.__tellMeKeys) {
    window.__tellMeKeys = true;
    document.addEventListener('keydown', (event) => {
      const altQ = event.altKey && !event.ctrlKey && !event.metaKey && event.code === 'KeyQ';
      const ctrlK = (event.ctrlKey || event.metaKey) && !event.altKey && event.code === 'KeyK';
      if (!altQ && !ctrlK) return;
      event.preventDefault();
      openTellMe();
    });
  }
}

// Every query word must appear somewhere in the label / group / keywords (BC-style); a hit in the
// page name itself ranks above a keyword-only hit.
function tellMeSearch(query) {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) {
    const recent = tellMeRecent();
    const recentEntries = recent.map((h) => tellMeEntries.find((e) => e.href === h)).filter(Boolean);
    return { recent: recentEntries, results: tellMeEntries.filter((e) => !recentEntries.includes(e)) };
  }
  const scored = [];
  tellMeEntries.forEach((entry, index) => {
    if (!words.every((w) => entry.haystack.includes(w))) return;
    const label = entry.label.toLowerCase();
    const initials = label.split(/[^a-z0-9]+/).filter(Boolean).map((p) => p[0]).join('');
    let score = 0;
    words.forEach((w) => {
      if (w.length > 1 && w === initials) score += 40; // "po" -> Purchase Orders, "ile" -> Item Ledger Entries
      else if (label.startsWith(w)) score += 30;
      else if (new RegExp(`\\b${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`).test(label)) score += 20;
      else if (label.includes(w)) score += 10;
    });
    scored.push({ entry, score, index });
  });
  scored.sort((a, b) => b.score - a.score || a.index - b.index);
  return { recent: [], results: scored.map((s) => s.entry) };
}

function openTellMe() {
  let backdrop = document.getElementById('tellMeBackdrop');
  if (backdrop) {
    backdrop.querySelector('input').select();
    return;
  }

  backdrop = document.createElement('div');
  backdrop.id = 'tellMeBackdrop';
  backdrop.className = 'tellme-backdrop';
  backdrop.innerHTML = `
    <div class="tellme-panel" role="dialog" aria-label="Tell me what you want to do">
      <input type="text" class="tellme-input" placeholder="Tell me what you want to do" autocomplete="off" spellcheck="false" />
      <div class="tellme-results" role="listbox"></div>
      <div class="tellme-hint"><kbd>&uarr;</kbd><kbd>&darr;</kbd> to move &middot; <kbd>Enter</kbd> to open &middot; <kbd>Esc</kbd> to close</div>
    </div>`;
  document.body.appendChild(backdrop);

  const input = backdrop.querySelector('.tellme-input');
  const resultsEl = backdrop.querySelector('.tellme-results');
  let shown = [];
  let selected = 0;

  const close = () => backdrop.remove();
  const go = (entry, newTab) => {
    if (!entry) return;
    tellMeRemember(entry.href);
    if (newTab) { window.open(entry.href, '_blank'); close(); }
    else location.href = entry.href;
  };

  const row = (entry, i) => `
    <a class="tellme-row${i === selected ? ' selected' : ''}" href="${tellMeEscape(entry.href)}" data-index="${i}" role="option">
      <span class="tellme-row-label">${tellMeEscape(entry.label)}</span>
      <span class="tellme-row-group">${tellMeEscape(entry.group)}</span>
    </a>`;

  function render() {
    const { recent, results } = tellMeSearch(input.value);
    shown = recent.concat(results);
    if (selected >= shown.length) selected = Math.max(0, shown.length - 1);
    let html = '';
    if (recent.length) {
      html += '<div class="tellme-heading">Recent</div>' + recent.map((e, i) => row(e, i)).join('');
    }
    if (results.length) {
      html += `<div class="tellme-heading">${input.value.trim() ? 'Go to Pages' : 'All Pages'}</div>`
        + results.map((e, i) => row(e, i + recent.length)).join('');
    }
    resultsEl.innerHTML = html || '<div class="tellme-empty">No pages match. Try another word.</div>';
    const sel = resultsEl.querySelector('.tellme-row.selected');
    if (sel) sel.scrollIntoView({ block: 'nearest' });
  }

  input.addEventListener('input', () => { selected = 0; render(); });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown') { event.preventDefault(); selected = Math.min(selected + 1, shown.length - 1); render(); }
    else if (event.key === 'ArrowUp') { event.preventDefault(); selected = Math.max(selected - 1, 0); render(); }
    else if (event.key === 'Enter') { event.preventDefault(); go(shown[selected], event.ctrlKey || event.metaKey); }
    else if (event.key === 'Escape') { event.preventDefault(); close(); }
  });
  resultsEl.addEventListener('click', (event) => {
    const a = event.target.closest('.tellme-row');
    if (!a) return;
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.button === 1) return; // browser new tab
    event.preventDefault();
    go(shown[Number(a.dataset.index)], false);
  });
  backdrop.addEventListener('mousedown', (event) => { if (event.target === backdrop) close(); });

  render();
  input.focus();
}

// Lazy-loads js/chat.js on first call rather than requiring every page's <script> list to include
// it - renderTopNav already runs on every authenticated page, so hooking the widget in here means
// one change here instead of editing ~40 HTML files. Safe to call with no session (no-ops).
let chatWidgetScriptPromise = null;
function mountChatWidget(session) {
  if (!session) return;

  if (typeof initChatWidget === 'function') {
    initChatWidget(session);
    return;
  }

  if (!chatWidgetScriptPromise) {
    chatWidgetScriptPromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = 'js/chat.js?v=chatphoto1';
      script.onload = resolve;
      script.onerror = reject;
      document.head.appendChild(script);
    });
  }

  chatWidgetScriptPromise
    .then(() => initChatWidget(session))
    .catch((err) => console.error('Chat: failed to load chat widget', err));
}

// Browser Back/Forward for modals - per "from the transfer order i open the order then when I hit
// back it will go to the production shelf map". Every portal "document" (Transfer Order, Production
// Order, PO, ...) opens as a .modal-backdrop on the list page, which never touched browser history,
// so Back skipped past it to the previous page. Now each modal that opens gets its own history entry:
// Back closes the top modal (via its own close button, so the page's cleanup/unsaved-changes prompt
// still runs), and closing a modal with X/Cancel drops that entry again so Back stays one step.
// A page can set modal.dataset.historyUrl (e.g. '?doc=TO-0001') before showing a modal to also put
// the open document in the URL - then leaving to another page and coming Back reopens it (the page's
// own deep-link handling does the reopening).
(function initModalHistory() {
  if (window.__modalHistoryInit) return;
  window.__modalHistoryInit = true;

  const stack = [];        // [{ el, pushed, baseUrl }] - open modals, oldest first
  let pendingPops = 0;     // our own history.back() calls whose popstate we must ignore
  let queuedPushes = [];   // opens that happened while a back() was still in flight
  const openState = new WeakMap(); // el -> last seen "is open"

  const isOpen = (el) => !el.classList.contains('hidden');
  const currentUrl = () => location.pathname + location.search + location.hash;
  const baseUrlWithout = () => location.pathname + location.hash;

  function targetUrlFor(el) {
    const u = el.dataset.historyUrl;
    if (!u) return null;
    return u.startsWith('?') ? location.pathname + u : u;
  }

  function pushFor(entry) {
    const url = targetUrlFor(entry.el);
    // Deep-link load (the URL already names this document): don't add a duplicate entry - closing it
    // just strips the parameter again instead of stepping Back off the page.
    if (url && url === currentUrl() && stack.length === 1) {
      // Came Back/Forward onto an entry we pushed earlier (fresh load of it): that entry is ours,
      // so closing should step Back to the list entry rather than leave a duplicate behind.
      entry.pushed = !!(history.state && history.state.modalHistory);
      entry.baseUrl = baseUrlWithout();
      return;
    }
    entry.pushed = true;
    entry.baseUrl = currentUrl();
    history.pushState({ modalHistory: stack.length }, '', url || currentUrl());
  }

  function onOpened(el) {
    const entry = { el, pushed: false, baseUrl: null };
    stack.push(entry);
    if (pendingPops > 0) queuedPushes.push(entry);
    else pushFor(entry);
  }

  function onClosed(el) {
    const idx = stack.findIndex((e) => e.el === el);
    if (idx === -1) return; // already removed by a Back press
    const [entry] = stack.splice(idx, 1);
    const q = queuedPushes.indexOf(entry);
    if (q !== -1) { queuedPushes.splice(q, 1); return; }
    if (entry.pushed) {
      pendingPops++;
      history.back();
    } else if (entry.baseUrl && entry.baseUrl !== currentUrl()) {
      history.replaceState(history.state, '', entry.baseUrl);
    }
  }

  function closeModal(el) {
    const btn = Array.from(el.querySelectorAll('.bc-doc-close, button[aria-label="Close"], button[id^="close"], button[id$="CloseBtn"]'))
      .find((b) => b.closest('.modal-backdrop') === el);
    if (btn) btn.click();
    else el.classList.add('hidden');
  }

  window.addEventListener('popstate', () => {
    if (pendingPops > 0) {
      pendingPops--;
      if (pendingPops === 0 && queuedPushes.length) {
        const q = queuedPushes; queuedPushes = [];
        q.forEach((entry) => { if (stack.includes(entry)) pushFor(entry); });
      }
      return;
    }
    const entry = stack.pop();
    if (!entry || !isOpen(entry.el)) return;
    closeModal(entry.el);
    // The close was refused (e.g. "unsaved changes?" -> Cancel): keep the modal and its entry.
    setTimeout(() => {
      if (isOpen(entry.el) && !stack.includes(entry)) {
        stack.push(entry);
        entry.pushed = true;
        history.pushState({ modalHistory: stack.length }, '', targetUrlFor(entry.el) || currentUrl());
      }
    }, 0);
  });

  function scan() {
    document.querySelectorAll('.modal-backdrop').forEach((el) => {
      const was = openState.get(el);
      const now = isOpen(el);
      openState.set(el, now);
      if (was === undefined) { if (now) onOpened(el); return; }
      if (now && !was) onOpened(el);
      else if (!now && was) onClosed(el);
    });
  }

  function start() {
    // Modals already open at load are left alone (no entry) only if they were open before we
    // started watching - record their state first, then react to changes.
    document.querySelectorAll('.modal-backdrop').forEach((el) => openState.set(el, isOpen(el)));
    new MutationObserver(scan).observe(document.body, {
      subtree: true, childList: true, attributes: true, attributeFilter: ['class']
    });
  }

  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);
})();

// "Comet night" sky background (js/nightSkyBg.js draws it once, as a still, on a canvas) on every
// portal page that loads this file, except Dashboard (has its own company photo background) and
// the print-only pages.
(function () {
  const page = (location.pathname.split('/').pop() || '').toLowerCase();
  // gma-conversations.html is a full-width three-panel inbox - a busy background there is distracting.
  // The calculator pages are a full-screen iframe, so the background would never be visible anyway.
  const SKIP = ['dashboard.html', 'gma-conversations.html', 'aquarium-calculator.html', 'stand-calculator.html', 'sticker-calculator.html', 'invoice.html', 'gma-order-invoice.html', 'delivery-receipt.html'];
  if (SKIP.includes(page) || page.includes('print')) return;
  const script = document.createElement('script');
  script.src = 'js/nightSkyBg.js?v=still1';
  script.defer = true;
  (document.head || document.documentElement).appendChild(script);
})();
