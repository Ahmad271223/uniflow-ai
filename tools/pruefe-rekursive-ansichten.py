#!/usr/bin/env python3
"""Waechter gegen sich selbst enthaltende SwiftUI-Ansichten (Absturz 18.11.2026, iPad Air 4, Build 45).

Eine Ansicht `struct X: View`, deren body (oder ein @ViewBuilder darin) direkt wieder `X(...)` enthaelt, ist im Typ
rekursiv. SwiftUI zaehlt die Teile mancher Container ueber den Typ (`_viewListCount`) und laeuft dann endlos, bis der
Stapel des Hauptfadens ueberlaeuft. Erlaubt ist der Selbstaufruf nur hinter `AnyView(...)` (bricht den Typ) oder wenn
der body der Ansicht selbst `AnyView` liefert. Aufruf: tools/pruefe-rekursive-ansichten.py [Ordner ...]; Ausgabe je
Fund "Datei:Zeile: Typ", Rueckgabe 1 bei Funden.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

STRUCT = re.compile(r"^(?:\s*)(?:@MainActor\s+)?(?:public |private |fileprivate |internal )?struct (\w+)(?:<[^>]*>)?\s*:\s*[^{]*\bView\b")
BODY_ANY = re.compile(r"var body: some View \{\s*AnyView\(")


def blocks(text: str):
    """(Name, Startzeile, Zeilen) je Ansichts-Struktur bis zur passenden schliessenden Klammer."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = STRUCT.match(lines[i])
        if not m:
            i += 1
            continue
        depth, j, started = 0, i, False
        while j < len(lines):
            code = re.sub(r'"(?:\\.|[^"\\])*"', '""', lines[j].split("//")[0])
            depth += code.count("{") - code.count("}")
            started = started or "{" in code
            if started and depth <= 0:
                break
            j += 1
        yield m.group(1), i, lines[i:j + 1]
        i = j + 1


def findings(root: Path):
    for f in sorted(root.rglob("*.swift")):
        if "Tests" in f.parts[-2] or f.name.endswith("Tests.swift"):
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        for name, start, body in blocks(text):
            joined = "\n".join(body)
            if BODY_ANY.search(joined):
                continue
            for k, line in enumerate(body[1:], start=1):
                code = re.sub(r'"(?:\\.|[^"\\])*"', '""', line.split("//")[0])
                if re.search(rf"(?<![\w.]){name}\(", code) and not re.search(rf"AnyView\(\s*{name}\(", code):
                    if re.search(rf"\b(static func|func preview|init)\b", code):
                        continue
                    yield f, start + k + 1, name


def cycles(root: Path):
    """Ringe ueber mehrere Ansichten (A enthaelt B, B enthaelt A) ohne AnyView dazwischen: je Ring einmal die Namen."""
    views: dict[str, tuple[Path, int, str]] = {}
    texts = {}
    for f in sorted(root.rglob("*.swift")):
        if f.name.endswith("Tests.swift"):
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        for name, start, body in blocks(text):
            joined = "\n".join(body[1:])
            if BODY_ANY.search("\n".join(body)):
                joined = ""                                  # body liefert AnyView: bricht jeden Ring
            views.setdefault(name, (f, start + 1, joined))
    edges: dict[str, set[str]] = {}
    for name, (_f, _l, joined) in views.items():
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', "\n".join(l.split("//")[0] for l in joined.split("\n")))
        code = re.sub(r"AnyView\(\s*\w+\(", "AnyView(", code)
        called = set(re.findall(r"(?<![\w.])([A-Z]\w*)\(", code))
        edges[name] = {o for o in called if o != name and o in views}
    seen_rings, state = set(), {}

    def visit(n, path):
        state[n] = 1
        for o in edges.get(n, ()):
            if state.get(o) == 1:
                ring = path[path.index(o):] + [n] if o in path else [o, n]
                key = frozenset(ring)
                if key not in seen_rings:
                    seen_rings.add(key)
                    yield ring
            elif state.get(o) is None:
                yield from visit(o, path + [n])
        state[n] = 2
    for n in sorted(edges):
        if state.get(n) is None:
            for ring in visit(n, []):
                yield [views[r][0] for r in ring][0], views[ring[0]][1], " -> ".join(ring + [ring[0]])


def main(argv: list[str]) -> int:
    roots = [Path(a) for a in argv] or [Path(__file__).resolve().parent.parent / "apps/apple"]
    found = [x for r in roots for x in findings(r)]
    rings = [x for r in roots for x in cycles(r)]
    for f, line, name in found:
        print(f"{f}:{line}: {name} enthaelt sich selbst ohne AnyView")
    for f, line, ring in rings:
        print(f"{f}:{line}: Ring ohne AnyView: {ring}")
    return 1 if found or rings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
