# iPad Build 28 und Windows/Web: Bestandsaufnahme (09.11.2026)

Auftrag des Inhabers vom 09.11.2026: "Windows-App und Mac auf gleichen Stand wie iPad Build 28, komplett, und
kompatibel. Diskussionen, Community müssen überall gleich sein."

Diese Datei ist Teil 1, die Bestandsaufnahme für die Windows-App und die Web-App (app.studinow.app). Beide nutzen
dieselbe Oberfläche (`app/static/*.js`) und dasselbe Python-Backend (`app/`).

- Windows ist die Tauri-Hülle `apps/windows`, das Backend läuft im PC-Modus.
- Das Web ist der Dienst im Modus `LERNAPP_MODE=hosted`.

Grundlage der Prüfung:

- iPad Build 28 ist Commit `7d1a8fb3`.
- Geprüft wurde am Code auf `develop` `574a2603`. Für `apps/apple` ist das derselbe Stand.
- Die älteren Dateien `docs/paritaet/*.md` und `docs/FERTIGSTELLUNG-WINDOWS-UND-DIENST.md` sind veraltet (Stand
  25.–27.10.). Sie wurden nicht übernommen, sondern am Code nachgeprüft.
- Teil 2 (Lücken schließen) ist auf Anweisung vom 09.11. zurückgestellt, zuerst kommt der Mac. In diesem Zweig wurde
  **kein Code geändert**.

Feste Entscheidungen, die hier nicht als Lücke zählen:

- Der Dienst speichert keine Hochschul-Passwörter (seit 06.11.). Deshalb hat das Web absichtlich keinen QIS- oder
  Stud.IP-Login und keinen Hochschul-Abgleich (`jobs.HOSTED_UNI_SYNC=False`). Aus demselben Grund fehlen dort
  Nachrichten, Uni-Mail, Bescheinigungen und Prüfungsanmeldung.
- Die Windows-App gleicht die Hochschule selbst ab, auf dem PC.
- Credits: Free 0, Probe 25, Plus 0, Pro AI 100. 1 Credit = 0,9 ct.
- In 1.0 ist nur die LUH dabei.

Zeichen in den Tabellen:

- **KOMPAT**: Daten, die ein Gerät schreibt, sind auf dem anderen nicht lesbar, werden dort nicht angezeigt oder
  werden überschrieben.
- **UI**: Die Oberfläche fehlt oder weicht ab. Die Daten sind nicht betroffen.
- Aufwand: S = bis ½ Tag, M = 1–2 Tage, L = mehr.

## 1. Übersicht

