# Übergabe: iPad-Funktionen in Windows und Web (04.11.2026)

Vier Pakete aus der Cloud-Sitzung, auf `develop` zusammengeführt. Vorlage war jeweils der Swift-Stand bis 271bfe6. Die
Windows-App ist dieselbe Oberfläche wie das Web, mit dem Python-Server darunter. Getestet ist nur unter Linux: Python
885 Tests grün, Node 171 von 172 (siehe „Bekannte Fehler“), alle `tools/gen-*-fixture.py --check` grün. **Nicht
geprüft:** echtes Windows/Tauri/MSIX, echte Stud.IP-/Learnweb-Seiten, Swift gegen die neuen Prüfdaten.

## Was neu in Python und Web ist

| Bereich | Python | Web | Prüfdaten |
| --- | --- | --- | --- |
| Neuigkeiten-Karte (Übersicht) | `/api/news` gab es | `news.js` | – |
| Schwarzes Brett (nur LUH, nie im Dienst) | `app/studip_bulletin.py`, Routen `/api/studip/bulletin(/{id})` | `bulletin.js` | `fixtures/studip-bulletin/bulletin.json` (neu) |
| Blubber (aus, wie `syncEnabled = false`) | `app/studip_blubber.py`, Routen `/api/studip/blubber(/{id})` | Gruppe in „Aus Stud.IP“ | – |
| „Aus Stud.IP“ im Modul | gab es | `studip-texts.js` | – |
| Frühere Semester | `app/older_semesters.py`, `older_semesters_api.py` (Routen wie Swift, dazu `POST /api/older-semesters/load`) | `older-semesters*.js` | – |
| Dokument „Zur Bibliothek“, Abgleich-Anzeige nur bei Neuem/Fehler | – | `doc-nav.js`, `sync-chip.js` | – |
| Dienstfehler an einer Stelle | – | `service-errors.js` (Texte wie `ServiceErrorText.swift`) | – |
| Community-Seite mit Kanal nach Lehrwoche, Diskussion, Dokumente | Likes auf Fragen, `?unanswered=true`, `module_id` in `/api/courses/community-keys`, `content_sha256` je Datei im Moduldetail | `community-channel.js/.css`, `community-logic.js` | `community/contract.json`, `account/contract.json` ergänzt |
| Korrekturvorschläge (Dienst) | `app/community_corrections.py`, Endpunkte unter `/api/community/solutions/{id}/corrections` und `/api/community/corrections/...` | `community-corrections*.js`, `community-editor-tools.js` | `community/correction-vectors.json` (neu) |
| Texterkennung (OCR) | `app/pageocr.py` (Tesseract + pypdfium2; im Dienst aus) | – | `fixtures/ocr/rules.json` (neu) |

## Für die Mac-Sitzung

1. **Prüfdaten mit neuen Feldern:** `local-backend/study-modules.json`, `study-plan.json`, `studip-import.json`,
   `timetable-logic.json` enthalten jetzt `content_sha256` je Datei im Moduldetail (Python liefert es für den
   Community-Kanal). Wenn die Swift-Tests die Schlüssel exakt vergleichen, im lokalen Backend ergänzen (die Spalte
   `files.content_sha256` gibt es dort schon) oder melden.
2. `app-paths.json`: Brett- und Blubber-Routen sind am PC nicht mehr 404.
3. **Korrekturen im Dienst-Modus:** `ServiceCommunityService` kann `supportsCorrections` setzen. Form und Chiffrat wie
   CloudKit-Typ `Correction` / `CommunityCorrections.seal`; Zuordnung in `docs/LOESUNGEN-TEILEN.md` Abschnitt 6b.
   Neue Fehlercodes: `corrections_limit`, `correction_exists`, `payload_invalid`, `id_invalid`, `own_post`; neue
   Grenze `correction_user`; neue Benachrichtigungsart `correction`.
4. Swift-Kommentare „Keine Python-Entsprechung“ in `StudIPBulletin.swift`, `StudIPBlubber.swift` und ihren
   Endpunkt-Dateien stimmen nicht mehr.
5. Neue Prüfdaten zum Gegenprüfen: `studip-bulletin/bulletin.json`, `community/correction-vectors.json`,
   `ocr/rules.json`.

## Bekannte Fehler (nicht aus diesen Paketen)

- `tests/js/solutions.test.mjs` „raw DEFLATE: harte Obergrenze“: Unter Node 22 lehnt `DecompressionStream` angehängte
  Bytes hinter dem Ende nicht ab, der Test erwartet das. Unterschied der Node-Versionen; kein Sicherheitsproblem, weil
  das Paket vorher mit AES-GCM geprüft wird. Entweder Test an die Node-Version anpassen oder die Prüfung selbst bauen.
- `tests/test_web_overview.py::test_overview_mobile_plan_in_first_screen_install_hint_below`: Chromium findet
  `#pwaHint` nicht, schon auf 271bfe6.

## Entschieden am 04.11.2026 und umgesetzt

- **Fragen je Kurs nur für Mitglieder** (wie auf dem iPad: nur wer den Kurs hat oder hatte; Beitritt nur für Kurse aus
  dem eigenen Abgleich). `app/community_qa.py` `_require_member`: Liste und Stellen 403 `not_a_member`, einzelne
  fremde Fragen (Lesen, Antworten, Liken, Melden, Merken) 404 für Nicht-Mitglieder. Das iPad ruft diese Pfade im
  Dienst-Modus nicht auf (Fragen laufen dort über CloudKit). Test `test_questions_only_for_members_of_the_course`.
- **Windows-Programmname StudiNow** (`productName`, Version 0.5.0): Programmordner `%LOCALAPPDATA%\StudiNow`,
  Installer `StudiNow_<version>_x64-setup.exe`, Startmenü „StudiNow“. Die alte App „UniFlow“ bleibt installiert und
  teilt den Datenordner: sie **ohne** „App-Daten entfernen“ deinstallieren (apps/windows/README.md).

## Offen (Entscheidung oder späterer Schritt)

- Windows-Workflow: Schritt fehlt, der Tesseract (Programm, Sprachdaten deu/eng, Lizenz) neben die exe legt; ohne ihn
  bleibt die Texterkennung auf Windows aus.
- `Retry-After` reicht die Weiterleitung `service_link.proxy` nicht durch (betrifft nur die Minutengrenze des Dienstes).
- Korrektur-Glocke öffnet nur das Dokument, nicht gleich die Korrektur; „Daneben ansehen“ ohne Ziehgriff.
