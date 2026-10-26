# Aufgabenteilung Apple (Mac-Sitzung) / PC-Sitzung – Stand 26.10.2026

Grundlage: der externe Prüfbericht `docs/PRUEFBERICHT-EXTERN-2026-10-26.md` (Teil A: Ziel iPad + MacBook ohne PC,
Teil B: 120 Prüfpunkte) und die Entscheidungen des Inhabers (Abschnitt 1). Die PC-Sitzung hat die wichtigsten
Behauptungen des Berichts am Code geprüft (Abschnitt 2); nur geprüfte Punkte sind hier Aufgaben. Nummern `Nr. x`
verweisen auf Teil B des Berichts.

Wer macht was: **Mac** = Mac-Sitzung (alles unter `apps/apple`, Swift-Kern, iPad/macOS, App Store).
**PC** = PC-Sitzung (Python-Server und Web, gehosteter Dienst, Windows, Android, CI, gemeinsame Verträge und Fixtures).
**Gemeinsam** = Vertrag, den die PC-Sitzung als Python-Referenz mit Fixtures festlegt und die Mac-Sitzung portiert
(wie bisher Stundenplan, Hildesheim, Fristen, Feiertage, Ankündigungen).

## 1. Entscheidungen des Inhabers (verbindlich)

1. **Apple V1 = vollständige App ohne generative KI**, lauffähig ohne PC und ohne lokalen Python-Server, auf iPad
   und auf Apple-Silicon-MacBooks. KI-Tutor, KI-Zusammenfassungen, KI-Tests kommen als Update etwa eine Woche später.
   Die klassischen Funktionen (Teil A, Abschnitt 7: Indexierung, Themen, Übung ↔ Skript, Fristen, Offline-Suche,
   Quellenangabe, keine erfundenen Treffer) **gehören in V1** und bleiben auch mit KI die Grundlage.
2. **MacBook in V1 über Variante A**: die iPad-App „Designed for iPad“ auf Apple-Silicon-Macs, mit der Mac-Checkliste
   aus Teil A (Fenster, Maus/Trackpad, Tastaturkürzel, Finder-Import, PDF-Export, StoreKit auf dem Mac). Eine eigene
   macOS-Oberfläche (Variante B) kommt später auf demselben Kern.
3. **Ein UniFlow-Konto für alle Geräte.** Der Inhaber will später problemlos zwischen Apple-Geräten, Windows und
   einem Samsung-Tablet (Android) wechseln. Darum:
   - Das Konto ist ein **UniFlow-Konto** (eigene Nutzer-ID, E-Mail + Passwort nach `docs/KONTEN-ABOS-PLAN.md`,
     Abschnitt 3). „Mit Apple anmelden“ und „Mit Google anmelden“ sind nur **Anmeldewege**, die mit genau diesem
     Konto verknüpft werden (Verknüpfung über die UniFlow-Nutzer-ID, nie über die E-Mail: Apple liefert
     Relay-Adressen). Die Apple-Benutzerkennung (`AccountStore.swift`) ist also nicht das Konto, sondern ein Schlüssel
     zu ihm.
   - **Synchronisierung über den eigenen Dienst** (gehosteter Python-Server, `LERNAPP_MODE=hosted`), nicht über
     iCloud/CloudKit: iCloud gibt es auf Windows und Android nicht. Daten, die synchron sein müssen: Notizen
     (Annotationen mit Versionen), Lernpläne/Pakete/Aufgaben, Module, Karteikarten, Einstellungen, Stundenplan-
     Ausnahmen, Hochschul-Verknüpfung (nicht die Passwörter). Hochschul-PDFs werden je Gerät selbst geladen.
   - Abo-Berechtigung (Free/Plus) hängt am UniFlow-Konto und gilt auf allen Geräten; Kauf über den jeweiligen Store
     (Apple, Google), Prüfung serverseitig (`docs/SICHERHEITSKONZEPT-KONTEN.md`).
   - Kontolöschung löscht serverseitig alles und auf jedem Gerät den lokalen Container.
