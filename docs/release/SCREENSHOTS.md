# Bildschirmfotos für den App Store (iPad)

Stand 04.11.2026. Erzeugt vom Test `apps/apple/UniFlowTests/StoreScreenshotTests.swift` aus den echten Ansichten der
App (ganze Hülle mit Seitenleiste und Kopfzeile) mit den Demo-Inhalten (`DemoContent`, erfundenes Modul „Demo:
Grundlagen der Informatik“). Bilder unter `~/Studora-Builds/appstore-screenshots/` (nicht im Repository).

## Größen für App Store Connect

| Gerät | Hochformat | Querformat | Pflicht |
| --- | --- | --- | --- |
| iPad Pro 13" (M4) – „iPad 13"-Display“ | 2064 × 2752 px | 2752 × 2064 px | ja |
| iPad Pro 11" / iPad Air 11" – „iPad 11"-Display“ (optional) | 1668 × 2420 px | 2420 × 1668 px | nein (App Store Connect skaliert die 13"-Bilder) |

Alle Bilder hier sind 2064 × 2752 (hoch) bzw. 2752 × 2064 (quer), PNG ohne Transparenz, gerendert mit Maßstab 2 aus
einem Fenster von 1032 × 1376 Punkten (der Test prüft die Pixelgröße jedes Bildes; zusätzlich geprüft mit
`sips -g pixelWidth -g pixelHeight`). Hochladen: je Sprache (Deutsch) bis zu 10 Bilder je Gerätegröße, eine
Ausrichtung je Satz; üblich ist Hochformat.

## Erzeugen

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/apple && xcodegen generate
UDID=$(xcrun simctl clone <iPad-UDID> SN-shots)            # eigener Simulator
TEST_RUNNER_UF_SCREENSHOT_DIR=$HOME/Studora-Builds/appstore-screenshots \
  xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath ~/Studora-Builds/dd-shots -only-testing:UniFlowTests/StoreScreenshotTests
