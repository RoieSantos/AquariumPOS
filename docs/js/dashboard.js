// Dashboard page logic: welcome greeting + a notification center (attention-needed items, e.g.
// unshipped Transfer Orders - see loadNotifications) + Online Orders status overview cards, plus
// (super users only) "Amount to Receive" / "Total Sales This Month" financial cards and a
// "Monthly Sales Target" progress card (% achieved + amount still needed). The target itself
// (28,000/day * number of days in the current month) is computed server-side in
// admin_get_online_order_financial_summary() so it always matches the same Asia/Manila month
// boundaries used for month_sales, regardless of the viewer's own browser timezone.
//
// The status counts come from admin_get_online_order_status_summary(), and the financial
// figures come from admin_get_online_order_financial_summary() - both read the persisted
// public.OnlineOrders table (kept fresh by the background sync) - NOT a live Pancake fetch -
// so these are fast, simple queries with no pagination/timeout concerns. Reuses the password
// captured at login (session.password, see auth.js) the same way the Online Orders page
// does, so no re-unlock prompt is needed here either.

// Running tallies for the "Projected Profit This Month" card - each load*Summary function below
// fills in its own slice as it resolves, and renderProfitCard() (called after all of them finish)
// combines them. Kept as plain numbers (not read back from the DOM) so the math isn't sensitive to
// formatCurrency's string formatting.
const monthlyTotals = { sales: 0, expense: 0, purchase: 0, payroll: 0 };

// Light/Dark buttons that call js/theme.js's setPortalTheme - the theme itself is applied on
// every portal page by theme.js at load time (from localStorage), these two buttons are just the
// only UI that ever changes the saved choice, per "have like a dark motif and light motif button
// on the dashboard .. this will be apply across all pages".
function wireThemeToggle() {
  const group = document.getElementById('themeToggleGroup');
  if (!group) return;

  const refreshActiveState = () => {
    const current = document.documentElement.getAttribute('data-theme') || 'light';
    group.querySelectorAll('.theme-toggle-btn').forEach((btn) => {
      btn.classList.toggle('active', btn.dataset.themeChoice === current);
    });
  };

  group.addEventListener('click', (e) => {
    const btn = e.target.closest('.theme-toggle-btn');
    if (!btn) return;
    setPortalTheme(btn.dataset.themeChoice);
    refreshActiveState();
  });

  refreshActiveState();
}

function setStatValue(elementId, value) {
  const el = document.getElementById(elementId);
  if (el) el.textContent = value === null || value === undefined ? '0' : String(value);
}

