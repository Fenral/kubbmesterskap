-- A corrected or struck group match invalidates any previously registered
-- shootout order for that group. A new registration replaces the whole group.

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
