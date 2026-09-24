-- Journeys answer to their owner, like every annotation.

alter table public.journeys enable row level security;

create policy journeys_owner_all on public.journeys
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

grant select, insert, update, delete on public.journeys to authenticated;
