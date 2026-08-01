import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

const root = process.cwd();
const db = new PGlite();
const migrations = [
  '20260727201123_kubb_schema_init.sql',
  '20260727201150_kubb_secrets_split.sql',
  '20260727201256_kubb_core_functions.sql',
  '20260727201349_kubb_setup_and_standings.sql',
  '20260727201451_kubb_playoff.sql',
  '20260727202125_kubb_playoff_fix.sql',
  '20260727213946_kubb_hardening.sql',
  '20260727214106_kubb_fix_unqualified_deletes.sql',
  '20260730210000_kubb_final_groups_and_courts.sql',
  '20260730220000_kubb_admin_teams_and_fair_draw.sql',
  '20260730230000_kilkast_flexible_groups_and_playoff_tree.sql',
  '20260730234759_direct_semifinals.sql',
  '20260731000930_admin_controlled_court_start.sql',
  '20260731120000_admin_control_and_tournament_phases.sql',
  '20260731160000_remaining_admin_controls.sql',
  '20260731210000_fixed_format_shootouts_and_withdrawals.sql',
  '20260731213000_tiebreak_invalidation.sql',
  '20260731220000_simple_match_change_queue.sql',
  '20260731225057_advancement_slots_and_admin_override.sql',
  '20260731225741_clear_withdrawn_advancement_override.sql',
  '20260731231654_incremental_final_group_fixtures.sql',
  '20260801054611_keep_expired_matches_open.sql',
  '20260801070428_automatic_next_match_and_team_start.sql',
  '20260801072759_reset_results_keep_teams_and_groups.sql'
];

const CODE = 'ENDRE_MEG';
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const scalar = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const teamList = () => Array.from({ length:16 }, (_, i) => ({ name:`Lag ${i + 1}`, grp:'A' }));
const playMatch = async (id, result = 'draw', code = CODE) => {
  let match = await scalar('select status from public.kubb_matches where id = $1', [id]);
  if (match.status === 'queued') {
    await db.query("update public.kubb_matches set deferred_until = now() - interval '1 second' where id = $1 and deferred_until > now()", [id]);
    await db.query('select public.kubb_select_court_match($1,$2,$3)', [code, 1, id]);
  }
  match = await scalar('select status from public.kubb_matches where id = $1', [id]);
  if (match.status === 'ready') await db.query('select public.kubb_start_match($1,$2)', [code, id]);
  if (match.status === 'paused') await db.query('select public.kubb_resume_match($1,$2)', [code, id]);
  await db.query('select public.kubb_finish_match($1,$2,$3)', [code, id, result]);
};
const finishStageAsDraws = async stages => {
  const rows = await db.query('select id from public.kubb_matches where stage = any($1::text[]) and status <> $2 order by order_no', [stages, 'finished']);
  for (const row of rows.rows) await playMatch(row.id, 'draw');
};
const finishGroupBySeed = async grp => {
  const rows = await db.query(`
    select m.id, a.seed seed_a, b.seed seed_b
      from public.kubb_matches m
      join public.kubb_teams a on a.id = m.team_a
      join public.kubb_teams b on b.id = m.team_b
     where m.stage = 'group' and m.grp = $1 and m.status <> 'finished'
     order by m.order_no
  `, [grp]);
  for (const row of rows.rows) await playMatch(row.id, row.seed_a < row.seed_b ? 'a' : 'b');
};
const resolveAllCutoffTies = async stage => {
  const groups = await db.query('select distinct grp from public.kubb_standings where stage = $1 order by grp', [stage]);
  for (const { grp } of groups.rows) {
    const rows = await db.query('select team_id, points, head_to_head_points from public.kubb_standings where stage = $1 and grp = $2 order by name desc', [stage, grp]);
    const second = rows.rows.find((_, i) => i === 1);
    const cohort = rows.rows.filter(row => row.points === second.points && row.head_to_head_points === second.head_to_head_points);
    if (cohort.length > 1) {
      await db.query('select public.kubb_admin_set_tiebreak($1,$2,$3,$4::uuid[])', [CODE, stage, grp, cohort.map(row => row.team_id)]);
    }
  }
};

await db.exec('create role anon; create role authenticated; create schema storage; create table storage.objects (bucket_id text, name text);');
for (const name of migrations) {
  let sql = await readFile(join(root, 'supabase', 'migrations', name), 'utf8');
  sql = sql.replace(/^alter publication.*$/gm, '');
  await db.exec(sql);
}

