# Was fehlt auf der Windows-Version? (Stand 05.11.2026)

Frage des Inhabers: „Was fehlt alles auf der Windows-Version?“

Nur gelesen, nichts im Repo geändert. Verglichen wurde die iPad-App (`apps/apple`, SwiftUI mit eigenem Backend im
Gerät, `UniFlowCore`) mit der Windows-App (`apps/windows`: Tauri-Fenster, darin dieselbe Web-Oberfläche `app/static`,
darunter der Python-Server `app/*.py` auf dem PC).

## Kurz gesagt

- **Die Grundausstattung ist da:** Hochschul-Anmeldung, Abgleich (Stud.IP, Learnweb, LSF, QIS), Bibliothek, PDF-Editor,
  Stundenplan, Lernkalender, Module mit Lernstand, Karteikarten, Wochentests mit eigener KI, Community über den Dienst,
  Geräte-Abgleich.
- **Es gibt seit dem 28.10. keinen grünen Windows-Bau.** Der einzige Lauf danach (04.11., Lauf 41929677402) bricht beim
  Tesseract-Schritt ab. Version 0.5.0 ist nie als Installer entstanden.
- **Die größte Lücke ist die KI.** Am PC läuft KI nur über das eigene ChatGPT-Abo oder die Claude-Code-Kommandozeile.
  Die StudiNow-KI mit Credits (Pro AI), die das iPad über das Konto nutzt, erreicht Windows nicht.
- **Die neuen iPad-Funktionen vom 03./04.11. fehlen fast alle in Web/Windows:** Studienverlauf, Nachrichten, KI-Start,
  Erklärungsspeicher, Dokument-Index, Weitermachen, Vorlesung aufnehmen mit Mitschrift, Videos & Links, Einladungen.
- **Bezahlen gibt es unter Windows nicht.** Am eigenen PC ist alles frei („Eigener PC“). Ob das so bleibt, ist eine
  Entscheidung des Inhabers.
- **Veröffentlichen:** MSIX für den Store ist gebaut, aber ohne echte Partner-Center-Werte. Der NSIS-Installer ist
  unsigniert und hat keine Update-Funktion.

## Grundlage

| Stand | Commit | Bemerkung |
| --- | --- | --- |
| Lokal vor dem Zusammenführen | `backup/develop-vor-zusammenfuehren-2026-11-04` = `18fd948` | 8 eigene Commits seit `aa1f32f` (Studienverlauf, Nachrichten, angemeldet bleiben, Design, Erklärungsspeicher, Wochentest-Optionen, Lernstand, Dateiarten, Vorlesung aufnehmen, Einladungen, Credits, Klausurtermine) |
| Cloud-Stand (vorher `origin/develop`) | `4939743` | 10 eigene Commits (Tarife Free/Plus/Pro AI, Karteikarten-Stapel, fertige Wochenfragen, Notizen-Abgleich erst ab Pro AI) |
| **Zusammengeführt, jetzt `origin/develop`** | `b580e68` | wurde während dieser Prüfung gepusht; lokales Stapel-Modell bleibt, Cloud-Doppel entfernt, fertige Wochenfragen übernommen |

Alle Aussagen unten gelten für `b580e68`. Wo nur ein Zweig etwas brachte, steht es in der Spalte „Beleg“. An den
Windows-Dateien (`apps/windows`, `app/desktop*.py`, `app/service_link.py`, `app/unilogin.py`, Workflow) hat das
Zusammenführen nichts geändert.

**Wichtig zum Verständnis:** Die Windows-App ist ein Einzelplatz (`LERNAPP_DESKTOP=1`, nicht `hosted`). Der lokale
Server leitet nur `/api/community/...` an den StudiNow-Dienst weiter (`app/server.py`, Middleware `community_link`).
Alles andere, was es „nur im Dienst“ gibt, antwortet am PC mit 501 `not_hosted`.

## Legende

- **Status:** vorhanden · teilweise · fehlt
- **Aufwand** für Windows/Web: **S** bis 1 Tag · **M** 2 bis 5 Tage · **L** mehr als eine Woche (jeweils mit Tests,
  ohne Prüfung auf echtem Windows)

