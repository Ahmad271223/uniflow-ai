"""Schreibt packages/shared-contracts/fixtures/community/text-cases.json: gemeinsame Faelle fuer Kommentar- und
Fragentexte der Community (Referenz app/community.py `plain_text` und `add_comment`, Gegenstueck
CommunityDiscussion.cleanText im Swift-Kern, der Kommentare und Fragen in CloudKit verschluesselt ablegt und darum
selbst bereinigen muss). Haertetest 13.11.2026: der Kern entfernte Steuer- und Richtungszeichen nicht.

Je Fall: Eingabe (als Liste von Unicode-Skalaren, damit unsichtbare Zeichen im JSON lesbar bleiben) und entweder der
bereinigte Text oder der Fehlercode (text_empty, text_too_long).
Aufruf im Projektordner: python tools/gen-community-text-cases.py [--check]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "community" / "text-cases.json"

INPUTS = [
    ("normal", "Danke!"),
    ("getrimmt", "  Danke!  \n"),
    ("nur Leerraum", "   \n\t "),
    ("leer", ""),
    ("Zeilenumbruch bleibt", "Zeile 1\nZeile 2"),
    ("Windows-Zeilenende wird \\n", "Zeile 1\r\nZeile 2"),
    ("Tab bleibt innen", "a\tb"),
    ("Nullbyte und Klingel", "a\x00b\x07c"),
    ("Richtungs-Ueberschreibung", "Richtig‮ herum"),
    ("Isolates", "⁦links⁩"),
    ("nur unsichtbare Zeichen", "‮⁦\x07"),
    ("C1-Steuerzeichen", "a\x85b\x9fc"),
    ("Loeschzeichen", "a\x7fb"),
    ("geschuetztes Leerzeichen am Rand", " Text　"),
    ("Emoji", "Gut 😀👍🏽"),
    ("Umlaute zerlegt bleiben", "ä"),
    ("Nullbreite bleibt", "a​b"),
    ("genau 2000", "ä" * 2000),
    ("2000 Emoji", "😀" * 2000),
    ("2001", "a" * 2001),
    ("2000 plus Steuerzeichen", "b" * 2000 + "\x00‮"),
    ("2000 plus Rand", "  " + "c" * 2000 + "  "),
]


def build() -> dict:
    sys.path.insert(0, str(ROOT))
    from app import community
    cases = []
    for name, raw in INPUTS:
        out = community.plain_text(raw).strip()
        case = {"name": name, "input": [ord(c) for c in raw]}
        if not out:
            case["error"] = "text_empty"
        elif len(out) > community.MAX_COMMENT:
            case["error"] = "text_too_long"
        else:
            case["output"] = [ord(c) for c in out]
        cases.append(case)
    return {"_hinweis": "Erzeugt mit tools/gen-community-text-cases.py (Referenz app/community.py); nicht von Hand aendern. "
                        "Pruefen: tests/test_community_haertetest.py (Python), CommunityDiscussionTests.swift (Swift-Kern).",
            "max_comment": community.MAX_COMMENT, "cases": cases}


def main() -> None:
    data = build()
    head = {k: v for k, v in data.items() if k != "cases"}
    lines = [json.dumps(c, ensure_ascii=False, separators=(",", ":")) for c in data["cases"]]   # ein Fall je Zeile
    text = json.dumps(head, ensure_ascii=False)[:-1] + ', "cases": [\n' + ",\n".join(lines) + "\n]}\n"
    if "--check" in sys.argv:
        if OUT.read_text(encoding="utf-8") != text:
            sys.exit(f"{OUT} ist veraltet: python tools/gen-community-text-cases.py")
        return
    OUT.write_text(text, encoding="utf-8")
    print(f"{OUT.relative_to(ROOT)}: {len(data['cases'])} Faelle")


if __name__ == "__main__":
    main()
