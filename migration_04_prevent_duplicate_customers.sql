-- ============================================================================
-- Migration 04: Prevent duplicate customer records by email
-- Target: the Supabase project the staff dashboard connects to
--         (casual-leasing-command-centre_1.html)
--
-- Context: 3 identical "Bloom Events Sdn Bhd" customer rows were found,
-- created minutes apart — almost certainly repeat submissions of whatever
-- public inquiry form creates these records (not this dashboard; this
-- dashboard only reads/updates customers, it never creates them). Those 3
-- were manually merged into 1 already. This migration stops it from
-- happening again, going forward.
--
-- HOW IT WORKS: a BEFORE INSERT trigger checks whether the incoming row's
-- email already belongs to an existing customer. If so, it updates that
-- existing row with any new info provided and skips creating a second row.
-- This works no matter what creates the record — this dashboard, a Zapier
-- step, a public form, or a manual SQL insert — since it's enforced at the
-- database level, not in any one piece of client code.
--
-- CAVEAT (read before relying on this): if the code that creates these
-- records does "insert customer, then use the new row's id to insert a
-- booking" in one flow, a genuine repeat submission will now get an EMPTY
-- result back from the customer insert (since the row is redirected into an
-- update instead of created fresh) rather than a normal single-row result.
-- Worth a quick check with whoever owns that intake form/automation.
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
-- ============================================================================

begin;

create or replace function public.merge_duplicate_customer()
returns trigger as $$
declare
  existing_id uuid;
begin
  -- No email on the incoming row -> nothing to match against, let it insert
  -- normally. A blank email isn't a safe identity key (many unrelated
  -- customers could all have none).
  if new.email is null or btrim(new.email) = '' then
    return new;
  end if;

  select id into existing_id
  from public.customers
  where lower(btrim(email)) = lower(btrim(new.email))
  limit 1;

  if existing_id is not null then
    -- Returning customer: update the existing record with whatever new info
    -- came in (non-null incoming fields win), instead of creating a duplicate.
    update public.customers
    set
      name            = coalesce(new.name, name),
      company         = coalesce(new.company, company),
      phone           = coalesce(new.phone, phone),
      address         = coalesce(new.address, address),
      registration_no = coalesce(new.registration_no, registration_no),
      sst_number      = coalesce(new.sst_number, sst_number),
      sst_registered  = new.sst_registered or sst_registered,
      notes           = coalesce(new.notes, notes)
    where id = existing_id;

    return null; -- skip the physical insert — this customer already exists
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_customers_merge_duplicate on public.customers;
create trigger trg_customers_merge_duplicate
before insert on public.customers
for each row execute function public.merge_duplicate_customer();

commit;
