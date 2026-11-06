# Bildschirmfotos für den App Store (iPad)

Stand 05.11.2026 (Rufname „Tobi“, Mensa als Bild 10). Erzeugt vom Test `apps/apple/UniFlowTests/StoreScreenshotTests.swift` aus den echten Ansichten der
App (ganze Hülle mit Seitenleiste und Kopfzeile) mit den Demo-Inhalten (`DemoContent`, erfundenes Modul „Demo:
Grundlagen der Informatik“) und den Zusätzen nur für die Store-Bilder (`DemoContent.installStoreExtras`: erfundener
Studienverlauf „Informatik B.Sc.“ mit Prüfungsanmeldung, vier Nachrichten, ein Lernpaket für heute; die App ruft das
nie auf, die Demo der Prüfer bleibt unverändert) und dem erfundenen Speiseplan (`MensaDemoHTTP`, unter XCTest im
lokalen Backend, kein Netz). Bilder unter `~/Studora-Builds/appstore-screenshots/` (nicht im
Repository), die iPhone-Bilder unter `~/Studora-Builds/appstore-screenshots-iphone/` (Abschnitt iPhone im Worktree
`feature/iphone`).

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
UDID=$(xcrun simctl clone <iPad-UDID> SN-shots-pad)        # eigener Simulator
TEST_RUNNER_UF_SCREENSHOT_DIR=$HOME/Studora-Builds/appstore-screenshots \
  xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath ~/Studora-Builds/dd-shots-pad -only-testing:UniFlowTests/StoreScreenshotTests
