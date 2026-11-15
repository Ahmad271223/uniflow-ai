# Testläufe: welcher Lauf wann

Stand 15.11.2026. Es gibt zwei klar benannte Läufe der Python-Tests. Der Unterschied sind die **Lasttests**: Tests,
die viele Prozesse oder Sitzungen zugleich starten.

| Lauf | Befehl | Was läuft | Wann |
| --- | --- | --- | --- |
| **Schneller Lauf** | `tools/tests-schnell.sh` | alle Python-Tests **ohne** Lasttests, danach `node --test tests/js/` | während der Arbeit: jeder Agent, jede Sitzung, vor jedem Commit. Darf neben anderen schnellen Läufen laufen. |
| **Voller Lauf** | `tools/tests-voll.sh` | **alle** Python-Tests mit Lasttests, danach `node --test tests/js/` | **einmal vor einem Build** (Kandidat steht fest). Immer nur einer auf dem Rechner. |

Dieselben Läufe ohne Skript:

```sh
# schneller Lauf
.venv/bin/python -m pytest -q -p no:cacheprovider --ignore=tests/test_pwa.py -m "not last"
node --test tests/js/

# voller Lauf (der bisherige Aufruf, unverändert: ohne -m läuft alles)
.venv/bin/python -m pytest -q -p no:cacheprovider --ignore=tests/test_pwa.py
node --test tests/js/
```

`python -m pytest` ohne Optionen lässt weiter **alles** laufen; `pytest.ini` trägt nur den Marker ein und wählt nichts
ab. Auch GitHub (`.github/workflows/python.yml`) läuft unverändert mit allen Tests.

In einem Worktree gibt es kein eigenes `.venv`; die Skripte nehmen dann das des Haupt-Checkouts (oder `UF_PYTHON`).
Einzelne Dateien: `tools/tests-schnell.sh tests/test_accounts.py`.

## Regeln

1. **Es laufen nie zwei volle Läufe zugleich.** Die Lasttests starten Dutzende Python-Prozesse und eigene Dienste.
   Zwei bis drei volle Läufe nebeneinander (mehrere Agents) neben einer iPad-Suite haben die Last des Rechners über
   300 getrieben; dann kippen Browser-Tests und Tests mit Zeitgrenzen, auch in den anderen Läufen.
   `tools/tests-voll.sh` setzt das durch: es startet nicht, solange ein anderer voller Lauf läuft (Sperre
   `~/Studora-Builds/tests-voll.lock`, oder ein `pytest` ohne `-m "not last"`), und nicht bei einer Rechnerlast ab 20
   (`uptime`; Grenze über `UF_TESTS_MAX_LAST`, `0` schaltet die Prüfung ab). Rückgabe 2 heißt „nicht gestartet“.
2. **Agents und Sitzungen nehmen den schnellen Lauf.** Den vollen Lauf startet, wer den Build vorbereitet, einmal.
   Wer von Hand startet, sieht vorher nach: `pgrep -fl pytest` und `uptime`.
3. **Kein voller Lauf neben einer iPad- oder iPhone-Suite** (`xcodebuild test`): erst das eine, dann das andere.
4. Ein roter Test wird nicht durch Wiederholen grün gemacht. Ausnahme sind nur die bekannten Wackel-Tests unten, und
   auch die weist der volle Lauf einzeln aus.

## Ausgabe der Skripte

Je Teil eine Zeile, am Ende `ERGEBNIS`:

```
== Voller Lauf (mit Lasttests) – Last des Rechners: 5 ==
pytest: 3611 bestanden, 1 rot, 5 übersprungen, 2 erwartet rot (7:40 min)
  wiederholt: tests/test_web_goals.py::test_narrow_window_without_horizontal_overflow – im vollen Lauf rot, einzeln grün (bekannter Wackel-Test)
node: bestanden (456 Tests)
ERGEBNIS: bestanden, 1 wiederholt (Wackel-Tests erst einzeln grün) – Protokoll: …/voll-2026-11-15-170000.log
```

- **bestanden**: alles grün.
- **rot**: ein Test ist rot und kein bekannter Wackel-Test, oder er war auch einzeln rot. Rückgabe 1.
- **wiederholt**: ein bekannter Wackel-Test war im vollen Lauf rot und einzeln grün. Rückgabe 0, aber die Zeile
  bleibt stehen; häuft sich das bei einem Test, gehört die Ursache gesucht.

Die Protokolle liegen unter `$TMPDIR/studinow-tests/` (oder `UF_TESTLOG_DIR`).

## Lasttests (Marker `last`)

Die Liste steht in `tests/lasttests.txt`; `tests/conftest.py` setzt daraus beim Sammeln den Marker `last`
(eingetragen in `pytest.ini`). Aufnahme in die Liste: der Test startet viele Prozesse oder Sitzungen zugleich (ab vier
Python-Prozessen, ein eigener Dienst mit Arbeitern, Dutzende gleichzeitige Anfragen) oder braucht länger als etwa
20 Sekunden. Gemessen am 15.11.2026 bei ruhigem Rechner, zusammen 69 s:

