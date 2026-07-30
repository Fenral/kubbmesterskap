-- Turneringen spilles i tre trinn:
-- 1) ordinære puljer, 2) nye A- og B-puljer, 3) ett utslagstre per nivå.

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
  select m.stage, m.grp, m.team_a as team_id,
         case m.result when 'a' then 3 when 'draw' then 1 else 0 end as points,
         (m.result = 'a')::int as wins, (m.result = 'draw')::int as draws,
         (m.result = 'b')::int as losses, coalesce(m.score_a, 0) as kubb_for,
         coalesce(m.score_b, 0) as kubb_against
    from public.kubb_matches m
   where m.stage in ('group', 'a_group', 'b_group')
     and m.status = 'finished' and m.result is not null and m.team_a is not null
  union all
  select m.stage, m.grp, m.team_b,
         case m.result when 'b' then 3 when 'draw' then 1 else 0 end,
         (m.result = 'b')::int, (m.result = 'draw')::int, (m.result = 'a')::int,
         coalesce(m.score_b, 0), coalesce(m.score_a, 0)
    from public.kubb_matches m
   where m.stage in ('group', 'a_group', 'b_group')
     and m.status = 'finished' and m.result is not null and m.team_b is not null
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
    join public.kubb_teams t on t.id = p.team_id
    left join results r on r.stage = p.stage and r.grp = p.grp and r.team_id = p.team_id
   group by p.stage, p.grp, p.team_id, t.name
)
select *, kubb_for - kubb_against as kubb_diff,
       rank() over (
         partition by stage, grp
         order by points desc, wins desc, kubb_for - kubb_against desc, name
       )::int as pos
  from totals;

grant select on public.kubb_standings to anon, authenticated;

-- Intern rundgang-generator.  Den brukes for alle tre gruppetrinnene.
create or replace function public.kubb_make_round_robin(
  p_stage text, p_grp text, p_teams uuid[], p_order_base int, p_label text
) returns int
language plpgsql security definer set search_path = public as $$
declare
  arr uuid[] := p_teams; n int; r int; i int; a uuid; b uuid; tmp uuid; total int := 0;
begin
  n := coalesce(array_length(arr, 1), 0);
  if n < 2 then return 0; end if;
  if n % 2 = 1 then arr := array_append(arr, null::uuid); n := n + 1; end if;

  for r in 1..(n - 1) loop
    for i in 1..(n / 2) loop
      a := arr[i]; b := arr[n + 1 - i];
      if a is null or b is null then continue; end if;
      if (r + i) % 2 = 0 then tmp := a; a := b; b := tmp; end if;
      insert into public.kubb_matches (stage, grp, round, team_a, team_b, order_no, label)
      values (p_stage, p_grp, r, a, b, p_order_base + r * 100 + i,
              p_label || ' – runde ' || r);
      total := total + 1;
    end loop;
    arr := arr[1:1] || arr[n:n] || arr[2:n - 1];
  end loop;
  return total;
end $$;

-- Fyll A med de to beste fra hver ordinær pulje, og B med resten.
create or replace function public.kubb_create_final_groups() returns int
language plpgsql security definer set search_path = public as $$
declare a_teams uuid[]; b_teams uuid[]; total int := 0;
begin
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then
    return 0;
  end if;
  if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then
    return 0;
  end if;

  select coalesce(array_agg(team_id order by grp, pos, name), '{}'::uuid[])
    into a_teams from public.kubb_standings where stage = 'group' and pos <= 2;
  select coalesce(array_agg(s.team_id order by s.grp, s.pos, s.name), '{}'::uuid[])
    into b_teams from public.kubb_standings s
   where s.stage = 'group'
     and s.pos >= greatest(3, (select count(*)::int - 1 from public.kubb_standings x where x.stage = 'group' and x.grp = s.grp));

  total := total + public.kubb_make_round_robin('a_group', 'A', a_teams, 200000, 'A-pulje');
  total := total + public.kubb_make_round_robin('b_group', 'B', b_teams, 300000, 'B-pulje');
  update public.kubb_tournament set phase = 'final_groups', updated_at = now() where id = 1;
  return total;
end $$;

-- Bygg ett seedet utslagstre for A eller B.  Walkovers går automatisk videre.
create or replace function public.kubb_build_pool_bracket(
  p_pool text, p_group_stage text, p_title text, p_order_base int
) returns int
language plpgsql security definer set search_path = public as $$
declare
  n int; sz int; len int; i int; ridx int := 1; mc int; total int := 0;
  teams uuid[] := '{}'; names text[] := '{}'; ord int[]; next_ord int[];
  cur_team uuid[] := '{}'; cur_match uuid[] := '{}'; cur_label text[] := '{}';
  next_team uuid[]; next_match uuid[]; next_label text[];
  ta uuid; tb uuid; ma uuid; mb uuid; new_id uuid; rname text; rlabel text; mlabel text;
  rec record;
