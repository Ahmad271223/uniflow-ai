# Übergabe 21.11.2026, 15:15 – Pause auf Wunsch des Inhabers („Stand speichern, stoppen, weiter bei go“)

Ergänzt `docs/UEBERGABE-2026-11-20.md` (Regeln, Werkzeuge, Befehle stehen dort und in `UEBERGABE-2026-11-14.md`).
Dieses Repo ist öffentlich: keine Schlüssel, Namen, Tester-Adressen, Konto-Kennungen oder Bibliotheksinhalte.

## 1. Wo alles liegt

- **Arbeitsstand:** Worktree `~/Studora-Builds/wt-aufraeumen`, Zweig `release/1.0.7`, **27 Commits vor
  `origin/release/1.0.7`, NICHT gepusht** (der Inhaber wurde zweimal gefragt, ob der Zweig auf GitHub soll, und hat
  nicht geantwortet – vor dem Pushen noch einmal fragen).
- **Dienst (Hetzner):** läuft seit 21.11. 14:38 auf `bffe510f`; Wissensbank eingeschaltet (`LERNAPP_WISSENSBANK=1`),
  Bibliothek hochgeladen. Ablauf, Sicherungen, Rückweg: `docs/release/DEPLOY-DIENST-2026-11-21.md`.
- **iPad des Inhabers (Kabel):** Testfassung aus `c0784d4c` (Release, Build 46, nicht bei Apple). Das Ablauf-Protokoll
  `StiftSpur` ist dort **eingeschaltet** (Datei `Library/Application Support/StiftSpur.an` im App-Ordner) – mit der
  letzten Testfassung wieder löschen (`xcrun devicectl device … ` bzw. Datei entfernen).
- **Konto des Inhabers im Dienst:** das Apple-Konto, mit dem das iPad angemeldet ist, stand auf Hochschule
  „hildesheim“; mit seinem Okay auf „luh“ gestellt (sonst keine Wissensbank; vermutlich war deshalb auch der
  Geräteabgleich verweigert).

## 2. Heute erledigt (alles in `release/1.0.7`, lokal)

| Thema | Stand |
|---|---|
| Scrollen mit dem Finger hakt | behoben (`098b5763`: Ausschnitt der Zeichenfläche behält seine Größe), vom Inhaber am iPad bestätigt („läuft flüssig“) |
| Zurück-Pfeil nach Lasso „nur einmal“, Verschobenes „springt von selbst zurück“ | Ursache: stehende Lasso-Auswahl von PencilKit zeigte ihr altes Bild; `cbc3a22c` beendet die Auswahl vor dem Setzen der Zeichnung. Dazu `8c7a60b7`: Schritt zurück verlor Stücke radierter Striche. Inhaber: „geht, etwas wackelig, lass das so“ |
| Zähler/Protokoll am Gerät | `StiftZaehler` erweitert, `StiftSpur` (aus, solange keine Schalter-Datei) |
| Wissensbank | in `release/1.0.7` gemischt, Entscheidungen des Inhabers in `docs/WISSENSBANK-STAND.md` (Urheberrecht von ihm geprüft; Abschnitte mit Lösungen der Lehrenden bleiben drin; interne Abgleich-Notizen werden nicht ausgeliefert; Probe-Konten unverändert) |
| Wissensbank mit Bild | `bffe510f`: auch bei „Bereich an KI“ (App schickt den im Ausschnitt erkannten Text) |
| Speicher-Absicherung ≤ 4 GB | gemischt (`25326a06`), `docs/SPEICHER-STAND.md`; 71 Editor-Tests grün |

Tests auf dem Weg: Python voll 4008 bestanden (auf `bffe510f`); Editor-Auswahl im Simulator „fix-tinte“ mehrfach
grün. **Der volle App-Lauf (`UniFlowTests` komplett), der volle Swift-Kern-Lauf und der iPhone-Lauf für Build 46
stehen noch aus.**

## 3. Offen – in dieser Reihenfolge weitermachen

