// Online Orders page logic (any active staff).
//
// Reads straight from the persisted public."OnlineOrders" table via admin_list_online_orders() -
// no live Pancake calls for LISTING orders, since the background cron job
// (cron_sync_online_orders_from_pancake, runs every minute) already keeps that table fresh on
// its own. This makes the page load instantly regardless of backlog size, with no
// throttling/incremental-catch-up/chunked-paging complexity needed.
//
// Status IS writable from here though (see the To Ship action / handleToShipClick below) -
// admin_update_online_order_status (supabase_online_order_portal_status_update.sql) pushes the
// change live to Pancake, mirroring the desktop app's OnlineOrdersForm grid instead of just
// reading whatever the last sync happened to pull in.
//
// Deliberately NOT a free-form status editor - per direct request, staff can't manually set an
// order to an arbitrary status from here. The only manual action offered is a "To Ship" button
// for the common packed-and-ready workflow (with a confirm() prompt before it fires); every other
// status transition (Shipped, Pending Transfer, In-Transit, Received, Production Done) only ever
// happens via the background Pancake sync, same as before this status-write feature existed.
//
// No password re-unlock prompt here (unlike the super-user-only setup pages) - since this page
// is open to any active staff member, it reuses the password captured at login (session.password,
// see auth.js) to satisfy the RPC's re-verification requirement without asking again.
let currentSession = null;
let orderSearchDebounceHandle = null;
let loadGeneration = 0;
let currentPage = 1;
let currentPageSize = 50;

// Deep-link filters from a Dashboard finance card (?period=month|today|prevmonth, ?scope=walkin,
// ?filter=outstanding) or a Sales by Staff figure (?confirmedBy=...&period=...) - set once in
// init() from the URL, then applied on every load/reload for the rest of this page view
// (search/status typed afterward combine with these, they don't replace them). See the
// finance-card hrefs in dashboard.html and staffStatLinkHtml in js/dashboard.js.
let currentPeriod = null;
let currentScope = null;
let outstandingOnly = false;
let currentConfirmedBy = null;

// Per "if the user is a online order staff They can only see Confirmed / Printed / To Ship" -
// applied as an exact-match IN-list server-side (see admin_list_online_orders' p_status_in in
// supabase_online_order_staff_status_scope.sql), not just a client-side hide, so the restriction
// holds even against a direct RPC call. "Please be aware that they dont need to see price" -
// hidePriceColumns strips the Delivery Fee column here (see orderRowsHtml) and every price column
// on the Online Order Lines drill-down (js/onlineOrderLines.js).
// 'Assigned' is now a real status too (supabase_online_order_assigned_status.sql), so it's fetched
// alongside Printed.
const ONLINE_ORDER_STAFF_STATUS_SCOPE = ['Confirmed', 'Printed', 'Assigned', 'To Ship'];
let hidePriceColumns = false;

// Per "if an order has been assigned to the user.. can you show it to their access?" - the My
// Assignments tab lists only the open orders where the logged-in user is the Tank Maker, Stand
// Maker or Dispatcher (admin_list_online_orders' p_assigned_to_me, supabase_online_order_my_
// assignments.sql). Staff whose only access is one of those roles (isOrderMakerOnly, js/auth.js)
// are locked to it - the server forces it for them too.
let myAssignmentsOnly = false;
let myAssignmentsLocked = false;

// Per "i want to show the online order per category: Confirmed / Printed / To-Ship... built it as
// a mobile GUI friendly. I want button style Confirmed Printed and ToShip, make it very Mobile
// friendly" - Online Order Staff get a tab per status (docs/online-orders.html's #groupedTabs)
// over a stacked card list (#groupedOrdersList) instead of the wide flat table, since this role
// works off a phone in the warehouse. Everyone else keeps the original flat table (#flatOrdersView)
// - see the isOnlineOrderStaff branch in loadOrders/init below.
const GROUP_COUNT_IDS = {
  'Confirmed': 'groupCountConfirmed',
  'Printed': 'groupCountPrinted',
  'Assigned': 'groupCountAssigned',
  'To Ship': 'groupCountToShip'
};

// Tab/count order for the grouped view - includes 'Assigned', unlike ONLINE_ORDER_STAFF_STATUS_
// SCOPE above, which stays the real Status values sent server-side (p_status_in). 'Assigned' is
// never a real Status value (see orderDisplayStatus below) - the server-side fetch already covers
// it by asking for 'Printed', which orderDisplayStatus then splits client-side.
const GROUP_TAB_STATUSES = ['Confirmed', 'Printed', 'Assigned', 'To Ship'];

// 'Assigned' isn't a real OnlineOrders.Status value - Status must keep mirroring Pancake (see
// supabase_online_order_production_assignment.sql's header comment), so this is a derived
// display-only split: a 'Printed' order whose every NEEDED maker is set reads as 'Assigned'
// everywhere a status is shown/grouped, positioned right after Printed in the workflow
// (Confirmed > Printed > Assigned > To Ship > Shipped). An order needs a Tank Maker when it has
// an aquarium line, a Stand Maker when it has a stand line, one/the other/both/neither - an order
// needing neither (has_aquarium_line and has_stand_line both false) never becomes 'Assigned', it
// just stays 'Printed' (nothing to assign). Same split admin_get_online_order_status_summary/
// admin_list_online_orders' own p_status = 'Assigned' case make server-side (supabase_orders_
// sync_tables.sql).
function orderDisplayStatus(o) {
  // Walk-in in production: its portal-only stage (To Assign / Assigned / Production Done / Completed -
  // supabase_walkin_order_portal_status.sql). Pancake keeps saying Shipped.
  if (o.walkin_stage) return o.walkin_stage;
  const status = (o.status || '').trim();
  if (status.toLowerCase() === 'printed' && (o.has_aquarium_line || o.has_stand_line)) {
    const tankOk = !o.has_aquarium_line || !!o.assigned_tank_maker;
    const standOk = !o.has_stand_line || !!o.assigned_stand_maker;
    if (tankOk && standOk) return 'Assigned';
  }
  return status;
}

// Which tab is currently showing in the grouped (Online Order Staff) view, and the last set of
// rows fetched for it - switching tabs just re-renders from this, no server round-trip needed
// since loadOrders already fetches all 3 statuses (up to the 200-row cap) in one call.
let activeGroupStatus = 'Confirmed';
let lastGroupedRows = [];

// Whether the logged-in staff's own warehouse is flagged Production - gates whether "To Ship"
// needs to check for serial-tracked lines at all (see EnsureOrderSerialTrackingAsync's own gate in
// OnlineOrdersForm.cs - a non-production store never needed this). Resolved once at init, same
// pattern (and duplicated for the same "no shared module system between these plain <script>
// pages" reason) as transferOrders.js/serialTracker.js's own resolveIsProductionWarehouse.
let currentSessionIsProductionWarehouse = true;

// Roster for the Tank/Stand Maker dropdowns - active staff with the TankMaker and/or StandMaker
// Staff Role (User Setup, see supabase_online_order_maker_by_role.sql) - fetched once at init()
// via staff_list_order_makers, since it rarely changes and every row's dropdown needs it. Each
// dropdown filters this by its own role (makerSelectHtml).
let productionMembers = [];
let productionMembersError = null; // last load failure, shown in the Assign popup instead of "no one has the role"

async function loadProductionMembers() {
  const { data, error } = await supabaseClient.rpc('staff_list_order_makers', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });
  if (error || !data) {
    console.error('staff_list_order_makers failed:', error);
    productionMembersError = error?.message || 'No data returned.';
    return;
  }
  productionMembersError = null;
  productionMembers = data;
}

// Per direct request: "To Ship" is temporarily taken out of service on the portal (still being
// shaken out) - staff are told to finish shipping the order through the local POS/desktop app
// instead. Flip this back to true to restore the real flow (serial check, notify prompt, status
// change) once it's ready again; see handleToShipClick below. The "Send Photo" button is
// unaffected - it was detached from this flow so it keeps working either way.
const TO_SHIP_ENABLED = false;

// Ready to Ship skips the photo prompt for now (see handleToShipClick) - set true to bring it back.
const READY_TO_SHIP_ASKS_PHOTO = false;

async function resolveIsProductionWarehouse(session) {
  if (!session?.warehouseName) return true;

  const { data, error } = await supabaseClient.rpc('staff_search_warehouses', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_search: session.warehouseName
  });
  if (error || !data) return true;

  const match = data.find((w) => (w.name || '').trim().toLowerCase() === session.warehouseName.trim().toLowerCase());
  return match ? !!match.is_production_warehouse : true;
}

// Warehouse-scoped staff (StaffUsers.WarehouseName set) only see orders for their own
// warehouse - same convention as Transfer Orders (js/transferOrders.js). Orders with no
// resolved warehouse_name (e.g. LocationID didn't match any synced Warehouses row) are
// hidden while scoped, since we can't confirm they belong to this user's warehouse.
// All-Branch Fabrication staff role (supabase_online_order_all_branch_fabrication.sql) also sees other
// branches' OPEN orders that need a maker (custom line, 10mm / 12mm glass, stand) - same rule as the
// server's _online_order_open_fabrication.
function matchesWarehouseFilter(order) {
  if (!currentSession.warehouseName) return true;
  if ((order.warehouse_name || '') === currentSession.warehouseName) return true;
  return canSeeAllBranchFabrication() && isOpenFabricationOrder(order);
}

function canSeeAllBranchFabrication() {
  return (currentSession?.staffRoles || []).includes('AllBranchFabrication');
}

function isOpenFabricationOrder(order) {
  if (!(order.has_aquarium_line || order.has_stand_line)) return false;
  if (order.received_at_shop) return ['To Assign', 'Assigned', 'Production Done'].includes(order.walkin_stage);
  return ['confirmed', 'submitted', 'printed', 'assigned', 'to ship', 'packing', 'packed']
    .includes(String(order.status || '').trim().toLowerCase());
}

// An order from another branch, shown here only because it needs fabrication (see above).
function otherBranchBadgeHtml(order) {
  if (!currentSession?.warehouseName || !order.warehouse_name || order.warehouse_name === currentSession.warehouseName) return '';
  return `<span class="badge badge-neutral" title="From another branch - shown because it needs fabrication (All-Branch Fabrication role).">${escapeHtml(order.warehouse_name)}</span>`;
}

// p_branch_scoped (supabase_online_order_all_branch_fabrication.sql) does the branch filter above
// server-side, before paging. Until that file is run the RPC doesn't know the param (PGRST202) - retry
// without it; matchesWarehouseFilter still filters in the browser either way.
const branchScopedUnsupported = new Set();
async function rpcBranchScoped(fnName, params) {
  if (!branchScopedUnsupported.has(fnName)) {
    const result = await supabaseClient.rpc(fnName, { ...params, p_branch_scoped: true });
    if (result.error?.code !== 'PGRST202') return result;
    branchScopedUnsupported.add(fnName);
  }
  return supabaseClient.rpc(fnName, params);
}

const STATUS_SUMMARY_ELEMENT_IDS = {
  'Confirmed': 'statusCountConfirmed',
  'Printed': 'statusCountPrinted',
  'Assigned': 'statusCountAssigned',
  // Every part marked done, waiting for the POS Production Done (supabase_online_order_production_done_tab.sql).
  'Production Done': 'statusCountProductionDone',
  // Walk-in tab only (supabase_walkin_order_portal_status.sql).
  'To Assign': 'statusCountToAssign',
  'Completed': 'statusCountCompleted',
  'To Ship': 'statusCountToShip',
  'Shipped': 'statusCountShipped',
  'Cancelled': 'statusCountCancelled'
};

// Exact per-status record counts, from the persisted OnlineOrders table (kept fresh by the
// background cron sync) - fast/instant since it's a simple grouped count on a local table (see
// admin_get_online_order_status_summary in supabase_orders_sync_tables.sql).
async function loadStatusSummary() {
  if (!currentSession.password) return;

  const { data, error } = await rpcBranchScoped('admin_get_online_order_status_summary', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_warehouse_name: currentSession.warehouseName || null,
    p_walkin_only: currentScope === 'walkin'
  });

  if (error || !data) {
    console.error('admin_get_online_order_status_summary failed:', error);
    return;
  }

  data.forEach((row) => {
    const elementId = STATUS_SUMMARY_ELEMENT_IDS[row.status_label];
    if (elementId) {
      document.getElementById(elementId).textContent = row.order_count;
    }
  });
}

// Per "put a flag in the online header to show if an order has 10mm glass or 12mm glass custom
// aquarium it may need or require an attachment" - o.glass_thickness comes from
// admin_list_online_orders() (see supabase_orders_sync_tables.sql), which scans that order's
// synced lines for a 10mm/12mm mention. Blank when no such line was found.
//
// Clickable per direct request - "if there is an 10mm or 12mm glass can you make that field
// clickable and show the cut glass for that glass order, this way we can see the glass cut and
// from there we can convert it to PO". Links to glass-cut-list.html, which fetches this order's
// live lines itself and parses the tank dimensions back out of the custom aquarium line's spec
// text (see GlassCutList.parseAquariumLineSpec and buildCustomAquariumSpecText in orderNow.js).
function glassBadgeHtml(order) {
  if (!order.glass_thickness) return '';
  return `<a class="badge badge-glass" href="glass-cut-list.html?order=${encodeURIComponent(order.order_id)}" title="This order has a ${order.glass_thickness} glass custom aquarium line - click to see its glass cut list.">${order.glass_thickness} glass</a>`;
}

// Flags an order with a "custom" line (custom aquarium/stand/sump/etc - see
// admin_list_online_orders' has_custom_line comment in supabase_orders_sync_tables.sql) so it's
// obvious at a glance which orders need production work assigned via assignSelectHtml below.
function customBadgeHtml(order) {
  if (!order.has_custom_line) return '';
  return `<span class="badge badge-custom" title="This order has a custom-built line - it may need a Production Member assigned.">Custom</span>`;
}

// Flags an order that was created from a GMA conversation (docs/gma-conversations.html's "+ New
// Order", see admin_list_online_orders' is_gma_order comment in supabase_orders_sync_tables.sql) -
// links back to the originating Automated Order request for the full conversation/line detail.
function gmaBadgeHtml(order) {
  if (!order.is_gma_order) return '';
  return `<a class="badge badge-purple" href="automated-orders.html?order=${encodeURIComponent(order.gma_order_no || '')}" title="Created from a GMA conversation - click to see the originating request.">GMA Page</a>`;
}

// Production Order(s) built for this order (ProductionOrders.SourceOnlineOrderId - attachProductionOrders,
// sql/supabase_online_order_production_order_tag.sql) - per "in the online order.. can we tag the
// production order no. created?". Links to that production order in the SAME tab: the portal login is
// in sessionStorage (auth.js), which a target="_blank" link (noopener) doesn't carry over, so a new tab
// landed on the login page.
function prodOrderBadgeHtml(order) {
  return (order.production_orders || []).map((p) => `<a class="badge ${p.status === 'Finished' ? 'badge-success' : 'badge-neutral'}" href="production-orders.html?no=${encodeURIComponent(p.production_order_no)}" title="Production Order ${escapeHtml(p.production_order_no)} (${escapeHtml(p.status || '')}) was created for this order - click to open it.">${escapeHtml(p.production_order_no)}</a>`).join(' ');
}

// Dispatcher partial release (attachReleaseSummary, sql/supabase_online_order_partial_release.sql) -
// "Released 2/5" while some units are still pending. Nothing once fully shipped.
function releaseBadgeHtml(order) {
  const r = order.release;
  if (!r || Number(r.released_qty) >= Number(r.ordered_qty)) return '';
  return `<span class="oo-released" title="Partially released in ${r.batches} batch${r.batches === 1 ? '' : 'es'} - the rest is still pending">Released ${Number(r.released_qty)}/${Number(r.ordered_qty)}</span>`;
}

function orderBadgesHtml(order) {
  return `${otherBranchBadgeHtml(order)} ${glassBadgeHtml(order)} ${customBadgeHtml(order)} ${gmaBadgeHtml(order)} ${prodOrderBadgeHtml(order)} ${releaseBadgeHtml(order)}`;
}

// "Assigned To" dropdown(s) - per "maybe each order can be assign a tank maker and a stand maker.
// if an order has Aquarium order assign tank maker, if stand then we can assign stand maker": one
// order can need a Tank Maker (has_aquarium_line), a Stand Maker (has_stand_line), both, or
// neither, so this renders 0-2 maker dropdowns, plus a Dispatcher dropdown on every order
// (supabase_online_order_dispatcher.sql). Each lists only the staff holding that Staff Role
// (TankMaker / StandMaker / Dispatcher) from the shared roster
// (loadProductionMembers) - change is handled by the delegated listener wired to
// .assign-maker-select in init() below (data-role tells it which column to write via
// admin_assign_online_order_maker).
const MAKER_ROLES = {
  tank: { staffRole: 'TankMaker', label: 'Tank Maker', field: 'tank_maker' },
  stand: { staffRole: 'StandMaker', label: 'Stand Maker', field: 'stand_maker' },
  dispatcher: { staffRole: 'Dispatcher', label: 'Dispatcher', field: 'dispatcher' }
};

// ---------------------------------------------------------------- Production Done (per person)
// Per "can you give them a button where they can do production done on their side.. be careful
// because an order can be assigned to multiple user/employee" - each assignee marks only their own
// part (supabase_online_order_production_done.sql). Same parts rule as the server's
// _online_order_production_roles: tank / stand for custom aquarium / stand lines, dispatcher for a
// custom order with neither, nothing for a normal order.
function neededProductionRoles(o) {
  // No has_custom_line gate: a 10mm / 12mm glass order needs a Tank Maker without a custom line
  // (supabase_online_order_thick_glass_tank_maker.sql) - has_aquarium_line already covers both.
  if (!o) return [];
  const roles = [];
  if (o.has_aquarium_line) roles.push('tank');
  if (o.has_stand_line) roles.push('stand');
  // No dispatcher part any more (the dispatcher is recorded at shipping) - a custom order with neither
  // an aquarium nor a stand has nothing to make here and follows the POS like a normal order.
  return roles;
}

function myProductionRoles(o) {
  const me = currentSession?.username;
  return neededProductionRoles(o).filter((role) => me && o[`assigned_${MAKER_ROLES[role].field}`] === me);
}

function isProductionDone(o) {
  const needed = neededProductionRoles(o);
  return needed.length > 0 && needed.every((role) => o.production_done?.[role]);
}

function canChangeProduction(o) {
  // Walk-ins are Shipped in Pancake from the start - open while their portal stage is.
  if (o?.walkin_stage) return ['To Assign', 'Assigned', 'Production Done'].includes(o.walkin_stage);
  return ['confirmed', 'submitted', 'printed', 'assigned'].includes((o?.status || '').trim().toLowerCase());
}

// Status shown in the list / card: 'Production Done' once every part is done (display only - the
// real status stays Assigned until the Production Manager / POS moves it on).
function listDisplayStatus(o) {
  if (o?.walkin_stage) return o.walkin_stage;
  return isProductionDone(o) && canChangeProduction(o) ? 'Production Done' : orderDisplayStatus(o);
}

// Open "send back for rework" notes (supabase_online_order_production_rework.sql) - one per part,
// until that part is marked done again.
async function attachRework(rows, ids) {
  await attachReworkCounts(rows, ids);
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_rework', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_ids: ids
  });
  if (error) {
    console.error('staff_get_online_order_rework failed:', error);
    return;
  }
  const byOrder = new Map(rows.map((o) => [String(o.order_id), o]));
  (data || []).forEach((w) => {
    const o = byOrder.get(String(w.order_id));
    if (o) o.rework[w.role] = w;
  });
}

// How many times each order was sent back (supabase_online_order_rework_history.sql) - one Send
// Back click counts once however many parts it covered.
async function attachReworkCounts(rows, ids) {
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_rework_counts', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_ids: ids
  });
  if (error) {
    console.error('staff_get_online_order_rework_counts failed:', error);
    return;
  }
  const byOrder = new Map(rows.map((o) => [String(o.order_id), o]));
  (data || []).forEach((c) => {
    const o = byOrder.get(String(c.order_id));
    if (o) o.rework_count = c.send_back_count;
  });
}

function reworkCountBadgeHtml(o) {
  const n = Number(o.rework_count) || 0;
  if (!n) return '';
  return ` <span class="oo-rework-count" title="Sent back for rework ${n} time${n === 1 ? '' : 's'}">&#8634; ${n}</span>`;
}

// Order card: every send-back of this order, newest first.
async function loadOrderCardReworkHistory(orderId) {
  const tab = document.getElementById('orderCardReworkTab');
  const o = findFlatOrder(orderId);
  const n = Number(o?.rework_count) || 0;
  tab.classList.toggle('hidden', !n);
  if (!n) return;
  document.getElementById('orderCardReworkSummary').textContent = `Sent back ${n} time${n === 1 ? '' : 's'}`;
  const body = document.getElementById('ocReworkBody');
  body.innerHTML = '<tr><td colspan="5" class="cell-msg">Loading...</td></tr>';
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_rework_history', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: String(orderId)
  });
  if (openCardOrderId !== String(orderId)) return;
  if (error) {
    body.innerHTML = `<tr><td colspan="5" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }
  const fmt = (t) => (t ? new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');
  body.innerHTML = (data || []).map((r) => `
    <tr>
      <td>${escapeHtml(fmt(r.sent_back_at))}<small class="oo-rh-sub">by ${escapeHtml(r.sent_back_by_name || '')}</small></td>
      <td>${escapeHtml(MAKER_ROLES[r.role]?.label || r.role)}</td>
      <td>${escapeHtml(r.reason || '')}</td>
      <td>${escapeHtml(r.prev_done_by_name || '')}<small class="oo-rh-sub">${escapeHtml(fmt(r.prev_done_at))}</small></td>
      <td>${r.fixed_at
        ? `<span class="oo-done">&#10003; Fixed</span><small class="oo-rh-sub">${escapeHtml(r.fixed_by_name || '')} · ${escapeHtml(fmt(r.fixed_at))}</small>`
        : '<span class="oo-rework">&#8634; Open</span>'}</td>
    </tr>`).join('') || '<tr><td colspan="5" class="cell-msg">No send-backs.</td></tr>';
}

function reworkNoteText(o) {
  return Object.entries(o.rework || {})
    .map(([role, w]) => `${MAKER_ROLES[role].label}: ${w.reason}`)
    .join(' · ');
}

function productionDoneTickHtml(o, role) {
  const w = o.rework?.[role];
  if (w && !o.production_done?.[role]) {
    return ` <span class="oo-rework" title="Sent back by ${escapeHtml(w.sent_back_by_name || w.sent_back_by)}: ${escapeHtml(w.reason)}">&#8634; Rework</span>`;
  }
  const d = o.production_done?.[role];
  if (!d) return '';
  const when = d.done_at ? new Date(d.done_at).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
  return ` <span class="oo-done" title="Production done by ${escapeHtml(d.done_by_name || d.done_by)}${when ? ' · ' + when : ''}">&#10003; Done</span>`;
}

async function attachProductionDone(rows) {
  const ids = rows.filter((o) => neededProductionRoles(o).length).map((o) => String(o.order_id));
  rows.forEach((o) => { o.production_done = {}; o.rework = {}; });
  if (!ids.length) return;
  await attachRework(rows, ids);
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_production_done', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_ids: ids
  });
  if (error) {
    console.error('staff_get_online_order_production_done failed:', error);
    return;
  }
  const byOrder = new Map(rows.map((o) => [String(o.order_id), o]));
  (data || []).forEach((d) => {
    const o = byOrder.get(String(d.order_id));
    if (o) o.production_done[d.role] = d;
  });
}

// Sets both Production Done buttons (list + card) for an order: hidden for non-makers, "Undo" once
// all of this user's parts are done, disabled when they have no part or the order has moved on.
function updateProductionDoneButton(btnId, o) {
  const btn = document.getElementById(btnId);
  if (!currentSession?.isOrderMaker) { btn.classList.add('hidden'); return; }
  const mine = o ? myProductionRoles(o) : [];
  // Maker focus: hidden only when the maker has no part on this order (e.g. a dispatcher's To Ship
  // order shows Mark Shipped instead). With a part, it always shows - disabled with the reason in its
  // label when production can't change - per "in the maker view.. i want them to be able to click
  // production done as well.. right now i cannot see production done button".
  btn.classList.toggle('hidden', isMakerFocus() && !mine.length);
  const allMineDone = mine.length > 0 && mine.every((role) => o.production_done?.[role]);
  const locked = !!o && mine.length > 0 && !canChangeProduction(o);
  // Phones have no tooltips - the maker view says why on the button itself.
  btn.querySelector('.pd-label').textContent = (allMineDone ? 'Undo Production Done' : 'Production Done')
    + (locked && isMakerFocus() ? ` (order is ${listDisplayStatus(o) || o.status})` : '');
  btn.classList.toggle('is-undo', allMineDone);
  btn.disabled = !mine.length || !canChangeProduction(o);
  btn.title = !o ? 'Select an order'
    : !mine.length ? 'You are not assigned to a production part of this order'
    : !canChangeProduction(o) ? `This order is already ${o.status}`
    : `Your part: ${mine.map((r) => MAKER_ROLES[r].label).join(' + ')}`;
}

// Phone view of My Assignments - see #myAssignmentCards in online-orders.html. Rendered on every
// My Assignments load; CSS decides whether it or the grid shows.
// Est. Delivery for makers - per "in the mobile show the estimated delivery date": a friendly date plus
// how long is left, e.g. "Mon, Oct 5 · in 7 days" / "Overdue 2 days". Dates are Manila calendar days.
function etaHtml(dateStr) {
  if (!dateStr) return '<span class="oo-eta none">Not set</span>';
  const [y, m, d] = String(dateStr).slice(0, 10).split('-').map(Number);
  if (!y || !m || !d) return `<span class="oo-eta">${escapeHtml(dateStr)}</span>`;
  const due = new Date(y, m - 1, d);
  const today = new Date(new Date().toLocaleString('en-US', { timeZone: 'Asia/Manila' }));
  today.setHours(0, 0, 0, 0);
  const days = Math.round((due - today) / 86400000);
  const label = due.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', ...(y !== today.getFullYear() ? { year: 'numeric' } : {}) });
  const left = days < 0 ? `Overdue ${-days} day${days === -1 ? '' : 's'}`
    : days === 0 ? 'Today' : days === 1 ? 'Tomorrow' : `in ${days} days`;
  const tone = days < 0 ? 'late' : days <= 1 ? 'soon' : '';
  return `<span class="oo-eta ${tone}"><b>${escapeHtml(label)}</b> <i>${escapeHtml(left)}</i></span>`;
}