| Test | Dauer | Warum |
| --- | --- | --- |
| `test_audit_p58_87_golive.py::test_p82_soak_tool_keeps_every_acknowledged_write_and_survives_a_killed_worker` | 16 s | `tools/lasttest-dauer.py`: eigener Dienst mit 2 API-Prozessen, 60 Sitzungen, 16 Anfragen zugleich, ein Prozess wird beendet |
| `test_audit_paket_15_16.py::test_p16_01_twelve_processes_on_a_fresh_data_dir_agree` | 15 s | 3 Runden mit 12 Python-Prozessen zugleich |
| `test_audit_paket_11_12.py::test_p11_02_twelve_processes_start_together` (2 Fälle) | 2 × 10 s | je 2 Runden mit 12 Python-Prozessen zugleich |
| `test_audit_paket_50_54.py::test_p54_09_accounts_db_wal_stays_bounded_under_sustained_multi_process_load` | 4 s | 6 Prozesse schreiben 4 s lang in dieselbe Datenbank |
| `test_audit_p58_87_golive.py::test_p82_ki_lasttest_reaches_the_fake_provider_in_hosted_mode` | 4 s | `tools/lasttest-ki.py`: eigener Dienst, KI-Attrappe |
| `test_audit_p58_87_golive.py::test_p84_03_backup_restores_into_an_empty_folder_with_identical_content_and_a_working_service` | 2 s | eigener Dienst, Sicherung und Rückspielen als eigene Prozesse |
| `test_ai_lastfest.py::test_ai_questions_run_async_and_leave_other_endpoints_fast` | 1,6 s | 60 KI-Fragen zugleich, misst Antwortzeiten |
| `test_audit_paket_17_18.py::test_p17_08_parallel_first_start_moves_data_exactly_once` | 1,5 s | 6 Python-Prozesse zugleich |
| `test_audit_p58_87_ki.py::test_p63_03_four_processes_never_book_past_the_shared_month_budget` | 0,3 s | 4 Python-Prozesse zugleich |

Kein einzelner Test braucht bei ruhigem Rechner länger als 20 Sekunden. Die übrigen Tests in
`tests/test_launch_4000.py` und `tests/test_ai_lastfest.py` heißen nach dem Lasttest, starten aber nichts Schweres
(zusammen unter 5 s) und laufen im schnellen Lauf mit.

Nur die Lasttests: `.venv/bin/python -m pytest -q -p no:cacheprovider -m last`.

Ein neuer Lasttest bekommt eine Zeile in `tests/lasttests.txt` (Datei, Testname, Dauer, Grund).
`tests/test_testlaeufe.py` prüft, dass es jeden Eintrag noch gibt und der Marker genau an diesen Tests steht.

## Dauer

Gemessen am 15.11.2026 auf dem Mac, beide Läufe direkt nacheinander über die Skripte, Rechnerlast beim Start 14
(andere Agents arbeiteten nebenher), beide ohne roten Test:

| Lauf | Tests | Dauer laut pytest |
| --- | --- | --- |
| schneller Lauf (pytest ohne Lasttests) | 3 609 (10 abgewählt) | 6:33 min |
| voller Lauf (pytest mit Lasttests) | 3 619 | 7:38 min |
| nur die Lasttests (`-m last`) | 10 | 1:09 min |
| `node --test tests/js/` | 456 | 1 s |

Der schnelle Lauf spart also gut eine Minute, nicht mehr: kein einzelner Test ist lang, die Zeit steckt in der Menge
(3 600 Tests in einem Prozess; allein die Passwort-Hashes der Testkonten, 1 900-mal scrypt, kosten rund eine Minute).
Wichtiger ist, was er nicht tut: er startet keine Prozess-Stürme (bis zu 12 Python-Prozesse zugleich, eigene
Dienste), mehrere schnelle Läufe nebeneinander bleiben deshalb verträglich. Unter fremder Last dauern beide Läufe
länger (voller Lauf neben einem `xcodebuild` bei Last 200: 8:00 min und drei rote Tests).

## Bekannte Wackel-Tests

`tests/wackeltests.txt`: Tests, die von der Rechnerlast oder von Zeitgrenzen abhängen und unter Last gelegentlich rot
sind, einzeln aber grün. Das sind die Browser-Tests (Playwright mit Chromium, Wartezeiten von 15 bis 30 s) und die
Tests in `test_launch_4000.py` und `test_ai_lastfest.py`, die Zeiten messen. Die Lasttests zählen von selbst dazu.
`tools/tests-voll.sh` wiederholt nur diese, einmal, einzeln.

Nicht in die Liste gehört ein Test, dessen Ursache man kennt. Am 15.11.2026 repariert und deshalb **nicht** in der
Liste (wieder rot heißt: neuer Befund):

