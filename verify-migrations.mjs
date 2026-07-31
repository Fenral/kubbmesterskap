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
  '20260731213000_tiebreak_invalidation.sql'
];

const CODE = 'ENDRE_MEG';
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const scalar = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const teamList = () => Array.from({ length:16 }, (_, i) => ({ name:`Lag ${i + 1}`, grp:'A' }));
const playMatch = async (id, result = 'draw', code = CODE) => {
  let match = await scalar('select status from public.kubb_matches where id = $1', [id]);
  if (match.status === 'queued') await db.query('select public.kubb_select_court_match($1,$2,$3)', [code, 1, id]);
  match = await scalar('select status from public.kubb_matches where id = $1', [id]);
  if (match.status === 'ready') await db.query('select public.kubb_start_match($1,$2)', [code, id]);
  if (match.status === 'paused') await db.query('select public.kubb_resume_match($1,$2)', [code, id]);
  await db.query('select public.kubb_finish_match($1,$2,$3)', [code, id, result]);
};
const finishStageAsDraws = async stages => {
  const rows = await db.query('select id from public.kubb_matches where stage = any($1::text[]) and status <> $2 order by order_no', [stages, 'finished']);
  for (const row of rows.rows) await playMatch(row.id, 'draw');
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
const removed = (await db.query('select public.kubb_admin_remove_team($1,$2) value', [CODE, teamCode.team_id])).rows[0].value;
assert(removed.matches_removed === 3, 'not all team matches were struck');
const afterRemoval = await scalar('select count(*)::int n from public.kubb_matches where team_a = $1 or team_b = $1', [teamCode.team_id]);
const removedLogin = await scalar('select public.kubb_login($1) login', [teamCode.code]);
tournament = await scalar('select planned_matches from public.kubb_tournament where id = 1');
assert(afterRemoval.n === 0 && !removedLogin.login.ok, 'withdrawn team or code is still active');
assert(tournament.planned_matches === 50, `expected 50 matches after a team withdrawal, got ${tournament.planned_matches}`);

// Start en ren 16-lagsturnering og test arrangorkontrollene.
await db.query('select public.kubb_admin_reset($1)', [CODE]);
await db.query('select public.kubb_admin_set_teams($1,$2::jsonb)', [CODE, JSON.stringify(teamList())]);
teamCode = await scalar("select code, team_id from public.kubb_codes where role = 'team' order by code limit 1");
const regenerated = (await db.query('select public.kubb_admin_regenerate_team_code($1,$2) value', [CODE, teamCode.team_id])).rows[0].value;
assert(regenerated.code && regenerated.code !== teamCode.code, 'team code was not regenerated');
await db.query("select public.kubb_admin_settings($1,'Kilkast test',40,2,2)", [CODE]);
await db.query('select public.kubb_admin_generate_groups($1)', [CODE]);

const first = await scalar("select id from public.kubb_matches where stage = 'group' order by order_no limit 1");
await db.query('select public.kubb_select_court_match($1,$2,$3)', [CODE, 1, first.id]);
let teamCouldStart = false;
try { await db.query('select public.kubb_start_match($1,$2)', [regenerated.code, first.id]); teamCouldStart = true; } catch (_) {}
assert(!teamCouldStart, 'a normal team code could start a match');
await db.query('select public.kubb_admin_move_court_match($1,$2,$3)', [CODE, first.id, 2]);
let selected = await scalar('select status, court from public.kubb_matches where id = $1', [first.id]);
assert(selected.status === 'ready' && selected.court === 2, 'ready match was not moved');
await db.query('select public.kubb_admin_release_court_match($1,$2)', [CODE, first.id]);
selected = await scalar('select status, court from public.kubb_matches where id = $1', [first.id]);
assert(selected.status === 'queued' && selected.court === null, 'not-ready match was not returned to queue');

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
assert(expired.status === 'finished' && expired.result === 'draw', 'expired group match did not become a draw');

await finishStageAsDraws(['group']);
let phase = await scalar('select phase from public.kubb_tournament where id = 1');
assert(phase.phase === 'group', 'group completion advanced without admin approval');
let phaseWorked = false;
try { await db.query("select public.kubb_admin_phase_action($1,'close_group')", [CODE]); phaseWorked = true; } catch (_) {}
assert(!phaseWorked, 'unresolved cutoff tie did not block the phase');
await resolveAllCutoffTies('group');
const rankedByShootout = await db.query("select pos, shootout_rank from public.kubb_standings where stage = 'group' and grp = 'A' order by pos");
assert(rankedByShootout.rows.every((row, i) => row.shootout_rank === i + 1), 'shootout order did not become standings order');
await db.exec('begin');
await db.query("update public.kubb_matches set result = 'a' where id = (select id from public.kubb_matches where stage = 'group' and grp = 'A' limit 1)");
const invalidated = await scalar("select count(*)::int n from public.kubb_tiebreaks where stage = 'group' and grp = 'A'");
assert(invalidated.n === 0, 'a corrected group result did not invalidate the old shootout order');
await db.exec('rollback');
await db.query("select public.kubb_admin_phase_action($1,'close_group')", [CODE]);
await db.query("select public.kubb_admin_phase_action($1,'start_final_groups')", [CODE]);

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
console.log('Migration and complete 56-match Kilkast flow checks passed.');
await db.close();
