# Übergabe an die nächste Mac-Sitzung (30.10.2026, Rechnerwechsel)

Der bisherige Mac wird abgegeben. Die Arbeit geht auf einem anderen Rechner weiter. Was dort gebraucht wird, steht im
Repo: Code, Branches, offene Schritte und Regeln. Das Gedächtnis der Claude-Sitzung (`~/.claude/...`) wandert nicht
mit, darum stehen die wichtigsten Regeln und Entscheidungen unten noch einmal.

> **Nachtrag 30.10.2026, Cloud-Sitzung:** `wip/lernplan-woche` ist nach `develop` übernommen (ohne App-Lauf, vom
> Inhaber freigegeben), der wacklige Sync-Test ist behoben, die JS-Tests sind grün, und der Kern-Teil der
> Hintergrund-Wochentests ist gebaut. Der aktuelle Stand, die Testzahlen und die offene Liste stehen in
> `BERICHT-CLOUD-SITZUNG-2026-10-30.md`; die Abschnitte 1 und 5 unten sind damit überholt. Der erste Schritt auf dem
> Mac bleibt der volle App-Lauf, jetzt auf `develop`.

## 1. Stand auf GitHub (`Ahmad271223/uniflow-ai`)

| Ref | Commit | Inhalt | Geprüft |
| --- | --- | --- | --- |
| `develop` | `ed565d8` | Editor 3–6, Barrierefreiheit, PR #6 (Seitenmarker), iPad-Kern `weekly.py`, iPad-Oberfläche „Vorlesung bis hier“ und Wochentest-Box | voll grün: Kern 765×2, App 557×2, pytest 558, alle Generatoren |
| `wip/lernplan-woche` | `952ced2` und dieser Übergabe-Commit | Lernplan nach der Regel des Inhabers (siehe 2), KI-Wochenplan entfernt | pytest 562, alle Generatoren `--check`, Kern 765×2, App-Tests `LocalModulesAppTests` (11) grün. **Der volle App-Lauf fehlt noch.** |
| `refs/backup/mac-2026-10-30/*` | – | Ältere lokale Zwischen-Branches des alten Macs (25.–27.10.). Ihr Inhalt ist längst in `develop`, die Commits haben nur andere Prüfsummen. 27 von 84 gesichert. 57 Stände vom 25. und 26.10. lehnte GitHub ab, weil sie alte Workflow-Dateien enthalten und der Zugang des alten Macs kein `workflow`-Recht hatte. Ihr Inhalt ist in `develop`. | – |

`main` bleibt unberührt. Pull Request #6 ist geschlossen; sein Inhalt steckt in `develop`.

## 2. Was zuletzt gebaut wurde (Branch `wip/lernplan-woche`)

Entscheidung des Inhabers am 30.10.2026:
- Der KI-Wochenplan entfällt.
- Kommen neue Unterlagen, plant die App die Woche automatisch.
- In KW N stehen nur die Sachen der Lehrwoche N im Plan.
- Ältere Vorlesungen kommen nur dazu, wenn in der Vorwoche ein Seitenmarker gesetzt wurde. Dann kommt der Rest des Skripts nach dem Marker dazu.
- Word-Import ist erwünscht, aber nicht dringend. Ansehen reicht vorerst.

Umgesetzt in Python und auf dem iPad, gegen dieselben Prüfdaten:
- `app/study.py`:
  - `generate_packages` nimmt je Tag nur die Lehrwoche des Tages (`_units(..., week, done_weeks)`).
  - `_marker_rest` liefert den Skriptrest, z. B. „VL02.pdf · S. 21–50“ mit anteiliger Dauer. Es zählen nur eigene Marker, keine gelöschten und keine zu prüfenden. Ohne Marker in der Vorwoche gibt es keinen Rest. Je Lehrwoche steht ein Rest höchstens einmal im Plan.
  - `auto_plan_week` plant nach jedem Abgleich (`_full_sync`, `sync.py`).
