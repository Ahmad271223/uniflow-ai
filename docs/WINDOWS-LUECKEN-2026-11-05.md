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
- ~~**Die größte Lücke ist die KI.**~~ **Erledigt 05.11.2026 (Abschnitt 4):** Am PC gilt jetzt dieselbe Reihenfolge wie auf
  dem iPad: Geteiltes/Gespeichertes (0 Credits) → eigenes ChatGPT → StudiNow-KI mit Credits über das Konto. Die
  Claude-Kommandozeile gibt es nur noch als Entwickler-Schalter (`LERNAPP_AI_CLI=1`).
- **Die neuen iPad-Funktionen vom 03./04.11. fehlen fast alle in Web/Windows:** ~~Studienverlauf~~ (erledigt 05.11.), ~~Nachrichten~~ (erledigt 05.11., mit Antworten), KI-Start,
  Erklärungsspeicher, Dokument-Index, ~~Weitermachen~~ (erledigt 05.11.), Vorlesung aufnehmen mit Mitschrift, Videos & Links,
  ~~Einladungen~~ (erledigt 05.11. ohne Belohnung; Stripe-Gutscheine offen beim Inhaber), ~~Erststart~~ (erledigt 05.11.).
- ~~**Bezahlen gibt es unter Windows nicht.**~~ **Erledigt 05.11.2026:** Entscheidung „anmelden immer muss ohne abo geht
  nichts“: Anmeldung mit dem StudiNow-Konto ist Pflicht, nach der 7-Tage-Probe braucht es Plus oder Pro AI (Stripe im
  Systembrowser, Apple-Abo zählt), ohne Abo nur ansehen und exportieren (`docs/ABO-SYSTEM.md` 3d, Handtest unten).
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
| **Nachrichten** (Stud.IP-Posteingang, Zähler, Suche, Antworten) | Seitenleiste „Nachrichten“, Antworten/Allen antworten | **Erledigt 05.11.2026:** Seite `#/messages` (Liste, Suche, Lesebereich, Zähler am Menüpunkt, „In Stud.IP öffnen“) und **Antworten / Allen antworten** wie auf dem iPad: Kontext live aus dem Posteingang (Namen nur im Fenster), Betreff „RE: …“, „Original zitieren“, Entwurf je Nachricht, „Beantwortet am …“ und eigene Antwort im Leser, Häkchen in der Liste; `POST jsonapi.php/v1/messages` mit der gemerkten Stud.IP-Sitzung, bei 401 einmal still erneuern, nie still wiederholt; Fehler mit „In Stud.IP antworten“ (App-Fenster). Empfänger nimmt der Server selbst aus Stud.IP. Ohne Abo nur lesen | vorhanden | `app/studip_messages.py`, `app/studip_reply.py`, `app/studip_live.py`, `messages.js`, `message-reply.js`, `tests/test_studip_reply.py` | – |
| **Abgeben in Stud.IP** | Teilen → „In Stud.IP abgeben …“ | **Erledigt 05.11.2026:** Export-Menü des Editors → „In Stud.IP abgeben …“ (nicht im Dienst): Kurs (Stud.IP-Kurse, Modul oben, Vorauswahl), nur beschreibbare Ordner, Hausaufgabenordner zuerst und vorausgewählt, geschlossene Abgabeordner als Fußzeile, Name „Nachname_Blatt3.pdf“, „Notizen und Blätter mitschicken“ (dieselbe PDF wie „Exportieren“), Vorschau mit 7-MB-Hinweis, „Jetzt abgeben“ genau einmal (`POST folders/{id}/file-refs`), Lizenz „selbst verfasst“ als bester Versuch, „In Stud.IP öffnen“, Verlauf „Abgegeben am …“. **Echter Test am PC steht aus** (am iPad auch) | vorhanden | `app/studip_submit.py`, `studip-submit.js`, `tests/test_studip_submit.py` | – |
| **Prüfungsanmeldung** (Hilfe, nie selbst anmelden) | Karte, Abschnitt im Studienverlauf, Modulblock, Erinnerungen | **Erledigt 05.11.2026:** `GET /api/exam-registration` mit derselben Antwort wie der Kern (Meldezeitraum, Vorschläge aus dem Studienverlauf mit Grund, Termin und Rücktrittsfrist, „AN“ im Notenspiegel, Info-Seite), Leser für „Info über angemeldete Prüfungen“ im normalen QIS-Abruf (nur lesend, nie Anmeldung/Abmeldung), Karte auf der Übersicht, Abschnitt im Studienverlauf, Block „Prüfung anmelden“ im Moduldetail und auf der Modulseite, Abzeichen in „Nächste Klausuren“, „Im QIS anmelden“ im App-Fenster; Erinnerungen als Hinweis in der App und, wenn die Windows-Erinnerungen an sind, als Windows-Mitteilung. Info-Seite am echten Konto ungesehen | vorhanden | `app/exam_registration_api.py`, `app/qis_registrations.py`, `exam-registration.js`, `tests/test_exam_registration_api.py` | – |
| Schwarzes Brett, Blubber | ja (Blubber aus) | ja (Blubber aus) | vorhanden | `app/studip_bulletin.py`, `bulletin.js` | – |
| Neuigkeiten, „Aus Stud.IP“ (Courseware, Wiki, Forum) | ja | ja | vorhanden | `news.js`, `studip-texts.js` | – |
| Noten (QIS) | ja | ja | vorhanden | `/api/grades`, „Uni & Noten“ | – |
| Geführter Erststart | Willkommen, Hochschule wählen, Anmeldung, Tarif | **Erledigt 05.11.2026:** nach der Konto-Anmeldung einmal je Hochschule Vollbild mit Willkommen („Wie sollen wir dich nennen?“), Hochschule wählen (am PC Wechsel mit Neustart, im Dienst fest am Konto), Anmeldung (PC: Anmeldefenster und Erstabgleich, Dienst: Zugang hinterlegen, „Später anmelden“), Tarif (Probe/Abo); nicht für bestehende Nutzer, nicht ohne Abo, nicht in der Demo | vorhanden | `onboarding.js`, `onboarding-logic.js`, `tests/js/onboarding.test.mjs` | – |

