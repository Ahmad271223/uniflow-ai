# Abgleich: Prüfkatalog einer anderen KI gegen den echten Stand (28.10.2026)

Der Inhaber hat einen langen Verlauf mit einer anderen KI eingefügt: 535 nummerierte Prüfpunkte, 18 „Master-Prompts“,
Ziele wie „Launch am 2. November“ und „30.000 Studierende gleichzeitig online“. Dieses Dokument ordnet den Verlauf:
Was davon stimmt, was falsch oder überholt ist, was der Inhaber entscheiden muss und was PC- und Mac-Sitzung bauen.

Geprüft auf `develop` (a7827c6) durch Lesen des Codes, zwei unabhängige Durchgänge (Apple; PC, Windows, Dienst) und
eigene Stichproben. Nichts davon ist auf echten Geräten oder unter Last gemessen.

## 1. Wichtigste Einordnung

- **Die andere KI hat fast nur `main` gelesen.** `main` steht auf dem 24.10.2026 (1291a2f) und liegt 323 Commits hinter
  `develop`. Auf `main` gibt es weder `accounts.py`, `community.py`, `plans.py`, `billing*`, `jobs.py`, `vault.py` noch
  `deploy/`. Viele ihrer „fehlt“-Befunde sind deshalb überholt.
- **Ihre drei Entwurfs-PRs setzen auf `main` auf**, nicht auf `develop`:
  - #1 `feature/community-foundation-20261028`: 261 Zeilen, ein zweites Community-Modell (eigene Tabelle
    `community_users` ohne Bezug zu `accounts.db`, keine Routen). Es steht neben `app/community.py` und dem
    CloudKit-Weg der iPad-App. Nicht mergen, sonst gibt es drei Community-Modelle.
  - #2 und #3: reine Architekturtexte und ein Entwurf `sync-operation-v1.schema.json`. Die brauchbaren Ideen sind
    unten in die Aufgaben übernommen (Abschnitt 5 und 6). Der Entwurf widerspricht teils dem bestehenden Vertrag G2
    (`docs/VERTRAEGE-KONTO-SYNC.md`), der schon in Python läuft und Fixtures hat.
  - Empfehlung: #2 und #3 schließen, #1 offen lassen, bis die Community-Entscheidung (Abschnitt 2) gefallen ist.
- **Falsch behauptet:**
  - „Basic 0,99 € / KI 3,99 €“: steht in keinem Zweig. Gültig sind vier Tarife in `app/plans.py`: Free 0 €,
    Plus 1,99 €, Pro Connect 2,99 €, Pro AI 3,99 €.
  - „Windows-Desktop-App geplant, nicht begonnen“: steht nur auf `main`. Auf `develop` ist die Windows-App bei 0.4.6
    mit Installer und MSIX.
  - „iPad meldet sich mit Server-Adresse und PIN an“, „`dirtyPages.removeAll()`-Race“, „Dateien unter
    `UniFlow/<fileId>/` ohne Konto“, „Strich-IDs per `UUID()`“: auf `develop` behoben oder durch neue Dateien ersetzt
    (Abschnitt 3).
- **Nicht realistisch, ehrlich gesagt:**
  - Ein öffentlicher Start am 2.11.2026 mit allen Funktionen auf Windows, iPad und iPhone. Es fehlen Apple-Team,
    Partner Center, Server, Domain, Mail, iPhone-Build, Abgleich zwischen Geräten und mehr (Abschnitt 4).
  - 30.000 gleichzeitig aktive Nutzer auf der heutigen Architektur: ein Prozess, SQLite je Konto, ein VPS, Chromium je
    Abgleich auf dem Server. Gemessen sind 20–30 Anfragen/s bei 50 gleichzeitigen. Dafür braucht es eine andere
    Architektur und echte Lasttests (Abschnitt 2, Punkt 5).

## 2. Entscheidungen, die nur der Inhaber treffen kann

