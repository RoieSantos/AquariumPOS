-- Supabase/Postgres mirrors of the local dbo.OnlineOrderHeader/dbo.OnlineOrderLines (Pancake
-- customer orders) and dbo.AdvanceOrderHeader/dbo.AdvanceOrderLines (in-store deposit/downpayment
-- orders) tables.
--
-- public."OnlineOrders" is populated from THREE independent sources (any one of them keeps it
-- fresh - no single one is required):
--   1. The desktop app's push sync, every 5 minutes via MainForm's masterDataSyncTimer:
--      OnlinefunctionsEvents.SyncOnlineOrdersToSupabaseAsync() / SyncAdvanceOrdersToSupabaseAsync()
--      (exists-check-then-POST/PATCH, same pattern as Warehouses/Items).
--   2. AUTOMATICALLY, just from staff browsing the Online Orders portal page: every page of
--      admin_list_online_orders_live() (in supabase_pancake_manual_sync.sql) also upserts each
--      order's header into this table as it's fetched from Pancake for display - no manual step
--      needed. Order lines are NOT synced this way (see that function's comments).
--   3. Manually, via the super-user-only "Sync from Pancake" button (admin_sync_online_orders_
--      from_pancake in supabase_pancake_manual_sync.sql), which also fills in order lines.
-- public."AdvanceOrders"/"AdvanceOrderLines" are only synced by the desktop app (source #1).
--
-- SECURITY NOTE: these tables carry customer PII (names, shipping addresses) and are NOT
-- opened up to the "anon" role directly. The desktop app authenticates its Supabase REST
-- calls with the SECRET/service-role key, which bypasses Row Level Security entirely, so no
-- anon/authenticated policies are required for the sync itself to work. The Web Portal reads
-- this data only through the re-verifying admin_list_* functions below (super users only,
-- same trust model as supabase_staff_users_table.sql).


create table if not exists public."OnlineOrders" (
    "OrderID" varchar(100) primary key,
    "Date" date,
    "Time" varchar(12),
    "Status" varchar(100),
    "CustomerName" varchar(200),
    "Page_ID" varchar(200),
    "Conversation_ID" varchar(200),
    "LocationID" varchar(200),
    "MoneyToCollect" numeric(18, 2),
    "AmountPaid" numeric(18, 2),
    "Discount" numeric(18, 2),
    "Balance" numeric(18, 2),
    "ForDelivery" boolean,
    "ShippingAddress" varchar(1000),
    "EstimatedDeliveryDate" date,
    "PrintCount" int,
    "Last_Updated_At" timestamptz,
    "Converted_LastUpdated_At" date,
    "LastPaid_Date" date,
    "LastPaid_Time" varchar(12),
    "DateofCompletion" date,
    "SyncedAtUtc" timestamptz
);

alter table public."OnlineOrders" enable row level security;

-- Added per "can we include in-store/walk-in orders too, with a new dashboard category":
-- Pancake's own `received_at_shop` flag distinguishes a true online/delivery order (false)
-- from one that was placed through Pancake but received/paid for in-store (true, a walk-in
-- sale). Both kinds are now synced into this same table (see the received_at_shop handling
-- in supabase_pancake_manual_sync.sql) so a single "Walk-In Sales" dashboard figure can be
-- computed without a second table - existing Online Orders pages/RPCs explicitly filter this
-- column back out (see admin_list_online_orders / admin_get_online_order_status_summary
-- below) so their behavior is unchanged. `add column if not exists` keeps this idempotent for
-- databases where "OnlineOrders" already existed before this column was introduced.
alter table public."OnlineOrders" add column if not exists "ReceivedAtShop" boolean;

-- Added per "put a flag in the online header to show if an order has 10mm glass or 12mm glass
-- custom aquarium it may need or require an attachment", then per "how can we populate that
-- glass automatically upon loading the page of online orders": Pancake's order LIST api (what
-- every automatic/background sync uses) never includes line items - only the per-order DETAIL
-- endpoint does - so this can't be computed from a page-load-time query alone without an N+1
-- Pancake call per order shown. Instead it's computed ONCE per order and cached here permanently
-- (never re-checked once "GlassThicknessCheckedAt" is set), the same "compute once, cache
-- forever" pattern the desktop app already uses for Estimated Delivery Date (see
-- DetectPriorityGlassThickness in OnlineOrdersForm.cs). Two writers keep it filled in without
-- ever blocking a page load:
--   1. cron_sync_online_orders_from_pancake (supabase_pancake_manual_sync.sql) - after its
--      normal headers-only sync, backfills up to ~30 not-yet-checked orders per minute via one
--      extra detail call each (self-heals over several minutes for the initial backlog).
--   2. admin_sync_online_orders_from_pancake (the manual "Sync from Pancake" button) - already
--      pays for a full per-order detail fetch to get lines, so it sets this for free at the
--      same time.
-- admin_list_online_orders below just reads the cached column directly - instant, no per-row
-- Pancake or OnlineOrderLines lookup needed at page-load time.
alter table public."OnlineOrders" add column if not exists "GlassThickness" varchar(10);
alter table public."OnlineOrders" add column if not exists "GlassThicknessCheckedAt" timestamptz;

