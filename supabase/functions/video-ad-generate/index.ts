// Video Ad Builder "describe your ad" (video-ad-builder.html) - staff type what the ad should be about
// (and optionally attach photos/clips), and Claude writes the whole ad: scenes, styles, headlines,
// checklists, which photo goes where, plus a Facebook caption to post it with. The page then renders
// and exports it exactly like a hand-made ad (js/videoAdRenderer.js) - this function never makes video.
//
//   POST { admin_username, admin_password, prompt,
//          photos?: [{ url, kind: 'image' | 'video', image_base64? }],   // already uploaded to video-ad-media
//          current?: <ad config with each scene's media replaced by "upload:N"> }   // "change with AI"
//   ->   { name, summary, caption, config }   (config in the shape documented in js/videoAdRenderer.js)
//
// Claude can look up the catalog (public_search_items) to get real product names/prices and use a
// product's own photo. Product photos are copied into the video-ad-media bucket first, because the
// browser can only put same-origin or CORS-enabled images into an exported video.
//
// Facts come only from the prompt, CompanyInfo / ChatbotStoreInfo / Warehouses and the catalog -
// the system prompt forbids inventing prices, discounts or promo dates.
//
// Super users only (is_admin_authorized), like the page. Secrets: ANTHROPIC_API_KEY (shared with
// the other functions); optional VIDEO_AD_MODEL to override the model.
//
// Deploy: supabase functions deploy video-ad-generate --project-ref hymcmesqgpliyyeghpgq

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import Anthropic from 'npm:@anthropic-ai/sdk@1.3.0';

const DEFAULT_MODEL = 'claude-opus-5-5';
const MEDIA_BUCKET = 'video-ad-media';
const MAX_PHOTOS = 8;
const MAX_TOOL_ROUNDS = 4;
const ACCENTS = ['#3fe0d0', '#ffd166', '#ff7a59', '#7cc8ff', '#a3e635'];
const STYLES = ['logo', 'tank', 'stand', 'sump', 'photo', 'water', 'cta'] as const;
// Tank option flags - same keys as TANK_OPTIONS in docs/js/videoAdRenderer.js.
const TANK_FLAGS = ['aio', 'rimless', 'highStrip', 'lowIron', 'tempered', 'backSticker', 'aquascape', 'light', 'cabinet', 'canopy'];
const BUILD_DIMS: Record<string, [number, number, number]> = { tank: [48, 18, 20], stand: [48, 18, 30], sump: [30, 14, 16] };

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

