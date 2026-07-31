-- Arrangoren endrer kampen pa en bane, ikke selve banen. Kampen som tas av
-- banen far ti minutters pause og blir prioritert nar pausen er over.

alter table public.kubb_matches
  add column if not exists deferred_until timestamptz;

create or replace function public.kubb_select_court_match(p_code text, p_court int, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  current_match uuid;
  candidate public.kubb_matches%rowtype;
  court_count int;
  snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  if (select phase from public.kubb_tournament where id = 1) = 'finished' then
    raise exception 'Turneringen er avsluttet';
  end if;
  select num_courts into court_count from public.kubb_tournament where id = 1;
  if p_court is null or p_court < 1 or p_court > court_count then raise exception 'Ugyldig bane'; end if;

  select * into candidate from public.kubb_matches where id = p_match and status = 'queued' for update;
  if not found or candidate.team_a is null or candidate.team_b is null then raise exception 'Kampen er ikke startklar'; end if;
  if candidate.deferred_until is not null and candidate.deferred_until > now() then
    raise exception 'Kampen har pause og kan velges om % minutter',
      greatest(1, ceil(extract(epoch from (candidate.deferred_until - now())) / 60)::int);
  end if;

  select id into current_match from public.kubb_matches
   where court = p_court and status = 'ready' limit 1 for update;
  if exists (
    select 1 from public.kubb_matches m
     where m.status in ('ready', 'live', 'paused')
       and m.id <> coalesce(current_match, '00000000-0000-0000-0000-000000000000'::uuid)
       and (candidate.team_a in (m.team_a, m.team_b) or candidate.team_b in (m.team_a, m.team_b))
  ) then raise exception 'Et av lagene er allerede satt opp pa en annen bane'; end if;

  snapshot := public.kubb_snapshot_matches(array_remove(array[p_match, current_match], null));
  perform public.kubb_log_admin_action(
    p_code, 'select_court',
    case when current_match is null then 'Valgte kamp til bane ' else 'Endret kamp pa bane ' end || p_court,
    p_match, snapshot, true
  );
  if current_match is not null then
    update public.kubb_matches
       set status = 'queued', court = null, ready_at = null,
           deferred_until = now() + interval '10 minutes'
     where id = current_match;
  end if;
  update public.kubb_matches
     set status = 'ready', court = p_court, ready_at = now(), deferred_until = null
   where id = p_match;
  update public.kubb_tournament set updated_at = now() where id = 1;
end $$;

create or replace function public.kubb_start_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  snapshot := public.kubb_match_snapshot(p_match);
  perform public.kubb_log_admin_action(p_code, 'start', 'Startet kamp', p_match, snapshot, true);
  update public.kubb_matches
     set status = 'live', started_at = now(), paused_at = null, pause_accum = 0,
         ready_at = null, deferred_until = null
   where id = p_match and status = 'ready';
  if not found then raise exception 'Kampen ma vaere valgt til en bane for den startes'; end if;
end $$;

create or replace function public.kubb_admin_undo_last(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.kubb_audit_log%rowtype; item jsonb; v_actor text;
begin
  perform public.kubb_require(p_code, true);
  select * into a from public.kubb_audit_log order by id desc limit 1 for update;
  if not found or not a.reversible or a.undone_at is not null then raise exception 'Siste handling kan ikke angres'; end if;
  if jsonb_typeof(a.before_state->'matches') <> 'array' then raise exception 'Handlingen mangler gjenopprettingsdata'; end if;
  for item in select value from jsonb_array_elements(a.before_state->'matches') loop
    update public.kubb_matches
       set team_a = nullif(item->>'team_a', '')::uuid,
           team_b = nullif(item->>'team_b', '')::uuid,
           court = nullif(item->>'court', '')::int,
           status = item->>'status',
           started_at = nullif(item->>'started_at', '')::timestamptz,
           paused_at = nullif(item->>'paused_at', '')::timestamptz,
           pause_accum = coalesce((item->>'pause_accum')::int, 0),
           extra_seconds = coalesce((item->>'extra_seconds')::int, 0),
           ended_at = nullif(item->>'ended_at', '')::timestamptz,
           result = nullif(item->>'result', ''),
           score_a = nullif(item->>'score_a', '')::int,
           score_b = nullif(item->>'score_b', '')::int,
           ready_at = nullif(item->>'ready_at', '')::timestamptz,
           deferred_until = nullif(item->>'deferred_until', '')::timestamptz
     where id = (item->>'id')::uuid;
  end loop;
  select coalesce(t.name, 'Hovedarrangor') into v_actor
    from public.kubb_codes c left join public.kubb_teams t on t.id = c.team_id
   where c.code = trim(p_code) and c.role = 'admin';
  update public.kubb_audit_log set undone_at = now(), undone_by = v_actor where id = a.id;
  perform public.kubb_log_admin_action(p_code, 'undo', 'Angret: ' || a.label, a.match_id, null, false);
  update public.kubb_tournament set updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'undone', a.label);
end $$;

-- De gamle enkeltoperasjonene er ikke lenger en del av arrangorflyten.
revoke execute on function public.kubb_admin_move_court_match(text, uuid, int) from public, anon, authenticated;
revoke execute on function public.kubb_admin_release_court_match(text, uuid) from public, anon, authenticated;
