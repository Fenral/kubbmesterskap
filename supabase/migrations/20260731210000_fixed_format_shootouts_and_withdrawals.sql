-- Fast turneringsformat: 4x4 -> A1/A2/B1/B2 -> semifinaler, finaler og bronsefinaler.
-- Rangering: poeng -> innbyrdes poeng -> arrangorregistrert straffekast.

alter table public.kubb_tournament
  add column if not exists planned_matches int not null default 0;

alter table public.kubb_teams
  add column if not exists withdrawn_at timestamptz;

create table if not exists public.kubb_tiebreaks (
  stage text not null check (stage in ('group', 'a_group', 'b_group')),
  grp text not null,
  team_id uuid not null references public.kubb_teams(id) on delete cascade,
  shootout_rank int not null check (shootout_rank > 0),
  decided_at timestamptz not null default now(),
  primary key (stage, grp, team_id),
  unique (stage, grp, shootout_rank)
);

alter table public.kubb_tiebreaks enable row level security;
drop policy if exists kubb_tiebreak_read on public.kubb_tiebreaks;
create policy kubb_tiebreak_read on public.kubb_tiebreaks
  for select to anon, authenticated using (true);
grant select on public.kubb_tiebreaks to anon, authenticated;

drop view if exists public.kubb_standings;
create view public.kubb_standings
with (security_invoker = on) as
with participants as (
  select distinct m.stage, m.grp, m.team_a as team_id
    from public.kubb_matches m
   where m.stage in ('group', 'a_group', 'b_group') and m.team_a is not null
  union
  select distinct m.stage, m.grp, m.team_b
    from public.kubb_matches m
   where m.stage in ('group', 'a_group', 'b_group') and m.team_b is not null
), results as (
  select m.stage, m.grp, m.team_a as team_id, m.team_b as opponent_id,
         case m.result when 'a' then 3 when 'draw' then 1 else 0 end as points,
         (m.result = 'a')::int as wins, (m.result = 'draw')::int as draws,
         (m.result = 'b')::int as losses, coalesce(m.score_a, 0) as kubb_for,
         coalesce(m.score_b, 0) as kubb_against
    from public.kubb_matches m
   where m.stage in ('group', 'a_group', 'b_group')
     and m.status = 'finished' and m.result is not null and m.team_a is not null and m.team_b is not null
  union all
  select m.stage, m.grp, m.team_b, m.team_a,
         case m.result when 'b' then 3 when 'draw' then 1 else 0 end,
         (m.result = 'b')::int, (m.result = 'draw')::int, (m.result = 'a')::int,
         coalesce(m.score_b, 0), coalesce(m.score_a, 0)
    from public.kubb_matches m
   where m.stage in ('group', 'a_group', 'b_group')
     and m.status = 'finished' and m.result is not null and m.team_a is not null and m.team_b is not null
), totals as (
  select p.stage, p.grp, p.team_id, t.name,
         coalesce(count(r.team_id), 0)::int as played,
         coalesce(sum(r.wins), 0)::int as wins,
         coalesce(sum(r.draws), 0)::int as draws,
         coalesce(sum(r.losses), 0)::int as losses,
         coalesce(sum(r.points), 0)::int as points,
         coalesce(sum(r.kubb_for), 0)::int as kubb_for,
         coalesce(sum(r.kubb_against), 0)::int as kubb_against
    from participants p
    join public.kubb_teams t on t.id = p.team_id and t.withdrawn_at is null
    left join results r on r.stage = p.stage and r.grp = p.grp and r.team_id = p.team_id
   group by p.stage, p.grp, p.team_id, t.name
), ranked as (
  select t.*,
         coalesce((
           select sum(r.points)::int
             from results r
             join totals opponent
               on opponent.stage = r.stage and opponent.grp = r.grp and opponent.team_id = r.opponent_id
            where r.stage = t.stage and r.grp = t.grp and r.team_id = t.team_id
              and opponent.points = t.points
         ), 0)::int as head_to_head_points
    from totals t
)
select r.*, r.kubb_for - r.kubb_against as kubb_diff,
       tb.shootout_rank,
       row_number() over (
         partition by r.stage, r.grp
         order by r.points desc, r.head_to_head_points desc,
                  coalesce(tb.shootout_rank, 2147483647), r.name
       )::int as pos
  from ranked r
  left join public.kubb_tiebreaks tb
    on tb.stage = r.stage and tb.grp = r.grp and tb.team_id = r.team_id;