| # | Frage | Heute | Folge der Entscheidung |
|---|---|---|---|
| 1 | Preise | vier Tarife (Free, Plus 1,99 €, Pro Connect 2,99 €, Pro AI 3,99 €); V1 verkauft Free und Plus | Bleibt es dabei, sind die Angaben der anderen KI zu ignorieren |
| 2 | Starttermin und Umfang V1 | iPad-App V1 ohne Dienst-Konto; Windows nur Einzelplatz | Was am Starttag geht, bestimmt die Reihenfolge der Aufgaben |
| 3 | iPhone in V1? | nur iPad (`project.yml:33`, `TARGETED_DEVICE_FAMILY: "2"`) | iPhone heißt eigene Layouts für Editor, Bibliothek, Kalender |
| 4 | Community: CloudKit (iPad, heute gebaut) oder Server (`app/community.py`)? | zwei Wege, dazu PR #1 als dritter | Nur ein Weg erlaubt dieselbe Community auf Windows und iPad. Für Windows braucht es den Server-Weg |
| 5 | Lastziel | gemessen 20–30 Anfragen/s; `BETRIEB.md` nennt „bis etwa 1.000 Nutzer“ für 2 vCPU/4 GB | 30.000 gleichzeitig verlangt PostgreSQL, mehrere API-Prozesse, Objektspeicher, Queue-Worker und Lasttests in einer Testumgebung (kostet Geld) |
| 6 | Hochschul-PDFs auf dem Server speichern? | nein: Dienst streamt, speichert nur Fingerabdruck und Seitentext | Speichern spart Downloads je Gerät, braucht aber Rechteklärung mit den Hochschulen (Urheberrecht) und Objektspeicher |
| 7 | Word/DOCX: nur ansehen oder bearbeiten? | iPad: ansehen über QuickLook; Web: kein Import | Bearbeiten ist ein eigenes großes Projekt |
| 8 | Drei Entwurfs-PRs der anderen KI | offen | Empfehlung in Abschnitt 1 |

## 3. Stand je Bereich (develop, 28.10.2026)

Zeichen: ✅ vorhanden · 🟡 teilweise · ❌ fehlt. Belege mit Datei und Zeile stehen in Abschnitt 4 bis 6.

