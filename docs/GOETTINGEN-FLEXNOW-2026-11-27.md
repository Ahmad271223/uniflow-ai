# Uni Göttingen: angemeldete Prüfungen aus FlexNow 2 (Stand 27.11.2026)

Zweig `uni/goettingen-flexnow` (lokal, nicht gepusht), abgezweigt von `uni/goettingen` @ 7db2302e. Für ein Update
**nach** 1.0.8 / Build 51 (Build 51 ist eingefroren). Nichts in `release/1.0.8-alles` gemischt, nichts hochgeladen,
nichts aufs iPad gespielt.

## 1. Kurz

- StudiNow liest an der Uni Göttingen aus FlexNow 2 **nur „Aktuelles → Aktuelle Prüfungen“**: welche Prüfungen
  angemeldet sind und bis wann man sich abmelden kann. Nie an- oder abmelden, nie ein Formular abschicken, nie
  „erzeugen“ (Datenblätter), nie „Logout“.
- Anzeige: Karte **„Prüfungen (FlexNow)“** unter „Uni & Noten“ (ersetzt dort die Karte „Noten (FlexNow)“ mit nur einem
  Link). Je Prüfung: Titel, Art (z. B. „Prüfungsvorleistung“), Modul, „Abmeldung bis Do, 10.12.2026, 23:59 Uhr · noch
  13 Tage“ (ab 3 Tagen vorher gelb, am letzten Tag rot), Semester.
- Erinnerung: 7 und 2 Tage vor dem Ende der Abmeldefrist um 9:00 Uhr (Schalter „An das Ende der Abmeldefrist erinnern“
  in der Karte; derselbe Schalter und dieselbe Erlaubnis wie die Erinnerung an die Prüfungsanmeldung).
- **Noten bleiben „noch nicht dabei“**: das Testkonto hatte keine Noten, das Format einer Notenzeile ist nicht gesehen.
- Passwort: tippt nur der Nutzer auf der echten FlexNow-Seite. Mit „Passwort auf diesem iPad merken“ liegt es nur im
  Schlüsselbund des Geräts (derselbe Uni-Zugang wie für Stud.IP), nie auf einem Server.

## 2. Grundlage (echt gesehen, maskiert)

`~/Studora-Builds/goettingen/STRUKTUR-ECHT-FLEXNOW-2026-11-26.md`, Abschnitt „Zweiter Blick (27.11.2026)“ (Chrome des
Inhabers, er hat sich selbst angemeldet; nur gelesen):
- Anmeldung `https://flexnow2.uni-goettingen.de/` → `/FN2AUTH/login.jsp`, POST an `/FN2AUTH/FN2AuthServlet?op=…` mit
  `kennung`, `kennwort` (versteckt `emrexSessionId`, `emrexReUrl`), ohne zweiten Faktor. Danach `/FN2SSS/`.
- Jeder Menüpunkt lädt per `POST /FN2SSS/FrontControllerSS` ein HTML-Stück nach. **Was in der Anfrage steht, ist nicht
  gesehen.** Darum liest die App die fertige Seite in einer Webansicht, statt `FrontControllerSS` selbst zu fragen.
- „Aktuelle Prüfungen“: `ul.class-list` → `div.class-list-head` „Modul: <Kürzel>: <Titel>“ → li →
  `div.PrfContainerAktuelles` → „Prüfung: <Kürzel>.Prvor: <Titel> (Prüfungsvorleistung)“ → `div.prfangBlock.angemeldet`
  mit `div.info-inner` (p „WS##/##“, `span.titelBez` „– <PRÜFER>: An-/Abmeldung bis TT.MM.JJJJ, HH Uhr“, `span.fristBis`
  „TT.MM.JJJJ - TT.MM.JJJJ, HH:MM Uhr“ nach „Abmeldung möglich im Zeitraum:“). Kein Prüfungstermin bei der Vorleistung.

## 3. Was gebaut ist

### Kern (`UniFlowCore`)
- `UniLoginForms.goettingenFlexNow` (`Universities/UniAutoLogin.swift`): Rechner `flexnow2.uni-goettingen.de`, Pfad
  `/FN2AUTH/`, Felder `kennung`/`kennwort`. Nur auf diesem Rechner und Pfad liest die App beim Absenden mit bzw. füllt
  sie bei der stillen Neuanmeldung ein – **nicht** im gleichen Kasten auf `www.uni-goettingen.de`. Absende-Knopf und
  Fehlertext sind nicht gesehen: Knopf über das Formular (sonst `requestSubmit`); „abgelehnt“ nur mit Fehlertext, sonst
  „nicht gelungen“ ohne das Passwort zu löschen. Nicht in `UniFormLogin.allowedForms` (Hintergrund ohne Webansicht erst
  nach einem echten Test).
