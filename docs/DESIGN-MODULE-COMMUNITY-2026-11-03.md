# Design-Überarbeitung Module und Community (3.11.2026)

Bereich: `apps/apple/UniFlow/Views/Modules/*` (Meine Module, Moduldetail mit Reitern, Wochentests, „Aus Stud.IP“) und
`apps/apple/UniFlow/Views/CommunityViews.swift` (Communities, Lösungslisten, Leser, Community-Einstellungen).
Das Designsystem (`Design/*`) ist unverändert; benutzt werden nur vorhandene `UF.*`-Farben, Radien und Bausteine.
Keine Funktionsänderung: dieselben Abrufe, Ziele und Aktionen; `accessibilityIdentifier` und VoiceOver-Namen bleiben.

Leitfäden: frontend-design (Zurückhaltung, ein Akzent, Leer- und Fehlerzustände als Wegweiser), taste-skill
(`references/app-screens.md`: Farbe auf Daten statt Rahmen, Kennzahlen als Schrift statt Kacheln, flache Flächen,
Tabellen aus Linien und Ausrichtung, fehlende Werte als grauer Strich, Laden in der fertigen Form), ui-ux-pro-max
(Tippflächen ≥ 44 pt, Rückmeldung beim Antippen ohne Lageänderung, Dynamic Type, Kontrast hell/dunkel, keine Emoji als
Symbole, semantische Farb-Tokens).

Fotos (iPad Pro 11, Demo-Inhalte, `-UFPlan plus`):
vorher `~/Studora-Builds/design/vorher/module-community/`, nachher `~/Studora-Builds/design/nachher/module-community/`
(01/02 Meine Module hell/dunkel, 03–05 Demo-Modul hell/dunkel/unten, 06–08 Modul ohne Dokumente, 09 Community-Seite,
10 Demo-Modul mit Textgröße „Bedienungshilfen L“).

## Meine Module (Karten, Liste)

| Änderung | Grund |
|---|---|
| Modulkarte ohne Farbverlauf und ohne blasses Deko-Symbol; flache `UF.surface` mit Haarlinie `UF.line`, Radius `UF.rLg` | Verlauf und Deko-Icon sind Vorlagen-Merkmale („gradient washes as decoration“); die Fläche wird ruhig, die Karten unterscheiden sich durch ihren Inhalt |
| Modulfarbe nur noch auf Kürzel, Fortschrittsbalken, Terminsymbol und „n neue Inhalte“ | Farbe trägt Daten, nicht den Rahmen; fünf bunte Karten nebeneinander wirkten unruhig |
| Beschreibung unter den Titel gezogen (Titel h2 17,6/650, Text 13,1 gedimmt), zwei Zeilen reserviert | klare Hierarchie Titel → Erklärung; Karten derselben Reihe fluchten |
| Kennzahlen „0 Dateien · 0 Aufgaben · Wochentests“ als eine Schriftzeile unter einer Haarlinie statt Symbol + großer Zahl | „KPIs are type, not tiles“; die großen fetten Nullen dominierten die Karte |
| „Nächster Termin“ als Tonstufe `UF.surface2` statt Rahmen in der Karte | weniger Rahmen-in-Rahmen, Separation durch eine Tonstufe |
| Zahlen mit gleich breiten Ziffern (`monospacedDigit`) | Prozent und Anzahlen springen nicht und stehen untereinander sauber |
| Antippen: Karte kurz leicht abgedunkelt, Zeilen mit `UF.surface2` (eigene `ModuleCardPressStyle`/`ModuleRowPressStyle`) | sichtbare Rückmeldung ohne Größen- oder Lageänderung |
| Liste und Stud.IP-Kurse ohne Modul: neutrale Ordnerkachel statt Akzentfläche, Zeilen ≥ 44 pt, Pfeil gedimmt, kein Schatten um die Liste | Akzent auf jeder Zeile war Dekor; flache Flächen |
| Laden: Platzhalter in Form der Seite (Titel, Untertitel, zwei Karten) statt eines großen Blocks | kein Springen beim Eintreffen der Daten |
| Fehler: Karte mit Grund und „Erneut versuchen“ (ruft denselben Ladevorgang) | ein Fehler zeigt den Weg weiter, nicht nur den Grund |
| Leer: „Noch keine Module. Nach dem ersten Abgleich mit Stud.IP erscheinen sie hier.“ | sagt, was passiert und was zu tun ist |

## Moduldetail (Kopf, Kennzahlen, Reiter, Wochenblöcke)

