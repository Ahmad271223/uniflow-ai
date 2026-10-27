# Fertigstellung: Windows-App und gehosteter Dienst – Stand 27.10.2026

Antwort auf die Frage des Inhabers: Was ist kritisch, kann die Windows-App schon benutzt und in den Store geladen
werden, und was muss der Inhaber noch beschaffen (Domain, Server, Mail, Konten)? Geprüft wurde der Zweig `develop`
(`5efd32c` und folgende); alles Genannte ist entweder behoben oder hier als offen markiert.

## 1. Kurzfassung

| Frage | Antwort |
|---|---|
| Windows-App benutzbar? | **Ja, für den eigenen Gebrauch** (Installer `UniFlow_0.3.x_x64-setup.exe` aus dem Workflow `windows.yml`). Windows warnt beim ersten Start, weil der Installer nicht signiert ist („Trotzdem ausführen“). |
| In den Microsoft Store laden? | **Technisch bereit**: MSIX-Paket baut, installiert und läuft auf dem GitHub-Runner (`apps/windows/msix/README.md`). Es fehlen nur die Werte aus Partner Center (`msix/store.json`), Screenshots und eine öffentliche Datenschutzerklärung. |
| Gehosteter Dienst (Konten für andere Studierende)? | **Code und Hosting-Paket fertig, nicht in Betrieb.** Braucht Server, Domain, Mail-Anbieter, Dienst-Geheimnis, Rechtstexte (Abschnitt 4). |
| Abos (Studora, vier Tarife)? | Zweig `feature/studora-abos` (Commit `80449da`), nicht in `develop` gemergt; Apple-Seite (StoreKit) fehlt. Entscheidung des Inhabers: mergen oder bei Free/Plus bleiben. |

## 2. Kritische Stellen – geprüft am 27.10.2026

### Behoben (heute)

| Stelle | Befund | Behebung |
|---|---|---|
| Windows-Start | „Unhandled exception“ (WinError 183): Installer und Backend im selben Ordner | Daten unter `%LOCALAPPDATA%\de.uniflow.desktop`, Umzug alter Daten, jeder Startfehler ins Protokoll (0.3.1) |
| Stundenplan | eigene Übungsgruppen fehlten (viele parallele Gruppen) | Stud.IP-Kalender (`events.ics`) entscheidet wie auf dem iPad (0.3.2) |
| Module | jedes Modul dreimal | Wettlauf in `ensure_modules` beseitigt, Doppel werden beim Start zusammengeführt (0.3.3) |
| Links | „Im Stud.IP öffnen“ tat nichts (Tauri blockiert neue Fenster) | Dienst öffnet den Standardbrowser, nur http(s), nur vom eigenen Rechner (0.3.4) |
| Fristen/Termine | nur ein Tooltip, nichts erklärt | Detailfenster mit Titel, Zeit, Kurs, ganzer Ankündigung und Link (0.3.5) |
| Abgleich | keine Fortschrittsanzeige | „Kurs 3 von 20 …“, „Datei 12 von 158 herunterladen“ im Chip |
| Zweiter Start | zweites Fenster mit zweitem Backend auf derselben Datenbank | Einzelinstanz-Plugin: Fenster kommt nach vorn (0.3.6) |
| Tests unter Windows | `test_plan_names` las Node-Ausgabe als cp1252 | UTF-8 erzwungen; Suite unter Windows komplett grün |
| GitHub Actions | Windows-Workflow brach immer vor dem Bauen ab (kein pytest); Android: `gradlew` ohne Ausführrecht | behoben; Windows-Installer und MSIX bauen seit heute |

### Offen – mit Risiko und Empfehlung

