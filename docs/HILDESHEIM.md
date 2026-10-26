# Uni Hildesheim in UniFlow

Hochschule: `UNIVERSITY=hildesheim` in der `.env` (oder **Einstellungen → Zugang & Darstellung → Hochschule**, gilt
nach einem Neustart). Werte `luh` | `hildesheim`, siehe `app/universities.py`.

## Trennung der Hochschulen

- Jede Uni hat einen eigenen Datenordner: LUH `data/` (wie bisher), Hildesheim `data/unis/hildesheim/`
  (Datenbank, Dateien, Browser-Profile); Protokolle ebenso unter `logs/unis/hildesheim/`.
- Eine laufende App arbeitet nur mit einer Uni. Ein Wechsel wird in der `.env` vorgemerkt und greift beim Neustart.
- Jede Datenbank merkt sich ihre Uni (`settings.university`). Passt sie nicht zur laufenden Uni, bricht der Start mit
  `UniversityMismatch` ab, statt Daten zu mischen.
- Zugangsdaten: eigene Präfixe pro Uni in der `.env`, kein Rückfall von Hildesheim auf die LUH-ID.

| Funktion | LUH | Hildesheim | Code |
|---|---|---|---|
| Kurse, Dateien, Ordner/Woche | Stud.IP | Learnweb (Moodle) | `app/learnweb.py`, `app/hildesheim.py` |
| Persönlicher Stundenplan | Stud.IP-Termine | LSF iCal-Export des Plans | `app/lsf.py` |
| Notenspiegel | QIS (+ Bescheinigungen) | LSF (ohne Bescheinigungen) | `app/qis.py` Profil `hildesheim` |
| Login | WebSSO (Shibboleth) | CAS (`https://www.uni-hildesheim.de/sso`) | `app/cas.py` |

## Zugangsdaten (nur lokale `.env`)

- `HILDESHEIM_USER` / `HILDESHEIM_PASSWORD`: UNI-Account. Kein Rückfall auf die LUH-ID (`config.own_credentials`).
- `LEARNWEB_TOKEN` (optional): selbst erzeugter Sicherheitsschlüssel „Moodle mobile web service“
  (Learnweb → Profil → Einstellungen → Sicherheitsschlüssel). Wird nur beim Download an die URL gehängt,
  nie in DB oder Log geschrieben.
- `HILDESHEIM_SEMESTER_FILTER` (optional): nur Learnweb-Kurse, deren Semester den Text enthaelt. Der LUH-Filter
  `SEMESTER_FILTER` gilt fuer Hildesheim nicht (beim Live-Test filterte "WiSe 2026/27" alle 9 SoSe-Kurse weg).

## Learnweb

- **Die Instanz wechselt jährlich** (`learnweb2026` = „SoSe 2026 - WiSe 2026/27“). Der Sync fragt die öffentliche
  Moodle-Schnittstelle von Vorjahr, aktuellem und nächstem Jahr und nimmt die Instanz, deren Name das aktuelle Semester
  nennt (`learnweb.discover_base`); im Januar also noch die Vorjahres-Instanz. Notfalls `HILDESHEIM_LEARNWEB_URL`.

- Mit Schlüssel: REST `core_webservice_get_site_info` → `core_enrol_get_users_courses` → `core_course_get_contents`.
  Änderungserkennung über `timemodified`. Moodle verbucht keine Aufrufe.
- Ohne Schlüssel: CAS-Login im Playwright-Profil `data/browser-profile-hildesheim`, AJAX
  `core_course_get_enrolled_courses_by_timeline_classification` + `core_courseformat_get_state`.
  `core_course_get_contents` ist für AJAX gesperrt (geprüft 25.10.2026), daher Dateilinks über
  `mod/resource/view.php?redirect=1` (nur Weiterleitung) und die Ordnerseite. Änderung = Revision im Pluginfile-Pfad.
  Moodle verbucht dabei einen Aufruf je Material.
