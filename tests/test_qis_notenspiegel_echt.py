"""Echter Aufbau des LUH-Notenspiegels (Beschreibung des Inhabers 12.11.2026, Testdaten erfunden):
packages/shared-contracts/fixtures/qis-notenspiegel/luh-notenspiegel.tsv (Tabulator-getrennt wie aus QIS kopiert) und
luh-notenspiegel.html (Tabelle wie QIS, Seite im Aufbau von qis-echt-list.html). Beide Wege (Zeilen der Tabelle und
HTML) muessen dasselbe ergeben; der Swift-Kern prueft dieselben Werte (QISNotenspiegelEchtTests).

Kopfzeile: PrfNr. | Bezeichnung der Leistung | Prf.Art | Semester | Note | Status | Leistungspunkte | Datum | Versuch |
Vermerk | Freiversuch. Zeilen mit PL/SL sind Leistungen, Zeilen ohne Art Modul- bzw. Kompetenzbereichszeilen (Summen,
nie mitzaehlen). Note 0,0 = anerkannt ohne Note. Mehrere Eintraege derselben Pruefung: der neueste gilt, "nicht
bestanden" ist ein Fehlversuch.

Am alten Stand (580072ea) falsch: anerkannte Leistungen zeigten die Note "0,0" (Uni & Noten, Studienverlauf), die
Leistung "Betriebswirtschaftslehre" des Moduls "Studium Generale" stand im Studienverlauf als "nicht zugeordnet",
Leistungen kannten ihr Modul nicht (modul_nr), zwei bestandene Eintraege derselben Pruefung zaehlten beide (LP doppelt,
Schnitt aus beiden), und mit Spalte "Prf.Art" machte ein Wert in "Versuch" eine Modulzeile zur Leistung."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "qis-notenspiegel"
DB_FIELDS = ("pruefungsnr", "text", "semester", "note", "status", "credits", "versuch", "datum", "abschluss", "raw")


def _stored(grades):
    """Wie qis.store_grades: nur die Spalten der Tabelle grades, mit id in Seitenreihenfolge"""
    return [{"id": i + 1, **{k: g.get(k) for k in DB_FIELDS}} for i, g in enumerate(grades)]


def _text_rows():
    from app import qis
    rows = [line.split("\t") for line in (FX / "luh-notenspiegel.tsv").read_text(encoding="utf-8").splitlines()]
    return qis.parse_grade_rows(rows, "Maschinenbau (PO-Version 2024)")


def _html_rows():
    from app import qis
    return qis.parse_grade_html((FX / "luh-notenspiegel.html").read_text(encoding="utf-8"), "Maschinenbau (PO-Version 2024)")


CATALOG = {"v": 1, "university": "luh", "program": "Maschinenbau", "code": "MBBSc24", "po": "2024", "regular_semesters": 6,
           "total_lp": 180, "areas": [{"id": "pflicht", "kind": "pflicht", "name": "Pflichtmodule"}],
           "modules": [
               {"id": "mathe-1", "title": "Mathematik für die Ingenieurwissenschaften I", "lp": 8, "semester": 1,
                "kind": "pflicht", "area": "pflicht", "turnus": "WS", "code": None},
               {"id": "tm-2", "title": "Technische Mechanik II", "lp": 5, "semester": 2, "kind": "pflicht", "area": "pflicht",
                "turnus": "SS", "code": None},
               {"id": "studium-generale", "title": "Studium Generale", "lp": 6, "semester": 3, "kind": "pflicht",
                "area": "pflicht", "turnus": None, "code": None}]}


def _check(grades):
    from app import grades_model, study_plan
    assert [g["pruefungsnr"] for g in grades] == ["11", "100", "110", "1110", "1110", "2500", "132110"], "jede Zeile der Tabelle"
    s = grades_model.summary(_stored(grades))
    rows = s["rows"]
    by = {(r["pruefungsnr"], r["semester_norm"]): r for r in rows}
    leistungen = [r for r in rows if r["level"] == "pruefung"]
    assert [r["pruefungsnr"] for r in leistungen] == ["110", "1110", "1110", "132110"], "4 Leistungen (PL/SL-Zeilen)"
    assert [r["art"] for r in leistungen] == ["PL"] * 4
    assert by[("11", "")]["level"] == "bereich" and by[("11", "")]["lp_counted"] == 0, "Kompetenzbereich (Summe 22 LP) nie"
    assert by[("100", "WiSe 24/25")]["level"] == "modul" and by[("2500", "WiSe 24/25")]["level"] == "modul"
    # Technische Mechanik II: Fehlversuch SoSe 25, bestanden SoSe 26
    tm = by[("1110", "SoSe 26")]
    assert (tm["note"], tm["credits"], tm["datum_iso"], tm["passed"], tm["graded"], tm["counted"]) == \
        ("3,3", "5", "2026-08-21", True, True, True)
    fail = by[("1110", "SoSe 25")]
    assert (fail["status"], fail["datum_iso"], fail["passed"], fail["counted"]) == ("nicht bestanden", "2025-08-22", False, False)
    assert s["failed_attempts"] == 1
    # anerkannt ohne Note
    m1 = by[("110", "WiSe 24/25")]
    assert (m1["note"], m1["anerkannt"], m1["passed"], m1["graded"]) == ("", True, True, False), "0,0 = anerkannt, keine Note"
    assert (m1["modul_nr"], m1["modul_text"]) == ("100", "Mathematik für die Ingenieurwissenschaften I")
    assert by[("100", "WiSe 24/25")]["note"] == "" and by[("100", "WiSe 24/25")]["anerkannt"] is True
    bwl = by[("132110", "WiSe 24/25")]
    assert (bwl["modul_nr"], bwl["modul_text"]) == ("2500", "Studium Generale"), "Leistung des Moduls ohne eigene Pruefungen"
    assert tm["modul_nr"] is None, "Technische Mechanik II gehoert nicht zum bestandenen Modul davor"
    # LP: Mathematik I 8 einmal (Modul und Pruefung nicht doppelt), Technische Mechanik II 5, Studium Generale 6
    assert s["credits"] == 19.0 == grades_model.credits_done(_stored(grades))
    assert {r["pruefungsnr"]: r["lp_counted"] for r in rows if r["counted"]} == {"100": 8.0, "1110": 5.0, "2500": 6.0}
    assert (s["average"], s["average_exact"], s["graded_count"], s["passed"]) == (3.3, 3.3, 1, 3), "Schnitt nur aus 3,3"
    # Studienverlauf: dieselben LP, Versuche und Semester
    p = study_plan.build_plan(CATALOG, grades_model.model(_stored(grades)), {}, "2026-11-12")
    mods = {m["id"]: (sem["term"], m) for sem in p["semesters"] for m in sem["modules"]}
    assert p["lp_done"] == 19.0
    assert p["start_term"] == "WiSe 24/25"
    assert p["unmatched"] == [], "Betriebswirtschaftslehre gehoert zu Studium Generale"
    term, t = mods["tm-2"]
    # Versuchsspalte zeigt bei beiden Eintraegen 1: gezaehlt wird der Fehlversuch (SoSe 25, eigenes Semester und Datum),
    # der bestandene ist damit Versuch 2 (max(Fehlversuche + 1, Versuch laut QIS))
    assert (term, t["status"], t["attempt"], t["grade"], t["attempt_known"]) == ("SoSe 26", "bestanden", 2, "3,3", True)
    assert (mods["mathe-1"][0], mods["mathe-1"][1]["status"], mods["mathe-1"][1]["grade"]) == ("WiSe 24/25", "bestanden", None)
    sg = mods["studium-generale"][1]
    assert (mods["studium-generale"][0], sg["status"], sg["grade"], sg["attempt_known"]) == ("WiSe 24/25", "bestanden", None, True)


def test_text_path_luh_notenspiegel():
    g = _text_rows()
    assert g[0]["semester"] == "2,5", "Kompetenzbereich ohne Zelle fuer Semester: verschoben wie kopiert"
    _check(g)


def test_html_path_luh_notenspiegel():
    g = _html_rows()
    assert (g[0]["note"], g[0]["credits"]) == ("2,5", "22"), "colspan: Note und LP unter ihrer Spalte"
    assert [x.get("art") for x in g] == ["", "", "PL", "PL", "PL", "", "PL"], "Spalte Prf.Art erkannt"
    _check(g)
    html = (FX / "luh-notenspiegel.html").read_text(encoding="utf-8")
    assert "Erika" in html and not any("Erika" in (x.get("raw") or "") or "1234567" in (x.get("raw") or "") for x in g), \
        "Stammdaten nie gelesen"


def test_newest_passed_entry_of_an_exam_counts_once():
    """Zwei bestandene Eintraege derselben Pruefung (Notenverbesserung): der neueste nach Datum gilt (LP einmal, Schnitt
    aus ihm); am alten Stand zaehlten beide (LP 10, Schnitt 3,0)"""
    from app import grades_model, qis
    rows = [["PrfNr.", "Bezeichnung der Leistung", "Prf.Art", "Semester", "Note", "Status", "Leistungspunkte", "Datum", "Versuch"],
            ["1110", "Technische Mechanik II", "PL", "SoSe 25", "3,7", "bestanden", "5", "22.08.2025", "1"],
            ["1110", "Technische Mechanik II", "PL", "WiSe 25/26", "2,3", "bestanden", "5", "20.02.2026", "2"]]
    s = grades_model.summary(_stored(qis.parse_grade_rows(rows)))
    assert (s["credits"], s["average_exact"], s["passed"]) == (5.0, 2.3, 1)
    old = next(r for r in s["rows"] if r["semester_norm"] == "SoSe 25")
    assert (old["superseded"], old["counted"], old["graded"]) == (True, False, False)


def test_art_column_decides_module_rows():
    """Mit Spalte Prf.Art ist eine Zeile ohne Art eine Modulzeile, auch mit Wert in "Versuch" (am alten Stand: Leistung,
    das Modul zaehlte dann seine LP nicht und die Pruefung darunter stand allein)"""
    from app import grades_model, qis
    rows = [["PrfNr.", "Bezeichnung der Leistung", "Prf.Art", "Semester", "Note", "Status", "Leistungspunkte", "Datum", "Versuch"],
            ["300", "Konstruktionslehre", "", "SoSe 26", "2,0", "bestanden", "6", "30.07.2026", "1"],
            ["310", "Konstruktionslehre Klausur", "PL", "SoSe 26", "2,0", "bestanden", "4", "30.07.2026", "1"],
            ["320", "Konstruktionslehre Entwurf", "SL", "SoSe 26", "", "bestanden", "2", "15.07.2026", "1"]]
    s = grades_model.summary(_stored(qis.parse_grade_rows(rows)))
    assert [r["level"] for r in s["rows"] if r["pruefungsnr"] == "300"] == ["modul"]
    assert (s["credits"], s["passed"], s["basis"]) == (6.0, 1, "module")
    sl = next(r for r in s["rows"] if r["pruefungsnr"] == "320")
    assert (sl["art"], sl["graded"], sl["modul_nr"]) == ("SL", False, "300")


def test_header_prf_art_and_navigation_rules():
    from app import qis
    assert qis._header_map(["PrfNr.", "Bezeichnung der Leistung", "Prf.Art", "Semester ", "Note", "Status", "Leistungspunkte",
                            "Datum", "Versuch", "Vermerk", "Freiversuch"]) == \
        ["pruefungsnr", "text", "art", "semester", "note", "status", "credits", "datum", "versuch", "status", None]
    for text, href in [("Logout", "https://q/rds?state=user&type=4&category=auth.logout"),
                       ("Prüfungsanmeldung/-abmeldung", "https://q/rds?state=prfAnmStudent"),
                       ("Abmelden", "https://q/rds"), ("PDF-Notenspiegel", "https://q/rds?state=verpublish")]:
        assert qis.is_forbidden_nav(text, href), text
    assert not qis.is_forbidden_nav("Leistungen für Maschinenbau (PO-Version 2024) anzeigen",
                                    "https://q/rds?state=notenspiegelStudent&next=list.vm&nodeID=auswahlBaum|abschluss:abschl=82|studiengang:stg=M24")
    links = [("Leistungen für Mathematik (PO-Version 2017) anzeigen", "a"),
             ("Leistungen für Maschinenbau (PO-Version 2024) anzeigen", "b")]
    assert [h for _, h in qis.prefer_program(links, ["Maschinenbau (PO-Version 2024)"])] == ["b", "a"], "eigener zuerst"
    assert [h for _, h in qis.prefer_program(links, [])] == ["a", "b"]


def test_registrations_real_columns_with_time():
    """Info über angemeldete Prüfungen: echte Spalten, Prüfungsdatum mit Uhrzeit"""
    from app import qis_registrations as Q
    rows = [["PrfNr.", "Prüfungsbezeichnung", "Prüfer/in", "Semester (Termin)", "Anmeldedatum *)",
             "Rücktritt über QIS möglich bis", "Prüfungsdatum"],
            ["1110", "Technische Mechanik II", "Muster", "SoSe 27 (01)", "10.05.2027", "13.08.2027", "20.08.2027 10:00"]]
    r = Q.row_view(Q.parse_rows(rows)[0])
    assert (r["pruefungsnr"], r["pruefer"], r["iso_date"], r["clock"], r["iso_withdraw"], r["registered"]) == \
        ("1110", "Muster", "2027-08-20", "10:00", "2027-08-13", True)
