# KI-Modellvergleich: Haiku 5.5 vs. Sonnet 5.5, Text vs. PDF (25.10.2026)

Frage des Inhabers: Reicht Haiku zum Analysieren von Folien und für Wochentests auch bei schweren Fächern wie Mathe
und Elektrotechnik?

## Ergebnis

- **Die Eingabe entscheidet, nicht das Modell.** Mit PDF-Seiten als Eingabe waren alle Aufgaben beider Modelle
  fachlich richtig. Mit dem heute aus dem PDF gelesenen Text waren es 85 bis 90 %. Bei Scans und Handschrift fiel die
  Text-Variante ganz aus: Beide Modelle hielten die Seiten für leer, Sonnet erfand sogar Themen.
- **Haiku 5.5 mit PDF reicht** für Einordnung, Zusammenfassung und Wochentests, auch in Mathe, Numerik,
  Signale und Systeme sowie Elektrotechnik. Es ist so gut wie Sonnet mit PDF und kostet etwa ein Siebzehntel.
- Nicht geprüft: das **Bewerten von Antworten** der Studierenden. Das braucht einen eigenen Vergleich.

## Aufbau

- 20 echte Dateien aus LUH-Kursen: Elektrotechnische Grundlagen (4), Mathematik I (7), Numerik (4),
  Signale und Systeme (5). Vorlesungsfolien, Skripte, Übungsblätter, Lösungen, Klausuren, 3 Scans mit Handschrift.
  Große Dateien auf die ersten 10 Seiten gekürzt, in allen Varianten gleich.
- Je Datei 4 Varianten: Haiku 5.5 und Sonnet 5.5, jeweils mit extrahiertem Text (wie die App heute, bis 14.000
  Zeichen) und mit der PDF-Datei. Aufgabe: Einordnung, Zusammenfassung, 3 Klausuraufgaben mit Musterlösung.
- Bewertung: Opus 5.5 liest das Original-PDF und bewertet die vier Antworten anonym und gemischt, mit Nachrechnen.
- Eigene Stichprobe: 6 Haiku-PDF-Aufgaben der zwei schwersten Dateien (Laplace, Pol-Nullstellen, z-Transformation,
  Differenzengleichung; Newton, Lagrange, implizites Euler) vollständig nachgerechnet: alle richtig.

## Zahlen

| Variante | Einordnung (0–2) | Zusammenfassung (0–2) | Aufgaben passen | Aufgaben richtig | als Test nutzbar | Kosten je Datei (API, geschätzt) |
| --- | --- | --- | --- | --- | --- | --- |
| Haiku, Text | 1,40 | 1,30 | 73 % | 85 % | 65 % | 0,005 $ |
| **Haiku, PDF** | **1,90** | **1,90** | **100 %** | **100 %** | **95 %** | **0,012 $** |
| Sonnet, Text | 1,55 | 1,50 | 78 % | 90 % | 80 % | 0,045 $ |
| Sonnet, PDF | 2,00 | 1,95 | 100 % | 100 % | 100 % | 0,202 $ |

Nur Scans und Handschrift (3 Dateien): Text-Varianten 0 % nutzbar, PDF-Varianten 100 %.

Nach Fach, Anteil nutzbarer Tests:

| Fach | Haiku Text | Haiku PDF | Sonnet Text | Sonnet PDF |
| --- | --- | --- | --- | --- |
| Elektrotechnik (4) | 100 % | 75 % | 100 % | 100 % |
| Mathematik I (7) | 29 % | 100 % | 71 % | 100 % |
| Numerik (4) | 75 % | 100 % | 75 % | 100 % |
| Signale und Systeme (5) | 80 % | 100 % | 80 % | 100 % |

Die eine nicht nutzbare Haiku-PDF-Datei (Elektrotechnik) war fachlich richtig, fragte aber nur das
Inhaltsverzeichnis eines 190-seitigen Skripts ab. Kleine Mängel bei Haiku-PDF: ein Vorzeichen in einer
Zwischenrechnung (Ergebnis trotzdem richtig), einmal ±√2 statt √2 bei ω ≥ 0.

Kosten: geschätzt für die Claude-API (Haiku 0,10/0,50 $, Sonnet 2/10 $ je 1 Mio. Token), ohne den Grundaufwand des
Claude-Kommandozeilenwerkzeugs, mit dem gemessen wurde. Laufzeit je Datei 40 bis 65 Sekunden.

## Empfehlung

1. **PDF-Seiten statt Text an die KI geben**, mindestens wenn der Text dünn ist (Scans, Handschrift, Formeln).
   Der heutige Weg über `text_excerpt` (4.000 Zeichen) ist noch schwächer als die hier geprüften 14.000 Zeichen.
2. **Haiku 5.5 mit PDF** für Dateianalyse und Wochentests. Mit den gemeinsamen Tests (einmal je Inhalts-Hash)
   kostet das je Foliensatz etwa einen Cent, für alle Nutzer zusammen.
3. Sonnet 5.5 mit PDF höchstens als Zweitprüfung, z. B. wenn Nutzer einen Fehler melden.
4. Nie Aufgaben aus fast leerem Text erzeugen: unter ca. 300 Zeichen pro Seite immer PDF verwenden.
5. Als Nächstes vergleichen: Bewertung der Antworten (Haiku vs. Sonnet), dort entstehen nach dem Teilen die meisten Kosten.

## Grenzen

20 Dateien mit je 3 Aufgaben (60 Aufgaben je Variante), ein Prüfermodell, Prüfer aus derselben Modellfamilie,
nur die ersten 10 Seiten großer Dateien, nur LUH-Kurse. Die eigene Stichprobe bestätigt das Prüferurteil für 6 Aufgaben.
