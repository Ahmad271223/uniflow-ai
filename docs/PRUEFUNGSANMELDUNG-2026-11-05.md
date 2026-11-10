# Prüfungsanmeldung – Hilfe (Entscheidung des Inhabers 05.11.2026)

Ziel: StudiNow erinnert an die Meldezeiträume, sagt, welche Prüfungen man laut eigenem Studienverlauf anmelden sollte,
öffnet das QIS an der richtigen Stelle und hakt danach ab, was angemeldet ist. **Anmelden und abmelden tut immer der
Mensch selbst im QIS.** StudiNow füllt kein QIS-Formular aus, schickt keins ab und folgt nie einem Link zur
Prüfungsanmeldung/-abmeldung. Das Schreiben an die Hochschulen (docs/release/ANSCHREIBEN-HOCHSCHULEN-2026-11-04.md,
„Prüfungsanmeldungen … bleiben im QIS“) bleibt damit wahr; docs/QIS-STUDIP-STRUKTUR.md ist angepasst.

## Was die App macht

1. **Meldezeiträume** der LUH je Semester und Studiengang aus den öffentlichen Seiten des Prüfungsamts, als Datendatei
   mit Quelle und Abrufdatum (`packages/shared-contracts/exam-registration-luh.json`). Lokale Mitteilungen 7 und 2 Tage
   vor dem Ende des Meldezeitraums und am ersten Tag (9:00 Uhr Berlin), abschaltbar. Ist der Zeitraum für einen
   Studiengang nicht sicher bekannt, zeigt die App **nur den Link** zur Terminseite – kein Raten.
2. **„Diese Prüfungen solltest du anmelden“**: Module des persönlichen Studienverlaufs im Semester des Meldezeitraums
   (geplant, offen, nachzuholen, nicht bestanden), ohne bestandene, ohne Abschlussarbeit und ohne Module mit
   Prüfungsleistung „keine“. Je Eintrag Modul, Prüfungstermin (wenn bekannt, aus allen Quellen der Klausurtermine), Grund
   („laut deinem Plan im 3. Semester“, „nachholen – im WiSe 25/26 nicht abgelegt“, „Wiederholung – 2. Versuch“), passende
   Frist (VbP oder alle anderen Prüfungsformen) und Rücktrittsregel. Ohne Studienverlauf: die kommenden Klausuren der
   eigenen Module (Grund „Klausurtermin bekannt“).
3. **„Im QIS zur Prüfung anmelden“** (bis 09.11.2026 „Im QIS anmelden“) öffnet die QIS-Seite „Mein Studium“ im In-App-Browser (gleiche Cookies wie der Notenabruf,
   `UniLinks`/`UniWebBrowser`). Darunter der Hinweis: „Tippe dort auf ‚Prüfungsanmeldung/-abmeldung‘, wähle die Prüfung
   und bestätige selbst. StudiNow füllt nichts aus und schickt nichts ab.“ Ist die Sitzung abgelaufen, zeigt QIS die
   eigene Anmeldeseite; der Mensch meldet sich selbst an.
   Seit 09.11.2026 (Befund des Inhabers am iPad: der Knopf wurde für den QIS-Login gehalten) heißt er „Im QIS zur
   Prüfung anmelden“ bzw. „Im LSF zur Prüfung anmelden“, und nach dem Schließen dieses In-App-Browsers ruft die App die
   angemeldeten Prüfungen einmal selbst ab (wie „Angemeldete Prüfungen abrufen“; nur mit bestehender QIS- bzw.
   LSF-Verbindung, nie in der Demo; `ExamRegistrationAutoFetch`, `UniWebBrowser.didClose`).
4. **Abhaken**: „Angemeldete Prüfungen abrufen“ (und jeder normale QIS-Abruf) liest nur lesend die Seite „Info über
   angemeldete Prüfungen“. Zusätzlich zählt der Vermerk **AN** im Notenspiegel (laut Prüfungsamt erscheinen angemeldete
   Prüfungen dort so; der Studienverlauf kennt das schon als Status „angemeldet“). Warnung, wenn der Meldezeitraum in
   höchstens 3 Tagen endet und geplante Prüfungen noch nicht angemeldet sind.

