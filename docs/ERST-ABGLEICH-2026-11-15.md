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
