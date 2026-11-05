# Raumfinder mit automatischem Google-Maps-Link (05.11.2026)

Auftrag des Inhabers (05.11.2026): „https://standortfinder.uni-hannover.de/de/ kannst du den raumfinder einbauen aber mit
automatische google maps link“. StudiNow hat jetzt die Seite **Raumfinder** (iPad, Web, Windows; Gruppe „Alltag“ neben der
Mensa, `#/raumfinder`), und **überall, wo ein Raum steht**, ist die Angabe ein Link zum Ort mit Google-Maps-Link. Frei in
jedem Tarif, ohne Anmeldung.

## 1. Quelle: Standortfinder der LUH

| | |
|---|---|
| Seite | https://standortfinder.uni-hannover.de/de/ (öffentlich, ohne Anmeldung; robots.txt ohne Einschränkung) |
| Suche | `POST https://standortfinder.uni-hannover.de/search` mit `search=<Text>&page=<n>` (Formular), 100 Treffer je Seite, `count` gesamt |
| Einzelobjekt | dieselbe Adresse mit `building_qr`, `room_qr` oder `facility_qr` (in StudiNow nicht nötig) |
| CSRF | die Seite schickt `X-CSRFToken` aus dem Cookie `csrftoken`; am 05.11.2026 setzte die Startseite kein Cookie und die Suche ging ohne Token. StudiNow schickt zuerst ohne Token; bei **403** holt es das Cookie von der Startseite und wiederholt einmal mit `X-CSRFToken` und Cookie (gilt für die Sitzung). |
| Kopfzeilen | `User-Agent: StudiNow/1.0 (+https://studinow.app; support@studinow.app)`, `Referer` der Startseite, `X-Requested-With: XMLHttpRequest` |
| Antwort | `{count, data: [...], search_term}`; je Treffer `item_type` (1 Raum, 2 Gebäude, 3 Einrichtung, `lr01` Lernraum-Gebäude, aus `map.js`), `item_id`, `item_name`, `building_id`, `building_name`, `room_nr`, `room_name`, `room_id`, `floor_nr`, `street`, `house_number`, `zip_code`, `city`, `lat`, `lon`, `is_position_correct`, `room_floorplan_url`, `room_url`, `building_url` (info.cafm.uni-hannover.de), `building_bf`, `room_bf`, `bf_building_info`, `bf_room_info`, `extra_info` (Einrichtungen: Beschreibung, Website, Öffnungszeiten) |
| Barrierefreiheit | Felder aus `map.js` (`createBFBuildingInfoTable`, `createBFRoomInfoTable`): Stellplätze, Zugang, Aufzug, Toiletten, Orientierung, Ruheraum; Raum: Zugang, Rollstuhlplätze, Akustik; Status `BF_YES`/`BF_NO`/`BF_RESTRICTED`. In allen gespeicherten Antworten leer (`null`) – die Seite zeigt sie nur in einer Entwicklerfassung; StudiNow zeigt sie, sobald es sie gibt, sonst „Keine Angaben zur Barrierefreiheit im Standortfinder.“ |
| Nicht übernommen | Lernraum-Modus (`/lr_data`, freie Lernplätze); Bilder; Kartenkacheln des Uni-Tileservers |

**Wenige Anfragen:** Eine Suche je Begriff; Antworten mit Treffern **30 Tage** im Cache (Räume ziehen selten um),
„nichts gefunden“ **1 Tag**; höchstens 500 Einträge. Am PC/Dienst `data/rooms/search-cache.json` (für alle Nutzer
gemeinsam, nur öffentliche Daten), auf dem iPad `Application Support/StudiNow-Rooms/search-cache.json`. Raumangaben werden
erst beim **Antippen** aufgelöst, nie im Hintergrund. Ohne Netz: Treffer aus dem Cache mit Hinweis „zuletzt geladener
Stand“, sonst ein Google-Maps-Link, der nach dem Text sucht. Entwicklung: 13 Anfragen am 05.11.2026 (je ≥ 3 s Abstand),
gespeichert in `~/Studora-Builds/standortfinder/` und als Fixtures in `packages/shared-contracts/fixtures/rooms/raw/`
(F102, E214, A003, 1101, 3403, Hauptgebäude, Bibliothek, Audimax, ohne Treffer). Tests laden nie etwas.

