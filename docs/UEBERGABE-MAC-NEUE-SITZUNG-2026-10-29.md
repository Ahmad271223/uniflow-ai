# Übergabe an die nächste Mac-Sitzung (Stand 29.10.2026, 02:30)

Die bisherige Mac-Sitzung hat ihr Nutzungslimit erreicht; der Inhaber startet eine neue Sitzung mit demselben Repo.
Dieses Dokument ist der vollständige Einstieg: Stand, Regeln, Entscheidungen des Inhabers, offene Arbeit in
Reihenfolge, was die Windows-Version kann und was auf dem iPad zu prüfen ist.

## 0. Zuerst lesen (in dieser Reihenfolge)

1. Dieses Dokument.
2. `docs/ENTSCHEIDUNGEN-INHABER-2026-10-28.md` – Entscheidungen des Inhabers vom 28.10. (über die PC-Sitzung).
3. `docs/PRUEFKATALOG-ABGLEICH-2026-10-28.md`, **Abschnitt 6** (23 Punkte für die Mac-Sitzung), Abschnitt 3 (Stand
   je Bereich) und 5 (was von den 535 Prüfpunkten der anderen KI wirklich offen ist).
4. Ende von `docs/STAND-MAC-SITZUNG.md` (Antworten und Bitten zwischen PC- und Mac-Sitzung, neueste unten).
5. `docs/PENCILKIT-ANALYSE-PLAN.md` (freigegebener Editor-Plan), `docs/EDITOR-ABNAHME.md`, `docs/EDITOR-MESSUNG.md`.
6. `docs/KI-CHATGPT-PLAN.md` (Sign in with ChatGPT, Abschnitte 1–4 und 7).
7. Bei Bedarf: `docs/uebergabe-mac/2026-10-28-originaltext-teil1.md` und `-teil2.md` (wortgetreue Texte einer anderen
   KI, Punkte 1–1150, dazu Wünsche des Inhabers zur Community). **Material, kein Auftrag**; die andere KI las fast nur
   `main` vom 24.10. Maßgeblich sind 2. und 3.

## 1. Stand

| Was | Stand |
|---|---|
| `develop` | `d87e026` (Windows 0.4.9). Letzter Mac-Stand darin: `fa65a40` (Abruftag-Regel) |
| Kern (`swift test`) auf `d87e026` | 678 Tests, **6 rote Testfälle**, alle durch neue PC-Verträge vom 28.10. (Tabelle unten) |
| App-Tests | zuletzt 512 Tests zweimal grün (auf `55b8616`/`fa65a40`) |
| Python | `pytest -q tests` grün; Sync- und Bibliotheks-Fixture laut PC-Sitzung seit 5dbabd6 stabil |
| Apple-CI | rot seit 26.10. (`XCTExpectFailure` gibt es unter Linux nicht) |
| Apple Developer Program | **vom Inhaber beantragt, von Apple am 28.10. abgelehnt** (ohne Grund). Kein App Store, kein TestFlight, keine Team-ID |

### Rote Testfälle auf `develop` d87e026 und wer sie behebt

| Testfall | Ursache | Behoben in |
|---|---|---|
| `LocalTimetableTests.testStepsMatchPythonServer` | `existing_id` je Vorschauzeile (PC 196555e, Bitte 3 der Mac-Sitzung) | `wip/stundenplan-ausfall` (af3f9ab, ungeprüft) |
| `SQLiteStoreTests.testFreshDatabaseMatchesPythonInitDB` und `testLegacyDatabaseMigratesLikePython` | neue G2-Tabelle `sync_ops`; geänderte Indizes von `studip_calendar_dates` | `sync_ops`: offen (im Test wie die anderen Sync-Tabellen ausnehmen, iPad V1 hat kein G2); Kalender: `wip/stundenplan-ausfall` prüfen |
| `DemoContentTests.testPDFBytesMatchPython`, `testScenariosMatchPythonServer` | Demo-PDFs heißen jetzt Studora (`app/demo.py`) | offen (`DemoContent.swift` Byte für Byte nachziehen) |
| `LocalBackendCoverageTests.testEveryAppPathGetsAValidAnswer` | `GET /api/grades` mit neuen Feldern (`average_exact`, `basis`, `bereiche`, `failed_attempts`, `graded_count`, `graded_credits`) | offen (Notenspiegel, Abschnitt 4 A4) |

