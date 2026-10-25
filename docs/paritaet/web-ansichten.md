<!-- Bestandsaufnahme Web-Ansichten, erstellt 25.10.2026 aus dem Quelltext (Stand develop). Teil von WEB-IPAD-PARITAET.md. -->
# UI-Inventar UniFlow AI (Frontend, ohne editor.js-Interna)

**Dateien.** Alle liegen unter `app/static/`. In den Tabellen kürze ich sie als `datei.js:Zeile` ab:
- `app/static/index.html`
- `app/static/app.js`
- `app/static/core.js`
- `app/static/views-misc.js`
- `app/static/views-plan.js`
- `app/static/views-tt.js`
- `app/static/views-lib.js`
- `app/static/views-doc.js`
- `app/static/style.css`
- `app/static/icons.js`
- `app/static/manifest.webmanifest`
- Backend-Routen zum Abgleich: `app/server.py`

**Konventionen.**
- Die Dateien sind minifiziert. Eine „Zeile“ ist deshalb oft eine ganze Funktion.
- Jeder API-Pfad bekommt in `api()` den Präfix `/api` (core.js:15–19). In den Tabellen steht der Pfad ohne `/api`.
- Fehlermeldungen kommen aus `detail` der JSON-Antwort und werden als `Error` geworfen.
- Ich habe jeden Frontend-Aufruf gegen die Routen in `server.py` geprüft. Zu allen Aufrufen gibt es eine Backend-Route.

---

## A) Routentabelle

Router: app.js:58–75. Er hört auf `hashchange`. `location.hash` wird zerlegt in `name/teil1/...?query`. Ein leerer oder unbekannter Name führt zu `viewDashboard`.

