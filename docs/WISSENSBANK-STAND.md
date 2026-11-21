# StudiNow-Wissensbank – Stand 21.11.2026 abends (Zweig `server/wissensbank`, enthält `release/1.0.7` lokal bis `831bd22a`)

## Fertig

- **Dienst** (`app/wissensbank.py`): Bibliothek aus `LERNAPP_WISSENSBANK_DIR` (Standard `/data/wissensbank`), Schalter
  `LERNAPP_WISSENSBANK` (Standard aus). Nur Pro AI und nur Konten der LUH (Hochschule am Konto, nicht Angabe der App).
- **Zuordnung über den Wortlaut**: Kandidaten über Dateititel (`quellen`, NFC, ohne Endung/Leerraum) bzw. Kurs; Entscheidung
  per 3-Wort-Shingles. Schwellen: Überlappung ≥ 0,6 mit Folien-/Aufgabentext, 0,75 ohne, +0,1 bei Kurs-Suche, mind. 8
  gemeinsame Shingles, Folien zusätzlich Jaccard ≥ 0,5. Zahlen samt Nachbarwörtern (Multimenge) müssen bei Aufgaben genau
  stimmen. Seitennummer nur Gleichstand-Entscheider. „identisch mit G00xx Seite N“ wird aufgelöst. „Aufgabentext:“ zählt
  auch ohne Fettdruck als Aufgabentext.
- **Text aus echten PDFs** (21.11.2026 abends, Messung unten): `normalize` setzt getrennte Umlaute der PDF-Textebene
  zusammen („f¨ ur“, Trema vor dem Buchstaben, auch über den Zeilenumbruch) und wirft Zeichen aus dem Privatbereich weg.
- **Ausschnitt einer Folie** („Bereich an KI“; `plan()` erkennt ihn am Bild oder am Feld `wissensbank.ausschnitt`): Es
  zählt das Enthaltensein (≥ 0,7 des Ausschnitts steht im Folientext, mind. 12 gemeinsame Shingles), nicht die Ähnlichkeit
  zur ganzen Folie. Passen mehrere Stellen (Aufbaustufen), zählt nur die mitgeschickte PDF-Seite und nur bei bekanntem
  Dateititel; sonst kein Treffer.
- **Stelle über Dateititel und Nummer** (`_anchored`, nur bei bekanntem Dateititel und nur, wenn der Wortlaut nichts
  findet): *Folien* über die Seitennummer und die Begriffe der Seite (≥ 0,6 der Begriffe der Anfrage stehen im Abschnitt,
  mind. 6, und mind. 0,15 besser als jede andere Seite derselben Einheiten). *Aufgaben* über die Aufgabennummer aus der
  Überschrift im angefragten Text, dieselbe Begriffsregel und die Zahlen der Aufgabe: die längste Zahlenfolge der
  Anfrage, die im Abschnitt am Stück steht, muss ≥ 0,6 aller Zahlen wiegen (0/1 = 1, Ziffer = 3, sonst 3,3 je Ziffer;
  mind. 14). Steht derselbe Dateititel in mehreren Einheiten (Semestern), wählen die Zahlen die Einheit; passen sie zu
  keiner, gibt es keinen Treffer.
- **Sperren gegen falsche Treffer** (jede aus einem gemessenen Fall): unter 5 Begriffen kein Treffer (Zahlenreihen,
  Wahrheitstafeln, einzelne Formeln); kurzer Aufgabentext oder kurze Anfrage (unter 25 Shingles) nur, wenn der angefragte
  Text die Nummer dieser Aufgabe nennt; Aufgabe ohne Zahlen nur bei bekanntem Dateititel; Seiten, die Aufgaben nennen, nie
  über Seitennummer und Begriffe; anderes Datum im Text als im Abschnitt = andere Fassung.
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
- **Abgleich mit echten PDFs (21.11.2026 abends, Endstand dieses Zweigs):** `tests/test_wissensbank.py` 86 grün (jede
  neue Regel mit Treffer und Gegenprobe am erfundenen Fixture: gleiche Aufgabe mit anderen Zahlen, gleicher Dateiname in
  zwei Semestern, reine Zahlenreihe, Kopfzeile, anderer Kurs, verschobene Nummer; jede Regel einzeln abgeschaltet macht
  ihren Test rot); mit `test_ai_relay.py` und `test_audit_p58_87_server.py` 126 grün. Schneller Python-Lauf: 4015 grün,
  0 rot, 4 übersprungen, 10 abgewählt (Lasttests), 2 erwartet rot (6:17 min). Voller Lauf, Swift und App nicht neu
  gelaufen (nur `app/wissensbank.py`, Tests und Fixture geändert).
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
  4 680, danach in 315 Abschnitten (Rest: „Nachrechnung/Abgleich“, „Abgleichsvermerk“, Fließtext).
