# Go-live-Gates G1–G6 – Stand 09.11.2026

Grundlage: externer, rein statischer Audit Pakete 62, 82–85 und 87 (Abschlussbericht mit den Gates G1–G6 und den P0/P1-Maßnahmen),
Code-Stand `origin/develop` b328ebdd plus Zweig `audit/p58-87-golive`. Bericht zu diesem Zweig:
docs/audit/AUDIT-2026-11-09-PAKET-62-82-87.md, Tests: `tests/test_audit_p58_87_golive.py`.

Ziel des Inhabers: bis 15.11.2026 2.000–4.000 Nutzer auf **einem** Hetzner CPX42 (Nürnberg, 8 vCPU, 16 GB, 12 uvicorn-Prozesse,
`API_MEMORY=8G`, ein Job-Container, Caddy). 100.000 ist kein Ziel für jetzt (Abschnitt 7: nur Fahrplan).

**Regel (aus Paket 87, übernommen):** Ein Gate ist nicht „erfüllt“, weil passender Code existiert. Erfüllt heißt: Messung oder
Probe mit Beleg (Datei, Protokoll, Test). Und: eine Messung auf dem Mac ist kein Nachweis für den Server.

## 0. Kurzfassung

| Gate | Status | Was fehlt (kurz) | Wer | Aufwand |
|---|---|---|---|---|
| G1 Build 25 / Apple Review | **teilweise** | tatsächlicher Review-Status, TestFlight-Gerätetest mit genau Build 25, produktiver Backend-Commit | Inhaber (ASC, iPad), Claude per SSH (Commit) | 30 min + 5 min |
| G2 Notizen ohne Datenverlust | **offen** | Gerätetest auf echtem iPad mit Pencil (Force-Quit, Offline, Zweitgerät, Zweitfenster) | Inhaber am iPad | 45 min |
| G3 Zahlungen und Abo-Rechte | **teilweise** | Sandbox-Kauf/Restore/Wechsel in TestFlight mit Konto, Dienst schaltet frei; späterer Abgleich nach Dienstfehler | Inhaber am iPad + ASC | 45 min |
| G4 Konten und Datenschutz | **teilweise** | Kontowechsel und Konto löschen am iPad (inkl. CloudKit-Community), Export am Gerät | Inhaber am iPad | 30 min |
| G5 4.000 aktive Nutzer | **offen** (Werkzeug fertig) | Lauf `tools/lasttest-server.sh` auf dem CPX42 | Claude per SSH (nachts) | 1 h Lauf, 15 min Auswertung |
| G6 Betrieb und Wiederherstellung | **teilweise** | Restore-Probe mit Dienststart **auf dem Server**, kontrollierter Worker-Ausfall auf dem Server, Mail-Alarm einmal ausgelöst, Rollback-Image | Claude per SSH, Inhaber (Mail ansehen) | 1 h |

**Entscheidung:** NO-GO für einen **unbeschränkten öffentlichen** Start mit 4.000 gleichzeitig aktiven Nutzern bleibt bestehen, bis
G5 und G6 auf dem Server und G2/G3 am Gerät belegt sind. Die **TestFlight-Welle 1 (50 Personen, TESTFLIGHT-500 6.2)** ist mit den
vorhandenen Nachweisen vertretbar (kleine Last, Monitoring alle 5 Minuten, Sicherung außer Haus, Support), sofern G1 (Beta
freigegeben, Dienst antwortet) erfüllt ist. Welle 2 (bis 500) erst nach G5-Serverlauf; der App-Store-Start mit offener Werbung erst
nach G1–G6.

Legende der Belegart: **[Server]** auf dem echten CPX42 gemessen · **[Mac]** lokal auf dem Mac des Inhabers (Apple Silicon,
18 CPUs) mit echtem Code und echten Prozessen · **[Test]** automatischer Test in der Suite · **[Code]** nur Codestelle · **[ASC]**
App Store Connect · **[iPad]** Gerät.

## 1. Gates im Einzelnen

### G1 – Build 25 und Apple Review

Mindestnachweis (P87): eingereichtes IPA, Commit, Entitlements, TestFlight-Gerätetest, tatsächlicher Review-Status.