const SYSTEM_PROMPT = `You plan short vertical video ads (Facebook / Instagram Reels, 1080x1920) for RS Pet Stop, an aquarium and pet supply store in the Philippines (custom-made aquariums, stands and sumps; fish; aquarium and pet supplies).

Staff describe the ad they want. You return the finished ad plan; the portal animates it. You do not make footage - every scene is one of these styles, with text on top:
- logo: the shop logo big in the centre with a soft glow, under the headline. Good for an opening hook or a brand moment.
- tank: a glass aquarium draws itself and fills with water, with its length/width/height in inches counting up. Only for custom/made-to-order aquarium messages.
  Set tank_options to what the staff mention for the tank (AIO = built-in rear filter chamber, rimless, high strip = glass band round the top, low-iron / tempered glass, background sticker, aquascape, LED light, cabinet under it, canopy on top, holes = drilled holes 0-4, dividers 0-3, extras = other accessories, comma separated). Each one is drawn on the tank and shown as a tag, so only set what the staff asked for - for a general custom-aquarium ad leave them off. Leave every option false / 0 / "" for other styles.
- stand: a square-tube metal aquarium stand builds itself, with its size counting up. For stand messages. Set stand_layers (1-4, usually 2) and stand_paint ("black" or "white").
- sump: a sump (filtration tank under the aquarium) draws itself: glass box with baffles, a filter sock, bio media and a return pump, with water flowing through it and its size counting up. For sump / filtration messages.
  For tank, stand and sump put the size in size_inches as [length, width, height]; it is drawn to that shape. Use the size the staff gave; otherwise a typical one (tank 48x18x20, stand 48x18x30, sump 30x14x16) - a stand for a tank shares the tank's length and width. Leave size_inches [] for other styles.
- photo: one of the photos/clips you are given (or a catalog product photo), full screen with a slow zoom. The strongest style when there is something real to show.
- water: just the underwater background and text. Use when there is nothing to show.
- cta: the end card - shop logo and name, the headline, a big button (button), up to 3 short lines under it (checklist) and a bottom line (footer). Always exactly one, always the LAST scene.

How to write it:
- 3 to 6 scenes, about 12-20 seconds in total; each scene 2-4 seconds (the end card 3-4).
- People scroll fast: scene 1 must be a hook - a question, a bold claim or the offer itself.
- headline: 2-5 words, 28 characters at most. sub: one short line, 50 characters at most (or empty). checklist: 0-4 items, each 28 characters at most - use it for features/options/what's included. Leave fields that don't apply to a style as "" or [].
- Write in the language the staff wrote in (English, Tagalog or Taglish).
- button: what to do next, e.g. "rspetstop.com", "Message us", or a branch contact number from the business facts.
- footer: e.g. which branches, or the promo dates if staff gave them.
- voiceover: what a narrator says during that scene - one short, natural spoken line (about 2-3 words per second of the scene; the scene is lengthened if the line runs long). Write it for every scene, in the staff's language, saying more than the on-screen text rather than repeating it word for word. Same fact rules. Staff choose the voice and can edit or clear the lines.
- accent: pick the colour that suits the ad.

Facts - this is an advert, so it must be true:
- Only state prices, discounts, freebies, dates, stock or product details that the staff wrote, that come from search_products, or that are in the business facts below. Never invent a promo, a price or a deadline. If the staff did not give a price, leave prices out.
- Use search_products when the ad is about specific products or a category, to get real names (and prices if the staff want them shown) and product photos. Do not search for generic custom-aquarium ads.

Photos:
- You are shown the staff's photos, numbered. Set a photo scene's photo to "upload:N" (N = the photo's number). Use each staff photo at most once, and use all of them when they fit the ad. Pick the order that tells the story best.
- Some items are VIDEO clips you cannot see - use their file name as a hint, and give each one its own photo scene.
- A product from search_products with has_image true can be shown with photo "product:<code>". Prefer staff photos; use product photos when the staff gave none.
- photo is "" for every non-photo scene. Never use the photo style without a photo.

summary: one or two sentences telling the staff member what you made and anything they should check or add (e.g. "Add a photo of the promo tank in scene 3").
caption: a ready-to-post Facebook/Instagram caption for the video - 2-5 short lines, a few emojis, how to order or message, and 3-6 hashtags. Same fact rules.
ad_name: a short name for the staff's list of saved ads, e.g. "Betta sale - Nov 2026".`;

const OUTPUT_SCHEMA = {
  type: 'object',
  properties: {
    ad_name: { type: 'string' },
    summary: { type: 'string' },
    caption: { type: 'string' },
    accent: { type: 'string', enum: ACCENTS },
    scenes: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          style: { type: 'string', enum: [...STYLES] },
          seconds: { type: 'number' },
          headline: { type: 'string' },
          sub: { type: 'string' },
          checklist: { type: 'array', items: { type: 'string' } },
          size_inches: { type: 'array', items: { type: 'number' } },
          tank_options: {
            type: 'object',
            properties: {
              ...Object.fromEntries(TANK_FLAGS.map((k) => [k, { type: 'boolean' }])),
              holes: { type: 'integer' },
              dividers: { type: 'integer' },
              extras: { type: 'string' }
            },
            required: [...TANK_FLAGS, 'holes', 'dividers', 'extras'],
            additionalProperties: false
          },
          stand_layers: { type: 'integer' },
          stand_paint: { type: 'string', enum: ['black', 'white'] },
          photo: { type: 'string' },
          button: { type: 'string' },
          footer: { type: 'string' },
          voiceover: { type: 'string' }
        },
        required: ['style', 'seconds', 'headline', 'sub', 'checklist', 'size_inches', 'tank_options', 'stand_layers', 'stand_paint', 'photo', 'button', 'footer', 'voiceover'],
        additionalProperties: false
      }
    }
  },
  required: ['ad_name', 'summary', 'caption', 'accent', 'scenes'],
  additionalProperties: false
};

const TOOLS: Anthropic.Beta.BetaTool[] = [{
  name: 'search_products',
  description: 'Search the store catalog by product name, brand, type or size (e.g. "canister filter", "betta", "35G aquarium"). Returns up to 10 matches with code, name, category, retail price and whether the product has a photo (has_image). Call it again with different words if nothing fits.',
  strict: true,
  input_schema: {
    type: 'object',
    properties: { query: { type: 'string', description: 'Words to search for.' } },
    required: ['query'],
    additionalProperties: false
  }
}];

