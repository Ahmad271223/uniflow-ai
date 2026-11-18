# App Store Connect – Texte und Angaben (iPhone und iPad, Mac „Designed for iPad“)

**Stand 15.11.2026 (iPhone und iPad, nur Jahresabos; 14.11.2026, 13.11.2026, 09.11.2026, 07.11.2026, 26.10.2026), Sprache de-DE, für StudiNow 1.0.4 und den Hotfix 1.0.5 (Build 44 ist seit 16.11.2026 23:42 als Version 1.0.5 in der Prüfung bei Apple, dieselben Texte und Bilder, nur „Neu“ anders; Build 42 ist seit 16.11.2026 10:49 als Version 1.0.4 veröffentlicht, nach der Prüfung bei Apple von Hand freigegeben; eingereicht am 15.11.2026 10:13, damals WAITING_FOR_REVIEW; Build 41 war am 14.11.2026 von 19:56 bis 21:54 eingereicht und wurde zurückgezogen; Build 35 ist seit 13.11.2026 als Version 1.0.3 veröffentlicht (live seit 23:53); 1.0.2 mit Build 31 veröffentlicht am 11.11.2026; 1.0.1 mit Build 30 seit 10.11.2026; Build 25 war als Version 1.0 freigegeben, wurde nie veröffentlicht und am 10.11. zurückgezogen; Build 27 und 28 nur auf dem Gerät des Inhabers).** Die Felder stehen in
`text`-Blöcken mit Feldnamen und sind **fertig zum Einfügen** (keine Platzhalter mehr, seit 06.11.2026 ohne die
Schalter aus `angaben.json`). `tests/test_release_texts.py` prüft Längen, Pflichtsätze und dass die Fassung ohne Pro AI
keine KI bewirbt. Zeichen inklusive Leerzeichen, gezählt wie App Store Connect (Unicode-Zeichen).

**1.0.6 (Build 45), vorbereitet am 18.11.2026, NICHT hochgeladen:** Die Blöcke `description-proai`, `whats-new-proai`,
`keywords`, `promo` und `review-notes-proai` unten sind die Fassung für 1.0.6 (`tools/store_einreichen.py texte 1.0.6`
liest genau diese Blöcke); im Store steht bis dahin der Text von 1.0.4 (`EINREICHUNG-1-0-4.md`). Neu gegenüber 1.0.4
(Entscheidungen des Inhabers 17./18.11.2026): Lernkalender aus (`LearnCalendar.enabled = false`, der Stundenplan mit
Hinweisen ist der Kalender), Erinnerungen an Abgaben, Tests und Klausuren ab Pro AI, KI-Credits zum Nachkaufen
(`de.uniflow.credits.klein`, `de.uniflow.credits.gross`; Plus nur KI-Chat), Klausurtermine aus Folien mit Texterkennung
auf dem Gerät, Abgleich von selbst 8–18 Uhr, Mitteilungen, Editor (flache Leiste, Füller, Textmarker), Video und
Lernseiten auch am iPhone, **„YouTube öffnen“ (Spalte mit der YouTube-Seite) ist in 1.0.6 AN** (`YouTubeBrowse.shipped`,
Entscheidung des Inhabers 18.11.2026 „Ja, wieder einschalten“; Folgen bei Apple: Abschnitt „1.0.6: Angaben bei Apple,
die sich ändern müssen“). Der eigene OpenAI-Schlüssel („Eigenes ChatGPT“) ist seit 11.11.2026 aus
(`OpenAIKeyLink.isOffered = false`); Beschreibung und Prüfhinweis von 1.0.4 nannten ihn noch – in 1.0.6 nicht mehr.
Untertitel neu „Skripte, Handschrift, Termine“ statt „… Lernplan“ (der Lernplan ist aus); den Untertitel setzt
`store_einreichen.py` nicht, er wird in App Store Connect von Hand eingetragen (App-Informationen bzw. Version).
Bildschirmfotos: neue Sätze `~/Studora-Builds/appstore-screenshots-1-0-6-ipad/` und `…-1-0-6-iphone/` (Abschnitt
Bildschirmfotos).

**Versionsnummern seit 10.11.2026:** Der erste Stand im Store heißt **1.0.1** (Build 30, nur LUH). Wo in älteren Texten
„1.0“ steht, ist dieser erste Stand gemeint; wo „1.0.1“ für HsH, Hildesheim, iPhone oder die Gerätegrenze steht, ist die
**nächste** Version gemeint (dann 1.0.2 oder höher).

**1.0 nur LUH, 1.0.1 mit HsH und Hildesheim (Entscheidung des Inhabers 07.11.2026, 14:10):** Version 1.0 (Build 25)
wird nur mit der Leibniz Universität Hannover (Stud.IP, QIS) eingereicht. Hochschule Hannover (Moodle, HISinOne) und
Universität Hildesheim (Learnweb, LSF, PLuS) bleiben im Code, sind im Store-Build aber ausgeblendet (Build-Einstellung
`UF_SHIPPED_UNIVERSITIES` = `luh` in `apps/apple/project.yml`, Info.plist `UFShippedUniversities`, Kern
`UFReleaseUniversities`) und kommen 1–2 Tage später mit Update 1.0.1 – dann die Texte unten wieder um beide Hochschulen
ergänzen (Beschreibung, Schlüsselwörter „Moodle“, „Hildesheim“, Prüfhinweise „Connected today“, Website).

**1.0.4 mit Universität Hildesheim (Entscheidung des Inhabers 14.11.2026):** Der Store-Build bietet ab Build 40 die Leibniz Universität Hannover und die Universität Hildesheim an (`UF_SHIPPED_UNIVERSITIES` = `luh hildesheim` im Release, `apps/apple/project.yml`); die Hochschule Hannover bleibt ausgeblendet. Beschreibung, Schlüsselwörter, „Neu in dieser Version“ und Prüfhinweise nennen Hildesheim (Learnweb, LSF). Hinweis: Hildesheim ist seit 14.11.2026 mit einem echten Testkonto geprüft (davor nur mit nachgebauten Seiten).

**1.0.4 wird mit Pro AI eingereicht (Entscheidung des Inhabers 07.11.2026, Dienst `app.studinow.app` läuft):** in App Store
Connect gehören `description-proai`, `whats-new-proai` und `review-notes-proai` hinein, dazu die zwei Jahresabos (Plus und Pro AI; die
Monatsabos sind seit 09.11.2026 aus dem Verkauf genommen, `ABO-NUR-JAHR-2026-11-09.md`). Die Fassungen „nur Plus“ bleiben
nur als Rückfall stehen und sind **überholt – nicht verwenden**.

**Stand 07.11.2026 abends, neu in den Texten:** (1) Probe 7 Tage im Umfang von Pro AI, höchstens einmal je iPad (auch nach
Neuinstallation oder mit anderer Apple-ID); danach Bildschirm „Deine Probe ist vorbei“ (Free, Plus, Pro AI, seit
09.11.2026 nur Jahresabos), der sich erst mit einer Wahl schließt – „Bei Free bleiben“ ist eine gültige Wahl ohne Kauf
(`TrialBanner.swift`, `UFTrialDecision`; im Prüfhinweis für die Richtlinien 3.1.2/5.1.1 erklärt). (2) Erster Abgleich:
erst aktuelles Semester samt Stundenplan, dann die Frage „Auch frühere Semester laden?“ („Nur aktuelles Semester“ /
„Frühere Semester auch laden“, im Hintergrund, nur WLAN, `OlderSemestersViews.swift`); die Demo hat keine früheren
Semester (`DemoContent.install`, Semester leer), darum steht die Frage kurz im Prüfhinweis. (3) Eigener API-Schlüssel in
jedem Tarif für KI-Hilfe und KI-Lernplan (Karteikarten aus Unterlagen ab Plus, Wochentests ab Pro AI,
`OpenAIKeyCard.introText`); die Beschreibung nennt ihn ohne fremde Marke, der Prüfhinweis mit OpenAI. Der KI-Lernplan
ist in der Demo ohne geöffnete Dateien leer und wird darum im Prüfhinweis nicht als Schritt versprochen.

**Neu in 1.0.4 (13.11.2026): iPhone.** Die App ist universal (`TARGETED_DEVICE_FAMILY` 1,2). Mit der ersten
veröffentlichten Version mit iPhone verlangt App Store Connect **Bildschirmfotos 6,9"** (1320 × 2868); sie liegen unter
`~/Studora-Builds/appstore-screenshots-iphone-2026-11-14/` (Satz vom 14.11.2026 mit den eigenen Kontodaten des Inhabers,
keine Daten Dritter; Abschnitt Bildschirmfotos). Am iPhone gibt es **keinen
Editor**: Dokumente öffnen in einer Leseansicht mit den Notizen vom iPad; das steht so in den Prüfhinweisen. Apple lässt
das iPhone später nicht mehr entfernen.

**Mac (Hinweis für den Inhaber):** Die iPad-App läuft auf Macs mit Apple-Chip als „Designed for iPad“; es gibt **keine
eigene macOS-Version**. In App Store Connect die Plattform **macOS nicht einreichen** (den alten macOS-1.0-Entwurf liegen
lassen) und unter **Preise und Verfügbarkeit → „iPhone- und iPad-Apps auf Apple-Silicon-Macs“ = verfügbar** setzen. In
Beschreibung und Werbetext steht dazu nichts. **Build 25 stürzt auf dem Mac ab** (Einstellungen und Übersicht,
`UFGridLayout` bei unendlicher Breite; behoben erst in Build 27, `afc919cc`, Audit P86-F3): solange Build 25 der
Prüf- bzw. Verkaufsstand ist, „iPhone- und iPad-Apps auf Apple-Silicon-Macs“ = **nicht verfügbar**; erst mit Build 27
nach einem Test auf einem Mac mit Apple-Chip einschalten.

Frühere Übersicht der zwei Fassungen (Pro AI erst nach Sandbox-Kauf und KI-Frage über TestFlight,
`docs/UEBERGABE-2026-11-06.md` Abschnitt 3 – durch die Entscheidung vom 07.11.2026 erledigt):

| Feld | nur Plus (Pro AI nicht eingereicht) | Plus und Pro AI |
|---|---|---|
| Name, Untertitel, Werbetext, Schlüsselwörter, Neue Funktionen | gleich | gleich |
| Beschreibung | `description` | `description-proai` |
| Hinweise für die App-Prüfung | `review-notes` | `review-notes-proai` |
| Bildschirmfotos | Satz Build 11 ohne KI (`~/Studora-Builds/appstore-screenshots-v11/`, `docs/release/SCREENSHOTS.md`) | **iPad: Satz vom 13.11.2026 mit Pro AI** (`~/Studora-Builds/appstore-screenshots-final-2026-11-13/`); **iPhone: Satz vom 14.11.2026** (`appstore-screenshots-iphone-2026-11-14/`, eigene Kontodaten des Inhabers, keine Daten Dritter); Abschnitt Bildschirmfotos |

Für 1.0.4 gilt die rechte Spalte (Plus und Pro AI).

