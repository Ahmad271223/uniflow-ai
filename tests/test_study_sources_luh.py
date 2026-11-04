"""Prueft packages/shared-contracts/study-sources-luh.json (Register aller LUH-Studiengaenge, erzeugt von
tools/luh-programs.py): eindeutige Schluessel, Pflichtfelder, alle URLs https auf uni-hannover.de, Formate aus der
festen Liste, keine Links auf Anmeldeseiten."""
from __future__ import annotations

import json
import re
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
DATA = json.loads((ROOT / "packages/shared-contracts/study-sources-luh.json").read_text())

REQUIRED = ("key", "university", "program", "degree", "faculty", "po", "catalog", "study_plan_url",
            "program_page", "regular_semesters", "total_lp", "qis_labels")
HOST = re.compile(r"^([a-z0-9-]+\.)*uni-hannover\.de$")
LOGIN = re.compile(r"(studip|qis\.|lsf\.|sso\.|login|shibboleth|ilias)", re.I)


def _urls(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str) and (k == "url" or k.endswith("_url") or k == "program_page"):
                yield v
            else:
                yield from _urls(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _urls(v)


def test_kopf():
    assert DATA["v"] == 1
    assert DATA["university"] == "luh"
    assert isinstance(DATA["programs"], list) and len(DATA["programs"]) >= 150
    assert set(DATA["formats"]) >= {"modkat-FEI", "none", "unknown"}
    codes = [m["code"] for m in DATA["modkat_codes"]]
    assert len(codes) == len(set(codes)) and "TIBSc25" in codes


def test_pflichtfelder_und_typen():
    for p in DATA["programs"]:
        for f in REQUIRED:
            assert f in p, (p.get("key"), f)
        assert p["university"] == "luh"
        assert p["program"] and p["degree"] and p["faculty"], p["key"]
        assert isinstance(p["qis_labels"], list) and all(isinstance(x, str) for x in p["qis_labels"])
        assert p["regular_semesters"] is None or 1 <= p["regular_semesters"] <= 12, p["key"]
        assert p["total_lp"] is None or 30 <= p["total_lp"] <= 360, p["key"]
        cat = p["catalog"]
        assert set(cat) >= {"url", "term", "format"}, p["key"]
        assert cat["format"] in DATA["formats"], (p["key"], cat["format"])
        if cat["format"] == "none":
            assert cat["url"] is None and not p["more_catalogs"], p["key"]
        else:
            assert cat["url"], p["key"]
        for extra in p["more_catalogs"]:
            assert extra["url"] and extra["format"] in DATA["formats"], p["key"]
        for d in p["po_documents"]:
            assert d["url"].endswith(".pdf"), d
        if cat["format"] == "modkat-FEI":
            assert re.search(r"/modkat-(full-)?[A-Za-z0-9_-]+-(WS_\d{4}_\d{2}|SS_\d{4})\.pdf$", cat["url"]), cat["url"]
            assert p.get("modkat_code"), p["key"]


def test_schluessel_eindeutig():
    keys = [p["key"] for p in DATA["programs"]]
    assert len(keys) == len(set(keys))
    for k in keys:
        assert re.fullmatch(r"luh\|[a-z0-9-]+\|[a-z0-9.-]+\|[A-Za-z0-9.-]+", k), k


def test_urls_https_uni_hannover():
    n = 0
    for u in _urls(DATA["programs"]):
        if u is None:
            continue
        p = urlsplit(u)
        assert p.scheme == "https", u
        assert HOST.match(p.netloc), u
        assert not LOGIN.search(p.netloc + p.path), u
        n += 1
    assert n > 200