type Photo = { url: string; kind: 'image' | 'video'; image_base64?: string };
type ProductHit = { code: string; name: string; category: string | null; price: number | null; image: string | null };

// Items."Images" is a URL, a JSON array of URLs, or several URLs separated by commas/spaces.
function firstImageUrl(images: unknown): string | null {
  if (!images) return null;
  const text = String(images).trim();
  let candidates: string[] = [];
  if (text.startsWith('[')) {
    try { candidates = (JSON.parse(text) as unknown[]).map((x) => String(x)); } catch { /* fall through */ }
  }
  if (!candidates.length) candidates = text.split(/[\s,]+/);
  return candidates.find((u) => /^https?:\/\//i.test(u)) ?? null;
}

async function searchProducts(supabase: SupabaseClient, query: string, seen: Map<string, ProductHit>) {
  const { data, error } = await supabase.rpc('public_search_items', { p_query: query });
  if (error) return { error: error.message };
  const hits = ((data ?? []) as Record<string, unknown>[]).slice(0, 10).map((row) => {
    const hit: ProductHit = {
      code: String(row.code),
      name: String(row.name ?? ''),
      category: (row.category_code as string) ?? null,
      price: row.price == null ? null : Number(row.price),
      image: firstImageUrl(row.images)
    };
    seen.set(hit.code, hit);
    return { code: hit.code, name: hit.name, category: hit.category, price: hit.price, has_image: !!hit.image };
  });
  return { results: hits };
}

// Copies a catalog photo into our own bucket so the browser can draw it into the exported video.
async function copyProductImage(supabase: SupabaseClient, url: string): Promise<string | null> {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const type = (res.headers.get('content-type') || 'image/jpeg').split(';')[0].trim();
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(type)) return null;
    const bytes = new Uint8Array(await res.arrayBuffer());
    const ext = type === 'image/png' ? 'png' : type === 'image/webp' ? 'webp' : 'jpg';
    const now = new Date();
    const path = `${now.toISOString().slice(0, 7)}/product_${now.getTime()}_${Math.random().toString(36).slice(2, 8)}.${ext}`;
    const { error } = await supabase.storage.from(MEDIA_BUCKET).upload(path, bytes, { contentType: type });
    if (error) return null;
    return supabase.storage.from(MEDIA_BUCKET).getPublicUrl(path).data.publicUrl;
  } catch {
    return null;
  }
}

async function businessFacts(supabase: SupabaseClient): Promise<string> {
  const [{ data: company }, { data: storeInfo }, { data: branches }] = await Promise.all([
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('Warehouses').select('"Name", "Address", "ContactNo"')
  ]);
  const lines = [
    ['Business name', company?.CompanyName],
    ['Website', 'rspetstop.com (online ordering, aquarium price calculator, chat with Alice - our AI assistant)'],
    ['Facebook', company?.FacebookUrl],
    ['Main contact number', company?.ContactNo],
    ['Business hours', storeInfo?.BusinessHours],
    ['Delivery', storeInfo?.DeliveryPolicy],
    ['Payment methods', storeInfo?.PaymentMethods],
    ['Pickup locations', storeInfo?.PickupLocations],
    ['Other store info', storeInfo?.AdditionalNotes]
  ]
    .filter(([, value]) => typeof value === 'string' && value.trim())
    .map(([label, value]) => `- ${label}: ${(value as string).trim()}`);
  for (const b of (branches ?? []) as Record<string, string | null>[]) {
    if (!b.Name) continue;
    lines.push(`- Branch ${b.Name}${b.Address ? `: ${b.Address}` : ''}${b.ContactNo ? ` (contact ${b.ContactNo})` : ''}`);
  }
  lines.push('- Custom aquariums: made to any size; rimless or with rim; glass 3mm-12mm or tempered; black or clear sealant; matching stands (black or white paint) and sumps.');
  return lines.join('\n');
}

