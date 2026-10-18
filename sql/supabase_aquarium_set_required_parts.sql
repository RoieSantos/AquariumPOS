-- Per-package "required parts" for aquarium SET packages - per "can we put a setup there that some sets
-- are not mandatory to have sump / etc". The POS set dialog (MainForm.PromptForAquariumSetAccessorySelection)
-- used to force Lights, Pump, Pipe, and Sump / Stand (when the package has none) on EVERY set - so a
-- top-filter set couldn't be punched without picking a sump.
--
-- Each flag defaults to true (= the old always-required behavior), so existing packages don't change until
-- someone unticks a box on the Customer Aquarium page. The POS pulls the flags with the packages
-- (SyncAquariumSetPackagesFromSupabaseAsync) into matching local columns.
--
-- Adds columns only; no data is changed. Safe to re-run.

alter table public."CompleteAquariumSetHeader"
  add column if not exists "RequireSump"   boolean not null default true,
  add column if not exists "RequireStand"  boolean not null default true,
  add column if not exists "RequireLights" boolean not null default true,
  add column if not exists "RequirePump"   boolean not null default true,
  add column if not exists "RequirePipe"   boolean not null default true;

-- Result: every package and its required parts.
select "PackageName", "PackagePrice", "RequireSump", "RequireStand", "RequireLights", "RequirePump", "RequirePipe"
from public."CompleteAquariumSetHeader"
order by "PackageName";
