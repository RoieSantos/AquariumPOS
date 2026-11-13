// Records the token usage of every Claude call into public."AIUsageLog" (sql/supabase_claude_spend_
// tracking.sql), so the portal's AI Spend page can show what the bot costs per day / feature / model
// and estimate the remaining API credit balance.
//
// Usage - wrap the client where it's created, nothing else changes:
//   const anthropic = trackAiUsage(new Anthropic({ apiKey }), 'chatbot-web-reply');
//
// Works for both anthropic.messages.create and anthropic.beta.messages.create. Logging is
// fire-and-forget: it never delays or breaks the reply, and a failed insert only logs a warning.
// Streaming calls (stream: true) are not counted - none of our functions use them.

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

let logClient: SupabaseClient | null = null;

function getLogClient(): SupabaseClient | null {
  if (logClient) return logClient;
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return null;
  logClient = createClient(url, key);
  return logClient;
}

// deno-lint-ignore no-explicit-any
function recordUsage(source: string, response: any): void {
  const usage = response?.usage;
  if (!usage) return;
  const client = getLogClient();
  if (!client) return;

  const insert = Promise.resolve(client.from('AIUsageLog').insert({
    Source: source.slice(0, 60),
    Model: typeof response.model === 'string' ? response.model.slice(0, 80) : null,
    InputTokens: usage.input_tokens ?? 0,
    OutputTokens: usage.output_tokens ?? 0,
    CacheWriteTokens: usage.cache_creation_input_tokens ?? 0,
    CacheReadTokens: usage.cache_read_input_tokens ?? 0,
    WebSearchRequests: usage.server_tool_use?.web_search_requests ?? 0
  }).then(({ error }) => {
    if (error) console.warn(`AIUsageLog insert failed (${source}):`, error.message);
  }));

  // Keep the isolate alive long enough to finish the insert if the response has already gone out.
  if (typeof EdgeRuntime !== 'undefined' && EdgeRuntime) EdgeRuntime.waitUntil(insert);
}

// deno-lint-ignore no-explicit-any
function wrapCreate(resource: any, source: string): void {
  if (!resource || typeof resource.create !== 'function' || resource.__aiUsageWrapped) return;
  const original = resource.create.bind(resource);
  // deno-lint-ignore no-explicit-any
  resource.create = (...args: any[]) => {
    const result = original(...args);
    if (!args[0]?.stream && result && typeof result.then === 'function') {
      // Side branch only - the caller still gets the SDK's own promise object back unchanged.
      result.then((response: unknown) => recordUsage(source, response), () => {});
    }
    return result;
  };
  resource.__aiUsageWrapped = true;
}

export function trackAiUsage<T>(anthropic: T, source: string): T {
  try {
    // deno-lint-ignore no-explicit-any
    const a = anthropic as any;
    wrapCreate(a.messages, source);
    wrapCreate(a.beta?.messages, source);
  } catch (err) {
    console.warn('trackAiUsage: could not wrap client:', err);
  }
  return anthropic;
}
