-- Migration: 20260901120000_device_pairing_and_vehicle_ownership.sql
--
-- Phase 2 Step 1: OAuth 2.0 Device Flow Pairing and Vehicle Ownership.
--
-- The local mDNS/HTTP channel is retired. The cloud becomes the meeting point.
-- The car opens a short-lived pairing channel, shows a user_code, and polls;
-- the signed-in phone claims the code, binding (vehicle_id, account_id) and
-- handing the car a scoped credential.
--
-- Three tables:
--   * device_pairing_sessions — short-lived, single-use code + polling state
--   * vehicle_ownership       — which account owns which vehicle
--   * vehicle_devices         — device credential (token_hash) per vehicle/account
-- Plus:
--   * pairing_claim_attempts  — rate-limit counter for claim (H2)
--   * RPC functions for atomic claim and one-time token delivery (H1/H3)

-- ---------------------------------------------------------------------------
-- 1. device_pairing_sessions — the short-lived pairing channel
-- ---------------------------------------------------------------------------

create table if not exists public.device_pairing_sessions (
  device_code uuid primary key default gen_random_uuid(),
  user_code varchar(8) not null,
  vehicle_id text not null,
  status text not null check (status in ('pending', 'approved', 'rejected', 'expired')) default 'pending',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  approved_by uuid references auth.users (id) on delete set null,
  car_token text
);

create index if not exists device_pairing_sessions_user_code_idx
  on public.device_pairing_sessions (user_code);

create index if not exists device_pairing_sessions_status_expires_idx
  on public.device_pairing_sessions (status, expires_at);

-- ---------------------------------------------------------------------------
-- 2. vehicle_ownership — which account owns which vehicle
-- ---------------------------------------------------------------------------

create table if not exists public.vehicle_ownership (
  id uuid primary key default gen_random_uuid(),
  vehicle_id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (vehicle_id, account_id)
);

create index if not exists vehicle_ownership_account_vehicle_idx
  on public.vehicle_ownership (account_id, vehicle_id);

-- Enforce single active owner per vehicle (H3.1)
create unique index if not exists vehicle_ownership_single_active_owner_idx
  on public.vehicle_ownership (vehicle_id) where revoked_at is null;

-- ---------------------------------------------------------------------------
-- 3. vehicle_devices — scoped device credential per vehicle/account
-- ---------------------------------------------------------------------------

