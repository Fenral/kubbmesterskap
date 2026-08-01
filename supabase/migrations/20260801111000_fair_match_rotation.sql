-- Fordel kampene jevnt. En kamp som allerede er klar, paagar eller er ferdig
-- rores aldri her; dette styrer kun hvilken uspilt kamp som velges neste gang
-- en bane blir ledig.

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

  select phase, num_courts into v_phase, v_courts
    from public.kubb_tournament
   where id = 1
   for update;

  if p_court < 1 or p_court > v_courts or v_phase not in ('group', 'final_groups', 'knockout') then
    return null;
  end if;

  -- En allerede annonsert eller startet kamp skal aldri flyttes av koen.
  if exists (
    select 1 from public.kubb_matches
     where court = p_court and status in ('ready', 'live', 'paused')
  ) then return null; end if;

  select candidate.* into v_candidate
    from public.kubb_matches candidate
    join public.kubb_teams team_a on team_a.id = candidate.team_a and team_a.withdrawn_at is null
    join public.kubb_teams team_b on team_b.id = candidate.team_b and team_b.withdrawn_at is null
    cross join lateral (
      select
        count(*) filter (where candidate.team_a in (committed.team_a, committed.team_b))::int as games_a,
        count(*) filter (where candidate.team_b in (committed.team_a, committed.team_b))::int as games_b
      from public.kubb_matches committed
      where committed.status in ('ready', 'live', 'paused', 'finished')
        and (
          (v_phase = 'group' and committed.stage = 'group') or
          (v_phase = 'final_groups' and committed.stage in ('a_group', 'b_group')) or
          (v_phase = 'knockout' and committed.stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$')
        )
    ) rotation
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
       select 1 from public.kubb_matches active
        where active.status in ('ready', 'live', 'paused')
          and (
            candidate.team_a in (active.team_a, active.team_b) or
            candidate.team_b in (active.team_a, active.team_b)
          )
     )
   order by
     -- En manuelt utsatt kamp skal, som avtalt, komme foerst naar de ti
     -- minuttene er ute. Etter det fordeles resten sa jevnt som mulig.
     case when candidate.deferred_until is not null then 0 else 1 end,
     candidate.deferred_until nulls last,
     case when v_phase = 'knockout' then 0 else greatest(rotation.games_a, rotation.games_b) end,
     case when v_phase = 'knockout' then 0 else least(rotation.games_a, rotation.games_b) end,
     case when v_phase = 'knockout' then 0 else candidate.round end,
     candidate.order_no,
     candidate.created_at
   limit 1
   for update of candidate;

  if not found then return null; end if;

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

comment on function public.kubb_assign_next_court_match(int, bigint) is
  'Internal queue dispatcher: preserves announced matches and gives teams with the fewest committed matches priority.';
