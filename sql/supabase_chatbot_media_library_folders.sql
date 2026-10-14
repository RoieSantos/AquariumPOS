-- Media Library folders - per "do better ui/ux for this media library.. maybe allow the user to add per
-- folder and individual pictures.. make it user friendly".
--
-- Adds a plain-text "Folder" to ChatbotMediaItems (null = Unsorted). A folder exists as long as it has
-- at least one item in it - no separate folders table. The Conversations media library panel
-- (gmaConversations.js) shows folders as chips, uploads into the open folder (single photos or a whole
-- folder from the computer, which lands in a folder named after it), and can move / delete / pick
-- several items at once.
--
-- Changes:
--   * ChatbotMediaItems."Folder" column (+ index)
--   * admin_add_chatbot_media_item     - new p_folder parameter (old 6-arg overload dropped)
--   * admin_list_chatbot_media_items   - also returns folder
--   * admin_move_chatbot_media_items   - NEW: move several items into a folder (null = Unsorted)
--   * admin_rename_chatbot_media_folder - NEW: rename a folder (or merge into an existing one)
--   * admin_delete_chatbot_media_items - NEW: delete several items at once (DB rows only, same as the
--                                        single delete - Storage objects are left behind on purpose)
-- All gated by is_conversations_authorized (Super User or Conversations Access), same as the live
-- definitions in supabase_gma_conversations_staff_rpc_access.sql.
--
-- Run AFTER supabase_chatbot_media_library.sql and supabase_gma_conversations_staff_rpc_access.sql.
-- Safe to re-run. If supabase_gma_conversations_staff_rpc_access.sql is ever re-run, run this file
-- again afterwards (that file would put back the folder-less add/list functions). Reload the
-- Conversations page after running.

alter table public."ChatbotMediaItems" add column if not exists "Folder" varchar(100);

create index if not exists "IX_ChatbotMediaItems_Folder" on public."ChatbotMediaItems" ("Folder");

-- ---------------------------------------------------------------------------
-- admin_add_chatbot_media_item: + p_folder
drop function if exists public.admin_add_chatbot_media_item(text, text, text, text, text, text);
drop function if exists public.admin_add_chatbot_media_item(text, text, text, text, text, text, text);

create or replace function public.admin_add_chatbot_media_item(
  p_admin_username text,
  p_admin_password text,
  p_storage_path text,
  p_media_url text,
  p_media_type text,
  p_file_name text,
  p_folder text default null
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_media_type text := lower(trim(coalesce(p_media_type, '')));
  v_folder text := left(nullif(trim(coalesce(p_folder, '')), ''), 100);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_storage_path is null or trim(p_storage_path) = '' or p_media_url is null or trim(p_media_url) = '' then
    raise exception 'Storage path/url is required.';
  end if;
  if v_media_type not in ('image', 'video') then
    v_media_type := 'image';
  end if;

  insert into public."ChatbotMediaItems" ("MediaType", "StoragePath", "MediaUrl", "FileName", "CreatedBy", "Folder")
  values (v_media_type, trim(p_storage_path), trim(p_media_url), nullif(trim(coalesce(p_file_name, '')), ''), p_admin_username, v_folder)
  returning "Id" into v_id;

  return v_id;
end;
$$;

grant execute on function public.admin_add_chatbot_media_item(text, text, text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_list_chatbot_media_items: + folder
drop function if exists public.admin_list_chatbot_media_items(text, text);

create or replace function public.admin_list_chatbot_media_items(
  p_admin_username text,
  p_admin_password text
)
returns table(id bigint, media_type text, media_url text, file_name text, created_at_utc timestamptz, folder text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select m."Id", m."MediaType"::text, m."MediaUrl"::text, m."FileName"::text, m."CreatedAtUtc", m."Folder"::text
    from public."ChatbotMediaItems" m
    order by m."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_chatbot_media_items(text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_move_chatbot_media_items: NEW
drop function if exists public.admin_move_chatbot_media_items(text, text, bigint[], text);

create or replace function public.admin_move_chatbot_media_items(
  p_admin_username text,
  p_admin_password text,
  p_media_ids bigint[],
  p_folder text
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count int;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."ChatbotMediaItems"
  set "Folder" = left(nullif(trim(coalesce(p_folder, '')), ''), 100)
  where "Id" = any(coalesce(p_media_ids, '{}'));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_move_chatbot_media_items(text, text, bigint[], text) to anon;

-- ---------------------------------------------------------------------------
-- admin_rename_chatbot_media_folder: NEW - renaming onto an existing folder merges the two.
drop function if exists public.admin_rename_chatbot_media_folder(text, text, text, text);

create or replace function public.admin_rename_chatbot_media_folder(
  p_admin_username text,
  p_admin_password text,
  p_old_folder text,
  p_new_folder text
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_old text := nullif(trim(coalesce(p_old_folder, '')), '');
  v_new text := left(nullif(trim(coalesce(p_new_folder, '')), ''), 100);
  v_count int;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_old is null then
    raise exception 'Folder name is required.';
  end if;

  update public."ChatbotMediaItems" set "Folder" = v_new where "Folder" = v_old;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_rename_chatbot_media_folder(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_delete_chatbot_media_items: NEW - bulk version of admin_delete_chatbot_media_item.
drop function if exists public.admin_delete_chatbot_media_items(text, text, bigint[]);

create or replace function public.admin_delete_chatbot_media_items(
  p_admin_username text,
  p_admin_password text,
  p_media_ids bigint[]
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count int;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."ChatbotMediaItems" where "Id" = any(coalesce(p_media_ids, '{}'));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_delete_chatbot_media_items(text, text, bigint[]) to anon;

notify pgrst, 'reload schema';
