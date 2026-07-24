-- ============================================================================
-- Migration 05: quotations table — allow writes, add a lookup index
-- Target: the Supabase project the staff dashboard connects to
--         (index.html)
--
-- Context: the quotations table already has every column the Zapier
-- integration asked for (booking_id, customer_id, space_id + proper foreign
-- keys back to bookings/customers/spaces, pic_name, company_name, email,
-- contact_no, event_type, preferred_venue, preferred_space, start_date,
-- end_date, weekday_price, weekend_price, weekday_count, weekend_count,
-- subtotal, sst_amount, total_amount, doc_url). It was built out already —
-- either by the colleague or provisioned alongside their Zapier setup.
--
-- THE GAP: Row Level Security is enabled on this table with only a SELECT
-- policy for the anon role. There is no INSERT (or UPDATE) policy, so
-- whatever writes a new quotation record — almost certainly Zapier, using
-- the same public anon key this dashboard uses — would currently be
-- silently blocked from creating or updating a row at all.
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
-- ============================================================================

begin;

create index if not exists idx_quotations_booking_id on public.quotations(booking_id);

-- Same posture as this project's other new tables (booking_documents,
-- hub_kpis): RLS enabled, anon gets full read/write access, since the
-- dashboard and its integrations connect with the public anon key and have
-- no staff-auth layer yet. See the SECURITY FLAG in migration_01 — same
-- caveat applies here.
drop policy if exists anon_select_quotations on public.quotations;
drop policy if exists anon_all_quotations on public.quotations;
create policy anon_all_quotations on public.quotations
  for all to anon using (true) with check (true);

commit;
