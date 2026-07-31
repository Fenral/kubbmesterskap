# Kubbmesterskap

Turneringsverktøy for kubb. Én HTML-fil som kjører hele arrangementet: påmelding av lag, to gruppespill, banetildeling, 40-minutters nedtelling, tabeller og separate A- og B-sluttspill fram til finale.

## Turneringsflyt

1. Arrangøren legger inn 12–16 lag. De to første lagene får arrangørtilgang med sin vanlige lagkode, og kan trekke fire tilfeldige puljer, se og dele alle lagkoder, samt rette resultater før neste turneringstrinn låses. Seier gir 3 poeng, uavgjort 1 poeng og tap 0 poeng.
2. De to beste fra hver første pulje går til A-gruppespillet, og de to nederste går til B-gruppespillet.
3. Arrangøren avslutter første gruppespill, kontrollerer A- og B-lagene og starter det nye gruppespillet. Etterpå kontrolleres semifinalistene før knockout startes. Vinnere går videre automatisk inne i knockouttreet.
4. Banekartet viser live-kamper, neste valgte kamp og nedtelling på fem baner i fast rekkefølge. Når 40 minutter går ut, blir en gruppespillkamp automatisk uavgjort. Arrangøren velger alltid neste kamp manuelt. Berørte lag får popup, vedvarende banemelding og valgfrie nettleservarsler.
5. Arrangøren avslutter turneringen eksplisitt etter finaler og bronsefinaler. Resultatene låses og hele turneringen får status `finished`.

Appen er laget for å brukes på mobil ute på banen. Arrangøren styrer alt fra ett ark, lagene logger inn med sin egen kode og ser bare det de trenger, og en storskjermvisning kan kastes opp på en projektor.

![Kampoversikt](docs/screenshots/03-kamper.png)

## Slik henger det sammen

Hele frontend-en ligger i `index.html` — ingen byggesteg, ingen npm-avhengigheter i produksjon, ingen rammeverk. Filen lastes opp til Supabase Storage, og en Edge Function (`supabase/functions/kubb`) serverer den med riktig `content-type` og et 60-sekunders cache-lag.

All logikk som betyr noe ligger i Postgres som `SECURITY DEFINER`-funksjoner. Klienten kan lese kamper, lag og turneringsoppsett gjennom RLS, men kan ikke skrive noe direkte — hver eneste endring går gjennom en funksjon som først sjekker koden din. Tabellen med koder (`kubb_codes`) har RLS uten policies, så den er utilgjengelig for alle andre enn de funksjonene.

Klokka er serverstyrt. `kubb_now()` gir felles tid, og hver kamp regner ut gjenstående tid fra `started_at` minus akkumulert pause. Da spiller det ingen rolle om mobilene har ulik klokke.

Oppdateringer kommer via Supabase Realtime på `kubb_matches`, `kubb_teams` og `kubb_tournament`, så alle skjermer følger hverandre uten polling.

## Roller

**Arrangør** logger inn med arrangørkoden og får et arbeidsark med fire faner: innstillinger (kamplengde, antall baner, antall videre fra gruppe), lag, koder og resultatregistrering. Herfra startes turneringen, kamper settes i gang og pauses, baner tildeles og sluttspillet genereres.

**Lag** logger inn med sin firesifrede kode og ser sine egne kamper, hvilken bane de skal på, nedtellingen og tabellen. Vanlige lagkoder har bare lesetilgang og varsler.

**Storskjerm** krever ingen innlogging og viser løpende kamper med nedtelling.

## Database

| Tabell | Innhold |
|---|---|
| `kubb_tournament` | Én rad med oppsettet for turneringen |
| `kubb_teams` | Lag, gruppe og seeding |
| `kubb_matches` | Kamper i gruppespill og sluttspill, med bane, status og klokke |
| `kubb_codes` | Innloggingskoder. Ingen RLS-policies — kun tilgjengelig for SECURITY DEFINER-funksjoner |
| `kubb_audit_log` | Tidspunkt, arrangør og beskrivelse for alle administrative endringer |
| `kubb_login_attempts` | Rate limiting på innlogging |

Funksjonene deler seg i to: `kubb_login` / `kubb_role` / `kubb_now` er åpne for leseflyten, mens all kampstyring og alle `kubb_admin_*`-funksjoner krever en kode med arrangørrolle.

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

Deretter legger du appen ut:

```bash
supabase functions deploy kubb --no-verify-jwt
# last opp index.html til Storage-bucketen «kubb» som public
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
