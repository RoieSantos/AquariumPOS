// Video Ad Builder voice-over (video-ad-builder.html) - turns one scene's voice-over line into speech
// with Google Cloud Text-to-Speech, saves the MP3 in the video-ad-media bucket and returns its URL.
// The page mixes the clips into the ad's soundtrack (js/videoAdMusic.js) - the browser's own voices
// can't be recorded into an exported MP4, so the speech has to come from a service.
//
//   POST { admin_username, admin_password, text, voice, rate, preview? }
//   ->   { url }                 (saved clip)
//   ->   { audio_base64 }        (preview: true - "Try this voice", nothing saved)
//
// voice = a Google voice name from VOICES in js/videoAdBuilder.js, e.g. "fil-PH-Wavenet-A".
//
// Super users only (is_admin_authorized), like the page. Secret: GOOGLE_TTS_API_KEY (a Google Cloud API
// key with the Cloud Text-to-Speech API enabled).
//
// Deploy: supabase functions deploy video-ad-voice --project-ref hymcmesqgpliyyeghpgq

import { createClient } from 'npm:@supabase/supabase-js@2';

const MEDIA_BUCKET = 'video-ad-media';
const MAX_CHARS = 400;
const VOICE_NAME = /^(fil-PH|en-US|en-GB|en-AU|en-IN)-(Standard|Wavenet|Neural2)-[A-Z]$/;

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const googleKey = Deno.env.get('GOOGLE_TTS_API_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'video-ad-voice is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.' }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Body must be JSON.' }, 400);
  }

  const adminUsername = String(body.admin_username ?? '');
  const adminPassword = String(body.admin_password ?? '');
  const text = String(body.text ?? '').trim();
  const voice = String(body.voice ?? '');
  const rate = Math.min(1.5, Math.max(0.7, Number(body.rate) || 1));
  const preview = body.preview === true;
  if (!adminUsername || !adminPassword) return jsonResponse({ error: 'Missing admin_username / admin_password.' }, 400);
  if (!text) return jsonResponse({ error: 'Nothing to say - write the voice-over line first.' }, 400);
  if (text.length > MAX_CHARS) return jsonResponse({ error: `Keep each voice-over line under ${MAX_CHARS} characters.` }, 400);
  if (!VOICE_NAME.test(voice)) return jsonResponse({ error: 'Unknown voice.' }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = await supabase.rpc('is_admin_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || !authorized) return jsonResponse({ error: 'Not authorized.' }, 401);
  if (!googleKey) return jsonResponse({ error: 'Voice-over is not set up yet - add the GOOGLE_TTS_API_KEY secret in Supabase.' }, 500);

  const languageCode = voice.split('-').slice(0, 2).join('-');
  const res = await fetch(`https://texttospeech.googleapis.com/v1/text:synthesize?key=${encodeURIComponent(googleKey)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      input: { text },
      voice: { languageCode, name: voice },
      audioConfig: { audioEncoding: 'MP3', speakingRate: rate, sampleRateHertz: 48000 }
    })
  });
  const result = await res.json().catch(() => ({}));
  if (!res.ok || !result.audioContent) {
    const message = result?.error?.message || `HTTP ${res.status}`;
    return jsonResponse({ error: `Google voice failed: ${message}` }, 502);
  }
  if (preview) return jsonResponse({ audio_base64: result.audioContent });

  const bytes = Uint8Array.from(atob(result.audioContent), (c) => c.charCodeAt(0));
  const now = new Date();
  const path = `${now.toISOString().slice(0, 7)}/voice_${now.getTime()}_${Math.random().toString(36).slice(2, 8)}.mp3`;
  const { error } = await supabase.storage.from(MEDIA_BUCKET).upload(path, bytes, { contentType: 'audio/mpeg' });
  if (error) return jsonResponse({ error: `Could not save the voice-over: ${error.message}` }, 500);
  return jsonResponse({ url: supabase.storage.from(MEDIA_BUCKET).getPublicUrl(path).data.publicUrl });
});
