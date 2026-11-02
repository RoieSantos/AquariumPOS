// Xendit Payment Sessions (hosted checkout: GCash, Maya, cards, QR Ph, banks...): used by xendit-create-invoice
// and xendit-webhook. Docs: https://docs.xendit.co/apidocs/create-session

const XENDIT_API = 'https://api.xendit.co';

function auth(secretKey: string): Record<string, string> {
  return { 'Authorization': 'Basic ' + btoa(secretKey + ':') };
}

export async function createSession(secretKey: string, session: Record<string, unknown>) {
  const response = await fetch(`${XENDIT_API}/sessions`, {
    method: 'POST',
    headers: { ...auth(secretKey), 'Content-Type': 'application/json' },
    body: JSON.stringify({ session_type: 'PAY', mode: 'PAYMENT_LINK', currency: 'PHP', country: 'PH', capture_method: 'AUTOMATIC', ...session })
  });
  const body = await response.json().catch(() => null);
  return { ok: response.ok && !!body?.payment_session_id && !!body?.payment_link_url, status: response.status, body };
}

export async function readSession(secretKey: string, sessionId: string) {
  const response = await fetch(`${XENDIT_API}/sessions/${encodeURIComponent(sessionId)}`, { headers: auth(secretKey) });
  const body = await response.json().catch(() => null);
  return { ok: response.ok && !!body?.status, status: response.status, body };
}

// Xendit answers 422 when the session is no longer ACTIVE, e.g. it was paid a moment ago.
export async function cancelSession(secretKey: string, sessionId: string) {
  const response = await fetch(`${XENDIT_API}/sessions/${encodeURIComponent(sessionId)}/cancel`, { method: 'POST', headers: auth(secretKey) });
  const body = await response.json().catch(() => null);
  return { ok: response.ok && !!body?.status, status: response.status, body };
}

// In the invoice shape _xendit_record_invoice_status already reads. Only a completed session has a payment,
// which is where the channel comes from; if it can't be read the payment is still recorded, just unnamed.
export async function toRecordedSession(secretKey: string, session: any): Promise<Record<string, unknown>> {
  const status = String(session?.status ?? '').toUpperCase();
  let payment: any = null;
  if (status === 'COMPLETED' && session.payment_id) {
    const response = await fetch(`${XENDIT_API}/v3/payments/${encodeURIComponent(session.payment_id)}`, {
      headers: { ...auth(secretKey), 'api-version': '2024-11-11' }
    }).catch(() => null);
    const body = await response?.json().catch(() => null);
    if (response?.ok) payment = body;
  }
  // CREDIT_CARD is the name the receipts and order payments already show as "card".
  const channel = payment?.channel_code === 'CARDS' ? 'CREDIT_CARD' : (payment?.channel_code ?? null);
  return {
    id: session.payment_session_id,
    external_id: session.reference_id,
    status: status === 'COMPLETED' ? 'PAID' : ['CANCELED', 'EXPIRED'].includes(status) ? 'EXPIRED' : status,
    amount: session.amount,
    paid_amount: session.amount,
    payment_method: channel,
    payment_channel: channel,
    payment_id: session.payment_id ?? session.payment_session_id,
    paid_at: payment?.updated ?? session.updated ?? null
  };
}