Orte: Karte „Prüfungsanmeldung“ auf der Übersicht (im Meldezeitraum und in den 7 Tagen davor), Abschnitt im
Studienverlauf, Zeile und Abzeichen „angemeldet“/„nicht angemeldet“ in der Karte „Nächste Klausuren“ (eine eigene Seite
„Klausurtermine“ gibt es nicht; diese Karte ist die Klausurliste), Block „Prüfung anmelden“ in den Moduldetails des
Studienverlaufs und auf der Modulseite der App.

## Quellen (gelesen am 05.11.2026, öffentlich, ohne Anmeldung)

robots.txt erlaubt die Seiten (gesperrt sind nur Suche, Downloads, Fußzeilen-Inhalte). Elf Abrufe im Abstand von
mindestens 3 Sekunden (robots.txt, Sitemap, Sitemap-Seiten, allgemeine Seite, sieben Terminseiten), abgelegt unter
`~/Studora-Builds/pruefungsanmeldung/` (nicht im Repository).

- Allgemein: https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/pruefungsanmeldung
  - Je Semester ein Meldezeitraum für VbP und einer für alle anderen Prüfungsformen; Studiengänge der Variante 2 haben
    einen zweiten Meldezeitraum (nicht für VbP). Die Zeiträume stehen je Studiengang unter „Termine“.
  - Module aus anderen Studiengängen behalten die Variante des anbietenden Studiengangs.
  - Anmeldung online im QIS (Juristische Fakultät: JUPS – dafür zeigt StudiNow nur den Link).
  - „Angemeldete Prüfungsleistungen erscheinen auf dem Notenspiegel mit dem Vermerk AN“, Abmeldung über QIS: Vermerk „AMD“.
  - Abmeldefristen: Klausur/Klausur mit Antwortwahl 7 Tage vor dem Prüfungstermin (im QIS); Mündliche Prüfung und
    Sportpraktische Präsentation 1 Tag vorher (schriftlich/E-Mail); VbP und Leistungen mit Abgabe bis zum Beginn;
    Abschlussarbeiten keine Abmeldung. Fristen kalendertagsgenau (BGB §§ 187, 188).
  - Bachelor-, Master- und Studienarbeiten haben keinen Meldezeitraum.
- Terminseiten je Studiengang: `https://www.uni-hannover.de/studium/im-studium/pruefungsinfos-fachberatung/<studiengang>/termine`
  (96 Seiten laut Sitemap; alle stehen als Link in der Datendatei, Daten nur für die geprüften).

Geprüft (gleiche Tabelle bei allen Variante-1-Seiten):

| Studiengang (Terminseite) | Variante |
|---|---|
| technische-informatik-bsc, technische-informatik-msc | 1 |
| informatik-bsc, informatik-msc | 1 |
| elektrotechnik-und-informationstechnik-bsc | 1 |
| maschinenbau-bsc | 1 |
| mathematik-bsc | 2 |

Gefundene Zeiträume (Variante 1):

| Semester | Zeitraum | von | bis |
|---|---|---|---|
| WiSe 26/27 | Meldezeitraum VbP | Mo 19.10.2026 | So 01.11.2026 |
| WiSe 26/27 | Prüfungszeitraum VbP | Mo 09.11.2026 | Sa 06.03.2027 |
| WiSe 26/27 | **Meldezeitraum alle anderen Prüfungsformen** | **Mo 09.11.2026** | **So 22.11.2026** |
| WiSe 26/27 | Prüfungszeitraum alle anderen | Mo 30.11.2026 | Sa 27.03.2027 |
| SoSe 27 | Meldezeitraum VbP | Mo 12.04.2027 | So 25.04.2027 |
| SoSe 27 | Meldezeitraum alle anderen | Mo 03.05.2027 | So 16.05.2027 |
| SoSe 27 | Prüfungszeitraum alle anderen | Mo 24.05.2027 | Sa 18.09.2027 |