**Vor dem Einreichen prüfen – Aussagen, die vom Stand des Builds und echten Konten abhängen:**

| Aussage im Text | Stand 06.11.2026 (Build 16) | Gilt nur, wenn – sonst im Text streichen |
|---|---|---|
| Universität Hildesheim (Learnweb, LSF, PLuS) | gebaut; Uni-Mail Hildesheim live bestätigt, Rest mit nachgebauten Seiten geprüft (`docs/HILDESHEIM-STAND-2026-11-05.md`). **Nicht in 1.0** (Entscheidung 07.11.2026): im Store-Build ausgeblendet, in den Texten gestrichen | erst mit 1.0.1: mit einem echten Hildesheim-Konto am Gerät durchgespielt, dann „Universität Hildesheim“, „Learnweb“, „LSF“ und „Hildesheim“ (Schlüsselwörter) wieder aufnehmen |
| Hochschule Hannover (Moodle, HISinOne, QIS) | gebaut, mit nachgebauten Seiten geprüft (`docs/HSH-2026-11-05.md`). **Nicht in 1.0** (Entscheidung 07.11.2026): im Store-Build ausgeblendet, in den Texten gestrichen | erst mit 1.0.1: Testliste in `docs/HSH-2026-11-05.md` mit einem echten Konto durchgespielt, dann „Hochschule Hannover“, „Moodle“, „HISinOne“ wieder aufnehmen |
| Uni-Mail und Uni-Kalender (LUH; Uni Hildesheim erst mit 1.0.1) | gebaut, Lesen live bestätigt (`docs/UNI-MAIL-2026-11-05.md`) | Senden und Antworten mit einem echten Konto geklappt |
| Bescheinigungen (LUH QIS, HsH und Hildesheim über HISinOne/PLuS) | LUH gebaut; HsH/Hildesheim nie mit echtem Konto ausgelöst (`docs/BESCHEINIGUNGEN-2026-11-06.md`) | Text nennt keine Hochschule; mindestens LUH am Gerät geprüft |
| Lehrende mit E-Mail und Sprechstunde, Raumfinder mit Route | nur LUH, Stud.IP live bestätigt (`docs/LEHRENDE-KONTAKTE-2026-11-06.md`, `docs/RAUMFINDER-2026-11-05.md`) | Google-Maps-Route am Gerät geöffnet |
| Automatisch anmelden (Passwort nur im Schlüsselbund dieses iPads) | gebaut (`docs/AUTOMATISCH-ANMELDEN-2026-11-06.md`); Uni-Mail-Formular und HsH-IdP sind geraten | Absatz bleibt in jedem Fall (er beschreibt, was die App mit dem Passwort tut) |
| Community deines Kurses (Plus) | gebaut (CloudKit `iCloud.de.uniflow.ai`, mit StudiNow-Konto über den Dienst) | Schema in Production übernommen (`docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md`), sonst geht sie im App Store nicht |
| Mensa | gebaut (`docs/MENSA-2026-11-05.md`), frei in jedem Tarif | – („ohne Gewähr“ steht in der App unter jedem Plan) |
| StudiNow-KI mit Pro AI (nur `description-proai`) | gebaut (`StudoraAccountLink`, `/api/ai/relay`, `ChatGPTLink.isEnabled = false`); Pro AI wird mit 1.0 verkauft (07.11.2026) | Dienst `app.studinow.app` erreichbar |
| Eigener API-Schlüssel in jedem Tarif (nur `description-proai`, ohne Marke) | gebaut (`OpenAIKeyCard`, `OpenAIKeySession`; KI-Hilfe und KI-Lernplan jeder Tarif, Karteikarten ab Plus, Wochentests ab Pro AI) | Karte in Einstellungen → Erweitert im Release-Build sichtbar |
| Probe einmal je iPad, danach „Deine Probe ist vorbei“ mit „Bei Free bleiben“ | gebaut (`LocalTrial.swift`, `TrialBanner.swift`) | – |
| „ohne Tracking“ | stimmt | solange kein Analyse-SDK eingebaut wird |

Nicht in den Texten, weil nicht oder noch nicht nutzbar: Zeitmesser (`StudyTimer.isEnabled = false`), Anmeldung bei
ChatGPT (`ChatGPTLink.isEnabled = false`, seit 07.11.2026 ohne Karte „bald verfügbar“ in den Einstellungen; der eigene
OpenAI-Schlüssel ist nutzbar und steht nur im Prüfhinweis, nicht im Werbetext – keine fremde Marke), Abgabefristen aus
Nachrichten (am Gerät mit echten Daten noch nicht bestätigt), Skriptsuche zur Aufgabe.

## Name, Untertitel, Werbetext

Name 28 Zeichen (max. 30), Untertitel 29 (max. 30), Werbetext 161 (max. 170). Stand 1.0.6: Untertitel ohne „Lernplan“, Werbetext ohne „Lernkalender“ (beide ausgeblendet).

```text name
StudiNow – Studium & Notizen
```

```text subtitle
Skripte, Handschrift, Termine
```

```text promo
Skripte, Termine, Uni-Mail und Noten deiner Hochschule auf iPhone und iPad – mit Apple Pencil, Stundenplan, Karteikarten und Speiseplan der Mensa. Ohne Tracking.
```

## Beschreibung (max. 4000 Zeichen)

### Fassung nur Plus – ÜBERHOLT, nicht verwenden (1.0.4 wird mit Pro AI eingereicht) – 3796 Zeichen

```text description
StudiNow bringt dein Studium an einen Ort: Unterlagen, Termine, Nachrichten, Uni-Mail und Noten deiner Hochschule, dazu Stundenplan, Lernkalender, Karteikarten und Handschrift mit dem Apple Pencil – auf iPhone und iPad.

FÜR STUDIERENDE IN GANZ DEUTSCHLAND
Angebunden heute: Leibniz Universität Hannover (Stud.IP, QIS). Weitere Hochschulen folgen. Du meldest dich auf der Anmeldeseite deiner Hochschule an; StudiNow holt neue Skripte, Übungsblätter und Folien, ordnet sie nach Modulen und Lehrwochen – das aktuelle Semester zuerst – und übernimmt deine Termine. In die Hochschulsysteme schreibt die App nur, wenn du es ausdrücklich auslöst.

DEINE UNI AN EINEM ORT
• Nachrichten aus Stud.IP beantworten, Übungen dort abgeben – erst nach deiner Bestätigung
• Uni-Mail und Uni-Kalender: lesen, antworten, weiterleiten, schreiben
• Notenspiegel und Bescheinigungen wie Immatrikulations- oder BAföG-Bescheinigung als PDF
• Lehrende mit E-Mail und Sprechstunde, Raumfinder mit Route zu Fuß in Google Maps oder Apple Karten
• Termin antippen: Raum mit Route, alle Lehrenden, E-Mail an einzelne oder alle
• Studienverlauf mit Modulkatalogen von über 300 Studiengängen, Meldezeiträume der Prüfungsanmeldung mit Erinnerung
• Speiseplan deiner Mensa mit Preisen, Nährwerten, Allergenen und Filtern (Studentenwerk Hannover, Studierendenwerk OstNiedersachsen; ohne Gewähr)

ÜBERSICHT UND LERNKALENDER
• Die Übersicht zeigt, was heute ansteht: Lernpakete, Termine, neue Dateien und die Mensa
• Wochenraster und Lernkalender: nacharbeiten, üben, nachholen, „Woche retten“; mit Plus automatisch geplant in deinen freien Zeitfenstern

DOKUMENTE LESEN UND BESCHREIBEN
• Bibliothek mit Modulordnern, Favoriten und Papierkorb; PDFs lesen, durchsuchen, Lesezeichen setzen
• Mit Plus: Schreiben mit dem Apple Pencil – Stift, Marker, Radierer, Lasso, Lineal, Text und Formen; Seiten einfügen, drehen, sortieren; Notizen als PDF exportieren
• Mit Plus: Übung und Skript nebeneinander

LERNEN UND GEMEINSAM LERNEN
• Mit Plus: eigene Karteikarten in Stapeln je Modul, Wiederholung nach dem Leitner-System
• Mit Plus: die Community deines Kurses – Lösungen zu Übungsblättern vergleichen, Fragen stellen und beantworten, unter Pseudonym, mit Melden und Sperren

DEINE DATEN
• Dateien, Notizen und Pläne liegen auf deinem iPad. Kein Tracking, keine Werbung, keine Analyse-Werkzeuge Dritter.
• Dein Hochschul-Passwort gibst du nur auf der Anmeldeseite deiner Hochschule ein. Lässt du „Passwort auf diesem iPad merken“ an, liegt es nur im Schlüsselbund dieses iPads (nicht in iCloud), damit StudiNow dich nach Ablauf einer Sitzung wieder anmeldet – abschaltbar, jederzeit löschbar. An Server von StudiNow geht es nie.
• Was du in der Community teilst, liegt verschlüsselt und unter Pseudonym, nie mit deinem Namen oder deiner E-Mail-Adresse.

STUDINOW FREE UND PLUS
StudiNow Free ist dauerhaft kostenlos: Abgleich mit der Hochschule, Uni-Mail, Noten und Bescheinigungen, Lesen, Stundenplan, Lernkalender, Raumfinder und Mensa. Zum Start hast du 7 Tage Probe mit allem (einmal je iPad) – ohne Zahlungsdaten, danach wählst du: Free bleibt kostenlos, oder Plus. StudiNow Plus (19,99 €/Jahr) schaltet das Schreiben mit dem Apple Pencil, Übung und Skript nebeneinander, Karteikarten, den automatischen Lernplan und die Community deines Kurses frei. Das Jahresabo verlängert sich automatisch um ein Jahr, wenn es nicht spätestens 24 Stunden vor Ablauf in deinem Apple-Konto gekündigt wird. Nach dem Ende von Plus bleiben alle Notizen lesbar und exportierbar.

Nutzungsbedingungen: https://studinow.app/nutzungsbedingungen
Datenschutz: https://studinow.app/datenschutz

StudiNow ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.
```

### Fassung mit Pro AI – für 1.0.6 verwenden (Stand 18.11.2026) – 3990 Zeichen

**1.0.6 (18.11.2026, nicht hochgeladen):** nur, was es in 1.0.6 gibt (Richtlinie 2.3). Entfernt gegenüber 1.0.4:
Lernkalender, KI-Lernplan, automatischer Lernplan, Lernziele in Stunden, „Lernplan“ auf iPhone und bei Plus, der eigene
API-Schlüssel (seit 11.11.2026 aus). Neu: Stundenplan mit Hinweisen und Klausurterminen aus Folien (Texterkennung auf
dem Gerät), Abgleich 8–18 Uhr mit Mitteilungen, Füller und Textmarker, Altklausuren nach Jahrgang, YouTube/Video/
Lernseite daneben (Plus, auch am iPhone), Credits nachkaufen (Pro AI; Plus KI-Chat mit gekauften Credits),
Erinnerungen an Abgaben, Tests und Klausuren bei Pro AI statt Plus, „keine Werbung von StudiNow“ (auf der YouTube-Seite
zeigt YouTube eigene Werbung). Der Text von 1.0.4 steht in `EINREICHUNG-1-0-4.md`.

