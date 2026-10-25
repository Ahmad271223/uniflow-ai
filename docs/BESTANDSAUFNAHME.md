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
| P0 | Stift reagiert ab und zu nicht mehr | Abheben geht verloren (iPad), dann neu aufsetzen | neues Aufsetzen mit gleicher Stift-ID wurde verworfen, solange der alte Strich als aktiv galt | `editor.js` | jedes Aufsetzen beendet den alten Strich; Abheben am Fenster, App-/Fensterwechsel setzen zurück; Speichern blockiert höchstens 15 s | Desktop: Strich ohne Abheben + neues Aufsetzen → 2 Striche; Abheben außerhalb → Strich beendet | iPad-Test |
| P1 | Pinch-Zoom wackelt | zwei Finger zoomen | jede Fingerbewegung baute Seiten neu auf und korrigierte die Position | `editor.js` | während der Geste nur CSS-Transformation, Übernahme beim Loslassen | Desktop: 3 Gesten, Punkt unter den Fingern ≤ 2 px versetzt | iPad-Test |
| P1 | Lineal lässt sich nicht bewegen/drehen | Lineal mit dem Finger ziehen | Konva-Ziehen auf einer nicht hörenden Ebene, Finger-Eingabe vorher abgefangen | `editor.js` | eigene Gesten: verschieben, Knopf, zwei Finger, Einrasten | Desktop: verschieben exakt, Knopf 30°, zwei Finger 44°→45°, Handballen bewegt nichts, beide Kanten | iPad-Test |
| P1 | Schriftbild unsauber | schreiben | Pixelrate 1,5 auf iOS, Tempo-Ausdünnung, Glättung erst beim Loslassen (Formsprung) | `editor.js` | Pixelrate 2 mit Budget, gleichmäßigere Breite, Glättung live, gleiche Zeichenroutine live und gespeichert | Desktop: Endpunkt exakt, Abweichung kleiner als das Zittern, 83 alte Striche fehlerfrei gezeichnet | iPad-Test |
| P2 | Skript-Hinweis erscheint nie | Übungsblatt öffnen | `GET /api/files/{id}` ohne `module_id` | `server.py`, `views-doc.js` | Feld ergänzt, Hinweis hängt nicht mehr davon ab | `test_file_meta_has_module_id`; Desktop: Aufgabe 2.3 → Folie 13, geteilte Ansicht | Server-Neustart |
| P2 | Lernpakete gleicher Titel am selben Tag | Lernkalender 18./19.11. | Paket-Titel = Thema der Woche, Inhalte verschieden | `study.py` | keine (kein Duplikat) | DB-Prüfung | Titel aussagekräftiger |
| P2 | Kalender: Termine überlagern sich, Namen abgeschnitten | Woche auf dem iPad | volle Spaltenbreite je Termin | `views-plan.js` | Spuren nebeneinander, Kurznamen, 3-Tage-Ansicht | Sichtprüfung Desktop | – |

Geprüft ohne Befund: doppelte Kurse, Dateien, Termine, Wochentests (eindeutiger Index), Noten. Passwörter in Logs
und Code: keine Fundstelle. Logs: keine Tracebacks; Sync-Fehler nur aus der Ersteinrichtung.

## 2a. Audit Phase 1 (25.10.2026, Zweig `develop`)

Jeder Befund ist durch einen Test belegt, der am alten Code fehlschlug (`tests/test_security.py`), oder durch den
genannten Code nachgewiesen. Server-Korrekturen wirken erst nach einem Neustart von `Start-iPad.cmd`.

