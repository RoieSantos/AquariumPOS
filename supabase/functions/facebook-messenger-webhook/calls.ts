// Messenger voice/video calls to the Page (Messenger Business Calling API, `calls` webhook field -
// tick it under Webhooks for each Page). NOTIFY ONLY: call routing stays on "Meta", so calls keep
// ringing in Meta Business Suite / the Facebook app and staff answer there - this file never accepts,
// rejects or ends a call, it only tells GMA Conversations about it:
//   connect   -> ChatbotCalls row + 'call_ringing' broadcast (the "📞 ... is calling" banner)
//   terminate -> 'call_ended' broadcast + a "📞 Voice call · 2 min 15 s" / "📞 Missed call" line in
//                the conversation (Role 'user', FacebookMessageId "call:<id>" = redelivery guard)
//
// Payload per Meta's docs (developers.facebook.com/documentation/business-messaging/messenger-
// platform/calling/consumer2biz/call-flow): entry[].calls[] with {id, from, to, event, timestamp,
// call_direction} on connect and {id, event, status, start_time, end_time, duration} on terminate -
// terminate has no caller id, hence the ChatbotCalls lookup by call id. Unconfirmed whether Meta sends
// these while routing is "Meta" rather than "Partners", so every event is logged raw ('Call event').
//
// A missed call also bumps LastCustomerMessageAtUtc so the conversation shows unread; an answered one
// doesn't (staff already spoke to them). Data model: sql/supabase_chatbot_calls.sql.

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

export interface FacebookCallEvent {
  id?: string;
  from?: string;
  to?: string;
  event?: string;
  timestamp?: number;
  call_direction?: string;
  status?: string;
  start_time?: number;
  end_time?: number;
  duration?: number;
}

interface HandleCallParams {
  supabase: SupabaseClient;
  pageId: string;
  call: FacebookCallEvent;
  fetchName: (psid: string) => Promise<string | null>;
  broadcast: (psid: string, event: string, extra: Record<string, unknown>) => Promise<void>;
}

function toIso(seconds: number | undefined): string {
  return seconds ? new Date(seconds * 1000).toISOString() : new Date().toISOString();
}

function formatDuration(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return m ? `${m} min${s ? ` ${s} s` : ''}` : `${s} s`;
}

export async function handleCallEvent(params: HandleCallParams): Promise<void> {
  const { supabase, pageId, call, fetchName, broadcast } = params;
  console.log('Call event', JSON.stringify({ pageId, ...call }));
  if (!call.id) return;

  if (call.event === 'connect') {
    // Only a customer calling the Page - a Page-initiated call has nothing to announce.
    if (call.call_direction && call.call_direction !== 'user_initiated') return;
    const psid = call.from;
    if (!psid) return;

    await supabase.from('ChatbotConversations').upsert({ Psid: psid, PageId: pageId }, { onConflict: 'Psid', ignoreDuplicates: true });
    const { data: conv } = await supabase.from('ChatbotConversations').select('CustomerName').eq('Psid', psid).maybeSingle();
    let customerName = (conv?.CustomerName as string | null) ?? null;
    if (!customerName) {
      customerName = await fetchName(psid);
      if (customerName) await supabase.from('ChatbotConversations').update({ CustomerName: customerName }).eq('Psid', psid);
    }

    const { error } = await supabase.from('ChatbotCalls').insert({
      CallId: call.id, Psid: psid, PageId: pageId, Direction: call.call_direction ?? null, StartedAtUtc: toIso(call.timestamp)
    });
    if (error) {
      if (error.code === '23505') return; // redelivered connect - already announced
      console.error('Failed to record call:', error.message);
    }
    await broadcast(psid, 'call_ringing', { call_id: call.id, page_id: pageId, customer_name: customerName });
    return;
  }

  if (call.event === 'terminate') {
    const { data: row } = await supabase.from('ChatbotCalls').select('Psid, EndedAtUtc').eq('CallId', call.id).maybeSingle();
    if (!row) {
      console.log('Call terminate with no matching connect - ignored', call.id);
      return;
    }
    if (row.EndedAtUtc) return; // redelivered terminate
    const psid = row.Psid as string;
    const duration = Math.max(0, Math.round(Number(call.duration) || 0));
    const answered = duration > 0;
    const endedIso = call.end_time ? toIso(call.end_time) : new Date().toISOString();

    await supabase.from('ChatbotCalls').update({
      EndedAtUtc: endedIso,
      DurationSeconds: duration,
      Status: answered ? 'Answered' : 'Missed',
      FacebookStatus: call.status ?? null
    }).eq('CallId', call.id);

    const { error } = await supabase.from('ChatbotMessages').insert({
      Psid: psid,
      Role: 'user',
      Content: answered ? `📞 Voice call · ${formatDuration(duration)}` : '📞 Missed call',
      FacebookMessageId: `call:${call.id}`,
      CreatedAtUtc: endedIso
    });
    if (error && error.code !== '23505') console.error('Failed to record call line:', error.message);

    await supabase
      .from('ChatbotConversations')
      .update({ LastMessageAtUtc: endedIso, ...(answered ? {} : { LastCustomerMessageAtUtc: endedIso }) })
      .eq('Psid', psid);
    await broadcast(psid, 'call_ended', { call_id: call.id, answered });
  }
}
