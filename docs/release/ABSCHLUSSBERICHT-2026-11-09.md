# Abschlussbericht StudiNow 1.0 – Stand 09.11.2026

Für: Ahmad Fakih (IT solutions by Ahmad Fakih). Zeitraum: 08.11.2026 morgens bis 09.11.2026 mittags.
Code-Stand: `develop` 7d1a8fb3 (Build 28). Auf dem Server läuft 729ccdf8; der Unterschied zu 7d1a8fb3 sind nur
Build-Nummer und Doku, kein Dienstcode.

## 1. Kurzfassung

- **Rund 290 echte Fehler behoben**, jeder zuerst mit einem roten Test nachgestellt und danach grün.
- **Rund 160 weitere Befunde widerlegt** und mit einem Test festgenagelt, damit sie nicht später doch auftreten.
- **Alle externen Prüfpakete 1–87 und die Liste der 95 Prüfstellen** sind abgearbeitet. Die Berichte liegen in `docs/audit/`
  (33 Dateien).
- **Server umgezogen** auf den Hetzner CPX42 in Nürnberg, abgesichert, überwacht, mit verschlüsselter Sicherung außer Haus.
- **Lasttest auf dem echten Server bestanden:** 4.000 KI-Fragen ohne Fehler, 4.000 Anmeldungen und Abgleiche ohne Fehler,
  30 Minuten Dauerlast, kein bestätigter Schreibvorgang verloren.
- **Build 28** ist die fertige iPad-Version für die Testphase: Build 25 plus alle Fehlerbehebungen und die gewünschten
  Neuerungen. Er ist noch **nicht** zu Apple hochgeladen.
- **Apple:** Build 25 wartet weiter auf die App-Prüfung und auf die TestFlight-Beta-Prüfung (Abfrage 09.11. 11:45).

## 2. Zahlen

| Größe | Wert |
|---|---|
| Commits seit 08.11. | 206, davon 38 Zusammenführungen |
| Geänderte Dateien | 296 |
| Zeilen hinzugefügt / entfernt | 37.927 / 1.598 |
| Neue Testdateien | 42 Python, 21 Swift |
| Python-Testfunktionen Build 25 → jetzt | 1.490 → 2.249 (3.273 Testläufe mit Parametern, alle grün) |
| Swift-Testfunktionen Build 25 → jetzt | 2.649 → 2.773 (Kern 1.385 grün, App-Suite 1.387 mit 0 Fehlern) |
| JavaScript-Tests | 398 → 402 Funktionen (440 Testläufe grün) |

### Behobene Fehler je Block

Gezählt aus den Ergebnistabellen der Prüfberichte. Ein Fehler, der mehrere Prüfnummern schließt, zählt einmal; die Summe ist
deshalb auf etwa ±10 genau.

| Block | Behoben | Bericht |
|---|---|---|
| Pakete 1–8 | ~38 | AUDIT-2026-11-08-PAKET-1-2, -3-4, -5, -6-8 |
| Pakete 9–16 | ~58 | -9-10, -11-12, -13-14, -15-16 |
| Pakete 17–24 | ~55 | -17-18, -19-21, -21-22, -23-24 |
| Pakete 25–32 | ~32 | -25-27, -28-29, -30-32 |
| Pakete 32–40 | ~37 | -32b-34, -35-37-40, -36, -38-39 |
| Pakete 40–47 | ~22 | -40x-45, -41, -42-43, -44, -46-47 |
| Pakete 45–57 | ~14 | -48-49, -50-54, -55-57 |
| Pakete 58–87 | ~14 | AUDIT-2026-11-09-* (fünf Berichte) |
| Liste der 95 Prüfstellen | 12 | LISTE-95-2026-11-09 |
| Eigene Funde während der Arbeit | ~8 | z. B. Schema-Transaktion, KI-Abbruch unter Python 3.12 |
| Von dir am iPad gemeldet | 8 | Abschnitt 3 |
| **Summe** | **rund 290–300** | |

Aus der Liste der 95 waren 31 schon vorher behoben, 18 widerlegt; die übrigen sind Design- oder Betriebsfragen mit Begründung
im Bericht. Von den Paketen 58–87 waren rund 50 Prüfstellen schon durch frühere Pakete behoben.

