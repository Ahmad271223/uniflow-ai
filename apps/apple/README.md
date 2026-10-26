# UniFlow für iPad (SwiftUI, PDFKit, PencilKit)

**Stand 25.10.2026:** Code wird in GitHub Actions gebaut und getestet (`.github/workflows/apple.yml`): der
gemeinsame Kern unter Linux und macOS, die App im iPad-Simulator. **Nicht auf einem echten iPad getestet.**
Schreibgefühl, Handballen-Erkennung, Pencil-Doppeltippen und Zoomverhalten am Gerät sind unbestätigt.

## Aufbau

| Teil | Aufgabe | Testbar ohne Mac |
| --- | --- | --- |
| `Packages/UniFlowCore` | Notizmodell (JSON, verlustfrei), Drei-Wege-Zusammenführung, lokales Journal, Synchronisierung, Zoom- und Seitengeometrie | ja (`swift test`, auch Linux) |
| `UniFlow/Models/StrokeConverter.swift` | PencilKit ↔ gemeinsames Strichformat mit stabilen IDs | Simulator |
| `UniFlow/Services/DocumentStore.swift` | Trennung von Stifteingabe, Umrechnung (Hintergrund), lokalem Sichern und Upload | Simulator |
| `UniFlow/Editor/PDFEditorController.swift` | PDFKit (Scrollen, Zoomen) + PencilKit (Schreiben) je Seite | Simulator, Gefühl nur am Gerät |
| `UniFlow/Views/Views.swift` | Verbinden, Bibliothek, Dokumentansicht | Simulator |

### Datenfluss beim Schreiben

1. PencilKit meldet eine geänderte Zeichnung. Der Editor merkt sich nur die neueste Zeichnung je Seite und kehrt
   sofort zurück (keine Arbeit auf dem Hauptthread während des Schreibens).
2. Nach 0,25 s Ruhe rechnet `InkProcessor` (Actor) die Zeichnung in Objekte um. Unveränderte Striche behalten ihr
   JSON, neue bekommen neue IDs, mit dem Pixel-Radierer geteilte Striche werden in sichtbare Teile zerlegt.
3. `SyncEngine.updatePage` vergibt eine neue Revision und schreibt die Seite atomar ins Journal. Schlägt das fehl,
   zeigt der Status „Nicht gesichert“, nie „Gespeichert“.
4. Nach 1,2 s lädt die Engine hoch, höchstens ein Upload gleichzeitig. Bestätigt werden genau die gesendeten
   Revisionen; was während des Uploads entstand, bleibt ungesendet.
5. Antwortet der Server mit 409, wird objektweise mit dem neueren Stand zusammengeführt (Basis = letzter
   bestätigter Stand) und erneut gesendet. Ohne Netz: Wiederholung nach 2 s … 60 s, beim Wechsel ins WLAN und
   beim Zurückkehren in die App sofort.

### Journal auf dem Gerät

`<Container>/journal/spaces/<Datenquelle>/docs/<Datei-ID>/` (Container je Apple-Nutzer und Hochschule unter
`Application Support/UniFlowContainers/<uuid>/`): `meta.json` (Seitenliste usw.), `acks.json`
(Serverversion, bestätigte Revisionen), `pages/<Seite>.json` (Stand + Revision), `base/<Seite>.json`
(Vergleichsstand für Konflikte). Jede Datei wird einzeln atomar ersetzt; nach einem Absturz ist an den Revisionen
erkennbar, was noch fehlt.

## Plattformübergreifend bearbeitbar

| Inhalt | Web → iPad | iPad → Web |
| --- | --- | --- |
| Striche Stift/Bleistift/Textmarker | bearbeitbar (verschieben, radieren, löschen) | bearbeitbar |
| Breite je Punkt, Farbe, Deckkraft | ja | ja |
| PencilKit-Pinselstruktur, Neigung | – | nur sichtbar (geht bei Bearbeitung im Browser verloren) |
| Text, Formen, Bilder | bleiben erhalten, auf dem iPad noch nicht angezeigt | – |
| Eingefügte Leer-/Bildseiten | bleiben erhalten, auf dem iPad noch nicht angezeigt | – |

## Bauen (Mac)

```bash
brew install xcodegen
```

```bash
cd apps/apple && xcodegen generate && open UniFlow.xcodeproj
```

In Xcode: Ziel „UniFlow“ → Signing & Capabilities → eigenes Team (Apple-ID reicht für 7 Tage), iPad per Kabel
verbinden, Run. Am PC `Start-iPad.cmd` starten, in der App Adresse und PIN eintragen.

Ohne Mac: Tests des Kerns lokal mit Docker (`swift:6.0-jammy`) oder über GitHub Actions („Apple“, auch manuell
startbar).

## Ausstehende Gerätetests

Siehe `docs/MAC-IPAD-CHECKLISTE.md`.

Vor einer Veröffentlichung: Bundle-ID und Team festlegen, Datenschutzangaben, App-Store-Connect-Eintrag
(Checkliste in `docs/RELEASE-VORBEREITUNG.md`). Die Info.plist enthält keine ATS-Ausnahme; nur der Debug-Build erlaubt
das lokale Netz für den eigenen Server (Skriptphase in `project.yml`).