-- Who created/confirmed the order, per Pancake's own records - read straight from that order's
-- status_history array (status 0 = created, status 1 = confirmed) via the shared
-- public.pancake_extract_created_confirmed_by() helper (supabase_pancake_manual_sync.sql),
-- purely for reporting. Entirely Supabase-side, calling Pancake directly - the desktop POS is
-- NOT involved in populating these at all, per direct instruction. All three population paths
-- (the desktop's own header push aside, which never touches these two columns) - admin_sync_
-- online_orders_from_pancake, cron_sync_online_orders_from_pancake, and admin_list_online_
-- orders_live - call that same helper, so any of the three keeps these filled in.
alter table public."OnlineOrders" add column if not exists "CreatedBy" varchar(200);
alter table public."OnlineOrders" add column if not exists "ConfirmedBy" varchar(200);

-- WHEN the order was confirmed (as opposed to "ConfirmedBy" above, which is WHO) - for the
-- Order Confirmation Timing dashboard (super users only), so staff can see which day/hour orders
-- tend to get confirmed. Same status_history[status=1] entry as ConfirmedBy, just reading that
-- entry's own timestamp instead of its name - see the extended pancake_extract_created_confirmed_by
-- in supabase_pancake_manual_sync.sql. Nullable: only populated once a matching timestamp field is
-- found on the entry, and only for orders synced/re-synced after this column was added (see
-- supabase_order_confirmation_timing_rpc.sql's admin_backfill_order_confirmed_at for backfilling
-- existing orders).
alter table public."OnlineOrders" add column if not exists "ConfirmedAtUtc" timestamptz;

-- Pancake's own internal "print note" (order-level, sent as note_print when this app CREATES an
-- order via CreateInstoreOnlineOrder/advance-order creation - see OnlinefunctionsEvents.cs,
-- always null on the way out today) - separate from the customer-facing "note" field. Per "we are
-- syncing over the online orders into the portal... can we also include that field into the
-- supabase/portal": only present on Pancake's per-order DETAIL response (not the /orders list
-- endpoint), so - same "detail endpoint only" asymmetry as GlassThickness above - it's populated
-- by whichever sync path already pays for a detail fetch: admin_sync_online_orders_from_pancake
-- (every order, since it needs lines) and cron_sync_online_orders_from_pancake's existing
-- GlassThickness backfill loop (a capped batch of orders per run, opportunistically extended to
-- also read note_print off the same already-fetched detail body). admin_list_online_orders_live
-- (the light live-browse path, list endpoint only) does NOT populate this, matching how it
-- already skips GlassThickness. NotePrintCheckedAt mirrors GlassThicknessCheckedAt so the cron
-- backfill loop can tell "never checked" apart from "checked, genuinely blank" and self-heals for
-- orders that already had GlassThicknessCheckedAt set before this column existed.
alter table public."OnlineOrders" add column if not exists "NotePrint" text;
alter table public."OnlineOrders" add column if not exists "NotePrintCheckedAt" timestamptz;

-- Pancake's own "shipping_fee" order-level field (see OnlinefunctionsEvents.cs's
-- shipping_fee = 0 on order creation) - unlike NotePrint, this is a plain financial field that
-- sits alongside money_to_collect/cod/prepaid/discount on Pancake's LIST endpoint response, so
-- it's populated directly from the header sync (no extra per-order detail fetch needed) in all
-- three sync paths: admin_sync_online_orders_from_pancake, cron_sync_online_orders_from_pancake,
-- and admin_list_online_orders_live.
alter table public."OnlineOrders" add column if not exists "DeliveryFee" numeric;

-- Receiver phone number, per the Delivery Receipt print layout (see docs/delivery-receipt.html)
-- which shows it under the receiver's name/address. Pancake's own payload carries this on
-- shipping_address.phone_number (see OnlinefunctionsEvents.cs's shipping_address object), so
-- it's extracted the same way as ShippingAddress itself, in all three sync paths (see
-- supabase_pancake_manual_sync.sql).
alter table public."OnlineOrders" add column if not exists "ShippingPhone" varchar(50);