grant select on public.kubb_standings to anon, authenticated;

create or replace function public.kubb_clear_tiebreaks_on_match_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.stage in ('group', 'a_group', 'b_group') then
      delete from public.kubb_tiebreaks where stage = old.stage and grp = old.grp;
    end if;
    return old;
  end if;
  if old.stage is distinct from new.stage or old.grp is distinct from new.grp
     or old.team_a is distinct from new.team_a or old.team_b is distinct from new.team_b
     or old.status is distinct from new.status or old.result is distinct from new.result then
    if old.stage in ('group', 'a_group', 'b_group') then
      delete from public.kubb_tiebreaks where stage = old.stage and grp = old.grp;
    end if;
    if new.stage in ('group', 'a_group', 'b_group') then
      delete from public.kubb_tiebreaks where stage = new.stage and grp = new.grp;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists kubb_clear_tiebreaks_after_match_change on public.kubb_matches;
create trigger kubb_clear_tiebreaks_after_match_change
after update of stage, grp, team_a, team_b, status, result or delete on public.kubb_matches
for each row execute function public.kubb_clear_tiebreaks_on_match_change();

revoke execute on function public.kubb_clear_tiebreaks_on_match_change() from public, anon, authenticated;

create or replace function public.kubb_has_unresolved_cutoff_tie(p_stage text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.kubb_standings second_place
      join public.kubb_standings third_place
        on third_place.stage = second_place.stage
       and third_place.grp = second_place.grp
       and third_place.pos = 3
     where second_place.stage = p_stage
       and second_place.pos = 2
       and second_place.points = third_place.points
       and second_place.head_to_head_points = third_place.head_to_head_points
       and (second_place.shootout_rank is null or third_place.shootout_rank is null)
  )
$$;

revoke execute on function public.kubb_has_unresolved_cutoff_tie(text) from public, anon, authenticated;

