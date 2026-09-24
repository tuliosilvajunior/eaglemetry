-- Migration: 20260911233000_interval_time_authority_columns.sql
--
-- Time authority T1: the minute gets its monotonic pair and a time state.
--
-- The head unit boots without knowing the time, and 158 of the captain's
-- 15,078 interval rows carry stamps outside the real session window. The
-- monotonic clock (`elapsedRealtimeNanos`) does not lie, so once a trusted
-- wall instant arrives for a boot every earlier minute resolves by exact
-- arithmetic — but only when the minute carries its monotonic reading. The
-- car stores `startElapsedNanos` + `startBootCount` beside `startUtcMillis`
-- (Room migration 44->45); these columns receive them.
--
-- * `start_elapsed_nanos` / `start_boot_count` — nullable, and they stay
--   nullable: every row uploaded before the car wrote the pair has no
--   reading stored anywhere, so it cannot be recovered, and the null says
--   so. The later sweeper back-fills only rows whose pair resolves.
-- * `time_state` — what the time authority believes about the stamp. NOT
--   NULL DEFAULT 'unknown': the detector and sweeper own the rest of the
--   vocabulary, and every row starts by admitting it does not know.
-- * `corrected_from_utc_millis` — the stamp this row carried before the
--   sweeper corrected it. Null means never corrected. The later cloud task
--   needs the original lie beside the fixed stamp to prove the correction
--   moved the minute to the right place.
--
-- Every statement is additive. Nothing is dropped and no row is rewritten.

alter table public."interval"
  add column if not exists start_elapsed_nanos bigint default null,
  add column if not exists start_boot_count bigint default null,
  add column if not exists time_state text not null default 'unknown',
  add column if not exists corrected_from_utc_millis bigint default null;
