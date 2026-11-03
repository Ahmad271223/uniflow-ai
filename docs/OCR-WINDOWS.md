# Texterkennung (OCR) für Scan-Seiten, Windows und Web

Stand 03.11.2026. Gegenstück zur Texterkennung auf dem iPad (Apple Vision, `PageOCR.swift`). Code: `app/pageocr.py`,
Regeln als Tabelle: `packages/shared-contracts/fixtures/ocr/rules.json` (`tools/gen-ocr-fixture.py`), Tests:
`tests/test_pageocr.py`.

## Was sie tut

Manche PDF-Seiten haben keine Textebene (Scan, abfotografiertes Blatt, Folie als Bild). Suche, Skriptsuche, KI-Hilfe und
Wochentests sehen dort sonst nichts. Die Texterkennung liest solche Seiten und trägt den Text in `page_texts` ein, damit alle
Leser ihn ohne Änderung finden. Regeln wie auf dem iPad:

- Die Textebene bleibt die erste Wahl. Erkannt wird nur eine Seite mit **weniger als 20 Buchstaben** (Ziffern zählen nicht).
- Nur **bei Bedarf**, nie beim bloßen Öffnen für alle Seiten: Seite öffnen / KI-Hilfe / Skriptsuche zu einer Seite = nur diese
  Seite (`Scope.only`); Index der Skriptsuche und markierte Vorlesungen der Wochentests im Hintergrund = alle (`Scope.all`);
  Abgaben nachlesen, Marker prüfen, Suche im Index = keine.
- Stapel von **4 Seiten**; nach jedem Stapel wird gespeichert. Abbruch (`cancel`) verliert höchstens den laufenden Stapel.
- Ergebnis je Datei, Seite und Änderungszeit **einmal** in der Tabelle `page_ocr` (`file_id, page, chdate, embedded, text`).
  Leer (`""`) heißt „nichts erkannt“ und wird nicht wiederholt. Der erkannte Text ersetzt den fast leeren Text, aber nur, wenn er
  mehr Buchstaben hat als die Textebene.
- Eine neue Fassung der Datei verwirft die Ergebnisse. Die Dokumentversion der Wochentests (`weekly.doc_version`) zählt nur die
  Textebene, damit eine Erkennung keine „geänderte Datei“ vortäuscht und keine Marker zur Prüfung vorlegt.
- Ein Fehler der Erkennung lässt alle Texte unverändert; der nächste Bedarf versucht es erneut. Die Schreibsperre der
  Datenbank wird während der Erkennung nicht gehalten.

## Schalter

| `LERNAPP_OCR` | Wirkung |
| --- | --- |
| leer (Standard) | **Am PC** (Einzelplatz, Windows-App): an, wenn ein Motor gefunden wird. **Im gehosteten Dienst**: aus (Serverlast). |
| `on` | an, wenn ein Motor gefunden wird (auch im Dienst) |
| `off` | aus |

Weitere: `LERNAPP_OCR_ENGINE=tesseract` (Standard) oder `windows`; `LERNAPP_TESSERACT=<Pfad zu tesseract(.exe)>`;
`LERNAPP_OCR_JOBS=2` (gleichzeitige Erkennungen). Ohne Motor, ohne `pypdfium2` oder mit `off` bleibt alles wie bisher.

Im Dienst gilt die Texterkennung nur für Dateien, die auf der Platte liegen. Dort liegt keine Hochschuldatei (Betriebsart
`stream`), also wäre `on` im Dienst heute wirkungslos. Das ist so gewollt, bis geklärt ist, ob der Dienst Scans erkennen soll
(Last, Datenschutz: das Bild verlässt dabei weder den Dienst noch geht es an Dritte).

## Motoren

| Motor | Stand | Kosten, Lizenz | Hinweis |
| --- | --- | --- | --- |
| **Tesseract** (`TesseractOCR`), Programm `tesseract` mit `deu`+`eng` | gebaut, Kommandozeile mit Programm-Ersatz getestet, **mit echtem Tesseract nicht gelaufen** (hier nicht installiert) | kostenlos, Apache-2.0 (Programm und Sprachdaten) | wird nur gestartet, nicht eingebunden. Empfohlen. |
| **Windows.Media.Ocr** (`WindowsMediaOCR`) | **ungeprüft, nur Schnittstelle**; nie unter Windows gelaufen, wird nie von selbst gewählt (nur `LERNAPP_OCR_ENGINE=windows`) | kostenlos, in Windows eingebaut, nichts mitzuliefern | braucht pip-Pakete `winrt-Windows.Media.Ocr`, `…Graphics.Imaging`, `…Storage.Streams`, `…Globalization` und das Windows-Sprachpaket „Deutsch“; Bild höchstens 2600 Pixel |

Tesseract ist als Standard gewählt, weil es sich unter Linux wie unter Windows gleich verhält (testbar, auch in der CI),
Deutsch und Englisch mitbringt und nicht vom Sprachpaket des Rechners abhängt. Die Windows-eigene Erkennung wäre kleiner
im Paket (nichts mitliefern), ist hier aber nicht prüfbar. Erst nach einem Lauf unter echtem Windows mit einem Scan
als Standard erwägen.

## Seiten als Bild rendern

`pypdf` rendert nicht. Optionen:

