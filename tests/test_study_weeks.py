"""Semesterwochen (study.semester_cut, semester_start, week_index): Stichtag des Semesters und Dateien vor dem
Vorlesungsbeginn. Korrektur vom 25.10.2026 (docs/IPAD-OHNE-PC.md, Abschnitt 7, Entscheidung 1), Vorlage fuer den
Swift-Port im lokalen Backend (StudyWeeks.swift)."""
from datetime import date, datetime


def _ts(y, m, d, h=12):
    return int(datetime(y, m, d, h).timestamp())


def test_semester_cut_never_in_future(monkeypatch):
    from app import study
    # Wintersemester: Oktober bis Februar -> 1.10.; Sommersemester: Maerz bis September -> 1.3.
    cases = {date(2026, 10, 1): date(2026, 10, 1), date(2026, 12, 31): date(2026, 10, 1),
             date(2027, 1, 18): date(2026, 10, 1), date(2027, 2, 28): date(2026, 10, 1),
             date(2027, 3, 1): date(2027, 3, 1), date(2027, 7, 15): date(2027, 3, 1),
             date(2027, 9, 15): date(2027, 3, 1), date(2027, 9, 30): date(2027, 3, 1)}
    for t, cut in cases.items():
        assert study.semester_cut(t) == cut, t
        assert study.semester_cut(t) <= t


def test_week_index_in_january_and_september(monkeypatch):
    from app import study
    start = date(2026, 10, 12)
    # Januar: Dateien des laufenden Wintersemesters sind keine "Aelteren Unterlagen"
    monkeypatch.setattr(study, "today", lambda: date(2027, 1, 18))
    assert study.week_index(start, _ts(2026, 10, 13)) == 1
    assert study.week_index(start, _ts(2027, 1, 12)) == 14
    assert study.week_index(start, _ts(2026, 9, 20)) == -1, "vor dem Stichtag: aelteres Semester"
    # September: das Sommersemester laeuft noch (Klausurzeit)
    monkeypatch.setattr(study, "today", lambda: date(2027, 9, 15))
    assert study.week_index(date(2027, 4, 12), _ts(2027, 6, 1)) == 8


def test_files_before_lecture_start_are_week_zero(monkeypatch):
    from app import study
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 20))
    start = date(2026, 10, 12)
    # nach dem Stichtag, aber vor dem Vorlesungsbeginn: "Vor Vorlesungsbeginn", nie -1 oder -2
    for d in (date(2026, 10, 1), date(2026, 10, 2), date(2026, 10, 9)):
        assert study.week_index(start, _ts(d.year, d.month, d.day)) == 0, d
    assert study.week_label(start, 0) == "Vor Vorlesungsbeginn"
    assert study.week_index(start, _ts(2026, 10, 12)) == 1
    assert study.week_index(start, None) == 0


def test_event_and_file_on_the_same_day_share_the_week(monkeypatch):
    from datetime import timedelta
    from app import study
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 20))
    start = date(2026, 10, 12)
    d = date(2026, 9, 1)
    while d <= date(2027, 2, 28):
        assert study.day_week(start, d) == study.week_index(start, _ts(d.year, d.month, d.day)), d
        d += timedelta(days=1)
    assert study.day_week(start, date(2026, 9, 30)) == -1, "vor dem Stichtag: aelteres Semester"
    assert study.day_week(start, date(2026, 10, 1)) == 0
    assert study.day_week(start, date(2026, 10, 11)) == 0
    assert study.day_week(start, date(2026, 10, 18)) == 1


def test_materials_for_event_before_lecture_start(app, monkeypatch):
    """timetable.materials_for_event: ein Termin vor dem Vorlesungsbeginn findet die Unterlagen von Woche 0
    ("Vor Vorlesungsbeginn"), nicht die des aelteren Semesters (Pruefer S4, 25.10.2026)."""
    from app import db, study, timetable
    ids = [f"mt-k{i}" for i in range(5)]
    files = [(f"mt-w1-{i}", ids[i], f"VL01_{i}.pdf", _ts(2026, 10, 13, 8 + i)) for i in range(5)]
    files += [("mt-vorkurs", ids[0], "Vorkurs Folien.pdf", _ts(2026, 10, 1, 10)),
              ("mt-alt", ids[0], "Folien Sommer.pdf", _ts(2026, 6, 1)),
              ("mt-w2", ids[1], "VL02.pdf", _ts(2026, 10, 20))]
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Testfach Unterlagen', '#000', 0, '2026-10-01')").lastrowid
        for i, cid in enumerate(ids):
            conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, created_at) VALUES (?, ?, 'Testfach Unterlagen', 'vorlesung', ?, '2026-10-01')",
                         (cid, f"Testkurs Unterlagen {i}", mid))
        for fid, cid, name, ts in files:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, ?, ?, ?, 'Vorlesung')", (fid, cid, name, ts))
    try:
        monkeypatch.setattr(study, "today", lambda: date(2026, 11, 20))
        with db.cursor() as conn:
            assert study.semester_start(conn) == date(2026, 10, 12)

            def mats(d):
                return [f["id"] for f in timetable.materials_for_event(conn, {"module_id": mid}, d)]
            # 10 bzw. 3 Tage vor dem Vorlesungsbeginn: Woche 0 (vorher Woche -1 und damit nur "mt-alt")
            assert mats(date(2026, 10, 2)) == ["mt-vorkurs"]
            assert mats(date(2026, 10, 9)) == ["mt-vorkurs"]
            # Vorlesungswochen wie bisher
            assert mats(date(2026, 10, 14)) == [f"mt-w1-{i}" for i in range(5)]
            assert mats(date(2026, 10, 21)) == ["mt-w2"]
            # vor dem Stichtag: aelteres Semester, wie eine Datei von diesem Tag
            assert mats(date(2026, 9, 30)) == ["mt-alt"]
            # Woche ohne Unterlagen: die letzten vier Vorlesungen/Uebungen
            assert mats(date(2026, 11, 18)) == ["mt-w1-2", "mt-w1-3", "mt-w1-4", "mt-w2"]
            assert timetable.materials_for_event(conn, {"module_id": None}, date(2026, 10, 2)) == []
    finally:
        with db.cursor() as conn:
            conn.execute(f"DELETE FROM files WHERE id IN ({','.join('?' * len(files))})", [f[0] for f in files])
            conn.execute(f"DELETE FROM courses WHERE id IN ({','.join('?' * len(ids))})", ids)
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))


