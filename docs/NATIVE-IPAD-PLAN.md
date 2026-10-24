# UniFlow AI als native iPad-App: Migrationsplan (SwiftUI, PDFKit, PencilKit)

Stand: 24.10.2026. Etappe 1 (Phasen 0–4 unten) liegt als Code in `apps/apple` (ungetestet), Verträge in `packages/shared-contracts`. Ziel: Die Handschrift läuft auf dem iPad über Apples eigene Engine (PencilKit) statt über Safari.
Der Rest der App (Stud.IP-Sync, KI, Lernkalender, Stundenplan, QIS) bleibt auf dem PC-Server und wird über die
vorhandene HTTP-API angebunden. Es wird nichts doppelt gebaut.

## Warum nativ

| Thema | Safari-Web-App (heute) | Native App mit PencilKit |
| --- | --- | --- |
| Latenz Stift → Strich | 1–2 Bildschirmframes plus JavaScript | ca. 9 ms, Apple-Vorhersage eingebaut |
| Handballen | eigene Heuristik in `editor.js` | vom System, `drawingPolicy = .pencilOnly` |
| Doppeltippen am Pencil 2 / Squeeze (Pro) | nicht verfügbar | `UIPencilInteraction` |
| Speicherlimit | festes Canvas-Gesamtlimit in Safari | normales App-Speicherbudget |
| Offline | nur Entwurf im Browser | echte lokale Dateien, Sync im Hintergrund |

## Architektur

```
iPad (SwiftUI)                                   PC (bestehend, FastAPI :8765)
┌──────────────────────────────┐                 ┌─────────────────────────────────┐
│ Bibliothek  (List/Grid)      │  GET /api/library│ Stud.IP-Sync, Analyse, KI       │
│ Dokument    PDFView (PDFKit) │  GET /api/files/{id}/content (PDF)                 │
│  └ je Seite PKCanvasView     │  GET/PUT /api/files/{id}/annotations?base_version= │
│    (PencilKit) als Overlay   │  POST /api/ai/tutor, /api/tasks/{id}/status …      │
│ Lernkalender, Module …       │  → zuerst als WKWebView der bestehenden Oberfläche │
└──────────────────────────────┘                 └─────────────────────────────────┘
```

- **Dokumentansicht nativ**: `PDFView` (PDFKit) zeigt die PDF. Pro Seite liegt ein `PKCanvasView` darüber, angebunden über
  `PDFPageOverlayViewProvider` (ab iPadOS 16). `PKToolPicker` liefert Stifte, Radierer (pixel- und strichweise), Lineal,
  Lasso. `drawingPolicy = .pencilOnly`, damit Finger scrollen und zoomen.
- **Übrige Ansichten werden nativ in SwiftUI gebaut** (Übersicht, Kalender, Module, Tests, Uni & Noten) und nutzen
  dieselben Endpunkte wie die Weboberfläche. Eine reine WebView-Verpackung ist kein Ziel; höchstens als Übergang
  während der Entwicklung.
- **Verbindung**: Basis-URL und PIN wie heute (`serve.py --lan`, Cookie `lernapp_pin`). Später optional Bonjour-Suche
  im WLAN (`_uniflow._tcp`), damit die IP nicht eingetippt werden muss.

## Datenformat

Heute speichert der Editor pro Datei ein JSON-Modell (`annotations.data`): Seiten mit `objects`, Striche als
`{type: "stroke", tool, color, width, widths[], opacity, points[x,y,…]}` in PDF-Punkten.

Plan: **beide Formate parallel**, damit PC-Browser und iPad dieselben Notizen sehen.

1. Neues Feld je Seite: `pkdrawing` = Base64 von `PKDrawing.dataRepresentation()` plus `pkVersion`.
2. Konverter in beide Richtungen:
   - PencilKit → JSON: `PKStroke.path` → Punkte (`location`), Breite aus `size` (×Druck), Farbe aus `ink.color`,
     Werkzeug aus `ink.inkType` (`.pen`→`pen`, `.marker`→`marker`, `.pencil`→`pencil`, `.fountainPen`→`fountain`).
   - JSON → PencilKit: Punkte als `PKStrokePoint(location:, timeOffset:, size:, opacity:, force:, azimuth:, altitude:)`.