## 1. Anmeldung und Hochschule

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Hochschul-Anmeldung (LUH, Hildesheim) | WebView, Cookies im Schlüsselbund | Anmeldefenster der App (WebView2), Sitzung in `university-session.json`; ohne Fenster-Agent Playwright | vorhanden | `app/desktop_windows.py`, `app/unilogin.py`, README „Browserfenster in der App“ | – |
| Angemeldet bleiben | alle Cookies der Hochschul-Domains inkl. Anmeldeseite, stille Erneuerung beim Öffnen und vor dem Abgleich, Benutzername vorausgefüllt, „Angemeldet bleiben“ angekreuzt | WebView2-Profil behält Cookies. **Keine** stille Erneuerung, kein vorausgefüllter Benutzername, kein „Passwort speichern?“ (`IsPasswordAutosaveEnabled` offen). Abgelaufen → „Anmeldung nötig“ | teilweise | `docs/IPAD-STUDIP-SYNC.md` §13 („nur iPad“); kein Treffer für Erneuerung in `unilogin.py`/`desktop_windows.py`; README „Noch offen“ | M |
| Hochschul-Links im angemeldeten Browser | In-App-Browser | Links öffnen als App-Fenster (seit 0.3.9), gleiches WebView2-Profil | vorhanden | README „Browserfenster in der App“ | – |
| Abgleich Stud.IP / Learnweb / LSF / QIS | direkt aus der App, auch im Hintergrund (BGTask) | Python-Abgleich, nur solange die App offen ist; kein Autostart, kein Infobereich | teilweise | `app/studip_sync.py`, `app/hildesheim.py`, `app/qis.py`; `BackgroundSync.swift` | S–M (nice-to-have) |
| Frühere Semester | ja | ja | vorhanden | `app/older_semesters*.py`, `older-semesters*.js` (Prüfdaten `app-paths.json` nennen es noch „nur auf dem Gerät“ – veraltet) | – |
| **Nachrichten** (Stud.IP-Posteingang, Zähler, Suche) | Seitenleiste „Nachrichten“ | kein Python, keine Seite | **fehlt** | `StudIPMessagesEndpoints.swift` („keine Python-Entsprechung“), `app.js` ohne Route `messages` | M |
| Schwarzes Brett, Blubber | ja (Blubber aus) | ja (Blubber aus) | vorhanden | `app/studip_bulletin.py`, `bulletin.js` | – |
| Neuigkeiten, „Aus Stud.IP“ (Courseware, Wiki, Forum) | ja | ja | vorhanden | `news.js`, `studip-texts.js` | – |
| Noten (QIS) | ja | ja | vorhanden | `/api/grades`, „Uni & Noten“ | – |
| Geführter Erststart | Willkommen, Hochschule wählen, Anmeldung, Tarif | leere Übersicht, Anmeldung unter Einstellungen → Zugang | teilweise | `Views/Onboarding/*`, `views-misc.js` („Im Browser anmelden“) | S–M |

