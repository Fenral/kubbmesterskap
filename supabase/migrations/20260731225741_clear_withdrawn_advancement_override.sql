-- Et lag som strykes skal heller ikke bli hengende igjen i en manuell
-- plass i gruppespill 2.
create or replace function public.kubb_clear_advancement_override_on_withdraw()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.withdrawn_at is null and new.withdrawn_at is not null then
    delete from public.kubb_advancement_overrides where team_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists kubb_clear_advancement_override_after_withdraw on public.kubb_teams;
create trigger kubb_clear_advancement_override_after_withdraw
after update of withdrawn_at on public.kubb_teams
for each row execute function public.kubb_clear_advancement_override_on_withdraw();

revoke execute on function public.kubb_clear_advancement_override_on_withdraw() from public, anon, authenticated;
