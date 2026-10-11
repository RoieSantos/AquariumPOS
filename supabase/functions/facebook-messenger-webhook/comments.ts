// Facebook Page post COMMENT auto-reply - the `feed` webhook field's half of
// facebook-messenger-webhook (index.ts only handles Messenger events itself and hands every
// entry.changes[] item here). Per direct request: every new comment on the Page's posts gets a
// short, human-sounding PUBLIC reply under it, and comments that need a real answer (price,
// availability, how to order, a complaint) also get a PRIVATE reply - a Messenger DM tied to the
// comment (Graph API "private replies": recipient = { comment_id }, ONE message per comment, within
// 7 days, and nothing more until the customer answers it).
//
// Prices/stock/order details are never posted publicly - only in the DM. The DM is written by the
// same Alice persona (buildSystemPrompt) but limited to READ_ONLY_TOOL_NAMES, since there's no real
// PSID until Facebook accepts the private reply. Once it's sent, the comment + DM are logged as a
// normal ChatbotConversations/ChatbotMessages thread under the PSID Facebook hands back, so the GMA
// Conversations inbox shows it and Alice has the context when the customer replies in Messenger.
//
// Requires on the Meta app: the Page subscribed to the `feed` webhook field, and a Page token
// (FACEBOOK_PAGE_ACCESS_TOKEN) carrying pages_read_engagement, pages_read_user_content,
// pages_manage_metadata, pages_manage_engagement and pages_messaging. Log + dedup table and the
// on/off switch: sql/supabase_facebook_comment_auto_reply.sql.

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import type Anthropic from 'npm:@anthropic-ai/sdk@0.124.0';
import { READ_ONLY_TOOL_NAMES, buildCurrentTimeLine, buildSystemPrompt, runChatbotTurn } from '../_shared/chatbot-engine.ts';

// Waits a random 15-40s before replying, so a reply doesn't land the instant someone comments -
// a person on the Page wouldn't answer that fast. Well inside the Edge Function's wall-clock limit.
const MIN_REPLY_DELAY_MS = 15_000;
const MAX_REPLY_DELAY_MS = 40_000;
// One person spamming a post shouldn't run up a reply (and a Claude call) per comment.
const PER_PERSON_WINDOW_MINUTES = 10;
const PER_PERSON_MAX_REPLIES = 4;

export interface FacebookFeedChangeValue {
  item?: string;
  verb?: string;
  comment_id?: string;
  post_id?: string;
  parent_id?: string;
  message?: string;
  photo?: string;
  from?: { id?: string; name?: string };
}

interface CommentReplyPlan {
  public_reply: string | null;
  dm: string | null;
  escalate_reason: string | null;
}

interface HandleCommentParams {
  supabase: SupabaseClient;
  anthropic: Anthropic;
  model: string;
  pageAccessToken: string;
  graphVersion: string;
  storeTimezone: string;
  pageId: string;
  value: FacebookFeedChangeValue;
  broadcast: (psid: string) => Promise<void>;
}