| Bereich | Web/Windows | Art | Aufwand |
|---|---|---|---|
| Navigation, Gruppen, Einträge | vorhanden, gleich | – | – |
| Untere Leiste "Mehr" | führt im Web direkt zu den Einstellungen statt zur Liste der übrigen Bereiche | UI | S |
| Übersicht (Klausuren, Mensa, Zuletzt, Neuigkeiten, Woche) | vorhanden; es fehlen die Karten "Heute an der Uni" und "Abgaben & Prüfungen"; Kennzahlen anders aufgebaut | UI | S–M |
| Module, Lernstand, Wochentests, Stud.IP-Texte | vorhanden, gleich | – | – |
| Vorlesungsaufzeichnungen (Opencast), "Videos & Links" | fehlen | UI | L |
| ZIP als Ordner öffnen | fehlt | UI | M |
| Stundenplan, Termin-Ausnahmen, Stud.IP-Rückfragen | vorhanden, gleich | – | – |
| Editor-Werkzeuge (Stifte, Formen, Lineal, Text, Lasso, Pinch-Zoom, Seiten, Suche, Seitennotizen, Fixieren) | vorhanden, gleich; das Web hat zusätzlich Bild einfügen, Zoom-Fenster und Drucken | – | – |
| Schreibhand: Lage der Spalte daneben | Regel vorhanden (16e9dbe3) | – | – |
| Schreibhand: Einstellung zwischen den Geräten | iPad: `uniflow.hand` in UserDefaults; Web: `settings.hand`, abgeglichen | **KOMPAT** (Teil iPad) | S |
| Schreibhand: Seitenleiste auf der Seite der freien Hand | das Web nutzt eine eigene Einstellung (`ed-prefs.sidebar`) | UI | S |
| Seiten tauschen (lange drücken/ziehen, Menü, Bedienungshilfe, je Paar gemerkt) | fehlt | UI | M |
| Blatt daneben (leeres Blatt, Vorlage) und Verknüpfung `sideSheets` | fehlt; das Web öffnet daneben nur PDFs und schreibt `sideSheets` nie | UI, teils KOMPAT | M |
| Notizfläche `note` am Dokument | nur im Web; das iPad zeigt sie nicht an, verwirft sie aber nicht | **KOMPAT** (Teil iPad, nur Anzeige) | S |
| Studienverlauf: Sperrregel | gleich (637f2aef) | – | – |
| Studienverlauf: Sperrgrund und ehrliche Rückmeldung | fehlen | UI | S |
| Lernkalender, Lernplan, Nachholen, Vorschlag | vorhanden, gleich | – | – |
| Lernplan nach dem Abgleich: nur neue Dokumente einordnen | Windows plant die Woche neu | **KOMPAT** | M |
| KI-Lernplan ("KI-Vorschlag") | fehlt | UI | M |
| Abgaben & Prüfungen als Liste, "Uhrzeit ändern" | fehlen (nur das Chip-Detail) | UI | S |
| Karteikarten, Stapel, Frei üben | vorhanden, gleich | – | – |
| Tests & Wiederholung | vorhanden, gleich; Tests werden nicht abgeglichen, auch am iPad nicht | – | – |
| KI-Hilfe (Start, im Dokument) | vorhanden, gleich; Bereich oder ganze Seite an die KI schicken fehlt im Web | UI | S |
| Mensa | vorhanden, gleich | – | – |
| Raumfinder | vorhanden, gleich (Apple Karten nur am iPad) | – | – |
| Uni & Noten / QIS | Windows vorhanden; Web absichtlich nicht | – | – |
| Prüfungsanmeldung: Knopftext | gleich ("Im QIS/LSF zur Prüfung anmelden") | – | – |
| Prüfungsanmeldung: Abruf nach der Rückkehr aus dem Browser | fehlt; abgerufen wird nur über den Knopf "abrufen" | UI | S |
| Nachrichten, Uni-Mail, Lehrende, Bescheinigungen | Windows gleich; Web absichtlich nicht | – | – |
| Zeitmesser | im Web vorhanden; am iPad in Build 28 ausgeschaltet | – | – |
| Community (Lösungen, Kommentare, Fragen, Korrekturen, Gruppen, Stapel, Wochentests) | eigene Community im Dienst; das iPad nutzt CloudKit | **KOMPAT** (Kern iPad) | L |
| Einstellungen | weitgehend gleich; Schlüssel `hand` und `rufname` passen nicht zusammen; das iPad gleicht `exam_registration_run` ab | **KOMPAT** (Teil iPad) | S |
| Konto (E-Mail, Apple, Export, Löschen, Sitzungen) | gleich; das Web hat zusätzlich Google | – | – |
| Probe-Anzeige | gleiche Quelle (`trial.ends_at` des Dienstes); im Web nur auf der Abo-Seite und der Übersicht (hosted), nicht in Seitenleiste und Einstellungen; Texte weichen ab | UI | S |
| Credits je Tarif | gleich (0/25/0/100); der iPad-Text sagt "1 Credit ist 1 Cent", richtig ist 0,9 ct | Text (iPad) | S |
| Onboarding | andere Reihenfolge; Rufname anders gespeichert | UI, KOMPAT über `rufname` | S |
| Demo | gleich (nur Windows, nie hosted) | – | – |

