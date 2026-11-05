"""Persoenlicher Studienverlauf (app/study_plan.py, 04.11.2026, docs/STUDIENVERLAUF-2026-11-04.md): Zuordnung der
QIS-Zeilen, Status, Semesterlage nach Turnus, Verschieben nach Fehlversuch mit abhaengigen Modulen, LP-Ausgleich,
Hinweise, Katalogwahl und die Endpunkte /api/study-plan. Fixture: tools/gen-study-plan-fixture.py (der Swift-Kern
rechnet dieselben Faelle in StudyPlanEngineTests). Nur erfundene Daten."""
import json
import subprocess
import sys
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-plan-engine"


def _engine():
    return json.loads((FX / "engine.json").read_text(encoding="utf-8"))


def _case(name):
    fx = _engine()
    c = next(c for c in fx["cases"] if c["name"] == name)
    from app import study_plan
    return study_plan.build_plan(fx["catalog"], c["grades"], c["settings"], c["today"])


def _mods(plan):
    """{Modul-id: (Semester, Modul)}"""
    return {m["id"]: (s["term"], m) for s in plan["semesters"] for m in s["modules"]}


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-study-plan-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_all_cases_match_fixture():
    from app import study_plan
    fx = _engine()
    assert len(fx["cases"]) >= 8
    assert len(fx["catalog"]["modules"]) >= 25
    for c in fx["cases"]:
        cat = fx["catalogs"][c["catalog_code"]] if c.get("catalog_code") else fx["catalog"]
        assert study_plan.build_plan(cat, c["grades"], c["settings"], c["today"]) == c["expected"], c["name"]


def test_chosen_electives_fill_plan_slots():
    """Katalog mit Studienverlaufsplan: gewaehlte Wahlpflicht ohne Fachsemester landet im Semester ihres Platzes"""
    from app import study_plan
    fx = _engine()
    c = next(c for c in fx["cases"] if c["name"] == "plaetze_laut_verlaufsplan")
    plan = study_plan.build_plan(fx["catalogs"]["TIBSc25"], c["grades"], c["settings"], c["today"])
    where = {m["id"]: s["fachsemester"] for s in plan["semesters"] for m in s["modules"]}
    assert where["eingebettete-systeme"] == 4 and where["datenbanken"] == 5 and where["ki"] == 5
    assert where["robotik"] == 7, "Platz im 6. (SoSe), Robotik nur im WS"


def _full_case(name):
    """Fall auf dem Katalog mit vollen Bereichen (TIBSc26): Plan und {Bereich: [Fachsemester der Plaetze]}"""
    from app import study_plan
    fx = _engine()
    c = next(c for c in fx["cases"] if c["name"] == name)
    plan = study_plan.build_plan(fx["catalogs"]["TIBSc26"], c["grades"], c["settings"], c["today"])
    slots: dict[str, list[int]] = {}
    for s in plan["semesters"]:
        for sl in s["slots"]:
            slots.setdefault(sl["area"], []).append(s["fachsemester"])
    return plan, slots, {a["id"]: a for a in plan["areas"]}


def test_full_area_has_no_open_slot():
    """Fund 05.11.2026 (INFBSc22, Web und iPad): "Proseminar" blieb stehen, obwohl Akademisches Arbeiten mit
    "noch 0 von 5 LP offen" voll war. Kein Platz eines Bereichs, dessen Bedarf durch Module gedeckt ist"""
    plan, slots, areas = _full_case("bereiche_offen_verlaufsplan")
    assert slots == {"akademisches-arbeiten": [4], "vertiefung": [4, 5, 6, 6], "seminare": [5], "labore": [5, 5]}
    for name in ("proseminar_bereich_voll_fachsemester", "proseminar_bereich_voll_eigene_lage"):
        plan, slots, areas = _full_case(name)
        assert areas["akademisches-arbeiten"]["lp_open"] == 0 and areas["akademisches-arbeiten"]["slots"] == 0, name
        assert "akademisches-arbeiten" not in slots, name
        assert slots["vertiefung"] == [4, 5, 6, 6], name
    # Bestand und Plaetze passen in jedem Fall zusammen: ein Bereich mit Bedarf und Platz hat noch etwas offen
    fx = _engine()
    for c in fx["cases"]:
        if c.get("catalog_code") != "TIBSc26":
            continue
        plan, slots, areas = _full_case(c["name"])
        for aid in slots:
            a = areas[aid]
            if a["target"] is not None and a["lp_open"] == 0:
                assert a["modules_required"] is not None and a["count"] < a["modules_required"], (c["name"], aid)


def test_lp_only_area_full_and_partial():
    """Nur LP (Vertiefung 10 bis 20 LP): gedeckt -> keine Plaetze mehr, die Wahlmodule gehen an die Spanne der Praxis;
    teilweise -> das Modul belegt einen Platz, der zweite bleibt mit den restlichen 5 LP"""
    plan, slots, areas = _full_case("lp_bereich_voll")
    assert "vertiefung" not in slots and slots["praxis"] == [6, 6]
    assert areas["vertiefung"]["lp_open"] == 0
    plan, slots, areas = _full_case("lp_bereich_teilweise")
    assert slots["vertiefung"] == [5, 6, 6] and "praxis" not in slots
    assert areas["vertiefung"]["lp_open"] == 5 and areas["vertiefung"]["chosen"] == ["vertiefung-c"]
    assert areas["praxis"]["chosen"] == [], "Modul in zwei Bereichen zaehlt genau einmal"


