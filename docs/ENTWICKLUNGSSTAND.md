# Entwicklungsstand nach Phasen (Zweig `develop`, Stand 30.10.2026)

> Gesamtstand und was bis zur Veröffentlichung fehlt: `RELEASE-READINESS.md` im Projektordner.
> Bericht des Tages mit Architektur, Testzahlen und Nachtrag vom Mac: `BERICHT-CLOUD-SITZUNG-2026-10-30.md`.
> Checkliste Web ↔ iPad je Funktion: `WEB-IPAD-PARITAET.md` im Projektordner (erzeugt mit `tools/gen-parity.py`,
> Stand 25.10., nicht fortgeschrieben).

Grundregel dieses Berichts: „getestet“ heißt, der Test lief wirklich und ist grün. Nichts hier wurde auf einem echten
iPad, Mac-Gerätetest oder Server ausgeführt; iOS-Tests liefen im iPad-Simulator auf dem Mac, Python, JS und der
Swift-Kern im Cloud-Container (Linux) und auf dem Mac.

**GitHub Actions:** seit dem 25.10., 00:15 Uhr, startet GitHub keine Jobs (Abrechnung, `GITHUB-ABRECHNUNG.md`). Alle
Commits seitdem tragen `[skip ci]`; alle Zahlen unten stammen aus lokalen Läufen.

## Testläufe

| Lauf (Commit, Ort) | Linux-Kern | macOS-Kern | iPad-App | Python | JS | Generatoren | Android |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `6b699b4` Phase 2/3 (Actions, 24.10.) | 35 | 37 | 12 | grün | 10 | – | – |
| `ecfdfab` Phase 4 (Actions, 25.10.) | grün | grün | App kompiliert, Testdatei mit Fehler | – | – | – | – |
| `7efe85f` Phase 5/6 (Actions) | **nicht gestartet (Abrechnung)** | – | – | – | – | – | – |
| Docker `android-sdk:35` (PC, 27.10.) | – | – | – | – | – | – | 119 |
| `ed565d8` (Mac, 29.10.) | – | 765 ×2 | 557 ×2 | 558 | – | alle | – |
| `ea88dfe` Lernplan-Regel (Cloud, 30.10.) | 754 ×2 | – | **nicht gelaufen** | 568 ×2 | 31 | 21 | – |
| `0252597` Hintergrund-Wochentests, Kern (Cloud, 30.10.) | 756 ×2 | – | – | 573 | 31 | 21 | – |
| `8f8cb8c`/`ae844ad` (Mac, 30.10. abends) | – | 776 ×2 | 563 ×2, dann 564 ×2 | – | – | – | – |
| `fbffbc2` Web als App (Cloud, 30.10.) | – | – | – | 580 (mit Chromium-Lauf) | 38 | 21 | – |
| `8d40053` Zustimmung, Wochentests im Dienst (Cloud, 30.10., 22 Uhr) | – | – | – | **598** | 38 | 21 | – |

Stand am Ende des 30.10.: **pytest 598, Swift-Kern 776 (Linux 761), App 564, JS 38, Generatoren 21, Android 119.** Die
Linux-Zahl des Kerns ist kleiner, weil 15 Tests (Schlüsselbund, ChatGPT-Sitzung) nur auf Apple-Systemen laufen.

## Phase 1 – Audit und Live-Blocker
- **Fertig:** P0/P1-Lücken im Server (Pfad-Traversal, fremde Webseiten, DNS-Rebinding, gleichzeitiges Speichern,
  `.env`, PIN in Antworten), Web-Entwurf beim Dauerschreiben, eingeschleustes HTML. Liste: `BESTANDSAUFNAHME.md` 2a.
- **Getestet:** je Befund ein Test, der am alten Code fehlschlug (`tests/test_security*.py`).
- **Seitdem:** CSP für die Oberfläche, gehosteter Modus mit Anmeldung, Herkunftsprüfung in der Windows-App.

## Phase 2 – PencilKit und PDFKit
- **Fertig:** PDFKit scrollt und zoomt, PencilKit schreibt; Palette am festen Anker; Overlays wiederverwendet;
  Zeichnung nie mitten im Strich ersetzt; Rückgängig je Dokument; Hoch- und Querformat.
- **Getestet (Simulator, Mac):** Seitenkoordinaten, Overlay, Zoomregeln, Strich-Identität, 1000 Striche.
- **Unbestätigt bis zum Gerätetest:** Schreibgefühl, Handballen, Pencil-Doppeltippen, Palette.

