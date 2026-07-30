-- KILKAST: fire første puljer med 3-4 lag, deretter én A-pulje og én
-- B-pulje. Begge sluttspilltrærne blir synlige allerede ved puljetrekket.

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
       row_number() over (
         partition by stage, grp
         order by points desc, wins desc, kubb_for - kubb_against desc, name
       )::int as pos
  from totals;

grant select on public.kubb_standings to anon, authenticated;

-- Seksten felt vises i klienten. Tomme felt ignoreres, men 12-16 lag holder
-- alle første puljer på minst tre lag.
create or replace function public.kubb_admin_set_teams(p_code text, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it jsonb; v_code text; v_id uuid; v_name text; n int := 0; v_role text; v_count int;
begin
  perform public.kubb_require(p_code, true);

  select count(*)::int into v_count
    from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) x
   where nullif(trim(x->>'name'), '') is not null;
  if v_count < 12 or v_count > 16 then
    raise exception 'Legg inn mellom 12 og 16 lag';
  end if;
  if exists (
    select 1
      from (
        select lower(trim(x->>'name')) as name, count(*) as n
          from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) x
         where nullif(trim(x->>'name'), '') is not null
         group by lower(trim(x->>'name'))
      ) duplicates
     where duplicates.n > 1
  ) then
    raise exception 'Hvert lag må ha et eget navn';
  end if;

  delete from public.kubb_matches;
  delete from public.kubb_teams;
  delete from public.kubb_codes where role = 'team';

  for it in select value from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) loop
    v_name := nullif(trim(it->>'name'), '');
    if v_name is null then continue; end if;
    n := n + 1;
    loop
      v_code := lpad((100 + floor(random() * 8900))::int::text, 4, '0');
      exit when not exists (select 1 from public.kubb_codes c where c.code = v_code);
    end loop;
    insert into public.kubb_teams (name, grp, seed)
      values (left(v_name, 40), 'A', n)
      returning id into v_id;
    v_role := case when n <= 2 then 'admin' else 'team' end;
    insert into public.kubb_codes (code, role, team_id) values (v_code, v_role, v_id);
  end loop;

  update public.kubb_tournament set phase = 'setup', updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'count', n, 'admin_teams', least(n, 2));
end $$;

-- Bygger et tomt, men komplett, sluttspilltre. Felt som har walkover føres
-- direkte til neste runde, slik at også B-sluttspillet fungerer med 4-7 lag.
create or replace function public.kubb_build_prepared_pool_bracket(
  p_pool text, p_size int, p_title text, p_order_base int
) returns int
language plpgsql security definer set search_path = public as $$
declare
  sz int := 2; len int; i int; ridx int := 1; mc int; total int := 0;
  ord int[] := array[1]; next_ord int[];
  cur_label text[] := '{}'; cur_match uuid[] := '{}';
  next_label text[]; next_match uuid[];
  ma uuid; mb uuid; new_id uuid; rname text; rlabel text; mlabel text;
  sf uuid[] := '{}'; bronze uuid;