function renderMyAssignmentCards(rows) {
  const box = document.getElementById('myAssignmentCards');
  if (!rows.length) {
    box.innerHTML = '<div class="oo-mc-empty">Nothing to do right now - no open work is assigned to you.</div>';
    return;
  }
  const me = currentSession.username;
  box.innerHTML = rows.map((o) => {
    const status = listDisplayStatus(o);
    const mine = myProductionRoles(o);
    const allMineDone = mine.length > 0 && mine.every((role) => o.production_done?.[role]);
    const canChange = canChangeProduction(o);
    const partChips = neededProductionRoles(o).map((role) => {
      const field = MAKER_ROLES[role].field;
      const who = o[`assigned_${field}_name`] || o[`assigned_${field}`];
      const done = !!o.production_done?.[role];
      const rework = !done && !!o.rework?.[role];
      const isMe = o[`assigned_${field}`] === me;
      return `<span class="oo-mc-part${done ? ' done' : ''}${rework ? ' rework' : ''}${isMe ? ' me' : ''}">
        <b>${escapeHtml(MAKER_ROLES[role].label)}</b> ${isMe ? 'You' : escapeHtml(who || 'Not assigned')}
        <i>${done ? '&#10003; Done' : rework ? '&#8634; Rework' : 'To do'}</i></span>`;
    }).join('');
    // Dispatcher is only known once someone has shipped it (recorded by Mark Shipped).
    const dispatcher = !o.assigned_dispatcher ? ''
      : `<div class="oo-mc-line"><span>Dispatcher</span>${o.assigned_dispatcher === me ? 'You' : escapeHtml(o.assigned_dispatcher_name || o.assigned_dispatcher)}</div>`;
    // The assigned Dispatcher marks a To Ship order Shipped once it's delivered; otherwise the
    // maker's Production Done (hidden once the order has moved on).
    const pdBtn = canMarkShipped(o)
      ? `<button type="button" class="oo-mc-btn primary" data-shipped-order="${escapeHtml(o.order_id)}">&#128666; ${o.release ? 'Release Remaining' : 'Release / Ship'}</button>`
      : mine.length && canChange ? `<button type="button" class="oo-mc-btn ${allMineDone ? 'undo' : 'primary'}" data-pd-order="${escapeHtml(o.order_id)}">
        ${allMineDone ? 'Undo Production Done' : '&#10003; Production Done'}</button>`
      // Their part, but production is closed - shown greyed out with the reason rather than hidden.
      : mine.length ? `<button type="button" class="oo-mc-btn" disabled>Production Done (order is ${escapeHtml(status)})</button>` : '';
    return `
      <article class="oo-mc is-clickable" data-order-id="${escapeHtml(o.order_id)}" data-open-order="${escapeHtml(o.order_id)}" role="button" tabindex="0" aria-label="Open order ${escapeHtml(o.order_id)}">
        <header class="oo-mc-head">
          <span class="oo-mc-id">#${escapeHtml(o.order_id)}</span>
          <span class="oo-mc-status ${status === 'Production Done' ? 'done' : ''}">${escapeHtml(status)}</span>${reworkCountBadgeHtml(o)} ${prodOrderBadgeHtml(o)} ${releaseBadgeHtml(o)}
          <span class="oo-mc-chevron" aria-hidden="true">&rsaquo;</span>
        </header>
        <div class="oo-mc-customer">${escapeHtml(o.customer_name || '')}</div>
        ${o.received_at_shop ? `<div class="oo-mc-line"><span>Walk-in</span>${escapeHtml(o.walkin_customer_phone || 'No contact no.')}</div>` : ''}
        <div class="oo-mc-line oo-mc-eta"><span>Est. Delivery</span>${etaHtml(o.estimated_delivery_date)}</div>
        <div class="oo-mc-line"><span>Handover</span>${o.for_delivery ? 'Delivery' : 'Pickup'}</div>
        <div class="oo-mc-line"><span>Branch</span>${escapeHtml(o.warehouse_name || o.location_id || '-')} ${glassBadgeHtml(o)}</div>
        ${dispatcher}
        <div class="oo-mc-parts">${partChips}</div>
        ${reworkNoteText(o) ? `<div class="oo-mc-rework"><b>Sent back for rework</b> ${escapeHtml(reworkNoteText(o))}</div>` : ''}
        ${o.note_print ? `<div class="oo-mc-note">${escapeHtml(o.note_print)}</div>` : ''}
        ${posNoteSummary(o) ? `<div class="oo-mc-note"><b>POS:</b> ${escapeHtml(posNoteSummary(o))}</div>` : ''}
        ${pdBtn ? `<div class="oo-mc-actions">${pdBtn}</div>` : ''}
      </article>`;
  }).join('');
}

// Restock Production Orders (production-orders.html, supabase_production_orders.sql) the user is a
// Tank / Stand Maker on, whose part isn't done yet - shown under My Assignments on every width.
// Each card opens the order on the Production Orders page, where the maker marks it done.
async function loadMyProductionOrderCards() {
  const box = document.getElementById('myProductionOrderCards');
  if (!box) return;
  if (!myAssignmentsOnly || !currentSession.isOrderMaker) {
    box.classList.add('hidden');
    return;
  }
  const me = currentSession.username;
  const { data, error } = await supabaseClient.rpc('staff_list_production_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: null,
    p_status: 'Released',
    p_assigned_to_me: true,
    p_page: 1,
    p_page_size: 50
  });
  // Quietly skipped until supabase_production_orders.sql has been run.
  if (error) { console.warn('staff_list_production_orders:', error.message); box.classList.add('hidden'); return; }
  const myOpenParts = (o) => ['tank', 'stand'].filter((p) => o[`${p}_maker`] === me && o[`needs_${p}`] && !o[`${p}_done_at`]);
  const open = (data || []).filter((o) => myOpenParts(o).length);
  myProductionOrderCount = open.length;
  setMyAssignmentsCount(null);
  if (!myAssignmentsOnly || !open.length) { box.classList.add('hidden'); return; }
  // Production work waiting - drop the "Nothing to do right now" line the online-order list left.
  document.querySelectorAll('#myAssignmentCards .oo-mc-empty, #orderTableBody .cell-msg').forEach((el) => {
    el.textContent = 'No online orders assigned to you - see your Production Orders below.';
  });

  // Per "i want the maker to see only the lines of what needs to be done together with the color
  // variant, Qty, and the button production done.. same as the online orders": each card lists just
  // this maker's part of the order (Tank or Stand lines), with a big Production Done button.
  const linesByOrder = new Map();
  const reworkByOrder = new Map();
  await Promise.all(open.map(async (o) => {
    const { data: lines, error: linesError } = await supabaseClient.rpc('staff_list_production_order_lines', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_no: o.order_no
    });
    linesByOrder.set(o.order_no, linesError ? null : (lines || []));
    // Undone Production Done = rework (supabase_production_order_rework.sql) - none until it's run.
    const { data: rework } = await supabaseClient.rpc('staff_list_production_order_rework', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_no: o.order_no
    });
    reworkByOrder.set(o.order_no, (rework || []).filter((r) => !r.fixed_at));
  }));
  if (!myAssignmentsOnly) { box.classList.add('hidden'); return; }

  prodCardData.clear();
  box.innerHTML = `<h3 class="oo-prod-cards-title">Production Orders (restock)</h3>` + open.map((o) => {
    const parts = myOpenParts(o);
    const lines = linesByOrder.get(o.order_no);
    const mine = (lines || []).filter((l) => parts.includes(l.part) && Number(l.quantity) > Number(l.qty_output || 0));
    const total = mine.reduce((n, l) => n + Number(l.quantity) - Number(l.qty_output || 0), 0);
    const partLabel = parts.map((p) => (p === 'tank' ? 'Tank Maker' : 'Stand Maker')).join(' + ');
    const rework = (reworkByOrder.get(o.order_no) || []).filter((r) => parts.includes(r.part));
    prodCardData.set(o.order_no, { o, lines: lines === null ? null : mine, partLabel, rework });
    return `
      <article class="oo-mc oo-prod-mc is-clickable" data-prod-no="${escapeHtml(o.order_no)}" data-prod-parts="${escapeHtml(parts.join(','))}" role="button" tabindex="0" aria-label="Open production order ${escapeHtml(o.order_no)}">
        <header class="oo-mc-head">
          <span class="oo-mc-id">${escapeHtml(o.order_no)}</span>
          <span class="oo-mc-status">${escapeHtml(partLabel)}</span>${rework.length ? '<span class="oo-rework">&#8634; Rework</span>' : ''}
          <span class="oo-mc-chevron" aria-hidden="true">&rsaquo;</span>
        </header>
        ${rework.map((r) => `<div class="oo-mc-rework"><b>Sent back for rework</b> ${escapeHtml(r.reason || '')}</div>`).join('')}
        ${o.description ? `<div class="oo-mc-customer">${escapeHtml(o.description)}</div>` : ''}
        <div class="oo-mc-line oo-mc-eta"><span>Due</span>${etaHtml(o.due_date)}</div>
        <div class="oo-mc-line"><span>Branch</span>${escapeHtml(o.warehouse_name || '')}</div>
        ${lines === null
          ? '<div class="oo-mc-note">Could not load the lines - open the order to see them.</div>'
          : `<table class="oo-prod-lines">
              <thead><tr><th>Build</th><th>Color</th><th class="num">Qty</th></tr></thead>
              <tbody>${mine.map((l) => {
                const colour = prodLineColour(l);
                return `<tr>
                  <td>${escapeHtml(prodLineName(l))}</td>
                  <td>${colour ? `<span class="oo-prod-colour ${colour.toLowerCase()}"><i></i>${escapeHtml(colour)}</span>` : `<span class="oo-prod-variant">${escapeHtml(l.variant_name && !l.variant_name.startsWith(l.item_code) ? l.variant_name : '-')}</span>`}</td>
                  <td class="num"><b>${formatProdQty(Number(l.quantity) - Number(l.qty_output || 0))}</b></td>
                </tr>`;
              }).join('') || '<tr><td colspan="3" class="oo-prod-none">Nothing left to build.</td></tr>'}</tbody>
              ${mine.length > 1 ? `<tfoot><tr><td colspan="2">Total</td><td class="num"><b>${formatProdQty(total)}</b></td></tr></tfoot>` : ''}
            </table>`}
        ${o.notes ? `<div class="oo-mc-note">${escapeHtml(o.notes)}</div>` : ''}
        <div class="oo-mc-actions">
          <button type="button" class="oo-mc-btn primary" data-prod-done="${escapeHtml(o.order_no)}">&#10003; Production Done</button>
        </div>
      </article>`;
  }).join('');
  box.classList.remove('hidden');

  if (!box.dataset.wired) {
    box.dataset.wired = '1';
    box.addEventListener('click', (event) => {
      const btn = event.target.closest('[data-prod-done]');
      if (btn) { handleProdOrderDoneClick(btn); return; }
      // Per "Production order cannot open the card" - the whole card opens its lines, same as the
      // online order cards above.
      const card = event.target.closest('.oo-prod-mc[data-prod-no]');
      if (card) openProdOrderCard(card.dataset.prodNo);
    });
    box.addEventListener('keydown', (event) => {
      const card = event.target.closest('.oo-prod-mc[data-prod-no]');
      if (!card || event.target !== card || (event.key !== 'Enter' && event.key !== ' ')) return;
      event.preventDefault();
      openProdOrderCard(card.dataset.prodNo);
    });
  }
}

// Production Order card for a maker (#prodOrderCardModal): Item / Description / SKU / Qty left to
// build for each of their lines, plus Production Done. Built from what loadMyProductionOrderCards
// already fetched - no extra calls.
const prodCardData = new Map();
let openProdCardNo = null;

function openProdOrderCard(orderNo) {
  const entry = prodCardData.get(orderNo);
  if (!entry) return;
  const { o, lines, partLabel, rework } = entry;
  openProdCardNo = orderNo;
  document.getElementById('prodCardTitle').textContent = orderNo;
  document.getElementById('prodCardPart').textContent = partLabel;
  document.getElementById('prodCardSummary').innerHTML = `
    ${o.description ? `<div class="oc-ms-row"><span>Order</span>${escapeHtml(o.description)}</div>` : ''}
    <div class="oc-ms-row"><span>Due</span>${etaHtml(o.due_date)}</div>
    <div class="oc-ms-row"><span>Branch</span>${escapeHtml(o.warehouse_name || '-')}</div>
    <div class="oc-ms-row"><span>Your part</span>${escapeHtml(partLabel)}</div>
    ${o.notes ? `<div class="oo-mc-note">${escapeHtml(o.notes)}</div>` : ''}
    ${rework.map((r) => `<div class="oo-mc-rework"><b>Sent back for rework</b> ${escapeHtml(r.reason || '')}</div>`).join('')}`;
  document.getElementById('prodCardLines').innerHTML = lines === null
    ? '<div class="oo-mc-empty">Could not load the lines - close and refresh the page.</div>'
    : lines.map((l) => {
      const colour = prodLineColour(l);
      return makerLineCardHtml({
        item: prodLineName(l),
        description: l.description,
        sku: l.sku || l.item_code,
        qty: formatProdQty(Number(l.quantity) - Number(l.qty_output || 0)),
        tag: colour ? `<span class="oo-prod-colour ${colour.toLowerCase()}"><i></i>${escapeHtml(colour)}</span>` : ''
      });
    }).join('') || '<div class="oo-mc-empty">Nothing left to build.</div>';
  document.getElementById('prodCardModal').classList.remove('hidden');
}

function closeProdOrderCard() {
  openProdCardNo = null;
  document.getElementById('prodCardModal').classList.add('hidden');
}

function wireProdOrderCard() {
  document.getElementById('closeProdCardBtn').addEventListener('click', closeProdOrderCard);
  document.getElementById('prodCardDoneBtn').addEventListener('click', async (e) => {
    if (!openProdCardNo) return;
    const card = document.querySelector(`#myProductionOrderCards [data-prod-no="${CSS.escape(openProdCardNo)}"] [data-prod-done]`);
    if (!card) return;
    if (await handleProdOrderDoneClick(card)) closeProdOrderCard();
  });
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || document.getElementById('prodCardModal').classList.contains('hidden')) return;
    if (!document.getElementById('confirmActionDialog').classList.contains('hidden')) return;
    closeProdOrderCard();
  });
}

// Same colour rule as the Production Orders page (supabase_production_variant_colour.sql's colour,
// else black|BLK / clear|CLR in the variant or description).
function prodLineColour(l) {
  if (l.colour) return l.colour;
  for (const t of [l.variant_name, l.description]) {
    if (/black|\bblk\b/i.test(t || '')) return 'Black';
    if (/clear|\bclr\b/i.test(t || '')) return 'Clear';
  }
  return null;
}

// The item's plain name - not the generated "name - Black - variant" description.
function prodLineName(l) {
  const desc = (l.description || '').trim();
  const name = (l.item_name || '').trim();
  if (name && (!desc || desc.toLowerCase().startsWith(name.toLowerCase()))) return name;
  return desc || l.item_code || '';
}

function formatProdQty(n) {
  return Number(n || 0).toLocaleString(undefined, { maximumFractionDigits: 4 });
}

async function handleProdOrderDoneClick(btn) {
  const card = btn.closest('[data-prod-no]');
  const orderNo = card.dataset.prodNo;
  const parts = card.dataset.prodParts.split(',').filter(Boolean);
  const partText = parts.map((p) => (p === 'tank' ? 'tank' : 'stand')).join(' and ');
  const ok = await confirmAction({
    caption: 'PRODUCTION DONE',
    title: orderNo,
    message: `Is your part (${partText}) completely finished?\n\nThe order will leave your list.`,
    confirmLabel: 'Yes, Production Done',
    tone: 'is-done'
  });
  if (!ok) return false;

  btn.disabled = true;
  for (const part of parts) {
    const { error } = await supabaseClient.rpc('staff_set_production_order_part_done', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_no: orderNo,
      p_part: part,
      p_done: true
    });
    if (error) {
      btn.disabled = false;
      window.alert(`Could not mark ${orderNo} Production Done: ${error.message}`);
      return false;
    }
  }
  loadMyProductionOrderCards();
  return true;
}

function wireMyAssignmentCards() {
  document.getElementById('myAssignmentCards').addEventListener('click', (event) => {
    const pd = event.target.closest('[data-pd-order]');
    if (pd) { handleProductionDoneClick(pd.dataset.pdOrder, pd); return; }
    const shipped = event.target.closest('[data-shipped-order]');
    if (shipped) { markOrderShipped(shipped.dataset.shippedOrder, shipped); return; }
    // The whole card opens the order (per "allow the user to click the card to open the details
    // instead of the open button") - the action buttons above are handled first and return.
    const open = event.target.closest('[data-open-order]');
    if (open) {
      event.preventDefault();
      selectedOrderId = open.dataset.openOrder;
      openOrderCard(open.dataset.openOrder);
    }
  });
  document.getElementById('myAssignmentCards').addEventListener('keydown', (event) => {
    const card = event.target.closest('.oo-mc.is-clickable');
    if (!card || event.target !== card || (event.key !== 'Enter' && event.key !== ' ')) return;
    event.preventDefault();
    selectedOrderId = card.dataset.openOrder;
    openOrderCard(card.dataset.openOrder);
  });
}

// ---------------------------------------------------------------- Next step (status-based)
// Per "once the order is in production done status.. should we add a button there 'Ready to ship'
// ... i want the button to change base on the status" - one Production Manager / Super User button
// whose label follows the custom order's stage:
//   Confirmed / Printed, not fully assigned  -> Assign        (opens the Assign popup)
//   Assigned, parts still being made         -> In Production 1/2 (disabled, shows progress)
//   Production Done (every part done)        -> Ready to Ship (To Ship in the portal + Pancake,
//                                               asks to message the customer - handleToShipClick)
//   To Ship (any order, custom or normal)    -> Mark Shipped (Pancake status 2 + portal 'Shipped',
//                                               admin_mark_online_order_shipped - no customer message)
// Other normal-order stages and anything already Shipped get no button (the POS carries on as before).
function isToShipOrder(o) {
  return ['to ship', 'packing', 'packed'].includes((o?.status || '').trim().toLowerCase());
}

// Per "i want that dispatcher assigned to mark it as shipped" - the Production Manager / Super User
// on any To Ship order, or the order's own assigned Dispatcher (admin_mark_online_order_shipped
// checks the same server-side).
function canMarkShipped(o) {
  if (!isToShipOrder(o)) return false;
  // Any Dispatcher - they're recorded as the order's dispatcher when they mark it Shipped.
  return canAssignOrders() || (currentSession?.staffRoles || []).includes('Dispatcher');
}

// ---- Stock tank / stand / sump orders - per "if the orders is tank / stand or sump can we check the
// serials if there are no serials available is it possible we can assign the order? then if there is an
// serial can we to-ship the order directly?" (supabase_online_order_stock_ship.sql). For an order whose
// serial-tracked lines are STOCK items (no custom line), counted at the order's own branch:
//   every unit has an In Stock serial           -> Ready to Ship now (pick the serials, To Ship)
//   some don't, no build yet                    -> Assign: creates a Production Order for the missing
//                                                  units with the chosen makers, linked to this order
//   that Production Order is Open / Released    -> "In Production PRD-..." (opens it)
// Loaded per selected / opened order and cached until the list reloads.
const stockStatusCache = new Map(); // order_id -> row of staff_get_online_order_stock_status, or 'loading'
const shipFromStockOrderIds = new Set();
let shipSerialWarehouse = null; // order's branch while picking serials for a ship-from-stock order

function stockStatusFor(o) {
  const s = o ? stockStatusCache.get(String(o.order_id)) : null;
  return s && s !== 'loading' ? s : null;
}

// 'assigned' too: a stock build moves the order to Assigned (supabase_online_order_stock_build_assigned.sql)
// and it still needs this check for In Production / Ready to Ship.
function isStockCheckCandidate(o) {
  if (!o || !canAssignOrders() || neededProductionRoles(o).length) return false;
  return ['confirmed', 'submitted', 'printed', 'assigned'].includes((o.status || '').trim().toLowerCase());
}

async function ensureStockStatus(o) {
  if (!isStockCheckCandidate(o)) return;
  const key = String(o.order_id);
  if (stockStatusCache.has(key)) return;
  stockStatusCache.set(key, 'loading');
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_stock_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_ids: [key]
  });
  if (error) {
    // Quietly nothing until supabase_online_order_stock_ship.sql is run.
    console.warn('staff_get_online_order_stock_status:', error.message);
    stockStatusCache.delete(key);
    return;
  }
  stockStatusCache.set(key, (data || [])[0] || { order_id: key, needs_serial: false });
  if (String(selectedOrderId) === key) updateOrderActionState();
  if (String(openCardOrderId) === key) updateNextStepButton('cardNextStepBtn', o);
}

// Same as stockLinesSummary, as HTML with the SKU in bold so the picker notices it (sku from
// supabase_online_order_stock_status_sku.sql; Item Code until that's run).
function stockLinesHtml(s) {
  return (s?.lines || []).map((l) => `${escapeHtml(l.description || l.item_code)} - SKU <b>${escapeHtml(l.sku || l.item_code || '-')}</b>: ${l.available}/${l.needed} in stock`).join('\n');
}

function stockLinesSummary(s) {
  return (s?.lines || []).map((l) => `${l.description || l.item_code}${l.variant_name ? ` (${l.variant_name})` : ''}: ${l.available}/${l.needed} in stock`).join('\n');
}

function nextStepForStock(o) {
  const s = stockStatusFor(o);
  if (!s || !s.needs_serial || s.has_custom_line) return null;
  if (s.all_available) {
    return { action: 'ship-stock', label: 'Ready to Ship', icon: 'ico-ship', title: `In stock at ${s.warehouse_name || 'this branch'} - pick the serial(s) and move it to To Ship.\n${stockLinesSummary(s)}` };
  }
  // Being built but not Assigned yet - the status update to Pancake failed, or it was linked before
  // stock builds moved the order to Assigned. Retries just that (and the customer message).
  if (s.production_order_no && ['Open', 'Released'].includes(s.production_order_status)
      && (o.status || '').trim().toLowerCase() !== 'assigned') {
    return { action: 'stock-assigned', label: 'Set Assigned', icon: 'ico-assign', title: `Being built on ${s.production_order_no}, but the order isn't Assigned yet. Moves it to Assigned in the portal and Pancake and sends the customer the "in production" message.` };
  }
  if (s.production_order_no && ['Open', 'Released'].includes(s.production_order_status)) {
    return { action: 'open-prod', label: `In Production ${s.production_order_no}`, icon: 'ico-done', title: `Being built on ${s.production_order_no} (${s.production_order_status}). It can ship once its output is posted.\n${stockLinesSummary(s)}` };
  }
  return { action: 'build', label: 'Assign', icon: 'ico-assign', title: `Not enough in stock at ${s.warehouse_name || 'this branch'} - assign makers to build the missing units (creates a Production Order).\n${stockLinesSummary(s)}` };
}

// "Assign" for a stock order with missing units: a Production Order for just the shortfall, with the
// makers picked here, linked to the online order, Released so the makers see it right away.
async function openStockBuildDialog(o) {
  const s = stockStatusFor(o);
  if (!s) return;
  const missing = (s.lines || []).filter((l) => l.available < l.needed)
    .map((l) => ({ ...l, qty: l.needed - l.available, part: /(stand(?!ard)|top[\s_-]*cover)/i.test(`${l.description || ''} ${l.item_code || ''}`) ? 'stand' : 'tank' }));
  if (!missing.length) return;
  await loadProductionMembers();
  const parts = [...new Set(missing.map((m) => m.part))];
  const makerOptions = (role) => '<option value="">(Not assigned)</option>' + productionMembers
    .filter((m) => (m.staff_roles || []).includes(role))
    .map((m) => `<option value="${escapeHtml(m.username)}">${escapeHtml(m.display_name)}</option>`).join('');

  let dialog = document.getElementById('stockBuildDialog');
  if (!dialog) {
    dialog = document.createElement('div');
    dialog.id = 'stockBuildDialog';
    dialog.className = 'modal-backdrop hidden';
    document.body.appendChild(dialog);
  }
  dialog.innerHTML = `
    <div class="modal-panel" style="max-width:560px;" role="dialog" aria-modal="true">
      <div class="bc-doc-caption" style="font-size:11px; letter-spacing:.06em; color:var(--text-muted);">ASSIGN - BUILD MISSING UNITS</div>
      <h3 style="margin:2px 0 6px;">${escapeHtml(orderLabel(o))}</h3>
      <p class="muted" style="margin:0 0 10px;">Not enough in stock at <b>${escapeHtml(s.warehouse_name || 'this branch')}</b>. This creates a Production Order for the missing units and hands it to the makers. Once its output is posted, the new serials are in stock and this order can go Ready to Ship.</p>
      <table class="bc-grid" style="width:100%; margin-bottom:12px;">
        <thead><tr><th>Build</th><th>Variant</th><th class="num">Need</th><th class="num">In stock</th><th class="num">To build</th></tr></thead>
        <tbody>${missing.map((m) => `<tr><td>${escapeHtml(m.description || m.item_code)}</td><td>${escapeHtml(m.variant_name || '-')}</td><td class="num">${m.needed}</td><td class="num">${m.available}</td><td class="num"><b>${m.qty}</b></td></tr>`).join('')}</tbody>
      </table>
      ${parts.includes('tank') ? `<label style="display:block; margin-bottom:8px;">Tank Maker<select id="sbTankMaker" style="width:100%;">${makerOptions('TankMaker')}</select></label>` : ''}
      ${parts.includes('stand') ? `<label style="display:block; margin-bottom:8px;">Stand Maker<select id="sbStandMaker" style="width:100%;">${makerOptions('StandMaker')}</select></label>` : ''}
      <label style="display:block; margin-bottom:8px;">Due date<input type="date" id="sbDueDate" value="${escapeHtml(o.estimated_delivery_date || '')}" /></label>
      <div id="sbError" class="error-text hidden"></div>
      <div style="display:flex; gap:8px; justify-content:flex-end; margin-top:12px;">
        <button class="btn btn-secondary" type="button" id="sbCancelBtn">Cancel</button>
        <button class="btn btn-primary" type="button" id="sbCreateBtn">Create &amp; Assign</button>
      </div>
    </div>`;
  dialog.classList.remove('hidden');
  const close = () => dialog.classList.add('hidden');
  dialog.querySelector('#sbCancelBtn').addEventListener('click', close);
  dialog.addEventListener('click', (e) => { if (e.target === dialog) close(); });

  dialog.querySelector('#sbCreateBtn').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    const errEl = dialog.querySelector('#sbError');
    const fail = (msg) => { errEl.textContent = msg; errEl.classList.remove('hidden'); btn.disabled = false; btn.textContent = 'Create & Assign'; };
    errEl.classList.add('hidden');
    const tankMaker = dialog.querySelector('#sbTankMaker')?.value || null;
    const standMaker = dialog.querySelector('#sbStandMaker')?.value || null;
    if ((parts.includes('tank') && !tankMaker) || (parts.includes('stand') && !standMaker)) {
      fail('Pick a maker for every part to build.');
      return;
    }
    btn.disabled = true;
    btn.textContent = 'Creating...';
    const creds = { p_admin_username: currentSession.username, p_admin_password: currentSession.password };
    const { data: prodNo, error } = await supabaseClient.rpc('staff_save_production_order', {
      ...creds,
      p_no: null,
      p_description: `For online order ${o.order_id}${o.customer_name ? ' · ' + o.customer_name : ''}`,
      p_warehouse_id: o.location_id,
      p_due_date: dialog.querySelector('#sbDueDate').value || null,
      p_notes: `Built for online order ${o.order_id} - not enough in stock at ${s.warehouse_name || 'the branch'}.`,
      p_tank_maker: tankMaker,
      p_stand_maker: standMaker,
      p_lines: missing.map((m) => ({
        line_no: null, item_code: m.item_code, variant_id: m.variation_id || null,
        description: [m.description || m.item_code, m.variant_name].filter(Boolean).join(' - '), quantity: m.qty
      }))
    });
    if (error) { fail(error.message); return; }
    const link = await supabaseClient.rpc('staff_link_production_order_to_online_order', { ...creds, p_no: prodNo, p_order_id: String(o.order_id) });
    if (link.error) { fail(`Created ${prodNo}, but could not link it to this order: ${link.error.message}`); return; }
    const rel = await supabaseClient.rpc('staff_set_production_order_released', { ...creds, p_no: prodNo, p_released: true });
    // The link copied the makers onto the order; now it goes Assigned (portal + Pancake) and the
    // customer gets the "in production" message, same as a custom order.
    btn.textContent = 'Updating status...';
    const assigned = await syncAssignedStatus(o, btn);
    close();
    o.production_orders = [{ order_id: String(o.order_id), production_order_no: prodNo, status: rel.error ? 'Open' : 'Released' }, ...(o.production_orders || [])];
    refreshOpenOrderCardHeader();
    await refreshCurrentOrders();
    if (!document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
    stockStatusCache.delete(String(o.order_id));
    await ensureStockStatus(findFlatOrder(o.order_id) || o);
    alert([
      rel.error
        ? `Created ${prodNo} for order ${o.order_id}, but it couldn't be Released (${rel.error.message}) - release it on Production Orders so the makers see it.`
        : `Created and released ${prodNo} for order ${o.order_id}. The makers can see it now; once its output is posted, this order can go Ready to Ship.`,
      assignedStatusNote(o, assigned)
    ].filter(Boolean).join('\n\n'));
  });
}

// Moves the order to 'Assigned' in the portal + Pancake once every needed maker is set (or a stock build
// is linked), or back if one was cleared - admin_sync_online_order_assigned_status. First time Assigned,
// the customer gets the "in production" message (supabase_online_order_assigned_message.sql); for a GMA
// Page order the SQL can't reach the GMA Page's Send API, so it hands back the psid + text and it's sent
// here (supabase_online_order_assigned_message_gma.sql). Returns { error } or { sync }.
async function syncAssignedStatus(o, btn) {
  const { data, error } = await supabaseClient.rpc('admin_sync_online_order_assigned_status', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: o.order_id
  });
  if (error) return { error };
  const sync = Array.isArray(data) ? data[0] : data;
  if (sync?.gma_psid && sync.gma_message) {
    if (btn) btn.textContent = 'Messaging customer...';
    const gma = await sendGmaAssignedMessage(o.order_id, sync.gma_psid, sync.gma_message);
    sync.message_sent = gma.sent;
    sync.message_error = gma.error;
  }
  return { sync };
}

// What to tell the user after syncAssignedStatus - '' when there's nothing to say.
function assignedStatusNote(o, { error, sync } = {}) {
  if (error) return `The order wasn't moved to Assigned: ${error.message}`;
  if (!sync?.changed || sync.new_status !== 'Assigned') return '';
  const eta = sync.estimated_delivery_date ? `Estimated delivery date: ${sync.estimated_delivery_date}.` : 'No estimated delivery date was set (check the glass turnaround days).';
  if (sync.message_sent) return `Order ${o.order_id} is now Assigned. The customer was sent the "in production" message.\n${eta}`;
  if (sync.message_error) return `Order ${o.order_id} is now Assigned, but the customer message failed: ${sync.message_error}\n${eta}`;
  return `Order ${o.order_id} is now Assigned.`;
}

