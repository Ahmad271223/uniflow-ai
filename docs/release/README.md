# Store- und Rechtstexte (P10) – Entwürfe, Stand 26.10.2026

Dieser Ordner enthält die Texte, die vor der Veröffentlichung im App Store (iPad, Mac „Designed for iPad“), im Play
Store (Android) und für den gehosteten Dienst gebraucht werden. **Alles sind Entwürfe aus dem tatsächlichen Verhalten
der Software, keine Rechtsberatung.** Vor der Veröffentlichung prüft eine Anwältin oder ein Anwalt die Datenschutz-
erklärung, die Nutzungsbedingungen und das Impressum; die Store-Texte prüft der Inhaber.

| Datei | Inhalt | Wo sie hinkommt |
|---|---|---|
| `DATENSCHUTZ.md` | Datenschutzerklärung für Apps, Web-Oberfläche und Dienst (Art. 13 DSGVO) | öffentliche Seite `https://studinow.app/datenschutz`; URL in App Store Connect und Play Console |
| `NUTZUNGSBEDINGUNGEN.md` | Nutzungsbedingungen inkl. Tarife, Abo, Hochschulsysteme, Community-Regeln | öffentliche Seite `https://studinow.app/nutzungsbedingungen`; Link auf der Tarifseite in der App (Pflicht bei Abos) |
| `IMPRESSUM.md` | Impressum nach § 5 DDG (Einzelunternehmen IT solutions by Ahmad Fakih) | `https://studinow.app/impressum`; Händlerangaben im App Store (DSA) |
| `KONTO-LOESCHEN.md` | Öffentliche Seite „Konto löschen“ (Pflicht im Play Store, nützlich für Apple) | `https://studinow.app/konto-loeschen` |
| `SUPPORT.md` | Support-Seite mit Kontaktadresse und häufigen Fragen (Anmeldung bei der Uni, Daten auf dem iPad, Konto löschen) | `https://studinow.app/support` (Support-URL in App Store Connect) |
| `STARTSEITE.md` | Startseite der Website im Stil einer Lernplattform (seit 05.11.2026): Einstieg, Vertrauensleiste, Funktionen mit Bildschirmfotos aus `website-img/` (Demo-Inhalte, hell/dunkel), Schritte, Tarife, Fragen; App-Store-Knopf mit „Bald verfügbar“, bis es den Store-Link gibt | `https://studinow.app` |
| `APP-STORE.md` | App Store Connect: Name, Untertitel, Werbetext, Beschreibung, Schlüsselwörter, Altersfreigabe, App-Datenschutz, Abo-Produkt, Hinweise für die Prüfung | App Store Connect (de-DE) |
| `PLAY-STORE.md` | Play Console: Titel, Kurz- und Vollbeschreibung, Datensicherheit, Inhaltseinstufung, Zielgruppe, Abo-Produkt | Play Console (de-DE) |
| `BETRIEB.md` | Betriebsanleitung für den gehosteten Dienst (Hosting-Paket `deploy/`: Docker, Caddy/TLS, `.env`, Backups, Updates, Löschfristen, Monitoring) | Inhaber, Server |
| `angaben.json` | Angaben des Inhabers (Firma, Anschrift, USt-IdNr., E-Mail, Domain) – zur Veröffentlichung bestimmt, darum im Repository | `tools/rechtstexte-fuellen.py --check` |
| `TESTFLIGHT-500-2026-11-08.md` | TestFlight-Beta „LUH-Tester“ (bis 500): Einladungstext, Testinfos, Tester-FAQ, Grenzen von 1.0, Ablaufplan; Befund zu Sandbox-Käufen und Probe, Tester freischalten (`python -m app.tester_freischalten`) | Inhaber (Versand), Support |

**Website:** `tools/gen-site.py` baut aus `STARTSEITE.md`, `SUPPORT.md`, `DATENSCHUTZ.md`, `IMPRESSUM.md`,
`NUTZUNGSBEDINGUNGEN.md` und `KONTO-LOESCHEN.md` die statischen Seiten in `site/` (reines HTML, eine CSS-Datei, hell
und dunkel nach Systemeinstellung, keine fremden Ressourcen). Nach jeder Änderung an diesen Texten neu erzeugen
(`.venv/bin/python tools/gen-site.py`); `tests/test_site.py` prüft, dass `site/` dem Stand der Texte entspricht, die
Firmenangaben enthält und außer den Hoster-Platzhaltern nichts Offenes. Veröffentlichen: den Ordner `site/` auf einen
beliebigen statischen Host legen (z. B. Cloudflare Pages, Netlify, GitHub Pages; `/datenschutz` → `datenschutz.html`
über „clean URLs“ des Hosts), DNS `studinow.app` und `www` auf den Host, `studinow.ai` als Weiterleitung auf
`https://studinow.app`.

