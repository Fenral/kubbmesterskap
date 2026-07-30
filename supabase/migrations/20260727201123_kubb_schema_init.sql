
-- ============ KUBBMESTERSKAP ============
create table if not exists public.kubb_tournament (
  id int primary key default 1,
  name text not null default 'Kubbmesterskap',
  match_seconds int not null default 2400,
  num_courts int not null default 6,
  phase text not null default 'setup',
  admin_code text not null default '1000',
  qualifiers_per_group int not null default 2,
  updated_at timestamptz not null default now(),
  constraint kubb_single_row check (id = 1)
);

create table if not exists public.kubb_teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  grp text not null default 'A',
  code text not null unique,
  seed int,
  created_at timestamptz not null default now()
);

create table if not exists public.kubb_matches (
  id uuid primary key default gen_random_uuid(),
  stage text not null default 'group',
  grp text,
  round int not null default 1,
  slot int,
  label text,
  team_a uuid references public.kubb_teams(id) on delete cascade,
  team_b uuid references public.kubb_teams(id) on delete cascade,
  source_a text,
  source_b text,
  court int,
  status text not null default 'queued',
  order_no int not null default 0,
  started_at timestamptz,
  paused_at timestamptz,
  pause_accum int not null default 0,
  ended_at timestamptz,
  result text,
  score_a int,
  score_b int,
  feeds_match uuid,
  feeds_side text,
  loser_feeds_match uuid,
  loser_feeds_side text,
  created_at timestamptz not null default now()
);

create index if not exists kubb_matches_status_idx on public.kubb_matches(status, order_no);
create index if not exists kubb_matches_court_idx on public.kubb_matches(court);

insert into public.kubb_tournament (id) values (1) on conflict do nothing;

alter table public.kubb_tournament enable row level security;
alter table public.kubb_teams enable row level security;
alter table public.kubb_matches enable row level security;

drop policy if exists kubb_t_read on public.kubb_tournament;
drop policy if exists kubb_team_read on public.kubb_teams;
drop policy if exists kubb_match_read on public.kubb_matches;

create policy kubb_t_read on public.kubb_tournament for select to anon, authenticated using (true);
create policy kubb_team_read on public.kubb_teams for select to anon, authenticated using (true);
create policy kubb_match_read on public.kubb_matches for select to anon, authenticated using (true);

-- Realtime
alter publication supabase_realtime add table public.kubb_matches;
alter publication supabase_realtime add table public.kubb_teams;
alter publication supabase_realtime add table public.kubb_tournament;
