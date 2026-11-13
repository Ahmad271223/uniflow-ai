# Community: Härtetest und Lasttest 20.000 Nutzer (13.11.2026)

Zweig: `community/test-last-windows` (von `develop`, nicht zurückgemischt, nichts gepusht, nichts zu Apple, kein
Server angefasst). **Alle Lasttests liefen nur lokal auf dem Mac** (eigener Dienst auf 127.0.0.1 mit Wegwerf-Daten),
nie gegen den echten Server oder den gemieteten Testserver.

## Kurz gesagt

- **4 echte Fehler gefunden und behoben**, jeder mit Test:
  1. Kommentare **gesperrter Nutzer** blieben unter fremden Lösungen sichtbar (Fragen und Antworten waren schon
     ausgeblendet, auf dem iPad auch Kommentare). Jetzt überall weg.
  2. Gesperrte Nutzer konnten ihre **alten Beiträge noch umschreiben** (Kommentare, Fragen, Antworten; am iPad
     Kommentare). Jetzt gesperrt, löschen bleibt erlaubt.
  3. **Doppelt auf „Melden“ tippen** konnte einen Serverfehler (500) auslösen. Jetzt zählt die Meldung einmal, die
     zweite bekommt eine normale Antwort „schon gemeldet“.
  4. Ein Kommentar, der **als Zahl statt als Text** ankommt (kaputte oder böswillige App), brachte den Dienst zum
     Fehler 500. Jetzt eine klare Ablehnung.
- **iPad und Dienst rechnen jetzt gleich:** Das iPad entfernte unsichtbare Steuer- und Richtungszeichen (mit denen
  man Text „verdreht“ anzeigen kann) nicht, der Dienst schon. Jetzt gleich, abgesichert durch eine gemeinsame
  Testdatei mit 22 Fällen, die Python und Swift beide prüfen.
- **Lasttest:** Bei **20.000 gleichzeitig angemeldeten Nutzern**, die im Schnitt einmal pro Minute etwas in der
  Community tun, antwortet der Dienst mit seiner heutigen Einstellung (4 Prozesse) im Median in rund 10–15 ms, ohne
  Fehler. Sind alle sehr aktiv (alle 20 Sekunden eine Aktion), reichen 4 Prozesse nicht mehr (Wartezeit ~1 s);
  mit 12 Prozessen geht es wieder glatt. **Kein einziges „database is locked“, keine verlorene Antwort, keine
  doppelte Stimme** in allen Läufen.
- **Engpass behoben:** Eine Seite des Fragen-Feeds stellte **124 Datenbankabfragen**, jetzt **8**. Dasselbe für
  Antworten, Mitteilungen und die Lösungsliste.
- **Ehrlich:** Der größte Rechenaufwand je Anfrage liegt **nicht in der Community**, sondern im allgemeinen Teil des
  Dienstes (Anmeldung prüfen, neun Zwischenschichten jeder Anfrage). Darum ändert die Verbesserung oben an der
  Gesamtkapazität wenig. Das betrifft den ganzen Dienst und ist ein eigener Umbau (siehe „Empfehlungen“).

## 1. Härtetest: was jetzt geprüft ist

Neu: `tests/test_community_haertetest.py` (32 Tests), dazu Swift `CommunityDiscussionTests.testTextCasesMatchServiceFixture`
und App-Test `CommunityCloudKitTests.testBannedUserCannotEditOldCommentsAndOthersNoLongerSeeThem`.

| Bereich | geprüft |
|---|---|
| Trennung | Fragen bleiben in ihrem Kurs (Liste, einzeln, Antworten, Stimmen, Melden, Merken per ID); gleicher Kurs-Schlüssel an einer anderen Hochschule zeigt nichts; Mitteilungen und Lesezeichen sind privat; fremde Beiträge lassen sich weder ändern noch löschen |
| Rechte | Free: weder lesen noch schreiben; Plus und Pro AI: lesen, fragen, antworten, kommentieren; nach Abo-Ende eigene Beiträge noch löschbar; unbestätigte E-Mail liest, schreibt aber nicht; Moderation nur für den Inhaber |
| Missbrauch | Gesperrte Nutzer überall unsichtbar und ohne Schreibrecht; eigene Sperrliste blendet Fragen und Antworten aus; Meldungen zählen einmal je Konto, ab 3 verborgen; Tagesgrenze für Meldungen; Stundengrenzen für Fragen und Antworten |
| Texte | leer, nur Leerzeichen, nur unsichtbare Zeichen, genau an der Grenze (160 / 4.000 / 2.000 Zeichen), eins drüber, Emoji (zählen als ein Zeichen), Steuer- und Richtungszeichen, falscher Datentyp |
| Gleichzeitig | 24 Antworten in derselben Sekunde (alle da, 24 Mitteilungen); 36 Fragen gleichzeitig, Blättern ohne Lücke und doppelt; 6 gleichzeitige Meldungen; 8-mal gleichzeitig dieselbe Meldung; 20 gleichzeitige Likes von 10 Konten = 10 |