| Test | Ursache | Reparatur |
| --- | --- | --- |
| `test_modules_race.py::test_merge_duplicate_modules_keeps_everything` (im vollen Lauf fast immer rot, einzeln grün) | Gemeinsame Test-Datenbank des ganzen Laufs: `tests/test_module_done.py` legt seit 13.11.2026 je Test die Module „Done-Analysis“ und „Done-Physik“ neu an und lässt sie stehen. Im vollen Lauf standen sie doppelt da; `merge_duplicate_modules` zählt alle Doppel der Datenbank und lieferte 4 statt 2. | Eigene, leere Datenbank je Test dieser Datei; die genaue Zahl bleibt geprüft. |
| `test_social_login.py::test_list_and_unlink_identities` (einmal rot) | Zeitabhängig: die Liste der Anmeldewege ist nach Zeitpunkt (volle Sekunden) und dann nach Anbieter sortiert. Der Test nahm die echte Uhr und erwartete stillschweigend dieselbe Sekunde für Google und Apple; mit einem Sekundenwechsel dazwischen kam die andere Reihenfolge. | Feste Uhr für beide Verknüpfungen; der Fall „verschiedene Sekunden“ wird eigens geprüft. |
| `test_moodle.py::test_pc_submission_only_where_moodle_is` (rot ohne Netz) | Der Test fragte den echten Server der Uni Hildesheim nach der Learnweb-Adresse. | Nachbildung der Abfrage; kein Test geht ins Netz. |

Wer einen neuen Wackler findet: erst die Ursache suchen (gemeinsamer Zustand zwischen Tests, feste Ports, Uhr,
Reihenfolge, zu knappe Wartezeit, Netz). Gegenprobe für die Reihenfolge: den Test zusammen mit den Dateien laufen
lassen, die im vollen Lauf vor ihm stehen (`pytest tests/test_a.py tests/test_b.py tests/test_c.py`).

## Weitere Läufe

- **Swift-Kern:** im Ordner `apps/apple/Packages/UniFlowCore` `swift test`.
- **iPad- und iPhone-Suite** immer auf einem **Klon** des Vorlage-Simulators (frische Simulatoren haben kein
  StoreKit-Setup und keine deutsche Sprache) und nacheinander, nie neben einem vollen pytest-Lauf:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/apple && xcodegen generate -q

# iPad: alle App-Tests auf einem Klon des Simulators „iPad“
IPAD=$(xcrun simctl clone 4495AA80-7860-4F6F-9FCD-C83CCED19021 "Test iPad")
xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "id=$IPAD" \
  -only-testing:UniFlowTests -derivedDataPath ~/Studora-Builds/dd-test > ~/Studora-Builds/test-ipad.log 2>&1
grep -E "Executed [0-9]+ tests" ~/Studora-Builds/test-ipad.log | tail -1
xcrun simctl shutdown "$IPAD"; xcrun simctl delete "$IPAD"

# iPhone: die iPhone-Klassen und die Breitenprüfung auf einem Klon des Simulators „iPhone 17“
IPHONE=$(xcrun simctl clone 5D435FE8-7D2A-48D1-BC89-5354DD6C9FF2 "Test iPhone")
ONLY=()
for c in $(grep -rhoE "^(final )?class (IPhone[A-Za-z0-9_]*Tests|LayoutWidthAuditTests)" UniFlowTests | awk '{print $NF}' | sort -u); do
  ONLY+=("-only-testing:UniFlowTests/$c")
done
xcodebuild test -project UniFlow.xcodeproj -scheme UniFlow -destination "id=$IPHONE" $ONLY \
  -derivedDataPath ~/Studora-Builds/dd-test > ~/Studora-Builds/test-iphone.log 2>&1
grep -E "Executed [0-9]+ tests" ~/Studora-Builds/test-iphone.log | tail -1
xcrun simctl shutdown "$IPHONE"; xcrun simctl delete "$IPHONE"
```

  Rote Tests stehen im Protokoll als `error: -[UniFlowTests.Klasse test…]`. Die Befehle stammen aus
  `docs/UEBERGABE-2026-11-14.md`, Abschnitt 6 (Tests). Am Mac („Designed for iPad“): `tools/mac-test.sh`.
- **Unter Last wacklig (Swift):** `SyncAllPortalsTests.testUniMailRunsSideBySideWithQIS`. Ursache ist der Test, nicht
  die App: die Nachbildung hält die Antwort des Posteingangs bis zu 3 Sekunden zurück und wartet in dieser Zeit auf
  die erste QIS-Anfrage – sie tut das aber im Lade-Thread von `UniStubProtocol`, und über diesen einen Thread laufen
  alle nachgebildeten Anfragen. Kommt die Anfrage an den Posteingang zuerst an, kann die QIS-Anfrage erst danach
  gezählt werden: der Test ist dann nach genau 3 Sekunden rot („QIS fragt, während der Posteingang noch lädt“,
  Protokoll vom 13.11.2026: 3,27 s statt sonst 0,22 s). Kommt die QIS-Anfrage zuerst, ist er grün; unter Last kippt
  die Reihenfolge öfter. Bis zur Reparatur einzeln wiederholen. Vorschlag: die zurückgehaltene Antwort nicht im
  Lade-Thread abwarten, sondern die Antwort von einem eigenen Thread aus ausliefern (`startLoading` kehrt sofort
  zurück); eine längere Wartezeit hilft nicht.
- **App-Store-Bilder:** `docs/release/SCREENSHOTS.md` (iPhone: nur `IPhoneRealShotsTests`).
