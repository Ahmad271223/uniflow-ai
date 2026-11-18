# Auftrag an die Mac-Sitzung: Klausur-Generator (17.11.2026)

Die PC-Sitzung hat den **Klausur-Generator** ins Repo gebracht. Es ist ein Werkzeug für die Lernvorbereitung des Inhabers, kein Teil der App: Es berührt weder App-Code noch Server noch Daten.

## Was neu ist

| Pfad | Inhalt |
| --- | --- |
| `.claude/skills/klausur-generator/SKILL.md` | Skill für Claude Code. Aufruf: `/klausur-generator <Fach-Ordner> [Klausurname]` oder `/klausur-generator alle`. Erzeugt je Fach und Klausur: Analyse, Themenliste, gelöste Altklausuren, 10 Probeklausuren, Formelblatt, Lernplan, `_pruefung.py` (sympy, muss mit `ALLES OK` enden) und PDFs. |
| `tools/klausur_pdf/` | PDF-Programm (Python, reportlab). Baut aus JSON oder Markdown ein Aufgaben-PDF im Klausur-Layout, ein Lösungs-PDF und ein Formelblatt-PDF. Mit `README.md`, `requirements.txt` und Tests (am PC 8, seit der Mac-Prüfung 10) in `tests/`. |

## Auf dem PC geprüft (Windows, Python 3.14, reportlab 4.4.10)

- `python -m pytest tests -q` in `tools/klausur_pdf`: 8 bestanden.
- `python -m klausur_pdf fonts`: Cambria Math, keine fehlenden Zeichen.
- Die erste Seite aller drei PDF-Arten wurde als Bild gerendert und angesehen. √, ‖, ∠, ℝ, π und ▶ werden richtig dargestellt, Fettdruck ebenfalls.

## Noch nicht geprüft

Stand 17.11.2026 nachmittags: **Auf dem Mac geprüft, alle sechs Punkte erledigt** (Einzelheiten unter „Ergebnis Mac“). Die Prüfliste war:

1. [x] `develop` holen. Normaler Merge, **kein** `pull --rebase` (siehe Erfahrung vom 27.10.).
2. [x] `python3 -m pip install -r tools/klausur_pdf/requirements.txt`. Ein venv ist empfohlen, falls das System-Python geschützt ist.
3. [x] `cd tools/klausur_pdf && python3 -m klausur_pdf fonts`. Erwartet wird „fehlende Zeichen: keine“.
   - Gesucht werden Arial Unicode (`/System/Library/Fonts/Supplemental/Arial Unicode.ttf`) und DejaVu.
   - Fehlt beides, `KLAUSUR_PDF_FONT` setzen und den Pfad hier eintragen.
4. [x] `python3 -m pytest tests -q`. Erwartet werden 8 bestandene Tests.
5. [x] Eine Beispiel-PDF bauen und die erste Seite ansehen: `python3 -m klausur_pdf build --input tests/beispiel.json --out /tmp/kpdf`.
6. [x] Das Ergebnis unten unter „Ergebnis Mac“ eintragen. Nur wirklich ausgeführte Schritte als bestanden melden.

## Hinweise

- Der Skill nennt Windows-Pfade (`C:\Users\…\UniFlow-Export`). Auf dem Mac muss der Fach-Ordner im Aufruf angegeben werden.
- Die Fachdaten selbst (UniFlow-Export, Wissensbibliothek) liegen nur auf dem PC und kommen **nicht** ins Repo. Sie enthalten Kursmaterial; personenbezogene Dateien wurden nur aus den Kopien entfernt.
- Kein Release, kein Merge nach `main`, keine kostenpflichtigen Dienste nötig.

## Ergebnis Mac

Geprüft am 17.11.2026 von der Mac-Sitzung. **Der Klausur-Generator läuft auf dem Mac.** Ein Fehler wurde gefunden und behoben (Fettdruck), ein zweiter kleiner Fehler ebenfalls (doppelte Schritt-Nummer).

### Umgebung

- macOS 26.6 (25G72), Python 3.13.18 aus der Projekt-Umgebung `~/uniflow-ai/.venv` (dieselbe, die `tools/tests-schnell.sh` benutzt). Nichts systemweit installiert, kein `sudo`.
- Neu in `.venv` installiert: reportlab 5.1.0 (am PC: 4.4.10), pillow 13.0.0, charset-normalizer 3.5.2. pytest 9.1.1 war schon da.
- Zusätzlich sympy 1.14.0 (mit mpmath 1.3.0) in `.venv`, weil der Skill damit die `_pruefung.py` rechnet. `python -I -c "import sympy"` geht.
- Aufruf auf dem Mac immer mit `~/uniflow-ai/.venv/bin/python` statt `python` oder `python3`.

### Ergebnis je Schritt