function formatCurrency(amount) {
  const value = Number(amount) || 0;
  return '₱' + value.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function updateSalesTargetTile(monthSales, monthSalesTarget) {
  const card = document.getElementById('salesTargetCard');
  if (!card) return;

  const target = Number(monthSalesTarget) || 0;
  if (target <= 0) {
    card.classList.add('hidden');
    return;
  }
  card.classList.remove('hidden');

  const sales = Number(monthSales) || 0;
  const rawPercent = (sales / target) * 100;
  const displayPercent = Math.max(0, Math.min(100, rawPercent));
  const fillEl = document.getElementById('targetProgressFill');
  fillEl.style.width = `${displayPercent}%`;
  fillEl.classList.toggle('target-over', rawPercent >= 100);

  document.getElementById('targetPercentValue').textContent = `${Math.round(rawPercent)}%`;

  const remaining = target - sales;
  const detailEl = document.getElementById('targetProgressDetail');
  detailEl.textContent = remaining > 0
    ? `${formatCurrency(remaining)} more needed to reach the ${formatCurrency(target)} target`
    : `Target reached! ${formatCurrency(sales - target)} over the ${formatCurrency(target)} target`;
}

async function loadFinancialSummary(session) {
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_online_order_financial_summary', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_online_order_financial_summary failed:', error);
    return;
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return;

  // "Total Sales" for the profit card is the combined "Total Sales This Month" card's figure
  // (Online + Walk-In) - per "Projected Profit this month formula should be take from Total Sales
  // This month not the online sales this month". The two halves are disjoint (ReceivedAtShop
  // true vs not true in the RPC), so summing them never double-counts an order.
  const totalSales = (Number(row.month_sales) || 0) + (Number(row.walkin_sales_month) || 0);
  monthlyTotals.sales = totalSales;

  document.getElementById('statMonthSales').textContent = formatCurrency(row.month_sales);

  const monthLabel = new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' });

  // "Amount Paid This Month" / "Amount to Receive This Month" - this month's online orders split
  // into what's been paid and what's still owed (replaces the old all-time Amount to Receive card).
  const paidCount = row.month_paid_order_count || 0;
  setStatValue('statMonthAmountPaid', formatCurrency(row.month_amount_paid));
  const paidSubEl = document.getElementById('statMonthAmountPaidSub');
  if (paidSubEl) paidSubEl.textContent = `${monthLabel} · ${paidCount} ${paidCount === 1 ? 'order' : 'orders'} with payment`;

  const toReceiveCount = row.month_to_receive_order_count || 0;
  setStatValue('statAmountToReceive', formatCurrency(row.month_amount_to_receive));
  const toReceiveSubEl = document.getElementById('statAmountToReceiveSub');
  if (toReceiveSubEl) toReceiveSubEl.textContent = `${monthLabel} · ${toReceiveCount} unpaid ${toReceiveCount === 1 ? 'order' : 'orders'}`;
  const orderCount = row.month_order_count || 0;
  const orderWord = orderCount === 1 ? 'order' : 'orders';
  document.getElementById('statMonthSalesSub').textContent = `${monthLabel} · ${orderCount} ${orderWord} so far`;

  document.getElementById('statWalkInSales').textContent = formatCurrency(row.walkin_sales_month);
  const walkinCount = row.walkin_order_count || 0;
  const walkinWord = walkinCount === 1 ? 'order' : 'orders';
  document.getElementById('statWalkInSalesSub').textContent = `${monthLabel} · ${walkinCount} ${walkinWord} so far`;

  // "Total Sales This Month" = Online + Walk-In, summed from the two figures above (same RPC row,
  // so it always matches the two cards beside it). Also feeds the Profit card via monthlyTotals.sales.
  setStatValue('statMonthTotalSales', formatCurrency(totalSales));
  const totalSalesSubEl = document.getElementById('statMonthTotalSalesSub');
  if (totalSalesSubEl) {
    totalSalesSubEl.textContent =
      `${monthLabel} · Online ${formatCurrency(row.month_sales)} + Walk-In ${formatCurrency(row.walkin_sales_month)}`;
  }

  // Mirrors the super-user "Walk-In Sales This Month" card above, for the standalone card shown
  // to regular (non-sales, non-super) staff - see walkInOnlyCard gating below.
  setStatValue('statWalkInSalesOnly', formatCurrency(row.walkin_sales_month));
  const walkInSalesOnlySubEl = document.getElementById('statWalkInSalesOnlySub');
  if (walkInSalesOnlySubEl) walkInSalesOnlySubEl.textContent = `${monthLabel} · ${walkinCount} ${walkinWord} so far`;

  const todayLabel = new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });

  document.getElementById('statTodayOnlineSales').textContent = formatCurrency(row.today_online_sales);
  const todayOnlineCount = row.today_online_order_count || 0;
  const todayOnlineWord = todayOnlineCount === 1 ? 'order' : 'orders';
  document.getElementById('statTodayOnlineSalesSub').textContent = `${todayLabel} · ${todayOnlineCount} ${todayOnlineWord}`;

  document.getElementById('statTodayWalkInSales').textContent = formatCurrency(row.today_walkin_sales);
  const todayWalkinCount = row.today_walkin_order_count || 0;
  const todayWalkinWord = todayWalkinCount === 1 ? 'order' : 'orders';
  document.getElementById('statTodayWalkInSalesSub').textContent = `${todayLabel} · ${todayWalkinCount} ${todayWalkinWord}`;

  // Mirrors of the above, for the standalone cards shown to regular (non-sales, non-super)
  // staff - see walkInOnlyCard gating below. setStatValue no-ops when an id isn't on the page.
  setStatValue('statTodayWalkInSalesOnly', formatCurrency(row.today_walkin_sales));
  const todayWalkInSalesOnlySubEl = document.getElementById('statTodayWalkInSalesOnlySub');
  if (todayWalkInSalesOnlySubEl) todayWalkInSalesOnlySubEl.textContent = `${todayLabel} · ${todayWalkinCount} ${todayWalkinWord}`;

  const prevMonthDate = new Date();
  prevMonthDate.setDate(1);
  prevMonthDate.setMonth(prevMonthDate.getMonth() - 1);
  const prevMonthLabel = prevMonthDate.toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  const prevMonthWalkinCount = row.previous_month_walkin_order_count || 0;
  const prevMonthWalkinWord = prevMonthWalkinCount === 1 ? 'order' : 'orders';
  setStatValue('statPrevMonthWalkInSalesOnly', formatCurrency(row.previous_month_walkin_sales));
  const prevMonthWalkInSalesOnlySubEl = document.getElementById('statPrevMonthWalkInSalesOnlySub');
  if (prevMonthWalkInSalesOnlySubEl) prevMonthWalkInSalesOnlySubEl.textContent = `${prevMonthLabel} · ${prevMonthWalkinCount} ${prevMonthWalkinWord}`;

  // Monthly Sales Target card is super-user only - loadFinancialSummary also runs for plain staff
  // (walk-in-only card), who must not see the target/progress.
  updateSalesTargetTile(row.month_sales, session.isSuperUser ? row.month_sales_target : 0);
}