3. Wer zuletzt schreibt, gewinnt nicht blind: das bestehende `base_version` (409 bei Konflikt) bleibt.
   Die App fragt bei Konflikt wie heute im Browser.
4. Koordinaten: PencilKit-Zeichnung pro Seite in Seitenpunkten (gleiches System wie `points` heute),
   PDF-Drehung (`rotation`) beim Übertragen berücksichtigen.

## Phasen

| Phase | Inhalt | Ergebnis | Aufwand (Abende à 3 h) |
| --- | --- | --- | --- |
| 0 | Mac mit Xcode 16+, Apple-ID; Projekt „UniFlow“ (SwiftUI, iPadOS 17+) | App startet auf dem iPad (kostenlose Signierung, 7 Tage gültig) | 1 |
| 1 | Verbindung: Server-URL + PIN, Bibliothek aus `/api/library`, PDF laden | Dokumente öffnen und lesen | 2 |
| 2 | `PDFView` + `PKCanvasView`-Overlay je Seite, `PKToolPicker`, `.pencilOnly` | Schreiben mit PencilKit | 3 |
| 3 | Speichern: `pkdrawing` je Seite, PUT mit `base_version`, Offline-Warteschlange | Notizen bleiben erhalten, auch ohne WLAN | 3 |
| 4 | Konverter PencilKit ↔ JSON, Server-Feld `pkdrawing`, Browser-Editor zeigt iPad-Striche | gleiche Notizen auf PC und iPad | 3 |
| 5 | Restliche Ansichten nativ in SwiftUI (Übersicht, Kalender, Dokumente, Module, Tests, Noten), Tab-Leiste | komplette App auf dem iPad | 8 |
| 6 | Feinschliff: Seiten hinzufügen (Vorlagen), Lesezeichen, Export als PDF (`PDFDocument` + `PKDrawing.image`) | Funktionsgleichheit mit dem Web-Editor | 4 |
| 7 | Optional: Mac-App über Mac Catalyst aus demselben Code; Apple Developer Program (99 €/Jahr) für dauerhafte Installation/TestFlight | Desktop- und Tablet-App | 2 |

## Änderungen am Server (klein)

- `PUT /api/files/{id}/annotations`: Feld `pages[key].pkdrawing` unverändert speichern (heute schon, weil das JSON frei ist).
- Neuer Endpunkt optional: `GET /api/files/{id}/annotations/meta` (nur Version + Zeitstempel), damit die App schnell prüft,
  ob sie neu laden muss.
- Bonjour-Anmeldung in `serve.py --lan` (Paket `zeroconf`), sobald Phase 1 steht.

## Tests (auf echtem iPad, je Phase)

- 100 kurze Buchstaben mit kurzem Abheben; 10 Minuten Dauerschreiben; schneller Buchstabenwechsel.
- Schreiben am Seitenrand und bei 50 %, 100 %, 300 % Zoom.
- Ein Finger scrollt, zwei Finger zoomen, danach sofort weiterschreiben.
- Hand liegt auf, Pencil schreibt: keine Fingerstriche, kein Scrollen.
- Flugmodus: schreiben, App schließen, WLAN an → Notizen kommen auf dem PC an.
- Gleiche Datei gleichzeitig auf PC und iPad bearbeiten → Konfliktabfrage statt Datenverlust.

## Risiken

- Ohne Mac kein Xcode: Phase 0 braucht einen Mac (eigener, Uni-Pool oder Cloud-Mac).
- Kostenlose Signierung läuft nach 7 Tagen ab; für dauerhaft: Apple Developer Program.
- PencilKit speichert eigene Strichdaten; der Konverter (Phase 4) ist der Teil mit dem meisten Testaufwand.