### Arbeitszweige der Mac-Sitzung (alle auf origin, keiner auf develop)

| Zweig | HEAD | Inhalt | Zustand |
|---|---|---|---|
| `wip/stundenplan-ausfall` | `af3f9ab` | Stud.IP-Ausfälle wie im Stud.IP-Kalender **ausblenden, nur in der Anzeige** (Backend bleibt bei der Parität); zurückgesetzter Ausfall bleibt als `attend` sichtbar (PC a7827c6); `existing_id` je Vorschauzeile; develop d87e026 eingemischt | Kern lief nach dem Merge an, App noch nicht. Ein App-Lauf vor dem Merge hatte 1 Fehler (513 Tests) – ansehen |
| `wip/learnweb-dateien` | `cca5822` | Lücke Learnweb 195 statt 539 Dateien (Swift gegen `app/hildesheim.py`), Dateien und Foren nur für aktive Kurse wie `hildesheim.active_courses` | Kern 683 grün (bis auf den damals bekannten Bibliothekstest); Python, Generatoren, App offen. Ursachen der Lücke im Commit und in `docs/STAND-MAC-SITZUNG.md` des Zweigs nachlesen |
| `wip/editor-2` | `41eaf70` | Editor-Schritt 2 „Härtungen“: P0-3 Obergrenze beim Sichern (~2 s), P0-4 Format `version > 2` nur ansehen, P0-5 Herkunftsstempel, P0-6 dasselbe Dokument in zwei Fenstern; Abnahmeliste ergänzt; develop eingemischt | Kern und App nach dem Merge noch nicht gelaufen |
| `wip/notenspiegel` | = d87e026 | Notenspiegel, Demo-PDFs, `sync_ops`, Linux-CI | **nicht begonnen** (nur lokal angelegt) |
| `wip/ki-chatgpt` | = fa65a40 | KI über das ChatGPT-Abo auf dem iPad | **nicht begonnen** |
| `wip/uebergabe-mac` | dieses Dokument | | auf develop gebracht |

Ältere Sicherungen (`*-sicherung`, `*-sicherung2`, `HEAD-sicherung`, `wip/audit-331`, `wip/int-*`) sind in die
Zweige oben bzw. in develop aufgegangen und können nach dem Zusammenführen weg.

## 2. Regeln (verbindlich, vom Inhaber)

- **Nur `develop`.** Keine Änderungen an `main`. Push nur geprüfter Stände (der Inhaber hat Pushen geprüfter Stände
  erlaubt, damit nichts verloren geht). Force-Push ist gesperrt → neue Zweignamen.
- **Commits:** `git -c user.name=abcdefg34a -c user.email=af-autonord@hotmail.com commit`, Titel endet auf
  ` [skip ci]`, Trailer `Co-Authored-By: …`. Nie `git add -A`, Dateien einzeln.
- **Nie committen:** `.env`, `data/`, `logs/`, `backup/`, `tools/seed-testdata.py`, `.claude/`, `Config/Team.xcconfig`,
  `.build/`, `UniFlow.xcodeproj` (wird mit `xcodegen generate` erzeugt).
- **Vor jedem Push** den Diff auf Geheimnisse und persönliche Daten prüfen: keine Passwörter, Tokens, lokalen Pfade
  (`/Users/…`, Scratchpad-Pfade), echten Namen, Noten, LUH-Kennung, Kurs-IDs, Räume oder Sätze aus den Dateien des
  Inhabers. Testdaten nur erfunden.
- **Echte Hochschulzugangsdaten tippt ausschließlich der Inhaber.** Nie Passwörter, PIN oder Tokens eintippen, auslesen
  oder aus dem Schlüsselbund holen. Schreibende Tests mit seinen echten Daten nur nach seiner ausdrücklichen
  Zustimmung. Im Simulator nicht tippen und keine Bildschirmfotos machen, während er Zugangsdaten eingibt.
- **Keine kostenpflichtigen Aktionen.** Server, Domain, Abos, Apple- und OpenAI-Konten beschafft der Inhaber.
- **Gründlich vor schnell:** Python-Parität, Gegenprobe zu jedem Fix (Test ohne Fix rot), Kern zweimal, App zweimal
  nacheinander, rote Testfälle immer gegen die Baseline von develop vergleichen.