| Bereich | Web/Windows | iPad | Dienst |
|---|---|---|---|
| Konto anlegen, anmelden, Passwort zurücksetzen | ✅ (im Dienst) | 🟡 Sign in with Apple, kein Dienst-Konto | ✅ |
| E-Mail bestätigen | ❌ | – | ❌ |
| Geräte ansehen, einzeln abmelden | ✅ 28.10. | ❌ | ✅ 28.10. |
| Konto löschen, Daten exportieren | 🟡 / ❌ | 🟡 „Daten dieser Hochschule löschen“ | 🟡 fehlerhaft / ❌ |
| Daten getrennt je Konto | ✅ (Einzelplatz; im Dienst eigene SQLite je Konto) | ✅ Container je Apple-ID und Hochschule | ✅ |
| Abgleich zwischen Geräten (G2) | ✅ Windows 28.10. (`app/sync_client.py`) | ❌ fehlt in Swift | ✅ |
| Stud.IP-Abgleich, Stundenplan 1:1, nur aktuelles Semester | ✅ | ✅ | ✅ |
| Editor: Stift, Marker, Radierer, Lasso, Lineal, Undo | ✅ | ✅ (System-Werkzeuge) | – |
| Editor: Formen, Textfelder, Bilder erstellen | ✅ | 🟡 nur anzeigen | – |
| Editor: Seiten einfügen, löschen, drehen | ✅ | ✅ | – |
| Editor: Seiten verschieben | ✅ | ❌ | – |
| Editor: eingefügte Bild-/PDF-Seiten anzeigen | ✅ | 🟡 Platzhalter | – |
| PDF-Text markieren, unterstreichen, durchstreichen | ✅ 28.10. | ❌ (zeigt sie als Formen) | – |
| Verankerte Kommentare wie in Word | ✅ an Lösungen (Community) 28.10.; eigene Notizen: Haftnotiz | ❌ | ✅ |
| Handschrift durchsuchen | ❌ | ❌ | – |
| PDF-Export mit Notizen | ✅ | ✅ | – |
| Geteilte Ansicht, Tabs | ✅ | ✅ (ab Plus) | – |
| Word/DOCX | ✅ ansehen 28.10. (`app/docx_view.py`) | 🟡 ansehen | ✅ ansehen |
| Lernkalender, Planung, Nachholen | ✅ | ✅ | ✅ |
| KI: Tutor, Tests, Lernpläne | ✅ lokal (Claude/ChatGPT) | ❌ in Release | 🟡 Tests über Bibliothek, Generieren 501 |
| KI: Quellen- und Seitenangaben | ❌ | ❌ | ❌ |
| Community: eigene Lösungen teilen, melden, sperren | ✅ 28.10. (Editor-Leiste) | ✅ (CloudKit, Umstellung auf den Dienst offen) | ✅ mit Likes, Kommentaren |
| Community: Feed, Fragen, Kommentare, Antworten, Profile, Benachrichtigungen, Lesezeichen | ❌ | ❌ | ❌ |
| Abos: Rechte serverseitig, Kontingente | ✅ | ✅ Free/Plus | ✅ |
| Abos: Kauf auf dem Server prüfen | – | ❌ abgeschaltet | ✅ Endpunkt da |
| Push, Universal Links | ❌ | ❌ (nur lokale Mitteilungen, `uniflow://`) | ❌ |
| Barrierefreiheit | 🟡 | 🟡 kein Dynamic Type, wenig VoiceOver | – |
| Installer, Updates, Signatur | 🟡 NSIS, MSIX; kein Auto-Update, keine Signatur | 🟡 Team fehlt | – |
| CI | ✅ Windows grün | ❌ rot seit 26.10. | ✅ Python grün |

## 4. Bestätigte Fehler und Lücken auf der PC-/Dienstseite (für die PC-Sitzung)

Nach Schwere. „Bestätigt“ heißt: im Code nachgelesen, nicht durch einen Testlauf.

