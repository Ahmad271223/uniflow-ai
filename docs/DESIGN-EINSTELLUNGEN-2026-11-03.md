# Design: Einstellungen, Stud.IP, Ersteinrichtung (3.11.2026)

Überarbeitung nach den drei Gestaltungsleitfäden (frontend-design, taste-skill „App-Bildschirme“, ui-ux-pro-max).
Grundsatz: ruhig, klare Gliederung, Farbe nur für Zustände, keine neuen Farben außerhalb `UF.*`, keine
Funktionsänderung, Rechtstexte und Hinweise inhaltlich unverändert, `accessibilityIdentifier` und VoiceOver-Labels
bleiben. Das Designsystem (`apps/apple/UniFlow/Design/*`) ist unverändert; neue Bausteine liegen in
`Views/Settings/SettingsParts.swift`.

Fotos (iPad-Simulator A10CF108, Hochformat): vorher `~/Studora-Builds/design/vorher/einstellungen/`, nachher
`~/Studora-Builds/design/nachher/einstellungen/` (gleiche Dateinamen; nachher zusätzlich 05b dunkel, 20/21 kleine
Schrift, 22/23 sehr große Schrift).

## Einstellungen → Zugang & Darstellung

| Änderung | Begründung |
| --- | --- |
| Vier Abschnitte mit Kopf und einem Satz: „Konto & Tarif“, „Studium“, „Auf diesem iPad“, „Austausch“ (`SettingsSection`) | Vorher eine lange Folge gleichrangiger Karten; Gruppen mit Abschnittskopf sind die Gliederung, die Leitfäden für Einstellungen verlangen (eine Ebene pro Bereich, Zusammengehöriges zusammen). |
| Abschnittskopf 20,8 pt/700 zwischen Seitentitel (30,4) und Kartentitel (17,6) | drei klar unterscheidbare Ebenen; ein kleinerer Kopf las sich im ersten Versuch schwächer als die Karten darunter. |
| 32 pt zwischen den Abschnitten, 16 pt zwischen den Karten | Abstand trennt Gruppen, nicht Linien oder Farben. |
| Karte „Darstellung / Stift & Touch / Schreibhand“ als Zeilen mit Titel, Bedienelement und Linie dazwischen (`SettingsRow`, `SettingsDivider`) | vorher fünf gleich große Kartenköpfe untereinander in einer Karte; Zeilen wie in einer Einstellungsliste lesen sich schneller. Der Hinweis zur Schreibhand steht als Erklärung unter seiner Zeile (Text unverändert). |
| Semester als eigene Karte im Abschnitt „Studium“ | gehört inhaltlich zum Studium, nicht zur Darstellung. |
| Konto: „Name“/„E-Mail“ als Bezeichnung und Wert in zwei Spalten (`SettingsValue`), fehlende Werte gedimmt | statt „Name: …“ in Fettschrift; ruhiger, Werte lassen sich markieren. |
| „Konto löschen“ und „Daten dieser Hochschule löschen“ abgesetzt am Kartenende unter einer Linie (`SettingsDangerZone`) | gleiche Stelle für endgültige Aktionen in allen Karten; Hochschule hatte das schon (Befund 27.10.), Konto jetzt auch. |
| Navigation: 28,8 pt Abstand zum Inhalt (vorher 19,2), Spalte 232 pt | Navigation und Inhalt lesen sich als zwei Ebenen. |
| Server-Modus (Entwicklung): gleiche Abschnitte, Karte „Semester & Darstellung“ ebenfalls in Zeilen | gleiche Gestaltung in beiden Modi. |

## Einstellungen → Hinweise oben

„Eigener Studora-Server nicht erreichbar“ und „Nicht aktualisiert …“ als Hinweis in Warnfarbe (`SettingsNotice`:
`UF.warnSoft`, Rand in `UF.warn` 30 %, Symbol, Titel in Textfarbe) statt einer weißen Karte mit orangefarbener
Überschrift. Begründung: Zustand auf einen Blick, Fehler im Block statt als Überschrift; Text in Textfarbe bleibt
lesbar (Kontrast), auch dunkel.

## Einstellungen → Lernzeit & Verfügbarkeit

„Aktuell: 2 Fächer pro Tag · 4 h · Lernzeit … · freie Tage … · Fahrtzeit …“ als Liste aus Bezeichnung und Wert
(Fächer pro Tag, Lernzeit pro Tag, Lernfenster, Freie Tage, Fahrtzeit). Begründung: Meta-Zeilen mit Mittelpunkten
sind schwer zu überfliegen; Werte stehen untereinander auf einer Kante.

