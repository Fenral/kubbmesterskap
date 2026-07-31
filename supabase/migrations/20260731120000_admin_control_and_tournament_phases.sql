-- Arrangørstyrte faseoverganger, revisjonslogg og reelle skriverettigheter.
-- Vanlige lagkoder er fortsatt gyldige for innlogging og lesing, men kan ikke
-- endre baner, klokker eller resultater.

alter table public.kubb_matches
  add column if not exists ready_at timestamptz;

update public.kubb_matches
   set ready_at = now()
 where status = 'ready' and ready_at is null;

create table if not exists public.kubb_audit_log (
  id bigint generated always as identity primary key,
  action text not null,
  label text not null,
  actor_team_id uuid references public.kubb_teams(id) on delete set null,
  actor_name text not null,
  match_id uuid references public.kubb_matches(id) on delete set null,
  before_state jsonb,
  reversible boolean not null default false,
  undone_at timestamptz,
  undone_by text,
  created_at timestamptz not null default now()
);

alter table public.kubb_audit_log enable row level security;
revoke all on table public.kubb_audit_log from public, anon, authenticated;
revoke all on sequence public.kubb_audit_log_id_seq from public, anon, authenticated;

create or replace function public.kubb_snapshot_matches(p_ids uuid[])
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'matches', coalesce(jsonb_agg(to_jsonb(m) order by m.order_no), '[]'::jsonb)
  )
  from public.kubb_matches m
  where m.id = any(coalesce(p_ids, '{}'::uuid[]))
$$;

create or replace function public.kubb_match_snapshot(p_match uuid)
returns jsonb language sql security definer set search_path = public as $$
  select public.kubb_snapshot_matches(array_remove(array[m.id, m.feeds_match, m.loser_feeds_match], null))
  from public.kubb_matches m
  where m.id = p_match
$$;

create or replace function public.kubb_log_admin_action(
  p_code text,
  p_action text,
  p_label text,
  p_match uuid default null,
  p_before jsonb default null,
  p_reversible boolean default false
) returns bigint language plpgsql security definer set search_path = public as $$
declare v_team uuid; v_actor text; v_id bigint;
begin
  select c.team_id, coalesce(t.name, 'Hovedarrangør')
    into v_team, v_actor
    from public.kubb_codes c
    left join public.kubb_teams t on t.id = c.team_id
   where c.code = trim(coalesce(p_code, '')) and c.role = 'admin';
  if not found then raise exception 'Krever arrangørkode'; end if;

  insert into public.kubb_audit_log
    (action, label, actor_team_id, actor_name, match_id, before_state, reversible)
  values
    (p_action, p_label, v_team, v_actor, p_match, p_before, p_reversible)
  returning id into v_id;
  return v_id;
end $$;

revoke execute on function public.kubb_snapshot_matches(uuid[]) from public, anon, authenticated;
revoke execute on function public.kubb_match_snapshot(uuid) from public, anon, authenticated;
revoke execute on function public.kubb_log_admin_action(text, text, text, uuid, jsonb, boolean) from public, anon, authenticated;

create or replace function public.kubb_admin_recent_actions(p_code text, p_limit int default 8)
returns table(
  id bigint,
  action text,
  label text,
  actor_name text,
  created_at timestamptz,
  can_undo boolean
) language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  return query
    select a.id, a.action, a.label, a.actor_name, a.created_at,
           (a.reversible and a.undone_at is null
             and a.id = (select max(latest.id) from public.kubb_audit_log latest)) as can_undo
      from public.kubb_audit_log a
     order by a.id desc
     limit greatest(1, least(coalesce(p_limit, 8), 30));
end $$;

