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
  '20260731120000_admin_control_and_tournament_phases.sql'
];

const assert = (condition, message) => { if (!condition) throw new Error(message); };
const scalar = async sql => (await db.query(sql)).rows[0];
const teams = count => Array.from({ length: count }, (_, i) => ({ name: `Lag ${i + 1}`, grp: 'A' }));
const playMatch = async (id, result = 'draw', code = 'ENDRE_MEG') => {
  let match = await scalar(`select status, court from public.kubb_matches where id = '${id}'`);
  if (match.status === 'queued') {
    await db.query('select public.kubb_select_court_match($1, $2, $3)', [code, 1, id]);
    match = await scalar(`select status, court from public.kubb_matches where id = '${id}'`);
  }
  if (match.status === 'ready') await db.query('select public.kubb_start_match($1, $2)', [code, id]);
  if (match.status === 'paused') await db.query('select public.kubb_resume_match($1, $2)', [code, id]);
  await db.query('select public.kubb_finish_match($1, $2, $3)', [code, id, result]);
};

await db.exec('create role anon; create role authenticated; create schema storage; create table storage.objects (bucket_id text, name text);');
for (const name of migrations) {
  let sql = await readFile(join(root, 'supabase', 'migrations', name), 'utf8');
  sql = sql.replace(/^alter publication.*$/gm, '');
  await db.exec(sql);
}

// Tre tomme felt skal gi én pulje med fire og tre puljer med tre lag.
await db.query('select public.kubb_admin_set_teams($1, $2::jsonb)', ['ENDRE_MEG', JSON.stringify(teams(13))]);
await db.query("select public.kubb_admin_generate_groups('ENDRE_MEG')");
let drawnGroups = await db.query('select grp, count(*)::int as n from public.kubb_teams group by grp order by grp');
assert(drawnGroups.rows.length === 4, 'expected four drawn groups');
assert(drawnGroups.rows.map(row => row.n).join(',') === '4,3,3,3', 'expected 13 teams to become one group of four and three groups of three');
let adminTeamCodes = await scalar("select count(*)::int as n from public.kubb_codes where role = 'admin' and team_id is not null");
assert(adminTeamCodes.n === 2, 'expected the first two teams to receive admin access');
let prepared = await scalar("select count(*)::int as a, (select count(*)::int from public.kubb_matches where stage ~ '^b_(r[0-9]+|qf|sf|final|bronze)$') as b from public.kubb_matches where stage ~ '^a_(r[0-9]+|qf|sf|final|bronze)$'");
assert(prepared.a > 0 && prepared.b > 0, 'expected A and B playoff trees to exist when groups are drawn');

// Tolv lag gir fire trelags-puljer. A-puljen får åtte lag og B-puljen fire.
await db.query('select public.kubb_admin_set_teams($1, $2::jsonb)', ['ENDRE_MEG', JSON.stringify(teams(12))]);
await db.query("select public.kubb_admin_settings('ENDRE_MEG', 'Kilkast test', 40, 1, 2)");
await db.query("select public.kubb_admin_generate_groups('ENDRE_MEG')");

let count = await scalar("select count(*)::int as n from public.kubb_matches where stage = 'group'");
assert(count.n === 12, `expected 12 first-group matches, got ${count.n}`);

let readyCount = await scalar("select count(*)::int as n from public.kubb_matches where status = 'ready'");
assert(readyCount.n === 0, 'matches should not be assigned to courts automatically');
const firstQueued = await scalar("select id from public.kubb_matches where stage = 'group' and status = 'queued' order by order_no limit 1");
await db.query('select public.kubb_select_court_match($1, $2, $3)', ['ENDRE_MEG', 1, firstQueued.id]);
const teamAccess = await scalar("select code from public.kubb_codes where role = 'team' limit 1");
let teamCouldStart = false;
try { await db.query('select public.kubb_start_match($1, $2)', [teamAccess.code, firstQueued.id]); teamCouldStart = true; } catch (_) {}
assert(!teamCouldStart, 'a team code should not be able to start a match');