## Phase 3 – Datenverlust verhindern
- **Fertig:** `UniFlowCore`: Journal je Seite mit Revisionen, ein Upload gleichzeitig, 409 → objektweise
  Zusammenführung, Offline-Wiederholung, Umrechnung abseits des Hauptthreads.
- **Getestet (Linux + Mac):** 1000/5000 Striche, Schreiben während Upload, Netzabbruch, Absturz, Speicherfehler,
  Konflikt, gleiche Seite auf zwei Geräten, Neustart, verlorene Bestätigung.

## Phase 4 – PDF-Editor (iPad) und Editor-Schritte 3–6
- **Fertig:** Seitenaufbau wie im Web, Text/Formen/Bilder sichtbar, Lesezeichen, Leerseite mit Vorlage, Suche,
  Seitenübersicht, Export mit Notizen, PDF-Import, Dokument-Tabs. Danach die Schritte der Abnahmeliste
  (`EDITOR-ABNAHME.md`): Schritt 3 Seite drehen ohne Verrutschen (Web + iPad, gemeinsame Prüfdaten), fremde native
  Zeichnung durchreichen; Schritt 4 Versionsverlauf höchstens alle 5 Minuten, Snapshot beim Schließen und nach
  Konflikt (Runde 13–16 s → 4,4 s); Schritte 5 und 6 Seitenwerkzeuge, Gliederung, gemischte Formate, eingefügte
  PDF-Seiten, Objekt-Werkzeuge (Text, Haftnotiz, Formen, Lasso, Textmarker), Linkshänder.
- **Getestet:** App-Tests im Simulator (Mac, 30.10.), JS-Tests für Drehen und Lösungen, Prüfvektoren.
- **Offen:** Abnahme am echten iPad mit Apple Pencil (nur der Inhaber).

## Phase 5 – native Oberfläche
- **Fertig und getestet (Simulator, Mac, 30.10.):** Tabs Übersicht, Dokumente, Module, Kalender (Tag/3 Tage/Woche),
  Wochentests, Karteikarten, Uni & Noten, Einstellungen (Profil, Schreibhand, Pencil, Hintergrundabgleich, Tarif,
  ChatGPT, Studora-Konto, Diagnose, Demo); Lade-, Fehler-, Offline- und Leerzustände; Barrierefreiheit (152 Angaben,
  VoiceOver-Namen auf Deutsch, Dynamic Type bis Accessibility3, Bewegung reduzieren). Erster Start: Apple → Tarif →
  Hochschule → Anmeldeseiten der Uni → Erstabgleich. `CFBundleName` „Studora“.
- Der frühere Eintrag „nicht gebaut“ gilt seit dem 26.10. nicht mehr (Mac-Sitzung); seit dem 30.10. voller Lauf 564 ×2.

## Phase 6 – Skriptsuche und Split-Screen
- **Fertig und getestet:** Web: Hinweis zur Aufgabe, geteilte Ansicht. iPad: zweites Dokument daneben, Schreibhand,
  gemeinsame Palette, Vorschlag über `/api/related` (lokal im Kern); Suche offline.
- **Offen:** Verhalten am Gerät.

## Phase 7 – Konten, Abgleich und Abos
- **Fertig:** Studora-Konto G1 (`app/accounts.py`, `account_api.py`, 18 Endpunkte: registrieren, E-Mail bestätigen,
  anmelden mit E-Mail, Apple, Google, Passwort zurücksetzen, Geräte, Export, löschen); Geräte-Abgleich G2
  (`app/sync.py` Dienst, `sync_client.py` Windows, Android `SyncEngine`); im Swift-Kern `StudoraAccountLink`
  (sichtbar erst mit Dienst-Adresse), **kein G2-Client auf dem iPad**. Vier Tarife in `app/plans.py`, Rechte in
  `entitlements.py`, Apple-Belege (`apple_store.py`), Kontingente mit Reservierung.
- **Neu 30.10.:** 7 Tage Probe mit allen Rechten für jedes neue Konto (`billing.start_trial`), danach Tarifwahl
  (`needs_plan_choice`, `POST /api/billing/plan-choice`); Stripe für Web und Windows (`app/stripe_billing.py`:
  Checkout, Kundenportal, Webhook mit Signatur, jedes Ereignis einmal; ohne Schlüssel 503 `stripe_not_configured`).
