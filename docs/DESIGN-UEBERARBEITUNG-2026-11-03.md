# Design-Überarbeitung iPad/Mac – 3. November 2026

Auftrag des Inhabers: „Nehme diese Sachen ernst für unser Design überarbeiten“. Grundlage sind drei Leitfäden, die
hier als **[FD]**, **[TS]** und **[UX]** zitiert werden:

- **[FD]** frontend-design (Anthropic-Plugin): Zurückhaltung, „eine Sache mutig, der Rest ruhig“, Struktur ist
  Information, keine Vorlagen-Ticks (Pfeil „→“ an Links, Werbesprache), Leerzustände als Einladung.
- **[TS]** taste-skill v2, Kapitel „App screens“ (`references/app-screens.md`): Farbe auf Daten statt auf Chrom,
  Kennzahlen sind Schrift statt Kacheln, flache Flächen, keine Verläufe/Glows/Deko-Symbole, Navigation tritt zurück.
- **[UX]** ui-ux-pro-max (`references/pro-rules.md`, `data/stacks/swiftui.csv`): Kontrast 4,5:1 für Text in hell und
  dunkel, Trefferflächen ≥ 44 pt, Dynamic Type, ein Symbolsatz, semantische Farb-Tokens statt Systemfarben je
  Bildschirm, Zustände sichtbar (auf-/zugeklappt).

Die Marke bleibt: Indigo-Akzent, Inter, Karten mit 12er-Radius, die Modulfarben. Neue Farben sind nur dunklere bzw.
tiefere Stufen der vorhandenen Töne. Funktionen, VoiceOver-Texte und `accessibilityIdentifier` sind unverändert
(neu nur: Wert „aufgeklappt/zugeklappt“ an Neuigkeiten-Zeilen, Name „Mehr“ am Ordnermenü, Kennungen
`file.openIn`/`file.preview`).

Bereich dieser Runde: Übersicht inkl. Neuigkeiten, Dokumente/Bibliothek inkl. Vorschau von Nicht-PDF-Dateien,
Editor-Leiste, KI-Hilfe, „Daneben öffnen“, Lösung daneben. Module, Einstellungen, Community und Kalender
übernehmen andere Agents; sie nutzen das Designsystem unten.

Bildschirmfotos (iPad Pro 11, hochkant, Demo-Inhalte): `~/Studora-Builds/design/vorher/` und
`~/Studora-Builds/design/nachher/` (gleiche Dateinamen).

## 1. Designsystem (für alle Agents verbindlich – bitte nachziehen)

Nur dieser Agent ändert `Design/UFTheme.swift`, `UFComponents.swift`, `UFKit.swift`. Neu bzw. geändert:

| Token / Baustein | Änderung | Grundsatz |
| --- | --- | --- |
| `UF.muted` | hell `0x7a8199 → 0x666c84`, dunkel `0x7f879d → 0x8a92a8`. Vorher 3,5:1 auf `surface2` (hell) bzw. 4,4:1 (dunkel), jetzt ≥ 4,6:1 überall. | [UX] Text-Kontrast 4,5:1 in beiden Modi; [TS] „Running text in the full ink … grey is for secondary notes“ – auch Grau muss lesbar sein |
| `UF.okText`, `warnText`, `badText`, `infoText` (neu) | Schrift auf den weichen Flächen (`*Soft`). Hell dunkler gemischt (z. B. Orange auf `warnSoft` 2,6:1 → 4,9:1), dunkel = bisherige Töne. `UFTone.fg` und `UFStatusPill` nutzen sie. **Für Text auf `*Soft` immer `*Text` nehmen, nie `UF.ok/warn/bad/info`.** | [UX] Kontrast; Token-getriebenes Theming |
| `UF.accentFill`, `accentFillPressed`, `okFill` (neu) | Flächen mit weißer Schrift: Hauptknopf, aktives `UFSegPill`, „ok“-Knopf, Tarif-Schloss. Dunkel `0x5561d6` statt `0x7b86f0` (Weiß darauf 3,2:1 → 5,2:1). **Weiße Schrift nie auf `UF.accent`, sondern auf `UF.accentFill`.** | [UX] Kontrast dunkler Modus, „State contrast parity“ |
| `UFButtonStyle` | Schrift folgt Dynamic Type (wie `ufFont`, in Standardgröße unverändert); `.danger` schreibt in `badText`. | [UX] Dynamic Type |
| `UFTabs` | Schrift folgt Dynamic Type. | [UX] Dynamic Type |
| `UFEmpty` | Symbol 30/26 pt in gedämpftem `muted` statt 36 pt `lineStrong`, 24/20 pt statt 32 pt Luft, Text höchstens 420 pt breit. Leere Karten werden nicht mehr halb so hoch wie der Bildschirm. | [FD] „An empty screen is an invitation to act“; [UX] lesbare Zeilenlänge |
| `UFPaneHeader` (neu) | Kopf für Spalten neben der PDF: 44 pt hoch, Titel 14,5/650, Symbol im Akzent, Schließen mit 44-pt-Fläche, Linie `UF.line`. | [UX] Konsistenz, Trefferfläche 44 pt; [FD] Struktur ist Information |
| `UFOptionalIdentifier` (neu) | setzt eine Kennung nur, wenn eine übergeben wird. | – |

