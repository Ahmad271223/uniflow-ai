# Übergabe an eine Claude-Code-Sitzung auf dem MacBook

Stand 25.10.2026, Zweig `develop`. Diese Datei ist für eine **neue Sitzung auf dem Mac** geschrieben: Sitzungen und
Notizen der bisherigen Arbeit liegen auf dem Windows-PC und sind auf dem Mac nicht sichtbar.

## Auftrag

Die native iPad-App (`apps/apple`) wird eine vollständige **1:1-Umsetzung der Web-App** (`app/static`, `app/*.py`):
gleiches Design, gleiche Navigation, gleiche Funktionen, gleiche Daten und Logik. Abweichungen nur, wo Apple Pencil,
Touch, Bildschirmgröße oder iPadOS es erfordern. Später soll die App ohne den Windows-PC laufen (lokale Daten,
portierte Logik). Vollständiger Auftrag und Abnahmekriterien: siehe Abschnitt „Abnahme“ unten.

**Maßgebliche Checkliste:** [`WEB-IPAD-PARITAET.md`](../WEB-IPAD-PARITAET.md) – 509 Funktionen mit Ort im Web,
iPad-Stand und Status. Erzeugt mit `python3 tools/gen-parity.py`; Status in `docs/paritaet/status.json` pflegen.
Bestandsaufnahmen: `docs/paritaet/web-ansichten.md`, `web-editor.md`, `ipad-app.md`.

## Regeln (vom Projektinhaber festgelegt)

- Nur auf `develop` arbeiten. **Kein Merge nach `main`, kein Release.**
- **Keine kostenpflichtigen Dienste, Runner oder Zahlungsänderungen** ohne ausdrückliche Zustimmung. GitHub Actions ist
  wegen der Abrechnung gesperrt: Commits mit `[skip ci]` im Titel, keine Läufe starten.
- Committen/pushen nur, wenn der Inhaber es sagt. Vor jedem Push die gestagten Dateien auf Geheimnisse prüfen.
  **Nie committen:** `.env`, `data/`, `logs/`, `backup/`.
- **Nie Passwörter oder Zugangsdaten eintippen** (LUH, Stud.IP, QIS). Der Inhaber meldet sich selbst an.
- „Implementiert“ heißt nicht „getestet“. Keine Tests oder Gerätetests behaupten, die nicht gelaufen sind.
- Nachfragen nur bei Geld, produktiven Daten, Zugangsdaten oder grundlegenden Architekturentscheidungen.
- Der UniFlow-Server läuft auf dem Windows-PC (Port 8765, Start über `Start-iPad.cmd`). Ihn nicht beenden oder
  verändern; seine Daten (`data/`) sind persönlich und nicht im Repository.
- Code im Stil der Umgebung schreiben: deutsche Kommentare ohne Umlaute im Quelltext, Texte in der Oberfläche mit Umlauten.

## Stand

Aktualisiert nach Commit `74354ff` (Arbeit der ersten Mac-Sitzung). Maßgeblich ist immer `WEB-IPAD-PARITAET.md`.

| Bereich | Stand |
| --- | --- |
| Designsystem, App-Rahmen, Übersicht, Lernkalender, Stundenplan, Meine Module, Dokumente & Notizen | 1:1 umgesetzt und **kompiliert** (284 Einträge) – geprüft bisher nur gegen einen lokalen Testserver, nicht mit echten Daten |
| Stundenplan-Import | 3 Einträge „Getestet“, aber mit einer erfundenen ICS-Datei gegen den Testserver → mit echten Daten wiederholen |
| Dokumentansicht, PDF-Editor | **nicht begonnen** (27 + 107 Einträge), alter nativer Editor |
| Tests & Wiederholung, Einstellungen, Uni & Noten, Zeitmesser, Community | nicht begonnen (Uni & Noten/Community: Web-Ansicht des PC-Servers als Übergang) |
| Stud.IP direkt vom iPad | Kern getestet; App-Teil kompiliert, mit echter Anmeldung noch nicht ausprobiert; Aufbau von QIS/Stud.IP in `docs/QIS-STUDIP-STRUKTUR.md` |
| Swift-Kern `Packages/UniFlowCore` | 48/48 Tests grün |
| Visuell geprüft | **0** – noch kein Bildvergleich abgelegt |