| Bibliothek | Lizenz | Urteil |
| --- | --- | --- |
| **pypdfium2** | BSD-3-Clause / Apache-2.0 (PDFium BSD-3) | **gewählt**: per pip als fertiges Rad für Windows, Linux, macOS (ca. 4 MB), kein Copyleft, keine Fremdprogramme. `requirements.txt`: `pypdfium2==5.14.0`. |
| PyMuPDF (MuPDF) | **AGPL-3.0** (oder bezahlte Lizenz von Artifex) | **nicht verwenden**: AGPL verlangt bei einem gehosteten Dienst die Offenlegung des gesamten Quelltexts; die Windows-App wäre ebenfalls betroffen. Nur mit gekaufter Lizenz. |
| poppler (`pdftoppm`) | GPL | Fremdprogramm, unter Windows nicht dabei; nicht nötig |

pypdfium2 rendert jede Seite einzeln als Graustufenbild (288 dpi, längste Seite höchstens 4000 Pixel, Drehung beachtet)
und gibt das Bild gleich wieder frei. Tesseract bekommt es als PGM (ohne Pillow). Nur lokal mit pypdfium2 5.14.0 geprüft
(Linux).

## Paketierung für Windows (noch nicht gebaut)

Gebaut werden konnte hier nicht. Vorbereitet:

- `apps/windows/backend/uniflow-backend.spec` nimmt `pypdfium2` und `pdfium.dll` ins Paket (leer, wenn das Paket beim Bauen
  fehlt).
- **Offen, Workflow `.github/workflows/windows.yml`:** Ordner `tesseract` neben die exe legen, wie schon `ms-playwright`:
  `dist/uniflow-backend/tesseract/tesseract.exe`, die zugehörigen DLLs daneben und `dist/uniflow-backend/tesseract/tessdata/`
  mit `deu.traineddata` und `eng.traineddata`. `app/pageocr.py` sucht in dieser Reihenfolge: `LERNAPP_TESSERACT`, Ordner
  `tesseract` im Paket (neben der exe bzw. `_MEIPASS`), `PATH`, `C:\Program Files\Tesseract-OCR`. `tessdata` neben dem Programm
  wird automatisch mit `--tessdata-dir` übergeben, wenn `TESSDATA_PREFIX` nicht gesetzt ist.
- Quelle für Windows-Programm: der Installer der UB Mannheim (Apache-2.0, 64 Bit), entpackt oder in einen Ordner installiert;
  Sprachdaten von `tessdata_fast` (klein, schnell) oder `tessdata_best` (genauer, größer). Größe grob wenige MB je Sprache
  (fast) bis rund 15 MB (best), das Programm mit DLLs rund 40 bis 50 MB: **Schätzung, nicht gemessen**. Der Installer wächst
  entsprechend; Chromium ist weiter der größte Teil.
- Lizenztexte: `LICENSE` von Tesseract und die Hinweise der mitgelieferten DLLs (Leptonica BSD-2, zlib, libpng, libtiff,
  libjpeg, openjpeg, webp, giflib) in den Ordner legen und in die Lizenzseite der App aufnehmen. pypdfium2/PDFium bringt seine
  Hinweise im Rad mit (`dist-info/licenses`).
- Ohne Ordner `tesseract` im Paket bleibt die Erkennung aus (außer ein Tesseract liegt im `PATH`); die App läuft wie bisher.

## Kosten und Last

Keine Gebühren (alles quelloffen, nichts über ein Netz). Rechenzeit grob einige Sekunden je Seite auf einem Laptop
(**Schätzung, nicht gemessen**); deshalb nur bei Bedarf und einmal je Seite. Im Dienst hielte eine Erkennung eine
Anfrage-Task und einen Kern für diese Zeit; darum dort standardmäßig aus.

## Was nicht geprüft werden konnte

- **Echtes Windows**: weder das Paket (PyInstaller, Ordner `tesseract`) noch `WindowsMediaOCR` noch der Start von
  `tesseract.exe` ohne Konsolenfenster (`CREATE_NO_WINDOW` gesetzt, nicht beobachtet).
- **Echter Tesseract auf echten Scans**: hier ist `tesseract` nicht installiert; der Test `test_real_tesseract_recognizes_scan`
  (erzeugt aus einer Text-PDF eine Bild-PDF und erkennt sie) wird dann übersprungen. Erkennungsgüte bei Handschrift, Formeln,
  schrägen Fotos, Tabellen und dunklem Grund ist unbekannt (Tesseract ist dafür bekanntermaßen schwächer als Vision).
- Laufzeit und Speicher je Seite, Verhalten bei sehr großen Dateien.

## Offene Lücken

- Die KI-Analyse (`app/extract.py`, `planner.py`: erste Seiten, Textauszug eines Tests) liest weiter nur die Textebene mit
  pypdf. Auf dem iPad erkennt dort `Scope.leading(10)` bzw. `leading(5)`.
- Im gehosteten Dienst nur mit Datei auf der Platte (siehe Schalter); eine Variante für durchgereichte Bytes gibt es nicht.
- Kein Abbruch von außen im Web (die Endpunkte laufen im Threadpool); `cancel` ist vorbereitet und getestet, aber noch von keinem
  Aufrufer gesetzt.
- Der Hintergrundlauf der Wochentests (`weekly.tick`) erkennt alle Seiten markierter Vorlesungen und der Skripte des Moduls in
  einem Durchgang (Stapel zu 4, danach gespeichert); bei einem 300-Seiten-Scan dauert das Minuten.
- Die Swift-Tests lesen die neue Fixture `fixtures/ocr/rules.json` noch nicht (nur Python prüft sie).