Regeln für alle Texte (Entscheidung des Inhabers vom 25.10.2026):

- **KI nur dort, wo man sie kaufen kann.** Entschieden (05./06.11.2026): Die StudiNow-KI gibt es nur in StudiNow Pro AI
  über den Dienst `app.studinow.app`; „eigenes ChatGPT verbinden“ ist im Build aus („bald verfügbar“). Darum hat
  `APP-STORE.md` zwei Fassungen: ohne Pro AI nennen die öffentlichen Felder weder „KI“ noch „automatisch erstellte
  Tests“ noch Zusammenfassungen; die Fassung mit Pro AI (`description-proai`) beschreibt die KI, nennt aber nie fremde
  Marken (ChatGPT, OpenAI). Die Hinweise für die App-Prüfung beschreiben die KI in beiden Fassungen (nicht öffentlich,
  Richtlinie 2.3.1). Geprüft von `tests/test_release_texts.py`.
  **Website (Wunsch des Inhabers vom 05.11.2026):** Die Startseite `studinow.app` nennt die KI-Hilfe (auch für das ganze
  Dokument) und den Tarif StudiNow Pro AI; `tests/test_site.py` prüft das.
- **Nur, was wirklich funktioniert.** Uni & Noten auf dem iPad und die Online-Community gelten erst als Funktion,
  wenn sie am Gerät laufen („bald“ ist kein Store-Text). Fristen, Termine und Noten sind Abbilder der
  Hochschulsysteme; verbindlich bleibt immer die Hochschule – das steht in jedem Text.
- **Keine Hochschule als Partner darstellen.** StudiNow ist nicht mit der Leibniz Universität Hannover, der
  Hochschule Hannover oder der Universität Hildesheim verbunden; keine Uni-Logos in Screenshots ohne Erlaubnis.

## Platzhalter

Alle Platzhalter stehen in doppelten eckigen Klammern und müssen vor der Veröffentlichung ersetzt sein
(`tests/test_release_texts.py` listet sie auf). **Stand 03.11.2026:** Die Angaben des Inhabers (IT solutions by Ahmad
Fakih, Einzelunternehmen, Inhaber Ahmad Fakih, Baldurstraße 5, 30657 Hannover, USt-IdNr. DE462836430,
support@studinow.app, Domain studinow.app) sind in `angaben.json` eingetragen und in den Texten an Ort und Stelle
eingesetzt (`[[Name]]`, `[[Anschrift]]`, `[[E-Mail]]`, `[[Domain]]`, `[[Datum]]`, `[[Jahr]]`, `[[USt-IdNr.]]`,
`[[Aufsichtsbehörde]]`, `[[7 Tagen]]` gibt es in den Texten nicht mehr; das Impressum hat nur noch die Variante für
das Einzelunternehmen). Offen bleiben:

- `[[Hoster]]`, `[[Serverstandort]]`, `[[Mail-Anbieter]]` in `DATENSCHUTZ.md` Abschnitt 11 – das Hosting des Dienstes
  ist nicht entschieden (`BETRIEB.md`); die Website zeigt sie bis dahin gelb markiert.
- `[[Telefon]]` in `PLAY-STORE.md` – keine Telefonnummer genannt; Apple verlangt sie für die Händlerangaben (DSA),
  Google für die Kontaktdaten. Das Impressum nennt nur die E-Mail-Adresse (anwaltlich prüfen, ob ein zweiter
  Kontaktweg nach § 5 Abs. 1 Nr. 2 DDG nötig ist).
- In `PLAY-STORE.md` die optionalen Satzteile wie `[[• Eigene Karteikarten mit Wiederholung (Plus)]]` (nur übernehmen,
  wenn die Funktion läuft; Schalter `funktionen.android_*` in `angaben.json`) und der Prüfhinweis
  `[[Mit der Google-Dokumentation …]]`. `APP-STORE.md` ist seit 06.11.2026 ohne Platzhalter und fertig zum Einfügen;
  die Schalter `funktionen.ipad_*` wirken dort nicht mehr (Hochschulen, die nicht laufen, streicht man von Hand, siehe
  Tabelle oben in `APP-STORE.md`).

## Platzhalter ausfüllen: `tools/rechtstexte-fuellen.py`