| P | Befund | Reproduktion | Ursache | Dateien | Korrektur | Test | Offen |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P0 | Beliebige Dateien lesbar, z. B. `.env` mit Passwörtern | `GET /api/assets/..%5C..%5C/.env` (vom PC ohne PIN) | Datei-ID ging ungeprüft in den Pfad, Windows wertet `\` als Trenner | `server.py` | IDs/Dateinamen nur `[A-Za-z0-9_-]`, Pfad muss im Asset-Ordner liegen | `test_asset_read_rejects_path_traversal` | – |
| P0 | Beliebige Dateien schreibbar, auch `.bat` in den Autostart-Ordner | `POST /api/files/..%5C..%5C…%5CStartup/recordings` mit `x.bat` | wie oben, dazu beliebige Endung bei Aufnahmen | `server.py` | wie oben, nur Audio-Endungen | `test_recording_upload_rejects_path_traversal_and_bad_extension` | – |
| P0 | Fremde Webseiten lösen Aktionen aus (Sync, KI, Uploads; mit der Zeile darüber Code-Ausführung) | Formular-POST einer beliebigen Webseite an `http://127.0.0.1:8765` | vom PC selbst gilt keine PIN, keine Herkunftsprüfung | `server.py` | Änderungen nur mit eigener oder ohne `Origin`, sonst 403 | `test_cross_site_post_is_rejected` | – |
| P0 | DNS-Rebinding liest PIN, Noten, Dokumente | fremder Hostname löst auf 127.0.0.1 auf | Host-Kopfzeile ungeprüft | `server.py` | nur IP-Adressen, `localhost`, eigener Rechnername (auch `.fritz.box`, `.local`), sonst 421 | `test_foreign_host_header_is_rejected` | – |
| P0 | Zwei Geräte speichern gleichzeitig: beide bekommen „gespeichert“, eines ist verloren | zwei PUT mit derselben `base_version` | Versionsprüfung lief außerhalb der Schreibtransaktion | `server.py` | `BEGIN IMMEDIATE` vor der Prüfung | `test_concurrent_annotation_saves_do_not_both_win` | – |
| P1 | Passwort mit ` #` oder `${…}` wird verfälscht, Zeilenumbruch schleust Einträge ein, Absturz beim Schreiben leert die `.env` | Passwort `ab #c` speichern | Werte ungequotet, Variablen-Ersetzung an, Schreiben nicht atomar | `config.py` | Werte in Anführungszeichen, keine Ersetzung, Temp-Datei + Ersetzen, Umbrüche abgelehnt | `test_env_roundtrip_special_characters`; echte `.env` liest unverändert | – |
| P1 | Web-Editor: beim Dauerschreiben bis 20 s ohne lokalen Entwurf, Safari-Absturz verliert Striche | 5 s ohne Pause schreiben, Tab schließen | Entwurf nur zusammen mit dem Hochladen nach einer Pause | `editor.js` | Entwurf spätestens 1,5 s nach jeder Änderung, sofort beim Verlassen | Desktop: Entwurf 5/10/15 Striche nach 2,5/3,7/5 s, vorher 0 | iPad-Test |
| P1 | Eingeschleustes HTML über KI-Themen in „Meine Module“ | Dokument, dessen Analyse HTML in `topics` liefert | Themenliste ohne `esc()` | `views-misc.js` | maskiert | Codeprüfung | – |
| P2 | PIN-Cookie für Skripte lesbar | – | Cookie ohne `HttpOnly` | `server.py` | `HttpOnly` | Codeprüfung | – |
| P2 | Builds nicht reproduzierbar | – | Abhängigkeiten ohne Versionen | `requirements*.txt` | feste Versionen | Tests mit diesen Versionen | – |
| P2 | Eine Stud.IP-Datei liefert 403 und wird bei jedem Sync erneut versucht | `logs/sync.log` | keine Merkliste für dauerhaft gesperrte Dateien | `studip_sync.py` | – | – | offen (braucht DB-Feld) |
| P2 | Nach mehr als 3 Konflikten bleibt der Web-Editor still auf „Offline“ | – | Fehlerzähler wird nie zurückgesetzt | `editor.js` | – | – | offen |

Zweite Prüfrunde (25.10.2026, Stabilisierung):

