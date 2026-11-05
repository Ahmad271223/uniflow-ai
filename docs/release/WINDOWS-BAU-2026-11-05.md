# Windows-Bau 0.6.0: starten, herunterladen, auf echtem Windows prüfen (Stand 05.11.2026)

Für Koordinator und Inhaber. Was dieser Bau enthält, warum der Lauf vom 04.11. rot war, wie man den Bau startet, wo die
Dateien liegen, wie man auf einem echten Windows-PC testet und was nur der Inhaber entscheiden kann.

## 1. Warum der Lauf vom 04.11. rot war und was jetzt anders ist

| Lauf | Commit | Ergebnis |
| --- | --- | --- |
| 41929677402 (04.11., 22:57, von Hand) | vor c6d259c | **rot** in `add-tesseract.ps1`: „tesseract.exe fehlt nach der Installation unter `D:\a\_temp\tesseract-build\installiert`“ |
| 41932061818 (04.11., 23:14, von Hand) | c6d259c (Suche + 7-Zip) | grün, 0.5.0 |
| 41937409745, 41954258229, 41993722721 (Push mit Merge) | bis faf2266 | grün, 0.5.0 |

**Ursache:** Der Tesseract-Installer der UB Mannheim (NSIS) übergeht den Zielordner `/D=…` bei stiller Installation
und installiert immer nach `C:\Program Files\Tesseract-OCR`. Das alte Skript erwartete die Datei im `/D`-Ordner. c6d259c
hat das mit einer rekursiven Suche über `Program Files` und `%LOCALAPPDATA%` umgangen. Das ging, kostete im Lauf
41993722721 aber zweieinhalb Minuten und hätte jedes beliebige vorinstallierte Tesseract genommen.

**Was am 05.11. an `apps/windows/scripts/add-tesseract.ps1` geändert wurde:**
- Version (5.4.0.20240606) und SHA-256 bleiben fest. Downloads werden bis zu dreimal versucht. Ein vorhandener Installer
  kann mit `-Setup <pfad>` übergeben werden (die Prüfsumme wird trotzdem verglichen).
- Statt die Platte zu durchsuchen, prüft das Skript nur feste Orte (bis zu 120 s lang): den `/D`-Ordner, die Registry
  (`HKLM\SOFTWARE\Tesseract-OCR\InstallDir`, Uninstall-Eintrag) und `%ProgramFiles%\Tesseract-OCR`.
- Rückfall: den Installer mit 7-Zip entpacken (7-Zip ist auf `windows-latest` vorhanden), dabei den Exitcode prüfen.
- Genommen wird nur ein Programm, das `5.4.0` meldet. Pflichtdateien (`tesseract.exe`, `libtesseract-5.dll`,
  `libleptonica-6.dll`, `deu`/`eng`, `LIZENZEN.txt`) werden im Ziel geprüft. `tesseract --version` muss aus dem
  Zielordner starten, damit eine fehlende DLL auffällt. Danach wie bisher: Sprachen auflisten und Probe-Erkennung.
- Jeder Fehler beginnt mit `add-tesseract:` und nennt, was fehlt und wo gesucht wurde.

## 2. Was im Paket 0.6.0 neu ist (Stand 05.11.)

- **Version 0.6.0** in `package.json`, `package-lock.json`, `src-tauri/tauri.conf.json` und `src-tauri/Cargo.toml`.
  Das MSIX übernimmt sie als `0.6.0.0`. Der Installer heißt `StudiNow_0.6.0_x64-setup.exe`.
- **Python-Module vom 05.11.** (`access`, `account_mode`, `account_mode_api`, `token_store`, `app_login_api` und alle
  anderen unter `app/`) kommen über `collect_submodules("app")` ins Paket. Neue Dateien unter `app/static` kommen
  automatisch mit, weil der ganze Ordner gepackt wird.
- **Daten des Studienverlaufs:** `luh.json.gz` (Grundstock), `study-sources.json` und `study-sources-all.json` waren
  schon im Paket. Neu ist `exam-registration-luh.json`, die `app/exam_registration.py` zur Laufzeit liest.
  `study-area-rules-luh.json` steckt schon im Grundstock (`tools/build-luh-seed.py`), und `luh-index.json` braucht nur
  der Swift-Kern. Beide gehören darum nicht ins Paket. `tests/test_windows_package.py` schlägt fehl, sobald `app/*.py`
  eine Datei unter `ROOT / …` liest, die nicht in `uniflow-backend.spec` steht.
- **Anmeldung über den Browser:** Das Backend öffnet `https://app.studinow.app/login?app=windows&redirect_uri=
  http://127.0.0.1:<port>/konto/rueckkehr&…` im Standardbrowser (`webbrowser`, nicht im App-Fenster). Die Rückleitung
  landet beim lokalen Server, der das App-Fenster bedient (gleicher Port wie in der Zustandsdatei). Der Smoke-Test prüft
  genau diese Adresse.

## 3. Was der Lauf prüft (`.github/workflows/windows.yml`)

