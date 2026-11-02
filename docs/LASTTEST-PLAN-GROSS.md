# Lasttest-Plan für den großen Dienst (bis 20.000 gleichzeitig) und Betrieb auf einem großen Rechner

Stand 02.11.2026. Gehört zu `docs/SKALIERUNG-GROSS.md` (Rechnung und Kosten). Dieser Plan beantwortet die eine Frage, die
die Rechnung nicht beantworten kann: **Trägt ein großer Rechner wirklich 2.000 bis 3.000 Anfragen je Sekunde?**

**Nichts hiervon ist bisher ausgeführt.** Das Werkzeug (`tools/lasttest-aufbau.py`, `tools/lasttest-k6.js`) ist geschrieben;
das Konten-Skript habe ich mit 40 Konten und einem echten Server-Prozess ausprobiert (alle sechs Lesepfade antworten mit
Bearer-Token 200). Das k6-Skript ist nur auf Syntax geprüft (k6 ist hier nicht installiert). **Der Lasttest selbst kostet
Geld (gemietete Rechner) und startet erst, wenn du es sagst.** Preise unten sind Schätzungen aus dem Gedächtnis.

---

## 1. Was getestet wird und was nicht

| Getestet | Nicht getestet (eigene Messung nötig) |
| --- | --- |
| Lesende Anfragen mit Anmeldung (Übersicht, Module, Dateien, Tarife) durch Caddy, TLS und alle API-Prozesse | Notizen schreiben, Likes, Kommentare unter Last (Community einzeln gemessen: `tools/lasttest-community.py`) |
| Anmeldung prüfen und `last_seen` schreiben in `accounts.db` (ca. 330 Schreibvorgänge je Sekunde bei 20.000) | Hochschul-Abgleich mit Chromium (`jobs`), KI-Aufrufe, Stripe |
| Speicher, CPU und „database is locked“ des Rechners | Ausfall und Wiederherstellung (Backup-Test ist ein eigener Punkt, Abschnitt 6) |

Umrechnung: **1 Anfrage je Sekunde ≈ 10 gleichzeitig angemeldete Nutzer** (Annahme: je Nutzer eine Anfrage alle 10 s).
Stufen 250, 500, 1.000, 2.000, 3.000 Anfragen je Sekunde ≈ 2.500 bis 30.000 Nutzer.

---

## 2. Was du brauchst und was es kostet (Schätzung)

| Was | Größe | Kosten |
| --- | --- | --- |
| **Dienst-Rechner** | 32 bis 48 dedizierte Kerne, 64 bis 128 GB RAM, 500 GB NVMe, nach Stunde abgerechnet (z. B. Hetzner-Cloud „CCX“ oder gleichwertig) | grob 0,5 bis 1,5 € je Stunde |
| **Last-Rechner** (k6) | 16 Kerne, 32 GB RAM, gleiche Region, **eigener Rechner**, nie derselbe wie der Dienst | grob 0,3 € je Stunde |
| Test-Domain | Unterdomain wie `lasttest.studora.de` auf die IP des Dienst-Rechners | 0 € |
| Zeit | Aufbau 1 bis 2 Stunden, Test 1,5 Stunden, Abbau 15 Minuten | |
| **Insgesamt für einen Nachmittag** | | **etwa 5 bis 15 €** |

Wichtig:
- Ein neues Konto beim Anbieter darf oft nur kleine Rechner anlegen. Für 32+ Kerne vorher beim Support ein höheres Limit
  anfragen (dauert Stunden bis Tage). Das ist die häufigste Verzögerung.
- Nach dem Test **beide Rechner und alle Volumes löschen**, sonst läuft die Rechnung weiter.
- Nur Testkonten (`@lasttest.invalid`). Keine echten Daten auf diese Rechner kopieren.

---

## 3. Aufbau (Dienst-Rechner)

Wie `docs/START-DIENST-CHECKLISTE.md` Abschnitte 1 bis 6, mit diesen Unterschieden:

1. Server mit **Ubuntu 24.04**, Docker installieren, Repository klonen (Abschnitte 3 und 4 der Checkliste).
2. `deploy/.env` aus der Vorlage; **zusätzlich zu den Pflichtwerten** (Domain, Geheimnis) für den Test:

| Variable | Testwert | Warum |
| --- | --- | --- |
| `UVICORN_WORKERS` | Kerne minus 4, z. B. `40` bei 48 Kernen | ein API-Prozess je Kern (95 Anfragen je Sekunde und Prozess gemessen) |
| `API_MEMORY` | Prozesse × 300 MB, z. B. `12G` | Speichergrenze des API-Containers |
| `LERNAPP_LIMIT_REGISTER_IP` | `300/60` | gilt für Registrierung, hier unkritisch, aber wie im Betrieb |
| `LERNAPP_JOB_WORKERS` | `1` | der Test braucht keine Browser-Abgleiche; spart Speicher |

3. `docker compose up -d --build`, dann prüfen: `docker compose ps` (alle drei „healthy“), `curl -s https://lasttest.studora.de/login | head -3`.
4. **Konten anlegen** (20.000 Konten brauchen auf 48 Kernen etwa 3 bis 4 Minuten, auf 4 Kernen etwa 30 Minuten):

```bash
cd /srv/uniflow/app/deploy
docker compose cp ../tools/lasttest-aufbau.py app:/tmp/lasttest-aufbau.py
docker compose exec -w /srv/uniflow app python /tmp/lasttest-aufbau.py --data-dir /data --accounts 20000 --out /tmp/tokens.json
docker compose cp app:/tmp/tokens.json /root/tokens.json
```

