# StudiNow-Wissensbank – Stand 22.11.2026 (Zweig `server/wissensbank-ki`, enthält `release/1.0.7` lokal bis `70a006c9`)

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

## Vorab-Frage, KI mit Auszügen, Antworten merken (21./22.11.2026, Zweig `server/wissensbank-ki`)

Rückmeldung des Inhabers nach dem Abgleich-Update: „meistens immer noch KI-Antwort“ und „wenn mehrere die gleiche Frage
zur gleichen Aufgabe haben, speichert man beim ersten die Antwort und gibt anderen dieselbe Lösung“.

**C. Vorab-Frage `POST /api/ai/wissensbank`** (`app/ai_relay.py`; gemischt und live seit 21.11., App-Seite in
`release/1.0.7`). Befund am iPad: Bei „ganze Seite erklären“ sieht die App zuerst in ihrem Erklärungsspeicher nach und
ruft `/api/ai/relay` nicht mehr; die Wissensbank wurde dort nie gefragt. Rumpf `{mode: "explain"|"steps", request_id,
wissensbank: {datei, kurs, seite, text, ausschnitt?}, fresh?}`. Treffer: Antwort wie eine Wissensbank-Lieferung über
`/api/ai/relay` plus `treffer: true` (1 Credit, Kontingent und Rate-Limit wie dort). Kein Treffer: Status 200,
`{treffer: false, grund, task}` ohne Kosten, ohne Verbrauch, ohne KI; `grund`: `kein_treffer`, `schon_geliefert`,
`nicht_berechtigt`, `keine_angaben`, `kontingent`, `credits`, `rate`. Im Relay hatte die Wissensbank schon Vorrang vor dem
Zwischenspeicher (jetzt durch einen Test belegt).

**A. KI mit Auszügen aus der Wissensbank** (`app/wissensbank_ki.py`, Schalter `LERNAPP_WISSENSBANK_KONTEXT`, Standard
aus). Hat der Abgleich keinen lieferbaren Treffer, sucht `suche` die bestpassenden Abschnitte: Einheiten zum
Dateititel, sonst zum Kurs; Rang über die gemeinsamen Begriffe mit dem ganzen Abschnitt, Seiten- bzw. Aufgabennummer
als Hinweis. Höchstens 2 Stellen und 6 000 Zeichen gehen als abgegrenzter Block hinter den Prompt (ohne Abgleich-Notizen,
ohne interne Kennungen), mit der Anweisung: nur verwenden, wenn es wirklich dieselbe Seite bzw. Aufgabe ist (gleiche
Zahlen und Angaben), sonst ignorieren; die Auszüge nicht erwähnen; nie eine Musterlösung behaupten. Gilt für
`tutor:explain`, `tutor:steps` und `tutor:ask`. Abrechnung wie jede KI-Antwort; Antwortfeld `wissensbank_kontext: true`
(die heutige App zeigt dafür nichts). Fest: Aufgaben gehen nur mit, wenn die Zahlen der Anfrage im Abschnitt am Stück
stehen – oder, ohne lesbare Zahlen, über Aufgabenbezeichnung und Seite (seit 22.11. abends, nächster Abschnitt); zu
einer Aufgabe gehen keine Folien mit; nur über den Kurs (Dateititel unbekannt) gilt die Schwelle 0,65 statt 0,5.

Messung der Suche (9 644 Anfragen aus den echten Kursdateien, Text wie in der App, **keine KI-Aufrufe**; „richtig“ =
dieselbe Seite/Aufgabe nach der Quelldatei bzw. dem Text der Bibliothek):