## 2. Studium

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Begrüßung | „Guten Morgen, Lea“ | **Erledigt 05.11.2026:** „Hallo Lea – lass uns gemeinsam lernen.“ wie auf dem iPad; Rufname aus Erststart oder Einstellungen → Zugang & Darstellung, sonst Kontoname, sonst erstes Wort des Anzeigenamens | vorhanden | `greeting.js`, `tests/js/greeting.test.mjs` | – |
| Weitermachen / Zuletzt benutzt | letztes Dokument auf der Seite, KI-Hilfe mit Gespräch, Liste „Zuletzt benutzt“ | **Erledigt 05.11.2026:** `GET /api/recent` in Python (PC und Dienst je Konto), KI-Gespräche je Dokument in der Datenbank (`/api/tutor-conversations`, höchstens 15), Fenster mit offenem Dokument geschlossen → nächster Start auf dessen Seite mit offener KI-Hilfe und Gespräch; Karte „Zuletzt benutzt“ auf der Übersicht | vorhanden | `app/recent.py`, `recent.js`, `recent-logic.js`, `ai-panel.js`, `tests/test_recent.py`, `tests/js/recent.test.mjs` | – |
| Stundenplan | aus dem eigenen Stud.IP-Kalender, Rückfragen bei unklaren Gruppen, Ausfälle | **Erledigt 05.11.2026:** Rückfragen (Kurs nicht im Stud.IP-Kalender: Übernehmen/Weglassen; Kurs mit drei oder mehr Serien: welche besuchst du) und Ausfälle laut Stud.IP auch in Web und Windows, gleiche Endpunkte wie auf dem iPad; Ausfälle im Stundenplan ausgeblendet wie in Stud.IP, mit Knopf „Anzeigen“ (Lernkalender und Übersicht zeigen sie noch) | vorhanden | `app/timetable_questions.py`, `studip-questions.js`, `tests/test_timetable_questions.py` | – |
| Lernkalender, Timer | ja | ja | vorhanden | `views-plan.js`, Editor „Zeitmesser“ | – |
| Module, Lernstand je Modul | ja | ja | vorhanden | `app/mastery.py`, `mastery.js` | – |
| Klausurtermine | aus allen Quellen, Karte, Kalender-Pins, Modulkopf, auch aus Dokumenten erkannt | Karte „Nächste Klausuren“ aus Stud.IP, Ankündigungen, QIS, Fristen; ohne Erkennung in Dokumenten | teilweise | `app/exams.py`, `exams.js`; `Exams.swift:248` „nur auf dem Gerät“ | S–M |
| Fristen aus Dateien erkennen, Erinnerungen | Erkennung + lokale Mitteilungen | **Erledigt 05.11.2026:** Erkennung aus Dokumenten, Dateinamen und Ankündigungen auch am PC/im Dienst (gleiche Fälle wie das iPad, `packages/shared-contracts/fixtures/due-detection/cases.json`), in Kalender, „Nächste Termine“ und Klausurliste mit „Stimmt“/„Stimmt nicht“; Erinnerungen 3 Tage, 1 Tag, morgens 8:00 und 2 Stunden vorher als Windows-Mitteilung (`tauri-plugin-notification`), im Browser über die Mitteilungen des Browsers, sonst als Hinweis in der App – nur solange StudiNow offen ist. Windows-Bau mit dem Plugin noch auf dem Runner prüfen | vorhanden | `app/due_detection.py`, `app/due_store.py`, `app/due_api.py`, `due-reminders.js`, `docs/FRISTEN-ERKENNUNG-2026-11-05.md` | – |
| **Studienverlauf** (Semester-Spalten, Moduldetail, Wahlpflicht, Nachholen, Wahlbereiche, eigene Lage, Gesamtansicht) | Seite + Eintrag in der Seitenleiste + Knopf im Modul | **Erledigt 05.11.2026:** Seite `#/studyplan` (auch `#/studienverlauf`), Eintrag „Studienverlauf“ unter „Meine Module“, Knopf „Im Studienverlauf“; Studiengang aus dem Register, Studienbeginn, Katalogsuche über den Status, Link zum Modulhandbuch; Plätze mit Auswahl, Tauschen, „Nicht belegen“, eigene Einträge, Schwerpunkt, „Plan zurücksetzen“, Verschieben per Ziehen (auch Finger) und Menü, Kasten „Bereiche und Wahl“, Gesamtansicht (1440 px eine Reihe, 390 px untereinander, ohne Rollen); ohne Abo nur lesen. Grundstock und Register im Windows-Paket. Prüfungsanmeldung seit 05.11. auch hier (Abschnitt oben, Zeile „Prüfungsanmeldung“) | vorhanden | `study-plan.js`, `study-plan-logic.js`, `tests/js/study-plan*.test.mjs`, Fotos `~/Studora-Builds/web-studienverlauf/` | – |
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
| Formerkennung nach Halten | Linie, Rechteck, Ellipse, Dreieck, Pfeil | **Erledigt (Paket B, geprüft 05.11.2026):** gleiche Schwellen (0,5 s, 6 pt, 30 pt), Schalter in der Stiftleiste, ein Rückgängig-Schritt; im Browser mit Stift-Zeigerereignissen nachgeprüft | vorhanden | `editor-shapes.js`, `tests/js/editor-shapes.test.mjs` | – |
| „Als Karteikarte“ aus markiertem Text | ja | **Erledigt (Paket B, geprüft 05.11.2026):** Werkzeug „PDF-Text markieren“ → „Als Karteikarte“, Vorderseite aus dem Text, Stapel des Dokuments (bzw. gewählter Stapel), ab Plus (`_require_flashcards`, sonst Meldung) | vorhanden | `editor-card.js`, `tests/js/editor-card.test.mjs` | – |
| **Ansicht fixieren / Zum Abpausen einfrieren** | Menü „Mehr“, ⌘L, Abzeichen „Lösen“; Abpausen ohne Leisten, keine Eingabe, Bildschirm an, Schloss 2 s halten | **Erledigt 05.11.2026:** Menü „Mehr“ → „Bildschirm fixieren“, Strg+L, Abzeichen; fixiert sperren Mausrad, Bildlaufleiste, Pinch, Fingerwischen, Hand, Seitenwechsel und Zoom, Stift schreibt weiter; Abpausen mit Fullscreen API (sonst fest darüber), Sperrfläche auch für den Stift, Screen Wake Lock, Schloss mit Fortschrittsring, Esc, Tastatur/Screenreader; „Kontrast für Abpausen“. Ohne „Helligkeit auf Maximum“ (Browser kann das nicht, wie Mac) | vorhanden | `editor-freeze.js`, `editor-freeze.css`, `tests/js/editor-freeze.test.mjs` | – |
| **Notizen und Blätter mitschicken** | Export, „Abgeben“, Lösung teilen, KI-Hilfe | **Erledigt 05.11.2026 (Export und Lösung teilen):** Schalter „Notizen und Blätter mitschicken“ im Export-Menü und im Dialog „Lösung teilen“; Blätter vom iPad (`sideSheets`) hinter ihrer Folie, leere Seitennotizen weg, „Diese Seite“ mit ihren Notizseiten, Notizseite bringt ihre Folie mit. **Offen:** KI-Hilfe schickt `own_notes` noch nicht (Server kann es, Helfer `typedText` in `side-notes.js`); „Abgeben“ seit 05.11. am PC (nimmt denselben Export); ein Blatt daneben anlegen gibt es im Browser nicht | teilweise | `side-notes.js`, `tests/js/side-notes.test.mjs` | S (KI) |
| Texterkennung (OCR) für Scans | Apple Vision | `pageocr.py` + Tesseract; **Bau scheitert genau hier** | teilweise (Blocker) | Lauf 41929677402: „tesseract.exe fehlt nach der Installation“ in `add-tesseract.ps1:35` | S |
| **Vorlesung aufnehmen** | eigene Aufnahmen mit Live-Mitschrift, Vorschlag aus dem Stundenplan, Suche in Transkripten, KI-Zusammenfassung | nur Audioaufnahme je Dokument im Editor, ohne Mitschrift | teilweise | `editor.js` „Transkription ist in dieser lokalen Version nicht verfügbar“; `/api/recordings/own` nur Gerät | L |

