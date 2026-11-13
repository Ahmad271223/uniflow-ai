# Smart Planner 2.0 – Bericht (12.11.2026)

Zweig: `feature/smart-planner-2` (nicht in develop gemischt, nichts zu Apple hochgeladen, kein Server geändert).

## Was ist neu – in einem Satz

Du trägst je Modul ein, wie viele Stunden du bis zur Klausur lernen willst (z. B. Mathematik 200 h); StudiNow
verteilt diese Stunden auf deine echte freie Zeit – nie über Vorlesungen, nie im Schlaf, nie nach der Klausur – und
sagt dir ehrlich, wenn die Zeit nicht reicht.

## Wo man es findet

Im **Lernkalender** gibt es oben in der Leiste (neben Tag / Woche / Monat) die neue Ansicht **„Lernziele“**.

- **Oben:** Tage bis zur nächsten Klausur, diese Woche geplant und gelernt, wie viel insgesamt noch fehlt.
- **Module:** je Modul Ziel, gelernt, fehlt, Stunden pro Woche, Prognose („auf Kurs“, „knapp“, „gefährdet“) und
  Klausurtag. Ein automatisch erkannter Termin steht als „unbestätigt“ da, bis du „Bestätigen“ tippst.
- **Diese Woche:** je Tag geplant gegen wirklich gelernt.
- **Konflikte:** zum Beispiel ein gesperrter Block, der jetzt über einer neuen Vorlesung liegt, oder Unterlagen, die
  nicht mehr ins Stundenbudget passen.
- **Knöpfe:** „Zeitrahmen“ (Schlaf – Vorgabe 10 Stunden –, Freizeit, Arbeit, feste Termine, wie viel der freien Zeit
  genutzt wird), „Zeit eintragen“, „Plan erstellen“ bzw. „Neu verteilen“.
- Die Lernblöcke stehen im normalen Kalender neben den Vorlesungen, in der Farbe des Moduls. Antippen: abhaken mit
  der wirklich gelernten Zeit, Stoppuhr starten, sperren, verschieben (vorher prüft die App, ob am neuen Platz etwas
  im Weg ist).

## Was jetzt geht (die 11 Punkte des Auftrags)

1. **Zeit in echten Fenstern:** gerechnet wird Tag für Tag mit den freien Lücken (ein freier Sonntag gleicht keinen
   vollen Dienstag aus). Vorlesungen und Übungen aus dem Stundenplan (mit Fahrtzeit), Schlaf, Freizeit, Arbeit,
   Sperrzeiten werden abgezogen; dazu die Nutzungsquote (Vorgabe 60 % der freien Zeit) und wahlweise eine Obergrenze
   pro Woche.
2. **Je Modul:** Klausurtag, Ziel in Stunden (Standard: nur Selbstlernen; Pflichtveranstaltungen können mitzählen),
   schon gelernt, noch nötig, Tage bis zur Klausur, Stunden pro Woche, Prognose. Nichts wird doppelt gezählt.
3. **Klausurtermine** kommen aus den vorhandenen Quellen (Stud.IP, Kalender, QIS-Anmeldungen, Dokumente). Automatisch
   erkannte sind als „unbestätigt“ markiert; man kann bestätigen, ändern, „schreibe ich nicht“ wählen, Erst- oder
   Zweittermin nehmen, Ziele hinzufügen und entfernen. Gefundene Termine lassen sich im Ziel-Dialog antippen.
4. **Wenn die Zeit nicht reicht**, baut StudiNow keinen Schein-Plan. Beispiel aus dem Auftrag, genau so getestet:
   „670 h nötig, 350 h verfügbar, fehlen 320 h“. Dazu Vorschläge: Nutzungsquote erhöhen (nur wenn das reicht; bei
   100 % werden keine Stunden erfunden), Freizeit senken, Ziele senken (mit Zahlen je Modul), Zweittermin, nach
   Priorität planen, oder bewusst einen Teilplan. Nichts passiert, bevor du eine Option wählst.
5. **Neue Stud.IP-Unterlagen** (Folien, Skript, Blatt, Lösung, Altklausur) kommen als Aufgaben in die Lernblöcke des
   passenden Moduls ab ihrer Woche – im vorhandenen Stundenbudget. Was nicht passt, steht als Konflikt da (wichtigstes
   zuerst); das Budget wächst nie von selbst.