1. **Wissensbank trifft im echten Betrieb kaum.** Gemessen (pypdf-Text echter Kursdateien vom Mac des Inhabers,
   Dateien, deren Titel in der Bibliothek stehen): 7 Treffer auf 93 Seiten; Übungsblätter des laufenden Semesters gar
   nicht. Der Inhaber fragt immer über „Bereich an KI“ (eingekreister Ausschnitt): Protokoll vom Gerät „Anhang area,
   299 Zeichen erkannter Text, App schickt Angaben: ja → keine Wissensbank-Felder“. Gründe: getrennte Umlaute aus
   LaTeX-PDFs, Aufgaben ohne Aufgabentext in der Bibliothek, Jaccard-Bedingung gegen die ganze Folie bei Ausschnitten,
   Texterkennung statt Textebene. Die „594/600“ in älteren Notizen waren keine Messung mit echtem PDF-Text.
   Vorgabe des Inhabers: lieber kein Treffer als eine falsche Lösung (gleicher Dateiname in anderen Semestern,
   vertauschte/umnummerierte Aufgaben).
   **Helfer dazu war mitten in der Arbeit** (Zweig `server/wissensbank`, Worktree
   `~/uniflow-ai/.claude/worktrees/agent-aedd46a702278d434`; Zwischenstand und Zahlen:
   `~/Studora-Builds/fix-wissensbank-logs/STAND-PAUSE.md`, sofern er sie noch geschrieben hat). Danach: mischen,
   Python voll, drittes Dienst-Update **nur mit Okay**, Test am iPad mit den vom Helfer genannten Stellen.
2. **Bild einfügen bei geöffneter Notiz daneben** (Meldung des Inhabers 21.11.): Bild landet nur im Hauptdokument,
   lässt sich nicht kleiner ziehen, „verschwindet“ beim Ziehen, verzerrter blauer Rahmen. Ursachen im Code:
   `DocumentView.insertPicked` nutzt immer den Editor des Hauptdokuments; `ObjectEditing` kennt nur Pinch zum Skalieren
   (Rahmen ohne Vorschau), keine Begrenzung auf die Seite. **Helfer dazu war mitten in der Arbeit** (Zweig
   `app/bild-in-notiz`, Worktree `~/Studora-Builds/wt-bild-notiz`; `~/Studora-Builds/fix-bild-logs/STAND-PAUSE.md`).
   Sichtbare Editor-Änderung: vor Auslieferung dem Inhaber per Kabel zeigen.
3. **Woher weiß man, was in der Bibliothek ist?** Frage des Inhabers, noch nicht beantwortet von ihm: Übersicht auf dem
   Mac (je Fach die Dateien) und/oder später ein Zeichen in der App.
4. **Speicher, offen:** Sichern/Öffnen sehr großer Dokumente (ab ~60 000 Strichen über 1 GB) – gemessen, nicht
   behoben (`docs/SPEICHER-STAND.md`, Abschnitt 6.1); große Seiten auf großen Geräten.
5. **Kleines:** Meldung „n ungesendete Seite(n) wiederhergestellt“ bleibt bis zum Schließen stehen (Inhaber gefragt,
   ob sie nach dem Hochladen verschwinden soll – keine Antwort). „Schreiben wirkt wackelig“: Inhaber sagte „lass das
   so“. Frage aus der alten Übergabe: wo es am Mac ruckelt.
6. **1.0.7 abschließen:** volle Tests (Python, Kern, App iPad + iPhone), `BUILD-HERKUNFT.md`/`APP-STORE.md` nachführen
   (Inhalt von Build 46 hat sich geändert: Wissensbank, Speicher, Editor-Korrekturen; `StiftSpur` erwähnen),
   Datenschutz/AGB-Entwurf zur Wissensbank prüfen (`docs/release/ENTWURF-1-0-7.md` führt die Musterlösungs-Frage noch
   als offen), Build 46 archivieren und hochladen, Website-Upload-Befehl an den Inhaber, einreichen – Einreichen,
   Dienst-Update, alles Öffentliche nur mit ausdrücklichem Okay.

## 4. Hinweise aus dem Tag

- Simulatoren: Hauptsitzung „fix-tinte“ (`A9F6FD9D…`) mit `~/Studora-Builds/dd-aufraeumen`; Kabel-Build
  `~/Studora-Builds/dd-tester-107` (Skript der Sitzung: Release, `generic/platform=iOS`, dann
  `xcrun devicectl device install app --device 00008120-000E309830814032 …/Release-iphoneos/UniFlow.app`).
- Unter Last (mehrere xcodebuild zugleich) scheitern Editor-Tests mit „kein Overlay in 20 s“ / `InvalidTransition`:
  einzeln wiederholen. In frischen Simulator-Klonen sind vier Lasso-Tests (`LassoHaengerTests`) wegen einer 69 pt
  hohen Tastaturleiste rot (Befund des Speicher-Helfers), im Simulator „fix-tinte“ grün.
- Vom Gerät lesen (nur Zahlen/Ereignisse, kein Inhalt): `xcrun devicectl device copy from --device <UDID>
  --domain-type appDataContainer --domain-identifier de.uniflow.ai --source "Library/Application
  Support/StiftSpur.txt" --destination <Datei>` (ebenso `StiftZaehler.json`).
