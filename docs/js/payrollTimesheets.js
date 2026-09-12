// Employee Timesheets (super users + payroll officers). Officer/supervisor enters daily hours
// worked per employee - not employee self-service clock-in, and a plain hours number per day
// (not clock in/out times) - see supabase_payroll_timesheets.sql. admin_create_payroll_run reads
// these to auto-post an Overtime Addition / Undertime Deduction per employee when a run is
// created, using the standard hours/day, work days/month, and overtime multiplier configured in
// Payroll Setup's Overtime Settings.
let currentSession = null;
let employeeOptions = []; // [{ username, display_name }] from admin_list_payroll_employees
let currentEntries = [];
let currentPage = 1;
let currentPageSize = 50;
let weekStart = null; // Date - Monday of the week currently shown in the grid
let cutoffSettings = null; // loaded once from admin_get_payroll_cutoff_settings, used by autofillDates()

const WEEKDAY_LABELS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

function formatDate(dateStr) {
  if (!dateStr) return '';
  return new Date(dateStr + 'T00:00:00').toLocaleDateString();
}

function toDateInputValue(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function getMondayOf(date) {
  const d = new Date(date);
  const day = d.getDay(); // 0 = Sunday
  const diff = day === 0 ? -6 : 1 - day; // shift back to Monday
  d.setDate(d.getDate() + diff);
  return d;
}

function weekDates(monday) {
  return Array.from({ length: 7 }, (_, i) => {
    const d = new Date(monday);
    d.setDate(d.getDate() + i);
    return d;
  });
}

async function loadEmployeeOptionsOnce() {
  const { data, error } = await supabaseClient.rpc('admin_list_payroll_employees', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    employeeOptions = [];
    return;
  }

  // Only active employees actually enrolled in a pay cycle ever go through a payroll run, so
  // there's no point logging timesheets for anyone inactive or "Not enrolled" (pay_cycle null).
  employeeOptions = (data || []).filter((e) => e.is_active && e.pay_cycle);

  const filterSelect = document.getElementById('filterUsername');
  const entrySelect = document.getElementById('entryUsername');
  const optionsHtml = employeeOptions
    .map((e) => `<option value="${e.username}">${e.display_name || e.username}</option>`)
    .join('');

  filterSelect.innerHTML = '<option value="">All employees</option>' + optionsHtml;
  entrySelect.innerHTML = optionsHtml;
}

// Weekly grid: one row per active employee, one column per day (Mon-Sun) of the selected week,
// plus one Cash Advance column (one amount per employee for the whole week, not per day - see
// supabase_payroll_cash_advances_bulk_entry.sql). Each hours cell is pre-filled from any existing
// timesheet entry; the Cash Advance cell is pre-filled from any Outstanding advance already dated
// somewhere inside this week.
function renderWeekGrid(dates, existingByKey, advanceByUsername) {
  const thead = document.getElementById('bulkEntryTableHead');
  const tbody = document.getElementById('bulkEntryTableBody');

  const headerCells = dates
    .map((d, i) => `<th>${WEEKDAY_LABELS[i]}<br /><span class="muted" style="font-weight:normal;">${d.getMonth() + 1}/${d.getDate()}</span></th>`)
    .join('');
  thead.innerHTML = `<tr><th>Employee</th>${headerCells}<th>Total</th><th>Cash Advance</th><th>Method</th></tr>`;

  if (employeeOptions.length === 0) {
    tbody.innerHTML = `<tr><td colspan="${dates.length + 4}" class="muted">No active employees found.</td></tr>`;
    return;
  }

  const lockedStyle = 'background:#e9ecef; color:#6c757d;';

  tbody.innerHTML = employeeOptions
    .map((e) => {
      const cells = dates
        .map((d) => {
          const key = `${e.username}|${toDateInputValue(d)}`;
          const existing = existingByKey[key];
          const value = existing ? existing.hours_worked : '';
          const locked = !!existing;
          return `<td><input type="number" class="bulk-hours" data-date="${toDateInputValue(d)}" min="0" max="24" step="0.5" value="${value}" style="width:70px;${locked ? lockedStyle : ''}" ${locked ? 'disabled' : ''} /></td>`;
        })
        .join('');
      const advance = advanceByUsername[e.username];
      const caValue = advance ? advance.amount : '';
      const caMethod = advance ? advance.method : 'Cash';
      const caLocked = !!advance;
      return `
        <tr data-username="${e.username}">
          <td>${e.display_name || e.username}</td>
          ${cells}
          <td class="row-total muted">0.00</td>
          <td><input type="number" class="bulk-ca" min="0" step="0.01" value="${caValue}" style="width:90px;${caLocked ? lockedStyle : ''}" placeholder="0.00" ${caLocked ? 'disabled' : ''} /></td>
          <td>
            <select class="bulk-ca-method" style="width:110px;${caLocked ? lockedStyle : ''}" ${caLocked ? 'disabled' : ''}>
              <option value="Cash" ${caMethod === 'Cash' ? 'selected' : ''}>Cash</option>
              <option value="Digital" ${caMethod === 'Digital' ? 'selected' : ''}>Digital (GCash)</option>
            </select>
          </td>
        </tr>
      `;
    })
    .join('');

  updateRowTotals();
}

function updateRowTotals() {
  document.querySelectorAll('#bulkEntryTableBody tr[data-username]').forEach((row) => {
    let total = 0;
    row.querySelectorAll('.bulk-hours').forEach((input) => {
      total += Number(input.value) || 0;
    });
    const totalCell = row.querySelector('.row-total');
    if (totalCell) totalCell.textContent = total.toFixed(2);
  });
}

function renderWeekRangeLabel(dates) {
  const start = dates[0];
  const end = dates[6];
  document.getElementById('weekRangeLabel').textContent =
    `${start.toLocaleDateString()} - ${end.toLocaleDateString()}`;
}

async function loadWeekGrid() {
  const errorEl = document.getElementById('bulkEntryError');
  errorEl.classList.add('hidden');

  const dates = weekDates(weekStart);
  renderWeekRangeLabel(dates);

  const [{ data, error }, { data: advanceData, error: advanceError }] = await Promise.all([
    supabaseClient.rpc('admin_list_timesheet_entries', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_username: null,
      p_date_start: toDateInputValue(dates[0]),
      p_date_end: toDateInputValue(dates[6]),
      p_page: 1,
      p_page_size: 500
    }),
    supabaseClient.rpc('admin_list_cash_advances', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_username: null,
      p_status: 'Outstanding',
      p_date_start: toDateInputValue(dates[0]),
      p_date_end: toDateInputValue(dates[6]),
      p_page: 1,
      p_page_size: 500
    })
  ]);

  if (error) {
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }
  if (advanceError) {
    errorEl.textContent = advanceError.message;
    errorEl.classList.remove('hidden');
    return;
  }

  const existingByKey = {};
  (data || []).forEach((t) => { existingByKey[`${t.username}|${t.work_date}`] = t; });

  const advanceByUsername = {};
  (advanceData || []).forEach((a) => { advanceByUsername[a.username] = { amount: a.amount, method: a.method }; });

  renderWeekGrid(dates, existingByKey, advanceByUsername);
}

