// Online Order Lines drill-down page logic (any active staff, read-only for order/line data,
// LIVE view). Reads ?order=<OrderID> from the URL and fetches directly from Pancake via
// admin_get_online_order_detail_live() (header + line items in one call, no local Supabase
// mirror table involved). No password re-unlock prompt here - reuses the password captured at
// login (session.password, see auth.js). Each line's "note" (from Pancake's own per-item note
// field) is shown in its own column alongside the other details.
//
// ATTACHMENTS: per-line pictures/files are an RS Pet Stop-side addition with no Pancake
// equivalent, so they're stored separately (public."OnlineOrderLineAttachments" - see
// supabase_online_order_line_attachments.sql) and joined in here by line_id after the live
// line items load. Uploads go through a signed-upload-URL minted server-side (staff
// credentials re-verified first) rather than a direct anon-key write - see that SQL file's
// header comment for the full flow.
//
// STATUS PHOTOS: a separate, order-level (not per-line) gallery of photos captured on the
// "To Ship" button on the Online Orders list page (js/onlineOrders.js) - see
// public."OnlineOrderStatusPhotos" / supabase_online_order_status_photo.sql. Only kept for
// 30 days (cron_cleanup_old_online_order_status_photos), so an empty gallery here doesn't
// necessarily mean no photo was ever sent for this order.
let currentSession = null;
let orderId = null;
let currentLines = [];
let attachmentsByLineId = {};
let pendingUploadLineId = null;

const ATTACHMENTS_BUCKET = 'online-order-line-attachments';
const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;

function formatMoney(value) {
  if (value === null || value === undefined) return '';
  return Number(value).toFixed(2);
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
}

function isImageFile(name) {
  return /\.(png|jpe?g|gif|webp)$/i.test(name || '');
}

function attachmentCellHtml(lineId) {
  const items = attachmentsByLineId[lineId] || [];

  const chips = items.map((a) => {
    const label = escapeHtml(a.file_name || 'attachment');
    const link = isImageFile(a.file_name)
      ? `<a href="${a.public_url}" target="_blank" rel="noopener" title="${label}"><img src="${a.public_url}" class="attachment-thumb" alt="${label}" /></a>`
      : `<a href="${a.public_url}" target="_blank" rel="noopener" class="attachment-file-chip">&#128206; ${label}</a>`;
    return `<span class="attachment-chip">${link}<button type="button" class="attachment-remove-btn" data-attachment-id="${a.attachment_id}" title="Remove attachment">&times;</button></span>`;
  }).join('');

  // Lines with no line_id from Pancake can't be reliably keyed, so attaching is disabled for them.
  const addControl = lineId
    ? `<button type="button" class="btn btn-secondary btn-sm attachment-add-btn" data-line-id="${lineId}">+ Add</button>`
    : `<span class="muted">No line ID</span>`;

  return `<div class="attachment-cell">${chips}${addControl}</div>`;
}

function renderLineRows(lines) {
  const tbody = document.getElementById('lineTableBody');

  if (!lines || lines.length === 0) {
    tbody.innerHTML = '<tr><td colspan="11" class="muted">No line items found for this order.</td></tr>';
    return;
  }

  tbody.innerHTML = lines
    .map((l) => `
      <tr>
        <td>${l.line_id || ''}</td>
        <td>${l.item_code || l.product_display_id || ''}</td>
        <td>${l.description || ''}</td>
        <td>${l.quantity ?? ''}</td>
        <td>${formatMoney(l.unit_cost)}</td>
        <td>${formatMoney(l.price)}</td>
        <td>${formatMoney(l.discount)}</td>
        <td>${formatMoney(l.gross_amount)}</td>
        <td>${formatMoney(l.net_amount)}</td>
        <td>${l.note || ''}</td>
        <td>${attachmentCellHtml(l.line_id)}</td>
      </tr>
    `)
    .join('');
}