| Teil | Status | Beleg | Fehlt | Wer | Aufwand |
|---|---|---|---|---|---|
| Commit des Builds | erfüllt [Code] | docs/release/BUILD-HERKUNFT.md: Build 25 = `d08cae54`, Export-Ordner Datei für Datei gleich (`tools/pruefe-build-herkunft.sh 25 d08cae54`), `tests/test_release_build_provenance.py` | – | – | – |
| Lokale Abnahme vor dem Archiv | erfüllt [Mac] | `b25-test.log`: 74 Tests, 2 übersprungen, 0 Fehler (Auswahl, nicht die ganze Suite) | CI-Lauf für d08cae54 rot (Linux-Job), iPad-Job übersprungen – für Build 25 gibt es keinen CI-Nachweis | – | – |
| Review-Status | offen [ASC] | Stand Doku 08.11.: WAITING_FOR_REVIEW | aktueller Status (In Review / Ready for Distribution / Rejected) und Beta-Freigabe der Gruppe „LUH-Tester“ | Inhaber in ASC | 2 min |
| Gerätetest mit **genau** Build 25 | offen [iPad] | – | TestFlight-Installation von Build 25 auf dem eigenen iPad, Reisen P85-01/02/04/10 (Abschnitt 4) | Inhaber am iPad | 30 min |
| Fixes nach Build 25 | bekannt | BUILD-HERKUNFT „Build 27“: u. a. Mac-Layout-Absturz `afc919cc`, Kauf-Konto-Token `a6add585` | gelten **nicht** für Build 25; Build 27 neu bauen, nicht das veraltete Archiv hochladen | Inhaber/Claude | – |
| Produktiver Backend-Commit und Konfiguration (P82-F10) | offen [Server] | – | `bash /root/studinow-lasttest/tools/lasttest-server.sh --trocken` schreibt Commit von `/srv/uniflow/app`, Image-ID, Speichergrenzen und die Betriebswerte (`WEB_CONCURRENCY`, `LERNAPP_LIMIT_*`, … – nur eine feste Liste, nie Schlüssel) | Claude per SSH | 5 min |

### G2 – PDF/Notizen ohne Datenverlust

Mindestnachweis: Pencil-Dauerschreiben, Force-Quit, Offline/Online, Zweitgerät, Multiwindow; keine verlorenen bestätigten Änderungen.

| Teil | Status | Beleg | Fehlt | Wer |
|---|---|---|---|---|
| Journal, Schreibpause, Zweitfenster-Sperre im Code | vorhanden [Code] | `DocumentStore.swift` (Journal, `isWritable`, Fensterübergabe); Swift-Tests u. a. `EditorHardeningStep2Tests`, `HardeningSolutionRoundTripTests`, `ResumeAppTests` | Simulator ersetzt keinen Stift | – |
| Dienstseite: bestätigter Push geht nicht verloren | erfüllt [Mac][Test] | `tools/lasttest-dauer.py` prüft nach dem Lauf jeden mit 200 bestätigten Push in der Konto-Datenbank (`test_p82_soak_tool_keeps_every_acknowledged_write_and_survives_a_killed_worker`, auch mit SIGKILL eines API-Prozesses); Wiederholung mit gleicher `op_id` legt nichts doppelt an (`app/sync.py` `sync_ops`, `tests/test_sync.py`) | Serverlauf (G5) | Claude per SSH |
| Gerät: Force-Quit direkt nach Strichen, Flugmodus, Zweitgerät, Split View | **offen** [iPad] | – | Reisen P85-04/05/06 (Abschnitt 4) | Inhaber am iPad (45 min) |

### G3 – Zahlungen und Abo-Rechte

| Teil | Status | Beleg | Fehlt | Wer |
|---|---|---|---|---|
| Dienst nimmt Sandbox wie Production an, kennzeichnet sie | erfüllt [Test] | TESTFLIGHT-500 7.1, `tests/test_subscriptions.py` (`test_sandbox_purchase_unlocks_pro_ai_like_production_but_is_labelled`, `test_sandbox_notifications_are_handled_like_production`) | – | – |
| P0-2 Reconciliation (`Entitlements.swift` `handle`: `transaction.finish()` auch wenn der Dienst nicht bestätigt) | teilweise [Code] | `StudoraAccountLink.reportTransaction`: bei Fehler `reportedPurchasesFor = nil` → beim nächsten Start/Anmelden meldet `reportPurchases()` alle `Transaction.currentEntitlements` erneut; dazu App Store Server Notifications (beide URLs, TESTFLIGHT-500 6.1 Nr. 4) | kein Swift-Test für „Dienst 503 beim Kauf → nächster Start schaltet frei“; Gerätetest | Agent „Käufe/Konten/Release“ (Test), Inhaber am iPad (Probe) |
| Wurzelzertifikat und Benachrichtigungen | offen [Server/ASC] | Prüfung ohne SSH: `curl -s -X POST https://app.studinow.app/api/billing/apple/notifications -H 'Content-Type: application/json' -d '{"signedPayload":"a.b.c"}'` → `400 jws_invalid` = eingerichtet | Ergebnis festhalten; in ASC beide URLs (Production **und** Sandbox) | Claude (curl), Inhaber (ASC) |
| Gerät: Kauf, Restore auf Zweitgerät, Upgrade Plus→Pro AI, Downgrade | **offen** [iPad] | – | Reise P85-10 | Inhaber am iPad |

### G4 – Konten und Datenschutz

