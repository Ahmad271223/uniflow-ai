# „+ Seite“ im Blatt daneben (Fehlerbericht Build 37, 13.11.2026)

Zweig `editor/plus-seite-fix` (von develop `ef3a7fda`). Nicht in develop, nicht gepusht, nichts zu Apple.

## Fehler

Im Blatt daneben tat „+ Seite“ nichts. Nur der Umweg über Schließen und neues „Leeres Blatt“ brachte eine Seite.

## Ursache

- Der Knopf war ein System-Menü mit Hauptaktion (`Menu … primaryAction`).
- Die ganze Kopfzeile des Blatts hat die Geste „gedrückt halten und ziehen“ zum Seitentausch (`UFPaneSwapGesture`,
  `LongPress` + `Drag` mit Mindestweg 0). Sie nimmt jede Berührung sofort auf.
- Ein normaler `Button` (wie das X) setzt sich dagegen durch, das System-Menü nicht: der Fingertipp kam nie an.
- Der App-Test aus `afefc17a` löste den Knopf über die Bedienungshilfen aus, also an der Berührung vorbei – darum
  war er grün. Mit echter Berührung nachgestellt: vorher „S. 1 / 1“, nach dem Tippen weiter „S. 1 / 1“.

## Behebung (wie vom Inhaber gewünscht)

- „+ Seite“ ist jetzt ein normaler Knopf. Er fragt zuerst nach dem Papier (leer, liniert, kariert, gepunktet,
  Millimeter, Cornell – wie bei „Leeres Blatt“; das Papier der angezeigten Seite ist markiert).
- Danach kommt die Seite **direkt unter der angezeigten** dazu, das Blatt bleibt offen und springt hin.
- Die Beschriftung „+ Seite“ wird hochkant nicht mehr abgeschnitten.
- Code: `CompanionAddPageButton`, `CompanionPaperChooser` in `Views/DocumentView.swift`.

## Tests

- **Neu: echter UI-Test mit Berührungen** (`UniFlowUITests/CompanionAddPageUITests`, neues Ziel in `project.yml`):
  Demo-Übungsblatt, Blatt daneben öffnen, „+ Seite“ tippen, Papier „Kariert“ wählen, neue Seite und Sprung prüfen,
  App beenden und neu starten, Seite noch da. Für Stift-Palette **oben fest, unten fest, schwebend**: 3/3 grün.
  Mit dem alten Knopf scheitert er (Seitenzahl bleibt gleich).
  Lauf: `xcodebuild test … -only-testing:UniFlowUITests` (nicht Teil von `-only-testing:UniFlowTests`).
  Bilder mit `TEST_RUNNER_UF_SCREENSHOT_DIR=…`.
- Die 15 Dokument-Reiter aus develop sind bei diesem Lauf dabei (Reiter des Übungsblatts in der Kopfzeile).
- `NebenblattBilderAppTests.test1Nebenansicht` wählt jetzt nach „+“ das Papier.
- iPad voll (`-only-testing:UniFlowTests`): 1619 Tests, 0 Fehler (27 übersprungen); `ChatGPTLinkAppTests` wegen
  zeitgleicher Suiten anderer Sitzungen getrennt gelaufen: 11/11. UI-Tests auf dem Endstand: 3/3.

## Bilder

`~/Studora-Builds/plusseite/bilder/`: je Palette 1 Blatt daneben, 2 Papier wählen, 3 neue Seite.

## Beim Mischen

- `xcodegen generate` (neues UI-Testziel).
- Hinweis an alle Sitzungen: gleichzeitig laufende Testsuiten stören `ChatGPTLinkAppTests` (fester Port).
