-- Opprett hver pulje i gruppespill 2 så snart alle fire plassene er fylt.
-- Kampene er planlagt, men ikke tilgjengelige i banekøen før runde 2 starter.

create or replace function public.kubb_sync_final_group(p_grp text) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_stage text; v_label text; v_order_base int; v_phase text;
  v_teams uuid[]; v_wanted uuid[]; v_current uuid[];
  v_filled int; v_unique int; v_matches int; v_created int;
begin
  case p_grp
    when 'A1' then v_stage := 'a_group'; v_label := 'A1-pulje'; v_order_base := 200000;
    when 'A2' then v_stage := 'a_group'; v_label := 'A2-pulje'; v_order_base := 220000;
    when 'B1' then v_stage := 'b_group'; v_label := 'B1-pulje'; v_order_base := 300000;
    when 'B2' then v_stage := 'b_group'; v_label := 'B2-pulje'; v_order_base := 320000;
    else raise exception 'Ugyldig pulje i gruppespill 2';
  end case;

  select array_agg(team_id order by destination_slot), count(team_id)::int, count(distinct team_id)::int
    into v_teams, v_filled, v_unique
    from public.kubb_advancement_slots
   where destination_grp = p_grp;

  select count(*)::int into v_matches
    from public.kubb_matches where stage = v_stage and grp = p_grp;

  -- En startet pulje er låst. Resultater skal aldri forsvinne ved en senere synk.
  if exists (
    select 1 from public.kubb_matches
     where stage = v_stage and grp = p_grp and status in ('live','paused','finished')
  ) then return v_matches; end if;

  if v_filled <> 4 or v_unique <> 4 then
    delete from public.kubb_matches where stage = v_stage and grp = p_grp;
    return 0;
  end if;

  select array_agg(team_id order by team_id) into v_wanted
    from unnest(v_teams) u(team_id);
  select array_agg(team_id order by team_id) into v_current
    from (
      select team_a as team_id from public.kubb_matches where stage = v_stage and grp = p_grp
      union
      select team_b from public.kubb_matches where stage = v_stage and grp = p_grp
    ) current_members
   where team_id is not null;

  select phase into v_phase from public.kubb_tournament where id = 1;
  if v_matches = 6 and v_current = v_wanted then
    update public.kubb_matches
       set status = case when v_phase = 'final_groups' then 'queued' else 'scheduled' end,
           court = null, ready_at = null
     where stage = v_stage and grp = p_grp and status in ('scheduled','queued','ready');
    return 6;
  end if;

  delete from public.kubb_matches where stage = v_stage and grp = p_grp;
  v_created := public.kubb_make_round_robin(v_stage, p_grp, v_teams, v_order_base, v_label);
  update public.kubb_matches
     set status = case when v_phase = 'final_groups' then 'queued' else 'scheduled' end
   where stage = v_stage and grp = p_grp;
  return v_created;
end $$;

revoke execute on function public.kubb_sync_final_group(text) from public, anon, authenticated;

create or replace function public.kubb_sync_all_final_groups() returns int
language plpgsql security definer set search_path = public as $$
declare v_total int := 0; v_grp text;
begin
  foreach v_grp in array array['A1','A2','B1','B2'] loop
    v_total := v_total + public.kubb_sync_final_group(v_grp);
  end loop;
  return v_total;
end $$;

revoke execute on function public.kubb_sync_all_final_groups() from public, anon, authenticated;

create or replace function public.kubb_sync_final_groups_after_match_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.stage = 'group' then perform public.kubb_sync_all_final_groups(); end if;
  return new;
end $$;

drop trigger if exists kubb_sync_final_groups_after_match_change on public.kubb_matches;
create trigger kubb_sync_final_groups_after_match_change
after update of status, result, team_a, team_b on public.kubb_matches
for each row execute function public.kubb_sync_final_groups_after_match_change();
revoke execute on function public.kubb_sync_final_groups_after_match_change() from public, anon, authenticated;

create or replace function public.kubb_sync_final_groups_after_tiebreak_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (case when tg_op = 'DELETE' then old.stage else new.stage end) = 'group' then
    perform public.kubb_sync_all_final_groups();
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

