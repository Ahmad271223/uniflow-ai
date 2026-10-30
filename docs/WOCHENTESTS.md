# Wochentests mit Vorlesungs-Seitenmarker

Stand: 29.10.2026 · Code: `app/weekly.py`, Oberfläche: `app/static/views-weekly.js` · Tests: `tests/test_weekly.py`

## Idee

Die Dateien aus Stud.IP sind die Wissensbibliothek. Daraus werden nicht pauschal tausende Aufgaben erzeugt. Stattdessen
stellt die App pro Modul und Lehrwoche **einen** gemeinsamen Wochentest zusammen, und zwar nur aus dem Stoff, der in
der Vorlesung wirklich schon behandelt wurde.

Das Herzstück ist der **Seitenmarker „Vorlesung bis hier“**. Ohne ihn könnte die KI bei einem Skript mit 120 Folien
Inhalte abfragen, die erst Wochen später drankommen.

## Ablauf

1. **Marker setzen.** Im Dokument-Kopf auf „Vorlesung bis hier“ tippen. Der Dialog zeigt:
   - den Vorlesungstermin (aus dem Stundenplan, änderbar),
   - den erfassten Seitenbereich (neu seit dem letzten Marker),
   - das Thema (aus den Folienüberschriften vorgeschlagen),
   - den voraussichtlichen Wochentest-Termin.

   Liegt auf der Seite schon ein Marker, wird dieser bearbeitet. Marker lassen sich verschieben, löschen und
   ausdrücklich für den Kurs freigeben. In den Seitenminiaturen sind sie mit „bis hier“ gekennzeichnet.
2. **Stoffumfang.** Aus allen Markern eines Moduls entsteht je Lehrwoche:
   - der **neue Stoff** (Seiten seit dem vorherigen Marker),
   - das **Vorwissen** (frühere Wochen).

   Vorlesungsdokumente ohne Marker gelten als *nicht behandelt*.
3. **Aufgabenindex.** Übungsblätter, Hörsaal- und Gruppenübungen, Zusatzaufgaben, Musterlösungen und Altklausuren
   werden in einzelne Aufgaben zerlegt (Überschrift „Aufgabe N“). Jede Aufgabe wird per Inhaltsabgleich (BM25) den
   Vorlesungsseiten zugeordnet, nicht über den Dateinamen. Die Zuordnung wird je Dateiversion zwischengespeichert, neu
   analysiert wird nur, was sich geändert hat.
4. **Zulässigkeit.** Eine Aufgabe kommt nur in Frage, wenn **alle** stark passenden Vorlesungsseiten (≥ 60 % des besten
   Treffers) behandelt sind. Ohne sicheren Bezug wird ausgeschlossen. Fast identische Folien aus einem anderen Semester
   (Token-Ähnlichkeit ≥ 0,8 zu einer behandelten Seite) blockieren nicht.
5. **Zeitplan.** Veröffentlichung 24 h nach Vorlesungsende laut Stundenplan. Einstellbar: 5, 24 oder 48 h.
   - Sind im Modul Übungen als *erwartet* eingetragen und fehlen sie, wartet der Test höchstens 48 h länger.
   - Danach erscheint er mit dem vorhandenen Material, und die fehlenden Quellen werden gekennzeichnet.
   - Ohne Eintrag wird nicht gewartet. Die App erfindet keine erwarteten Dateien.
6. **Erzeugung und Prüfung.**
   - Die KI erstellt einen Entwurf mit 15 Aufgaben: 4–5 kurze, der Rest mittel bis schwer, 1–2 angelehnte
     Altklausuraufgaben, wenn passende vorhanden sind.
   - Danach prüfen feste Regeln: Anzahl, Bezüge nur auf freigegebenes Material, Lösung nicht in der Aufgabenstellung,
     Abdeckung des neuen Stoffs, Abstand zu Originalklausuren.
   - Anschließend kommt eine KI-Fachprüfung, höchstens eine Reparaturrunde ist erlaubt. Nicht bestandene Entwürfe
     werden **nie** veröffentlicht.
7. **Gemeinsamer Test.** Derselbe Stoffumfang ergibt denselben `scope_key` und damit dieselbe Testversion für alle.
   Veröffentlichte Versionen sind per SQLite-Trigger unveränderlich und nicht löschbar.
   - Multiple Choice wird ohne KI und für alle gleich bewertet.
   - Die Rangliste läuft je Testversion und je Modul/Woche. Nachträge zählen nicht.
8. **Nachtrag.** Kommen nach der Veröffentlichung neue passende Aufgaben hinzu, entsteht ein gemeinsamer Nachtrag mit
   2–5 Aufgaben. Der ursprüngliche Test und bereits abgegebene Versuche bleiben unverändert.
9. **Probeklausur.** Getrennt vom Wochentest und nur auf Anfrage. Sie übernimmt Aufbau, Aufgabenzahl, Punkte und
   Bearbeitungszeit aus den Altklausuren des Moduls und nutzt den gesamten bisher markierten Stoff.
   - Die Abschlussprobeklausur geht erst, wenn alle Vorlesungsskripte bis zur letzten Seite markiert sind.

