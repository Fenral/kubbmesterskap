
create or replace function public.kubb_admin_set_teams(p_code text, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; v_code text; v_id uuid; n int := 0;
begin
  perform public.kubb_require(p_code, true);
  delete from public.kubb_matches where id is not null;
  delete from public.kubb_teams   where id is not null;
  delete from public.kubb_codes   where role = 'team';

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

create or replace function public.kubb_admin_start_tournament(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g record; arr uuid[]; m int; r int; i int; gi int := 0;
  a uuid; b uuid; tmp uuid; total int := 0;
begin
  perform public.kubb_require(p_code, true);
  delete from public.kubb_matches where id is not null;

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
  delete from public.kubb_matches where id is not null;
  delete from public.kubb_teams   where id is not null;
  delete from public.kubb_codes   where role = 'team';
  update public.kubb_tournament set phase = 'setup', updated_at = now() where id = 1;
end $$;
