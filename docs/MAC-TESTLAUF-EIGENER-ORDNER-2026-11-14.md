# Tests am Mac laufen in einem eigenen Ordner

Stand: 14.11.2026, Zweig `fix/mac-test-abschottung` (von `fix/mac-durchlauf`, darin `develop` `1c2fd03a`).
Anlass: `docs/MAC-DURCHLAUF-2026-11-14.md`, Abschnitt 6.3.

## Kurz

- **Vorher:** Ein Testlauf am Mac war dieselbe App wie dein StudiNow am Mac. Die Tests sahen dein Konto, deine
  Stud.IP-Anmeldung und deine KI-Gespräche und haben dort Dinge hinterlassen.
- **Jetzt:** Für Tests am Mac wird eine eigene Test-App gebaut. Sie hat einen anderen Namen im System
  (`de.uniflow.ai.mactest`). Der Mac gibt ihr deshalb einen eigenen, leeren Datenordner, einen eigenen Bereich im
  Schlüsselbund und eigene Einstellungen. An dein StudiNow kommt sie nicht heran.
- **Riegel:** Startet jemand die Tests am Mac auf dem alten Weg, beendet sich der Testlauf sofort, bevor er etwas
  anfasst.
- **Die App im Store ändert sich nicht.** Am iPad und iPhone ändert sich auch nichts.

## Warum dieser Weg

Zur Wahl standen zwei Wege:

| | Weg (a): App öffnet unter Test nichts Echtes | Weg (b): eigene Kennung für Mac-Tests |
|---|---|---|
| Wer trennt? | Code in der App, an vielen Stellen | das Betriebssystem |
| Datenordner | bleibt derselbe; nur der Container wird nicht geöffnet | eigener Ordner |
| Einstellungen (`UserDefaults.standard`) | bleiben die echten: 126 Stellen in den Tests und viele Ansichten greifen direkt darauf zu | eigene |
| Schlüsselbund | jede Stelle müsste einzeln umgebogen werden | eigener Bereich |
| alte Web-Datenspeicher | entstünden weiter im echten Ordner | entstehen im Test-Ordner |
| Eingriff in die App | viele Stellen im ausgelieferten Code | keiner im ausgelieferten Code |

Gewählt: **Weg (b)**. Er trennt alles auf einmal und kann nichts übersehen, weil nicht der Code trennt, sondern
der Mac. Bei Weg (a) hätte ich viele Stellen im Code der App ändern müssen, und eine vergessene Stelle hätte wieder
echte Daten getroffen.

Die Schwäche von Weg (b): Er wirkt nur, wenn der Testlauf richtig gestartet wird. Darum gibt es dazu den Riegel
(unten) und ein Skript, das alles richtig einstellt.

## Was geändert wurde

1. **`apps/apple/project.yml`:** Nur im Test-Bau (Debug) lässt sich die Kennung der App von außen setzen
   (`UF_DEBUG_BUNDLE_ID`). Ohne Angabe bleibt sie `de.uniflow.ai`. Der Bau für TestFlight und App Store (Release)
   nimmt weiter die feste Kennung und kennt die neue Einstellung nicht (nachgeprüft: mit und ohne Angabe
   `de.uniflow.ai`).
2. **`tools/mac-test.sh`:** der eine Weg, Tests am Mac zu starten. Das Skript
   - baut die Test-App mit der Test-Kennung, ohne „Mit Apple anmelden“ und iCloud (`Config/MacTest.entitlements`).
     Dadurch reicht das allgemeine Profil des Teams; **im Apple-Entwicklerkonto wird nichts angelegt oder geändert**;
   - prüft vor dem ersten Start die Signatur: Die Test-App darf nur ihren eigenen Schlüsselbund-Bereich haben. Sonst
     bricht es ab;
   - startet die Tests und meldet die Test-App danach beim Mac wieder ab, damit Links und Dateien weiter in deinem
     StudiNow aufgehen.
3. **Riegel in der App (`MacTestGuard.swift`, nur im Test-Bau):** Läuft ein Test am Mac ohne die Test-Kennung, beendet
   sich die App in der ersten Zeile des Starts, vor Konto, Container und Dateien. Im Protokoll steht dann
   „Testlauf am Mac abgebrochen …“ mit dem Hinweis auf das Skript.
4. **Neuer Test `MacTestIsolationTests`:** Er merkt sich, was die App beim Start des Testlaufs vorfand, und schlägt
   fehl, wenn das ein geöffneter Container, Stud.IP-Cookies oder eine KI-Ablage waren. Er prüft auch den Riegel und
   dass der Mac-Lauf die Test-Kennung hat. Er läuft auch im Simulator (dort muss die Test-App ebenfalls leer sein).

## So startet man Tests am Mac

Der Mac muss entsperrt und wach sein. Es öffnen sich Fenster einer leeren StudiNow-Test-App.

```bash
tools/mac-test.sh -only-testing:UniFlowTests/MacTestIsolationTests
```

Mehrere Klassen: weitere `-only-testing:UniFlowTests/<Klasse>` anhängen. Das Protokoll liegt unter
`~/Studora-Builds/mac-test/`.

Nicht mehr verwenden: `xcodebuild test … variant=Designed for iPad` von Hand und
`~/Studora-Builds/wt-editor-mac-test.sh`. Beide enden jetzt am Riegel.

## Stand der Prüfung

**Noch nicht fertig geprüft.** Am 14.11.2026 gegen 23:10 Uhr hat die Hauptsitzung um Ruhe auf dem Rechner gebeten
(voller Testlauf für Build 42). Meine zwei Läufe (Mac-Bau der Test-App, Simulator-Lauf) habe ich darum abgebrochen.

