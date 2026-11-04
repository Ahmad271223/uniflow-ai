"""Grundstock der Modulkataloge (tools/build-luh-seed.py, docs/STUDIENGAENGE-LUH-2026-11-04.md "Grundstock"):
Bau aus einem kleinen erfundenen Satz Fakten, Nachbearbeitung (Wahlbereiche nie Pflicht, nur Fakten, Doppeltes weg,
ungueltig/unzugeordnet weg), feste Reihenfolge, --check; Ablauf lokal -> Grundstock -> laden in app/study_catalog.py;
die mitgelieferte Ressource ist gueltig und passt zum Register."""
from __future__ import annotations

import copy
import gzip
import importlib.util
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FX = ROOT / "packages/shared-contracts/fixtures/study-catalog"
NOW = datetime(2026, 11, 4, 9, 0, tzinfo=timezone.utc)

_spec = importlib.util.spec_from_file_location("build_luh_seed", ROOT / "tools/build-luh-seed.py")
seed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(seed)

from app import study_catalog as sc  # noqa: E402

TI_URL = "https://modkat.fei.uni-hannover.de/material/modkat-full-TIBSc25-WS_2026_27.pdf"
ET_URL = "https://modkat.fei.uni-hannover.de/material/modkat-full-ETMSc17-WS_2026_27.pdf"


def _url_of(fmt: str) -> str:
    luh = seed.load_luh()
    return next(c["url"] for e in luh["programs"] for c in sc.luh_catalogs(e) if c.get("format") == fmt)


def _catalog(url: str, term: str = "WS 2026/27", program: str = "Erfunden") -> dict:
    """Kleiner erfundener Katalog: Pflicht, Nebenfach (faelschlich Pflicht), Schluesselkompetenzen (Wahl), Texte"""
    return {
        "v": 1, "university": "luh", "program": program, "degree": "B.Sc.", "po": "2017", "catalog_term": term,
        "code": None, "regular_semesters": 6, "total_lp": 180,
        "source": {"url": url, "fetched_at": "2026-11-04T09:00:00Z", "sha256": "0" * 64},
        "areas": [{"id": "grundlagen", "name": "Grundlagen", "lp_required": 10, "lp_max": None, "kind": "pflicht"},
                  {"id": "nebenfach-physik", "name": "Nebenfach Physik", "lp_required": 10, "lp_max": None, "kind": "pflicht"},
                  {"id": "schluesselkompetenzen", "name": "Schlüsselkompetenzen", "lp_required": 4, "lp_max": None, "kind": "wahl"}],
        "modules": [
            {"id": "beispiel-1", "title": "Beispiel I", "code": None, "area": "grundlagen", "kind": "pflicht", "lp": 5,
             "semester": 1, "turnus": "WS", "exam": "Klausur 90 min", "coursework": None, "prerequisites": [],
             "language": "deutsch", "workload_h": 150, "source_page": 3, "content": "langer Text", "_intern": 1},
            {"id": "physik-1", "title": "Physik I", "code": None, "area": "nebenfach-physik", "kind": "pflicht", "lp": 5,
             "semester": None, "turnus": "WS", "exam": None, "coursework": None, "prerequisites": ["beispiel-1"],
             "language": None, "workload_h": None, "source_page": 4},
            {"id": "physik-1", "title": "Physik I (doppelt)", "code": None, "area": "nebenfach-physik", "kind": "pflicht",
             "lp": 5, "semester": None, "turnus": "WS", "exam": None, "coursework": None, "prerequisites": [],
             "language": None, "workload_h": None, "source_page": 5},
            {"id": "rhetorik", "title": "Rhetorik", "code": None, "area": "schluesselkompetenzen", "kind": "pflicht",
             "lp": 2, "semester": None, "turnus": "SS", "exam": None, "coursework": None, "prerequisites": [],
             "language": None, "workload_h": None, "source_page": 6},
        ],
        "module_texts": {"beispiel-1": {"content": "x"}},
    }


def _write(path: Path, doc) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")


