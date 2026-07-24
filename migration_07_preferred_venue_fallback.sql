-- ============================================================================
-- Migration 07: preferred_venue/preferred_space fall back to the confirmed
-- hub/space when no preference was recorded
-- Target: the Supabase project the staff dashboard connects to (index.html)
--
-- Context: checked the data directly — 0 of 18 bookings have
-- preferred_hub_id/preferred_space_id set at all. The customer-facing intake
-- form only ever writes the exact space picked (space_id), it never captures
-- a separate "what they originally asked for" value. So preferred_venue/
-- preferred_space in the Zapier payload were correctly reflecting NULL, not
-- a bug — there was nothing to report.
--
-- FIX: fall back to the confirmed hub/space name whenever no preference is
-- on record, so the field is always usable rather than blank. If the intake
-- form ever starts capturing a real preference later, that takes priority
-- automatically (coalesce only falls through on NULL).
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction. Replaces the
-- function from migration_06; the trigger itself is unchanged.
-- ============================================================================

begin;

create or replace function public.notify_zapier_on_accept()
returns trigger as $$
declare
  cust record;
  sp record;
  pref_hub_name text;
  pref_space_name text;
  weekday_cnt int;
  weekend_cnt int;
  subtotal_amt numeric;
  sst_amt numeric;
  total_amt numeric;
  duration_days int;
  payload jsonb;
  webhook_url text := 'https://hooks.zapier.com/hooks/catch/28343750/44ffc6f/';
begin
  select * into cust from public.customers where id = new.customer_id;
  select s.*, h.name as hub_name into sp
    from public.spaces s
    left join public.hubs h on h.id = s.hub_id
    where s.id = new.space_id;
  select h.name into pref_hub_name from public.hubs h where h.id = new.preferred_hub_id;
  select s.name into pref_space_name from public.spaces s where s.id = new.preferred_space_id;

  -- No preference on record for this booking -> fall back to the confirmed
  -- hub/space so Zapier always gets a usable value instead of blank.
  pref_hub_name := coalesce(pref_hub_name, sp.hub_name);
  pref_space_name := coalesce(pref_space_name, sp.name);

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
    'guest_name', cust.name,
    'guest_email', cust.email,
    'inquiry_id', new.id,
    'inquiry_details', format(
      '%s at %s / %s, %s to %s (%s day(s)), quotation RM %s',
      new.purpose, sp.hub_name, sp.name, new.start_date, new.end_date, duration_days, total_amt
    ),
    'date', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'booking_id', new.id,
    'pic_name', cust.name,
    'company', cust.company,
    'email', cust.email,
    'phone', cust.phone,
    'event_type', new.purpose,
    'hub', sp.hub_name,
    'space', sp.name,
    'start_date', new.start_date,
    'end_date', new.end_date,
    'duration_days', duration_days,
    'quotation_total', total_amt,
    'currency', 'MYR',
    'customer_id', new.customer_id,
    'space_id', new.space_id,
    'company_name', cust.company,
    'contact_no', cust.phone,
    'preferred_venue', pref_hub_name,
    'preferred_space', pref_space_name,
    'weekday_price', sp.weekday_price,
    'weekend_price', sp.weekend_price,
    'weekday_count', weekday_cnt,
    'weekend_count', weekend_cnt,
    'subtotal', subtotal_amt,
    'sst_amount', sst_amt,
    'total_amount', total_amt
  );

  perform net.http_post(
    url := webhook_url,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := payload
  );

  insert into public.notification_log (booking_id, event, payload)
  values (new.id, 'inquiry_accepted_serverside', payload);

  return new;
end;
$$ language plpgsql security definer set search_path = public, extensions;

commit;
