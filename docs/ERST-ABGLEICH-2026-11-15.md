# Erster Abgleich nach dem Verbinden des Uni-Kontos (15.11.2026)

Auftrag des Inhabers: „wenn jemand sein uni konto verbindet soll alles direkt klappen“. Zweig `fix/erst-abgleich`
(ab 6ed2cc39, Kandidat für Build 43).

## Was am iPad passiert ist (Testkonto Uni Hildesheim, nur Zahlen aus der Geräte-Datenbank)

- 12:04:57–12:04:59 Lauf nur mit dem LSF (Stundenplan, Noten). 12:05:13–12:30:10 der erste Learnweb-Lauf: 139 Dateien
  in 14 Kursen des laufenden Semesters. 12:30–12:32 frühere Semester (113 Dateien in 8 Kursen).
- Downloads je Minute: 12:10 eine, 12:12 eine, 12:21 siebenunddreißig, 12:25 eine, 12:26 eine, 12:28–12:32 knapp 200.
  Solange die App offen und vorn war, kamen 40 bis 60 Dateien je Minute. Langsam war es nur, während das iPad gesperrt
  bzw. die App im Hintergrund war (iOS hält die App dann an).
- In der ganzen Zeit gab es an der Uni Hildesheim keine Anzeige: Commit 39e37839 (14.11.) zeigt die Statusleiste nur
  noch bei Fehlern, damit fiel auch jeder Fortschritt weg. Der Knopf „Sync“ antwortete 25 Minuten lang nur „Der
  Abgleich läuft bereits“.
- Uni-Mail: der Posteingang wurde zum ersten Mal um 12:30:24 gelesen, 14 Sekunden nach dem Ende des langen Laufs. Der
  Abgleich aller Portale (verbindet auch die Uni-Mail mit dem gespeicherten Zugang) startete nicht, solange Learnweb
  lief – „Mail verbinden geht nicht“ war also sehr wahrscheinlich „wartet auf das Ende des Datei-Abgleichs“.

## Ist-Ablauf

| | LUH (Stud.IP) | Uni Hildesheim (Learnweb) |
|---|---|---|
| Kursliste | zuerst | zuerst |
| Dateilisten | alle Kurse, 4 zugleich, vor den Downloads | Kurs für Kurs, jeweils direkt gefolgt von seinen Downloads |
| Downloads | streng nacheinander, Reihenfolge der Kurse | streng nacheinander, Kurs für Kurs |
| Anzeige | Karte „Stud.IP wird abgeglichen – 37 neue Dateien – lade 12 von 37: …“ | seit 14.11. keine |
| Datei antippen, die noch nicht geladen ist | lädt sie einzeln („Jetzt laden“) | nur Hinweis „kommt mit dem Abgleich“ |
| Unterbrechung | Lauf endet als abgebrochen; nächster Start frühestens nach 30 Minuten, wenn schon einmal ein Lauf durch war | wie LUH |
| Hintergrund | keine Hintergrundzeit für den laufenden Abgleich; BGTask-Läufe nur nach Plan von iOS | wie LUH |
| Frühere Semester | nach dem ersten vollen Lauf Frage „Auch frühere Semester laden?“, Antwort bleibt gespeichert | wie LUH |

Was der Nutzer an der Uni Hildesheim sah: Module sofort (Kurse werden zuerst angelegt), aber ohne Dateien, bis der
jeweilige Kurs an der Reihe war – ohne jeden Hinweis, dass noch geladen wird.

## Lösung

1. **Eine Fortschrittsanzeige für alle Hochschulen** (`SyncProgress` im Kern, `UFSyncProgressBar` in der App): „Deine
   Kurse werden geladen: 121 von 250 Dateien“, darunter der Kurs, der gerade dran ist, mit Balken. Nur solange geladen
   wird; danach verschwindet sie. Die abgelehnte Dauerleiste „Learnweb ok · LSF ok“ kommt nicht zurück. In Modulen,
   deren Dateien noch fehlen, steht „Dateien werden noch geladen …“ statt „Noch keine Dokumente“.
2. **Wichtiges zuerst** (`HildesheimSync`): erst die Dateilisten ALLER Kurse (3 zugleich), dann die Downloads –
   laufendes Semester vor früheren, kleine und neue Dateien zuerst (`DownloadPlan.order`, gleich in
   `app/sync_order.py`). Nicht geladene Dateien stehen sofort in den Modulen; Antippen lädt sie einzeln, jetzt auch im
   Learnweb.