def _tiny(tmp: Path) -> dict:
    """Erfundener Satz: fei/ (TIBSc25 mit Plan, ETMSc17), a/ (MB-Katalog, dazu Duplikat von TI), b/ (ungueltig,
    unzugeordnet, unlesbar)"""
    sd = tmp / "seed"
    ti = _catalog(TI_URL)
    ti["study_plan"] = {"url": "https://example.org/plan.pdf", "fetched_at": None, "sha256": None}
    ti["plan_slots"] = [{"semester": 3, "title": "Nebenfach", "areas": ["nebenfach-physik"], "lp": 5, "lp_max": None}]
    _write(sd / "fei/TIBSc25-WS_2026_27.json", {"v": 1, "format": "modkat-FEI", "registry_keys": [], "catalog": ti})
    _write(sd / "fei/ETMSc17-WS_2026_27.json", {"catalog": _catalog(ET_URL)})
    mb = next(e["catalog"]["url"] for e in seed.load_luh()["programs"] if e["key"] == "luh|maschinenbau|b.sc.|2017")
    _write(sd / "a/luh|maschinenbau|b.sc.|2017.json", _catalog(mb, term="WS 2026/27"))
    _write(sd / "a/dup-ti.json", _catalog(TI_URL))                       # gleicher Schluessel wie fei/: fei gewinnt
    bad = _catalog(_url_of("maphy-katalog"), term="SS 2026")
    bad["modules"][0]["kind"] = "irgendwas"
    _write(sd / "b/bad.json", bad)
    _write(sd / "b/fremd.json", _catalog("https://example.org/fremd.pdf"))
    (sd / "b/kaputt.json").write_text("{", encoding="utf-8")
    doc = tmp / "doc.md"
    doc.write_text("# Bericht\n\nText davor.\n", encoding="utf-8")
    return {"seed": sd, "out": tmp / "out", "doc": doc, "mb": mb}


def _args(t: dict, *extra: str) -> list[str]:
    return ["--no-fei", "--seed-dir", str(t["seed"]), "--out-dir", str(t["out"]), "--doc", str(t["doc"]), *extra]


def test_fix_choice_kinds_rule():
    c = _catalog(TI_URL)
    assert seed.fix_choice_kinds(c) == 3
    kinds = {m["id"] + m["title"][-3:]: m["kind"] for m in c["modules"]}
    assert list(kinds.values()) == ["pflicht", "wahlpflicht", "wahlpflicht", "wahl"]
    assert [a["kind"] for a in c["areas"]] == ["pflicht", "wahlpflicht", "wahl"]
    assert seed.fix_choice_kinds(c) == 0, "idempotent"
    for name in ("Nebenfach Informatik", "Schluesselkompetenzen", "Wahlbereich", "Studium Generale", "Wahlpflichtmodule"):
        assert seed.is_choice_area(name), name
    for name in ("Grundlagen der Informatik", "Bachelorarbeit", None):
        assert not seed.is_choice_area(name)
    f = seed.facts_only(c)
    assert all("content" not in m and "_intern" not in m for m in f["modules"]) and "module_texts" not in f
    assert [m["id"] for m in f["modules"]] == ["beispiel-1", "physik-1", "rhetorik"], "doppelte id: die erste gilt"


