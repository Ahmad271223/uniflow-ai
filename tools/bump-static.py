"""Cache-Versionen der Oberflaeche hochzaehlen: `?v=N` des geaenderten Moduls und - weil ein Browser ein Modul mit
unveraenderter Adresse aus dem Zwischenspeicher nimmt - aller Module und Seiten, die es (auch ueber Umwege) einbinden.

Aufruf:  python tools/bump-static.py studora-link.js editor.css
"""
import re
import sys
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "app" / "static"
REF = re.compile(r'([\w.-]+\.(?:js|mjs|css))\?v=(\d+)')


def importers(name: str) -> list[Path]:
    out = []
    for p in list(STATIC.glob("*.js")) + list(STATIC.glob("*.html")):
        if re.search(re.escape(name) + r"\?v=\d+", p.read_text(encoding="utf-8")):
            out.append(p)
    return out


def bump(names: list[str]) -> list[str]:
    todo, done = list(names), set()
    while todo:
        n = todo.pop()
        if n in done:
            continue
        done.add(n)
        for p in importers(n):
            s = p.read_text(encoding="utf-8")
            s2 = re.sub(re.escape(n) + r"\?v=(\d+)", lambda m: f"{n}?v={int(m.group(1)) + 1}", s)
            if s2 != s:
                p.write_text(s2, encoding="utf-8", newline="")
            if p.suffix == ".js":
                todo.append(p.name)
    return sorted(done)


if __name__ == "__main__":
    print("hochgezaehlt:", ", ".join(bump(sys.argv[1:])))