def test_semester_start_in_january(app, monkeypatch):
    from app import db, study
    ids = [f"sw-k{i}" for i in range(5)]
    with db.cursor() as conn:
        for i, cid in enumerate(ids):
            conn.execute("INSERT INTO courses(id, title, kind, created_at) VALUES (?, ?, 'vorlesung', '2026-10-01')", (cid, f"Testkurs {i}"))
            conn.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?, ?, 'f.pdf', ?)", (f"sw-f{i}", cid, _ts(2026, 10, 13 + i % 2)))
    try:
        monkeypatch.setattr(study, "today", lambda: date(2027, 1, 18))
        with db.cursor() as conn:
            assert study.semester_start(conn) == date(2026, 10, 12), "Wochenbeginn mit 5 Kursen, auch im Januar"
    finally:
        with db.cursor() as conn:
            conn.execute(f"DELETE FROM files WHERE id IN ({','.join('?' * 5)})", [f"sw-f{i}" for i in range(5)])
            conn.execute(f"DELETE FROM courses WHERE id IN ({','.join('?' * 5)})", ids)


def test_file_week_is_one_rule_for_detail_plan_and_event(app, monkeypatch):
    """study.file_week: "Blatt 3", in Woche 5 hochgeladen, steht im Moduldetail, im Lernplan (_units) und bei den
    Unterlagen zum Termin in Woche 3; vorher nahmen Lernplan und Termin die Woche der Aenderung (Abnahme 26.10.2026)."""
    from app import db, study, timetable
    ids = [f"fw-k{i}" for i in range(5)]
    files = [(f"fw-w1-{i}", ids[i], f"Folien Einfuehrung {i}.pdf", "Vorlesung", _ts(2026, 10, 13, 8 + i)) for i in range(5)]
    files += [("fw-blatt3", ids[0], "Blatt 3.pdf", "Uebungen", _ts(2026, 11, 10)),
              ("fw-vl5", ids[1], "Folien Integrale.pdf", "Vorlesung", _ts(2026, 11, 10)),
              ("fw-klausur", ids[2], "Probeklausur.pdf", "Klausuren", _ts(2026, 11, 10))]
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Testfach Lehrwoche', '#000', 0, '2026-10-01')").lastrowid
        for i, cid in enumerate(ids):
            conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, created_at) VALUES (?, ?, 'Testfach Lehrwoche', 'vorlesung', ?, '2026-10-01')",
                         (cid, f"Testkurs Lehrwoche {i}", mid))
        for fid, cid, name, folder, ts in files:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, ?, ?, ?, ?)", (fid, cid, name, ts, folder))
    try:
        monkeypatch.setattr(study, "today", lambda: date(2026, 11, 20))
        with db.cursor() as conn:
            start = study.semester_start(conn)
            assert start == date(2026, 10, 12)
            rows = {f["id"]: f for f in study._file_rows(conn, mid)}
            assert study.week_index(start, rows["fw-blatt3"]["chdate"]) == 5
            assert study.file_week(start, rows["fw-blatt3"]) == 3
            assert study.file_week(start, rows["fw-vl5"]) == 5
            assert study.file_week(start, rows["fw-klausur"]) == -2
            detail = {w["week"]: w for w in study.module_detail(conn, mid)["weeks"]}
            assert [f["id"] for f in detail[3]["uebungen"]] == ["fw-blatt3"]
            units = {u["week"]: u for u in study._units(conn, mid, set())}
            assert [f["id"] for f in units[3]["uebungen"]] == ["fw-blatt3"], "Lernplan: Woche 3 wie im Moduldetail"
            assert [f["id"] for f in units[5]["vorlesungen"]] == ["fw-vl5"]
            assert -2 not in units

            def mats(d):
                return [f["id"] for f in timetable.materials_for_event(conn, {"module_id": mid}, d)]
            assert mats(date(2026, 10, 28)) == ["fw-blatt3"], "Termin in Woche 3"
            assert mats(date(2026, 11, 11)) == ["fw-vl5"], "Termin in Woche 5: ohne Blatt 3 und Klausur"
    finally:
        with db.cursor() as conn:
            conn.execute(f"DELETE FROM files WHERE id IN ({','.join('?' * len(files))})", [f[0] for f in files])
            conn.execute(f"DELETE FROM courses WHERE id IN ({','.join('?' * len(ids))})", ids)
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))
