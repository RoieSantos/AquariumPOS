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

  document.getElementById('statAmountToReceive').textContent = formatCurrency(row.amount_to_receive);
  document.getElementById('statMonthSales').textContent = formatCurrency(row.month_sales);

  const monthLabel = new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
  const orderCount = row.month_order_count || 0;
  const orderWord = orderCount === 1 ? 'order' : 'orders';
  document.getElementById('statMonthSalesSub').textContent = `${monthLabel} · ${orderCount} ${orderWord} so far`;

  document.getElementById('statWalkInSales').textContent = formatCurrency(row.walkin_sales_month);
  const walkinCount = row.walkin_order_count || 0;
  const walkinWord = walkinCount === 1 ? 'order' : 'orders';
  document.getElementById('statWalkInSalesSub').textContent = `${monthLabel} · ${walkinCount} ${walkinWord} so far`;

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

  updateSalesTargetTile(row.month_sales, row.month_sales_target);
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
// "Total Purchase" (statTotalPurchase/statTotalPurchaseSub in dashboard.html) is still an
// unwired placeholder - add a backend RPC (mirroring this function) and call it here the same
// way once its calculation formula is defined.
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

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  renderTopNav('Dashboard');
  await applyAppBackground();

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
    await loadFinancialSummary(session);
    await loadExpenseSummary(session);
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
