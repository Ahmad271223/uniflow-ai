# Auftrag an die Mac-Sitzung: Klausur-Generator (17.11.2026)

Die PC-Sitzung hat den **Klausur-Generator** ins Repo gebracht. Es ist ein Werkzeug für die Lernvorbereitung des Inhabers, kein Teil der App: Es berührt weder App-Code noch Server noch Daten.

## Was neu ist

| Pfad | Inhalt |
| --- | --- |
| `.claude/skills/klausur-generator/SKILL.md` | Skill für Claude Code. Aufruf: `/klausur-generator <Fach-Ordner> [Klausurname]` oder `/klausur-generator alle`. Erzeugt je Fach und Klausur: Analyse, Themenliste, gelöste Altklausuren, 10 Probeklausuren, Formelblatt, Lernplan, `_pruefung.py` (sympy, muss mit `ALLES OK` enden) und PDFs. |
| `tools/klausur_pdf/` | PDF-Programm (Python, reportlab). Baut aus JSON oder Markdown ein Aufgaben-PDF im Klausur-Layout, ein Lösungs-PDF und ein Formelblatt-PDF. Mit `README.md`, `requirements.txt` und 8 Tests in `tests/`. |

## Auf dem PC geprüft (Windows, Python 3.14, reportlab 4.4.10)

- `python -m pytest tests -q` in `tools/klausur_pdf`: 8 bestanden.
- `python -m klausur_pdf fonts`: Cambria Math, keine fehlenden Zeichen.
- Die erste Seite aller drei PDF-Arten wurde als Bild gerendert und angesehen. √, ‖, ∠, ℝ, π und ▶ werden richtig dargestellt, Fettdruck ebenfalls.

## Noch nicht geprüft

**Auf dem Mac ist nichts geprüft.** Bitte dort:

1. `develop` holen. Normaler Merge, **kein** `pull --rebase` (siehe Erfahrung vom 27.10.).
2. `python3 -m pip install -r tools/klausur_pdf/requirements.txt`. Ein venv ist empfohlen, falls das System-Python geschützt ist.
3. `cd tools/klausur_pdf && python3 -m klausur_pdf fonts`. Erwartet wird „fehlende Zeichen: keine“.
   - Gesucht werden Arial Unicode (`/System/Library/Fonts/Supplemental/Arial Unicode.ttf`) und DejaVu.
   - Fehlt beides, `KLAUSUR_PDF_FONT` setzen und den Pfad hier eintragen.
4. `python3 -m pytest tests -q`. Erwartet werden 8 bestandene Tests.
5. Eine Beispiel-PDF bauen und die erste Seite ansehen: `python3 -m klausur_pdf build --input tests/beispiel.json --out /tmp/kpdf`.
6. Das Ergebnis unten unter „Ergebnis Mac“ eintragen. Nur wirklich ausgeführte Schritte als bestanden melden.

## Hinweise

- Der Skill nennt Windows-Pfade (`C:\Users\…\UniFlow-Export`). Auf dem Mac muss der Fach-Ordner im Aufruf angegeben werden.
- Die Fachdaten selbst (UniFlow-Export, Wissensbibliothek) liegen nur auf dem PC und kommen **nicht** ins Repo. Sie enthalten Kursmaterial; personenbezogene Dateien wurden nur aus den Kopien entfernt.
- Kein Release, kein Merge nach `main`, keine kostenpflichtigen Dienste nötig.

## Ergebnis Mac

(von der Mac-Sitzung auszufüllen)