// Super User only - client-side re-enable of every locked cell in the grid as currently shown, so
// a mistake can be corrected and re-saved without going through the All Entries list / Payroll
// Setup's Cash Advances journal. Nothing is changed in the database until Save All is clicked again.
function unlockEditing() {
  document.querySelectorAll('#bulkEntryTableBody .bulk-hours:disabled, #bulkEntryTableBody .bulk-ca:disabled, #bulkEntryTableBody .bulk-ca-method:disabled').forEach((input) => {
    input.disabled = false;
    input.style.background = '';
    input.style.color = '';
  });
}

async function saveBulkEntry() {
  const errorEl = document.getElementById('bulkEntryError');
  errorEl.classList.add('hidden');

  const entries = [];
  const caEntries = [];
  document.querySelectorAll('#bulkEntryTableBody tr[data-username]').forEach((row) => {
    const username = row.getAttribute('data-username');
    row.querySelectorAll('.bulk-hours:not(:disabled)').forEach((input) => {
      const hours = Number(input.value);
      if (!input.value || !(hours > 0)) return;
      entries.push({ username, work_date: input.getAttribute('data-date'), hours_worked: hours });
    });
    const caInput = row.querySelector('.bulk-ca:not(:disabled)');
    const caMethodInput = row.querySelector('.bulk-ca-method:not(:disabled)');
    if (caInput) caEntries.push({ username, amount: Number(caInput.value) || 0, method: caMethodInput ? caMethodInput.value : 'Cash' });
  });

  if (entries.length === 0 && caEntries.every((c) => !(c.amount > 0))) {
    errorEl.textContent = 'Nothing entered - fill in at least one hours or cash advance cell.';
    errorEl.classList.remove('hidden');
    return;
  }

  // Cells with data lock (gray out) once saved - see renderWeekGrid - so this is the one chance to
  // change what's about to be submitted.
  if (!confirm('Once saved this entry cannot be modified, continue saving?')) return;

  const saveBtn = document.getElementById('saveBulkEntryBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  if (entries.length > 0) {
    const { data, error } = await supabaseClient.rpc('admin_upsert_timesheet_entries_bulk', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_entries: entries
    });

    const result = Array.isArray(data) ? data[0] : data;
    if (error || !result || !result.success) {
      saveBtn.disabled = false;
      saveBtn.textContent = 'Save All';
      errorEl.textContent = error?.message || result?.message || 'Failed to save timesheet entries.';
      errorEl.classList.remove('hidden');
      return;
    }
  }

  // Cash Advance is a per-week amount, not per-day - a Thursday release date is assigned to any
  // brand-new advance; an existing Outstanding advance already dated inside this week is updated
  // (or removed, if its cell was cleared back to blank/0) instead of creating a duplicate.
  const dates = weekDates(weekStart);
  const { data: caData, error: caError } = await supabaseClient.rpc('admin_upsert_cash_advances_bulk', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_advance_date: toDateInputValue(dates[3]),
    p_week_start: toDateInputValue(dates[0]),
    p_week_end: toDateInputValue(dates[6]),
    p_entries: caEntries
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save All';

  const caResult = Array.isArray(caData) ? caData[0] : caData;
  if (caError || !caResult || !caResult.success) {
    errorEl.textContent = caError?.message || caResult?.message || 'Failed to save cash advances.';
    errorEl.classList.remove('hidden');
    return;
  }

  await loadWeekGrid();
  await loadEntries();
}

