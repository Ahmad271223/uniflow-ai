"""Mehr-Faecher-Studiengang (26.11.2026, echtes Konto Uni Hildesheim): das LSF fuehrt jedes Fach eines Zwei-Faecher-
Bachelors als eigenen "Studiengang" unter demselben Abschluss. Die App nahm ein Fach als ganzen Studiengang ("69 von
72 LP", ein anderes Fach als "Früheres Studium"). Jetzt: ein Studiengang mit 180 LP, je Fach seine LP, bestanden je
Semester. Gleiche Faelle in StudyCombinedDegreeTests.swift. Bezeichnungen im Aufbau der echten Seite, Leistungen erfunden."""
from app import grades_model
from app import study_plan as sp

B5 = "Abschluss: [B5] Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule Studiengang: "
MATH = B5 + "[105] Mathematik PO-Version: 2025"
ECON = B5 + "[011] Wirtschaft PO-Version: 2014"
ESW = B5 + "[ESW] Erziehungs- und Sozialwissenschaften PO-Version: 2022"
OLD = "Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2023"


def _row(label, nr, text, semester="", note="", status="bestanden", lp="0", versuch="", datum=""):
    return {"abschluss": label, "pruefungsnr": nr, "text": text, "semester": semester, "note": note, "status": status,
            "credits": lp, "versuch": versuch, "datum": datum, "raw": ""}


def _account(label, text, lp, note=""):
    return {"abschluss": label, "pruefungsnr": None, "text": "Gesamtkonto: " + text, "semester": None, "note": note or None,
            "status": None, "credits": lp, "versuch": None, "datum": None, "raw": f"Konto 10 | {text} | {note} |  | {lp} |  |  | "}


def _grades():
    return grades_model.model([
        _account(MATH, "Mathematik", "9", "0,0"),
        _row(MATH, "25011", "TM 1: Arithmetik / 5105 Arithmetik", "WiSe 25/26", "3,3", lp="6", versuch="1", datum="20.02.2026"),
        _row(MATH, "22021", "TM: Einführung in die Didaktik / 5201 Einführung", "SoSe 26", lp="3", versuch="1", datum="15.07.2026"),
        _account(MATH, "Vorläufige Gesamtnote aller Fächer", "20", "2,65"),
        _account(ECON, "Wirtschaft", "6"),
        _row(ECON, "14010", "BM 1: Betriebswirtschaftslehre I", "WiSe 25/26", "2,0", lp="6"),
        _row(ECON, "14011", "TM: Grundlagen I (V) / 3200 Grundlagen 1", "WiSe 25/26", "2,0", lp="3", versuch="1", datum="09.02.2026"),
        _row(ECON, "14012", "TM: Grundlagen II (Ü) / 3201 Grundlagen 2", "WiSe 25/26", lp="3", versuch="1", datum="09.02.2026"),
        _account(ESW, "Pädagogik", "5"),
        _row(ESW, "21010", "BM 1: Handeln in der Schule", "SoSe 26", lp="5"),
        _row(ESW, "21011", "TM: Schulpädagogik / 0424 Einführung", "SoSe 26", lp="5", versuch="1", datum="01.07.2026"),
    ])


def test_subjects_of_one_degree_are_one_program_with_180_lp():
    grades = _grades()
    deg = sp.combined_degree(grades)
    assert deg == {"degree": "Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule", "labels": [MATH, ECON, ESW]}
    assert sp.his_label(MATH) == {"degree_key": "[B5] Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule",
                                  "degree": "Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule",
                                  "subject": "Mathematik", "po": "2025"}
    assert sp.his_label("Technische Informatik (PO-Version 2017)") is None
    mine = sp.grades_for_catalog(grades, {"program": "Mathematik im Polyvalenten Zwei-Fächer-Bachelor"}, "hildesheim")
    assert {r["abschluss"] for r in mine} == {MATH}, "die anderen Faecher zaehlen nicht im Katalog Mathematik"
    assert grades_model.credits_done(mine) == 9
    d = sp.degree_overview(grades, mine)
    assert (d["name"], d["lp_total"], d["lp_done"]) == ("Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule", 180, 20)
    assert (d["official_lp"], d["official_grade"]) == (20, "2,65")
    assert [(s["program"], s["po"], s["lp_done"], s["passed"], s["current"]) for s in d["subjects"]] == [
        ("Mathematik", "2025", 9, 2, True), ("Wirtschaft", "2014", 6, 1, False),
        ("Erziehungs- und Sozialwissenschaften", "2022", 5, 1, False)]
    assert sp.degree_overview(grades, mine, lp_manual=4)["lp_done"] == 24, "selbst eingetragene LP zaehlen im Studiengang mit"
    assert sp.degree_total("Master of Education") == 120 and sp.degree_total("Staatsexamen") is None


