"""Grundstock der Modulkataloge aller HsH-Studiengaenge fuer die App (Hochschule Hannover; Auftrag des Inhabers
05.11.2026 "die gleiche Bibliothek wie fuer die LUH", Bericht docs/STUDIENGAENGE-HSH-2026-11-05.md; Vorbild
tools/build-luh-seed.py).

Ablauf (ohne Netz, erneut lauffaehig):
  a) Register packages/shared-contracts/study-sources-hsh.json (tools/hsh-programs.py): je Studiengang, PO-Version und
     Vertiefung ein Eintrag mit Modulhandbuch (catalog) und weiteren Handbuechern derselben PO (more_catalogs, z. B.
     Wahlpflichtkatalog);
  b) jedes lesbare Handbuch (catalog.format hsh-*) aus dem Zwischenspeicher ~/Studora-Builds/hsh-catalog (bzw. dem des
     Register-Laufs ~/Studora-Builds/hsh/crawl) mit app/catalog_formats/hsh.py lesen, weitere Handbuecher einmischen;
  c) nachbearbeiten: Turnus aus Semesterlage und Studienbeginn (nur Pflichtmodule mit Fachsemester in Studiengaengen,
     die nur im Winter beginnen: ungerade = WS, gerade = SS; sonst bleibt "unbekannt"), Wahlbereiche (Name) nie
     Pflicht, Handangaben aus packages/shared-contracts/study-area-rules-hsh.json, nur geteilte Fakten, Validator aus
     app/study_catalog.py, feste Reihenfolge; Kataloge mit weniger als 3 Modulen fallen weg;
  d) Ressource apps/apple/UniFlow/Resources/StudyCatalogSeed/hsh.json.gz + hsh-index.json (Aufbau wie luh-index.json)
     und Abschnitt "Grundstock" im Bericht.

Aufruf im Projektordner:
  .venv/bin/python tools/build-hsh-seed.py            # bauen und schreiben
  .venv/bin/python tools/build-hsh-seed.py --check    # frisch bauen und mit Ressource, Verzeichnis und Bericht vergleichen
  .venv/bin/python tools/build-hsh-seed.py --diff     # nur zeigen, was sich gegenueber der Ressource aendern wuerde
Optionen fuer Tests: --registry, --out-dir, --doc.
"""
from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import importlib.util
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app import study_catalog as sc  # noqa: E402
from app.catalog_formats import hsh as reader  # noqa: E402
from app.catalog_formats.formats_a_common import fill_rates, merge_catalogs  # noqa: E402

UNIVERSITY = "hsh"
REGISTRY = ROOT / "packages" / "shared-contracts" / "study-sources-hsh.json"
AREA_RULES = ROOT / "packages" / "shared-contracts" / "study-area-rules-hsh.json"
OUT_DIR = ROOT / "apps" / "apple" / "UniFlow" / "Resources" / "StudyCatalogSeed"
DOC = ROOT / "docs" / "STUDIENGAENGE-HSH-2026-11-05.md"
MIN_MODULES = 3


def _load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


LUH = _load("build_luh_seed", "build-luh-seed.py")      # Nachbearbeitung und Ausgabe wie bei der LUH
CAT = _load("hsh_catalogs", "hsh-catalogs.py")          # Zwischenspeicher (ohne Netz)
CAT.NETWORK[0] = False


def _iso(ts) -> str | None:
    if ts is None:
        return None
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def pages_of(url: str) -> tuple[list[str], dict] | None:
    e = CAT.fetch(url)
    if not e or not e.get("abs") or not str(e["abs"]).endswith(".pdf"):
        return None
    return CAT.pdf_pages_cached(e["abs"], e.get("sha256")), e


def term_fallback(entry_term: str | None, fetched_at) -> str | None:
    """Katalogsemester: aus dem Handbuch (Register), sonst das Semester des Abrufs"""
    if entry_term and sc.term_number(entry_term):
        return entry_term
    if fetched_at:
        return sc.current_term(datetime.fromtimestamp(int(fetched_at), tz=timezone.utc).strftime("%Y-%m-%d"))
    return None