create table if not exists public."OnlineOrderLines" (
    "OrderID" varchar(100) not null,
    "LineID" varchar(100) not null,
    "ItemCode" varchar(200),
    "product_display_id" varchar(200),
    "VariationId" varchar(200),
    "Quantity" numeric(18, 2),
    "UnitCost" numeric(18, 2),
    "Price" numeric(18, 2),
    "Discount" numeric(18, 2),
    "GrossAmount" numeric(18, 2),
    "NetAmount" numeric(18, 2),
    "Note" text,
    "Description" varchar(500),
    "SyncedAtUtc" timestamptz,
    constraint "PK_OnlineOrderLines" primary key ("OrderID", "LineID")
);

alter table public."OnlineOrderLines" enable row level security;

create table if not exists public."AdvanceOrders" (
    "TransactionNo" varchar(100) primary key,
    "StoreNo" varchar(100),
    "POSTerminalNo" varchar(100),
    "ReceiptNo" varchar(100),
    "Type" varchar(100),
    "Quantity" numeric(18, 2),
    "Price" numeric(18, 2),
    "Discount" numeric(18, 2),
    "GrossAmount" numeric(18, 2),
    "NetAmount" numeric(18, 2),
    "Date" date,
    "Time" varchar(20),
    "UserID" varchar(100),
    "Downpayment" numeric(18, 2),
    "Balance" numeric(18, 2),
    "CustomerName" varchar(200),
    "Order_Description" varchar(1000),
    "EODID" varchar(100),
    "SyncedAtUtc" timestamptz
);

alter table public."AdvanceOrders" enable row level security;

create table if not exists public."AdvanceOrderLines" (
    "TransactionNo" varchar(100) not null,
    "LineNo" varchar(50) not null,
    "StoreNo" varchar(100),
    "POSTerminalNo" varchar(100),
    "ReceiptNo" varchar(100),
    "Type" varchar(100),
    "No" varchar(200),
    "Description" varchar(500),
    "Quantity" numeric(18, 2),
    "Price" numeric(18, 2),
    "Discount" numeric(18, 2),
    "GrossAmount" numeric(18, 2),
    "NetAmount" numeric(18, 2),
    "Date" date,
    "Time" varchar(20),
    "EODID" varchar(100),
    "UserID" varchar(100),
    "VariationId" varchar(200),
    "SyncedAtUtc" timestamptz,
    constraint "PK_AdvanceOrderLines" primary key ("TransactionNo", "LineNo")
);

alter table public."AdvanceOrderLines" enable row level security;

create index if not exists "IX_OnlineOrderLines_OrderID" on public."OnlineOrderLines" ("OrderID");
create index if not exists "IX_AdvanceOrderLines_TransactionNo" on public."AdvanceOrderLines" ("TransactionNo");

-- Read-only "Online Orders" (any active staff) / "Advance Orders" (super users only) pages.
-- Every call still re-verifies the acting staff member's username + password rather than
-- opening direct anon SELECT access (this data includes customer names/addresses) - Online
-- Orders uses public.is_staff_authorized() (any active login), while Advance Orders still
-- requires public.is_admin_authorized() (SuperUser=true) since it wasn't opened up.

drop function if exists public.admin_list_online_orders(text, text, text, text);
drop function if exists public.admin_list_online_orders(text, text, text, text, text);
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean);
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int);
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text);

