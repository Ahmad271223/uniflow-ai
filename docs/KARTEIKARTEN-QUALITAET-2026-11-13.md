# KI-Karteikarten: bessere Qualität (13.11.2026)

Zweig `ki/karteikarten-qualitaet` (von `develop`), nicht gemischt, nicht hochgeladen, nicht auf dem Server.

## Kurz gesagt

- Die KI bekommt jetzt klare Regeln für gute Karten: **eine Idee je Karte**, kurze vollständige Antwort,
  **Mischung** aus Begriff-, Warum-, Rechen-, Formel- und Lückentext-Karten, **nichts erfinden**, keine Ja/Nein-
  und keine Doppelfragen.
- **Jede Karte nennt ihre Seite.** Die Antwort endet mit „(S. 4)“. Beim Auftrag „Modul/Woche“ mit Dateiname,
  z. B. „(V05.pdf, S. 12)“. Die Seitenzahl wird geprüft: nur Seiten, die wirklich gewählt waren.
- **Strengere Prüfung** der KI-Antwort (Python und iPad gleich): doppelte und fast gleiche Fragen fliegen raus,
  zu lange Karten (keine „eine Idee“ mehr) fliegen raus, Karten, deren Frage die Antwort schon verrät, fliegen raus.
  Fragen, die sich nur in einer Zahl unterscheiden („… für q = 1/2?“ und „… für q = 1/3?“), gelten nicht als doppelt.
- Das Modell bleibt das günstige (gpt-6-luna). **Kosten pro Kartensatz: weiterhin 1 Credit.**
- Ein Fehler nebenbei behoben: Ein Auftrag mit 50 Karten passte nicht in die alte Ausgabegrenze (3000 Tokens,
  50 Karten brauchen rund 4500 plus Denken). Neue Grenze 8000. Das kostet nur, was wirklich gebraucht wird.

## Vorher / Nachher

Wichtig, ehrlich: Hier ist **kein Schlüssel für die echte KI** vorhanden (Ordner `~/Studora-Builds/keys/` ist leer).
Die Beispiele stammen von einem kleinen, schnellen Hilfsmodell, dem ich genau den alten bzw. den neuen Prompt
gegeben habe. Das echte Modell der App kann etwas anders schreiben. Die Richtung ist aber klar zu sehen.

Material: nachgebaute Folien „Abtastung“ (Signale und Systeme, Seiten 3–6), „Reihen“ (Analysis, Seiten 12–14),
„Objekte und Referenzen“ (Programmieren in Java, Seiten 21–24). Je 8 Karten.

### Signale und Systeme

| Vorher | Nachher |
|---|---|
| Unter welcher Bedingung ist ein bandbegrenztes Signal exakt rekonstruierbar? → „Wenn f_A > 2·f_max gilt. **Die Rate 2·f_max heißt Nyquist-Rate.**“ (zwei Dinge in einer Karte) | Wie lässt sich beim Abtasttheorem ein bandbegrenztes Signal zurückgewinnen? → Mit einem idealen Tiefpass mit Grenzfrequenz f_A/2 (sinc-Interpolation). **(S. 4)** |
| Wie verhindert man Aliasing **vor der Abtastung**? → „Mit einem Anti-Aliasing-Filter … **VOR der Abtastung**.“ | Beim Abtasten gilt: Ist f_A ≤ 2 f_max, so ___ sich die periodisch fortgesetzten Spektren. → überlappen **(S. 5, Lückentext)** |
| (Seite 6, CD-Audio, **fehlt ganz**) | **Warum** braucht das Anti-Aliasing-Filter bei CD-Audio einen Übergangsbereich zwischen 20 und 22,05 kHz? → Hörbereich bis 20 kHz, Grenze f_A/2 = 22,05 kHz; dazwischen muss das Filter schon dämpfen. **(S. 6)** |
| Welche Alias-Frequenz entsteht bei f = 7 kHz, f_A = 10 kHz? → 3 kHz | Ein Signal mit 7 kHz wird mit f_A = 10 kHz abgetastet. Auf welche Frequenz wird es abgebildet? → 3 kHz, denn \|7 − 10\| kHz = 3 kHz. **(S. 5, Rechnen mit Weg)** |