| Schritt | Ergebnis |
| --- | --- |
| 1. `develop` holen | Erledigt mit `git fetch origin` und `git merge origin/develop` (Vorspulen auf `0b70c3fe`, kein Rebase). |
| 2. Abhängigkeiten | Erledigt, siehe oben. Keine Fehlermeldung. |
| 3. `python -m klausur_pdf fonts` | `Schrift: /System/Library/Fonts/Supplemental/Arial Unicode.ttf`, `fehlende Zeichen: keine`. DejaVu gibt es auf diesem Mac nicht, `KLAUSUR_PDF_FONT` ist nicht nötig. |
| 4. Tests | Vor meiner Änderung: 8 bestanden. Nach meiner Änderung: 10 bestanden (2 neue Tests). |
| 5. Beispiel-PDFs | Gebaut mit `build` (JSON), `from-markdown`, `build` (Formelblatt) und `build-all`. Von allen fünf PDFs die erste Seite mit `sips -s format png -Z 1700` als Bild gerendert und angesehen. Ablage außerhalb des Repos: `~/Studora-Builds/klausur-generator/` (Unterordner `vorher/` = Stand vor der Fettdruck-Korrektur). |

### Was auf den Bildern zu sehen ist

- Aufgaben-PDF: Kopfzeile mit Semester, Fach und Titel, Namensfeld und Matrikelnummer, Zeile mit Bearbeitungszeit, Gesamtpunkten und Hilfsmitteln, grauer Hinweiskasten, Aufgaben mit Punkten, eingerückte Teilaufgaben, Punktetabelle mit Σ, Fußzeile mit Seitenzahl. Alles da.
- Lösungs-PDF: gelber Merke-Kasten, Schritte, blauer Ergebniskasten mit ▶. Alles da.
- Formelblatt: Abschnitte, „Aufgabe: …“ über jeder Formel, Hinweiszeile. Alles da.
- Zeichen: √, ‖, ∠, ℝ, π, ▶, ∈, ×, ·, −, ², ₀, ±, ⇒, φ, Σ und die Umlaute werden richtig dargestellt.

### Gefundener Fehler 1: kein Fettdruck auf dem Mac (behoben)

- Vorher war auf dem Mac **nichts** fett: keine Überschrift, kein „Merke:“, kein „Schritt 1:“, kein Ergebnis. Grund: Arial Unicode hat keinen fetten Schnitt, und in `fonts.py` stand für den Mac keine Fettschrift.
- Kleinster sauberer Weg: Arial Bold (`/System/Library/Fonts/Supplemental/Arial Bold.ttf`, liegt auf jedem Mac, gleiche Schriftfamilie) ist jetzt die Fettschrift zu Arial Unicode. Keine Schrift installiert, keine Schrift ins Repo gelegt.
- Arial Bold fehlen sieben Pflichtzeichen: ∠ ℝ ∈ ₀ ₁ ₂ ▶. Früher hätte eine Zeile mit so einem Zeichen den Fettdruck ganz verloren. Jetzt setzt `render.fett()` nur das einzelne Zeichen in der Grundschrift, der Rest der Zeile bleibt fett. Beispiel: In „▶ ∠(x, y) = π/4“ ist nur das ∠ nicht fett.
- Das wirkt genauso unter Windows und Linux, falls dort der Fettschrift ein Zeichen fehlt. Kann die Fettschrift alles (DejaVu), ändert sich nichts. **Am PC bitte einmal `python -m pytest tests -q` wiederholen** (erwartet: 10 bestanden) und ein Lösungs-PDF ansehen.

### Gefundener Fehler 2: „Schritt 1:“ doppelt oder nicht fett (behoben, betrifft auch den PC)

- Stand im Markdown `**Schritt 1:** …` (so verlangt es der Lösungsstil im Skill), kam im PDF „Schritt 1: Schritt 1: …“ heraus.
- Stand dort `Schritt 1: …` ohne Sternchen, war die Nummer nicht fett, bei den automatisch nummerierten Zeilen daneben aber schon.
- Jetzt gibt es `render.schritt_markup()`: Die Nummer steht genau einmal da und ist immer fett. Dazu ein neuer Test.

### Geänderte Dateien

- `tools/klausur_pdf/klausur_pdf/fonts.py`: Arial Bold als Fettschrift für den Mac.
- `tools/klausur_pdf/klausur_pdf/render.py`: `fett()` mischt die Schriften zeichenweise, neu `schritt_markup()`.
- `tools/klausur_pdf/tests/test_klausur_pdf.py`: 2 neue Tests (zusammen 10).
- `tools/klausur_pdf/README.md` und `.claude/skills/klausur-generator/SKILL.md`: Hinweis zum Aufruf auf dem Mac.

### Was nicht geprüft ist

- **Der Skill selbst (`/klausur-generator <Fach-Ordner>`) ist auf dem Mac nicht gelaufen.** Es gibt hier keinen Fach-Ordner: `~/Documents/UniFlow-Export` existiert auf dem Mac nicht. Geprüft ist nur das PDF-Programm mit den drei Beispieldateien aus `tests/`.
- Nur einseitige PDFs angesehen. Seitenumbruch bei langen Klausuren ist auf dem Mac nicht geprüft.
- Die PDFs wurden nur als Bild (über `sips`) angesehen, nicht ausgedruckt und nicht in anderen Programmen geöffnet.
- Die Änderung am Fettdruck ist unter Windows nicht gelaufen (siehe oben).

### Kleinigkeit, nicht geändert

- Im Aufgaben-PDF stößt die Linie hinter „Name:“ direkt an das Wort „Matrikelnummer:“. Es fehlt ein kleiner Abstand. Das ist auf dem PC genauso und stört beim Ausfüllen nicht.
