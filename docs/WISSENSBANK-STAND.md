# StudiNow-Wissensbank – Stand 21.11.2026 (Zweig `server/wissensbank`, enthält `release/1.0.7` lokal bis `1f3f21d3`)

## Fertig

- **Dienst** (`app/wissensbank.py`): Bibliothek aus `LERNAPP_WISSENSBANK_DIR` (Standard `/data/wissensbank`), Schalter
  `LERNAPP_WISSENSBANK` (Standard aus). Nur Pro AI und nur Konten der LUH (Hochschule am Konto, nicht Angabe der App).
- **Zuordnung über den Wortlaut**: Kandidaten über Dateititel (`quellen`, NFC, ohne Endung/Leerraum) bzw. Kurs; Entscheidung
  per 3-Wort-Shingles. Schwellen: Überlappung ≥ 0,6 mit Folien-/Aufgabentext, 0,75 ohne, +0,1 bei Kurs-Suche, mind. 8
  gemeinsame Shingles, Folien zusätzlich Jaccard ≥ 0,5. Zahlen samt Nachbarwörtern (Multimenge) müssen bei Aufgaben genau
  stimmen. Seitennummer nur Gleichstand-Entscheider. „identisch mit G00xx Seite N“ wird aufgelöst.
- **Ablauf in `/api/ai/relay`**: erstes Mal Antwort aus der Wissensbank (1 Credit, `tutor:wissensbank`, Kontingent und
  Rate-Limit wie KI); Wiederholung derselben Stelle → normale KI + `feedback_token`. `POST /api/ai/feedback`: Ja =
  Kandidat (ohne Konto, ohne Frage, ungeprüft), Nein = Stimme für die vorher gelieferte Antwort. Auswahl je Stelle:
  Wahl des Inhabers, sonst freigegebener Kandidat mit mehr Stimmen als die Bibliothek, sonst Bibliothek.
- **Ausgelieferter Text ohne Abgleich-Notizen** (21.11.2026, `without_abgleich` in `answer_text`): Die Bibliothek enthält
  in den Abschnitten interne Prüfnotizen „Abgleich …“ (Vergleich der eigenen Lösung mit der Lösung der Lehrenden, teils
  mit deren Wortlaut). Sie werden nicht ausgeliefert: Absatz, Listenpunkt oder Satz mit der Marke „Abgleich“ (fett,
  kursiv oder am Satzanfang) bis zur nächsten anderen Marke („**Lösung.**“, „**Kernergebnis.**“) bzw. Leerzeile, dazu
  Unterabschnitte `### Abgleich …`. Bleibt nur die Vorlage (Zitat, Aufgabentext) übrig, ist die Stelle nicht lieferbar
  und die KI antwortet wie sonst. Der Abschnitt endet außerdem an der nächsten Überschrift der obersten Ebene (`# [Q2] …`
  hing bisher am Abschnitt davor). Die Zuordnung liest unverändert den ganzen Abschnitt; die Hinweise für das Abzeichen
  („KI-Lösung, ungeprüft“ …) ebenfalls.
- **Prüf-Werkzeug**: `python -m app.wissensbank_pruefen --liste/--zeigen/--freigeben/--ablehnen/--waehlen/--bibliothek`.
- **Konto**: Löschen und Export umfassen die neuen Tabellen; offene Ja/Nein-Fragen verfallen nach 7 Tagen.
- **Hochladen**: `tools/wissensbank-hochladen.sh SERVER_IP` (nur `katalog.json` + `.md`, nicht ausgeführt).
- **App**: sendet `wissensbank`-Angaben nur, wenn `GET /api/entitlements` `wissensbank: true` meldet; Abzeichen „Aus der
  StudiNow-Wissensbank“ (+ geprüft / KI-Lösung, ungeprüft), Ja/Nein-Frage, lokales `/api/ai/feedback`; Wissensbank-
  Antworten nie in den geteilten Erklärungsspeicher.
- **Entwurf** Datenschutz/AGB + Urheberrechts-Hinweis: `docs/release/ENTWURF-1-0-7.md` (Abschnitt „StudiNow-Wissensbank“).

## Tests (21.11.2026, alle auf dem Mac gelaufen, Protokolle in `~/Studora-Builds/fix-wissensbank-logs/`)

- **Python, voller Lauf** nach dem Mischen von `release/1.0.7` (Stand `a4640600`): 3977 grün, 0 rot, 4 übersprungen,
  2 erwartet rot (7:55 min). Kein Wackel-Test rot. `node --test tests/js/`: 472 grün.
- **Python, schneller Lauf** (ohne die 10 Lasttests) auf dem Endstand mit Abgleich-Filter (`6acd2d23`): 3997 grün, 0 rot,
  4 übersprungen, 2 erwartet rot (6:14 min). Der volle Lauf ist auf dem Endstand nicht wiederholt (Rechner unter Last).
  `tests/test_wissensbank.py`: 68 grün (23 Zuordnungsfälle alle richtig, 0 falsche Treffer; 24 Formen der
  Abgleich-Notiz); mit `test_ai_relay.py` und `test_audit_p58_87_server.py` zusammen 108 grün.
