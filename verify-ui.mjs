import { chromium } from 'playwright';
import { existsSync } from 'node:fs';

const chrome = [
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
].find(existsSync);
if (!chrome) throw new Error('Fant ikke Chrome eller Edge for UI-testen');

const now = Date.now();
const names = ['Kubbkongene','Furu Fighters','Plankepiratene','Rullesteinene','Kast & Kubb','Treffsikre','Kongelaget','Vikings','Kubbkameratene','Pinnekasterne','Gressgjengen','Parklaget','Kubbklubben','Sommerkast','Kongen står','Siste pinne'];
const teams = names.map((name, i) => ({
  id:`00000000-0000-4000-8000-${String(i + 1).padStart(12, '0')}`,
  name, grp:String.fromCharCode(65 + Math.floor(i / 4)), seed:i + 1, withdrawn_at:null
}));
const matchId = n => `10000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const makeMatch = (n, court, status, a, b, minutes, label, readyMinutes = 0) => ({
  id:matchId(n), stage:'group', grp:'A', round:1, label,
  team_a:teams[a].id, team_b:teams[b].id, court, status, order_no:n,
  started_at:minutes == null ? null : new Date(now - minutes * 60000).toISOString(),
  paused_at:status === 'paused' ? new Date(now - 120000).toISOString() : null,
  pause_accum:0, extra_seconds:n === 1 ? 300 : 0, ended_at:null, result:null, score_a:null, score_b:null,
  feeds_match:null, feeds_side:null, loser_feeds_match:null, loser_feeds_side:null,
  created_at:new Date(now - 3600000).toISOString(),
  ready_at:readyMinutes ? new Date(now - readyMinutes * 60000).toISOString() : null
});
const matches = [
  makeMatch(1, 1, 'live',   0,  1, 12,   'Pulje A · runde 1'),
  makeMatch(2, 2, 'live',   2,  3, 41,   'Pulje A · runde 1'),
  makeMatch(3, 3, 'paused', 4,  5, 18,   'Pulje B · runde 1'),
  makeMatch(4, 4, 'live',   6,  7, 26,   'Pulje B · runde 1'),
  makeMatch(5, 5, 'ready',  8,  9, null, 'Pulje C · runde 1', 6),
  makeMatch(6, 1, 'ready', 10, 11, null, 'Pulje C · runde 2', 1),
  makeMatch(7, null, 'queued', 12, 13, null, 'Pulje D · runde 1'),
  makeMatch(8, null, 'queued', 14, 15, null, 'Pulje D · runde 1')
];
matches[1].stage = 'a_sf';
matches[1].grp = null;
matches[1].label = 'A-sluttspill · Semifinale 1';
const standings = teams.map((team, i) => ({
  stage:'group', grp:team.grp, team_id:team.id, name:team.name,
  played:i < 8 ? 2 : 1, wins:i % 3, draws:i % 2, losses:0,
  kubb_for:0, kubb_against:0, kubb_diff:0, points:(i % 3) * 3 + (i % 2),
  head_to_head_points:0, shootout_rank:null, pos:(i % 4) + 1
}));
const audit = [
  { id:9, action:'pause', label:'Pauset kamp', actor_name:'Kubbkongene', created_at:new Date(now - 120000).toISOString(), can_undo:true },
  { id:8, action:'start', label:'Startet kamp', actor_name:'Kubbkongene', created_at:new Date(now - 480000).toISOString(), can_undo:false }
];

const browser = await chromium.launch({ headless:true, executablePath:chrome });
const page = await browser.newPage({ viewport:{ width:390, height:844 } });
const errors = [];
page.on('pageerror', error => errors.push(error.message));
page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });

await page.route('https://rknxxzxywmfkwsvojfiv.supabase.co/**', route => {
  const request = route.request();
  const path = new URL(request.url()).pathname;
  const headers = {
    'access-control-allow-origin':'*',
    'access-control-allow-headers':'*',
    'access-control-allow-methods':'GET,POST,OPTIONS',
    'content-type':'application/json'
  };
  if (request.method() === 'OPTIONS') return route.fulfill({ status:204, headers });
  const send = body => route.fulfill({ status:200, headers, body:JSON.stringify(body) });
  if (path.endsWith('/rpc/kubb_login')) return send({ ok:true, role:'admin', team_id:teams[0].id, team_name:teams[0].name, grp:'A' });
  if (path.endsWith('/rpc/kubb_now')) return send(new Date(now).toISOString());
  if (path.endsWith('/rpc/kubb_admin_recent_actions')) return send(audit);
  if (path.endsWith('/rpc/kubb_finish_expired_matches')) return send(0);
  if (path.endsWith('/kubb_tournament')) return send({ id:1, name:'Kilkast test', match_seconds:2400, num_courts:5, phase:'group', planned_matches:56, qualifiers_per_group:2, drawn_at:new Date(now - 3600000).toISOString(), completed_at:null, updated_at:new Date(now).toISOString() });
  if (path.endsWith('/kubb_teams')) return send(teams);
  if (path.endsWith('/kubb_matches')) return send(matches);
  if (path.endsWith('/kubb_standings')) return send(standings);
  return send(null);
});

try {
  await page.goto('http://127.0.0.1:4173/index.html', { waitUntil:'domcontentloaded' });
  for (const digit of ['1','2','3','4']) await page.getByRole('button', { name:digit, exact:true }).click();
  await page.locator('#whoName').getByText('Kubbkongene · arrangør').waitFor({ timeout:5000 });

  const courtNumbers = await page.locator('.court-no').allTextContents();
  if (courtNumbers.join(',') !== '1,2,3,4,5') throw new Error(`Banerekkefølgen er feil: ${courtNumbers.join(',')}`);
  if (await page.locator('.court-next.assigned').count() !== 4) throw new Error('Neste kamp er ikke tydelig markert på alle aktive baner');
  if (!await page.locator('.court-next.assigned').getByText(/Gressgjengen – Parklaget/).count()) throw new Error('Valgt neste kamp vises ikke på riktig bane');
  if (await page.locator('.admin-alert').count() !== 2) throw new Error('Forventet varsler for utløpt tid og forsinket start');
  if (!await page.locator('.turn-call').getByText(/Dere spiller på bane 1/).count()) throw new Error('Vedvarende banevarsel mangler');
  if (await page.getByRole('button', { name:'+5 min', exact:true }).count() !== 4) throw new Error('Ekstra tid mangler på pågående kamper');
  if (!await page.getByRole('button', { name:'Flytt / endre', exact:true }).count()) throw new Error('Flytting av en klar kamp mangler');
  await page.locator(`#c-${matchId(2)}`).getByRole('button', { name:'Avslutt', exact:true }).click();
  if (!await page.locator('.sheet').getByText(/Straffekast · velg vinner/).count()) throw new Error('Utløpt knockoutkamp viser ikke straffekast');
  if (await page.locator('.sheet').getByRole('button', { name:/Uavgjort/ }).count()) throw new Error('Knockoutkamp kan registreres uavgjort');
  await page.locator('.sheet').getByRole('button', { name:'Avbryt' }).click();

  await page.getByRole('button', { name:'Arrangør' }).click();
  const adminText = (await page.locator('#view').innerText()).replace(/\s+/g, ' ');
  if (!adminText.includes('0/56') || !adminText.includes('0%')) throw new Error('Fast fremdrift for 56 kamper mangler');
  if (!adminText.includes('Pauset kamp') || !adminText.includes('Kubbkongene')) throw new Error('Revisjonsloggen vises ikke');
  if (!await page.getByRole('button', { name:'Avslutt første gruppespill' }).isDisabled()) throw new Error('Faseovergang kan brukes før kampene er ferdige');
  if (adminText.includes('Trekk grupper på nytt')) throw new Error('En offentlig trekning kan fortsatt kjøres på nytt');
  await page.getByRole('button', { name:/Lagstatus og ventetid/ }).click();
  if (await page.locator('.status-row').count() !== 16) throw new Error('Lagstatus viser ikke alle 16 lag');
  if (await page.getByRole('button', { name:'Stryk lag', exact:true }).count() !== 16) throw new Error('Arrangøren kan ikke stryke hvert lag');
  if (!await page.locator('.sheet').getByText(/Spiller på bane 1/).count()) throw new Error('Lagstatus viser ikke hvem som spiller');
  await page.locator('.sheet').getByRole('button', { name:'Lukk' }).click();

  await page.getByRole('button', { name:'Kun oversikt' }).click();
  const tvNumbers = await page.locator('.court-no').allTextContents();
  if (tvNumbers.join(',') !== '1,2,3,4,5') throw new Error('Oversiktsmodus endrer banerekkefølgen');
  const tvText = await page.locator('#view').innerText();
  if (/Start kampen|Pause|Avslutt|Velg kamp/.test(tvText)) throw new Error('Oversiktsmodus viser kampkontroller');
  if (errors.length) throw new Error(`Nettleserfeil: ${errors.join(' | ')}`);
  console.log('Mobile admin overview and notification checks passed.');
} finally {
  await browser.close();
}