| # | Schwere | Befund | Beleg | Lösung |
|---|---|---|---|---|
| P1 | P0 ✅ behoben 28.10. | **Endgültiges Löschen scheitert**, sobald das Konto Zugangsdaten oder Abgleich-Aufträge hatte: `purge_deleted` löscht `users`, aber `vault` und `sync_jobs` verweisen per Fremdschlüssel darauf (`PRAGMA foreign_keys=ON`). Tresor, Aufträge und Community-Pakete werden nie gelöscht | `app/accounts.py:460-472`, `app/vault.py:34`, `app/jobs.py:27`, `app/accounts.py:126` | abhängige Zeilen zuerst löschen, Community-Pakete des Autors entfernen, Test mit Tresor und Jobs |
| P2 | P0 ✅ behoben 28.10. | **Abruf überspringt Zeilen:** `LIMIT 2000` je Tabelle, der Cursor ist das Maximum über alle Tabellen, kein `has_more` | `app/sync.py:100-115` | Cursor je Tabelle oder gemeinsamer Zeitpunkt = Minimum der abgeschnittenen Tabellen, `has_more` |
| P3 | P1 ✅ behoben 28.10. | **Wiederholtes Senden legt neue Zeilen doppelt an** (keine Operations-ID für neue Zeilen) | `app/sync.py:175-190` | `client_op_id` je neuer Zeile speichern und bei Wiederholung dieselbe ID liefern (Idee aus PR #2/#3) |
| P4 | P1 ✅ behoben 28.10. | Keine E-Mail-Bestätigung | `app/accounts.py:44`, `app/mail.py:180` | Bestätigungslink, Grenzen bis zur Bestätigung |
| P5 | P1 ✅ behoben 28.10. | Kein Datenexport (DSGVO Art. 20) | keine Route | `GET /api/account/export` als ZIP |
| P6 | P1 ✅ behoben 28.10. (409 bleibt, siehe G1) | Keine Grenzen für Registrierung und Passwort-Reset; `409 email_taken` verrät, ob ein Konto existiert | `app/accounts.py:217-218, 236-246` | Grenzen je IP und E-Mail, neutrale Antwort |
| P7 | P1 ✅ behoben 28.10. (Windows: `app/sync_client.py`) | Web und Windows gleichen nicht mit dem Konto ab; die Windows-App ist Einzelplatz | `docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md:45` | G2-Client im Web, Anmeldung mit UniFlow-Konto in der Windows-App |
| P8 | P1 ✅ behoben 28.10. (`db.schema_once`, „zuletzt gesehen“ je Minute) | Last je Anfrage: neue Verbindung, `executescript(SCHEMA)` und ein UPDATE auf `accounts.db` | `app/accounts.py:119-133, 262` | Schema einmal beim Start, „zuletzt gesehen“ höchstens minütlich |
| P9 | P1 | Keine allgemeine Rate-Limit-Middleware; keine Drosselung gegenüber den Hochschulen über alle Konten | `app/studip_sync.py:583, 669`, `app/filestream.py` | globale Grenzen je Konto und je Hochschule |
| P10 | P2 ✅ behoben 28.10. | Tresor-Zwischenspeicher veraltet, wenn Jobs in einem eigenen Prozess laufen | `app/vault.py:127-143`, `app/jobs.py:10` | Zwischenspeicher mit Änderungszeit prüfen |
| P11 | P2 ✅ behoben 28.10. (Geheimnis `LERNAPP_AGENT_TOKEN`) | Lokales Backend der Windows-App: GET-Anfragen von 127.0.0.1 sind ohne Prüfung frei; eine fremde Seite in einem App-Fenster könnte bei bekanntem Port z. B. `/api/desktop/commands` abholen | `app/server.py:173-175, 257-271`, `app/desktop_windows.py:63-74` | Token des Fenster-Agenten für `/api/desktop/*` |
| P12 | P2 | Community: keine Beiträge, Kommentare, Gruppen, Benachrichtigungen, kein seitenweises Laden, keine Spam-Grenzen | `app/community.py`, `app/plans.py:50` | nach Entscheidung 4 |
| P13 | P2 | KI: keine Warteschlange, keine Quellen- und Seitenangaben; im Dienst `tests/generate`, `plan/generate` 501 | `app/ai_backend.py:311-338`, `app/server.py:60-66` | Warteschlange, Zitate mit Seite |
| P14 | P2 🟡 28.10.: Markieren und Word-Ansicht gebaut, Handschriftsuche offen | Editor: kein Markieren von PDF-Text, keine Handschriftsuche, kein DOCX | `app/static/editor.js:209, 361, 930`, `app/server.py:755` | Textlayer-Markierungen ins gemeinsame Format |
| P15 | P3 | Windows ohne Code-Signing und Auto-Update | `apps/windows/README.md:136` | über Microsoft Store gelöst; außerhalb Zertifikat nötig |
| P16 | P3 | Betrieb: Backup außer Haus nur auskommentiert, Monitoring nur Healthcheck, Rechtstexte mit Platzhaltern | `deploy/backup.sh`, `docs/release/BETRIEB.md:208-230` | beim Einrichten des Servers |
| P17 | P3 | Offene Punkte der Mac-Sitzung vom 27./28.10. (`pending_groups`, Herkunft im Termin-Fenster, `existing_id` in der Vorschau, `PUT /api/terms` prüfen, 500er-Texte, Umbenennung „Studora“) | `docs/STAND-MAC-SITZUNG.md` | nächste PC-Runde |

## 5. Was von den 535 Prüfpunkten bleibt

Die Punkte der anderen KI sind ein allgemeiner Wunschkatalog, keine Befunde. Zusammengefasst nach Themen, mit dem,
was davon wirklich offen ist:

| Thema (Punkte der anderen KI) | Schon erledigt auf develop | Wirklich offen |
|---|---|---|
| Konten, Sitzungen, Geräte (1–60, 506–511) | Registrierung, Login, Reset, scrypt, Sitzungen 30 Tage, Apple/Google, Trennung je Konto | E-Mail-Bestätigung, Datenexport, Geräte einzeln abmelden, Löschen reparieren (P1, P4–P6) |
| Synchronisierung, Offline, Konflikte (175–177, 313–315, 376–380, 512–517, 524–531) | G2 mit Versionen, Tombstones, Feld-Regel; iPad: Journal, `localRev`/`acked`, stabile Strich-IDs | Cursor (P2), Idempotenz (P3), G2 in Web/Windows und Swift, Live-Hinweis (WebSocket/SSE), Strich-genaue Notiz-Ops statt ganzer Dokumente |
| Editor Windows/Apple (316–365, 426–465) | Werkzeuge, Seiten, Vorlagen, Export, geteilte Ansicht, Tabs | Textmarkierung (beide), Formen/Text/Bilder erstellen (iPad), Seiten verschieben (iPad), Bild-/PDF-Seiten anzeigen (iPad), Kommentare verankern, Handschriftsuche, DOCX |
| Community (178–183, 298–303, 336–345, 366–385) | Lösungen teilen nur mit eigenen Notizen, Vorschau ohne Original (iPad), melden, sperren, Moderation | Feed, Fragen, Kommentare, Antworten, Profile, Benachrichtigungen, Lesezeichen, Gruppen auf dem Server, seitenweises Laden, Spam-Grenzen |
| Stud.IP (148–153, 310–312, 386–393) | Sitzung vom Gerät, Kalender 1:1, Semesterregel, Downloads fortsetzbar, HTML statt PDF erkannt | Drosselung je Hochschule (P9) |
| Kalender (262–267, 394–401) | Tag/Woche/Monat, Planung, Nachholen, Klausuren, Drag & drop | Abgleich der Pläne zwischen Geräten (hängt an G2) |
| KI (184–189, 244–249, 268–273, 402–409) | Budget gesamt und je Konto, Kontingente, Tests MC/Kurz/Rechnung | Warteschlange, Quellen mit Seite, KI auf dem iPad über den Dienst |
| Abos (410–417) | Tarife, Rechte serverseitig, Apple-Prüfendpunkt | Prüfung vom iPad aus einschalten, Pro-Tarife verkaufen |
| Skalierung, Betrieb (162–171, 190–195, 226–243) | Backups täglich, Löschfristen, Healthcheck | Entscheidung 5; Backup außer Haus, Monitoring, Lasttests |
| Lieferkette, CI, Release (286–297) | Windows-, Python-, Android-Workflows grün | Apple-CI rot, SBOM/Abhängigkeits-Scan, Signierung |
| Barrierefreiheit (274–279) | Linkshänder-Seite in der geteilten Ansicht (iPad) | Dynamic Type, VoiceOver, reduzierte Bewegung, Tastatur |
| Push, Deep Links (154–157, 421–422) | lokale Mitteilungen, `uniflow://` | APNs, Universal Links, Windows-Mitteilungen |

## 6. Vollständige Übergabe an die Mac-Sitzung

Alles, was auf dem iPad (und später iPhone) zu tun ist. Reihenfolge nach Bedeutung für den Start. Belege aus der
Prüfung vom 28.10. in Klammern.

**A. Sofort (Grundlage)**
1. **Apple-CI wieder grün:** `XCTExpectFailure` gibt es unter Linux nicht (`SQLiteStoreTests.swift:117`,
   `AuditRunde1213Tests.swift:418`). Unter `#if canImport(ObjectiveC)` setzen oder anders lösen. Dadurch läuft auch der
   iOS-Job wieder (`needs: core-linux`).
2. **Nachzüge vom 28.10.:** `docs/UEBERGABE-APPLE-2026-10-28.md`, Antworten und Entscheidungen am Ende von
   `docs/STAND-MAC-SITZUNG.md` (Abruftag, zurückgesetzter Ausfall als `attend`, Learnweb nur aktive Kurse,
   Sync- und Bibliotheks-Fixture repariert).
3. **Release-Signierung vorbereiten**, sobald das Team da ist: `Config/Team.xcconfig`, Sign in with Apple, CloudKit
   (`project.yml:42-51`). Das Team-Konto beschafft der Inhaber.

**B. Konto und Abgleich (damit „ein Konto auf allen Geräten“ geht)**
4. **Anmeldung am UniFlow-Konto (G1)** zusätzlich zu Sign in with Apple, nach
   `packages/shared-contracts/fixtures/account/contract.json`. Token im Schlüsselbund. Kontowechsel trennt Container
   wie heute.
5. **G2-Client in Swift:** Schema-Spalten `sync_version`, `sync_updated_at`, `sync_device`, `sync_tombstones`
   (`Migrations.swift:12-15`), Push und Pull nach `fixtures/sync/cases.json`, `canSyncAnnotations` freischalten
   (`Plans.swift:245`). Bitte die PC-Fixes P2 (Cursor) und P3 (Operations-ID für neue Zeilen) abwarten oder gleich mit
   einplanen; die PC-Sitzung erweitert dafür den Vertrag und die Fixture.
6. **Notizen geräteübergreifend:** heute ein ganzes Annotationsdokument je Datei mit 409 und Zusammenführung im Client
   (`app/sync.py:244-264`, `merge.js`). Das iPad hat dafür schon `localRev`/`acked` und stabile Strich-IDs. Für
   gleichzeitiges Arbeiten auf Windows und iPad an derselben Seite ist die Zusammenführung je Objekt Pflicht: neue
   Striche beider Seiten bleiben, Löschungen als Tombstone. Vorschlag aus PR #2/#3 (Operationen mit `operation_id`,
   genaue Bestätigung) ist mit dem Journal des iPads vereinbar; Vertrag bitte mit der PC-Sitzung zusammen festlegen.
