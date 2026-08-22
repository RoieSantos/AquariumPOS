// Registers sw.js so the portal is installable (Add to Home Screen on Android/iOS, or
// "Install app" on desktop Chrome/Edge). See sw.js for caching strategy/rationale.
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  });
}

// --- Install prompt banner ----------------------------------------------------------------
// Per "can you create me an auto install to the mobile... will it auto install to their phone?" -
// a TRUE zero-tap install from a link is not possible on either platform: both Android and iOS
// deliberately block any website from silently installing anything, as a security measure no web
// app can work around. This is the closest the web actually allows:
//   - Android/desktop Chrome/Edge: a real one-tap "Install" button, using the browser's own
//     beforeinstallprompt API (only fires once the manifest/HTTPS/service-worker installability
//     checks already pass, which they do here).
//   - iOS Safari (and iOS Chrome, same WebKit share sheet): there is NO install API at all on iOS
//     - Apple has never shipped one - so the only path is the person manually tapping Share, then
//     "Add to Home Screen". This banner just shows that instruction; it cannot trigger it.
// Hidden entirely once already installed (running in standalone display mode), and dismissible
// with a cooldown so it doesn't nag on every visit.
(function () {
  const DISMISS_KEY = 'pwaInstallBannerDismissedAt';
  const COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

  function isStandalone() {
    return window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
  }

  function recentlyDismissed() {
    try {
      const dismissedAt = Number(localStorage.getItem(DISMISS_KEY) || 0);
      return dismissedAt > 0 && (Date.now() - dismissedAt) < COOLDOWN_MS;
    } catch {
      return false;
    }
  }

  function dismiss(bannerEl) {
    try { localStorage.setItem(DISMISS_KEY, String(Date.now())); } catch {}
    bannerEl.remove();
  }

  function isIos() {
    return /iphone|ipad|ipod/i.test(navigator.userAgent) && !window.MSStream;
  }

  function showBanner({ text, actionLabel, onAction }) {
    if (document.querySelector('.pwa-install-banner')) return; // already showing one

    const banner = document.createElement('div');
    banner.className = 'pwa-install-banner';
    banner.innerHTML = `
      <span class="pwa-install-icon">📲</span>
      <span class="pwa-install-text">${text}</span>
      ${actionLabel ? `<button type="button" class="btn btn-primary btn-sm pwa-install-action">${actionLabel}</button>` : ''}
      <button type="button" class="pwa-install-dismiss" aria-label="Dismiss" title="Dismiss">&times;</button>
    `;
    document.body.appendChild(banner);

    banner.querySelector('.pwa-install-dismiss').addEventListener('click', () => dismiss(banner));
    const actionBtn = banner.querySelector('.pwa-install-action');
    if (actionBtn && onAction) {
      actionBtn.addEventListener('click', () => onAction(banner));
    }
  }

  if (isStandalone() || recentlyDismissed()) return;

  let deferredInstallEvent = null;

  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault(); // suppress the browser's own mini-infobar - show our banner instead
    deferredInstallEvent = event;
    showBanner({
      text: 'Install this app on your device for quick access.',
      actionLabel: 'Install',
      onAction: async (banner) => {
        deferredInstallEvent.prompt();
        await deferredInstallEvent.userChoice;
        deferredInstallEvent = null;
        banner.remove();
      }
    });
  });

  if (isIos()) {
    showBanner({ text: 'Install this app: tap Share, then "Add to Home Screen".' });
  }
})();