## 2. Kompatibilität (zuerst zu beheben)

### K1 Community getrennt (Kern am iPad, betrifft alle Geräte)

Auf dem iPad ist der Weg über den Dienst ausgeschaltet: `StudoraAccountLink.communityViaService = false`
(`apps/apple/UniFlow/Services/StudoraAccountLink.swift:203`). Laut Kommentar gilt das seit dem Gerätetest am 07.11.
Seitdem läuft die Community am iPad für alle über die öffentliche CloudKit-Datenbank (`CommunityCloudKit.swift`,
`CardStackCloudKit.swift`, `WeeklyTestCloudKit.swift`).

Web und Windows nutzen den Dienst. Windows leitet `/api/community/...` mit dem Konto-Token dorthin weiter
(`app/server.py:192-206`, `app/service_link.py:438-457`).

Folgen:

- Was am iPad geschrieben wird, sieht man im Web und unter Windows nicht, und umgekehrt.
- Es gibt keine Brücke zwischen CloudKit und dem Dienst.
- Die Vorgabe "Diskussionen, Community müssen überall gleich sein" ist damit heute nicht erfüllt.

| Objekt | iPad | Web/Windows |
|---|---|---|
| Lösungen, Kommentare, Likes | CloudKit `Solution`, `Comment`, `Like` | Dienst `/solutions`, `/solutions/{id}/comments`, `/like` (`app/community_api.py:54,145-179`) |
| Fragen & Antworten je Modul | CloudKit `Comment` mit einer Antwortebene | Dienst `/courses/{key}/questions` mit Abstimmen, "Als Lösung markieren", Lesezeichen und Mitteilungen (`community_api.py:247-358`, `views-qa.js`) |
| Korrekturen | CloudKit `Correction`; Gesehen/Ignorieren nur auf dem Gerät | Dienst `/corrections`, Status im Dienst |
| Communitys, Lerngruppen | CloudKit `StudyGroup` | Dienst `/communities`, `/groups` |
| Melden, Sperren, Moderation | CloudKit `Report`, `Block`, `Ban` | Dienst `/report`, `/blocks`, `/moderate` |
| Geteilte Stapel, Wochenstapel | CloudKit `CardStackShare`, `WeekCardStack` | Dienst `community_cards`, `shared_card_stacks` |
| Gemeinsame Wochentests | CloudKit `WeeklyTest` | Dienst `/api/v2/shared-tests` |

**Weg dorthin:** Alle Geräte nutzen den Dienst.

- Den iPad-Client gibt es schon: `ServiceCommunityService` (`UniFlowCore/Solutions/ServiceCommunity.swift`). Er wird
  aber nicht benutzt.
- Ihm fehlen Fragen und Antworten (`/courses/{key}/questions`). Daran ist der Gerätetest am 07.11. gescheitert.
- Für Nutzer ohne StudiNow-Konto ist eine Entscheidung nötig: Konto-Pflicht für die Community oder ein Übergang.
- Die Arbeit liegt überwiegend am iPad (Zweig `paritaet/community-sync-b28`). Web und Windows brauchen nur, was
  dabei als fehlend auffällt.
- Aufwand: L.

**Entscheidungen aus Commit 6859265f:**

- **P42-05:** Fremde Kommentare unter der eigenen Lösung heißen am iPad "Ausblenden", weil CloudKit sie nicht
  löschen kann. Mit dem Dienst ist "Löschen" richtig. So macht es das Web heute, und so sieht es auch die iPad-Regel
  `commentRemoval(accountService:)` vor.
- **P43-06:** Das Übernahme-Kontingent zählt im Dienst je Konto, der Monat gilt in Europe/Berlin
  (`community_cards_api.py:64-68,323-341`). Solange die Stapel getrennt liegen, zählt derselbe Stapel am iPad und im
  Web doppelt.