Der Inhaber trägt **einmal wenige Werte** in eine JSON ein, das Werkzeug ersetzt damit alle Platzhalter in
`IMPRESSUM.md`, `DATENSCHUTZ.md`, `NUTZUNGSBEDINGUNGEN.md`, `KONTO-LOESCHEN.md`, `APP-STORE.md` und `PLAY-STORE.md`
(diese README und `BETRIEB.md` bleiben unberührt, sie beschreiben die Platzhalter nur). Die echten Werte stehen in
`angaben.json`; Vorlage mit erfundenen Beispielwerten: `angaben.example.json` (Felder `_hinweis` erklären jeden Wert).

```bash
.venv/bin/python tools/rechtstexte-fuellen.py docs/release/angaben.json --check   # was ist offen (Hoster, Telefon, Schalter)
# sobald hoster, hoster_ort, mail_anbieter und telefon in angaben.json stehen und die Schalter entschieden sind:
.venv/bin/python tools/rechtstexte-fuellen.py docs/release/angaben.json           # docs/release/*.md an Ort und Stelle füllen
.venv/bin/python tools/gen-site.py                                                # danach die Website neu erzeugen
.venv/bin/python tools/rechtstexte-fuellen.py angaben.json --out /pfad/legal      # oder in einen anderen Ordner (LERNAPP_LEGAL_DIR)
```

`--check` schreibt nichts und endet mit Exit 1, solange Platzhalter offen sind oder ein Pflichtwert in der JSON leer
ist. Beim Füllen prüft das Werkzeug vor dem Schreiben, dass kein `[[` mehr vorkommt und keiner der Arbeitsvermerke,
die `tests/test_release_texts.py` verbietet; ist `datum` leer, nimmt es das heutige Datum (TT.MM.JJJJ). Ein Platzhalter,
den das Werkzeug nicht kennt, ist ein Fehler – neue Platzhalter in `tools/rechtstexte-fuellen.py` (`VALUES`,
`FEATURES`, `NOTES`) eintragen. Tests: `tests/test_rechtstexte.py`.

**Werte, die der Inhaber liefern muss** (Pflicht, sofern nicht „optional“):

| Wert in der JSON | Platzhalter / Wirkung | Wo |
|---|---|---|
| `name` | `[[Name]]` – Anbieter, Verantwortlicher, Copyright | Impressum (Variante A), Datenschutz 2, Nutzungsbedingungen 1, App Store |
| `strasse`, `plz_ort` | `[[Straße Hausnummer]]`, `[[PLZ Ort]]`; zusammen `[[Anschrift]]` („Straße, PLZ Ort“) | Impressum, Datenschutz 2, Nutzungsbedingungen 1 |
| `email` | `[[E-Mail]]` – Kontakt, Support-URL-Kontakt, Konto löschen | alle sechs Dateien |
| `email_datenschutz` (optional) | `[[E-Mail]]` nur in `DATENSCHUTZ.md`; leer = `email` | Datenschutz 2, 14, 15 |
| `telefon` | `[[Telefon]]` – zweiter Kontaktweg (§ 5 DDG), Händlerangaben (DSA), Play Console | Impressum, Play Store |
| `domain` | `[[Domain]]` – nur Hostname, eingesetzt wird `https://<domain>` (…/datenschutz, /impressum, /konto-loeschen, /support) | alle sechs Dateien |
| `hoster`, `hoster_ort` | `[[Hoster]]` (früher `[[Hosting-Anbieter]]`), `[[Serverstandort]]` | Datenschutz 11 |
| `mail_anbieter` | `[[Mail-Anbieter]]` | Datenschutz 11 |
| `aufsichtsbehoerde` | `[[Aufsichtsbehörde]]` mit Anschrift (z. B. Die Landesbeauftragte für den Datenschutz Niedersachsen, Prinzenstraße 5, 30159 Hannover) | Datenschutz 14 |
| `ustid` (optional) + `kleinunternehmer` (true/false) | Block **Umsatzsteuer**: USt-IdNr. gesetzt → „USt-IdNr. nach § 27a UStG: …“; leer → `kleinunternehmer` muss true sein → „Kleinunternehmer nach § 19 UStG, keine USt-IdNr.“ | Impressum |
| `datenschutzbeauftragter` (optional) | leer → „Einen Datenschutzbeauftragten gibt es nicht …“; sonst „Datenschutzbeauftragte/r: …“ (`[[Falls doch benannt: Name und Kontakt.]]`) | Datenschutz 2 |
| `antwortfrist` | `[[7 Tagen]]` – Zusage für die Bestätigung einer Löschung per E-Mail | Konto löschen |
| `datum` (optional) | `[[Datum]]` (Stand der Texte) und `[[Jahr]]` (Copyright); leer = heute | Datenschutz, Nutzungsbedingungen, App Store |
| `unternehmen.*` (nur juristische Person) | `firma` gesetzt → Impressum **Variante B** mit `[[Firma]] [[Rechtsform]]`, `[[Geschäftsführer/in Vorname Nachname]]`, `[[Amtsgericht Ort]]`, `[[HRB …]]`; leer → **Variante A** (natürliche Person). Die andere Variante wird entfernt, Überschrift „Angaben nach § 5 DDG“, Titel „Impressum“ | Impressum |
| `funktionen.*` (true/false) | optionale Satzteile: `ipad_hildesheim` (`[[ UND DER UNIVERSITÄT HILDESHEIM]]`, `[[ bzw. Learnweb]]`), `ipad_hsh` (`[[, DER HOCHSCHULE HANNOVER]]`, `[[, Moodle]]`, Zeile Hochschule Hannover; seit 05.11.2026 mit `ipad_hildesheim` an, Wunsch des Inhabers), `ipad_fristen` (Abgabefristen/Ankündigungen/Feiertage, auch Bildschirmfoto 5), `ipad_skriptsuche`, `ipad_community_online`, `android_karteikarten`, `android_community` (beide zusammen für `[[, dazu Karteikarten und das Teilen von Lösungen]]`) | App Store, Play Store |
| – | Prüfhinweise `[[Anwaltlich prüfen…]]`, `[[mit Apple-Dokumentation…]]`, `[[Mit der Google-Dokumentation…]]` und die Erklärung `[[…]]` in `PLAY-STORE.md` werden entfernt und im Protokoll genannt | Nutzungsbedingungen 5, 9; App Store; Play Store |

