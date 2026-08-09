// Shared company branding helpers - reads public."CompanyInfo" (see
// supabase_company_info_table.sql), edited from General Setup (js/generalSetup.js). That table
// is readable directly by the anon key via RLS (no RPC, no session/password needed) since none
// of this data is sensitive and the Login page in particular has no session yet - so both
// functions below work identically whether the caller is logged in or not.
//
// renderCompanyLetterhead(containerId): the full bordered letterhead (logo + name/Facebook/
// address/contact/DTI no.) - used on printable pages (Transfer Order print, Delivery Manifest).
// The logo itself is only shown there, not on Login/Dashboard.
// applyLoginBackground(): Login page only - if a BackgroundImageUrl is set, uses it as a
// full-bleed photo background over the plain gradient backdrop; does nothing otherwise.
// applyAppBackground(): any authenticated page (currently Dashboard) - if a BackgroundImageUrl is
// set, shows it full-bleed (subtly, behind the page's normal white cards/content) via the
// app-has-photo-bg body class; does nothing otherwise, leaving the page's normal background.
async function fetchCompanyInfo() {
  const { data, error } = await supabaseClient
    .from('CompanyInfo')
    .select('*')
    .eq('"Id"', 1)
    .limit(1);

  if (error || !data || data.length === 0) return null;
  return data[0];
}

async function applyLoginBackground() {
  const info = await fetchCompanyInfo();
  if (!info || !info['BackgroundImageUrl']) return;

  document.body.style.backgroundImage = `url(${info['BackgroundImageUrl']})`;
  document.body.classList.add('login-has-photo-bg');
}

async function applyAppBackground() {
  const info = await fetchCompanyInfo();
  if (!info || !info['BackgroundImageUrl']) return;

  document.body.style.backgroundImage = `url(${info['BackgroundImageUrl']})`;
  document.body.classList.add('app-has-photo-bg');
}

async function renderCompanyLetterhead(containerId) {
  const container = document.getElementById(containerId);
  if (!container) return;

  const info = await fetchCompanyInfo();
  if (!info) return;

  const lines = [
    info['FacebookUrl'],
    info['Address'] ? `Address : ${info['Address']}` : '',
    info['ContactNo'] ? `Contact No : ${info['ContactNo']}` : '',
    info['DtiNo'] ? `DTI No.: ${info['DtiNo']}` : ''
  ].filter(Boolean);

  const logoHtml = info['LogoUrl']
    ? `<img src="${info['LogoUrl']}" alt="Company logo" class="letterhead-logo" />`
    : '';
  const nameHtml = info['CompanyName']
    ? `<div class="letterhead-name">${info['CompanyName']}</div>`
    : '';
  const linesHtml = lines.map((line) => `<div class="letterhead-line">${line}</div>`).join('');

  if (!logoHtml && !nameHtml && !linesHtml) return;

  container.innerHTML = `
    <div class="letterhead">
      ${logoHtml}
      <div class="letterhead-info">
        ${nameHtml}
        ${linesHtml}
      </div>
    </div>
  `;
}