xcrun simctl delete "$UDID"
```

Ohne `UF_SCREENSHOT_DIR` prüft der Test nur, dass jede Ansicht mit den Demo-Inhalten erscheint. Je Ansicht entstehen
vier Dateien: `<nn>-<name>-{light|dark}-{portrait|landscape}.png`, der Store-Satz direkt im Ordner, Varianten und
Reserve unter `reserve/`. Kein Netz, keine Anfrage an eine Hochschule (`UniStubProtocol` zählt mit), die KI antwortet
aus einem Schein-Transport, Stud.IP (Antworten, Abgeben) aus einer Nachbildung im Speicher (`DemoStudIP`: Konto „Tobi
Muster“, Tutorium, Abgabeordner der Demo-Übung), die Community aus einer leeren Wolke im Speicher. Tarif Plus über
`setPlanForTesting`; die Tarifseite läuft in einer StoreKit-Sitzung aus `UniFlow.storekit` ohne das Pro-AI-Produkt. Die
Handschrift kommt aus dem Test (`handwriting()` auf dem Skript, `sheetHandwriting()` auf dem Übungsblatt) über den
`DocumentStore`, wie der Editor sie speichert. Blätter (Antworten, Abgeben) nimmt der Test getrennt auf: erst die Seite,
dann das Blatt darüber mit der Abdunklung (unter einem präsentierten Blatt zeichnet `drawHierarchy` die Seite schwarz).
Die Begrüßung und die Seitenleiste nennen den erfundenen Rufnamen „Tobi“ (Wunsch des Inhabers 05.11.2026, vorher „Mia“).
Die Bilder hängen vom Datum und der Uhrzeit ab (Lernpakete dieser Woche, „Guten Morgen“/„Hallo“, Karte
„Prüfungsanmeldung“ nur im Meldezeitraum WiSe 26/27 09.–22.11.2026 und in den 7 Tagen davor, Mensa nur an Werktagen –
am Wochenende zeigt die Seite „Geschlossen“ und die Übersicht keine Mensa-Karte). Stand der Bilder: Donnerstag,
05.11.2026, 16:28 Uhr, darum „Hallo Tobi – lass uns gemeinsam lernen.“ statt „Guten Morgen“.

## Store-Satz (Reihenfolge im Store)

Bildunterschriften höchstens zwei Zeilen, als Vorschlag für App Store Connect. Bild 2 und 4 zeigen die KI (KI-Hilfe,
Wochentest): nur verwenden, wenn StudiNow Pro AI mit eingereicht wird (`docs/release/APP-STORE.md`, Abschnitt
Bildschirmfotos); in der Fassung nur mit Plus statt 2 `reserve/12-editor-*.png` (Editor mit Handschrift) und statt 4
`reserve/11-bibliothek-*.png`.

| Nr. | Datei (Hochformat, hell) | Ansicht | Bildunterschrift |
| --- | --- | --- | --- |
| 1 | `01-uebersicht-light-portrait.png` | Übersicht: Begrüßung „Hallo Tobi – lass uns gemeinsam lernen.“, Karte „Prüfungsanmeldung“ (3 offen, 1 angemeldet), Karte „Heute in der Mensa“, Lernpaket heute | Dein Tag auf einen Blick – und welche Prüfungen du jetzt anmelden solltest. |
| 2 | `02-ki-dokument-light-portrait.png` | Skript mit Handschrift, KI-Hilfe offen: Umfang „Ganzes Dokument“, „Ganze Vorlesung erklären“ mit Abschnitten und Seitenangaben | Die ganze Vorlesung erklärt, Abschnitt für Abschnitt mit Seitenangabe – neben deinem Skript. |
| 3 | `03-karteikarten-light-portrait.png` | Karteikarten (zwei Stapel, 5 heute fällig, Lernstand) | Karteikarten je Modul im Leitner-System: richtig = seltener, falsch = morgen wieder. |
| 4 | `04-wochentest-light-portrait.png` | Wochentest-Ergebnis (75 %, Erklärung je Aufgabe, „Nochmal anschauen“) | Wochentest mit Auswertung: Punkte, Erklärung je Aufgabe und was du wiederholen solltest. |
| 5 | `05-studienverlauf-light-portrait.png` | Studienverlauf „Informatik B.Sc.“ (59 von 180 LP), Abschnitt Prüfungsanmeldung mit Zeiträumen und Vorschlägen | Studienverlauf mit Leistungspunkten und Prüfungsanmeldung – Zeiträume und passende Prüfungen. |
| 6 | `06-nachrichten-light-portrait.png` | Nachrichten: Nachricht des Tutoriums im Leser, darüber „Antworten“ mit Text | Stud.IP-Nachrichten lesen und direkt beantworten – Fristen darin werden erkannt. |
| 7 | `07-abgeben-light-portrait.png` | Übungsblatt mit Handschrift, darüber „In Stud.IP abgeben“ (Kurs, Abgabeordner, Dateiname, Notizen mitschicken) | Deine Lösung mit Notizen direkt in Stud.IP abgeben – in den richtigen Abgabeordner. |
| 8 | `08-community-light-portrait.png` | Community (Community des Demo-Moduls, Pseudonym, Lerngruppen) | Lösungen vergleichen – nur eigene Notizen, verschlüsselt, unter Pseudonym. |
| 9 | `09-lernkalender-light-portrait.png` | Lernkalender (Woche, Uni-Termine, Lernpakete) | Der Lernkalender verteilt Vorlesung, Übung und Wiederholung auf deine Woche. |
| 10 | `10-mensa-light-portrait.png` | Mensa: Speiseplan heute (Hauptmensa), Preise für Studierende, Kennzeichen vegan/vegetarisch, Nährwerte, Filter, Öffnungszeiten | Was gibt’s heute in der Mensa? Preise, Nährwerte, Allergene und Filter für vegan und vegetarisch. |

Bild 10 war bis 05.11.2026 der Stundenplan (jetzt `reserve/16-stundenplan-*.png`, das schwächste Motiv: eine fast leere
Woche); der Inhaber wollte die Mensa im Satz. Die KI-Motive 2 und 4 bleiben wie oben austauschbar.

Dunkle und Querformat-Varianten liegen daneben (`-dark-`, `-landscape`); für den Store reicht ein Satz, am besten hell
und Hochformat (quer ist das Skript in 2 auf Breite gezoomt und oben angeschnitten).

Reserve unter `reserve/` (nicht ohne Entscheidung hochladen):

| Datei | Inhalt | Vorbehalt |
| --- | --- | --- |
| `11-bibliothek-*.png` | Dokumente & Notizen, Bereich „Neue Dateien“ | Ersatz für 4 ohne KI |
| `11b-regal-*.png` | „Mein Regal“ | nennt die Hochschule des Containers und den Hinweis „öffne eine Datei mit KI-Hilfe“ |
| `12-editor-*.png` | Editor mit Handschrift, ohne KI | Ersatz für 2 ohne KI („Skripte und Übungsblätter mit dem Apple Pencil – Marker, Stift, Formen, alles bleibt auf deinem iPad.“) |
| `13-tarife-*.png` | Tarifseite (Free als Stand, Plus 1,99 €/Monat) | Plus-Karte nennt „Neue KI-Tests von StudiNow“ (in Vorbereitung) |
| `14-einstellungen-*.png` | Einstellungen → Zugang & Darstellung | Reiter „Entwicklung“ (nur Debug) und die Hochschule; nur intern |
| `15-ki-start-*.png` | KI-Start mit Beispielfrage und Antwort | nur mit Pro AI |
| `16-stundenplan-*.png` | Stundenplan mit Terminen (bis 05.11.2026 Bild 10) | Ersatz („Stundenplan mit Räumen und Terminen – direkt aus deiner Hochschule.“) |

Hinweise:

- Keine Demo-Leiste: die Leiste „Demo-Inhalte – erfunden, ohne Hochschule“ mit „Beenden“, die Prüfer im Demo-Betrieb
  sehen, blendet der Test aus (`\.ufDemoBarHidden`, nur im Test; `test01Uebersicht` prüft, dass sie fehlt).
- Die Seitenleiste zeigt unter dem Profil „Pro AI holen“ (Knopf der App für Plus-Kunden, wie in den bisherigen
  Bildern) und „Community“, weil der Test eine verbundene Community nachstellt.
- Prüfungsanmeldung (1, 5): Zeiträume aus der Terminseite des Prüfungsamts (Informatik B.Sc., gelesen am 05.11.2026),
  Vorschläge aus dem erfundenen Studienverlauf; „Im QIS anmelden“ öffnet nur die QIS-Seite.
- Antworten (6) und Abgeben (7): Blätter in der Größe der App (Formblatt); unten im Blatt stehen noch der Hinweis und
  „Senden“ bzw. „Jetzt abgeben“, außerhalb des sichtbaren Teils.
- Geändert für die Bilder (wirkt in der App): Umfang der KI-Hilfe mit Segmenten nach Inhalt (`TutorScopeSegments`,
  vorher „Ganzes Doku…“ im iPad-Hochformat), „1 Uni-Termin“ statt „1 Uni-Termine“ auf der Übersicht.

## Prüfung auf verbotene Inhalte

Jedes Bild wurde angesehen (Lauf 05.11.2026: alle 68 Dateien, Store-Satz und Reserve, hell/dunkel, hoch/quer): keine überlappenden Elemente,
keine Debug-Leiste, kein Platzhaltertext, Pixelgröße mit `sips -g pixelWidth -g pixelHeight` geprüft (alle 2064 × 2752
bzw. 2752 × 2064). Es erscheinen nur die Demo-Inhalte und die Zusätze der Store-Bilder: Modul „Demo: Grundlagen der
Informatik“, die drei Demo-PDFs, „Hörsaal A“, „Seminarraum 3“, erfundene Karteikarten, Testaufgaben und KI-Antworten,
Studiengang „Informatik B.Sc.“ mit allgemeinen Modulnamen, Absender als Rollen („Tutorium“, „Lehrende“,
„Studienberatung“), Empfänger „Tutorium Grundlagen der Informatik“, Rufname „Tobi“, Dateiname „Muster_Blatt1.pdf“; in der Mensa
(1, 10) erfundene Gerichte, Preise und Nährwerte aus `MensaDemoHTTP` – Name, Adresse, Öffnungszeiten und die
Quellenzeile („Speiseplan: Studentenwerk Hannover (Studi|Futter)“, „Angaben ohne Gewähr“) sind die echten Angaben der
Hauptmensa aus `packages/shared-contracts/mensa.json`.
Kein echter Personenname, kein Hochschul-Logo; der Name einer Hochschule steht nur in den Reserven `11b-regal` und
`14-einstellungen`. Die Noten im Studienverlauf (5) sind erfunden. Preise: 1,99 €/Monat (Plus) aus der
StoreKit-Testkonfiguration.

## iPhone (6,9")

Stand 05.11.2026, Worktree `feature/iphone`. Erzeugt vom Test `apps/apple/UniFlowTests/IPhoneStoreScreenshotTests.swift`
aus der kompakten Hülle (untere Leiste, Blätter von unten) mit denselben Demo-Inhalten und Zusätzen wie die iPad-Bilder
(`DemoContent.installStoreExtras`, Schein-Dienste und Zusammensetzen aus `StoreScreenshotTests`). Bilder unter
`~/Studora-Builds/appstore-screenshots-iphone/`, je Ansicht `<nn>-<name>-{light|dark}-portrait.png`.

| Gerät | Hochformat | Pflicht |
| --- | --- | --- |
| iPhone 6,9" (iPhone 17 Pro Max) | 1320 × 2868 px | ja (App Store Connect skaliert für kleinere iPhones) |

Gerendert mit Maßstab 3 aus einem Fenster von 440 × 956 Punkten im Simulator „iPhone 17 Pro Max“; der Test prüft die
Pixelgröße, zusätzlich mit `sips -g pixelWidth -g pixelHeight` geprüft (alle 1320 × 2868). Oben zeichnet der Test die
Statuszeile wie auf dem Gerät (9:41, Netz, WLAN, Akku), weil der Testaufbau keine eigene hat. Blätter (KI-Hilfe,
Antworten, Abgeben) ganz hoch bzw. in der Höhe, die die App wählt: halb hoch ist das Blatt aus Glas, das sich im Test
nicht zeichnen lässt.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/apple && xcodegen generate
UDID=$(xcrun simctl create SN-shots-phone com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-27-2)
TEST_RUNNER_UF_SCREENSHOT_DIR=$HOME/Studora-Builds/appstore-screenshots-iphone \
  xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath ~/Studora-Builds/dd-shots-phone -only-testing:UniFlowTests/IPhoneStoreScreenshotTests
xcrun simctl delete "$UDID"
```

