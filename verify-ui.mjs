import { chromium } from 'playwright';
import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const chrome = [
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
].find(existsSync);
if (!chrome) throw new Error('Fant ikke Chrome eller Edge for UI-testen');
const captureDir = process.env.KUBB_CAPTURE_DIR || '';
if (captureDir) mkdirSync(captureDir, { recursive:true });

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
  ready_at:readyMinutes ? new Date(now - readyMinutes * 60000).toISOString() : null,
  deferred_until:null
});
const makeBracketMatch = (n, stage, slot, label, sourceA, sourceB) => ({
  id:matchId(n), stage, grp:null, round:null, slot, label,
  team_a:null, team_b:null, source_a:sourceA, source_b:sourceB,
  court:null, status:'queued', order_no:400000 + n,
  started_at:null, paused_at:null, pause_accum:0, extra_seconds:0, ended_at:null,
  result:null, score_a:null, score_b:null, feeds_match:null, feeds_side:null,
  loser_feeds_match:null, loser_feeds_side:null,
  created_at:new Date(now - 3600000).toISOString(), ready_at:null, deferred_until:null
});
const matches = [
  makeMatch(1, 1, 'live',   0,  1, 12,   'Pulje A · runde 1'),
  makeMatch(2, 2, 'live',   2,  3, 41,   'Pulje A · runde 1'),
  makeMatch(3, 3, 'paused', 4,  5, 18,   'Pulje B · runde 1'),
  makeMatch(4, 4, 'live',   6,  7, 39.95,'Pulje B · runde 1'),
  makeMatch(5, 5, 'ready',  8,  9, null, 'Pulje C · runde 1', 6),
  makeMatch(6, 1, 'ready', 10, 11, null, 'Pulje C · runde 2', 1),
  makeMatch(7, null, 'queued', 12, 13, null, 'Pulje D · runde 1'),
  makeMatch(8, null, 'queued', 14, 15, null, 'Pulje D · runde 1'),
  makeBracketMatch(9,  'a_sf',     2, 'A-sluttspill · semifinale 2', '1. A2-pulje', '2. A1-pulje'),
  makeBracketMatch(10, 'a_final',  1, 'A-sluttspill · finale', 'Vinner semifinale 1', 'Vinner semifinale 2'),
  makeBracketMatch(11, 'a_bronze', 1, 'A-sluttspill · bronsefinale', 'Taper semifinale 1', 'Taper semifinale 2'),
  makeBracketMatch(12, 'b_sf',     1, 'B-sluttspill · semifinale 1', '1. B1-pulje', '2. B2-pulje'),
  makeBracketMatch(13, 'b_sf',     2, 'B-sluttspill · semifinale 2', '1. B2-pulje', '2. B1-pulje'),
  makeBracketMatch(14, 'b_final',  1, 'B-sluttspill · finale', 'Vinner semifinale 1', 'Vinner semifinale 2'),
  makeBracketMatch(15, 'b_bronze', 1, 'B-sluttspill · bronsefinale', 'Taper semifinale 1', 'Taper semifinale 2')
];
matches[1].stage = 'a_sf';
matches[1].grp = null;
matches[1].label = 'A-sluttspill · Semifinale 1';
matches[7].deferred_until = new Date(now - 60000).toISOString();
const standings = teams.map((team, i) => ({
  stage:'group', grp:team.grp, team_id:team.id, name:team.name,
  played:i < 8 ? 2 : 1, wins:i % 3, draws:i % 2, losses:0,
  kubb_for:0, kubb_against:0, kubb_diff:0, points:(i % 3) * 3 + (i % 2),
  head_to_head_points:0, shootout_rank:null, pos:(i % 4) + 1
}));
const advancementLayout = [
  ['A1',1,'A',1], ['A1',2,'B',2], ['A1',3,'C',1], ['A1',4,'D',2],
  ['A2',1,'A',2], ['A2',2,'B',1], ['A2',3,'C',2], ['A2',4,'D',1],
  ['B1',1,'A',3], ['B1',2,'B',4], ['B1',3,'C',3], ['B1',4,'D',4],
  ['B2',1,'A',4], ['B2',2,'B',3], ['B2',3,'C',4], ['B2',4,'D',3]
];
const advancement = advancementLayout.map(([destination_grp,destination_slot,source_grp,source_pos]) => ({
  destination_stage:destination_grp.startsWith('A') ? 'a_group' : 'b_group',
  destination_grp, destination_slot, source_grp, source_pos,
  team_id:null, team_name:null, is_manual:false, source_complete:false,
  source_needs_tiebreak:false, placement_status:'waiting'
}));
const a2Members = [teams[0], teams[4], teams[8], teams[12]];
advancement.filter(row => row.destination_grp === 'A2').forEach((row, index) => Object.assign(row, {
  team_id:a2Members[index].id, team_name:a2Members[index].name,
  is_manual:false, source_complete:true, placement_status:'automatic'
}));
[
  [0,1,1], [2,3,1], [0,2,2], [1,3,2], [0,3,3], [1,2,3]
].forEach(([a,b,round], index) => {
  const match = makeMatch(16 + index, null, 'scheduled',
    teams.indexOf(a2Members[a]), teams.indexOf(a2Members[b]), null,
    `A2-pulje · runde ${round}`);
  Object.assign(match, { stage:'a_group', grp:'A2', round, order_no:200000 + index });
  matches.push(match);
});
const audit = [
  { id:9, action:'pause', label:'Pauset kamp', actor_name:'Kubbkongene', created_at:new Date(now - 120000).toISOString(), can_undo:true },
  { id:8, action:'start', label:'Startet kamp', actor_name:'Kubbkongene', created_at:new Date(now - 480000).toISOString(), can_undo:false }
];