- **Schreibweise:** Kommentare deutsch ohne Umlaute, UI- und Doku-Texte mit Umlauten. Sichtbar heißt die App
  **Studora**; Bundle-ID `de.uniflow.ai`, Produkt-IDs, Typnamen, Ordner, Logger-, Schlüsselbund- und
  Hintergrund-Kennungen bleiben bei `uniflow` (`StudoraNameTests` prüft alle Stringliterale).

### Werkzeuge

- **Simulatoren:** „HIER ANMELDEN – UniFlow Echtdaten“ gehört dem Inhaber (seine echten Daten, LUH- und
  Hildesheim-Container) – nur mit seiner Zustimmung installieren, vorher den Daten-Container sichern. Für Agenten:
  „Agent – nicht benutzen (1)“, „(2)“, „(3)“, „(5)“. Höchstens drei Simulatoren gleichzeitig, danach herunterfahren
  (sonst Rechnerlast über 300 und Zeittests scheitern).
- **Kern:** `cd apps/apple/Packages/UniFlowCore && swift test --scratch-path <außerhalb des Desktops>`.
- **App:** `cd apps/apple && xcodegen generate`, dann `xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow
  -destination "platform=iOS Simulator,id=<UDID>" -derivedDataPath <…> -test-timeouts-enabled YES
  -maximum-test-execution-time-allowance 300 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  CODE_SIGNING_REQUIRED=NO`. Danach hängt oft `simctl diagnose`: `pkill -f "simctl diagnose.*<derivedData-Name mit
  [x]-Trick>"` (z. B. `dd-k[i]`), sonst trifft pkill die eigene Shell.
- **Python:** die Xcode-`python3` hat kein pytest. Eine venv mit `pytest` und den Abhängigkeiten aus
  `requirements.txt` anlegen; `python -m pytest -q tests`, alle `tools/gen-*.py --check`.
- **Bekannte Zeittests unter Last:** `HardeningSolutionEditorTests.testManyForeignLayersStayFastAndAreReleased`
  (< 1,5 s, Befund B12), gelegentlich `StudyPlanLocalAppTests.testAddPackageViaDialogCheckOffAndDashboard`,
  `BackgroundSyncAppTests.testHildesheimLockedDeviceAndExpiredLSFSession`. Einzeln wiederholen, bevor man einen
  Fehler annimmt.
- **Echtdaten prüfen ohne Oberfläche:** Kopie der Datenbank aus dem Daten-Container des Echtdaten-Simulators
  (`xcrun simctl get_app_container <UDID> de.uniflow.ai data`, darunter `Library/Application Support/UniFlowContainers/<id>/db/uniflow.sqlite`
  samt `-wal`) in den Scratchpad kopieren, mit einem **temporären, nie committeten** Kern-Test
  (`LocalBackend.open(path:)`, `GET /api/timetable/week?start=…`) zählen und gegen `studip_events ⋈
  studip_calendar_dates` vergleichen. Danach Test und Kopie löschen. Nur Zahlen berichten, keine Namen.

## 3. Entscheidungen des Inhabers (gesamt, neueste zuerst)