5. `tokens.json` auf den Last-Rechner kopieren (`scp`), danach auf dem Dienst-Rechner löschen. Die Datei enthält gültige
   Sitzungen der Testkonten, sonst nichts.

---

## 4. Durchführung (Last-Rechner)

```bash
# k6 installieren: https://grafana.com/docs/k6/latest/set-up/install-k6/  (Paketquelle für Ubuntu)
ulimit -n 100000
k6 run -e BASE_URL=https://lasttest.studora.de -e TOKENS=tokens.json -e MAXVUS=8000 \
       --summary-export=ergebnis.json tools/lasttest-k6.js
```

Das Skript fährt die Stufen 250, 500, 1.000, 2.000, 3.000 Anfragen je Sekunde, jede 5 Minuten, und **bricht selbst ab**, sobald mehr
als 1 % der Anfragen scheitern. Zum Probieren zuerst `-e STEPS=100 -e STEP_MIN=1`.

Währenddessen auf dem Dienst-Rechner in einem zweiten Fenster:

```bash
docker stats --no-stream            # CPU und Speicher je Container
uptime                              # Auslastung des Rechners
docker compose logs --since 5m app | grep -ci "locked"      # Zahl der "database is locked"
```

---

## 5. Ergebnis lesen

| Messwert | Gut | Handeln |
| --- | --- | --- |
| p95 der Antwortzeit | unter 500 ms in der Stufe | darüber: Stufe merken, Ursache unten suchen |
| Fehlerrate (`http_req_failed`) | unter 0,1 % | über 1 % bricht der Test ab |
| `server_errors_5xx` | 0 | jede 500: Protokoll des Containers lesen |
| „database is locked“ im Protokoll | 0 | tritt es auf: Schreibvorgänge von `accounts.db` (`last_seen`, Sitzungen) sind der Engpass, siehe SKALIERUNG-GROSS Abschnitt 9 Nr. 6 |
| CPU des Dienst-Rechners | unter 80 % | bei 100 % und guten Zeiten: Reserve fehlt, mehr Kerne |
| Last-Rechner selbst | unter 80 % CPU | sonst misst du den Last-Rechner, nicht den Dienst: zweiten Lastgeber starten |

**Deine Zahl** ist die höchste Stufe, die alle Werte einhält. Beispiel: Stufe 2.000 ist grün, 3.000 reißt → der Dienst
trägt belegbar ca. 20.000 gleichzeitige Nutzer, Spitzen darüber nicht. Dann in `deploy/.env` genau diese Prozesszahl
lassen und im Betrieb mit `docker stats` beobachten.

---

## 6. Abbau und Nacharbeit

1. Beide Rechner löschen, Volumes und Snapshots auch. In der Rechnung des Anbieters prüfen, dass nichts weiterläuft.
2. `tokens.json` überall löschen.
3. Ergebnis (`ergebnis.json`, die gehaltene Stufe, Kerne und RAM) in `docs/SKALIERUNG-GROSS.md` Abschnitt 4 nachtragen.
4. **Sicherung wirklich zurückspielen** (an einem kleinen Testrechner, nicht nur sichern): `docs/release/BETRIEB.md`.

---

## 7. Betrieb auf einem großen Rechner: Unterschiede zur Checkliste

Die Checkliste `docs/START-DIENST-CHECKLISTE.md` ist die Schritt-für-Schritt-Anleitung (Server, Domain, DNS, Docker, `.env`,
Mail, Stripe, OpenAI, Backups, Start). Sie bleibt die einzige Anleitung, damit sich nichts widerspricht. Für den großen
Rechner ändert sich nur:

| Thema | Standard (Checkliste) | Großer Rechner |
| --- | --- | --- |
| Rechner | 2 vCPU / 4 GB, 40 GB Platte | 32–48 Kerne, 128 GB, **2 × 2 TB NVMe** (Platten spiegeln) |
| API-Prozesse | 2, Speichergrenze 768 MB | `UVICORN_WORKERS`, `API_MEMORY` in `deploy/.env` (Vorlage Abschnitt 8b) |
| Registrierung | `LERNAPP_LIMIT_REGISTER_IP=300/60` | gleich oder höher, sonst sperrt ein Hörsaal-NAT neue Studenten |
| Mail | 3.000 Mails gratis | größerer Tarif beim Mail-Anbieter (bei 100.000 Konten rechnen mit 50–100 € im Monat) |
| KI | Probe 5 €, gesamt 50 € | `LERNAPP_AI_TRIAL_BUDGET_EUR` und `LERNAPP_AI_BUDGET_EUR` an die Zahl der Kunden anpassen (SKALIERUNG-GROSS Abschnitt 8) |
| Sicherung | Storage Box 1 TB | 5 TB, nächtlich plus Test der Wiederherstellung |
| Ausfall | ein Rechner, Ausfall = Dienst aus | Für Ausfallsicherheit **nicht** einfach einen zweiten Rechner dazustellen (SQLite-Dateien lassen sich nicht zwischen zwei Rechnern teilen); ein zweiter, gleich großer Rechner mit täglich zurückgespielter Sicherung ist die einfache Reserve |
| Hochschul-Abgleich (`jobs`) | 2 Arbeiter | getrennten Rechner dafür erwägen; die Browser nehmen sonst der API die Kerne weg |

**Reihenfolge, wenn du alles selbst machen willst:** (1) Checkliste auf dem kleinen Standardrechner bis zum Ende durchgehen,
(2) mit echten Nutzern starten, (3) erst bei Bedarf auf den großen Rechner umziehen (Anbieter-Funktion „Rechner vergrößern“
oder Sicherung zurückspielen), (4) Lasttest vorher in diesem Plan.
