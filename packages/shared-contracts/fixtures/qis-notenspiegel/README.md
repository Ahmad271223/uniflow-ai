# Fixtures LUH-Notenspiegel (echter Aufbau, erfundene Daten)

Beschreibung des echten QIS-Notenspiegels der LUH vom Inhaber (12.11.2026, aus einer anderen App; deren Code wurde
nicht uebernommen, nur Regeln und Testdaten). Weg: Mein Studium -> Notenspiegel / Studienverlauf -> (bei "Bitte
wählen Sie aus" den Abschluss waehlen) -> "Leistungen für … anzeigen".

- `luh-notenspiegel.tsv`: die Testdaten des Inhabers, Tabulator-getrennt wie aus QIS kopiert (Kopfzeile
  `PrfNr. | Bezeichnung der Leistung | Prf.Art | Semester  | Note | Status | Leistungspunkte | Datum | Versuch | Vermerk |
  Freiversuch`, Leerzeichen in Zellen, die Kompetenzbereich-Zeile hat keine Zelle fuer Art und Semester).
- `luh-notenspiegel.html`: dieselben Zeilen als QIS-Tabelle (`<th class="tabelleheader">`, `<td>` mit Leerraum und
  `&nbsp;`, Kompetenzbereich mit `colspan="2"` ueber Art und Semester) im Seitenaufbau von
  `../exam-registration/qis-echt-list.html` (Kopf, Brotkrumen, Stammdaten-Tabelle "Erika Beispiel" (nie gelesen),
  PDF-Link und Formular (nie benutzt), Sitzung asi=S1abcDEF erfunden).

Erwartet (tests/test_qis_notenspiegel_echt.py, Swift QISNotenspiegelEchtTests): 4 Leistungen (PL-Zeilen 110, 1110,
1110, 132110); Kompetenzbereich 11 (Schnitt 2,5, 22 LP) ist eine Summe und zaehlt nie; 110 anerkannt ohne Note
(0,0), Modul 100; 1110 Fehlversuch SoSe 25 (22.08.2025), bestanden SoSe 26 mit 3,3, 5 LP, 2026-08-21, im
Studienverlauf Versuch 2; 132110 gehoert zu Modul 2500 (Studium Generale); LP 19 (8 + 5 + 6); Schnitt 3,3.