| Stelle | Risiko | Empfehlung |
|---|---|---|
| **Kein Code-Signing des Installers** | SmartScreen-Warnung, Nutzer brechen ab; für die Weitergabe außerhalb des Stores ungeeignet | Microsoft Store (signiert selbst) oder Zertifikat kaufen (~200–400 €/Jahr, Azure Trusted Signing günstiger) |
| **Keine automatischen Updates** außerhalb des Stores | Nutzer bleiben auf fehlerhaften Versionen | Store-Fassung; alternativ Tauri-Updater mit GitHub Releases (Signaturschlüssel nötig) |
| **Apple-Workflow rot** seit 26.10. (`XCTExpectFailure` auf Linux) | echte Swift-Fehler fallen nicht mehr auf | Mac-Sitzung (Hinweis in `docs/STAND-MAC-SITZUNG.md`) |
| **Kein Gerätetest auf fremdem Windows-Rechner** | Unterschiede bei WebView2, Firewall, Virenscanner unbekannt | einmal auf einem frischen Laptop installieren (Checkliste Abschnitt 5) |
| **Lokales Backend ohne Zugangsschutz** (127.0.0.1, zufälliger Port, keine PIN) | jedes Programm auf dem PC könnte die API nutzen; Browser sind durch die Herkunftsprüfung ausgeschlossen | wie andere Desktop-Apps; für die Store-Prüfung dokumentieren, kein Blocker |
| **Daten liegen unverschlüsselt** im Datenordner (SQLite, PDFs, Hochschul-Sitzung) | bei Diebstahl des Laptops lesbar | BitLocker empfehlen (Datenschutzerklärung, Abschnitt 3); Hochschul-Passwort selbst liegt nie dort |
| **KI nur über Claude Code auf dem PC** | auf fremden Rechnern keine KI; Store-Texte dürfen keine KI nennen | Plan `docs/KI-CHATGPT-PLAN.md` (ChatGPT-Abo des Nutzers), erst nach OpenAI-Freigabe |
| **Laptop und iPad haben getrennte Daten** | Notizen und Haken wandern nicht | Geräte-Abgleich über den Dienst (Vertrag G2 ist fertig, Clients: Android ja, iPad/Windows-Web nein) |
| **Hosted: Abgleich im Container nie unter Last beobachtet** | Chromium-Speicher, Zeitplan 08:00/15:00 | nach dem ersten Betriebstag `docker stats` (BETRIEB.md, Abschnitt 13) |
| **Rechtstexte sind Entwürfe** mit Platzhaltern, nicht anwaltlich geprüft | Abmahnrisiko, Store-Ablehnung | Platzhalter füllen, prüfen lassen (`tests/test_release_texts.py` listet sie) |

## 3. Microsoft Store – was fehlt

1. Partner-Center-Konto (storedeveloper.microsoft.com), App anlegen, Namen reservieren.
2. Produktidentität (drei Werte) in `apps/windows/msix/store.json` eintragen, `store_ready: true`.
3. Datenschutzerklärung unter einer öffentlichen Adresse (Pflicht), mindestens ein Screenshot 1366×768, Beschreibung.
4. Paket `UniFlow_<version>.0_x64.msix` aus dem Artefakt `uniflow-windows-msix` hochladen, Altersfreigabe
   ausfüllen, Prüfhinweis mit Demo-Inhalten (Einstellungen → Erweitert).
Danach verteilt der Store Updates automatisch. Genaue Schritte: `apps/windows/msix/README.md`.

## 4. Was der Inhaber beschaffen muss

