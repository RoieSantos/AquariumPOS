// Business Central-style filter pane header, shared by every list page with an
// <aside class="bc-filterpane"> (css/bc-list.css). Turns the plain "Filter list by" head into:
//   - an expandable section toggle (chevron) that collapses/expands the pane body, and
//   - a hide button (x) that closes the whole pane via the page's own #filterPaneBtn, so each
//     page's existing open/close logic (grid columns, fitGridToViewport...) still runs.
// Collapsed by default on phones (<= 860px, where the pane stacks above the list) and expanded on
// desktop; the choice is remembered per page. The head shows how many filters are set while
// collapsed, so an active filter is never invisible.
(function () {
  const PHONE = window.matchMedia('(max-width: 860px)');
  const CHEVRON = '<svg class="bc-fp-chev" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 3.5 10.5 8 6 12.5"/></svg>';

  function storageKey() { return 'bcFilterPaneCollapsed:' + (PHONE.matches ? 'phone:' : 'desk:') + location.pathname.split('/').pop(); }
  function readSaved() {
    try { const v = localStorage.getItem(storageKey()); return v === null ? null : v === '1'; } catch (e) { return null; }
  }
  function save(collapsed) {
    try { localStorage.setItem(storageKey(), collapsed ? '1' : '0'); } catch (e) { /* storage blocked - fine */ }
  }

  function enhance(pane) {
    const head = pane.querySelector('.bc-pane-head');
    const body = pane.querySelector('.bc-pane-body');
    if (!head || !body || head.querySelector('.bc-fp-toggle')) return;

    if (!body.id) body.id = (pane.id || 'filterPane') + 'Body';
    const title = head.textContent.trim() || 'Filter list by';
    head.innerHTML =
      '<button type="button" class="bc-fp-toggle" aria-controls="' + body.id + '">' + CHEVRON +
      '<span>' + title + '</span><span class="bc-fp-count"></span></button>' +
      '<button type="button" class="bc-fp-close" title="Hide filter pane" aria-label="Hide filter pane">&times;</button>';

    const toggle = head.querySelector('.bc-fp-toggle');
    const count = head.querySelector('.bc-fp-count');

    function setCollapsed(collapsed) {
      pane.classList.toggle('fp-collapsed', collapsed);
      toggle.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
      toggle.title = collapsed ? 'Show filters' : 'Collapse filters';
      window.dispatchEvent(new Event('resize')); // let pages re-fit their grid to the new height
    }

    function updateCount() {
      const n = [...body.querySelectorAll('input, select')]
        .filter((el) => el.type !== 'checkbox' && el.type !== 'radio' && String(el.value || '').trim() !== '').length;
      count.textContent = n ? '(' + n + ')' : '';
    }

    toggle.addEventListener('click', () => {
      const collapsed = !pane.classList.contains('fp-collapsed');
      setCollapsed(collapsed);
      save(collapsed);
    });
    head.querySelector('.bc-fp-close').addEventListener('click', () => {
      const btn = document.getElementById('filterPaneBtn');
      if (btn) btn.click();
      else pane.classList.add('hidden');
    });
    body.addEventListener('input', updateCount);
    body.addEventListener('change', updateCount);
    // Pages also set filters from code (status tabs, deep links) without firing input events.
    setInterval(updateCount, 1000);

    const saved = readSaved();
    setCollapsed(saved === null ? PHONE.matches : saved);
    updateCount();
  }

  function init() { document.querySelectorAll('.bc-filterpane').forEach(enhance); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
