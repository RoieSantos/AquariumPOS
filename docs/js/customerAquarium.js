// Customer Aquarium page logic.
// Tables: CompleteAquariumSetHeader ("PackageName" PK, "PackagePrice", "VariantID", "SetCode", "Description",
// "SellOnline" - a trigger mirrors each package to its SET catalog item, supabase_aquarium_sets_portal_owned.sql)
// CompleteAquariumSetLine ("EntryNo" PK, "PackageName" FK, "ItemNo", "ItemName", "Quantity", "Price")

let editingPackageName = null;

function formatMoney(value) {
  const n = Number(value);
  if (isNaN(n)) return value ?? '';
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

async function loadPackages() {
  const tbody = document.getElementById('packageTableBody');
  tbody.innerHTML = '<tr><td colspan="7" class="muted">Loading...</td></tr>';

  const [{ data, error }, { data: lineData }] = await Promise.all([
    supabaseClient.from('CompleteAquariumSetHeader').select('*').order('PackageName', { ascending: true }),
    supabaseClient.from('CompleteAquariumSetLine').select('PackageName, Quantity, Price')
  ]);

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${escapeHtml(error.message)}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="7" class="muted">No packages found. Click "New Package" to create one.</td></tr>';
    return;
  }

  // Items total per package = sum of Qty x Price (the regular price of everything in the set).
  const totals = new Map();
  (lineData || []).forEach((l) => {
    const t = totals.get(l.PackageName) || { count: 0, total: 0 };
    t.count += 1;
    t.total += (Number(l.Quantity) || 0) * (Number(l.Price) || 0);
    totals.set(l.PackageName, t);
  });

  tbody.innerHTML = data
    .map((r) => {
      const t = totals.get(r.PackageName) || { count: 0, total: 0 };
      const price = Number(r.PackagePrice) || 0;
      const saves = t.total - price;
      const savesCell = t.total > 0
        ? `<span class="${saves >= 0 ? 'save-pos' : 'save-neg'}">${formatMoney(saves)}</span> <span class="muted">(${Math.round((saves / t.total) * 100)}%)</span>`
        : '<span class="muted">-</span>';
      return `
      <tr>
        <td class="pkg-name-cell">${escapeHtml(r.PackageName)}${optionalPartsText(r) ? `<div class="muted" style="font-size:12px; font-weight:400;">${escapeHtml(optionalPartsText(r))}</div>` : ''}</td>
        <td class="num">${t.count}</td>
        <td class="num">${formatMoney(t.total)}</td>
        <td class="num"><strong>${formatMoney(price)}</strong>${price === 0 ? ' <span class="save-neg">(not set)</span>' : ''}</td>
        <td class="num">${savesCell}</td>
        <td class="variant-cell">${escapeHtml(r.SetCode || '-')}<span class="online-badge${r.SellOnline === false ? ' off' : ''}">${r.SellOnline === false ? 'POS only' : 'Online'}</span></td>
        <td><button class="btn btn-secondary btn-sm edit-pkg-btn" data-pkg="${encodeURIComponent(r.PackageName || '')}" type="button">Edit</button></td>
      </tr>`;
    })
    .join('');

  tbody.querySelectorAll('.edit-pkg-btn').forEach((btn) => {
    btn.addEventListener('click', () => openEditPackage(decodeURIComponent(btn.dataset.pkg)));
  });
}

function addPkgLineRow(line) {
  const tbody = document.getElementById('pkgLinesBody');
  const row = document.createElement('tr');
  row.innerHTML = `
    <td><input type="text" class="pkg-item-no" value="${escapeHtml(line?.ItemNo)}" /></td>
    <td><input type="text" class="pkg-item-name" value="${escapeHtml(line?.ItemName)}" title="${escapeHtml(line?.ItemName)}" /></td>
    <td><input type="number" class="pkg-qty" min="0" step="1" value="${line?.Quantity ?? 1}" /></td>
    <td><input type="number" class="pkg-price" min="0" step="0.01" value="${line?.Price ?? 0}" /></td>
    <td class="pkg-amount">0.00</td>
    <td><button type="button" class="btn btn-danger pkg-remove-btn" title="Remove item" aria-label="Remove item">&times;</button></td>
  `;
  row.querySelector('.pkg-remove-btn').addEventListener('click', () => { row.remove(); recalcPkgTotals(); });
  row.querySelector('.pkg-qty').addEventListener('input', recalcPkgTotals);
  row.querySelector('.pkg-price').addEventListener('input', recalcPkgTotals);
  const nameInput = row.querySelector('.pkg-item-name');
  nameInput.addEventListener('input', () => { nameInput.title = nameInput.value; });
  attachItemLookup(row, row.querySelector('.pkg-item-no'));
  attachItemLookup(row, nameInput);
  tbody.appendChild(row);
  recalcPkgTotals();
}

