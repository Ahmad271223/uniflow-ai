# Store- und Rechtstexte (P10) – Entwürfe, Stand 26.10.2026

Dieser Ordner enthält die Texte, die vor der Veröffentlichung im App Store (iPad, Mac „Designed for iPad“), im Play
Store (Android) und für den gehosteten Dienst gebraucht werden. **Alles sind Entwürfe aus dem tatsächlichen Verhalten
der Software, keine Rechtsberatung.** Vor der Veröffentlichung prüft eine Anwältin oder ein Anwalt die Datenschutz-
erklärung, die Nutzungsbedingungen und das Impressum; die Store-Texte prüft der Inhaber.

| Datei | Inhalt | Wo sie hinkommt |
|---|---|---|
| `DATENSCHUTZ.md` | Datenschutzerklärung für Apps, Web-Oberfläche und Dienst (Art. 13 DSGVO) | öffentliche Seite `[[Domain]]/datenschutz`; URL in App Store Connect und Play Console |
| `NUTZUNGSBEDINGUNGEN.md` | Nutzungsbedingungen inkl. Tarife, Abo, Hochschulsysteme, Community-Regeln | öffentliche Seite `[[Domain]]/nutzungsbedingungen`; Link auf der Tarifseite in der App (Pflicht bei Abos) |
| `IMPRESSUM.md` | Impressum-Vorlage nach § 5 DDG (zwei Varianten) | `[[Domain]]/impressum`; Händlerangaben im App Store (DSA) |
| `KONTO-LOESCHEN.md` | Öffentliche Seite „Konto löschen“ (Pflicht im Play Store, nützlich für Apple) | `[[Domain]]/konto-loeschen` |
| `APP-STORE.md` | App Store Connect: Name, Untertitel, Werbetext, Beschreibung, Schlüsselwörter, Altersfreigabe, App-Datenschutz, Abo-Produkt, Hinweise für die Prüfung | App Store Connect (de-DE) |
| `PLAY-STORE.md` | Play Console: Titel, Kurz- und Vollbeschreibung, Datensicherheit, Inhaltseinstufung, Zielgruppe, Abo-Produkt | Play Console (de-DE) |
| `BETRIEB.md` | Betriebsanleitung für den gehosteten Dienst (Hosting-Paket `deploy/`: Docker, Caddy/TLS, `.env`, Backups, Updates, Löschfristen, Monitoring) | Inhaber, Server |

Regeln für alle Texte (Entscheidung des Inhabers vom 25.10.2026):

- **Keine KI-Versprechen.** V1 enthält keine generativen Funktionen; die Texte nennen weder „KI“ noch „automatisch
  erstellte Tests“ noch Zusammenfassungen. Wenn KI-Funktionen später kommen, werden Store-Texte und
  Datenschutzerklärung zuerst ergänzt (`tests/test_release_texts.py` prüft die Store-Texte darauf).
- **Nur, was wirklich funktioniert.** Uni & Noten auf dem iPad und die Online-Community gelten erst als Funktion,
  wenn sie am Gerät laufen („bald“ ist kein Store-Text). Fristen, Termine und Noten sind Abbilder der
  Hochschulsysteme; verbindlich bleibt immer die Hochschule – das steht in jedem Text.
- **Keine Hochschule als Partner darstellen.** Studora ist nicht mit der Leibniz Universität Hannover oder der
  Universität Hildesheim verbunden; keine Uni-Logos in Screenshots ohne Erlaubnis.

## Platzhalter

Alle Platzhalter stehen in doppelten eckigen Klammern und müssen vor der Veröffentlichung ersetzt sein
(`tests/test_release_texts.py` listet sie auf):

`[[Name]]`, `[[Anschrift]]`, `[[E-Mail]]`, `[[Telefon]]`, `[[Domain]]`, `[[Hosting-Anbieter]]`, `[[Serverstandort]]`,
`[[Mail-Anbieter]]`, `[[Datum]]`, `[[USt-IdNr.]]` (nur falls vorhanden), `[[Aufsichtsbehörde]]`.

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
   Konto-Menü der App; `tests/test_legal_pages.py`. Es bleibt, die Platzhalter zu ersetzen.
6. **App Review – erledigt (27.10.2026):** Demo-Inhalte ohne Hochschulkonto (`app/demo.py`): Einstellungen →
   Erweitert → „Demo-Inhalte anlegen“ bzw. `POST /api/demo {enabled: true}` legt ein Demo-Modul mit drei selbst
   erzeugten PDFs, Stundenplan, Lernkalender, einer Frist und einer Ankündigung an; „entfernen“ nimmt alles
   rückstandslos weg. Gilt für Web, Windows und Android (über den Dienst). Das iPad hat denselben Schalter lokal
   ohne Dienst (27.10.2026, `DemoContent` im Swift-Kern, gleiche Inhalte, Vergleich `fixtures/demo/demo.json`):
   Einstellungen → Erweitert und im ersten Start auf der Anmeldeseite „Ohne Hochschulkonto ansehen (Demo)“.
7. **Händlerstatus (DSA)** in App Store Connect angeben; Name, Anschrift, E-Mail und Telefon werden dann im Store
   angezeigt. Dieselben Angaben wie im Impressum.
8. **Datenexport** als Gesamtpaket (ZIP mit Notizen, Kalender, Karteikarten) ist in `docs/KONTEN-ABOS-PLAN.md`
   geplant, aber nicht gebaut; die Erklärung nennt heute den Export als PDF und den Geräteabgleich.
9. **Abstimmung mit den Hochschulen** zum automatisierten Abruf mit Studierenden-Zugangsdaten
   (`docs/ANFRAGE-STUDIP-ZUGANG.md`, `docs/ANFRAGE-HILDESHEIM.md`): Ergebnis ggf. in Nutzungsbedingungen Abschnitt 4.
