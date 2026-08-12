-- One-time (re-runnable) backfill for public."OnlineOrderLines" - discovered empty (2205 orders,
-- 0 with lines) while building the Top Selling Items report, because no automatic sync path had
-- ever populated it: the per-minute cron only syncs headers, the manual admin_sync_online_orders_
-- from_pancake button has no UI trigger wired up, and admin_get_online_order_detail_live is
-- fetch-for-display-only (never persisted). supabase_pancake_manual_sync.sql's
-- cron_sync_online_orders_from_pancake now also does a small bounded backfill of this every
-- minute going forward (~30 orders/run) so this gap won't recur, but at that rate 2205 orders
-- would take over an hour to fully catch up - this RPC lets you power through the existing
-- backlog faster by calling it repeatedly from the SQL editor with a larger p_limit.
--
-- Same "loop N orders missing the target data, one detail fetch each, on conflict do update"
-- shape as admin_backfill_order_confirmed_at (supabase_order_confirmation_timing_rpc.sql) and the
-- new lines-backfill block in cron_sync_online_orders_from_pancake - the insert logic itself is
-- copied verbatim from admin_sync_online_orders_from_pancake's line-sync block.
--
-- Deliberately not restricted to ReceivedAtShop = false - covers walk-in/in-store orders too,
-- since Top Selling Items intentionally includes them.

drop function if exists public.admin_backfill_online_order_lines(text, text, int);

create or replace function public.admin_backfill_online_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_limit int default 25
)
returns table(processed_count int, updated_count int, remaining_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := 'e611861d2fc84607bfbbe1428a432447';
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_limit int := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_order_id text;
  v_detail_url text;
  v_detail_response extensions.http_response;
  v_detail_body jsonb;
  v_order_el jsonb;
  v_line_items jsonb;
  v_line_item jsonb;
  v_variation_info jsonb;
  v_product_display_id text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_line_name text;
  v_line_note text;
  v_line_id text;
  v_lines_inserted_this_order int;
  v_processed int := 0;
  v_updated int := 0;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  for v_order_id in
    select o."OrderID" from public."OnlineOrders" o
    where not exists (select 1 from public."OnlineOrderLines" l where l."OrderID" = o."OrderID")
    order by o."Last_Updated_At" desc nulls last
    limit v_limit
  loop
    v_processed := v_processed + 1;
    begin
      v_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order_id || '?api_key=' || v_api_key || '&page_size=1000';
      v_detail_response := extensions.http_get(v_detail_url);

      if v_detail_response.status >= 200 and v_detail_response.status < 300 then
        v_detail_body := v_detail_response.content::jsonb;
        v_order_el := case
          when jsonb_typeof(v_detail_body -> 'data') = 'object' then v_detail_body -> 'data'
          when jsonb_typeof(v_detail_body) = 'object' then v_detail_body
          else null
        end;
        v_line_items := case
          when v_order_el is not null and jsonb_typeof(v_order_el -> 'items') = 'array' then v_order_el -> 'items'
          else '[]'::jsonb
        end;

        v_lines_inserted_this_order := 0;

        for v_line_item in select * from jsonb_array_elements(v_line_items)
        loop
          begin
            v_variation_info := v_line_item -> 'variation_info';
            v_product_display_id := coalesce(v_variation_info ->> 'product_display_id', v_line_item ->> 'product_display_id');
            if v_product_display_id is null or trim(v_product_display_id) = '' then
              continue;
            end if;

            v_variation_id := coalesce(v_variation_info ->> 'variation_id', v_line_item ->> 'variation_id', v_line_item ->> 'variationId');
            v_qty := public.pancake_parse_decimal(v_line_item ->> 'quantity');
            v_price := public.pancake_parse_decimal(coalesce(v_variation_info ->> 'retail_price', v_line_item ->> 'retail_price'));
            v_line_name := coalesce(v_variation_info ->> 'name', v_line_item ->> 'name');
            v_line_note := v_line_item ->> 'note';
            v_line_id := coalesce(
              v_line_item ->> 'line_id', v_line_item ->> 'id', v_line_item ->> 'order_line_id',
              v_line_item ->> 'order_item_id', v_line_item ->> 'item_id', ''
            );

            insert into public."OnlineOrderLines" (
              "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
            ) values (
              v_order_id, v_line_id, v_product_display_id, v_product_display_id, nullif(v_variation_id, ''), v_qty, null, v_price, v_price * v_qty, nullif(v_line_note, ''), nullif(v_line_name, ''), now()
            )
            on conflict ("OrderID", "LineID") do update set
              "ItemCode" = excluded."ItemCode",
              "product_display_id" = excluded."product_display_id",
              "VariationId" = excluded."VariationId",
              "Quantity" = excluded."Quantity",
              "Price" = excluded."Price",
              "GrossAmount" = excluded."GrossAmount",
              "Note" = excluded."Note",
              "Description" = excluded."Description",
              "SyncedAtUtc" = now();

            v_lines_inserted_this_order := v_lines_inserted_this_order + 1;
          exception when others then
            null; -- skip malformed line, keep processing the rest
          end;
        end loop;

        if v_lines_inserted_this_order > 0 then
          v_updated := v_updated + 1;
        end if;
      end if;
    exception when others then
      null; -- skip this order, keep processing the rest of the batch
    end;
  end loop;

  return query
    select v_processed, v_updated,
      (select count(*) from public."OnlineOrders" o where not exists (select 1 from public."OnlineOrderLines" l where l."OrderID" = o."OrderID"));
end;
$$;

grant execute on function public.admin_backfill_online_order_lines(text, text, int) to anon;