### K2 Lernplan: Windows plant nach dem Abgleich die Woche neu

**iPad (seit 994377ea):** `StudyPlan.insertNewFiles`
(`UniFlowCore/LocalBackend/Study/StudyPlanInsert.swift:36-116`, Tabelle `study_plan_seen_files`).

- Neue Dokumente kommen einzeln in freie Lücken: ab morgen, nicht vor ihrer Lehrwoche, vor der Klausur des Moduls.
- Alles, was schon im Plan steht, bleibt unverändert.

**Windows:**

- `_full_sync` ruft `study.auto_plan_week(conn, len(new_files))` auf (`app/server.py:985`).
- `auto_plan_week` ruft `generate_packages(..., replace=True)` auf (`app/study.py:857-869`).
- Dabei werden alle automatisch erstellten, nicht begonnenen Pakete gelöscht und für heute bis Sonntag neu geplant.
  Gemeint sind Pakete mit `generated=1`, bei denen alle Aufgaben "geplant" sind und kein `moved_from` gesetzt ist
  (`study.py:505-588`).

**Warum das KOMPAT ist:**

- `study_packages` und `study_tasks` werden abgeglichen (`app/sync.py:37-38`).
- Die Pakete, die das iPad eingeordnet hat, tragen `generated=1`. Für Windows sind sie deshalb ersetzbar.
- Ein Windows-Abgleich mit neuen Dateien löscht diese Pakete (die Tombstones erreichen das iPad) und legt neue an,
  mit neuen IDs und neuen Uhrzeiten.
- Verschobenes, Nachgeholtes und Begonnenes bleibt erhalten.

**Lösung:**

- `insert_new_files` mit denselben Regeln in `app/study.py` nachbauen, mit einer eigenen Tabelle der bekannten
  Dateien.
- Ein gemeinsamer Fall-Satz unter `packages/shared-contracts/fixtures` hält die Regeln für Swift und Python fest.
- `auto_plan_week` bleibt nur für den ersten Lauf ohne Plan.
- Aufwand: M.

### K3 Einstellungsschlüssel (Teil iPad)

**`hand`**

- Das Web speichert `settings.hand`, der Wert wird abgeglichen (`app/static/views-misc.js:833`).
- Das iPad liest und schreibt im lokalen Modus nur UserDefaults `uniflow.hand` (`DocumentView.swift:161`,
  `SettingsPage.swift:649,1013,1054`).
- Folge: Die Schreibhand wandert nicht zwischen iPad und PC.
- Lösung am iPad: den Wert in die lokale `settings`-Tabelle schreiben und von dort lesen. Aufwand S.

**`rufname`**

- Das Web speichert `settings.rufname`, der Wert wird abgeglichen (`views-misc.js:834`, Onboarding).
- Das iPad speichert `uniflow.greeting.rufname` in UserDefaults (`UFGreeting.swift:63`).
- Lösung wie bei `hand`. Aufwand S.

**Lokale Schlüssel**

- Windows hält zehn Schlüssel lokal (`app/sync_client.py:41`), das iPad nur fünf (`DeviceSync.swift:220`).
- Das iPad gleicht deshalb `exam_registration_run`, `messages_seen_up_to`, `studip_reply_drafts`, `studip_replies`
  und `studip_submissions` ab. So überschreibt ein Gerät den Gerätestand des anderen.
- Lösung: beide Listen gleich machen, am besten aus einer gemeinsamen Datei. Aufwand S.

### K4 Notizfläche und Blatt daneben (nur Anzeige)

- **Feld `note`:** Das Web schreibt es am Dokument (`views-doc.js:33,46`). Das iPad zeigt es nicht an, behält es aber.
  Es geht also nichts verloren, man sieht es am iPad nur nicht.
