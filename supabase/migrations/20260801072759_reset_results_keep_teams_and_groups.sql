-- Start turneringen pa nytt uten a miste lag, puljer, lagkoder eller arrangorroller.
-- Dette er en mindre destruktiv operasjon enn kubb_admin_reset, som fortsatt er
-- reservert for tilfeller der hele lagoppsettet faktisk skal slettes.

create or replace function public.kubb_admin_reset_results(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_result jsonb;
  v_active_teams int;
  v_team_codes int;
  v_valid_groups int;
begin
  perform public.kubb_require(p_code, true);
  perform 1 from public.kubb_tournament where id = 1 for update;

  select count(*)::int into v_active_teams
    from public.kubb_teams where withdrawn_at is null;
  select count(*)::int into v_team_codes
    from public.kubb_codes c
    join public.kubb_teams t on t.id = c.team_id
   where t.withdrawn_at is null;
  select count(*)::int into v_valid_groups
    from (
      select grp
        from public.kubb_teams
       where withdrawn_at is null and grp in ('A','B','C','D')
       group by grp
      having count(*) = 4
    ) groups_of_four;

  if v_active_teams <> 16 or v_team_codes <> 16 or v_valid_groups <> 4 then
    raise exception 'Kan ikke nullstille kampene: forventet 16 aktive lag med kode i fire puljer';
  end if;

  perform public.kubb_log_admin_action(
    p_code,
    'reset_results',
    'Nullstilte alle kamper og beholdt lag, puljer og koder',
    null,
    null,
    false
  );

  delete from public.kubb_tiebreaks where team_id is not null;
  delete from public.kubb_advancement_overrides where team_id is not null;
  if to_regclass('public.kubb_push_deliveries') is not null then
    execute 'delete from public.kubb_push_deliveries where match_id is not null';
  end if;
  delete from public.kubb_matches where id is not null;

  update public.kubb_tournament
     set phase = 'setup',
         planned_matches = 0,
         drawn_at = null,
         completed_at = null,
         updated_at = now()
   where id = 1;

  select public.kubb_admin_start_tournament(p_code) into v_result;
  return v_result || jsonb_build_object(
    'reset', true,
    'teams_preserved', v_active_teams,
    'groups_preserved', v_valid_groups,
    'codes_preserved', v_team_codes
  );
end $$;

revoke execute on function public.kubb_admin_reset_results(text) from public;
grant execute on function public.kubb_admin_reset_results(text) to anon, authenticated;

comment on function public.kubb_admin_reset_results(text) is
  'Nullstiller turneringsforlopet og bygger kampene pa nytt, men beholder lag, puljer, koder og roller.';

-- Den eksisterende knappen og eldre klienter bruker dette navnet. Fra na av er
-- ogsa "Nullstill alt" trygg for lagoppsettet og dele-kodene.
create or replace function public.kubb_admin_reset(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_admin_reset_results(p_code);
end $$;

revoke execute on function public.kubb_admin_reset(text) from public;
grant execute on function public.kubb_admin_reset(text) to anon, authenticated;

comment on function public.kubb_admin_reset(text) is
  'Nullstiller kamper og resultater, men beholder lag, puljer, koder og roller.';
