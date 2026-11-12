"""Zusammengesetzte Modultitel (12.11.2026, iPad eines Nutzers, Maschinenbau B.Sc.; Zeilen anonymisiert, Noten und Daten
erfunden). Der Modulkatalog der LUH nennt "Thermodynamik I / Chemie" (beide Teile noetig) und "Tutorien oder Studium
Generale" (einer reicht); das QIS fuehrt die Teile: Modul "Studium Generale" mit seiner Leistung, die Leistung
"Grundzüge der Chemie" und auf "Info über angemeldete Prüfungen" die Anmeldung "Thermodynamik I".

Am alten Stand (dfb319c6) falsch: alle vier Zeilen standen im Studienverlauf als "nicht zugeordnet", Studium Generale
blieb offen, Thermodynamik I / Chemie stand ohne Stand da und die Pruefungsanmeldung zeigte Thermodynamik als "nicht
angemeldet". Richtig: Studium Generale bestanden; Thermodynamik I / Chemie nicht bestanden (nur ein Teil), angemeldet,
mit Hinweis auf den bestandenen und den fehlenden Teil. Der Swift-Kern prueft dasselbe (QISTeilmoduleTests)."""
import pytest

HEADER = ["PrfNr.", "Bezeichnung der Leistung", "Prf.Art", "Semester ", "Note", "Status", "Leistungspunkte", "Datum",
          "Versuch", "Vermerk", "Freiversuch"]
ROWS = [
    HEADER,
    ["2500", "Studium Generale", "", "WiSe 24/25", " 0,0", "bestanden", " 4", "24.03.2025", "", "", ""],
    ["132110", "Betriebswirtschaftslehre", "PL", "WiSe 24/25", "0,0 ", "bestanden", "4", "24.03.2025", "1", " LAI", ""],
    ["1310", "Grundzüge der Chemie", "SL", "WiSe 25/26", "", "bestanden", "2", "20.02.2026", "1", "", ""],
]
REGISTRATIONS = [
    {"pruefungsnr": "1300", "text": "Thermodynamik I", "semester": "WiSe 26/27", "datum": "", "status": None, "raw": ""},
    {"pruefungsnr": "1200", "text": "Technische Mechanik III", "semester": "WiSe 26/27", "datum": "", "status": None, "raw": ""},
]


def _mod(i, title, sem, lp=5, exam="Klausur 120 min", area="pflicht"):
    return {"id": i, "title": title, "code": None, "area": area, "kind": "pflicht", "lp": lp, "semester": sem, "turnus": "WS",
            "exam": exam, "coursework": None, "prerequisites": [], "language": "deutsch", "workload_h": 150, "source_page": 1}


# Titel wie im Grundstock (maschinenbau|b.sc.|2017)
CATALOG = {
    "v": 1, "university": "luh", "program": "Maschinenbau", "degree": "B.Sc.", "po": "2017", "catalog_term": "WS 2026/27",
    "code": "maschinenbau|b.sc.|2017", "regular_semesters": 7, "total_lp": 210,
    "areas": [{"id": "pflicht", "name": "Pflicht", "kind": "pflicht"},
              {"id": "schluessel", "name": "Schlüssselkompetenzen", "kind": "pflicht"}],
    "modules": [
        _mod("technische-mechanik-3", "Technische Mechanik III", 3),
        _mod("thermodynamik-1-chemie", "Thermodynamik I / Chemie", 3, lp=7, exam="Klausur - Thermodynamik 120 min"),
        _mod("tutorien-oder-studium-generale", "Tutorien oder Studium Generale", 5, lp=4, exam=None, area="schluessel"),
    ],
}
AB = "Maschinenbau (PO-Version 2017)"


def _grades():
    from app import qis
    return qis.parse_grade_rows(ROWS, AB)


def _plan_rows():
    """Notenspiegel plus Anmeldungen wie study_plan.grade_rows"""
    from app import grades_model
    rows = [{"id": i + 1, **g} for i, g in enumerate(_grades())]
    for r in REGISTRATIONS:
        rows.append({"pruefungsnr": r["pruefungsnr"], "text": r["text"], "semester": r["semester"], "note": "",
                     "status": "angemeldet", "versuch": None, "credits": None, "datum": r["datum"], "abschluss": AB,
                     "raw": None, "source": "anmeldung"})
    return grades_model.model(rows)


