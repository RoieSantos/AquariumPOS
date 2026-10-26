// Video Ad Builder background music (video-ad-builder.html). Two sources:
//   - built-in tracks ('upbeat', 'chill', 'ocean'), synthesised here with an OfflineAudioContext at
//     exactly the ad's length - nothing to license, so Facebook/Instagram have no reason to mute them;
//   - a song the staff upload (any format the browser decodes), started at music.start seconds.
// buildTrack() returns the finished soundtrack (volume, fade-in/out, looped if the song is shorter
// than the ad) as one 48 kHz stereo AudioBuffer - used for the preview and muxed into the MP4 by
// js/videoAdRenderer.js.
//
// music (saved in the ad config): { track: 'none'|'upbeat'|'chill'|'ocean'|'custom', src, name, start, volume }
//
// Voice-over clips (Google voices, made by supabase/functions/video-ad-voice) are mixed in on top at
// their scene's start, and the music dips under them.
window.VideoAdMusic = (function () {
  const SR = 48000;
  const MOODS = [
    { key: 'upbeat', label: '🎉 Upbeat' },
    { key: 'chill', label: '🌴 Chill' },
    { key: 'ocean', label: '🌊 Ocean calm' }
  ];
  const cache = new Map();

  const midiHz = (m) => 440 * Math.pow(2, (m - 69) / 12);
  function seeded(seed) {
    let a = seed >>> 0;
    return () => {
      a = (a + 0x6d2b79f5) >>> 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // ---------- instruments (all schedule onto an OfflineAudioContext) ----------
  function makeNoise(ctx, rnd) {
    const buf = ctx.createBuffer(1, SR, SR);
    const d = buf.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = rnd() * 2 - 1;
    return buf;
  }
  function makeReverb(ctx, rnd) {
    const len = Math.round(SR * 2.2);
    const buf = ctx.createBuffer(2, len, SR);
    for (let c = 0; c < 2; c++) {
      const d = buf.getChannelData(c);
      for (let i = 0; i < len; i++) d[i] = (rnd() * 2 - 1) * Math.pow(1 - i / len, 3);
    }
    const conv = ctx.createConvolver();
    conv.buffer = buf;
    return conv;
  }
  function env(ctx, t, attack, hold, release, peak) {
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(peak, t + attack);
    g.gain.setValueAtTime(peak, t + attack + hold);
    g.gain.exponentialRampToValueAtTime(0.0001, t + attack + hold + release);
    return g;
  }
  function pad(ctx, out, t, dur, notes, vol) {
    const lp = ctx.createBiquadFilter();
    lp.type = 'lowpass'; lp.frequency.value = 1100; lp.Q.value = 0.3;
    const g = env(ctx, t, 0.5, Math.max(0, dur - 0.5), 0.9, vol);
    lp.connect(g); g.connect(out);
    for (const m of notes) {
      for (const detune of [-7, 7]) {
        const o = ctx.createOscillator();
        o.type = 'sawtooth'; o.frequency.value = midiHz(m); o.detune.value = detune;
        o.connect(lp); o.start(t); o.stop(t + dur + 1);
      }
    }
  }
  function pluck(ctx, out, t, m, vol, decay, wave = 'triangle') {
    const g = env(ctx, t, 0.005, 0, decay, vol);
    g.connect(out);
    const o = ctx.createOscillator();
    o.type = wave; o.frequency.value = midiHz(m);
    const o2 = ctx.createOscillator();
    o2.type = 'sine'; o2.frequency.value = midiHz(m + 12);
    const g2 = ctx.createGain(); g2.gain.value = 0.3;
    o.connect(g); o2.connect(g2); g2.connect(g);
    o.start(t); o2.start(t); o.stop(t + decay + 0.05); o2.stop(t + decay + 0.05);
  }
  function bass(ctx, out, t, m, dur, vol) {
    const lp = ctx.createBiquadFilter();
    lp.type = 'lowpass'; lp.frequency.value = 420;
    const g = env(ctx, t, 0.01, dur * 0.6, dur * 0.4, vol);
    lp.connect(g); g.connect(out);
    for (const type of ['sine', 'triangle']) {
      const o = ctx.createOscillator();
      o.type = type; o.frequency.value = midiHz(m);
      o.connect(lp); o.start(t); o.stop(t + dur + 0.05);
    }
  }
  function kick(ctx, out, t, vol) {
    const o = ctx.createOscillator();
    o.frequency.setValueAtTime(150, t);
    o.frequency.exponentialRampToValueAtTime(45, t + 0.12);
    const g = env(ctx, t, 0.002, 0.02, 0.3, vol);
    o.connect(g); g.connect(out); o.start(t); o.stop(t + 0.4);
  }
  function noiseHit(ctx, out, noise, t, type, freq, decay, vol) {
    const s = ctx.createBufferSource();
    s.buffer = noise;
    const f = ctx.createBiquadFilter();
    f.type = type; f.frequency.value = freq;
    const g = env(ctx, t, 0.002, 0, decay, vol);
    s.connect(f); f.connect(g); g.connect(out);
    s.start(t, (t * 7.3) % 0.5); s.stop(t + decay + 0.05);
  }
  function bubble(ctx, out, t, vol, base) {
    const o = ctx.createOscillator();
    o.type = 'sine';
    o.frequency.setValueAtTime(base, t);
    o.frequency.exponentialRampToValueAtTime(base * 2.2, t + 0.07);
    const g = env(ctx, t, 0.003, 0.02, 0.06, vol);
    o.connect(g); g.connect(out); o.start(t); o.stop(t + 0.12);
  }
  function swell(ctx, out, noise, t, dur, vol) {
    const s = ctx.createBufferSource();
    s.buffer = noise; s.loop = true;
    const f = ctx.createBiquadFilter();
    f.type = 'lowpass'; f.frequency.value = 450;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(vol, t + dur * 0.45);
    g.gain.linearRampToValueAtTime(0.0001, t + dur);
    s.connect(f); f.connect(g); g.connect(out);
    s.start(t); s.stop(t + dur);
  }

  // ---------- the three tracks ----------
  const SONGS = {
    upbeat: {
      bpm: 112,
      chords: [[60, 64, 67], [59, 62, 67], [57, 60, 64], [57, 60, 65]], // C G Am F
      roots: [36, 43, 45, 41],
      play(ctx, bus, rev, noise, rnd, beat, bars) {
        bars.forEach(({ t, chord, root, bar }) => {
          pad(ctx, rev, t, beat * 4, chord, 0.035);
          const arp = [0, 1, 2, 1, 0, 1, 2, 1].map((i, k) => chord[i] + (k >= 4 ? 12 : 0));
          arp.forEach((m, k) => pluck(ctx, bus, t + k * beat / 2, m + 12, 0.09, 0.28));
          for (let b = 0; b < 4; b++) {
            const bt = t + b * beat;
            bass(ctx, bus, bt, root, beat * 0.45, 0.22);
            bass(ctx, bus, bt + beat / 2, root + 12, beat * 0.3, 0.12);
            if (bar > 0 || b >= 2) kick(ctx, bus, bt, 0.7);
            noiseHit(ctx, bus, noise, bt + beat / 2, 'highpass', 7500, 0.05, 0.12);
            if (b % 2 === 1) noiseHit(ctx, rev, noise, bt, 'bandpass', 1600, 0.16, 0.25);
          }
        });
      }
    },
    chill: {
      bpm: 84,
      chords: [[60, 64, 67, 71], [57, 60, 64, 67], [57, 62, 65, 69], [55, 60, 62, 67]], // Cmaj7 Am7 Dm7 G7sus
      roots: [36, 45, 38, 43],
      play(ctx, bus, rev, noise, rnd, beat, bars) {
        bars.forEach(({ t, chord, root }) => {
          pad(ctx, rev, t, beat * 4, chord, 0.04);
          [0, 2, 1, 3, 2, 1].forEach((i, k) => pluck(ctx, rev, t + k * beat * 2 / 3, chord[i] + 12, 0.07, 0.6, 'sine'));
          bass(ctx, bus, t, root, beat * 1.8, 0.22);
          bass(ctx, bus, t + beat * 2.5, root, beat * 1.2, 0.16);
          kick(ctx, bus, t, 0.45);
          kick(ctx, bus, t + beat * 2.5, 0.35);
          for (let s = 0; s < 8; s++) noiseHit(ctx, bus, noise, t + s * beat / 2, 'highpass', 5500, 0.07, s % 2 ? 0.05 : 0.08);
        });
      }
    },
    ocean: {
      bpm: 70,
      chords: [[53, 57, 60, 64], [52, 55, 60, 64], [50, 57, 60, 64], [55, 59, 62, 67]], // Fmaj7 C/E Dm9 G
      roots: [41, 40, 38, 43],
      play(ctx, bus, rev, noise, rnd, beat, bars, seconds) {
        const pent = [72, 74, 76, 79, 81, 84];
        bars.forEach(({ t, chord, root }) => {
          pad(ctx, rev, t, beat * 4, chord, 0.05);
          bass(ctx, bus, t, root, beat * 3.5, 0.12);
          for (let b = 0; b < 4; b += 2) {
            if (rnd() < 0.8) pluck(ctx, rev, t + b * beat + rnd() * 0.1, pent[Math.floor(rnd() * pent.length)], 0.06, 1.4, 'sine');
          }
        });
        for (let w = 0; w < seconds; w += 6) swell(ctx, rev, noise, w, 6.5, 0.05);
        for (let b = 0.4; b < seconds; b += 0.35 + rnd() * 1.1) bubble(ctx, rev, b, 0.04, 500 + rnd() * 700);
      }
    }
  };

  async function renderSong(key, seconds) {
    const song = SONGS[key];
    const len = Math.ceil(seconds) + 1;
    const ctx = new OfflineAudioContext(2, len * SR, SR);
    const rnd = seeded(key.length * 7919 + 17);
    const master = ctx.createDynamicsCompressor();
    master.threshold.value = -14; master.ratio.value = 3;
    master.connect(ctx.destination);
    const bus = ctx.createGain(); bus.gain.value = 0.9; bus.connect(master);
    const reverb = makeReverb(ctx, rnd);
    const wet = ctx.createGain(); wet.gain.value = 0.35;
    reverb.connect(wet); wet.connect(master);
    // Anything sent to "rev" is heard dry and through the reverb.
    const rev = ctx.createGain(); rev.connect(bus); rev.connect(reverb);
    const noise = makeNoise(ctx, rnd);

    const beat = 60 / song.bpm;
    const bars = [];
    for (let bar = 0, t = 0; t < len; bar++, t += beat * 4) {
      const i = bar % song.chords.length;
      bars.push({ t, bar, chord: song.chords[i], root: song.roots[i] });
    }
    song.play(ctx, bus, rev, noise, rnd, beat, bars, len);
    return ctx.startRendering();
  }

  async function decodeUrl(url) {
    const res = await fetch(url);
    if (!res.ok) throw new Error('Could not load the audio (' + res.status + ').');
    const data = await res.arrayBuffer();
    // An OfflineAudioContext at 48 kHz resamples the song to the video's audio rate while decoding.
    return new OfflineAudioContext(2, 1, SR).decodeAudioData(data);
  }

  function decodeCached(url) {
    const k = 'url:' + url;
    if (!cache.has(k)) cache.set(k, decodeUrl(url).catch((e) => { cache.delete(k); throw e; }));
    return cache.get(k);
  }

  // Length of a voice clip in seconds.
  async function clipSeconds(url) {
    return (await decodeCached(url)).duration;
  }

  function sourceFor(music, seconds) {
    if (!music || !music.track || music.track === 'none') return null;
    if (music.track === 'custom') return music.src ? decodeCached(music.src) : null;
    if (!SONGS[music.track]) return null;
    const k = music.track + ':' + Math.ceil(seconds);
    if (!cache.has(k)) cache.set(k, renderSong(music.track, seconds));
    return cache.get(k);
  }

  // The finished soundtrack for an ad `seconds` long, or null for silence. voices = [{ url, start }]
  // voice-over clips, played at voiceVolume with the music ducked to a third under them.
  async function buildTrack(music, seconds, voices, voiceVolume) {
    const sourcePromise = sourceFor(music, seconds);
    voices = (voices || []).filter((v) => v && v.url && v.start < seconds);
    if (!sourcePromise && !voices.length) return null;
    const [src, clips] = await Promise.all([sourcePromise, Promise.all(voices.map((v) => decodeCached(v.url)))]);
    const frames = Math.max(1, Math.round(seconds * SR));
    const ctx = new OfflineAudioContext(2, frames, SR);

    if (src) {
      const node = ctx.createBufferSource();
      node.buffer = src;
      const custom = music.track === 'custom';
      const start = custom ? Math.min(Math.max(0, Number(music.start) || 0), Math.max(0, src.duration - 1)) : 0;
      if (custom) { node.loop = true; node.loopStart = start; node.loopEnd = src.duration; }
      const vol = Math.min(1, Math.max(0, music.volume == null ? 0.8 : Number(music.volume)));
      const g = ctx.createGain();
      const fadeIn = custom ? 0.4 : 0.05;
      const fadeOut = Math.min(1.5, seconds / 4);
      g.gain.setValueAtTime(0, 0);
      g.gain.linearRampToValueAtTime(vol, fadeIn);
      g.gain.setValueAtTime(vol, Math.max(fadeIn, seconds - fadeOut));
      g.gain.linearRampToValueAtTime(0, seconds);
      const duck = ctx.createGain();
      duck.gain.setValueAtTime(1, 0);
      voices.forEach((v, i) => {
        duck.gain.setTargetAtTime(0.33, Math.max(0, v.start - 0.15), 0.06);
        duck.gain.setTargetAtTime(1, v.start + clips[i].duration, 0.2);
      });
      node.connect(g); g.connect(duck); duck.connect(ctx.destination);
      node.start(0, start);
    }

    const vg = ctx.createGain();
    vg.gain.value = Math.min(1.5, Math.max(0, voiceVolume == null ? 1 : Number(voiceVolume)));
    vg.connect(ctx.destination);
    voices.forEach((v, i) => {
      const node = ctx.createBufferSource();
      node.buffer = clips[i];
      node.connect(vg);
      node.start(v.start);
    });
    return ctx.startRendering();
  }

  return { MOODS, SR, buildTrack, clipSeconds };
})();