| Teil | Status | Beleg | Fehlt | Wer |
|---|---|---|---|---|
| IDOR/Mandantentrennung, Export, Löschung im Dienst | erfüllt [Test] | Audit 55–57 (`tests/test_audit_paket_55_57.py`), `tests/test_launch_4000.py` | – | – |
| Löschung nach Restore bleibt wirksam (P84-F9, P84-11) | erfüllt [Test] | `test_p57_06_deletions_after_a_backup_are_reapplied_after_restore`; Runbook BETRIEB 9 „Wiederherstellung“ Schritt 0 (`accounts deleted` / `redelete`) | in die Restore-Übung auf dem Server einbeziehen (Abschnitt 5) | Claude per SSH |
| Kontowechsel am iPad, CloudKit-Community nach Löschung | **offen** [iPad] | Swift `DataSeparationAppTests`, `AccountStoreTests` (Simulator) | Reise P85-11 und „Konto löschen“ am Gerät | Inhaber am iPad |

### G5 – 4.000 aktive Nutzer

Mindestnachweis: produktionsnaher 30–120-Minuten-Mischlasttest mit 4.000 Sitzungen, p95/p99, Fehler, RAM, Queue, DB-Locks.

| Teil | Status | Beleg | Fehlt |
|---|---|---|---|
| KI: 4.000 Fragen gleichzeitig | gemessen [Mac] | BETRIEB 14: 4.000/4.000 beantwortet, normale Anfragen p95 832 ms (4 Prozesse, Attrappe 10–20 s) | Serverlauf. **Achtung:** seit Audit P7-03 (08.11.) lief `tools/lasttest-ki.py` nicht mehr – jede Frage 503 `ai_not_configured` (behoben auf diesem Zweig, Bericht Nr. 2) |
| Registrieren/Anmelden/Abgleich hinter einer Campus-IP | gemessen [Mac] | LAUNCH-4000 2: 1.000/1.000 Registrierungen, 4.000 Anmeldungen, 4.000 Pushes, 0 Fehler (64 Clients, 4 Prozesse) | Serverlauf |
| accounts.db unter Dauerlast | gemessen [Mac] | Audit 50–54: 12 Prozesse, 120 s, 0 „database is locked“, WAL ≤ 7,8 MB, Backup 83 ms | Serverlauf (SSD des CPX42) |
| **Dauerlast 4.000 Sitzungen** | gemessen [Mac], Kurzlauf | `tools/lasttest-dauer.py` (neu), Ergebnis Abschnitt 3.3 | Serverlauf 30 min |
| Lauf auf dem CPX42 | **offen** [Server] | Werkzeug `tools/lasttest-server.sh` mit Attrappen-Test (`test_g5_*`) | Lauf, Abschnitt 3 |
| Echte Netz-/TLS-Last über Caddy | nicht getestet | – | bewusst nicht im Serverlauf (der Wegwerf-Container hat kein Netz); für 4.000 nicht entscheidend (Caddy ohne `max_conns`, LAUNCH-4000 1.3). Optional später mit k6 von außen gegen eine eigene Test-Domain (`tools/lasttest-k6.js`) |
| Job-Fenster 08:00/15:00 bei 4.000 Konten | gemessen [Mac] | Audit 50–54: ≈ 4,6 min für 4.000 Konten (4 Arbeiter) | Serverlauf nicht nötig vor dem Launch; im Betrieb `dienst-check` |

### G6 – Betrieb und Wiederherstellung

Mindestnachweis: Überwachungsalarme, Backup-Restore, kontrollierter Worker-/Host-Ausfall, Incident- und Rollback-Runbook.

| Teil | Status | Beleg | Fehlt | Wer |
|---|---|---|---|---|
| Überwachung alle 5 Minuten | vorhanden, Einrichtung auf dem Server zu bestätigen | `deploy/dienst-check.sh` + Timer, `tests/test_dienst_check.py`; Probe `systemctl list-timers \| grep uniflow` | Timer bestätigen und einmal einen Alarm auslösen und die Mail sehen (z. B. `DIENST_CHECK_DISK_PCT=1 bash deploy/dienst-check.sh --verbose`, eine Mail an support@) | Claude per SSH, Inhaber (Postfach) |
| Uptime von außen | offen | BETRIEB 12 nennt UptimeRobot/Uptime Kuma | ohne Prüfung von außen merkt niemand einen Ausfall des ganzen Hosts (dienst-check läuft auf demselben Host) | Inhaber (10 min, kostenlos) |
| Tägliches Backup | erfüllt [Server] laut BETRIEB 9 | `deploy/backup.sh`, Timer 03:30, `tests/test_audit_paket_50_54.py` (`p51_10`, `p52_10`) | – | – |
| **Sicherung außer Haus** | **erfüllt [Server]** | BETRIEB 9: seit 09.11.2026 Storage Box Falkenstein, erste Kopie und Probe-Wiederherstellung auf dem Mac erfolgreich (`integrity_check` ok, `tools/sicherung-ausser-haus-einrichten.sh --pruefen`) | – | – |
| Restore mit Inhaltsvergleich und Dienststart (P84-03, P62-12) | erfüllt [Mac][Test], offen [Server] | `tools/restore-probe.py` (neu): Archiv in leeren Ordner, `integrity_check` je DB, Dienst startet auf den Daten, Stichproben 200; Hash je Datenbank vor/nach gleich (`test_p84_03_*`) | dasselbe mit dem echten Archiv auf dem Server: `lasttest-server.sh --phasen restore` (Abschnitt 5) | Claude per SSH (10 min) |
| API-Prozess hart beendet | erfüllt [Mac][Test] | `lasttest-dauer.py --kill-worker-nach`: uvicorn ersetzt den Prozess (~1 s), bestätigte Schreibvorgänge vollständig; KI-Reservierung weder verloren noch doppelt (`test_p52_05_*`) | Serverlauf (Phase `dauer` tötet nach 10 min einen Prozess) | Claude per SSH |
| Job-Container hart beendet | erfüllt [Test] | `test_p51_08_jobs_process_frees_jobs_left_running_by_a_killed_predecessor`; `test_p52_08_four_thousand_queued_jobs_are_each_claimed_exactly_once` | auf dem Server nicht nötig vor dem Launch | – |
| Host-Ausfall (P84-02) | offen, Runbook vorhanden | BETRIEB 9 „Ernstfall“ (neuer Server, Kopie von der Box, Schritt 0–5), `tools/server-umzug.sh` | RTO einmal messen (Probeaufbau eines zweiten CPX auf Stundenbasis) – **nach** dem Launch | Claude per SSH + Inhaber (Hetzner) |
| Rollback-Runbook | **neu**, Abschnitt 6 | – | vor dem nächsten Deploy einmal `docker tag` des laufenden Images | Claude per SSH |