## 2. Google Maps automatisch

Jeder Ort (Treffer, aufgelöste Raumangabe, Standort) trägt `maps`:

| Schlüssel | Adresse |
|---|---|
| `google` | `https://www.google.com/maps/search/?api=1&query=<Ziel>` |
| `google_route` | `https://www.google.com/maps/dir/?api=1&destination=<Ziel>&travelmode=walking` |
| `google_app` | `comgooglemaps://?q=<Ziel>` |
| `google_app_route` | `comgooglemaps://?daddr=<Ziel>&directionsmode=walking` |
| `apple` / `apple_route` | `https://maps.apple.com/?q=<Name>&ll=<Ziel>` bzw. `?daddr=<Ziel>&dirflg=w` |

Ziel: `lat,lon` (höchstens 6 Nachkommastellen, z. B. `52.38255,9.71785`), wenn `is_position_correct` stimmt; sonst die
Adresse („Welfengarten 1, 30167 Hannover“), ohne Adresse „<Name>, Leibniz Universität Hannover“. Kodiert wird alles außer
`A–Z a–z 0–9 - . _ ~` (`%2C` für das Komma). Knöpfe: **„In Google Maps öffnen“**, **„Route“** (zu Fuß), **„In Apple
Karten“**. Auf dem iPad nimmt StudiNow die Google-Maps-App, wenn sie installiert ist (`canOpenURL`, dafür
`LSApplicationQueriesSchemes: comgooglemaps` in project.yml), sonst die Webadresse (Safari bzw. Universal Link); am PC und
im Web immer die Webadresse in einem neuen Tab. **Datenschutz:** An Google oder Apple geht nichts von selbst – erst beim
Antippen eines Karten-Links (docs/release/DATENSCHUTZ.md Abschnitt 4 und 12).

## 3. Raumangaben überall als Link

Wo ein Raum steht, ist er antippbar (`UFRoomLink` auf dem iPad, `.room-link` im Web, beide mit Stecknadel):

| Ort | iPad | Web/Windows |
|---|---|---|
| Stundenplan und Lernkalender: Termin-Panel einer Serie | `EventDrawer` (TimetableShared.swift) | `openEvent` (views-tt.js) |
| Lernkalender: Einzeltermin aus dem Stud.IP-Kalender | `DatedEventDialog` (PlanActions.swift) | – (öffnet dort kein eigenes Panel) |
| Klausurtermine: Karte „Nächste Klausuren“ der Übersicht | `UpcomingExamsList` (ExamDates.swift) | `examsCard` (exams.js) |
| Modulseite: „Nächste Klausur“ | `ModuleNextExam` | – |

Antippen öffnet ein Blatt bzw. einen Dialog („Raum“) mit dem aufgelösten Ort (`GET /api/rooms/resolve`). „Online“, „Zoom“,
„BigBlueButton“ & Co. ohne Raumnummer bleiben Text. Vorlesetext: „Raum 1101 - F102“, Hinweis „Zeigt den Ort mit Link zu
Google Maps“.

### Erkannte Schreibweisen (LUH; app/rooms.py `parse`, Rooms.swift `parse`)

