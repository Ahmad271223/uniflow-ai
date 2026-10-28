"""Notenspiegel: Ebenen, Doppelte und aktueller Schnitt (app/grades_model.py, 28.10.2026). Aufbau wie im LUH-QIS
(Werte erfunden): Modulzeile ohne Art und Versuch, darunter die Pruefung mit Art und Versuch, nicht bestandene
Versuche, Bereichszeilen mit weniger Zellen, dieselben Pruefungen noch einmal mit langen Semesternamen."""
import pytest


def raw(*cells):
    return " | ".join(cells)


ROWS = [
    # Bereich (eine Zelle weniger: Note steht in der Semesterspalte)
    {"text": "Kompetenzbereich Grundlagen", "semester": "3,3", "note": "bestanden", "status": "13", "raw": raw("10", "Kompetenzbereich Grundlagen", "", "3,3", "bestanden", "13", "", "", "", "")},
    # Modul + Pruefung
    {"text": "Testmathe I", "semester": "WiSe 23/24", "note": "3,3", "status": "bestanden", "versuch": "", "raw": raw("110", "Testmathe I", "", "WiSe 23/24", "3,3", "bestanden", "8", "22.01.2024", "", "", "")},
    {"text": "Testmathe I", "semester": "WiSe 23/24", "note": "3,3", "status": "bestanden", "versuch": "1", "raw": raw("111", "Testmathe I", "PL", "WiSe 23/24", "3,3", "bestanden", "8", "22.01.2024", "1", "", "")},
    # dieselbe Pruefung aus der zweiten Ansicht mit langem Semesternamen (echtes Doppel)
    {"text": "Testmathe I", "semester": "Wintersemester 23/24", "note": "3,3", "status": "bestanden", "versuch": "1", "raw": raw("111", "Testmathe I", "PL", "Wintersemester 23/24", "3,3", "bestanden", "8", "22.01.2024", "1", "", "")},
    # nicht bestandener Versuch, spaeter bestanden
    {"text": "Testphysik", "semester": "SoSe 24", "note": "5,0", "status": "nicht bestanden", "versuch": "1", "raw": raw("121", "Testphysik", "PL", "SoSe 24", "5,0", "nicht bestanden", "0", "20.07.2024", "1", "OWR", "")},
    {"text": "Testphysik", "semester": "WiSe 24/25", "note": "", "status": "", "versuch": "", "raw": raw("120", "Testphysik", "", "WiSe 24/25", "2,0", "bestanden", "5", "10.02.2025", "", "", "")},
    {"text": "Testphysik", "semester": "WiSe 24/25", "note": "2,0", "status": "bestanden", "versuch": "1", "raw": raw("121", "Testphysik", "PL", "WiSe 24/25", "2,0", "bestanden", "5", "10.02.2025", "1", "", "")},
    # Labor ohne Note (Studienleistung) und Pflichtmodule-Bereich
    {"text": "Testlabor", "semester": "SoSe 24", "note": "", "status": "bestanden", "versuch": "1", "raw": raw("521", "Testlabor", "LA", "SoSe 24", "", "bestanden", "2", "23.07.2024", "1", "", "")},
    {"text": "Pflichtmodule", "semester": "SoSe 25", "note": "", "status": "bestanden", "raw": raw("599", "Pflichtmodule", "", "SoSe 25", "", "bestanden", "6", "13.06.2025", "", "", "")},
    {"text": "Einstiegsmodul", "semester": "SoSe 25", "note": "", "status": "bestanden", "raw": raw("510", "Einstiegsmodul", "", "SoSe 25", "", "bestanden", "6", "13.06.2025", "", "", "")},
]


