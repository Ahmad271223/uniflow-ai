"""Erzeugt packages/shared-contracts/fixtures/local-backend/outline-sample.pdf (ein erfundenes 30-Seiten-Skript mit
Lesezeichen: Titel, Inhaltsverzeichnis, Kapitel mit und ohne Unterabschnitte, eine dritte Ebene, Anhang) und
outline.json: die Lesezeichen, wie pypdf sie liest, die Abschnitte (app/outline.py sections_from_entries) und die
Aufgaben fuer mehrere Lernzeiten und Seitenbereiche (parts), dazu die Lernschritte. Der Swift-Kern liest dieselbe PDF
mit PDFKit und rechnet dieselben Aufgaben (StudyOutlineTests). Keine echten Unterlagen, kein Netz.
Aufruf im Projektordner: python tools/gen-outline-fixture.py [--check]"""
from __future__ import annotations

import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend"

# (Ebene, Titel, Seite) - Ebene 0 Kapitel, 1 Abschnitt, 2 Unterabschnitt
BOOKMARKS = [
    (0, "Titel", 1), (0, "Inhaltsverzeichnis", 2),
    (0, "1 Signale", 4), (1, "1.1 Zeitkontinuierliche Signale", 4), (1, "1.2 Zeitdiskrete Signale", 7),
    (0, "2 Fourier-Transformation", 10), (1, "2.1 Definition", 10), (1, "2.2 Eigenschaften der Fourier-Transformierten und Korrespondenzen", 12),
    (2, "2.2.1 Linearität", 12), (2, "2.2.2 Verschiebung", 14), (1, "2.3 Faltung", 18),
    (0, "3. Abtastung", 21),
    (0, "4 Systeme", 24), (1, "4.1 LTI-Systeme", 24), (1, "4.2 Stabilität", 24),
    (0, "Literatur", 28), (0, "A Korrespondenzen", 29),
]
PAGES = 30


def build_pdf() -> bytes:
    from pypdf import PdfWriter
    w = PdfWriter()
    for _ in range(PAGES):
        w.add_blank_page(width=595, height=842)
    parents: dict[int, object] = {}
    for level, title, page in BOOKMARKS:
        parents[level] = w.add_outline_item(title, page - 1, parent=parents.get(level - 1) if level else None)
    w.add_metadata({"/Producer": "uniflow gen-outline-fixture", "/CreationDate": "D:20261114000000Z", "/ModDate": "D:20261114000000Z"})
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


def main() -> int:
    from app import outline
    check = "--check" in sys.argv[1:]
    pdf = OUT / "outline-sample.pdf"
    if not check or not pdf.exists():
        pdf.write_bytes(build_pdf())
    entries, pages = outline.read_pdf(str(pdf))
    secs = outline.sections_from_entries(entries, pages)
    cases = []
    for budget in (20, 30, 45, 60, 200):
        for first, last in ((1, None), (11, 22), (25, 30)):
            total = outline.est_total(45, pages, "skript")
            cases.append({"budget": budget, "first": first, "last": last, "total": total,
                          "parts": outline.parts(secs, pages, total, budget, first, last, name="Beispielskript")})
    cases.append({"budget": 30, "first": 1, "last": None, "total": 90, "parts": outline.parts([], pages, 90, 30, name="Arbeitsblätter")})
    out = {"generator": "tools/gen-outline-fixture.py", "pdf": "outline-sample.pdf", "entries": entries, "pages": pages,
           "sections": secs, "cases": cases,
           "steps": {k: outline.steps(k, 4, 9) for k in ("vorlesung", "skript", "uebung", "loesung", "frei")} | {"ohne_seiten": outline.steps("skript")}}
    text = json.dumps(out, ensure_ascii=False, indent=1) + "\n"
    target = OUT / "outline.json"
    if check:
        ok = target.exists() and target.read_text(encoding="utf-8") == text
        print(("aktuell: " if ok else "VERALTET: ") + str(target.relative_to(ROOT)))
        return 0 if ok else 1
    target.write_text(text, encoding="utf-8")
    print("geschrieben:", target.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
