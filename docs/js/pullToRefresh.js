// Swipe-down-to-refresh for mobile/PWA pages - per direct request. Standalone (home-screen-
// installed) PWAs have NO browser chrome, so the OS/browser's own native pull-to-refresh gesture
// isn't available at all once a page is "Added to Home Screen" (this is exactly the mode Online
// Order Staff use - see the apple-mobile-web-app-capable meta tags added across docs/*.html). This
// reimplements the gesture in plain JS/CSS so pages feel like a native app again.
//
// Opt-in per page (NOT auto-wired into every page via pwa.js) - a page calls
// initPullToRefresh(refreshFn) once from its own init(), passing whatever "refresh" means for that
// page (e.g. online-orders.html passes refreshCurrentOrders). Pages with no sensible "refresh"
// concept (a mid-edit form, a modal-heavy setup page) simply don't call it, so there's no risk of
// an accidental pull discarding unsaved work. refreshFn may return a promise - the indicator stays
// in its spinning state until it resolves/rejects (rejection is swallowed, same "don't block the
// user over a failed background refresh" spirit as the rest of this portal).
//
// Touch-only (no mouse/pointer support) - desktop staff already have F5/browser refresh; this is
// purely for the mobile/PWA experience where that's not obviously available.

(function () {
  const PULL_THRESHOLD = 70; // px of actual finger movement needed to trigger a refresh
  const MAX_PULL = 110; // px the indicator is allowed to visually travel, past which it resists further
  const MIN_SPIN_MS = 500; // keeps the spinner from flashing instantly on a fast refresh, feels intentional

  let indicatorEl = null;
  let iconEl = null;
  let labelEl = null;
  let refreshFn = null;
  let touchStartY = null;
  let currentPull = 0;
  let refreshing = false;
  let tracking = false;

  function ensureIndicator() {
    if (indicatorEl) return;

    indicatorEl = document.createElement('div');
    indicatorEl.className = 'pull-refresh-indicator';
    indicatorEl.innerHTML = `
      <span class="pull-refresh-spinner"></span>
      <span class="pull-refresh-label">Pull to refresh</span>
    `;
    document.body.appendChild(indicatorEl);
    iconEl = indicatorEl.querySelector('.pull-refresh-spinner');
    labelEl = indicatorEl.querySelector('.pull-refresh-label');
  }

  function setPull(distance, animate) {
    currentPull = distance;
    indicatorEl.style.transition = animate ? 'transform 0.2s ease' : 'none';
    indicatorEl.style.transform = `translate(-50%, ${distance - 56}px)`;
    indicatorEl.classList.toggle('visible', distance > 4);
    indicatorEl.classList.toggle('ready', distance >= PULL_THRESHOLD);
    labelEl.textContent = distance >= PULL_THRESHOLD ? 'Release to refresh' : 'Pull to refresh';
    iconEl.style.transform = `rotate(${Math.min(distance / PULL_THRESHOLD, 1) * 180}deg)`;
  }

  async function triggerRefresh() {
    refreshing = true;
    indicatorEl.classList.add('spinning');
    labelEl.textContent = 'Refreshing...';
    indicatorEl.style.transition = 'transform 0.2s ease';
    indicatorEl.style.transform = 'translate(-50%, 8px)';

    const startedAt = Date.now();
    try {
      if (refreshFn) await refreshFn();
    } catch {
      // A failed background refresh shouldn't trap the user under a stuck spinner - just close it.
    }

    const elapsed = Date.now() - startedAt;
    if (elapsed < MIN_SPIN_MS) {
      await new Promise((resolve) => setTimeout(resolve, MIN_SPIN_MS - elapsed));
    }

    indicatorEl.classList.remove('spinning', 'ready', 'visible');
    setPull(0, true);
    refreshing = false;
  }

  function handleTouchStart(event) {
    if (refreshing || event.touches.length !== 1) return;
    // Only arm the gesture when the page is already scrolled to the very top - otherwise this
    // would fire mid-scroll on an ordinary upward-then-down swipe anywhere on a long list.
    if ((window.scrollY || document.documentElement.scrollTop || 0) > 0) return;
    touchStartY = event.touches[0].clientY;
    tracking = true;
  }

  function handleTouchMove(event) {
    if (!tracking || touchStartY === null || refreshing) return;

    const deltaY = event.touches[0].clientY - touchStartY;
    if (deltaY <= 0) {
      // Swiped back up before releasing - cancel cleanly rather than leaving the indicator
      // stuck at whatever the last downward position was.
      if (currentPull > 0) setPull(0, true);
      return;
    }

    // Resistance curve past MAX_PULL so the indicator visually "gives up" the further it's
    // dragged, instead of following the finger 1:1 forever - same feel as native pull-to-refresh.
    const resisted = deltaY < MAX_PULL ? deltaY : MAX_PULL + (deltaY - MAX_PULL) * 0.15;
    ensureIndicator();
    setPull(resisted, false);
    // Prevents the page's own bounce/overscroll from fighting the indicator while pulling -
    // requires this listener to be registered non-passive (see the addEventListener call below).
    event.preventDefault();
  }

  function handleTouchEnd() {
    if (!tracking) return;
    tracking = false;
    touchStartY = null;

    if (currentPull >= PULL_THRESHOLD && !refreshing) {
      triggerRefresh();
    } else if (!refreshing) {
      setPull(0, true);
    }
  }

  window.initPullToRefresh = function initPullToRefresh(fn) {
    refreshFn = fn;
    ensureIndicator();
    document.addEventListener('touchstart', handleTouchStart, { passive: true });
    document.addEventListener('touchmove', handleTouchMove, { passive: false });
    document.addEventListener('touchend', handleTouchEnd, { passive: true });
    document.addEventListener('touchcancel', handleTouchEnd, { passive: true });
  };
})();