// Walk-in in production (portal-only stage, supabase_walkin_order_portal_status.sql):
//   To Assign        -> Assign (Production Manager)
//   Assigned         -> In Production 1/2 (progress only)
//   Production Done  -> Mark Picked Up (any staff except maker-only accounts - whoever hands it over)
//   Completed        -> Undo Picked Up (in case it was tapped by mistake)
// Nothing goes to Pancake - the sale stays Shipped there.
function nextStepForWalkin(o) {
  const canHandOver = !myAssignmentsLocked;
  const needed = neededProductionRoles(o);
  switch (o.walkin_stage) {
    case 'To Assign':
      return canAssignOrders() ? { action: 'assign', label: 'Assign', icon: 'ico-assign', title: 'Assign the Tank Maker / Stand Maker' } : null;
    case 'Assigned': {
      const done = needed.filter((role) => o.production_done?.[role]).length;
      return { action: 'none', label: `In Production ${done}/${needed.length}`, icon: 'ico-done', disabled: true, title: 'Waiting for the makers to mark their parts done' };
    }
    case 'Production Done':
      return canHandOver ? { action: 'pickup', label: 'Mark Picked Up', icon: 'ico-ship', title: 'The customer has collected it - moves to Completed (portal only)' } : null;
    case 'Completed':
      return canHandOver ? { action: 'unpickup', label: 'Undo Picked Up', icon: 'ico-done', title: 'Move it back to Production Done' } : null;
    default:
      return null;
  }
}

function nextStepFor(o) {
  if (!o) return null;
  if (o.walkin_stage) return nextStepForWalkin(o);
  if (canMarkShipped(o)) {
    return o.release
      ? { action: 'shipped', label: 'Release Remaining', icon: 'ico-ship', title: 'Partly released - release the rest (or another batch). The last batch marks it Shipped in the portal and Pancake' }
      : { action: 'shipped', label: 'Release / Ship', icon: 'ico-ship', title: 'Release all or some items. Releasing everything marks it Shipped in the portal and Pancake' };
  }
  if (!canAssignOrders()) return null;
  const status = (o.status || '').trim().toLowerCase();
  const needed = neededProductionRoles(o);
  if (!needed.length) return nextStepForStock(o);
  const display = orderDisplayStatus(o);

  if (isProductionDone(o) && canChangeProduction(o)) {
    return ['printed', 'assigned'].includes(status)
      ? { action: 'ship', label: 'Ready to Ship', icon: 'ico-ship', title: 'Move to To Ship in the portal and Pancake, then choose whether to message the customer' }
      : { action: 'ship', label: 'Ready to Ship', icon: 'ico-ship', disabled: true, title: 'Assign the order first - it has to be Assigned before it can ship' };
  }
  if (['confirmed', 'submitted', 'printed'].includes(status) && display !== 'Assigned') {
    return { action: 'assign', label: 'Assign', icon: 'ico-assign', title: 'Assign the Tank Maker / Stand Maker' };
  }
  if (status === 'assigned' || display === 'Assigned') {
    const done = needed.filter((role) => o.production_done?.[role]).length;
    return { action: 'none', label: `In Production ${done}/${needed.length}`, icon: 'ico-done', disabled: true, title: 'Waiting for the makers to mark their parts done' };
  }
  return null;
}

function updateNextStepButton(btnId, o) {
  const btn = document.getElementById(btnId);
  const step = nextStepFor(o);
  // When this button already reads "Assign", hide the regular Assign button next to it so there
  // aren't two (it comes back at later stages, for changing who's assigned).
  const assignBtn = document.getElementById(btnId === 'listNextStepBtn' ? 'listAssignBtn' : 'cardAssignBtn');
  if (canAssignOrders()) assignBtn.classList.toggle('hidden', step?.action === 'assign' || step?.action === 'build');
  btn.classList.toggle('hidden', !step);
  if (!step) return;
  btn.dataset.action = step.action;
  btn.disabled = !!step.disabled;
  btn.title = step.title || '';
  btn.classList.toggle('is-ship', (step.action === 'ship' || step.action === 'ship-stock') && !step.disabled);
  btn.innerHTML = `<svg class="bc-ico"><use href="#${step.icon}"/></svg>${escapeHtml(step.label)}`;
}

// Confirmation dialog for the actions that are easy to tap by accident (Production Done, Mark Shipped,
// Ready to Ship) - per "on the production done and mark shipped can you put a confirmation message so
// it will not accedentally clicked? this is for both mobile and portal". A real dialog (#confirmActionDialog)
// rather than the browser's small confirm(): names the order and customer, Cancel has focus, and the
// confirm button only becomes tappable after a moment so a double-tap on the original button can't
// land on it. Resolves true only on the confirm button; Cancel, Escape or tapping outside -> false.
// messageHtml (already escaped) instead of message when part of it needs formatting, e.g. bold SKUs.
function confirmAction({ caption = 'PLEASE CONFIRM', title, message, messageHtml, confirmLabel, tone = '' }) {
  const dialog = document.getElementById('confirmActionDialog');
  const panel = dialog.querySelector('.oo-confirm-dialog');
  const okBtn = document.getElementById('confirmActionOkBtn');
  const cancelBtn = document.getElementById('confirmActionCancelBtn');
  document.getElementById('confirmActionCaption').textContent = caption;
  document.getElementById('confirmActionTitle').textContent = title;
  if (messageHtml != null) document.getElementById('confirmActionMessage').innerHTML = messageHtml;
  else document.getElementById('confirmActionMessage').textContent = message;
  okBtn.textContent = confirmLabel;
  panel.classList.remove('is-done', 'is-ship', 'is-undo');
  if (tone) panel.classList.add(tone);

  return new Promise((resolve) => {
    const finish = (answer) => {
      dialog.classList.add('hidden');
      okBtn.removeEventListener('click', onOk);
      cancelBtn.removeEventListener('click', onCancel);
      dialog.removeEventListener('click', onBackdrop);
      document.removeEventListener('keydown', onKey, true);
      resolve(answer);
    };
    const onOk = () => finish(true);
    const onCancel = () => finish(false);
    const onBackdrop = (e) => { if (e.target === dialog) finish(false); };
    const onKey = (e) => {
      if (e.key === 'Escape') { e.stopImmediatePropagation(); finish(false); }
    };
    okBtn.addEventListener('click', onOk);
    cancelBtn.addEventListener('click', onCancel);
    dialog.addEventListener('click', onBackdrop);
    document.addEventListener('keydown', onKey, true);

    okBtn.disabled = true;
    dialog.classList.remove('hidden');
    cancelBtn.focus();
    setTimeout(() => { okBtn.disabled = false; }, 700);
  });
}

function orderLabel(o) {
  return `Order ${o.order_id}${o.customer_name ? ` · ${o.customer_name}` : ''}`;
}

async function handleNextStepClick(orderId, btn) {
  const o = findFlatOrder(orderId);
  if (!o) return;
  if (btn.dataset.action === 'assign') {
    openAssignDialog(orderId);
  } else if (btn.dataset.action === 'ship') {
    const ok = await confirmAction({
      caption: 'READY TO SHIP',
      title: orderLabel(o),
      message: 'Mark this order as Ready to Ship?\n\nIt moves to To Ship in the portal and Pancake.',
      confirmLabel: 'Yes, Ready to Ship',
      tone: 'is-ship'
    });
    if (!ok) return;
    await handleToShipClick(String(o.order_id), btn, { readyToShip: true });
  } else if (btn.dataset.action === 'ship-stock') {
    // Fresh lines from Pancake first, then re-check stock - the cached check / saved lines can still
    // hold old copies of the lines (order 105852 asked for 2 + 2).
    btn.disabled = true;
    const refreshError = await refreshOrderLinesFromPancake(o.order_id);
    btn.disabled = false;
    if (refreshError) {
      alert(refreshError);
      return;
    }
    stockStatusCache.delete(String(o.order_id));
    await ensureStockStatus(o);
    const s = stockStatusFor(o);
    if (!s?.all_available) {
      alert(s ? `Not everything is in stock at ${s.warehouse_name || 'this branch'} any more:\n${stockLinesSummary(s)}` : 'Could not check the stock for this order - try again.');
      return;
    }
    const ok = await confirmAction({
      caption: 'READY TO SHIP - FROM STOCK',
      title: orderLabel(o),
      messageHtml: `Everything is in stock at ${escapeHtml(s?.warehouse_name || 'this branch')}:\n${stockLinesHtml(s)}\n\nPick the serial(s) and move this order to To Ship in the portal and Pancake?`,
      confirmLabel: 'Yes, Ready to Ship',
      tone: 'is-ship'
    });
    if (!ok) return;
    await handleToShipClick(String(o.order_id), btn, { readyToShip: true, fromStock: true, linesRefreshed: true });
    stockStatusCache.delete(String(o.order_id));
  } else if (btn.dataset.action === 'build') {
    await openStockBuildDialog(o);
  } else if (btn.dataset.action === 'stock-assigned') {
    const s = stockStatusFor(o);
    const ok = await confirmAction({
      caption: 'SET ASSIGNED',
      title: orderLabel(o),
      message: `${s?.production_order_no || 'A Production Order'} is building this order.\n\nMove it to Assigned in the portal and Pancake? The customer gets the "in production" message (once per order).`,
      confirmLabel: 'Yes, Set Assigned'
    });
    if (!ok) return;
    btn.disabled = true;
    const label = btn.textContent;
    btn.textContent = 'Updating status...';
    const result = await syncAssignedStatus(o, btn);
    btn.disabled = false;
    btn.textContent = label;
    await refreshCurrentOrders();
    if (!document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
    stockStatusCache.delete(String(o.order_id));
    await ensureStockStatus(findFlatOrder(o.order_id) || o);
    alert(assignedStatusNote(o, result) || `Order ${o.order_id} wasn't changed - refresh and check its status.`);
  } else if (btn.dataset.action === 'open-prod') {
    // Same tab - a new tab has no portal login (per-tab sessionStorage).
    const s = stockStatusFor(o);
    if (s?.production_order_no) window.location.href = `production-orders.html?no=${encodeURIComponent(s.production_order_no)}`;
  } else if (btn.dataset.action === 'shipped') {
    await markOrderShipped(String(o.order_id), btn);
  } else if (btn.dataset.action === 'pickup' || btn.dataset.action === 'unpickup') {
    await markWalkinPickedUp(String(o.order_id), btn, btn.dataset.action === 'pickup');
  }
}

// Walk-in Mark Picked Up / Undo (admin_mark_walkin_order_picked_up) - portal only, nothing to Pancake.
async function markWalkinPickedUp(orderId, btn, pickedUp) {
  const o = findFlatOrder(orderId);
  if (!o) return;
  const ok = await confirmAction(pickedUp
    ? {
      caption: 'MARK PICKED UP',
      title: orderLabel(o),
      message: 'Has the customer collected this order?\n\nIt moves to Completed.',
      confirmLabel: 'Yes, Picked Up',
      tone: 'is-ship'
    }
    : {
      caption: 'UNDO PICKED UP',
      title: orderLabel(o),
      message: 'Move this order back to Production Done?',
      confirmLabel: 'Yes, Undo',
      tone: 'is-undo'
    });
  if (!ok) return;
  btn.disabled = true;
  const { error } = await supabaseClient.rpc('admin_mark_walkin_order_picked_up', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_picked_up: pickedUp
  });
  btn.disabled = false;
  if (error) {
    alert(error.message);
    return;
  }
  await refreshCurrentOrders();
  if (!document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
}

// Walk-in customer name / contact no. on the order card (admin_set_walkin_order_customer) - portal only.
async function saveWalkinCustomer() {
  const orderId = openCardOrderId;
  if (!orderId) return;
  const btn = document.getElementById('ocWalkinSaveBtn');
  btn.disabled = true;
  btn.textContent = 'Saving...';
  const { error } = await supabaseClient.rpc('admin_set_walkin_order_customer', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_name: document.getElementById('ocWalkinName').value.trim() || null,
    p_phone: document.getElementById('ocWalkinPhone').value.trim() || null
  });
  btn.disabled = false;
  btn.textContent = 'Save';
  if (error) {
    alert(error.message);
    return;
  }
  await refreshCurrentOrders();
}

// Shared by the next-step button (list / card) and the Dispatcher's phone card. Per "in the dispatcher..
// can they do partial release only": opens the Release dialog (openReleaseDialog) - all or some lines.
// Orders with no lines on file fall back to the plain whole-order Mark Shipped below.
async function markOrderShipped(orderId, btn) {
  const o = findFlatOrder(orderId);
  if (!o || !canMarkShipped(o)) return;
  btn.disabled = true;
  const { data: lines, error } = await supabaseClient.rpc('staff_get_online_order_release_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: String(o.order_id)
  });
  btn.disabled = false;
  // Quietly the old whole-order flow until supabase_online_order_partial_release.sql is run.
  if (error) console.warn('staff_get_online_order_release_lines:', error.message);
  if (!error && lines?.length) {
    openReleaseDialog(o, lines);
    return;
  }
  await markOrderShippedWhole(o, btn);
}

async function markOrderShippedWhole(o, btn) {
  const ok = await confirmAction({
    caption: 'MARK SHIPPED',
    title: orderLabel(o),
    message: `Has this order been shipped / handed to the customer?\n\nIt changes to Shipped in the portal and Pancake${(currentSession?.staffRoles || []).includes('Dispatcher') ? ', and you are recorded as its dispatcher' : ''}. No message is sent to the customer.`,
    confirmLabel: 'Yes, Mark Shipped',
    tone: 'is-ship'
  });
  if (!ok) return;
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_mark_online_order_shipped', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: String(o.order_id)
  });
  btn.disabled = false;
  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result?.success) {
    alert(error?.message || result?.message || 'Could not mark as shipped.');
    return;
  }
  if (openCardOrderId === String(o.order_id) && myAssignmentsLocked) closeOrderCard();
  await refreshCurrentOrders();
  if (!myAssignmentsLocked && !document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
}

// ---------------------------------------------------------------- Release (partial / full shipping)
// Each line: tick + how many leave now (defaults to everything left). Untouched lines stay pending.
// admin_release_online_order_lines re-checks the remaining quantities server-side; the batch that
// releases the last unit marks the order Shipped in the portal and Pancake.
let releaseOrderId = null;

function openReleaseDialog(o, lines) {
  releaseOrderId = String(o.order_id);
  document.getElementById('releaseTitle').textContent = orderLabel(o);
  document.getElementById('releaseLines').innerHTML = lines.map((l) => {
    const left = Number(l.remaining_qty) || 0;
    const released = Number(l.released_qty) || 0;
    const sub = `Ordered ${Number(l.ordered_qty)}${released ? ` · ${released} already released` : ''}${left ? ` · ${left} left` : ''}`;
    return `<div class="oo-rl-line${left ? '' : ' is-done'}" data-line-id="${escapeHtml(l.line_id)}" data-left="${left}">
      <input type="checkbox" ${left ? 'checked' : 'disabled'} aria-label="Release ${escapeHtml(l.description || l.item_code || '')}" />
      <span class="oo-rl-info"><b>${escapeHtml(l.description || l.item_code || l.line_id)}</b><small>${left ? escapeHtml(sub) : '&#10003; All released'}</small></span>
      ${left ? `<input type="number" class="oo-rl-qty" min="1" max="${left}" step="1" value="${left}" inputmode="numeric" aria-label="Quantity to release" />` : ''}
    </div>`;
  }).join('');
  document.getElementById('releaseNote').value = '';
  document.getElementById('releaseError').classList.add('hidden');
  updateReleaseDialogState();
  document.getElementById('releaseDialog').classList.remove('hidden');
}

function closeReleaseDialog() {
  releaseOrderId = null;
  document.getElementById('releaseDialog').classList.add('hidden');
}

function releaseSelection() {
  return [...document.querySelectorAll('#releaseLines .oo-rl-line')].map((row) => {
    const left = Number(row.dataset.left) || 0;
    const qtyInput = row.querySelector('.oo-rl-qty');
    const picked = !!row.querySelector('input[type="checkbox"]')?.checked && left > 0;
    return { line_id: row.dataset.lineId, left, quantity: picked ? Number(qtyInput?.value) || 0 : 0 };
  });
}

// Keeps "Release everything left" and the button label in step with the picks: the label says whether
// this batch ships the order or leaves part of it pending.
function updateReleaseDialogState() {
  const sel = releaseSelection().filter((s) => s.left > 0);
  const all = sel.length > 0 && sel.every((s) => s.quantity >= s.left);
  const any = sel.some((s) => s.quantity > 0);
  document.getElementById('releaseAll').checked = all;
  const btn = document.getElementById('saveReleaseBtn');
  btn.textContent = all ? 'Release All - Mark Shipped' : 'Release Selected (Partial)';
  btn.disabled = !any;
}

async function saveRelease() {
  const o = findFlatOrder(releaseOrderId);
  const errorEl = document.getElementById('releaseError');
  const fail = (msg) => { errorEl.textContent = msg; errorEl.classList.remove('hidden'); };
  const sel = releaseSelection().filter((s) => s.quantity > 0);
  if (!o) return closeReleaseDialog();
  if (!sel.length) return fail('Tick at least one item to release.');
  const bad = sel.find((s) => !Number.isInteger(s.quantity) || s.quantity < 1 || s.quantity > s.left);
  if (bad) return fail(`Quantity must be a whole number from 1 to ${bad.left}.`);
  const full = releaseSelection().every((s) => s.quantity >= s.left);

  const ok = await confirmAction(full
    ? {
      caption: 'RELEASE ALL - MARK SHIPPED',
      title: orderLabel(o),
      message: `Release everything that is left?\n\nThe order changes to Shipped in the portal and Pancake${(currentSession?.staffRoles || []).includes('Dispatcher') ? ', and you are recorded as its dispatcher' : ''}. No message is sent to the customer.`,
      confirmLabel: 'Yes, Mark Shipped',
      tone: 'is-ship'
    }
    : {
      caption: 'PARTIAL RELEASE',
      title: orderLabel(o),
      message: `Release ${sel.reduce((n, s) => n + s.quantity, 0)} item(s) now?\n\nThe rest stays pending - the order stays in To Ship until everything is released. Nothing changes in Pancake yet.`,
      confirmLabel: 'Yes, Release',
      tone: 'is-ship'
    });
  if (!ok) return;

  const btn = document.getElementById('saveReleaseBtn');
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_release_online_order_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: releaseOrderId,
    p_lines: sel.map((s) => ({ line_id: s.line_id, quantity: s.quantity })),
    p_note: document.getElementById('releaseNote').value.trim() || null
  });
  btn.disabled = false;
  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result?.success) return fail(error?.message || result?.message || 'Could not release.');

  const orderId = releaseOrderId;
  closeReleaseDialog();
  if (result.fully_shipped && openCardOrderId === orderId && myAssignmentsLocked) closeOrderCard();
  await refreshCurrentOrders();
  if (openCardOrderId === orderId) loadOrderCardReleaseHistory(orderId);
  if (!myAssignmentsLocked && !document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
  if (!result.fully_shipped) alert(result.message);
}

function wireReleaseDialog() {
  const box = document.getElementById('releaseLines');
  box.addEventListener('change', (e) => {
    const row = e.target.closest('.oo-rl-line');
    // Typing a quantity ticks the line; clearing it to 0 unticks it.
    if (row && e.target.classList.contains('oo-rl-qty')) {
      row.querySelector('input[type="checkbox"]').checked = Number(e.target.value) > 0;
    }
    updateReleaseDialogState();
  });
  box.addEventListener('input', updateReleaseDialogState);
  document.getElementById('releaseAll').addEventListener('change', (e) => {
    document.querySelectorAll('#releaseLines .oo-rl-line').forEach((row) => {
      const left = Number(row.dataset.left) || 0;
      if (!left) return;
      row.querySelector('input[type="checkbox"]').checked = e.target.checked;
      if (e.target.checked) row.querySelector('.oo-rl-qty').value = left;
    });
    updateReleaseDialogState();
  });
  document.getElementById('saveReleaseBtn').addEventListener('click', saveRelease);
  document.getElementById('cancelReleaseBtn').addEventListener('click', closeReleaseDialog);
  document.getElementById('closeReleaseBtn').addEventListener('click', closeReleaseDialog);
  document.addEventListener('keydown', (e) => {
    // The confirm dialog on top handles its own Escape (capture phase) first.
    if (e.key === 'Escape' && !document.getElementById('releaseDialog').classList.contains('hidden')
      && document.getElementById('confirmActionDialog').classList.contains('hidden')) closeReleaseDialog();
  });
}

// Order card: every release batch, newest first. Hidden until something has been released.
async function loadOrderCardReleaseHistory(orderId) {
  const tab = document.getElementById('orderCardReleaseTab');
  const r = findFlatOrder(orderId)?.release;
  tab.classList.toggle('hidden', !r);
  if (!r) return;
  document.getElementById('orderCardReleaseSummary').textContent =
    `${Number(r.released_qty)} of ${Number(r.ordered_qty)} released in ${r.batches} batch${r.batches === 1 ? '' : 'es'}`;
  const body = document.getElementById('ocReleaseBody');
  body.innerHTML = '<tr><td colspan="5" class="cell-msg">Loading...</td></tr>';
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_release_history', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: String(orderId)
  });
  if (openCardOrderId !== String(orderId)) return;
  if (error) {
    body.innerHTML = `<tr><td colspan="5" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }
  const fmt = (t) => (t ? new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');
  body.innerHTML = (data || []).map((h) => `
    <tr>
      <td>#${h.batch_no}</td>
      <td>${escapeHtml(fmt(h.released_at))}<small class="oo-rh-sub">by ${escapeHtml(h.released_by_name || '')}</small></td>
      <td>${escapeHtml(h.description || '')}</td>
      <td class="num">${Number(h.quantity)}</td>
      <td>${escapeHtml(h.note || '')}</td>
    </tr>`).join('') || '<tr><td colspan="5" class="cell-msg">Nothing released yet.</td></tr>';
}

function wireNextStepButtons() {
  // Wired for everyone: walk-in Mark Picked Up is for any staff, not just Production Managers / makers
  // (the button stays hidden whenever nextStepFor has nothing for this user).
  document.getElementById('listNextStepBtn').addEventListener('click', (e) => selectedOrderId && handleNextStepClick(selectedOrderId, e.currentTarget));
  document.getElementById('cardNextStepBtn').addEventListener('click', (e) => openCardOrderId && handleNextStepClick(openCardOrderId, e.currentTarget));
}

// ---------------------------------------------------------------- Send back for rework
// Per "a production manager can click a button reassign after production done so it will go back to
// the maker has issue or if needed to rework" - clears the chosen parts' done marks with a reason
// (admin_send_back_online_order_production), so they return to that maker's My Assignments.
let sendBackOrderId = null;

function doneParts(o) {
  return neededProductionRoles(o).filter((role) => o.production_done?.[role]);
}

function updateSendBackButton(btnId, o) {
  const btn = document.getElementById(btnId);
  btn.classList.toggle('hidden', !canAssignOrders());
  btn.disabled = !o || !doneParts(o).length || !canChangeProduction(o);
  btn.title = !o ? 'Select an order'
    : !doneParts(o).length ? 'No part of this order has been marked done yet'
    : !canChangeProduction(o) ? `This order is already ${o.status}`
    : 'Send finished parts back to the maker for rework';
}

function openSendBackDialog(orderId) {
  const o = findFlatOrder(orderId);
  if (!o || !doneParts(o).length) return;
  sendBackOrderId = String(o.order_id);
  document.getElementById('sendBackTitle').textContent = `${o.order_id}${o.customer_name ? ' · ' + o.customer_name : ''}`;
  document.getElementById('sendBackParts').innerHTML = doneParts(o).map((role) => {
    const d = o.production_done[role];
    const when = d.done_at ? new Date(d.done_at).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
    return `<label class="oo-sb-part"><input type="checkbox" value="${role}" />
      <span><b>${escapeHtml(MAKER_ROLES[role].label)}</b> - ${escapeHtml(d.done_by_name || d.done_by)}<small>${when ? 'Done ' + escapeHtml(when) : ''}</small></span></label>`;
  }).join('');
  document.getElementById('sendBackReason').value = '';
  document.getElementById('sendBackError').classList.add('hidden');
  document.getElementById('sendBackDialog').classList.remove('hidden');
  document.getElementById('sendBackReason').focus();
}

function closeSendBackDialog() {
  sendBackOrderId = null;
  document.getElementById('sendBackDialog').classList.add('hidden');
}

async function saveSendBack() {
  const cardOrderId = openCardOrderId;
  const errorEl = document.getElementById('sendBackError');
  const roles = [...document.querySelectorAll('#sendBackParts input:checked')].map((i) => i.value);
  const reason = document.getElementById('sendBackReason').value.trim();
  const fail = (msg) => { errorEl.textContent = msg; errorEl.classList.remove('hidden'); };
  if (!roles.length) return fail('Pick at least one part to send back.');
  if (!reason) return fail('Please give a reason so the maker knows what to fix.');

  const btn = document.getElementById('saveSendBackBtn');
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_send_back_online_order_production', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: sendBackOrderId,
    p_roles: roles,
    p_reason: reason
  });
  btn.disabled = false;
  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result?.success) return fail(error?.message || result?.message || 'Could not send back.');

  closeSendBackDialog();
  await refreshCurrentOrders();
  if (cardOrderId && openCardOrderId === cardOrderId) loadOrderCardReworkHistory(cardOrderId);
  if (!document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
}

function wireSendBackDialog() {
  if (!canAssignOrders()) return;
  document.getElementById('listSendBackBtn').addEventListener('click', () => selectedOrderId && openSendBackDialog(selectedOrderId));
  document.getElementById('cardSendBackBtn').addEventListener('click', () => openCardOrderId && openSendBackDialog(openCardOrderId));
  document.getElementById('saveSendBackBtn').addEventListener('click', saveSendBack);
  document.getElementById('cancelSendBackBtn').addEventListener('click', closeSendBackDialog);
  document.getElementById('closeSendBackBtn').addEventListener('click', closeSendBackDialog);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !document.getElementById('sendBackDialog').classList.contains('hidden')) closeSendBackDialog();
  });
}

async function handleProductionDoneClick(orderId, btn) {
  const o = findFlatOrder(orderId);
  if (!o) return;
  const mine = myProductionRoles(o);
  if (!mine.length) return;
  const undo = mine.every((role) => o.production_done?.[role]);
  const parts = mine.map((r) => MAKER_ROLES[r].label.replace(' Maker', '').toLowerCase()).join(' and ');
  const ok = await confirmAction(undo
    ? {
      caption: 'UNDO PRODUCTION DONE',
      title: orderLabel(o),
      message: `Undo Production Done for your part (${parts})?\n\nIt goes back to being in production.`,
      confirmLabel: 'Yes, Undo',
      tone: 'is-undo'
    }
    : {
      caption: 'PRODUCTION DONE',
      title: orderLabel(o),
      message: `Is your part (${parts}) completely finished?${myAssignmentsOnly ? '\n\nThe order will leave your list.' : ''}`,
      confirmLabel: 'Yes, Production Done',
      tone: 'is-done'
    });
  if (!ok) return;

  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('staff_set_online_order_production_done', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: String(o.order_id),
    p_done: !undo
  });
  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result?.success) {
    alert(error?.message || result?.message || 'Could not update production.');
  } else if (!undo && myAssignmentsOnly) {
    // Done orders drop out of My Assignments (supabase_online_order_my_assignments_hide_done.sql),
    // so close the order card and land the maker back on their list.
    if (openCardOrderId === orderId) closeOrderCard();
    alert(`Order ${o.order_id}: your part is marked done and it's now off your list.${result.all_done ? ' Every part is done - the Production Manager will finish it.' : ''}`);
  } else if (!undo && result.all_done) {
    alert(`Order ${o.order_id}: every part is done - it now shows as Production Done.`);
  }
  await refreshCurrentOrders();
  if (!myAssignmentsLocked && !document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
}