begin
  for rec in
    select team_id, name from public.kubb_standings
     where stage = p_group_stage
     order by pos, points desc, kubb_diff desc, name
  loop
    teams := array_append(teams, rec.team_id);
    names := array_append(names, rec.name);
  end loop;
  n := coalesce(array_length(teams, 1), 0);
  if n < 2 then return 0; end if;

  sz := 2;
  while sz < n loop sz := sz * 2; end loop;
  ord := array[1];
  while array_length(ord, 1) < sz loop
    len := array_length(ord, 1); next_ord := '{}';
    for i in 1..len loop
      next_ord := array_append(next_ord, ord[i]);
      next_ord := array_append(next_ord, 2 * len + 1 - ord[i]);
    end loop;
    ord := next_ord;
  end loop;

  for i in 1..sz loop
    if ord[i] <= n then
      cur_team := array_append(cur_team, teams[ord[i]]);
      cur_label := array_append(cur_label, names[ord[i]]);
    else
      cur_team := array_append(cur_team, null::uuid);
      cur_label := array_append(cur_label, 'Walkover');
    end if;
    cur_match := array_append(cur_match, null::uuid);
  end loop;

  while array_length(cur_team, 1) > 1 loop
    mc := array_length(cur_team, 1) / 2;
    rname := case mc when 1 then 'final' when 2 then 'sf' when 4 then 'qf' when 8 then 'r16' else 'r' || (mc * 2) end;
    rlabel := case mc when 1 then 'Finale' when 2 then 'Semifinale' when 4 then 'Kvartfinale'
                   when 8 then 'Åttendedelsfinale' else (mc * 2) || '-delsfinale' end;
    next_team := '{}'::uuid[]; next_match := '{}'::uuid[]; next_label := '{}'::text[];

    for i in 1..mc loop
      ta := cur_team[2 * i - 1]; tb := cur_team[2 * i];
      ma := cur_match[2 * i - 1]; mb := cur_match[2 * i];
      if ma is null and mb is null and (ta is null) <> (tb is null) then
        next_team := array_append(next_team, coalesce(ta, tb));
        next_match := array_append(next_match, null::uuid);
        next_label := array_append(next_label, case when ta is not null then cur_label[2 * i - 1] else cur_label[2 * i] end);
        continue;
      end if;
      new_id := gen_random_uuid();
      mlabel := p_title || ' · ' || rlabel || case when mc > 1 then ' ' || i else '' end;
      insert into public.kubb_matches
        (id, stage, round, slot, label, team_a, team_b, source_a, source_b, order_no)
      values
        (new_id, p_pool || '_' || rname, ridx, i, mlabel, ta, tb,
         cur_label[2 * i - 1], cur_label[2 * i], p_order_base + ridx * 1000 + i);
      total := total + 1;
      if ma is not null then update public.kubb_matches set feeds_match = new_id, feeds_side = 'a' where id = ma; end if;
      if mb is not null then update public.kubb_matches set feeds_match = new_id, feeds_side = 'b' where id = mb; end if;
      next_team := array_append(next_team, null::uuid);
      next_match := array_append(next_match, new_id);
      next_label := array_append(next_label, 'Vinner ' || mlabel);
    end loop;
    cur_team := next_team; cur_match := next_match; cur_label := next_label; ridx := ridx + 1;
  end loop;
  return total;
end $$;

create or replace function public.kubb_create_pool_playoffs() returns int
language plpgsql security definer set search_path = public as $$
declare total int := 0;
begin
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group') and status <> 'finished') then
    return 0;
  end if;
  if exists (select 1 from public.kubb_matches where stage ~ '^[ab]_(r[0-9]+|qf|sf|final)$') then
    return 0;
  end if;
  if exists (select 1 from public.kubb_matches where stage = 'a_group') then
    total := total + public.kubb_build_pool_bracket('a', 'a_group', 'A-sluttspill', 400000);
  end if;
  if exists (select 1 from public.kubb_matches where stage = 'b_group') then
    total := total + public.kubb_build_pool_bracket('b', 'b_group', 'B-sluttspill', 500000);
  end if;
  update public.kubb_tournament set phase = 'knockout', updated_at = now() where id = 1;
  return total;
end $$;