- `app/weekly.py` `task_test` und `POST /api/tasks/{id}/start-test`: In Fächern mit Markern öffnet die Testaufgabe den gemeinsamen Wochentest. Sonst kommt 409 mit Grund.
- Entfernt:
  - `POST /api/plan/generate`, `planner.generate_plan`
  - `ai.build_week_plan`, `ai.week_plan_prompt`
  - die Wochenplan-Fälle im KI-Vertrag und in Swift
- iPad:
  - `StudyPlan.markerRest`, `plannedFileWeeks`, `autoPlanWeek`, `StudyAutoPlan.afterSync`, `Weekly.taskTest`
  - Aufruf nach dem Stud.IP-Abgleich (`StudIPSync.autoPlan`) und nach dem Learnweb-Abgleich (`HildesheimConnection`)
- Prüfdaten:
  - `study-plan.json`: Szenario „lehrwoche“ mit `auto`-Schritten
  - `weekly.json`: start-test vor und nach der Veröffentlichung
  - `tests/test_week_plan_rule.py`
- Absichtlich eingebaute Fehler werden erkannt: 5 in Python, 5 in Swift.
- Einzelheiten für die PC-Sitzung stehen in `docs/STAND-MAC-SITZUNG.md`, letzter Abschnitt.

## 3. Als Erstes auf dem neuen Rechner (Reihenfolge)

1. **Einrichten**, siehe 4.
2. **Voller App-Lauf auf `wip/lernplan-woche`**, zweimal, am Netzteil:
   - Neu ist, dass nach einem Stud.IP- oder Learnweb-Abgleich automatisch geplant wird. App-Tests, die nach einem Abgleich Lernpakete zählen, könnten dadurch anders ausfallen. Erst prüfen, dann anpassen.
   - Bekannte lastabhängige Tests einzeln wiederholen, bevor man einen Fehler annimmt: `AuditRunde11AppTests.testDiagnosisWithManyFilesKeepsTheMainThreadFree` und `HardeningSolutionEditorTests.testManyForeignLayersStayFastAndAreReleased`.
3. Wenn alles grün ist, den Branch nach `develop` übernehmen und pushen:
   - `git checkout develop && git pull && git merge wip/lernplan-woche && git push origin develop`
   - Diese Übergabe liegt auf beiden Branches mit gleichem Inhalt, der Merge läuft ohne Konflikt.
4. Danach offen, siehe 5.

## 4. Einrichten auf dem neuen Rechner

1. GitHub-Zugang: `gh auth login`. Das macht der Inhaber selbst, Zugangsdaten tippt nur er.
2. `git clone https://github.com/Ahmad271223/uniflow-ai.git && cd uniflow-ai && git checkout wip/lernplan-woche`
3. Python 3.13:
   - `python3.13 -m venv .venv && .venv/bin/pip install -r requirements.txt -r requirements-dev.txt`
   - Tests: `.venv/bin/python -m pytest -q`
   - Generatoren: `for g in tools/gen-*.py; do .venv/bin/python $g --check || echo FAIL $g; done` (`gen-ios-icons.mjs` braucht Node und gehört nicht dazu)
4. Swift-Kern: `cd apps/apple/Packages/UniFlowCore && swift test`, zweimal.
5. App:
   - `brew install xcodegen`, dann `cd apps/apple && xcodegen generate`
   - Simulator „iPad“ anlegen
   - Testlauf: `xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "platform=iOS Simulator,id=<UDID>" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO`
   - Immer ad hoc signieren, sonst geht die Schlüsselbund-PIN verloren. Nie zwei Läufe parallel auf demselben Simulator. Volle Läufe nur am Netzteil, im Akkubetrieb gibt es falsche Fehler.