def test_build_tiny_set_bundle_index_report_and_check(tmp_path, capsys):
    t = _tiny(tmp_path)
    assert seed.main(_args(t)) == 0
    files = sorted(p.name for p in t["out"].iterdir())
    assert files == ["luh-index.json", "luh.json.gz"]
    data = json.loads(gzip.decompress((t["out"] / "luh.json.gz").read_bytes()))
    cats = {c["code"]: c for c in data["catalogs"]}
    mb_code = "maschinenbau|b.sc.|2017"
    assert set(cats) == {"TIBSc25", "ETMSc17", mb_code}, "ungueltig, unzugeordnet und doppelt verworfen"
    for c in data["catalogs"]:
        assert sc.validate(c) == []
        assert not any(k in m for m in c["modules"] for k in ("content", "goals", "literature", "_intern"))
        assert not any(m["kind"] == "pflicht" for m in c["modules"] if m["area"] != "grundlagen")
    ti = cats["TIBSc25"]
    # Kopf aus dem gemischten Register (wie StudySources.meta auf dem Geraet), Plan aus fei/ behalten
    assert (ti["program"], ti["degree"], ti["po"]) == ("Technische Informatik", "B.Sc.", "2025")
    assert ti["study_plan"]["url"] == "https://example.org/plan.pdf" and ti["plan_slots"][0]["areas"] == ["nebenfach-physik"]
    assert cats["ETMSc17"]["program"] == "Elektrotechnik und Informationstechnik"
    assert cats[mb_code]["program"] == "Maschinenbau" and cats[mb_code]["po"] == "2017"
    index = json.loads((t["out"] / "luh-index.json").read_text())
    assert index["catalogs"] == 3 and index["modules"] == 9
    by_code: dict = {}
    for e in index["entries"]:
        by_code.setdefault(e["code"], []).append(e)
        assert e["library_key"] == sc.library_key("luh", e["code"], e["term"]) and e["file"] == "luh.json.gz"
        assert {"key", "program", "degree", "po", "term", "modules", "qis_labels"} <= set(e)
    assert len(by_code["ETMSc17"]) >= 2, "ein Katalog, mehrere Registereintraege (ET M.Sc. und Microelectronics)"
    assert any("Maschinenbau" in q for e in by_code[mb_code] for q in e["qis_labels"])
    assert index["files"]["luh.json.gz"]["sha256"] == __import__("hashlib").sha256((t["out"] / "luh.json.gz").read_bytes()).hexdigest()
    doc = t["doc"].read_text()
    assert doc.startswith("# Bericht\n\nText davor.\n") and "## Grundstock" in doc and doc.count(seed.DOC_START) == 1
    assert "b/bad.json: ungueltig" in doc and "b/fremd.json: keinem Registereintrag" in doc and "b/kaputt.json: nicht lesbar" in doc
    # erneut: byte-gleich, Bericht ersetzt statt angehaengt
    before = {p.name: p.read_bytes() for p in t["out"].iterdir()}
    assert seed.main(_args(t)) == 0
    assert before == {p.name: p.read_bytes() for p in t["out"].iterdir()} and t["doc"].read_text() == doc
    capsys.readouterr()
    assert seed.main(_args(t, "--check")) == 0
    # neue Fakten in a/: --check meldet veraltet und zeigt die Aenderung, --diff ebenso
    extra = _catalog(_url_of("luh-modulbeschreibung"), program="Neu")
    _write(t["seed"] / "a/neu.json", extra)
    assert seed.main(_args(t, "--check")) == 1
    out = capsys.readouterr().out
    assert "Grundstock veraltet" in out and "+ " in out
    assert seed.main(_args(t, "--diff")) == 0 and "+ " in capsys.readouterr().out


def test_split_per_faculty_above_limit(tmp_path, monkeypatch):
    t = _tiny(tmp_path)
    monkeypatch.setattr(seed, "SPLIT_BYTES", 100)
    assert seed.main(_args(t)) == 0
    names = sorted(p.name for p in t["out"].glob("luh*.json.gz"))
    assert len(names) >= 2 and "luh.json.gz" not in names
    index = json.loads((t["out"] / "luh-index.json").read_text())
    assert {e["file"] for e in index["entries"]} == set(names) == set(index["files"])
    assert seed.read_bundle(t["out"]).keys() == {e["library_key"] for e in index["entries"]}


def _conn(label: str):
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript("CREATE TABLE grades (id INTEGER PRIMARY KEY, text TEXT, abschluss TEXT);"
                       "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);")
    conn.execute("INSERT INTO settings VALUES ('university', 'luh')")
    conn.execute("INSERT INTO grades(text, abschluss) VALUES ('X', ?)", (label,))
    return conn


class Stub:
    def __init__(self):
        self.calls = []

    def __call__(self, url, etag=None, last_modified=None):
        self.calls.append(url)
        return sc.FetchResult(404, error="HTTP 404")


