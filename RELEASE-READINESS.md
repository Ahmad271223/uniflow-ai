# UniFlow AI – Release-Readiness (Zweig `develop`, 25.10.2026)

> Neuester Stand: [`docs/LIVE-BLOCKER-TEST-2026-10-25.md`](docs/LIVE-BLOCKER-TEST-2026-10-25.md) (Live-Blocker-Test,
> fünf behobene Blocker, Serverplanung nach Nutzerzahl).

Kurzfassung: **Nicht release-bereit.** Server und Web-Editor sind getestet und gehärtet. Die iPad-App ist bis Phase 3
im Simulator grün, Phase 4 kompiliert, alles danach ist **nicht gebaut**, weil GitHub Actions seit 25.10., 00:15 Uhr
wegen der Abrechnung keine Jobs startet. Kein Test auf einem echten iPad oder Mac. `main` ist unverändert, kein Merge,
kein Release.

## 1. Erfolgreich gebaut

| Was | Wo | Commit |
| --- | --- | --- |
| UniFlowCore (Swift-Paket) | GitHub Actions: Linux (`swift:6.0-jammy`) und macOS 15 | bis `ecfdfab` jeder Lauf grün |
| iPad-App inkl. Phase 4 (Editor-Funktionen, StoreKit-Code) | macOS 15, Xcode 16.4, iPad-Simulator | `ecfdfab` (App-Ziel kompiliert; Testziel scheiterte an einer Testdatei) |
| Server (Python 3.14), Weboberfläche | lokal und CI | aktueller Stand |

## 2. Erfolgreich getestet

| Bereich | Tests | Wo | Stand |
| --- | --- | --- | --- |
| Server: Sicherheit, Datenverlust, Verträge, Migration, Kontingente | 42 | lokal (pytest) | aktuell |
| Gemeinsame Zusammenführung Web | 10 | lokal (Node) | aktuell |
| Swift-Kern: JSON, Zusammenführung, Journal, Sync (1000/5000 Striche, Upload-Überschneidung, Netzabbruch, Absturz, Speicherfehler, Konflikte, Neustart) | 37 | CI Linux + macOS | `ecfdfab` |
| iPad: Strich-Identität, Pixel-Radierer, Lasso, Seitenkoordinaten, Overlay-Anforderung | 12 | CI iPad-Simulator | `6b699b4` |
| Web-Editor: Konflikt mit zweitem Gerät auf derselben Seite, Entwurf beim Dauerschreiben | manuell mit simulierten Eingaben | eingebauter Browser | 25.10. |
| Gehärteter Server mit echter Oberfläche (PDF-Anzeige, Speichern, Download statt Anzeige für `.py`) | manuell | Testinstanz `127.0.0.1:8766` mit Datenbank-Kopie | 25.10. |

## 3. Fehlgeschlagen

| Was | Ursache | Stand |
| --- | --- | --- |
| Apple-Läufe `d801e9e`, `df90001`, `4ef3377`, `ecfdfab` | echte Kompilierfehler (`CGSize`, `Transaction`, `cos`, Raw-String in Test) | im Code behoben, Korrektur des letzten nicht gebaut |
| Apple `7efe85f`, `b5922f3`; CI und Android `b5922f3` | **Abrechnungssperre**, Jobs nie gestartet | wartet auf Freigabe (`docs/GITHUB-ABRECHNUNG.md`) |

## 4. Noch nicht getestet

- **Swift seit `ecfdfab` (nie kompiliert):** Übersicht, Module, Kalender, KI-Tests, Einstellungen, geteilte Ansicht,
  gemeinsame Palette und gemeinsamer Rückgängig-Verlauf, Seitenschlüssel-Umbau, Lebenszyklus (Pausieren statt Beenden
  beim Tabwechsel). Von Hand Zeile für Zeile geprüft; dabei behoben: Tupel-Keypaths in Listen, mehrdeutige
  Koordinatenebene, Startseite des Skripts, StoreKit-Datei nicht im Testbundle.
- **iOS-Tests ohne Lauf:** Phase-4-Tests (6), Kauftest (2), Hilfsbausteine (4).
- **Android-Kern** (Kotlin) und **Windows** (Tauri): nie gebaut; Konfiguration und Code statisch geprüft.
- **Alles am Gerät:** Schreibgefühl, Handballen, Pencil-Doppeltippen, Palette, Zoom am Gerät, Speicher bei großen PDFs,
  Offline über mehrere Tage, Export am Gerät (`docs/MAC-IPAD-CHECKLISTE.md`).
- Stud.IP-Abgleich auf dem iPad: nur Konzept (`docs/IPAD-STUDIP-SYNC.md`).

## 5. Kritische Risiken

