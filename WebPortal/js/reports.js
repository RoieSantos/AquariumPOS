// Reports page logic: Month End + Expense Report tabs (read-only drill-down).

function formatDate(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleDateString();
}

function formatDateTime(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return value;
  return d.toLocaleString();
}

function formatMoney(value) {
  const n = Number(value);
  if (isNaN(n)) return value ?? '';
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function showTab(tab) {
  const monthEndTab = document.getElementById('monthEndTab');
  const expenseTab = document.getElementById('expenseTab');
  const monthEndBtn = document.getElementById('tabMonthEndBtn');
  const expenseBtn = document.getElementById('tabExpenseBtn');

  if (tab === 'monthEnd') {
    monthEndTab.classList.remove('hidden');
    expenseTab.classList.add('hidden');
    monthEndBtn.className = 'btn btn-primary btn-sm';
    expenseBtn.className = 'btn btn-secondary btn-sm';
  } else {
    monthEndTab.classList.add('hidden');
    expenseTab.classList.remove('hidden');
    monthEndBtn.className = 'btn btn-secondary btn-sm';
    expenseBtn.className = 'btn btn-primary btn-sm';
  }
}

async function loadMonthEndHeaders() {
  const tbody = document.getElementById('monthEndHeaderBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient
    .from('MonthEndHeader')
    .select('*')
    .order('PostedAtUtc', { ascending: false })
    .limit(200);

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No month end reports found.</td></tr>';
    return;
  }

  tbody.innerHTML = data
    .map((r) => `
      <tr class="clickable-row" data-doc-no="${encodeURIComponent(r.DocumentNo || '')}">
        <td>${r.DocumentNo || ''}</td>
        <td>${formatDate(r.FromDate)}</td>
        <td>${formatDate(r.ToDate)}</td>
        <td>${r.WarehouseName || ''}</td>
        <td>${r.TotalLines ?? ''}</td>
        <td>${r.PostedBy || ''}</td>
        <td>${formatDateTime(r.PostedAtUtc)}</td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('tr[data-doc-no]').forEach((row) => {
    row.addEventListener('click', () => openMonthEndLines(decodeURIComponent(row.dataset.docNo)));
  });
}

async function openMonthEndLines(docNo) {
  document.getElementById('monthEndLinesTitle').textContent = `Month End ${docNo}`;
  const body = document.getElementById('monthEndLinesBody');
  body.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';
  document.getElementById('monthEndLinesModal').classList.remove('hidden');

  const { data, error } = await supabaseClient
    .from('MonthEndLines')
    .select('*')
    .eq('DocumentNo', docNo)
    .order('LineNo', { ascending: true });

  if (error) {
    body.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    body.innerHTML = '<tr><td colspan="7" class="muted">No line items.</td></tr>';
    return;
  }

  body.innerHTML = data
    .map((l) => `
      <tr>
        <td>${l.ItemNo || ''}</td>
        <td>${l.Description || ''}</td>
        <td>${l.QtyOnHand ?? ''}</td>
        <td>${l.OpeningStock ?? ''}</td>
        <td>${l.PhysicalQtyOnHand ?? ''}</td>
        <td>${l.Variance ?? ''}</td>
        <td>${l.ShrinkagePercent ?? ''}</td>
      </tr>
    `)
    .join('');
}

async function loadExpenseHeaders() {
  const tbody = document.getElementById('expenseHeaderBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient
    .from('ExpenseReportHeader')
    .select('*')
    .order('GeneratedDate', { ascending: false })
    .limit(200);

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No expense reports found.</td></tr>';
    return;
  }

  tbody.innerHTML = data
    .map((r) => `
      <tr class="clickable-row" data-doc-no="${encodeURIComponent(r.DocumentNo || '')}">
        <td>${r.DocumentNo || ''}</td>
        <td>${formatDate(r.GeneratedDate)}</td>
        <td>${formatDate(r.FromDate)}</td>
        <td>${formatDate(r.ToDate)}</td>
        <td>${r.WarehouseName || ''}</td>
        <td>${r.GeneratedBy || ''}</td>
        <td>${formatMoney(r.GrandTotal)}</td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('tr[data-doc-no]').forEach((row) => {
    row.addEventListener('click', () => openExpenseLines(decodeURIComponent(row.dataset.docNo)));
  });
}

async function openExpenseLines(docNo) {
  document.getElementById('expenseLinesTitle').textContent = `Expense Report ${docNo}`;
  const body = document.getElementById('expenseLinesBody');
  body.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';
  document.getElementById('expenseLinesModal').classList.remove('hidden');

  const { data, error } = await supabaseClient
    .from('ExpenseReportLines')
    .select('*')
    .eq('DocumentNo', docNo)
    .order('LineNo', { ascending: true });

  if (error) {
    body.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    body.innerHTML = '<tr><td colspan="7" class="muted">No line items.</td></tr>';
    return;
  }

  body.innerHTML = data
    .map((l) => `
      <tr>
        <td>${l.Category || ''}</td>
        <td>${l.Description || ''}</td>
        <td>${l.UserId || ''}</td>
        <td>${formatDate(l.TransactionDate)}</td>
        <td>${l.TransactionTime || ''}</td>
        <td>${l.Quantity ?? ''}</td>
        <td>${formatMoney(l.Amount)}</td>
      </tr>
    `)
    .join('');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  renderTopNav('Reports');

  document.getElementById('tabMonthEndBtn').addEventListener('click', () => showTab('monthEnd'));
  document.getElementById('tabExpenseBtn').addEventListener('click', () => showTab('expense'));
  document.getElementById('refreshReportsBtn').addEventListener('click', () => {
    loadMonthEndHeaders();
    loadExpenseHeaders();
  });
  document.getElementById('closeMonthEndLinesBtn').addEventListener('click', () =>
    document.getElementById('monthEndLinesModal').classList.add('hidden')
  );
  document.getElementById('closeExpenseLinesBtn').addEventListener('click', () =>
    document.getElementById('expenseLinesModal').classList.add('hidden')
  );

  showTab('monthEnd');
  await loadMonthEndHeaders();
  await loadExpenseHeaders();
})();
