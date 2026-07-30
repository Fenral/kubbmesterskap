
create or replace function public.kubb_admin_generate_playoff(p_code text, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q int; n int; sz int; len int; i int; ridx int := 1; mc int;
  qual uuid[] := '{}'; qnames text[] := '{}';
  ord int[]; nord int[];
  cur_team uuid[] := '{}'; cur_match uuid[] := '{}'; cur_label text[] := '{}';
  nx_team uuid[]; nx_match uuid[]; nx_label text[];
  ta uuid; tb uuid; ma uuid; mb uuid;
  rname text; rlabel text; mlabel text; new_id uuid;
  sf uuid[] := '{}'; bronze uuid; total int := 0;
  rec record;
begin
  perform public.kubb_require(p_code, true);

  if not p_force and exists (select 1 from public.kubb_matches where stage = 'group' and status <> 'finished') then
    raise exception 'Det er fortsatt uspilte gruppekamper';
  end if;

  select qualifiers_per_group into q from public.kubb_tournament where id = 1;

  for rec in
    select s.team_id, s.name from public.kubb_standings s
    where s.pos <= q
    order by s.pos, s.points desc, s.kubb_diff desc, s.name
  loop
    qual := qual || rec.team_id;
    qnames := qnames || rec.name;
  end loop;

  n := coalesce(array_length(qual,1), 0);
  if n < 2 then raise exception 'For få lag til sluttspill'; end if;

  sz := 2;
  while sz < n loop sz := sz * 2; end loop;

  ord := array[1];
  while coalesce(array_length(ord,1),0) < sz loop
    len := array_length(ord,1);
    nord := '{}';
    for i in 1..len loop
      nord := nord || ord[i] || (2*len + 1 - ord[i]);
    end loop;
    ord := nord;
  end loop;

  for i in 1..sz loop
    if ord[i] <= n then
      cur_team := cur_team || qual[ord[i]];
      cur_label := cur_label || qnames[ord[i]];
    else
      cur_team := cur_team || null::uuid;
      cur_label := cur_label || 'Bye';
    end if;
    cur_match := cur_match || null::uuid;
  end loop;

  delete from public.kubb_matches where stage <> 'group';

  while array_length(cur_team,1) > 1 loop
    mc := array_length(cur_team,1) / 2;
    rname  := case mc when 1 then 'final' when 2 then 'sf' when 4 then 'qf' when 8 then 'r16' else 'r'||(mc*2) end;
    rlabel := case mc when 1 then 'Finale' when 2 then 'Semifinale' when 4 then 'Kvartfinale'
                      when 8 then 'Åttendedelsfinale' else (mc*2)||'-delsfinale' end;
    nx_team := '{}'; nx_match := '{}'; nx_label := '{}';

    for i in 1..mc loop
      ta := cur_team[2*i-1]; tb := cur_team[2*i];
      ma := cur_match[2*i-1]; mb := cur_match[2*i];

      if ma is null and mb is null and (ta is null) <> (tb is null) then
        -- walkover: laget går rett videre
        nx_team  := nx_team  || coalesce(ta, tb);
        nx_match := nx_match || null::uuid;
        nx_label := nx_label || case when ta is not null then cur_label[2*i-1] else cur_label[2*i] end;
        continue;
      end if;

      new_id := gen_random_uuid();
      mlabel := rlabel || case when mc > 1 then ' ' || i else '' end;
      insert into public.kubb_matches
        (id, stage, round, slot, label, team_a, team_b, source_a, source_b, order_no)
      values
        (new_id, rname, ridx, i, mlabel, ta, tb, cur_label[2*i-1], cur_label[2*i], 100000 + ridx*1000 + i);
      total := total + 1;

      if ma is not null then update public.kubb_matches set feeds_match = new_id, feeds_side = 'a' where id = ma; end if;
      if mb is not null then update public.kubb_matches set feeds_match = new_id, feeds_side = 'b' where id = mb; end if;
      if rname = 'sf' then sf := sf || new_id; end if;

      nx_team := nx_team || null::uuid;
      nx_match := nx_match || new_id;
      nx_label := nx_label || ('Vinner ' || mlabel);
    end loop;

    cur_team := nx_team; cur_match := nx_match; cur_label := nx_label;
    ridx := ridx + 1;
  end loop;

  if array_length(sf,1) = 2 then
    bronze := gen_random_uuid();
    insert into public.kubb_matches (id, stage, round, slot, label, source_a, source_b, order_no)
      values (bronze, 'bronze', ridx, 1, 'Bronsefinale', 'Taper Semifinale 1', 'Taper Semifinale 2', 100000 + ridx*1000);
    update public.kubb_matches set loser_feeds_match = bronze, loser_feeds_side = 'a' where id = sf[1];
    update public.kubb_matches set loser_feeds_match = bronze, loser_feeds_side = 'b' where id = sf[2];
    total := total + 1;
  end if;

  update public.kubb_tournament set phase = 'playoff', updated_at = now() where id = 1;
  perform public.kubb_assign_courts();
  return jsonb_build_object('ok', true, 'matches', total, 'teams', n);
end $$;

-- Hent koder (kun arrangør)
create or replace function public.kubb_admin_codes(p_code text)
returns table(team_id uuid, team_name text, grp text, code text)
language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  return query
    select t.id, t.name, t.grp, c.code
    from public.kubb_teams t join public.kubb_codes c on c.team_id = t.id
    order by t.grp, t.seed, t.name;
end $$;

create or replace function public.kubb_admin_set_admin_code(p_code text, p_new text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  if p_new !~ '^[0-9]{4,8}$' then raise exception 'Koden må være 4-8 siffer'; end if;
  if exists (select 1 from public.kubb_codes where code = p_new and role <> 'admin') then
    raise exception 'Koden er i bruk';
  end if;
  update public.kubb_codes set code = p_new where role = 'admin';
end $$;
