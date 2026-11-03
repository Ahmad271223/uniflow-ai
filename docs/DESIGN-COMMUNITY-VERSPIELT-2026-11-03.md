# Community verspielt, aber modern (3.11.2026)

Auftrag des Inhabers: „Schau dir die alten Design-Repos an und bau sie ein, mach es schön – die Community darf verspielt
sein, aber modern und einfach zu bedienen.“ Bereich: `Views/CommunitySpacePage.swift`, `Views/CommunityChannelView.swift`,
`Views/CommunityViews.swift`, neu `Views/CommunityStyle.swift` (Farben und Bausteine der Community). Keine neue Funktion,
keine zusätzlichen Schritte; VoiceOver-Texte und `accessibilityIdentifier` bleiben (Tests unverändert grün).

Leitfäden: **[TS]** taste-skill (`references/app-screens.md`: „Give the product a face“, Farbe auf Daten, ein eigenes
Element des Produkts; `motion.md`: Rückmeldung unter der Hand, ein geschützter Moment, keine einheitliche Bewegung),
**[UX]** ui-ux-pro-max (Kontrast 4,5:1 hell/dunkel, Tippflächen ≥ 44 pt, Dynamic Type, ein Symbolsatz, Bewegung
reduzieren), **[FD]** frontend-design (eine Sache mutig, Leerzustand als Einladung mit einer Handlung), **[MP]**
motion-primitives über `UFMotion` (gestaffeltes Erscheinen, Druck-Rückmeldung). Inhaber-Vorliebe aus
`DESIGN-MODULE-COMMUNITY-2026-11-03.md`: die alten Modulkarten mit Farbtönung, Deko-Symbol und Kacheln.

## Was sich geändert hat

