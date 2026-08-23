// Public "Order Now" customer wizard - no login required. Lets a customer pick a category, add
// items + quantities to a cart, enter contact/fulfillment details, and submit - which lands in
// public."AutomatedOrders"/"AutomatedOrderLines" via the insert-only submit_automated_order() RPC
// (see supabase_automated_orders_tables.sql). Staff review/action requests from
// automated-orders.html.
//
// Cart is kept in sessionStorage (not just an in-memory var) so an accidental refresh/back-nav
// mid-order doesn't wipe out everything the customer already picked.

const CART_STORAGE_KEY = 'order_now_cart';

// Best-effort friendly icon per known Categories.Code (see supabase_categories_backfill.sql) -
// anything else (CUSTOM-* accessories, future categories) falls back to the generic icon below,
// so this list never needs to be exhaustive.
const CATEGORY_ICONS = {
  AQUARIUM: '🐠',
  STAND: '🪑',
  FILTRATION: '🌀',
  SUMP: '🪣',
  FISH: '🐟',
  SET: '🎁'
};
const DEFAULT_CATEGORY_ICON = '🛒';

let cart = loadCart();
// The real underlying Categories.Code value(s) behind the currently-open tile - normally just one,
// but a tile can represent more than one when loadCategories() merged duplicate-cased categories
// (e.g. "Aquarium"/"AQUARIUM") together, see loadCategories/loadItems below.
let currentCategoryCodes = [];
let currentCategoryLabel = null;
// The currently-loaded category's items, kept around so the details modal (openItemDetail) can
// look up a clicked item's full description/stock/images by code without re-fetching.
let currentCategoryItems = [];
// Which item the details modal is currently showing - null when closed. Its own Add to Order
// button reads quantity from the modal's own qty-stepper, not the card's.
let currentDetailItem = null;
let currentStep = 1;
let selectedFulfillment = 'Pickup';
let selectedLocation = 'Amaya';
// Glass thickness snapshotted the moment Low Iron/Rimless gets ticked, so unticking either can
// restore whatever the customer had chosen before that option forced an upgrade.
let glassBeforeLowIron = null;
let glassBeforeRimless = null;
// Set by the confirm prompt shown when leaving the Options step - Filtration no longer has its
// own checkbox on that step, so this is the single source of truth for whether it's enabled.
let filtrationEnabled = false;
// Which Customize tab (Aquarium/Stand/Filtration/Stickers) built the line currently staged for
// the shared "custom-checkout" (Order Summary) screen - lets that one screen
// serve all four instead of needing a separate checkout page per sub-flow.
let customBuilderType = 'aquarium';
// Which Customize tab (aquarium/stand/filtration/stickers) is currently showing - see
// switchCustomizeTab/applyCustomizeTabVisibility below. Independent of currentStep/goToStep on
// purpose: switching tabs, or navigating away to custom-checkout and back, must never reset
// whatever the customer already typed into the OTHER tabs (per "so they can see the stand /
// aquarium / filtration only in one page" - each tab's fields just stay in the DOM, hidden).
let activeCustomizeTab = 'aquarium';
// Once the customer has been asked (via the Stand tab's own footprint prompt below) whether a
// stand they're building is for their Customize > Aquarium tab, don't ask again this session -
// avoids re-prompting every time they hop between tabs.
let standAquariumPromptAsked = false;
// Step 4 (customer details) is shared by the Standard and Customize flows, so its Back button
// needs to know which step led there - set right before navigating into step 4.
let detailsBackTarget = 3;
// Estimate Delivery is reachable both from the Step 0 mode picker (no order in progress yet) and
// from Step 4's "Estimate the delivery fee" link (already deep into an order) - this tracks which
// one so its Back button returns to the right place, and so the Start an Order button (only
// meaningful from the mode-picker entry, since Step 4 already has an order going) can be hidden
// when it isn't.
let deliveryEstimateReturnStep = 0;
// Populated from a ?psid= query param when the customer arrives via a Messenger button whose URL
// Pancake personalized with the sender's PSID. Kept in sessionStorage too so it survives the
// wizard's internal navigation/refreshes. Stays null for anyone who reaches the page any other way.
const PSID_STORAGE_KEY = 'order_now_psid';
let messengerPsid = sessionStorage.getItem(PSID_STORAGE_KEY) || null;

function captureMessengerPsid() {
  const params = new URLSearchParams(window.location.search);
  const psid = params.get('psid');
  if (psid) {
    messengerPsid = psid;
    sessionStorage.setItem(PSID_STORAGE_KEY, psid);
  }
}

// Auto-fills Step 4's name/phone/email from the customer's existing Pancake record (matched by
// PSID) so someone who arrived via a Messenger link doesn't have to retype details Pancake
// already has - see public_lookup_customer_by_psid() in supabase_online_customers_table.sql.
// Only fills fields that are still blank, so it never clobbers something the customer already
// typed (e.g. if the lookup resolves after they started filling the form in manually).
async function prefillCustomerDetailsFromPsid() {
  if (!messengerPsid) return;

  const { data, error } = await supabaseClient.rpc('public_lookup_customer_by_psid', { p_psid: messengerPsid });
  if (error || !data || data.length === 0) return;

  const match = data[0];
  const nameInput = document.getElementById('customerName');
  const phoneInput = document.getElementById('customerPhone');
  const emailInput = document.getElementById('customerEmail');

  if (nameInput && !nameInput.value.trim() && match.name) nameInput.value = match.name;
  if (phoneInput && !phoneInput.value.trim() && match.phone) phoneInput.value = match.phone;
  if (emailInput && !emailInput.value.trim() && match.email) emailInput.value = match.email;
}

function loadCart() {
  try {
    const raw = sessionStorage.getItem(CART_STORAGE_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveCart() {
  sessionStorage.setItem(CART_STORAGE_KEY, JSON.stringify(cart));
  updateViewCartLink();
}

function cartItemCount() {
  return cart.reduce((sum, line) => sum + line.quantity, 0);
}

function cartTotal() {
  return cart.reduce((sum, line) => sum + line.quantity * line.price, 0);
}

function formatMoney(value) {
  return '₱' + Number(value || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// Short single-line preview of item.description (Pancake's note_product, see Items.Description)
// for the item grid card - the full multi-line text (piping/sump/etc. broken out with \r\n) is
// still shown as-is in the item-details modal (openItemDetail), this is just a "there's more, tap
// to see it" teaser so the card doesn't have to grow to fit a whole paragraph.
function shortDescriptionSnippet(description, maxLength = 90) {
  const flat = String(description || '').replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!flat) return '';
  return flat.length > maxLength ? flat.slice(0, maxLength).trim() + '…' : flat;
}

function firstImageUrl(images) {
  if (!images) return null;
  const first = String(images).split(',')[0].trim();
  return first || null;
}

function updateCartBar() {
  const bar = document.getElementById('cartBar');
  const showBar = (currentStep === 1 || currentStep === 2) && cart.length > 0;
  bar.classList.toggle('hidden', !showBar);
  document.getElementById('cartBarInfo').textContent = `${cartItemCount()} item${cartItemCount() === 1 ? '' : 's'} - ${formatMoney(cartTotal())}`;
  document.getElementById('cartBarSub').textContent = 'Tap to review your order';
}

// "View Cart" link under the page header - shows the running item count so it's clear at a
// glance whether there's anything to look at, from any step (not just Standard's steps 1-2 like
// the sticky cart bar above).
function updateViewCartLink() {
  const link = document.getElementById('viewCartLink');
  if (!link) return;
  const count = cartItemCount();
  link.textContent = count > 0 ? `🛒 View Cart (${count})` : '🛒 View Cart';
}

// Cart viewer modal - reachable from the "View Cart" link regardless of which step the customer
// is on, unlike Step 3's cart review which is only reached by walking the Standard flow. Styled
// as the same receipt-style report shown on the Order Summary/checkout screens (company
// letterhead + Product/Qty/Amount table, see renderCustomCheckout) rather than a plain list, but
// keeps this view's own quantity +/- and Remove controls the checkout report doesn't have.
async function renderCartViewModal() {
  const emptyMsg = document.getElementById('cartViewEmptyMsg');
  const report = document.getElementById('cartViewReport');
  const proceedBtn = document.getElementById('cartViewProceedBtn');

  if (cart.length === 0) {
    emptyMsg.classList.remove('hidden');
    report.classList.add('hidden');
    proceedBtn.disabled = true;
    return;
  }

  emptyMsg.classList.add('hidden');
  report.classList.remove('hidden');
  proceedBtn.disabled = false;

  const info = await fetchCompanyInfo();
  const logo = document.getElementById('cartViewLogo');
  if (info && info['LogoUrl']) {
    logo.src = info['LogoUrl'];
    logo.classList.remove('hidden');
  } else {
    logo.classList.add('hidden');
  }
  document.getElementById('cartViewCompanyName').textContent = (info && info['CompanyName']) || '';
  document.getElementById('cartViewFacebook').textContent = (info && info['FacebookUrl']) || '';
  document.getElementById('cartViewAddress').textContent = info && info['Address'] ? `Address : ${info['Address']}` : '';
  document.getElementById('cartViewContactNo').textContent = info && info['ContactNo'] ? `Contact No : ${info['ContactNo']}` : '';
  document.getElementById('cartViewDtiNo').textContent = info && info['DtiNo'] ? `DTI No.: ${info['DtiNo']}` : '';

  const linesBody = document.getElementById('cartViewLinesBody');
  linesBody.innerHTML = cart
    .map((line, idx) => `
      <tr>
        <td>${line.itemName}</td>
        <td>
          <div class="cart-line-qty-controls">
            <button type="button" class="cart-qty-btn" data-idx="${idx}" data-delta="-1">&minus;</button>
            <span class="cart-qty-value">${line.quantity}</span>
            <button type="button" class="cart-qty-btn" data-idx="${idx}" data-delta="1">+</button>
          </div>
        </td>
        <td style="text-align:right;">${formatMoney(line.quantity * line.price)}</td>
        <td style="text-align:right;"><button type="button" class="cart-line-remove" data-idx="${idx}">Remove</button></td>
      </tr>
    `)
    .join('');

  linesBody.querySelectorAll('.cart-qty-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const idx = Number(btn.dataset.idx);
      const delta = Number(btn.dataset.delta);
      cart[idx].quantity = Math.max(1, cart[idx].quantity + delta);
      saveCart();
      renderCartViewModal();
      renderCart();
      updateCartBar();
    });
  });

  linesBody.querySelectorAll('.cart-line-remove').forEach((btn) => {
    btn.addEventListener('click', () => {
      cart.splice(Number(btn.dataset.idx), 1);
      saveCart();
      renderCartViewModal();
      renderCart();
      updateCartBar();
    });
  });

  document.getElementById('cartViewTotalValue').textContent = formatMoney(cartTotal());
}

async function openCartViewModal() {
  document.getElementById('cartViewModal').classList.remove('hidden');
  await renderCartViewModal();
}

function closeCartViewModal() {
  document.getElementById('cartViewModal').classList.add('hidden');
}

// Step 0 (Standard/Customize/Estimate Delivery picker), every "custom-*" step (the Customize
// path's own sub-steps), and the standalone "delivery-estimate" step all sit outside the linear
// 1-4 order flow the progress dots represent, so the whole bar hides on those.
function updateProgress() {
  const progressBar = document.getElementById('wizardProgress');
  if (currentStep === 0 || currentStep === 'delivery-estimate' || String(currentStep).indexOf('custom') === 0) {
    progressBar.classList.add('hidden');
    return;
  }
  progressBar.classList.remove('hidden');

  const displayStep = Math.min(Number(currentStep), 4);
  document.querySelectorAll('.wizard-progress-step').forEach((el) => {
    const stepNum = Number(el.dataset.step);
    el.classList.toggle('done', stepNum < displayStep);
    el.classList.toggle('active', stepNum === displayStep);
  });
}

// Per-tab visibility for the Customize tab bar (docs/order-now.html's data-step="customize-tabs"
// section) - the four builder sections (data-step="custom-dims" etc.) carry class
// "customize-tab-panel" and are excluded from goToStep's normal one-section-at-a-time toggle
// below, so they can each independently stay in the DOM (and keep their entered values) while
// only the currently-selected one is actually visible.
function applyCustomizeTabVisibility() {
  const showingTabs = currentStep === 'customize-tabs';
  document.querySelectorAll('.customize-tab-panel').forEach((el) => {
    el.classList.toggle('active', showingTabs && el.dataset.tabPanel === activeCustomizeTab);
  });
  document.querySelectorAll('.customize-tab-btn').forEach((btn) => {
    btn.classList.toggle('active', btn.dataset.tab === activeCustomizeTab);
  });
}

function switchCustomizeTab(tab) {
  activeCustomizeTab = tab;
  applyCustomizeTabVisibility();
  if (tab === 'stand') {
    updateStandAdviseFromAquariumVisibility();
  }
}

function goToStep(step) {
  currentStep = step;
  document.querySelectorAll('.wizard-step').forEach((el) => {
    if (el.classList.contains('customize-tab-panel')) return;
    el.classList.toggle('active', el.dataset.step === String(step));
  });
  applyCustomizeTabVisibility();
  updateProgress();
  updateCartBar();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

// ---- Step 1: categories ----

async function loadCategories() {
  const loadingMsg = document.getElementById('categoryLoadingMsg');
  const errorMsg = document.getElementById('categoryErrorMsg');
  const grid = document.getElementById('categoryGrid');

  const { data, error } = await supabaseClient.rpc('public_list_order_categories');
  loadingMsg.classList.add('hidden');

  if (error) {
    errorMsg.textContent = 'Could not load categories: ' + error.message;
    errorMsg.classList.remove('hidden');
    return;
  }

  // Standard flow offers pre-built Sets, Aquariums, and Stands - per direct request, every other
  // category (Filtration/Sump/Fish sold separately) stays hidden here even though
  // public_list_order_categories() still returns all of them, so the Customize flow (which has
  // its own separate step-by-step Aquarium/Stand builder, unaffected by this) keeps working.
  const STANDARD_FLOW_CATEGORY_CODES = ['SET', 'AQUARIUM', 'STAND'];
  const standardCategoriesRaw = data.filter((cat) => STANDARD_FLOW_CATEGORY_CODES.includes(String(cat.code).toUpperCase()));

  if (!standardCategoriesRaw || standardCategoriesRaw.length === 0) {
    errorMsg.textContent = 'No categories are available to order right now. Please check back later.';
    errorMsg.classList.remove('hidden');
    return;
  }

  // Merge categories that only differ by code casing (e.g. "Aquarium" vs "AQUARIUM" - same
  // category, just inconsistent casing in the source data) into a single tile here on Order Now
  // only - Category Setup/the desktop app still show them as separate rows, nothing in the
  // database changes. Items get pooled from every underlying code once the merged tile is opened
  // (see loadItems), and each item keeps its own real code when added to cart (see the
  // data-action="add"/itemDetailAddBtn handlers below) so order submission is unaffected.
  const mergedByKey = new Map();
  standardCategoriesRaw.forEach((cat) => {
    const key = String(cat.code).toUpperCase();
    const existing = mergedByKey.get(key);
    if (!existing) {
      mergedByKey.set(key, { key, codes: [cat.code], description: cat.description });
    } else {
      existing.codes.push(cat.code);
      // Prefer a normally-cased label ("Aquarium") over an ALL CAPS duplicate for display.
      if (existing.description === existing.description.toUpperCase() && cat.description !== String(cat.description).toUpperCase()) {
        existing.description = cat.description;
      }
    }
  });
  const standardCategories = Array.from(mergedByKey.values());

  grid.innerHTML = standardCategories
    .map((cat) => `
      <div class="category-card" data-codes="${cat.codes.join('|')}" data-label="${cat.description}">
        <span class="category-icon">${CATEGORY_ICONS[cat.key] || DEFAULT_CATEGORY_ICON}</span>
        ${cat.description}
      </div>
    `)
    .join('');

  grid.querySelectorAll('.category-card').forEach((card) => {
    card.addEventListener('click', () => openCategory(card.dataset.codes.split('|'), card.dataset.label));
  });
}

// ---- Step 2: items within a category ----

async function openCategory(codes, label) {
  currentCategoryCodes = Array.isArray(codes) ? codes : [codes];
  currentCategoryLabel = label;
  document.getElementById('itemStepTitle').textContent = label;
  goToStep(2);
  await loadItems(currentCategoryCodes);
}

async function loadItems(codes) {
  const loadingMsg = document.getElementById('itemLoadingMsg');
  const errorMsg = document.getElementById('itemErrorMsg');
  const emptyMsg = document.getElementById('itemEmptyMsg');
  const grid = document.getElementById('itemGrid');

  loadingMsg.classList.remove('hidden');
  errorMsg.classList.add('hidden');
  emptyMsg.classList.add('hidden');
  grid.innerHTML = '';

  const codeList = Array.isArray(codes) ? codes : [codes];
  const results = await Promise.all(
    codeList.map((code) => supabaseClient.rpc('public_list_order_items', { p_category_code: code }))
  );
  loadingMsg.classList.add('hidden');

  const failed = results.find((r) => r.error);
  if (failed) {
    errorMsg.textContent = 'Could not load items: ' + failed.error.message;
    errorMsg.classList.remove('hidden');
    return;
  }

  // Tag each item with the real underlying category code it came from, so adding it to cart still
  // records that exact code (not a merged placeholder) even when this tile pooled items from more
  // than one duplicate-cased category - see loadCategories.
  const data = [];
  results.forEach((result, i) => {
    (result.data || []).forEach((item) => data.push(Object.assign({}, item, { _sourceCategoryCode: codeList[i] })));
  });

  if (data.length === 0) {
    currentCategoryItems = [];
    emptyMsg.classList.remove('hidden');
    return;
  }

  currentCategoryItems = data;

  grid.innerHTML = data
    .map((item) => {
      const imgUrl = firstImageUrl(item.images);
      const imgHtml = imgUrl
        ? `<img class="item-card-img" src="${imgUrl}" alt="${item.name}" onerror="this.outerHTML='<div class=&quot;item-card-img-placeholder&quot;>${DEFAULT_CATEGORY_ICON}</div>'" />`
        : `<div class="item-card-img-placeholder">${DEFAULT_CATEGORY_ICON}</div>`;
      const stockHtml = item.quantity_in_stock === null || item.quantity_in_stock === undefined
        ? ''
        : item.quantity_in_stock > 0
          ? `<div class="item-card-stock">In stock</div>`
          : `<div class="item-card-stock">Currently out of stock - request anyway</div>`;
      const descSnippet = shortDescriptionSnippet(item.description);
      const descHtml = descSnippet ? `<div class="item-card-desc">${descSnippet}</div>` : '';

      return `
        <div class="item-card" data-code="${item.code}" data-name="${item.name}" data-price="${item.price}">
          <div class="item-card-tap-area" data-action="details">
            ${imgHtml}
            <div class="item-card-name">${item.name}</div>
            ${descHtml}
            <div class="item-card-price">${formatMoney(item.price)}</div>
            ${stockHtml}
          </div>
          <div class="qty-stepper">
            <button type="button" data-action="dec">-</button>
            <input type="number" min="1" value="1" data-qty />
            <button type="button" data-action="inc">+</button>
          </div>
          <button type="button" class="btn btn-primary btn-sm" data-action="add">Add to Order</button>
        </div>
      `;
    })
    .join('');

  grid.querySelectorAll('.item-card').forEach((card) => {
    const qtyInput = card.querySelector('[data-qty]');
    card.querySelector('[data-action="dec"]').addEventListener('click', () => {
      qtyInput.value = Math.max(1, Number(qtyInput.value) - 1);
    });
    card.querySelector('[data-action="inc"]').addEventListener('click', () => {
      qtyInput.value = Number(qtyInput.value) + 1;
    });
    card.querySelector('[data-action="add"]').addEventListener('click', () => {
      const sourceItem = currentCategoryItems.find((i) => String(i.code) === card.dataset.code);
      addToCart({
        categoryCode: (sourceItem && sourceItem._sourceCategoryCode) || currentCategoryCodes[0],
        itemCode: card.dataset.code,
        itemName: card.dataset.name,
        price: Number(card.dataset.price),
        quantity: Math.max(1, Number(qtyInput.value) || 1)
      });
      qtyInput.value = 1;
      flashAdded(card);
    });
    // Tapping the image/name/price area opens the full details modal (description of what's
    // included, bigger photo) - looked up from currentCategoryItems by code rather than stuffed
    // into data-* attributes, since a Set's description can be long/contain characters that don't
    // survive an HTML attribute round-trip cleanly.
    card.querySelector('[data-action="details"]').addEventListener('click', () => {
      const item = currentCategoryItems.find((i) => String(i.code) === card.dataset.code);
      if (item) openItemDetail(item);
    });
  });
}

// ---- Item details modal (steps 2's item-grid) ----

function openItemDetail(item) {
  currentDetailItem = item;
  const imgUrl = firstImageUrl(item.images);
  document.getElementById('itemDetailImageWrap').innerHTML = imgUrl
    ? `<img src="${imgUrl}" alt="${item.name}" onerror="this.outerHTML='<div class=&quot;item-card-img-placeholder&quot;>${DEFAULT_CATEGORY_ICON}</div>'" />`
    : `<div class="item-card-img-placeholder">${DEFAULT_CATEGORY_ICON}</div>`;
  document.getElementById('itemDetailName').textContent = item.name;
  document.getElementById('itemDetailPrice').textContent = formatMoney(item.price);

  const stockEl = document.getElementById('itemDetailStock');
  if (item.quantity_in_stock === null || item.quantity_in_stock === undefined) {
    stockEl.textContent = '';
  } else {
    stockEl.textContent = item.quantity_in_stock > 0 ? 'In stock' : 'Currently out of stock - request anyway';
  }

  const description = (item.description || '').trim();
  document.getElementById('itemDetailDescriptionLabel').classList.toggle('hidden', !description);
  document.getElementById('itemDetailDescription').textContent = description || 'No additional details for this item.';

  document.getElementById('itemDetailQtyInput').value = 1;
  document.getElementById('itemDetailModal').classList.remove('hidden');
}

function closeItemDetail() {
  currentDetailItem = null;
  document.getElementById('itemDetailModal').classList.add('hidden');
}

function flashAdded(card) {
  const btn = card.querySelector('[data-action="add"]');
  const original = btn.textContent;
  btn.textContent = 'Added ✓';
  setTimeout(() => { btn.textContent = original; }, 1000);
}

function addToCart(line) {
  const existing = cart.find((l) => l.itemCode === line.itemCode);
  if (existing) {
    existing.quantity += line.quantity;
  } else {
    cart.push(line);
  }
  saveCart();
  updateCartBar();
}

// ---- Step 3: cart review ----

function renderCart() {
  const emptyMsg = document.getElementById('cartEmptyMsg');
  const linesBox = document.getElementById('cartLinesBox');
  const totalRow = document.getElementById('cartTotalRow');
  const continueBtn = document.getElementById('cartContinueBtn');

  if (cart.length === 0) {
    emptyMsg.classList.remove('hidden');
    linesBox.innerHTML = '';
    totalRow.classList.add('hidden');
    continueBtn.disabled = true;
    return;
  }

  emptyMsg.classList.add('hidden');
  totalRow.classList.remove('hidden');
  continueBtn.disabled = false;

  linesBox.innerHTML = cart
    .map((line, idx) => `
      <div class="cart-line-row">
        <div>
          <div class="cart-line-name">${line.itemName}</div>
          <div class="cart-line-meta">${line.quantity} &times; ${formatMoney(line.price)} = ${formatMoney(line.quantity * line.price)}</div>
        </div>
        <button type="button" class="cart-line-remove" data-idx="${idx}">Remove</button>
      </div>
    `)
    .join('');

  linesBox.querySelectorAll('.cart-line-remove').forEach((btn) => {
    btn.addEventListener('click', () => {
      cart.splice(Number(btn.dataset.idx), 1);
      saveCart();
      renderCart();
      updateCartBar();
    });
  });

  document.getElementById('cartTotalValue').textContent = formatMoney(cartTotal());
}

// ---- Step 4: customer details ----

// Touch-friendly replacement for window.confirm() - native browser confirm dialogs render as a
// tiny, inconsistent OS popup on mobile that's easy to mis-tap. This uses the same modal-backdrop/
// modal-panel pattern as the rest of the portal, with big stacked buttons sized for a thumb.
function showConfirmModal(message, confirmLabel, cancelLabel) {
  return new Promise((resolve) => {
    const modal = document.getElementById('confirmModal');
    const yesBtn = document.getElementById('confirmModalYesBtn');
    const noBtn = document.getElementById('confirmModalNoBtn');

    document.getElementById('confirmModalMessage').textContent = message;
    yesBtn.textContent = confirmLabel;
    noBtn.textContent = cancelLabel;

    function cleanup(result) {
      modal.classList.add('hidden');
      yesBtn.removeEventListener('click', onYes);
      noBtn.removeEventListener('click', onNo);
      resolve(result);
    }
    function onYes() { cleanup(true); }
    function onNo() { cleanup(false); }

    yesBtn.addEventListener('click', onYes);
    noBtn.addEventListener('click', onNo);
    modal.classList.remove('hidden');
  });
}

// Glass/Tubular/Sticker pricing rows, centralized in Supabase (see
// supabase_pricing_setup_tables.sql) so a price edited from the portal's Pricing Setup page shows
// up here, in the staff Portal calculators, and (once the desktop app is updated to read the same
// tables) Local too - one number per price tier instead of three copies that can drift apart.
// Loaded once and reused for every price recalculation on this page. custom-aquarium-calculator.js
// already has built-in hardcoded fallback prices if these fetches fail, so being offline/Supabase
// being unreachable degrades gracefully rather than blocking the estimate entirely.
let glassPricingSetupRows = [];
let tubularPricingSetupRows = [];
let stickerPricingSetupRows = [];
let pricingSetupLoadPromise = null;

function ensureGlassPricingLoaded() {
  if (pricingSetupLoadPromise) return pricingSetupLoadPromise;
  pricingSetupLoadPromise = Promise.all([
    supabaseClient.rpc('public_get_glass_pricing'),
    supabaseClient.rpc('public_get_tubular_pricing'),
    supabaseClient.rpc('public_get_sticker_pricing')
  ])
    .then(([glassResult, tubularResult, stickerResult]) => {
      glassPricingSetupRows = Array.isArray(glassResult.data) ? glassResult.data : [];
      tubularPricingSetupRows = Array.isArray(tubularResult.data) ? tubularResult.data : [];
      stickerPricingSetupRows = Array.isArray(stickerResult.data) ? stickerResult.data : [];
    })
    .catch(() => {
      glassPricingSetupRows = [];
      tubularPricingSetupRows = [];
      stickerPricingSetupRows = [];
    });
  return pricingSetupLoadPromise;
}

// Builds the payload calculateCustomAquarium() expects, from whatever the customer has filled in
// across the Dimensions, Options, and (when the post-Options prompt was answered "yes") Filtration
// steps. Stand/sticker sizing still isn't collected (no step for it) so those stay disabled.
function buildCustomPayload() {
  const unit = document.getElementById('customUnit').value || 'Inches';
  return {
    length: document.getElementById('customLength').value,
    width: document.getElementById('customWidth').value,
    height: document.getElementById('customHeight').value,
    unit: unit,
    option: 'Aquarium only',
    glassThickness: document.getElementById('customGlass').value,
    temperedGlass: document.getElementById('customTempered').checked,
    lowIron: document.getElementById('customLowIron').checked,
    aio: document.getElementById('customAio').checked,
    rimless: document.getElementById('customRimless').checked,
    highStrip: document.getElementById('customHighStrip').checked,
    aquascapeService: document.getElementById('customAquascape').checked,
    enclosure: document.getElementById('customEnclosure').checked,
    filtrationSump: {
      enabled: filtrationEnabled,
      type: document.getElementById('sumpType').value,
      length: document.getElementById('sumpLength').value,
      width: document.getElementById('sumpWidth').value,
      height: document.getElementById('sumpHeight').value,
      unit: unit,
      piping: document.getElementById('sumpPiping').checked,
      overflowBox: document.getElementById('sumpOverflowBox').checked,
      filterMedias: document.getElementById('sumpFilterMedias').checked,
      allumTopCover: document.getElementById('sumpAllumTopCover').checked
    },
    stand: { enabled: false },
    stickerBackground: { enabled: false },
    stickerBottom: { enabled: false },
    glassPricingSetupRows: glassPricingSetupRows,
    glassPricingUom: 'MM',
    tubularPricingSetupRows: tubularPricingSetupRows,
    stickerPricingSetupRows: stickerPricingSetupRows
  };
}

// Inverse of convertToInches() - used to re-fill the sump dimension fields in the aquarium's own
// unit of measure when Sump Type changes (see applySumpTypeDefaults), mirroring
// WebAquariumCalculator/index.html's convertInchesToSelectedUnit.
function convertFromInches(valueInInches, unit) {
  const num = Number(valueInInches) || 0;
  if (unit === 'CM') return num * 2.54;
  if (unit === 'MM') return num * 25.4;
  if (unit === 'Ft') return num / 12;
  return num;
}

// Mirrors WebAquariumCalculator/index.html's own Sump Type default-fill: Undersump defaults to an
// 18in cube, Overhead Sump defaults to a 6in-tall sump running the same length as the aquarium
// (since it sits on top, along the back). Runs when Sump Type changes and once when the customer
// first reaches the Filtration step, so it's never left at a 0-size sump they never touched.
function applySumpTypeDefaults() {
  const sumpType = document.getElementById('sumpType').value;
  const unit = document.getElementById('customUnit').value || 'Inches';
  const side = round1(convertFromInches(sumpType === 'Undersump' ? 18 : 6, unit));
  document.getElementById('sumpWidth').value = side;
  document.getElementById('sumpHeight').value = side;
  if (sumpType === 'Overhead Sump') {
    document.getElementById('sumpLength').value = document.getElementById('customLength').value;
  } else {
    document.getElementById('sumpLength').value = side;
  }
}

// Aquarium sketch on the Options step - a trimmed-down port of the isometric canvas drawing in
// WebAquariumCalculator/index.html's drawAquarium(), adapted to this step's own field IDs and
// leaving out stand/sticker rendering (the wizard doesn't collect those yet). Kept as a separate
// copy rather than a shared module so this page never risks the staff-only calculator page, and
// vice versa.
let customCanvasCtx = null;
let CUSTOM_CANVAS_W = 0;
let CUSTOM_CANVAS_H = 0;

// Lets the customer drag (or click the Rotate button) to flip the aquarium sketch and see the
// other side, per "is it possible that the user can drag and rotate the aquarium image?". It's a
// horizontal mirror of the same isometric drawing rather than a true 3D rotation (there's no 3D
// model to rotate) - cheap to do reliably and still gives the "look at it from the other side"
// effect. customAquariumMirrored is the toggled state; currentDrawMirrored is read by
// drawCustomDimensionChip (shared with the Stand sketch) so only the aquarium's own chip text
// counter-flips back to readable while everything else mirrors normally.
let customAquariumMirrored = false;
let currentDrawMirrored = false;
let lastCustomAquariumResult = null;

// The same live preview is shown on both the Dimensions step (customAquariumCanvasDims) and the
// Options step (customAquariumCanvas), so redraws happen on every registered canvas in this list
// rather than a single one. Each entry is {ctx, w, h}; the draw* functions below still read/write
// the module-level customCanvasCtx/CUSTOM_CANVAS_W/CUSTOM_CANVAS_H globals, which the loops in
// drawCustomPlaceholder()/drawCustomAquarium() point at each canvas in turn before drawing it.
let customCanvases = [];

function round1(value) {
  return Math.round((Number(value) || 0) * 10) / 10;
}

const STAND_TUBULAR_THICKNESS_IN = { '1x1': 1, '1.5x1.5': 1.5, '2x2': 2 };

// Shared with the Stand canvas sketch's "Gap" arrows/captions so the Order Summary shows the same
// number - see the sketch's own comment for why: a middle rail borders TWO gaps at once, so the
// total material used by all `layers` rails is spread evenly across all (layers - 1) gaps rather
// than charging each gap the full thickness of both its rails.
function computeStandGapInches(totalHeightIn, footingIn, layers, tubular) {
  if (!(layers > 1)) return null;
  const heightIn = Math.max(0, (Number(totalHeightIn) || 0) - (Number(footingIn) || 0));
  const thicknessIn = STAND_TUBULAR_THICKNESS_IN[tubular] || 1;
  const spacingIn = heightIn / (layers - 1);
  const gapReductionIn = (layers * thicknessIn) / (layers - 1);
  return Math.max(0, spacingIn - gapReductionIn);
}

function registerCustomCanvas(canvasId) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const w = canvas.width;
  const h = canvas.height;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  ctx.scale(dpr, dpr);
  customCanvases.push({ ctx, w, h });
}

function setupCustomCanvas() {
  customCanvases = [];
  registerCustomCanvas('customAquariumCanvasDims');
  drawCustomPlaceholder('Enter your aquarium details to see a preview.');
}

function toggleCustomAquariumView() {
  customAquariumMirrored = !customAquariumMirrored;
  drawCustomAquarium(lastCustomAquariumResult);
}

// Lets a drag across the canvas act as "rotate" (mirror-flip) - one flip per drag gesture, past a
// small threshold so an accidental click/tap doesn't feel jumpy. The Rotate button next to the
// canvas does the same toggle for anyone who doesn't realize dragging works.
function wireCustomAquariumRotate() {
  const canvas = document.getElementById('customAquariumCanvasDims');
  const rotateBtn = document.getElementById('customAquariumRotateBtn');
  if (!canvas || !rotateBtn) return;

  rotateBtn.addEventListener('click', () => toggleCustomAquariumView());

  let dragging = false;
  let startX = 0;
  let flippedThisDrag = false;

  canvas.addEventListener('pointerdown', (e) => {
    dragging = true;
    flippedThisDrag = false;
    startX = e.clientX;
    canvas.style.cursor = 'grabbing';
  });

  canvas.addEventListener('pointermove', (e) => {
    if (!dragging || flippedThisDrag) return;
    if (Math.abs(e.clientX - startX) > 30) {
      flippedThisDrag = true;
      toggleCustomAquariumView();
    }
  });

  const endDrag = () => {
    dragging = false;
    canvas.style.cursor = 'grab';
  };
  canvas.addEventListener('pointerup', endDrag);
  canvas.addEventListener('pointerleave', endDrag);
  canvas.addEventListener('pointercancel', endDrag);
}

function drawCustomPlaceholder(message) {
  customCanvases.forEach(({ ctx, w, h }) => {
    customCanvasCtx = ctx;
    CUSTOM_CANVAS_W = w;
    CUSTOM_CANVAS_H = h;
    drawCustomPlaceholderOnActiveCanvas(message);
  });
}

function drawCustomPlaceholderOnActiveCanvas(message) {
  const ctx = customCanvasCtx;
  if (!ctx) return;
  ctx.clearRect(0, 0, CUSTOM_CANVAS_W, CUSTOM_CANVAS_H);
  const bg = ctx.createLinearGradient(0, 0, 0, CUSTOM_CANVAS_H);
  bg.addColorStop(0, '#ffffff');
  bg.addColorStop(1, '#f4f9ff');
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, CUSTOM_CANVAS_W, CUSTOM_CANVAS_H);
  ctx.strokeStyle = '#d7e0ef';
  ctx.strokeRect(0.5, 0.5, CUSTOM_CANVAS_W - 1, CUSTOM_CANVAS_H - 1);

  ctx.fillStyle = '#9fb4d1';
  ctx.font = '28px Segoe UI';
  ctx.textAlign = 'center';
  ctx.fillText('🐠', CUSTOM_CANVAS_W / 2, CUSTOM_CANVAS_H / 2 - 6);
  ctx.fillStyle = '#6a7a93';
  ctx.font = '13px Segoe UI';
  ctx.fillText(message, CUSTOM_CANVAS_W / 2, CUSTOM_CANVAS_H / 2 + 22);
  ctx.textAlign = 'left';
}

