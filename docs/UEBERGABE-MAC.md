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

| Bereich | Stand |
| --- | --- |
| Designsystem `apps/apple/UniFlow/Design/` | Tokens aus `style.css` (`UFTheme.swift`), Komponenten nach den CSS-Klassen (`UFComponents.swift`), Formatierung wie `core.js` (`UFFormat.swift`), 83 Web-Icons als Vektor (`Assets.xcassets/Icons`, erzeugt mit `node tools/gen-ios-icons.mjs`) – **geschrieben, nie kompiliert** |
| App-Rahmen `AppShell.swift`, `ShellState.swift` | Seitenleiste, Kopfzeile (Suche, Sync, Hell/Dunkel/Auto), untere Leiste unter 900 pt, Router mit den Web-Routen – **nicht kompiliert** |
| Übersicht `Views/DashboardView.swift` + `Views/PlanDialogs.swift` | 1:1 nach `viewDashboard`; Dialoge „Lernplan erstellen“, „Lernkombination ändern“, „Meine Woche retten“ – **nicht kompiliert** |
| Stundenplan, Uni & Noten, Community | Übergang: Web-Ansicht des PC-Servers eingebettet (`UFWebFallback.swift`) |
| Kalender, Module, Dokumente, Tests, Einstellungen, Editor | alte native Ansichten, noch nicht 1:1 |
| Stud.IP direkt vom iPad | Kern getestet (`StudIPClient`, `StudIPImport`), App-Teil (`StudIPSync`, `StudIPView`) nicht kompiliert; siehe `docs/IPAD-STUDIP-SYNC.md` |
| Swift-Kern `Packages/UniFlowCore` | 48/48 Tests grün (Linux-Container `swift:6.0-jammy`) |

Auf dem PC war nur eine Syntaxprüfung (`swiftc -parse`) der App-Dateien möglich, **keine Typprüfung**. Beim ersten
Bauen sind Typfehler zu erwarten – zuerst diese beheben.

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
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|BUILD" | head -80
```

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

## Nächste Schritte (Reihenfolge des Auftrags)

1. Bauen, Typfehler beheben, bis die App im iPad-Simulator startet. Status in `status.json` auf „Kompiliert“ setzen.
2. Übersicht mit Daten im Simulator prüfen; Bildschirmfotos Web (Safari im Simulator, gleiche Größe) und iPad
   nebeneinander unter `docs/paritaet/screens/` ablegen und vergleichen.
3. Bereich für Bereich nach der Checkliste umsetzen: Lernkalender (inkl. Lernpaket- und Termin-Drawer), Stundenplan,
   Module, Dokumente, Dokumentansicht + Editor, Tests/Karteikarten, Uni & Noten, Einstellungen, Zeitmesser.
   Nach jedem Bereich kompilieren, testen, vergleichen, `status.json` aktualisieren, `python3 tools/gen-parity.py`.
4. Lokales Backend (SQLite + Swift-Port von `study.py`, `timetable.py`, `scriptsearch.py`), damit die App ohne PC läuft.
   Antworten gegen den Python-Server auf derselben Test-Datenbank vergleichen.
5. KI ohne PC braucht einen KI-Dienst – das kostet Geld und **braucht die Zustimmung des Inhabers**.

## Abnahme (aus dem Auftrag)

Fertig erst, wenn jede Webansicht ein natives Gegenstück hat, alle Funktionen vorhanden sind und jede Schaltfläche
funktioniert, Daten korrekt gespeichert werden, nichts verloren geht, das Design mit der Webversion per Bildschirmfoto
verglichen wurde, die wichtigen Abläufe getestet sind, die App kompiliert und es keine bekannten kritischen
Datenverlustfehler gibt.

## Startnachricht für die neue Sitzung

> Lies `docs/UEBERGABE-MAC.md` und `WEB-IPAD-PARITAET.md` und arbeite auf `develop` an der 1:1-Umsetzung der Web-App
> für das iPad weiter. Beginne damit, die App in Xcode für den iPad-Simulator zu bauen und alle Compilerfehler zu beheben.