## Stoffumfang: persönlich und Kurs

- Persönliche Marker gelten für den jeweiligen Studenten.
- Kursmarker entstehen nur durch ausdrückliche Freigabe (`POST /api/markers/{id}/release` mit `confirm: true`).
- Sobald ein Modul Kursmarker hat, richtet sich der gemeinsame Test danach.
- Persönliche Zusatztests bleiben unabhängig.

> Die App ist heute eine Einzelplatz-Installation ohne Konten. Die Tabellen tragen eine `user_id` (Standard `local`),
> damit Kursmarker, gemeinsame Tests und Ranglisten mit Konten ohne Umbau funktionieren. Heute gibt es nur einen
> Teilnehmer.

## Dokumentänderungen

- Marker speichern die Dokumentversion und einen Fingerabdruck des Seitentexts.
- Ändert sich die PDF (z. B. eine neue Titelseite), wird die markierte Seite über den Fingerabdruck wiedergefunden und
  der Marker verschoben.
- Ist die Seite nicht eindeutig auffindbar, wird der Marker zur Prüfung markiert. Bis dahin zählt der Stoff dieser
  Datei ab dort nicht.
- Im Editor eingefügte oder gelöschte Notizseiten ändern die PDF-Seitennummer nicht.

## Einstellungen

| Wo | Schlüssel | Standard |
| --- | --- | --- |
| Modul → Lernfortschritt & Wochentests → Zahnrad | Veröffentlichung nach Vorlesungsende (`weekly_publish_hours`) | 24 h |
| | erwartete Übungen (`modules.expected_materials`) | keine |
| | Altklausuren: angelehnt / Original erlaubt (`modules.exam_reuse`) | angelehnt |
| `settings` | `weekly_max_delay_hours` | 48 |
| `settings` | `weekly_ai_daily_limit` (Kostenbremse: neue KI-Tests pro Tag) | 8 |
| `settings` | `weekly_questions` | 15 |

## API

| Methode | Pfad | Zweck |
| --- | --- | --- |
| GET | `/api/markers?file_id=…&module_id=…` | Marker (prüft vorher Dokumentänderungen) |
| GET | `/api/markers/preview?file_id=…&page=…[&lecture_date=…]` | Daten für den Dialog |
| POST | `/api/markers` | `{file_id, page, page_key?, lecture_date?, topic?}` |
| PATCH | `/api/markers/{id}` | Seite, Termin oder Thema ändern |
| DELETE | `/api/markers/{id}` | löschen (veröffentlichte Tests bleiben) |
| POST | `/api/markers/{id}/release` | `{confirm: true}` als Kursmarker freigeben |
| GET | `/api/weekly/module/{id}` | „Lernfortschritt & Wochentests“ |
| GET | `/api/weekly/defs/{id}` | Testdetails inkl. Quellen und Rangliste |
| POST | `/api/weekly/defs/{id}/attempt` | Bearbeitungsversuch anlegen |
| GET | `/api/weekly/ranking?module_id=…[&week_no=…]` | Rangliste nach Modul/Woche |
| POST | `/api/weekly/tick` | Durchlauf jetzt starten (läuft sonst alle 10 min und nach jedem Sync) |
| POST | `/api/weekly/mock-exam` | `{module_id, full?}` Probeklausur |

## Datenmodell

- `lecture_markers`: Marker mit Benutzer, Modul, Dokument, Dokumentversion, Seite, Seitenschlüssel, Fingerabdruck,
  Vorlesungstermin und -ende, Kalenderwoche, Lehrwoche, Thema, Geltungsbereich, Prüf-Hinweis und Zeitstempeln.
- `doc_index`, `task_index`: Aufgabenindex je Dateiversion.
- `wt_plans`: ein Plan je Modul, Lehrwoche und Stoffumfang (eindeutig), mit Zeitplan, Status, fehlenden Quellen und
  Sperre gegen parallele Läufe.
- `wt_defs`: versionierte Testdefinitionen (Wochentest, Nachtrag, Probeklausur) mit Quellen und Prüfprotokoll.
  Veröffentlicht heißt unveränderlich.
- `tests`: Bearbeitungsversuche, neu mit `def_id`, `user_id` und `duration_sec`. Pro Version und Person gibt es einen
  Versuch.

## iPad (ohne PC)

- **Kern:** `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Weekly/` ist eine Swift-Fassung von
  `app/weekly.py` mit denselben Endpunkten (`WeeklyEndpoints.swift`). Die Fixture
  `packages/shared-contracts/fixtures/local-backend/weekly.json` (`tools/gen-weekly-fixture.py`) spielt den ganzen
  Ablauf nach: Marker, Zeitplan, KI-Aufrufe mit byte-gleichen Prompts, Veröffentlichung, Nachtrag, Probeklausur und die
  Tabellen am Ende. `PATCH /api/modules/{id}` nimmt wie am PC `expected_materials` und `exam_reuse` an
  (Fixture `study-modules.json`).
