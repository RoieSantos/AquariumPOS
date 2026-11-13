// Xendit Payments API calls for QR Ph (channel QRPH): used by xendit-pos-payment and xendit-webhook.
// Docs: https://docs.xendit.co/apidocs/create-payment-request

const XENDIT_API = 'https://api.xendit.co';

function headers(secretKey: string): Record<string, string> {
  return {
    'Authorization': 'Basic ' + btoa(secretKey + ':'),
    'api-version': '2024-11-11',
    'Content-Type': 'application/json'
  };
}

function url(paymentRequestId: string, action = ''): string {
  return `${XENDIT_API}/v3/payment_requests/${encodeURIComponent(paymentRequestId)}${action}`;
}

export async function createQrphRequest(secretKey: string, referenceId: string, amount: number, description: string) {
  const response = await fetch(`${XENDIT_API}/v3/payment_requests`, {
    method: 'POST',
    headers: headers(secretKey),
    body: JSON.stringify({
      reference_id: referenceId,
      type: 'PAY',
      country: 'PH',
      currency: 'PHP',
      request_amount: amount,
      capture_method: 'AUTOMATIC',
      channel_code: 'QRPH',
      description
    })
  });
  const body = await response.json().catch(() => null);
  const qrString = body?.actions?.find((a: any) => a?.descriptor === 'QR_STRING')?.value ?? null;
  return { ok: response.ok && !!body?.payment_request_id && !!qrString, status: response.status, body, qrString };
}

// Returns the payment request, or null when Xendit can't be reached / doesn't answer with one.
export async function readPaymentRequest(secretKey: string, paymentRequestId: string): Promise<any | null> {
  const response = await fetch(url(paymentRequestId), { headers: headers(secretKey) }).catch(() => null);
  const body = await response?.json().catch(() => null);
  return response?.ok && body?.status ? body : null;
}

// Same read, but also says when Xendit answered 404 (no such payment request on this account - e.g. the
// dashboard's "Test and save" sample), so the webhook can acknowledge it instead of asking Xendit to retry.
export async function readPaymentRequestOrNotFound(secretKey: string, paymentRequestId: string): Promise<{ notFound: boolean; request: any | null }> {
  const response = await fetch(url(paymentRequestId), { headers: headers(secretKey) }).catch(() => null);
  if (response?.status === 404) return { notFound: true, request: null };
  const body = await response?.json().catch(() => null);
  return { notFound: false, request: response?.ok && body?.status ? body : null };
}

export async function cancelPaymentRequest(secretKey: string, paymentRequestId: string): Promise<any | null> {
  const response = await fetch(url(paymentRequestId, '/cancel'), { method: 'POST', headers: headers(secretKey) }).catch(() => null);
  const body = await response?.json().catch(() => null);
  return response?.ok && body?.status ? body : null;
}

// Test mode only. The result arrives later: the next read of the payment request / the webhook.
export async function simulatePayment(secretKey: string, paymentRequestId: string, amount: number) {
  const response = await fetch(url(paymentRequestId, '/simulate'), {
    method: 'POST',
    headers: headers(secretKey),
    body: JSON.stringify({ amount })
  });
  const body = await response.json().catch(() => null);
  return { ok: response.ok, status: response.status, body };
}

// In the invoice shape _xendit_record_invoice_status already reads, so a QR Ph payment is recorded the
// same way (once only) as every other Xendit payment. A cancelled / failed request counts as expired.
export function toRecordedInvoice(request: any): Record<string, unknown> {
  const status = String(request?.status ?? '').toUpperCase();
  return {
    id: request.payment_request_id,
    external_id: request.reference_id,
    status: status === 'SUCCEEDED' ? 'PAID'
      : ['CANCELED', 'EXPIRED', 'FAILED'].includes(status) ? 'EXPIRED'
      : status,
    amount: request.request_amount,
    paid_amount: request.request_amount,
    payment_method: 'QR_CODE',
    payment_channel: request.channel_code ?? 'QRPH',
    payment_id: request.latest_payment_id ?? request.payment_request_id,
    paid_at: request.updated ?? null
  };
}
