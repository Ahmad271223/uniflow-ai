"""Mensa (docs/MENSA-2026-11-05.md): Datendatei pruefen, Kopie im Swift-Kern und gemeinsame Faelle schreiben.

Quelle der Wahrheit: packages/shared-contracts/mensa.json (Mensen, Quellen, Kennzeichen- und Allergentabellen). Das Werkzeug
- prueft die Datei (eindeutige Kennungen, bekannte Quellen, Standard-Mensa je Hochschule, nur https),
- schreibt apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Mensa/MensaData.swift (woertlich),
- schreibt packages/shared-contracts/fixtures/mensa/cases.json aus den gespeicherten Antworten in fixtures/mensa/raw
  (Studi|Futter, STW-ON-Mensa-API, OpenMensa) mit app/mensa.py: vereinheitlichte Tage, Status je Tag, Filter, Auswahl
  fuer die Uebersicht, Abruf-Adressen, Mensen je Hochschule. Swift-Kern (MensaTests) und node (tests/js/mensa.test.mjs)
  pruefen dieselben Faelle. Laedt nie etwas aus dem Netz.

Aufruf im Projektordner: .venv/bin/python tools/gen-mensa-fixture.py [--check]
"""
from __future__ import annotations

import json
import re
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from schema_source import ROOT, write_or_check  # noqa: E402

from app import mensa  # noqa: E402

DATA = ROOT / "packages" / "shared-contracts" / "mensa.json"
SWIFT = ROOT / "apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/Mensa/MensaData.swift"
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "mensa"
CASES = FX / "cases.json"
RAW = [("studifutter", "studifutter-garbsen.json"), ("stwon", "stwon-hi-uni.json"), ("openmensa", "openmensa-hauptmensa.json")]
TODAY = date(2026, 11, 5)
FILTERS = [
    {},
    {"vegan": True},
    {"vegetarisch": True},
    {"ohne_schwein": True},
    {"allergens": ["gluten"]},
    {"allergens": ["milch", "ei"]},
    {"vegetarisch": True, "allergens": ["gluten"]},
    {"vegan": True, "ohne_schwein": True, "allergens": ["soja", "sellerie"]},
]


def check_data(d: dict) -> list[str]:
    errs: list[str] = []
    if d.get("v") != 1:
        errs.append("v")
    for k, s in d.get("sources", {}).items():
        for f in ("url", "api"):
            if not str(s.get(f, "")).startswith("https://"):
                errs.append(f"sources.{k}.{f}")
    ids = [c.get("id") for c in d.get("canteens", [])]
    if len(set(ids)) != len(ids):
        errs.append("canteens: doppelte id")
    labels = {l["key"] for l in d.get("labels", [])}
    allergens = {a["key"] for a in d.get("allergens", [])}
    for c in d.get("canteens", []):
        cid = c.get("id") or ""
        if not re.fullmatch(r"[a-z0-9-]+", cid):
            errs.append(f"canteens.{cid}: id")
        if c.get("source", {}).get("kind") not in d.get("sources", {}):
            errs.append(f"canteens.{cid}: source")
        if not str(c.get("url", "")).startswith("https://"):
            errs.append(f"canteens.{cid}: url")
        if c.get("region") not in {u["region"] for u in d["universities"].values()}:
            errs.append(f"canteens.{cid}: region")
        if not c.get("hours") or any(not h.get("lines") for h in c["hours"]):
            errs.append(f"canteens.{cid}: hours")
        for u in c.get("universities", []):
            if u not in d["universities"]:
                errs.append(f"canteens.{cid}: university {u}")
    for u, x in d.get("universities", {}).items():
        if x.get("default") not in ids:
            errs.append(f"universities.{u}: default")
    for code, m in d.get("studifutter_markings", {}).items():
        if m["type"] == "label" and not set(m["keys"]) <= labels:
            errs.append(f"studifutter_markings.{code}")
        if m["type"] == "allergen" and m["key"] not in allergens:
            errs.append(f"studifutter_markings.{code}")
    for code, keys in d.get("stwon_categories", {}).items():
        if not set(keys) <= labels:
            errs.append(f"stwon_categories.{code}")
    for code, key in d.get("stwon_allergens", {}).items():
        if key not in allergens:
            errs.append(f"stwon_allergens.{code}")
    for r in d.get("openmensa_notes", []):
        if not set(r.get("label") or []) <= labels or (r.get("allergen") and r["allergen"] not in allergens):
            errs.append(f"openmensa_notes.{r.get('match')}")
    return errs


