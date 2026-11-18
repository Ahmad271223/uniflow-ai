# Datei-Eingang langer Zufallsname unter `studinow.app` (18.11.2026: „über 50 Buchstaben … damit ihn niemand findet“; der Name
steht nicht im Repo, nur in `~/Studora-Builds/private_keys/eingang-adresse.txt`)

Auftrag des Inhabers: „nur an anderen server schicken erstmal ohne erklären bitte aber geordnet unbedingt“; Adresse
langer Zufallsname unter `studinow.app` (18.11.2026: „über 50 Buchstaben … damit ihn niemand findet“; der Name
steht nicht im Repo, nur in `~/Studora-Builds/private_keys/eingang-adresse.txt`). Gebaut auf Zweig `app/datei-eingang`. **Nichts davon ist gestartet.**

## Was es tut

Neue Kurs-PDFs (Vorlesung, Übung, Lösung, Skript, Altklausur) gehen nach dem Abgleich einmal an den Eingang und
liegen dort geordnet unter `geordnet/<Hochschule>/<Studiengang>/<Semester>/<Modul>/<Art>/`. Jede Datei liegt nur einmal
auf der Platte (`dateien/`), die Ordnung besteht aus harten Links. Keine KI, keine Konto-ID, keine IP-Adressen.
Technik: `app/intake_server.py`, Ticket `app/intake_api.py`, Gerät `CourseFileIntake` / `CourseFileIntakeRunner`.

## Einrichten (erst nach Okay des Inhabers)

1. **Rechner mieten** (Inhaber, Hetzner-Konsole): ein eigener Cloud-Server, z. B. CX23, Ubuntu, Standort Nürnberg oder
   Falkenstein, dazu ein **Volume** für die Dateien (Größe siehe unten). IPv4-Adresse notieren.
2. **DNS** (Inhaber, dort wo `A app` für `studinow.app` liegt): `A <langer Name>` → IPv4 des neuen Rechners.
3. **Starten** (Sitzung, nur mit Okay): Repo-Stand auf den Rechner, `deploy/eingang/.env` aus `.env.example`,
   `LERNAPP_INTAKE_SECRET=$(openssl rand -hex 32)`, dann in `deploy/eingang/`: `docker compose up -d --build`.
   Prüfen: `curl https://<langer Name>.studinow.app/intake/v1/health` → `{"ok": true}`.
4. **Dienst verbinden** (Server-Deploy, nur mit Okay): in `deploy/.env` von `app.studinow.app`
   `LERNAPP_INTAKE_URL=https://<langer Name>.studinow.app` und dasselbe `LERNAPP_INTAKE_SECRET`, Dienst neu starten.
5. **App** (nur mit Okay): Zustimmungstext und Datenschutzerklärung freigeben, dann mit dem nächsten Build ausliefern.

## Platz auf der Platte (Schätzung, nicht gemessen)

Annahme 10.000 Studierende, etwa 1.500 verschiedene Kurse, je Kurs etwa 3 neue PDFs pro Woche, im Mittel etwa 3 MB:
rund 650 Dateien bzw. 2 GB am Tag, rund 250 bis 300 GB je Semester. Mit 300 bis 500 GB Volume anfangen und
beobachten (`du -sh /var/lib/docker/volumes/*eingang-data*`).

## Offen

- Datenschutzerklärung: neuer Absatz zum Datei-Eingang (Entwurf folgt, nur mit Okay).
- Rechtliche Prüfung: dauerhaftes Sammeln von Lehrmaterial.
- Beim Zusammenführen: eine Zeile in `StudoraAccountCard.swift` (Einstellungen werden in `app/aufraeumen-17-11` umgebaut).

## Wie versteckt der lange Name ist

- Erraten kann ihn niemand (56 Zeichen Zufall). Die App kennt ihn nicht fest: sie bekommt die Adresse mit jedem
  Ticket vom Dienst.
- Aber: Jedes HTTPS-Zertifikat steht in öffentlichen Zertifikats-Listen (Certificate Transparency, z. B. crt.sh).
  Wer dort nach `studinow.app` sucht, sieht auch den langen Namen. Ganz unsichtbar wäre er nur mit einem
  Sammel-Zertifikat (`*.studinow.app`), dafür braucht Caddy Zugriff auf die DNS-Verwaltung (bei STRATO nicht per
  Schnittstelle möglich).
- Der eigentliche Schutz: Ohne Ticket des Dienstes nimmt der Eingang nichts an, und es gibt gar keinen Weg, Dateien
  herunterzuladen. Wer den Namen findet, sieht nur „404“.
