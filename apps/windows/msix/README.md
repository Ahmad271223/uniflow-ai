# UniFlow im Microsoft Store (MSIX)

**Stand 27.10.2026:** Der Workflow `windows.yml` baut neben dem NSIS-Installer ein MSIX-Paket aus derselben App
(`scripts/build-msix.ps1`), installiert eine testsignierte Fassung auf dem Runner, startet das Backend im Paketkontext
(`scripts/check-msix.ps1`) und lädt beides als Artefakt `uniflow-windows-msix` hoch. Hochgeladen in Partner Center ist
noch nichts; dafür fehlen die Werte aus Partner Center in `store.json` (Testwerte, `store_ready: false`).

Warum MSIX statt des NSIS-Installers: Der Store signiert MSIX-Pakete selbst (kein eigenes Zertifikat nötig) und
verteilt Updates automatisch. Ein EXE-Installer bräuchte ein gekauftes Code-Signing-Zertifikat, eine feste
HTTPS-Adresse je Version und eine eigene Update-Funktion.

## Aufbau

| Datei | Inhalt |
| --- | --- |
| `AppxManifest.xml.in` | Manifest mit Platzhaltern: Identität, Anzeigename, `runFullTrust` (Desktop-App), `internetClient`, Windows 10 1809+ |
| `store.json` | Werte aus Partner Center (Produktidentität) und Store-Texte; `store_ready` erst nach dem Eintragen auf `true` |
| `../scripts/build-msix.ps1` | baut aus `uniflow-desktop.exe` und `backend\` (mit Chromium) das Paket; Bilder aus `app-icon.png`, Version aus `tauri.conf.json` als `x.y.z.0`; `-TestSign` signiert zusätzlich mit einem Wegwerf-Zertifikat |
| `../scripts/check-msix.ps1` | nur auf dem Runner: Testzertifikat vertrauen, installieren, Dateien prüfen, Backend im Paket starten und abfragen, deinstallieren |

Artefakt `uniflow-windows-msix`: `UniFlow_<version>.0_x64.msix` (unsigniert, für Partner Center) und
`…-test.msix` mit `…-test.cer` (nur zum Ausprobieren, siehe unten).

Im Paket schreibt Windows alles, was die App unter `%LOCALAPPDATA%` anlegt, in einen eigenen Bereich des Pakets
(`%LOCALAPPDATA%\Packages\<Paketfamilie>\LocalCache\…`). Daten der NSIS-Fassung (`%LOCALAPPDATA%\de.uniflow.desktop`)
sieht die Store-Fassung deshalb womöglich nicht; Kurse und Dateien kommen mit dem ersten Abgleich wieder. Vor dem Wechsel
die NSIS-Fassung deinstallieren, damit nicht zwei UniFlow im Startmenü stehen.

## Was der Inhaber in Partner Center einrichtet

1. **Konto:** <https://storedeveloper.microsoft.com> → als Einzelperson registrieren (Microsoft-Konto,
   Identitätsprüfung). Laut Microsoft für Einzelpersonen kostenlos; beim Anlegen prüfen.
2. **App anlegen und Namen reservieren:** Partner Center → Apps und Spiele → Neues Produkt → MSIX- oder PWA-App →
   Namen eingeben (z. B. „UniFlow“; ist er vergeben, einen anderen wählen – der reservierte Name ist der Anzeigename
   im Store und muss zu `display_name` in `store.json` passen).
3. **Produktidentität kopieren:** Produktverwaltung → Produktidentität. Drei Werte an die PC-Sitzung geben oder selbst
   in `store.json` eintragen und `store_ready` auf `true` setzen:
   - `Package/Identity/Name` → `identity_name`
   - `Package/Identity/Publisher` (beginnt mit `CN=`) → `publisher`
   - `Package/Properties/PublisherDisplayName` → `publisher_display_name`
   Danach baut der nächste Lauf von `windows.yml` ein Paket, das Partner Center annimmt.
4. **Einreichung anlegen** (Übermittlung starten):
   - *Preise und Verfügbarkeit:* kostenlos; Märkte (mindestens Deutschland); Sichtbarkeit öffentlich oder zuerst
     „Privat, nur per Link“ zum Testen.
   - *Eigenschaften:* Kategorie Bildung; **Datenschutzerklärung-URL** (Pflicht, die App verarbeitet persönliche Daten;
     Entwurf `docs/release/DATENSCHUTZ.md`, muss öffentlich erreichbar sein); Support-Kontakt.
   - *Altersfreigabe:* IARC-Fragebogen ausfüllen (Lern-App ohne Nutzerinhalte für andere außer Community → je nach
     Antwort „USK 0“).
   - *Pakete:* das unsignierte `UniFlow_<version>.0_x64.msix` aus dem Artefakt `uniflow-windows-msix` hochladen.
   - *Store-Einträge (Deutsch):* Beschreibung, mindestens ein Screenshot (1366 × 768 oder größer), kurze Merkmale.
   - *Hinweise für die Zertifizierung:* erklären, dass `runFullTrust` nötig ist (Desktop-App mit lokalem Dienst und
     eingebautem Chromium für die Hochschul-Anmeldung), und wie Prüfer ohne Hochschulkonto testen: Einstellungen →
     Erweitert → Demo-Inhalte (`app/demo.py`).
5. **Einreichen:** Die Prüfung dauert meist einige Werktage. Danach installiert der Store die App und spielt jede neue
   Fassung automatisch ein.

## Neue Fassung veröffentlichen

1. Version in `apps/windows/package.json`, `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml` erhöhen
   (Test `test_windows_app_versions_match`), pushen.
2. Artefakt `uniflow-windows-msix` des Laufs herunterladen, in Partner Center eine neue Übermittlung mit dem neuen Paket
   anlegen. Die MSIX-Version muss höher sein als die letzte veröffentlichte.
3. Nach der Freigabe bekommen alle Nutzer das Update automatisch.

## Testfassung ausprobieren (optional)

`…-test.msix` ist mit einem Wegwerf-Zertifikat signiert. Zum Installieren muss `…-test.cer` einmal als
vertrauenswürdig eingetragen werden (Doppelklick → Zertifikat installieren → Lokaler Computer → „Vertrauenswürdige
Personen“; braucht Administratorrechte), dann `…-test.msix` doppelklicken. Danach das Zertifikat wieder entfernen
(`certlm.msc` → Vertrauenswürdige Personen). Für die Store-Fassung ist das nicht nötig.

## Offen

- Werte aus Partner Center in `store.json` (siehe oben), Screenshots, öffentliche Datenschutzerklärung.
- WebView2 ist ab Windows 10 21H2 und unter Windows 11 vorhanden; auf älteren Windows-10-Fassungen fehlt es eventuell
  (der NSIS-Installer bringt dafür einen Installer mit, MSIX nicht).
- Das Fenster selbst (WebView2) startet der Runner nicht; geprüft werden Dateien und das Backend im Paketkontext.