6. Nicht im Repo, und das ist richtig so: `.env`, `data/`, `logs/`, `backup/`, `tools/seed-testdata.py`, `.claude/`, `apps/apple/Config/Team.xcconfig` (Team-ID, erst nach der Apple-Freigabe), `UniFlow.xcodeproj` (wird von xcodegen erzeugt).

## 5. Was danach noch offen ist

| Punkt | Wer | Stand |
| --- | --- | --- |
| Apple Developer Program | Inhaber | Die Anmeldung wurde am 28.10. abgelehnt. Ohne Freigabe gibt es kein TestFlight, keine App-Store-Einreichung, kein „Mit Apple anmelden“ auf dem Gerät. Support-Fall beim Inhaber. |
| Test mit echten Daten und Pencil am iPad | Inhaber und Mac-Sitzung | Der Inhaber meldet sich selbst bei Stud.IP und QIS an. |
| Echter ChatGPT-Test (Client-ID von OpenAI) | Inhaber | Braucht die Zulassung bei OpenAI. Danach einen Wochentest mit Marker auf echtem Skript prüfen; bisher ist alles mit simulierter KI geprüft. |
| Wochentests im Hintergrund bei geschlossener App | optional | Heute läuft der Takt nur im Vordergrund und beim Öffnen. Möglich über die Hintergrundaufgaben (8, 15, 20 Uhr). |
| Word-Import | später | Ansehen reicht laut Inhaber vorerst. |
| Android: Seite drehen mit Notizen | PC-Sitzung | Gemeinsame Fälle `rotate/cases.json` |
| Wackliger Test `tests/test_sync.py::test_push_creates_with_mapping_and_pull_with_cursor` | Mac- oder PC-Sitzung | vermutlich eine Sekundengrenze |
| Branches von Ahmad271223 (28.10., 384 Commits zurück) | Inhaber | Empfehlung: durchsehen, dann schließen. Schließen erst nach seinem Ja. |
| `node --test tests/js` | PC-Sitzung | Auf dem Mac gibt es kein Node, die Fälle liefen hier mit JavaScriptCore. |

## 6. Regeln des Inhabers (aus dem Gedächtnis der alten Sitzung)

- **Git:**
  - Nur auf `develop` arbeiten, nie an `main`, kein Force-Push.
  - Jeder Commit-Titel endet mit `[skip ci]`, GitHub Actions sind gesperrt.
  - Committen mit `git -c user.name=abcdefg34a -c user.email=af-autonord@hotmail.com commit`.
  - Dateien einzeln hinzufügen, nie `git add -A`.
  - Vor jedem Push den Diff nach Geheimnissen und persönlichen Daten durchsuchen.
- **Zugangsdaten und Kosten:**
  - Nie Passwörter, Uni-Zugänge, PIN oder Tokens eintippen; das macht nur der Inhaber.
  - Keine kostenpflichtigen Schritte ohne sein Ja.
  - Nach außen sichtbare GitHub-Schritte (PR schließen, kommentieren) vorher bestätigen lassen.
- **Arbeitsweise:**
  - Lieber gründlich als schnell: 1:1 gegen die Python-Prüfdaten portieren.
  - Fehler absichtlich einbauen und prüfen, dass die Tests sie finden.
  - Volle Testzyklen: Generatoren, pytest, Kern ×2, App ×2.
  - Antworten auf Deutsch, einfach und vollständig; alle offenen Punkte nennen.
- **App Store V1** (`docs/AUFTRAG-APPSTORE-V1.md`):
  - iPad-App ohne PC-Server, Name „Studora“, verkauft werden nur Free und Plus.
  - KI läuft über das ChatGPT-Abo des Nutzers, nie mit einem Schlüssel in der App.
- **Wochentests:** jedes Modul jede Woche, 15 Aufgaben (4 leicht, 6 mittel, 5 schwer), aus den Folien der Woche, mit genau einer Klausuraufgabe, wenn es eine Altklausur gibt.
- **Lernplan** (30.10.): wie in Abschnitt 2.