## 2. P0/P1-Maßnahmen aus Paket 87

| Nr. | Maßnahme | Status | Beleg / was fehlt | Wer | Aufwand |
|---|---|---|---|---|---|
| P0-1 | Exakt Build 25 testen | offen | G1: TestFlight-Install von Build 25, Reisen Abschnitt 4 | Inhaber am iPad | 30 min |
| P0-2 | StoreKit-Reconciliation | teilweise | G3: Code meldet beim nächsten Start erneut; Swift-Test fehlt, Gerätetest fehlt | Agent Käufe (Test), Inhaber (iPad) | 1 h + 20 min |
| P0-3 | Notizen gegen Verlust (Gerät) | offen | G2 | Inhaber am iPad | 45 min |
| P0-4 | Produktionsnahe 4.000er-Lastabnahme | offen, Werkzeug fertig | G5, Abschnitt 3 | Claude per SSH | 1 h 15 min |
| P0-5 | Backup-Restore und Löschregister | teilweise | Außer-Haus-Probe ok (Mac); Dienststart auf Restore und Löschregister auf dem Server offen (Abschnitt 5) | Claude per SSH | 15 min |
| P0-6 | Release-Entscheidung mit Monitoring und Rollback | teilweise | Commit/Konfiguration per `--trocken`; Alarm-Mail einmal sehen; Rollback Abschnitt 6; Drosselgrenzen Abschnitt 6.3 | Claude per SSH, Inhaber | 30 min |
| P1-7 | Campus-NAT, Login-Spitzen | erfüllt [Mac], Server offen | LAUNCH-4000 1.1/2 (eine IP, 1.000 Registrierungen ohne 429); Phase `anmeldung` des Serverlaufs mit denselben Grenzen wie in LAUNCH-4000 3 | Claude per SSH | im G5-Lauf |
| P1-8 | Stud.IP-Fehler, große Dateien, alte Semester | Gerät | läuft seit 06.11. nur auf dem iPad (Passwort bleibt am Gerät); Swift-Tests `StudIPDownloadGapAppTests`, `AbnahmeSemesterReihenfolgeAppTests`; Reise P85-02/03 | Inhaber am iPad | 20 min |
| P1-9 | Community Ende-zu-Ende | Gerät | 1.0: Community über CloudKit (`communityViaService = false`); Reise P85-09 mit zwei Apple-IDs | Inhaber (2 Geräte) | 20 min |
| P1-10 | KI-Quoten, Monatswechsel, Jahresabo | erfüllt [Test] | Agent „KI/Lernplan“; Reservierung vor dem Anbieter unter Gleichzeitigkeit (`tests/test_ai_lastfest.py`), Credits-Regeln (`tests/test_credit_regel_2026_11_08.py`) | – | – |
| P1-11 | iPad-Bedienbarkeit (Rotation, Split View, VoiceOver, große PDFs) | Gerät | Swift `AccessibilityAppTests`, `LayoutWidthAuditTests` (Simulator) | Inhaber am iPad | 20 min |
| P1-12 | Review-Konten, Datenschutz, App Privacy, CloudKit Production | ASC | APP-STORE.md (Review Notes, Nutrition Labels); CloudKit-Schema in Production deployt? | Inhaber in ASC / CloudKit Console | 20 min |

## 3. Server-Lasttest (G5) – vorbereitet, Claude startet ihn per SSH

### 3.1 Was `tools/lasttest-server.sh` tut – und was nicht

- startet aus dem **vorhandenen** Image `uniflow-app:latest` (derselbe Code wie die Produktion) einen eigenen Container
  `uniflow-lasttest-<zeit>` mit `--network none` (kein Netz nach außen: kein OpenAI, keine Mail, keine Hochschule; der Dienst im
  Container lauscht nur auf seinem eigenen 127.0.0.1, am Host ist kein Port offen), `--memory 6144m`, `--cpus 6`, `--cap-drop ALL`,
  einziger eingebundener Ordner `/tmp/uniflow-lasttest-<zeit>` (Rechte 700). Keine `.env`, keine Schlüssel.
