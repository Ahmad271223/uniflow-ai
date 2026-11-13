# Startseite, Reiter im Editor, Schreibgefühl – 13.11.2026

Zweig `app/startseite-letzte-dokumente-stift` (von develop `75995b2e`). Nicht in develop gemischt, nichts gepusht,
nichts zu Apple hochgeladen. Bilder liegen unter `~/Studora-Builds/startseite/`.

## 1. Startseite aufgeräumt

Geprüft wurde die Übersicht mit Demo-Inhalten, großes iPad (13 Zoll quer) und kleines iPad (mini hochkant), hell
und dunkel, dazu die Fälle „Probe läuft“ und „Pro AI ohne Anmeldung“.

**Gefunden:**

| Element | Befund |
|---|---|
| „Nächste Termine“ | doppelt: dieselben Abgaben wie „Abgaben & Prüfungen“ |
| Kachel „0 / 4 Aufgaben erledigt“ | doppelt: steht auch in „Diese Woche“ |
| Kacheln „25 min heute geplant“, „3 nachzuholen“ | drei große Kacheln für zwei Zahlen |
| „Heute in der Mensa“ | stand ganz oben, noch vor dem Lernplan |
| Knopf „Tagesansicht“ oben | doppelt: Lernkalender in der Leiste, „Lernpaket öffnen“ in der Karte |
| Probe-Hinweis und „Noch ein Schritt für die KI“ | stehen bei einer Probe zugleich da |
| Studiengruppen-Karte | steht nicht auf der Startseite, sondern unter Stud.IP; unverändert |

**Umgesetzt (vom Inhaber am 13.11.2026 freigegeben):**

- „Nächste Termine“ entfällt. Abgaben, Fristen und Klausuren stehen in „Abgaben & Prüfungen“, Lernpakete in
  „Diese Woche“ und im Lernkalender.
- Die drei Kacheln sind jetzt eine Zeile unter „Hallo …“: „25 min geplant, 13 h frei · 3 nachzuholen – neu planen“.
  „neu planen“ ist ein Link und macht dasselbe wie vorher.
- Mensa steht am Ende der Seite. „Tagesansicht“ ist ein Link in der Karte „Heute für dich geplant“.
- „Diese Woche“ steht quer in der breiten Spalte.

**Nicht freigegeben, darum unverändert:** Probe-Hinweis und KI-Hinweis können weiter zugleich oben stehen.

Ergebnis: Auf dem kleinen iPad beginnt der Lernplan etwa auf halber Höhe statt erst in der zweiten Bildschirmhälfte.
Die ganze Seite ist rund ein Fünftel kürzer.

## 2. Letzte 15 Dokumente im Editor-Kopf

- In der einen Kopfzeile stehen die zuletzt geöffneten 15 Dokumente als Reiter (vorher 10). Es gibt keine zweite
  Zeile, die Schreibfläche bleibt gleich groß.
- Passen nicht alle Reiter, lässt sich die Leiste waagerecht wischen. Der Rand blendet weich aus, damit man sieht,
  dass es weitergeht. Das offene Dokument ist farbig hervorgehoben und wird beim Öffnen in Sicht geschoben.
- Antippen öffnet das Dokument. Das „×“ nimmt es aus der Leiste.
- Hochkant auf dem 11-Zoll-iPad ist es jetzt auch eine wischbare Leiste (vorher ein Knopf mit Liste). Nur ganz schmal
  (Drittel in der geteilten Ansicht) bleibt es ein Knopf mit Liste.
- Die Leiste bleibt nach einem Neustart erhalten. Sie gilt je Konto und Hochschule: Nach einem Wechsel stehen nie
  Reiter eines anderen Kontos da (eigener Test).
- Gelöschte Dokumente verschwinden aus der Leiste: aus dem Papierkorb sofort, endgültig gelöschte nach einer
  Rückfrage beim Speicher. Ausgeblendete Kurse behalten ihre Reiter.

## 3. Schreibgefühl mit dem Apple Pencil

**Geprüft und in Ordnung** (nichts geändert):

- Handballen: Stift schreibt, Finger scrollt (`pencilOnly`), nie die unsichere Grundeinstellung.
- Druck und Neigung werden gespeichert und wieder geladen (Prüftest vorhanden).
- PencilKit glättet und sagt den Strich selbst voraus. Die App greift nicht ein, und das ist richtig so.
- Werkzeuge werden nur beim Wechsel neu gebaut. Die Leiste rechnet beim Schreiben nicht neu (0 Meldungen je Strich).

**Behoben, mit Messung vorher/nachher** (Simulator, Test `PencilFeelTests`):

| Punkt | Vorher | Nachher |
|---|---|---|
| Radierer über 40 Striche auf einer Seite mit 300 | 40-mal ganze Seite gesichert, 129 ms Arbeit im Hauptablauf während des Radierens | 1-mal beim Absetzen, 0,2 ms |
| Pinch-Zoom (30 Bilder) | 30 Meldungen, jedes Mal rechnet die ganze Dokumentansicht neu | 5 Meldungen |
| Nach dem Zoomen | 4 von 5 unsichtbaren Seiten neu in Zoom-Schärfe (Speicher, Grafik) | 0 (sie werden beim Wiederanzeigen scharf) |
| Form erkannt („zeichnen und halten“) | zweimal gesichert (Strich und Form) | einmal |

Unverändert und bewusst so: Jeder abgesetzte Strich wird sofort auf die Platte geschrieben. Das verlangt das Audit
(P60/P61: Ein Strich übersteht einen Absturz direkt nach dem Absetzen). Auf einer vollen Seite kostet das wenige
Millisekunden je Strich.

**Nur am echten iPad mit Stift prüfbar:**

- Latenz und Vorhersage: Der Simulator hat keinen Stift.
- Wie flüssig Pinchen und Radieren sich anfühlen.
- Ob schnelles Doppeltippen mit dem Stift (Punkte, „ü“) ein Zoomen auslöst. PDFKits Doppeltipp-Zoom nimmt auch den
  Stift an. Das ist ein Kandidat für die nächste Runde.
- Möglicher nächster Schritt: Bei sehr starkem Zoom (4-fach) ist die Zeichenfläche riesig. Eine Grenze bei 3-fach
  müsste am Gerät gegen die Schärfe abgewogen werden.

## Tests

- Volle iPad-Testsuite (`-only-testing:UniFlowTests`, Kopie von Simulator 4495AA80): 1.570 Tests, 0 Fehler,
  20 übersprungen (`~/Studora-Builds/startseite/voll2.log`).
- Kern `swift test` (UniFlowCore): 1.495 Tests, 0 Fehler, 9 übersprungen. Kern und Python unverändert, darum keine
  Python-Tests.
- Neu: `StartseiteBilderAppTests` (Bilder und Prüfung der Startseite), `PencilFeelTests` (vorher/nachher),
  zwei Reiter-Tests in `DocumentTabsHeaderAppTests` (Kontotrennung, gelöschte Dokumente).
- Schon vorher wackelig, nicht durch diesen Zweig: `KIAbnahmeLUHAppTests.test3ProAIUeberDenDienst` scheitert
  manchmal („Aufgabe lösen“ fehlt, weil die vorige KI-Anfrage noch läuft). Auf unverändertem develop 2 von 4 Läufen
  rot, auf diesem Zweig im ersten vollen Lauf rot und im zweiten grün.

Bilder: `~/Studora-Builds/startseite/ergebnis/` (vorher/jetzt), Einzelbilder in `bilder/` (vorher) und `endstand/`.