| Was | Wofür | Wo eintragen | Kosten (ca.) |
|---|---|---|---|
| **Domain** (z. B. `uniflow.de` → `app.uniflow.de`) | Dienst, Datenschutzerklärung, Mail-Absender, Store-Links | `deploy/.env`: `UNIFLOW_DOMAIN`, `LERNAPP_ALLOWED_HOSTS`, `LERNAPP_PUBLIC_URL`; DNS A/AAAA auf den Server | 1–2 €/Monat |
| **Server (VPS, EU)** 2 vCPU, 4 GB RAM, 40 GB | gehosteter Dienst mit Konten | Debian/Ubuntu, Docker, `deploy/` nach `docs/release/BETRIEB.md` | 5–6 €/Monat (Hetzner CX23 o. ä.) |
| **Vertrag zur Auftragsverarbeitung** mit dem Hoster | DSGVO Art. 28 | Hoster-Konsole; Hoster und Standort in `DATENSCHUTZ.md` | 0 € |
| **Dienst-Geheimnis** | verschlüsselt Hochschul-Zugangsdaten aller Konten | `LERNAPP_SECRET_KEY` (32 Byte, `openssl rand -base64 32`), getrennt von Backups aufbewahren | 0 € |
| **Mail-Anbieter mit SMTP** (Resend, Brevo, Postmark, Mailgun …) | Passwort-vergessen-Link, Willkommensmail | `LERNAPP_MAIL=smtp`, `LERNAPP_SMTP_HOST/PORT/USER/PASSWORD`, `LERNAPP_MAIL_FROM`; Domain beim Anbieter verifizieren (SPF/DKIM); Anbieter in `DATENSCHUTZ.md` Abschnitt 11 | Resend: kostenlos bis 3.000 Mails/Monat; SMTP laut Resend-Doku `smtp.resend.com`, Port 465 oder 587, Nutzer `resend`, Passwort = API-Schlüssel (beim Einrichten prüfen) |
| **Backup-Ziel außer Haus** (Storage Box, S3) | Wiederherstellung nach Serverausfall | `deploy/backup.sh` schreibt nach `/srv/uniflow/backups`; Ziel per rclone/rsync | 3–4 €/Monat |
| **Monitoring** (Uptime-Robot o. ä.) | merkt Ausfälle | HTTPS-Check auf `/login` | kostenlos |
| **Rechtstexte** | Impressum, Datenschutz, Nutzungsbedingungen, Konto löschen | Platzhalter in `docs/release/*.md`: Name, Anschrift, E-Mail, Telefon, Domain, Hoster, Standort, Mail-Anbieter, Datum, ggf. USt-IdNr. | Anwaltsprüfung nach Aufwand |
| **Microsoft Partner Center** | Store-Veröffentlichung | `apps/windows/msix/store.json` | kostenlos (Einzelperson, beim Anlegen prüfen) |
| **Apple Developer Program** | iPad-App, „Mit Apple anmelden“, iCloud | `apps/apple/Config/Team.xcconfig`; für den Dienst `LERNAPP_APPLE_CLIENT_IDS` | 99 €/Jahr |
| **Google Cloud Client-IDs** (optional) | „Mit Google anmelden“ | `LERNAPP_GOOGLE_CLIENT_IDS`, `LERNAPP_GOOGLE_WEB_CLIENT_ID` | 0 € |
| **OpenAI-Freigabe** (später) | KI über das ChatGPT-Abo der Nutzer | Interessenformular, siehe `docs/KI-CHATGPT-PLAN.md` | 0 € |
| **Code-Signing-Zertifikat** (nur außerhalb des Stores) | Installer ohne Windows-Warnung | Workflow `windows.yml`, Schritt vor dem Hochladen | 200–400 €/Jahr |

Mindestens für einen **Start nur mit der Windows-App** (ohne Dienst): nichts davon außer Partner Center und den
Rechtstexten. Für den **Dienst mit Konten**: Domain, Server, AVV, Geheimnis, Mail, Backup, Rechtstexte.

## 5. Abnahme vor der Veröffentlichung (Inhaber, je 10–20 Minuten)

1. Frischer Windows-Laptop ohne Python: Installer starten, SmartScreen bestätigen, App startet, Einstellungen →
   Zugang → „Im Browser anmelden“ (Stud.IP), Abgleich, Fortschritt sichtbar, Stundenplan mit eigenen Gruppen,
   Dokument öffnen und schreiben, „Im Stud.IP öffnen“ öffnet den Browser.
2. App schließen, erneut öffnen: Daten da. Zweites Öffnen bei laufender App: nur ein Fenster.
3. Flugmodus: Dokumente, Stundenplan, Kalender weiter sichtbar; KI-Funktionen melden sauber, dass sie nicht gehen.
4. Deinstallieren über Windows-Einstellungen: Programm weg, Daten unter `%LOCALAPPDATA%\de.uniflow.desktop` bleiben
   (bewusst), bei Neuinstallation wieder da.
5. Dienst (wenn gebucht): BETRIEB.md Abschnitte 1–7, dann Registrierung im Browser, Passwort vergessen (Mail kommt),
   Abgleich mit Hochschulkonto, Backup-Archiv prüfen.