-- p_order_id: exact filter, used by the lines drill-down page to fetch just that order's header.
-- p_search/p_status: free-text browsing filters, ignored when p_order_id is set.
--
-- glass_thickness: per "put a flag in the online header to show if an order has 10mm glass or
-- 12mm glass custom aquarium it may need or require an attachment". Straight passthrough of the
-- cached OnlineOrders."GlassThickness" column - see that column's comment above (near the
-- ReceivedAtShop alter) for how/where it actually gets computed and cached. Deliberately NOT
-- computed here from OnlineOrderLines/live Pancake, so this stays a plain instant read with no
-- per-row lookup cost at page-load time.
--
-- has_custom_line: per "assign the order to a team member" for custom-built items (custom
-- aquarium/stand/sump/etc, identified the same way as everywhere else in this codebase - the
-- word "custom" in the line's item code/description, see supabase_online_order_production_
-- assignment.sql's header comment). Unlike glass_thickness above, this is computed live via a
-- correlated EXISTS against OnlineOrderLines rather than cached on the row - OnlineOrderLines is
-- already a locally-synced table (no live Pancake call needed to check it), so there's no reason
-- to pay for a separate cache/backfill job here.
--
-- assigned_production_member / assigned_production_member_name: the Production Member (see
-- supabase_staff_users_production_member_field.sql) this order's custom build is assigned to, if
-- any - set via admin_assign_online_order_production_member
-- (supabase_online_order_production_assignment.sql).
--
-- p_period / p_walkin_only: per "once I click the dashboard I want to be able to open the
-- corresponding data/page of entries filtered" - the dashboard's finance cards (Total Sales This
-- Month, Today's Online Sales, Walk-In Sales This Month, Today's Walk-In Sales) link here with
-- these set so the list opens already scoped to what the card showed, instead of the full
-- unfiltered order list. p_period ('month'/'today'/'prevmonth'/null) reuses the exact same
-- Asia/Manila boundary logic as admin_get_online_order_financial_summary/admin_get_sales_by_
-- confirmed_by so the list always matches what that card actually counted. p_walkin_only flips
-- the existing ReceivedAtShop exclusion around (default false preserves the page's normal
-- online-orders-only behavior).
--
-- p_confirmed_by: per "click on the [Sales by Staff] figure and show all order details" - an
-- exact (case/whitespace-insensitive) match against OnlineOrders."ConfirmedBy", used by the
-- Dashboard's Sales by Staff cards to deep-link straight to that staff member's orders for the
-- period clicked. Same text-match convention as admin_get_sales_by_confirmed_by.
--
-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
create or replace function public.admin_list_online_orders(
  p_admin_username text, p_admin_password text,
  p_search text default null, p_status text default null, p_order_id text default null,
  p_period text default null, p_walkin_only boolean default false,
  p_page int default 1, p_page_size int default 50,
  p_confirmed_by text default null
)
returns table(
  order_id text,
  order_date date,
  order_time text,
  status text,
  customer_name text,
  location_id text,
  warehouse_name text,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  for_delivery boolean,
  shipping_address text,
  estimated_delivery_date date,
  last_updated_at timestamptz,
  synced_at_utc timestamptz,
  glass_thickness text,
  created_by text,
  confirmed_by text,
  note_print text,
  delivery_fee numeric,
  has_custom_line boolean,
  assigned_production_member text,
  assigned_production_member_name text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_today date;
  v_prev_month_start date;
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_period in ('month', 'today', 'prevmonth') then
    v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
    v_month_end := (v_month_start + interval '1 month')::date;
    v_today := (now() at time zone 'Asia/Manila')::date;
    v_prev_month_start := (v_month_start - interval '1 month')::date;
  end if;

  return query
    select o."OrderID"::text, o."Date", o."Time"::text, o."Status"::text, o."CustomerName"::text, o."LocationID"::text, w."Name"::text,
           o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance", o."ForDelivery", o."ShippingAddress"::text,
           o."EstimatedDeliveryDate", o."Last_Updated_At", o."SyncedAtUtc", o."GlassThickness"::text,
           o."CreatedBy"::text, o."ConfirmedBy"::text, o."NotePrint"::text, o."DeliveryFee",
           exists (
             select 1 from public."OnlineOrderLines" ol
             where ol."OrderID" = o."OrderID"
               and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
           ),
           o."AssignedProductionMember"::text, spm."DisplayName"::text,
           count(*) over()
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    left join public."StaffUsers" spm on spm."Username" = o."AssignedProductionMember"
    where (case when p_walkin_only then o."ReceivedAtShop" is true else o."ReceivedAtShop" is not true end)
      and (p_period is distinct from 'month' or (o."Date" >= v_month_start and o."Date" < v_month_end))
      and (
        p_period is distinct from 'today'
        or (
          -- Widens "today" to the same ConfirmedAtUtc-based rule used by
          -- admin_get_sales_by_confirmed_by's daily_sales AND admin_get_online_order_financial_
          -- summary's today_online_sales - i.e. whenever this list is scoped to online orders
          -- (p_walkin_only false, the default) or to a specific staff member's Daily drill-down
          -- (p_confirmed_by set - always online-only anyway, per that function's own join). The
          -- Today's Walk-In Sales card (p_walkin_only true, no p_confirmed_by) keeps the plain
          -- Date = today behavior its own total is still computed with, so that figure and its
          -- drill-down list still always match.
          case
            when (p_confirmed_by is not null and trim(p_confirmed_by) <> '') or not p_walkin_only
              then coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
            else o."Date" = v_today
          end
        )
      )
      and (p_period is distinct from 'prevmonth' or (o."Date" >= v_prev_month_start and o."Date" < v_month_start))
      and (p_confirmed_by is null or trim(p_confirmed_by) = '' or lower(trim(o."ConfirmedBy")) = lower(trim(p_confirmed_by)))
      and (
        (p_order_id is not null and trim(p_order_id) <> '' and o."OrderID" = p_order_id)
        or (
          (p_order_id is null or trim(p_order_id) = '')
          and (p_search is null or trim(p_search) = '' or o."OrderID" ilike '%' || p_search || '%' or o."CustomerName" ilike '%' || p_search || '%')
          and (p_status is null or trim(p_status) = '' or o."Status" ilike '%' || p_status || '%')
        )
      )
    order by o."Last_Updated_At" desc nulls last, o."Date" desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_list_online_order_lines(text, text, text);

create or replace function public.admin_list_online_order_lines(p_admin_username text, p_admin_password text, p_order_id text)
returns table(
  order_id text,
  line_id text,
  item_code text,
  product_display_id text,
  variation_id text,
  quantity numeric,
  unit_cost numeric,
  price numeric,
  discount numeric,
  gross_amount numeric,
  net_amount numeric,
  description text,
  note text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "OrderID"::text, "LineID"::text, "ItemCode"::text, "product_display_id"::text, "VariationId"::text,
           "Quantity", "UnitCost", "Price", "Discount", "GrossAmount", "NetAmount", "Description"::text, "Note"::text
    from public."OnlineOrderLines"
    where "OrderID" = p_order_id
    order by "LineID";
end;
$$;

-- Dashboard status overview cards ("Confirmed / Printed / To Ship / Shipped / Cancelled").
-- Deliberately queries the persisted public."OnlineOrders" table (kept fresh by the desktop
-- app's own 5-minute push sync) instead of Pancake directly - a plain grouped count over a
-- local table is effectively instant, unlike the live Pancake list view which has to be paged
-- carefully to avoid the gateway's "HTTP request cancelled" cancellation (see
-- supabase_pancake_manual_sync.sql). Always returns exactly these 5 rows (0 if none found) so
-- the dashboard doesn't need to guess which labels exist.
--
-- Bucketing is done case-insensitively against BOTH the already-normalized title-case labels
-- the desktop app writes (Confirmed/Printed/To Ship/Shipped - see the status-normalization
-- block in IntegrationEvents.cs) AND the raw upstream Pancake tokens those labels are derived
-- from (submitted, packing/packed, shipped/delivered/2, canceled/cancelled, etc), so a stray
-- unnormalized value or casing/whitespace difference still lands in the right bucket instead
-- of silently being excluded and showing as 0.
--
-- p_warehouse_name (optional, per "I want the dashboard count for the status counted based on
-- the warehouse too"): when supplied, only orders whose LocationID resolves (via Warehouses) to
-- that warehouse name are counted - same warehouse-scoping convention as Transfer Orders/Online
-- Orders list filtering (js/transferOrders.js, matchesWarehouseFilter in onlineOrders.js). Both
-- call sites (dashboard.js and onlineOrders.js) pass the caller's own session.warehouseName so a
-- warehouse-scoped staff member's dashboard/status cards only reflect their own warehouse; super
-- users / staff with no assigned warehouse pass null and see the unfiltered totals as before.
drop function if exists public.admin_get_online_order_status_summary(text, text);
drop function if exists public.admin_get_online_order_status_summary(text, text, text);

create or replace function public.admin_get_online_order_status_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null)
returns table(status_label text, order_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with buckets(status_label, sort_order) as (
      values ('Confirmed', 1), ('Printed', 2), ('To Ship', 3), ('Shipped', 4), ('Cancelled', 5)
    ),
    order_buckets as (
      select
        case
          when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted') then 'Confirmed'
          when lower(trim(coalesce(o."Status", ''))) = 'printed' then 'Printed'
          when lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed') then 'To Ship'
          when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2') then 'Shipped'
          when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
          else null
        end as status_label
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."ReceivedAtShop" is not true
        and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name)
    )
    select b.status_label, count(ob.status_label)::int as order_count
    from buckets b
    left join order_buckets ob on ob.status_label = b.status_label
    group by b.status_label, b.sort_order
    order by b.sort_order;
end;
$$;

-- Dashboard "Amount to Receive" / "Total Sales This Month" / "Monthly Sales Target" cards
-- (super users only). All figures come straight from the persisted OnlineOrders table - no
-- live Pancake call needed, same as admin_get_online_order_status_summary above. Cancelled
-- orders are excluded from all of them (an order that never happened shouldn't count as
-- money owed, a sale, or progress toward the target). "This month" uses the Asia/Manila
-- business date (same UTC+8 convention used everywhere else in this codebase - see
-- supabase_pancake_manual_sync.sql), not the DB server's own date/time.
--
-- month_sales_target: per "Monthly sales target = 28000 per day * number of days in the
-- month" - computed here (not in the browser) so it always matches the same Asia/Manila
-- month boundaries used for month_sales, regardless of the viewer's own browser timezone,
-- and automatically adjusts for 28/29/30/31-day months without any client-side date math.
--
-- walkin_sales_month / walkin_order_count: per "can we include [in-store orders] and create a
-- new category on the dashboard saying in-store sales or walk-in sales" - same month/exclusion
-- rules as month_sales above, but for orders where "ReceivedAtShop" = true (Pancake orders that
-- were received/paid for in-store rather than delivered) instead of false. amount_to_receive
-- deliberately stays online-only (walk-in sales are paid at the counter, not owed afterward).
--
-- today_online_sales / today_online_order_count / today_walkin_sales / today_walkin_order_count:
-- per "can you add daily online sales and walk-in sales too?" - identical online/walk-in split
-- and exclusion rules as the month_* / walkin_*_month figures above, just scoped to today's
-- Asia/Manila business date instead of the whole month.
--
-- today_online_sales/today_online_order_count specifically key off "ConfirmedAtUtc" (falling
-- back to "Date" when still null) rather than plain "Date" - per "so in the daily report of
-- sales.. Today's online sales can we do the same thing" as the per-staff Daily figure in
-- admin_get_sales_by_confirmed_by (see that function's own comment for the full reasoning: "Date"
-- is when the order was PLACED, not when it was actually confirmed, so an order placed on an
-- earlier day but confirmed today belongs in today's sales). today_walkin_sales is untouched -
-- walk-in orders are received/paid in-store immediately, not confirmed later like online orders,
-- so "Date" already reflects the sale.
--
-- previous_month_walkin_sales / previous_month_walkin_order_count: per "show daily sales and
-- previous month (Walk-in)" - same walk-in split/exclusion rules as walkin_sales_month above,
-- scoped to the full calendar month immediately before the current one (same Asia/Manila
-- boundary convention as admin_get_sales_by_confirmed_by's previous_month_sales).
drop function if exists public.admin_get_online_order_financial_summary(text, text, text);

create or replace function public.admin_get_online_order_financial_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null)
returns table(
  amount_to_receive numeric, month_sales numeric, month_order_count int, month_sales_target numeric,
  walkin_sales_month numeric, walkin_order_count int,
  today_online_sales numeric, today_online_order_count int,
  today_walkin_sales numeric, today_walkin_order_count int,
  previous_month_walkin_sales numeric, previous_month_walkin_order_count int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_days_in_month int;
  v_today date;
  v_prev_month_start date;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_month_end := (v_month_start + interval '1 month')::date;
  v_days_in_month := v_month_end - v_month_start;
  v_today := (now() at time zone 'Asia/Manila')::date;
  v_prev_month_start := (v_month_start - interval '1 month')::date;

  return query
    select
      coalesce(sum(o."Balance") filter (
        where o."Balance" > 0
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as amount_to_receive,
      coalesce(sum(o."MoneyToCollect") filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as month_sales,
      count(*) filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as month_order_count,
      (28000 * v_days_in_month)::numeric as month_sales_target,
      coalesce(sum(o."MoneyToCollect") filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as walkin_sales_month,
      count(*) filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as walkin_order_count,
      coalesce(sum(o."MoneyToCollect") filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as today_online_sales,
      count(*) filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as today_online_order_count,
      coalesce(sum(o."MoneyToCollect") filter (
        where o."Date" = v_today
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as today_walkin_sales,
      count(*) filter (
        where o."Date" = v_today
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as today_walkin_order_count,
      coalesce(sum(o."MoneyToCollect") filter (
        where o."Date" >= v_prev_month_start and o."Date" < v_month_start
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as previous_month_walkin_sales,
      count(*) filter (
        where o."Date" >= v_prev_month_start and o."Date" < v_month_start
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as previous_month_walkin_order_count
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name;
end;
$$;

-- Dashboard "Sales by Staff (Confirmed By)" table - per "if the Display Name = Confirmed By...
-- show Daily/Monthly/Previous Month Sales, filter Confirmed By based on the Display Name of the
-- user setup". One row per staff member flagged "SalesUser" in StaffUsers (see
-- supabase_staff_users_table.sql), matched to their online orders by
-- lower(trim("ConfirmedBy")) = lower(trim("DisplayName")) - Pancake's ConfirmedBy field (see
-- pancake_extract_created_confirmed_by in supabase_pancake_manual_sync.sql) is a free-text name
-- staff typed/were assigned in Pancake, not a foreign key, so this is a best-effort text match,
-- case/whitespace-insensitive to reduce false negatives from minor formatting differences.
-- LEFT JOIN + a Sales User with zero matching orders still gets a row (all-zero figures) so the
-- table always lists every Sales User, not just ones with sales this period.
--
-- Same online-only, non-cancelled scope as month_sales/today_online_sales above (walk-in orders
-- excluded, per direct instruction) - a Sales User's walk-in confirmations (if any) don't count
-- here. "Previous Month" is the full calendar month immediately before the current one, same
-- Asia/Manila business-date boundaries used everywhere else on this dashboard.
--
-- monthly_sales_target: per "I want to see their sales target per sales staff and how many %
-- already they accomplish - to accomplish this I want to add new field under user setup to
-- setup their target sales". Straight passthrough of StaffUsers."MonthlySalesTarget" (see
-- supabase_staff_users_table.sql) - the % accomplished itself is left for the client to compute
-- (monthly_sales / monthly_sales_target) so the dashboard can render it live, same convention
-- as the site-wide Monthly Sales Target card (updateSalesTargetTile in js/dashboard.js).
--
-- daily_sales/daily_order_count: per "under the sales user Daily can you add printed/toship/
-- shipped status as long as its today's date it will fall on the Daily sales", refined by "can we
-- grab the confirmation date from pancake... I think its the time when the order has been
-- changed status = 1 (confirmed)". "Date" is the order's PLACED date (from Pancake's inserted_at/
-- created_at), not when a Sales User actually confirmed it - an order placed on one day can sit
-- unconfirmed and get confirmed (and later printed/shipped) days afterward, so gating Daily
-- purely on "Date" = today both undercounts (a same-day confirmation of an older order never
-- shows) and doesn't track the actual sales action being measured here. "ConfirmedAtUtc" (see the
-- alter table above) is the real status=1 timestamp pulled straight from Pancake's status_history
-- via pancake_extract_created_confirmed_by() (supabase_pancake_manual_sync.sql) - using its
-- Asia/Manila calendar date is the correct "did this Sales User confirm this order today" signal,
-- and since it doesn't change when the order later moves to Printed/To Ship/Shipped, those orders
-- stay correctly attributed to the day they were actually confirmed rather than the day they
-- happened to ship. Falls back to "Date" only when ConfirmedAtUtc is still null (older orders
-- synced before this column existed / not yet backfilled - see admin_backfill_order_confirmed_at
-- in supabase_order_confirmation_timing_rpc.sql), so nothing silently drops out of Daily while
-- the backfill is catching up.
drop function if exists public.admin_get_sales_by_confirmed_by(text, text);

create or replace function public.admin_get_sales_by_confirmed_by(p_admin_username text, p_admin_password text)
returns table(
  display_name text,
  daily_sales numeric,
  daily_order_count int,
  monthly_sales numeric,
  monthly_order_count int,
  previous_month_sales numeric,
  previous_month_order_count int,
  monthly_sales_target numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date;
  v_month_start date;
  v_month_end date;
  v_prev_month_start date;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_today := (now() at time zone 'Asia/Manila')::date;
  v_month_start := date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month')::date;
  v_prev_month_start := (v_month_start - interval '1 month')::date;

  return query
    select
      su."DisplayName"::text,
      coalesce(sum(o."MoneyToCollect") filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
      ), 0)::numeric as daily_sales,
      count(*) filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
      )::int as daily_order_count,
      coalesce(sum(o."MoneyToCollect") filter (where o."Date" >= v_month_start and o."Date" < v_month_end), 0)::numeric as monthly_sales,
      count(*) filter (where o."Date" >= v_month_start and o."Date" < v_month_end)::int as monthly_order_count,
      coalesce(sum(o."MoneyToCollect") filter (where o."Date" >= v_prev_month_start and o."Date" < v_month_start), 0)::numeric as previous_month_sales,
      count(*) filter (where o."Date" >= v_prev_month_start and o."Date" < v_month_start)::int as previous_month_order_count,
      coalesce(su."MonthlySalesTarget", 0)::numeric as monthly_sales_target
    from public."StaffUsers" su
    left join public."OnlineOrders" o
      on lower(trim(o."ConfirmedBy")) = lower(trim(su."DisplayName"))
      and o."ReceivedAtShop" is not true
      and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
    where su."SalesUser" is true
      and su."DisplayName" is not null and trim(su."DisplayName") <> ''
    group by su."DisplayName", su."MonthlySalesTarget"
    order by su."DisplayName";
end;
$$;

grant execute on function public.admin_get_sales_by_confirmed_by(text, text) to anon;

-- "Where can I see the last sync date/time?" - answers that directly: the single latest
-- SyncedAtUtc across every row in OnlineOrders, i.e. whichever of the three population paths
-- (desktop app's push sync, automatic live-view persistence, or the manual "Sync from Pancake"
-- button) last actually wrote something. Shown on the Online Orders page next to the status
-- summary bar so there's always a real, persistent answer instead of only a transient
-- per-click message that disappears on refresh/navigation.
drop function if exists public.admin_get_online_orders_last_synced_at(text, text);

create or replace function public.admin_get_online_orders_last_synced_at(p_admin_username text, p_admin_password text)
returns timestamptz
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_last_synced timestamptz;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select max("SyncedAtUtc") into v_last_synced from public."OnlineOrders";
  return v_last_synced;
end;
$$;

drop function if exists public.admin_list_advance_orders(text, text, text);
drop function if exists public.admin_list_advance_orders(text, text, text, text);
drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int);

-- p_transaction_no: exact filter, used by the lines drill-down page to fetch just that order's
-- header - that call site doesn't pass p_page/p_page_size, so it just gets the (1, 50) defaults,
-- fine since exactly one matching row is expected.
-- p_search: free-text browsing filter, ignored when p_transaction_no is set.
-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
create or replace function public.admin_list_advance_orders(p_admin_username text, p_admin_password text, p_search text default null, p_transaction_no text default null, p_page int default 1, p_page_size int default 50)
returns table(
  transaction_no text,
  receipt_no text,
  user_id text,
  customer_name text,
  order_description text,
  order_date date,
  order_time text,
  net_amount numeric,
  downpayment numeric,
  balance numeric,
  synced_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "TransactionNo"::text, "ReceiptNo"::text, "UserID"::text, "CustomerName"::text, "Order_Description"::text,
           "Date", "Time"::text, "NetAmount", "Downpayment", "Balance", "SyncedAtUtc",
           count(*) over()
    from public."AdvanceOrders"
    where (p_transaction_no is not null and trim(p_transaction_no) <> '' and "TransactionNo" = p_transaction_no)
       or (
         (p_transaction_no is null or trim(p_transaction_no) = '')
         and (
           p_search is null or trim(p_search) = ''
           or "TransactionNo" ilike '%' || p_search || '%'
           or "ReceiptNo" ilike '%' || p_search || '%'
           or "CustomerName" ilike '%' || p_search || '%'
           or "UserID" ilike '%' || p_search || '%'
         )
       )
    order by "TransactionNo" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_list_advance_order_lines(text, text, text);
drop function if exists public.admin_list_advance_order_lines(text, text, text, int, int);

-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
create or replace function public.admin_list_advance_order_lines(p_admin_username text, p_admin_password text, p_transaction_no text, p_page int default 1, p_page_size int default 50)
returns table(
  transaction_no text,
  line_no text,
  receipt_no text,
  type text,
  item_no text,
  description text,
  quantity numeric,
  price numeric,
  discount numeric,
  gross_amount numeric,
  net_amount numeric,
  user_id text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "TransactionNo"::text, "LineNo"::text, "ReceiptNo"::text, "Type"::text, "No"::text, "Description"::text,
           "Quantity", "Price", "Discount", "GrossAmount", "NetAmount", "UserID"::text,
           count(*) over()
    from public."AdvanceOrderLines"
    where "TransactionNo" = p_transaction_no
    order by "LineNo"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- Direct table access stays fully blocked by RLS (no policies); only the
-- re-verifying functions above are reachable from the portal's anon key.
revoke all on public."OnlineOrders" from anon, authenticated;
revoke all on public."OnlineOrderLines" from anon, authenticated;
revoke all on public."AdvanceOrders" from anon, authenticated;
revoke all on public."AdvanceOrderLines" from anon, authenticated;

grant execute on function public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text) to anon;
grant execute on function public.admin_list_online_order_lines(text, text, text) to anon;
grant execute on function public.admin_get_online_order_status_summary(text, text, text) to anon;
grant execute on function public.admin_get_online_order_financial_summary(text, text, text) to anon;
grant execute on function public.admin_get_online_orders_last_synced_at(text, text) to anon;
grant execute on function public.admin_list_advance_orders(text, text, text, text, int, int) to anon;
grant execute on function public.admin_list_advance_order_lines(text, text, text, int, int) to anon;
