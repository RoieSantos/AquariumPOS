-- Customer Message Timing dashboard (Web Portal, super users only) - per "can we build reporting
-- the timing of messages captured from our GMA conversations... track when customers are
-- messaging us". Same day-of-week/hour-of-day bucketing convention (Asia/Manila local time) as
-- admin_get_order_confirmation_timing (supabase_order_confirmation_timing_rpc.sql), applied to
-- public."ChatbotMessages" (supabase_chatbot_conversations_tables.sql) instead of OnlineOrders.
--
-- Only counts "Role" = 'user' rows - actual inbound messages FROM customers, not the bot's own
-- replies ('assistant') or staff replies sent from GMA Conversations ('staff', see
-- supabase_chatbot_staff_reply.sql).
--
-- Note: ChatbotMessages is trimmed by cron_cleanup_old_chatbot_messages to the last 60 days (see
-- supabase_chatbot_conversations_tables.sql), so this can only ever report on that rolling window -
-- fine for a day/hour pattern (it repeats weekly), not for long-term trend history.

drop function if exists public.admin_get_chatbot_message_timing(text, text, date, date);

create or replace function public.admin_get_chatbot_message_timing(
  p_admin_username text,
  p_admin_password text,
  p_date_from date default null,
  p_date_to date default null
)
returns table(day_of_week int, hour_of_day int, message_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      extract(dow from ("CreatedAtUtc" at time zone 'Asia/Manila'))::int,
      extract(hour from ("CreatedAtUtc" at time zone 'Asia/Manila'))::int,
      count(*)
    from public."ChatbotMessages"
    where "Role" = 'user'
      and (p_date_from is null or ("CreatedAtUtc" at time zone 'Asia/Manila')::date >= p_date_from)
      and (p_date_to is null or ("CreatedAtUtc" at time zone 'Asia/Manila')::date <= p_date_to)
    group by 1, 2;
end;
$$;

grant execute on function public.admin_get_chatbot_message_timing(text, text, date, date) to anon;