create table if not exists public.vehicle_devices (
  device_id uuid primary key default gen_random_uuid(),
  vehicle_id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
  token_hash text not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index if not exists vehicle_devices_vehicle_token_idx
  on public.vehicle_devices (vehicle_id, token_hash);

-- ---------------------------------------------------------------------------
-- 3b. pairing_claim_attempts — rate limiting for claim (H2)
-- ---------------------------------------------------------------------------

create table if not exists public.pairing_claim_attempts (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references auth.users (id) on delete cascade,
  attempted_at timestamptz not null default now()
);

create index if not exists pairing_claim_attempts_account_time_idx
  on public.pairing_claim_attempts (account_id, attempted_at);

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------

alter table public.device_pairing_sessions enable row level security;
alter table public.vehicle_ownership enable row level security;
alter table public.vehicle_devices enable row level security;
alter table public.pairing_claim_attempts enable row level security;

-- device_pairing_sessions: pairing is mediated by Edge Functions via
-- service_role (bypasses RLS). No direct client SELECT/INSERT is needed.
-- Explicitly deny direct access: enable RLS with no permissive policy for
-- authenticated, so any direct PostgREST call is refused. Service role
-- bypasses RLS and the Edge Function enforces code single-use, expiry and
-- rate-limit.
--
-- We still create an explicit restrictive policy for the approved owner so
-- the table is not left with "no policy" by accident and the intent is
-- readable. The policy allows a user to read only sessions they approved.

drop policy if exists device_pairing_sessions_owner_reads on public.device_pairing_sessions;
create policy device_pairing_sessions_owner_reads on public.device_pairing_sessions
  for select to authenticated
  using (approved_by = (select auth.uid()));

-- No insert/update/delete policies for authenticated: clients must go
-- through the Edge Function (service_role).

-- vehicle_ownership: an account reads its own ownership rows.
-- H3: inserts MUST go through the Edge Function (service_role + RPC), not
-- directly via PostgREST. We keep only select/update for authenticated.

drop policy if exists vehicle_ownership_owner_reads on public.vehicle_ownership;
create policy vehicle_ownership_owner_reads on public.vehicle_ownership
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists vehicle_ownership_owner_inserts on public.vehicle_ownership;
-- Removed: inserts only via Edge Function service_role/RPC (H3.3)

drop policy if exists vehicle_ownership_owner_updates on public.vehicle_ownership;
create policy vehicle_ownership_owner_updates on public.vehicle_ownership
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

-- vehicle_devices: an account reads its own device credentials (token_hash
-- is the hash, never the raw token).

drop policy if exists vehicle_devices_owner_reads on public.vehicle_devices;
create policy vehicle_devices_owner_reads on public.vehicle_devices
  for select to authenticated
  using (account_id = (select auth.uid()));

drop policy if exists vehicle_devices_owner_inserts on public.vehicle_devices;
-- Removed: inserts only via Edge Function service_role/RPC (H3.3)

drop policy if exists vehicle_devices_owner_updates on public.vehicle_devices;
create policy vehicle_devices_owner_updates on public.vehicle_devices
  for update to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

-- pairing_claim_attempts: no direct client access; Edge Function uses service_role.

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------

grant select on public.device_pairing_sessions to authenticated;
-- H3.3: remove insert from authenticated on ownership/devices; Edge Function uses service_role which bypasses RLS and has its own grant
grant select, update on public.vehicle_ownership to authenticated;
grant select, update on public.vehicle_devices to authenticated;
grant select, insert, update on public.vehicle_ownership to service_role;
grant select, insert, update on public.vehicle_devices to service_role;
grant all on public.device_pairing_sessions to service_role;
grant all on public.pairing_claim_attempts to service_role;
grant usage on schema public to authenticated, anon, service_role;

-- Explicitly revoke insert from authenticated if previously granted
revoke insert on public.vehicle_ownership from authenticated;
revoke insert on public.vehicle_devices from authenticated;

-- ---------------------------------------------------------------------------
-- 6. Atomic claim RPC (H3.2) + one-time token+cleanup helpers (H1)
-- ---------------------------------------------------------------------------

-- Atomically: check single-owner, insert ownership, insert device, approve session.
-- Called via service_role from the Edge Function. Security definer so it can
-- bypass RLS. The transaction is atomic — no orphan rows on race.
create or replace function public.claim_pairing_session(
  p_device_code uuid,
  p_vehicle_id text,
  p_account_id uuid,
  p_token_hash text,
  p_car_token text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_existing_owner uuid;
begin
  -- Serialize concurrent claims on the same vehicle.
  perform 1 from public.vehicle_ownership
   where vehicle_id = p_vehicle_id and revoked_at is null
   for update;

  select account_id into v_existing_owner
    from public.vehicle_ownership
   where vehicle_id = p_vehicle_id and revoked_at is null
   limit 1;

  if v_existing_owner is not null and v_existing_owner <> p_account_id then
    return jsonb_build_object('error', 'vehicle_already_claimed');
  end if;

  -- Ensure ownership row exists for claimant (idempotent)
  insert into public.vehicle_ownership (vehicle_id, account_id)
  values (p_vehicle_id, p_account_id)
  on conflict (vehicle_id, account_id) do nothing;

  -- Create device credential
  insert into public.vehicle_devices (vehicle_id, account_id, token_hash)
  values (p_vehicle_id, p_account_id, p_token_hash);

  -- Approve session only if still pending and not expired
  update public.device_pairing_sessions
     set status = 'approved',
         approved_by = p_account_id,
         car_token = p_car_token
   where device_code = p_device_code
     and status = 'pending'
     and expires_at > now();

  if not found then
    select status into v_status from public.device_pairing_sessions where device_code = p_device_code;
    if v_status is null then
      raise exception 'invalid_device_code' using errcode = 'P0001';
    elsif v_status <> 'pending' then
      raise exception 'already_claimed' using errcode = 'P0002';
    else
      raise exception 'expired' using errcode = 'P0003';
    end if;
  end if;

  return jsonb_build_object('ok', true);
exception
  when unique_violation then
    -- Catches partial unique index violation when race slipped past SELECT FOR UPDATE
    select account_id into v_existing_owner
      from public.vehicle_ownership
     where vehicle_id = p_vehicle_id and revoked_at is null and account_id <> p_account_id
     limit 1;
    if v_existing_owner is not null then
      return jsonb_build_object('error', 'vehicle_already_claimed');
    end if;
    return jsonb_build_object('error', 'conflict');
end;
$$;

revoke all on function public.claim_pairing_session(uuid, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.claim_pairing_session(uuid, text, uuid, text, text) to service_role;

-- One-time token delivery: atomically fetch and clear car_token (H1)
create or replace function public.consume_pairing_token(p_device_code uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_token text;
begin
  select car_token into v_token from public.device_pairing_sessions where device_code = p_device_code for update;
  if v_token is not null then
    update public.device_pairing_sessions set car_token = null where device_code = p_device_code;
  end if;
  return v_token;
end;
$$;

revoke all on function public.consume_pairing_token(uuid) from public, anon, authenticated;
grant execute on function public.consume_pairing_token(uuid) to service_role;

-- Cleanup helper for expired sessions: null out car_token for old/expired rows (H1)
create or replace function public.cleanup_expired_pairing_tokens()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  update public.device_pairing_sessions
     set car_token = null
   where car_token is not null
     and expires_at < now() - interval '1 day';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.cleanup_expired_pairing_tokens() from public, anon, authenticated;
grant execute on function public.cleanup_expired_pairing_tokens() to service_role;

-- Also clean stale claim-attempt rows older than 1 hour (housekeeping)
create or replace function public.cleanup_old_claim_attempts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  delete from public.pairing_claim_attempts where attempted_at < now() - interval '1 hour';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.cleanup_old_claim_attempts() from public, anon, authenticated;
grant execute on function public.cleanup_old_claim_attempts() to service_role;

-- ---------------------------------------------------------------------------
-- 7. Tell PostgREST
-- ---------------------------------------------------------------------------

notify pgrst, 'reload schema';