// Oppsettet er alltid 16 lag og fire puljer med fire.
let wrongCountWorked = false;
try { await db.query('select public.kubb_admin_set_teams($1,$2::jsonb)', [CODE, JSON.stringify(teamList().slice(0,15))]); wrongCountWorked = true; } catch (_) {}
assert(!wrongCountWorked, 'team setup accepted fewer than 16 teams');
await db.query('select public.kubb_admin_set_teams($1,$2::jsonb)', [CODE, JSON.stringify(teamList())]);
let teamCode = await scalar("select code, team_id from public.kubb_codes where role = 'team' order by code limit 1");
await db.query("select public.kubb_admin_settings($1,'Kilkast test',40,2,2)", [CODE]);
await db.query('select public.kubb_admin_generate_groups($1)', [CODE]);

let groups = await db.query("select grp, count(*)::int n from public.kubb_teams where withdrawn_at is null group by grp order by grp");
assert(groups.rows.map(row => `${row.grp}:${row.n}`).join(',') === 'A:4,B:4,C:4,D:4', 'draw was not four groups of four');
let count = await scalar("select count(*)::int n from public.kubb_matches where stage = 'group'");
assert(count.n === 24, `expected 24 first-stage matches, got ${count.n}`);
let prepared = await scalar("select count(*)::int n from public.kubb_matches where stage ~ '^[ab]_(sf|final|bronze)$'");
assert(prepared.n === 8, `expected exactly eight prepared knockout matches, got ${prepared.n}`);
let tournament = await scalar('select phase, planned_matches from public.kubb_tournament where id = 1');
assert(tournament.phase === 'group' && tournament.planned_matches === 56, 'the fixed 56-match plan was not stored');
let redrawWorked = false;
try { await db.query('select public.kubb_admin_generate_groups($1)', [CODE]); redrawWorked = true; } catch (_) {}
assert(!redrawWorked, 'the public draw was not locked');

// Strykning fjerner laget, koden og samtlige kamper fra regnskapet.
const beforeRemoval = await scalar('select count(*)::int n from public.kubb_matches where team_a = $1 or team_b = $1', [teamCode.team_id]);
assert(beforeRemoval.n === 3, 'a team in a four-team group should have three matches');
await db.query("select public.kubb_admin_set_advancement_slot($1,'A1',1,$2)", [CODE, teamCode.team_id]);
let overrideCount = await scalar('select count(*)::int n from public.kubb_advancement_overrides where team_id = $1', [teamCode.team_id]);
assert(overrideCount.n === 1, 'manual advancement override was not stored');
const removed = (await db.query('select public.kubb_admin_remove_team($1,$2) value', [CODE, teamCode.team_id])).rows[0].value;
assert(removed.matches_removed === 3, 'not all team matches were struck');
const afterRemoval = await scalar('select count(*)::int n from public.kubb_matches where team_a = $1 or team_b = $1', [teamCode.team_id]);
const removedLogin = await scalar('select public.kubb_login($1) login', [teamCode.code]);
tournament = await scalar('select planned_matches from public.kubb_tournament where id = 1');
assert(afterRemoval.n === 0 && !removedLogin.login.ok, 'withdrawn team or code is still active');
overrideCount = await scalar('select count(*)::int n from public.kubb_advancement_overrides where team_id = $1', [teamCode.team_id]);
assert(overrideCount.n === 0, 'a withdrawn team remained in a manual advancement slot');
assert(tournament.planned_matches === 50, `expected 50 matches after a team withdrawal, got ${tournament.planned_matches}`);

// Rydd testdatabasen helt for a kunne sette opp neste isolerte scenario.
// Produktfunksjonen kubb_admin_reset beholder med vilje dagens lag og oppsett.
await db.exec(`
  delete from public.kubb_tiebreaks where team_id is not null;
  delete from public.kubb_advancement_overrides where team_id is not null;
  delete from public.kubb_matches where id is not null;
  delete from public.kubb_teams where id is not null;
  delete from public.kubb_codes where team_id is not null;
  update public.kubb_tournament
     set phase = 'setup', planned_matches = 0, drawn_at = null, completed_at = null
   where id = 1;
`);
await db.query('select public.kubb_admin_set_teams($1,$2::jsonb)', [CODE, JSON.stringify(teamList())]);
teamCode = await scalar("select code, team_id from public.kubb_codes where role = 'team' order by code limit 1");
const regenerated = (await db.query('select public.kubb_admin_regenerate_team_code($1,$2) value', [CODE, teamCode.team_id])).rows[0].value;
assert(regenerated.code && regenerated.code !== teamCode.code, 'team code was not regenerated');
await db.query("select public.kubb_admin_settings($1,'Kilkast test',40,2,2)", [CODE]);
await db.query('select public.kubb_admin_generate_groups($1)', [CODE]);