## 4. KI

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| **Woher die KI kommt** | Geteiltes (0 Credits) → eigenes ChatGPT → StudiNow-KI mit Credits über das Konto | **erledigt 05.11.2026:** gleiche Reihenfolge. Der PC baut den Prompt aus seinen Dateien und schickt ihn mit dem Konto-Token an `POST /api/ai/relay`; der Dienst wählt zur Aufgabe (`tutor:<Modus>`, `flashcards`, `week_test`, `weekly`, `grade`) System-Text, Schema, Zweck, Recht, Kontingent und Höchstlänge selbst, Credits und harte Obergrenze gelten zentral. Fehler 402/403/409/429/503 kommen mit Code unverändert in der Oberfläche an. `claude -p` nur noch mit `LERNAPP_AI_CLI=1` (bzw. im Entwicklungsserver ohne Konto-Pflicht). Dateianalyse und Stundenplan-Import aus Bildern bleiben am PC beim eigenen ChatGPT (keine stillen Credits im Hintergrund) | vorhanden | `app/ai_relay.py`, `app/ai.py` (`source`, `for_task`), `tests/test_ai_relay.py` | – |
| **KI-Start** (Gespräch, farbige Aktionen, Hilfe ohne KI, Dokument anhängen) | `#/ki` | **erledigt 05.11.2026** (Paket B + heute): Route `#/ki`, fünf farbige Aktionen, Gespräch mit Markdown, Hilfe ohne KI (0 Credits), Dokument anhängen; jetzt auch das gewählte Modul als Kontext (`module_id`) und der Weg/Credits-Stand in der Statuszeile vor der ersten Antwort | vorhanden | `views-ai.js`, `ai-start-logic.js`, `tests/js/ai-start.test.mjs`, `tests/js/ai-source.test.mjs` | – |
| KI-Hilfe im Editor | drei farbige Reiter (Erklären, Karteikarten, Test), Markdown, Gesprächsverlauf | **erledigt 05.11.2026:** drei farbige Reiter, Markdown, Verlauf je Dokument, Umfang „Ganzes Dokument“ und Schnellknöpfe bleiben; Seitennotizen und Blätter neben der Folie gehen als `own_notes` mit (dann nie aus einem Speicher); Fußzeile mit Weg und Credits; „Tarif ansehen“ bei Credits/Kontingent/Tarif/Abo | vorhanden | `ai-panel.js`, `side-notes.js`, `tests/js/ai-panel.test.mjs` | – |
| **Erklärungsspeicher** („Schon erklärt · 0 Credits“) | CloudKit `PageExplain` | **erledigt 05.11.2026:** eigener Speicher (`explain_local`) → Speicher des Dienstes `/api/explain` (verschlüsselt nach `page-explain.md`, nur wer die Datei hat, kann lesen; „Schon erklärt · sofort da · 0 Credits“) → Zwischenspeicher der StudiNow-KI (gleiche Anfrage, 0 Credits) → live; frische Antworten gehen verschlüsselt an den Dienst. iPad (CloudKit) und Dienst teilen sich weiter nichts | vorhanden | `app/explain_service.py`, `server.py` `ai_tutor` | – |
| Ganzes Dokument erklären | Plan, Kosten, Schritte, gemeinsamer Speicher | **erledigt 05.11.2026:** Plan und Schritte laufen mit dem Seitentext vom PC im Dienst (gemeinsamer Speicher erklärter Teile für alle Konten, Kostenzeile „Kostet etwa N Credits, du hast M“) | vorhanden | `doc_explain_api.py` `_forward` | – |
| Dokument-Index (Einordnung je Seite, Regal-Pfad) | ja | **weiter offen:** Der Dienst hat nur den Auftrag zum Hochladen und `analyze_page` (Stub), keinen gemeinsamen Speicher der Index-Einträge wie CloudKit `DocIndex`. Ohne den gibt es nichts weiterzuleiten; am PC deshalb auch keine Einordnung für freie Fragen | fehlt | `app/doc_index.py`, `docs/DOKUMENT-INDEX-2026-11-04.md` „Dienst (V2)“ | M–L (Dienst zuerst) |
| Credits-Anzeige | ja | **erledigt 05.11.2026:** `GET /api/ai/source` (Weg und Stand), Stand nach jeder Antwort auch in `GET /api/entitlements` (Abo-Zwischenspeicher, ohne die Kulanzzeit zu verlängern) | vorhanden | `ai_relay.py` `_remember_credits` | – |