function drawCustomDimensionChip(centerX, centerY, text) {
  const ctx = customCanvasCtx;
  ctx.font = 'bold 17px Segoe UI';
  const textWidth = ctx.measureText(text).width;
  const paddingX = 9;
  const chipWidth = textWidth + paddingX * 2;
  const chipHeight = 27;
  const x = centerX - chipWidth / 2;
  const y = centerY - chipHeight / 2;
  const radius = 8;

  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.arcTo(x + chipWidth, y, x + chipWidth, y + chipHeight, radius);
  ctx.arcTo(x + chipWidth, y + chipHeight, x, y + chipHeight, radius);
  ctx.arcTo(x, y + chipHeight, x, y, radius);
  ctx.arcTo(x, y, x + chipWidth, y, radius);
  ctx.closePath();
  ctx.fillStyle = 'rgba(255, 255, 255, 0.94)';
  ctx.fill();
  ctx.strokeStyle = '#c3d4ec';
  ctx.lineWidth = 1;
  ctx.stroke();

  ctx.save();
  if (currentDrawMirrored) {
    // The chip background above already mirrored correctly along with the rest of the drawing
    // (it's symmetric geometry), but glyphs drawn under a horizontal mirror render backwards -
    // so undo just the mirror, locally, for the text itself.
    ctx.translate(centerX, centerY);
    ctx.scale(-1, 1);
    ctx.translate(-centerX, -centerY);
  }
  ctx.fillStyle = '#213b64';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, centerX, centerY + 0.5);
  ctx.restore();
  ctx.textAlign = 'left';
  ctx.textBaseline = 'alphabetic';
}

function drawCustomDimensionLine(x1, y1, x2, y2) {
  const ctx = customCanvasCtx;
  const tickLength = 6;
  const isHorizontal = Math.abs(y2 - y1) < Math.abs(x2 - x1);

  ctx.strokeStyle = '#9fb2cc';
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(x1, y1);
  ctx.lineTo(x2, y2);
  ctx.stroke();

  ctx.beginPath();
  if (isHorizontal) {
    ctx.moveTo(x1, y1 - tickLength / 2);
    ctx.lineTo(x1, y1 + tickLength / 2);
    ctx.moveTo(x2, y2 - tickLength / 2);
    ctx.lineTo(x2, y2 + tickLength / 2);
  } else {
    ctx.moveTo(x1 - tickLength / 2, y1);
    ctx.lineTo(x1 + tickLength / 2, y1);
    ctx.moveTo(x2 - tickLength / 2, y2);
    ctx.lineTo(x2 + tickLength / 2, y2);
  }
  ctx.stroke();
}

// Dashed red double-headed arrow marking the clear vertical opening between two adjacent shelves
// (Customize > Stand preview) - mirrors the reference photo's red "Gap" arrow.
function drawCustomStandGapArrow(x, yTop, yBottom) {
  const ctx = customCanvasCtx;
  const headLen = 6;

  ctx.strokeStyle = '#e2483f';
  ctx.fillStyle = '#e2483f';
  ctx.lineWidth = 2;
  ctx.setLineDash([4, 3]);
  ctx.beginPath();
  ctx.moveTo(x, yTop);
  ctx.lineTo(x, yBottom);
  ctx.stroke();
  ctx.setLineDash([]);

  [[yTop, 1], [yBottom, -1]].forEach(([y, dir]) => {
    ctx.beginPath();
    ctx.moveTo(x, y);
    ctx.lineTo(x - headLen * 0.55, y + headLen * dir);
    ctx.lineTo(x + headLen * 0.55, y + headLen * dir);
    ctx.closePath();
    ctx.fill();
  });
}

// result: the return value of calculateCustomAquarium() - drawn straight from its normalized
// dimensions/sump so the sketch always matches whatever price was just computed. Draws to every
// registered canvas (see customCanvases above).
function drawCustomAquarium(result) {
  lastCustomAquariumResult = result;
  customCanvases.forEach(({ ctx, w, h }) => {
    customCanvasCtx = ctx;
    CUSTOM_CANVAS_W = w;
    CUSTOM_CANVAS_H = h;
    drawCustomAquariumOnActiveCanvas(result);
  });
}

function drawCustomAquariumOnActiveCanvas(result) {
  const ctx = customCanvasCtx;
  if (!ctx) return;

  ctx.clearRect(0, 0, CUSTOM_CANVAS_W, CUSTOM_CANVAS_H);
  const bg = ctx.createLinearGradient(0, 0, 0, CUSTOM_CANVAS_H);
  bg.addColorStop(0, '#ffffff');
  bg.addColorStop(1, '#f4f9ff');
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, CUSTOM_CANVAS_W, CUSTOM_CANVAS_H);
  ctx.strokeStyle = '#d7e0ef';
  ctx.strokeRect(0.5, 0.5, CUSTOM_CANVAS_W - 1, CUSTOM_CANVAS_H - 1);

  if (!result || !result.ok || !result.normalized) {
    drawCustomPlaceholderOnActiveCanvas(result && result.error ? result.error : 'Enter your aquarium details to see a preview.');
    return;
  }

  ctx.save();
  if (customAquariumMirrored) {
    currentDrawMirrored = true;
    ctx.translate(CUSTOM_CANVAS_W, 0);
    ctx.scale(-1, 1);
  } else {
    currentDrawMirrored = false;
  }

  const dims = result.normalized;
  const lengthIn = Math.max(1, Number(dims.lengthInches) || 1);
  const widthIn = Math.max(1, Number(dims.widthInches) || 1);
  const heightIn = Math.max(1, Number(dims.heightInches) || 1);
  const showSump = Boolean(dims.sump);
  const showHighStrip = document.getElementById('customHighStrip').checked;
  const showRimless = document.getElementById('customRimless').checked;

  // Fills and centers the drawing within whatever canvas size is actually available, rather than
  // fixed pixel offsets tuned for the desktop calculator's wide 1060px layout - those left the
  // sketch tiny and stuck in the top-left corner once this canvas is stretched across a much
  // narrower/shorter mobile-width container. Margins reserve room for the dimension chips/lines
  // (and the sump box below, when shown) so the scaled drawing never overlaps them.
  const marginLeft = 66;
  const marginRight = 56;
  const marginTop = 34;
  const marginBottom = showSump ? 92 : 52;
  const availableWidth = Math.max(80, CUSTOM_CANVAS_W - marginLeft - marginRight);
  const availableHeight = Math.max(80, CUSTOM_CANVAS_H - marginTop - marginBottom);

  // Solve for the largest scale that keeps the isometric bounding box (front face + depth
  // wedge) inside the available space on both axes, then use whichever is smaller.
  const widthBoundScale = availableWidth / (lengthIn + widthIn * 0.38);
  const heightBoundScale = availableHeight / (heightIn + widthIn * 0.38 * 0.48);
  const scale = Math.min(Math.max(1.5, Math.min(widthBoundScale, heightBoundScale)), 14);

  const frontWidth = lengthIn * scale;
  const frontHeight = heightIn * scale;
  const depth = Math.max(24, widthIn * scale * 0.38);
  const totalWidth = frontWidth + depth;
  const frontLeft = marginLeft + Math.max(0, (availableWidth - totalWidth) / 2);
  const baseY = CUSTOM_CANVAS_H - marginBottom;
  const frontTop = baseY - frontHeight;
  const backTop = frontTop - depth * 0.48;

  ctx.save();
  const shadowCenterX = frontLeft + frontWidth / 2 + depth / 2;
  const shadowY = baseY + 6;
  const shadowGrad = ctx.createRadialGradient(shadowCenterX, shadowY, 4, shadowCenterX, shadowY, frontWidth * 0.62);
  shadowGrad.addColorStop(0, 'rgba(30, 50, 90, 0.20)');
  shadowGrad.addColorStop(1, 'rgba(30, 50, 90, 0)');
  ctx.fillStyle = shadowGrad;
  ctx.beginPath();
  ctx.ellipse(shadowCenterX, shadowY, frontWidth * 0.62, 10, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  const frontGrad = ctx.createLinearGradient(0, frontTop, 0, frontTop + frontHeight);
  frontGrad.addColorStop(0, '#eaf7ff');
  frontGrad.addColorStop(0.12, '#cdeaf9');
  frontGrad.addColorStop(1, '#7cc4dd');
  ctx.fillStyle = frontGrad;
  ctx.fillRect(frontLeft, frontTop, frontWidth, frontHeight);

  ctx.save();
  ctx.beginPath();
  ctx.rect(frontLeft, frontTop, frontWidth, frontHeight);
  ctx.clip();
  ctx.fillStyle = 'rgba(255, 255, 255, 0.22)';
  ctx.beginPath();
  ctx.moveTo(frontLeft + frontWidth * 0.08, frontTop + frontHeight);
  ctx.lineTo(frontLeft + frontWidth * 0.28, frontTop);
  ctx.lineTo(frontLeft + frontWidth * 0.42, frontTop);
  ctx.lineTo(frontLeft + frontWidth * 0.22, frontTop + frontHeight);
  ctx.closePath();
  ctx.fill();
  ctx.restore();

  ctx.beginPath();
  ctx.moveTo(frontLeft, frontTop);
  ctx.lineTo(frontLeft + depth, backTop);
  ctx.lineTo(frontLeft + depth + frontWidth, backTop);
  ctx.lineTo(frontLeft + frontWidth, frontTop);
  ctx.closePath();
  const topGrad = ctx.createLinearGradient(frontLeft, backTop, frontLeft, frontTop);
  topGrad.addColorStop(0, '#e4eef8');
  topGrad.addColorStop(1, '#b9cfe4');
  ctx.fillStyle = topGrad;
  ctx.fill();

  ctx.beginPath();
  ctx.moveTo(frontLeft + frontWidth, frontTop);
  ctx.lineTo(frontLeft + frontWidth + depth, backTop);
  ctx.lineTo(frontLeft + frontWidth + depth, backTop + frontHeight);
  ctx.lineTo(frontLeft + frontWidth, frontTop + frontHeight);
  ctx.closePath();
  const sideGrad = ctx.createLinearGradient(frontLeft + frontWidth, frontTop, frontLeft + frontWidth + depth, frontTop);
  sideGrad.addColorStop(0, '#a9cbdd');
  sideGrad.addColorStop(1, '#6fa8bf');
  ctx.fillStyle = sideGrad;
  ctx.fill();

  ctx.strokeStyle = '#2c4a68';
  ctx.lineWidth = 1.6;
  ctx.lineJoin = 'round';
  ctx.strokeRect(frontLeft, frontTop, frontWidth, frontHeight);
  ctx.beginPath();
  ctx.moveTo(frontLeft, frontTop);
  ctx.lineTo(frontLeft + depth, backTop);
  ctx.lineTo(frontLeft + depth + frontWidth, backTop);
  ctx.lineTo(frontLeft + frontWidth + depth, backTop + frontHeight);
  ctx.lineTo(frontLeft + frontWidth, frontTop + frontHeight);
  ctx.stroke();

  if (showHighStrip) {
    const stripGrad = ctx.createLinearGradient(0, frontTop + 8, 0, frontTop + 16);
    stripGrad.addColorStop(0, '#d65b5b');
    stripGrad.addColorStop(1, '#a83636');
    ctx.fillStyle = stripGrad;
    ctx.fillRect(frontLeft + 6, frontTop + 8, Math.max(24, frontWidth - 12), 8);
  }

  if (!showRimless) {
    ctx.fillStyle = '#45566e';
    ctx.fillRect(frontLeft - 1, frontTop - 3, frontWidth + 2, 5);
  }

  if (showSump) {
    const sumpTop = baseY + 24;
    const sumpHeight = 22;
    const sumpWidth = Math.max(56, frontWidth * 0.55);
    const sumpLeft = frontLeft + ((frontWidth - sumpWidth) / 2);

    const sumpGrad = ctx.createLinearGradient(0, sumpTop, 0, sumpTop + sumpHeight);
    sumpGrad.addColorStop(0, '#f7fcff');
    sumpGrad.addColorStop(1, '#dcedf7');
    ctx.fillStyle = sumpGrad;
    ctx.strokeStyle = '#507193';
    ctx.lineWidth = 1.6;
    ctx.fillRect(sumpLeft, sumpTop, sumpWidth, sumpHeight);
    ctx.strokeRect(sumpLeft, sumpTop, sumpWidth, sumpHeight);

    ctx.strokeStyle = 'rgba(80, 113, 147, 0.45)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(sumpLeft + sumpWidth * 0.34, sumpTop + 3);
    ctx.lineTo(sumpLeft + sumpWidth * 0.34, sumpTop + sumpHeight - 3);
    ctx.moveTo(sumpLeft + sumpWidth * 0.68, sumpTop + 3);
    ctx.lineTo(sumpLeft + sumpWidth * 0.68, sumpTop + sumpHeight - 3);
    ctx.stroke();

    const pipeX = frontLeft + frontWidth / 2;
    ctx.strokeStyle = '#7b8fa6';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(pipeX - 2, baseY);
    ctx.lineTo(pipeX - 2, sumpTop);
    ctx.moveTo(pipeX + 2, baseY);
    ctx.lineTo(pipeX + 2, sumpTop);
    ctx.stroke();
  }

  const lengthLineY = baseY + (showSump ? 54 : 24);
  const heightLineX = frontLeft - 26;
  const widthLineX2 = frontLeft + frontWidth + depth + 4;

  drawCustomDimensionLine(frontLeft, lengthLineY, frontLeft + frontWidth, lengthLineY);
  drawCustomDimensionLine(heightLineX, frontTop, heightLineX, frontTop + frontHeight);
  drawCustomDimensionLine(frontLeft + frontWidth + 4, backTop, widthLineX2, backTop + 2);

  drawCustomDimensionChip(frontLeft + frontWidth / 2, lengthLineY, 'L: ' + round1(lengthIn) + '"');
  drawCustomDimensionChip(heightLineX, frontTop + frontHeight / 2, 'H: ' + round1(heightIn) + '"');
  drawCustomDimensionChip((frontLeft + frontWidth + widthLineX2) / 2, backTop - 2, 'W: ' + round1(widthIn) + '"');

  ctx.restore();
  currentDrawMirrored = false;
}

