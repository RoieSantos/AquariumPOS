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

// Web Push - see docs/js/pushNotifications.js for the subscribe flow and
// supabase/functions/send-web-push for what actually sends the push message this receives.
// Payload shape is { title, body, url } (set by send-web-push's notificationPayload).
self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = { body: event.data ? event.data.text() : '' };
  }

  const title = data.title || 'RS Pet Stop Portal';
  const options = {
    body: data.body || '',
    icon: 'icons/apple-touch-icon.png',
    badge: 'icons/apple-touch-icon.png',
    data: { url: data.url || 'dashboard.html' }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

// Focuses an already-open portal tab if there is one, otherwise opens a new one - same "don't
// pile up duplicate tabs" behavior as most notification-driven apps.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = event.notification.data && event.notification.data.url ? event.notification.data.url : 'dashboard.html';

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.includes(targetUrl) && 'focus' in client) {
          return client.focus();
        }
      }
      if (self.clients.openWindow) {
        return self.clients.openWindow(targetUrl);
      }
    })
  );
});
