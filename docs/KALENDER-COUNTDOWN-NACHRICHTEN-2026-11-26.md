# Termine im Kalender, Countdown, Widget „Nachrichten“ (26.11.2026)

Auftrag des Inhabers vom 26.11.2026 nach dem Vergleich mit der freien Stud.IP-App eines LUH-Studenten (MIT): „mach das
alles bei uns besser als bei denen, viel besser und genauer“. Übernommen sind nur die drei Ideen – kein Code, kein
Name, kein Logo.

- Zweig: `app/kalender-countdown-nachrichten` (Ordner `~/Studora-Builds/wt-kalender-countdown`), abgezweigt von
  `release/1.0.8-alles` @ 75ddc104. Lokal committet, **nicht gepusht**, in **keinem** Build.
- Ziel: der Build **nach** 1.0.8 (Build 50). Nichts davon ist in Build 50.

## 1. Termine im Kalender

**Was es tut.** Einstellungen → Uni-Zugang & Abgleich → Karte „Termine im Kalender“. Schalter „In die Kalender-App
eintragen“ (von selbst **aus**). Erst dieser Schalter fragt iOS nach der Erlaubnis. StudiNow legt einen eigenen
Kalender **„StudiNow“** an und hält ihn aktuell.

- **Quelle:** genau der Stundenplan, wie er in der App steht (`GET /api/timetable/week`): Stud.IP, LSF/Campus-
  management, eigene Termine, eigene Änderungen, Verlegungen, eigene Ausfälle, vorlesungsfreie Tage. Dazu wahlweise
  Abgaben/Tests/Fristen (Feld `deadlines` derselben Antwort) und Klausuren/Prüfungen (`GET /api/exams/upcoming`).
- **Im Eintrag:** Titel, Zeit (Europe/Berlin), Raum als Ort, in den Notizen Art (Vorlesung, Übung …), Modul,
  Lehrende, Sitzungsthema, eigene Notiz, „Verlegt vom 26.11.“, Hinweis „fällt vielleicht aus“ aus Ankündigungen, und
  als Adresse ein Link zurück in die App (`uniflow://#/timetable?date=…`, Prüfungen `#/exams`).
- **Zeitraum wählbar:** 2 Wochen, 4 Wochen, 8 Wochen, **ganzes Semester** (Vorgabe; bis Semesterende, mindestens 2
  Wochen, höchstens 200 Tage; ohne bekanntes Semesterende 8 Wochen).
- **Schalter im Einzelnen:** Abgaben und Fristen · Klausuren und Prüfungen · Ausfälle als „Fällt aus“ zeigen ·
  Feiertage und vorlesungsfreie Zeit (alle von selbst an, sobald der Abgleich an ist).

**Genau abgleichen statt neu anlegen** (`CalendarExportPlan`, `EventKitCalendarStore`):

- Jedes Ereignis trägt eine feste Kennung in seiner Adresse (`…&sn=<Kennung>`): Serie + Tag (`e12@2026-11-26`),
  Stud.IP-Einzeltermin (`s<Quelle>|<id>`), Abgabe (`d…`), Prüfung (`x…`), Feiertag/Pause (`h<Art>|<Name>|<Nr>`).
- Geändertes wird geändert, Entfallenes entfernt, Doppeltes gelöscht (z. B. nach einem abgebrochenen Lauf).
  Unveränderte Einträge werden **nicht** neu geschrieben.
- **Verlegt:** behält die Kennung seines ursprünglichen Tages – der Eintrag wandert, statt gelöscht und neu angelegt.
- **Ausfälle:** Ausfälle laut Stud.IP blendet die App aus (Entscheidung des Inhabers 28.10.2026) – im Kalender fehlen
  sie deshalb auch. Selbst markierte Ausfälle (in der App durchgestrichen) stehen als „Fällt aus: …“ (als „frei“, wo der
  Kalender das kennt), oder fehlen, wenn der Schalter aus ist. Nicht besuchte Termine fehlen.
- **Feiertage/vorlesungsfreie Zeit:** aufeinanderfolgende Tage als **ein** ganztägiger Eintrag; läuft die Zeit schon
  seit vor heute, behält der Eintrag seinen Beginn.
- **Nie angefasst:** Ereignisse ohne StudiNow-Kennung (auch nicht, wenn sie jemand in den Kalender „StudiNow“
  einträgt), alle anderen Kalender, alles Vergangene.
