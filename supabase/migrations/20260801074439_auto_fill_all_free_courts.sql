-- Courts are a queue display, not a manual scheduling surface. Fill every free
-- court as soon as eligible teams are available; organizers can still replace
-- a ready match through kubb_select_court_match.

create or replace function public.kubb_fill_free_courts(
  p_audit_log_id bigint default null
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_court int;
  v_courts int;
  v_assigned uuid;
  v_count int := 0;
begin
  select num_courts into v_courts
    from public.kubb_tournament
   where id = 1;

  for v_court in 1..coalesce(v_courts, 0) loop
    select public.kubb_assign_next_court_match(v_court, p_audit_log_id)
      into v_assigned;
    if v_assigned is not null then v_count := v_count + 1; end if;
  end loop;
  return v_count;
end $$;

revoke execute on function public.kubb_fill_free_courts(bigint) from public, anon, authenticated;

create or replace function public.kubb_admin_start_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g record;
  arr uuid[];
  group_matches int := 0;
  playoff_matches int := 0;
  gi int := 0;
  v_phase text;
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

  -- The first round is announced immediately on all available courts.
  perform public.kubb_fill_free_courts();
  return jsonb_build_object('ok', true, 'group_matches', group_matches, 'playoff_matches', playoff_matches, 'planned_matches', 56);
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
    perform public.kubb_fill_free_courts();
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
    perform public.kubb_fill_free_courts();
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

create or replace function public.kubb_finish_match(
  p_code text,
  p_match uuid,
  p_result text,
  p_score_a int default null,
  p_score_b int default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match public.kubb_matches%rowtype;
  v_snapshot jsonb;
  v_log_id bigint;
begin
  perform public.kubb_require(p_code, true);
  if p_result not in ('a', 'b', 'draw') then raise exception 'Ugyldig resultat'; end if;

  select * into v_match from public.kubb_matches where id = p_match for update;
  if not found then raise exception 'Fant ikke kampen'; end if;
  if v_match.status not in ('live', 'paused') then raise exception 'Kampen ma vaere startet for resultatet registreres'; end if;
  if v_match.stage not in ('group', 'a_group', 'b_group') and p_result = 'draw' then
    raise exception 'Sluttspillkamper kan ikke ende uavgjort';
  end if;

  v_snapshot := public.kubb_match_snapshot(p_match);
  v_log_id := public.kubb_log_admin_action(
    p_code, 'finish', 'Registrerte resultat', p_match, v_snapshot, true
  );

  update public.kubb_matches
     set status = 'finished', result = p_result, score_a = p_score_a, score_b = p_score_b,
         ended_at = now(), court = null, paused_at = null, ready_at = null,
         deferred_until = null
   where id = p_match;

  perform public.kubb_propagate(p_match);
  -- Fill this and any other court that became possible when the teams were freed.
  perform public.kubb_fill_free_courts(v_log_id);
end $$;

revoke execute on function public.kubb_finish_match(text, uuid, text, int, int) from public;
grant execute on function public.kubb_finish_match(text, uuid, text, int, int) to anon, authenticated;

comment on function public.kubb_fill_free_courts(bigint) is
  'Internal scheduler: fills every free court with the next eligible queued match.';
