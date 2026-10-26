# Prüfpunkte 571–681 (Windows, Android) – Ergebnis der PC-Sitzung, 26.10.2026

Grundlage: `docs/PRUEFBERICHT-EXTERN-2026-10-26-TEIL2.md` (Wortlaut des externen Prüfers). Jeder Punkt wurde gegen den
Code auf `develop` geprüft; behoben wurde nur, was sich bestätigt hat, mit Regressionstest. Drei Arbeitsstränge liefen
parallel (Windows, Android-Kern, Android-Oberfläche), jeweils auf getrennten Dateien. Die Apple-Punkte 221–570 sind an
die Mac-Sitzung übergeben (`docs/STAND-MAC-SITZUNG.md`). Die Nummern 591–652 lagen nicht vor.

**Stand der Prüfung:** Python 268 Tests grün (1 unter Windows übersprungen, läuft unter Linux); Kotlin-Kern 33 Tests,
Android-App 21 Tests, Debug-APK und Release-Bundle gebaut (Docker); Rust `cargo check` und `cargo check --tests`
grün. Nicht ausgeführt: die GitHub-Workflows (Actions seit 25.10. durch die Abrechnung gesperrt), der Installer-Test
im Echtlauf (braucht den NSIS-Build auf dem Runner), Tests auf einem echten Android-Gerät.

## Zusammenfassung

| | bestätigt und behoben | identisch zum Vertrag (Entscheidung nötig) | nicht bestätigt / bereits erledigt | nur gemeldet |
|---|---|---|---|---|
| Windows (581–590, 658–660) | 13 (inkl. 1 Zusatzfund) | – | – | – |
| Android-Kern (574–577, 579–580, 653–657, 679–681) | 4 (574 teilweise, 577, 679/680, 681) | 6 (575/656, 576, 653, 654, 655, 657) | – | 2 (579, 580) |
| Android-App (661–678) | 13 | – | 3 (661, 670, 678) | – |
| Vorab erledigt (571–573, 578) | 571/572 (26.10., Android-Commit), 578 (erste App) | 573 → siehe 653 | | |

## Windows (581–590, 658–660) – alle bestätigt und behoben