function renderEntryRows(entries) {
  currentEntries = entries || [];
  const tbody = document.getElementById('timesheetTableBody');

  if (!entries || entries.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" class="muted">No timesheet entries found.</td></tr>';
    return;
  }

  tbody.innerHTML = entries
    .map((t) => `
      <tr>
        <td>${t.display_name || t.username || ''}</td>
        <td>${formatDate(t.work_date)}</td>
        <td>${Number(t.hours_worked).toFixed(2)}</td>
        <td>${t.notes || ''}</td>
        <td>
          <button class="btn btn-secondary btn-sm" data-edit-id="${t.timesheet_id}" type="button">Edit</button>
          <button class="btn btn-danger btn-sm" data-delete-id="${t.timesheet_id}" type="button">Delete</button>
        </td>
      </tr>
    `)
    .join('');
}

async function loadEntries() {
  const tbody = document.getElementById('timesheetTableBody');
  tbody.innerHTML = '<tr><td colspan="5" class="muted">Loading...</td></tr>';

  const username = document.getElementById('filterUsername').value || null;
  const dateStart = document.getElementById('filterDateStart').value || null;
  const dateEnd = document.getElementById('filterDateEnd').value || null;

  const { data, error } = await supabaseClient.rpc('admin_list_timesheet_entries', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_username: username,
    p_date_start: dateStart,
    p_date_end: dateEnd,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="5" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderEntryRows(data);

  renderPaginationBar(
    document.getElementById('timesheetPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadEntries(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadEntries(); }
    }
  );
}

function openNewEntryModal() {
  document.getElementById('entryModalTitle').textContent = 'Add Timesheet Entry';
  document.getElementById('entryUsername').disabled = false;
  document.getElementById('entryUsername').value = employeeOptions[0]?.username || '';
  document.getElementById('entryWorkDate').value = '';
  document.getElementById('entryHoursWorked').value = 8;
  document.getElementById('entryNotes').value = '';
  document.getElementById('saveEntryBtn').dataset.editId = '';
  document.getElementById('entryError').classList.add('hidden');
  document.getElementById('entryModal').classList.remove('hidden');
}

function openEditEntryModal(timesheetId) {
  const entry = currentEntries.find((t) => t.timesheet_id === timesheetId);
  if (!entry) return;

  document.getElementById('entryModalTitle').textContent = 'Edit Timesheet Entry';
  document.getElementById('entryUsername').value = entry.username;
  document.getElementById('entryUsername').disabled = true;
  document.getElementById('entryWorkDate').value = entry.work_date;
  document.getElementById('entryHoursWorked').value = entry.hours_worked;
  document.getElementById('entryNotes').value = entry.notes || '';
  document.getElementById('saveEntryBtn').dataset.editId = timesheetId;
  document.getElementById('entryError').classList.add('hidden');
  document.getElementById('entryModal').classList.remove('hidden');
}

async function saveEntry() {
  const errorEl = document.getElementById('entryError');
  errorEl.classList.add('hidden');

  const editId = document.getElementById('saveEntryBtn').dataset.editId;
  const username = document.getElementById('entryUsername').value;
  const workDate = document.getElementById('entryWorkDate').value;
  const hoursWorked = Number(document.getElementById('entryHoursWorked').value);
  const notes = document.getElementById('entryNotes').value.trim();

  if (!username || !workDate || !(hoursWorked > 0)) {
    errorEl.textContent = 'Employee, work date, and hours worked (greater than zero) are all required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveEntryBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = editId
    ? await supabaseClient.rpc('admin_update_timesheet_entry', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_timesheet_id: editId,
        p_work_date: workDate,
        p_hours_worked: hoursWorked,
        p_notes: notes || null
      })
    : await supabaseClient.rpc('admin_add_timesheet_entry', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_username: username,
        p_work_date: workDate,
        p_hours_worked: hoursWorked,
        p_notes: notes || null
      });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save Entry';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to save timesheet entry.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('entryModal').classList.add('hidden');
  await loadWeekGrid();
  await loadEntries();
}

