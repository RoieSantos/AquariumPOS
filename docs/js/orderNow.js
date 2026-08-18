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
let currentCategoryCode = null;
let currentCategoryLabel = null;
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
// Which Customize sub-flow (customize-choice: Aquarium/Stand/Filtration) built the line currently
// staged for the shared "custom-checkout" (Order Summary) screen - lets that one screen serve all
// three instead of needing a separate checkout page per sub-flow.
let customBuilderType = 'aquarium';
// The Stand/Filtration sub-flows are reachable both directly from the customize-choice picker and
// from the post-Aquarium-checkout "add more products?" prompt - these track which one so each
// step's own Back button returns to the right place instead of always assuming direct entry.
let standBackTarget = 'customize-choice';
let filtrationStandaloneBackTarget = 'customize-choice';
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
// is on, unlike Step 3's cart review which is only reached by walking the Standard flow. Unlike
// that read-mostly review (Remove only), this also lets quantity be adjusted in place.
function renderCartViewModal() {
  const emptyMsg = document.getElementById('cartViewEmptyMsg');
  const linesBox = document.getElementById('cartViewLinesBox');
  const totalRow = document.getElementById('cartViewTotalRow');

  if (cart.length === 0) {
    emptyMsg.classList.remove('hidden');
    linesBox.innerHTML = '';
    totalRow.classList.add('hidden');
    return;
  }

  emptyMsg.classList.add('hidden');
  totalRow.classList.remove('hidden');

  linesBox.innerHTML = cart
    .map((line, idx) => `
      <div class="cart-line-row">
        <div>
          <div class="cart-line-name">${line.itemName}</div>
          <div class="cart-line-meta">${formatMoney(line.price)} each - ${formatMoney(line.quantity * line.price)}</div>
        </div>
        <div class="cart-line-qty-controls">
          <button type="button" class="cart-qty-btn" data-idx="${idx}" data-delta="-1">&minus;</button>
          <span class="cart-qty-value">${line.quantity}</span>
          <button type="button" class="cart-qty-btn" data-idx="${idx}" data-delta="1">+</button>
        </div>
        <button type="button" class="cart-line-remove" data-idx="${idx}">Remove</button>
      </div>
    `)
    .join('');

  linesBox.querySelectorAll('.cart-qty-btn').forEach((btn) => {
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

  linesBox.querySelectorAll('.cart-line-remove').forEach((btn) => {
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

function openCartViewModal() {
  renderCartViewModal();
  document.getElementById('cartViewModal').classList.remove('hidden');
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

function goToStep(step) {
  currentStep = step;
  document.querySelectorAll('.wizard-step').forEach((el) => {
    el.classList.toggle('active', el.dataset.step === String(step));
  });
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

  // Standard flow only offers pre-built Sets right now - per direct request, every other
  // category (Aquarium/Stand/Filtration/Sump/Fish sold separately) is hidden here even though
  // public_list_order_categories() still returns all of them, so the Customize flow (which has
  // its own separate step-by-step Aquarium/Filtration builder, unaffected by this) keeps working.
  const setCategories = data.filter((cat) => String(cat.code).toUpperCase() === 'SET');

  if (!setCategories || setCategories.length === 0) {
    errorMsg.textContent = 'No categories are available to order right now. Please check back later.';
    errorMsg.classList.remove('hidden');
    return;
  }

  grid.innerHTML = setCategories
    .map((cat) => `
      <div class="category-card" data-code="${cat.code}" data-label="${cat.description}">
        <span class="category-icon">${CATEGORY_ICONS[String(cat.code).toUpperCase()] || DEFAULT_CATEGORY_ICON}</span>
        ${cat.description}
      </div>
    `)
    .join('');

  grid.querySelectorAll('.category-card').forEach((card) => {
    card.addEventListener('click', () => openCategory(card.dataset.code, card.dataset.label));
  });
}

// ---- Step 2: items within a category ----

async function openCategory(code, label) {
  currentCategoryCode = code;
  currentCategoryLabel = label;
  document.getElementById('itemStepTitle').textContent = label;
  goToStep(2);
  await loadItems(code);
}

async function loadItems(code) {
  const loadingMsg = document.getElementById('itemLoadingMsg');
  const errorMsg = document.getElementById('itemErrorMsg');
  const emptyMsg = document.getElementById('itemEmptyMsg');
  const grid = document.getElementById('itemGrid');

  loadingMsg.classList.remove('hidden');
  errorMsg.classList.add('hidden');
  emptyMsg.classList.add('hidden');
  grid.innerHTML = '';

  const { data, error } = await supabaseClient.rpc('public_list_order_items', { p_category_code: code });
  loadingMsg.classList.add('hidden');

  if (error) {
    errorMsg.textContent = 'Could not load items: ' + error.message;
    errorMsg.classList.remove('hidden');
    return;
  }

  if (!data || data.length === 0) {
    emptyMsg.classList.remove('hidden');
    return;
  }

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

      return `
        <div class="item-card" data-code="${item.code}" data-name="${item.name}" data-price="${item.price}">
          ${imgHtml}
          <div class="item-card-name">${item.name}</div>
          <div class="item-card-price">${formatMoney(item.price)}</div>
          ${stockHtml}
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
      addToCart({
        categoryCode: currentCategoryCode,
        itemCode: card.dataset.code,
        itemName: card.dataset.name,
        price: Number(card.dataset.price),
        quantity: Math.max(1, Number(qtyInput.value) || 1)
      });
      qtyInput.value = 1;
      flashAdded(card);
    });
  });
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

// Shows the Dimensions step's values (Dimension/Unit/Glass Thickness/Sealant Color) at the top
// of the Options step, so the customer isn't picking add-ons blind to what they already specified.
function renderCustomDimsSummary() {
  const length = document.getElementById('customLength').value || '?';
  const width = document.getElementById('customWidth').value || '?';
  const height = document.getElementById('customHeight').value || '?';
  const unit = document.getElementById('customUnit').value;
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

  document.getElementById('customDimsSummary').innerHTML = `
    <div><strong>Dimension:</strong> ${length} x ${width} x ${height}</div>
    <div><strong>Unit of Measure:</strong> ${unit}</div>
    <div><strong>Glass Thickness:</strong> ${glass}</div>
    <div><strong>Sealant Color:</strong> ${sealant}</div>
    <div><strong>Edge:</strong> ${rimless}</div>
    ${optionsHtml ? `<div class="dims-summary-options-grid">${optionsHtml}</div>` : ''}
  `;
}

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

// Glass price-per-sqft rows (same source WebAquariumCalculator/index.html uses) - loaded once
// and reused for every price recalculation. custom-aquarium-calculator.js already has built-in
// fallback prices if this fetch fails, so a missing/broken file degrades gracefully rather than
// blocking the estimate entirely.
let glassPricingSetupRows = [];
let glassPricingLoadPromise = null;

function ensureGlassPricingLoaded() {
  if (glassPricingLoadPromise) return glassPricingLoadPromise;
  glassPricingLoadPromise = fetch('WebAquariumCalculator/glass-pricing.json', { cache: 'no-store' })
    .then((response) => (response.ok ? response.json() : []))
    .then((rows) => { glassPricingSetupRows = Array.isArray(rows) ? rows : []; })
    .catch(() => { glassPricingSetupRows = []; });
  return glassPricingLoadPromise;
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
      // lightPrice/pumpPrice deliberately omitted - picking a specific light/pump model+price is
      // an inventory lookup only staff tooling does (WebAquariumCalculator/index.html), so
      // Submersible Light/Pump here are captured as plain interest checkboxes (see
      // buildCustomAquariumSpecText) and priced later by staff instead of guessed at here.
    },
    stand: { enabled: false },
    stickerBackground: { enabled: false },
    stickerBottom: { enabled: false },
    glassPricingSetupRows: glassPricingSetupRows,
    glassPricingUom: 'MM'
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
  registerCustomCanvas('customAquariumCanvas');
  drawCustomPlaceholder('Enter your aquarium details to see a preview.');
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

  ctx.fillStyle = '#213b64';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, centerX, centerY + 0.5);
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
  const marginBottom = 52;
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
}

// Shown on the Dimensions, Options, and (when reached) Filtration steps, same as the canvas
// preview - so the customer sees a running price as soon as they enter dimensions, and it keeps
// including whatever sump specs they've entered once Filtration is reached.
async function updateCustomPriceEstimate() {
  const dimsBox = document.getElementById('customPriceEstimateDims');
  const optionsBox = document.getElementById('customPriceEstimate');
  const filtrationBox = document.getElementById('customPriceEstimateFiltration');
  const boxes = [dimsBox, optionsBox, filtrationBox].filter(Boolean);

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

  // Light/Pump aren't priced here (see buildCustomPayload) since picking a specific model+price
  // is a staff-only inventory lookup - flag that they're still to be confirmed whenever the
  // customer expressed interest in either.
  const wantsLightOrPump = filtrationEnabled && (
    document.getElementById('sumpSubmersibleLight').checked || document.getElementById('sumpSubmersiblePump').checked
  );
  const sumpNote = wantsLightOrPump
    ? '<div class="custom-price-note">+ Submersible Light/Pump pricing still needed - we\'ll confirm final pricing with you.</div>'
    : '';
  // All three steps show the computed gallon volume right under the price, so the customer has a
  // sense of tank size at every point in the custom-aquarium flow.
  const priceHtml = `Estimated Price: ${formatMoney(result.totalPrice)}${sumpNote}<div class="custom-price-gallons-badge">${result.gallons} gallons</div>`;
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

  const opts = [];
  if (document.getElementById('customAio').checked) opts.push('AIO');
  if (document.getElementById('customLowIron').checked) opts.push('Low Iron');
  if (document.getElementById('customTempered').checked) opts.push('Tempered Glass');
  if (document.getElementById('customHighStrip').checked) opts.push('High Strip');
  if (document.getElementById('customAquascape').checked) opts.push('Aquascape Service');
  if (document.getElementById('customEnclosure').checked) opts.push('Enclosure');
  if (filtrationEnabled) opts.push(`Filtration (${buildFiltrationSpecText()})`);

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
  if (document.getElementById('sumpSubmersibleLight').checked) extras.push('Submersible Light - price TBC');
  if (document.getElementById('sumpSubmersiblePump').checked) extras.push('Submersible Pump - price TBC');

  const extrasText = extras.length ? `, ${extras.join(', ')}` : '';
  return `${sumpType} ${sumpLength} x ${sumpWidth} x ${sumpHeight} ${unit}${extrasText}`;
}

// price stays the PER-UNIT price (result.totalPrice - what one build of this spec costs); qty is
// multiplied in by the cart/checkout rendering, same as every Standard-flow line already does.
function customAquariumQty() {
  return Math.max(1, Math.round(Number(document.getElementById('customQty').value) || 1));
}

// Builds the single cart line representing the whole custom aquarium build, so it flows through
// the existing Standard-flow cart/details/submit pipeline (submitOrder() already just reads
// whatever's in `cart`) instead of needing a separate submission path.
function buildCustomAquariumCartLine(result) {
  return {
    categoryCode: 'CUSTOM-AQUARIUM',
    itemCode: null,
    itemName: `Custom Aquarium - ${buildCustomAquariumSpecText()}`,
    price: result && result.ok ? result.totalPrice : 0,
    quantity: customAquariumQty()
  };
}

// ---- Customize > Stand sub-flow (standalone, no aquarium involved) ----

// Tracks which Tubular size is selected on the Stand step, same pattern as
// deliveryEstimateMethod/selectDeliveryEstimateMethod - the toggle buttons just reflect this.
let selectedStandTubular = '1x1';

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
    footingInches: document.getElementById('standFooting').value
  };
}

function selectStandTubular(value) {
  selectedStandTubular = value;
  document.getElementById('standTubular1x1').classList.toggle('selected', value === '1x1');
  document.getElementById('standTubular1_5x1_5').classList.toggle('selected', value === '1.5x1.5');
  document.getElementById('standTubular2x2').classList.toggle('selected', value === '2x2');
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

// Live summary of every Stand field, same "declutter - only list options actually turned on"
// pattern as renderCustomDimsSummary() on the Aquarium flow's Options step. Unlike that one
// (rendered once, on arrival at a separate Options step), this re-renders on every field change
// since the Stand flow is a single step - there's no natural "moving on" moment to render it at.
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

  document.getElementById('customStandSummary').innerHTML = `
    <div><strong>Dimension:</strong> ${length} x ${width} x ${height}</div>
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
function updateCustomStandPriceEstimate() {
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

  const note = document.getElementById('standAquariumAwarenessNote');
  note.textContent = `Using this aquarium's footprint: ${length} x ${width} ${unit}. You can adjust Length/Width if you'd like a different fit.`;
  note.classList.remove('hidden');

  updateCustomStandPriceEstimate();
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
    glassPricingUom: 'MM'
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

async function updateStandaloneFiltrationPriceEstimate() {
  const box = document.getElementById('customPriceEstimateStandaloneFiltration');

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

  const wantsLightOrPump = document.getElementById('standaloneSumpSubmersibleLight').checked
    || document.getElementById('standaloneSumpSubmersiblePump').checked;
  const note = wantsLightOrPump
    ? '<div class="custom-price-note">+ Submersible Light/Pump pricing still needed - we\'ll confirm final pricing with you.</div>'
    : '';
  box.innerHTML = `Estimated Price: ${formatMoney(result.totalPrice)}${note}`;
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
  if (document.getElementById('standaloneSumpSubmersibleLight').checked) extras.push('Submersible Light - price TBC');
  if (document.getElementById('standaloneSumpSubmersiblePump').checked) extras.push('Submersible Pump - price TBC');
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
  ['standaloneSumpPiping', 'standaloneSumpOverflowBox', 'standaloneSumpFilterMedias', 'standaloneSumpAllumTopCover', 'standaloneSumpSubmersibleLight', 'standaloneSumpSubmersiblePump']
    .forEach((id) => { document.getElementById(id).checked = false; });

  const errorMsg = document.getElementById('customStandaloneFiltrationErrorMsg');
  errorMsg.textContent = '';
  errorMsg.classList.add('hidden');
  document.getElementById('customPriceEstimateStandaloneFiltration').textContent = 'Enter your sump details to see a price estimate.';

  const awarenessNote = document.getElementById('filtrationAquariumAwarenessNote');
  awarenessNote.textContent = '';
  awarenessNote.classList.add('hidden');
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

// Populates the receipt-styled checkout/review page (step "custom-checkout") with the company
// letterhead (same fields the Delivery Receipt page shows, via companyBranding.js) and a single
// product row summarizing whichever Customize sub-flow (Aquarium/Stand/Filtration, tracked by
// customBuilderType) the customer just built. Returns the current calculator result so the
// Confirm handler can build the cart line from the same numbers being displayed.
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

  let result;
  let productLabel;
  let qty;
  let titleText;

  if (customBuilderType === 'stand') {
    // No glass-pricing lookup involved in Stand pricing (tubular rate table only), unlike the
    // other two branches below.
    result = window.CustomAquariumCalculator.calculateStandaloneStand(buildCustomStandPayload());
    productLabel = `Custom Stand - ${buildCustomStandSpecText()}`;
    qty = customStandQty();
    titleText = 'CUSTOM STAND ORDER SUMMARY';
  } else if (customBuilderType === 'filtration') {
    await ensureGlassPricingLoaded();
    result = window.CustomAquariumCalculator.calculateStandaloneFiltration(buildStandaloneFiltrationPayload());
    productLabel = `Custom Filtration - ${buildStandaloneFiltrationSpecText()}`;
    qty = standaloneFiltrationQty();
    titleText = 'CUSTOM FILTRATION ORDER SUMMARY';
  } else {
    await ensureGlassPricingLoaded();
    result = window.CustomAquariumCalculator.calculateCustomAquarium(buildCustomPayload());
    productLabel = `Custom Aquarium - ${buildCustomAquariumSpecText()}`;
    qty = customAquariumQty();
    titleText = 'CUSTOM AQUARIUM ORDER SUMMARY';
  }

  document.getElementById('checkoutTitle').textContent = titleText;

  const lineTotal = result.ok ? result.totalPrice * qty : 0;
  const amountText = result.ok ? formatMoney(lineTotal) : '-';
  document.getElementById('checkoutLinesBody').innerHTML = `
    <tr>
      <td>${productLabel}</td>
      <td>${qty}</td>
      <td style="text-align:right;">${amountText}</td>
    </tr>
  `;
  document.getElementById('checkoutTotal').textContent = result.ok ? formatMoney(lineTotal) : (result.error || 'Please review your details.');

  return result;
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

  renderCustomDimsSummary();
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
  const result = (data && data[0]) || {};
  document.getElementById('confirmationOrderNo').textContent = result.order_no;

  const onlineOrderNoBox = document.getElementById('confirmationOnlineOrderNo');
  const onlineOrderNoLabel = document.getElementById('confirmationOnlineOrderNoLabel');
  if (result.pancake_sync_status === 'Synced' && result.pancake_order_id) {
    onlineOrderNoBox.textContent = '#' + result.pancake_order_id;
    onlineOrderNoBox.classList.remove('hidden');
    onlineOrderNoLabel.classList.remove('hidden');
  } else {
    onlineOrderNoBox.classList.add('hidden');
    onlineOrderNoLabel.classList.add('hidden');
  }
  cart = [];
  saveCart();
  goToStep(5);
}

// Puts the whole Customize flow back to its just-loaded defaults - per direct request, opening
// the Dimensions step should always feel like starting fresh, not resuming whatever was left over
// from a previous visit (e.g. after confirming one custom aquarium and starting a second, or
// backing out to the mode picker and re-entering Customize).
function resetCustomAquariumBuilder() {
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
  ['sumpPiping', 'sumpOverflowBox', 'sumpFilterMedias', 'sumpAllumTopCover', 'sumpSubmersibleLight', 'sumpSubmersiblePump']
    .forEach((id) => { document.getElementById(id).checked = false; });

  filtrationEnabled = false;
  glassBeforeLowIron = null;
  glassBeforeRimless = null;

  ['customDimsErrorMsg', 'customDimsGlassNotice', 'customGlassNotice'].forEach((id) => {
    const el = document.getElementById(id);
    el.textContent = '';
    el.classList.add('hidden');
  });
  document.getElementById('customDimsSummary').innerHTML = '';

  drawCustomPlaceholder('Enter your aquarium details to see a preview.');
  ['customPriceEstimateDims', 'customPriceEstimate', 'customPriceEstimateFiltration'].forEach((id) => {
    const box = document.getElementById(id);
    if (box) box.textContent = 'Enter your aquarium details to see a price estimate.';
  });
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
function showCustomizeLoading(durationMs = 1300) {
  const overlay = document.getElementById('customizeLoadingOverlay');
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
    `Lalamove ${quote.isSandbox ? 'test/SANDBOX price (not real pricing yet)' : 'quote'} - ${quote.serviceType}, from ${from.label} to your address.`;
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
  loadCategories();
  renderCart();
  updateViewCartLink();
  wireLocationToggle();
  wireFulfillmentToggle();
  setupCustomCanvas();
  setupStandCanvas();
  // Clones the Payment & Release policy (see paymentPolicyTemplate) into both order-summary
  // screens - Step 3 (Standard flow cart review) and custom-checkout (Customize flow) - so it's
  // no longer a separate wizard step the customer has to click through.
  const policyTemplate = document.getElementById('paymentPolicyTemplate');
  document.getElementById('cartPaymentPolicyBox').appendChild(policyTemplate.content.cloneNode(true));
  document.getElementById('checkoutPaymentPolicyBox').appendChild(policyTemplate.content.cloneNode(true));
  goToStep(0);

  document.getElementById('modeStandardBtn').addEventListener('click', () => goToStep(1));
  document.getElementById('modeCustomizeBtn').addEventListener('click', async () => {
    await showCustomizeLoading();
    goToStep('customize-choice');
  });
  document.getElementById('customizeChoiceBackBtn').addEventListener('click', () => goToStep(0));
  document.getElementById('customizeChoiceAquariumBtn').addEventListener('click', () => {
    customBuilderType = 'aquarium';
    resetCustomAquariumBuilder();
    goToStep('custom-dims');
  });
  document.getElementById('customizeChoiceStandBtn').addEventListener('click', () => {
    customBuilderType = 'stand';
    standBackTarget = 'customize-choice';
    resetCustomStandBuilder();
    goToStep('custom-stand');
  });
  document.getElementById('customizeChoiceFiltrationBtn').addEventListener('click', () => {
    customBuilderType = 'filtration';
    filtrationStandaloneBackTarget = 'customize-choice';
    resetStandaloneFiltrationBuilder();
    goToStep('custom-filtration-standalone');
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
  ['customUnit', 'customGlass'].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => {
      applyCustomDimsGlassSafety();
      updateCustomPriceEstimate();
    });
  });

  document.getElementById('customDimsBackBtn').addEventListener('click', () => goToStep('customize-choice'));
  document.getElementById('customDimsNextBtn').addEventListener('click', async () => {
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
    // runs right here on raw Length/Width/Height/Glass Thickness, before AIO/Low Iron/Rimless
    // even exist (those are chosen on the next step, where enforceGlassThicknessRules applies
    // their own option-specific rules instead). isTempered is passed as true so the chart's
    // general "tempered is mandatory at 36in+" branch doesn't false-block here - that part is
    // already auto-enforced on the Options step regardless of what's picked on this one.
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

    renderCustomDimsSummary();
    enforceGlassThicknessRules().then(updateCustomPriceEstimate);
    goToStep('custom-options');
  });
  document.getElementById('customOptionsBackBtn').addEventListener('click', () => goToStep('custom-dims'));
  document.getElementById('customOptionsNextBtn').addEventListener('click', async () => {
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

  document.getElementById('customFiltrationBackBtn').addEventListener('click', () => goToStep('custom-options'));
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
  ['sumpPiping', 'sumpOverflowBox', 'sumpFilterMedias', 'sumpAllumTopCover', 'sumpSubmersibleLight', 'sumpSubmersiblePump']
    .forEach((id) => document.getElementById(id).addEventListener('change', () => updateCustomPriceEstimate()));

  // ---- Stand sub-flow navigation/wiring ----
  document.getElementById('standTubular1x1').addEventListener('click', () => { selectStandTubular('1x1'); updateCustomStandPriceEstimate(); });
  document.getElementById('standTubular1_5x1_5').addEventListener('click', () => { selectStandTubular('1.5x1.5'); updateCustomStandPriceEstimate(); });
  document.getElementById('standTubular2x2').addEventListener('click', () => { selectStandTubular('2x2'); updateCustomStandPriceEstimate(); });
  document.getElementById('standSumpHolder').addEventListener('change', (event) => {
    document.getElementById('standSumpWidthRow').classList.toggle('hidden', !event.target.checked);
    updateCustomStandPriceEstimate();
  });
  ['standLength', 'standWidth', 'standHeight', 'standLayers', 'standSumpWidth', 'standFooting'].forEach((id) => {
    document.getElementById(id).addEventListener('input', () => updateCustomStandPriceEstimate());
  });
  document.getElementById('standQty').addEventListener('input', () => renderCustomStandSummary());
  document.getElementById('standUnit').addEventListener('change', () => updateCustomStandPriceEstimate());
  ['standStainless', 'standCabinet'].forEach((id) => {
    document.getElementById(id).addEventListener('change', () => updateCustomStandPriceEstimate());
  });
  document.getElementById('customStandBackBtn').addEventListener('click', () => goToStep(standBackTarget));
  document.getElementById('customStandNextBtn').addEventListener('click', async () => {
    const errorMsg = document.getElementById('customStandErrorMsg');
    if (!document.getElementById('standUnit').value) {
      errorMsg.textContent = 'Please select a unit of measure.';
      errorMsg.classList.remove('hidden');
      return;
    }
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
  ['standaloneSumpPiping', 'standaloneSumpOverflowBox', 'standaloneSumpFilterMedias', 'standaloneSumpAllumTopCover', 'standaloneSumpSubmersibleLight', 'standaloneSumpSubmersiblePump']
    .forEach((id) => document.getElementById(id).addEventListener('change', () => updateStandaloneFiltrationPriceEstimate()));
  document.getElementById('customStandaloneFiltrationBackBtn').addEventListener('click', () => goToStep(filtrationStandaloneBackTarget));
  document.getElementById('customStandaloneFiltrationNextBtn').addEventListener('click', async () => {
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

  // Goes back to wherever checkout was actually reached from - branches by which Customize
  // sub-flow (Aquarium/Stand/Filtration) built the pending line (see customBuilderType). For
  // Aquarium: Filtration when the customer opted into it, Options directly when they skipped it
  // (mirrors customOptionsNextBtn's own branch).
  document.getElementById('customCheckoutBackBtn').addEventListener('click', () => {
    if (customBuilderType === 'stand') {
      goToStep('custom-stand');
    } else if (customBuilderType === 'filtration') {
      goToStep('custom-filtration-standalone');
    } else {
      goToStep(filtrationEnabled ? 'custom-filtration' : 'custom-options');
    }
  });
  document.getElementById('customCheckoutConfirmBtn').addEventListener('click', () => {
    if (customBuilderType === 'stand') {
      const result = window.CustomAquariumCalculator.calculateStandaloneStand(buildCustomStandPayload());
      cart = cart.filter((line) => line.categoryCode !== 'CUSTOM-STAND');
      cart.push(buildCustomStandCartLine(result));
      saveCart();
      detailsBackTarget = 'custom-checkout';
      goToStep(4);
    } else if (customBuilderType === 'filtration') {
      const result = window.CustomAquariumCalculator.calculateStandaloneFiltration(buildStandaloneFiltrationPayload());
      cart = cart.filter((line) => line.categoryCode !== 'CUSTOM-FILTRATION');
      cart.push(buildStandaloneFiltrationCartLine(result));
      saveCart();
      detailsBackTarget = 'custom-checkout';
      goToStep(4);
    } else {
      const result = window.CustomAquariumCalculator.calculateCustomAquarium(buildCustomPayload());
      cart = cart.filter((line) => line.categoryCode !== 'CUSTOM-AQUARIUM');
      cart.push(buildCustomAquariumCartLine(result));
      saveCart();
      // Unlike Stand/Filtration (which go straight to contact details), a just-confirmed
      // Aquarium build offers to add a matching Stand/Filtration on top of it first.
      goToStep('custom-add-more');
    }
  });

  // ---- "Add more products?" prompt (shown right after confirming a Custom Aquarium) ----
  document.getElementById('addMoreBackBtn').addEventListener('click', () => goToStep('custom-checkout'));
  document.getElementById('addMoreNoBtn').addEventListener('click', () => {
    detailsBackTarget = 'custom-checkout';
    goToStep(4);
  });
  document.getElementById('addMoreStandBtn').addEventListener('click', () => {
    customBuilderType = 'stand';
    standBackTarget = 'custom-add-more';
    prefillStandFromAquarium();
    goToStep('custom-stand');
  });
  document.getElementById('addMoreFiltrationBtn').addEventListener('click', () => {
    customBuilderType = 'filtration';
    filtrationStandaloneBackTarget = 'custom-add-more';
    resetStandaloneFiltrationBuilder();
    showFiltrationAquariumAwarenessNote();
    goToStep('custom-filtration-standalone');
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
        renderCustomDimsSummary();
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
        renderCustomDimsSummary();
      }
      updateCustomPriceEstimate();
    });
  });

  ['customAio', 'customTempered', 'customHighStrip', 'customAquascape', 'customEnclosure']
    .forEach((id) => document.getElementById(id).addEventListener('change', () => {
      enforceGlassThicknessRules().then(updateCustomPriceEstimate);
    }));
  document.getElementById('viewCartBtn').addEventListener('click', () => { renderCart(); goToStep(3); });
  document.getElementById('cartAddMoreBtn').addEventListener('click', () => goToStep(currentCategoryCode ? 2 : 1));
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
})();