## 3. Von dir gemeldete Fehler und Wünsche (alle in Build 28)

1. **Prüfungsknopf QIS/LSF:** heißt jetzt „Im QIS/LSF zur Prüfung anmelden“. Nach dem Schließen des Browsers ruft die App den
   Stand einmal ab, statt weiter „bei QIS anmelden“ zu zeigen.
2. **Studienverlauf, Module verschieben:** repariert. Ablegen klappt auch nach dem Neuaufbau der Seite und im Hochformat.
   Angemeldete und bestandene Module sind gesperrt und sagen, warum. Web und PC verhalten sich gleich.
3. **Rechts-/Linkshänder vertauscht:** behoben. Blatt oder Übung liegt jetzt auf der Seite der Schreibhand, das Skript auf der
   Seite der freien Hand. Gleich im Web.
4. **Seiten tauschen (neu):** Kopfzeile der Spalte lange drücken, zur anderen Seite ziehen, loslassen. Zusätzlich im Menü und
   als VoiceOver-Aktion. Die Lage wird je Dokumentpaar gemerkt.
5. **Probe-Anzeige:** überall aus einer Quelle, keine widersprüchlichen Resttage mehr.
6. **Lernplan:** ordnet nur neue Dokumente ein, statt die Woche neu zu planen.
7. **Credits:** Free 0, Probe 25, Plus 0, Pro AI 100, Probe plus Plus 25 bis zum Probe-Ende; 1 Credit = 0,9 Cent.
8. **Mac (Designed for iPad):** Absturz im Raster bei unendlicher Breite behoben. Gilt ab 1.0.1; für Build 25 den Mac abschalten.

## 4. Wichtigste behobene Fehler

- **Zeichnung sofort gesichert (P60-F1):** Ein Strich lag nach dem Absetzen nur im Speicher. Wurde die App hart beendet, war er
  weg. Jetzt wird er sofort geschrieben und nach einem Absturz wiederhergestellt.
- **Erledigtes geht beim Abgleich nicht verloren (P73-F6):** Geräte schickten ganze Zeilen, ein zweites Gerät konnte so eine
  Erledigung überschreiben. Jetzt werden nur geänderte Felder geschickt und zusammengeführt.
- **Käufe:** ungültige Konto-Kennung im Kauf führte zu Serverfehler; Kontowechsel während der Aboprüfung schrieb den Tarif ins
  falsche Konto; Kauf ohne Konto-Kennung bei Dienstausfall; Kulanzfrist; Ablauf bei offener App; verstellte Uhr.
- **Konten und Datenschutz:** Kontolöschung räumte nicht alle Tabellen; Export war unvollständig; drei Löschfristen liefen nie;
  Installationskennung fehlte in den Datenschutzangaben.
- **Community:** fremde Pseudonyme über eine Sperr-Route sichtbar; Pakete und Datenbank nicht atomar; Wiederherstellen gelöschter
  Pakete; Übernahme-Kontingent je Konto statt je Gerät.
- **Last und Stabilität:** KI-Endpunkte asynchron; Credits bei KI-Abbruch unter Python 3.12 verloren (jetzt eigener Thread);
  Datenbank „locked“ beim Schema-Start mehrerer Prozesse; 101 von 303 Fuzz-Eingaben gaben vorher Serverfehler 500.
- **Schlüssel:** zwölf Prozesse erzeugten beim Erststart zwölf verschiedene Schlüssel; Schlüsseldatei kurz lesbar für alle.

## 5. Server und Betrieb

| Punkt | Stand |
|---|---|
| Server | Hetzner CPX42 Nürnberg, 46.225.32.3, 8 vCPU, 16 GB; 12 API-Prozesse, ein Job-Container, Caddy |
| Umzug | Helsinki → Nürnberg am 08.11., DNS bei STRATO umgestellt, Datenschutzerklärung mit neuem Standort |
| Zugang | SSH nur mit Schlüssel, fail2ban aktiv |
| Überwachung | Prüfung alle 5 Minuten: Container, Platte, RAM, Fehlerquote, Zertifikat, Jobs, Sicherung |
| Sicherung | täglich 03:30 auf dem Server, danach verschlüsselt (age) auf die Storage Box, 30 Tage aufbewahrt |
| Wiederherstellung | auf dem Server geprobt: vollständig, Dienst lief auf der Kopie |
| Website | studinow.app über Netlify, Upload per Skript statt Drag-and-drop |