// Live line Amounts + the summary tiles (items total, package price, customer savings).
function recalcPkgTotals() {
  let total = 0;
  let count = 0;
  document.querySelectorAll('#pkgLinesBody tr').forEach((row) => {
    const qtyEl = row.querySelector('.pkg-qty');
    if (!qtyEl) return;
    const amount = (parseFloat(qtyEl.value) || 0) * (parseFloat(row.querySelector('.pkg-price').value) || 0);
    row.querySelector('.pkg-amount').textContent = formatMoney(amount);
    if (row.querySelector('.pkg-item-no').value.trim()) count += 1;
    total += amount;
  });

  const price = parseFloat(document.getElementById('pkgPrice').value) || 0;
  const saves = total - price;
  document.getElementById('pkgItemsTotal').textContent = formatMoney(total);
  document.getElementById('pkgItemsCount').textContent = `${count} item${count === 1 ? '' : 's'}`;
  document.getElementById('pkgPriceShown').textContent = formatMoney(price);
  document.getElementById('pkgSavings').textContent = formatMoney(saves);

  const tile = document.getElementById('pkgSavingsTile');
  tile.classList.toggle('is-good', price > 0 && saves > 0);
  tile.classList.toggle('is-bad', price > 0 && saves < 0);
  document.getElementById('pkgSavingsPct').textContent = price <= 0
    ? 'Set a package price'
    : total > 0
      ? (saves >= 0 ? `${Math.round((saves / total) * 100)}% off the regular price` : 'Package costs MORE than the items')
      : '';
}

// ---------------------------------------------------------------- item lookup
// Typing in Item No. or Item Name searches Items (staff_search_items, code or name) and picking a hit
// fills both - the POS needs Item No. to be the real item code to explode the set and load variants.

let itemLookupTimer = null;
let itemLookupSeq = 0;

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function itemHitsBox() {
  let box = document.getElementById('pkgItemHits');
  if (!box) {
    box = document.createElement('div');
    box.id = 'pkgItemHits';
    box.className = 'pkg-item-hits hidden';
    document.body.appendChild(box);
  }
  return box;
}

function hideItemHits() {
  itemHitsBox().classList.add('hidden');
}

function attachItemLookup(row, input) {
  input.setAttribute('autocomplete', 'off');
  input.placeholder = 'Search item...';
  input.addEventListener('input', () => {
    clearTimeout(itemLookupTimer);
    const term = input.value.trim();
    if (term.length < 2) { hideItemHits(); return; }
    itemLookupTimer = setTimeout(() => runItemLookup(row, input, term), 250);
  });
  input.addEventListener('keydown', (e) => { if (e.key === 'Escape') hideItemHits(); });
  // Delay so a click on a hit lands before the list disappears.
  input.addEventListener('blur', () => setTimeout(hideItemHits, 200));
}

async function runItemLookup(row, input, term) {
  const seq = ++itemLookupSeq;
  // Same search as GMA Conversations' product picker: active items, every word must match code /
  // name / variant, and it returns the retail price (staff_search_items has no price).
  const { data, error } = await supabaseClient.rpc('staff_search_items_wildcard', { p_query: term });
  if (seq !== itemLookupSeq || document.activeElement !== input) return;

  const box = itemHitsBox();
  const hits = error ? [] : (data || []).slice(0, 15);
  box.innerHTML = error
    ? `<div class="pkg-item-hit muted">Search failed: ${escapeHtml(error.message)}</div>`
    : hits.length === 0
      ? '<div class="pkg-item-hit muted">No items found.</div>'
      : hits.map((h, i) =>
        `<div class="pkg-item-hit" data-i="${i}"><strong>${escapeHtml(h.code)}</strong> - ${escapeHtml(h.name)}` +
        `<span class="muted"> (${escapeHtml(h.category_code || 'no category')}) &middot; ${formatMoney(h.price ?? 0)}</span></div>`
      ).join('');

  // Fixed to the input so the modal's scrolling table can't clip it.
  const rect = input.getBoundingClientRect();
  box.style.left = `${rect.left}px`;
  box.style.top = `${rect.bottom + 2}px`;
  box.style.minWidth = `${Math.max(rect.width, 360)}px`;
  box.classList.remove('hidden');

  box.querySelectorAll('.pkg-item-hit[data-i]').forEach((el) => {
    el.addEventListener('mousedown', (e) => {
      e.preventDefault();
      const hit = hits[Number(el.dataset.i)];
      row.querySelector('.pkg-item-no').value = hit.code || '';
      row.querySelector('.pkg-item-name').value = hit.name || '';
      row.querySelector('.pkg-price').value = Number(hit.price ?? 0);
      row.querySelector('.pkg-item-name').title = hit.name || '';
      hideItemHits();
      recalcPkgTotals();
      row.querySelector('.pkg-qty').focus();
    });
  });
}

