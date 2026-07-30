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
  '20260730210000_kubb_final_groups_and_courts.sql'
];

const assert = (condition, message) => { if (!condition) throw new Error(message); };
const scalar = async sql => (await db.query(sql)).rows[0];

await db.exec('create role anon; create role authenticated; create schema storage; create table storage.objects (bucket_id text, name text);');
for (const name of migrations) {
  let sql = await readFile(join(root, 'supabase', 'migrations', name), 'utf8');
  sql = sql.replace(/^alter publication.*$/gm, '');
  await db.exec(sql);
}

const teams = [
  ['Alfa', 'A'], ['Bravo', 'A'], ['Charlie', 'A'], ['Delta', 'A'],
  ['Echo', 'B'], ['Foxtrot', 'B'], ['Golf', 'B'], ['Hotel', 'B']
].map(([name, grp]) => ({ name, grp }));
await db.query('select public.kubb_admin_set_teams($1, $2::jsonb)', ['ENDRE_MEG', JSON.stringify(teams)]);
await db.query("select public.kubb_admin_settings('ENDRE_MEG', 'Testturnering', 40, 1, 2)");
await db.query("select public.kubb_admin_start_tournament('ENDRE_MEG')");

let count = await scalar("select count(*)::int as n from public.kubb_matches where stage = 'group'");
assert(count.n === 12, `expected 12 initial group matches, got ${count.n}`);

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

const expiring = await scalar("select id from public.kubb_matches where status = 'ready' limit 1");
await db.query('select public.kubb_start_match($1, $2)', ['ENDRE_MEG', expiring.id]);
await db.query('update public.kubb_matches set started_at = now() - interval \'41 minutes\' where id = $1', [expiring.id]);
await db.query("select public.kubb_finish_expired_matches('ENDRE_MEG')");
let expired = await scalar(`select status, result from public.kubb_matches where id = '${expiring.id}'`);
assert(expired.status === 'finished' && expired.result === 'draw', 'expired group match did not become a draw');

const firstStage = await db.query("select id from public.kubb_matches where stage = 'group' and status <> 'finished'");
for (const row of firstStage.rows) {
  await db.query('select public.kubb_finish_match($1, $2, $3)', ['ENDRE_MEG', row.id, 'draw']);
}
count = await scalar("select count(*)::int as a, (select count(*)::int from public.kubb_matches where stage = 'b_group') as b from public.kubb_matches where stage = 'a_group'");
assert(count.a === 6 && count.b === 6, `expected six A and six B matches, got ${count.a} and ${count.b}`);

const secondStage = await db.query("select id from public.kubb_matches where stage in ('a_group', 'b_group')");
for (const row of secondStage.rows) {
  await db.query('select public.kubb_finish_match($1, $2, $3)', ['ENDRE_MEG', row.id, 'draw']);
}
count = await scalar("select count(*)::int as n from public.kubb_matches where stage ~ '^[ab]_(r[0-9]+|qf|sf|final)$'");
assert(count.n === 6, `expected six A/B knockout matches, got ${count.n}`);

console.log('Migration and tournament-flow checks passed.');
await db.close();