## 5. Lernen

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Wochentests (automatisch, „Fehlende Wochentests“) | ja | ja, mit eigener KI | vorhanden | `weekly.py`, `views-weekly.js` | – |
| Wochentest-Optionen (Anzahl, Schwierigkeit, Arten inkl. Wahr/Falsch und Lückentext, Thema) | ja | **Erledigt (Paket B, geprüft 05.11.2026):** Dialog „Wochentest erstellen“ mit Lehrwoche, Dauer, 5/10/15/20 Aufgaben, Schwierigkeit, Arten (Multiple Choice, Wahr/Falsch, Lückentext, Kurzantwort, Rechnen), Thema, Hinweis „gemeinsam“/„eigener Test“ | vorhanden | `week-test-dialog.js`, `tests/js/week-test-dialog.test.mjs` | – |
| Gemeinsame Wochentests (Pool) | über Dienst / CloudKit | **erledigt 05.11.2026:** mit Konto derselbe Pool wie im Dienst (`/api/v2/shared-tests`): eigene Variante übernehmen (keine KI), warten, sonst Platz belegen, erzeugen, veröffentlichen; Fehler gibt den Platz frei; ohne Netz eigener Test | vorhanden | `testshare.obtain_via_service` | – |
| Testergebnis mit Ring, „Frag die KI zu Aufgabe n“ | ja | ja, inkl. Lückentext in `QTYPE` und Eingabefeld im Testlauf | vorhanden | `test-result.js`, `views-misc.js` | – |
| Fertige Wochenfragen (Pro AI, aus der Cloud-Sitzung) | zieht nach | **erledigt 05.11.2026 (lesen und starten):** der PC rechnet den Schlüssel der Woche aus seinen Dateien und fragt `/api/library/week-keys/…`; Stand, Sätze, Lösungen, Start als eigener Test in der PC-Datenbank (zählt als Bibliothekstest). **Vorbereiten** nur im Dienst (ein PC schickt nie Material in die gemeinsame Bibliothek) | teilweise | `week_library_api.py` `_pc_*` | – |
| Karteikarten: Stapel, Bearbeiten, Üben, Lesemodus | ja | ja | vorhanden | `flashcards.js`, `flashcard-stacks*.js` | – |
| Wochenstapel holen | geteilt oder neu | am PC immer eigener Stapel (eigene KI, Status `unshared`) | teilweise | `docs/KARTEIKARTEN-STAPEL-2026-11-04.md` Z. 136 | – |
| Stapel teilen / geteilte übernehmen | CloudKit `WeekCardStack`, `CardStackShare` | **erledigt 05.11.2026:** Teilen, Ersetzen, Zurückziehen schicken die Karten vom PC (`POST/PUT/DELETE /api/community/card-stacks`); Übernehmen legt den Stapel in der PC-Datenbank an und zählt im Dienst. Offen: Merker „schon übernommen“ in der Liste kommt vom Dienst-Konto | vorhanden | `community_cards_api.py` `_pc`, `server.py` `_COMMUNITY_LOCAL` | – |

