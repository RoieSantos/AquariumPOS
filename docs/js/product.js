// Product page (docs/product.html?code=<Items.Code>) - one product per URL, Petco-style: photo
// gallery, price, stock per branch (and per color/variant), pickup/delivery, set contents, and a
// quantity + Add to cart that drops the item into the same cart Order Now uses, so the customer
// can keep shopping and check out later (order-now.html?start=cart).
//
// Loaded after js/landing.js, which supplies the shared top bar/branding plus firstImageUrl,
// formatPeso, escapeHtml, productPageUrl and FEATURED_CATEGORY_CODES (the categories Order Now's
// Standard flow sells - anything else is in-store only here too).
//
// Data: public_get_product (supabase_public_product_page.sql) - the same row public_list_order_items
// gives Order Now and Alice. Sets add their contents from public_list_aquarium_sets() and their
// "N sold" from public_get_best_selling_sets (supabase_public_best_sellers.sql).

// The cart itself (readCart / writeCart / updateSiteCartLink) lives in js/landing.js, shared with
// the homepage's top-bar Cart link.
const BRANCHES = ['Amaya', 'GMA'];
const MAX_RELATED = 4;

function allImageUrls(images) {
  if (!images) return [];
  return String(images).split(',').map((url) => url.trim()).filter(Boolean);
}

function stockText(count) {
  const n = Number(count) || 0;
  return n > 0 ? `${n} in stock` : 'Out of stock';
}

function showImage(url) {
  const img = document.getElementById('productImage');
  const placeholder = document.getElementById('productPlaceholder');
  img.hidden = !url;
  placeholder.hidden = !!url;
  if (url) img.src = url;
  document.querySelectorAll('#productThumbs button').forEach((thumb) => {
    thumb.classList.toggle('active', thumb.dataset.url === url);
  });
}

function renderGallery(product) {
  const images = allImageUrls(product.images);
  document.getElementById('productImage').alt = product.name;
  document.getElementById('productThumbs').innerHTML = images.length > 1
    ? images.map((url) => `<button type="button" data-url="${escapeHtml(url)}"><img src="${escapeHtml(url)}" alt="" loading="lazy" /></button>`).join('')
    : '';
  showImage(images[0] || null);
}

// Per-branch totals, then a per-color/variant table when the item has variants (aquariums: Black /
// Clear Sealant, stands: Black / White Paint) - only variants with stock somewhere are listed.
function renderStock(product, isSet) {
  // A set has no stock of its own (its Items row is a portal package, QuantityInStock 0) - it's
  // assembled from its parts when ordered, so per-branch counts would always read "Out of stock".
  if (isSet) {
    document.getElementById('productBranchStock').innerHTML = `
      <div class="prod-branch prod-branch-wide in">
        <span class="prod-branch-name">🛠️ Made to order</span>
        <span class="prod-branch-count">We assemble this set for you at Amaya or GMA</span>
      </div>
    `;
    document.getElementById('productVariantStock').innerHTML = '';
    document.getElementById('productPickupSub').textContent = 'We\'ll confirm when it\'s ready';
    return;
  }

  const byLocation = product.stock_by_location || {};
  document.getElementById('productBranchStock').innerHTML = BRANCHES
    .map((branch) => {
      const n = Number(byLocation[branch]) || 0;
      return `
        <div class="prod-branch ${n > 0 ? 'in' : 'out'}">
          <span class="prod-branch-name">📍 ${branch}</span>
          <span class="prod-branch-count">${stockText(n)}</span>
        </div>
      `;
    })
    .join('');

  const variants = Array.isArray(product.stock_by_variant) ? product.stock_by_variant : [];
  document.getElementById('productVariantStock').innerHTML = variants.length
    ? `<table class="prod-variant-table">
        <thead><tr><th>Option</th>${BRANCHES.map((b) => `<th>${b}</th>`).join('')}</tr></thead>
        <tbody>${variants
          .map((v) => `<tr><td>${escapeHtml(v.option || v.variant || v.sku || '-')}</td>${BRANCHES.map((b) => `<td>${Number(v[b]) || 0}</td>`).join('')}</tr>`)
          .join('')}</tbody>
      </table>`
    : '';

  const total = BRANCHES.reduce((sum, b) => sum + (Number(byLocation[b]) || 0), 0);
  // 0 everywhere still allows Add to cart (aquariums/stands are built to order) - say so, so the
  // button next to "Out of stock" doesn't look like a mistake.
  if (total === 0) {
    document.getElementById('productVariantStock').innerHTML =
      '<p class="prod-note">Out of stock right now - you can still order, and we\'ll confirm when it\'s ready.</p>';
  }
  const ready = BRANCHES.filter((b) => Number(byLocation[b]) > 0);
  document.getElementById('productPickupSub').textContent = ready.length
    ? `Ready at ${ready.join(' & ')}`
    : total === 0 ? 'Order now, we\'ll confirm when it\'s ready' : 'Amaya or GMA branch';
}