### Analysis

| Vorher | Nachher |
|---|---|
| **Was ist eine Reihe und wann konvergiert sie?** (Doppelfrage) | Wie ist die Folge der Partialsummen sₙ gebildet? → sₙ = Σₖ₌₁ⁿ aₖ … **(S. 12)** |
| Gilt die Umkehrung des notwendigen Kriteriums? → Nein … (Ja/Nein) | **Warum** folgt aus aₖ → 0 allein noch nicht, dass Σ aₖ konvergiert? → Gegenbeispiel harmonische Reihe. **(S. 12)** |
| Was besagt das Quotientenkriterium? → ganze Regel mit drei Fällen | Welche Aussage macht das Quotientenkriterium, wenn lim \|aₖ₊₁/aₖ\| = 1? → Keine Aussage. **(S. 14, gezielt der Stolperstein)** |

### Programmieren

| Vorher | Nachher |
|---|---|
| Was liefern s == t **und** s.equals(t) …? (zwei Antworten in einer) | **Warum** ergibt s == t den Wert false, wenn beide mit new String("Hi") erzeugt werden? → == vergleicht Referenzen … **(S. 22)** |
| Wann tritt eine NullPointerException auf **und wie vermeidet man sie?** | Getrennt: „Wann wirft Java eine NullPointerException?“ **(S. 24)** und „Wie vermeidet man sie?“ **(S. 24)** |
| Wie vergleicht man Objekte richtig? → equals() (fast dieselbe Karte wie die davor) | Lückentext: Objekte vergleicht man in Java immer mit ___ und nicht mit ==. → equals() **(S. 22)** |

### Bewertung

- **Vorher** waren die Karten meist inhaltlich richtig, aber: keine Seitenangabe, mehrere Doppelfragen, fast nur
  „Was besagt …?“, kaum „Warum“, eine Seite (CD-Beispiel) fehlte ganz, eine Karte doppelt.
- **Nachher**: alle Seiten abgedeckt, jede Karte mit Seite, gemischte Arten (in jedem Fach 3× Verständnis,
  1–2× Anwendung, 1× Lückentext, nur 1–2× reine Begriffe), keine Doppelfragen. Restschwäche im Test: eine Ja/Nein-
  Karte zum Leibniz-Kriterium; dafür gibt es jetzt die Regel „keine Ja/Nein-Fragen“.
- Die strengere Prüfung hat bei diesen Beispielen nichts aussortieren müssen. Sie ist ein Sicherheitsnetz für
  Ausreißer (doppelte Karten bei 30–50 Karten, sehr lange Antworten, verratene Antworten).

## Was ist mit StudySmarter? (öffentlich recherchiert, nichts übernommen)

- Laut ihrer Hilfe erzeugt deren KI Karten als **Frage/Antwort** oder **Multiple Choice**, aus Text oder Datei
  (bis 10 Seiten, etwa 5 Karten je Seite). Lückentext und Wahr/Falsch als eigene Art habe ich nicht gefunden.
- Seitenangabe auf der Karte, Schwierigkeitsstufen und Duplikat-Schutz sind dort **nicht dokumentiert**.
- Wiederholung: eigene Stufen (schlecht / ok / gut / perfekt), wachsende Abstände.
- Die bekannten Regeln für gute Karten (SuperMemo „20 Regeln“, Andy Matuschak) sagen: kleine, eindeutige Fragen,
  eine Antwort, nichts verraten, Aufzählungen aufteilen, Lückentext nur mit einer Lücke. Genau das steht jetzt im Prompt.
- Typische Fehler von KI-Karten laut Erfahrungsberichten: Doppelfragen, „es/dies“ ohne Bezug, erratbare Lücken,
  erfundene Inhalte. Darauf zielen Regeln und Prüfung.

Quellen: studysmarter.zendesk.com (Hilfeartikel zu KI-Karten, Multiple Choice, Spaced Repetition),
supermemo.com/en/blog/twenty-rules-of-formulating-knowledge, andymatuschak.org/prompts,
dev.to/alexrchen/why-llm-generated-flashcards-are-usually-bad-and-how-to-screen-them-20mi.