- Der Inhaber arbeitet in der KI-Hilfe über „Bereich an KI“ (Einkreisen), nicht über „Erklären“ zur ganzen Seite.

## 5. Zwischenstand der beiden Helfer (beide angehalten, 15:30)

- **Wissensbank-Abgleich:** `server/wissensbank` @ `894bcc1f` (`[WIP]`, nur `app/wissensbank.py`), Notiz
  `~/Studora-Builds/fix-wissensbank-logs/STAND-PAUSE.md`, Messung unter `…/messung/`. **Nicht ausrollbar:** In den
  Gegenproben des letzten Laufs zählt das Prüfskript 25 neue „falsch“, die noch nicht von Hand angesehen sind (im Lauf
  davor waren 6 von 21 echte Falsch-Treffer, dagegen kamen zwei Sperren). Keine Tests für die neuen Regeln, Stand-Dokument
  nicht nachgeführt. Gemessen mit PDFKit/Vision wie in der App (am Mac): Folien-Ausschnitt 15,7 % → 45,6 %, ganze Folie
  20,7 % → 49,3 %, eingekreiste Aufgabe eines Übungsblatts 18,9 % → 20,7 %, Klausuraufgabe 1,3 % → 1,6 %. Hauptgrund bei
  Aufgaben liegt in der Bibliothek: 6 927 von 11 252 Aufgaben-Abschnitten haben keinen Aufgabentext. „594/600“ vom
  20.11. war mit dem Text der Bibliothek selbst gefragt. Vorschläge für die App: Feld `wissensbank.ausschnitt`,
  Semester/Datum der Datei mitschicken (Schutz bei gleichem Dateinamen im nächsten Semester).
- **Bild in der Notiz daneben:** `app/bild-in-notiz` @ `7f5d5726` (`[WIP]`, baut), Worktree `~/Studora-Builds/wt-bild-notiz`,
  Notiz `~/Studora-Builds/fix-bild-logs/STAND-PAUSE.md`. Laut Bericht alle vier Punkte im Simulator nachgestellt und
  behoben (aktiver Editor `EditorToolState.activeEditor`, Objektmodus „Auswählen“/Lasso auch im Dokument daneben, vier
  Anfasser, Begrenzung auf die Seite). Abschlusslauf auf dem Endstand abgebrochen (61 grün, 0 rot; mehrere Klassen
  fehlen). Nicht gemischt, nicht am iPad gezeigt.

## 6. Nachtrag 22.11.2026 mittags

- Dienst läuft auf `07e26fea`: Wissensbank mit verbessertem Abgleich, Vorab-Frage für „Seite erklären“, KI mit Auszügen
  (`LERNAPP_WISSENSBANK_KONTEXT=1`) und gemerkte KI-Antworten (`LERNAPP_WISSENSBANK_MERKEN=sofort`); alles in
  `docs/release/DEPLOY-DIENST-2026-11-21.md` (Punkte 9 bis 11). Rückmeldung des Inhabers: „KI-Antwort passt immer“.
- Bild in der Notiz daneben samt Hinüberziehen ist in `release/1.0.7` und vom Inhaber am iPad bestätigt.
- In Arbeit (Helfer, Zweig `server/wissensbank-ki`): Formel-Aufgaben und Verweise im Abgleich – echter Fehlfall
  `uebung3.pdf` (Grundlagen digitaler Systeme), Seite 25, Aufgabe 4.1.5: Lösung steht in der Bibliothek, der Dienst fand
  sie nicht. Danach sechstes Dienst-Update nur mit Okay.
- Entscheidung des Inhabers 22.11.: eigene KI (ChatGPT/Claude/Gemini) in der Spalte neben dem Dokument erst in der
  nächsten Version nach 1.0.7; vor dem Bauen Tarif, Liste der Seiten und Verhältnis zu „KI über mein ChatGPT“ klären.
- Vor der Veröffentlichung von 1.0.7 noch nötig: Datenschutz/AGB um Wissensbank, KI mit Auszügen und gemerkte Antworten
  ergänzen und vom Inhaber freigeben lassen (Textvorschläge in `docs/WISSENSBANK-STAND.md`), Website-Upload durch ihn;
  volle Testläufe (App iPad/iPhone, Swift-Kern), Unterlagen für Build 46; `StiftSpur` auf dem iPad wieder ausschalten;
  Frage GitHub-Push ist weiter offen.
