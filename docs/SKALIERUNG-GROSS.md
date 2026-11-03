# StudiNow-Dienst für 20.000 gleichzeitige Nutzer: Rechnung, Messung, Kosten, KI

Stand 02.11.2026. Gilt für den **eigenen Dienst** (Web, Windows, Konten, Community auf dem Server). Die iPad-App der
Version 1 läuft ohne diesen Dienst: ihre Community geht über CloudKit bei Apple und skaliert mit Apple, nicht mit deinem
Server. Dazu gehört das Geld für Server, Mail und KI nicht.

**Wichtig vorweg.** Gemessen ist hier nur, was ein Prozess auf einem 4-Kerne-Rechner schafft (Abschnitt 4 und
`docs/LASTTEST-DIENST-2026-10-30.md`). Alles für 20.000 gleichzeitig ist **hochgerechnet**, nicht ausprobiert. Preise sind
Schätzungen aus dem Gedächtnis, nicht aus den heutigen Preislisten der Anbieter. Vor jeder Bestellung prüfen.

---

## 1. Kurzfassung

| Frage | Antwort |
| --- | --- |
| Schafft der Dienst heute 20.000 gleichzeitig? | **Nicht mit der heutigen Einstellung** (2 API-Prozesse, ein Rechner mit 4 GB). Der Aufbau trägt es mit viel mehr Rechenkernen, aber das ist nicht gemessen. |
| Was ist der Engpass? | Die **normalen Anfragen** (Übersicht, Lernplan, Anmeldung prüfen): rund 2.000 je Sekunde, dafür etwa 32 bis 48 Rechenkerne. Nicht die Community: Ansehen, Liken und Kommentieren belasten wenig. |
| Was hast du heute schon gewonnen? | Das **Ansehen einer Lösung ist 1,5- bis 3-mal schneller** (Abschnitt 4). |
| Speicher? | Lösungen: 40 GB bis 160 GB. Konten: 150 GB bis 1,5 TB (mittlere Annahme 600 GB). Insgesamt **1 bis 2 TB schnelle Platte** plus gleich viel für Sicherungen. |
| Leitung? | Spitze bei 2 MB je Lösung etwa 190 bis 370 MBit/s; im Semester 11 bis 23 TB (Abschnitt 6). |
| Kosten? | Ein großer Rechner plus Zubehör: **etwa 300 bis 450 € im Monat** ohne KI (Schätzung). KI nach Verbrauch, gedeckelt (Abschnitt 8). |

---

## 2. Annahmen (ändere sie, dann ändern sich die Zahlen)

| Annahme | Wert | Warum |
| --- | --- | --- |
| Konten insgesamt | 100.000 | 20 % davon gleichzeitig online = 20.000 (Klausurwoche, Vorlesungsbeginn) |
| Anfragen je aktivem Nutzer | 1 alle 10 Sekunden | wie im Lasttest vom 30.10. (Abschnitt 5 dort) |
| Lösungen im Semester | 20.000 | 10.000 Autoren mit je 2 Lösungen. **Das ist eine Annahme von mir**, du hast keine Zahl genannt. |
| Ansichten je Lösung | 100 bis 200 verschiedene Personen | dein Wunsch („100–200 mal angeschaut“ habe ich als Mal gelesen) |
| Wiederholungen | jede Person öffnet sie im Schnitt 3-mal | „auch mehrmals“; sinkt, wenn das Gerät das Paket behält |
| Größe einer Lösung | 0,5 MB, 2 MB (Grundannahme), 8 MB | verschlüsseltes Paket mit Notizen, Obergrenze 65 MB |
| Likes / Kommentare | 10 % / 2 % der Ansichten | Schätzung |
| Spitze gegenüber Mittel | 20-fach | Abende und Klausurwochen |
| Semester | 17 Wochen | |

---

## 3. Last durch normale Anfragen

