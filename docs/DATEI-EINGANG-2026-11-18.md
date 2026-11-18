# Datei-Eingang ohne Domain (18.11.2026)

Auftrag des Inhabers: „nur an anderen server schicken erstmal ohne erklären bitte aber geordnet unbedingt“, dann
„ohne … Domain-Name … einfach auf Server schicken, im Backend Serveradresse angeben“ (Umbau 18.11.2026). Gebaut auf
Zweig `app/datei-eingang`. **Nichts davon ist gestartet.**

## Was es tut

```text
App  →  StudiNow-Dienst (app.studinow.app)  →  privates Hetzner-Netz  →  Eingang (eigener Server, keine Domain)
```

Neue Kurs-PDFs (Vorlesung, Übung, Lösung, Skript, Altklausur) gehen nach dem Abgleich an den Dienst
(`POST /api/intake/check`, `POST /api/intake/file`, app/intake_api.py). Der Dienst speichert nichts und reicht sie
über das private Netz an den Eingang weiter (app/intake_server.py). Der Eingang legt jede Datei einmal ab (`dateien/`)
und ordnet sie als harte Links unter `geordnet/<Hochschule>/<Studiengang>/<Semester>/<Modul>/<Art>/`.

- Der Eingang hat keine Domain, kein Zertifikat und keinen öffentlichen Port (nur SSH). Er hört nur auf seiner
  Adresse im privaten Netz.
- Der Eingang erfährt nicht, wer geschickt hat (keine Konto-ID, keine IP-Adresse).
- Gerät: `CourseFileIntake` (Kern), `AccountCourseFileIntake` (über das Konto), `CourseFileIntakeRunner` (App).

## Einrichten

1. **Server mieten** (Inhaber, Hetzner-Konsole): CX23, Ubuntu, **im selben Gebiet wie der Dienst** (Nürnberg oder
   Falkenstein), SSH-Schlüssel `studinow_server`, dazu ein **Volume** (300 GB zum Start).
2. **Privates Netz** (Inhaber, Hetzner-Konsole → Netzwerke): „Netzwerk erstellen“ (Name z. B. `studinow-intern`,
   Zone eu-central, Bereich 10.0.0.0/16) → beide Server hinzufügen (der heutige Dienst und der neue Eingang). Die
   Konsole zeigt dann je Server eine Adresse wie `10.0.0.2` und `10.0.0.3`.
3. **Firewall** (Inhaber oder Sitzung, Hetzner-Konsole → Firewalls): für den Eingang nur SSH (22) von außen erlauben.
   Das private Netz ist davon nicht betroffen.
4. **Eingang starten** (Sitzung, nur mit Okay): Repo-Stand auf den Server, `deploy/eingang/.env` aus `.env.example`
   (`EINGANG_PRIVATE_IP`, `EINGANG_DATA` = Einhängepunkt des Volumes, `LERNAPP_INTAKE_SECRET=$(openssl rand -hex 32)`),
   dann in `deploy/eingang/`: `docker compose up -d --build`. Prüfen vom Dienst aus:
   `curl http://10.0.0.3:8780/intake/v1/health` → `{"ok": true}`; von außen darf nichts antworten.
5. **Dienst verbinden** (Server-Update, nur mit Okay): in `deploy/.env` des Dienstes
   `LERNAPP_INTAKE_URL=http://10.0.0.3:8780` und dasselbe `LERNAPP_INTAKE_SECRET`, Dienst neu starten.
6. **App** (nur mit Okay): Zustimmungstext und Datenschutzerklärung freigeben, dann mit dem nächsten Build ausliefern.

## Platz und Last (Schätzung, nicht gemessen)

Annahme 10.000 Studierende, etwa 1.500 verschiedene Kurse, je Kurs etwa 3 neue PDFs pro Woche, im Mittel etwa 3 MB:
rund 650 Dateien bzw. 2 GB am Tag durch den Dienst, rund 250 bis 300 GB je Semester auf dem Eingang. Je Konto höchstens
300 Dateien am Tag (`FILES_PER_DAY`). Mit 300 GB Volume anfangen und beobachten.

## Offen

- Datenschutzerklärung: neuer Absatz zum Datei-Eingang (Entwurf folgt, nur mit Okay).
- Rechtliche Prüfung: dauerhaftes Sammeln von Lehrmaterial.
- Beim Zusammenführen: eine Zeile in `StudoraAccountCard.swift` (Einstellungen werden in `app/aufraeumen-17-11` umgebaut).
