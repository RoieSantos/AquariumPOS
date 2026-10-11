// Page access token lookup for the Messenger bot when one Meta app (RSPetStopMessenger) serves more
// than one Facebook Page. Every Page has its own token - a message sent with another Page's token is
// rejected by Facebook - so every Send/Graph call picks the token by the conversation's PageId.
//
// Secrets:
//   FACEBOOK_PAGE_TOKENS        - optional JSON map {"<pageId>":"<page access token>", ...} for the
//                                 extra Pages (e.g. {"195716644410829":"EAAB..."}).
//   FACEBOOK_PAGE_ACCESS_TOKEN  - the original single-Page token (RSPetStop GMA). Used for any Page
//                                 not in FACEBOOK_PAGE_TOKENS, so GMA keeps working unchanged.

let cachedMap: Record<string, string> | null = null;

function pageTokenMap(): Record<string, string> {
  if (cachedMap) return cachedMap;
  const raw = Deno.env.get('FACEBOOK_PAGE_TOKENS')?.trim();
  cachedMap = {};
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') {
        for (const [id, token] of Object.entries(parsed)) {
          if (typeof token === 'string' && token.trim()) cachedMap[String(id).trim()] = token.trim();
        }
      }
    } catch {
      console.error('FACEBOOK_PAGE_TOKENS is not valid JSON - falling back to FACEBOOK_PAGE_ACCESS_TOKEN for every Page.');
    }
  }
  return cachedMap;
}

// The token for this Page, else the default FACEBOOK_PAGE_ACCESS_TOKEN (GMA / unknown Page).
export function getPageAccessToken(pageId?: string | null): string | undefined {
  const mapped = pageId ? pageTokenMap()[pageId] : undefined;
  return mapped || Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN') || undefined;
}

// True when at least one Page token is configured (default or mapped) - for the missing-secret checks.
export function hasAnyPageAccessToken(): boolean {
  return !!Deno.env.get('FACEBOOK_PAGE_ACCESS_TOKEN') || Object.keys(pageTokenMap()).length > 0;
}