## 6. Gemeinsam (Community)

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Lösungen, Korrekturen, Fragen je Kurs, Kanal nach Lehrwoche | CloudKit oder Dienst | über den Dienst (Weiterleitung) | vorhanden (braucht Konto und laufenden Dienst) | `community-channel.js`, `community-corrections*.js`, `server.py` `community_link` | – |
| StudiNow-Konto am PC | Anmelden, Registrieren | **erledigt 05.11.2026:** Anmeldung beim Start ist Pflicht (Anmeldebildschirm), Dienstadresse fest `https://app.studinow.app`, E-Mail/Passwort oder „Mit Apple/Google anmelden“, „Konto anlegen“, „Passwort vergessen?“ im Systembrowser; Token in der Windows-Anmeldeinformationsverwaltung | vorhanden | `app/account_mode.py`, `app/static/account-gate.js` | – |

**Wie iPad und Windows zusammenhängen:** Ein iPad **ohne** StudiNow-Konto nutzt CloudKit. Ein iPad **mit** Konto derselben
Hochschule schaltet auf `ServiceCommunityService` um (`StudoraAccountLink.swift:134`) und sieht dieselbe Community wie
Windows und Web. Nur über CloudKit laufen weiter: Erklärungsspeicher, Dokument-Index, geteilte Wochenstapel und die
Katalog-Bibliothek. Diese vier sieht Windows nie, solange der Dienst sie nicht spiegelt.

## 7. Konto, Tarife, Kauf, Einladungen

| Bereich | iPad | Windows / Web | Status | Beleg | Aufwand |
| --- | --- | --- | --- | --- | --- |
| Tarife und 7-Tage-Probe | Free / Plus / Pro AI über StoreKit, Probe je Apple-ID | **erledigt 05.11.2026:** Tarif und Probe aus dem StudiNow-Konto (Quelle „account“, 7 Tage Kulanz ohne Netz), Leiste „Probe: noch N Tage“; ohne Abo nur lesen und exportieren (kein Free am PC) | vorhanden | `app/account_mode.py`, `app/access.py`, `docs/ABO-SYSTEM.md` 3d | – |
| Kaufen unter Windows | App Store | **erledigt 05.11.2026:** Stripe-Checkout des Dienstes im Systembrowser, Kundenportal zum Kündigen; mit Apple-Abo kein zweiter Kauf (auch im Dienst gesperrt). Microsoft-Store-Kauf bewusst nicht | vorhanden (Stripe-Schlüssel im Dienst fehlen noch) | `app/account_mode.py`, `app/stripe_billing.py` | – |
| Einladungen (Links, Stufen, Belohnung) | ja (Apple-Angebotscodes) | **Erledigt 05.11.2026 ohne Belohnung:** Seite `#/einladungen` (Einstellungen → Zugang & Darstellung → „Freunde einladen“) mit Zähler, Links, Teilen/Kopieren, „Neuer Einladungslink“ in der Probewoche, QR-Code (Link oder App-Code, inline SVG, kein fremder Dienst); Windows reicht `/api/invites` mit dem StudiNow-Konto an den Dienst weiter. **Offen beim Inhaber:** Belohnung über Stripe-Gutscheine (`docs/EINLADUNGEN.md` Abschnitt 9) – bis dahin zeigt die Seite keine Stufen und nichts zum Einlösen (`WEB_REWARDS = false`) | vorhanden (Belohnung offen) | `invites.js`, `qr.js`, `app/invites_api.py`, `tests/test_invites_pc.py`, `tests/js/qr.test.mjs` | Inhaber |
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

