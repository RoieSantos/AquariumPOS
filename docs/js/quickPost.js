// Quick Post page logic (super users only) - the phone version of facebook-post-test.html:
// take/choose a photo -> it is watermarked with the saved defaults and Claude writes the caption
// straight away (both from AI Bot Setup > Facebook Posts) -> one tap on Post Now publishes it to
// the GMA Page. The caption stays editable and Post Now stays a deliberate tap, so an AI caption
// that misreads the photo never goes live unseen. Shared drawing/function call in
// js/facebookPostShared.js.
let currentSession = null;
let settings = null;
// Downscaled + watermarked JPEG, base64 without the data: prefix.
let photoBase64 = null;
// Bumped per photo so a slow caption for an old photo can't overwrite the new one's.
let captionRequestId = 0;

function showStep(step) {
  ['qpPickStep', 'qpReviewStep', 'qpDoneStep'].forEach((id) => {
    document.getElementById(id).classList.toggle('hidden', id !== step);
  });
}

function showError(message) {
  const errorEl = document.getElementById('qpError');
  errorEl.textContent = message;
  errorEl.classList.toggle('hidden', !message);
}

function setStatus(text) {
  document.getElementById('qpStatus').textContent = text;
}

async function onPhotoPicked(e) {
  const file = e.target.files && e.target.files[0];
  // Reset so picking the same file again still fires change.
  e.target.value = '';
  if (!file) return;
  showError('');

  const objectUrl = URL.createObjectURL(file);
  try {
    const sourceImg = await loadImage(objectUrl, false);
    const dataUrl = renderWatermarkedPhoto(sourceImg, watermarkOptionsFromSettings(settings));
    photoBase64 = dataUrl.split(',')[1];
    document.getElementById('qpPreview').src = dataUrl;
  } catch (err) {
    showError(err.message);
    return;
  } finally {
    URL.revokeObjectURL(objectUrl);
  }

  document.getElementById('qpCaption').value = '';
  document.getElementById('qpNotes').value = '';
  showStep('qpReviewStep');
  window.scrollTo(0, 0);
  await writeCaption();
}

async function writeCaption() {
  const requestId = ++captionRequestId;
  const postBtn = document.getElementById('qpPostBtn');
  const rewriteBtn = document.getElementById('qpRewriteBtn');
  postBtn.disabled = true;
  rewriteBtn.disabled = true;
  setStatus('✍️ Writing caption...');
  showError('');

  try {
    const result = await callFacebookPostFunction(currentSession, photoBase64, {
      action: 'caption',
      notes: document.getElementById('qpNotes').value.trim()
    });
    if (requestId !== captionRequestId) return;
    document.getElementById('qpCaption').value = result.caption || '';
    // The angle comes from the poster's role/branch (see posterAngle in facebook-page-post).
    const writtenAs = [result.angle, result.branch].filter(Boolean).join(' · ');
    setStatus(`${writtenAs ? `Written as: ${writtenAs}. ` : ''}Check the caption, then tap Post Now.`);
  } catch (err) {
    if (requestId !== captionRequestId) return;
    setStatus('');
    showError(`${err.message} You can type a caption yourself.`);
  } finally {
    if (requestId === captionRequestId) {
      postBtn.disabled = false;
      rewriteBtn.disabled = false;
    }
  }
}

async function postNow() {
  const caption = document.getElementById('qpCaption').value.trim();
  if (!caption) {
    showError('Add a caption first.');
    return;
  }

  const btn = document.getElementById('qpPostBtn');
  btn.disabled = true;
  btn.textContent = 'Posting...';
  showError('');
  try {
    const result = await callFacebookPostFunction(currentSession, photoBase64, { action: 'post', caption });
    const resultEl = document.getElementById('qpResult');
    resultEl.textContent = '✅ Posted to the GMA Page! ';
    if (result.post_url) {
      const link = document.createElement('a');
      link.href = result.post_url;
      link.target = '_blank';
      link.rel = 'noopener';
      link.textContent = 'View it on Facebook';
      resultEl.appendChild(link);
    }
    photoBase64 = null;
    showStep('qpDoneStep');
  } catch (err) {
    showError(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Post Now';
  }
}

function startOver() {
  captionRequestId++;
  photoBase64 = null;
  showError('');
  setStatus('');
  showStep('qpPickStep');
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Quick Post');

  // Super users only - the Delivery Team posts from Mark Done on the Delivery route view instead.
  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to use Quick Post.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  // Settings + logo must be ready before the first photo is watermarked.
  [settings] = await Promise.all([loadFacebookPostSettings(), loadCompanyLogo()]);

  document.getElementById('qpContent').classList.remove('hidden');
  document.getElementById('qpCameraInput').addEventListener('change', onPhotoPicked);
  document.getElementById('qpGalleryInput').addEventListener('change', onPhotoPicked);
  document.getElementById('qpRewriteBtn').addEventListener('click', writeCaption);
  document.getElementById('qpRetakeBtn').addEventListener('click', startOver);
  document.getElementById('qpPostBtn').addEventListener('click', postNow);
  document.getElementById('qpAnotherBtn').addEventListener('click', startOver);
})();
