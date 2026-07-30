# Kubbmesterskap

Turneringsverktøy for kubb. Én HTML-fil som kjører hele arrangementet: påmelding av lag, gruppespill, banetildeling, nedtelling per kamp, tabeller og sluttspill fram til finale.

Appen er laget for å brukes på mobil ute på banen. Arrangøren styrer alt fra ett ark, lagene logger inn med sin egen kode og ser bare det de trenger, og en storskjermvisning kan kastes opp på en projektor.

![Kampoversikt](docs/screenshots/03-kamper.png)

## Slik henger det sammen

Hele frontend-en ligger i `index.html` — ingen byggesteg, ingen npm-avhengigheter i produksjon, ingen rammeverk. Filen lastes opp til Supabase Storage, og en Edge Function (`supabase/functions/kubb`) serverer den med riktig `content-type` og et 60-sekunders cache-lag.

All logikk som betyr noe ligger i Postgres som `SECURITY DEFINER`-funksjoner. Klienten kan lese kamper, lag og turneringsoppsett gjennom RLS, men kan ikke skrive noe direkte — hver eneste endring går gjennom en funksjon som først sjekker koden din. Tabellen med koder (`kubb_codes`) har RLS uten policies, så den er utilgjengelig for alle andre enn de funksjonene.

Klokka er serverstyrt. `kubb_now()` gir felles tid, og hver kamp regner ut gjenstående tid fra `started_at` minus akkumulert pause. Da spiller det ingen rolle om mobilene har ulik klokke.

Oppdateringer kommer via Supabase Realtime på `kubb_matches`, `kubb_teams` og `kubb_tournament`, så alle skjermer følger hverandre uten polling.

## Roller

**Arrangør** logger inn med arrangørkoden og får et arbeidsark med fire faner: innstillinger (kamplengde, antall baner, antall videre fra gruppe), lag, koder og resultatregistrering. Herfra startes turneringen, kamper settes i gang og pauses, baner tildeles og sluttspillet genereres.

**Lag** logger inn med sin firesifrede kode og ser sine egne kamper, hvilken bane de skal på, nedtellingen og tabellen.

**Storskjerm** krever ingen innlogging og viser løpende kamper med nedtelling.

## Database

| Tabell | Innhold |
|---|---|
| `kubb_tournament` | Én rad med oppsettet for turneringen |
| `kubb_teams` | Lag, gruppe og seeding |
| `kubb_matches` | Kamper i gruppespill og sluttspill, med bane, status og klokke |
| `kubb_codes` | Innloggingskoder. Ingen RLS-policies — kun tilgjengelig for SECURITY DEFINER-funksjoner |
| `kubb_login_attempts` | Rate limiting på innlogging |

Funksjonene deler seg i tre: `kubb_login` / `kubb_role` / `kubb_now` er åpne, `kubb_start_match` / `kubb_pause_match` / `kubb_resume_match` / `kubb_finish_match` / `kubb_reopen_match` / `kubb_set_court` krever gyldig kode, og `kubb_admin_*` krever arrangørkoden.

Sluttspillet bygges av `kubb_admin_generate_playoff`, som setter opp bracketen med `feeds_match`/`feeds_side`-pekere. Når en kamp avsluttes flytter `kubb_propagate` vinneren videre av seg selv.

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
