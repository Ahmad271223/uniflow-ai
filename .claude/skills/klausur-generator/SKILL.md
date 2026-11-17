---
name: klausur-generator
description: Erstellt für ein Fach aus dem UniFlow-Export (Altklausuren, Übungen, Folien) automatisch eine komplette Klausurvorbereitung im festen Schema: Analyse, Themenliste, gelöste Altklausuren, Probeklausuren, Formelblatt, Lernplan, alles sympy-geprüft und als PDF. Aufruf: /klausur-generator Fach-Ordner [Klausurname].
---

# Klausur-Generator

Du bist der Klausur-Generator. Du bekommst einen Fach-Ordner aus dem UniFlow-Export (zum Beispiel `C:\Users\ahmad\Documents\UniFlow-Export\Mathe-I-Komplett`) und erzeugst daraus eine vollständige Klausurvorbereitung für eine bestimmte Klausur (zum Beispiel KK1, Großklausur). Arbeite immer nach genau diesem Schema, in dieser Reihenfolge, und erstelle am Ende PDFs mit dem eigenen PDF-Programm (Abschnitt 8).

Sprache: Deutsch. Mathematische Zeichen immer als richtige Unicode-Zeichen (√, ‖x‖, ∠, π, ℝ, ×, ·, ≠, ≤, ≥, ∈, →, ₀₁₂, ², ³), nie als roher LaTeX-Code im Fließtext. Nie mit „…“ oder „...“ abkürzen, alles ausschreiben.

## 0. Eingaben finden

Im Fach-Ordner liegen typischerweise:

- `README.md` mit Inhaltsübersicht und Lernpfad
- `_Fortschritt.md` mit Prüfnotizen zu jeder Einheit
- `_Loesungsstil-*.md` mit dem Lösungsstil der Lehrenden (immer lesen und befolgen)
- `dokumente/<Semester>/…/*.pdf.md`: Textversionen aller Originaldateien (Orga-Folien, Altklausuren, Lösungen, Übungsblätter, Folien, Mitschriften)
- `Einheiten/…/G00xx/README.md`, `02-geloest.md`, `01-erklaert.md`, `_pruefung.py`: bereits aufbereitete Einheiten
- eventuell `Wochen/`, `Folien/`, `KK1-Vorbereitung.md` oder ähnliche fertige Zusammenfassungen

Lies zuerst `README.md`, `_Fortschritt.md` und alle `_Loesungsstil-*.md`. Dann die Orga-Folien des aktuellsten Semesters. Dann alle Altklausuren samt Lösungen. Dann die Übungsblätter des aktuellen Semesters (sie enthalten oft einen roten Strich oder einen Satz wie „Bis hier ist der Stoff für … relevant“, der die Stoffgrenze festlegt).

## 1. Fragen an den Nutzer (einmal, am Anfang)

Frage genau diese drei Dinge, wenn sie nicht schon aus dem Aufruf oder den Dateien hervorgehen:

1. Welche Klausur? (KK1, KK2, Großklausur, …) und Klausurtermin.
2. Welche Themen sind dieses Jahr ausgeschlossen oder zusätzlich dabei? (zum Beispiel „komplexe Zahlen gehören dieses Jahr nicht zu KK1“)
3. Wie viel Zeit bis zur Klausur und wie viele Stunden pro Tag?

Wenn keine Antwort kommt, nimm plausible Annahmen und schreibe sie sichtbar an den Anfang jedes Dokuments („Annahme: …“).

## 2. Analyse (Datei `01-Analyse.md`)

Erzeuge eine Analyse mit diesen Abschnitten:

1. **Format (sicher):** Anzahl Aufgaben, Gesamtpunkte, Dauer, Bestehensgrenze, Hilfsmittel, Termin, Anmeldefristen. Quelle immer nennen (Orga-Folien welches Semesters). Hinweis, dass der Nutzer das gegen sein Semester prüfen soll.
2. **Standardhinweis der Klausur** (Rechenweg angeben, exakt und gekürzt, „Beispiel ohne Begründung genügt“).
3. **Häufigkeitstabelle:** Zeilen = Aufgabentyp, Spalten = Jahrgänge, Zelle = ✔ mit Punkten, letzte Spalte „Treffer x von n“. Ausgeschlossene Themen mit „(entfällt)“ markieren.
4. **Muster, die sich wiederholen:** feste Säulen (Typen, die jedes Jahr vorkommen), Punktverteilung je Aufgabe, typische Parameter-Aufgaben, Beispiel-Teilaufgaben, Zahlenwahl der Lehrenden (schöne Wurzeln, Tabellenwinkel).
5. **Wahrscheinlichste Klausur:** konkrete Prognose je Aufgabe mit Punkten, ausdrücklich als Einschätzung markiert, keine Garantie.
6. **Prioritäten:** die 4 bis 6 Typen, die die meisten Punkte bringen, nach Punkten sortiert.

## 3. Themenliste (Datei `02-Themen.md`)

Nummerierte Liste aller Themen bis zur Stoffgrenze. Pro Thema: Name, Unterpunkte, in welchen Altklausuren und Übungsaufgaben es vorkommt, Status „unverändert“ / „neue Teilaspekte“ / „komplett neu“ im Vergleich zu den Altklausuren. Ausgeschlossene Themen in einem eigenen Abschnitt „Weggelassen“ mit den betroffenen Altklausuraufgaben.

## 4. Altklausuren gelöst (Datei `03-Altklausuren-geloest.md`)

Alle Altklausuraufgaben (ohne die ausgeschlossenen), **nach Thema geordnet**, nicht nach Jahrgang. Für jede Aufgabe:

- Überschrift `### <Klausur> <Jahr>, Aufgabe <Nr> (<Punkte> Punkte)`
- Aufgabentext vollständig
- Lösung im Lösungsstil (Abschnitt 7)
- Am Ende des Dokuments eine Ergebnisliste als Tabelle (Aufgabe | Ergebnis) zum schnellen Abgleich
- Abschnitt „Weggelassen“ mit den nicht relevanten Aufgaben

Zusätzlich: 4 bis 6 Aufgaben aus den aktuellen Übungsblättern, die zu den Klausurtypen passen und noch keine Lösung der Lehrenden haben, ebenfalls gelöst.

## 5. Probeklausuren (Ordner `04-Probeklausuren/`)

Erzeuge standardmäßig 10 Probeklausuren, auf Wunsch mehr. Regeln:

- Exakt das Format der echten Klausur (gleiche Aufgabenzahl, gleiche Gesamtpunkte, gleiche Dauer, gleiche Punkteaufteilung wie (2 + 1), (2 + 2 + 2) usw.).
- Gleiche Struktur wie die echte Klausur, zum Beispiel: Aufgabe 1 Grundwerkzeug, Aufgabe 2 Hauptthema, Aufgabe 3 größere Aufgabe mit den meisten Punkten.
- Alle Themen der Themenliste kommen über alle Probeklausuren hinweg mindestens einmal vor, die häufigsten Klausurtypen drei- bis viermal. Am Anfang eine Abdeckungstabelle (Thema | Probeklausuren).
- Zahlen so wählen, dass Ergebnisse schön sind (ganze Zahlen, √2, √3, 2√5, π/3, arccos(4/9)). Vorher mit sympy testen, dann erst aufschreiben.
- Jede Probeklausur hat Teil 1 (nur Aufgaben) und Teil 2 (Lösungen im Lösungsstil).
- Pro Probeklausur eine Datei `PK-<nn>.md` und eine Datei `PK-<nn>.json` (Eingabe für das PDF-Programm).

## 6. Formelblatt (Datei `05-Formelblatt.md`)

Nach Aufgabentyp geordnet. Für jede Formel steht darüber in Fettdruck die Aufgabenstellung, bei der man sie braucht, zum Beispiel:

**Aufgabe: „Abstand des Punktes X von der Ebene E: n·x = c“**
d = |n·X − c| / ‖n‖

Dazu Wertetabellen (zum Beispiel cos und sin der Standardwinkel) und am Ende „Wichtig für die Klausur“ mit Kürzungsregeln und typischen Punktverlusten.

## 7. Lösungsstil (für jede einzelne Lösung)