def test_count_only_area_full_and_lp_with_count():
    """Nur Zahl der Module (Seminare, 1): eigener Eintrag deckt -> kein Platz; Labore (6 LP und 2 Module): 6 LP gedeckt,
    aber erst 1 Modul -> ein Platz bleibt"""
    plan, slots, areas = _full_case("zahl_bereich_voll")
    assert "seminare" not in slots and areas["seminare"]["count"] == 1
    assert slots["labore"] == [5] and areas["labore"]["lp_open"] == 0 and areas["labore"]["count"] == 1


def test_area_slots_cover_lp_and_count():
    """Bereich ohne Verlaufsplan mit LP und Zahl der Module: so viele Plaetze, dass beides reicht"""
    from app import study_plan
    fx = _engine()
    cat = json.loads(json.dumps(fx["catalogs"]["TIBSc26"]))
    cat.pop("plan_slots")
    plan = study_plan.build_plan(cat, [], {"start_term": "WiSe 26/27", "electives": ["labor-a"]}, "2026-11-04")
    labor = [sl for s in plan["semesters"] for sl in s["slots"] if sl["area"] == "labore"]
    assert len(labor) == 1 and labor[0]["lp"] == 3, "6 LP gedeckt, 1 von 2 Modulen: ein Platz in Modulgroesse (Median 3 LP)"


def test_terms_and_name_keys():
    from app import study_plan as sp
    assert sp.term_name(sp.parse_term("Wintersemester 2025/2026")) == "WiSe 25/26"
    assert sp.term_name(sp.parse_term("SS 2027")) == "SoSe 27"
    assert sp.parse_term("Herbst 25") is None
    assert sp.term_name(sp.current_term("2026-03-31")) == "WiSe 25/26"
    assert sp.term_name(sp.current_term("2026-04-01")) == "SoSe 26"
    assert sp.term_name(sp.current_term("2026-10-01")) == "WiSe 26/27"
    assert sp.name_key("Übung zu Programmieren I") == sp.name_key("Programmieren 1") == "programmieren 1"
    assert sp.name_key("Grundlagen digitaler Systeme, Tranche A") == "grundlagen digitaler systeme"
    assert sp.name_key("Datenstrukturen & Algorithmen") == sp.name_key("Datenstrukturen und Algorithmen")
    assert sp.name_key("V") == "v", "ein einzelnes Wort bleibt (keine roemische Zahl)"
    fx = _engine()
    for n in fx["name_keys"]:
        assert sp.name_key(n["text"]) == n["key"]


def test_on_track_and_registered():
    p = _case("im_plan")
    m = _mods(p)
    assert p["current_term"] == "WiSe 26/27" and p["current_fachsemester"] == 5
    assert m["programmieren-1"] == ("WiSe 24/25", m["programmieren-1"][1]) and m["programmieren-1"][1]["status"] == "bestanden"
    assert m["seminar"][1]["status"] == "angemeldet" and m["seminar"][0] == "WiSe 26/27"
    assert m["bachelorarbeit"][0] == "SoSe 27" and m["bachelorarbeit"][1]["status"] == "geplant"
    assert p["lp_done"] == p["lp_expected"] == 111 and p["lp_total"] == 180
    assert p["notes"] == []
    assert p["disclaimer"] == "Verbindlich ist die Prüfungsordnung deiner Hochschule."


def test_failed_in_winter_moves_to_next_winter():
    m = _mods(_case("nicht_bestanden_ws"))
    term, mod = m["theoretische-informatik"]
    assert term == "WiSe 26/27" and mod["status"] == "nicht_bestanden" and mod["attempt"] == 1
    assert mod["moved_from"] == "WiSe 25/26"


def test_failed_module_takes_dependents_along():
    m = _mods(_case("nicht_bestanden_abhaengige"))
    assert m["programmieren-1"][0] == "WiSe 26/27"
    assert m["programmieren-2"][0] == "SoSe 27" and m["programmieren-2"][1]["reason"] == "Voraussetzung Programmieren I zuerst"
    assert m["datenstrukturen"][0] == "SoSe 27"
    assert m["betriebssysteme"][0] == "WiSe 27/28"
    assert m["bachelorarbeit"][0] == "WiSe 28/29"
    assert m["mathematik-2"][1]["status"] == "angemeldet" and m["mathematik-2"][0] == "SoSe 26"
    # unabhaengige Module bleiben im Verlaufsplan
    assert m["stochastik"][0] == "SoSe 27" and m["stochastik"][1]["moved_from"] is None


