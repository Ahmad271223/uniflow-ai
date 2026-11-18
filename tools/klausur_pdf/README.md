# klausur_pdf

PDF-Programm für den Klausur-Generator (`.claude/skills/klausur-generator/SKILL.md`). Baut aus einer JSON- oder
Markdown-Datei ein Aufgaben-PDF im Layout einer Originalklausur, ein Lösungs-PDF (Merke, Schritte, Ergebnis
hervorgehoben) und Formelblatt-PDFs („Aufgabe: …“ über jeder Formel).

## Einrichten

```bash
python -m pip install -r tools/klausur_pdf/requirements.txt
cd tools/klausur_pdf
python -m klausur_pdf fonts          # muss „fehlende Zeichen: keine“ melden
python -m pytest tests -q            # 10 Tests
```

Auf dem Mac gibt es kein `python`. Dort die Projekt-Umgebung nehmen, also überall `~/uniflow-ai/.venv/bin/python`
statt `python` (dort sind reportlab, pytest und sympy installiert).

Die Schrift wird automatisch gesucht (DejaVu Sans unter Linux, Arial Unicode oder DejaVu auf dem Mac, Cambria Math
unter Windows). Fettdruck kommt aus der passenden Fettschrift (auf dem Mac Arial Bold). Fehlt ihr ein Zeichen, zum
Beispiel ∠ oder ℝ, steht nur dieses eine Zeichen in der Grundschrift, der Rest bleibt fett. Eine andere Schrift: Umgebungsvariable `KLAUSUR_PDF_FONT=/pfad/zur/schrift.ttf` (bei `.ttc`
`pfad#index`), optional `KLAUSUR_PDF_FONT_BOLD`.

## Aufruf

```bash
python -m klausur_pdf build --input PK-03.json --out pdf/
python -m klausur_pdf from-markdown --input PK-03.md --out pdf/
python -m klausur_pdf build-all --dir 04-Probeklausuren --out pdf/
```

Aus einem anderen Ordner: `PYTHONPATH=<Repo>/tools/klausur_pdf python -m klausur_pdf …`

Ausgabe: `<Titel>-Aufgaben.pdf`, `<Titel>-Loesungen.pdf` (wenn Lösungen da sind), bei `typ: formelblatt`
`<Titel>.pdf`. `build-all` baut alle `.json` eines Ordners und alle `.md` ohne gleichnamige `.json`.

## Eingabe

JSON wie in SKILL.md, Abschnitt 10 (`typ`, `fach`, `titel`, `untertitel`, `meta`, `hinweis`, `aufgaben`,
`loesungen`, `formeln`). Zusätzliche `meta`-Felder: `datum`, `fakultaet`, `platz_mm` (Platz zum Rechnen nach jeder
Aufgabe).

Markdown (Prompt-Modus), Beispiel in `tests/beispiel.md`:

- Kopfblock zwischen `---` mit `typ`, `fach`, `titel`, `untertitel`, `dauer`, `punkte`, `hilfsmittel`, `semester`, `datum`, `hinweis`
- `## Teil 1: Aufgaben`, darin `### Aufgabe 1 (2 + 1 Punkte)`, Teilaufgaben als Zeilen `(a) …`
- `## Teil 2: Lösungen`, darin `### Aufgabe 1`, `**Merke:** …`, `(a)` auf eigener Zeile, Schritte als Zeilen,
  `▶ **Ergebnis**`, `**Wichtig für die Klausur:** …`
- Formelblatt (`typ: formelblatt`): `## Abschnitt`, `**Aufgabe: „…“**`, darunter die Formel, `Hinweis: …`

Vektoren werden als Zeilen gesetzt, zum Beispiel (1, 2, 2). Spaltenvektoren gibt es noch nicht.
