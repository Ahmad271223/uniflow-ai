# Studienordnung inklusive Modulhandbuch (Uni Hildesheim): Leser-Fixtures

Erwartungswerte des Lesers `app/study_catalog_hildesheim.py` (Python) und
`UniFlowCore/StudyCatalog/StudyCatalogHildesheimParser.swift` (Swift). Beide müssen dieselben kanonischen Texte liefern
(`dumps`, `texts_dumps`, `details_dumps`, `head_dumps`). Erzeugt von `tools/gen-study-catalog-hildesheim-fixture.py`
(Prüfung mit `--check`), nie von Hand ändern. Geprüft von `tests/test_study_catalog_hildesheim.py` und
`StudyCatalogHildesheimParserTests`.

**Alle Inhalte sind erfunden** (Studiengänge, Module, Namen, Heftnummern, Daten). Nur der Aufbau folgt den echten
Studienordnungen: Titelseite, Paragrafen, Anlage 1 mit „Gesamtzahl der Leistungspunkte“, Anlage 2 Studienablaufplan,
Anlage 3 Modulhandbuch mit der zweispaltigen Tabelle je Modul, Seitenkopf. Echte Ordnungen gehören nicht in diesen
Ordner.

- `verkuendungsblatt.json`  Seitentexte, wie pypdf sie liefert: Seitenkopf „Verkündungsblatt … - Seite N -“, Titel über
  zwei Zeilen, Teilmodule, Wert über die Seitengrenze, zweizeilige Feldnamen, LP als Summe, weitere Anlage danach
- `lesefassung.json`        Textstücke mit Lage `[x, y, text]` in PDFKit-Reihenfolge (erst Feldnamen, dann Werte) →
  `row_pages` / `rowPages` → Seitentexte; Titelseite „Lesefassung (Stand …)“, Master mit „Master of Arts“
- `pdfkit-roh.json`         roher PDFKit-Text mit mehreren Feldnamen in einer Zeile: nur Titel, LP, Teilmodule und Texte
  bleiben, alles nicht sicher Zuordenbare ist leer
- `werte.json`              Einzelfälle: Fachsemester, Turnus, Leistungspunkte, Teilmodule, Kürzen, Erkennung