Web/PC nutzt dieselben Dienst-Endpunkte und bekommt die Korrekturen damit automatisch. Die Eingabefelder im Browser
haben dieselben Längengrenzen wie der Dienst.

## 2. Lasttest

**Werkzeug:** `tools/lasttest-community-feed.py` (neu, nach dem Vorbild von `tools/lasttest-smart-planner.py`; k6 ist
auf dem Mac nicht installiert). Es startet den Dienst wie im Betrieb (uvicorn, `--workers 4` wie
`WEB_CONCURRENCY=4` im Dockerfile) nur auf 127.0.0.1 und hat keinen Schalter für eine fremde Adresse.

**Testdaten (erfunden):** 20.000 Konten (Plus, bestätigt, angemeldet), 400 Kurse, jedes Konto in 6 Kursen
(120.000 Mitgliedschaften), ungleich große Kurse (größter 8.173 Mitglieder, Median 146), 15.822 Fragen,
42.821 Antworten, 47.486 Likes, 85.222 hilfreich-Stimmen.

**Mischung der Aktionen:** 50 % Feed lesen (30 Fragen, jede fünfte die zweite Seite), 25 % Frage öffnen
(ein Teil davon mit hilfreich-Stimme), 8 % antworten, 3 % fragen, 4 % liken, 6 % Mitteilungen.

**Rechner:** MacBook Pro, 18 Kerne. **Wichtig:** Andere Sitzungen ließen parallel iPad-Simulatoren laufen
(Lastmittel zwischen 10 und 90). Antwortzeiten sind dadurch eher schlechter als auf einem ruhigen Rechner; Client und
Dienst teilen sich dieselben Kerne.

### 2a. Gemessen: vorher und nachher (Bestandsnutzer, 4 Dienst-Prozesse)

| | vorher | nachher |
|---|---|---|
| Datenbankabfragen je Feed-Seite | 124 | **8** |
| Datenbankabfragen „Frage öffnen“ | 17–25 | **13** |
| Rechenzeit Community-Funktion Feed (Median) | 1,2 ms | **0,8 ms** |
| Rechenzeit Community-Funktion Antworten (Median) | 2,4 ms | **1,7 ms** |
| Rechenzeit des ganzen Dienstes je Anfrage | 9,4 ms | **7,8 ms** |
| Höchstleistung (ohne Pause, 96 Verbindungen) | 538 Anfragen/s | 540 Anfragen/s |
| 20.000 online, 1 Aktion/Minute (333/s): Median Feed | 9,6 ms | 14,2 ms\* |
| … p95 / p99 Feed | 55 / 105 ms | 74 / 131 ms\* |
| Fehler (5xx), „database is locked“, verlorene Antworten | 0 / 0 / 0 | 0 / 0 / 0 |

\* Innerhalb der Schwankung durch die fremde Last auf dem Mac; die Rechenzeit je Anfrage ist der verlässlichere Wert.

### 2b. Gemessen: Grenze (20.000 online, jeder alle 20 s eine Aktion = 1.000 Anfragen/s angeboten)

| Dienst-Prozesse | erreicht | Median Feed | p95 Feed | p99 Feed | Fehler / locked |
|---|---|---|---|---|---|
| 4 (heute) | 480/s – **reicht nicht**, Anfragen stauen sich | 1.010 ms | 1.329 ms | 1.498 ms | 0 / 0 |
| 12 | **1.049/s** – alles bedient | 22 ms | 137 ms | 227 ms | 0 / 0 |

Schreiben unter Last: in allen Läufen zusammen über 13.000 bestätigte Antworten (dazu die Fragen), jede bestätigte
Antwort lag danach in der Datenbank, keine doppelte Stimme und kein doppeltes Like. SQLite mit WAL hält diese
Schreibrate (rund 110 Schreibvorgänge/s) ohne Sperrfehler.

Die wenigen Antworten mit Status 400 sind gewollt: der Test hat zufällig die eigene Frage geliked („Die eigene Frage
lässt sich nicht liken“).

### 2c. Gemessen: lauter neue Konten

