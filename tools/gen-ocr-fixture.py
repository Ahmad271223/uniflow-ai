"""Erzeugt packages/shared-contracts/fixtures/ocr/rules.json: die Regeln der Texterkennung fuer PDF-Seiten ohne
Textebene aus der Python-Referenz (app/pageocr.py) - "fast leer" (Buchstaben zaehlen, Grenzwert 20), Umfang
(keine / bestimmte Seiten / erste n / alle), Stapel von 4 Seiten, wann erkannter Text die Textebene ersetzt und die
Zuordnung zur Textebene (`embedded`). Swift (PageOCR.swift) und Kotlin koennen dieselbe Datei pruefen.
Aufruf im Projektordner: python tools/gen-ocr-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "ocr" / "rules.json"

TEXTS = [
    "", "  \n ", "3", "  3 ", "12 / 40", "Seite 12 von 40", "Eigenwerte", "Aufgabe 3: Eigenwerte",
    "abcdefghijklmnopqrs",                      # 19 Buchstaben
    "abcdefghijklmnopqrst",                     # 20 Buchstaben
    "abcdefghij klmnopqrs 1234567890",          # 19 Buchstaben und Ziffern
    "ÄÖÜäöüß ÄÖÜäöüß ÄÖÜäö",                    # 19 Umlaute
    "ÄÖÜäöüß ÄÖÜäöüß ÄÖÜäöü",                   # 20 Umlaute
    "äbcdefghijklmnopqrs",                # zerlegtes ä: Grundbuchstabe und Zeichen zaehlen zusammen 20
    "∫ f(x) dx = F(b) − F(a) 1 2 3 4 5 6 7 8",  # Formelzeile: wenige Buchstaben
    "Eigenwerte einer Matrix\nDas charakteristische Polynom liefert die Eigenwerte.",
]


def build() -> dict:
    sys.path.insert(0, str(ROOT))
    from app import pageocr
    sparse = [{"text": t, "letters": pageocr.letters(t), "sparse": pageocr.is_sparse(t)} for t in TEXTS]
    scopes = [("none", pageocr.Scope.none(), None), ("pages", pageocr.Scope.only(2, 5), [2, 5]),
              ("pages", pageocr.Scope.only(), []), ("leading", pageocr.Scope.leading(3), 3),
              ("leading", pageocr.Scope.leading(0), 0), ("all", pageocr.Scope.all(), None)]
    scope_cases = [{"kind": k, "arg": a, "contains": [p for p in range(1, 8) if s.contains(p)]} for k, s, a in scopes]
    todo_cases = [{"todo": t, "batches": pageocr.batches(t)} for t in ([], [3], [1, 2, 3, 4], [1, 2, 3, 4, 5], list(range(1, 10)))]
    decisions = [(e, r) for e in ("", "  3 ", "Seitenzahl 3 und Kopf Aufgabe", "Eigenwerte einer Matrix und mehr Text")
                 for r in ("", "Knotenregel", "Kirchhoffsche Maschenregel: Summe der Spannungen ist null",
                           "abcdefghijklmnopqrstuvwxyz")]
    decision_cases = [{"embedded": e, "recognized": r, "accepts": pageocr.accepts(e, r)} for e, r in decisions]
    pages = ["Seite mit Text auf der Textebene", "  3 ", "Kirchhoffsche Maschenregel", "", "Knotenregel", "von Hand geaendert"]
    rows = [{"page": 2, "embedded": "  3 ", "text": "Kirchhoffsche Maschenregel"},      # Seite 2 traegt nicht mehr den erkannten Text
            {"page": 3, "embedded": "  3 ", "text": "Kirchhoffsche Maschenregel"},
            {"page": 4, "embedded": "", "text": ""},                                    # nichts erkannt: nichts zu ersetzen
            {"page": 5, "embedded": None, "text": "Knotenregel"},
            {"page": 6, "embedded": "alt", "text": "nicht mehr der Text der Seite"},
            {"page": 9, "embedded": "x", "text": "gibt es nicht"}]
    embedded = {"pages": pages, "rows": rows, "expect": pageocr.map_embedded(rows, pages)}
    return {"_hinweis": "Erzeugt mit tools/gen-ocr-fixture.py aus app/pageocr.py; nicht von Hand aendern.",
            "minimum_letters": pageocr.MINIMUM_LETTERS, "batch_size": pageocr.BATCH_SIZE,
            "table": pageocr.TABLE_SQL, "sparse": sparse, "scopes": scope_cases, "batches": todo_cases,
            "decisions": decision_cases, "embedded": embedded}


def main(check: bool) -> bool:
    sys.path.insert(0, str(ROOT / "tools"))
    from schema_source import write_or_check
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    return write_or_check(OUT, text, check)


if __name__ == "__main__":
    ok = main("--check" in sys.argv)
    sys.exit(0 if ok or "--check" not in sys.argv else 1)
