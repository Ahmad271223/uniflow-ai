"""Grundstock der Modulkataloge der Universitaet Hildesheim fuer die App (docs/STUDIENGAENGE-HILDESHEIM-2026-11-05.md,
Abschnitt "Grundstock"; Auftrag 05.11.2026). Gegenstueck zu tools/build-luh-seed.py.

Ablauf (ohne Netz, erneut lauffaehig):
  a) jeder Registereintrag aus packages/shared-contracts/study-sources-hildesheim.json mit Katalog (Studienordnung mit
     Modulbeschreibungen oder FB-4-Modulhandbuch), dessen PDF im Zwischenspeicher ~/Studora-Builds/hildesheim/crawl/
     liegt (tools/hildesheim-programs.py), mit dem Leser seines Formats (app/catalog_formats/hildesheim.py); weitere
     Kataloge desselben Eintrags (`more_catalogs`, z. B. Wirtschaftsinformatik aus allen drei FB-4-Handbuechern) werden
     angehaengt;
  b) nachbearbeiten wie bei der LUH (Wahlbereiche nie `pflicht`, Schwerpunkte als Gruppe, Handangaben aus
     packages/shared-contracts/study-area-rules-hildesheim.json, nur die geteilten Fakten, Validator, Kopf aus dem
     gemischten Register, je Kuerzel ein Katalog);
  c) Ressource apps/apple/UniFlow/Resources/StudyCatalogSeed/hildesheim.json.gz und Verzeichnis hildesheim-index.json
     (Aufbau wie luh-index.json, university "hildesheim"); Bericht im Abschnitt "Grundstock" des Dokuments.

Aufruf im Projektordner:
  .venv/bin/python tools/build-hildesheim-seed.py            # bauen und schreiben
  .venv/bin/python tools/build-hildesheim-seed.py --check    # frisch bauen und mit Ressource, Verzeichnis und Bericht vergleichen
  .venv/bin/python tools/build-hildesheim-seed.py --diff     # nur zeigen, was sich gegenueber der Ressource aendern wuerde
Optionen fuer Tests: --crawl-dir, --register, --out-dir, --doc.
"""
from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import importlib.util
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app import study_catalog as sc  # noqa: E402
from app.catalog_formats import get_parser  # noqa: E402
from app.catalog_formats.formats_a_common import merge_catalogs  # noqa: E402

_spec = importlib.util.spec_from_file_location("build_luh_seed", ROOT / "tools" / "build-luh-seed.py")
luh_seed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(luh_seed)

UNIVERSITY = "hildesheim"
CRAWL_DIR = Path.home() / "Studora-Builds" / "hildesheim" / "crawl"
OUT_DIR = ROOT / "apps" / "apple" / "UniFlow" / "Resources" / "StudyCatalogSeed"
DOC = ROOT / "docs" / "STUDIENGAENGE-HILDESHEIM-2026-11-05.md"
AREA_RULES = ROOT / "packages" / "shared-contracts" / "study-area-rules-hildesheim.json"
FILE = "hildesheim.json.gz"
INDEX = "hildesheim-index.json"


# --------------------------------------------------------------------------------------------------------------------
# Register und Zwischenspeicher
# --------------------------------------------------------------------------------------------------------------------

def load_register(path: Path = sc.HILDESHEIM_REGISTRY_PATH) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_full(register: dict) -> dict:
    """Gemischtes Register wie auf dem Geraet (study-sources.json + LUH + Hildesheim)"""
    curated = json.loads(sc.REGISTRY_PATH.read_text(encoding="utf-8"))
    wides = [w for w in sc.load_wide_registries() if w.get("university") != UNIVERSITY] + [register]
    return sc.merge_wide_registries(curated, wides)