// ---- Stand (tubular) preview canvas ----
// Separate registry from customCanvases above - both live in the Customize flow but must never
// draw onto each other's canvas. Renders a simplified isometric wireframe (uprights + one
// horizontal frame per layer/shelf) rather than a solid box, so a Stand sketch reads as a tubular
// frame rather than glass - reuses the same dimension-chip/line helpers as the aquarium sketch
// (and its module-level customCanvasCtx/CUSTOM_CANVAS_W/H pointer) for visual consistency.
let standCanvases = [];

function registerStandCanvas(canvasId) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const w = canvas.width;
  const h = canvas.height;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  ctx.scale(dpr, dpr);
  standCanvases.push({ ctx, w, h });
}

function setupStandCanvas() {
  standCanvases = [];
  registerStandCanvas('customStandCanvas');
  drawStandPlaceholder('Enter your stand details to see a preview.');
}

function drawStandPlaceholder(message) {
  standCanvases.forEach(({ ctx, w, h }) => {
    customCanvasCtx = ctx;
    CUSTOM_CANVAS_W = w;
    CUSTOM_CANVAS_H = h;
    drawCustomPlaceholderOnActiveCanvas(message);
  });
}

// result: the return value of calculateStandaloneStand() - drawn from its normalized
// dimensions/layers so the sketch always matches whatever price was just computed.
function drawCustomStand(result) {
  standCanvases.forEach(({ ctx, w, h }) => {
    customCanvasCtx = ctx;
    CUSTOM_CANVAS_W = w;
    CUSTOM_CANVAS_H = h;
    drawCustomStandOnActiveCanvas(result);
  });
}

function drawCustomStandOnActiveCanvas(result) {
  const ctx = customCanvasCtx;
  if (!ctx) return;

  ctx.clearRect(0, 0, CUSTOM_CANVAS_W, CUSTOM_CANVAS_H);
  const bg = ctx.createLinearGradient(0, 0, 0, CUSTOM_CANVAS_H);
  bg.addColorStop(0, '#ffffff');
  bg.addColorStop(1, '#f4f9ff');
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, CUSTOM_CANVAS_W, CUSTOM_CANVAS_H);
  ctx.strokeStyle = '#d7e0ef';
  ctx.strokeRect(0.5, 0.5, CUSTOM_CANVAS_W - 1, CUSTOM_CANVAS_H - 1);

  if (!result || !result.ok || !result.normalized) {
    drawCustomPlaceholderOnActiveCanvas(result && result.error ? result.error : 'Enter your stand details to see a preview.');
    return;
  }

  const dims = result.normalized;
  const lengthIn = Math.max(1, Number(dims.lengthInches) || 1);
  const widthIn = Math.max(1, Number(dims.widthInches) || 1);
  // The Height the customer enters is the TOTAL floor-to-top height (footing already included in
  // it), so the shelf frame span (used for shelf spacing/gap math and to position each layer on
  // the sketch) is derived by subtracting footing back out, not by adding footing on top.
  const totalHeightIn = Math.max(1, Number(dims.heightInches) || 1);
  const footingIn = Math.max(0, Number(dims.footingInches) || 0);
  const heightIn = Math.max(0, totalHeightIn - footingIn);
  const layers = Math.max(2, Math.round(Number(dims.layers) || 2));

  // Same isometric bounding-box math as the aquarium sketch, so both flows scale/center the same
  // way inside whatever canvas size is actually available. Uses the FULL height (frame span +
  // footing) so the whole stand, feet included, fits on the canvas. Extra room is reserved above
  // when a sump holder is shown, since that now draws as its own small supported frame sitting on
  // top of the stand (per direct request) rather than below it.
  const marginLeft = 66;
  const marginRight = 56;
  const marginTop = dims.sumpHolder ? 58 : 34;
  // Extra room below the usual Length line, for the second "Built Length (incl. end posts)"
  // dimension line/chip added underneath it.
  const marginBottom = 80;
  const availableWidth = Math.max(80, CUSTOM_CANVAS_W - marginLeft - marginRight);
  const availableHeight = Math.max(80, CUSTOM_CANVAS_H - marginTop - marginBottom);

  const widthBoundScale = availableWidth / (lengthIn + widthIn * 0.38);
  const heightBoundScale = availableHeight / (totalHeightIn + widthIn * 0.38 * 0.48);
  const scale = Math.min(Math.max(1.5, Math.min(widthBoundScale, heightBoundScale)), 14);

  const frontWidth = lengthIn * scale;
  const frontHeight = totalHeightIn * scale;
  const frameSpan = heightIn * scale;
  const footingPx = footingIn * scale;
  const depth = Math.max(24, widthIn * scale * 0.38);
  const totalWidth = frontWidth + depth;
  const frontLeft = marginLeft + Math.max(0, (availableWidth - totalWidth) / 2);
  const baseY = CUSTOM_CANVAS_H - marginBottom;
  const frontTop = baseY - frontHeight;
  const backTop = frontTop - depth * 0.48;
  const backLeft = frontLeft + depth;
  const backBaseY = baseY - depth * 0.48;
  // Where the bottom-most shelf actually sits - above the true floor by the footing amount, so
  // the legs continue below it down to the floor as short foot stubs (matching the reference
  // photo's stand, whose bottom shelf sits slightly clear of the ground).
  const shelfBaseY = baseY - footingPx;

  // Tubular metal look - thin strokes instead of the aquarium's glass-panel fills, so this reads
  // as a frame rather than a solid box.
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';

  ctx.strokeStyle = '#6b7686';
  ctx.lineWidth = 3;
  [
    [frontLeft, frontTop, frontLeft, baseY],
    [frontLeft + frontWidth, frontTop, frontLeft + frontWidth, baseY],
    [backLeft, backTop, backLeft, backBaseY],
    [backLeft + frontWidth, backTop, backLeft + frontWidth, backBaseY]
  ].forEach(([x1, y1, x2, y2]) => {
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.stroke();
  });

  // One horizontal frame (isometric parallelogram outline) per layer/shelf, evenly spaced from
  // the ground up to the top of the stand - the topmost is drawn darker to read as the main deck.
  // Each frame also gets its own cross brace(s) - same "one brace per 3ft of length" the pricing
  // math already charges for (see computeStandRetailPrice's bracesPerFrame), so the sketch matches
  // a real tubular stand's look (crossbar reinforcing each shelf, as in a real welded frame).
  const bracesPerFrame = Math.max(1, Math.ceil(lengthIn / 36));
  ctx.lineWidth = 2.4;
  for (let i = 0; i < layers; i += 1) {
    const t = layers === 1 ? 0 : i / (layers - 1);
    const y = shelfBaseY - t * frameSpan;
    const backY = y - depth * 0.48;
    ctx.strokeStyle = i === layers - 1 ? '#45566e' : '#8a94a3';
    ctx.beginPath();
    ctx.moveTo(frontLeft, y);
    ctx.lineTo(frontLeft + frontWidth, y);
    ctx.lineTo(backLeft + frontWidth, backY);
    ctx.lineTo(backLeft, backY);
    ctx.closePath();
    ctx.stroke();

    ctx.lineWidth = 1.6;
    for (let b = 1; b <= bracesPerFrame; b += 1) {
      const bt = b / (bracesPerFrame + 1);
      ctx.beginPath();
      ctx.moveTo(frontLeft + bt * frontWidth, y);
      ctx.lineTo(backLeft + bt * frontWidth, backY);
      ctx.stroke();
    }
    ctx.lineWidth = 2.4;
  }

  // Vertical clear-space arrow between each pair of adjacent shelves - see computeStandGapInches
  // (shared with the Order Summary's own "Gap per layer" line, so both always agree).
  const tubularThicknessIn = STAND_TUBULAR_THICKNESS_IN[dims.tubular] || 1;
  if (layers > 1) {
    const gapReductionIn = (layers * tubularThicknessIn) / (layers - 1);
    const gapIn = computeStandGapInches(totalHeightIn, footingIn, layers, dims.tubular);
    const gapX = frontLeft + frontWidth * 0.68;
    const halfReductionPx = (gapReductionIn / 2) * scale;
    for (let i = 0; i < layers - 1; i += 1) {
      const yLower = shelfBaseY - (i / (layers - 1)) * frameSpan;
      const yUpper = shelfBaseY - ((i + 1) / (layers - 1)) * frameSpan;
      const arrowBottom = yLower - halfReductionPx;
      const arrowTop = yUpper + halfReductionPx;
      if (arrowBottom - arrowTop > 10) {
        drawCustomStandGapArrow(gapX, arrowTop, arrowBottom);
      }
      ctx.fillStyle = '#c23b31';
      ctx.font = 'bold 13px Segoe UI';
      ctx.textAlign = 'left';
      ctx.textBaseline = 'middle';
      ctx.fillText('Gap: ' + round1(gapIn) + '"', gapX + 9, (yLower + yUpper) / 2);
      ctx.textBaseline = 'alphabetic';
    }
  }

  // Pointer callout naming the tubular's own cross-section thickness - a single label at the left
  // edge feeding a vertical spine with one short tick pointing at EVERY layer's front rail (not
  // just the top deck), since the tubular size is the same stock for every shelf in the stand.
  const tubularSizeLabelMap = { '1x1': '1"×1"', '1.5x1.5': '1½"×1½"', '2x2': '2"×2"' };
  const tubularSizeLabel = (tubularSizeLabelMap[dims.tubular] || (round1(tubularThicknessIn) + '"')) + ' tube';
  {
    // Spine sits just outside the frame (left of the uprights, right of the H dimension line at
    // frontLeft - 26) so it never crosses either.
    const spineX = frontLeft - 10;
    const layerYs = [];
    for (let i = 0; i < layers; i += 1) {
      const t = layers === 1 ? 0 : i / (layers - 1);
      layerYs.push(shelfBaseY - t * frameSpan);
    }
    const topY = Math.min.apply(null, layerYs);
    const bottomY = Math.max.apply(null, layerYs);
    const labelX = 8;
    const labelY = Math.max(11, topY - 14);

    ctx.strokeStyle = '#45566e';
    ctx.lineWidth = 1;
    ctx.font = 'bold 12px Segoe UI';
    const textWidth = ctx.measureText(tubularSizeLabel).width;

    ctx.beginPath();
    ctx.moveTo(labelX + textWidth + 4, labelY);
    ctx.lineTo(spineX, topY);
    ctx.stroke();

    ctx.beginPath();
    ctx.moveTo(spineX, topY);
    ctx.lineTo(spineX, bottomY);
    ctx.stroke();

    layerYs.forEach((y) => {
      ctx.beginPath();
      ctx.moveTo(spineX, y);
      ctx.lineTo(frontLeft, y);
      ctx.stroke();

      ctx.fillStyle = '#45566e';
      ctx.beginPath();
      ctx.ellipse(frontLeft, y, 2.4, 2.4, 0, 0, Math.PI * 2);
      ctx.fill();
    });

    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
    ctx.fillText(tubularSizeLabel, labelX, labelY);
  }

  // Small foot caps where the legs meet the floor, matching a real welded stand's feet.
  ctx.fillStyle = '#45566e';
  [[frontLeft, baseY], [frontLeft + frontWidth, baseY]].forEach(([fx, fy]) => {
    ctx.beginPath();
    ctx.ellipse(fx, fy, 5, 2.4, 0, 0, Math.PI * 2);
    ctx.fill();
  });

  // Footing callout - labels the short leg-stub segment between the bottom shelf and the floor,
  // since it's now a customer-adjustable field (standFooting) in its own right, not just folded
  // silently into the overall Height figure.
  if (footingPx > 0.5) {
    ctx.strokeStyle = '#8a94a3';
    ctx.setLineDash([2, 2]);
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(frontLeft + frontWidth + 3, shelfBaseY);
    ctx.lineTo(frontLeft + frontWidth + 3, baseY);
    ctx.stroke();
    ctx.setLineDash([]);

    ctx.fillStyle = '#45566e';
    ctx.font = 'bold 14px Segoe UI';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText(round1(footingIn) + '" footing', frontLeft + frontWidth + 9, baseY - footingPx / 2);
    ctx.textBaseline = 'alphabetic';
  }

  // Sump holder - drawn as its own small supported tubular frame (outline + 2 legs, matching the
  // "u=2" support-leg count computeStandRetailPrice's sump-holder math already prices), sitting
  // on top of the main stand rather than below it, per direct request. Legs bridge the small gap
  // down to the stand's own top rail. Compartment dividers use the same bracesPerFrame count as
  // the main frame's own braces.
  if (dims.sumpHolder) {
    const sumpGap = 8;
    const sumpBottom = frontTop - sumpGap;
    const sumpHeight = 14;
    const sumpTop = sumpBottom - sumpHeight;
    const sumpWidth = Math.max(48, frontWidth * 0.4);
    const sumpLeft = frontLeft + ((frontWidth - sumpWidth) / 2);
    const sumpRight = sumpLeft + sumpWidth;

    ctx.strokeStyle = '#507193';
    ctx.lineWidth = 1.6;
    ctx.strokeRect(sumpLeft, sumpTop, sumpWidth, sumpHeight);

    ctx.lineWidth = 1;
    for (let b = 1; b <= bracesPerFrame; b += 1) {
      const bx = sumpLeft + (b / (bracesPerFrame + 1)) * sumpWidth;
      ctx.beginPath();
      ctx.moveTo(bx, sumpTop + 2);
      ctx.lineTo(bx, sumpBottom - 2);
      ctx.stroke();
    }

    ctx.lineWidth = 1.6;
    [[sumpLeft + 4, sumpBottom], [sumpRight - 4, sumpBottom]].forEach(([lx, ly]) => {
      ctx.beginPath();
      ctx.moveTo(lx, ly);
      ctx.lineTo(lx, frontTop);
      ctx.stroke();
    });

    // Caption naming the sump holder and its width, per direct request - placed beside the frame
    // so it never collides with the H dimension line/chip on the left.
    const sumpWidthInVal = round1(Number(dims.sumpWidthInches) || 0);
    ctx.fillStyle = '#45566e';
    ctx.font = 'bold 14px Segoe UI';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText(`Sump holder with ${sumpWidthInVal}" width`, sumpRight + 9, (sumpTop + sumpBottom) / 2);
    ctx.textBaseline = 'alphabetic';
  }

  const lengthLineY = baseY + 24;
  const heightLineX = frontLeft - 26;
  const widthLineX2 = backLeft + frontWidth + 4;

  drawCustomDimensionLine(frontLeft, lengthLineY, frontLeft + frontWidth, lengthLineY);
  drawCustomDimensionLine(heightLineX, frontTop, heightLineX, baseY);
  drawCustomDimensionLine(frontLeft + frontWidth + 4, backTop, widthLineX2, backTop + 2);

  // Height label shows the full floor-to-top measurement (frame span + footing) since that's what
  // the H dimension line above actually spans (frontTop to the true floor at baseY).
  drawCustomDimensionChip(frontLeft + frontWidth / 2, lengthLineY, 'L: ' + round1(lengthIn) + '"');
  drawCustomDimensionChip(heightLineX, frontTop + frontHeight / 2, 'H: ' + round1(totalHeightIn) + '"');
  drawCustomDimensionChip((frontLeft + frontWidth + widthLineX2) / 2, backTop - 2, 'W: ' + round1(widthIn) + '"');

  // Second dimension line below the plain Length line, marking the TRUE built length once the two
  // end tubular posts are accounted for (dual stand = one post at each end of the Length run) - see
  // computeStandBuiltLengthInches / the matching "Built Length" row in the summary card. Dashed
  // tick-downs from each leg corner show exactly how much extra each post adds, so the viewer isn't
  // left guessing where the extra length comes from.
  const postPx = tubularThicknessIn * scale;
  const builtLengthLineY = lengthLineY + 26;
  const builtLeftX = frontLeft - postPx;
  const builtRightX = frontLeft + frontWidth + postPx;
  const builtLengthIn = window.CustomAquariumCalculator.computeStandBuiltLengthInches(lengthIn, dims.tubular);

  ctx.strokeStyle = '#c23b31';
  ctx.setLineDash([2, 2]);
  ctx.lineWidth = 1;
  [frontLeft, frontLeft + frontWidth].forEach((x) => {
    ctx.beginPath();
    ctx.moveTo(x, baseY + 3);
    ctx.lineTo(x, builtLengthLineY);
    ctx.stroke();
  });
  ctx.setLineDash([]);

  ctx.strokeStyle = '#c23b31';
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(builtLeftX, builtLengthLineY);
  ctx.lineTo(builtRightX, builtLengthLineY);
  ctx.stroke();
  [builtLeftX, builtRightX].forEach((x) => {
    ctx.beginPath();
    ctx.moveTo(x, builtLengthLineY - 4);
    ctx.lineTo(x, builtLengthLineY + 4);
    ctx.stroke();
  });

  drawCustomDimensionChip((builtLeftX + builtRightX) / 2, builtLengthLineY, 'Built L (incl. end posts): ' + round1(builtLengthIn) + '"');
}

// Live summary of every Aquarium field picked so far - "declutter" pattern, only listing options
// actually turned on - same as renderCustomStandSummary() on the Stand flow. Re-renders on every
// field change via updateCustomPriceEstimate() below, since Dimensions/Options/Filtration all
// live on the same screen (or the Filtration step right after) with no natural "moving on" point.
function renderCustomAquariumSummary() {
  const summaryEl = document.getElementById('customAquariumSummary');
  if (!summaryEl) return;

  const length = document.getElementById('customLength').value || '?';
  const width = document.getElementById('customWidth').value || '?';
  const height = document.getElementById('customHeight').value || '?';
  const unit = document.getElementById('customUnit').value || 'Not specified';
  const glass = document.getElementById('customGlass').value;
  const sealant = document.getElementById('customSealant').value || 'Not specified';
  const rimless = document.getElementById('customRimless').checked ? 'Rimless' : 'With Rim';

  // Only options actually turned on are listed here - an option left at "No" adds nothing the
  // customer doesn't already know from the checkbox below, so skipping it keeps this summary short.
  const options = [
    ['AIO', document.getElementById('customAio').checked],
    ['Low Iron', document.getElementById('customLowIron').checked],
    ['Tempered Glass', document.getElementById('customTempered').checked],
    ['High Strip', document.getElementById('customHighStrip').checked],
    ['Aquascape Service', document.getElementById('customAquascape').checked],
    ['Enclosure', document.getElementById('customEnclosure').checked],
    ['Filtration', filtrationEnabled]
  ];
  const optionsHtml = options
    .filter(([, checked]) => checked)
    .map(([label]) => `<div><strong>${label}:</strong> Yes</div>`)
    .join('');

  summaryEl.innerHTML = `
    <div><strong>Dimension:</strong> ${length} x ${width} x ${height}</div>
    <div><strong>Unit of Measure:</strong> ${unit}</div>
    <div><strong>Glass Thickness:</strong> <span class="dims-summary-glass-badge">${glass}</span></div>
    <div><strong>Sealant Color:</strong> ${sealant}</div>
    <div><strong>Edge:</strong> ${rimless}</div>
    ${optionsHtml ? `<div class="dims-summary-options-grid">${optionsHtml}</div>` : ''}
  `;
}

// Shown on the Dimensions, Options, and (when reached) Filtration steps, same as the canvas
// preview - so the customer sees a running price as soon as they enter dimensions, and it keeps
// including whatever sump specs they've entered once Filtration is reached.
async function updateCustomPriceEstimate() {
  const dimsBox = document.getElementById('customPriceEstimateDims');
  const filtrationBox = document.getElementById('customPriceEstimateFiltration');
  const boxes = [dimsBox, filtrationBox].filter(Boolean);
  renderCustomAquariumSummary();

  // Nothing computes until a real unit is picked - buildCustomPayload would otherwise silently
  // assume Inches, showing a price/preview for dimensions the customer hasn't actually confirmed
  // the unit of yet.
  if (!document.getElementById('customUnit').value) {
    const notConfigured = { ok: false, error: 'Select a unit of measure to see a price estimate.' };
    drawCustomAquarium(notConfigured);
    boxes.forEach((box) => { box.textContent = notConfigured.error; });
    return;
  }

  await ensureGlassPricingLoaded();

  const result = window.CustomAquariumCalculator.calculateCustomAquarium(buildCustomPayload());
  drawCustomAquarium(result);
  if (!result.ok) {
    boxes.forEach((box) => { box.textContent = result.error || 'Enter valid dimensions to see a price estimate.'; });
    return;
  }

  // All three steps show the computed gallon volume right under the price, so the customer has a
  // sense of tank size at every point in the custom-aquarium flow.
  const priceHtml = `Estimated Price: ${formatMoney(result.totalPrice)}<div class="custom-price-gallons-badge">${result.gallons} gallons</div>`;
  boxes.forEach((box) => { box.innerHTML = priceHtml; });
}

// Plain-text spec line describing everything picked across the Dimensions/Options steps, used
// both as the cart line's item name (so it shows up correctly in the submitted order) and as the
// product row on the checkout summary below.
function buildCustomAquariumSpecText() {
  const length = document.getElementById('customLength').value;
  const width = document.getElementById('customWidth').value;
  const height = document.getElementById('customHeight').value;
  const unit = document.getElementById('customUnit').value;
  const glass = document.getElementById('customGlass').value;
  const sealant = document.getElementById('customSealant').value;
  const edge = document.getElementById('customRimless').checked ? 'Rimless' : 'With Rim';

  // Filtration is deliberately NOT listed here - when enabled it gets its own separate cart line
  // (see buildEmbeddedFiltrationCartLine) instead of being folded into this one's name/price.
  const opts = [];
  if (document.getElementById('customAio').checked) opts.push('AIO');
  if (document.getElementById('customLowIron').checked) opts.push('Low Iron');
  if (document.getElementById('customTempered').checked) opts.push('Tempered Glass');
  if (document.getElementById('customHighStrip').checked) opts.push('High Strip');
  if (document.getElementById('customAquascape').checked) opts.push('Aquascape Service');
  if (document.getElementById('customEnclosure').checked) opts.push('Enclosure');

  const optsText = opts.length ? `, ${opts.join(', ')}` : '';
  return `${length} x ${width} x ${height} ${unit}, ${glass} glass, ${sealant} sealant, ${edge}${optsText}`;
}

