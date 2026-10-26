# Prüfbericht iPad-App ↔ Web-App

**Geprüfter Stand:** Commit `6a7e286` auf `develop` (25.10.2026). Zeilenangaben beziehen sich auf diesen Stand und
können sich inzwischen verschoben haben.

**Wie geprüft:** Drei unabhängige Code-Prüfungen haben jede Web-Funktion (`app/static/*.js`, `app/server.py`) mit dem
iPad-Code (`apps/apple/UniFlow`) verglichen: Lernkalender/Stundenplan, Übersicht/Module/Dokumente/App-Rahmen,
Tests/Zeitmesser/Uni & Noten/Community/Einstellungen. Dazu kamen ein maschineller Abgleich der Server-Endpunkte,
eine Suche nach Platzhaltern, die Tests des Swift-Kerns und eine Syntaxprüfung aller App-Dateien (beides im
Linux-Container). **Nichts davon ist ein Test auf dem Gerät oder im Simulator.** Mit ✔ markierte Befunde habe ich
zusätzlich selbst im Code nachgelesen; die übrigen stammen aus den Code-Prüfungen und sind beim Beheben zu bestätigen.

> **Reihenfolge geändert:** Es gilt [`docs/AUFTRAG-APPSTORE-V1.md`](AUFTRAG-APPSTORE-V1.md), Abschnitt 3. V1 nutzt
> den Apple-Editor; **F1 (UniFlow-Editor 1:1) gehört zu V2**. Für V1 vorrangig: K-Punkte, F3 (lokales Backend) mit F5
> (Stud.IP direkt), damit auch F2 (Offline).

**Für die Mac-Sitzung:** Bitte in der Reihenfolge K → F → A abarbeiten. Je Punkt: beheben, bauen, mit den **echten
Daten** im Simulator prüfen (schreibende Aktionen nur nach Zustimmung des Inhabers, siehe `docs/UEBERGABE-MAC.md`),
`docs/paritaet/status.json` aktualisieren, hier in der Spalte „Erledigt“ Commit und Prüfung eintragen, mit `[skip ci]`
committen. Server-Punkte (S) betreffen auch das Web und den PC-Server – vorher mit dem Inhaber absprechen, damit nicht
zwei Sitzungen gleichzeitig `app/` ändern.

## Stand in Zahlen

| | |
|---|---|
| Funktionen laut `WEB-IPAD-PARITAET.md` | 509 – davon 365 kompiliert, 4 getestet, 0 visuell geprüft, 140 nicht begonnen |
| Server-Endpunkte, die das Web nutzt | 86 – davon ruft die iPad-App 77 auf (zusätzlich `POST /grades/sync`, das das Web laut Abgleich nicht direkt nutzt); es fehlen `GET/PATCH /files/{id}`, `GET /files`, `POST /files/{id}/opened`, `POST /files/{id}/assets`, Aufnahmen (`GET/POST /files/{id}/recordings`, `DELETE /recordings/{id}`) und `GET /network` (bewusst) |
| Platzhalter, leere Aktionen, dauerhaft gesperrte Knöpfe | keine gefunden |
| Swift-Kern `UniFlowCore` | 48/48 Tests grün |
| App-Dateien | 49, Syntax fehlerfrei; App-Tests laut Mac-Sitzung 33/33 grün |
| Passwortfelder / Senden von Passwörtern | keine (bewusst; nur die Server-PIN) |

## K – Kritisch (Datenverlust, falsches Schreiben, Bedienung blockiert)

