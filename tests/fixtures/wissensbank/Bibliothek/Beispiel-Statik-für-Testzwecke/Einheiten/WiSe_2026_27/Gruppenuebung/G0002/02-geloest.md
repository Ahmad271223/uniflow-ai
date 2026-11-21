---
fach: Beispiel-Statik (erfunden)
semester: WiSe 2026/27
einheit: G0002
quellen:
  - "[Q1] Übungsblatt 03 - Balken.pdf, Seiten 1-2 (Aufgabenblatt der Gruppenübung 3)"
typ: uebung-geloest
loesung_von: Übungsleitung (Musterlösung), Aufgabe 2 KI
---

# [Q1] Übungsblatt 03 - Balken

## [Q1] Aufgabe 1 a): Lagerreaktionen am Einfeldträger

**Aufgabentext.** Ein Einfeldträger der Länge l = 4 m liegt links auf einem Festlager A und rechts auf einem Loslager
B. In der Mitte des Trägers greift eine senkrechte Einzelkraft F = 12 kN an. Das Eigengewicht des Trägers wird
vernachlässigt. a) Bestimmen Sie die Lagerreaktionen in A und B.

**Lösung.** LOESUNG-1A: Aus der Symmetrie folgt A_v = B_v = F/2 = 6 kN, die waagrechte Lagerkraft A_h ist 0.
Probe mit dem Momentengleichgewicht um A: B_v · 4 m − 12 kN · 2 m = 0, also B_v = 6 kN. □

**Abgleich mit der Musterlösung.** ABGLEICH-1A: Die (erfundene) Musterlösung der Übungsleitung schreibt „A = B = 6 kN“
und lässt die Probe weg; nachgerechnet, nicht unabhängig gelöst. Übereinstimmung. □

**Erklärung.** ERKLAERUNG-1A: Die Kraft greift in der Mitte an, deshalb trägt jedes Lager genau die Hälfte.

## [Q1] Aufgabe 1 b): Größtes Biegemoment

**Aufgabentext.** Für den Träger aus Teil a) mit l = 4 m und F = 12 kN: b) Berechnen Sie das größte Biegemoment und
geben Sie an, an welcher Stelle der Balkenachse es auftritt.

**Lösung.** LOESUNG-1B: M_max = F · l / 4 = 12 kN · 4 m / 4 = 12 kNm in der Trägermitte. □ Abgleich: gleich
(ABGLEICH-1B-KURZ, erfundene Lösungsfolie 7).

### Abgleich mit den Lösungsfolien

ABGLEICH-1B: Die (erfundenen) Lösungsfolien zeichnen das Momentendreieck mit der Spitze 12 kNm in der Mitte.

- gleiche Zahl, gleiche Stelle

### Merksatz

MERKSATZ-1B: Einzelkraft in der Mitte des Einfeldträgers: größtes Moment F · l / 4 unter der Kraft.

## [Q1] Aufgabe 2: Kragarm mit Streckenlast

**Aufgabentext.** Ein Kragarm der Länge 3 m ist links fest eingespannt und trägt über seine ganze Länge eine
konstante Streckenlast q0 = 5 kN/m. Bestimmen Sie die Einspannreaktionen sowie den Verlauf der Querkraft und
des Biegemoments entlang des Kragarms.

**Lösung (KI-Lösung, ungeprüft).** LOESUNG-2: Resultierende R = q0 · 3 m = 15 kN in 1,5 m Abstand; Einspannmoment
M_E = 15 kN · 1,5 m = 22,5 kNm. Querkraft linear von 15 kN auf 0, Moment quadratisch. □

## [Q1] Aufgabe 3: Kragträger mit Einzelmoment

**Aufgabentext.** Ein Kragträger der Länge 2 m ist rechts fest eingespannt und wird am freien linken Ende durch ein
Einzelmoment M0 = 8 kNm belastet. Bestimmen Sie die Einspannreaktionen und skizzieren Sie den Momentenverlauf
über die gesamte Trägerlänge.

**Abgleich mit der Musterlösung.** ABGLEICH-3: Hier steht nur, was die (erfundene) Musterlösung der Übungsleitung
nennt: Einspannmoment 8 kNm, keine Querkraft. Eine eigene Lösung fehlt noch.

## Prüfvermerk

Rechnungen mit _pruefung.py nachgerechnet (erfundenes Beispiel).