| Angabe | Ergebnis |
|---|---|
| `F102`, `Hörsaal F 303`, `Raum E214: Großer Physiksaal` | Raum F102 / F303 / E214 (1–2 Großbuchstaben, 3 Ziffern, optional Buchstabe; Leerzeichen erlaubt) |
| `1101 - F102`, `1101-E214`, `Raum 1101-E214`, `1101/F102`, `Gebäude 3403, Raum A003` | Gebäude + Raum |
| `F102 (1101)`, `F102 (Geb. 1101)` | Raum + Gebäude |
| `1101.001.F102` (Raum-ID des Standortfinders) | Gebäude, Etage, Raum |
| `Gebäude 1101, Raum 029` | Gebäude + Raum mit Ziffern (nur mit Gebäude) |
| `Hauptgebäude, F142`, `Hauptgebäude Herrenhausen, A003`, `Lessinghaus` | Gebäudename (Tabelle `luh_buildings`: Hauptgebäude 1101, Hauptgebäude Herrenhausen 4105, Hauptgebäude Physik 3701, Hochhaus Conti 1502, Hochhaus Appelstraße 3408, WMR-Gebäude 3403, Lessinghaus 1112, Kesselhaus 1208, Pferdestall 3440 – alle aus den Antworten des Standortfinders) bzw. Wort auf „…gebäude“/„…haus“ |
| `3403` | Gebäude (vierstellig; Jahreszahlen 19xx/20xx nie) |
| `Hörsaal F 303 · Hörsaal F 102`, `A; B`, `A | B`, Zeilen | bis zu vier Teile, jeder für sich |
| `Seminarraum`, `Raum C`, `Pool 1` | keine Nummer: Hinweis und Google-Maps-Suche nach „Leibniz Universität Hannover <Text>“ |
| `Online`, `Online (Zoom)` | Online-Termin, kein Ort; `Online / Raum F102` zählt als Raum |

Auswahl (`choose`): Treffer mit gleicher Raumnummer (ohne Leerzeichen, groß), dann gleiches Gebäude (Nummer oder Name),
dann Etage. Genau einer → „found“; mehrere → „ambiguous“ (bis zu 10 zur Auswahl, z. B. A003 in 16 Gebäuden); keiner, aber
Gebäude bekannt → zweite Suche nach dem Gebäude („building“: „Raum Z999 steht nicht im Standortfinder; gezeigt wird das
Gebäude.“); sonst „not_found“ mit Text-Suche. Weitere Status: `unknown` (keine Nummer), `offline`, `online`, `campus`,
`search` (HsH/Hildesheim).

## 4. Hochschule Hannover und Universität Hildesheim

Beide haben **keinen öffentlichen Raumfinder** (geprüft 05.11.2026). StudiNow zeigt den Standort der Hochschule mit
Adresse und Kartenlink, immer mit dem Hinweis **„Ort laut Hochschule; genaue Lage ohne Gewähr“**. Tabelle in
`packages/shared-contracts/rooms.json` (Quelle je Standort verlinkt):

| Hochschule | Standort | Adresse | erkannt an |
|---|---|---|---|
| HsH | Campus Linden | Ricklinger Stadtweg 120, 30459 Hannover | „Campus Linden“, „Ricklinger Stadtweg“, „Linden“, Raumkennung `1H.1.01` (Muster `1<Buchstabe>.<Ziffer>.<2 Ziffern>`, Gebäude 1 = Linden laut Seiten der HsH, z. B. „1J.2.26“) |
| HsH | Campus Expo Plaza | Expo Plaza 2, 30539 Hannover | „Expo Plaza“, „Lissabonner Allee“ |
| HsH | Campus Kleefeld | Blumhardtstraße 2, 30625 Hannover | „Kleefeld“, „Blumhardtstraße“ |
| HsH | Campus Ahlem | Heisterbergallee 10A, 30453 Hannover | „Ahlem“, „Heisterbergallee“ |
| Hildesheim | Hauptcampus (Marienburger Höhe) | Universitätsplatz 1, 31141 Hildesheim | „Hauptcampus“, „Marienburger Höhe“, „Universitätsplatz“ (das LSF schreibt den Campus in Klammern) |
| Hildesheim | Bühler-Campus | Lübecker Straße 1, 31141 Hildesheim | „Bühler“, „Lübecker Straße“ |
| Hildesheim | Samelsonplatz | Samelsonplatz, 31141 Hildesheim | „Samelsonplatz“ |
| Hildesheim | Kulturcampus Domäne Marienburg | Domänenstraße, 31141 Hildesheim | „Domäne“, „Kulturcampus“ |

