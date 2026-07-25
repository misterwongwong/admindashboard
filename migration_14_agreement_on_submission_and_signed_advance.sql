-- ============================================================================
-- Migration 14: fire the agreement webhook on customer submission (not staff
-- Accept), and auto-advance a booking to 'confirmed' once the customer signs
-- Target: the Supabase project the staff dashboard connects to (index.html)
--
-- Context: the process was redesigned — there is no staff review gate before
-- the leasing agreement is generated. The agreement auto-fills and goes to
-- the CUSTOMER to sign first, then to management. So:
--
--   1. The webhook that kicks off agreement generation must fire the moment
--      a booking becomes 'submitted' (right when the customer finishes
--      confirm-booking.html), not when staff click Accept in the Submitted
--      tab. The old trigger (fired on submitted -> confirmed) is dropped —
--      leaving it would double-fire if staff ever manually flip a booking to
--      'confirmed' via the status dropdown.
--   2. Once the customer signs (agreements.customer_signed_at gets set by
--      Nabila's/your SignWell-reporting Zap), the booking itself should
--      auto-advance to 'confirmed' — this is what actually moves it out of
--      the "Submitted" tab and into "Agreements" in the dashboard (Submitted
--      filters status = 'submitted'; Agreements shows any booking with an
--      agreements row, regardless of status).
--
-- Also carries migration_13's fixes (trade_name + commencement_date were
-- missing from the payload) since 13 was never applied.
--
-- NOTE: the Submitted tab's Accept button (submitted -> confirmed) still
-- exists in the dashboard but is now semantically stale under this design —
-- flagged separately, not changed by this migration.
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Re-point the agreement-generation webhook to fire on submission.
-- ----------------------------------------------------------------------------
create or replace function public.notify_zapier_on_submission_for_agreement()
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
    'trade_name', new.trade_name,
    'event_type', new.purpose,
    'hub', sp.hub_name,
    'hub_name', sp.hub_name,
    'venue', sp.hub_name,
    'space', sp.name,
    'start_date', new.start_date,
    'end_date', new.end_date,
    'commencement_date', coalesce(new.commencement_date, new.start_date),
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
  values (new.id, 'submission_agreement_requested', payload);

  return new;
end;
$$ language plpgsql security definer set search_path = public, extensions;

-- Drop the old confirmed-on-Accept trigger + function (superseded — would
-- double-fire if a booking is ever manually flipped to 'confirmed').
drop trigger if exists trg_bookings_notify_confirm_submission on public.bookings;
drop function if exists public.notify_zapier_on_confirm_submission();

drop trigger if exists trg_bookings_notify_submission_for_agreement on public.bookings;
create trigger trg_bookings_notify_submission_for_agreement
after update on public.bookings
for each row
when (new.status = 'submitted' and old.status is distinct from 'submitted')
execute function public.notify_zapier_on_submission_for_agreement();

-- ----------------------------------------------------------------------------
-- 2. Auto-advance the booking to 'confirmed' once the customer signs.
-- ----------------------------------------------------------------------------
create or replace function public.advance_booking_on_customer_signed()
returns trigger as $$
begin
  update public.bookings
  set status = 'confirmed', reviewed_at = coalesce(reviewed_at, now())
  where id = new.booking_id and status = 'submitted';

  insert into public.notification_log (booking_id, event, payload)
  values (new.booking_id, 'la_signed_by_customer', jsonb_build_object('agreement_id', new.id));

  return new;
end;
$$ language plpgsql security definer set search_path = public, extensions;

drop trigger if exists trg_agreements_advance_on_customer_signed on public.agreements;
create trigger trg_agreements_advance_on_customer_signed
after update on public.agreements
for each row
when (new.customer_signed_at is not null and old.customer_signed_at is null)
execute function public.advance_booking_on_customer_signed();

commit;
