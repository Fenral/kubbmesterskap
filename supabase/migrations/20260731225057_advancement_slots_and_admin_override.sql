-- Synlig fordelingsmatrise fra gruppespill 1 til A1/A2/B1/B2.
-- Automatiske plasser leses direkte fra tabellen når en kildegruppe er ferdig.
-- Arrangøren kan overstyre enkeltplasser før gruppespill 2 opprettes.

create table if not exists public.kubb_advancement_overrides (
  destination_grp text not null check (destination_grp in ('A1','A2','B1','B2')),
  destination_slot int not null check (destination_slot between 1 and 4),
  team_id uuid not null references public.kubb_teams(id) on delete cascade,
  changed_at timestamptz not null default now(),
  primary key (destination_grp, destination_slot),
  unique (team_id)
);

alter table public.kubb_advancement_overrides enable row level security;
drop policy if exists kubb_advancement_override_read on public.kubb_advancement_overrides;
create policy kubb_advancement_override_read on public.kubb_advancement_overrides
  for select to anon, authenticated using (true);
revoke insert, update, delete on public.kubb_advancement_overrides from public, anon, authenticated;
grant select on public.kubb_advancement_overrides to anon, authenticated;

drop view if exists public.kubb_advancement_slots;
create view public.kubb_advancement_slots
with (security_invoker = on) as
with mapping(destination_stage, destination_grp, destination_slot, source_grp, source_pos) as (
  values
    ('a_group', 'A1', 1, 'A', 1),
    ('a_group', 'A1', 2, 'B', 2),
    ('a_group', 'A1', 3, 'C', 1),
    ('a_group', 'A1', 4, 'D', 2),
    ('a_group', 'A2', 1, 'A', 2),
    ('a_group', 'A2', 2, 'B', 1),
    ('a_group', 'A2', 3, 'C', 2),
    ('a_group', 'A2', 4, 'D', 1),
    ('b_group', 'B1', 1, 'A', 3),
    ('b_group', 'B1', 2, 'B', 4),
    ('b_group', 'B1', 3, 'C', 3),
    ('b_group', 'B1', 4, 'D', 4),
    ('b_group', 'B2', 1, 'A', 4),
    ('b_group', 'B2', 2, 'B', 3),
    ('b_group', 'B2', 3, 'C', 4),
    ('b_group', 'B2', 4, 'D', 3)
), completed_groups as (
  select m.grp
    from public.kubb_matches m
   where m.stage = 'group'
   group by m.grp
  having bool_and(m.status = 'finished')
), unresolved_groups as (
  select second_place.grp
    from public.kubb_standings second_place
    join public.kubb_standings third_place
      on third_place.stage = second_place.stage
     and third_place.grp = second_place.grp
     and third_place.pos = 3
   where second_place.stage = 'group'
     and second_place.pos = 2
     and second_place.points = third_place.points
     and second_place.head_to_head_points = third_place.head_to_head_points
     and (second_place.shootout_rank is null or third_place.shootout_rank is null)
), candidates as (
  select m.*,
         (c.grp is not null) as source_complete,
         (u.grp is not null) as source_needs_tiebreak,
         s.team_id as ranked_team_id,
         o.team_id as manual_team_id
    from mapping m
    left join completed_groups c on c.grp = m.source_grp
    left join unresolved_groups u on u.grp = m.source_grp
    left join public.kubb_standings s
      on s.stage = 'group' and s.grp = m.source_grp and s.pos = m.source_pos
    left join public.kubb_advancement_overrides o
      on o.destination_grp = m.destination_grp and o.destination_slot = m.destination_slot
), resolved as (
  select c.*,
         case
           when c.manual_team_id is not null then c.manual_team_id
           when c.source_complete and not c.source_needs_tiebreak
             and not exists (
               select 1 from public.kubb_advancement_overrides taken
                where taken.team_id = c.ranked_team_id
             ) then c.ranked_team_id
           else null
         end as team_id
    from candidates c
)
select r.destination_stage,
       r.destination_grp,
       r.destination_slot,
       r.source_grp,
       r.source_pos,
       r.team_id,
       t.name as team_name,
       (r.manual_team_id is not null) as is_manual,
       r.source_complete,
       r.source_needs_tiebreak,
       case
         when r.manual_team_id is not null then 'manual'
         when not r.source_complete then 'waiting'
         when r.source_needs_tiebreak then 'tiebreak'
         when r.team_id is not null then 'automatic'
         else 'missing'
       end as placement_status
  from resolved r
  left join public.kubb_teams t on t.id = r.team_id and t.withdrawn_at is null;

