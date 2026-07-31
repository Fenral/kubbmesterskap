-- De resterende arrangørkontrollene som ikke endrer de sportslige reglene.
-- Trekningen og oppsettet låses etter start, mens enkeltkamper kan flyttes,
-- få ekstra tid og nullstilles kontrollert videre i knockouttreet.

alter table public.kubb_matches
  add column if not exists extra_seconds int not null default 0;

alter table public.kubb_tournament
  add column if not exists drawn_at timestamptz,
  add column if not exists completed_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'kubb_matches_extra_seconds_range'
       and conrelid = 'public.kubb_matches'::regclass
  ) then
    alter table public.kubb_matches
      add constraint kubb_matches_extra_seconds_range
      check (extra_seconds between 0 and 3600);
  end if;
end $$;

update public.kubb_tournament t
   set drawn_at = coalesce(
     t.drawn_at,
     (select min(m.created_at) from public.kubb_matches m),
     t.updated_at
   )
 where t.id = 1 and t.phase <> 'setup' and t.drawn_at is null;

create or replace function public.kubb_stamp_phase_times()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.phase = 'setup' then
    new.drawn_at := null;
    new.completed_at := null;
  elsif old.phase = 'setup' and new.phase <> 'setup' and new.drawn_at is null then
    new.drawn_at := now();
  end if;
  if new.phase = 'finished' and old.phase is distinct from 'finished' then
    new.completed_at := now();
  elsif new.phase <> 'finished' then
    new.completed_at := null;
  end if;
  return new;
end $$;

drop trigger if exists kubb_stamp_phase_times on public.kubb_tournament;
create trigger kubb_stamp_phase_times
before update on public.kubb_tournament
for each row execute function public.kubb_stamp_phase_times();

revoke execute on function public.kubb_stamp_phase_times() from public, anon, authenticated;

-- Gjenopprett også kampens individuelle tilleggstid ved «angre».
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
           extra_seconds = coalesce((item->>'extra_seconds')::int, 0),
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