Variante 2 (Mathematik B.Sc.): gleiche VbP- und 1. Meldezeiträume; 1. Prüfungszeitraum WiSe 30.11.2026–13.02.2027,
**2. Meldezeitraum 01.03.–07.03.2027**, 2. Prüfungszeitraum 08.03.–27.03.2027; SoSe 27: 2. Meldezeitraum
23.08.–29.08.2027. Bewertungsfristen stehen ebenfalls in der Datei. Das SoSe 2026 steht auf den Seiten ohne Jahr und ist
vorbei; es fehlt absichtlich.

Neu lesen (jedes Semester, ein paar Abrufe): Terminseiten nach `~/Studora-Builds/pruefungsanmeldung/termine-<slug>.html`
laden (≥ 2,5 s Abstand), dann `.venv/bin/python tools/gen-exam-registration-fixture.py --from-cache
~/Studora-Builds/pruefungsanmeldung` (liest Tabellen und Variante, schreibt die Datendatei) und ohne Schalter erneut
(Kern-Kopie und Fälle). Datum `checked_at` je Studiengang.

## Datenformat (`exam-registration-luh.json`)

```json
{"v": 1, "university": "luh", "checked_at": "2026-11-05",
 "general": {"url": "…/pruefungsanmeldung", "title": "…"},
 "qis_menu": "https://qis…?state=change&type=1&moduleParameter=studyPOSMenu&next=menu.vm",
 "rules": [{"form": "Klausur", "withdraw_days_before": 7, "text": "…"}],
 "tables": {"luh-v1": {"variant": "1", "terms": [{"term": "WiSe 26/27", "periods": [
     {"kind": "meldung", "n": 1, "label": "Meldezeitraum für alle anderen Prüfungsformen", "start": "2026-11-09", "end": "2026-11-22"}]}]}},
 "programs": [{"slug": "technische-informatik-bsc", "url": "…/termine", "table": "luh-v1", "variant": "1", "checked_at": "2026-11-05"},
              {"slug": "architektur-bsc", "url": "…/termine", "table": null, "variant": null, "checked_at": null}]}
```

Arten: `vbp_meldung`, `vbp_pruefung`, `vbp_bewertung`, `meldung`, `pruefung`, `bewertung` (je mit `n` 1/2).
Zuordnung Studiengang → Seite: Name aus Katalog bzw. QIS-Abschluss ohne „(PO-Version …)“, klein, Umlaute ausgeschrieben,
Leerzeichen → „-“, dazu der Abschluss („B.Sc.“ → `bsc`, „M.Sc.“ → `msc`, „B.A.“ → `ba`, „M.A.“ → `ma`, „M.Ed.“ → `med`;
fehlt er, „Bachelor“/„Master“ aus dem QIS-Text). Kein Treffer → allgemeine Seite als Link.

Erzeuger `tools/gen-exam-registration-fixture.py [--check]`: prüft die Datei (Daten, Reihenfolge, Verweise, nur
https auf www.uni-hannover.de), schreibt die Kopie im Kern (`ExamRegistrationData.swift`) und
`fixtures/exam-registration/period-cases.json` (Zuordnung und Phase je Tag aus `app/exam_registration.py`, gegen den
Kern geprüft). Python hat nur diesen Teil (Daten, Zuordnung, Phase) – siehe „Lücken“.

## Phase des Meldezeitraums

Je Art (`meldung`, `vbp_meldung`) das Fenster, das heute läuft, sonst das nächste: `open` (Start ≤ heute ≤ Ende,
`days_left`), `soon` (beginnt in höchstens 7 Tagen, `days_until`), `later`, oder keins (Daten zu alt → nur Link).
Semester des Fensters = Semester, für das vorgeschlagen wird. Karte auf der Übersicht bei `open` oder `soon` des
Fensters `meldung` (VbP nur, wenn es selbst offen ist).

## Endpunkt (nur lokal, Kern)

