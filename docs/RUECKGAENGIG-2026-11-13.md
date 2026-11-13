# Rückgängig holt gelöschte Striche zurück, Formen erkennen am iPad – 13.11.2026

Zweig `fix/rueckgaengig-striche` (von develop `61cb4c03`). Nicht in develop gemischt, nichts gepusht.

## 1. Rückgängig (Inhaber, echtes iPad, Build 37–39)

**Fehler:**
- Rückgängig sollte den letzten Strich entfernen, holte aber ab und zu früher entfernte Striche zurück.
- Das passierte auch bei Glättung „Normal“ und wenn man an derselben Stelle neu zeichnet.

**Ursache 1, im Test nachgewiesen:** Zwei Schritte wurden einer.
- Der Editor meldet jeden Strich und jedes Radieren als eigenen Rückgängig-Schritt.
- iOS fasst aber alles, was im selben Durchlauf der Hauptschleife gemeldet wird, zu **einem** Schritt zusammen.
- Ist das iPad kurz beschäftigt (volle Seite sichern, Abgleich), arbeitet iOS die gestauten Berührungen in einem
  Durchlauf ab. So wurden „radieren“ und „nächster Strich“ ein Schritt.
- Ein Rückgängig nahm dann den Strich weg und holte gleichzeitig die radierten Striche zurück.
- Test `testStepsInOneBusyMomentStaySeparate`: auf develop **rot**, jetzt grün.

**Ursache 2, Bauart:** Rückgängig setzte die ganze Seite auf ein gemerktes Foto „vorher“ zurück.
- War dieses Foto veraltet, kam alles darauf Gemerkte zurück, auch längst Gelöschtes.
- Veraltet sein kann es zum Beispiel durch Ursache 1, nach Neuladen oder Abgleich der Seite, oder durch einen
  Reihenfolge-Unterschied am Gerät.

**Behebung:**
- Jeder Schritt (Strich, Radieren, Lasso, Objekte) ist ausdrücklich ein eigener Rückgängig-Schritt
  (`UndoManager.beginSeparateStep`).
- Ein Schritt merkt sich nur noch, welche Striche er hinzugefügt und welche er entfernt hat (`InkUndoStep`).
  Rückgängig nimmt genau diese Striche zurück, auf dem Stand, den die Seite jetzt hat. Ein Strich, den der Schritt
  nicht selbst entfernt hat, kommt nie zurück.
- Schritte ohne Änderung werden nicht mehr gemerkt. Vorher löschten sie die Wiederholen-Liste, und Rückgängig tat
  scheinbar nichts.
- Die Bündelung durch iOS bleibt sonst an. Textfelder nutzen denselben Verlauf und bräuchten sonst eigene Gruppen.

**Tests (`UndoStrokesAppTests`, echte Striche über die Wege von PencilKit):**
- Ihr Fall: Strich A, Rückgängig, Strich B an derselben Stelle. Danach steht nur B da, auch nach Sichern,
  Vorschau, Abgleich und Seitenwechsel. Geprüft für Glättung Normal, Leicht und Aus, je mit Formerkennung an und aus.
  Ehrlich: Im Simulator war dieser Fall auch auf develop schon grün. Am iPad kam er sehr wahrscheinlich über
  Ursache 1 bzw. 2 zustande, und beide sind jetzt behoben.
- Schreiben, Radieren, Rückgängig und Wiederholen in Serie, in beiden Reihenfolgen der PencilKit-Meldungen,
  mit Pausen und Sichern.
- Abgleich direkt nach dem Radieren, Seitenwechsel.
- Rechnung `InkUndoStep`: Ein inzwischen woanders gelöschter Strich bleibt gelöscht, ein inzwischen neu
  geschriebener bleibt stehen.

## 2. Formen erkennen klappte am iPad nicht (Build 39)

**Ursache 1, Reihenfolge:**
- Die Erkennung lief nur, wenn iOS erst „Zeichnung geändert“ und dann „Stift abgesetzt“ meldet.
- Am iPad kommt es offenbar umgekehrt. Dann wurde die Erkennung übersprungen, und ebenso die Glättung „Leicht/Aus“.
- Jetzt läuft beides in jeder Reihenfolge.

**Ursache 2, Haltezeit:**
- Die Haltezeit wurde aus den Punkten von PencilKit gelesen. Steht der Stift still, legt PencilKit oft keine
  Punkte mehr an.
- Jetzt misst die App die Haltezeit an den Zeitstempeln des Stifts selbst (`RawStroke.heldDuration`): ½ Sekunde
  im Umkreis von 6 Punkten.

`ShapeRecognizer.swift` selbst ist unverändert. Daran arbeitet eine eigene Sitzung; mein Vorschlag dafür: Formen
erst ab 18 statt 12 Punkten, damit ein „o“ beim Nachdenken kein Kreis wird.

**Zur Kontrolle am Gerät:** Jede Prüfung schreibt eine Zeile ins Protokoll (Konsole am Mac, Kategorie
„Formerkennung“: gehaltene Sekunden, still ja/nein).

**Tests:**
- Kreis mit ½ s Halten wird in beiden Reihenfolgen ersetzt, und das ist ein Rückgängig-Schritt.
- Ohne Halten bleibt der Strich.
- Mit Schalter „aus“ bleibt der Strich.

## Was nur am echten iPad prüfbar ist

- Ob die Reihenfolge der Meldungen am Gerät wirklich umgekehrt ist. Der Code arbeitet jetzt mit beiden Reihenfolgen.
- Wie zuverlässig die Formerkennung mit echter Hand auslöst.
