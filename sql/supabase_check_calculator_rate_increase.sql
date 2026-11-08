-- =============================================================================
-- READ-ONLY CHECK: did the price increase include the custom aquarium calculator?
--
-- Custom aquarium quotes come from calculator rates (glass, tubular, peso extras), not item
-- prices. Those rates go up only if a Price Increase batch has 'glass' / 'tubular' / 'extra'
-- lines (the "Calculator rates" table on price-increase.html, added 2026-10-31).
--
-- One row per batch: how many item / set / calculator-rate lines it has, and how many
-- calculator lines were skipped. Status 'Applied' + calculator_lines > 0 = custom aquariums
-- went up. calculator_lines = 0 = that batch did NOT touch the calculator.
-- =============================================================================

select b."BatchId" as batch_id,
       b."Description" as description,
       b."Status" as status,
       b."IncreasePct" as increase_pct,
       coalesce(b."AppliedAtUtc", b."ScheduledForUtc", b."CreatedAtUtc") as batch_date,
       count(l."LineNo") filter (where l."Kind" in ('item', 'variant')) as item_lines,
       count(l."LineNo") filter (where l."Kind" = 'set') as set_lines,
       count(l."LineNo") filter (where l."Kind" in ('glass', 'tubular', 'extra')) as calculator_lines,
       count(l."LineNo") filter (where l."Kind" in ('glass', 'tubular', 'extra') and l."Skipped") as calculator_lines_skipped,
       case
         when count(l."LineNo") filter (where l."Kind" in ('glass', 'tubular', 'extra')) = 0
           then 'NO - calculator rates not in this batch'
         when b."Status" = 'Applied' then 'YES - calculator rates applied'
         else 'in batch but status is ' || b."Status"
       end as custom_aquarium_included
from public."PriceChangeBatches" b
left join public."PriceChangeBatchLines" l on l."BatchId" = b."BatchId"
group by b."BatchId"
order by b."BatchId" desc;
