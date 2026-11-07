# Bildschirmfotos für den App Store (iPad)

## Endgültiger Satz mit Pro AI (Stand 07.11.2026, zum Hochladen)

Entscheidung des Inhabers 07.11.2026: **Pro AI wird mit Version 1.0 eingereicht**, die KI darf und soll gezeigt
werden. Die früheren KI-Bilder (`~/Studora-Builds/appstore-screenshots/`, 05.11.2026) sind unbrauchbar: dort steht
„über dein ChatGPT“ (das eigene ChatGPT ist abgeschaltet). Neu: zehn Bilder unter
`~/Studora-Builds/appstore-screenshots-final/` (nicht im Repository), Hochformat 2064 × 2752, PNG ohne Transparenz,
je Motiv **genau eine** Fassung hell oder dunkel (keine weiteren Varianten), ohne eingebrannte Beschriftung wie
bisher. Hochladen (iPad 13"-Display, Deutsch) in dieser Reihenfolge:

| Nr. | Datei | Ansicht | Bildunterschrift (Vorschlag) |
| --- | --- | --- | --- |
| 1 | `01-uebersicht-light.png` | Übersicht: „Hallo Tobi – lass uns gemeinsam lernen.“, Karte „Prüfungsanmeldung“ (3 offen, 1 angemeldet), Kennzahlen, Lernpaket heute, Abgaben; Seitenleiste mit Uni-Mail (2), Raumfinder, Profil „Tobi · Pro AI“ | Dein Tag auf einen Blick – und welche Prüfungen du jetzt anmelden solltest. |
| 2 | `02-ki-frage-dark.png` | Skript „Kapitel 1: Zahlensysteme“ mit Handschrift, daneben KI-Hilfe: Frage „Warum ist 13 im Dualsystem 1101?“, Antwort der KI (Stellenwerte 8 · 4 · 2 · 1, Probe, hexadezimal D), Anschlussfragen; Fußzeile „Seite 1 · StudiNow-KI · – 2 Credits (86 übrig)“ | Frag die KI zu deiner Seite – Antworten direkt neben dem Skript. |
| 3 | `03-ki-karteikarten-light.png` | Karteikarten: Stapel „KI-Karten aus Skript Kapitel 1“ (6 Karten, von der KI aus dem Skript), Wiederholung „Karte 1 von 6“, aufgedeckt: Zweierkomplement von −37 mit 8 Bit → 1101 1011, „Falsch“/„Richtig“ | Die KI macht Karteikarten aus deinem Skript – du lernst sie im Leitner-System. |
| 4 | `04-community-diskussion-dark.png` | Community „Demo: Grundlagen der Informatik“, Reiter „Diskussion“; darüber das Blatt „Frage“: Frage von „Zahlenfuchs“ (7 Likes, „Beantwortet“) mit drei Antworten von „Bitwise_Bea“, „Lerneule“ und „Zahlenfuchs“ | Fragen stellen, Antworten bekommen – in der Community deines Moduls, unter Pseudonym. |
| 5 | `05-uni-mail-light.png` | Uni-Mail (LUH): Posteingang mit acht erfundenen Mails, geöffnet die Mail von „Prof. Dr. Anna Beispiel“ mit Anhang „Probeklausur_GdI.pdf“ | Deine Uni-Mails in StudiNow: lesen, beantworten, Anhänge öffnen. |
| 6 | `06-stundenplan-termin-light.png` | Stundenplan, Termin-Detail der Vorlesung: Raum „Hörsaal A“ mit „Route zu Fuß in Google Maps“, Lehrende mit E-Mail (example.org) und Sprechstunde, „Allen Lehrenden schreiben“ | Termin antippen: Raum mit Route zu Fuß und alle Lehrenden mit E-Mail. |
| 7 | `07-skript-uebung-stift-dark.png` | Geteilte Ansicht: links das Skript, rechts das Übungsblatt, beide mit Apple-Pencil-Notizen (Marker, Unterstreichung, Kreis, Pfeil, Haken) | Skript und Übungsblatt nebeneinander – mit dem Apple Pencil direkt hineinschreiben. |
| 8 | `08-wochentest-ki-dark.png` | Wochentest-Ergebnis „Zahlensysteme“ (KI-generiert): 75 %, 60/80 Punkte, „Bestanden“, Zusammenfassung, „Nochmal anschauen: Hexadezimalsystem“, je Aufgabe Erklärung und „Rückmeldung zur Antwort“, „Frag die KI zu Aufgabe 2“ | Wochentest aus deinen Unterlagen – die KI wertet aus und sagt, was du wiederholen solltest. |
| 9 | `09-raumfinder-light.png` | Raumfinder: Suche „F102“, Detail mit „In Google Maps öffnen“, „Route“, „In Apple Karten“, Gebäude, Etage, Adresse | Räume finden und mit Google Maps hinlaufen – Gebäude, Etage und Adresse. |
| 10 | `10-mensa-light.png` | Mensa: Speiseplan (Hauptmensa), Preise für Studierende, vegan/vegetarisch, Nährwerte, Filter, Öffnungszeiten | Was gibt’s heute in der Mensa? Preise, Nährwerte und Filter für vegan und vegetarisch. |

**Tarif und KI in den Bildern:** Tobi hat **Pro AI** (Seitenleiste „Pro AI“, kein „Pro AI holen“). Die KI antwortet
als **StudiNow-KI** mit Credits: Stand wie vom Dienst für Pro AI (100 im Monat, vor der Frage 88 übrig, die Antwort
kostet 2, Fußzeile „– 2 Credits (86 übrig)“). Die Einwilligung gilt als gegeben, kein Einwilligungs-Blatt ist zu sehen.
Nirgends steht ChatGPT.

**Erzeugen** (Test `apps/apple/UniFlowTests/StoreScreenshotFinalTests.swift`, Technik wie Satz Build 11):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/apple && xcodegen generate
UDID=$(xcrun simctl clone 5483AC27-A4C2-4704-91A5-46D1A9E1DF47 SN-shots2)   # iPad Pro 13-inch (M5)
TEST_RUNNER_UF_SCREENSHOT_DIR=$HOME/Studora-Builds/appstore-screenshots-final \
  xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath ~/Studora-Builds/dd-shots2 -only-testing:UniFlowTests/StoreScreenshotFinalTests
xcrun simctl delete "$UDID"
```

Ohne `UF_SCREENSHOT_DIR` prüft der Test nur die Ansichten und dass in keinem Bild „ChatGPT“, „Pro AI holen“, das
Einwilligungs-Blatt („KI-Hilfe: Was wird gesendet?“) oder „wird geladen“ steht und die Seitenleiste „Pro AI“ nennt.
Erfundene Inhalte nur im Test bzw. nur im Debug-Build (Release unverändert):

- Alles aus Satz Build 11 (Demo-Inhalte, Store-Zusätze, `DemoSOGo`, Lehrende, Raumfinder, Mensa,
  `installV11Extras`); Tarif über `setPlanForTesting(.proAI)`.
- KI: Schein-Transport `StoreScreenshotTests.Intercept` vor dem lokalen Backend (`/api/ai/tutor`: erfundene Antwort mit
  `credits`/`charged`, `/api/tests/18`: erfundener Wochentest); Umgebung wie die App mit StudiNow-KI (`ufAIEnabled`,
  `ufStudiNowAI`, `ufAIAccess = .ready`) und ein `StudoraAccountLink` mit Credits aus einem Schein-Dienst
  (`InviteAppTests.StubTransport`). Die Frage wird ins Eingabefeld getippt und gesendet wie in der App.
- KI-Karteikarten: sechs erfundene Karten über `POST /api/flashcards` mit `stack_name` „KI-Karten aus Skript
  Kapitel 1“ (Art Vorlesung), danach „Üben“ und „Antwort zeigen“.
- Community-Diskussion: `DemoCommunity` im Test (Kurse wie CloudKit mit leerer Wolke, Demo-Kurs beigetreten, drei
  erfundene Fragen mit Antworten unter Pseudonym, schreibt nichts); das Blatt „Frage“ wird über der Seite aufgenommen.
- „Hallo Tobi“ unabhängig von der Uhrzeit: `UFGreeting.hourOverride` (nur `#if DEBUG`, die App setzt ihn nie);
  Mensa am Wochenende über `UFFmt.todayOverride` wie bisher.

Stand der Bilder: Samstag, 07.11.2026, gegen 9:30 Uhr (Anrede fest auf „Hallo“; „Samstag, 7. November“; Karte
„Prüfungsanmeldung“, weil 7 Tage vor dem Meldezeitraum 09.–22.11.2026; Termin-Detail zeigt Do. 05.11.).

**Geprüft (07.11.2026):** alle zehn Bilder einzeln angesehen, Größe mit `sips` (2064 × 2752): kein „ChatGPT“, kein
„Pro AI holen“, kein Einwilligungs-Blatt, kein Ladekreis, kein Platzhalter, kein Fehler, keine Demo-Leiste, Text lesbar.
Namen nur erfunden („Tobi Muster“, „Prof. Dr. Anna Beispiel“, „Dr. Jonas Muster“, „Lena Probe“, „Prof. Demo“, Pseudonyme
„Zahlenfuchs“, „Bitwise_Bea“, „Lerneule“, „Mo_Info“, „Kaffeebit“), Adressen nur unter example.org. Echte, öffentliche
Angaben wie bisher: Name der LUH, Raum F102 im Hauptgebäude (Welfengarten 1), Name, Adresse und Öffnungszeiten der
Hauptmensa. Fachlich nachgerechnet: 13 = 8 + 4 + 1 = 1101 = D; −37 mit 8 Bit = 1101 1011 (−128 + 64 + 16 + 8 + 2 + 1).

## Satz Build 11 – Fassung nur mit Plus (Stand 07.11.2026, überholt: Pro AI wird eingereicht)

Version 1.0 wird **nur mit Plus** eingereicht (Pro AI nicht): darum zeigt dieser Satz keine KI (keine KI-Hilfe, kein
KI-Dokument, kein Wochentest, kein Knopf „Pro AI holen“, kein KI-Knopf im Dokument), dafür die neuen Funktionen
Uni-Mail, Termin-Detail mit Lehrenden, Raumfinder, geteilte Ansicht und Bescheinigungen. Bilder unter
`~/Studora-Builds/appstore-screenshots-v11/` (nicht im Repository), je Motiv vier Dateien
`<nn>-<name>-{light|dark}-{portrait|landscape}.png`, 2064 × 2752 (hoch) bzw. 2752 × 2064 (quer), PNG ohne
Transparenz; alle 40 Dateien mit `sips -g pixelWidth -g pixelHeight` geprüft. Hochladen in App Store Connect
(iPad 13"-Display, Deutsch): **hell, Hochformat**, die zehn Dateien in dieser Reihenfolge. Wie im bisherigen Satz
reine App-Ansichten ohne eingebrannte Beschriftung; die Bildunterschriften sind Vorschläge (z. B. für eine spätere
Fassung mit Rahmen).

| Nr. | Datei (Hochformat, hell) | Ansicht | Bildunterschrift (Vorschlag) |
| --- | --- | --- | --- |
| 1 | `01-uebersicht-light-portrait.png` | Übersicht: „Guten Morgen, Tobi – lass uns gemeinsam lernen.“, Karte „Prüfungsanmeldung“ (3 offen, 1 angemeldet), Kennzahlen, Lernpaket heute; Seitenleiste mit Uni-Mail (2) und Raumfinder | Dein Tag auf einen Blick – und welche Prüfungen du jetzt anmelden solltest. |
| 2 | `02-uni-mail-light-portrait.png` | Uni-Mail: Posteingang mit acht erfundenen Mails, daneben die Mail der erfundenen Dozentin „Prof. Dr. Anna Beispiel“ (Klausurtermin, Anhang „Probeklausur_GdI.pdf“), Antworten/Weiterleiten | Deine Uni-Mails in StudiNow: lesen, beantworten, Anhänge öffnen. |
| 3 | `03-stundenplan-termin-light-portrait.png` | Stundenplan der Woche, Termin-Detail der Vorlesung: Raum „Hörsaal A“ mit „Route zu Fuß in Google Maps“, Lehrende „Prof. Dr. Anna Beispiel“ und „Dr. Jonas Muster“ mit E-Mail (example.org) und Sprechstunde, „Allen Lehrenden schreiben“ | Termin antippen: Raum mit Route zu Fuß und alle Lehrenden mit E-Mail. |
| 4 | `04-raumfinder-light-portrait.png` | Raumfinder: Suche „F102“, 1 Treffer, darüber das Detail mit „In Google Maps öffnen“, „Route“, „In Apple Karten“, Gebäude, Etage, Adresse | Räume finden und mit Google Maps hinlaufen – Gebäude, Etage und Adresse. |
| 5 | `05-geteilt-light-portrait.png` | Geteilte Ansicht (Plus): links das Skript, rechts das Übungsblatt, beide mit Apple-Pencil-Notizen (Marker, Unterstreichung, Kreis, Pfeil, Haken) | Skript und Übungsblatt nebeneinander – mit dem Apple Pencil direkt hineinschreiben. |
| 6 | `06-karteikarten-light-portrait.png` | Karteikarten (zwei Stapel, 5 heute fällig, Lernstand) | Karteikarten je Modul im Leitner-System: richtig = seltener, falsch = morgen wieder. |
| 7 | `07-studienverlauf-light-portrait.png` | Studienverlauf „Informatik B.Sc.“ (59 von 180 LP), Prüfungsanmeldung mit Zeiträumen und Vorschlägen | Studienverlauf mit Leistungspunkten und Prüfungsanmeldung – Zeiträume und passende Prüfungen. |
| 8 | `08-bescheinigungen-light-portrait.png` | Bescheinigungen aus QIS: „Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG“ (WiSe 2026/27, gespeicherte Kopie mit Stand, „Öffnen“), Enrolment Certificate, Notenspiegel deutsch/englisch, „Nicht im Portal gefunden“ | Immatrikulationsbescheinigung & Co. mit einem Tipp – gespeichert mit Datum auf deinem iPad. |
| 9 | `09-mensa-light-portrait.png` | Mensa: Speiseplan heute (Hauptmensa), Preise für Studierende, vegan/vegetarisch, Nährwerte, Filter, Öffnungszeiten | Was gibt’s heute in der Mensa? Preise, Nährwerte, Allergene und Filter für vegan und vegetarisch. |
| 10 | `10-community-light-portrait.png` | Community (Community des Demo-Moduls, Pseudonym, Lerngruppen) | Lösungen vergleichen – nur eigene Notizen, verschlüsselt, unter Pseudonym. |

Uni-Mail (2), Lehrende (3), Raumfinder (4) und Bescheinigungen aus QIS (8) zeigen den Stand der LUH (Seitentitel
„Uni-Mail (LUH)“ mit dem Namen der Leibniz Universität Hannover, Raum F102 im Hauptgebäude aus dem Standortfinder);
das deckt sich mit der Beschreibung („Angebunden heute: …“). Querformat: dieselben Motive (`-landscape`), dunkel:
`-dark-`; für den Store reicht der helle Hochformat-Satz.

**Erzeugen** (Test `apps/apple/UniFlowTests/StoreScreenshotV11Tests.swift`, gleiche Technik wie unten beim bisherigen
Satz: echte Ansichten der ganzen App-Hülle, Fenster 1032 × 1376 Punkte bei Maßstab 2):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/apple && xcodegen generate
UDID=$(xcrun simctl clone 5483AC27-A4C2-4704-91A5-46D1A9E1DF47 SN-shots)   # iPad Pro 13-inch (M5)
TEST_RUNNER_UF_SCREENSHOT_DIR=$HOME/Studora-Builds/appstore-screenshots-v11 \
  xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath ~/Studora-Builds/dd-shots -only-testing:UniFlowTests/StoreScreenshotV11Tests
xcrun simctl delete "$UDID"
```

Ohne `UF_SCREENSHOT_DIR` prüft der Test nur, dass jede Ansicht mit den erfundenen Inhalten erscheint und dass in
keinem Bild „KI-Hilfe“, „Pro AI“, „Wochentest“ oder „KI-Dokument“ steht. Erfundene Inhalte nur im Test bzw. nur im
Debug-Build (Release unverändert):

- Demo-Inhalte und Store-Zusätze wie beim bisherigen Satz (`DemoContent`, `installStoreExtras`, Rufname „Tobi“).
- Uni-Mail: Nachbildung von SOGo im Speicher (`DemoSOGo` im Test: Posteingang mit acht erfundenen Mails, Adressen unter
  example.org, Konto `tobi.muster@stud.example.org`); `UniMailConnection.readsDemoForScreenshots` (nur `#if DEBUG`)
  erlaubt das Lesen trotz Demo-Inhalten. Lesen markiert die Mail als gelesen wie SOGo; gesendet wird nichts.
- Lehrende: zwei erfundene Dozent/innen und eine Tutorin am Demo-Kurs (Tabelle `studip_lecturers` wie nach dem
  Stud.IP-Abgleich).
- Bescheinigungen: gespeicherte Liste des QIS (`settings.certificates`, erfunden) mit einer erfundenen PDF als Kopie;
  der QIS gilt als verbunden, gelesen wird nichts (Liste frisch).
- Raumfinder und Mensa: Testdaten des lokalen Backends (`RoomFinderDemoHTTP`, `MensaDemoHTTP`). Am Wochenende hat die
  Mensa keinen Plan: der Test setzt dann `UFFmt.todayOverride` (nur `#if DEBUG`) auf den nächsten Montag, die Seite
  zeigt „Heute“ mit dem Plan dieses Tages.
- Geteilte Ansicht: über „Weitermachen wie zuvor“ (`ResumeState` mit zweitem Dokument), je Ausrichtung ein eigenes
  Fenster (quer stünde sonst die Mitte der Seiten oben).
- Ohne „Pro AI holen“ in der Seitenleiste und ohne den Knopf „KI-Hilfe“ im Dokument: Umgebungswert
  `\.ufProAIOfferHidden` (nur Tests, die App setzt ihn nie).

Stand der Bilder: Samstag, 07.11.2026, 01:00 Uhr (darum „Guten Morgen“, „Samstag, 7. November“, keine Mensa-Karte auf
der Übersicht; Karte „Prüfungsanmeldung“ nur im Meldezeitraum 09.–22.11.2026 und 7 Tage davor).

**Geprüft (07.11.2026):** alle zehn Motive hell hoch angesehen, dazu quer und dunkel stichprobenartig (Uni-Mail,
Termin-Detail, Raumfinder, geteilte Ansicht, Bescheinigungen, Mensa, Übersicht): kein Platzhaltertext, kein
„wird geladen“, kein Fehler, keine Demo-Leiste, keine KI. Namen nur erfunden („Tobi Muster“, „Prof. Dr. Anna
Beispiel“, „Dr. Jonas Muster“, „Lena Probe“, „Prof. Demo“, Rollen wie „Prüfungsamt“), Adressen nur unter example.org.
Echte, öffentliche Angaben: Name der LUH, Raum F102 im Hauptgebäude (Welfengarten 1) aus dem Standortfinder, Name,
Adresse und Öffnungszeiten der Hauptmensa.

**Hinweis für die App (nicht Teil der Bilder):** In der App sieht ein Plus-Kunde heute weiterhin „Pro AI holen“ in der
Seitenleiste und den Knopf „KI-Hilfe“ im Dokument, auch wenn Pro AI nicht im Store ist. Für eine Fassung nur mit Plus
sollte das vor dem Einreichen entschieden werden.

## Bisheriger Satz (Stand 05.11.2026, mit KI-Motiven – unbrauchbar: „über dein ChatGPT“)

Stand 05.11.2026 (Rufname „Tobi“, Mensa als Bild 10). Erzeugt vom Test `apps/apple/UniFlowTests/StoreScreenshotTests.swift` aus den echten Ansichten der
App (ganze Hülle mit Seitenleiste und Kopfzeile) mit den Demo-Inhalten (`DemoContent`, erfundenes Modul „Demo:
Grundlagen der Informatik“) und den Zusätzen nur für die Store-Bilder (`DemoContent.installStoreExtras`: erfundener
Studienverlauf „Informatik B.Sc.“ mit Prüfungsanmeldung, vier Nachrichten, ein Lernpaket für heute; die App ruft das
nie auf, die Demo der Prüfer bleibt unverändert) und dem erfundenen Speiseplan (`MensaDemoHTTP`, unter XCTest im
lokalen Backend, kein Netz). Bilder unter `~/Studora-Builds/appstore-screenshots/` (nicht im
Repository), die iPhone-Bilder unter `~/Studora-Builds/appstore-screenshots-iphone/` (Abschnitt iPhone im Worktree
`feature/iphone`).

### Größen für App Store Connect

| Gerät | Hochformat | Querformat | Pflicht |
| --- | --- | --- | --- |
| iPad Pro 13" (M4) – „iPad 13"-Display“ | 2064 × 2752 px | 2752 × 2064 px | ja |
| iPad Pro 11" / iPad Air 11" – „iPad 11"-Display“ (optional) | 1668 × 2420 px | 2420 × 1668 px | nein (App Store Connect skaliert die 13"-Bilder) |

Alle Bilder hier sind 2064 × 2752 (hoch) bzw. 2752 × 2064 (quer), PNG ohne Transparenz, gerendert mit Maßstab 2 aus
einem Fenster von 1032 × 1376 Punkten (der Test prüft die Pixelgröße jedes Bildes; zusätzlich geprüft mit
`sips -g pixelWidth -g pixelHeight`). Hochladen: je Sprache (Deutsch) bis zu 10 Bilder je Gerätegröße, eine
Ausrichtung je Satz; üblich ist Hochformat.

### Erzeugen

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

### Store-Satz (Reihenfolge im Store)

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

### Prüfung auf verbotene Inhalte

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