def test_levels_duplicates_and_fields_from_raw():
    from app import grades_model as gm
    m = gm.model(ROWS)
    assert len(m) == len(ROWS) - 1, "das Doppel mit langem Semesternamen faellt weg"
    lv = {(r["pruefungsnr"], r["semester_norm"]): r["level"] for r in m}
    assert lv[("10", "")] == "bereich" and lv[("599", "SoSe 25")] == "bereich"
    assert lv[("110", "WiSe 23/24")] == "modul" and lv[("111", "WiSe 23/24")] == "pruefung"
    mathe = next(r for r in m if r["pruefungsnr"] == "110")
    assert (mathe["credits"], mathe["datum"]) == ("8", "22.01.2024"), "LP und Datum aus der Zeile"
    phys = next(r for r in m if r["pruefungsnr"] == "120")
    assert (phys["note"], phys["status"], phys["graded"]) == ("2,0", "bestanden", True), "leere Felder aus der Zeile ergaenzt"
    bereich = next(r for r in m if r["pruefungsnr"] == "10")
    assert (bereich["note"], bereich["status"], bereich["credits"], bereich["semester"]) == ("3,3", "bestanden", "13", "")
    assert gm.norm_semester("Wintersemester 25/26") == "WiSe 25/26" and gm.norm_semester("Sommersemester 26") == "SoSe 26"
    assert gm.norm_semester("WS 2024/2025") == "WiSe 24/25"


def test_average_uses_passed_graded_modules_weighted_and_truncated():
    from app import grades_model as gm
    s = gm.summary(ROWS)
    # Module: Testmathe I 3,3 (8 LP), Testphysik 2,0 (5 LP); Einstiegsmodul ohne Note; Versuch 5,0 und Bereiche zaehlen nicht
    exact = (3.3 * 8 + 2.0 * 5) / 13
    assert s["average_exact"] == round(exact, 2) and s["average"] == 2.8      # 2,80 -> 2,8
    assert (s["basis"], s["graded_count"], s["graded_credits"]) == ("module", 2, 13.0)
    assert (s["passed"], s["credits"]) == (3, 19.0), "bestandene Module mit LP, auch ohne Note"
    assert s["failed_attempts"] == 1
    assert [b["text"] for b in s["bereiche"]] == ["Kompetenzbereich Grundlagen", "Pflichtmodule"]
    assert gm.truncate1(3.47) == 3.4 and gm.truncate1(3.0) == 3.0 and gm.truncate1(1.99) == 1.9


def test_hildesheim_layout_without_module_rows_uses_graded_achievements():
    from app import grades_model as gm
    rows = [{"pruefungsnr": "5011", "text": "TM 1: Grundlagen", "note": "1,7", "status": "bestanden", "credits": "6", "raw": "5011 | TM 1 | 1,7 | bestanden | 6"},
            {"pruefungsnr": "4220", "text": "Grundlagen I", "note": "2,3", "status": "bestanden", "credits": "6", "raw": "4220 | Grundlagen I | 2,3 | bestanden | 6"},
            {"pruefungsnr": "5032", "text": "TM 2", "note": "", "status": "angemeldet (SoSe 26)", "credits": "0", "raw": "5032 | TM 2 |  | angemeldet (SoSe 26) | 0"},
            {"pruefungsnr": "10010", "text": "Pflichtmodule (mindestens 12 LP)", "note": "", "status": "Prüfung vorhanden", "credits": "6", "raw": "10010 | Pflichtmodule"}]
    s = gm.summary(rows)
    assert s["average"] == 2.0 and s["graded_count"] == 2 and s["credits"] == 12.0
    assert [b["text"] for b in s["bereiche"]] == ["Pflichtmodule (mindestens 12 LP)"]


def test_grades_endpoint_returns_the_model(app):
    import json
    from conftest import asgi_call
    from app import db, qis
    db.init_db()
    with db.cursor() as conn:
        conn.execute("DELETE FROM grades")
        qis.store_grades(conn, ROWS)
    try:
        st, _, b = asgi_call(app, "GET", "/api/grades")
        d = json.loads(b)
        assert st == 200 and d["average"] == 2.8 and d["average_exact"] == 2.8 and d["graded_count"] == 2
        assert d["grades"][0]["level"] == "bereich" and {r["level"] for r in d["grades"]} == {"bereich", "modul", "pruefung"}
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM grades")