`GET /api/exam-registration` →
`{supported, university, program{name, degree, slug, url, verified, variant}, source{url, general_url, checked_at},
term, window, vbp_window, periods[], show_card, plan_available, plan_message, suggestions[], registered[],
registrations_checked_at, registrations_message, open_count, registered_count, warnings[], qis_url, hint, rules[],
disclaimer}`; je Vorschlag `{id, title, lp, exam, kind, fachsemester, reason, reason_kind (plan|nachholen|wiederholung|
klausur), exam_date, exam_time, exam_room, exam_source, registered, registered_via (notenspiegel|qis_info), period
(meldung|vbp), withdraw_until, withdraw_rule, app_module_ids, last_attempt}`.

Gespeichert (erst bei Bedarf angelegt, nur Gerät): Tabelle `exam_registrations` (Zeilen der Info-Seite, je Abruf
ersetzt) und `settings.exam_registration_run` (`{at, ok, count, message}`).

## QIS „Info über angemeldete Prüfungen“ (am 10.11.2026 am echten Konto gesehen)

**Stand 10.11.2026** (Meldung des Inhabers: „wenn man Klausuren anmeldet, erkennt die App das nicht“): mit der Anmeldung
des Inhabers nur lesend gesehen, nichts an- oder abgemeldet, kein PDF erzeugt. Ursache: Die echte Tabelle heißt in den
Kopfzeilen **„PrfNr.“** und **„Prüfungsbezeichnung“**; beide Wörter kannte der Leser nicht, fand deshalb keine Tabelle
und meldete „Im QIS sind keine Prüfungen angemeldet“. Behoben in `app/qis_registrations.py` und
`UniFlowCore/ExamRegistration/QISRegistrations.swift` (gleiches Verhalten), geprüft an anonymisierten Kopien der echten
Seiten (`packages/shared-contracts/fixtures/exam-registration/qis-echt-*.html`).

Echter Weg: Startseite (ohne `asi`) → „Mein Studium“ (`moduleParameter=studyPOSMenu`) → „Info über angemeldete
Prüfungen“ (`state=examsinfosStudent&next=tree.vm`) → Baum „Abschluss …“ (`nodeID=…abschl=…`, `expand=0` klappt auf,
`expand=1` wieder zu; der Zustand des Baums liegt in der Sitzung des Servers) → Bild-Link je Studiengang
(`next=list.vm…|studiengang:stg=…`, Titel „angemeldete Prüfungen anzeigen für …“) → Tabelle mit den Spalten PrfNr.,
Prüfungsbezeichnung, Prüfer/in, Semester (Termin), Anmeldedatum, Rücktritt über QIS möglich bis, Prüfungsdatum.
Der Leser folgt zuerst Listen-Links, klappt nie wieder zu (`expand=1`) und geht nie zu einem Elternknoten zurück.
Auf der Listenseite stehen ein PDF-Link (`state=hisreports`) und ein Formular: beides wird nie benutzt.

Der Leser bleibt absichtlich tolerant (erfundene Seiten `qis-*.html` für andere Formen):

- Weg: Startseite → „Mein Studium“ → Link mit Text „Info über angemeldete Prüfungen“ (auch „angemeldete Prüfungen“,
  Bild-alt/title) → Tabellen lesen; gibt es keine, Baum aufklappen: Links mit gleichem `state` wie der Info-Link und
  `nodeID`, oder wieder mit Text „angemeldete Prüfungen“; höchstens 12 Seiten.
- **Nie** gefolgt: Text oder Adresse mit „anmeldung“ (ohne „angemeldet“), „abmeld“, „rücktritt“, „anmelden“, `state`
  mit „anm“/„abm“/„prfan“, Bescheinigungen (`verpublish`), PDF (auch `hisreports`), Abmelden. Keine Formulare, nur
  GET der Links.
- Tabelle: Kopfzeile mit Prüfungstext und mindestens einer von Prüfungsnr./Datum/Semester, ohne Spalte „Note“.
  Spalten (erstes Wort): Prüfungsnr./PrfNr./Nr., Prüfungstext/Prüfungsbezeichnung/Text/Bezeichnung/Prüfung/Titel/Veranstaltung/Modul,
  Semester, Datum/Prüfungsdatum/Termin, Uhrzeit/Zeit/Beginn, Raum/Ort, Prüfer/Prüfende, Versuch, Status/Vermerk,
  Rücktritt/Abmeldung/Abmeldefrist, Form/Prüfungsform/Art. Stammdaten-Zeilen und -Tabellen werden nie gelesen.
  Status AMD/abgemeldet/RT… → nicht angemeldet; leer, AN, angemeldet, zugelassen → angemeldet.