Quellen: Standortseiten der HsH (hs-hannover.de → Gebäudemanagement → Standorte und Anfahrt: Linden, Expo Plaza,
Kleefeld, Ahlem) und die Anfahrtsseite der Uni Hildesheim (uni-hildesheim.de/en/ueber-uns/anfahrt/). Eine öffentliche
Gebäudeliste mit Gebäudekennungen gibt es bei keiner der beiden; die Lagepläne sind Bilder. Ohne erkannten Standort sucht
der Link nach „Hochschule Hannover <Angabe>“ bzw. „Universität Hildesheim <Angabe>“. Für die LUH zeigt die Seite zusätzlich
fünf Standorte (Welfengarten, Conti-Campus, Nordstadt/Appelstraße, Herrenhausen, Garbsen) mit Koordinaten aus dem
Standortfinder.

## 5. Einheitliche Form (Python = Swift)

- `GET /api/rooms/search?q=&page=0` → `{query, count, page, pages, items: [Ort], stale, message, source}`; leerer Text: keine Anfrage.
- `GET /api/rooms/resolve?text=&university=` → `{text, university, parts: [{text, room, building, building_name, floor,
  campus, online, query, linkable, status, place, candidates, maps, note}], source, stale, message}`; ohne `university`
  die Hochschule aus den Einstellungen.
- `GET /api/rooms/campuses?university=` → `{university, name, finder, campuses: [Ort], note, source}`.
- Ort: `{id, type (room/building/facility/campus), title, subtitle, room, room_name, building, building_name, floor,
  floor_label („Erdgeschoss“, „1. Obergeschoss“, „1. Untergeschoss“), address {street, house_number, zip, city, line},
  lat, lon, position_ok, note, floorplan_url, room_url, building_url, website, opening_hours_url, description,
  accessibility {building, room: [{key, title, status, text}]}, maps, source}`. Nur https-Links werden übernommen.

## 6. Umsetzung

| Teil | Dateien |
|---|---|
| Daten | `packages/shared-contracts/rooms.json` (Quelle der Wahrheit), `fixtures/rooms/raw/*.json` (Antworten 05.11.2026), `fixtures/rooms/cases.json` (erzeugt), `tools/gen-rooms-fixture.py [--check]` (prüft die Datei, schreibt `RoomsData.swift` und die Fälle) |
| Python (PC, Windows, Dienst) | `app/rooms.py` (Zerlegen, Treffer, Auswahl, Abruf mit CSRF-Wiederholung, Cache), `app/rooms_api.py` (Routen), Eintrag in `app/server.py`; `rooms.json` im Windows-Paket (`uniflow-backend.spec`) |
| Swift-Kern (iPad ohne PC) | `Rooms/Rooms.swift`, `Rooms/LocalRooms.swift` (`URLSessionRoomFinderHTTP`, Cache, `RoomsEndpoints`), `Rooms/RoomsDemo.swift` (`RoomFinderDemoHTTP`: sechs gespeicherte Treffer für App-Tests), `Rooms/RoomsData.swift` (erzeugt) |
| iPad | `Views/Rooms/RoomFinderViews.swift` (Seite, Detail, `RoomResolveSheet`, `UFRoomLink`, Raumplan im In-App-Browser `SFSafariViewController`), Route `.rooms` / `#/raumfinder`, Menüpunkt „Raumfinder“ (Symbol `map-pin`) in „Alltag“; Links in TimetableShared, PlanActions, ExamDates |
| Web/Windows | `app/static/rooms.js`, `rooms-logic.js`, `rooms.css`, `.room-link` in `style.css`; Route in `app.js` (mit Klick-Weiche für `.room-link`), Gruppe „Alltag“ in `shell-nav.js`, Links in `views-tt.js`, `exams.js` |
| Tests | `tests/test_rooms.py` (11), `RoomsTests.swift` (9), `tests/js/rooms.test.mjs` (4), `RoomFinderAppTests.swift` (5: Kartenlinks, Menü, Seite mit Suche und Detail, Stundenplan-Termin mit antippbarem Raum, HsH), Nav-Tests (`DesignShellAppTests`, `AbnahmeV1AppTests`, `shell-redesign`, `mensa`), `LayoutWidthAuditTests` (Seite „raumfinder“), App-Pfade (`app-paths.json`) |

Neue Gebäudenamen oder Standorte: `packages/shared-contracts/rooms.json` anpassen, `.venv/bin/python tools/gen-rooms-fixture.py`
ausführen.
