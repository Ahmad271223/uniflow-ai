# Raumfinder für die Universität Hildesheim (07.11.2026)

Auftrag des Inhabers (07.11.2026, Version 1.0): Raumfinder für die Uni Hildesheim wie für die LUH
(docs/RAUMFINDER-2026-11-05.md). Quelle ist der **öffentliche Raumplan im LSF** (HIS-QIS/LSF, ohne Anmeldung erreichbar,
`robots.txt` ohne Einschränkung, geprüft 07.11.2026 mit 63 lesenden Aufrufen, je ≥ 2,5 s Abstand). Der genaue Aufbau der
Seiten steht in `~/Studora-Builds/hildesheim/RAUMPLAN-STRUKTUR-2026-11-07.md` (Rohseiten daneben unter `raumplan/`).
Bisher nur iPad (Swift-Kern); Python/Web/Windows zeigen für Hildesheim weiter den Standort der Hochschule.

## 1. Quelle

| | |
|---|---|
| Raumsuche | `GET rds?state=change&type=5&moduleParameter=raumPlanSearch&…&raum.stxt=<Text>&search_start=Suche+starten` – Teilwortsuche in Raumname und Kurzbezeichnung, `*` erlaubt. Mehrere Treffer: Seite „Ihre Auswahl war nicht eindeutig“ mit Links (`raum.rgid`); genau einer: direkt sein Belegungsplan (Raum im `<h4>` mit `webInfoRaum`-Link); keiner: leerer Plan |
| Raum-Einzelansicht | `…publishConfFile=webInfoRaum&…&raum.rgid=<rgid>`: Raum, Gebäude (`k_gebaeude.gebid`), Kurzbezeichnung, Stockwerk („Ebene 1“), Raumart. Die „Raumadmin“-Personen liest die App nie |
| Gebäude-Einzelansicht | `…publishContainer=buildingContainer&k_gebaeude.gebid=<gebid>`: Campus, Adresse (PLZ, Ort, Straße), OpenStreetMap-Marker (Koordinaten) |
| Belegung | `state=wplan&raum.rgid=<rgid>&week=<KW>_<Jahr>&…&P.vx=lang`: Termine je Wochentag mit Zeit, Rhythmus (Einzeltermin, wöchentlich, 14-tägl.), Art, Start/Ende; Lehrpersonen und Einrichtungen bleiben weg |
| Kopfzeilen | `User-Agent: StudiNow/1.0 (+https://studinow.app; support@studinow.app)`, eigene Cookies, 15 s Zeitlimit |

**Feste Gebäudetabelle** (`UniFlowCore/Hildesheim/HildesheimRoomsData.swift`, 45 Gebäude aus dem LSF, gelesen 07.11.2026):
Kennung, Name, Campus, Adresse, Koordinaten und die Präfixe der Raumcodes (`HC.I` → Gebäude I (Hauptcampus),
Universitätsplatz 1). 17 Gebäude haben im LSF keine Straße: dann gilt die Campus-Adresse von der Anfahrtsseite der Uni
(Hauptcampus Universitätsplatz 1, Bühler-Campus Lübecker Straße 3, Samelsonplatz 1, Domänenstraße 1, Schützenallee 41b),
mit dem Hinweis „Das LSF nennt für dieses Gebäude keine Straße; gezeigt wird die Adresse des Campus.“ Koordinaten gibt es
für 38 Gebäude, dann zeigt die Route genau dorthin.

Raumcodes: `<Campus>.<Gebäude>.<Etage>.<Raum>` (`HC.I.1.Hörsaal 1`, `BC.LN.0.03`, `KC.48.0.04`, `HC.I.-1.06`), ohne
Gebäudeteil `SH.0.23` (Schützenallee) und `WL.2.01` (Leesterhaus). Der LSF-iCal des Stundenplans schreibt
`Gebäude I (Hauptcampus) - HC.I.1.Hörsaal 1`. Campus-Kürzel: HC Hauptcampus, BC Bühler, SC Samelson, KC Domäne,
SH Schützenallee.

**Wenige Anfragen:** Ein Raumcode mit bekanntem Gebäude braucht **keine** Anfrage (Tabelle). Suche, Raum- und
Gebäudeseite 30 Tage im Cache, „nichts gefunden“ 1 Tag, Belegung 6 Stunden; Datei
`Application Support/StudiNow-Rooms/hildesheim-cache.json` (nur geparste Ergebnisse, nie Seiten). Aufgelöst wird erst beim
Antippen. Ohne Netz: alter Stand mit Hinweis, sonst Google-Maps-Suche nach dem Text.