## Erste Schritte auf dem Mac

```bash
cd <Projektordner>                 # Klon von https://github.com/Ahmad271223/uniflow-ai
git fetch && git checkout develop && git pull
brew install xcodegen              # einmalig
cd apps/apple && xcodegen generate
(cd Packages/UniFlowCore && swift test)
xcrun simctl list devices available | grep iPad
xcodebuild build -project UniFlow.xcodeproj -scheme UniFlow \
  -destination 'platform=iOS Simulator,name=<iPad-Simulator aus der Liste>' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|warning:|BUILD" | head -80
```

Ad-hoc signieren (`CODE_SIGN_IDENTITY=-`), nicht `CODE_SIGNING_ALLOWED=NO`: Ein unsignierter Simulator-Build darf nicht
in den Schlüsselbund schreiben, die PIN geht dann bei jeder Neuinstallation verloren (geprüft von `KeychainTests`).

Danach Tests: `xcodebuild test` mit demselben `-destination` (wie in `.github/workflows/apple.yml`).

## Echte Daten – keine Testdaten, kein Ersatz-Server

Entwickelt und geprüft wird **mit den echten Daten des Inhabers**, nicht mit erfundenen Daten oder einem nachgebauten
Server. Die echten Daten liegen bereits auf dem UniFlow-Server am Windows-PC (Stud.IP-Abgleich, Kalender, Tests …):

1. Auf dem PC läuft `Start-iPad.cmd` (Server im Heimnetz, Port 8765). Mac und PC im selben WLAN.
2. In der App im Simulator auf dem Verbindungsbildschirm: Adresse `http://192.168.178.46:8765` (IP des PCs im WLAN;
   alternativ `http://amo.fritz.box:8765`) und die PIN. **Adresse darf die Sitzung eintragen, die PIN tippt der
   Inhaber selbst** (sie steht in der Web-App unter Einstellungen → Zugang & Darstellung → Auf dem iPad benutzen).
   Die App merkt sich beides im Schlüsselbund des Simulators.
3. Stud.IP direkt vom iPad: Der Inhaber meldet sich im Simulator selbst im Stud.IP-Fenster der App an
   (Einstellungen → Stud.IP oder „Stud.IP ohne PC nutzen“); danach lädt die App seine echten Dateien.

Keine Claude-Sitzung tippt LUH-, Stud.IP- oder QIS-Zugangsdaten oder die PIN ein – das ist eine feste
Sicherheitsregel. Stattdessen den Inhaber kurz bitten, sich selbst anzumelden, und danach weiterarbeiten.
Feste Beispieldaten sind nur in automatisierten Unit-Tests erlaubt (`UniFlowTests`, `UniFlowCoreTests`), nie für
Bildschirmvergleiche oder das Ausprobieren von Abläufen.

**Kein lokaler Testserver mehr für Prüfungen.** Der Debug-Start mit `-UFServer http://localhost:8765` ist nur noch für
reine Darstellungsfragen erlaubt, nicht für einen Status. Alle bisherigen Prüfungen gegen den Testserver (Stundenplan-
Import, Safari-Abgleich der Übersicht) werden mit den echten Daten wiederholt; erst dann „Getestet“ bzw. „Visuell
geprüft“.

## Testen mit echten Daten: lesen ja, schreiben nur mit Zustimmung

- **Ohne Rückfrage erlaubt:** alles, was nur liest (Ansichten öffnen, blättern, Drawer und Dialoge öffnen und mit
  „Abbrechen“ schließen, Importvorschau ansehen).
- **Nur nach ausdrücklicher Zustimmung des Inhabers im Chat:** alles, was Daten auf dem PC-Server ändert –
  „Übernehmen“, „Speichern“, „Erstellen“, „Löschen“, „Erledigt“, Verschieben, Lernplan erstellen, Notizen/Striche in
  Dokumenten, Tests abgeben, Stud.IP- oder QIS-Abruf auslösen. Vorher sagen, was genau sich ändert.
