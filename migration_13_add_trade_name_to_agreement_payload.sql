-- ============================================================================
-- Migration 13: add trade_name to the leasing-agreement webhook payload
-- Target: the Supabase project the staff dashboard connects to (index.html)
--
-- Context: migration_10's confirm-submission trigger was written before
-- bookings.trade_name existed (migration_12). Without this fix, the payload
-- Zapier/SignWell receives on Accept would have no way to fill the Trade
-- Name field in the leasing agreement template.
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
-- ============================================================================

begin;

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
  values (new.id, 'submission_confirmed_agreement_requested', payload);

  return new;
end;
$$ language plpgsql security definer set search_path = public, extensions;

commit;