function makerSelectHtml(order, role, currentUsername) {
  const staffRole = MAKER_ROLES[role].staffRole;
  const members = productionMembers.filter((m) => (m.staff_roles || []).includes(staffRole));
  let options = members
    .map((m) => `<option value="${escapeHtml(m.username)}" ${currentUsername === m.username ? 'selected' : ''}>${escapeHtml(m.display_name)}</option>`)
    .join('');
  // An assignment made before roles existed (or to someone whose role was since removed) stays
  // visible instead of the dropdown silently showing blank - it just can't be re-picked.
  if (currentUsername && !members.some((m) => m.username === currentUsername)) {
    const name = order[`assigned_${MAKER_ROLES[role].field}_name`] || currentUsername;
    options += `<option value="${escapeHtml(currentUsername)}" selected disabled>${escapeHtml(name)} (no role)</option>`;
  }
  const label = MAKER_ROLES[role].label;
  // Assigning Tank Maker / Stand Maker / Dispatcher is the Production Manager's call (or a Super
  // User's) - supabase_production_manager_role.sql enforces the same server-side. Everyone else
  // sees who's assigned, read-only.
  const locked = !(currentSession?.isSuperUser || currentSession?.isProductionManager);
  return `
    <select class="assign-maker-select" data-order-id="${escapeHtml(order.order_id)}" data-role="${role}" title="${locked ? label + ' - assigned by the Production Manager' : label}" style="max-width:150px;" ${locked ? 'disabled' : ''}>
      <option value="" ${!currentUsername ? 'selected' : ''}>&mdash; ${label} &mdash;</option>
      ${options}
    </select>
  `;
}

function assignSelectHtml(order) {
  const parts = [];
  if (order.has_aquarium_line) parts.push(makerSelectHtml(order, 'tank', order.assigned_tank_maker));
  if (order.has_stand_line) parts.push(makerSelectHtml(order, 'stand', order.assigned_stand_maker));
  // No Dispatcher dropdown - per "dispatcher's dont need to be assigned. any dispatcher can mark an order
  // shipped". Whoever marks it Shipped is recorded as its Dispatcher (shown read-only once known).
  if (order.assigned_dispatcher) {
    parts.push(`<span class="muted" title="Recorded when the order was marked Shipped">Dispatcher: ${escapeHtml(order.assigned_dispatcher_name || order.assigned_dispatcher)}</span>`);
  }
  if (!parts.length) return '<span class="muted">-</span>';
  return `<div style="display:flex; flex-direction:column; gap:4px; align-items:flex-start;">${parts.join('')}</div>`;
}

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Plain-text assignee for the list columns - '' when the order doesn't need that maker at all
// (no aquarium/stand line), so an empty cell reads differently from "needed but unassigned" (-).
function assigneeCellHtml(o, needed, username, name) {
  if (!needed) return '';
  return username ? escapeHtml(name || username) : '<span class="muted">-</span>';
}

// BC list rows: data only, no buttons. Every action (Open / Send Photo / To-Ship Message / To Ship)
// lives on the action bar and works on the selected row (see wireOrderListActions), and the
// Order ID drills into the Online Order document (openOrderCard) the way a BC "No." field does.
// Assignments are edited on that document, not in the list.
function orderRowsHtml(orders) {
  return orders
    .map((o) => `
      <tr data-order-id="${escapeHtml(o.order_id)}" class="${String(o.order_id) === String(selectedOrderId) ? 'selected' : ''}">
        <td><a class="bc-doc-no" href="#" data-open-order="${escapeHtml(o.order_id)}" title="Open this order">${escapeHtml(o.order_id)}</a></td>
        <td>${o.order_date || ''}</td>
        <td>${o.order_time || ''}</td>
        <td>${escapeHtml(o.customer_name)}</td>
        <td>${escapeHtml(o.warehouse_name || o.location_id)}</td>
        <td>${escapeHtml(listDisplayStatus(o))}${reworkCountBadgeHtml(o)}</td>
        <td>${escapeHtml(o.confirmed_by)}</td>
        <td>${escapeHtml(o.created_by)}</td>
        <td>${assigneeCellHtml(o, o.has_aquarium_line, o.assigned_tank_maker, o.assigned_tank_maker_name)}${productionDoneTickHtml(o, 'tank')}</td>
        <td>${assigneeCellHtml(o, o.has_stand_line, o.assigned_stand_maker, o.assigned_stand_maker_name)}${productionDoneTickHtml(o, 'stand')}</td>
        <td>${assigneeCellHtml(o, true, o.assigned_dispatcher, o.assigned_dispatcher_name)}${productionDoneTickHtml(o, 'dispatcher')}</td>
        <td>${otherBranchBadgeHtml(o)} ${glassBadgeHtml(o)} ${customBadgeHtml(o)} ${gmaBadgeHtml(o)}</td>
        <td>${prodOrderBadgeHtml(o)}</td>
        <td>${o.received_at_shop && posNoteSummary(o) ? `<span class="oo-pos-note" title="${escapeHtml(o.pos_note)}">${escapeHtml(posNoteSummary(o))}</span>` : escapeHtml(o.note_print)}${!o.received_at_shop && posNoteSummary(o) ? `${o.note_print ? ' ' : ''}<span class="oo-pos-note" title="${escapeHtml(o.pos_note)}"><b>POS:</b> ${escapeHtml(posNoteSummary(o))}</span>` : ''}</td>
        ${hidePrices() ? '' : `<td class="num">${o.delivery_fee ? Number(o.delivery_fee).toFixed(2) : ''}</td>`}
        <td>${o.for_delivery ? 'Yes' : 'No'}</td>
        <td>${o.estimated_delivery_date || ''}</td>
        <td>${o.last_updated_at ? new Date(o.last_updated_at).toLocaleString() : ''}</td>
      </tr>
    `)
    .join('');
}

// Stacked card for the grouped (Online Order Staff / mobile) view - one order's info as
// label/value rows instead of a wide table, so nothing gets clipped or forces horizontal
// scrolling on a phone. The "To Ship" button is only shown once an order is 'Printed' (same rule
// as the desktop list's To Ship action, see updateOrderActionState). "Send Photo" is detached from that gate entirely - it's always
// offered, independent of To Ship's status/enabled state (see handleSendPhotoClick).
function orderCardHtml(o) {
  const status = o.status || '';
  // Mirrors the desktop app's IsPrintedStatusForRow gate on MarkRowAsToShipAsync (OnlineOrdersForm.cs)
  // and admin_update_online_order_status' matching server-side check.
  const showToShipBtn = isPrintedOrder(o);

  return `
    <div class="order-card" data-order-id="${o.order_id}">
      <div class="order-card-top">
        <span class="order-card-id">#${o.order_id || ''}</span>
        ${orderBadgesHtml(o)}
      </div>
      <div class="order-card-customer">${o.customer_name || 'No name on order'}</div>
      <div class="order-card-grid">
        <span class="order-card-label">Date</span><span>${o.order_date || ''} ${o.order_time || ''}</span>
        <span class="order-card-label">Warehouse</span><span>${o.warehouse_name || o.location_id || ''}</span>
        <span class="order-card-label">Delivery</span><span><span class="badge ${o.for_delivery ? 'badge-success' : 'badge-neutral'}">${o.for_delivery ? 'Yes' : 'No'}</span> ${o.estimated_delivery_date ? '&middot; ' + o.estimated_delivery_date : ''}</span>
        <span class="order-card-label">Confirmed By</span><span>${o.confirmed_by || '-'}</span>
        ${o.note_print ? `<span class="order-card-label">Print Note</span><span>${o.note_print}</span>` : ''}
        <span class="order-card-label">Assigned To</span><span>${assignSelectHtml(o)}</span>
      </div>
      <div class="order-card-actions">
        <a class="btn btn-secondary btn-sm" href="online-order-lines.html?order=${encodeURIComponent(o.order_id)}">View Order Lines</a>
        <button type="button" class="btn btn-secondary btn-sm status-send-photo-btn">Send Photo</button>
        <button type="button" class="btn btn-secondary btn-sm status-send-message-btn">TO-SHIP</button>
        ${showToShipBtn ? '<button type="button" class="btn btn-primary status-to-ship-btn">To Ship</button>' : ''}
      </div>
    </div>
  `;
}

// Filters the last-fetched rows down to whichever status tab is active and renders them as cards
// - called both after a fresh fetch (loadOrders) and on a plain tab click (no re-fetch needed,
// see wireGroupedTabs below).
function renderActiveGroupTab() {
  const list = document.getElementById('groupedOrdersList');
  const bucket = lastGroupedRows.filter((o) => orderDisplayStatus(o).toLowerCase() === activeGroupStatus.toLowerCase());
  list.innerHTML = bucket.length === 0
    ? `<p class="muted">No ${activeGroupStatus} orders.</p>`
    : bucket.map(orderCardHtml).join('');
}

// Splits rows into the Confirmed/Assigned/Printed/To Ship counts (see GROUP_COUNT_IDS/GROUP_TAB_
// STATUSES above), stores them for tab switching, and renders whichever tab is currently active.
// fetchedCount/totalCount come straight from the server response (BEFORE the client-side
// warehouse/outstanding post-filters loadOrders applies) - used only to flag when the 200-row
// fetch cap might be hiding older matching orders, not to decide what's actually shown.
function renderGroupedOrders(rows, fetchedCount, totalCount) {
  lastGroupedRows = rows;

  GROUP_TAB_STATUSES.forEach((status) => {
    const count = rows.filter((o) => orderDisplayStatus(o).toLowerCase() === status.toLowerCase()).length;
    document.getElementById(GROUP_COUNT_IDS[status]).textContent = count;
  });

  renderActiveGroupTab();

  const note = document.getElementById('groupedOrdersNote');
  if (fetchedCount < totalCount) {
    note.textContent = `Showing the most recent ${fetchedCount} of ${totalCount} matching orders. Use search to find an older one if it's not listed below.`;
    note.classList.remove('hidden');
  } else {
    note.classList.add('hidden');
  }
}

function refreshCurrentOrders() {
  return loadOrders(document.getElementById('orderSearchInput').value.trim(), document.getElementById('statusFilterInput').value.trim());
}

// Friendly "please hold on" banner shown while applyStatusChange's RPCs are in flight - per direct
// request, so staff have some indication of progress instead of a disabled button with no feedback
// while the photo send in particular can take several seconds across its retries (see
// admin_send_online_order_status_photo's statement_timeout/retry-loop comments). Built dynamically
// rather than static markup, same pattern as pwa.js's install banner.
let sendStatusBannerEl = null;

function showSendStatusBanner(text) {
  if (!sendStatusBannerEl) {
    sendStatusBannerEl = document.createElement('div');
    sendStatusBannerEl.className = 'send-status-banner';
    sendStatusBannerEl.innerHTML = '<span class="send-status-spinner"></span><span class="send-status-text"></span>';
    document.body.appendChild(sendStatusBannerEl);
  }
  sendStatusBannerEl.querySelector('.send-status-text').textContent = text;
}

function hideSendStatusBanner() {
  if (sendStatusBannerEl) {
    sendStatusBannerEl.remove();
    sendStatusBannerEl = null;
  }
}

// Shared apply step for the "To Ship" button. admin_update_online_order_status re-validates the
// transition server-side regardless of what's offered here (blocked-from-'new', 'To Ship' only).
// serialRunningNos (from the serial picker modal, production warehouses only - see
// handleToShipClick/supabase_online_order_to_ship_serials.sql) are claimed inside the same RPC
// call, atomically with the Pancake status PATCH - null/empty when no serial pick was needed.
//
// The photo (if any) is sent as its OWN separate call (admin_send_online_order_status_photo),
// per direct instruction - AFTER the status change/text message above has already gone through,
// never bundled into that RPC. This keeps admin_update_online_order_status's own runtime short
// (it used to chain a status PATCH + bank_payments snapshot/restore + text message + photo POST
// all in one request, long enough to occasionally hit the authenticator role's statement_timeout)
// and means a slow/failing photo attach can never roll back the actual status change.
async function applyStatusChange(orderId, newStatus, notifyCustomer, photoUrl, photoStoragePath, serialRunningNos, triggerEl) {
  triggerEl.disabled = true;
  showSendStatusBanner("Hey there! Updating this order's status, please hold on...");

  // The serial picker resolves { running, fresh }: existing serials to claim and new ones to create
  // (supabase_online_order_ship_new_serials.sql). A plain array (older callers) is just "running".
  const running = Array.isArray(serialRunningNos) ? serialRunningNos : (serialRunningNos?.running || []);
  const fresh = Array.isArray(serialRunningNos) ? [] : (serialRunningNos?.fresh || []);

  try {
    // Ship-from-stock orders may still be Confirmed - admin_ship_online_order_from_stock allows that
    // (supabase_online_order_stock_ship.sql); same parameters and result as the regular RPC.
    const rpcName = shipFromStockOrderIds.has(String(orderId)) ? 'admin_ship_online_order_from_stock' : 'admin_update_online_order_status';
    const { data, error } = await supabaseClient.rpc(rpcName, {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId,
      p_new_status: newStatus,
      p_notify_customer: notifyCustomer,
      p_serial_running_nos: running.length > 0 ? running : null,
      p_new_serials: fresh.length > 0 ? fresh : null
    });

    if (error) {
      // "Failed to fetch" = the connection dropped (e.g. the API gateway's ~60s limit while Pancake was
      // slow), NOT a rejection - the server may have finished anyway. Ask for the order's status
      // before telling staff anything (supabase_online_order_stock_ship.sql).
      if (/failed to fetch|network|load failed/i.test(error.message || '')) {
        showSendStatusBanner('The connection dropped - checking whether the order went through...');
        const { data: nowStatus } = await supabaseClient.rpc('staff_get_online_order_current_status', {
          p_admin_username: currentSession.username,
          p_admin_password: currentSession.password,
          p_order_id: orderId
        });
        if (String(nowStatus || '').trim().toLowerCase() === String(newStatus).trim().toLowerCase()) {
          alert(`Order ${orderId} is now ${newStatus} - the connection dropped before the reply came back, but it went through.`
            + (notifyCustomer ? ' Check the customer got the message.' : '')
            + (fresh.length ? ' Reprint any new serial labels from the Serial Tracker.' : ''));
          await refreshCurrentOrders();
          return;
        }
        alert(`Could not update status - the connection dropped and order ${orderId} is still ${nowStatus || 'unchanged'}. `
          + 'Pancake may be slow right now; wait a minute and try again.');
        triggerEl.disabled = false;
        return;
      }
      alert('Could not update status: ' + error.message);
      triggerEl.disabled = false;
      return;
    }

    const result = data && data[0];

    // New serials were created - print their labels now, same as the desktop's To Ship.
    const created = Array.isArray(result?.created_serials) ? result.created_serials : [];
    if (created.length) {
      printSerialLabels(created.map((s) => ({ serialNo: s.serial_no, itemCode: s.item_code, description: s.description })));
    }
    // GMA Page order: the SQL hands back the psid + text instead of sending
    // (supabase_online_order_status_message_gma.sql) - send it through the GMA Page here.
    if (result?.gma_psid && result.gma_message) {
      showSendStatusBanner("Messaging the customer on the GMA Page...");
      const gma = await sendGmaMessage(result.gma_psid, result.gma_message);
      result.message_sent = gma.sent;
      result.message_error = gma.error;
    }
    // The message goes last in that call, so a slow Pancake can run it out of time ("HTTP request
    // cancelled") after the status already changed - re-send it as its own call, and if that fails too
    // open the To-Ship Message dialog prefilled so staff can just press Send
    // (supabase_online_order_message_timeout.sql).
    const isToShip = String(newStatus).trim().toLowerCase() === 'to ship';
    if (notifyCustomer && result && !result.message_sent && !isToShip) {
      alert('Status updated, but the customer notification failed to send: ' + (result.message_error || 'unknown error'));
    } else if (notifyCustomer && result && !result.message_sent) {
      let resent = false;
      if (!result.gma_psid) {
        showSendStatusBanner('Status updated - sending the customer message again...');
        resent = await resendToShipMessage(orderId);
      }
      if (!resent) {
        alert(`Status updated, but the customer message didn't go (${result.message_error || 'unknown error'}).\n\nThe To-Ship Message window opens next - check the text and press Send.`);
        openSendMessageModal(orderId);
      }
    }

    const gmaPhotoPsid = photoUrl ? (result?.gma_psid || await getGmaPsid(orderId)) : null;
    if (photoUrl && gmaPhotoPsid) {
      showSendStatusBanner("Sending the photo to the customer on the GMA Page...");
      const gmaPhoto = await sendGmaOrderPhoto(orderId, gmaPhotoPsid, photoUrl, photoStoragePath);
      if (!gmaPhoto.sent) alert('Status updated, but the photo could not be attached: ' + (gmaPhoto.error || 'unknown error'));
    } else if (photoUrl) {
      // The retry loop inside admin_send_online_order_status_photo can take several seconds (up to
      // 8 attempts with a short pause between each) - update the banner text so it's clear this
      // specific step, not the whole action, is what's still working.
      showSendStatusBanner("Hang tight, sending the photo to the customer's conversation - this can take a few tries...");

      const { data: photoData, error: photoError } = await supabaseClient.rpc('admin_send_online_order_status_photo', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_order_id: orderId,
        p_photo_url: photoUrl,
        p_photo_storage_path: photoStoragePath
      });

      const photoResult = photoData && photoData[0];
      // attempts_used/elapsed_ms are new diagnostic fields from admin_send_online_order_status_photo
      // - per direct request, so we can actually see how long the retries take and whether a send
      // succeeds/fails consistently, not just a pass/fail alert. Always logged; also surfaced to
      // staff so they don't have to ask a developer to check the console.
      const attempts = photoResult?.attempts_used;
      const elapsedSeconds = photoResult?.elapsed_ms != null ? (photoResult.elapsed_ms / 1000).toFixed(1) : null;
      console.log('[online order photo send]', { orderId, sent: photoResult?.photo_sent, attempts, elapsedMs: photoResult?.elapsed_ms, error: photoResult?.photo_error || photoError?.message });

      if (photoError || (photoResult && photoResult.photo_sent === false)) {
        // Status change (and text message, if requested) already went through fine - only the
        // photo attachment failed. Surface it so staff know to just describe the item to the
        // customer instead, without implying the whole notification failed.
        const detail = photoError ? photoError.message : (photoResult?.photo_error || 'unknown error');
        const timingNote = elapsedSeconds != null ? ` (gave up after ${attempts} attempt(s), ${elapsedSeconds}s)` : '';
        alert('Status updated, but the photo could not be attached: ' + detail + timingNote);
      } else if (photoResult && photoResult.photo_sent) {
        // Brief success flash with timing, then the finally block below hides the banner as usual.
        showSendStatusBanner(`Photo sent! (${attempts} attempt(s), ${elapsedSeconds}s)`);
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }

    await refreshCurrentOrders();
    if (!document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
  } finally {
    hideSendStatusBanner();
  }
}

// Serial labels - per "is it possible to move the printout of serials": the same 100x30mm label the
// desktop prints (MainForm.DrawSerialNumberLabel): serial in bold, item code, description (2 lines max),
// Code128 barcode of the serial. One label per page, printed through the browser's print dialog - pick
// the label printer there. Rendered in a hidden iframe so it isn't blocked as a popup.
//
// Now goes through js/labelPrinter.js first: with QZ Tray running and General Setup's Barcode Printer
// set, labels print straight to the barcode printer (no dialog); otherwise LabelPrinter falls back to
// the same dialog printing as below. printSerialLabelsDialog is kept only for a page without it loaded.
function printSerialLabels(labels) {
  if (!labels || !labels.length) return;
  if (window.LabelPrinter) {
    LabelPrinter.init(currentSession);
    LabelPrinter.printSerialLabels(labels).then((r) => { if (r.via !== 'qz') console.info('Serial labels:', r.message); });
    return;
  }
  printSerialLabelsDialog(labels);
}

function printSerialLabelsDialog(labels) {
  if (!labels || !labels.length) return;
  document.getElementById('serialLabelFrame')?.remove();
  const body = labels.map((l) => `
    <div class="label">
      <div class="sn">${escapeHtml(l.serialNo)}</div>
      ${l.itemCode ? `<div class="ic">${escapeHtml(l.itemCode)}</div>` : ''}
      ${l.description ? `<div class="desc">${escapeHtml(l.description)}</div>` : ''}
      <svg class="bc" data-value="${escapeHtml(l.serialNo)}"></svg>
    </div>`).join('');
  const frame = document.createElement('iframe');
  frame.id = 'serialLabelFrame';
  frame.setAttribute('aria-hidden', 'true');
  frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden;';
  frame.srcdoc = `<!doctype html><html><head><meta charset="utf-8"><title>Serial labels</title><style>
    @page { size: 100mm 30mm; margin: 0; }
    html, body { margin: 0; padding: 0; background: #fff; }
    body { font-family: Arial, Helvetica, sans-serif; color: #000; }
    .label { width: 100mm; height: 30mm; box-sizing: border-box; padding: 1.5mm 2mm 1mm; display: flex; flex-direction: column;
             align-items: center; overflow: hidden; break-after: page; page-break-after: always; }
    .label:last-child { break-after: auto; page-break-after: auto; }
    .sn { font-size: 9pt; font-weight: 700; line-height: 1.15; }
    .ic { font-size: 7pt; font-weight: 700; line-height: 1.15; }
    .desc { font-size: 6.5pt; line-height: 1.15; text-align: center; max-height: 2.3em; overflow: hidden; }
    .bc { width: 92mm; flex: 1 1 auto; min-height: 6mm; margin-top: .5mm; }
  </style></head><body>${body}
  <script src="https://cdn.jsdelivr.net/npm/jsbarcode@3.11.6/dist/JsBarcode.all.min.js"><\/script>
  <script>
    window.onload = function () {
      try {
        document.querySelectorAll('svg.bc').forEach(function (el) {
          JsBarcode(el, el.getAttribute('data-value'), { format: 'CODE128', displayValue: false, margin: 0, height: 60, width: 2 });
          el.setAttribute('preserveAspectRatio', 'none');
          el.removeAttribute('width'); el.removeAttribute('height');
        });
      } catch (e) { /* labels still print, without the barcode */ }
      setTimeout(function () { window.focus(); window.print(); }, 200);
    };
  <\/script></body></html>`;
  document.body.appendChild(frame);
}

// "Print Serial Labels" on the order card: every serial tied to the order (picked or created at Ready
// to Ship) - for reprints (staff_get_online_order_serial_labels).
async function printOrderSerialLabels(orderId, btn) {
  btn.disabled = true;
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_serial_labels', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: String(orderId)
  });
  btn.disabled = false;
  if (error) {
    alert('Could not load this order\'s serials: ' + error.message);
    return;
  }
  if (!data || !data.length) {
    alert(`Order ${orderId} has no serials yet - they're picked or created at Ready to Ship.`);
    return;
  }
  printSerialLabels(data.map((s) => ({ serialNo: s.serial_no, itemCode: s.item_code, description: s.description })));
}

// Fetches which of this order's lines need a serial pick before shipping, and how many - see
// supabase_online_order_to_ship_serials.sql (resolves Pancake's item_code/category server-side and
// applies the same prefix/IsProductionCategory rule OnlineOrdersForm.cs uses, so the client doesn't
// need to duplicate that logic).
// Re-reads the order's lines from Pancake right now (supabase_online_order_refresh_lines_before_ship.sql)
// - Pancake gives lines new IDs when an order is saved again, and until the background sync catches up
// the saved lines can hold old + new copies (Ready to Ship asked for 4 serials on a 2-line order).
// Returns null when done (or the SQL isn't run yet), else the error message.
async function refreshOrderLinesFromPancake(orderId) {
  const { error } = await supabaseClient.rpc('staff_refresh_online_order_lines', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: String(orderId)
  });
  if (!error) return null;
  if (/could not find the function|does not exist/i.test(error.message || '')) return null;
  return error.message || 'unknown error';
}

async function getOrderSerialRequirements(orderId) {
  const { data, error } = await supabaseClient.rpc('admin_get_online_order_serial_requirements', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });
  if (error) throw error;
  return data || [];
}

// --- Serial picker modal (#shipSerialModal) ---------------------------------------------------
// Reuses the .serial-tag-picker/.serial-tag-chip/.item-suggest-* styling and interaction pattern
// Transfer Orders already established (js/transferOrders.js's searchAvailableSerialsForRow etc.) -
// duplicated rather than shared, same "no module system" reason as resolveIsProductionWarehouse
// above. Only offers EXISTING IN_STOCK serials (see supabase_online_order_to_ship_serials.sql's
// header comment) - if staff can't find enough, Confirm blocks with a message pointing them to the
// desktop app instead of letting them ship short.

function getSelectedSerialsForShipPicker(picker) {
  try {
    return JSON.parse(picker.dataset.selected || '[]');
  } catch {
    return [];
  }
}

function updateShipSerialTagCount(picker) {
  const selected = getSelectedSerialsForShipPicker(picker);
  const required = Math.max(0, parseFloat(picker.dataset.required) || 0);
  const countEl = picker.querySelector('.serial-tag-count');
  const satisfied = selected.length === required;
  const fresh = selected.filter((s) => s.isNew).length;
  countEl.textContent = `${selected.length} / ${required} selected${fresh ? ` (${fresh} new)` : ''}`;
  countEl.classList.toggle('satisfied', satisfied && required > 0);
  countEl.classList.toggle('unsatisfied', !satisfied);
  const newBtn = picker.querySelector('.serial-tag-new');
  if (newBtn) newBtn.disabled = selected.length >= required;
  // A "Pick a serial for every unit" error from an earlier Confirm is stale once the selection
  // changes - clear it so a now-complete picker doesn't still show it.
  document.getElementById('shipSerialModalError')?.classList.add('hidden');
}

// "+ New serial" - per "is it possible to move the printout of serials" / "at ready to ship": a
// placeholder for a unit with no In Stock serial. The real serial (RS-<ItemCode>-<YY>-000001) is
// created by admin_update_online_order_status when the order ships, and its label printed then
// (supabase_online_order_ship_new_serials.sql). Placeholders use negative ids so they never clash
// with a real RunningSerialNo.
let shipNewSerialSeq = 0;
function addNewSerialPlaceholder(picker) {
  const selected = getSelectedSerialsForShipPicker(picker);
  const required = Math.max(0, parseFloat(picker.dataset.required) || 0);
  if (selected.length >= required) return;
  selected.push({ runningSerialNo: -(++shipNewSerialSeq), serialNo: 'New serial', isNew: true });
  picker.dataset.selected = JSON.stringify(selected);
  renderShipSerialTagChips(picker);
  updateShipSerialTagCount(picker);
}

function renderShipSerialTagChips(picker) {
  const chipsEl = picker.querySelector('.serial-tag-chips');
  const selected = getSelectedSerialsForShipPicker(picker);
  chipsEl.innerHTML = selected
    .map((s) => `
      <span class="serial-tag-chip${s.isNew ? ' is-new' : ''}" data-running-serial-no="${s.runningSerialNo}" ${s.isNew ? 'title="Created and printed when the order ships"' : ''}>
        ${s.isNew ? '&#65291; New serial' : escapeHtml(s.serialNo)}<span class="serial-tag-chip-remove" title="Remove">&times;</span>
      </span>
    `)
    .join('');

  chipsEl.querySelectorAll('.serial-tag-chip-remove').forEach((removeBtn) => {
    removeBtn.addEventListener('click', () => {
      const chip = removeBtn.closest('.serial-tag-chip');
      const runningSerialNo = Number(chip.dataset.runningSerialNo);
      const remaining = getSelectedSerialsForShipPicker(picker).filter((s) => s.runningSerialNo !== runningSerialNo);
      picker.dataset.selected = JSON.stringify(remaining);
      renderShipSerialTagChips(picker);
      updateShipSerialTagCount(picker);
    });
  });
}

function addSerialTagToShipPicker(picker, serial) {
  const selected = getSelectedSerialsForShipPicker(picker);
  if (selected.some((s) => s.runningSerialNo === serial.runningSerialNo)) return;
  selected.push(serial);
  picker.dataset.selected = JSON.stringify(selected);
  renderShipSerialTagChips(picker);
  updateShipSerialTagCount(picker);
}