- Kurs-IDs `lw-<moodle-id>`, Datei-IDs `lw-<cmid>-<hash>`. Kursname „SoSe 2026: 9406 Titel“ → Semester + Vst.-Nr.
- Abschnitte mit reiner Zahl werden zu „Woche N“ (Wochenerkennung im Lernplan).

## Learnweb-Fristen (Abgaben, Tests)

- Beim Sync nach den Dateien, beide Wege (Schlüssel und Sitzung), nur lesend. `core_calendar_get_calendar_events` ist
  für AJAX gesperrt (geprüft 26.10.2026), deshalb zwei Quellen derselben Ereignis-Form:
  `core_calendar_get_action_events_by_timesort` (offene Fristen von gestern bis +200 Tage, seitenweise über
  `aftereventid`, erledigte Aufgaben fehlen) und `core_calendar_get_calendar_upcoming_view` (Vorschau, auch „Test
  beginnt“; ein Fehler dort wird ignoriert). Doppelte Ereignis-IDs werden zusammengefasst (`learnweb.deadlines_from_events`).
- Arten: Aufgabe fällig → `abgabe`, Test endet/beginnt → `test_ende`/`test_beginn`, andere Aktivität fällig/schließt →
  `frist`, sonst `termin`. Zeit lokal `YYYY-MM-DDTHH:MM` (Europe/Berlin), Titel = Aktivitätsname.
- Tabelle `deadlines` (`id` = `lw-ev-<Ereignis-id>`, Kurs `lw-<id>`). Was im abgefragten Fenster nicht mehr kommt,
  wird entfernt (gelöscht oder abgegeben); ältere Fristen bleiben. Ein Fehler beim Kalender meldet „Learnweb-Fristen:
  FEHLER …“, der Sync läuft weiter.
- Titel ohne angehängte Zeitangabe in Klammern („Bonustest Teil 1 (verfügbar vom … bis …)“ → „Bonustest Teil 1“), voller
  Name in `full_title` (Tooltip).
- Anzeige: Startseite „Nächste Termine“ (mit Uhrzeit, Art und Kurs, Link ins Learnweb), `GET /api/deadlines`, und in
  Lernkalender (Woche, Monat, Tag, Mini-Kalender) und Stundenplan je Tag (`deadlines` an jedem Kalendertag).
- Live 26.10.2026: 5 Fristen (2× Test beginnt, 2× Test endet, 1 Abgabe), alle mit Kurs, zweiter Lauf ohne Doppelte.
- Überfällige, nicht erledigte Fristen: Abruf 120 Tage zurück (`overdue` von Moodle); Startseite zeigt die der
  letzten 6 Wochen rot oben, ältere (Vorsemester) nicht.
- Ferien/Feiertage stehen nicht im Learnweb; vorlesungsfreie Tage kommen aus dem LSF-Export (EXDATE).

## Ankündigungen der Lehrenden (`app/announcements.py`)

- Learnweb: nur Ankündigungsforen (Moodle-Typ `news`), erster Beitrag je Diskussion, höchstens 30 neueste je Forum.
  Mit Schlüssel über REST (`mod_forum_get_forums_by_courses`, `mod_forum_get_forum_discussions`), ohne Schlüssel über
  die Forumsseiten (Foren-Dienste sind für AJAX gesperrt, geprüft 26.10.2026). Bekannte Diskussionen werden nicht
  erneut geöffnet; im Learnweb gelöschte verschwinden. Allgemeine Diskussionsforen der Studierenden bleiben außen vor.
- Stud.IP (LUH): `/jsonapi.php/v1/courses/{id}/news` je Kurs beim Sync.
- `extract_dates` erkennt 12.11., 12.11.26, 12.11.2026, „12. November“ mit Uhrzeit danach; Art aus dem Satzteil
  (Ausfall?, Verlegung?, Raum, Frist, Prüfung, Online, Termin). Die App ändert dadurch **nie** Termine selbst, sie
  zeigt Hinweise an den Kalendertagen (`notices`), auf der Startseite („Ankündigungen“) und unter `GET /api/announcements`.