let advancement = await db.query('select * from public.kubb_advancement_slots order by destination_grp, destination_slot');
assert(advancement.rows.length === 16 && advancement.rows.every(row => row.placement_status === 'waiting'), 'the four second-stage groups were not prepared as 16 visible waiting slots');
await finishGroupBySeed('D');
advancement = await db.query('select * from public.kubb_advancement_slots order by destination_grp, destination_slot');
assert(advancement.rows.filter(row => row.source_grp === 'D' && row.placement_status === 'automatic' && row.team_id).length === 4, 'a completed first-stage group did not populate its four destinations automatically');
assert(advancement.rows.filter(row => row.source_grp !== 'D' && row.team_id === null).length === 12, 'unfinished source groups populated too early');

let automaticallyReady = await scalar("select id, court from public.kubb_matches where status = 'ready' order by ready_at desc limit 1");
assert(automaticallyReady?.court === 1, 'finishing a match did not immediately assign the next eligible match to the freed court');
await db.query("update public.kubb_matches set status = 'queued', court = null, ready_at = null where status = 'ready'");
await db.query("update public.kubb_matches set deferred_until = now() - interval '1 second' where deferred_until > now()");

const starter = await scalar(`
  select m.id, c.code
    from public.kubb_matches m
    join public.kubb_codes c on c.role = 'team' and c.team_id in (m.team_a, m.team_b)
   where m.stage = 'group' and m.status = 'queued'
   order by m.order_no limit 1
`);
await db.exec('begin');
await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 1, starter.id]);
await db.query('select public.kubb_start_match($1,$2)', [starter.code, starter.id]);
let teamStarted = await scalar('select status from public.kubb_matches where id = $1', [starter.id]);
assert(teamStarted.status === 'live', 'a participating team could not start its ready match');
const outsider = await scalar("select code from public.kubb_codes where role = 'team' and team_id not in (select team_a from public.kubb_matches where id = $1 union select team_b from public.kubb_matches where id = $1) limit 1", [starter.id]);
let outsiderCouldStart = false;
try { await db.query('select public.kubb_start_match($1,$2)', [outsider.code, starter.id]); outsiderCouldStart = true; } catch (_) {}
assert(!outsiderCouldStart, 'a team outside the match could start its clock');
await db.exec('rollback');

const first = await scalar("select id from public.kubb_matches where stage = 'group' and status = 'queued' order by order_no limit 1");
await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 1, first.id]);
const oldControls = await scalar(`select
  has_function_privilege('anon','public.kubb_admin_move_court_match(text,uuid,integer)','EXECUTE') as can_move,
  has_function_privilege('anon','public.kubb_admin_release_court_match(text,uuid)','EXECUTE') as can_release`);