4. Regeln für beide Sitzungen: keine Hochschulpasswörter eingeben (der Inhaber meldet sich selbst an); keine
   Schreibaktionen mit echten Hochschuldaten; keine kostenpflichtigen Dienste buchen (Hosting, Zertifikate,
   Entwicklerkonten entscheidet der Inhaber); keine Zugangsdaten in Git; `main` bleibt unberührt; Platzhalter dürfen
   nie Erfolg melden.

## 2. Prüfung der Behauptungen (PC-Sitzung, 26.10.2026, Stand 6d0dc42)

| Nr. | Behauptung | Befund |
| --- | --- | --- |
| 1 | `NSAllowsArbitraryLoads: true` | **bestätigt** (`apps/apple/project.yml:87`), nicht auf Debug beschränkt |
| 2, Mac | nur iPad-Ziel | **bestätigt** (`TARGETED_DEVICE_FAMILY: "2"`, `project.yml:33`) |
| 3, 57 | Android nur Kern | **bestätigt** (`apps/android/README.md`: Kern mit Tests, ungebaut) |
| 4, 55 | Windows nur Fenster auf `127.0.0.1:8765` | **bestätigt** (`apps/windows/README.md`, `main.rs` 8 Zeilen) |
| 5 | Tauri `"csp": null` | **bestätigt** (`tauri.conf.json:13`) |
| 6, 7, 10 | keine Konten, keine Nutzer-ID, `.env`-Klartext | **bestätigt**; für den lokalen Einzelplatzmodus so gewollt, für den gehosteten Dienst zu bauen (Plan liegt in `docs/KONTEN-ABOS-PLAN.md`, `docs/SICHERHEITSKONZEPT-KONTEN.md`) |
| 11–13 | PIN in URL, Cookie 365 Tage, Fehlversuche im Speicher | **bestätigt** (`app/server.py:80–91`, `_PIN_FAILS`); gilt nur im lokalen Modus |
| 15 | `app/ai.py` ruft `claude` als Subprozess | **bestätigt**; im gehosteten Modus bis zum KI-Release abschalten |
| 16, 31–40 | S6 Platzhalter | **bestätigt** (`Endpoints/Pending/PendingStudyEndpoints.swift`, `PendingOverviewEndpoints.swift`) |
| 17, 41, 42 | S7 Platzhalter | **bestätigt** (`/api/search`, `/api/related`, `pagetext` in `Pending/`) |
| 26, 43–45 | Karteikarten Platzhalter, Löschen meldet Erfolg | **bestätigt** (`PendingServicesEndpoints.swift:32–40`, `delete … { .ok }`) |
| 29 | `PrivacyInfo.xcprivacy` fehlt | **bestätigt** (keine Datei unter `apps/apple`) |
| 30, CI | keine erfolgreichen Läufe | **Ursache bekannt**: GitHub Actions seit 25.10. durch die Abrechnung gesperrt (`docs/GITHUB-ABRECHNUNG.md`); `[skip ci]` ist Folge davon. Sache des Inhabers |
| 48, 50 | Apple-Kennung lokal, keine zentrale Löschung | **bestätigt** (`apps/apple/UniFlow/Services/AccountStore.swift`) |
| 51–54 | `NotConnectedCommunityService` | **bestätigt** (`Solutions/CommunityService.swift:74`); lokaler Teil S9 ist fertig |
| 61, 62 | Datei ersetzt vor Datenbank | **bestätigt** (`UniDownloads.swift:94` rename, `:101` Transaktion). **Gleiche Reihenfolge in Python** (`studip_sync.py:357` `os.replace`, danach `:487` UPDATE) → gemeinsamer Fix |
| 71 | Migration fest auf `.luh` | **kein Fehler**: Altdaten gab es nur vor der Hochschultrennung, also nur LUH; Hildesheim-Daten lagen nie im alten Ordner (`LegacyDataMigration.swift:120`). Kommentar ergänzen |
| 83 | SVG als Asset | **bestätigt, beide Seiten** (`server.py:420` erlaubt `.svg`); Python liefert Assets mit `Content-Security-Policy: sandbox` aus (`server.py:163`), Swift muss dieselbe Kopfzeile setzen |
| 85, 87 | `base_version` optional | **bestätigt, beide Seiten** (`AnnotationEndpoints.swift:49–75`, `server.py:375`). Der Web-Editor sendet sie immer (`editor.js:582`); fehlen darf sie nur für Fremdclients → Pflicht für App-Clients |
| 88 | Favorit ohne Treffer meldet Erfolg | **bestätigt, beide Seiten** (`server.py:1034`) |
| 89 | „Gesehen“ markiert alle Dateien | **so gewollt** (Knopf „Gesehen“ unter „Neu aus Stud.IP“), beide Seiten gleich |
| 91–95 | Limits 1.500 Anfragen, 6 Ebenen, Seitenlängen | **bestätigt** (`StudIPClient.swift:123,207,225,240,249`); Python hat Pagination über `links.next`, kein Anfragelimit |
| 101, 102 | Learnweb-SSO/Token-Download nicht live geprüft | **bestätigt** (`MoodleSSO.swift:48`); der Sitzungsweg (CAS) ist live geprüft, der Schlüsselweg nicht |
| 109 | Notenspiegel 6 Seiten | **bestätigt** (`LearnwebAPI.swift:329`); live waren es 3 Seiten |
| 19 | >100 MB ohne Oberfläche | **nicht geprüft** (Mac) |
| 111–120 | Skriptsuche: OCR, Cache nach `chdate`, leere Seiten | **bestätigt** (`app/scriptsearch.py:64–135`) |
| Feiertage, Fristen, Ankündigungen | im Bericht nicht erwähnt | seit 05f46d6/6d0dc42 in Python umgesetzt, iPad-Port offen (`docs/STAND-MAC-SITZUNG.md`) |