async function deleteEntry(timesheetId) {
  if (!confirm('Delete this timesheet entry?')) return;

  const { data, error } = await supabaseClient.rpc('admin_delete_timesheet_entry', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_timesheet_id: timesheetId
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    alert(error?.message || result?.message || 'Failed to delete timesheet entry.');
    return;
  }

  await loadWeekGrid();
  await loadEntries();
}

// New Payroll Run modal (same flow as payroll.html/payroll.js's "+ New Payroll Run") - lets the
// officer go straight from a filled-in week grid to creating the run that will read those hours.
async function loadCutoffSettingsOnce() {
  const { data, error } = await supabaseClient.rpc('admin_get_payroll_cutoff_settings', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    cutoffSettings = null;
    return;
  }
  cutoffSettings = Array.isArray(data) ? data[0] : data;
}

function computeCutoffDates(cutoffLetter, targetMonthValue) {
  if (!cutoffSettings || !targetMonthValue) return null;

  const [yearStr, monthStr] = targetMonthValue.split('-');
  const year = Number(yearStr);
  const month = Number(monthStr); // 1-12

  const startDay = cutoffLetter === 'A' ? cutoffSettings.cutoff_a_start_day : cutoffSettings.cutoff_b_start_day;
  const endDay = cutoffLetter === 'A' ? cutoffSettings.cutoff_a_end_day : cutoffSettings.cutoff_b_end_day;
  const payDay = cutoffLetter === 'A' ? cutoffSettings.cutoff_a_pay_day : cutoffSettings.cutoff_b_pay_day;
  const payIsLastDay = cutoffLetter === 'A' ? cutoffSettings.cutoff_a_pay_day_is_last_day_of_month : cutoffSettings.cutoff_b_pay_day_is_last_day_of_month;

  const periodEnd = new Date(year, month - 1, endDay);
  const periodStart = startDay > endDay ? new Date(year, month - 2, startDay) : new Date(year, month - 1, startDay);
  const payDate = payIsLastDay ? new Date(year, month, 0) : new Date(year, month - 1, payDay);

  return { periodStart, periodEnd, payDate };
}

