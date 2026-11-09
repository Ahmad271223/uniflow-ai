# App Store Connect – Texte und Angaben (iPad, Mac „Designed for iPad“)

**Entwurf, Stand 07.11.2026 (26.10.2026), Sprache de-DE, für StudiNow 1.0 (Build 28; Build 25 ist seit 08.11. in der Prüfung, Build 27 nur auf dem Gerät des Inhabers).** Die Felder stehen in
`text`-Blöcken mit Feldnamen und sind **fertig zum Einfügen** (keine Platzhalter mehr, seit 06.11.2026 ohne die
Schalter aus `angaben.json`). `tests/test_release_texts.py` prüft Längen, Pflichtsätze und dass die Fassung ohne Pro AI
keine KI bewirbt. Zeichen inklusive Leerzeichen, gezählt wie App Store Connect (Unicode-Zeichen).

**1.0 nur LUH, 1.0.1 mit HsH und Hildesheim (Entscheidung des Inhabers 07.11.2026, 14:10):** Version 1.0 (Build 25)
wird nur mit der Leibniz Universität Hannover (Stud.IP, QIS) eingereicht. Hochschule Hannover (Moodle, HISinOne) und
Universität Hildesheim (Learnweb, LSF, PLuS) bleiben im Code, sind im Store-Build aber ausgeblendet (Build-Einstellung
`UF_SHIPPED_UNIVERSITIES` = `luh` in `apps/apple/project.yml`, Info.plist `UFShippedUniversities`, Kern
`UFReleaseUniversities`) und kommen 1–2 Tage später mit Update 1.0.1 – dann die Texte unten wieder um beide Hochschulen
ergänzen (Beschreibung, Schlüsselwörter „Moodle“, „Hildesheim“, Prüfhinweise „Connected today“, Website).

**1.0 wird mit Pro AI eingereicht (Entscheidung des Inhabers 07.11.2026, Dienst `app.studinow.app` läuft):** in App Store
Connect gehören `description-proai` und `review-notes-proai` hinein, dazu alle vier Abos (Plus und Pro AI, je monatlich und
jährlich). Die Fassungen „nur Plus“ bleiben nur als Rückfall stehen und sind **überholt – nicht verwenden**.

**Stand 07.11.2026 abends, neu in den Texten:** (1) Probe 7 Tage im Umfang von Pro AI, höchstens einmal je iPad (auch nach
Neuinstallation oder mit anderer Apple-ID); danach Bildschirm „Deine Probe ist vorbei“ (Free, Plus, Pro AI,
Monatlich/Jährlich), der sich erst mit einer Wahl schließt – „Bei Free bleiben“ ist eine gültige Wahl ohne Kauf
(`TrialBanner.swift`, `UFTrialDecision`; im Prüfhinweis für die Richtlinien 3.1.2/5.1.1 erklärt). (2) Erster Abgleich:
erst aktuelles Semester samt Stundenplan, dann die Frage „Auch frühere Semester laden?“ („Nur aktuelles Semester“ /
„Frühere Semester auch laden“, im Hintergrund, nur WLAN, `OlderSemestersViews.swift`); die Demo hat keine früheren
Semester (`DemoContent.install`, Semester leer), darum steht die Frage kurz im Prüfhinweis. (3) Eigener API-Schlüssel in
jedem Tarif für KI-Hilfe und KI-Lernplan (Karteikarten aus Unterlagen ab Plus, Wochentests ab Pro AI,
`OpenAIKeyCard.introText`); die Beschreibung nennt ihn ohne fremde Marke, der Prüfhinweis mit OpenAI. Der KI-Lernplan
ist in der Demo ohne geöffnete Dateien leer und wird darum im Prüfhinweis nicht als Schritt versprochen.

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
| Bildschirmfotos | Satz Build 11 ohne KI (`~/Studora-Builds/appstore-screenshots-v11/`, `docs/release/SCREENSHOTS.md`) | **endgültiger Satz mit Pro AI** (`~/Studora-Builds/appstore-screenshots-final-2026-11-07/`, Abschnitt Bildschirmfotos) |

Für 1.0 gilt die rechte Spalte (Plus und Pro AI).

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
Nachrichten (am Gerät mit echten Daten noch nicht bestätigt), Skriptsuche zur Aufgabe, iPhone.

## Name, Untertitel, Werbetext

Name 28 Zeichen (max. 30), Untertitel 30 (max. 30), Werbetext 155 (max. 170).

```text name
StudiNow – Studium & Notizen
```

```text subtitle
Skripte, Handschrift, Lernplan
```

```text promo
Skripte, Termine, Uni-Mail und Noten deiner Hochschule auf dem iPad – mit Apple Pencil, Lernkalender, Karteikarten und Speiseplan der Mensa. Ohne Tracking.
```

## Beschreibung (max. 4000 Zeichen)

