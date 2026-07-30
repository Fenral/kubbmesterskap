-- De to første lagene får arrangørtilgang med sin vanlige lagkode.
create or replace function public.kubb_admin_set_teams(p_code text, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; v_code text; v_id uuid; n int := 0; v_role text;
begin
  perform public.kubb_require(p_code, true);
  delete from public.kubb_matches where id is not null;
  delete from public.kubb_teams where id is not null;
  delete from public.kubb_codes where role = 'team';

  for it in select * from jsonb_array_elements(p_teams) loop
    n := n + 1;
    loop
      v_code := lpad((100 + floor(random() * 8900))::int::text, 4, '0');
      exit when not exists (select 1 from public.kubb_codes c where c.code = v_code);
    end loop;
    insert into public.kubb_teams (name, grp, seed)
      values (coalesce(nullif(trim(it->>'name'), ''), 'Lag ' || n),
              upper(coalesce(nullif(trim(it->>'grp'), ''), 'A')), n)
      returning id into v_id;
    v_role := case when n <= 2 then 'admin' else 'team' end;
    insert into public.kubb_codes (code, role, team_id) values (v_code, v_role, v_id);
  end loop;

  update public.kubb_tournament set phase = 'setup', updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'count', n, 'admin_teams', least(n, 2));
end $$;

-- Ett synlig, tilfeldig puljetrekk: 16 lag fordeles i fire puljer à fire og
-- alle kampene settes opp i samme handling.
create or replace function public.kubb_admin_generate_groups(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  perform public.kubb_require(p_code, true);
  select count(*) into v_count from public.kubb_teams;
  if v_count <> 16 then raise exception 'Puljetrekket krever nøyaktig 16 lag'; end if;

  with draw as (
    select id, row_number() over (order by random()) as n
    from public.kubb_teams
  )
  update public.kubb_teams t
     set grp = chr(65 + ((d.n - 1) / 4)::int),
         seed = d.n::int
    from draw d
   where t.id = d.id;

  perform public.kubb_admin_start_tournament(p_code);
  return jsonb_build_object('ok', true, 'groups', 4, 'teams_per_group', 4);
end $$;

-- Endre et registrert resultat direkte. Når en kamp allerede har sendt et lag
-- videre, må neste kamp fortsatt være uspilt for at endringen skal være trygg.
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
    raise exception 'Utslagskamper kan ikke ende uavgjort';
  end if;
  if m.stage = 'group' and exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then
    raise exception 'Første gruppespill kan ikke endres etter at A- og B-gruppene er laget';
  end if;
  if m.stage in ('a_group', 'b_group') and exists (select 1 from public.kubb_matches where stage ~ '^[ab]_(r[0-9]+|qf|sf|final)$') then
    raise exception 'A- eller B-gruppespill kan ikke endres etter at utslagstreet er laget';
  end if;
  if m.feeds_match is not null and exists (
    select 1 from public.kubb_matches where id = m.feeds_match and status in ('live', 'paused', 'finished')
  ) then
    raise exception 'Endre eller nullstill den påfølgende kampen først';
  end if;
  if m.loser_feeds_match is not null and exists (
    select 1 from public.kubb_matches where id = m.loser_feeds_match and status in ('live', 'paused', 'finished')
  ) then
    raise exception 'Endre eller nullstill den påfølgende kampen først';
  end if;

  update public.kubb_matches
     set result = p_result, score_a = p_score_a, score_b = p_score_b, ended_at = now()
   where id = p_match;
  perform public.kubb_propagate(p_match);
  perform public.kubb_assign_courts();
end $$;