// Spells out the sump build so staff can see exactly what was requested without re-opening the
// order in the wizard - same reasoning as buildCustomAquariumSpecText() above, just for the
// Filtration step's own fields.
function buildFiltrationSpecText() {
  const sumpType = document.getElementById('sumpType').value;
  const sumpLength = document.getElementById('sumpLength').value;
  const sumpWidth = document.getElementById('sumpWidth').value;
  const sumpHeight = document.getElementById('sumpHeight').value;
  const unit = document.getElementById('customUnit').value;

  const extras = [];
  if (document.getElementById('sumpPiping').checked) extras.push('Piping');
  if (document.getElementById('sumpOverflowBox').checked) extras.push('Overflow Box');
  if (document.getElementById('sumpFilterMedias').checked) extras.push('Filter Medias');
  if (document.getElementById('sumpAllumTopCover').checked) extras.push('Allum Top Cover');

  const extrasText = extras.length ? `, ${extras.join(', ')}` : '';
  return `${sumpType} ${sumpLength} x ${sumpWidth} x ${sumpHeight} ${unit}${extrasText}`;
}

// price stays the PER-UNIT price (result.totalPrice - what one build of this spec costs); qty is
// multiplied in by the cart/checkout rendering, same as every Standard-flow line already does.
function customAquariumQty() {
  return Math.max(1, Math.round(Number(document.getElementById('customQty').value) || 1));
}

// When Filtration is added onto a Custom Aquarium, splits calculateCustomAquarium()'s single
// combined totalPrice into an aquarium portion and a filtration portion, so each can show as its
// own cart line/order line (per direct request) instead of one merged line. Uses the sump-specific
// components calculateCustomAquarium already isolates (sumpGlass/filterMedia/overflowBox/light/
// pump/piping/allumTopCover) as the filtration side, and whatever's left of totalPrice as the
// aquarium side - the two always add back up to exactly totalPrice, even though a multiplier that
// applies to the combined total before this split (e.g. Low Iron, Enclosure) ends up attributed
// entirely to the aquarium side rather than proportioned across both. Good enough for an estimate
// (the checkout screen already says final pricing gets confirmed with the customer).
function splitCustomAquariumFiltrationPrice(result) {
  if (!result || !result.ok) return { aquariumPrice: 0, filtrationPrice: 0 };
  const c = result.components || {};
  const filtrationPrice = Math.round((
    (c.sumpGlass || 0) + (c.filterMedia || 0) + (c.overflowBox || 0) +
    (c.light || 0) + (c.pump || 0) + (c.piping || 0) + (c.allumTopCover || 0)
  ) * 100) / 100;
  const aquariumPrice = Math.round((result.totalPrice - filtrationPrice) * 100) / 100;
  return { aquariumPrice, filtrationPrice };
}

// Builds the cart line for the aquarium itself, so it flows through the existing Standard-flow
// cart/details/submit pipeline (submitOrder() already just reads whatever's in `cart`) instead of
// needing a separate submission path. When Filtration is also enabled, its price/name are carried
// by a separate line (see buildEmbeddedFiltrationCartLine) rather than folded into this one.
function buildCustomAquariumCartLine(result) {
  const price = result && result.ok
    ? (filtrationEnabled ? splitCustomAquariumFiltrationPrice(result).aquariumPrice : result.totalPrice)
    : 0;
  return {
    categoryCode: 'CUSTOM-AQUARIUM',
    itemCode: null,
    itemName: `Custom Aquarium - ${buildCustomAquariumSpecText()}`,
    price,
    quantity: customAquariumQty()
  };
}

// Companion line to buildCustomAquariumCartLine when Filtration was added onto the aquarium -
// same CategoryCode ('CUSTOM-FILTRATION') the standalone Customize > Filtration flow's own cart
// line uses, so it matches the same Pancake catalog item (see
// supabase_diagnose_custom_stand_filtration_items.sql) - the two flows are treated as "at most one
// filtration per order" either way, consistent with how Aquarium/Stand/Filtration already each
// replace their own prior line on every re-confirm.
function buildEmbeddedFiltrationCartLine(result) {
  const { filtrationPrice } = splitCustomAquariumFiltrationPrice(result);
  return {
    categoryCode: 'CUSTOM-FILTRATION',
    itemCode: null,
    itemName: `Filtration/Sump (for Custom Aquarium) - ${buildFiltrationSpecText()}`,
    price: filtrationPrice,
    quantity: customAquariumQty()
  };
}

// ---- Customize > Stand sub-flow (standalone, no aquarium involved) ----

// Tracks which Tubular size is selected on the Stand step, same pattern as
// deliveryEstimateMethod/selectDeliveryEstimateMethod - the toggle buttons just reflect this.
let selectedStandTubular = '1x1';

// Per direct request: when the customer uses the aquarium's footprint for the stand
// (prefillStandFromAquarium), Height should default based on which Tubular is selected - 30in
// for 1x1, 36in for 1 1/2x1 1/2 or 2x2. This flag tracks whether standHeight is still showing
// that auto-default (so selectStandTubular can keep it in sync as the customer tries different
// Tubular sizes) versus a value the customer typed in themselves (which should never be
// silently overwritten) - same "don't clobber deliberate input" pattern as glassBeforeLowIron/
// glassBeforeRimless above. Only ever set true by prefillStandFromAquarium - manually building a
// stand from scratch (no footprint prefill) never auto-fills Height at all, per the request being
// scoped to "if the user wants to use footprint".
let standHeightIsFootprintDefault = false;

function defaultStandHeightInches(tubular) {
  return tubular === '1x1' ? 30 : 36;
}

function customStandQty() {
  return Math.max(1, Math.round(Number(document.getElementById('standQty').value) || 1));
}

function buildCustomStandPayload() {
  const unit = document.getElementById('standUnit').value || 'Inches';
  const sumpHolder = document.getElementById('standSumpHolder').checked;
  return {
    length: document.getElementById('standLength').value,
    width: document.getElementById('standWidth').value,
    height: document.getElementById('standHeight').value,
    unit: unit,
    layers: document.getElementById('standLayers').value,
    tubular: selectedStandTubular,
    stainless: document.getElementById('standStainless').checked,
    cabinet: document.getElementById('standCabinet').checked,
    sumpHolder: sumpHolder,
    sumpWidth: sumpHolder ? document.getElementById('standSumpWidth').value : 0,
    footingInches: document.getElementById('standFooting').value,
    tubularPricingSetupRows: tubularPricingSetupRows
  };
}

function selectStandTubular(value) {
  selectedStandTubular = value;
  document.getElementById('standTubular1x1').classList.toggle('selected', value === '1x1');
  document.getElementById('standTubular1_5x1_5').classList.toggle('selected', value === '1.5x1.5');
  document.getElementById('standTubular2x2').classList.toggle('selected', value === '2x2');

  // Keep Height following the Tubular-based default (see defaultStandHeightInches) as long as the
  // customer hasn't typed their own Height yet - see standHeightIsFootprintDefault above.
  if (standHeightIsFootprintDefault) {
    const unit = document.getElementById('standUnit').value || 'Inches';
    document.getElementById('standHeight').value = round1(convertFromInches(defaultStandHeightInches(value), unit));
  }
}

// Fades out (and blocks clicking) whichever Tubular options the current Length/Width would
// immediately force away from anyway (see enforceStandTubularSafety's two dimension-based rules)
// - per direct request, so it's visually obvious 1x1/1 1/2x1 1/2 aren't real choices right now
// instead of letting the customer pick one and having it silently snap back on the next update.
function updateStandTubularAvailability() {
  const btn1x1 = document.getElementById('standTubular1x1');
  const btn15 = document.getElementById('standTubular1_5x1_5');
  const unit = document.getElementById('standUnit').value;
  const lengthIn = unit ? convertToInches(document.getElementById('standLength').value, unit) : 0;
  const widthIn = unit ? convertToInches(document.getElementById('standWidth').value, unit) : 0;

  if (!lengthIn || !widthIn) {
    btn1x1.classList.remove('option-disabled');
    btn15.classList.remove('option-disabled');
    return;
  }

  const check1x1 = window.CustomAquariumCalculator.enforceStandTubularSafety(lengthIn, widthIn, undefined, '1x1');
  const check15 = window.CustomAquariumCalculator.enforceStandTubularSafety(lengthIn, widthIn, undefined, '1.5x1.5');
  btn1x1.classList.toggle('option-disabled', check1x1.tubular !== '1x1');
  btn15.classList.toggle('option-disabled', check15.tubular !== '1.5x1.5');
}

// Live summary of every Stand field - "declutter" pattern, only listing options actually turned
// on - re-renders on every field change since the Stand flow is a single step.
function renderCustomStandSummary() {
  const length = document.getElementById('standLength').value || '?';
  const width = document.getElementById('standWidth').value || '?';
  const height = document.getElementById('standHeight').value || '?';
  const unit = document.getElementById('standUnit').value || 'Not specified';
  const qty = document.getElementById('standQty').value || '1';
  const layers = document.getElementById('standLayers').value || '2';
  const footing = document.getElementById('standFooting').value || '0';

  const options = [
    ['Stainless', document.getElementById('standStainless').checked],
    ['Cabinet', document.getElementById('standCabinet').checked],
    ['Sump Holder', document.getElementById('standSumpHolder').checked]
  ];
  const optionsHtml = options
    .filter(([, checked]) => checked)
    .map(([label]) => {
      if (label === 'Sump Holder') {
        return `<div><strong>Sump Holder:</strong> Yes (W-${document.getElementById('standSumpWidth').value} ${unit})</div>`;
      }
      return `<div><strong>${label}:</strong> Yes</div>`;
    })
    .join('');

  // Height/Footing are entered in whatever unit is picked (except Footing, always inches) - convert
  // to real inches, same as calculateStandaloneStand does, so the gap shown here always matches the
  // canvas sketch's own "Gap" arrows/captions.
  const layersNum = Math.round(Number(layers)) || 2;
  const heightInchesForGap = unit && window.CustomAquariumCalculator
    ? window.CustomAquariumCalculator.toInches(height, unit)
    : Number(height) || 0;
  const gapIn = window.CustomAquariumCalculator
    ? computeStandGapInches(heightInchesForGap, Number(footing) || 0, layersNum, selectedStandTubular)
    : null;
  const gapHtml = gapIn !== null ? `<div><strong>Gap per layer:</strong> ${round1(gapIn)}in</div>` : '';

  // Dual stand = one tubular post at each end of the Length run, so the frame actually built is
  // longer than the footprint Length by 2x the tubular's own thickness - shown here for the
  // customer's awareness only, the price estimate below still prices off the entered footprint.
  let builtLengthHtml = '';
  if (window.CustomAquariumCalculator && unit !== 'Not specified' && Number(length) > 0) {
    const lengthInches = window.CustomAquariumCalculator.toInches(length, unit);
    const builtLengthInches = window.CustomAquariumCalculator.computeStandBuiltLengthInches(lengthInches, selectedStandTubular);
    const builtLengthDisplay = round1(convertFromInches(builtLengthInches, unit));
    builtLengthHtml = `<div><strong>Built Length (incl. end posts):</strong> ${builtLengthDisplay} ${unit}</div>`;
  }

  document.getElementById('customStandSummary').innerHTML = `
    <div><strong>Dimension:</strong> ${length} x ${width} x ${height}</div>
    ${builtLengthHtml}
    <div><strong>Unit of Measure:</strong> ${unit}</div>
    <div><strong>Quantity:</strong> ${qty}</div>
    <div><strong>Layers:</strong> ${layers}</div>
    ${gapHtml}
    <div><strong>Footing:</strong> ${footing}in</div>
    <div><strong>Tubular:</strong> ${selectedStandTubular}</div>
    ${optionsHtml ? `<div class="dims-summary-options-grid">${optionsHtml}</div>` : ''}
  `;
}

// Warns when Footing reaches 10in or above - per direct request, a footing that tall starts
// undermining the stand's own stability rather than just lifting it clear of the floor.
function updateStandFootingNotice() {
  const notice = document.getElementById('customStandFootingNotice');
  const footingIn = Number(document.getElementById('standFooting').value) || 0;
  if (footingIn >= 10) {
    notice.textContent = 'Please note: the higher the footing, the more unstable the stand becomes.';
    notice.classList.remove('hidden');
  } else {
    notice.classList.add('hidden');
  }
}

// Live price + tubular-safety notice for the Stand step - mirrors applyCustomDimsGlassSafety's
// "auto-adjust and explain why" pattern, just driven by calculateStandaloneStand's own notice
// (it already runs enforceStandTubularSafety internally) instead of a separate check.
async function updateCustomStandPriceEstimate() {
  const box = document.getElementById('customPriceEstimateStand');
  const notice = document.getElementById('customStandNotice');
  renderCustomStandSummary();
  updateStandFootingNotice();

  if (!document.getElementById('standUnit').value) {
    box.textContent = 'Select a unit of measure to see a price estimate.';
    notice.classList.add('hidden');
    drawStandPlaceholder('Select a unit of measure to see a preview.');
    updateStandTubularAvailability();
    return;
  }

  updateStandTubularAvailability();
  await ensureGlassPricingLoaded();
  const result = window.CustomAquariumCalculator.calculateStandaloneStand(buildCustomStandPayload());
  drawCustomStand(result);
  if (!result.ok) {
    box.textContent = result.error || 'Enter valid dimensions to see a price estimate.';
    notice.classList.add('hidden');
    return;
  }

  if (result.normalized.tubular !== selectedStandTubular) {
    selectStandTubular(result.normalized.tubular);
  }
  if (result.notice) {
    notice.textContent = `${result.notice.title}: ${result.notice.message}`;
    notice.classList.remove('hidden');
  } else {
    notice.classList.add('hidden');
  }

  box.textContent = `Estimated Price: ${formatMoney(result.totalPrice)}`;
}

function buildCustomStandSpecText() {
  const length = document.getElementById('standLength').value;
  const width = document.getElementById('standWidth').value;
  const height = document.getElementById('standHeight').value;
  const unit = document.getElementById('standUnit').value;
  const layers = document.getElementById('standLayers').value;

  const opts = [`${document.getElementById('standFooting').value}in footing`];
  if (document.getElementById('standStainless').checked) opts.push('Stainless');
  if (document.getElementById('standCabinet').checked) opts.push('Cabinet');
  if (document.getElementById('standSumpHolder').checked) {
    opts.push(`Sump Holder (W-${document.getElementById('standSumpWidth').value} ${unit})`);
  }
  const optsText = opts.length ? `, ${opts.join(', ')}` : '';

  return `${length} x ${width} x ${height} ${unit}, ${layers} Layer, Tubular ${selectedStandTubular}${optsText}`;
}

function buildCustomStandCartLine(result) {
  return {
    categoryCode: 'CUSTOM-STAND',
    itemCode: null,
    itemName: `Custom Stand - ${buildCustomStandSpecText()}`,
    price: result && result.ok ? result.totalPrice : 0,
    quantity: customStandQty()
  };
}

// Puts the Stand step back to its just-loaded defaults, same reasoning as
// resetCustomAquariumBuilder - opening it should always feel like starting fresh.
function resetCustomStandBuilder() {
  // Plain reset (no footprint prefill) never auto-fills Height - only prefillStandFromAquarium
  // (called right after this) arms the flag and overwrites the '0' just set below.
  standHeightIsFootprintDefault = false;
  document.getElementById('standLength').value = '0';
  document.getElementById('standWidth').value = '0';
  document.getElementById('standHeight').value = '0';
  document.getElementById('standFooting').value = '3';
  document.getElementById('standQty').value = '1';
  document.getElementById('standUnit').value = '';
  document.getElementById('standLayers').value = '2';
  selectStandTubular('1x1');
  document.getElementById('standTubular1x1').classList.remove('option-disabled');
  document.getElementById('standTubular1_5x1_5').classList.remove('option-disabled');
  document.getElementById('standStainless').checked = false;
  document.getElementById('standCabinet').checked = false;
  document.getElementById('standSumpHolder').checked = false;
  document.getElementById('standSumpWidth').value = '0';
  document.getElementById('standSumpWidthRow').classList.add('hidden');

  ['customStandErrorMsg', 'customStandNotice', 'customStandFootingNotice', 'standAquariumAwarenessNote'].forEach((id) => {
    const el = document.getElementById(id);
    el.textContent = '';
    el.classList.add('hidden');
  });
  document.getElementById('customPriceEstimateStand').textContent = 'Enter your stand details to see a price estimate.';
  drawStandPlaceholder('Enter your stand details to see a preview.');
  renderCustomStandSummary();
}

// Reached from the post-Aquarium-checkout "Add Stand" prompt - carries the just-confirmed
// aquarium's own Length/Width/Unit over as the stand's starting footprint (a stand has to match
// the tank it's holding), leaving everything else at its normal reset defaults. The customer can
// still edit Length/Width afterward if they want a different footprint.
function prefillStandFromAquarium() {
  resetCustomStandBuilder();
  const length = document.getElementById('customLength').value;
  const width = document.getElementById('customWidth').value;
  const unit = document.getElementById('customUnit').value;
  document.getElementById('standLength').value = length;
  document.getElementById('standWidth').value = width;
  document.getElementById('standUnit').value = unit;

  // Per direct request: default Height by Tubular size when using the footprint - 30in for 1x1,
  // 36in for 1 1/2x1 1/2 or 2x2 (see defaultStandHeightInches). resetCustomStandBuilder() just
  // above always leaves Tubular at 1x1, so this starts at 30in; armed here so selectStandTubular
  // keeps it synced if the customer then tries a different Tubular size, up until they type their
  // own Height.
  standHeightIsFootprintDefault = true;
  document.getElementById('standHeight').value = round1(convertFromInches(defaultStandHeightInches(selectedStandTubular), unit));

  const note = document.getElementById('standAquariumAwarenessNote');
  note.textContent = `Using this aquarium's footprint: ${length} x ${width} ${unit}. You can adjust Length/Width if you'd like a different fit.`;
  note.classList.remove('hidden');

  updateCustomStandPriceEstimate();
}

// Shared by maybeOfferStandPrefillFromAquarium (the one-time popup) and
// updateStandAdviseFromAquariumVisibility (the always-available link) - both need to know whether
// the Aquarium tab actually has a real footprint to offer.
function isAquariumTabFilled() {
  const length = document.getElementById('customLength').value;
  const width = document.getElementById('customWidth').value;
  const height = document.getElementById('customHeight').value;
  const unit = document.getElementById('customUnit').value;
  return Number(length) > 0 && Number(width) > 0 && Number(height) > 0 && Boolean(unit);
}

// Reached when the customer clicks straight into the Stand tab (as opposed to the post-checkout
// "Add Stand" prompt, which already knows the answer is yes). If the Aquarium tab has real
// dimensions filled in and the Stand tab hasn't been touched yet, ask whether this stand is for
// that same aquarium - if so, carry the footprint over the same way prefillStandFromAquarium()
// does for the post-checkout flow. Only asks once per session (see standAquariumPromptAsked) so
// tab-hopping doesn't repeatedly interrupt the customer.
async function maybeOfferStandPrefillFromAquarium() {
  if (standAquariumPromptAsked) return;
  if (!isAquariumTabFilled()) return;

  const standUntouched = !(Number(document.getElementById('standLength').value) > 0);
  if (!standUntouched) return;

  const length = document.getElementById('customLength').value;
  const width = document.getElementById('customWidth').value;
  const height = document.getElementById('customHeight').value;
  const unit = document.getElementById('customUnit').value;

  standAquariumPromptAsked = true;
  const wantsPrefill = await showConfirmModal(
    `Are you getting a stand for the aquarium you're customizing (${length} x ${width} x ${height} ${unit})?`,
    'Yes, Use Its Footprint',
    'No, I\'ll Enter My Own'
  );
  if (wantsPrefill) {
    prefillStandFromAquarium();
  }
}

// Always-available "Advise stand dimension base on aquarium" link shown above the Stand tab's
// Dimensions fields whenever the Aquarium tab has a real footprint filled in - unlike the one-time
// popup above, the customer can click this anytime (e.g. after editing the aquarium's size, or
// after having said "No" to the popup) to pull the footprint over.
function updateStandAdviseFromAquariumVisibility() {
  document.getElementById('standAdviseFromAquariumRow').classList.toggle('hidden', !isAquariumTabFilled());
}

// ---- Customize > Filtration sub-flow (standalone, no aquarium involved) ----

function standaloneFiltrationQty() {
  return Math.max(1, Math.round(Number(document.getElementById('standaloneFiltrationQty').value) || 1));
}

function buildStandaloneFiltrationPayload() {
  const unit = document.getElementById('standaloneFiltrationUnit').value || 'Inches';
  return {
    length: document.getElementById('standaloneSumpLength').value,
    width: document.getElementById('standaloneSumpWidth').value,
    height: document.getElementById('standaloneSumpHeight').value,
    unit: unit,
    sumpType: document.getElementById('standaloneSumpType').value,
    glassThickness: document.getElementById('standaloneFiltrationGlass').value,
    piping: document.getElementById('standaloneSumpPiping').checked,
    overflowBox: document.getElementById('standaloneSumpOverflowBox').checked,
    filterMedias: document.getElementById('standaloneSumpFilterMedias').checked,
    allumTopCover: document.getElementById('standaloneSumpAllumTopCover').checked,
    glassPricingSetupRows: glassPricingSetupRows,
    glassPricingUom: 'MM',
    stickerPricingSetupRows: stickerPricingSetupRows
  };
}

// Mirrors applySumpTypeDefaults() but with no aquarium to derive an Overhead Sump length from -
// defaults to the same 18in-cube starting point regardless of sump type here.
function applyStandaloneSumpTypeDefaults() {
  const unit = document.getElementById('standaloneFiltrationUnit').value || 'Inches';
  const side = round1(convertFromInches(18, unit));
  document.getElementById('standaloneSumpLength').value = side;
  document.getElementById('standaloneSumpWidth').value = side;
  document.getElementById('standaloneSumpHeight').value = side;
}

// Live "declutter" spec summary, same purpose as renderCustomAquariumSummary/
// renderCustomStandSummary - reuses buildStandaloneFiltrationSpecText() (already exists for the
// cart line's item name) rather than duplicating its field-reading logic.
function renderStandaloneFiltrationSummary() {
  const summaryEl = document.getElementById('standaloneFiltrationSummary');
  const unit = document.getElementById('standaloneFiltrationUnit').value;
  if (!unit) {
    summaryEl.innerHTML = '';
    return;
  }
  const qty = document.getElementById('standaloneFiltrationQty').value || '1';
  summaryEl.innerHTML = `
    <div><strong>Build:</strong> ${buildStandaloneFiltrationSpecText()}</div>
    <div><strong>Quantity:</strong> ${qty}</div>
  `;
}

async function updateStandaloneFiltrationPriceEstimate() {
  const box = document.getElementById('customPriceEstimateStandaloneFiltration');
  renderStandaloneFiltrationSummary();

  if (!document.getElementById('standaloneFiltrationUnit').value) {
    box.textContent = 'Select a unit of measure to see a price estimate.';
    return;
  }

  await ensureGlassPricingLoaded();
  const result = window.CustomAquariumCalculator.calculateStandaloneFiltration(buildStandaloneFiltrationPayload());
  if (!result.ok) {
    box.textContent = result.error || 'Enter valid dimensions to see a price estimate.';
    return;
  }

  box.innerHTML = `Estimated Price: ${formatMoney(result.totalPrice)}`;
}

