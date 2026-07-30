
create or replace function public.kubb_now() returns timestamptz
language sql stable as $$ select now() $$;

-- Rolle for en kode: 'admin', 'team' eller null
create or replace function public.kubb_role(p_code text)
returns table(role text, team_id uuid)
language sql security definer set search_path = public as $$
  select c.role, c.team_id from public.kubb_codes c where c.code = trim(p_code)
$$;

create or replace function public.kubb_login(p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select c.role, c.team_id into r from public.kubb_codes c where c.code = trim(p_code);
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Ugyldig kode');
  end if;
  return jsonb_build_object(
    'ok', true,
    'role', r.role,
    'team_id', r.team_id,
    'team_name', (select t.name from public.kubb_teams t where t.id = r.team_id),
    'grp', (select t.grp from public.kubb_teams t where t.id = r.team_id)
  );
end $$;

create or replace function public.kubb_require(p_code text, p_admin boolean)
returns text
language plpgsql security definer set search_path = public as $$
declare v_role text;
begin
  select c.role into v_role from public.kubb_codes c where c.code = trim(coalesce(p_code,''));
  if v_role is null then raise exception 'Ugyldig kode';
  end if;
  if p_admin and v_role <> 'admin' then raise exception 'Krever arrangørkode';
  end if;
  return v_role;
end $$;

-- Tildel ledige baner til neste kamper i køen
create or replace function public.kubb_assign_courts() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_courts int;
  c int;
  v_busy uuid[];
  v_id uuid;
begin
  select num_courts into v_courts from public.kubb_tournament where id = 1;
  for c in 1..v_courts loop
    if exists (select 1 from public.kubb_matches m where m.court = c and m.status in ('ready','live','paused')) then
      continue;
    end if;
    select coalesce(array_agg(x), '{}'::uuid[]) into v_busy from (
      select team_a as x from public.kubb_matches where status in ('ready','live','paused') and team_a is not null
      union
      select team_b from public.kubb_matches where status in ('ready','live','paused') and team_b is not null
    ) s;
    select m.id into v_id from public.kubb_matches m
      where m.status = 'queued'
        and m.team_a is not null and m.team_b is not null
        and not (m.team_a = any(v_busy))
        and not (m.team_b = any(v_busy))
      order by m.order_no, m.created_at
      limit 1;
    if v_id is not null then
      update public.kubb_matches set court = c, status = 'ready' where id = v_id;
    end if;
  end loop;
end $$;

create or replace function public.kubb_start_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, false);
  update public.kubb_matches
     set status = 'live', started_at = now(), paused_at = null, pause_accum = 0
   where id = p_match and status in ('ready','queued');
  if not found then raise exception 'Kampen kan ikke startes'; end if;
end $$;

create or replace function public.kubb_pause_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, false);
  update public.kubb_matches set status = 'paused', paused_at = now()
   where id = p_match and status = 'live';
end $$;

create or replace function public.kubb_resume_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, false);
  update public.kubb_matches
     set status = 'live',
         pause_accum = pause_accum + greatest(0, extract(epoch from (now() - paused_at))::int),
         paused_at = null
   where id = p_match and status = 'paused';
end $$;

-- Send vinner/taper videre i sluttspillet
create or replace function public.kubb_propagate(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m record; v_win uuid; v_lose uuid;
begin
  select * into m from public.kubb_matches where id = p_match;
  if m.result is null then return; end if;
  if m.result = 'a' then v_win := m.team_a; v_lose := m.team_b;
  elsif m.result = 'b' then v_win := m.team_b; v_lose := m.team_a;
  else return; -- uavgjort avgjør ikke sluttspill
  end if;

  if m.feeds_match is not null then
    if m.feeds_side = 'a' then
      update public.kubb_matches set team_a = v_win where id = m.feeds_match;
    else
      update public.kubb_matches set team_b = v_win where id = m.feeds_match;
    end if;
  end if;
  if m.loser_feeds_match is not null then
    if m.loser_feeds_side = 'a' then
      update public.kubb_matches set team_a = v_lose where id = m.loser_feeds_match;
    else
      update public.kubb_matches set team_b = v_lose where id = m.loser_feeds_match;
    end if;
  end if;
end $$;

create or replace function public.kubb_finish_match(
  p_code text, p_match uuid, p_result text, p_score_a int default null, p_score_b int default null)
returns void language plpgsql security definer set search_path = public as $$
declare m record;
begin
  perform public.kubb_require(p_code, false);
  if p_result not in ('a','b','draw') then raise exception 'Ugyldig resultat'; end if;
  select * into m from public.kubb_matches where id = p_match;
  if m is null then raise exception 'Fant ikke kampen'; end if;
  if m.stage <> 'group' and p_result = 'draw' then
    raise exception 'Sluttspillkamper kan ikke ende uavgjort';
  end if;
  update public.kubb_matches
     set status = 'finished', result = p_result, score_a = p_score_a, score_b = p_score_b,
         ended_at = now(), court = null, paused_at = null
   where id = p_match;
  perform public.kubb_propagate(p_match);
  perform public.kubb_assign_courts();
end $$;

create or replace function public.kubb_reopen_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  update public.kubb_matches
     set status = 'queued', result = null, score_a = null, score_b = null,
         started_at = null, ended_at = null, paused_at = null, pause_accum = 0, court = null
   where id = p_match;
  perform public.kubb_assign_courts();
end $$;

create or replace function public.kubb_set_court(p_code text, p_match uuid, p_court int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  if p_court is null then
    update public.kubb_matches set court = null, status = 'queued' where id = p_match and status = 'ready';
  else
    if exists (select 1 from public.kubb_matches where court = p_court and status in ('ready','live','paused') and id <> p_match) then
      raise exception 'Banen er opptatt';
    end if;
    update public.kubb_matches set court = p_court, status = 'ready' where id = p_match and status = 'queued';
  end if;
end $$;