// Same 10mm/12mm-priority detection as admin_list_online_orders() uses for the order list's
// "Glass" badge (see supabase_orders_sync_tables.sql) - computed client-side here from the
// live line items already on hand, so it can't lag behind the local sync mirror the way the
// list page's badge can.
function detectGlassThickness(lines) {
  const normalize = (value) => String(value || '').replace(/\s+/g, '').toLowerCase();
  let has12mm = false;
  let has10mm = false;

  (lines || []).forEach((l) => {
    const combined = normalize(`${l.description || ''} ${l.note || ''} ${l.item_code || ''}`);
    if (combined.includes('12mm')) has12mm = true;
    if (combined.includes('10mm')) has10mm = true;
  });

  if (has12mm) return '12mm';
  if (has10mm) return '10mm';
  return null;
}

function renderGlassFlag(lines) {
  const wrap = document.getElementById('glassFlagNote');
  const thickness = detectGlassThickness(lines);

  if (!thickness) {
    wrap.classList.add('hidden');
    return;
  }

  wrap.querySelector('.badge').textContent = `${thickness} glass - may need an attachment`;
  wrap.classList.remove('hidden');
}

function renderOrderSummary(lines) {
  const note = document.getElementById('orderSummaryNote');
  const first = lines && lines.length > 0 ? lines[0] : null;
  if (!first) {
    note.textContent = `Order ${orderId} - line items:`;
    return;
  }
  note.textContent = `Order ${first.order_id || orderId} - ${first.customer_name || 'unknown customer'} - status: ${first.status || 'n/a'}`;
}

// Fetches every attachment for this order (all lines in one call) and re-renders just the
// line rows so newly added/removed attachments show up without re-fetching Pancake.
async function loadAttachments() {
  const { data, error } = await supabaseClient.rpc('admin_list_online_order_line_attachments', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });

  attachmentsByLineId = {};
  if (!error && data) {
    data.forEach((a) => {
      if (!attachmentsByLineId[a.line_id]) attachmentsByLineId[a.line_id] = [];
      attachmentsByLineId[a.line_id].push(a);
    });
  }

  renderLineRows(currentLines);
}

async function handleUploadAttachment(lineId, file) {
  if (file.size > MAX_ATTACHMENT_BYTES) {
    alert('That file is too large - max 10 MB.');
    return;
  }

  const { data: uploadRows, error: signError } = await supabaseClient.rpc('admin_create_online_order_line_attachment_upload', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_line_id: lineId,
    p_file_name: file.name
  });

  const uploadInfo = uploadRows && uploadRows[0];
  if (signError || !uploadInfo) {
    alert(`Could not start upload: ${signError ? signError.message : 'unknown error'}`);
    return;
  }

  const { error: uploadError } = await supabaseClient.storage
    .from(ATTACHMENTS_BUCKET)
    .uploadToSignedUrl(uploadInfo.storage_path, uploadInfo.upload_token, file);

  if (uploadError) {
    alert(`Upload failed: ${uploadError.message}`);
    return;
  }

  const { error: recordError } = await supabaseClient.rpc('admin_record_online_order_line_attachment', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId,
    p_line_id: lineId,
    p_file_name: file.name,
    p_storage_path: uploadInfo.storage_path,
    p_public_url: uploadInfo.public_url
  });

  if (recordError) {
    alert(`File uploaded, but could not save it against this line: ${recordError.message}`);
    return;
  }

  await loadAttachments();
}

async function handleRemoveAttachment(attachmentId) {
  if (!confirm('Remove this attachment?')) return;

  const { error } = await supabaseClient.rpc('admin_delete_online_order_line_attachment', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_attachment_id: attachmentId
  });

  if (error) {
    alert(`Could not remove attachment: ${error.message}`);
    return;
  }

  await loadAttachments();
}

