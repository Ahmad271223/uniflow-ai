# Reihenfolge des Abgleichs: zuerst das aktuelle Semester (05.11.2026)

Wunsch des Inhabers (05.11.2026): Wer sich anmeldet, sieht zuerst sein aktuelles Semester samt Stundenplan; fruehere
Semester kommen danach im Hintergrund. Unter Module stehen die Module je Semester, fuer alle Portale.

Dieser Vertrag gilt fuer jeden Adapter (Stud.IP, Moodle/Learnweb, HISinOne/LSF/QIS) auf dem iPad und in Python
(Web, Windows, Dienst). Gemeinsame Teile:

| | Python (Web, Windows, Dienst) | iPad |
|---|---|---|
| Stufen, aktuelles Semester, Fortschritt, Module je Semester | `app/sync_order.py` | `UniFlowCore/Sync/SyncOrder.swift` |
| Wahl "Ältere Semester laden" | `app/older_semesters.py` (`mode`) | `OlderSemesters.Mode` |
| Stufe (d) im Hintergrund | `sync_order.start_older_background` (PC), `run_older_now` (Dienst) | `OlderSemesterLoader` (App, BGTask) |
| Routen | `GET /api/sync-order`, `GET /api/module-semesters`, `POST /api/older-semesters/mode` | dieselben im lokalen Backend |

## 1. Stufen

Jeder volle Abgleich (auch der erste) laeuft in dieser Reihenfolge:

| Stufe | Inhalt | Wann |
|---|---|---|
| (a) `current` | Kursliste, **Stundenplan**, Kurse/Module des aktuellen Semesters mit Dateilisten, Downloads, Ankuendigungen, Terminen, Fristen, Pruefungsterminen | sofort |
| (b) `grades` | Noten (QIS, LSF, HISinOne) | nach (a) |
| (c) `upcoming` | naechstes Semester, falls das Portal es schon zeigt | nach (a), in Python/Stud.IP auch nach (b) des Adapters |
| (d) `older` | fruehere Semester: Dateiliste und Dateien je Kurs | danach im Hintergrund, nie im vollen Lauf |

Regeln fuer Adapter:

1. **Kein Abruf eines frueheren Semesters im vollen Lauf.** Kurse frueherer Semester werden nur als Kurs gespeichert
   (inaktiv, Semesterregel `semesters.is_current`). Dateiliste und Dateien holt nur der Lauf `older_only=True`
   (Python) bzw. `olderOnly: true` (Swift).
2. **Stundenplan vor den Downloads.** Nach der Kursliste: Stundenplan (Stud.IP-Termine/Kalender, LSF-/HISinOne-iCal),
   erst dann Downloads. Ein Fehler im Stundenplan haelt die Dateien nicht an.
3. **Aktuelle Kurse vor naechsten.** Reihenfolge der Kurse: `sync_order.split` / `SyncOrder.stage`
   (aktiv und Semester > aktuelles = `upcoming`, sonst `current`; aus = `older`).
4. **Zwischenstaende sichtbar.** Python: nach der Kursliste, nach dem Stundenplan und je Kurs `conn.commit()`; die
   Oberflaeche sieht das aktuelle Semester waehrend der Lauf weitergeht.
5. **Ende von (a) melden:** `sync_order.mark_current_ready(conn, now)` / `SyncOrder.markCurrentReady(c, now:)` nach
   Stundenplan, Dateien und Ankuendigungen des aktuellen Semesters (vor den Noten).
6. **Noten nach (a).** Python: `sync_order.run_grades_if_due` (hoechstens alle 20 h) nach dem Lauf (sync.py,
   server `_full_sync`); Adapter mit eigenen Noten (HsH: `hsh.sync_grades`) rufen sie nach `mark_current_ready`.
7. **Stufe (d)**: `older_semesters.pending(conn)` bzw. `OlderSemesters.pending` sagt, welche Kurse dran sind;
   **neuestes Semester zuerst** (`sync_order.newest_first` / `SyncOrder.newestFirst`), **je Kurs fertig merken**
   (`older_semesters.finish` / `OlderSemesters.markLoaded`, dann `conn.commit()`), damit ein Abbruch dort weitermacht.
   Zwischen zwei Kursen `if not sync_order.older_continue(): break` (drosselt und haelt an, wenn ein voller Abgleich
   wartet). Keine Termine, kein Stundenplan, keine Noten in (d).

Stand der Adapter (05.11.2026): Stud.IP (Python `run_studip_sync`/`sync_older_files`, iPad `StudIPSync.perform`),
Learnweb und HsH-Moodle (Python `hildesheim.sync_learnweb`, `hildesheim.run_sync`, `hsh.run_sync`; iPad
`HildesheimSync.run`, `HildesheimConnection.loadOlderFiles`, `HsHConnection.loadOlderFiles`) folgen der Regel.
**Neue Adapter und Umbauten** (HsH-Agent, Hildesheim-Agent) halten 1. bis 7. ein und ordnen ihre Schritte wie oben.

## 2. Aktuelles Semester erkennen

