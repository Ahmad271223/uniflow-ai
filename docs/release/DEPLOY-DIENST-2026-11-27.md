# Dienst-Update 27.11.2026 16:33 – Stand für 1.0.8 (vor dem Einreichen)

Stand: `67430b23` (`release/1.0.8-alles`, Build 52). Freigabe des Inhabers im Chat auf „Soll ich das Server-Update vor
dem Einreichen machen?“: „Ja, vorher machen“. Grund: Apple prüft die neuen Käufe (u. a. `de.uniflow.plus.fuenfjahre`)
gegen den Live-Dienst; der alte Stand kannte das Paket, die Probe mit 25 Credits und 120 Credits für Pro AI nicht.

Vorher lief `f549428b` (Prüfsummen aller Dateien unter `app/` und `deploy/` verglichen) plus `app/wake_push.py` vom
26.11. 22:23 (gleich dem Release-Stand). Server-eigen und unverändert: `deploy/docker-compose.override.yml`
(Apple-Wurzelzertifikat), `deploy/.env` (`LERNAPP_CREDITS_PRO_AI` nicht gesetzt → 120; Wissensbank-Schalter wie
vorher).

## Ablauf
1. Tests auf `67430b23`: Server 4154 bestanden (1 wackelig, allein grün), node 473; Kern 1974; iPad 2342 (2 rot,
   eingeordnet); iPhone 162; Mac Tarif-Klassen 124.
2. Backup `uniflow-2026-11-27_1631.tar.gz` (452 MB, 46 Datenbanken), `.env` nach `/root/env-vor-1-0-8-20261127-1632.bak`.
3. `git archive 67430b23 | ssh … tar -x -C /srv/uniflow/app`, `VERSION-COMMIT` = `67430b23…`.
4. `docker compose up -d --build`: `uniflow-app` und `uniflow-jobs` healthy, keine Fehlerzeilen; `dienst-check.sh
   --no-mail --verbose`: alle Prüfungen bestanden; von außen `/login` 200, API ohne Anmeldung 401.
5. Im laufenden Dienst: `plan_for_product` kennt `plus.fuenfjahre`/`plus.monthly` → plus, `proai.*` → pro_ai,
   `plus.yearly` → plus; `CREDITS` pro_ai 120, trial 25; Pakete 80/160 für 1,99/3,99 €; Göttingen bekannt.

Datenbank: nur neue Tabelle `crash_reports` (CREATE TABLE IF NOT EXISTS), sonst kein Umbau.

**Zurück:** `git archive f549428b | ssh … 'tar -x -C /srv/uniflow/app && cd deploy && docker compose up -d --build'`
(die neue Tabelle stört den alten Stand nicht; `.env` aus dem Backup unter `/root`).

## Wirkung für die Store-App 1.0.7 (Build 48) bis 1.0.8 veröffentlicht ist
Pro AI 120 statt 80 Credits; Wochentests und neue Pool-Tests kosten Credits; KI nur mit nutzbaren Credits (429);
neue Probe = 7 Tage Plus mit 25 Credits; Einladungen ohne Belohnungen (410, 1.0.7 zeigt noch den alten Hinweistext);
Plus jährlich gilt weiter. Göttinger Konten lassen sich anlegen.
