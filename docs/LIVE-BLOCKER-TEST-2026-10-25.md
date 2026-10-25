# Live-Blocker-Test und Serverplanung (25.10.2026)

Zweig `develop`. Geprüft wurden die PC-App (Server und Weboberfläche) mit echten Daten der Uni Hildesheim,
die Sicherheit, die Belastbarkeit und der Ressourcenbedarf pro Nutzer. Daraus folgt die Serverplanung.

## 1. Ergebnis in Kürze

- **Fünf Live-Blocker gefunden und behoben**, jeweils mit Test (Abschnitt 3).
- **Weiter offen für den App-Store-Start:** iPad-Code seit `ecfdfab` nie kompiliert, kein Gerätetest,
  Freigabe der LUH für Stud.IP (Abschnitt 4).
- **Server:** Für V1 (nur iPad) ist kein eigener Server nötig, außer ein kleiner KI-Zugang, falls KI mitkommt.
  Ab V2 reicht anfangs ein kleiner Server. **Die KI ist der größte Kostenblock, nicht das Hosting** (Abschnitt 6).

## 2. Was geprüft wurde und bestanden hat

| Prüfung | Ergebnis |
| --- | --- |
| Python-Tests | 77 bestanden |
| JavaScript-Tests (Zusammenführung) | 12 bestanden |
| Syntax aller 10 Web-Module (als ES-Modul) | fehlerfrei |
| Abhängigkeiten (`pip-audit`) | keine bekannten Schwachstellen |
| Geheimnis-Scan (Passwörter, Learnweb-Schlüssel) | sauber |
| Alle 15 Ansichten der Web-App mit echten Daten | laden ohne Fehler |
| PDF aus dem Learnweb im Editor | wird angezeigt |
| Pfad-Tricks gegen die `.env` (`..\`, `../`, kodiert) | alle abgewiesen (404) |
| Fremder Host-Header | abgewiesen (421) |
| PIN und Passwörter in API-Antworten | werden nicht ausgeliefert |
| Upload-Grenzen (20 MB Bild, `.exe`) | abgewiesen (400) |
| Uni-Wächter beim Start mit fremdem Datenordner | Start verweigert |
| Hildesheim live: CAS, Learnweb, LSF-Stundenplan, Noten | 9 Kurse, 539 Dateien, 24 Serien, 17 Leistungen |
| Lasttest 300 Anfragen bei 1, 10, 50 gleichzeitig | 300 von 300 erfolgreich |

## 3. Gefundene Live-Blocker (behoben)

| # | Fehler | Folge | Behebung |
| --- | --- | --- | --- |
| 1 | Dateiname mit zerlegtem Umlaut (U+0308) | Protokollausgabe stürzte ab, **der ganze Sync brach ab und verwarf alle Daten des Laufs** | Ausgabe stürzt nie mehr ab, Namen werden normalisiert, jeder Kurs wird einzeln gespeichert |
| 2 | Downloads über Playwright | Serverprozess wuchs bei 1 GB Dateien auf **2,7 GB** Speicher und gab ihn nicht frei | Downloads werden direkt auf die Platte gestreamt; live gemessen: 166 MB geladen, Speicher +4 MB |
| 3 | LUH-Semesterfilter galt auch für Hildesheim | alle Learnweb-Kurse wurden aussortiert | eigener Filter je Uni |
| 4 | Notenspiegel Hildesheim | 0 von 17 Leistungen erkannt | Kopfzeile wird überall in der Tabelle gefunden |
| 5 | Daten verschiedener Unis | konnten in einer Datenbank landen | eigener Datenordner je Uni, Wächter beim Start |

**Nur teilweise live geprüft:** Der neue gestreamte Download ist für die LUH (Stud.IP) nicht live getestet, weil die
Sitzung im Browserprofil abgelaufen war. Dafür gibt es einen automatischen Rückfall auf den alten Weg, der den Speicher
sofort freigibt. Der nächste LUH-Sync zeigt im Protokoll, ob der Rückfall gebraucht wurde
(„Gestreamter Download fehlgeschlagen …“).

## 4. Offene Blocker (nicht behoben)

| Blocker | Warum offen | Wer |
| --- | --- | --- |
| iPad-Code seit `ecfdfab` nie kompiliert | GitHub Actions wegen Abrechnung gesperrt; lokaler Swift-Test über Docker scheiterte, weil Docker Desktop nicht startete | Inhaber: Docker Desktop einmal öffnen oder Actions freigeben |
| Kein Test auf einem echten iPad | braucht Mac und Gerät | Mac-Sitzung, Inhaber |
| LUH-Freigabe für Stud.IP (OAuth2, App-Store-Regel 5.2.2) | Anfrage noch nicht gestellt | Inhaber |
| **Laufender Server auf Port 8765 hat den alten Code** | alle Korrekturen dieses Tages greifen erst nach Neustart | Inhaber: `Start-iPad.cmd` neu starten |
| Hildesheim auf dem iPad | Auftrag `AUFTRAG-HILDESHEIM-IPAD.md` an die Mac-Sitzung | Mac-Sitzung |

**Für V2 (Server mit vielen Nutzern) nötig, für die PC-App unkritisch:**
- Keine Benutzertrennung in der Datenbank (`user_id` fehlt, siehe `KONTEN-ABOS-PLAN.md`).
- `/api/files` liefert alle Dateien auf einmal (bei 539 Dateien 745 KB). Für viele Nutzer: Seitenweise abrufen.
- Uploads werden erst ganz in den Speicher gelesen und dann auf die Größe geprüft. Für einen offenen Server:
  Größe vorher über die Länge prüfen und streamen.

**Nur lokale Testumgebung:** Ein Programm auf dem PC (vermutlich eine Sicherheitssoftware mit HTTPS- und
Netzwerkprüfung) bremst Python-Verbindungen zu `127.0.0.1` und bricht einige ab. Mit curl ist der gleiche Server
schnell und fehlerfrei. Die App selbst ist nicht betroffen: Ihre Downloads aus dem Internet liefen mit 14 MB/s.

## 5. Gemessener Bedarf pro Nutzer

| Größe | Wert | Quelle |
| --- | --- | --- |
| Vorlesungsdateien je Semester | ca. 1 GB (Hildesheim, 9 Kurse), LUH 0,22 GB nach 2 Wochen | Live-Sync |
| Dateien je Monat | ca. 150 | LUH 151 in 2 Wochen, Hildesheim 539 je Semester |
| Notizen (Handschrift) | 0,6 MB, dazu 8,4 MB Versionen nach zwei Testtagen | LUH-Datenbank, nur Größen gelesen |
| Notiz speichern (98 KB) | 27 ms (Median), 71 ms (95 %) | Lasttest |
| Text je Datei für die KI | ca. 2.400 Zeichen (max. 4.000) | LUH-Datenbank |
| Wochentest | ca. 10.000 Eingabe- und 2.500 Ausgabe-Token, mit Denken ca. 5.000 | gemessene Testlängen |
| Sync-Dauer ohne Learnweb-Schlüssel | 14 min für 539 Dateien (erstmalig) | Live-Sync |
| Ein Serverprozess (Entwicklungs-PC) | 20 bis 30 Anfragen/s, bei 50 gleichzeitig 95 % unter 5,2 s | Lasttest mit curl |

## 6. Serverplanung

### Grundsatz

- **Uni-Zugänge und Vorlesungsdateien gehören nie auf den eigenen Server.** Das iPad holt sie selbst bei der Uni
  (Datenschutz, Nutzungsregeln der Unis, Urheberrecht, App-Store-Regel 5.2.2). Deshalb braucht der Server auch keine
  Browser und kaum Speicher: pro Nutzer nur Notizen, Einstellungen, Lernplan und Konto.
- Ein Sync mit Browser kostet 300 bis 500 MB Arbeitsspeicher pro gleichzeitigem Lauf. Auf einem Server wären das bei
  1.000 Nutzern schnell mehrere hundert GB. Auch technisch gehört der Sync also aufs Gerät.

### Annahmen

- Abends sind bis zu 10 % der registrierten Nutzer gleichzeitig aktiv.
- Ein aktiver Nutzer erzeugt im Schnitt 0,1 Anfragen pro Sekunde, vor allem Notizen speichern und abgleichen.
- Notizen inkl. Versionen: 20 MB pro Nutzer und Semester (Versionen begrenzen).
- Hosting-Preise: Hetzner, Stand Oktober 2026, ohne MwSt. Hetzner hat 2026 zweimal erhöht. Vor dem Buchen in der
  Hetzner-Konsole prüfen.

### Hosting nach Nutzerzahl

| Phase | Registrierte Nutzer | Gleichzeitig | Anfragen/s | Aufbau | Hosting ca. pro Monat |
| --- | --- | --- | --- | --- | --- |
| V1 | beliebig | – | – | **kein eigener Server.** Nur falls KI in V1: ein kleiner KI-Zugang (Konto prüfen, Kontingent zählen, Anfrage an die Claude-API weitergeben) | 0 €, mit KI ca. 6 € (1 kleiner Server) |
| V2 Start | bis 1.000 | 100 | 10 | 1 Server (2 vCPU, 4 GB, z. B. CX23) mit App und PostgreSQL, Object Storage für Notizen, tägliches Backup | ca. 15 € |
| V2 Wachstum | bis 10.000 | 1.000 | 100 | 2 App-Server + 1 Datenbank-Server (je 2 bis 4 vCPU), Load Balancer, Object Storage 200 GB | ca. 80 bis 150 € |
| V2 groß | bis 100.000 | 10.000 | 1.000 | 4 bis 8 App-Server, PostgreSQL mit Replikat, Redis für Sitzungen und Kontingente, Object Storage 2 TB, Load Balancer | ca. 500 bis 900 € |

Hinweis: Hetzner bietet laut den gefundenen Quellen keine verwaltete Datenbank. PostgreSQL läuft dann selbst
betrieben auf einem eigenen Server, mit Backups. Wer das nicht pflegen will, braucht einen Anbieter mit verwalteter
Datenbank (teurer).

### KI-Kosten (der größte Posten)

Preise der Claude-API je 1 Mio. Token (Eingabe/Ausgabe): Haiku 5.5 0,10/0,50 $, Sonnet 5.5 2/10 $, Opus 5.5 4/20 $.
Batch-Verarbeitung kostet die Hälfte.

| Aufgabe | Haiku 5.5 | Sonnet 5.5 | Opus 5.5 |
| --- | --- | --- | --- |
| Ein Wochentest | 0,004 $ | 0,07 $ | 0,14 $ |
| Dateianalyse, 150 Dateien im Monat (Batch) | 0,04 $ | 0,75 $ | 1,50 $ |

| Tarif (Tests/Monat) | Netto nach Apple (15 %) | KI-Kosten mit Haiku-Analyse und Sonnet-Tests | mit Haiku für beides |
| --- | --- | --- | --- |
| Free (1) | 0 € | ca. 0,11 $ | ca. 0,05 $ |
| Plus (6), 1,99 € | ca. 1,69 € | ca. 0,46 $ | ca. 0,06 $ |
| Pro (40), 4,99 € | ca. 4,24 € | ca. 2,84 $ | ca. 0,20 $ |

Beispiel 10.000 Nutzer (70 % Free, 20 % Plus, 10 % Pro), Analyse mit Haiku, Tests mit Sonnet:
KI ca. 4.500 $ im Monat, Hosting ca. 100 €, Einnahmen netto ca. 7.600 €.

**Empfehlungen:**
1. Dateianalyse mit Haiku 5.5 über die Batch-API (zeitunkritisch, 50 % günstiger).
2. Wochentests mit Sonnet 5.5, aber zuerst die Qualität gegen Haiku 5.5 an echten Folien vergleichen. Reicht Haiku,
   sinken die KI-Kosten auf einen Bruchteil.
3. Kontingente serverseitig zählen (vorbereitet in `KONTEN-ABOS-PLAN.md`). Den API-Schlüssel nie in die App legen.
4. Der KI-Zugang bekommt nur den extrahierten Text, nie die PDF-Dateien. In der Datenschutzerklärung nennen.

### Last an den Unis

Jedes Gerät lädt seine Dateien selbst bei der Uni. 1.000 Studierende einer Uni laden zusammen etwa 1 TB pro
Semester, verteilt über Wochen. Mit dem Learnweb-Schlüssel braucht es dabei keinen Browser, und Moodle zählt keine
Aufrufe. Vor einer breiten Veröffentlichung sollte die jeweilige Uni informiert werden.

## Quellen

- Claude-API-Preise: Anthropic, Stand der Referenz 06.10.2026
- Hetzner: [Preisanpassung 15.06.2026](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/),
  [Object Storage](https://www.hetzner.com/storage/object-storage/),
  [Preisübersicht Oktober 2026](https://dev.to/hostingsift/is-hetzner-still-the-cheapest-vps-we-priced-24-alternatives-october-2026-271g),
  [Preiserhöhungen 2026](https://northflank.com/blog/hetzner-cloud-server-price-increases)
