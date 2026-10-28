# Stud.IP-Abgleich auf dem iPad (ohne Playwright)

Stand 25.10.2026 (Probe an der LUH und Umsetzung von Option B: Abschnitte 7–9). Ziel: Dateien, Termine und Kurse direkt auf dem iPad abgleichen. Das LUH-Passwort bleibt beim
Studierenden, der zentrale Dienst bekommt weder Passwort noch Stud.IP-Token (Vorgabe vom 25.10.).

## 1. Warum Playwright dort nicht geht

Heute meldet sich `app/studip_sync.py` mit einem ferngesteuerten Chromium (Playwright) über WebSSO an und nutzt danach
die JSON:API mit dem Session-Cookie. Auf iPadOS gibt es keinen fernsteuerbaren Browser, und Apps dürfen keinen eigenen
Browser-Prozess starten. Benötigt wird ein offizieller Anmeldeweg.

## 2. Optionen

| | A: Stud.IP-OAuth2 mit PKCE (empfohlen) | B: WebSSO im App-Browser + Cookie | C: PC als Abgleich-Station |
| --- | --- | --- | --- |
| Anmeldung | Systemfenster `ASWebAuthenticationSession` mit der Hochschul-SSO-Seite | eingebettete `WKWebView` mit der SSO-Seite | wie heute (Playwright am PC) |
| Sieht die App das Passwort? | nein | technisch möglich (eingebettete Seite) | ja, liegt in `.env` am PC |
| Dauerhafter Zugriff | Refresh-Token im Schlüsselbund | Session-Cookie, läuft nach Stunden ab, dann neu anmelden | solange der PC läuft |
| Abgleich im Hintergrund | ja (Token reicht) | kaum (Cookie abgelaufen) | ja, aber nur mit PC |
| Abhängigkeit | LUH-Administration muss einen OAuth2-Client für UniFlow anlegen | keine | PC |
| Aufwand | mittel | mittel | vorhanden |