## 3. Aufgaben der Mac-Sitzung (Apple)

Reihenfolge nach Wirkung. P0 = vor jeder Abgabe an Tester, P1 = vor dem Store.

| # | Prio | Aufgabe | Bericht |
| --- | --- | --- | --- |
| M1 | P0 | **Kein Platzhalter meldet Erfolg.** Alle `placeholder: true`-Routen antworten 501 mit Meldung („kommt mit S6“), nie `.ok` oder leere Listen, die wie „nichts da“ aussehen. Sofort: `DELETE /api/flashcards/{id}`, Favorit ohne Treffer → 404. Regressionstest über alle Pending-Routen | 45, 88, 12 (Teil A) |
| M2 | P0 | **S6 Lernplanung**: Port von `app/study.py` (Pakete, Aufgaben, Kalender, Nachholen, „Woche retten“, `reslot`, Übersicht). Fixtures: `tools/gen-local-backend-fixture.py` (läuft nur unter macOS/Linux) | 16, 31–40 |
| M3 | P0 | **S7 Suche/Skriptsuche**: Port von `app/scriptsearch.py` (BM25, Seitentexte, `/api/search`, `/api/related`, `pagetext`) mit PDFKit-Text und Vision-OCR für Scans; „nicht lesbar“ ≠ „kein Treffer“; Index nach Inhalts-Hash statt `chdate`. Die PC-Sitzung liefert Fixtures (Abschnitt 5, G3) | 17, 41, 42, 111–120, Teil A 7 |
| M4 | P0 | **Neue Original-PDF bei vorhandenen Notizen**: Fingerabdruck je Seite, Neuzuordnung, alte Fassung aufbewahren, Editor-Zwischenspeicher erneuern | 18, 21 |
| M5 | P0 | **Download-Reihenfolge** (`UniDownloads.swift`): alte Datei als APFS-Klon/Hardlink behalten, bis die Transaktion bestätigt ist; bei Fehler zurücklegen; Absturz zwischen `rename` und Transaktion mit Fehlerinjektion testen; parallele Läufe sperren; `try?` beim Aufräumen protokollieren; Speicherplatz vor großen Downloads prüfen, Grenze (z. B. >100 MB) nachfragen | 61–70, 19 |
| M6 | P0 | **Notizen**: `base_version` Pflicht für die App (ohne → 400), Restore mit aktueller Version, Konfliktdialog; Asset-Upload prüft Datei-ID in der DB; SVG nur mit `Content-Security-Policy: sandbox` wie Python oder als Rasterbild; große Dateien streamen statt `Data(contentsOf:)` | 85, 87, 84, 83, 81, 82 |
| M7 | P0 | **Release-Konfiguration**: `NSAllowsArbitraryLoads` nur Debug (Hochschulen sind https); `PrivacyInfo.xcprivacy` mit Required-Reason-APIs; `SUPPORTS_MACCATALYST`/„Designed for iPad“ auf Apple-Silicon-Macs freischalten und die Mac-Checkliste abarbeiten; StoreKit-Produkte gegen App Store Connect, sobald der Inhaber das Konto hat | 1, 2, 9, 29, Teil A 2 |
| M8 | P1 | **Karteikarten** lokal (Liste, Anlegen, Review, Löschen) wie `app/server.py` `/api/flashcards*` | 26, 43–45 |
| M9 | P1 | **Hochschul-Sync robust**: Sitzungsablauf/Logout Stud.IP; 1.500-Anfragen-Limit und 6-Ebenen-Grenze als „unvollständig“ sichtbar machen oder fortsetzen; Pagination über `links.next` wie Python; Kursfehler sichtbar; Sync-Log nicht mit `try?`; LSF ohne Exportlink klare Meldung; Notenspiegel ohne feste 6-Seiten-Grenze (Schleife bis keine neue Seite) | 23, 91–100, 105–109 |
| M10 | P1 | **Hildesheim live auf dem iPad**: Schlüsselweg (`MoodleSSO`, Token-Download) gegen das echte Learnweb; LSF, Noten, Fristen, Ankündigungen (Port nach `docs/STAND-MAC-SITZUNG.md`); nur mit dem Inhaber am Gerät | 101–104, 110 |
| M11 | P1 | **LUH-QIS nativ** (`/api/grades/sync`, Dokumente) | 24, 46, 47 |
| M12 | P1 | **S8 Hintergrundabgleich** (BGAppRefresh), Abgleich beim Öffnen | 25 |
| M13 | P1 | **Konto-Client**: `AccountStore` auf das UniFlow-Konto umstellen (Abschnitt 1.3, Vertrag G1); Anmeldung mit Apple als Verknüpfung; Hochschulwechsel in der Oberfläche; Kontolöschung ruft den Dienst und löscht lokal; `remove()`/`purgeTrash()` melden Fehler | 48–50, 78, 79 |
| M14 | P1 | **Sync-Client** nach Vertrag G2 (Notizen, Pläne, Module, Karteikarten, Einstellungen) | 8, 60, Teil A |
| M15 | P1 | **Community-Client** gegen den Dienst der PC-Sitzung (G4), nach dessen Fertigstellung | 51–54 |
| M16 | P1 | **Migrationen**: Wiederaufnahme je Schritt, Konflikte sichtbar, Punktdateien, beschädigte Statusdatei; Kommentar zu Nr. 71 (Altdaten = nur LUH) | 71–77, 80 |
| M17 | P1 | `/api/files` mit Pagination/Limit wie der Web-Client es verträgt (erst nach Abstimmung mit PC, gleiche Antwortform) | 90 |
| M18 | P1 | Gerätetests nach Teil A, Abschnitt 3, auf echtem iPad mit Pencil und MacBook; Ergebnisse anonym in `docs/STAND-MAC-SITZUNG.md` | 59, 60 |