- **Wann:** nach jedem Stud.IP-Abgleich, beim Öffnen der App (höchstens alle 10 Minuten), beim Wechsel in den
  Hintergrund (eigene Änderungen am Stundenplan), beim Wechsel der Hochschule/des Kontos, bei jeder Änderung einer
  Einstellung. Mit Demo-Inhalten passiert nichts (erfundene Termine gehören nicht in den echten Kalender).
  Abgemeldet: die künftigen Einträge werden entfernt.
- **Abschalten** fragt nach und entfernt den Kalender „StudiNow“ ganz.
- **In der Kalender-App gelöscht:** StudiNow legt ihn nicht ungefragt neu an, sondern schaltet den Abgleich aus und
  sagt es in der Karte.
- **Wo:** dort, wo die Kalender-App neue Termine anlegt (meist iCloud), sonst iCloud/andere CalDAV-Konten, zuletzt
  „Auf meinem iPhone/iPad“; scheitert das Anlegen an einer Stelle, die nächste. In iCloud nutzen mehrere Geräte
  denselben Kalender „StudiNow“ (gleiche Kennungen, also nichts doppelt). Vorher stand hier „lokal zuerst“ – geändert
  nach dem Codevergleich, weil die Kalender-App lokale Kalender bei eingeschaltetem iCloud-Kalender oft gar nicht zeigt.

**Besser/genauer als das Vorbild:** dort ein Kalender mit den nächsten 8 Wochen, höchstens einmal am Tag abgeglichen.
Hier: Quelle ist der ganze Stundenplan der App (mit eigenen Terminen, Änderungen, Verlegungen, Ausfällen, Feiertagen,
Abgaben, Prüfungen), Zeitraum wählbar bis zum Semesterende, Abgleich nach jedem Stundenplan-Abgleich und beim Öffnen,
feste Kennungen statt Neuanlage, Raum/Lehrende/Thema/Link in jedem Eintrag, fremde Einträge unberührt.

## 2. Countdown auf der Startseite

In der Karte „Heute an der Uni“ (keine neue Karte, Vorgabe vom 13.11.2026), iPhone, iPad und Mac:

- laufender Termin: **„läuft · noch 35 Min“** (über eine Stunde: „noch 1 Std 10 Min“);
- nächster Termin: **„in 25 Min“**, „in 2 Std 10 Min“, „beginnt jetzt“; beginnen zwei gleichzeitig, beide;
- nach dem letzten Termin des Tages unten: **„Als Nächstes: morgen 8:15 · Analysis I“** (sonst „Mo. 10:00“ bzw.
  „14.12. 10:00“); gibt es in der nächsten Woche nichts, verschwindet die Zeile ganz.
- Zählt nur besuchte Termine; Ausfälle, nicht besuchte und verlegte zählen nicht (nach einem Ausfall kommt der
  nächste stattfindende). Ausfälle laut Stud.IP sind ohnehin ausgeblendet. Raum aus dem Termin selbst (Raumänderungen
  stehen dort).
- Aktualisiert sich zu jeder vollen Minute ohne Neuladen (`TimelineView(.everyMinute)`), Minuten aufgerundet (um
  10:14 „in 1 Min“, um 10:15 „läuft“).
- VoiceOver liest ganze Sätze: „Läuft gerade, noch 35 Minuten“, „Beginnt in 25 Minuten“, „Nächster Termin morgen um
  8:15 Uhr: Analysis I“.
- iPad/Mac: kleines Feld vor dem Raum; iPhone: eigene Zeile unter dem Raum (bricht bei großer Schrift nicht ab).

Code: `UniFlow/Views/TerminCountdown.swift`, Karte herausgelöst nach `UniFlow/Views/DashboardEventsCard.swift`
(Inhalt und Aussehen sonst unverändert).

## 3. Widget „Nachrichten“

Neues drittes Widget neben „Nächster Termin“ und „Mensa heute“ (gleiche App-Gruppe `group.de.uniflow.ai`, gleicher
Schnappschuss `home-widget.json`, neues Feld `messages`; alte Schnappschüsse bleiben lesbar).

