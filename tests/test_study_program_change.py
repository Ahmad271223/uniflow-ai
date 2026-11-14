"""Wechsel des Studiengangs (14.11.2026, erstes echtes Hildesheim-Konto: seit zwei Monaten Sozialpaedagogik, vorher
Erziehungswissenschaft; die App nahm weiter Erziehungswissenschaft). Gleiche Faelle in StudyProgramChangeTests.swift.
LSF-Bezeichnungen im Aufbau der echten Seite (Abschluss/Studiengang/PO-Version), Leistungen erfunden."""
import pytest

from app import study_catalog as sc
from app import study_plan as sp


@pytest.fixture
def fresh(app, tmp_path, monkeypatch):
    """eigene Datenbank: Katalog-Stand und Grundstock-Kataloge bleiben nicht fuer andere Tests liegen"""
    from app import db
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "programm.db")
    db.init_db()
    yield

EW = "Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2023"
SOP = "Abschluss: [82] Bachelor Studiengang: [161] B.A. Sozialpädagogik PO-Version: 2025"


def _g(label, text="Einführung", status="bestanden"):
    return {"abschluss": label, "text": text, "note": "2,0", "status": status, "semester": "WiSe 24/25"}


def test_newest_program_wins_over_the_one_with_most_grades():
    grades = [_g(EW, f"Modul {i}") for i in range(5)] + [_g(SOP, "Grundlagen der Sozialpädagogik")]
    assert sp.abschluss_of(grades) == SOP
    assert sp.current_label(["Technische Informatik (PO-Version 2017)", "Technische Informatik (PO-Version 2017)", "Technische Informatik (PO-Version 2022)"]) \
        == "Technische Informatik (PO-Version 2022)"
    assert sp.current_label(["A", "B", "B"]) == "B", "ohne PO-Version: der haeufigste"
    progs = sp.programs_of(grades, "hildesheim")
    assert [p["program"] for p in progs] == ["Sozialpädagogik", "Erziehungswissenschaft"]
    assert progs[0]["code"] == "sozialpaedagogik|b.a.|2025" and progs[1]["grades"] == 5


def test_grades_of_the_old_program_do_not_count_in_the_new_catalog():
    grades = [_g(EW, "Einführung in die Erziehungswissenschaft"), _g(SOP, "Grundlagen der Sozialpädagogik"),
              {"abschluss": "", "text": "ohne Angabe", "note": "1,0", "status": "bestanden"},
              _g("Abschluss: Unbekannt PO-Version: 2020", "unbekannt")]
    kept = sp.grades_for_catalog(grades, {"program": "Sozialpädagogik"}, "hildesheim")
    assert [g["text"] for g in kept] == ["Grundlagen der Sozialpädagogik", "ohne Angabe", "unbekannt"]
    assert sp.grades_for_catalog(grades, None, "hildesheim") == grades


def test_chosen_program_wins_in_the_catalog_sync(fresh):
    """Nur Leistungen aus Erziehungswissenschaft, gewaehlt ist Sozialpaedagogik: gesucht wird deren Katalog"""
    from app import db
    with db.cursor() as conn:
        conn.execute("DELETE FROM grades")
        conn.execute("INSERT INTO grades(pruefungsnr, text, note, status, abschluss) VALUES ('1', 'Einführung', '2,0', 'bestanden', ?)", (EW,))
        conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('study_plan', ?)", ('{"po": "sozialpaedagogik|b.a.|2025"}',))
        st = sc.run_sync(conn, fetch=lambda url, etag=None, last_modified=None: sc.FetchResult(404), university="hildesheim")
        assert st["code"] == "sozialpaedagogik|b.a.|2025" and st["program"] == "Sozialpädagogik", st
        conn.execute("DELETE FROM settings WHERE key='study_plan'")
        st = sc.run_sync(conn, fetch=lambda url, etag=None, last_modified=None: sc.FetchResult(404), university="hildesheim")
        assert st["program"] == "Erziehungswissenschaft", "ohne Wahl der Studiengang aus dem Notenspiegel"
        conn.execute("DELETE FROM grades")