- `ExamRegistration/FlexNowRegistrations.swift`:
  - `FlexNowPage`: Adressen (`entry`, `start` = `/FN2SSS/`), `isSignedIn` (HTTPS, `/FN2SSS…`, kein Anmeldeformular).
  - `FlexNowParser.parse(html:)`: kleiner Baum aus `HTMLTokenizer`, liest je `div.PrfContainerAktuelles` das Modul
    davor, Kürzel, Titel, Art (auch geschachtelt „Klausur (90 Minuten)“) und je `div.prfangBlock` **mit Klasse
    `angemeldet`** Semester, Prüfer (nur auf dem Gerät, `pruefer` geht nicht in den Geräteabgleich), Abmeldefrist (Ende aus
    `span.fristBis`, sonst aus `span.titelBez`; „23 Uhr“ → „23:00 Uhr“). Andere Blöcke werden nur gezählt. Die versteckten
    Kennungen im Formular werden nie gelesen.
  - „Liste erreicht“ nur mit Prüfungsblöcken oder wenn der Abschnitt selbst „keine …“ sagt (nur Text im Abschnitt, nicht
    Fußzeile oder andere Kästen). Sonst (Seite noch am Nachladen, anderer Bereich offen) wird **nichts gespeichert und
    nichts gelöscht**.
  - `FlexNowRegistrationsSync.read(db:html:)`: speichert in dieselbe Tabelle `exam_registrations` wie die
    QIS-Anmeldungen (`QISRegistrationsSync.store`, Abgleich statt Ersetzen; Geräteabgleich wie bisher). Anmeldeseite →
    „Anmeldung nötig“, Zeilen bleiben.
- `ExamRegistrationAPI` (`GET /api/exam-registration`): an der Uni Göttingen `system: "FlexNow"`, die gelesenen Zeilen
  mit `module`, `form`, `withdraw_until`, `withdraw_time`, `withdraw_text`, **keine** Meldezeiträume, **keine** Vorschläge,
  `show_card: false` (also keine Karte „Prüfungsanmeldung“ auf der Übersicht und kein Block „Prüfung anmelden“ im Modul),
  `withdraw_reminders: true`.
- `ExamRegistrationReminders.planWithdraw`: je Fristtag eine Mitteilung „Abmeldefrist: noch 7 Tage“ bzw. „Abmeldefrist
  endet übermorgen“ (mehrere Prüfungen mit derselben Frist zusammen), Ziel „Uni & Noten“. Nur mit `withdraw_reminders`
  – LUH und Hildesheim bekommen nichts Neues.

### App
- `Services/FlexNowConnection.swift`: Verbindung je Göttinger Container (`ContainerManager.flexnow`, Umgebung
  `\.flexnow`). Lesen über `FlexNowWebReader`: unsichtbare, winzige Webansicht mit dem Datenspeicher des Containers lädt
  `/FN2SSS/`, wartet, bis „Aktuelle Prüfungen“ lesbar ist und sich eine Sekunde nicht mehr ändert (höchstens 25 s),
  liest `outerHTML`. Hauptrahmen nur HTTPS auf `*.uni-goettingen.de`. Abgelaufen → genau eine stille Anmeldung mit dem
  gemerkten Uni-Zugang (`UniAutoLogin.handleExpiry`, Portal „flexnow“, nur im Vordergrund), dann genau ein neues Lesen;
  ein abgelehntes Passwort wird nie wieder gesendet. Abmelden löscht nur die FlexNow-Cookies (Stud.IP bleibt), die
  gelesenen Prüfungen bleiben, danach keine stille Neuanmeldung bis zur nächsten eigenen Anmeldung.
- Von selbst liest die App nur beim Öffnen von „Uni & Noten“ und höchstens alle 6 Stunden; sonst auf Knopfdruck
  „Angemeldete Prüfungen lesen“. Kein Hintergrundlauf, kein Teil des Sync-Knopfs (bewusst klein gehalten).
- `Views/FlexNowViews.swift`: Anmeldeblatt mit der echten FlexNow-Seite (`StudIPWebView`, neu `opensNewWindowsInPlace`:
  Links/Formulare mit neuem Fenster laden in derselben Ansicht), darunter „Passwort merken“ und der Hinweis „Landest du
  nach der Anmeldung wieder auf der Seite der Universität, tippe auf ‚FlexNow neu öffnen‘“ (im Browser der Claude-App
  kam man nach der Anmeldung auf der Uni-Seite heraus; Grund unbekannt). Karte „Prüfungen (FlexNow)“ (iPad und iPhone).
- „FlexNow öffnen“ öffnet jetzt im In-App-Browser mit der Anmeldung der App (`UniLinks.scopes`), nicht mehr in Safari.
- Texte: Hinweis „neu in StudiNow“ (`newNotice`) nennt bei „Schon dabei“ jetzt „Aus FlexNow liest StudiNow deine
  angemeldeten Prüfungen mit Abmeldefrist.“, bei „Noch nicht dabei“ „Noten (FlexNow)“ statt „Noten und
  Prüfungsanmeldung (FlexNow)“. Dazu Hochschulwahl, Untertitel „Uni & Noten“, Ersatztext der Notenkarte.

