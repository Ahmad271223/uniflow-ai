# Fixtures Pruefungsanmeldung

- period-cases.json: ERZEUGT von tools/gen-exam-registration-fixture.py (Zuordnung Studiengang -> Terminseite, Phase je
  Tag aus app/exam_registration.py; der Kern prueft dieselben Faelle).
- qis-*.html: ERFUNDENE Seiten im Aufbau des HIS-QIS der LUH (Rechner qis.verwaltung.uni-hannover.de, Person
  "Erika Beispiel", Sitzung asi=S1abcDEF). Die echte Seite "Info über angemeldete Prüfungen" ist noch nicht gesehen
  (docs/PRUEFUNGSANMELDUNG-2026-11-05.md); die Seiten zeigen die Formen, die der Leser vertragen muss:
  qis-start, qis-studium (mit dem Link "Prüfungsanmeldung/-abmeldung", dem nie gefolgt werden darf), qis-info-tree
  (Baum: Abschluss), qis-info-expanded (Studiengang mit Bild-Link), qis-info-list (Tabelle mit Ruecktritt und
  "Abmelden"-Links je Zeile), qis-info-empty (keine Anmeldung), qis-info-direct (Tabelle direkt, andere Spaltenkoepfe).