def test_passed_terms_list_what_was_passed_in_which_semester():
    terms = sp.passed_terms(_grades())
    assert [(t["name"], t["lp"]) for t in terms] == [("WiSe 25/26", 12), ("SoSe 26", 8)]
    assert [(r["text"], r["lp"], r["program"]) for r in terms[0]["rows"]] == [
        ("TM 1: Arithmetik / 5105 Arithmetik", 6, "Mathematik"), ("BM 1: Betriebswirtschaftslehre I", 6, "Wirtschaft")]
    assert terms[0]["rows"][0]["note"] == "3,3"
    # QIS der LUH: dieselbe Liste, ohne Fach; eine Leistung ohne Semester und ohne Datum steht am Ende
    luh = grades_model.model([
        {"abschluss": "Informatik (PO-Version 2017)", "pruefungsnr": "1100", "text": "Mathematik I", "semester": "WiSe 23/24",
         "note": "2,0", "status": "bestanden", "credits": "8", "versuch": "", "datum": "", "raw": ""},
        {"abschluss": "Informatik (PO-Version 2017)", "pruefungsnr": "1200", "text": "Programmieren", "semester": "",
         "note": "", "status": "bestanden", "credits": "5", "versuch": "", "datum": "", "raw": ""}])
    terms = sp.passed_terms(luh)
    assert [(t["name"], t["lp"], [r["program"] for r in t["rows"]]) for t in terms] == [("WiSe 23/24", 8, [None]), (None, 5, [None])]
    assert sp.combined_degree(luh) is None and sp.degree_overview(luh, luh) is None


def test_change_of_program_in_a_plain_bachelor_stays_an_earlier_study():
    """Zwei Studiengaenge unter "Bachelor" ohne Mehr-Faecher-Abschluss (Wechsel, 14.11.2026): kein gemeinsamer Studiengang"""
    sop = "Abschluss: [82] Bachelor Studiengang: [161] B.A. Sozialpädagogik PO-Version: 2025"
    grades = grades_model.model([_row(OLD, "1", "Einführung", "WiSe 24/25", "2,0", lp="6"),
                                 _row(sop, "2", "Grundlagen", "SoSe 26", "2,0", lp="6")])
    assert sp.combined_degree(grades) is None
    kept = sp.grades_for_catalog(grades, {"program": "Sozialpädagogik"}, "hildesheim")
    assert [g["text"] for g in kept] == ["Grundlagen"]
    # und ein frueheres Studium neben dem Mehr-Faecher-Studiengang bleibt eines; seine LP wie in Uni & Noten
    both = grades_model.model([dict(r) for r in _grades()] + [_row(OLD, "1", "Einführung", "WiSe 23/24", "2,0", lp="6")])
    assert sp.combined_degree(both)["labels"] == [MATH, ECON, ESW]
    econ = [r for r in _grades() if r["abschluss"] == ECON and not sp.is_bereich(r)]
    assert sp.earlier_studies(econ)[0]["lp"] == 6, "Modul und Teilmodule nicht doppelt (vorher 12)"


def test_custom_entries_keep_hours_and_content():
    """Eigene Module mit Arbeitsaufwand und Inhalt (26.11.2026): was die App nicht erkennt, legt man selbst an"""
    rows = sp.clean_custom([
        {"title": " Seminar Medien ", "lp": 5, "semester": 3, "workload_h": 150, "content": "  Grundlagen\nPraxisprojekt  "},
        {"title": "Ohne Angaben", "lp": 2.5, "workload_h": 0, "content": "   "},
        {"title": "Zu viel", "workload_h": 99999, "content": "x" * 2100},
        {"title": "Text statt Zahl", "workload_h": "90"}])
    assert rows[0] == {"id": "eigen-1", "title": "Seminar Medien", "lp": 5, "area": None, "semester": 3, "workload_h": 150,
                       "content": "Grundlagen\nPraxisprojekt"}
    assert (rows[1]["workload_h"], rows[1]["content"]) == (None, None)
    assert rows[2]["workload_h"] is None and len(rows[2]["content"]) == 2000
    assert rows[3]["workload_h"] is None