Hinweise für die anderen Bereiche (Vorschläge, nicht umgesetzt): Verläufe und Deko-Symbole auf Karten (z. B.
`ModuleCard` mit Verlauf und blassem 44-pt-Symbol) widersprechen [TS] „No gradients, no decorative shapes“; Text
`UF.ok/warn/bad` auf weißen Flächen ist grenzwertig (Rot 4,4:1) – für Text `*Text` verwenden.

## 2. Übersicht (DashboardView, NewsCard)

| Änderung | Warum (Leitfaden) |
| --- | --- |
| Drei Kennzahlen immer in einer Reihe (ab 640 pt Breite), vorher hochkant 2 + 1 mit leerer Zelle. | [TS] „rows ended ragged“ als Fehler; „the grid's arithmetic closes“ |
| „nachzuholen“: roter Rahmen um die Karte entfernt, die Zahl bleibt rot. | [TS] „Colour goes on data, not chrome“ |
| „Nächste Termine“: Titel in Textfarbe statt ganz in Linkfarbe, Pfeil rechts als Hinweis „öffnet“; Symbol Kalender statt Fahne (Fahne trägt schon „Abgaben & Prüfungen“). „Neu aus Stud.IP“: Titel ebenso in Textfarbe. „Diese Woche“: Symbol Aufgaben statt Uhr (Uhr trägt „Heute an der Uni“). | [FD] „Visual structure is information“ – gleiches Symbol für Verschiedenes verwirrt; [TS] Farbe sparsam |
| Neuigkeiten: kleiner Pfeil zeigt, dass eine Zeile aufklappt, dreht sich beim Öffnen; VoiceOver sagt „aufgeklappt/zugeklappt“. | [UX] Zustände (expanded) sichtbar und angesagt |
| Leerzustand „Heute für dich geplant“ kompakter (siehe `UFEmpty`). | [FD] Leerzustand als Einladung, nicht als Fläche |

## 3. Dokumente / Bibliothek

| Änderung | Warum |
| --- | --- |
| Kopf: nur „Neu“ als Hauptaktion neben dem Titel; Suche, Modulfilter, Sortierung und Ansicht in einer eigenen Werkzeugzeile. Vorher fünf Steuerelemente rechts vom Titel, „Neu“ brach hochkant allein in eine Zeile. | [TS] „The most frequent job is one click from the first screen“, eine Hauptaktion; [FD] Struktur |
| Unterzeile ohne Werbesatz („Übersichtlich, schnell und fokussiert.“ entfällt). „Alle anzeigen →“ ohne Pfeil. | [FD] „Describe what something is … rather than selling it“; „→ appended to link text“ als Vorlagen-Tick |
| Ordnerkarte: Farbwelle (Verlauf) durch ruhige Fläche in der Modulfarbe ersetzt, Mappe flach ohne farbigen Schein, Initialen-Kachel ohne Schatten (2-pt-Rand in der Kartenfarbe). Die Mappe bleibt das eine prägende Element. | [TS] „No gradients … no glows“, „Surfaces are separated by a tone step“; [FD] „Spend your boldness in one place“ |
| Ordnermenü „…“: 44-pt-Trefferfläche, VoiceOver-Name „Mehr“. | [UX] Touch target ≥ 44 pt, Icon-Knöpfe mit Namen |
| **Nicht-PDF-Dateien (Word, PowerPoint, Excel, Bilder …):** statt leerer Seite mit „Diese Datei ist keine PDF …“ und Knopf jetzt die eingebettete Vorschau (QuickLook, `QLPreviewController` in SwiftUI) direkt in der App; darüber eine schmale Leiste mit Titel, „Vorschau · nur ansehen“ und dezentem „Öffnen in …“ (Teilen-Blatt des Systems). Nicht geladen bzw. Fehler: wie bisher die Meldung. | Auftrag; [FD] „Treat … emptiness as moments for direction“; [TS] Inhalt statt Hinweis |
| Dokument-Reiter über dem Editor in UF-Farben (Akzent-weich aktiv, `surface2` sonst) statt Systemfarben; Schließen-„x“ mit größerer Fläche. | [UX] Semantische Tokens statt Systemfarben je Bildschirm |
| Beim Öffnen eines Dokuments über eine Route (Übersicht „Weiterlernen“, Suche) blieb hochkant die Dokumentliste über dem Dokument und der KI-Hilfe liegen (`.detailOnly` griff vor dem ersten Bild nicht); jetzt nach dem ersten Bild erneut gesetzt. Siehe vorher/06, 07, 14. | [UX] Inhalt nicht verdecken |

