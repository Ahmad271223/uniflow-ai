"""Wahlbereiche und eigene Lage im Studienverlauf (Inhaber 05.11.2026, docs/STUDIENVERLAUF-2026-11-04.md, Abschnitte
"Wahlbereiche" und "Eigene Lage"): Plaetze fuer offene Wahl, Schwerpunkt-Gruppen, eigene Eintraege mit QIS-Stand,
Verschieben/Vorziehen (Bestandenes bleibt), Turnus- und Voraussetzungshinweise, LP-Summen, Nachholen nach Fehlversuch,
"Nicht belegen", Pruefungsanmeldung folgt der eigenen Lage, Leser fuer die Bereichsregeln (modkat). Erfundene Daten aus
fixtures/study-plan-engine/engine.json."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-plan-engine" / "engine.json"


def _fx():
    return json.loads(FX.read_text(encoding="utf-8"))


def _plan(catalog_code, grades, settings, today="2026-11-04"):
    from app import study_plan
    fx = _fx()
    cat = fx["catalogs"][catalog_code]
    return study_plan.build_plan(cat, grades, settings, today)


def _g(text, semester, status, note="2,0", versuch="", credits=""):
    return {"text": text, "semester": semester, "status": status, "note": note, "versuch": versuch, "pruefungsnr": "",
            "credits": credits, "datum": "", "abschluss": "Technische Informatik (PO-Version 2017)"}


def _where(plan):
    return {m["id"]: (s["term"], m) for s in plan["semesters"] for m in s["modules"]}


def test_placement_moves_pulls_forward_and_sums_lp():
    base = _plan("TIBSc22", [], {"start_term": "WiSe 26/27"})
    moved = _plan("TIBSc22", [], {"start_term": "WiSe 26/27", "placements": {"rechnernetze": "WiSe 26/27",
                                                                              "mathematik-3": "SoSe 29"}})
    assert _where(base)["rechnernetze"][0] == "SoSe 28"
    term, m = _where(moved)["rechnernetze"]
    assert term == "WiSe 26/27" and m["placed"] is True
    assert "Laut Katalog nur im Sommersemester angeboten" in m["hints"]
    assert _where(moved)["mathematik-3"][0] == "SoSe 29", "auch nach der Regelstudienzeit"
    for s in moved["semesters"]:
        assert s["lp"] == sum(x["lp"] for x in s["modules"])
    first = next(s for s in moved["semesters"] if s["term"] == "WiSe 26/27")
    assert first["lp"] == next(s for s in base["semesters"] if s["term"] == "WiSe 26/27")["lp"] + 5
    assert moved["placements"] == {"mathematik-3": "SoSe 29", "rechnernetze": "WiSe 26/27"}


def test_passed_module_stays_locked_and_failed_follows_placement():
    grades = [_g("Programmieren I", "WiSe 25/26", "bestanden"),
              _g("Mathematik I", "WiSe 25/26", "nicht bestanden", "5,0", "1")]
    p = _plan("TIBSc22", grades, {"placements": {"programmieren-1": "SoSe 27", "mathematik-1": "WiSe 27/28"}})
    w = _where(p)
    assert w["programmieren-1"][0] == "WiSe 25/26" and w["programmieren-1"][1]["placed"] is False
    assert w["mathematik-1"][0] == "WiSe 27/28" and w["mathematik-1"][1]["status"] == "nicht_bestanden"
    assert "programmieren-1" not in p["placements"]
    # vor dem naechsten moeglichen Versuch: Lage gilt nicht, naechstes WS
    early = _plan("TIBSc22", grades, {"placements": {"mathematik-1": "WiSe 25/26"}}, today="2026-05-01")
    assert _where(early)["mathematik-1"][0] == "WiSe 26/27"


def test_prerequisite_hint_and_placed_modules_are_not_moved():
    p = _plan("TIBSc22", [], {"start_term": "WiSe 26/27", "placements": {"programmieren-2": "WiSe 26/27"}})
    term, m = _where(p)["programmieren-2"]
    assert term == "WiSe 26/27"
    assert "Voraussetzung Programmieren I liegt nicht davor" in m["hints"]


def test_excluded_and_custom_entries():
    grades = [_g("Spanisch A1", "SoSe 26", "bestanden", "1,3", credits="4")]
    p = _plan("ETBSc25", grades, {"excluded": ["stochastik"], "custom": [{"title": "Spanisch A1", "lp": 4,
                                                                         "area": "studium-generale"}]})
    assert "stochastik" not in _where(p)
    assert [e["id"] for e in p["excluded"]] == ["stochastik"]
    term, e = _where(p)["eigen-1"]
    assert (term, e["status"], e["grade"], e["custom"]) == ("SoSe 26", "bestanden", "1,3", True)
    sg = next(a for a in p["areas"] if a["id"] == "studium-generale")
    assert (sg["lp_done"], sg["lp_open"], sg["slots"]) == (4, 0, 0)


def test_slots_track_and_area_types():
    p = _plan("ETBSc25", [], {})
    slots = [x for s in p["semesters"] for x in s["slots"]]
    assert [(x["kind"], x["title"], x["lp"]) for x in slots] == [("area", "Seminare", 5), ("area", "Studium Generale", 4),
                                                               ("track", "Schwerpunkt wählen", 15)]
    types = {a["id"]: a["type"] for a in p["areas"]}
    assert types["seminare"] == "seminar" and types["studium-generale"] == "studium_generale"
    assert types["schwerpunkt-robotik"] == "schwerpunkt"
    assert p["groups"][0]["options"] == ["allgemeine-et", "schwerpunkt-robotik", "schwerpunkt-daten"]
    chosen = _plan("ETBSc25", [], {"tracks": {"schwerpunkt": "schwerpunkt-daten"}})
    assert all(x["kind"] != "track" for s in chosen["semesters"] for x in s["slots"])
    assert "robotik-pflicht" not in _where(chosen), "Pflichtmodul eines nicht gewaehlten Schwerpunkts fehlt"


def test_exam_registration_follows_placement():
    from app import study_plan
    fx = _fx()
    cat = fx["catalogs"]["TIBSc22"]
    full = study_plan.compute(cat, [], {"start_term": "WiSe 25/26", "placements": {"rechnernetze": "WiSe 26/27"}}, "2026-11-04")
    assert study_plan.term_name(full["state"]["rechnernetze"]["term"]) == "WiSe 26/27"


def test_modkat_area_extras_reads_rules_and_tables():
    from app import study_catalog as sc
    page_toc = ("1. Kompetenzbereiche . . . . . . . . 2\n1.1. Schwerpunkt Robotik . . . . . . . 2\n"
                "1.2. Allgemeine Technik . . . . . . 3\n2. Details der Semesterangebote . . . . 4\nRobotik I . . . . . . 4\n")
    p2 = ("1.1. Schwerpunkt Robotik\nInformation zum Kompetenzbereich: 0 - 25 LP\nDer Schwerpunkt ist absolviert, wenn "
          "mindestens vier Module erbracht wurden.\nModul LP SWS PL SL Frequenz\nRobotik I 5 2V + 2Ü K 0 jw\n"
          "Regelungs-\ntechnik 5 2V K 0 jw\n")
    p3 = "1.2. Allgemeine Technik\nInformation zum Kompetenzbereich: 0 - 25 LP\nModul Modul LP SWS PL\nRobotik I Robotik I 5 2V\n"
    cat = {"areas": [{"id": "schwerpunkt-robotik", "name": "Schwerpunkt Robotik"}, {"id": "allgemeine-technik", "name": "Allgemeine Technik"}],
           "modules": [{"id": "robotik-1", "title": "Robotik I"}, {"id": "regelungstechnik", "title": "Regelungstechnik"}]}
    ex = sc.modkat_area_extras([page_toc, p2, p3, "Robotik I\n"], cat)
    assert ex["schwerpunkt-robotik"]["modules"] == ["robotik-1", "regelungstechnik"]
    assert ex["schwerpunkt-robotik"]["modules_required"] == 4
    assert ex["schwerpunkt-robotik"]["rule"].startswith("Der Schwerpunkt ist absolviert")
    assert ex["allgemeine-technik"]["modules"] == ["robotik-1"] and ex["allgemeine-technik"]["rule"] is None