Bild 2 und 4 zeigen die KI: nur mit Entscheidung B (sonst weglassen; es bleiben 6 Bilder).

| Nr. | Datei (hell) | Ansicht | Bildunterschrift |
| --- | --- | --- | --- |
| 1 | `01-start-light-portrait.png` | Start: „Guten Morgen, Mia“, Karte „Prüfungsanmeldung“, untere Leiste | Dein Tag auf einen Blick – und welche Prüfungen du jetzt anmelden solltest. |
| 2 | `02-ki-dokument-light-portrait.png` | KI-Hilfe als Blatt über dem Skript: „Ganzes Dokument“, erklärte Vorlesung mit Seitenangaben | Die ganze Vorlesung erklärt, Abschnitt für Abschnitt mit Seitenangabe. |
| 3 | `03-karteikarten-light-portrait.png` | Karteikarten (Stapel, 5 heute fällig) | Karteikarten je Modul: richtig = seltener, falsch = morgen wieder. |
| 4 | `04-wochentest-light-portrait.png` | Wochentest-Ergebnis (75 %, Erklärung je Aufgabe) | Wochentest mit Auswertung und Erklärung je Aufgabe. |
| 5 | `05-studienverlauf-light-portrait.png` | Studienverlauf „Informatik B.Sc.“ mit Prüfungsanmeldung | Studienverlauf mit Leistungspunkten und Prüfungsanmeldung. |
| 6 | `06-nachrichten-light-portrait.png` | Nachricht des Tutoriums, darunter „Antworten“ (Blatt halb hoch mit „Senden“) | Stud.IP-Nachrichten lesen und direkt beantworten. |
| 7 | `07-abgeben-light-portrait.png` | „In Stud.IP abgeben“ (Abgabeordner, Notizen mitschicken, 2 Seiten · 1,2 MB, „Jetzt abgeben“) | Deine Lösung mit Notizen direkt in Stud.IP abgeben. |
| 8 | `08-community-light-portrait.png` | Community (So funktioniert's, Community des Demo-Moduls) | Lösungen vergleichen – nur eigene Notizen, verschlüsselt, unter Pseudonym. |

Jedes Bild hell und dunkel angesehen: keine überlappenden Elemente, keine Demo-Leiste, kein Platzhaltertext; nur die
Demo-Inhalte (wie beim iPad). Für die Bilder geändert (wirkt in der App): Trennlinien der Prüfungsanmeldung kompakt in
voller Breite (`ExamRegistrationList`), „1 Uni-Termin“ statt „1 Uni-Termine“.