3. **Schneller**: 3 Downloads zugleich (`DownloadLanes`), an der LUH und in Hildesheim. Meldet die Hochschule 429 oder
   einen Serverfehler, geht es für den Rest des Laufs einzeln weiter.
4. **Unterbrechungen**: Der laufende Abgleich bittet iOS um Hintergrundzeit; läuft sie ab, endet er sauber. Ein nicht
   beendeter Lauf ist gemerkt (`runOpen`); beim Zurückkommen startet er von selbst wieder und lädt nur, was fehlt.
   Solange etwas fehlt, steht die Anzeige da – kein Zustand, der wie „fertig“ aussieht.
5. **Frühere Semester**: bleibt bei „laufendes Semester zuerst, dann fragen“; die Frage kommt erst, wenn das laufende
   Semester wirklich vollständig ist, die Antwort bleibt gespeichert.
6. **Uni-Mail**: wird mit dem gespeicherten Zugang sofort mitverbunden, auch während Learnweb noch lädt; „Sync“ wartet
   dafür nicht mehr auf den Datei-Abgleich. Ohne gespeichertes Passwort: klarer Hinweis „einmal von Hand anmelden“.
   Offene Beobachtung der echten Hildesheimer SOGo-Seite: siehe Bericht.

## Umgesetzt (Stand 15.11.2026 abends)

- **Weiterer Befund beim Bauen:** An der Uni Hildesheim luden die offenen Seiten erst am ENDE des ganzen Laufs neu
  (`ufReload` hörte nur auf `finishedRuns`). Auch schon geladene Kurse blieben also bis zum Schluss leer, wenn man die
  Seite nicht wechselte. Jetzt laden die Seiten während des Abgleichs alle paar Sekunden neu (`stagesReady`).
- Kern: `Sync/SyncProgress.swift` (`SyncProgress`, `SyncPending`, `DownloadPlan`, `DownloadLanes`),
  `HildesheimSync` (Listen je Stufe zuerst, Downloads geordnet und 3 zugleich, `loadFile`), `DownloadFailures`
  (Gründe für Learnweb-Dateien). Python: `sync_order.download_order`/`size_class` mit denselben Testfällen.
- App: `Views/SyncProgressViews.swift` (Leiste, Modul-Hinweis, Hintergrundzeit), `HildesheimConnection` und
  `StudIPSync` (`progress`, `interrupted`, `stagesReady`, `runOpen`), `FileLoadPanel` (Learnweb), `OpenSync`,
  `StoredLoginConnect.connectMailAfterSignIn`, `UniMailConnection.adoptExistingSession`, Anmeldefenster der Uni-Mail.
- Messung im Test (nachgestelltes Learnweb, 14 Kurse, 140 Dateien, 15 ms je Anfrage): nacheinander 3,37 s, mit drei
  Downloads zugleich 1,21 s (rund 2,8-mal so schnell). Am echten Gerät hängt die Dauer vor allem an der Leitung und
  daran, ob die App offen bleibt.
- Unterbrechung: iOS gibt einer App im Hintergrund in der Regel rund 30 Sekunden. Solange läuft der Abgleich weiter,
  dann endet er sauber. Beim Zurückkommen startet er von selbst und lädt nur, was fehlt (Listen werden kurz neu
  gelesen, keine Datei zweimal geladen). Ein Laden über viele Minuten bei gesperrtem Gerät geht damit NICHT; dafür
  bräuchte es Hintergrund-Downloads des Systems (eigener, größerer Umbau, siehe offene Punkte).

## Offen

- Uni-Mail Hildesheim: das Formular `hildesheimSOGo` (automatisches Ausfüllen) ist weiter nicht an der echten Seite
  bestätigt. Einmal im Browser prüfen: https://webmail.uni-hildesheim.de/SOGo/ – (1) heißen die Felder wie an der LUH
  (Benutzername `input[name="userName"]` bzw. `ng-model="app.creds.username"`, Passwort `input#passwordField`,
  Knopf `button[type="submit"]`)? (2) Meldet man sich mit dem UNI-Account an oder mit der E-Mail-Adresse? (3) Gibt es
  nach dem Passwort einen zweiten Schritt (Code)? (4) Steht nach der Anmeldung `/SOGo/so/<benutzer>/…` in der Adresse?
  (5) Welcher Text erscheint bei falschem Passwort?
- Laden bei gesperrtem Gerät über die 30 Sekunden hinaus (Hintergrund-Downloads von iOS).
- Hochschule Hannover: bekommt Listen zuerst und drei Downloads zugleich aus dem Kern, die neue Anzeige noch nicht.
- Am echten iPad/iPhone/Mac noch nicht gesehen (nur Simulator und Tests).
