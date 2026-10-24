# UniFlow für iPad (SwiftUI, PDFKit, PencilKit)

**Stand: Etappe 1, nicht kompiliert und nicht auf einem Gerät getestet.** Der Code wurde auf einem Windows-PC
geschrieben. Bauen und Testen braucht einen Mac mit Xcode.

## Was Etappe 1 kann

- Mit dem UniFlow-Server im WLAN verbinden (Adresse + PIN; PIN im Schlüsselbund).
- Bibliothek: Module und PDF-Dokumente aus Stud.IP, Suche.
- PDF öffnen (PDFKit), mit dem Apple Pencil schreiben (PencilKit, Werkzeugpalette von Apple).
  Finger scrollen und zoomen, „Nur Stift“ ist Standard und oben umschaltbar.
- Jede Änderung wird sofort lokal gesichert und nach 1,2 s an den Server geschickt; ohne WLAN wird es
  automatisch nachgeholt. Konflikte (gleiche Datei auf PC und iPad) werden seitenweise zusammengeführt.
- Striche aus dem Web-Editor erscheinen auf dem iPad, Striche vom iPad erscheinen im Web-Editor.

Noch nicht: im Browser eingefügte Leerseiten, Text/Formen/Bilder anzeigen (bleiben aber erhalten), gedrehte Seiten
(Koordinaten ungeprüft), Lernkalender und übrige Ansichten nativ, Split-Screen, Konten, Abos/StoreKit.

## Bauen (Mac)

```bash
brew install xcodegen
```

```bash
cd apps/apple && xcodegen generate && open UniFlow.xcodeproj
```

In Xcode: Ziel „UniFlow“ → Signing & Capabilities → eigenes Team (Apple-ID reicht für 7 Tage), iPad per Kabel
verbinden, Run. Am PC `Start-iPad.cmd` starten, in der App Adresse und PIN eintragen.

## Erste Prüfung auf dem iPad (Abnahme Etappe 1)

1. PDF öffnen, 15 Minuten schreiben, dabei zoomen und mit einem Finger scrollen.
2. 100 kurze Striche mit kurzem Abheben; Hand liegt dabei auf.
3. App schließen, neu öffnen: alle Striche an derselben Stelle.
4. Dasselbe PDF am PC im Browser öffnen: Striche sind da; dort einen Strich ergänzen, auf dem iPad neu öffnen.
5. Flugmodus: schreiben, App schließen, WLAN an, App öffnen → Status „Gespeichert“, Striche am PC sichtbar.

## Aufbau

| Datei | Aufgabe |
| --- | --- |
| `UniFlow/Editor/PDFEditorController.swift` | PDFView + PKCanvasView je Seite (`PDFPageOverlayViewProvider`), Werkzeugpalette |
| `UniFlow/Services/DocumentStore.swift` | Laden, lokales Sichern, Upload mit `base_version`, Konflikte, Wiederholen |
| `UniFlow/Models/StrokeConverter.swift` | PencilKit ↔ gemeinsames Strichformat, Signatur für `pkdrawing` |
| `UniFlow/Models/AnnotationDocument.swift`, `JSONValue.swift` | Notizmodell verlustfrei (unbekannte Felder bleiben) |
| `UniFlow/Services/APIClient.swift`, `Session.swift`, `LocalStore.swift` | Server, PIN/Schlüsselbund, Dateien im App-Container |
| `UniFlow/Views/Views.swift` | Verbinden, Bibliothek (3 Spalten), Dokumentansicht |

Vor einer Veröffentlichung: `NSAllowsArbitraryLoads` aus `project.yml` entfernen (Server dann per HTTPS),
Bundle-ID und Team festlegen, Datenschutzangaben, App-Store-Connect-Eintrag.
