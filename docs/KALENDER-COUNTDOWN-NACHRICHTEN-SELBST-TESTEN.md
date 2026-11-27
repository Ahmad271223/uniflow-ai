# Selbst testen: Kalender, Countdown, Widget „Nachrichten“

Für den Inhaber, 26.11.2026. Zweig `app/kalender-countdown-nachrichten`. Am besten auf dem eigenen iPhone und iPad per
Kabel (Claude spielt die App auf, wenn du es sagst). Mit deinem echten Stud.IP-Konto, weil nur dort echte Termine und
Nachrichten sind. Jeder Punkt hat ein „richtig ist“.

Vorher einmal: Für das Widget braucht die App im Apple-Konto die App-Gruppe `group.de.uniflow.ai` (wie bei den
Widgets seit Build 47). Das legt Xcode beim ersten Gerätebau an – nur mit deinem Okay.

## 1. Termine im Kalender (≈ 10 Minuten)

1. StudiNow → Einstellungen → **Uni-Zugang & Abgleich** → Karte **„Termine im Kalender“** → Schalter an.
   - richtig ist: iOS fragt nach dem Kalender. Tippe **„Vollzugriff erlauben“**. Danach steht in der Karte
     „Zuletzt abgeglichen: … · N Einträge“.
   - Tippst du „Nicht erlauben“: Schalter bleibt aus, die Karte sagt, wo man es in den Einstellungen erlaubt.
2. **Kalender-App** öffnen → unten „Kalender“ → es gibt **„StudiNow“** (meist unter iCloud).
   - richtig ist: deine Vorlesungen dieser und der nächsten Wochen, mit Raum als Ort. Tippe einen Termin an: in den
     Notizen Art, Lehrende, ggf. Thema; die Adresse öffnet StudiNow am richtigen Tag.
   - Feiertage, Abgaben (z. B. „Abgabe: Blatt 4 (bis 12:00)“) und Klausuren stehen auch drin.
3. Termin **als ausgefallen markieren** (in StudiNow im Stundenplan einen Termin antippen → ausgefallen), dann
   StudiNow kurz verlassen (Home-Bildschirm).
   - richtig ist: in der Kalender-App heißt er jetzt „Fällt aus: …“. Zurücknehmen → wieder normal.
4. Einen Termin **verlegen** (anderer Tag/Uhrzeit).
   - richtig ist: derselbe Eintrag wandert an den neuen Platz, nichts doppelt.
5. Selbst in der Kalender-App einen Termin **in den Kalender „StudiNow“** eintragen, dann in StudiNow auf Sync.
   - richtig ist: dein eigener Termin bleibt stehen.
6. In der Karte **Zeitraum „2 Wochen“** wählen.
   - richtig ist: Termine nach zwei Wochen verschwinden aus der Kalender-App; „Ganzes Semester“ bringt sie zurück.
7. Schalter **aus** → Rückfrage bestätigen.
   - richtig ist: der Kalender „StudiNow“ ist in der Kalender-App weg, deine anderen Kalender sind unverändert.
8. Auf **iPhone und iPad** einschalten (beide mit iCloud).
   - richtig ist: ein Kalender „StudiNow“, kein Termin doppelt.

## 2. Countdown auf der Startseite (an einem Tag mit Vorlesung)

1. Startseite → Karte **„Heute an der Uni“**.
   - richtig ist: beim nächsten Termin „in 25 Min“ (bzw. „in 2 Std 10 Min“), während eines Termins
     „läuft · noch 35 Min“. iPhone: als Zeile unter dem Raum; iPad/Mac: kleines Feld vor dem Raum.
2. Eine Minute warten, ohne etwas zu tippen.
   - richtig ist: die Zahl zählt von selbst weiter.
3. Abends nach dem letzten Termin.
   - richtig ist: unten „Als Nächstes: morgen 8:15 · …“ (bzw. „Mo. 10:00 · …“). Ist in der nächsten Woche nichts,
     steht nichts da.
4. Ausgefallener Termin.
   - richtig ist: bekommt keinen Countdown; der nächste stattfindende schon.
5. VoiceOver an (Einstellungen → Bedienungshilfen) und über die Zeile wischen.
   - richtig ist: „Beginnt in 25 Minuten“ bzw. „Läuft gerade, noch 35 Minuten“.