def test_pasted_link_to_a_known_catalog_comes_from_the_seed(fresh):
    """Testkonto: Link zum Modulhandbuch Sozialpaedagogik eingefuegt, po leer, Notenspiegel nur Erziehungswissenschaft.
    Der Link gehoert zum Katalog eines bekannten Studiengangs: der kommt aus dem Grundstock (vorher: LUH-Leser, 0 Module)"""
    from app import db
    link = "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5273"
    reg = sc.load_registry()
    assert sc.code_for_catalog_url(reg, "hildesheim", link) == "sozialpaedagogik|b.a.|2025"
    assert sc.code_for_catalog_url(reg, "hildesheim", "https://example.org/x.pdf") is None
    with db.cursor() as conn:
        conn.execute("DELETE FROM grades")
        conn.execute("INSERT INTO grades(pruefungsnr, text, note, status, abschluss) VALUES ('1', 'Einführung', '2,0', 'bestanden', ?)", (EW,))
        conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('study_plan', ?)",
                     ('{"po": null, "start_term": "WiSe 26/27", "electives": [], "catalog_url": "%s"}' % link,))
        calls = []
        st = sc.run_sync(conn, fetch=lambda url, etag=None, last_modified=None: calls.append(url) or sc.FetchResult(404),
                         university="hildesheim", seed=sc.load_seed())
        assert st["state"] == "seed" and st["program"] == "Sozialpädagogik" and st["modules"] == 16, st
        assert calls == [], "nichts geladen"
        cat, reason = sp.pick_catalog(sp.DbCatalogSource(conn).catalogs(), sp.load_settings(conn), sp.grade_rows(conn))
        assert reason is None and cat["program"] == "Sozialpädagogik"
        old_uni = db.row(conn, "SELECT value FROM settings WHERE key='university'")["value"]
        conn.execute("UPDATE settings SET value='hildesheim' WHERE key='university'")
        try:
            plan = sp.plan_response(conn, "2026-11-14")
        finally:
            conn.execute("UPDATE settings SET value=? WHERE key='university'", (old_uni,))
        assert plan["program"] == "Sozialpädagogik" and plan["lp_done"] == 0, "Leistung aus Erziehungswissenschaft zaehlt nicht"
        assert any(n.get("kind") == "anderer_studiengang" for n in plan["notes"] if isinstance(n, dict)), plan["notes"]
        # frueheres Studium getrennt sichtbar, nichts in den neuen Studiengang gemischt
        assert [(e["program"], e["count"], e["lp"]) for e in plan["earlier_studies"]] == [("Erziehungswissenschaft", 1, 0.0)]
        conn.execute("DELETE FROM settings WHERE key='study_plan'")
        conn.execute("DELETE FROM grades")


def test_minors_and_ask_once_when_the_grades_name_a_newer_program():
    assert sp.clean_minors([" bwl|b.a.|2022 ", "bwl|b.a.|2022", "", 3, "a", "b", "c"]) == ["bwl|b.a.|2022", "a", "b"]
    progs = sp.programs_of([_g(SOP, "x"), _g(EW, "y")], "hildesheim")
    # gewaehlt Erziehungswissenschaft, Notenspiegel nennt Sozialpaedagogik mit neuerer PO: einmal nachfragen
    m = sp.program_mismatch(progs, {"po": "erziehungswissenschaft|b.a.|2023"}, "hildesheim")
    assert m and m["code"] == "sozialpaedagogik|b.a.|2025" and m["chosen"] == "Erziehungswissenschaft"
    assert sp.program_mismatch(progs, {"po": "erziehungswissenschaft|b.a.|2023", "program_ack": "sozialpaedagogik|b.a.|2025"},
                               "hildesheim") is None, "schon abgelehnt"
    # gewaehlt Sozialpaedagogik, Notenspiegel nur mit dem alten Studiengang (aeltere PO): nicht nachfragen
    old = sp.programs_of([_g(EW, "y")], "hildesheim")
    assert sp.program_mismatch(old, {"po": "sozialpaedagogik|b.a.|2025"}, "hildesheim") is None
    assert sp.program_mismatch(progs, {"po": None}, "hildesheim") is None