7. **Kaufprüfung beim Server einschalten** (`BillingServiceLink.swift:22`, `isEnabled = false`), danach Pro Connect
   und Pro AI verkaufbar machen (`Plans.swift:100`). Endpunkte stehen in `app/billing_api.py:70-100`.

**C. Editor (gleiche Funktionen wie Windows)**
8. **PDF-Text markieren, unterstreichen, durchstreichen** (`PDFEditorController.swift:314`, heute keine Textauswahl im
   Stiftmodus). Format gemeinsam mit der PC-Seite festlegen (Textanker plus Geometrie), damit Windows es zeigt.
9. **Formen, Textfelder, Bilder erstellen und bearbeiten** (heute nur anzeigen: `PageObjects.swift:67-80`,
   `DocumentStore.swift:635-651`, `DocumentView.swift:275`).
10. **Eingefügte Bild- und PDF-Seiten wirklich anzeigen** statt Platzhalter (`PDFEditorController.swift:533`,
    `DisplayLayout.swift:67-75`).
11. **Seiten verschieben** (fehlt; im Web vorhanden, `pageOrder` im gemeinsamen Format).
12. **Verankerte Kommentare** an Text oder Strich (Marker, Seitenleiste, Antworten, erledigt). Format zusammen mit der
    PC-Seite; heute gibt es nur die Haftnotiz im Web.