- **Größen:** klein, mittel; Sperrbildschirm rechteckig, rund (Zahl), Zeile („3 ungelesene Nachrichten“).
- **Inhalt:** Zahl der ungelesenen Stud.IP-Nachrichten (Uni Hildesheim: Learnweb, HsH: Moodle), wahlweise plus
  Uni-Mail (SOGo, wenn verbunden; Vorgabe an), und die neuesten ungelesenen Absender + Betreffe (mittel: 3, klein: 1).
- **„Ungelesen“ je Nachricht, nur in StudiNow** (Entscheidung des Inhabers 26.11.2026, `MessagesInbox.isUnread`):
  1. eigene Wahl in StudiNow zuerst: **Antippen einer Nachricht = gelesen**, im Leser „Als ungelesen markieren“ bzw.
     „Als gelesen markieren“, oben „Alle als gelesen“;
  2. sonst gilt alles bis zur früheren Marke „beim letzten Öffnen der Seite“ als gelesen (einmal beim Umstieg
     festgehalten, damit nach dem Update nicht alte Nachrichten plötzlich ungelesen sind);
  3. sonst der Stand in Stud.IP (`is-read`, neue Spalte `is_read`); bei Learnweb/Moodle unbekannt = ungelesen.
  Das **Öffnen der Seite allein setzt nichts mehr auf gelesen** (vorher stand danach überall 0). Im Querformat wird die
  erste Nachricht automatisch angezeigt, aber nicht als gelesen gezählt. Nach Stud.IP schreibt StudiNow **nichts** – im
  Browser bleiben Nachrichten, die man nur in StudiNow gelesen hat, ungelesen. Abzeichen „Nachrichten“, Punkte in der
  Liste und Widget folgen derselben Regel; gespeichert je Container (Konto und Hochschule).
- **Antippen:** öffnet „Nachrichten“ in der App; eine Uni-Mail-Zeile öffnet „Uni-Mail“; nur Uni-Mail ungelesen →
  „Uni-Mail“.
- **Datenschutz/Sperrbildschirm** (Karte „Widget „Nachrichten““ in den Einstellungen):
  - Home-Bildschirm: Absender und Betreff.
  - Sperrbildschirm: **nur Zahl und Absender**; Betreff nur mit dem Schalter „Betreff auf dem Sperrbildschirm“ (aus).
  - **Nie ein Nachrichtentext** ohne den Schalter „Anfang des Nachrichtentexts zeigen“ (aus). Ohne Schalter steht der
    Text gar nicht erst im Schnappschuss.
  - Betreff und Textanfang sind `privacySensitive` (iOS blendet sie bei gesperrtem Gerät aus, wo es das kann).
  - Absender von Stud.IP sind wie bisher Rollen („Lehrende“, „Stud.IP“), keine Personennamen.
- **Wann neu:** nach jedem Abgleich, beim Öffnen der Seite „Nachrichten“, nach Uni-Mail, beim Ändern der Schalter.

**Besser/genauer als das Vorbild:** dort nur die Zahl ungelesener Stud.IP-Nachrichten. Hier: Zahl plus Absender und
Betreff, Uni-Mail dazu, Sperrbildschirm-Größen, genaue Zählung (Stud.IP-Stand und App-Stand), Schutz des Inhalts auf
dem Sperrbildschirm, Antippen öffnet die richtige Seite.

## Vergleich mit dem Code des Vorbilds (26.11.2026, nachmittags)

Gelesen (nur gelesen, nichts übernommen): Kalender-Abgleich, Countdown, Widgets und Postfach der freien App (Stand
7.11.2026). Dort: Kalender über die nächsten 8 Wochen ab „jetzt“, abgeglichen beim Öffnen der Startseite, Kennung als
Prüfwert in der Adresse, Ausweichen auf andere Kalenderquellen, Abmelden entfernt den Kalender; Countdown in einer
eigenen Karte („läuft, noch 35 Min“, „in 3 Std“, „morgen“), alle 30 Sekunden neu; Widget „Ungelesene Nachrichten“ nur
als Zahl (klein, rund, Zeile).

**Daraus bei uns behoben:**
- Kalenderquelle wie oben (vorher „lokal zuerst“ – hätte bei iCloud-Nutzern unsichtbar sein können).
- Nach einem Abgleich im Hintergrund (App zu) wird jetzt auch der Kalender nachgezogen (vorher erst beim Öffnen).
- Nach einem Hintergrundlauf ohne offenes Fenster verschwand die Uni-Mail-Zahl aus dem Widget – jetzt bleibt der
  letzte Stand (`HomeWidgetSync.keepingMail`, Test).