def test_settings_store_minors_and_ack(fresh):
    from app import db
    with db.cursor() as conn:
        out = sp.save_settings(conn, {"po": "erziehungswissenschaft|b.a.|2022", "minors": ["betriebswirtschaftslehre-begleitfach"],
                                      "program_ack": "x"}, "2026-11-14")
        assert out["minors"] == ["betriebswirtschaftslehre-begleitfach"] and out["program_ack"] == "x"
        out = sp.save_settings(conn, {"minors": [], "program_ack": None}, "2026-11-14")
        assert out["minors"] == [] and "program_ack" not in out
        import pytest as _p
        from fastapi import HTTPException
        with _p.raises(HTTPException):
            sp.save_settings(conn, {"minors": "nein"}, "2026-11-14")


def test_earlier_studies_group_by_program_with_passed_lp():
    rows = [dict(_g(EW, "TM 1: Einführung"), credits="6"), dict(_g(EW, "TM 2: Kindheit", status="angemeldet"), credits="3"),
            dict(_g("Abschluss: [82] Bachelor Studiengang: [021] Betriebswirtschaftslehre (Begleitfach) PO-Version: 2022", "BWL"), credits="7,5")]
    e = sp.earlier_studies(rows)
    assert [(x["program"], x["count"], x["lp"]) for x in e] == [("Erziehungswissenschaft", 2, 6.0),
                                                                 ("Betriebswirtschaftslehre (Begleitfach)", 1, 7.5)]
    assert e[0]["rows"][0] == {"text": "TM 1: Einführung", "note": "2,0", "status": "bestanden", "credits": "6", "semester": "WiSe 24/25"}


def test_pasted_link_to_a_hildesheim_study_regulation_is_read(fresh, monkeypatch):
    """Eigener Link zu einer Hildesheimer Studienordnung, die das Register nicht kennt: der Leser fuer dieses Format
    liest sie (erfundene Seiten aus fixtures/study-catalog-hildesheim, mit Lage der Textstuecke)"""
    import json
    from pathlib import Path
    from app import db
    fx = json.loads((Path(__file__).resolve().parent.parent / "packages/shared-contracts/fixtures/study-catalog-hildesheim/lesefassung.json")
                    .read_text(encoding="utf-8"))
    monkeypatch.setattr(sc, "pdf_pages", lambda data: fx["pages"])
    monkeypatch.setattr(sc, "pdf_items", lambda data: fx["items"])
    link = "https://example.org/studienordnung.pdf"
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('study_plan', ?)", (json.dumps({"po": None, "catalog_url": link}),))
        st = sc.run_sync(conn, fetch=lambda url, etag=None, last_modified=None: sc.FetchResult(200, b"%PDF"), university="hildesheim")
        assert st["state"] == "ready", st
        assert st["program"] == fx["head"]["program"] and st["modules"] == len(fx["catalog"]["modules"]), st
        assert st["code"].startswith("link-") and st["catalog_term"] == fx["head"]["catalog_term"]
        cat, reason = sp.pick_catalog(sp.DbCatalogSource(conn).catalogs(), sp.load_settings(conn), sp.grade_rows(conn))
        assert reason is None and cat["program"] == fx["head"]["program"] and cat["source"]["url"] == link


def test_older_order_is_suggested_for_an_earlier_start():
    code = "sozialpaedagogik|b.a.|2025"
    s = sp.order_suggestion({}, code, "WiSe 24/25", "hildesheim")
    assert s and s["program"] == "Sozial- und Organisationspädagogik" and s["po"] == "2020" and s["url"].endswith("fileID=4710")
    assert sp.order_suggestion({}, code, "WiSe 26/27", "hildesheim") is None, "Testkonto: Beginn WiSe 26/27, neue Ordnung"
    assert sp.order_suggestion({}, code, "WiSe 2025/26", "hildesheim") is None, "ab dem Stichsemester"
    assert sp.order_suggestion({}, code, None, "hildesheim") is None, "ohne Studienbeginn nicht raten"
    assert sp.order_suggestion({"order_ack": "order:" + code}, code, "WiSe 24/25", "hildesheim") is None, "abgelehnt"
    assert sp.order_suggestion({"catalog_url": s["url"]}, code, "WiSe 24/25", "hildesheim") is None, "alte schon gewaehlt"
    assert sp.order_suggestion({}, "erziehungswissenschaft|b.a.|2023", "WiSe 20/21", "hildesheim") is None
