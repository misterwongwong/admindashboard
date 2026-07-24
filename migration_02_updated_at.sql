-- ============================================================================
-- Migration 02: bookings.updated_at (auto-maintained by trigger)
-- Needed for the new "All bookings" table's Last updated column.
--
-- Idempotent — safe to run more than once.
-- ============================================================================

begin;

alter table public.bookings add column if not exists updated_at timestamptz;

-- Backfill existing rows from created_at rather than leaving them all at "now()".
update public.bookings set updated_at = coalesce(updated_at, created_at, now());

alter table public.bookings alter column updated_at set default now();
alter table public.bookings alter column updated_at set not null;

-- Auto-bump on every update, regardless of which client makes the change
-- (dashboard, SQL editor, future API) — no app code has to remember to set it.
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_bookings_set_updated_at on public.bookings;
create trigger trg_bookings_set_updated_at
before update on public.bookings
for each row execute function public.set_updated_at();

commit;