Nicht als Platzhalter vorgesehen (steht fest im Text): Land „Deutschland“ im Impressum, OpenAI/ChatGPT (Datenschutz
8a, nur bei eigener Verbindung), Apple/Google als Zahlungsabwickler. Die Vorbehalte „Entwurf, Stand 26.10.2026“ und
„vor der Veröffentlichung anwaltlich prüfen“ bleiben stehen – sie entfernt die Anwältin oder der Anwalt nach der
Prüfung von Hand.

**Danach:** Der Dienst liest die Dateien zur Laufzeit aus `LERNAPP_LEGAL_DIR` (`app/legal.py`, Standard
`docs/release`; im Docker-Image `/srv/uniflow/docs/release`, hineinkopiert beim Bauen, `deploy/Dockerfile`). Nach dem
Füllen also entweder Image neu bauen (`docker compose up -d --build`) oder den `--out`-Ordner als Volume einhängen und
`LERNAPP_LEGAL_DIR` darauf zeigen (`deploy/.env.example`); kein Cache-Zähler nötig, die Seiten werden mit `no-cache`
ausgeliefert. Seit dem Füllen an Ort und Stelle (03.11.2026) erwartet `tests/test_release_texts.py`
`https://studinow.app/datenschutz` in den Store-Texten und die Firmenangaben in den Rechtstexten;
`tests/test_rechtstexte.py` prüft das Werkzeug gegen den gefüllten Stand (offen nur Hoster, Telefon, Schalter).
Das Windows-Paket nimmt `docs/release` mit (`apps/windows/backend/uniflow-backend.spec`).

## Was vor der Veröffentlichung noch zu tun ist

1. **Hosting entscheiden** (`docs/KONTEN-ABOS-PLAN.md`): Anbieter, Standort (Empfehlung EU), Vertrag zur
   Auftragsverarbeitung (Art. 28 DSGVO). Ohne gehosteten Dienst gilt für V1 (iPad) nur der Abschnitt „Auf deinem
   Gerät“ der Datenschutzerklärung – das ist dort so markiert.
2. **Schriftart selbst ausliefern – erledigt (26.10.2026).** Die Web-Oberfläche liefert „Inter“ aus
   `app/static/fonts/` aus (Inter 4.1, SIL Open Font License, `LICENSE-Inter.txt`); die CSP (`UI_CSP`) erlaubt keine
   fremden Hosts mehr, `tests/test_fonts.py` prüft das. Hintergrund: Laden von Google Fonts überträgt die IP-Adresse
   an Google und ist in Deutschland ohne Einwilligung angreifbar (LG München I, 3 O 17493/20).
3. **Löschfristen – erledigt (26.10.2026):** `app/retention.py` läuft im Dienst täglich ab 04:00 (Zeitplan der
   Jobs): eigenes Zugriffsprotokoll je Tag, 14 Tage; Abgleich-Protokolle und `sync_log` je Konto 90 Tage; abgelaufene
   Sitzungen, Reset-Token, Fehlversuchszähler; Konten 30 Tage nach Löschung (`accounts.purge_deleted`). Der Dienst muss
   ohne das uvicorn-Zugriffsprotokoll laufen (`--no-access-log`), siehe `docs/VERTRAEGE-KONTO-SYNC.md`, Betrieb.