6. **Lernzeit:** Stoppuhr starten/pausieren/beenden, Zeit nachtragen, korrigieren, löschen. Ein abgehakter Block zählt
   nur mit der Zeit, die du angibst (vorgeschlagen ist die Dauer). Doppelt gemeldete oder sich überschneidende Zeiten
   (z. B. iPad und Mac) zählen nur einmal.
7. **Automatisch neu planen** bei: Klausur verschoben, neues Blatt, weniger gelernt, neuer Pflichttermin, Ziel
   geändert, Block verpasst, verschoben oder gelöscht. Erledigte, gesperrte und von dir verschobene Blöcke bleiben,
   wo sie sind. Kleine Änderungen (bis 8 Blöcke) passieren still, größere fragt die App vorher („Neu verteilen“ oder
   „Alten Plan behalten“).
8. **Oberfläche** im bestehenden StudiNow-Design, am iPad und in derselben App am Mac.
9. **Keine KI** für Planen, Verteilen, Konflikte und Fortschritt. Vorhandene Analysen (z. B. geschätzte Dauer einer
   Datei) werden nur gelesen. Beim Öffnen und Verschieben gibt es keinen KI-Aufruf (per Test geprüft).
10. **Datenschutz und Zuverlässigkeit:** jedes Konto hat im Dienst seine eigene Datenbank (Test: ein fremdes Konto
    sieht nichts und darf nichts ändern); jede Änderung ist ein Ganzes (bricht etwas ab, bleibt alles wie vorher);
    doppelt gestartete Neuplanung plant nur einmal; zwei Geräte, auch eines offline, ergeben keine doppelten Blöcke;
    eine laufende Stoppuhr übersteht einen Absturz (die Startzeit steht in der Datenbank); neu geplant wird nur, wenn
    sich etwas geändert hat. Alte Datenbanken werden nur ergänzt, nichts wird gelöscht.
11. **Pflicht-Testszenarien:** alle als automatische Tests vorhanden (Liste unten).

## Tarife

Ziele eintragen, Lernzeit erfassen und die Übersicht gibt es in jedem Tarif. **Lernblöcke automatisch planen und
umplanen** gehört – wie der bisherige automatische Lernplan – zu **Plus** (in Free mit Schloss sichtbar).

## Wie geprüft wurde (echte Läufe, keine erfundenen Zahlen)

**Automatische Tests (Stand 13.11.2026)**

- Python (PC-Dienst): 3.415 bestanden, 3 fehlgeschlagen. Zwei davon (Konto-Löschhinweis, E-Mail-Migration) schlugen
  schon vor dieser Arbeit fehl und sind auf develop behoben; der dritte (Web-Seite Studienverlauf ohne QIS) schlägt
  auch ohne die Änderungen dieses Tages fehl und hat mit dem Planer nichts zu tun. Darunter 40 neue Planer-Tests
  (Rechenkern mit 300 Zufallsfällen, alle Pflicht-Szenarien) und der Rechte-Test über alle neuen Adressen.
- iPad-Kern (Swift): 1.461 Tests, 0 Fehler – darunter der Abgleich, dass iPad und PC bei 48 Planungsfällen exakt
  denselben Plan rechnen, und 14 Szenarien über die Lernziel-Schnittstellen.
- App im Simulator: 910 bestanden, 27 fehlgeschlagen. Alle 27 betreffen den Schlüsselbund (Uni-Passwort, Tarif-Probe,
  ChatGPT-/OpenAI-Verknüpfung, Konto): der Test-Bau ist ohne Signatur, dann darf der Simulator nichts in den
  Schlüsselbund schreiben (die Tests sagen das selbst). Alle Lernkalender- und Lernziel-Tests sind grün, auch der
  Test, dass die neuen Ansichten das iPad nicht überfordern.

**Lasttest** (`tools/lasttest-smart-planner.py`, dieser Mac mit 18 Kernen)

- **Rechenkern, 100.000 erfundene Nutzer** (2–6 Module, Stundenplan, Schlaf, Arbeit, 6–20 Wochen bis zur Klausur):
  100.000 Pläne in 49 Sekunden, ein Plan im Mittel 6 ms (99 % unter 23 ms), 0 Fehler, 0 Verstöße (geprüft: nie nach
  der Klausur, nie über einem Termin, keine Überschneidung, Tagesbudget eingehalten).
- **Dienst mit 200 Konten unter Gedränge** (32 gleichzeitig, auch dieselbe Neuplanung doppelt gestartet):
  4.986 Anfragen, alle in Ordnung, 0 Sperrfehler, 0 doppelte Lernblöcke.
