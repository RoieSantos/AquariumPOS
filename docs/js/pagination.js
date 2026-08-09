// Shared pagination control bar for RPC-fed list pages (Item Setup, Variant Setup, Advance
// Orders, Expenses, Online Orders, etc.). Every one of those RPCs now returns a "total_count"
// column (count(*) over(), computed before LIMIT/OFFSET applies) alongside p_page/p_page_size
// params - this module just renders Prev/Next + a rows-per-page selector against that, and
// leaves the actual data (re)fetching to each page's own load function via the callbacks.
const PAGE_SIZE_OPTIONS = [25, 50, 100, 200];

/**
 * @param {HTMLElement} container - element the bar is rendered into (its innerHTML is replaced).
 * @param {{ page: number, pageSize: number, totalCount: number }} state
 * @param {{ onPageChange: (newPage:number) => void, onPageSizeChange: (newSize:number) => void }} callbacks
 */
function renderPaginationBar(container, state, callbacks) {
  const { page, pageSize, totalCount } = state;
  const totalPages = Math.max(1, Math.ceil(totalCount / pageSize));

  // Hide the bar entirely when everything already fits on the smallest page size - a Warehouses
  // or Staff Users table with a handful of rows doesn't need Prev/Next clutter.
  if (totalCount <= PAGE_SIZE_OPTIONS[0]) {
    container.innerHTML = '';
    return;
  }

  const startRow = totalCount === 0 ? 0 : (page - 1) * pageSize + 1;
  const endRow = Math.min(page * pageSize, totalCount);

  const sizeOptionsHtml = PAGE_SIZE_OPTIONS
    .map((size) => `<option value="${size}" ${size === pageSize ? 'selected' : ''}>${size} / page</option>`)
    .join('');

  container.innerHTML = `
    <div class="pagination-bar">
      <span class="pagination-info">Showing ${startRow}-${endRow} of ${totalCount}</span>
      <div class="pagination-controls">
        <button class="btn btn-secondary btn-sm" data-action="prev" type="button" ${page <= 1 ? 'disabled' : ''}>&larr; Prev</button>
        <span class="pagination-info">Page ${page} of ${totalPages}</span>
        <button class="btn btn-secondary btn-sm" data-action="next" type="button" ${page >= totalPages ? 'disabled' : ''}>Next &rarr;</button>
        <select class="pagination-page-size" aria-label="Rows per page">${sizeOptionsHtml}</select>
      </div>
    </div>
  `;

  container.querySelector('[data-action="prev"]').addEventListener('click', () => {
    if (page > 1) callbacks.onPageChange(page - 1);
  });
  container.querySelector('[data-action="next"]').addEventListener('click', () => {
    if (page < totalPages) callbacks.onPageChange(page + 1);
  });
  container.querySelector('.pagination-page-size').addEventListener('change', (e) => {
    callbacks.onPageSizeChange(Number(e.target.value));
  });
}