async function renderSetContents(product) {
  const box = document.getElementById('productSetContents');
  box.innerHTML = '<p class="prod-note">Loading what\'s included…</p>';
  const { data, error } = await supabaseClient.rpc('public_list_aquarium_sets');
  const set = !error && data ? data.find((s) => s.code === product.code) : null;
  const includes = set && Array.isArray(set.includes) ? set.includes : [];
  const storeSelected = set && Array.isArray(set.store_selected) ? set.store_selected : [];
  const notIncluded = set && Array.isArray(set.not_included) ? set.not_included : [];

  let html = '';
  if (includes.length) {
    html += `<h2 class="prod-panel-title">What's included</h2><ul class="prod-list">${includes
      .map((part) => `<li><span>${escapeHtml(part.item)}</span><span class="prod-list-qty">&times;${Number(part.qty) || 1}</span></li>`)
      .join('')}</ul>`;
  }
  if (storeSelected.length) {
    html += `<p class="prod-note">Also included, chosen by our store to fit your tank: ${escapeHtml(storeSelected.join(', '))}.</p>`;
  }
  if (notIncluded.length) {
    html += `<p class="prod-note">Not included (available as add-ons): ${escapeHtml(notIncluded.join(', '))}.</p>`;
  }
  box.innerHTML = html;
}

async function addSoldBadge(product, badges) {
  const { data, error } = await supabaseClient.rpc('public_get_best_selling_sets', { p_days: 365, p_limit: 24 });
  const row = !error && data ? data.find((s) => s.code === product.code) : null;
  if (!row) return;
  badges.unshift(`<span class="prod-badge">#${row.rank} Best-Selling Set</span>`);
  if (Number(row.qty_sold) > 0) badges.push(`<span class="prod-badge prod-badge-muted">${Number(row.qty_sold).toLocaleString('en-PH')} sold</span>`);
  document.getElementById('productBadges').innerHTML = badges.join('');
}

async function renderRelated(product) {
  const { data, error } = await supabaseClient.rpc('public_list_order_items', { p_category_code: product.category_code });
  const related = (!error && data ? data : [])
    .filter((item) => item.code !== product.code && firstImageUrl(item.images) && Number(item.price) > 0)
    .slice(0, MAX_RELATED);
  if (related.length === 0) return;

  document.getElementById('productRelatedTitle').textContent = `More ${product.category_label || 'like this'}`;
  document.getElementById('productRelatedGrid').innerHTML = related
    .map((item) => `
      <a class="land-product-card" href="${productPageUrl(item.code)}">
        <img src="${escapeHtml(firstImageUrl(item.images))}" alt="${escapeHtml(item.name)}" loading="lazy" />
        <div class="land-product-info">
          <div class="land-product-name">${escapeHtml(item.name)}</div>
          <div class="land-product-price">${formatPeso(item.price)}</div>
        </div>
      </a>
    `)
    .join('');
  document.getElementById('productRelated').hidden = false;
}