def test_title_parts():
    from app import study_plan as S
    parts, need_all = S.title_parts("Thermodynamik I / Chemie")
    assert [p for p, _ in parts] == ["Thermodynamik I", "Chemie"] and need_all is True
    parts, need_all = S.title_parts("Tutorien oder Studium Generale")
    assert [p for p, _ in parts] == ["Tutorien", "Studium Generale"] and need_all is False
    assert S.title_parts("Ein-/Ausgabe") == ([], False), "/ ohne Leerzeichen trennt nicht"
    assert S.title_parts("Technische Mechanik III") == ([], False)
    parts, _ = S.title_parts("Thermodynamik I / Chemie")
    assert S.part_index("Thermodynamik I", parts) == 0
    assert S.part_index("Grundzüge der Chemie", parts) == 1, "endet mit dem Teil"
    assert S.part_index("Thermodynamik II", parts) is None
    assert S.part_index("Biochemie", parts) is None, "nur ganze Woerter"


def test_study_plan_assigns_parts():
    from app import study_plan
    p = study_plan.build_plan(CATALOG, _plan_rows(), {}, "2026-11-12")
    assert p["unmatched"] == [], "jede Leistung und Anmeldung gehoert zu einem Modul"
    mods = {m["id"]: m for s in p["semesters"] for m in s["modules"]}
    sg = mods["tutorien-oder-studium-generale"]
    assert sg["status"] == "bestanden", "Studium Generale (Modulzeile und Leistung) fuellt 'Tutorien oder Studium Generale'"
    th = mods["thermodynamik-1-chemie"]
    assert th["status"] == "angemeldet", "nur Chemie bestanden, Thermodynamik I angemeldet"
    assert th["hints"][0] == "Teil bestanden: Grundzüge der Chemie – es fehlt noch: Thermodynamik I"
    assert (th["attempt"], th["final"]) == (1, False), "der bestandene Teil ist kein Fehlversuch"
    assert mods["technische-mechanik-3"]["status"] == "angemeldet"


def test_both_parts_or_module_row_pass_the_module():
    from app import grades_model, study_plan
    both = [{"id": i + 1, **g} for i, g in enumerate(_grades())] + [
        {"id": 9, "pruefungsnr": "1300", "text": "Thermodynamik I", "semester": "SoSe 26", "note": "2,7", "status": "bestanden",
         "credits": "5", "versuch": "1", "datum": "10.08.2026", "abschluss": AB, "raw": "1300 | Thermodynamik I | PL | SoSe 26 | 2,7 | bestanden | 5 | 10.08.2026 | 1"}]
    p = study_plan.build_plan(CATALOG, grades_model.model(both), {}, "2026-11-12")
    th = {m["id"]: m for s in p["semesters"] for m in s["modules"]}["thermodynamik-1-chemie"]
    assert (th["status"], th["grade"], th["hints"]) == ("bestanden", "2,7", [])
    row = [{"id": 1, "pruefungsnr": "1350", "text": "Thermodynamik I / Chemie", "semester": "SoSe 26", "note": "2,7",
            "status": "bestanden", "credits": "7", "versuch": None, "datum": "10.08.2026", "abschluss": AB, "raw": ""}]
    p = study_plan.build_plan(CATALOG, grades_model.model(row), {}, "2026-11-12")
    assert {m["id"]: m for s in p["semesters"] for m in s["modules"]}["thermodynamik-1-chemie"]["status"] == "bestanden"


@pytest.fixture
def device_db(monkeypatch, tmp_path):
    from app import db, qis, qis_registrations, study_plan
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "teilmodule.db")
    db.init_db()
    with db.cursor() as conn:
        qis.store_grades(conn, _grades())
        qis_registrations.store(conn, REGISTRATIONS, "t")
    return study_plan.MemoryCatalogSource([CATALOG])


def test_exam_registration_sees_the_part(device_db):
    from app import db, exam_registration_api
    with db.cursor() as conn:
        v = exam_registration_api.response(conn, "2026-11-12", source=device_db)
    one = {x["id"]: x for x in v["suggestions"]}
    assert one["thermodynamik-1-chemie"]["registered"] is True
    assert one["thermodynamik-1-chemie"]["registered_via"] == "qis_info"
    assert one["technische-mechanik-3"]["registered_via"] == "qis_info"
    assert v["open_count"] == 0
