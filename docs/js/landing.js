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
    const logoImg = document.getElementById('landingLogo');
    if (logoImg) {
      logoImg.src = info['LogoUrl'];
      logoImg.hidden = false;
    }
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

  // De-dupe categories that only differ by code casing (e.g. "Aquarium" vs "AQUARIUM") into one
  // pill - same reasoning as order-now.html's own loadCategories.
  const seen = new Map();
  data.forEach((cat) => {
    const key = String(cat.code || '').toUpperCase();
    if (key && !seen.has(key)) seen.set(key, cat.description);
  });

  wrap.innerHTML = Array.from(seen.values())
    .map((label) => `<a class="land-pill" href="order-now.html">${label}</a>`)
    .join('');
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
      if (firstImageUrl(item.images)) items.push(item);
    });
  });

  if (items.length === 0) {
    return;
  }
  section.hidden = false;

  grid.innerHTML = items
    .slice(0, MAX_FEATURED_PRODUCTS)
    .map((item) => `
      <a class="land-product-card" href="order-now.html">
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