- **Dienst wie im Betrieb** (echter Server mit mehreren Prozessen, echte Verbindungen): Hier zeigte sich ein echtes
  Problem, das jetzt behoben ist. Die Lernziel-Übersicht stellte 190 Datenbankabfragen (151 davon, weil der
  Stundenplan verschobene Termine Tag für Tag einzeln nachsah) und schrieb einen offenen Vorschlag bei jedem Öffnen neu.
  Jetzt sind es 38 Abfragen und keine unnötigen Schreibvorgänge. Ergebnis mit 4 Server-Prozessen (so ist der Dienst
  heute eingestellt) und 32 gleichzeitigen Nutzern: vorher 26 Anfragen pro Sekunde, Übersicht im Mittel 1 Sekunde,
  104 abgebrochene Verbindungen – nachher 61 pro Sekunde, im Mittel 37 ms, keine Fehler. Mit 12 Server-Prozessen:
  341 Anfragen pro Sekunde, 99 % der Übersichten unter 0,5 Sekunden, keine Fehler.
- **Hochrechnung auf 100.000 gleichzeitige Nutzer** (Annahme, offen genannt: jeder öffnet alle 5 Minuten die Übersicht
  und schreibt alle 10 Minuten etwas, also etwa 500 Anfragen pro Sekunde): reine Rechenzeit 3 Kern-Sekunden pro
  Sekunde; gemessen schafft ein Server-Prozess etwa 28 Anfragen pro Sekunde. Gebraucht werden also rund 18
  Server-Prozesse, mit Reserve etwa 26 – zum Beispiel zwei Server mit je 16 Kernen. Die heutige Einstellung
  (4 Prozesse) reicht nach dieser Messung für etwa 10.000–20.000 gleichzeitige Nutzer; für mehr muss die Zahl der
  Prozesse (`WEB_CONCURRENCY`) bzw. der Server steigen. Das ist eine Rechnung auf Messwerten, kein Lauf mit 100.000
  echten Verbindungen.

## Was offen ist

- **Mischen in develop:** der Zweig ist fertig zum Ansehen, aber nicht gemischt. develop ist seit dem Start weiter
  gelaufen (Build 35, Studiengruppen); beim Mischen sind Konflikte in Lernkalender-Dateien möglich.
- **Ziehen im Wochenraster:** Ein Block, den man mit dem Finger auf einen anderen Tag zieht, wird ohne vorherige
  Rückfrage verschoben (danach steht ein Konflikt in den Lernzielen). Die Rückfrage gibt es beim Knopf „Verschieben“.
- **Erinnerungen** an Lernblöcke (laut Regel ab Plus) sind nicht Teil dieses Auftrags und noch nicht angebunden.
- **Web/PC-Oberfläche:** Die Funktionen sind im PC-Dienst vorhanden (gleiche Rechnung, gleiche Schnittstellen), eine
  eigene Web-Ansicht dafür gibt es noch nicht.
- **Lasttest:** 100.000 gleichzeitige Nutzer wurden nicht als echte Verbindungen erzeugt (das geht auf einem Mac nicht);
  belegt ist es über die gemessene Leistung je Server-Prozess (siehe oben) plus eine offen genannte Annahme.
  Ein Lauf auf dem gemieteten Testserver (vorhandenes Werkzeug k6) steht noch aus. Empfehlung: im Betrieb so viele
  Server-Prozesse wie Kerne einstellen (heute fest 4) – das betrifft den ganzen Dienst, nicht nur den Planer, und ist
  hier nicht geändert.
- Unabhängig von diesem Auftrag gefunden: drei ältere Abgleichsdateien (Einstellungen, Bibliothek, Stud.IP-Import)
  passen nicht mehr zur neuesten Python-Fassung; zwei Python-Tests (Konto-Löschhinweis, E-Mail-Migration) schlugen
  schon auf dem Ausgangsstand fehl und sind auf develop inzwischen behoben.

## Was nur am Gerät prüfbar ist

- Aussehen und Bedienung der neuen Ansicht „Lernziele“ und der Dialoge auf dem echten iPad und am Mac (hell/dunkel,
  kleine iPads, Bedienung mit Finger und Stift).
- Abgleich zwischen iPad und Mac über das StudiNow-Konto mit echten Daten (getestet ist die Regel, nicht der echte
  Abgleich über den Dienst).
- Die Stoppuhr, wenn die App im Hintergrund ist oder neu startet (läuft weiter, weil die Startzeit gespeichert ist).
- Echte Klausurtermine aus Stud.IP/QIS der eigenen Hochschule in der Liste „Gefundene Termine“.
