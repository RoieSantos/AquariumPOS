// Renders the shared top navigation bar into <div id="topnav"></div>.
// Requires: auth.js to be loaded first (for wireLogoutButton, getPortalSession).
function renderTopNav(activeLabel) {
  const nav = document.getElementById('topnav');
  if (!nav) return;

  const session = getPortalSession();

  // Per "Sales User dont need to see transfer orders and other related notification for
  // transfers - Remove Serial Tracker/Reports/Customer Aquarium" - a Sales User who is NOT also
  // a super user gets a trimmed top nav too, same set dropped as the dashboard's nav-card grid
  // (see js/dashboard.js's isSalesOnlyUser). Posted Transfers is dropped alongside Transfer
  // Orders since it's the same transfer-order workflow, just the read-only posted view.
  const isSalesOnlyUser = session?.isSalesUser && !session?.isSuperUser;

  const items = [{ href: 'dashboard.html', label: 'Dashboard' }];

  if (!isSalesOnlyUser) {
    items.push({ href: 'transfer-orders.html', label: 'Transfer Orders' });
    items.push({ href: 'posted-transfer-orders.html', label: 'Posted Transfers' });
    items.push({ href: 'reports.html', label: 'Reports' });
    items.push({ href: 'top-selling-items.html', label: 'Top Selling Items' });
    items.push({ href: 'customer-aquarium.html', label: 'Customer Aquarium' });
  }

  items.push({ href: 'stand-calculator.html', label: 'Custom Calculator' });

  if (!isSalesOnlyUser) {
    items.push({ href: 'serial-tracker.html', label: 'Serial Tracker' });
  }

  // Per "let the sales user see it as well" - unlike Serial Tracker above, Inventory Summary stays
  // visible to Sales-only users too.
  items.push({ href: 'inventory-summary.html', label: 'Inventory Summary' });

  items.push({ href: 'online-orders.html', label: 'Online Orders' });
  items.push({ href: 'delivery.html', label: 'Delivery' });

  if (session?.isSuperUser) {
    items.push({ href: 'general-setup.html', label: 'General Setup' });
    items.push({ href: 'warehouse-setup.html', label: 'Warehouse Setup' });
    items.push({ href: 'item-setup.html', label: 'Item Setup' });
    items.push({ href: 'variant-setup.html', label: 'Variants' });
    items.push({ href: 'category-setup.html', label: 'Categories' });
    items.push({ href: 'advance-orders.html', label: 'Advance Orders' });
    items.push({ href: 'expense-entries.html', label: 'Expenses' });
    items.push({ href: 'order-timing-dashboard.html', label: 'Order Timing' });
    items.push({ href: 'vendor-setup.html', label: 'Vendors' });
    items.push({ href: 'user-setup.html', label: 'User Setup' });
  }

  const linksHtml = items
    .map((item) => {
      const activeClass = item.label === activeLabel ? ' active' : '';
      return `<a class="topnav-link${activeClass}" href="${item.href}">${item.label}</a>`;
    })
    .join('');

  nav.innerHTML = `
    <div class="topnav-inner">
      <span class="topnav-brand">RS Pet Stop Portal</span>
      <div class="topnav-links">
        ${linksHtml}
        <button id="logoutBtn" class="topnav-logout" type="button">Logout</button>
      </div>
    </div>
  `;

  wireLogoutButton('logoutBtn');
}