4. **Mailversand – Code erledigt (27.10.2026), Zugangsdaten fehlen:** `app/mail.py` verschickt den Reset-Link und
   eine Willkommensmail (nur Information) per SMTP (`LERNAPP_MAIL`, `LERNAPP_SMTP_HOST/PORT/USER/PASSWORD`,
   `LERNAPP_MAIL_FROM`, `LERNAPP_PUBLIC_URL`, siehe `docs/VERTRAEGE-KONTO-SYNC.md`, Betrieb); ohne SMTP-Host landen
   die Mails in `logs/mail.log`. Es bleibt: Mail-Anbieter wählen, Zugangsdaten eintragen, Anbieter in die
   Datenschutzerklärung (Abschnitt 11).
4a. **„Mit Google/Apple anmelden“ – Code erledigt (27.10.2026), Client-IDs fehlen:** `app/social_login.py` prüft die
   ID-Tokens; Buttons und Endpunkte sind erst mit `LERNAPP_GOOGLE_CLIENT_IDS` / `LERNAPP_APPLE_CLIENT_IDS` (und den
   Web-Client-IDs) aktiv. Es bleibt: Google-Cloud-Projekt (OAuth-Client-IDs für Android, iOS, Web) und bei Apple
   „Sign in with Apple“ für die App-ID plus eine Services-ID mit bestätigter Domain anlegen; beide Anbieter in die
   Datenschutzerklärung.
5. **Öffentliche Seiten – erledigt (26.10.2026):** der Dienst liefert `/datenschutz`, `/nutzungsbedingungen`,
   `/impressum` und `/konto-loeschen` direkt aus diesen Markdown-Dateien aus (`app/legal.py`, ohne Sitzung, auch im
   gehosteten Modus; Platzhalter erscheinen gelb markiert, bis sie ersetzt sind). Verlinkt auf der Anmeldeseite und im
   Konto-Menü der App; `tests/test_legal_pages.py`. **Website – erledigt (03.11.2026):** `site/` aus denselben
   Dateien (`tools/gen-site.py`, oben), Domain `studinow.app` und Postfach `support@studinow.app` ab 04.11.2026; die
   iPad-App verlinkt die Seiten auf der Tarifseite und in den Einstellungen (`UFLegalLinks`). Es bleibt, die
   Hoster-Platzhalter zu ersetzen (Abschnitt „Platzhalter ausfüllen“).
6. **App Review – erledigt (27.10.2026):** Demo-Inhalte ohne Hochschulkonto (`app/demo.py`): Einstellungen →
   Erweitert → „Demo-Inhalte anlegen“ bzw. `POST /api/demo {enabled: true}` legt ein Demo-Modul mit drei selbst
   erzeugten PDFs, Stundenplan, Lernkalender, einer Frist und einer Ankündigung an; „entfernen“ nimmt alles
   rückstandslos weg. Gilt für Web, Windows und Android (über den Dienst). Das iPad hat denselben Schalter lokal
   ohne Dienst (27.10.2026, `DemoContent` im Swift-Kern, gleiche Inhalte, Vergleich `fixtures/demo/demo.json`), seit
   04.11.2026 nur für Prüfer: einziger Weg ist der kleine Textlink „Ohne Hochschulkonto ansehen (Demo)“ ganz unten auf
   der Anmeldeseite der Hochschule (nicht mehr in den Einstellungen); im Demo-Betrieb die Leiste mit „Beenden“.
7. **Händlerstatus (DSA)** in App Store Connect angeben; Name, Anschrift, E-Mail und Telefon werden dann im Store
   angezeigt. Dieselben Angaben wie im Impressum; die Telefonnummer fehlt noch (`[[Telefon]]`).
8. **Datenexport** als Gesamtpaket (ZIP mit Notizen, Kalender, Karteikarten) ist in `docs/KONTEN-ABOS-PLAN.md`
   geplant, aber nicht gebaut; die Erklärung nennt heute den Export als PDF und den Geräteabgleich.
9. **Abstimmung mit den Hochschulen** zum automatisierten Abruf mit Studierenden-Zugangsdaten
   (`docs/ANFRAGE-STUDIP-ZUGANG.md`, `docs/ANFRAGE-HILDESHEIM.md`): Ergebnis ggf. in Nutzungsbedingungen Abschnitt 4.