begin
  if p_size < 2 then return 0; end if;
  if exists (select 1 from public.kubb_matches where stage like p_pool || '_%') then return 0; end if;
  while sz < p_size loop sz := sz * 2; end loop;

  while coalesce(array_length(ord, 1), 0) < sz loop
    len := array_length(ord, 1); next_ord := '{}';
    for i in 1..len loop
      next_ord := array_append(next_ord, ord[i]);
      next_ord := array_append(next_ord, 2 * len + 1 - ord[i]);
    end loop;
    ord := next_ord;
  end loop;

  for i in 1..sz loop
    cur_label := array_append(cur_label,
      case when ord[i] <= p_size then ord[i]::text || '. ' || upper(p_pool) || '-pulje' else 'Walkover' end
    );
    cur_match := array_append(cur_match, null::uuid);
  end loop;

  while array_length(cur_label, 1) > 1 loop
    mc := array_length(cur_label, 1) / 2;
    rname := case mc when 1 then 'final' when 2 then 'sf' when 4 then 'qf' when 8 then 'r16' else 'r' || (mc * 2) end;
    rlabel := case mc when 1 then 'Finale' when 2 then 'Semifinale' when 4 then 'Kvartfinale'
                   when 8 then 'Åttendedelsfinale' else (mc * 2) || '-delsfinale' end;
    next_label := '{}'::text[]; next_match := '{}'::uuid[];

    for i in 1..mc loop
      ma := cur_match[2 * i - 1]; mb := cur_match[2 * i];
      if ma is null and mb is null and (cur_label[2 * i - 1] = 'Walkover') <> (cur_label[2 * i] = 'Walkover') then
        next_label := array_append(next_label, case when cur_label[2 * i - 1] <> 'Walkover' then cur_label[2 * i - 1] else cur_label[2 * i] end);
        next_match := array_append(next_match, null::uuid);
        continue;
      end if;

      new_id := gen_random_uuid();
      mlabel := p_title || ' · ' || rlabel || case when mc > 1 then ' ' || i else '' end;
      insert into public.kubb_matches
        (id, stage, round, slot, label, source_a, source_b, order_no)
      values
        (new_id, p_pool || '_' || rname, ridx, i, mlabel,
         nullif(cur_label[2 * i - 1], 'Walkover'), nullif(cur_label[2 * i], 'Walkover'),
         p_order_base + ridx * 1000 + i);
      total := total + 1;
      if ma is not null then update public.kubb_matches set feeds_match = new_id, feeds_side = 'a' where id = ma; end if;
      if mb is not null then update public.kubb_matches set feeds_match = new_id, feeds_side = 'b' where id = mb; end if;
      if rname = 'sf' then sf := array_append(sf, new_id); end if;
      next_label := array_append(next_label, 'Vinner ' || mlabel);
      next_match := array_append(next_match, new_id);
    end loop;
    cur_label := next_label; cur_match := next_match; ridx := ridx + 1;
  end loop;

  if array_length(sf, 1) = 2 then
    insert into public.kubb_matches (stage, round, slot, label, source_a, source_b, order_no)
      values (p_pool || '_bronze', ridx, 1, p_title || ' · Bronsefinale', 'Taper semifinale 1', 'Taper semifinale 2', p_order_base + ridx * 1000)
      returning id into bronze;
    update public.kubb_matches set loser_feeds_match = bronze, loser_feeds_side = 'a' where id = sf[1];
    update public.kubb_matches set loser_feeds_match = bronze, loser_feeds_side = 'b' where id = sf[2];
    total := total + 1;
  end if;
  return total;
end $$;