create or replace function public.kubb_admin_undo_last(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a public.kubb_audit_log%rowtype; item jsonb; v_actor text;
begin
  perform public.kubb_require(p_code, true);
  select * into a from public.kubb_audit_log order by id desc limit 1 for update;
  if not found or not a.reversible or a.undone_at is not null then
    raise exception 'Siste handling kan ikke angres';
  end if;
  if jsonb_typeof(a.before_state->'matches') <> 'array' then
    raise exception 'Handlingen mangler gjenopprettingsdata';
  end if;

  for item in select value from jsonb_array_elements(a.before_state->'matches') loop
    update public.kubb_matches
       set team_a = nullif(item->>'team_a', '')::uuid,
           team_b = nullif(item->>'team_b', '')::uuid,
           court = nullif(item->>'court', '')::int,
           status = item->>'status',
           started_at = nullif(item->>'started_at', '')::timestamptz,
           paused_at = nullif(item->>'paused_at', '')::timestamptz,
           pause_accum = coalesce((item->>'pause_accum')::int, 0),
           ended_at = nullif(item->>'ended_at', '')::timestamptz,
           result = nullif(item->>'result', ''),
           score_a = nullif(item->>'score_a', '')::int,
           score_b = nullif(item->>'score_b', '')::int,
           ready_at = nullif(item->>'ready_at', '')::timestamptz
     where id = (item->>'id')::uuid;
  end loop;

  select coalesce(t.name, 'Hovedarrangør') into v_actor
    from public.kubb_codes c left join public.kubb_teams t on t.id = c.team_id
   where c.code = trim(p_code) and c.role = 'admin';
  update public.kubb_audit_log
     set undone_at = now(), undone_by = v_actor
   where id = a.id;
  perform public.kubb_log_admin_action(p_code, 'undo', 'Angret: ' || a.label, a.match_id, null, false);
  update public.kubb_tournament set updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'undone', a.label);
end $$;

-- Bare arrangører kan velge, starte, pause, fortsette eller avslutte kamper.
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
  select * into candidate from public.kubb_matches where id = p_match and status = 'queued';
  if not found or candidate.team_a is null or candidate.team_b is null then
    raise exception 'Kampen er ikke startklar';
  end if;
  select id into current_match from public.kubb_matches
   where court = p_court and status = 'ready' limit 1;
  if exists (
    select 1 from public.kubb_matches m
     where m.status in ('ready', 'live', 'paused')
       and m.id <> coalesce(current_match, '00000000-0000-0000-0000-000000000000'::uuid)
       and (candidate.team_a in (m.team_a, m.team_b) or candidate.team_b in (m.team_a, m.team_b))
  ) then
    raise exception 'Et av lagene er allerede satt opp på en annen bane';
  end if;

  snapshot := public.kubb_snapshot_matches(array_remove(array[p_match, current_match], null));
  perform public.kubb_log_admin_action(
    p_code, 'select_court', 'Valgte kamp til bane ' || p_court, p_match, snapshot, true
  );
  if current_match is not null then
    update public.kubb_matches set status = 'queued', court = null, ready_at = null where id = current_match;
  end if;
  update public.kubb_matches set status = 'ready', court = p_court, ready_at = now() where id = p_match;
end $$;

create or replace function public.kubb_start_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  snapshot := public.kubb_match_snapshot(p_match);
  perform public.kubb_log_admin_action(p_code, 'start', 'Startet kamp', p_match, snapshot, true);
  update public.kubb_matches
     set status = 'live', started_at = now(), paused_at = null, pause_accum = 0, ready_at = null
   where id = p_match and status = 'ready';
  if not found then raise exception 'Kampen må være valgt til en bane før den startes'; end if;
end $$;

create or replace function public.kubb_pause_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  snapshot := public.kubb_match_snapshot(p_match);
  perform public.kubb_log_admin_action(p_code, 'pause', 'Pauset kamp', p_match, snapshot, true);
  update public.kubb_matches set status = 'paused', paused_at = now()
   where id = p_match and status = 'live';
  if not found then raise exception 'Kampen spilles ikke nå'; end if;
end $$;

create or replace function public.kubb_resume_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  snapshot := public.kubb_match_snapshot(p_match);
  perform public.kubb_log_admin_action(p_code, 'resume', 'Fortsatte kamp', p_match, snapshot, true);
  update public.kubb_matches
     set status = 'live',
         pause_accum = pause_accum + greatest(0, extract(epoch from (now() - paused_at))::int),
         paused_at = null
   where id = p_match and status = 'paused';
  if not found then raise exception 'Kampen er ikke pauset'; end if;
end $$;

create or replace function public.kubb_finish_match(
  p_code text, p_match uuid, p_result text, p_score_a int default null, p_score_b int default null
) returns void language plpgsql security definer set search_path = public as $$
declare m public.kubb_matches%rowtype; snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  if p_result not in ('a', 'b', 'draw') then raise exception 'Ugyldig resultat'; end if;
  select * into m from public.kubb_matches where id = p_match;
  if not found then raise exception 'Fant ikke kampen'; end if;
  if m.status not in ('live', 'paused') then raise exception 'Kampen må være startet før resultatet registreres'; end if;
  if m.stage not in ('group', 'a_group', 'b_group') and p_result = 'draw' then
    raise exception 'Sluttspillkamper kan ikke ende uavgjort';
  end if;
  snapshot := public.kubb_match_snapshot(p_match);
  perform public.kubb_log_admin_action(p_code, 'finish', 'Registrerte resultat', p_match, snapshot, true);
  update public.kubb_matches
     set status = 'finished', result = p_result, score_a = p_score_a, score_b = p_score_b,
         ended_at = now(), court = null, paused_at = null, ready_at = null
   where id = p_match;
  perform public.kubb_propagate(p_match);
