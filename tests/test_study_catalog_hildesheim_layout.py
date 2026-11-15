"""Tabellen-Leser der Universitaet Hildesheim (app/study_catalog_hildesheim_layout.py): Informatik im Lehramt 2026
("INF-B1: „Titel“", LP in der letzten Tabellenspalte, Pflicht/Wahlpflicht aus Anlage 1) und Barrierefreie Kommunikation
("Kennnummer | Workload | Credits"). Erfundene Seitentexte im Aufbau der Ordnungen
(tools/gen-study-catalog-hildesheim-layout-fixture.py); der Swift-Kern prueft dieselben Dateien
(StudyCatalogHildesheimLayoutParserTests). Kein echtes Netz, keine echte Ordnung."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

from app import study_catalog as sc
from app import study_catalog_hildesheim_layout as hl
from app.catalog_formats import get_parser
from app.catalog_formats import hildesheim as H

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-catalog-hildesheim-layout"
PARSERS = {hl.KUERZEL_FORMAT: hl.parse_kuerzel_modultabelle, hl.KENNNUMMER_FORMAT: hl.parse_kennnummer_tabelle}


def _j(name):
    return json.loads((FX / name).read_text(encoding="utf-8"))


def _mods(case):
    return {m["code"]: m for m in case["catalog"]["modules"]}


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-study-catalog-hildesheim-layout-fixture.py", "--check"], cwd=ROOT,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.mark.parametrize("name", ["kuerzel-fach", "kuerzel-master", "kennnummer"])
def test_case_matches_fixture_and_validates(name):
    c = _j(f"{name}.json")
    pages = c["pages"]
    assert {"kuerzel": hl.is_kuerzel_modultabelle(pages), "kennnummer": hl.is_kennnummer_tabelle(pages)} == c["detect"]
    assert c["detect"] == {"kuerzel": c["format"] == hl.KUERZEL_FORMAT, "kennnummer": c["format"] == hl.KENNNUMMER_FORMAT}
    catalog, texts = PARSERS[c["format"]](pages, c["meta"])
    assert sc.validate(catalog) == []
    assert sc.dumps(catalog) == c["dumps"] and sc.dumps(texts) == c["texts_dumps"]
    # Form wie parse_luh_modkat: dieselben Schluessel, Texte nur lokal
    assert list(catalog) == ["v", "university", "program", "degree", "po", "catalog_term", "code", "regular_semesters",
                             "total_lp", "source", "areas", "modules"]
    assert all(list(m) == ["id", "title", "code", "area", "kind", "lp", "semester", "turnus", "exam", "coursework",
                           "prerequisites", "language", "workload_h", "source_page"] for m in catalog["modules"])
    assert set(texts) == {m["id"] for m in catalog["modules"]}
    assert all(set(t) == {"content", "goals", "literature"} for t in texts.values())
    assert all(len(m[k] or "") <= hl.MAX_FACT for m in catalog["modules"] for k in ("exam", "coursework"))
    # der andere Leser findet in diesem Format nichts
    other = next(p for f, p in PARSERS.items() if f != c["format"])
    assert other(pages, c["meta"])[0]["modules"] == []


def test_kuerzel_fach_required_only_if_required_in_every_variant():
    c = _j("kuerzel-fach.json")
    m = _mods(c)
    assert list(m) == ["GAR-B1", "GAR-B2", "GAR-A1", "GAR-A2", "GAR-V1"], "GAR-B9 steht nur im Modellstudienplan"
    # Anlage 1: Variante 1 Pflicht B1, B2, A1, A2 (Liste ueber zwei Zeilen); Variante 2 Pflicht B1, B2, A2, V1
    assert {k: v["kind"] for k, v in m.items()} == {"GAR-B1": "pflicht", "GAR-B2": "pflicht", "GAR-A1": "wahlpflicht",
                                                    "GAR-A2": "pflicht", "GAR-V1": "wahlpflicht"}
    assert [(a["id"], a["kind"]) for a in c["catalog"]["areas"]] == [("pflichtmodule", "pflicht"), ("wahlpflichtmodule", "wahlpflicht")]
    assert all(v["area"] == v["kind"] + "module" for v in m.values())
    # LP: letzte Spalte, Teilmodule summiert (auch ueber die Seitengrenze), Komma
    assert [v["lp"] for v in m.values()] == [6, 6, 9, 3, 4.5]
    assert [v["workload_h"] for v in m.values()] == [150, 150, 225, 75, 135]
    assert [v["semester"] for v in m.values()] == [1, 1, 4, 5, 3]
    assert [v["turnus"] for v in m.values()] == ["WS", "WS", "SS", "WS", "WS+SS"]
    assert m["GAR-B1"]["title"] == "Einführung in die Gartenkunde" and m["GAR-B1"]["source_page"] == 3
    assert m["GAR-B1"]["exam"] == "Klausur oder mündliche Prüfung", "nur die Spalte Prüfungsformen"
    assert m["GAR-B2"]["exam"] == "Projekt mit Bericht und mündliche Prüfung", "Fortsetzung auf der Folgeseite gehoert nicht dazu"
    assert m["GAR-A1"]["exam"] == "TM1: Mündliche Prüfung; TM2: Hausarbeit"
    assert m["GAR-A1"]["coursework"] == "TM1: Gießprotokolle; TM2: Referat mit Handout"
    assert m["GAR-A2"]["exam"] == "Vortrag und Ausarbeitung oder Portfolio" and m["GAR-A2"]["coursework"] == "ggfs. Hausübungen"
    assert m["GAR-B1"]["coursework"] is None, "Verweis auf ein anderes Handbuch: nichts geraten"
    t = c["module_texts"]
    assert t[m["GAR-B1"]["id"]] == {"content": None, "goals": None, "literature": None}
    assert t[m["GAR-A1"]["id"]]["content"].startswith("Das Modul führt in Konzepte der Gartendidaktik ein.")
    assert "sowie deren Bedeutung." in t[m["GAR-A1"]["id"]]["content"]


def test_kuerzel_master_status_total_line_and_title_suffix():
    c = _j("kuerzel-master.json")
    m = _mods(c)
    assert list(m) == ["GAR-M1", "LPS_Gar1", "LPS_Gar3"] and c["catalog"]["areas"] == []
    assert [v["kind"] for v in m.values()] == ["pflicht", "pflicht", "wahlpflicht"], "Status Modul; Mastermodul bleibt Wahlpflicht"
    assert [v["lp"] for v in m.values()] == [7, 13, 24], "Summe der Teilmodule bzw. Zeile mit den LP des ganzen Moduls"
    assert [v["workload_h"] for v in m.values()] == [175, None, 720]
    assert m["LPS_Gar3"]["title"] == "Mastermodul" and m["LPS_Gar3"]["semester"] == 4 and m["LPS_Gar3"]["turnus"] == "WS+SS"
    assert m["LPS_Gar1"]["exam"] == "TM6: Schriftliche Hausarbeit" and m["LPS_Gar1"]["turnus"] == "WS"
    assert m["LPS_Gar1"]["coursework"] is None and m["LPS_Gar3"]["coursework"] is None, "reiner Verweis auf die RStO"
    assert m["GAR-M1"]["exam"] == "TM1: Mündliche Prüfung oder Klausur; TM2: Hausarbeit"


def test_kennnummer_header_values_and_numbered_rows():
    c = _j("kennnummer.json")
    m = _mods(c)
    assert list(m) == ["TG 1", "TG 2", "TG 5", "TG 7", "TG 10", "TG 11"]
    assert [v["title"] for v in m.values()] == ["Grundlagen der Teichgestaltung", "Uferpflanzen", "Vertiefungsbereich Wasserbau I: Theorie",
                                                "Fachsprache 2 (Wahlpflichtmodul)", "Profilmodul: Forschung oder Praxis", "Abschluss"]
    assert [v["lp"] for v in m.values()] == [13, 11, 10, 13, 10, 20]
    assert [v["workload_h"] for v in m.values()] == [390, 330, 300, 390, 300, 600]
    assert [v["semester"] for v in m.values()] == [1, 1, 2, 3, 4, 4]
    assert [v["turnus"] for v in m.values()] == ["WS+SS", "WS", "SS", "WS", "unbekannt", "unbekannt"], "umbrochene Häufigkeit, auch zentriert"
    assert [v["kind"] for v in m.values()] == ["pflicht", "pflicht", "pflicht", "wahlpflicht", "pflicht", "abschluss"]
    # Titelzeile "Modul TG 5 – Titel" ueber zwei Zeilen; auf der Folgeseite stehen beide Zeilen noch einmal
    assert m["TG 5"]["exam"] == "Hausarbeit oder Projektarbeit (z.B. Poster mit Präsentation)"
    assert c["module_texts"][m["TG 5"]["id"]]["content"] == "Theorie\ndes Wasserbaus an Beispielen.", "nur der Kolumnentitel faellt weg"
    assert m["TG 1"]["exam"] == "Klausur"
    assert m["TG 1"]["coursework"] == "1.1. oder 1.3: Bestehen der Klausur; 1.2. Aktive, regelmäßige Teilnahme"
    assert m["TG 2"]["exam"] == "2.1: Hausarbeit oder Projektarbeit (z.B. Poster mit Präsentation) im jeweils anderen Teilmodul"
    assert m["TG 2"]["coursework"].startswith("2.2: Aktive, regelmäßige Teilnahme; Bearbeitung von Aufgaben")
    assert m["TG 10"]["exam"] is None and m["TG 10"]["coursework"].endswith("…") and len(m["TG 10"]["coursework"]) <= 200
    assert m["TG 11"]["coursework"] is None and m["TG 11"]["exam"].startswith("Masterarbeit im Umfang von ca. 60 Seiten (inkl. Leerzeichen)")
    t = c["module_texts"][m["TG 1"]["id"]]
    assert t["goals"].startswith("Die Studierenden kennen") and t["content"].startswith("Das Modul dient der Einführung")
    assert "Grundlagen der Teichgestaltung" not in t["content"], "Kolumnentitel der Folgeseite"


def test_values_and_detection():
    w = _j("werte.json")
    for c in w["lines"]:
        assert hl.layout_lines([c["text"]])[0] == c["lines"] and sc.dumps(c["lines"]) == c["dumps"], c["text"]
    for c in w["join"]:
        assert hl._join(c["parts"]) == c["text"], c["parts"]
    for c in w["season"]:
        assert hl._season(c["text"]) == c["turnus"], c["text"]
    for c in w["facts"]:
        assert hl._facts(c["items"], c["references"]) == c["text"], c["items"]
    for c in w["detect"]:
        got = {"kuerzel": hl.is_kuerzel_modultabelle(c["pages"]), "kennnummer": hl.is_kennnummer_tabelle(c["pages"])}
        assert got == c["detect"], c["name"]


@pytest.mark.parametrize("name", [hl.KUERZEL_FORMAT, hl.KENNNUMMER_FORMAT])
def test_formats_registered_for_the_seed_and_read_in_layout_mode(name):
    assert get_parser(name) is PARSERS[name]
    assert name in H.LAYOUT_FORMATS, "Seitentexte im Layout-Modus (Spalten bleiben erhalten)"


def test_older_readers_find_nothing_in_these_formats():
    """Deshalb die eigenen Leser: die drei bisherigen finden hier kein einziges vollstaendiges Modul"""
    for name in ("kuerzel-fach", "kennnummer"):
        c = _j(f"{name}.json")
        for parse in (H.parse_modulbeschreibung, H.parse_modultabelle, H.parse_it):
            cat, _ = parse(c["pages"], c["meta"])
            assert sum(1 for m in cat["modules"] if m["lp"]) < len(c["catalog"]["modules"]), (name, parse.__name__)