- Live 26.10.2026: Hildesheim 14 Ankündigungen (9 mit Termin), LUH 23 (15 mit Termin, 19 Kalendertage mit Hinweis).

## LSF-Bemerkungen und Platzhalter

- Die Bemerkung steht im iCal als DESCRIPTION und wird in `event_notes` gespeichert (eigene Tabelle, damit
  `course_events` und alle Antworten unverändert bleiben). Termine mit „nur aus technischen Gründen angezeigt“ werden
  einmalig auf „nicht besuchen“ gestellt; stellt der Nutzer sie wieder auf „besuchen“, bleibt das.
- Dienste-Link „Heute im LSF“: die Variante `type=1` liefert im LSF eine Fehlerseite, `type=0` mit Navigation geht.

## Feiertage und vorlesungsfreie Zeit (`app/holidays.py`)

- Keine Quelle liefert eine Ferienliste. Gesetzliche Feiertage in Niedersachsen werden berechnet; Vorlesungszeiten
  und Unterbrechungen stehen als Tabelle aus den offiziellen Zeitplänen (Hildesheim: PDFs unter „Termine und Fristen“
  bis SoSe 2030; LUH: Seite „Semestertermine“ bis WiSe 2028/29). Neue Semester dort nachtragen.
- Jeder Kalendertag hat `marks` (`feiertag`, `pause`, `vorlesungsfrei`); Feiertage und Pausen grün, vorlesungsfreie
  Zeit hellgrün. Nach dem letzten bekannten Zeitplan wird nichts erfunden (nur Feiertage).
- Vorgabe-Semester des Stundenplans kommt jetzt aus dieser Tabelle (vorher für alle die LUH-Zeit 12.10.–30.01.).
- Serien **ohne eigene Daten** (z. B. persönliche Stud.IP-Stundenplan-Einträge) fallen an markierten Tagen aus
  (`occurrences`, nur Uni-Veranstaltungsarten, nie persönlich; Ausnahmen des Nutzers gehen vor).

## LSF-Stundenplan

- Stundenplan-Seite → Link `moduleCall=iCalendarPlan` → ICS. Der Link braucht keine Sitzung, enthält aber nur die
  Termin-Nummern und wird bei jedem Sync neu gelesen.
- Im LSF-Export ist `DTSTART` der Semesterbeginn; der Wochentag steht nur in `BYDAY`. `timetable.parse_ics`
  berücksichtigt das (auch mehrere Tage) und liefert `EXDATE` als Ausfall-Tage.
- Import nur für Quelle `lsf`: neue Serien anlegen, nicht mehr vorhandene entfernen, bestehende mit Ausnahmen behalten.
  Kurszuordnung über Vst.-Nr. **und** Semester (Nummern wiederholen sich zwischen Semestern).
- Nie auf „Anmelden/abmelden“ oder „Jetzt anmelden“ klicken (ändert echte Belegungen).

## Live-Test 25.10.2026

- CAS-Login ok, 9 Learnweb-Kurse, 539 Dateien (517 echte PDFs, keine fehlt), 24 LSF-Serien, zweiter Import ohne Doppelte,
  Notenspiegel 17 Leistungen aus zwei Abschlüssen, keine PDFs gespeichert.
- Dabei behoben: Absturz der Protokollausgabe bei U+0308 (Windows-Konsole), Dateinamen jetzt NFC, jeder Kurs in eigener
  Transaktion, LUH-Semesterfilter galt fälschlich auch für Hildesheim, Notenspiegel-Kopfzeile nicht in der ersten Zeile.

## Offen

- Bescheinigungen (Immatrikulation): Quelle in Hildesheim unbekannt, im LSF-Menü nicht vorhanden.