`sync_order.current_term(today, terms, university)` / `SyncOrder.currentTerm(today:terms:university:)`:

1. Semesterliste des Portals mit Beginn und Ende: das Semester, das heute laeuft (juengster Beginn gewinnt).
   - Stud.IP: `semesters` aus `include=start-semester,end-semester` der Kursliste (Python: Feld `term` je Kurs,
     `sync_order.portal_terms(courses)`; Swift: `StudIPCourse.semesterTitle`/`semesterStart`).
   - HISinOne/LSF: Semesterwechsel der Seite (LSF-Kennung `20262` = WiSe 2026/27, `sync_order.term_key`).
   - Moodle/Learnweb: Kategorie- bzw. Kursnamen "SoSe 2026", "WiSe 2026/27" (`learnweb.parse_course_title`), die jaehrliche
     Learnweb-Instanz (`learnweb.discover_base`) nennt die Semester im Namen.
2. Sonst das Datum mit den Grenzen der Hochschule (`TERM_STARTS`): LUH und Hildesheim Sommer ab 1.4., Winter ab
   1.10.; HsH Sommer ab 1.3., Winter ab 1.9.
3. Kurse ohne erkennbares Semester gelten als aktuell; noch laufende Kurse des Vorsemesters (Pruefungszeit, Ende
   nach heute) ebenso. Eigene Schalter (`active_custom`) gelten immer.

## 3. "Ältere Semester laden: Automatisch / Nur WLAN / Aus"

Gespeichert im Feld `older_semester_choice.choice` (nur dieses Geraet): `auto`, `wifi`, `off`; fruehere Werte gelten
weiter (`all` = Automatisch, `current` = Aus). Nie gefragt = **Nur WLAN** (Vorgabe).

- Automatisch / Nur WLAN: Stufe (d) holt alle noch nicht geladenen Kurse frueherer Semester.
- Aus: nur, was der Nutzer in der Bibliothek vormerkt ("Dateien laden").
- iPad: Stromsparmodus pausiert, "Nur WLAN" wartet auf ein nicht teures Netz (`NWPath.isExpensive`), im
  Hintergrund nur im langen BGProcessingTask und solange iOS Zeit gibt (`OlderSemesterLoader`).
- Windows/PC: nur solange die App offen ist (eigener Faden nach `_full_sync`); der geplante Lauf `sync.py` laedt
  keine frueheren Semester. "Nur WLAN" wirkt am PC wie Automatisch.
- Dienst: nur Vorgemerktes, im selben Job nach dem vollen Abgleich (`jobs.run_job`).

## 4. Anzeige

`GET /api/sync-order`:

```json
{"current": {"key": [2026, 2], "label": "WiSe 2026/27", "ready": true, "ready_at": "…"},
 "older": {"mode": "wifi", "total": 6, "done": 3, "pending": 3, "running": true, "paused": null},
 "hint": "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (3 von 6)"}
```

`hint`: "Aktuelles Semester wird geladen …" bis (a) fertig; danach der Satz oben, gezaehlt in **Semestern**; pausiert
"… ältere Semester pausiert (Stromsparmodus) (2 von 6)" bzw. "warten auf WLAN"; nichts mehr zu laden: `null`.

`GET /api/module-semesters` (Seite Module, Web `module-semesters.js`, iPad `ModuleSemesters`):

```json
{"current": {"key": [2026, 2], "label": "WiSe 2026/27", "module_ids": [4, 7], "count": 2},
 "upcoming": [{"key": [2027, 1], "label": "SoSe 2027", "module_ids": [9], "items": […], "count": 1, …}],
 "older": [{"key": [2026, 1], "label": "SoSe 2026", "count": 3, "files": 12, "downloaded": 4, "loaded": false,
            "items": [{"name": "Regelungstechnik", "module_id": 5, "color": "#…", "course_ids": ["…"],
                       "courses": 2, "files": 6, "downloaded": 4, "loaded": false}]}],
 "status": { … wie /api/sync-order … }}
```

Fruehere Semester neuestes zuerst; je Semester echte Module (inaktiv) und erkannte Faecher aus Kursen ohne Modul
(`courses.subject`, wie beim Abgleich klassifiziert; `module_id: null` oeffnet den Kursordner `c<Kurs-ID>`).
Dateien bleiben an Kurs und Modul. Adapter muessen dafuer nur `courses.semester` (Startsemester-Titel),
`semester_end`/`semester_ends_at` und `subject` richtig fuellen.

## 5. Tests

- Python: `tests/test_sync_order.py` (Stud.IP-Stub mit 7 Semestern: kein frueheres Semester vor (a), Stundenplan vor
  den Downloads, (d) neuestes zuerst und fortsetzbar, Wahl, Module je Semester, Semestererkennung).
- Kern: `SyncOrderTests` (Learnweb-/LSF-Stub mit 7 Semestern, Stufen, Wahl, Semestererkennung).
- App: `SyncOrderAppTests` (Stud.IP-Stub mit 7 Semestern, Stufe (d) mit Pause, Seite Module).
- Web: `tests/js/module-semesters.test.mjs`, `tests/js/older-semesters.test.mjs`.
