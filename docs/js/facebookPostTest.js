// Facebook Post Test page logic (super users only) - PROTOTYPE for automated Facebook Page
// posting, via the facebook-page-post Edge Function (supabase/functions/facebook-page-post).
// Upload a photo -> Claude writes a caption -> staff edit it -> post to the GMA Page now, or
// schedule it (the safe way to test: scheduled posts wait in Meta Business Suite > Planner).
let currentSession = null;
// The photo as sent to the function: downscaled + watermarked JPEG, base64 without the data: prefix.
let photoBase64 = null;
// The decoded original photo, kept so changing a watermark option re-renders from the clean image.
let sourceImg = null;

function showError(message) {
  const errorEl = document.getElementById('fbErrorEl');
  errorEl.textContent = message;
  errorEl.classList.remove('hidden');
}

function clearMessages() {
  document.getElementById('fbErrorEl').classList.add('hidden');
  document.getElementById('fbResultEl').classList.add('hidden');
}

function getWatermarkOptions() {
  return {
    enabled: document.getElementById('fbWatermarkOn').checked,
    style: document.getElementById('fbWatermarkStyle').value,
    text: document.getElementById('fbWatermarkText').value.trim(),
    position: document.getElementById('fbWatermarkPosition').value,
    size: Number(document.getElementById('fbWatermarkSize').value) / 100,
    opacity: Number(document.getElementById('fbWatermarkOpacity').value) / 100,
    knockout: document.getElementById('fbWatermarkKnockout').checked
  };
}

// Watermark drawing lives in js/facebookPostShared.js.
function renderPhoto() {
  if (!sourceImg) return;
  const dataUrl = renderWatermarkedPhoto(sourceImg, getWatermarkOptions());
  photoBase64 = dataUrl.split(',')[1];
  const preview = document.getElementById('fbPhotoPreview');
  preview.src = dataUrl;
  preview.classList.remove('hidden');
}

function callPostFunction(payload) {
  return callFacebookPostFunction(currentSession, photoBase64, payload);
}

