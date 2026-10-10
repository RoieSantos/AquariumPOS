// Mandatory proof photo on Production Done / Release - per "can we mandatory ask them for picture once
// they clicked Production done? same goes to release/ship". Shared by Online Orders (js/onlineOrders.js
// confirmWithPhoto) and Production Orders (js/productionOrders.js setPartDone). Needs the page's
// supabaseClient + currentSession globals, and the dialog styles in css/bc-list.css (#proofPhotoDialog).
//
// confirmWithPhotoDialog: confirm dialog whose button stays disabled until a photo is taken; on confirm
// the photo is shrunk, uploaded (online-order-status-photos bucket, same as Send Photo) and recorded
// against refId with `label` (staff_record_online_order_proof_photo,
// sql/supabase_online_order_proof_photos.sql). Not sent to the customer. Resolves true only once the
// photo is saved; Cancel / Escape / backdrop -> false.

// PortalSettings PROOF_PHOTO_PRODUCTION_DONE / PROOF_PHOTO_RELEASE ('true' / 'false'), set on General
// Setup -> Online Orders - Proof Photos. Read on every click so a change applies without a reload.
// Not saved yet (or can't be read) -> required, the safe default.
async function proofPhotoRequired(kind) {
  const { data, error } = await supabaseClient.rpc('admin_get_public_portal_setting', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_setting_key: kind === 'production' ? 'PROOF_PHOTO_PRODUCTION_DONE' : 'PROOF_PHOTO_RELEASE'
  });
  if (error) console.warn('admin_get_public_portal_setting:', error.message);
  return !!error || String(data ?? '').trim().toLowerCase() !== 'false';
}

// The dialog markup, added once to whichever page uses it.
function ensureProofPhotoDialog() {
  if (document.getElementById('proofPhotoDialog')) return;
  document.body.insertAdjacentHTML('beforeend', `
  <div id="proofPhotoDialog" class="bc-dialog-backdrop hidden">
    <div class="bc-dialog bc-assign-dialog oo-confirm-dialog oo-proof-dialog" role="dialog" aria-modal="true" aria-labelledby="proofPhotoTitle">
      <div class="bc-dialog-head">
        <div>
          <div id="proofPhotoCaption" class="bc-doc-caption" style="font-size:11px; font-weight:600; letter-spacing:.06em; color:var(--text-muted);">PLEASE CONFIRM</div>
          <h2 id="proofPhotoTitle">Order</h2>
        </div>
      </div>
      <div class="bc-dialog-body">
        <p id="proofPhotoMessage" class="bc-lede"></p>
        <label class="oo-proof-pick" for="proofPhotoInput">
          <img id="proofPhotoPreview" class="hidden" alt="Proof photo preview" />
          <span id="proofPhotoPickText">&#128247; Take a photo (required)</span>
        </label>
        <input type="file" id="proofPhotoInput" accept="image/*" capture="environment" class="hidden" />
      </div>
      <div class="bc-dialog-foot oo-confirm-foot">
        <p id="proofPhotoError" class="bc-dialog-msg error-text hidden"></p>
        <button class="bc-btn" id="proofPhotoCancelBtn" type="button">Cancel</button>
        <button class="bc-btn bc-btn-primary" id="proofPhotoOkBtn" type="button" disabled>Confirm</button>
      </div>
    </div>
  </div>`);
}

// The last proof photo saved ({ refId, label, file }) - onlineOrders.js posts a Dispatcher's ship
// photo to Facebook from it (postShipPhotoToFacebook).
let lastProofPhoto = null;

// Signed upload, same flow as uploadOrderStatusPhoto in onlineOrders.js. Returns { url, storagePath }
// or { error }.
async function uploadProofPhoto(refId, file) {
  const { data, error } = await supabaseClient.rpc('admin_create_online_order_status_photo_upload', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_order_id: refId,
    p_file_name: file.name || 'photo.jpg'
  });
  if (error || !data || !data[0]) return { error: 'Could not prepare the photo upload: ' + (error ? error.message : 'unknown error') };
  const { storage_path, upload_token, public_url } = data[0];
  const { error: uploadError } = await supabaseClient.storage
    .from('online-order-status-photos')
    .uploadToSignedUrl(storage_path, upload_token, file);
  if (uploadError) return { error: 'Photo upload failed: ' + uploadError.message };
  return { url: public_url, storagePath: storage_path };
}