- „Keine Prüfungen angemeldet“ ist kein Fehler (0 Zeilen, Abruf gelungen).
- Zuordnung zu Modulen: Prüfungsnummer = Modulkürzel, sonst Namensschlüssel wie der Studienverlauf.

### Was der Inhaber einmal am echten Konto prüfen muss

1. App öffnen, QIS verbinden (selbst anmelden), Übersicht → Karte „Prüfungsanmeldung“ (oder Studienverlauf).
2. „Angemeldete Prüfungen abrufen“ tippen. Erwartung: Meldung „n angemeldete Prüfungen gelesen“ ohne Fehler.
   Bei „Seite nicht gefunden“: im In-App-Browser selbst „Mein Studium“ → „Info über angemeldete Prüfungen“ öffnen und
   notieren (ohne persönliche Daten): Linktext, Parameter `state`/`next`/`nodeID` in der Adresse, ob ein Baum kommt,
   Spaltenköpfe der Tabelle, Text bei keiner Anmeldung.
3. Nach einer eigenen Anmeldung im QIS (selbst geklickt) erneut abrufen: das Modul muss „angemeldet“ zeigen. Prüfen,
   ob der Notenspiegel die Prüfung mit „AN“ führt (dann hakt schon der normale Notenabruf ab).
4. „Im QIS zur Prüfung anmelden“ tippen: Erwartung „Mein Studium“ mit dem Punkt „Prüfungsanmeldung/-abmeldung“ (QIS braucht dafür
   evtl. den Sitzungsparameter `asi`; kommt die Startseite, ist das nur ein Schritt mehr). Nichts davon füllt die App aus.
5. Mitteilung: Einstellungen des iPad → StudiNow → Mitteilungen erlaubt; am 15.11. und 20.11.2026 um 9:00 Uhr kommen
   die Erinnerungen an das Ende am 22.11. (Schalter in der Karte).

## Lücken (bewusst)

- ~~**Python/PC und Web**~~ **seit 05.11.2026 am PC (Windows-App/Einzelplatz):** `GET /api/exam-registration`
  (`app/exam_registration_api.py`, gleiche Antwort und Fälle wie der Kern, dazu `reminders`), Leser der Info-Seite
  (`app/qis_registrations.py`, gleiche Sperrliste, mit den erfundenen Seiten getestet) läuft im normalen QIS-Abruf mit
  (`app/qis.py`, nur LUH, nie im Dienst); „Angemeldete Prüfungen abrufen“ stößt diesen Abruf an. Web: Karte auf der
  Übersicht, Abschnitt im Studienverlauf, Block am Modul (Moduldetail und Modulseite), Abzeichen in „Nächste Klausuren“
  (`app/static/exam-registration.js`). Erinnerungen am ersten Tag, 7 und 2 Tage vor dem Ende als Hinweis in der App;
  sind in der Windows-App die Erinnerungen an (`due-reminders.js`, Tauri-Plugin), einmal auch als Windows-Mitteilung.
  Im Dienst `supported=false`. app-paths.json bleibt unverändert (Form gleich). Tests: `tests/test_exam_registration_api.py`.
- Daten nur für sieben geprüfte Studiengänge; alle anderen zeigen den Link ihrer Terminseite.
- Module aus anderen Studiengängen können eine andere Variante haben (Hinweis im Text, keine Daten je Modul).
- ~~Uni Hildesheim: nicht unterstützt~~ **seit 05.11.2026 unterstützt**, siehe „Uni Hildesheim“ unten.

## Umsetzung (05.11.2026)

