// The logo file itself is flat white behind the circular mark (no alpha channel) - fine for the
// nav bar/hero-card logo, which are meant to look like a framed badge, but it shows up as an ugly
// light rectangle when used as the faint page background below. There's no separate cutout asset
// to point at instead, so this draws the image to an off-screen canvas and clears any near-white
// pixel's alpha, returning a data: URL with a true transparent background. Falls back to the
// original URL untouched if the canvas can't be read back (e.g. the image host doesn't send
// CORS headers, which would otherwise throw on getImageData - "tainted canvas").
function makeWhiteTransparent(imageUrl) {
  return new Promise((resolve) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => {
      try {
        const canvas = document.createElement('canvas');
        canvas.width = img.naturalWidth;
        canvas.height = img.naturalHeight;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0);
        const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
        const data = imageData.data;
        const WHITE_THRESHOLD = 232;
        for (let i = 0; i < data.length; i += 4) {
          if (data[i] >= WHITE_THRESHOLD && data[i + 1] >= WHITE_THRESHOLD && data[i + 2] >= WHITE_THRESHOLD) {
            data[i + 3] = 0;
          }
        }
        ctx.putImageData(imageData, 0, 0);
        resolve(canvas.toDataURL('image/png'));
      } catch {
        resolve(imageUrl);
      }
    };
    img.onerror = () => resolve(imageUrl);
    img.src = imageUrl;
  });
}

// Customer landing page (docs/index.html) - populates the logo/name/Facebook link from
// public."CompanyInfo" (see supabase_company_info_table.sql), reusing fetchCompanyInfo() from
// companyBranding.js. That table is readable by the anon key with no session at all, which is
// exactly what this page needs since it's the public-facing entry point with no login.
async function applyLandingBranding() {
  const info = await fetchCompanyInfo();
  if (!info) return;

  if (info['CompanyName']) {
    document.querySelectorAll('[data-company-name]').forEach((el) => {
      el.textContent = info['CompanyName'];
    });
    document.title = `${info['CompanyName']} - Aquariums & Pet Supplies`;
  }

  if (info['LogoUrl']) {
    // Nav bar logo starts hidden (a tiny fallback icon looks off in that strip) - only shown
    // once the real logo is in. The big hero logo is always visible (falls back to the small
    // app icon while this loads) since it's the page's main visual, mirroring the hero image in
    // the reference design.
    const navLogo = document.getElementById('landingLogoNav');
    if (navLogo) {
      navLogo.src = info['LogoUrl'];
      navLogo.hidden = false;
    }

    const heroLogo = document.getElementById('landingLogo');
    if (heroLogo) heroLogo.src = info['LogoUrl'];

    // Same full-page background technique as the staff portal's Dashboard (applyAppBackground in
    // companyBranding.js / body.app-has-photo-bg in css/styles.css) - a fixed, centered background
    // image plus a tint overlay (see body.land-has-logo-bg in css/landing.css) - using the logo
    // itself here rather than CompanyInfo.BackgroundImageUrl, since the request was specifically
    // "our logo in the background" like the Dashboard has. Its white backing is stripped first
    // (see makeWhiteTransparent above) so it blends into the page instead of showing a light box.
    makeWhiteTransparent(info['LogoUrl']).then((transparentUrl) => {
      document.body.style.backgroundImage = `url(${transparentUrl})`;
      document.body.classList.add('land-has-logo-bg');
    });
  }

  if (info['FacebookUrl']) {
    const fbLink = document.getElementById('landingFacebookLink');
    if (fbLink) {
      fbLink.href = info['FacebookUrl'];
      fbLink.hidden = false;
    }
  }
}

applyLandingBranding();

// ---- Shop by category + featured products ----
// Both reuse the same public (anon, no login) RPCs order-now.html's wizard already relies on
// (see supabase_automated_orders_tables.sql / supabase_item_hide_from_set.sql) - nothing new is
// exposed, this just surfaces the same live catalog data on the landing page.

function formatPeso(value) {
  return '₱' + Number(value || 0).toLocaleString('en-PH', { minimumFractionDigits: 0, maximumFractionDigits: 0 });
}

// Items.Images is a comma-separated string of URLs - same convention/helper as
// docs/js/orderNow.js's firstImageUrl.
function firstImageUrl(images) {
  if (!images) return null;
  const first = String(images).split(',')[0].trim();
  return first || null;
}