| ID | ✔ | Problem | Ort | Folge | Lösungsvorschlag | Abnahme | Erledigt |
|---|---|---|---|---|---|---|---|
| K1 | ✔ | Testabgabe: Das iPad bricht jede Anfrage nach 25 s ab, der Server bewertet aber synchron per KI (bis 600 s) | `Services/APIClient.swift:27`; `Exams/ExamsPage.swift:414-423`; `app/server.py:659-665`, `app/ai.py:28` | „Bewertung fehlgeschlagen“, obwohl der Server weiterbewertet; Kalender-Aufgabe bleibt offen (`POST /tasks/:id/status` übersprungen); erneutes Abgeben bewertet doppelt und überschreibt das Ergebnis | Für `submit` eigene, lange Zeitgrenze (≥ 660 s) und Knopf während der Abgabe sperren; nach Zeitüberschreitung `GET /tests/:id` abfragen und bei gesetztem `submitted_at` das Ergebnis zeigen statt erneut abzugeben | Abgabe eines echten Tests (nach Zustimmung) mit Bewertung > 25 s zeigt das Ergebnis, Aufgabe ist erledigt, keine zweite Bewertung | |
| K2 | ✔ | „Lernkombination ändern“ und „Persönliche Verfügbarkeit“ zeigen Vorgabewerte, bis die Einstellungen geladen sind; Ladefehler wird mit `try?` verschluckt | `Views/PlanDialogs.swift:167-195`; `Timetable/TimetableShared.swift:325-400` | „Speichern“ schreibt Vorgaben über die echten Werte (`subjects_per_day` 1, `hours_per_day` 2.00, alle Tage Lerntage, …) und **löscht alle Sperrzeiten** | „Speichern“ erst nach erfolgreichem Laden freigeben; bei Ladefehler Fehlermeldung statt Formular (wie Web: Dialog öffnet erst nach dem Laden); nur Felder senden, die geladen wurden | Mit getrennter Verbindung lässt sich nicht speichern; mit Verbindung bleiben unveränderte Werte und Sperrzeiten erhalten | |
| K3 | ✔ | Dokument öffnen führt in die alte `LibraryView` mit dem alten Editor | `Views/MainView.swift:23-24` → `Views/Views.swift:50-194`; `Services/DocumentStore.swift:128-133` | Notizbücher/Whiteboards öffnen nicht (verlangt `%PDF` von `/content`, Server 404), Bilder auch nicht; Öffnen wird nicht gemeldet (`POST /files/:id/opened`, `PATCH /files/:id {status:"gelesen"}` fehlen) → „Neu aus Stud.IP“, „Zuletzt“, Modulzähler bleiben falsch; `task` und `page` aus der Route werden verworfen (kein „Erledigt“-Knopf, kein Sprung zur Seite); Dateien aus inaktiven Kursen/Papierkorb nicht auffindbar | Neue Dokumentansicht 1:1 nach `views-doc.js` (gehört zu F1): `GET /files/:id`, Meldung `opened` und `gelesen`, `last_page`, Knopf „Erledigt“ (`POST /tasks/:id/status`), Seite anspringen, Notizbuch/Whiteboard ohne Server-PDF, Bilder und andere Typen wie `mountDoc` | Aus Übersicht, Kalender, Bibliothek und Suche: PDF, Notizbuch, Bild öffnen; danach unter „Zuletzt“ sichtbar, „Neu“ zählt herunter; „Weiterlernen“ zeigt „Erledigt“ | |
| K4 | ✔ | Hochformat (≤ 900 pt) mit offenem Dokument: keine Seitenleiste, keine Kopfzeile, keine untere Leiste | `Design/AppShell.swift:174-188` | Man kommt nicht mehr aus dem Dokument heraus | Wie im Web eine Dokument-Kopfzeile mit Menüknopf (`#docMenu`), der die Seitenleiste als Schublade öffnet, plus „Zurück“ | Im Hochformat Dokument öffnen und über Menü zu jeder Ansicht wechseln | |
| K5 | | Knopf „Trennen“ in der alten Dokumentbibliothek | `Views/Views.swift:91`; `Services/Session.swift:48-51` | Ein Tipp trennt die Verbindung und löscht die PIN | Aus der Dokumentansicht entfernen (gibt es im Web dort nicht); Trennen nur in den Einstellungen mit Rückfrage | | |
| K6 | | Uni & Noten, Zugangsdialog: „Nicht speichern“ / „Gleiches Passwort wie“ | `Services/ServicesPage.swift:450-461`; `app/server.py:1300-1308` | Löscht Benutzer und Passwort in der `.env` am PC ohne Rückfrage; auf dem iPad nicht wiederherstellbar | Rückfrage mit Hinweis „Passwort lässt sich nur in der Web-App am PC wieder eintragen“ | | |
| K7 | | Papierkorb „Endgültig löschen“ ohne Rückfrage (auch im Web) | `Library/LibraryDialogs.swift:294`; `views-lib.js:124` | Ein Tipp löscht eigene Dokumente endgültig | Rückfrage ergänzen – im iPad (Touch) und mit S4 auch im Web | | |
| K8 | | Import meldet am Ende immer „Importiert“; Bilder aus der Fotomediathek als `Bild N.jpg` / `image/jpeg`, auch HEIC (unsicher) | `Library/LibraryDialogs.swift:64-68, 103-105`; `app/server.py:1427-1443` | Man hält einen fehlgeschlagenen Import für gesichert; HEIC-Daten könnten als unbrauchbare Datei gespeichert werden | Wie Web beim ersten Fehler abbrechen und den Fehler zeigen; Bilder vor dem Hochladen in JPEG umwandeln, Dateinamen aus dem Original übernehmen | | |
| K9 | | Bescheinigung öffnen prüft den HTTP-Status nicht | `Services/ServicesPage.swift:246-255`; `Services/APIClient.swift:47-51` | Bei 404 wird die Fehlermeldung als `.pdf` gespeichert, QuickLook zeigt eine kaputte Datei | Status prüfen, Fehlermeldung zeigen | | |
| K10 | | Zahlenfelder `UFNumberField` (`TextField(value:format:)`) übernehmen den Wert evtl. erst bei Return/Fokuswechsel (unsicher) | `Design/UFKit.swift:636-647`; genutzt u. a. `Plan/PlanActions.swift:361, 418, 458, 504`, `PlanDialogs.swift:130`, `TimetableShared.swift:341-344` | Direkt „Speichern“ getippt → alter Wert gesendet (Dauer, Lernzeit, Verfügbarkeit) | Im Simulator prüfen; sonst Text-Bindung mit sofortiger Umwandlung | Wert eintippen und ohne Return speichern → neuer Wert kommt an | |
| K11 | | Aufgabennummer `nr` als Zahl gelesen (`.double ?? 0`), Web nutzt `String(q.nr)` | `Exams/ExamsPage.swift:293, 343` | Liefert die KI `"nr"` als Text, landen alle Antworten unter „0“ und überschreiben sich; Bewertung findet keine Antworten | Schlüssel wie im Web als Zeichenkette aus Zahl **oder** Text bilden | | |

