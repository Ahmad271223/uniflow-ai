# Build-Herkunft der iPad-App (StudiNow 1.0)

Stand 08.11.2026, Audit P46-01/P47-04. Welcher Git-Commit steckt in welchem hochgeladenen Build? Fehlerbehebungen nach
einem Build gelten **nicht** für diesen Build. `tests/test_release_build_provenance.py` prüft diese Datei gegen
`apps/apple/project.yml` und `docs/release/APP-STORE.md` und – auf dem Mac des Inhabers, wo `~/Studora-Builds` liegt –
die Export-Ordner gegen die Commits.

Aktueller Stand in project.yml: Build 28 (Version 1.0, `CURRENT_PROJECT_VERSION`).

## Builds

Zeiten MEZ. „Commit“ ist der Commit, aus dem der Export-Ordner `~/Studora-Builds/export-bNN` per `git archive` entstand
(geprüft am 08.11.2026: Ordner und Commit sind Datei für Datei gleich, bis auf die beim Bauen erzeugten Dateien, siehe
unten). Alle Builds: Release, `UF_SHIPPED_UNIVERSITIES=luh` (nur LUH), Team 78MQGF36BD, Bundle-ID `de.uniflow.ai`.

| Build | Commit | Datum | Status | Inhalt |
|---|---|---|---|---|
| 21 | `44ba7cc5` | 08.11.2026 00:30 | hochgeladen (TestFlight), nicht eingereicht | Bibliothek liest vor dem Öffnen einer „nicht geladenen“ Datei frisch nach |
| 22 | `10f76288` | 08.11.2026 00:48 | hochgeladen (TestFlight), nicht eingereicht | Bibliothek liest ihre Liste nach jedem Abgleich neu |
| 23 | `6cccffc5` | 08.11.2026 01:07 | hochgeladen (TestFlight), nicht eingereicht | Stud.IP-Abgleich lädt Dateien ohne Ablageort in jedem vollen Lauf nach |
| 24 | `d4accf67` | 08.11.2026 01:34 | hochgeladen (TestFlight), nicht eingereicht | Dokument sofort über die Kennung öffnen; voller Abgleich vor Stufe d |
| 25 | `d08cae54` | 08.11.2026 01:51 | eingereicht: App Store WAITING_FOR_REVIEW, zugleich TestFlight-Beta-Prüfung | Bibliothek ohne „Dokument wählen“ beim Öffnen; Community-Beiträge erscheinen sofort |
| 26 | – | – | nie gebaut und nie hochgeladen (Nummer übersprungen) | – |
| 27 | `b328ebdd` | 09.11.2026 01:40 | gebaut (Archiv), nur auf das iPad des Inhabers installiert, nie hochgeladen | Build 25 plus Bugfixes, siehe unten |
| 28 | `7d1a8fb3` | 09.11.2026 12:08 | gebaut (Archiv), auf das iPad des Inhabers installiert, noch nicht hochgeladen | Build 27 plus Händigkeit/Seitentausch, Strich sofort gesichert (P60-F1), Erledigung beim Abgleich (P73-F6), Audits 58–87, siehe unten |

### Build 25 (in der Prüfung)

- Quelle: `git archive d08cae54` nach `~/Studora-Builds/export-b25` (develop, Nacht 07./08.11.2026, Commit 08.11. 01:51).
  Beim endgültigen Einreichen um 10:05 stand develop auf `c372db24`; zwischen `d08cae54` und `c372db24` hat sich unter
  `apps/apple/` nichts geändert (nur Dienst und Doku: 1 Credit = 0,9 Cent).
- Archiv: `~/Studora-Builds/StudiNow-25.xcarchive`, erstellt 08.11.2026 01:55 (`xcodebuild archive`, Protokoll
  `b25-archive.log` nennt `export-b25/apps/apple`), `CFBundleVersion` 25, `UFShippedUniversities` = `luh`, keine
  ATS-Ausnahme, `PrivacyInfo.xcprivacy` im Bundle (Stand 07.11.: fünf Datenarten).
- Hochgeladen 08.11.2026 02:08–02:10 mit `xcodebuild -exportArchive` (Protokoll `b25-upload.log`, „Uploaded UniFlow“,
  „EXPORT SUCCEEDED“). Signierung beim Export mit dem Distributionszertifikat; die Entitlements des Archivs selbst sind
  noch die der Entwicklung (`get-task-allow`).
- Vor dem Archiv lokal geprüft: `b25-test.log` (Abnahme-Auswahl: AbnahmeV1, AbnahmeV1LUHRelease, BackArrow,
  LayoutWidthAudit, LibraryShelf, LocalDocuments, StudIPDownloadGap – 74 Tests, 2 übersprungen, 0 Fehler).
- **GitHub Actions:** Der Lauf „Apple“ für `d08cae54` (Run 42431686238) ist rot, weil der Linux-Job schon beim
  Übersetzen scheitert (Linux-Foundation, nicht iOS); der iPad-Job wurde übersprungen. Für Build 25 gibt es also
  **keinen** CI-Nachweis, nur die lokalen Läufe oben.

### Build 27 (ersetzt durch Build 28)

Build 27 = Build 25 plus die Änderungen unter `apps/apple/` seit `d08cae54`, Stand 08.11.2026 21:15:

