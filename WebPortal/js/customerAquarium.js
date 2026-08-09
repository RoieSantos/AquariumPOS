// Customer Aquarium page logic.
// Tables: CompleteAquariumSetHeader ("PackageName" PK, "PackagePrice", "VariantID")
// CompleteAquariumSetLine ("EntryNo" PK, "PackageName" FK, "ItemNo", "ItemName", "Quantity", "Price")

let editingPackageName = null;

function formatMoney(value) {
  const n = Number(value);
  if (isNaN(n)) return value ?? '';
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

async function loadPackages() {
  const tbody = document.getElementById('packageTableBody');
  tbody.innerHTML = '<tr><td colspan="4" class="muted">Loading...</td></tr>';

  const { data, error } = await supabaseClient
    .from('CompleteAquariumSetHeader')
    .select('*')
    .order('PackageName', { ascending: true });

  if (error) {
    tbody.innerHTML = `<tr><td colspan="4" class="error-text">${error.message}</td></tr>`;
    return;
  }

  if (!data || data.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" class="muted">No packages found. Click "New Package" to create one.</td></tr>';
    return;
  }

  tbody.innerHTML = data
    .map((r) => `
      <tr>
        <td>${r.PackageName || ''}</td>
        <td>${formatMoney(r.PackagePrice)}</td>
        <td>${r.VariantID || ''}</td>
        <td><button class="btn btn-secondary btn-sm edit-pkg-btn" data-pkg="${encodeURIComponent(r.PackageName || '')}" type="button">Edit</button></td>
      </tr>
    `)
    .join('');

  tbody.querySelectorAll('.edit-pkg-btn').forEach((btn) => {
    btn.addEventListener('click', () => openEditPackage(decodeURIComponent(btn.dataset.pkg)));
  });
}

function addPkgLineRow(line) {
  const tbody = document.getElementById('pkgLinesBody');
  const row = document.createElement('tr');
  row.innerHTML = `
    <td><input type="text" class="pkg-item-no" value="${line?.ItemNo ? String(line.ItemNo).replace(/"/g, '&quot;') : ''}" /></td>
    <td><input type="text" class="pkg-item-name" value="${line?.ItemName ? String(line.ItemName).replace(/"/g, '&quot;') : ''}" /></td>
    <td><input type="number" class="pkg-qty" min="0" step="0.01" value="${line?.Quantity ?? 1}" /></td>
    <td><input type="number" class="pkg-price" min="0" step="0.01" value="${line?.Price ?? 0}" /></td>
    <td><button type="button" class="btn btn-danger btn-sm remove-pkg-line-btn">Remove</button></td>
  `;
  row.querySelector('.remove-pkg-line-btn').addEventListener('click', () => row.remove());
  tbody.appendChild(row);
}

function openNewPackage() {
  editingPackageName = null;
  document.getElementById('packageModalTitle').textContent = 'New Package';
  document.getElementById('pkgName').value = '';
  document.getElementById('pkgName').disabled = false;
  document.getElementById('pkgPrice').value = '';
  document.getElementById('pkgVariantId').value = '';
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
  document.getElementById('pkgLinesBody').innerHTML = '<tr><td colspan="5" class="muted">Loading...</td></tr>';

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
  document.getElementById('addPkgLineBtn').addEventListener('click', () => addPkgLineRow());
  document.getElementById('savePackageBtn').addEventListener('click', savePackage);
  document.getElementById('deletePackageBtn').addEventListener('click', deletePackage);

  await loadPackages();
})();