const COMMENT_MODE_RULES = [
  'FACEBOOK COMMENT MODE - this turn is NOT a Messenger chat. Someone commented on one of our Facebook Page posts, and you are writing what the Page posts back. Everything above about the store, products, prices and tone still applies, with these rules on top:',
  '- PUBLIC REPLY (posted under their comment, visible to everyone): sound like a real person from the store, not a bot - short (one or two sentences), warm, casual, in the SAME language/mix the commenter used (English, Tagalog or Taglish). Use their first name naturally when it fits. One emoji at most, and not every time. Vary your wording - never a canned template. Do not start with "Hi [name]! Thank you for your comment".',
  '- NEVER put a price, stock count, order detail, phone number or other personal detail in the PUBLIC reply. If they asked about price/availability/ordering/delivery/location details, or have a complaint, the public reply just says (in their language) that you sent them a message, e.g. "Sent you a PM po!" / "Check your inbox, Maria 😊" - and you write the DM.',
  '- Compliments, emojis, tags of friends, "nice!", etc. get a short friendly public reply only - no DM.',
  '- DM (a private Messenger message, only when the comment needs a real answer or is a complaint): answer it properly like a normal Messenger reply - look up real prices/stock with your tools, never guess. Mention you\'re following up on their comment. It is the ONLY message you can send until they reply, so make it complete and end with a question that invites them to continue. Do not promise to place orders or call them - you can\'t from here.',
  '- Complaints / angry comments: public reply is calm and apologetic and moves it to PM (never argue publicly); write a DM, and set escalate_reason so staff are notified.',
  '- Spam, scams, abusive or meaningless comments: public_reply null, dm null.',
  '- If they ask whether the Page is a bot, answer honestly that it\'s an automated assistant.',
  'Your FINAL answer must be ONLY a JSON object, no other text: {"public_reply": string or null, "dm": string or null, "escalate_reason": string or null}'
].join('\n');

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function graphGet(path: string, fields: string, pageAccessToken: string, graphVersion: string): Promise<Record<string, unknown> | null> {
  try {
    const res = await fetch(`https://graph.facebook.com/${graphVersion}/${path}?fields=${fields}&access_token=${pageAccessToken}`);
    if (!res.ok) {
      console.error(`Graph GET ${path} failed (${res.status}): ${await res.text()}`);
      return null;
    }
    return await res.json();
  } catch (err) {
    console.error(`Graph GET ${path} error:`, err instanceof Error ? err.message : err);
    return null;
  }
}

