// Production links for the compact navs below - a Delivery Team / Online Order Staff account that is
// also a Production Manager (or Tank / Stand Maker) can open the Production pages (see
// canOpenProductionPage in js/auth.js).
function compactProductionLinks(session, activeLabel) {
  if (!(session?.isProductionManager || session?.isOrderMaker)) return '';
  return `
          <a class="topnav-link${activeLabel === 'Production Orders' ? ' active' : ''}" href="production-orders.html">Production Orders</a>${session.isProductionManager ? `
          <a class="topnav-link${activeLabel === 'Finished Production Orders' ? ' active' : ''}" href="production-orders.html?view=finished">Finished</a>` : ''}
          <a class="topnav-link${activeLabel === 'Production Shelf Map' ? ' active' : ''}" href="production-shelf-map.html">Shelf Map</a>`;
}

// Pages every staff login can open (ALL_STAFF_PAGES in js/auth.js) - added to the compact navs below,
// since the full nav further down already lists them under Calculators.
function allStaffLinks(activeLabel) {
  return `
          <a class="topnav-link${activeLabel === 'Aquarium Calculator' ? ' active' : ''}" href="aquarium-calculator.html">Aquarium Calculator</a>`;
}

// Renders the shared top navigation bar into <div id="topnav"></div>.
// Requires: auth.js to be loaded first (for wireLogoutButton, getPortalSession).
function renderTopNav(activeLabel) {
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
          <a class="topnav-link${activeLabel === 'Online Orders' ? ' active' : ''}" href="online-orders.html">Online Orders</a>${compactProductionLinks(session, activeLabel)}${allStaffLinks(activeLabel)}
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
          <a class="topnav-link${activeLabel === 'Production Shelf Map' ? ' active' : ''}" href="production-shelf-map.html">Shelf Map</a>${allStaffLinks(activeLabel)}
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
          <a class="topnav-link${activeLabel === 'Dashboard' ? ' active' : ''}" href="dashboard.html">Dashboard</a>${allStaffLinks(activeLabel)}
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

  const orders = [];
  if (isStoreManager) {
    orders.push({ href: 'transfer-orders.html', label: 'Transfer Orders' });
  } else if (!isSalesOnlyUser) {
    orders.push({ href: 'transfer-orders.html', label: 'Transfer Orders' });
    orders.push({ href: 'posted-transfer-orders.html', label: 'Posted Transfers' });
  }
  orders.push({ href: 'online-orders.html', label: 'Online Orders' });
  orders.push({ href: 'automated-orders.html', label: 'Automated Orders' });
  if (isSuperUser) {
    orders.push({ href: 'advance-orders.html', label: 'Advance Orders' });
  }

  const delivery = [
    { href: 'delivery.html', label: 'Delivery' },
    { href: 'delivery-quote.html', label: 'Delivery Quote' }
  ];
  if (isSuperUser) {
    delivery.push({ href: 'delivery-setup.html', label: 'Delivery Setup' });
  }

  const calculators = [
    { href: 'stand-calculator.html', label: 'Custom Stand' },
    { href: 'aquarium-calculator.html', label: 'Aquarium Calculator' },
    { href: 'repair-calculator.html', label: 'Repair Calculator' },
    { href: 'sticker-calculator.html', label: 'Custom Accessories / Stickers' },
    { href: 'glass-cut-list.html', label: 'Glass Cut List' },
  ];

  const inventory = [];
  if (!isSalesOnlyUser) {
    inventory.push({ href: 'serial-tracker.html', label: 'Serial Tracker' });
  }
  // Per "let the sales user see it as well" - unlike Serial Tracker above, Inventory Summary stays
  // visible to Sales-only users too.
  inventory.push({ href: 'inventory-summary.html', label: 'Inventory Summary' });
  inventory.push({ href: 'stock-on-hand.html', label: 'Stock On Hand' });
  inventory.push({ href: 'shelf-map.html', label: 'Shelf Map' });
  if (!isStoreManager) {
    inventory.push({ href: 'purchase-orders.html', label: 'Purchase Orders' });
    inventory.push({ href: 'posted-purchase-orders.html', label: 'Posted Purchase Orders' });
  }
  // Per "can you show this to manager permission too?" - Physical Inventory Journal is also open to
  // Store Manager accounts (supabase_phys_journal_store_manager_access.sql swapped its RPCs' auth
  // check to allow SuperUser OR StoreManager). Everything else in this super-user-only block stays
  // SuperUser only.
  if (isSuperUser || isStoreManager) {
    inventory.push({ href: 'physical-inventory-journal.html', label: 'Physical Inventory Journal' });
    // Store Managers report (own location, with a photo); Super Users report and approve.
    inventory.push({ href: 'defect-items.html', label: 'Defect Items' });
  }
  if (isSuperUser) {
    // Super users only for now - every RPC behind this page re-checks with is_admin_authorized, so
    // this gate is convenience, not the control.
    inventory.push({ href: 'item-ledger-entries.html', label: 'Item Ledger Entries' });
    inventory.push({ href: 'warehouse-setup.html', label: 'Warehouse Setup' });
    inventory.push({ href: 'item-setup.html', label: 'Item Setup' });
    inventory.push({ href: 'variant-setup.html', label: 'Variants' });
    inventory.push({ href: 'category-setup.html', label: 'Categories' });
    inventory.push({ href: 'vendor-setup.html', label: 'Vendors' });
  }

  // Production (supabase_production_orders.sql) - restock builds; Super User / Production Manager
  // manage them, a Tank / Stand Maker sees only their own. The RPCs re-check the role.
  const production = [];
  if (isSuperUser || session?.isProductionManager || session?.isOrderMaker) {
    production.push({ href: 'production-orders.html', label: 'Production Orders' });
    // Finished ones, in their own list (supabase_production_finished_orders_view.sql) - managers only.
    if (isSuperUser || session?.isProductionManager) {
      production.push({ href: 'production-orders.html?view=finished', label: 'Finished Production Orders' });
    }
    // Where each built unit is stored, by serial (supabase_production_shelf_map.sql).
    production.push({ href: 'production-shelf-map.html', label: 'Production Shelf Map' });
  }
  // Every maker's open assignments, grouped by maker (supabase_maker_assignments_view.sql) - Super
  // Users only; the RPC re-checks with is_admin_authorized.
  if (isSuperUser) {
    production.push({ href: 'maker-assignments.html', label: 'Maker Assignments' });
  }
  // Counting serial-tracked units - same access as the Physical Inventory Journal (its RPCs use
  // is_phys_journal_authorized: Super User or Store Manager).
  if (isSuperUser || isStoreManager) {
    production.push({ href: 'serial-inventory-journal.html', label: 'Serial Inventory Journal' });
  }

  const reports = [];
  if (!isSalesOnlyUser && !isStoreManager) {
    reports.push({ href: 'reports.html', label: 'Reports' });
    reports.push({ href: 'top-selling-items.html', label: 'Top Selling Items' });
    // Black vs Clear sealant variants sold (supabase_sealant_sales_report.sql), same audience.
    reports.push({ href: 'sealant-sales-report.html', label: 'Sealant Sales' });
    // Sales per category, drilling into items / variants (supabase_category_sales_report.sql).
    reports.push({ href: 'category-sales-report.html', label: 'Category Sales' });
    reports.push({ href: 'customer-aquarium.html', label: 'Customer Aquarium' });
  }
  if (isSuperUser) {
    reports.push({ href: 'order-timing-dashboard.html', label: 'Order Timing' });
    reports.push({ href: 'message-timing.html', label: 'Message Timing' });
    reports.push({ href: 'expense-entries.html', label: 'Expenses' });
    reports.push({ href: 'expense-journal.html', label: 'Expense Journal' });
    // Purchases + expenses and each cause's share of the total (supabase_spending_report.sql).
    reports.push({ href: 'spending-report.html', label: 'Purchases & Expenses' });
    // Financials - super users only, matching the Expenses page it draws from. Both RPCs behind
    // these re-check with is_admin_authorized, so this gate is convenience, not the control.
    reports.push({ href: 'gl-entries.html', label: 'General Ledger' });
    // Payment Methods report - super users only; its RPCs re-check with is_admin_authorized.
    reports.push({ href: 'payment-method-report.html', label: 'Payment Methods Report' });
  }

  const admin = [];
  if (isSuperUser) {
    admin.push({ href: 'general-setup.html', label: 'General Setup' });
    admin.push({ href: 'ai-bot-setup.html', label: 'AI Bot Setup' });
  }
  // Conversations Access sees GMA Conversations even without full Super User - same
  // "isSuperUser || is<Flag>" gate the page itself enforces in its own init().
  if (isSuperUser || isConversationsStaff) {
    admin.push({ href: 'gma-conversations.html', label: 'Conversations' });
  }
  if (isSuperUser) {
    admin.push({ href: 'customers.html', label: 'Customers' });
    admin.push({ href: 'ai-bot-sandbox.html', label: 'AI Bot Sandbox' });
    admin.push({ href: 'pricing-setup.html', label: 'Pricing Setup' });
    admin.push({ href: 'payment-methods.html', label: 'Payment Methods' });
    admin.push({ href: 'gl-setup.html', label: 'G/L Setup' });
    admin.push({ href: 'user-setup.html', label: 'User Setup' });
  }
  // Payroll Officer (supabase_staff_users_payroll_officer_field.sql) sees these three even
  // without full Super User - same "isSuperUser || isPayrollOfficer" gate each payroll page itself
  // enforces in its own init().
  if (isSuperUser || isPayrollOfficer) {
    admin.push({ href: 'payroll.html', label: 'Payroll' });
    admin.push({ href: 'payroll-setup.html', label: 'Payroll Setup' });
    admin.push({ href: 'payroll-timesheets.html', label: 'Timesheets' });
    admin.push({ href: 'payroll-ledger.html', label: 'Payroll Ledger' });
    // How much payroll costs, by employee / branch / month (supabase_payroll_spending_report.sql).
    admin.push({ href: 'payroll-spending-report.html', label: 'Payroll Spending' });
  }

  const groups = [
    { label: 'Orders', items: orders },
    { label: 'Delivery', items: delivery },
    { label: 'Calculators', items: calculators },
    { label: 'Inventory', items: inventory },
    { label: 'Production', items: production },
    { label: 'Reports', items: reports },
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
      const itemsHtml = group.items
        .map((item) => {
          const activeClass = item.label === activeLabel ? ' active' : '';
          return `<a class="topnav-link${activeClass}" href="${item.href}">${item.label}</a>`;
        })
        .join('');
      return `
        <div class="topnav-group" data-group-index="${index}">
          <button class="topnav-group-toggle${isActiveGroup ? ' active' : ''}" type="button" aria-expanded="false">
            ${group.label}<span class="topnav-group-caret">&#9662;</span>
          </button>
          <div class="topnav-group-menu">${itemsHtml}</div>
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
      script.src = 'js/chat.js';
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

// "Comet night" animated background (js/nightSkyBg.js draws it on a canvas) on every
// portal page that loads this file, except Dashboard (has its own company photo background) and
// the print-only pages.
(function () {
  const page = (location.pathname.split('/').pop() || '').toLowerCase();
  // gma-conversations.html is a full-width three-panel inbox - a busy background there is distracting.
  // The calculator pages are a full-screen iframe, so the background would never be visible anyway.
  const SKIP = ['dashboard.html', 'gma-conversations.html', 'aquarium-calculator.html', 'stand-calculator.html', 'sticker-calculator.html', 'invoice.html', 'gma-order-invoice.html', 'delivery-receipt.html'];
  if (SKIP.includes(page) || page.includes('print')) return;
  const script = document.createElement('script');
  script.src = 'js/nightSkyBg.js?v=2';
  script.defer = true;
  (document.head || document.documentElement).appendChild(script);
})();