end $$;

create or replace function public.kubb_finish_expired_matches(p_code text)
returns int language plpgsql security definer set search_path = public as $$
declare m record; total int := 0;
begin
  perform public.kubb_require(p_code, true);
  for m in
    select match.id
      from public.kubb_matches match
      join public.kubb_tournament t on t.id = 1
     where match.status = 'live'
       and match.stage in ('group', 'a_group', 'b_group')
       and match.started_at + make_interval(secs => t.match_seconds + match.pause_accum) <= now()
     order by match.order_no
  loop
    perform public.kubb_finish_match(p_code, m.id, 'draw', null, null);
    total := total + 1;
  end loop;
  return total;
end $$;

create or replace function public.kubb_admin_correct_result(
  p_code text, p_match uuid, p_result text, p_score_a int default null, p_score_b int default null
) returns void language plpgsql security definer set search_path = public as $$
declare m public.kubb_matches%rowtype; snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  select * into m from public.kubb_matches where id = p_match;
  if not found or m.status <> 'finished' then raise exception 'Kampen er ikke ferdigspilt'; end if;
  if p_result not in ('a', 'b', 'draw') then raise exception 'Ugyldig resultat'; end if;
  if m.stage not in ('group', 'a_group', 'b_group') and p_result = 'draw' then
    raise exception 'Sluttspillkamper kan ikke ende uavgjort';
  end if;
  if m.stage = 'group' and (select phase from public.kubb_tournament where id = 1) <> 'group' then
    raise exception 'Første gruppespill er låst';
  end if;
  if m.stage in ('a_group', 'b_group') and (select phase from public.kubb_tournament where id = 1) <> 'final_groups' then
    raise exception 'A- og B-gruppespillet er låst';
  end if;
  if m.feeds_match is not null and exists (
    select 1 from public.kubb_matches where id = m.feeds_match and status in ('ready', 'live', 'paused', 'finished')
  ) then raise exception 'Nullstill den påfølgende kampen først'; end if;
  if m.loser_feeds_match is not null and exists (
    select 1 from public.kubb_matches where id = m.loser_feeds_match and status in ('ready', 'live', 'paused', 'finished')
  ) then raise exception 'Nullstill den påfølgende kampen først'; end if;

  snapshot := public.kubb_match_snapshot(p_match);
  perform public.kubb_log_admin_action(p_code, 'correct', 'Rettet resultat', p_match, snapshot, true);
  update public.kubb_matches
     set result = p_result, score_a = p_score_a, score_b = p_score_b, ended_at = now()
   where id = p_match;
  perform public.kubb_propagate(p_match);
end $$;

create or replace function public.kubb_reopen_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.kubb_matches%rowtype; snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  select * into m from public.kubb_matches where id = p_match and status = 'finished';
  if not found then raise exception 'Kampen er ikke ferdig'; end if;
  if m.feeds_match is not null and exists (
    select 1 from public.kubb_matches where id = m.feeds_match and status in ('ready', 'live', 'paused', 'finished')
  ) then raise exception 'Nullstill den påfølgende kampen først'; end if;
  if m.loser_feeds_match is not null and exists (
    select 1 from public.kubb_matches where id = m.loser_feeds_match and status in ('ready', 'live', 'paused', 'finished')
  ) then raise exception 'Nullstill den påfølgende kampen først'; end if;

  snapshot := public.kubb_match_snapshot(p_match);
  perform public.kubb_log_admin_action(p_code, 'reopen', 'Gjenåpnet kamp', p_match, snapshot, true);
  if m.feeds_match is not null then
    if m.feeds_side = 'a' then update public.kubb_matches set team_a = null where id = m.feeds_match;
    else update public.kubb_matches set team_b = null where id = m.feeds_match; end if;
  end if;
  if m.loser_feeds_match is not null then
    if m.loser_feeds_side = 'a' then update public.kubb_matches set team_a = null where id = m.loser_feeds_match;
    else update public.kubb_matches set team_b = null where id = m.loser_feeds_match; end if;
  end if;
  update public.kubb_matches
     set status = 'queued', result = null, score_a = null, score_b = null,
         started_at = null, ended_at = null, paused_at = null, pause_accum = 0,
         court = null, ready_at = null
   where id = p_match;