- **Getestet:** `tests/test_accounts.py`, `test_subscriptions.py`, `test_trial_stripe.py` (13), `test_billing.py`,
  `test_sync.py`, `test_hosted_sync.py`; iPad Kauf-Tests (19) grün mit `xcodebuild test` (mit `test-without-building`
  fielen sie durch, Grund offen).
- **Offen:** Stripe-Konto und Preise (Inhaber), Microsoft-Store-Beleg (nicht gebaut), Downgrade über das Kundenportal,
  Apple-Kaufprüfung beim Dienst (`BillingServiceLink.swift`, einziges TODO im Code, V2), Plus-Kontingent 3 oder 6.

## Phase 8 – Windows, Android, gemeinsame Daten
- **Fertig:** Verträge (`packages/shared-contracts`: Schema, API-Schemas, Prüfdaten aus 21 Generatoren); gleiche
  Zusammenführung in Swift, Web, Kotlin. Windows-App 0.4.9 (Tauri 2, PyInstaller-Backend, Daten unter
  `%LOCALAPPDATA%\de.uniflow.desktop`, Sicherungen, Einzelinstanz, Konto und Community über den Dienst, MSIX für den
  Store). Android-Kern und -App als Client für Dienst oder PC mit Offline-Stand.
- **Getestet:** Swift (Linux + Mac), Web (Node 38), Python (598), Android 119 im Docker-Bild, Windows-Installer still
  installiert und geprüft (27.10., Workflow `windows.yml`).
- **Offen:** Android auf einem Gerät, Windows auf einem fremden Rechner, Android „Seite drehen mit Notizen“
  (`rotate/cases.json`).

## Phase 9 – CI
- **Fertig:** Workflows Apple, CI (Python, pip-audit, Geheimnis-Prüfung, Web), Android, Windows (manuell).
- **Gesperrt seit 25.10.:** Abrechnung des Kontos. Alle Prüfungen laufen lokal; der Swift-Kern ohne Mac in Docker
  (`BERICHT-CLOUD-SITZUNG-2026-10-30.md` Abschnitt 6). Widersprüchlich in den Quellen: ob der Windows-Workflow am 27.10.
  trotz Sperre lief.

## Phase 10 – Release
- **Fertig:** `RELEASE-VORBEREITUNG.md`, `MAC-IPAD-CHECKLISTE.md`, Rechts- und Store-Texte als Entwürfe in
  `release/` (Platzhalter, nicht anwaltlich geprüft), Info.plist ohne `NSAllowsArbitraryLoads`, Privacy Manifest,
  Demo-Inhalte für die Apple-Prüfung.
- **Blockiert:** Apple Developer Program am 28.10. abgelehnt (Support-Fall beim Inhaber). Ohne Freigabe kein
  TestFlight, keine Einreichung, kein „Mit Apple anmelden“, keine CloudKit-Community. Darum Reihenfolge neu
  (Phase 15).

## Phase 11 – Hochschulen: LUH und Hildesheim
- **Fertig:** Stud.IP (WebSSO, JSON-API, Ordner, Opencast), QIS-Noten und Bescheinigungen, Learnweb und LSF über CAS
  (`app/hildesheim.py`, `learnweb.py`, `lsf.py`, `cas.py`), getrennte Datenordner je Hochschule, Semester automatisch
  (`semesters.py`), Stundenplan 1:1 aus dem Stud.IP-Kalender; auf dem iPad derselbe Ablauf im Kern (`UniStore`,
  `UniRules`, `UniDownloads`). Passwörter merkt nur iOS bzw. die Windows-Kennwortverwaltung, nie die App.
- **Getestet:** mit 150 echten LUH-Dateien (PC und Simulator), Hildesheim ohne Netz gegen Nachbildungen
  (`HILDESHEIM-PARITAET.md`).
- **Offen:** Hildesheim mit echten Daten auf dem iPad (195 gegen 539 Dateien), QIS auf dem iPad (0 Leistungen).

## Phase 12 – Lernplan nach der Regel des Inhabers (30.10.)
- **Fertig:** `study.generate_packages` nimmt je Tag nur die Lehrwoche des Tages; `_marker_rest` ergänzt den Skriptrest
  nach dem Seitenmarker der Vorwoche (nur eigene, nicht gelöschte Marker; je Lehrwoche höchstens einmal);
  `auto_plan_week` läuft nach jedem Abgleich (PC `_full_sync`, `sync.py`; iPad `StudyAutoPlan.afterSync` nach
  Stud.IP und Learnweb). Testaufgabe öffnet den gemeinsamen Wochentest (`task_test`, sonst 409 mit Grund).
  **Entfernt:** `POST /api/plan/generate`, `planner.generate_plan`, `ai.build_week_plan`, die Wochenplan-Fälle im
  KI-Vertrag und in Swift.
