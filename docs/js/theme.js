// Site-wide light/dark theme toggle (portal pages only - not the public order-now.html customer
// flow, which has its own separate wizard styling not covered by this). The actual toggle buttons
// only live on Dashboard (js/dashboard.js's wireThemeToggle), but every portal page loads this
// file - right after css/styles.css, before body renders - so the saved choice applies instantly
// on every page without a flash of the other theme. See css/styles.css's :root[data-theme="dark"]
// block for what actually changes.
//
// Choices: 'light', 'dark', or 'auto' (the default when nothing is saved) - auto is dark from
// AUTO_DARK_FROM_HOUR to AUTO_LIGHT_FROM_HOUR on the device's clock, and re-checks every minute so
// an open page flips at the boundary without a reload.
const PORTAL_THEME_STORAGE_KEY = 'portal_theme';
const AUTO_DARK_FROM_HOUR = 18; // 6:00 PM
const AUTO_LIGHT_FROM_HOUR = 6; // 6:00 AM

function getStoredPortalTheme() {
  try {
    return localStorage.getItem(PORTAL_THEME_STORAGE_KEY);
  } catch {
    return null;
  }
}

// The saved choice ('light' | 'dark' | 'auto'), defaulting to auto
function getPortalThemeChoice() {
  const stored = getStoredPortalTheme();
  return stored === 'light' || stored === 'dark' ? stored : 'auto';
}

function themeForTimeOfDay(date = new Date()) {
  const h = date.getHours();
  return h >= AUTO_DARK_FROM_HOUR || h < AUTO_LIGHT_FROM_HOUR ? 'dark' : 'light';
}

function applyPortalTheme(choice) {
  const theme = choice === 'auto' ? themeForTimeOfDay() : choice;
  const value = theme === 'dark' ? 'dark' : 'light';
  if (document.documentElement.getAttribute('data-theme') !== value) {
    document.documentElement.setAttribute('data-theme', value);
  }
}

function setPortalTheme(choice) {
  try {
    localStorage.setItem(PORTAL_THEME_STORAGE_KEY, choice);
  } catch {
    // Private browsing/storage disabled - theme still applies for this page load, just won't
    // persist to the next one.
  }
  applyPortalTheme(choice);
}

applyPortalTheme(getPortalThemeChoice());

// Auto mode: follow the clock while the page stays open (and catch up when a sleeping tab wakes)
setInterval(() => {
  if (getPortalThemeChoice() === 'auto') applyPortalTheme('auto');
}, 60 * 1000);
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) applyPortalTheme(getPortalThemeChoice());
});