def read_entry(entry: dict) -> tuple[dict | None, str | None]:
    """Registereintrag -> (Katalog mit Fakten und Hilfsfeldern, Problem)"""
    c = entry.get("catalog") or {}
    got = pages_of(c.get("url") or "")
    if got is None:
        return None, "Handbuch nicht im Zwischenspeicher"
    pages, e = got
    code = sc.seed_code(entry["key"])
    meta = {"university": UNIVERSITY, "program": entry["program"], "degree": entry["degree"], "abbr": entry.get("abbr"),
            "po": str(entry.get("po") or "unbekannt"), "code": code,
            "catalog_term": term_fallback(c.get("term"), e.get("fetched_at")),
            "regular_semesters": entry.get("regular_semesters"), "total_lp": entry.get("total_lp"),
            "source": {"url": c["url"], "fetched_at": _iso(e.get("fetched_at")), "sha256": e.get("sha256")}}
    try:
        cat, texts = reader.parse(pages, meta, c.get("format"))
    except Exception as ex:  # noqa: BLE001
        return None, f"nicht lesbar ({ex})"
    cat["catalog_term"] = meta["catalog_term"]
    for more in entry.get("more_catalogs") or []:
        got = pages_of(more["url"])
        if got is None:
            continue
        try:
            extra, extra_texts = reader.parse(got[0], meta, more.get("format"))
        except Exception:  # noqa: BLE001
            continue
        cat, texts = merge_catalogs(cat, texts, extra, extra_texts)
    return cat, None


def infer_turnus(cat: dict, start_terms: list[str]) -> int:
    """Pflichtmodule mit Fachsemester in Studiengaengen, die nur im Wintersemester beginnen: ungerade = WS,
    gerade = SS (nur wenn das Handbuch keinen Turnus nennt). Ergebnis: Zahl gesetzter Module"""
    if start_terms != ["Wintersemester"]:
        return 0
    n = 0
    for m in cat.get("modules") or []:
        if m.get("turnus") in (None, "unbekannt") and m.get("kind") == "pflicht" and isinstance(m.get("semester"), int):
            m["turnus"] = "WS" if m["semester"] % 2 == 1 else "SS"
            n += 1
    return n


def load_area_rules(path: Path = AREA_RULES) -> dict:
    return LUH.load_area_rules(path)


def build(registry: dict, rules: dict) -> tuple[list[dict], list[str], dict]:
    problems: list[str] = []
    stats = {"entries": 0, "readable": 0, "read": 0, "dropped_small": 0, "dropped_invalid": 0, "dropped_unread": 0,
             "turnus_inferred": 0, "kinds_fixed": 0, "area_rules": 0, "dropped_duplicate": 0}
    items: list[dict] = []
    seen: dict[str, dict] = {}
    for entry in registry.get("programs") or []:
        stats["entries"] += 1
        fmt = (entry.get("catalog") or {}).get("format")
        if fmt not in reader.FORMATS:
            continue
        stats["readable"] += 1
        cat, why = read_entry(entry)
        if cat is None:
            problems.append(f"{entry['key']}: {why}")
            stats["dropped_unread"] += 1
            continue
        if len(cat.get("modules") or []) < MIN_MODULES:
            problems.append(f"{entry['key']}: nur {len(cat.get('modules') or [])} Module erkannt ({fmt})")
            stats["dropped_small"] += 1
            continue
        stats["turnus_inferred"] += infer_turnus(cat, entry.get("start_terms") or [])
        stats["kinds_fixed"] += LUH.fix_choice_kinds(cat)
        LUH.group_alternatives(cat)
        if LUH.apply_area_rules(cat, rules):
            stats["area_rules"] += 1
        rates = fill_rates(cat)
        cat = LUH.facts_only(cat)
        errors = sc.validate(cat)
        if errors:
            problems.append(f"{entry['key']}: ungueltig ({'; '.join(errors[:3])})")
            stats["dropped_invalid"] += 1
            continue
        key = sc.catalog_key(cat)
        if key in seen:
            stats["dropped_duplicate"] += 1
            continue
        stats["read"] += 1
        item = {"catalog": cat, "entry": entry, "format": fmt, "faculty": entry.get("faculty") or "unbekannt",
                "library_key": key, "rates": rates}
        seen[key] = item
        items.append(item)
    items.sort(key=lambda i: (i["faculty"], i["catalog"]["program"], i["catalog"]["degree"], i["catalog"]["code"]))
    return items, problems, stats