13. **Handschrift durchsuchen** (optional, Erkennung nur als Zusatz, Striche bleiben unverändert).
14. **DOCX:** nach Entscheidung 7. Mindestens Import aus Dateien-App zum Ansehen (heute nur PDF/Bild,
    `LibraryDialogs.swift:80`).

**D. Community (nach Entscheidung 4)**
15. Bleibt es bei CloudKit: Kommentare und Antworten zu Lösungen, Fragen je Modul (`CommunityPage.swift:19` „geplant“),
    Profile, Lesezeichen, Benachrichtigungen. Muss die Community auch auf Windows gehen, auf den Server-Weg
    (`app/community.py`) umstellen; die PC-Sitzung baut dann Beiträge, Kommentare, Gruppen und Benachrichtigungen dort.
16. Vorschau vor dem Veröffentlichen ist auf dem iPad da (`DocumentView.swift:625`); bitte beibehalten, die
    PC-Seite übernimmt sie.

**E. KI auf dem iPad**
17. KI-Tests und Tutor in Release über den Dienst (Pro AI), heute `needsService` (`Plans.swift:245-249`,
    `AppShell.swift:155-166`). Quellen mit Seitenangabe gemeinsam mit der PC-Seite.

**F. Plattform**
18. **iPhone** nach Entscheidung 3 (`project.yml:33`): kompakte Layouts für Bibliothek, Editor (Touch-Werkzeuge),
    Kalender, Community.
