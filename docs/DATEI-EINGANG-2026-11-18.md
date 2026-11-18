# Datei-Eingang ohne Domain (18.11.2026)

Auftrag des Inhabers: „nur an anderen server schicken erstmal ohne erklären bitte aber geordnet unbedingt“, dann
„ohne … Domain-Name … einfach auf Server schicken, im Backend Serveradresse angeben“ (Umbau 18.11.2026). Gebaut auf
Zweig `app/datei-eingang`; App-Teil für 1.0.6 auf Zweig `app/eingang-testbuild` (Basis `896ca45a`).
**Nichts davon ist gestartet.**

## Schalter über den Build (Entscheidung des Inhabers 18.11.2026)

**Stand 18.11.2026 abends (Inhaber: „Ja, auch im Store“):** Release (App Store, TestFlight, Kabel-Fassungen) hat
`UF_INTAKE_OFFERED=YES` in `apps/apple/project.yml`; der Eingang ist dort **von selbst an**, der Nutzer schaltet ihn
unter **Einstellungen → Uni-Zugang & Abgleich** aus. Debug (Simulator, App-Tests) bleibt `NO`.

| Fassung | Build-Einstellung | Was der Nutzer sieht |
|---|---|---|
| App Store / TestFlight 1.0.6 (Release) | `UF_INTAKE_OFFERED=YES` (project.yml) | Karte „Kursdateien teilen“ mit Schalter, von selbst an (nur mit StudiNow-Konto, nicht in der Demo, nur im WLAN) |
| Debug (Simulator, Tests) | `UF_INTAKE_OFFERED=NO` | nichts; es wird nichts geschickt |

**Vor dem Einreichen von 1.0.6:** Absatz in Nutzungsbedingungen (§6) und Datenschutz (§7a, §7, §1) live auf der
Website, App-Datenschutzangabe in App Store Connect um „Nutzerinhalte“ ergänzen. Ein Release-Build ohne Eingang geht
weiter mit `UF_INTAKE_OFFERED=NO` auf der Kommandozeile.

Die Einstellung landet als `UFIntakeOffered` in der Info.plist, die App liest sie in `CourseFileIntakeSetting.isOffered`.
Nur ein ausdrückliches `YES` schaltet ein; fehlt der Wert oder ist er leer, bleibt es aus.

**Test-Build bauen** (Archiv für TestFlight; Hochladen wie in `docs/UEBERGABE-2026-11-14.md`, nur mit Okay):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/apple && xcodegen generate -q
xcodebuild archive -project UniFlow.xcodeproj -scheme UniFlow -configuration Release \
  -destination generic/platform=iOS -archivePath ~/Studora-Builds/StudiNow-Eingang-Test-NN.xcarchive \
  UF_INTAKE_OFFERED=YES CURRENT_PROJECT_VERSION=NN -allowProvisioningUpdates