- **Danach aufräumen:** eigene Testeinträge über ihre ID wieder entfernen und prüfen, dass nur sie entfernt wurden
  (der Inhaber arbeitet parallel mit denselben Daten).
- Die Debug-Aktion `tt-import-ics` (erfundene Kalenderdatei „Testkurs Physik“) **nie gegen den PC-Server** ausführen:
  „Übernehmen“ würde erfundene Termine anlegen und echte als „nicht mehr enthalten“ entfernen. Für Importtests eine
  echte Datei des Inhabers bzw. den Stud.IP-Abgleich nehmen und vor „Übernehmen“ fragen.

## Bildvergleich (Voraussetzung für „Visuell geprüft“)

- Je Ansicht und Zustand ein Bildpaar mit **denselben echten Daten**: Web-App in Safari im iPad-Simulator (gleiches
  Gerät, gleiche Ausrichtung) und native App im selben Simulator. Querformat 1180 × 820, zusätzlich Hochformat, wo
  sich das Layout ändert (≤ 900 pt).
- Ablage: `docs/paritaet/screens/<bereich>-<zustand>-web.png` und `…-ipad.png`. Persönliche Daten (Noten, Namen
  anderer Personen, Adressen) vor dem Ablegen unkenntlich machen oder die Bilder nicht ins Repository legen
  (`docs/paritaet/screens/` dann in `.gitignore`).
- Abweichungen in `status.json` beim jeweiligen Eintrag notieren; „Visuell geprüft“ erst, wenn keine sichtbaren
  Unterschiede mehr bleiben außer den begründeten iPad-Anpassungen.

## Nächste Schritte (Priorität des Inhabers)

1. **Dokumentansicht und PDF-Editor 1:1** (wichtigste Funktion für den Inhaber, Apple Pencil): Leisten, Werkzeuge,
   Seitenverwaltung, Rückgängig für alles, Lineal, Zoom-Ansicht, KI-Seitenleiste (nur Anbindung an den Server),
   Tabs, geteilte Ansicht, Export. Pencil-Feingefühl bleibt Gerätetest (`docs/MAC-IPAD-CHECKLISTE.md`).
2. Bisher kompilierte Bereiche mit echten Daten prüfen und Bildvergleiche ablegen.
3. Tests & Wiederholung (inkl. Karteikarten), Einstellungen, Uni & Noten, Zeitmesser, Community.
4. Nach jedem Bereich: kompilieren, Unit-Tests, mit echten Daten ausprobieren, Bildvergleich, `status.json`
   aktualisieren, `python3 tools/gen-parity.py`, committen mit `[skip ci]` (nach Freigabe des Inhabers).
5. Lokales Backend (SQLite + Swift-Port von `study.py`, `timetable.py`, `scriptsearch.py`), damit die App ohne PC läuft.
   Antworten gegen den Python-Server vergleichen.
6. KI ohne PC braucht einen KI-Dienst – das kostet Geld und **braucht die Zustimmung des Inhabers**.

## Abnahme (aus dem Auftrag)

Fertig erst, wenn jede Webansicht ein natives Gegenstück hat, alle Funktionen vorhanden sind und jede Schaltfläche
funktioniert, Daten korrekt gespeichert werden, nichts verloren geht, das Design mit der Webversion per Bildschirmfoto
verglichen wurde, die wichtigen Abläufe getestet sind, die App kompiliert und es keine bekannten kritischen
Datenverlustfehler gibt.

## Startnachricht für die neue Sitzung

> Lies `docs/UEBERGABE-MAC.md` und `WEB-IPAD-PARITAET.md` und arbeite auf `develop` an der 1:1-Umsetzung der Web-App
> für das iPad weiter – mit meinen echten Daten vom PC-Server, schreibende Tests nur nach meiner Zustimmung.
> Als Nächstes: Dokumentansicht und PDF-Editor 1:1.
