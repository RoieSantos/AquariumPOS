// Registers sw.js so the portal is installable (Add to Home Screen on Android/iOS, or
// "Install app" on desktop Chrome/Edge). See sw.js for caching strategy/rationale.
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  });
}
