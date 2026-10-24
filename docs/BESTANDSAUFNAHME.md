# Bestandsaufnahme und Go-live-Blocker (Stand 24.10.2026)

## 1. Was es gibt

| Bereich | Technik | Dateien |
| --- | --- | --- |
| Server | Python 3.14, FastAPI, SQLite (WAL), Playwright für Stud.IP/QIS | `app/server.py`, `app/db.py` |
| Stud.IP-Sync | WebSSO-Login, JSON-API (Kurse, Termine, Ordner), Datei-Downloads, 8:00/15:00 per Aufgabenplanung | `app/studip_sync.py`, `sync.py`, `scripts/install_schedule.ps1` |
| Weboberfläche | Vanilla-JS-Module, kein Framework | `app/static/*.js`, `style.css` |
| PDF-Editor | pdf.js 4.8 (Anzeige), Konva 9 (Objekte), eigene Stifteingabe, pdf-lib (Export) | `app/static/editor.js`, `editor.css` |
| Notizen | JSON-Modell v2 je Datei, 30 Versionen, Konflikterkennung `base_version` | `annotations`, `annotation_versions` |
| KI | Claude Code CLI (`claude -p`) für Analyse, Wochentests, Tutor | `app/ai.py`, `app/planner.py` |
| Lernplanung | Module, Lehrwochen, Lernpakete, freie Fenster aus dem Stundenplan | `app/study.py`, `app/timetable.py` |
| QIS | Notenspiegel, Bescheinigungen | `app/qis.py` |
| iPad-Zugriff | `serve.py --lan`, PIN-Schutz, PWA-Manifest | `serve.py`, `app/server.py` |
| Native iPad-App | Etappe 1 (ungetestet) | `apps/apple` |

**Nicht vorhanden:** Benutzerkonten, Anmeldung, Mandantentrennung, Free/Plus/Pro-Tarife, Zahlungen, gehosteter
Server, HTTPS. Die App ist eine Einzelperson-Installation auf dem eigenen PC. Punkte des Auftrags, die darauf
aufbauen (Berechtigungen, Tarif-Umgehung, KI-Kontingente pro Tarif, Abo-Freischaltung), sind deshalb keine Fehler
der heutigen App, sondern fehlende Voraussetzungen für einen Store-Start.

## 2. Blocker-Liste

Spalten: Priorität · Befund · Reproduktion · Ursache · Dateien · Korrektur · Test · offen.

| P | Befund | Reproduktion | Ursache | Dateien | Korrektur | Test | Offen |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Doppelte Striche, zunehmend langsameres Schreiben | Seite aus dem Bild scrollen und zurück, dann schreiben | Stift-Listener wurden bei jedem Einblenden erneut angehängt (seit 2.6) | `editor.js` | einmal pro Seite (`pg._nativeInk`) | Desktop: 3× aus/einblenden → 1 Strich = 1 Objekt | iPad-Test |
| P0 | Safari-Absturz („wiederholt ein Problem“) | lange schreiben, zoomen | bis zu 7 große Canvas je Seite, Neuanlage bei jeder Zoom-Bewegung; Safari-Canvas-Limit | `editor.js` | Pixel-Budget je Canvas, Hit-Canvas kleiner, Zoom zuerst nur CSS | Desktop: 1 geladene Seite belegt 18 MPx Canvas (Vorher-Wert nicht gemessen) | iPad-Test |
| P0 | Datenverlust bei unbekannten Feldern | Datei mit iPad-Feldern im Browser speichern | `migrate()` übernahm nur bekannte Felder | `editor.js` | unbekannte Felder bleiben | `test_annotations_keep_unknown_fields` | – |
| P0 | Veralteter Stand überschreibt neueren | zwei Geräte speichern dieselbe Datei | – (war korrekt: 409) | `server.py` | – | `test_annotations_conflict_does_not_overwrite` | – |
| P1 | „Unerwarteter Dateityp text/x-python – keine PDF“ | `.py`/`.zip`/`.gif` aus Stud.IP öffnen | jede Stud.IP-Datei bekam `kind='pdf'` | `db.py`, `studip_sync.py`, `views-doc.js` | Art aus Endung/MIME, Datenbank korrigiert (7 Dateien, 1 Bild) | `test_file_kind_*`, `test_db_migration_*` | – |
| P1 | Seite springt/rutscht beim Schreiben und Abheben | Handballen auflegen, schreiben, abheben | Handballen startete Finger-Scrollen mit Schwung; Statusleiste änderte Höhe | `editor.js`, `style.css` | Handballen-Erkennung, feste Leistenhöhen, kein Seitenscroll | Desktop: 100 Striche, 0 px Verschiebung | iPad-Test |
| P1 | Safari markiert Seitentext | Pencil lange auf die Seite halten | kein `user-select:none`, Touch-Standardaktionen aktiv | `editor.css`, `editor.js` | Markieren/Lupe/Seiten-Zoom auf der Schreibfläche aus | Desktop: CSS geprüft | iPad-Test |
| P1 | PIN per Durchprobieren erratbar | viele `?pin=`-Aufrufe aus dem WLAN | keine Begrenzung | `server.py` | 8 Fehlversuche → 10 min Sperre | `test_lan_pin_guard` | Server-Neustart nötig |
| P1 | Zugangsdaten im Klartext auf der Platte | `.env` öffnen | Einzelplatz-Design | `.env` | – | Suche: kein Passwort außerhalb `.env` (Logs, Code) | vor Store-Start: Keychain/Windows-Anmeldeinformationen |
| P2 | Lernpakete gleicher Titel am selben Tag | Lernkalender 18./19.11. | Paket-Titel = Thema der Woche, Inhalte verschieden | `study.py` | keine (kein Duplikat) | DB-Prüfung | Titel aussagekräftiger |
| P2 | Kalender: Termine überlagern sich, Namen abgeschnitten | Woche auf dem iPad | volle Spaltenbreite je Termin | `views-plan.js` | Spuren nebeneinander, Kurznamen, 3-Tage-Ansicht | Sichtprüfung Desktop | – |

Geprüft ohne Befund: doppelte Kurse, Dateien, Termine, Wochentests (eindeutiger Index), Noten. Passwörter in Logs
und Code: keine Fundstelle. Logs: keine Tracebacks; Sync-Fehler nur aus der Ersteinrichtung.

## 3. Tests

```bash
.venv\Scripts\python.exe -m pytest -q tests
```

6 Regressionstests (Temp-Datenordner über `LERNAPP_DATA_DIR`, die echte Datenbank wird nie berührt).
Editor-Tests liefen im Desktop-Browser mit simulierten Stift- und Fingerereignissen; **kein Test auf einem echten iPad.**

## 4. Offene Risiken

- Alle Stift-Korrekturen sind auf dem iPad unbestätigt.
- Web-Editor auf dem iPad bleibt durch Safari begrenzt; die native App (`apps/apple`) ist ungetestet.
- Gedrehte PDF-Seiten in der nativen App: Koordinaten nicht geprüft.
- Kein HTTPS, keine Konten: nur im eigenen WLAN mit PIN nutzen, nicht ins Internet stellen.
