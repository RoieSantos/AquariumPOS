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
    // Highlight the saved choice (Light / Dark / Auto), not the theme Auto currently resolves to
    const current = getPortalThemeChoice();
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
function staffStatLinkHtml(displayName, period, label, amount, count, linkParam = 'confirmedBy') {
  const href = `online-orders.html?${linkParam}=${encodeURIComponent(displayName)}&period=${period}`;
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
    .join('') + await botCreatedCardHtml(session, 'Vic');
}

// Vic (the Messenger bot) card - per "add vic there but only for created". Vic never confirms, so
// his card counts orders he CREATED (admin_get_sales_by_created_by, supabase_dashboard_sales_by_
// created_by.sql); not ranked against the staff. Empty if the SQL isn't run yet.
async function botCreatedCardHtml(session, name) {
  const { data, error } = await supabaseClient.rpc('admin_get_sales_by_created_by', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_created_by: name
  });
  if (error) {
    console.error('admin_get_sales_by_created_by failed:', error);
    return '';
  }
  const r = (data || [])[0];
  if (!r) return '';
  return `
    <div class="staff-sales-card">
      <div class="staff-sales-header">
        <div class="staff-sales-identity">
          <div class="staff-sales-avatar">🤖</div>
          <div class="staff-sales-name">${name} <span class="muted">(created)</span></div>
        </div>
      </div>
      <div class="staff-sales-stats">
        ${staffStatLinkHtml(name, 'today', 'Daily', r.daily_sales, r.daily_order_count, 'createdBy')}
        ${staffStatLinkHtml(name, 'month', 'Monthly', r.monthly_sales, r.monthly_order_count, 'createdBy')}
        ${staffStatLinkHtml(name, 'prevmonth', 'Prev. Month', r.previous_month_sales, r.previous_month_order_count, 'createdBy')}
      </div>
    </div>
  `;
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

// nameKey/title are optional - the tender breakdown (loadDailyByTender) reuses this with
// method_name rows and a "By tender" caption; the sales cards' branch split gets "By branch".
function renderWarehouseBreakdown(elementId, rows, amountKey, countKey, nameKey = 'warehouse_name', title = '') {
  const el = document.getElementById(elementId);
  if (!el) return;
  const lines = rows
    .filter((r) => (Number(r[countKey]) || 0) > 0 || (Number(r[amountKey]) || 0) > 0)
    .sort((a, b) => (Number(b[amountKey]) || 0) - (Number(a[amountKey]) || 0));
  el.innerHTML = (title && lines.length ? `<div class="finance-breakdown-title">${escapeDashboardHtml(title)}</div>` : '') + lines
    .map((r) => `
      <div class="finance-breakdown-row">
        <span class="finance-breakdown-name">${escapeDashboardHtml(r[nameKey])}</span>
        <span class="finance-breakdown-value">${formatCurrency(r[amountKey])} <span class="finance-breakdown-count">(${Number(r[countKey]) || 0})</span></span>
      </div>
    `)
    .join('');
  el.classList.toggle('hidden', lines.length === 0);
}

// Kept for renderWalkInBranchTender, which nests the Walk-In card's tenders under these branch rows.
let dailyByWarehouseRows = [];

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

  dailyByWarehouseRows = data;
  renderWarehouseBreakdown('statTodayOnlineSalesByWh', data, 'online_sales', 'online_order_count', 'warehouse_name', 'By branch');
  renderWarehouseBreakdown('statTodayWalkInSalesByWh', data, 'walkin_sales', 'walkin_order_count', 'warehouse_name', 'By branch');
  renderWarehouseBreakdown('statTodayExpenseByWh', data, 'expense', 'expense_count');
}