1. ~~**Windows-Bau wieder grün:** Tesseract-Schritt reparieren (`add-tesseract.ps1`, Installationsziel), danach 0.5.0 bauen.
   **S**~~ **erledigt 05.11.2026:** seit c6d259c wieder grün (Läufe 41932061818 bis 41993722721, 0.5.0), Skript danach
   ohne Suche über ganze Laufwerke, Version geprüft, Smoke-Test erweitert, Version 0.6.0 mit Konto/Abo und
   Studienverlauf; Bau und Handtest: `docs/release/WINDOWS-BAU-2026-11-05.md`.
2. **Einmal auf echtem Windows durchspielen:** Installieren, Hochschul-Anmeldung, Abgleich, PDF öffnen und schreiben,
   Karteikarten, Wochentest mit ChatGPT, Konto verbinden, Community, Geräte-Abgleich mit dem iPad. **S–M**
3. ~~**KI für normale Nutzer:**~~ **erledigt 05.11.2026** (Abschnitt 4). Entweder die StudiNow-KI (Pro AI, Credits) am PC über das verbundene Konto weiterleiten
   (wie Community), oder klar sagen „KI nur mit eigenem ChatGPT“. Die Claude-Kommandozeile als Standard ist für
   Endnutzer unbrauchbar. **L** (Weiterleitung von `/api/ai/*` mit Kontext-Texten, Credits-Anzeige, Fehlertexte)
4. **Veröffentlichungsweg festlegen und fertig machen:** Store (Partner-Center-Werte, Screenshots, Datenschutz-URL) oder
   Direkt-Download (Zertifikat + Update-Funktion). **S** (Store) bzw. **M** (Direkt)
5. ~~**Konto-Verbindung ohne Tipparbeit**~~ **erledigt 05.11.2026** (feste Dienstadresse, Konto anlegen und Passwort
   vergessen im Browser).
6. ~~**Tarif-Frage für Windows entscheiden und umsetzen**~~ **erledigt 05.11.2026** (Konto- und Abo-Pflicht, Stripe;
   Handtest unten). Offen beim Inhaber: Stripe-Schlüssel und Preise im Dienst.

### Sollte (iPad-Gleichstand bei sichtbaren Funktionen)

7. **Angemeldet bleiben:** stille Erneuerung über das WebView2-Fenster, Benutzername vorausfüllen,
   `IsPasswordAutosaveEnabled`. **M**
8. ~~**Studienverlauf:** Seite im Web, Katalogsuche anstoßen, Grundstock und Register ins Windows-Paket.~~ **erledigt 05.11.2026**
   (Seite mit Wahlbereichen, Auswahl, Verschieben per Ziehen und Menü, Gesamtansicht; ohne Abo nur lesen; siehe Abschnitt 2).
9. ~~**Nachrichten aus Stud.IP:** Python-Abruf + Seite.~~ **erledigt 05.11.2026** (mit Antworten; dazu Abgeben in Stud.IP und Prüfungsanmeldung)
10. ~~**KI-Start** und KI-Hilfe mit drei Reitern und Markdown.~~ **erledigt 05.11.2026**
11. ~~**Wochentest-Optionen** im Web-Dialog~~ **erledigt** (Paket B, geprüft 05.11.2026).
12. ~~**Weitermachen / Zuletzt benutzt / Begrüßung mit Namen.**~~ **erledigt 05.11.2026** (`app/recent.py`, `recent.js`, `greeting.js`).
13. ~~**Karteikarten teilen am PC**~~ **erledigt 05.11.2026**
14. ~~**Fristen-Erkennung und Windows-Mitteilungen**~~ **erledigt 05.11.2026** (`app/due_*.py`, `due-reminders.js`, `tauri-plugin-notification`; Windows-Bau mit Plugin noch prüfen).

### Kann später

15. ~~Erklärungsspeicher~~ (erledigt 05.11.2026) und Dokument-Index im Web (Dienst braucht zuerst einen Speicher für Index-Einträge). **M–L**
16. Videos & Links (Opencast). **M**
17. Vorlesung aufnehmen mit Mitschrift (Windows-Spracherkennung oder lokales Modell). **L**
18. Audio-Transkript. **L**
19. ~~Formerkennung nach Halten, „Als Karteikarte“ aus markiertem Text. **S–M**~~ **erledigt** (Paket B; dazu 05.11.2026
    Ansicht fixieren/Abpausen und Notizen und Blätter mitschicken, Abschnitt 3).
20. Alte Dateifassungen bei Notizen (S7). **M**
21. Stundenplan-Rückfragen und Ausfälle, Klausuren aus Dokumenten erkennen. **M**
22. Einladungen im Web/Windows (nach der Belohnungs-Entscheidung). **M**
23. Abgleich im Hintergrund (Autostart, Infobereich). **M**
24. ~~Fertige Wochenfragen am PC~~ **erledigt 05.11.2026** (lesen und starten; vorbereiten bleibt im Dienst).

## Offene Entscheidungen des Inhabers

