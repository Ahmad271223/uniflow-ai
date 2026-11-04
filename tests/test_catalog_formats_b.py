"""Leseprogramme "Formate B": phil-kv-tabelle, maphy-katalog und OCR-Zeilen (app/catalog_formats/).

Nur erfundene Fixtures (packages/shared-contracts/fixtures/catalog-formats-b/, Erzeuger
tools/gen-catalog-formats-b-fixture.py); keine PDFs, kein Netz, keine Texterkennung im Test.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from app.catalog_formats import FORMATS, get_parser, maphy_katalog, ocr_pages, phil_kv_tabelle
from app.study_catalog import TEXT_KEYS, shareable, validate

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "packages" / "shared-contracts" / "fixtures" / "catalog-formats-b"
sys.path.insert(0, str(ROOT / "tools"))


def _load(name):
    return json.loads((FIX / name).read_text())


def _gen():
    import importlib.util
    spec = importlib.util.spec_from_file_location("gen_b", ROOT / "tools" / "gen-catalog-formats-b-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ----------------------------------------------------------------------------
# Register und Fixtures
# ----------------------------------------------------------------------------

def test_registry_lines():
    assert FORMATS["phil-kv-tabelle"] == "app.catalog_formats.phil_kv_tabelle:parse"
    assert FORMATS["maphy-katalog"] == "app.catalog_formats.maphy_katalog:parse"
    assert get_parser("phil-kv-tabelle") is phil_kv_tabelle.parse
    assert get_parser("maphy-katalog") is maphy_katalog.parse


def test_fixtures_up_to_date():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen-catalog-formats-b-fixture.py"), "--check"],
                       capture_output=True, text=True, cwd=ROOT)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.mark.parametrize("name", ["phil-expected.json", "maphy-expected.json"])
def test_expected_catalogs_valid_and_facts_only(name):
    for cat in _load(name).values():
        assert validate(cat) == []
        assert shareable(cat) == cat
        for m in cat["modules"]:
            assert not any(k in m for k in TEXT_KEYS)
            for k in ("exam", "coursework", "title"):
                assert m[k] is None or len(m[k]) <= 500


# ----------------------------------------------------------------------------
# phil-kv-tabelle
# ----------------------------------------------------------------------------

def _phil(key):
    gen = _gen()
    return phil_kv_tabelle.parse(_load("phil-pages.json"), gen.phil_meta(key, gen.PHIL_KEYS[key]))


def test_phil_matches_fixture():
    gen = _gen()
    exp = _load("phil-expected.json")
    for key in gen.PHIL_KEYS:
        cat, texts = _phil(key)
        assert cat == exp[key]
        assert texts  # lokale Texte getrennt


def test_phil_fueba_modules_and_fields():
    cat, texts = _phil("luh|beispielkunde-im-faecheruebergreifenden-bachelor|b.a.|2016")
    by = {m["id"]: m for m in cat["modules"]}
    assert list(by) == ["grundlagen-der-beispielkunde", "vertiefung-der-beispielkunde", "bachelorarbeit"]
    g = by["grundlagen-der-beispielkunde"]
    assert (g["lp"], g["workload_h"], g["turnus"], g["semester"], g["code"]) == (8, 240, "WS", 1, "10 100")
    assert g["exam"] == "Klausur (90 Minuten)"
    assert g["coursework"] == "Eine Studienleistung pro Lehrveranstaltung"
    v = by["vertiefung-der-beispielkunde"]
    # "Pflichtmodul (FueBa) und Wahlpflichtmodul (Master LG)": Art je Studiengang
    assert v["kind"] == "pflicht"
    # "Semesterlage und / Haeufigkeit des Angebots" ueber zwei Zeilen, "Pruefungs- und Studienleistungen" getrennt
    assert (v["turnus"], v["semester"], v["exam"], v["coursework"]) == ("WS+SS", 2, "Hausarbeit (15 Seiten)", "Referat")
    assert v["prerequisites"] == ["grundlagen-der-beispielkunde"]
    assert v["workload_h"] == 300
    b = by["bachelorarbeit"]
    assert (b["kind"], b["semester"], b["coursework"], b["code"]) == ("abschluss", 6, None, "9999")
    assert "Erfundene Inhalte der Beispielkunde, Teil eins." in texts["grundlagen-der-beispielkunde"]["content"]
    assert texts["grundlagen-der-beispielkunde"]["literature"].startswith("Muster, E.")
    assert cat["catalog_term"] == "WS 2026/27"


def test_phil_master_filter_and_kind():
    cat, _ = _phil("luh|beispielkunde-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016")
    ids = [m["id"] for m in cat["modules"]]
    # Bachelorarbeit nur FueBa, Zertifikatsmodul nirgends
    assert ids == ["grundlagen-der-beispielkunde", "vertiefung-der-beispielkunde", "beispielpraxis-im-lehramt"]
    by = {m["id"]: m for m in cat["modules"]}
    assert by["vertiefung-der-beispielkunde"]["kind"] == "wahlpflicht"
    p = by["beispielpraxis-im-lehramt"]
    assert (p["turnus"], p["semester"], p["lp"], p["coursework"], p["code"]) == ("SS", 2, 5, None, None)


def test_phil_without_layout_falls_back_to_labels():
    """Normale pypdf-Texte (eine Leerstelle zwischen Schluessel und Wert) gehen auch"""
    pages = ["Pflichtmodul Einfache Kunde\nAnbieter Institut\nHäufigkeit des Angebots jedes Sommersemester\n"
             "ECTS-LP/Workload 6 LP / 180 Stunden\nPrüfungsleistungen Klausur (60 Minuten)\nStudienleistungen keine"]
    cat, _ = phil_kv_tabelle.parse(pages, {"university": "luh", "program": "X", "degree": "B.A.", "po": "2016",
                                           "code": "x", "catalog_term": "SS 2026", "source": {"url": "https://x"}})
    assert validate(cat) == []
    m = cat["modules"][0]
    assert (m["title"], m["lp"], m["turnus"], m["workload_h"], m["exam"]) == \
        ("Einfache Kunde", 6, "SS", 180, "Klausur (60 Minuten)")


@pytest.mark.parametrize("text,lp,expected", [
    ("8 LP/ 240 Stunden 75 Kontaktstunden 165 Selbststudium", 8, 240),
    ("6 LP / 180 Stunden Präsenzzeit: 75 h, Selbststudium: 105 h", 6, 180),
    ("14 LP 2 x 2 SWS 60 Kontaktstunden 360 Stunden Selbststudium", 14, 420),
    ("5 LP Präsenzzeit: 60 h Selbststudium: 90 h", 5, 150),
    ("24 LP, davon 3 LP für LE 3.1, 90 Stunden", 24, None),
])
def test_phil_workload(text, lp, expected):
    assert phil_kv_tabelle.workload_phil(text, lp) == expected


@pytest.mark.parametrize("key,family", [
    ("luh|sport-im-faecheruebergreifenden-bachelor|b.a.|2016", "fueba"),
    ("luh|sport-im-bachelorstudiengang-technical-education|b.sc.|2016", "te"),
    ("luh|sport-im-masterstudiengang-lehramt-an-gymnasien|m.ed.|2016", "lg"),
    ("luh|sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen|m.ed.|2016", "lbs"),
    ("luh|sport-im-masterstudiengang-lehramt-an-berufsbildenden-schulen-fuer-fachbachelor-lbs-sprint|m.ed.|2026",
     "sprint"),
    ("luh|sport-im-bachelorstudiengang-sonderpaedagogik|b.a.|2016", "so_ba"),
    ("luh|sport-im-masterstudiengang-lehramt-fuer-sonderpaedagogik|m.ed.|2016", "so_ma"),
    ("luh|politikwissenschaft|b.a.|2016", None),
])
def test_program_family(key, family):
    assert phil_kv_tabelle.program_family(key) == family


@pytest.mark.parametrize("usage,family,keep", [
    ("Fächerübergreifender Bachelorstudiengang (Erst- und Zweitfach) Zertifikatsprogramm LG", "lg", False),
    ("Fächerübergreifender Bachelorstudiengang (Erst- und Zweitfach) Zertifikatsprogramm LG", "fueba", True),
    ("Masterstudiengang Lehramt an berufsbildenden Schulen (LBS-Sprint)", "lbs", False),
    ("Masterstudiengang Lehramt an berufsbildenden Schulen (LBS-Sprint)", "sprint", True),
    ("Bachelorstudiengang Sonderpädagogik Zertifikatsprogramm LSo", "so_ba", True),
    ("Bachelorstudiengang Sonderpädagogik Zertifikatsprogramm LSo", "so_ma", False),
    ("Zertifikatsprogramm LBS", "fueba", False),
    ("", "fueba", True),
])
def test_keep_for_program(usage, family, keep):
    raw = {"usage": usage, "title": "Modul", "kind_text": "Pflichtmodul"}
    assert phil_kv_tabelle.keep_for_program(raw, family) is keep


@pytest.mark.parametrize("kind_text,kind,area", [
    ("Pflichtmodul Politikwissenschaft", "pflicht", "Pflichtmodule Politikwissenschaft"),
    ("Basismodul B", "pflicht", "Basismodule"),
    ("Wahlpflichtmodul H.1", "wahlpflicht", "Wahlpflichtmodule"),
    ("Modul aus den Fächern des Wahlpflichtbereichs, Fach Rechtswissen- schaften", "wahlpflicht",
     "Wahlpflichtbereich: Rechtswissenschaften"),
    ("Pflichtmodul (FüBa) und Wahlpflichtmodul (Master LSo)", "wahlpflicht", "Wahlpflichtmodule"),
    ("Pflichtmodul", "pflicht", "Pflichtmodule"),
])
def test_area_from_header(kind_text, kind, area):
    assert phil_kv_tabelle.area_from_header({"kind_text": kind_text, "kind": kind}) == area


@pytest.mark.parametrize("meta_term,text,hint,fetched,expected", [
    ("WS 2025/26", "Stand: 01.10.2026", None, None, "WS 2025/26"),
    (None, "Stand: ab WS 2022/23 mit Änderungen von 16.04.2025/01.10.2026", None, None, "WS 2026/27"),
    (None, "Modulkatalog - Stand: Oktober 2026", None, None, "WS 2026/27"),
    (None, "Modulkatalog", "Stand 10/2026", None, "WS 2026/27"),
    (None, "Version vom 1. Juli 2026", None, None, "SS 2026"),
    (None, "Stand: 09.04.2025", None, None, "SS 2025"),
    (None, "ohne Datum", "aktuell", "2026-11-04T21:00:00Z", "WS 2026/27"),
    (None, "ohne Datum", "aktuell", None, None),
])
def test_catalog_term(meta_term, text, hint, fetched, expected):
    assert phil_kv_tabelle.catalog_term(meta_term, text, hint, fetched) == expected


def test_prereqs_longest_title_first():
    raw = [{"title": "Algebra I", "lp": 10, "prereq": ""},
           {"title": "Lineare Algebra I", "lp": 10, "prereq": ""},
           {"title": "Analysis II", "lp": 10, "prereq": "Lineare Algebra I, Analysis I"},
           {"title": "Analysis I", "lp": 10, "prereq": ""}]
    meta = {"university": "luh", "program": "X", "degree": "B.Sc.", "po": "1", "code": "x",
            "source": {"url": "https://x"}}
    cat, _ = phil_kv_tabelle.build_with_prereqs(meta, raw, "WS 2026/27")
    by = {m["title"]: m for m in cat["modules"]}
    assert by["Analysis II"]["prerequisites"] == ["lineare-algebra-1", "analysis-1"]


# ----------------------------------------------------------------------------
# maphy-katalog
# ----------------------------------------------------------------------------

def test_maphy_matches_fixture():
    gen = _gen()
    pages = _load("maphy-pages.json")
    exp = _load("maphy-expected.json")
    for name, (degree, key) in gen.MAPHY_KEYS.items():
        cat, texts = maphy_katalog.parse(pages, gen.maphy_meta(degree, key))
        assert cat == exp[name]


def test_maphy_bachelor_fields():
    gen = _gen()
    cat, texts = maphy_katalog.parse(_load("maphy-pages.json"), gen.maphy_meta(*gen.MAPHY_KEYS["bachelor"]))
    by = {m["id"]: m for m in cat["modules"]}
    assert list(by) == ["rechnen-1", "rechnen-2"]       # Master-Modul gefiltert, Anhang ist kein Modul
    r1, r2 = by["rechnen-1"], by["rechnen-2"]
    assert (r1["lp"], r1["workload_h"], r1["turnus"], r1["exam"], r1["coursework"]) == (10, 300, "WS", "Klausur", "Übung")
    assert r1["title"] == "Rechnen I"                     # englischer Titel in Klammern weg
    assert r1["area"] == "pflichtmodule-bachelor" and r1["kind"] == "pflicht"
    assert r2["exam"] == "Klausur oder mündliche Prüfung" and r2["turnus"] == "SS"
    assert r2["prerequisites"] == ["rechnen-1"]
    assert r2["language"] == "deutsch"                    # aus der Lehrveranstaltung im Anhang
    assert r1["semester"] is None                         # steht in der Pruefungsordnung
    assert texts["rechnen-1"]["goals"].startswith("Sicherer Umgang")
    assert cat["catalog_term"] == "WS 2026/27"


def test_maphy_master_and_page_number_glued():
    gen = _gen()
    cat, texts = maphy_katalog.parse(_load("maphy-pages.json"), gen.maphy_meta(*gen.MAPHY_KEYS["master"]))
    assert [m["id"] for m in cat["modules"]] == ["seminar-master"]
    m = cat["modules"][0]
    assert (m["lp"], m["workload_h"], m["turnus"], m["coursework"]) == (5, 150, "WS+SS", None)
    assert m["exam"] == "Präsentation mit Ausarbeitung (VbP)"


def test_maphy_lp_with_decimal_hours():
    lines = ["Semesterlage       Wintersemester, 1. Semester",
             "Leistungsnachweise          Prüfungsleistung: 1 Klausur/VbP",
             "Leistungspunkte (ECTS)                                 □97.5 h Präsenzstudium",
             "8                                                       142.5 h Selbststudium",
             "                                                        Insgesamt: 240 h"]
    pages = ["2.1 Pflichtmodule\nMathe fuer Beispiele\n" + "\n".join(lines)]
    cat, _ = maphy_katalog.parse(pages, {"university": "luh", "program": "X", "degree": "B.Sc.", "po": "1",
                                         "code": "x", "catalog_term": "WS 2026/27", "source": {"url": "https://x"}})
    m = cat["modules"][0]
    assert (m["title"], m["lp"], m["workload_h"], m["semester"], m["turnus"]) == ("Mathe fuer Beispiele", 8, 240, 1, "WS")


# ----------------------------------------------------------------------------
# OCR-Zeilen
# ----------------------------------------------------------------------------

def test_ocr_lines_match_fixture():
    page = _load("ocr-page.json")
    exp = _load("ocr-expected.json")
    assert ocr_pages.page_text(page) == exp["plain"]
    assert ocr_pages.layout_text(page) == exp["layout"]
    assert "Leibniz" not in exp["plain"]                  # Logo rechts oben weg
    assert "Prüfungsleistungen Klausur (60 Minuten)" in exp["plain"]  # Lesefehler im Feldnamen berichtigt


def test_ocr_layout_feeds_phil_parser():
    page = _load("ocr-page.json")
    text = ocr_pages.layout_text(page)
    cat, _ = phil_kv_tabelle.parse([text], {"university": "luh", "program": "X", "degree": "B.A.", "po": "2016",
                                            "code": "x", "catalog_term": "WS 2026/27",
                                            "source": {"url": "https://x"}})
    m = cat["modules"][0]
    assert (m["title"], m["lp"], m["workload_h"], m["turnus"], m["exam"]) == \
        ("Grundlagen der Beispielkunde", 5, 150, "WS", "Klausur (60 Minuten)")


@pytest.mark.parametrize("raw,fixed", [
    ("Prutungsleistungen: Alternativ", "Prüfungsleistungen: Alternativ"),
    ("Hautigkeit des Angebots", "Häufigkeit des Angebots"),
    ("Lteratur xyz", "Literatur xyz"),
    ("Praktikum Allgemeine Chemie", "Praktikum Allgemeine Chemie"),
    ("Spracherwerb", "Spracherwerb"),
    ("lodultit", "Modultitel"),
    ("Leistungspunkte 5", "Leistungspunkte 5"),
    ("Modultitel9 Modellierung von Prozessen", "Modultitel Modellierung von Prozessen"),
    ("Modultitel& Modellierung", "Modultitel Modellierung"),
    ("Sprache Deutsch", "Sprache Deutsch"),
    ("Moduldauer", "Moduldauer"),
    ("Struktur &t Reaktivität", "Struktur & Reaktivität"),
    ("Experimentalphysik Il", "Experimentalphysik II"),
])
def test_fix_label(raw, fixed):
    assert ocr_pages.fix_label(raw) == fixed


def test_paired_head_lines():
    def o(t, x, y):
        return {"t": t, "c": 1.0, "x": x, "y": y, "bw": 0.15, "bh": 0.012}
    page = {"obs": [o("Leistungspunkte", 0.12, 0.2), o("Häufigkeit des Angebots", 0.4, 0.2), o("Sprache", 0.7, 0.2),
                    o("5 LP", 0.12, 0.22), o("Jedes Wintersemester", 0.4, 0.22),
                    o("Kompetenzbereich", 0.12, 0.24), o("Moduldauer", 0.7, 0.24),
                    o("1 Semester", 0.7, 0.26)]}
    assert ocr_pages.paired_lines(page) == ["Leistungspunkte: 5 LP", "Häufigkeit des Angebots: Jedes Wintersemester",
                                            "Sprache:", "Kompetenzbereich:", "Moduldauer: 1 Semester"]


def test_template_of():
    assert ocr_pages.template_of(["Anbieter x\nAnbieter y\nAnbieter z"]) == "phil"
    assert ocr_pages.template_of(["Modultitel a Kennnummer"] * 2) == "luh"
    assert ocr_pages.template_of(["Anbieter x\nAnbieter y\nAnbieter z\nModultitel\nModultitel\nModultitel"]) == "mixed"


def test_merge_catalogs():
    gen = _gen()
    pages = _load("maphy-pages.json")
    a = maphy_katalog.parse(pages, gen.maphy_meta(*gen.MAPHY_KEYS["bachelor"]))
    b = maphy_katalog.parse(pages, gen.maphy_meta(*gen.MAPHY_KEYS["master"]))
    cat, texts = ocr_pages.merge_catalogs(a, b)
    assert [m["id"] for m in cat["modules"]] == ["rechnen-1", "rechnen-2", "seminar-master"]
    assert {x["id"] for x in cat["areas"]} == {"pflichtmodule-bachelor", "module-master"}
    assert validate(cat) == []
    same, _ = ocr_pages.merge_catalogs(a, a)
    assert len(same["modules"]) == 2
    assert set(texts) == {"rechnen-1", "rechnen-2", "seminar-master"}


def test_swift_source_contract():
    """Das Swift-Skript nutzt Vision mit Deutsch, genau und ohne Netz (nur lokale Rahmenwerke)"""
    src = ocr_pages.SWIFT_SOURCE
    assert "VNRecognizeTextRequest" in src and '"de-DE"' in src and ".accurate" in src
    assert "URLSession" not in src and "http" not in src
