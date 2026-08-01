-- Time expiry is only a visual and audible signal. The organizer still decides
-- the result, because a match may have been won at the final moment.
create or replace function public.kubb_finish_expired_matches(p_code text)
returns int language plpgsql security definer set search_path = public as $$
begin
  perform public.kubb_require(p_code, true);
  return 0;
end $$;

comment on function public.kubb_finish_expired_matches(text) is
  'Compatibility no-op: expired matches stay live until the organizer records a result.';