## 2. Studium

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Begrüßung | „Guten Morgen, Lea“ | „Guten Morgen!“ ohne Namen | teilweise | `views-home.js`, `docs/WEITERMACHEN-2026-11-04.md` Z. 26 | S |
| **Weitermachen / Zuletzt benutzt** | letztes Dokument auf der Seite, KI-Hilfe mit Gespräch, Liste „Zuletzt benutzt“ | nichts | **fehlt** | `/api/recent` nur Gerät (`app-paths.json`), WEITERMACHEN Z. 67 „kein Gegenstück“ | M |
| Stundenplan | aus dem eigenen Stud.IP-Kalender, Rückfragen bei unklaren Gruppen, Ausfälle | aus dem Stud.IP-Kalender (`timetable.py`); Rückfragen und Ausfall-Anzeige fehlen | teilweise | `/api/timetable/studip-questions`, `/studip-cancelled` nur Gerät | M |
| Lernkalender, Timer | ja | ja | vorhanden | `views-plan.js`, Editor „Zeitmesser“ | – |
| Module, Lernstand je Modul | ja | ja | vorhanden | `app/mastery.py`, `mastery.js` | – |
| Klausurtermine | aus allen Quellen, Karte, Kalender-Pins, Modulkopf, auch aus Dokumenten erkannt | Karte „Nächste Klausuren“ aus Stud.IP, Ankündigungen, QIS, Fristen; ohne Erkennung in Dokumenten | teilweise | `app/exams.py`, `exams.js`; `Exams.swift:248` „nur auf dem Gerät“ | S–M |
| Fristen aus Dateien erkennen, Erinnerungen | Erkennung + lokale Mitteilungen | fehlt; Windows hat gar keine Mitteilungen (kein Tauri-Plugin) | **fehlt** | `DueDetection.swift`, `DueReminderScheduler.swift`; `Cargo.toml` nur `single-instance` | M |
| **Studienverlauf** (Semester-Spalten, Moduldetail, Wahlpflicht, Nachholen) | Seite + Eintrag in der Seitenleiste + Knopf im Modul | Python-Routen `/api/study-plan*` da, aber: keine Seite, Katalogsuche (`study_catalog.run_sync`) wird nirgends aufgerufen, Grundstock liegt unter `apps/apple/...` und ist nicht im Windows-Paket, Register-JSON auch nicht | **fehlt** | `app.js` ohne Route `studyplan`; `study_catalog.py` `SEED_DIR`; `uniflow-backend.spec` `datas` | L |
| Katalog-Bibliothek (geteilte Kataloge) | CloudKit `StudyCatalog` | nichts | fehlt | `StudyCatalogCloudKit.swift` | M (Entscheidung: Dienst?) |

## 3. Dokumente und Editor

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Bibliothek, Ordner, „Mein Regal“, Suche | ja | ja | vorhanden | `views-lib.js`, `scriptsearch.py` | – |
| Word .docx | Textansicht + KI-Hilfe | Word-Ansicht (nur ansehen), Text für Suche/KI | vorhanden | `docs/DATEIARTEN.md`, `app/docx_view.py` | – |
| PowerPoint .pptx | Textansicht + KI-Hilfe | Textansicht je Folie, Original zum Herunterladen | vorhanden | `filekinds.js`, `views-doc.js` | – |
| Audio-Transkript | auf dem Gerät (Apple-Spracherkennung) | nur Hinweis und Download | fehlt | DATEIARTEN „kein Transkript am PC“ | L (nice-to-have) |
| **Videos & Links** (Opencast, YouTube, TIB, Courseware-Videos) | Bereich im Modulordner, Player | kein Opencast im Python | **fehlt** | `Opencast/*.swift`; kein Treffer „opencast“ in `app/*.py` | M |
| Alte Dateifassungen bei Notizen | alte Fassung bleibt, späte Striche gehen nicht verloren | nur Notiz-Verlauf, keine alten Originale | teilweise | `FileVersionEndpoints.swift` (nur Gerät), `/api/files/{id}/annotations/versions` | M |
| Editor: Stift, Textmarker, Formen, Text, Haftnotiz, Lasso, Lineal, Lesezeichen, Export | PencilKit | Konva, Stiftdruck über Pointer Events (Windows Ink) | vorhanden | `editor.js` | – |
| Seitenleiste „+“, Vorlagen, Papierkorb, Drehen, Rückgängig | ja | ja | vorhanden | `editor.js`, `pagerotate.js` | – |
| Formerkennung nach Halten | Linie, Rechteck, Ellipse, Dreieck, Pfeil | fehlt | fehlt | `Editor/ShapeRecognizer.swift` | S–M |
| „Als Karteikarte“ aus markiertem Text | ja | fehlt (nur KI-Modus „Karteikarten erstellen“) | fehlt | Commit `d1c1be0` | S |
| Texterkennung (OCR) für Scans | Apple Vision | `pageocr.py` + Tesseract; **Bau scheitert genau hier** | teilweise (Blocker) | Lauf 41929677402: „tesseract.exe fehlt nach der Installation“ in `add-tesseract.ps1:35` | S |
| **Vorlesung aufnehmen** | eigene Aufnahmen mit Live-Mitschrift, Vorschlag aus dem Stundenplan, Suche in Transkripten, KI-Zusammenfassung | nur Audioaufnahme je Dokument im Editor, ohne Mitschrift | teilweise | `editor.js` „Transkription ist in dieser lokalen Version nicht verfügbar“; `/api/recordings/own` nur Gerät | L |

