# Gemeinsame Wochentests

Stand 25.10.2026. Vorgabe des Inhabers: Wer dieselbe Vorlesung und dieselbe Übung hat, bekommt **automatisch
denselben Wochentest**. Nicht jeder bekommt einen eigenen.

## Regel

Ein Wochentest wird durch einen **gemeinsamen Schlüssel** beschrieben (`app/testshare.py`, Version `wt2` seit 29.10.2026: 15 Aufgaben 4/6/5, Altklausur im Schlüssel):

| Teil des Schlüssels | Warum |
| --- | --- |
| Hochschule | Unis werden nie gemischt |
| Testdauer, gerundet auf 15/30/45/60/90/120 Minuten | 40 und 45 Minuten teilen denselben Test |
| SHA-256 des Inhalts jeder verwendeten Datei (sortiert, ohne Doppelte) | gleiche Folie und gleiches Übungsblatt ergeben denselben Abdruck, egal ob über Stud.IP, Learnweb mit oder ohne Schlüssel |

**Nicht** im Schlüssel: Nutzer, Gerät, Modulname, Lehrwochen-Nummer. Diese sind pro Nutzer verschieden einstellbar.
Wer eine **andere Übungsgruppe mit anderem Blatt** hat, bekommt dadurch automatisch einen eigenen Test. Fehlt bei einer
Datei der Inhalt, wird nicht geteilt (lieber ein eigener Test als ein falscher).

Ändert sich der Aufbau eines Tests (Prompt, Format), wird `VERSION` erhöht. Dann entstehen neue Tests, alte werden nicht
mit neuen vermischt.

## Stand der Umsetzung

- **PC-App (fertig):** Jede geladene Datei bekommt ihren Inhalts-Hash (`files.content_sha256`), jeder Wochentest seinen
  Schlüssel (`tests.share_key`). Gibt es den Schlüssel schon, wird der Test ohne KI-Anfrage übernommen; die Lehrwoche im
  Titel ist die eigene. Tests: `tests/test_testshare.py`.
- **iPad:** dieselbe Berechnung; Erwartungswerte in `packages/shared-contracts/fixtures/testshare/cases.json`.
- **V2-Dienst (geplant):** Der Dienst speichert **einen Test je Schlüssel für alle Nutzer**.

## Ablauf im V2-Dienst

1. Das Gerät berechnet den Schlüssel aus seinen Dateien und fragt `GET /api/v2/shared-tests/{key}`.
2. Gibt es den Test, kommt er sofort zurück. Keine KI-Kosten.
3. Sonst schickt das Gerät den **extrahierten Text** (nie die PDF) mit `POST`. Der Dienst erzeugt den Test genau einmal.
   Eine Sperre pro Schlüssel verhindert, dass zwei gleichzeitige Anfragen zwei Tests erzeugen; die zweite wartet.
4. Antworten, Punkte und Rückmeldungen bleiben **pro Nutzer** und werden nie geteilt.
5. Einen Test bekommt nur, wer den Schlüssel berechnen kann, also die Dateien des Kurses selbst besitzt. Der Dienst gibt
   keine Liste von Schlüsseln heraus.
6. Meldet ein Nutzer einen Fehler im Test, wird der Test für alle mit diesem Schlüssel neu erzeugt (Version + 1 nur für
   diesen Schlüssel) oder korrigiert.

Dasselbe Prinzip gilt für die **Dateianalyse**: einmal je Inhalts-Hash statt einmal je Nutzer.

## Kostenwirkung (10.000 Nutzer, Annahmen)

Annahmen: 70 % Free, 20 % Plus, 10 % Pro; jeder nutzt sein Kontingent voll (59.000 Tests im Monat); je Kurs und Übungsblatt
teilen sich im Schnitt **30 Nutzer** einen Test (5 Module je Nutzer, 4 Wochen).

| Posten | ohne Teilen | mit Teilen |
| --- | --- | --- |
| Tests erzeugen (Sonnet 5.5, 0,07 $ je Test) | ca. 4.130 $ | ca. 470 $ (rund 6.700 verschiedene Tests) |
| Dateianalyse (Haiku 5.5, Batch) | ca. 400 $ | ca. 10 $ (je Datei einmal) |
| Antworten bewerten, pro Nutzer (Sonnet 5.5, ca. 0,038 $) | ca. 2.240 $ | ca. 2.240 $ |
| Antworten bewerten mit Haiku 5.5 (ca. 0,002 $) | ca. 120 $ | ca. 120 $ |
| **Summe mit Sonnet-Bewertung** | **ca. 6.770 $** | **ca. 2.720 $** |
| **Summe mit Haiku-Bewertung** | ca. 4.650 $ | **ca. 600 $** |

Nach dem Teilen ist die **Bewertung der Antworten** der größte Posten. Hebel: Multiple-Choice- und Zahlenaufgaben ohne
KI auf dem Gerät bewerten, nur Freitext mit KI, und dafür Haiku 5.5 testen.

## Offene Entscheidung des Inhabers

- Zählt ein geteilter (also kostenloser) Test gegen das Monatskontingent (1/6/40)? Technisch nötig ist es nicht.
