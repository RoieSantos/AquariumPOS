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
  FISH: '🐟'
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
// Step 4 (customer details) is shared by the Standard and Customize flows, so its Back button
// needs to know which step led there - set right before navigating into step 4.
let detailsBackTarget = 3;
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
  renderPsidDebugBanner();
}

// TEMPORARY - for testing the Messenger PSID hand-off only. Remove once confirmed working.
function renderPsidDebugBanner() {
  const banner = document.getElementById('psidDebugBanner');
  if (!banner) return;
  banner.textContent = messengerPsid
    ? `PSID captured: ${messengerPsid}`
    : 'PSID captured: none (opened without a ?psid= link)';
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

// Step 0 (Standard/Customize picker) and every "custom-*" step (the Customize path's own
// sub-steps) sit outside the linear 1-4 order flow the progress dots represent, so the whole bar
// hides on those.
function updateProgress() {
  const progressBar = document.getElementById('wizardProgress');
  if (currentStep === 0 || String(currentStep).indexOf('custom') === 0) {
    progressBar.classList.add('hidden');
    return;
  }
  progressBar.classList.remove('hidden');

  const displayStep = currentStep === 'payment-policy' ? 4 : Math.min(Number(currentStep), 4);
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

  if (!data || data.length === 0) {
    errorMsg.textContent = 'No categories are available to order right now. Please check back later.';
    errorMsg.classList.remove('hidden');
    return;
  }

  grid.innerHTML = data
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

  const yesNo = (checked) => (checked ? 'Yes' : 'No');
  const aio = document.getElementById('customAio').checked;
  const lowIron = document.getElementById('customLowIron').checked;
  const tempered = document.getElementById('customTempered').checked;
  const highStrip = document.getElementById('customHighStrip').checked;
  const aquascape = document.getElementById('customAquascape').checked;
  const enclosure = document.getElementById('customEnclosure').checked;

  document.getElementById('customDimsSummary').innerHTML = `
    <div><strong>Dimension:</strong> ${length} x ${width} x ${height}</div>
    <div><strong>Unit of Measure:</strong> ${unit}</div>
    <div><strong>Glass Thickness:</strong> ${glass}</div>
    <div><strong>Sealant Color:</strong> ${sealant}</div>
    <div><strong>Edge:</strong> ${rimless}</div>
    <div class="dims-summary-options-grid">
      <div><strong>AIO:</strong> ${yesNo(aio)}</div>
      <div><strong>Low Iron:</strong> ${yesNo(lowIron)}</div>
      <div><strong>Tempered Glass:</strong> ${yesNo(tempered)}</div>
      <div><strong>High Strip:</strong> ${yesNo(highStrip)}</div>
      <div><strong>Aquascape Service:</strong> ${yesNo(aquascape)}</div>
      <div><strong>Enclosure:</strong> ${yesNo(enclosure)}</div>
      <div><strong>Filtration:</strong> ${yesNo(filtrationEnabled)}</div>
    </div>
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
// across the Dimensions (step 2) and Options (step 3) steps so far. Sump/stand/sticker sizing
// isn't collected yet (no step for it), so filtrationSump is passed with 0 dimensions - the
// calculator only adds a sump cost once length/width/height are all > 0, so this correctly
// contributes $0 rather than guessing a size the customer never specified.
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
      type: 'Undersump',
      length: 0,
      width: 0,
      height: 0,
      unit: unit
    },
    stand: { enabled: false },
    stickerBackground: { enabled: false },
    stickerBottom: { enabled: false },
    glassPricingSetupRows: glassPricingSetupRows,
    glassPricingUom: 'MM'
  };
}

// Aquarium sketch on the Options step - a trimmed-down port of the isometric canvas drawing in
// WebAquariumCalculator/index.html's drawAquarium(), adapted to this step's own field IDs and
// leaving out stand/sticker rendering (the wizard doesn't collect those yet). Kept as a separate
// copy rather than a shared module so this page never risks the staff-only calculator page, and
// vice versa.
let customCanvasCtx = null;
let CUSTOM_CANVAS_W = 0;
let CUSTOM_CANVAS_H = 0;

function round1(value) {
  return Math.round((Number(value) || 0) * 10) / 10;
}

function setupCustomCanvas() {
  const canvas = document.getElementById('customAquariumCanvas');
  if (!canvas) return;
  customCanvasCtx = canvas.getContext('2d');
  CUSTOM_CANVAS_W = canvas.width;
  CUSTOM_CANVAS_H = canvas.height;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = CUSTOM_CANVAS_W * dpr;
  canvas.height = CUSTOM_CANVAS_H * dpr;
  customCanvasCtx.scale(dpr, dpr);
  drawCustomPlaceholder('Enter your aquarium details to see a preview.');
}

function drawCustomPlaceholder(message) {
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
  ctx.font = '11px Segoe UI';
  const textWidth = ctx.measureText(text).width;
  const paddingX = 7;
  const chipWidth = textWidth + paddingX * 2;
  const chipHeight = 17;
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

// result: the return value of calculateCustomAquarium() - drawn straight from its normalized
// dimensions/sump so the sketch always matches whatever price was just computed.
function drawCustomAquarium(result) {
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
    drawCustomPlaceholder(result && result.error ? result.error : 'Enter your aquarium details to see a preview.');
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

async function updateCustomPriceEstimate() {
  const box = document.getElementById('customPriceEstimate');
  await ensureGlassPricingLoaded();

  const result = window.CustomAquariumCalculator.calculateCustomAquarium(buildCustomPayload());
  drawCustomAquarium(result);
  if (!result.ok) {
    box.textContent = result.error || 'Enter valid dimensions to see a price estimate.';
    return;
  }

  const sumpNote = filtrationEnabled
    ? '<div class="custom-price-note">+ Filtration Sump sizing still needed - we\'ll confirm final pricing with you.</div>'
    : '';
  box.innerHTML = `Estimated Price: ${formatMoney(result.totalPrice)}${sumpNote}`;
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
  if (filtrationEnabled) opts.push('Filtration');

  const optsText = opts.length ? `, ${opts.join(', ')}` : '';
  return `${length} x ${width} x ${height} ${unit}, ${glass} glass, ${sealant} sealant, ${edge}${optsText}`;
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
    quantity: 1
  };
}

// Populates the receipt-styled checkout/review page (step "custom-checkout") with the company
// letterhead (same fields the Delivery Receipt page shows, via companyBranding.js) and a single
// product row summarizing the aquarium build. Returns the current calculateCustomAquarium()
// result so the Continue handler can build the cart line from the same numbers being displayed.
async function renderCustomCheckout() {
  await ensureGlassPricingLoaded();
  const result = window.CustomAquariumCalculator.calculateCustomAquarium(buildCustomPayload());

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

  const amountText = result.ok ? formatMoney(result.totalPrice) : '-';
  document.getElementById('checkoutLinesBody').innerHTML = `
    <tr>
      <td>Custom Aquarium - ${buildCustomAquariumSpecText()}</td>
      <td>1</td>
      <td style="text-align:right;">${amountText}</td>
    </tr>
  `;
  document.getElementById('checkoutTotal').textContent = result.ok ? formatMoney(result.totalPrice) : (result.error || 'Please review your dimensions.');

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

  // submit_automated_order now returns a row (order_no, pancake_order_id, pancake_sync_status) -
  // show the real Pancake order id when the sync went through, since that's the number Pancake
  // (and any staff working there) will actually recognize. Falls back to our internal OrderNo
  // whenever there's no Pancake id yet (sync still pending/failed) - the request is always
  // recorded either way, so the customer still gets something to reference.
  const result = (data && data[0]) || {};
  document.getElementById('confirmationOrderNo').textContent =
    (result.pancake_sync_status === 'Synced' && result.pancake_order_id) || result.order_no;
  cart = [];
  saveCart();
  goToStep(5);
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

(function init() {
  captureMessengerPsid();
  prefillCustomerDetailsFromPsid();
  loadCompanyLogo();
  loadCategories();
  renderCart();
  wireLocationToggle();
  wireFulfillmentToggle();
  setupCustomCanvas();
  goToStep(0);

  document.getElementById('modeStandardBtn').addEventListener('click', () => goToStep(1));
  document.getElementById('modeCustomizeBtn').addEventListener('click', () => goToStep('custom-dims'));
  document.getElementById('backToModeBtn').addEventListener('click', () => goToStep(0));
  document.getElementById('backToCategoriesBtn').addEventListener('click', () => goToStep(1));

  document.getElementById('customDimsBackBtn').addEventListener('click', () => goToStep(0));
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
      goToStep('custom-filtration');
    } else {
      await renderCustomCheckout();
      goToStep('custom-checkout');
    }
  });

  document.getElementById('customFiltrationBackBtn').addEventListener('click', () => goToStep('custom-options'));
  // Next step after Filtration isn't defined yet - placeholder until it is.
  document.getElementById('customFiltrationNextBtn').addEventListener('click', () => alert('More steps coming soon.'));

  document.getElementById('customCheckoutBackBtn').addEventListener('click', () => goToStep('custom-options'));
  document.getElementById('customCheckoutConfirmBtn').addEventListener('click', () => {
    const result = window.CustomAquariumCalculator.calculateCustomAquarium(buildCustomPayload());
    cart = cart.filter((line) => line.categoryCode !== 'CUSTOM-AQUARIUM');
    cart.push(buildCustomAquariumCartLine(result));
    saveCart();
    detailsBackTarget = 'custom-checkout';
    goToStep('payment-policy');
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
    goToStep('payment-policy');
  });
  document.getElementById('paymentPolicyBackBtn').addEventListener('click', () => {
    if (detailsBackTarget === 3) renderCart();
    goToStep(detailsBackTarget);
  });
  document.getElementById('paymentPolicyContinueBtn').addEventListener('click', () => goToStep(4));
  document.getElementById('detailsBackBtn').addEventListener('click', () => goToStep('payment-policy'));
  document.getElementById('detailsForm').addEventListener('submit', submitOrder);
  document.getElementById('startNewOrderBtn').addEventListener('click', resetWizard);
})();
