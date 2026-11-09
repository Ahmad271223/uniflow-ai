# Mac: Bedienung mit Maus, Trackpad und Tastatur – 09.11.2026

**Befund des Inhabers (09.11.2026, App am Mac):** „es gibt kein Dokument links rechts wischen und noch weitere Sachen
nicht“. Am iPad geht alles mit Finger und Stift; am Mac („Designed for iPad“, dieselbe App) kommen Maus und Trackpad
anders an.

**Ursache:** Im Editor schrieb am Mac **jedes** Ziehen mit der Maus (`drawingPolicy .anyInput`, Rollen erst ab zwei
Berührungen). Mit der Maus ließ sich das Dokument also nie verschieben – weder hoch/runter noch, gezoomt, nach links
und rechts –, und der Schalter „Nur Stift“ tat am Mac nichts. Tasten taten im Editor nichts (Pfeile, Leertaste,
Cmd +/-). Ein waagerechtes Wischen mit zwei Fingern auf dem Trackpad blätterte nicht um.

**Was das iPad unter „Dokument links/rechts wischen“ macht:** Im Editor ist das Dokument eine senkrechte Seitenfolge
(`PDFView`, `singlePageContinuous`, `vertical`). Mit „Nur Stift“ (Standard) verschiebt **ein Finger** das Dokument in
jede Richtung: senkrecht durch die Seiten, gezoomt auch waagerecht. Ein Seitenwechsel per Wischen nach links/rechts
gibt es am iPad nicht. Daneben gibt es Wischen nach links/rechts im **Karteikarten-Trainer** (gewusst/nicht gewusst) und
im **Community-Leser** (nächste/vorige Person).

Branch `mac/bedienung-b29` (von `develop` b8ff8e29). Nichts hochgeladen, App Store Connect nicht angefasst.

## 1. Was UIKit am Mac mit Maus und Trackpad macht (geprüft, nicht vermutet)

Geprüft am 09.11.2026 in UIKitCore dieses Macs (macOS 26.6, die UIKit-Fassung, die iPad-Apps am Mac nutzen):
kleines Mac-Catalyst-Programm im Notizordner, Methodenliste per Objective-C-Laufzeit, Maschinencode mit `lldb`.

- **Zwei Finger rollen auf dem Trackpad, Mausrad:** kommen als Rollereignis (`UIEvent` Typ 10), nicht als Berührung.
  `-[UIGestureRecognizer _internalShouldReceiveEvent:]` prüft bei Rollereignissen `allowedTouchTypes` nicht,
  `-[UIPanGestureRecognizer shouldReceiveEvent:]` nur `allowedScrollTypesMask` (bei der PDF-Ansicht 3 = alle).
  `minimumNumberOfTouches` spielt dafür keine Rolle. **Folge:** Rollen mit Trackpad und Mausrad ging im Editor schon
  vorher, senkrecht und gezoomt waagerecht; das Mausrad rollt nur senkrecht (Umschalt + Rad waagerecht macht macOS).
- **Trackpad-Pinch:** Transformationsereignis (Typ 14), ebenfalls ohne Prüfung der Berührungsart → Zoomen mit zwei
  Fingern ging schon. Eine Maus hat keinen Pinch → Cmd +/-/0 fehlte.
- **Klicken und Ziehen mit der Maus:** eine Berührung (in iPad-Apps am Mac als direkte Berührung, die Zeigerart
  `indirectPointer` ist zur Sicherheit mit erlaubt). Das ist der einzige Weg, wie die Maus das Dokument „anfassen“
  kann – und genau den hat vorher die Zeichenfläche bekommen.
- **Lange drücken:** Maustaste halten. **Rechtsklick:** öffnet `contextMenu`. **Drag & Drop:** geht innerhalb der App
  und aus dem Finder.

## 2. Jede Bedienung: iPad → Mac vorher → Mac jetzt

