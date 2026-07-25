-- ============================================================================
-- Migration 12: bookings.trade_name (brand / event name for the leasing agreement)
-- Target: the Supabase project the staff dashboard connects to (index.html)
--
-- Context: the leasing agreement template's "Trade Name" field (e.g. "Baqa
-- Bouncy Castle") is the customer's brand/event name for THIS booking — a
-- fact about the event, not a permanent company attribute like TIN/SST/MSIC
-- (which live on `customers` since they don't change between bookings). A
-- repeat customer could run a different-named event each time, so this
-- belongs on `bookings`.
--
-- Filled in by the customer on confirm-booking.html, alongside the other
-- company-details fields — kept as plain nullable text so it can be
-- populated either by direct customer input now, or by a future automation
-- step (e.g. an LLM suggesting/validating it) without a schema change.
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
-- ============================================================================

begin;

alter table public.bookings add column if not exists trade_name text;

commit;