## 4. Aufgaben der PC-Sitzung (Web, Dienst, Windows, Android)

Stand 26.10.2026 (zweite Runde): **P1, P2, P3 umgesetzt** (Konten, gehosteter Modus mit Trennung je Konto, Verträge
G1/G2 mit Fixtures, Download-Reihenfolge und Platzhalter-Regel in Python), Details in `docs/VERTRAEGE-KONTO-SYNC.md`.
Dritte Runde: Hochschul-Abgleich je Konto im Dienst (Tresor `app/vault.py`, Jobs `app/jobs.py`, Zeitplan 08:00/15:00).
Offen aus P1: Mailversand, Signaturprüfung Apple/Google, Anmeldeseite der Web-Oberfläche.

| # | Prio | Aufgabe | Bericht |
| --- | --- | --- | --- |
| P1 | P0 | **Gehosteter Modus mit Konten** (`LERNAPP_MODE=hosted`): Registrierung, Anmeldung, Sitzungen (gehashte Tokens, Ablauf, Abmelden überall), Passwort-Reset; `user_id` an jeder Tabelle und jeder Abfrage; Tests „A sieht nichts von B“ für jeden Endpunkt; PIN nur im lokalen Modus; HTTPS-Betrieb dokumentiert. Grundlage `docs/KONTEN-ABOS-PLAN.md`, `docs/SICHERHEITSKONZEPT-KONTEN.md` | 6, 7, 10–14 |
| P2 | P0 | **Vertrag G1 Konto-API** und **G2 Sync-API** (Abschnitt 5) als Python-Referenz mit Fixtures, bevor der Mac den Client baut | 8, 48–50 |
| P3 | P0 | **Datenintegrität Python**: Download-Reihenfolge wie M5 (`stream_download`/`store_course_files`: alte Datei behalten bis zum Commit); `base_version` Pflicht für App-Clients; Favorit ohne Treffer 404; Download-Hosts auf die Hochschul-Hosts beschränken (Restrisiko aus `docs/SICHERHEIT.md`); SVG-Regel mit Mac abgestimmt | 61, 62, 85, 88, 83, SICHERHEIT |
| P4 | P0 | **Skriptsuche als Referenz für S7**: OCR-Pfad für Scans (Tesseract optional), „nicht lesbar“ vs. „kein Treffer“ in der Antwort, Cache nach Inhalts-Hash, Fixtures mit echten Beispiel-PDFs (Übungsblatt → Skriptseiten) in `packages/shared-contracts/fixtures/scriptsearch` | 111–120, Teil A 7 |
| P5 | P0 | **Windows-App**: **umgesetzt** (26.10.) – Tauri startet das mitgelieferte Backend (`app/desktop.py`, PyInstaller-Ordnerpaket, Chromium daneben), freier Port auf 127.0.0.1, Daten unter `%LOCALAPPDATA%/UniFlow`, strenge CSP im Backend (`UI_CSP`) und im Fenster, Installer über `windows.yml` mit Start-Test des Pakets; offen: Updater und Signierung (Zertifikat kauft der Inhaber), erster Lauf des Workflows (Actions gesperrt) | 4, 5, 55, 56 |
| P6 | P1 | **Android-App**: Oberfläche auf dem Kotlin-Kern (Kurse, Dokumente, PDF-Anzeige mit Stift über den gemeinsamen Notizvertrag, Stundenplan, Lernkalender), Play-Store-Bundle und Signierung vorbereitet; dieselben Fixtures wie Swift | 3, 57, 58 |
| P7 | P1 | **Community-Dienst** (G4): veröffentlichen, suchen, laden, zurückziehen, melden, sperren; Berechtigung „Datei aus dem eigenen Hochschul-Abgleich“ | 27, 51–54 |
| P8 | P1 | **CI**: sobald Actions wieder laufen (Abrechnung, Inhaber), `[skip ci]` beenden, volle Läufe für `ci.yml`, `apple.yml`, `android.yml`, `windows.yml`; Linux-Lauf des Swift-Kerns bleibt als Ersatz | 30, 59 |
| P9 | P1 | **KI im gehosteten Modus** bis zum KI-Release abgeschaltet (klare 403 „kommt mit dem KI-Update“), danach über die API statt Subprozess, mit Kontingenten je Konto | 15 |
| P10 | P1 | **Store- und Rechtstexte** (`docs/release/`: Datenschutz, Nutzungsbedingungen, Impressum, App-Store-Texte ohne KI-Versprechen), Hochschul-Anfragen (`docs/ANFRAGE-STUDIP-ZUGANG.md`, `docs/ANFRAGE-HILDESHEIM.md`) – offene Aufgabe der Mac-Sitzung an die PC-Sitzung vom 26.10. | Teil A 4 |
| P11 | P2 | Web-PWA offline (Service Worker) nur, wenn die Web-Version öffentlich wird; für den lokalen PC-Modus nicht nötig | 28 |
| P12 | P1 | Windows-Setup: `tzdata` in der Doku, `Start-iPad.cmd` mit `pip install -r requirements.txt` (offen vom 26.10.) | – |

