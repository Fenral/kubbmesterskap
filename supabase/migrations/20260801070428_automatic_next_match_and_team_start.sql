-- Når et resultat registreres, fylles den frigjorte banen med den første
-- spillbare kampen i køen. Kampen blir bare gjort klar; et av lagene (eller
-- et arrangørlag i reserve) må fortsatt starte den felles klokken.

create or replace function public.kubb_assign_next_court_match(
  p_court int,
  p_audit_log_id bigint default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phase text;
  v_courts int;
  v_candidate public.kubb_matches%rowtype;
begin
  if p_court is null then return null; end if;

  -- Låser den korte tildelingsseksjonen slik at to baner ikke får samme kamp.
  select phase, num_courts into v_phase, v_courts
    from public.kubb_tournament
   where id = 1
   for update;

  if p_court < 1 or p_court > v_courts or v_phase not in ('group', 'final_groups', 'knockout') then
    return null;
  end if;

  -- En allerede valgt neste kamp på banen skal beholdes.
  if exists (
    select 1 from public.kubb_matches
     where court = p_court and status in ('ready', 'live', 'paused')
  ) then return null; end if;

  select candidate.* into v_candidate
    from public.kubb_matches candidate
    join public.kubb_teams team_a on team_a.id = candidate.team_a and team_a.withdrawn_at is null
    join public.kubb_teams team_b on team_b.id = candidate.team_b and team_b.withdrawn_at is null
   where candidate.status = 'queued'
     and candidate.team_a is not null
     and candidate.team_b is not null
     and (candidate.deferred_until is null or candidate.deferred_until <= now())
     and (
       (v_phase = 'group' and candidate.stage = 'group') or
       (v_phase = 'final_groups' and candidate.stage in ('a_group', 'b_group')) or
       (v_phase = 'knockout' and candidate.stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$')
     )
     and not exists (
       select 1
         from public.kubb_matches active
        where active.status in ('ready', 'live', 'paused')
          and (
            candidate.team_a in (active.team_a, active.team_b) or
            candidate.team_b in (active.team_a, active.team_b)
          )
     )
   order by
     case when candidate.deferred_until is not null then 0 else 1 end,
     candidate.deferred_until nulls last,
     candidate.order_no,
     candidate.created_at
   limit 1
   for update of candidate;

  if not found then return null; end if;

  -- Hvis resultatet angres, må også den automatisk valgte kampen gå tilbake
  -- til nøyaktig tilstanden den hadde før tildelingen.
  if p_audit_log_id is not null and not exists (
    select 1
      from jsonb_array_elements(coalesce(
        (select before_state->'matches' from public.kubb_audit_log where id = p_audit_log_id),
        '[]'::jsonb
      )) item
     where item->>'id' = v_candidate.id::text
  ) then
    update public.kubb_audit_log
       set before_state = jsonb_set(
         coalesce(before_state, jsonb_build_object('matches', '[]'::jsonb)),
         '{matches}',
         coalesce(before_state->'matches', '[]'::jsonb) || to_jsonb(v_candidate),
         true
       )
     where id = p_audit_log_id;
  end if;

  update public.kubb_matches
     set status = 'ready', court = p_court, ready_at = now(), deferred_until = null
   where id = v_candidate.id;

  update public.kubb_tournament set updated_at = now() where id = 1;
  return v_candidate.id;
end $$;

revoke execute on function public.kubb_assign_next_court_match(int, bigint) from public, anon, authenticated;

create or replace function public.kubb_start_match(p_code text, p_match uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match public.kubb_matches%rowtype;
  v_role text;
  v_team uuid;
  v_actor text;
  v_snapshot jsonb;
begin
  select * into v_match from public.kubb_matches where id = p_match for update;
  if not found then raise exception 'Fant ikke kampen'; end if;

  select c.role, c.team_id, coalesce(t.name, 'Arrangørlag')
    into v_role, v_team, v_actor
    from public.kubb_codes c
    left join public.kubb_teams t on t.id = c.team_id and t.withdrawn_at is null
   where c.code = trim(coalesce(p_code, ''));
  if not found then raise exception 'Ugyldig kode'; end if;

  if v_role <> 'admin' and (v_team is null or v_team not in (v_match.team_a, v_match.team_b)) then
    raise exception 'Bare lagene i kampen kan starte klokken';
  end if;
  if v_match.status = 'live' then return; end if;
  if v_match.status <> 'ready' then raise exception 'Kampen må være klar på en bane før den startes'; end if;

  v_snapshot := public.kubb_match_snapshot(p_match);
  insert into public.kubb_audit_log
    (action, label, actor_team_id, actor_name, match_id, before_state, reversible)
  values
    ('start', 'Startet kamp', v_team, v_actor, p_match, v_snapshot, true);

  update public.kubb_matches
     set status = 'live', started_at = now(), paused_at = null, pause_accum = 0,
         ready_at = null, deferred_until = null
   where id = p_match;
  update public.kubb_tournament set updated_at = now() where id = 1;
end $$;

revoke execute on function public.kubb_start_match(text, uuid) from public;
grant execute on function public.kubb_start_match(text, uuid) to anon, authenticated;

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
  v_court int;
begin
  perform public.kubb_require(p_code, true);
  if p_result not in ('a', 'b', 'draw') then raise exception 'Ugyldig resultat'; end if;

  select * into v_match from public.kubb_matches where id = p_match for update;
  if not found then raise exception 'Fant ikke kampen'; end if;
  if v_match.status not in ('live', 'paused') then
    raise exception 'Kampen må være startet før resultatet registreres';
  end if;
  if v_match.stage not in ('group', 'a_group', 'b_group') and p_result = 'draw' then
    raise exception 'Sluttspillkamper kan ikke ende uavgjort';
  end if;

  v_court := v_match.court;
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
  perform public.kubb_assign_next_court_match(v_court, v_log_id);
end $$;

revoke execute on function public.kubb_finish_match(text, uuid, text, int, int) from public;
grant execute on function public.kubb_finish_match(text, uuid, text, int, int) to anon, authenticated;

comment on function public.kubb_assign_next_court_match(int, bigint) is
  'Internal queue dispatcher: assigns the highest-priority eligible match to a freed court without starting it.';
comment on function public.kubb_start_match(text, uuid) is
  'Starts a ready match when called by either participating team or by an organizer team as backup.';