async function onPhotoSelected(e) {
  clearMessages();
  const file = e.target.files && e.target.files[0];
  photoBase64 = null;
  sourceImg = null;
  document.getElementById('fbPhotoPreview').classList.add('hidden');
  if (!file) return;

  const objectUrl = URL.createObjectURL(file);
  try {
    sourceImg = await loadImage(objectUrl, false);
    renderPhoto();
  } catch (err) {
    showError(err.message);
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}

async function writeCaption() {
  clearMessages();
  if (!photoBase64) {
    showError('Choose a photo first.');
    return;
  }

  const btn = document.getElementById('fbCaptionBtn');
  btn.disabled = true;
  btn.textContent = 'Writing...';
  try {
    const result = await callPostFunction({
      action: 'caption',
      notes: document.getElementById('fbNotesInput').value.trim()
    });
    document.getElementById('fbCaptionInput').value = result.caption || '';
    // The angle comes from the poster's role/branch (see posterAngle in facebook-page-post).
    const writtenAs = [result.angle, result.branch].filter(Boolean).join(' · ');
    document.getElementById('fbWrittenAs').textContent = writtenAs ? `Written as: ${writtenAs}` : '';
  } catch (err) {
    showError(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Write Caption with AI';
  }
}

async function postToFacebook() {
  clearMessages();
  const caption = document.getElementById('fbCaptionInput').value.trim();
  if (!photoBase64) {
    showError('Choose a photo first.');
    return;
  }
  if (!caption) {
    showError('Write a caption first.');
    return;
  }

  const mode = document.querySelector('input[name="fbMode"]:checked').value;
  let scheduledAtUnix = null;
  if (mode === 'schedule') {
    const value = document.getElementById('fbScheduleInput').value;
    if (!value) {
      showError('Pick a date and time to schedule the post.');
      return;
    }
    scheduledAtUnix = Math.floor(new Date(value).getTime() / 1000);
  } else if (!confirm('Publish this post on the GMA Facebook Page right now? Everyone following the Page will see it.')) {
    return;
  }

  const btn = document.getElementById('fbPostBtn');
  btn.disabled = true;
  btn.textContent = 'Posting...';
  try {
    const result = await callPostFunction({ action: 'post', caption, scheduled_at_unix: scheduledAtUnix });
    const resultEl = document.getElementById('fbResultEl');
    if (result.scheduled) {
      resultEl.textContent = `Scheduled for ${new Date(scheduledAtUnix * 1000).toLocaleString()}. Check it in Meta Business Suite > Planner (photo id ${result.photo_id}).`;
    } else {
      resultEl.innerHTML = 'Posted! ';
      if (result.post_url) {
        const link = document.createElement('a');
        link.href = result.post_url;
        link.target = '_blank';
        link.rel = 'noopener';
        link.textContent = 'View the post on Facebook';
        resultEl.appendChild(link);
      }
    }
    resultEl.classList.remove('hidden');
  } catch (err) {
    showError(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Post to Facebook';
  }
}

// Saved defaults (js/facebookPostSettings.js), kept so Save as Default can write the watermark
// back without touching the caption directions that live in AI Bot Setup.
let savedSettings = null;

function applyWatermarkSettings(s) {
  document.getElementById('fbWatermarkOn').checked = s.watermarkEnabled;
  document.getElementById('fbWatermarkStyle').value = s.watermarkStyle;
  document.getElementById('fbWatermarkPosition').value = s.watermarkPosition;
  document.getElementById('fbWatermarkPosition').classList.toggle('hidden', s.watermarkStyle !== 'badge');
  document.getElementById('fbWatermarkSize').value = s.watermarkSize;
  document.getElementById('fbWatermarkOpacity').value = s.watermarkOpacity;
  document.getElementById('fbWatermarkKnockout').checked = s.watermarkKnockout;
  document.getElementById('fbWatermarkText').value = s.watermarkText;
}

async function saveWatermarkAsDefault() {
  const btn = document.getElementById('fbSaveDefaultBtn');
  const msgEl = document.getElementById('fbSaveDefaultMsg');
  // Not loaded yet - saving now would blank the caption directions.
  if (!savedSettings) return;
  const o = getWatermarkOptions();
  btn.disabled = true;
  msgEl.textContent = '';
  try {
    const settings = {
      ...savedSettings,
      watermarkEnabled: o.enabled,
      watermarkStyle: o.style,
      watermarkPosition: o.position,
      watermarkSize: Math.round(o.size * 100),
      watermarkOpacity: Math.round(o.opacity * 100),
      watermarkKnockout: o.knockout,
      watermarkText: o.text
    };
    const message = await saveFacebookPostSettings(currentSession, settings);
    if (message) {
      showError(message);
      return;
    }
    savedSettings = settings;
    msgEl.textContent = 'Saved.';
  } finally {
    btn.disabled = false;
  }
}

function toLocalInputValue(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Facebook Post Test');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to use Facebook Post Test.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  // Default the schedule to tomorrow 9:00 AM - far enough out to review/delete it in Planner.
  const tomorrow = new Date();
  tomorrow.setDate(tomorrow.getDate() + 1);
  tomorrow.setHours(9, 0, 0, 0);
  document.getElementById('fbScheduleInput').value = toLocalInputValue(tomorrow);

  document.querySelectorAll('input[name="fbMode"]').forEach((radio) => {
    radio.addEventListener('change', () => {
      const isSchedule = document.querySelector('input[name="fbMode"]:checked').value === 'schedule';
      document.getElementById('fbScheduleRow').classList.toggle('hidden', !isSchedule);
    });
  });

  document.getElementById('fbPostContent').classList.remove('hidden');
  document.getElementById('fbPhotoInput').addEventListener('change', onPhotoSelected);
  ['fbWatermarkOn', 'fbWatermarkPosition', 'fbWatermarkKnockout'].forEach((id) => document.getElementById(id).addEventListener('change', renderPhoto));
  // Sliders fire many input events per second; redraw at most once per frame.
  let renderQueued = false;
  const queueRender = () => {
    if (renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(() => { renderQueued = false; renderPhoto(); });
  };
  ['fbWatermarkText', 'fbWatermarkSize', 'fbWatermarkOpacity'].forEach((id) => document.getElementById(id).addEventListener('input', queueRender));
  document.getElementById('fbWatermarkStyle').addEventListener('change', () => {
    // Corner position only applies to the small badge.
    document.getElementById('fbWatermarkPosition').classList.toggle('hidden', document.getElementById('fbWatermarkStyle').value !== 'badge');
    renderPhoto();
  });
  document.getElementById('fbSaveDefaultBtn').addEventListener('click', saveWatermarkAsDefault);
  loadFacebookPostSettings().then((s) => {
    savedSettings = s;
    applyWatermarkSettings(s);
    renderPhoto();
  });
  loadCompanyLogo().then(renderPhoto);
  document.getElementById('fbCaptionBtn').addEventListener('click', writeCaption);
  document.getElementById('fbPostBtn').addEventListener('click', postToFacebook);
})();