### Fassung nur Plus – ÜBERHOLT, nicht verwenden (1.0 wird mit Pro AI eingereicht) – 3818 Zeichen

```text description
StudiNow bringt dein Studium an einen Ort: Unterlagen, Termine, Nachrichten, Uni-Mail und Noten deiner Hochschule, dazu Stundenplan, Lernkalender, Karteikarten und Handschrift mit dem Apple Pencil – auf dem iPad.

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
StudiNow Free ist dauerhaft kostenlos: Abgleich mit der Hochschule, Uni-Mail, Noten und Bescheinigungen, Lesen, Stundenplan, Lernkalender, Raumfinder und Mensa. Zum Start hast du 7 Tage Probe mit allem (einmal je iPad) – ohne Zahlungsdaten, danach wählst du: Free bleibt kostenlos, oder Plus. StudiNow Plus (1,99 €/Monat oder 21,99 €/Jahr) schaltet das Schreiben mit dem Apple Pencil, Übung und Skript nebeneinander, Karteikarten, den automatischen Lernplan und die Community deines Kurses frei. Das Abo verlängert sich automatisch um einen Monat bzw. ein Jahr, wenn es nicht spätestens 24 Stunden vor Ablauf in deinem Apple-Konto gekündigt wird. Nach dem Ende von Plus bleiben alle Notizen lesbar und exportierbar.

Nutzungsbedingungen: https://studinow.app/nutzungsbedingungen
Datenschutz: https://studinow.app/datenschutz

StudiNow ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.
```

### Fassung mit Pro AI – für 1.0 verwenden (Stand 07.11.2026 abends) – 3969 Zeichen

Dieselben Aussagen wie oben, dazu der Abschnitt „KI-HILFE MIT STUDINOW PRO AI“ und die Tarife mit Pro AI. Um unter
4000 Zeichen zu bleiben, sind Übersicht/Lernkalender und Dokumente/Lernen zusammengefasst. Keine fremden Marken
(ChatGPT, OpenAI) im öffentlichen Text.

```text description-proai
StudiNow bringt dein Studium an einen Ort: Unterlagen, Termine, Nachrichten, Uni-Mail und Noten deiner Hochschule, dazu Lernkalender, Karteikarten, Handschrift mit dem Apple Pencil und KI-Hilfe – auf dem iPad.

FÜR STUDIERENDE IN GANZ DEUTSCHLAND
Angebunden heute: Leibniz Universität Hannover (Stud.IP, QIS). Weitere Hochschulen folgen. Du meldest dich auf der Anmeldeseite deiner Hochschule an; StudiNow holt neue Skripte, Übungsblätter und Folien, ordnet sie nach Modulen und Lehrwochen – das aktuelle Semester zuerst, frühere auf Wunsch – und übernimmt deine Termine. In die Hochschulsysteme schreibt die App nur, wenn du es ausdrücklich auslöst.

DEINE UNI AN EINEM ORT
• Nachrichten aus Stud.IP beantworten, Übungen dort abgeben – erst nach deiner Bestätigung
• Uni-Mail und Uni-Kalender: lesen, antworten, weiterleiten, schreiben
• Notenspiegel und Bescheinigungen wie Immatrikulations- oder BAföG-Bescheinigung als PDF
• Lehrende mit E-Mail und Sprechstunde, Raumfinder mit Route zu Fuß
• Termin antippen: Raum mit Route, Lehrende, E-Mail an alle
• Studienverlauf mit Modulkatalogen von über 300 Studiengängen, Meldezeiträume der Prüfungsanmeldung mit Erinnerung
• Speiseplan deiner Mensa mit Preisen und Allergenen (Studentenwerk Hannover, Studierendenwerk OstNiedersachsen; ohne Gewähr)
• Übersicht für heute, Wochenraster, Lernkalender; mit Plus Lernplan automatisch in freien Zeitfenstern

LESEN, SCHREIBEN, LERNEN
• Bibliothek nach Modulen; PDFs lesen, durchsuchen, Lesezeichen setzen
• Mit Plus: Schreiben mit dem Apple Pencil – Stift, Marker, Radierer, Lasso, Lineal, Text und Formen; Notizen als PDF exportieren
• Mit Plus: Übung und Skript nebeneinander, eigene Karteikarten (Leitner-System) und die Community deines Kurses – Lösungen vergleichen, Fragen stellen, unter Pseudonym, mit Melden und Sperren

KI-HILFE MIT STUDINOW PRO AI
• Frag zur Seite, zu einer Markierung oder einem eingekreisten Bereich: erklären, zusammenfassen, Aufgabe lösen, Lösung prüfen
• Ganzes Dokument: „Ganze Vorlesung erklären“ oder „Alle Aufgaben erklären“ – ein Block je Abschnitt oder Aufgabe, mit Seitenangabe
• Wochentests und Karteikarten aus deinen Unterlagen, KI-Lernplan als Vorschlag
• Vor einem großen Lauf siehst du, was er kostet
Die KI ist freiwillig und braucht ein StudiNow-Konto (Anmelden mit Apple) – oder in jedem Tarif deinen eigenen API-Schlüssel (Einstellungen → Erweitert) für KI-Hilfe und KI-Lernplan. Nur was du ihr schickst, verlässt dein iPad. KI-Antworten können Fehler enthalten.

DEINE DATEN
• Dateien, Notizen und Pläne liegen auf deinem iPad. Kein Tracking, keine Werbung, keine Analyse-Werkzeuge Dritter.
• Dein Hochschul-Passwort gibst du nur auf der Anmeldeseite deiner Hochschule ein. Lässt du „Passwort auf diesem iPad merken“ an, liegt es nur im Schlüsselbund dieses iPads (nicht in iCloud) – abschaltbar, löschbar. An Server von StudiNow geht es nie.

STUDINOW FREE, PLUS UND PRO AI
StudiNow Free ist dauerhaft kostenlos: Abgleich mit der Hochschule, Uni-Mail, Noten, Lesen, Stundenplan, Lernkalender, Raumfinder und Mensa. Zum Start 7 Tage Probe mit allem aus Pro AI (einmal je iPad), ohne Zahlungsdaten; danach wählst du: Free bleibt kostenlos, oder Plus bzw. Pro AI. StudiNow Plus (1,99 €/Monat oder 21,99 €/Jahr): Apple Pencil, Übung und Skript nebeneinander, Karteikarten, automatischer Lernplan, Community. StudiNow Pro AI (3,99 €/Monat oder 41,99 €/Jahr): alles aus Plus, die StudiNow-KI mit 100 Credits im Monat und deine Notizen auf allen Geräten. Abos verlängern sich automatisch um einen Monat bzw. ein Jahr, wenn sie nicht spätestens 24 Stunden vor Ablauf in deinem Apple-Konto gekündigt werden. Danach bleiben alle Notizen lesbar und exportierbar.

Nutzungsbedingungen: https://studinow.app/nutzungsbedingungen
Datenschutz: https://studinow.app/datenschutz

StudiNow ist ein unabhängiges Angebot und nicht mit den Hochschulen verbunden. Verbindlich für Termine, Fristen und Noten sind immer die Systeme deiner Hochschule.
```

