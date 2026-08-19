// Site-wide light/dark theme toggle (portal pages only - not the public order-now.html customer
// flow, which has its own separate wizard styling not covered by this). The actual toggle buttons
// only live on Dashboard (js/dashboard.js's wireThemeToggle), but every portal page loads this
// file - right after css/styles.css, before body renders - so the saved choice applies instantly
// on every page without a flash of the other theme. See css/styles.css's :root[data-theme="dark"]
// block for what actually changes.
const PORTAL_THEME_STORAGE_KEY = 'portal_theme';

function getStoredPortalTheme() {
  try {
    return localStorage.getItem(PORTAL_THEME_STORAGE_KEY);
  } catch {
    return null;
  }
}

function applyPortalTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme === 'dark' ? 'dark' : 'light');
}

function setPortalTheme(theme) {
  try {
    localStorage.setItem(PORTAL_THEME_STORAGE_KEY, theme);
  } catch {
    // Private browsing/storage disabled - theme still applies for this page load, just won't
    // persist to the next one.
  }
  applyPortalTheme(theme);
}

applyPortalTheme(getStoredPortalTheme() || 'light');
