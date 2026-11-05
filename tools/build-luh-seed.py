"""Grundstock der Modulkataloge aller LUH-Studiengaenge fuer die App (docs/STUDIENGAENGE-LUH-2026-11-04.md, Abschnitt
"Grundstock"; Auftrag 04.11.2026).

Ablauf (ohne Netz, erneut lauffaehig):
  a) FEI: jeder modkat-Katalog aus packages/shared-contracts/study-sources-luh.json, dessen PDF im Zwischenspeicher
     ~/Studora-Builds/luh-crawl/ liegt (neuestes Semester je Kuerzel), mit dem modkat-Leser aus app/study_catalog.py;
     kennt das Register einen Studienverlaufsplan (study-sources.json, study_plan), wird er aus dem Zwischenspeicher
     (/private/tmp/claude-501/po/ oder luh-crawl) eingemischt. Ergebnis je Katalog ~/Studora-Builds/luh-seed/fei/<KUERZEL>-<SEMESTER>.json.
  b) alle Fakten aus ~/Studora-Builds/luh-seed/{fei,a,b}/*.json einsammeln (a/ und b/ schreiben die Leser der anderen
     Formate, app/catalog_formats/).
  c) nachbearbeiten: Module in Bereichen wie "Nebenfach", "Schluesselkompetenzen", "Wahlbereich", "Studium generale",
     "Wahlpflicht..." sind nie `pflicht` (-> wahlpflicht bzw. wahl); Kuerzel und Kopf aus dem gemischten Register
     (study-sources-all.json, wie der Ablauf auf dem Geraet); doppelte Kataloge (gleicher Schluessel) und doppelte
     Modul-ids weg; nur die geteilten Fakten des Schemas (keine Texte); Validator aus app/study_catalog.py; feste
     Reihenfolge.
  d) eine Ressource apps/apple/UniFlow/Resources/StudyCatalogSeed/luh.json.gz (ab 3 MB unkomprimiert je Fakultaet
     eine Datei luh-<fakultaet>.json.gz) und das Verzeichnis luh-index.json (je Registereintrag: key, program, degree,
     po, term, modules, qis_labels, code, library_key, file); Bericht im Abschnitt "Grundstock" des Dokuments.

Aufruf im Projektordner:
  .venv/bin/python tools/build-luh-seed.py            # bauen und schreiben
  .venv/bin/python tools/build-luh-seed.py --check    # frisch bauen und mit Ressource, Verzeichnis und Bericht vergleichen
  .venv/bin/python tools/build-luh-seed.py --diff     # nur zeigen, was sich gegenueber der Ressource aendern wuerde
Optionen fuer Tests: --seed-dir, --crawl-dir, --out-dir, --doc, --no-fei (FEI-Fakten nicht neu lesen).
"""
from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app import study_catalog as sc  # noqa: E402

HOME = Path.home()
SEED_DIR = HOME / "Studora-Builds" / "luh-seed"
CRAWL_DIR = HOME / "Studora-Builds" / "luh-crawl"
PLAN_DIRS = [Path("/private/tmp/claude-501/po"), CRAWL_DIR / "cache"]
OUT_DIR = ROOT / "apps" / "apple" / "UniFlow" / "Resources" / "StudyCatalogSeed"
DOC = ROOT / "docs" / "STUDIENGAENGE-LUH-2026-11-04.md"
SOURCES = ("fei", "a", "b")
SPLIT_BYTES = 3 * 1024 * 1024
UNIVERSITY = "luh"

# Studienverlaufsplaene im Zwischenspeicher, die nicht ueber luh-crawl/index.json laufen (Dateiname der URL -> Datei)
PLAN_FILES = {
    "Studienverlaufsplan_Bachelor_Technische_Informatik_WS2026-27.pdf": "svp-ti",
    "Studienverlaufsplan_Bachelor_Informatik_WS2026-27.pdf": "svp-inf",
}

# Felder der geteilten Fakten (study-catalog.schema.json); alles andere (Texte, Hilfsfelder der Leser) faellt weg
CATALOG_KEYS = ("v", "university", "program", "degree", "po", "catalog_term", "code", "regular_semesters", "total_lp",
                "source", "areas", "modules", "study_plan", "plan_slots")