- 20.000 gleichzeitig × 1 Anfrage je 10 s = **2.000 Anfragen je Sekunde** (4.000, wenn alle alle 5 s etwas tun).
- Ein API-Prozess trägt laut Lasttest vom 30.10. etwa **90 bis 100 Anfragen je Sekunde** (lesend).
- 2.000 ÷ 95 = **21 Prozesse bei voller Auslastung, 35 bei 60 %** (so plant man). Bei 4.000: 42 bzw. 70.
- Heute läuft der Dienst mit `--workers 2` (`deploy/Dockerfile:62`), 768 MB für die API (`deploy/docker-compose.yml`).
  Für 20.000 braucht es **32 bis 48 Rechenkerne und die Arbeiterzahl muss einstellbar werden**.
- `accounts.db` bekommt je aktiver Sitzung eine Schreibung je Minute (`last_seen`): 20.000 ÷ 60 ≈ **330 Schreibvorgänge je
  Sekunde**. In der Messung unten schafft die Community-Datenbank rund 1.200 je Sekunde mit 4 Prozessen. Mit 35 Prozessen
  gegen eine Datei ist es **nicht gemessen** („database is locked“ ist das Risiko).

---

## 4. Messung der Community (02.11.2026, 4 Kerne, Cloud-Rechner)

Werkzeug: `tools/lasttest-community.py` (legt eine Wegwerf-Datenbank mit 5.000 Mitgliedern an; misst nur die Arbeit des
Dienstes, nicht TLS und Leitung). Es traten **keine Fehler** auf (kein „database is locked“).

| Paketgröße | Vorher (einlesen und neu schreiben) | Nachher (Text einsetzen) | |
| --- | --- | --- | --- |
| 0,3 MB, 1 Prozess | 260 je s | 364 je s | |
| 0,3 MB, 4 Prozesse | 483 je s | 723 bis 785 je s | **1,5-fach** |
| 3 MB, 1 Prozess | 62 je s | 136 bis 170 je s | |
| 3 MB, 4 Prozesse | 115 je s | 339 je s | **3-fach** |
| 20 MB, 4 Prozesse | 15 je s | 29 bis 35 je s | 2-fach |
| Liken, 1 / 4 Prozesse | 372 / 1.225 je s | (unverändert) | |

**Änderung:** `app/community.py` (`get_package_raw`) und `app/community_api.py` (`download`) schicken das gespeicherte
JSON unverändert in die Antwort, statt bis zu 65 MB zu lesen, in Python-Objekte zu verwandeln und wieder zu schreiben.
Inhalt und Zähler bleiben gleich (Test `test_download_liefert_gespeicherten_text_unveraendert`; Fehler-Einbau zeigte, dass
der Test anschlägt).

**Was die Spitze der Community braucht:** 6 bis 12 Mio. Abrufe im Semester = im Mittel 0,6 bis 1,2 je Sekunde, in der Spitze
12 bis 23 je Sekunde. Das schafft schon ein Prozess mit 3-MB-Paketen (136 je s). Die Community ist also **nicht der
Engpass**.

---

## 5. Speicher

| Posten | Rechnung | Ergebnis |
| --- | --- | --- |
| Lösungen (Dateien unter `community/`) | 20.000 × 0,5 / 2 / 8 MB | **10 / 39 / 156 GB** |
| Likes | 0,2 bis 0,4 Mio. × ca. 120 Byte | 24 bis 48 MB |
| Kommentare | 40.000 bis 80.000 × ca. 400 Byte | 16 bis 32 MB |
| Konten aktiv | 30.000 × 5 / 20 / 50 MB (Notizen; Hochschul-PDFs werden im Dienst nicht gespeichert, `stream`) | **150 GB / 600 GB / 1,5 TB** |
| Konten inaktiv | 70.000 × 0,32 MB | 22 GB |
| Summe, mittlere Annahme | 39 GB + 600 GB + 22 GB | **rund 660 GB**; mit Reserve und Wachstum **1 bis 2 TB NVMe** |
| Sicherungen | `deploy/backup.sh` kopiert alles; 7 Tage Verlauf ≈ 2 bis 3-fach | **3 bis 5 TB** außer Haus |

Die Unsicherheit steckt bei den Konten (5 bis 50 MB je aktivem Konto aus dem Lasttest vom 30.10.). Messen, sobald
echte Nutzer da sind: `du -sh /data/users/* | sort -h | tail`.

---