- **Getestet:** Prüfdaten `study-plan.json` Szenario „lehrwoche“, `tests/test_week_plan_rule.py`; absichtliche Fehler
  werden erkannt (5 in Python, 5 in Swift). App-Lauf 30.10.: drei Tests an die Regel angepasst (Testdaten, nicht Logik).

## Phase 13 – Wochentests mit Seitenmarker
- **Fertig (PC):** `app/weekly.py`: Marker „Vorlesung bis hier“, Stoffumfang je Lehrwoche, Aufgabenindex (BM25),
  Zulässigkeit, Zeitplan (24 h, Warten auf erwartete Unterlagen bis 48 h), 15 Aufgaben 4/6/5 mit genau einer
  Altklausuraufgabe, Regelprüfung und KI-Fachprüfung, gemeinsame Version je `scope_key`, Nachtrag, Rangliste,
  Probeklausur. Takt nach dem Abgleich und alle 10 Minuten, nur mit KI.
- **Fertig (iPad):** Kern `LocalBackend/Weekly/` byte-gleich zu Python (Fixture `weekly.json`), Oberfläche
  (Dialog im Dokument, Kennzeichen an Miniaturen, Box „Lernfortschritt & Wochentests“), Takt im Vordergrund.
  **Hintergrundlauf (30.10.):** Entscheidung als reine Logik in Python und Kern (`background_decision`,
  `WeeklyBackground.decide`, 90 Fälle inkl. Zeitumstellung), Lauf im langen `BGProcessingTask` um 8, 15, 20 Uhr,
  auch bei ausgeschaltetem Abgleich, nie neben einem laufenden Abgleich; Abbruch kostet keinen Versuch; Mitteilung
  „Neuer Wochentest verfügbar“; Debug-Knopf, weil der Simulator `BGTaskScheduler` ablehnt.
- **Fertig (Dienst, 30.10.):** Takt je Konto als Job in `app/jobs.py` (nach dem Abgleich, zu den Zeitfenstern, auf
  Knopfdruck `POST /api/weekly/tick`), KI = Studora-KI, jeder neue Test verbraucht eins aus `ai_tests_new`
  (Free 0 → Plan wartet mit Grund, Plus 3, Pro AI 40). Kein Teilen zwischen Konten (V2-Dienst).
- **Getestet:** `tests/test_weekly.py`, `test_week_test_rule.py`, `test_testshare.py`; Kern `WeeklyFixtureTests`,
  `WeeklyAutoTickTests`; App `WeeklyAppTests`, `BackgroundSyncAppTests` (Mac, 30.10.).
- **Ungeprüft:** echte KI auf echtem Skript; Start des Hintergrundlaufs durch iOS (nur am Gerät über Tage).

## Phase 14 – KI: Claude, Sign in with ChatGPT, Studora-KI
- **Fertig:** (1) `app/ai.py` über `claude -p` am eigenen PC (Modelle `CLAUDE_MODEL`, `CLAUDE_MODEL_MATERIAL`).
  (2) Sign in with ChatGPT (`app/chatgpt_login.py`, Swift `UniFlowCore/AI`, `ChatGPTLink`): dynamische Registrierung
  (`client_id=dynamic_agent_client`), **keine vorab vergebene Client-ID nötig**, PKCE, ID-Token gegen JWKS, Responses
  API, rotierendes Refresh-Token; am 30.10. mit dem OpenAI-Devkit abgeglichen (`login_hint`, Freigabe nachholen,
  anderes Konto, `account_mismatch`, `earliest_refresh_at`). In jedem iPad-Build verfügbar; im gehosteten Dienst aus,
  bis OpenAI freigibt. Tutor-Prompt gleich für `claude -p` und Studora-KI. (3) Studora-KI im Dienst
  (`app/ai_backend.py`): Anbieter und Schlüssel nur auf dem Server, Budget je Monat und je Konto, Rate-Limit, Cache,
  Sperre gegen doppelte Generierung.