function confirmWithPhotoDialog({ caption, title, message, confirmLabel, tone = '', refId, label }) {
  ensureProofPhotoDialog();
  const dialog = document.getElementById('proofPhotoDialog');
  const panel = dialog.querySelector('.oo-proof-dialog');
  const okBtn = document.getElementById('proofPhotoOkBtn');
  const cancelBtn = document.getElementById('proofPhotoCancelBtn');
  const input = document.getElementById('proofPhotoInput');
  const pick = dialog.querySelector('.oo-proof-pick');
  const preview = document.getElementById('proofPhotoPreview');
  const pickText = document.getElementById('proofPhotoPickText');
  const errorEl = document.getElementById('proofPhotoError');
  const pickPrompt = '\u{1F4F7} Take a photo (required)';
  let file = null;
  let previewUrl = null;

  document.getElementById('proofPhotoCaption').textContent = caption;
  document.getElementById('proofPhotoTitle').textContent = title;
  document.getElementById('proofPhotoMessage').textContent = message;
  okBtn.textContent = confirmLabel;
  panel.classList.remove('is-done', 'is-ship', 'is-undo');
  if (tone) panel.classList.add(tone);
  input.value = '';
  preview.classList.add('hidden');
  preview.removeAttribute('src');
  pick.classList.remove('has-photo');
  pickText.textContent = pickPrompt;
  errorEl.classList.add('hidden');

  return new Promise((resolve) => {
    let busy = false;
    const finish = (answer) => {
      dialog.classList.add('hidden');
      okBtn.removeEventListener('click', onOk);
      cancelBtn.removeEventListener('click', onCancel);
      dialog.removeEventListener('click', onBackdrop);
      input.removeEventListener('change', onPick);
      document.removeEventListener('keydown', onKey, true);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      resolve(answer);
    };
    const onPick = () => {
      file = input.files && input.files[0] || null;
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      previewUrl = file ? URL.createObjectURL(file) : null;
      preview.classList.toggle('hidden', !file);
      if (file) preview.src = previewUrl;
      pick.classList.toggle('has-photo', !!file);
      pickText.textContent = file ? 'Tap to retake' : pickPrompt;
      errorEl.classList.add('hidden');
      okBtn.disabled = !file;
    };
    const onOk = async () => {
      if (!file || busy) return;
      busy = true;
      okBtn.disabled = cancelBtn.disabled = true;
      okBtn.textContent = 'Saving photo...';
      const fail = (msg) => {
        errorEl.textContent = msg;
        errorEl.classList.remove('hidden');
        okBtn.textContent = confirmLabel;
        okBtn.disabled = cancelBtn.disabled = false;
        busy = false;
      };
      // Shrunk to a JPEG first: the bucket takes at most 10 MB and only JPEG/PNG/WebP, and some phones
      // shoot 15+ MB or HEIC. If the browser can't read it, try the original.
      const upload = await shrinkProofPhoto(file).catch(() => file);
      const photo = await uploadProofPhoto(String(refId), upload);
      if (photo.error) return fail(photo.error);
      const { error } = await supabaseClient.rpc('staff_record_online_order_proof_photo', {
        p_admin_username: currentSession.username,
        p_admin_password: currentSession.password,
        p_ref_id: String(refId),
        p_label: label,
        p_photo_url: photo.url,
        p_photo_storage_path: photo.storagePath
      });
      if (error) return fail(`Could not save the photo: ${error.message}`);
      lastProofPhoto = { refId: String(refId), label, file: upload };
      okBtn.textContent = confirmLabel;
      cancelBtn.disabled = false;
      finish(true);
    };
    const onCancel = () => { if (!busy) finish(false); };
    const onBackdrop = (e) => { if (e.target === dialog && !busy) finish(false); };
    const onKey = (e) => {
      if (e.key === 'Escape') { e.stopImmediatePropagation(); if (!busy) finish(false); }
    };
    okBtn.addEventListener('click', onOk);
    cancelBtn.addEventListener('click', onCancel);
    dialog.addEventListener('click', onBackdrop);
    input.addEventListener('change', onPick);
    document.addEventListener('keydown', onKey, true);

    okBtn.disabled = true;
    cancelBtn.disabled = false;
    dialog.classList.remove('hidden');
    cancelBtn.focus();
  });
}

// At most 1600px on the long side, re-encoded as JPEG - same idea as compressImage in defectItems.js.
function shrinkProofPhoto(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, 1600 / Math.max(img.width, img.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      URL.revokeObjectURL(url);
      canvas.toBlob((blob) => (blob
        ? resolve(new File([blob], 'proof.jpg', { type: 'image/jpeg' }))
        : reject(new Error('Could not process the photo.'))), 'image/jpeg', 0.82);
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('That file is not a readable image.')); };
    img.src = url;
  });
}

// Added at load, not on first use - onlineOrders.js checks #proofPhotoDialog when Escape is pressed.
if (document.body) ensureProofPhotoDialog();
else document.addEventListener('DOMContentLoaded', ensureProofPhotoDialog);
