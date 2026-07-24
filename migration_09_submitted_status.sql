-- ============================================================================
-- Migration 09: 'submitted' booking status + supporting columns
-- Target: the Supabase project the staff dashboard connects to (index.html)
--
-- Context: the customer-facing flow (confirm-booking.html) currently jumps
-- straight from the company-details/document-upload form to status
-- 'confirmed' — skipping any staff review of what was submitted. This adds
-- a new stage in between:
--
--   inquired -> pending -> submitted -> confirmed / rejected
--            (staff accepts   (customer fills   (staff reviews docs,
--             the inquiry)     form + uploads)   makes the final call)
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. bookings.status: add 'submitted' to the allowed values
-- ----------------------------------------------------------------------------
-- Same approach as migration_01's 'rejected' addition — finds whichever
-- check constraint governs status (works regardless of its actual name) and
-- recreates it with 'submitted' added. No data is modified.
do $$
declare
  c record;
begin
  for c in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
    where nsp.nspname = 'public'
      and rel.relname = 'bookings'
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%status%'
  loop
    execute format('alter table public.bookings drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.bookings
  add constraint bookings_status_check
  check (status in ('inquired','pending','submitted','confirmed','completed','cancelled','rejected'));

-- ----------------------------------------------------------------------------
-- 2. bookings.submitted_at: when the customer completed the company-details
--    + document-upload form (mirrors the existing reviewed_at column, which
--    marks when staff accepted the original inquiry).
-- ----------------------------------------------------------------------------
alter table public.bookings add column if not exists submitted_at timestamptz;

-- ----------------------------------------------------------------------------
-- 3. agreements.doc_url: where the auto-generated leasing agreement document
--    lands once Phase D's Zapier automation creates it. Same naming
--    convention as quotations.doc_url.
-- ----------------------------------------------------------------------------
alter table public.agreements add column if not exists doc_url text;

commit;