- **`sideSheets`** (Verknüpfung von der Folie zum Blatt daneben): Nur das iPad schreibt das Feld. Das Web liest es und
  behält es (`side-notes.js:3-6`), legt aber selbst keine Verknüpfung an.

## 3. Build-28-Änderungen, die der Inhaber am iPad getestet hat

### Schreibhand: Spalte daneben auf der Seite der Schreibhand (5160860b)

- **Web/Windows heute:** Die Regel ist umgesetzt (`doc-nav.js:37-54`, `views-doc.js:83`, Commit 16e9dbe3), Test
  `tests/js/split-sides.test.mjs`. Das Web zählt zusätzlich `whiteboard` und `ueb\d` als Schreibblatt.
- **Offen:** Die Seitenleiste folgt nicht der Schreibhand, sie hat eine eigene Einstellung `ed-prefs.sidebar`
  (`editor.js:80,936`). Zum Schlüssel der Schreibhand siehe K3.

### Seiten tauschen: Kopfzeile lange drücken oder ziehen, Menü, Bedienungshilfe, je Paar gemerkt (5160860b, 4e9aea98)

- **Web/Windows heute:** fehlt. `views-doc.js:49-89` hat nur den Griff für die Breite.
- **Offen:** nachbauen, mit demselben Gedächtnisformat wie am iPad (`SplitSides.swift:12-14,53-64`):
  - Zeilen `"<primaryId>|<sideId>"` bzw. `"<primaryId>|loesung:<id>"`
  - höchstens 100 Einträge, die ältesten fallen heraus
  - gerätelokal wie am iPad, z. B. in localStorage `uniflow.splitSwapped`
- Aufwand M.

### Studienverlauf: Angemeldetes und Bestandenes gesperrt, mit Grund (07254389)

- **Web/Windows heute:** Die Regel ist gleich: `movable` (`study-plan-logic.js:566`). Ziehen geht nur bei
  verschiebbaren Karten.
- **Offen, Sperrgrund:** Die Texte des iPads stehen in `StudyPlanModel.swift:730-732`. Im Web fehlt der Grund:
  - im Menü: Gesperrte Module haben gar kein Menü (`:952`)
  - im Detail (`study-plan.js:533-537`)
  - für Screenreader (`moduleLabel`, `:125-133`)
  - auf der Karte: Bestandenes hat nur den Tooltip "Bestanden – bleibt im Semester aus QIS" (`:276`), Angemeldetes gar
    nichts
- **Offen, Rückmeldung:** `moveMessage` (`:660-673`) meldet immer "verschoben". Es prüft nicht, ob das Modul wirklich
  im Ziel liegt; das iPad tut das (`StudyPlanPage.swift:619-625`).
- Aufwand S.

### Probe-Anzeige aus einer Quelle (3992573b)

- **Web/Windows heute:** Die Daten kommen aus derselben Quelle: `trial.days_left` und `ends_at` (`billing.py:397-408`).
  Die Leiste nutzt `access.trial_days_left` (`access.py:82`, `account-gate.js:56`).
- **Offen:** Das Web zeigt die Probe nur auf der Abo-Seite (`views-abo.js:75`) und auf der Übersicht im Dienst
  (`trial-hint.js:20`). In Seitenleiste und Einstellungen fehlt sie, und die Texte weichen ab.
- Aufwand S.

### Lernplan: nur neue Dokumente einordnen (994377ea)

- **Web/Windows heute:** Windows plant die Woche neu.
- **Offen:** siehe K2. Aufwand M.

### Knopf "Im QIS/LSF zur Prüfung anmelden" (7e175276)

- **Web/Windows heute:** Der Text ist gleich (`exam-registration-logic.js:10,45,100`,
  `exam_registration_api.py:84-87`). Nur der Kommentar in `exam-registration.js:5` ist veraltet.
- **Offen:** Windows soll einmal abrufen, wenn der Nutzer nach dem Klick zurückkommt (`focus`/`visibilitychange`), so
  wie das iPad nach dem Schließen des Browsers. Das betrifft nur Windows; das Web hat absichtlich keine
  Prüfungsanmeldung.
