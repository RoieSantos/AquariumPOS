// System Tests - who can open which page (docs/js/auth.js) and what the menu shows each role
// (docs/js/nav.js). Pure logic: fake logins, no database.
//
// Two things break here when pages are added fast:
//   1. A menu link the role can't actually open - clicking it bounces them back to their landing
//      page (canOpenPortalPage is the same lockdown requireAuth applies).
//   2. A sensitive page (payroll, users, settings, finance) showing up for, or opening for, a role
//      that shouldn't have it.
(function () {
  const BASE_SESSION = { username: 'system-test', displayName: 'System Test', password: 'x', staffRoles: [] };

  const ROLES = {
    'Super User': { isSuperUser: true },
    'Sales User': { isSalesUser: true },
    'Payroll Officer': { isPayrollOfficer: true },
    'Serial Admin': { isSerialAdmin: true },
    'Production Member': { isProductionMember: true },
    'Production Manager': { isProductionManager: true, staffRoles: ['ProductionManager'] },
    'Conversations Staff': { isConversationsStaff: true },
    'Store Manager': { isStoreManager: true },
    'Store Manager + Conversations': { isStoreManager: true, isConversationsStaff: true },
    'Delivery Team': { isDeliveryTeam: true },
    'Delivery Team + Production Manager': { isDeliveryTeam: true, isProductionManager: true, staffRoles: ['ProductionManager'] },
    'Online Order Staff': { isOnlineOrderStaff: true },
    'Tank Maker (no other access)': { isOrderMaker: true, staffRoles: ['TankMaker'] },
    'No permissions ticked': {}
  };

  // Owner-only pages: settings, users, money. Payroll pages are also open to a Payroll Officer.
  const SUPER_USER_ONLY_PAGES = [
    'user-setup.html', 'general-setup.html', 'pricing-setup.html', 'ai-bot-setup.html', 'ai-bot-sandbox.html',
    'gl-entries.html', 'gl-setup.html', 'owner-funds.html', 'expense-entries.html', 'expense-journal.html', 'tender-declarations.html',
    'business-bills.html', 'payment-methods.html', 'system-tests.html'
  ];
  const PAYROLL_PAGES = ['payroll.html', 'payroll-setup.html', 'payroll-timesheets.html', 'payroll-ledger.html', 'payroll-run.html'];

  // Roles that are confined to an allowlist in auth.js (they must not be able to OPEN these pages).
  const LOCKED_DOWN_ROLES = ['Store Manager', 'Delivery Team', 'Online Order Staff', 'Tank Maker (no other access)', 'No permissions ticked'];

  function sessionFor(role) {
    return { ...BASE_SESSION, ...ROLES[role] };
  }

  // Renders the real menu for a fake session into a detached box and returns its page links.
  // nav.js reads getPortalSession() and looks elements up by id, so both are pointed at the box for
  // the duration - the real top bar on this page is never touched.
  function menuPagesFor(session) {
    const box = document.createElement('div');
    const realGetElementById = document.getElementById;
    const saved = { getPortalSession: window.getPortalSession, mountChatWidget: window.mountChatWidget, wireLogoutButton: window.wireLogoutButton };
    try {
      document.getElementById = (id) => (id === 'topnav' ? box : box.querySelector(`[id="${id}"]`));
      window.getPortalSession = () => session;
      window.mountChatWidget = () => {};
      window.wireLogoutButton = () => {};
      renderTopNavLinks('');
    } finally {
      document.getElementById = realGetElementById;
      Object.assign(window, saved);
    }
    return [...new Set([...box.querySelectorAll('a[href]')].map((link) => link.getAttribute('href').split('?')[0]))];
  }
  window.SystemTestsMenuPagesFor = menuPagesFor; // used by databaseChecks.js to crawl every page

  SystemTests.suite('Page access per role', {
    kind: 'logic',
    description: 'For a fake login of each role: every menu link opens (no bounce back), and owner-only pages stay hidden and locked.'
  }, (t) => {
    Object.keys(ROLES).forEach((role) => {
      t.test(`${role}: every menu link opens`, (a) => {
        const session = sessionFor(role);
        const pages = menuPagesFor(session);
        a.ok(pages.length > 0, 'menu has no links');
        const bounced = pages.filter((page) => !canOpenPortalPage(session, page));
        a.ok(bounced.length === 0, `menu shows page(s) this role gets bounced from: ${bounced.join(', ')}`);
      });
    });

    Object.keys(ROLES).filter((role) => role !== 'Super User').forEach((role) => {
      t.test(`${role}: no owner-only pages in the menu`, (a) => {
        const session = sessionFor(role);
        const allowed = session.isPayrollOfficer ? [] : PAYROLL_PAGES;
        const leaked = menuPagesFor(session).filter((page) => SUPER_USER_ONLY_PAGES.includes(page) || allowed.includes(page));
        a.ok(leaked.length === 0, `menu shows: ${leaked.join(', ')}`);
      });
    });

    LOCKED_DOWN_ROLES.forEach((role) => {
      t.test(`${role}: can't open owner-only or payroll pages by URL`, (a) => {
        const session = sessionFor(role);
        const open = [...SUPER_USER_ONLY_PAGES, ...PAYROLL_PAGES].filter((page) => canOpenPortalPage(session, page));
        a.ok(open.length === 0, `can open: ${open.join(', ')}`);
      });
    });

    t.test('Every role can open the Aquarium Calculator and My Payslips', (a) => {
      Object.keys(ROLES).forEach((role) => {
        const session = sessionFor(role);
        a.ok(canOpenPortalPage(session, 'aquarium-calculator.html'), `${role} can't open aquarium-calculator.html`);
        a.ok(canOpenPortalPage(session, 'my-payslips.html'), `${role} can't open my-payslips.html`);
      });
    });

    t.test('Delivery Team can open the print pages behind the Delivery screen', (a) => {
      const session = sessionFor('Delivery Team');
      ['delivery.html', 'delivery-receipt.html', 'invoice.html', 'job-order.html'].forEach((page) => {
        a.ok(canOpenPortalPage(session, page), `can't open ${page}`);
      });
    });

    t.test('Tank Maker can open their assignments and production pages only', (a) => {
      const session = sessionFor('Tank Maker (no other access)');
      ['online-orders.html', 'production-orders.html', 'production-shelf-map.html'].forEach((page) => {
        a.ok(canOpenPortalPage(session, page), `can't open ${page}`);
      });
      ['dashboard.html', 'delivery.html', 'stock-on-hand.html', 'customers.html'].forEach((page) => {
        a.ok(!canOpenPortalPage(session, page), `can open ${page}`);
      });
    });
  });
})();