| Prüfung | Stand |
|---|---|
| Kennung je Bauart (`xcodebuild -showBuildSettings`): Debug ohne Angabe `de.uniflow.ai`, Debug mit Angabe `de.uniflow.ai.mactest`, Release mit und ohne Angabe `de.uniflow.ai`, Testbundle unverändert | geprüft, stimmt |
| Python-Prüfungen zur Projektdatei (`tests/test_release_gate.py`, `test_release_build_provenance.py`, `test_release_texts.py`) | 45 bestanden |
| Signieren der Test-App mit dem allgemeinen Team-Profil, ohne Zugriff auf das Apple-Konto | Xcode nimmt es an (der Bau lief bis ins Übersetzen, dann abgebrochen). Die Signatur der fertigen App ist noch nicht geprüft. |
| Übersetzen der neuen Dateien | **offen** (kein Bau zu Ende gelaufen) |
| Lauf im iPad-Simulator-Klon („iPad Testordner“, Klon von `4495AA80-…`) | **offen** |
| Lauf am Mac über `tools/mac-test.sh`, klassenweise | **offen** (braucht Entwarnung und einen entsperrten Mac) |
| `tutor-conversations.json` im echten Ordner vor und nach dem Mac-Lauf gleich | **offen**. Stand vorher: zuletzt geändert 14.11.2026 20:36:10, 4318 Bytes |

Für die offenen Läufe vorgesehen: `MacTestIsolationTests`, `StudoraNameTests`, `RecordingSourcesAppTests`,
`FlashcardsAppTests`, `LockVisibilityAppTests`, `TutorCardsRunAppTests`, `ViewTypeDepthAppTests`, `KeychainTests`,
`DataSeparationAppTests`.

## Aufräumen im echten Ordner – nicht gemacht, bitte entscheiden

Ich habe im Datenordner deines StudiNow am Mac nichts gelöscht und nichts geändert. Angesehen habe ich nur
Dateinamen, Anzahlen und Änderungszeiten, keine Inhalte.
Ordner: `~/Library/Containers/6196C4B8-3DE8-4CB8-AA41-0D7B27BB53C3/Data/Library/`

### 1. Die 7 Test-Gespräche in der KI-Ablage

Datei: `Application Support/UniFlowContainers/<Container>/tutor-conversations.json`. Es gibt zwei solche Dateien: die
vom 14.11.2026 (4318 Bytes, die 7 Test-Einträge) und eine kleine vom 09.11.2026 (359 Bytes). Der 09.11. war auch ein
Mac-Testtag; ob diese zweite Datei ein Test-Rest ist, zeigt erst ein Blick auf die Kennungen.

Sicherer Weg:

1. StudiNow am Mac beenden (sonst schreibt die App ihren Stand wieder zurück).
2. Beide Dateien sichern (in einen Ordner außerhalb, z. B. `~/Studora-Builds/sicherung-ki-ablage-2026-11-14/`).
3. Nur die Einträge entfernen, deren Kennung zu den Tests gehört: `exam:8:1`, `f-1`, `f-area-…`, `f-sn-…`. Alles
   andere bleibt stehen. Nicht die ganze Datei löschen, falls inzwischen ein echtes Gespräch dazugekommen ist.
4. StudiNow öffnen und unter den letzten KI-Gesprächen nachsehen. Wenn etwas fehlt: Sicherung zurückkopieren.

Das kann eine Sitzung in wenigen Minuten machen. Es fehlt nur dein Okay.

### 2. Die alten Web-Datenspeicher aus Testläufen

Ordner: `WebKit/WebsiteDataStore/`. Dort liegen inzwischen **761** Unterordner (im Bericht waren es 533). Zu deinem
StudiNow gehören nur die, die genauso heißen wie ein Ordner in `Application Support/UniFlowContainers/` – das sind
**2** (du hast 3 Container, für einen gibt es noch keinen Web-Speicher). Die übrigen 759 stammen aus Testläufen. Sie
enthalten keine Daten von dir, kosten aber Platz.

Sicherer Weg:

1. StudiNow am Mac beenden.
2. Die 759 Ordner nicht löschen, sondern in einen Ordner außerhalb verschieben
   (z. B. `~/Studora-Builds/sicherung-webspeicher-2026-11-14/`). Die 2 Ordner mit den Namen deiner Container bleiben.
3. StudiNow öffnen und prüfen: Stud.IP, QIS und Uni-Mail sind noch verbunden.
4. Nach ein paar Tagen ohne Auffälligkeit den Sicherungsordner löschen.

Schlimmster Fall, wenn doch ein falscher Ordner erwischt würde: Du müsstest dich bei der Uni einmal neu anmelden.
Noten, Dateien und Notizen liegen woanders und sind davon nicht betroffen.

### 3. Leistenlage im Editor

`LockVisibilityAppTests` hat bei früheren Mac-Läufen deine Einstellung der Leistenlage gelöscht. Falls du „Unten
fest“ gewählt hattest, steht sie jetzt wieder auf „Oben fest“. Bitte in den Einstellungen einmal nachsehen.

## Frage an dich

Sollen die 7 Test-Gespräche und die 759 alten Web-Datenspeicher auf dem beschriebenen Weg entfernt werden
(mit Sicherung)? Ohne dein Okay bleibt alles, wie es ist.

## Nebenbei aufgefallen (nicht Teil dieser Aufgabe)

- Die Oberflächen-Tests `UniFlowUITests` am Mac laufen nicht über den Riegel (dort startet die App als eigener
  Prozess ohne XCTest-Umgebung). Über `tools/mac-test.sh` bekommen sie die Test-Kennung; von Hand gestartet liefen sie
  weiter in der echten App.
- `~/Studora-Builds/wt-editor-mac-test.sh` ist jetzt überholt (endet am Riegel).