| Anfragen ohne genauen Treffer | Zahl | Auszug mitgegeben | darunter die richtige Stelle | nur andere Stellen |
| --- | --- | --- | --- | --- |
| Folie: Ausschnitt (Vision) | 136 | 78 | 61 (45 %) | 17 |
| Übungsblatt: Aufgabe eingekreist (Vision) | 178 | 14 | 9 (5 %) | 5 |
| Klausur: Aufgabe eingekreist (Vision) | 539 | 11 | 6 (1 %) | 5 |
| Lösungsdatei: Aufgabe eingekreist (Vision) | 226 | 5 | 0 | 5 |
| Aufgaben, deren Abschnitt keinen Aufgabentext hat | 316 | 6 | 1 | 5 |
| Gegenprobe: Aufgabe mit fremdem Dateinamen | 2 421 | 51 | 12 | 39 (1,6 %) |
| Gegenprobe: Aufgabe, Dateititel unbekannt | 1 452 | 7 | 1 | 6 (0,4 %) |
| Gegenprobe: Folien-Ausschnitt mit fremdem Dateinamen | 1 721 | 284 | 207 | 77 (4,5 %) |
| Gegenprobe: Folien-Ausschnitt, Dateititel unbekannt | 1 015 | 13 | 8 | 5 (0,5 %) |

Bei Folien steigt der Anteil „genauer Treffer oder richtige Stelle als Auszug“ damit von 112 auf 173 von 248 (70 %).
Von den „nur anderen“ Folien-Stellen waren in einer Stichprobe (6) drei doch die richtige (andere Seitenzählung), drei
eine Nachbarfolie zum selben Thema. Bei Aufgaben bringt A fast nichts, solange die Bibliothek keinen Aufgabentext hat;
die lockerere Regel „Dateititel + Aufgabennummer ohne Zahlen“ hätte 30 statt 9 von 178 richtige Stellen gebracht, aber
in 8,6 % der Gegenproben mit fremdem Dateinamen eine andere Aufgabe mitgegeben (verworfen). Kosten: im Mittel rund
3 700 Zeichen mehr je Anfrage mit Auszug (Median 3 400, höchstens 6 700; etwa 1 000, höchstens knapp 2 000 Tokens
Eingabe mehr), davon rund 800 Zeichen die feste Anweisung.
**Nicht gemessen:** ob die KI einen unpassenden Auszug wirklich ignoriert; das geht nur mit echten (bezahlten) Anfragen.

**B. Antworten merken** (`app/wissensbank_ki.py`, Schalter `LERNAPP_WISSENSBANK_MERKEN` = `aus` (Standard) | `freigabe` |
`sofort`). Die erste KI-Antwort zu einer Stelle wird ohne Konto und ohne Frage gespeichert (`wissensbank_gemerkt`:
Dateititel, Kurs, Modus, Seite, Aufgabenbezeichnungen, normalisierter Text des Ausschnitts, Antwort, Modell). Ein
anderes Konto bekommt sie statt einer neuen KI-Antwort (`source: "gemerkt"`, 1 Credit, `tutor:gemerkt`, kein
KI-Aufruf). Entscheidungen des Inhabers 22.11.2026: eingeschaltet wird mit `sofort`; 1 Credit für alle, die danach
kommen (der Erste zahlt seine normale KI-Antwort); übergeben wird **nur bei derselben Stelle**: gleicher Dateititel UND
gleicher Kurs UND gleiche Seite UND gleicher Modus UND gleiche Aufgabenbezeichnungen UND praktisch gleicher Text
(beidseitig ≥ 0,8 der Wortfolgen, alle Zahlen gleich). Nie über Datei- oder Kursgrenzen; ohne Dateititel oder Kurs wird
nichts gemerkt. Voraussetzung ist das Feld `wissensbank.teilbar: true` der App (nichts Persönliches in der Anfrage);
fehlt es, wird weder gemerkt noch ausgeliefert, also auch mit der heutigen App nicht. Nur `explain` und `steps`, nie
getippte Fragen, nie zweite Meinung. Dasselbe Konto noch einmal: frische KI-Antwort mit „Gefällt dir diese Antwort
besser?“; „Ja“ ist eine Stimme gegen die gemerkte Antwort, „Nein“ eine dafür; ab 2 Stimmen dagegen (und mehr als dafür)
wird sie nicht mehr geliefert und die nächste KI-Antwort tritt an ihre Stelle. Prüf-Werkzeug:
`python -m app.wissensbank_pruefen --gemerkt`, `--gemerkt-zeigen ID`, `--gemerkt-freigeben ID`, `--gemerkt-ablehnen ID`.
Eine Stelle der Bibliothek hat immer Vorrang und wird nicht gemerkt.
Gemessen an 1 651 echten Ausschnitten (nur die Regel „praktisch gleich“): zwei verschiedene Seiten derselben Datei gelten
in 1 von 3 003 Paaren als gleich, zufällige Paare aus allen Dateien in 22 von 200 000 (gleiche Folien in zwei Fassungen;
Dateititel, Kurs und Seite schließen sie zusätzlich aus). Derselbe Ausschnitt ohne seine letzte Zeile gilt nur in 39 %
der Fälle noch als gleich: Die Regel ist bewusst streng, zwei Leute müssen fast genau dasselbe einkreisen.