- **Richtigstellung zu „594/600“ vom 20.11.:** Das war kein Test mit Text aus PDFs. Gefragt wurde mit dem Folien- bzw.
  Aufgabentext der Bibliothek selbst (neu umbrochen, erfundene Kopf- und Fußzeile, Dateititel aus der Bibliothek) und nur
  für Abschnitte, die so einen Text haben. Die Zahl sagt, dass der Vergleich seinen eigenen Text wiederfindet, nicht,
  wie oft eine echte Seite trifft. Maßgeblich ist die Messung unten.

## Messung mit echten PDFs (21.11.2026, Stand `894bcc1f` + Folge-Commits)

**Aufbau** (Skripte, Texte und Ergebnisse außerhalb des Repos: `~/Studora-Builds/fix-wissensbank-logs/messung/`,
Überblick in `~/Studora-Builds/fix-wissensbank-logs/STAND-PAUSE.md`): Export der Kursdateien des Inhabers, 740 PDFs,
223 davon mit einem Dateititel, den die Bibliothek kennt. Text wie in der App: Seitentext mit PDFKit (`page.string`),
Ausschnitte gerendert und mit Vision gelesen (Einstellungen wie `PDFEditorController.recognizeText`, Faktor wie
`areaScale`). Ausschnitte: je Aufgaben-Überschrift bis zur nächsten (2 533), auf Folien ein Block von etwa 40 % der
Zeilen und eine Formelzeile (2 058 Seiten). Gemessen am Mac, ohne Notizen auf der Seite; am iPad liest dieselbe
Bibliothek, kleine Abweichungen der Texterkennung sind möglich. „Vorher“ = `831bd22a` (so läuft der Dienst).

| Weg (Dateien mit Titel in der Bibliothek) | Anfragen | vorher | jetzt |
| --- | --- | --- | --- |
| Folie: Ausschnitt, Block (Vision) | 248 | 39 (15,7 %) | 112 (45,2 %) |
| Folie: Ausschnitt, Block (markierter Text, PDFKit) | 248 | 45 (18,1 %) | 133 (53,6 %) |
| Folie: eine Formelzeile (Vision) | 86 | 3 (3,5 %) | 21 (24,4 %) |
| Folie: ganze Seite (PDFKit) | 2 076 | 430 (20,7 %) | 1 021 (49,2 %) |
| Übungsblatt: Aufgabe eingekreist (Vision) | 227 | 43 (18,9 %) | 49 (21,6 %) |
| Übungsblatt: Aufgabe markiert (PDFKit) | 227 | 45 (19,8 %) | 57 (25,1 %) |
| Übungsblatt: ganze Seite | 517 | 57 (11,0 %) | 78 (15,1 %) |
| Klausur: Aufgabe eingekreist (Vision) | 547 | 7 (1,3 %) | 8 (1,5 %) |
| Klausur: Aufgabe markiert (PDFKit) | 547 | 18 (3,3 %) | 23 (4,2 %) |
| Lösungsdatei: Aufgabe eingekreist (Vision) | 227 | 0 | 1 (0,4 %) |

Aufgaben im Modus „Lösen“ liegen je Zeile ein bis drei Treffer darunter. Die Folien-Ausschnitte sind eine Stichprobe
(bis 10 Seiten je Datei).

