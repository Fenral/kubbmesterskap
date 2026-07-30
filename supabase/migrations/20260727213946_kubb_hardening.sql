
-- 1) Interne hjelpefunksjoner skal ikke kunne kalles fra nettet.
--    De kjøres fra SECURITY DEFINER-funksjoner og trenger ingen ekstern EXECUTE.
revoke execute on function public.kubb_assign_courts()                     from public, anon, authenticated;
revoke execute on function public.kubb_propagate(uuid)                     from public, anon, authenticated;
revoke execute on function public.kubb_role(text)                          from public, anon, authenticated;
revoke execute on function public.kubb_require(text, boolean)              from public, anon, authenticated;

-- 2) Fast search_path
create or replace function public.kubb_now() returns timestamptz
language sql stable security invoker set search_path = public as $$ select now() $$;

-- 3) Bremse mot gjetting av koder: teller feilforsøk i et rullende vindu
create table if not exists public.kubb_login_attempts (
  at timestamptz not null default now(),
  ok boolean not null
);
create index if not exists kubb_login_attempts_at_idx on public.kubb_login_attempts(at desc);
alter table public.kubb_login_attempts enable row level security;
-- ingen policyer: bare SECURITY DEFINER-funksjonen skriver hit

create or replace function public.kubb_login(p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_fails int;
begin
  delete from public.kubb_login_attempts where at < now() - interval '10 minutes';

  select count(*) into v_fails
    from public.kubb_login_attempts
   where ok = false and at > now() - interval '60 seconds';

  if v_fails >= 15 then
    return jsonb_build_object('ok', false, 'error', 'For mange forsøk. Vent et minutt.');
  end if;

  select c.role, c.team_id into r from public.kubb_codes c where c.code = trim(coalesce(p_code,''));

  if not found then
    insert into public.kubb_login_attempts (ok) values (false);
    perform pg_sleep(0.25);
    return jsonb_build_object('ok', false, 'error', 'Ugyldig kode');
  end if;

  insert into public.kubb_login_attempts (ok) values (true);
  return jsonb_build_object(
    'ok', true,
    'role', r.role,
    'team_id', r.team_id,
    'team_name', (select t.name from public.kubb_teams t where t.id = r.team_id),
    'grp', (select t.grp from public.kubb_teams t where t.id = r.team_id)
  );
end $$;

-- 4) Storage: bare selve app-filen skal være lesbar, ikke hele bøtta
drop policy if exists kubb_pub_read on storage.objects;
create policy kubb_pub_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'kubb' and name = 'index.html');