// Two-letter initials for the staff avatar circle, e.g. "Juan Dela Cruz" -> "JD".
function staffInitials(displayName) {
  const parts = (displayName || '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '?';
  return parts.slice(0, 2).map((p) => p[0].toUpperCase()).join('');
}

// Each figure links to Online Orders pre-filtered to this staff member + period (see
// onlineOrders.js's confirmedBy/period URL handling and admin_list_online_orders's matching
// p_confirmed_by/p_period params in supabase_orders_sync_tables.sql).
function staffStatLinkHtml(displayName, period, label, amount, count) {
  const href = `online-orders.html?confirmedBy=${encodeURIComponent(displayName)}&period=${period}`;
  const orderWord = count === 1 ? 'order' : 'orders';
  return `
    <a class="staff-sales-stat" href="${href}">
      <div class="staff-stat-label">${label}</div>
      <div class="staff-stat-value">${formatCurrency(amount)}</div>
      <div class="staff-stat-count">${count || 0} ${orderWord}</div>
    </a>
  `;
}

// Rank badge (top-right of each card) - per "add a ranking in the dashboard base on the metrics
// of the sales user". Ranked by monthly_sales (the same figure the dashboard's other cards treat
// as the headline metric - Total Sales This Month, the target progress bar above), computed
// client-side in loadSalesByStaff below since admin_get_sales_by_confirmed_by returns rows
// ordered by display_name (needed for stable listing regardless of rank changes). Top 3 get a
// medal emoji; everyone else gets a plain "#N".
function staffRankBadgeHtml(rank) {
  const medal = rank === 1 ? '🥇' : rank === 2 ? '🥈' : rank === 3 ? '🥉' : null;
  const topClass = rank <= 3 ? ' staff-rank-badge-top' : '';
  return `<div class="staff-rank-badge${topClass}" title="Rank #${rank} by sales this month">${medal || '#' + rank}</div>`;
}

// Per-staff monthly target progress block, shown under a card's stat tiles - per "I want to see
// their sales target per sales staff and how many % already they accomplish". Only rendered when
// that staff member actually has a target set (StaffUsers.MonthlySalesTarget > 0, set in User
// Setup) - a staff member without one just gets the plain stat tiles above, same "hide instead of
// showing a meaningless 0%" convention as the site-wide target card (updateSalesTargetTile).
function staffTargetHtml(monthlySales, target) {
  const targetValue = Number(target) || 0;
  if (targetValue <= 0) return '';

  const sales = Number(monthlySales) || 0;
  const rawPercent = (sales / targetValue) * 100;
  const displayPercent = Math.max(0, Math.min(100, rawPercent));
  const overClass = rawPercent >= 100 ? ' staff-target-fill-over' : '';

  return `
    <div class="staff-sales-target">
      <div class="staff-target-row">
        <span>Monthly Target</span>
        <span class="staff-target-percent">${Math.round(rawPercent)}%</span>
      </div>
      <div class="staff-target-track">
        <div class="staff-target-fill${overClass}" style="width:${displayPercent}%;"></div>
      </div>
      <div class="staff-target-sub">${formatCurrency(sales)} of ${formatCurrency(targetValue)}</div>
    </div>
  `;
}

// "Sales by Staff (Confirmed By)" cards - one per Sales User (StaffUsers.SalesUser = true),
// matched to their online orders via admin_get_sales_by_confirmed_by() (lower/trim-matched
// ConfirmedBy = DisplayName - see that function's comment in supabase_orders_sync_tables.sql for
// why this is a text match, not a foreign key). Not warehouse-scoped, unlike the cards above -
// a Sales User's confirmations aren't tied to a single warehouse the way orders are.
async function loadSalesByStaff(session) {
  const grid = document.getElementById('salesByStaffGrid');
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_sales_by_confirmed_by', {
    p_admin_username: session.username,
    p_admin_password: session.password
  });

  if (error) {
    console.error('admin_get_sales_by_confirmed_by failed:', error);
    grid.innerHTML = `<p class="error-text">${error.message}</p>`;
    return;
  }

  const rows = data || [];
  if (rows.length === 0) {
    grid.innerHTML = '<p class="muted">No staff are flagged as a Sales User yet - set that in User Setup.</p>';
    return;
  }

  // Ranked by monthly sales, highest first (ties broken alphabetically for a stable order) -
  // admin_get_sales_by_confirmed_by itself returns rows ordered by display_name, so ranking is
  // computed here rather than server-side.
  const rankedRows = [...rows].sort((a, b) => {
    const diff = (Number(b.monthly_sales) || 0) - (Number(a.monthly_sales) || 0);
    return diff !== 0 ? diff : (a.display_name || '').localeCompare(b.display_name || '');
  });

  grid.innerHTML = rankedRows
    .map((r, index) => `
      <div class="staff-sales-card">
        <div class="staff-sales-header">
          <div class="staff-sales-identity">
            <div class="staff-sales-avatar">${staffInitials(r.display_name)}</div>
            <div class="staff-sales-name">${r.display_name || ''}</div>
          </div>
          ${staffRankBadgeHtml(index + 1)}
        </div>
        <div class="staff-sales-stats">
          ${staffStatLinkHtml(r.display_name, 'today', 'Daily', r.daily_sales, r.daily_order_count)}
          ${staffStatLinkHtml(r.display_name, 'month', 'Monthly', r.monthly_sales, r.monthly_order_count)}
          ${staffStatLinkHtml(r.display_name, 'prevmonth', 'Prev. Month', r.previous_month_sales, r.previous_month_order_count)}
        </div>
        ${staffTargetHtml(r.monthly_sales, r.monthly_sales_target)}
      </div>
    `)
    .join('');
}

// "Expense This Month" / "Expense Today" cards, sourced from admin_get_expense_entry_summary()
// (supabase_expense_entry_tables.sql) - same Asia/Manila month/day boundaries as
// loadFinancialSummary above, so the two sections always agree on what "this month"/"today"
// means regardless of the viewer's own browser timezone.
//
async function loadExpenseSummary(session) {
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_expense_entry_summary', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_expense_entry_summary failed:', error);
    return;
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return;

  monthlyTotals.expense = Number(row.month_expense) || 0;

  const monthLabel = new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  const todayLabel = new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });

  document.getElementById('statMonthExpense').textContent = formatCurrency(row.month_expense);
  const monthCount = row.month_expense_count || 0;
  const monthWord = monthCount === 1 ? 'entry' : 'entries';
  document.getElementById('statMonthExpenseSub').textContent = `${monthLabel} · ${monthCount} ${monthWord} so far`;

  document.getElementById('statTodayExpense').textContent = formatCurrency(row.today_expense);
  const todayCount = row.today_expense_count || 0;
  const todayWord = todayCount === 1 ? 'entry' : 'entries';
  document.getElementById('statTodayExpenseSub').textContent = `${todayLabel} · ${todayCount} ${todayWord}`;
}