// Per "is it possible we break it down too by the tender types?" - a second split under the two
// "Sales - Today" cards: Cash / GCash / BDO... from admin_get_dashboard_daily_by_tender
// (supabase_dashboard_daily_by_tender.sql), same "today" rules as the cards. Its "Unpaid / not
// synced yet" row (balances owed + orders the 5-minute payment sync hasn't read) makes the rows
// add up to the headline.
async function loadDailyByTender(session) {
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_dashboard_daily_by_tender', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_dashboard_daily_by_tender failed:', error);
    return;
  }

  // Online card: one flat tender list, summed across branches.
  const onlineByMethod = new Map();
  data.filter((r) => !r.is_walkin).forEach((r) => {
    const m = onlineByMethod.get(r.method_name) || { method_name: r.method_name, amount: 0, order_count: 0 };
    m.amount += Number(r.amount) || 0;
    m.order_count += Number(r.order_count) || 0;
    onlineByMethod.set(r.method_name, m);
  });
  renderWarehouseBreakdown('statTodayOnlineSalesByTender', [...onlineByMethod.values()], 'amount', 'order_count', 'method_name', 'By tender');

  // Walk-In card - per "can you do By Branch By tender so they will have relationship": each branch
  // row (from loadDailyByWarehouse) with its own tenders indented under it.
  renderWalkInBranchTender(data.filter((r) => r.is_walkin));
}

function renderWalkInBranchTender(tenderRows) {
  const el = document.getElementById('statTodayWalkInSalesByWh');
  if (!el) return;
  const branches = dailyByWarehouseRows
    .filter((r) => (Number(r.walkin_order_count) || 0) > 0)
    .sort((a, b) => (Number(b.walkin_sales) || 0) - (Number(a.walkin_sales) || 0));
  if (!branches.length) return;
  const row = (name, amount, count, cls) => `
      <div class="finance-breakdown-row ${cls}">
        <span class="finance-breakdown-name">${escapeDashboardHtml(name)}</span>
        <span class="finance-breakdown-value">${formatCurrency(amount)} <span class="finance-breakdown-count">(${Number(count) || 0})</span></span>
      </div>`;
  el.innerHTML = '<div class="finance-breakdown-title">By branch · tender</div>' + branches
    .map((b) => row(b.warehouse_name, b.walkin_sales, b.walkin_order_count, 'finance-breakdown-branch') + tenderRows
      .filter((t) => t.warehouse_name === b.warehouse_name)
      .sort((x, y) => (Number(y.amount) || 0) - (Number(x.amount) || 0))
      .map((t) => row(t.method_name, t.amount, t.order_count, 'finance-breakdown-sub'))
      .join(''))
    .join('');
  el.classList.remove('hidden');
}

// "Today's Advance Orders" card - per "can you show in the dashboard too today's advance order
// sales". admin_get_dashboard_daily_advance_orders (supabase_dashboard_daily_advance_orders.sql)
// returns one row per branch for advance orders dated today (Manila); the headline is their total
// order value (NetAmount), the sub-line shows downpayments taken vs balance still owed.
async function loadDailyAdvanceOrders(session) {
  if (!session.password) return;

  const { data, error } = await supabaseClient.rpc('admin_get_dashboard_daily_advance_orders', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });

  if (error || !data) {
    console.error('admin_get_dashboard_daily_advance_orders failed:', error);
    return;
  }

  const sum = (key) => data.reduce((t, r) => t + (Number(r[key]) || 0), 0);
  const count = sum('order_count');
  setStatValue('statTodayAdvanceOrders', formatCurrency(sum('net_amount')));
  setStatValue('statTodayAdvanceOrdersSub',
    `${count} ${count === 1 ? 'order' : 'orders'} · ${formatCurrency(sum('downpayment'))} downpayment · ${formatCurrency(sum('balance'))} balance`);
  renderWarehouseBreakdown('statTodayAdvanceOrdersByWh', data, 'net_amount', 'order_count', 'warehouse_name', 'By branch');

  // Per "possible we show the tender type too on today's advance orders" - payments actually taken
  // today on ANY advance order (downpayments + balances, like the POS EOD "ADV ORDER COLLECTIONS"),
  // from admin_get_dashboard_daily_advance_tender (supabase_advance_order_payments.sql). Separate
  // call so the card still shows if that SQL hasn't been run yet.
  const tender = await supabaseClient.rpc('admin_get_dashboard_daily_advance_tender', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_warehouse_name: session.warehouseName || null
  });
  if (tender.error || !tender.data) {
    console.error('admin_get_dashboard_daily_advance_tender failed:', tender.error);
    return;
  }
  renderWarehouseBreakdown('statTodayAdvanceOrdersByTender', tender.data, 'amount', 'payment_count', 'method_name', 'Collected today · by tender');
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