## 4. KI

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| **Woher die KI kommt** | Geteiltes (0 Credits) → eigenes ChatGPT → StudiNow-KI mit Credits über das Konto | nur eigenes ChatGPT oder `claude -p` (Claude-Code-Kommandozeile, für Endnutzer nicht vorhanden). StudiNow-KI des Dienstes wird am PC nie genutzt | **fehlt** | `StudoraAccountLink.swift:304`; `app/ai.py` (`ask`), `server.py` `_tutor_hosted` nur bei `is_hosted()`; Weiterleitung nur `/api/community/` | L |
| **KI-Start** (Gespräch, farbige Aktionen, Hilfe ohne KI, Dokument anhängen) | `#/ki` | keine Route | **fehlt** | `AIStartView.swift`; `app.js` `routes` | M |
| KI-Hilfe im Editor | drei farbige Reiter (Erklären, Karteikarten, Test), Markdown, Gesprächsverlauf | Seitenleiste mit Auswahlliste (10 Modi), Karten speichern; keine Reiter, kein Markdown | teilweise | `editor.js:232` | S–M |
| **Erklärungsspeicher** („Schon erklärt · 0 Credits“) | CloudKit `PageExplain` | Dienst-Routen `/api/explain` gebaut, aber Web ruft sie nicht; am PC 501 und nicht weitergeleitet | **fehlt** | `docs/ERKLAERUNGSSPEICHER-2026-11-04.md` Z. 104, `page_explain_api.py` | M |
| Dokument-Index (Einordnung je Seite, Regal-Pfad) | ja | nur Dienst-Stub (`analyze_page`) | fehlt | `docs/DOKUMENT-INDEX-2026-11-04.md` „Dienst (V2)“ | M–L |
| Credits-Anzeige | ja | nur im gehosteten Web | fehlt am PC (folgt aus der KI-Frage) | `views-abo.js` | S nach KI-Lösung |

## 5. Lernen

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Wochentests (automatisch, „Fehlende Wochentests“) | ja | ja, mit eigener KI | vorhanden | `weekly.py`, `views-weekly.js` | – |
| Wochentest-Optionen (Anzahl, Schwierigkeit, Arten inkl. Wahr/Falsch und Lückentext, Thema) | ja | Python kann es (`ai.week_test_options`), Web-Dialog fragt nur Modul und Dauer | teilweise | `views-misc.js:112` | S |
| Gemeinsame Wochentests (Pool) | über Dienst / CloudKit | am PC kein Pool, nur eigener Schlüssel | teilweise | `docs/GEMEINSAME-WOCHENTESTS.md` Z. 96 | hängt an der KI-Frage |
| Testergebnis mit Ring, „Frag die KI zu Aufgabe n“ | ja | ja | vorhanden | `test-result.js` (Lückentext fehlt in `QTYPE`) | – |
| Fertige Wochenfragen (Pro AI, aus der Cloud-Sitzung) | zieht nach | nur im Dienst; am PC 501 `not_hosted` | fehlt am PC | `app/week_library_api.py` | M |
| Karteikarten: Stapel, Bearbeiten, Üben, Lesemodus | ja | ja | vorhanden | `flashcards.js`, `flashcard-stacks*.js` | – |
| Wochenstapel holen | geteilt oder neu | am PC immer eigener Stapel (eigene KI, Status `unshared`) | teilweise | `docs/KARTEIKARTEN-STAPEL-2026-11-04.md` Z. 136 | – |
| Stapel teilen / geteilte übernehmen | CloudKit `WeekCardStack`, `CardStackShare` | Lesen geht über die Weiterleitung; **Teilen 501** (`/api/flashcard-stacks/{id}/share` nicht weitergeleitet); **Übernehmen** legt den Stapel im Dienst-Konto an, nicht auf dem PC | teilweise | `community_cards_api.py` `_user`; KARTEIKARTEN Z. 137–139 „offen“ | M |