async function searchAvailableSerialsForShipLine(lineEl, picker, searchText) {
  const dropdown = picker.querySelector('.serial-tag-dropdown');
  const itemCode = lineEl.dataset.itemCode;
  const variationId = lineEl.dataset.variationId;

  let query = supabaseClient
    .from('ItemSerialTracking')
    .select('RunningSerialNo, SerialNo, ItemCode, VariantCode')
    .eq('Status', 'IN_STOCK')
    .eq('ItemCode', itemCode);
  query = variationId ? query.eq('VariantCode', variationId) : query.or('VariantCode.is.null,VariantCode.eq.');
  // Only offer serials physically at the staff member's own location - same reasoning as Transfer
  // Orders' identical restriction (searchAvailableSerialsForRow). Staff with no assigned warehouse
  // stay unrestricted, same convention used everywhere else this session field is checked.
  // Shipping from stock: the order's own branch instead (shipSerialWarehouse, set by handleToShipClick).
  const serialLocation = shipSerialWarehouse || currentSession?.warehouseName;
  if (serialLocation) {
    query = query.eq('Location', serialLocation);
  }
  if (searchText && searchText.trim()) {
    query = query.ilike('SerialNo', `%${searchText.trim()}%`);
  }
  query = query.order('SerialNo').limit(20);

  const { data, error } = await query;

  if (error) {
    dropdown.innerHTML = `<div class="item-suggest-empty error-text">${escapeHtml(error.message)}</div>`;
    dropdown.classList.remove('hidden');
    return;
  }

  const selected = getSelectedSerialsForShipPicker(picker);
  const alreadySelected = new Set(selected.map((s) => s.runningSerialNo));
  const available = (data || []).filter((s) => !alreadySelected.has(s.RunningSerialNo));

  if (available.length === 0) {
    dropdown.innerHTML = '<div class="item-suggest-empty muted">No available serials found.</div>';
    dropdown.classList.remove('hidden');
    return;
  }

  dropdown.innerHTML = available
    .map((s) => `<div class="item-suggest-option" data-running-serial-no="${s.RunningSerialNo}" data-serial-no="${encodeURIComponent(s.SerialNo)}">${escapeHtml(s.SerialNo)}</div>`)
    .join('');
  dropdown.classList.remove('hidden');

  // mousedown + preventDefault, same reasoning as Transfer Orders' identical picker - keeps the
  // search input focused so there's no blur-vs-click race hiding the dropdown before a pick lands.
  dropdown.querySelectorAll('.item-suggest-option').forEach((opt) => {
    opt.addEventListener('mousedown', (e) => {
      e.preventDefault();
      addSerialTagToShipPicker(picker, {
        runningSerialNo: Number(opt.dataset.runningSerialNo),
        serialNo: decodeURIComponent(opt.dataset.serialNo)
      });
      dropdown.classList.add('hidden');
      dropdown.innerHTML = '';
      picker.querySelector('.serial-tag-search').value = '';
    });
  });
}

function wireShipSerialPicker(lineEl, picker) {
  updateShipSerialTagCount(picker);
  picker.querySelector('.serial-tag-new').addEventListener('click', () => addNewSerialPlaceholder(picker));

  const searchInput = picker.querySelector('.serial-tag-search');
  const dropdown = picker.querySelector('.serial-tag-dropdown');
  let debounceHandle = null;

  searchInput.addEventListener('input', (e) => {
    clearTimeout(debounceHandle);
    const value = e.target.value;
    debounceHandle = setTimeout(() => searchAvailableSerialsForShipLine(lineEl, picker, value), 250);
  });
  searchInput.addEventListener('focus', () => searchAvailableSerialsForShipLine(lineEl, picker, searchInput.value));
  searchInput.addEventListener('blur', () => {
    setTimeout(() => dropdown.classList.add('hidden'), 150);
  });
}

function renderShipSerialModal(requirements) {
  const container = document.getElementById('shipSerialModalLines');
  container.innerHTML = requirements
    .map((r) => `
      <div class="ship-serial-line" data-line-id="${r.line_id}" data-item-code="${escapeHtml(r.item_code)}" data-variation-id="${escapeHtml(r.variation_id || '')}" data-description="${escapeHtml(r.description || r.item_code)}" style="margin-bottom:18px;">
        <div class="ship-serial-line-label" style="font-weight:600; margin-bottom:6px;">${escapeHtml(r.description || r.item_code)} <span class="muted">(need ${r.quantity_needed})</span></div>
        <div class="serial-tag-picker" data-required="${r.quantity_needed}" data-selected="[]">
          <div class="serial-tag-count muted">0 / ${r.quantity_needed} selected</div>
          <div class="serial-tag-chips"></div>
          <div class="serial-tag-row">
            <input type="text" class="serial-tag-search" placeholder="Search serial no..." autocomplete="off" />
            <button type="button" class="bc-btn serial-tag-new" title="No serial in stock - create one when the order ships and print its label">&#65291; New serial</button>
          </div>
          <div class="serial-tag-dropdown hidden"></div>
        </div>
      </div>
    `)
    .join('');

  container.querySelectorAll('.ship-serial-line').forEach((lineEl) => {
    const picker = lineEl.querySelector('.serial-tag-picker');
    wireShipSerialPicker(lineEl, picker);
    // Custom builds start pre-filled with "+ New serial" (see isCustomBuildItem) - removable if a
    // unit does have a serial already.
    if (isCustomBuildItem(lineEl.dataset.itemCode, lineEl.dataset.description)) {
      const required = Math.max(0, Math.round(parseFloat(picker.dataset.required) || 0));
      for (let i = 0; i < required; i++) addNewSerialPlaceholder(picker);
    }
  });
}

// Per "if its a custom item and there is no serial.. should we print the serial automatically": a
// custom aquarium / stand / sump is built for this one order, so there's never an In Stock serial to
// pick - it always gets a new serial (created and label printed when the order ships). Stock items
// (AQ-..., production categories) still have their built units picked.
// Checks the item code AND the line description: a custom aquarium's line often resolves to its
// variant's own item code (not "CUSTOM-..."), with "CUSTOM-AQUARIUM" only in the description.
function isCustomBuildItem(itemCode, description) {
  const pattern = /(^|[^a-z])custom[\s_-]*(aquarium|tank|stand|sump|cabinet)/i;
  return pattern.test(itemCode || '') || pattern.test(description || '');
}

// Resolves with an array of runningSerialNo once every line is fully picked and Confirm is
// clicked, or null if staff cancels - handleToShipClick treats null as "abort To Ship entirely".
let shipSerialModalResolve = null;

function openShipSerialModal(requirements) {
  // Only custom builds on the order - nothing to pick, so no picker at all: every unit gets a new
  // serial and its label prints once the status change goes through.
  if (requirements.length && requirements.every((r) => isCustomBuildItem(r.item_code, r.description))) {
    return Promise.resolve({
      running: [],
      fresh: requirements.map((r) => ({
        item_code: r.item_code,
        variation_id: r.variation_id || null,
        description: r.description || r.item_code,
        quantity: Math.max(1, Math.round(parseFloat(r.quantity_needed) || 1))
      }))
    });
  }
  return new Promise((resolve) => {
    shipSerialModalResolve = resolve;
    document.getElementById('shipSerialModalError').classList.add('hidden');
    renderShipSerialModal(requirements);
    document.getElementById('shipSerialModal').classList.remove('hidden');
  });
}

function closeShipSerialModal(result) {
  document.getElementById('shipSerialModal').classList.add('hidden');
  const resolve = shipSerialModalResolve;
  shipSerialModalResolve = null;
  if (resolve) resolve(result);
}

function wireShipSerialModalButtons() {
  document.getElementById('shipSerialModalCancelBtn').addEventListener('click', () => closeShipSerialModal(null));

  document.getElementById('shipSerialModalConfirmBtn').addEventListener('click', () => {
    const pickers = Array.from(document.querySelectorAll('#shipSerialModalLines .serial-tag-picker'));
    const errorEl = document.getElementById('shipSerialModalError');
    const incompleteLabels = [];
    const running = [];
    const fresh = [];

    pickers.forEach((picker) => {
      const lineEl = picker.closest('.ship-serial-line');
      const required = Math.max(0, parseFloat(picker.dataset.required) || 0);
      const selected = getSelectedSerialsForShipPicker(picker);
      if (selected.length < required) {
        incompleteLabels.push(lineEl.querySelector('.ship-serial-line-label').textContent.trim());
      }
      running.push(...selected.filter((s) => !s.isNew).map((s) => s.runningSerialNo));
      const newCount = selected.filter((s) => s.isNew).length;
      if (newCount) {
        fresh.push({
          item_code: lineEl.dataset.itemCode,
          variation_id: lineEl.dataset.variationId || null,
          description: lineEl.dataset.description,
          quantity: newCount
        });
      }
    });

    if (incompleteLabels.length > 0) {
      errorEl.textContent = `Pick a serial for every unit needed: ${incompleteLabels.join(', ')}. No serial in stock? Tap "+ New serial".`;
      errorEl.classList.remove('hidden');
      return;
    }

    // { running: existing serials to claim, fresh: new serials to create } - see applyStatusChange.
    closeShipSerialModal({ running, fresh });
  });
}

// Tracks which order/button is waiting on the shared #toShipPhotoInput's result (see
// handleToShipClick/handleToShipPhotoSelected/handleToShipPhotoCancelled below).
let pendingToShip = null;

function handleOrderTableClick(event) {
  const toShipBtn = event.target.closest('.status-to-ship-btn');
  const sendPhotoBtn = event.target.closest('.status-send-photo-btn');
  const sendMessageBtn = event.target.closest('.status-send-message-btn');
  if (!toShipBtn && !sendPhotoBtn && !sendMessageBtn) return;

  // Generic [data-order-id] (not tr[data-order-id]) - matches both the flat table's <tr> rows and
  // the grouped view's <div class="order-card"> cards (see orderCardHtml above), since the same
  // handler covers both.
  const row = event.target.closest('[data-order-id]');
  if (!row) return;

  if (sendMessageBtn) {
    openSendMessageModal(row.dataset.orderId);
    return;
  }
  if (sendPhotoBtn) {
    handleSendPhotoClick(row.dataset.orderId, sendPhotoBtn);
    return;
  }
  handleToShipClick(row.dataset.orderId, toShipBtn);
}

// "TO-SHIP" (was a generic "Send Message" button, per direct request now labeled/prefilled for
// this one use) - brings GMA Conversations' own "Send to customer" capability to this page, per
// direct request. Not every order here came from a GMA conversation though, so the routing has to
// be resolved per-order first (admin_get_online_order_messaging_route, see sql/supabase_online_
// order_send_message.sql's header comment for the full reasoning): a GMA-originated order has no
// Pancake conversation at all (Psid is always null for those) and can only be reached via the GMA
// Facebook Page's own Graph API - the exact same chatbot-staff-reply Edge Function GMA
// Conversations' own send button already calls, just with an explicit psid instead of relying on
// that page's "currently open conversation" state. Every other order already has a real Pancake
// conversation (Page_ID/Conversation_ID, populated by the regular sync) and goes through
// admin_send_online_order_message instead, which mirrors _send_online_order_status_message's own
// Pancake call exactly.
//
// The composer now opens prefilled with admin_render_online_order_to_ship_message's output - the
// exact same "your order is ready" template the local POS (OnlineOrdersForm.cs's To Ship button/
// GlobalSettings.PickupReadyMessage) sends, so staff aren't typing it from scratch. Still an
// editable textarea before Send, same as before.
let sendMessageOrderId = null;
let sendMessageRoute = null;

// Sends the standard "your order is ready" message (same template as the dialog) for a Pancake
// conversation order, with no dialog. True when Pancake accepted it.
async function resendToShipMessage(orderId) {
  const creds = { p_admin_username: currentSession.username, p_admin_password: currentSession.password, p_order_id: orderId };
  const { data: text, error: renderError } = await supabaseClient.rpc('admin_render_online_order_to_ship_message', creds);
  if (renderError || !text || !String(text).trim()) return false;
  const { error } = await supabaseClient.rpc('admin_send_online_order_message', { ...creds, p_message: text });
  return !error;
}

async function openSendMessageModal(orderId) {
  sendMessageOrderId = orderId;
  sendMessageRoute = null;

  const modal = document.getElementById('sendOrderMessageModal');
  const subEl = document.getElementById('sendOrderMessageSub');
  const errorEl = document.getElementById('sendOrderMessageError');
  const textEl = document.getElementById('sendOrderMessageText');
  const sendBtn = document.getElementById('sendOrderMessageSendBtn');

  textEl.value = '';
  errorEl.classList.add('hidden');
  subEl.textContent = `Order ${orderId} - checking where this customer can be reached...`;
  sendBtn.disabled = true;
  modal.classList.remove('hidden');

  const [routeResult, messageResult] = await Promise.all([
    supabaseClient.rpc('admin_get_online_order_messaging_route', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId
    }),
    supabaseClient.rpc('admin_render_online_order_to_ship_message', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId
    })
  ]);
  const { data, error } = routeResult;

  // Prefill is best-effort - a failure here shouldn't block sending, just leaves the textarea for
  // staff to type into manually like before.
  if (!messageResult.error && messageResult.data) {
    textEl.value = messageResult.data;
  }

  if (error || !data || data.length === 0) {
    subEl.textContent = `Order ${orderId}`;
    errorEl.textContent = error?.message || 'Could not determine how to reach this customer.';
    errorEl.classList.remove('hidden');
    return;
  }

  sendMessageRoute = data[0];
  const name = sendMessageRoute.customer_name || 'this customer';

  if (sendMessageRoute.is_gma_order) {
    subEl.textContent = `To ${name} (Order ${orderId}) - via the GMA Page.`;
    sendBtn.disabled = false;
  } else if (sendMessageRoute.has_pancake_conversation) {
    subEl.textContent = `To ${name} (Order ${orderId}) - via Pancake.`;
    sendBtn.disabled = false;
  } else {
    subEl.textContent = `Order ${orderId}`;
    errorEl.textContent = 'This order has no linked Messenger conversation on either platform - there is nowhere to send a message.';
    errorEl.classList.remove('hidden');
  }
}

function closeSendMessageModal() {
  document.getElementById('sendOrderMessageModal').classList.add('hidden');
  sendMessageOrderId = null;
  sendMessageRoute = null;
}

async function submitSendOrderMessage() {
  const errorEl = document.getElementById('sendOrderMessageError');
  const textEl = document.getElementById('sendOrderMessageText');
  const sendBtn = document.getElementById('sendOrderMessageSendBtn');
  errorEl.classList.add('hidden');

  const message = textEl.value.trim();
  if (!message) {
    errorEl.textContent = 'Enter a message first.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (!sendMessageRoute) return;

  sendBtn.disabled = true;
  try {
    if (sendMessageRoute.is_gma_order) {
      const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-staff-reply`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
          'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
        },
        body: JSON.stringify({
          admin_username: currentSession.username,
          admin_password: currentSession.password,
          psid: sendMessageRoute.gma_psid,
          message,
          images: []
        })
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(result.error || `Send failed (${response.status}).`);
      }
    } else {
      const { error } = await supabaseClient.rpc('admin_send_online_order_message', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_order_id: sendMessageOrderId,
        p_message: message
      });
      if (error) throw error;
    }

    closeSendMessageModal();
  } catch (err) {
    errorEl.textContent = err?.message || 'Could not send the message.';
    errorEl.classList.remove('hidden');
  } finally {
    sendBtn.disabled = false;
  }
}

function wireSendMessageModalButtons() {
  document.getElementById('sendOrderMessageCancelBtn').addEventListener('click', closeSendMessageModal);
  document.getElementById('sendOrderMessageSendBtn').addEventListener('click', submitSendOrderMessage);
}

// Delegated on #setupContent (see init() below) so this fires for the Tank/Stand Maker dropdowns
// (makerSelectHtml) in both the flat table (orderRowsHtml) and the grouped card view
// (orderCardHtml) - same delegation convention as handleOrderTableClick above, just for 'change'
// instead of 'click'. data-role ('tank'/'stand'/'dispatcher') tells admin_assign_online_order_maker which of
// the three columns this particular dropdown writes.
async function handleAssignProductionMemberChange(event) {
  const select = event.target.closest('.assign-maker-select');
  if (!select) return;

  const orderId = select.dataset.orderId;
  const role = select.dataset.role;
  const username = select.value || null;

  select.disabled = true;
  const { data, error } = await supabaseClient.rpc('admin_assign_online_order_maker', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_role: role,
    p_username: username
  });
  select.disabled = false;

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    alert('Could not update the assignment: ' + (error?.message || result?.message || 'unknown error'));
    await refreshCurrentOrders(); // reverts the dropdown back to its last saved value
    if (select.closest('#orderCardModal')) renderOrderCardAssignments();
    return;
  }

  // Edited on the Online Order document - reload the list so its Tank/Stand/Dispatcher columns
  // and the derived "Assigned" status reflect it (the card header refreshes from the new rows).
  if (select.closest('#orderCardModal')) {
    await refreshCurrentOrders();
    if (!document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
  }
}

// Mirrors OnlineOrdersForm.cs's EnsureOrderSerialTrackingAsync gate: at a production warehouse, a
// serial-tracked line (e.g. a custom aquarium) needs a physical unit's serial picked and tied to
// this order before it can ship - see supabase_online_order_to_ship_serials.sql. Only checked at
// all when the logged-in staff's own warehouse is Production (currentSessionIsProductionWarehouse,
// resolved once at init) - a regular store's To Ship never needed this, same as the desktop.
// Cancelling the serial picker aborts the whole To Ship action (nothing sent, nothing changed).
async function handleToShipClick(orderId, toShipBtn, { readyToShip = false, fromStock = false, linesRefreshed = false } = {}) {
  // Ready to Ship (the Production Manager's next-step button on a Production Done order) runs this
  // real flow even while the general To Ship button is still switched off - see nextStepFor.
  if (!TO_SHIP_ENABLED && !readyToShip) {
    alert('To-Ship is under construction, please To-Ship through the local POS for now.');
    return;
  }

  let serialRunningNos = null;
  // Shipping from stock (see stockStatusFor): the serials must be picked no matter which warehouse the
  // manager is logged in at, and they're searched at the ORDER's branch, where the stock was counted.
  shipSerialWarehouse = fromStock ? (stockStatusFor(findFlatOrder(orderId))?.warehouse_name || null) : null;
  if (fromStock) shipFromStockOrderIds.add(String(orderId));
  else shipFromStockOrderIds.delete(String(orderId));

  if (currentSessionIsProductionWarehouse || fromStock) {
    toShipBtn.disabled = true;
    if (!linesRefreshed) {
      const refreshError = await refreshOrderLinesFromPancake(orderId);
      if (refreshError) {
        alert(refreshError);
        toShipBtn.disabled = false;
        return;
      }
    }
    let requirements;
    try {
      requirements = await getOrderSerialRequirements(orderId);
    } catch (err) {
      alert('Could not check serial requirements for this order: ' + (err?.message || 'unknown error'));
      toShipBtn.disabled = false;
      return;
    }
    toShipBtn.disabled = false;

    if (requirements.length > 0) {
      serialRunningNos = await openShipSerialModal(requirements);
      if (serialRunningNos === null) return; // cancelled - To Ship not sent at all
    }
  }

  // Mirrors OnlineOrdersForm.cs's "To Ship" behavior: asks staff to confirm before notifying the
  // customer (the status change itself always goes through either way - the confirm only gates the
  // message/photo). This is the only manual status action offered on this page (see the comment
  // near the top of this file) - the button click plus the confirm() prompt means a status change
  // can never fire from a single accidental click.
  //
  // Per direct request, staff can snap a photo of the packed order on their phone and have it go
  // out with the ready notification - only prompted when notifying, since a photo is pointless
  // otherwise. Cancelling the camera/file picker just sends the text-only message.
  const notifyCustomer = window.confirm('Order complete? Do you want to update the customer?');

  if (!notifyCustomer) {
    applyStatusChange(orderId, 'To Ship', false, null, null, serialRunningNos, toShipBtn);
    return;
  }

  // Per "can we removed the picture requirement for now? ill put that back later" - Ready to Ship
  // sends the text message without asking for a photo. Flip READY_TO_SHIP_ASKS_PHOTO back to true to
  // restore the photo step.
  if (readyToShip && !READY_TO_SHIP_ASKS_PHOTO) {
    applyStatusChange(orderId, 'To Ship', true, null, null, serialRunningNos, toShipBtn);
    return;
  }

  pendingToShip = { orderId, triggerEl: toShipBtn, serialRunningNos };
  document.getElementById('toShipPhotoInput').click();
}

// Uploads the captured photo via the same signed-upload flow as Online Order Line attachments (see
// supabase_online_order_status_photo.sql) - returns {url, storagePath}, or null (with an alert) if
// the upload itself failed. Shared by both the (currently disabled) To Ship photo step and the
// standalone Send Photo button below - neither RPC it calls cares which flow triggered it.
async function uploadOrderStatusPhoto(orderId, file) {
  const { data, error } = await supabaseClient.rpc('admin_create_online_order_status_photo_upload', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_file_name: file.name || 'photo.jpg'
  });

  if (error || !data || !data[0]) {
    alert('Could not prepare the photo upload: ' + (error ? error.message : 'unknown error'));
    return null;
  }

  const { storage_path, upload_token, public_url } = data[0];
  const { error: uploadError } = await supabaseClient.storage
    .from('online-order-status-photos')
    .uploadToSignedUrl(storage_path, upload_token, file);

  if (uploadError) {
    alert('Photo upload failed: ' + uploadError.message);
    return null;
  }

  return { url: public_url, storagePath: storage_path };
}

async function handleToShipPhotoSelected(event) {
  const input = event.target;
  const file = input.files && input.files[0];
  const pending = pendingToShip;
  pendingToShip = null;
  input.value = ''; // reset so picking the same file again still fires 'change' next time

  if (!pending) return;

  if (!file) {
    // Some browsers fire 'change' with an empty file list instead of a 'cancel' event.
    applyStatusChange(pending.orderId, 'To Ship', true, null, null, pending.serialRunningNos, pending.triggerEl);
    return;
  }

  const photo = await uploadOrderStatusPhoto(pending.orderId, file);
  applyStatusChange(pending.orderId, 'To Ship', true, photo ? photo.url : null, photo ? photo.storagePath : null, pending.serialRunningNos, pending.triggerEl);
}

function handleToShipPhotoCancelled() {
  const pending = pendingToShip;
  pendingToShip = null;
  if (!pending) return;
  applyStatusChange(pending.orderId, 'To Ship', true, null, null, pending.serialRunningNos, pending.triggerEl);
}

// --- Standalone "Send Photo" button --------------------------------------------------------
// Per direct request: detached entirely from the To Ship flow above (and from any status change -
// admin_send_online_order_status_photo just messages whatever conversation is on the order record
// already, it was never actually coupled to a status transition server-side). Lets staff send a
// packed-order photo to the customer regardless of To Ship's enabled state or the order's status.

let pendingSendPhoto = null;

function handleSendPhotoClick(orderId, triggerEl) {
  pendingSendPhoto = { orderId, triggerEl };
  document.getElementById('sendPhotoInput').click();
}

// Same RPC call applyStatusChange makes for the photo half of To Ship, just fired on its own
// instead of chained after a status-change RPC - see admin_send_online_order_status_photo's own
// retry-loop/statement_timeout comments (supabase_online_order_portal_status_update.sql) for why
// this can take a few seconds.
async function sendOrderStatusPhoto(orderId, photoUrl, photoStoragePath, triggerEl) {
  triggerEl.disabled = true;
  showSendStatusBanner("Hang tight, sending the photo to the customer's conversation - this can take a few tries...");

  let sent = false;
  try {
    // GMA Page order: no Pancake conversation - send through the GMA Page instead.
    const gmaPsid = await getGmaPsid(orderId);
    if (gmaPsid) {
      const gma = await sendGmaOrderPhoto(orderId, gmaPsid, photoUrl, photoStoragePath);
      if (!gma.sent) alert('Could not send the photo: ' + (gma.error || 'unknown error'));
      else {
        sent = true;
        showSendStatusBanner('Photo sent!');
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
      return sent;
    }

    const { data, error } = await supabaseClient.rpc('admin_send_online_order_status_photo', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId,
      p_photo_url: photoUrl,
      p_photo_storage_path: photoStoragePath
    });

    const result = data && data[0];
    const attempts = result?.attempts_used;
    const elapsedSeconds = result?.elapsed_ms != null ? (result.elapsed_ms / 1000).toFixed(1) : null;
    console.log('[online order photo send]', { orderId, sent: result?.photo_sent, attempts, elapsedMs: result?.elapsed_ms, error: result?.photo_error || error?.message });

    if (error || (result && result.photo_sent === false)) {
      const detail = error ? error.message : (result?.photo_error || 'unknown error');
      const timingNote = elapsedSeconds != null ? ` (gave up after ${attempts} attempt(s), ${elapsedSeconds}s)` : '';
      alert('Could not send the photo: ' + detail + timingNote);
    } else if (result && result.photo_sent) {
      sent = true;
      showSendStatusBanner(`Photo sent! (${attempts} attempt(s), ${elapsedSeconds}s)`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  } finally {
    hideSendStatusBanner();
    triggerEl.disabled = false;
  }
  return sent;
}

// Per direct follow-up request: once a photo actually goes out, ask staff whether they're about to
// ship this order and, if so, show them which physical serials are actually available before they
// head to the local POS to do it (To Ship itself stays disabled - see TO_SHIP_ENABLED - so this is
// purely informational, nothing is picked/claimed here).
//
// Applicability deliberately mirrors the desktop's REGULAR CHECKOUT serial rule
// (ShouldRequireAquariumSerialSelection in MainForm.cs - item code prefix/category flag only), NOT
// the Online-Order-specific EnsureOrderSerialTrackingAsync gate the (disabled) To Ship flow used,
// which only checked at a warehouse flagged Production. Per direct confirmation after checking both
// against the desktop source: checkout's rule has no such gate - any warehouse selling an AQ-/
// CUSTOM- item (or one in a production-flagged category) requires a serial, so this check now runs
// regardless of currentSessionIsProductionWarehouse. Conveniently, admin_get_online_order_serial_
// requirements (supabase_online_order_to_ship_serials.sql) already implements that same
// prefix/category rule with no warehouse gate of its own - so nothing there needed to change, only
// the client-side "only if production warehouse" shortcut this function used to add on top.
async function promptShipAfterPhoto(orderId) {
  if (!window.confirm('Are you going to ship this order?')) return;

  let requirements;
  try {
    requirements = await getOrderSerialRequirements(orderId);
  } catch (err) {
    alert('Could not check serial availability for this order: ' + (err?.message || 'unknown error'));
    return;
  }
  if (requirements.length === 0) return;

  // Actual serial numbers (not just a count) - same IN_STOCK/ItemCode/VariantCode/Location filters
  // as searchAvailableSerialsForShipLine above, just read-only display instead of a picker.
  const lines = [];
  for (const r of requirements) {
    let query = supabaseClient
      .from('ItemSerialTracking')
      .select('SerialNo')
      .eq('Status', 'IN_STOCK')
      .eq('ItemCode', r.item_code);
    query = r.variation_id ? query.eq('VariantCode', r.variation_id) : query.or('VariantCode.is.null,VariantCode.eq.');
    if (currentSession?.warehouseName) {
      query = query.eq('Location', currentSession.warehouseName);
    }
    query = query.order('SerialNo').limit(50);

    const { data, error } = await query;
    lines.push({
      description: r.description || r.item_code,
      quantityNeeded: r.quantity_needed,
      serialNumbers: error ? [] : (data || []).map((s) => s.SerialNo)
    });
  }

  openViewSerialsModal(lines);
}

function renderViewSerialsModal(lines) {
  const container = document.getElementById('viewSerialsModalLines');
  container.innerHTML = lines
    .map((l) => `
      <div style="margin-bottom:16px;">
        <div style="font-weight:600; margin-bottom:6px;">${escapeHtml(l.description)} <span class="muted">(need ${l.quantityNeeded})</span></div>
        ${l.serialNumbers.length === 0
          ? '<p class="error-text" style="margin:0;">No serials found, please To-Ship through your local POS.</p>'
          : `<ul style="margin:0; padding-left:20px;">${l.serialNumbers.map((s) => `<li>${escapeHtml(s)}</li>`).join('')}</ul>`}
      </div>
    `)
    .join('');
}

function openViewSerialsModal(lines) {
  renderViewSerialsModal(lines);
  document.getElementById('viewSerialsModal').classList.remove('hidden');
}

function wireViewSerialsModalButtons() {
  document.getElementById('viewSerialsModalCloseBtn').addEventListener('click', () => {
    document.getElementById('viewSerialsModal').classList.add('hidden');
  });
}

async function handleSendPhotoSelected(event) {
  const input = event.target;
  const file = input.files && input.files[0];
  const pending = pendingSendPhoto;
  pendingSendPhoto = null;
  input.value = ''; // reset so picking the same file again still fires 'change' next time

  if (!pending || !file) return; // no pending request, or staff cancelled the camera/file picker

  const photo = await uploadOrderStatusPhoto(pending.orderId, file);
  if (!photo) return; // uploadOrderStatusPhoto already alerted with the reason

  const sent = await sendOrderStatusPhoto(pending.orderId, photo.url, photo.storagePath, pending.triggerEl);
  if (sent) await promptShipAfterPhoto(pending.orderId);
}

function handleSendPhotoCancelled() {
  pendingSendPhoto = null;
}

// ---------------------------------------------------------------- BC list selection + action bar

// The flat list's rows as last rendered, and which one is selected - the action bar's Open / Send
// Photo / To-Ship Message / To Ship all act on selectedOrderId (BC: actions work on the current
// line). Kept across reloads by id so a refresh doesn't drop the selection.
let lastFlatRows = [];
let selectedOrderId = null;

function findFlatOrder(orderId) {
  return lastFlatRows.find((o) => String(o.order_id) === String(orderId)) || null;
}

// 'Assigned' is a Printed order whose makers are set - To Ship is allowed from either.
function isPrintedOrder(o) {
  const status = (o?.status || '').trim().toLowerCase();
  return status === 'printed' || status === 'assigned';
}

function updateOrderActionState() {
  const o = findFlatOrder(selectedOrderId);
  ['openOrderBtn', 'listSendPhotoBtn', 'listSendMessageBtn'].forEach((id) => { document.getElementById(id).disabled = !o; });
  document.getElementById('listToShipBtn').disabled = !isPrintedOrder(o);
  document.getElementById('listAssignBtn').disabled = !o;
  updateProductionDoneButton('listProductionDoneBtn', o);
  updateSendBackButton('listSendBackBtn', o);
  updateNextStepButton('listNextStepBtn', o);
  ensureStockStatus(o);
}

// ---------------------------------------------------------------- Assign popup

// Assigning is the Production Manager's call (or a Super User's) - see supabase_production_manager_role.sql.
function canAssignOrders() {
  return !!(currentSession?.isSuperUser || currentSession?.isProductionManager);
}

let assignDialogOrderId = null;

// Options for one role's dropdown: only staff holding that Staff Role, plus the current assignee
// even if they've since lost the role (shown, not re-pickable) so nothing is silently blanked.
function assignOptionsHtml(order, role) {
  const cfg = MAKER_ROLES[role];
  const current = order[`assigned_${cfg.field}`] || '';
  const pool = productionMembers.filter((m) => (m.staff_roles || []).includes(cfg.staffRole));
  let html = `<option value="">(Not assigned)</option>` + pool
    .map((m) => `<option value="${escapeHtml(m.username)}" ${m.username === current ? 'selected' : ''}>${escapeHtml(m.display_name)}</option>`)
    .join('');
  if (current && !pool.some((m) => m.username === current)) {
    html += `<option value="${escapeHtml(current)}" selected disabled>${escapeHtml(order[`assigned_${cfg.field}_name`] || current)} (no role)</option>`;
  }
  return html;
}

async function openAssignDialog(orderId) {
  if (!findFlatOrder(orderId) || !canAssignOrders()) return;

  // Re-read the roster every time - roles ticked in User Setup after this page was opened must
  // show up without a page reload. Reload the list too: its aquarium/stand flags come from the
  // portal's synced OnlineOrderLines, and the copy in memory is from when the list was last loaded -
  // per "the new item i add is custom-stand but when I hit assign I cannot assign it to my stand
  // maker", an item synced in after that wasn't counted.
  showSendStatusBanner('Loading the latest order lines...');
  try {
    await Promise.all([refreshCurrentOrders(), loadProductionMembers()]);
  } finally {
    hideSendStatusBanner();
  }

  const o = findFlatOrder(orderId);
  if (!o) return;
  assignDialogOrderId = String(o.order_id);

  document.getElementById('assignDialogTitle').textContent = `${o.order_id}${o.customer_name ? ' · ' + o.customer_name : ''}`;
  // has_aquarium_line = any custom line that isn't a stand/top cover (Tank Maker); has_stand_line =
  // custom stand or top cover (Stand Maker) - _online_order_line_part, supabase_online_order_maker_line_rules.sql.
  // A 10mm / 12mm glass order needs a Tank Maker even with no custom line
  // (supabase_online_order_thick_glass_tank_maker.sql).
  const thickGlass = /^(10|12)mm$/i.test(String(o.glass_thickness || '').replace(/\s+/g, ''));
  const needs = [o.has_aquarium_line ? (thickGlass && !o.has_custom_line ? `${o.glass_thickness} glass tank work` : 'custom tank work') : null, o.has_stand_line ? 'a stand / top cover' : null].filter(Boolean);
  // Only custom orders go Confirmed > Assigned > To Ship here; normal orders still go through the
  // local POS (see _online_order_assignment_complete in supabase_online_order_assigned_status.sql).
  // Per "no need to asign a dispatcher since the dispatcher will be logged after shipping the order" -
  // only the makers are assigned; whoever marks the order Shipped is recorded as its Dispatcher
  // (admin_mark_online_order_shipped, supabase_online_order_dispatcher_on_ship.sql).
  document.getElementById('assignDialogLede').textContent = needs.length
    ? `This order has ${needs.join(' and ')} to build. It moves to Assigned once every maker is set.`
    : 'This order has no custom items to build - nothing to assign. Print and ship it from the local POS.';

  document.getElementById('assignTankRow').classList.toggle('hidden', !o.has_aquarium_line);
  document.getElementById('assignStandRow').classList.toggle('hidden', !o.has_stand_line);
  document.getElementById('assignTankSelect').innerHTML = assignOptionsHtml(o, 'tank');
  document.getElementById('assignStandSelect').innerHTML = assignOptionsHtml(o, 'stand');

  const missing = ['TankMaker', 'StandMaker']
    .filter((r) => !productionMembers.some((m) => (m.staff_roles || []).includes(r)))
    .map((r) => MAKER_ROLES[Object.keys(MAKER_ROLES).find((k) => MAKER_ROLES[k].staffRole === r)].label);
  document.getElementById('assignDialogHint').textContent = productionMembersError
    ? `Could not load the staff list: ${productionMembersError} - make sure sql/supabase_online_order_maker_by_role.sql and sql/supabase_online_order_dispatcher.sql have been run.`
    : missing.length
      ? `No active staff has the ${missing.join(' / ')} role yet - tick it in User Setup > (employee) > Roles.`
      : '';

  document.getElementById('assignDialogError').classList.add('hidden');
  document.getElementById('assignDialog').classList.remove('hidden');
}

function closeAssignDialog() {
  assignDialogOrderId = null;
  document.getElementById('assignDialog').classList.add('hidden');
}

async function saveAssignDialog() {
  const o = findFlatOrder(assignDialogOrderId);
  if (!o) return closeAssignDialog();
  const errorEl = document.getElementById('assignDialogError');
  errorEl.classList.add('hidden');

  const picks = [
    ['tank', 'assignTankSelect', o.has_aquarium_line],
    ['stand', 'assignStandSelect', o.has_stand_line]
  ].filter(([role, id, needed]) => {
    if (!needed) return false;
    const value = document.getElementById(id).value || null;
    return value !== (o[`assigned_${MAKER_ROLES[role].field}`] || null);
  });

  // Nothing changed - but if every needed maker is already set and the order still isn't Assigned
  // (the last status update to Pancake failed, e.g. "SSL_ERROR_SYSCALL"), OK retries just the status.
  const statusKey = (o.status || '').trim().toLowerCase();
  const needsStatusRetry = !picks.length
    && (o.has_aquarium_line || o.has_stand_line)
    && (!o.has_aquarium_line || !!o.assigned_tank_maker)
    && (!o.has_stand_line || !!o.assigned_stand_maker)
    && ['confirmed', 'submitted', 'printed'].includes(statusKey);
  if (!picks.length && !needsStatusRetry) return closeAssignDialog();

  const btn = document.getElementById('saveAssignDialogBtn');
  btn.disabled = true;
  btn.textContent = 'Saving...';
  const failures = [];
  for (const [role, id] of picks) {
    const { data, error } = await supabaseClient.rpc('admin_assign_online_order_maker', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: o.order_id,
      p_role: role,
      p_username: document.getElementById(id).value || null
    });
    const result = Array.isArray(data) ? data[0] : data;
    if (error || !result || !result.success) failures.push(`${MAKER_ROLES[role].label}: ${error?.message || result?.message || 'failed'}`);
  }
  // Moves the order to 'Assigned' (and Pancake's matching status) once every needed role is
  // filled, or back to 'Printed' if one was cleared - see admin_sync_online_order_assigned_status.
  if (!failures.length) {
    btn.textContent = 'Updating status...';
    const result = await syncAssignedStatus(o, btn);
    if (result.error) {
      failures.push(`Saved, but the status wasn't updated: ${result.error.message}`);
    } else if (result.sync?.message_sent || result.sync?.message_error) {
      // First time Assigned: say how the "in production" customer message went.
      const note = assignedStatusNote(o, result);
      if (note) alert(note);
    }
  }
  btn.disabled = false;
  btn.textContent = 'OK';

  // Reload either way so the list, the open card and the derived "Assigned" status show what's
  // actually saved.
  await refreshCurrentOrders();
  if (!document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();

  if (failures.length) {
    errorEl.textContent = failures.join(' · ');
    errorEl.classList.remove('hidden');
    return;
  }
  closeAssignDialog();
}

// Sends to a GMA Page customer through chatbot-staff-reply (same as the Send Message modal's GMA
// route) - normal send inside Facebook's 24h window, HUMAN_AGENT-tagged after it. Never throws.
async function sendGmaMessage(psid, message, images) {
  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/chatbot-staff-reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      },
      body: JSON.stringify({
        admin_username: currentSession.username,
        admin_password: currentSession.password,
        psid,
        message: message || '',
        images: images || []
      })
    });
    const result = await response.json().catch(() => ({}));
    if (response.ok) return { sent: true, error: null };
    return { sent: false, error: result.error || `Send failed (${response.status}).` };
  } catch (err) {
    return { sent: false, error: err?.message || 'Could not reach the GMA Page.' };
  }
}

