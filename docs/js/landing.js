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
