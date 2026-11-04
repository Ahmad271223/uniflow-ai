"""Erzeugt packages/shared-contracts/fixtures/doc-index/cases.json: Erwartungswerte des Dokument-Index, wie app/doc_index.py
sie bildet, fuer den Geraete-Kern (Swift: DocIndexTests). Datei-Schluessel (HMAC), Seiten-Abdruecke (Text normalisiert,
Bildseite an Datei und Seite gebunden), Datensatznamen, Art im Regal aus der Einordnung. Alles erfunden.
Aufruf im Projektordner: python tools/gen-doc-index-cases.py [--check]"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "doc-index" / "cases.json"
sys.path.insert(0, str(ROOT))


def build() -> dict:
    from app import doc_index as di
    sha_a = "a" * 64
    sha_b = "0123456789abcdef" * 4
    texts = [
        "Eigenwerte einer Matrix\nDas charakteristische Polynom liefert die Eigenwerte.",
        "EIGENWERTE   einer\tMatrix\n\nDas charakteristische Polynom liefert die Eigenwerte.",   # gleicher Abdruck
        "Unabh¨ angigkeit von Ereignissen: P(A ∩ B) = P(A) · P(B) für unabhängige A, B.",
        "Aufgabe 3b: Berechne ∫ x² dx von 0 bis 1 und begründe jeden Schritt (ß, äöü, €, \U0001F600).",
        "  3 ",                                                                                   # Bildseite (fast kein Text)
        "",
    ]
    return {
        "_hinweis": "Erzeugt mit tools/gen-doc-index-cases.py aus app/doc_index.py; nicht von Hand aendern.",
        "schema_version": di.SCHEMA_VERSION,
        "file_key": [{"sha": s, "key": di.file_key(s)} for s in (sha_a, sha_b, sha_b.upper())],
        "page_hash": [{"text": t, "sha": sha_a, "page": i + 1, "normalized": di.normalize_text(t), "letters": di.letters(t),
                       "hash": di.page_hash(t, sha_a, i + 1)} for i, t in enumerate(texts)],
        "record_name": [{"key": di.file_key(sha_a), "page": p, "name": di.record_name(di.file_key(sha_a), p)} for p in (0, 1, 12)],
        "catalog_kind": [{"doc_type": d, "sub_label": l, "kind": di.catalog_kind(d, l)[0], "label": di.catalog_kind(d, l)[1]}
                         for d, l in (("vorlesung", "Vorlesung"), ("uebung", "Übung"), ("uebung", "Hörsaalübung"), ("uebung", "Gruppenübung"),
                                      ("uebung", "Tutorium"), ("klausur", "Klausur"), ("klausur", "Altklausur"), ("skript", "Skript"),
                                      ("loesung", "Lösung"), ("organisatorisch", "Organisatorisches"), ("sonstiges", ""), (None, None))],
        "kind_order": di.KIND_ORDER,
        "prompt": [{"in": {"course": "Testmathe I", "file_name": "vl02.pdf", "page": 3, "page_count": 12, "text": texts[0], "with_image": False},
                    "out": di.page_prompt("Testmathe I", "vl02.pdf", 3, 12, texts[0], False)},
                   {"in": {"course": "Testkurs", "file_name": "blatt3.pdf", "page": 1, "page_count": 2, "text": texts[3], "with_image": True,
                           "with_solutions": True},
                    "out": di.page_prompt("Testkurs", "blatt3.pdf", 1, 2, texts[3], True, True)},
                   {"in": {"course": "", "file_name": "", "page": 1, "page_count": 1, "text": "   ", "with_image": False},
                    "out": di.page_prompt("", "", 1, 1, "   ", False)}],
        "system": di.SYSTEM,
    }


def main(argv: list[str]) -> int:
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    if "--check" in argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print(f"{OUT} ist nicht aktuell: python tools/gen-doc-index-cases.py")
            return 1
        print("doc-index cases.json aktuell")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"geschrieben: {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
