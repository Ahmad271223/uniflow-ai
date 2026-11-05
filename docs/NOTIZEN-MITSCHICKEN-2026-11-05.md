# Notizen und Blätter mitschicken (05.11.2026)

Wunsch des Inhabers (05.11.2026, wörtlich): „ganz wichtig wenn ich seiten notiz aufmache oder blatt neben seite öffne
und was aufschreibe und lösung hochlade soll das direkt mit geschickt werden auch neben der folie wo es war ganz
wichtig“.

## 1. Begriffe

| Begriff | Was es im Code ist |
|---|---|
| **Seitennotiz** | Leerseite im eigenen Dokument, eingefügt mit „Leere Seite danach“ (Seitenleiste, Menü „Seite“): Eintrag `type: "blank"` in `pageOrder` direkt hinter der Folie. |
| **Blatt neben der Seite** | „Daneben öffnen → Leeres Blatt“ (`CompanionPicker`): ein eigenes Notizbuch (`kind: notebook`) in der geteilten Ansicht. Es ist ein **anderes Dokument**; bis 04.11. wusste niemand, neben welcher Folie darauf geschrieben wurde. |
| **Notizseite einer Folie** | Seitennotizen direkt hinter der Folie (bis zur nächsten PDF-Seite) und Blattseiten, die neben dieser Folie beschrieben wurden. |

## 2. Verknüpfung Blatt → Folie

Schreibt man auf einer Seite des Blatts daneben (Stift, Text, Formen), merkt sich das **Hauptdokument**, neben welcher
Seite das war – einmal je Blattseite, die erste Folie gilt („wo es angefangen hat“):

```json
"sideSheets": [ { "file": "<ID des Notizbuchs>", "pages": { "<Seitenschlüssel im Blatt>": "<Seitenschlüssel im Dokument, z. B. p4>" } } ]
```

- Wurzelfeld des Notizmodells (unbekannte Felder bleiben überall erhalten, `annotations.schema.json`), wird mit den
  Notizen abgeglichen (Zusammenführen wie andere Wurzelfelder, `AnnotationMerge.mergeField`).
- Nur Notizbücher zählen als Blatt (ein Skript daneben wird nie mitgeschickt). Nur wenn das Dokument beschreibbar ist.
- Kern: `UniFlowCore/SideNotes.swift` (`SideNotes.link`, `links`, `sheetFileIDs`). App: `DocumentStore.onLocalEdit`
  meldet Schreiben im Blatt, `DocumentView` verknüpft mit der gerade angezeigten Seite (`DocumentStore.linkSideSheet`).
- Blattseiten ohne Verknüpfung (vor dem 05.11. beschrieben) kommen ans Ende, wie bisher.

## 3. Reihenfolge beim Mitschicken

`SideNotes.interleaved(main:sheets:skipEmptySheetPages:)` baut ein Dokument in der Reihenfolge der Seitenleiste:

1. Folie (PDF-Seite), 2. ihre Seitennotizen (Leerseiten dahinter, wie in der Seitenleiste), 3. die Blattseiten, die
neben dieser Folie beschrieben wurden (in der Reihenfolge des Blatts), dann die nächste Folie.

- Blattseiten bekommen den Schlüssel `sn-<Schlüssel im Blatt>` (doppelt: `sn2-…`) und im Eintrag `sideOf` (Folie) und
  `sideFile` (Blatt). `sn-` ist **kein** Notizblatt-Schlüssel im Sinne von `SolutionBuilder.isNotebookKey`: beim
  Zusammenführen einer aktualisierten Lösung bleiben sie wie Leerseiten hinter ihrer PDF-Seite (Python, Browser und
  Swift unverändert).
- Leere Blattseiten werden ausgelassen. Leere Seitennotizen: im PDF-Export ausgelassen, wenn das Dokument Folien hat
  (`skipEmptyNotePages`); im Lösungs-Dialog nicht vorausgewählt (ohne Notizen ohnehin nicht teilbar).

## 4. Wege nach draußen

### 4.1 Lösung teilen / in der Community veröffentlichen

- Dialog „Lösung teilen“: Schalter **„Notizen und Blätter mitschicken“**, Standard **an**. An: alle Seitennotizen und
  Blattseiten mit Notizen sind ausgewählt und stehen direkt hinter ihrer Folie; aus: keine davon.