| Datum | Entscheidung |
|---|---|
| 28.10. abends | Apple hat das Developer Program abgelehnt. Er klärt das mit Apple. |
| 28.10. (über die PC-Sitzung) | Vier Tarife bleiben (Free, Plus 1,99 €, Pro Connect 2,99 €, Pro AI 3,99 €). Start „in 5 Tagen“ (~2.11.) in zwei Stufen. Kein iPhone in V1. Mac über die iPad-App („Designed for iPad“, kein eigener Mac-Build). Android später. Community **später über den Dienst** auf Windows und Apple mit einem Konto (iPad stellt von CloudKit auf G4 um). Ziel 30.000 gleichzeitig nur als Stufenplan. Hochschul-PDFs: Streaming plus optionale Cloud-Ablage (hinter Schalter). Word nur ansehen. Notenspiegel richtig rechnen. Zurückgesetzter Stud.IP-Ausfall bleibt als Termin sichtbar. Learnweb lädt nur aktive Kurse. |
| 28.10. ~09:00 | **Sign in with ChatGPT auf dem iPad**: Lernpläne, Tests, Fragen und Analyse laufen über das ChatGPT-Abo des Nutzers. Laut OpenAI-Bedingungen an **keinen** Studora-Tarif gebunden (auch Free). Studora braucht als bezahlte App die Aufnahme bei OpenAI; er beantragt sie (`docs/KI-CHATGPT-PLAN.md` §4). Bis dahin nur seine eigene Nutzung (Debug/Entwicklung). Für Nutzer ohne ChatGPT will er später eigene OpenAI-/Claude-Schlüssel stellen → **nur über den Server**, nie in der App (Tarif Pro AI, günstiges Modell). |
| 28.10. ~08:30 | Stud.IP-Ausfälle **wie im Stud.IP-Kalender ausblenden** (Woche, Tag, Übersicht), die Zeit wird frei. Gilt gegen die frühere PC-Regel „Ausfall bleibt durchgestrichen“. |
| 28.10. ~03:00 | Name **Studora auf allen Plattformen** (iPad, Windows, Android, Web, Rechtstexte, Demo). |
| 28.10. ~01:10 | V1 auf dem iPad **verkauft nur Free und Plus**; Pro Connect/Pro AI erst mit dem Server. Community **lesen in Free**, schreiben/teilen ab Plus; Melden und Blockieren für alle (Apple 1.2). |
| 27.10. | Stundenplan **1:1 aus dem eigenen Stud.IP-Kalender**, nur aktuelles Semester; persönliche Stud.IP-Einträge (z. B. eine Gruppenübung alle zwei Wochen) bleiben; bei eingetragenen, aber ausgeblendeten Kursen nachfragen. Jedes Fach eigene, änderbare Farbe. Fristen, Kurztests, Testate, Abgaben aus Folien/Übungsblättern erkennen, in den Kalender und als Mitteilung, für beide Hochschulen. Passwörter merkt **nur iOS** (Schlüsselbund/AutoFill), nie die App. Demo-Schalter für die App-Prüfung. Editor-Plan freigegeben: 1 Abnahme+Messung ✅, 2 Härtungen, 3 Drehen ohne Verrutschen, 4 Speicherlast, 5 Seitenwerkzeuge, 6 Objekt-Werkzeuge; Web-Werkzeuge kommen **in** den PencilKit-Editor, kein zweiter Editor. Konto löschen → neu anmelden, nichts vorgespeichert. |
| 25./26.10. | iPad-App V1 **ohne PC/Python-Server** (lokales Backend, Stud.IP direkt), Mit Apple anmelden, erster Start: Apple → Tarif → Hochschule (LUH oder Hildesheim) → sofort deren Anmeldeseiten → erster Abgleich. Strikte Datentrennung je (Apple-Nutzer, Hochschule). LUH-Noten dürfen leer sein (ehrlicher Leerzustand). Hildesheim bekommt dieselben Funktionen wie LUH. |

## 4. Offene Arbeit für die Mac-Sitzung (Reihenfolge)

### A. Fertigstellen und auf develop bringen (vor allem anderen)

Jeden Zweig einzeln: develop einmischen (nicht rebasen), Kern zweimal gegen die Baseline, App zweimal, Python und
Generatoren, Geheimnis-Prüfung, dann als Fast-Forward auf develop.

1. **`wip/stundenplan-ausfall`** prüfen (App-Fehler aus dem Lauf vor dem Merge ansehen). Ziel: `LocalTimetableTests`
   grün, Kalender-Teil im Schema grün. Regeln: Kalender entscheidet ab dem frühesten `fetched_at`, davor der eigene
   Zeitschlitz (mit echten Daten belegt; die PC-Sitzung hat dieselbe Regel in 5dbabd6 übernommen); Ausfälle laut
   Stud.IP nur in der Anzeige ausgeblendet; vom Nutzer gesetzte oder zurückgesetzte Ausnahmen bleiben sichtbar.
   **Bitte an die PC-Sitzung**: Ausfälle in Web/Windows ebenfalls ausblenden (Entscheidung 28.10. ~08:30), danach den
   Vertrag gemeinsam anpassen.