const browser = await chromium.launch({ headless:true, executablePath:chrome });
const context = await browser.newContext({ viewport:{ width:390, height:844 }, serviceWorkers:'block' });
const page = await context.newPage();
const capture = async name => { if(captureDir) await page.screenshot({ path:join(captureDir, `${name}.png`), fullPage:true }); };
const errors = [];
let expiredFinishCalls = 0;
await page.addInitScript(() => {
  window.__expiryAlarms = [];
  document.addEventListener('kubb:time-expired', event => window.__expiryAlarms.push(event.detail.matchId));
});
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
  if (path.endsWith('/rpc/kubb_finish_expired_matches')) { expiredFinishCalls++; return send(0); }
  if (path.endsWith('/rpc/kubb_admin_set_advancement_slot')) {
    const body = request.postDataJSON();
    const slot = advancement.find(row => row.destination_grp === body.p_destination_grp && row.destination_slot === Number(body.p_destination_slot));
    const selected = teams.find(team => team.id === body.p_team);
    const previousTeam = slot?.team_id;
    if (slot) Object.assign(slot, selected ? { team_id:selected.id, team_name:selected.name, is_manual:true, placement_status:'manual' } : { team_id:null, team_name:null, is_manual:false, placement_status:'waiting' });
    if (slot && selected && previousTeam) matches
      .filter(match => match.grp === slot.destination_grp && ['a_group','b_group'].includes(match.stage))
      .forEach(match => {
        if (match.team_a === previousTeam) match.team_a = selected.id;
        if (match.team_b === previousTeam) match.team_b = selected.id;
      });
    return send({ ok:true });
  }
  if (path.endsWith('/kubb_tournament')) return send({ id:1, name:'Kilkast test', match_seconds:2400, num_courts:5, phase:'group', planned_matches:56, qualifiers_per_group:2, drawn_at:new Date(now - 3600000).toISOString(), completed_at:null, updated_at:new Date(now).toISOString() });
  if (path.endsWith('/kubb_teams')) return send(teams);
  if (path.endsWith('/kubb_matches')) return send(matches);
  if (path.endsWith('/kubb_standings')) return send(standings);
  if (path.endsWith('/kubb_advancement_slots')) return send(advancement);
  return send(null);
});