// The GMA psid for a GMA Page order, or null for a Pancake order (supabase_online_order_send_message.sql).
async function getGmaPsid(orderId) {
  const { data, error } = await supabaseClient.rpc('admin_get_online_order_messaging_route', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });
  const route = !error && Array.isArray(data) ? data[0] : null;
  return route?.is_gma_order ? route.gma_psid : null;
}

// Sends a status photo to a GMA Page customer and logs it in the same photo history as Pancake orders
// (supabase_online_order_status_message_gma.sql). The photo's own Storage cleanup cron still owns the
// file, so no path is passed to chatbot-staff-reply.
async function sendGmaOrderPhoto(orderId, psid, photoUrl, photoStoragePath) {
  const { sent, error } = await sendGmaMessage(psid, '', [{ url: photoUrl, path: null, type: 'image' }]);
  const { error: logError } = await supabaseClient.rpc('admin_record_online_order_status_photo', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_photo_url: photoUrl,
    p_photo_storage_path: photoStoragePath,
    p_sent: sent,
    p_error: error
  });
  if (logError) console.error('Could not log the GMA status photo:', logError.message);
  return { sent, error };
}

// Sends the first-Assigned "in production" message to a GMA Page customer, then logs the outcome so it
// isn't sent twice.
async function sendGmaAssignedMessage(orderId, psid, message) {
  const { sent, error } = await sendGmaMessage(psid, message);
  const { error: logError } = await supabaseClient.rpc('admin_record_online_order_assigned_message', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_sent: sent,
    p_error: error
  });
  if (logError) console.error('Could not log the GMA assigned message:', logError.message);
  return { sent, error };
}

function wireAssignDialog() {
  const allowed = canAssignOrders();
  document.getElementById('listAssignBtn').classList.toggle('hidden', !allowed);
  document.getElementById('cardAssignBtn').classList.toggle('hidden', !allowed);
  if (!allowed) return;

  document.getElementById('listAssignBtn').addEventListener('click', () => selectedOrderId && openAssignDialog(selectedOrderId));
  document.getElementById('cardAssignBtn').addEventListener('click', () => openCardOrderId && openAssignDialog(openCardOrderId));
  document.getElementById('saveAssignDialogBtn').addEventListener('click', saveAssignDialog);
  document.getElementById('cancelAssignDialogBtn').addEventListener('click', closeAssignDialog);
  document.getElementById('closeAssignDialogBtn').addEventListener('click', closeAssignDialog);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !document.getElementById('assignDialog').classList.contains('hidden')) {
      e.stopImmediatePropagation();
      closeAssignDialog();
    }
  }, true);
}

function selectOrderRow(orderId) {
  selectedOrderId = orderId;
  document.querySelectorAll('#orderTableBody tr[data-order-id]').forEach((tr) => {
    tr.classList.toggle('selected', tr.dataset.orderId === String(orderId));
  });
  updateOrderActionState();
}

function wireOrderListActions() {
  const tbody = document.getElementById('orderTableBody');
  tbody.addEventListener('click', (event) => {
    const openLink = event.target.closest('[data-open-order]');
    if (openLink) {
      event.preventDefault();
      selectOrderRow(openLink.dataset.openOrder);
      openOrderCard(openLink.dataset.openOrder);
      return;
    }
    if (event.target.closest('a')) return; // Glass / GMA badge drill-down links keep their own navigation
    const tr = event.target.closest('tr[data-order-id]');
    if (tr) selectOrderRow(tr.dataset.orderId);
  });
  tbody.addEventListener('dblclick', (event) => {
    const tr = event.target.closest('tr[data-order-id]');
    if (tr && !event.target.closest('a')) openOrderCard(tr.dataset.orderId);
  });

  document.getElementById('openOrderBtn').addEventListener('click', () => selectedOrderId && openOrderCard(selectedOrderId));
  document.getElementById('listSendPhotoBtn').addEventListener('click', (e) => selectedOrderId && handleSendPhotoClick(selectedOrderId, e.currentTarget));
  document.getElementById('listSendMessageBtn').addEventListener('click', () => selectedOrderId && openSendMessageModal(selectedOrderId));
  document.getElementById('listToShipBtn').addEventListener('click', (e) => selectedOrderId && handleToShipClick(selectedOrderId, e.currentTarget));
  document.getElementById('listProductionDoneBtn').addEventListener('click', (e) => selectedOrderId && handleProductionDoneClick(selectedOrderId, e.currentTarget));
}

// ---------------------------------------------------------------- Online Order document (card + lines)

const ORDER_CARD_MAXIMIZED_KEY = 'onlineOrderCardMaximized';
let openCardOrderId = null;
let orderCardLoadGeneration = 0;

function readStoredFlag(key, fallback) {
  try {
    const v = localStorage.getItem(key);
    return v === null ? fallback : v === '1';
  } catch (err) {
    return fallback;
  }
}

function writeStoredFlag(key, value) {
  try { localStorage.setItem(key, value ? '1' : '0'); } catch (err) { /* not persisted */ }
}

function applyOrderCardMaximized(maximized) {
  const modal = document.getElementById('orderCardModal');
  modal.classList.toggle('modal-maximized', maximized);
  modal.querySelector('.modal-panel').classList.toggle('modal-maximized', maximized);
  const btn = document.getElementById('orderCardMaximizeBtn');
  btn.textContent = maximized ? 'Restore' : 'Maximize';
  btn.title = maximized ? 'Restore this document to a window' : 'Maximize this document to fill the window';
}

function setCardText(id, value) {
  const el = document.getElementById(id);
  el.textContent = value === null || value === undefined || value === '' ? '-' : value;
}

function fillOrderCardHeader(o) {
  const displayStatus = listDisplayStatus(o);
  document.getElementById('orderCardTitle').textContent = `${o.order_id}${o.customer_name ? ' · ' + o.customer_name : ''}`;
  const badge = document.getElementById('orderCardStatusBadge');
  badge.textContent = displayStatus || '';
  badge.className = 'badge ' + (['Assigned', 'Shipped', 'Completed'].includes(displayStatus) ? 'badge-success' : displayStatus === 'Cancelled' ? 'badge-danger' : 'badge-neutral');
  document.getElementById('orderCardBadges').innerHTML = orderBadgesHtml(o);

  setCardText('ocOrderId', o.order_id);
  setCardText('ocCustomer', [o.customer_name, o.walkin_customer_phone].filter(Boolean).join(' · '));
  setCardText('ocOrderDate', [o.order_date, o.order_time].filter(Boolean).join(' '));
  // Walk-in picked up: when and by whom (portal only).
  setCardText('ocStatus', o.walkin_stage === 'Completed' && o.picked_up_at
    ? `${displayStatus} · picked up ${new Date(o.picked_up_at).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}${o.picked_up_by_name ? ' by ' + o.picked_up_by_name : ''}`
    : displayStatus);

  // Walk-in customer name / contact no. - editable by staff (not maker-only accounts), any walk-in.
  const walkinRow = document.getElementById('ocWalkinCustomerRow');
  walkinRow.classList.toggle('hidden', !o.received_at_shop || myAssignmentsLocked);
  if (o.received_at_shop && !myAssignmentsLocked && walkinRow.dataset.orderId !== String(o.order_id)) {
    walkinRow.dataset.orderId = String(o.order_id);
    document.getElementById('ocWalkinName').value = o.walkin_customer_name || '';
    document.getElementById('ocWalkinPhone').value = o.walkin_customer_phone || '';
  }
  setCardText('ocWarehouse', o.warehouse_name || o.location_id);
  setCardText('ocConfirmedBy', o.confirmed_by);
  setCardText('ocCreatedBy', o.created_by);
  setCardText('ocLastUpdated', o.last_updated_at ? new Date(o.last_updated_at).toLocaleString() : '');
  setCardText('ocForDelivery', o.for_delivery ? 'Yes' : 'No');
  setCardText('ocEstDelivery', o.estimated_delivery_date);
  setCardText('ocDeliveryFee', o.delivery_fee ? Number(o.delivery_fee).toFixed(2) : '');
  setCardText('ocPrintNote', o.note_print);
  document.getElementById('ocDeliveryFeeRow').classList.toggle('hidden', hidePrices());

  // Payment FastTab - same Pancake-synced amounts as the Excel export's Money To Collect /
  // Amount Paid / Discount / Balance columns.
  document.getElementById('orderCardPaymentTab').classList.toggle('hidden', hidePrices());
  setCardText('ocMoneyToCollect', money(o.money_to_collect));
  setCardText('ocDiscount', money(o.discount));
  setCardText('ocAmountPaid', money(o.amount_paid));
  setCardText('ocBalance', money(o.balance));
  const balance = Number(o.balance) || 0;
  document.getElementById('ocBalance').classList.toggle('oc-balance-due', balance > 0);
  document.getElementById('orderCardPaymentSummary').textContent =
    balance > 0 ? `Balance ${money(balance)}` : (o.balance === null || o.balance === undefined ? '' : 'Paid in full');

  document.getElementById('orderCardGeneralSummary').textContent =
    [o.customer_name, displayStatus, o.warehouse_name || o.location_id].filter(Boolean).join(' · ');
  document.getElementById('orderCardDeliverySummary').textContent =
    o.for_delivery ? `For delivery${o.estimated_delivery_date ? ' · ' + o.estimated_delivery_date : ''}` : 'Pickup';

  document.getElementById('cardToShipBtn').disabled = !isPrintedOrder(o);
  updateProductionDoneButton('cardProductionDoneBtn', o);
  fillMakerFocusSummary(o);
  updateSendBackButton('cardSendBackBtn', o);
  updateNextStepButton('cardNextStepBtn', o);
  ensureStockStatus(o);
  renderOrderCardAssignments();
}

function renderOrderCardAssignments() {
  const o = findFlatOrder(openCardOrderId);
  if (!o) return;
  document.getElementById('ocTankMakerRow').classList.toggle('hidden', !o.has_aquarium_line);
  document.getElementById('ocStandMakerRow').classList.toggle('hidden', !o.has_stand_line);
  document.getElementById('ocTankMaker').innerHTML = o.has_aquarium_line ? makerSelectHtml(o, 'tank', o.assigned_tank_maker) + productionDoneTickHtml(o, 'tank') : '';
  document.getElementById('ocStandMaker').innerHTML = o.has_stand_line ? makerSelectHtml(o, 'stand', o.assigned_stand_maker) + productionDoneTickHtml(o, 'stand') : '';
  // Not assigned any more - recorded when the order is marked Shipped.
  document.getElementById('ocDispatcher').innerHTML = o.assigned_dispatcher
    ? escapeHtml(o.assigned_dispatcher_name || o.assigned_dispatcher)
    : '<span class="muted">Recorded when shipped</span>';

  const parts = [];
  if (o.has_aquarium_line) parts.push(`Tank: ${o.assigned_tank_maker_name || o.assigned_tank_maker || '-'}`);
  if (o.has_stand_line) parts.push(`Stand: ${o.assigned_stand_maker_name || o.assigned_stand_maker || '-'}`);
  parts.push(`Dispatcher: ${o.assigned_dispatcher_name || o.assigned_dispatcher || '-'}`);
  if (reworkNoteText(o)) parts.push(`Rework - ${reworkNoteText(o)}`);
  document.getElementById('orderCardAssignSummary').textContent = parts.join(' · ');
}

// After a list reload (e.g. an assignment saved on the card, or a status change from its action
// bar), re-read the open card's header from the fresh row and its sent photos - the lines don't change, so no re-fetch.
function refreshOpenOrderCardHeader() {
  if (!openCardOrderId || document.getElementById('orderCardModal').classList.contains('hidden')) return;
  const o = findFlatOrder(openCardOrderId);
  if (o) fillOrderCardHeader(o);
  loadOrderCardStatusPhotos(openCardOrderId); // e.g. a photo just sent with Send Photo from the card
}

function money(value) {
  return value === null || value === undefined || value === '' ? '' : Number(value).toFixed(2);
}

// Lines + per-line attachments + sent photos for the open document. Same RPCs as
// online-order-lines.html (js/onlineOrderLines.js) - attachments are an RS Pet Stop-side addition
// stored in public."OnlineOrderLineAttachments" and joined in by line_id, uploaded through a
// signed upload URL minted server-side (supabase_online_order_line_attachments.sql).
const CARD_ATTACHMENTS_BUCKET = 'online-order-line-attachments';
const CARD_MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
let cardLines = [];
let cardAttachmentsByLineId = {};
let cardPendingUploadLineId = null;

function isImageFileName(name) {
  return /\.(png|jpe?g|gif|webp)$/i.test(name || '');
}

// Pancake doesn't always send net_amount - fall back to gross, then price x qty - discount, so the
// Line Amount column is never blank for a priced line.
function lineAmount(l) {
  if (l.net_amount !== null && l.net_amount !== undefined && l.net_amount !== '') return Number(l.net_amount);
  if (l.gross_amount !== null && l.gross_amount !== undefined && l.gross_amount !== '') return Number(l.gross_amount) - (Number(l.discount) || 0);
  if (l.price === null || l.price === undefined || l.price === '') return null;
  return (Number(l.price) || 0) * (Number(l.quantity) || 0) - (Number(l.discount) || 0);
}

function cardAttachmentCellHtml(lineId) {
  if (!lineId) return '<span class="muted">No line ID</span>';
  const chips = (cardAttachmentsByLineId[lineId] || []).map((a) => {
    const label = escapeHtml(a.file_name || 'attachment');
    const link = isImageFileName(a.file_name)
      ? `<a href="${escapeHtml(a.public_url)}" target="_blank" rel="noopener" title="${label}"><img src="${escapeHtml(a.public_url)}" class="attachment-thumb" alt="${label}" /></a>`
      : `<a href="${escapeHtml(a.public_url)}" target="_blank" rel="noopener" class="attachment-file-chip">&#128206; ${label}</a>`;
    return `<span class="attachment-chip">${link}<button type="button" class="attachment-remove-btn" data-attachment-id="${escapeHtml(a.attachment_id)}" title="Remove attachment">&times;</button></span>`;
  }).join('');
  return `<div class="attachment-cell">${chips}<button type="button" class="bc-link card-attach-btn" data-line-id="${escapeHtml(lineId)}">+ Attach</button></div>`;
}

// ---------------------------------------------------------------- Maker focus
// Per "for the maker view in the mobile.. can you show him only the details of the order lines..
// this way the maker can focus on the order details" - a maker-only account (myAssignmentsLocked)
// opens an order as just: a short summary (due date, their part, rework note), the lines as cards
// (item, quantity, spec note, attachments) and the glass cut. Everything else on the document
// (General, Assignment, Delivery, Payment, Photos Sent, Rework History, most actions) is hidden by
// #orderCardModal.maker-focus in css/bc-list.css.
// Per "check on the dispatcher side.. dont show the amount, i want the same view for the maker too..
// dont give too much info": anyone working from My Assignments who isn't a Super User / Production
// Manager (e.g. a Store Manager who is also a Dispatcher) gets the same stripped view, not just
// maker-only accounts.
function isMakerFocus() {
  return myAssignmentsLocked || (myAssignmentsOnly && !!currentSession?.isOrderMaker
    && !currentSession.isSuperUser && !currentSession.isProductionManager);
}

// No amounts for price-hidden roles, nor for anyone in the maker focus view.
function hidePrices() {
  return hidePriceColumns || isMakerFocus();
}

function renderOrderCardLineCards() {
  const box = document.getElementById('orderCardLineCards');
  if (!box) return;
  if (!isMakerFocus()) { box.innerHTML = ''; return; }
  // Per "I want the maker to see the item / description / SKU / quantity": the Pancake line name is
  // the Item, its spec note the Description.
  box.innerHTML = cardLines.map((l) => makerLineCardHtml({
    item: l.description || l.item_code,
    description: l.note,
    sku: lineSku(l),
    qty: l.quantity ?? '',
    extra: `<div class="oc-lc-attach">${cardAttachmentCellHtml(l.line_id)}</div>`
  })).join('') || '<div class="oo-mc-empty">No line items found for this order.</div>';
}

// One line for a maker: Item + big Qty, then labelled Description / SKU (shared by the online order
// card and the Production Order card).
function makerLineCardHtml({ item, description, sku, qty, tag = '', extra = '' }) {
  return `
    <article class="oc-line-card">
      <div class="oc-lc-head">
        <div class="oc-lc-desc"><span class="oc-lc-label">Item</span>${escapeHtml(item || '-')} ${tag}</div>
        <div class="oc-lc-qty" title="Quantity">x${escapeHtml(String(qty))}</div>
      </div>
      <div class="oc-lc-row"><span class="oc-lc-label">Description</span>${description ? `<div class="oc-lc-note">${escapeHtml(description)}</div>` : '<div class="oc-lc-none">-</div>'}</div>
      <div class="oc-lc-row"><span class="oc-lc-label">SKU</span><div class="oc-lc-code">${escapeHtml(sku || '-')}</div></div>
      ${extra}
    </article>`;
}

function fillMakerFocusSummary(o) {
  const box = document.getElementById('ocMakerSummary');
  box.classList.toggle('hidden', !isMakerFocus());
  if (!isMakerFocus()) return;
  const mine = myProductionRoles(o).map((r) => MAKER_ROLES[r].label);
  box.innerHTML = `
    <div class="oc-ms-row"><span>Customer</span>${escapeHtml(o.customer_name || '-')}</div>
    <div class="oc-ms-row"><span>Est. Delivery</span>${etaHtml(o.estimated_delivery_date)}</div>
    <div class="oc-ms-row"><span>Handover</span>${o.for_delivery ? 'Delivery' : 'Pickup'}</div>
    <div class="oc-ms-row"><span>Your part</span>${escapeHtml(mine.join(' + ') || 'Dispatcher')}</div>
    ${o.note_print ? `<div class="oo-mc-note">${escapeHtml(o.note_print)}</div>` : ''}
    ${reworkNoteText(o) ? `<div class="oo-mc-rework"><b>Sent back for rework</b> ${escapeHtml(reworkNoteText(o))}</div>` : ''}`;
}

// Variant SKU -> item SKU -> Item Code (admin_get_online_order_detail_live's sku,
// supabase_online_order_lines_sku.sql); Item Code until that's run.
function lineSku(l) {
  return l.sku || l.item_code || l.product_display_id || '';
}

function renderOrderCardLines() {
  const tbody = document.getElementById('orderCardLinesBody');
  const tfoot = document.getElementById('orderCardLinesFoot');
  if (!cardLines.length) {
    tbody.innerHTML = '<tr><td colspan="9" class="cell-msg">No line items found for this order.</td></tr>';
    tfoot.innerHTML = '';
    return;
  }

  const priceCell = (v) => (hidePrices() ? '' : `<td class="num">${money(v)}</td>`);
  tbody.innerHTML = cardLines.map((l) => `
    <tr>
      <td>${escapeHtml(l.item_code || l.product_display_id)}</td>
      <td><b>${escapeHtml(lineSku(l))}</b></td>
      <td style="white-space:normal;">${escapeHtml(l.description)}</td>
      <td class="num">${l.quantity ?? ''}</td>
      ${priceCell(l.price)}
      ${priceCell(l.discount)}
      ${priceCell(lineAmount(l))}
      <td style="white-space:normal;">${escapeHtml(l.note)}</td>
      <td style="white-space:normal;">${cardAttachmentCellHtml(l.line_id)}</td>
    </tr>`).join('');

  renderOrderCardLineCards();

  const totalQty = cardLines.reduce((sum, l) => sum + (Number(l.quantity) || 0), 0);
  const totalNet = cardLines.reduce((sum, l) => sum + (lineAmount(l) || 0), 0);
  tfoot.innerHTML = `<tr>
    <td>Total</td><td></td><td></td><td class="num">${totalQty}</td>
    ${hidePrices() ? '' : `<td></td><td></td><td class="num">${money(totalNet)}</td>`}
    <td></td><td></td></tr>`;
}