2. **`wip/learnweb-dateien`** fertig testen (Python, Generatoren, App). Ursachen der Lücke 195→539 dokumentieren.
3. **`wip/editor-2`** fertig testen, Gegenproben je Punkt P0-3 bis P0-6 nachweisen.
4. **Notenspiegel** (`wip/notenspiegel`, neu): Swift wie `app/grades_model.py`/`qis.summary`
   (`tests/test_grades_model.py`): Felder aus der Zeile (Nummer, Art, LP), Ebenen Bereich/Modul/Prüfung, Doppelte
   aus der zweiten QIS-Ansicht mit langen Semesternamen entfernen, aktueller Schnitt der bestandenen benoteten Module
   nach LP gewichtet und nach der ersten Nachkommastelle abgeschnitten, dazu der genaue Wert. Endpunkt `/api/grades`
   mit den neuen Feldern; Ansicht mit Bereichen als Chips und Schalter „Module“ / „Alle Prüfungen und Versuche“.
   Für Hildesheim prüfen. Im selben Zweig: Demo-PDFs (`DemoContent.swift`), `sync_ops` im Schema-Test ausnehmen,
   Linux-CI (`XCTExpectFailure` unter `#if canImport(ObjectiveC)` oder gleichwertig; `grep -rn XCTExpectFailure`).
5. **KI über ChatGPT** (`wip/ki-chatgpt`, neu, Vorgabe `docs/KI-CHATGPT-PLAN.md` Phase 3, Python-Vorlage
   `app/chatgpt_login.py`, `app/ai_backend.py`, `app/ai.py`):
   - Kern: Protokoll `AIService`, OAuth mit PKCE bei `auth.openai.com` (`dynamic_agent_client`, ausgestellte
     `oaiapp_…`-ID speichern und wiederverwenden, Scopes `openid profile email offline_access resource.invoke
     chatgpt.tokens.use.direct`, state/nonce, ID-Token gegen JWKS prüfen, Erneuerung 60 s vor Ablauf), Responses API,
     Prompts byte-gleich zu `app/ai.py` (am besten über einen neuen Vertrag `packages/shared-contracts/ai/` aus einem
     Generator, der nur `app/ai.py` importiert), JSON-Prüfung, vier Funktionen (Tutor im Editor, Lernplan-Vorschlag,
     Wochentest mit Bewertung, Analyse). Tests nur mit Mock-Transport, ohne echtes Netz.
   - Rückleitung: `ASWebAuthenticationSession`; OpenAI dokumentiert für native Apps bisher nur Loopback
     `http://127.0.0.1:<port>/auth/callback` → lokalen `NWListener` prüfen; eigenes Schema/Universal Link später nur
     Konfiguration.
   - Token nur im Schlüsselbund des Geräts je Apple-Nutzer; Trennen, Abmelden und Konto löschen löschen ihn.
     Zustimmungsdialog je Funktion (Apple 5.1.2). An keinen Tarif gebunden. **In Release unsichtbar**, solange keine
     von OpenAI vergebene Client-ID in der Konfiguration steht; nur Debug bzw. Einstellungen → Entwicklung.
   - App: Einstellungen → KI (verbinden, trennen, Konto, Modell, Schalter je Funktion, „Nutzung verwalten“),
     Editor-Seitenleiste „KI“, „Plan vorschlagen“, „Test erstellen“, „Analysieren“. Datenschutz-Abschnitt „KI über
     ChatGPT“ als Entwurf. Den echten Test mit seinem ChatGPT macht der Inhaber selbst.
6. **Lese-Auftrag (offen):** aus `docs/uebergabe-mac/` alles heraussuchen, was der **Inhaber selbst** gesagt oder
   gewünscht hat (getrennt von der anderen KI), Widersprüche zu Abschnitt 3 und Lücken gegenüber Abschnitt 6 des
   PRUEFKATALOG melden. Ein Agent hatte beide Texte gelesen, brach aber vor dem Bericht ab.

### B. Echtdaten-Abgleich mit dem Inhaber (nach A1, mit seiner Zustimmung)