### Nachbildung
`apps/apple/DebugStub/goettingen-flexnow/` (README dort): Anmeldeseite, angemeldete Seite, leere und unfertige Liste –
erfundene Daten im gesehenen Aufbau. `tools/build-goettingen-stub.py` kopiert die beiden Seiten in
`DebugStub/goettingen/`, damit der Simulator mit einem Ordner auskommt (`-UFLoginStub …/DebugStub/goettingen`).

## 4. Tests (27.11.2026)

- **Kern** (`swift test`, eigener Bauordner `~/Studora-Builds/dd-flexnow-core`): alle **1957** Tests, 0 Fehler (20
  übersprungen wie bisher). Neu `FlexNowTests` (8): Formular und Rechner, angemeldete Seite, Leser gegen die
  Nachbildung, nur Blöcke mit `angemeldet`, leere/unfertige/Anmeldeseite, Textregeln, Speichern ohne Löschen bei
  unfertiger Liste, Antwort der Schnittstelle, Erinnerungen. `GoettingenTests.testLoginForm` angepasst (zwei Formulare).
- **App, eigener iPad-Simulator** „FlexNow iPad“ (7416FE4E-…): 39 betroffene Klassen, **456** Tests, 0 Fehler (3
  übersprungen). Neu `FlexNowAppTests` (8): nur Göttingen hat FlexNow, Anmelden → Lesen → Anzeige, abgelaufen → genau
  eine stille Anmeldung, abgelehntes Passwort nie zweimal, Abmelden (Stud.IP bleibt), Karte auf iPad und iPhone,
  Texte, Mitlese- und Laderegeln, Nachbildung gleich in beiden Ordnern. `GoettingenAppTests` angepasst (FlexNow im
  In-App-Browser, Schnittstelle antwortet mit `FlexNow`).
- **App, eigener iPhone-Simulator** „FlexNow iPhone“ (07C2FE7B-…): 9 Klassen (FlexNow, Göttingen, Prüfungsanmeldung,
  iPhone-Anmeldung, Breiten-Prüfung, Erinnerungen …), **82** Tests, 0 Fehler (5 übersprungen).
- **Python**: `tests/test_goettingen.py` (Nachbildung aktuell), `test_release_texts.py`, `test_exam_registration*.py`:
  46 grün.
- **Mac**: nicht gelaufen (nicht Teil des Auftrags; vor dem Einmischen über `tools/mac-test.sh`, wenn kein anderer
  Mac-Lauf aktiv ist).
- Bildschirmbild der Karte auf iPhone und iPad im Test angesehen: zwei Prüfungen mit Art, Modul, Frist („noch 13 Tage“),
  nichts abgeschnitten.

## 5. Zum Ausprobieren am Gerät (Inhaber, mit eigenem Konto)

Nur mit Okay des Inhabers aufs Gerät. Dann: „Uni & Noten“ → „Prüfungen (FlexNow)“ → „FlexNow verbinden“ → auf der
echten Seite selbst Kennung und Passwort eintippen und „Login“ tippen. Zu prüfen:
1. Kommt die Anmeldung im Fenster an (Studentenschnittstelle erscheint, Blatt schließt sich)? Wenn man auf der
   Uni-Seite landet: „FlexNow neu öffnen“ tippen und berichten, was dann zu sehen ist.
2. Stehen die angemeldeten Prüfungen mit der richtigen Abmeldefrist in der Karte?
3. Später (Sitzung abgelaufen) „Angemeldete Prüfungen lesen“: gelingt die stille Neuanmeldung?

Was ich ohne echtes Konto nicht prüfen konnte: die Anmeldung in der App selbst, ob „Aktuelles“ nach dem Laden von
`/FN2SSS/` von selbst kommt (die App klickt nichts an), wie lange die Sitzung hält, der Text bei falschem Passwort, der
Wortlaut „keine aktuellen Prüfungen“, Prüfungen mit Termin und Raum, die englische Fassung.

## 6. Offen / später

- Noten aus „Studierendendaten → Alle Prüfungen“: erst mit einem Konto, das Noten hat.
- Website und Store-Texte nennen FlexNow noch als „noch nicht dabei“ (`docs/release/STARTSEITE.md`, `site/index.html`):
  anpassen, wenn dieses Update erscheint.
- Hintergrund-Anmeldung ohne Webansicht (`allowedForms`), Lesen im Sync-Knopf bzw. im Hintergrund: nach dem Gerätetest.
- Beim Mischen mit dem Zweig der Göttinger Uni-Mail: `UFUniversityScope.newNotice` ändern beide Zweige (hier nur
  „Aus FlexNow …“ und „Noten (FlexNow)“).