async function loadOrderCardLines(orderId) {
  const myGeneration = ++orderCardLoadGeneration;
  const tbody = document.getElementById('orderCardLinesBody');
  cardLines = [];
  cardAttachmentsByLineId = {};
  tbody.innerHTML = '<tr><td colspan="9" class="cell-msg">Loading lines from Pancake...</td></tr>';
  document.getElementById('orderCardLinesFoot').innerHTML = '';
  document.getElementById('orderCardPhotosPart').classList.add('hidden');
  cardGlassTanks = [];
  document.getElementById('orderCardGlassTab').classList.add('hidden');
  renderPosDescription(null);

  const [linesRes] = await Promise.all([
    supabaseClient.rpc('admin_get_online_order_detail_live', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId
    }),
    loadOrderCardAttachments(orderId, false),
    loadOrderCardStatusPhotos(orderId)
  ]);
  if (myGeneration !== orderCardLoadGeneration) return;

  if (linesRes.error) {
    // Usually Pancake's live API being slow for a moment, not a session problem - offer a retry.
    tbody.innerHTML = `<tr><td colspan="9" class="cell-msg error-text">Could not load lines: ${escapeHtml(linesRes.error.message)}
      <button type="button" class="bc-link" id="retryOrderCardLinesBtn" style="margin-left:8px;">Retry</button></td></tr>`;
    document.getElementById('retryOrderCardLinesBtn').addEventListener('click', () => loadOrderCardLines(orderId));
    return;
  }

  cardLines = (linesRes.data || []).filter((l) => l.line_id || l.item_code || l.description);
  renderPosDescription(findFlatOrder(orderId), linesRes.data?.[0]?.order_note || findFlatOrder(orderId)?.pos_note);
  renderOrderCardLines();
  loadOrderCardGlassTanks();
}

// Walk-in POS description - per "in the walk-in orders can you sync over the descriptions from local
// pos to the portal". The POS sends the receipt's description as the Pancake order note
// (CreateInstoreOnlineOrder, OnlinefunctionsEvents.cs):
//   "<ReceiptNo> - Customer: X | Order: <description> | Details: a || b | Cashier: Y | POS Discount: n"
// Split into labelled rows; money parts are dropped for accounts that don't see prices.
const POS_DESC_MONEY_KEYS = ['pos discount', 'cardfee', 'discount type'];
// Online (non walk-in) orders can come from the local POS too - per "in the online orders can we show
// the POS Description too". Those are recognised by the POS note shape (receipt no. + "Customer:" /
// "Cashier:" parts), so a hand-typed Pancake note on a regular online order isn't shown as one.
function isPosNote(note) {
  const text = String(note || '').trim();
  return /^\S+\s+-\s+Customer:/i.test(text) || /\|\s*Cashier:/i.test(text);
}
function parsePosDescription(note) {
  const rows = [];
  String(note || '').split(/\s\|\s/).forEach((part, i) => {
    let text = part.trim();
    if (!text) return;
    if (i === 0) {
      const receipt = text.match(/^(\S+)\s+-\s+(.*)$/);
      if (receipt) { rows.push({ label: 'Receipt', value: receipt[1] }); text = receipt[2].trim(); }
    }
    const kv = text.match(/^([A-Za-z][A-Za-z ]{0,20}):\s*(.*)$/);
    if (!kv) { rows.push({ label: '', value: text }); return; }
    const key = kv[1].trim();
    if (hidePrices() && POS_DESC_MONEY_KEYS.includes(key.toLowerCase())) return;
    if (!kv[2].trim()) return;
    rows.push({ label: key === 'Order' ? 'Description' : key, value: kv[2].trim() });
  });
  return rows;
}

function renderPosDescription(o, note) {
  const box = document.getElementById('ocPosDescription');
  const rows = o && (o.received_at_shop || isPosNote(note)) ? parsePosDescription(note) : [];
  box.classList.toggle('hidden', !rows.length);
  if (!rows.length) { box.innerHTML = ''; return; }
  box.innerHTML = `<div class="oc-pos-desc-head">POS Description</div>` + rows.map((r) => {
    // Details lists the sold items, separated by "||" - one per line.
    const value = r.label === 'Details'
      ? r.value.split(/\s*\|\|\s*/).filter(Boolean).map((d) => `<div>${escapeHtml(d)}</div>`).join('')
      : escapeHtml(r.value);
    return `<div class="oc-pos-desc-row"><span>${escapeHtml(r.label)}</span><div>${value}</div></div>`;
  }).join('');
}

// ---------------------------------------------------------------------------
// Glass Cut section - per "where is the glass cut sitting again? can we add it on the online
// order?" / "my goal is to see the glass cut then directly order the glass to the supplier as PO".
// Before this the cut list only lived on glass-cut-list.html, reachable from the 10mm/12mm badge.
// Now every custom aquarium line (any thickness) gets its cut list drawn right on the card, and
// Create Purchase Order hands ALL of them to the New PO as one note listing every cut size.
//
// "Custom aquarium line" uses the same custom + aquarium text match as the SQL production roles
// (_online_order_production_roles in supabase_online_order_production_done.sql). Tank dimensions
// come from the line's spec note, same parse as glass-cut-list.html (GlassCutList.parseAquariumLineSpec).
const OC_GLASS_OPTIONS = ['3mm', '5mm', '6mm', '8mm', '10mm', '12mm', '15mm', '19mm'];
const OC_GLASS_SHEET_KEY = 'onlineOrders.glassSheetSize';
let cardGlassTanks = [];

function isCustomAquariumLine(l) {
  const text = `${l.description || ''} ${l.item_code || ''} ${l.product_display_id || ''}`;
  return /custom/i.test(text) && /aquarium/i.test(`${l.description || ''} ${l.item_code || ''}`);
}

function lineGlassSpec(l) {
  return GlassCutList.parseAquariumLineSpec(l.note || '') ||
    GlassCutList.parseAquariumLineSpec(`${l.description || ''} ${l.item_code || ''}`);
}

// Per "can you show this too in the 12mm and 10mm glass": a 10mm / 12mm tank line (e.g.
// "STANDARD-150G (60×24×24in, 12MM GLASS)") gets a cut list without being custom - when the line
// says 10mm/12mm (or the order has the 10mm/12mm badge), it reads as a tank size, and it isn't a
// stand / top cover.
function isThickGlassTankLine(l, order) {
  const text = `${l.description || ''} ${l.note || ''} ${l.item_code || ''} ${l.product_display_id || ''}`;
  if (/(stand(?!ard)|top[\s_-]*cover)/i.test(`${l.description || ''} ${l.item_code || ''}`)) return false;
  const thick = /(10|12)mm/i.test(text.replace(/\s+/g, ''))
    || /^(10|12)mm$/i.test(String(order?.glass_thickness || '').replace(/\s+/g, ''));
  return thick && !!lineGlassSpec(l);
}

function loadOrderCardGlassTanks() {
  const order = findFlatOrder(openCardOrderId);
  cardGlassTanks = cardLines.filter((l) => isCustomAquariumLine(l) || isThickGlassTankLine(l, order)).map((line) => {
    const spec = lineGlassSpec(line);
    // Falls back to the order's flagged thickness (the 10mm/12mm badge) when the note doesn't say.
    const glass = (spec && spec.glass) || findFlatOrder(openCardOrderId)?.glass_thickness || '10mm';
    return { line, spec, glass: String(glass).toLowerCase().replace(/\s+/g, '') };
  });
  renderOrderCardGlassCut();
}

function ocGlassSheetSize() {
  return {
    sheetWidth: Number(document.getElementById('ocGlassSheetW').value) || 0,
    sheetHeight: Number(document.getElementById('ocGlassSheetH').value) || 0
  };
}

function ocGlassTankOptions(tank) {
  return {
    length: tank.spec.length,
    width: tank.spec.width,
    height: tank.spec.height,
    glass: tank.glass,
    quantity: Number(tank.line.quantity) || 1,
    ...ocGlassSheetSize()
  };
}

function renderOrderCardGlassCut() {
  const tab = document.getElementById('orderCardGlassTab');
  tab.classList.toggle('hidden', cardGlassTanks.length === 0);
  if (cardGlassTanks.length === 0) return;

  const f = GlassCutList.formatInches;
  const orderId = openCardOrderId;
  const canPo = typeof canOpenPortalPage !== 'function' || canOpenPortalPage(currentSession, 'purchase-orders.html');
  const canFull = typeof canOpenPortalPage !== 'function' || canOpenPortalPage(currentSession, 'glass-cut-list.html');
  document.getElementById('ocGlassPoBtn').classList.toggle('hidden', !canPo);
  const fullLink = document.getElementById('ocGlassFullLink');
  fullLink.classList.toggle('hidden', !canFull);
  fullLink.href = `glass-cut-list.html?order=${encodeURIComponent(orderId)}`;

  let totalSheets = 0;
  let blocked = false;
  document.getElementById('ocGlassTanks').innerHTML = cardGlassTanks.map((tank, i) => {
    const title = escapeHtml(tank.line.note || tank.line.description || tank.line.item_code || `Line ${i + 1}`);
    if (!tank.spec) {
      blocked = true;
      return `<div class="oc-glass-tank"><div class="oc-glass-tank-head"><strong>${title}</strong></div>
        <p class="muted" style="margin:0;">Couldn't read the tank size from this line's note${canFull ? ' - use Open Full Cut List to enter it by hand' : ''}.</p></div>`;
    }

    const glassOptions = OC_GLASS_OPTIONS.includes(tank.glass) ? OC_GLASS_OPTIONS : [tank.glass, ...OC_GLASS_OPTIONS];
    const opts = ocGlassTankOptions(tank);
    const result = GlassCutList.buildCutList(opts);
    totalSheets += result.sheets.length;
    const qtyNote = opts.quantity > 1 ? ` &middot; ${opts.quantity} tanks` : '';
    const head = `<div class="oc-glass-tank-head">
        <strong>${title}</strong>
        <span class="muted">Tank ${f(opts.length)}" x ${f(opts.width)}" x ${f(opts.height)}"${qtyNote}</span>
        <select class="oc-glass-thickness" data-tank-index="${i}" title="Glass thickness">
          ${glassOptions.map((g) => `<option value="${escapeHtml(g)}"${g === tank.glass ? ' selected' : ''}>${escapeHtml(g)}</option>`).join('')}
        </select>
      </div>`;
    const panels = `<table class="oc-glass-panels"><thead><tr><th>Panel</th><th>Cut size</th><th>Qty</th></tr></thead><tbody>
        ${result.panels.map((p) => `<tr><td>${escapeHtml(p.name)}</td><td><strong>${f(p.width)}" x ${f(p.height)}"</strong></td><td>${p.qty}</td></tr>`).join('')}
      </tbody></table>`;

    if (result.oversized.length > 0) {
      blocked = true;
      return `<div class="oc-glass-tank">${head}${panels}<p class="error-text" style="margin:0;">These panels don't fit a ${f(opts.sheetWidth)}" x ${f(opts.sheetHeight)}" sheet even rotated: ${escapeHtml(result.oversized.map((p) => p.label).join(', '))}. Use a bigger stock sheet size above.</p></div>`;
    }

    const sheets = result.sheets.map((sheet, s) =>
      GlassCutList.renderSheetSvg(sheet, { caption: `Sheet ${s + 1} of ${result.sheets.length} - ${opts.glass}` })
    ).join('');
    return `<div class="oc-glass-tank">${head}${panels}<div class="oc-glass-sheets">${sheets}</div></div>`;
  }).join('');

  const poBtn = document.getElementById('ocGlassPoBtn');
  poBtn.disabled = blocked;
  poBtn.title = blocked ? 'Fix the tank(s) above first - one has no readable size or doesn\'t fit the stock sheet.' : 'Open a New Purchase Order with every cut size above in its Notes';
  document.getElementById('orderCardGlassSummary').textContent =
    `${cardGlassTanks.length} custom aquarium line(s) · ${totalSheets} stock sheet(s)`;
}

// Same sessionStorage handoff as glass-cut-list.html's Create Purchase Order button -
// purchase-orders.html opens the New PO with this in Notes. Vendor / glass item / warehouse are
// still picked there, as on the full page.
function handleOrderCardGlassPo() {
  const tanks = cardGlassTanks.filter((t) => t.spec).map((tank) => {
    const options = ocGlassTankOptions(tank);
    return { options, result: GlassCutList.buildCutList(options) };
  });
  if (tanks.length === 0) return;
  sessionStorage.setItem('pendingGlassPoNotes', GlassCutList.buildPoNotes(openCardOrderId, tanks));
  window.location.href = 'purchase-orders.html';
}

function wireOrderCardGlassCut() {
  // Stock sheet size is remembered per browser - it's the supplier's sheet, not per order.
  try {
    const saved = JSON.parse(localStorage.getItem(OC_GLASS_SHEET_KEY) || 'null');
    if (saved && saved.w > 0 && saved.h > 0) {
      document.getElementById('ocGlassSheetW').value = saved.w;
      document.getElementById('ocGlassSheetH').value = saved.h;
    }
  } catch (e) { /* storage unavailable - keep the defaults */ }

  ['ocGlassSheetW', 'ocGlassSheetH'].forEach((id) => document.getElementById(id).addEventListener('input', () => {
    const { sheetWidth, sheetHeight } = ocGlassSheetSize();
    try { localStorage.setItem(OC_GLASS_SHEET_KEY, JSON.stringify({ w: sheetWidth, h: sheetHeight })); } catch (e) { /* ignore */ }
    renderOrderCardGlassCut();
  }));
  document.getElementById('ocGlassTanks').addEventListener('change', (event) => {
    const select = event.target.closest('.oc-glass-thickness');
    if (!select) return;
    cardGlassTanks[Number(select.dataset.tankIndex)].glass = select.value;
    renderOrderCardGlassCut();
  });
  document.getElementById('ocGlassPoBtn').addEventListener('click', handleOrderCardGlassPo);
}

async function loadOrderCardAttachments(orderId, rerender = true) {
  const { data, error } = await supabaseClient.rpc('admin_list_online_order_line_attachments', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });
  if (String(orderId) !== String(openCardOrderId)) return;
  cardAttachmentsByLineId = {};
  (error ? [] : data || []).forEach((a) => {
    (cardAttachmentsByLineId[a.line_id] = cardAttachmentsByLineId[a.line_id] || []).push(a);
  });
  if (rerender && cardLines.length) renderOrderCardLines();
}

async function uploadOrderCardAttachment(orderId, lineId, file, triggerEl) {
  if (file.size > CARD_MAX_ATTACHMENT_BYTES) {
    alert('That file is too large - max 10 MB.');
    return;
  }
  if (triggerEl) { triggerEl.disabled = true; triggerEl.textContent = 'Uploading...'; }

  try {
    const { data: uploadRows, error: signError } = await supabaseClient.rpc('admin_create_online_order_line_attachment_upload', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId,
      p_line_id: lineId,
      p_file_name: file.name
    });
    const uploadInfo = uploadRows && uploadRows[0];
    if (signError || !uploadInfo) {
      alert(`Could not start upload: ${signError ? signError.message : 'unknown error'}`);
      return;
    }

    const { error: uploadError } = await supabaseClient.storage
      .from(CARD_ATTACHMENTS_BUCKET)
      .uploadToSignedUrl(uploadInfo.storage_path, uploadInfo.upload_token, file);
    if (uploadError) {
      alert(`Upload failed: ${uploadError.message}`);
      return;
    }

    const { error: recordError } = await supabaseClient.rpc('admin_record_online_order_line_attachment', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_order_id: orderId,
      p_line_id: lineId,
      p_file_name: file.name,
      p_storage_path: uploadInfo.storage_path,
      p_public_url: uploadInfo.public_url
    });
    if (recordError) {
      alert(`File uploaded, but could not save it against this line: ${recordError.message}`);
      return;
    }
  } finally {
    if (triggerEl && triggerEl.isConnected) { triggerEl.disabled = false; triggerEl.textContent = '+ Attach'; }
  }

  await loadOrderCardAttachments(orderId);
}

async function removeOrderCardAttachment(attachmentId) {
  if (!confirm('Remove this attachment?')) return;
  const { error } = await supabaseClient.rpc('admin_delete_online_order_line_attachment', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_attachment_id: attachmentId
  });
  if (error) {
    alert(`Could not remove attachment: ${error.message}`);
    return;
  }
  if (openCardOrderId) await loadOrderCardAttachments(openCardOrderId);
}

function cardStatusPhotoHtml(p) {
  const takenAt = p.uploaded_at_utc ? new Date(p.uploaded_at_utc).toLocaleString() : '';
  return `
    <div class="status-photo-card" data-photo-id="${escapeHtml(p.photo_id)}">
      <a href="${escapeHtml(p.public_url)}" target="_blank" rel="noopener">
        <img src="${escapeHtml(p.public_url)}" class="status-photo-thumb" alt="Status update photo" />
      </a>
      <button type="button" class="status-photo-remove-btn" data-photo-id="${escapeHtml(p.photo_id)}" title="Remove photo">&times;</button>
      <div class="status-photo-meta">
        <div>${escapeHtml(p.status)} - ${takenAt}</div>
        <div class="${p.sent_to_customer ? '' : 'error-text'}" title="${escapeHtml(p.send_error)}">${p.sent_to_customer ? 'Sent to customer' : 'Not sent to customer'}</div>
        <div class="muted">by ${escapeHtml(p.uploaded_by)}</div>
      </div>
    </div>`;
}

async function loadOrderCardStatusPhotos(orderId) {
  const { data, error } = await supabaseClient.rpc('admin_list_online_order_status_photos', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });
  if (String(orderId) !== String(openCardOrderId)) return;
  const part = document.getElementById('orderCardPhotosPart');
  if (error || !data || !data.length) {
    part.classList.add('hidden');
    return;
  }
  document.getElementById('orderCardPhotosList').innerHTML = data.map(cardStatusPhotoHtml).join('');
  part.classList.remove('hidden');
}

async function removeOrderCardStatusPhoto(photoId) {
  if (!confirm('Remove this photo? This cannot be undone.')) return;
  const { error } = await supabaseClient.rpc('admin_delete_online_order_status_photo', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_photo_id: photoId
  });
  if (error) {
    alert(`Could not remove photo: ${error.message}`);
    return;
  }
  if (openCardOrderId) await loadOrderCardStatusPhotos(openCardOrderId);
}

function wireOrderCardAttachments() {
  const fileInput = document.getElementById('cardAttachmentFileInput');
  let pendingTrigger = null;

  const onLinesClick = (event) => {
    const attachBtn = event.target.closest('.card-attach-btn');
    if (attachBtn) {
      cardPendingUploadLineId = attachBtn.dataset.lineId;
      pendingTrigger = attachBtn;
      fileInput.click();
      return;
    }
    const removeBtn = event.target.closest('.attachment-remove-btn');
    if (removeBtn) removeOrderCardAttachment(removeBtn.dataset.attachmentId);
  };
  document.getElementById('orderCardLinesBody').addEventListener('click', onLinesClick);
  document.getElementById('orderCardLineCards').addEventListener('click', onLinesClick);

  fileInput.addEventListener('change', async (event) => {
    const file = event.target.files && event.target.files[0];
    event.target.value = ''; // allow re-selecting the same file later
    const lineId = cardPendingUploadLineId;
    cardPendingUploadLineId = null;
    if (!file || !lineId || !openCardOrderId) return;
    await uploadOrderCardAttachment(openCardOrderId, lineId, file, pendingTrigger);
  });

  document.getElementById('orderCardPhotosList').addEventListener('click', (event) => {
    const removeBtn = event.target.closest('.status-photo-remove-btn');
    if (removeBtn) removeOrderCardStatusPhoto(removeBtn.dataset.photoId);
  });
}

function openOrderCard(orderId) {
  const o = findFlatOrder(orderId);
  if (!o) return;
  openCardOrderId = String(o.order_id);
  document.getElementById('orderCardModal').classList.toggle('maker-focus', isMakerFocus());
  // Makers can't change the glass stock sheet size - it's set by the Production Manager / office.
  ['ocGlassSheetW', 'ocGlassSheetH'].forEach((id) => {
    const input = document.getElementById(id);
    input.readOnly = isMakerFocus();
    input.title = isMakerFocus() ? 'Stock sheet size is set by the Production Manager' : '';
  });
  document.querySelectorAll('#orderCardModal .oc-price').forEach((th) => th.classList.toggle('hidden', hidePrices()));
  fillOrderCardHeader(o);
  document.getElementById('orderCardModal').classList.remove('hidden');
  loadOrderCardLines(openCardOrderId);
  if (!hidePrices()) loadOrderCardPaymentMethods(openCardOrderId);
  loadOrderCardReworkHistory(openCardOrderId);
  loadOrderCardReleaseHistory(openCardOrderId);
}

// Payment FastTab's "Paid Via": which method(s) the Amount Paid came in through (Cash, GCASH, BDO...),
// read live from the Pancake order's cash + bank_payments (supabase_online_order_payment_methods.sql).
async function loadOrderCardPaymentMethods(orderId) {
  const el = document.getElementById('ocPaidVia');
  el.textContent = 'Loading...';
  const { data, error } = await supabaseClient.rpc('admin_get_online_order_payment_methods', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });
  if (openCardOrderId !== String(orderId)) return;
  if (error) {
    el.textContent = 'Could not load from Pancake';
    return;
  }
  const rows = data || [];
  if (!rows.length) {
    el.textContent = Number(findFlatOrder(orderId)?.amount_paid) > 0 ? 'Not recorded in Pancake' : 'No payment yet';
    return;
  }
  // method is the Payment Methods name (supabase_payment_methods_master.sql), or "Unnamed (cbe9ddfa)"
  // until a super user names that Pancake ID on payment-methods.html.
  el.innerHTML = rows.map((r) => `<div title="${escapeHtml(r.code || '')}">${escapeHtml(r.method)}: ${money(r.amount)}</div>`).join('');
}

function closeOrderCard() {
  openCardOrderId = null;
  orderCardLoadGeneration++;
  document.getElementById('orderCardModal').classList.add('hidden');
  delete document.getElementById('ocWalkinCustomerRow').dataset.orderId; // refill the walk-in fields next open
}

function wireOrderCard() {
  applyOrderCardMaximized(readStoredFlag(ORDER_CARD_MAXIMIZED_KEY, false));
  document.getElementById('orderCardMaximizeBtn').addEventListener('click', () => {
    const next = !document.getElementById('orderCardModal').classList.contains('modal-maximized');
    writeStoredFlag(ORDER_CARD_MAXIMIZED_KEY, next);
    applyOrderCardMaximized(next);
  });
  document.getElementById('closeOrderCardBtn').addEventListener('click', closeOrderCard);
  wireOrderCardGlassCut();
  document.getElementById('orderCardModal').addEventListener('change', handleAssignProductionMemberChange);
  document.getElementById('cardSendPhotoBtn').addEventListener('click', (e) => openCardOrderId && handleSendPhotoClick(openCardOrderId, e.currentTarget));
  document.getElementById('cardSendMessageBtn').addEventListener('click', () => openCardOrderId && openSendMessageModal(openCardOrderId));
  document.getElementById('cardToShipBtn').addEventListener('click', (e) => openCardOrderId && handleToShipClick(openCardOrderId, e.currentTarget));
  document.getElementById('cardProductionDoneBtn').addEventListener('click', (e) => openCardOrderId && handleProductionDoneClick(openCardOrderId, e.currentTarget));
  document.getElementById('cardPrintSerialsBtn').addEventListener('click', (e) => openCardOrderId && printOrderSerialLabels(openCardOrderId, e.currentTarget));
  document.getElementById('ocWalkinSaveBtn').addEventListener('click', saveWalkinCustomer);
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || document.getElementById('orderCardModal').classList.contains('hidden')) return;
    // Only when no dialog launched from the card is open on top of it.
    const stacked = ['shipSerialModal', 'viewSerialsModal', 'sendOrderMessageModal', 'assignDialog', 'sendBackDialog', 'confirmActionDialog']
      .some((id) => !document.getElementById(id).classList.contains('hidden'));
    if (!stacked) closeOrderCard();
  });
}

// Assigned Dispatcher isn't part of admin_list_online_orders' result - it's looked up for just the
// orders on screen via staff_get_online_order_assignments (supabase_online_order_dispatcher.sql)
// and merged onto each row before rendering. A failed lookup only leaves the dropdowns blank.
async function attachDispatchers(rows) {
  if (!rows.length) return;
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_assignments', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_ids: rows.map((o) => String(o.order_id))
  });
  if (error) {
    console.error('staff_get_online_order_assignments failed:', error);
    return;
  }
  const byOrder = new Map((data || []).map((a) => [String(a.order_id), a]));
  rows.forEach((o) => {
    const a = byOrder.get(String(o.order_id));
    o.assigned_dispatcher = a?.assigned_dispatcher || null;
    o.assigned_dispatcher_name = a?.assigned_dispatcher_name || null;
  });
}

// Walk-in POS description (OnlineOrders."Note", saved by the /orders cron sync -
// sql/supabase_walkin_order_pos_note.sql) for the rows on screen - walk-ins, plus online orders
// whose note is a POS receipt note (isPosNote).
async function attachPosNotes(rows) {
  const ids = rows.map((o) => String(o.order_id));
  if (!ids.length) return;
  const { data, error } = await supabaseClient.rpc('staff_get_online_order_notes', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_ids: ids
  });
  if (error) {
    console.error('staff_get_online_order_notes failed:', error);
    return;
  }
  const byOrder = new Map((data || []).map((n) => [String(n.order_id), n.note]));
  rows.forEach((o) => {
    const note = byOrder.get(String(o.order_id)) || null;
    o.pos_note = o.received_at_shop || isPosNote(note) ? note : null;
  });
}

// Production Orders linked to the rows on screen (prodOrderBadgeHtml). Quietly none until
// sql/supabase_online_order_production_order_tag.sql has been run.
async function attachProductionOrders(rows) {
  const ids = rows.map((o) => String(o.order_id));
  if (!ids.length) return;
  const { data, error } = await supabaseClient.rpc('staff_list_online_order_production_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_ids: ids
  });
  if (error) {
    console.warn('staff_list_online_order_production_orders:', error.message);
    return;
  }
  const byOrder = new Map();
  (data || []).forEach((p) => {
    const key = String(p.order_id);
    if (!byOrder.has(key)) byOrder.set(key, []);
    byOrder.get(key).push(p);
  });
  rows.forEach((o) => { o.production_orders = byOrder.get(String(o.order_id)) || []; });
}

// Dispatcher release progress for the rows on screen (releaseBadgeHtml / Release History) - o.release
// is set only on orders with at least one release. Quietly none until
// sql/supabase_online_order_partial_release.sql has been run.
async function attachReleaseSummary(rows) {
  rows.forEach((o) => { o.release = null; });
  const ids = rows.map((o) => String(o.order_id));
  if (!ids.length) return;
  const { data, error } = await supabaseClient.rpc('staff_list_online_order_release_summary', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_ids: ids
  });
  if (error) {
    console.warn('staff_list_online_order_release_summary:', error.message);
    return;
  }
  const byOrder = new Map((data || []).map((r) => [String(r.order_id), r]));
  rows.forEach((o) => { o.release = byOrder.get(String(o.order_id)) || null; });
}

// One-line POS description for the list / phone cards: the cashier's Order text, else the items.
function posNoteSummary(o) {
  if (!o?.pos_note) return '';
  const rows = parsePosDescription(o.pos_note);
  const pick = rows.find((r) => r.label === 'Description') || rows.find((r) => r.label === 'Details');
  return pick ? pick.value.replace(/\s*\|\|\s*/g, ' · ') : '';
}