## Einstellungen → Module

Spaltenköpfe der Kurstabelle in Satzschreibung (12,8 pt/600) statt Versalien mit Sperrung. Begründung: Versalien
für Beschriftungen gelten in allen drei Leitfäden als Vorlagen-Merkmal und lesen sich schlechter.

## Einstellungen → Erweitert (KI über mein ChatGPT, Studora-Konto, Hintergrund)

| Änderung | Begründung |
| --- | --- |
| ChatGPT-Karte: Symbol „sparkles“ statt „bulb“ | „bulb“ gibt es nicht unter den Icons und fiel auf das Datei-Symbol zurück (sichtbarer Fehler im Vorher-Foto). |
| ChatGPT verbunden: „Verbunden als“ als Bezeichnung/Wert, Linien zwischen Schalter, Modell und Knöpfen; „Trennen“ abgesetzt am Kartenende | klare Zeilen; trennende Aktion nicht zwischen „Nutzung verwalten“ und „Anderes Konto verbinden“. |
| Studora-Konto: Felder im Stil der App (`UFTextField`) mit Beschriftung darüber statt Systemrahmen mit Platzhalter als einziger Beschriftung | Leitfaden „Formulare“: sichtbare Beschriftung über dem Feld; einheitlicher Rahmen, Fokusring in Akzentfarbe. AutoFill-Typen (`username`, `password`) bleiben. |
| Studora-Konto angemeldet: E-Mail als „Angemeldet als“, Geräte als Liste mit Linien und 44 pt Zeilenhöhe, dieses Gerät mit Haken; Löschen samt Passwortfeld abgesetzt am Ende | Passwortfeld steht jetzt direkt über dem Knopf, zu dem es gehört; Trefferflächen ≥ 44 pt. |
| Hintergrund-Abgleich: Linien zwischen den beiden Schaltern und dem letzten Lauf | drei Blöcke statt einer Textwand. |

## Stud.IP-Seite

Kursliste mit Linien zwischen den Kursen und mindestens 44 pt Zeilenhöhe (Trefferfläche); Datenschutzhinweis unter
einer Linie und 12,8 pt, damit Stand und Knöpfe oben das Wichtigste bleiben. Texte unverändert. (Kein Vorher/Nachher-
Foto: die Seite öffnet nur als Blatt per Tippen, ohne Startargument.)

## Ersteinrichtung

| Änderung | Begründung |
| --- | --- |
| Begrüßung: Symbole der drei Gründe als ruhige Linien-Icons ohne getöntes Kästchen, 16 pt Abstand, Zeile für VoiceOver zusammengefasst | „Icon in getöntem Quadrat“ ist ein Vorlagen-Merkmal; die Zeile trägt der Titel. |
| Begrüßung: Datenschutzsatz unten 12,8 statt 11,84 pt | Lesbarkeit; unter 12 pt ist für Fließtext zu klein. |
| Tarifwahl, Hochschulwahl, Anmeldeseiten, Erstabgleich | unverändert: bereits klar gegliedert (eine Aufgabe je Seite, Hauptknopf eindeutig, Zustände mit Marke und Symbol). |

## Geprüft

- Dunkler Modus: Fotos 02, 07, 05b, 09, 11, 13, 15, 21.
- Dynamic Type: 20 (extra-small) und 22/23 (accessibility-large); Texte brechen um, nichts wird gekürzt.
- App-Tests (Simulator A10CF108): BackgroundSyncAppTests, DemoAppTests, FirstStartAppTests, LocalModulesAppTests,
  StudIPSessionAppTests, TrialAppTests, PlanContractTests, UniversityLoginPolicyTests, AccessibilityAppTests,
  AccountStoreTests, StudoraAccountAppTests, ChatGPTLinkAppTests, NoServerStateTests, LocalDocumentsAppTests:
  130 Tests, 0 Fehler.

## Offen

- Die Mitte der Seite „Zugang & Darstellung“ (Karten „Darstellung“ und „Hintergrund“) ist im Simulator nur über
  das Seitenende (-UFScroll bottom) teilweise fotografiert; ein Startargument für eine Scrollposition fehlt.
- Karten anderer Bereiche auf derselben Seite (Stud.IP & QIS, Erinnerungen, Community, Demo-Inhalte) gehören anderen
  Agents und sind unverändert.