## 4. Editor

| Änderung | Warum |
| --- | --- |
| Rechte Leiste in Gruppen nach Aufgabe (ab iOS 26 mit `ToolbarSpacer`, je Gruppe eigene Glasfläche): Sicherungsstand · Lesen (Vorlesung bis hier, Suchen, KI-Hilfe, Geteilt) · Schreiben (Stift/Finger, Tinte/Objekte, Ebenen) · Teilen und Mehr. Vorher elf Knöpfe in einer Kapsel. | [FD] „Visual structure is information“; [UX] Navigation nicht überladen, Gruppierung |
| Sicherungsstand (Wolke) ohne Glasfläche, damit er nicht wie ein Knopf aussieht (`sharedBackgroundVisibility(.hidden)`). | [UX] „Semantic native controls“ – Anzeige ≠ Knopf |
| KI-Hilfe, Dokument daneben und Lösung daneben haben denselben Kopf (`UFPaneHeader`): gleiche Höhe, Schrift, Linie, Schließen mit 44 pt; „Neu“ in der KI-Hilfe als ruhiger Textknopf; „nur ansehen“ als neutrales Abzeichen. Linien in `UF.line` statt Systemtrennern (im Dunkeln vorher heller als die übrigen Linien). | [UX] Konsistenz, Trefferflächen, Dark-Mode-Parität |
| KI-Hilfe leer: Überschrift „Frag etwas zur offenen Seite“ mit Erklärung darunter statt eines grauen Satzes. | [FD] Leerzustand als Einladung |
| „Daneben öffnen“: Symbole der App (UFIcon) statt SF Symbols in der Liste, Überschriften in der h3-Stufe, Vorlagen ohne Schatten (Rand `lineStrong`), Trennlinien `UF.line`. Lösung daneben: Hintergrund `UF.surface2`, Seitenbeschriftung in `muted`, Bilder ohne Schatten. Ziehgriff der geteilten Ansicht in UF-Linienfarben. | [UX] ein Symbolsatz, Tokens; [TS] keine Schatten an ruhenden Dingen |

## 5. Werkzeuge für Bildvergleiche (nur Debug-Builds)

- `-UFDemo YES` legt vor `-UFRoute` die Demo-Inhalte an, wenn sie fehlen.
- `-UFDocPanel tutor|companion` öffnet im Editor gleich die KI-Hilfe bzw. „Daneben öffnen“.

Die Word-Testdatei in den Fotos 12/13 wurde nur im Simulator in die Datenbank gelegt (kein Teil des Repos).

## 6. Offen / Vorschläge für später

- Kleine Knöpfe (`UFButtonStyle .small`, 28 pt) liegen unter 44 pt; eine größere Trefferfläche ohne sichtbare
  Größenänderung bräuchte einen eigenen Layout-Baustein.
- `NavigationSplitView` im Editor zeigt links weiterhin Apples Spalten-Knopf (eigene Kapsel); eine eigene Lösung
  gehört in die Editor-Navigation.
- Weitere feste Schriftgrößen (`.font(.uf(…))` ohne Skalierung) in `UFSelect`, Badges in Tabellen.
- Karten-Schatten `.sm` im hellen Modus: nach [TS] reicht die Linie; nicht geändert, weil alle Bereiche betroffen
  sind – gemeinsam entscheiden.