grant select on public.kubb_advancement_slots to anon, authenticated;

create or replace function public.kubb_admin_set_advancement_slot(
  p_code text, p_destination_grp text, p_destination_slot int, p_team uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_phase text;
  v_team_name text;
  v_existing text;
begin
  perform public.kubb_require(p_code, true);
  select phase into v_phase from public.kubb_tournament where id = 1 for update;
  if v_phase not in ('group', 'group_review') then
    raise exception 'Plassene kan bare endres for gruppespill 2 starter';
  end if;
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
    return jsonb_build_object('ok', true, 'mode', 'automatic');
  end if;

  select name into v_team_name
    from public.kubb_teams
   where id = p_team and withdrawn_at is null;
  if not found then raise exception 'Fant ikke et aktivt lag'; end if;

  select destination_grp || ', plass ' || destination_slot into v_existing
    from public.kubb_advancement_overrides
   where team_id = p_team
     and (destination_grp, destination_slot) <> (p_destination_grp, p_destination_slot);
  if found then
    delete from public.kubb_advancement_overrides where team_id = p_team;
  end if;

  insert into public.kubb_advancement_overrides(destination_grp, destination_slot, team_id, changed_at)
  values (p_destination_grp, p_destination_slot, p_team, now())
  on conflict (destination_grp, destination_slot) do update
    set team_id = excluded.team_id, changed_at = excluded.changed_at;

  perform public.kubb_log_admin_action(
    p_code, 'advancement', 'Satte ' || v_team_name || ' inn i ' || p_destination_grp || ', plass ' || p_destination_slot ||
      case when v_existing is not null then ' (flyttet fra ' || v_existing || ')' else '' end,
    null, null, false
  );
  return jsonb_build_object('ok', true, 'mode', 'manual', 'team', v_team_name);
end $$;

revoke execute on function public.kubb_admin_set_advancement_slot(text, text, int, uuid) from public;
grant execute on function public.kubb_admin_set_advancement_slot(text, text, int, uuid) to anon, authenticated;

create or replace function public.kubb_create_final_groups() returns int
language plpgsql security definer set search_path = public as $$
declare
  a1 uuid[]; a2 uuid[]; b1 uuid[]; b2 uuid[];
  total int := 0; v_slots int; v_filled int; v_unique int;
begin
  if exists (select 1 from public.kubb_matches where stage in ('a_group', 'b_group')) then return 0; end if;
  if exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then return 0; end if;
  if public.kubb_has_unresolved_cutoff_tie('group') then return 0; end if;

  select count(*)::int, count(team_id)::int, count(distinct team_id)::int
    into v_slots, v_filled, v_unique
    from public.kubb_advancement_slots;
  if v_slots <> 16 or v_filled <> 16 or v_unique <> 16 then return 0; end if;

  select array_agg(team_id order by destination_slot) into a1
    from public.kubb_advancement_slots where destination_grp = 'A1';
  select array_agg(team_id order by destination_slot) into a2
    from public.kubb_advancement_slots where destination_grp = 'A2';
  select array_agg(team_id order by destination_slot) into b1
    from public.kubb_advancement_slots where destination_grp = 'B1';
  select array_agg(team_id order by destination_slot) into b2
    from public.kubb_advancement_slots where destination_grp = 'B2';

  total := total + public.kubb_make_round_robin('a_group', 'A1', a1, 200000, 'A1-pulje');
  total := total + public.kubb_make_round_robin('a_group', 'A2', a2, 220000, 'A2-pulje');
  total := total + public.kubb_make_round_robin('b_group', 'B1', b1, 300000, 'B1-pulje');
  total := total + public.kubb_make_round_robin('b_group', 'B2', b2, 320000, 'B2-pulje');
  update public.kubb_tournament set phase = 'final_groups', updated_at = now() where id = 1;
  return total;
end $$;

revoke execute on function public.kubb_create_final_groups() from public, anon, authenticated;