| # | Frage | Optionen | Folgen |
| --- | --- | --- | --- |
| 1 | **Kostet Windows etwas?** – **entschieden 05.11.2026:** Konto und Abo Pflicht (b, strenger: ohne Abo nur lesen) | a) PC bleibt frei (heute so), Geld nur über Pro AI im Konto · b) Tarif kommt aus dem verbundenen Konto (Plus/Pro AI wie auf dem iPad) | a) kein Bau nötig, aber Plus-Funktionen am PC gratis. b) Sperren in der Web-Oberfläche am PC, Konto wird Pflicht für Plus |
| 2 | **Wie bezahlt man unter Windows?** – **gebaut 05.11.2026:** Stripe im Systembrowser; Store-Regeln vor der Einreichung prüfen | Stripe im Web (Konto) · Kauf im Microsoft Store | Stripe ist gebaut, braucht Schlüssel und Preise im Stripe-Konto. Store-Kauf müsste neu gebaut werden (Windows.Services.Store). Laut Microsoft-Richtlinie dürfen Nicht-Spiele-Apps seit 2021 eigene Zahlungswege nutzen – vor der Einreichung prüfen |
| 3 | **Store oder Direkt-Download?** | Microsoft Store (MSIX) · eigener Download (NSIS) · beides | Store: signiert und aktualisiert selbst, braucht Partner-Center-Konto. Direkt: Code-Signing-Zertifikat (jährliche Kosten), feste HTTPS-Adresse, Update-Funktion bauen |
| 4 | **Code-Signing-Zertifikat** | kaufen (OV/EV) · Cloud-Signierdienst · keins (nur Store) | ohne Zertifikat warnt SmartScreen bei jedem Direkt-Download |
| 5 | **KI am PC** – **umgesetzt 05.11.2026:** beides wie auf dem iPad | StudiNow-KI über das Konto weiterleiten · nur eigenes ChatGPT · beides wie auf dem iPad | bestimmt Aufwand Punkt 3 und ob Credits am PC gelten |
| 6 | **CloudKit-Inhalte für Windows** | Dienst spiegelt Erklärungsspeicher, Dokument-Index, Wochenstapel, Katalog-Bibliothek · bleibt iPad-only | ohne Spiegel sehen Windows-Nutzer diese geteilten Inhalte nie |
| 7 | **Einladungs-Belohnung außerhalb von Apple** | Stripe-Gutscheine · keine Belohnung für Windows | heute nur Apple-Angebotscodes |
| 8 | **Notizen-Abgleich iPad ↔ PC erst ab Pro AI** | so lassen · ab Plus | entschieden am 04.11. (Pro AI); für Windows-Nutzer mit iPad wichtig zu kommunizieren |

## Hinweise

- Alle Belege stammen aus `b580e68` (jetzt `origin/develop`) bzw. dem Sicherungszweig. Der Windows-Lauf wurde mit
  `gh run view` gelesen, sonst kein Netz.
- Nichts davon wurde auf echtem Windows geprüft.
- Der Dienst (`app.studinow.app`) muss laufen, damit Konto, Community und Geräte-Abgleich unter Windows überhaupt
  funktionieren (`docs/START-DIENST-CHECKLISTE.md`).

## Handtest Konto- und Abo-Pflicht (05.11.2026, auf einem echten Windows-PC)

Im Repo nur mit Attrappen geprüft (`tests/test_account_mode.py`): kein echtes Windows, keine echte
Anmeldeinformationsverwaltung, kein echter Systembrowser, kein echtes Stripe. Vorbereitung: Dienst läuft unter
`https://app.studinow.app` (oder `LERNAPP_SERVICE_URL` in `%LOCALAPPDATA%\de.uniflow.desktop\.env`), Stripe im
Testmodus eingerichtet (`LERNAPP_STRIPE_SECRET_KEY=sk_test_…`, Preise, Webhook), drei Testkonten: neu (Probe), Probe
beendet (`python -m app.accounts …` bzw. `billing.end_trial`), mit Apple-Abo (aus der iPad-App, Sandbox).

1. **Erster Start ohne Anmeldung:** Installieren, starten → nur der Anmeldebildschirm „Bei StudiNow anmelden“, keine
   Seitenleiste. Link „Meine Daten exportieren“ lädt eine ZIP-Datei.
2. **E-Mail und Passwort:** neues Konto anmelden → App öffnet sich, oben die Leiste „Probe: noch 7 Tage alles wie
   StudiNow Pro AI“; Notizen schreiben, Karteikarten anlegen geht.
3. **Token in der Anmeldeinformationsverwaltung:** Systemsteuerung → Anmeldeinformationsverwaltung →
   Windows-Anmeldeinformationen → Generische Anmeldeinformationen: Eintrag `StudiNow/dienst-sitzung` vorhanden. In
   `%LOCALAPPDATA%\de.uniflow.desktop\data\service-account.json` steht **kein** `token` und nirgends das Passwort.
4. **Neustart:** App schließen und neu starten → ohne erneute Anmeldung angemeldet.
5. **Mit Apple anmelden / Mit Google anmelden:** Abmelden (Abo-Seite → Konto bzw. Einstellungen), dann „Mit Apple
   anmelden“ → Standardbrowser (nicht das App-Fenster) öffnet `app.studinow.app/login?app=windows…`; dort anmelden →
   Browser zeigt „Angemeldet … Du kannst dieses Fenster schließen“, die App wechselt nach wenigen Sekunden selbst.
   Dasselbe mit Google. War der Browser schon angemeldet: Frage „Weiter / Anderes Konto“ erscheint.