// Full live category list (Fish, Aquariums, Stands, Filtration, Pumps, Lights, Sets, etc.) -
// unlike order-now.html's Standard flow, nothing is filtered out here since the point of this
// section is "what do you sell", not "what can I one-click buy".
async function loadCategoryPills() {
  const wrap = document.getElementById('landingCategoryPills');
  if (!wrap) return;

  const { data, error } = await supabaseClient.rpc('public_list_order_categories');
  if (error || !data || data.length === 0) return;

  // De-dupe categories that only differ by code OR label casing (e.g. "Aquarium" vs "AQUARIUM",
  // "Sticker" vs "STICKER") into one pill - same reasoning as order-now.html's own loadCategories.
  // Internal bookkeeping categories (production/customized line items, blank "NULL" rows) mean
  // nothing to a customer, so they're left out entirely.
  const INTERNAL_LABEL = /^(null|production item|customi[sz]ed item|customer sticker)$/i;
  const seenCodes = new Set();
  const seenLabels = new Set();
  const pills = [];
  data.forEach((cat) => {
    const code = String(cat.code || '').toUpperCase();
    const label = String(cat.description || '').trim();
    const labelKey = label.toLowerCase();
    if (!code || !label || INTERNAL_LABEL.test(label) || seenCodes.has(code) || seenLabels.has(labelKey)) return;
    seenCodes.add(code);
    seenLabels.add(labelKey);
    pills.push({ code, label });
  });
  const labels = pills.map((p) => p.label);

  // Only categories a customer can actually order online become links, each to the path that
  // sells it: "Custom ..." -> the Customize flow, FEATURED_CATEGORY_CODES (order-now.html's
  // Standard flow list) -> Standard. Everything else (fish, food, medicines...) is in-store only,
  // so it shows as a plain tag rather than a link to a page that doesn't list it.
  wrap.innerHTML = pills
    .map(({ code, label }) => {
      if (/^custom/i.test(label)) return `<a class="land-pill" href="order-now.html?start=custom">${label}</a>`;
      if (FEATURED_CATEGORY_CODES.includes(code)) return `<a class="land-pill" href="order-now.html?start=standard">${label}</a>`;
      return `<span class="land-pill land-pill-static" title="Available in-store">${label}</span>`;
    })
    .join('');

  // Long lists collapse to the first few with a "Show all" toggle, so the pills read as a quick
  // overview instead of a wall of tags pushing the rest of the page down.
  const VISIBLE_PILLS = 12;
  const moreBtn = document.getElementById('landingPillsMoreBtn');
  if (moreBtn && labels.length > VISIBLE_PILLS) {
    wrap.classList.add('land-pill-row-collapsed');
    moreBtn.textContent = `Show all ${labels.length} categories`;
    moreBtn.hidden = false;
    moreBtn.addEventListener('click', () => {
      const collapsed = wrap.classList.toggle('land-pill-row-collapsed');
      moreBtn.textContent = collapsed ? `Show all ${labels.length} categories` : 'Show fewer';
    });
  }
}

// A handful of real product photos pulled straight from the catalog, so "what products do we
// offer" shows actual current stock instead of stock marketing photos. Limited to the same
// categories order-now.html's Standard flow offers (pre-built Sets/Aquariums/Stands/Pumps/
// Lights) since those are the ones customers can browse/one-click order without customizing.
const FEATURED_CATEGORY_CODES = ['SET', 'AQUARIUM', 'STAND', 'PUMP', 'LIGHTS'];
const MAX_FEATURED_PRODUCTS = 8;

async function loadFeaturedProducts() {
  const section = document.getElementById('landingProductsSection');
  const grid = document.getElementById('landingProductGrid');
  if (!section || !grid) return;

  const results = await Promise.all(
    FEATURED_CATEGORY_CODES.map((code) => supabaseClient.rpc('public_list_order_items', { p_category_code: code }))
  );

  const items = [];
  results.forEach((result) => {
    (result.data || []).forEach((item) => {
      // A 0-priced item (price not set yet) reads as "free" to a customer - skip it here.
      if (firstImageUrl(item.images) && Number(item.price) > 0) items.push(item);
    });
  });

  if (items.length === 0) {
    return;
  }
  section.hidden = false;
  const shopNavLink = document.getElementById('landingShopNavLink');
  if (shopNavLink) shopNavLink.hidden = false;

  grid.innerHTML = items
    .slice(0, MAX_FEATURED_PRODUCTS)
    .map((item) => `
      <a class="land-product-card" href="order-now.html?start=standard">
        <img src="${firstImageUrl(item.images)}" alt="${item.name}" loading="lazy" />
        <div class="land-product-info">
          <div class="land-product-name">${item.name}</div>
          <div class="land-product-price">${formatPeso(item.price)}</div>
        </div>
      </a>
    `)
    .join('');
}

loadCategoryPills();
loadFeaturedProducts();

// ---- Top bar: phone menu + "you are here" highlighting ----
function wireLandingNav() {
  const menuBtn = document.getElementById('landingMenuBtn');
  const nav = document.getElementById('landingNav');
  if (!menuBtn || !nav) return;

  const setOpen = (open) => {
    nav.classList.toggle('open', open);
    menuBtn.setAttribute('aria-expanded', String(open));
    menuBtn.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  };
  menuBtn.addEventListener('click', () => setOpen(!nav.classList.contains('open')));
  // Picking a link (or tapping outside) closes the phone menu again.
  nav.addEventListener('click', (event) => { if (event.target.closest('a')) setOpen(false); });
  document.addEventListener('click', (event) => {
    if (!nav.contains(event.target) && !menuBtn.contains(event.target)) setOpen(false);
  });

  // Highlights the in-page section link (#offer/#shop/#builds/#visit) currently on screen.
  const sectionLinks = Array.from(nav.querySelectorAll('a.land-nav-link[href^="#"]'));
  const updateActive = () => {
    let active = null;
    sectionLinks.forEach((link) => {
      const target = document.getElementById(link.getAttribute('href').slice(1));
      if (target && !link.hidden && target.getBoundingClientRect().top <= 140) active = link;
    });
    sectionLinks.forEach((link) => link.classList.toggle('active', link === active));
  };
  window.addEventListener('scroll', updateActive, { passive: true });
  updateActive();
}

wireLandingNav();
