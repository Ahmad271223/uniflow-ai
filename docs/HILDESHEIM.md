# Uni Hildesheim in UniFlow

Einstellung: **Einstellungen → Zugang & Darstellung → Hochschule → Universität Hildesheim**
(Setting `university`, Werte `luh` | `hildesheim`, siehe `app/universities.py`).

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

## Learnweb

- Mit Schlüssel: REST `core_webservice_get_site_info` → `core_enrol_get_users_courses` → `core_course_get_contents`.
  Änderungserkennung über `timemodified`. Moodle verbucht keine Aufrufe.
- Ohne Schlüssel: CAS-Login im Playwright-Profil `data/browser-profile-hildesheim`, AJAX
  `core_course_get_enrolled_courses_by_timeline_classification` + `core_courseformat_get_state`.
  `core_course_get_contents` ist für AJAX gesperrt (geprüft 25.10.2026), daher Dateilinks über
  `mod/resource/view.php?redirect=1` (nur Weiterleitung) und die Ordnerseite. Änderung = Revision im Pluginfile-Pfad.
  Moodle verbucht dabei einen Aufruf je Material.
- Kurs-IDs `lw-<moodle-id>`, Datei-IDs `lw-<cmid>-<hash>`. Kursname „SoSe 2026: 0406 Titel“ → Semester + Vst.-Nr.
- Abschnitte mit reiner Zahl werden zu „Woche N“ (Wochenerkennung im Lernplan).

## LSF-Stundenplan

- Stundenplan-Seite → Link `moduleCall=iCalendarPlan` → ICS. Der Link braucht keine Sitzung, enthält aber nur die
  Termin-Nummern und wird bei jedem Sync neu gelesen.
- Im LSF-Export ist `DTSTART` der Semesterbeginn; der Wochentag steht nur in `BYDAY`. `timetable.parse_ics`
  berücksichtigt das (auch mehrere Tage) und liefert `EXDATE` als Ausfall-Tage.
- Import nur für Quelle `lsf`: neue Serien anlegen, nicht mehr vorhandene entfernen, bestehende mit Ausnahmen behalten.
  Kurszuordnung über Vst.-Nr. **und** Semester (Nummern wiederholen sich zwischen Semestern).
- Nie auf „Anmelden/abmelden“ oder „Jetzt anmelden“ klicken (ändert echte Belegungen).

## Offen

- Live-Lauf mit echten Zugangsdaten: steht aus (Zugang muss der Nutzer selbst in der App eintragen).
- Bescheinigungen (Immatrikulation): Quelle in Hildesheim unbekannt, im LSF-Menü nicht vorhanden.
- Learnweb-Abgabetermine (Aufgaben/Quizze) sind noch nicht in den Kalender übernommen.
- Ein Wechsel der Hochschule mischt Daten in derselben Datenbank; für Tests eigenen `LERNAPP_DATA_DIR` nutzen.
