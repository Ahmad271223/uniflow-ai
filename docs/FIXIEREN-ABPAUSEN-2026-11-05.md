# Bildschirm fixieren und zum Abpausen einfrieren (05.11.2026)

Wunsch des Inhabers (05.11.2026, wörtlich): „gibt es leute die ab und zu technische zeichnungen dann müssen die was
abpausen vom ipad und damit das nicht verrutscht soll es im editor eine funktion geben bildschirm fixieren oder einfrieren
damit das nicht verrutscht immer“.

Wer technische Zeichnungen anfertigt, legt Papier auf das iPad und paust die Seite ab oder zeichnet genau auf der Seite.
Dabei darf sich die Seite nicht bewegen: kein Scrollen, kein Zoom, kein Seitenwechsel durch Hand, Papier oder Stift.

## 1. Zwei Stufen

| | „Ansicht fixieren“ | „Zum Abpausen einfrieren“ |
| --- | --- | --- |
| Zweck | genau zeichnen, ohne dass die Seite verrutscht | Papier auflegen und abpausen |
| Zoom, Scrollen, Pinch, Doppeltippen | gesperrt | gesperrt |
| Seitenwechsel (Seitenleiste, Suche, Gehe zu Seite, Gliederung, KI-Hilfe-Sprung) | gesperrt | gesperrt |
| „100 %“ (Einpassen) | gesperrt | – (nicht sichtbar) |
| Zurück-Wischen vom Rand, Seitenleiste der geteilten Ansicht per Wischen, Tippen auf die Statusleiste, Tastatur-Scrollen | gesperrt | gesperrt |
| Apple Pencil und Werkzeuge (Palette, Objekte) | **schreiben weiter** | keine Eingabe, auch nicht der Stift |
| Leisten, Seitenleiste, KI-Hilfe, Dokument daneben, Hinweise, Reiter der Bibliothek | bleiben | ausgeblendet, die Seite füllt den Bildschirm im **aktuellen Zoom** |
| Bildschirm | wie immer | bleibt an (`isIdleTimerDisabled`), danach wie vorher |
| Helligkeit | wie immer | auf Wunsch „Helligkeit auf Maximum“, danach wieder wie vorher |
| Kontrast | – | auf Wunsch „Kontrast für Abpausen“: weißer Hintergrund ohne Seitenschatten |
| Anzeige | Abzeichen „Ansicht fixiert“ mit „Lösen“ oben links über der Seite | kleines Schloss in der Ecke (Seite der freien Hand), 30 % Deckkraft |
| Lösen | „Lösen“, ⌘L, Menü „Ansicht lösen“ | Schloss etwa **2 Sekunden** halten (Fortschrittsring), Esc auf der Tastatur, VoiceOver-Aktion „Entsperren“ |

Entsperren vom Abpausen führt zur Stufe davor zurück: War die Ansicht vorher fixiert, bleibt sie fixiert; sonst ist alles
frei. Kurz antippen oder loslassen vor 2 Sekunden entsperrt nicht (Papier, das auf das Schloss drückt, löst nichts aus,
solange es nicht zwei Sekunden auf genau dieser Stelle liegt). ⌘L löst das Abpausen nicht.

Wo das Fixieren an Grenzen stößt: Ist die Seite schmaler als die Ansicht (Seitenleiste oder KI-Hilfe geht zu, Leisten
verschwinden beim Abpausen), legt PDFKit sie waagerecht in die Mitte; Zoom und Höhe bleiben. Am oberen bzw. unteren Rand
des Dokuments begrenzt der Scrollbereich die Stelle. Beides passiert nur durch eine bewusste Handlung (Fenster, Leisten),
nie durch Berührung.

## 2. Einstieg

- Editor, Menü „Mehr“ (…), Abschnitt „Bildschirm fixieren“: „Ansicht fixieren“ / „Ansicht lösen“, „Zum Abpausen
  einfrieren“, Schalter „Helligkeit auf Maximum“ (nicht am Mac) und „Kontrast für Abpausen“.
- Tastatur: ⌘L fixiert bzw. löst die Ansicht.
- Beim ersten Mal erklärt ein Dialog beide Stufen (mit den beiden Schaltern) und startet die gewählte.

Der Zustand gilt nur für die offene Sitzung des Dokuments und wird nicht gespeichert; beim Schließen des Dokuments (auch
Wechsel des Reiters) ist alles gelöst, Bildschirm und Helligkeit wie vorher. Gemerkt werden nur der Wunsch „Helligkeit
auf Maximum“ (`uniflow.freeze.maxBrightness`) und dass die Erklärung gesehen wurde (`uniflow.freeze.introSeen`). Geht die
App beim Abpausen in den Hintergrund, kommt die Helligkeit vorerst zurück (iPadOS behielte sie sonst bis zur Sperre des
Geräts) und ist beim Zurückkommen wieder hell.