## Kosten und Modellwahl (mit Zahlen)

1 Credit = 0,9 Cent. Pro AI hat 100 Credits im Monat. Preise aus `app/ai_prices.py`.

| Kartensatz | gpt-6-luna (heute, bleibt) | Claude Sonnet 5.5 | Mischung MEDIUM (75 % luna, 25 % Sonnet) |
|---|---|---|---|
| Dokument, 10 Karten | 0,14 ct = **1 Credit** (vorher 0,12 ct) | 3,0 ct = 4 Credits | Ø 0,84 ct, Ø 1,75 Credits |
| Dokument, 30 Karten | 0,22 ct = **1 Credit** | 4,9 ct = 6 Credits | Ø 1,4 ct, Ø 2,25 Credits |
| Auftrag Woche, 50 Karten | 0,34 ct = **1 Credit** | 7,5 ct = 9 Credits | Ø 2,1 ct, Ø 3 Credits |

Schätzung: Text ≈ 3,5 Zeichen je Token, rund 1000 Denk-Tokens, je Karte rund 80 Ausgabe-Tokens.

- **Empfehlung: beim günstigen Modell bleiben.** Der neue Prompt kostet fast nichts mehr (+0,02 ct je Satz) und
  bleibt bei 1 Credit. Mit MEDIUM würde ein Kartensatz im Schnitt 1,75 statt 1 Credit kosten: Studierende bekämen
  aus 100 Credits etwa 57 statt 100 Kartensätze, und die Qualität schwankt je nachdem, welches Modell antwortet.
- **Kein zweiter KI-Durchgang zum Selbstprüfen.** Er würde jeden Satz auf 2 Credits verdoppeln (Mindestpreis
  1 Credit je Aufruf). Stattdessen prüft die App selbst (ohne KI, kostenlos).
- Wenn du MEDIUM später trotzdem testen willst: Das geht ohne neuen Code über die Server-Einstellung
  `LERNAPP_AI_ROUTES` (z. B. `{"routes": {"flashcards": "openai:75,anthropic:25"}}`). Das wäre ein Server-Update
  und braucht deine Freigabe.

## Neue Kartenarten (Multiple Choice, Wahr/Falsch): später

Der Trainer zeigt heute nur Vorderseite/Rückseite. Lückentext passt da hinein (Lücke „___“ in der Frage) und ist
jetzt dabei. **Multiple Choice** und **Wahr/Falsch** brauchen neue Felder in der Datenbank (Python, iPad, Abgleich)
und eine neue Ansicht im Trainer. Vorschlag als eigener späterer Schritt. Ebenso eine echte Spalte „Seite“ in der
Datenbank, damit man von der Karte direkt zur Seite im Dokument springen kann (heute steht die Seite im Antworttext).

## Was im Code geändert ist

- `app/ai.py`: `FLASHCARDS_RULES`, `FLASHCARDS_KINDS`, `FLASHCARDS_SCHEMA` mit `kind` und `page`,
  `flashcards_pages_text` (Seitenüberschriften), strengere `check_flashcards` (Länge, Doppel, verratene Antwort,
  Seitenangabe).
- `app/flashcard_order.py`: Auftrag nach Modul/Woche mit denselben Regeln und Prüfung, Seitenangabe mit Dateiname.
- `app/server.py`: Seitenüberschriften im Prompt, Prüfung mit den gewählten Seiten.
- `app/ai_backend.py`: Ausgabegrenze Karteikarten 3000 → 8000.
- iPad-Kern (Swift): dieselben Regeln (erzeugt mit `tools/gen-swift-ai-texts.py`), dieselbe Prüfung
  (`AIAnswers.checkFlashcards`), Seitenüberschriften (`AIPrompts.flashcardsPagesText`). Gespeicherte geteilte
  Stapel werden nicht neu geprüft, damit keine Karte verschwindet.
- Vertrag `packages/shared-contracts/ai/contract.json` mit neuen Fällen; Python und Swift bestehen dieselben Fälle.

Verträglich mit alten Geräten und altem Server: Alte iPads ignorieren die neuen Felder; ein neues iPad mit altem
Server bekommt Karten ohne Seitenangabe, sonst gleich.