## 5. Gemeinsame Verträge (PC legt fest, Mac portiert)

| # | Vertrag | Inhalt |
| --- | --- | --- |
| G1 | **Konto** | **umgesetzt**: `/api/account/*` (register, login, login/{apple,google}, link/{apple,google}, me, logout, logout-all, password, password/reset-request, password/reset, university, delete, info); Fixture `fixtures/account/contract.json`; Doku `docs/VERTRAEGE-KONTO-SYNC.md` |
| G2 | **Sync** | **umgesetzt**: Spalten `sync_version`, `sync_updated_at`, `sync_device` + Trigger + `sync_tombstones` (`app/sync.py::ensure_schema`), `GET /api/sync/changes`, `POST /api/sync/push` (Server-IDs mit `mapping`, je Feld letzter Schreiber, Löschen/Wiederherstellen, Notizen mit `base_version`/Konflikt); Fixture `fixtures/sync/cases.json`; Doku `docs/VERTRAEGE-KONTO-SYNC.md` |
| G3 | **Skriptsuche** | Tokenisierung, BM25-Parameter, Snippet-Regel, Antwortform von `/api/search` und `/api/related` inkl. `unreadable: true`; Fixtures mit Beispiel-PDFs |
| G4 | **Community** | Paketformat ist fertig (S9, `docs/LOESUNGEN-TEILEN.md`); dazu Dienst-API: veröffentlichen, suchen nach Datei-Fingerabdruck, laden, zurückziehen, melden |
| G5 | **Download-Reihenfolge** | alte Datei behalten → neue schreiben (`.part`) → Hash → Transaktion → erst dann alte Datei entfernen; **Python umgesetzt** (`studip_sync.keep_previous/restore_previous/reconcile_backup`, Tests `tests/test_rules_g5_g6.py`: DB-Fehler nach dem Ersetzen, Download-Fehler, Absturz dazwischen) – gleiche Fälle im Swift-Kern |
| G6 | **Platzhalter-Regel** | eine nicht umgesetzte Funktion antwortet 501 mit Meldung; niemals 200/`ok`, niemals eine leere Liste ohne `pending: true`; **Python umgesetzt**: Änderung/Löschung nach unbekannter ID → 404 (19 Pfade getestet), nicht verfügbare Pfade im Dienst → 501 `not_available_hosted` |