def crawl_index(crawl: Path) -> dict:
    try:
        return json.loads((crawl / "index.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"urls": {}, "log": []}


def cached_pdf(index: dict, crawl: Path, url: str) -> tuple[bytes, str | None] | None:
    """(PDF, Abrufzeit) aus dem Zwischenspeicher, sonst None"""
    hit = (index.get("urls") or {}).get(url) or {}
    if hit.get("status") != 200 or not hit.get("path"):
        return None
    path = crawl / hit["path"]
    if not path.exists():
        return None
    at = max((x.get("t") or 0 for x in index.get("log") or [] if x.get("url") == url), default=0)
    fetched = datetime.fromtimestamp(at, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if at else None
    return path.read_bytes(), fetched


def meta_for(full: dict, code: str, term: str, source: dict) -> dict | None:
    found = sc.program_entry(full, UNIVERSITY, code)
    if not found:
        return None
    _, prog, po = found
    return {"university": UNIVERSITY, "program": prog.get("program"), "degree": prog.get("degree"), "po": str(po.get("po")),
            "code": code, "catalog_term": term, "regular_semesters": prog.get("regular_semesters"),
            "total_lp": prog.get("total_lp"), "source": source}


# --------------------------------------------------------------------------------------------------------------------
# Lesen und Nachbearbeiten
# --------------------------------------------------------------------------------------------------------------------

def load_area_rules(path: Path = AREA_RULES) -> dict:
    return luh_seed.load_area_rules(path)


def read_entry(e: dict, full: dict, index: dict, crawl: Path, pages_cache: dict) -> tuple[dict | None, str | None]:
    """Registereintrag -> (Katalog, Problem)"""
    cats = sc.luh_catalogs(e)
    if not cats:
        return None, None
    code = sc.seed_code(e["key"], cats[0]["url"])
    catalog = texts = None
    for c in cats:
        parser = get_parser(c.get("format") or "")
        if parser is None:
            return None, f"{e['key']}: Format {c.get('format')} ohne Leser"
        hit = cached_pdf(index, crawl, c["url"])
        if hit is None:
            return None, f"{e['key']}: PDF fehlt im Zwischenspeicher ({c['url']})"
        data, fetched = hit
        pk = (c["url"], c.get("format"))
        if pk not in pages_cache:
            from app.catalog_formats.hildesheim import pages_for
            pages_cache[pk] = pages_for(c.get("format") or "", data)
        term = c.get("term") if sc.term_number(c.get("term")) else cats[0].get("term")
        source = {"url": cats[0]["url"], "fetched_at": fetched, "sha256": hashlib.sha256(data).hexdigest()} \
            if catalog is None else None
        meta = meta_for(full, code, term, source or {"url": cats[0]["url"]})
        if meta is None:
            return None, f"{e['key']}: Kuerzel {code} nicht im gemischten Register"
        if c.get("usage_program"):
            meta["usage_program"] = c["usage_program"]
        cat, tx = parser(pages_cache[pk], meta)
        if catalog is None:
            catalog, texts = cat, tx
        else:
            src = catalog["source"]
            catalog, texts = merge_catalogs(catalog, texts, cat, tx)
            catalog["source"] = src
    catalog.pop("usage_program", None)
    return catalog, None


def apply_area_patterns(cat: dict, rules: dict) -> bool:
    """Handangaben fuer Bereiche nach Namen (`area_patterns`: [{match: Regex auf den Bereichsnamen, set: Felder}]); die
    FB-4-Kataloge haben je Gebiet einen Bereich, die Regeln der PO gelten fuer alle Gebiete eines Abschnitts"""
    import re
    r = rules.get(cat.get("code")) or {}
    hit = False
    for p in r.get("area_patterns") or []:
        rx = re.compile(p["match"], re.I)
        for a in cat.get("areas") or []:
            if rx.search(a.get("name") or ""):
                a.update(p.get("set") or {})
                hit = True
    return hit


def postprocess(catalog: dict, rules: dict, stats: dict) -> tuple[dict | None, list[str]]:
    cat = copy.deepcopy(catalog)
    cat["v"] = 1
    n_before = len(cat.get("modules") or [])
    stats["kinds_fixed"] += luh_seed.fix_choice_kinds(cat)
    luh_seed.group_alternatives(cat)
    patterned = apply_area_patterns(cat, rules)
    if luh_seed.apply_area_rules(cat, rules) or patterned:
        stats["area_rules"] += 1
    cat = luh_seed.facts_only(cat)
    stats["dropped_modules"] += n_before - len(cat["modules"])
    errors = sc.validate(cat)
    if errors or not cat["modules"]:
        return None, errors or ["keine Module"]
    return cat, []


def build(register: dict, crawl: Path, log=print) -> tuple[list[dict], list[str], dict]:
    full = load_full(register)
    index = crawl_index(crawl)
    rules = load_area_rules()
    stats = {"kinds_fixed": 0, "dropped_invalid": 0, "dropped_modules": 0, "area_rules": 0, "missing": 0}
    problems: list[str] = []
    pages_cache: dict = {}
    items: dict[str, dict] = {}
    for e in register.get("programs") or []:
        catalog, problem = read_entry(e, full, index, crawl, pages_cache)
        if problem:
            problems.append(problem)
            stats["missing"] += 1
            continue
        if catalog is None:
            continue
        cat, errors = postprocess(catalog, rules, stats)
        if cat is None:
            problems.append(f"{e['key']}: ungueltig ({'; '.join(errors[:3])})")
            stats["dropped_invalid"] += 1
            continue
        key = sc.catalog_key(cat)
        fmt = (e.get("catalog") or {}).get("format")
        items.setdefault(key, {"catalog": cat, "registry_keys": [], "format": fmt, "faculty": e.get("faculty") or "unbekannt",
                               "library_key": key})
        items[key]["registry_keys"].append(e["key"])
        log(f"  {cat['code']}: {len(cat['modules'])} Module, {len(cat['areas'])} Bereiche")
    out = sorted(items.values(), key=lambda i: (i["faculty"], i["catalog"]["program"], i["catalog"]["degree"], i["catalog"]["code"]))
    return out, problems, stats


# --------------------------------------------------------------------------------------------------------------------
# Ressource, Verzeichnis, Bericht
# --------------------------------------------------------------------------------------------------------------------

def _dump(v) -> bytes:
    return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def bundle(items: list[dict], register: dict) -> tuple[dict[str, bytes], dict]:
    data = _dump({"v": 1, "university": UNIVERSITY, "catalogs": [i["catalog"] for i in items]})
    gz = gzip.compress(data, compresslevel=9, mtime=0)
    sizes = {FILE: {"bytes": len(gz), "raw_bytes": len(data), "sha256": hashlib.sha256(gz).hexdigest(), "catalogs": len(items)}}
    by_key = {e["key"]: e for e in register.get("programs") or []}
    entries = []
    for i in items:
        c = i["catalog"]
        for k in i["registry_keys"]:
            e = by_key.get(k) or {}
            entries.append({"key": k, "program": e.get("program") or c["program"], "degree": e.get("degree") or c["degree"],
                            "po": str(e.get("po") or c["po"]), "term": c["catalog_term"], "modules": len(c["modules"]),
                            "qis_labels": list(e.get("qis_labels") or []), "code": c["code"], "library_key": i["library_key"],
                            "file": FILE, "format": i["format"], "faculty": i["faculty"],
                            "study_plan": isinstance(c.get("study_plan"), dict)})
    entries.sort(key=lambda x: (x["key"], x["code"]))
    index = {"v": 1, "university": UNIVERSITY, "generator": "tools/build-hildesheim-seed.py", "files": sizes,
             "catalogs": len(items), "modules": sum(len(i["catalog"]["modules"]) for i in items), "entries": entries}
    return {FILE: gz, INDEX: (json.dumps(index, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode("utf-8")}, index


DOC_START = "<!-- grundstock:start (tools/build-hildesheim-seed.py) -->"
DOC_END = "<!-- grundstock:end -->"


FIELDS = (("lp", "LP"), ("semester", "Semester"), ("turnus", "Turnus"), ("exam", "Prüfung"), ("coursework", "Studienl."),
          ("prerequisites", "Vorauss."), ("language", "Sprache"), ("workload_h", "Aufwand"))


def _filled(m: dict, k: str) -> bool:
    v = m.get(k)
    if k == "turnus":
        return v in ("WS", "SS", "WS+SS")
    if k == "prerequisites":
        return bool(v)
    return v is not None


def completeness(mods: list[dict]) -> list[str]:
    n = len(mods) or 1
    return [f"{round(100 * sum(1 for m in mods if _filled(m, k)) / n)} %" for k, _ in FIELDS]


def requests_line(crawl: Path) -> str:
    ix = crawl_index(crawl)
    log = ix.get("log") or []
    if not log:
        return "Anfragen: keine im Zwischenspeicher."
    from collections import Counter
    st = Counter(str(x.get("status")) for x in log)
    pdfs = sum(1 for v in (ix.get("urls") or {}).values() if str(v.get("path") or "").endswith(".pdf"))
    mb = sum(x.get("bytes") or 0 for x in log) / 1e6
    gaps = [b["t"] - a["t"] for a, b in zip(log, log[1:])]
    t0 = datetime.fromtimestamp(log[0]["t"], timezone.utc).strftime("%d.%m.%Y %H:%M")
    t1 = datetime.fromtimestamp(log[-1]["t"], timezone.utc).strftime("%d.%m.%Y %H:%M")
    return (f"Anfragen laut Zwischenspeicher: {ix.get('requests', len(log))} ("
            + ", ".join(f"{v} × {k}" for k, v in sorted(st.items())) + f"), davon {pdfs} PDFs, {mb:.0f} MB, "
            f"{t0}–{t1} UTC, kleinster Abstand {min(gaps) if gaps else 0:.1f} s.")


def report(items: list[dict], index: dict, problems: list[str], stats: dict, register: dict, crawl: Path | None = None) -> str:
    lines = [DOC_START, "## Grundstock (Modulkataloge in der App)", "",
             "Erzeugt von `tools/build-hildesheim-seed.py` aus dem Zwischenspeicher `~/Studora-Builds/hildesheim/crawl/`",
             "(Leser in `app/catalog_formats/hildesheim.py`). Ressource `apps/apple/UniFlow/Resources/StudyCatalogSeed/hildesheim.json.gz`",
             "(gzip, nur geteilte Fakten), Verzeichnis `hildesheim-index.json`. Die App nimmt den Grundstock der Hochschule des",
             "Containers (`settings.university`).", ""]
    lines += ["| Fachbereich | Kataloge | Einträge | Module | Formate |", "|---|---:|---:|---:|---|"]
    fac: dict[str, dict] = {}
    for i in items:
        f = fac.setdefault(i["faculty"], {"catalogs": 0, "entries": 0, "modules": 0, "formats": {}})
        f["catalogs"] += 1
        f["entries"] += len(i["registry_keys"])
        f["modules"] += len(i["catalog"]["modules"])
        f["formats"][i["format"]] = f["formats"].get(i["format"], 0) + 1
    for name in sorted(fac):
        f = fac[name]
        fm = ", ".join(f"{k} {v}" for k, v in sorted(f["formats"].items()))
        lines.append(f"| {name} | {f['catalogs']} | {f['entries']} | {f['modules']} | {fm} |")
    total_entries = len({e["key"] for e in index["entries"]})
    lines.append(f"| **zusammen** | **{len(items)}** | **{total_entries}** | **{index['modules']}** | |")
    lines.append("")
    form: dict[str, list[int]] = {}
    for i in items:
        form.setdefault(i["format"], [0, 0])
        form[i["format"]][0] += 1
        form[i["format"]][1] += len(i["catalog"]["modules"])
    lines.append("Nach Format: " + "; ".join(f"`{k}` {v[0]} Kataloge / {v[1]} Module" for k, v in sorted(form.items())) + ".")
    lines.append(f"Registereinträge: {len(register.get('programs') or [])}, davon im Grundstock: {total_entries}.")
    lines += ["", "Vollständigkeit der Felder (Anteil der Module mit Wert; Turnus nur WS/SS/WS+SS, Voraussetzungen = "
              "verweist auf andere Module):", "",
              "| Format | Kataloge | Module | " + " | ".join(h for _, h in FIELDS) + " |",
              "|---|---:|---:|" + "---:|" * len(FIELDS)]
    for fmt in sorted(form):
        mods = [m for i in items if i["format"] == fmt for m in i["catalog"]["modules"]]
        lines.append(f"| `{fmt}` | {form[fmt][0]} | {len(mods)} | " + " | ".join(completeness(mods)) + " |")
    allm = [m for i in items for m in i["catalog"]["modules"]]
    lines.append(f"| **zusammen** | **{len(items)}** | **{len(allm)}** | " + " | ".join(completeness(allm)) + " |")
    with_rules = sum(1 for i in items if any(a.get("rule") or a.get("lp_required") for a in i["catalog"]["areas"]))
    with_sem = sum(1 for i in items if any(m.get("semester") for m in i["catalog"]["modules"]))
    lines.append("")
    lines.append(f"Kataloge mit Regeln/LP für Bereiche: {with_rules}; mit empfohlenem Semester je Modul: {with_sem}.")
    missing = [e for e in register.get("programs") or [] if (e.get("catalog") or {}).get("format") in (None, "none")]
    if missing:
        lines += ["", f"Ohne Katalog im Grundstock ({len(missing)}) – geht nicht, weil …:", ""]
        for e in missing:
            why = (e.get("catalog") or {}).get("reason") or "keine Modulbeschreibungen gefunden"
            lines.append(f"- {e['program']} ({e['degree']}): {why}")
    if crawl is not None:
        lines += ["", requests_line(crawl)]
    for name, s in sorted(index["files"].items()):
        lines.append(f"Datei `{name}`: {s['bytes'] / 1024:.0f} KB gzip, {s['raw_bytes'] / 1024:.0f} KB JSON, {s['catalogs']} Kataloge.")
    lines.append(f"Nachbearbeitung: {stats['kinds_fixed']} Module in Wahlbereichen von `pflicht` auf `wahlpflicht`/`wahl`, "
                 f"{stats['area_rules']} Kataloge mit Handangaben, {stats['dropped_modules']} doppelte Module, "
                 f"{stats['dropped_invalid']} ungültige, {stats['missing']} ohne PDF/Leser verworfen.")
    if problems:
        lines += ["", "Hinweise des letzten Laufs:"] + [f"- {p}" for p in problems[:30]]
    lines += ["", "Neu bauen: `.venv/bin/python tools/build-hildesheim-seed.py` (prüfen: `--check`, Vorschau: `--diff`).", DOC_END]
    return "\n".join(lines) + "\n"


def doc_with(doc_text: str, section: str) -> str:
    if DOC_START in doc_text and DOC_END in doc_text:
        a = doc_text.index(DOC_START)
        b = doc_text.index(DOC_END) + len(DOC_END)
        rest = doc_text[b:]
        return doc_text[:a] + section.rstrip("\n") + (rest if rest.startswith("\n") else "\n" + rest)
    return doc_text.rstrip("\n") + "\n\n" + section


def read_bundle(out_dir: Path) -> dict[str, dict]:
    p = out_dir / FILE
    if not p.exists():
        return {}
    try:
        data = json.loads(gzip.decompress(p.read_bytes()))
    except (OSError, ValueError):
        return {}
    return {sc.catalog_key(c): c for c in data.get("catalogs") or []}


def diff(old: dict[str, dict], items: list[dict]) -> list[str]:
    new = {i["library_key"]: i["catalog"] for i in items}
    out = []
    for k in sorted(set(new) - set(old), key=lambda k: new[k]["code"]):
        out.append(f"+ {new[k]['code']} {new[k]['catalog_term']}: {len(new[k]['modules'])} Module")
    for k in sorted(set(old) - set(new), key=lambda k: old[k]["code"]):
        out.append(f"- {old[k]['code']} {old[k]['catalog_term']}")
    for k in sorted(set(old) & set(new), key=lambda k: new[k]["code"]):
        if _dump(old[k]) != _dump(new[k]):
            out.append(f"~ {new[k]['code']} {new[k]['catalog_term']}: {len(old[k]['modules'])} -> {len(new[k]['modules'])} Module")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Grundstock der Hildesheimer Modulkataloge bauen")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--diff", action="store_true")
    ap.add_argument("--crawl-dir", type=Path, default=CRAWL_DIR)
    ap.add_argument("--register", type=Path, default=sc.HILDESHEIM_REGISTRY_PATH)
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR)
    ap.add_argument("--doc", type=Path, default=DOC)
    args = ap.parse_args(argv)
    quiet = args.check or args.diff
    log = (lambda *_: None) if quiet else print
    register = load_register(args.register)
    items, problems, stats = build(register, args.crawl_dir, log=log)
    files, index = bundle(items, register)
    section = report(items, index, problems, stats, register, args.crawl_dir)
    doc_text = args.doc.read_text(encoding="utf-8") if args.doc.exists() else ""
    new_doc = doc_with(doc_text, section)
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
            stale.append(args.doc.name + " (Abschnitt Grundstock)")
        if stale:
            print("Grundstock veraltet: " + ", ".join(stale) + " (tools/build-hildesheim-seed.py ausfuehren)")
            for line in diff(read_bundle(args.out_dir), items)[:40]:
                print("  " + line)
            return 1
        print(f"Grundstock aktuell ({index['catalogs']} Kataloge, {index['modules']} Module, {INDEX})")
        return 0
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (args.out_dir / name).write_bytes(data)
    if new_doc != doc_text:
        args.doc.write_text(new_doc, encoding="utf-8")
    print(f"Grundstock: {index['catalogs']} Kataloge, {len({e['key'] for e in index['entries']})} Registereintraege, "
          f"{index['modules']} Module -> {args.out_dir}")
    for name, s in sorted(index["files"].items()):
        print(f"  {name}: {s['bytes']} Bytes gzip, {s['raw_bytes']} Bytes JSON")
    for p in problems:
        print("  Hinweis: " + p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