```

- (bis 18.11. abends: eigener Test-Build; seit „Ja, auch im Store“ ist jeder Release-Build so gebaut.)
- Den Test-Build in App Store Connect **nie zur Prüfung einreichen**, nur in TestFlight an die zwei Tester geben
  (interne Tester brauchen einen Zugang zu App Store Connect; externe Tester brauchen die Beta-Prüfung von Apple).
- Prüfen, dass es wirklich der Test-Build ist:
  `/usr/libexec/PlistBuddy -c "Print :UFIntakeOffered" ~/Studora-Builds/StudiNow-Eingang-Test-NN.xcarchive/Products/Applications/UniFlow.app/Info.plist`
  → `YES` (seit 18.11. abends auch beim App-Store-Archiv).
- Zum Ausprobieren im Simulator: `xcodebuild build … UF_INTAKE_OFFERED=YES` (Debug).

## Was genau gesendet wird (und was nie)

Nur nach Zustimmung, nur mit angemeldetem StudiNow-Konto, nur im WLAN, nie in der Demo, nie unter XCTest, nach jedem
Abgleich (`StudIPSync.autoPlan`). Zuerst fragt das Gerät mit `POST /api/intake/check`, welche Dateien fehlen; nur die
gehen mit `POST /api/intake/file` hoch. Jede Datei je Platz einmal (Merker `intake_sent` auf dem Gerät).

- **Datei:** die Original-PDF aus dem Kurs (wie heruntergeladen; Notizen und Markierungen des Editors liegen getrennt
  und gehen nicht mit), nur Vorlesung, Übung, Lösung, Skript, Altklausur aus aktiven Kursen, höchstens 80 MB.
- **Karteikarte:** Prüfsumme (SHA-256), Studiengang (nur falls im Studienverlauf gewählt), Semester, Modul, Art,
  Dateiname, Kursname, Veranstaltungsnummer, Woche, Seitenzahl; dazu die Hochschule.
- **An den Dienst:** die Anmeldung des Kontos (Sitzungs-Token). Der Dienst zählt damit je Konto und Tag (höchstens 300
  Dateien, Tabelle `intake_days` ohne Bezug zu den Dateien) und reicht nur Hochschule und Datei weiter.
- **Nie:** Name, Konto-ID, E-Mail, Notizen, eigene Dokumente (Kurs `__user__`), Organisatorisches, Dateien
  inaktiver Kurse. Listen mit Namen/Matrikelnummern/Noten werden vorher aussortiert (siehe Lücken).

## Lücken (ehrlich)

- **Namenslisten-Filter ist eine Wortregel** (`CourseFileIntake.looksLikeNameList`, gleich wie der Server): Dateiname
  mit Wörtern wie „Teilnehmerliste“, „Notenliste“, „Matrikel“; oder ≥ 5 Zahlen mit 7–8 Stellen bzw. ≥ 2 solche Wörter
  im Text der **ersten 3 Seiten**. Nicht erkannt werden u. a.: eingescannte Listen ohne Textebene (das Gerät liest
  hier keinen OCR-Text, dann zählt nur der Dateiname), Listen nur mit Namen oder Punkten („Punkteliste“, „Bonuspunkte“,
  „Zulassung“, „Ergebnisse“ stehen nicht in der Regel), Matrikelnummern mit anderer Stellenzahl, Listen ab Seite 4.
  Der Server prüft dieselbe Regel noch einmal (mit dem Text der ersten Seiten), mehr nicht.
- **Eigene Abgaben in Kursordnern:** lädt ein Studierender eine Lösung in einen Stud.IP-/Learnweb-Ordner hoch, liegt
  sie bei ihm als Kursdatei und kann als „Lösung“/„Übung“ hochgehen – mit seinem Namen im Inhalt oder Dateinamen. Der
  Urheber (`author`) wird nicht geprüft.
- **Dateiname geht mit:** steht ein Name im Dateinamen, steht er auch in der Karteikarte.
- **Der Dienst sieht, wer schickt** (Anmeldung, IP-Adresse wie bei jeder Anfrage); nur der Eingang erfährt es nicht.
- Datenschutzerklärung und rechtliche Prüfung (dauerhaftes Sammeln von Lehrmaterial) stehen aus – auch für den
  Test mit zwei Testern sollten die beiden Bescheid wissen.

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
- Gerät: `CourseFileIntake` (Kern), `AccountCourseFileIntake` (über das Konto), `CourseFileIntakeRunner` und
  `CourseFileIntakeCard` (App, `apps/apple/UniFlow/Services/CourseFileIntakeRunner.swift`).

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
6. **App** (nur mit Okay): erst der Test-Build (oben), später für alle nur nach Freigabe von Zustimmungstext und
   Datenschutzerklärung – dann `UF_INTAKE_OFFERED` in `project.yml` für Release auf `YES`.

## Platz und Last (Schätzung, nicht gemessen)

Annahme 10.000 Studierende, etwa 1.500 verschiedene Kurse, je Kurs etwa 3 neue PDFs pro Woche, im Mittel etwa 3 MB:
rund 650 Dateien bzw. 2 GB am Tag durch den Dienst, rund 250 bis 300 GB je Semester auf dem Eingang. Je Konto höchstens
300 Dateien am Tag (`FILES_PER_DAY`). Mit 300 GB Volume anfangen und beobachten.

## Offen

- Datenschutzerklärung: neuer Absatz zum Datei-Eingang (Entwurf folgt, nur mit Okay).
- Rechtliche Prüfung: dauerhaftes Sammeln von Lehrmaterial.
- Ohne Eingang auf dem Server (Schritte 1–5) antwortet der Dienst `503 intake_off`; die App bleibt dann still und
  versucht es beim nächsten Abgleich wieder. Für den Test also erst den Eingang starten.
