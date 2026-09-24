-- Journeys: one named real-world event, a time window over the sessions.
--
-- Same shape as insight_places: an annotation keyed on the account, never on
-- the vehicle — a holiday is the person's, and the person can own two cars.
-- The membership model is the window alone, so there is no member table and no exclusion list here: which
-- sessions belong is computed when the group is read. The tombstone keeps a
-- stale replica from resurrecting a deletion.

create table public.journeys (
  id text not null,
  account_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  started_at_utc_millis bigint not null,
  ended_at_utc_millis bigint not null,
  note text,
  created_at_utc_millis bigint not null,
  updated_at_utc_millis bigint not null,
  origin text not null,
  deleted_at_utc_millis bigint,
  primary key (account_id, id)
);
