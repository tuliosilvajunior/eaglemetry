-- Migration: 20260913000000_device_registration_rate_limit.sql
-- Phase 5 Wave 5.1 (P5-T1) — /register rate limiting (per-vehicle and per-IP).
-- Mirrors pairing_claim_attempts shape for pre-claim registration endpoint.

create table if not exists public.device_registration_attempts (
  id uuid primary key default gen_random_uuid(),
  vehicle_id text not null,
  ip text,
  attempted_at timestamptz not null default now()
);

create index if not exists device_registration_attempts_vehicle_time_idx
  on public.device_registration_attempts (vehicle_id, attempted_at);

create index if not exists device_registration_attempts_ip_time_idx
  on public.device_registration_attempts (ip, attempted_at);

alter table public.device_registration_attempts enable row level security;

-- device_registration_attempts: no direct client access; Edge Function uses service_role.
grant all on public.device_registration_attempts to service_role;

create or replace function public.cleanup_old_registration_attempts()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.device_registration_attempts where attempted_at < now() - interval '1 hour';
$$;

grant execute on function public.cleanup_old_registration_attempts() to service_role;