- Daten: `packages/shared-contracts/exam-registration-luh.json` (96 Terminseiten, 7 mit Daten), Erzeuger
  `tools/gen-exam-registration-fixture.py`, Python `app/exam_registration.py`, Fälle
  `fixtures/exam-registration/period-cases.json`, erfundene QIS-Seiten `fixtures/exam-registration/qis-*.html`.
- Kern (`UniFlowCore/ExamRegistration/`): `ExamRegistrationPeriods` (Daten, Zuordnung, Phase), `QISRegistrations`
  (Leser, Weg, Sperrliste, Speicher, Abruf), `ExamRegistrationAPI` (Antwort), `ExamRegistrationReminders` (Plan der
  Mitteilungen), Endpunkt `ExamRegistrationEndpoints`.
- App: `Views/Exams/ExamRegistrationViews.swift` (Karte, Abschnitt, Modulblock, Knöpfe, Zeile unter „Nächste
  Klausuren“), `Services/ExamRegistrationReminderScheduler.swift` (Schalter „An die Prüfungsanmeldung erinnern“,
  Vorgabe an, Erlaubnis nur beim Einschalten), `QISConnection.fetchRegistrations()` und Abruf im normalen QIS-Lauf,
  `DueNotificationDelegate` zeigt und öffnet auch diese Mitteilungen (`#/studyplan`).
- Nebenbei behoben: Die Karte „Nächste Klausuren“ lud nie, weil `.task` an einer leeren Ansicht hing (ohne Klausuren
  zeigt die Liste nichts, also startete das Laden nie); jetzt hängt das Laden an einem festen Behälter.
- Tests: Kern `ExamRegistrationTests` (11), App `ExamRegistrationAppTests` (6), Python `tests/test_exam_registration.py`
  (6); `app-paths.json` kennt `GET /api/exam-registration` als „nur auf dem Gerät“.

## Uni Hildesheim (05.11.2026)

Gleiche Hilfe wie bei der LUH, mit den Eigenheiten der Uni Hildesheim. Anmelden und abmelden tut immer der Mensch
selbst im LSF; StudiNow öffnet nie „An-/Abmeldung zu Studien-/Prüfungsleistungen“, „Zur Anmeldung“ oder „Zur
Stornierung“.

### Was die öffentlichen Seiten sagen (gelesen am 05.11.2026, ohne Anmeldung)

robots.txt von www.uni-hildesheim.de erlaubt die Seiten für alle Programme (gesperrt nur /intranet/, /personal/, /wiki/
u. a.; **`ClaudeBot` ist dort ganz ausgeschlossen** – die Abrufe liefen als nutzergesteuerte Einzelabrufe mit
eigener Kennung, nicht als Crawler). Zehn Abrufe nacheinander im Abstand von ≥ 3 s, abgelegt unter
`~/Studora-Builds/hildesheim/pruefungsanmeldung/` (nicht im Repository). Learnweb, LSF und CAS wurden nicht angefragt.

