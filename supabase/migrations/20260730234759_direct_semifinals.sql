-- Etter A- og B-gruppespillet går de fire beste i hver pulje rett til semifinaler.
-- Denne migrasjonen beholder pågående gruppespill, men erstatter et ubrukt
-- kvartfinaletre med et nytt semifinaleoppsett.

create or replace function public.kubb_admin_start_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g record; arr uuid[]; group_matches int := 0; playoff_matches int := 0; gi int := 0;
begin
  perform public.kubb_require(p_code, true);
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
  perform public.kubb_assign_courts();
  return jsonb_build_object('ok', true, 'group_matches', group_matches, 'playoff_matches', playoff_matches);
end $$;

do $$
begin
  if (select phase from public.kubb_tournament where id = 1) in ('group', 'final_groups')
     and exists (select 1 from public.kubb_matches where stage = 'group')
     and not exists (
       select 1 from public.kubb_matches
        where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$'
          and status in ('live', 'paused', 'finished')
     ) then
    delete from public.kubb_matches where stage ~ '^[ab]_(r[0-9]+|qf|sf|final|bronze)$';
    perform public.kubb_build_prepared_pool_bracket('a', 4, 'A-sluttspill', 400000);
    perform public.kubb_build_prepared_pool_bracket('b', 4, 'B-sluttspill', 500000);
  end if;
end $$;