const alternate = await db.query(`
  select q.id as next_match, r.id as current_match, r.court
  from public.kubb_matches q join public.kubb_matches r on r.status = 'ready'
  where q.status = 'queued' and q.team_a is not null and q.team_b is not null
    and not exists (
      select 1 from public.kubb_matches busy
      where busy.status in ('ready', 'live', 'paused') and busy.id <> r.id
        and (q.team_a in (busy.team_a, busy.team_b) or q.team_b in (busy.team_a, busy.team_b))
    )
  limit 1
`);
assert(alternate.rows.length === 1, 'expected an eligible alternate court match');
await db.query('select public.kubb_select_court_match($1, $2, $3)', ['ENDRE_MEG', alternate.rows[0].court, alternate.rows[0].next_match]);
let swapped = await scalar(`select status, court from public.kubb_matches where id = '${alternate.rows[0].next_match}'`);
assert(swapped.status === 'ready' && swapped.court === alternate.rows[0].court, 'alternate match was not placed on the court');
let latestAction = await scalar("select can_undo from public.kubb_admin_recent_actions('ENDRE_MEG', 1)");
assert(latestAction.can_undo, 'the latest court selection should be reversible');
await db.query("select public.kubb_admin_undo_last('ENDRE_MEG')");
swapped = await scalar(`select status, court from public.kubb_matches where id = '${alternate.rows[0].next_match}'`);
assert(swapped.status === 'queued' && swapped.court === null, 'undo did not restore the alternate match to the queue');

let teamCouldFinish = false;
try { await db.query('select public.kubb_finish_match($1, $2, $3)', [teamAccess.code, alternate.rows[0].next_match, 'a']); teamCouldFinish = true; } catch (_) {}
assert(!teamCouldFinish, 'a team code should not be able to finish a match');

const expiring = await scalar("select id from public.kubb_matches where stage = 'group' and status = 'ready' limit 1");
await db.query('select public.kubb_start_match($1, $2)', ['ENDRE_MEG', expiring.id]);
let teamCouldPause = false;
try { await db.query('select public.kubb_pause_match($1, $2)', [teamAccess.code, expiring.id]); teamCouldPause = true; } catch (_) {}
assert(!teamCouldPause, 'a team code should not be able to pause a match');
await db.query("update public.kubb_matches set started_at = now() - interval '41 minutes' where id = $1", [expiring.id]);
await db.query("select public.kubb_finish_expired_matches('ENDRE_MEG')");
let expired = await scalar(`select status, result from public.kubb_matches where id = '${expiring.id}'`);
assert(expired.status === 'finished' && expired.result === 'draw', 'expired group match did not become a draw');
let replacement = await db.query('select status from public.kubb_matches where court = 1');
assert(replacement.rows.length === 0, 'a new match was automatically assigned to the freed court');

const decided = await scalar("select id, team_a, team_b from public.kubb_matches where stage = 'group' and status <> 'finished' limit 1");
let beforePoints = await db.query('select team_id, points from public.kubb_standings where stage = $1 and team_id in ($2, $3)', ['group', decided.team_a, decided.team_b]);
const beforeA = beforePoints.rows.find(row => row.team_id === decided.team_a).points;
const beforeB = beforePoints.rows.find(row => row.team_id === decided.team_b).points;
await playMatch(decided.id, 'a');
let points = await db.query('select team_id, points from public.kubb_standings where stage = $1 and team_id in ($2, $3)', ['group', decided.team_a, decided.team_b]);
assert(points.rows.find(row => row.team_id === decided.team_a).points === beforeA + 3, 'a group winner did not receive three points');
assert(points.rows.find(row => row.team_id === decided.team_b).points === beforeB, 'a group loser incorrectly received points');
await db.query('select public.kubb_admin_correct_result($1, $2, $3)', ['ENDRE_MEG', decided.id, 'b']);
points = await db.query('select team_id, points from public.kubb_standings where stage = $1 and team_id in ($2, $3)', ['group', decided.team_a, decided.team_b]);
assert(points.rows.find(row => row.team_id === decided.team_a).points === beforeA, 'corrected group result did not remove the old winner points');
assert(points.rows.find(row => row.team_id === decided.team_b).points === beforeB + 3, 'corrected group result did not award the new winner points');