function buildStandaloneFiltrationSpecText() {
  const sumpType = document.getElementById('standaloneSumpType').value;
  const length = document.getElementById('standaloneSumpLength').value;
  const width = document.getElementById('standaloneSumpWidth').value;
  const height = document.getElementById('standaloneSumpHeight').value;
  const unit = document.getElementById('standaloneFiltrationUnit').value;
  const glass = document.getElementById('standaloneFiltrationGlass').value;

  const extras = [];
  if (document.getElementById('standaloneSumpPiping').checked) extras.push('Piping');
  if (document.getElementById('standaloneSumpOverflowBox').checked) extras.push('Overflow Box');
  if (document.getElementById('standaloneSumpFilterMedias').checked) extras.push('Filter Medias');
  if (document.getElementById('standaloneSumpAllumTopCover').checked) extras.push('Allum Top Cover');
  const extrasText = extras.length ? `, ${extras.join(', ')}` : '';

  return `${sumpType} ${length} x ${width} x ${height} ${unit}, ${glass} glass${extrasText}`;
}

function buildStandaloneFiltrationCartLine(result) {
  return {
    categoryCode: 'CUSTOM-FILTRATION',
    itemCode: null,
    itemName: `Custom Filtration - ${buildStandaloneFiltrationSpecText()}`,
    price: result && result.ok ? result.totalPrice : 0,
    quantity: standaloneFiltrationQty()
  };
}

function resetStandaloneFiltrationBuilder() {
  document.getElementById('standaloneFiltrationQty').value = '1';
  document.getElementById('standaloneFiltrationUnit').value = '';
  document.getElementById('standaloneSumpType').value = 'Undersump';
  document.getElementById('standaloneFiltrationGlass').value = '6mm';
  document.getElementById('standaloneSumpLength').value = '18';
  document.getElementById('standaloneSumpWidth').value = '18';
  document.getElementById('standaloneSumpHeight').value = '18';
  ['standaloneSumpPiping', 'standaloneSumpOverflowBox', 'standaloneSumpFilterMedias', 'standaloneSumpAllumTopCover']
    .forEach((id) => { document.getElementById(id).checked = false; });

  const errorMsg = document.getElementById('customStandaloneFiltrationErrorMsg');
  errorMsg.textContent = '';
  errorMsg.classList.add('hidden');
  document.getElementById('customPriceEstimateStandaloneFiltration').textContent = 'Enter your sump details to see a price estimate.';

  const awarenessNote = document.getElementById('filtrationAquariumAwarenessNote');
  awarenessNote.textContent = '';
  awarenessNote.classList.add('hidden');

  renderStandaloneFiltrationSummary();
}

// Standalone Custom Accessories/Stickers sub-flow (own tab in the Customize tab bar, no aquarium
// involved) - mirrors ShowCustomStickersDialog in MainForm.cs (the desktop POS app's "CUSTOM
// STICKERS" action button), via the shared window.CustomAquariumCalculator.calculateStandaloneSticker
// (custom-aquarium-calculator.js) so this quotes identically to both the desktop app and
// docs/sticker-calculator.html.
function standaloneStickerQty() {
  return Math.max(1, Math.round(Number(document.getElementById('standaloneStickerQty').value) || 1));
}

function buildStandaloneStickerPayload() {
  return {
    length: document.getElementById('standaloneStickerLength').value,
    width: document.getElementById('standaloneStickerWidth').value,
    unit: document.getElementById('standaloneStickerUnit').value,
    type: document.getElementById('standaloneStickerType').value,
    thickness: document.getElementById('standaloneStickerThickness').value,
    repair: document.getElementById('standaloneStickerRepair').checked,
    stickerPricingSetupRows: stickerPricingSetupRows,
    glassPricingSetupRows: glassPricingSetupRows,
    glassPricingUom: 'MM'
  };
}

// Live "declutter" spec summary, same purpose as renderCustomAquariumSummary/
// renderCustomStandSummary/renderStandaloneFiltrationSummary - reuses buildStandaloneStickerSpecText()
// (already exists for the cart line's item name) rather than duplicating its field-reading logic.
function renderStandaloneStickerSummary() {
  const summaryEl = document.getElementById('standaloneStickerSummary');
  const unit = document.getElementById('standaloneStickerUnit').value;
  if (!unit) {
    summaryEl.innerHTML = '';
    return;
  }
  const qty = document.getElementById('standaloneStickerQty').value || '1';
  summaryEl.innerHTML = `
    <div><strong>Build:</strong> ${buildStandaloneStickerSpecText()}</div>
    <div><strong>Quantity:</strong> ${qty}</div>
  `;
}

async function updateStandaloneStickerPriceEstimate() {
  const box = document.getElementById('customPriceEstimateStandaloneSticker');
  renderStandaloneStickerSummary();

  if (!document.getElementById('standaloneStickerUnit').value) {
    box.textContent = 'Select a unit of measure to see a price estimate.';
    return;
  }

  await ensureGlassPricingLoaded();

  const result = window.CustomAquariumCalculator.calculateStandaloneSticker(buildStandaloneStickerPayload());
  if (!result.ok) {
    box.textContent = result.error || 'Enter valid dimensions to see a price estimate.';
    return;
  }

  box.innerHTML = `Estimated Price: ${formatMoney(result.totalPrice)}`;
}

function buildStandaloneStickerSpecText() {
  const type = document.getElementById('standaloneStickerType').value;
  const thickness = document.getElementById('standaloneStickerThickness').value;
  const length = document.getElementById('standaloneStickerLength').value;
  const width = document.getElementById('standaloneStickerWidth').value;
  const unit = document.getElementById('standaloneStickerUnit').value;
  const hasThickness = type === 'Rubber Matting' || type === 'Glass';
  const isRepair = type === 'Glass' && document.getElementById('standaloneStickerRepair').checked;

  return `${type}${isRepair ? ' REPAIR' : ''}${hasThickness ? ` (${thickness})` : ''} ${length}${unit} x ${width}${unit}`;
}

function buildStandaloneStickerCartLine(result) {
  return {
    categoryCode: 'CUSTOM-STICKER',
    itemCode: null,
    itemName: `Custom Accessory/Sticker - ${buildStandaloneStickerSpecText()}`,
    price: result && result.ok ? result.totalPrice : 0,
    quantity: standaloneStickerQty()
  };
}

// One reference photo per Type, per "add an image of the custom accessories so the user will have
// a reference" - files don't exist yet (no real product photos to source), so
// updateStandaloneStickerTypeImage below hides the <img> via onerror until someone drops a real
// file at each of these paths into docs/icons/. Filenames are deliberately plain/predictable so
// adding a photo later never needs a code change - just drop the file in with this exact name.
const standaloneStickerTypeImageMap = {
  'Tiles Sticker': 'icons/sticker-tiles.jpg',
  'Plain Sticker': 'icons/sticker-plain.jpg',
  'Rubber Matting': 'icons/sticker-rubber-matting.jpg',
  'Glass': 'icons/sticker-glass.jpg',
  'Acrylic': 'icons/sticker-acrylic.jpg',
  'Allum TopCover': 'icons/sticker-allum-topcover.jpg'
};

function updateStandaloneStickerTypeImage() {
  const type = document.getElementById('standaloneStickerType').value;
  const img = document.getElementById('standaloneStickerTypeImage');
  const path = standaloneStickerTypeImageMap[type];

  img.classList.add('hidden');
  if (!path) return;

  img.onerror = () => img.classList.add('hidden');
  img.onload = () => img.classList.remove('hidden');
  img.alt = `${type} reference photo`;
  img.src = path;
}

function setStandaloneStickerVisibilityState() {
  const type = document.getElementById('standaloneStickerType').value;
  const hasThickness = type === 'Rubber Matting' || type === 'Glass';
  document.getElementById('standaloneStickerThicknessWrap').classList.toggle('hidden', !hasThickness);

  const showRepair = type === 'Glass';
  document.getElementById('standaloneStickerRepairWrap').classList.toggle('hidden', !showRepair);
  if (!showRepair) document.getElementById('standaloneStickerRepair').checked = false;

  updateStandaloneStickerTypeImage();
}

function resetStandaloneStickerBuilder() {
  document.getElementById('standaloneStickerQty').value = '1';
  document.getElementById('standaloneStickerUnit').value = '';
  document.getElementById('standaloneStickerType').value = 'Tiles Sticker';
  document.getElementById('standaloneStickerThickness').value = '6mm';
  document.getElementById('standaloneStickerLength').value = '24';
  document.getElementById('standaloneStickerWidth').value = '12';
  document.getElementById('standaloneStickerRepair').checked = false;
  setStandaloneStickerVisibilityState();

  const errorMsg = document.getElementById('customStandaloneStickerErrorMsg');
  errorMsg.textContent = '';
  errorMsg.classList.add('hidden');
  document.getElementById('customPriceEstimateStandaloneSticker').textContent = 'Enter your sticker details to see a price estimate.';

  renderStandaloneStickerSummary();
}

// Reached from the post-Aquarium-checkout "Add Filtration" prompt - a sump's dimensions are
// usually smaller than (and independent of) the tank it filters, so unlike the Stand prompt this
// doesn't prefill any fields, just surfaces the aquarium's own measurements as a reference while
// the customer sizes the sump.
function showFiltrationAquariumAwarenessNote() {
  const length = document.getElementById('customLength').value;
  const width = document.getElementById('customWidth').value;
  const height = document.getElementById('customHeight').value;
  const unit = document.getElementById('customUnit').value;

  const note = document.getElementById('filtrationAquariumAwarenessNote');
  note.textContent = `For reference, this aquarium is ${length} x ${width} x ${height} ${unit}.`;
  note.classList.remove('hidden');
}

// Per-tab checkout-line computers, one per Customize tab. Each reads that tab's OWN current form
// fields (independent of which tab is actually active) and returns [] if that tab doesn't have a
// valid, priced estimate sitting in it (e.g. still at default/blank dimensions), or one or more
// {categoryCode, label, qty, amount, cartLine} rows if it does - Aquarium can return two (itself
// plus its embedded Filtration/Sump) when filtrationEnabled. Used by collectCustomizeCheckoutLines
// below to pull in every already-estimated tab, not just the one Checkout was clicked from.
function computeAquariumCheckoutLines() {
  // Same "must pick a unit first" gate updateCustomPriceEstimate already enforces on the live
  // price card - without it, buildCustomPayload's unit fallback to 'Inches' would let this compute
  // a "valid" price even though the customer never actually selected Unit of Measure yet.
  if (!document.getElementById('customUnit').value) return [];
  const result = window.CustomAquariumCalculator.calculateCustomAquarium(buildCustomPayload());
  if (!result.ok) return [];
  const qty = customAquariumQty();
  if (filtrationEnabled) {
    const split = splitCustomAquariumFiltrationPrice(result);
    return [
      { categoryCode: 'CUSTOM-AQUARIUM', label: `Custom Aquarium - ${buildCustomAquariumSpecText()}`, qty, amount: split.aquariumPrice * qty, cartLine: buildCustomAquariumCartLine(result) },
      { categoryCode: 'CUSTOM-FILTRATION', label: `Filtration/Sump (for Custom Aquarium) - ${buildFiltrationSpecText()}`, qty, amount: split.filtrationPrice * qty, cartLine: buildEmbeddedFiltrationCartLine(result) }
    ];
  }
  return [{ categoryCode: 'CUSTOM-AQUARIUM', label: `Custom Aquarium - ${buildCustomAquariumSpecText()}`, qty, amount: result.totalPrice * qty, cartLine: buildCustomAquariumCartLine(result) }];
}
function computeStandCheckoutLines() {
  if (!document.getElementById('standUnit').value) return [];
  const result = window.CustomAquariumCalculator.calculateStandaloneStand(buildCustomStandPayload());
  if (!result.ok) return [];
  const qty = customStandQty();
  return [{ categoryCode: 'CUSTOM-STAND', label: `Custom Stand - ${buildCustomStandSpecText()}`, qty, amount: result.totalPrice * qty, cartLine: buildCustomStandCartLine(result) }];
}
function computeFiltrationCheckoutLines() {
  if (!document.getElementById('standaloneFiltrationUnit').value) return [];
  const result = window.CustomAquariumCalculator.calculateStandaloneFiltration(buildStandaloneFiltrationPayload());
  if (!result.ok) return [];
  const qty = standaloneFiltrationQty();
  return [{ categoryCode: 'CUSTOM-FILTRATION', label: `Custom Filtration - ${buildStandaloneFiltrationSpecText()}`, qty, amount: result.totalPrice * qty, cartLine: buildStandaloneFiltrationCartLine(result) }];
}
function computeStickerCheckoutLines() {
  if (!document.getElementById('standaloneStickerUnit').value) return [];
  const result = window.CustomAquariumCalculator.calculateStandaloneSticker(buildStandaloneStickerPayload());
  if (!result.ok) return [];
  const qty = standaloneStickerQty();
  return [{ categoryCode: 'CUSTOM-STICKER', label: `Custom Accessory/Sticker - ${buildStandaloneStickerSpecText()}`, qty, amount: result.totalPrice * qty, cartLine: buildStandaloneStickerCartLine(result) }];
}

const CUSTOMIZE_LINE_COMPUTERS = {
  aquarium: computeAquariumCheckoutLines,
  stand: computeStandCheckoutLines,
  filtration: computeFiltrationCheckoutLines,
  stickers: computeStickerCheckoutLines
};

const CUSTOMIZE_CHECKOUT_TITLES = {
  aquarium: 'CUSTOM AQUARIUM ORDER SUMMARY',
  stand: 'CUSTOM STAND ORDER SUMMARY',
  filtration: 'CUSTOM FILTRATION ORDER SUMMARY',
  stickers: 'CUSTOM ACCESSORIES/STICKERS ORDER SUMMARY'
};

const CUSTOMIZE_TAB_LABELS = {
  aquarium: 'Aquarium',
  stand: 'Stand',
  filtration: 'Filtration',
  stickers: 'Accessory/Sticker'
};

// True when every one of `lines` (from a CUSTOMIZE_LINE_COMPUTERS entry) already sits in the cart
// exactly as computed right now (same category, name, price, and quantity) - i.e. the customer
// already added this tab's current estimate (via its own Add to Cart button, Checkout, or a prior
// answer to this same prompt) and hasn't changed anything on the tab since. Used to skip
// re-asking maybeAddCurrentTabEstimateToCart below for no reason.
function customizeLinesAlreadyInCart(lines) {
  return lines.every((line) => cart.some((cartLine) =>
    cartLine.categoryCode === line.cartLine.categoryCode &&
    cartLine.itemName === line.cartLine.itemName &&
    cartLine.price === line.cartLine.price &&
    cartLine.quantity === line.cartLine.quantity
  ));
}

// Fires right before switchCustomizeTab() moves the customer off of `activeCustomizeTab` onto a
// different one - per direct request, a tab that's already priced out shouldn't just be silently
// left behind if the customer wanders off to another tab without ever pressing that tab's own
// Checkout button. Only asks when the tab being LEFT actually has a valid, priced estimate right
// now (see CUSTOMIZE_LINE_COMPUTERS) that ISN'T already sitting in the cart as-is - nothing to
// offer for a still-blank/untouched tab, and nothing to re-ask about once it's already been added.
async function maybeAddCurrentTabEstimateToCart() {
  const computeLines = CUSTOMIZE_LINE_COMPUTERS[activeCustomizeTab];
  if (!computeLines) return;
  await ensureGlassPricingLoaded();
  const lines = computeLines();
  if (!lines.length) return;
  if (customizeLinesAlreadyInCart(lines)) return;

  const tabLabel = CUSTOMIZE_TAB_LABELS[activeCustomizeTab] || 'item';
  const total = lines.reduce((sum, line) => sum + line.amount, 0);
  const addToCart = await showConfirmModal(
    `You have an estimated ${tabLabel} (${formatMoney(total)}). Add it to your cart before switching tabs?`,
    'Yes, Add to Cart',
    'No, Skip'
  );
  if (!addToCart) return;

  const categoryCodes = new Set(lines.map((line) => line.categoryCode));
  cart = cart.filter((line) => !categoryCodes.has(line.categoryCode));
  lines.forEach((line) => cart.push(line.cartLine));
  saveCart();
}

// Wired to each Customize tab's own "Add to Cart" button (sits above that tab's Checkout button) -
// adds whatever's currently estimated on `type`'s own fields straight to the cart without leaving
// the tab or walking through the Order Summary/Checkout screen, so the customer can add one thing
// and keep building the next without losing their place. `msgEl` is a single dedicated
// success/error-text element per tab (not shared with that tab's own validation errorMsg element,
// to avoid the two stepping on each other's success/error styling).
async function addCustomizeTabToCart(type, msgEl) {
  await ensureGlassPricingLoaded();
  const lines = CUSTOMIZE_LINE_COMPUTERS[type]();
  if (!lines.length) {
    msgEl.textContent = 'Please fill in the required fields above to see a price before adding to cart.';
    msgEl.classList.remove('success-text');
    msgEl.classList.add('error-text');
    msgEl.classList.remove('hidden');
    return;
  }

  const categoryCodes = new Set(lines.map((line) => line.categoryCode));
  cart = cart.filter((line) => !categoryCodes.has(line.categoryCode));
  lines.forEach((line) => cart.push(line.cartLine));
  saveCart();

  const total = lines.reduce((sum, line) => sum + line.amount, 0);
  msgEl.textContent = `Added to cart (${formatMoney(total)}).`;
  msgEl.classList.remove('error-text');
  msgEl.classList.add('success-text');
  msgEl.classList.remove('hidden');
}

// Combines primaryType's own freshly-computed checkout line(s) (the tab Checkout was actually
// clicked from) with whatever else is ALREADY sitting in the cart - per direct request, Checkout
// should only proceed with items the customer actually has in their cart, not silently sweep in
// some other tab just because it happens to have a valid price sitting unsaved in its fields (that
// tab's own Add to Cart button, or the tab-switch prompt, is what puts it in the cart). primaryType
// always wins over any stale cart line with the same categoryCode (e.g. re-confirming Aquarium
// after editing it replaces the old CUSTOM-AQUARIUM cart line rather than showing both).
function collectCustomizeCheckoutLines(primaryType) {
  const primaryLines = CUSTOMIZE_LINE_COMPUTERS[primaryType]();
  const primaryCategoryCodes = new Set(primaryLines.map((line) => line.categoryCode));
  const cartLines = cart
    .filter((line) => !primaryCategoryCodes.has(line.categoryCode))
    .map((line) => ({
      categoryCode: line.categoryCode,
      label: line.itemName,
      qty: line.quantity,
      amount: line.price * line.quantity,
      cartLine: line
    }));
  return [...primaryLines, ...cartLines];
}

// Populates the receipt-styled checkout/review page (step "custom-checkout") with the company
// letterhead (same fields the Delivery Receipt page shows, via companyBranding.js) and one product
// row per item actually in the cart, plus the tab Checkout was just clicked from (see
// collectCustomizeCheckoutLines).
async function renderCustomCheckout() {
  const info = await fetchCompanyInfo();
  const logo = document.getElementById('checkoutLogo');
  if (info && info['LogoUrl']) {
    logo.src = info['LogoUrl'];
    logo.classList.remove('hidden');
  } else {
    logo.classList.add('hidden');
  }
  document.getElementById('checkoutCompanyName').textContent = (info && info['CompanyName']) || '';
  document.getElementById('checkoutFacebook').textContent = (info && info['FacebookUrl']) || '';
  document.getElementById('checkoutAddress').textContent = info && info['Address'] ? `Address : ${info['Address']}` : '';
  document.getElementById('checkoutContactNo').textContent = info && info['ContactNo'] ? `Contact No : ${info['ContactNo']}` : '';
  document.getElementById('checkoutDtiNo').textContent = info && info['DtiNo'] ? `DTI No.: ${info['DtiNo']}` : '';

  // All four Customize builders can now depend on centralized pricing (Aquarium/Filtration on
  // GlassPricingSetup, Stand on TubularPricingSetup, Stickers on both StickerPricingSetup and
  // GlassPricingSetup for its "Glass" type) - one shared await up front instead of repeating it
  // per builder below.
  await ensureGlassPricingLoaded();

  const primaryCategoryCodes = new Set(CUSTOMIZE_LINE_COMPUTERS[customBuilderType]().map((line) => line.categoryCode));
  const lines = collectCustomizeCheckoutLines(customBuilderType);
  // Only the specific per-tab title (matching the old single-tab behavior) when nothing else got
  // pulled in - as soon as another tab's estimate is combined in, "Aquarium" alone stops being an
  // accurate title for what's actually listed below.
  const onlyPrimaryType = lines.every((line) => primaryCategoryCodes.has(line.categoryCode));
  document.getElementById('checkoutTitle').textContent = onlyPrimaryType ? CUSTOMIZE_CHECKOUT_TITLES[customBuilderType] : 'CUSTOM ORDER SUMMARY';

  const grandTotal = lines.reduce((sum, line) => sum + line.amount, 0);
  document.getElementById('checkoutLinesBody').innerHTML = lines.length
    ? lines.map((line) => `
      <tr>
        <td>${line.label}</td>
        <td>${line.qty}</td>
        <td style="text-align:right;">${formatMoney(line.amount)}</td>
      </tr>
    `).join('')
    : '';
  document.getElementById('checkoutTotal').textContent = lines.length ? formatMoney(grandTotal) : 'Please review your details.';

  return lines;
}

function convertToInches(value, unit) {
  const num = Number(value) || 0;
  if (unit === 'CM') return num / 2.54;
  if (unit === 'MM') return num / 25.4;
  if (unit === 'Ft') return num * 12;
  return num;
}

// Finds the thinnest glass tier (starting from whatever's currently selected, upward) that
// validateGlassSafety actually considers safe for these dimensions - a single tier bump isn't
// always enough (e.g. a very large tank flagged at 6mm may still be unsafe at 10mm and need
// 12mm), so this walks the chart forward instead of guessing one step ahead. Returns null if
// even 12mm (the thickest option offered) still isn't enough.
function findSafeGlassTier(lengthIn, widthIn, heightIn, startingGlass) {
  const tiers = ['3mm', '6mm', '10mm', '12mm'];
  const startIdx = Math.max(tiers.indexOf(startingGlass), 0);
  for (let i = startIdx; i < tiers.length; i += 1) {
    const check = window.CustomAquariumCalculator.validateGlassSafety(lengthIn, widthIn, heightIn, tiers[i], true, false);
    if (check.isSafe) return tiers[i];
  }
  return null;
}

