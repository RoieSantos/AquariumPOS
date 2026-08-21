// Renders the shared top navigation bar into <div id="topnav"></div>.
// Requires: auth.js to be loaded first (for wireLogoutButton, getPortalSession).
function renderTopNav(activeLabel) {
  const nav = document.getElementById('topnav');
  if (!nav) return;

  const session = getPortalSession();

  // Per "if the user is on Delivery team they can only see the Delivery calendar that is all" -
  // js/auth.js's requireAuth() only allows dashboard.html (shows just a "Go to Delivery" link,
  // see js/dashboard.js) and delivery.html itself for this group, so showing the full link list
  // here would just be a wall of dead-end links. Short-circuit to a minimal nav instead -
  // Dashboard + Delivery + Logout, nothing else, no hamburger collapse needed for so few items.
  if (session?.isDeliveryTeam) {
    nav.innerHTML = `
      <div class="topnav-inner">
        <span class="topnav-brand">RS Pet Stop Portal</span>
        <div class="topnav-links" id="topnavLinks">
          <a class="topnav-link${activeLabel === 'Dashboard' ? ' active' : ''}" href="dashboard.html">Dashboard</a>
          <a class="topnav-link${activeLabel === 'Delivery' ? ' active' : ''}" href="delivery.html">Delivery</a>
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
        <div class="topnav-links" id="topnavLinks">
          <a class="topnav-link${activeLabel === 'Dashboard' ? ' active' : ''}" href="dashboard.html">Dashboard</a>
          <a class="topnav-link${activeLabel === 'Online Orders' ? ' active' : ''}" href="online-orders.html">Online Orders</a>
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

  // Dashboard stands alone (not part of any group) since it's the one link everyone reaches for
  // first. Everything else is bucketed by function so the nav reads as a handful of menus instead
  // of a wall of ~20 flat tabs - see the .topnav-group/.topnav-group-menu styles in css/styles.css.
  const standalone = [{ href: 'dashboard.html', label: 'Dashboard' }];

  const orders = [];
  if (!isSalesOnlyUser) {
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
    { href: 'delivery-quote.html', label: 'Delivery Quote' },
  ];
  if (isSuperUser) {
    delivery.push({ href: 'delivery-setup.html', label: 'Delivery Setup' });
  }

  const calculators = [
    { href: 'stand-calculator.html', label: 'Custom Stand' },
    { href: 'aquarium-calculator.html', label: 'Aquarium Calculator' },
    { href: 'sticker-calculator.html', label: 'Custom Accessories / Stickers' },
  ];

  const inventory = [];
  if (!isSalesOnlyUser) {
    inventory.push({ href: 'serial-tracker.html', label: 'Serial Tracker' });
  }
  // Per "let the sales user see it as well" - unlike Serial Tracker above, Inventory Summary stays
  // visible to Sales-only users too.
  inventory.push({ href: 'inventory-summary.html', label: 'Inventory Summary' });
  inventory.push({ href: 'stock-on-hand.html', label: 'Stock On Hand' });
  if (isSuperUser) {
    inventory.push({ href: 'warehouse-setup.html', label: 'Warehouse Setup' });
    inventory.push({ href: 'item-setup.html', label: 'Item Setup' });
    inventory.push({ href: 'variant-setup.html', label: 'Variants' });
    inventory.push({ href: 'category-setup.html', label: 'Categories' });
    inventory.push({ href: 'vendor-setup.html', label: 'Vendors' });
  }

  const reports = [];
  if (!isSalesOnlyUser) {
    reports.push({ href: 'reports.html', label: 'Reports' });
    reports.push({ href: 'top-selling-items.html', label: 'Top Selling Items' });
    reports.push({ href: 'customer-aquarium.html', label: 'Customer Aquarium' });
  }
  if (isSuperUser) {
    reports.push({ href: 'order-timing-dashboard.html', label: 'Order Timing' });
    reports.push({ href: 'expense-entries.html', label: 'Expenses' });
  }

  const admin = [];
  if (isSuperUser) {
    admin.push({ href: 'general-setup.html', label: 'General Setup' });
    admin.push({ href: 'pricing-setup.html', label: 'Pricing Setup' });
    admin.push({ href: 'user-setup.html', label: 'User Setup' });
  }

  const groups = [
    { label: 'Orders', items: orders },
    { label: 'Delivery', items: delivery },
    { label: 'Calculators', items: calculators },
    { label: 'Inventory', items: inventory },
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