xcrun simctl delete "$UDID"
```

Ohne `UF_SCREENSHOT_DIR` prüft der Test nur, dass jede Ansicht mit den Demo-Inhalten erscheint. Je Ansicht entstehen
vier Dateien: `<nn>-<name>-{light|dark}-{portrait|landscape}.png`. Kein Netz, keine Anfrage an eine Hochschule
(`UniStubProtocol` zählt mit), die KI antwortet aus einem Schein-Transport, die Community aus einer leeren Wolke im
Speicher (so erscheint die Seite wie im Build mit iCloud-Container). Tarif Plus über `setPlanForTesting`, damit
Notizen und Karteikarten frei sind; die Tarifseite läuft in einer StoreKit-Sitzung aus `UniFlow.storekit` ohne das
Pro-AI-Produkt (Store-Stand zum Start: Free, Plus und der Hinweis „Pro AI folgt mit dem Dienst“). Die Handschrift im
Editor kommt aus dem Test (`handwriting()`: Marker, Unterstreichung, Kreis, Pfeil, Haken in Seitenpunkten) über den
`DocumentStore`, wie der Editor sie speichert. Die Bilder hängen vom Datum ab (Lernpakete dieser Woche, „Guten Tag!“).

## Grundsatz ohne KI (Reihenfolge im Store)

Bildunterschriften höchstens zwei Zeilen, kein Versprechen zur KI (Entscheidung 25.10.2026, `tests/test_release_texts.py`).

| Nr. | Datei (Hochformat, hell) | Ansicht | Bildunterschrift |
| --- | --- | --- | --- |
| 1 | `01-uebersicht-light-portrait.png` | Übersicht: Lernpaket heute, Uni-Termin, Abgabe, Module, Neuigkeiten | Dein Semester auf einen Blick: Lernpakete, Abgaben und Ankündigungen aus Stud.IP. |
| 2 | `03-editor-light-portrait.png` | Editor mit Handschrift auf dem Demo-Skript | Skripte und Übungsblätter mit dem Apple Pencil – Marker, Stift, Formen, alles bleibt auf deinem iPad. |
| 3 | `04-lernkalender-light-portrait.png` | Lernkalender (Woche) | Der Lernkalender verteilt Vorlesung, Übung und Wiederholung auf deine Woche. |
| 4 | `05-stundenplan-light-portrait.png` | Stundenplan mit Terminen | Stundenplan mit Räumen, Fristen und Feiertagen – direkt aus deiner Hochschule. |
| 5 | `02-bibliothek-light-portrait.png` | Dokumente & Notizen, Bereich „Neue Dateien“ (die drei Demo-Dokumente als Karten) | Alle Unterlagen nach Modul und Woche – Vorlesungen, Übungen, Altklausuren. |
| 6 | `06-karteikarten-light-portrait.png` | Karteikarten (Stapel, heute fällig) | Karteikarten je Modul im Leitner-System: richtig = seltener, falsch = morgen wieder. |
| 7 | `07-community-light-portrait.png` | Community (Community des Demo-Moduls, Pseudonym, Lerngruppen) | Lösungen vergleichen – nur eigene Notizen, verschlüsselt, unter Pseudonym. |
| 8 | `08-tarife-light-portrait.png` | Tarifseite „Tarif wechseln“ (Free als Stand, Plus 1,99 €/Monat) | Free zum Organisieren, Plus für Handschrift und Karteikarten. 7 Tage kostenlos testen. |

Dunkle und Querformat-Varianten liegen daneben (`-dark-`, `-landscape`); für den Store reicht ein Satz, am besten hell
und Hochformat.

Varianten und Reserve (nicht ohne Entscheidung hochladen):

| Datei | Inhalt | Vorbehalt |
| --- | --- | --- |
| `02b-regal-*.png` | Dokumente & Notizen als „Mein Regal“ (Semester, Modul, Woche, Art) | nennt die Hochschule des Containers („Leibniz Universität Hannover“; die Hochschulen haben die App nicht unterstützt) und den Hinweis „öffne eine Datei mit KI-Hilfe“ |
| `09-einstellungen-*.png` | Einstellungen → Zugang & Darstellung (Konto, Tarif, Hochschule, Rechtliches) | zeigt den Reiter „Entwicklung“ (nur Debug-Build) und die Hochschule; nur intern, nicht für den Store |

Hinweise zu den Bildern des Grundsatzes:

- Auf Übersicht (1) steht die Leiste „Demo-Inhalte aktiv … Entfernen“ – das ist der echte Demo-Betrieb, den auch die
  Prüfer sehen. Wer sie nicht im Store will, muss die Übersicht mit einem Hochschulkonto und erfundenen Kursen neu
  aufnehmen (nicht Teil dieses Tests).
- Lernkalender (3) zeigt das rote Band „2 Aufgaben müssen nachgeholt werden“, weil das Montags-Lernpaket der Demo
  bereits vorbei ist (Aufnahme an einem Mittwoch). An einem Montag erzeugt, fehlt das Band.
- Tarifseite (8): die Plus-Karte listet unter „in Vorbereitung“ auch „Neue KI-Tests von StudiNow“ – Text der App
  (Vertrag), keine Zusage im Store-Text. Bei Weg C ggf. die Tarifseite ans Ende stellen oder weglassen.
- Die Kopfzeile zeigt den Platzhalter-Avatar (kein Apple-Name freigegeben), die Seitenleiste „Community“, weil der
  Test eine verbundene Community nachstellt; ohne iCloud-Container im Build fehlt der Eintrag.

## KI-Satz (getrennt, nur nach Entscheidung B)

Unter `~/Studora-Builds/appstore-screenshots/ki/`. Erst verwenden, wenn der Inhaber Weg B wählt
(`docs/release/APP-STORE.md`, „Offene Entscheidung KI“); bei Weg A oder C bleiben sie weg. Die Antworten und der
Wochentest im Bild sind erfunden und kommen aus dem Test, nicht von ChatGPT; die Kopfzeile sagt „über dein ChatGPT“.

| Nr. | Datei | Ansicht | Bildunterschrift (nur mit Weg B) |
| --- | --- | --- | --- |
| K1 | `ki/11-ki-start-light-portrait.png` | KI-Start mit Beispielfrage und Antwort | Fragen, Karteikarten, Wochentest – mit deinem eigenen ChatGPT-Abo, freiwillig. |
| K2 | `ki/12-ki-hilfe-light-portrait.png` | KI-Hilfe neben dem Skript (Erklären), mit Handschrift | Die KI-Hilfe erklärt die offene Seite – über dein ChatGPT, nichts läuft über uns. |
| K3 | `ki/13-wochentest-light-portrait.png` | Wochentest mit Auswertung (75 %, Erklärung je Aufgabe) | Wochentest aus den Unterlagen der Woche, mit Auswertung und Erklärung je Aufgabe. |

Mit Weg B gehören K1–K3 hinter Nr. 2 (Editor) bzw. ans Ende; zusammen bleiben es höchstens 10 Bilder.

## Prüfung auf verbotene Inhalte

Jedes Bild des Grundsatzes und des KI-Satzes wurde angesehen (hell/hoch; dunkel und quer sind dieselben Ansichten).
Es erscheinen nur die Demo-Inhalte (Modul „Demo: Grundlagen der Informatik“, Dateien „Skript Kapitel 1 –
Zahlensysteme“, „Folien Woche 1 – Einführung“, „Übungsblatt 1 – Zahlensysteme“, „Hörsaal A“, „Seminarraum 3“,
erfundene Karteikarten, erfundene Testaufgaben und KI-Antworten), kein echter Personenname (der Demo-Dozent „Prof.
Demo“ ist in keinem Bild zu sehen), keine Note, kein Hochschul-Logo. Der Name einer Hochschule steht nur in den
Varianten `02b-regal` und `09-einstellungen` (siehe Vorbehalte). Avatar: Platzhalter-Symbol. Preise: 1,99 €/Monat
(Plus) aus der StoreKit-Testkonfiguration, wie in App Store Connect anzulegen.