SOURCE_KEYS = ("url", "fetched_at", "sha256")
AREA_KEYS = ("id", "name", "lp_required", "lp_max", "kind", "type", "group", "modules", "modules_required", "semester", "rule")
MODULE_KEYS = ("id", "title", "code", "area", "kind", "lp", "semester", "turnus", "exam", "coursework", "prerequisites",
               "language", "workload_h", "source_page")
SLOT_KEYS = ("semester", "title", "areas", "lp", "lp_max")

# Bereiche, deren Module nie Pflicht sind (Name gefaltet: klein, Umlaute ausgeschrieben); "... - Pflichtmodule" bleibt
CHOICE_AREA_RE = re.compile(r"nebenfach|schluesselkompetenz|wahlbereich|wahlpflicht|studium generale")
PFLICHT_AREA_RE = re.compile(r"(?<!wahl)pflichtmodul")
# Wahlbereiche von Hand aus PO/Modulkatalog (05.11.2026)
AREA_RULES = ROOT / "packages" / "shared-contracts" / "study-area-rules-luh.json"


# --------------------------------------------------------------------------------------------------------------------
# Register
# --------------------------------------------------------------------------------------------------------------------

def load_luh() -> dict:
    return json.loads(sc.LUH_REGISTRY_PATH.read_text(encoding="utf-8"))


def load_full() -> dict:
    curated = json.loads(sc.REGISTRY_PATH.read_text(encoding="utf-8"))
    return sc.merge_luh_registry(curated, load_luh())


def entries_by_url(luh: dict) -> dict[str, list[dict]]:
    """Katalog-URL -> Registereintraege (Haupt-Katalog vor more_catalogs, sonst Reihenfolge der Erhebung)"""
    out: dict[str, list[dict]] = {}
    for e in luh.get("programs") or []:
        for c in sc.luh_catalogs(e):
            out.setdefault(c["url"], []).append(e)
    return out


def meta_for(full: dict, code: str, term: str, source: dict) -> dict | None:
    """Kopf wie StudySources.meta im Kern (erster Registereintrag mit dem Kuerzel)"""
    found = sc.program_entry(full, UNIVERSITY, code)
    if not found:
        return None
    _, prog, po = found
    return {"university": UNIVERSITY, "program": prog.get("program"), "degree": prog.get("degree"), "po": str(po.get("po")),
            "code": code, "catalog_term": term, "regular_semesters": prog.get("regular_semesters"),
            "total_lp": prog.get("total_lp"), "source": source}


# --------------------------------------------------------------------------------------------------------------------
# a) FEI
# --------------------------------------------------------------------------------------------------------------------