end $$;

-- Eksplisitte faseoverganger. Ingen kamp får opprette neste trinn automatisk.
create or replace function public.kubb_admin_phase_action(p_code text, p_action text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_phase text; v_created int; v_seeded boolean; v_label text;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;

  if p_action = 'close_group' then
    if v_phase <> 'group' then raise exception 'Første gruppespill kan ikke avsluttes nå'; end if;
    if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then
      raise exception 'Alle kampene i første gruppespill må være ferdige';
    end if;
    v_label := 'Avsluttet første gruppespill';
    perform public.kubb_log_admin_action(p_code, 'phase', v_label, null, null, false);
    update public.kubb_tournament set phase = 'group_review', updated_at = now() where id = 1;

  elsif p_action = 'start_final_groups' then
    if v_phase <> 'group_review' then raise exception 'Kontroller A- og B-lagene først'; end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Startet A- og B-gruppespill', null, null, false);
    v_created := public.kubb_create_final_groups();
    if v_created = 0 and not exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then
      raise exception 'Kunne ikke opprette A- og B-gruppespillet';
    end if;

  elsif p_action = 'review_semifinalists' then
    if v_phase <> 'final_groups' then raise exception 'A- og B-gruppespillet pågår ikke'; end if;
    if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group') and status <> 'finished') then
      raise exception 'Alle kampene i A- og B-gruppespillet må være ferdige';
    end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Kontrollerte semifinalister', null, null, false);
    update public.kubb_tournament set phase = 'semifinal_review', updated_at = now() where id = 1;

  elsif p_action = 'start_knockout' then
    if v_phase <> 'semifinal_review' then raise exception 'Kontroller semifinalistene først'; end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Startet knockout', null, null, false);
    v_seeded := public.kubb_seed_pool_playoffs();
    if not v_seeded then raise exception 'Kunne ikke fylle semifinalene'; end if;
    update public.kubb_matches set ready_at = null
     where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$';
    update public.kubb_tournament set phase = 'knockout', updated_at = now() where id = 1;

  elsif p_action = 'finish_tournament' then
    if v_phase <> 'knockout' then raise exception 'Knockoutspillet pågår ikke'; end if;
    if exists (select 1 from public.kubb_matches where status <> 'finished' and team_a is not null and team_b is not null) then
      raise exception 'Alle startklare kamper må være ferdige';
    end if;
    perform public.kubb_log_admin_action(p_code, 'phase', 'Avsluttet turneringen', null, null, false);
    update public.kubb_tournament set phase = 'finished', updated_at = now() where id = 1;
  else
    raise exception 'Ukjent fasehandling';
  end if;

  return jsonb_build_object('ok', true, 'phase', (select phase from public.kubb_tournament where id = 1));
end $$;

create or replace function public.kubb_admin_advance_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  raise exception 'Bruk fasekontrollen for å gå videre';
end $$;

-- Oppsett og strukturelle endringer loggføres, men er ikke ett-trykks-angre.
create or replace function public.kubb_admin_settings(
  p_code text, p_name text, p_minutes int, p_courts int, p_qualifiers int
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  perform public.kubb_log_admin_action(p_code, 'settings', 'Endret turneringsinnstillinger', null, null, false);
  update public.kubb_tournament
     set name = coalesce(nullif(trim(p_name), ''), name),
         match_seconds = greatest(60, coalesce(p_minutes, 40) * 60),
         num_courts = greatest(1, least(20, coalesce(p_courts, 6))),
         qualifiers_per_group = greatest(1, coalesce(p_qualifiers, 2)),
         updated_at = now()
   where id = 1;
end $$;

create or replace function public.kubb_admin_set_teams(p_code text, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it jsonb; v_code text; v_id uuid; v_name text; n int := 0; v_role text; v_count int;
begin
  perform public.kubb_require(p_code, true);
  select count(*)::int into v_count
    from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) x
   where nullif(trim(x->>'name'), '') is not null;
  if v_count < 12 or v_count > 16 then raise exception 'Legg inn mellom 12 og 16 lag'; end if;
  if exists (
    select 1 from (
      select lower(trim(x->>'name')) as name, count(*) as n
        from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) x
       where nullif(trim(x->>'name'), '') is not null
       group by lower(trim(x->>'name'))
    ) duplicates where duplicates.n > 1
  ) then raise exception 'Hvert lag må ha et eget navn'; end if;

  perform public.kubb_log_admin_action(p_code, 'teams', 'Lagret ny lagliste', null, null, false);
  delete from public.kubb_matches where id is not null;
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
      values (left(v_name, 40), 'A', n) returning id into v_id;
    v_role := case when n <= 2 then 'admin' else 'team' end;
    insert into public.kubb_codes (code, role, team_id) values (v_code, v_role, v_id);
  end loop;
  update public.kubb_tournament set phase = 'setup', updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'count', n, 'admin_teams', least(n, 2));
