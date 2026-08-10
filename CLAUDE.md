# Project instructions

## SQL file links

Whenever telling the user which `.sql` file(s) to run, or handing them a newly generated/one-off SQL script (e.g. a data backfill), always reference it as a clickable markdown link, e.g. `[supabase_pancake_manual_sync.sql](supabase_pancake_manual_sync.sql)` — never as a plain filename in backticks or a bare inline code block.

Save one-off/generated SQL as an actual `.sql` file in the repo (matching the existing `supabase_*.sql` naming convention) before linking it, so the user can click to open and copy it into the Supabase SQL editor. This applies project-wide, not just to one page/feature.
