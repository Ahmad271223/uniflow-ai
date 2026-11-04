"""Erzeugt packages/shared-contracts/fixtures/cardshare/cases.json: Erwartungswerte der geteilten Wochenstapel
(app/cardshare.py, Entscheidung des Inhabers vom 04.11.2026) fuer den Swift-Kern (CardStackShare.swift,
CardStackShareTests): Schluessel je Hochschule, Art und Inhalts-Hashes, Stapelnamen, der Prompt eines Wochenstapels
(byte-gleich mit AIPrompts.flashcards) und der kanonische Klartext eines geteilten Stapels.

Aufruf im Projektordner: python tools/gen-cardshare-fixture.py [--check]
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "cardshare" / "cases.json"


def main(check: bool) -> int:
    from app import cardshare
    h = [hashlib.sha256(x).hexdigest() for x in (b"VL5", b"VL5-Skript", b"Blatt5", b"Blatt5-Loesung")]
    cases = []
    for name, uni, kind, mats in [
        ("Vorlesung Woche 5, luh", "luh", "vorlesung", [h[0], h[1]]),
        ("gleiche Dateien, andere Reihenfolge, Doppelte", "luh", "vorlesung", [h[1], h[0], h[0]]),
        ("Uebung derselben Woche: anderer Schluessel", "luh", "uebung", [h[2], h[3]]),
        ("Vorlesungsdateien als Uebung: Art im Schluessel", "luh", "uebung", [h[0], h[1]]),
        ("andere Hochschule", "hildesheim", "vorlesung", [h[0], h[1]]),
        ("eine Datei", "luh", "uebung", [h[2]]),
    ]:
        cases.append({"name": name, "university": uni, "kind": kind, "materials": mats,
                      "expected_key": cardshare.week_key(uni, kind, [{"content_sha256": m} for m in mats])})
    unsafe = [{"name": "Datei ohne Inhalts-Hash: kein Schluessel", "university": "luh", "kind": "vorlesung", "materials": [h[0], None]},
              {"name": "ohne Dateien", "university": "luh", "kind": "vorlesung", "materials": []},
              {"name": "unbekannte Art", "university": "luh", "kind": "eigene", "materials": [h[0]]}]
    for u in unsafe:
        assert cardshare.week_key(u["university"], u["kind"], [{"content_sha256": m} for m in u["materials"]]) is None
    files = [{"name": "VL05_Reihen.pdf", "text": "  Konvergenz von Reihen: Majorantenkriterium, Quotientenkriterium.  "},
             {"name": "Skript_Kap5.pdf", "text": "Potenzreihen und Konvergenzradius ä ö ü ß\n" + "x" * 4000}]
    cards = [{"question": "Was sagt das Quotientenkriterium?", "answer": "Konvergenz, wenn lim |a_{n+1}/a_n| < 1 ist."},
             {"question": "Konvergenzradius?", "answer": "r = 1/limsup |a_n|^(1/n) – „Zitat“\nZeile 2"}]
    doc = {
        "generator": "tools/gen-cardshare-fixture.py",
        "version": cardshare.VERSION,
        "kinds": list(cardshare.KINDS),
        "week_doc_types": {k: list(v) for k, v in cardshare.WEEK_DOC_TYPES.items()},
        "week_cards": cardshare.WEEK_CARDS,
        "max_cards": 30,
        "week_files_max": cardshare.WEEK_FILES_MAX,
        "week_text_chars": cardshare.WEEK_TEXT_CHARS,
        "max_variants": cardshare.MAX_VARIANTS,
        "canonical": "sha256(JSON mit sortierten Schluesseln, ohne Leerzeichen: {kind, materials: sortierte eindeutige Inhalts-Hashes, uni, v}), Ergebnis 'cs1:' + hex",
        "stack_names": [{"kind": "vorlesung", "week": 5, "name": cardshare.stack_name("vorlesung", 5)},
                        {"kind": "uebung", "week": 12, "name": cardshare.stack_name("uebung", 12)}],
        "cases": cases,
        "unsafe": unsafe,
        "prompt": {"module": "Analysis I", "kind": "vorlesung", "week": 5, "files": files,
                   "week_text": cardshare.week_text(files), "expected": cardshare.prompt("Analysis I", "vorlesung", 5, files)},
        "plaintext": {"cards": cards, "expected": cardshare.canonical_cards(cards)},
        "record_names": [{"key": cases[0]["expected_key"], "variant": v, "name": f"{cases[0]['expected_key']}#{v}"} for v in range(3)],
    }
    text = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    if check:
        if OUT.exists() and OUT.read_text(encoding="utf-8") == text:
            print(f"aktuell: {OUT.relative_to(ROOT)}")
            return 0
        print(f"VERALTET: {OUT.relative_to(ROOT)}")
        return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"geschrieben: {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main("--check" in sys.argv))
