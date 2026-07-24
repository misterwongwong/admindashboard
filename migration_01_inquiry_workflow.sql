-- ============================================================================
-- Migration 01: Inquiry-to-booking workflow
-- Target: the Supabase project the staff dashboard connects to
--         (casual-leasing-command-centre_1.html)
--
-- SAFE TO REVIEW-THEN-RUN: every statement is idempotent. Running it twice
-- is a no-op. Run the whole thing in the Supabase SQL Editor.
--
-- Wrapped in a single transaction so a failure rolls everything back.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. customers: capture PIC name, company, email, phone as distinct fields
-- ----------------------------------------------------------------------------
-- NOTE ON `pic_name`: your current schema is customers(id, name, company) and
-- the dashboard already renders `customers.name` as the contact person and
-- `customers.company` as the company. So `name` may ALREADY be your PIC name.
-- I'm adding a dedicated `pic_name` column anyway (per your request) but leaving
-- `name` untouched. If `name` was in fact your PIC field, decide whether to
-- backfill pic_name from it (commented-out statement provided) or drop pic_name
-- and keep using `name`. Flagging so you don't end up with two overlapping fields.

alter table public.customers add column if not exists pic_name text;
alter table public.customers add column if not exists email    text;
alter table public.customers add column if not exists phone    text;

-- Optional backfill if `name` has been serving as the PIC/contact person:
-- update public.customers set pic_name = name where pic_name is null;

-- ----------------------------------------------------------------------------
-- 2. bookings: event type, preferred vs confirmed venue, review audit fields
-- ----------------------------------------------------------------------------
-- NOTE ON `event_type` vs `purpose`: the dashboard reads `bookings.purpose` and
-- labels it "Event type". So `purpose` is likely already your event type. I add
-- `event_type` per your request but you probably want to standardise on ONE.
-- Recommendation: keep `purpose`, skip `event_type`. If you prefer `event_type`,
-- uncomment the backfill below and update the dashboard's `b.purpose` reads.

alter table public.bookings add column if not exists event_type text;
-- update public.bookings set event_type = purpose where event_type is null;

-- preferred_* = what the customer ASKED for at inquiry time (space may be null,
-- they might only name a hub). hub_id/space_id stay as the CONFIRMED venue once
-- staff lock it in. Both reference the same parent tables.
alter table public.bookings
  add column if not exists preferred_hub_id uuid references public.hubs(id);
alter table public.bookings
  add column if not exists preferred_space_id uuid references public.spaces(id);

alter table public.bookings add column if not exists rejection_reason text;
alter table public.bookings add column if not exists reviewed_at      timestamptz;
alter table public.bookings add column if not exists reviewed_by      uuid references auth.users(id);

-- ----------------------------------------------------------------------------
-- 3. bookings.status: add 'rejected' to the allowed values
-- ----------------------------------------------------------------------------
-- Your JS uses: inquired, pending, confirmed, completed, cancelled.
-- We recreate the CHECK to add 'rejected'. This assumes the constraint is the
-- Supabase-default name `bookings_status_check`. If yours differs, the DO block
-- below finds and drops ANY check constraint on bookings mentioning 'status',
-- so it works either way. No data is modified.

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
  check (status in ('inquired','pending','confirmed','completed','cancelled','rejected'));

-- ----------------------------------------------------------------------------
-- 4. booking_documents: required docs a customer must submit after acceptance
-- ----------------------------------------------------------------------------
create table if not exists public.booking_documents (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.bookings(id) on delete cascade,
  doc_type    text not null,
  file_url    text,
  uploaded_at timestamptz,
  status      text not null default 'awaiting'
              check (status in ('awaiting','submitted','approved','rejected')),
  created_at  timestamptz not null default now()
);

create index if not exists idx_booking_documents_booking_id
  on public.booking_documents(booking_id);

-- ----------------------------------------------------------------------------
-- 5. notification_log: audit trail of what was sent to Zapier / email
-- ----------------------------------------------------------------------------
create table if not exists public.notification_log (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid references public.bookings(id) on delete set null,
  event      text not null,
  sent_at    timestamptz not null default now(),
  payload    jsonb not null default '{}'::jsonb
);

create index if not exists idx_notification_log_booking_id
  on public.notification_log(booking_id);

-- ----------------------------------------------------------------------------
-- 6. Row Level Security
-- ----------------------------------------------------------------------------
-- The two NEW tables get RLS enabled (Postgres default-denies once enabled).
-- Policies below grant the anon role exactly what the dashboard needs and
-- nothing more. I am NOT touching policies on your existing tables (customers,
-- bookings, spaces, hubs) — see the SECURITY FLAG at the bottom.

alter table public.booking_documents enable row level security;
alter table public.notification_log  enable row level security;

-- booking_documents: staff dashboard reads + writes doc status.
drop policy if exists anon_all_booking_documents on public.booking_documents;
create policy anon_all_booking_documents on public.booking_documents
  for all to anon using (true) with check (true);

-- notification_log: dashboard INSERTs on accept, and reads for the audit trail.
-- No update/delete (it's an append-only log) — 'for select' + 'for insert' only.
drop policy if exists anon_select_notification_log on public.notification_log;
create policy anon_select_notification_log on public.notification_log
  for select to anon using (true);

drop policy if exists anon_insert_notification_log on public.notification_log;
create policy anon_insert_notification_log on public.notification_log
  for insert to anon with check (true);

commit;

-- ============================================================================
-- SECURITY FLAG — READ BEFORE GOING LIVE
-- ============================================================================
-- The anon key is shipped in client-side JS and is PUBLIC. Every policy above
-- (and whatever already lets the dashboard PATCH bookings.status) means anyone
-- who views the page source can read and write these tables directly. That is
-- acceptable for an internal prototype but NOT for production data.
--
-- Before this handles real customer PII / money, move to one of:
--   (a) Supabase Auth: require staff login, change policies from `to anon`
--       to `to authenticated`, and gate writes on the user's role; OR
--   (b) put all writes behind a Supabase Edge Function called with a secret,
--       and give anon read-only (or no) direct table access.
--
-- I have NOT loosened any existing-table policy. If the dashboard currently
-- can't write with the anon key, that's your existing RLS — tell me and I'll
-- write the minimal policy for it rather than opening everything up.
-- ============================================================================
