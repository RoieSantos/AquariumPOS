-- AI Messenger chatbot: look up one item's photo, called by the send_item_image tool
-- (supabase/functions/facebook-messenger-webhook) when a customer confirms they want to see a
-- picture of something they asked about. Per direct request - the bot offers a photo, and only
-- sends one after the customer says yes.
--
-- Deliberately its own narrow RPC rather than reusing public_search_items' existing "images"
-- column - the tool takes a specific item_code (from a prior search_items/list_items_in_category
-- result the bot already has), so this is an exact lookup, and keeps the image URL that actually
-- gets sent to Messenger fully server-controlled: the model only ever passes a code it already saw
-- in a real catalog result, never a URL string itself, so there's no way a crafted/injected message
-- could get the bot to send an arbitrary attacker-supplied image to a customer.

drop function if exists public.public_get_item_image(text);

create or replace function public.public_get_item_image(p_code text)
returns text
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "Images"::text
  from public."Items"
  where "Code" = p_code and "IsActive" is true
  limit 1;
$$;

grant execute on function public.public_get_item_image(text) to anon;