| Commit | Änderung |
|---|---|
| `afc919cc` | Mac („Designed for iPad“): Absturz in `UFGridLayout` bei unendlicher Breite behoben; Testbundle mit Stub und Fixtures |
| `c3ea0e60` | Build-Nummer 27 |
| `994377ea` | Lernplan ordnet nur neue Dokumente ein, statt die Woche neu zu planen |
| `a6add585` | Kauf trägt mit Anmeldung immer das Konto-Token, späte Kaufprüfung nach Kontowechsel verworfen (Audit P36) |
| (Audit 46/47) | Datenschutz-Manifest mit Geräte-ID, Text der Spracherkennung nennt auch „Transkript erstellen“ |

Dazu kommen weitere Swift-Korrekturen aus den laufenden Audits bis `b328ebdd` (develop, 09.11.2026). **Stand
09.11.2026 (Audit P68-01):** `~/Studora-Builds/export-b27` ist Datei für Datei der Export von `b328ebdd` (geprüft mit
`_export_differences` aus `tests/test_release_build_provenance.py`, 0 Abweichungen; `StudiNow-27.commit` = `b328ebdd`),
daraus `StudiNow-27.xcarchive` vom 09.11.2026 01:40 (`b27-archive.log`: „ARCHIVE SUCCEEDED“, `CFBundleVersion` 27,
`UFShippedUniversities` = `luh`); vorher lokal `b27-test.log`: **1365 Tests, 18 übersprungen, 0 Fehler**. Das frühere
Archiv vom 08.11. 19:44 (aus `c3ea0e60`) ist damit ersetzt. Noch nicht hochgeladen. Kommt vor dem Upload noch eine
Änderung unter `apps/apple/` dazu, gilt wieder: neu aus dem dann aktuellen Commit bauen und die Zeile 27 oben anpassen. Wird Build 27 einmal
hochgeladen, ist die Nummer verbraucht; jede weitere Änderung braucht Build 28.

### Build 28 (nächster Upload)

Build 28 = Build 27 plus die Änderungen bis `7d1a8fb3` (develop, 09.11.2026): Schreibhand und Seiten tauschen
(`e5050f50`, `5160860b`, `4e9aea98`), Strich sofort gesichert (P60-F1, `f5a31bf8`), nur geänderte Felder beim Abgleich
(P73-F6, `83e7d910`, `a6d25a73`), Prüfungsknopf QIS/LSF (`7e175276`), Studienverlauf verschieben (`07254389`),
Probe-Anzeige aus einer Quelle (`3992573b`), Übernahme-Kontingent je Konto (`6859265f`) und die Swift-Korrekturen der
Audits 58–87. **Stand 09.11.2026:** `~/Studora-Builds/export-b28` ist Datei für Datei der Export von `7d1a8fb3`
(`tools/pruefe-build-herkunft.sh 28 7d1a8fb3`: keine Abweichung; `StudiNow-28.commit` = `7d1a8fb3`), daraus
`StudiNow-28.xcarchive` (`b28-archive.log`: „ARCHIVE SUCCEEDED“, Version 1.0, `CFBundleVersion` 28,
`UFShippedUniversities` = `luh`, Team 78MQGF36BD); vorher lokal `b28-test.log` auf demselben Commit: **1387 Tests,
18 übersprungen, 0 Fehler**. Noch nicht hochgeladen, Upload erst auf Ansage des Inhabers. Kommt vor dem Upload noch eine
Änderung unter `apps/apple/` dazu: neu aus dem dann aktuellen Commit bauen und die Zeile 28 oben anpassen.

## Commit eines Archivs nachweisen

1. **Export-Ordner gegen Commit:** `tools/pruefe-build-herkunft.sh 25 d08cae54` packt `git archive d08cae54` in einen
   leeren Ordner und vergleicht mit `~/Studora-Builds/export-b25`. Erlaubt sind nur die beim Bauen erzeugten Dateien
   `apps/apple/Config/Team.xcconfig`, `apps/apple/UniFlow.xcodeproj`, `apps/apple/UniFlow/Info.plist` und
   `apps/apple/Packages/UniFlowCore/.swiftpm`; jede andere Abweichung heißt: anderer Stand.
2. **Archiv gegen Export-Ordner:** `grep -m1 export-b25/apps/apple ~/Studora-Builds/b25-archive.log`.
3. **Build-Nummer im Archiv:**
   `/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" ~/Studora-Builds/StudiNow-25.xcarchive/Info.plist`
   und in der App selbst `.../Products/Applications/UniFlow.app/Info.plist` (`CFBundleVersion`, `UFShippedUniversities`).
4. **Upload:** `b25-upload.log` endet mit „Uploaded UniFlow“; in App Store Connect (TestFlight → iOS-Builds) steht
   dieselbe Build-Nummer 25 unter Version 1.0.

So bauen (wie Build 21 bis 25): `git archive <commit> | tar -x -C ~/Studora-Builds/export-bNN`,
`Config/Team.xcconfig` hineinkopieren, `xcodegen generate`, `xcodebuild archive` (Release, generic/platform=iOS) nach
`~/Studora-Builds/StudiNow-NN.xcarchive`, dann `xcodebuild -exportArchive` mit Upload. Nie aus einem Arbeitsordner mit
uncommitteten Änderungen bauen. Empfehlung: nach dem Upload einen Git-Tag `ios-1.0-bNN` auf den Commit setzen.
