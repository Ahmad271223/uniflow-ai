# Knöpfe im Kopf der Spalte daneben (Meldung Build 39, 13.11.2026)

Zweig `editor/kopfzeile-knoepfe` (von develop `3aa9edba`). Nicht in develop, nicht gepusht, nichts zu Apple.

## Meldung

Community-Lösung daneben geöffnet („Lösung von Anonym …“, „nur ansehen“): Das X reagierte nicht.

## Prüfung mit echter Berührung (XCUITest, `UniFlowUITests/SidePaneHeaderUITests`)

- Neuer Debug-Startschalter `-UFDocPanel solution`: legt zum Demo-Dokument eine erfundene Lösung an (Strich auf
  Seite 1, karierte Notizseite), versiegelt mit der eigenen PDF, und öffnet sie daneben. Nur in Entwickler-Builds,
  nichts wird gesendet (`Services/DebugDemoSolution.swift`).
- Geprüft: X der Lösung, X und „+ Seite“ des Notizblatts; Palette oben, unten, schwebend; hochkant und quer; Spalte
  gescrollt; kurzer Tipp, langer Druck und stiftartiger Tipp (0,5 s mit 4 pt Bewegung).
- **Ergebnis:** Im Simulator schloss das X in jedem Fall – auch auf dem unveränderten Stand. Der genaue Weg des
  Inhabers ist noch offen (Rückfrage gestellt: wie geöffnet, Finger oder Stift, reagiert sonst etwas).

## Härtung

- Die Geste „gedrückt halten und ziehen“ (Seiten tauschen) lag auf der **ganzen** Kopfzeile und damit auch über
  allen Knöpfen. Beim „+ Seite“ (Build 37) war genau diese Konkurrenz die Ursache. Jetzt liegt sie **nur auf Symbol
  und Titel**; X, „+ Seite“, Papierkorb usw. haben keine konkurrierende Geste mehr.
- Seiten tauschen geht weiter: Titel gedrückt halten und zur anderen Seite ziehen (Test
  `testSwapByDraggingTheTitle`), außerdem „Geteilt“ gedrückt halten › „Seiten tauschen“ und die Bedienungshilfe.
- Code: `UFPaneHeader` in `Design/UFComponents.swift`; Kennungen `solution.close`, `companion.close`.

## Tests

- UI-Tests (echte Berührung): `SidePaneHeaderUITests` 9/9 und `CompanionAddPageUITests` 3/3.
- iPad voll (`-only-testing:UniFlowTests`, ohne den Port-Test, der einzeln lief): 1745 Tests. Im ersten Lauf zeigte
  `TutorHeadAppTests` einen echten Fehler meiner ersten Fassung (Kopfzeile wuchs in die Höhe), behoben. Im zweiten
  Lauf scheiterte nur `CommunityCorrectionWiringAppTests.testInboxBannerOnSpacePageOpensAndIgnores` (Zeitlimit);
  allein zweimal 13/13 grün. `TutorHeadAppTests`, `ViewTypeDepthAppTests`, `SplitSidesAppTests`,
  `ChatGPTLinkAppTests` zusammen 27/27.