## 6. Gemeinsam (Community)

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Lösungen, Korrekturen, Fragen je Kurs, Kanal nach Lehrwoche | CloudKit oder Dienst | über den Dienst (Weiterleitung) | vorhanden (braucht Konto und laufenden Dienst) | `community-channel.js`, `community-corrections*.js`, `server.py` `community_link` | – |
| StudiNow-Konto am PC | Anmelden, Registrieren | nur Anmelden; **Dienstadresse muss man eintippen** (kein Standard, nur `LERNAPP_SERVICE_URL`); kein Registrieren, kein „Passwort vergessen“ | teilweise | `studora-link.js:67`, `service_link.normalize_url` | S |

**Wie iPad und Windows zusammenhängen:** Ein iPad **ohne** StudiNow-Konto nutzt CloudKit. Ein iPad **mit** Konto derselben
Hochschule schaltet auf `ServiceCommunityService` um (`StudoraAccountLink.swift:134`) und sieht dieselbe Community wie
Windows und Web. Nur über CloudKit laufen weiter: Erklärungsspeicher, Dokument-Index, geteilte Wochenstapel und die
Katalog-Bibliothek. Diese vier sieht Windows nie, solange der Dienst sie nicht spiegelt.

## 7. Konto, Tarife, Kauf, Einladungen

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Tarife und 7-Tage-Probe | Free / Plus / Pro AI über StoreKit, Probe je Apple-ID | am eigenen PC keine Tarife: alles frei, Seitenleiste „Eigener PC“, kein „Plus holen“ | anders gebaut (Entscheidung) | `shell-nav.js` `planLabel`, `billing.LOCAL_PLAN`, `docs/TARIF-MATRIX-2026-11-04.md` §3 | – |
| Kaufen unter Windows | App Store | **kein Zahlungsweg**: Stripe ist nur für das gehostete Web gebaut, Microsoft-Store-Kauf nicht gebaut | **fehlt** | `docs/ABO-SYSTEM.md` Z. 83, 123; `app/stripe_billing.py` | M (Stripe über Konto) bis L (Store-Kauf) |
| Einladungen (Links, Stufen, Belohnung) | ja (Apple-Angebotscodes) | Endpunkte `/api/invites` da, keine Seite; Belohnung für Stripe nicht entschieden | **fehlt** | `docs/EINLADUNGEN.md` Z. 126 | M |
| Demo für die Store-Prüfung | Link auf der Anmeldeseite | Einstellungen → Erweitert → Demo-Inhalte | vorhanden | `app/demo.py`, `msix/README.md` | – |
| Konto entfernen (PC weitergeben) | ja | ja | vorhanden | `app/reset.py` | – |

## 8. Geräte und Abgleich

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Geräte-Abgleich iPad ↔ PC (G2) über den Dienst | `DeviceSync.swift` | `app/sync_client.py`, Knopf „Jetzt abgleichen“ | vorhanden, **nie zwischen echtem iPad und echtem Windows geprüft** | Notizen erst ab Pro AI (`can_sync_annotations`, Commit `11344c2`) | Test: S–M |
| WLAN-Modus (iPad am PC) | nur Entwicklung | Windows-App hört bewusst nur auf `127.0.0.1` | so gewollt | README „Sicherheit“ | – |
| Offline | alles Lokale geht | alles Lokale geht (Server auf dem PC); Community, KI, Konto, Abgleich brauchen Netz | vorhanden | – | – |

## 9. Bauen, Installieren, Veröffentlichen