async function graphPost(path: string, body: unknown, pageAccessToken: string, graphVersion: string): Promise<{ ok: boolean; data: Record<string, unknown> | null; error: string | null }> {
  try {
    const res = await fetch(`https://graph.facebook.com/${graphVersion}/${path}?access_token=${pageAccessToken}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    const data = await res.json().catch(() => null);
    if (!res.ok) return { ok: false, data: null, error: `${res.status}: ${JSON.stringify(data)}` };
    return { ok: true, data, error: null };
  } catch (err) {
    return { ok: false, data: null, error: err instanceof Error ? err.message : String(err) };
  }
}

// The model's final text should be just the JSON object, but tolerate stray text/code fences
// around it. Anything unparseable means NO reply - never post free text that might hold a price.
function parsePlan(text: string): CommentReplyPlan | null {
  const match = text.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try {
    const raw = JSON.parse(match[0]);
    const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : null);
    return { public_reply: str(raw.public_reply), dm: str(raw.dm), escalate_reason: str(raw.escalate_reason) };
  } catch {
    return null;
  }
}

export async function handleFeedComment(params: HandleCommentParams): Promise<void> {
  const { supabase, anthropic, model, pageAccessToken, graphVersion, storeTimezone, pageId, value, broadcast } = params;

  // Only brand-new comments from someone other than the Page itself - the Page's own replies (ours
  // or staff's) come back through this same webhook, and replying to those would loop forever.
  if (value.item !== 'comment' || value.verb !== 'add') return;
  const commentId = value.comment_id;
  const fromId = value.from?.id;
  if (!commentId || !fromId || fromId === pageId) return;
  const commentText = value.message?.trim() || '';
  if (!commentText && !value.photo) return;

  const { data: aiSettings } = await supabase.from('ChatbotAiSettings').select('*').eq('Id', 1).maybeSingle();
  if (aiSettings && aiSettings.CommentAutoReplyEnabled === false) return;

  const postId = value.post_id ?? null;
  const parentId = value.parent_id && value.parent_id !== postId ? value.parent_id : null;
  const fromName = value.from?.name?.trim() || null;

  // Claim the comment - the unique CommentId makes a Facebook redelivery a no-op.
  const { data: claimed } = await supabase
    .from('FacebookPostComments')
    .upsert(
      { CommentId: commentId, PageId: pageId, PostId: postId, ParentId: parentId, FromId: fromId, FromName: fromName, Message: commentText || null, PhotoUrl: value.photo ?? null, Status: 'Processing' },
      { onConflict: 'CommentId', ignoreDuplicates: true }
    )
    .select('CommentId');
  if (!claimed || claimed.length === 0) return;

  const finish = (update: Record<string, unknown>) =>
    supabase.from('FacebookPostComments').update({ ...update, RepliedAtUtc: new Date().toISOString() }).eq('CommentId', commentId);

  const windowStart = new Date(Date.now() - PER_PERSON_WINDOW_MINUTES * 60 * 1000).toISOString();
  const { count: recentReplies } = await supabase
    .from('FacebookPostComments')
    .select('CommentId', { count: 'exact', head: true })
    .eq('FromId', fromId)
    .eq('Status', 'Replied')
    .gte('ReceivedAtUtc', windowStart);
  if ((recentReplies ?? 0) >= PER_PERSON_MAX_REPLIES) {
    await finish({ Status: 'Skipped', Error: 'Too many comments from this person in a short time.' });
    return;
  }

  // One DM per person per post - a second comment in the same thread only gets a public reply.
  const { count: priorDms } = postId
    ? await supabase
      .from('FacebookPostComments')
      .select('CommentId', { count: 'exact', head: true })
      .eq('FromId', fromId)
      .eq('PostId', postId)
      .eq('DmStatus', 'Sent')
    : { count: 0 };
  const dmAllowed = (priorDms ?? 0) === 0;

  const [post, parent] = await Promise.all([
    postId ? graphGet(postId, 'message', pageAccessToken, graphVersion) : Promise.resolve(null),
    parentId ? graphGet(parentId, 'message,from', pageAccessToken, graphVersion) : Promise.resolve(null)
  ]);

  const [{ data: storeInfo }, { data: companyInfo }, { data: followUpSettings }] = await Promise.all([
    supabase.from('ChatbotStoreInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('CompanyInfo').select('*').eq('Id', 1).maybeSingle(),
    supabase.from('ChatbotFollowUpSettings').select('*').eq('Id', 1).maybeSingle()
  ]);

  const systemBlocks = [
    { type: 'text' as const, text: buildSystemPrompt(storeInfo, companyInfo, aiSettings, followUpSettings), cache_control: { type: 'ephemeral' as const } },
    { type: 'text' as const, text: COMMENT_MODE_RULES },
    { type: 'text' as const, text: buildCurrentTimeLine(storeTimezone) }
  ];

  const parentFrom = (parent?.from as { id?: string; name?: string } | undefined) ?? null;
  const contextLines = [
    `Our post: ${typeof post?.message === 'string' && post.message.trim() ? `"${post.message.trim()}"` : '(photo/video post with no caption, or caption unavailable)'}`,
    parent
      ? `Their comment is a reply in a thread under ${parentFrom?.id === pageId ? 'OUR Page\'s earlier reply' : `${parentFrom?.name || 'someone'}'s comment`}: "${String(parent.message ?? '').trim()}"`
      : null,
    `Commenter: ${fromName || '(name unavailable)'}`,
    `Their comment: ${commentText ? `"${commentText}"` : '(no text)'}${value.photo ? ' [they attached a photo/sticker]' : ''}`,
    dmAllowed ? null : 'You already sent this person a DM about this post - set dm to null, public reply only.'
  ].filter(Boolean);

  const effectiveModel = (aiSettings?.AiModel as string | undefined)?.trim() || model;

  let plan: CommentReplyPlan | null = null;
  let rawText = '';
  try {
    rawText = await runChatbotTurn({
      supabase,
      anthropic,
      model: effectiveModel,
      psid: `fb-comment:${commentId}`,
      pageId,
      messages: [{ role: 'user', content: contextLines.join('\n') }],
      followUpSettings,
      aiSettings,
      systemBlocks,
      simulate: false,
      pageAccessToken,
      graphVersion,
      allowedToolNames: READ_ONLY_TOOL_NAMES
    });
    plan = parsePlan(rawText);
  } catch (err) {
    await finish({ Status: 'Failed', Error: `AI error: ${err instanceof Error ? err.message : String(err)}` });
    return;
  }

  if (!plan) {
    await finish({ Status: 'Failed', Error: `Could not read the AI's reply: ${rawText.slice(0, 500)}` });
    return;
  }
  if (!dmAllowed) plan.dm = null;
  if (!plan.public_reply && !plan.dm) {
    await finish({ Status: 'Skipped', Error: 'AI chose not to reply (spam/abusive/meaningless).' });
    return;
  }

  await sleep(MIN_REPLY_DELAY_MS + Math.random() * (MAX_REPLY_DELAY_MS - MIN_REPLY_DELAY_MS));

  const update: Record<string, unknown> = { Status: 'Replied' };
  const errors: string[] = [];

  if (plan.public_reply) {
    const sent = await graphPost(`${commentId}/comments`, { message: plan.public_reply }, pageAccessToken, graphVersion);
    update.PublicReplyText = plan.public_reply;
    update.PublicReplyCommentId = sent.ok ? String(sent.data?.id ?? '') || null : null;
    if (!sent.ok) errors.push(`Public reply failed - ${sent.error}`);
  }

  if (plan.dm) {
    const sent = await graphPost(`${pageId}/messages`, { recipient: { comment_id: commentId }, message: { text: plan.dm } }, pageAccessToken, graphVersion);
    update.DmText = plan.dm;
    update.DmStatus = sent.ok ? 'Sent' : 'Failed';
    if (!sent.ok) errors.push(`DM failed - ${sent.error}`);

    const psid = sent.ok ? String(sent.data?.recipient_id ?? '') : '';
    if (psid) {
      update.Psid = psid;
      await logDmConversation(supabase, psid, pageId, fromName, commentId, commentText, value.photo, post, plan.dm, sent.data?.message_id);
      await broadcast(psid);
    }
  }

  if (plan.escalate_reason) {
    await supabase.rpc('_telegram_send_message', {
      p_text: `Facebook comment needs attention (${fromName || fromId}): ${plan.escalate_reason}\nComment: "${commentText}"`
    });
  }

  if (errors.length > 0) {
    update.Error = errors.join(' | ');
    // Nothing actually reached Facebook - mark it Failed so it doesn't count as a reply.
    if (!update.PublicReplyCommentId && update.DmStatus !== 'Sent') update.Status = 'Failed';
  }
  await finish(update);
}

// Writes the comment (as the customer's opening 'user' turn) and the DM (as Alice's reply) into the
// normal Messenger history, so the GMA inbox shows the thread and Alice's next turn - when the
// customer answers the DM in Messenger - knows what they originally asked.
async function logDmConversation(
  supabase: SupabaseClient,
  psid: string,
  pageId: string,
  fromName: string | null,
  commentId: string,
  commentText: string,
  photo: string | undefined,
  post: Record<string, unknown> | null,
  dmText: string,
  messageId: unknown
): Promise<void> {
  await supabase.from('ChatbotConversations').upsert({ Psid: psid, PageId: pageId }, { onConflict: 'Psid', ignoreDuplicates: true });
  if (fromName) {
    await supabase.from('ChatbotConversations').update({ CustomerName: fromName }).eq('Psid', psid).is('CustomerName', null);
  }

  const postSnippet = typeof post?.message === 'string' && post.message.trim() ? ` (post: "${post.message.trim().slice(0, 120)}")` : '';
  const userContent = `[Commented on our Facebook post${postSnippet}] ${commentText || ''}${photo ? ' [Photo]' : ''}`.trim();
  await supabase.from('ChatbotMessages').insert({ Psid: psid, Role: 'user', Content: userContent, FacebookMessageId: `comment:${commentId}` });
  await supabase.from('ChatbotMessages').insert({
    Psid: psid,
    Role: 'assistant',
    Content: dmText,
    DeliveryStatus: 'Sent',
    ...(typeof messageId === 'string' && messageId ? { FacebookMessageId: messageId } : {})
  });

  const nowIso = new Date().toISOString();
  await supabase
    .from('ChatbotConversations')
    .update({ LastMessageAtUtc: nowIso, LastCustomerMessageAtUtc: nowIso, LastBotMessageAtUtc: nowIso })
    .eq('Psid', psid);
}
