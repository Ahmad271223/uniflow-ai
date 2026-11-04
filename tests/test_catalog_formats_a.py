"""Leseprogramme "Formate A" (app/catalog_formats/, docs/STUDIENGAENGE-LUH-2026-11-04.md "Leseprogramme Formate A"):
erfundene Seitentexte im Aufbau der vier Vorlagen (tools/gen-catalog-formats-a-fixture.py) -> geteilte Fakten und
getrennte lokale Texte. Kein echtes Handbuch, kein Netz."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "catalog-formats-a"
sys.path.insert(0, str(ROOT))

from app.catalog_formats import FORMATS, get_parser  # noqa: E402
from app.catalog_formats.formats_a_common import kind_of, language_of, merge_catalogs, turnus_of  # noqa: E402
from app.study_catalog import validate  # noqa: E402

CASES = ["mb-modulkatalog", "luh-modulbeschreibung", "wiwi-unabhaengig", "wiwi-semester", "fbg-modulhandbuch"]


def _case(name):
    pages = json.loads((FX / f"{name}.pages.json").read_text(encoding="utf-8"))
    exp = json.loads((FX / f"{name}.expected.json").read_text(encoding="utf-8"))
    return pages, exp


def _mods(name):
    return {m["title"]: m for m in _case(name)[1]["catalog"]["modules"]}


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-catalog-formats-a-fixture.py", "--check"], cwd=ROOT,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_registry_has_four_formats():
    for f in ("luh-modulbeschreibung", "mb-modulkatalog", "wiwi-modulhandbuch", "fbg-modulhandbuch"):
        assert f in FORMATS
        assert callable(get_parser(f))
    assert get_parser("gibt-es-nicht") is None


@pytest.mark.parametrize("name", CASES)
def test_parse_equals_expected_and_validates(name):
    pages, exp = _case(name)
    catalog, texts = get_parser(exp["format"])(pages, exp["meta"])
    assert catalog == exp["catalog"]
    assert texts == exp["module_texts"]
    assert validate(catalog) == []


@pytest.mark.parametrize("name", CASES)
def test_shared_facts_without_texts(name):
    _, exp = _case(name)
    c = exp["catalog"]
    assert "module_texts" not in c
    for m in c["modules"]:
        assert not {"content", "goals", "literature"} & set(m)
        for v in m.values():
            assert not isinstance(v, str) or len(v) <= 500
    # lokale Texte getrennt, je Modul-id
    assert set(exp["module_texts"]) <= {m["id"] for m in c["modules"]}
    assert any(t.get("goals") for t in exp["module_texts"].values())


def test_mb_facts():
    m = _mods("mb-modulkatalog")
    g = m["Grundlagen der Beispieltechnik"]          # Titel umbrochen, Modul ueber zwei Seiten, gestapelte Tabelle
    assert (g["kind"], g["lp"], g["semester"], g["turnus"]) == ("pflicht", 7, 1, "WS")
    assert g["exam"] == "Klausur 120 min" and g["coursework"] == "Laborversuche"
    assert (g["workload_h"], g["language"], g["source_page"]) == (210, "deutsch", 3)
    a = m["Angewandte Beispielsysteme"]              # englische Feldnamen, Zeile mit Umbruch
    assert (a["kind"], a["turnus"], a["semester"], a["language"]) == ("wahlpflicht", "WS+SS", 3, "englisch")
    assert a["exam"].startswith("Projektorientierte Prüfung Bericht")
    assert a["prerequisites"] == [g["id"]]
    areas = {x["name"]: x for x in _case("mb-modulkatalog")[1]["catalog"]["areas"]}
    assert areas["Grundlagen der Beispieltechnik"]["lp_required"] == 12
    assert (areas["Vertiefung Beispieltechnik"]["lp_required"], areas["Vertiefung Beispieltechnik"]["lp_max"]) == (5, 10)
    assert a["area"] == areas["Vertiefung Beispieltechnik"]["id"]   # erster von mehreren Kompetenzbereichen
    texts = _case("mb-modulkatalog")[1]["module_texts"][g["id"]]
    assert "zwei Seiten" in texts["content"] and texts["literature"].startswith("Muster")


def test_luh_facts():
    m = _mods("luh-modulbeschreibung")
    e = m["Einführung in die Beispielkunde"]
    assert (e["code"], e["kind"], e["lp"], e["turnus"], e["semester"]) == ("100", "pflicht", 6, "WS", 1)
    assert e["exam"] == "Klausur K 90 (1 PL)" and e["coursework"] == "Teilnahme an der Übung (1 SL)"
    assert e["workload_h"] == 180
    a = m["Aufbaumodul Beispielkunde"]               # ohne "Modultitel", englischer Titel in Klammern weg
    assert (a["kind"], a["lp"], a["turnus"], a["semester"]) == ("wahlpflicht", 5, "SS", 4)
    assert a["exam"] == "Hausarbeit (15 Seiten) / benotet" and a["coursework"] is None
    assert a["prerequisites"] == [e["id"]]
    p = m["Beispielpraktikum im Gelände"]            # direkt nach dem vorigen Modul auf derselben Seite
    assert (p["turnus"], p["exam"], p["coursework"], p["workload_h"]) == ("unbekannt", None, "Geländeprotokoll", 120)
    x = m["Example Data Analysis"]                   # englische Vorlage ohne Nummern
    assert (x["kind"], x["lp"], x["turnus"], x["semester"]) == ("wahlpflicht", 5, "WS", 5)
    assert (x["exam"], x["coursework"]) == ("written exam (90 minutes)", "accepted exercises")
    assert len(m) == 4


def test_wiwi_facts_and_turnus_hints():
    u = _mods("wiwi-unabhaengig")
    b = u["Beispiel-BWL I: Grundlagen"]              # Zeile des eigenen Studiengangs, nicht die erste
    assert (b["kind"], b["semester"], b["lp"], b["workload_h"], b["code"]) == ("pflicht", 1, 6, 180, "999101")
    assert (b["exam"], b["turnus"], b["language"]) == ("Klausur (60 Min.)", "WS", "deutsch")
    s = u["Beispielmärkte"]
    assert (s["kind"], s["turnus"], s["semester"], s["language"]) == ("wahl", "SS", 4, "englisch")
    assert s["prerequisites"] == [b["id"]]
    sem = _mods("wiwi-semester")
    x = sem["Beispielmärkte"]                        # Semesterfassung: Turnus nur aus der unabhaengigen Fassung
    assert (x["kind"], x["semester"], x["lp"], x["turnus"], x["exam"]) == ("wahl", 4, 5, "SS", "Hausarbeit (10 Seiten)")
    assert _case("wiwi-semester")[1]["catalog"]["catalog_term"] == "SS 2026"
    pages, exp = _case("wiwi-semester")
    meta = {k: v for k, v in exp["meta"].items() if k != "turnus_hints"}
    c, _ = get_parser("wiwi-modulhandbuch")(pages, meta)
    assert c["modules"][0]["turnus"] == "unbekannt"


def test_fbg_facts():
    m = _mods("fbg-modulhandbuch")
    b = m["Beispielmechanik"]
    assert (b["kind"], b["semester"], b["lp"], b["turnus"], b["exam"]) == ("pflicht", 1, 6, "WS", "Klausur")
    assert (b["coursework"], b["language"], b["workload_h"]) == ("1 Studienleistung", "deutsch", 180)
    s = m["Beispielstatik"]                          # Vertiefungsmatrix, nur moegliche Pruefungsformen
    assert (s["kind"], s["turnus"], s["exam"], s["language"]) == ("wahlpflicht", "WS+SS", "möglich: K/MP/VbP", "deutsch/englisch")
    assert s["prerequisites"] == [b["id"]]
    areas = {a["name"]: a for a in _case("fbg-modulhandbuch")[1]["catalog"]["areas"]}
    assert areas["Übergreifende Inhalte"]["lp_required"] == 6 and areas["Übergreifende Inhalte"]["lp_max"] == 12
    assert s["area"] == areas["Übergreifende Inhalte"]["id"]


def test_value_helpers():
    assert turnus_of("i.d.R. im Wintersemester") == "WS"
    assert turnus_of("SoSe") == "SS"
    assert turnus_of("WiSe/SoSe") == "WS+SS"
    assert turnus_of("jedes Semester") == "WS+SS"
    assert turnus_of("jährlich") == "unbekannt"
    assert turnus_of("every winter term") == "WS"
    assert kind_of("Pflicht / Compulsory") == "pflicht"
    assert kind_of("Required elective") == "wahlpflicht"
    assert kind_of("Wahlmodul") == "wahl"
    assert kind_of("WP") == "wahlpflicht"
    assert language_of("Deutsch/Englisch") == "deutsch/englisch"
    assert language_of("E") == "englisch"
    assert language_of("German / English") == "deutsch/englisch"


def test_merge_second_handbook():
    _, a = _case("luh-modulbeschreibung")
    _, b = _case("mb-modulkatalog")
    merged, texts = merge_catalogs(a["catalog"], a["module_texts"], b["catalog"], b["module_texts"])
    assert validate(merged) == []
    assert len(merged["modules"]) == len(a["catalog"]["modules"]) + len(b["catalog"]["modules"])
    again, _ = merge_catalogs(merged, texts, b["catalog"], b["module_texts"])
    assert len(again["modules"]) == len(merged["modules"])   # gleiche Titel nur einmal