## 2. In der App

- **Raumfinder** (Gruppe „Alltag“): Hochschulweiche über `GET /api/rooms/campuses` (`finder`, `source.key`:
  `standortfinder` LUH, `lsf` Hildesheim, HsH ohne – „folgt“, Suchfeld ausgeblendet). Hildesheim: Suche im LSF
  (Beispiele „Hörsaal“, „HC.I“, „Forum“, „Bühler“, „Seminarraum“), Treffer mit Gebäude, Etage, Adresse; dazu die vier
  Standorte und die Liste **„Gebäude im LSF (44)“** (Hauptcampus zuerst). Ein Gebäudename als Suchbegriff („Forum“) steht
  als Gebäude vorneweg.
- **Detail**: Google Maps / Route zu Fuß / Apple Karten, Angaben (Gebäude, Campus, Etage, Raum, Raumart, Adresse), Links
  „Raum im LSF“ und „Gebäude im LSF“ (In-App-Browser), Abschnitt **Belegung** („Belegung dieser Woche laden“, dann KW mit
  Pfeilen; erst auf Antippen geladen).
- **Stundenplan-Termin**: Raum mit LSF-Code → Antippen startet sofort die **Route zu Fuß** (ohne Anfrage), „Im Raumfinder
  anzeigen“ zeigt Adresse und Lage; Gebäudename („Forum“) → Route zum Gebäude; unbekannter Text → Raumfinder mit
  vorbelegter Suche (`TerminDetail.route`, unverändert).

## 3. Einheitliche Form

- `GET /api/rooms/search?q=` (Hochschule aus den Einstellungen oder `university=`): Hildesheim liefert alle Treffer auf
  einer Seite, Orte wie `Rooms.place` plus `rgid`, `gebid`, `campus`, `kind`, `source: "lsf"`.
- `GET /api/rooms/resolve?text=`: Status `found` (Raumcode oder ein Treffer), `building`, `ambiguous` (Kandidaten),
  `campus`, `not_found`, `offline`, `online`; `source` = LSF.
- `GET /api/rooms/campuses`: für Hildesheim `finder: true`, `source` (LSF), `buildings` (44 Orte).
- Neu: `GET /api/rooms/place?rgid=` (Raum mit Gebäude, Etage, Raumart, Adresse) und
  `GET /api/rooms/plan?rgid=&week=` (`{week, semester, room, entries: [{weekday, day, start, end, title, rhythm, kind,
  start_date, end_date}], stale, message}`); ohne LSF-Leser 404.

## 4. Dateien und Tests

| Teil | Dateien |
|---|---|
| Kern (neu) | `Hildesheim/HildesheimRooms.swift` (Adressen, Leser, Raumcodes, Orte, `HildesheimRoomFinder` mit Cache), `Hildesheim/HildesheimRoomsData.swift` (Gebäudetabelle), `Hildesheim/HildesheimRoomsDemo.swift` (nachgebaute Seiten mit erfundenen Räumen für Tests) |
| Kern (geändert) | `Rooms/LocalRooms.swift`: `configure(hildesheim:)`, Weiche in Suche/Auflösen, `campuses`, Endpunkte `place` und `plan`. Ohne gesetzten Leser bleibt alles wie am PC (Python-Fixtures `RoomsTests` unverändert grün) |
| App | `Services/LocalBackendHost.swift` (Leser setzen; unter XCTest Demo), `Views/Rooms/RoomFinderViews.swift` (Weiche, Gebäudeliste, LSF-Links, `RoomPlanSection`), Kommentar in `Views/Timetable/TerminDetailViews.swift` |
| Tests | Kern `HildesheimRoomsTests` (10: Adressen, Seiten, Raumcodes, Tabelle, Orte, Auflösen mit/ohne Netz, Cache, Belegung, Endpunkte); App `HildesheimRoomFinderAppTests` (3: Seite mit Suche, Detail und Belegung; Termin mit Route; Regeln) – Bildschirmfotos mit `TEST_RUNNER_UF_SCREENSHOT_DIR` |

Offen: Python/Web/Windows (`app/rooms.py`) kennen den LSF-Raumplan noch nicht; die Standorttabelle in
`packages/shared-contracts/rooms.json` nennt für den Bühler-Campus „Lübecker Straße 1“ (Anfahrtsseite), das LSF
„Lübecker Straße 3“ – beim nächsten Lauf von `tools/gen-rooms-fixture.py` angleichen. Echte Räume der Uni wurden nur beim
Erkunden gelesen; die Tests laden nie etwas.
