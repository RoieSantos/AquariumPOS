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
})();
