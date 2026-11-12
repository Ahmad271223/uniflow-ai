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


# Regel des Inhabers 12.11.2026: QIS ist die einzige Quelle; jede bestandene QIS-Leistung zaehlt einmal (wie
# GradesModelTests im Swift-Kern)
def _row(nr, text, sem, status, note="", lp="", art="", versuch=""):
    return {"pruefungsnr": nr, "text": text, "semester": sem, "note": note, "status": status, "credits": lp, "versuch": versuch,
            "raw": raw(nr, text, art, sem, note, status, lp, "", versuch, "")}


def test_passed_exam_without_module_row_counts():
    from app import grades_model as gm
    rows = [_row("1100", "Mathematik I", "WiSe 23/24", "bestanden", "2,0", "8"),
            _row("1101", "Mathematik I", "WiSe 23/24", "bestanden", "2,0", "8", "PL", "1"),
            _row("9000", "Kompetenzbereich Schlüsselkompetenzen", "", "bestanden", "", "4"),
            _row("9011", "Englisch B2", "WiSe 24/25", "bestanden", "", "4", "SL", "1")]
    s = gm.summary(rows)
    assert (s["credits"], s["passed"]) == (12.0, 2), "vorher 8 LP: die Pruefung ohne Modulzeile fehlte"
    assert gm.credits_done(rows) == 12.0


def test_passed_status_variants_and_note_without_status():
    from app import grades_model as gm
    rows = [_row("201", "Seminar A", "SoSe 25", "BE", "", "3", "SL", "1"),
            _row("202", "Auslandsmodul", "SoSe 25", "bestanden (anerkannt)", "", "5", "AN", "1"),
            _row("203", "Vorkurs", "SoSe 25", "angerechnet", "", "2", "SL", "1"),
            _row("204", "Projekt", "SoSe 25", "", "1,7", "6", "PL", "1"),
            _row("205", "Klausur X", "SoSe 25", "", "5,0", "6", "PL", "1"),
            _row("206", "Klausur Y", "SoSe 26", "angemeldet", "", "", "PL", "1"),
            _row("207", "Klausur Z", "SoSe 25", "nicht bestanden", "4,0", "6", "PL", "1")]
    assert [r["passed"] for r in gm.model(rows)] == [True, True, True, True, False, False, False]
    assert gm.summary(rows)["credits"] == 16.0
    assert not gm.is_passed({"status": "bestanden", "source": "anmeldung"})


def test_vertiefung_der_is_a_module_not_a_bereich():
    from app import grades_model as gm
    rows = [_row("300", "Vertiefung der Betriebssysteme", "WiSe 24/25", "bestanden", "1,7", "5"),
            _row("310", "Vertiefung Informatik", "WiSe 24/25", "bestanden", "", "15")]
    assert [r["level"] for r in gm.model(rows)] == ["modul", "bereich"]
    assert gm.summary(rows)["credits"] == 5.0


def test_module_and_its_exams_count_once():
    from app import grades_model as gm
    rows = [_row("1100", "Mathematik I", "WiSe 23/24", "bestanden", "2,0", "8"),
            _row("1101", "Klausur Mathematik I", "WiSe 23/24", "bestanden", "2,0", "8", "PL", "1"),
            _row("1102", "Übungsschein", "WiSe 23/24", "bestanden", "", "8", "SL", "1"),
            _row("6001", "Labor Regelung", "WiSe 25/26", "bestanden", "", "2", "LA", "1"),
            _row("4000", "Programmierpraktikum", "SoSe 24", "bestanden"),
            _row("4711", "Praktikum Abnahme", "SoSe 24", "bestanden", "", "6", "PR", "1"),
            _row("5000", "Elektrotechnik", "SoSe 25", "", "", "10"),
            _row("5001", "Elektrotechnik", "SoSe 25", "bestanden", "2,3", "7", "PL", "1"),
            _row("5002", "Elektrotechnik", "SoSe 25", "bestanden", "", "7", "LA", "1")]
    got = {r["pruefungsnr"]: r["lp_counted"] for r in gm.model(rows) if r["counted"]}
    assert got == {"1100": 8, "6001": 2, "4000": 6, "5001": 7, "5002": 3}
    assert gm.summary(rows)["credits"] == 26.0


def test_parse_grade_rows_reads_prfnr_and_lp_and_keeps_same_named_exams():
    from app import qis
    rows = [["PrfNr.", "Prüfungstext", "Art", "Semester", "Note", "Status", "LP", "Vermerk", "Versuch", "Prüfungsdatum"],
            ["1101", "Mathematik I", "PL", "WiSe 26/27", "2,0", "bestanden", "8", "", "1", "12.02.2027"],
            ["1102", "Mathematik I", "SL", "WiSe 26/27", "", "bestanden", "0", "", "1", "01.02.2027"]]
    g = qis.parse_grade_rows(rows)
    assert [(r["pruefungsnr"], r["credits"]) for r in g] == [("1101", "8"), ("1102", "0")]
    # Nummer aus der ersten Spalte auch bei unbekanntem Kopf
    g2 = qis.parse_grade_rows([["Nummer", "Prüfungstext", "Note", "Status"], ["4711", "Projekt", "1,0", "bestanden"]])
    assert g2[0]["pruefungsnr"] == "4711"


def test_semester_from_date_when_column_is_empty():
    from app import grades_model as gm
    m = gm.model([_row("2101", "Mathematik II", "", "nicht bestanden", "5,0", "0", "PL", "")])
    assert m[0]["semester_norm"] == "" and gm.term_of_date("27.09.2024") == 4048
    rows = [{**_row("2101", "Mathematik II", "", "nicht bestanden", "5,0", "0", "PL", ""), "datum": "27.09.2024"}]
    assert gm.model(rows)[0]["semester_norm"] == "SoSe 24"
    assert gm.norm_semester("W24") == "WiSe 24/25" and gm.norm_semester("20251") == "SoSe 25"