**Tests** (22.11.2026): `tests/test_wissensbank_ki.py` 21 grün (C, A, B; je Regel Treffer und Gegenprobe; beide Schalter
aus = Prompt und Antwortfelder wie bisher); mit `test_wissensbank.py`, `test_ai_relay.py`, `test_audit_p58_87_server.py`
147 grün; schneller Python-Lauf 4036 grün, 0 rot, 4 übersprungen, 10 abgewählt, 2 erwartet rot (5:45 min).

**Was die App dafür braucht** (nicht gebaut): `wissensbank`-Angaben auch bei `tutor:ask` schicken (für A); Feld
`wissensbank.teilbar: true` setzen, wenn im Ausschnitt/auf der Seite keine eigenen Notizen liegen, kein Notiztext, kein
Gesprächsverlauf und keine getippte Frage mitgeht (für B); Antworten mit `wissensbank_kontext` oder `source: "gemerkt"`
nicht in den geteilten Erklärungsspeicher legen; Anzeige für beide (Vorschlag: „Mit Wissen aus der StudiNow-Wissensbank“
bzw. „Gemerkte KI-Antwort“).

## Formeln, Verweise, kurze Aufgaben-Ausschnitte (22.11.2026 abends, Fehlfall des Inhabers)

**Der Fall.** Auf den Übungsfolien eines Kurses war der Kopf einer Formel-Aufgabe eingekreist: Überschrift mit
Aufgabennummer, eine Zeile „a) …“, eine Formelzeile mit ∨ und ∧. Die Bibliothek hat die Lösung (in der Einheit eines
früheren Semesters vollständig, im laufenden Semester als Verweis darauf), geliefert wurde eine normale KI-Antwort.
Gegen die echte Bibliothek nachgestellt; die Ursachen im Einzelnen:

1. **Zu wenig Wörter.** Der Ausschnitt hat drei Begriffe. Der Abgleich verlangt fünf (`MIN_BEGRIFFE`), der Weg über
   Dateititel und Nummer sechs und Zahlen, die Suche für die Auszüge (A) brach unter sechs ab.
2. **Logische Zeichen.** ∨, ∧ und ¬ wurden beim Zerlegen verworfen; die Texterkennung liefert dafür „V“, „^“, „1“, „A“
   oder nichts. Wortfolgen und Zahlenfolge der Formel passten deshalb nicht zusammen. Tiefgestellte Ziffern waren
   **nicht** das Problem (NFKC macht aus x₁ schon „x 1“).
3. **Verweise.** Der Markdown-Verweis „[G00xx, Abschnitt „Titel“](…)“ wurde nicht erkannt; „identisch mit G00xx Seite N“
   lief ins Leere, wenn die Zieleinheit die Stelle nur als Aufgaben-Abschnitt hat (keine Seiten-Abschnitte).
4. **Ungenutzte Hinweise.** Dieselbe Aufgabenbezeichnung in Ausschnitt und Abschnittskopf, und der Abschnitt nennt die
   Folien, auf denen die Aufgabe steht (in der Art „**a) (Folien 15 und 16), …**“), darunter die mitgeschickte Seite.