- Eine gewählte Notizseite bringt ihre **Folie** mit (auch ohne eigene Notizen auf der Folie): sonst stünde die Notiz beim
  Empfänger als „Eigene Seite“ ganz vorn und rutschte beim Zusammenführen vor alle PDF-Seiten. Im Dialog sichtbar
  (Folie wird mit angehakt; Folie abwählen nimmt ihre Notizseiten heraus, `SolutionShareSheet.toggled`), beim Bauen
  erzwungen (`SolutionBuilder.withSlides` in `SolutionSharing.content`, nur Folien ohne Prüfproblem). Unverknüpfte
  Blattseiten am Ende bringen keine Folie mit.
- Geladen werden alle verknüpften Blätter (`sideSheets`) und das gerade daneben offene Blatt desselben Moduls; ein
  Blatt, das in einem Fenster offen ist, wird über dessen Store gelesen (`OpenDocuments`), sonst kurz geöffnet und
  wieder geschlossen (nur lesen, kein Versionseintrag).
- Paket unverändert (Formatversion 2): Blattseiten sind Leerseiten (`kind: blank`) mit Vorlage und Größe des Blatts.

### 4.2 PDF exportieren (Teilen-Menü) und „Abgeben“ in Stud.IP – eine Funktion

```swift
// apps/apple/UniFlow/Services/NotesExport.swift
enum NotesExport {
    struct Options: Sendable, Equatable {
        var scope: ShareScope = .document         // .page(i): Seite i mit ihren Notizseiten
        var includeSideNotes = true               // Blätter daneben mitschicken
        var skipEmptyNotePages = true             // leere Seitennotizen/Blattseiten weglassen
        var fileStem: String? = nil               // Dateiname ohne .pdf (Standard: Titel des Dokuments)
        var folder = "teilen"                     // Unterordner in AppTemp (z. B. "abgabe")
    }
    struct Result: Sendable, Equatable {
        let url: URL                              // fertige PDF (Titel.pdf) im AppTemp-Ordner
        let payload: SharePayload                 // Seitenzahl, Titel, fehlende Bilder
        let notePages: Int                        // davon Seitennotizen und Blattseiten
    }
    @MainActor
    static func pdf(for store: DocumentStore, api: APIClient, options: Options = Options()) async throws -> Result
}
```

Beispiel „Abgeben“: `let r = try await NotesExport.pdf(for: store, api: api, options: .init(fileStem: "Blatt 4 – Abgabe", folder: "abgabe"))`,
dann `r.url` hochladen. „Diese Seite“ (`scope: .page(i)`) liefert die Folie und ihre Notizseiten.

Der Store muss geladen sein (`store.load()`); ausstehende Striche werden vorher verarbeitet. „Abgeben“ ruft genau diese
Funktion (z. B. `options.folder = "abgabe"`) und lädt `result.url` hoch.

### 4.3 KI-Hilfe

Fragt man die KI zu einer Folie, gehen deren Notizseiten mit: Text aus Textfeldern und Haftnotizen und die erkannte
Handschrift (Vision, Deutsch/Englisch, auf dem Gerät) als Feld `own_notes` der Anfrage `POST /api/ai/tutor`
(`AttachedNotes.text(for:pageKey:api:)`, höchstens 4 000 Zeichen). Der Dienst bzw. das iPad hängt sie als Block
„MEINE NOTIZEN ZU DIESER SEITE“ an den Prompt (`AIPrompts.tutor(ownNotes:)`, `ai.tutor_prompt(own_notes=)`) und
benutzt dann **nie** den geteilten Erklärungsspeicher (persönlicher Inhalt).

## 5. Beim Empfänger

Die Seiten einer Lösung heißen in allen Ansichten (iPad: Vorschau, „Lösung daneben“, Dialog; Web: Community-Kanal,
Korrektur-Werkzeuge) einheitlich: PDF-Seite → „PDF-Seite 4“, Leerseite hinter einer PDF-Seite → **„Notiz zu Folie 4“**,
Leerseite vor der ersten PDF-Seite → „Eigene Seite“ (`SolutionBuilder.pageTitle`, Browser `pageTitle` in
`app/static/solution-labels.js`).

## 6. Tests

- Kern (`swift test`): `SideNotesTests` – Verknüpfen (erste Folie gilt), Einflechten hinter Folie und Seitennotizen,
  leere Blattseiten, unverknüpfte ans Ende, Schlüsselkollision, Zusammenführen hält `sn-` hinter der Folie,
  Seitentitel, Prompt-Block.
- App: `NotesExportAppTests` – Dokument mit eingefügtem Blatt hinter Seite 2 und Blattnotiz zu Seite 4: PDF-Reihenfolge,
  Tinte gerendert, leere ausgelassen, Lösung mit `sn-`-Seite hinter PDF-Seite 4, KI-Notiztext.
- Python: `tests/test_tutor_own_notes.py`; Node: `tests/js/solution-labels.test.mjs`.
