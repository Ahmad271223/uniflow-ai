# Blatt daneben, Druck und Lösungen anderer (13.11.2026)

Zweig `editor/nebenblatt-community` (von develop `f0964d1f`). Nicht in develop gemischt, nicht gepusht, nichts zu Apple.

## 1. Mehrere Seiten im Blatt daneben

- **Vorher:** Im Blatt daneben gab es keinen Knopf für eine weitere Seite. Am iPad ging nur das eine Blatt
  (am Mac nur über Rechtsklick).
- **Jetzt:** Im Kopf des Blatts daneben steht ein „+“ (*Seite darunter einfügen*): Antippen fügt eine leere Seite direkt
  unter der angezeigten ein, mit derselben Vorlage (kariert, liniert …), und springt hin. Gedrückt halten: Vorlage wählen.
  Die Seitenzahl zeigt jetzt „S. 2 / 3“.
- Code: `CompanionAddPageButton`, `CompanionPageLabel` in `Views/DocumentView.swift` (eigene kleine View-Typen,
  `DocumentView.body` unverändert).

## 2. Blatt daneben wiederfinden – nichts geht verloren

- **Wo es liegt:** Jedes leere Blatt aus „Daneben öffnen“ ist ein eigenes Notizbuch. Es liegt in der Bibliothek beim
  Modul unter „Eigene Notizen“ (ohne Modul bei den eigenen Dokumenten) und heißt „Notizen – <Dokument>“. Das Dokument
  merkt sich, neben welcher Seite darauf geschrieben wurde (`sideSheets`).
- **Problem:** Nach dem Schließen gab es keinen Weg zurück aus dem Dokument, das Blatt erschien nicht unter
  „Zuletzt benutzt“, und mehrere Blätter hießen gleich.
- **Jetzt:**
  - „Geteilt“ › „Daneben öffnen“ zeigt oben **„Deine Blätter zu diesem Dokument“**: alle Blätter, die neben diesem
    Dokument beschrieben wurden, dazu nur angelegte gleichen Namens, mit Datum. Ein Blatt im Papierkorb steht dort mit
    „Wiederherstellen“.
  - Ein Blatt daneben zählt als geöffnet: es steht unter **„Zuletzt benutzt“** (Übersicht) und „Zuletzt bearbeitet“.
  - Beim Schließen sagt ein kurzer Hinweis, dass es gespeichert ist und wo es wieder auftaucht.
- Test: `SideSheetFoundAgainAppTests.testClosedSheetIsKeptAndFoundAgain` (Striche nach dem Schließen noch da, in
  Bibliothek, „Zuletzt benutzt“, „Deine Blätter“, Papierkorb).

## 3. Lösungen anderer 1:1 auf dem richtigen Hintergrund

- Die geteilte Lösung trägt nur den **Fingerabdruck der PDF** (SHA-256) und die **Seitennummern** – nie die PDF selbst.
- **Vorher:** In der Lese-Ansicht einer Community-Lösung standen die Striche immer auf weißen Seiten, auch wenn man
  dieselbe PDF hatte.
- **Jetzt:**
  - Lese-Ansicht: Hat der Betrachter dieselbe PDF (gleicher Fingerabdruck, gleiche Seitenzahl), steht jede Seite auf
    seiner **eigenen Kopie** der PDF. Sonst bleibt die leere Seite mit Hinweis („Du hast diese PDF nicht …“).
  - In der Liste „Lösungen aus der Community“ im Dokument gibt es **„Daneben ansehen“**: lädt die Lösung und zeigt sie
    in der geteilten Ansicht neben dem eigenen Dokument, jede Seite auf der eigenen PDF-Seite, Notizseiten auf ihrer
    Vorlage.
- Nichts wird hochgeladen; gelesen wird nur die eigene Datei im eigenen Container (`CommunityCourses.localPDF`).
- **Stud.IP-Datei-ID:** bewusst nicht als zweiter Weg eingebaut. Hat der Lehrende die Datei geändert, verschieben sich
  oft die Seiten – dann stünde die Lösung auf der falschen Folie. Dafür müsste außerdem das versiegelte Lösungsformat
  (Kern und Dienst) geändert werden. Der Fingerabdruck ist genau, und bei gleicher Stud.IP-Datei ist er gleich.
- Test: `SideSheetFoundAgainAppTests.testForeignSolutionUsesOwnCopyOfThePDF`.

## 4. Druckfehler

- **Ursache:** „Drucken“ (ebenso Sichern, Teilen, Abgeben) nimmt die Blätter daneben mit, die mit dem Dokument
  verknüpft sind. Dabei wurde **auch ein Blatt aus dem Papierkorb** gelesen (die App fragte die Datei ohne Blick auf
  „gelöscht“ ab). So erschien ein altes Blatt im Druck, das in der App sonst nirgends zu sehen war. Das gerade offene,
  noch nicht verknüpfte Blatt fehlte dagegen. Der Hinweis vor dem Druck nannte keins davon.
- **Jetzt:**
  - Blätter im Papierkorb gehen nie mit (Druck, Export, Abgeben, Lösung teilen, KI-Hilfe).
  - Das gerade daneben offene Blatt geht mit.
  - Der Hinweis vor Drucken/Sichern/Teilen listet **„Mit dabei: n Blätter daneben“** mit Namen und Datum; jedes lässt
    sich abwählen.
- Tests: `testTrashedOldSheetIsNotPrinted`, `testPrintTakesTheOpenSheetAndLeavesOutDeselectedOnes`.

## Tests

- iPad voll (`-only-testing:UniFlowTests`, Klon „iPad Nebenblatt“ von 4495AA80): 1576 Tests, 23 übersprungen, einziger
  Fehler `KIAbnahmeLUHAppTests.test3ProAIUeberDenDienst` – scheitert auf develop `f0964d1f` ohne diese Änderungen genauso
  (geprüft im selben Simulator), hat mit dem Blatt daneben nichts zu tun.
- Neu: `SideSheetFoundAgainAppTests` 6/6; dazu `NotesExportAppTests`, `ViewTypeDepthAppTests` grün.
- Kern `swift test`: 1503 Tests, 0 Fehler (Kern unverändert, darum kein Python-Lauf nötig).

## Bilder

`~/Studora-Builds/nebenblatt/bilder/` (erzeugt mit `NebenblattBilderAppTests`, nur mit `UF_SCREENSHOT_DIR`).

## Beim Mischen

- Neue Testdateien: `xcodegen generate`.
- Keine gemeinsamen Dateien mit `app/startseite-letzte-dokumente-stift` (dort `EditorHeaderBar`, `DocumentTabList`,
  `PDFEditorController`, `DashboardView`, `Views.swift`, `APIClient.swift`). Die neuen Knöpfe sitzen in der Kopfzeile
  des Blatts daneben (`UFPaneHeader` in `CompanionView`), nicht in `EditorHeaderBar`.