drop trigger if exists kubb_sync_final_groups_after_tiebreak_change on public.kubb_tiebreaks;
create trigger kubb_sync_final_groups_after_tiebreak_change
after insert or update or delete on public.kubb_tiebreaks
for each row execute function public.kubb_sync_final_groups_after_tiebreak_change();
revoke execute on function public.kubb_sync_final_groups_after_tiebreak_change() from public, anon, authenticated;

create or replace function public.kubb_admin_set_advancement_slot(
  p_code text, p_destination_grp text, p_destination_slot int, p_team uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_phase text; v_team_name text; v_existing_grp text; v_existing_slot int; v_matches int;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase not in ('group', 'group_review', 'final_groups') then
    raise exception 'Plassene kan bare endres for knockoutspillet';
  end if;
  if exists (
    select 1 from public.kubb_matches
     where stage in ('a_group','b_group') and status in ('live','paused','finished')
  ) then raise exception 'Plassene er last etter at forste kamp i gruppespill 2 har startet'; end if;
  if p_destination_grp not in ('A1','A2','B1','B2') or p_destination_slot not between 1 and 4 then
    raise exception 'Ugyldig plass i gruppespill 2';
  end if;

  if p_team is null then
    delete from public.kubb_advancement_overrides
     where destination_grp = p_destination_grp and destination_slot = p_destination_slot;
    perform public.kubb_log_admin_action(
      p_code, 'advancement', 'Tilbakestilte plass ' || p_destination_slot || ' i ' || p_destination_grp || ' til automatisk',
      null, null, false
    );
    v_matches := public.kubb_sync_all_final_groups();
    return jsonb_build_object('ok', true, 'mode', 'automatic', 'matches', v_matches);
  end if;

  select name into v_team_name from public.kubb_teams where id = p_team and withdrawn_at is null;
  if not found then raise exception 'Fant ikke et aktivt lag'; end if;

  select destination_grp, destination_slot into v_existing_grp, v_existing_slot
    from public.kubb_advancement_overrides
   where team_id = p_team
     and (destination_grp, destination_slot) <> (p_destination_grp, p_destination_slot);
  if found then delete from public.kubb_advancement_overrides where team_id = p_team; end if;

  insert into public.kubb_advancement_overrides(destination_grp, destination_slot, team_id, changed_at)
  values (p_destination_grp, p_destination_slot, p_team, now())
  on conflict (destination_grp, destination_slot) do update
    set team_id = excluded.team_id, changed_at = excluded.changed_at;

  perform public.kubb_log_admin_action(
    p_code, 'advancement', 'Satte ' || v_team_name || ' inn i ' || p_destination_grp || ', plass ' || p_destination_slot ||
      case when v_existing_grp is not null then ' (flyttet fra ' || v_existing_grp || ', plass ' || v_existing_slot || ')' else '' end,
    null, null, false
  );
  v_matches := public.kubb_sync_all_final_groups();
  return jsonb_build_object('ok', true, 'mode', 'manual', 'team', v_team_name, 'matches', v_matches);
end $$;

revoke execute on function public.kubb_admin_set_advancement_slot(text, text, int, uuid) from public;
grant execute on function public.kubb_admin_set_advancement_slot(text, text, int, uuid) to anon, authenticated;

create or replace function public.kubb_create_final_groups() returns int
language plpgsql security definer set search_path = public as $$
declare v_total int; v_filled int; v_unique int;
begin
  if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then return 0; end if;
  if public.kubb_has_unresolved_cutoff_tie('group') then return 0; end if;
  select count(team_id)::int, count(distinct team_id)::int into v_filled, v_unique
    from public.kubb_advancement_slots;
  if v_filled <> 16 or v_unique <> 16 then return 0; end if;

  perform public.kubb_sync_all_final_groups();
  select count(*)::int into v_total
    from public.kubb_matches where stage in ('a_group','b_group');
  if v_total <> 24 then return 0; end if;

  update public.kubb_matches set status = 'queued', court = null, ready_at = null
   where stage in ('a_group','b_group') and status in ('scheduled','queued','ready');
  update public.kubb_tournament set phase = 'final_groups', updated_at = now() where id = 1;
  return v_total;
end $$;

revoke execute on function public.kubb_create_final_groups() from public, anon, authenticated;

-- Fyll eventuelle puljer som allerede er klare når migrasjonen tas i bruk.
do $$ begin perform public.kubb_sync_all_final_groups(); end $$;