// "My View" group - per "I want to see how the business is doing base on how the real accounting
// see it". Everything comes from one call, admin_get_my_view (sql/supabase_dashboard_my_view.sql):
// an accrual income statement (purchases become inventory; only the cost of what SOLD is expensed),
// a today snapshot of what the business owns / is owed / owes, owner's money, what's coming due and
// a 6-month trend. The period tabs just re-call it with another date range.
// The range on screen and its expense categories, for the per-category drill-down.
let myViewCurrentRange = null;
let myViewCategories = [];

// Click on an expense category row: load its entries once (admin_list_my_view_expense_entries) and
// show/hide them right under it.
async function toggleMyViewEntries(session, catRowEl) {
  const idx = catRowEl.dataset.catIdx;
  const table = catRowEl.closest('table');
  const existing = table.querySelectorAll(`.mv-entry-row[data-for="${idx}"]`);
  const arrow = catRowEl.querySelector('.mv-toggle');
  if (existing.length) {
    const open = existing[0].classList.contains('hidden');
    existing.forEach((r) => r.classList.toggle('hidden', !open));
    arrow.textContent = open ? '▾' : '▸';
    return;
  }

  const cat = myViewCategories[Number(idx)];
  if (!cat || !myViewCurrentRange) return;
  arrow.textContent = '…';
  const { data, error } = await supabaseClient.rpc('admin_list_my_view_expense_entries', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_from: myViewCurrentRange.from,
    p_to: myViewCurrentRange.to,
    p_code: cat.code
  });
  arrow.textContent = '▾';

  const rows = error
    ? [`<tr class="mv-entry-row" data-for="${idx}"><td colspan="3" class="error-text">${escapeDashboardHtml(error.message)}</td></tr>`]
    : (data || []).map((e) => `
      <tr class="mv-entry-row" data-for="${idx}">
        <td>${escapeDashboardHtml(e.description || '(no description)')}
          <div class="mv-list-sub">${myViewDateLabel(e.entry_date)} · ${escapeDashboardHtml(e.source)}${e.doc_no ? ` ${escapeDashboardHtml(e.doc_no)}` : ''}${e.warehouse ? ` · ${escapeDashboardHtml(e.warehouse)}` : ''}${e.created_by ? ` · ${escapeDashboardHtml(e.created_by)}` : ''}</div></td>
        <td class="num">${formatCurrency(e.amount)}</td>
        <td></td>
      </tr>`);
  if (!error && rows.length === 0) {
    rows.push(`<tr class="mv-entry-row" data-for="${idx}"><td colspan="3" class="muted">No entries.</td></tr>`);
  }
  catRowEl.insertAdjacentHTML('afterend', rows.join(''));
}