| Änderung | Grund |
|---|---|
| Drei Kennzahl-Kacheln → eine Karte mit drei Zellen, getrennt durch Haarlinien (`ModuleKPIStrip`); untereinander, wenn eine Zelle keine 200 pt bekommt | auf dem iPad hochkant brachen die Kacheln als 2 + 1 um (verwaiste Kachel); eine Leiste liest sich als zusammengehörige Zahlen |
| Fehlende Werte („–“) in `UF.muted` statt Textfarbe | ein voller Strich liest sich wie „lädt“ |
| Kopf: Aktionen mittig zum Titel, Kürzel oben bündig (auch bei umbrechendem Titel mit großer Schrift), Kürzel für VoiceOver ausgeblendet | ruhige Kante; der Modulname wird ohnehin gelesen |
| Wochenblock: Pfeil zeigt den Zustand (rechts = zugeklappt, vorher immer nach unten), gedimmt; benannte VoiceOver-Aktion „Auf-/Zuklappen“ | Zustand sichtbar und bedienbar ohne Sehen |
| Gruppenüberschriften (Vorlesung, Übung …) kleiner (12,8/600), bündig mit den Dokumentzeilen | Hierarchie Woche → Gruppe → Dokument |
| Dokumentzeile: Titel in Textfarbe statt Linkfarbe, Typsymbol `UF.text2`, nur „Neu“ im Akzent; Zeile ≥ 44 pt; Schrift folgt Dynamic Type | eine Liste aus lauter blauen Titeln hat keine Hierarchie; feste Größen skalierten vorher nicht |
| Reiter Vorlesungen/Übungen/…: Zeilen durch Haarlinien getrennt; leer: Symbol + „Keine Übungen in diesem Modul.“ statt „Nichts vorhanden.“ | Tabellen aus Linien; der leere Rahmen sagt, was fehlt |
| Übersicht ohne Dokumente: „Noch keine Dokumente in diesem Modul. Nach dem nächsten Abgleich stehen sie hier nach Lehrwoche.“ | Leerzustand als Wegweiser |
| Dokumentkacheln: etwas mehr Innenabstand, Zusammenfassung in `UF.text2` | Lesbarkeit |
| Laden/Fehler wie bei Meine Module (Platzhalter in Seitenform, „Erneut versuchen“) | siehe oben |
| KI-Zusammenfassung: Systemanzeige statt „⏳“, Text mit Zeilenabstand 1,6 und höchstens 680 pt breit, Fehler in `UF.bad` | keine Emoji als Symbole; lesbare Zeilenlänge |

## Lernfortschritt & Wochentests

| Änderung | Grund |
|---|---|
| Laden: drei Platzhalterzeilen in Zeilenhöhe statt „Lade Wochentests…“ (VoiceOver: „Lade Wochentests“) | Laden in der fertigen Form, kein Springen |
| Fehler: Symbol, Grund, „Erneut laden“ (derselbe Abruf) | Weg aus dem Fehler |
| Hinweis „Marker prüfen“: Radius `UF.rSm`, etwas mehr Innenabstand | einheitliche Radien aus den Tokens |
| Testdetails: Laden mit Systemanzeige; Rangliste mit gleich breiten Ziffern | ruhige Zahlenspalten |
| „Vorlesung bis hier“: `Color.orange`/`Color.accentColor` → `UF.warn`/`UF.accent` | keine Farben außerhalb `UF.*`, richtig im dunklen Modus |

## Aus Stud.IP (Courseware, Wiki, Forum)

| Änderung | Grund |
|---|---|
| Kopf- und Gruppenzeilen ≥ 44 pt, Pfeile gedimmt, Einträge mit Rückmeldung beim Antippen | Tippflächen, Hierarchie |
| Leser: Grundschrift 14,5 mit Zeilenabstand 1,65, Text höchstens 640 pt breit; Fehler mit Symbol | lesbare Zeilenlänge (~75 Zeichen) |

## Community (CommunityViews.swift)

| Änderung | Grund |
|---|---|
| Fehler und Erfolg als `CommunityNotice` (Symbol im Ton, Text in Textfarbe, blasse Tonfläche) statt nackter roter/grüner Zeilen | sichtbarer Zustand, besser lesbar als farbiger Fließtext |
| Laden als `CommunityLoading` mit Satz („Lösungen werden geladen …“) statt einzelnem Kreisel; Leserseiten halten ihren Platz (A4-Fläche) bis das Bild da ist | Kontext beim Warten, kein Springen |
| Lösungen einer Community in einer Karte mit Haarlinien; je Zeile eine sichtbare Handlung („Ansehen“), Zurückziehen/Melden/Blockieren unter „Mehr“ (wie bei den Treffern im Dokument) | weniger Knöpfe je Zeile, einheitliches Muster; Aktionen unverändert |
| „Mehr“-Knöpfe 44 × 44 pt | Tippfläche |
| Communities-Liste und Lösungen nach Lehrwoche mit Haarlinien; Leerzustand mit Symbol; Wochenüberschrift als Überschrift für VoiceOver | Tabellen aus Linien, Navigation mit VoiceOver |
| Kommentare: Aktionen als Geisterknöpfe, Haarlinie zwischen Kommentaren, Text mit Zeilenabstand 1,55 | der Kommentar führt, nicht die Knöpfe |
| Community-Einstellungen: Unterabschnitte (Pseudonym, Lerngruppen, Sperrliste) eine Stufe unter dem Kartentitel mit Trennlinie statt gleich großer Titel mit Symbol | flache Hierarchie aufgelöst |

## Nicht geändert / offen

- Die Community-Bereiche brauchen einen Build mit iCloud-Container; im Simulator erscheint nur der Hinweis „In diesem
  Build nicht verfügbar“ (`Views/Services/CommunityPage.swift`, nicht in diesem Bereich). Lösungslisten, Leser und
  Community-Reiter sind darum nur im Code und über die Tests geprüft, nicht fotografiert.
- Der Reiterzustand im Moduldetail ist nicht per Startargument wählbar; fotografiert ist die Übersicht.
- Wochentests erscheinen lokal nur mit verbundenem ChatGPT-Abo; im Simulator ohne Abo nicht sichtbar.
- Text auf blassen Tonflächen (z. B. `UF.warn` auf `UF.warnSoft`) hat knappen Kontrast; die neuen Tokens
  `UF.warnText`/`UF.badText` usw. des Designsystem-Agents (Branch worktree-agent-aaa07d96190362dbc) sollten nach dem
  Zusammenführen hier eingesetzt werden.
- `UFTabs` und `UFProgress` (Designsystem) sind unverändert; die Fortschrittsspur ist im dunklen Modus sehr blass.