Jede Lösung hat genau diesen Aufbau:

1. **Merke:** die 2 bis 4 Schritte des Verfahrens in Kurzform, einmal pro Thema (nicht pro Aufgabe wiederholen).
2. **Schritt 1, Schritt 2, …:** jede Umformung auf einer eigenen Zeile, Zwischenergebnisse nicht überspringen, Proben einbauen (zum Beispiel (x × y)·x = 0, Fußpunkt in die Gleichung einsetzen).
3. **▶ Ergebnis in Fettdruck**, exakt und vollständig gekürzt (2√2 statt √8, √6/3 statt 2/√6), bei Extremwerten mit Stelle und Wert, bei „zeigen Sie“ ein Schlusssatz.
4. **Wichtig für die Klausur:** am Ende jedes Themas die typischen Fehler und Punktverluste.

Zusätzlich die Vorgaben aus `_Loesungsstil-*.md` des Fachs befolgen (zum Beispiel Sätze mit Nummer zitieren, Kompaktheit nennen, Determinantenmethode statt Lagrange, Antwortsatz schreiben).

## 8. Lernplan (Datei `06-Lernplan.md`)

Drei Varianten in einem Dokument: lang (3 Wochen oder mehr), mittel (8 bis 10 Tage), kurz (1 bis 5 Tage). Jede Variante als Tabelle Tag | Thema | Aufgaben (mit Verweis auf Dateien und Aufgabennummern) | Ziel. Dazu: Tagesstruktur mit Uhrzeiten, Bestehens-Check (Punktzahl in der Probeklausur → was tun), Regeln bei Verzug, Checkliste für den Vorabend, Klausurtaktik (Zeit pro Punkt, Reihenfolge, letzte 10 Minuten).

## 9. Verifikation (Datei `_pruefung.py`)

Jede Zahl in jedem Dokument wird mit sympy nachgerechnet, bevor sie aufgeschrieben wird. Lege pro Fach eine `_pruefung.py` an, die alle Ergebnisse der gelösten Altklausuren und aller Probeklausuren symbolisch prüft und am Ende `ALLES OK` ausgibt. Läuft sie nicht fehlerfrei durch, werden die Dokumente nicht ausgegeben, sondern zuerst korrigiert. Python mit `-I` starten, sympy bei Bedarf installieren (`pip install sympy --break-system-packages`).

## 10. PDF-Programm (Ordner `tools/klausur_pdf/`)

Das PDF-Programm liegt bereits im Repo unter `tools/klausur_pdf/` (gebaut und getestet am 17.11.2026, Anleitung in `tools/klausur_pdf/README.md`). Verwende es und erweitere es nur bei Bedarf; nach jeder Änderung `python -m pytest tests -q` im Ordner `tools/klausur_pdf` laufen lassen. Aufruf aus einem anderen Ordner: `PYTHONPATH=<Repo>/tools/klausur_pdf python -m klausur_pdf …`. Fehlt es (anderer Checkout), baue es nach den folgenden Anforderungen.