def crawl_index(crawl: Path) -> dict:
    try:
        return json.loads((crawl / "index.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"urls": {}, "log": []}


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cached_pdf(index: dict, crawl: Path, url: str) -> tuple[bytes, str] | None:
    """(PDF, Abrufzeit) aus luh-crawl, sonst None"""
    hit = (index.get("urls") or {}).get(url) or {}
    if hit.get("status") != 200 or not hit.get("path"):
        return None
    path = Path(hit["path"])
    if not path.exists():
        path = crawl / "cache" / path.name
    if not path.exists():
        return None
    at = max((x.get("t") or 0 for x in index.get("log") or [] if x.get("url") == url), default=0)
    return path.read_bytes(), (_iso(at) if at else None)


def cached_plan(index: dict, crawl: Path, url: str, plan_dirs: list[Path]) -> tuple[bytes, str | None] | None:
    hit = cached_pdf(index, crawl, url)
    if hit:
        return hit
    stem = PLAN_FILES.get(url.rsplit("/", 1)[-1])
    for d in plan_dirs:
        if stem and (d / f"{stem}.pdf").exists():
            fetched = None
            headers = d / f"{stem}.headers"
            if headers.exists():
                m = re.search(r"^Date: (.+)$", headers.read_text(errors="replace"), re.M)
                if m:
                    try:
                        fetched = parsedate_to_datetime(m.group(1).strip()).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    except (TypeError, ValueError):
                        fetched = None
            return (d / f"{stem}.pdf").read_bytes(), fetched
    return None


def fei_jobs(luh: dict) -> list[tuple[str, str, str]]:
    """(Kuerzel, Semester, URL) aller modkat-Kataloge der Erhebung, neuestes Semester je Kuerzel"""
    best: dict[str, tuple[str, str]] = {}
    for e in luh.get("programs") or []:
        for c in sc.luh_catalogs(e):
            parts = sc.modkat_parts(c["url"]) if c.get("format") == "modkat-FEI" else None
            if not parts:
                continue
            code, term = parts
            if code not in best or sc.term_number(term) > sc.term_number(best[code][0]):
                best[code] = (term, c["url"])
    return sorted((code, t, u) for code, (t, u) in best.items())


def build_fei(out_dir: Path, crawl: Path, plan_dirs: list[Path], log=print) -> list[dict]:
    """Alle FEI-Kataloge lesen und nach <out_dir> schreiben; Ergebnis: Zeilen fuer den Bericht"""
    luh, full = load_luh(), load_full()
    index = crawl_index(crawl)
    by_url = entries_by_url(luh)
    out_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for code, term, url in fei_jobs(luh):
        hit = cached_pdf(index, crawl, url)
        if not hit:
            log(f"  {code}: PDF fehlt im Zwischenspeicher ({url})")
            rows.append({"code": code, "term": term, "error": "PDF fehlt"})
            continue
        data, fetched = hit
        source = {"url": url, "fetched_at": fetched, "sha256": hashlib.sha256(data).hexdigest()}
        meta = meta_for(full, code, term, source)
        if meta is None:
            rows.append({"code": code, "term": term, "error": "nicht im Register"})
            continue
        pages = sc.pdf_pages(data)
        catalog, _texts = sc.parse_luh_modkat(pages, meta)
        apply_modkat_extras(catalog, sc.modkat_area_extras(pages, catalog))
        fix_choice_kinds(catalog)
        plan_info = None
        plan_src = sc.study_plan_source(full, UNIVERSITY, code)
        if plan_src:
            plan_hit = cached_plan(index, crawl, plan_src["url"], plan_dirs)
            if plan_hit:
                plan_data, plan_at = plan_hit
                plan = sc.parse_study_plan(sc.pdf_items(plan_data))
                psrc = {"url": plan_src["url"], "fetched_at": plan_at, "sha256": hashlib.sha256(plan_data).hexdigest()}
                merged, unmatched = sc.merge_study_plan(catalog, plan, psrc)
                if not sc.validate(merged):
                    catalog = merged
                    plan_info = {"state": "merged", "url": plan_src["url"], "entries": len(plan["entries"]),
                                 "slots": len(merged["plan_slots"]), "unmatched": unmatched}
                else:
                    plan_info = {"state": "error", "url": plan_src["url"], "error": sc.validate(merged)[:5]}
            else:
                plan_info = {"state": "missing", "url": plan_src["url"]}
        errors = sc.validate(catalog)
        keys = [e["key"] for e in by_url.get(url, [])]
        doc = {"v": 1, "format": "modkat-FEI", "registry_keys": keys, "catalog": sc.shareable(catalog),
               "study_plan": plan_info, "errors": errors}
        name = f"{code}-{sc.term_slug(term)}.json"
        (out_dir / name).write_text(json.dumps(doc, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        rows.append({"code": code, "term": term, "modules": len(catalog["modules"]), "errors": len(errors),
                     "plan": (plan_info or {}).get("state")})
        log(f"  {code} {term}: {len(catalog['modules'])} Module, {len(catalog['areas'])} Bereiche"
            + (f", Plan {plan_info['state']}" if plan_info else "") + (f", {len(errors)} Fehler" if errors else ""))
    return rows


# --------------------------------------------------------------------------------------------------------------------
# b) Einsammeln
# --------------------------------------------------------------------------------------------------------------------

def _catalogs_in(doc) -> list[tuple[dict, list[str]]]:
    """Kataloge in einer Faktendatei: {catalog, registry_keys|registry_key|key}, {catalogs: [...]}, eine Liste oder
    ein Katalog selbst"""
    out: list[tuple[dict, list[str]]] = []
    if isinstance(doc, list):
        for d in doc:
            out.extend(_catalogs_in(d))
        return out
    if not isinstance(doc, dict):
        return out
    if isinstance(doc.get("catalogs"), list):
        for d in doc["catalogs"]:
            out.extend(_catalogs_in(d))
        return out
    keys: list[str] = []
    for k in ("registry_keys", "registry_key", "key", "keys"):
        v = doc.get(k)
        if isinstance(v, str) and v.startswith(UNIVERSITY + "|"):
            keys.append(v)
        elif isinstance(v, list):
            keys.extend(x for x in v if isinstance(x, str) and x.startswith(UNIVERSITY + "|"))
    cat = doc.get("catalog") if isinstance(doc.get("catalog"), dict) else (doc if isinstance(doc.get("modules"), list) else None)
    if cat is not None:
        out.append((cat, keys))
    return out


def collect(seed_dir: Path) -> tuple[list[dict], list[str]]:
    """Alle Kataloge aus {fei,a,b}/*.json: [{origin, file, catalog, registry_keys}], Fehlerliste"""
    found, problems = [], []
    for origin in SOURCES:
        d = seed_dir / origin
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.json")):
            try:
                doc = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError) as e:
                problems.append(f"{origin}/{f.name}: nicht lesbar ({e.__class__.__name__})")
                continue
            cats = _catalogs_in(doc)
            if not cats:
                problems.append(f"{origin}/{f.name}: kein Katalog")
            # Dateiname = Registerschluessel ("luh|biologie|b.sc.|2018.json", so schreiben die Leser in a/ und b/)
            stem_key = [f.stem] if f.stem.startswith(UNIVERSITY + "|") else []
            for cat, keys in cats:
                found.append({"origin": origin, "file": f"{origin}/{f.name}", "catalog": cat,
                              "registry_keys": keys or stem_key})
    return found, problems


# --------------------------------------------------------------------------------------------------------------------
# c) Nachbearbeiten
# --------------------------------------------------------------------------------------------------------------------

def is_choice_area(name) -> bool:
    return isinstance(name, str) and CHOICE_AREA_RE.search(sc._fold(name)) is not None \
        and PFLICHT_AREA_RE.search(sc._fold(name)) is None


def apply_modkat_extras(catalog: dict, extras: dict) -> int:
    """Wahlbereiche (05.11.2026) aus sc.modkat_area_extras: Regeltext, Zahl der Module, alle waehlbaren Module je
    Bereich (`modules` nur, wenn mehr als die eigenen); Module ohne Bereich (Tabelle "Modul Modul LP ...") bekommen den
    ersten, Art wie im Leser (Spanne -> wahlpflicht). Ergebnis: Zahl der Bereiche mit Angaben"""
    areas = {a["id"]: a for a in catalog.get("areas") or []}
    n = 0
    for aid, ex in extras.items():
        a = areas.get(aid)
        if a is None:
            continue
        n += 1
        if ex.get("rule"):
            a["rule"] = ex["rule"]
        if ex.get("modules_required"):
            a["modules_required"] = ex["modules_required"]
        own = {m["id"] for m in catalog["modules"] if m.get("area") == aid}
        if set(ex.get("modules") or []) - own:
            a["modules"] = list(ex["modules"])
    for m in catalog["modules"]:
        if m.get("area") is not None:
            continue
        aid = next((x for x, ex in extras.items() if m["id"] in (ex.get("modules") or []) and x in areas), None)
        if aid is None:
            continue
        m["area"] = aid
        a = areas[aid]
        if a.get("kind") == "abschluss" or sc.FINAL_RE.search(m["title"]):
            m["kind"] = "abschluss"
        elif m.get("kind") == "pflicht" and a.get("lp_max") is not None:
            m["kind"] = "wahlpflicht"
    # eigene Module stehen nicht doppelt in `modules`; leere Liste weg
    for a in areas.values():
        if "modules" in a:
            own = {m["id"] for m in catalog["modules"] if m.get("area") == a["id"]}
            if not set(a["modules"]) - own:
                del a["modules"]
    return n


def group_alternatives(catalog: dict) -> None:
    """Schwerpunkte als Gruppe (eins waehlen); "Allgemeine ..." mit derselben Spanne ("0 - 25 LP") ist die Wahl ohne
    Schwerpunkt und gehoert dazu (ET, Mechatronik)"""
    areas = catalog.get("areas") or []
    sp = [a for a in areas if sc._fold(a.get("name") or "").startswith("schwerpunkt ") and not a.get("group")]
    if len(sp) < 2:
        return
    for a in sp:
        a["group"] = "schwerpunkt"
    spans = {a.get("lp_max") for a in sp}
    for a in areas:
        if sc._fold(a.get("name") or "").startswith("allgemeine ") and not a.get("group") \
                and not a.get("lp_required") and a.get("lp_max") in spans:
            a["group"] = "schwerpunkt"


def load_area_rules(path: Path = AREA_RULES) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("catalogs") or {}
    except (OSError, ValueError):
        return {}


def apply_area_rules(catalog: dict, rules: dict) -> bool:
    """Handangaben je Kuerzel (study-area-rules-luh.json) einmischen; True, wenn es welche gab"""
    r = rules.get(catalog.get("code"))
    if not r:
        return False
    areas = {a["id"]: a for a in catalog.get("areas") or []}
    for aid, fields in (r.get("areas") or {}).items():
        if aid in areas:
            areas[aid].update(fields)
    for a in r.get("add_areas") or []:
        if a["id"] not in areas:
            catalog["areas"].append(dict(a))
    mods = {m["id"]: m for m in catalog.get("modules") or []}
    for mid, fields in (r.get("modules") or {}).items():
        if mid in mods:
            mods[mid].update(fields)
    return True


def fix_choice_kinds(catalog: dict) -> int:
    """Module in Wahl-Bereichen (Nebenfach, Schluesselkompetenzen, Wahlbereich, Studium generale, Wahlpflicht...) sind
    nie Pflicht: -> wahl (Bereich `wahl`) bzw. wahlpflicht; der Bereich selbst ebenso. Ergebnis: Zahl geaenderter Module"""
    changed = 0
    areas = {a.get("id"): a for a in catalog.get("areas") or [] if isinstance(a, dict)}
    for a in areas.values():
        if is_choice_area(a.get("name")) and a.get("kind") == "pflicht":
            a["kind"] = "wahlpflicht"
    for m in catalog.get("modules") or []:
        a = areas.get(m.get("area")) if isinstance(m, dict) else None
        if a is not None and is_choice_area(a.get("name")) and m.get("kind") == "pflicht":
            m["kind"] = "wahl" if a.get("kind") == "wahl" else "wahlpflicht"
            changed += 1
    return changed


def facts_only(catalog: dict) -> dict:
    """Nur die geteilten Fakten des Schemas, Schluessel in fester Reihenfolge"""
    c = sc.shareable(catalog)

    def pick(d, keys):
        return {k: d[k] for k in keys if isinstance(d, dict) and k in d}

    out = pick(c, CATALOG_KEYS)
    out["source"] = pick(c.get("source") or {}, SOURCE_KEYS)
    out["areas"] = [pick(a, AREA_KEYS) for a in c.get("areas") or []]
    seen: set = set()
    mods = []
    for m in c.get("modules") or []:
        if not isinstance(m, dict) or m.get("id") in seen:
            continue                                     # doppelte Modul-id: die erste gilt
        seen.add(m.get("id"))
        mods.append(pick(m, MODULE_KEYS))
    out["modules"] = mods
    if isinstance(c.get("study_plan"), dict):
        out["study_plan"] = pick(c["study_plan"], SOURCE_KEYS)
    if isinstance(c.get("plan_slots"), list):
        out["plan_slots"] = [pick(s, SLOT_KEYS) for s in c["plan_slots"]]
    return out


def _rank(item: dict) -> tuple:
    """Bei gleichem Schluessel: FEI vor a vor b, mit Studienverlaufsplan, mehr Module, Dateiname"""
    c = item["catalog"]
    return (SOURCES.index(item["origin"]), 0 if isinstance(c.get("study_plan"), dict) else 1, -len(c.get("modules") or []),
            item["file"])


def postprocess(found: list[dict], luh: dict, full: dict) -> tuple[list[dict], list[str], dict]:
    """-> (Kataloge [{catalog, registry_keys, origin, faculty, format}], Probleme, Zahlen)"""
    by_url = entries_by_url(luh)
    problems: list[str] = []
    stats = {"kinds_fixed": 0, "dropped_invalid": 0, "dropped_duplicate": 0, "dropped_unmapped": 0, "dropped_modules": 0,
             "area_rules": 0}
    rules = load_area_rules()
    candidates: dict[str, list[dict]] = {}
    for item in found:
        cat = copy.deepcopy(item["catalog"])
        url = ((cat.get("source") or {}).get("url")) if isinstance(cat.get("source"), dict) else None
        entries = list(by_url.get(url, [])) if url else []
        for k in item["registry_keys"]:
            e = next((x for x in luh.get("programs") or [] if x.get("key") == k), None)
            if e is not None and e not in entries:
                entries.append(e)
        if not entries or not url:
            problems.append(f"{item['file']}: keinem Registereintrag zugeordnet ({url})")
            stats["dropped_unmapped"] += 1
            continue
        if sc.modkat_parts(url) is None:
            # ausserhalb von modkat: ein Katalog je Registereintrag (Kuerzel = Schluessel ohne "luh|"); ausdruecklich
            # genannter Eintrag (Dateiname, registry_keys, code der Leser) vor der URL
            named = item["registry_keys"] + ([f"{UNIVERSITY}|{cat['code']}"] if isinstance(cat.get("code"), str) else [])
            chosen = next((e for k in named for e in entries if e.get("key") == k), entries[0])
            entries = [chosen]
        code = sc.seed_code(entries[0].get("key") or "", url)
        term = cat.get("catalog_term")
        meta = meta_for(full, code, term, cat.get("source") or {})
        if meta:                                          # Kopf wie auf dem Geraet (Register)
            for k in ("university", "program", "degree", "po", "code", "regular_semesters", "total_lp"):
                cat[k] = meta[k]
        else:
            cat["university"], cat["code"] = UNIVERSITY, code
        cat["v"] = 1
        n_before = len(cat.get("modules") or [])
        stats["kinds_fixed"] += fix_choice_kinds(cat)
        group_alternatives(cat)
        if apply_area_rules(cat, rules):
            stats["area_rules"] += 1
        cat = facts_only(cat)
        stats["dropped_modules"] += n_before - len(cat["modules"])
        errors = sc.validate(cat)
        if errors or not cat["modules"]:
            problems.append(f"{item['file']}: ungueltig ({'; '.join(errors[:3]) or 'keine Module'})")
            stats["dropped_invalid"] += 1
            continue
        fmt = next((c.get("format") for e in entries for c in sc.luh_catalogs(e) if c["url"] == url), None)
        primary = entries[0]
        candidates.setdefault(sc.catalog_key(cat), []).append(
            {"catalog": cat, "origin": item["origin"], "file": item["file"], "format": fmt or item["origin"],
             "faculty": primary.get("faculty") or "unbekannt", "registry_keys": sorted({e["key"] for e in entries})})
    out = []
    for key, items in candidates.items():
        items.sort(key=_rank)
        best = items[0]
        stats["dropped_duplicate"] += len(items) - 1
        best["registry_keys"] = sorted({k for i in items for k in i["registry_keys"]})
        best["library_key"] = key
        out.append(best)
    # je Kuerzel nur das neueste Semester
    newest: dict[str, dict] = {}
    for item in out:
        code = item["catalog"]["code"]
        if code not in newest or sc.term_number(item["catalog"]["catalog_term"]) > sc.term_number(newest[code]["catalog"]["catalog_term"]):
            if code in newest:
                stats["dropped_duplicate"] += 1
            newest[code] = item
        else:
            stats["dropped_duplicate"] += 1
    out = sorted(newest.values(), key=lambda i: (i["faculty"], i["catalog"]["program"], i["catalog"]["degree"], i["catalog"]["code"]))
    return out, problems, stats


# --------------------------------------------------------------------------------------------------------------------
# d) Ressource, Verzeichnis, Bericht
# --------------------------------------------------------------------------------------------------------------------

def _dump(v) -> bytes:
    return json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _file_slug(faculty: str) -> str:
    return sc.slug(re.sub(r"^Fakult(ae|ä)t f(ue|ü)r ", "", faculty or "unbekannt"))[:40]


def bundle(items: list[dict], luh: dict) -> tuple[dict[str, bytes], dict]:
    """-> ({Dateiname: Inhalt (gz)}, Verzeichnis)"""
    payload = {"v": 1, "university": UNIVERSITY, "catalogs": [i["catalog"] for i in items]}
    raw = _dump(payload)
    groups: dict[str, list[dict]] = {}
    if len(raw) > SPLIT_BYTES:
        for i in items:
            groups.setdefault(f"luh-{_file_slug(i['faculty'])}.json.gz", []).append(i)
    else:
        groups["luh.json.gz"] = items
    files: dict[str, bytes] = {}
    file_of: dict[str, str] = {}
    sizes: dict[str, dict] = {}
    for name, group in sorted(groups.items()):
        data = _dump({"v": 1, "university": UNIVERSITY, "catalogs": [i["catalog"] for i in group]})
        gz = gzip.compress(data, compresslevel=9, mtime=0)
        files[name] = gz
        sizes[name] = {"bytes": len(gz), "raw_bytes": len(data), "sha256": hashlib.sha256(gz).hexdigest(),
                       "catalogs": len(group)}
        for i in group:
            file_of[i["library_key"]] = name
    by_key = {e["key"]: e for e in luh.get("programs") or []}
    entries = []
    for i in items:
        c = i["catalog"]
        for k in i["registry_keys"]:
            e = by_key.get(k) or {}
            entries.append({"key": k, "program": e.get("program") or c["program"], "degree": e.get("degree") or c["degree"],
                            "po": str(e.get("po") or c["po"]), "term": c["catalog_term"], "modules": len(c["modules"]),
                            "qis_labels": list(e.get("qis_labels") or []), "code": c["code"], "library_key": i["library_key"],
                            "file": file_of[i["library_key"]], "format": i["format"], "faculty": i["faculty"],
                            "study_plan": isinstance(c.get("study_plan"), dict)})
    entries.sort(key=lambda x: (x["key"], x["code"]))
    index = {"v": 1, "university": UNIVERSITY, "generator": "tools/build-luh-seed.py", "files": sizes,
             "catalogs": len(items), "modules": sum(len(i["catalog"]["modules"]) for i in items), "entries": entries}
    files["luh-index.json"] = (json.dumps(index, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode("utf-8")
    return files, index


DOC_START = "<!-- grundstock:start (tools/build-luh-seed.py) -->"
DOC_END = "<!-- grundstock:end -->"


def report(items: list[dict], index: dict, problems: list[str], stats: dict, luh: dict) -> str:
    lines = [DOC_START, "## Grundstock (Modulkataloge in der App)", "",
             "Erzeugt von `tools/build-luh-seed.py` aus den Fakten in `~/Studora-Builds/luh-seed/{fei,a,b}/` (FEI: modkat-Leser",
             "aus `app/study_catalog.py` mit eingemischtem Studienverlaufsplan; a/ und b/: Leser in `app/catalog_formats/`).",
             "Ressource `apps/apple/UniFlow/Resources/StudyCatalogSeed/` (gzip, nur geteilte Fakten ohne Modultexte), Verzeichnis",
             "`luh-index.json`. Die App sucht dort zuerst (Stand `seed`, „Aus dem StudiNow-Grundstock“), dann in der",
             "Bibliothek, erst dann lädt sie die PDF; Modultexte lädt sie erst, wenn jemand ein Modul öffnet (einmal je Katalog).",
             ""]
    lines += ["| Fakultät | Kataloge | Einträge | Module | Formate |", "|---|---:|---:|---:|---|"]
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
    total_entries = len({e['key'] for e in index['entries']})
    lines.append(f"| **zusammen** | **{len(items)}** | **{total_entries}** | **{index['modules']}** | |")
    lines.append("")
    form: dict[str, list[int]] = {}
    for i in items:
        form.setdefault(i["format"], [0, 0])
        form[i["format"]][0] += 1
        form[i["format"]][1] += len(i["catalog"]["modules"])
    lines.append("Nach Format: " + "; ".join(f"`{k}` {v[0]} Kataloge / {v[1]} Module" for k, v in sorted(form.items())) + ".")
    with_plan = sum(1 for i in items if isinstance(i["catalog"].get("study_plan"), dict))
    lines.append(f"Mit Studienverlaufsplan: {with_plan}. Registereinträge der Erhebung: {len(luh.get('programs') or [])}, "
                 f"davon im Grundstock: {total_entries}.")
    for name, s in sorted(index["files"].items()):
        lines.append(f"Datei `{name}`: {s['bytes'] / 1024:.0f} KB gzip, {s['raw_bytes'] / 1024:.0f} KB JSON, {s['catalogs']} Kataloge.")
    lines.append(f"Nachbearbeitung: {stats['kinds_fixed']} Module in Wahlbereichen von `pflicht` auf `wahlpflicht`/`wahl`, "
                 f"{stats['dropped_duplicate']} doppelte Kataloge, {stats['dropped_modules']} doppelte Module, "
                 f"{stats['dropped_invalid']} ungültige, {stats['dropped_unmapped']} nicht zugeordnete verworfen.")
    if problems:
        lines.append("")
        lines.append("Hinweise des letzten Laufs:")
        lines += [f"- {p}" for p in problems[:30]]
    lines += ["", "Neu bauen: `.venv/bin/python tools/build-luh-seed.py` (prüfen: `--check`, Vorschau: `--diff`).", DOC_END]
    return "\n".join(lines) + "\n"


def doc_with(doc_text: str, section: str) -> str:
    if DOC_START in doc_text and DOC_END in doc_text:
        a = doc_text.index(DOC_START)
        b = doc_text.index(DOC_END) + len(DOC_END)
        rest = doc_text[b:]
        return doc_text[:a] + section.rstrip("\n") + (rest if rest.startswith("\n") else "\n" + rest)
    return doc_text.rstrip("\n") + "\n\n" + section


def read_bundle(out_dir: Path) -> dict[str, dict]:
    """Vorhandene Ressource: {library_key: Katalog}"""
    out: dict[str, dict] = {}
    for f in sorted(out_dir.glob("luh*.json.gz")):
        try:
            data = json.loads(gzip.decompress(f.read_bytes()))
        except (OSError, ValueError):
            continue
        for c in data.get("catalogs") or []:
            out[sc.catalog_key(c)] = c
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


def build(seed_dir: Path, crawl: Path, plan_dirs: list[Path], fei: bool, log=print):
    if fei:
        build_fei(seed_dir / "fei", crawl, plan_dirs, log=log)
    luh, full = load_luh(), load_full()
    found, problems = collect(seed_dir)
    items, more, stats = postprocess(found, luh, full)
    files, index = bundle(items, luh)
    return items, files, index, problems + more, stats, luh


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Grundstock der LUH-Modulkataloge bauen")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--diff", action="store_true")
    ap.add_argument("--no-fei", action="store_true")
    ap.add_argument("--seed-dir", type=Path, default=SEED_DIR)
    ap.add_argument("--crawl-dir", type=Path, default=CRAWL_DIR)
    ap.add_argument("--plan-dir", type=Path, action="append")
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR)
    ap.add_argument("--doc", type=Path, default=DOC)
    args = ap.parse_args(argv)
    quiet = args.check or args.diff
    log = (lambda *_: None) if quiet else print
    # --check/--diff lesen FEI in einen eigenen Ordner neu (die Fakten in seed-dir/fei bleiben unberuehrt)
    seed_dir = args.seed_dir
    plan_dirs = args.plan_dir or PLAN_DIRS
    if quiet and not args.no_fei:
        import shutil
        import tempfile
        tmp = Path(tempfile.mkdtemp(prefix="luh-seed-check-"))
        for o in SOURCES[1:]:
            if (seed_dir / o).is_dir():
                shutil.copytree(seed_dir / o, tmp / o)
        seed_dir = tmp
    items, files, index, problems, stats, luh = build(seed_dir, args.crawl_dir, plan_dirs, not args.no_fei, log=log)
    section = report(items, index, problems, stats, luh)
    doc_text = args.doc.read_text(encoding="utf-8") if args.doc.exists() else ""
    new_doc = doc_with(doc_text, section)
    if args.diff:
        lines = diff(read_bundle(args.out_dir), items)
        print("\n".join(lines) if lines else "keine Aenderung an den Katalogen")
        return 0
    if args.check:
        stale = []
        old_index = args.out_dir / "luh-index.json"
        for name, data in files.items():
            p = args.out_dir / name
            if not p.exists():
                stale.append(name)
            elif name.endswith(".gz"):
                if gzip.decompress(p.read_bytes()) != gzip.decompress(data):
                    stale.append(name)
            elif p.read_bytes() != data:
                stale.append(name)
        extra = sorted(p.name for p in args.out_dir.glob("luh*.json.gz") if p.name not in files) if args.out_dir.exists() else []
        stale += [f"{n} (ueberzaehlig)" for n in extra]
        if new_doc != doc_text:
            stale.append(str(args.doc.name) + " (Abschnitt Grundstock)")
        if stale:
            print("Grundstock veraltet: " + ", ".join(stale) + " (tools/build-luh-seed.py ausfuehren)")
            for line in diff(read_bundle(args.out_dir), items)[:40]:
                print("  " + line)
            return 1
        print(f"Grundstock aktuell ({index['catalogs']} Kataloge, {index['modules']} Module, {old_index.name})")
        return 0
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for p in args.out_dir.glob("luh*.json.gz"):
        if p.name not in files:
            p.unlink()
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
    pending = [o for o in SOURCES[1:] if not any((args.seed_dir / o).glob("*.json"))]
    if pending:
        print("  noch keine Fakten in: " + ", ".join(f"{args.seed_dir / o}" for o in pending))
    return 0


if __name__ == "__main__":
    sys.exit(main())
