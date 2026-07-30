
create or replace view public.kubb_standings
with (security_invoker = on) as
with res as (
  select m.team_a as team,
         case m.result when 'a' then 3 when 'draw' then 1 else 0 end as pts,
         (m.result='a')::int as w, (m.result='draw')::int as d, (m.result='b')::int as l,
         coalesce(m.score_a,0) as gf, coalesce(m.score_b,0) as ga
  from public.kubb_matches m
  where m.stage='group' and m.status='finished' and m.result is not null and m.team_a is not null
  union all
  select m.team_b,
         case m.result when 'b' then 3 when 'draw' then 1 else 0 end,
         (m.result='b')::int, (m.result='draw')::int, (m.result='a')::int,
         coalesce(m.score_b,0), coalesce(m.score_a,0)
  from public.kubb_matches m
  where m.stage='group' and m.status='finished' and m.result is not null and m.team_b is not null
)
select t.id as team_id, t.name, t.grp,
  coalesce(count(r.team),0)::int as played,
  coalesce(sum(r.w),0)::int as wins,
  coalesce(sum(r.d),0)::int as draws,
  coalesce(sum(r.l),0)::int as losses,
  coalesce(sum(r.pts),0)::int as points,
  coalesce(sum(r.gf),0)::int as kubb_for,
  coalesce(sum(r.ga),0)::int as kubb_against,
  coalesce(sum(r.gf) - sum(r.ga),0)::int as kubb_diff,
  rank() over (
    partition by t.grp
    order by coalesce(sum(r.pts),0) desc, coalesce(sum(r.w),0) desc,
             coalesce(sum(r.gf) - sum(r.ga),0) desc, t.name
  )::int as pos
from public.kubb_teams t
left join res r on r.team = t.id
group by t.id, t.name, t.grp;

grant select on public.kubb_standings to anon, authenticated;

create or replace function public.kubb_admin_settings(
  p_code text, p_name text, p_minutes int, p_courts int, p_qualifiers int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  update public.kubb_tournament
     set name = coalesce(nullif(trim(p_name),''), name),
         match_seconds = greatest(60, coalesce(p_minutes,40) * 60),
         num_courts = greatest(1, least(20, coalesce(p_courts,6))),
         qualifiers_per_group = greatest(1, coalesce(p_qualifiers,2)),
         updated_at = now()
   where id = 1;
  perform public.kubb_assign_courts();
end $$;

create or replace function public.kubb_admin_set_teams(p_code text, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  it jsonb; v_code text; v_id uuid; n int := 0;
begin
  perform public.kubb_require(p_code, true);
  delete from public.kubb_matches;
  delete from public.kubb_teams;
  delete from public.kubb_codes where role = 'team';

  for it in select * from jsonb_array_elements(p_teams) loop
    n := n + 1;
    loop
      v_code := lpad((100 + floor(random()*8900))::int::text, 4, '0');
      exit when not exists (select 1 from public.kubb_codes c where c.code = v_code);
    end loop;
    insert into public.kubb_teams (name, grp, seed)
      values (coalesce(nullif(trim(it->>'name'),''), 'Lag '||n), upper(coalesce(nullif(trim(it->>'grp'),''),'A')), n)
      returning id into v_id;
    insert into public.kubb_codes (code, role, team_id) values (v_code, 'team', v_id);
  end loop;

  update public.kubb_tournament set phase = 'setup', updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'count', n);
end $$;

-- Generer alle gruppekamper (rundgang / circle method) og start turneringen
create or replace function public.kubb_admin_start_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g record; arr uuid[]; m int; r int; i int; gi int := 0;
  a uuid; b uuid; tmp uuid; total int := 0;
begin
  perform public.kubb_require(p_code, true);
  delete from public.kubb_matches;

  for g in select distinct grp from public.kubb_teams order by grp loop
    gi := gi + 1;
    select coalesce(array_agg(id order by seed, name), '{}'::uuid[]) into arr
      from public.kubb_teams where grp = g.grp;
    m := array_length(arr, 1);
    if m is null or m < 2 then continue; end if;
    if m % 2 = 1 then arr := arr || null::uuid; m := m + 1; end if;

    for r in 1..(m-1) loop
      for i in 1..(m/2) loop
        a := arr[i]; b := arr[m + 1 - i];
        if a is null or b is null then continue; end if;
        if (r + i) % 2 = 0 then tmp := a; a := b; b := tmp; end if;
        insert into public.kubb_matches (stage, grp, round, team_a, team_b, order_no, label)
          values ('group', g.grp, r, a, b, r*10000 + i*100 + gi, 'Pulje '||g.grp||' – runde '||r);
        total := total + 1;
      end loop;
      -- roter alle unntatt første
      arr := arr[1:1] || arr[m:m] || arr[2:m-1];
    end loop;
  end loop;

  update public.kubb_tournament set phase = 'group', updated_at = now() where id = 1;
  perform public.kubb_assign_courts();
  return jsonb_build_object('ok', true, 'matches', total);
end $$;

create or replace function public.kubb_admin_reset(p_code text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  delete from public.kubb_matches;
  delete from public.kubb_teams;
  delete from public.kubb_codes where role = 'team';
  update public.kubb_tournament set phase = 'setup', updated_at = now() where id = 1;
end $$;