## F – Fehlt komplett

| ID | Was fehlt | Hinweise | Erledigt |
|---|---|---|---|
| F1 | **Dokumentansicht und PDF-Editor 1:1** (27 + 107 Einträge, höchste Priorität des Inhabers) | Leisten und Menüs wie `editor.js`; Text/Formen/Bilder/Haftnotizen anlegen und bearbeiten (heute nur Anzeige); Lasso über alle Objekte; Lineal; Zoom-Ansicht; Seitenverwaltung vollständig (vor/nach/letzte, duplizieren, kopieren, leeren, Papierkorb, Vorlage wechseln, gehe zu Seite); Rückgängig für alles; KI-Seitenleiste (Anbindung an den Server); Aufnahmen; Export einzelner/ausgewählter Seiten, Drucken; Tastenkürzel; Tabs mit gespeichertem Zoom/Position; geteilte Ansicht wie `views-doc.js`; Skript-Hinweis; Vollbild mit „Vollbild beenden“; „Zeitmesser“ im Zubehör-Menü; Stift & Touch / Schreibhand aus den Einstellungen (siehe A-S1). Endpunkte: `/files/:id`, `/opened`, `/assets`, `/recordings`. Inventar: `docs/paritaet/web-editor.md` | |
| F2 | **Offline-Zwischenspeicher für alle Seiten** | Nur die Übersicht nutzt `RemoteData`/`UFRemote`. Kalender, Stundenplan, Module, Dokumente, Tests, Uni & Noten, Einstellungen holen bei jedem Aufruf direkt vom Server (`api.value`) und zeigen ohne PC nur Fehler. Lesende Abrufe über den Zwischenspeicher je Server leiten; schreibende Aktionen offline sperren oder sicher einreihen | |
| F3 | **Betrieb ohne PC: lokales Backend** | SQLite mit dem Schema aus `app/db.py`; Swift-Port von `study.py`, `timetable.py`, `scriptsearch.py`; dieselben Antworten wie die Web-API; Vergleichstests gegen den Python-Server | |
| F4 | QIS direkt vom iPad | Anmeldung auf der echten QIS-Seite durch den Inhaber, Auswertung nach `docs/QIS-STUDIP-STRUKTUR.md`; Bescheinigungen nur auf ausdrücklichen Wunsch | |
| F5 | Stud.IP direkt: Stundenplan und Dateien in App | `seminar-cycle-dates` als Kurszeiten (siehe `docs/QIS-STUDIP-STRUKTUR.md`); direkt geladene Dateien in Bibliothek und Editor öffnen (heute nur QuickLook) | |
| F6 | KI ohne PC | Braucht einen KI-Dienst – kostet Geld, **Entscheidung des Inhabers**. Bis dahin klar „nur mit PC-Server“ anzeigen | |
| F7 | Automatisierte Tests | Keine Tests für Lernkalender, Stundenplan, Module, Dokumente, Tests & Wiederholung; keine Oberflächentests (XCUITest) für die Hauptabläufe | |
| F8 | Bildvergleich Web ↔ iPad | 0 Bildpaare. Voraussetzung: PIN in Safari im Simulator (gibt der Inhaber ein). Ablage und Regeln: `docs/UEBERGABE-MAC.md`, Abschnitt „Bildvergleich“ | |
| F9 | Gerätetest mit Apple Pencil | `docs/MAC-IPAD-CHECKLISTE.md` | |
| F10 | Globaler Fehlerhinweis und Fehlerliste | Web: Toast „Fehler: …“ für unbehandelte Fehler und „Fehler in dieser Sitzung: N“ in der Diagnose (`app.js:51-54`, `views-misc.js:188-189`); iPad sammelt keine Fehler | |
| F11 | Vor einer Veröffentlichung | `NSAllowsArbitraryLoads` entfernen (HTTPS), Datenschutz-Manifest `PrivacyInfo.xcprivacy` fehlt, `TARGETED_DEVICE_FAMILY "1,2"` schließt das iPhone ein, Signierung/Team | |