// Per-warehouse split under the three Daily cards - per "i want see how much is from each
// warehouse". admin_get_dashboard_daily_by_warehouse (supabase_dashboard_daily_by_warehouse.sql)
// uses the same "today" rules as the cards' own totals, so the rows add up to the headline figure.
// A card with nothing today keeps its breakdown hidden.
function escapeDashboardHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function renderWarehouseBreakdown(elementId, rows, amountKey, countKey) {
  const el = document.getElementById(elementId);
  if (!el) return;
  const lines = rows
    .filter((r) => (Number(r[countKey]) || 0) > 0)
    .sort((a, b) => (Number(b[amountKey]) || 0) - (Number(a[amountKey]) || 0));
  el.innerHTML = lines
    .map((r) => `
      <div class="finance-breakdown-row">
        <span class="finance-breakdown-name">${escapeDashboardHtml(r.warehouse_name)}</span>
        <span class="finance-breakdown-value">${formatCurrency(r[amountKey])} <span class="finance-breakdown-count">(${Number(r[countKey]) || 0})</span></span>
      </div>
    `)
    .join('');
  el.classList.toggle('hidden', lines.length === 0);
}

async function loadDailyByWarehouse(session) {
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_dashboard_daily_by_warehouse', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_dashboard_daily_by_warehouse failed:', error);
    return;
  }

  renderWarehouseBreakdown('statTodayOnlineSalesByWh', data, 'online_sales', 'online_order_count');
  renderWarehouseBreakdown('statTodayWalkInSalesByWh', data, 'walkin_sales', 'walkin_order_count');
  renderWarehouseBreakdown('statTodayExpenseByWh', data, 'expense', 'expense_count');
}

// "Total Purchase" card, sourced from admin_get_purchase_summary()
// (supabase_item_cost_and_po_line_cost.sql) - the same Asia/Manila month boundary as
// loadExpenseSummary/loadFinancialSummary above, so all three sections agree on "this month".
//
// Counts POSTED purchase orders only, costed against Qty Received, and dated by the PO's
// posting date (PostedAtUtc, Manila time) - see the RPC for why each of those was chosen.
async function loadPurchaseSummary(session) {
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_purchase_summary', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_purchase_summary failed:', error);
    return;
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return;

  monthlyTotals.purchase = Number(row.month_purchase) || 0;

  const monthLabel = new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  document.getElementById('statTotalPurchase').textContent = formatCurrency(row.month_purchase);

  const poCount = row.month_po_count || 0;
  const poWord = poCount === 1 ? 'PO' : 'POs';
  const uncosted = row.month_uncosted_po_count || 0;

  // An uncosted received line contributes zero, so without this note the card would silently
  // understate purchases and read like a bug rather than missing data.
  const uncostedNote = uncosted > 0
    ? ` · ${uncosted} not fully costed`
    : '';

  document.getElementById('statTotalPurchaseSub').textContent =
    `${monthLabel} · ${poCount} ${poWord} so far${uncostedNote}`;
}

// "Payroll This Month" card, sourced from admin_get_payroll_month_summary()
// (supabase_payroll_month_summary.sql) - per "after the finalize payroll run i want to show it
// here .. so I can track how much is the salary spent for this month." Sums NetPay ledger rows
// (take-home pay) posted at Finalize time, for runs whose Pay Date falls in the current month -
// same Asia/Manila month boundary as the other finance cards.
async function loadPayrollSummary(session) {
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_payroll_month_summary', {
    p_admin_username: session.username,
    p_admin_password: session.password
  });

  if (error || !data) {
    console.error('admin_get_payroll_month_summary failed:', error);
    return;
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return;

  monthlyTotals.payroll = Number(row.month_payroll) || 0;

  const monthLabel = new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  document.getElementById('statMonthPayroll').textContent = formatCurrency(row.month_payroll);

  const empCount = row.month_payroll_employee_count || 0;
  const empWord = empCount === 1 ? 'employee' : 'employees';
  document.getElementById('statMonthPayrollSub').textContent =
    `${monthLabel} · ${empCount} ${empWord} paid so far`;
}

// "Projected Profit This Month" card - "Projected Profit = Total sales - (Expense + total
// purchase + payroll)", where Total Sales is the combined "Total Sales This Month" card's figure
// (Online + Walk-In). Purely a client-side
// combination of the four numbers already loaded above - call this only after all four
// load*Summary calls have resolved, so monthlyTotals is fully populated (a call before then would
// just show ₱0.00 minus whatever happened to load first).
function renderProfitCard() {
  const profit = monthlyTotals.sales - monthlyTotals.expense - monthlyTotals.purchase - monthlyTotals.payroll;
  document.getElementById('statMonthProfit').textContent = formatCurrency(profit);
  document.getElementById('profitCard').classList.toggle('finance-loss', profit < 0);

  const monthLabel = new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  document.getElementById('statMonthProfitSub').textContent =
    `${monthLabel} · ${formatCurrency(monthlyTotals.sales)} sales - ${formatCurrency(monthlyTotals.expense)} expense - ${formatCurrency(monthlyTotals.purchase)} purchase - ${formatCurrency(monthlyTotals.payroll)} payroll`;
}

