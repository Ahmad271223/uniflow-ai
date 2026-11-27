"""Teilmodule des LSF Hildesheim im Studienverlauf (26.11.2026, echtes Konto; Faecher, Nummern und Noten erfunden).

Das Modulhandbuch nennt "Basismodul 1: Aufbau der Zahlbereiche", der Notenspiegel des LSF "BM 1: Aufbau der
Zahlbereiche" (Status "Prüfung vorhanden", solange nicht alle Teile bestanden sind) und darunter die Teilmodule
("TM 1: Arithmetik und Algebra …"). Vorher: alle Katalog-Module "offen", die Teilmodule "nicht zugeordnet". Jetzt:
Modulbezeichner werden erkannt, ein angefangenes Modul zeigt seine erreichten LP. Der Swift-Kern rechnet denselben
Fall in den Vergleichsdaten (tools/gen-study-plan-fixture.py, Fall lsf_teilmodule)."""
from app import grades_model, study_plan as S

AB = "Abschluss: [B5] Zwei-Fächer-Bachelor Studiengang: [105] Mathematik PO-Version: 2025"


def _mod(i, title, area, lp, sem):
    return {"id": i, "title": title, "code": None, "area": area, "kind": "pflicht", "lp": lp, "semester": sem,
            "turnus": "WS+SS", "prerequisites": []}


CATALOG = {
    "v": 1, "university": "hildesheim", "program": "Mathematik", "degree": "B.A./B.Sc.", "po": "2025", "code": "m|2025",
    "catalog_term": "SS 2025", "regular_semesters": 6, "total_lp": None,
    "areas": [{"id": "basis", "name": "Basismodule", "kind": "pflicht"}],
    "modules": [_mod("b1", "Basismodul 1: Aufbau der Zahlbereiche", "basis", 15, 1),
                _mod("b2", "Basismodul 2: Grundlagen der Mathematikdidaktik", "basis", 6, 2),
                _mod("b3", "Basismodul 3: Geometrie", "basis", 7, 1)],
}


def _row(nr, text, sem, status, note="", lp="0", versuch="", datum=""):
    return {"pruefungsnr": nr, "text": text, "semester": sem, "note": note, "status": status, "credits": lp,
            "versuch": versuch, "datum": datum, "abschluss": AB, "raw": ""}


def test_module_tag():
    assert S.module_tag("Basismodul 1: Aufbau der Zahlbereiche") == ("#b1", "Aufbau der Zahlbereiche")
    assert S.module_tag("BM 1: Aufbau der Zahlbereiche") == ("#b1", "Aufbau der Zahlbereiche")
    assert S.module_tag("Aufbaumodul 2: Vertiefung") == S.module_tag("AM 2: Vertiefung") == ("#a2", "Vertiefung")
    assert S.module_tag("Vertiefungsmodul 3: Diskrete Mathematik")[0] == S.module_tag("VM 3: X")[0] == "#v3"
    assert S.module_tag("M 4: Praktische Philosophie") == S.module_tag("Modul 4: Praktische Philosophie") == ("#4", "Praktische Philosophie")
    assert S.module_tag("TM: Einführung in die Mathematikdidaktik") is None, "Teilmodul ohne Nummer"
    assert S.module_tag("Mathematik I") is None and S.module_tag("Programmieren 1") is None


def test_lsf_modules_and_their_parts_belong_to_the_catalog_modules():
    grades = grades_model.model([
        _row("4010", "BM 1: Aufbau der Zahlbereiche", "SoSe 26", "Prüfung vorhanden", lp="14"),
        _row("4011", "TM 1: Arithmetik und Algebra / 5105 Arithmetik", "WiSe 25/26", "nicht bestanden", "5,0", "0", "1", "13.02.2026"),
        _row("4011", "TM 1: Arithmetik und Algebra / 5105 Arithmetik", "WiSe 25/26", "bestanden", "3,3", "6", "2", "26.03.2026"),
        _row("4012", "TM 2: Analysis / 5110 Analysis", "SoSe 26", "bestanden", "", "8", "1", "27.07.2026"),
        _row("4020", "BM 2: Grundlagen der Mathematikdidaktik", "SoSe 26", "Prüfung vorhanden", lp="2"),
        _row("4021", "TM: Einführung in die Mathematikdidaktik / 5130 Einführung", "SoSe 26", "bestanden", "", "2", "1", "30.09.2026"),
        _row("4030", "BM 3: Geometrie", "WiSe 25/26", "bestanden", "2,0", "7"),
        _row("4031", "TM: Geometrie / 5300 Geometrie", "WiSe 25/26", "bestanden", "2,0", "7", "1", "20.02.2026"),
    ])
    p = S.build_plan(CATALOG, grades, {}, "2026-11-26")
    assert p["unmatched"] == [], "Teilmodule gehoeren zu ihrem Modul"
    mods = {m["id"]: m for s in p["semesters"] for m in s["modules"]}
    b1, b2, b3 = mods["b1"], mods["b2"], mods["b3"]
    assert (b3["status"], b3["grade"]) == ("bestanden", "2,0"), "BM 3 bestanden -> Basismodul 3 bestanden"
    assert b1["status"] == "offen" and b1["lp_part"] == 14, "angefangen, nicht bestanden"
    assert (b1["attempt"], b1["reason"]) == (None, "Angefangen – Rest nachholen"), "der Fehlversuch von TM 1 zaehlt nicht mehr"
    assert b1["hints"] == ["Teilweise bestanden (14 von 15 LP): TM 1: Arithmetik und Algebra, TM 2: Analysis"]
    assert b2["lp_part"] == 2 and b2["hints"][0].startswith("Teilweise bestanden (2 von 6 LP)")
    now = next(s for s in p["semesters"] if s["current"])
    assert now["lp"] == 1 + 4, "im Semester nur, was noch fehlt"
    assert p["lp_done"] == 23, "LP wie in Uni & Noten"
    basis = p["areas"][0]
    assert (basis["lp_done"], basis["count_done"]) == (23, 1)


def test_without_module_rows_it_stays_as_before():
    """Ohne Modulzeile (QIS der LUH, aelterer Abzug): eine bestandene Leistung mit Modulbezeichner besteht das Modul wie
    ein gleichnamiger Titel; nichts wird zu "teilweise" """
    grades = grades_model.model([_row("4030", "BM 3: Geometrie", "WiSe 25/26", "bestanden", "2,0", "7", "1", "20.02.2026")])
    mods = {m["id"]: m for s in S.build_plan(CATALOG, grades, {}, "2026-11-26")["semesters"] for m in s["modules"]}
    assert mods["b3"]["status"] == "bestanden" and "lp_part" not in mods["b3"]
    assert "lp_part" not in mods["b1"] and mods["b1"]["hints"] == []