## A – Abweichungen nach Bereich

### Lernkalender und Stundenplan

Alle Knöpfe, Dialoge und Drawer aus dem Web sind vorhanden und richtig angebunden, inklusive Ziehen & Ablegen und
aller Rückfragen.

| ID | Abweichung | Ort (iPad / Web) | Erledigt |
|---|---|---|---|
| A-P1 | Nach „Lernplan erstellen“ kein Neuladen, wenn man schon auf `view=week&date=<Start>` steht (`router.go` ignoriert gleiche Route) | `PlanDialogs.swift:69-71`, `AppShell.swift:116-117` / `views-plan.js:250` | |
| A-P2 | „Lernplan erstellen“ öffnet auch, wenn die Machbarkeitsabfrage scheitert (Web: kein Dialog); nach „Lernkombination ändern“ behalten „Tage“/„Ersetzen“ alte Werte | `PlanDialogs.swift:15-22, 57` / `views-plan.js:243, 249` | |
| A-P3 | „Aufgabe bearbeiten“ sendet mindestens 5 min (`max(5, …)`), Web den eingegebenen Wert | `PlanActions.swift:367` / `views-plan.js:216` | |
| A-P4 | Randfall 0: Web nimmt bei 0 den Standard (`\|\| 60`), iPad die 0 (`??`); bei „Vorlesung nacharbeiten“ fällt die Aufgabe dann weg | `PlanActions.swift:179, 588, 593` / `views-plan.js:176, 195` | |
| A-P5 | „Neues Lernpaket“: Modul ist 0, bis die Module geladen sind → Paket „Allgemein“ ohne Modul möglich | `PlanActions.swift:491, 510-515, 521-523` / `views-plan.js:236-240` | |
| A-P6 | Tooltip „Frei hh:mm–hh:mm“ fehlt im Wochen- und 3-Tage-Raster | `PlanGrids.swift:165-172` / `views-plan.js:91` | |
| A-P7 | Sperrzeiten: nur `weekday/start/end/title` werden zurückgeschrieben (derzeit keine weiteren Felder) | `TimetableShared.swift:384, 393` / `views-tt.js:86-90` | |

### Übersicht, Module, Dokumente, App-Rahmen

