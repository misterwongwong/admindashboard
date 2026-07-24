-- ============================================================================
-- Migration 10: Zapier webhooks for the post-submission review decision
-- Target: the Supabase project the staff dashboard connects to (index.html)
--
-- Context: Phase C added the "Submitted" tab where staff Accept or Reject a
-- customer's completed company-details form + documents. This wires up the
-- two outcomes, same server-side-trigger pattern as migration_06's
-- accept-notification (fires from the database, not the browser, so it can't
-- be blocked by CORS and fires even if staff close the tab right after
-- clicking):
--
--   submitted -> rejected   : sends the customer a rejection email, including
--                             whatever reason staff typed in the dashboard.
--   submitted -> confirmed  : sends everything needed to auto-fill the
--                             leasing agreement template.
--
-- Both triggers use PLACEHOLDER webhook URLs — Nabila hasn't built these two
-- Zaps yet. Once she has, swap REJECT_WEBHOOK_URL / AGREEMENT_WEBHOOK_URL
-- below for the real Catch Hook URLs (one-line change each, no other code
-- affected) and re-run just this file.
--
-- Both triggers are scoped to `old.status = 'submitted'` specifically — not
-- just "whenever a booking becomes rejected/confirmed" — since a booking can
-- also reach 'rejected' straight from 'inquired' (the existing inquiry-stage
-- reject flow, which never had an email and isn't changing here), and manual
-- status overrides via the dashboard's dropdown shouldn't misfire an email
-- meant for the document-review decision specifically.
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Rejection email: submitted -> rejected
-- ----------------------------------------------------------------------------
create or replace function public.notify_zapier_on_reject_submission()
returns trigger as $$
declare
  cust record;
  sp record;
  payload jsonb;
  webhook_url text := 'https://REPLACE-ME.zapier.com/reject-webhook-not-yet-created';
begin
  select * into cust from public.customers where id = new.customer_id;
  select s.*, h.name as hub_name into sp
    from public.spaces s
    left join public.hubs h on h.id = s.hub_id
    where s.id = new.space_id;

  payload := jsonb_build_object(
    'booking_id', new.id,
    'customer_id', new.customer_id,
    'guest_name', cust.name,
    'guest_email', cust.email,
    'company_name', cust.company,
    'contact_no', cust.phone,
    'event_type', new.purpose,
    'hub', sp.hub_name,
    'hub_name', sp.hub_name,
    'venue', sp.hub_name,
    'space', sp.name,
    'start_date', new.start_date,
    'end_date', new.end_date,
    'rejection_reason', new.rejection_reason,
    'date', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  perform net.http_post(
    url := webhook_url,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := payload
  );

  insert into public.notification_log (booking_id, event, payload)
  values (new.id, 'submission_rejected', payload);

  return new;
end;
$$ language plpgsql security definer set search_path = public, extensions;

drop trigger if exists trg_bookings_notify_reject_submission on public.bookings;
create trigger trg_bookings_notify_reject_submission
after update on public.bookings
for each row
when (new.status = 'rejected' and old.status = 'submitted')
execute function public.notify_zapier_on_reject_submission();

-- ----------------------------------------------------------------------------
-- 2. Leasing agreement auto-fill: submitted -> confirmed
-- ----------------------------------------------------------------------------
create or replace function public.notify_zapier_on_confirm_submission()
returns trigger as $$
declare
  cust record;
  sp record;
  weekday_cnt int;
  weekend_cnt int;
  subtotal_amt numeric;
  sst_amt numeric;
  total_amt numeric;
  duration_days int;
  payload jsonb;
  webhook_url text := 'https://REPLACE-ME.zapier.com/leasing-agreement-webhook-not-yet-created';
begin
  select * into cust from public.customers where id = new.customer_id;
  select s.*, h.name as hub_name into sp
    from public.spaces s
    left join public.hubs h on h.id = s.hub_id
    where s.id = new.space_id;

  select
    count(*) filter (where extract(dow from d) not in (0, 6)),
    count(*) filter (where extract(dow from d) in (0, 6))
  into weekday_cnt, weekend_cnt
  from generate_series(new.start_date, new.end_date, interval '1 day') as d;

  weekday_cnt := coalesce(weekday_cnt, 0);
  weekend_cnt := coalesce(weekend_cnt, 0);
  duration_days := weekday_cnt + weekend_cnt;
  subtotal_amt := (weekday_cnt * coalesce(sp.weekday_price, 0)) + (weekend_cnt * coalesce(sp.weekend_price, 0));
  sst_amt := round(subtotal_amt * 0.06, 2);
  total_amt := subtotal_amt + sst_amt;

  payload := jsonb_build_object(
    'booking_id', new.id,
    'customer_id', new.customer_id,
    'guest_name', cust.name,
    'guest_email', cust.email,
    'pic_name', cust.name,
    'contact_no', cust.phone,
    'company_name', cust.company,
    'registration_no', cust.registration_no,
    'tin_number', cust.tin_number,
    'sst_number', cust.sst_number,
    'sst_registered', cust.sst_registered,
    'msic_code', cust.msic_code,
    'einvoice_required', cust.einvoice_required,
    'tax_exempted', cust.tax_exempted,
    'event_type', new.purpose,
    'hub', sp.hub_name,
    'hub_name', sp.hub_name,
    'venue', sp.hub_name,
    'space', sp.name,
    'start_date', new.start_date,
    'end_date', new.end_date,
    'duration_days', duration_days,
    'weekday_price', sp.weekday_price,
    'weekend_price', sp.weekend_price,
    'weekday_count', weekday_cnt,
    'weekend_count', weekend_cnt,
    'subtotal', subtotal_amt,
    'sst_amount', sst_amt,
    'total_amount', total_amt,
    'currency', 'MYR',
    'date', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  perform net.http_post(
    url := webhook_url,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := payload
  );

  insert into public.notification_log (booking_id, event, payload)
  values (new.id, 'submission_confirmed_agreement_requested', payload);

  return new;
end;
$$ language plpgsql security definer set search_path = public, extensions;

drop trigger if exists trg_bookings_notify_confirm_submission on public.bookings;
create trigger trg_bookings_notify_confirm_submission
after update on public.bookings
for each row
when (new.status = 'confirmed' and old.status = 'submitted')
execute function public.notify_zapier_on_confirm_submission();

commit;