1. **Tests, blockierend:** `tests/test_desktop.py`, `tests/test_desktop_windows.py`, `tests/test_windows_package.py`.
   Dazu gehört ein echter Eintrag in der Windows-Anmeldeinformationsverwaltung: ein Dummy-Token unter einem eigenen
   Ziel `StudiNow/ci-probe-…` wird geschrieben, gelesen, überschrieben und gelöscht.
2. **Tests, nur Hinweis:** `test_account_mode`, `test_web_windows_shell`, `test_pageocr`, `test_study_catalog`,
   `test_luh_seed`, `test_exam_registration`, `test_study_sources_luh`. Sie liefen noch nie unter Windows. Ein Fehler
   steht in der Zusammenfassung des Laufs, hält den Installer aber nicht auf. **Nach dem ersten grünen Lauf** in
   `windows.yml` beim Schritt „Windows-relevante Tests“ `continue-on-error: true` entfernen.
3. **Smoke-Test des gepackten Backends** (`apps/windows/scripts/check-backend.ps1`, läuft zweimal: auf das
   PyInstaller-Paket und nach der stillen Installation). Eine eigene `/api/health` gibt es nicht. Als Lebenszeichen
   dient `/api/account/info`. Geprüft werden:
   - die Content-Security-Policy
   - die Oberflächen-Dateien (`app.js`, `study-plan.js`, `study-plan-logic.js`, `views-abo.js`, `trial-hint.js`)
   - `/api/app-account/status`: `required`, `signed_out` und `token_store = windows_credential_manager`. Das zeigt,
     dass ctypes und advapi32 im Paket laufen.
   - `/api/overview`: 401 `account_required`
   - `browser-login` mit `open_browser:false`: Die Rückleitung ist genau `http://127.0.0.1:<port>/konto/rueckkehr`.
   - `/konto/rueckkehr` mit fremdem `state`: 400
   - die Paketdaten unter `_internal\…`
4. Tesseract, Installer bauen, still installieren und deinstallieren, MSIX bauen und testweise installieren (wie bisher).
5. **Zusammenfassung des Laufs:** Version, Name und Größe des Installers, Commit.

## 4. Bau starten (Koordinator)

Commits mit `[skip ci]` lösen keinen Lauf aus. Darum nach dem Push von Hand starten:

```sh
gh workflow run windows.yml --ref develop
sleep 5; RUN=$(gh run list --workflow windows.yml -L 1 --json databaseId -q '.[0].databaseId'); echo $RUN
gh run watch $RUN --exit-status            # dauert etwa 20 Minuten
gh run view $RUN --log-failed              # nur bei Rot
gh run download $RUN -n uniflow-windows -n uniflow-windows-msix -D ~/Studora-Builds/windows-0.6.0
```

**Artefakte** (14 Tage aufbewahrt, auch unter GitHub → Actions → Windows → Lauf → Artifacts):

| Artefakt | Inhalt |
| --- | --- |
| `uniflow-windows` | `StudiNow_0.6.0_x64-setup.exe` (NSIS, etwa 330 MB, unsigniert), `Cargo.lock`, `cargo-audit.json` |
| `uniflow-windows-msix` | `StudiNow_0.6.0.0_x64.msix` (unsigniert, für Partner Center), `…-test.msix` und `…-test.cer` (Wegwerf-Testsignatur) |

## 5. Auf einem echten Windows-PC testen (Inhaber)

Windows 10 22H2 oder Windows 11, 64 Bit. Den ausführlichen Konto-Handtest gibt es in `docs/WINDOWS-LUECKEN-2026-11-05.md`,
Abschnitt „Handtest Konto- und Abo-Pflicht“. Die Liste hier ist die Kurzfassung für einen Durchgang.

**Installieren**
- [ ] `StudiNow_0.6.0_x64-setup.exe` starten. SmartScreen warnt („Unbekannter Herausgeber“), weil der Installer
      unsigniert ist: „Weitere Informationen“ → „Trotzdem ausführen“. Es braucht keine Adminrechte. Installiert wird nach
      `%LOCALAPPDATA%\StudiNow`.
- [ ] Startmenü → StudiNow. Das Fenster zeigt „StudiNow startet …“ und danach den Anmeldebildschirm.
- [ ] Alternativ MSIX: `…-test.cer` als Administrator unter „Lokaler Computer → Vertrauenswürdige Personen“ eintragen,
      dann `…-test.msix` doppelklicken (`apps/windows/msix/README.md`). Das Zertifikat danach wieder entfernen.

**Konto (Pflicht seit 05.11.)**
- [ ] Ohne Anmeldung gibt es nur den Anmeldebildschirm. „Meine Daten exportieren“ lädt eine ZIP-Datei.
- [ ] Mit E-Mail und Passwort anmelden. Bei einem neuen Konto erscheint die Leiste „Probe: noch 7 Tage …“.
- [ ] „Mit Apple anmelden“ und „Mit Google anmelden“ öffnen den **Standardbrowser** (nicht das App-Fenster). Nach der
      Anmeldung zeigt der Browser „Angemeldet … Du kannst dieses Fenster schließen“, und die App wechselt nach wenigen
      Sekunden. Meldet die Windows-Firewall etwas: Die Rückleitung geht nur an 127.0.0.1, eine Freigabe ist nicht nötig.
