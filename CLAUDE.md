# Project instructions

## SQL file links

Whenever telling the user which `.sql` file(s) to run, or handing them a newly generated/one-off SQL script (e.g. a data backfill), always reference it as a clickable markdown link, e.g. `[supabase_pancake_manual_sync.sql](sql/supabase_pancake_manual_sync.sql)` — never as a plain filename in backticks or a bare inline code block.

Save one-off/generated SQL as an actual `.sql` file in the `sql/` folder (matching the existing `supabase_*.sql` naming convention) before linking it, so the user can click to open and copy it into the Supabase SQL editor. This applies project-wide, not just to one page/feature.

## Changelog

Whenever you make a code change (any edit/add/delete to a tracked file - SQL, JS, HTML, Edge Functions, etc.), append a dated entry to [CHANGELOG.md](CHANGELOG.md) summarizing what changed and why, in the same session as the change itself - don't wait to be asked. Newest entries go at the top, under a `## YYYY-MM-DD` heading (reuse today's heading if one already exists from earlier in the day). Keep each entry to 1-2 lines per change; this is a running log for the user, not a detailed diff.

## Keep the AI bot ("Alice") in sync

Whenever you add, change, or remove a customer-facing feature, price, policy, or business rule - a new pricing setup, a new product option, a new safety/delivery/cancellation rule, a new page or ordering flow, etc. - check whether the AI bot needs to know about it too, and update it in the same session rather than leaving it to drift:

- The bot's persona/knowledge/rules live in `buildSystemPrompt` (`supabase/functions/_shared/chatbot-engine.ts`) - this is what both the Facebook Messenger bot and the website widget ("Alice", `chatbot-web-reply`) actually run on.
- Some pricing logic is NOT shared code - it's a separate, hand-ported TypeScript copy inside `chatbot-engine.ts` (e.g. `calculateCustomAquarium` backing the `compute_aquarium_quote` tool is a duplicate of `docs/WebAquariumCalculator/custom-aquarium-calculator.js`, not an import of it). A change to the "real" calculator does NOT automatically apply to what the bot quotes - check both copies whenever you touch aquarium/stand/delivery pricing.
- If a new feature needs a new tool input (e.g. a new option the bot should be able to quote), update the relevant tool's JSON schema in `TOOLS` too, not just the calculation function - Claude can't pass a parameter that doesn't exist in the schema.
- If you decide NOT to update the bot in a given change (time/scope), say so explicitly to the user rather than silently leaving it out of sync - e.g. "the bot doesn't know about this yet" - the way the Hole/Divider aquarium pricing gap was flagged.