def test_third_attempt_final_and_missing_prerequisite():
    p = _case("dritter_versuch")
    m = _mods(p)
    assert m["mathematik-1"][1]["status"] == "angemeldet" and m["mathematik-1"][1]["attempt"] == 3
    assert m["mathematik-1"][1]["last_attempt"] is True
    kinds = [n["kind"] for n in p["notes"]]
    assert kinds[0] == "endgueltig" and "letzter_versuch" in kinds and "voraussetzung" in kinds and kinds[-1] == "rueckstand"
    assert "Mathematik I: Letzter Versuch – sprich mit der Studienberatung." in [n["text"] for n in p["notes"]]
    assert "Mathematik II: Voraussetzung Mathematik I ist noch nicht bestanden." in [n["text"] for n in p["notes"]]


def test_start_in_summer_shifts_winter_modules():
    p = _case("beginn_sose")
    m = _mods(p)
    assert p["start_term"] == "SoSe 25" and p["semesters"][0]["fachsemester"] == 1
    assert m["programmieren-1"][0] == "WiSe 25/26"
    assert m["mathematik-3"][1]["reason"] == "Wird nur im Wintersemester angeboten"
    assert m["schluesselkompetenzen"][1]["status"] == "bestanden", "Wahlmodul aus QIS kommt von selbst in den Plan"


def test_electives_and_balancing():
    p = _case("wahlpflicht_gewaehlt")
    m = _mods(p)
    assert m["robotik"][0] == "WiSe 27/28" and m["robotik"][1]["reason"] == "Mehr als 36 LP im Semester"
    assert m["ki"][0] == "SoSe 27", "ohne Fachsemester: erstes passendes Semester mit Platz bis 30 LP"
    assert m["eingebettete-systeme"][1]["status"] == "bestanden"
    cur = next(s for s in p["semesters"] if s["current"])
    assert cur["lp"] <= 36
    chosen = {e["id"] for e in p["electives"] if e["chosen"]}
    assert chosen == {"datenbanken", "bildverarbeitung", "robotik", "ki"}


def test_name_variants_and_unmatched():
    p = _case("namensvarianten")
    m = _mods(p)
    for mid in ("programmieren-1", "mathematik-1", "digitale-systeme", "et-1", "programmieren-2", "datenstrukturen",
                "rechnerstrukturen", "signale-systeme"):
        assert m[mid][1]["status"] == "bestanden", mid
    assert m["mathematik-2"][1]["status"] == "nicht_bestanden"
    assert m["theoretische-informatik"][1]["status"] == "offen", "abgemeldet zaehlt nicht"
    assert p["unmatched"] == ["Englisch für Ingenieure"]


def test_pick_catalog():
    from app import study_plan as sp
    fx = _engine()
    for p in fx["picks"]:
        cat, reason = sp.pick_catalog([fx["catalogs"][c] for c in p["catalogs"]], p["settings"], p["grades"])
        assert (cat["code"] if cat else None, reason) == (p["code"], p["reason"])


def test_endpoints_match_fixture(app, monkeypatch, tmp_path):
    """Dieselbe Folge wie im Generator, hier gegen die laufende App (eigene Datenbank)"""
    from datetime import date
    from app import db, study
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 4))
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "studienverlauf.db")
    db.init_db()
    fx = json.loads((FX / "endpoints.json").read_text(encoding="utf-8"))
    with db.cursor() as conn:
        for s in fx["seed"]:
            conn.execute(s["sql"], s["params"])
    for s in fx["steps"]:
        if "sql" in s:
            with db.cursor() as conn:
                for q in s["sql"]:
                    conn.execute(q["sql"], q["params"])
            continue
        body = json.dumps(s["body"]) if "body" in s else None
        status, _, raw = asgi_call(app, s["method"], s["path"], body=body)
        assert status == s["status"], (s["path"], raw)
        got = json.loads(raw)
        if isinstance(got, dict):
            got = {k: v for k, v in got.items() if k not in ("sync_version", "sync_updated_at", "sync_device")}
        assert got == s["response"], s["path"]
    with db.cursor() as conn:
        rows = [dict(r) for r in conn.execute("SELECT key, value FROM settings WHERE key='study_plan'")]
    assert rows == fx["tables_after"]["settings"]


def test_without_catalog_and_memory_source(app, monkeypatch, tmp_path):
    from app import db, study_plan
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "leer.db")
    db.init_db()
    fx = _engine()
    with db.cursor() as conn:
        out = study_plan.plan_response(conn, "2026-11-04", study_plan.MemoryCatalogSource([]))
        assert out["available"] is False and out["reason"] == "no_catalog"
        assert out["message"] == "Für deinen Studiengang gibt es noch keinen Katalog."
        assert out["disclaimer"] == study_plan.DISCLAIMER
        src = study_plan.MemoryCatalogSource([fx["catalog"]], {study_plan.catalog_key(fx["catalog"]): {
            "mathematik-1": {"content": "Analysis", "goals": None, "literature": None}}})
        assert study_plan.plan_response(conn, "2026-11-04", src)["available"] is True
        detail = study_plan.module_response(conn, "mathematik-1", "2026-11-04", src)
        assert detail["texts"]["content"] == "Analysis" and detail["source"]["page"] == 14
