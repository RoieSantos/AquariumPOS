// Delivery Setup page logic (super users only) - one fixed route per day of week, optionally
// tagged to multiple Warehouses and/or Vendors (Ctrl/Cmd-click multi-select). See
// supabase_delivery_route_schedule.sql for the RPCs and the "informational only" trust model
// (does not restrict order assignment on the Delivery page). Each Save fully replaces that day's
// tag set - not an incremental add.
let currentSession = null;
let warehouseOptions = []; // [{id, name}], loaded once via staff_search_warehouses
let vendorOptions = []; // [{code, name}], loaded once via admin_list_vendors

function escapeHtml(value) {
  return (value ?? '').toString()
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function loadDropdownOptions() {
  const [warehouseResult, vendorResult] = await Promise.all([
    supabaseClient.rpc('staff_search_warehouses', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_search: null,
      p_limit: 100
    }),
    supabaseClient.rpc('admin_list_vendors', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_search: null,
      p_page: 1,
      p_page_size: 500
    })
  ]);

  warehouseOptions = (warehouseResult.data || []).map((w) => ({ id: w.id, name: w.name }));
  vendorOptions = (vendorResult.data || [])
    .filter((v) => v.is_active)
    .map((v) => ({ code: v.vendor_code, name: v.name }));
}

// The "Clear" button just deselects every option in the multi-select client-side - it does NOT
// call the RPC on its own. The row's existing Save button is still what persists it (an empty
// selection saved this way correctly removes that day's Warehouse/Vendor tags - see
// admin_upsert_delivery_route_schedule's delete-then-conditionally-reinsert logic). Per "let me
// clear the vendor / warehouse that has been assigned already" - deselecting every option by
// Ctrl/Cmd-click in a native multi-select isn't obvious, so this is the one-click alternative.
function multiSelectHtml(options, valueKey, labelKey, selectedValues, dayOfWeek, field) {
  const selected = new Set(selectedValues || []);
  const opts = options
    .map((o) => `<option value="${escapeHtml(o[valueKey])}" ${selected.has(o[valueKey]) ? 'selected' : ''}>${escapeHtml(o[labelKey])}</option>`)
    .join('');
  return `
    <div>
      <select class="route-field-input" multiple size="4" data-day="${dayOfWeek}" data-field="${field}" style="min-width:160px;">${opts}</select>
      <div><button class="btn btn-secondary btn-sm" data-action="clear-multiselect" data-day="${dayOfWeek}" data-field="${field}" type="button" style="margin-top:4px;">Clear</button></div>
    </div>
  `;
}

function renderRouteScheduleRows(days) {
  const tbody = document.getElementById('routeScheduleTableBody');

  tbody.innerHTML = (days || [])
    .map((d) => {
      if (d.day_of_week === 1) {
        return `
          <tr class="muted">
            <td>${escapeHtml(d.day_name)}</td>
            <td colspan="4">No Delivery - no truck runs on Mondays</td>
            <td></td>
          </tr>
        `;
      }

      return `
        <tr data-day="${d.day_of_week}">
          <td>${escapeHtml(d.day_name)}</td>
          <td><input type="text" class="route-field-input" data-day="${d.day_of_week}" data-field="routeName" value="${escapeHtml(d.route_name || '')}" placeholder="e.g. GMA Route" style="width:200px;" /></td>
          <td>${multiSelectHtml(warehouseOptions, 'id', 'name', d.warehouse_ids, d.day_of_week, 'warehouseIds')}</td>
          <td>${multiSelectHtml(vendorOptions, 'code', 'name', d.vendor_codes, d.day_of_week, 'vendorCodes')}</td>
          <td>${d.updated_at_utc ? new Date(d.updated_at_utc).toLocaleString() : '<span class="muted">Never</span>'}</td>
          <td>
            <button class="btn btn-secondary btn-sm" data-action="save-route" data-day="${d.day_of_week}" type="button">Save</button>
            <span class="route-saved muted hidden" data-day="${d.day_of_week}">Saved</span>
          </td>
        </tr>
      `;
    })
    .join('');

  tbody.querySelectorAll('button[data-action="save-route"]').forEach((btn) => {
    btn.addEventListener('click', () => saveRoute(btn.dataset.day));
  });

  tbody.querySelectorAll('button[data-action="clear-multiselect"]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const select = tbody.querySelector(`select[data-day="${btn.dataset.day}"][data-field="${btn.dataset.field}"]`);
      Array.from(select.options).forEach((o) => { o.selected = false; });
    });
  });
}

function selectedValues(selectEl) {
  return Array.from(selectEl.selectedOptions).map((o) => o.value);
}

async function saveRoute(dayOfWeek) {
  const row = document.querySelector(`tr[data-day="${dayOfWeek}"]`);
  const routeName = row.querySelector('[data-field="routeName"]').value;
  const warehouseIds = selectedValues(row.querySelector('[data-field="warehouseIds"]'));
  const vendorCodes = selectedValues(row.querySelector('[data-field="vendorCodes"]'));
  const savedLabel = document.querySelector(`.route-saved[data-day="${dayOfWeek}"]`);

  const { data, error } = await supabaseClient.rpc('admin_upsert_delivery_route_schedule', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_day_of_week: Number(dayOfWeek),
    p_route_name: routeName,
    p_warehouse_ids: warehouseIds,
    p_vendor_codes: vendorCodes
  });

  const result = Array.isArray(data) ? data[0] : data;

  if (error || !result?.success) {
    window.alert(`Failed to save route: ${error ? error.message : result?.message}`);
    return;
  }

  savedLabel.classList.remove('hidden');
  setTimeout(() => savedLabel.classList.add('hidden'), 1500);
  await loadRouteSchedule();
}

async function loadRouteSchedule() {
  const { data, error } = await supabaseClient.rpc('admin_list_delivery_route_schedule', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    document.getElementById('routeScheduleTableBody').innerHTML = `<tr><td colspan="6" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderRouteScheduleRows(data);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Delivery Setup');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Delivery Setup.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  await loadDropdownOptions();
  await loadRouteSchedule();
})();
