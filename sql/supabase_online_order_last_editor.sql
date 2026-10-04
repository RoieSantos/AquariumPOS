-- Online Order card: who last updated the order - per "can you help me put a name of the user who last
-- update the order?". The card's "Last Updated" only had Pancake's updated_at time; Pancake keeps the
-- editor on its own edit history (histories[], one entry per change), which OnlineOrders doesn't store.
--
-- staff_get_online_order_last_editor(order) GETs the order from Pancake and returns the newest history
-- entry's editor: { name, at, via } (name null when Pancake gives none). Falls back to an order-level
-- last_editor / updated_by object if the order has no history. Read-only, called when the card opens.
--
-- Note: edits the portal makes (status changes, SET materials, ...) go through the shop API key, so
-- Pancake records them under the API connection user, not the portal staff member.
--
-- Safe to re-run.

create or replace function public.staff_get_online_order_last_editor(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '15000'
as $$
declare
  v_response extensions.http_response;
  v_body jsonb;
  v_order jsonb;
  v_entry jsonb;
  v_name text;
  v_at text;
  v_via text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');
  v_response := extensions.http_get(
    'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || trim(p_order_id)
    || '?api_key=' || public._pancake_api_key());
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not read order % from Pancake (HTTP %).', p_order_id, v_response.status;
  end if;

  v_body := v_response.content::jsonb;
  v_order := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body -> 'order') = 'object' then v_body -> 'order'
    else v_body
  end;

  -- Newest history entry (by its time, then by position - Pancake appends).
  select h.entry into v_entry
  from jsonb_array_elements(case when jsonb_typeof(v_order -> 'histories') = 'array'
                                 then v_order -> 'histories' else '[]'::jsonb end)
       with ordinality as h(entry, n)
  order by coalesce(h.entry ->> 'updated_at', h.entry ->> 'inserted_at', h.entry ->> 'created_at', '') desc, h.n desc
  limit 1;

  if v_entry is not null then
    v_name := coalesce(nullif(trim(v_entry -> 'editor' ->> 'name'), ''), nullif(trim(v_entry ->> 'editor_name'), ''),
                       nullif(trim(v_entry -> 'user' ->> 'name'), ''), nullif(trim(v_entry ->> 'user_name'), ''));
    v_at := coalesce(v_entry ->> 'updated_at', v_entry ->> 'inserted_at', v_entry ->> 'created_at');
    v_via := coalesce(v_entry ->> 'app', v_entry ->> 'source', v_entry ->> 'platform');
  end if;

  if v_name is null then
    v_name := coalesce(nullif(trim(v_order -> 'last_editor' ->> 'name'), ''), nullif(trim(v_order -> 'updated_by' ->> 'name'), ''),
                       nullif(trim(v_order ->> 'last_editor_name'), ''));
  end if;

  return jsonb_build_object('name', v_name, 'at', v_at, 'via', v_via);
end;
$$;

grant execute on function public.staff_get_online_order_last_editor(text, text, text) to anon;