| ID | Abweichung | Ort (iPad / Web) | Erledigt |
|---|---|---|---|
| A-L1 ✔ | Globale Suche kodiert `&`, `+`, `=` nicht („C++“ kommt als „C  “ an) | `ShellState.swift:105` / `app.js:36` | |
| A-L2 | Seitenwechsel schließt offene Drawer/Dialoge nicht (`overlay.closeAll()` fehlt); Dialoge der Übersicht (`ufModal`) liegen nur über der Inhaltsspalte | `AppShell.swift:116-124`, `UFKit.swift:339-341`, `DashboardView.swift:27-37` / `app.js:63`, `core.js:33` | |
| A-L3 | Sync-Chip: „Noch kein Sync“ mit grünem Haken, Fehler mit `info` statt `alert`; Tooltip mit letzter Meldung fehlt; nach App-Start fehlt die Abschlussmeldung eines laufenden Jobs | `AppShell.swift:327-336`, `ShellState.swift:46, 52-56` / `app.js:45, 49` | |
| A-L4 | Offline/Fehler: kein automatischer Neuversuch alle 3 s; Module, Moduldetail, Bibliothek zeigen nur `UFEmpty` statt der Karte „Server nicht erreichbar“; Text weicht ab; HTTP 500 ohne `detail` erscheint als „offline“ | `UFFormat.swift:77-109`, `ModulesPage.swift:15, 221`, `LibraryPage.swift:64` / `app.js:66-71` | |
| A-L5 | Fehler werden mit `try?` verschluckt und danach trotzdem neu geladen (Gesehen, Stern, Ordner anlegen/umbenennen/färben/löschen, Titel, Duplizieren, Papierkorb, Verschieben); „Verschieben“ schließt auch bei Fehler | `DashboardView.swift:281`, `LibraryPage.swift:360`, `LibraryDialogs.swift:89, 225, 234, 243, 334, 351, 364, 403` / `views-lib.js:132`, `app.js:51-54` | |
| A-L6 | Neu-Menü bleibt bei abgebrochener Dateiauswahl offen | `LibraryDialogs.swift:49, 71-83` / `views-lib.js:106` | |
| A-L7 | Wochen-Zusammenfassung zeigt Überschriften/Listen als Rohtext (`#`, `-`) | `ModulesPage.swift:525` / `views-misc.js:64` | |
| A-L8 | Modul bearbeiten: Fehlermeldung ohne „Fehler: “; eigene Testdauer (z. B. 20) wird behalten statt „Standard“; Dokumentzeile „· ca. 0 min“; Farbe aus dem ColorPicker evtl. außerhalb `#rrggbb` (Display P3, unsicher) | `ModulesPage.swift:397, 480, 495, 509, 570-574` / `views-misc.js:51, 54, 56, 58` | |
| A-L9 | Moduldetail A → B (z. B. über die Suche): Tab/Ansicht bleiben, kurz ist noch A zu sehen | `ModulesPage.swift:215-217, 225` / `views-misc.js:28` | |
| A-L10 | Suche: „Keine Treffer“ schon während des Ladens, alte Treffer bleiben stehen, Fehler still; Esc schließt nicht | `ShellState.swift:98-121`, `AppShell.swift:363-394` / `app.js:26, 35-39` | |
| A-L11 | Tooltips der Symbolknöpfe fehlen; Bedienungshilfe-Beschriftung ist nur der Icon-Name | `AppShell.swift:322, 337, 339, 345`, `UFComponents.swift:93` / `index.html:32-38` | |
| A-L12 | Routen: `#/tasks?module=` verliert `module`; `#/files?new=` wird nicht auf „Neu“ abgebildet | `AppShell.swift:81, 84` / `app.js:58`, `views-lib.js:15` | |
| A-L13 | Design „Automatisch“: prüfen, ob die App nach Hell/Dunkel wieder der Systemeinstellung folgt (`preferredColorScheme(nil)`) | `UniFlowApp.swift:30` / `app.js:31` | |

### Tests, Zeitmesser, Uni & Noten, Einstellungen

