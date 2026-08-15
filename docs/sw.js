// Minimal service worker - exists mainly to satisfy PWA "installability" (Add to Home
// Screen / desktop install prompt) so the portal can be added as an app icon. Deliberately
// does NOT cache Supabase API responses or pre-cache pages: this is a live staff tool
// (inventory, orders, delivery) and stale cached data would be worse than no offline support.
// Strategy: network-first for same-origin requests, with a same-origin cache used only as a
// fallback when the network is unavailable (e.g. brief connectivity drop).
const CACHE_NAME = 'rspetstop-portal-v1';

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET' || new URL(request.url).origin !== self.location.origin) {
    return;
  }

  event.respondWith(
    fetch(request)
      .then((response) => {
        const responseClone = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, responseClone));
        return response;
      })
      .catch(() => caches.match(request))
  );
});