// Live safety check for the Dimensions step - auto-bumps the Glass Thickness dropdown upward
// whenever the current selection isn't safe for the entered L/W/H (never downgrades it), and
// explains why via customDimsGlassNotice. Runs on every dimension/unit/glass edit (see the
// customLength/customWidth/customHeight/customUnit/customGlass listeners below) so the customer
// already sees the right thickness and price before ever reaching customDimsNextBtn's own
// safety check, which mirrors this same validateGlassSafety/findSafeGlassTier pair as a fallback.
function applyCustomDimsGlassSafety() {
  const notice = document.getElementById('customDimsGlassNotice');
  const glassSelect = document.getElementById('customGlass');
  const unit = document.getElementById('customUnit').value;

  // Without a real unit there's no way to safely convert L/W/H to inches for the safety chart -
  // convertToInches would otherwise silently assume Inches, which could wrongly leave an unsafe
  // glass thickness selected (or bump it unnecessarily) before the customer has even said what
  // unit they're using.
  if (!unit) {
    notice.classList.add('hidden');
    return;
  }

  const lengthIn = convertToInches(document.getElementById('customLength').value, unit);
  const widthIn = convertToInches(document.getElementById('customWidth').value, unit);
  const heightIn = convertToInches(document.getElementById('customHeight').value, unit);

  if (!lengthIn || !widthIn || !heightIn) {
    notice.classList.add('hidden');
    return;
  }

  // isTempered is passed as true, same as customDimsNextBtn's own check further down - Tempered
  // Glass isn't collected until the Options step, so this shouldn't false-block on the 36in+ rule.
  const safety = window.CustomAquariumCalculator.validateGlassSafety(
    lengthIn, widthIn, heightIn, glassSelect.value, true, false
  );

  if (safety.isSafe) {
    notice.classList.add('hidden');
    return;
  }

  const suggestedGlass = safety.autoChangeTo || findSafeGlassTier(lengthIn, widthIn, heightIn, glassSelect.value);
  if (suggestedGlass) {
    glassSelect.value = suggestedGlass;
    notice.textContent = `Glass thickness was automatically increased to ${suggestedGlass} for these dimensions.`;
    notice.classList.remove('hidden');
  } else {
    // Already at 12mm (the thickest option) and still flagged unsafe - nothing left to auto-fix,
    // so just explain why instead of silently leaving an unsafe thickness selected.
    notice.textContent = safety.message;
    notice.classList.remove('hidden');
  }
}

// Mirrors the glass-thickness safety rules from the standalone custom aquarium calculator
// (WebAquariumCalculator/index.html's enforceOptionRules) - re-applied here because the wizard
// now collects dimensions/glass (step 2) and options (step 3) as separate steps instead of one
// page, so nothing else validates them together. Runs whenever an option checkbox changes, and
// once when the Options step is first entered (so the dimension-driven Tempered Glass rule
// applies even before the customer ticks anything).
async function enforceGlassThicknessRules() {
  const aio = document.getElementById('customAio');
  const lowIron = document.getElementById('customLowIron');
  const tempered = document.getElementById('customTempered');
  const rimless = document.getElementById('customRimless');
  const enclosure = document.getElementById('customEnclosure');
  const glass = document.getElementById('customGlass');
  const unit = document.getElementById('customUnit').value;
  const lengthIn = convertToInches(document.getElementById('customLength').value, unit);
  const widthIn = convertToInches(document.getElementById('customWidth').value, unit);
  const heightIn = convertToInches(document.getElementById('customHeight').value, unit);
  const temperedMandatory = widthIn >= 36 || heightIn >= 36;
  const messages = [];

  if (aio.checked && enclosure.checked) {
    enclosure.checked = false;
    messages.push('Enclosure was unchecked - AIO and Enclosure cannot both be selected.');
  }

  if (lowIron.checked) {
    tempered.checked = true;
    tempered.disabled = true;
  } else {
    tempered.disabled = temperedMandatory;
  }

  if (temperedMandatory && !tempered.checked) {
    tempered.checked = true;
    messages.push('Tempered Glass was enabled automatically - required when width or height reaches 36 inches or more.');
  }

  if (aio.checked && glass.value === '3mm') {
    const upgrade = await showConfirmModal(
      'AIO setups need a minimum of 6mm glass. Would you like to convert your aquarium into thicker glass? (Price change may vary)',
      'Yes, Upgrade Glass',
      'No, Keep Current'
    );
    if (upgrade) {
      glass.value = '6mm';
      messages.push('Glass thickness was increased to 6mm for your AIO setup.');
    } else {
      aio.checked = false;
      messages.push('AIO was unchecked since 6mm glass was declined.');
    }
  }

  if (lowIron.checked && tempered.checked && (glass.value === '3mm' || glass.value === '6mm')) {
    const upgrade = await showConfirmModal(
      'Low Iron Tempered glass needs a minimum of 10mm. Would you like to convert your aquarium into thicker glass? (Price change may vary)',
      'Yes, Upgrade Glass',
      'No, Keep Current'
    );
    if (upgrade) {
      glass.value = '10mm';
      messages.push('Glass thickness was increased to 10mm for Low Iron Tempered.');
    } else {
      lowIron.checked = false;
      tempered.disabled = temperedMandatory;
      if (!temperedMandatory) {
        tempered.checked = false;
      }
      messages.push('Low Iron was unchecked since 10mm glass was declined.');
    }
  }

  // Plain Tempered Glass (not via Low Iron, which already forces its own 10mm prompt above) still
  // needs a minimum of 10mm per direct request - asks the same way AIO/Low Iron/Rimless do below,
  // rather than silently bumping the thickness, since it changes the price.
  if (tempered.checked && !lowIron.checked && (glass.value === '3mm' || glass.value === '6mm')) {
    const upgrade = await showConfirmModal(
      'Tempering Glass starts at 10mm Glass Thickness. Would you like to proceed? (Price change may vary)',
      'Yes, Upgrade Glass',
      'No, Keep Current'
    );
    if (upgrade) {
      glass.value = '10mm';
      messages.push('Glass thickness was increased to 10mm for Tempered Glass.');
    } else if (temperedMandatory) {
      // Can't uncheck - required by the 36in+ dimension rule above - so the decline just keeps
      // the current (thinner) glass selected instead of forcing 10mm on them.
      messages.push('Tempered Glass is still required for these dimensions, even at the current glass thickness.');
    } else {
      tempered.checked = false;
      messages.push('Tempered Glass was unchecked since 10mm glass was declined.');
    }
  }

  // Rimless safety is gallon-based, not a fixed minimum like AIO/Low Iron above - mirrors
  // validateGlassSafety() in WebAquariumCalculator/custom-aquarium-calculator.js.
  if (rimless.checked) {
    const gallons = (lengthIn * widthIn * heightIn) / 231;
    const glassMm = Number((glass.value.match(/(\d+)/) || [0, 0])[1]);

    if (gallons >= 10 && gallons <= 15 && glassMm < 6) {
      const upgrade = await showConfirmModal(
        'Rimless 10-15 gallon tanks need a minimum of 6mm glass. Would you like to convert your aquarium into thicker glass? (Price change may vary)',
        'Yes, Upgrade Glass',
        'No, Keep Current'
      );
      if (upgrade) {
        glass.value = '6mm';
        messages.push('Glass thickness was increased to 6mm for your Rimless tank.');
      } else {
        rimless.checked = false;
        messages.push('Rimless was unchecked since 6mm glass was declined.');
      }
    } else if (gallons >= 30 && gallons <= 100 && glassMm < 10) {
      const upgrade = await showConfirmModal(
        'Rimless 30-100 gallon tanks need a minimum of 10mm glass. Would you like to convert your aquarium into thicker glass? (Price change may vary)',
        'Yes, Upgrade Glass',
        'No, Keep Current'
      );
      if (upgrade) {
        glass.value = '10mm';
        messages.push('Glass thickness was increased to 10mm for your Rimless tank.');
      } else {
        rimless.checked = false;
        messages.push('Rimless was unchecked since 10mm glass was declined.');
      }
    }
  }

  const notice = document.getElementById('customGlassNotice');
  if (messages.length > 0) {
    notice.textContent = messages.join(' ');
    notice.classList.remove('hidden');
  } else {
    notice.classList.add('hidden');
  }
}

function wireLocationToggle() {
  const amayaOpt = document.getElementById('locationAmaya');
  const gmaOpt = document.getElementById('locationGma');

  function select(value) {
    selectedLocation = value;
    amayaOpt.classList.toggle('selected', value === 'Amaya');
    gmaOpt.classList.toggle('selected', value === 'GMA');
  }

  amayaOpt.addEventListener('click', () => select('Amaya'));
  gmaOpt.addEventListener('click', () => select('GMA'));
}

function wireFulfillmentToggle() {
  const pickupOpt = document.getElementById('fulfillmentPickup');
  const deliveryOpt = document.getElementById('fulfillmentDelivery');
  const addressRow = document.getElementById('deliveryAddressRow');

  function select(value) {
    selectedFulfillment = value;
    pickupOpt.classList.toggle('selected', value === 'Pickup');
    deliveryOpt.classList.toggle('selected', value === 'Delivery');
    addressRow.classList.toggle('hidden', value !== 'Delivery');
  }

  pickupOpt.addEventListener('click', () => select('Pickup'));
  deliveryOpt.addEventListener('click', () => select('Delivery'));
}

// Accepts PH mobile numbers in local (09171234567), country-code (639171234567) or
// +-prefixed (+639171234567) form - anything else (e.g. "test") is rejected before it ever
// reaches submit_automated_order, which enforces this same pattern server-side as the real gate.
function isValidPhMobileNumber(raw) {
  const digits = (raw || '').replace(/\D/g, '');
  return /^(09\d{9}|639\d{9})$/.test(digits);
}

async function submitOrder(event) {
  event.preventDefault();
  const errorMsg = document.getElementById('submitErrorMsg');
  errorMsg.classList.add('hidden');

  const name = document.getElementById('customerName').value.trim();
  const phone = document.getElementById('customerPhone').value.trim();
  const email = document.getElementById('customerEmail').value.trim();
  const address = document.getElementById('deliveryAddress').value.trim();
  const notes = document.getElementById('orderNotes').value.trim();

  if (!name || !phone) {
    errorMsg.textContent = 'Please fill in your name and phone number.';
    errorMsg.classList.remove('hidden');
    return;
  }
  if (!isValidPhMobileNumber(phone)) {
    errorMsg.textContent = 'Please enter a valid mobile number, e.g. 09171234567.';
    errorMsg.classList.remove('hidden');
    return;
  }
  if (selectedFulfillment === 'Delivery' && !address) {
    errorMsg.textContent = 'Please enter a delivery address.';
    errorMsg.classList.remove('hidden');
    return;
  }
  if (cart.length === 0) {
    errorMsg.textContent = 'Your cart is empty.';
    errorMsg.classList.remove('hidden');
    return;
  }

  const submitBtn = document.getElementById('submitOrderBtn');
  submitBtn.disabled = true;
  submitBtn.textContent = 'Submitting...';

  const { data, error } = await supabaseClient.rpc('submit_automated_order', {
    p_customer_name: name,
    p_customer_phone: phone,
    p_customer_email: email || null,
    p_fulfillment_type: selectedFulfillment,
    p_delivery_address: selectedFulfillment === 'Delivery' ? address : null,
    p_notes: notes || null,
    p_location: selectedLocation,
    p_psid: messengerPsid,
    p_lines: cart.map((line) => ({
      category_code: line.categoryCode,
      item_code: line.itemCode,
      item_name: line.itemName,
      quantity: line.quantity,
      price: line.price
    }))
  });

  submitBtn.disabled = false;
  submitBtn.textContent = 'Submit Order Request';

  if (error) {
    errorMsg.textContent = 'Could not submit your order: ' + error.message;
    errorMsg.classList.remove('hidden');
    return;
  }

  // submit_automated_order returns a row (order_no, pancake_order_id, pancake_sync_status). Order
  // ID (our internal AO-##### number) always shows - it's assigned before the Pancake push even
  // runs, so it exists regardless of whether that push succeeded. Online Order ID (Pancake's own
  // number) only shows alongside it once the sync actually went through - showing both instead of
  // picking one avoids the confusion of a customer only ever seeing AO-##### when Pancake sync
  // failed/is pending, with no way to tell that's what happened.
  //
  // submit_automated_order no longer pushes to Pancake itself (see
  // supabase_automated_order_async_pancake_sync.sql) - it always comes back with
  // pancake_sync_status 'Pending' now, so the confirmation screen shows immediately with just the
  // order number, and pollAutomatedOrderPancakeStatus below fills in the Pancake number a moment
  // later once the background sync (fired right after, not awaited) actually lands.
  // Wrapped in try/catch purely as a diagnostic aid: the order is already safely committed server-
  // side at this point (submit_automated_order already returned successfully above), so nothing
  // here SHOULD be able to fail - but if it somehow does, this makes that failure visible (console
  // + on-screen message) instead of silently leaving the customer stuck on Step 4 with no
  // indication their order actually went through.
  try {
    const result = (data && data[0]) || {};
    document.getElementById('confirmationOrderNo').textContent = result.order_no;

    const onlineOrderNoBox = document.getElementById('confirmationOnlineOrderNo');
    const onlineOrderNoLabel = document.getElementById('confirmationOnlineOrderNoLabel');
    onlineOrderNoBox.classList.add('hidden');
    onlineOrderNoLabel.classList.add('hidden');

    if (result.order_no) {
      // Deliberately not awaited - this is what keeps order submission fast regardless of
      // Pancake's own latency. Runs in the background while the customer is already looking at
      // their confirmation screen; pollAutomatedOrderPancakeStatus below picks up the result once
      // it lands. supabaseClient.rpc(...) returns a PostgREST "thenable" builder, not a real
      // Promise - it only implements .then(), not .catch()/.finally(), so calling .catch()
      // directly on it throws "is not a function" (this is what was silently breaking every
      // single order's confirmation screen - the whole rest of submitOrder never got to run).
      // Promise.resolve(...) converts it into a genuine Promise first, so .catch() is safe here.
      Promise.resolve(supabaseClient.rpc('public_sync_automated_order_to_pancake', { p_order_no: result.order_no })).catch(() => {});
      pollAutomatedOrderPancakeStatus(result.order_no).catch((err) => console.error('pollAutomatedOrderPancakeStatus failed:', err));
    }

    cart = [];
    saveCart();
    goToStep(5);
  } catch (err) {
    console.error('submitOrder: order was created (see result above) but showing the confirmation screen failed:', err);
    errorMsg.textContent = 'Your order was submitted (order #' + ((data && data[0] && data[0].order_no) || '?') + '), but something went wrong showing the confirmation. Please take a screenshot of this and contact us.';
    errorMsg.classList.remove('hidden');
  }
}

// Briefly polls for the background Pancake sync (kicked off just above) to land, so the
// confirmation screen can reveal the real Pancake order number without the customer ever having to
// wait on it up front. 5 tries, 1.5s apart (~7.5s total) - generous for the normal case, and if it
// genuinely doesn't land in that window the screen just quietly stays as-is; the order itself is
// already confirmed either way, and the pg_cron safety net still catches it within a minute.
async function pollAutomatedOrderPancakeStatus(orderNo, attempt) {
  attempt = attempt || 0;
  if (attempt >= 5) return;

  await new Promise((resolve) => setTimeout(resolve, 1500));

  // The customer may have already left the confirmation step (e.g. started a new order) - stop
  // polling rather than surprise them with an unrelated screen update.
  if (document.getElementById('confirmationOrderNo').textContent !== orderNo) return;

  const { data, error } = await supabaseClient.rpc('public_get_automated_order_status', { p_order_no: orderNo });
  const status = !error && data && data[0];

  if (status && status.pancake_sync_status === 'Synced' && status.pancake_order_id) {
    const onlineOrderNoBox = document.getElementById('confirmationOnlineOrderNo');
    const onlineOrderNoLabel = document.getElementById('confirmationOnlineOrderNoLabel');
    onlineOrderNoBox.textContent = '#' + status.pancake_order_id;
    onlineOrderNoBox.classList.remove('hidden');
    onlineOrderNoLabel.classList.remove('hidden');
    return;
  }

  if (status && status.pancake_sync_status === 'Failed') return;

  await pollAutomatedOrderPancakeStatus(orderNo, attempt + 1);
}

// Puts the whole Customize flow back to its just-loaded defaults - per direct request, opening
// the Dimensions step should always feel like starting fresh, not resuming whatever was left over
// from a previous visit (e.g. after confirming one custom aquarium and starting a second, or
// backing out to the mode picker and re-entering Customize).
function resetCustomAquariumBuilder() {
  customAquariumMirrored = false;
  document.getElementById('customLength').value = '0';
  document.getElementById('customWidth').value = '0';
  document.getElementById('customHeight').value = '0';
  document.getElementById('customQty').value = '1';
  document.getElementById('customUnit').value = '';
  document.getElementById('customGlass').value = '6mm';
  document.getElementById('customSealant').value = '';

  ['customAio', 'customLowIron', 'customTempered', 'customRimless', 'customHighStrip', 'customAquascape', 'customEnclosure']
    .forEach((id) => { document.getElementById(id).checked = false; document.getElementById(id).disabled = false; });

  document.getElementById('sumpType').value = 'Undersump';
  document.getElementById('sumpLength').value = '18';
  document.getElementById('sumpWidth').value = '18';
  document.getElementById('sumpHeight').value = '18';
  ['sumpPiping', 'sumpOverflowBox', 'sumpFilterMedias', 'sumpAllumTopCover']
    .forEach((id) => { document.getElementById(id).checked = false; });

  filtrationEnabled = false;
  glassBeforeLowIron = null;
  glassBeforeRimless = null;

  ['customDimsErrorMsg', 'customDimsGlassNotice', 'customGlassNotice'].forEach((id) => {
    const el = document.getElementById(id);
    el.textContent = '';
    el.classList.add('hidden');
  });

  drawCustomPlaceholder('Enter your aquarium details to see a preview.');
  ['customPriceEstimateDims', 'customPriceEstimateFiltration'].forEach((id) => {
    const box = document.getElementById(id);
    if (box) box.textContent = 'Enter your aquarium details to see a price estimate.';
  });
  renderCustomAquariumSummary();
}

function resetWizard() {
  cart = [];
  saveCart();
  document.getElementById('detailsForm').reset();
  selectedFulfillment = 'Pickup';
  document.getElementById('fulfillmentPickup').classList.add('selected');
  document.getElementById('fulfillmentDelivery').classList.remove('selected');
  selectedLocation = 'Amaya';
  document.getElementById('locationAmaya').classList.add('selected');
  document.getElementById('locationGma').classList.remove('selected');
  document.getElementById('deliveryAddressRow').classList.add('hidden');
  goToStep(1);
}

// Closes the tab/window this wizard is running in - only works when the browser actually opened
// it via script (e.g. a Messenger-personalized link opened as a new tab); browsers block
// script-closing a tab the visitor navigated to directly, so window.close() silently does
// nothing in that case rather than erroring - fall back to a plain message telling them it's
// safe to close the tab themselves.
function exitOrderNow() {
  window.close();
  setTimeout(() => {
    if (!document.hidden) {
      window.alert('You can now safely close this tab.');
    }
  }, 300);
}

// Brief transitional loading state shown right after clicking Customize on the mode picker -
// purely for delight (there's no real work happening), per direct request for some animation and
// a "grab your tape measure" message before landing on the Aquarium/Stand/Filtration sub-choice.
// Also reused for switching between the Aquarium/Stand/Filtration/Accessories tabs themselves (see
// the customize-tab-btn click handler below) with its own icon/text/brand line, passed via
// `options` - defaults reproduce the original Customize-entry message unchanged so that call site
// doesn't need to change.
function showCustomizeLoading(durationMs = 1300, options = {}) {
  const overlay = document.getElementById('customizeLoadingOverlay');
  const icon = options.icon || '📏';
  const text = options.text || 'Grab your tape measure - we\'re going to start building!';
  const brand = options.brand || '';

  overlay.querySelector('.customize-loading-icon').textContent = icon;
  overlay.querySelector('.customize-loading-text').textContent = text;
  const brandEl = overlay.querySelector('.customize-loading-brand');
  brandEl.textContent = brand;
  brandEl.classList.toggle('hidden', !brand);

  overlay.classList.remove('hidden');
  return new Promise((resolve) => {
    setTimeout(() => {
      overlay.classList.add('hidden');
      resolve();
    }, durationMs);
  });
}

async function loadCompanyLogo() {
  const info = await fetchCompanyInfo();
  if (!info) return;
  const box = document.getElementById('companyLogoBox');
  if (info['LogoUrl']) {
    box.innerHTML = `<img src="${info['LogoUrl']}" alt="${info['CompanyName'] || 'Company logo'}" class="company-logo-img" />`;
    const watermark = document.getElementById('watermarkBg');
    if (watermark) watermark.style.backgroundImage = `url(${info['LogoUrl']})`;
  }
}

// Ongoing promo banner - public.PromotionSettings (see supabase_promotion_setting.sql), edited
// from General Setup. Public read (RLS grants anon SELECT directly, no RPC needed) since Order Now
// runs with no login/session at all.
async function loadPromotionBanner() {
  const banner = document.getElementById('promoBanner');
  if (!banner) return;

  const { data, error } = await supabaseClient
    .from('PromotionSettings')
    .select('*')
    .eq('"Id"', 1)
    .limit(1);

  const info = !error && data && data[0];
  const promoText = info && info['IsActive'] ? (info['PromoText'] || '').trim() : '';
  if (!promoText) {
    banner.classList.add('hidden');
    return;
  }

  banner.textContent = promoText;
  banner.classList.remove('hidden');
}

// ---- "Estimate Delivery" mode: self-service delivery price estimate, no login/order required.
// Mirrors js/deliveryQuote.js's staff-only in-house pricing path (base fee + rate/km + toll -
// see runInHouseQuote there) but sourced from public_get_delivery_quote_settings() (see
// supabase_public_delivery_estimate.sql) since a customer here has no staff username/password to
// call the staff-gated admin_get_public_portal_setting/staff_search_warehouses RPCs with.
// Deliberately lighter than the staff tool: fixed branch addresses (same two shown in Step 4's
// "Which branch?" picker, geocoded on demand rather than read from a saved Warehouse Lat/Lng), a
// non-draggable map (just a visual confirmation, not a fine-tuning tool), and no Lalamove option.

const DELIVERY_ESTIMATE_ORIGINS = {
  Amaya: 'Antero Soriano Highway, Amaya Dos, Tanza, Cavite',
  GMA: 'Blk 2 Lot 53 Brgy. Granados, General Mariano Alvarez, Cavite'
};

let deliveryEstimateSettingsPromise = null;
let deliveryEstimateGoogleMapsApiKey = null;
let deliveryEstimateBaseFee = null;
let deliveryEstimateRatePerKm = null;
let deliveryEstimateTollFee = 0;
let deliveryEstimateGoogleMapsReadyPromise = null;
const deliveryEstimateOriginGeocodeCache = {}; // origin key -> {lat, lng} (each fixed address only needs geocoding once)
let resolvedDeliveryEstimateDestination = null; // {lat, lng, address} from Places Autocomplete
let deliveryEstimateMapInstance = null;
let deliveryEstimateFromMarker = null;
let deliveryEstimateToMarker = null;

// 'inhouse' (base fee + rate/km + toll) or 'lalamove' (real Lalamove Quotation API price, via the
// same delivery-lalamove-quote proxy the staff Delivery Quote page uses) - per direct request to
// let the customer pick between the two, same choice deliveryQuote.js's deliveryMethodSelect
// already offers staff. Booking is intentionally NOT offered here (unlike the staff page) - this
// mode is quote-only, no login/order required.
let deliveryEstimateMethod = 'inhouse';
let deliveryEstimateVehicleTypes = []; // [{key, description}] from delivery-lalamove-vehicle-types
let deliveryEstimateVehicleTypesLoaded = false;

// Lazy-loaded once, the first time the customer opens this mode - avoids the extra round trip/
// Google Maps script load for anyone who never touches it, same "only pay for what's used" reasoning
// as loadLalamoveVehicleTypes in deliveryQuote.js.
function loadDeliveryEstimateSettings() {
  if (deliveryEstimateSettingsPromise) return deliveryEstimateSettingsPromise;

  deliveryEstimateSettingsPromise = supabaseClient.rpc('public_get_delivery_quote_settings').then(({ data, error }) => {
    if (error) {
      console.error('public_get_delivery_quote_settings failed:', error);
      return;
    }
    const byKey = {};
    (data || []).forEach((row) => { byKey[row.setting_key] = row.setting_value; });
    deliveryEstimateGoogleMapsApiKey = byKey.GOOGLE_MAPS_API_KEY || null;
    deliveryEstimateBaseFee = byKey.DELIVERY_BASE_FEE != null && byKey.DELIVERY_BASE_FEE !== '' ? Number(byKey.DELIVERY_BASE_FEE) : null;
    deliveryEstimateRatePerKm = byKey.DELIVERY_RATE_PER_KM != null && byKey.DELIVERY_RATE_PER_KM !== '' ? Number(byKey.DELIVERY_RATE_PER_KM) : null;
    deliveryEstimateTollFee = byKey.DELIVERY_TOLL_FEE != null && byKey.DELIVERY_TOLL_FEE !== '' ? Number(byKey.DELIVERY_TOLL_FEE) : 0;
  });

  return deliveryEstimateSettingsPromise;
}

