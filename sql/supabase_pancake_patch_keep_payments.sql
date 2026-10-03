-- Status changes must never lose an order's Pancake payments - per "the payment did not sync over" on
-- order 105852: it showed Amount Paid 501.00 / Paid Via GCASH 501.00, and after it went To Ship
-- (10/3 9:57 AM) Pancake itself had no payment left (Paid Via is read live from Pancake: "No payment
-- yet"), so the portal synced 0.00.
--
-- CAUSE: Pancake's order PATCH wipes bank_payments (GCASH, BDO, ...). _pancake_patch_online_order_status
-- (supabase_pancake_patch_retry.sql) - used by every portal status change (Assigned, To Ship, Shipped,
-- Send Back...) - took a snapshot first and wrote it back after, but both halves could fail silently:
--   - the snapshot GET failing/timing out (8s) just meant "nothing to restore" - the status PATCH went
--     ahead anyway and the payments were gone;
--   - the write-back ignored Pancake's reply: an HTTP error counted as done, and was never retried.
--
-- FIX (same function, same signature - every caller gets it):
--   1. The snapshot is required: up to 2 tries; if Pancake's order can't be read, nothing is sent and the
--      status change fails with a "try again" message (same as when the PATCH itself can't get through).
--   2. The write-back needs a 2xx reply, up to 3 tries with pauses.
--   3. Every snapshot is kept in PancakeBankPaymentSnapshots with whether its write-back worked, so a
--      failed one can be re-applied (_pancake_restore_bank_payments_snapshot) instead of re-typed.
--      A failed write-back does NOT undo the status change (Pancake already has the new status) - check
--      the table: select * from public."PancakeBankPaymentSnapshots" where not "Restored";
--
-- Run AFTER supabase_pancake_patch_retry.sql. Safe to re-run.

create table if not exists public."PancakeBankPaymentSnapshots" (
  "ID" bigserial primary key,
  "OrderID" text not null,
  "BankPayments" jsonb not null,
  "StatusPayload" jsonb,
  "TakenAtUtc" timestamptz not null default now(),
  "Restored" boolean not null default false,
  "RestoreError" text
);

create index if not exists "IX_PancakeBankPaymentSnapshots_OrderID" on public."PancakeBankPaymentSnapshots" ("OrderID", "TakenAtUtc" desc);

alter table public."PancakeBankPaymentSnapshots" enable row level security;
revoke all on public."PancakeBankPaymentSnapshots" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Writes bank_payments back to a Pancake order: up to 3 tries, needs a 2xx. Returns null when it
-- worked, else the last error.
create or replace function public._pancake_put_bank_payments(p_order_id text, p_bank_payments jsonb)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key() || '&page_size=1000';
  v_response extensions.http_response;
  v_error text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
  for i in 1..3 loop
    begin
      select * into v_response from extensions.http((
        'PATCH', v_order_url,
        array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
        'application/json',
        jsonb_build_object('bank_payments', p_bank_payments)::text
      )::extensions.http_request);
      if v_response.status >= 200 and v_response.status < 300 then
        return null;
      end if;
      v_error := format('HTTP %s: %s', v_response.status, left(coalesce(v_response.content, ''), 200));
    exception when others then
      v_error := sqlerrm;
    end;
    if i < 3 then perform pg_sleep(i); end if;
  end loop;
  return v_error;
end;
$$;

revoke execute on function public._pancake_put_bank_payments(text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
create or replace function public._pancake_patch_online_order_status(p_order_id text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key() || '&page_size=1000';
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_snapshot_ok boolean := false;
  v_snapshot_id bigint;
  v_restore_error text;
  v_patch_response extensions.http_response;
  v_attempt int := 0;
  v_max_attempts int := 3;
  v_last_error text;
begin
  -- 8s per call keeps the worst case inside the 60s limit of admin_sync_online_order_assigned_status,
  -- which also sends the customer message afterwards.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

  -- 1. Snapshot bank_payments (Pancake's PATCH wipes them). Required - no snapshot, no PATCH.
  for i in 1..2 loop
    begin
      select * into v_get_response from extensions.http_get(v_order_url);
      if v_get_response.status >= 200 and v_get_response.status < 300 then
        v_get_body := v_get_response.content::jsonb;
        v_order_obj := case
          when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
          when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
          else v_get_body
        end;
        if jsonb_typeof(v_order_obj) = 'object' then
          v_bank_payments := case when jsonb_typeof(v_order_obj -> 'bank_payments') = 'object'
                                  then v_order_obj -> 'bank_payments' end;
          v_snapshot_ok := true;
          exit;
        end if;
      end if;
      v_last_error := format('HTTP %s', v_get_response.status);
    exception when others then
      v_last_error := sqlerrm;
    end;
    if i < 2 then perform pg_sleep(1); end if;
  end loop;

  if not v_snapshot_ok then
    raise exception 'Could not read order % from Pancake to keep its payments (%). Nothing was changed - please try again in a moment.', p_order_id, v_last_error;
  end if;

  if v_bank_payments is not null and v_bank_payments <> '{}'::jsonb then
    insert into public."PancakeBankPaymentSnapshots" ("OrderID", "BankPayments", "StatusPayload")
    values (p_order_id, v_bank_payments, p_payload)
    returning "ID" into v_snapshot_id;
  end if;

  -- 2. The status PATCH (unchanged: up to 3 tries, 5xx retried, 4xx is a real rejection).
  v_last_error := null;
  loop
    v_attempt := v_attempt + 1;
    begin
      select * into v_patch_response from extensions.http((
        'PATCH', v_order_url,
        array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
        'application/json',
        p_payload::text
      )::extensions.http_request);
      exit when v_patch_response.status < 500;
      v_last_error := format('HTTP %s', v_patch_response.status);
    exception when others then
      v_last_error := sqlerrm;
    end;

    if v_attempt >= v_max_attempts then
      raise exception 'Could not reach Pancake after % tries (%). The status was not changed on the portal - please try again in a moment.', v_max_attempts, v_last_error;
    end if;
    perform pg_sleep(v_attempt);
  end loop;

  if v_patch_response.status < 200 or v_patch_response.status >= 300 then
    raise exception 'Pancake rejected the status update (HTTP %).', v_patch_response.status;
  end if;

  -- 3. Put the payments back - checked, retried, and recorded either way.
  if v_snapshot_id is not null then
    v_restore_error := public._pancake_put_bank_payments(p_order_id, v_bank_payments);
    update public."PancakeBankPaymentSnapshots"
    set "Restored" = v_restore_error is null, "RestoreError" = v_restore_error
    where "ID" = v_snapshot_id;
  end if;
end;
$$;

revoke execute on function public._pancake_patch_online_order_status(text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Re-apply a kept snapshot (e.g. one whose write-back failed). Returns null when it worked.
--   select public._pancake_restore_bank_payments_snapshot(<ID>);
create or replace function public._pancake_restore_bank_payments_snapshot(p_snapshot_id bigint)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_snap public."PancakeBankPaymentSnapshots";
  v_error text;
begin
  select * into v_snap from public."PancakeBankPaymentSnapshots" where "ID" = p_snapshot_id;
  if not found then
    raise exception 'Snapshot % not found.', p_snapshot_id;
  end if;
  v_error := public._pancake_put_bank_payments(v_snap."OrderID", v_snap."BankPayments");
  update public."PancakeBankPaymentSnapshots"
  set "Restored" = v_error is null, "RestoreError" = v_error
  where "ID" = p_snapshot_id;
  return v_error;
end;
$$;

revoke execute on function public._pancake_restore_bank_payments_snapshot(bigint) from public, anon, authenticated;