Dieselben Aussagen wie oben, dazu der Abschnitt „KI-HILFE MIT STUDINOW PRO AI“ und die Tarife mit Pro AI. Um unter
4000 Zeichen zu bleiben, sind Übersicht/Lernkalender und Dokumente/Lernen zusammengefasst. Keine fremden Marken
(ChatGPT, OpenAI) im öffentlichen Text.

```text description-proai
StudiNow ist ein Lernmanagementsystem für Hochschulen in ganz Deutschland – zum Start mit voller Anbindung an die Leibniz Universität Hannover und die Universität Hildesheim. Unterlagen, Termine, Mails und Noten an einem Ort, dazu Apple Pencil, Karteikarten und KI-Hilfe – auf iPhone und iPad.

FÜR STUDIERENDE IN GANZ DEUTSCHLAND
Angebunden: LUH (Stud.IP, QIS) und Uni Hildesheim (Learnweb, LSF), weitere Hochschulen folgen. StudiNow holt Skripte, Übungsblätter und Folien, ordnet sie nach Modulen und Wochen und übernimmt deine Termine – von 8 bis 18 Uhr alle 30 Minuten von selbst (im Hintergrund, wann iOS es zulässt), sonst auf „Sync“; Neues meldet sie als Mitteilung. In die Hochschulsysteme schreibt die App nur, wenn du es auslöst.

AUF IPHONE UND IPAD
Am iPhone lesen, abhaken und mailen; am iPad schreiben mit dem Apple Pencil.

DEINE UNI AN EINEM ORT
• Stud.IP-Nachrichten beantworten, Übungen abgeben – erst nach deiner Bestätigung
• Uni-Mail und Uni-Kalender: lesen, antworten, schreiben
• Notenspiegel und Bescheinigungen wie Immatrikulations- oder BAföG-Bescheinigung als PDF
• Lehrende mit Sprechstunde, Raumfinder mit Route
• Studienverlauf für über 300 Studiengänge, Prüfungsanmeldung mit Erinnerung und Link ins QIS
• Stundenplan mit Hinweisen zu Abgaben, Kurztests und Klausuren; Klausurtermine findet StudiNow auch in Folien (Texterkennung auf dem Gerät)
• Speiseplan deiner Mensa mit Preisen und Allergenen (Studentenwerk Hannover, Studierendenwerk OstNiedersachsen; ohne Gewähr)

LESEN, SCHREIBEN, LERNEN
• Bibliothek nach Modulen; PDFs lesen, durchsuchen, abhaken; Altklausuren nach Jahrgang mit Lösung
• Mit Plus: Schreiben mit dem Apple Pencil – Stift, Füller, Textmarker, Radierer, Lasso, Lineal und Formen; Notizen als PDF exportieren
• Mit Plus: Übung und Skript nebeneinander; daneben (am iPhone darüber) YouTube zum Suchen und Schauen, ein Video per Link, eine Vorlesungsaufzeichnung oder eine Lernseite
• Mit Plus: eigene Karteikarten und die Community deines Kurses – unter Pseudonym, mit Melden und Sperren

KI-HILFE MIT STUDINOW PRO AI
• Frag zur Seite oder zu einem markierten Bereich: erklären, zusammenfassen, Aufgabe lösen
• Ganzes Dokument: „Ganze Vorlesung erklären“ oder „Alle Aufgaben erklären“
• Wochentests und Karteikarten aus deinen Unterlagen, E-Mails ans Prüfungsamt verbessern
• Credits aufgebraucht? 100 oder 200 Credits einmalig nachkaufen; sie verfallen nicht
Die KI ist freiwillig und braucht ein StudiNow-Konto (Anmelden mit Apple). Nur was du ihr schickst, verlässt dein Gerät. KI-Antworten können Fehler enthalten.

DEINE DATEN
• Dateien und Notizen liegen auf deinem Gerät. Kein Tracking, keine Werbung von StudiNow, keine Analyse-Werkzeuge Dritter.
• Dein Hochschul-Passwort bleibt bei dir: Mit „Passwort auf diesem iPad merken“ liegt es nur im Schlüsselbund dieses Geräts (nicht in iCloud). An Server von StudiNow geht es nie.

STUDINOW FREE, PLUS UND PRO AI
StudiNow Free ist dauerhaft kostenlos (ein Gerät): Abgleich mit der Hochschule, Uni-Mail, Noten, Lesen, Stundenplan, Raumfinder und Mensa. Zum Start 7 Tage Probe mit allem aus Pro AI (einmal je Gerät), ohne Zahlungsdaten; danach wählst du: Free bleibt kostenlos, oder Plus bzw. Pro AI. StudiNow Plus (19,99 €/Jahr): Apple Pencil, Übung und Skript nebeneinander, Karteikarten, Community, KI-Chat mit gekauften Credits. StudiNow Pro AI (39,99 €/Jahr): alles aus Plus, die StudiNow-KI mit 100 Credits im Monat, Erinnerungen an Abgaben, Tests und Klausuren und deine Notizen auf allen Geräten. Beide sind Jahresabos und verlängern sich automatisch um ein Jahr, wenn sie nicht spätestens 24 Stunden vor Ablauf in deinem Apple-Konto gekündigt werden. Danach bleiben alle Notizen lesbar und exportierbar.

Nutzungsbedingungen: https://studinow.app/nutzungsbedingungen
Datenschutz: https://studinow.app/datenschutz

StudiNow ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.
```

## Schlüsselwörter (max. 100 Zeichen, durch Komma getrennt) – 100 Zeichen

**1.0.6:** „Lernkalender“ raus (ausgeblendet), dafür „Klausuren“ (Klausurtermine aus Folien, Altklausuren) und „LSF“. Vorher (1.0.4): `Stud.IP,Learnweb,Apple Pencil,Stundenplan,Lernkalender,Karteikarten,Uni-Mail,Mensa,Hildesheim,Noten`. Keine fremden Marken (auch nicht „YouTube“).

Wörter aus Name und Untertitel (StudiNow, Studium, Notizen, Skripte, Handschrift, Lernplan) indiziert Apple ohnehin;
sie stehen hier nicht noch einmal. Keine fremden Marken (z. B. ChatGPT) in Name, Untertitel oder Schlüsselwörtern
(Richtlinie 2.3.7). „Hannover“ deckt die LUH; „Uni“ steckt in „Uni-Mail“. 1.0 nur LUH (Entscheidung 07.11.2026): „Moodle“ und
„Hildesheim“ sind durch „Hochschule“ und „Noten“ ersetzt; mit 1.0.1 (HsH, Hildesheim) „Moodle“ und „Hildesheim“ wieder
aufnehmen (dann z. B. „Hochschule“ und „Noten“ weglassen, max. 100 Zeichen).

```text keywords
Stud.IP,Learnweb,Apple Pencil,Stundenplan,Klausuren,Karteikarten,Uni-Mail,Mensa,Hildesheim,Noten,LSF
```

## Neue Funktionen in dieser Version (1.0.6)

Zwei Fassungen wie bei der Beschreibung: `whats-new-proai` nennt die KI (Uni-Mail, Karteikarten) und gehört in App Store
Connect, solange Pro AI mitverkauft wird; `whats-new` ist der Rückfall ohne KI.

### Fassung ohne KI – Rückfall, Stand 1.0.4 (überholt, nicht verwenden) – 1234 Zeichen

```text whats-new
Neu in 1.0.4:
• Neu angebunden: Universität Hildesheim (Learnweb und LSF) – Kurse, Dateien, Termine und Noten wie an der Leibniz Universität Hannover.
• StudiNow gibt es jetzt auch fürs iPhone: Übersicht, Stundenplan, Lernkalender, Module, Nachrichten, Uni-Mail, Noten und Mensa unterwegs – gelesen und abgehakt wird am iPhone, geschrieben mit dem Apple Pencil weiter am iPad.
• Neuer Einstieg: Willkommen, kurzer Rundgang, ein paar Fragen zu Fächern und Prüfungstagen – danach steht dein erster Wochenplan.
• Haken „erledigt“ im Modul: einzelne Dateien oder eine ganze Lehrwoche abhaken. Der Stand ist auf allen deinen Geräten gleich, Lernpakete und Lernfortschritt ziehen mit.
• Prüfungsanmeldung: ein Knopf führt direkt auf die richtige Seite im QIS.
• Lernziele in Stunden je Fach: sag, wie viele Stunden du bis zur Klausur lernen willst – StudiNow verteilt sie auf deine freie Zeit und zeigt dir, ob es reicht.
• Schreiben mit dem Apple Pencil: Striche werden geglättet (Aus, Leicht, Normal), auf Wunsch werden Formen erkannt; Radierer und Zoom laufen runder.
• Uni-Mail: Hängt die Anmeldung einmal, meldet sich die App selbst neu an; sonst sagt sie verständlich, was zu tun ist.
• Viele kleine Verbesserungen und Fehler behoben.
```

### Fassung mit Pro AI – für 1.0.6 verwenden (Stand 18.11.2026, zehn Punkte) – 2109 Zeichen

Die Fassung von 1.0.4 steht in `EINREICHUNG-1-0-4.md`. „Lernkalender … vorerst ausgeblendet“ steht bewusst drin: Wer 1.0.4 hatte, vermisst ihn sonst ohne Erklärung.

```text whats-new-proai
Neu in 1.0.6:
• Klausuren und Tests: StudiNow erkennt Termine jetzt auch in Folien – auch in PowerPoint und Word und auf Folien, die nur ein Bild sind (Texterkennung auf dem Gerät). Neue Karte oben auf der Übersicht: „Klausuren und Tests: bald und neu erkannt“.
• Der Stundenplan ist dein Kalender: Oben stehen Hinweise zu Terminen, Anmeldungen, Kurztests und Klausuren. Lernkalender, Lernpakete und automatische Lernplanung sind vorerst ausgeblendet.
• Abgleich von selbst: zwischen 8 und 18 Uhr alle 30 Minuten (bei geschlossener App, wann iOS es zulässt), sonst mit „Sync“. Neue Karte „Mitteilungen“: neue Dateien, Nachrichten, Ausfall oder Raumänderung heute und morgen, „Neue Note eingetragen“ – jede Art mit eigenem Schalter.
• Apple Pencil: neues Werkzeug „Füller“, feinere Fineliner-Stufen, der Textmarker lässt den Text lesbar und wird beim Halten gerade, Viereck, Dreieck und Linie werden zuverlässiger erkannt. Striche blitzen nicht mehr auf und gehen nicht mehr verloren.
• Dokument: Die obere Leiste ist eine flache Zeile, die Seite hat mehr Platz. Behoben: Hänger nach „Seite drehen“, der Griff der geteilten Ansicht neben der KI-Hilfe und ein Absturz am iPad in der geteilten Ansicht.
• Video neben dem Dokument (mit Plus): YouTube direkt öffnen, suchen und schauen – nur YouTube, ohne Adresszeile –, dazu ein Video per Link, eine Vorlesungsaufzeichnung oder eine Lernseite. Neu auch am iPhone, über dem Dokument.
• KI-Credits nachkaufen: 100 oder 200 Credits als einmaliger Kauf, mit Plus oder Pro AI und StudiNow-Konto. Mit Plus stellst du der KI damit Fragen (KI-Chat).
• Erinnerungen an Abgaben, Tests und Klausuren (auch „Neuer Klausurtermin erkannt“) gibt es jetzt mit Pro AI.
• Altklausuren sind nach Jahrgang geordnet, jede mit ihrer Lösung. „Neu“ steht an Dateien nur noch 24 Stunden; was beim ersten Einlesen eines Kurses kommt, gilt nicht als neu.
• Übersichtlicher: Das Logo führt zur Übersicht, die Profilkarte öffnet die Einstellungen, die Einstellungen sind in Bereiche gegliedert. Community: Antworten, Kommentare und „Gefällt mir“ klappen zuverlässiger, Melden mit Rückmeldung.
```

