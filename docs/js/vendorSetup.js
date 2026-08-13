// Vendor Setup page logic (super users only). Manages the Vendors master list plus, per vendor,
// its Bills (what's owed) and Payments (what's been paid, optionally applied to a bill) - full
// accounts payable, per "is it possible to create me a vendor table master? this will allow me
// to pay them / tag the item and etc". Item-to-vendor tagging itself lives on the Item Setup
// page's factbox (docs/js/itemSetup.js), not here - this page only maintains the vendor list
// vendors are picked from.
//
// No password re-entry prompt - super user status alone is enough, same trust model as every
// other Setup page (reuses the password captured at login, session.password, see auth.js).
let currentSession = null;
let currentVendors = [];
let currentPage = 1;
let currentPageSize = 50;

let manageVendorCode = null;
let manageVendorBills = [];

function formatMoney(value) {
  const amount = Number(value) || 0;
  return '₱' + amount.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function billStatusBadge(bill) {
  if (bill.is_void) return '<span class="badge badge-neutral">Void</span>';
  if (Number(bill.balance) <= 0) return '<span class="badge badge-success">Paid</span>';
  if (Number(bill.paid_amount) > 0) return '<span class="badge badge-warning">Partial</span>';
  return '<span class="badge badge-danger">Unpaid</span>';
}

// ---------------------------------------------------------------------------
// Vendor list

function renderVendorRows(vendors) {
  currentVendors = vendors || [];
  const tbody = document.getElementById('vendorTableBody');

  if (!vendors || vendors.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" class="muted">No vendors found.</td></tr>';
    return;
  }

  tbody.innerHTML = vendors
    .map((v) => `
      <tr>
        <td>${v.vendor_code || ''}</td>
        <td>${v.name || ''}</td>
        <td>${v.contact_person || ''}</td>
        <td>${v.phone || ''}</td>
        <td>${v.address || ''}</td>
        <td style="text-align:right;">${formatMoney(v.balance)}</td>
        <td><span class="badge ${v.is_active ? 'badge-success' : 'badge-danger'}">${v.is_active ? 'Active' : 'Inactive'}</span></td>
        <td><button class="btn btn-secondary btn-sm" data-manage-code="${v.vendor_code}" type="button">Manage</button></td>
      </tr>
    `)
    .join('');
}

let vendorSearchDebounceHandle = null;
let currentVendorSearch = '';

async function loadVendors() {
  const tbody = document.getElementById('vendorTableBody');
  tbody.innerHTML = '<tr><td colspan="8" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: currentVendorSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="8" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderVendorRows(data);

  renderPaginationBar(
    document.getElementById('vendorPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadVendors(); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadVendors(); }
    }
  );
}

function wireVendorSearch() {
  document.getElementById('vendorSearchInput').addEventListener('input', (e) => {
    const value = e.target.value.trim();
    clearTimeout(vendorSearchDebounceHandle);
    vendorSearchDebounceHandle = setTimeout(() => {
      currentVendorSearch = value;
      currentPage = 1;
      loadVendors();
    }, 300);
  });
}

// ---------------------------------------------------------------------------
// Export to Excel / Import from Excel
// Plain CSV (not a real .xlsx), same convention as Online Orders' own "Export to Excel"
// (js/onlineOrders.js) - Excel opens it natively with no extra library/CDN dependency. Import
// reads that same header layout back in via admin_bulk_upsert_vendors (supabase_vendor_bulk_
// import.sql), upserting by Vendor Code - per "export to excel and import to excel this way I
// can update / insert using excel".

function escapeCsvValue(value) {
  const str = value === null || value === undefined ? '' : String(value);
  return /[",\n]/.test(str) ? '"' + str.replace(/"/g, '""') + '"' : str;
}

// Exports every vendor matching the CURRENT search, not just the page on screen - loops
// admin_list_vendors at its own max page size (500) until exhausted, same pagination-loop
// pattern as exportOrdersToExcel.
async function exportVendorsToExcel() {
  const btn = document.getElementById('exportExcelBtn');
  const exportPageSize = 500;
  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Exporting...';

  try {
    const allRows = [];
    let page = 1;
    for (;;) {
      const { data, error } = await supabaseClient.rpc('admin_list_vendors', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_search: currentVendorSearch || null,
        p_page: page,
        p_page_size: exportPageSize
      });

      if (error) {
        alert('Export failed: ' + error.message);
        return;
      }

      allRows.push(...(data || []));
      if (!data || data.length < exportPageSize) break;
      page += 1;
    }

    if (allRows.length === 0) {
      alert('No vendors to export for the current filters.');
      return;
    }

    const headers = [
      'Vendor Code', 'Name', 'Contact Person', 'Phone', 'Email', 'Address', 'Payment Terms',
      'Notes', 'Active', 'Total Billed', 'Total Paid', 'Balance', 'Created At', 'Updated At'
    ];
    const csvLines = [headers.map(escapeCsvValue).join(',')];
    allRows.forEach((v) => {
      csvLines.push([
        v.vendor_code,
        v.name,
        v.contact_person,
        v.phone,
        v.email,
        v.address,
        v.payment_terms,
        v.notes,
        v.is_active ? 'Yes' : 'No',
        v.total_billed,
        v.total_paid,
        v.balance,
        v.created_at_utc ? new Date(v.created_at_utc).toLocaleString() : '',
        v.updated_at_utc ? new Date(v.updated_at_utc).toLocaleString() : ''
      ].map(escapeCsvValue).join(','));
    });

    const blob = new Blob(['﻿' + csvLines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
    const link = document.createElement('a');
    link.href = url;
    link.download = `vendors-${stamp}.csv`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}

// Blank starter file for Import from Excel - only the columns admin_bulk_upsert_vendors actually
// reads (csvRowsToVendorObjects below), unlike the full Export to Excel which also includes
// read-only computed columns (Total Billed/Paid/Balance, Created/Updated At) that Import ignores
// and would just be confusing to fill in. One example row shows the expected format - Vendor
// Code is the upsert key (existing code -> update, new code -> insert), Active is Yes/No.
function downloadVendorImportTemplate() {
  const headers = ['Vendor Code', 'Name', 'Contact Person', 'Phone', 'Email', 'Address', 'Payment Terms', 'Notes', 'Active'];
  const exampleRow = ['V001', 'Sample Vendor Co.', 'Juan Dela Cruz', '09171234567', 'vendor@example.com', '123 Main St, Quezon City', 'Net 30', 'Preferred supplier', 'Yes'];

  const csvLines = [headers.map(escapeCsvValue).join(','), exampleRow.map(escapeCsvValue).join(',')];
  const blob = new Blob(['﻿' + csvLines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = 'vendor-import-template.csv';
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}

// RFC4180-ish CSV parser (handles quoted fields containing commas/newlines/escaped "" quotes) -
// needed because Vendor Notes/Address fields can legitimately contain commas, and a plain
// split(',')/split('\n') would break on those exactly the way escapeCsvValue above guards
// against when exporting. No external library - this file already avoids one for export.
function parseCsv(text) {
  if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1); // strip UTF-8 BOM if present

  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (inQuotes) {
      if (char === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; }
      } else {
        field += char;
      }
    } else if (char === '"') {
      inQuotes = true;
    } else if (char === ',') {
      row.push(field); field = '';
    } else if (char === '\r') {
      // ignore - a following \n (CRLF) closes the row on its own
    } else if (char === '\n') {
      row.push(field); field = '';
      rows.push(row); row = [];
    } else {
      field += char;
    }
  }
  if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row); }

  return rows.filter((r) => !(r.length === 1 && r[0].trim() === ''));
}

// Maps parsed CSV rows to admin_bulk_upsert_vendors' expected object shape by header NAME
// (case-insensitive), not column position - so a re-ordered or partially-trimmed-down export
// (e.g. someone deletes the Balance/Created At columns before re-importing) still works, as long
// as "Vendor Code" and "Name" are present.
function csvRowsToVendorObjects(rows) {
  if (rows.length === 0) return [];

  const headers = rows[0].map((h) => h.trim().toLowerCase());
  const col = (label) => headers.indexOf(label);
  const idx = {
    vendor_code: col('vendor code'),
    name: col('name'),
    contact_person: col('contact person'),
    phone: col('phone'),
    email: col('email'),
    address: col('address'),
    payment_terms: col('payment terms'),
    notes: col('notes'),
    is_active: col('active')
  };

  if (idx.vendor_code === -1 || idx.name === -1) {
    throw new Error('That file must have "Vendor Code" and "Name" columns (matching Export to Excel\'s headers).');
  }

  const at = (r, i) => (i > -1 ? (r[i] || '').trim() : '');

  return rows.slice(1)
    .filter((r) => r.some((v) => v.trim() !== ''))
    .map((r) => ({
      vendor_code: at(r, idx.vendor_code),
      name: at(r, idx.name),
      contact_person: at(r, idx.contact_person),
      phone: at(r, idx.phone),
      email: at(r, idx.email),
      address: at(r, idx.address),
      payment_terms: at(r, idx.payment_terms),
      notes: at(r, idx.notes),
      is_active: idx.is_active === -1 || !/^(no|false|0|inactive)$/i.test(at(r, idx.is_active))
    }));
}

async function importVendorsFromExcel(file) {
  const btn = document.getElementById('importExcelBtn');
  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Importing...';

  try {
    const text = await file.text();
    let vendors;
    try {
      vendors = csvRowsToVendorObjects(parseCsv(text));
    } catch (err) {
      alert(err.message);
      return;
    }

    if (vendors.length === 0) {
      alert('No vendor rows found in that file.');
      return;
    }

    const { data, error } = await supabaseClient.rpc('admin_bulk_upsert_vendors', {
      p_admin_username: currentSession.username,
      p_admin_password: currentSession.password,
      p_vendors: vendors
    });

    if (error) {
      alert('Import failed: ' + error.message);
      return;
    }

    const result = Array.isArray(data) ? data[0] : data;
    const errorNote = result?.errors?.length ? `\n\nSkipped:\n${result.errors.join('\n')}` : '';
    alert(`Import complete.\nInserted: ${result?.inserted_count ?? 0}\nUpdated: ${result?.updated_count ?? 0}\nSkipped: ${result?.skipped_count ?? 0}${errorNote}`);

    await loadVendors();
  } finally {
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}

// ---------------------------------------------------------------------------
// New vendor modal

function openNewVendorModal() {
  document.getElementById('newVendorCode').value = '';
  document.getElementById('newVendorName').value = '';
  document.getElementById('newVendorContact').value = '';
  document.getElementById('newVendorPhone').value = '';
  document.getElementById('newVendorEmail').value = '';
  document.getElementById('newVendorAddress').value = '';
  document.getElementById('newVendorTerms').value = '';
  document.getElementById('newVendorNotes').value = '';
  document.getElementById('newVendorError').classList.add('hidden');
  document.getElementById('newVendorModal').classList.remove('hidden');
}

async function saveNewVendor() {
  const errorEl = document.getElementById('newVendorError');
  errorEl.classList.add('hidden');

  const vendorCode = document.getElementById('newVendorCode').value.trim();
  const name = document.getElementById('newVendorName').value.trim();

  if (!vendorCode) {
    errorEl.textContent = 'Vendor Code is required.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (!name) {
    errorEl.textContent = 'Name is required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveNewVendorBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_create_vendor', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_vendor_code: vendorCode,
    p_name: name,
    p_contact_person: document.getElementById('newVendorContact').value.trim() || null,
    p_phone: document.getElementById('newVendorPhone').value.trim() || null,
    p_email: document.getElementById('newVendorEmail').value.trim() || null,
    p_address: document.getElementById('newVendorAddress').value.trim() || null,
    p_payment_terms: document.getElementById('newVendorTerms').value.trim() || null,
    p_notes: document.getElementById('newVendorNotes').value.trim() || null
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Create Vendor';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to create vendor.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('newVendorModal').classList.add('hidden');
  await loadVendors();
}

// ---------------------------------------------------------------------------
// Manage vendor modal - info edit + bills + payments

function renderManageVendorSummary(vendor) {
  document.getElementById('manageVendorBilled').textContent = formatMoney(vendor.total_billed);
  document.getElementById('manageVendorPaid').textContent = formatMoney(vendor.total_paid);
  document.getElementById('manageVendorBalance').textContent = formatMoney(vendor.balance);
}

// Re-fetches just this vendor's row (search matches the code) so the summary tiles and the
// list behind the modal both reflect the latest balance after a bill/payment change, without a
// dedicated single-vendor RPC.
async function refreshManageVendor(vendorCode) {
  const { data, error } = await supabaseClient.rpc('admin_list_vendors', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: vendorCode,
    p_page: 1,
    p_page_size: 50
  });

  if (error || !data) return;
  const vendor = data.find((v) => v.vendor_code === vendorCode);
  if (vendor) renderManageVendorSummary(vendor);

  await loadVendors();
}

function openManageVendorModal(vendorCode) {
  const vendor = currentVendors.find((v) => v.vendor_code === vendorCode);
  if (!vendor) return;

  manageVendorCode = vendorCode;

  document.getElementById('manageVendorTitle').textContent = `${vendor.vendor_code} - ${vendor.name}`;
  document.getElementById('manageVendorCode').value = vendor.vendor_code || '';
  document.getElementById('manageVendorName').value = vendor.name || '';
  document.getElementById('manageVendorContact').value = vendor.contact_person || '';
  document.getElementById('manageVendorPhone').value = vendor.phone || '';
  document.getElementById('manageVendorEmail').value = vendor.email || '';
  document.getElementById('manageVendorAddress').value = vendor.address || '';
  document.getElementById('manageVendorTerms').value = vendor.payment_terms || '';
  document.getElementById('manageVendorNotes').value = vendor.notes || '';
  document.getElementById('manageVendorActive').checked = !!vendor.is_active;
  document.getElementById('manageVendorError').classList.add('hidden');
  renderManageVendorSummary(vendor);

  document.getElementById('addBillForm').classList.add('hidden');
  document.getElementById('addPaymentForm').classList.add('hidden');
  document.getElementById('newBillDate').value = new Date().toISOString().slice(0, 10);
  document.getElementById('newPaymentDate').value = new Date().toISOString().slice(0, 10);

  document.getElementById('manageVendorModal').classList.remove('hidden');

  loadVendorBills(vendorCode);
  loadVendorPayments(vendorCode);
}

async function saveManageVendor() {
  const errorEl = document.getElementById('manageVendorError');
  errorEl.classList.add('hidden');

  const name = document.getElementById('manageVendorName').value.trim();
  if (!name) {
    errorEl.textContent = 'Name is required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveManageVendorBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_update_vendor', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_vendor_code: manageVendorCode,
    p_name: name,
    p_contact_person: document.getElementById('manageVendorContact').value.trim() || null,
    p_phone: document.getElementById('manageVendorPhone').value.trim() || null,
    p_email: document.getElementById('manageVendorEmail').value.trim() || null,
    p_address: document.getElementById('manageVendorAddress').value.trim() || null,
    p_payment_terms: document.getElementById('manageVendorTerms').value.trim() || null,
    p_notes: document.getElementById('manageVendorNotes').value.trim() || null,
    p_is_active: document.getElementById('manageVendorActive').checked
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save Vendor Info';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to update vendor.';
    errorEl.classList.remove('hidden');
    return;
  }

  await loadVendors();
}

// ---------------------------------------------------------------------------
// Bills

function populatePaymentBillSelect(bills) {
  const select = document.getElementById('newPaymentBill');
  const openBills = bills.filter((b) => !b.is_void && Number(b.balance) > 0);
  const options = openBills
    .map((b) => `<option value="${b.bill_no}">${b.bill_no} - ${formatMoney(b.balance)} due</option>`)
    .join('');
  select.innerHTML = '<option value="">(Not applied to a specific bill)</option>' + options;
}

function renderVendorBills(bills) {
  manageVendorBills = bills || [];
  const tbody = document.getElementById('vendorBillsBody');

  if (!bills || bills.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="muted">No bills yet.</td></tr>';
  } else {
    tbody.innerHTML = bills
      .map((b) => `
        <tr>
          <td>${b.bill_no}</td>
          <td>${b.bill_date ? new Date(b.bill_date).toLocaleDateString() : ''}</td>
          <td>${b.due_date ? new Date(b.due_date).toLocaleDateString() : ''}</td>
          <td>${b.reference_no || ''}</td>
          <td style="text-align:right;">${formatMoney(b.amount)}</td>
          <td style="text-align:right;">${formatMoney(b.paid_amount)}</td>
          <td style="text-align:right;">${formatMoney(b.balance)}</td>
          <td>${billStatusBadge(b)}</td>
          <td>${b.is_void || Number(b.paid_amount) > 0 ? '' : `<button class="btn btn-secondary btn-sm" data-void-bill="${b.bill_no}" type="button">Void</button>`}</td>
        </tr>
      `)
      .join('');
  }

  populatePaymentBillSelect(manageVendorBills);
}

async function loadVendorBills(vendorCode) {
  const tbody = document.getElementById('vendorBillsBody');
  tbody.innerHTML = '<tr><td colspan="9" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_vendor_bills', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_vendor_code: vendorCode,
    p_page: 1,
    p_page_size: 200
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="9" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderVendorBills(data);
}

async function saveBill() {
  const errorEl = document.getElementById('addBillError');
  errorEl.classList.add('hidden');

  const billDate = document.getElementById('newBillDate').value;
  const amount = Number(document.getElementById('newBillAmount').value);

  if (!billDate) {
    errorEl.textContent = 'Bill Date is required.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (!amount || amount <= 0) {
    errorEl.textContent = 'Amount must be greater than zero.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('saveBillBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_create_vendor_bill', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_vendor_code: manageVendorCode,
    p_bill_date: billDate,
    p_due_date: document.getElementById('newBillDueDate').value || null,
    p_reference_no: document.getElementById('newBillReference').value.trim() || null,
    p_amount: amount,
    p_notes: document.getElementById('newBillNotes').value.trim() || null
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save Bill';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to add bill.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('addBillForm').classList.add('hidden');
  document.getElementById('newBillReference').value = '';
  document.getElementById('newBillAmount').value = '';
  document.getElementById('newBillNotes').value = '';

  await loadVendorBills(manageVendorCode);
  await refreshManageVendor(manageVendorCode);
}

async function voidBill(billNo) {
  if (!window.confirm(`Void bill ${billNo}?`)) return;

  const { data, error } = await supabaseClient.rpc('admin_void_vendor_bill', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_bill_no: billNo
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    window.alert(error?.message || result?.message || 'Failed to void bill.');
    return;
  }

  await loadVendorBills(manageVendorCode);
  await refreshManageVendor(manageVendorCode);
}

// ---------------------------------------------------------------------------
// Payments

function renderVendorPayments(payments) {
  const tbody = document.getElementById('vendorPaymentsBody');

  if (!payments || payments.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No payments yet.</td></tr>';
    return;
  }

  tbody.innerHTML = payments
    .map((p) => `
      <tr>
        <td>${p.payment_no}</td>
        <td>${p.payment_date ? new Date(p.payment_date).toLocaleDateString() : ''}</td>
        <td>${p.bill_no || '<span class="muted">-</span>'}</td>
        <td style="text-align:right;">${formatMoney(p.amount)}</td>
        <td>${p.method || ''}</td>
        <td>${p.reference_no || ''}</td>
        <td>${p.is_void ? '<span class="badge badge-neutral">Void</span>' : `<button class="btn btn-secondary btn-sm" data-void-payment="${p.payment_no}" type="button">Void</button>`}</td>
      </tr>
    `)
    .join('');
}

async function loadVendorPayments(vendorCode) {
  const tbody = document.getElementById('vendorPaymentsBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient.rpc('admin_list_vendor_payments', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_vendor_code: vendorCode,
    p_page: 1,
    p_page_size: 200
  });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  renderVendorPayments(data);
}

async function savePayment() {
  const errorEl = document.getElementById('addPaymentError');
  errorEl.classList.add('hidden');

  const paymentDate = document.getElementById('newPaymentDate').value;
  const amount = Number(document.getElementById('newPaymentAmount').value);

  if (!paymentDate) {
    errorEl.textContent = 'Payment Date is required.';
    errorEl.classList.remove('hidden');
    return;
  }
  if (!amount || amount <= 0) {
    errorEl.textContent = 'Amount must be greater than zero.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('savePaymentBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  const { data, error } = await supabaseClient.rpc('admin_create_vendor_payment', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_vendor_code: manageVendorCode,
    p_bill_no: document.getElementById('newPaymentBill').value || null,
    p_payment_date: paymentDate,
    p_amount: amount,
    p_method: document.getElementById('newPaymentMethod').value.trim() || null,
    p_reference_no: document.getElementById('newPaymentReference').value.trim() || null,
    p_notes: document.getElementById('newPaymentNotes').value.trim() || null
  });

  saveBtn.disabled = false;
  saveBtn.textContent = 'Save Payment';

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    errorEl.textContent = error?.message || result?.message || 'Failed to record payment.';
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('addPaymentForm').classList.add('hidden');
  document.getElementById('newPaymentAmount').value = '';
  document.getElementById('newPaymentMethod').value = '';
  document.getElementById('newPaymentReference').value = '';
  document.getElementById('newPaymentNotes').value = '';

  await loadVendorBills(manageVendorCode);
  await loadVendorPayments(manageVendorCode);
  await refreshManageVendor(manageVendorCode);
}

async function voidPayment(paymentNo) {
  if (!window.confirm(`Void payment ${paymentNo}?`)) return;

  const { data, error } = await supabaseClient.rpc('admin_void_vendor_payment', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_payment_no: paymentNo
  });

  const result = Array.isArray(data) ? data[0] : data;
  if (error || !result || !result.success) {
    window.alert(error?.message || result?.message || 'Failed to void payment.');
    return;
  }

  await loadVendorBills(manageVendorCode);
  await loadVendorPayments(manageVendorCode);
  await refreshManageVendor(manageVendorCode);
}

// ---------------------------------------------------------------------------

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Vendors');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Vendors.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('vendorSetupContent').classList.remove('hidden');
  wireVendorSearch();
  await loadVendors();

  document.getElementById('exportExcelBtn').addEventListener('click', exportVendorsToExcel);
  document.getElementById('downloadTemplateBtn').addEventListener('click', downloadVendorImportTemplate);
  document.getElementById('importExcelBtn').addEventListener('click', () => {
    document.getElementById('importExcelFileInput').click();
  });
  document.getElementById('importExcelFileInput').addEventListener('change', async (e) => {
    const file = e.target.files[0];
    e.target.value = ''; // allow re-selecting the same file next time
    if (file) await importVendorsFromExcel(file);
  });

  document.getElementById('newVendorBtn').addEventListener('click', openNewVendorModal);
  document.getElementById('closeNewVendorBtn').addEventListener('click', () =>
    document.getElementById('newVendorModal').classList.add('hidden')
  );
  document.getElementById('saveNewVendorBtn').addEventListener('click', saveNewVendor);

  document.getElementById('vendorTableBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-manage-code]');
    if (btn) openManageVendorModal(btn.getAttribute('data-manage-code'));
  });
  document.getElementById('closeManageVendorBtn').addEventListener('click', () =>
    document.getElementById('manageVendorModal').classList.add('hidden')
  );
  document.getElementById('saveManageVendorBtn').addEventListener('click', saveManageVendor);

  document.getElementById('toggleAddBillBtn').addEventListener('click', () =>
    document.getElementById('addBillForm').classList.toggle('hidden')
  );
  document.getElementById('saveBillBtn').addEventListener('click', saveBill);
  document.getElementById('vendorBillsBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-void-bill]');
    if (btn) voidBill(btn.getAttribute('data-void-bill'));
  });

  document.getElementById('toggleAddPaymentBtn').addEventListener('click', () =>
    document.getElementById('addPaymentForm').classList.toggle('hidden')
  );
  document.getElementById('savePaymentBtn').addEventListener('click', savePayment);
  document.getElementById('vendorPaymentsBody').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-void-payment]');
    if (btn) voidPayment(btn.getAttribute('data-void-payment'));
  });
})();
