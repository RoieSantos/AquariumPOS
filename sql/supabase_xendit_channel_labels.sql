-- Xendit: customer-facing names for the newly offered channels - per "these are all the payment channels
-- activated" (RCBC, Cebuana, LBC added to the non-card checkout in xendit-create-invoice). Without this the
-- Messenger "payment received" message and the receipt page would say "Rcbc Direct Debit" / "Lbc" /
-- "Bpi Direct Debit".
--
-- Same function as supabase_xendit_payment_receipt_message.sql, plus BPI, RCBC, Cebuana and LBC. If that file
-- is ever re-run, run this one again afterwards.
--
-- Run AFTER supabase_xendit_payment_receipt_message.sql. Safe to re-run.

create or replace function public._xendit_channel_label(p_channel text, p_method text)
returns text
language sql
immutable
as $$
  select case upper(coalesce(nullif(p_channel, ''), p_method, ''))
    when 'GCASH' then 'GCash'
    when 'PAYMAYA' then 'Maya'
    when 'MAYA' then 'Maya'
    when 'GRABPAY' then 'GrabPay'
    when 'SHOPEEPAY' then 'ShopeePay'
    when 'QRPH' then 'QR Ph'
    when 'BPI_DIRECT_DEBIT' then 'BPI'
    when 'BPI_ONLINE_BANKING' then 'BPI'
    when 'RCBC_DIRECT_DEBIT' then 'RCBC'
    when 'RCBC_ONLINE_BANKING' then 'RCBC'
    when 'CEBUANA' then 'Cebuana Lhuillier'
    when 'LBC' then 'LBC'
    when 'CREDIT_CARD' then 'card'
    when '' then 'online payment'
    else initcap(replace(lower(coalesce(nullif(p_channel, ''), p_method)), '_', ' '))
  end;
$$;

-- Check - one result.
select code, public._xendit_channel_label(code, null) as label
  from (values ('GCASH'), ('PAYMAYA'), ('GRABPAY'), ('QRPH'), ('BPI_DIRECT_DEBIT'), ('RCBC_DIRECT_DEBIT'), ('CEBUANA'), ('LBC'), ('CREDIT_CARD')) v(code);
