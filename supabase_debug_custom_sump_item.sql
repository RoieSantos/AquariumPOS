-- Follow-up to supabase_debug_custom_category_items.sql: that query found placeholder Items rows
-- for CUSTOM-AQUARIUM (CI-005) and CUSTOM-STAND (CI-006), but NONE named CUSTOM-FILTRATION - which
-- is exactly why the Filtration/Sump line in a Customize order never matches and the whole push
-- gets refused. This checks whether the real placeholder item is actually named CUSTOM-SUMP
-- instead (matching the CUSTOM-SUMP category code already hardcoded elsewhere in the codebase -
-- see OnlinefunctionsEvents.cs's defaultHiddenCategories list). Safe to re-run, read-only.

select "Code", "Name", "CategoryCode", "VariationId", "ProductId", "IsActive", "SyncedAtUtc"
from public."Items"
where "Name" ilike '%CUSTOM%SUMP%' or "Name" ilike '%CUSTOM%FILTRATION%' or "Code" ilike '%CUSTOM%SUMP%' or "Code" ilike '%CUSTOM%FILTRATION%';
