
-- Flytt hemmeligheter ut av leselige tabeller
create table if not exists public.kubb_codes (
  code text primary key,
  role text not null,            -- 'admin' | 'team'
  team_id uuid references public.kubb_teams(id) on delete cascade
);
alter table public.kubb_codes enable row level security;
-- ingen policies => ingen anon-tilgang. Kun SECURITY DEFINER-funksjoner leser den.

alter table public.kubb_teams drop column if exists code;
alter table public.kubb_tournament drop column if exists admin_code;

-- Sett din egen arrangørkode her før du kjører migrasjonen.
insert into public.kubb_codes (code, role) values ('ENDRE_MEG','admin') on conflict do nothing;
