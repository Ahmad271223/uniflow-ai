# Fixture Texterkennung (OCR)

`rules.json` – Regeln der Texterkennung für PDF-Seiten ohne Textebene aus der Python-Referenz (`app/pageocr.py`). Erzeugt mit

```
python tools/gen-ocr-fixture.py          # schreibt die Datei
python tools/gen-ocr-fixture.py --check  # Exitcode 1, wenn veraltet
```

Nicht von Hand ändern. Inhalt: `minimum_letters` (20) und `batch_size` (4), die Tabelle `page_ocr`, `sparse` (Text, Zahl der
Buchstaben, „fast leer“; Grenzfälle 19/20, Ziffern, Umlaute, zerlegtes ä), `scopes` (keine / bestimmte Seiten / erste n / alle),
`batches` (Stapel von 4), `decisions` (ersetzt der erkannte Text die Textebene: nur bei mehr Buchstaben) und `embedded`
(Zuordnung zur Textebene: nur eine Zeile, deren Text die Seite noch trägt, wird zurückgesetzt).

Geprüft von: Python (`tests/test_pageocr.py`). Swift (`PageOCRStore`) und Kotlin können dieselbe Datei lesen; die Swift-Regeln
(`letters`, `isSparse`, `OCRScope`, `embedded`) sind dieselben.