| Bedienung | iPad (Geste) | Mac vorher | Mac jetzt (wie) | Test |
|---|---|---|---|---|
| **Dokument verschieben (hoch/runter, gezoomt links/rechts)** | ein Finger ziehen („Nur Stift“) | Ziehen mit der Maus **schrieb**, verschob nie; nur Trackpad/Mausrad rollten | **Standard „Maus blättert“:** Ziehen verschiebt in alle Richtungen, schreibt nicht (`EditorPointer.config`: `.pencilOnly`, Rollen ab 1 Berührung, direkte + Zeiger-Berührung). Trackpad und Mausrad rollen wie vorher | `MacBedienungTests.testMacMouseNavigatesByDefaultAndWritesOnlyWhenChosen`, `testEditorAppliesTheInputOfThisDevice`, `EditorPaletteTests.testPencilOnlyIsTheDefault…` (jetzt ohne Mac-Ausnahme) |
| **Schreiben mit der Maus** | Stift (bzw. „Finger zeichnet“) | jedes Ziehen schrieb | Schalter in der Leiste **„Maus blättert“ ↔ „Maus schreibt“** (derselbe Schalter wie „Nur Stift“/„Finger zeichnet“ am iPad, gerätelokal), Hinweis unten und Hilfetext beim Zeigen; mit „Maus schreibt“ blättern Trackpad, Mausrad, Pfeiltasten | dieselben |
| Einstellung dazu | „Stift & Touch“: „Nur Stift schreibt, Finger navigiert“ | Text sprach vom Stift, wirkte am Mac nicht | Mac: „Maus & Trackpad“ mit „Maus schreibt …“ / „Maus blättert …“ | – (Text) |
| **Dokument links/rechts wischen** | (kein Seitenwechsel; gezoomt verschiebt der Finger waagerecht) | Trackpad waagerecht: nichts (nicht gezoomt) | **Zwei Finger waagerecht auf dem Trackpad = nächste/vorige Seite**, nur wenn die Seite nicht breiter als die Ansicht ist (sonst rollt es waagerecht); nur Trackpad-Rollereignisse, keine Berührungen (`TrackpadPageSwipe`, nur am Mac) | `testTrackpadSwipeTurnsPagesOnlyWhenClearlySideways`, `testTrackpadSwipeIsInstalledOnlyOnTheMac` |
| Seite vor/zurück | Finger rollt, Seitenleiste | nur Seitenleiste, Suche, Gehe zu | **← →** vorige/nächste Seite (gezoomt erst waagerecht bis zum Rand, wie Vorschau), **Cmd-↑/↓, Pos1/Ende** erste/letzte Seite | `testLeftRightTurnPages…`, `testKeysDriveTheEditor` |
| Rollen mit der Tastatur | – | nichts | **↑ ↓** eine Zeile, **Leertaste / Umschalt-Leertaste, Bild ab/auf** fast eine Bildschirmhöhe | `testUpDownSpaceAndPageKeysScroll`, `testKeysDriveTheEditor` |
| Zoomen | zwei Finger Pinch, Doppeltippen | Trackpad-Pinch und Doppelklick gingen; Maus ohne Weg | **Cmd +** (auch Cmd =), **Cmd −**, **Cmd 0** (Seitenbreite), in den Grenzen des Editors | `testZoomKeys`, `testKeysDriveTheEditor` |
| Tasten beim Tippen, fixiert, mit Blatt darüber | – | – | Tasten ruhen, wenn ein Textfeld den Fokus hat (Textobjekt, KI-Hilfe), die Ansicht fixiert ist oder ein Blatt darüber liegt (`acceptsEditorKeys`) | `testKeysDriveTheEditor` |
| Rückgängig/Wiederholen | Palette, drei Finger | Knöpfe, Cmd-Z (Build 29) | unverändert | (`MAC-B28`) |
| Dokument-Reiter wechseln | Reiter antippen, Leiste wischen | Klicken; Leiste mit Trackpad/Ziehen | zusätzlich **Ctrl-Tab / Ctrl-Umschalt-Tab** und **Cmd-Option-→/←** (am Ende wieder vorn) | `testDocumentTabsCycleWithTheKeyboard` |
| Liste neu laden (Dokumente, Nachrichten) | nach unten ziehen | Ziehen mit gedrückter Maus | zusätzlich **Cmd-R** | – (Knopf mit Kurzbefehl) |
| Geteilte Ansicht: Breite | Griff ziehen | Griff mit der Maus ziehen ging | unverändert | – |
| Geteilte Ansicht: Seiten tauschen | Kopfzeile lange drücken und ziehen | ging mit gehaltener Maustaste (`MAC-B28`, Bild `debug-13`) | unverändert; dazu Rechtsklick auf „Geteilt“ → „Seiten tauschen“ (schon da) | – |
| Karteikarten: gewusst/nicht gewusst | nach rechts/links wischen | Knöpfe, ← →, Leertaste, R, Cmd-Z gab es schon; Ziehen mit der Maus geht | unverändert (Trackpad-Wischen bewegt die Karte nicht, Tasten und Knöpfe reichen) | `FlashcardTrainerTests` (13 grün am Mac) |
| Community-Leser: nächste/vorige Person | wischen | Pfeilknöpfe, Ziehen mit der Maus | zusätzlich **← →** | `CommunityChannelAppTests` (16 grün am Mac) |
| Gliederung: Eintrag entfernen | nach links wischen | nur Wischen (mit der Maus ziehen) | zusätzlich **Rechtsklick → Entfernen** | – |
| ZIP-Ordner: Löschen/Umbenennen | wischen | Rechtsklick-Menü gab es schon | unverändert | – |
| Seiten in der Seitenleiste (Menü) | lange drücken | Rechtsklick | unverändert | – |
| Studienverlauf / Lernkalender verschieben | ziehen und ablegen | Ziehen mit der Maus; Menü „Verschieben nach …“ bzw. „Auf anderen Tag verschieben“ | unverändert | (`StudyPlanMoveAppTests` am Mac grün, `MAC-B28`) |
| Objekte (Text, Formen): wählen, verschieben, bearbeiten | tippen, ziehen, doppeltippen, Pinch | Klick, Ziehen, Doppelklick; Pinch mit dem Trackpad | unverändert | – |
| PDF-Text markieren | lange drücken / Palette „Text markieren“ | Maustaste halten / Palette | unverändert | – |
| Fixieren / Abpausen | Cmd-L, Schloss zwei Sekunden halten | Cmd-L, Esc, Maustaste halten | unverändert (Abpausen am Mac ohne Helligkeit) | `EditorFreezeAppTests` (10 grün am Mac) |
| Dateien hineinziehen | aus Dateien-App | aus dem Finder | unverändert | – |