create or replace function public.kubb_admin_regenerate_team_code(p_code text, p_team uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; v_name text; v_role text;
begin
  perform public.kubb_require(p_code, true);
  select t.name, c.role into v_name, v_role
    from public.kubb_teams t
    join public.kubb_codes c on c.team_id = t.id
   where t.id = p_team
   for update of c;
  if not found then raise exception 'Fant ikke laget eller lagkoden'; end if;

  loop
    v_code := lpad((100 + floor(random() * 8900))::int::text, 4, '0');
    exit when not exists (select 1 from public.kubb_codes c where c.code = v_code);
  end loop;
  perform public.kubb_log_admin_action(
    p_code, 'team_code', 'Lagde ny kode til ' || v_name, null, null, false
  );
  update public.kubb_codes set code = v_code where team_id = p_team;
  return jsonb_build_object('ok', true, 'team_id', p_team, 'team_name', v_name, 'role', v_role, 'code', v_code);
end $$;

create or replace function public.kubb_admin_release_court_match(p_code text, p_match uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m public.kubb_matches%rowtype; snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  select * into m from public.kubb_matches where id = p_match for update;
  if not found or m.status <> 'ready' or m.court is null then
    raise exception 'Bare en valgt, ikke startet kamp kan legges tilbake i køen';
  end if;
  snapshot := public.kubb_snapshot_matches(array[p_match]);
  perform public.kubb_log_admin_action(
    p_code, 'release_court', 'La kampen på bane ' || m.court || ' tilbake i køen', p_match, snapshot, true
  );
  update public.kubb_matches set status = 'queued', court = null, ready_at = null where id = p_match;
  update public.kubb_tournament set updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'match_id', p_match);
end $$;

create or replace function public.kubb_admin_move_court_match(p_code text, p_match uuid, p_court int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m public.kubb_matches%rowtype; v_courts int; snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  select num_courts into v_courts from public.kubb_tournament where id = 1;
  if p_court is null or p_court < 1 or p_court > v_courts then raise exception 'Ugyldig bane'; end if;
  select * into m from public.kubb_matches where id = p_match for update;
  if not found or m.status <> 'ready' or m.court is null then
    raise exception 'Bare en valgt, ikke startet kamp kan flyttes';
  end if;
  if exists (
    select 1 from public.kubb_matches busy
     where busy.id <> p_match and busy.court = p_court
       and busy.status in ('ready', 'live', 'paused')
  ) then raise exception 'Den banen er allerede i bruk'; end if;
  snapshot := public.kubb_snapshot_matches(array[p_match]);
  perform public.kubb_log_admin_action(
    p_code, 'move_court', 'Flyttet kamp fra bane ' || m.court || ' til bane ' || p_court, p_match, snapshot, true
  );
  update public.kubb_matches set court = p_court, ready_at = now() where id = p_match;
  update public.kubb_tournament set updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'match_id', p_match, 'court', p_court);
end $$;

create or replace function public.kubb_admin_add_match_time(p_code text, p_match uuid, p_minutes int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m public.kubb_matches%rowtype; snapshot jsonb; v_seconds int;
begin
  perform public.kubb_require(p_code, true);
  if p_minutes is null or p_minutes < 1 or p_minutes > 30 then
    raise exception 'Legg til mellom 1 og 30 minutter om gangen';
  end if;
  select * into m from public.kubb_matches where id = p_match for update;
  if not found or m.status not in ('live', 'paused') then
    raise exception 'Bare en pågående kamp kan få ekstra tid';
  end if;
  v_seconds := p_minutes * 60;
  if m.extra_seconds + v_seconds > 3600 then raise exception 'En kamp kan få maksimalt 60 minutter ekstra'; end if;
  snapshot := public.kubb_snapshot_matches(array[p_match]);
  perform public.kubb_log_admin_action(
    p_code, 'extra_time', 'La til ' || p_minutes || ' min på bane ' || m.court, p_match, snapshot, true
  );
  update public.kubb_matches set extra_seconds = extra_seconds + v_seconds where id = p_match;
  update public.kubb_tournament set updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'match_id', p_match, 'extra_seconds', m.extra_seconds + v_seconds);
end $$;

-- Nullstill alle senere knockoutkamper som kan ha mottatt vinner eller taper
-- fra den valgte kampen. Den valgte kampen beholdes slik at resultatet kan rettes.
create or replace function public.kubb_admin_reset_downstream(p_code text, p_match uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; v_count int; snapshot jsonb;
begin
  perform public.kubb_require(p_code, true);
  if not exists (select 1 from public.kubb_matches where id = p_match) then raise exception 'Fant ikke kampen'; end if;

  with recursive tree(id) as (
    select p_match
    union
    select child.id
      from public.kubb_matches m
      join tree t on m.id = t.id
      cross join lateral (values (m.feeds_match), (m.loser_feeds_match)) child(id)
     where child.id is not null
  )
  select coalesce(array_agg(id), '{}'::uuid[]) into v_ids from tree where id <> p_match;
  v_count := cardinality(v_ids);
  if v_count = 0 then return jsonb_build_object('ok', true, 'count', 0); end if;

  snapshot := public.kubb_snapshot_matches(v_ids);
  perform public.kubb_log_admin_action(
    p_code, 'reset_downstream', 'Nullstilte ' || v_count || ' senere knockoutkamper', p_match, snapshot, true
  );

  with recursive sources(id) as (
    select p_match
    union
    select child.id
      from public.kubb_matches m
      join sources s on m.id = s.id
      cross join lateral (values (m.feeds_match), (m.loser_feeds_match)) child(id)
     where child.id is not null
  ), edges as (
    select m.feeds_match as target_id, m.feeds_side as target_side
      from public.kubb_matches m join sources s on s.id = m.id where m.feeds_match is not null
    union all
    select m.loser_feeds_match, m.loser_feeds_side
      from public.kubb_matches m join sources s on s.id = m.id where m.loser_feeds_match is not null
  )
  update public.kubb_matches target
     set team_a = case when exists (select 1 from edges e where e.target_id = target.id and e.target_side = 'a') then null else target.team_a end,
         team_b = case when exists (select 1 from edges e where e.target_id = target.id and e.target_side = 'b') then null else target.team_b end,
         status = 'queued', court = null, ready_at = null,
         started_at = null, paused_at = null, pause_accum = 0, extra_seconds = 0,
         ended_at = null, result = null, score_a = null, score_b = null
   where target.id = any(v_ids);

  update public.kubb_tournament set updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'count', v_count);
end $$;

-- Individuell tilleggstid inngår i automatisk tidsutløp.
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
       and match.started_at + make_interval(secs => t.match_seconds + match.extra_seconds + match.pause_accum) <= now()
     order by match.order_no
  loop
    perform public.kubb_finish_match(p_code, m.id, 'draw', null, null);
    total := total + 1;
  end loop;
  return total;
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
         extra_seconds = 0, ready_at = null
   where id = p_match and status = 'ready';
  if not found then raise exception 'Kampen må være valgt til en bane før den startes'; end if;
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
         extra_seconds = 0, court = null, ready_at = null
   where id = p_match;
end $$;

-- Lagliste og fellesinnstillinger er før-start-valg. Etter trekningen kreves
-- full nullstilling, slik at en arrangør ikke kan endre formatet i det skjulte.
create or replace function public.kubb_admin_settings(
  p_code text, p_name text, p_minutes int, p_courts int, p_qualifiers int
) returns void language plpgsql security definer set search_path = public as $$
declare v_phase text;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase <> 'setup' or exists (select 1 from public.kubb_matches) then
    raise exception 'Innstillingene er låst etter trekningen';
  end if;
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
  it jsonb; v_code text; v_id uuid; v_name text; n int := 0; v_role text; v_count int; v_phase text;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase <> 'setup' or exists (select 1 from public.kubb_matches) then
    raise exception 'Laglisten er låst etter trekningen. Nullstill turneringen for å begynne på nytt';
  end if;
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
  update public.kubb_tournament set phase = 'setup', drawn_at = null, completed_at = null, updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'count', n, 'admin_teams', least(n, 2));
