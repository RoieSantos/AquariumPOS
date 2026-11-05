// Navigation helpers shared by the three web calculators (see calculator-ui.css). Purely
// presentational - only reads the DOM the pricing scripts already update, never calls into them:
//   1. Highlights the step-nav pill for whichever section is currently scrolled into view.
//   2. Mirrors the live price (#priceLine) into the fixed bottom bar shown on narrow screens.
(function () {
  var links = Array.prototype.slice.call(document.querySelectorAll('.step-nav a[href^="#"]'));
  var targets = links.map(function (link) {
    return document.getElementById(link.getAttribute('href').slice(1));
  });

  function updateActiveStep() {
    var activeIndex = 0;
    targets.forEach(function (target, i) {
      if (target && target.offsetParent !== null && target.getBoundingClientRect().top <= 120) {
        activeIndex = i;
      }
    });
    // Scrolled to the very bottom - the last short section may never reach the top, so force it.
    if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4) {
      for (var i = targets.length - 1; i >= 0; i--) {
        if (targets[i] && targets[i].offsetParent !== null) { activeIndex = i; break; }
      }
    }
    links.forEach(function (link, i) {
      link.classList.toggle('active', i === activeIndex);
    });
  }

  if (links.length) {
    window.addEventListener('scroll', updateActiveStep, { passive: true });
    window.addEventListener('resize', updateActiveStep);
    updateActiveStep();
  }

  var priceLine = document.getElementById('priceLine');
  var barPrice = document.getElementById('quoteBarPrice');
  if (priceLine && barPrice) {
    var syncBar = function () {
      var value = priceLine.querySelector('.price-value');
      var text = (value ? value.textContent : priceLine.textContent).replace(/^\s*Price:\s*/, '').trim();
      barPrice.textContent = text || '-';
    };
    new MutationObserver(syncBar).observe(priceLine, { childList: true, subtree: true, characterData: true });
    syncBar();
  }

  // 3. Pinned drawing (Custom Aquarium calculator): keeps #drawingCard stuck under the step nav while
  //    options are changed. On by default; the toggle's choice is remembered per browser.
  var pinCard = document.querySelector('.drawing-pinned');
  var pinBtn = document.getElementById('drawingPinToggle');
  if (pinCard && pinBtn) {
    var PIN_KEY = 'rsCalcDrawingPinned';
    var nav = document.querySelector('.step-nav');
    var root = document.documentElement;
    var measure = function () {
      if (nav) root.style.setProperty('--step-nav-h', nav.offsetHeight + 'px');
      var pinnedNow = pinCard.classList.contains('is-pinned');
      root.style.setProperty('--pinned-drawing-h', pinnedNow ? pinCard.offsetHeight + 'px' : '0px');
    };
    var setPinned = function (on, save) {
      pinCard.classList.toggle('is-pinned', on);
      document.body.classList.toggle('drawing-is-pinned', on);
      pinBtn.setAttribute('aria-pressed', on ? 'true' : 'false');
      pinBtn.innerHTML = on ? '&#128204; Pinned' : '&#128204; Pin drawing';
      pinBtn.title = on ? 'Unpin - let the drawing scroll with the page' : 'Keep the drawing visible while scrolling';
      if (save) {
        try { localStorage.setItem(PIN_KEY, on ? '1' : '0'); } catch (e) { /* storage blocked */ }
      }
      measure();
    };
    var saved = null;
    try { saved = localStorage.getItem(PIN_KEY); } catch (e) { /* storage blocked */ }
    setPinned(saved !== '0', false);
    pinBtn.addEventListener('click', function () {
      setPinned(!pinCard.classList.contains('is-pinned'), true);
    });
    window.addEventListener('resize', measure);
    if (window.ResizeObserver) new ResizeObserver(measure).observe(pinCard);

    // .is-stuck = the card is currently floating over the form (page scrolled past its natural
    // spot) - drives the elevated shadow in calculator-ui.css.
    var updateStuck = function () {
      var stuck = pinCard.classList.contains('is-pinned') &&
        pinCard.parentElement.getBoundingClientRect().top < pinCard.getBoundingClientRect().top - 1;
      pinCard.classList.toggle('is-stuck', stuck);
    };
    window.addEventListener('scroll', updateStuck, { passive: true });
    window.addEventListener('resize', updateStuck);
    pinBtn.addEventListener('click', updateStuck);
    updateStuck();
  }
})();
