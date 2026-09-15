-- GMA Conversations: lets staff EDIT an existing Quick Reply (supabase_chatbot_quick_replies.sql /
-- supabase_chatbot_quick_reply_images.sql), not just add/delete - per direct request, the pencil
-- icon in the Quick Reply popover header (docs/gma-conversations.html) opens a "Manage Quick
-- Replies" view with Edit actions per row.
--
-- Redefines admin_upsert_chatbot_quick_reply with a new p_remove_image flag so an edit that doesn't
-- touch the photo can leave ImagePath/ImageUrl exactly as they are, without the client having to
-- know/resend the existing storage path. Without this flag there would be no way to distinguish
-- "didn't touch the photo" from "clear the photo" - both send null image fields from the client.
drop function if exists public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text, text, text);

create or replace function public.admin_upsert_chatbot_quick_reply(
  p_admin_username text,
  p_admin_password text,
  p_id bigint,
  p_label text,
  p_message_text text,
  p_image_path text,
  p_image_url text,
  p_remove_image boolean default false
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_message text := nullif(trim(coalesce(p_message_text, '')), '');
  v_image_path text := nullif(trim(coalesce(p_image_path, '')), '');
  v_image_url text := nullif(trim(coalesce(p_image_url, '')), '');
  v_existing_image_url text;
  v_will_have_image boolean;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_label is null or trim(p_label) = '' then
    raise exception 'Label is required.';
  end if;

  if p_id is not null then
    select "ImageUrl" into v_existing_image_url from public."ChatbotQuickReplies" where "Id" = p_id;
  end if;

  -- What the row will actually end up with, after this save - a NEW photo always wins, an explicit
  -- removal always clears it, otherwise whatever was already there (if any) stays.
  v_will_have_image := v_image_url is not null
    or (p_id is not null and not p_remove_image and v_existing_image_url is not null);

  if v_message is null and not v_will_have_image then
    raise exception 'Add a message, a photo, or both.';
  end if;

  if p_id is null then
    insert into public."ChatbotQuickReplies" ("Label", "MessageText", "ImagePath", "ImageUrl", "CreatedBy")
    values (trim(p_label), coalesce(v_message, ''), v_image_path, v_image_url, p_admin_username)
    returning "Id" into v_id;
  else
    update public."ChatbotQuickReplies"
    set "Label" = trim(p_label),
        "MessageText" = coalesce(v_message, ''),
        "ImagePath" = case
          when v_image_url is not null then v_image_path
          when p_remove_image then null
          else "ImagePath"
        end,
        "ImageUrl" = case
          when v_image_url is not null then v_image_url
          when p_remove_image then null
          else "ImageUrl"
        end
    where "Id" = p_id;

    if not found then
      raise exception 'Quick reply not found.';
    end if;
    v_id := p_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text, text, text, boolean) to anon;