**Belege zu A:** Stud.IP enthält einen OAuth2-Server mit „Authorization Code Grant mit PKCE“ und „Refresh Token Grant“;
Endpunkte `…/dispatch.php/api/oauth2/authorize` und `…/dispatch.php/api/oauth2/token`, einziger Scope `api`; Clients
legt ein Root-Administrator unter `…/dispatch.php/admin/oauth2` an; Apps müssen PKCE nutzen
([Stud.IP-Entwicklerdoku OAuth2](https://docs.gitlab.studip.de/entwicklung/functions/oauth2/)). Eine fremde
Bibliothek nutzt denselben Weg gegen die JSON:API (`jsonapi.php/v1/`) mit Client-ID und eigenem URL-Schema
([Dart-Paket studip](https://pub.dev/documentation/studip/latest/)).

**Bei der LUH geprüft (ohne Anmeldung):** `https://studip.uni-hannover.de/dispatch.php/api/oauth2/authorize` antwortet
mit HTTP 500, eine erfundene Adresse daneben mit HTTP 400. Der OAuth2-Teil ist also in der Installation vorhanden;
ob er eingerichtet ist und ob es einen Client für Apps gibt, ist **nicht geprüft** und muss bei der LUH erfragt werden.

## 3. Empfehlung

1. **Jetzt:** Anfrage an das Stud.IP-Team der LUH (ELSA/Stud.IP-Support): OAuth2-Client für eine studentische App,
   öffentlicher Client mit PKCE, Weiterleitung `de.uniflow.ai:/oauth/callback` (oder Universal Link), Scope `api`.
2. **Bis zur Antwort:** Option B als Übergang auf dem iPad (Anmeldung beim Öffnen der App, Cookie nur im Schlüsselbund,
   nie an den Dienst), dazu Option C für Nutzer mit PC.
3. **Mit OAuth2:** Option A als Standard; B nur noch als Rückfall für Hochschulen ohne OAuth2-Client.

## 4. Zuverlässigkeit unter iPadOS

iPadOS führt Hintergrundarbeit nicht zu festen Uhrzeiten aus. „8:00 und 15:00 Uhr“ wie am PC ist daher nicht garantierbar.

| Auslöser | Verhalten | Einsatz |
| --- | --- | --- |
| App wird geöffnet / kommt in den Vordergrund | sofort | immer abgleichen (inkrementell, nur Änderungen) |
| `BGAppRefreshTask` (frühestens 8:00 / 15:00) | System entscheidet nach Nutzung, Akku, Netz; ca. 30 s Laufzeit | Dateiliste holen, Downloads anstoßen |
| `BGProcessingTask` | meist nachts beim Laden | große Downloads, Textauszug für die Skriptsuche |
| Hintergrund-`URLSession` | Downloads laufen weiter, auch wenn die App beendet wird | PDF-Downloads |
| Stille Push-Nachricht vom Dienst um 8:00/15:00 | weckt die App kurz; wird vom System gedrosselt | Auslöser für A; braucht APNs (Developer Program) |

Realistisches Versprechen an Nutzer: „Neue Dateien erscheinen spätestens beim Öffnen der App und meist schon vorher.“

## 5. Technische Schnittstelle (Entwurf)

- `StudIPAuth`: liefert ein gültiges Zugriffstoken (A) bzw. Cookie (B); erneuert über Refresh-Token; meldet „Anmeldung
  nötig“, statt still zu scheitern.
- `StudIPClient`: `courses()`, `folders(course)`, `files(folder, since:)`, `download(fileRef) -> URL`,
  `events(range)`; nutzt dieselben JSON:API-Routen wie `app/studip_sync.py`
  (`users/{id}/courses`, `courses/{id}/events`, `folders`, `file-refs/{id}/content`).
- Ergebnis in dieselbe lokale Struktur wie heute (Modul, Lehrwoche, Ordnertyp), damit Kalender, Module und
  Skriptsuche unverändert bleiben.

## 6. Tests (wenn umgesetzt)

- Ablauf mit Test-Instanz von Stud.IP (eigene Docker-Instanz) und Testkonto; nie mit echten LUH-Zugangsdaten in CI.
- Token-Ablauf, Widerruf, Netzabbruch während Downloads, App-Beendigung während Hintergrund-Downloads.
- Am Gerät: Hintergrundabgleich über mehrere Tage beobachten (Zeitpunkte protokollieren).

## 7. Probe an der LUH (25.10.2026, nur lesend)

Ablauf wie später auf dem iPad: Anmeldung von Hand auf der echten Stud.IP-Seite (WebSSO) im Browser, danach nur
noch Abrufe der JSON:API mit dem Sitzungs-Cookie. 124 GET-Anfragen nacheinander mit 250 ms Pause, nichts verändert.

| Prüfung | Ergebnis |
| --- | --- |
| `users/me` mit Sitzungs-Cookie | 200 (ohne Anmeldung: 401) |
| Kurse (`users/{id}/courses`) | 19, alle 14 Kurse mit Dateien aus dem PC-Abgleich enthalten |
| Dateien nur über den Ordnerbaum der API (`courses/{id}/folders` → `folders/{id}/file-refs` / `folders`) | **151 – genau so viele wie der PC-Abgleich**, keine Abweichung in einem Kurs, 52 Ordner |
| Datei-Merkmale | `name`, `filesize`, `mime-type`, `chdate`, `mkdate`, `is-downloadable` u. a. → Änderungen ohne Download erkennbar |
| Download `file-refs/{id}/content` (3 kleinste Dateien) | 3 × 200, Größe stimmt byte-genau |
| nicht herunterladbar | 1 Datei (deckt sich mit dem PC: 150 von 151 geladen) |
| Antwortzeiten | Median 62 ms, 95 % unter 99 ms, max. 237 ms; keine Fehler |
| Sitzungs-Cookie für Skripte lesbar? | nein (HttpOnly) |
| `dispatch.php/api/oauth2/authorize` ohne Parameter | 500 (Route vorhanden, Einrichtung unbekannt) |
| Sitzung nach 10 Minuten | noch gültig; **Dauer über Stunden noch nicht gemessen** |

Bisherige PC-Läufe (24.10.): alle 7 Fehlschläge betrafen das automatische Ausfüllen des Anmeldeformulars bzw.
fehlende Zugangsdaten während der Einrichtung; alle regulären Läufe danach waren erfolgreich. Auf dem iPad meldet
sich der Mensch selbst an, diese Fehlerquelle entfällt. Neue Unbekannte ist die Lebensdauer der Sitzung.

## 8. Nutzungsbedingungen und Recht (Recherche 25.10.2026, keine Rechtsberatung)

- **Stud.IP-Nutzungsbedingungen der LUH** (Betreiber ZQS/elsa,
  [Nutzungsbedingungen](https://studip.uni-hannover.de/dispatch.php/siteinfo/show/1/8)): Herunterladen für den
  privaten Gebrauch sowie Forschung und Lehre erlaubt. Verboten: Weitergabe an Dritte zu kommerziellen Zwecken,
  Zugänglichmachen für Nicht-Berechtigte, Weitergabe des Passworts, automatisiertes Erheben von Daten (z. B. Namen)
  über das übliche Maß hinaus. Zu API, Bots oder Drittanbieter-Apps steht dort nichts; Abruflimits nicht gefunden.
- **LUIS-Nutzungsordnung** ([PDF](https://www.luis.uni-hannover.de/fileadmin/it-support/Nutzungsordnung_LUIS-IT_2017-08-17.pdf)):
  nur eigene Kennung, Passwort geheim, Betrieb nicht stören, Urheberrecht beachten. LUIS wertet das Hinterlegen von
  Zugangsdaten auf Systemen Dritter als unzulässig ([Hinweis zu Mail-Apps](https://www.luis.uni-hannover.de/services/kommunikation/e-mail/exchange-mailsystem/zugaenge/sicherheitsmaengel-in-mail-apps-fuer-android-und-ios))
  → Cookies/Tokens nie auf einen zentralen Server.
- **Stud.IP-Doku:** JSON:API ist ausdrücklich die externe Schnittstelle; Anmeldung per Basic-Auth, Sitzungs-Cookie
  oder OAuth2 ([JSON:API](https://docs.gitlab.studip.de/entwicklung/jsonapi/start/),
  [OAuth2](https://docs.gitlab.studip.de/entwicklung/functions/oauth2/)). OAuth2: Clients legt ein Root-Admin an,
  Apps mit PKCE, einziger Scope `api` (Vollzugriff).
- **Eingebettete Anmeldung:** RFC 8252 §8.12 rät von Anmeldungen in eingebetteten Webansichten ab, weil die App die
  Eingaben technisch mitlesen könnte. Option B ist deshalb nur als Übergang und für die eigene Nutzung gedacht; für
  eine Veröffentlichung OAuth2 mit `ASWebAuthenticationSession` (Option A).
- **Urheberrecht:** Speichern auf dem eigenen Gerät deckt sich mit den Nutzungsbedingungen (privater Gebrauch).
  Zentrale Speicherung durch einen (bezahlten) Dienst oder Bereitstellung für andere ist kritisch (§ 53 Abs. 1
  S. 2, § 60a UrhG) → Dateien nur auf dem Gerät des Studierenden; vor einer Veröffentlichung juristisch prüfen lassen.
- **Datenschutz:** Stud.IP protokolliert IP und Benutzername je Abruf (7 Tage) – die Abrufe der App sind dort
  sichtbar. Bei Verteilung an andere: Datenschutzerklärung, keine Cookies/Dateien auf eigenen Servern.

Ansprechpartner: ZQS/elsa E-Learning-Support (betreibt Stud.IP, elearning@uni-hannover.de), LUIS
IT-Service-Desk, Datenschutzbeauftragter der LUH. Entwurf einer Anfrage: `docs/ANFRAGE-STUDIP-ZUGANG.md`.

## 9. Umsetzung auf dem iPad (Option B, Stand 25.10.2026)

Geprüft: Kern lokal im offiziellen Linux-Container `swift:6.0-jammy` (Swift 6.0.3, derselbe wie im CI): 48 von 48 Tests grün, keine Warnungen. **App-Teil (Webansicht, Schlüsselbund, Oberfläche) nicht kompiliert** – braucht macOS/Xcode (CI-Lauf auf macOS oder Mac).

- **Kern** (`UniFlowCore`, auch unter Linux testbar): `StudIPClient` (nur lesend, nacheinander, 250 ms Pause,
  höchstens 1500 Anfragen je Durchgang, nur der eigene Host, abgelaufene Sitzung bei 401 oder Umleitung auf die
  Anmeldung), `StudIPImport` (neu/geändert/unverändert/nicht herunterladbar/in Stud.IP entfernt, sichere
  Dateinamen, Vorauswahl der Kurse des jüngsten Semesters). Tests: `StudIPTests.swift` (11 Fälle).
- **App:** `StudIPLoginView` (eingebettete Webansicht, Stud.IP-Seite der LUH; seit 27.10.2026 merkt das Passwort nur
  iOS – die App speichert und füllt nichts, der Schalter „Auf diesem iPad merken“ vom 26.10. ist wieder entfernt,
  `docs/SICHERHEITSKONZEPT-KONTEN.md` 1a; Erfolg erst, wenn
  `users/me` mit den Cookies 200 liefert), `StudIPKeychain` (nur dieses Gerät, nicht im Backup), `StudIPSync`
  (Abgleich beim Öffnen der App, höchstens alle 30 Minuten, und auf Knopfdruck; Dateien im Container des
  Apple-Nutzers und der LUH unter `StudIP/` (bis zur Hochschulwahl Application Support/StudIP), vom iCloud-Backup
  ausgenommen; Verzeichnis nach jeder Datei gespeichert; Sitzungs-Cookie und Webansicht je Container),
  `StudIPView` (Status, Kursauswahl, Dateien mit Vorschau, Abmelden mit/ohne Löschen). Erreichbar über
  Einstellungen → Stud.IP und auf dem Verbindungsbildschirm („Stud.IP ohne PC nutzen“).
- **Noch nicht:** Anzeige der Stud.IP-Dateien im Editor und in den Modulen, Termine, Hintergrundabgleich.

Offen und zu messen, sobald die App auf dem Gerät läuft:
1. Lebensdauer der Sitzung (wie oft muss man sich neu anmelden; bleibt die SSO-Anmeldung in der Webansicht erhalten?).
2. Abgleich über mehrere Tage: Anzahl Anfragen und Dauer je Durchgang, Fehler.
3. Speicherbedarf (PC-Stand: 151 Dateien, 222 MB).

## 10. Stundenplan nach dem eigenen Stud.IP-Kalender (27.10.2026)

Befund mit echten LUH-Daten im Simulator (Zählwerte, keine Inhalte): `users/{id}/schedule` liefert **alle**
Kurszeiten aller belegten Kurse (102 Kurszeiten in 17 Kursen), auch fremde Übungsgruppen und Kurse, die der Nutzer in
Stud.IP nicht im Kalender hat. Daraus wurden 14 Serien. Der Stud.IP-Kalender des Nutzers zeigt dagegen andere Termine:
Die eigene Gruppenübung, Fragestunden und die Kurszeit „Hauptveranst.“ einer Übung mit 18 Gruppen fehlten. Dafür kamen
zwei Vorlesungen eines Kurses dazu, den der Nutzer aus dem Kalender genommen hatte.

Stud.IP wählt die Kalendertermine so aus (`CalendarCourseDate::getEvents`):
- Kurse mit Kalenderbindung (`seminar_user.bind_calendar`),
- ohne im Stundenplan ausgeblendete Kurszeiten,
- Termine mit Statusgruppen nur für deren Mitglieder.

Genau diese Termine liefert der iCalendar-Export `jsonapi.php/v1/users/{id}/events.ics` ab dem Zeitpunkt der Abfrage.
Die UID `Stud.IP-SEM-<Termin-ID>@…` ist dieselbe ID wie in `courses/{id}/events`.

Umsetzung (`StudIPCalendar` im Kern):
- Der Abgleich holt den Export zusätzlich.
- Je Kurszeit gilt:
  - **relevant**, wenn ein künftiger Termin im Kalender steht (Kurs, Tag und Beginn; bei gleichen Zeiten in mehreren
    Räumen entscheidet der Raum),
  - **nicht relevant**, wenn es künftige Termine gibt, aber keiner im Kalender steht.
- Relevante Kurszeiten kommen ohne Gruppenwahl in den Stundenplan. Gleiche Zeiten eines Kurses werden eine Serie.
- Nicht relevante, unveränderte Serien verschwinden. Serien mit eigener Änderung bleiben (Teilnahme, Zeiten, Notiz,
  eigene Ausnahme).
- Entscheidungen bleiben gespeichert. Kurszeiten ganz in der Vergangenheit bleiben unentschieden (bisherige Regel).
- Persönliche Einträge aus dem Stud.IP-Stundenplan bleiben wie bisher.

Zwei Fragen an den Nutzer stehen als Karten über dem Stundenplan und in der Zusammenfassung des Abgleichs. Die Antworten
gelten je Kurs und je Container, also je Nutzer und Hochschule. Endpunkte nur auf dem Gerät:
`GET /api/timetable/studip-questions`, `POST …/course`, `POST …/times`.
1. **Kurs belegt, aber nicht im Kalender:** „Übernehmen“ oder „Weglassen“. Bis zur Antwort nicht im Stundenplan, wie in
   Stud.IP. Übernommen gilt die bisherige Regel, also Gruppenwahl bei parallelen Gruppen.
2. **Kurs mit drei oder mehr Serien je Woche:** „Welche Termine besuchst du?“ Alle sind vorausgewählt, abgewählte
   bekommen `attend=0` (grau, Zeit frei).

Ohne Export (Fehler, ältere Stud.IP-Fassung, Kalender ohne Veranstaltungstermine) bleibt die bisherige Regel. Die
Zusammenfassung sagt dann „Stud.IP-Kalender nicht gelesen: eigene Übungsgruppen nicht sicher bekannt“. Tests mit
erfundenen Daten: `packages/shared-contracts/fixtures/studip-schedule/kalender`, `StudIPCalendarTests` (Kern) und
`StudIPCalendarAppTests` (App).

**Python (PC, Windows-App, Web) seit 27.10.2026 mit derselben Regel** (`timetable._apply_calendar`,
`studip_sync.fetch_calendar_ids`, Tests `tests/test_studip_calendar.py` gegen dieselbe Fixture). Unterschiede, weil
Python Einzeltermine zu Serien fasst statt Kurszeiten zu lesen: entschieden wird je Serie (Kurs, Wochentag, Beginn,
Ende) über ihre künftigen Einzeltermine; gleiche Zeit in mehreren Räumen ist eine Serie mit dem Raum der eigenen
Termine. Statt der zwei Fragekarten bleibt der fehlende Kurs in der Import-Vorschau wählbar (Hinweis „Kurs steht nicht
in deinem Stud.IP-Kalender“), Kurse mit vielen Serien werden wie in Stud.IP alle übernommen. Von Hand bestätigte
Vorschauen heißen `studip-manual` und werden nie als fremde Gruppe entfernt. Dazu die Doppel-Regel aus 3d74b00
(gleicher Kurs, Tag und überlappende Zeit, `timetable._same_series`).

**iPad seit dem Nachzug von 8cc7463 (27.10.2026):** Einzeltermine, die zu keiner Kurszeit gehören (Blocktermine,
Klausuren, Kurse ohne Kurszeiten), entscheidet das iPad jetzt genauso wie Python (`LocalTimetableImport.applyCalendar`,
Tabelle `studip_series_relevance`); was laut Kalender nicht dazugehört, entfernt der Abgleich über die Verknüpfung der
Serie, nur wenn sie unverändert und automatisch übernommen ist (Quelle genau `studip`). Von Hand bestätigte Vorschauen
heißen auch hier `studip-manual`, die Doppel-Regel `_same_series` gilt in Vorschau und Abgleich, die Termin-IDs liest
dieselbe Regel wie `calendar_date_ids`. Weiter nur auf dem iPad: Kurszeiten mit Raum-Entscheidung und die zwei
Fragekarten; „Kurs fehlt im Kalender“ aus Einzelterminen nur bei Kursen ohne entschiedene Kurszeit; was der Kalender
entschieden hat (`fremd`, `kurs_fehlt`), zählt nicht als offene Gruppe. Test mit den Erwartungen von
`tests/test_studip_calendar.py` auf derselben Fixture: `StudIPCalendarSingleDatesTests` (Kern).

**iPad seit dem Nachzug von e9a40d1, c0721da und ba02e47 (28.10.2026, `docs/UEBERGABE-APPLE-2026-10-28.md`):** Die
Woche kommt wie am PC direkt aus den Einzelterminen (`LocalTimetable.studipDated`, `mergeDated`). Ab dem Tag nach dem
Kalenderabruf zählen nur Termine aus dem eigenen Kalender, derselbe Termin in mehreren Räumen ist ein Eintrag.
Automatisch übernommene Serien zeigen nur, was Stud.IP an dem Tag kennt; das gilt auf dem iPad auch für Serien aus
Kurszeiten. Gespeicherte Ausnahmen bleiben sichtbar. Kurse früherer Semester plant der Abgleich nicht ein (`Semesters`,
Abruf mit `end-semester`): keine Dateien, Termine, Aufzeichnungen und Module. Eigene Schalter in Einstellungen → Module
bleiben (`active_custom`). Vertrag: `fixtures/studip-schedule/woche.json` (`StudIPWeekTests`).

**iPad-Regel für den Abruftag und die Zeit davor (28.10.2026, Befund mit echten Daten).** Auf dem Echtdaten-Simulator
lief der Abruf am 27.10. um 02:39. Montag 26.10. und Dienstag 27.10. zeigten jede parallele Übungsgruppe, also dasselbe
Fach fünfmal; KW 44 ab Mittwoch stimmte. Der Grund: Am PC entscheidet der Kalender erst ab dem Tag nach dem Abruf, davor
zählt jeder Einzeltermin, und jeder Abruf ersetzt die IDs des vorigen. Nach jedem Abgleich ist aber heute der Abruftag:
Die Übersicht „Heute an der Uni“ und der Tag zeigten alle Gruppen, ebenso alle Wochen vor dem ersten Abruf. Auf dem iPad
gilt deshalb (`StudIPCalendar.Coverage`, `LocalTimetable.studipDated`):
1. **Ab dem ersten Abruf entscheidet der Kalender** (frühestes `fetched_at`; ältere IDs behalten ihren Zeitpunkt),
   auch am Abruftag. Nicht erst ab dem frühesten Kalendertermin: Mit echten Daten stand am Abruftag um 08:15 eine
   fremde Gruppe, deren Zeitschlitz erst ab einer späteren Woche die eigene ist; der erste eigene Termin des Tages war
   um 10:15. Was vor dem ersten Abruf begann (auch am Abruftag selbst), wird wie Punkt 3 behandelt. Ob der Export
   schon begonnene Termine enthält, wissen wir nicht sicher.
2. **IDs früherer Abrufe bleiben.** Ein neuer Abruf entfernt nur IDs, die nicht mehr im Kalender stehen und deren
   Termin ab dem Abrufzeitpunkt beginnt; das Datum kommt aus `studip_events`. IDs ohne bekannten Termin bleiben. So
   bleiben vergangene Tage auf dem zuletzt gesehenen Stand, und `max(fetched_at)` ist der letzte Abruf.
   - Absicht: entfernt wird ab dem Abrufzeitpunkt, nicht ab dem Abruftag. Sonst verlöre ein Abruf am Mittag die
     eigenen Termine vom Vormittag, die ein früherer Abruf gesehen hatte. Spätestens beim nächsten Abruf an einem
     anderen Tag wären sie dann aus der Woche verschwunden.
   - Keine Migration nötig: Die Tabelle bleibt gleich, gesammelt wird ab dem nächsten Abruf.
3. **Davor zählt der Zeitschlitz:** Für Zeiten, die der Kalender nicht abdeckt, gilt ein Termin als eigener, wenn Kurs,
   Wochentag, Beginn und Ende einem Kalendertermin desselben Kurses entsprechen. Sonst erscheint er nicht. Ein Kurs ganz
   ohne Kalendertermin fällt weg, wie nach dem Abruf.
   - Automatisch übernommene Serien folgen den Einzelterminen.
   - Persönliche, eigene und von Hand bestätigte Serien (`studip-manual`) bleiben immer, gespeicherte Ausnahmen wie
     „Ausfall laut Stud.IP“ bleiben sichtbar.
   - Serien eines Kurses ohne Kalendertermin fallen ab dem Abruftag weg, nicht erst ab dem Tag danach.

Die Entscheidungen über Kurszeiten und Serien (`StudIPCalendar.store`, `applyCalendar`) bleiben wie am PC „ab dem Tag
nach dem Abruf“. Sie werten nur künftige Termine aus und sind nicht betroffen. Tests mit erfundenen Daten:
`StudIPCalendarFetchDayTests`. Die Verträge `woche.json` (Abruf 27.10., Woche 16.–22.11.) und `timetable-logic.json`
(ohne Kalender) sind unverändert grün. Seit 5dbabd6 gilt am PC dieselbe Regel (`calendar_coverage`, `calendar_shows`,
`store_calendar`; `tests/test_studip_fetch_day.py`). `timetable-logic.json` enthält keinen Kalender, der Fall kommt im
Vertrag also nicht vor.

**Ausfälle laut Stud.IP blendet das iPad aus wie Stud.IP (Entscheidung des Inhabers, 28.10.2026).** In der
Weihnachtswoche (23.–25.12.) markiert Stud.IP 13 Veranstaltungen des Inhabers als ausgefallen. Der Stud.IP-Kalender
zeigt dann nichts, UniFlow zeigte sie durchgestrichen. Jetzt fehlen sie in Stundenplan-Woche, Lernkalender (Woche,
3 Tage, Tag, Monat, Liste) und „Heute an der Uni“.
- **Nur in der Anzeige:** Die Antworten des lokalen Backends bleiben wie in Python (`status: ausfall`), die Verträge
  `woche.json` und `timetable-logic.json` sind unverändert. Die App holt die Ausfälle laut Stud.IP eines Zeitraums
  über `GET /api/timetable/studip-cancelled?start=…&end=…` (nur auf dem Gerät) und lässt genau diese Vorkommen weg
  (`StudIPCancellations` im Kern, `StudIPCancelled` in der App).
- **Unterscheidung:** Ein Ausfall laut Stud.IP ist eine Ausnahme `cancelled` mit der Notiz „Ausfall laut Stud.IP“. So
  speichert sie der Abgleich (`apply_import` mit Quelle studip, `StudIPScheduleImport.refresh`). Was der Nutzer selbst
  als ausgefallen markiert, hat diese Notiz nicht, ebenso „heute nicht“ und „dauerhaft nicht“. Solche Termine bleiben
  sichtbar, damit er sie zurücknehmen kann.
- **Freie Zeit:** Belegt ist nur „teilnahme“ (`busy_blocks`). Ein Ausfall gibt die Zeit also schon frei, für freie
  Fenster, Lernplan und Umplanen; daran hat sich nichts geändert.
- **Nicht betroffen:** Mitteilungen (nur Fristen, Abgleich und Timer) und die Fristen-Erkennung (keine Termine) zeigen
  keine Stundenplan-Termine. Der nächste Termin je Modul nimmt nur besuchte.
- **Zurückgesetzt bleibt sichtbar** (Entscheidung des Inhabers, a7827c6, wie `set_exception` in Python): Setzt der
  Nutzer einen Ausfall laut Stud.IP zurück, wird daraus `attend` mit der Notiz „Findet statt (Ausfall laut Stud.IP
  zurückgesetzt)“. Der Termin steht als `teilnahme` da, der nächste Abgleich trägt den Ausfall nicht wieder ein, und
  `dropStaleCancellations` entfernt nur Ausnahmen `cancelled` mit der Stud.IP-Notiz. Wer noch einmal zurücksetzt,
  bekommt den Ausfall laut Stud.IP zurück; alle anderen Ausnahmen werden wie bisher gelöscht.
- **Am PC-Server** gibt es den Endpunkt nicht, dort bleibt alles wie geliefert.

Tests: `StudIPCancellationsTests` (Kern) und `StudyPlanLocalAppTests.testStudIPCancellationIsHiddenButOwnMarksStay`
(App, ohne die Änderung rot).

**Vorschau: `existing_id` an jeder Zeile (wie 196555e).** `diff_against_existing` setzt `existing_id` an jede Zeile mit
vorhandener Serie (`LocalTimetableImport.diffAgainstExisting(marking:)`, aus Stud.IP über `previewDiff` nach
Stud.IP-ID). Der Dialog (`TimetablePreviewDialog.existingID`) nimmt die Markierung der Zeile selbst. Strenger als die
Web-App: Markiert die Vorschau andere Zeilen, ist eine Zeile ohne Schlüssel neu. Die Web-App sucht dann noch über
Titel und Wochentag und träfe beim zweiten Termin desselben Kurses am selben Tag die Serie des ersten. Nur eine
Vorschau ganz ohne Markierung (älterer PC-Server) sucht wie bisher. Tests: `StudIPCalendarSingleDatesTests`,
`StudIPScheduleStoreTests.testGroupOnLectureDayKeepsLecture` (Kern), `TimetableLocalAppTests.testPreviewRowUsesItsOwnExistingID` (App).
