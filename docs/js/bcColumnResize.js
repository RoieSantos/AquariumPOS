// Business Central-style column resizing for list grids (css/bc-list.css .bc-grid).
//
// Per "in the order list can the user adjust the field manually .. for example make the collumn
// wider": drag the right edge of a column header to resize it; the widths are remembered per list,
// per browser (localStorage), and a double-click on any edge puts that list back to automatic widths.
//
// Opt-in: only tables with data-resize-key="<name>" get it - the key names the saved layout, so
// each list keeps its own. The first drag freezes every column at its current width and switches
// the table to table-layout:fixed (.bc-grid-fixed), so one column changing never re-flows the rest;
// text that no longer fits is cut off with an ellipsis, as in BC.
(function () {
  const STORAGE_PREFIX = 'bc-col-widths:';
  const MIN_WIDTH = 40;

  function readWidths(key) {
    try {
      const raw = localStorage.getItem(STORAGE_PREFIX + key);
      const widths = raw ? JSON.parse(raw) : null;
      return Array.isArray(widths) ? widths : null;
    } catch (err) {
      return null;
    }
  }

  function writeWidths(key, widths) {
    try {
      if (widths) localStorage.setItem(STORAGE_PREFIX + key, JSON.stringify(widths));
      else localStorage.removeItem(STORAGE_PREFIX + key);
    } catch (err) {
      /* Layout simply won't persist - not worth surfacing. */
    }
  }

  function headerCells(table) {
    return table.tHead ? Array.from(table.tHead.rows[0].cells) : [];
  }

  // The column itself being hidden - NOT offsetParent, which is also null while the whole list is
  // still hidden behind the login check (Online Orders' #setupContent), and would size it to 0.
  function isColumnHidden(th) {
    return th.classList.contains('hidden') || getComputedStyle(th).display === 'none';
  }

  // A hidden column (e.g. Online Orders' Delivery Fee for some staff) keeps its slot as 0 so the
  // saved array still lines up with the header cells.
  function applyWidths(table, widths) {
    const cells = headerCells(table);
    let total = 0;
    cells.forEach((th, i) => {
      const w = Number(widths[i]) || 0;
      th.style.width = w > 0 ? `${w}px` : '';
      if (!isColumnHidden(th)) total += w;
    });
    table.classList.add('bc-grid-fixed');
    table.style.width = `${Math.round(total)}px`;
  }

  function clearWidths(table) {
    headerCells(table).forEach((th) => { th.style.width = ''; });
    table.classList.remove('bc-grid-fixed');
    table.style.width = '';
  }

  function currentWidths(table) {
    return headerCells(table).map((th) => (isColumnHidden(th) ? 0 : Math.round(th.getBoundingClientRect().width)));
  }

  function initTable(table) {
    const key = table.dataset.resizeKey;
    const cells = headerCells(table);
    if (!key || cells.length === 0) return;

    const saved = readWidths(key);
    if (saved && saved.length === cells.length) applyWidths(table, saved);

    cells.forEach((th, index) => {
      const handle = document.createElement('span');
      handle.className = 'bc-col-resizer';
      handle.title = 'Drag to resize - double-click to reset all columns';
      handle.setAttribute('aria-hidden', 'true');
      th.appendChild(handle);

      handle.addEventListener('click', (e) => e.stopPropagation());

      handle.addEventListener('dblclick', (e) => {
        e.preventDefault();
        e.stopPropagation();
        clearWidths(table);
        writeWidths(key, null);
      });

      handle.addEventListener('pointerdown', (e) => {
        if (e.button !== 0) return;
        e.preventDefault();
        e.stopPropagation();

        const widths = currentWidths(table);
        applyWidths(table, widths);
        const startX = e.clientX;
        const startWidth = widths[index];

        handle.setPointerCapture(e.pointerId);
        handle.classList.add('resizing');
        document.body.classList.add('bc-col-resizing');

        const onMove = (ev) => {
          widths[index] = Math.max(MIN_WIDTH, Math.round(startWidth + ev.clientX - startX));
          applyWidths(table, widths);
        };
        const onUp = () => {
          handle.removeEventListener('pointermove', onMove);
          handle.removeEventListener('pointerup', onUp);
          handle.removeEventListener('pointercancel', onUp);
          handle.classList.remove('resizing');
          document.body.classList.remove('bc-col-resizing');
          writeWidths(key, widths);
        };

        handle.addEventListener('pointermove', onMove);
        handle.addEventListener('pointerup', onUp);
        handle.addEventListener('pointercancel', onUp);
      });
    });
  }

  function initAll() {
    document.querySelectorAll('table.bc-grid[data-resize-key]').forEach(initTable);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initAll);
  else initAll();
})();