def _dump(v) -> bytes:
    return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def bundle(items: list[dict]) -> tuple[dict[str, bytes], dict]:
    data = _dump({"v": 1, "university": UNIVERSITY, "catalogs": [i["catalog"] for i in items]})
    gz = gzip.compress(data, compresslevel=9, mtime=0)
    name = f"{UNIVERSITY}.json.gz"
    files = {name: gz}
    sizes = {name: {"bytes": len(gz), "raw_bytes": len(data), "sha256": hashlib.sha256(gz).hexdigest(),
                    "catalogs": len(items)}}
    entries = []
    for i in items:
        c, e = i["catalog"], i["entry"]
        entries.append({"key": e["key"], "program": e["program"], "degree": e["degree"], "po": str(c["po"]),
                        "term": c["catalog_term"], "modules": len(c["modules"]), "qis_labels": list(e.get("qis_labels") or []),
                        "code": c["code"], "library_key": i["library_key"], "file": name, "format": i["format"],
                        "faculty": i["faculty"], "study_plan": isinstance(c.get("study_plan"), dict),
                        "variant": e.get("variant"), "status": e.get("status")})
    entries.sort(key=lambda x: (x["key"], x["code"]))
    index = {"v": 1, "university": UNIVERSITY, "generator": "tools/build-hsh-seed.py", "files": sizes,
             "catalogs": len(items), "modules": sum(len(i["catalog"]["modules"]) for i in items), "entries": entries}
    files[f"{UNIVERSITY}-index.json"] = (json.dumps(index, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode("utf-8")
    return files, index


DOC_START = "<!-- grundstock:start (tools/build-hsh-seed.py) -->"
DOC_END = "<!-- grundstock:end -->"
RATE_KEYS = ("lp", "semester", "exam", "coursework", "turnus", "language", "workload_h", "code", "prerequisites")


def report(items: list[dict], index: dict, problems: list[str], stats: dict, registry: dict) -> str:
    progs = registry.get("programs") or []
    lines = [DOC_START, "## Grundstock (Zahlen des letzten Laufs)", "",
             "Erzeugt von `tools/build-hsh-seed.py` aus dem Register `study-sources-hsh.json` und den Handbüchern im",
             "Zwischenspeicher. Ressource `apps/apple/UniFlow/Resources/StudyCatalogSeed/hsh.json.gz` + `hsh-index.json`.", ""]
    lines += ["| Fakultät | Registereinträge | lesbares Handbuch | im Grundstock | Module |", "|---|---:|---:|---:|---:|"]
    fac: dict[str, list[int]] = {}
    for p in progs:
        f = fac.setdefault(p.get("faculty") or "unbekannt", [0, 0, 0, 0])
        f[0] += 1
        f[1] += 1 if (p.get("catalog") or {}).get("format") in reader.FORMATS else 0
    for i in items:
        f = fac.setdefault(i["faculty"], [0, 0, 0, 0])
        f[2] += 1
        f[3] += len(i["catalog"]["modules"])
    for name in sorted(fac):
        a, b, c, d = fac[name]
        lines.append(f"| {name} | {a} | {b} | {c} | {d} |")
    lines.append(f"| **zusammen** | **{len(progs)}** | **{stats['readable']}** | **{len(items)}** | **{index['modules']}** |")
    lines.append("")
    n = index["modules"] or 1
    tot = {k: 0.0 for k in RATE_KEYS}
    for i in items:
        m = len(i["catalog"]["modules"])
        for k in RATE_KEYS:
            tot[k] += i["rates"].get(k, 0) * m
    lines.append("Feldfüllung über alle Module: " + ", ".join(f"{k} {100 * tot[k] / n:.0f} %" for k in RATE_KEYS) + ".")
    form: dict[str, list[int]] = {}
    for i in items:
        form.setdefault(i["format"], [0, 0])
        form[i["format"]][0] += 1
        form[i["format"]][1] += len(i["catalog"]["modules"])
    lines.append("Nach Bauart: " + "; ".join(f"`{k}` {v[0]} Kataloge / {v[1]} Module" for k, v in sorted(form.items())) + ".")
    for name, s in sorted(index["files"].items()):
        lines.append(f"Datei `{name}`: {s['bytes'] / 1024:.0f} KB gzip, {s['raw_bytes'] / 1024:.0f} KB JSON, {s['catalogs']} Kataloge.")
    lines.append(f"Nachbearbeitung: Turnus bei {stats['turnus_inferred']} Pflichtmodulen aus Semesterlage abgeleitet, "
                 f"{stats['kinds_fixed']} Module in Wahlbereichen nicht Pflicht, Handangaben in {stats['area_rules']} "
                 f"Katalogen; verworfen: {stats['dropped_small']} mit weniger als {MIN_MODULES} Modulen, "
                 f"{stats['dropped_invalid']} ungültig, {stats['dropped_unread']} nicht lesbar, "
                 f"{stats['dropped_duplicate']} doppelt.")
    if problems:
        lines += ["", "Hinweise des letzten Laufs:"] + [f"- {p}" for p in problems[:60]]
    lines += ["", "Neu bauen: `.venv/bin/python tools/build-hsh-seed.py` (prüfen: `--check`, Vorschau: `--diff`).", DOC_END]
    return "\n".join(lines) + "\n"


def read_bundle(out_dir: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    f = out_dir / f"{UNIVERSITY}.json.gz"
    if f.exists():
        try:
            for c in json.loads(gzip.decompress(f.read_bytes())).get("catalogs") or []:
                out[sc.catalog_key(c)] = c
        except (OSError, ValueError):
            pass
    return out


def diff(old: dict[str, dict], items: list[dict]) -> list[str]:
    new = {i["library_key"]: i["catalog"] for i in items}
    lines = []
    for k in sorted(set(new) - set(old), key=lambda k: new[k]["code"]):
        lines.append(f"+ {new[k]['code']} {new[k]['catalog_term']} ({new[k]['program']} {new[k]['degree']}): {len(new[k]['modules'])} Module")
    for k in sorted(set(old) - set(new), key=lambda k: old[k]["code"]):
        lines.append(f"- {old[k]['code']} {old[k]['catalog_term']} ({old[k]['program']})")
    for k in sorted(set(old) & set(new), key=lambda k: new[k]["code"]):
        if _dump(old[k]) != _dump(new[k]):
            lines.append(f"~ {new[k]['code']} {new[k]['catalog_term']}: {len(old[k]['modules'])} -> {len(new[k]['modules'])} Module")
    return lines


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Grundstock der HsH-Modulkataloge bauen")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--diff", action="store_true")
    ap.add_argument("--registry", type=Path, default=REGISTRY)
    ap.add_argument("--rules", type=Path, default=AREA_RULES)
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR)
    ap.add_argument("--doc", type=Path, default=DOC)
    args = ap.parse_args(argv)
    registry = json.loads(args.registry.read_text(encoding="utf-8"))
    items, problems, stats = build(registry, load_area_rules(args.rules))
    files, index = bundle(items)
    section = report(items, index, problems, stats, registry)
    doc_text = args.doc.read_text(encoding="utf-8") if args.doc.exists() else ""
    new_doc = LUH.doc_with(doc_text, section) if DOC_START in doc_text or not doc_text else \
        doc_text.rstrip("\n") + "\n\n" + section
    if DOC_START in doc_text:
        a = doc_text.index(DOC_START)
        b = doc_text.index(DOC_END, a) + len(DOC_END)
        new_doc = doc_text[:a] + section.rstrip("\n") + doc_text[b:]
    if args.diff:
        lines = diff(read_bundle(args.out_dir), items)
        print("\n".join(lines) if lines else "keine Aenderung an den Katalogen")
        return 0
    if args.check:
        stale = []
        for name, data in files.items():
            p = args.out_dir / name
            if not p.exists():
                stale.append(name)
            elif name.endswith(".gz"):
                if gzip.decompress(p.read_bytes()) != gzip.decompress(data):
                    stale.append(name)
            elif p.read_bytes() != data:
                stale.append(name)
        if new_doc != doc_text:
            stale.append(f"{args.doc.name} (Abschnitt Grundstock)")
        if stale:
            print("Grundstock veraltet: " + ", ".join(stale) + " (tools/build-hsh-seed.py ausfuehren)")
            for line in diff(read_bundle(args.out_dir), items)[:40]:
                print("  " + line)
            return 1
        print(f"Grundstock aktuell ({index['catalogs']} Kataloge, {index['modules']} Module, hsh-index.json)")
        return 0
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (args.out_dir / name).write_bytes(data)
    if new_doc != doc_text:
        args.doc.write_text(new_doc, encoding="utf-8")
    print(f"Grundstock HsH: {index['catalogs']} Kataloge, {index['modules']} Module -> {args.out_dir}")
    for name, s in sorted(index["files"].items()):
        print(f"  {name}: {s['bytes']} Bytes gzip, {s['raw_bytes']} Bytes JSON")
    print("  " + json.dumps(stats, ensure_ascii=False))
    for p in problems:
        print("  Hinweis: " + p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