try {
  await page.goto('http://127.0.0.1:4173/index.html', { waitUntil:'domcontentloaded' });
  if (!await page.locator('.auth .mark img').count()) throw new Error('Den nye Kilkasting2026-logoen mangler på innloggingen');
  const installButton = page.getByRole('button', { name:'Legg appen på Hjem-skjermen', exact:true });
  if (!await installButton.isVisible()) throw new Error('Innloggingen mangler knappen for å legge appen på Hjem-skjermen');
  await installButton.click();
  if (!await page.locator('.sheet').getByText('Legg Kilkasting2026 på Hjem-skjermen', { exact:true }).count()) throw new Error('Hjemskjermknappen viser ikke installasjonsveiledning');
  await page.locator('.sheet').getByRole('button', { name:'Skjønner', exact:true }).click();
  for (const digit of ['1','2','3','4']) await page.getByRole('button', { name:digit, exact:true }).click();
  await page.locator('#whoName').getByText('Kubbkongene · arrangør').waitFor({ timeout:5000 });

  if (await page.locator('[data-tab="groups"]').getAttribute('aria-current') !== 'page') throw new Error('Lag lander ikke direkte på gruppespillet');
  if (await page.locator('#group-title').textContent() !== 'Gruppe A') throw new Error('Lagets egen gruppe åpnes ikke automatisk');
  await page.getByRole('button', { name:'Baner', exact:true }).click();

  const courtNumbers = await page.locator('.court-no').allTextContents();
  if (courtNumbers.join(',') !== '1,2,3,4,5') throw new Error(`Banerekkefølgen er feil: ${courtNumbers.join(',')}`);
  if (await page.locator('.court-next.assigned').count() !== 4) throw new Error('Neste kamp er ikke tydelig markert på alle aktive baner');
  if (!await page.locator('.court-next.assigned').getByText(/Gressgjengen – Parklaget/).count()) throw new Error('Valgt neste kamp vises ikke på riktig bane');
  if (await page.locator('.admin-alert').count() !== 1) throw new Error('Forventet ett separat varsel i tillegg til den prioriterte arrangørhandlingen');
  if (!await page.locator('.turn-call').getByText(/Dere spiller på bane 1/).count()) throw new Error('Vedvarende banevarsel mangler');
  if (await page.getByRole('button', { name:'+5 min', exact:true }).count() !== 4) throw new Error('Ekstra tid mangler på pågående kamper');
  if (await page.getByRole('button', { name:'Flytt / endre', exact:true }).count()) throw new Error('Flytting til en annen bane vises fortsatt');
  if (!await page.getByRole('button', { name:'Endre kamp', exact:true }).count()) throw new Error('Endre kamp mangler');
  await capture('01-baner');
  await page.waitForFunction(id => window.__expiryAlarms.includes(id), matchId(4), { timeout:5000 });
  if (expiredFinishCalls) throw new Error('Utløpt tid registrerer fortsatt automatisk uavgjort');
  await page.locator(`#c-${matchId(4)}`).getByRole('button', { name:'Avslutt', exact:true }).click();
  if (await page.locator('.sheet [data-r="a"]').count() !== 1 || await page.locator('.sheet [data-r="b"]').count() !== 1) throw new Error('Seier kan ikke velges etter utløpt tid');
  if (!await page.locator('.sheet').getByRole('button', { name:/Uavgjort/ }).count()) throw new Error('Gruppespill kan ikke registreres uavgjort etter utløpt tid');
  const resultSave = page.locator('.sheet').getByRole('button', { name:'Lagre resultat' });
  if (!await resultSave.isDisabled()) throw new Error('Resultatet kan lagres før et utfall er valgt');
  await page.locator('.sheet [data-r="a"]').click();
  if (await resultSave.isDisabled() || !await page.locator('.sheet').isVisible()) throw new Error('Resultatvalget mangler et eksplisitt lagringstrinn');
  await page.locator('.sheet').getByRole('button', { name:'Avbryt' }).click();
  await page.locator(`#c-${matchId(5)}`).getByRole('button', { name:'Endre kamp', exact:true }).click();
  if (!await page.locator('.sheet').getByRole('heading', { name:'Velg ny kamp til bane 5' }).count()) throw new Error('Endre kamp åpner ikke kampkøen direkte');
  if (await page.locator('.sheet').getByText(/Flytt til bane|Legg kampen tilbake i køen/).count()) throw new Error('Overflødige flytte- eller køkontroller vises fortsatt');
  const queuedTeams = await page.locator('.sheet [data-pick] b').allTextContents();
  if (queuedTeams[0] !== 'Kongen står – Siste pinne') throw new Error(`Utsatt kamp ligger ikke først i køen: ${queuedTeams.join(', ')}`);
  await page.locator('.sheet').getByRole('button', { name:'Avbryt' }).click();
  await page.locator(`#c-${matchId(2)}`).getByRole('button', { name:'Avslutt', exact:true }).click();
  if (!await page.locator('.sheet').getByText(/Straffekast · velg vinner/).count()) throw new Error('Utløpt knockoutkamp viser ikke straffekast');
  if (await page.locator('.sheet').getByRole('button', { name:/Uavgjort/ }).count()) throw new Error('Knockoutkamp kan registreres uavgjort');
  await page.locator('.sheet').getByRole('button', { name:'Avbryt' }).click();

  await page.getByRole('button', { name:'Arrangør' }).click();
  const adminText = (await page.locator('#view').innerText()).replace(/\s+/g, ' ');
  if (!adminText.includes('0/56') || !adminText.includes('0%')) throw new Error('Fast fremdrift for 56 kamper mangler');
  if (!adminText.includes('Pauset kamp') || !adminText.includes('Kubbkongene')) throw new Error('Revisjonsloggen vises ikke');
  if (!adminText.includes('Beholder lag, puljer, koder og rettigheter')) throw new Error('Nullstill alt forklarer ikke at lagoppsettet beholdes');
  if (!await page.getByRole('button', { name:'Avslutt første gruppespill' }).isDisabled()) throw new Error('Faseovergang kan brukes før kampene er ferdige');
  if (adminText.includes('Trekk grupper på nytt')) throw new Error('En offentlig trekning kan fortsatt kjøres på nytt');
  await capture('02-arrangor');
  await page.getByRole('button', { name:/Lagstatus og ventetid/ }).click();
  if (await page.locator('.status-row').count() !== 16) throw new Error('Lagstatus viser ikke alle 16 lag');
  if (await page.getByRole('button', { name:'Stryk lag', exact:true }).count() !== 16) throw new Error('Arrangøren kan ikke stryke hvert lag');
  if (!await page.locator('.sheet').getByText(/Spiller på bane 1/).count()) throw new Error('Lagstatus viser ikke hvem som spiller');
  await page.locator('.sheet').getByRole('button', { name:'Lukk' }).click();

  await page.getByRole('button', { name:'Gruppespill', exact:true }).click();
  if (!await page.getByRole('button', { name:'Gruppespill 1', exact:true }).count() || !await page.getByRole('button', { name:'Gruppespill 2', exact:true }).count()) throw new Error('Valget mellom de to gruppespillene mangler');
  if (!await page.locator('.mode.stage-switch').count()) throw new Error('Gruppespill bruker ikke mockens tydelige valgmeny');
  await page.getByRole('button', { name:'Gruppespill 2', exact:true }).click();
  const secondGroups = await page.locator('.group-tabs button').allTextContents();
  if (secondGroups.join(',') !== 'Gruppe B1,Gruppe B2,Gruppe A1,Gruppe A2') throw new Error(`Gruppespill 2 viser ikke alle fire puljene med samme meny som gruppespill 1: ${secondGroups.join(',')}`);
  if (await page.locator('.group-tabs button[aria-current="page"]').textContent() !== 'Gruppe A2') throw new Error('Eget lag sin pulje åpnes ikke automatisk i gruppespill 2');
  if (await page.locator('#group-title').textContent() !== 'A2') throw new Error('Gruppespill 2 bruker ikke samme gruppevisning som gruppespill 1');
  if (await page.locator('.group-board tbody tr').count() !== 4) throw new Error('Valgt pulje viser ikke alle fire plassene');
  if (await page.locator('.group-board').getByText('2. plass fra gruppe A · automatisk', { exact:true }).count() !== 1) throw new Error('Automatisk kildeplass vises ikke i tabellen');
  if (await page.getByRole('button', { name:/Endre plass .* i A2/ }).count() !== 4) throw new Error('Arrangøren kan ikke endre alle plassene i puljen');
  if (await page.locator('.group-matches .mrow').count() !== 6 || await page.locator('.group-matches .chip').filter({ hasText:'Planlagt' }).count() !== 6) throw new Error('En full pulje viser ikke seks automatisk planlagte kamper');
  await capture('03-gruppespill');
  await page.getByRole('button', { name:'Endre plass 1 i A2', exact:true }).click();
  if (await page.locator('.sheet [data-team]').count() !== 17) throw new Error('Arrangøren får ikke velge automatisk plassering eller alle 16 lag');
  await page.locator('.sheet [data-team]').filter({ hasText:'Furu Fighters' }).click();
  await page.locator('.sheet').waitFor({ state:'detached' });
  const firstSlot = page.locator('.group-board tbody tr').first();
  if (!await firstSlot.getByText('Furu Fighters', { exact:true }).count() || !await firstSlot.getByText('Satt manuelt av arrangør', { exact:true }).count()) throw new Error(`Manuell reserveplassering vises ikke i tabellen: ${await firstSlot.innerText()}`);
  const rebuiltMatches = await page.locator('.group-matches .mrow .side b').allTextContents();
  if (!rebuiltMatches.includes('Furu Fighters') || rebuiltMatches.includes('Kubbkongene')) throw new Error('Kampoppsettet ble ikke oppdatert etter lagbyttet');

  await page.getByRole('button', { name:'Knockout', exact:true }).click();
  if (!await page.getByRole('button', { name:'A-sluttspill', exact:true }).count() || !await page.getByRole('button', { name:'B-sluttspill', exact:true }).count()) throw new Error('A/B-valget i sluttspillet mangler på mobil');
  if (!await page.locator('.knockout-pool[data-pool="a"]').isVisible() || await page.locator('.knockout-pool[data-pool="b"]').isVisible()) throw new Error('Mobilvisningen viser ikke valgt A-sluttspill alene');
  await page.getByRole('button', { name:'B-sluttspill', exact:true }).click();
  if (!await page.locator('.knockout-pool[data-pool="b"]').isVisible() || await page.locator('.knockout-pool[data-pool="a"]').isVisible()) throw new Error('Det går ikke å velge B-sluttspillet på mobil');
  if (!await page.locator('.knockout-pool[data-pool="b"] .bracket-flow').count() || !await page.locator('.knockout-pool[data-pool="b"] .bracket-match').count() || !await page.locator('.knockout-pool[data-pool="b"] .final-grid').count()) throw new Error('Knockout følger ikke mockens vertikale semifinaler og medaljekamper');
  const bracketOverflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  if (bracketOverflow) throw new Error('Knockouttreet lager horisontal side-scroll på mobil');
  await capture('04-knockout');
  await page.waitForTimeout(30);
  const focusedTag = await page.evaluate(() => document.activeElement?.tagName);
  if (['INPUT','TEXTAREA','SELECT'].includes(focusedTag)) throw new Error('Tastaturfelt beholder fokus på sluttspillsiden');

  await page.setViewportSize({ width:844, height:390 });
  const aPool = await page.locator('.knockout-pool[data-pool="a"]').boundingBox();
  const bPool = await page.locator('.knockout-pool[data-pool="b"]').boundingBox();
  if (!aPool || !bPool || Math.abs(aPool.y - bPool.y) > 4 || aPool.x >= bPool.x) throw new Error('A- og B-sluttspillet står ikke side om side i landskap');
  await page.setViewportSize({ width:390, height:844 });
  await page.getByRole('button', { name:'Baner', exact:true }).click();

  await page.getByRole('button', { name:'Kun oversikt' }).click();
  const tvNumbers = await page.locator('.court-no').allTextContents();
  if (tvNumbers.join(',') !== '1,2,3,4,5') throw new Error('Oversiktsmodus endrer banerekkefølgen');
  const exitButton = await page.locator('.tv-exit').boundingBox();
  const firstCourt = await page.locator('.court.overview').first().boundingBox();
  if (exitButton && firstCourt && exitButton.y + exitButton.height > firstCourt.y) throw new Error('Knappen for å avslutte oversikten ligger over et banekort');
  const overlap = await page.locator('.court.overview:not([data-state="free"])').evaluateAll(cards => cards.some(card => {
    const timer = card.querySelector('.timer .t')?.getBoundingClientRect();
    const names = [...card.querySelectorAll('.side b')].map(name => name.getBoundingClientRect());
    return timer && names.length && timer.top < Math.max(...names.map(name => name.bottom)) + 8;
  }));
  if (overlap) throw new Error('Lagnavn og klokke overlapper i mobilens oversiktsmodus');
  const tvText = await page.locator('#view').innerText();
  if (/Start kampen|Pause|Avslutt|Velg kamp/.test(tvText)) throw new Error('Oversiktsmodus viser kampkontroller');
  if (errors.length) throw new Error(`Nettleserfeil: ${errors.join(' | ')}`);
  console.log('Mobile admin overview and notification checks passed.');
} finally {
  await browser.close();
}
