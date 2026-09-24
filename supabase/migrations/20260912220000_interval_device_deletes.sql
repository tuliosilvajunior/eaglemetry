-- Migration: 20260912220000_interval_device_deletes.sql
--
-- Time authority T9: the corrected re-upload deletes EXACTLY the keys the
-- car rewrote, AFTER the corrected row lands (insert first, delete after).
-- The delete sees a row already in the table, so it demands the same clauses
-- as select/update: the token's vehicle AND the token's account must match.
-- A vehicle-scoped delete from another account (or from a pre-claim
-- credential after a claim backfilled) is refused by RLS — that refusal is
-- proved in car_direct_upload_rls.sql.

grant delete on public."interval" to anon;

drop policy if exists interval_device_deletes on public."interval";
create policy interval_device_deletes on public."interval"
  for delete to anon
  using (
    car_device_identity_from_header()->>'vehicle_id' = vehicle_id
    and account_id is not distinct from (car_device_identity_from_header()->>'account_id')::uuid
  );

notify pgrst, 'reload schema';