function autofillDates() {
  const cutoffLetter = document.getElementById('newRunCutoff').value;
  const targetMonth = document.getElementById('newRunTargetMonth').value;
  const errorEl = document.getElementById('newRunError');

  const dates = computeCutoffDates(cutoffLetter, targetMonth);
  if (!dates) {
    errorEl.textContent = 'Pick a month, and make sure Cutoff Settings are configured in Payroll Setup.';
    errorEl.classList.remove('hidden');
    return;
  }
  errorEl.classList.add('hidden');

  document.getElementById('newRunPeriodStart').value = toDateInputValue(dates.periodStart);
  document.getElementById('newRunPeriodEnd').value = toDateInputValue(dates.periodEnd);
  document.getElementById('newRunPayDate').value = toDateInputValue(dates.payDate);
}

function autofillWeeklyDates() {
  const payDateValue = document.getElementById('newRunWeeklyPayDate').value;
  const errorEl = document.getElementById('newRunError');

  if (!payDateValue) {
    errorEl.textContent = 'Pick a pay date first.';
    errorEl.classList.remove('hidden');
    return;
  }

  const payDate = new Date(payDateValue + 'T00:00:00');
  if (payDate.getDay() !== 0) {
    errorEl.textContent = 'Weekly pay date should be a Sunday.';
    errorEl.classList.remove('hidden');
    return;
  }
  errorEl.classList.add('hidden');

  const periodStart = new Date(payDate);
  periodStart.setDate(periodStart.getDate() - 6);

  document.getElementById('newRunPeriodStart').value = toDateInputValue(periodStart);
  document.getElementById('newRunPeriodEnd').value = toDateInputValue(payDate);
  document.getElementById('newRunPayDate').value = toDateInputValue(payDate);
}

function updateCutoffRowVisibility() {
  const payCycle = document.getElementById('newRunPayCycle').value;
  document.getElementById('cutoffAutofillRow').classList.toggle('hidden', payCycle !== 'SemiMonthly');
  document.getElementById('weeklyAutofillRow').classList.toggle('hidden', payCycle !== 'Weekly');
}

// Defaults to the week currently shown in the grid, since that's almost always the week whose
// hours the officer just finished entering.
function openNewRunModal() {
  const dates = weekDates(weekStart);
  const sunday = dates[6];

  document.getElementById('newRunPayCycle').value = 'Weekly';
  document.getElementById('newRunCutoff').value = 'A';
  document.getElementById('newRunTargetMonth').value = `${weekStart.getFullYear()}-${String(weekStart.getMonth() + 1).padStart(2, '0')}`;
  document.getElementById('newRunWeeklyPayDate').value = toDateInputValue(sunday);
  document.getElementById('newRunError').classList.add('hidden');
  updateCutoffRowVisibility();
  document.getElementById('newRunModal').classList.remove('hidden');
  autofillWeeklyDates();
}