def test_sync_order_local_seed_download():
    """lokal -> Grundstock (0 Anfragen fuer den Katalog) -> laden; Kataloge ausserhalb von modkat nur aus dem Grundstock"""
    exp = json.loads((FX / "expected-full.json").read_text())
    cat = copy.deepcopy(exp["catalog"])
    key = sc.catalog_key(cat)
    conn, fetch = _conn("Technische Informatik (PO-Version 2017)"), Stub()
    s = sc.run_sync(conn, fetch, NOW, seed={key: cat})
    assert s["state"] == "seed" and s["origin"] == "seed" and s["message"] == "Aus dem StudiNow-Grundstock", s
    assert not any("modkat" in u for u in fetch.calls), "kein Download des Katalogs"
    assert sc.get_catalog(conn, key)["modules"] == cat["modules"]
    assert sc.db.row(conn, "SELECT origin FROM study_catalogs WHERE catalog_key=?", (key,))["origin"] == "seed"
    assert sc.run_sync(conn, fetch, NOW, seed={key: cat})["origin"] == "local"
    # ohne Grundstock: Download versucht (404 -> nicht gefunden)
    conn2, fetch2 = _conn("Technische Informatik (PO-Version 2017)"), Stub()
    assert sc.run_sync(conn2, fetch2, NOW, seed={})["state"] == "not_found" and any("modkat" in u for u in fetch2.calls)
    # Maschinenbau (luh-grundstock): Semester nur aus dem Grundstock, nie ein Download
    mb = sc.match_program("Maschinenbau (PO-Version 2017)")
    assert mb and mb["needs_confirmation"] is False
    mcat = dict(copy.deepcopy(cat), program="Maschinenbau", po="2017", code=mb["code"], catalog_term="WS 2026/27")
    conn3, fetch3 = _conn("Maschinenbau (PO-Version 2017)"), Stub()
    assert sc.run_sync(conn3, fetch3, NOW, seed={})["state"] == "not_found" and fetch3.calls == []
    s3 = sc.run_sync(conn3, fetch3, NOW, seed={sc.catalog_key(mcat): mcat})
    assert s3["state"] == "seed" and s3["code"] == mb["code"] and fetch3.calls == []
    assert sc.run_sync(conn3, fetch3, NOW, seed={}, force=True)["origin"] == "local" and fetch3.calls == []


def test_bundled_resource_valid_and_matches_registry():
    """Die mitgelieferte Ressource: gueltig, nur Fakten, Verzeichnis passt, Register kennt jedes Kuerzel, INF-Nebenfach
    nicht Pflicht, TI und INF mit Studienverlaufsplan"""
    index = json.loads((seed.OUT_DIR / "luh-index.json").read_text())
    cats = sc.load_seed()
    assert len(cats) == index["catalogs"] >= 21 and sum(len(c["modules"]) for c in cats.values()) == index["modules"]
    reg = sc.load_registry()
    for k, c in cats.items():
        assert sc.validate(c) == [], c["code"]
        assert sc.program_entry(reg, "luh", c["code"]) is not None, c["code"]
        assert not any(t in m for m in c["modules"] for t in ("content", "goals", "literature"))
        for m in c["modules"]:
            area = next(a for a in c["areas"] if a["id"] == m["area"]) if m["area"] else None
            if area and seed.is_choice_area(area["name"]):
                assert m["kind"] != "pflicht", (c["code"], m["id"])
    assert {e["library_key"] for e in index["entries"]} == set(cats)
    by_code = {c["code"]: c for c in cats.values()}
    assert {"TIBSc25", "INFBSc22"} <= set(by_code)
    assert by_code["TIBSc25"].get("study_plan") and by_code["INFBSc22"].get("study_plan")
    inf = by_code["INFBSc22"]
    neben = [m for m in inf["modules"] if (m["area"] or "").startswith("nebenfach")]
    assert neben and all(m["kind"] != "pflicht" for m in neben)
    m = sc.match_program("Technische Informatik (PO-Version 2017)")
    assert m["code"] == "TIBSc25" and m["needs_confirmation"] is True
    assert sc.library_key("luh", "TIBSc25", "WS 2026/27") in cats