**Geändert** (`app/wissensbank.py`, `app/wissensbank_ki.py`; App unverändert, keine neuen Schalter):

- **Formeln** (`normalize`): ∨ → „v“, ∧ → „^“ (so, wie die Texterkennung sie liefert, wenn sie sie liest), ¬ fällt weg
  (Überstriche gehen in der Erkennung verloren), ⊕ ist ein Zeichen. Nebenwirkung, gewollt: Zwei Formeln, die sich nur
  in ∨/∧ unterscheiden, gelten im Abgleich jetzt als verschieden (vorher gleich).
- **Verweise** (`_link_target`, `_resolve`): Markdown-Verweis auf einen Abschnitt (Ziel über den Titel, sonst die
  Aufgabenbezeichnung); „identisch mit G00xx Seite N“ führt, wenn es die Seite dort nicht gibt, zu der Aufgabe, die
  diese Seite/Folie nennt (`Section.pages`: Seiten aus Überschrift, Zwischenüberschriften und fetten Marken) – nur wenn
  das Ziel eindeutig ist. Geliefert bzw. mitgegeben wird der Zielabschnitt, einmal, egal wie viele Verweise hinführen.
- **Welche Einheit gewinnt**: Verweise zeigen auf den Abschnitt mit Inhalt, der gewinnt damit von selbst. Bei gleichem
  Ergebnis entscheidet das neuere Semester (`Unit.semester` aus dem Pfad „…/WiSe_2026_27/…“); dieselbe Seite in zwei
  Semestern mit gleichem Inhalt gilt im Weg über Titel und Seite nicht mehr als Rivale, sondern die neueste wird geliefert.
- **Aufgaben-Ausschnitt ohne lesbare Zahlen – nur als Auszug an die KI (A), nie als Lieferung** (`_ueber_bezeichnung`):
  Dateititel passt UND die Überschrift im Ausschnitt nennt dieselbe Aufgabenbezeichnung wie der Abschnitt UND die
  mitgeschickte Seite ist im Abschnitt als Seite/Folie genannt (oder die Seite der Bibliothek verweist dorthin) UND von
  den Wörtern unter dieser Überschrift stehen mindestens zwei und die Hälfte im Abschnitt UND die Zahlen widersprechen
  nicht (jede größere Zahl steht im Abschnitt; ab drei Ziffern muss ihre Folge ohne 0 und 1 dort am Stück stehen, das
  trägt auch die Indizes einer Formelzeile). Steht dieselbe Bezeichnung in zwei Semestern mit verschiedenen Zahlen und
  entscheidet die Anfrage nicht, geht nichts mit. Eine Überschrift am Ende des Ausschnitts (der Kreis reicht in die
  nächste Aufgabe) zählt nur mit eigenem Text von mindestens einem Drittel des Ausschnitts.
- **Warum nicht als genaue Lieferung:** Am erkannten Text lässt sich eine Formel nicht nachprüfen. Gemessen an 24
  eingekreisten Formelzeilen mit ∨/∧: keine einzige kam vollständig richtig an; ∨ stand in 28 von 78 Fällen als eigenes
  „V“ da (sonst klebt es am Nachbarn: „a Vb“), ∧ in 4 von 18 als „^“. Dieselbe Aufgabe mit geänderter Formel im
  nächsten Semester sähe im erkannten Text gleich aus. Die KI bekommt das Bild und den Auszug und entscheidet.
- **Beim Messen gefunden und geschlossen** (Abgleich, genaue Lieferung): Über den Kurs (Dateititel unbekannt) konnte der
  eingekreiste Kopf einer Aufgabe ohne ihre Zahlen die Seite eines Blatts aus einem früheren Jahr treffen (gleicher
  Satz, andere Zahlen in Teil a). Seiten, die Aufgaben nennen, treffen über den Kurs jetzt wie Aufgaben nur noch mit
  Zahlen, die dann genau stimmen müssen. Im echten Lauf nicht aufgetreten (nur in der Gegenprobe mit vertauschter
  Nummer), aber möglich.