async function loadOrders(search, status) {
  const myGeneration = ++loadGeneration;
  const grouped = !!currentSession.isOnlineOrderStaff;
  const trimmedSearch = (search || '').trim();
  const trimmedStatus = (status || '').trim();

  const { data, error } = await rpcBranchScoped('admin_list_online_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: trimmedSearch || null,
    p_status: trimmedStatus || null,
    p_period: currentPeriod,
    p_walkin_only: currentScope === 'walkin',
    p_page: currentPage,
    p_page_size: currentPageSize,
    p_confirmed_by: currentConfirmedBy,
    p_status_in: grouped ? ONLINE_ORDER_STAFF_STATUS_SCOPE : null,
    p_assigned_to_me: myAssignmentsOnly
  });

  if (myGeneration !== loadGeneration) return;

  if (error) {
    if (grouped) {
      document.getElementById('groupedOrdersList').innerHTML = `<p class="error-text">${error.message}</p>`;
    } else {
      document.getElementById('orderTableBody').innerHTML = `<tr><td colspan="18" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    }
    return;
  }

  // NOTE: warehouse scoping is server-side once supabase_online_order_all_branch_fabrication.sql
  // is run (p_branch_scoped - this filter is then a no-op); before that it's a client-side
  // post-filter like outstanding-only, applied AFTER the server already paged the unfiltered
  // result - so a page can show fewer than pageSize rows, and the pagination bar's total
  // reflects the pre-filter total.
  let rows = myAssignmentsOnly ? (data || []) : (data || []).filter(matchesWarehouseFilter);
  if (myAssignmentsOnly) setMyAssignmentsCount(data?.[0]?.total_count || 0);
  if (outstandingOnly) {
    rows = rows.filter((o) => Number(o.balance) > 0);
  }

  await attachDispatchers(rows);
  await attachProductionDone(rows);
  await attachPosNotes(rows);
  await attachProductionOrders(rows);
  await attachReleaseSummary(rows);
  if (myGeneration !== loadGeneration) return;

  // Online Order Staff get the tabbed card view (renderGroupedOrders) instead of the flat table +
  // pagination bar - see the isOnlineOrderStaff branch in init() below, which hides
  // #flatOrdersView/shows #groupedOrdersView and bumps currentPageSize to the server's 200-row
  // cap so this single fetch covers their whole Confirmed/Printed/To Ship queue.
  if (grouped) {
    renderGroupedOrders(rows, (data || []).length, data?.[0]?.total_count || 0);
    return;
  }

  lastFlatRows = rows;
  stockStatusCache.clear(); // stock may have moved since - re-checked for the selected / opened order
  if (selectedOrderId && !rows.some((o) => String(o.order_id) === String(selectedOrderId))) selectedOrderId = null;
  updateOrderActionState();
  refreshOpenOrderCardHeader();

  document.getElementById('setupContent').classList.toggle('mine-mode', myAssignmentsOnly);
  // Maker focus: the cards on every width instead of the wide grid (css/bc-list.css .assign-focus).
  document.getElementById('setupContent').classList.toggle('assign-focus', isMakerFocus());
  document.getElementById('deliveryFeeHeader').classList.toggle('hidden', hidePrices());
  if (myAssignmentsOnly) renderMyAssignmentCards(rows);
  loadMyProductionOrderCards();

  const tbody = document.getElementById('orderTableBody');
  tbody.innerHTML = rows.length === 0
    ? `<tr><td colspan="18" class="cell-msg">${myAssignmentsOnly ? 'Nothing to do right now - no open work is assigned to you.' : 'No online orders found.'}</td></tr>`
    : orderRowsHtml(rows);

  renderPaginationBar(
    document.getElementById('orderPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadOrders(trimmedSearch, trimmedStatus); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadOrders(trimmedSearch, trimmedStatus); }
    }
  );
  fitGridToViewport();
}

// The list grid fills the rest of the window (css/bc-list.css .bc-grid-wrap) - measured, since the
// chrome above it (info bar, status tabs) comes and goes.
function fitGridToViewport() {
  const el = document.getElementById('orderGridWrap');
  if (!el || el.offsetParent === null) return;
  const available = window.innerHeight - el.getBoundingClientRect().top - 64; // leaves room for the pagination bar
  el.style.maxHeight = Math.max(240, available) + 'px';
}

function escapeCsvValue(value) {
  const str = value === null || value === undefined ? '' : String(value);
  return /[",\n]/.test(str) ? '"' + str.replace(/"/g, '""') + '"' : str;
}

// Super-user-only "Export to Excel" (exportExcelBtn - see init()'s session.isSuperUser gate).
// Exports every order matching the CURRENT search/status/period/scope/confirmedBy/warehouse
// filters, not just the page currently on screen - loops admin_list_online_orders at its own
// max page size (200, see v_page_size in supabase_orders_sync_tables.sql) until exhausted.
// Plain CSV (not a real .xlsx) - Excel opens it natively with no extra library/CDN dependency;
// the UTF-8 BOM prefix keeps Excel from mangling the Peso sign in any money fields later added.
async function exportOrdersToExcel() {
  // Belt-and-braces: the button is only un-hidden for super users, but refuse here too in case it's
  // reached another way (e.g. the button un-hidden from dev tools).
  if (!currentSession?.isSuperUser) {
    alert('Only super users can export orders to Excel.');
    return;
  }
  const btn = document.getElementById('exportExcelBtn');
  const searchInput = document.getElementById('orderSearchInput');
  const statusInput = document.getElementById('statusFilterInput');
  const trimmedSearch = searchInput.value.trim();
  const trimmedStatus = statusInput.value.trim();
  const exportPageSize = 200;

  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Exporting...';

  try {
    const allRows = [];
    let page = 1;
    for (;;) {
      const { data, error } = await rpcBranchScoped('admin_list_online_orders', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_search: trimmedSearch || null,
        p_status: trimmedStatus || null,
        p_period: currentPeriod,
        p_walkin_only: currentScope === 'walkin',
        p_page: page,
        p_page_size: exportPageSize,
        p_confirmed_by: currentConfirmedBy
      });

      if (error) {
        alert('Export failed: ' + error.message);
        return;
      }

      let rows = (data || []).filter(matchesWarehouseFilter);
      if (outstandingOnly) {
        rows = rows.filter((o) => Number(o.balance) > 0);
      }
      allRows.push(...rows);

      if (!data || data.length < exportPageSize) break;
      page += 1;
    }

    if (allRows.length === 0) {
      alert('No orders to export for the current filters.');
      return;
    }

    // Every field admin_list_online_orders returns (except total_count, which is pagination
    // metadata, not an order field) - per "include all available fields in the export".
    const headers = [
      'Order ID', 'Date', 'Time', 'Status', 'Customer', 'Location ID', 'Warehouse',
      'Money To Collect', 'Amount Paid', 'Discount', 'Balance', 'For Delivery',
      'Shipping Address', 'Est. Delivery Date', 'Last Updated', 'Synced At', 'Glass Thickness',
      'Created By', 'Confirmed By', 'Print Note', 'Delivery Fee', 'Has Custom Line', 'Assigned Production Member'
    ];
    const csvLines = [headers.map(escapeCsvValue).join(',')];
    allRows.forEach((o) => {
      csvLines.push([
        o.order_id,
        o.order_date,
        o.order_time,
        o.status,
        o.customer_name,
        o.location_id,
        o.warehouse_name,
        o.money_to_collect,
        o.amount_paid,
        o.discount,
        o.balance,
        o.for_delivery ? 'Yes' : 'No',
        o.shipping_address,
        o.estimated_delivery_date,
        o.last_updated_at ? new Date(o.last_updated_at).toLocaleString() : '',
        o.synced_at_utc ? new Date(o.synced_at_utc).toLocaleString() : '',
        o.glass_thickness,
        o.created_by,
        o.confirmed_by,
        o.note_print,
        o.delivery_fee,
        o.has_custom_line ? 'Yes' : 'No',
        o.assigned_production_member_name || o.assigned_production_member
      ].map(escapeCsvValue).join(','));
    });

    const blob = new Blob(['﻿' + csvLines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
    const link = document.createElement('a');
    link.href = url;
    link.download = `online-orders-${stamp}.csv`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}

// Highlights whichever status-summary pill matches the current status filter text (case-
// insensitive), so clicking a pill (or typing a status directly into the filter box) gives a
// clear "this is the active filter" indication.
function updateStatusPillActiveState() {
  const currentStatus = document.getElementById('statusFilterInput').value.trim().toLowerCase();
  document.querySelectorAll('#statusSummaryBar .status-summary-pill').forEach((pill) => {
    if (pill.dataset.mine) {
      pill.classList.toggle('active', myAssignmentsOnly);
      return;
    }
    pill.classList.toggle('active', !myAssignmentsOnly && currentStatus !== '' && pill.dataset.status.toLowerCase() === currentStatus);
  });
}

// The My Assignments count = assigned online orders + Released Production Orders where this user's
// part isn't done yet (loadMyProductionOrderCards) - per "if maker has an production order mark it
// under my assignments for that user".
let myOnlineAssignmentCount = 0;
let myProductionOrderCount = 0;
function setMyAssignmentsCount(count) {
  if (count != null) myOnlineAssignmentCount = Number(count) || 0;
  document.getElementById('myAssignmentsCount').textContent = String(myOnlineAssignmentCount + myProductionOrderCount);
}

// Tab buttons for the grouped (Online Order Staff) view - switching tabs re-renders from the
// last-fetched rows (lastGroupedRows) rather than re-querying the server, so it's instant.
function wireGroupedTabs() {
  document.getElementById('groupedTabs').addEventListener('click', (event) => {
    const tabBtn = event.target.closest('.grouped-tab-btn');
    if (!tabBtn) return;

    activeGroupStatus = tabBtn.dataset.status;
    document.querySelectorAll('#groupedTabs .grouped-tab-btn').forEach((btn) => {
      btn.classList.toggle('active', btn === tabBtn);
    });
    renderActiveGroupTab();
  });
}

function wireOrderFilters() {
  const searchInput = document.getElementById('orderSearchInput');
  const statusInput = document.getElementById('statusFilterInput');

  const reload = () => {
    updateStatusPillActiveState();
    currentPage = 1;
    clearTimeout(orderSearchDebounceHandle);
    orderSearchDebounceHandle = setTimeout(
      () => loadOrders(searchInput.value.trim(), statusInput.value.trim()),
      300
    );
  };

  searchInput.addEventListener('input', reload);
  statusInput.addEventListener('input', reload);

  // Per "make that button clickable so the user can filter out based on status" - clicking a
  // status-summary pill sets the status filter box to that status (or clears it if the same
  // pill is clicked again while already active) and reloads immediately, no debounce needed
  // since it's a discrete click rather than free-text typing.
  document.getElementById('statusSummaryBar').addEventListener('click', (event) => {
    const pill = event.target.closest('.status-summary-pill');
    if (!pill) return;

    // My Assignments toggles the assigned-to-me filter and clears the status filter; a status tab
    // switches back to the full list (unless this account is locked to its assignments).
    if (pill.dataset.mine) {
      if (myAssignmentsLocked) return;
      myAssignmentsOnly = !myAssignmentsOnly;
      statusInput.value = '';
      updateStatusPillActiveState();
      currentPage = 1;
      clearTimeout(orderSearchDebounceHandle);
      loadOrders(searchInput.value.trim(), '');
      return;
    }
    if (!myAssignmentsLocked) myAssignmentsOnly = false;

    const clickedStatus = pill.dataset.status;
    const alreadyActive = statusInput.value.trim().toLowerCase() === clickedStatus.toLowerCase();
    statusInput.value = alreadyActive ? '' : clickedStatus;
    updateStatusPillActiveState();
    currentPage = 1;

    clearTimeout(orderSearchDebounceHandle);
    loadOrders(searchInput.value.trim(), statusInput.value.trim());
  });

  document.getElementById('exportExcelBtn').addEventListener('click', exportOrdersToExcel);

  document.getElementById('refreshOrdersBtn').addEventListener('click', () => {
    refreshCurrentOrders();
    if (!document.getElementById('statusSummaryBar').classList.contains('hidden')) loadStatusSummary();
  });

  let filterPaneOpen = true;
  document.getElementById('filterPaneBtn').addEventListener('click', () => {
    filterPaneOpen = !filterPaneOpen;
    document.getElementById('filterPane').classList.toggle('hidden', !filterPaneOpen);
    document.getElementById('flatOrdersView').classList.toggle('no-filterpane', !filterPaneOpen);
    document.getElementById('filterPaneBtn').setAttribute('aria-pressed', filterPaneOpen ? 'true' : 'false');
    fitGridToViewport();
  });
  window.addEventListener('resize', fitGridToViewport);
}

// WALKIN_LIST_LAYOUT - per "in the walk-in orders can we also put a tag if that order is custom and
// needs 10mm 12mm glass also show the warehouse/location": the Walk-in tab drops the Dispatcher /
// delivery columns (css/bc-list.css .oo-walkin) so the Tags (Custom / 10mm / 12mm glass) and
// Warehouse columns sit closer to view, and keeps its own saved column widths. Tank / Stand Maker
// stay - walk-ins can be assigned to makers (supabase_walkin_order_production.sql). Runs at load,
// not in init(), because js/bcColumnResize.js applies saved widths on DOMContentLoaded - before
// init()'s awaits finish. init() takes it back off for accounts that can't see the scope tabs.
if (new URLSearchParams(window.location.search).get('scope') === 'walkin') {
  const walkinGrid = document.querySelector('.oo-grid');
  walkinGrid.classList.add('oo-walkin');
  walkinGrid.dataset.resizeKey = 'online-orders-walkin-v2';
  const tagsHeader = walkinGrid.tHead.rows[0].cells[11];
  if (tagsHeader) tagsHeader.textContent = 'Tags';
  // Walk-ins have no print note - that slot shows the POS description instead (posNoteSummary).
  const noteHeader = walkinGrid.tHead.rows[0].cells[12];
  if (noteHeader) noteHeader.textContent = 'POS Description';
}

// ---------------------------------------------------------------- Advance Orders tab
// Per "how about the advance orders can we squeeze it in there" - the POS's deposit/downpayment
// orders as a third list tab (?scope=advance, super users only), same read-only data and RPC as
// advance-orders.html (admin_list_advance_orders). None of the online-order actions apply, so the
// page's online wiring is skipped entirely in this mode (see init()).
let advancePage = 1;
let advancePageSize = 50;
let advanceLoadGeneration = 0;

function formatAdvanceMoney(value) {
  return value === null || value === undefined ? '' : Number(value).toFixed(2);
}

async function loadAdvanceOrders() {
  const tbody = document.getElementById('advanceTableBody');
  tbody.innerHTML = '<tr><td colspan="15" class="cell-msg">Loading...</td></tr>';
  const thisGeneration = ++advanceLoadGeneration;

  const { data, error } = await supabaseClient.rpc('admin_list_advance_orders', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: document.getElementById('orderSearchInput').value.trim() || null,
    p_page: advancePage,
    p_page_size: advancePageSize
  });
  if (thisGeneration !== advanceLoadGeneration) return; // superseded by a newer search/page

  if (error) {
    tbody.innerHTML = `<tr><td colspan="15" class="cell-msg error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  tbody.innerHTML = !data || data.length === 0
    ? '<tr><td colspan="15" class="cell-msg">No advance orders found.</td></tr>'
    : data.map((o) => `
      <tr>
        <td>${escapeHtml(o.transaction_no || '')}</td>
        <td>${escapeHtml(o.receipt_no || '')}</td>
        <td>${escapeHtml(o.user_id || '')}</td>
        <td>${escapeHtml(o.customer_name || '')}</td>
        <td>${escapeHtml(o.order_description || '')}</td>
        <td>${escapeHtml(o.order_date || '')}</td>
        <td>${escapeHtml(o.order_time || '')}</td>
        <td class="num">${formatAdvanceMoney(o.net_amount)}</td>
        <td class="num">${formatAdvanceMoney(o.downpayment)}</td>
        <td class="num">${formatAdvanceMoney(o.balance)}</td>
        <td>${escapeHtml(o.online_order_id || '')}</td>
        <td><span class="badge ${o.fully_paid ? 'badge-success' : 'badge-neutral'}">${o.fully_paid ? 'Yes' : 'No'}</span></td>
        <td>${o.date_paid ? escapeHtml(new Date(o.date_paid).toLocaleString()) : ''}</td>
        <td>${escapeHtml(o.warehouse || '')}</td>
        <td><a href="advance-order-lines.html?transaction=${encodeURIComponent(o.transaction_no)}">View</a></td>
      </tr>`).join('');

  renderPaginationBar(
    document.getElementById('advancePaginationBar'),
    { page: advancePage, pageSize: advancePageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { advancePage = newPage; loadAdvanceOrders(); },
      onPageSizeChange: (newSize) => { advancePageSize = newSize; advancePage = 1; loadAdvanceOrders(); }
    }
  );
}

function fitAdvanceGridToViewport() {
  const el = document.getElementById('advanceGridWrap');
  if (!el || el.offsetParent === null) return;
  el.style.maxHeight = Math.max(240, window.innerHeight - el.getBoundingClientRect().top - 64) + 'px';
}

async function initAdvanceOrdersView() {
  document.getElementById('orderScopeTabs').classList.remove('hidden');
  document.getElementById('scopeTabAdvance').classList.add('active');
  document.querySelector('.bc-title').textContent = 'Advance Orders';
  document.getElementById('ordersSubtitle').textContent = 'Customer deposit/downpayment orders from the POS (read-only).';
  document.title = document.title.replace('Online Orders', 'Advance Orders');
  document.getElementById('orderSearchInput').placeholder = 'Search transaction, receipt, or customer';

  // Only Refresh applies here - hide every other action, the status tabs, and the online list.
  document.querySelectorAll('#orderCmdbar > :not(#refreshOrdersBtn)').forEach((el) => el.classList.add('hidden'));
  ['statusSummaryBar', 'flatOrdersView', 'filterPaneBtn'].forEach((id) => document.getElementById(id).classList.add('hidden'));
  document.getElementById('advanceOrdersView').classList.remove('hidden');

  let searchDebounce = null;
  document.getElementById('orderSearchInput').addEventListener('input', () => {
    clearTimeout(searchDebounce);
    searchDebounce = setTimeout(() => { advancePage = 1; loadAdvanceOrders(); }, 300);
  });
  document.getElementById('refreshOrdersBtn').addEventListener('click', loadAdvanceOrders);
  if (window.initPullToRefresh) initPullToRefresh(loadAdvanceOrders);
  window.addEventListener('resize', fitAdvanceGridToViewport);

  await loadAdvanceOrders();
  fitAdvanceGridToViewport();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Online Orders');

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Online Orders.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  // Makers land here instead of the Dashboard - ask them to turn on job notifications
  // (no-op for anyone who isn't a Sales User / Tank / Stand Maker).
  maybeShowPushLoginPrompt(session);
  document.getElementById('scopeTabAdvance').classList.toggle('hidden', !session.isSuperUser);
  if (session.isSuperUser && new URLSearchParams(window.location.search).get('scope') === 'advance') {
    await initAdvanceOrdersView();
    return;
  }
  document.getElementById('exportExcelBtn').classList.toggle('hidden', !session.isSuperUser);
  // Delegated on #setupContent (not #orderTableBody directly) so the same "To Ship" handling
  // works whether the click lands in the flat table or one of the three grouped-view tables
  // (see the isOnlineOrderStaff branch below) - handleOrderTableClick already finds its target
  // via .closest(), so it doesn't care which table fired the event.
  document.getElementById('setupContent').addEventListener('click', handleOrderTableClick);
  document.getElementById('setupContent').addEventListener('change', handleAssignProductionMemberChange);
  document.getElementById('toShipPhotoInput').addEventListener('change', handleToShipPhotoSelected);
  document.getElementById('toShipPhotoInput').addEventListener('cancel', handleToShipPhotoCancelled);
  document.getElementById('sendPhotoInput').addEventListener('change', handleSendPhotoSelected);
  document.getElementById('sendPhotoInput').addEventListener('cancel', handleSendPhotoCancelled);
  wireOrderFilters();
  wireShipSerialModalButtons();
  wireViewSerialsModalButtons();
  wireSendMessageModalButtons();
  wireOrderListActions();
  wireOrderCard();
  wireAssignDialog();
  wireMyAssignmentCards();
  wireProdOrderCard();
  wireSendBackDialog();
  wireReleaseDialog();
  wireNextStepButtons();
  wireOrderCardAttachments();
  // Swipe-down-to-refresh (js/pullToRefresh.js) - re-runs whatever's currently on screen, same
  // as the search/status filters' own reload, so a refresh mid-search doesn't clear it.
  if (window.initPullToRefresh) initPullToRefresh(refreshCurrentOrders);
  currentSessionIsProductionWarehouse = await resolveIsProductionWarehouse(session);
  await loadProductionMembers();

  // Supports deep-linking from the Dashboard's status cards, e.g. online-orders.html?status=Shipped,
  // from the Dashboard's finance cards, e.g. ?period=month|today|prevmonth, ?scope=walkin,
  // ?filter=outstanding, and from a Sales by Staff figure, e.g. ?confirmedBy=Juan+Dela+Cruz&period=month
  // (see dashboard.html's finance-card hrefs / staffStatLinkHtml in js/dashboard.js / the
  // module-level comment on currentPeriod above).
  const urlParams = new URLSearchParams(window.location.search);
  const periodParam = urlParams.get('period') || '';
  const scopeParam = urlParams.get('scope') || '';
  const filterParam = urlParams.get('filter') || '';
  const confirmedByParam = urlParams.get('confirmedBy') || '';

  // Per "if the user is a online order staff They can only see Confirmed / Printed / To Ship" -
  // hard-locked server-side via p_status_in (see loadOrders/ONLINE_ORDER_STAFF_STATUS_SCOPE
  // above), not just a default they can clear/change (ignores any ?status= deep link too). The
  // text here is just a display label for the disabled box - loadOrders always sends the real
  // 3-status list for this role regardless of what this string says. The status filter box and
  // status-summary pills are disabled rather than hidden so it's still visible/obvious why
  // nothing else shows up.
  const statusParam = session.isOnlineOrderStaff ? ONLINE_ORDER_STAFF_STATUS_SCOPE.join(', ') : (urlParams.get('status') || '');

  if (statusParam) {
    document.getElementById('statusFilterInput').value = statusParam;
  }
  if (session.isOnlineOrderStaff) {
    hidePriceColumns = true;
    document.getElementById('deliveryFeeHeader').classList.add('hidden');
    const statusInput = document.getElementById('statusFilterInput');
    statusInput.disabled = true;
    statusInput.title = 'Your account only shows Confirmed, Printed, and To Ship orders.';
    document.getElementById('statusSummaryBar').classList.add('hidden');

    // Per "i want to show the online order per category: Confirmed / Printed / To-Ship" - swap
    // the flat table for the three-section grouped view (see renderGroupedOrders/loadOrders
    // above), and fetch at the server's max page size (200, see admin_list_online_orders) in one
    // shot instead of paging, since this role's whole queue is only ever these 3 statuses.
    document.getElementById('flatOrdersView').classList.add('hidden');
    document.getElementById('groupedOrdersView').classList.remove('hidden');
    // The filter pane lives inside #flatOrdersView, so its toggle has nothing to show here.
    document.getElementById('filterPaneBtn').classList.add('hidden');
    // The action bar's row actions work on the desktop list's selected row - the phone cards carry
    // their own buttons instead, so only Refresh stays.
    ['openOrderBtn', 'listSendPhotoBtn', 'listSendMessageBtn', 'listToShipBtn', 'listAssignBtn'].forEach((id) => document.getElementById(id).classList.add('hidden'));
    document.querySelectorAll('#orderCmdbar .bc-cmd-sep').forEach((sep) => sep.classList.add('hidden'));
    currentPageSize = 200;
    wireGroupedTabs();
  }
  if (session.isOrderMaker && !session.isOnlineOrderStaff) {
    document.getElementById('myAssignmentsTab').classList.remove('hidden');
    // Makers land on their own list; Super Users / Production Managers who also hold a maker role
    // keep the full list and can click the tab.
    myAssignmentsOnly = !session.isSuperUser && !session.isProductionManager && !urlParams.get('status');
  }
  if (isOrderMakerOnly(session)) {
    myAssignmentsLocked = true;
    myAssignmentsOnly = true;
    document.querySelector('.bc-title').textContent = 'My Assignments';
    document.getElementById('ordersSubtitle').textContent = 'Orders assigned to you. Open one to see its items and photos; tap Production Done when your part is finished.';
    hidePriceColumns = true;
    document.getElementById('deliveryFeeHeader').classList.add('hidden');
    // Only their tab - status tabs and the status filter would just be empty for them.
    document.querySelectorAll('#statusSummaryBar .status-summary-pill:not([data-mine])').forEach((pill) => pill.classList.add('hidden'));
    document.getElementById('filterPaneBtn').classList.add('hidden');
    // Read-only: Open and Refresh only, on the list and on the order card.
    ['listSendPhotoBtn', 'listSendMessageBtn', 'listToShipBtn', 'listAssignBtn', 'exportExcelBtn',
      'cardSendPhotoBtn', 'cardSendMessageBtn', 'cardToShipBtn', 'cardAssignBtn']
      .forEach((id) => document.getElementById(id).classList.add('hidden'));
    document.querySelectorAll('#orderCmdbar .bc-cmd-sep').forEach((sep) => sep.classList.add('hidden'));
  }
  updateStatusPillActiveState();

  currentPeriod = periodParam === 'month' || periodParam === 'today' || periodParam === 'prevmonth' ? periodParam : null;
  currentScope = scopeParam === 'walkin' ? 'walkin' : null;
  outstandingOnly = filterParam === 'outstanding';
  currentConfirmedBy = confirmedByParam.trim() || null;

  const noteParts = [];
  if (currentConfirmedBy) {
    noteParts.push(`orders confirmed by ${currentConfirmedBy}`);
  } else {
    if (currentScope === 'walkin') noteParts.push('walk-in');
    noteParts.push(currentScope === 'walkin' ? 'sales' : 'online orders');
  }
  if (currentPeriod === 'month') {
    noteParts.push('for ' + new Date().toLocaleDateString('en-US', { month: 'long', year: 'numeric' }));
  } else if (currentPeriod === 'today') {
    noteParts.push('for today (' + new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }) + ')');
  } else if (currentPeriod === 'prevmonth') {
    const prevMonthDate = new Date();
    prevMonthDate.setDate(1);
    prevMonthDate.setMonth(prevMonthDate.getMonth() - 1);
    noteParts.push('for ' + prevMonthDate.toLocaleDateString('en-US', { month: 'long', year: 'numeric' }));
  }
  if (outstandingOnly) noteParts.push('with an outstanding balance');

  // Online / Walk-in list switch (online-orders.html #orderScopeTabs) - a separate Walk-in Orders
  // list alongside the online one. Not for Online Order Staff / maker-only accounts, whose lists
  // are locked to their own scope. Walk-ins never go through the maker flow, so a maker who can
  // see the switch gets the whole walk-in list rather than their (online-only) assignments.
  const showScopeTabs = !session.isOnlineOrderStaff && !myAssignmentsLocked;
  if (!showScopeTabs) document.querySelector('.oo-grid').classList.remove('oo-walkin'); // see WALKIN_LIST_LAYOUT
  document.getElementById('orderScopeTabs').classList.toggle('hidden', !showScopeTabs);
  document.getElementById('scopeTabOnline').classList.toggle('active', currentScope !== 'walkin');
  document.getElementById('scopeTabWalkin').classList.toggle('active', currentScope === 'walkin');
  if (currentScope === 'walkin' && showScopeTabs) {
    myAssignmentsOnly = false;
    document.querySelector('.bc-title').textContent = 'Walk-in Orders';
    document.getElementById('ordersSubtitle').textContent = 'Pancake orders received and paid for in-store.';
    // Walk-in tabs are portal-only stages (supabase_walkin_order_portal_status.sql) - no Confirmed /
    // Printed / To Ship: the POS creates every walk-in as Shipped in Pancake.
    document.querySelectorAll('#statusSummaryBar .online-pill').forEach((pill) => pill.classList.add('hidden'));
    document.querySelectorAll('#statusSummaryBar .walkin-pill').forEach((pill) => pill.classList.remove('hidden'));
    document.title = document.title.replace('Online Orders', 'Walk-in Orders');
  }

  // The scope tabs already say which list this is, so the note only shows for the Dashboard's
  // other deep-link filters - and Clear filters keeps you on the same (online / walk-in) list.
  const activeFilterNote = document.getElementById('activeFilterNote');
  if (currentPeriod || outstandingOnly || currentConfirmedBy || (currentScope && !showScopeTabs)) {
    const clearHref = currentScope === 'walkin' && showScopeTabs ? 'online-orders.html?scope=walkin' : 'online-orders.html';
    activeFilterNote.innerHTML = `Showing ${noteParts.join(' ')}. <a href="${clearHref}">Clear filters</a>`;
    activeFilterNote.classList.remove('hidden');
  }

  // The status summary bar/pills count the list's own scope - online orders, or walk-ins on the
  // Walk-in tab (admin_get_online_order_status_summary's p_walkin_only, supabase_walkin_order_
  // production.sql). My Assignments already spans both (walk-in and online), so it stays on the
  // Online tab only. Stays hidden for Online Order Staff regardless (already hidden above) - a
  // summary across every status isn't useful when this account can only ever see Printed orders anyway.
  const showStatusSummary = !session.isOnlineOrderStaff && (currentScope !== 'walkin' || showScopeTabs);
  document.getElementById('statusSummaryBar').classList.toggle('hidden', !showStatusSummary);
  if (currentScope === 'walkin' && showScopeTabs) document.getElementById('myAssignmentsTab').classList.add('hidden');

  const loaders = [loadOrders('', myAssignmentsOnly ? '' : statusParam)];
  if (showStatusSummary && !myAssignmentsLocked) loaders.push(loadStatusSummary());
  await Promise.all(loaders);
})();