### Lasttest auf dem echten Server (09.11. 04:51–05:26)

| Szenario | Ergebnis |
|---|---|
| 4.000 gleichzeitige KI-Fragen | 4.000 beantwortet, 0 Fehler |
| 1.000 Registrierungen hinter einer IP (Uni-NAT) | 0 Fehler |
| 4.000 Anmeldungen und 4.000 Abgleiche | 0 Fehler |
| 30 Minuten Dauerlast | 720.000 Anfragen, 0,07 % Fehler, p95 rund 50 ms |
| API-Prozess hart beendet | Ersatz nach 1 s |
| Wiederanlauf-Sturm | 0 Fehler |
| Bestätigte Schreibvorgänge | 296.390, davon 0 verloren |

Einziger knapper Wert: Normale Anfragen brauchten unter 4.000 gleichzeitigen KI-Fragen im p95 2,1 Sekunden. Das ist spürbar,
aber kein Fehler. Für 2.000–4.000 Nutzer reicht der Server.

## 6. Go-live-Gates

| Gate | Status | Was fehlt |
|---|---|---|
| G1 Build und Apple-Prüfung | teilweise | Freigabe durch Apple |
| G2 Notizen ohne Datenverlust | offen | Gerätetest mit Pencil am iPad |
| G3 Zahlungen und Abos | teilweise | Sandbox-Kauf, Wiederherstellen, Wechsel in TestFlight |
| G4 Konten und Datenschutz | teilweise | Kontowechsel und Konto löschen am iPad |
| G5 4.000 aktive Nutzer | **erfüllt** | – |
| G6 Betrieb und Wiederherstellung | teilweise | Restore-Probe mit Dienststart ist belegt; Rest siehe Gate-Datei |

Einzelheiten: docs/release/GO-LIVE-GATES-2026-11-09.md. Welle 1 mit 50 Testern ist mit diesem Stand vertretbar, sobald Apple
die Beta freigibt.

## 7. Build 28

| Punkt | Stand |
|---|---|
| Version, Build | 1.0 (28), nur LUH |
| Commit | 7d1a8fb3 |
| Inhalt | Build 25 plus alle Behebungen aus Abschnitt 2–4 |
| App-Tests auf dem Endstand | 1.387 Tests, 18 übersprungen, 0 Fehler (Simulator, 09.11. 11:45–12:05) |
| Archiv | `StudiNow-28.xcarchive` vom 09.11. 12:08, Export Datei für Datei gleich dem Commit, Team 78MQGF36BD |
| Hochgeladen zu Apple | **nein**, erst auf deine Ansage |

Build 25 bleibt in der Prüfung. Sobald Apple ihn freigibt, kann Build 28 als Update nachgereicht werden. Für TestFlight kann
Build 28 auch vorher hochgeladen werden; er braucht dann eine eigene, meist kurze Beta-Prüfung.

## 8. Deine offenen Aufgaben

1. **App Store Connect, App-Datenschutz:** „Geräte-ID“ ergänzen (Installationskennung beim Abgleich).
2. **Build 25 für Mac mit Apple-Chip abschalten** (Preise und Verfügbarkeit), weil der Mac-Absturz erst ab Build 28 behoben ist.
3. **Gerätetests am iPad (rund 2 Stunden):** Pencil schreiben und App hart beenden, zwei Geräte, Sandbox-Kauf und
   Wiederherstellen, Kontowechsel, Studienverlauf, Seiten tauschen, Schreibhand.
4. **age-Schlüssel der Sicherung** in den Passwortmanager legen. Ohne ihn ist die Sicherung außer Haus nicht lesbar.
5. **Optional:** Storage Box von BX21 auf BX11 verkleinern.
6. **Nach Apples Freigabe:** TestFlight-Link https://testflight.apple.com/join/XTzTMRpn in Wellen verschicken, zuerst 50.
7. **Ansage für Build 28:** dann lade ich ihn hoch.