const firstStage = await db.query("select id from public.kubb_matches where stage = 'group' and status <> 'finished'");
for (const row of firstStage.rows) {
  await playMatch(row.id, 'draw');
}
let phase = await scalar('select phase from public.kubb_tournament where id = 1');
assert(phase.phase === 'group', 'first group completion should wait for explicit admin approval');
count = await scalar("select count(*)::int as n from public.kubb_matches where stage in ('a_group', 'b_group')");
assert(count.n === 0, 'A/B matches should not be created automatically');
await db.query("select public.kubb_admin_phase_action('ENDRE_MEG', 'close_group')");
phase = await scalar('select phase from public.kubb_tournament where id = 1');
assert(phase.phase === 'group_review', 'first group review phase was not entered');
await db.query("select public.kubb_admin_phase_action('ENDRE_MEG', 'start_final_groups')");
count = await scalar("select count(*)::int as a, (select count(*)::int from public.kubb_matches where stage = 'b_group') as b from public.kubb_matches where stage = 'a_group'");
assert(count.a === 28 && count.b === 6, `expected 28 A-pool and 6 B-pool matches, got ${count.a} and ${count.b}`);
let misplaced = await scalar(`
  with final_teams as (
    select distinct stage, team_a as team_id from public.kubb_matches where stage in ('a_group', 'b_group')
    union
    select distinct stage, team_b from public.kubb_matches where stage in ('a_group', 'b_group')
  )
  select count(*)::int as n
  from final_teams f
  join public.kubb_standings s on s.stage = 'group' and s.team_id = f.team_id
  where (f.stage = 'a_group' and s.pos > 2)
     or (f.stage = 'b_group' and s.pos <= 2)
`);
assert(misplaced.n === 0, 'teams were placed in the wrong A or B group');

const secondStage = await db.query("select id from public.kubb_matches where stage in ('a_group', 'b_group')");
for (const row of secondStage.rows) {
  await playMatch(row.id, 'draw');
}
phase = await scalar('select phase from public.kubb_tournament where id = 1');
assert(phase.phase === 'final_groups', 'A/B completion should wait for explicit semifinal review');
await db.query("select public.kubb_admin_phase_action('ENDRE_MEG', 'review_semifinalists')");
phase = await scalar('select phase from public.kubb_tournament where id = 1');
assert(phase.phase === 'semifinal_review', 'semifinal review phase was not entered');
await db.query("select public.kubb_admin_phase_action('ENDRE_MEG', 'start_knockout')");
let seeded = await scalar("select count(*)::int as a, (select count(*)::int from public.kubb_matches where stage = 'b_sf' and team_a is not null and team_b is not null) as b from public.kubb_matches where stage = 'a_sf' and team_a is not null and team_b is not null");
assert(seeded.a === 2 && seeded.b === 2, `expected seeded A and B semifinals, got ${seeded.a} A and ${seeded.b} B`);

for (;;) {
  const next = await db.query("select id from public.kubb_matches where stage ~ '^[ab]_(sf|final|bronze)$' and status <> 'finished' and team_a is not null and team_b is not null order by order_no limit 1");
  if (!next.rows.length) break;
  await playMatch(next.rows[0].id, 'a');
}
await db.query("select public.kubb_admin_phase_action('ENDRE_MEG', 'finish_tournament')");
phase = await scalar('select phase from public.kubb_tournament where id = 1');
assert(phase.phase === 'finished', 'tournament did not reach the finished phase');
const auditCount = await scalar('select count(*)::int as n from public.kubb_audit_log');
assert(auditCount.n > 10, 'admin changes were not written to the audit log');

await db.query("select public.kubb_admin_set_admin_code('ENDRE_MEG', '0000')");
const globalLogin = await scalar("select public.kubb_login('0000') as login");
assert(globalLogin.login.ok && globalLogin.login.role === 'admin', 'main admin code was not updated');
adminTeamCodes = await scalar("select count(*)::int as n from public.kubb_codes where role = 'admin' and team_id is not null");
assert(adminTeamCodes.n === 2, 'changing the main code should preserve both admin team codes');

console.log('Migration and Kilkast tournament-flow checks passed.');
await db.close();
