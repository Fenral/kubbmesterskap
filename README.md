# Kilkasting2026

Turneringsverktøy for kubb. Én HTML-fil som kjører hele arrangementet: 16 lag, to gruppespill, banetildeling, 40-minutters nedtelling, tabeller og separate A- og B-sluttspill med finale og bronsefinale.

## Turneringsflyt

1. Ett av arrangørlagene legger inn nøyaktig 16 lag. De to første lagene får arrangørtilgang med sin vanlige lagkode, og kan trekke fire tilfeldige puljer med fire lag, se og dele alle lagkoder, samt rette resultater før neste turneringstrinn låses. Trekket tidsstemples og kan ikke kjøres på nytt uten full nullstilling. Seier gir 3 poeng, uavgjort 1 poeng og tap 0 poeng.
2. De to beste fra hver første pulje går til A1 eller A2. De to nederste går til B1 eller B2. Det blir fire nye puljer med fire lag og seks kamper i hver.
3. Rangeringen er poeng, deretter innbyrdes poeng. Er lagene fortsatt helt like ved kvalifiseringsstreken, gjennomføres straffekast og arrangøren registrerer rekkefølgen. Etter andre gruppespill går de to beste fra hver pulje direkte til semifinaler i A eller B. Begge spor har finale og bronsefinale. En knockoutkamp kan aldri registreres uavgjort og avgjøres med straffekast ved behov.
4. Baneoversikten viser live-kamper, ny kamp og nedtelling på fem baner i fast rekkefølge. Alle ledige baner fylles automatisk ved start, faseoverganger og lagret resultat med den høyest prioriterte spillbare kampen. Arrangørlaget kan bare overstyre en kamp som allerede er klar, med «Endre kamp». Begge lagene i kampen kan starte den felles klokken; arrangørlagene har samme knapp som reserve. Når tiden går ut, fortsetter kampen å være åpen til et arrangørlag registrerer seier eller uavgjort. Berørte lag får popup, vedvarende banemelding og valgfrie nettleservarsler.
5. Er et lag ikke klart, kan arrangørlaget velge en annen kamp. Kampen som erstattes får ti minutters pause og kommer deretter øverst i køen. Arrangørlaget kan også stryke et lag; da fjernes alle lagets spilte og kommende kamper, tabellene beregnes på nytt og laget kan ikke lenger logge inn.
6. Arrangøren avslutter turneringen eksplisitt etter finaler og bronsefinaler. Resultatene låses og hele turneringen får status `finished`. En komplett turnering består av 56 kamper: 24 + 24 i gruppespillene og 8 i knockout.

Appen er laget for å brukes på mobil ute på banen. Arrangørlagene styrer turneringen fra ett kontrollark, lagene logger inn med sin egen kode og ser sin gruppe først, og en ren oversiktsvisning kan vises på en større skjerm.

![Kampoversikt](docs/screenshots/03-kamper.png)

## Slik henger det sammen

Hele frontend-en ligger i `index.html` — ingen byggesteg, ingen npm-avhengigheter i produksjon og ingen rammeverk. Vercel serverer de statiske filene på `kubbmesterskap.vercel.app`, mens Supabase lagrer turneringen og sender sanntidsoppdateringer. Edge-funksjonen `kubb-push-expiry` sender tidsvarsler til installerte mobilapper også når skjermen er låst.

All logikk som betyr noe ligger i Postgres som `SECURITY DEFINER`-funksjoner. Klienten kan lese kamper, lag og turneringsoppsett gjennom RLS, men kan ikke skrive noe direkte — hver eneste endring går gjennom en funksjon som først sjekker koden din. Tabellen med koder (`kubb_codes`) har RLS uten policies, så den er utilgjengelig for alle andre enn de funksjonene.

Klokka er serverstyrt. `kubb_now()` gir felles tid, og hver kamp regner ut gjenstående tid fra `started_at` minus akkumulert pause, pluss eventuell tilleggstid. Da spiller det ingen rolle om mobilene har ulik klokke.

Oppdateringer kommer via Supabase Realtime på `kubb_matches`, `kubb_teams` og `kubb_tournament`, så alle skjermer følger hverandre uten polling.

## Roller