## 6. Was nur der Inhaber entscheiden oder kaufen kann

- Apple Developer Program, App Store Connect (Produkte Plus 1,99 €/Monat), TestFlight.
- Google-Play-Entwicklerkonto; Code-Signing-Zertifikat für Windows.
- Hosting für den Dienst (Konten, Sync, Community), Domain, HTTPS; GitHub-Abrechnung für Actions.
- Zulässigkeit der Hochschulanbindung (Anfragen aus P10), Datenschutzerklärung freigeben.
- Echte Geräte für M18: iPad mit Pencil, MacBook mit M-Chip; Anmeldung an Stud.IP/Learnweb/LSF dort selbst.

## 7. Reihenfolge

1. Beide sofort: Platzhalter-Regel (M1), Release-Konfiguration (M7), Download-Reihenfolge (M5/P3).
2. Mac: S6 (M2), S7 (M3, M4). PC: Konten (P1), Verträge G1/G2 (P2), Skriptsuche-Referenz (P4).
3. Mac: Konto- und Sync-Client (M13, M14). PC: Windows mit Backend (P5).
4. PC: Community-Dienst (P7), Android (P6). Mac: Community-Client (M15), Hildesheim/LUH live (M10, M11), S8 (M12).
5. Gerätetests (M18), Store-Texte (P10), Veröffentlichung iPad + Mac; Windows und Android danach auf demselben
   Konto- und Sync-Dienst.