- Phasen im Container: `ki` (4.000 KI-Fragen gleichzeitig gegen die Attrappe, 10–20 s Antwortzeit, 12 Prozesse), `anmeldung`
  (1.000 Registrierungen, 4.000 Anmeldungen, 4.000 Syncs, 3.000 gemischt, alle hinter einer Campus-IP, Grenzen wie in LAUNCH-4000 3),
  `dauer` (4.000 Sitzungen auf 1.000 Konten, 30 min, 400 Anfragen/s = je Sitzung eine je 10 s, 5 % KI, nach 10 min SIGKILL eines
  API-Prozesses, danach Wiederanlauf-Sturm aller 4.000 Sitzungen in 60 s, Prüfung jedes bestätigten Schreibvorgangs), optional
  `restore` (Abschnitt 5).
- schreibt alle 5 s CPU/RAM des Hosts (`/proc`) und `docker stats` von Lasttest **und** Produktion mit (nur lesend).
- **Wächter:** fällt `MemAvailable` unter 2 GB oder wird `uniflow-app` „unhealthy“, beendet er den eigenen Container sofort.
- **Vorprüfung** (verweigert mit Exit 2, startet nichts): Image fehlt, Produktion nicht „healthy“, `MemAvailable` < 8 GB, unter /tmp
  < 5 GB frei, Uhrzeit außerhalb 0–7 Uhr (sonst `--auch-tagsueber`).
- räumt immer auf (auch bei Fehler, Strg-C): `docker rm -f` nur des eigenen Namens, Ordner unter /tmp gelöscht.
- vergleicht Zustand und Neustartzähler der Produktion vorher/nachher („Produktion unveraendert“).
- **beruehrt nie**: `docker compose`, `exec/stop/restart/rm/kill` eines Produktionscontainers, Volumes `uniflow_uniflow-data` /
  `-logs`, die Checkout `/srv/uniflow/app` (nur `git rev-parse` lesend). Test: `test_g5_server_load_test_*` mit docker-Attrappe,
  die jeden Aufruf mitschreibt.
- **Grenze der Aussage:** misst den Dienst auf der echten Hardware (CPU, SSD, Kernel), aber ohne TLS/Caddy und mit dem Lastgeber im
  selben Container (er kostet selbst CPU; Ergebnis also eher vorsichtig). Die Produktion läuft nebenher und teilt sich die 8 Kerne –
  darum nachts und mit `--cpus 6`.

### 3.2 Genauer Befehl (vom Mac des Inhabers, Repo-Wurzel, Zweig mit diesen Werkzeugen)

```bash
# 1. Werkzeuge auf den Server (eigener Ordner, die Produktions-Checkout bleibt unberuehrt)
git archive HEAD tools/lasttest-server.sh tools/lasttest-ki.py tools/lasttest-ki-anbieter.py tools/lasttest-anmeldung.py \
    tools/lasttest-dauer.py tools/lasttest_dienst.py tools/restore-probe.py \
  | ssh -i ~/.ssh/studinow_server root@46.225.32.3 \
    'rm -rf /root/studinow-lasttest && mkdir -p /root/studinow-lasttest && tar -x -C /root/studinow-lasttest'

# 2. Vorpruefung und Fingerabdruck der Produktion (startet nichts; G1 "produktiver Commit")
ssh -i ~/.ssh/studinow_server root@46.225.32.3 'bash /root/studinow-lasttest/tools/lasttest-server.sh --trocken'

# 3. Lauf (nachts 0-7 Uhr; ~45 min: ki ~2 min, anmeldung ~3 min, restore ~2 min, dauer 30 min + Sturm + Aufbau)
ssh -i ~/.ssh/studinow_server root@46.225.32.3 \
  'nohup bash /root/studinow-lasttest/tools/lasttest-server.sh --phasen "restore ki anmeldung dauer" > /root/lasttest.log 2>&1 &'

# 4. Verfolgen und Ergebnis holen
ssh -i ~/.ssh/studinow_server root@46.225.32.3 'tail -n 30 /root/lasttest.log'
scp -i ~/.ssh/studinow_server -r root@46.225.32.3:/root/lasttest/ ~/Studora-Builds/lasttest-server/
```

Kleinerer erster Lauf (zum Prüfen der Mechanik, ~5 min): `LT_KI_FRAGEN=200 LT_REGISTER=100 LT_LOGINS=400 LT_SYNCS=400
LT_MIXED=300 LT_SESSIONS=400 LT_DAUER_KONTEN=100 LT_RATE=40 LT_DAUER_MIN=2 LT_KILL_NACH=60 LT_STURM_S=20 bash … lasttest-server.sh`.
Abbrechen: `pkill -f lasttest-server.sh` – das Skript räumt beim Beenden auf; zur Not `docker rm -f $(docker ps -q --filter label=studinow.lasttest=1)`.