// "Required at the POS" checkboxes <-> CompleteAquariumSetHeader.Require* (supabase_aquarium_set_required_parts.sql).
// Missing / null = required, matching the POS's default.
const REQUIRED_PARTS = [
  { id: 'reqSump', column: 'RequireSump', label: 'Sump' },
  { id: 'reqStand', column: 'RequireStand', label: 'Stand' },
  { id: 'reqLights', column: 'RequireLights', label: 'Lights' },
  { id: 'reqPump', column: 'RequirePump', label: 'Pump' },
  { id: 'reqPipe', column: 'RequirePipe', label: 'Pipe' }
];

function setRequiredParts(header) {
  REQUIRED_PARTS.forEach((p) => { document.getElementById(p.id).checked = header?.[p.column] !== false; });
}

function readRequiredParts() {
  const out = {};
  REQUIRED_PARTS.forEach((p) => { out[p.column] = document.getElementById(p.id).checked; });
  return out;
}

function optionalPartsText(header) {
  const optional = REQUIRED_PARTS.filter((p) => header?.[p.column] === false).map((p) => p.label);
  return optional.length ? `Optional at POS: ${optional.join(', ')}` : '';
}

function openNewPackage() {
  setRequiredParts(null);
  editingPackageName = null;
  document.getElementById('packageModalTitle').textContent = 'New Package';
  document.getElementById('pkgName').value = '';
  document.getElementById('pkgName').disabled = false;
  document.getElementById('pkgPrice').value = '';
  document.getElementById('pkgVariantId').value = '';
  document.getElementById('pkgSetCode').value = '';
  document.getElementById('pkgDescription').value = '';
  document.getElementById('pkgSellOnline').checked = true;
  document.getElementById('pkgLinesBody').innerHTML = '';
  document.getElementById('packageError').classList.add('hidden');
  document.getElementById('deletePackageBtn').classList.add('hidden');
  addPkgLineRow();
  document.getElementById('packageModal').classList.remove('hidden');
}

async function openEditPackage(packageName) {
  editingPackageName = packageName;
  document.getElementById('packageModalTitle').textContent = `Edit Package: ${packageName}`;
  document.getElementById('packageError').classList.add('hidden');
  document.getElementById('deletePackageBtn').classList.remove('hidden');
  document.getElementById('packageModal').classList.remove('hidden');
  document.getElementById('pkgName').disabled = true;
  document.getElementById('pkgLinesBody').innerHTML = '<tr><td colspan="6" class="muted">Loading...</td></tr>';

  const { data: headerData, error: headerError } = await supabaseClient
    .from('CompleteAquariumSetHeader')
    .select('*')
    .eq('PackageName', packageName)
    .maybeSingle();

  if (headerError || !headerData) {
    document.getElementById('packageError').textContent = headerError?.message || 'Package not found.';
    document.getElementById('packageError').classList.remove('hidden');
    return;
  }

  document.getElementById('pkgName').value = headerData.PackageName || '';
  document.getElementById('pkgPrice').value = headerData.PackagePrice ?? '';
  document.getElementById('pkgVariantId').value = headerData.VariantID || '';
  document.getElementById('pkgSetCode').value = headerData.SetCode || '';
  document.getElementById('pkgDescription').value = headerData.Description || '';
  document.getElementById('pkgSellOnline').checked = headerData.SellOnline !== false;
  setRequiredParts(headerData);

  const { data: lineData, error: lineError } = await supabaseClient
    .from('CompleteAquariumSetLine')
    .select('*')
    .eq('PackageName', packageName)
    .order('EntryNo', { ascending: true });

  document.getElementById('pkgLinesBody').innerHTML = '';
  if (lineError) {
    document.getElementById('packageError').textContent = lineError.message;
    document.getElementById('packageError').classList.remove('hidden');
    return;
  }

  if (!lineData || lineData.length === 0) {
    addPkgLineRow();
  } else {
    lineData.forEach((l) => addPkgLineRow(l));
  }
  recalcPkgTotals();
}