**Der Fall des Inhabers jetzt** (nachgestellt gegen die echte Bibliothek, Text in vier Lesarten der Texterkennung):
kein genauer Treffer (gewollt), **ein Auszug an die KI: der vollständige Abschnitt der Aufgabe** (2 404 Zeichen, ohne
interne Kennungen). Mit anderer Seite, anderer Aufgabennummer, anderen Indizes oder ohne die Überschrift: nichts.
Nicht geprüft: die Antwort der KI selbst (keine bezahlten Aufrufe) und der Weg am iPad.

**Messung** (wie oben, Text aus den echten Kursdateien, keine KI-Aufrufe; „vorher“ = Stand vor dieser Änderung).

Neuer Lauf „kurzer Ausschnitt“: Überschrift der Aufgabe plus eine oder zwei Zeilen bzw. eine Formelzeile, mit Vision
gelesen, 2 172 Anfragen aus Dateien mit bekanntem Titel:

| Kurzer Ausschnitt | Anfragen | genau vorher → jetzt | richtiger Auszug vorher → jetzt | Auszug nur einer anderen Stelle |
| --- | --- | --- | --- | --- |
| Übungsblatt/Übungsfolien | 486 | 26 → 19 | 5 → 147 (30 %) | 0 |
| Klausur | 1 188 | 5 → 5 | 2 → 91 (8 %) | 0 |
| Lösungsdatei | 498 | 0 → 0 | 0 → 28 (6 %) | 0 |
| darunter Kopf + Formelzeile | 172 | 3 → 3 | 0 → 12 (7 %) | 0 |

Drei Auszüge konnte das Prüfskript nicht bestätigen; von Hand: alle drei die richtige Aufgabe. Die Grenze ist die
Bibliothek: Nur bei 1 211 der 2 172 Anfragen nennt der Abschnitt überhaupt die Seite. Die 7 genauen Treffer weniger sind
Folien eines anderen Semesters, die über den Kurs getroffen wurden (inhaltlich richtig, durch die neue Sperre weg).

Ganze eingekreiste Aufgaben (Lauf wie am 22.11. morgens), Anfragen ohne genauen Treffer:

| Auszug mit der richtigen Stelle | vorher | jetzt |
| --- | --- | --- |
| Übungsblatt: Aufgabe eingekreist (Vision) | 9 von 178 (5 %) | 38 von 180 (21 %) |
| Klausur: Aufgabe eingekreist (Vision) | 6 von 539 (1 %) | 11 von 539 (2 %) |
| Lösungsdatei: Aufgabe eingekreist (Vision) | 0 von 226 | 7 von 226 (3 %) |
| Übungsblatt: Aufgabe markiert (PDFKit) | 16 von 170 (9 %) | 45 von 172 (26 %) |
| Ausschnitt-Block auf Folien und Blättern (Vision) | 82 von 841 | 85 von 842 |

Bei den Ausschnitt-Blöcken meldet das Prüfskript 51 statt 37 Auszüge „nur einer anderen Stelle“. Die neuen sind Auszüge
über die Aufgabenbezeichnung (die Überschrift einer Aufgabe steht im Block, das Skript vergleicht aber mit der ganzen
Seite). Alle 19 solchen Auszüge einzeln geprüft: 14 über die Wörter unter der Überschrift bestätigt, 5 von Hand – alle
die richtige Aufgabe.

Gegenproben für die Auszüge:

| Gegenprobe | Anfragen | Auszug nur einer anderen Stelle vorher → jetzt |
| --- | --- | --- |
| Ganze Aufgabe mit fremdem Dateinamen | 2 421 | 39 → 42 (1,7 %) |
| Ganze Aufgabe, Dateititel unbekannt | 1 452 | 6 → 6 (0,4 %) |
| Kurzer Ausschnitt mit fremdem Dateinamen | 2 890 | 6 → 20 (0,7 %) |
| Kurzer Ausschnitt mit der Nummer einer anderen Aufgabe | 1 168 | 4 → 5 (0,4 %) |
| Kurzer Ausschnitt, Seite um 7 verschoben | 2 172 | 2 → 6 (0,3 %) |
| Folien-Ausschnitt mit fremdem Dateinamen | 1 721 | 77 → 78 (4,5 %) |

