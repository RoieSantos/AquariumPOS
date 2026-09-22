// Customer Message Timing dashboard page logic (super users only) - day-of-week x hour-of-day
// heatmap of inbound customer messages on ChatbotMessages (the GMA Conversations AI bot), so staff
// can see when customers actually message in. Mirrors the auth/filter pattern of the sibling
// "orders" dashboard (docs/order-timing-dashboard.html / js/orderTimingDashboard.js) - same
// admin_get_order_confirmation_timing shape, just one metric (inbound messages) instead of two, and
// a day x hour heatmap grid instead of separate bar rows per request.
let currentSession = null;

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const DAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function hourLabel(hour) {
  if (hour === 0) return '12 AM';
  if (hour === 12) return '12 PM';
  return hour < 12 ? `${hour} AM` : `${hour - 12} PM`;
}

function shortHourLabel(hour) {
  if (hour === 0) return '12a';
  if (hour === 12) return '12p';
  return hour < 12 ? `${hour}a` : `${hour - 12}p`;
}

// Turns the RPC's flat (day_of_week, hour_of_day, message_count) rows into a dense 7x24 grid,
// defaulting every bucket the RPC didn't return to 0.
function buildGrid(rows) {
  const grid = Array.from({ length: 7 }, () => new Array(24).fill(0));

  (rows || []).forEach((row) => {
    const day = row.day_of_week;
    const hour = row.hour_of_day;
    if (day === null || day === undefined || hour === null || hour === undefined) return;
    if (day < 0 || day > 6 || hour < 0 || hour > 23) return;
    grid[day][hour] = Number(row.message_count) || 0;
  });

  return grid;
}

// Buckets a raw count into one of 5 heat levels (0 = none, 1-4 = increasing quarters of the
// grid's own max), same idea as a GitHub contribution graph rather than a literal linear scale -
// keeps a handful of very busy hours from washing out every other cell to near-white.
function levelFor(count, max) {
  if (count <= 0 || max <= 0) return 0;
  return Math.min(4, Math.max(1, Math.ceil((count / max) * 4)));
}

function renderHeatmap(grid) {
  const container = document.getElementById('msgHeatmapGrid');
  const max = Math.max(1, ...grid.map((hours) => Math.max(...hours)));

  let html = '<div class="msg-heat-corner"></div>';
  for (let hour = 0; hour < 24; hour++) {
    html += `<div class="msg-heat-hour-label">${hour % 3 === 0 ? shortHourLabel(hour) : ''}</div>`;
  }

  grid.forEach((hours, day) => {
    html += `<div class="msg-heat-day-label">${DAY_LABELS[day]}</div>`;
    hours.forEach((count, hour) => {
      const level = levelFor(count, max);
      html += `<div class="msg-heat-cell" data-level="${level}" title="${DAY_NAMES[day]} ${hourLabel(hour)}: ${count} message${count === 1 ? '' : 's'}"></div>`;
    });
  });

  container.innerHTML = html;
}

function renderTopSlots(grid) {
  const tbody = document.getElementById('topSlotsBody');
  const entries = [];

  grid.forEach((hours, day) => {
    hours.forEach((count, hour) => {
      if (count > 0) entries.push({ day, hour, count });
    });
  });
  entries.sort((a, b) => b.count - a.count);
  const top = entries.slice(0, 10);

  if (top.length === 0) {
    tbody.innerHTML = '<tr><td colspan="2" class="muted">No data yet</td></tr>';
    return;
  }

  tbody.innerHTML = top
    .map((entry) => `<tr><td>${DAY_NAMES[entry.day]}, ${hourLabel(entry.hour)}</td><td>${entry.count}</td></tr>`)
    .join('');
}

function bestBucketLabel(counts, labels, unitWord) {
  const max = Math.max(...counts);
  if (max <= 0) return 'No messages yet';
  const index = counts.indexOf(max);
  return `${labels[index]} (${max} ${unitWord})`;
}

async function loadTimingData() {
  const loadingEl = document.getElementById('timingLoading');
  const errorEl = document.getElementById('timingError');
  const resultsEl = document.getElementById('timingResults');

  loadingEl.classList.remove('hidden');
  errorEl.classList.add('hidden');
  resultsEl.classList.add('hidden');

  const dateFrom = document.getElementById('dateFromInput').value || null;
  const dateTo = document.getElementById('dateToInput').value || null;

  const { data, error } = await supabaseClient.rpc('admin_get_chatbot_message_timing', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_date_from: dateFrom,
    p_date_to: dateTo
  });

  loadingEl.classList.add('hidden');

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  const grid = buildGrid(data);
  const byDay = grid.map((hours) => hours.reduce((sum, count) => sum + count, 0));
  const byHour = new Array(24).fill(0);
  grid.forEach((hours) => hours.forEach((count, hour) => { byHour[hour] += count; }));
  const total = byDay.reduce((sum, count) => sum + count, 0);

  document.getElementById('busiestDay').textContent = bestBucketLabel(byDay, DAY_NAMES, 'messages');
  document.getElementById('busiestHour').textContent = bestBucketLabel(byHour, Array.from({ length: 24 }, (_, hour) => hourLabel(hour)), 'messages');
  document.getElementById('totalMessages').textContent = total.toLocaleString();

  renderHeatmap(grid);
  renderTopSlots(grid);

  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Message Timing');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Message Timing.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');

  document.getElementById('applyFilterBtn').addEventListener('click', loadTimingData);
  document.getElementById('clearFilterBtn').addEventListener('click', () => {
    document.getElementById('dateFromInput').value = '';
    document.getElementById('dateToInput').value = '';
    loadTimingData();
  });

  await loadTimingData();
})();