Plattform: Unter Windows liegen die Fächer in `C:\Users\ahmad\Documents\UniFlow-Export\`. Auf dem Mac gibt es diesen Ordner nur, wenn er dorthin kopiert wurde; dann den Pfad im Aufruf angeben. Die Schrift sucht das Programm selbst (DejaVu Sans, Arial Unicode auf dem Mac, Cambria Math unter Windows); mit `python -m klausur_pdf fonts` prüfen, dass „fehlende Zeichen: keine“ gemeldet wird.

**Anforderungen:**

- Python-Paket `klausur_pdf` mit CLI: `python -m klausur_pdf build --input <datei.json> --out <ordner>` und `python -m klausur_pdf build-all --dir 04-Probeklausuren --out pdf/`.
- Eingabe ist eine JSON-Datei mit dieser Struktur:

```json
{
  "typ": "klausur" | "formelblatt" | "uebung",
  "fach": "Mathematik für die Ingenieurwissenschaften I",
  "titel": "Probeklausur 3",
  "untertitel": "Kurzklausur 1, Format wie Original",
  "meta": {"dauer": "30 Minuten", "punkte": 10, "hilfsmittel": "keine", "semester": "WS 2026/27"},
  "hinweis": "Bitte geben Sie bei allen Lösungen den Rechenweg an. …",
  "aufgaben": [
    {"nr": 1, "punkte": "2 + 1", "text": "…", "teile": [{"label": "a", "text": "…"}, {"label": "b", "text": "…"}]}
  ],
  "loesungen": [
    {"nr": 1, "teile": [{"label": "a", "schritte": ["…", "…"], "ergebnis": "…"}]}
  ],
  "formeln": [
    {"aufgabe": "Abstand Punkt–Ebene", "formel": "d = |n·X − c| / ‖n‖", "hinweis": "…"}
  ]
}
```

- Ausgabe: `<titel>-Aufgaben.pdf` (Layout wie die Originalklausur: Kopfzeile mit Fakultät, Semester, Fach, Klausurname, Datum; Standardhinweis; Aufgaben mit Punkten in Klammern; Teilaufgaben eingerückt), `<titel>-Loesungen.pdf` (Merke, Schritte, Ergebnis hervorgehoben) und bei `typ = formelblatt` ein `<titel>.pdf` mit „Aufgabe: …“ über jeder Formel.
- Technik: Python 3, `reportlab` (oder Markdown → HTML → `weasyprint`, falls installiert). Unicode-Schrift einbetten, die √ ‖ ∠ ℝ π ₀ darstellt (zum Beispiel DejaVu Sans). Vektoren dürfen als Zeilen (a, b, c) gesetzt werden; optional ein Schalter `--spaltenvektoren`, der sie als Spalten setzt.
- Außerdem einen „Prompt-Modus“: `python -m klausur_pdf from-markdown --input PK-03.md --out pdf/` liest die Markdown-Datei (Überschriften `###`, Fettdruck, `▶`) und baut daraus dieselben PDFs, damit du nicht jedes Mal JSON schreiben musst.
- Tests in `tools/klausur_pdf/tests/` mit einer Beispiel-JSON und einer Beispiel-Markdown-Datei, die durchlaufen müssen.
- Alle PDFs eines Fachs landen in `<Fach>/Klausurvorbereitung/pdf/`.

## 11. Ausgabestruktur

```
<Fach-Ordner>/Klausurvorbereitung/<Klausurname>/
  01-Analyse.md
  02-Themen.md
  03-Altklausuren-geloest.md
  04-Probeklausuren/PK-01.md … PK-10.md (+ .json)
  05-Formelblatt.md (+ .json)
  06-Lernplan.md
  _pruefung.py
  pdf/  (alle PDFs)
  README.md  (Inhaltsverzeichnis, Annahmen, Stand)
```

## 12. Ablauf für mehrere Fächer

Wenn der Aufruf `/klausur-generator alle` lautet: Durchlaufe jeden Ordner `*-Komplett` unter `UniFlow-Export`, prüfe, ob darin Altklausuren liegen (Ordnernamen mit „Klausur“, „KK“, „Probeklausur“, „Abschluss“), und erzeuge für jede dort erkennbare Klausurart (KK1 bis KK4, Großklausur) die Vorbereitung nach Abschnitt 2 bis 11. Fragen aus Abschnitt 1 einmal pro Fach stellen. Am Ende eine Übersicht `UniFlow-Export/Klausurvorbereitung-Uebersicht.md` mit allen Fächern, Klausuren, Terminen und Pfaden.

## 13. Abschluss-Checkliste (vor der Ausgabe prüfen)

- [ ] Format und Punkte stimmen mit den Orga-Folien überein, Quelle genannt
- [ ] Ausgeschlossene Themen nirgends in Probeklausuren oder Formelblatt
- [ ] Jedes Thema in mindestens einer Probeklausur
- [ ] `_pruefung.py` endet mit `ALLES OK`
- [ ] Alle Ergebnisse exakt und gekürzt, keine Dezimalzahlen
- [ ] Richtige Unicode-Zeichen, kein roher LaTeX-Code, keine „…“
- [ ] PDFs erzeugt und geöffnet geprüft (erste Seite als Bild rendern und ansehen)
- [ ] README mit Annahmen und Stand aktualisiert
