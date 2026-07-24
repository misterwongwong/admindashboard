-- ============================================================================
-- Migration 03: Per-hub annual KPI targets
-- Target: the Supabase project the staff dashboard connects to
--         (casual-leasing-command-centre_1.html)
--
-- SAFE TO REVIEW-THEN-RUN: idempotent, wrapped in a transaction.
--
-- FISCAL YEAR CONVENTION: this business's fiscal year runs Nov 1 -> Oct 31.
-- A fiscal year is labeled by the calendar year it ENDS in — e.g. "FY2026"
-- means Nov 1, 2025 -> Oct 31, 2026 — so "this year's KPI" lines up with
-- today's actual calendar year rather than feeling a year off. The dashboard's
-- JS applies this same convention when computing "the current fiscal year".
-- ============================================================================

begin;

-- One row per hub per fiscal year, so past years' targets stay on record
-- instead of being overwritten when a new year's KPI is set.
create table if not exists public.hub_kpis (
  id              uuid primary key default gen_random_uuid(),
  hub_id          uuid not null references public.hubs(id) on delete cascade,
  fiscal_year     int not null,
  target_revenue  numeric not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (hub_id, fiscal_year)
);

create index if not exists idx_hub_kpis_hub_id on public.hub_kpis(hub_id);

-- Reuses public.set_updated_at() already created by migration_02.
drop trigger if exists trg_hub_kpis_set_updated_at on public.hub_kpis;
create trigger trg_hub_kpis_set_updated_at
before update on public.hub_kpis
for each row execute function public.set_updated_at();

-- Same posture as migration_01's new tables (booking_documents,
-- notification_log): RLS enabled, anon gets exactly what the dashboard needs.
-- See the SECURITY FLAG in migration_01 — same caveat applies here.
alter table public.hub_kpis enable row level security;

drop policy if exists anon_all_hub_kpis on public.hub_kpis;
create policy anon_all_hub_kpis on public.hub_kpis
  for all to anon using (true) with check (true);

commit;
