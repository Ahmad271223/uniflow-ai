---
fach: Beispiel-Algorithmen (erfunden)
semester: WiSe 2026/27
einheit: G0001
quellen:
  - {kurz: Q1, titel: "algo-skript-bsp", seiten: "1-3"}
typ: vorlesung-erklaert
---

# [Q1] algo-skript-bsp (Seiten 1–3)

## [Q1] Seite 1: Binäre Suche

**Folientext**

> Die binäre Suche findet einen Schlüssel in einem sortierten Feld, indem sie das Feld wiederholt halbiert. Man
> vergleicht den gesuchten Schlüssel mit dem mittleren Element; ist er kleiner, sucht man in der linken Hälfte
> weiter, sonst in der rechten. Die Laufzeit liegt in O(log n), weil sich der Suchbereich in jedem Schritt halbiert.

**Erklärung**

ERKLAERUNG-ALGO-1: Wichtig ist die Voraussetzung, dass das Feld sortiert ist.

## [Q1] Seite 2: Sortieren durch Einfügen

**Folientext**

> Beim Sortieren durch Einfügen wird das Feld von links nach rechts durchlaufen. Jedes neue Element wird in den
> bereits sortierten Anfangsteil an der richtigen Stelle eingefügt, indem größere Elemente um eine Position nach
> rechts verschoben werden. Im schlechtesten Fall braucht das Verfahren quadratisch viele Vergleiche.

**Erklärung**

ERKLAERUNG-ALGO-2: Der sortierte Anfangsteil wächst in jedem Schritt um ein Element.

## [Q1] Seite 3: Sortieren durch Einfügen, Beispiel

**Folientext**

> Beim Sortieren durch Einfügen wird das Feld von links nach rechts durchlaufen. Jedes neue Element wird in den
> bereits sortierten Anfangsteil an der richtigen Stelle eingefügt, indem größere Elemente um eine Position nach
> rechts verschoben werden. Im schlechtesten Fall braucht das Verfahren quadratisch viele Vergleiche.
> Beispiel: Das Feld 5, 2, 4, 6, 1, 3 wird nach sechs Durchläufen zu 1, 2, 3, 4, 5, 6 sortiert.

**Erklärung**

ERKLAERUNG-ALGO-3: Animationsstufe von Seite 2 mit zusätzlichem Beispiel.