assert(!oldControls.can_move && !oldControls.can_release, 'old move/release operations are still public');
const alternate = await scalar("select id from public.kubb_matches where stage = 'group' and status = 'queued' order by order_no limit 1");
await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 1, alternate.id]);
let delayed = await scalar('select status, court, extract(epoch from (deferred_until - now()))::int wait_seconds from public.kubb_matches where id = $1', [first.id]);
assert(delayed.status === 'queued' && delayed.court === null && delayed.wait_seconds >= 599 && delayed.wait_seconds <= 601, 'replaced match did not receive a ten-minute queue pause');
let earlySelectionWorked = false;
try { await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 2, first.id]); earlySelectionWorked = true; } catch (_) {}
assert(!earlySelectionWorked, 'a delayed match could be selected before ten minutes');
await db.query("update public.kubb_matches set deferred_until = now() - interval '1 second' where id = $1", [first.id]);
await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 1, first.id]);
let selected = await scalar('select status, court, deferred_until from public.kubb_matches where id = $1', [first.id]);
assert(selected.status === 'ready' && selected.court === 1 && selected.deferred_until === null, 'expired queue pause did not make the match selectable again');
await db.query('select public.kubb_admin_undo_last($1)', [CODE]);
selected = await scalar('select status, court from public.kubb_matches where id = $1', [alternate.id]);
assert(selected.status === 'ready' && selected.court === 1, 'undo did not restore the previously selected match');
await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 1, first.id]);
await db.query('select public.kubb_start_match($1,$2)', [CODE, first.id]);
await db.query('select public.kubb_admin_add_match_time($1,$2,5)', [CODE, first.id]);
await db.query("update public.kubb_matches set started_at = now() - interval '41 minutes' where id = $1", [first.id]);
await db.query('select public.kubb_finish_expired_matches($1)', [CODE]);
let expired = await scalar('select status, extra_seconds from public.kubb_matches where id = $1', [first.id]);
assert(expired.status === 'live' && expired.extra_seconds === 300, 'added time was not honored');
await db.query("update public.kubb_matches set started_at = now() - interval '46 minutes' where id = $1", [first.id]);
await db.query('select public.kubb_finish_expired_matches($1)', [CODE]);
expired = await scalar('select status, result from public.kubb_matches where id = $1', [first.id]);
assert(expired.status === 'live' && expired.result === null, 'expired match was closed before an organizer recorded the result');
await db.query("select public.kubb_finish_match($1,$2,'draw')", [CODE, first.id]);
automaticallyReady = await scalar("select id, status, court from public.kubb_matches where status = 'ready' and court = 1 limit 1");
assert(automaticallyReady?.status === 'ready', 'recording the result did not announce a new match on the same court');
await db.query('select public.kubb_admin_undo_last($1)', [CODE]);
const restoredFinishedMatch = await scalar('select status, court from public.kubb_matches where id = $1', [first.id]);
const restoredQueuedMatch = await scalar('select status, court from public.kubb_matches where id = $1', [automaticallyReady.id]);
assert(restoredFinishedMatch.status === 'live' && restoredFinishedMatch.court === 1, 'undo did not restore the just-finished match');
assert(restoredQueuedMatch.status === 'queued' && restoredQueuedMatch.court === null, 'undo did not return the automatically announced match to the queue');
await db.query("select public.kubb_finish_match($1,$2,'draw')", [CODE, first.id]);

// The replacement above intentionally gives the displaced match a ten-minute
// pause. Expire test-only pauses before completing the rest of the tournament.
await db.query("update public.kubb_matches set deferred_until = now() - interval '1 second' where deferred_until > now()");
await finishStageAsDraws(['group']);
let phase = await scalar('select phase from public.kubb_tournament where id = 1');
assert(phase.phase === 'group', 'group completion advanced without admin approval');
let phaseWorked = false;
try { await db.query("select public.kubb_admin_phase_action($1,'close_group')", [CODE]); phaseWorked = true; } catch (_) {}
assert(!phaseWorked, 'unresolved cutoff tie did not block the phase');
await resolveAllCutoffTies('group');
const rankedByShootout = await db.query("select pos, shootout_rank from public.kubb_standings where stage = 'group' and grp = 'A' order by pos");
assert(rankedByShootout.rows.every((row, i) => row.shootout_rank === i + 1), 'shootout order did not become standings order');
advancement = await db.query('select * from public.kubb_advancement_slots order by destination_grp, destination_slot');
assert(advancement.rows.length === 16 && advancement.rows.every(row => row.placement_status === 'automatic' && row.team_id), 'all 16 automatic advancement slots were not filled after the groups were settled');
let scheduledSecondGroups = await scalar("select count(*)::int n, count(*) filter (where status = 'scheduled')::int scheduled from public.kubb_matches where stage in ('a_group','b_group')");
assert(scheduledSecondGroups.n === 24 && scheduledSecondGroups.scheduled === 24, 'filled second-stage groups did not create their six scheduled matches automatically');

