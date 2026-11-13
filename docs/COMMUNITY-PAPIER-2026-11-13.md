# Lösung anderer mit richtigem Papier, Papierkorb für Notizblätter (13.11.2026)

Zweig `editor/community-papier` (von develop `2445ba20`). Nicht in develop, nicht gepusht, nichts zu Apple.

## Lösung daneben: genau wie geschrieben

Geprüft und mit Tests abgesichert (`CommunityPaperAppTests`, zwei getrennte Konten, echtes verschlüsseltes Paket):

1. **Papierart wird mitgeschickt.** Jede eigene Seite der Absenderin (leeres Blatt, Blatt daneben) trägt im Paket nur
   den **Namen ihres Musters** (`template`: leer, liniert, kariert, gepunktet, Millimeter, Cornell) – keine Datei,
   keine PDF. Das war schon so; neu ist der Test, der es über Teilen → Versiegeln → Öffnen beim anderen Konto prüft.
2. **Anzeige:** Folien stehen auf der eigenen PDF-Seite, eigene Blätter auf genau ihrem Papier. Neu steht das Papier
   im Seitentitel: „Notiz zu Folie 1 · Liniert“. Der Hinweis ohne eigene PDF sagt jetzt richtig, dass nur Folien weiß
   bleiben, eigene Blätter aber auf ihrem Papier stehen; eine Lösung nur aus eigenen Blättern braucht gar keine PDF.
3. **Links oder rechts:** gab es schon – Kopfzeile der Lösung zur anderen Seite ziehen, oder „Geteilt“ gedrückt
   halten › „Seiten tauschen“. Die Wahl wird je Dokument und Lösung gemerkt (Tests `SplitSidesAppTests`).
4. **Mehrseitig:** alle Seiten untereinander, jede auf ihrem Hintergrund (Folie 1, liniert, Folie 2, kariert, Folie 3).

Code: `SolutionPaper` in `Views/SolutionViews.swift`; Texte in `CommunityTexts`.

## Papierkorb für Notizblätter daneben (Wunsch des Inhabers)

- Im Kopf des Notizblatts daneben gibt es einen **Papierkorb-Knopf** mit Rückfrage. Vorher wird alles gesichert.
- Das Blatt verschwindet aus der Spalte, ein Hinweis sagt, wo es wiederherzustellen ist: „Geteilt“ › Deine Blätter
  (dort „Wiederherstellen“) oder Bibliothek › Papierkorb. Nichts wird endgültig gelöscht.
- Unter „Deine Blätter zu diesem Dokument“ lässt sich ein Blatt auch über gedrückt halten in den Papierkorb legen
  (nicht das gerade offene).
- Ein Blatt im Papierkorb geht nicht mehr mit in Druck, Export oder geteilte Lösungen.
- Code: `SideSheetTrash`, `CompanionTrashButton`; Test `testSideSheetTrashKeepsEverythingRestorable`.

## Bilder

- `~/Studora-Builds/papier/bilder/`: 1 Lösung rechts, 2 Lösung links (getauscht), 3 alle Seiten untereinander.
- `~/Studora-Builds/papier/bilder-neben/`: 10 Papierkorb-Knopf, 11 Rückfrage, 12 Hinweis danach.

## Tests

- iPad voll (Klon „iPad Nebenblatt“ von 4495AA80): 1602 Tests, 27 übersprungen, 1 Fehler
  `StoreScreenshotV11Tests.test02UniMail` (Zeitüberschreitung); allein wiederholt 10/10 grün. Ein erster Lauf hing,
  weil eine andere Sitzung zeitgleich ihre Suite lief (fester Port im ChatGPT-Anmeldetest) – abgebrochen, neu gestartet.
- Neu: `CommunityPaperAppTests` 1/1, `SideSheetFoundAgainAppTests` 11/11, `ViewTypeDepthAppTests` grün.
- Kern unverändert (kein `swift test`/Python-Lauf nötig).
