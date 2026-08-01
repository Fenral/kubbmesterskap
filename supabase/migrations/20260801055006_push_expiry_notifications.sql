create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create table if not exists public.kubb_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  team_id uuid references public.kubb_teams(id) on delete cascade,
  is_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.kubb_push_deliveries (
  match_id uuid not null references public.kubb_matches(id) on delete cascade,
  subscription_id uuid not null references public.kubb_push_subscriptions(id) on delete cascade,
  expires_at timestamptz not null,
  sent_at timestamptz not null default now(),
  primary key (match_id, subscription_id, expires_at)
);

alter table public.kubb_push_subscriptions enable row level security;
alter table public.kubb_push_deliveries enable row level security;
revoke all on public.kubb_push_subscriptions from public, anon, authenticated;
revoke all on public.kubb_push_deliveries from public, anon, authenticated;
grant all on public.kubb_push_subscriptions to service_role;
grant all on public.kubb_push_deliveries to service_role;

create or replace function public.kubb_register_push_subscription(
  p_code text,
  p_subscription jsonb
) returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  v_team uuid;
  v_endpoint text := p_subscription->>'endpoint';
  v_p256dh text := p_subscription->'keys'->>'p256dh';
  v_auth text := p_subscription->'keys'->>'auth';
begin
  select c.role, c.team_id into v_role, v_team
    from public.kubb_codes c
   where c.code = trim(coalesce(p_code, ''));
  if v_role is null then raise exception 'Ugyldig kode'; end if;
  if v_endpoint is null or v_endpoint !~ '^https://' or v_p256dh is null or v_auth is null then
    raise exception 'Ugyldig push-abonnement';
  end if;

  insert into public.kubb_push_subscriptions(endpoint, p256dh, auth, team_id, is_admin)
  values (v_endpoint, v_p256dh, v_auth, v_team, v_role = 'admin')
  on conflict (endpoint) do update
    set p256dh = excluded.p256dh,
        auth = excluded.auth,
        team_id = excluded.team_id,
        is_admin = excluded.is_admin,
        updated_at = now();
  return true;
end $$;

revoke execute on function public.kubb_register_push_subscription(text, jsonb) from public;
grant execute on function public.kubb_register_push_subscription(text, jsonb) to anon, authenticated;

create index if not exists kubb_push_subscriptions_team_idx
  on public.kubb_push_subscriptions(team_id);
