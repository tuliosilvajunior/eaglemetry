-- Migration: 20260830120000_drop_sample_table.sql
-- Issue 221 Seam 4: Drop sample table as telemetry is fully served by intervals and tracks.

drop table if exists public.sample cascade;