- **Oberfläche** (`apps/apple/UniFlow/Views/Modules/WeeklyViews.swift`, wie `app/static/views-weekly.js`):
  - Knopf „Vorlesung bis hier“ in der Leiste des Dokuments, mit Dialog: Vorschau, Termin, Thema, eigene Marker mit
    Springen, Verschieben, Freigeben und Löschen.
  - Kennzeichen „bis hier“ an den Miniaturen.
  - Box „Lernfortschritt & Wochentests“ auf der Modulseite mit Testdetails, Rangliste, Einstellungen und Probeklausur.
  - Lokal erscheinen Box und Knopf nur mit verbundenem ChatGPT-Abo, wie die Wochentest-Felder im Modul-Dialog. Am
    PC-Server erscheinen sie immer.
- **Takt:** `WeeklyAutoTick` (Kern) und `WeeklyAutoTicker` (App) laufen 20 s nach dem Öffnen und danach alle 10 min,
  solange die App im Vordergrund ist. Bedingungen: `auto_tests` ist an, die KI ist verbunden, und kein anderer
  Hintergrundauftrag läuft. Ohne KI gibt es keinen Lauf, damit fällige Pläne ihre drei Versuche nicht verbrauchen. Im
  Hintergrund läuft auf dem iPad kein Takt, der nächste Lauf folgt beim Öffnen.
- **Hintergrundlauf (gebaut in der Cloud am 30.10., auf dem Mac ungeprüft):** Bei geschlossener App läuft der Takt zu
  den Zeiten des Hintergrundabgleichs (8, 15, 20 Uhr) im langen Hintergrundlauf (`BGProcessingTask`), nie im kurzen.
  - Entscheidung als reine Logik in Python (`weekly.background_snapshot`, `weekly.background_decision`,
    `slot_at_or_after`, `next_slot`) und im Swift-Kern (`WeeklyBackground.snapshot`/`decide`; für die App
    `WeeklyBackground.decision(ctx)` mit `next_at` als `Date` über `BerlinClock.utcSeconds`), gegen dieselben Prüfdaten
    (`weekly.json`, Schritte `background` und `background_cases`). Sie sagt, ob ein Lauf etwas täte (`run`, `idle`,
    `limit`, `off`, `no_ai`, `busy`), welche Pläne fällig sind und wann der nächste Termin nötig ist (`next_at`).
  - App (`BackgroundSyncController.performRun`): im langen Lauf nach dem Abgleich, auch wenn der ausfiel (Sitzung
    abgelaufen, „Im Hintergrund abgleichen“ aus), bei `run` der Takt `WeeklyAutoTick.run`; nicht ohne passenden
    Container, nicht während eines Wechsels, nicht neben einem laufenden Abgleich. Hat er etwas veröffentlicht, laden
    offene Boxen neu, und mit dem Schalter „Benachrichtigen“ kommt „Neuer Wochentest verfügbar“ (ohne Fach, ohne
    Inhalt, eigene Kennung in der Gruppe des Containers).
  - Termin (`schedule`): der lange Lauf wird auch mit ausgeschaltetem Abgleich bestellt, wenn `next_at` gesetzt ist
    und die KI verbunden ist (der kurze dann abbestellt); eingeschaltet ist sein frühester Beginn der frühere von
    `BackgroundSchedule.next` und `next_at`.
  - Abbruch durch iOS (`BackgroundTaskRun.expire` → `Task.cancel`) kostet keinen Versuch: `Weekly.processPlan` löst
    nur die Sperre, Status und `attempts` bleiben, `Weekly.ask` stellt keine Anfrage mehr, `WeeklyAutoTick.run`
    liefert `.cancelled`. Python kennt keinen Abbruch; die Prüfdaten sind unverändert.
  - Nach jedem vollen Abgleich (Stud.IP und Hildesheim, `StudIPSync.autoPlan`) läuft der Takt wie `_full_sync` am PC,
    nicht nach dem kurzen Hintergrundlauf mit Listen.
  - Geprüft: Kern-Tests (Abbruch durch `CancellationError`, `URLError.cancelled` und `Task.cancel` mitten in der
    KI-Anfrage; Entscheidung und Termin für die App). Die App-Tests (`BackgroundSyncAppTests`, `WeeklyAppTests`)
    sind geschrieben, aber ohne Xcode nicht gelaufen; Syntax der App-Dateien mit `swiftc -parse` geprüft. Wann iOS
    den Lauf wirklich startet, zeigt nur das Gerät über Tage.

## Grenzen (ehrlich)

- Die Zuordnung arbeitet auf der Textebene der PDFs. Gescannte oder handschriftliche Seiten und Abbildungen werden
  nicht ausgewertet. Es gibt keine Texterkennung.
- Aufgaben werden über Überschriften wie „Aufgabe 3“ erkannt. Blätter ohne solche Überschriften werden seitenweise
  zerlegt.
- Die KI-Fachprüfung ist eine zweite KI-Meinung und kein menschliches Lektorat. Bei Rechenaufgaben bleibt ein
  Restrisiko.
- Die Tests verwenden eine simulierte KI. Ein Durchlauf mit echtem `claude -p` und echten Stud.IP-Dateien steht noch
  aus.