- **Getestet:** `tests/test_chatgpt_login.py`, `test_ai_contract.py`, `test_ai_console.py`; Kern 776 (ChatGPT-Sitzung
  nur auf Apple); Simulator: Karte, Zustimmung, Systemabfrage und echte Anmeldeseite öffnen sich.
- **Ungeprüft:** jede echte Anmeldung und Anfrage (nur der Inhaber); Fehlercodes der Responses API bei erschöpftem
  Kontingent; OpenAI-Zulassung für den gehosteten Dienst (Warteliste); Repo wird privat, keine Lizenzdatei (Entscheidung 31.10.).

## Phase 15 – Web zuerst: Dienst und Web-App (30.10.)
- **Fertig:** gehosteter Modus (`LERNAPP_MODE=hosted`, eine Datenbank je Konto, `/login`, Rechtsseiten),
  Hosting-Paket `deploy/` (Docker, Caddy mit HTTPS, Backups, Löschfristen). Web als installierbare App:
  `app/static/pwa.js` (Hinweis „Zum Home-Bildschirm“, „Zum Dock“, „Installieren“, einmal auf der Übersicht und als
  Karte in den Einstellungen), `sw.js` mit Regeln in `sw-policy.js` (Netz zuerst, Ablage als Rückfall für Oberfläche,
  zuletzt geöffnete Dateien und Listen; nie aus der Ablage: Konto, Aufträge, Abgleich, Suche, Bezahlung,
  Zugangsdaten; Änderungen ohne Netz 503 `offline`; Ablage je Konto, leer beim Abmelden). Hochschul-Zugangsdaten beim
  Dienst nur mit Zustimmung (`PUT /api/credentials` mit `consent: true`, Karte mit Erklärung und „Zugangsdaten
  löschen“, Satz in `release/DATENSCHUTZ.md`).
- **Getestet:** `tests/test_pwa.py` mit echtem Chromium (laden, Netz aus, neu laden, Konto nie aus der Ablage),
  `tests/js/sw.test.mjs`, `test_deploy.py`, `test_web_login.py`, `test_legal_pages.py`; Container lokal `healthy`.
- **Fertig (30.10., abends):** Notizen ohne Netz zwischenspeichern und nachsenden (`app/static/notes-queue.js`, 11 Node-Tests,
  Chromium-Lauf mit 409-Zusammenführung); Lasttest in-process (`docs/LASTTEST-DIENST-2026-10-30.md`); Startpaket
  (`deploy/`, `docs/START-DIENST-CHECKLISTE.md`, Backup/Restore im Container durchgespielt).
- **Offen:** Dienst nie auf einem Server; Safari auf iPad und Mac ungeprüft; Rechtstexte mit Platzhaltern; Server, Domain, Mail, Stripe,
  Partner Center beim Inhaber.

## Phase 16 – Community
- **Fertig:** Dienst G4 (`app/community_api.py`, 38 Endpunkte): Lösungen als verschlüsseltes Paket (nur mit der
  Original-PDF lesbar), Fingerabdrücke der eigenen PDFs, Likes, Kommentare an der Stelle, Fragen je Kurs, Melden,
  Sperren, Rangliste für den Admin. Web und Windows im Editor (`editor-community.js`, Testvektoren). iPad über
  CloudKit (Veröffentlichen, Lerngruppen mit Code/QR).
- **Getestet:** `tests/test_community*.py`, JS `solutions.test.mjs`, Kern `SolutionCrypto`.
- **Offen:** iPad von CloudKit auf den Dienst umstellen (braucht Dienst und Apple-Freigabe für den heutigen Weg);
  Community nie im Betrieb mit echten Nutzern.

## Nächster Schritt

1. Inhaber: Server, Domain, Mail-Anbieter, Stripe-Konto, Rechtstexte; einmal mit dem eigenen ChatGPT-Abo anmelden und
   einen Wochentest auf echtem Skript prüfen.
2. Inhaber: Server, Domain, Mail nach `docs/START-DIENST-CHECKLISTE.md`; danach Sitzung: Dienst in Betrieb nehmen, Lasttest auf dem Server, Prüfung in Safari.
3. Inhaber + PC-Sitzung: Microsoft Store (Partner Center, Screenshots, Einreichung).
4. Mac-Sitzung, sobald Apple freigibt: G2-Client auf dem iPad, Community über den Dienst, Gerätetest nach
   `MAC-IPAD-CHECKLISTE.md` und `EDITOR-ABNAHME.md`, App Store.
