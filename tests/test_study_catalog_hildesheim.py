"""Leser fuer "Studienordnung inklusive Modulhandbuch" der Universitaet Hildesheim (app/study_catalog_hildesheim.py):
erfundene Seitentexte im Aufbau der Studienordnungen (tools/gen-study-catalog-hildesheim-fixture.py); der Swift-Kern
prueft dieselben Dateien (StudyCatalogHildesheimParserTests). Kein echtes Netz, keine echte Ordnung."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

from app import study_catalog as sc
from app import study_catalog_hildesheim as hi

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-catalog-hildesheim"


def _j(name):
    return json.loads((FX / name).read_text(encoding="utf-8"))


def _mods(case):
    return {m["id"]: m for m in case["catalog"]["modules"]}


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-study-catalog-hildesheim-fixture.py", "--check"], cwd=ROOT,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.mark.parametrize("name", ["verkuendungsblatt", "lesefassung", "pdfkit-roh"])
def test_case_matches_fixture_and_validates(name):
    c = _j(f"{name}.json")
    pages = c["pages"]
    assert hi.is_hildesheim_sto(pages) is c["detect"] is True
    assert sc.dumps(hi.hildesheim_sto_head(pages)) == c["head_dumps"]
    catalog, texts = hi.parse_hildesheim_sto(pages, c["meta"])
    assert sc.validate(catalog) == []
    assert sc.dumps(catalog) == c["dumps"] and sc.dumps(texts) == c["texts_dumps"]
    assert sc.dumps(hi.hildesheim_sto_details(pages)) == c["details_dumps"]
    # Form wie parse_luh_modkat: dieselben Schluessel, Texte nur lokal
    assert list(catalog) == ["v", "university", "program", "degree", "po", "catalog_term", "code", "regular_semesters",
                             "total_lp", "source", "areas", "modules"]
    assert all(list(m) == ["id", "title", "code", "area", "kind", "lp", "semester", "turnus", "exam", "coursework",
                           "prerequisites", "language", "workload_h", "source_page"] for m in catalog["modules"])
    assert set(texts) == {m["id"] for m in catalog["modules"]}
    assert all(set(t) == {"content", "goals", "literature"} for t in texts.values())


def test_verkuendungsblatt_modules_title_parts_and_facts():
    c = _j("verkuendungsblatt.json")
    assert c["head"] == {"program": "Garten- und Teichpädagogik", "level": "Bachelor", "degree": "Bachelor",
                         "stand": "2031-02-14", "heft": "999", "po": "2031", "catalog_term": "WS 2031/32", "total_lp": 45}
    m = _mods(c)
    assert [x["title"] for x in m.values()] == ["Einstieg in den Garten", "Gartenpädagogik II – Handeln in Gemeinschaftsgärten",
                                                "Teichrecht I", "Abschlussmodul"]
    assert [x["lp"] for x in m.values()] == [6, 15, 9, 15] and sum(x["lp"] for x in m.values()) == c["head"]["total_lp"]
    first = m["einstieg-in-den-garten"]
    # Wert ueber die Seitengrenze, Seitenkopf weg
    assert (first["semester"], first["turnus"], first["workload_h"], first["source_page"]) == (1, "WS+SS", 180, 3)
    assert first["exam"] == "Modulprüfung (unbenotet): Beetbericht und Referat"
    assert first["coursework"].endswith("Gartentagebuch ergänzt wird.")
    assert "Verkündungsblatt" not in sc.dumps(c["catalog"]) + sc.dumps(c["module_texts"])
    # Titel ueber zwei Zeilen, Voraussetzung nennt die Modulnummer
    second = m["gartenpaedagogik-2-handeln-in-gemeinschaftsgaerten"]
    assert second["prerequisites"] == ["einstieg-in-den-garten"] and second["semester"] == 4
    # Pruefungsleistung ohne Begruendung, Turnus aus den Teilmodulen
    third = m["teichrecht-1"]
    assert third["exam"] == "Teilmodulprüfungen: Klausur in TM 1 und in TM 2" and third["turnus"] == "WS+SS"
    last = m["abschlussmodul"]
    assert (last["kind"], last["lp"], last["coursework"], last["turnus"]) == ("abschluss", 15, None, "unbekannt")
    assert last["prerequisites"] == ["einstieg-in-den-garten", "teichrecht-1"]
    d = c["details"]
    assert [d[k]["number"] for k in m] == [1, 2, 3, 4] and d["abschlussmodul"]["sws"] is None
    assert d["einstieg-in-den-garten"]["parts"][2] == {"number": 3, "title": "Werkzeuge der Gartenarbeit", "kind": "Seminar",
                                                      "sws": 2, "lp": 2, "term": "WS+SS"}
    assert [(p["title"], p["lp"], p["term"]) for p in d["teichrecht-1"]["parts"]] == [
        ("Einführung in das Teichrecht", 4.5, "SS"), ("Froschrecht „Quaken und Schweigen“", 4.5, "WS")]
    # Inhalte nur in den lokalen Texten
    assert "Gewächshaus" not in sc.dumps(c["catalog"]) and "Gewächshaus" in c["module_texts"]["einstieg-in-den-garten"]["content"]


def test_lesefassung_rows_from_positioned_items():
    c = _j("lesefassung.json")
    assert hi.row_pages(c["items"]) == c["pages"]
    # die Stuecke stehen in der Fixture nicht in Lesereihenfolge (Feldnamen-Spalte zuerst)
    assert hi.parse_hildesheim_sto(["\n".join(t for _, _, t in page) for page in c["items"]], c["meta"])[0]["modules"] != c["catalog"]["modules"]
    assert c["head"]["degree"] == "M.A." and c["head"]["stand"] == "2032-03-02" and c["head"]["catalog_term"] == "SS 2031"
    assert (c["catalog"]["program"], c["catalog"]["po"], c["catalog"]["total_lp"]) == ("Wald- und Wiesenpädagogik", "2032", 33)
    m = _mods(c)
    assert [x["semester"] for x in m.values()] == [1, 1, 3, 1]
    assert [x["turnus"] for x in m.values()] == ["WS+SS", "WS+SS", "unbekannt", "WS"]
    assert m["wiesenkunde"]["coursework"] is None and m["wiesenkunde"]["lp"] == 6
    third = m["pilze-und-flechten-3-sammeln-bestimmen-und-bewahren"]
    assert third["title"] == "Pilze und Flechten III – Sammeln, Bestimmen und Bewahren"
    assert third["prerequisites"] == ["wiesenkunde", "waldeingangsphase"]
    assert c["details"][third["id"]]["parts"][0]["lp"] == 6


def test_raw_pdfkit_text_keeps_only_what_is_certain():
    c = _j("pdfkit-roh.json")
    mods = c["catalog"]["modules"]
    assert [(x["title"], x["lp"]) for x in mods] == [("Hochbeet", 6), ("Kräuterspirale – Planen und", 6), ("Teichbau", None)]
    for x in mods:
        assert (x["semester"], x["turnus"], x["exam"], x["coursework"], x["workload_h"], x["prerequisites"]) == \
            (None, "unbekannt", None, None, None, [])
    assert len(c["details"]["hochbeet"]["parts"]) == 2


def test_values_and_detection():
    w = _j("werte.json")
    assert all(hi._semester(c["text"]) == c["semester"] for c in w["semester"])
    assert all(hi._season(c["text"]) == c["turnus"] for c in w["season"])
    assert all(hi._lp(c["lines"]) == c["lp"] for c in w["lp"])
    assert all(sc.dumps(hi._parts(c["lines"])) == c["dumps"] for c in w["parts"])
    assert all(hi._clip(c["text"], c["limit"]) == c["clip"] for c in w["clip"])
    for c in w["detect"]:
        assert hi.is_hildesheim_sto(c["pages"]) is c["detect"], c["name"]
        assert sc.dumps(hi.hildesheim_sto_head(c["pages"])) == c["head_dumps"], c["name"]
    assert [c["detect"] for c in w["detect"]] == [False, False, False, False, True]


def test_luh_reader_finds_nothing_in_this_format():
    c = _j("verkuendungsblatt.json")
    assert sc.parse_luh_modkat(c["pages"], c["meta"])[0]["modules"] == []
