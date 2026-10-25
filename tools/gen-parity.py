"""Erzeugt WEB-IPAD-PARITAET.md aus den Bestandsaufnahmen in docs/paritaet/ und den Regeln in status.json.

Jede Tabellenzeile der Web-Bestandsaufnahmen wird eine Checklisten-Zeile mit fester ID (Abschnitt + laufende Nummer).
Status und iPad-Stand kommen aus docs/paritaet/status.json (Abschnitts-Vorgaben + Regeln je Zeile).
Aufruf im Projektordner: python tools/gen-parity.py
"""
from __future__ import annotations

import json
import re
from collections import Counter, OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs" / "paritaet"
STATUSES = ["Nicht begonnen", "Implementiert", "Kompiliert", "Getestet", "Visuell geprüft", "Vollständig gleichwertig"]


def cell(s: str, n: int = 150) -> str:
    s = re.sub(r"\s+", " ", s.replace("|", "/")).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def tables(path: Path, prefix: str) -> list[dict]:
    """Zeilen aller Tabellen; Abschnitt = letzte Ueberschrift, Kopfzeile wird uebersprungen."""
    rows, sec, header, count = [], "", None, Counter()
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            sec, header = line.strip("# ").strip(), None
            continue
        if not line.startswith("|") or re.match(r"^\|\s*:?-", line):
            if not line.startswith("|"):
                header = None
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = cells
            continue
        code = (sec.split(" ")[0] if sec else "A").rstrip(")")
        count[code] += 1
        rows.append({"id": f"{prefix}{code}-{count[code]:02d}", "section": sec, "code": code, "cells": cells, "header": header})
    return rows


def headings(path: Path, prefix: str, pattern: str) -> list[dict]:
    """Funktionsbloecke ohne Tabelle (z. B. B1–B28 im Editor) als je eine Zeile."""
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(pattern, line)
        if m:
            code = m.group(1)
            out.append({"id": f"{prefix}{code}", "section": line.strip("# ").strip(), "code": code,
                        "cells": [line.strip("# ").strip()], "header": ["Funktion"]})
    return out


def describe(r: dict) -> tuple[str, str, str]:
    """(Funktion, Aussehen/Verhalten, Web-Ort + API) aus den Spalten einer Zeile."""
    h = [x.lower() for x in r["header"]]
    c = r["cells"] + [""] * (len(h) - len(r["cells"]))
    name = c[0] if h and h[0] != "#" else (c[1] if len(c) > 1 else c[0])
    rest = [(h[i], c[i]) for i in range(len(h)) if c[i] and i > (1 if h and h[0] == "#" else 0)]
    where = " · ".join(v for k, v in rest if "datei" in k or "zeile" in k or k in ("style.css",))
    api = " · ".join(v for k, v in rest if k.startswith("api"))
    look = " · ".join(v for k, v in rest if not ("datei" in k or "zeile" in k or k.startswith("api") or k == "style.css"))
    return cell(name, 90), cell(look, 170), cell(" · ".join(x for x in (where, api) if x), 110)


def apply_rules(r: dict, rules: dict) -> dict:
    best = None
    for code, d in rules["sections"].items():
        if r["code"] == code or r["code"].startswith(code + ".") or r["id"].startswith(code):
            if best is None or len(code) > len(best[0]):
                best = (code, d)
    out = dict(best[1]) if best else {"heute": "–", "status": "Nicht begonnen"}
    # nur der Funktionsname (erste Spalte bzw. zweite bei nummerierten Tabellen), nicht die Beschreibung
    text = (r["cells"][1] if r["header"] and r["header"][0] == "#" and len(r["cells"]) > 1 else r["cells"][0]).lower()
    for rule in rules["rows"]:
        if not (r["id"].startswith(rule["prefix"]) or r["code"] == rule["prefix"]):
            continue
        if all(k.lower() in text for k in rule.get("contains", [])):
            out.update({k: v for k, v in rule.items() if k in ("status", "heute", "note")})
    return out


def main() -> None:
    rules = json.loads((DOCS / "status.json").read_text(encoding="utf-8"))
    web = tables(DOCS / "web-ansichten.md", "W.")
    web = [r for r in web if not r["code"].startswith(("D.1", "D.2"))]        # reine Tokenlisten, siehe Designsystem
    ed = tables(DOCS / "web-editor.md", "E.") + headings(DOCS / "web-editor.md", "E.", r"^### (B\d+) ")
    # Funktionen, die in den Bestandsaufnahmen nur als Fliesstext stehen (z. B. Kopfzeile in Abschnitt C)
    for x in rules.get("extra", []):
        web.append({"id": x["id"], "section": x["area"], "code": x["code"], "header": ["Element", "Verhalten", "Datei:Zeile"],
                    "cells": [x["name"], x["look"], x["where"]]})
    areas = OrderedDict((title, []) for title in rules["areas"].values())
    for r in web + ed:
        r.update(apply_rules(r, rules))
        key = "E." + r["code"][0] if r["id"].startswith("E.") else ".".join(r["code"].split(".")[:2])
        areas.setdefault(rules["areas"].get(key, r["section"]), []).append(r)
    areas = OrderedDict((k, v) for k, v in areas.items() if v)

    total = Counter(r["status"] for rows in areas.values() for r in rows)
    lines = [rules["intro"].rstrip(), "",
             "## Stand auf einen Blick", "",
             f"{sum(total.values())} Web-Funktionen und Ansichtselemente aus den Bestandsaufnahmen "
             f"(`docs/paritaet/web-ansichten.md`, `docs/paritaet/web-editor.md`).", "",
             "| Bereich | " + " | ".join(STATUSES) + " |", "|---|" + "---:|" * len(STATUSES)]
    for title, rows in areas.items():
        c = Counter(r["status"] for r in rows)
        lines.append(f"| {title} | " + " | ".join(str(c.get(s, 0) or "") for s in STATUSES) + " |")
    lines.append("| **Summe** | " + " | ".join(f"**{total.get(s, 0)}**" for s in STATUSES) + " |")
    lines += ["", rules["middle"].rstrip(), "", "## Checkliste je Funktion", "",
              "Spalten: **Web** = Ort im Quelltext und API · **iPad heute** = Stand vor dem 1:1-Umbau bzw. jetzt · "
              "**Status** = Fortschritt der 1:1-Umsetzung · **Fehlt zur Gleichheit** = offene Unterschiede.", ""]
    for title, rows in areas.items():
        lines += [f"### {title}", "", "| ID | Funktion | Aussehen / Verhalten (Web) | Web: Ort · API | iPad heute | Status | Fehlt zur Gleichheit |",
                  "|---|---|---|---|---|---|---|"]
        for r in rows:
            name, look, where = describe(r)
            lines.append(f"| {r['id']} | {name} | {look} | {where} | {cell(r.get('heute', '–'), 120)} | {r['status']} | "
                         f"{cell(r.get('note', 'native 1:1-Umsetzung'), 140)} |")
        lines.append("")
    lines.append(rules["outro"].rstrip())
    (ROOT / "WEB-IPAD-PARITAET.md").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"WEB-IPAD-PARITAET.md: {sum(total.values())} Zeilen, {dict(total)}")


if __name__ == "__main__":
    main()