function wireBuy(product) {
  const qtyInput = document.getElementById('productQty');
  const readQty = () => Math.max(1, Math.floor(Number(qtyInput.value) || 1));
  document.getElementById('productQtyDec').addEventListener('click', () => { qtyInput.value = Math.max(1, readQty() - 1); });
  document.getElementById('productQtyInc').addEventListener('click', () => { qtyInput.value = readQty() + 1; });

  document.getElementById('productAddBtn').addEventListener('click', () => {
    const quantity = readQty();
    const cart = readCart();
    const existing = cart.find((line) => line.itemCode === product.code);
    if (existing) {
      existing.quantity += quantity;
    } else {
      cart.push({
        categoryCode: product.category_code,
        itemCode: product.code,
        itemName: product.name,
        price: Number(product.price),
        quantity,
      });
    }
    writeCart(cart);
    updateSiteCartLink();
    qtyInput.value = 1;
    document.getElementById('productAdded').hidden = false;
  });
}

function showStatus(message) {
  const status = document.getElementById('productStatus');
  status.textContent = message;
  status.hidden = false;
}

async function loadProduct() {
  updateSiteCartLink();
  const code = new URLSearchParams(window.location.search).get('code');
  if (!code) {
    showStatus('No product selected. Browse our best sellers and shop on the homepage.');
    return;
  }

  const { data, error } = await supabaseClient.rpc('public_get_product', { p_code: code });
  const product = !error && data && data[0];
  if (!product) {
    showStatus('Sorry, this product is no longer available. Browse our other products on the homepage.');
    return;
  }

  const categoryKey = String(product.category_code || '').toUpperCase();
  const isSet = categoryKey === 'SET';
  const orderable = FEATURED_CATEGORY_CODES.includes(categoryKey);

  document.body.dataset.pageTitle = product.name;
  document.title = `${product.name} - RS Pet Stop`;
  document.getElementById('productStatus').hidden = true;
  document.getElementById('productLayout').hidden = false;

  document.getElementById('productBreadcrumb').innerHTML = `
    <a href="index.html">Home</a><span aria-hidden="true">/</span>
    <a href="${orderable ? 'order-now.html?start=standard' : 'index.html#offer'}">${escapeHtml(product.category_label || 'Products')}</a><span aria-hidden="true">/</span>
    <span class="prod-breadcrumb-current">${escapeHtml(product.name)}</span>
  `;
  document.getElementById('productName').textContent = product.name;
  document.getElementById('productSku').textContent = `Item code: ${product.code}`;
  document.getElementById('productPrice').textContent = formatPeso(product.price);

  const badges = [];
  if (isSet) badges.push('<span class="prod-badge">Complete set</span>');
  if (!orderable) badges.push('<span class="prod-badge prod-badge-muted">Available in-store</span>');
  document.getElementById('productBadges').innerHTML = badges.join('');

  renderGallery(product);
  renderStock(product, isSet);

  // Description often just repeats the name (Items.Description falls back to it) - skip that.
  const desc = String(product.description || '').trim();
  const showDesc = desc && desc.toLowerCase() !== String(product.name || '').trim().toLowerCase();
  document.getElementById('productDescription').textContent = desc;
  document.getElementById('productDescriptionWrap').hidden = !showDesc;

  document.getElementById('productBuy').hidden = !orderable;
  document.getElementById('productInStore').hidden = orderable;
  if (orderable) wireBuy(product);

  if (isSet) {
    renderSetContents(product);
    addSoldBadge(product, badges);
  }
  renderRelated(product);
}

document.getElementById('productThumbs').addEventListener('click', (event) => {
  const thumb = event.target.closest('button[data-url]');
  if (thumb) showImage(thumb.dataset.url);
});

loadProduct();