**Wo das Vorbild weiter ist (nicht gebaut, Entscheidung des Inhabers):**
1. ~~Gelesen je Nachricht~~ – **entschieden und gebaut (26.11.2026): nur in StudiNow** (siehe Widget „Nachrichten“).
   Unterschied zum Vorbild bleibt: dort wird es auch in Stud.IP gesetzt, bei uns bewusst nicht.
2. **Erinnerung vor dem Termin** (Mitteilung z. B. 10 Minuten vor der Vorlesung, Wochenende ruhig) – haben wir nur für
   Abgaben und Prüfungen.
3. **Countdown an Tagen ohne Uni-Termin:** das Vorbild zeigt immer den nächsten Termin (eigene Karte). Bei uns gibt es an
   solchen Tagen keine Karte „Heute an der Uni“ und damit keinen Countdown (Vorgabe „keine neue Karte“).
4. **Schalter schon in der Einführung** (beim ersten Start) – bei uns nur in den Einstellungen.

## Getestet

- **App-Tests** `UniFlowTests/KalenderCountdownNachrichtenAppTests` (18 Tests) auf eigenem iPad-Simulator (iPad Pro
  11 M5, iOS 27.2, `D8CDB2DD-…`) grün, darunter **gegen den echten Kalender des Simulators** (anlegen, zweiter Lauf
  ändert nichts, ändern, entfernen, fremdes Ereignis bleibt, Abschalten entfernt den Kalender, gelöschter Kalender wird
  erkannt). Dieser Test fand einen echten Fehler: lokale Kalender kennen „frei/beschäftigt“ nicht und hätten bei jedem
  Abgleich alle Abgaben/Feiertage/Ausfälle neu geschrieben – behoben.
- Widget-Bilder aller Größen hell/dunkel und Countdown-Bilder (iPhone 402 pt, iPhone SE 375 pt, iPhone mit großer
  Schrift, iPad; 09:50, 11:10, 13:40, 18:00) in `~/Studora-Builds/kalender-countdown/widget-bilder/`.
- **Kern-Tests** (`swift test`, ganzes Paket): 1893 Tests, 0 Fehler; neu: `is-read` wird gespeichert, alte Tabelle ohne
  Spalte.
- **iPad-Simulator, weitere App-Tests** (196 Tests, 8 übersprungen wie immer, 0 Fehler): Quellen-Prüfungen
  (`AuditPaket353740`, `AuditPaket59bis77`, `AuditRunde0910`, `AuditRunde11`, `SheetGate`, `SheetNachHinweis`,
  `BackArrow`, `StudoraName`, `UniversityLoginPolicy`, `MacTestIsolation`, `DataSeparation`, `ViewTypeDepth`,
  `LayoutWidthAudit`), `EinstellungenKlar`, `EinstellungenBilder`, `StartseiteBilder`, `OhneLernkalender`,
  `WidgetSnapshot`, `Messages`.
- **iPhone-Simulator** (iPhone 17 Pro, iOS 27.2, `3881184D-…`): `KalenderCountdownNachrichtenAppTests` (mit echtem
  Kalender), `WidgetSnapshot`, `Messages`, `OhneLernkalender` – 54 Tests, 0 Fehler.
- Nach den Korrekturen aus dem Codevergleich: neue Tests, Widgets, Nachrichten und Quellen-Prüfungen (67 Tests) auf
  iPad- und iPhone-Simulator erneut grün.
- „Gelesen je Nachricht“ (26.11.2026 abends): Regeln, Ausgangsmarke, Seite (Antippen, „Als ungelesen markieren“,
  „Alle als gelesen“) plus Widgets, Nachrichten, Quellen-Prüfungen, Einstellungen und Breitenprüfung – 104 Tests je auf
  iPad- und iPhone-Simulator grün.
- Nicht gelaufen: die ganze App-Suite (rund 290 Testdateien) und die UI-Tests.
- Schon vorher so, nicht Teil dieses Auftrags: auf dem iPhone mit sehr großer Schrift bricht die Uhrzeitspalte in
  „Heute an der Uni“ um („10:“ / „15“), weil sie fest 44 pt breit ist.

## Nicht getestet