end $$;

create or replace function public.kubb_admin_start_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g record; arr uuid[]; group_matches int := 0; playoff_matches int := 0; gi int := 0;
begin
  perform public.kubb_require(p_code, true);
  perform public.kubb_log_admin_action(p_code, 'draw', 'Trakk puljer og startet første gruppespill', null, null, false);
  delete from public.kubb_matches where id is not null;
  for g in select distinct grp from public.kubb_teams order by grp loop
    gi := gi + 1;
    select coalesce(array_agg(id order by seed, name), '{}'::uuid[]) into arr
      from public.kubb_teams where grp = g.grp;
    group_matches := group_matches + public.kubb_make_round_robin('group', g.grp, arr, gi * 10000, 'Pulje ' || g.grp);
  end loop;
  playoff_matches := public.kubb_build_prepared_pool_bracket('a', 4, 'A-sluttspill', 400000);
  playoff_matches := playoff_matches + public.kubb_build_prepared_pool_bracket('b', 4, 'B-sluttspill', 500000);
  update public.kubb_tournament set phase = 'group', updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'group_matches', group_matches, 'playoff_matches', playoff_matches);
end $$;

create or replace function public.kubb_admin_reset(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  perform public.kubb_log_admin_action(p_code, 'reset', 'Nullstilte hele turneringen', null, null, false);
  delete from public.kubb_matches where id is not null;
  delete from public.kubb_teams where id is not null;
  delete from public.kubb_codes where team_id is not null;
  update public.kubb_tournament set phase = 'setup', updated_at = now() where id = 1;
end $$;

create or replace function public.kubb_admin_set_admin_code(p_code text, p_new text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  if p_new !~ '^[0-9]{4,8}$' then raise exception 'Koden må være 4–8 siffer'; end if;
  if exists (select 1 from public.kubb_codes where code = p_new) then raise exception 'Koden er i bruk'; end if;
  perform public.kubb_log_admin_action(p_code, 'admin_code', 'Byttet hovedkoden', null, null, false);
  update public.kubb_codes set code = p_new where role = 'admin' and team_id is null;
  if not found then raise exception 'Fant ikke hovedarrangørkoden'; end if;
end $$;

create or replace function public.kubb_admin_codes_v2(p_code text)
returns table(team_id uuid, team_name text, grp text, code text, role text)
language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  return query
    select t.id, t.name, t.grp, c.code, c.role
      from public.kubb_teams t
      join public.kubb_codes c on c.team_id = t.id
     order by case when c.role = 'admin' then 0 else 1 end, t.grp, t.name;
end $$;

grant execute on function public.kubb_admin_recent_actions(text, int) to anon, authenticated;
grant execute on function public.kubb_admin_undo_last(text) to anon, authenticated;
grant execute on function public.kubb_admin_phase_action(text, text) to anon, authenticated;
grant execute on function public.kubb_admin_codes_v2(text) to anon, authenticated;

-- Eldre versjoner kunne sette fasen til knockout ved et tidlig trykk på
-- «Gå videre». Normaliser bare fasefeltet fra kampene som faktisk finnes.
do $$
begin
  if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished')
     and not exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then
    update public.kubb_tournament set phase = 'group', updated_at = now() where id = 1;
  elsif exists (select 1 from public.kubb_matches where stage = 'group')
     and not exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished')
     and not exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then
    update public.kubb_tournament set phase = 'group_review', updated_at = now() where id = 1;
  elsif exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group') and status <> 'finished') then
    update public.kubb_tournament set phase = 'final_groups', updated_at = now() where id = 1;
  elsif exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group'))
     and not exists (
       select 1 from public.kubb_matches
        where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$'
          and status in ('ready', 'live', 'paused', 'finished')
     ) then
    update public.kubb_tournament set phase = 'semifinal_review', updated_at = now() where id = 1;
  end if;
end $$;