## 6. Datenmenge und Leitung

| Paketgröße | 100 Ansichten je Lösung | 200 Ansichten je Lösung |
| --- | --- | --- |
| 0,5 MB | 6 Mio. Abrufe, **2,9 TB** | 12 Mio., **5,7 TB** |
| 2 MB | 6 Mio. Abrufe, **11,4 TB** | 12 Mio., **22,9 TB** |
| 8 MB | 6 Mio. Abrufe, **45,8 TB** | 12 Mio., **91,6 TB** |

(je Semester, mit 3 Abrufen je Person; ohne Wiederholungen ein Drittel)

- Spitze bei 2 MB: 12 bis 23 Abrufe je Sekunde × 2 MB = **190 bis 370 MBit/s**. Eine 1-GBit-Leitung reicht.
- Bei 8 MB und 200 Ansichten wären es 1,5 GBit/s in der Spitze: dann **nicht mehr** über denselben Rechner.
- Hetzner-Cloud-Rechner enthalten meist 20 TB Datenmenge im Monat, dedizierte Rechner haben eine 1-GBit-Leitung ohne
  Mengengrenze (Schätzung, prüfen). Der Bedarf liegt bei 3 bis 6 TB im Monat (2 MB), das passt.

---

## 7. Server und Kosten (Schätzung, netto, im Monat)

| Posten | Betrag | Hinweis |
| --- | --- | --- |
| Großer dedizierter Rechner, 32 bis 64 Kerne, 128 GB RAM, 2 × 2 TB NVMe | **200 bis 300 €** | z. B. Hetzner AX162-Klasse; **ein** Rechner = ein Ausfallpunkt |
| Zweiter Rechner zum Probieren und Einspringen (optional) | 0 bis 300 € | SQLite-Dateien lassen sich nicht auf zwei Rechnern gleichzeitig nutzen |
| Sicherung außer Haus, 5 TB | 15 bis 25 € | Hetzner Storage Box o. ä. |
| Domain, Monitoring | 2 bis 20 € | |
| Mail (Bestätigung, Passwort, Hinweise) bei 100.000 Konten | 50 bis 100 € | die 3.000 Gratis-Mails reichen nicht mehr |
| Cloudflare R2 o. ä. für Pakete (optional, Phase 2) | 0 bis 50 € | keine Gebühr für abgerufene Daten, aber Speicher 0,015 $/GB |
| **Summe ohne KI** | **etwa 300 bis 450 €** | Anwalt für Rechtstexte einmalig extra |
| Stripe | 1,5 % + 0,25 € je Zahlung | bei 1,99 € ca. 0,28 € |

**Gegenrechnung:** Bei 5 % zahlenden Plus-Kunden (5.000 × 1,99 € brutto) bleiben nach 19 % MwSt und 15 % Apple etwa
7.100 € im Monat. Die Infrastruktur wäre damit bezahlt. Ob 5 % stimmen, weiß ich nicht.

---

## 8. KI andocken: Analyse, Lernplaner, Erklärungen

**Schon gebaut** (`app/ai.py`, `app/plans.py`): StudiNow-KI im Dienst nur mit bestätigter E-Mail und Tarif Pro AI, Kontingente
je Monat (40 neue Tests, 150 Erklärungen/Lernfragen/Zusammenfassungen), Budgets (gesamt 50 €, je Konto 2 €, Probekonten
zusammen 5 €), gesperrt ohne Token-Preise. Dateianalyse und Wochentests laufen **einmal je Inhalt** und gelten für alle
(ca. 1 Cent je Foliensatz, `docs/KI-MODELLVERGLEICH-2026-10-25.md`).

**Kosten je Aufruf** (Annahmen: Erklärung 6.000 Token rein / 800 raus, Test 12.000 / 3.000, Lernplan-Analyse 10.000 / 2.000):

| Modellklasse (Preis je 1 Mio. Token rein/raus, **angenommen**) | Erklärung | Test | Lernplan | Pro-AI-Nutzer, Quote voll | Nutzer, 20 % der Quote |
| --- | --- | --- | --- | --- | --- |
| günstig, 0,25 € / 2 € | 0,3 Ct | 0,9 Ct | 0,65 Ct | 0,83 € | **0,17 €** |
| mittel, 1 € / 8 € | 1,2 Ct | 3,6 Ct | 2,6 Ct | 3,30 € (greift Deckel 2 €) | **0,66 €** |