async function saveNewRun() {
  const errorEl = document.getElementById('newRunError');
  errorEl.classList.add('hidden');

  const payCycle = document.getElementById('newRunPayCycle').value;
  const periodStart = document.getElementById('newRunPeriodStart').value || null;
  const periodEnd = document.getElementById('newRunPeriodEnd').value || null;
  const payDate = document.getElementById('newRunPayDate').value || null;

  if (!periodStart || !periodEnd) {
    errorEl.textContent = 'Period start and end are required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveRunBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Creating...';

  const { data, error } = await supabaseClient.rpc('admin_create_payroll_run', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_pay_cycle: payCycle,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_pay_date: payDate
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Create Run';

  if (error || !data) {
    errorEl.textContent = error?.message || 'Failed to create payroll run.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('newRunModal').classList.add('hidden');
  window.location.href = `payroll-run.html?run=${data}`;
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Timesheets');

  if (!session.isSuperUser && !session.isPayrollOfficer) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  document.getElementById('timesheetsContent').classList.remove('hidden');
  document.getElementById('unlockEditingBtn').classList.toggle('hidden', !session.isSuperUser);
  await loadEmployeeOptionsOnce();
  await loadEntries();
  await loadCutoffSettingsOnce();

  weekStart = getMondayOf(new Date());
  await loadWeekGrid();

  document.getElementById('prevWeekBtn').addEventListener('click', () => {
    weekStart.setDate(weekStart.getDate() - 7);
    loadWeekGrid();
  });
  document.getElementById('nextWeekBtn').addEventListener('click', () => {
    weekStart.setDate(weekStart.getDate() + 7);
    loadWeekGrid();
  });

  document.getElementById('createRunFromTimesheetsBtn').addEventListener('click', openNewRunModal);
  document.getElementById('closeNewRunBtn').addEventListener('click', () =>
    document.getElementById('newRunModal').classList.add('hidden')
  );
  document.getElementById('saveRunBtn').addEventListener('click', saveNewRun);
  document.getElementById('newRunPayCycle').addEventListener('change', updateCutoffRowVisibility);
  document.getElementById('autofillDatesBtn').addEventListener('click', autofillDates);
  document.getElementById('autofillWeeklyDatesBtn').addEventListener('click', autofillWeeklyDates);
  document.getElementById('bulkEntryTableBody').addEventListener('input', (e) => {
    if (e.target.classList.contains('bulk-hours')) updateRowTotals();
  });
  document.getElementById('saveBulkEntryBtn').addEventListener('click', saveBulkEntry);
  document.getElementById('unlockEditingBtn').addEventListener('click', unlockEditing);

  document.getElementById('toggleAllEntriesBtn').addEventListener('click', (e) => {
    const section = document.getElementById('allEntriesSection');
    const willBecomeVisible = section.classList.contains('hidden');
    section.classList.toggle('hidden', !willBecomeVisible);
    e.target.textContent = willBecomeVisible ? 'Hide All Entries' : 'Show All Entries';
  });

  document.getElementById('applyFiltersBtn').addEventListener('click', () => { currentPage = 1; loadEntries(); });
  document.getElementById('newEntryBtn').addEventListener('click', openNewEntryModal);
  document.getElementById('closeEntryModalBtn').addEventListener('click', () =>
    document.getElementById('entryModal').classList.add('hidden')
  );
  document.getElementById('saveEntryBtn').addEventListener('click', saveEntry);

  document.getElementById('timesheetTableBody').addEventListener('click', (e) => {
    const editBtn = e.target.closest('[data-edit-id]');
    if (editBtn) return openEditEntryModal(editBtn.getAttribute('data-edit-id'));
    const deleteBtn = e.target.closest('[data-delete-id]');
    if (deleteBtn) return deleteEntry(deleteBtn.getAttribute('data-delete-id'));
  });
})();