| Nr. | Befund | Fix | Datei | Test |
|---|---|---|---|---|
| 581/582 | Linux-CI: `test_watch_parent_fires_when_parent_ends` rot (im Docker `python:3.14-slim` reproduziert: 1 failed). Ursache: `os.kill(pid, 0)` meldet Zombies als lebendig. | `process_alive` prüft unter Linux `/proc/<pid>/stat` (Z/X = tot, Datei weg = tot), sonst `ps -o stat=`; ohne `wait`, weil der echte Elternprozess (Tauri) kein Kind ist. | `app/desktop.py` (`_unix_process_state`, `process_alive`) | `tests/test_desktop.py::test_watch_parent_fires_when_parent_ends`, `::test_process_alive_treats_zombie_as_dead` (Linux: 15 passed) |
| 586/590 | Freier Port ermittelt, Zustandsdatei geschrieben, erst dann uvicorn gestartet (Port konnte dazwischen belegt werden; Datei sah gültig aus, bevor der Server lief). | `bind_socket()` bindet 127.0.0.1:0 und hört, erst dann Zustandsdatei, dann `uvicorn.Server(Config).run(sockets=[sock])`; belegter fester Port → Fehler statt stillem Ausweichen. | `app/desktop.py` (`bind_socket`, `serve`) | `test_desktop.py` (Socket hört sofort; Subprozess-Test: nach Erscheinen der Datei muss TCP-Connect ohne Warten klappen; belegter Port → keine Datei, Rückgabe 1) |
| 583 | Fenster prüfte die Zustandsdatei nur über den Zeitstempel. | `check_state(text, child_pid)`: `pid` in backend.json muss die PID des gestarteten Kindprozesses sein. | `apps/windows/src-tauri/src/main.rs` | Rust-Unit-Test `check_state_needs_our_pid_and_local_url` (kompiliert), `test_tauri_window_checks_backend_pid_url_and_exit` |
| 584 | Navigation zur URL aus backend.json ohne Beschränkung. | `local_port()` akzeptiert nur genau `http://127.0.0.1:<port>/` (Port 1–65535, kein Pfad/Query/https/anderer Host); `port` in der Datei muss passen; sonst Fehlerseite. | `main.rs` | Rust-Unit-Test `local_port_accepts_only_loopback_http` (11 Negativfälle) |
| 585 | 90 s Warten ohne Prüfung, ob das Backend schon beendet ist. | `child.try_wait()` in jeder Warteschleife; beendet → sofort Fehlermeldung mit Status und Protokollpfad auf der Startseite. | `main.rs` | `test_tauri_window_checks_backend_pid_url_and_exit` |
| 587 | start.js leitete im Entwicklungsmodus bei jeder HTTP-Antwort weiter. | Weiterleitung nur bei 200 und JSON mit Feld `mode`; sonst Meldung und erneuter Versuch. | `apps/windows/dist/start.js` | `test_start_page_redirects_only_on_uniflow_answer` (start.js in node mit Attrappen, 6 Fälle) |
| 588 | package.json 0.2.0, tauri.conf.json/Cargo.toml 0.3.0. | package.json und package-lock.json auf 0.3.0. | `apps/windows/package.json`, `package-lock.json` | `test_windows_app_versions_match` (vier Stellen) |
| 589 | Installer-Workflow nur manuell. | `push` auf develop bei Änderungen unter apps/windows/**, app/**, requirements.txt, Workflow-Datei; `workflow_dispatch` bleibt. | `.github/workflows/windows.yml` | `test_pyinstaller_spec_and_workflow` |
| 658 | Chromium-Verzeichnis mit festem Pfad verschoben; leerer Ordner wäre still auf Playwrights Standardpfad zurückgefallen. | `chromium-*` unter `PLAYWRIGHT_BROWSERS_PATH` suchen, bei Fehlen `throw` mit Meldung, nach dem Verschieben erneut prüfen. | `windows.yml` | `test_pyinstaller_spec_and_workflow` |
| 659 | Icons aus einer Datei unter apps/apple/. | Eigene Quelle `apps/windows/app-icon.png` (1024×1024), Workflow nutzt nur noch diese. | `windows.yml`, `apps/windows/app-icon.png` | `test_pyinstaller_spec_and_workflow` (kein „apple“ im Workflow, PNG quadratisch) |
| 660 | Installer gebaut, nie installiert. | `apps/windows/scripts/check-installer.ps1`: still installieren (`/S`), App-exe, `backend\uniflow-backend.exe`, Chromium prüfen, Backend-Starttest (`check-backend.ps1`: PID = gestarteter Prozess, URL-Form, sofortiger TCP-Connect, `mode`), still deinstallieren, Reste prüfen; Schritt zwischen `tauri build` und Artefakt-Upload. | `windows.yml`, `apps/windows/scripts/` | `test_pyinstaller_spec_and_workflow`; `check-backend.ps1` lokal gegen das neu gebaute Paket grün |
| Zusatzfund | Die gepackte `uniflow-backend.exe` (ohne Konsole, `sys.stdout = None`) stürzte in uvicorns Logging-Konfiguration (`sys.stdout.isatty()`) ab – PyInstaller-Fehlerfenster, Prozess hing; mit dem alten Code war die Zustandsdatei da schon geschrieben, das Fenster hätte ewig gewartet. | `redirect_std_streams` (beide Ströme nach `logs\backend.log`), Ausnahmen in `main` als Traceback ins Protokoll, Rückgabe 1 (das Fenster zeigt das dank 585 sofort). Paket neu gebaut, `check-backend.ps1` grün. | `app/desktop.py` | `test_desktop.py` Variante „ohne-konsole“ (Subprozess mit `sys.stdout = sys.stderr = None`) |

Beobachtung ohne Änderung: Installationsordner (`%LOCALAPPDATA%\UniFlow`) und Datenordner des Backends sind derselbe
Ordner; der Deinstallierer löscht nur installierte Dateien (Daten überleben). Eine Trennung (z. B. Daten unter
`%LOCALAPPDATA%\de.uniflow.desktop`) wäre eine Verhaltensänderung – Entscheidung des Inhabers.

## Android-Kern (apps/android/core)

| Nr. | Status | Ergebnis | Datei | Test |
|---|---|---|---|---|
| 574 | teilweise bestätigt, behoben | Behauptung „nur Seiten-Merge“ stimmt nicht: `AnnotationDocument.merge` führt das Dokument inkl. `pageOrder` zusammen. Bestätigte Lücke: alle anderen Wurzelfelder (`deletedPages`, `note`, `bookmarks`, `outline`) kamen immer vom Server – lokal geänderte gingen beim 409-Merge verloren. Jetzt nach der Feldregel aus `merge.js` (nur hier geändert → hier, nur dort → dort, beidseitig → hier + Konflikt), wie Swift `mergeRootMeta`. | `AnnotationDocument.kt` | `AnnotationDocumentTest.rootFieldsMergeLikePageFields` |
| 575/656 | identisch zum Vertrag | `merge.js index()`: letzter Eintrag je ID im Index, Ausgabe nur der erste – Kotlin und Swift exakt gleich. Nicht geändert. | `AnnotationMerge.kt` | `AnnotationMergeTest.duplicateIdsBehaveLikeMergeJs` (dokumentiert das Verhalten) |
| 576 | identisch zum Vertrag | lokal gewinnt, Serverfassung nur gezählt – `merge.js`, Swift und Fixture „dasselbe Objekt verschieden geaendert: dieses Geraet gewinnt“. Nicht geändert. | – | Fixture (SharedFixtureTest) |
| 577 | teilweise bestätigt, angeglichen | Präzisionsverlust ist identisch mit JavaScript (jede JSON-Zahl ist ein Double). Abweichend war nur der Signaturtext (`1.0E21` vs. `1e+21`); Kotlin formatiert jetzt wie ECMAScript `Number::toString`. Swift weicht hier weiter ab (`1e+15`), die Kennungen werden aber nie zwischen Plattformen ausgetauscht. | `AnnotationMerge.kt` | `AnnotationMergeTest.canonicalNumbersMatchJsonStringify` (21 Werte, gegen Node geprüft) |
| 579/580 | nur gemeldet | `android.yml`: Job `core` (`:core:test`), Job `app` (Unit-Tests, Debug-APK, Release-AAB), Auslöser push auf develop/main bei apps/android/**, Fixtures, Workflow; kein Emulator, kein Sync-Test mit Netzunterbrechung (Fixtures prüfen nur Nachrichten). | – | – |
| 653 | identisch zum Vertrag | `merge.js`: local, wenn Objekte = lokale Objekte; sonst server, wenn = Serverobjekte; sonst `perStroke(local)` → local; sonst `perStroke(server)`. Kein Signaturvergleich – Swift und Kotlin gleich. Nicht geändert. | `AnnotationMerge.kt` | `AnnotationMergeTest.drawingV2OnBothSidesTakesLocalWithoutComparingSignatures` |
| 654 | identisch zum Vertrag | v2 nur über Form erkannt (`strokeSigs` ist Array); Passung je Strich prüft der Leser (iPad). Nicht geändert. | – | derselbe Test |
| 655 | identisch zum Vertrag | Objekte ohne String-ID über Inhalt erkannt (Fixture „Objekte ohne ID werden ueber ihren Inhalt erkannt“); durch 577 jetzt zeichengleich mit dem Web. | – | Fixture |
| 657 | identisch zum Vertrag | geändert gegen gelöscht → Seite bleibt + Konflikt; unverändert gegen gelöscht → weg (Fixture). | – | `AnnotationMergeTest.pageDeletedOnOneSideAndChangedOnTheOtherStays` |
| 679/680 | bestätigt, behoben | Ungültige `changes`-/`tombstones`-Einträge und `mapping`-Zuordnungen wurden still verworfen. Jetzt strikt: `SyncFormatError(position, …)` mit Positionen wie `changes.modules[1]`, `mapping[0].id`; IDs müssen JSON-Ganzzahlen sein; fehlende Listen bleiben leer. Sync-Vertrag (`fixtures/sync/cases.json`) weiter grün. | `SyncApi.kt` | `SyncApiTest` (6), `SyncContractTest` |
| 681 | bestätigt, behoben | `status >= 400` ließ 3xx/1xx als Erfolg durch. Jetzt nur 200–299 (plus `allowStatus`, z. B. 409 bei Notizen); Meldung „Unerwartete Weiterleitung (302) nach …“. | `ApiClient.kt` | `ApiClientTest` (3), `AccountContractTest` |

Nebenbefund (nicht geändert): `AnnotationDocument.orderedPages` liest `deletedPages` als Liste von Strings, das Web
schreibt Objekte `{entry, objects, at, pos}`; wirkungslos, weil gelöschte Seiten nicht in `pageOrder` stehen.

## Android-Oberfläche (apps/android/app)

| Nr. | Status | Ergebnis | Datei | Test |
|---|---|---|---|---|
| 661 | nicht bestätigt, abgesichert | `NavHost` legt je `doc/{fileId}` einen eigenen Eintrag an; die Ansicht wird nicht wiederverwendet. Trotzdem ist der ganze Zustand jetzt `remember(fileId)`. | `DocumentScreen.kt` | – |
| 662 | bestätigt, behoben | Scheitert ein Schritt nach dem Öffnen, wird der Renderer geschlossen, Fehler gezeigt, „Erneut versuchen“; nicht öffenbares PDF wird aus dem Cache verworfen. | `DocumentScreen.kt`, `Repo.kt` | – |
| 663 (601–604) | bestätigt, behoben – zwei echte Verlustpfade | (a) `save()` ersetzte `doc` nach Bestätigung durch den gesendeten Stand – ein währenddessen gezeichneter Strich war weg; (b) Speichern beim Verlassen lief im gerade beendeten Scope. Neu `AnnotationSession`: Mutex serialisiert Speichern; bestätigter Stand ersetzt lokal nur bei Identität, sonst Drei-Wege-Merge (Basis = gesendeter Stand) und Nachsenden; Seitenwechsel während `saving` gesperrt; `BackHandler` speichert zuerst; `onDispose`/`ON_STOP` senden über einen prozessweiten Scope. 409 weiter über `core.AnnotationStore`. | `AnnotationSession.kt`, `DocumentScreen.kt`, `UniFlowApplication.kt` | `AnnotationSessionTest` (6) |
| 664 | bestätigt, behoben | Division/`createBitmap` mit 0 wären Abstürze; `InkMath.validPageSize`/`pageRatio` (A4-Rückfall), Renderer liefert bei unbrauchbarem Maß null → Statusmeldung. | `Ink.kt`, `DocumentScreen.kt` | `InkTest.pageRatioFallsBackToA4` |
| 665 | bestätigt, behoben | Strichbreite 0,3–60 pt (NaN/∞ → 2), Transparenz 0..1. | `Ink.kt` | `InkTest.widthAndOpacityAreClamped` |
| 666/667 | bestätigt, behoben | `PdfRules`: `%PDF-` in den ersten 1024 Bytes + Mindestgröße; ungültige Cache-Datei wird gelöscht und neu geladen; Download vor Übernahme geprüft (`not_pdf`), `.part` → atomar umbenannt. | `Pdf.kt`, `Repo.kt` | `PdfRulesTest` (2) |
| 668 | bestätigt, behoben | `toPoints` lehnt scale ≤ 0/NaN/∞ ab; die Ansicht überspringt solche Eingaben. | `Ink.kt` | `InkTest.scaleMustBeFiniteAndPositive` |
| 669 | bestätigt, behoben | Web-Editor schreibt `#RRGGBB`; `parseColor` akzeptiert `#RRGGBB` und `#RRGGBBAA`, alles andere → Standardfarbe (vorher wurde `#fff` unsichtbar). | `Ink.kt` | `InkTest.onlySharedColorFormatsAreAccepted` |
| 670 | nicht bestätigt | Bei „Nur Stift“ scrollt der Finger die Seite – gewollt und wie im Web (`allowPointer` in editor.js); sonst wäre eine lange Seite im Stiftmodus nicht scrollbar. Nur Kommentar. | `DocumentScreen.kt` | – |
| 671 | bestätigt, behoben | Einzelpunkt wird wie im Web (`strokeEnd`, +0,05) verdoppelt und als Punkt gezeichnet. | `Ink.kt`, `DocumentScreen.kt` | `InkTest.singleTapBecomesAShortStrokeLikeTheWebEditor`, `thinningKeepsEndpointsAndDropsJitter` |
| 672 | Anzeige bestätigt, behoben; Erhalt war gegeben | Text/Formen/Bilder gehen beim Speichern nicht verloren (`addObject`/`removeObject` auf der ganzen Liste, Radierer nur `stroke`). Neu: Hinweis „N weitere Objekte (Text/Formen/Bilder) nur auf PC/iPad sichtbar“. | `Ink.kt`, `DocumentScreen.kt` | `InkTest.foreignObjectsAreCountedAndNeverTouched` |
| 673 | bestätigt, behoben | Checkbox während laufender Anfrage gesperrt (`busy`-Menge). | `CalendarScreen.kt` | – |
| 674 | bestätigt, behoben | Fehlermeldung `remember(start)` → Wochenwechsel setzt zurück. | `CalendarScreen.kt` | – |
| 675 | bestätigt, behoben | Wie `pollBg` im Web: nach `POST /api/sync` alle 3 s `GET /api/bg` bis fertig (max. 300), dann neu laden; 409 „läuft bereits“ wird abgewartet. | `Sync.kt`, `Repo.kt`, `HomeScreen.kt` | `SyncRulesTest` (3) |
| 676 | bestätigt, behoben | Sitzung sofort lokal verwerfen und zum Login; Token-Entwertung im Hintergrund mit 5 s Timeout. | `Repo.kt`, `HomeScreen.kt` | – |
| 677 | bestätigt, behoben | Neuladen bei `ON_RESUME` und nach Abgleich; Listen behalten beim Neuladen den Inhalt (kein Flackern, Scrollposition bleibt). | `LibraryScreen.kt`, `ui/Common.kt`, `build.gradle.kts` | – |
| 678 | nicht bestätigt | `app/timetable.py` liefert zum Ursprungstermin (`verschoben`) einen Ersatztermin am Zieltag (`moved_here`); der Web-Lernkalender filtert genauso. Ausblenden ist korrekt. | `TimetableScreen.kt` | – |

Nur auf einem echten Gerät prüfbar: Stift/Finger bei „Nur Stift“, Einzeltipp mit S Pen, Radierer-Radius, Speichern
bei System-Zurück und im Hintergrund (ohne WorkManager nicht garantiert, im README vermerkt), fehlerhafte PDF-Seiten,
Download-Abbruch im Stream, Logout-Timing, Poll-Verlauf des Abgleichs, ON_RESUME-Neuladen. Alle Screens wurden
kompiliert, nicht gestartet. Beobachtung ohne Änderung: im Stiftmodus ohne „Nur Stift“ verbraucht jeder Touch das
Zeichnen, die Seite lässt sich dann nicht scrollen (war schon so).

## Benötigte Entscheidungen (Inhaber, mit der Mac-Sitzung)

Die Zusammenführung der Notizen ist ein Vertrag für Web, Swift und Kotlin (`merge.js`, `AnnotationMerge.swift`,
`AnnotationMerge.kt`, `fixtures/merge/cases.json`). Vier Verhalten, die der Prüfer bemängelt, sind auf allen
Plattformen gleich – sie zu ändern heißt, zuerst die Fixtures zu erweitern und dann alle drei nachzuziehen:

1. **Doppelte Objekt-IDs** (575/656, Apple 433): Index „letzter gewinnt“, Ausgabe „erster gewinnt“. Alternative:
   Duplikate vor dem Merge erkennen und melden.
2. **Beidseitige Änderung desselben Objekts** (576, Apple 431): lokal gewinnt, Serverfassung nur gezählt.
   Alternative: Serverfassung als Konfliktkopie behalten.
3. **v2-Zeichnung auf beiden Seiten** (653/654, Apple 438): lokale v2 ohne Vergleich der Strichsignaturen; v2 nur
   über die Form erkannt. Alternative: Signaturvergleich je Strich im Vertrag.
4. **Dokumentstruktur / pageOrder** (574, Apple 435): Web nimmt bei lokaler Strukturänderung lokal komplett, Swift
   vereinigt (Serverreihenfolge + nur lokal neue Seiten), Kotlin lokal bei Änderung gegenüber Basis. Kein gemeinsamer
   Fixture-Fall. Empfehlung: eine Regel festlegen (Drei-Wege über die Basis-Reihenfolge, Konflikt sichtbar) und als
   Fixture aufnehmen.

Weiter offen (nicht Code): GitHub Actions freischalten, damit `windows.yml` (jetzt mit Installer-Test) und
`android.yml` laufen; Gerätetests Android und Windows-Installer auf einem sauberen Rechner.