| P | Befund | Ursache | Dateien | Korrektur | Test |
| --- | --- | --- | --- | --- | --- |
| P1 | HTML/SVG aus Stud.IP-Ordnern oder Uploads lief mit den Rechten der App (Skripte gegen die API) | Dateien inline auf der App-Adresse mit dem Typ aus Stud.IP | `server.py` | nur PDF/Bilder/Text inline, sonst Download; `nosniff`; Sandbox-CSP | `test_security_extended.py` |
| P1 | Server bei Portweiterleitung oder im eduroam für Fremde erreichbar | `0.0.0.0` ohne Netzprüfung; Firewall erlaubt Python in öffentlichen Netzen | `server.py`, `serve.py` | nur private Netze; WLAN-Modus startet nicht in „Öffentlich“-Netzen | ja (10 Adressen) |
| P1 | iPad: nach Einfügen/Drehen von Seiten könnten Striche auf der falschen Seite landen | Canvases über Anzeige-Index statt Seitenschlüssel gespeichert | `PDFEditorController.swift`, `DocumentStore.swift`, `DocumentView.swift` | Seitenschlüssel je Overlay, Overlays alter Seitenaufbauten werden nicht wiederverwendet | nicht gebaut |
| P1 | iPad: nach einem Tabwechsel wurde nicht mehr hochgeladen | `onDisappear` beendete die Synchronisierung endgültig | `DocumentView.swift`, `DocumentStore.swift` | Pausieren beim Verdecken, Beenden erst beim Schließen | nicht gebaut |
| P2 | iPad geteilte Ansicht: Rückgängig nahm nur im Hauptdokument zurück; Skript öffnete auf falscher Seite bei eingefügten Seiten | getrennte Verläufe; Index statt PDF-Seite | wie oben | gemeinsamer Verlauf; PDF-Seite → Anzeige-Index | nicht gebaut |
| P2 | Import akzeptierte beliebige Endungen und Nicht-PDFs | keine Prüfung | `server.py` | Bild-Endungen, `%PDF`-Kopf | ja |

Native App (`apps/apple`, nie kompiliert), Korrektur in Phase 2 und 3:

| P | Befund | Ursache | Datei |
| --- | --- | --- | --- |
| P0 | Striche, die während eines Uploads entstehen, gelten danach als gesendet und gehen beim nächsten Start verloren | `dirtyPages.removeAll()` nach Erfolg, ohne Revisionen | `DocumentStore.swift` |
| P0 | Jede Änderung vergibt allen Strichen der Seite neue IDs | `UUID()` bei jeder Umwandlung | `StrokeConverter.swift` |
| P0 | Konflikt: eigene Seite überschreibt die Striche des anderen Geräts auf derselben Seite | seitenweise statt objektweise Zusammenführung | `DocumentStore.swift` |
| P1 | Bei jeder Stiftänderung: ganze Seite umwandeln, hashen, ganzes Dokument als JSON schreiben, alles auf dem Hauptthread | keine Trennung von Eingabe, Speichern, Umwandeln | `DocumentStore.swift` |
| P1 | Speicherfehler werden verschluckt, Status zeigt trotzdem Erfolg | `try?` | `LocalStore.swift` |
| P1 | Zwei Uploads gleichzeitig möglich | Timer und `onDisappear` starten unabhängig | `DocumentStore.swift`, `Views.swift` |
| P1 | Zoom springt zurück, wenn sich die Fläche ändert | `autoScales = true` dauerhaft | `PDFEditorController.swift` |
| P1 | Werkzeugpalette verschwindet, wenn die erste Seite aus dem Bild scrollt | First Responder ist eine Seiten-Canvas | `PDFEditorController.swift` |
| P1 | Striche auf im Browser entfernten PDF-Seiten werden still verworfen | `pageKey` nil → `return` | `DocumentStore.swift` |

## 3. Tests

```bash
.venv\Scripts\python.exe -m pytest -q tests
```

42 Tests (Temp-Datenordner über `LERNAPP_DATA_DIR`, die echte Datenbank wird nie berührt).
Editor-Tests liefen im Desktop-Browser mit simulierten Stift- und Fingerereignissen; **kein Test auf einem echten iPad.**

## 4. Offene Risiken

- Alle Stift-Korrekturen sind auf dem iPad unbestätigt.
- Web-Editor auf dem iPad bleibt durch Safari begrenzt; die native App (`apps/apple`) ist ungetestet.
- Gedrehte PDF-Seiten in der nativen App: Koordinaten nicht geprüft.
- Kein HTTPS, keine Konten: nur im eigenen WLAN mit PIN nutzen, nicht ins Internet stellen.
