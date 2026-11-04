#!/usr/bin/env python3
"""Riesentest: Ergebnisse von tools/riesentest-python.py (Python-Referenz), RiesentestSynthTests (Swift-Kern) und
RiesentestSynthAppTests (iPad-App) zusammenfassen und je Konto vergleichen (Paritaet: gleiche Zahlen, gleiche Modulnamen).

Aufruf: python tools/riesentest-compare.py --python py.json --swift swift.json [--app app.json] [--md]
Nur Standardbibliothek. Gibt Markdown-Tabellen aus (fuer docs/RIESENTEST-2026-11-03.md).
"""
from __future__ import annotations

import argparse
import collections
import json
import statistics
from pathlib import Path

# Zahlen, die Python und Swift bei gleicher Eingabe gleich liefern muessen (Dateien: Swift ohne Videos/tiefe Ordner,
# darum nur die Summe der Pruefung, nicht die Rohzahl)
PARITY_KEYS = ("courses", "modules", "series_weekly", "cancelled", "studip_events", "deadlines_news_found", "cw_deadlines_found",
               "deadlines_found", "announcements", "lsf_series", "lsf_cancelled", "grades", "semesters", "messages")


def load(path: str | None) -> dict | None:
    if not path or not Path(path).exists():
        return None
    return json.loads(Path(path).read_text(encoding="utf-8"))


def pct(x: list[float], p: float) -> float:
    if not x:
        return 0.0
    s = sorted(x)
    return s[min(len(s) - 1, int(len(s) * p))]


def summary(name: str, r: dict) -> dict:
    accs = r["accounts"]
    secs = [a.get("seconds", 0.0) for a in accs]
    fails = collections.Counter()
    for a in accs:
        for k, v in (a.get("checks") or {}).items():
            if not v.get("ok"):
                fails[k] += 1
    phases: dict[str, float] = collections.defaultdict(float)
    for a in accs:
        for k, v in (a.get("phases") or {}).items():
            phases[k] += v
    errors = [a for a in accs if a.get("errors")]
    return {"name": name, "accounts": len(accs), "ok": sum(1 for a in accs if a.get("ok")), "errors": len(errors),
            "locked": sum(a.get("locked", 0) for a in accs), "wall": r.get("wall_seconds"), "parallel": r.get("parallel", 1),
            "rss": r.get("max_rss_mb"), "median": statistics.median(secs) if secs else 0, "p95": pct(secs, 0.95), "max": max(secs) if secs else 0,
            "sum": sum(secs), "over_budget": sum(1 for a in accs if a.get("within_budget") is False), "fails": dict(fails), "phases": dict(phases),
            "requests": sum(a.get("requests", 0) for a in accs), "files": sum((a.get("counts") or {}).get("files", 0) for a in accs),
            "downloaded": sum((a.get("counts") or {}).get("downloaded", 0) for a in accs),
            "courses": sum((a.get("counts") or {}).get("courses", 0) for a in accs), "modules": sum((a.get("counts") or {}).get("modules", 0) for a in accs)}


def compare(py: dict, sw: dict) -> dict:
    by_py = {a["index"]: a for a in py["accounts"]}
    by_sw = {a["index"]: a for a in sw["accounts"]}
    both = sorted(set(by_py) & set(by_sw))
    diffs: list[dict] = []
    same = 0
    module_mismatch = 0
    key_mismatch = collections.Counter()
    for i in both:
        a, b = by_py[i], by_sw[i]
        ca, cb = a.get("counts") or {}, b.get("counts") or {}
        d = {}
        for k in PARITY_KEYS:
            # nur Zahlen, die beide Seiten festhalten (die App-Pruefung zaehlt weniger als Kern und PC)
            if ca.get(k) is not None and cb.get(k) is not None and ca.get(k) != cb.get(k):
                d[k] = [ca.get(k), cb.get(k)]
                key_mismatch[k] += 1
        if ca.get("module_names") is not None and cb.get("module_names") is not None \
                and sorted(ca.get("module_names") or []) != sorted(cb.get("module_names") or []):
            d["module_names"] = [sorted(set(ca.get("module_names") or []) ^ set(cb.get("module_names") or []))]
            module_mismatch += 1
        if d:
            diffs.append({"index": i, "university": a.get("university"), "flags": a.get("flags"), "diff": d})
        else:
            same += 1
    return {"compared": len(both), "same": same, "module_mismatch": module_mismatch, "key_mismatch": dict(key_mismatch), "diffs": diffs}


def md_summary(rows: list[dict]) -> str:
    out = ["| Lauf | Konten | ok | Abstürze | locked | Wanduhr s | parallel | RSS MB | je Konto Median s | p95 s | max s | über Budget | Anfragen | Dateien in DB | geladen |",
           "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for s in rows:
        out.append(f"| {s['name']} | {s['accounts']} | {s['ok']} | {s['errors']} | {s['locked']} | {s['wall'] if s['wall'] is None else round(s['wall'], 1)} | {s['parallel']} | "
                   f"{s['rss'] if s['rss'] is None else round(s['rss'], 0)} | {s['median']:.2f} | {s['p95']:.2f} | {s['max']:.2f} | {s['over_budget']} | {s['requests']} | {s['files']} | {s['downloaded']} |")
    return "\n".join(out)


def md_phases(rows: list[dict]) -> str:
    keys = sorted({k for s in rows for k in s["phases"]})
    out = ["| Lauf | " + " | ".join(keys) + " |", "| --- |" + " --- |" * len(keys)]
    for s in rows:
        out.append(f"| {s['name']} | " + " | ".join(f"{s['phases'].get(k, 0):.1f}" for k in keys) + " |")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", nargs="*", default=[])
    ap.add_argument("--swift", nargs="*", default=[])
    ap.add_argument("--app", nargs="*", default=[])
    ap.add_argument("--compare", nargs=2, metavar=("PY", "SWIFT"), action="append", default=[])
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    rows = []
    for group, paths in (("Python", a.python), ("Swift-Kern", a.swift), ("iPad-App", a.app)):
        for p in paths:
            r = load(p)
            if r:
                rows.append(summary(f"{group} {Path(p).stem}", r))
    print("## Läufe\n")
    print(md_summary(rows))
    print("\n## Phasen (Summe Sekunden über alle Konten)\n")
    print(md_phases(rows))
    print("\n## Fehlgeschlagene Prüfpunkte\n")
    for s in rows:
        print(f"- {s['name']}: {s['fails'] or 'keine'}")
    result = {"runs": rows, "compare": []}
    for py_path, sw_path in a.compare:
        py, sw = load(py_path), load(sw_path)
        if not py or not sw:
            continue
        c = compare(py, sw)
        result["compare"].append({"python": py_path, "swift": sw_path, **c})
        print(f"\n## Parität {Path(py_path).stem} ↔ {Path(sw_path).stem}\n")
        print(f"- verglichene Konten: {c['compared']}, davon in allen Zahlen und Modulnamen gleich: {c['same']}")
        print(f"- Konten mit anderen Modulnamen: {c['module_mismatch']}; Abweichungen je Zahl: {c['key_mismatch'] or 'keine'}")
        for d in c["diffs"][:40]:
            print(f"  - #{d['index']} {d['university']} {d['flags']}: {json.dumps(d['diff'], ensure_ascii=False)}")
    if a.json:
        Path(a.json).write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
