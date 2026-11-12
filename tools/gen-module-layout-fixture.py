"""Erzeugt packages/shared-contracts/fixtures/module-layout/cases.json: eigene Wochen und Abschnitte je Modul
(app/module_layout.py, Auftrag 12.11.2026). Der Swift-Kern prueft dieselben Erwartungen (ModuleLayoutTests).
Eingaben sind erfunden. Aufruf im Projektordner: python tools/gen-module-layout-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app import module_layout as ml  # noqa: E402

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "module-layout" / "cases.json"
START = date(2026, 10, 12)

S = lambda i, week=None, title=None, rank=None, sort=None, hidden=False: {  # noqa: E731
    "id": i, "week": week, "title": title, "rank": rank, "sort": sort, "hidden": hidden}

LAYOUTS = {
    "leer": {"sections": [], "places": {}},
    "umsortiert": {"sections": [S(1, 1, sort=0), S(2, 3, sort=1), S(3, 4, sort=2), S(4, 2, sort=3)], "places": {}},
    "abschnitt": {"sections": [S(7, title="Kapitel Graphen", rank=20.5), S(8, title="Extras")], "places": {}},
    "gemischt": {"sections": [S(1, 5, hidden=True), S(2, title="Graphen", rank=30.5), S(3, 1, title="Einstieg"),
                              S(4, title="Weg", hidden=True)],
                 "places": {"a": "w:2", "b": "s:2", "c": "w:5", "d": "w:-4", "e": "s:99", "f": "s:4", "g": "w:-3"}},
}
ORDER_WEEKS = [[3, -2, 1, -1, 0, -3, -4, 2], [1, 2, 3, 4, 5, -2], [1, 2, 3, 4, 5], [1, 2, 3, 4, 5, -1],
               [1, 2, 3, -1007, -1008, -4], [1, 2, 3, 4, 5, 6, -1002, -2, -4]]
FILES = [("a", 7, False), ("b", 7, False), ("c", 7, False), ("d", 7, False), ("e", 7, False), ("f", 4, False),
         ("g", 2, False), ("x", 5, False), ("x", 3, True), ("a", 3, True), ("y", -2, False)]
KEYS = ["w:3", "w:-4", "w:-5", "w:60", "w:61", "s:12", "s:0", "x:1", "w:", "w:abc", "", "w:3:4"]
TITLES = ["Woche 5", " 3. Woche ", "Woche 5 – Graphen", "Kapitel 2", "week 12", "Lehrwoche 4", "Woche 41", "WOCHE 07"]
HINTS = ["VL 3.pdf", "Vorlesung_03.pdf", "V03 Graphen.pdf", "Übungsblatt 02.pdf", "Blatt 4 Lösung.pdf", "Lösung zu Blatt 2.pdf",
         "Ü3.pdf", "Tutorium 5.pdf", "Skript Teil 4.pdf", "Kapitel 3.pdf", "Woche 5.pdf", "KW 46.pdf", "2. Woche.pdf",
         "Sitzung vom 12.10.2026.pdf", "7_Literaturempfehlungen.pdf", "Einleitung.pdf", "Folien 20261019.pdf"]
DATES = ["VL_2026-10-12.pdf", "Folien 20261019.pdf", "Sitzung vom 12.10.2026.pdf", "Sitzung 2.11.26.pdf", "Blatt 3.pdf", "2026-13-40.pdf"]
SUGGEST = [("Graphen.pdf", "Diskrete Strukturen\nVorlesung 4: Graphen"), ("Loesung.pdf", "Musterlösung zu Blatt 2"),
           ("Sitzung.pdf", "Sitzung vom 27.10.2026"), ("02 Grundlagen.pdf", None), ("Grundlagen.pdf", "Grundlagen der Informatik"),
           ("3_Rekursion.pdf", ""), ("Zusatz.pdf", "Informatik I – Vorlesung 2: Zahlensysteme"), ("10 Ende.pdf", "KW 46"),
           ("Plan.pdf", "Termin am 30.03.2027"), ("0 Vorwort.pdf", None)]
BULK = [
    {"name": "sammel", "files": [{"id": f"f{i}", "course": "c1", "day": "2026-10-13", "week": 1, "doc_type": "vorlesung", "hint": None} for i in range(6)]},
    {"name": "fuenf", "files": [{"id": f"f{i}", "course": "c1", "day": "2026-10-13", "week": 1, "doc_type": "vorlesung", "hint": 1 if i == 0 else None} for i in range(6)]},
    {"name": "spaet", "files": [{"id": f"f{i}", "course": "c1", "day": "2026-11-13", "week": 3 if i == 0 else 4, "doc_type": "uebung", "hint": None} for i in range(7)]},
    {"name": "eigene", "files": [{"id": f"f{i}", "course": "__user__", "day": "2026-10-13", "week": 0, "doc_type": "skript", "hint": None} for i in range(8)]},
    {"name": "gemischt", "files": [{"id": f"f{i}", "course": "c1", "day": "2026-10-12", "week": 0, "doc_type": ["vorlesung", "sonstiges", "uebung", "loesung", "skript", "vorlesung", "klausur", "uebung"][i], "hint": None} for i in range(8)]},
]


def layout(name: str) -> ml.Layout:
    d = LAYOUTS[name]
    return ml.Layout([dict(s) for s in d["sections"]], dict(d["places"]))


def build() -> dict:
    return {
        "layouts": LAYOUTS,
        "order": [{"layout": n, "weeks": w, "expect": ml.order(w, layout(n))} for n in LAYOUTS for w in ORDER_WEEKS],
        "files": [{"layout": n, "file": f, "auto": a, "unsure": u, "planning": layout(n).planning_week(f, a),
                   "display": layout(n).display_week(f, a, u)} for n in LAYOUTS for f, a, u in FILES],
        "keys": [{"key": k, "week": ml.week_of_key(k)} for k in KEYS],
        "titles": [{"title": t, "week": ml.week_number_in_title(t)} for t in TITLES],
        "hints": [{"name": h, "expect": (lambda r: {"kind": r[0], "number": r[1]} if r else None)(ml.name_hint(h))} for h in HINTS],
        "dates": [{"name": d, "expect": (lambda r: r.isoformat() if r else None)(ml.date_in_name(d))} for d in DATES],
        "suggest": [{"name": n, "first_page": p, "start": START.isoformat(), "expect": ml.suggest(n, p, START)} for n, p in SUGGEST],
        "bulk": [{"name": b["name"], "files": b["files"], "expect": sorted(ml.bulk_uploads(b["files"]))} for b in BULK],
    }


def main() -> int:
    content = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv[1:]:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == content
        print(("aktuell: " if ok else "VERALTET: ") + str(OUT.relative_to(ROOT)))
        return 0 if ok else 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(content, encoding="utf-8")
    print("geschrieben:", OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