| Hash-Route | Query-Parameter | View-Funktion | Datei |
|---|---|---|---|
| `#/` · `#/dashboard` · unbekannt | – | `viewDashboard` | app.js:78 |
| `#/plan` | `view=day/|3days/|week/|month/|list` (Standard: week), `date=YYYY-MM-DD`, `module=<id>` (Filter). Werte bleiben in `planState` über Navigationen hinweg erhalten | `viewPlan` | views-plan.js:8 |
| `#/tasks` | wie plan, `view` ist fest `list` | Lambda → `viewPlan(p,{...q,view:"list"})` | app.js:58 |
| `#/timetable` | `date=` (Woche, die das Datum enthält) | `viewTimetable` | views-tt.js:6 |
| `#/modules` | – | `viewModules` | views-misc.js:19 |
| `#/modules/:id` | – | `viewModules` → `viewModule(id)` | views-misc.js:20/27 |
| `#/files` | `section=docs/|fav/|recent/|new/|trash` (Standard: docs; `new=…` wirkt wie section=new), `path=m<id>` · `m<id>/<doc_type>` · `m<id>/f<id>` · `f<id>/f<id>…`, `q=` Suche | `viewFiles` | views-lib.js:13 |
| `#/doc/:id` | `task=<taskId>` (zeigt „Erledigt“-Button), `page=<n>` | `viewDoc` | views-doc.js:12 |
| `#/exams` | – | `viewExams` | views-misc.js:68 |
| `#/exams/:id` | `task=<taskId>` (Zurück führt zu #/plan; nach Abgabe wird die Aufgabe erledigt gesetzt) | `viewExams` → `runTest` | views-misc.js:69/92 |
| `#/cards` | – | `viewCards` (Karteikarten, kein Sidebar-Eintrag) | views-misc.js:114 |
| `#/services` | – | `viewServices` | views-misc.js:151 |
| `#/community` | – | `viewCommunity` | views-misc.js:180 |
| `#/settings` | `tab=modules/|plan/|account/|advanced/|diag` (`diag` öffnet advanced; Standard: modules) | `viewSettings` | views-misc.js:192 |

**Was der Router bei jedem Wechsel tut** (app.js:59–74):
1. Markiert den aktiven Eintrag über `[data-route]`. Bei `doc` wird „files“ markiert.
2. Schließt die mobile Sidebar, das Backdrop `#sideBd`, den Drawer und alle Modals.
3. Entfernt die Body-Klassen `exam-focus`, `fullscreen-doc` und `doc-open`.
4. Zerstört alle Editoren und sichert vorher deren Zustand in `docTabs.state[tabId]`.
5. Zeigt ein Skeleton: Balken mit 40 % Breite, darunter 3 Kacheln à 120 px.
6. Fehler:
   - „Offline“-Karte, wenn die Meldung auf Failed to fetch, NetworkError oder Load failed passt. Inhalt: „Server nicht erreichbar“, Erklärtext zu serve.py, Buttons „Jetzt neu laden“ (`location.reload`) und „Diagnose“ (→ `#/settings?tab=diag`). Der Router prüft alle 3 s per `GET /bg` und lädt die Route bei Erfolg neu.
   - Sonst eine Karte „Fehler“ mit der Meldung.
7. Scrollt nach oben, außer bei `doc`.

---

## B) Views, Sub-Views und Dialoge

### B.0 Gemeinsame Bausteine (core.js)

| Baustein | Verhalten | Datei:Zeile |
|---|---|---|
| `api(path, opts)` | fetch `/api…`; JSON-Body oder FormData; wirft bei !ok `detail`/statusText | core.js:15 |
| `toast(msg, ms=2600)` | ein `#toastEl` unten mittig, wird überschrieben, blendet nach ms aus | core.js:32 |
| `modal(html,{wide})` | `.modal` im `#overlay`; Klick auf die Abdunkelung schließt; `[data-close]` schließt; wide = 900 px | core.js:33 |
| `drawer(html)` | rechter Drawer `#drawerEl` plus Backdrop `#drawerBd`; Backdrop-Klick und `[data-close]` schließen; immer nur einer offen | core.js:34–35 |
| `statusPill(st)` | Pill `.st-<status>` mit Icon und Text: Geplant, In Bearbeitung, Erledigt, Teilweise erledigt, Nachholen, Verschoben, Übersprungen, Frei, Nichts geplant | core.js:9–10, 36 |
| `diffBadge(d)` | „Stufe N“: ok bei ≤2, bad bei ≥4, sonst warn | core.js:37 |
| `typeBadge(t)` | neutrale Badge mit Dokumenttyp | core.js:38 |
| `initial()`/`shortName()` | Modul-Initialen und Kurznamen (z. B. Mathematik für die Ingenieurwissenschaften → Mathematik) | core.js:39–40 |
| Icons | `icon(name,size)`: Lucide-Stil, 24×24, stroke 2, round; unbekannter Name → `file` | icons.js:71 |

### B.1 Übersicht (Dashboard), app.js:78–109

API: `GET /dashboard`.

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Begrüßung | „Guten Morgen“ (<11 Uhr), „Guten Tag“ (<18 Uhr), sonst „Guten Abend“. Datumszeile: Wochentag, Datum · „heute N Lernpaket(e)“ oder „heute ist nichts geplant“ · „N Uni-Termine“ | – | app.js:80, 87 |
| Button „Tagesansicht“ | Link `#/plan?view=day&date=<heute>` | – | app.js:88 |
| Button „Weiterlernen“ (primary) | nur bei offener Aufgabe; führt zu `#/doc/<file>?task=<id>`, ohne Datei zur Tagesansicht | – | app.js:85, 88 |
| KPI 1 | geplante Minuten heute, dazu „· X frei“ | – | app.js:89 |
| KPI 2 | „erledigt / gesamt“, „Aufgaben erledigt“, grüner Fortschrittsbalken | – | app.js:89 |
| KPI 3 | Anzahl „nachzuholen“; bei >0 roter Rahmen und roter Wert, dazu Link „neu planen“ (`#rescueBtn`) → `suggestFlow({rescue:true})` | `POST /calendar/suggest` | app.js:89, 106 |
| Karte „Heute für dich geplant“ | pro Paket eine `.pkg-card` (linker Rand in Modulfarbe): Punkt, Fach, Uhrzeit, Minuten, Titel, Status-Pill. Darunter die Aufgaben mit Icon, Titel (erledigt durchgestrichen), Minuten und Link „öffnen“ (`#/doc/<file>?task=`). Fortschrittsbalken | – | app.js:92–95 |
| Button „Lernpaket öffnen“ (`data-pkg`) | öffnet den Lernpaket-Drawer (B.2.10) | `GET /packages/:id` | app.js:95, 104 |
| Leerzustand | Kalender-Icon, „Für heute ist nichts geplant.“ und Button „Lernplan erstellen“ (`#genTodayBtn`) → `generatePlan(heute)` | `GET /calendar/feasibility` | app.js:96, 107 |
| Karte „Heute an der Uni“ (nur bei Terminen) | Link „Stundenplan“; Zeilen mit Punkt, Zeit, Titel (durchgestrichen, wenn keine Teilnahme) und Raum (max. 22 Zeichen). Klick öffnet den Termin-Drawer | `GET /timetable/events`, `/timetable/day`, `/timetable/event-materials/:id` | app.js:97, 105 |
| Karte „Nächste Termine“ | bis zu 6 Einträge; Link zur Tagesansicht, zum Modul oder zu `#/plan`; Unterzeile „Datum · Klausur/Wochentest/Lernpaket“. Leer: „Keine Termine.“ | – | app.js:100 |
| Karte „Diese Woche“ | „done/total“, Fortschrittsbalken, `.week-strip` mit 7 Tagen (Kürzel, Statuspunkt `.sd`, Minuten oder „–“); heute umrandet; Klick → Tagesansicht | – | app.js:101 |
| Karte „Neu aus Stud.IP“ | Gesamtzahl; bis zu 4 Module mit „N neue Datei(en) · Titel …“ und Badge (Link `#/files?section=new`); Link „Alle anzeigen“. Leer: „Nichts Neues.“ | – | app.js:102 |
| Button „Gesehen“ (`#markSeenBtn`) | markiert alle neuen Dateien als gesehen und lädt die Route neu | `POST /files/mark-seen` | app.js:108 |

### B.2 Lernkalender (`#/plan`), views-plan.js

API beim Laden: `GET /calendar?start&end`, `GET /tasks/open`, `GET /modules`. Außer in der Monatsansicht zusätzlich `GET /calendar` für den ganzen Monat (für den Mini-Kalender). Woche und 3 Tage laden außerdem `GET /timetable/week?start=` für freie Fenster (freeMap, views-plan.js:61). Die Tagesansicht ruft `GET /timetable/day?date=` zweimal auf.

#### B.2.1 Kopf, Nachhol-Banner, Toolbar

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Titel | „Lernkalender“, Unterzeile „Dein Wochenplan – perfekt auf Vorlesungen, Übungen und Tests abgestimmt.“ | – | :24 |
| „+ Lernpaket“ (`#addPkgBtn`) | Dialog „Neues Lernpaket“ (B.2.15); Datum: Tag oder Wochenstart | `GET /modules` | :25, 47 |
| „Lernkombination“ (`#cfgBtn`) | Dialog „Lernkombination“ (B.2.17) | `GET /settings` | :25, 47 |
| „Woche retten“ (`#rescueBtn`) | ohne Rückstand deaktiviert (Tooltip „Nichts nachzuholen“); sonst `suggestFlow({rescue:true})` | `POST /calendar/suggest` | :25, 48 |
| „Plan erstellen“ (primary, `#genBtn`) | Dialog „Lernplan erstellen“; Startdatum: Wochenanfang in der Wochenansicht, sonst der Tag | `GET /calendar/feasibility` | :25, 46 |
| Nachhol-Banner (rot, nur bei Rückstand) | „N Aufgabe(n) müssen nachgeholt werden“ | – | :26 |
| · „Jetzt nachholen“ (`#catchNow`) | wechselt in die Listenansicht | – | :49 |
| · „Neu einplanen“ (primary, `#catchPlan`) | `suggestFlow({})` | `POST /calendar/suggest` | :49 |
| · „Bewusst überspringen“ (ghost, `#catchSkip`) | Browser-`confirm` „N offene Aufgaben als bewusst übersprungen markieren?“, danach Toast „Übersprungen“ | `POST /tasks/skip {task_ids}` | :50 |
| Segment (Pill) | Tag, 3 Tage, Woche, Monat, „Liste“ (mit Icon); `data-view` setzt den Hash | – | :28, 41 |
| ‹ / › (`#prevBtn`/`#nextBtn`) | Monat ±1, Woche ±7, 3 Tage ±3, Tag/Liste ±1 | – | :29, 42–43 |
| Zeitraum-Titel | Kalender-Icon und Label (Zeitraum, „Monat Jahr“ oder langes Tagesdatum) | – | :19, 29 |
| „Heute“ (`#todayBtn`) | springt zu heute | – | :30, 43 |
| Select „Alle Module“ (`#modSel`) | Modulfilter, setzt `module=` im Hash | – | :30, 45 |
| Zahnrad (`#cfgBtn2`) | Lernkombination | – | :30, 47 |
| `panel-right` (`#sideBtn`, nur Woche/3 Tage) | blendet die Seitenspalte ein/aus (`.side-off`); gespeichert in localStorage `cal-side`; Standard: aus bei Fensterbreite <1400 px | – | :30, 44, 60 |

#### B.2.2 Wochen- und 3-Tage-Raster (`weekGrid`, views-plan.js:84–99)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Tageskopf `.cal2-dh` | Wochentag, „T.M.“, Fortschrittsring (Farbe nach Status: nachholen rot, erledigt grün, teilweise orange, sonst accent), dazu Minuten, „Frei“, „Nichts geplant“ oder kompakt „–“. Klick → Tagesansicht | – | :70–75, 104 |
| Zeitachse | 60 px pro Stunde; mindestens 08:00–19:00, wird durch Termine erweitert | – | :55–56, 95 |
| Freie Fenster `.cal2-free` | grün schraffiert, Tooltip „Frei hh:mm–hh:mm“ | (`/timetable/week`) | :91 |
| Uni-Termin `.cal2-ev` | Farbe des Termins, Uhrzeit, Name (kompakt/parallel: TINY-Kürzel wie „Mathe I“, „ET“, „DSA“, „Ü …“), Raum ab Höhe >54 px. `off` (nicht besucht) blass und durchgestrichen. Parallele Termine liegen in Spuren nebeneinander; `.narrow` ab 3 Spuren. Klick → Termin-Drawer | Termin-Drawer-APIs | :58–59, 63–69, 76–79, 107 |
| Lernblock `.cal2-ev.study` | gestrichelter Info-Rahmen, Buch-Icon, Uhrzeit, Fach, Titel (ab >54 px), Fuß mit Status-Pill und Checkbox (ab >88 px, nicht kompakt). Klick → Lernpaket-Drawer | `GET /packages/:id` | :80–83, 101 |
| Checkbox `[data-pkgdone]` | setzt alle Aufgaben des Pakets auf erledigt bzw. zurück auf geplant; Toast „Lernpaket erledigt ✓“ oder „Wieder offen“ | `GET /packages/:id`, je Aufgabe `POST /tasks/:id/status` | :102 |
| Jetzt-Linie `.cal2-now` | nur heute | – | :92 |
| „+“-Button `.cal2-add` (nur Spalte heute) | „Lernpaket hinzufügen“ | `GET /modules` | :92, 105 |
| **Drag & Drop** | Pakete (`.pkg`, `.tt-ev`, `.cal2-ev`, `.day2-ev` mit `data-pkg`) sind ziehbar (`.dragging`). Drop auf `.cal2-col` oder `.cal-day` (Hervorhebung `.drop`) ändert nur das Datum; Toast „Verschoben“ | `PATCH /packages/:id {date}` | :101, 103 |
| Legende | Uni-Termin, Lernblock, Freie Zeit, nicht besucht | – | :97 |
| Karte „N Lernpaket(e) ohne Uhrzeit“ | Button „Uhrzeiten vergeben“ (`#reslotWeek`), Toast „Uhrzeiten vergeben“; darunter die Paket-Boxen (klick- und ziehbar) | `POST /timetable/reslot {}` | :98, 106 |
| Kompaktmodus | 7 Tage bei Fensterbreite <1500 px: Kurznamen, nur Startzeit, kein Fuß | – | :86 |

#### B.2.3 Monatsansicht (views-plan.js:35)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Raster `.cal-month` | Kopfzeile Mo–So; 6 Wochen; Tage anderer Monate blass (`.other`); heute mit Akzentrahmen | – | :35 |
| Tageszelle `.md` | Statuspunkt, Tageszahl, Farbbalken je Paket (Tooltip: Fach), Minuten. Klick → Tagesansicht | – | :35, 104 |
| Drop-Ziel | Monatszellen sind **kein** Drop-Ziel | – | :103 |

#### B.2.4 Tagesansicht (`dayTimeline`, views-plan.js:142–153; `bindDayExtras` :164)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Zeitachse | 72 px pro Stunde; mindestens 07:00–20:00, erweiterbar | `GET /timetable/day?date` (ggf. `GET /calendar`) | :143–145 |
| Freie Fenster `.day2-free` | schraffiert, Tooltip „Frei: …“ | – | :146 |
| Termin `.day2-ev` | Icon nach Art, Titel, Zeit, Raum, „nicht besucht“ oder „fällt aus“; Art-Badge, Modul-Badge. Klick → Termin-Drawer | s. B.3.2 | :147, 107 |
| Lernpaket `.day2-ev.study` | „Fach – Titel“, Zeit, Minuten, „x/y erledigt“, Badge „Lernpaket“, Status-Pill. Klick → Drawer; ziehbar (es gibt aber nur eine Spalte) | `GET /packages/:id` | :148 |
| Sperrzeit `.tt-blocked` | Titel oder „Sperrzeit“ | – | :149 |
| Jetzt-Linie | nur heute | – | :151 |
| „N Lernpaket(e) ohne Uhrzeit“ | Link-Button „Uhrzeiten vergeben“ (`#reslotBtn`) | `POST /timetable/reslot {dates:[date]}` | :152, 165 |

#### B.2.5 Listenansicht (`tasksListHtml`, views-plan.js:283–287)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Gruppen | „Nachholen“ (rote Badge), „Heute“ (info), „Demnächst“ (neutral) mit Anzahl; je Aufgabe eine Kopfzeile (Punkt, Fach, Datum) und eine Aufgabenzeile (B.2.8) | `GET /tasks/open` | :283–286 |
| Leerzustand | Häkchen-Icon, „Keine offenen Aufgaben.“ | – | :286 |

#### B.2.6 Seitenspalte Woche/3 Tage/Monat/Liste (`weekSide`, views-plan.js:123–132; `bindSide` :133–139)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| „Mein Fortschritt“ | Donut: Erledigt (ok), Geplant (info), Nachholen (bad), Uni-Termine (nur wenn >0); Mitte „done / total Aufgaben“ | – | :112–116, 128 |
| „Nicht erledigt“ | Badge mit Anzahl; bis zu 4 Einträge (Warn-Icon, Fach, Titel, Chevron). Klick → Lernpaket-Drawer. Leer: „Alles erledigt – nichts nachzuholen.“ | `GET /packages/:id` | :129, 134 |
| „Schnell hinzufügen“ | 4 Buttons: „Lernpaket“ (Dialog), „Freie Zeit“ (Verfügbarkeitsdialog), „Testtermin“ (navigiert nur zu `#/exams`), „Persönlich“ (Termin-Dialog mit Art persönlich und Datum) | je nach Dialog | :130, 135 |
| Mini-Kalender | „Monat Jahr“ mit ‹/›-Links (Monat ±1); Kopf Mo–So; 42 Tageslinks zur Tagesansicht, bis zu 3 Farbpunkte; Klassen heute/sel/other | – | :117–122 |

#### B.2.7 Seitenspalte Tag (`daySide`, views-plan.js:154–163)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Mini-Kalender | wie oben | – | :159 |
| „Tagesübersicht“ | Donut: Vorlesungen, Übungen, Tests, Freie Zeit; Mitte „done/total Aufgaben“ | `GET /timetable/day` | :155–160 |
| „Heutige Aufgaben“ + „Hinzufügen“ (`#addTaskBtn`) | der Button öffnet den Dialog „Neues Lernpaket“ (nicht „Aufgabe“) | `GET /modules` | :161, 137 |
| Aufgabe `.task2` | runde Checkbox (`data-taskdone`, Toast „Erledigt ✓“ oder „Wieder offen“), „Fach – Titel“, Zeit · Typ · Minuten, Buch-Button → `#/doc/<file>?task=`. Leer: „Für diesen Tag ist nichts geplant.“ | `POST /tasks/:id/status` | :161, 136 |
| „Freie Zeit“ | Fenster „hh:mm – hh:mm“, Minuten, „· Campus“, Button „Lernzeit planen“ (`data-use`) → B.2.19. Leer: „Keine freien Fenster (Lernzeit a–b).“ | – | :162, 138 |

#### B.2.8 Aufgabenzeile (`taskRow`/`bindTaskRows`, views-plan.js:199–220)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Checkbox `.chk` (`data-done`) | Tooltip „Als erledigt/offen markieren“; Toast „Erledigt ✓“ oder „Wieder offen“ | `POST /tasks/:id/status {status}` | :201, 207 |
| Titel/Meta | Typ-Icon und Titel; Typ · Minuten · Uhrzeit · Status · „verschoben von …“ · Testpunkte | – | :202 |
| „Öffnen“ | Link `#/doc/<file>?task=<id>[&page=<last_page>]` | – | :203 |
| Test-Button (`data-starttest`) | „Test starten“ (primary), „Fortsetzen“ oder „Ergebnis“; zeigt „Test wird erstellt…“, dann → `#/exams/<test>?task=<id>`. Fehler als Toast (5 s) | `POST /tasks/:id/start-test` | :203, 208 |
| „…“ (`data-taskmenu`) | öffnet das Aufgaben-Menü (B.2.9) | – | :204, 209 |

#### B.2.9 Modal „Aufgabe“ (Aufgaben-Menü), views-plan.js:211–218

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| „In Bearbeitung“ | setzt den Status | `POST /tasks/:id/status {status:"in_bearbeitung"}` | :211, 217 |
| „Auf anderen Tag verschieben“ | Verschieben-Dialog (B.2.11), Toast „Verschoben“ | `POST /calendar/apply {moves:[{task_id,to}]}` | :214 |
| „Bewusst überspringen“ | setzt den Status | `POST /tasks/:id/status {status:"uebersprungen"}` | :217 |
| „Titel / Dauer ändern“ | Modal „Aufgabe bearbeiten“: Titel (vorbelegt), Dauer in Minuten (immer mit 45 vorbelegt, min 5, step 5); Abbrechen/Speichern | `PATCH /tasks/:id {title, est_minutes}` | :216 |
| „Löschen“ (danger) | `confirm` „Aufgabe löschen?“ | `DELETE /tasks/:id` | :215 |
| „Abbrechen“ | schließt | – | :211 |

#### B.2.10 Drawer „Lernpaket“ (`openPackage`, views-plan.js:184–198)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Laden | lädt das Paket; Fehler-Toast „Paket nicht gefunden“ | `GET /packages/:id` | :185 |
| Kopf | Punkt, Fach, „Titel · Datum · Zeit · Minuten“, Status-Pill, X schließt | – | :186 |
| Körper | Aufgabenzeilen (B.2.8) | – | :187 |
| Nachhol-Box (Status nachholen/teilweise) | „N Aufgaben müssen nachgeholt werden.“; „Neu einplanen“ (`#pkSuggest`) → `suggestFlow({package_id})`; „Bewusst überspringen“ (`#pkSkip`), Toast „Übersprungen“ | `POST /calendar/suggest`; `POST /tasks/skip` | :188, 192–193 |
| „Verschieben“ (`#pkMove`) | Verschieben-Dialog „Lernpaket „X“ verschieben“, Toast „Verschoben“ | `PATCH /packages/:id {date}` | :194 |
| „Uhrzeit“ (`#pkTime`) | Modal „Uhrzeit“: Beginn (time, Standard 09:00), Dauer (number, step 15); Abbrechen/Speichern | `PATCH /packages/:id {start_time,end_time}` | :195 |
| „Aufgabe“ (`#pkAddTask`) | Dialog „Aufgabe hinzufügen“ (B.2.14) | – | :197 |
| Papierkorb (danger, `#pkDel`) | `confirm` „Lernpaket mit allen Aufgaben löschen?“ | `DELETE /packages/:id` | :196 |

#### B.2.11 bis B.2.19 Weitere Dialoge im Lernkalender

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| **B.2.11 Verschieben-Dialog** (`moveDialog`) | Titel, „Neuer Tag“ (date), Chips „+1 Tag“, „+2 Tage“, „+3 Tage“, „+7 Tage“ (gerechnet ab heute); Abbrechen/„Verschieben“ | Callback | :221–225 |
| **B.2.12 Uhrzeit** | s. B.2.10 | – | :195 |
| **B.2.13 Aufgabe bearbeiten** | s. B.2.9 | – | :216 |
| **B.2.14 „Aufgabe hinzufügen“** (`addTaskDialog`) | Art: Vorlesung, Übung, Wochentest, Wiederholung, Freies Lernen. Dokument (optional, Dateien des Moduls; füllt den Titel vor). Titel (Platzhalter „z. B. Kapitel 3 wiederholen“). Dauer (Standard 45). Abbrechen/„Hinzufügen“, Toast „Aufgabe hinzugefügt“ | `GET /modules/:id`; `POST /packages/:id/tasks` | :226–234 |
| **B.2.15 „Neues Lernpaket“** (`addPackageDialog`) | Tag (date), Modul (select), Titel („z. B. Kapitel 2 lernen“), Beginn (optional), Dauer (Standard 60 oder freie Minuten); Abbrechen/„Anlegen“, Toast „Lernpaket angelegt“ | `GET /modules`; `POST /packages {date,module_id,title,minutes}`; mit Beginn zusätzlich `PATCH /packages/:id` | :235–241 |
| **B.2.16 „Lernplan erstellen“** (`generatePlan`) | Erklärtext. Hinweisbox (warn) oder „Offen: ca. X · verfügbar in 4 Wochen: Y“. „Ab“ (date), „Tage“ (7 Tage, 14 Tage, 4 Wochen). Checkbox „Bereits geplante, noch nicht begonnene Pakete … ersetzen“. Buttons: Abbrechen, „Lernkombination ändern“ (öffnet Konfiguration, danach zurück), „Erstellen“ (wird deaktiviert). Toast mit Server-Meldung, dann Wechsel zur Wochenansicht | `GET /calendar/feasibility`; `POST /calendar/generate {start,days,replace}` | :242–251 |
| **B.2.17 „Meinen Lernplan konfigurieren“** (`configDialog`) | Preset-Radios: A Intensiv, B Intensiv mit Wiederholung, C Abwechslungsreich, D Zwei Fächer mit Wiederholung, E Benutzerdefiniert. Felder: Fächer pro Tag (1/2/3), Lernzeit pro Tag (Minuten, min 30, step 15), Vorlesungen der Woche (nicht einplanen / alle der Lehrwoche), Übungen der Woche (nicht einplanen / alle …), Wochentest pro Modul (kein Test / 1 gemeinsamer Test / 1 Test + Wiederholung), Dauer Wochentest (15/30/45/60/90). Lerntage als Chips Mo–So (an = Lerntag). Checkbox „Klausurtermine stärker priorisieren“. Live-Machbarkeit `#cFeas` (grün „Passt in …“, rot „Das passt nicht … Vorschlag …“). Abbrechen/Speichern, Toast „Lernkombination gespeichert“ | `GET /settings`; `PUT /settings {subjects_per_day, parts_lecture, parts_exercise, tests_per_subject, test_minutes, hours_per_day, free_days, exam_priority}` | :252–273 |
| **B.2.18 „Meine Woche retten“ / „Neu einplanen“** (`suggestFlow`) | ohne Vorschläge nur ein Toast mit der Meldung. Sonst: Meldung, Liste je Vorschlag (Icon, Fach: Titel, Minuten, „von →“, editierbares Datum), Hinweistext; Abbrechen/„Vorschlag übernehmen“, Toast „N Aufgaben neu eingeplant“ | `POST /calendar/suggest`; `POST /calendar/apply {moves}` | :274–282 |
| **B.2.19 „X frei (hh:mm–hh:mm)“** (`useFreeWindow`) | „Wie möchtest du die Zeit nutzen?“. Mit Materialien zusätzlich „Passende Übung bearbeiten“ und „Vorlesung selbstständig nacharbeiten“. Immer: „Lerneinheit automatisch einplanen“, „Offene Aufgaben nachholen“ (`suggestFlow({horizon:1})`), „Eigenen Lernblock anlegen“ (Neues Lernpaket mit Minuten), „Frei lassen“. Toast „Lernblock angelegt“ bzw. Server-Meldung | Übung/Vorlesung: `POST /packages {date,module_id,title,tasks}` und `POST /timetable/reslot {dates}`; Auto: `POST /calendar/generate {start,days:1}` | :168–181 |

### B.3 Stundenplan (`#/timetable`), views-tt.js

API beim Laden: `GET /timetable/week?start=`, `GET /timetable/conflicts`.

#### B.3.1 Hauptansicht (views-tt.js:6–33)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Titel | „Stundenplan“; Unterzeile „Semester · Beginn – Ende · Lernzeit a–b“ | – | :12 |
| „Verfügbarkeit“ (`#ttAvail`) | Dialog „Persönliche Verfügbarkeit“ (B.3.4) | `GET /settings` | :13, 28 |
| „+ Termin“ (`#ttAdd`) | Dialog „Neuer Termin“ (B.3.3) | `GET /modules` | :13, 28 |
| „Stundenplan importieren“ (primary, `#ttImport`) | Import-Dialog (B.3.5) | – | :13, 28 |
| Konflikt-Banner (warn) | „N Lernslot(s) überschneiden sich mit Hochschulterminen“, bis zu 4 Konflikte; Button „Lernslots neu legen“ (`#ttReslot`), Toast „N Tage neu gelegt“ | `POST /timetable/reslot {}` | :14, 29 |
| Wochennavigation | ‹ (`#ttPrev`, −7 Tage), Zeitraum-Label, › (`#ttNext`), „Heute“ (ghost, `#ttToday`) | – | :15, 27 |
| Legende | Vorlesung/Übung, Lernslot, Frei, Sperrzeit | – | :16 |
| Leerzustand | „Noch kein Stundenplan.“ und Hinweis auf Import aus Stud.IP | – | :17 |
| Raster | Kopf mit langem Wochentag und Datum (heute hervorgehoben); Achse 56 px pro Stunde (min(Lernbeginn, 8:00) −1 h bis max(Lernende, 18:00) +1 h) | – | :9, 18–19 |
| Freie Fenster / Sperrzeiten | `.tt-free` schraffiert (Tooltip mit Minuten); `.tt-blocked` mit Titel | – | :21–22 |
| Termin `.tt-ev` | Kurzname, „Zeit · Raum (18 Zeichen)“; Statusklassen nicht_teilnahme, ausfall, verschoben. Klick → Termin-Drawer | B.3.2 | :23, 30 |
| Lernslot `.tt-ev.study` | Fach, Zeit · Titel. Klick → Lernpaket-Drawer; hier **nicht** ziehbar (bindCalendar wird nicht aufgerufen) | `GET /packages/:id` | :24, 31 |
| **Doppelklick** in eine Spalte | öffnet „Neuer Termin“, vorbelegt mit Wochentag, Startzeit (auf 15 min gerundet), Ende +90 min und date_from | `GET /modules` | :32 |
| Fußhinweis | Erklärung zum Termin-Klick | – | :26 |

#### B.3.2 Termin-Drawer (`openEvent`, views-tt.js:35–57)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Laden | Fehler: Toast „Termin nicht gefunden“ | `GET /timetable/events`, `GET /timetable/day?date`, `GET /timetable/event-materials/:id?date` | :36–38 |
| Kopf | Punkt, Titel, „Art · Datum · Zeit · Raum · Dozent“, X | – | :40 |
| Teilnahme-Karte | „Teilnahme: Ich nehme teil / Heute nicht / Dauerhaft nicht / Fällt aus / Verschoben“; Rhythmus „Alle zwei Wochen/Wöchentlich · aus Stud.IP“ | – | :41 |
| Buttons (aktiver = primary) | „Ich nehme teil“ (today_attend), „Ich nehme heute nicht teil“ (today_skip), „Ich besuche diese Veranstaltung dauerhaft nicht“ (permanent_skip), „Veranstaltung fällt aus“ (cancelled); bei Nichtteilnahme zusätzlich „Wieder dauerhaft besuchen“ (permanent_attend); bei Ausnahme „Ausnahme für diesen Tag zurücksetzen“ (reset) | `POST /timetable/attendance {event_id,date,mode}` | :42, 46–53 |
| Folge-Modal „Du hast jetzt X frei“ | nur bei skip oder cancelled mit ≥30 freien Minuten: „Frei lassen“ / „Zeit nutzen“ → B.2.19. Sonst Toast „Teilnahme gespeichert“ | – | :48–51 |
| „Passende Unterlagen“ | Dokumentzeilen (Link `#/doc/:id`). Leer: „Keine passenden Unterlagen gefunden.“ Button „Modul öffnen“ | – | :43–44 |
| „Bearbeiten“ (`#evEdit`) | Termin-Dialog mit Datum | – | :54 |
| „Lernblock danach“ (`#evBlock`) | Freies Fenster vom Terminende +90 min (höchstens bis 22:00) → B.2.19 | – | :56 |
| Papierkorb (`#evDel`) | `confirm` „Ganze Veranstaltungsreihe aus dem Stundenplan entfernen?“ | `DELETE /timetable/events/:id` | :55 |

#### B.3.3 Termin-Dialog (`eventDialog`, views-tt.js:59–75)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Titel | „Neuer Termin“ oder „Termin bearbeiten“ | `GET /modules` | :60–62 |
| Felder | Titel („z. B. Mathematik I – Vorlesung“); Art (alle 9 KIND_TXT: Vorlesung, Übung, Hörsaalübung, Gruppenübung, Tutorium, Labor, Seminar, Sonstiges, Persönlich); Modul (– keins –/Module); Wochentag (Montag–Sonntag); Beginn; Ende; Raum; Dozent/in; Rhythmus (Wöchentlich / Alle zwei Wochen / Einzeltermin); Von; Bis | – | :63–67 |
| „Änderung gilt für“ (nur beim Bearbeiten einer Serie) | „Nur diesen Termin (Datum)“ / „Diesen und alle zukünftigen Termine“ / „Die gesamte Veranstaltungsreihe“ (Standard) | – | :68 |
| Abbrechen/Speichern | Toast „Gespeichert“ | neu: `POST /timetable/events`; bearbeiten: `PATCH /timetable/events/:id {…, scope, date}` | :69–74 |

#### B.3.4 „Persönliche Verfügbarkeit“ (`availabilityDialog`, views-tt.js:77–91)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Felder | Früheste Lernzeit, Späteste Lernzeit (time); Fahrtzeit Zuhause ↔ Uni, Mindestdauer eines Lernslots, Pause zwischen Aufgaben (step 5); Maximale Lernzeit pro Tag (step 15) | `GET /settings` | :79–82 |
| Chips „Lernfreie Wochentage“ Mo–So | an = **lernfrei** (umgekehrt zu B.2.17) | – | :83, 89 |
| Sperrzeiten-Liste | pro Zeile: Wochentag-Select, Start, Ende, Bezeichnung, X löschen. Leer: „Keine Sperrzeiten.“ Button „+ Sperrzeit“ (Standard Mo 12:00–13:00) | – | :84, 86–88 |
| Abbrechen/Speichern | Toast „Verfügbarkeit gespeichert“ | `PUT /settings {learn_start, learn_end, travel_minutes, min_slot_minutes, break_minutes, hours_per_day, free_days, blocked_times}` | :90 |

#### B.3.5 Import-Kette (views-tt.js:93–126)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Modal „Stundenplan importieren“ | Hinweis zur Vorschau. Quellen: „Aus Stud.IP übernehmen (Termine deiner Kurse)“ (primary), „Kalenderdatei (ICS)“, „PDF-Stundenplan (Texterkennung + KI)“, „Screenshot / Foto (KI-Bildanalyse)“, „Text einfügen (KI)“, „Manuell eingeben“ (→ Termin-Dialog); Abbrechen | – | :94–99 |
| Datei-Auswahl | verstecktes `<input type=file>`; accept `.ics,text/calendar`, `application/pdf` oder `image/*` | – | :103 |
| Modal „Stundenplan als Text“ | Textarea mit Beispiel-Platzhalter; Abbrechen/„Analysieren“ | – | :101 |
| Modal „Import läuft…“ | Stud.IP: „Termine werden zusammengefasst.“; sonst: „Die KI liest … halbe Minute.“ Fehler: Toast „Import fehlgeschlagen: …“ (6 s) | `POST /timetable/import/preview` (FormData: source, text/upload) | :106–110 |
| Modal „Importvorschau · N Veranstaltungen“ (breit, 900 px) | Zählung neu/geändert/unverändert/nicht mehr enthalten; Hinweis auf orange (unsichere) Zeilen. Tabelle: Checkbox, Veranstaltung (Input und Hinweise „vorhanden (bisher …)“), Art, Tag, Von, Bis, Raum, Modul; abgewählte Zeilen blass | – | :111–117 |
| „Nicht mehr im neuen Plan“ | Chips mit Checkbox „Titel (Tag Zeit)“, Hinweis „Angehakte werden entfernt.“ | – | :115 |
| Abbrechen/„Übernehmen“ | ohne Auswahl Toast „Nichts ausgewählt“; sonst Toast „N neu, M aktualisiert, K entfernt“ | `POST /timetable/import/confirm {entries,source,import_id,remove_ids}` | :118–124 |
| Modal „N Lernslots kollidieren jetzt mit Terminen“ | Liste (bis 8); „Später“ / „Lernslots neu legen“ | `POST /timetable/reslot {}` | :123 |

### B.4 Meine Module, views-misc.js

#### B.4.1 Liste (`#/modules`, views-misc.js:19–26)

API: `GET /modules`.

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Titel | „Meine Module“, Unterzeile | – | :22 |
| Segment „Karten“/„Liste“ (Pill) | in localStorage `mod-mode` | – | :23, 25 |
| „Module & Wochentests“ | Link `#/settings?tab=modules` | – | :23 |
| Modulkarte `.mod2` (Link `#/modules/:id`) | Deko-Icon nach Name (mathe → grid, elektro → sparkles, signal → rotate, programm → type, datenstruktur → layers, einf → columns, digital → cards, sonst book); Initialen-Kachel; Name; Beschreibung (Themen oder „Vorlesung, Übungen und Material – N Veranstaltung(en) aus Stud.IP.“); „X % bearbeitet“ und „N neue Inhalte“ oder „Klausur Datum“/„aktuell“; Fortschritt; Box „Nächster Termin“, „Nächster Lernblock“ oder „Kein Termin in den nächsten 14 Tagen“; Kennzahlen Dateien, Aufgaben, Wochentest(s) | – | :5–18 |
| Listenzeile `.lib-row` | Initialen-Ordner, Name, Themen, „% bearbeitet“, „N Dateien · N neu“, nächster Termin, Chevron | – | :24 |
| Leerzustand | „Noch keine Module. Erst synchronisieren.“ | – | :24 |

#### B.4.2 Moduldetail (`#/modules/:id`, views-misc.js:27–50)

API: `GET /modules/:id`.

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Kopf | Farbkachel mit Initialen, Name, „N Veranstaltungen: Arten · Klausur Datum“ | – | :38 |
| „Modul“ (`#modEdit`) | Modal „Modul bearbeiten“ (B.4.3) | – | :39, 47 |
| Segment Liste/Kacheln (Icons) | Ansichtsmodus, nur im Speicher | – | :39, 44 |
| KPIs | Lernfortschritt %; aktuelle Lehrwoche (· Thema); nächster Lernblock (Datum, Titel, Link „öffnen“) oder „Kein Lernblock geplant“ | – | :40 |
| Tabs | Übersicht, Vorlesungen, Übungen, Lösungen, Skripte, Klausuren, Notizen (nur im Speicher) | – | :41, 43 |
| Übersicht: Wochenblöcke | Kopf (Chevron, „Label – Thema“, „N Dokumente“) klappt den Inhalt ein/aus. Button „Zusammenfassen“ (nur bei Vorlesungen) → B.4.4. Inhalt nach Gruppe (Vorlesung, Übung, Lösung, Skript, Klausur, Sonstiges bzw. sub_label) mit h4 und Dokumentzeilen. Leer: „Keine Dokumente.“ | – | :33–34, 45–46 |
| Andere Tabs | Dokumentliste (Zeilen oder `.doc-grid`-Karten). Leer: „Nichts vorhanden.“ | – | :32, 35–36 |
| Dokumentzeile `.doc-row` | Typ-Icon, Titel (Status neu → Badge „Neu“; erledigt → durchgestrichen), Unterzeile „sub_label · Ordner · Datum · ca. N min · mit Notizen“, Stern bei Favorit, Stufen-Badge; Link `#/doc/:id` | – | :51 |
| Dokumentkarte `.doc-card` | Typ-Badge, Stufe, Titel, Datum · Minuten, Zusammenfassung (3 Zeilen) | – | :52 |

#### B.4.3 Modal „Modul bearbeiten“ (`editModule`, views-misc.js:53–59)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Felder | Name; Farbe (Farbwähler); Priorität (Niedrig/Normal/Hoch); Klausurtermin (date); Checkbox „Modul aktiv (wird eingeplant)“; Checkbox „Gemeinsamer Wochentest“; „Abweichende Testdauer“ (Standard/15/30/45/60/90 min) | – | :54–56 |
| Abbrechen/Speichern | Toast „Gespeichert“ | `PATCH /modules/:id {name,color,priority,exam_date,active,weekly_test,test_minutes}` | :57–58 |

#### B.4.4 Modal „Zusammenfassung: <Woche>“ (`summarizeWeek`, views-misc.js:60–65)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Ladezustand | „⏳ Die KI liest die Vorlesungsfolien dieser Woche…“ | bis zu 3 Vorlesungen × Seite 1–4: `GET /files/:id/pagetext?page=n` (max. 9000 Zeichen) | :61–62 |
| Ergebnis | Markdown (über `md` aus editor.js); Fehler: „Fehler: …“; Button „Schließen“ | `POST /ai/tutor {file_id,page:1,mode:"summary",page_text,question}` | :63–64 |

### B.5 Dokumente & Notizen (`#/files`), views-lib.js

API: `GET /library`.

#### B.5.1 Hauptansicht (views-lib.js:13–81)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Titel | „Dokumente & Notizen“, Unterzeile | – | :57 |
| Suche (`#libQ`, Platzhalter „In Dokumenten suchen…“) | Debounce 300 ms, setzt `q=` im Hash; durchsucht title, name, ai_title, subject (lokal) | – | :58, 70, 50 |
| Modul-Select (`#libMod`) | „Alle Module“ oder Modul → `#/files?path=m<id>` | – | :59, 71 |
| Sortierung (`#libSort`) | „Zuletzt bearbeitet“ / „Name“ (nur im Speicher) | – | :60, 71 |
| Segment Kacheln/Liste | in localStorage `lib-mode` | – | :61, 73 |
| „+ Neu“ (primary, `#libNew`) | Neu-Menü (B.5.2) | – | :61, 74 |
| Typ-Chips | Alle, Vorlesungen, Übungen, Skripte, Klausuren, Notizen, Sonstiges (Filter nur im Speicher; außerhalb von docs → `#/files`) | – | :6, 62, 72 |
| Bereichs-Links (ghost) | „Favoriten“ (Stern), „Zuletzt“ (Uhr), „Neu aus Stud.IP“ (sparkles, Badge mit Anzahl), „Papierkorb“ (trash); aktiver Bereich in accent-soft | – | :63 |
| Brotkrumen `.lib-crumbs` (nicht auf der Startebene) | Bereichstitel oder Pfad-Links mit „›“; Zusatz „· Suche „q““ bzw. „· Filter“ | – | :64 |
| Papierkorb-Hinweis | „Dokumente im Papierkorb lassen sich wiederherstellen …“ | – | :65 |
| Startebene: `.folder-grid` | Ordnerkarten für Module (Initialen) und eigene Ordner (Ordner-Icon): Welle, Mappe, Name, Kebab-Menü (`data-menu` module:ID oder folder:ID), „N Dokument(e)“. Klick öffnet den Pfad | – | :66, 82–85 |
| Startebene: „Eigene Dokumente“ | eigene Dokumente ohne Ordner als Kacheln oder Liste | – | :66 |
| Startebene: „Schnellzugriff“ | 4 zuletzt bearbeitete; Link „Alle anzeigen →“; Farbkachel je Typ, Titel, „Fach/Eigene Notizen · vor N Tagen“. Leer: „Zuletzt geöffnete Dokumente erscheinen hier.“ | – | :67, 86–89 |
| Unterebenen: Kacheln `.lib-grid` | Ordner (farbige Mappe, Name, bei eigenen Ordnern Menü-Chevron, „N Dokumente“). Dokument: Vorschau (PDF-Thumbnail lazy über IntersectionObserver, rootMargin 400px; Notizbuch liniert; Whiteboard; Bild), Stern-Toggle, Name, Menü-Chevron, „bearbeitet Datum“ bzw. Datum, „· Neu“. Papierkorb: „gelöscht Datum“, nicht anklickbar | `POST /files/:id/favorite {favorite}`; Thumbnail `GET /files/:id/content` (renderThumbnail) | :68, 77, 79–80, 90–94 |
| Unterebenen: Liste `.lib-row` | Mini-Icon oder Thumbnail, Titel (+ Originalname), Typ, Fach/„Eigene“, Datum, „…“-Menü | – | :95–99 |
| Leerzustände | Ordner-Icon und „Papierkorb ist leer.“, „Keine Treffer.“ oder „Hier ist noch nichts. Über „Neu“ ein Notizbuch anlegen oder eine PDF importieren.“ | – | :68 |
| Klick auf Element (`data-open`) | `doc:` → `#/doc/:id`; `path:` → `#/files?path=` | – | :75 |

#### B.5.2 Neu-Menü und Notizbuch-Dialog

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Modal „Neu (in „Ordner“)“ | Buttons Notizbuch, Whiteboard, Ordner, PDF importieren, Bild importieren; Abbrechen | – | views-lib.js:100–104 |
| · Ordner | `prompt` „Name des Ordners:“ (Standard „Neuer Ordner“) | `POST /folders {name,parent_id,module_id}` | :107 |
| · PDF/Bild importieren | Datei-Dialog (mehrere Dateien), Toast „Importiert“ | je Datei `POST /notebooks` (FormData: kind, title, module_id, folder_id, upload) | :109–110 |
| Modal „Neues Notizbuch“ / „Neues Whiteboard“ | Titel (Standard Notizen/Whiteboard); nur Notizbuch: Vorlagen-Chips Leer, Liniert (Standard), Kariert, Gepunktet, Millimeter, Cornell; Modul (optional); Abbrechen/„Erstellen“ → `#/doc/<neu>` | `POST /notebooks` (FormData: kind, title, template, module_id, folder_id) | :113–120 |

#### B.5.3 Kontextmenüs (`itemMenu`, views-lib.js:121–137)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Ordner „X“: Umbenennen | `prompt` „Neuer Name:“ | `PATCH /folders/:id {name}` | :123 |
| Ordner: Farbe | `prompt` „Farbe (Hex):“ | `PATCH /folders/:id {color}` | :123 |
| Ordner: „Ordner löschen (Inhalt bleibt erhalten)“ | `confirm` | `DELETE /folders/:id` | :123 |
| Papierkorb: Wiederherstellen | Fehler als Toast | `PATCH /library/files/:id {restore:true}` | :124 |
| Papierkorb: Endgültig löschen (danger) | ohne Rückfrage | `PATCH /library/files/:id {delete_forever:true}` | :124 |
| Dokument: Öffnen | `#/doc/:id` | – | :126, 129 |
| Dokument: Zu Favoriten / Aus Favoriten entfernen | – | `POST /files/:id/favorite` | :130 |
| Dokument: Umbenennen | `prompt` „Neuer Titel:“ | `PATCH /library/files/:id {title}` | :131 |
| Dokument: „In Ordner verschieben“ | Modal „Verschieben nach“ (Select „(kein Ordner …)“ oder „Modul › Ordner“), Abbrechen/Verschieben | `PATCH /library/files/:id {folder_id}` | :132 |
| Dokument: Duplizieren | – | `PATCH /library/files/:id {duplicate:true}` | :133 |
| Dokument: Original herunterladen | nur bei geladenen PDFs; `<a download>` | `GET /files/:id/content` | :126 |
| Dokument: In den Papierkorb (danger) | `confirm` (bei Stud.IP-Dateien mit Hinweis auf das Original) | `PATCH /library/files/:id {trash:true}` | :134 |
| Modul-Kebab auf Ordnerkarte (`module:ID`) | **fehlerhaft**, s. E | – | :84, 125 |

### B.6 Dokumentansicht (`#/doc/:id`, Shell), views-doc.js

Laden:
1. `GET /files/:id`. Bei Fehler wird der Tab geschlossen und die Karte „Dokument nicht gefunden.“ gezeigt.
2. `POST /files/:id/opened {}` ohne auf die Antwort zu warten.
3. Bei Status „neu“: `PATCH /files/:id {status:"gelesen"}`.
4. `GET /settings` für Schreibhand und pen_input.
5. Setzt `view.className="doc-view"` und `body.doc-open` (views-doc.js:13–20).

#### B.6.1 Kopfleiste `.doc-top`

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Menü (`#docMenu`, nur ≤900 px) | schaltet die Sidebar um (ohne Backdrop) | – | :22, 35 |
| „‹ Dokumente“ (`#docBack`) | `history.back()`, sonst Modul oder `#/files`; Text unter 1100 px ausgeblendet | – | :22, 30 |
| Tabs `#docTabs` | geöffnete Dokumente aus localStorage `uniflow-doc-tabs` (max. 12): Icon, Titel, Tooltip. Klick → `#/doc/:id`. X schließt den Tab; beim aktiven Tab geht es zum letzten Tab oder zu `#/files`. Der aktive Tab wird ins Bild gescrollt | – | :5–10, 105–111 |
| „✓ Erledigt“ (btn ok, `#docDone`, nur mit `?task=`) | Toast „Aufgabe erledigt ✓“, dann → `#/plan` | `POST /tasks/:task/status {status:"erledigt"}` | :23, 36 |
| Status-Select (`#docState`) | neu / gelesen / erledigt; Toast „Status gespeichert“ | `PATCH /files/:id {status}` | :24, 31 |
| Stern (`#docFav`) | Farbe warn (Favorit) oder muted | `POST /files/:id/favorite {favorite}` | :25, 32 |
| „Notizen“ (`#docNotes`) | blendet die Notizspalte ein/aus | – | :26, 40 |
| „Geteilt“ (`#docSplit`) | offen: schließt die geteilte Ansicht; sonst Auswahl „Zweites Dokument öffnen“ (B.6.4) | `GET /files` | :26, 80 |
| Vollbild (`#docFull`) | schaltet `body.fullscreen-doc` um | – | :26, 33 |
| „× Vollbild beenden“ (`#fsExit`) | schwebende Pill oben rechts, nur im Vollbild sichtbar | – | :27, 34 |

#### B.6.2 Bereiche `#docPanes`

Klasse `hand-right` oder `hand-left`.

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Bereich A `#paneA` | Editor (PdfEditor) für PDFs und Notizbücher. Startseite aus `?page`, last_page oder dem gespeicherten Tab-Zustand. Seitenwechsel (Debounce 800 ms) speichert last_page | `POST /files/:id/opened {last_page}`; Inhalt `GET /files/:id/content` | :37, 119–134 |
| Notizspalte `#paneN` | Kopf „Eigene Notizen“ mit Anzeige „gespeichert“; Textarea mit Platzhalter (Hinweis auf Handschrift über „Seite +“). Debounce 600 ms schreibt in `edA.model.note` und `markDirty()`; gespeichert wird über die Editor-Annotationen | (editor) | :28, 39 |
| Trenner `#splitHandle` | nur in der geteilten Ansicht; Pointer-Drag 20–65 %, gespeichert in localStorage `doc-split` (Standard 35 %) | – | :28, 42–55 |
| Bereich B `#paneB` | `.pane-bar` mit Buch-Icon, „Lädt…“ bzw. Titel, Button „× Schließen“; zweiter Editor ohne eigene Werkzeugleisten (CSS blendet `.ed-main`/`.ed-ctx` aus); übernimmt den Werkzeugzustand von A | `GET /files/:pick`; Fehler: Toast „Dokument nicht gefunden“ | :58–79 |
| Layout | Rechtshänder: [B pct %][10 px][A](+300 px Notizen). Linkshänder: [A][10 px][B pct %] | – | :43–49 |

#### B.6.3 Ersatzanzeigen (`mountDoc`/`docFallback`)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Datei fehlt lokal | „Datei ist lokal nicht vorhanden. Bitte Sync ausführen.“ | – | :123 |
| Textdateien (.py .txt .md .c .h .java .pf .csv .tex) | Monospace-Block `.nonpdf` | `GET /files/:id/content` | :135 |
| Bilder (.png .jpg .gif .webp) | `<img>` | – | :136 |
| Sonstige Typen | „Keine Vorschau für diesen Dateityp.“ + „Öffnen / Herunterladen“ | – | :137 |
| Fehler-Karte (warn) „Dokument wird nicht angezeigt“ | Meldung; „Im Browser-Viewer anzeigen“ (iframe `…/content#toolbar=1`), „In neuem Tab öffnen“, „Neu laden“, „Diagnose“ (→ `#/settings?tab=diag`). Wird auch nach 2,5 s gezeigt, wenn keine Seite sichtbar ist | – | :112–118, 130, 132 |

#### B.6.4 Modal „Zweites Dokument öffnen“ (`pickDocument`, views-doc.js:139–146)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Suche | Platzhalter „Suchen… (z. B. Übungsblatt)“, filtert live | `GET /files` (nur PDFs) | :141–144 |
| Liste | max. 60, gleiches Modul zuerst, dann neueste; Icon, Titel, „Fach · Typ“; Klick wählt | – | :143 |
| Abbrechen / Klick auf die Abdunkelung | Ergebnis null | – | :144 |

#### B.6.5 Skript-Hinweis (`setupScriptHint`, views-doc.js:81–104)

Nur bei Übungen, Lösungen und Klausuren oder wenn der Name auf übung, blatt, ueb oder aufgabe passt.

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Auslöser | 2,5 s nach Tinte, Seitenwechsel oder Scrollen; nicht während des Schreibens (`html.ed-inking`) | `POST /related {file_id,text}` (pro Kontext-Key gecacht) | :88–103 |
| Box `.script-hint` (schwebt oben rechts) | „Passende Skriptstelle (zu Aufgabe X)“, „Titel · Seite N“; Tooltip mit Ausschnitt und gemeinsamen Begriffen | – | :96–97 |
| „Öffnen“ (primary) | öffnet die Stelle in der geteilten Ansicht auf der Seite | `GET /files/:id` | :98 |
| X | „Für diese Aufgabe ausblenden“ | – | :99 |

### B.7 Zeitmesser (global), views-doc.js:149–170

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Öffnen | Header-Button `#profileBtn` (Uhr-Icon, Tooltip „Zeitmesser“) schaltet um; die Editor-Funktion „timer“ öffnet | – | app.js:16, 23; views-doc.js:128, 150 |
| Widget `.timer-widget` (unten rechts, 260 px) | Segment Stoppuhr / Countdown / Pomodoro (Wechsel setzt zurück); X schließt | – | :160, 165, 167 |
| Anzeige | große Zeit m:ss; rot bei Ablauf | – | :161 |
| Countdown-Chips | 5, 15, 25, 45, 60 min | – | :162, 166 |
| Pomodoro-Info | „Arbeiten/Pause · Runde N · 25/5 min“ | – | :162 |
| „Start“/„Pause“ (primary), „Zurücksetzen“ | Takt alle 500 ms | – | :163, 168–169 |
| Pill `.timer-pill` | bei geschlossenem Widget, wenn die Uhr läuft oder Zeit vergangen ist; Klick öffnet | – | :157 |
| Ablauf | Toast „Pomodoro vorbei – Pause!“, „Pause vorbei – weiter geht's“ oder „Zeit abgelaufen“; Pomodoro wechselt die Phase automatisch | – | :154 |

### B.8 Tests & Wiederholung, views-misc.js

#### B.8.1 Übersicht (`#/exams`, views-misc.js:68–90)

API: `GET /tests`, `GET /modules`, `GET /flashcards?due=true`.

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Titel | „Tests & Wiederholung“, Unterzeile | – | :78 |
| Modul-Select (`#exSubj`), Dauer-Select (`#exDur`) | Dauer 15/30 (Standard)/45/60/90 min | – | :79 |
| „+ Zusatztest“ (`#exGen`) | Toast „Zusatztest wird erstellt (ca. 1 Minute)…“, dann pollBg | `POST /tests/generate {module_id,duration_min}` | :79, 82 |
| „Wochentests erstellen“ (primary, `#exWeek`) | Toast „Fehlende Wochentests werden erstellt…“ | `POST /tests/generate-week` | :79, 83 |
| Statusleiste `.statbar` | „N offene Tests“, „N abgeschlossen · Ø X %“, Link „N Karteikarten fällig →“ (`#/cards`) | – | :80 |
| Testkarte `.test-card` (oberer Rand in Modulfarbe) | Punkt und Fach; Badge „Wochentest“ (neutral) oder „manuell“ (info); Löschen-Icon (40×40); „Lehrwoche N / Woche Datum · Dauer · N Aufgaben“; bereinigter Titel. Abgegeben: Fortschritt (grün ≥60 %, sonst rot), „X/Y Punkte (Z %)“, Button „Ansehen“. Offen: „begonnen“ oder „noch nicht gestartet“, Button „Fortsetzen“/„Starten“ (primary) → `#/exams/:id`. Sortiert nach Woche, neueste zuerst | – | :72–77 |
| Leerzustand | Test-Icon und „Noch keine Wochentests. Sie entstehen automatisch …“ | – | :77 |
| Modal „Test löschen?“ | „Fach · Titel“; bei automatischen Tests Hinweis, dass sie nicht neu entstehen; bei abgegebenen „Ergebnis und Antworten werden mit gelöscht.“; Abbrechen / „Löschen“ (danger). Toast „Test gelöscht“ bzw. „Löschen fehlgeschlagen: …“ | `DELETE /tests/:id` | :85–89 |

#### B.8.2 Testdurchführung (`#/exams/:id`, `runTest`, views-misc.js:92–113)

API: `GET /tests/:id`. Bei offenem Test wird `body.exam-focus` gesetzt (blendet Sidebar und Header aus).

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| „‹ Abbrechen“/„Zurück“ (`#exBack`) | → `#/plan` (mit task) oder `#/exams`; entfernt exam-focus und stoppt den Timer | – | :97, 109 |
| Kopf | Titel; „Fach · Dauer · N Aufgaben · KI-generiert · Lehrwoche N“ | – | :97 |
| Timer `#timer` | „⏱ m:ss“ ab started_at + Dauer; rot unter 5 min; bei 0 Toast „Zeit abgelaufen – bitte abgeben.“ | – | :97, 112 |
| Ergebnis-Karte (abgegeben) | „X / Y Punkte (Z %)“, Zusammenfassung, „Nochmal anschauen: …“ | – | :98 |
| Aufgaben-Chips (Nummern) | aktive markiert; Rahmen grün/rot nach Feedback, accent wenn beantwortet; Klick springt (aktuelle Antwort wird gemerkt) | – | :99, 106 |
| Aufgabenkarte `.q` | „Aufgabe N von M · Multiple Choice / Rechnen / Programmieren / Kurzantwort“, Punkte (→ erreicht); Frage; MC-Radios `.opt` oder Textarea „Deine Antwort / Rechenweg“; nach Abgabe gesperrt; Feedback-Box „Feedback: …“ und „Musterlösung: …“; Rahmen grün/rot | – | :100–103 |
| „‹ Zurück“ (`#qPrev`) | an Position 0 deaktiviert | – | :104, 107 |
| „Weiter ›“ (primary, `#qNext`) | nächste Aufgabe | – | :104, 107 |
| „✓ Abgeben & bewerten“ (btn ok, `#qSubmit`) | `confirm` „Test abgeben? N Aufgaben sind unbeantwortet. Die KI bewertet deine Antworten.“; Button zeigt „Wird bewertet…“; danach wird die Ansicht neu gerendert. Fehler: Toast „Bewertung fehlgeschlagen: …“ (5 s) | `POST /tests/:id/submit {answers}`; mit task zusätzlich `POST /tasks/:task/status {erledigt}` | :104, 108 |

#### B.8.3 Karteikarten (`#/cards`, `viewCards`, views-misc.js:114–128)

API: `GET /flashcards?due=true`, `GET /flashcards`.

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Kopf | „Karteikarten“, „N fällig · Leitner-System …“, Button „‹ Tests“ | – | :120 |
| Karte `.fc-card` | „Karte i von N · Fach x · Modul“; Frage; „Klicken zum Aufdecken“; Klick zeigt die Antwort | – | :121–122 |
| „Falsch“ (danger) / „Richtig“ (ok) | nur nach dem Aufdecken; weiter zur nächsten Karte | `POST /flashcards/:id/review {correct}` | :121, 123–124 |
| Leerzustand | Häkchen-Icon und „Heute nichts fällig.“ | – | :121 |
| „Alle Karten“ (Anzahl) | Frage; „Antwort · Fach · fällig Datum“; Papierkorb-Button. Leer: „Noch keine Karten. Erstelle welche im Editor über die KI-Seitenleiste.“ | `DELETE /flashcards/:id` | :117, 125 |

### B.9 Uni & Noten (`#/services`), views-misc.js:131–177

API: `GET /services`, `GET /grades`, `GET /timetable/auto-status` (Fehler wird ignoriert).

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Titel | „Uni & Noten“, Unterzeile | – | :154 |
| KPI 1 | Notendurchschnitt (mit Komma) und „· N LP“ | – | :156 |
| KPI 2 | „Leistungen im Notenspiegel · N bestanden“ | – | :157 |
| KPI 3 | Datum des letzten Abrufs; „zuletzt abgerufen“, „letzter Abruf fehlgeschlagen“ oder „noch nicht abgerufen“ | – | :158 |
| Karte „Notenspiegel (QIS)“: „Zugang“ (`#qisCred`) | Zugangsdialog für QIS (B.9.1) | – | :160, 176 |
| · „Noten & Bescheinigungen abrufen“ (primary, `#qisSync`) | Toast „Notenspiegel wird abgerufen…“, dann pollBg | `POST /grades/sync` | :160, 172–173 |
| · Inline-Box „QIS-Zugang hinterlegen“ (ohne eigenen QIS-Zugang) | Erklärtext (ggf. „Aktuell: wie X.“); Felder Benutzername, QIS-Passwort; „✓ Speichern & abrufen“ (`#qInlineOk`). Leere Felder: Toast „Benutzername und Passwort eingeben“; Erfolg: Toast „QIS-Zugang gespeichert“, dann Abruf | `PUT /credentials/qis {user,password}`, danach `POST /grades/sync` | :161, 174 |
| · Hinweis bei vorhandenem Zugang | „Zugang gespeichert (user). Die App meldet sich selbst an …“ | – | :161 |
| · Fehlerbox (letzter Abruf fehlgeschlagen) | Meldung, Hinweis auf `logs/qis-fehler.png`, Button „Noten abrufen (sichtbar)“ (`#qisShow`) | `POST /grades/sync?show=true` | :162, 174 |
| · Notentabelle `.tbl` | Prüfung (+ Nr · Abschluss), Semester, Note, LP, Status-Badge (be… = ok, ni… = bad, sonst neutral), Versuch. Leer: Icon und „Noch keine Noten geladen …“ | – | :163 |
| · „Bescheinigungen & Transcript of Records“ | Links (neuer Tab) mit Titel und Datum | `GET /qis/documents/:id` | :164 |
| · Fußhinweis | Datenschutz und Herkunft | – | :165 |
| Karte „Stundenplan“ | automatische Übernahme (+ N persönliche Einträge). Bei offenen Gruppen: Warnbox „N Fach/Fächer mit parallelen Übungsgruppen“ mit Liste und Hinweis; sonst „Keine offenen Gruppenentscheidungen.“ Button „Stundenplan öffnen“ | – | :167 |
| Karte „Zugänge“ | 8 Zeilen: Stud.IP / WebSSO, QIS (Prüfungsverwaltung), IDM Account-Manager, ILIAS, E-Mail (LUIS), Matrix-Chat, LUHKI, GitLab. Badges: Stud.IP „LUH-ID gespeichert“ (ok) oder „fehlt“ (warn); sonst „eigener Zugang · user“ (ok), „wie X“ (info) oder „nicht gesetzt“ (neutral). Stift: Stud.IP → `#/settings?tab=account`, sonst Zugangsdialog | – | :131, 168, 175 |
| Abschnitt „Uni-Dienste“ | Kacheln `.mod-card` (Link, neuer Tab): Icon, Name, Beschreibung, Login-Badge, „synchronisiert“ (ok), „Noten-Abruf“ (info) oder „öffnen ↗“ | – | :170–171 |

#### B.9.1 Modal „Zugang: <Dienst>“ (`credDialog`, views-misc.js:133–150)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Hinweis | dienstspezifisch (QIS eigenes Passwort, IDM wie QIS, sonst „wie Stud.IP“) | – | :135 |
| Radio „Eigene Zugangsdaten“ | Benutzername, Passwort (Platzhalter „•••••••• (leer lassen = behalten)“) | `PUT /credentials/:key {user,password}` | :136–137, 146 |
| Radio „Gleiches Passwort wie [Select]“ | andere Dienste zur Auswahl | `PUT /credentials/:key {same_as}` | :138, 145 |
| Radio „Nicht speichern“ | löscht den Zugang | `PUT /credentials/:key {clear:true}` | :139, 144 |
| Abbrechen/Speichern | Toast „Zugang gespeichert“; Fehler als Toast (4 s) | – | :140–149 |

### B.10 Community (`#/community`), views-misc.js:180–184

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Titel | „Community“, Unterzeile „Lösungen vergleichen, Fragen stellen, Lerngruppen.“ | – | :181 |
| Badge (warn) | „Vorbereitet, noch nicht verbunden“ und Erklärtext | – | :182 |
| Liste | „Eigene Lösungen freiwillig teilen – geplant“, „Lösungswege anderer Studierender vergleichen – geplant“, „Fragen und Antworten pro Modul – geplant“ | – | :183 |

### B.11 Einstellungen (`#/settings`), views-misc.js:187–253

API: `GET /settings`, `GET /courses`, `GET /modules`, `GET /sync/status`, `GET /credentials`, `GET /terms`. Linke Navigation `.set-nav` mit 4 Buttons: Module & Wochentests (book), Lernzeit & Verfügbarkeit (clock), Zugang & Darstellung (user), Erweitert (settings). Der Tab-Wechsel passiert nur im Speicher (:216, 218).

#### B.11.1 Tab „Module & Wochentests“ (:197–203)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Kopf | Badge „N aktiv“ und Erklärtext | – | :197 |
| Checkbox „Gemeinsamen Wochentest pro Modul automatisch erstellen“ (`#sAutoTests`) | Toast „Gespeichert“ | `PUT /settings {auto_tests}` | :198, 223 |
| Segment „Standard-Testdauer“ | 15, 30, 60 Min., „Eigene“ (`prompt` „Testdauer in Minuten:“); Toast „Testdauer gespeichert“ | `PUT /settings {test_minutes}` | :198, 222 |
| Modulzeile (Klick klappt auf/zu) | Farbpunkt, Name, „N Kurse“, Badge „kein Wochentest“ oder „1 gemeinsamer Test pro Woche · N min“; inaktive Module blass | – | :199, 219 |
| · Checkbox „aktiv“ | Toast „Gespeichert“ | `PATCH /modules/:id {active}` | :199, 221 |
| · Zahnrad | Modal „Modul bearbeiten“ (B.4.3) | `PATCH /modules/:id` | :199, 220 |
| Aufgeklappt: Tabelle Stud.IP-Kurs / Art / Modul | Art-Select (Vorlesung, Übung, Hörsaalübung, Gruppenübung, Tutorium, Labor, Seminar, Sonstiges), Toast „Gespeichert“. Modul-Select (+ „– kein Modul –“), Toast „Zuordnung gespeichert“. Leer: „Keine Kurse zugeordnet.“ | `PATCH /courses/:id {kind}`; `POST /courses/:id/module {module_id}` | :200, 225–226 |
| Karte „Ohne Modul (nicht eingeplant)“ | pro Kurs ein Modul-Select | `POST /courses/:id/module` | :201 |
| Chip „+ Modul anlegen“ | Modal „Neues Modul“ (Name), Abbrechen/„Anlegen“ | `POST /modules {name}` | :202, 227 |
| Chip „Zuordnung automatisch prüfen“ | Toast „N Kurse zugeordnet, M unsicher“; bei unsicheren Zuordnungen Modal „Unsichere Zuordnungen“ (Liste „Kurs → Vorschlag“, OK) | `POST /modules/auto-assign` | :202, 228 |
| Zusammenfassung | „Deine Einstellungen: …“ | – | :203 |

#### B.11.2 Tab „Lernzeit & Verfügbarkeit“ (:217)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| „Lernkombination“ (primary, `#openCfg`) | Dialog B.2.17 | `GET/PUT /settings` | :217, 250 |
| „Verfügbarkeit & Sperrzeiten“ (`#openAvail`) | Dialog B.3.4 | `GET/PUT /settings` | :217, 251 |
| Text „Aktuell: …“ | Fächer pro Tag, Minuten, Lernzeit, freie Tage, Fahrtzeit | – | :217 |

#### B.11.3 Tab „Zugang & Darstellung“ (:204–212, 214)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Karte „Stud.IP-Zugang“ | Badge „gespeichert“ oder „fehlt“; Hinweis „… für den Sync um 8 und 15 Uhr.“ | – | :204 |
| · Felder LUH-ID, WebSSO-Passwort | Platzhalter „•••••••• (leer lassen = behalten)“ bzw. „noch nicht gesetzt“ | – | :205 |
| · „Zugang speichern“ (primary) | Toast „Zugang gespeichert“ | `PUT /credentials {user,password}` | :206, 229 |
| · „Dateien jetzt holen (ohne KI)“ | Toast „Dateien werden geholt…“, dann pollBg | `POST /sync?ai=false` | :206, 230 |
| „Semester“ | Name, Beginn, Ende, Speichern; Toast „Semester gespeichert“ | `PUT /terms {name,start,end}` | :207, 231 |
| „Anzeigename“ | Input (Platzhalter „z. B. Ahmad H.“), Speichern; Toast „Gespeichert“, danach **Seiten-Reload** | `PUT /settings {user_name}` | :208, 247 |
| „Darstellung“ (Segment) | Automatisch / Hell / Dunkel → `setTheme` | – | :209, 232 |
| „Stift & Touch“ (Select) | „Finger darf schreiben (Handballen wird bei Stift ignoriert)“ / „Nur Stift schreibt, Finger navigiert“; Toast „Gespeichert“ | `PUT /settings {pen_input}` | :210, 233 |
| „Schreibhand“ (Segment) | Rechtshänder / Linkshänder; Hinweis zur geteilten Ansicht (35 %); Toast „Schreibhand gespeichert“ | `PUT /settings {hand}` | :211, 246 |
| Karte „Auf dem iPad benutzen“ | Badge „…“ → „WLAN-Zugriff aktiv“ (ok) oder „nur auf diesem PC“ (warn). Laden: „Netzwerk wird geprüft…“; Fehler: „Netzwerkinfo nicht verfügbar.“ 5 Schritte: Firewall-Befehl (`netsh … localport=<port>`), `serve.py --lan` (+ Status), WLAN-URLs, PIN (groß), „Zum Home-Bildschirm“. Warnbox zu eduroam und Mobilem Hotspot (`http://192.168.137.1:<port>`) | `GET /network` | :212, 234–245 |

#### B.11.4 Tab „Erweitert“ (:213–214, 187–191)

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Karte „Sync-Protokoll“ | Checkbox „Lernkalender nach dem Sync automatisch auffüllen“ (Toast „Gespeichert“); Einträge „✅/❌ Datum – Meldung (90 Zeichen)“, scrollbar bis 200 px. Leer: „Noch kein Sync.“ | `PUT /settings {auto_plan}` | :213, 224 |
| Karte „Diagnose“ | Text-Block: Browser, Fenster, Pixelverhältnis, Design, Adresse, „Module-Version: v=25“, Fehlerzahl und Fehlerliste. Button „Kopieren“ (Toast „Diagnose kopiert“) | – | :188–189, 248 |
| „PDF-Anzeige testen“ / „Test starten“ | „Prüfe…“; ohne PDF „Keine PDF vorhanden.“; sonst Zeilen zu HTTP-Status, pdf.js, Canvas und Konva plus Vorschaubild; Fehler rot | `GET /library`, `GET /files/:id/content` | :190, 249 |

### B.12 Globale Zustände

| Element/Funktion | Was der Nutzer sieht/tut | API | Datei:Zeile |
|---|---|---|---|
| Fehler-Toast | JS-Fehler und unbehandelte Promises: „Fehler: …“ (5 s, höchstens einmal in 8 s); gespeichert in `state.errors` (max. 30); „ResizeObserver loop“ wird ignoriert | – | app.js:51–54 |
| Skeleton, Offline, Fehler | s. A | `GET /bg` (Wiederholversuch) | app.js:66–71 |

---

## C) Globale Shell

**Gerüst** (index.html:21–46): `.shell#shell` (Grid aus Sidebar und `.main`); darin `header.header` und `main#view`. Außerhalb liegen `nav.mobile-nav#mobileNav` und `div#overlay` (Container für Modals und Drawer). Das Script ist ein ES-Modul `app.js?v=27`; style.css und editor.css haben ebenfalls v=27.

**Sidebar** (app.js:10–20; style.css:46–63)
- Marke: Logo-Kachel 30 px mit Gradient (accent → #8b5cf6) und Icon `graduation`, Text „UniFlow AI“.
- Einträge in dieser Reihenfolge (Route, Label, Icon):

| # | Route | Label | Icon |
|---|---|---|---|
| 1 | dashboard | Übersicht | home |
| 2 | plan | Lernkalender | calendar |
| 3 | timetable | Stundenplan | clock |
| 4 | modules | Meine Module | book |
| 5 | files | Dokumente & Notizen | folder |
| 6 | exams | Tests & Wiederholung | exam |
| 7 | services | Uni & Noten | graduation |
| 8 | community | Community | users |

- Fuß (mit Trennlinie): „Einstellungen“ (settings, `#/settings`) und „Einklappen“ (panel-left, `#collapseBtn`).
- Aktiver Eintrag: Hintergrund accent-soft, Text accent-text. Bei `#/doc` ist „Dokumente & Notizen“ aktiv.
- Einklappen: `#collapseBtn` schaltet `.shell.collapsed` (248 px → 68 px, Labels ausgeblendet, Icons zentriert) und speichert localStorage `sidebar=min|full`.
- `.nav` scrollt selbst; die Höhe nutzt 100dvh und den Safe-Area-Abstand unten.

**Header** (index.html:31–40; app.js:16–28; style.css:65–72, 325–327)
- Höhe 56 px, sticky, Hintergrund surface mit 88 % Deckkraft und Blur 10 px.
- `#menuBtn` (menu-Icon, nur ≤900 px): öffnet die Sidebar als Off-Canvas plus `.backdrop#sideBd`.
- Suche `#globalSearch`:
  - Input „Suche nach Dateien, Modulen, Themen…“ mit Hinweis „Strg K“.
  - Ab 2 Zeichen, Debounce 220 ms, `GET /search?q=` (Backend: bis 5 Module, bis 20 Dateien; durchsucht Name, KI-Titel, Themen und Fach).
  - Popover: Module (Farbpunkt, Name, „Modul“) → `#/modules/:id`; Dateien (Typ-Icon, Titel, „Fach · Typ“) → `#/doc/:id`. Leer: „Keine Treffer“.
  - Esc schließt; Klick außerhalb schließt; Strg/Cmd+K fokussiert das Feld. Ein Klick auf ein Ergebnis leert das Feld.
- Sync-Chip `#syncChip`: läuft ein Job, „↻ <Task> läuft…“ (Abfrage `GET /bg` alle 3 s, Sync-Button gesperrt); danach Toast mit der Meldung (oder „Fertig“) und Neuladen der Route. Sonst „✓/⚠ Zuletzt synchronisiert: HH:MM“ (Tooltip: letzte Meldung) oder „ⓘ Noch kein Sync“ (`GET /sync/status`).
- `#syncBtn` „Sync“: `POST /sync`, Toast „Synchronisierung gestartet“, dann Abfrage.
- `#themeBtn`: wechselt Hell → Automatisch → Dunkel → Hell. Icon Mond bei dunkel, sonst Sonne. Toast „Design: Hell/Automatisch/Dunkel“. Gespeichert in localStorage `theme`. Ein Inline-Script im `<head>` setzt `data-theme` vor dem Rendern (Standard light).
- `#profileBtn`: im HTML mit Tooltip „Profil“, wird zu Uhr-Icon „Zeitmesser“ und öffnet den Timer.
- `.avatar#avatar`: 34 px Kreis, Initialen aus `settings.user_name` (Standard „AH“), Tooltip „Angemeldet mit deiner LUH-ID“, nicht klickbar.

**Mobil ≤900 px** (style.css:235–253)
- Die Shell hat eine Spalte; die Sidebar wird fixiert, versteckt (`translateX(-100%)`) und öffnet mit `.open`.
- Sync-Chip und `#profileBtn` sind ausgeblendet. `.content` bekommt unten 5rem Abstand; der Drawer wird 100 % breit.
- `.mobile-nav`: festes 5er-Grid unten (mit Safe-Area): Start (home), Kalender (calendar), Module (book), Dokumente (folder), Mehr (settings → `#/settings`). Aktiv: accent-soft.

**Body-Klassen und Modi**

| Klasse | Gesetzt durch | Wirkung | style.css |
|---|---|---|---|
| `doc-open` | viewDoc | `html` und `body` scrollen nicht; Header und Mobile-Nav ausgeblendet; doc-view 100dvh hoch. Ab 901 px: Sidebar fest auf 68 px, Labels und Badges ausgeblendet, `#collapseBtn` ausgeblendet. `.doc-top` 46 px (52 px bei grobem Zeiger) | :412–452 |
| `fullscreen-doc` | `#docFull` (oder Editor `toggleFullscreen`) | Sidebar, Header und `.doc-top` ausgeblendet; Shell einspaltig; doc-view 100vh; `#fsExit` sichtbar | :230, 425, 432, 444–446 |
| `exam-focus` | runTest bei offenem Test | Sidebar und Header ausgeblendet, Shell einspaltig | :212 |
| `html.ed-inking` | Editor beim Schreiben | Skript-Hinweis mit Deckkraft .25, nicht klickbar | :498 |

**z-Ebenen**

| Element | z-index |
|---|---|
| header | 15 |
| backdrop | 19 |
| sidebar | 20 |
| mobile-nav | 30 |
| script-hint | 30 |
| drawer | 40 |
| fs-exit | 40 |
| timer | 45 |
| modal | 50 |
| toast | 60 |

**localStorage-Schlüssel:** `theme`, `sidebar`, `mod-mode`, `lib-mode`, `cal-side`, `doc-split`, `uniflow-doc-tabs`.

**PWA** (manifest.webmanifest): name „UniFlow AI – Lern-App“, short_name „UniFlow“, display standalone, theme #4f5bd5, background #f6f7fb, Icons icon.svg und apple-touch-icon 180 px. In index.html: `apple-mobile-web-app-capable` und `viewport-fit=cover` mit `maximum-scale=1`.

**Breakpoints**

| Breite | Wirkung |
|---|---|
| 1500 px | kompakte Wochenansicht |
| 1400 px | Seitenspalte im Kalender standardmäßig aus |
| 1366 px | Testraster zweispaltig |
| 1100 px | cols-3 → 2; cal2 einspaltig; `.hide-s` in der doc-top aus; `#docStatus` aus |
| 900 px | Mobil-Layout |
| 820 px | Grids einspaltig; Einstellungen einspaltig |
| 640 px | Testraster einspaltig |
| `pointer: coarse` | doc-top 52 px |

---

## D) Design-Tokens (style.css)

### D.1 Variablen in `:root` (:2–12) und im Dunkelmodus

Dunkel gilt bei `[data-theme=dark]` (:13–19) und bei `prefers-color-scheme: dark` ohne gesetztes Theme (:20–28, identische Werte).

| Variable | Hell | Dunkel |
|---|---|---|
| --bg | #f6f7fb | #0f1117 |
| --surface | #ffffff | #171a23 |
| --surface-2 | #f1f3f9 | #1f2330 |
| --line | #e5e8f0 | #262b3a |
| --line-strong | #d3d8e4 | #333a4d |
| --text | #171a26 | #e8eaf2 |
| --text-2 | #4b5168 | #b3b9cc |
| --muted | #7a8199 | #7f879d |
| --accent | #4f5bd5 | #7b86f0 |
| --accent-strong | #3f4bc2 | #6a76e8 |
| --accent-soft | #eceefc | #232848 |
| --accent-text | #3a45b4 | #a9b1ff |
| --ok / --ok-soft | #1f9d5b / #e3f6ec | #3fbf7c / #173327 |
| --warn / --warn-soft | #d9851e / #fdf0dc | #e9a04a / #3a2a14 |
| --bad / --bad-soft | #d64545 / #fbe5e5 | #ef6b6b / #3d1d1d |
| --info / --info-soft | #2f7fd1 / #e4effb | #5aa0e8 / #172a40 |
| --sh-sm | 0 1px 2px rgba(20,24,40,.05) | 0 1px 2px rgba(0,0,0,.4) |
| --sh | 0 4px 16px rgba(20,24,40,.06) | 0 4px 16px rgba(0,0,0,.4) |
| --sh-lg | 0 16px 40px rgba(20,24,40,.14) | 0 16px 40px rgba(0,0,0,.6) |
| --r-sm / --r / --r-lg | 8px / 12px / 16px | gleich |
| --sidebar / --sidebar-min / --header | 248px / 68px / 56px | gleich |
| --font | "Inter", "Segoe UI", system-ui, -apple-system, Roboto, sans-serif | gleich |
| --t | .16s ease | gleich |

**Nicht als Token definiert:**
- Abstände: alles fest in rem.
- Radien 18px (folder-card, quick-card, mod2), 10px, 9px, 6px und 999px (Pills).
- z-Ebenen.
- Feste Hex-Farben:
  - Logo-Gradient #8b5cf6.
  - Dateifarben (views-lib.js:7): vorlesung #e5484d, uebung #2f7fd1, skript #d9851e, klausur #8b5cf6, loesung #1f9d5b, notebook #7c3aed, whiteboard #0ea5a0, image #1f9d5b, sonstiges #7a8199.
  - Ordner: Standard #4f8ef7, eigene Ordner #8b93a8.
  - Modul-Standardfarbe #4f5bd5.
  - Notizbuch-Linien #e6e9f0, Whiteboard #fafbfd.
  - Legende Sperrzeit #999.
  - Modal-Abdunkelung rgba(10,12,24,.45), Backdrop rgba(0,0,0,.35).

### D.2 Typografie

- **Schrift:** Inter von Google Fonts (400/500/600/700, `display=swap`). Fallback: Segoe UI, system-ui, -apple-system, Roboto, sans-serif. Monospace (`.nonpdf`): ui-monospace, Consolas, monospace.
- **Body:** 14.5px/1.5. Überschriften: Gewicht 650, letter-spacing -.01em.

| Element | Größe |
|---|---|
| h1 | 1.45rem; überschrieben durch `.page-head h1` mit 1.9rem/700/-.02em; mobil 1.25rem |
| h2 | 1.1rem |
| h3 | .95rem |
| h4 | .85rem in text-2 |
| `.small` | .82rem |
| `.tiny` | .74rem |
| `.kpi b` | 1.35rem/700 |
| `.score` | 2rem/800 |
| `.timer` | 1.05rem/700, tabular-nums |

- Es werden auch die Gewichte 550 und 650 benutzt, geladen sind aber nur 400 bis 700 in Hunderterschritten.

**Animationen:**
- fade (opacity und translateY 4px): .content .18s, modal .12s, toast .15s.
- slide für den Drawer: .18s.
- Skeleton-Schimmer: 1.2s.
- `prefers-reduced-motion` schaltet alle Animationen ab.

### D.3 Komponenten

| Komponente | Werte | style.css |
|---|---|---|
| `.btn` | inline-flex, gap .45rem, padding .5rem .85rem, radius 8px, 1px line-strong, bg surface, 500, lh 1.2; hover surface-2; aktiv translateY(1px); disabled .55 | :81–82 |
| `.btn.primary` | bg/border accent, #fff; hover accent-strong | :83 |
| `.btn.ghost` | transparent, text-2; hover surface-2/text | :84 |
| `.btn.danger` | color bad, border bad 40 % (color-mix); hover bad-soft | :85 |
| `.btn.ok` | bg/border ok, #fff | :87 |
| `.btn.sm` / `.icon` / `.icon.sm` | padding .3rem .6rem, .82rem / 34×34 px, padding .45rem / 28×28 px, padding .25rem | :86 |
| `.card` | surface, 1px line, radius 12px, padding 1.1rem 1.2rem, sh-sm; `.flat` ohne Schatten; `.pad-0` | :88–89 |
| `.card-head` | flex between, gap .6rem, mb .8rem; h2 flex gap .45rem | :90–91 |
| `.badge` | pill, padding .1rem .5rem, .72rem, 600, accent-soft/accent-text | :96 |
| Badge-Varianten | ok (ok-soft/ok), warn, bad, info, neutral (surface-2/text-2) | :97 |
| `.status-pill` | .75rem 600, padding .1rem .5rem, pill. geplant info-soft/info; in_bearbeitung accent-soft/accent-text; erledigt ok; teilweise warn; nachholen bad; verschoben, übersprungen, frei, leer surface-2/muted | :134–135 |
| `.chip` | padding .25rem .65rem, pill, 1px line, surface, .8rem, text-2; `.on` accent-soft, Rahmen transparent, accent-text, 600 | :98–99 |
| `.chips .chip` (Bibliothek) | .45rem .95rem, .86rem, radius 10px, bg surface-2 | :379 |
| `.seg` | surface-2, radius 8px, padding 3px, gap 2px; Button .35rem .7rem, radius 6px; aktiv surface + sh-sm | :108–110 |
| `.seg.pill` | padding 4px, radius 10px; Button .4rem .9rem, radius 8px; aktiv bg accent, #fff | :328–329 |
| `.tabs` | Unterlinie line; Button .6rem .85rem, text-2; aktiv accent-text mit 2px accent unten | :105–107 |
| `.input` | padding .5rem .7rem, radius 8px, 1px line-strong; Fokus: Rahmen accent und Ring 0 0 0 3px accent-soft | :100–101 |
| `label.field` | .85rem, text-2, margin .55rem 0 | :102 |
| `.progress` | 6px, Spur surface-2, Füllung accent (.ok → ok), Übergang width .3s; `.mod2` 7px in Modulfarbe | :116–117, 404 |
| `.modal` / `.modal-box` | fixed inset, padding 1rem / surface, radius 16px, Breite min(620px,100%) (wide 900px), max-height 92vh, padding 1.3rem 1.4rem, sh-lg; `.modal-foot` flex-end, gap .5rem, mt 1rem | :125–127 |
| `.drawer` | rechts fixiert, Breite min(440px,100%), border-left, sh-lg; head padding .9rem 1.1rem; body 1rem 1.1rem; foot .8rem 1.1rem | :129–133 |
| `.toast` | unten 1.2rem, zentriert, bg text / color bg (invertiert), .55rem 1rem, pill, sh-lg, .9rem | :128 |
| `.statbar` | flex, gap .5rem 1.6rem, surface, 1px line, radius 12px, padding .6rem 1rem, .9rem text-2; b 1.05rem text | :468–469 |
| `.page-head` | flex, align end, between, gap 1rem, wrap, mb 1.2rem; `.sub` muted; h1 1.9rem/700 | :76–77, 324 |
| `.content` | padding 1.4rem 1.6rem 3rem, max 1480px; `.wide` max none, padding .8rem 1rem 1rem. Pro View per Inline-Style: Dashboard 1120, Module 1480, Karteikarten 820, Uni & Noten 1120, Community 860, Einstellungen 1180, Kalender und Stundenplan 1600, Testlauf 900 | :73–74 |
| `.kpi`, `.empty`, `.skeleton`, `.tbl` | kpi b 1.35rem; empty zentriert, muted, 2rem 1rem; tbl .86rem, th .76rem uppercase .04em muted; Zeilen-Hover surface-2 | :118–124 |
| `.item`/`.list` | .6rem .5rem, Trennlinie, radius 8px; `.title` 550 mit Ellipse; `.sub` .8rem muted | :111–114 |
| Sidebar/Nav | Sidebar padding .75rem .6rem; Link .55rem .7rem, radius 8px, text-2, 500; aktiv accent-soft | :46–63 |
| Header-Suche | Input pill, bg surface-2, padding .5rem .8rem .5rem 2.2rem; Max-Breite 520px; `.kbd` .68rem, radius 5px; Popover radius 12px, sh-lg, max 60vh | :66–71, 326 |
| `.avatar` | 34px, Kreis, accent-soft/accent-text, .78rem 700 | :325 |
| **Kalender cal2** | Grid minmax(0,1fr) + 286px. main: radius 16px, padding .9rem 1rem 1rem. Raster 44px + 7 Spalten, gap 0 6px. Tageskopf radius 12px, heute accent-soft. Ring 18px conic (innen 11px). Achse .72rem. Spalte mit Stundenlinien (--hour 60px), heute accent-soft 40 %, `.drop` accent-soft. Termin radius 10px, padding .35rem .5rem, bg Farbe 13 % gemischt, linker Rand 3px. Lernblock gestrichelt in info 60 % und 7 %. Jetzt-Linie 2px accent mit 8px-Punkt. Add-Button 34px rund accent. `.narrow`. Legende .75rem | :330–354, 455–466, 481 |
| Seitenkarten / Donut / Mini-Kalender | side-card radius 16px, padding 1rem 1.1rem. Donut 104px (innen 76px). legend2 .8rem. todo-item radius 12px. quick-grid 2 Spalten. Mini-Kalender 7 Spalten, Zellen radius 8px, min 32px; heute accent/#fff; ausgewählt accent-soft; Punkte 4px | :355–367 |
| Tagesansicht day2 | Termin radius 12px, padding .55rem .9rem, bg Farbe 10 %, linker Rand 4px; Icon-Kachel 38px radius 10px; study info 8 %; frei schraffiert ok 12 %. task2-Checkbox 22px rund, an = accent | :368–378 |
| Monat | `.cal-month` 7 Spalten, gap .4rem; Zelle min 86px, radius 8px; Farbbalken 4px | :187–192 |
| `.pkg` | radius 8px, padding .5rem .6rem, surface-2, linker Rand 4px (--pc), .83rem; erledigt .7; nachholen bad-soft; teilweise warn-soft; Aufgaben-Kacheln 18px (done ok, late bad) | :179–186 |
| `.pkg-card` | linker Rand 4px, radius 12px, padding .7rem .9rem | :309 |
| `.task-row` | Checkbox 22px, radius 6px, an = ok; erledigt durchgestrichen; nachholen bad | :194–199 |
| Stundenplan tt | Raster 52px + 7×minmax(120px,1fr), min-width 900px. Kopf sticky .82rem. Termin radius 8px, .72rem, bg Farbe, #fff, linker Rand 3px rgba(0,0,0,.18). study: surface mit Rahmen in Paketfarbe (links 4px). Varianten nicht_teilnahme/ausfall/verschoben. Frei schraffiert 135°, Sperrzeit 45°. Import-Tabelle `.unc` warn-soft, `.off` .5 | :289–306 |
| **Bibliothek** | lib-grid auto-fill minmax(150px), gap 1.2rem 1rem. Mappe 112×86px radius 12px (Lasche 46×16). Vorschau 112×86px radius 6px. Liste: Spalten 44px 1fr 110px 120px 90px 36px, mini 36px. folder-grid minmax(290px), folder-card radius 18px, padding 1.4rem 1.2rem 1.1rem, Welle (radial-gradient), Mappe 92×70, Initialen 44px radius 12px. quick-card radius 18px; quick-list minmax(230px); quick-item radius 12px; Farbkachel 38px radius 10px. Mobil: minmax(120px), Mappe 96×74 | :264–286, 380–395 |
| **Modulkarten** | `.mod2-grid` minmax(300px), gap 1.2rem. `.mod2` radius 18px, Rahmen Farbe 22 % gemischt, padding 1.2rem 1.3rem 1.1rem, Gradient 160° (Farbe 14 % → surface bei 72 %). Deko 44px, Deckkraft .18. Initialen 48px radius 12px. Name 1.12rem/700. Beschreibung 2 Zeilen. next-Box radius 12px. Kennzahlen b 1.05rem. Liste: Spalten 44px 1fr 120px 120px 120px 36px. Moduldetail-Kopf: Farbkachel 46px radius 12px | :152–163, 396–407 |
| `.mod-card` (Dienste) | linker Streifen 4px (--mc), Hover translateY(-2px) + sh | :141–145 |
| **test-card** | oberer Rand 4px (--mc); test-grid auto-fill minmax(280px); Löschen 40×40 (Hover bad); test-go min-height 40px. Frage `.q` radius 12px (good ok / bad bad); `.opt` radius 8px; Feedback surface-2 | :204–211, 310–313, 470–473 |
| Karteikarte `.fc-card` | radius 16px, padding 1.6rem, min 180px, zentriert; Antwort accent-text | :213–214 |
| Dokumentansicht | `.doc-top` 46px. Tabs 32px radius 9px max 210px, aktiv accent-soft/600. Status-Select 32px. Bereiche: Grid, gap .4rem, padding .4rem; geteilt 65fr/35fr (Rechtshänder 35/65), Notizen 300px/340px. Notizspalte radius 12px. Trenner-Griff 4×48px (Hover accent). `.pane-bar` 34px. `.script-hint` oben 120px, rechts 22px, radius 12px, linker Rand 3px accent, Blur 8px. `.fs-exit` pill, Blur 8px | :217–229, 257–262, 433–451, 485–498 |
| Zeitmesser | Widget 260px, radius 16px, sh-lg; Zeit 2rem/700 tabular (abgelaufen bad); Pill accent/#fff, 600 | :318–321 |
| Einstellungen | `.set-layout` 240px + 1fr; Nav sticky, Buttons min 44px, aktiv accent-soft | :475–482 |
| Wochenleiste (Dashboard) | 7 Spalten; Tag radius 8px, surface-2, .78rem; heute outline 2px accent | :146–149 |
| Status-Punkt `.sd` | geplant info, in_bearbeitung accent, erledigt ok, teilweise warn, nachholen bad, frei/leer line-strong | :177 |

---

## E) Platzhalter, nicht oder nur halb funktionierende Stellen

1. **Community** (views-misc.js:180–184): reiner Platzhalter. Badge „Vorbereitet, noch nicht verbunden“, drei Punkte mit „geplant“, kein API-Aufruf.
2. **Profil/Avatar**: `#profileBtn` heißt im HTML „Profil“, ist aber in Wahrheit der Zeitmesser (app.js:16). Es gibt keine Profilseite; der Avatar ist nicht klickbar (`cursor: default`). Unter 900 px ist `#profileBtn` ausgeblendet (style.css:242), dort erreicht man den Timer nur über die Editor-Funktion.
3. **Modul-Kebab auf der Ordnerkarte** (views-lib.js:84 erzeugt `data-menu="module:ID"`): `itemMenu` hat keinen Zweig für `module`. Der Code fällt in den Dokument-Zweig, `lib.files.find` liefert undefined, und `f.course_id` wirft einen TypeError (Fehler-Toast). Nicht funktionsfähig (:125).
4. **Zeitmesser-Alarm**: `new AudioContext().resume()` spielt keinen Ton (views-doc.js:154); man sieht nur einen Toast.
5. **Diagnose** zeigt fest „Module-Version: v=25“, die Assets sind aber v=27 (views-misc.js:188).
6. **`#docStatus`**: wird in `mountDoc` angesprochen und in CSS gestylt (style.css:419), existiert aber im Markup der doc-top nicht. Der Aufruf bewirkt nichts (views-doc.js:127).
7. **„Titel / Dauer ändern“**: die Dauer ist immer mit 45 vorbelegt statt mit dem echten Wert (views-plan.js:216).
8. **Testlauf**: Antworten liegen nur im Speicher. „Abbrechen“ oder Navigieren verwirft sie, es gibt keinen Speicher-Endpunkt; der Timer läuft serverseitig ab started_at weiter.
9. **Zugänge in Uni & Noten**: IDM, ILIAS, E-Mail, Matrix, LUHKI und GitLab werden nur gespeichert („als Übersicht“, views-misc.js:168). Genutzt werden nur Stud.IP und QIS.
10. **Zugangsdialog**: die Felder unter „Eigene Zugangsdaten“ sind immer sichtbar, egal welches Radio gewählt ist.
11. **Header-Suche**: CSS rechnet mit einem Lupen-Icon (padding-left 2.2rem, `.header .search .ic`), im Markup gibt es aber keins.
12. **Drag & Drop**: nur in Woche/3 Tage (`.cal2-col`). Monatszellen nehmen keine Drops an. Im Stundenplan sind Lernslots nicht ziehbar, weil bindCalendar fehlt. Ein Drop ändert nur das Datum, nicht die Uhrzeit.
13. **Schnell hinzufügen → „Testtermin“**: navigiert nur zu `#/exams`; einen Testtermin kann man nicht anlegen (views-plan.js:135).
14. **Seitenspalte Tag → „Hinzufügen“** bei „Heutige Aufgaben“ öffnet „Neues Lernpaket“, nicht „Aufgabe hinzufügen“ (views-plan.js:137).
15. **Gegensätzliche Chip-Logik**: in der Lernkombination bedeutet „an“ Lerntag, in der Verfügbarkeit bedeutet „an“ lernfrei. Beide schreiben `free_days` und `hours_per_day`.
16. **Zustand nicht in der URL**: Einstellungs-Tabs, Moduldetail-Tab und -Modus sowie Bibliothek-Sortierung und Typ-Filter liegen nur im Speicher. Deep-Links funktionieren nur für `?tab=` beim ersten Aufruf.
17. **Status-Select in der Dokumentansicht**: bei Status „neu“ sind „neu“ und „gelesen“ gleichzeitig `selected`, angezeigt wird „gelesen“ (views-doc.js:24).
18. **`#docMenu`** (mobil) öffnet die Sidebar ohne Backdrop (views-doc.js:35).
19. **Native Dialoge**: `confirm()` und `prompt()` stehen noch an vielen Stellen: Überspringen, Paket löschen, Aufgabe löschen, Test abgeben, Termin löschen, Ordner anlegen/umbenennen/färben/löschen, Datei umbenennen, Papierkorb, eigene Testdauer. Laut Kommentar in views-misc.js:84 ist `confirm()` in der iPad-App unzuverlässig; nur „Test löschen“ nutzt ein eigenes Modal. „Endgültig löschen“ im Papierkorb fragt gar nicht nach.
20. **Anzeigename speichern** lädt die ganze Seite neu.
21. **Kein Sidebar-Eintrag** für `#/cards` (nur über den Link in der Tests-Statusleiste) und `#/tasks`.
22. **CSS ohne Verwendung in den Views**: `.doc-bar`, `.cal-week`, `.cal-day` (nur als Drop-Selektor), `.lib`/`.lib-nav`, `.filters`, `.tt-day`, `.today-card`, `.doc-tab.home`, `.cal-day-view`, `.pkg.uni`, `.legend`. Außerdem `.greet h1` 1.6rem, das von `.page-head h1` (1.9rem) überschrieben wird.
23. **Backend-Routen ohne Aufrufer im Frontend** (auch nicht in editor.js): `/overview`, `/plan`, `/plan/items` (POST/PATCH/DELETE), `/plan/generate`, `/subjects`, `/tasks/history`, `/timetable/free`, `/timetable/exceptions`, `/files/:id/analyze`, `DELETE /modules/:id`. Für das Löschen eines Moduls gibt es keine Oberfläche.