def swift_text(raw: str) -> str:
    if '"""#' in raw:
        raise ValueError("Datendatei enthaelt das Ende eines Swift-Rohtexts")
    return ("// Erzeugt von tools/gen-mensa-fixture.py aus packages/shared-contracts/mensa.json - nicht von Hand aendern.\n"
            "enum MensaData {\n    static let json = #\"\"\"\n" + raw.rstrip("\n") + "\n\"\"\"#\n}\n")


def cases(d: dict) -> dict:
    parsed = {}
    for kind, name in RAW:
        raw = json.loads((FX / "raw" / name).read_text(encoding="utf-8"))
        parsed[name] = {"kind": kind, "result": mensa.parse(kind, raw, d)}
    sf = parsed["studifutter-garbsen.json"]["result"]
    on = parsed["stwon-hi-uni.json"]["result"]
    om = parsed["openmensa-hauptmensa.json"]["result"]
    sample = sf["days"]["2026-11-05"] + on["days"]["2026-11-05"]
    end = date(2026, 11, 18)
    return {
        "today": TODAY.isoformat(),
        "parse": parsed,
        "days": [
            {"fixture": "studifutter-garbsen.json", "start": "2026-11-05", "count": 7,
             "status": [x["status"] for x in mensa.build_days(TODAY, 7, sf)]},
            {"fixture": "stwon-hi-uni.json", "start": "2026-11-04", "count": 7, "since": "2026-11-05",
             "status": [x["status"] for x in mensa.build_days(date(2026, 11, 4), 7, on, "2026-11-05")]},
            {"fixture": "openmensa-hauptmensa.json", "start": "2026-11-05", "count": 4,
             "status": [x["status"] for x in mensa.build_days(TODAY, 4, om)]},
        ],
        "filters": [{"filter": f, "ids": [m["id"] for m in mensa.filter_meals(sample, f)],
                     "top": [m["id"] for m in mensa.top_meals(sample, 3, f)]} for f in FILTERS],
        "top_stwon": [m["id"] for m in mensa.top_meals(on["days"]["2026-11-05"], 3)],
        "sorts": [{"fixture": fx, "by": by, "role": role,
                   "ids": [m["id"] for m in mensa.sort_meals(res["days"]["2026-11-05"], by, role)]}
                  for fx, res in [("studifutter-garbsen.json", sf), ("stwon-hi-uni.json", on), ("openmensa-hauptmensa.json", om)]
                  for by, role in [("line", "student"), ("price", "student"), ("price", "guest"), ("kcal", "student"),
                                   ("protein", "student")]],
        "numbers": {x: mensa._number(x) for x in ["2,7 g", "0,0 g", "13", "", "kein Wert", "865 kJ (207 kcal)"]},
        "prices": [{"id": m["id"], "role": r, "price": mensa.price_for(m, r)} for m in sample[:3] for r in ("student", "employee", "guest", "x")],
        "pretty": {s: mensa.pretty_category(s) for s in ["VEGGIE & VEGAN", "SÜSSE ECKE", "PASTA & FRIENDS", "Essen 1", "", "  QUER  BEET ", "Beilage"]},
        "urls": {cid: mensa.source_url(mensa.canteen(cid, d), TODAY, end, kind, d)
                 for cid, kind in [("garbsen", "studifutter"), ("hi-uni", "stwon"), ("hauptmensa", "openmensa")]},
        "canteens": {u: (lambda r: {"university": r["university"], "region": r["region"], "default": r["default"],
                                    "ids": [c["id"] for c in r["canteens"]], "own": [c["id"] for c in r["canteens"] if c["own"]]})(
                         mensa.canteens_response(u, d)) for u in ["luh", "hsh", "hildesheim", "unbekannt"]},
    }


def main() -> int:
    check = "--check" in sys.argv[1:]
    raw = DATA.read_text(encoding="utf-8")
    d = json.loads(raw)
    errs = check_data(d)
    if errs:
        print("FEHLER in der Datendatei:\n  " + "\n  ".join(errs), file=sys.stderr)
        return 1
    ok = write_or_check(SWIFT, swift_text(raw), check)
    ok = write_or_check(CASES, json.dumps(cases(d), ensure_ascii=False, indent=1) + "\n", check) and ok
    return 1 if check and not ok else 0


if __name__ == "__main__":
    sys.exit(main())