6. **Konto anlegen / Passwort vergessen** auf dem Anmeldebildschirm öffnen die passenden Reiter im Browser; nach dem
   Registrieren geht es in der App weiter.
7. **Probe vorbei:** mit dem Konto „Probe beendet“ anmelden → Start auf „Abo & Tarife“ mit „Kein aktives Abo“, Leiste
   „Kein aktives Abo · Nur lesen“. „Meine Daten ansehen“ → Übersicht, Dokumente, Notizen lesbar; Schreiben im Editor
   aus; „Sync“ und Speichern zeigen „Dafür brauchst du ein aktives Abo …“. „Meine Daten exportieren“ lädt die ZIP.
8. **Kaufen:** „Abschließen“ bei Plus → Stripe-Checkout öffnet im Standardbrowser (Testkarte 4242 4242 4242 4242) →
   Seite „Danke! … zu StudiNow zurückkehren“; die App zeigt innerhalb von etwa 5–10 Sekunden Plus, Leiste weg.
9. **Verwalten/Kündigen:** „Abo verwalten“ öffnet das Stripe-Kundenportal im Browser; Kündigen → Abo läuft bis zum
   Periodenende, danach (Stripe-Testuhr oder Webhook) zurück auf „Kein aktives Abo“.
10. **Apple-Abo:** mit dem Apple-Abo-Konto anmelden → Tarif aus der Apple-App aktiv, auf der Abo-Seite „Du hast schon
    ein Abo über Apple – verwalten in den Einstellungen deines iPads/iPhones“, kein „Abschließen“-Knopf.
11. **Offline:** WLAN aus, App neu starten → arbeitet mit dem letzten Stand weiter (Plus bleibt Plus). Optional:
    `LERNAPP_OFFLINE_GRACE_DAYS=0` in die `.env`, Neustart offline → „Abo konnte nicht geprüft werden“, nur lesen;
    WLAN an, „Erneut prüfen“ → wieder frei.
12. **Sitzung widerrufen:** am iPad oder im Web „Andere Geräte abmelden“ → in der App beim nächsten Prüfen (Fenster
    verlassen und zurückkehren) der Anmeldebildschirm.
13. **PC weitergeben:** Einstellungen → „Hochschul-Konto entfernen“ → auch das StudiNow-Konto ist abgemeldet, der
    Eintrag in der Anmeldeinformationsverwaltung ist weg.
14. **Web gegenprüfen:** dasselbe Konto „Probe beendet“ im Browser auf `app.studinow.app` → ebenfalls „Kein aktives
    Abo“, nur lesen, Export geht; in der iPad-App bleibt Free nutzbar.

## Handtest KI am PC (05.11.2026, auf einem echten Windows-PC)

Im Repo nur mit Attrappen geprüft (`tests/test_ai_relay.py`: PC und Dienst im selben Prozess, KI-Attrappe, kein Netz).

Grenze der Weiterleitung: Der PC schickt einen fertigen Prompt, weil nur er die Dateien hat. Der Dienst nimmt ihn nur
zu einer festen Aufgabe an und bestimmt alles, was Geld kostet, selbst (siehe `app/ai_relay.py`). Freie Fragen gab es
ohnehin (Modus „Frage“); die Grenzen sind Credits, Kontingent, Rate-Limit und die harte Obergrenze je Konto.

1. Konto mit Pro AI (oder Probe), ChatGPT **nicht** verbunden: Editor → KI-Hilfe, Fußzeile „Credits: N von 100 übrig“.
   „Erklären“ auf einer Folie → Antwort, Fußzeile „– k Credits (… übrig)“; dieselbe Folie noch einmal → „Schon erklärt ·
   0 Credits“. Kein Fenster „claude“ geht auf.
2. Zweiter PC, anderes Konto, dieselbe Vorlesungsdatei: „Erklären“ auf derselben Folie → „Schon erklärt · sofort da ·
   0 Credits“ (Speicher des Dienstes).
3. Seitennotiz hinter der Folie mit getipptem Text, dann „Erklären“ → Antwort geht auf die Notiz ein, nie „Schon erklärt“.
4. Plus-Konto: KI-Hilfe → Meldung „Diese Funktion gibt es ab StudiNow Pro AI.“ mit „Tarif ansehen“. Credits auf 0
   (Dienst: `LERNAPP_CREDITS_PRO_AI=0`) → „Credits für diesen Monat aufgebraucht – am 1. gibt es neue.“
5. „Erkläre die ganze Vorlesung“ → Kostenzeile mit Credits, Schritte laufen; zweites Konto → alles „schon erklärt“.
6. Wochentest erstellen (Plus): Test kommt ohne Credits, zählt auf „Neue StudiNow-KI-Tests“; zweites Konto mit denselben
   Dateien bekommt „Gemeinsamer Test · Variante …“, ohne neue KI-Anfrage (gleiche Variante vorausgesetzt).
7. Karteikarten-Stapel teilen, am anderen PC übernehmen → Stapel erscheint dort unter Karteikarten.
8. ChatGPT verbinden → Fußzeile „über dein ChatGPT · 0 Credits“, Credits bleiben stehen.
