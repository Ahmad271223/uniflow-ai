# Entscheidungen des Inhabers vom 29.10.2026 (Mac-Sitzung)

Ergänzt `docs/ENTSCHEIDUNGEN-INHABER-2026-10-28.md` und Abschnitt 3 von
`docs/UEBERGABE-MAC-NEUE-SITZUNG-2026-10-29.md`. Gilt für iPad, Windows und Web gleich.

## 1. Wochentests

| Punkt | Entscheidung |
|---|---|
| Welche Module | **Jedes Modul** bekommt jede Woche automatisch einen Test (nicht nur ausgewählte). |
| Grundlage | **Alle Folien dieser Woche** des Moduls. |
| Umfang | **Genau 15 Aufgaben: 4 leicht, 6 mittel, 5 schwer.** Vom Inhaber ausdrücklich so bestätigt („mach genau so“). |
| Altklausur | Gibt es zum Modul eine Altklausur, ist **eine der 5 schweren Aufgaben im Klausurstil**. Die Summe bleibt 15. (Festlegung der Mac-Sitzung; der Inhaber kann sie ändern.) |
| Übungsblatt | Ist ein Übungsblatt offen, zeigt die App, **wo im Skript** der Stoff dazu steht (Seite). |

### Umsetzung

- **Aufgaben erzeugen braucht immer eine KI.** Auf dem iPad über das ChatGPT-Abo des Nutzers
  (`docs/KI-CHATGPT-PLAN.md`, Übergabe Abschnitt 4 A5), am PC über den bisherigen Weg (`app/ai.py`).
- **Prompt in Python und Swift byte-gleich**, über einen gemeinsamen Vertrag aus einem Generator, der nur `app/ai.py`
  importiert. Heute erzeugt `_test_prompt` in `app/ai.py` „etwa 8“ bzw. „etwa 12“ Aufgaben je nach Dauer, ohne feste
  Verteilung; das ändert sich auf 15 mit 4/6/5 und je Aufgabe ein Feld `difficulty` (`leicht`, `mittel`, `schwer`).
- **Prüfung der Antwort:** Ein erzeugter Wochentest wird nur angenommen, wenn er genau 15 Aufgaben mit genau dieser
  Verteilung hat. Sonst wird die Antwort verworfen und einmal neu angefordert; scheitert auch das, wird ein Fehler
  angezeigt statt eines falschen Tests. Tests dazu in Python und Swift, ohne echtes Netz.
- **Standard:** `tests_per_subject` ist auf dem iPad 0. Für „jedes Modul automatisch“ wird der Standard 1, und der
  Lernplan plant je Modul und Woche einen Test ein. Bestehende Nutzerwerte bleiben.
- **Stelle im Skript zum Übungsblatt**, zweistufig:
  1. Ohne KI, offline und in jedem Tarif: Fachbegriffe aus dem Übungsblatt gegen den gespeicherten Seitentext der
     Skripte des Moduls (`page_texts`, Volltextsuche). Die Seiten mit den meisten Treffern werden vorgeschlagen.
  2. Mit KI (wenn verbunden): dieselben Kandidatenseiten nummeriert an die KI, die die passende Stelle wählt und mit
     `[n]` belegt, wie der KI-Tutor mit Quellen und Seitenangabe (PC 3b12273). Die KI nennt nur Seiten, die ihr
     vorlagen.

## 2. Bitte an die PC-Sitzung

Wochentests in `app/ai.py` und Windows auf diese Regel umstellen (15 Aufgaben, 4/6/5, alle Folien der Woche,
Klausuraufgabe, Prüfung der Antwort), damit der gemeinsame Vertrag entstehen kann. Die Mac-Sitzung zieht Swift nach.