Geteilte Ansicht: „Ansicht fixieren“ fixiert auch das Dokument daneben; beim Abpausen ist es ausgeblendet (danach lädt es
neu). Gedrehte Seiten verhalten sich wie andere. Die Textansicht (Word, PowerPoint, Audio, `TextDocumentView`) bietet
die Funktion nicht an: dort gibt es nichts abzupausen und keinen Stift. Mac („Designed for iPad“): ohne
Helligkeitsschalter, sonst gleich.

## 3. Umsetzung

| Teil | Datei |
| --- | --- |
| Stufen, Bildschirm anlassen, Helligkeit merken und zurückstellen, Halten von 2 s (plattformunabhängig, für die spätere iPhone-Fassung) | `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/EditorFreeze.swift` |
| iPad-Bildschirm (`SystemFreezeScreen`), Sitzung je Dokument (`EditorFreezeSession`), Sperren im Editor (Gesten, Stelle und Zoom halten, Systemgesten, Kontrast) | `apps/apple/UniFlow/Editor/EditorFreezeLock.swift` |
| `freezeMode`, `traceContrast`; Sperren von `goToPage`, `show(selection)`, `fitWidth`, Einpassen nach Layout, Neuaufbau der Seiten | `apps/apple/UniFlow/Editor/PDFEditorController.swift` |
| keine Palette beim Abpausen (`pickerAllowed`) | `apps/apple/UniFlow/Editor/CorrectionMode.swift` |
| Abzeichen, Sperre mit Schloss (Esc, VoiceOver), Erklärung, Texte, Meldung an die Bibliothek | `apps/apple/UniFlow/Views/FreezeViews.swift` |
| Menü, ⌘L, Ausblenden der Leisten, Statusleiste und Home-Balken, Startargument `-UFDocFreeze view|trace` (nur Debug) | `apps/apple/UniFlow/Views/DocumentView.swift` |
| Reiter der Bibliothek beim Abpausen aus | `apps/apple/UniFlow/Views/Views.swift` |

So sperrt der Editor:
- Scroll-Ansicht von PDFKit: `isScrollEnabled = false` (Finger, Trackpad, Mausrad), Pinch aus, `scrollsToTop` aus,
  `allowsKeyboardScrolling` aus; Doppeltipp-Gesten von PDFKit aus (eigene Objekte auf der Seite behalten ihre).
- Navigation: `interactivePopGestureRecognizer` und `UISplitViewController.presentsWithGesture` aus, beim Lösen und beim
  Verlassen des Editors wieder wie vorher.
- Stelle: beim Fixieren Seitenschlüssel, Punkt der Seite an der linken oberen Ecke und Zoom merken; nach jedem Layout
  (Leisten, Seitenleiste, Drehen, geteilte Ansicht) und nach einem Neuaufbau der Seiten (Abgleich, Seite eingefügt) Zoom
  und Stelle wiederherstellen statt neu einzupassen. Ein Zoom, der doch durchkommt, wird zurückgenommen.
- Abpausen: `pdfView.isUserInteractionEnabled = false` (keine Berührung erreicht PDF, Zeichenflächen oder Objekte),
  darüber eine SwiftUI-Fläche, die jede Berührung schluckt; Palette weg, Auswahl und Tastatur weg; Statusleiste aus,
  Home-Balken zurückhaltend, Systemgesten am Rand verzögert (`defersSystemGestures`).

## 4. Tests

- Kern (`swift test`): `EditorFreezeTests` – Zustandsfolge, Ruhezustand und Helligkeit zurück (auch beim Schließen und
  im Hintergrund), ohne Helligkeit am Mac, Entsperren erst nach 2 s Halten, Abbruch.
- App: `EditorFreezeAppTests` – im Editor mit lokalem Backend: fixiert ändern Gehe-zu-Seite, Einpassen, ein
  durchgerutschter Zoom und eine neue Fensterbreite Zoom und Stelle nicht, der Stift trifft weiter die Zeichenfläche und
  der Strich wird gespeichert, Gegenprobe nach dem Lösen; gedrehte Seiten; Zurück-Wischen aus und wieder an; Abpausen:
  keine Berührung erreicht die Seite (Trefferprüfung), kein Strich, Stelle bleibt, kurzes Halten entsperrt nicht, 2 s
  schon, Bildschirm und Helligkeit wie vorher; echter Zeitgeber; VoiceOver-Aktion „Entsperren“; Abzeichen „Lösen“; im
  ganzen Dokument verschwinden beim Abpausen Leisten und Seitenanzeige und kommen nach „Entsperren“ zurück.
- Echte Finger und Stifte gibt es im Simulator-Test nicht: Gesten werden über ihren Zustand und die Trefferprüfung
  geprüft. Am Gerät prüfen: Papier auflegen, mit der Hand darüber streichen, mit dem Stift durch das Papier drücken –
  nichts darf sich bewegen oder schreiben; Schloss halten entsperrt.
