// Minimal service worker - exists for PWA "installability" (Add to Home Screen / desktop
// install prompt) and Web Push below. No fetch handler: requests go straight to the network /
// browser HTTP cache. The old network-first handler copied every response into Cache Storage
// on every page load and never pruned old ?v= versions - on the store POS that disk work made
// Online Orders / Transfer Orders take 10-12 s to open. Activate deletes that old cache.

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
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