const originalA1 = advancement.rows.find(row => row.destination_grp === 'A1' && row.destination_slot === 1);
const originalA2 = advancement.rows.find(row => row.destination_grp === 'A2' && row.destination_slot === 1);
await db.query('select public.kubb_admin_set_advancement_slot($1,$2,$3,$4)', [CODE, 'A1', 1, originalA2.team_id]);
await db.query('select public.kubb_admin_set_advancement_slot($1,$2,$3,$4)', [CODE, 'A2', 1, originalA1.team_id]);
advancement = await db.query("select destination_grp, destination_slot, team_id, is_manual from public.kubb_advancement_slots where destination_grp in ('A1','A2') and destination_slot = 1 order by destination_grp");
assert(advancement.rows[0].team_id === originalA2.team_id && advancement.rows[1].team_id === originalA1.team_id && advancement.rows.every(row => row.is_manual), 'the admin could not swap two second-stage slots manually');
scheduledSecondGroups = await scalar("select count(*)::int n, count(*) filter (where status = 'scheduled')::int scheduled from public.kubb_matches where stage in ('a_group','b_group')");
assert(scheduledSecondGroups.n === 24 && scheduledSecondGroups.scheduled === 24, 'manual slot changes did not rebuild a complete scheduled fixture list');
await db.exec('begin');
await db.query("update public.kubb_matches set result = 'a' where id = (select id from public.kubb_matches where stage = 'group' and grp = 'A' limit 1)");
const invalidated = await scalar("select count(*)::int n from public.kubb_tiebreaks where stage = 'group' and grp = 'A'");
assert(invalidated.n === 0, 'a corrected group result did not invalidate the old shootout order');
await db.exec('rollback');
await db.query("select public.kubb_admin_phase_action($1,'close_group')", [CODE]);
await db.query("select public.kubb_admin_phase_action($1,'start_final_groups')", [CODE]);

const manualPlacementMatches = await scalar(`select
  count(*) filter (where grp = 'A1' and (team_a = $1 or team_b = $1))::int in_a1,
  count(*) filter (where grp = 'A2' and (team_a = $2 or team_b = $2))::int in_a2
  from public.kubb_matches where stage = 'a_group'`, [originalA2.team_id, originalA1.team_id]);
assert(manualPlacementMatches.in_a1 === 3 && manualPlacementMatches.in_a2 === 3, 'manual advancement overrides were not used to build group-stage matches');
const firstSecondStage = await scalar("select id from public.kubb_matches where stage = 'a_group' order by order_no limit 1");
await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 1, firstSecondStage.id]);
await db.query('select public.kubb_start_match($1,$2)', [CODE, firstSecondStage.id]);
let lateOverrideWorked = false;
try { await db.query('select public.kubb_admin_set_advancement_slot($1,$2,$3,$4)', [CODE, 'A1', 2, originalA1.team_id]); lateOverrideWorked = true; } catch (_) {}
assert(!lateOverrideWorked, 'an advancement override was accepted after second-stage play began');

const secondGroups = await db.query("select stage, grp, count(*)::int n from public.kubb_matches where stage in ('a_group','b_group') group by stage,grp order by stage,grp");
assert(secondGroups.rows.length === 4 && secondGroups.rows.every(row => row.n === 6), 'A1/A2/B1/B2 were not four groups of four');
count = await scalar("select count(*)::int n from public.kubb_matches where stage in ('a_group','b_group')");
assert(count.n === 24, `expected 24 second-stage matches, got ${count.n}`);
let misplaced = await scalar(`
  with final_teams as (
    select distinct stage, team_a team_id from public.kubb_matches where stage in ('a_group','b_group')
    union select distinct stage, team_b from public.kubb_matches where stage in ('a_group','b_group')
  )
  select count(*)::int n from final_teams f join public.kubb_standings s on s.stage = 'group' and s.team_id = f.team_id
   where (f.stage = 'a_group' and s.pos > 2) or (f.stage = 'b_group' and s.pos <= 2)
`);
assert(misplaced.n === 0, 'a team was allocated to the wrong A/B track');

await finishStageAsDraws(['a_group','b_group']);
phaseWorked = false;
try { await db.query("select public.kubb_admin_phase_action($1,'review_semifinalists')", [CODE]); phaseWorked = true; } catch (_) {}
assert(!phaseWorked, 'unresolved semifinal cutoff tie did not block the phase');
await resolveAllCutoffTies('a_group');
await resolveAllCutoffTies('b_group');
await db.query("select public.kubb_admin_phase_action($1,'review_semifinalists')", [CODE]);
await db.query("select public.kubb_admin_phase_action($1,'start_knockout')", [CODE]);
let seeded = await scalar("select count(*)::int n from public.kubb_matches where stage in ('a_sf','b_sf') and team_a is not null and team_b is not null");
assert(seeded.n === 4, 'all four direct semifinals were not seeded');

