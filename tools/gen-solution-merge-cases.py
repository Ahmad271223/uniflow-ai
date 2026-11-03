"""Erzeugt packages/shared-contracts/fixtures/solutions/merge-cases.json: gemeinsame Faelle fuer das Zusammenfuehren
einer bisherigen Loesung mit einer neuen Fassung (03.11.2026, "Aktualisieren?" beim erneuten Teilen zu derselben PDF).

Die Erwartungen (Seitenfolge, Objekte, Bilder) stehen hier von Hand; die Referenz app/solution_format.merge_contents
muss sie erfuellen, ihr Ergebnis steht als `merged` im Fixture. Swift (`SolutionBuilder.merge`, Kern-Tests) und der
Browser (`mergeContent`, tests/js) rechnen dieselben Faelle nach.
Aufruf im Projektordner: python tools/gen-solution-merge-cases.py [--check]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "solutions" / "merge-cases.json"
FP, FP2 = "a" * 64, "b" * 64
PREV_ID, NEW_ID = "6f1c1c0e-0000-4000-8000-0000000000a1", "6f1c1c0e-0000-4000-8000-0000000000b2"
PNG = "iVBORw0KGgoAAAANSUhEUg=="                    # Anfang einer PNG-Datei (reicht fuer die Typpruefung)


def stroke(oid: str) -> dict:
    return {"id": oid, "type": "stroke", "tool": "pen", "color": "#000000", "width": 4, "points": [10, 10, 50, 50]}


def image(oid: str, src: str) -> dict:
    return {"id": oid, "type": "image", "src": src, "x": 10, "y": 10, "w": 40, "h": 30}


def pdf(key: str, index: int, *objects) -> dict:
    return {"key": key, "kind": "pdf", "pdfIndex": index, "width": 595, "height": 842, "rotation": 0, "extraRotation": 0,
            "objects": list(objects) or [stroke(f"{key}-s")]}


def blank(key: str, *objects) -> dict:
    return {"key": key, "kind": "blank", "width": 595, "height": 842, "rotation": 0, "extraRotation": 0, "template": "grid",
            "objects": list(objects) or [stroke(f"{key}-s")]}


def content(pages: list, *, sid=PREV_ID, created="2026-10-30T09:00:00Z", title="Blatt 3", name="Lea", fp=FP,
            images=None, missing=None) -> dict:
    return {"format": "uniflow-solution-content", "formatVersion": 1, "solutionId": sid, "createdAt": created, "title": title,
            "displayName": name, "document": {"sha256": fp, "pageCount": 12}, "pages": pages,
            "images": {s: {"mime": "image/png", "data": PNG} for s in (images or [])}, "missingImages": missing or []}


def new(pages: list, **kw) -> dict:
    return content(pages, sid=NEW_ID, created="2026-11-03T12:00:00Z", **kw)


CASES = [
    {"name": "andere Folie kommt dazu, bisherige bleibt",
     "previous": content([pdf("p1", 1)]), "new": new([pdf("p3", 3)]),
     "expect": {"keys": ["p1", "p3"]}},
    {"name": "dieselbe PDF-Seite wird ersetzt (auch mit anderem Schluessel)",
     "previous": content([pdf("p1", 1), pdf("p2", 2, stroke("alt"))]), "new": new([pdf("q2", 2, stroke("neu"))]),
     "expect": {"keys": ["p1", "q2"], "objects": {"q2": ["neu"]}}},
    {"name": "Reihenfolge nach PDF-Seite",
     "previous": content([pdf("p2", 2), pdf("p5", 5)]), "new": new([pdf("p4", 4), pdf("p1", 1)]),
     "expect": {"keys": ["p1", "p2", "p4", "p5"]}},
    {"name": "Leerseiten: gleicher Schluessel ersetzt, neue folgt ihrer PDF-Seite",
     "previous": content([pdf("p1", 1), blank("b1", stroke("alt")), pdf("p3", 3)]),
     "new": new([pdf("p2", 2), blank("b1", stroke("neu")), blank("b2")]),
     "expect": {"keys": ["p1", "p2", "b1", "b2", "p3"], "objects": {"b1": ["neu"]}}},
    {"name": "Leerseite vor der ersten PDF-Seite vorn, Notizblatt hinten",
     "previous": content([blank("b0"), pdf("p2", 2), blank("nb-x")]), "new": new([pdf("p1", 1), blank("nb2-y")]),
     "expect": {"keys": ["b0", "p1", "p2", "nb-x", "nb2-y"]}},
    {"name": "PDF-Seite ersetzt eine alte Seite mit demselben Schluessel",
     "previous": content([pdf("p1", 1), pdf("p2", 2)]), "new": new([pdf("p2", 4)]),
     "expect": {"keys": ["p1", "p2"], "objects": {"p2": ["p2-s"]}, "pdfIndex": {"p2": 4}}},
    {"name": "Bilder der bleibenden Seiten bleiben, ersetzte fallen weg; Titel neu, ID und Datum alt",
     "previous": content([pdf("p1", 1, image("i1", "a.png")), pdf("p2", 2, image("i2", "b.png"))], images=["a.png"], missing=["b.png"]),
     "new": new([pdf("p2", 2, image("i3", "c.png")), pdf("p3", 3, image("i4", "d.png"))], images=["c.png"], missing=["d.png"],
                title="Blatt 3 (ergänzt)", name="Lea M."),
     "expect": {"keys": ["p1", "p2", "p3"], "images": ["a.png", "c.png"], "missingImages": ["d.png"], "title": "Blatt 3 (ergänzt)",
                "displayName": "Lea M.", "solutionId": PREV_ID, "createdAt": "2026-10-30T09:00:00Z"}},
    {"name": "andere PDF: kein Zusammenfuehren",
     "previous": content([pdf("p1", 1)]), "new": new([pdf("p1", 1)], fp=FP2), "error": "fingerprintMismatch"},
]


def build() -> dict:
    sys.path.insert(0, str(ROOT))
    from app import solution_format as sf
    out = []
    for c in CASES:
        case = {k: v for k, v in c.items() if k != "expect"}
        if "error" in c:
            try:
                sf.merge_contents(c["previous"], c["new"])
                raise AssertionError(c["name"] + ": Fehler erwartet")
            except ValueError as e:
                assert str(e) == c["error"], (c["name"], e)
            out.append(case)
            continue
        m = sf.merge_contents(c["previous"], c["new"])
        e = c["expect"]
        assert [p["key"] for p in m["pages"]] == e["keys"], (c["name"], [p["key"] for p in m["pages"]])
        for k, ids in e.get("objects", {}).items():
            assert [o["id"] for p in m["pages"] if p["key"] == k for o in p["objects"]] == ids, c["name"]
        for k, i in e.get("pdfIndex", {}).items():
            assert next(p for p in m["pages"] if p["key"] == k)["pdfIndex"] == i, c["name"]
        for f in ("title", "displayName", "solutionId", "createdAt", "missingImages"):
            if f in e:
                assert m[f] == e[f], (c["name"], f, m[f])
        if "images" in e:
            assert sorted(m["images"]) == e["images"], (c["name"], sorted(m["images"]))
        assert m["solutionId"] == PREV_ID and m["createdAt"] == c["previous"]["createdAt"], c["name"]
        case["keys"] = e["keys"]
        case["merged"] = m
        out.append(case)
    return {"_hinweis": "Erzeugt mit tools/gen-solution-merge-cases.py (Referenz app/solution_format.merge_contents); nicht von Hand "
                        "aendern. Pruefen: tests/test_solution_merge.py (Python), tests/js/solutions.test.mjs (Browser), "
                        "SolutionMergeTests (Swift-Kern).",
            "rules": ["dieselbe PDF-Seite (pdfIndex) oder derselbe Seitenschluessel: die neue Fassung ersetzt die alte",
                      "andere Seiten kommen dazu, alte bleiben",
                      "Reihenfolge nach PDF-Seite; Leerseite hinter der PDF-Seite, der sie in ihrer Fassung folgte (davor: vorn); "
                      "Notizblatt-Seiten (nb-…) hinten; bei Gleichstand alt vor neu, je in ihrer Reihenfolge",
                      "solutionId und createdAt der bisherigen Loesung; Titel, Anzeigename, Seitenzahl aus der neuen Fassung",
                      "Bilder: nur die von den Seiten benutzten (neue Fassung zuerst); fehlende sortiert in missingImages"],
            "cases": out}


def main(check: bool) -> bool:
    sys.path.insert(0, str(ROOT / "tools"))
    from schema_source import write_or_check
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    return write_or_check(OUT, text, check)


if __name__ == "__main__":
    ok = main("--check" in sys.argv)
    sys.exit(0 if ok or "--check" not in sys.argv else 1)