async function loadStatusSummary(session) {
  if (!session.password) {
    // Stale session from before login started capturing the password - just leave the
    // cards at their placeholder dashes rather than blocking the whole dashboard.
    return;
  }

  const { data, error } = await supabaseClient.rpc('admin_get_online_order_status_summary', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_online_order_status_summary failed:', error);
    return;
  }

  const countsByLabel = {};
  data.forEach((row) => {
    countsByLabel[row.status_label] = row.order_count;
  });

  setStatValue('statConfirmed', countsByLabel['Confirmed']);
  setStatValue('statPrinted', countsByLabel['Printed']);
  setStatValue('statToShip', countsByLabel['To Ship']);
  setStatValue('statShipped', countsByLabel['Shipped']);
  setStatValue('statCancelled', countsByLabel['Cancelled']);
}

// Notification center - surfaces attention-needed items. Starts with just one: Requested
// transfer orders (created but not yet shipped) scoped to the staff's own warehouse, mirroring
// the default From/To warehouse filter transferOrders.js applies on its own list page. Reads
// Transfer_Header directly (RLS already permits anon read on this table, same as the Transfer
// Orders page itself) rather than a new RPC, since this is a simple unauthenticated-safe count -
// no password-gated logic needed. Filters client-side rather than a server-side OR filter,
// matching the same pattern transferOrders.js's own renderHeaders() uses.
function renderNotifications(items) {
  const container = document.getElementById('notificationCenter');
  if (!items || items.length === 0) {
    container.classList.add('hidden');
    container.innerHTML = '';
    return;
  }

  container.innerHTML = items
    .map((item) => `
      <div class="notification-item">
        <div class="notification-message"><span class="notification-icon">${item.icon}</span> ${item.message}</div>
        <a class="notification-action" href="${item.href}">Open now</a>
      </div>
    `)
    .join('');
  container.classList.remove('hidden');
}

async function loadNotifications(session) {
  const notifications = [];

  const { data, error } = await supabaseClient
    .from('Transfer_Header')
    .select('*')
    .eq('"Status"', 'Requested');

  if (error) {
    console.error('Failed to load transfer order notifications:', error);
  } else {
    let rows = data || [];
    if (session.warehouseName) {
      rows = rows.filter((r) =>
        (r['From Warehouse'] || '') === session.warehouseName ||
        (r['To Warehouse'] || '') === session.warehouseName
      );
    }
    if (rows.length > 0) {
      notifications.push({
        icon: '📦',
        message: `You have ${rows.length} Requested transfer order${rows.length === 1 ? '' : 's'} needing attention`,
        href: 'transfer-orders.html?status=Requested'
      });
    }
  }

  // Shipped and awaiting receipt - receiving happens at the destination (To) warehouse, so unlike
  // the Requested notification above (which can be actioned from either side), this only fires
  // for staff at the To warehouse. Deliberately excludes 'Partial Received' (something's already
  // been received against it, so it's no longer purely "waiting") - per direct instruction, only
  // 'In-Transit' and 'Partial Shipped' count here.
  const { data: receivingData, error: receivingError } = await supabaseClient
    .from('Transfer_Header')
    .select('*')
    .in('"Status"', ['Partial Shipped', 'In-Transit']);

  if (receivingError) {
    console.error('Failed to load transfer order receiving notifications:', receivingError);
  } else {
    let receivingRows = receivingData || [];
    if (session.warehouseName) {
      receivingRows = receivingRows.filter((r) => (r['To Warehouse'] || '') === session.warehouseName);
    }
    if (receivingRows.length > 0) {
      notifications.push({
        icon: '📥',
        // Deep-links to the "Awaiting Receipt" multi-status filter option (transfer-orders.html's
        // statusFilter dropdown / renderHeaders() in transferOrders.js) so the list is narrowed to
        // exactly the same In-Transit + Partial Shipped set this notification counted.
        message: `You have ${receivingRows.length} transfer order${receivingRows.length === 1 ? '' : 's'} waiting to be received`,
        href: `transfer-orders.html?status=${encodeURIComponent('In-Transit,Partial Shipped')}`
      });
    }
  }

  renderNotifications(notifications);
}

// Production group cards - admin_get_production_dashboard_summary
// (sql/supabase_dashboard_production_summary.sql). Counts stay "-" if that SQL isn't run yet.
async function loadProductionSummary(session) {
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_production_dashboard_summary', {
    p_admin_username: session.username,
    p_admin_password: session.password
  });

  if (error || !data) {
    console.error('admin_get_production_dashboard_summary failed:', error);
    return;
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return;

  const fmt = (n) => (Number(n) || 0).toLocaleString('en-US', { maximumFractionDigits: 2 });
  document.getElementById('statProdOpen').textContent = fmt(row.open_count);
  document.getElementById('statProdReleased').textContent = fmt(row.released_count);
  document.getElementById('statProdOverdue').textContent = fmt(row.overdue_count);
  document.getElementById('statProdFinishedMonth').textContent = fmt(row.finished_month_count);
  document.getElementById('statProdOutputMonth').textContent = fmt(row.output_month_qty);
  document.getElementById('statProdOverdue').closest('.finance-card')
    .classList.toggle('finance-loss', Number(row.overdue_count) > 0);
}