### 3.3 Abnahme (vor dem Lauf festgelegt; Vorschläge aus P82/P87, keine Messwerte)

| Messgröße | Grenze für BESTANDEN | Quelle im Ergebnis |
|---|---|---|
| unerwartete Fehler (ohne 401 bei absichtlich falschem Passwort) | < 1 % je Phase und im Dauerlauf | `anmeldung.json` Status, `dauer.json` `total.error_pct` |
| normale Anfragen p95 (Anmelden, Abo-Stand, Abgleich) | < 1 s; Sync p95 < 2 s | `anmeldung.json`, `dauer.json` Minutenwerte, `ki.json` `under_load` |
| KI 4.000 gleichzeitig | 4.000/4.000 beantwortet, normale Anfragen unter KI-Last p95 < 2 s | `ki.json` |
| verlorene bestätigte Schreibvorgänge | **0** | `dauer.json` `writes.missing` (sonst Exit 1) |
| SIGKILL eines API-Prozesses | Ersatz < 10 s, Fehler nur in dieser Minute | `dauer.json` `killed` |
| Wiederanlauf-Sturm (4.000 × 3 Anfragen in 60 s) | < 1 % Fehler, p99 < 5 s | `dauer.json` `storm` |
| Speicher | kein OOM-Abbruch, `MemAvailable` min > 2 GB, RSS je Prozess stabil über 30 min (kein stetiges Wachsen) | `host.csv`, `dauer.json` `rss_mb` je Minute |
| accounts.db | WAL bleibt begrenzt (< 64 MB) | `dauer.json` `wal_mb` |
| Produktion | „Produktion unveraendert“, keine `PROBLEM`-Zeile im `dienst-check.log` während des Laufs | `lasttest.log`, `/srv/uniflow/dienst-check.log` |
| erreichte Rate | Anfragen je Minute ≈ 24.000 (sonst ist der Lastgeber der Engpass – mit `LT_CPUS=7` oder `LT_RATE` niedriger wiederholen und das so notieren) | `dauer.json` `minutes[].n` |

Ergebnis in docs/release/LAUNCH-4000-2026-11-08.md (neue Zeile „Server“ je Tabelle) und hier unter G5 als **[Server]** eintragen,
je Zeile BESTANDEN / FEHLGESCHLAGEN / NICHT GETESTET.

### 3.4 Mac-Kurzlauf des Dauerwerkzeugs (09.11.2026, nicht der Serverlauf)

4.000 Sitzungen, 12 Prozesse, 400 Anfragen/s, 4 min: 96.000 Anfragen, 0,065 % Fehler (nur beim SIGKILL), normale Anfragen
p95 33–43 ms (eine Minute 1 s, ungeklärt), Ersatzprozess nach ~1 s, Sturm 12.000 Anfragen in 60 s ohne Fehler (p99 414 ms),
46.550 bestätigte Schreibvorgänge, 0 fehlend. Ein erster Lauf zeigte einen Einbruch (1.274 Verbindungsfehler in einer Minute),
wahrscheinlich das Verbindungslimit des Macs (128) – auf dem Server gezielt darauf achten. Einzelheiten:
docs/audit/AUDIT-2026-11-09-PAKET-62-82-87.md, Abschnitt 3. **[Mac]**, nicht [Server].

## 4. iPad-End-to-End (Paket 85) – Abnahmeliste für den Inhaber

Mit **genau Build 25 aus TestFlight** (nicht Xcode), Produktionsdienst, LUH. Je Reise: BESTANDEN / FEHLGESCHLAGEN / NICHT GETESTET,
bei Fehler Bildschirmfoto + Uhrzeit (damit Claude im Zugriffsprotokoll nachsehen kann).