end $$;

create or replace function public.kubb_admin_start_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g record; arr uuid[]; group_matches int := 0; playoff_matches int := 0; gi int := 0; v_phase text;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase <> 'setup' or exists (select 1 from public.kubb_matches) then
    raise exception 'Turneringen er allerede startet';
  end if;
  perform public.kubb_log_admin_action(p_code, 'draw', 'Trakk puljer og startet første gruppespill', null, null, false);
  for g in select distinct grp from public.kubb_teams order by grp loop
    gi := gi + 1;
    select coalesce(array_agg(id order by seed, name), '{}'::uuid[]) into arr
      from public.kubb_teams where grp = g.grp;
    group_matches := group_matches + public.kubb_make_round_robin('group', g.grp, arr, gi * 10000, 'Pulje ' || g.grp);
  end loop;
  playoff_matches := public.kubb_build_prepared_pool_bracket('a', 4, 'A-sluttspill', 400000);
  playoff_matches := playoff_matches + public.kubb_build_prepared_pool_bracket('b', 4, 'B-sluttspill', 500000);
  update public.kubb_tournament set phase = 'group', drawn_at = now(), updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'group_matches', group_matches, 'playoff_matches', playoff_matches);
end $$;

create or replace function public.kubb_admin_generate_groups(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_count int; v_base int; v_extra int; v_phase text; v_result jsonb;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase <> 'setup' or exists (select 1 from public.kubb_matches) then
    raise exception 'Puljene er allerede trukket og er nå låst';
  end if;
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

  select public.kubb_admin_start_tournament(p_code) into v_result;
  update public.kubb_tournament set drawn_at = now(), updated_at = now() where id = 1;
  return jsonb_build_object(
    'ok', true, 'groups', 4, 'small_group_size', v_base,
    'large_group_size', v_base + case when v_extra > 0 then 1 else 0 end,
    'group_matches', v_result->'group_matches', 'playoff_matches', v_result->'playoff_matches'
  );
end $$;

create or replace function public.kubb_admin_reset(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  perform public.kubb_log_admin_action(p_code, 'reset', 'Nullstilte hele turneringen', null, null, false);
  delete from public.kubb_matches where id is not null;
  delete from public.kubb_teams where id is not null;
  delete from public.kubb_codes where team_id is not null;
  update public.kubb_tournament
     set phase = 'setup', drawn_at = null, completed_at = null, updated_at = now()
   where id = 1;
end $$;

grant execute on function public.kubb_admin_regenerate_team_code(text, uuid) to anon, authenticated;
grant execute on function public.kubb_admin_release_court_match(text, uuid) to anon, authenticated;
grant execute on function public.kubb_admin_move_court_match(text, uuid, int) to anon, authenticated;
grant execute on function public.kubb_admin_add_match_time(text, uuid, int) to anon, authenticated;
grant execute on function public.kubb_admin_reset_downstream(text, uuid) to anon, authenticated;
revoke execute on function public.kubb_admin_start_tournament(text) from public, anon, authenticated;