**Gegenproben: 28 675 Anfragen, 0 falsche Lösungen.** Text einer Datei mit dem Dateinamen einer anderen aus demselben
Modul (10 346), Dateien ohne Titel in der Bibliothek über die Kurs-Suche (8 429), Aufgabentext mit der Nummer einer
anderen Aufgabe (5 234), Ausschnitte mit fremdem oder unbekanntem Titel und reine Kopfzeilen (4 666). Das Prüfskript
vergleicht jeden Treffer mit der Quelldatei bzw. dem Text der Bibliothek; was es nicht bestätigen konnte (44 verschiedene
Fälle über alle Läufe), ist von Hand angesehen: 42 inhaltlich richtig (meist andere Seitenzählung, zwei Fassungen
derselben Datei im Export, Mitschrift zu genau dieser Folie), 2 Grenzfälle ohne falsche Lösung (wortgleicher Text auf
einer anderen Folie desselben Kurses; einer davon bestand schon vorher). Dazu 38 Treffer der neuen Wege als Stichprobe
von Hand: alle richtig. Auf dem Weg dahin gefunden und gesperrt: gleiche Kurzklausur-Aufgabe eines anderen Jahres mit
anderen Zahlen, gleicher Dateiname in mehreren Jahren, derselbe kurze Satz in zwei Aufgaben, Zahlenreihen gegen
Wahrheitstafeln, fast gleich überschriebene Folien.

**Gründe für „kein Treffer“** (eingekreiste Aufgabe, vorher): 40 % Abschnitt ohne Aufgabentext, 33 % Aufgabentext da,
aber kaum gemeinsamer Text (Kurzfassung in eigenen Worten, Formeln), 13 % Überlappung unter 0,6, 8 % kein Abschnitt zu
dieser Aufgabe. Das liegt an der Bibliothek, nicht an Schwellen: Von 11 252 Aufgaben-Abschnitten haben 6 927 keinen
Aufgabentext (6 750, seit „Aufgabentext:“ ohne Fettdruck zählt), 923 nur einen sehr kurzen; von 15 319 Folien-Abschnitten
haben 6 850 keinen Folientext. Größte Lücken bei den Aufgaben: Grundlagen digitaler Systeme 1 321 von 1 960, Mathe II
854 von 1 256, Signale und Systeme 695 von 876, Numerik 681 von 1 904, ET Felder 666 von 1 087, Mathe I 535 von 689,
ET Netzwerke 484 von 1 220, TM II 387 von 502, TM I 339 von 440. Ohne Aufgabentext trifft eine Aufgabe nur über
Dateititel + Nummer + Zahlen; Aufgaben ohne Zahlen im Text oder mit Zahlen, die die Texterkennung nicht liest, treffen
dann bewusst nicht.

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
- **Treffer** weiterhin nur bei gleicher Seite bzw. gleicher Aufgabe. Fragen „zum Thema“ ohne gleiche Seite/Aufgabe
  sind **nicht** umgesetzt; möglicher späterer Schritt.
- **Lieber kein Treffer als eine falsche Lösung** (21.11.2026, zur Sorge „gleiches Dokument, aber andere Aufgabe oder
  andere Nummer“): Trefferquote ist zweitrangig. Daraus folgen die Sperren oben.
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
5. Mischen in `release/1.0.7` und Dienst-Update (zentral, Hauptsitzung; nur mit Okay des Inhabers). Der Abgleich ist
   reines Python (`app/wissensbank.py`), die App bleibt, wie sie ist.
6. **Vorschläge für die App** (nicht gebaut): (a) Feld `wissensbank.ausschnitt: true` immer dann, wenn der Text nur ein
   Teil der Seite ist, also auch bei markiertem Text ohne Bild (der Dienst liest das Feld schon; bis dahin erkennt er den
   Ausschnitt nur am Bild). (b) Semester bzw. Datum der Datei mitschicken (Stud.IP kennt beides): der einzige harte Schutz
   bei gleichem Dateinamen im nächsten Semester, wenn eine Aufgabe keine Zahlen hat.
7. **Bibliothek** (Rückmeldung an den Mac, Textvorschlag im Bericht vom 21.11.): Aufgabentext wörtlich und markiert
   aufnehmen, Verweise auf andere Abschnitte ausschreiben. Das hebt die Trefferquote bei Aufgaben; im Code lässt sie sich
   ohne Risiko nicht weiter heben.
8. Am iPad prüfen (nach dem Dienst-Update): eingekreister Absatz einer Folie des laufenden Semesters.