Er hat am 28.10. zugestimmt: nach dem Ausfall-Fix die neue Version auf seinem Echtdaten-Simulator installieren.
Vorher den Daten-Container sichern. Er meldet sich selbst neu an (Stud.IP-Anmeldung war abgelaufen; für Hildesheim
CAS). Danach prüfen:
- **LUH:** Woche jetzt, KW 45, KW 47 und Weihnachtswoche gegen seinen Stud.IP-Kalender (Kopie vom 28.10.: KW 47 =
  19/19, KW 45 = 18/18, KW 44 nur eigene Termine; Weihnachten nach dem Ausfall-Fix ohne die 13 ausgefallenen),
  Fristen-Erkennung (Kurztests, Kurzklausuren, Testate, Abgaben), Noten mit neuem Schnitt, Fragekarten
  (ausgeblendeter Kurs, Fragestunden mehrmals pro Woche).
- **Hildesheim:** Learnweb (8 von 9 Kursen sind vom Sommersemester 2026 → werden durch die Semesterregel
  ausgeblendet; nur einer passt zu einer aktuellen LSF-Veranstaltung → Inhaber fragen, ob er in die aktuellen
  Learnweb-Kurse eingeschrieben ist), Dateien gegen PC, LSF (26 Serien, 17 Ausnahmen), Fristen und Ankündigungen
  (beim letzten Abgleich noch 0, weil vor dem Nachzug), Noten.
- Danach die Sicherung des Daten-Containers im Scratchpad löschen.

### C. Übergabe der PC-Sitzung (Abschnitt 6 im PRUEFKATALOG, 23 Punkte) – Einordnung für die Mac-Sitzung

| Nr. | Punkt | Einordnung |
|---|---|---|
| A1 | Apple-CI grün (`XCTExpectFailure` unter Linux) | in A4 oben |
| A2 | Nachzüge vom 28.10. (`UEBERGABE-APPLE-2026-10-28.md`, Ende STAND-MAC-SITZUNG) | Semesterregel, Woche 1:1, Abruftag erledigt (develop); Ausfall-Reset, Learnweb aktiv in A1/A2 oben; Notenspiegel A4 |
| A3 | Release-Signierung (`Config/Team.xcconfig`, Sign in with Apple, CloudKit) | **blockiert**: Developer Program abgelehnt |
| B4 | Anmeldung am Studora-Konto (G1) zusätzlich zu Apple, Vertrag `fixtures/account/contract.json` (E-Mail bestätigen, `rate_limited` mit Retry-After, Datenexport als ZIP) | nach Start, braucht Server |
| B5 | G2-Client in Swift (Spalten, Tombstones, Push/Pull nach `fixtures/sync/cases.json`, seitenweiser Abruf mit `has_more`, `op_id` je Änderung im Journal) | nach Start, braucht Server; Vertrag `docs/VERTRAEGE-KONTO-SYNC.md` G2 lesen |
| B6 | Notizen geräteübergreifend, Zusammenführung je Objekt mit Tombstones | mit PC-Sitzung Vertrag festlegen; iPad hat `localRev`/`acked` und stabile Strich-IDs |
| B7 | Kaufprüfung beim Server (`BillingServiceLink.isEnabled`), dann Pro-Tarife verkaufbar | nach Start, braucht Server und Team |
| C8 | PDF-Text markieren, unterstreichen, durchstreichen (Windows hat es seit 0.4.8) | Editor-Schritt 5/6; Format mit PC (Textanker plus Geometrie) |
| C9 | Formen, Textfelder, Bilder erstellen/bearbeiten | Editor-Schritt 6 (P1-4 bis P1-7) |
| C10 | Eingefügte Bild-/PDF-Seiten wirklich anzeigen | Editor-Schritt 5 (P1-3) |
| C11 | Seiten verschieben | Editor-Schritt 5 (P1-1); dazu Befund M6 (A0-Seite verkleinert alle anderen) |
| C12 | Verankerte Kommentare | mit PC-Format; Community-Kommentare haben `page_key` + `anchor {x,y}` |
| C13 | Handschrift durchsuchen | optional, später |
| C14 | DOCX ansehen (Import aus der Dateien-App) | klein: QuickLook ist da, Import erlauben |
| D15 | Community: Umstellung auf den Dienst (G4: Claims, Likes, Kommentare mit Stelle, Melden, Rangliste nur Admin) | nach Start, braucht Server und G1 |
| D16 | Vorschau vor dem Veröffentlichen beibehalten | da |
| E17 | KI in Release über den Dienst (Pro AI), Quellen mit Seitenangabe (PC 3b12273) | nach Start; vorher KI über ChatGPT (A5) |
| F18 | iPhone | **nicht in V1** (Entscheidung) |
| F19 | Push (APNs), Universal Links (`associated-domains`) | braucht Team |
| F20 | Barrierefreiheit (Dynamic Type über `UIFontMetrics` in `ufFont`, VoiceOver-Labels, reduzierte Bewegung, Linkshänder) | vor dem Start sinnvoll, ohne Server machbar |
| G21 | Gerätetest Apple Pencil (`docs/EDITOR-ABNAHME.md`) | Inhaber, echtes iPad |
| G22 | Echte Anmeldung LUH und Hildesheim, Flugmodus | Abschnitt B oben |
| G23 | App-Store-Einreichung (Texte, Datenschutzangaben, Prüfhinweis mit Demo, Testkonto) | blockiert durch Team |