## Schlüsselwörter (max. 100 Zeichen, durch Komma getrennt) – 99 Zeichen

Wörter aus Name und Untertitel (StudiNow, Studium, Notizen, Skripte, Handschrift, Lernplan) indiziert Apple ohnehin;
sie stehen hier nicht noch einmal. Keine fremden Marken (z. B. ChatGPT) in Name, Untertitel oder Schlüsselwörtern
(Richtlinie 2.3.7). „Hannover“ deckt die LUH; „Uni“ steckt in „Uni-Mail“. 1.0 nur LUH (Entscheidung 07.11.2026): „Moodle“ und
„Hildesheim“ sind durch „Hochschule“ und „Noten“ ersetzt; mit 1.0.1 (HsH, Hildesheim) „Moodle“ und „Hildesheim“ wieder
aufnehmen (dann z. B. „Hochschule“ und „Noten“ weglassen, max. 100 Zeichen).

```text keywords
Stud.IP,Apple Pencil,Stundenplan,Lernkalender,Karteikarten,Uni-Mail,Mensa,Hannover,Hochschule,Noten
```

## Neue Funktionen in dieser Version (1.0) – 317 Zeichen

Bei der ersten Version zeigt der App Store dieses Feld nicht an; App Store Connect verlangt es bei 1.0 auch nicht. Für
1.0.1 ff. ersetzen. Passt zu beiden Fassungen.

```text whats-new
Erste Version von StudiNow für das iPad: Unterlagen, Termine, Nachrichten, Noten und Bescheinigungen aus deiner Hochschule, Uni-Mail und Uni-Kalender, Raumfinder mit Route, Stundenplan, Lernkalender und Mensa. Mit StudiNow Plus: Schreiben mit dem Apple Pencil, Übung und Skript nebeneinander, Karteikarten, Community.
```

## Weitere Angaben