| Risiko | Folge | Gegenmaßnahme |
| --- | --- | --- |
| **Laufender Server hat noch die alte, angreifbare Version** | Dateien lesbar/schreibbar, bis neu gestartet wird | `Start-iPad.cmd` neu starten (Ordner steht auf `develop`) |
| Zugangsdaten waren über die Leselücke erreichbar | Missbrauch von LUH-Konto, Servern (SSH), Claude | Wechsel nach `docs/SICHERHEIT.md` Abschnitt 3 |
| ~1.400 Zeilen Swift nie kompiliert | erste CI-Runden werden Fehler zeigen | Checkliste unten; Fehler sind meist klein (Typen, APIs) |
| Kein Gerätetest | Stifteingabe kann sich anders verhalten als im Simulator | Gerätetest vor jeder weiteren Funktion |
| Stud.IP auf dem iPad braucht OAuth2-Client der LUH | ohne ihn nur Übergangslösung (Anmeldung beim Öffnen) | Anfrage an das Stud.IP-Team der LUH |
| Firewall erlaubt Python in öffentlichen Netzen | Erreichbarkeit im eduroam | Befehle in `docs/SICHERHEIT.md` Abschnitt 4 (als Admin) |

## 6. Erforderliche Entscheidungen

1. **GitHub Actions**: bis zum Monatswechsel warten oder Actions-Budget erhöhen (kostet Geld).
2. **Server neu starten** und **Zugangsdaten wechseln** (deine Aktionen).
3. **Firewall-Regeln** einschränken (Administrator).
4. **Lokale Werkzeuge** (optional, siehe unten): Docker-Images laden, Gradle oder Rust installieren.
5. **LUH anfragen**: OAuth2-Client für Stud.IP.
6. Später: Hosting, KI-Abrechnung, Apple Developer Program, Notiz-Sync über den Dienst ja/nein.

### Lokale Werkzeuge (geprüft, nicht installiert)

| Werkzeug | Zweck | Weg | Umfang |
| --- | --- | --- | --- |
| Docker (vorhanden, läuft nicht) | Swift-Kern und Kotlin-Kern lokal testen, ohne Actions | Docker Desktop starten, Images `swift:6.0-jammy`, `gradle:8.10-jdk17` laden | ca. 1–2 GB Download, keine Installation |
| Gradle (Java 17 vorhanden) | Android-Kern | Zip von gradle.org entpacken | ca. 130 MB + Abhängigkeiten |
| Rust + Visual Studio Build Tools | Tauri-Build für Windows | rustup + C++-Build-Tools (Admin) | mehrere GB |
| Swift für Windows | Swift-Kern ohne Docker | Toolchain + Build Tools | mehrere GB |

Empfehlung: Docker-Weg (geringster Eingriff, deckt Swift- und Kotlin-Kern ab). Die iPad-App selbst braucht immer macOS.

## 7. Geschätzter Aufwand bis zur ersten iPad-Testversion

| Schritt | Aufwand |
| --- | --- |
| CI grün bekommen (Kompilierfehler Phase 5/6, 2–5 Runden) | 0,5–1 Tag |
| MacBook einrichten, App per Kabel auf das eigene iPad (kostenlose Signierung) | 0,5 Tag |
| Gerätetest nach Checkliste, kritische Fehler beheben | 2–4 Tage |
| **Erste selbst installierte iPad-Testversion** | **ca. 3–6 Arbeitstage** |
| TestFlight (Developer Program, HTTPS-Testserver, Datenschutzangaben) | zusätzlich 1–2 Wochen, Kosten nach Freigabe |

## 8. Checkliste, sobald GitHub Actions wieder läuft

1. Abrechnung prüfen und freigeben (`docs/GITHUB-ABRECHNUNG.md`).
2. GitHub → Actions → **Apple** → „Run workflow“ auf `develop`. Erwartet: Linux-Kern 37 Tests, macOS-Kern 37,
   iPad-Simulator 24 Tests (StrokeConverter 8, PDFLayout 4, EditorFeature 6, Purchase 2, Support 4).
3. Bei Kompilierfehlern: alle Fehler eines Laufs zusammen beheben, ein Commit, erneut starten. Jede Runde mit
   Fehlern und Korrektur in `docs/ENTWICKLUNGSSTAND.md` eintragen.
4. **CI** läuft beim Push automatisch: Python 42 Tests, pip-audit, Geheimnis-Prüfung, Web-Syntax, Node-Tests.
5. **Android** (Kotlin-Kern) prüfen; bei Fehlern wie Schritt 3.
6. **Windows** einmal manuell starten, Installer aus den Artefakten lokal testen, `Cargo.lock` übernehmen.
7. Ergebnisse in diese Datei übertragen (Abschnitte 1–4), erst dann neue Funktionen.
8. Danach: Gerätetest nach `docs/MAC-IPAD-CHECKLISTE.md`.

## Verweise

`docs/SICHERHEIT.md` · `docs/SICHERHEITSKONZEPT-KONTEN.md` · `docs/IPAD-STUDIP-SYNC.md` · `docs/GITHUB-ABRECHNUNG.md` ·
`docs/ENTWICKLUNGSSTAND.md` · `docs/BESTANDSAUFNAHME.md` · `docs/MAC-IPAD-CHECKLISTE.md` · `docs/KONTEN-ABOS-PLAN.md`