create or replace function public.kubb_admin_set_tiebreak(
  p_code text, p_stage text, p_grp text, p_teams uuid[]
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_base record; v_cohort uuid[]; v_unique int; rec record;
begin
  perform public.kubb_require(p_code, true);
  if p_stage not in ('group', 'a_group', 'b_group') then raise exception 'Ugyldig gruppespill'; end if;
  if coalesce(cardinality(p_teams), 0) < 2 then raise exception 'Velg minst to lag i rekkefolge'; end if;
  select count(distinct x)::int into v_unique from unnest(p_teams) x;
  if v_unique <> cardinality(p_teams) then raise exception 'Et lag kan bare velges en gang'; end if;

  select s.points, s.head_to_head_points into v_base
    from public.kubb_standings s
   where s.stage = p_stage and s.grp = p_grp and s.team_id = p_teams[1];
  if not found then raise exception 'Fant ikke laget i denne puljen'; end if;

  select array_agg(s.team_id order by s.name) into v_cohort
    from public.kubb_standings s
   where s.stage = p_stage and s.grp = p_grp
     and s.points = v_base.points and s.head_to_head_points = v_base.head_to_head_points;
  if cardinality(v_cohort) <> cardinality(p_teams)
     or exists (select 1 from unnest(v_cohort) x where not (x = any(p_teams))) then
    raise exception 'Alle helt like lag ma tas med i straffekastrekkefolgen';
  end if;

  perform public.kubb_log_admin_action(
    p_code, 'tiebreak', 'Registrerte straffekast i pulje ' || p_grp, null, null, false
  );
  delete from public.kubb_tiebreaks where stage = p_stage and grp = p_grp;
  for rec in select team_id, ordinality::int as rank from unnest(p_teams) with ordinality u(team_id, ordinality) loop
    insert into public.kubb_tiebreaks(stage, grp, team_id, shootout_rank)
    values (p_stage, p_grp, rec.team_id, rec.rank);
  end loop;
  return jsonb_build_object('ok', true, 'count', cardinality(p_teams));
end $$;

grant execute on function public.kubb_admin_set_tiebreak(text, text, text, uuid[]) to anon, authenticated;

create or replace function public.kubb_build_prepared_semifinals(
  p_pool text, p_title text, p_group_1 text, p_group_2 text, p_order_base int
) returns int language plpgsql security definer set search_path = public as $$
declare sf1 uuid; sf2 uuid; final_id uuid; bronze_id uuid;
begin
  if exists (select 1 from public.kubb_matches where stage like p_pool || '\_%' escape '\') then return 0; end if;
  insert into public.kubb_matches(stage, round, slot, label, source_a, source_b, order_no)
  values (p_pool || '_sf', 1, 1, p_title || ' · Semifinale 1',
          '1. ' || p_group_1 || '-pulje', '2. ' || p_group_2 || '-pulje', p_order_base + 1001)
  returning id into sf1;
  insert into public.kubb_matches(stage, round, slot, label, source_a, source_b, order_no)
  values (p_pool || '_sf', 1, 2, p_title || ' · Semifinale 2',
          '1. ' || p_group_2 || '-pulje', '2. ' || p_group_1 || '-pulje', p_order_base + 1002)
  returning id into sf2;
  insert into public.kubb_matches(stage, round, slot, label, source_a, source_b, order_no)
  values (p_pool || '_final', 2, 1, p_title || ' · Finale',
          'Vinner semifinale 1', 'Vinner semifinale 2', p_order_base + 2001)
  returning id into final_id;
  insert into public.kubb_matches(stage, round, slot, label, source_a, source_b, order_no)
  values (p_pool || '_bronze', 2, 1, p_title || ' · Bronsefinale',
          'Taper semifinale 1', 'Taper semifinale 2', p_order_base + 2002)
  returning id into bronze_id;
  update public.kubb_matches
     set feeds_match = final_id, feeds_side = case when id = sf1 then 'a' else 'b' end,
         loser_feeds_match = bronze_id, loser_feeds_side = case when id = sf1 then 'a' else 'b' end
   where id in (sf1, sf2);
  return 4;
end $$;

revoke execute on function public.kubb_build_prepared_semifinals(text, text, text, text, int) from public, anon, authenticated;

create or replace function public.kubb_seed_pool_playoffs() returns boolean
language plpgsql security definer set search_path = public as $$
declare rec record; v_source text; v_count int;
begin
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group') and status <> 'finished') then return false; end if;
  if public.kubb_has_unresolved_cutoff_tie('a_group') or public.kubb_has_unresolved_cutoff_tie('b_group') then return false; end if;
  if not exists (select 1 from public.kubb_matches where stage in ('a_sf', 'b_sf')) then return false; end if;
  if exists (select 1 from public.kubb_matches where stage ~ '^[ab]_(sf|final|bronze)$' and status in ('live', 'paused', 'finished')) then return false; end if;

  update public.kubb_matches
     set team_a = null, team_b = null, status = 'queued', court = null,
         started_at = null, paused_at = null, pause_accum = 0, extra_seconds = 0,
         ended_at = null, result = null, score_a = null, score_b = null, ready_at = null
   where stage ~ '^[ab]_(sf|final|bronze)$';

  for rec in
    select team_id, stage, grp, pos
      from public.kubb_standings
     where stage in ('a_group', 'b_group') and pos <= 2
     order by stage, grp, pos
  loop
    v_source := rec.pos::text || '. ' || rec.grp || '-pulje';
    update public.kubb_matches set team_a = rec.team_id
     where source_a = v_source and stage like case when rec.stage = 'a_group' then 'a_%' else 'b_%' end;
    update public.kubb_matches set team_b = rec.team_id
     where source_b = v_source and stage like case when rec.stage = 'a_group' then 'a_%' else 'b_%' end;
  end loop;
  select count(*)::int into v_count from public.kubb_matches
   where stage in ('a_sf', 'b_sf') and team_a is not null and team_b is not null;
  return v_count = 4;
end $$;

create or replace function public.kubb_create_final_groups() returns int
language plpgsql security definer set search_path = public as $$
declare a1 uuid[]; a2 uuid[]; b1 uuid[]; b2 uuid[]; total int := 0;
begin
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then return 0; end if;
  if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then return 0; end if;
  if public.kubb_has_unresolved_cutoff_tie('group') then return 0; end if;

  select coalesce(array_agg(team_id order by grp, pos, name), '{}'::uuid[]) into a1
    from public.kubb_standings where stage = 'group'
     and ((pos = 1 and grp in ('A','C')) or (pos = 2 and grp in ('B','D')));
  select coalesce(array_agg(team_id order by grp, pos, name), '{}'::uuid[]) into a2
    from public.kubb_standings where stage = 'group'
     and ((pos = 1 and grp in ('B','D')) or (pos = 2 and grp in ('A','C')));
  select coalesce(array_agg(team_id order by grp, pos, name), '{}'::uuid[]) into b1
    from public.kubb_standings where stage = 'group'
     and ((pos = 3 and grp in ('A','C')) or (pos >= 4 and grp in ('B','D')));
  select coalesce(array_agg(team_id order by grp, pos, name), '{}'::uuid[]) into b2
    from public.kubb_standings where stage = 'group'
     and ((pos = 3 and grp in ('B','D')) or (pos >= 4 and grp in ('A','C')));

  total := total + public.kubb_make_round_robin('a_group', 'A1', a1, 200000, 'A1-pulje');
  total := total + public.kubb_make_round_robin('a_group', 'A2', a2, 220000, 'A2-pulje');
  total := total + public.kubb_make_round_robin('b_group', 'B1', b1, 300000, 'B1-pulje');
  total := total + public.kubb_make_round_robin('b_group', 'B2', b2, 320000, 'B2-pulje');
  update public.kubb_tournament set phase = 'final_groups', updated_at = now() where id = 1;
  return total;
end $$;

create or replace function public.kubb_refresh_planned_matches() returns int
language plpgsql security definer set search_path = public as $$
declare first_count int; second_count int; total int; rec record;
begin
  select count(*)::int into first_count from public.kubb_matches where stage = 'group';
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then
    select count(*)::int into second_count from public.kubb_matches where stage in ('a_group', 'b_group');
  else
    second_count := 0;
    for rec in
      select bucket, count(*)::int as n from (
        select case
          when pos <= 2 and ((pos = 1 and grp in ('A','C')) or (pos = 2 and grp in ('B','D'))) then 'A1'
          when pos <= 2 then 'A2'
          when (pos = 3 and grp in ('A','C')) or (pos >= 4 and grp in ('B','D')) then 'B1'
          else 'B2' end as bucket
        from public.kubb_standings where stage = 'group'
      ) allocation group by bucket
    loop
      second_count := second_count + (rec.n * (rec.n - 1) / 2);
    end loop;
  end if;
  total := first_count + second_count + case when first_count > 0 then 8 else 0 end;
  update public.kubb_tournament set planned_matches = total, updated_at = now() where id = 1;
  return total;
end $$;

revoke execute on function public.kubb_refresh_planned_matches() from public, anon, authenticated;

create or replace function public.kubb_admin_set_teams(p_code text, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it jsonb; v_code text; v_id uuid; v_name text; n int := 0; v_role text; v_count int; v_phase text;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase <> 'setup' or exists (select 1 from public.kubb_matches) then
    raise exception 'Laglisten er last etter trekningen. Nullstill turneringen for a begynne pa nytt';
  end if;
  select count(*)::int into v_count from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) x
   where nullif(trim(x->>'name'), '') is not null;
  if v_count <> 16 then raise exception 'Fyll inn alle 16 lag'; end if;
  if exists (
    select 1 from (
      select lower(trim(x->>'name')) as name, count(*) as n
        from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) x
       where nullif(trim(x->>'name'), '') is not null
       group by lower(trim(x->>'name'))
    ) duplicate_names where duplicate_names.n > 1
  ) then raise exception 'Hvert lag ma ha et eget navn'; end if;

  perform public.kubb_log_admin_action(p_code, 'teams', 'Lagret ny lagliste med 16 lag', null, null, false);
  delete from public.kubb_tiebreaks where team_id is not null;
  delete from public.kubb_teams where id is not null;
  delete from public.kubb_codes where team_id is not null;
  for it in select value from jsonb_array_elements(p_teams) loop
    v_name := trim(it->>'name'); n := n + 1;
    loop
      v_code := lpad((100 + floor(random() * 8900))::int::text, 4, '0');
      exit when not exists (select 1 from public.kubb_codes c where c.code = v_code);
    end loop;
    insert into public.kubb_teams(name, grp, seed) values (left(v_name, 40), 'A', n) returning id into v_id;
    v_role := case when n <= 2 then 'admin' else 'team' end;
    insert into public.kubb_codes(code, role, team_id) values (v_code, v_role, v_id);
  end loop;
  update public.kubb_tournament
     set phase = 'setup', planned_matches = 0, drawn_at = null, completed_at = null, updated_at = now()
   where id = 1;
  return jsonb_build_object('ok', true, 'count', 16, 'admin_teams', 2);
end $$;

create or replace function public.kubb_admin_start_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g record; arr uuid[]; group_matches int := 0; playoff_matches int := 0; gi int := 0; v_phase text;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase <> 'setup' or exists (select 1 from public.kubb_matches) then raise exception 'Turneringen er allerede startet'; end if;
  if (select count(*) from public.kubb_teams where withdrawn_at is null) <> 16 then raise exception 'Turneringen krever 16 lag'; end if;
  perform public.kubb_log_admin_action(p_code, 'draw', 'Trakk fire puljer med fire lag', null, null, false);
  for g in select distinct grp from public.kubb_teams where withdrawn_at is null order by grp loop
    gi := gi + 1;
    select coalesce(array_agg(id order by seed, name), '{}'::uuid[]) into arr
      from public.kubb_teams where grp = g.grp and withdrawn_at is null;
    if cardinality(arr) <> 4 then raise exception 'Hver pulje ma ha fire lag'; end if;
    group_matches := group_matches + public.kubb_make_round_robin('group', g.grp, arr, gi * 10000, 'Pulje ' || g.grp);
  end loop;
  playoff_matches := public.kubb_build_prepared_semifinals('a', 'A-sluttspill', 'A1', 'A2', 400000);
  playoff_matches := playoff_matches + public.kubb_build_prepared_semifinals('b', 'B-sluttspill', 'B1', 'B2', 500000);
  update public.kubb_tournament
     set phase = 'group', planned_matches = 56, drawn_at = now(), completed_at = null, updated_at = now()
   where id = 1;
  return jsonb_build_object('ok', true, 'group_matches', group_matches, 'playoff_matches', playoff_matches, 'planned_matches', 56);
end $$;

create or replace function public.kubb_admin_generate_groups(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_count int; v_phase text; v_result jsonb;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase <> 'setup' or exists (select 1 from public.kubb_matches) then raise exception 'Puljene er allerede trukket og er na last'; end if;
  select count(*)::int into v_count from public.kubb_teams where withdrawn_at is null;
  if v_count <> 16 then raise exception 'Puljetrekket krever 16 lag'; end if;
  with draw as (
    select id, row_number() over (order by random())::int as n
      from public.kubb_teams where withdrawn_at is null
  )
  update public.kubb_teams t set grp = chr(65 + ((d.n - 1) / 4)), seed = d.n from draw d where t.id = d.id;
  select public.kubb_admin_start_tournament(p_code) into v_result;
  return v_result || jsonb_build_object('groups', 4, 'group_size', 4);
end $$;

create or replace function public.kubb_admin_phase_action(p_code text, p_action text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_phase text; v_created int; v_seeded boolean;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if p_action = 'close_group' then
    if v_phase <> 'group' then raise exception 'Forste gruppespill kan ikke avsluttes na'; end if;
    if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then raise exception 'Alle kampene i forste gruppespill ma vaere ferdige'; end if;
    if public.kubb_has_unresolved_cutoff_tie('group') then raise exception 'Avgjor straffekast ved kvalifiseringsstreken forst'; end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Avsluttet forste gruppespill', null, null, false);
    update public.kubb_tournament set phase = 'group_review', updated_at = now() where id = 1;
  elsif p_action = 'start_final_groups' then
    if v_phase <> 'group_review' then raise exception 'Kontroller A- og B-lagene forst'; end if;
    if public.kubb_has_unresolved_cutoff_tie('group') then raise exception 'Avgjor straffekast ved kvalifiseringsstreken forst'; end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Startet A1, A2, B1 og B2', null, null, false);
    v_created := public.kubb_create_final_groups();
    if v_created = 0 then raise exception 'Kunne ikke opprette det andre gruppespillet'; end if;
  elsif p_action = 'review_semifinalists' then
    if v_phase <> 'final_groups' then raise exception 'A- og B-gruppespillet pagar ikke'; end if;
    if exists (select 1 from public.kubb_matches where stage in ('a_group','b_group') and status <> 'finished') then raise exception 'Alle kampene i det andre gruppespillet ma vaere ferdige'; end if;
    if public.kubb_has_unresolved_cutoff_tie('a_group') or public.kubb_has_unresolved_cutoff_tie('b_group') then raise exception 'Avgjor straffekast ved semifinalestreken forst'; end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Kontrollerte semifinalister', null, null, false);
    update public.kubb_tournament set phase = 'semifinal_review', updated_at = now() where id = 1;
  elsif p_action = 'start_knockout' then
    if v_phase <> 'semifinal_review' then raise exception 'Kontroller semifinalistene forst'; end if;
    if public.kubb_has_unresolved_cutoff_tie('a_group') or public.kubb_has_unresolved_cutoff_tie('b_group') then raise exception 'Avgjor straffekast ved semifinalestreken forst'; end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Startet A- og B-knockout', null, null, false);
    v_seeded := public.kubb_seed_pool_playoffs();
    if not v_seeded then raise exception 'Kunne ikke fylle semifinalene'; end if;
    update public.kubb_tournament set phase = 'knockout', updated_at = now() where id = 1;
  elsif p_action = 'finish_tournament' then
    if v_phase <> 'knockout' then raise exception 'Knockoutspillet pagar ikke'; end if;
    if (select count(*) from public.kubb_matches where stage ~ '^[ab]_(sf|final|bronze)$' and status = 'finished') <> 8 then
      raise exception 'Alle semifinaler, finaler og bronsefinaler ma vaere ferdige';
    end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Avsluttet turneringen', null, null, false);
    update public.kubb_tournament set phase = 'finished', completed_at = now(), updated_at = now() where id = 1;
  else
    raise exception 'Ukjent fasehandling';
  end if;
  return jsonb_build_object('ok', true, 'phase', (select phase from public.kubb_tournament where id = 1));
end $$;

create or replace function public.kubb_admin_remove_team(p_code text, p_team uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_team public.kubb_teams%rowtype; v_phase text; v_removed int; v_reset boolean := false; v_seeded boolean := false;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase in ('setup', 'finished') then raise exception 'Lag kan bare strykes mens turneringen pagar'; end if;
  select * into v_team from public.kubb_teams where id = p_team and withdrawn_at is null for update;
  if not found then raise exception 'Fant ikke aktivt lag'; end if;
  perform public.kubb_log_admin_action(p_code, 'withdraw', 'Strok laget ' || v_team.name || ' og alle kampene', null, null, false);

  if v_phase = 'knockout' then
    delete from public.kubb_matches where stage ~ '^[ab]_(sf|final|bronze)$';
    v_reset := true;
  end if;
  delete from public.kubb_tiebreaks where team_id = p_team;
  delete from public.kubb_codes where team_id = p_team;
  delete from public.kubb_matches
   where stage in ('group','a_group','b_group') and (team_a = p_team or team_b = p_team);
  get diagnostics v_removed = row_count;
  update public.kubb_teams set withdrawn_at = now() where id = p_team;

  if v_reset then
    perform public.kubb_build_prepared_semifinals('a', 'A-sluttspill', 'A1', 'A2', 400000);
    perform public.kubb_build_prepared_semifinals('b', 'B-sluttspill', 'B1', 'B2', 500000);
    v_seeded := public.kubb_seed_pool_playoffs();
    if not v_seeded then update public.kubb_tournament set phase = 'semifinal_review' where id = 1; end if;
  end if;
  perform public.kubb_refresh_planned_matches();
  return jsonb_build_object('ok', true, 'team', v_team.name, 'matches_removed', v_removed,
                            'knockout_reset', v_reset, 'knockout_seeded', v_seeded);
end $$;

grant execute on function public.kubb_admin_remove_team(text, uuid) to anon, authenticated;
revoke execute on function public.kubb_admin_start_tournament(text) from public, anon, authenticated;

create or replace function public.kubb_admin_reset(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  perform public.kubb_log_admin_action(p_code, 'reset', 'Nullstilte hele turneringen', null, null, false);
  delete from public.kubb_tiebreaks where team_id is not null;
  delete from public.kubb_matches where id is not null;
  delete from public.kubb_teams where id is not null;
  delete from public.kubb_codes where team_id is not null;
  update public.kubb_tournament set phase = 'setup', planned_matches = 0,
         drawn_at = null, completed_at = null, updated_at = now() where id = 1;
end $$;

-- Oppgrader et allerede trukket, men ikke startet, tre uten a berore gruppespillresultater.
do $$
begin
  if not exists (
    select 1 from public.kubb_matches
     where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$' and status in ('ready','live','paused','finished')
  ) then
    delete from public.kubb_matches where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$';
    if exists (select 1 from public.kubb_matches where stage = 'group') then
      perform public.kubb_build_prepared_semifinals('a', 'A-sluttspill', 'A1', 'A2', 400000);
      perform public.kubb_build_prepared_semifinals('b', 'B-sluttspill', 'B1', 'B2', 500000);
      perform public.kubb_refresh_planned_matches();
    end if;
  end if;
end $$;
