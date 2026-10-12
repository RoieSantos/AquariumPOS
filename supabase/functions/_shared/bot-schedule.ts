// Messenger bot schedule hours (ChatbotAiSettings.BotScheduleEnabled / BotSchedule, see
// sql/supabase_chatbot_bot_schedule.sql). Shared by facebook-messenger-webhook (live replies +
// auto-resume) and chatbot-followup-dispatcher so all three agree on when the bot may speak.

type ScheduleDay = { on?: boolean; start?: string; end?: string };

function toMinutes(hhmm: string | undefined): number | null {
  const m = /^(\d{2}):(\d{2})$/.exec(hhmm ?? '');
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

// True when the bot may auto-reply right now. Schedule off (or never set) = always on.
// Days are index 0 = Sunday; a window whose end is at/before its start runs past midnight, so
// yesterday's overnight window is checked too.
export function isWithinBotSchedule(aiSettings: Record<string, unknown> | null | undefined, timeZone: string, now = new Date()): boolean {
  if (!aiSettings || aiSettings.BotScheduleEnabled !== true) return true;
  const schedule = aiSettings.BotSchedule as ScheduleDay[] | null | undefined;
  if (!Array.isArray(schedule) || schedule.length !== 7) return true;

  const parts = new Intl.DateTimeFormat('en-US', { timeZone, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? '';
  const day = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(get('weekday'));
  const minute = Number(get('hour')) * 60 + Number(get('minute'));
  if (day < 0) return true;

  const today = schedule[day];
  const yesterday = schedule[(day + 6) % 7];

  const todayStart = toMinutes(today?.start);
  const todayEnd = toMinutes(today?.end);
  if (today?.on && todayStart !== null && todayEnd !== null) {
    if (todayEnd > todayStart ? minute >= todayStart && minute < todayEnd : minute >= todayStart) return true;
  }

  const yStart = toMinutes(yesterday?.start);
  const yEnd = toMinutes(yesterday?.end);
  if (yesterday?.on && yStart !== null && yEnd !== null && yEnd <= yStart && minute < yEnd) return true;

  return false;
}