| Änderung | Leitfaden |
|---|---|
| **Fachfarbe je Community** (`CommunityTint`): Farbe des Moduls aus dem Abgleich (`/api/modules`, Moduldetail), sonst eine feste Farbe derselben Palette (`ModuleColors.palette`) aus dem Schlüssel; Lerngruppen im Akzent. Schrift in der Fachfarbe wird Richtung Textfarbe gemischt (`ink`), damit auch Oliv/Ocker lesbar bleiben. | [TS] Produkt bekommt ein Gesicht; Inhaber: Modulkarten mit Tönung |
| **Kopf der Community-Seite** als Kachel wie die alten Modulkarten: blasse Tönung → Fläche, leicht gedrehte Kürzel-Kachel in der Fachfarbe, ruhiges Deko-Symbol (16 %) rechts oben. | [FD] eine mutige Stelle; Inhaber-Vorliebe |
| **„Deine Communities“** als Kachelraster statt Zeilenliste: Kürzel in der Fachfarbe, grüner Haken = beigetreten (VoiceOver: Wert „beigetreten“), Titel bis zwei Zeilen, dieselben Knöpfe Öffnen/Ansehen, Beitreten/Verlassen, „Frühere Kurse (N)“ unverändert. | Inhaber: Kacheln; [UX] Zustand sichtbar |
| **Personen-Kreise** (`CommunityAvatar`): Initialen in einer festen Pastellfarbe aus dem Pseudonym (8 Paare, FNV-Hash, auf jedem Gerät gleich), eigene Person im Akzent; überlappende Reihen (`CommunityAvatarStack`, „+N“) auf Karten, Listenzeilen und bei „n Antworten“. Vorschau des eigenen Pseudonyms in den Einstellungen. | [TS] „its people“; [UX] Text auf Tonflächen ≥ 4,5:1 (jedes Paar hat eine eigene dunkle/helle Textstufe) |
| **Etiketten der Art** (`CommunityKindTag`): je Art ein weiches Paar mit Symbol – Vorlesung himmelblau/Buch, Hörsaalübung lavendel/Säulen, Übung mint/Stift, Gruppenübung petrol/Personen, Tutorium pfirsich/Hut, Klausur rosa/Prüfung, eigene Notizen butter/Notiz. | [UX] Farbe nie allein – immer mit Symbol und Wort |
| **Karten der Wochen**: echte Karte (Fläche, Haarlinie, Radius `rLg`), Vorschau eingerückt; ohne PDF-Vorschau ein schräg gelegtes Blatt mit Zeilen in der Farbe der Art. Titel zwei Zeilen reserviert (Reihe fluchtet), unten Kreise + „n Personen“ + Kommentarzahl. Ohne geteilte Notizen gestrichelt und gedämpft. `UFPressStyle` und `.hoverEffect(.lift)` (Zeiger auf iPad/Mac). | [MP] Druck-Rückmeldung; [TS] fehlende Werte ehrlich |
| **Wochenkopf** mit Wochenmarke (Zahl in der Fachfarbe) und „3 Blätter · 2 mit Notizen“. „Neueste geteilte Notizen“ mit kleinem Funken-Symbol. | [FD] Struktur ist Information |
| **Fragen und Antworten**: jede Frage als eigene Karte mit 38-pt-Kreis, „Beantwortet“-Abzeichen, darunter Gefällt-mir-Kapsel und Antworten mit den Kreisen derer, die geantwortet haben; gestaffeltes Erscheinen beim ersten Mal (`ufAppear`). Eingabe mit eigenem Kreis. | [MP] animated-group; [UX] 44-pt-Ziele |
| **Gefällt mir** (`CommunityLikeStar`): gemocht = gefüllter Stern in Butter-Gelb auf weicher Kapsel; beim Mögen springt der Stern kurz auf (1,35 → 1, Feder) und sechs Funken fliegen heraus (0,45 s), dazu leichtes Haptik-Feedback. „Bewegung reduzieren“ und Tests: nur der Farbwechsel. | [TS] ein geschützter, freudiger Moment; [UX] reduce motion |
| **Leser einer Person**: Kreis neben dem Namen in der Personenleiste, Kommentare mit Kreisen und eingerücktem Text; schwebende Leiste unverändert (Erweiterungspunkt `extraActions` bleibt), Gefällt-mir wie oben. | Konsistenz |
| **Leerzustände** (`CommunityEmptyState`): kleine Komposition aus Symbolen (Kreis in der Fachfarbe, zwei Pastell-Begleiter, Funken) statt eines grauen Symbols, ein Satz, höchstens eine Handlung (z. B. „Zur Community“, wenn es die Community nicht gibt). Nicht beigetreten: Einladung auf der Seite, unten nur noch der große „Beitreten“-Knopf (vorher stand der Hinweis doppelt). | [FD] Leerzustand als Einladung, eine Handlung |
| Fehler behoben: Unter `ufTabPanel` (ZStack) lagen „Neueste geteilte Notizen“ und „Fragen und Antworten“ bzw. die Umschalter „Wochen/Liste“ und die erste Woche übereinander; jetzt je Reiter ein eigener Stapel. | – |
| Kontrast: Hinweis „kein iCloud-Container“ in `UF.warnText` statt `UF.warn`. | [UX] Text auf Fläche |

## Fotos

iPad-Breite 1024 pt, hell und dunkel, erfundene Daten (Fake-Dienst wie in `CommunityChannelAppTests`):
`/private/tmp/claude-501/-Users-ahmadfakih-uniflow-ai/b2e6b52d-8140-52f8-a368-082b8202c588/scratchpad/community-design/`
(01 nicht beigetreten, 02 Diskussion, 03 Dokumente nach Wochen, 04 Liste, 05 leer, 06 „Wer hat geteilt“, 07 Leser mit
Diskussion, 08 Deine Communities; je `-light`/`-dark`).

## Offen

- Kacheln in „Deine Communities“ sind je Reihe unterschiedlich hoch, wenn eine Beschreibung umbricht (LazyVGrid streckt
  nicht); bewusst so gelassen.
- Die Fachfarbe in der Liste kommt über den Modulnamen; hat jemand sein Modul lokal umbenannt, greift die feste
  Ersatzfarbe aus dem Schlüssel.