| Feld | Wert |
|---|---|
| Plattform, Geräte | **nur die iOS-App** in App Store Connect (App-ID 6830632088); macOS nicht einreichen, der alte macOS-1.0-Entwurf bleibt liegen (Hinweis oben). iPad (iPadOS 17 oder neuer, `TARGETED_DEVICE_FAMILY` 2); Mac mit Apple-Chip über „Designed for iPad“ (Preise und Verfügbarkeit → „iPhone- und iPad-Apps auf Apple-Silicon-Macs“; am Mac noch nicht getestet, sonst abschalten); kein iPhone |
| Primäre Sprache | Deutsch |
| Kategorie | Bildung; zweite Kategorie: Produktivität |
| Support-URL | `https://studinow.app/support` (Kontakt per E-Mail support@studinow.app) |
| Marketing-URL | `https://studinow.app` (optional) |
| Datenschutz-URL | `https://studinow.app/datenschutz` |
| Nutzungsbedingungen (EULA) | eigene unter `https://studinow.app/nutzungsbedingungen` (App-Informationen → Lizenzvereinbarung) oder Apples Standard-EULA – Entscheidung des Inhabers; der Link steht in der Beschreibung und auf der Tarifseite der App |
| Copyright | © 2026 IT solutions by Ahmad Fakih |
| Händlerstatus (DSA) | Händler; Name, Anschrift, E-Mail wie im Impressum (IT solutions by Ahmad Fakih, Inhaber Ahmad Fakih, Baldurstraße 5, 30657 Hannover, support@studinow.app; werden im Store angezeigt); Telefonnummer verlangt Apple zusätzlich – vom Inhaber eintragen; die E-Mail beim Händlerstatus ändert der Inhaber selbst |
| Bundle-ID, SKU | `de.uniflow.ai` (`docs/RELEASE-VORBEREITUNG.md`); SKU frei wählbar, z. B. `studinow-ipad` |
| Version, Build | 1.0 (`MARKETING_VERSION`), **Build 28** (`CURRENT_PROJECT_VERSION`; Build 25 in der Prüfung, Build 26 nie hochgeladen); Build 5 bis 24 nicht einreichen; welcher Commit in welchem Build steckt: `docs/release/BUILD-HERKUNFT.md` |
| Mit Apple anmelden | Fähigkeit aktiv, an zwei Stellen: beim Start (trennt die Daten je Apple-Nutzer, bleibt auf dem Gerät) und freiwillig für das StudiNow-Konto (Einstellungen → Zugang & Darstellung → StudiNow-Konto; Token-Tausch beim Dienst). Konto löschen geht für beides in der App (Richtlinie 5.1.1(v)) |
| Exportkontrolle | `ITSAppUsesNonExemptEncryption = NO` steht schon in `project.yml` (nur Verschlüsselung des Betriebssystems: HTTPS über URLSession, AES-256-GCM und HKDF aus CryptoKit); App Store Connect fragt beim Build nicht nach |

## Altersfreigabe (Fragebogen in App Store Connect)

| Frage | Antwort | Begründung |
|---|---|---|
| Kindersicherung, Altersprüfung in der App | nein | – |
| Uneingeschränkter Webzugang | nein | Webansichten nur für die Anmeldeseiten der Hochschulen (bekannte Adressen); Links, Google Maps und Apple Karten öffnen außerhalb der App |
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

Frage „Erfassen Sie oder Ihre Drittanbieter Daten aus dieser App?“ → **Ja**.

| Datentyp | Erfasst | Mit Identität verknüpft | Für Tracking | Zweck | Was genau |
|---|---|---|---|---|---|
| Kontaktinformationen → E-Mail-Adresse | ja | ja | nein | App-Funktionalität | nur mit StudiNow-Konto: die Adresse, die Apple bei „Mit Apple anmelden“ übermittelt (ggf. Weiterleitungsadresse), bzw. die bei der Registrierung angegebene; Mitteilungen zum Konto |
| Kennungen → Nutzer-ID | ja | ja | nein | App-Funktionalität | Konto-ID und Apple-Kennung beim StudiNow-Dienst; CloudKit-Nutzerkennung (zufällig, nur für StudiNow) in jedem Community-, Wochentest- und Bibliotheks-Datensatz (Zurückziehen, Melden, Blockieren, Moderation) |
| Kennungen → Geräte-ID | ja | ja | nein | App-Funktionalität | nur mit StudiNow-Konto: zufällige Kennung dieser Installation (`ipad-<UUID>`, `StudoraAccountLink.deviceID`, keine Werbe- oder Hardware-Kennung) als `device_id` bei Anmeldung und Geräteabgleich; der Dienst führt sie bei der Sitzung (Geräteliste, andere Geräte abmelden). **Neu seit Audit P46-04 (08.11.2026), gilt ab Build 27; in App Store Connect vom Inhaber nachzutragen** |
| Käufe → Kaufverlauf | ja | ja | nein | App-Funktionalität | nur mit StudiNow-Konto: die von Apple signierte Transaktion (Produkt, Laufzeit, Transaktionskennung) geht an `/api/billing/apple/verify`, damit Tarif und Credits am Konto stimmen; keine Zahlungsdaten |
| Nutzerinhalte → Andere Nutzerinhalte | ja | ja | nein | App-Funktionalität | Community (Lösungen verschlüsselt, Fragen, Antworten, Kommentare, Meldungen; CloudKit bzw. mit Konto im Dienst); KI-Anfragen (Seitentext bzw. Bild eines Bereichs, Frage, Kurs- und Dateiname) an den Dienst und weiter an den KI-Anbieter; Geräteabgleich mit Konto (Module, Termine, Lernpakete, Karteikarten, Einstellungen; Notizen ab Pro AI) |
| Nutzungsdaten → Produktinteraktion | ja | ja | nein | App-Funktionalität | je KI-Anfrage Zeitpunkt, Art der Aufgabe und verbrauchte Credits (Abrechnung der Credits, Monatsgrenze) |
| Gesundheit und Fitness, Finanzinformationen, Standort, sensible Daten, Kontakte, Browserverlauf, Suchverlauf, Diagnose, Name, sonstige Daten | nein | – | – | – | – |