19. **Push (APNs) und Universal Links** (`aps-environment`, `associated-domains` fehlen). Push-Token beim Abmelden
    und Kontowechsel löschen.
20. **Barrierefreiheit:** Dynamic Type über `UIFontMetrics` in `ufFont` (`UFTheme.swift:91-106`), VoiceOver-Labels für
    alle Bedienelemente (heute 36), reduzierte Bewegung respektieren, Linkshänder-Modus auch für die Werkzeugleiste.

**G. Abnahme, die nur am echten Gerät geht** (Inhaber mit der Mac-Sitzung, `docs/OFFEN-V1.md:66-90`)
21. Apple Pencil: Latenz, Druck, Handballen, Doppeltipp, Zoom und Drehen ohne versetzte Striche, Split View und Stage
    Manager, große PDFs (500 Seiten) bei Speicherwarnung, App in den Hintergrund während des Schreibens.
22. Echte Hochschul-Anmeldung LUH und Hildesheim, KW 47 mit 21 Terminen wie Stud.IP, Offline-Betrieb im Flugmodus.
23. App-Store-Einreichung: Texte (`docs/release/APP-STORE.md` ist Entwurf), Datenschutzangaben, Prüfhinweis mit
    Demo-Inhalten, Testkonto.

## 7. Aufgaben für die PC-Sitzung (Reihenfolge)

1. ✅ P1 Konto endgültig löschen repariert (`tests/test_accounts.py`, zwei neue Tests).
2. ✅ P2 und P3: seitenweiser Abruf mit `has_more`, `op_id` je Push-Eintrag; Vertrag G2 und Fixture erweitert,
   Mac-Sitzung informiert (`tests/test_sync.py`, vier neue Tests).
3. ✅ P4 bis P6: E-Mail-Bestätigung, Datenexport, Grenzen für Registrierung, Reset und Login je IP (NAT im
   Hochschulnetz berücksichtigt); `tests/test_account_limits_export.py`, Vertrag G1 erweitert.
4. ✅ P8, P10, P11 (28.10.): Schema einmal je Prozess, „zuletzt gesehen“ je Minute, Tresor prüft den Stand in der
   Datenbank, Geheimnis für den Fenster-Agenten.
5. ✅ P7 (28.10.): Windows-App mit Studora-Konto, Geräte-Abgleich G2, Community im Editor, Geräte einzeln abmelden.
6. P14 und C8/C12 mit der Mac-Sitzung: gemeinsames Format für Textmarkierungen und verankerte Kommentare.
7. P12/P13 nach den Entscheidungen 4 und 5.
8. P17: offene Bitten der Mac-Sitzung.