| ID | Prio | Schritte | Soll | Automatisch vorhanden (Simulator) |
|---|---|---|---|---|
| P85-01 | BLOCKER | App löschen, aus TestFlight neu installieren → „Mit Apple anmelden“ → LUH | Start ohne Fehler, Tarif „Probe“ | `FirstStartAppTests`, `AbnahmeV1LUHReleaseAppTests` |
| P85-02 | BLOCKER | Stud.IP-Login → erster Abgleich → ein Modul öffnen | Vorlesung/Übung/PDF sichtbar | `StudIPDownloadGapAppTests`, `LibraryShelfAppTests` |
| P85-03 | HOCH | „Auch frühere Semester laden?“ → Ja; danach in Stud.IP eine Datei ändern (falls möglich) und „Jetzt abgleichen“ | alte Semester da, geänderte Datei neu | `AbnahmeSemesterReihenfolgeAppTests` |
| P85-04 | BLOCKER | PDF öffnen, 30 s mit Pencil schreiben, **sofort** App-Umschalter → App wegwischen → neu öffnen | alle Striche da | `ResumeAppTests`, Editor-Tests |
| P85-05 | HOCH | Flugmodus an, schreiben, App schließen, Flugmodus aus, öffnen, „Jetzt abgleichen“; zweites iPad (gleiches Konto, Pro AI) | gleicher Stand auf beiden | `SyncOrderAppTests` |
| P85-06 | HOCH | dasselbe PDF in zwei Fenstern (Split View) | zweites Fenster nur lesend bzw. Übergabe, nichts still überschrieben | `EditorHardeningStep2Tests` |
| P85-07 | HOCH | Modul → KI-Test aus Übungen/Skripten mit Seitenbegrenzung | Fragen nur aus gewählten Seiten | `KIAbnahmeLUHAppTests` |
| P85-08 | HOCH | Karteikarten erzeugen, eine bearbeiten, wiederholen, App neu starten | Fortschritt erhalten | `FlashcardsAppTests`, `FlashcardTrainerTests` |
| P85-09 | HOCH | Community: Lösung teilen (Gerät A), auf Gerät B (andere Apple-ID) sehen, kommentieren, auf A zurückziehen | verschwindet bei B | `CommunityCloudKitTests`, `SolutionSharingTests` |
| P85-10 | BLOCKER | Plus kaufen (Sandbox-Hinweis im Kaufblatt), dann Pro AI; StudiNow-Konto angemeldet; zweites iPad „Käufe wiederherstellen“ | Tarif auf beiden; KI mit 100 Credits | `PurchaseTests`, `PurchaseAccountLinkP36Tests`, `StoreKitP44Tests` |
| P85-11 | HOCH | abmelden → anderes Konto anmelden | keine Dokumente/Notizen des ersten Kontos | `DataSeparationAppTests` |
| P85-12 | BLOCKER | alle Reisen oben mit Build 25 aus TestFlight gegen app.studinow.app | – | – |

Varianten, die ohne zweites Gerät gehen: Hoch-/Querformat, Stage Manager, Dynamic Type groß, VoiceOver kurz an. Was das iPad nicht
hergibt (zweites Gerät, zweite Apple-ID): als NICHT GETESTET notieren, nicht weglassen.

## 5. Ausfall, Wiederherstellung, Chaos (Paket 84) – Stand und Checkliste

| ID | Prio | Szenario | Stand | Beleg / Schritt |
|---|---|---|---|---|
| P84-01 | BLOCKER | API-Container/Prozess unter Last stoppen | Prozess: [Mac][Test]; Server: Phase `dauer` | `lasttest-dauer.py --kill-worker-nach`; ein Container-Stopp der **Produktion** ist ein Deploy (BETRIEB 8, 30 s `stop_grace_period`) – nicht als Test |
| P84-02 | BLOCKER | Host weg, RTO | Runbook vorhanden, nicht geübt | BETRIEB 9 „Ernstfall“; Übung nach dem Launch (zweiter CPX stundenweise, Kopie von der Box, `restore-probe.py`, DNS nicht umstellen) |
| P84-03 | BLOCKER | komplettes Backup auf isolierter Umgebung, Hashes | [Mac][Test] erfüllt; [Server] Phase `restore` | `test_p84_03_backup_restores_into_an_empty_folder_…`; auf dem Server mit dem echten Archiv: `lasttest-server.sh --phasen restore` |
| P84-04/05 | HOCH | Job-Worker SIGKILL/SIGTERM | [Test] | `test_p51_08_*` (SIGKILL), `app/jobs.py` STOP_GRACE_S 25 s; Wiederholung über das nächste Fenster |
| P84-06 | HOCH | Datenbank gesperrt | [Test][Mac] | busy_timeout 15 s, Middleware schreibt nicht (LAUNCH-4000 0.2), 12 Prozesse × 120 s ohne „database is locked“ (Audit 50–54, `test_p54_09_*`); Sperr-Fälle in `tests/test_audit_paket_11_12.py` u. a. |
| P84-07 | HOCH | Platte voll bei Upload/Sync | [Test] | 507 `storage_full` unter `LERNAPP_DISK_MIN_FREE_MB` (`tests/test_launch_4000.py`, `test_p50_index_upload_keeps_the_disk_reserve`), `dienst-check` ab 80 % |
| P84-08 | HOCH | KI-Anbieter 429/503/Timeout | [Test] | `tests/test_ai_lastfest.py` (`ai_provider_busy`, Retry-After, keine Doppelabrechnung) |
| P84-09 | HOCH | Stud.IP 30 min weg | entfällt im Dienst | Hochschul-Abgleich läuft seit 06.11. nur auf dem iPad; Rücknahme `UniRenewalPolicy.backoff` / `UniAutoLogin.backoff` (exponentiell bis 2–4 h) |
| P84-10 | HOCH | 4.000 Clients reconnecten in einer Minute | [Mac] Sturm; [Server] Phase `dauer` | iPad: Abgleich mit dem Dienst nur bei Öffnen/Vordergrund/Knopf, höchstens alle 3 min (`StudoraAccountLink.autoSyncInterval`), kein Timer-Takt → kein enger Wiederholungssturm; **kein Jitter** im Client (Befund für 1.0.1, Bericht) |
| P84-11 | HOCH | altes Backup nach Kontolöschung | [Test] erfüllt | `test_p57_06_*`, BETRIEB 9 Schritt 0 |
| P84-12 | BLOCKER | Mehrhost/100k-Failover | nicht für 4.000 | Abschnitt 7 |