-- Legger de ferdige plasseringene fra A- og B-puljene inn i treet. Kilder
-- med "Vinner ..." er allerede koblet videre med feeds_match.
create or replace function public.kubb_seed_pool_playoffs() returns boolean
language plpgsql security definer set search_path = public as $$
declare rec record; v_source text;
begin
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group') and status <> 'finished') then
    return false;
  end if;
  if not exists (select 1 from public.kubb_matches where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$') then
    return false;
  end if;
  if exists (select 1 from public.kubb_matches where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$' and status in ('live', 'paused', 'finished')) then
    return false;
  end if;

  update public.kubb_matches
     set team_a = null, team_b = null, status = 'queued', court = null,
         started_at = null, paused_at = null, pause_accum = 0,
         ended_at = null, result = null, score_a = null, score_b = null
   where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$';

  for rec in
    select team_id, stage, pos
      from public.kubb_standings
     where stage in ('a_group', 'b_group')
     order by stage, pos
  loop
    v_source := rec.pos::text || '. ' || case when rec.stage = 'a_group' then 'A' else 'B' end || '-pulje';
    update public.kubb_matches set team_a = rec.team_id where source_a = v_source and stage like case when rec.stage = 'a_group' then 'a_%' else 'b_%' end;
    update public.kubb_matches set team_b = rec.team_id where source_b = v_source and stage like case when rec.stage = 'a_group' then 'a_%' else 'b_%' end;
  end loop;
  return true;
end $$;

-- Etter første gruppespill går de to beste fra hver pulje til A. Resten går
-- til B, slik at trelags-puljer gir ett lag til B og firelags-puljer gir to.
create or replace function public.kubb_create_final_groups() returns int
language plpgsql security definer set search_path = public as $$
declare a_teams uuid[]; b_teams uuid[]; total int := 0;
begin
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then return 0; end if;
  if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then return 0; end if;

  select coalesce(array_agg(team_id order by grp, pos, name), '{}'::uuid[])
    into a_teams from public.kubb_standings where stage = 'group' and pos <= 2;
  select coalesce(array_agg(team_id order by grp, pos, name), '{}'::uuid[])
    into b_teams from public.kubb_standings where stage = 'group' and pos > 2;

  total := total + public.kubb_make_round_robin('a_group', 'A', a_teams, 200000, 'A-pulje');
  total := total + public.kubb_make_round_robin('b_group', 'B', b_teams, 300000, 'B-pulje');
  update public.kubb_tournament set phase = 'final_groups', updated_at = now() where id = 1;
  return total;
end $$;

create or replace function public.kubb_create_pool_playoffs() returns int
language plpgsql security definer set search_path = public as $$
declare seeded boolean;
begin
  seeded := public.kubb_seed_pool_playoffs();
  if seeded then
    update public.kubb_tournament set phase = 'knockout', updated_at = now() where id = 1;
  end if;
  return 0;
end $$;

-- Et rettferdig trekk gir A-D, med tre eller fire lag per pulje.
create or replace function public.kubb_admin_generate_groups(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_count int; v_base int; v_extra int;
begin
  perform public.kubb_require(p_code, true);
  select count(*) into v_count from public.kubb_teams;
  if v_count < 12 or v_count > 16 then raise exception 'Puljetrekket krever mellom 12 og 16 lag'; end if;
  v_base := v_count / 4;
  v_extra := mod(v_count, 4);

  with draw as (
    select id, row_number() over (order by random())::int as n from public.kubb_teams
  )
  update public.kubb_teams t
     set grp = chr(65 + case
                 when v_extra > 0 and d.n <= (v_base + 1) * v_extra
                   then ((d.n - 1) / (v_base + 1))
                 else v_extra + ((d.n - ((v_base + 1) * v_extra) - 1) / v_base)
               end),
         seed = d.n
    from draw d
   where t.id = d.id;

  perform public.kubb_admin_start_tournament(p_code);
  return jsonb_build_object('ok', true, 'groups', 4, 'small_group_size', v_base, 'large_group_size', v_base + case when v_extra > 0 then 1 else 0 end);
end $$;

create or replace function public.kubb_admin_start_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g record; arr uuid[]; group_matches int := 0; playoff_matches int := 0; gi int := 0; v_count int;
begin
  perform public.kubb_require(p_code, true);
  delete from public.kubb_matches;

  for g in select distinct grp from public.kubb_teams order by grp loop
    gi := gi + 1;
    select coalesce(array_agg(id order by seed, name), '{}'::uuid[]) into arr
      from public.kubb_teams where grp = g.grp;
    group_matches := group_matches + public.kubb_make_round_robin('group', g.grp, arr, gi * 10000, 'Pulje ' || g.grp);
  end loop;
  select count(*) into v_count from public.kubb_teams;
  playoff_matches := public.kubb_build_prepared_pool_bracket('a', 8, 'A-sluttspill', 400000);
  playoff_matches := playoff_matches + public.kubb_build_prepared_pool_bracket('b', v_count - 8, 'B-sluttspill', 500000);
  update public.kubb_tournament set phase = 'group', updated_at = now() where id = 1;
  perform public.kubb_assign_courts();
  return jsonb_build_object('ok', true, 'group_matches', group_matches, 'playoff_matches', playoff_matches);
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
    raise exception 'Sluttspillkamper kan ikke ende uavgjort';
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

create or replace function public.kubb_finish_expired_matches(p_code text) returns int
language plpgsql security definer set search_path = public as $$
declare total int;
begin
  perform public.kubb_require(p_code, false);
  update public.kubb_matches m
     set status = 'finished', result = 'draw', ended_at = now(), court = null, paused_at = null
    from public.kubb_tournament t
   where m.status = 'live' and m.stage in ('group', 'a_group', 'b_group')
     and m.started_at + make_interval(secs => t.match_seconds + m.pause_accum) <= now();
  get diagnostics total = row_count;
  if total > 0 then
    perform public.kubb_create_final_groups();
    perform public.kubb_create_pool_playoffs();
    perform public.kubb_assign_courts();
  end if;
  return total;
end $$;

create or replace function public.kubb_admin_correct_result(
  p_code text, p_match uuid, p_result text, p_score_a int default null, p_score_b int default null
) returns void language plpgsql security definer set search_path = public as $$
declare m public.kubb_matches%rowtype;
begin
  perform public.kubb_require(p_code, true);
  select * into m from public.kubb_matches where id = p_match;
  if not found or m.status <> 'finished' then raise exception 'Kampen er ikke ferdigspilt'; end if;
  if p_result not in ('a', 'b', 'draw') then raise exception 'Ugyldig resultat'; end if;
  if m.stage not in ('group', 'a_group', 'b_group') and p_result = 'draw' then
    raise exception 'Sluttspillkamper kan ikke ende uavgjort';
  end if;
  if m.stage = 'group' and exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then
    raise exception 'Første gruppespill kan ikke endres etter at A- og B-puljene er laget';
  end if;
  if m.stage in ('a_group', 'b_group') and exists (
    select 1 from public.kubb_matches
     where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$' and status in ('live', 'paused', 'finished')
  ) then
    raise exception 'A- eller B-gruppespill kan ikke endres etter at sluttspillet har startet';
  end if;
  if m.feeds_match is not null and exists (
    select 1 from public.kubb_matches where id = m.feeds_match and status in ('live', 'paused', 'finished')
  ) then
    raise exception 'Endre eller nullstill den påfølgende kampen først';
  end if;

  update public.kubb_matches
     set result = p_result, score_a = p_score_a, score_b = p_score_b, ended_at = now()
   where id = p_match;
  perform public.kubb_propagate(p_match);
  if m.stage in ('a_group', 'b_group') then perform public.kubb_create_pool_playoffs(); end if;
  perform public.kubb_assign_courts();
end $$;

create or replace function public.kubb_admin_advance_tournament(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare created_groups int; created_playoffs int;
begin
  perform public.kubb_require(p_code, true);
  created_groups := public.kubb_create_final_groups();
  created_playoffs := public.kubb_create_pool_playoffs();
  perform public.kubb_assign_courts();
  return jsonb_build_object('ok', true, 'matches', created_groups + created_playoffs);
end $$;

revoke execute on function public.kubb_build_prepared_pool_bracket(text, int, text, int) from public, anon, authenticated;
revoke execute on function public.kubb_seed_pool_playoffs() from public, anon, authenticated;

-- Det som allerede er en testturnering i første gruppespill får trærne uten
-- å forstyrre kamper som pågår.
do $$
declare v_count int;
begin
  select count(*) into v_count from public.kubb_teams;
  if v_count between 12 and 16
     and exists (select 1 from public.kubb_matches where stage = 'group')
     and not exists (select 1 from public.kubb_matches where stage like 'a_%' or stage like 'b_%') then
    perform public.kubb_build_prepared_pool_bracket('a', 8, 'A-sluttspill', 400000);
    perform public.kubb_build_prepared_pool_bracket('b', v_count - 8, 'B-sluttspill', 500000);
  end if;
  update public.kubb_tournament set name = 'Kilkast', updated_at = now() where id = 1;
end $$;
