# Auftrag an die Mac-Sitzung: Windows, Web und iPad/Mac 1:1 (12.11.2026)

Geschrieben von der PC-Sitzung, Zweig `feature/windows-fertigstellung` (von `develop`). Grundlage und Belege:
[`WINDOWS-FERTIG-2026-11-12.md`](WINDOWS-FERTIG-2026-11-12.md). Wunsch des Inhabers: „alles, dass es klappt und alles
1 zu 1 funktioniert“ zwischen Windows, Web und iPad/Mac.

> Hol mit `git fetch` und `git switch feature/windows-fertigstellung` den Stand und lies zuerst diesen Auftrag, dann
> `docs/WINDOWS-FERTIG-2026-11-12.md` (Abschnitte 1, 4a, 5) und in `docs/VERTRAEGE-KONTO-SYNC.md` den Abschnitt
> „Eigene Dokumente“. Arbeite auf einem eigenen Zweig von `develop` (bzw. nach dem Merge dieses Zweigs nach `develop`);
> `main` bleibt unverändert, kein Merge nach `main`, kein Release, keine Store-Einreichung ohne ausdrückliche Freigabe
> des Inhabers. Nichts als erledigt melden, was nicht getestet ist; Gerätetests nur melden, wenn sie wirklich liefen.

Was der PC **nicht** kann und deshalb hier liegt: Swift bauen und testen, und der SSH-Schlüssel für den Server
(`~/.ssh/studinow_server`) liegt nur auf dem Mac.

## Reihenfolge

### 1. Dienst auf dem Server aktualisieren (Voraussetzung für alles Weitere) – nur mit Freigabe des Inhabers

Erst wenn der Inhaber den Zweig nach `develop` übernommen hat und das Aufspielen freigibt (vorher den Satz in der
Datenschutzerklärung klären, `WINDOWS-FERTIG-2026-11-12.md` Abschnitt 4a):

1. Auf dem Server wie gewohnt `git pull` und `docker compose -f deploy/docker-compose.yml up -d --build`.
2. Prüfen (nur lesen): `GET https://app.studinow.app/api/sync/own-documents` ohne Anmeldung → **401** (nicht 404);
   `GET /.well-known/apple-developer-domain-association.txt` → 404, solange keine Datei hinterlegt ist.
3. Die nächtliche Sicherung enthält jetzt `files/Eigene Dokumente/` (vorher fehlten die im Web hochgeladenen PDFs).
   Nach dem ersten Lauf einmal im Archiv nachsehen, dass der Ordner dabei ist.

Das veröffentlichte iPad (1.0.2/Build 34) merkt davon nichts: Notizen eigener Dokumente kommen im Abruf nur mit
`own=1`, alles andere ist unverändert (`tests/test_own_docs_sync.py::test_published_ipad_does_not_get_notes_of_own_documents`).

### 2. Plan A: Community auf iPad/Mac über den Dienst (E2) – nur nach Entscheidung des Inhabers

Heute zwei getrennte Communitys (iPad/Mac: CloudKit; Windows/Web: Dienst). Plan, Aufrufe und Aufwand stehen in
`docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md` Abschnitte 5.1–5.3 (≈ 4–6 Tage):

- `ServiceCommunityService` vervollständigen: Fragen & Antworten, Korrekturen, Mitteilungen (Glocke), Lesezeichen,
  Sperren (5.2), Karteikarten-Stapel/Wochenstapel/Wochentests über den Dienst (5.3).
- Danach `communityViaService` wieder einschalten (`StudoraAccountLink.swift`, seit 07.11. `false`).
- Erprobt ist der Dienst-Weg mit einem „iPad-Konto“ (Header `X-StudiNow-Client: ios`) in `tools/e2e-windows-konto.py`.
- **Lerngruppen-Codes:** Windows/Web zeigen seit heute Gruppen, denen das Konto anderswo beigetreten ist, mit „Code hier
  einmal eingeben“ (Code nie beim Dienst). Mit Plan A dieselbe Anzeige auf iPad/Mac, sonst kennt ein iPad ohne iCloud-
  Code die Dienst-Gruppe nicht.
- Erst wenn Plan A im Store ist, stimmt „eine Community für alle“. Der Untertitel in Web/Windows sagt deshalb jetzt
  „StudiNow-Community für Windows und Web“ (`app/static/views-misc.js`); nach Plan A auf „Windows, Web, iPad und Mac“
  ändern.

### 3. Eigene Dokumente auf iPad/Mac abgleichen (E3, Swift-Teil)

Dienst und Windows sind fertig und getestet (Vertrag: `docs/VERTRAEGE-KONTO-SYNC.md` „Eigene Dokumente“; Referenz-
Client `app/own_docs_sync.py`, ca. 300 Zeilen). Die Kennungen passen schon: das iPad vergibt `u` + 23 Hex
(`LibraryEndpoints.newDocumentID`), genau wie Python.