## Weitere Angaben

| Feld | Wert |
|---|---|
| Plattform, Geräte | **nur die iOS-App** in App Store Connect (App-ID 6830632088); macOS nicht einreichen, der alte macOS-1.0-Entwurf bleibt liegen (Hinweis oben). Seit 1.0.4 (Build 39) **iPhone und iPad** (`TARGETED_DEVICE_FAMILY` 1,2; iPadOS/iOS 17 oder neuer); Mac mit Apple-Chip über „Designed for iPad“ (Preise und Verfügbarkeit → „iPhone- und iPad-Apps auf Apple-Silicon-Macs“; Mac-Durchlauf am 14.11.2026: der Absturz beim Öffnen von Blättern ist behoben (in Build 41), die zweite Hälfte der Mac-Tests ist noch offen). Achtung: Ist eine Version mit iPhone veröffentlicht, lässt Apple das iPhone nicht mehr entfernen. Für die Store-Einreichung sind dann iPhone-Bilder 6,9" Pflicht (für TestFlight nicht) |
| Primäre Sprache | Deutsch |
| Kategorie | Bildung; zweite Kategorie: Produktivität |
| Support-URL | `https://studinow.app/support` (Kontakt per E-Mail support@studinow.app) |
| Marketing-URL | `https://studinow.app` (optional) |
| Datenschutz-URL | `https://studinow.app/datenschutz` |
| Nutzungsbedingungen (EULA) | eigene unter `https://studinow.app/nutzungsbedingungen` (App-Informationen → Lizenzvereinbarung) oder Apples Standard-EULA – Entscheidung des Inhabers; der Link steht in der Beschreibung und auf der Tarifseite der App |
| Copyright | © 2026 IT solutions by Ahmad Fakih |
| Händlerstatus (DSA) | Händler; Name, Anschrift, E-Mail wie im Impressum (IT solutions by Ahmad Fakih, Inhaber Ahmad Fakih, Vahrenwalder Straße 30, 30165 Hannover, support@studinow.app; werden im Store angezeigt); Telefonnummer verlangt Apple zusätzlich – vom Inhaber eintragen; die E-Mail beim Händlerstatus ändert der Inhaber selbst |
| Bundle-ID, SKU | `de.uniflow.ai` (`docs/RELEASE-VORBEREITUNG.md`); SKU frei wählbar, z. B. `studinow-ipad` |
| Version, Build | 1.0.6 (`MARKETING_VERSION` auf develop seit 16.11.2026; 1.0.5 ist der Hotfix in der Prüfung; 1.0.4 seit 13.11.2026 für Build 36: Smart Planner 2.0, eigene Wochen, kurzer KI-Hinweis; Entscheidung des Inhabers 09.11.2026: der erste veröffentlichte Stand heißt 1.0.1), **Build 45** (`CURRENT_PROJECT_VERSION` auf develop); Build 44 in der Prüfung (`10cf2836`, Version 1.0.5, Hotfix: Absturz bei offenem Dokument auf iPadOS 18/26, Speicher-Runde nach dem Schließen; eingereicht am 16.11.2026 23:42, WAITING_FOR_REVIEW, Freigabe von Hand); Build 43 (`e2e26e56`) seit 15.11.2026 19:41 nur intern in TestFlight (Gruppe „Intern (Inhaber)“, nicht an „LUH-Tester“, nicht eingereicht); Build 42 als Version 1.0.4 veröffentlicht am 16.11.2026 10:49 (eingereicht am 15.11.2026 10:13, von Apple genehmigt, von Hand freigegeben); Build 41 am 14.11.2026 19:56 eingereicht und um 21:54 zurückgezogen (Fehler im iPhone-Layout am echten Gerät), seitdem nur TestFlight; Builds 36 bis 40 (1.0.4) nur TestFlight seit 13.11.2026 (ab 39 mit iPhone, ab 40 mit Hildesheim); Build 35 als Version 1.0.3 veröffentlicht am 13.11.2026; Builds 33 und 34 (1.0.3) nur TestFlight; Build 32 nur TestFlight (Absturz); Build 31 als Version 1.0.2 veröffentlicht am 11.11.2026; Build 30 als Version 1.0.1 veröffentlicht am 10.11.2026; Version 1.0 mit Build 25 freigegeben, nie veröffentlicht, zurückgezogen; Build 26 nie hochgeladen; Build 5 bis 24 nicht einreichen; welcher Commit in welchem Build steckt: `docs/release/BUILD-HERKUNFT.md` |
| Mit Apple anmelden | Fähigkeit aktiv. Seit 12.11.2026 eine Anmeldung für alles: „Mit Apple anmelden“ beim Start trennt die Daten je Apple-Nutzer und meldet zugleich beim StudiNow-Dienst an (Token-Tausch beim Dienst; ein neues Konto direkt nach der Hochschulwahl; dieselbe Apple-ID = dasselbe Konto auf jedem Gerät). Rückfall bei Fehler/offline: Einstellungen → Konto. „Konto löschen“ in der App löscht Gerätedaten und Dienst-Konto und widerruft die Apple-Anmeldung bei Apple (Richtlinie 5.1.1(v); `app/apple_signin.py`, braucht `LERNAPP_APPLE_TEAM_ID`, `LERNAPP_APPLE_SIGNIN_KEY_ID`, `LERNAPP_APPLE_SIGNIN_KEY_FILE` am Server) |
| Exportkontrolle | `ITSAppUsesNonExemptEncryption = NO` steht schon in `project.yml` (nur Verschlüsselung des Betriebssystems: HTTPS über URLSession, AES-256-GCM und HKDF aus CryptoKit); App Store Connect fragt beim Build nicht nach |

## 1.0.6: Angaben bei Apple, die sich ändern müssen

**Nur Vorschlag (18.11.2026), bei Apple ist nichts geändert.** Grund: „YouTube öffnen“ ist in 1.0.6 an
(`YouTubeBrowse.shipped = true`, Entscheidung des Inhabers 18.11.2026). Die Spalte lädt die Seite von YouTube
(`m.youtube.com`/`youtube.com`) mit Startseite, Suche, Vorschlägen, Kanälen und Werbung von YouTube – ohne Adresszeile,
jeder andere Link öffnet außerhalb (Safari), Anmeldung bei Google gesperrt (`YouTubeSidePolicy`,
`docs/VIDEO-LERNSEITEN-2026-11-14.md` Abschnitt 12). Der Inhaber trägt das in App Store Connect ein, bevor 1.0.6
eingereicht wird:

| Wo in App Store Connect | Heute (1.0.4) | Vorschlag für 1.0.6 | Warum |
|---|---|---|---|
| Altersfreigabe → „Uneingeschränkter Webzugang“ (Unrestricted Web Access) | nein | **ja** | In der YouTube-Spalte erreicht man alle Inhalte von YouTube (Suche, Vorschläge, Kommentare, Kanäle). Das ist kein freier Browser, aber Apple wertet frei durchsuchbare Fremdinhalte in einer Web-Ansicht in der Regel so. „Nein“ wäre nur noch mit dem Schalter aus (`YouTubeBrowse.shipped = false`) ehrlich. |
| Altersfreigabe → Ergebnis | 16+ (berechnet 4+, vom Inhaber auf 16+ gesetzt, `docs/UEBERGABE-2026-11-06.md`) | **Altersstufe steigt voraussichtlich** (mit „Uneingeschränkter Webzugang = ja“ setzt App Store Connect die Stufe selbst hoch; den genauen Wert zeigt App Store Connect nach dem Fragebogen) | für Studierende unkritisch (Datenschutzerklärung: nicht unter 16) |
| Altersfreigabe → „Werbung“ | nein | **prüfen**: StudiNow selbst zeigt keine Werbung und hat kein Werbe-SDK; YouTube zeigt in seiner Seite eigene Werbung Dritter, die die App nicht ausblendet (YouTube verlangt das). Vorschlag: „nein“ lassen und im Prüfhinweis offen sagen (steht in `review-notes-proai`: „YouTube's ads and cookie choice unchanged“). Fragt Apple nach, auf „ja“ stellen. | ehrlich gegenüber dem Prüfer |
| App-Datenschutz (Nutrition Labels) | sechs Datentypen | **unverändert** – die App erfasst für YouTube nichts (kein Abgleich, nichts an unseren Dienst; Cookies und Verlauf bleiben im eigenen Speicher auf dem Gerät). Was Google auf seiner Seite erhebt, ist Googles eigene Erhebung als eigener Verantwortlicher, wie bei einem Link. „Für Tracking“ bleibt nein (die App verknüpft nichts mit Daten Dritter). | Apple-Definition „erfasst“ (Abschnitt App-Datenschutz) |
| Datenschutzerklärung (`docs/release/DATENSCHUTZ.md`, Website `site/datenschutz.html`) | nennt YouTube nicht | **neuer Abschnitt 4a** (Entwurf vom 18.11.2026 im Repo, Website-Seite neu erzeugt, **nicht hochgeladen**): YouTube öffnen, Video per Link, Lernseiten, eigener Speicher, Google als eigener Verantwortlicher | muss vor der Freigabe von 1.0.6 auf `studinow.app/datenschutz` stehen (`tools/site-hochladen.sh`, nur der Inhaber) |
| Prüfhinweis | – | Absatz „YouTube (Plus)“ in `review-notes-proai` | Richtlinie 2.3.1 (nichts verstecken) |

Risiko, das der Inhaber kennen sollte: Apple kann bei einer Web-Ansicht mit fremden Inhalten nachfragen (Richtlinien 4.2
„Mindestfunktion“, 5.2.2/5.2.3 „Inhalte Dritter“). Unsere Antwort: Die Spalte ist ein Werkzeug neben dem eigenen
Dokument (mitschreiben beim Video), YouTube bleibt unverändert (Werbung, Einwilligung, Bedienung), es wird nichts
heruntergeladen. Die Nutzungsbedingungen von YouTube (Einbinden der Seite in einer App, Funktion hinter Plus) hat
niemand rechtlich geprüft (`VIDEO-LERNSEITEN-2026-11-14.md`, Abschnitt 12).

Außerdem neu in 1.0.6 bei Apple (unabhängig von YouTube): die zwei In-App-Käufe der Credit-Pakete müssen angelegt und
mit der Version zur Prüfung gegeben werden (Abschnitt In-App-Käufe); den Untertitel von Hand auf „Skripte, Handschrift,
Termine“ setzen.

## Altersfreigabe (Fragebogen in App Store Connect)

| Frage | Antwort | Begründung |
|---|---|---|
| Kindersicherung, Altersprüfung in der App | nein | – |
| Uneingeschränkter Webzugang | nein (Stand 1.0.4; **für 1.0.6 ja vorgeschlagen**, Abschnitt „1.0.6: Angaben bei Apple, die sich ändern müssen“) | Webansichten nur für die Anmeldeseiten der Hochschulen (bekannte Adressen); Links, Google Maps und Apple Karten öffnen außerhalb der App. Ab 1.0.6 dazu die Seite von YouTube neben dem Dokument (Plus) |
| Nutzergenerierte Inhalte | **ja** | Community: Lösungen, Fragen, Antworten, Kommentare; Melden, Blockieren, Moderation durch den Anbieter, Kontaktadresse |
| Nachrichten und Chat | nein | keine Direktnachrichten zwischen StudiNow-Nutzern; Fragen und Antworten sind öffentliche Beiträge in der Community eines Kurses. Uni-Mail und Stud.IP-/Moodle-Nachrichten sind Postfächer der Hochschule, die die App wie ein Mailprogramm anzeigt |
| Werbung | nein | – |
| Grobe Sprache, Horror, Alkohol/Tabak/Drogen, sexuelle Inhalte oder Nacktheit, Gewalt, Waffen, Glücksspiel (auch simuliert), Wettbewerbe | keine | – |
| Medizinische Inhalte, Gesundheit und Wellness | keine | – |

Die Stufe berechnet App Store Connect aus den Antworten. Zielgruppe sind Studierende (Datenschutzerklärung,
Abschnitt 16: nicht für Kinder unter 16); eine höhere Stufe als 4+ wegen nutzergenerierter Inhalte ist unkritisch.

## App-Datenschutz (Nutrition Labels)

**Build 11, neu abgeleitet aus dem Code (06.11.2026).** Grundlage: `StudoraAccountLink.swift` (StudiNow-Konto, Dienst
`https://app.studinow.app`), `BillingServiceLink.swift` (`isEnabled = true`), `StudiNowAI.swift` (`/api/ai/relay`),
`DeviceSync.swift`, `UniAutoLogin.swift`, die CloudKit-Dateien unter `Services/` und `docs/release/DATENSCHUTZ.md`
(Abschnitte 3–9). „Erfasst“ heißt nach Apples Definition: verlässt das Gerät und bleibt für uns oder unsere
Auftragsverarbeiter länger abrufbar, als die Anfrage dauert. Optionale Funktionen (StudiNow-Konto, KI, Community)
zählen mit.

**Stand 12.11.2026 („eine Anmeldung für alles“, Entscheidung des Inhabers):** „Mit Apple anmelden“ beim ersten Start
meldet jetzt zugleich beim StudiNow-Dienst an; jeder Nutzer hat damit ein StudiNow-Konto, Geräteabgleich und Meldung
der Käufe laufen für alle (nicht mehr „nur mit StudiNow-Konto“). **Neue Datentypen kommen dadurch nicht dazu** – alle
unten stehenden waren schon angegeben, weil Apple optionale Funktionen mitzählt. Neu in bestehenden Typen: der Hash
(SHA-256) der Stud.IP-Benutzerkennung (Datentrennung im Geräteabgleich) gehört zu „Kennungen → Nutzer-ID“; das
verschlüsselte Refresh-Token von Apple (nur für den Widerruf beim Löschen, Richtlinie 5.1.1(v)) ist kein vom Nutzer
erhobener Datentyp. **Für App Store Connect (Inhaber, dort nichts automatisch):** prüfen, dass genau diese sechs
Datentypen eingetragen sind, alle „mit Identität verknüpft“, keiner „für Tracking“, Zweck „App-Funktionalität“ –
insbesondere „Kennungen → Geräte-ID“ (seit P46-04 nachzutragen) und „Käufe → Kaufverlauf“; fehlt einer, ergänzen.

Frage „Erfassen Sie oder Ihre Drittanbieter Daten aus dieser App?“ → **Ja**.

| Datentyp | Erfasst | Mit Identität verknüpft | Für Tracking | Zweck | Was genau |
|---|---|---|---|---|---|
| Kontaktinformationen → E-Mail-Adresse | ja | ja | nein | App-Funktionalität | StudiNow-Konto (seit 12.11.2026 für alle): die Adresse, die Apple bei „Mit Apple anmelden“ übermittelt (ggf. Weiterleitungsadresse), bzw. die bei der Registrierung angegebene; Mitteilungen zum Konto |
| Kennungen → Nutzer-ID | ja | ja | nein | App-Funktionalität | Konto-ID und Apple-Kennung beim StudiNow-Dienst; Hash (SHA-256) der Stud.IP-Benutzerkennung (Datentrennung im Geräteabgleich, seit 12.11.2026); CloudKit-Nutzerkennung (zufällig, nur für StudiNow) in jedem Community-, Wochentest- und Bibliotheks-Datensatz (Zurückziehen, Melden, Blockieren, Moderation) |
| Kennungen → Geräte-ID | ja | ja | nein | App-Funktionalität | zufällige Kennung dieser Installation (`ipad-<UUID>`, `StudoraAccountLink.deviceID`, keine Werbe- oder Hardware-Kennung) als `device_id` bei Anmeldung und Geräteabgleich; der Dienst führt sie bei der Sitzung (Geräteliste, andere Geräte abmelden). **Neu seit Audit P46-04 (08.11.2026), gilt ab Build 27; in App Store Connect vom Inhaber nachzutragen** |
| Käufe → Kaufverlauf | ja | ja | nein | App-Funktionalität | die von Apple signierte Transaktion (Produkt, Laufzeit, Transaktionskennung) geht an `/api/billing/apple/verify` bzw. bei Credit-Paketen (ab 1.0.6) an `/api/billing/credits/apple`, damit Tarif und Credits am Konto stimmen; keine Zahlungsdaten |
| Nutzerinhalte → Andere Nutzerinhalte | ja | ja | nein | App-Funktionalität | Community (Lösungen verschlüsselt, Fragen, Antworten, Kommentare, Meldungen; CloudKit bzw. mit Konto im Dienst); KI-Anfragen (Seitentext bzw. Bild eines Bereichs, Frage, Kurs- und Dateiname) an den Dienst und weiter an den KI-Anbieter; Geräteabgleich mit dem Konto (Module, Termine, Lernpakete, Karteikarten, Einstellungen; Notizen ab Pro AI) |
| Nutzungsdaten → Produktinteraktion | ja | ja | nein | App-Funktionalität | je KI-Anfrage Zeitpunkt, Art der Aufgabe und verbrauchte Credits (Abrechnung der Credits, Monatsgrenze) |
| Gesundheit und Fitness, Finanzinformationen, Standort, sensible Daten, Kontakte, Browserverlauf, Suchverlauf, Diagnose, Name, sonstige Daten | nein | – | – | – | – |

Warum so:

- **Hochschul-Passwörter werden nicht erfasst.** Die App merkt sich Benutzername und Passwort der Hochschule nur, wenn
  der Schalter „Passwort auf diesem iPad merken“ an ist (voreingestellt an, jederzeit abschaltbar), und nur im
  Schlüsselbund dieses iPads (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false`:
  nicht in iCloud, nicht im Backup). Das Passwort geht nur an die Anmeldeseiten der Hochschule, nie an StudiNow-Server;
  der Dienst speichert keine Hochschul-Passwörter (seit 06.11.2026, `DATENSCHUTZ.md` Abschnitt 6). Es verlässt das
  Gerät also nicht in unsere Richtung – keine Erfassung im Sinne Apples.
- **Mit Apple anmelden beim Start** meldet seit 12.11.2026 zugleich beim **StudiNow-Konto** an: Apples
  Identitäts-Token (und der einmalige Code für das Refresh-Token zum Widerruf) gehen an den Dienst – daher E-Mail-Adresse
  und Nutzer-ID. Den Namen übermittelt die App dabei nicht; er bleibt im Schlüsselbund des iPads.
- **KI (Pro AI bzw. Probe des Kontos):** Der Dienst gibt jede Anfrage an einen Auftragsverarbeiter weiter (heute
  OpenAI; Claude über Amazon Bedrock Frankfurt, sobald eingeschaltet). Antworten speichert der Dienst 24 Stunden bzw.
  ohne Kontobezug bis 30 Tage (`DATENSCHUTZ.md` 8c) – darum „erfasst“. Die Anmeldung bei ChatGPT ist im Build aus
  (`ChatGPTLink.isEnabled = false`). Der **eigene OpenAI-Schlüssel** (Einstellungen → Erweitert, seit 07.11.2026, jeder
  Tarif) schickt dieselben Inhalte direkt vom iPad an OpenAI über das Konto des Nutzers, nie über uns (`DATENSCHUTZ.md`
  8a); vor dem Speichern des Schlüssels steht der Hinweis, was gesendet wird, mit Haken „Ich stimme zu …“
  (`OpenAIKeyCard.swift`, Richtlinie 5.1.2(i)). Die Datenart „Andere Nutzerinhalte“ ist ohnehin angegeben.
- **Uni-Mail, Lehrende, Noten, Bescheinigungen** liegen nur auf dem Gerät und bei der Hochschule; nichts davon geht an
  den Dienst (`DATENSCHUTZ.md` Abschnitt 4). Der Raumfinder schickt nur den Suchtext an den öffentlichen Standortfinder
  der LUH, Google Maps bekommt erst etwas, wenn man „Route“ antippt – kein Standort, keine Erfassung durch uns.
- **Verknüpft ja:** Konto- und CloudKit-Datensätze tragen eine Nutzerkennung; Apple nennt Daten nur dann „nicht
  verknüpft“, wenn Kennungen vor der Erfassung entfernt werden. Die vorsichtige Angabe kostet nichts.
- **Diagnose:** keine Absturz- oder Analyse-SDKs; Absturzberichte über Apple (TestFlight, Xcode Organizer) sind Apples
  eigene Erfassung. Zugriffsprotokolle des Servers (IP-Adresse, 14 Tage, nur Sicherheit) werden nicht ausgewertet und
  keiner Person zugeordnet.
- **Datenschutz-Manifest:** `apps/apple/UniFlow/PrivacyInfo.xcprivacy` nennt dieselben Datenarten wie die Tabelle
  (verknüpft, kein Tracking, App-Funktionalität; seit 06.11.2026 fünf, seit 08.11.2026 sechs mit der Geräte-ID,
  Audit P46-04, Build 25 trägt noch die fünf) und die Gründe der genutzten APIs (UserDefaults CA92.1,
  Datei-Zeitstempel C617.1 und 3B52.1, freier Speicher E174.1, seit Build 16 Systemstartzeit 35F9.1 für verstrichene
  Zeit in der App: `DispatchTime.uptimeNanoseconds`, `CLOCK_MONOTONIC`); geprüft in `tests/test_ai_consent.py` und
  `AIConsentAppTests`. Gilt ab Build 11.

## In-App-Käufe

Tarife nach `docs/ABO-SYSTEM.md`; Namen, Preise und Produkt-IDs aus `packages/shared-contracts/fixtures/plans/plans.json`
(`app/plans.py`). **Die App bietet StudiNow Free, StudiNow Plus und StudiNow Pro AI an** (`UFPlanCatalog.sellable`).
StudiNow Free hat kein Produkt. **Keine Einführungsangebote:** die 7-Tage-Probe läuft in der App selbst, ohne Kauf und
ohne Zahlungsdaten (einmal je Apple-ID und einmal je iPad), danach wählt man auf „Deine Probe ist vorbei“ Free, Plus
oder Pro AI („Bei Free bleiben“ ohne Kauf); wer sich beim StudiNow-Konto anmeldet, bekommt dort
zusätzlich 7 Tage Probe mit 25 Credits für die StudiNow-KI. **Nur Jahresabos (Entscheidung des Inhabers vom
09.11.2026, abends: „Monatliche Abos komplett entfernen. Nur 19,99 und 39,99.“):** zwei automatisch verlängerbare
Abos in der Abo-Gruppe „StudiNow“, kein Umschalter der Zahlweise mehr in der App. Die Tarifkarte zeigt den
Jahrespreis aus dem Store und „entspricht … im Monat“ (Jahrespreis durch 12, aus StoreKit).

| Feld | StudiNow Plus | StudiNow Pro AI |
|---|---|---|
| Produkt-ID | `de.uniflow.plus.yearly` (die Kennung bleibt bei `de.uniflow`, Bundle-ID `de.uniflow.ai`) | `de.uniflow.proai.yearly` |
| Abo-Gruppe / Stufe | StudiNow / Stufe 2 | StudiNow / Stufe 1 (höchste) |
| Referenzname | StudiNow Plus (jährlich) | StudiNow Pro AI (jährlich) |
| Dauer | 1 Jahr | 1 Jahr |
| Anzeigename (max. 30) | StudiNow Plus | StudiNow Pro AI |
| Beschreibung (max. 45) | Stift, Karteikarten, Community, Lösungen | Alles aus Plus und die StudiNow-KI |
| Preis | 19,99 € pro Jahr (Deutschland als Basis, andere Länder automatisch angepasst) | 39,99 € pro Jahr (ebenso) |
| Einführungsangebot | keins | keins |
| Einreichen | mit Version 1.0 bzw. dem nächsten Build (Version → In-App-Käufe und Abonnements → Produkt auswählen) | ebenso |
| Prüf-Screenshot | Tarifseite mit allen drei Karten: `~/Studora-Builds/appstore-pruefung/tarif-portrait.png` (bzw. `tarif-landscape.png`; `StoreScreenshotFinalTests.testTarifPruefung`, Stand 09.11.2026, neu aufnehmen) | dasselbe Bild (Pro-AI-Karte mit 39,99 €, KI-Funktionen und Konto-Hinweis) |
| Prüfhinweis zum Abo | „Plus unlocks writing with Apple Pencil, exercise and script side by side, flashcards, the course community (read and post) and sharing own solutions; StudiNow Free has no community. Yearly subscription. Buy and restore on the plan page: Einstellungen → Zugang & Darstellung → Tarif → Tarif wechseln.“ | „Pro AI includes everything in Plus plus the StudiNow AI (100 credits per calendar month) and note sync between devices. Yearly subscription. The AI runs on our service with the StudiNow account; "Sign in with Apple" on first launch signs in there too (fallback: Einstellungen → Zugang & Darstellung → Konto → Mit Apple anmelden). Then open a PDF and use KI-Hilfe.“ |

**Frühere Monatsabos** (`de.uniflow.plus.monthly`, `de.uniflow.proai.monthly`, bis 09.11.2026): in App Store Connect
genehmigt und nicht löschbar, darum **aus dem Verkauf genommen** (Klickliste in `ABO-NUR-JAHR-2026-11-09.md`). Die App
lädt und zeigt sie nicht mehr; ein früherer Kauf damit (Sandbox/TestFlight) gilt in App und Dienst weiter als Kauf des
Tarifs (`UFPlan(productID:)`, `plans.LEGACY_PRODUCTS`), die Tarifkarte bietet dann den Wechsel zum Jahresabo an.

Die KI-Credits gelten auch beim Jahresabo je Kalendermonat (100 Credits, `credit_months` im Dienst).

**Credit-Pakete (neu mit 1.0.6, `docs/KI-CREDITS-2026-11-15.md` Abschnitt 9):** zwei Verbrauchsartikel (Consumable),
ohne Familienfreigabe, mit der Version 1.0.6 zur Prüfung geben (erste Einreichung eines neuen In-App-Kaufs braucht eine
Version). Kaufen darf, wer **bezahltes** Plus oder Pro AI hat und beim StudiNow-Konto angemeldet ist (nicht in der Probe,
nicht mit Free; `plans.CREDIT_PACKS`). Gekaufte Credits verfallen nicht; mit Plus nur für den KI-Chat. In der App:
Einstellungen → Konto & Tarif → Tarif → „Credits kaufen“, dazu das Blatt in der KI-Hilfe, wenn die Credits aufgebraucht
sind. Prüf-Bild: Blatt „Credits kaufen“ (`CreditShopAppTests`, nur mit `UF_CREDIT_SHOTS`).

| Feld | Kleines Paket | Großes Paket |
|---|---|---|
| Produkt-ID | `de.uniflow.credits.klein` | `de.uniflow.credits.gross` |
| Referenzname | Credits klein | Credits groß |
| Anzeigename (de-DE) | 100 Credits | 200 Credits |
| Beschreibung (max. 45) | 100 Credits für die StudiNow-KI | 200 Credits für die StudiNow-KI |
| Preis | 1,99 € | 3,99 € |

Liefert StoreKit Pro AI nicht (fehlt in App Store Connect, nicht freigegeben, kein Netz), zeigt die Tarifseite nur Free
und Plus und darunter „StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden. Öffne die Seite später noch
einmal.“ (`Plans.swift`, `proAIMissingNote`) ohne Preis und ohne Kaufknopf. Mit Produkt erscheint die Pro-AI-Karte mit dem Preis aus dem Store. StudiNow Pro Connect gibt es nicht
mehr; `de.uniflow.proconnect.monthly` nicht anlegen.

**Tarifkarten (Stand 07.11.2026, App-Prüfung):** nur, was auf dem iPad wirklich geht, nichts „in Vorbereitung“, kein
ChatGPT (`UFPlanCard`, `PlanContractTests`).
- **Free:** Stud.IP verbinden und abgleichen, Dokumente lesen, Meine Module und Stundenplan, Lernkalender ansehen und
  abhaken, Lernblöcke selbst planen, Notizen ansehen/exportieren, Uni & Noten.
- **Plus:** Schreiben mit Apple Pencil, Community, eigene Lösungen teilen, Übung und Skript nebeneinander, eigene
  Karteikarten, „Lernplan automatisch erstellen“ (Lernslots in deinen freien Zeiten; Free sieht dafür das Schloss).
- **Pro AI:** „KI-Hilfe zu deinen Unterlagen“ (Seite, Bereich, ganzes Dokument, „Ganze Vorlesung erklären“, „Alle
  Aufgaben erklären“), „Karteikarten aus deinen Unterlagen“, „Wochentests erstellen“ (StudiNow-KI; auf dem iPad darum
  Pro AI), „Notizen auf allen deinen Geräten“; Zeile „Braucht ein StudiNow-Konto (Anmelden mit Apple). 100 Credits im
  Monat.“ Nicht gebaute Rechte des Vertrags (Lernstatistik, Empfehlungen, Testbibliothek, fertige Wochenfragen,
  vollständige Testliste) stehen auf keiner Karte.

**Probe auf dem iPad:** 7 Tage alles wie Pro AI, ohne Kauf, einmal je Apple-ID (Schlüsselbund + iCloud) **und einmal je
iPad** (Geräte-Marke im Schlüsselbund, nur dieses Gerät, übersteht die Neuinstallation; eine weitere Apple-ID sieht
„Auf diesem iPad wurde die Probe schon genutzt“). Die StudiNow-KI braucht auch in der Probe ein StudiNow-Konto (neue
Konten: 25 Credits). **Nach der Probe** liegt der Bildschirm „Deine Probe ist vorbei“ über der App (Free, Plus, Pro AI,
nur Jahresabos), nicht wegzuwischen; „Bei Free bleiben“ ist eine gültige Wahl ohne Kauf, wird je Apple-ID gemerkt und
kommt danach nicht wieder (`UFTrialDecision`). Während der Probe steht auf der Tarifseite „Probe aktiv: alle Funktionen von StudiNow Pro AI bis
… (noch n Tage)“, keine Karte trägt „Aktueller Tarif“, die Pro-AI-Karte trägt „Probe“. Stärker wäre später Apple
DeviceCheck (übersteht das Zurücksetzen des Geräts, braucht einen Schlüssel und eine Abfrage im StudiNow-Dienst).

Kaufprüfung: Der Tarif auf dem iPad entsteht immer aus StoreKit 2 auf dem Gerät; ein Fehler des Dienstes sperrt nie
einen Kauf. Ist ein StudiNow-Konto angemeldet, kauft die App mit `appAccountToken` (Kennung des Kontos) und meldet die
signierte Transaktion nach Kauf, Verlängerung und einmal je Anmeldung an `POST /api/billing/apple/verify`
(`UFBillingServiceLink`); erst damit kennt der Dienst Pro AI und gibt Credits. Ohne Konto geht keine Kaufmeldung hinaus.

**TestFlight (Beta „LUH-Tester“, 08.11.2026):** Käufe in TestFlight laufen in Apples Sandbox (kein Geld; Jahresabo =
1 Stunde, höchstens 12 Verlängerungen). Der Dienst nimmt Sandbox-Transaktionen an, kennzeichnet sie (`environment`) und gibt
dieselben 100 Credits wie bei echten Pro-AI-Abos; Einladungstext, Tester-FAQ und Ablaufplan in `TESTFLIGHT-500-2026-11-08.md`.

Pflichttexte auf der Tarifseite in der App: Preis und Laufzeit, automatische Verlängerung, Kündigung in den
Einstellungen, Links zu Nutzungsbedingungen und Datenschutzerklärung, „Käufe wiederherstellen“.

## Hinweise für die App-Prüfung (Review Notes)

> **Achtung, Stand 18.11.2026 (Zweig `mac/lesbarkeit`):** Der Inhaber hat entschieden, den Textlink
> „Ohne Hochschulkonto ansehen (Demo)“ von der Anmeldeseite zu entfernen (`FirstLoginFlow.demoLinkShown = false`).
> Sobald das in einem Build ist, stimmen die Prüfhinweise unten nicht mehr: Schritt 3 beschreibt einen Link, den es
> dann nicht gibt. Vor der nächsten Einreichung muss der Inhaber festlegen, wie Apples Prüfer ohne Hochschulkonto
> in die App kommen (z. B. Zugangsdaten eines Test-Kontos der Hochschule im Feld „Anmeldung erforderlich“), und die
> Hinweise müssen das beschreiben. Sonst ist eine Ablehnung nach Richtlinie 2.1 (unvollständiger Zugang) zu erwarten.

Auf Englisch, damit jede Prüferin sie lesen kann; Bezeichnungen der Oberfläche stehen auf Deutsch in Anführungszeichen,
wie sie in der App erscheinen. Anmeldedaten für ein Demo-Konto: keine (Feld „Anmeldung erforderlich“ ausschalten – die
Demo braucht kein Hochschulkonto, „Mit Apple anmelden“ nimmt die Prüfer-Apple-ID, auch für das StudiNow-Konto).
Kontakt: Ahmad Fakih, support@studinow.app, Telefon vom Inhaber. Die Notizen beschreiben den Build ehrlich, also auch
die KI, wenn Pro AI nicht eingereicht ist (Richtlinie 2.3.1: keine versteckten Funktionen) – sie sind kein Werbetext.

Demo nur für Prüfer (Entscheidung des Inhabers 04.11.2026): normale Nutzer sehen die Demo nirgends. Einziger Weg ist
der kleine Textlink „Ohne Hochschulkonto ansehen (Demo)“ ganz unten auf der Anmeldeseite der Hochschule (Wortlaut in
der App und hier gleich, `tests/test_release_texts.py`). Solange die Demo aktiv ist, steht oben eine schmale Leiste
„Demo-Inhalte – erfunden, ohne Hochschule“ mit „Beenden“. Die Store-Bildschirmfotos zeigen die Leiste nicht.

**Richtlinie 5.1.2(i) (KI-Weitergabe), erledigt 06.11.2026:** Vor der ersten Anfrage an die StudiNow-KI zeigen iPad,
Web und Windows einmal „KI-Hilfe: Was wird gesendet?“ (was, an wen: StudiNow-Dienst, OpenAI bzw. Claude über Amazon
Bedrock Frankfurt, Link zur Datenschutzerklärung) und senden ohne „Okay, los“ nichts (zentral in
`StudiNowAI.json` bzw. `app/ai_consent.py`, je Konto, widerrufbar unter „KI-Einwilligung widerrufen“).

### Fassung nur Plus – ÜBERHOLT, nicht verwenden (1.0.4 wird mit Pro AI eingereicht) – 3910 Zeichen

```text review-notes
StudiNow is a study app for students in Germany. Connected today: Leibniz Universität Hannover. Its university features (files, timetable, messages, mail, grades) need the student's personal university account, which we cannot share. Please use the built-in demo content (no university account needed):

1. Tap "Mit Apple anmelden" (Sign in with Apple). It keeps the data of each Apple account and each university strictly separate on the device; it sends nothing to our servers.
2. Choose a plan ("StudiNow Free" is enough) and the university "Leibniz Universität Hannover" (the only one offered in this version). A 7-day trial with everything unlocked starts automatically, no purchase or payment details (once per iPad). Afterwards "Deine Probe ist vorbei" asks for a choice; "Bei Free bleiben" needs no purchase.
3. On the university login page tap the small text link "Ohne Hochschulkonto ansehen (Demo)" at the very bottom, below "Später anmelden". This creates a demo module with three PDFs, timetable, study calendar, five flashcards, a deadline and an announcement (all invented by us). Demo mode never contacts the university.
While the demo is active, a slim bar "Demo-Inhalte – erfunden, ohne Hochschule" is shown at the top. Tap "Beenden" in that bar and confirm: all demo content is removed.

University password: below each university login page, the switch "Passwort auf diesem iPad merken" (on by default, can be turned off) stores the university user name and password only in this iPad's Keychain (this device only, not synced to iCloud) to sign in again when a session expires. It is never sent to our servers. Type or delete it under "Einstellungen" → "Zugang & Darstellung" → "Uni-Zugang"; signing out also deletes it.

Subscriptions: "StudiNow Plus" (yearly subscription; no introductory offers) can be tested in the sandbox on the plan page ("Einstellungen" → "Zugang & Darstellung" → "Tarif" → "Tarif wechseln"), including "Käufe wiederherstellen". Plus unlocks writing with Apple Pencil, exercise and script side by side, flashcards, the course community and sharing own solutions. The trial is the app's own, not an App Store offer. After Plus ends, all notes stay readable and exportable. Terms: https://studinow.app/nutzungsbedingungen, privacy: https://studinow.app/datenschutz.

AI: the build contains AI help ("KI-Hilfe" in the editor, "KI-Start"). It is answered by our own service (https://app.studinow.app) and belongs to the plan "StudiNow Pro AI", which is not part of this submission; the plan page shows "StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden." without price or buy button. To try it anyway: "Einstellungen" → "Zugang & Darstellung" → "StudiNow-Konto" → "Mit Apple anmelden" creates a StudiNow account with a 7-day trial of 25 AI credits. Without account or plan the AI places explain this and send nothing; nothing is sent before "Okay, los" in the notice "KI-Hilfe: Was wird gesendet?". Own OpenAI key ("Einstellungen" → "Erweitert" → "Eigenes ChatGPT", every plan): after the notice and ticking "Ich stimme zu …", the same content goes directly from the iPad to OpenAI on the user's own key; no ChatGPT login exists in the build.

Account deletion: "Einstellungen" → "Zugang & Darstellung" → "Konto löschen" (device); the "StudiNow-Konto" card has its own "Konto löschen" (online account).

Community (guideline 1.2): students of a course share notes on an exercise sheet, ask questions and comment, under a pseudonym; content is encrypted in our public CloudKit database (or our service with a StudiNow account). Every post can be reported ("Melden") and its author blocked ("Blockieren"). We review reports within 24 hours, remove content and ban users. Contact: support@studinow.app. Needs Plus or the trial.

No tracking, no ads, no third-party analytics. Not endorsed by universities; it writes to them only on explicit user action.
```

### Fassung mit Pro AI – für 1.0.6 verwenden (Stand 18.11.2026) – 3806 Zeichen (max. 4000)

**1.0.6:** Wege in den Einstellungen nach der neuen Gliederung („Konto & Tarif“, „Uni-Zugang & Abgleich“), dazu
Credit-Pakete (wo, wer darf), Lernkalender bewusst aus, Hintergrund-Modi (`fetch`/`processing` für den Abgleich 8–18 Uhr,
`audio` für die Vorlesungsaufnahme), Texterkennung auf
dem Gerät, „YouTube öffnen“. Gestrichen gegenüber 1.0.4: der eigene OpenAI-Schlüssel (seit 11.11.2026 nicht im Build),
die Geräte-Regel im Einzelnen. Die Fassung von 1.0.4 steht in `EINREICHUNG-1-0-4.md`.

```text review-notes-proai
New in 1.0.6: AI credit packs (two consumables), exam dates found in slides, automatic sync 8:00-18:00, YouTube next to a document (Plus). The study calendar (study packages, auto planning) is switched off on purpose; the timetable is the calendar.

Connected today: Leibniz Universität Hannover and Universität Hildesheim. University features need a personal account. Please use the demo:
1. Tap "Mit Apple anmelden" (Sign in with Apple). It separates data per Apple account.
2. Choose "StudiNow Free" and "Leibniz Universität Hannover". A 7-day trial at Pro AI level starts, no purchase, once per device.
3. On the university login page tap the small link "Ohne Hochschulkonto ansehen (Demo)" at the bottom: an invented module with PDFs, timetable and flashcards; it never contacts the university. The bar "Demo-Inhalte – erfunden, ohne Hochschule" marks it; "Beenden" removes it.

After the trial "Deine Probe ist vorbei" shows Free, Plus and Pro AI (yearly) and closes only after a choice. "Bei Free bleiben" is a valid choice without any purchase.

iPhone support: The Pencil editor stays on iPad; documents open in a reader.

University password: "Passwort auf diesem iPad merken" keeps it only in this device's Keychain (not synced to iCloud); it is never sent to our servers. "Einstellungen" → "Uni-Zugang & Abgleich" → "Uni-Zugang".

Background modes: "fetch" (lists) and "processing" (new files) sync due portals between 8:00 and 18:00 local time, every 30 minutes at most; iOS decides when. Otherwise only "Sync". Only the saved session or the login saved on the device is used.

Text recognition: exam dates are also read from slides (PDF, PowerPoint, Word); image-only slides use Apple's on-device text recognition. Nothing is uploaded; found dates say "bitte prüfen".

YouTube (Plus): document → "Mehr" → "Video oder Lernseite daneben …" → "YouTube öffnen" (iPhone: "Video oder Lernseite"). After a notice that data goes to Google and "Öffnen", the column loads only youtube.com / m.youtube.com: no address bar, other links open outside in Safari, Google sign-in blocked, YouTube's ads and cookie choice unchanged, nothing downloaded.

Subscriptions (yearly only, no introductory offers; monthly products are removed from sale; 19.99 € and 39.99 € from 11 Nov 2026): "Einstellungen" → "Konto & Tarif" → "Tarif" → "Tarif wechseln", with "Käufe wiederherstellen".

Credit packs "100 Credits" (de.uniflow.credits.klein), "200 Credits" (de.uniflow.credits.gross): need paid Plus or Pro AI (not the trial) and the StudiNow account. Sandbox: "Einstellungen" → "Konto & Tarif" → "Tarif" → "Credits kaufen"; the sheet also opens in "KI-Hilfe" when credits run out. Our service verifies and credits each transaction once, then the app finishes it. Credits never expire and stay with the account (nothing to restore). With Plus they pay only for questions (AI chat).

AI (Pro AI, 100 credits per month) runs on https://app.studinow.app with the StudiNow account (fallback "StudiNow-Konto" → "Mit Apple anmelden"). In the sandbox or trial open a demo PDF, tap "KI-Hilfe", ask. "KI-Hilfe: Was wird gesendet?" comes first: page text or image of a circled area, question, course and file name go via our service to OpenAI or Claude (Amazon Bedrock, Frankfurt), privacy policy section 8c; never name, e-mail or university credentials. Nothing is sent before "Okay, los". Uni-Mail "Mit KI verbessern" (Pro AI) only proposes; sent only with "Senden". No own API key and no ChatGPT login in this build.

Account deletion: "Einstellungen" → "Konto & Tarif" → "Konto löschen" (also revokes Sign in with Apple).

Community (1.2): pseudonyms, "Melden", "Blockieren", reports reviewed within 24 hours; support@studinow.app.

No tracking, no analytics. Not endorsed by universities; writes there only on user action.
```

## Bildschirmfotos

Pflicht für die Einreichung mit iPhone: ein Satz **iPad 13"** und ein Satz **iPhone 6,9"**. App Store Connect rechnet
beide auf die kleineren Geräte herunter. Nur echte App-Inhalte, keine Uni-Logos, keine eingebrannte Beschriftung, keine
Demo-Leiste. **Für 1.0.6 (18.11.2026, nicht hochgeladen)** sind beide Sätze neu, mit erfundenen Demo-Inhalten („Tobi“,
Modul „Demo: Grundlagen der Informatik“, Tarif Pro AI, Lehrende `@example.org`), ohne echte Namen, Noten,
Matrikelnummern oder Daten Dritter, ohne YouTube-Inhalte. Grund: Jedes Bild der Sätze für 1.0.4 zeigte etwas, das es in
1.0.6 nicht mehr gibt – iPad: Menüpunkt „Lernkalender“ in der Seitenleiste jedes Bildes, Übersicht mit „Heute für
dich geplant“, „Diese Woche“ und „Weiterlernen“, Stundenplan mit „Lernblock danach“, Editor mit der alten Leiste und
einem Textmarker, der den Text verdeckt; iPhone: Startseite mit „Weiterlernen“ und Lernpaketen, Bild 2 „Lernkalender“.
Erzeugen: `docs/release/SCREENSHOTS.md`, Abschnitt „Satz für 1.0.6“. `tools/store_einreichen.py` (`SHOTS`) zeigt auf
diese Ordner und diese Reihenfolge. Hell und dunkel gemischt wie bei 1.0.4 (iPad gemischt, iPhone die hellen; die
dunklen iPhone-Bilder liegen als Alternative daneben).

### iPad 13" (2064 × 2752) für 1.0.6

Ordner `~/Studora-Builds/appstore-screenshots-1-0-6-ipad/`, genau zehn Bilder im Hochformat, neue Reihenfolge (Editor
und Stundenplan weiter vorn):

| Nr. | Datei | Motiv |
|---|---|---|
| 1 | `01-uebersicht-light.png` | Übersicht „Hallo Tobi“: oben „Klausuren und Tests: bald und neu erkannt“ (Kurztest morgen, Klausur aus den Folien), „Nächste Klausuren“, Prüfungsanmeldung |
| 2 | `02-ki-frage-dark.png` | Skript mit KI-Hilfe: Frage zur Seite und Antwort der StudiNow-KI (Credits); neue flache Leiste, Textmarker lässt den Text lesbar |
| 3 | `03-stundenplan-termin-light.png` | Stundenplan mit Termin-Detail (Raum mit Route, Lehrende mit E-Mail), ohne „Lernblock danach“ |
| 4 | `04-skript-uebung-stift-dark.png` | Skript und Übungsblatt nebeneinander mit Apple-Pencil-Notizen, neue Leiste mit Füller |
| 5 | `05-ki-karteikarten-light.png` | Karteikarten, von der KI aus dem Skript erstellt, eine Karte aufgedeckt |
| 6 | `06-community-diskussion-dark.png` | Community des Moduls: Frage mit drei Antworten unter Pseudonym |
| 7 | `07-uni-mail-light.png` | Uni-Mail: Posteingang und geöffnete Mail |
| 8 | `08-wochentest-ki-dark.png` | Wochentest mit Auswertung der KI |
| 9 | `09-raumfinder-light.png` | Raumfinder mit Google Maps und Route |
| 10 | `10-mensa-light.png` | Mensa |

### iPhone 6,9" (1320 × 2868) für 1.0.6

Ordner `~/Studora-Builds/appstore-screenshots-1-0-6-iphone/`: sieben Motive je hell und dunkel
(`<nn>-<name>-{light|dark}-portrait.png`); hochladen die **hellen sieben** in dieser Reihenfolge. **Demo-Inhalte statt
der Kontodaten des Inhabers** (Satz für 1.0.4): sonst wäre Bild 2 nicht ohne Lernkalender zu ersetzen gewesen, und
so zeigen iPad und iPhone dieselben erfundenen Inhalte.

| Nr. | Datei (hell) | Motiv |
|---|---|---|
| 1 | `01-uebersicht-light-portrait.png` | Startseite: „Klausuren und Tests: bald und neu erkannt“, nächste Klausuren |
| 2 | `02-stundenplan-light-portrait.png` | Stundenplan der Woche mit Hinweis „Kurztest“ (statt Lernkalender) |
| 3 | `03-modul-erledigt-light-portrait.png` | Modul: erkannte Klausur, Abgabe, Woche mit Erledigt-Haken |
| 4 | `04-uni-mail-ki-light-portrait.png` | Uni-Mail-Entwurf mit Vorschlag der KI |
| 5 | `05-ki-hilfe-light-portrait.png` | KI-Hilfe erklärt eine Vorlesung |
| 6 | `06-studienverlauf-light-portrait.png` | Studienverlauf: Leistungspunkte, Bereiche, Prüfungsanmeldung |
| 7 | `07-mensa-light-portrait.png` | Mensa |

Bild 4 und 5 zeigen die KI (Pro AI). Am iPhone gibt es keinen Editor; Dokumente öffnen dort in der Leseansicht.

### Satz für 1.0.4: iPad 13" (überholt)

Für die Einreichung von 1.0.4 am 14.11.2026 waren beide Sätze hochgeladen: 10 iPad-Bilder und
7 iPhone-Bilder, alle COMPLETE. Die neue Einreichung vom 15.11.2026 mit Build 42 nutzt dieselben Texte und Bilder
unverändert. 1.0.5 ebenso; sie stehen bis zum Hochladen von 1.0.6 im Store.

**Satz vom 13.11.2026 für 1.0.4** (aufgenommen mit dem Stand von Build 39, unverändert für die Einreichung mit
Build 42) unter `~/Studora-Builds/appstore-screenshots-final-2026-11-13/`: genau
zehn Bilder im Hochformat, je Motiv eine Fassung hell oder dunkel. Er zeigt den heutigen Stand – aufgeräumte Startseite
mit Kennzahl-Zeile, Knopf „Im QIS zur Prüfung anmelden“, Kopfzeile des Editors mit Reitern und die Stift-Leiste in
einer Zeile. Tobi hat den Tarif Pro AI (Seitenleiste „Pro AI“, kein „Pro AI holen“), die KI antwortet als StudiNow-KI
mit Credits, nirgends ChatGPT, keine Hochschule außer der LUH. Die Sätze vom 07.11.2026
(`appstore-screenshots-final-2026-11-07/`, Version 1.0) und vom Vormittag (`appstore-screenshots-final/`) sind überholt.
Erzeugen und Prüfung: `docs/release/SCREENSHOTS.md`, Abschnitt „Endgültiger Satz“. Hochladen (iPad 13"-Display,
Deutsch) in dieser Reihenfolge:

| Nr. | Datei | Motiv |
|---|---|---|
| 1 | 01-uebersicht-light.png | Übersicht „Hallo Tobi“ mit Prüfungsanmeldung |
| 2 | 02-ki-frage-dark.png | Skript mit KI-Hilfe: Frage zur Seite und Antwort der StudiNow-KI (Credits) |
| 3 | 03-ki-karteikarten-light.png | Karteikarten, von der KI aus dem Skript erstellt, eine Karte aufgedeckt |
| 4 | 04-community-diskussion-dark.png | Community des Moduls, Diskussion: Frage mit drei Antworten unter Pseudonym |
| 5 | 05-uni-mail-light.png | Uni-Mail: Posteingang und geöffnete Mail |
| 6 | 06-stundenplan-termin-light.png | Stundenplan mit Termin-Detail (Raum mit Route, Lehrende mit E-Mail) |
| 7 | 07-skript-uebung-stift-dark.png | Skript und Übungsblatt nebeneinander mit Apple-Pencil-Notizen |
| 8 | 08-wochentest-ki-dark.png | Wochentest mit Auswertung der KI |
| 9 | 09-raumfinder-light.png | Raumfinder mit Google Maps und Route |
| 10 | 10-mensa-light.png | Mensa |

### Satz für 1.0.4: iPhone 6,9" (überholt)

**Satz vom 14.11.2026 für 1.0.4** (aufgenommen mit dem Stand von Build 41, unverändert für die Einreichung mit
Build 42) unter `~/Studora-Builds/appstore-screenshots-iphone-2026-11-14/`: sieben
Motive, je eine helle und eine dunkle Fassung (`<nn>-<name>-{light|dark}-portrait.png`), jedes Bild 1320 × 2868. Für den
Store sind die **hellen sieben** in dieser Reihenfolge hochgeladen (iPhone 6,9"-Display, Deutsch; 14.11.2026); die
dunklen (`-dark-`) liegen als Alternative daneben. `tools/store_einreichen.py` zeigt auf diesen Ordner und diese
Reihenfolge. **Eigene Kontodaten des Inhabers, keine Daten Dritter:** aufgenommen mit den Daten des eigenen Kontos des
Inhabers (Entscheidung des Inhabers 14.11.2026), ohne Namen, ohne Matrikelnummer und ohne Daten Dritter. Überholt sind
der Satz vom 13.11.2026 (`appstore-screenshots-iphone-2026-11-13/`, vom Test `IPhoneStoreScreenshotTests` mit
erfundenen Demo-Inhalten erzeugt, Woche noch als Liste; `docs/release/SCREENSHOTS.md`, Abschnitt iPhone) und der Satz
vom 11.11.2026 (`appstore-screenshots-iphone-2026-11-11/`, acht Motive).

| Nr. | Datei (hell) | Motiv |
|---|---|---|
| 1 | 01-start-light-portrait.png | Startseite: nächste Klausuren, heute geplant |
| 2 | 02-lernkalender-light-portrait.png | Lernkalender, Woche als Raster Mo–So |
| 3 | 03-modul-light-portrait.png | Modul mit Woche und Erledigt-Haken |
| 4 | 04-uni-mail-ki-light-portrait.png | Uni-Mail-Entwurf mit Vorschlag der KI |
| 5 | 05-ki-hilfe-light-portrait.png | KI-Hilfe erklärt eine Vorlesung |
| 6 | 06-studienverlauf-light-portrait.png | Studienverlauf: kommende Semester bis zur Bachelorarbeit |
| 7 | 07-mensa-light-portrait.png | Mensa |

Bild 4 und 5 zeigen die KI: nur verwenden, solange StudiNow Pro AI mitverkauft wird (wie beim iPad). Am iPhone gibt es
keinen Editor; Dokumente öffnen dort in der Leseansicht.

### Ältere Sätze

Die Fassung nur mit Plus (ohne KI) liegt als Satz Build 11 unter `~/Studora-Builds/appstore-screenshots-v11/`; der
frühere Satz mit KI-Motiven unter `~/Studora-Builds/appstore-screenshots/` ist überholt (er nennt „über dein
ChatGPT“), nur dessen `reserve/13-tarife-light-portrait.png` bleibt der Prüf-Screenshot für Plus.