### D. Editor-Schritte 3 bis 6 (freigegeben, nach A3)

3. Drehen ohne Verrutschen (P0-7, P0-8, mit Web-Gegenstück und gemeinsamer Fixture).
4. Speicherlast (P0-9: Speicherrunde wächst mit dem ganzen Dokument, Befunde M1–M4 aus `EDITOR-MESSUNG.md`;
   P0-10 Zoom-Schärfe nach Gerätetest).
5. Seitenwerkzeuge (P1-1 Umsortieren/Duplizieren/Formate, P1-2 Navigation, P1-3 Asset-Seiten, P1-13 Doku).
6. Objekt-Werkzeuge (P1-4 Werkzeugmodus, P1-5 Textfelder, P1-6 Haftnotizen, P1-7 Objekt-Lasso), danach P1-8, P1-9,
   P1-12.

### E. Weitere offene Punkte der Mac-Sitzung

- `fixtures/solutions/vectors.json` (neu, Testvektoren für das Lösungspaket, „genau wie `SolutionCrypto.swift`“):
  Swift-Test gegen die Vektoren.
- „Designed for iPad“ auf Apple-Silicon-Macs: Einstellungen in `project.yml` prüfen; Test braucht Signierung.
- PC-Bitten offen halten: Studora in Windows/Web/`community.py`/Demo (laut 196555e erledigt, prüfen), `PUT /api/terms`
  wie iPad (569), 500er-Texte kürzen (555), Ausfälle ausblenden (A1).

## 5. Was die Windows-Version kann (0.3.1 bis 0.4.9) – Abgleich mit dem iPad

| Windows | Inhalt | iPad |
|---|---|---|
| 0.3.1–0.3.9 | Daten getrennt vom Programmordner, Einzelinstanz, Sicherungen außerhalb, Links als App-Fenster, Hochschul-Anmeldung als Fenster | entsprechend vorhanden (Container, Anmelde-WebView) |
| 0.4.0–0.4.1 | Sign in with ChatGPT (lokal), KI ohne Konsolenfenster (`claude -p`) | fehlt → A5 |
| 0.4.2 | Hochschul-Konto entfernen, alle Daten löschen | vorhanden („Daten dieser Hochschule löschen“, Konto löschen) |
| 0.4.3 | nur das aktuelle Semester | vorhanden (develop) |
| 0.4.4 | Mittwochs-Termine (Kurs-ID im Schlüssel), ein Kasten je Termin, Timer-Leiste | vorhanden bis auf die Timer-Leiste |
| 0.4.5 | Abruftag nur eigene Gruppen, Fixtures stabil | vorhanden (develop fa65a40) |
| 0.4.6 | zurückgesetzter Ausfall bleibt sichtbar, Learnweb nur aktive Kurse | in A1/A2 |
| 0.4.7 | Studora-Konto, Community im Editor (Leiste „Lösungen anderer“, Projektion als Ebene, Kommentar-Marker, Likes, „Lösung teilen“) | Community über CloudKit; Dienst-Weg später (D15) |
| 0.4.8 | PDF-Text markieren, Word ansehen, Geräte einzeln abmelden | Textmarker fehlt (C8), Word über QuickLook, Geräte ohne Konto entfällt |
| 0.4.9 | Fragen je Kurs, Lesezeichen, Mitteilungen, Barrierefreiheit, Lieferkette (Audits, SBOM) | Fragen/Lesezeichen fehlen (Community), Barrierefreiheit F20 |
| Dienst 28.10. | E-Mail-Bestätigung, Grenzen je IP, Datenexport, Konto endgültig löschen, G2 seitenweise mit `op_id`, Grenzen je Konto und Schonung der Hochschulen (P9), KI-Tutor mit Quellen und Seitenangabe, Notenspiegel | Notenspiegel A4; der Rest braucht Server und G1 |

