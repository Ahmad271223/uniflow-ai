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