function myViewIsoDate(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function myViewRange(period) {
  const today = new Date();
  const y = today.getFullYear();
  const m = today.getMonth();
  if (period === 'prevmonth') return { from: new Date(y, m - 1, 1), to: new Date(y, m, 0) };
  if (period === 'quarter') return { from: new Date(y, m - (m % 3), 1), to: today };
  if (period === 'ytd') return { from: new Date(y, 0, 1), to: today };
  return { from: new Date(y, m, 1), to: today };
}

function myViewDateLabel(iso) {
  return new Date(`${iso}T00:00:00`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function myViewPct(part, whole) {
  const w = Number(whole) || 0;
  return w === 0 ? null : (Number(part) || 0) / w * 100;
}

// "+12%" vs the previous period. goodWhenUp=false for costs, so a rise in expenses reads red.
function myViewDelta(cur, prev, goodWhenUp = true) {
  const c = Number(cur) || 0;
  const p = Number(prev) || 0;
  if (p === 0) return '';
  const change = (c - p) / Math.abs(p) * 100;
  if (Math.abs(change) < 0.5) return '<span title="vs previous period">±0%</span>';
  const good = (change > 0) === goodWhenUp;
  return `<span class="${good ? 'mv-good' : 'mv-bad'}" title="vs previous period: ${formatCurrency(p)}">${change > 0 ? '▲' : '▼'} ${Math.abs(change).toFixed(0)}%</span>`;
}

function renderMyViewPnl(pnl, prev) {
  const row = (label, amount, prevAmount, cls = '', goodWhenUp = true, sign = '') => `
    <tr class="${cls}">
      <td>${label}</td>
      <td class="num">${sign}${formatCurrency(amount)}</td>
      <td class="num mv-delta">${prevAmount === undefined ? '' : myViewDelta(amount, prevAmount, goodWhenUp)}</td>
    </tr>`;
  const gm = myViewPct(pnl.gross_profit, pnl.revenue);
  const nm = myViewPct(pnl.net_profit, pnl.revenue);
  const cats = pnl.expense_categories || [];
  const shown = cats.slice(0, 8);
  const other = cats.slice(8).reduce((t, c) => t + (Number(c.amount) || 0), 0);
  const coverage = pnl.cogs_coverage === null ? null : Number(pnl.cogs_coverage) * 100;
  // Each expense category opens its entries underneath (wireMyView's click handler, loadMyViewEntries).
  myViewCategories = cats;
  const catRow = (c, i, cls) => `
    <tr class="${cls} mv-cat-row" data-cat-idx="${i}" title="Click to see the entries">
      <td><span class="mv-toggle">▸</span> ${escapeDashboardHtml(c.category)} <span class="mv-list-sub">(${c.entries})</span></td>
      <td class="num">${formatCurrency(c.amount)}</td>
      <td class="num mv-delta"></td>
    </tr>`;

  document.getElementById('mvPnl').innerHTML = `
    <table class="mv-stmt">
      <tr class="mv-section"><td colspan="3">Revenue</td></tr>
      ${row(`Online sales <span class="mv-list-sub">(${pnl.online_count} orders)</span>`, pnl.online_sales, prev.online_sales, 'mv-indent')}
      ${row(`Walk-in sales <span class="mv-list-sub">(${pnl.walkin_count} orders)</span>`, pnl.walkin_sales, prev.walkin_sales, 'mv-indent')}
      ${row('Total Revenue', pnl.revenue, prev.revenue, 'mv-total')}
      ${row('Less: Cost of Goods Sold', pnl.cogs, prev.cogs, '', false, '- ')}
      ${row(`Gross Profit${gm === null ? '' : ` <span class="mv-list-sub">(${gm.toFixed(1)}% margin)</span>`}`, pnl.gross_profit, prev.gross_profit, 'mv-total')}
      <tr class="mv-section"><td colspan="3">Operating Expenses</td></tr>
      ${shown.map((c, i) => catRow(c, i, 'mv-indent')).join('')}
      ${other > 0 ? row(`<span class="mv-toggle">▸ Other (${cats.length - 8} categories)</span>`, other, undefined, 'mv-indent mv-other-row') : ''}
      ${cats.slice(8).map((c, i) => catRow(c, i + 8, 'mv-indent mv-sub-row hidden')).join('')}
      ${row(`Salaries &amp; Wages <span class="mv-list-sub">(gross, ${pnl.payroll_employees} staff)</span>`, pnl.payroll_gross, prev.payroll_gross, 'mv-indent', false)}
      ${row('Total Operating Expenses', pnl.opex_total, prev.opex_total, 'mv-total', false)}
      <tr class="mv-grand">
        <td>Net ${Number(pnl.net_profit) < 0 ? 'Loss' : 'Profit'}${nm === null ? '' : ` <span class="mv-list-sub">(${nm.toFixed(1)}%)</span>`}</td>
        <td class="num ${Number(pnl.net_profit) < 0 ? 'mv-bad' : 'mv-good'}">${formatCurrency(pnl.net_profit)}</td>
        <td class="num mv-delta">${myViewDelta(pnl.net_profit, prev.net_profit)}</td>
      </tr>
    </table>
    <div class="mv-note">Purchases aren't an expense here - they become inventory, and only the cost of what sold
      (Cost of Goods Sold) comes off profit.${coverage === null ? '' : ` Item costs cover <b>${coverage.toFixed(0)}%</b> of sales value${coverage < 90 ? ` - ${pnl.uncosted_lines} sold line(s) have no item cost yet, so the real cost is higher and profit lower than shown. Set costs in Item Setup.` : '.'}`}</div>`;
}

function renderMyViewPosition(pos) {
  const line = (label, amount, sub = '', href = '') => `
    <div class="mv-list-row">
      <div class="mv-list-name">${href ? `<a href="${href}">${label}</a>` : label}${sub ? `<div class="mv-list-sub">${sub}</div>` : ''}</div>
      <div class="mv-list-amt">${formatCurrency(amount)}</div>
    </div>`;
  const owns = (Number(pos.inventory_value) || 0) + (Number(pos.receivables) || 0);
  const owes = (Number(pos.vendor_payables) || 0) + (Number(pos.bills_overdue_amount) || 0)
    + (Number(pos.owed_to_owner) || 0) + (Number(pos.customer_deposits) || 0);
  const net = owns - owes;

  document.getElementById('mvPosition').innerHTML = `
    <table class="mv-stmt"><tr class="mv-section"><td>What the business has</td></tr></table>
    ${line('Inventory on hand (at cost)', pos.inventory_value,
      Number(pos.inventory_uncosted_items) > 0 ? `${pos.inventory_uncosted_items} stocked item(s) have no cost - not counted` : '', 'stock-on-hand.html')}
    ${line('Customers still owe you', pos.receivables, `${pos.receivables_count} unpaid order(s) in progress - not New / Shipped / Delivered`, 'online-orders.html?filter=outstanding')}
    <table class="mv-stmt"><tr class="mv-section"><td>What the business owes</td></tr></table>
    ${line('Unpaid vendor bills', pos.vendor_payables,
      Number(pos.vendor_overdue) > 0 ? `<span class="mv-bad">${formatCurrency(pos.vendor_overdue)} overdue</span>` : 'Accounts payable', 'vendor-setup.html')}
    ${line('Overdue Bills &amp; Dues', pos.bills_overdue_amount,
      Number(pos.bills_overdue_count) > 0 ? `<span class="mv-bad">${pos.bills_overdue_count} past due</span>` : 'Nothing overdue', 'business-bills.html')}
    ${line('Owed back to owner', pos.owed_to_owner, 'Owner loans not yet repaid', 'owner-funds.html')}
    ${line('Customer deposits held', pos.customer_deposits, `${pos.customer_deposits_count} advance order(s) not yet delivered`, 'advance-orders.html')}
    <table class="mv-stmt">
      <tr class="mv-grand"><td>Net position</td><td class="num ${net < 0 ? 'mv-bad' : 'mv-good'}">${formatCurrency(net)}</td></tr>
    </table>
    <div class="mv-note">Has minus owes, excluding cash on hand. Owner has put in ${formatCurrency(pos.capital_total)} capital and taken ${formatCurrency(pos.drawings_total)} in drawings (all time).
      ${Number(pos.bills_due30_count) > 0 ? `${pos.bills_due30_count} more bill(s) worth ${formatCurrency(pos.bills_due30_amount)} fall due in the next 30 days.` : ''}</div>`;
}

function renderMyViewTrend(trend) {
  const el = document.getElementById('mvTrend');
  if (!trend.length) { el.innerHTML = '<div class="muted">No data yet.</div>'; return; }
  const costOf = (t) => (Number(t.cogs) || 0) + (Number(t.opex_total) || 0);
  const max = Math.max(1, ...trend.map((t) => Math.max(Number(t.revenue) || 0, costOf(t))));
  const monthName = (iso) => new Date(`${iso}T00:00:00`).toLocaleDateString('en-US', { month: 'short' });
  const short = (n) => {
    const v = Number(n) || 0;
    const a = Math.abs(v);
    const s = a >= 1e6 ? `${(a / 1e6).toFixed(1)}M` : a >= 1e3 ? `${(a / 1e3).toFixed(0)}k` : a.toFixed(0);
    return `${v < 0 ? '-' : ''}₱${s}`;
  };
  el.innerHTML = `
    <div class="mv-trend" role="img" aria-label="Sales vs expenses, last 6 months">
      ${trend.map((t) => `
        <div class="mv-trend-col" title="${monthName(t.month)}: Sales ${formatCurrency(t.revenue)} · Expenses ${formatCurrency(costOf(t))} · Net ${formatCurrency(t.net_profit)}">
          <div class="mv-bar mv-bar-rev" style="height:${((Number(t.revenue) || 0) / max * 100).toFixed(1)}%"></div>
          <div class="mv-bar mv-bar-cost" style="height:${(costOf(t) / max * 100).toFixed(1)}%"></div>
        </div>`).join('')}
    </div>
    <div class="mv-trend-labels">
      ${trend.map((t) => `<div>${monthName(t.month)}<b class="${Number(t.net_profit) < 0 ? 'mv-bad' : ''}">${short(t.net_profit)}</b></div>`).join('')}
    </div>
    <div class="mv-note">Number under each month = net profit. Hover a month for the figures.</div>`;
}

function renderMyViewSide(data) {
  const today = data.today;
  const up = data.upcoming || [];
  document.getElementById('mvUpcoming').innerHTML = up.length === 0
    ? '<div class="muted">Nothing due in the next 30 days. 🎉</div>'
    : up.map((u) => {
      const overdue = u.due_date < today;
      return `
        <div class="mv-list-row">
          <div class="mv-list-name">${u.kind === 'Vendor' ? '🧾' : '📅'} ${escapeDashboardHtml(u.name)}
            <div class="mv-list-sub ${overdue ? 'mv-bad' : ''}">${overdue ? 'Overdue · ' : ''}${myViewDateLabel(u.due_date)}</div></div>
          <div class="mv-list-amt">${u.amount === null ? '-' : formatCurrency(u.amount)}</div>
        </div>`;
    }).join('');

  const o = data.owner || {};
  const put = (Number(o.capital_in) || 0) + (Number(o.owner_loan) || 0);
  const took = (Number(o.drawings) || 0) + (Number(o.repayments) || 0);
  const ownerRow = (label, amount, sub = '') => `
    <div class="mv-list-row"><div class="mv-list-name">${label}${sub ? `<div class="mv-list-sub">${sub}</div>` : ''}</div>
    <div class="mv-list-amt">${formatCurrency(amount)}</div></div>`;
  document.getElementById('mvOwner').innerHTML = `
    ${ownerRow('Capital put in', o.capital_in, 'Permanent investment')}
    ${ownerRow('Loaned to the business', o.owner_loan, 'To be paid back')}
    ${ownerRow('Taken out (drawings)', o.drawings)}
    ${ownerRow('Loan repaid to owner', o.repayments)}
    <div class="mv-note">${formatCurrency(o.paid_directly)} of this paid business expenses straight from your pocket.
      Net ${put - took >= 0 ? 'into' : 'out of'} the business: <b>${formatCurrency(Math.abs(put - took))}</b>.</div>`;

  const c = data.cash_out || {};
  const p = data.pnl || {};
  document.getElementById('mvCashOut').innerHTML = `
    ${ownerRow('Stock purchased', c.purchases, 'Posted POs - goes to inventory')}
    ${ownerRow('Paid to vendors', c.vendor_payments, 'Includes POs, paid when posted - not on top of the line above')}
    ${ownerRow('Expenses', p.expense_total, 'POS + Expense Journal')}
    ${ownerRow('Payroll (net pay)', p.payroll_net)}
    ${ownerRow('Bills &amp; Dues paid', (Number(c.bills_paid_business) || 0) + (Number(c.bills_paid_owner) || 0),
      Number(c.bills_paid_owner) > 0 ? `${formatCurrency(c.bills_paid_owner)} by the owner` : 'All by the business')}
    <div class="mv-note">Bills &amp; Dues paid with an expense category are already inside Expenses.</div>`;
}

function renderMyViewHealth(pnl) {
  const chip = (label, value, sub) => `
    <div class="mv-chip"><div class="mv-chip-label">${label}</div><div class="mv-chip-value">${value}</div><div class="mv-chip-sub">${sub}</div></div>`;
  const gm = myViewPct(pnl.gross_profit, pnl.revenue);
  const nm = myViewPct(pnl.net_profit, pnl.revenue);
  const payrollShare = myViewPct(pnl.payroll_gross, pnl.revenue);
  // Break-even: the sales needed for gross profit to cover operating expenses at this margin.
  const breakEven = gm && gm > 0 ? (Number(pnl.opex_total) || 0) / (gm / 100) : null;
  const fmtPct = (v) => (v === null ? '-' : `${v.toFixed(1)}%`);
  document.getElementById('mvHealth').innerHTML =
    chip('Gross margin', fmtPct(gm), 'kept from each ₱1 sold, after item cost') +
    chip('Net margin', fmtPct(nm), 'kept after every expense') +
    chip('Payroll vs sales', fmtPct(payrollShare), 'gross salaries ÷ revenue') +
    chip('Break-even sales', breakEven === null ? '-' : formatCurrency(breakEven),
      breakEven === null ? 'needs sales with item costs'
        : (Number(pnl.revenue) || 0) >= breakEven ? '✅ reached this period' : `${formatCurrency(breakEven - (Number(pnl.revenue) || 0))} to go`);
}

async function loadMyView(session, period = 'month') {
  if (!session.password) return;
  const { from, to } = myViewRange(period);
  const errorEl = document.getElementById('mvError');
  document.getElementById('mvRange').textContent = `${myViewDateLabel(myViewIsoDate(from))} - ${myViewDateLabel(myViewIsoDate(to))} · loading...`;

  const { data, error } = await supabaseClient.rpc('admin_get_my_view', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_from: myViewIsoDate(from),
    p_to: myViewIsoDate(to)
  });
  if (error || !data) {
    console.error('admin_get_my_view failed:', error);
    errorEl.textContent = `Could not load My View: ${error?.message || 'no data'}`;
    errorEl.classList.remove('hidden');
    return;
  }
  errorEl.classList.add('hidden');
  myViewCurrentRange = { from: data.from, to: data.to };

  const pnl = data.pnl;
  const prev = data.prev;
  const costs = (Number(pnl.cogs) || 0) + (Number(pnl.opex_total) || 0);
  const prevCosts = (Number(prev.cogs) || 0) + (Number(prev.opex_total) || 0);
  const ownerIn = (Number(data.owner.capital_in) || 0) + (Number(data.owner.owner_loan) || 0);

  document.getElementById('mvRange').textContent =
    `${myViewDateLabel(data.from)} - ${myViewDateLabel(data.to)} · compared with the ${data.to >= data.today ? 'same number of days' : 'period'} before`;
  document.getElementById('mvAsOf').textContent = `as of ${myViewDateLabel(data.today)}`;
  setStatValue('mvRevenue', formatCurrency(pnl.revenue));
  setStatValue('mvRevenueSub', `${pnl.online_count + pnl.walkin_count} orders · ${prev.revenue ? `${myViewDelta(pnl.revenue, prev.revenue).replace(/<[^>]+>/g, '')} vs before` : 'Online + Walk-In'}`);
  setStatValue('mvCosts', formatCurrency(costs));
  setStatValue('mvCostsSub', `Item cost ${formatCurrency(pnl.cogs)} + operating ${formatCurrency(pnl.opex_total)}${prevCosts ? ` · ${myViewDelta(costs, prevCosts).replace(/<[^>]+>/g, '')}` : ''}`);
  setStatValue('mvProfit', formatCurrency(pnl.net_profit));
  document.getElementById('mvProfitCard').classList.toggle('finance-loss', Number(pnl.net_profit) < 0);
  const nm = myViewPct(pnl.net_profit, pnl.revenue);
  setStatValue('mvProfitSub', `${nm === null ? 'No sales yet' : `${nm.toFixed(1)}% of sales`}${prev.revenue ? ` · was ${formatCurrency(prev.net_profit)}` : ''}`);
  setStatValue('mvOwnerIn', formatCurrency(ownerIn));
  setStatValue('mvOwnerInSub', `${formatCurrency(data.owner.paid_directly)} paid bills directly · ${formatCurrency(data.owner.drawings)} taken out`);

  renderMyViewHealth(pnl);
  renderMyViewPnl(pnl, prev);
  renderMyViewPosition(data.position);
  renderMyViewTrend(data.trend || []);
  renderMyViewSide(data);
}

function wireMyView(session) {
  // "Other (N categories)" in the Income Statement expands to list each one (click again to fold).
  document.getElementById('mvPnl').addEventListener('click', (e) => {
    const catRow = e.target.closest('.mv-cat-row');
    if (catRow) {
      toggleMyViewEntries(session, catRow);
      return;
    }
    const otherRow = e.target.closest('.mv-other-row');
    if (!otherRow) return;
    const open = otherRow.classList.toggle('mv-open');
    const table = otherRow.closest('table');
    table.querySelectorAll('.mv-sub-row').forEach((r) => r.classList.toggle('hidden', !open));
    if (!open) {
      // Folding "Other" also folds any entries opened under its categories.
      table.querySelectorAll('.mv-sub-row').forEach((r) => {
        r.querySelector('.mv-toggle').textContent = '▸';
        table.querySelectorAll(`.mv-entry-row[data-for="${r.dataset.catIdx}"]`).forEach((x) => x.classList.add('hidden'));
      });
    }
    const label = otherRow.querySelector('.mv-toggle');
    label.textContent = label.textContent.replace(/^[▸▾]/, open ? '▾' : '▸');
  });

  const tabs = document.getElementById('mvPeriod');
  tabs.addEventListener('click', (e) => {
    const tab = e.target.closest('[data-period]');
    if (!tab) return;
    tabs.querySelectorAll('[data-period]').forEach((t) => t.classList.toggle('active', t === tab));
    loadMyView(session, tab.dataset.period);
  });
  return loadMyView(session, 'month');
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
  showDashboardGroup(valid ? saved : 'myview');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  renderTopNav('Dashboard');
  // Not awaited - the background photo is cosmetic and shouldn't hold up the dashboard's data.
  applyAppBackground();
  wireThemeToggle();
  const loaders = [];

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
    // Fired in parallel rather than one await after another - each RPC is a full round trip, so
    // ~12 sequential calls made the dashboard several seconds slower on staff/mobile connections.
    // Only real dependencies: by-tender reads dailyByWarehouseRows, and the profit card needs the
    // four monthlyTotals (sales/expense/purchase/payroll) filled in first.
    loaders.push(
      Promise.all([
        loadFinancialSummary(session),
        loadExpenseSummary(session),
        loadPurchaseSummary(session),
        loadPayrollSummary(session)
      ]).then(renderProfitCard),
      loadDailyByWarehouse(session).then(() => loadDailyByTender(session)),
      loadDailyAdvanceOrders(session),
      loadSpendingRanking(session),
      loadProductionSummary(session),
      loadMakerAssignmentSummary(session),
      wireMyView(session)
    );
  }

  // Per "if the user is a sales user show the dashboard sales by confirmation" - Sales Users
  // (StaffUsers.SalesUser, see supabase_staff_users_table.sql) get the full "Sales by Staff"
  // section too, same as super users, not just their own card - admin_get_sales_by_confirmed_by
  // already only requires is_staff_authorized (any active login), so no RPC change was needed,
  // just widening this frontend gate.
  if (session.isSuperUser || session.isSalesUser) {
    document.getElementById('salesByStaffSection').classList.remove('hidden');
    loaders.push(loadSalesByStaff(session));
  }

  // Per "show Total Walk-in sales on the dashboard for the user that is not sales user and not
  // super user" - a plain staff login (neither flag) gets just this one figure, not the full
  // super-user finance grid (Amount to Receive/Total Sales/Expense stay hidden from them).
  if (!session.isSuperUser && !session.isSalesUser) {
    document.getElementById('walkInOnlyCard').classList.remove('hidden');
    loaders.push(loadFinancialSummary(session));
  }

  loaders.push(loadStatusSummary(session));
  if (!isSalesOnlyUser) {
    loaders.push(loadNotifications(session));
  }
  await Promise.all(loaders);
})();
