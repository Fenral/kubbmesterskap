-- Banene fylles bare når arrangøren velger en startklar kamp.
-- Eksisterende kall beholdes som en ufarlig no-op, slik at turneringen aldri
-- setter en kamp på bane automatisk etter trekning, resultat eller timeout.
create or replace function public.kubb_assign_courts()
returns void language plpgsql security definer set search_path = public as $$
begin
  return;
end $$;

-- En kamp må være valgt til en konkret bane, og startes av arrangøren.
create or replace function public.kubb_start_match(p_code text, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  update public.kubb_matches
     set status = 'live', started_at = now(), paused_at = null, pause_accum = 0
   where id = p_match and status = 'ready';
  if not found then
    raise exception 'Kampen må velges til en bane før den kan startes';
  end if;
end $$;

-- Å velge kamp til en bane er også en ren arrangørhandling.
create or replace function public.kubb_select_court_match(p_code text, p_court int, p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare current_match uuid; candidate public.kubb_matches%rowtype; court_count int;
begin
  perform public.kubb_require(p_code, true);
  select num_courts into court_count from public.kubb_tournament where id = 1;
  if p_court is null or p_court < 1 or p_court > court_count then raise exception 'Ugyldig bane'; end if;
  select * into candidate from public.kubb_matches where id = p_match and status = 'queued';
  if not found or candidate.team_a is null or candidate.team_b is null then
    raise exception 'Denne kampen er ikke klar til å settes på bane';
  end if;
  select id into current_match from public.kubb_matches
   where court = p_court and status = 'ready' limit 1;
  if exists (
    select 1 from public.kubb_matches m
     where m.status in ('ready', 'live', 'paused')
       and m.id is distinct from current_match
       and (candidate.team_a in (m.team_a, m.team_b) or candidate.team_b in (m.team_a, m.team_b))
  ) then
    raise exception 'Ett av lagene spiller allerede på en annen bane';
  end if;
  if current_match is not null then
    update public.kubb_matches set status = 'queued', court = null where id = current_match;
  end if;
  update public.kubb_matches set status = 'ready', court = p_court where id = p_match;
end $$;

-- Start med et tomt baneoppsett. Kamper som allerede spilles beholdes.
update public.kubb_matches
   set status = 'queued', court = null
 where status = 'ready';