- [ ] In der Anmeldeinformationsverwaltung (Windows-Anmeldeinformationen → Generische Anmeldeinformationen) steht
      `StudiNow/dienst-sitzung`. In `%LOCALAPPDATA%\de.uniflow.desktop\data\service-account.json` steht kein Token.
- [ ] App schließen und neu starten: Du bist noch angemeldet.

**Abo**
- [ ] Mit dem Konto, das ein **Apple-Abo** hat (iPad, Sandbox): Der Tarif ist aktiv, die Abo-Seite zeigt „Du hast schon
      ein Abo über Apple …“, und es gibt keinen Knopf „Abschließen“.
- [ ] Mit einem Konto, dessen Probe vorbei ist: Es erscheint „Kein aktives Abo · Nur lesen“. Lesen und Export gehen,
      Schreiben ist gesperrt.
- [ ] **Stripe-Kauf:** „Abschließen“ bei Plus öffnet den Checkout im Browser. Im Testmodus mit der Karte
      `4242 4242 4242 4242` bezahlen, danach zeigt die App nach etwa 5–10 s Plus. „Abo verwalten“ öffnet das
      Kundenportal. Voraussetzung: Stripe-Schlüssel, Preise und Webhook sind im Dienst eingerichtet. Echtes Geld nur,
      wenn du das bewusst willst.

**Funktionen**
- [ ] Hochschul-Anmeldung (LUH) im App-Fenster, Abgleich Stud.IP/QIS, PDF öffnen und schreiben.
- [ ] **Studienverlauf:** Seitenleiste → Meine Module → Studienverlauf. Studiengang wählen, Katalogsuche aus dem
      Grundstock, Wahlbereiche, Verschieben per Ziehen.
- [ ] **Texterkennung (OCR):** ein gescanntes PDF ohne Textebene öffnen, Suche bzw. KI-Hilfe findet Text der Seite.
      Tesseract liegt unter `%LOCALAPPDATA%\StudiNow\backend\tesseract` (`docs/OCR-WINDOWS.md`).
- [ ] **Mitteilungen:** nur, wenn dieser Bau das Tauri-Notification-Plugin enthält. Prüfen in
      `apps/windows/src-tauri/Cargo.toml` (`tauri-plugin-notification`). Dann eine Frist anlegen und auf die
      Windows-Mitteilung warten; unter Einstellungen → System → Benachrichtigungen muss StudiNow erlaubt sein. Ohne
      Plugin gibt es unter Windows noch keine Mitteilungen.
- [ ] Deinstallieren (Einstellungen → Apps). Die Daten bleiben unter `%LOCALAPPDATA%\de.uniflow.desktop`.

Fundstellen bitte mit Uhrzeit und `%LOCALAPPDATA%\de.uniflow.desktop\logs\backend.log` melden.

## 6. Was offen bleibt (Entscheidungen des Inhabers)

| Punkt | Optionen | Kosten | Stand |
| --- | --- | --- | --- |
| **Vertriebsweg** | (a) nur Microsoft Store (MSIX), (b) zusätzlich Direkt-Download (NSIS) | – | offen |
| **Partner Center** | Entwicklerkonto anlegen, Namen „StudiNow“ reservieren, drei Werte (`identity_name`, `publisher`, `publisher_display_name`) in `apps/windows/msix/store.json` und `store_ready: true` setzen, neu bauen, `StudiNow_0.6.0.0_x64.msix` hochladen (`docs/release/MICROSOFT-STORE.md`) | laut Microsoft für Einzelpersonen kostenlos, beim Anlegen prüfen | offen, `store.json` hat Testwerte |
| **Code-Signing für den NSIS-Installer** | nur für den Direkt-Download nötig: OV/EV-Zertifikat oder Azure Trusted Signing, sonst warnt SmartScreen. Der Store signiert MSIX selbst. | kostenpflichtig, **nichts gekauft** | offen |
| **Updates beim Direkt-Download** | Tauri-Updater mit eigenem Signaturschlüssel und Update-Server, oder nur über den Store | – | offen |
| **Store-Angaben** | öffentliche Datenschutz-URL, 4–6 Bildschirmfotos ab 1366 × 768, Altersfreigabe (IARC), Support-Kontakt | – | offen |
| **Größe** | Tesseract belegt 165 MB im Paket (alle DLLs des Builds). Nur die nötigen DLLs mitnehmen, etwa 40 MB (eigene Aufgabe, mit Probe-Erkennung abgesichert). | – | Vorschlag |
| **Hinweis-Tests blockierend machen** | nach dem ersten grünen Lauf `continue-on-error` entfernen | – | Koordinator |