async function savePackage() {
  const errorEl = document.getElementById('packageError');
  errorEl.classList.add('hidden');

  const name = document.getElementById('pkgName').value.trim();
  if (!name) {
    errorEl.textContent = 'Package Name is required.';
    errorEl.classList.remove('hidden');
    return;
  }

  const price = parseFloat(document.getElementById('pkgPrice').value) || 0;
  const variantId = document.getElementById('pkgVariantId').value.trim();

  const lineRows = Array.from(document.getElementById('pkgLinesBody').querySelectorAll('tr'));
  const lines = lineRows
    .map((row) => ({
      itemNo: row.querySelector('.pkg-item-no').value.trim(),
      itemName: row.querySelector('.pkg-item-name').value.trim(),
      qty: parseFloat(row.querySelector('.pkg-qty').value) || 0,
      price: parseFloat(row.querySelector('.pkg-price').value) || 0
    }))
    .filter((l) => l.itemNo);

  if (lines.length === 0) {
    errorEl.textContent = 'Add at least one package item.';
    errorEl.classList.remove('hidden');
    return;
  }

  const saveBtn = document.getElementById('savePackageBtn');
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving...';

  try {
    await upsertRow('CompleteAquariumSetHeader', { PackageName: name }, {
      PackagePrice: price,
      VariantID: variantId || null,
      // Portal-owned sets: the DB trigger copies these (and the price) onto the set's catalog item.
      Description: document.getElementById('pkgDescription').value.trim() || null,
      SellOnline: document.getElementById('pkgSellOnline').checked,
      ...readRequiredParts(),
      UpdatedDate: new Date().toISOString()
    });

    // Replace all line items for this package (simplest consistent approach for a small package list).
    const { error: deleteError } = await supabaseClient
      .from('CompleteAquariumSetLine')
      .delete()
      .eq('PackageName', name);
    if (deleteError) throw deleteError;

    const insertPayload = lines.map((l) => ({
      PackageName: name,
      ItemNo: l.itemNo,
      ItemName: l.itemName || null,
      Quantity: l.qty,
      Price: l.price
    }));
    const { error: insertError } = await supabaseClient.from('CompleteAquariumSetLine').insert(insertPayload);
    if (insertError) throw insertError;

    document.getElementById('packageModal').classList.add('hidden');
    await loadPackages();
  } catch (err) {
    errorEl.textContent = err.message || 'Failed to save package.';
    errorEl.classList.remove('hidden');
  } finally {
    saveBtn.disabled = false;
    saveBtn.textContent = 'Save Package';
  }
}

async function deletePackage() {
  if (!editingPackageName) return;
  if (!confirm(`Delete package "${editingPackageName}"? This cannot be undone.`)) return;

  const { error } = await supabaseClient
    .from('CompleteAquariumSetHeader')
    .delete()
    .eq('PackageName', editingPackageName);

  if (error) {
    const errorEl = document.getElementById('packageError');
    errorEl.textContent = error.message;
    errorEl.classList.remove('hidden');
    return;
  }

  document.getElementById('packageModal').classList.add('hidden');
  await loadPackages();
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  renderTopNav('Customer Aquarium');

  document.getElementById('newPackageBtn').addEventListener('click', openNewPackage);
  document.getElementById('closePackageModalBtn').addEventListener('click', () =>
    document.getElementById('packageModal').classList.add('hidden')
  );
  document.getElementById('addPkgLineBtn').addEventListener('click', () => {
    addPkgLineRow();
    const rows = document.querySelectorAll('#pkgLinesBody .pkg-item-no');
    rows[rows.length - 1]?.focus();
  });
  document.getElementById('pkgPrice').addEventListener('input', recalcPkgTotals);
  document.getElementById('useItemsTotalBtn').addEventListener('click', (e) => {
    e.preventDefault();
    let total = 0;
    document.querySelectorAll('#pkgLinesBody tr').forEach((row) => {
      const qtyEl = row.querySelector('.pkg-qty');
      if (qtyEl) total += (parseFloat(qtyEl.value) || 0) * (parseFloat(row.querySelector('.pkg-price').value) || 0);
    });
    document.getElementById('pkgPrice').value = total.toFixed(2);
    recalcPkgTotals();
  });
  document.getElementById('savePackageBtn').addEventListener('click', savePackage);
  document.getElementById('deletePackageBtn').addEventListener('click', deletePackage);

  await loadPackages();
})();