## 3. Tests

**Rot zuerst** (`eb5eef36`, Hilfstypen mit dem alten Verhalten), Mac, nur die neuen Tests und der geänderte
Palettentest: 9 Tests, 8 rot, 1 grün (`testIPadInputIsUnchanged`), Protokoll `~/Studora-Builds/macbed-red.log`.

**Grün** (`9aecdc08`), Mac (`platform=macOS,arch=arm64,variant=Designed for iPad`, `DEVELOPMENT_TEAM=78MQGF36BD`),
Klassen rund um Editor und Wischen: 77 Tests, 75 bestanden, 2 übersprungen (wie in `MAC-B28`: Rückgängig-Gruppen und
Riesentest), 0 Fehler – `MacBedienungTests` 10, `EditorPaletteTests` 18, `EditorFreezeAppTests` 10,
`EditorScaleTests` 10 (2 übersprungen), `FlashcardTrainerTests` 13, `CommunityChannelAppTests` 16
(`~/Studora-Builds/macbed-green.log`). Ein ganzer Mac-Lauf ist wegen der Testumgebung (Bedienungshilfen-Baum,
StoreKit, WebKit-Cookies, siehe `MAC-B28` Abschnitt 3) nicht grün und war hier nicht das Ziel.

**iPad-Simulator** (frischer Export `export-macbed` von 3fee4b70, Klon „iPad MacBed Gegenlauf“ von 4495AA80, danach
gelöscht): **1.397 Tests, 1.379 bestanden, 18 übersprungen, 0 Fehler** (vorher 1.387 + 10 neue; die 18 Übersprungenen
wie bisher), `~/Studora-Builds/macbed-sim-test.log`.

## 4. Commits

| Commit | Inhalt |
|---|---|
| `eb5eef36` | Tests zuerst (rot); Editor liest Zeichen- und Rollflächen-Einstellung aus `EditorPointer.config`, Tasten angemeldet |
| `9aecdc08` | Maus blättert/schreibt, Trackpad-Wischen, Tasten im Editor, Reiter per Tastatur, Community ← →, Gliederung per Kontextmenü, Einstellungstext am Mac |
| `3fee4b70` | Cmd-R für Dokumentliste und Nachrichten |

iPad: Gesten, Standard und Texte unverändert. Neu auch am iPad, nur mit angeschlossener Tastatur wirksam: die Tasten im
Editor, die Reiter-Tasten, Cmd-R, ← → im Community-Leser; dazu das Kontextmenü „Entfernen“ in der Gliederung.

## 5. Vom Inhaber am Mac von Hand zu prüfen

Ich habe am Mac keine Maus- oder Tastaturereignisse geschickt (der Inhaber arbeitete am Rechner). Geprüft sind
Einstellung, Logik und die Wirkung der Befehle im echten Editor per Test, nicht das Gefühl mit echter Hand:

1. Dokument öffnen: Standard „Maus blättert“ → mit gedrückter Maustaste ziehen verschiebt das Dokument hoch/runter;
   gezoomt (Cmd +) auch links/rechts. Es entsteht **kein** Strich.
2. „Maus blättert“ antippen → „Maus schreibt“: Ziehen schreibt mit dem Stift der Palette; Trackpad (zwei Finger) und
   Mausrad rollen weiter.
3. Zwei Finger waagerecht auf dem Trackpad (nicht gezoomt): eine Seite weiter/zurück; Richtung bei „Natürliches
   Scrollen“ wie erwartet? Schwelle 60 pt angenehm?
4. ← → ↑ ↓, Leertaste, Cmd-↑/↓, Cmd +/−/0 im Dokument; während man in der KI-Hilfe tippt, bewegen die Pfeile nur den
   Cursor.
5. Ctrl-Tab mit zwei offenen Dokumenten; Cmd-R in Nachrichten.
6. Blätter (Sheets) ohne Schließen-Knopf lassen sich am Mac nicht wegwischen – beim Durchklicken darauf achten.