function wireAttachmentControls() {
  const fileInput = document.getElementById('attachmentFileInput');

  document.getElementById('lineTableBody').addEventListener('click', (event) => {
    const addBtn = event.target.closest('.attachment-add-btn');
    if (addBtn) {
      pendingUploadLineId = addBtn.dataset.lineId;
      fileInput.click();
      return;
    }

    const removeBtn = event.target.closest('.attachment-remove-btn');
    if (removeBtn) {
      handleRemoveAttachment(removeBtn.dataset.attachmentId);
    }
  });

  fileInput.addEventListener('change', async (event) => {
    const file = event.target.files && event.target.files[0];
    event.target.value = ''; // allow re-selecting the same file later
    if (!file || !pendingUploadLineId) return;

    const lineId = pendingUploadLineId;
    pendingUploadLineId = null;
    await handleUploadAttachment(lineId, file);
  });
}

// "Photos Sent With Status Updates" gallery - photos captured on the "To Ship" button
// (js/onlineOrders.js) via public."OnlineOrderStatusPhotos" (see
// supabase_online_order_status_photo.sql). Order-level, not per-line, and unrelated to the
// per-line attachments above - hidden entirely when this order has none.
function statusPhotoCardHtml(p) {
  const takenAt = p.uploaded_at_utc ? new Date(p.uploaded_at_utc).toLocaleString() : '';
  const sentLabel = p.sent_to_customer ? 'Sent to customer' : 'Not sent to customer';
  const sentClass = p.sent_to_customer ? '' : 'error-text';
  const title = escapeHtml(p.send_error || '');
  return `
    <div class="status-photo-card" data-photo-id="${p.photo_id}">
      <a href="${p.public_url}" target="_blank" rel="noopener">
        <img src="${p.public_url}" class="status-photo-thumb" alt="Status update photo" />
      </a>
      <button type="button" class="status-photo-remove-btn" data-photo-id="${p.photo_id}" title="Remove photo">&times;</button>
      <div class="status-photo-meta">
        <div>${escapeHtml(p.status || '')} - ${takenAt}</div>
        <div class="${sentClass}" title="${title}">${sentLabel}</div>
        <div class="muted">by ${escapeHtml(p.uploaded_by || '')}</div>
      </div>
    </div>
  `;
}

async function loadStatusPhotos() {
  const { data, error } = await supabaseClient.rpc('admin_list_online_order_status_photos', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });

  const section = document.getElementById('statusPhotosSection');
  if (error || !data || data.length === 0) {
    section.classList.add('hidden');
    return;
  }

  document.getElementById('statusPhotosList').innerHTML = data.map(statusPhotoCardHtml).join('');
  section.classList.remove('hidden');
}

async function handleRemoveStatusPhoto(photoId) {
  if (!confirm('Remove this photo? This cannot be undone.')) return;

  const { error } = await supabaseClient.rpc('admin_delete_online_order_status_photo', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_photo_id: photoId
  });

  if (error) {
    alert(`Could not remove photo: ${error.message}`);
    return;
  }

  await loadStatusPhotos();
}

async function loadOrderDetail() {
  const { data, error } = await supabaseClient.rpc('admin_get_online_order_detail_live', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: orderId
  });

  if (error) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = `Could not load order ${orderId}: ${error.message}`;
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('setupContent').classList.remove('hidden');

  currentLines = (data || []).filter((l) => l.line_id);
  renderOrderSummary(data);
  renderGlassFlag(currentLines);
  await Promise.all([loadAttachments(), loadStatusPhotos()]);
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Online Orders');

  const params = new URLSearchParams(window.location.search);
  orderId = params.get('order');

  if (!orderId) {
    document.getElementById('orderSummaryNote').textContent = 'No order specified.';
    document.getElementById('lineTableBody').innerHTML = '<tr><td colspan="11" class="error-text">Missing ?order= parameter.</td></tr>';
    return;
  }

  if (!session.password) {
    // Session was created before login started capturing the password (edge case for
    // anyone already logged in before this update) - a fresh login resolves it.
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Online Orders.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  wireAttachmentControls();
  document.getElementById('statusPhotosList').addEventListener('click', (event) => {
    const removeBtn = event.target.closest('.status-photo-remove-btn');
    if (removeBtn) handleRemoveStatusPhoto(removeBtn.dataset.photoId);
  });
  await loadOrderDetail();
})();