function loadDeliveryEstimateGoogleMapsScript() {
  if (deliveryEstimateGoogleMapsReadyPromise) return deliveryEstimateGoogleMapsReadyPromise;

  deliveryEstimateGoogleMapsReadyPromise = loadDeliveryEstimateSettings().then(() => new Promise((resolve, reject) => {
    if (!deliveryEstimateGoogleMapsApiKey) {
      reject(new Error('Delivery estimate is not available right now - please contact us directly for a delivery quote.'));
      return;
    }
    const script = document.createElement('script');
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(deliveryEstimateGoogleMapsApiKey)}&libraries=places`;
    script.async = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error('Failed to load the map. Check your connection and try again.'));
    document.head.appendChild(script);
  }));

  return deliveryEstimateGoogleMapsReadyPromise;
}

function deliveryEstimateGeocode(address) {
  return loadDeliveryEstimateGoogleMapsScript().then(() => {
    const geocoder = new google.maps.Geocoder();
    return new Promise((resolve) => {
      geocoder.geocode({ address }, (results, status) => {
        resolve(status === 'OK' && results && results[0] ? results[0].geometry.location : null);
      });
    });
  });
}

async function resolveDeliveryEstimateOrigin(originKey) {
  if (deliveryEstimateOriginGeocodeCache[originKey]) return deliveryEstimateOriginGeocodeCache[originKey];

  const address = DELIVERY_ESTIMATE_ORIGINS[originKey];
  const location = await deliveryEstimateGeocode(address);
  if (!location) throw new Error(`Could not find the ${originKey} branch on the map - please contact us directly for a delivery quote.`);

  const resolved = { lat: location.lat(), lng: location.lng(), label: `${originKey} branch` };
  deliveryEstimateOriginGeocodeCache[originKey] = resolved;
  return resolved;
}

async function resolveDeliveryEstimateDestination() {
  const input = document.getElementById('deliveryEstimateDestInput');
  const address = input.value.trim();
  if (!address) throw new Error('Enter your delivery address.');

  // Reuse the Places Autocomplete pick's coordinates if the text hasn't been edited since -
  // same "skip a redundant Geocoder call" reasoning as deliveryQuote.js's resolveFromLocation.
  if (resolvedDeliveryEstimateDestination && resolvedDeliveryEstimateDestination.address === address) {
    return { lat: resolvedDeliveryEstimateDestination.lat, lng: resolvedDeliveryEstimateDestination.lng, label: address };
  }

  const location = await deliveryEstimateGeocode(address);
  if (!location) throw new Error(`Could not find "${address}" on the map. Try a more specific address.`);
  return { lat: location.lat(), lng: location.lng(), label: address };
}

function getDeliveryEstimateDrivingDistance(origin, destination) {
  return loadDeliveryEstimateGoogleMapsScript().then(() => {
    const service = new google.maps.DistanceMatrixService();
    return new Promise((resolve, reject) => {
      service.getDistanceMatrix({
        origins: [origin],
        destinations: [destination],
        travelMode: 'DRIVING',
        unitSystem: google.maps.UnitSystem.METRIC
      }, (response, status) => {
        if (status !== 'OK') {
          reject(new Error(`Could not calculate driving distance (${status}).`));
          return;
        }
        const element = response?.rows?.[0]?.elements?.[0];
        if (!element || element.status !== 'OK') {
          reject(new Error('No driving route found to that address.'));
          return;
        }
        resolve({ distanceMeters: element.distance.value, distanceText: element.distance.text, durationText: element.duration.text });
      });
    });
  });
}

// Same route-shape toll heuristic as deliveryQuote.js's routeUsesTolls - compares the default
// route against a forced no-tolls route; a distance/duration difference means the default route
// used a toll road.
function deliveryEstimateRouteUsesTolls(origin, destination) {
  return loadDeliveryEstimateGoogleMapsScript().then(() => {
    const directionsService = new google.maps.DirectionsService();
    const requestRoute = (avoidTolls) => new Promise((resolve, reject) => {
      directionsService.route({ origin, destination, travelMode: google.maps.TravelMode.DRIVING, avoidTolls }, (result, status) => {
        if (status !== 'OK' || !result.routes || !result.routes[0]) {
          reject(new Error(`Could not check for toll roads (${status}).`));
          return;
        }
        resolve(result.routes[0]);
      });
    });

    return Promise.all([requestRoute(false), requestRoute(true)]).then(([normalRoute, noTollRoute]) => {
      const normalLeg = normalRoute.legs[0];
      const noTollLeg = noTollRoute.legs[0];
      return normalLeg.distance.value !== noTollLeg.distance.value || normalLeg.duration.value !== noTollLeg.duration.value;
    });
  });
}

async function fetchDeliveryEstimateTollPrice(origin, destination) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-toll-price`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({ origin, destination })
  });
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw new Error(body?.error || `Toll price lookup failed (${response.status}).`);
  }
  return response.json();
}

// Same fallback ladder as deliveryQuote.js's resolveTollFee: a real Google per-route price first,
// then the configured flat DELIVERY_TOLL_FEE applied only when the route-shape heuristic detects
// an actual toll road, defaulting to applying it if that heuristic itself fails.
async function resolveDeliveryEstimateTollFee(origin, destination) {
  try {
    const googleToll = await fetchDeliveryEstimateTollPrice(origin, destination);
    if (googleToll.hasTollInfo && googleToll.estimatedPrice > 0) {
      return { amount: googleToll.estimatedPrice, detected: true, source: 'google' };
    }
  } catch (err) {
    console.warn('Google toll price lookup unavailable, falling back to configured toll fee:', err);
  }

  if (!(deliveryEstimateTollFee > 0)) return { amount: 0, detected: null, source: 'none' };

  try {
    const usesToll = await deliveryEstimateRouteUsesTolls(origin, destination);
    return { amount: usesToll ? deliveryEstimateTollFee : 0, detected: usesToll, source: 'flat' };
  } catch (err) {
    console.error('Could not detect toll road usage, defaulting to applying the configured toll fee:', err);
    return { amount: deliveryEstimateTollFee, detected: null, source: 'flat' };
  }
}

async function ensureDeliveryEstimateMap() {
  await loadDeliveryEstimateGoogleMapsScript();
  if (deliveryEstimateMapInstance) return deliveryEstimateMapInstance;
  const mapEl = document.getElementById('deliveryEstimateMap');
  mapEl.classList.remove('hidden');
  deliveryEstimateMapInstance = new google.maps.Map(mapEl, { center: { lat: 12.8797, lng: 121.7740 }, zoom: 6 });
  return deliveryEstimateMapInstance;
}

function refitDeliveryEstimateMap() {
  if (!deliveryEstimateMapInstance) return;

  if (deliveryEstimateFromMarker && deliveryEstimateToMarker) {
    const bounds = new google.maps.LatLngBounds();
    bounds.extend(deliveryEstimateFromMarker.getPosition());
    bounds.extend(deliveryEstimateToMarker.getPosition());
    deliveryEstimateMapInstance.fitBounds(bounds);
  } else if (deliveryEstimateFromMarker) {
    deliveryEstimateMapInstance.setCenter(deliveryEstimateFromMarker.getPosition());
    deliveryEstimateMapInstance.setZoom(14);
  }
}

function deliveryEstimateReverseGeocode(lat, lng) {
  return loadDeliveryEstimateGoogleMapsScript().then(() => {
    const geocoder = new google.maps.Geocoder();
    return new Promise((resolve) => {
      geocoder.geocode({ location: { lat, lng } }, (results, status) => {
        resolve(status === 'OK' && results && results[0] ? results[0].formatted_address : null);
      });
    });
  });
}

// Dragging the origin pin corrects that branch's pinned location for this session (rather than
// introducing a separate "Other address" origin, which doesn't apply here - orders only ever ship
// from an actual branch) - same reverse-geocode-then-re-quote pattern as deliveryQuote.js's
// handleFromMarkerDragEnd, per "let the user drag the pin point same on our web portal delivery
// quote... same experience".
async function handleDeliveryEstimateFromMarkerDragEnd(latLng) {
  const lat = latLng.lat();
  const lng = latLng.lng();
  const address = (await deliveryEstimateReverseGeocode(lat, lng)) || `${lat.toFixed(6)}, ${lng.toFixed(6)}`;

  const originKey = document.getElementById('deliveryEstimateOriginSelect').value;
  const resolved = { lat, lng, label: `${originKey} branch (adjusted)` };
  deliveryEstimateOriginGeocodeCache[originKey] = resolved;
  if (deliveryEstimateFromMarker) deliveryEstimateFromMarker.setTitle(`From: ${address}`);

  runDeliveryEstimate();
}

async function handleDeliveryEstimateToMarkerDragEnd(latLng) {
  const lat = latLng.lat();
  const lng = latLng.lng();
  const address = (await deliveryEstimateReverseGeocode(lat, lng)) || `${lat.toFixed(6)}, ${lng.toFixed(6)}`;

  resolvedDeliveryEstimateDestination = { lat, lng, address };
  document.getElementById('deliveryEstimateDestInput').value = address;
  if (deliveryEstimateToMarker) deliveryEstimateToMarker.setTitle(`To: ${address}`);

  runDeliveryEstimate();
}

// Split into separate From/To setters (rather than one combined "render both" call) so the
// origin branch can be plotted immediately on opening this mode - per "show the map already upon
// loading, same functionality [as] delivery [Quote]" - instead of waiting for a destination to be
// entered. Draggable, same as deliveryQuote.js's staff map (see handleDeliveryEstimateFromMarkerDragEnd/
// handleDeliveryEstimateToMarkerDragEnd above) - lets the customer nudge a slightly-off geocode
// result themselves instead of being stuck with whatever Google guessed.
async function setDeliveryEstimateFromMarker(loc) {
  await ensureDeliveryEstimateMap();
  if (deliveryEstimateFromMarker) deliveryEstimateFromMarker.setMap(null);

  deliveryEstimateFromMarker = new google.maps.Marker({
    position: { lat: loc.lat, lng: loc.lng },
    map: deliveryEstimateMapInstance,
    title: `From: ${loc.label}`,
    icon: 'https://maps.google.com/mapfiles/ms/icons/green-dot.png',
    draggable: true
  });
  deliveryEstimateFromMarker.addListener('dragend', () => handleDeliveryEstimateFromMarkerDragEnd(deliveryEstimateFromMarker.getPosition()));
  refitDeliveryEstimateMap();
}

async function setDeliveryEstimateToMarker(loc) {
  await ensureDeliveryEstimateMap();
  if (deliveryEstimateToMarker) deliveryEstimateToMarker.setMap(null);

  deliveryEstimateToMarker = new google.maps.Marker({
    position: { lat: loc.lat, lng: loc.lng },
    map: deliveryEstimateMapInstance,
    title: `To: ${loc.label}`,
    draggable: true
  });
  deliveryEstimateToMarker.addListener('dragend', () => handleDeliveryEstimateToMarkerDragEnd(deliveryEstimateToMarker.getPosition()));
  refitDeliveryEstimateMap();
}

// Shows the currently-selected origin branch on the map right away - mirrors deliveryQuote.js's
// "show the map directly upon open Delivery Quote" behavior. Best-effort: a geocoding hiccup here
// shouldn't block the customer from still typing an address and clicking Get Estimate, so failures
// are just logged, same as deliveryQuote.js's own init()-time preview.
async function showDeliveryEstimateOriginPreview() {
  const originKey = document.getElementById('deliveryEstimateOriginSelect').value;
  try {
    await loadDeliveryEstimateSettings();
    const from = await resolveDeliveryEstimateOrigin(originKey);
    await setDeliveryEstimateFromMarker(from);
  } catch (err) {
    console.error('Could not resolve origin branch for map preview:', err);
    await ensureDeliveryEstimateMap();
  }
}

function wireDeliveryEstimatePlacesAutocomplete() {
  const input = document.getElementById('deliveryEstimateDestInput');
  loadDeliveryEstimateGoogleMapsScript().then(() => {
    const autocomplete = new google.maps.places.Autocomplete(input, {
      fields: ['geometry'],
      componentRestrictions: { country: 'ph' }
    });
    autocomplete.addListener('place_changed', () => {
      const place = autocomplete.getPlace();
      if (!place.geometry || !place.geometry.location) return;
      const loc = {
        lat: place.geometry.location.lat(),
        lng: place.geometry.location.lng(),
        address: input.value.trim()
      };
      resolvedDeliveryEstimateDestination = loc;

      // Per "once the delivery address is filled in, auto estimate - the map pin should move
      // too", same "picking a suggestion is itself a strong enough signal to price it
      // immediately" reasoning as deliveryQuote.js's toAddressInput Autocomplete handler. Moves
      // the pin right away rather than waiting for runDeliveryEstimate's own marker update, so
      // there's instant feedback even while the estimate itself is still in flight.
      setDeliveryEstimateToMarker({ ...loc, label: loc.address });
      runDeliveryEstimate();
    });
  }).catch((err) => console.error('Failed to initialize address suggestions:', err));

  // Typing invalidates any previously picked suggestion, same as deliveryQuote.js's toAddressInput -
  // otherwise an edited-but-not-re-picked address would silently keep quoting the old coordinates.
  input.addEventListener('input', () => { resolvedDeliveryEstimateDestination = null; });
}

function formatDeliveryEstimateCurrency(amount) {
  return '₱' + Number(amount || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// Calls the delivery-lalamove-vehicle-types Supabase Edge Function - same proxy deliveryQuote.js
// uses, already anon-callable with no staff login required. Lazy-loaded once, the first time the
// customer switches to Lalamove.
async function loadDeliveryEstimateVehicleTypes() {
  const select = document.getElementById('deliveryEstimateVehicleTypeSelect');
  if (deliveryEstimateVehicleTypesLoaded) return;
  deliveryEstimateVehicleTypesLoaded = true;

  try {
    const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-lalamove-vehicle-types`, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
        'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
      }
    });

    const body = await response.json().catch(() => null);
    if (!response.ok) throw new Error(body?.error || `Failed to load vehicle types (${response.status}).`);

    deliveryEstimateVehicleTypes = body.vehicleTypes || [];
    if (deliveryEstimateVehicleTypes.length === 0) throw new Error('No vehicle types available for this account/market.');

    select.innerHTML = deliveryEstimateVehicleTypes.map((v) => `<option value="${v.key}" title="${v.description}">${v.key}</option>`).join('');
    const motorcycleOption = deliveryEstimateVehicleTypes.find((v) => v.key === 'MOTORCYCLE');
    if (motorcycleOption) select.value = motorcycleOption.key;
  } catch (err) {
    console.error('Could not load Lalamove vehicle types:', err);
    select.innerHTML = `<option value="">Failed to load - ${err.message}</option>`;
  }
}

// Calls the delivery-lalamove-quote Supabase Edge Function - same signing proxy deliveryQuote.js
// uses in front of Lalamove's Quotation API, already anon-callable with no staff login required.
async function fetchDeliveryEstimateLalamoveQuote(origin, destination, serviceType) {
  const response = await fetch(`${window.APP_CONFIG.SUPABASE_URL}/functions/v1/delivery-lalamove-quote`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${window.APP_CONFIG.SUPABASE_ANON_KEY}`,
      'apikey': window.APP_CONFIG.SUPABASE_ANON_KEY
    },
    body: JSON.stringify({ origin, destination, serviceType })
  });
  const body = await response.json().catch(() => null);
  if (!response.ok) throw new Error(body?.error || `Lalamove quote failed (${response.status}).`);
  return body;
}

// In-house pricing path (base fee + rate/km + toll) - split out of runDeliveryEstimate so it can
// sit alongside runDeliveryEstimateLalamove below, same split as deliveryQuote.js's
// runInHouseQuote/runLalamoveQuote.
async function runDeliveryEstimateInHouse(from, to) {
  if (deliveryEstimateBaseFee == null || deliveryEstimateRatePerKm == null) {
    throw new Error('Delivery pricing isn\'t configured yet - please contact us directly for a delivery quote.');
  }

  const origin = { lat: from.lat, lng: from.lng };
  const destination = { lat: to.lat, lng: to.lng };

  const [{ distanceMeters, distanceText, durationText }, toll] = await Promise.all([
    getDeliveryEstimateDrivingDistance(origin, destination),
    resolveDeliveryEstimateTollFee(origin, destination)
  ]);

  const distanceKm = distanceMeters / 1000;
  const price = deliveryEstimateBaseFee + deliveryEstimateRatePerKm * distanceKm + toll.amount;

  document.getElementById('deliveryEstimateDistance').textContent = distanceText;
  document.getElementById('deliveryEstimateDuration').textContent = durationText;
  document.getElementById('deliveryEstimatePrice').textContent = formatDeliveryEstimateCurrency(price);

  let tollPart = '';
  if (toll.amount > 0) {
    tollPart = ` + ${formatDeliveryEstimateCurrency(toll.amount)} toll fee`;
  } else if (toll.detected === false) {
    tollPart = ' (no toll road detected on this route)';
  }
  document.getElementById('deliveryEstimateBreakdown').textContent =
    `${formatDeliveryEstimateCurrency(deliveryEstimateBaseFee)} base fee + ${formatDeliveryEstimateCurrency(deliveryEstimateRatePerKm)}/km x ${distanceKm.toFixed(2)} km${tollPart}, from ${from.label} to your address.`;
}

// Lalamove pricing path - calls their real Quotation API (via the signing proxy) instead of the
// in-house formula. Quote-only: unlike deliveryQuote.js, there is no Book Delivery here - this
// mode never asks for sender/recipient contact details, so nothing here is bookable as-is.
async function runDeliveryEstimateLalamove(from, to) {
  const serviceType = document.getElementById('deliveryEstimateVehicleTypeSelect').value || undefined;
  const quote = await fetchDeliveryEstimateLalamoveQuote(
    { lat: from.lat, lng: from.lng, address: from.label },
    { lat: to.lat, lng: to.lng, address: to.label },
    serviceType
  );

  const distanceKm = quote.distanceMeters != null ? quote.distanceMeters / 1000 : null;

  document.getElementById('deliveryEstimateDistance').textContent = distanceKm != null ? `${distanceKm.toFixed(2)} km` : '-';
  document.getElementById('deliveryEstimateDuration').textContent = 'N/A (Lalamove)';
  document.getElementById('deliveryEstimatePrice').textContent = quote.total != null
    ? formatDeliveryEstimateCurrency(quote.total)
    : '-';

  document.getElementById('deliveryEstimateBreakdown').textContent =
    `Lalamove quote - ${quote.serviceType}, from ${from.label} to your address.`;
}

async function runDeliveryEstimate() {
  const errorEl = document.getElementById('deliveryEstimateError');
  const loadingEl = document.getElementById('deliveryEstimateLoading');
  const resultEl = document.getElementById('deliveryEstimateResult');
  const getBtn = document.getElementById('deliveryEstimateGetBtn');
  errorEl.classList.add('hidden');
  resultEl.classList.add('hidden');

  const originKey = document.getElementById('deliveryEstimateOriginSelect').value;
  if (!originKey) {
    errorEl.textContent = 'Pick which branch you\'re ordering from.';
    errorEl.classList.remove('hidden');
    return;
  }

  getBtn.disabled = true;
  loadingEl.classList.remove('hidden');

  try {
    await loadDeliveryEstimateSettings();

    const [from, to] = await Promise.all([
      resolveDeliveryEstimateOrigin(originKey),
      resolveDeliveryEstimateDestination()
    ]);

    if (deliveryEstimateMethod === 'lalamove') {
      await runDeliveryEstimateLalamove(from, to);
    } else {
      await runDeliveryEstimateInHouse(from, to);
    }

    resultEl.classList.remove('hidden');
    await setDeliveryEstimateFromMarker(from);
    await setDeliveryEstimateToMarker(to);
  } catch (err) {
    errorEl.textContent = err.message;
    errorEl.classList.remove('hidden');
  } finally {
    getBtn.disabled = false;
    loadingEl.classList.add('hidden');
  }
}