Haben die 20.000 Konten noch keine eigene Datenbank (z. B. alle registrieren sich am selben Tag), legt der Dienst
beim ersten Kontakt jedes Kontos dessen Datenbank an (gewollt, einmal je Konto). In diesem Lauf (vor der Verbesserung,
Mac sehr stark ausgelastet, Lastmittel ~85) kostete eine Anfrage im Schnitt **35 ms** Rechenzeit, die 4 Prozesse
schafften nur ~70–100 Anfragen/s, Wartezeiten mehrere Sekunden – aber auch hier **keine Fehler und keine Sperren**.
Das ist ein Anlauf-Effekt: nach dem ersten Kontakt gilt 2a.

### 2d. Hochgerechnet (nicht gemessen)

Grundlage: 7,8 ms Rechenzeit je Community-Anfrage auf dem Mac. **Annahme:** ein Kern eines gemieteten Servers ist
1,5- bis 2-mal langsamer als ein Mac-Kern. Ziel: höchstens 70 % Auslastung.

| 20.000 online, … | Anfragen/s | Kerne (Mac) | Kerne Server (geschätzt) | Dienst-Prozesse |
|---|---|---|---|---|
| ruhig: 1 Aktion je Minute | 333 | 2,6 | **6 bis 8** | 6–8 |
| sehr aktiv: alle 20 s | 1.000 | 7,8 | **16 bis 22** | 16–22 |

Das gilt nur für die Community. Die übrigen Seiten (Übersicht, Lernplan, Abgleich) kommen dazu
(`docs/SKALIERUNG-GROSS.md`). Ein echter Lauf auf dem gemieteten Testserver würde die Annahme „1,5- bis 2-mal
langsamer“ ersetzen – **nur nach deiner ausdrücklichen Zustimmung**.

## 3. Empfehlungen (nicht umgesetzt, brauchen deine Entscheidung)

1. **Zahl der Dienst-Prozesse an die Kerne koppeln** (`WEB_CONCURRENCY` ≈ Kernzahl statt fest 4). Gemessen: 4 → 12
   Prozesse verdoppelt die Leistung. Betrifft den ganzen Dienst und den Server-Deploy (Freigabe nötig).
2. **Zwischenschichten des Dienstes umbauen** (neun `@app.middleware("http")` → schlanke ASGI-Middleware). Das ist der
   größte Teil der 7,8 ms; die Community selbst braucht unter 1 ms. Eigener Umbau für den ganzen Dienst.
3. Für einen Start mit sehr vielen neuen Konten am selben Tag: die Konto-Datenbank im Hintergrund anlegen statt beim
   ersten Aufruf (2c).

## 4. Nachmachen

```
.venv/bin/python tools/lasttest-community-feed.py --users 20000 --courses 400 --seconds 30 --out ergebnis.json
.venv/bin/python tools/lasttest-community-feed.py --users 20000 --think 20 --workers 12 --skip-a      # Grenze
.venv/bin/python tools/lasttest-community-feed.py --users 20000 --new-accounts --skip-a               # neue Konten
```

## 5. Geänderte Dateien

- Dienst: `app/community.py`, `app/community_qa.py` (4 Fehler, weniger Abfragen)
- iPad-Kern: `CommunityDiscussion.swift` (Texte bereinigen wie der Dienst); App: `CommunityCloudKit.swift`
  (gesperrte Konten ändern keine Kommentare)
- Gemeinsame Testdatei: `packages/shared-contracts/fixtures/community/text-cases.json`, erzeugt mit
  `tools/gen-community-text-cases.py`
- Tests: `tests/test_community_haertetest.py`, `CommunityDiscussionTests.swift`, `CommunityCloudKitTests.swift`
- Web: `app/static/community-spaces.js` (Lerngruppe zeigt nach Beitritt per Code ihren Namen; Cache-Versionen hochgezählt)
- Werkzeug: `tools/lasttest-community-feed.py`

## 6. Testergebnisse (13.11.2026, nach allen Änderungen)

- Python: `.venv/bin/python -m pytest` → 3.465 bestanden, 5 übersprungen, 2 erwartet rot (vorher 3.433; neu sind die
  32 Härtetests), keiner rot.
- Swift-Kern: `swift test` → 1.496 Tests, 0 Fehler (9 übersprungen wie bisher).
- Browser-Logik: `node --test tests/js/` → 440/440.
- iPad-App auf einem Klon des Simulators 4495AA80: `CommunityCloudKitTests`, `CommunityChannelAppTests`,
  `CommunityEntscheidungenAppTests`, `ViewTypeDepthAppTests` → 51/51 (die übrigen App-Tests nicht erneut gelaufen;
  geändert ist in der App nur `CommunityCloudKit.swift`).
