-- Quick replies with our bank / GCash details - per "some quick replies has still our bank accounts / gcash no.
-- sending to the customers.. how can we control it if the xendit is live".
--
--   - ChatbotQuickReplies."HasPaymentDetails" marks a quick reply that gives our account numbers / GCash QR.
--     The first run pre-flags the existing ones by keyword (GCash, BDO, BPI, account no. ...) or a 10+ digit
--     number; super users fix any mistake with the 💳 toggle in Manage Quick Replies.
--   - While Xendit is switched on for customers, Conversations (js/gmaConversations.js ?v=paydetails1) hides
--     flagged quick replies from everyone, and Send refuses a message carrying those numbers or their
--     photos - super users too (?v=paydetails2). Super users still manage them in Manage Quick Replies.
--   - admin_list_chatbot_quick_replies now also returns has_payment_details (body otherwise as in
--     supabase_gma_conversations_staff_rpc_access.sql). If that file is re-run, run this one again.
--
-- Run AFTER supabase_gma_conversations_staff_rpc_access.sql and supabase_chatbot_quick_reply_multi_images.sql.
-- Safe to re-run: the keyword pre-flag only happens the first time, so a super user's toggles are kept.
-- Ends with every quick reply and its flag - check the list.

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'ChatbotQuickReplies' and column_name = 'HasPaymentDetails') then
    alter table public."ChatbotQuickReplies" add column "HasPaymentDetails" boolean not null default false;

    update public."ChatbotQuickReplies" q
       set "HasPaymentDetails" = true
     where coalesce(q."Label", '') || ' ' || coalesce(q."MessageText", '')
           ~* '(g-?cash|maya|bdo|bpi|metrobank|unionbank|landbank|security ?bank|rcbc|china ?bank|eastwest|account (no|num|name|#)|acct|acc\.? ?no|bank details|[0-9]{4}[ -]?[0-9]{3}[ -]?[0-9]{3,})';
  end if;
end;
$$;

drop function if exists public.admin_list_chatbot_quick_replies(text, text);

create or replace function public.admin_list_chatbot_quick_replies(
  p_admin_username text,
  p_admin_password text
)
returns table(id bigint, label text, message_text text, image_urls jsonb, has_payment_details boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      q."Id",
      q."Label"::text,
      q."MessageText"::text,
      coalesce(
        (
          select jsonb_agg(jsonb_build_object('id', i."Id", 'image_url', i."ImageUrl") order by i."SortOrder", i."Id")
          from public."ChatbotQuickReplyImages" i
          where i."QuickReplyId" = q."Id"
        ),
        '[]'::jsonb
      ) as image_urls,
      coalesce(q."HasPaymentDetails", false)
    from public."ChatbotQuickReplies" q
    order by q."SortOrder", q."Id";
end;
$$;

grant execute on function public.admin_list_chatbot_quick_replies(text, text) to anon;

-- Super users only: mark / unmark a quick reply as having our payment details.
create or replace function public.admin_set_chatbot_quick_reply_payment_flag(
  p_admin_username text,
  p_admin_password text,
  p_id bigint,
  p_has_payment_details boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._is_active_super_user(p_admin_username) then
    raise exception 'Only a super user can change this.';
  end if;
  update public."ChatbotQuickReplies" set "HasPaymentDetails" = coalesce(p_has_payment_details, false) where "Id" = p_id;
  if not found then
    raise exception 'Quick reply not found.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_quick_reply_payment_flag(text, text, bigint, boolean) to anon;

notify pgrst, 'reload schema';

-- Check: every quick reply and whether it's flagged. Fix any mistake with the 💳 toggle in Manage Quick Replies.
select q."Id", q."HasPaymentDetails" as has_payment_details, q."Label", left(q."MessageText", 120) as message_start
  from public."ChatbotQuickReplies" q
 order by q."HasPaymentDetails" desc, q."SortOrder", q."Id";