- 22.11.2026 nachmittags: Rechtstexte zur Wissensbank vom Inhaber freigegeben (Datenschutz 8e, Nutzungsbedingungen 5a,
  Stand 22.11.2026, `1827a391`) und von ihm auf die Website hochgeladen – auf studinow.app geprüft (beide Seiten Stand
  22.11.2026, Abschnitt 8e vorhanden). Damit sind auch die übrigen 1.0.7-Texte (Mensa, Klausur-Generator, Prüfungen im
  Geräteabgleich) online. `release/1.0.7` liegt seit 22.11. auf GitHub (Okay des Inhabers), weitere Commits werden
  dorthin nachgezogen. Hinweis „ungesendete Seite(n) wiederhergestellt“ blendet sich nach dem Senden aus (`70235f08`).
  Offen aus dem Lesen der Texte: In Datenschutz 8c fehlt, dass bei „Bereich an KI“ das Bild des Ausschnitts an die KI
  geht (Vorschlag dem Inhaber angeboten, keine Antwort bisher).
- 22.11.2026 nachmittags (2): `server/wissensbank-ki` @ `52258f1b` eingemischt (`f8292e11`: Formel-Aufgaben als Auszug an
  die KI, Verweise auf Aufgaben-Abschnitte, neueste Einheit; Bericht in `docs/WISSENSBANK-STAND.md`). **Noch nicht auf
  dem Server** (sechstes Update nur mit Okay). Offene Entscheidung des Inhabers: Weg über die Aufgabenbezeichnung für alle
  Aufgaben-Ausschnitte ohne lesbare Zahlen (so gebaut) oder nur für sehr kurze (unter 6 Begriffen).
- Lösungen anderer nur noch neben dem Dokument (`2d02c085`, Auftrag des Inhabers am iPad, Einzelheiten im Nachtrag von
  `docs/LOESUNGEN-TEILEN.md`); Vorschau zeichnet die Handschrift wie der Editor. Testfassung per Kabel auf dem iPad,
  Rückmeldung des Inhabers steht aus. Kern-Lauf komplett grün auf `7c1e81a4` (1773 Tests); der komplette App-Lauf lief auf
  `7c1e81a4` und muss auf dem Endstand wiederholt werden.
- Frage des Inhabers „500 / 2000 / 4000 / 6000 neue Nutzer morgen?“: Berichte der Helfer in
  `~/Studora-Builds/kapazitaet-logs/` (Kosten und fremde Dienste fertig; Server-Auslegung und Lastmessung am Mac liefen
  noch). Der echte Server wurde dafür nicht angesehen (Zugriff eines Helfers per ssh wurde nicht erlaubt).
- 22.11.2026 13:57: sechstes Dienst-Update auf `12aa93b0` ausgerollt (Okay des Inhabers), siehe
  `docs/release/DEPLOY-DIENST-2026-11-21.md` Punkt 12. Der Dienst läuft damit auf dem Stand von `release/1.0.7`.
- Kompletter App-Lauf (`UniFlowTests`, iPad-Klon) auf `7c1e81a4`, 22.11.2026: 2160 Tests, 57 übersprungen, 5 rot. Vier
  davon sind die bekannten Lasso-Tests im frischen Klon (`EditorStrichBleibtTests`, Tastaturleiste) – im Simulator
  „fix-tinte“ auf `2d02c085` alle grün (44 Tests, Nachlauf). Der fünfte, `IPhoneStoreScreenshotTests.test02Stundenplan`
  („Kurztest“ fehlt), war auch im Nachlauf rot: Die Testdaten legen den Kurztest auf „morgen“, der 22.11. ist ein
  Sonntag, der Stundenplan zeigt die Woche 16.–22.11. – der Hinweis liegt damit in der nächsten Woche (Einschätzung,
  am Montag gegenprüfen). **Vor Build 46 den kompletten App-Lauf und den iPhone-Lauf auf dem Endstand wiederholen**
  (seit `7c1e81a4` kam `2d02c085` dazu).
- 22.11.2026 15:25, Server nur lesend geprüft (Okay „Ja, nur lesen“): gesund, 273 GB frei, App 843 MB von 8 GB,
  KI-Budgets 600 € zahlend / 200 € Probe, Verbrauch November zusammen 0,57 €, 22 Konten. 25 Speicherabbrüche, alle in
  der Lasttest-Nacht 09.11.; seitdem keine. Einzelheiten im Nachtrag von `~/Studora-Builds/kapazitaet-logs/BERICHT-SERVER.md`
  (Berichte zu Kosten und Lastmessung daneben). Offen beim Inhaber: Höhe des Probe-Budgets für den Ansturm.

- 22.11.2026: Inhaber entscheidet „Bei 200 € lassen“ (Probe-Budget `LERNAPP_AI_TRIAL_BUDGET_EUR` bleibt 200).
