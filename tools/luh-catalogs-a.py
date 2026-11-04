"""Grundstock der Modulkataloge, Formate A (Auftrag 04.11.2026, docs/STUDIENGAENGE-LUH-2026-11-04.md, Abschnitt
"Leseprogramme Formate A"): liest alle zwischengespeicherten Modulhandbuecher der Formate luh-modulbeschreibung,
mb-modulkatalog, wiwi-modulhandbuch und fbg-modulhandbuch einmal auf dem Mac (nie auf dem Geraet), prueft sie mit dem
gemeinsamen Validator und schreibt nur die geteilten Fakten (keine Modultexte) nach
~/Studora-Builds/luh-seed/a/<registry-key>.json. Kein Netz: PDFs nur aus ~/Studora-Builds/luh-crawl/ (index.json).

Aufruf im Projektordner:
  .venv/bin/python tools/luh-catalogs-a.py            # lesen, schreiben, Tabelle ausgeben
  .venv/bin/python tools/luh-catalogs-a.py --docs     # dazu die Abdeckungstabelle im Doc ersetzen
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.catalog_formats import get_parser  # noqa: E402
from app.catalog_formats.formats_a_common import fill_rates, merge_catalogs, pdf_pages, validate  # noqa: E402
from app.catalog_formats.wiwi_modulhandbuch import turnus_hints  # noqa: E402
from app.study_catalog import TERM_RE  # noqa: E402

REGISTRY = ROOT / "packages" / "shared-contracts" / "study-sources-luh.json"
CRAWL = Path.home() / "Studora-Builds" / "luh-crawl"
OUT = Path.home() / "Studora-Builds" / "luh-seed" / "a"
DOC = ROOT / "docs" / "STUDIENGAENGE-LUH-2026-11-04.md"
FORMATS = ("luh-modulbeschreibung", "mb-modulkatalog", "wiwi-modulhandbuch", "fbg-modulhandbuch")
HEADING = "## Leseprogramme Formate A"
FALLBACK_TERM = "WS 2026/27"   # Abrufsemester des Zwischenspeichers (04.11.2026), wenn das Handbuch keins nennt


def _fetched(index: dict) -> dict:
    out = {}
    for e in index.get("log") or []:
        if e.get("status") == 200 and e.get("url") not in out:
            out[e["url"]] = datetime.fromtimestamp(e["t"], tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return out


def main() -> int:
    reg = json.loads(REGISTRY.read_text(encoding="utf-8"))
    index = json.loads((CRAWL / "index.json").read_text(encoding="utf-8"))
    urls, fetched = index["urls"], _fetched(index)
    pages_cache: dict = {}

    def pages_of(url):
        e = urls.get(url)
        if not e or e.get("status") != 200 or not e.get("path"):
            return None
        if url not in pages_cache:
            pages_cache[url] = pdf_pages(Path(e["path"]).read_bytes())
        return pages_cache[url]

    entries = [p for p in reg["programs"] if (p.get("catalog") or {}).get("format") in FORMATS]
    # Turnus-Hinweise fuer die WiWi-Semesterfassungen aus der semesterunabhaengigen Fassung (Digital Business)
    hints: dict = {}
    for p in entries:
        c = p["catalog"]
        if c["format"] == "wiwi-modulhandbuch" and "semesterunabh" in (c.get("term") or ""):
            pg = pages_of(c["url"])
            if pg:
                cat, _ = get_parser("wiwi-modulhandbuch")(pg, {"source": {"url": c["url"]}, "catalog_term": FALLBACK_TERM})
                hints.update(turnus_hints(cat))
    OUT.mkdir(parents=True, exist_ok=True)
    rows = []
    for p in entries:
        c = p["catalog"]
        fmt = c["format"]
        parse = get_parser(fmt)
        cats = [c] + [m for m in p.get("more_catalogs") or [] if m.get("format") == fmt]
        row = {"key": p["key"], "program": p["program"], "degree": p["degree"], "po": p["po"], "format": fmt,
               "est": sum(x.get("modules_est") or 0 for x in cats), "error": None}
        result = texts = None
        try:
            for x in cats:
                pg = pages_of(x["url"])
                if pg is None:
                    raise RuntimeError("PDF nicht im Zwischenspeicher")
                e = urls[x["url"]]
                term = x.get("term") if TERM_RE.match(x.get("term") or "") else None
                meta = {"university": "luh", "program": p["program"], "degree": p["degree"], "po": p["po"],
                        "code": p["key"].split("|", 1)[1], "catalog_term": term,
                        "regular_semesters": p.get("regular_semesters"), "total_lp": p.get("total_lp"),
                        "source": {"url": x["url"], "fetched_at": fetched.get(x["url"]), "sha256": e.get("sha256")},
                        "turnus_hints": hints}
                cat, tx = parse(pg, meta)
                if not cat.get("catalog_term"):
                    cat["catalog_term"] = FALLBACK_TERM
                if result is None:
                    result, texts = cat, tx
                else:
                    result, texts = merge_catalogs(result, texts, cat, tx)
        except Exception as exc:  # noqa: BLE001
            row["error"] = f"{type(exc).__name__}: {exc}"
            rows.append(row)
            continue
        errs = validate(result)
        row["errors"] = errs
        row["rates"] = fill_rates(result)
        row["texts"] = len(texts)
        row["term"] = result["catalog_term"]
        if not errs and result["modules"]:
            name = p["key"].replace("/", "_") + ".json"
            (OUT / name).write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        rows.append(row)
    table = _table(rows)
    print(table)
    if "--docs" in sys.argv:
        _write_doc(table)
    bad = [r for r in rows if r.get("error") or r.get("errors")]
    return 1 if bad else 0


def _pct(v) -> str:
    return f"{round(v * 100):d}"


def _table(rows: list[dict]) -> str:
    out = []
    totals: dict = {}
    for fmt in FORMATS:
        rs = [r for r in rows if r["format"] == fmt]
        n = sum(r.get("rates", {}).get("modules", 0) for r in rs)

        def w(k):
            s = sum(r["rates"][k] * r["rates"]["modules"] for r in rs if r.get("rates"))
            return s / n if n else 0
        totals[fmt] = (len(rs), n, sum(r["est"] for r in rs), {k: w(k) for k in
                       ("title", "lp", "exam", "coursework", "turnus", "semester", "language", "workload_h", "area")},
                       sum(1 for r in rs if r.get("error") or r.get("errors")))
    out.append("| Format | Einträge | Module gelesen | Schätzung | Titel | LP | Prüfung | Studienl. | Turnus | Semester |"
               " Sprache | Aufwand | Bereich | Fehler |")
    out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for fmt, (ne, n, est, r, bad) in totals.items():
        out.append(f"| `{fmt}` | {ne} | {n} | {est} | " + " | ".join(_pct(r[k]) for k in
                   ("title", "lp", "exam", "coursework", "turnus", "semester", "language", "workload_h", "area"))
                   + f" | {bad} |")
    out.append("")
    out.append("Je Eintrag (Werte in % der gelesenen Module; Turnus zählt nur WS/SS/WS+SS, nicht „unbekannt“):")
    out.append("")
    out.append("| Eintrag | Format | Module / Schätzung | LP | Prüfung | Turnus | Semester | Sprache | Bereich | Validator |")
    out.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for r in rows:
        key = r["key"].replace("luh|", "")
        if r.get("error"):
            out.append(f"| {key} | {r['format']} | – / {r['est']} | | | | | | | {r['error']} |")
            continue
        q = r["rates"]
        val = "ok" if not r["errors"] else f"{len(r['errors'])} Fehler ({r['errors'][0]})"
        out.append(f"| {key} | {r['format']} | {q['modules']} / {r['est']} | {_pct(q['lp'])} | {_pct(q['exam'])} | "
                   f"{_pct(q['turnus'])} | {_pct(q['semester'])} | {_pct(q['language'])} | {_pct(q['area'])} | {val} |")
    return "\n".join(out)


def _write_doc(table: str) -> None:
    text = DOC.read_text(encoding="utf-8")
    intro = (HEADING + "\n\n"
             "Leseprogramme für vier Formate außerhalb der FEI (`app/catalog_formats/`: `luh_modulbeschreibung.py`, "
             "`mb_modulkatalog.py`, `wiwi_modulhandbuch.py`, `fbg_modulhandbuch.py`, gemeinsame Bausteine in "
             "`formats_a_common.py`, Register `FORMATS` in `__init__.py`). Gelesen wird einmal auf dem Mac aus dem "
             "Zwischenspeicher (kein Netz), Textgewinnung und Normalisierung wie `app/study_catalog.py`; geprüft mit "
             "dem gemeinsamen Validator. Ausgabe nur Fakten nach `~/Studora-Builds/luh-seed/a/<registry-key>.json` "
             "(außerhalb des Repos); Inhalte, Lernziele und Literatur liefern die Parser getrennt (nur lokal, nicht "
             "geschrieben). Erneut: `.venv/bin/python tools/luh-catalogs-a.py --docs`. Tests mit erfundenen Texten: "
             "`tests/test_catalog_formats_a.py` (Fixture `packages/shared-contracts/fixtures/catalog-formats-a/`, "
             "Erzeuger `tools/gen-catalog-formats-a-fixture.py [--check]`).\n\n"
             "Hinweise: `code` ist bei diesen Formaten der Registerschlüssel ohne `luh|` (kein Kürzel wie bei modkat). "
             "Katalogsemester aus dem Register, sonst aus dem Handbuch („Wintersemester 2026/2027“, „Stand: TT.MM.JJJJ“), "
             "sonst WS 2026/27. Ein zweites Handbuch desselben Formats (`more_catalogs`, z. B. Wahlpflicht) wird "
             "angehängt. Gleiche Module in mehreren Bereichen/Vertiefungen stehen einmal im Katalog (erster Bereich). "
             "Die WiWi-Semesterfassungen nennen keinen Turnus; er kommt nur aus der semesterunabhängigen Fassung "
             "(Digital Business), wenn der Titel gleich ist. FBG: Prüfung = gewählte Form je Prüfungszeitraum "
             "(„P-Form“), sonst „möglich: K/KA/…“. Schätzungen aus dem Register zählen Modulbeschreibungen mit "
             "Wiederholungen (gleiches Modul je Vertiefung) mit.\n\n")
    block = intro + table + "\n"
    if HEADING in text:
        start = text.index(HEADING)
        nxt = text.find("\n## ", start + len(HEADING))
        text = text[:start] + block + (text[nxt + 1:] if nxt >= 0 else "")
    else:
        text = text.rstrip("\n") + "\n\n" + block
    DOC.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