| Bereich | Stand | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- |
| **Windows-Bau (CI)** | letzter grüner Lauf 28.10. (0.4.x); seitdem alle Commits `[skip ci]`; Lauf vom 04.11. rot im Tesseract-Schritt | **Blocker** | `gh run list --workflow windows.yml`, `apps/windows/scripts/add-tesseract.ps1` | S |
| NSIS-Installer | gebaut, still installiert und geprüft auf dem Runner, **unsigniert** (SmartScreen warnt) | teilweise | `tauri.conf.json` `targets: ["nsis"]` | – |
| MSIX für den Microsoft Store | Paket wird gebaut und testsigniert geprüft; `store.json` hat Testwerte (`store_ready: false`); Screenshots, öffentliche Datenschutz-URL, IARC fehlen | teilweise | `apps/windows/msix/README.md`, `msix/store.json` | S (Werte) + Inhaber |
| Updates | Store-MSIX: automatisch. NSIS: **keine Update-Funktion** (kein Updater-Plugin) | fehlt (nur bei Direkt-Download) | `src-tauri/Cargo.toml` | M |
| Code-Signing | kein Zertifikat | fehlt (nur bei Direkt-Download) | README „Sicherheit“ | Inhaber |
| WebView2 | ab Windows 10 21H2 da; NSIS bringt Installer mit, MSIX nicht | teilweise | `msix/README.md` „Offen“ | S |
| Größe | Chromium (Playwright, für den Abgleich nötig) ≈ 150 MB | so | README „Offen“ | – |
| Prüfung auf echtem Windows | das Fenster selbst startet der Runner nie; 0.5.0 nie von Hand getestet | fehlt | `msix/README.md` | S–M |
| Prüfdaten | `app-paths.json` nennt frühere Semester noch „nur auf dem Gerät“ | Kleinigkeit | `fixtures/local-backend/app-paths.json` | S |

## Was für einen Windows-Start fehlt

### Muss (ohne das kein Start)

1. **Windows-Bau wieder grün:** Tesseract-Schritt reparieren (`add-tesseract.ps1`, Installationsziel), danach 0.5.0 bauen.
   **S**
2. **Einmal auf echtem Windows durchspielen:** Installieren, Hochschul-Anmeldung, Abgleich, PDF öffnen und schreiben,
   Karteikarten, Wochentest mit ChatGPT, Konto verbinden, Community, Geräte-Abgleich mit dem iPad. **S–M**
3. **KI für normale Nutzer:** Entweder die StudiNow-KI (Pro AI, Credits) am PC über das verbundene Konto weiterleiten
   (wie Community), oder klar sagen „KI nur mit eigenem ChatGPT“. Die Claude-Kommandozeile als Standard ist für
   Endnutzer unbrauchbar. **L** (Weiterleitung von `/api/ai/*` mit Kontext-Texten, Credits-Anzeige, Fehlertexte)
4. **Veröffentlichungsweg festlegen und fertig machen:** Store (Partner-Center-Werte, Screenshots, Datenschutz-URL) oder
   Direkt-Download (Zertifikat + Update-Funktion). **S** (Store) bzw. **M** (Direkt)
5. **Konto-Verbindung ohne Tipparbeit:** Dienstadresse fest eintragen (`https://app.studinow.app`), Link „Konto anlegen“
   und „Passwort vergessen“ ins Web. **S**
6. **Tarif-Frage für Windows entscheiden und umsetzen** (siehe Entscheidungen): sonst bekommt jeder Windows-Nutzer Plus
   gratis. **S** (bleibt frei) bis **M** (Tarif über Konto + Stripe)

### Sollte (iPad-Gleichstand bei sichtbaren Funktionen)

7. **Angemeldet bleiben:** stille Erneuerung über das WebView2-Fenster, Benutzername vorausfüllen,
   `IsPasswordAutosaveEnabled`. **M**
8. **Studienverlauf:** Seite im Web, Katalogsuche anstoßen, Grundstock und Register ins Windows-Paket. **L**
9. **Nachrichten aus Stud.IP:** Python-Abruf + Seite. **M**
10. **KI-Start** und KI-Hilfe mit drei Reitern und Markdown. **M**
11. **Wochentest-Optionen** im Web-Dialog (Python kann es schon). **S**
12. **Weitermachen / Zuletzt benutzt / Begrüßung mit Namen.** **M**
13. **Karteikarten teilen am PC** (Share-Route weiterleiten, Übernehmen in die PC-Datenbank). **M**
14. **Fristen-Erkennung und Windows-Mitteilungen** (Tauri-Notification). **M**

