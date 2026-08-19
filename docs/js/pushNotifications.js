// Web Push subscribe/unsubscribe flow for the Portal PWA - see supabase_web_push_subscriptions.sql
// (storage), supabase_web_push_order_confirmed_trigger.sql (what triggers a send), and
// supabase/functions/send-web-push (what actually sends it). Included on dashboard.html via the
// "Enable Order Notifications" button - wirePushNotificationButton() is the entry point, called
// from that page's own init() once a session exists.

// Paired with VAPID_PRIVATE_KEY (Edge Function secret only, never here) - this half is public by
// design, same as any VAPID public key.
const VAPID_PUBLIC_KEY = 'BJ0iYU529iQ4EnlwEV9o_0segYmeG_SLbF_g3lMIqAeqKtgTQV1ItCbZKKdR7_IHjVFTM-pq56IUo-DoZHLWQjg';

function urlBase64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const rawData = atob(base64);
  return Uint8Array.from([...rawData].map((c) => c.charCodeAt(0)));
}

function pushNotificationsSupported() {
  return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
}

async function getExistingPushSubscription() {
  if (!pushNotificationsSupported()) return null;
  const registration = await navigator.serviceWorker.ready;
  return registration.pushManager.getSubscription();
}

async function enablePushNotifications(session) {
  if (!pushNotificationsSupported()) {
    throw new Error('Push notifications are not supported in this browser.');
  }

  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    throw new Error('Notification permission was not granted.');
  }

  const registration = await navigator.serviceWorker.ready;
  let subscription = await registration.pushManager.getSubscription();
  if (!subscription) {
    subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY)
    });
  }

  const json = subscription.toJSON();
  const { error } = await supabaseClient.rpc('staff_save_push_subscription', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_endpoint: json.endpoint,
    p_p256dh: json.keys.p256dh,
    p_auth: json.keys.auth
  });

  if (error) {
    throw new Error(error.message);
  }
}

async function disablePushNotifications(session) {
  const subscription = await getExistingPushSubscription();
  if (!subscription) return;

  const endpoint = subscription.endpoint;
  await subscription.unsubscribe();

  await supabaseClient.rpc('staff_delete_push_subscription', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_endpoint: endpoint
  });
}

// Wires a single toggle button (id: pushNotifyBtn) to reflect and control subscription state.
// Safe to call even where the button doesn't exist on the page (no-ops).
async function wirePushNotificationButton(session) {
  const btn = document.getElementById('pushNotifyBtn');
  if (!btn) return;

  if (!pushNotificationsSupported()) {
    btn.textContent = 'Notifications not supported on this browser';
    btn.disabled = true;
    return;
  }

  async function refreshButtonState() {
    const subscription = await getExistingPushSubscription();
    const isSubscribed = !!subscription && Notification.permission === 'granted';
    btn.textContent = isSubscribed ? '🔔 Order Notifications: On (tap to turn off)' : '🔕 Enable Order Notifications';
    btn.classList.toggle('btn-success', isSubscribed);
    btn.classList.toggle('btn-secondary', !isSubscribed);
    return isSubscribed;
  }

  let isSubscribed = await refreshButtonState();

  btn.addEventListener('click', async () => {
    btn.disabled = true;
    try {
      if (isSubscribed) {
        await disablePushNotifications(session);
      } else {
        await enablePushNotifications(session);
      }
      isSubscribed = await refreshButtonState();
    } catch (err) {
      alert(err.message || 'Something went wrong.');
    } finally {
      btn.disabled = false;
    }
  });
}
