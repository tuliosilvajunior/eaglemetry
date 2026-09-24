-- Migration: 20260902180000_device_pairing_five_minute_expiry.sql
--
-- Shorten device pairing code lifetime from ten to five minutes.
-- The expiry is decided solely by the database DEFAULT. The edge function
-- (supabase/functions/device-pairing/index.ts) inserts without an
-- expires_at and returns the row's stored value via .select("expires_at")
-- .single(), so there is no second writer to drift from this default.
-- This migration is the single source of truth for the lifetime.

alter table public.device_pairing_sessions
  alter column expires_at set default (now() + interval '5 minutes');