| ID | Abweichung | Ort (iPad / Web) | Erledigt |
|---|---|---|---|
| A-E1 | Testlauf: beim Öffnen eines schon abgelaufenen Tests fehlt „Zeit abgelaufen – bitte abgeben.“ | `ExamsPage.swift:436-443` / `views-misc.js:112` | |
| A-E2 | Karteikarten: Fehler bei „Richtig/Falsch“ werden verschluckt → nächste Karte, nichts gespeichert; Lade-/Löschfehler erscheinen als „Heute nichts fällig“ | `ExamsPage.swift:506-535` / `views-misc.js:115, 123-125` | |
| A-E3 | Antwort-Entwürfe hängen an der Serveradresse (Adresswechsel → Entwurf scheinbar weg), bleiben nach Löschen des Tests liegen | `ExamsPage.swift:225-233, 256, 275, 283-286` | |
| A-E4 | Zeitmesser: Ende von Countdown/Pomodoro im Hintergrund ohne Mitteilung; Zustand geht verloren, wenn iPadOS die App beendet (iPad-Anpassung: lokale Mitteilung, Zustand sichern) | `Timer/StudyTimer.swift:44-73` / `views-doc.js:149-170` | |
| A-E5 | Löschdialog kürzt den Titel anders als das Web | `ExamsPage.swift:47-52, 214` / `views-misc.js:87` | |
| A-S1 ✔ | „Stift & Touch“ (`pen_input`) und „Schreibhand“ vom Server wirken im Editor nicht: Editor nutzt nur lokal `uniflow.pencilOnly` (Standard „nur Stift“), Schreibhand erst nach Öffnen des Einstellungs-Reiters | `DocumentView.swift:66-67, 266-268`, `SettingsPage.swift:464-466, 531-535` / `views-doc.js:28, 37`, `views-misc.js:210-211` | |
| A-S2 | Art-Auswahl in der Kurstabelle springt nach dem Speichern auf den alten Wert zurück (kein Neuladen) | `SettingsPage.swift:277, 338-339` / `views-misc.js:226` | |
| A-S3 | Karte „Auf diesem iPad“: Abzeichen „mit dem PC verbunden“ fest grün ohne Prüfung | `SettingsPage.swift:552` | |
| A-S4 | „Noten abrufen (sichtbar)“: Text verspricht ein Browserfenster, das am PC aufgeht | `ServicesPage.swift:129-131` / `views-misc.js:162` | |

## S – Server (betrifft Web und iPad, Code in `app/`)

| ID | ✔ | Problem | Ort | Vorschlag | Erledigt |
|---|---|---|---|---|---|
| S1 | ✔ | `PATCH /api/packages/{id}` übernimmt nur `date`, `title`, `sort` – `start_time`/`end_time` werden ignoriert; „Uhrzeit“ und „Beginn (optional)“ beim Lernpaket wirken in Web und iPad nicht | `app/server.py:947-955` | Felder übernehmen (Spalten existieren, `db.py` `add_col("study_packages", "start_time"/"end_time")`), Test ergänzen | S6 (`wip/s6-lernplan-2`): `study.set_package_time`, Aufgaben rücken mit, ungültige Uhrzeit 400; `tests/test_study_plan.py`; auf dem iPad `StudyPlan.setPackageTime` |
| S2 | ✔ | Testbewertung läuft synchron im Request (Ursache von K1) | `app/server.py:659-665` | Bewertung als Hintergrundaufgabe (`/api/bg`) wie die Testerstellung; Client fragt den Stand ab | |
| S3 | | Laut Code-Prüfung wirft das Menü der Modulkarte in der Bibliothek im Web einen TypeError (nicht nachgeprüft) | `app/static/views-lib.js:84, 125` | prüfen und beheben | |
| S4 | | „Endgültig löschen“ ohne Rückfrage (siehe K7) | `app/static/views-lib.js:124` | Rückfrage | |

## Was bereits stimmt

- Lernkalender und Stundenplan: jeder Knopf, Dialog und Drawer, Ziehen & Ablegen, alle Rückfragen des Webs.
- Keine Platzhalter oder leeren Aktionen; 77 von 86 vom Web genutzten Server-Funktionen sind angebunden.
- Kein Passwortfeld, kein Senden von Passwörtern; Stud.IP-Anmeldung nur auf der echten Seite.
- Test-Entwürfe werden bei jeder Eingabe lokal gesichert (Verlassen der Ansicht verliert nichts).
- Zwischenspeicher je Server getrennt; Sicherung beim Speichern im Hintergrund korrigiert; PIN bleibt im Schlüsselbund.

## Startnachricht für die Mac-Sitzung

> Hol mit `git pull` den neuen Stand und lies `docs/PRUEFBERICHT-IPAD.md`. Behebe zuerst K1 bis K4, dann die übrigen
> K-Punkte, dann F1 (Dokumentansicht und PDF-Editor 1:1) und F2 (Offline-Zwischenspeicher), danach die A-Punkte.
> Server-Punkte (S) nur nach Rücksprache mit mir. Trag bei jedem Punkt Commit und Prüfung in die Spalte „Erledigt“
> ein. Prüfen mit meinen echten Daten, schreibende Aktionen nur nach meiner Zustimmung.