1. In `DeviceSync` den Ablauf wie Windows: Liste holen (`GET /api/sync/own-documents`; 403 `plan_required` → aus;
   404 → älterer Dienst, Rest läuft) → G2 abrufen **mit `own=1`** → eigene Dokumente → G2 senden → Bilder hoch → G2
   abrufen → Bilder herunter.
2. Je Dokument eine Zuordnung wie `own_doc_link` (Zeitpunkt `meta_at` des Dienstes, Fingerabdruck der eigenen
   Beschreibung + SHA-256 vom letzten Abgleich). Regeln wie dort: nur hier geändert → `PUT` Beschreibung, dann
   `PUT …/content?sha256=` roh; nur im Dienst → übernehmen (`GET /api/files/{id}/content`, SHA-256 prüfen, Datei atomar
   ablegen); beides → dieses Gerät gewinnt; Grabsteine in beide Richtungen; im Dienst gelöscht, hier inzwischen
   Dokument **oder Notizen** geändert → bleibt und geht neu hoch.
3. Notizen eigener Dokumente beim Senden mit `file: {course_id: "__user__", course_title: "Eigene Dokumente", …}`, erst
   wenn das Dokument im Dienst liegt (Windows: `sync_client.file_info`). `DeviceSync.swift:554` schließt
   `__user__` bisher aus – das bleibt so, bis Schritt 1–2 da sind.
4. Bilder/PDF-Seiten in Notizen: `GET /api/sync/assets`, `PUT /api/sync/assets/{ordner}/{name}`, `GET /api/assets/…`.
   Aufnahmen bleiben am Gerät.
5. Ordner: `folder_id` im Dienst ↔ lokale Ordner über die G2-Zuordnung `folders`.
6. Tests: die Fälle aus `tests/test_own_docs_sync.py` als Kern-/App-Tests (beide Richtungen, gleichzeitige Notizen,
   Löschen beidseitig, „gelöscht, aber hier geändert“, Plus → nichts, älterer Dienst, Datei > 75 MB bleibt).
7. Datei über 75 MB: bleibt am Gerät, im Status nennen (Windows: Konto-Karte „Zu groß für den Abgleich“).

### 4. „Passwort für andere Geräte festlegen“ (Weg für Apple-Konten auf Windows, solange E1 fehlt)

Im Konto-Menü des iPads: ruft `POST /api/account/password/reset-request` mit der eigenen Adresse auf (öffentlich,
immer gleiche Antwort), Hinweis „Link in der Mail öffnen, Passwort festlegen, dann auf Windows mit E-Mail und Passwort
anmelden“. Der Reset beendet alle Sitzungen: danach meldet sich das iPad einmal neu mit Apple an. Dazu den fehlenden
Knopf für `link/apple` (Konto zuerst auf Windows angelegt, dann auf dem iPad mit Apple verknüpfen;
`StudoraAccount.linkApple` gibt es).

### 5. Community neu laden (gleiche Regel wie Web/Windows)

Beim Zurückkommen (`scenePhase == .active`) die offene Community-Liste neu laden, höchstens einmal je Minute, nie mit
angefangenem Text oder offenem Blatt, Scrollstand behalten (Vorbild `app/static/community-refresh.js`).

## Schritte nur im Konto des Inhabers (nicht von der Mac-Sitzung allein)

- **E1 Apple im Browser:** Services-ID im Apple-Entwicklerkonto anlegen, Domain `app.studinow.app`, Rückkehr-URL
  `https://app.studinow.app/login`; Bestätigungsdatei (falls verlangt) ins Datenvolumen kopieren
  (`docker compose -f deploy/docker-compose.yml cp ./apple-developer-domain-association.txt app:/data/apple-developer-domain-association.txt`),
  dann `LERNAPP_APPLE_WEB_CLIENT_ID=<Services-ID>` in `deploy/.env` und Dienst neu starten. Danach einmal mit einem
  Apple-Konto vom iPad auf Windows anmelden (Annahme „gleiche Apple-Benutzerkennung im selben Team“ ist ungeprüft).
- **E4 Bezahlen unter Windows/Web:** Stripe-Schlüssel und Preise im Stripe-Konto des Inhabers (`docs/ABO-SYSTEM.md`).
  Ohne Stripe oder Apple-Abo ist ein Windows-Nutzer nach 7 Tagen Probe gesperrt.
- **Datenschutzerklärung:** Satz zum Abgleich eigener Dokumente (Vorschlag in `WINDOWS-FERTIG-2026-11-12.md`
  Abschnitt 4a), vor dem Aufspielen von Schritt 1.

## Auf echten Geräten prüfen (danach)

1. Windows-PC und Web mit demselben Konto (Pro AI/Probe): Notizbuch am PC anlegen und beschreiben → „Jetzt abgleichen“ →
   im Web öffnen; im Web eine PDF importieren → am PC abgleichen → öffnen. (Im Lauf auf dem PC belegt, auf einem echten
   Windows-Laptop mit Installer nicht.)
2. Nach Schritt 3: dasselbe mit dem iPad.
3. Nach Schritt 2: Lösung am PC teilen → auf dem iPad sehen, kommentieren → Mitteilung am PC.
