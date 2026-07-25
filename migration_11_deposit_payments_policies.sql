-- ============================================================================
-- Migration 11: anon INSERT + SELECT policies on deposit_payments
-- Target: the Supabase project the customer site + admin dashboard share
--
-- Context: the deposit-payment page (customer uploads their 50% transfer
-- receipt after signing the leasing agreement) needs to write a row into
-- deposit_payments from the browser using the public anon key. That table has
-- RLS enabled but ZERO policies, so every anon insert is currently rejected —
-- the page would silently fail to save. This adds the two policies it needs,
-- mirroring exactly how booking_documents is already set up (anon INSERT so
-- the customer can submit, anon SELECT so the admin dashboard can read the
-- record back to verify it).
--
-- SECURITY NOTE (consistent with the project's existing, already-flagged RLS
-- posture): these are permissive anon policies. A malicious anon caller could
-- insert bogus deposit_payments rows or read existing ones with the public
-- key. Low harm today — `verified` defaults false and an admin confirms each
-- payment manually, so a fake row is inert until a human approves it — but
-- this table should be tightened as part of the broader RLS cleanup that's
-- still pending across the project. No UPDATE policy is added here: marking a
-- payment verified is an admin action that isn't built yet.
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
-- ============================================================================

begin;

alter table public.deposit_payments enable row level security;

drop policy if exists anon_insert_deposit_payments on public.deposit_payments;
create policy anon_insert_deposit_payments
  on public.deposit_payments
  for insert
  to anon
  with check (true);

drop policy if exists anon_select_deposit_payments on public.deposit_payments;
create policy anon_select_deposit_payments
  on public.deposit_payments
  for select
  to anon
  using (true);

commit;