// Production group's Maker Assignments summary - per "in production group i want to see the
// makers assignment reports as well high level". Same RPC and counting rules as
// js/makerAssignments.js's renderStatCards (rows with no source are idle makers), plus a
// one-row-per-maker table; each maker links to maker-assignments.html?maker=... for the detail.
// The "PO Tasks Built / PO Units (Month)" columns - per "in the maker view can we show the no. of
// task build on production order as well" - come from admin_get_maker_production_built
// (sql/supabase_dashboard_production_summary.sql); they show "-" if that SQL isn't run yet.
async function loadMakerAssignmentSummary(session) {
  const tbody = document.getElementById('dashMakerTableBody');
  if (!session.password) return;

  const auth = { p_admin_username: session.username, p_admin_password: session.password };
  const [{ data, error }, built] = await Promise.all([
    supabaseClient.rpc('admin_list_maker_assignments', auth),
    supabaseClient.rpc('admin_get_maker_production_built', auth)
  ]);
  if (built.error) console.error('admin_get_maker_production_built failed:', built.error);
  const builtByMaker = new Map((built.data || []).map(b => [b.maker, b]));

  if (error) {
    console.error('admin_list_maker_assignments failed:', error);
    tbody.innerHTML = `<tr><td colspan="8" class="error-text">${escapeDashboardHtml(error.message)}</td></tr>`;
    return;
  }

  const rows = data || [];
  const work = rows.filter(r => r.source);
  const count = (s) => work.filter(r => r.part_status === s).length;
  const pendingTank = work.filter(r => r.part_status === 'Pending' && r.part === 'tank').length;
  const pendingStand = work.filter(r => r.part_status === 'Pending' && r.part === 'stand').length;
  const busy = new Set(work.filter(r => r.part_status !== 'Done').map(r => r.maker)).size;
  const allMakers = new Set(rows.map(r => r.maker)).size;

  document.getElementById('statMakerPending').textContent = count('Pending');
  document.getElementById('statMakerPendingSub').textContent = `${pendingTank} tank · ${pendingStand} stand`;
  document.getElementById('statMakerRework').textContent = count('Rework');
  document.getElementById('statMakerDone').textContent = count('Done');
  document.getElementById('statMakerBusy').textContent = `${busy} / ${allMakers}`;

  const makers = new Map();
  for (const r of rows) {
    if (!makers.has(r.maker)) {
      makers.set(r.maker, { maker: r.maker, name: r.maker_name || r.maker, tank: 0, stand: 0, rework: 0, done: 0 });
    }
    const m = makers.get(r.maker);
    if (!r.source) continue;
    if (r.part_status === 'Pending') m[r.part === 'stand' ? 'stand' : 'tank']++;
    else if (r.part_status === 'Rework') m.rework++;
    else if (r.part_status === 'Done') m.done++;
  }
  // A maker who built Production Orders but has no row above (e.g. no longer set up as a maker).
  for (const b of builtByMaker.values()) {
    if (!makers.has(b.maker)) {
      makers.set(b.maker, { maker: b.maker, name: b.maker, tank: 0, stand: 0, rework: 0, done: 0 });
    }
  }
  const builtCell = (m, field) => {
    if (built.error) return '-';
    const b = builtByMaker.get(m.maker);
    return b ? (Number(b[field]) || 0).toLocaleString('en-US', { maximumFractionDigits: 2 }) : '0';
  };

  const list = Array.from(makers.values())
    .sort((a, b) => (b.tank + b.stand + b.rework) - (a.tank + a.stand + a.rework) || a.name.localeCompare(b.name));

  tbody.innerHTML = list.length === 0
    ? '<tr><td colspan="8" class="muted">No makers set up yet.</td></tr>'
    : list.map(m => {
      const open = m.tank + m.stand + m.rework;
      const status = m.rework ? '<span class="badge badge-danger">Has rework</span>'
        : open ? '<span class="badge badge-warning">Busy</span>'
        : m.done ? '<span class="badge badge-success">Done, waiting</span>'
        : '<span class="badge badge-neutral">Idle</span>';
      return `
        <tr>
          <td><a href="maker-assignments.html?maker=${encodeURIComponent(m.maker)}">${escapeDashboardHtml(m.name)}</a></td>
          <td class="num">${m.tank}</td>
          <td class="num">${m.stand}</td>
          <td class="num">${m.rework}</td>
          <td class="num">${m.done}</td>
          <td class="num" title="All-time: ${builtCell(m, 'tasks_total')} task(s)">${builtCell(m, 'tasks_month')}</td>
          <td class="num">${builtCell(m, 'units_month')}</td>
          <td>${status}</td>
        </tr>`;
    }).join('');
}