// En sluttspillkamp kan ikke registreres uavgjort; vinneren velges etter straffekast.
const firstSemi = await scalar("select id from public.kubb_matches where stage = 'a_sf' order by order_no limit 1");
await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 1, firstSemi.id]);
await db.query('select public.kubb_start_match($1,$2)', [CODE, firstSemi.id]);
let drawWorked = false;
try { await db.query("select public.kubb_finish_match($1,$2,'draw')", [CODE, firstSemi.id]); drawWorked = true; } catch (_) {}
assert(!drawWorked, 'a knockout draw was accepted');
await db.query("select public.kubb_finish_match($1,$2,'a')", [CODE, firstSemi.id]);

for (;;) {
  const next = await db.query("select id from public.kubb_matches where stage ~ '^[ab]_(sf|final|bronze)$' and status <> 'finished' and team_a is not null and team_b is not null order by order_no limit 1");
  if (!next.rows.length) break;
  await playMatch(next.rows[0].id, 'a');
}
const allMatches = await scalar('select count(*)::int total, count(*) filter (where status = $1)::int finished from public.kubb_matches', ['finished']);
assert(allMatches.total === 56 && allMatches.finished === 56, `expected a complete 56-match tournament, got ${allMatches.finished}/${allMatches.total}`);
await db.query("select public.kubb_admin_phase_action($1,'finish_tournament')", [CODE]);
phase = await scalar('select phase from public.kubb_tournament where id = 1');
assert(phase.phase === 'finished', 'tournament did not reach finished phase');

const audit = await scalar('select count(*)::int n from public.kubb_audit_log');
assert(audit.n > 20, 'admin actions were not audited');

// En testturnering kan ryddes uten at dagens lag, puljer, koder eller roller forsvinner.
const preservedBeforeReset = await db.query(`
  select t.id, t.name, t.grp, t.seed, c.code, c.role
    from public.kubb_teams t
    join public.kubb_codes c on c.team_id = t.id
   where t.withdrawn_at is null
   order by t.id
`);
const resetResult = (await db.query('select public.kubb_admin_reset_results($1) value', [CODE])).rows[0].value;
const preservedAfterReset = await db.query(`
  select t.id, t.name, t.grp, t.seed, c.code, c.role
    from public.kubb_teams t
    join public.kubb_codes c on c.team_id = t.id
   where t.withdrawn_at is null
   order by t.id
`);
assert(JSON.stringify(preservedAfterReset.rows) === JSON.stringify(preservedBeforeReset.rows), 'result reset changed teams, groups, codes, or roles');
assert(resetResult.reset && resetResult.teams_preserved === 16 && resetResult.groups_preserved === 4, 'result reset did not report the preserved setup');
const cleanRestart = await scalar(`select
  (select phase from public.kubb_tournament where id = 1) phase,
  (select planned_matches from public.kubb_tournament where id = 1) planned_matches,
  count(*)::int total,
  count(*) filter (where stage = 'group' and status = 'queued')::int queued_group,
  count(*) filter (where status = 'finished' or result is not null or started_at is not null)::int played,
  count(*) filter (where stage in ('a_group','b_group'))::int second_group
  from public.kubb_matches`);
assert(cleanRestart.phase === 'group' && cleanRestart.planned_matches === 56, 'result reset did not return the tournament to first group play');
assert(cleanRestart.total === 32 && cleanRestart.queued_group === 24 && cleanRestart.played === 0 && cleanRestart.second_group === 0, 'result reset did not recreate a clean 24+8 match plan');

// Bakoverkompatibel knapp-funksjon skal ha noyaktig samme trygge semantikk.
await db.query("update public.kubb_matches set status = 'finished', result = 'draw', ended_at = now() where id = (select id from public.kubb_matches where stage = 'group' order by order_no limit 1)");
await db.query('select public.kubb_admin_reset($1)', [CODE]);
const legacyReset = await scalar(`select
  (select count(*)::int from public.kubb_teams where withdrawn_at is null) teams,
  (select count(*)::int from public.kubb_codes where team_id is not null) codes,
  count(*) filter (where stage = 'group' and status = 'queued')::int queued_group,
  count(*) filter (where status = 'finished' or result is not null)::int played
  from public.kubb_matches`);
assert(legacyReset.teams === 16 && legacyReset.codes === 16 && legacyReset.queued_group === 24 && legacyReset.played === 0, 'Nullstill alt deleted setup or left played matches behind');

console.log('Migration, complete 56-match flow, and safe result reset checks passed.');
await db.close();