| Seite | Inhalt |
|---|---|
| [Prüfungsamt 2: Fragen zu Prüfungs-/Studienleistungen](https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/pruefungsamt-2/fragen-zu-pruefungs-studienleistungen/) | „Ab dem 11. November 2026 ist im LSF die POS-Anmeldung … für das Wintersemester 26/27 für alle Bachelor- und Masterstudiengänge freigeschaltet (mit Ausnahme einiger Weiterbildungsmaster).“ Abmeldung unverbindlicher Anmeldungen im selben Semester, ausnahmsweise bis 3 Semester rückwirkend; ältere werden NB. |
| [LSF-Termine (IT-Abteilung)](https://www.uni-hildesheim.de/dez3/it-abteilung/lsf-vergabe/lsf-termine/) | 11.11.2026 „Beginn der POS Anmeldephase“ |
| [Häufige Fragen zur POS-Anmeldung](https://www.uni-hildesheim.de/posanmeldung/haeufige-fragen-zur-online-anmeldung-zu-studien-pruefungsleistungen/) | **Keine universitätsweit einheitlichen Fristen**; Anmeldungen mit Frist sind verbindlich (das LSF zeigt, bis wann man sich abmelden kann), ohne Frist unverbindlich und jederzeit stornierbar. Nachklausuren im Semester der ursprünglichen Veranstaltung anmelden. Freischaltung „typischerweise in der dritten Woche der Vorlesungszeit“. Übersicht: Meine Funktionen → POS-Management → **Meine POS-Anmeldungen** (bei Klausuren mit Ort und Zeit). Das LSF schickt wenige Tage vor Ablauf befristeter Anmeldungen Erinnerungs-E-Mails. |
| [Schnellanleitung](https://www.uni-hildesheim.de/posanmeldung/howto-schnellanleitung-zur-online-pruefungsanmeldung/) | LSF → Meine Funktionen → POS-Management → „An-/Abmeldung zu Studien-/Prüfungsleistungen“ → Hinweise bestätigen → Semester, Modul/Teilmodul, Veranstaltung → „Zur Anmeldung“ bzw. „Zur Stornierung der Anmeldung“ → bestätigen. |
| [Semesterzeiten](https://www.uni-hildesheim.de/termine-fristen/semesterzeiten-in-reintext-zum-barrierefreien-aufruf/) | WiSe 2026/27: 01.10.2026 – 31.03.2027 (Ende des Fensters, keine Anmeldefrist) |
| [Zuständigkeiten nach Studiengängen](https://www.uni-hildesheim.de/studium/studierende/pruefungsamt/zustaendigkeiten-nach-studiengaengen/) | Prüfungsamt je Studiengang (Link je Eintrag) |
| [Institut für Technik: Wissenswertes zu Prüfungen](https://www.uni-hildesheim.de/fb4/institute/institut-fuer-technik/studium-lehre/wissenswertes-zu-pruefungen/) | Nur dieses Institut: Klausuranmeldung bis 2 Wochen vor dem Prüfungszeitraum; Daten auf der Seite sind von 2025 → **nicht übernommen** |

Ergebnis: **ein** bekannter Termin (Start der POS-Anmeldung WiSe 26/27 am 11.11.2026, alle Bachelor/Master), **kein
Ende** (Fristen je Prüfung im LSF). SoSe 27 ist noch nicht veröffentlicht („typischerweise Ende April“ ist kein Datum)
→ ab 01.04.2027 nur der Link. 71 Studiengang-Einträge aus den Zuständigkeiten (63 mit POS-Start, 8 nur Link:
Weiterbildung, Diplom/Magister ausgelaufen, Zugangsprüfung, Austausch, Staatliche Anerkennung) plus ein Eintrag
`default` „Alle Bachelor- und Masterstudiengänge“ für alle anderen.

### Daten (`exam-registration-hildesheim.json`)

Gleiches Format wie die LUH-Datei, dazu: `system: "LSF"`, `hint`, `disclaimer`, `period_note` (Texte der Uni),
`sources[]` (`url`, `title`, `says`, `checked_at`), je Zeitraum `open_end: true` und `source`, je Studiengang `name`,
`faculty`, `url` = Seite des Prüfungsamts, und ein Eintrag mit `default: true`. Regeln ohne `withdraw_days_before`
(nie eine Rücktrittsfrist erfinden). Erzeuger: `.venv/bin/python tools/gen-exam-registration-fixture.py
--from-cache-hildesheim ~/Studora-Builds/hildesheim/pruefungsanmeldung` (liest die gespeicherte Zuständigkeiten-Seite;
Zeiträume, Regeln und Texte stehen im Erzeuger als `HILDESHEIM_*`), danach ohne Schalter bzw. `--check`. Kern:
`ExamRegistrationData.luh` / `.hildesheim`, `ExamRegistrationPeriods.for(university:)`, `resolve(name:degree:)`;
Python `exam_registration.for_university`, `resolve_program`.

### Verhalten

- Antwort mit `system: "LSF"`, `open_label: "Im LSF zur Prüfung anmelden"`, `period_note`; `qis_url` = LSF-Startseite
  (`UniversityProfile.hildesheimLSFStart`, im In-App-Browser). Fenster `open_end`: keine Warnung „endet in“, Karte auf der
  Übersicht nur 7 Tage vor bis 14 Tage nach dem Start (`ExamRegistrationAPI.openEndCardDays`), Erinnerung nur am ersten
  Tag (11.11.2026, 9:00), der Hinweis in der Web-App bis 14 Tage danach. Rücktritt: nur, was das LSF in „Meine
  POS-Anmeldungen“ zeigt (`withdraw_until` aus der Zeile), sonst nichts.
- Abhaken: Notenspiegel-Status „angemeldet“ (wie im Live-Test-Fixture) und **„Meine POS-Anmeldungen“** – im Kern im
  Notenspiegel-Schritt von `HildesheimSync` (nach dem Notenspiegel, Fehler ändern den LSF-Stand nicht), Knopf
  „Angemeldete Prüfungen abrufen“ (`HildesheimConnection.fetchRegistrations`), am PC in `qis.run` (Profil hildesheim).
  Weg: Start → Link „POS-Management“ → Link „Meine POS-Anmeldungen“ (nur über den Text; die Ausnahme in der Sperrliste
  gilt nur für genau diesen Text, Parameter mit „abmeld“, „storn“, „prfanm“ bleiben gesperrt). Tabelle wie im
  Notenspiegel („Abschluss: …“-Zeile, „Prüfungsnr.“, „Bezeichnung der Leistung …“); Status zugelassen/AN → angemeldet,
  storniert/abgelehnt/nicht zugelassen → nicht. Erfundene Seiten `fixtures/exam-registration/lsf-*.html`.
- Klausurtermine („Nächste Klausuren“, `Exams`/`app/exams.py`): neue Quelle `anmeldung` – gelesene Anmeldungen mit
  Termin (Uhrzeit, Raum) aus „Meine POS-Anmeldungen“ bzw. „Info über angemeldete Prüfungen“ (gilt auch für die LUH).
  Für Hildesheim zählen außerdem: Klausurtermin am Modul, Learnweb-Fristen mit „Klausur“/„Prüfung“ im Namen (auch
  `test_ende`/`test_beginn`), Learnweb-Ankündigungen eines Kurses, in Dateien erkannte Klausuren. **Nur LUH:**
  Stud.IP-Termine mit Art „Klausur“, Stud.IP-Nachrichten, Notenspiegel-Zeilen „AN“ mit Datum (der Hildesheimer
  Notenspiegel hat keine Datumsspalte). Nicht genutzt: Klausurtermine im LSF-Stundenplan (iCal) – die Serien landen im
  Stundenplan, nicht in „Nächste Klausuren“.

### Was der Inhaber einmal am echten Hildesheimer Konto prüfen muss

1. LSF verbinden (selbst anmelden), Abgleich laufen lassen; Statusleiste: „n angemeldete Prüfungen gelesen.“ oder
   „Angemeldete Prüfungen: Die Seite „Meine POS-Anmeldungen“ wurde im LSF nicht gefunden.“ Im zweiten Fall im
   In-App-Browser selbst Meine Funktionen → POS-Management → Meine POS-Anmeldungen öffnen und notieren (ohne
   persönliche Daten): genauer Linktext beider Links, Parameter `state`/`moduleParameter`/`next` in der Adresse,
   Spaltenköpfe, Text der Statusspalte (zugelassen? AN?), Text ohne Anmeldung, ob die Seite einen Baum je Semester hat.
2. Notenspiegel: Steht eine angemeldete, noch nicht bewertete Prüfung mit Status „angemeldet“ (oder „AN“) darin?
3. „Im LSF zur Prüfung anmelden“: Erwartung Startseite des LSF (Meine Funktionen); weiter über POS-Management selbst.
4. Ab 11.11.2026: Karte „Prüfungsanmeldung“ auf der Übersicht, Mitteilung um 9:00 Uhr; nach dem 25.11. keine Karte mehr,
   der Abschnitt im Studienverlauf bleibt.
5. Neu lesen vor dem SoSe 27: FAQ von Prüfungsamt 2 und LSF-Termine (Start der POS-Anmeldung), dann
   `HILDESHEIM_TABLES` im Erzeuger ergänzen.