// "Biggest Purchases & Expenses - This Month" - per "can you show me a report there what is the
// biggest purchase and expense by ranking". admin_get_dashboard_spending_ranking
// (sql/supabase_dashboard_spending_ranking.sql) returns the top 10 of every ranking in one call,
// using the same month/warehouse rules as the Total Purchase / Expense This Month cards; each
// card's tabs just redraw from that. Shows an error line if that SQL isn't run yet.
async function loadSpendingRanking(session) {
  if (!session.password) return;
  const cards = document.querySelectorAll('.dash-ranking-card');

  const { data, error } = await supabaseClient.rpc('admin_get_dashboard_spending_ranking', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });

  if (error) {
    console.error('admin_get_dashboard_spending_ranking failed:', error);
    cards.forEach(card => {
      card.querySelector('.dash-ranking-list').innerHTML =
        `<div class="error-text">${escapeDashboardHtml(error.message)}</div>`;
    });
    return;
  }

  const rows = data || [];
  const render = (card, dim) => {
    const list = rows.filter(r => r.source === card.dataset.rankingSource && r.dimension === dim);
    card.querySelectorAll('.dash-ranking-tab').forEach(t => t.classList.toggle('active', t.dataset.dim === dim));
    const countWord = (n) => {
      if (dim === 'entry') return '';
      if (card.dataset.rankingSource === 'Expense') return `${n} ${n === 1 ? 'entry' : 'entries'}`;
      if (dim === 'po') return `${n} ${n === 1 ? 'line' : 'lines'}`;
      return `${n} ${n === 1 ? 'PO' : 'POs'}`;
    };
    card.querySelector('.dash-ranking-list').innerHTML = list.length === 0
      ? '<div class="muted">Nothing posted this month yet.</div>'
      : list.map(r => {
        const pct = Math.max(0, Math.min(100, (Number(r.share) || 0) * 100));
        const sub = [r.detail, countWord(Number(r.entry_count) || 0)].filter(Boolean).join(' · ');
        return `
          <div class="dash-ranking-row">
            <span class="dash-ranking-rank">${r.rank}</span>
            <div class="dash-ranking-main">
              <div class="dash-ranking-line">
                <span class="dash-ranking-name" title="${escapeDashboardHtml(r.name)}">${escapeDashboardHtml(r.name)}</span>
                <span class="dash-ranking-amount">${formatCurrency(r.amount)}</span>
              </div>
              <div class="dash-ranking-bar"><span style="width:${pct.toFixed(1)}%"></span></div>
              <div class="dash-ranking-sub"><span>${escapeDashboardHtml(sub)}</span><span>${pct.toFixed(1)}%</span></div>
            </div>
          </div>`;
      }).join('');
  };

  cards.forEach(card => {
    render(card, 'category');
    card.querySelector('.dash-ranking-tabs').addEventListener('click', (e) => {
      const tab = e.target.closest('.dash-ranking-tab');
      if (tab) render(card, tab.dataset.dim);
    });
  });
}

// Per "dashboards are mostly for reportings - 1st group Sales, 2nd Production, 3rd Purchase and
// Expense and payroll... put the grouping on the left" (super users first). The left
// #dashGroupsNav shows one data-dash-group section of #financeCardGrid at a time. The shared
// Sales Target / order-status / Sales by Staff blocks are moved into the Sales group, and the
// nav-card shortcuts into a Shortcuts group sub-grouped by their data-group. Elements are moved
// (not cloned) so their ids and the hidden/shown gating in init() still apply.
const DASH_SHORTCUT_GROUPS = [
  { key: 'orders', title: 'Orders' },
  { key: 'calculators', title: 'Calculators & Quotes' },
  { key: 'inventory', title: 'Inventory & Setup' },
  { key: 'reports', title: 'Reports' },
  { key: 'admin', title: 'Admin' }
];
const DASH_GROUP_STORAGE_KEY = 'dashboardGroup';

function showDashboardGroup(key) {
  document.querySelectorAll('#financeCardGrid .dash-group').forEach(section => {
    section.classList.toggle('hidden', section.dataset.dashGroup !== key);
  });
  document.querySelectorAll('#dashGroupsNav .dash-group-tab').forEach(tab => {
    tab.classList.toggle('active', tab.dataset.dashTab === key);
  });
  try { localStorage.setItem(DASH_GROUP_STORAGE_KEY, key); } catch (e) { /* storage blocked */ }
}

