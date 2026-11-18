"""CLI:

    python -m klausur_pdf build --input PK-03.json --out pdf/
    python -m klausur_pdf build-all --dir 04-Probeklausuren --out pdf/
    python -m klausur_pdf from-markdown --input PK-03.md --out pdf/
    python -m klausur_pdf fonts          (zeigt, welche Schrift benutzt wird)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .fonts import registriere
from .markdown_in import lade_markdown
from .model import EingabeFehler, lade_json
from .render import baue


def _lade(pfad: Path):
    if pfad.suffix.lower() == ".json":
        return lade_json(pfad)
    if pfad.suffix.lower() in (".md", ".markdown"):
        return lade_markdown(pfad)
    raise EingabeFehler(f"unbekanntes Format: {pfad.name} (erwartet .json oder .md)")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="klausur_pdf", description="Klausur-, Lösungs- und Formelblatt-PDFs bauen")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="eine JSON- oder Markdown-Datei bauen")
    b.add_argument("--input", required=True)
    b.add_argument("--out", required=True)
    m = sub.add_parser("from-markdown", help="eine Markdown-Datei bauen (Prompt-Modus)")
    m.add_argument("--input", required=True)
    m.add_argument("--out", required=True)
    a = sub.add_parser("build-all", help="alle .json (und .md ohne gleichnamige .json) eines Ordners bauen")
    a.add_argument("--dir", required=True)
    a.add_argument("--out", required=True)
    sub.add_parser("fonts", help="benutzte Schrift anzeigen")
    args = p.parse_args(argv)

    try:
        if args.cmd == "fonts":
            s = registriere()
            print(f"Schrift: {s.pfad}")
            print("fehlende Zeichen: " + (s.fehlend or "keine"))
            return 0
        if args.cmd in ("build", "from-markdown"):
            pfad = Path(args.input)
            doc = lade_markdown(pfad) if args.cmd == "from-markdown" else _lade(pfad)
            for z in baue(doc, args.out):
                print(z)
            return 0
        if args.cmd == "build-all":
            ordner = Path(args.dir)
            dateien = sorted(ordner.glob("*.json"))
            json_stems = {d.stem for d in dateien}
            dateien += sorted(d for d in ordner.glob("*.md") if d.stem not in json_stems and d.stem.lower() != "readme")
            if not dateien:
                print(f"keine .json/.md-Dateien in {ordner}", file=sys.stderr)
                return 1
            fehler = 0
            for d in sorted(dateien):
                try:
                    for z in baue(_lade(d), args.out):
                        print(z)
                except EingabeFehler as e:
                    fehler += 1
                    print(f"FEHLER {d.name}: {e}", file=sys.stderr)
            return 1 if fehler else 0
    except (EingabeFehler, FileNotFoundError, RuntimeError) as e:
        print(f"FEHLER: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