## 6. Prüf- und Testliste für die Mac-Sitzung

**Automatisch (jede Änderung):** Kern zweimal ohne neue rote Testfälle gegen die Baseline; App zweimal nacheinander
grün; `pytest -q tests`; alle `tools/gen-*.py --check`; Geheimnis-Prüfung vor dem Push.

**Im Simulator (nach A1–A5):**
- Erster Start: Apple-Anmeldung (Debug-Weg), Tarif, Hochschule, Anmeldeseiten, erster Abgleich mit Fortschritt.
- Stundenplan: eigene Woche, Abruftag, Weihnachtswoche, Ausfälle ausgeblendet, zurückgesetzter Ausfall sichtbar,
  Fragekarten, Farben je Fach.
- Notenspiegel: Bereiche, Schalter, Schnitt mit genauem Wert; LUH leer erlaubt.
- Learnweb: nur aktive Kurse, Dateien, Ankündigungen, Fristen; LSF.
- Editor: Härtungen (Dauerschreiben, zwei Fenster, Format neuer als 2), Speichern/Wiederöffnen.
- Tarife: nur Free und Plus kaufbar, Community lesen in Free, Name Studora überall.
- KI: Verbinden-Ablauf mit Mock, Zustimmungsdialog, Fehlerfälle, in Release unsichtbar.
- Konto löschen → neu anmelden ohne vorgespeicherte Sitzungen.

**Nur der Inhaber (echtes Gerät oder Konto):** Apple Pencil nach `docs/EDITOR-ABNAHME.md`; echte Anmeldung LUH und
Hildesheim; Offline im Flugmodus; Sign in with ChatGPT mit seinem Abo; Speicherdruck mit großen PDFs.

## 7. Was nur der Inhaber tun kann

- **Apple Developer Program:** Apple Developer Support kontaktieren (Grund schriftlich, ob eine neue Anmeldung mit
  derselben Apple-ID möglich ist; Name der Apple-ID = amtlicher Name, Zwei-Faktor an). Danach Team-ID →
  `Config/Team.xcconfig`, App Store Connect: App „Studora“, für V1 nur das Plus-Abo `de.uniflow.plus.monthly`.
- **OpenAI:** Konto anlegen und das Formular „Sign in with ChatGPT“ ausfüllen (`docs/KI-CHATGPT-PLAN.md` §4).
- **Server, Domain, Mail-Anbieter, Backup** für Konto, Community und Geräteabgleich (`docs/release/BETRIEB.md`).
- Rechtstexte ausfüllen (Name, Anschrift, Domain) und veröffentlichen.
- In der App entscheiden: ausgeblendete Kurse (z. B. eine Mathe-Veranstaltung) übernehmen oder weglassen,
  Fragestunden wählen.
- Learnweb Hildesheim: Einschreibung in die Kurse des aktuellen Semesters prüfen.
- Die am 25.10. im Chat gezeigten Passwörter ändern.
- Gerätetest mit Apple Pencil.

## 8. Start und Veröffentlichung

- **iPad:** ohne Developer Program kein App Store und kein TestFlight. Testen auf dem eigenen iPad mit kostenloser
  Apple-ID über Xcode (Installation gilt 7 Tage, ohne iCloud/Community, Sign in with Apple und echte Käufe).
- **Windows:** Einzelplatz ab 0.4.x startklar (PC-Sitzung), ohne Code-Signierung und Auto-Update.
- **Konto, Community, Geräteabgleich:** erst wenn Server, Domain und Mail beschafft sind und Dienst und Clients
  nachweislich zusammen funktionieren (zweite Stufe).
