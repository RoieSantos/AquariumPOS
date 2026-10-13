// Shrinks a video in the browser before it's uploaded - per "make it smaller if possible and viewable"
// (Online Order line attachments, js/onlineOrders.js uploadOrderCardAttachment). The clip is played
// into a canvas at most 1280px on its long side (720p) and re-recorded with MediaRecorder at about
// 1.2 Mbit/s: MP4 (H.264) where the browser can record it - plays everywhere - else WebM. It runs in
// real time (a 1-minute clip takes about a minute). Returns null when the browser can't compress, so
// the caller can fall back to the original file.
const VIDEO_MAX_SECONDS = 120;
const VIDEO_MAX_LONG_SIDE = 1280;
const VIDEO_BITS_PER_SECOND = 1200000;

function isVideoFile(file) {
  return /^video\//.test(file?.type || '') || /\.(mp4|m4v|mov|webm)$/i.test(file?.name || '');
}

function isVideoFileName(name) {
  return /\.(mp4|m4v|mov|webm)$/i.test(name || '');
}

function pickVideoRecorderType(withAudio) {
  if (typeof MediaRecorder === 'undefined' || !MediaRecorder.isTypeSupported) return null;
  const types = withAudio
    ? ['video/mp4;codecs=avc1.42E01E,mp4a.40.2', 'video/mp4;codecs=avc1,mp4a', 'video/mp4', 'video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm']
    : ['video/mp4;codecs=avc1.42E01E', 'video/mp4;codecs=avc1', 'video/mp4', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
  return types.find((t) => MediaRecorder.isTypeSupported(t)) || null;
}

// onProgress(0..1). Throws (with a message for the user) when the clip is too long.
async function compressVideoFile(file, onProgress = () => {}) {
  if (typeof MediaRecorder === 'undefined' || !HTMLCanvasElement.prototype.captureStream) return null;

  const url = URL.createObjectURL(file);
  const video = document.createElement('video');
  video.muted = true;
  video.playsInline = true;
  video.preload = 'auto';
  video.src = url;
  try {
    await new Promise((resolve, reject) => {
      video.onloadedmetadata = resolve;
      video.onerror = () => reject(new Error('unreadable'));
    });
  } catch {
    URL.revokeObjectURL(url);
    return null; // a format this browser can't decode - upload the original
  }

  const duration = Number.isFinite(video.duration) ? video.duration : 0;
  if (duration > VIDEO_MAX_SECONDS) {
    URL.revokeObjectURL(url);
    throw new Error(`That video is ${Math.round(duration)} seconds long - please keep it under ${VIDEO_MAX_SECONDS / 60} minutes.`);
  }

  const w = video.videoWidth || 1280;
  const h = video.videoHeight || 720;
  const scale = Math.min(1, VIDEO_MAX_LONG_SIDE / Math.max(w, h));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(2, Math.round((w * scale) / 2) * 2);
  canvas.height = Math.max(2, Math.round((h * scale) / 2) * 2);
  const ctx = canvas.getContext('2d');
  const stream = canvas.captureStream(30);

  // The clip's sound, where the browser lets us tap it (Chrome / Edge / Firefox); otherwise silent.
  try {
    const src = video.captureStream ? video.captureStream() : video.mozCaptureStream ? video.mozCaptureStream() : null;
    src?.getAudioTracks().forEach((t) => stream.addTrack(t));
  } catch { /* video only */ }

  let type = stream.getAudioTracks().length ? pickVideoRecorderType(true) : null;
  if (!type) {
    // No recordable audio format - keep the picture only.
    stream.getAudioTracks().forEach((t) => stream.removeTrack(t));
    type = pickVideoRecorderType(false);
  }
  if (!type) {
    URL.revokeObjectURL(url);
    return null;
  }

  const chunks = [];
  const recorder = new MediaRecorder(stream, { mimeType: type, videoBitsPerSecond: VIDEO_BITS_PER_SECOND, audioBitsPerSecond: 64000 });
  recorder.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };

  const done = new Promise((resolve, reject) => {
    recorder.onstop = resolve;
    recorder.onerror = (e) => reject(e.error || new Error('Recording failed.'));
  });

  let drawing = true;
  const draw = () => {
    if (!drawing) return;
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    if (duration) onProgress(Math.min(1, video.currentTime / duration));
    if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(draw);
    else requestAnimationFrame(draw);
  };

  try {
    recorder.start(1000);
    await video.play();
    draw();
    await new Promise((resolve) => { video.onended = resolve; });
    drawing = false;
    recorder.stop();
    await done;
  } catch {
    drawing = false;
    if (recorder.state !== 'inactive') recorder.stop();
    return null;
  } finally {
    video.pause();
    stream.getTracks().forEach((t) => t.stop());
    URL.revokeObjectURL(url);
  }

  const baseType = type.split(';')[0];
  const blob = new Blob(chunks, { type: baseType });
  if (!blob.size) return null;
  const baseName = (file.name || 'video').replace(/\.[^.]+$/, '');
  onProgress(1);
  return new File([blob], `${baseName}.${baseType === 'video/mp4' ? 'mp4' : 'webm'}`, { type: baseType });
}