Von Hand angesehen (jeder gemeldete Fall des kurzen Ausschnitts, 25 verschiedene): Bei fremdem Dateinamen sind 5 von 17
doch die richtige Aufgabe (Mitschrift bzw. Lösungsdatei zur selben Aufgabe, dieselbe Aufgabe in zwei Klausuren), 12 sind
die Aufgabe mit derselben Nummer auf derselben Seite aus einer anderen Klausur derselben Reihe (anderes Jahr, anderer
Termin; gleiche Fachwörter, Formeln nicht lesbar) – das ist die Restgefahr dieses Wegs, sie setzt voraus, dass ein
fremder Inhalt unter dem Dateinamen einer Einheit läuft. Vertauschte
Nummer: 5 andere Aufgaben (so konstruiert). Verschobene Seite: 2 Fälle Teilaufgabe d statt der Aufgabenstellung derselben
Aufgabe, 1 richtige Aufgabe. Zwei echte Fehlgriffe in eigenen Dateien traten in einem Zwischenstand auf (Auszug der
Folgeaufgabe, weil deren Überschrift am Ende des Ausschnitts stand) und sind durch die Regel „Überschrift nur mit
eigenem Text“ weg.

**Abgleich (genaue Lieferung), alle Läufe neu** (38 665 Anfragen wie am 21.11.): 2 299 statt 2 314 Treffer. Verloren
18 Anfragen: eine Folie, deren PDF-Text die Zeichen ∧/∨ gar nicht enthält (8), Seiten mit Aufgaben, die nur über den
Kurs getroffen wurden (9, neue Sperre; alle waren inhaltlich richtig), eine Formelzeile eines Blatts (1). Gewonnen 3:
eine Formel-Aufgabe einer Kurzklausur (2 Anfragen, von Hand: richtig) und eine Skriptseite. **Kein neuer Treffer mit
Urteil „falsch“**; in den Gegenproben (fremder Dateiname 289 Treffer, unbekannter Titel 54, vertauschte Nummer 136)
kein neuer gemeldeter Fall gegenüber dem freigegebenen Stand. Kurzer Ausschnitt: 24 genaue Treffer in eigenen Dateien, alle richtig; in den Gegenproben 9, die
4 nicht automatisch bestätigten von Hand richtig (Mitschrift bzw. Lösungshinweise zur selben Aufgabe).

**Gemerkte Antworten (B):** unverändert. Ausschnitte mit echten ∨/∧-Zeichen (markierter Text), die vor diesem Stand
gemerkt wurden, werden nicht wiedergefunden (anderer normalisierter Text); die Folge ist eine neue KI-Antwort.

**Tests** (erfundenes Fixture: Formel-Aufgabe mit eigener Formel in der Einheit des Vorjahres, laufendes Semester nur
mit Verweisen, eine Blattseite des Vorjahres): `tests/test_wissensbank.py` 91, `tests/test_wissensbank_ki.py` 23; die
neuen Tests waren vor der Änderung rot. Mit `test_ai_relay.py` und `test_audit_p58_87_server.py` 154 grün; schneller
Python-Lauf 4045 grün, 0 rot, 2 übersprungen, 10 abgewählt, 2 erwartet rot (7:27 min).

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
   ohne Risiko nicht weiter heben. Dazu seit 22.11.: in jedem Aufgaben-Abschnitt die Seiten bzw. Folien nennen, auf
   denen die Aufgabe steht (in der Überschrift oder als fette Marke, „**Aufgabe (Folie 14).**“) – nur dann kann ein
   kurzer Ausschnitt mit Formel als Auszug an die KI gehen (heute bei gut der Hälfte der Aufgaben der Fall).
8. Am iPad prüfen (nach dem Dienst-Update): eingekreister Absatz einer Folie des laufenden Semesters.