(function init() {
  captureMessengerPsid();
  prefillCustomerDetailsFromPsid();
  loadCompanyLogo();
  loadPromotionBanner();
  loadCategories();
  renderCart();
  updateViewCartLink();
  wireLocationToggle();
  wireFulfillmentToggle();
  setupCustomCanvas();
  wireCustomAquariumRotate();
  setupStandCanvas();
  // Clones the Payment & Release policy (see paymentPolicyTemplate) into both order-summary
  // screens - Step 3 (Standard flow cart review) and custom-checkout (Customize flow) - so it's
  // no longer a separate wizard step the customer has to click through.
  const policyTemplate = document.getElementById('paymentPolicyTemplate');
  document.getElementById('cartPaymentPolicyBox').appendChild(policyTemplate.content.cloneNode(true));
  document.getElementById('checkoutPaymentPolicyBox').appendChild(policyTemplate.content.cloneNode(true));

  // One-time initial reset for all four Customize tabs (price estimate boxes, safety banners,
  // canvas placeholders) so their derived UI matches the fields' HTML defaults from the very first
  // paint - previously each ran only once, right when the customer entered that flow from the
  // customize-choice picker; now all four tabs exist on the page at once (see the "so they can see
  // the stand / aquarium / filtration only in one page" tab bar below), so there's no later
  // "entry" moment to hook this into.
  resetCustomAquariumBuilder();
  resetCustomStandBuilder();
  resetStandaloneFiltrationBuilder();
  resetStandaloneStickerBuilder();
  goToStep(0);

  document.getElementById('modeStandardBtn').addEventListener('click', () => goToStep(1));
  document.getElementById('modeCustomizeBtn').addEventListener('click', async () => {
    await showCustomizeLoading();
    goToStep('customize-tabs');
  });
  document.getElementById('customizeTabsBackBtn').addEventListener('click', () => goToStep(0));
  document.querySelectorAll('.customize-tab-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      // Skip the loading flash when re-clicking the tab that's already showing - nothing is
      // actually changing, so there's nothing to "build".
      if (btn.dataset.tab !== activeCustomizeTab) {
        await maybeAddCurrentTabEstimateToCart();
        await showCustomizeLoading(700, { icon: '🏗️', text: 'Building something great!', brand: 'RSPETSTOP' });
      }
      switchCustomizeTab(btn.dataset.tab);
      if (btn.dataset.tab === 'stand') {
        await maybeOfferStandPrefillFromAquarium();
      }
    });
  });
  document.getElementById('standAdviseFromAquariumLink').addEventListener('click', (event) => {
    event.preventDefault();
    prefillStandFromAquarium();
  });
  document.getElementById('modeDeliveryBtn').addEventListener('click', () => {
    deliveryEstimateReturnStep = 0;
    document.getElementById('deliveryEstimateStartOrderBtn').classList.remove('hidden');
    goToStep('delivery-estimate');
    // Show the map immediately on open, per "show the map already upon loading, same
    // functionality [as] delivery [Quote]" - plots the default-selected origin branch right away
    // rather than waiting for Get Estimate.
    showDeliveryEstimateOriginPreview();
  });
  document.getElementById('backToModeBtn').addEventListener('click', () => goToStep(0));
  document.getElementById('backToCategoriesBtn').addEventListener('click', () => goToStep(1));

  // "Not sure of the delivery fee? Estimate it here" link on Step 4 - lets the customer check the
  // fee without abandoning the order already in progress. Carries over whatever they've already
  // filled in (branch, delivery address) and returns to Step 4 (not the mode picker) on Back.
  // Start an Order is hidden here since starting a new order would abandon the one they're on.
  document.getElementById('detailsEstimateDeliveryLink').addEventListener('click', (event) => {
    event.preventDefault();
    deliveryEstimateReturnStep = 4;
    document.getElementById('deliveryEstimateStartOrderBtn').classList.add('hidden');
    document.getElementById('deliveryEstimateOriginSelect').value = selectedLocation;
    const address = document.getElementById('deliveryAddress').value.trim();
    if (address) document.getElementById('deliveryEstimateDestInput').value = address;
    goToStep('delivery-estimate');
    showDeliveryEstimateOriginPreview();
  });

  document.getElementById('deliveryEstimateBackBtn').addEventListener('click', () => goToStep(deliveryEstimateReturnStep));
  document.getElementById('deliveryEstimateGetBtn').addEventListener('click', runDeliveryEstimate);
  document.getElementById('deliveryEstimateStartOrderBtn').addEventListener('click', () => goToStep(1));
  // Picking a different branch is itself a request to re-preview that location on the map.
  document.getElementById('deliveryEstimateOriginSelect').addEventListener('change', showDeliveryEstimateOriginPreview);
  wireDeliveryEstimatePlacesAutocomplete();

  // RSPetStop Delivery vs Lalamove toggle - same two-option touch UI as the Pickup/Delivery
  // fulfillment toggle already used in Step 4, per direct request to let the customer choose.
  const deliveryEstimateMethodInhouseBtn = document.getElementById('deliveryEstimateMethodInhouse');
  const deliveryEstimateMethodLalamoveBtn = document.getElementById('deliveryEstimateMethodLalamove');
  const deliveryEstimateVehicleTypeRow = document.getElementById('deliveryEstimateVehicleTypeRow');
  const deliveryEstimateInhouseNote = document.getElementById('deliveryEstimateInhouseNote');
  const deliveryEstimateLalamoveDisclaimer = document.getElementById('deliveryEstimateLalamoveDisclaimer');

  async function selectDeliveryEstimateMethod(method) {
    deliveryEstimateMethod = method;
    deliveryEstimateMethodInhouseBtn.classList.toggle('selected', method === 'inhouse');
    deliveryEstimateMethodLalamoveBtn.classList.toggle('selected', method === 'lalamove');
    deliveryEstimateVehicleTypeRow.classList.toggle('hidden', method !== 'lalamove');
    deliveryEstimateInhouseNote.classList.toggle('hidden', method !== 'inhouse');
    deliveryEstimateLalamoveDisclaimer.classList.toggle('hidden', method !== 'lalamove');
    if (method === 'lalamove') await loadDeliveryEstimateVehicleTypes();

    // Per "if we switch from RSPetStop Delivery and Lalamove please auto compute estimate" - only
    // once a delivery address has actually been entered, same guard runDeliveryEstimate's own
    // validation would otherwise raise as an error on an empty first visit to this mode. Awaiting
    // loadDeliveryEstimateVehicleTypes above first means a switch to Lalamove re-quotes with the
    // real default vehicle type already selected, not a blank one.
    const destInput = document.getElementById('deliveryEstimateDestInput');
    if (destInput.value.trim()) {
      runDeliveryEstimate();
    }
  }

  deliveryEstimateMethodInhouseBtn.addEventListener('click', () => selectDeliveryEstimateMethod('inhouse'));
  deliveryEstimateMethodLalamoveBtn.addEventListener('click', () => selectDeliveryEstimateMethod('lalamove'));

  // Live-updates the aquarium preview canvas + glass-thickness safety check on the Dimensions
  // step itself as the customer types, same as the Options step's canvas already does via
  // updateCustomPriceEstimate() -> drawCustomAquarium(). applyCustomDimsGlassSafety() runs first
  // so a corrected glass thickness is reflected in the price/preview right after it.
  ['customLength', 'customWidth', 'customHeight'].forEach((id) => {
    document.getElementById(id).addEventListener('input', () => {
      applyCustomDimsGlassSafety();
      updateCustomPriceEstimate();
    });
  });
  // Re-runs the option-specific rules (enforceGlassThicknessRules) here too, not just on the
  // Options checkboxes' own change handlers below - per direct request: if the customer already
  // ticked Rimless (or AIO/Low Iron) and then comes back and manually picks a thinner Glass
  // Thickness (or changes Unit, which changes the gallons the Rimless rule is based on), that
  // combination needs to be re-validated, not just whatever combination existed at the moment the
  // checkbox was first ticked. applyCustomDimsGlassSafety() (the general dimension-vs-glass chart)
  // still runs first, same order as before.
  ['customUnit', 'customGlass'].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => {
      applyCustomDimsGlassSafety();
      enforceGlassThicknessRules().then(updateCustomPriceEstimate);
    });
  });

  // Sealant Color doesn't factor into price/glass-safety at all (buildCustomPayload doesn't even
  // send it to calculateCustomAquarium), but it IS one of the fields renderCustomAquariumSummary
  // shows on the live spec summary - this was the one option with no listener at all, so picking a
  // color left the summary showing a stale/blank "Sealant Color" until some other field's own
  // change happened to trigger a refresh. Plain updateCustomPriceEstimate() call, no
  // enforceGlassThicknessRules needed since this can't affect that check.
  document.getElementById('customSealant').addEventListener('change', () => updateCustomPriceEstimate());

  document.getElementById('customDimsAddToCartBtn').addEventListener('click', () => {
    addCustomizeTabToCart('aquarium', document.getElementById('customDimsAddToCartMsg'));
  });
  document.getElementById('customDimsNextBtn').addEventListener('click', async () => {
    customBuilderType = 'aquarium';
    const errorMsg = document.getElementById('customDimsErrorMsg');
    if (!document.getElementById('customUnit').value) {
      errorMsg.textContent = 'Please select a unit of measure.';
      errorMsg.classList.remove('hidden');
      return;
    }
    if (!document.getElementById('customSealant').value) {
      errorMsg.textContent = 'Please select a sealant color.';
      errorMsg.classList.remove('hidden');
      return;
    }
    // Length/Width/Height default to 0 (not a real size), so this can't be skipped by clicking
    // Next without touching them - the glass safety check just below would otherwise pass
    // trivially at 0x0x0 and let a customer through to Options with no real dimensions at all.
    if (
      !(Number(document.getElementById('customLength').value) > 0) ||
      !(Number(document.getElementById('customWidth').value) > 0) ||
      !(Number(document.getElementById('customHeight').value) > 0)
    ) {
      errorMsg.textContent = 'Please enter valid positive dimensions for your aquarium.';
      errorMsg.classList.remove('hidden');
      return;
    }

    // Glass-thickness-vs-dimension safety check, using the same chart as the standalone
    // calculator (WebAquariumCalculator/custom-aquarium-calculator.js's validateGlassSafety) -
    // runs right here on raw Length/Width/Height/Glass Thickness, checked separately from the
    // AIO/Low Iron/Rimless option-specific rules enforceGlassThicknessRules applies below.
    // isTempered is passed as true so the chart's general "tempered is mandatory at 36in+" branch
    // doesn't false-block here - that part is already auto-enforced regardless of what's picked.
    const unit = document.getElementById('customUnit').value;
    const glassSelect = document.getElementById('customGlass');
    const lengthIn = convertToInches(document.getElementById('customLength').value, unit);
    const widthIn = convertToInches(document.getElementById('customWidth').value, unit);
    const heightIn = convertToInches(document.getElementById('customHeight').value, unit);
    const safety = window.CustomAquariumCalculator.validateGlassSafety(
      lengthIn, widthIn, heightIn, glassSelect.value, true, false
    );

    if (!safety.isSafe) {
      const suggestedGlass = safety.autoChangeTo || findSafeGlassTier(lengthIn, widthIn, heightIn, glassSelect.value);

      if (!suggestedGlass) {
        // Already at the thickest option (12mm) and still flagged unsafe - nothing left to
        // upgrade to, so just block with the reason instead of offering a confirm modal.
        errorMsg.textContent = safety.message;
        errorMsg.classList.remove('hidden');
        return;
      }

      const upgrade = await showConfirmModal(
        `${safety.message} Would you like to upgrade to ${suggestedGlass} glass? (Price change may vary)`,
        'Yes, Upgrade Glass',
        'No, Keep Current'
      );

      if (upgrade) {
        glassSelect.value = suggestedGlass;
        errorMsg.classList.add('hidden');
      } else {
        errorMsg.textContent = safety.message;
        errorMsg.classList.remove('hidden');
        return;
      }
    } else {
      errorMsg.classList.add('hidden');
    }

    await enforceGlassThicknessRules();
    await updateCustomPriceEstimate();

    filtrationEnabled = await showConfirmModal(
      'Would you like to add Filtration to your custom aquarium?',
      'Yes, Add Filtration',
      'No, Skip'
    );
    if (filtrationEnabled) {
      // First visit to this build only - fills in the Undersump/Overhead Sump default dimensions
      // (see applySumpTypeDefaults) so the customer never sees a 0-size sump, then reflects that
      // in the price shown as soon as the step appears.
      applySumpTypeDefaults();
      await updateCustomPriceEstimate();
      goToStep('custom-filtration');
    } else {
      await renderCustomCheckout();
      goToStep('custom-checkout');
    }
  });

  document.getElementById('customFiltrationBackBtn').addEventListener('click', () => {
    switchCustomizeTab('aquarium');
    goToStep('customize-tabs');
  });
  document.getElementById('customFiltrationBackBtnTop').addEventListener('click', () => document.getElementById('customFiltrationBackBtn').click());
  document.getElementById('customFiltrationNextBtn').addEventListener('click', async () => {
    await renderCustomCheckout();
    goToStep('custom-checkout');
  });

  document.getElementById('sumpType').addEventListener('change', () => {
    applySumpTypeDefaults();
    updateCustomPriceEstimate();
  });
  ['sumpLength', 'sumpWidth', 'sumpHeight'].forEach((id) => {
    document.getElementById(id).addEventListener('input', () => updateCustomPriceEstimate());
  });
  ['sumpPiping', 'sumpOverflowBox', 'sumpFilterMedias', 'sumpAllumTopCover']
    .forEach((id) => document.getElementById(id).addEventListener('change', () => updateCustomPriceEstimate()));

  // ---- Stand sub-flow navigation/wiring ----
  document.getElementById('standTubular1x1').addEventListener('click', () => { selectStandTubular('1x1'); updateCustomStandPriceEstimate(); });
  document.getElementById('standTubular1_5x1_5').addEventListener('click', () => { selectStandTubular('1.5x1.5'); updateCustomStandPriceEstimate(); });
  document.getElementById('standTubular2x2').addEventListener('click', () => { selectStandTubular('2x2'); updateCustomStandPriceEstimate(); });
  document.getElementById('standSumpHolder').addEventListener('change', (event) => {
    document.getElementById('standSumpWidthRow').classList.toggle('hidden', !event.target.checked);
    updateCustomStandPriceEstimate();
  });
  ['standLength', 'standWidth', 'standLayers', 'standSumpWidth', 'standFooting'].forEach((id) => {
    document.getElementById(id).addEventListener('input', () => updateCustomStandPriceEstimate());
  });
  // Separate listener (not lumped into the array above) - typing into Height directly means the
  // customer wants their own value, so this stops selectStandTubular from silently overwriting it
  // if they go on to try a different Tubular size afterward. See standHeightIsFootprintDefault.
  document.getElementById('standHeight').addEventListener('input', () => {
    standHeightIsFootprintDefault = false;
    updateCustomStandPriceEstimate();
  });
  document.getElementById('standQty').addEventListener('input', () => renderCustomStandSummary());
  document.getElementById('standUnit').addEventListener('change', () => updateCustomStandPriceEstimate());
  ['standStainless', 'standCabinet'].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => updateCustomStandPriceEstimate());
  });
  document.getElementById('customStandAddToCartBtn').addEventListener('click', () => {
    addCustomizeTabToCart('stand', document.getElementById('customStandAddToCartMsg'));
  });
  document.getElementById('customStandNextBtn').addEventListener('click', async () => {
    customBuilderType = 'stand';
    const errorMsg = document.getElementById('customStandErrorMsg');
    if (!document.getElementById('standUnit').value) {
      errorMsg.textContent = 'Please select a unit of measure.';
      errorMsg.classList.remove('hidden');
      return;
    }
    await ensureGlassPricingLoaded();
    const result = window.CustomAquariumCalculator.calculateStandaloneStand(buildCustomStandPayload());
    if (!result.ok) {
      errorMsg.textContent = result.error;
      errorMsg.classList.remove('hidden');
      return;
    }
    errorMsg.classList.add('hidden');
    await renderCustomCheckout();
    goToStep('custom-checkout');
  });

  // ---- Standalone Filtration sub-flow navigation/wiring ----
  document.getElementById('standaloneSumpType').addEventListener('change', () => {
    applyStandaloneSumpTypeDefaults();
    updateStandaloneFiltrationPriceEstimate();
  });
  document.getElementById('standaloneFiltrationUnit').addEventListener('change', () => {
    applyStandaloneSumpTypeDefaults();
    updateStandaloneFiltrationPriceEstimate();
  });
  ['standaloneSumpLength', 'standaloneSumpWidth', 'standaloneSumpHeight'].forEach((id) => {
    document.getElementById(id).addEventListener('input', () => updateStandaloneFiltrationPriceEstimate());
  });
  document.getElementById('standaloneFiltrationGlass').addEventListener('change', () => updateStandaloneFiltrationPriceEstimate());
  // Quantity doesn't affect price (a per-unit estimate, same as the Aquarium/Stand tabs' own Qty
  // fields), but it IS shown on the live summary now - had no listener at all before, matching
  // the same "not wired" gap standaloneStickerQty below had until now.
  document.getElementById('standaloneFiltrationQty').addEventListener('input', () => renderStandaloneFiltrationSummary());
  ['standaloneSumpPiping', 'standaloneSumpOverflowBox', 'standaloneSumpFilterMedias', 'standaloneSumpAllumTopCover']
    .forEach((id) => document.getElementById(id).addEventListener('change', () => updateStandaloneFiltrationPriceEstimate()));
  document.getElementById('customStandaloneFiltrationAddToCartBtn').addEventListener('click', () => {
    addCustomizeTabToCart('filtration', document.getElementById('customStandaloneFiltrationAddToCartMsg'));
  });
  document.getElementById('customStandaloneFiltrationNextBtn').addEventListener('click', async () => {
    customBuilderType = 'filtration';
    const errorMsg = document.getElementById('customStandaloneFiltrationErrorMsg');
    if (!document.getElementById('standaloneFiltrationUnit').value) {
      errorMsg.textContent = 'Please select a unit of measure.';
      errorMsg.classList.remove('hidden');
      return;
    }
    await ensureGlassPricingLoaded();
    const result = window.CustomAquariumCalculator.calculateStandaloneFiltration(buildStandaloneFiltrationPayload());
    if (!result.ok) {
      errorMsg.textContent = result.error;
      errorMsg.classList.remove('hidden');
      return;
    }
    errorMsg.classList.add('hidden');
    await renderCustomCheckout();
    goToStep('custom-checkout');
  });

  // ---- Standalone Accessories/Stickers sub-flow navigation/wiring ----
  document.getElementById('standaloneStickerType').addEventListener('change', () => {
    setStandaloneStickerVisibilityState();
    updateStandaloneStickerPriceEstimate();
  });
  ['standaloneStickerLength', 'standaloneStickerWidth'].forEach((id) => {
    document.getElementById(id).addEventListener('input', () => updateStandaloneStickerPriceEstimate());
  });
  ['standaloneStickerUnit', 'standaloneStickerThickness', 'standaloneStickerRepair'].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => updateStandaloneStickerPriceEstimate());
  });
  // Same as standaloneFiltrationQty above - doesn't affect price, but is shown on the live
  // summary now and had no listener at all before.
  document.getElementById('standaloneStickerQty').addEventListener('input', () => renderStandaloneStickerSummary());
  document.getElementById('customStandaloneStickerAddToCartBtn').addEventListener('click', () => {
    addCustomizeTabToCart('stickers', document.getElementById('customStandaloneStickerAddToCartMsg'));
  });
  document.getElementById('customStandaloneStickerNextBtn').addEventListener('click', async () => {
    customBuilderType = 'stickers';
    const errorMsg = document.getElementById('customStandaloneStickerErrorMsg');
    if (!document.getElementById('standaloneStickerUnit').value) {
      errorMsg.textContent = 'Please select a unit of measure.';
      errorMsg.classList.remove('hidden');
      return;
    }
    await ensureGlassPricingLoaded();
    const result = window.CustomAquariumCalculator.calculateStandaloneSticker(buildStandaloneStickerPayload());
    if (!result.ok) {
      errorMsg.textContent = result.error;
      errorMsg.classList.remove('hidden');
      return;
    }
    errorMsg.classList.add('hidden');
    await renderCustomCheckout();
    goToStep('custom-checkout');
  });

  // Goes back to wherever checkout was actually reached from - branches by which Customize tab
  // (Aquarium/Stand/Filtration/Stickers) built the pending line (see customBuilderType). For
  // Aquarium: the embedded Filtration step when the customer opted into it (still its own real
  // page, not a tab), the Customize tab bar directly when they skipped it (mirrors
  // customDimsNextBtn's own branch).
  document.getElementById('customCheckoutBackBtn').addEventListener('click', () => {
    if (customBuilderType === 'stand') {
      switchCustomizeTab('stand');
      goToStep('customize-tabs');
    } else if (customBuilderType === 'filtration') {
      switchCustomizeTab('filtration');
      goToStep('customize-tabs');
    } else if (customBuilderType === 'stickers') {
      switchCustomizeTab('stickers');
      goToStep('customize-tabs');
    } else if (filtrationEnabled) {
      goToStep('custom-filtration');
    } else {
      switchCustomizeTab('aquarium');
      goToStep('customize-tabs');
    }
  });
  document.getElementById('customCheckoutBackBtnTop').addEventListener('click', () => document.getElementById('customCheckoutBackBtn').click());
  document.getElementById('customCheckoutConfirmBtn').addEventListener('click', async () => {
    await ensureGlassPricingLoaded();
    // Same combined set renderCustomCheckout just displayed (see collectCustomizeCheckoutLines) -
    // replaces every categoryCode actually being confirmed (not just customBuilderType's own) so
    // an Aquarium+Stand combined checkout, for example, pushes both cart lines together instead of
    // only whichever tab's Checkout button was clicked.
    const lines = collectCustomizeCheckoutLines(customBuilderType);
    const categoryCodes = new Set(lines.map((line) => line.categoryCode));
    cart = cart.filter((line) => !categoryCodes.has(line.categoryCode));
    lines.forEach((line) => cart.push(line.cartLine));
    saveCart();

    if (customBuilderType === 'stand' || customBuilderType === 'filtration' || customBuilderType === 'stickers') {
      detailsBackTarget = 'custom-checkout';
      goToStep(4);
    } else {
      // Unlike Stand/Filtration (which go straight to contact details), a just-confirmed
      // Aquarium build offers to add a matching Stand/Filtration on top of it first.
      goToStep('custom-add-more');
    }
  });

  // ---- "Add more products?" prompt (shown right after confirming a Custom Aquarium) ----
  document.getElementById('addMoreBackBtn').addEventListener('click', () => goToStep('custom-checkout'));
  document.getElementById('addMoreBackBtnTop').addEventListener('click', () => document.getElementById('addMoreBackBtn').click());
  document.getElementById('addMoreNoBtn').addEventListener('click', () => {
    detailsBackTarget = 'custom-checkout';
    goToStep(4);
  });
  document.getElementById('addMoreStandBtn').addEventListener('click', () => {
    customBuilderType = 'stand';
    prefillStandFromAquarium();
    switchCustomizeTab('stand');
    goToStep('customize-tabs');
  });
  document.getElementById('addMoreFiltrationBtn').addEventListener('click', () => {
    customBuilderType = 'filtration';
    resetStandaloneFiltrationBuilder();
    showFiltrationAquariumAwarenessNote();
    switchCustomizeTab('filtration');
    goToStep('customize-tabs');
  });

  document.getElementById('customLowIron').addEventListener('change', (event) => {
    if (event.target.checked) {
      glassBeforeLowIron = document.getElementById('customGlass').value;
    }
    enforceGlassThicknessRules().then(() => {
      // Only restore on an actual uncheck - not right after the checked branch above ran (that
      // would immediately undo the upgrade it just applied/confirmed).
      if (!event.target.checked && glassBeforeLowIron) {
        document.getElementById('customGlass').value = glassBeforeLowIron;
        glassBeforeLowIron = null;
      }
      updateCustomPriceEstimate();
    });
  });

  document.getElementById('customRimless').addEventListener('change', (event) => {
    if (event.target.checked) {
      glassBeforeRimless = document.getElementById('customGlass').value;
    }
    enforceGlassThicknessRules().then(() => {
      if (!event.target.checked && glassBeforeRimless) {
        document.getElementById('customGlass').value = glassBeforeRimless;
        glassBeforeRimless = null;
      }
      updateCustomPriceEstimate();
    });
  });

  ['customAio', 'customTempered', 'customHighStrip', 'customAquascape', 'customEnclosure']
    .forEach((id) => document.getElementById(id).addEventListener('change', () => {
      enforceGlassThicknessRules().then(updateCustomPriceEstimate);
    }));
  document.getElementById('viewCartBtn').addEventListener('click', () => { renderCart(); goToStep(3); });
  document.getElementById('cartAddMoreBtn').addEventListener('click', () => goToStep(currentCategoryLabel ? 2 : 1));
  document.getElementById('cartContinueBtn').addEventListener('click', () => {
    detailsBackTarget = 3;
    goToStep(4);
  });
  // Payment & Release policy is no longer its own step (merged into Step 3 / Order Summary, see
  // paymentPolicyTemplate) - Back from Details returns straight to whichever summary screen led
  // here, same targets detailsBackTarget already tracked for the old payment-policy step.
  document.getElementById('detailsBackBtn').addEventListener('click', () => {
    if (detailsBackTarget === 3) renderCart();
    goToStep(detailsBackTarget);
  });
  document.getElementById('detailsForm').addEventListener('submit', submitOrder);
  document.getElementById('startNewOrderBtn').addEventListener('click', resetWizard);
  document.getElementById('exitOrderNowBtn').addEventListener('click', exitOrderNow);
  document.getElementById('viewCartLink').addEventListener('click', (event) => {
    event.preventDefault();
    openCartViewModal();
  });
  document.getElementById('cartViewCloseBtn').addEventListener('click', closeCartViewModal);
  document.getElementById('cartViewProceedBtn').addEventListener('click', () => {
    if (cart.length === 0) return;
    closeCartViewModal();
    // Cart can hold a mix of Standard + Customize items depending on how the customer got here,
    // so there's no single natural "back" screen - Step 3's cart review already handles that same
    // mixed case, so Back from Details lands there too, same as cartContinueBtn's own target.
    detailsBackTarget = 3;
    goToStep(4);
  });

  document.getElementById('itemDetailCloseBtn').addEventListener('click', closeItemDetail);
  document.getElementById('itemDetailQtyStepper').querySelector('[data-action="dec"]').addEventListener('click', () => {
    const input = document.getElementById('itemDetailQtyInput');
    input.value = Math.max(1, Number(input.value) - 1);
  });
  document.getElementById('itemDetailQtyStepper').querySelector('[data-action="inc"]').addEventListener('click', () => {
    const input = document.getElementById('itemDetailQtyInput');
    input.value = Number(input.value) + 1;
  });
  document.getElementById('itemDetailAddBtn').addEventListener('click', () => {
    if (!currentDetailItem) return;
    const qty = Math.max(1, Number(document.getElementById('itemDetailQtyInput').value) || 1);
    addToCart({
      categoryCode: currentDetailItem._sourceCategoryCode || currentCategoryCodes[0],
      itemCode: currentDetailItem.code,
      itemName: currentDetailItem.name,
      price: Number(currentDetailItem.price),
      quantity: qty
    });
    closeItemDetail();
  });
})();