**Arrangørlag** er de to første lagene i laglisten. De logger inn med sin vanlige lagkode og får kontrollarket i tillegg til sin egen lagvisning. Herfra settes oppsettet før start, trekningen gjennomføres, enkeltkoder fornyes, lagstatus og ventetid følges, resultater registreres og faseovergangene godkjennes. Ved retting av et knockoutresultat vises alle senere kamper som påvirkes, og disse kan nullstilles kontrollert før resultatet endres.

**Lag** logger inn med sin firesifrede kode og går direkte til sin egen gruppe. De ser egne kamper, hvilken bane de skal på, nedtellingen og tabellen. Når deres kamp er annonsert på en bane, kan begge lag starte klokken. Øvrig kampstyring og resultatregistrering krever arrangørlag.

**Storskjerm** krever ingen innlogging og viser løpende kamper med nedtelling.

## Database

| Tabell | Innhold |
|---|---|
| `kubb_tournament` | Én rad med oppsettet for turneringen |
| `kubb_teams` | Lag, gruppe og seeding |
| `kubb_matches` | Kamper i gruppespill og sluttspill, med bane, status og klokke |
| `kubb_codes` | Innloggingskoder. Ingen RLS-policies — kun tilgjengelig for SECURITY DEFINER-funksjoner |
| `kubb_audit_log` | Tidspunkt, arrangør og beskrivelse for alle administrative endringer |
| `kubb_tiebreaks` | Straffekastrekkefølge for lag som fortsatt er helt like |
| `kubb_login_attempts` | Rate limiting på innlogging |

Funksjonene deler seg i to: `kubb_login` / `kubb_role` / `kubb_now` er åpne for leseflyten, `kubb_start_match` godtar ett av lagene i den aktuelle kampen eller et arrangørlag, og øvrig kampstyring samt alle `kubb_admin_*`-funksjoner krever arrangørrolle. `kubb_assign_next_court_match` velger neste kamp i køen automatisk etter lagret resultat, men starter aldri klokken. `kubb_admin_reset_results` rydder en testturnering tilbake til første gruppespill uten å endre lag, puljer, lagkoder eller arrangørroller.

`kubb_admin_phase_action` styrer de eksplisitte faseovergangene. Først etter arrangørens godkjenning oppretter `kubb_create_final_groups` A- og B-gruppene, og senere seedes semifinalene. Når en utslagskamp avsluttes flytter `kubb_propagate` vinneren videre av seg selv.

## Sette opp fra bunn

```bash
supabase link --project-ref <ditt-prosjekt>
supabase db push
```

Migrasjonene ligger i `supabase/migrations/` og kjøres i rekkefølge.

**Før du kjører dem:** åpne `20260727201150_kubb_secrets_split.sql` og bytt ut `ENDRE_MEG` med arrangørkoden du vil ha. Har du allerede kjørt migrasjonene, endrer du koden med:

```sql
select public.kubb_admin_set_admin_code('<gjeldende kode>', '<ny kode>');
```

Deretter kobler du mappen til Vercel. Et push til `main` publiserer de statiske filene automatisk. Edge-funksjonen for tidsvarsler legges ut separat:

```bash
supabase functions deploy kubb-push-expiry --no-verify-jwt
vercel --prod
```

`index.html` peker på Supabase-URL og anon-nøkkel øverst i filen. Bytt disse til ditt eget prosjekt. Anon-nøkkelen er ment å ligge i klienten — det er RLS og funksjonene som holder på sikkerheten, ikke nøkkelen.

## Skjermbilder

De tjue bildene i `docs/screenshots/` er fanget med Playwright og dekker innlogging, banetildeling, kampvisning, tabell, arrangørarket, nedtelling, tomme tilstander, sluttspill, feilkoder og både mobil, desktop og storskjerm. `package.json` inneholder bare Playwright, brukt til å ta dem.

| | |
|---|---|
| ![Innlogging](docs/screenshots/01-login.png) | ![Arrangørarket](docs/screenshots/05-arrangor.png) |
| ![Tabell](docs/screenshots/04-tabell.png) | ![Sluttspill](docs/screenshots/13-sluttspill.png) |

## Lisens

MIT. Se `LICENSE`.