const clampNum = (v: unknown, min: number, max: number, fallback: number) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : fallback;
};
const cut = (v: unknown, max: number) => String(v ?? '').trim().slice(0, max);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return jsonResponse({ error: 'Use POST.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ error: 'video-ad-generate is missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.' }, 500);
  if (!anthropicApiKey) return jsonResponse({ error: 'Missing the ANTHROPIC_API_KEY secret.' }, 500);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Body must be JSON.' }, 400);
  }

  const adminUsername = String(body.admin_username ?? '');
  const adminPassword = String(body.admin_password ?? '');
  const prompt = String(body.prompt ?? '').trim();
  const photos = (Array.isArray(body.photos) ? body.photos : []).slice(0, MAX_PHOTOS) as Photo[];
  const current = body.current && typeof body.current === 'object' ? body.current : null;
  if (!adminUsername || !adminPassword) return jsonResponse({ error: 'Missing admin_username / admin_password.' }, 400);
  if (!prompt) return jsonResponse({ error: 'Describe the ad you want first.' }, 400);
  if (prompt.length > 2000) return jsonResponse({ error: 'Keep the description under 2000 characters.' }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey);
  const { data: authorized, error: authError } = await supabase.rpc('is_admin_authorized', {
    p_username: adminUsername,
    p_password: adminPassword
  });
  if (authError || !authorized) return jsonResponse({ error: 'Not authorized.' }, 401);

  // User turn: the numbered photos (images shown, clips described), then the request.
  const content: Anthropic.Beta.BetaContentBlockParam[] = [];
  photos.forEach((p, i) => {
    const n = i + 1;
    if (p.kind === 'image' && p.image_base64) {
      content.push({ type: 'text', text: `Photo ${n}:` });
      content.push({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: p.image_base64 } });
    } else {
      const fileName = decodeURIComponent(String(p.url).split('/').pop() || '').replace(/^\d+_/, '');
      content.push({ type: 'text', text: `Photo ${n}: a ${p.kind === 'video' ? 'VIDEO clip' : 'photo'} you cannot see (file name: ${fileName || 'unknown'}).` });
    }
  });
  const request = current
    ? `Here is the current ad (scenes' photos are written as "upload:N", the same numbering as the photos above):\n${JSON.stringify(current)}\n\nChange it as follows, keeping everything else that still fits:\n${prompt}`
    : `Make this ad:\n${prompt}`;
  content.push({ type: 'text', text: photos.length ? request : `${request}\n\n(No photos attached.)` });

  const system = `${SYSTEM_PROMPT}\n\nAbout the business (real facts - use the ones that fit; never contradict them or invent others):\n${await businessFacts(supabase)}`;
  const messages: Anthropic.Beta.BetaMessageParam[] = [{ role: 'user', content }];
  const products = new Map<string, ProductHit>();
  const anthropic = new Anthropic({ apiKey: anthropicApiKey });
  const model = Deno.env.get('VIDEO_AD_MODEL') || DEFAULT_MODEL;

  let plan: Record<string, unknown> | null = null;
  try {
    for (let round = 0; round <= MAX_TOOL_ROUNDS && !plan; round++) {
      const response = await anthropic.beta.messages.create({
        model,
        max_tokens: 16000,
        betas: ['server-side-fallback-2026-07-01'],
        fallbacks: 'default',
        output_config: { effort: 'medium', format: { type: 'json_schema', schema: OUTPUT_SCHEMA } },
        system,
        tools: TOOLS,
        // The last round can't search any more, so it has to answer.
        tool_choice: { type: round < MAX_TOOL_ROUNDS ? 'auto' : 'none' },
        messages
      });

      if (response.stop_reason === 'refusal') {
        return jsonResponse({ error: 'The AI declined to write this ad. Try describing it differently.' }, 422);
      }
      if (response.stop_reason === 'tool_use') {
        messages.push({ role: 'assistant', content: response.content as Anthropic.Beta.BetaContentBlockParam[] });
        const results: Anthropic.Beta.BetaToolResultBlockParam[] = [];
        for (const block of response.content) {
          if (block.type !== 'tool_use') continue;
          const query = String((block.input as { query?: unknown })?.query ?? '');
          const result = block.name === 'search_products' ? await searchProducts(supabase, query, products) : { error: 'Unknown tool.' };
          results.push({ type: 'tool_result', tool_use_id: block.id, content: JSON.stringify(result), is_error: 'error' in result });
        }
        messages.push({ role: 'user', content: results });
        continue;
      }
      if (response.stop_reason === 'max_tokens') {
        return jsonResponse({ error: 'The AI ran out of room writing the ad. Try a shorter description.' }, 502);
      }
      const text = response.content
        .filter((b) => b.type === 'text')
        .map((b) => (b as { text: string }).text)
        .join('');
      plan = JSON.parse(text);
    }
  } catch (err) {
    if (err instanceof Anthropic.RateLimitError) return jsonResponse({ error: 'The AI is busy right now - try again in a minute.' }, 429);
    if (err instanceof Anthropic.APIError) return jsonResponse({ error: `AI request failed (${err.status}): ${err.message}` }, 502);
    if (err instanceof SyntaxError) return jsonResponse({ error: 'The AI returned an unreadable ad. Try again.' }, 502);
    throw err;
  }
  if (!plan) return jsonResponse({ error: 'The AI did not finish the ad. Try again.' }, 502);

  // Turn the plan into the renderer's config, resolving "upload:N" / "product:CODE" to media URLs.
  const productUrls = new Map<string, string | null>();
  const rawScenes = (plan.scenes as Record<string, unknown>[]) ?? [];
  const scenes = [];
  for (const s of rawScenes.slice(0, 12)) {
    const style = STYLES.includes(s.style as typeof STYLES[number]) ? (s.style as string) : 'water';
    const scene: Record<string, unknown> = {
      style,
      duration: clampNum(s.seconds, 1.5, 6, 3),
      headline: cut(s.headline, 60),
      sub: cut(s.sub, 70),
      bullets: ((s.checklist as unknown[]) ?? []).map((x) => cut(x, 40)).filter(Boolean).slice(0, style === 'cta' ? 3 : 4)
    };
    if (cut(s.voiceover, 300)) scene.say = cut(s.voiceover, 300);
    if (BUILD_DIMS[style]) {
      const d = (s.size_inches as unknown[]) ?? [];
      const def = BUILD_DIMS[style];
      scene.dims = [clampNum(d[0], 1, 200, def[0]), clampNum(d[1], 1, 100, def[1]), clampNum(d[2], 1, 100, def[2])];
    }
    if (style === 'tank') {
      const o = (s.tank_options as Record<string, unknown>) ?? {};
      const options: Record<string, unknown> = {};
      for (const k of TANK_FLAGS) if (o[k] === true) options[k] = true;
      const holes = Math.round(clampNum(o.holes, 0, 4, 0)), dividers = Math.round(clampNum(o.dividers, 0, 3, 0));
      if (holes) options.holes = holes;
      if (dividers) options.dividers = dividers;
      if (cut(o.extras, 120)) options.extras = cut(o.extras, 120);
      scene.options = options;
    }
    if (style === 'stand') {
      scene.layers = Math.round(clampNum(s.stand_layers, 1, 4, 2));
      scene.paint = s.stand_paint === 'white' ? 'white' : 'black';
    }
    if (style === 'cta') {
      scene.button = cut(s.button, 30) || 'rspetstop.com';
      scene.footer = cut(s.footer, 50);
    }
    if (style === 'photo') {
      const ref = String(s.photo ?? '');
      const upload = /^upload:(\d+)$/.exec(ref);
      const product = /^product:(.+)$/.exec(ref);
      if (upload && photos[Number(upload[1]) - 1]) {
        const p = photos[Number(upload[1]) - 1];
        scene.media = p.url;
        scene.mediaType = p.kind === 'video' ? 'video' : 'image';
      } else if (product && products.get(product[1])?.image) {
        const code = product[1];
        if (!productUrls.has(code)) productUrls.set(code, await copyProductImage(supabase, products.get(code)!.image!));
        const url = productUrls.get(code);
        if (url) { scene.media = url; scene.mediaType = 'image'; }
      }
      // A photo scene with no usable photo still renders (water background) and the page asks for one.
    }
    scenes.push(scene);
  }
  // The end card always comes last.
  const ctaIndex = scenes.findIndex((s) => s.style === 'cta');
  if (ctaIndex === -1) {
    scenes.push({ style: 'cta', duration: 3, headline: 'Message us today', button: 'rspetstop.com', bullets: [], footer: '' });
  } else if (ctaIndex !== scenes.length - 1) {
    scenes.push(scenes.splice(ctaIndex, 1)[0]);
  }

  return jsonResponse({
    name: cut(plan.ad_name, 120) || 'AI video ad',
    summary: cut(plan.summary, 600),
    caption: cut(plan.caption, 2000),
    config: {
      version: 1,
      accent: ACCENTS.includes(plan.accent as string) ? plan.accent : ACCENTS[0],
      scenes
    }
  });
});