### Kann später

15. Erklärungsspeicher und Dokument-Index im Web (erst wenn der Dienst die KI hat). **M–L**
16. Videos & Links (Opencast). **M**
17. Vorlesung aufnehmen mit Mitschrift (Windows-Spracherkennung oder lokales Modell). **L**
18. Audio-Transkript. **L**
19. Formerkennung nach Halten, „Als Karteikarte“ aus markiertem Text. **S–M**
20. Alte Dateifassungen bei Notizen (S7). **M**
21. Stundenplan-Rückfragen und Ausfälle, Klausuren aus Dokumenten erkennen. **M**
22. Einladungen im Web/Windows (nach der Belohnungs-Entscheidung). **M**
23. Abgleich im Hintergrund (Autostart, Infobereich). **M**
24. Fertige Wochenfragen am PC (Weiterleitung an den Dienst). **M**

## Offene Entscheidungen des Inhabers

| # | Frage | Optionen | Folgen |
| --- | --- | --- | --- |
| 1 | **Kostet Windows etwas?** | a) PC bleibt frei (heute so), Geld nur über Pro AI im Konto · b) Tarif kommt aus dem verbundenen Konto (Plus/Pro AI wie auf dem iPad) | a) kein Bau nötig, aber Plus-Funktionen am PC gratis. b) Sperren in der Web-Oberfläche am PC, Konto wird Pflicht für Plus |
| 2 | **Wie bezahlt man unter Windows?** | Stripe im Web (Konto) · Kauf im Microsoft Store | Stripe ist gebaut, braucht Schlüssel und Preise im Stripe-Konto. Store-Kauf müsste neu gebaut werden (Windows.Services.Store). Laut Microsoft-Richtlinie dürfen Nicht-Spiele-Apps seit 2021 eigene Zahlungswege nutzen – vor der Einreichung prüfen |
| 3 | **Store oder Direkt-Download?** | Microsoft Store (MSIX) · eigener Download (NSIS) · beides | Store: signiert und aktualisiert selbst, braucht Partner-Center-Konto. Direkt: Code-Signing-Zertifikat (jährliche Kosten), feste HTTPS-Adresse, Update-Funktion bauen |
| 4 | **Code-Signing-Zertifikat** | kaufen (OV/EV) · Cloud-Signierdienst · keins (nur Store) | ohne Zertifikat warnt SmartScreen bei jedem Direkt-Download |
| 5 | **KI am PC** | StudiNow-KI über das Konto weiterleiten · nur eigenes ChatGPT · beides wie auf dem iPad | bestimmt Aufwand Punkt 3 und ob Credits am PC gelten |
| 6 | **CloudKit-Inhalte für Windows** | Dienst spiegelt Erklärungsspeicher, Dokument-Index, Wochenstapel, Katalog-Bibliothek · bleibt iPad-only | ohne Spiegel sehen Windows-Nutzer diese geteilten Inhalte nie |
| 7 | **Einladungs-Belohnung außerhalb von Apple** | Stripe-Gutscheine · keine Belohnung für Windows | heute nur Apple-Angebotscodes |
| 8 | **Notizen-Abgleich iPad ↔ PC erst ab Pro AI** | so lassen · ab Plus | entschieden am 04.11. (Pro AI); für Windows-Nutzer mit iPad wichtig zu kommunizieren |

## Hinweise

- Alle Belege stammen aus `b580e68` (jetzt `origin/develop`) bzw. dem Sicherungszweig. Der Windows-Lauf wurde mit
  `gh run view` gelesen, sonst kein Netz.
- Nichts davon wurde auf echtem Windows geprüft.
- Der Dienst (`app.studinow.app`) muss laufen, damit Konto, Community und Geräte-Abgleich unter Windows überhaupt
  funktionieren (`docs/START-DIENST-CHECKLISTE.md`).