- **Swift-Kern** (`swift test`, Stand `a4640600`): 1770 Tests, 16 übersprungen, 0 Fehler (inkl. `WissensbankTests`, 6).
- **App im Simulator** (Klon `fix-wissensbank`, iPad): 25 Klassen der KI-Hilfe, 180 Tests, 0 rot, 2 übersprungen
  (Bildschirmfoto-Tests, die nur mit gesetzter Umgebungsvariable laufen). Zweimal gelaufen: Stand `a4640600` und nach dem
  Nachmischen Stand `282d4ea9`. Klassen: `AIStartPolish`, `TutorPanelWidth`, `StudiNowAI`, `AIViews`, `PageExplain`,
  `TutorCardsRun`, `KIAbnahmeLUH`, `CreditShop`, `TutorDocument`, `TutorConversations`, `KIErklaerenBild`, `ChatGPTLink`,
  `TutorHead`, `AIConsent`, `AIAnswerRecursion`, `MathDisplay`, `OwnChatGPTOff`, `TutorStop`, `OpenAIKeyLink`,
  `ViewTypeDepth`, `Wissensbank`, `CreditsDisplay`, `LocalBackend`, `SplitWidth` (jeweils `…AppTests`) und
  `EntitlementTests`. Nicht gelaufen: iPhone-Klassen (`IPhoneLearnAITests`), übrige App-Tests, kein echtes Gerät.
- **Lokal an der echten Bibliothek** (nicht committet, nur Zahlen): 26 571 lieferbare Abschnitte (15 319 Seiten,
  11 252 Aufgaben). Der Filter nimmt aus 4 398 Abschnitten Abgleich-Notizen heraus (3,8 % des Textes); 548 Abschnitte
  sind danach nicht mehr lieferbar (334 davon reine Verweise „identisch mit G00xx“). Das Wort „Abgleich“ steht vorher in
  4 680, danach in 315 Abschnitten (Rest: „Nachrechnung/Abgleich“, „Abgleichsvermerk“, Fließtext). Stand vom 20.11. zur
  Zuordnung (594/600 richtig + 3 gleichwertig, 3 kein Treffer, 0 falsch; geänderte Zahl 0/187 Treffer) ist nicht neu
  gemessen; die Zuordnung ist unverändert.

## Entscheidungen des Inhabers 21.11.2026

- **Urheberrecht**: vom Inhaber geprüft (seine Aussage).
- **Keine Musterlösungen der Lehrenden** herausgeben, nur die eigene Erklärung und Lösung, schön formatiert wie eine
  KI-Antwort. Umgesetzt für die Abgleich-Notizen (siehe „Fertig“); was darüber hinaus in der Bibliothek steht, siehe
  „Fehlt“ Punkt 1.
- **Abschnitte, die auf Lösungen der Lehrenden beruhen** (Nachfrage am 21.11.2026 nachmittags, nach dem Befund unten:
  Absätze „Musterlösung/Kurzlösung“, Einheiten, die ein Lösungsdokument Zeile für Zeile erklären): Der Inhaber hat
  entschieden, sie bleiben in der Wissensbank – „einbauen in die Wissensbank, und wenn jemand eine Frage hat und die
  Lösung passend ist, Lösung angeben aus der Wissensbank“. Es wird also nichts weiter herausgefiltert; nur die internen
  Abgleich-Notizen werden nicht ausgeliefert.
- **Probe-Konten**: unverändert einbezogen (zählen als Pro AI); dazu gab es keine neue Aussage.
- **Treffer** weiterhin nur bei gleicher Seite bzw. gleicher Aufgabe (Wortlaut). Fragen „zum Thema“ ohne gleiche
  Seite/Aufgabe sind **nicht** umgesetzt; möglicher späterer Schritt.
- **Einschalten** (`LERNAPP_WISSENSBANK=1`), Upload und Server-Deploy: Sache des Inhabers bzw. nur mit seinem
  ausdrücklichen Okay.

## Fehlt / nächste Schritte

1. **Entschieden am 21.11.2026 (bleibt drin, siehe oben) – zur Einordnung: Lösungen der Lehrenden außerhalb der
   Abgleich-Notizen.** Gemessen an der echten
   Bibliothek (nach dem Filter): In 2 198 Abschnitten stehen weiter die Wörter „Musterlösung“, „Kurzlösung“, „ML“ oder
   „Lösungsfolie“; in rund 1 350 Abschnitten (79 Dateien) als eigene Marke am Absatzanfang, etwa „**Musterlösung.** …“,
   „**Kurzlösung (wörtlich).** …“, „Musterlösung: …“. Dazu rund 2 700 Abschnitte, deren Quelle dem Titel nach selbst ein
   Lösungsdokument ist (die Bibliothek erklärt dort die Lösung der Lehrenden Zeile für Zeile; geliefert würde das, wenn
   jemand genau diese Lösungsseite öffnet und fragt). Ob das unter „keine Musterlösungen herausgeben“ fällt, ist nicht
   entschieden und nicht gebaut. Außerdem zitieren die Abschnitte den Folien- bzw. Aufgabentext der Vorlage (`>`-Zitate,
   „Aufgabentext“): der steht weiter in der Antwort (der Nutzer hat genau diese Seite vor sich).
2. Verlauf der KI-Hilfe speichert Abzeichen/Frage nicht (nach Neustart weg) – bewusst einfach gehalten.
3. Entwurf Datenschutz/AGB (`docs/release/ENTWURF-1-0-7.md`) an die Entscheidungen anpassen (dort steht die Frage zu den
   Musterlösungen noch als offen).
4. MAC-ANLEITUNG.md der Bibliothek sagt „nicht auf Server“ – Entscheidung dort vermerken.
5. Mischen in `release/1.0.7` (zentral, Hauptsitzung): Probe-Mischen gegen `release/1.0.7` @ `cbc3a22c` ohne Konflikt,
   keine gemeinsamen Dateien. Danach Upload und Schalter nur mit Okay des Inhabers.