- Aufwand S.

### Strich sofort gesichert (P60-F1, f5a31bf8)

- **Web/Windows heute:** Das ist iPad-intern (`ink/`). Im Web nicht nötig, dort speichert der Server.
- **Offen:** nichts.

### Erledigung beim Abgleich (P73-F6, a6d25a73)

- **Web/Windows heute:** Windows sendet `changed` (`app/sync_client.py:411`). Der Dienst führt nur diese Felder
  zusammen (`app/sync.py`).
- **Offen:** nichts, erledigt.

## 4. Was nur im Web/Windows fehlt (reine Oberfläche)

| Funktion | iPad-Stelle | Aufwand |
|---|---|---|
| Vorlesungsaufzeichnungen (Opencast) je Modul und eigene Aufnahme auf Modulebene; das Web hat nur Audio-Notizen im Dokument | `RecordingsViews.swift`, `LectureRecorderViews.swift` | L |
| Bibliothek "Videos & Links" | – | M |
| ZIP als Ordner öffnen und bearbeiten | – | M |
| Blatt daneben als leeres Blatt oder Vorlage, nicht nur PDF (`views-doc.js:186` filtert `.pdf`) | – | M |
| KI-Lernplan "KI-Vorschlag" | `Plan/AIPlanDialog.swift`, Kern `AIPlanEndpoints.swift` | M |
| Bereich oder ganze Seite an die KI schicken | `DocumentView.swift:452-454` | S |
| Liste "Abgaben & Prüfungen" mit "Uhrzeit ändern", Karte "Heute an der Uni" | `Due/DueViews.swift:40,171,200` | S |
| Treffer in Aufnahmen bei der globalen Suche | – | S |
| Liste "Mehr" in der unteren Leiste | – | S |

Umgekehrt gibt es manches nur im Web und nicht am iPad (wichtig für den Mac-Zweig):

- Bild einfügen, Zoom-Fenster, Drucken
- PDF-Seiten importieren
- Google-Anmeldung
- Zeitmesser (am iPad in Build 28 ausgeschaltet, `StudyTimer.isEnabled = false`)

## 5. Reihenfolge für Teil 2

1. K2: Lernplan-Einordnen in Python nachbauen, mit gemeinsamem Fall-Satz (Windows; M).
2. K3: Einstellungsschlüssel und lokale Schlüssel angleichen (iPad und `sync_client.py`; S).
3. Studienverlauf: Sperrgrund und ehrliche Rückmeldung im Web (S).
4. Seiten tauschen im Web (M), Seitenleiste nach der Schreibhand (S).
5. Probe-Anzeige in Seitenleiste und Einstellungen des Web (S).
6. Prüfungsanmeldung: Abruf nach der Rückkehr (Windows; S).
7. K1: Community auf den Dienst umstellen. Das ist die größte Lücke (L). Sie hängt am iPad-Client für Fragen und
   Antworten und an der Entscheidung zur Konto-Pflicht; abzustimmen mit `paritaet/community-sync-b28`.
8. Reine Oberfläche aus Abschnitt 4, nach Wunsch des Inhabers.

Zur Kenntnis, am iPad-Code nicht geändert: Der iPad-Text "1 Credit ist 1 Cent echter KI-Kosten"
(`SettingsPage.swift:911`) widerspricht dem festgelegten Wert von 0,9 ct.

## 6. Testlauf auf diesem Stand (ohne Änderung)

| Lauf | Befehl | Ergebnis |
|---|---|---|
| Python | `.venv/bin/python -m pytest -q -x` (ohne `-n`, weil xdist nicht installiert ist) | 3288 bestanden, 50 übersprungen, 2 xfailed |
| JS | `node --test tests/js/*.test.mjs` | 440 bestanden, 0 Fehler |
