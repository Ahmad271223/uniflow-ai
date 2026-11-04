# Fixture Word/PowerPoint-Text

Kleine echte `.docx`/`.pptx`-Dateien (nur Standardbibliothek erzeugt, feste Zeitstempel) und die Seiten, die
`app/extract.py` daraus liest (docs/DATEIARTEN.md). Erzeugt mit

```
python tools/gen-office-fixture.py          # schreibt die Dateien
python tools/gen-office-fixture.py --check  # Exitcode 1, wenn veraltet
```

Nicht von Hand ändern. Inhalt von `cases.json`: `files` (Datei, `kind`, erwartete Seiten), `kinds` (Dateiname → `kind`),
`paragraph_pages` (Absätze, Überschriften, Umbrüche → Seiten; Grenzen `soft_page_chars` 3000 und `hard_page_chars` 6000).

- `bericht.docx`: Titel, Überschriften (Formatvorlage und `outlineLvl`), Umlaute, Tabulator und Zeilenumbruch im Absatz,
  leere Absätze, Tabelle, Textkasten (Choice und Fallback nur einmal), Feldcode und gelöschter Text (kein Text), echter
  Seitenumbruch, weiche Grenze an einer Überschrift, harte Grenze ohne Überschrift.
- `leer.docx`: ohne Text → keine Seiten.
- `folien.pptx`: vier Folien in der Reihenfolge der Präsentation (nicht der Dateinamen), Aufzählung mit Zeilenumbruch,
  Foliennummer-Platzhalter ausgelassen, Notizen an Folie 2, Folie ohne Text als leere Seite, ein ungepackter ZIP-Eintrag.

Geprüft von: Python (`tests/test_office_text.py`), Kern (`OfficeTextTests.swift`), Web (`tests/js/filekinds.test.mjs`).