function setupDashboardGroups() {
  const extras = document.getElementById('dashSalesExtras');
  ['salesTargetCard', 'statCardGrid', 'salesByStaffSection'].forEach(id => {
    const el = document.getElementById(id);
    if (el) extras.appendChild(el);
  });

  const shortcuts = document.getElementById('dashShortcutsGroup');
  const grid = document.querySelector('#dashLayout .card-grid');
  if (grid) {
    DASH_SHORTCUT_GROUPS.forEach(group => {
      const cards = Array.from(grid.querySelectorAll(`.nav-card[data-group="${group.key}"]`))
        .filter(card => !card.classList.contains('hidden'));
      if (!cards.length) return;
      const heading = document.createElement('h3');
      heading.className = 'finance-section-heading';
      heading.textContent = group.title;
      const list = document.createElement('div');
      list.className = 'card-grid dash-shortcut-grid';
      cards.forEach(card => list.appendChild(card));
      shortcuts.append(heading, list);
    });
    grid.classList.add('hidden');
  }

  const nav = document.getElementById('dashGroupsNav');
  nav.addEventListener('click', (e) => {
    const tab = e.target.closest('.dash-group-tab');
    if (tab) showDashboardGroup(tab.dataset.dashTab);
  });
  nav.classList.remove('hidden');
  document.getElementById('dashLayout').classList.add('dash-grouped');

  let saved = null;
  try { saved = localStorage.getItem(DASH_GROUP_STORAGE_KEY); } catch (e) { /* storage blocked */ }
  const valid = Array.from(nav.querySelectorAll('.dash-group-tab')).some(t => t.dataset.dashTab === saved);
  showDashboardGroup(valid ? saved : 'sales');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  renderTopNav('Dashboard');
  await applyAppBackground();
  wireThemeToggle();

  const displayName = session.displayName || session.username;
  if (displayName) {
    document.getElementById('welcomeHeading').textContent = `Welcome back, ${displayName},`;
    document.getElementById('welcomeText').textContent = "Here's what's happening with your online orders today.";
  }

  // Per "if the user is delivery team can you atleast show a button first, the delivery button,
  // on the dashboard" - js/auth.js's requireAuth() now allows dashboard.html for Delivery Team
  // accounts (previously it was hard-redirected straight to delivery.html with no stop here), but
  // only to show this one link - the real dashboard content (finance cards, nav-card grid, etc.)
  // stays hidden and none of its data gets loaded.
  if (session.isDeliveryTeam) {
    document.getElementById('welcomeText').textContent = "Here's your shortcut to Delivery.";
    document.getElementById('deliveryTeamLanding').classList.remove('hidden');
    document.getElementById('dashboardMainContent').classList.add('hidden');
    return;
  }

  // Same pattern as Delivery Team above, for "Online Order Staff" - real dashboard content stays
  // hidden and none of its data gets loaded.
  if (session.isOnlineOrderStaff) {
    document.getElementById('welcomeText').textContent = "Here's your shortcut to Online Orders.";
    document.getElementById('onlineOrderStaffLanding').classList.remove('hidden');
    document.getElementById('dashboardMainContent').classList.add('hidden');
    return;
  }

  // Same pattern again, for a plain account with none of the permission checkboxes ticked - per
  // "why it can see all the buttons? it suppose to be My payslips only right?"
  if (hasNoPortalPermission(session)) {
    document.getElementById('welcomeText').textContent = "Here's your shortcut to My Payslips.";
    document.getElementById('noPermissionLanding').classList.remove('hidden');
    document.getElementById('dashboardMainContent').classList.add('hidden');
    return;
  }

  wirePushNotificationButton(session);
  maybeShowPushLoginPrompt(session);

  // Per "Sales User dont need to see transfer orders and other related notification for
  // transfers - Remove Serial Tracker/Reports/Customer Aquarium" - a Sales User who is NOT also
  // a super user gets a trimmed-down nav-card grid (Custom Stand/Online Orders stay, since
  // those weren't named) and no Transfer Order notifications (loadNotifications below is 100%
  // transfer-order content, so it's skipped outright for this group). A super user who also
  // happens to be flagged Sales User keeps full access - this only narrows the sales-only role.
  const isSalesOnlyUser = session.isSalesUser && !session.isSuperUser;
  if (isSalesOnlyUser) {
    document.getElementById('transferOrdersCard').classList.add('hidden');
    document.getElementById('reportsCard').classList.add('hidden');
    document.getElementById('topSellingItemsCard').classList.add('hidden');
    document.getElementById('customerAquariumCard').classList.add('hidden');
    document.getElementById('serialTrackerCard').classList.add('hidden');
  }

  if (session.isSuperUser) {
    document.getElementById('warehouseSetupCard').classList.remove('hidden');
    document.getElementById('itemSetupCard').classList.remove('hidden');
    document.getElementById('variantSetupCard').classList.remove('hidden');
    document.getElementById('advanceOrdersCard').classList.remove('hidden');
    document.getElementById('orderTimingDashboardCard').classList.remove('hidden');
    document.getElementById('vendorSetupCard').classList.remove('hidden');
    document.getElementById('userSetupCard').classList.remove('hidden');
    document.getElementById('financeCardGrid').classList.remove('hidden');
    setupDashboardGroups();
    await loadFinancialSummary(session);
    await loadExpenseSummary(session);
    await loadDailyByWarehouse(session);
    await loadPurchaseSummary(session);
    await loadPayrollSummary(session);
    renderProfitCard();
    await loadSpendingRanking(session);
    await loadProductionSummary(session);
    await loadMakerAssignmentSummary(session);
  }

  // Per "if the user is a sales user show the dashboard sales by confirmation" - Sales Users
  // (StaffUsers.SalesUser, see supabase_staff_users_table.sql) get the full "Sales by Staff"
  // section too, same as super users, not just their own card - admin_get_sales_by_confirmed_by
  // already only requires is_staff_authorized (any active login), so no RPC change was needed,
  // just widening this frontend gate.
  if (session.isSuperUser || session.isSalesUser) {
    document.getElementById('salesByStaffSection').classList.remove('hidden');
    await loadSalesByStaff(session);
  }

  // Per "show Total Walk-in sales on the dashboard for the user that is not sales user and not
  // super user" - a plain staff login (neither flag) gets just this one figure, not the full
  // super-user finance grid (Amount to Receive/Total Sales/Expense stay hidden from them).
  if (!session.isSuperUser && !session.isSalesUser) {
    document.getElementById('walkInOnlyCard').classList.remove('hidden');
    await loadFinancialSummary(session);
  }

  await loadStatusSummary(session);
  if (!isSalesOnlyUser) {
    await loadNotifications(session);
  }
})();