- **Am echten Gerät** (iPad/iPhone des Inhabers): nichts aufgespielt (braucht sein Okay). Besonders offen: wie iOS
  nach der Erlaubnis fragt (iOS 17+: „Vollzugriff“), iCloud-Fall ohne lokalen Kalender, Widget auf echtem
  Sperrbildschirm.
- **Mac** („Designed for iPad“): nicht gebaut/getestet (kein Mac-Lauf, solange die Build-50-Sitzung läuft). Offen,
  ob macOS den Kalenderzugriff einer iPad-App ohne zusätzliche Berechtigung erlaubt.
- Ein echtes Stud.IP-Konto mit `is-read`: das Feld ist im Geräte-Probelauf (`StudIPDeviceProbeTests`) schon gelesen
  worden, aber der neue Speicherweg lief noch nicht mit echten Daten.
- Bildschirmfotos aus der laufenden App im Simulator: die Freigabe zum Bedienen des Simulators kam nicht; die Bilder
  oben sind mit derselben Ansicht im Test gezeichnet.

## Was der Inhaber entscheiden muss

1. **Erlaubnistext** (Info.plist, steht in `project.yml`): „StudiNow trägt deinen Stundenplan, wenn du es in den
   Einstellungen einschaltest, in einen eigenen Kalender „StudiNow“ ein und hält ihn aktuell. Andere Kalender liest
   oder ändert StudiNow nicht. Nichts davon geht an einen Server.“ – so lassen? (`NSCalendarsFullAccessUsageDescription`
   und für ältere Systeme `NSCalendarsUsageDescription`.) Vollzugriff ist nötig: mit „Nur hinzufügen“ kann eine App
   keinen eigenen Kalender anlegen und nichts ändern oder entfernen. Apple prüft bei Vollzugriff genauer, ob die
   Begründung passt.
2. **Datenschutzerklärung (Website + Dienst):** neuer Absatz nötig (Vorschlag):
   „**Kalender und Widgets.** Schaltest du „Termine im Kalender“ ein, trägt StudiNow deinen Stundenplan (Titel, Zeit,
   Raum, Lehrende, Link in die App) in einen eigenen Kalender „StudiNow“ auf deinem Gerät ein. Liegt dein Kalender in
   iCloud, synchronisiert Apple ihn wie deine anderen Kalender. StudiNow liest nur diesen eigenen Kalender. Die Widgets
   zeigen Termine, Mensa und die Zahl ungelesener Nachrichten mit Absender und Betreff aus den Daten auf deinem Gerät;
   nichts davon geht an einen Server von StudiNow.“
3. **App-Datenschutz in App Store Connect / `PrivacyInfo.xcprivacy`:** keine neue Datenart (nichts verlässt das Gerät
   Richtung StudiNow; EventKit ist keine „Required Reason“-Schnittstelle). Hinweis: Der Kommentar im Manifest sagt noch
   „UserDefaults … keine App Group“ – seit den Widgets stimmt das nicht mehr (Text anpassen, keine neue Angabe nötig).
4. **Store-Text „Neu in dieser Version“** und ggf. ein Bild mit dem Kalender/Widget.
5. **Vorgaben ok?** Kalender aus; Zeitraum „Ganzes Semester“; Ausfälle als „Fällt aus“ sichtbar; Sperrbildschirm ohne
   Betreff; kein Nachrichtentext; Uni-Mail mitzählen an.
6. **App-Gruppe/Widget-ID im Apple-Konto** wie schon bei den Widgets (Build 47): nichts Neues, das Widget
   „Nachrichten“ steckt in derselben Erweiterung.

## Prüfläufe

Befehle (eigener Bauordner `~/Studora-Builds/dd-kalender`, eigene Simulatoren „Kalender-Countdown iPad“
`D8CDB2DD-24A0-450F-9423-08F6E5D7D6C9` und „Kalender-Countdown iPhone“ `3881184D-71C1-4C63-9BA4-5C33CB72726E`):

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/apple && xcodegen generate
xcrun simctl privacy <Simulator> grant calendar de.uniflow.ai     # sonst wird der Kalender-Test übersprungen
xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination id=<Simulator> -derivedDataPath ~/Studora-Builds/dd-kalender \
  -only-testing:UniFlowTests/KalenderCountdownNachrichtenAppTests
```

Ergebnisse: siehe „Getestet“ oben.