**RPO/RTO (Vorschlag, mit dem Inhaber festzulegen):** Konten/Notizen im Dienst RPO ≤ 24 h (tägliches Archiv 03:30, außer Haus danach),
bei Hostausfall RTO ≤ 4 h (neuer Server + Kopie von der Box, BETRIEB 9). Notizen liegen zusätzlich auf dem iPad (Gerät ist Quelle,
der Dienst Kopie) – ein Dienstverlust kostet für iPad-Nutzer im Regelfall keine Notizen, nur den Abgleich zum Zweitgerät.

## 6. Rollback und Drosseln

### 6.1 Dienst

Heute löscht `docker image prune -f` nach jedem Update das alte Image (BETRIEB 8) – ein Rollback heißt dann neu bauen (3–4 min).
Vor dem **nächsten** Deploy:

```bash
cd /srv/uniflow/app && git rev-parse --short HEAD > /root/vorheriger-commit.txt
docker tag uniflow-app:latest uniflow-app:vorher           # laufendes Image aufheben
cd deploy && /srv/uniflow/app/deploy/backup.sh               # Archiv vor dem Update
git pull && docker compose up -d --build
# Rollback, falls p95/5xx im dienst-check steigen:
docker tag uniflow-app:vorher uniflow-app:latest && docker compose up -d --no-build
git -C /srv/uniflow/app checkout "$(cat /root/vorheriger-commit.txt)"   # Checkout passend zum Image
```

Datenbank-Schema: `init_db` migriert nur vorwärts (Spalten/Tabellen dazu); ein älterer Code-Stand läuft auf dem neueren Schema
weiter, solange keine Spalte entfernt wurde – vor einem Deploy mit Schemaänderung das Archiv oben nicht überspringen.

### 6.2 App

Build 25 bleibt; Fehler in Build 25 → Build 27/28 hochladen (BUILD-HERKUNFT). Notbremsen in ASC: TestFlight-Link deaktivieren,
„Phased Release“ für die Store-Version anhalten, Verkauf in Ländern vorübergehend entfernen.

### 6.3 Drosselgrenzen (sofort in `deploy/.env`, dann `docker compose up -d`)

| Symptom | Schalter |
|---|---|
| KI-Kosten oder Anbieter-429 | `LERNAPP_AI_BUDGET_EUR` / `LERNAPP_AI_TRIAL_BUDGET_EUR` senken (harte Grenze), `LERNAPP_AI_CONCURRENCY` senken |
| CPU dauerhaft > 80 % | `LERNAPP_AI_RATE_PER_MINUTE` 6 → 3; Welle 2 der Einladungen verschieben |
| Massenregistrierung | `LERNAPP_LIMIT_REGISTER_ALL` senken |
| Speicher | `UVICORN_WORKERS` 12 → 8 |

## 7. 100.000 – nur Fahrplan (Paket 83)

Kein Umbau vor dem 15.11. Ausgangspunkt ist der Fahrplan in docs/audit/AUDIT-2026-11-08-PAKET-50-54.md (letzter Abschnitt) und
docs/SKALIERUNG-GROSS.md. Kennzeichnung nach P83: **IMPLEMENTIERT / PROTOTYP / GEPLANT / NICHT GETESTET**.

Globaler Zustand heute (P83 Arbeitsauftrag 2):

| Zustand | Ort | Mehrhost-tauglich? | Phase |
|---|---|---|---|
| Konten, Sitzungen, Grenzen, Credits, KI-Budget, Jobs | `accounts.db` (SQLite, WAL) | nein → PostgreSQL | C, GEPLANT |
| Community, Bibliothek | `community.db`, `test_library` | nein → PostgreSQL | C, GEPLANT |
| Konto-Daten | `users/<id>/lernapp.db` je Konto | nur mit Routing Konto→Host oder Postgres | C/D, GEPLANT |
| Uploads, Community-Pakete | lokales Volume | nein → Objektspeicher mit signierten Links | D, GEPLANT |
| API-Rate-Limit `_api_rate`, KI-Gleichzeitigkeit, „zuletzt gesehen“-Sammler, Mail-Warteschlange, `_user_dbs_ready` | RAM je Prozess | nein → Redis/Postgres; Mail → durable Queue | C, GEPLANT |
| Hochschul-Abgleich | iPad (seit 06.11.) | entfällt im Dienst | IMPLEMENTIERT |
| Drittanbieter (OpenAI, Bedrock, Apple, STRATO, CloudKit) | extern | globale Token-/Kostenbudgets je Minute | E, GEPLANT |

Reihenfolge A–F wie P83 (A = dieser Launch: messen; B Abstraktionen; C zentraler Zustand; D Dateien/Jobs; E horizontale Skalierung;
F 100k-Nachweis mit 10k → 25k → 50k → 100k). Kein 100k-Versprechen aus 4k-Messungen.
