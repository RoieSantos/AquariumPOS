// Order Timing dashboard page logic (super users only).
// No password re-entry prompt - super user status alone is enough, same trust model as
// Warehouse Setup/Online Orders/Expenses (reuses the password captured at login, session.password,
// see auth.js).
let currentSession = null;

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const DAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function hourLabel(hour) {
  if (hour === 0) return '12 AM';
  if (hour === 12) return '12 PM';
  return hour < 12 ? `${hour} AM` : `${hour - 12} PM`;
}

// Parses a plain "YYYY-MM-DD" (as returned by the RPC for date/week_start columns) as a local
// calendar date rather than UTC midnight - avoids `new Date("2026-08-03")` shifting a day
// backward/forward depending on the browser's timezone offset.
function parseLocalDate(isoDate) {
  const [year, month, day] = isoDate.split('-').map(Number);
  return new Date(year, month - 1, day);
}

function formatDateLabel(isoDate) {
  return parseLocalDate(isoDate).toLocaleDateString(undefined, { weekday: 'short', year: 'numeric', month: 'short', day: 'numeric' });
}

// week_start from the RPC is always a Monday (Postgres date_trunc('week', ...) convention).
function formatWeekLabel(isoWeekStart) {
  const start = parseLocalDate(isoWeekStart);
  const end = new Date(start);
  end.setDate(end.getDate() + 6);
  const startLabel = start.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  const endLabel = end.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
  return `${startLabel} - ${endLabel}`;
}

// Splits the flat RPC result into the series the page renders: day-of-week/hour-of-day are plain
// arrays of counts (defaulting missing buckets to 0); date/week are arrays of {key, count} pairs,
// one per bucket the RPC actually returned (no filling-in of missing dates/weeks).
function buildSeries(rows) {
  const createdByDay = new Array(7).fill(0);
  const createdByHour = new Array(24).fill(0);
  const confirmedByDay = new Array(7).fill(0);
  const confirmedByHour = new Array(24).fill(0);
  const createdByDate = [];
  const createdByWeek = [];
  const confirmedByDate = [];
  const confirmedByWeek = [];

  (rows || []).forEach((row) => {
    const count = Number(row.order_count) || 0;

    if (row.metric === 'created_date' && row.bucket_date) {
      createdByDate.push({ key: row.bucket_date, count });
      return;
    }
    if (row.metric === 'created_week' && row.week_start) {
      createdByWeek.push({ key: row.week_start, count });
      return;
    }
    if (row.metric === 'confirmed_date' && row.bucket_date) {
      confirmedByDate.push({ key: row.bucket_date, count });
      return;
    }
    if (row.metric === 'confirmed_week' && row.week_start) {
      confirmedByWeek.push({ key: row.week_start, count });
      return;
    }

    const target = row.metric === 'confirmed'
      ? (row.day_of_week !== null ? confirmedByDay : confirmedByHour)
      : (row.day_of_week !== null ? createdByDay : createdByHour);
    const index = row.day_of_week !== null ? row.day_of_week : row.hour_of_day;
    if (index !== null && index !== undefined && index >= 0 && index < target.length) {
      target[index] = count;
    }
  });

  const byCountDesc = (a, b) => b.count - a.count;
  createdByDate.sort(byCountDesc);
  createdByWeek.sort(byCountDesc);
  confirmedByDate.sort(byCountDesc);
  confirmedByWeek.sort(byCountDesc);

  return { createdByDay, createdByHour, confirmedByDay, confirmedByHour, createdByDate, createdByWeek, confirmedByDate, confirmedByWeek };
}

function renderTopTable(tbodyId, entries, formatLabel, limit) {
  const tbody = document.getElementById(tbodyId);
  const top = entries.slice(0, limit);

  if (top.length === 0) {
    tbody.innerHTML = '<tr><td colspan="2" class="muted">No data yet</td></tr>';
    return;
  }

  tbody.innerHTML = top
    .map((entry) => `<tr><td>${formatLabel(entry.key)}</td><td>${entry.count}</td></tr>`)
    .join('');
}

function renderBarRow(containerId, counts, labels) {
  const container = document.getElementById(containerId);
  const max = Math.max(1, ...counts);

  container.innerHTML = counts
    .map((count, index) => {
      const heightPct = Math.round((count / max) * 100);
      return `
        <div class="timing-bar-col" title="${labels[index]}: ${count} order${count === 1 ? '' : 's'}">
          <div class="timing-bar-count">${count > 0 ? count : ''}</div>
          <div class="timing-bar" style="height:${heightPct}%;"></div>
          <div class="timing-bar-label">${labels[index]}</div>
        </div>
      `;
    })
    .join('');
}

function bestBucketLabel(counts, labels, unitWord) {
  const max = Math.max(...counts);
  if (max <= 0) return 'No confirmed orders yet';
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

  const { data, error } = await supabaseClient.rpc('admin_get_order_confirmation_timing', {
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

  const series = buildSeries(data);

  document.getElementById('bestConfirmDay').textContent = bestBucketLabel(series.confirmedByDay, DAY_NAMES, 'orders confirmed');
  document.getElementById('bestConfirmHour').textContent = bestBucketLabel(series.confirmedByHour, Array.from({ length: 24 }, (_, h) => hourLabel(h)), 'orders confirmed');

  renderBarRow('createdByDayRow', series.createdByDay, DAY_LABELS);
  renderBarRow('createdByHourRow', series.createdByHour, Array.from({ length: 24 }, (_, h) => hourLabel(h)));
  renderBarRow('confirmedByDayRow', series.confirmedByDay, DAY_LABELS);
  renderBarRow('confirmedByHourRow', series.confirmedByHour, Array.from({ length: 24 }, (_, h) => hourLabel(h)));

  renderTopTable('createdTopDatesBody', series.createdByDate, formatDateLabel, 10);
  renderTopTable('createdTopWeeksBody', series.createdByWeek, formatWeekLabel, 10);
  renderTopTable('confirmedTopDatesBody', series.confirmedByDate, formatDateLabel, 10);
  renderTopTable('confirmedTopWeeksBody', series.confirmedByWeek, formatWeekLabel, 10);

  resultsEl.classList.remove('hidden');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Order Timing');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Order Timing.';
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