create or replace function public.kubb_finish_match(
  p_code text, p_match uuid, p_result text, p_score_a int default null, p_score_b int default null
) returns void language plpgsql security definer set search_path = public as $$
declare m public.kubb_matches%rowtype;
begin
  perform public.kubb_require(p_code, false);
  if p_result not in ('a', 'b', 'draw') then raise exception 'Ugyldig resultat'; end if;
  select * into m from public.kubb_matches where id = p_match;
  if not found then raise exception 'Fant ikke kampen'; end if;
  if m.stage not in ('group', 'a_group', 'b_group') and p_result = 'draw' then
    raise exception 'Utslagskamper kan ikke ende uavgjort';
  end if;
  update public.kubb_matches
     set status = 'finished', result = p_result, score_a = p_score_a, score_b = p_score_b,
         ended_at = now(), court = null, paused_at = null
   where id = p_match and status <> 'finished';
  if not found then raise exception 'Kampen er allerede avsluttet'; end if;
  perform public.kubb_propagate(p_match);
  if m.stage = 'group' then perform public.kubb_create_final_groups(); end if;
  if m.stage in ('a_group', 'b_group') then perform public.kubb_create_pool_playoffs(); end if;
  perform public.kubb_assign_courts();
end $$;

-- Klienten kaller denne med jevne mellomrom.  Utgåtte gruppekamper blir uavgjort
-- og neste kamp fylles inn på banen uten at arrangøren må trykke noe.
create or replace function public.kubb_finish_expired_matches(p_code text) returns int
language plpgsql security definer set search_path = public as $$
declare total int;
begin
  perform public.kubb_require(p_code, false);
  update public.kubb_matches m
     set status = 'finished', result = 'draw', ended_at = now(), court = null, paused_at = null
    from public.kubb_tournament t
   where m.status = 'live'
     and m.stage in ('group', 'a_group', 'b_group')
     and m.started_at + make_interval(secs => t.match_seconds + m.pause_accum) <= now();
  get diagnostics total = row_count;
  if total > 0 then
    perform public.kubb_create_final_groups();
    perform public.kubb_create_pool_playoffs();
    perform public.kubb_assign_courts();
  end if;
  return total;
end $$;

-- Arrangøren kan bytte ut en kamp som står klar på banen med en annen uspilt kamp.
create or replace function public.kubb_select_court_match(p_code text, p_court int, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare current_match uuid; candidate public.kubb_matches%rowtype; court_count int;
begin
  perform public.kubb_require(p_code, true);
  select num_courts into court_count from public.kubb_tournament where id = 1;
  if p_court is null or p_court < 1 or p_court > court_count then raise exception 'Ugyldig bane'; end if;
  select * into candidate from public.kubb_matches where id = p_match and status = 'queued';
  if not found or candidate.team_a is null or candidate.team_b is null then
    raise exception 'Denne kampen er ikke klar til å settes på bane';
  end if;
  select id into current_match from public.kubb_matches
   where court = p_court and status = 'ready' limit 1;
  if exists (
    select 1 from public.kubb_matches m
     where m.status in ('ready', 'live', 'paused')
       and m.id is distinct from current_match
       and (candidate.team_a in (m.team_a, m.team_b) or candidate.team_b in (m.team_a, m.team_b))
  ) then
    raise exception 'Ett av lagene spiller allerede på en annen bane';
  end if;
  if current_match is not null then
    update public.kubb_matches set status = 'queued', court = null where id = current_match;
  end if;
  update public.kubb_matches set status = 'ready', court = p_court where id = p_match;
  perform public.kubb_assign_courts();
end $$;

-- Manuell fremdrift er også tilgjengelig dersom turneringen er importert midtveis.
create or replace function public.kubb_admin_advance_tournament(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare created_groups int; created_playoffs int;
begin
  perform public.kubb_require(p_code, true);
  if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then
    raise exception 'Det er fortsatt uspilt i første gruppespill';
  end if;
  created_groups := public.kubb_create_final_groups();
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group') and status <> 'finished') then
    perform public.kubb_assign_courts();
    return jsonb_build_object('ok', true, 'phase', 'final_groups', 'matches', created_groups);
  end if;
  created_playoffs := public.kubb_create_pool_playoffs();
  perform public.kubb_assign_courts();
  return jsonb_build_object('ok', true, 'phase', 'knockout', 'matches', created_groups + created_playoffs);
end $$;

revoke execute on function public.kubb_make_round_robin(text, text, uuid[], int, text) from public, anon, authenticated;
revoke execute on function public.kubb_create_final_groups() from public, anon, authenticated;
revoke execute on function public.kubb_build_pool_bracket(text, text, text, int) from public, anon, authenticated;
revoke execute on function public.kubb_create_pool_playoffs() from public, anon, authenticated;