## 2b. Erinnerung vor der Vorlesung

1. Einstellungen → Uni-Zugang & Abgleich → Karte **„Mitteilungen“** → **„Vor jeder Vorlesung“** an.
   - richtig ist: iOS fragt nach Mitteilungen (falls noch nie gefragt). Darunter „Wie lange vorher“ (10 Min).
2. Auf „5 Min“ stellen und warten, bis 5 Minuten vor dem nächsten Termin.
   - richtig ist: Mitteilung „In 5 Min: …“ mit Zeit und Raum. Antippen öffnet den Stundenplan an dem Tag.
3. Einen Termin als ausgefallen markieren, StudiNow kurz verlassen.
   - richtig ist: für ihn kommt keine Mitteilung mehr.
4. Schalter aus.
   - richtig ist: keine Erinnerungen vor Vorlesungen mehr; Erinnerungen an Abgaben bleiben.

## 3. Widget „Nachrichten“

1. Home-Bildschirm lange drücken → „+“ / „Bearbeiten“ → **StudiNow** → **„Nachrichten“** (klein und mittel).
   Sperrbildschirm: lange drücken → Anpassen → Widgets → StudiNow → „Nachrichten“.
   - richtig ist: Zahl der ungelesenen Nachrichten; mittel mit Absender und Betreff der neuesten.
2. Dir selbst in Stud.IP (Browser) eine Nachricht schreiben, dann in StudiNow auf Sync.
   - richtig ist: Widget zeigt eine mehr.
3. In StudiNow die Nachrichten öffnen, **ohne** eine anzutippen.
   - richtig ist: Zahl bleibt gleich. Jetzt die Nachricht antippen → Zahl geht runter (Widget und Seitenleiste).
4. Im Leser **„Als ungelesen markieren“** → Zahl wieder höher. Oben **„Alle als gelesen“** → 0.
5. Sperrbildschirm: es stehen nur Zahl und Absender, **kein Betreff**. Einstellungen → Uni-Zugang & Abgleich →
   Karte „Widget „Nachrichten““ → „Betreff auf dem Sperrbildschirm“ an → Betreff erscheint.
6. Uni-Mail verbunden: Widget zeigt „Stud.IP 2 · Uni-Mail 1“; eine Uni-Mail-Zeile antippen öffnet Uni-Mail.
7. Ein Nachrichtentext erscheint nur mit „Anfang des Nachrichtentexts zeigen“.

## Wenn etwas nicht stimmt

Bildschirmfoto machen und sagen, bei welchem Punkt – das reicht.

## Was Claude schon geprüft hat (ohne dein Gerät)

- Durchgehender Test im Simulator: Termine, Ausfall und Verlegung über die echte Datenbank der App, Abgleich in den
  echten Kalender des Simulators, Änderung in der App, erneuter Abgleich (geändert, entfernt, nichts doppelt),
  Countdown aus denselben Daten.
- Regeln aller drei Funktionen, Widget-Bilder in allen Größen hell/dunkel, Countdown-Bilder iPhone/iPad/große Schrift,
  Quellen-Prüfungen, Einstellungen, Startseite – auf iPad- und iPhone-Simulator.
- Kern-Tests komplett (1893).
- Ganze App-Testsuite auf dem iPad-Simulator (27.11.): 2331 Tests, 66 übersprungen, 4 rot – alle vier schon vor
  diesem Zweig bekannt und ohne Bezug: `StoreScreenshotTests/test01Uebersicht` rechnet mit dem heutigen Datum
  (Meldezeitraum, seit 25.11. auch auf dem unveränderten Stand rot), drei Editor-Messläufe zählen Bilder unter Last
  (`EditorScaleTests` ×2, `EditorStrichBleibtTests`; allein wiederholt 2 davon grün). Dieser Zweig ändert keine
  Editor-Datei.

**Nicht** geprüft: echtes Gerät (Erlaubnis-Abfrage von iOS, iCloud mit zwei Geräten, echtes Widget auf dem
Sperrbildschirm), Mac, echtes Stud.IP-Konto mit dem neuen „gelesen“-Feld.