Bei 3.000 Pro-AI-Kunden mit 3,99 € brutto kostet die KI also etwa 500 € bis 2.000 € im Monat und bringt rund 8.500 bis 10.000 € ein
(nach MwSt und Gebühren geschätzt). **Echte Preise des gewählten Modells in `LERNAPP_AI_PRICE_IN_EUR/OUT_EUR` eintragen.**

**Für 20.000 gleichzeitig anzupassen:**
1. `LERNAPP_AI_TRIAL_BUDGET_EUR` (5 €) ist viel zu klein: bei einem günstigen Modell nach etwa 1.600 Erklärungen gesperrt (bei einem mittleren nach 400). Bei vielen neuen Konten auf
   50 bis 100 € setzen oder die Probe ohne KI lassen.
2. `LERNAPP_AI_BUDGET_EUR` (50 €) an die Zahl der Pro-AI-Kunden anpassen (z. B. 3.000 × 0,66 € ≈ 2.000 €).
3. Eine KI-Anfrage dauert 10 bis 30 s und belegt einen Arbeits-Thread. Ein Prozess schafft damit nur wenige KI-Anfragen
   je Sekunde. Bei 3.000 Kunden sind es in der Spitze unter 5 je Sekunde, das geht, aber **mit eigener Warteschlange und
   OpenAI-Limit (Tokens je Minute) planen**.
4. Analyse der PDF und Lernplaner auf dem iPad laufen über das ChatGPT-Abo des Nutzers und kosten dich nichts.

---

## 9. Was heute fehlt, in dieser Reihenfolge

| Nr. | Was | Wer | Aufwand |
| --- | --- | --- | --- |
| 1 | **Erledigt:** Ansehen einer Lösung 1,5- bis 3-mal schneller; Messwerkzeug im Repo | Cloud | fertig |
| 2 | **Erledigt:** Arbeiterzahl und Speichergrenze einstellbar (`UVICORN_WORKERS`, `API_MEMORY` in `deploy/.env`; Standard unverändert 2 und 768M). Mit `docker compose config` geprüft, echter Start mit vielen Prozessen nicht | Cloud | fertig |
| 3 | **Vorbereitet:** Lasttest mit bis zu 3.000 Anfragen je Sekunde auf einem gemieteten Rechner (`tools/lasttest-aufbau.py`, `tools/lasttest-k6.js`, Plan `docs/LASTTEST-PLAN-GROSS.md`), ca. 5–15 € für einen Nachmittag | **dein OK** nötig, dann Start | offen |
| 4 | `register_ip` (30 je Stunde je Adresse) anheben, sonst sperrt das eduroam-NAT neue Studenten (`LERNAPP_LIMIT_REGISTER_IP`) | du (Einstellung) | klein |
| 5 | Pakete aus dem Objektspeicher mit zeitlich begrenzten Links ausliefern; Antwort und Zähler trennen (Vertrag ändert sich, Apps müssen mit) | Cloud + Mac | mittel, erst bei Bedarf |
| 6 | Ab etwa 5.000 gleichzeitig: Konten auf mehrere Rechner verteilen (nach Konto-Nummer) und `accounts.db` in eine echte Datenbank (PostgreSQL) | Cloud | groß, **ein Rechner ist bis dahin einfacher** |
| 7 | Uni-Abgleich durch den Dienst begrenzt auf 240 Starts je Stunde je Hochschule: bei vielen Konten übernimmt das iPad/der PC | schon so geplant | – |

**Ehrlich:** Mit Schritt 1 bis 4 ist der Dienst *voraussichtlich* bis einige Tausend gleichzeitig tragfähig. Für 20.000
gleichzeitig fehlt der Beweis (Schritt 3) und vermutlich Schritt 6. Ich würde mit **2.000 gleichzeitig starten** und mit
dem Lasttest nach oben tasten, statt blind für 20.000 zu bestellen.
