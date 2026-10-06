// Maker Assignments page (super users only, read-only) - every open Tank Maker / Stand Maker
// assignment grouped by maker, from admin_list_maker_assignments
// (sql/supabase_maker_assignments_view.sql). Filtering is client-side: the open list is small.
let currentSession = null;
let allRows = [];
let searchDebounceHandle = null;
const collapsedMakers = new Set();

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function formatDateTime(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleString();
}

// Where the order opens: its lines page for online / advance, the card for a production order.
function refLink(r) {
  const no = encodeURIComponent(r.ref_no);
  if (r.source === 'Advance') return `advance-order-lines.html?transaction=${no}`;
  if (r.source === 'Production') return `production-orders.html?no=${no}`;
  return `online-order-lines.html?order=${no}`;
}

function statusBadge(status) {
  const cls = status === 'Rework' ? 'badge-danger' : status === 'Pending' ? 'badge-warning' : 'badge-success';
  return `<span class="badge ${cls}">${escapeHtml(status)}</span>`;
}

function readFilters() {
  return {
    search: document.getElementById('makerSearchInput').value.trim().toLowerCase(),
    source: document.getElementById('makerSourceFilter').value,
    part: document.getElementById('makerPartFilter').value,
    hideDone: document.getElementById('makerHideDone').checked,
    showIdle: document.getElementById('makerShowIdle').checked
  };
}

function renderStatCards(rows) {
  const work = rows.filter((r) => r.source);
  const count = (s) => work.filter((r) => r.part_status === s).length;
  const busyMakers = new Set(work.filter((r) => r.part_status !== 'Done').map((r) => r.maker)).size;
  const allMakers = new Set(rows.map((r) => r.maker)).size;
  document.getElementById('makerStatCards').innerHTML = `
    <div class="stat-card stat-printed"><div class="stat-label">Pending parts</div><div class="stat-value">${count('Pending')}</div></div>
    <div class="stat-card stat-cancelled"><div class="stat-label">Rework</div><div class="stat-value">${count('Rework')}</div></div>
    <div class="stat-card stat-shipped"><div class="stat-label">Done (not shipped yet)</div><div class="stat-value">${count('Done')}</div></div>
    <div class="stat-card stat-confirmed"><div class="stat-label">Makers busy</div><div class="stat-value">${busyMakers} / ${allMakers}</div></div>`;
}

function render() {
  const f = readFilters();
  const container = document.getElementById('makerGroups');

  // Group by maker first (idle rows included), then filter each group's rows.
  const groups = new Map();
  for (const r of allRows) {
    if (!groups.has(r.maker)) groups.set(r.maker, { maker: r.maker, name: r.maker_name, rows: [] });
    if (r.source) groups.get(r.maker).rows.push(r);
  }

  const html = [];
  for (const g of groups.values()) {
    const makerMatches = !f.search || `${g.name} ${g.maker}`.toLowerCase().includes(f.search);
    const rows = g.rows.filter((r) =>
      (!f.source || r.source === f.source) &&
      (!f.part || r.part === f.part) &&
      (!f.hideDone || r.part_status !== 'Done') &&
      (makerMatches || `${r.ref_no} ${r.customer || ''}`.toLowerCase().includes(f.search))
    );
    const isIdle = g.rows.length === 0;
    if (isIdle ? !(f.showIdle && makerMatches && !f.source && !f.part) : rows.length === 0) continue;

    const n = (s) => rows.filter((r) => r.part_status === s).length;
    const collapsed = collapsedMakers.has(g.maker);
    html.push(`
      <div class="card maker-group${collapsed ? ' collapsed' : ''}" data-maker="${escapeHtml(g.maker)}">
        <div class="maker-group-head">
          <h2><span class="maker-chevron">&#9662;</span> ${escapeHtml(g.name)} <span class="muted" style="font-weight:normal;">(${escapeHtml(g.maker)})</span></h2>
          <div class="maker-counts">
            ${isIdle ? '<span class="badge badge-neutral">Idle</span>' : `
              <span class="badge badge-warning">${n('Pending')} pending</span>
              ${n('Rework') ? `<span class="badge badge-danger">${n('Rework')} rework</span>` : ''}
              <span class="badge badge-success">${n('Done')} done</span>`}
          </div>
        </div>
        ${isIdle ? '<p class="muted maker-idle">No open assignments.</p>' : `
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Source</th><th>Order</th><th>Customer / Description</th><th>Part</th><th>Part Status</th>
                <th>Order Status</th><th>Warehouse</th><th>Date</th><th>Done At</th><th>Updated</th>
              </tr>
            </thead>
            <tbody>
              ${rows.map((r) => `
                <tr>
                  <td>${escapeHtml(r.source)}</td>
                  <td><a href="${refLink(r)}">${escapeHtml(r.ref_no)}</a></td>
                  <td>${escapeHtml(r.customer)}</td>
                  <td>${r.part === 'tank' ? 'Tank' : 'Stand'}</td>
                  <td>${statusBadge(r.part_status)}${r.part_status === 'Rework' && r.rework_reason ? `<div class="rework-note">${escapeHtml(r.rework_reason)}</div>` : ''}</td>
                  <td>${escapeHtml(r.order_status)}</td>
                  <td>${escapeHtml(r.warehouse)}</td>
                  <td>${escapeHtml(r.order_date)}</td>
                  <td>${formatDateTime(r.done_at)}</td>
                  <td>${formatDateTime(r.updated_at)}</td>
                </tr>`).join('')}
            </tbody>
          </table>
        </div>`}
      </div>`);
  }

  container.innerHTML = html.length ? html.join('') : '<p class="muted">No assignments match the filters.</p>';
}

async function loadAssignments() {
  const container = document.getElementById('makerGroups');
  container.innerHTML = '<p class="muted">Loading...</p>';

  const { data, error } = await supabaseClient.rpc('admin_list_maker_assignments', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password
  });

  if (error) {
    container.innerHTML = `<p class="error-text">${escapeHtml(error.message)}</p>`;
    return;
  }

  allRows = data || [];
  renderStatCards(allRows);
  render();
}

function wireFilters() {
  document.getElementById('makerSearchInput').addEventListener('input', () => {
    clearTimeout(searchDebounceHandle);
    searchDebounceHandle = setTimeout(render, 200);
  });
  ['makerSourceFilter', 'makerPartFilter', 'makerHideDone', 'makerShowIdle'].forEach((id) =>
    document.getElementById(id).addEventListener('change', render));
  document.getElementById('makerRefreshBtn').addEventListener('click', loadAssignments);

  // Click a maker's header to collapse / expand their table.
  document.getElementById('makerGroups').addEventListener('click', (e) => {
    const head = e.target.closest('.maker-group-head');
    if (!head) return;
    const group = head.parentElement;
    const maker = group.dataset.maker;
    if (collapsedMakers.has(maker)) collapsedMakers.delete(maker); else collapsedMakers.add(maker);
    group.classList.toggle('collapsed');
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Maker Assignments');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Maker Assignments.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');
  // ?maker=<username> - from the Dashboard's Production group maker table: pre-fills the search.
  const makerParam = new URLSearchParams(window.location.search).get('maker');
  if (makerParam) document.getElementById('makerSearchInput').value = makerParam;
  wireFilters();
  await loadAssignments();
})();