Warum so:

- **Hochschul-Passwörter werden nicht erfasst.** Die App merkt sich Benutzername und Passwort der Hochschule nur, wenn
  der Schalter „Passwort auf diesem iPad merken“ an ist (voreingestellt an, jederzeit abschaltbar), und nur im
  Schlüsselbund dieses iPads (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false`:
  nicht in iCloud, nicht im Backup). Das Passwort geht nur an die Anmeldeseiten der Hochschule, nie an StudiNow-Server;
  der Dienst speichert keine Hochschul-Passwörter (seit 06.11.2026, `DATENSCHUTZ.md` Abschnitt 6). Es verlässt das
  Gerät also nicht in unsere Richtung – keine Erfassung im Sinne Apples.
- **Mit Apple anmelden beim Start** bleibt auf dem iPad (Kennung, Name, E-Mail im Schlüsselbund). Erst die freiwillige
  Anmeldung beim **StudiNow-Konto** schickt Apples Identitäts-Token an den Dienst – daher E-Mail-Adresse und Nutzer-ID.
  Den Namen übermittelt die App dabei nicht.
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
zusätzlich 7 Tage Probe mit 25 Credits für die StudiNow-KI. Vier automatisch verlängerbare Abos in der Abo-Gruppe
„StudiNow“ (je Tarif monatlich und jährlich, Jahresabos unten):

| Feld | StudiNow Plus | StudiNow Pro AI |
|---|---|---|
| Produkt-ID | `de.uniflow.plus.monthly` (die Kennung bleibt bei `de.uniflow`, Bundle-ID `de.uniflow.ai`) | `de.uniflow.proai.monthly` |
| Abo-Gruppe / Stufe | StudiNow / Stufe 2 | StudiNow / Stufe 1 (höchste) |
| Referenzname | StudiNow Plus (monatlich) | StudiNow Pro AI (monatlich) |
| Anzeigename (max. 30) | StudiNow Plus | StudiNow Pro AI |
| Beschreibung (max. 45) | Stift, Karteikarten, Community, Lösungen | Alles aus Plus und die StudiNow-KI |
| Preis | 1,99 € pro Monat | 3,99 € pro Monat |
| Einführungsangebot | keins | keins |
| Einreichen | **mit der ersten App-Version** (Version → In-App-Käufe und Abonnements → Produkt auswählen) | **mit der ersten App-Version** (Entscheidung 07.11.2026, Dienst läuft) |
| Prüf-Screenshot | Tarifseite mit allen drei Karten: `~/Studora-Builds/appstore-pruefung/tarif-portrait.png` (bzw. `tarif-landscape.png`; `StoreScreenshotFinalTests.testTarifPruefung`, Stand 07.11.2026) | dasselbe Bild (Pro-AI-Karte mit 3,99 €, KI-Funktionen und Konto-Hinweis) |
| Prüfhinweis zum Abo | „Plus unlocks writing with Apple Pencil, exercise and script side by side, flashcards, the course community (read and post) and sharing own solutions; StudiNow Free has no community. Buy and restore on the plan page: Einstellungen → Zugang & Darstellung → Tarif → Tarif wechseln.“ | „Pro AI includes everything in Plus plus the StudiNow AI (100 credits per month) and note sync between devices. The AI runs on our service and needs a StudiNow account: Einstellungen → Zugang & Darstellung → StudiNow-Konto → Mit Apple anmelden. Then open a PDF and use KI-Hilfe.“ |

**Jahresabos (Entscheidung des Inhabers vom 07.11.2026, ab Build 16):** zwei weitere Abos in **derselben** Gruppe
„StudiNow“, jeweils auf **derselben Stufe** wie das Monatsabo des Tarifs (dann wechselt Apple die Zahlweise zur
nächsten Verlängerung, kein Doppel-Abo). Die Tarifseite zeigt oben „Monatlich · Jährlich“, sobald StoreKit ein
Jahresabo liefert; Monatsbetrag und Ersparnis rechnet die App aus den Store-Preisen.

| Feld | StudiNow Plus jährlich | StudiNow Pro AI jährlich |
|---|---|---|
| Produkt-ID | `de.uniflow.plus.yearly` | `de.uniflow.proai.yearly` |
| Abo-Gruppe / Stufe | StudiNow / Stufe 2 (wie Plus monatlich) | StudiNow / Stufe 1 (wie Pro AI monatlich) |
| Referenzname | StudiNow Plus (jährlich) | StudiNow Pro AI (jährlich) |
| Dauer | 1 Jahr | 1 Jahr |
| Anzeigename (max. 30) | StudiNow Plus | StudiNow Pro AI |
| Beschreibung (max. 45) | Stift, Karteikarten, Community, Lösungen | Alles aus Plus und die StudiNow-KI |
| Preis | 21,99 € pro Jahr (statt 23,88 € bei 12 × 1,99 €, gut 7 % günstiger) | 41,99 € pro Jahr (statt 47,88 €, gut 12 % günstiger) |
| Einführungsangebot | keins | keins |
| Einreichen | mit Version 1.0, zusammen mit den Monatsabos | mit Version 1.0, zusammen mit den Monatsabos |
| Prüf-Screenshot | `~/Studora-Builds/appstore-pruefung/tarif-jahr-portrait.png` (`StoreScreenshotFinalTests.testTarifPruefungJahr`) | dasselbe Bild |
| Prüfhinweis zum Abo | „Same features as StudiNow Plus (monthly), billed yearly. On the plan page choose ‚Jährlich‘ above the cards.“ | „Same features as StudiNow Pro AI (monthly), billed yearly; 100 AI credits per calendar month. On the plan page choose ‚Jährlich‘ above the cards.“ |

Die KI-Credits gelten auch beim Jahresabo je Kalendermonat (100 Credits, `credit_months` im Dienst).

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
Monatlich/Jährlich), nicht wegzuwischen; „Bei Free bleiben“ ist eine gültige Wahl ohne Kauf, wird je Apple-ID gemerkt und
kommt danach nicht wieder (`UFTrialDecision`). Während der Probe steht auf der Tarifseite „Probe aktiv: alle Funktionen von StudiNow Pro AI bis
… (noch n Tage)“, keine Karte trägt „Aktueller Tarif“, die Pro-AI-Karte trägt „Probe“. Stärker wäre später Apple
DeviceCheck (übersteht das Zurücksetzen des Geräts, braucht einen Schlüssel und eine Abfrage im StudiNow-Dienst).

Kaufprüfung: Der Tarif auf dem iPad entsteht immer aus StoreKit 2 auf dem Gerät; ein Fehler des Dienstes sperrt nie
einen Kauf. Ist ein StudiNow-Konto angemeldet, kauft die App mit `appAccountToken` (Kennung des Kontos) und meldet die
signierte Transaktion nach Kauf, Verlängerung und einmal je Anmeldung an `POST /api/billing/apple/verify`
(`UFBillingServiceLink`); erst damit kennt der Dienst Pro AI und gibt Credits. Ohne Konto geht keine Kaufmeldung hinaus.

**TestFlight (Beta „LUH-Tester“, 08.11.2026):** Käufe in TestFlight laufen in Apples Sandbox (kein Geld; Monatsabo =
5 Minuten, höchstens 12 Verlängerungen). Der Dienst nimmt Sandbox-Transaktionen an, kennzeichnet sie (`environment`) und gibt
dieselben 100 Credits wie bei echten Pro-AI-Abos; Einladungstext, Tester-FAQ und Ablaufplan in `TESTFLIGHT-500-2026-11-08.md`.

Pflichttexte auf der Tarifseite in der App: Preis und Laufzeit, automatische Verlängerung, Kündigung in den
Einstellungen, Links zu Nutzungsbedingungen und Datenschutzerklärung, „Käufe wiederherstellen“.

## Hinweise für die App-Prüfung (Review Notes)

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
Bedrock Frankfurt, Link zur Datenschutzerklärung) und senden ohne „Zustimmen und fortfahren“ nichts (zentral in
`StudiNowAI.json` bzw. `app/ai_consent.py`, je Konto, widerrufbar unter „KI-Einwilligung widerrufen“).

### Fassung nur Plus – ÜBERHOLT, nicht verwenden (1.0 wird mit Pro AI eingereicht) – 3972 Zeichen

```text review-notes
StudiNow is a study app for students in Germany. Connected today: Leibniz Universität Hannover. Its university features (files, timetable, messages, mail, grades) need the student's personal university account, which we cannot share. Please use the built-in demo content (no university account needed):

1. Tap "Mit Apple anmelden" (Sign in with Apple). It keeps the data of each Apple account and each university strictly separate on the device; it sends nothing to our servers.
2. Choose a plan ("StudiNow Free" is enough) and the university "Leibniz Universität Hannover" (the only one offered in this version). A 7-day trial with everything unlocked starts automatically, no purchase or payment details (once per iPad). Afterwards "Deine Probe ist vorbei" asks for a choice; "Bei Free bleiben" needs no purchase.
3. On the university login page tap the small text link "Ohne Hochschulkonto ansehen (Demo)" at the very bottom, below "Später anmelden". This creates a demo module with three PDFs, timetable, study calendar, five flashcards, a deadline and an announcement (all invented by us). Demo mode never contacts the university.
While the demo is active, a slim bar "Demo-Inhalte – erfunden, ohne Hochschule" is shown at the top. Tap "Beenden" in that bar and confirm: all demo content is removed.

University password: below each university login page, the switch "Passwort auf diesem iPad merken" (on by default, can be turned off) stores the university user name and password only in this iPad's Keychain (this device only, not synced to iCloud) to sign in again when a session expires. It is never sent to our servers. Delete it under "Einstellungen" → "Zugang & Darstellung" → "Automatisch anmelden"; signing out also deletes it.

Subscriptions: "StudiNow Plus" (monthly or yearly: switch "Monatlich · Jährlich" above the cards; no introductory offers) can be tested in the sandbox on the plan page ("Einstellungen" → "Zugang & Darstellung" → "Tarif" → "Tarif wechseln"), including "Käufe wiederherstellen". Plus unlocks writing with Apple Pencil, exercise and script side by side, flashcards, the course community and sharing own solutions. The trial is the app's own, not an App Store offer. After Plus ends, all notes stay readable and exportable. Terms: https://studinow.app/nutzungsbedingungen, privacy: https://studinow.app/datenschutz.

AI: the build contains AI help ("KI-Hilfe" in the editor, "KI-Start"). It is answered by our own service (https://app.studinow.app) and belongs to the plan "StudiNow Pro AI", which is not part of this submission; the plan page shows "StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden." without price or buy button. To try it anyway: "Einstellungen" → "Zugang & Darstellung" → "StudiNow-Konto" → "Mit Apple anmelden" creates a StudiNow account with a 7-day trial of 25 AI credits. Without account or plan the AI places explain this and send nothing; nothing is sent before "Zustimmen und fortfahren" in the notice "KI-Hilfe: Was wird gesendet?". Own OpenAI key ("Einstellungen" → "Erweitert" → "Eigenes ChatGPT", every plan): after the notice and ticking "Ich stimme zu …", the same content goes directly from the iPad to OpenAI on the user's own key; no ChatGPT login exists in the build.

Account deletion: "Einstellungen" → "Zugang & Darstellung" → "Konto löschen" (device); the "StudiNow-Konto" card has its own "Konto löschen" (online account).

Community (guideline 1.2): students of a course share notes on an exercise sheet, ask questions and comment, under a pseudonym; content is encrypted in our public CloudKit database (or our service with a StudiNow account). Every post can be reported ("Melden") and its author blocked ("Blockieren"). We review reports within 24 hours, remove content and ban users. Contact: support@studinow.app. Needs Plus or the trial.

No tracking, no ads, no third-party analytics. Not endorsed by universities; it writes to them only on explicit user action.
```

### Fassung mit Pro AI – für 1.0 verwenden (Stand 07.11.2026 abends) – 3994 Zeichen (max. 4000)

```text review-notes-proai
StudiNow is a study app for students in Germany. Connected today: Leibniz Universität Hannover. University features (files, timetable, mail, grades) need a personal university account. Please use the built-in demo instead:

1. Tap "Mit Apple anmelden" (Sign in with Apple). It separates data per Apple account on the device and sends nothing to our servers.
2. Choose a plan ("StudiNow Free" is enough) and "Leibniz Universität Hannover" (the only university in this version). A 7-day trial at Pro AI level starts automatically, no purchase or payment details, once per iPad (also after reinstalling or with another Apple ID).
3. On the university login page tap the small link "Ohne Hochschulkonto ansehen (Demo)" at the very bottom, below "Später anmelden". It adds an invented module with three PDFs, timetable, study calendar, flashcards, a deadline and an announcement. Demo mode never contacts the university.
A slim bar "Demo-Inhalte – erfunden, ohne Hochschule" marks the demo; "Beenden" there removes all demo content.

After the trial: a screen "Deine Probe ist vorbei" shows Free, Plus and Pro AI (monthly/yearly) and closes only after a choice. "Bei Free bleiben" is a valid choice without any purchase: Free stays usable at no cost, nothing is lost.

With a real account the first sync loads the current semester and timetable, then asks "Auch frühere Semester laden?" (background, Wi-Fi only). Not visible in the demo, which has no older semesters.

University password: the switch "Passwort auf diesem iPad merken" (on by default) keeps it only in this iPad's Keychain (not synced to iCloud) for later sign-ins; it is never sent to our servers. Delete: "Einstellungen" → "Zugang & Darstellung" → "Automatisch anmelden".

Subscriptions (switch "Monatlich · Jährlich" above the cards; no introductory offers), plan page "Einstellungen" → "Zugang & Darstellung" → "Tarif" → "Tarif wechseln", with "Käufe wiederherstellen":
- "StudiNow Plus": Apple Pencil, exercise and script side by side, flashcards, automatic study plan, course community.
- "StudiNow Pro AI": everything in Plus, the StudiNow AI with 100 credits per month, note sync between devices.
Terms: https://studinow.app/nutzungsbedingungen, privacy: https://studinow.app/datenschutz.

AI (Pro AI) runs on our own service (https://app.studinow.app) and needs a StudiNow account. Test:
1. Buy "StudiNow Pro AI" in the sandbox (or skip it: a new StudiNow account has a 7-day trial with 25 credits).
2. "Einstellungen" → "Zugang & Darstellung" → "StudiNow-Konto" → "Mit Apple anmelden". Our service then verifies the signed transaction and assigns the plan.
3. Open a demo PDF, tap "KI-Hilfe" and ask about the page, or choose "Ganzes Dokument" → "Ganze Vorlesung erklären".
The first AI request shows "KI-Hilfe: Was wird gesendet?": page text (or image of a circled area), question, course and file name go via our service to OpenAI or Claude (Amazon Bedrock, Frankfurt), privacy policy section 8c; never name, e-mail or university credentials. Nothing is sent before "Zustimmen und fortfahren". Own OpenAI key ("Einstellungen" → "Erweitert" → "Eigenes ChatGPT", every plan for AI help and AI study plan; flashcards from a document need Plus, weekly tests Pro AI): after the notice and ticking "Ich stimme zu …", the same content goes directly from the iPad to OpenAI on the user's own key; no ChatGPT login exists in the build.

Account deletion: "Einstellungen" → "Zugang & Darstellung" → "Konto löschen" (device); the "StudiNow-Konto" card has its own "Konto löschen" (online).

Community (guideline 1.2): course members share notes on exercise sheets, ask and comment under a pseudonym (encrypted; CloudKit or our service). Every post can be reported ("Melden") and its author blocked ("Blockieren"). We review reports within 24 hours, remove content and ban users. Contact: support@studinow.app.

No tracking, no ads, no third-party analytics. Not endorsed by universities; writes to them only on explicit user action.
```

## Bildschirmfotos (iPad Pro 13", 2064 × 2752)

**Endgültiger Satz mit Pro AI** (Version 1.0, Build 16; Entscheidung des Inhabers 07.11.2026: Pro AI wird mit
eingereicht) unter `~/Studora-Builds/appstore-screenshots-final-2026-11-07/` (Stand der App vom 07.11.2026 nachmittags:
flacher KI-Hilfe-Kopf, „Neue Mails prüfen“, nur LUH; der Satz vom Vormittag unter `appstore-screenshots-final/` ist
überholt): genau zehn Bilder im Hochformat, je Motiv eine
Fassung hell oder dunkel, ohne eingebrannte Beschriftung. Tobi hat den Tarif Pro AI (Seitenleiste „Pro AI“, kein
„Pro AI holen“), die KI antwortet als StudiNow-KI mit Credits, nirgends ChatGPT, keine Hochschule außer der LUH.
Erzeugen und Prüfung:
`docs/release/SCREENSHOTS.md`, Abschnitt „Endgültiger Satz“. Hochladen (iPad 13"-Display, Deutsch) in dieser
Reihenfolge:

| Nr. | Datei | Motiv |
|---|---|---|
| 1 | `01-uebersicht-light.png` | Übersicht „Hallo Tobi“ mit Prüfungsanmeldung |
| 2 | `02-ki-frage-dark.png` | Skript mit KI-Hilfe: Frage zur Seite und Antwort der StudiNow-KI (Credits) |
| 3 | `03-ki-karteikarten-light.png` | Karteikarten, von der KI aus dem Skript erstellt, eine Karte aufgedeckt |
| 4 | `04-community-diskussion-dark.png` | Community des Moduls, Diskussion: Frage mit drei Antworten unter Pseudonym |
| 5 | `05-uni-mail-light.png` | Uni-Mail: Posteingang und geöffnete Mail |
| 6 | `06-stundenplan-termin-light.png` | Stundenplan mit Termin-Detail (Raum mit Route, Lehrende mit E-Mail) |
| 7 | `07-skript-uebung-stift-dark.png` | Skript und Übungsblatt nebeneinander mit Apple-Pencil-Notizen |
| 8 | `08-wochentest-ki-dark.png` | Wochentest mit Auswertung der KI |
| 9 | `09-raumfinder-light.png` | Raumfinder mit Google Maps und Route |
| 10 | `10-mensa-light.png` | Mensa |

Die Fassung nur mit Plus (ohne KI) liegt als Satz Build 11 unter `~/Studora-Builds/appstore-screenshots-v11/`; der
frühere Satz mit KI-Motiven unter `~/Studora-Builds/appstore-screenshots/` ist überholt (er nennt „über dein
ChatGPT“), nur dessen `reserve/13-tarife-light-portrait.png` bleibt der Prüf-Screenshot für Plus. Nur echte
App-Inhalte mit erfundenen Daten, keine Uni-Logos, keine echten Namen oder Noten.

