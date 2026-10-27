"""Semester erkennen (app/semesters.py, 28.10.2026): alte Kurse werden nicht mehr eingeplant, Entscheidungen des
Nutzers bleiben, Stud.IP-Antworten mit start-/end-semester werden gelesen."""
import json
from datetime import date

import pytest

TODAY = date(2026, 10, 28)                 # WiSe 2026/27


def study_mod():
    from app import study
    return study


def test_keys_and_current_semester():
    from app import semesters as s
    assert s.key("WiSe 2026/27") == (2026, 2) and s.key("SoSe 2026") == (2026, 1) and s.key("WS 26/27") == (2026, 2)
    assert s.key("Wintersemester 2025/2026") == (2025, 2) and s.key("SS 2024") == (2024, 1) and s.key("") is None and s.key(None) is None
    assert s.current(TODAY) == (2026, 2) and s.current(date(2027, 3, 31)) == (2026, 2) and s.current(date(2027, 4, 1)) == (2027, 1)
    assert s.label((2026, 2)) == "WiSe 2026/27" and s.label((2027, 1)) == "SoSe 2027"
    assert s.is_current("WiSe 2026/27", today=TODAY) is True and s.is_current("SoSe 2026", today=TODAY) is False
    assert s.is_current("SoSe 2027", today=TODAY) is True and s.is_current("Projektkurs", today=TODAY) is None
    # Datum des Semesterendes und unbegrenzte Kurse gehen vor
    assert s.is_current("SoSe 2024", ends_at="2027-03-31T23:59:59+02:00", today=TODAY) is True
    assert s.is_current("WiSe 2026/27", ends_at="2026-03-31", today=TODAY) is False
    assert s.is_current("WiSe 2022/23", semester_end="unbegrenzt", today=TODAY) is True
    assert s.is_current("WiSe 2022/23", semester_end="SoSe 2025", today=TODAY) is False


@pytest.fixture
def courses(app):
    from app import db
    with db.cursor() as conn:
        conn.execute("DELETE FROM courses WHERE id LIKE 'sem-%'")
        conn.execute("DELETE FROM modules WHERE name LIKE 'SEM-%'")
    yield
    with db.cursor() as conn:
        conn.execute("DELETE FROM courses WHERE id LIKE 'sem-%'")
        conn.execute("DELETE FROM modules WHERE name LIKE 'SEM-%'")


def test_upsert_sets_active_by_semester_and_keeps_user_choice(app, courses, monkeypatch):
    from app import db, semesters, studip_sync
    monkeypatch.setattr(study_mod(), "today", lambda: TODAY)
    with db.cursor() as conn:
        studip_sync.upsert_course(conn, {"id": "sem-alt", "title": "SEM-Technische Mechanik II", "number": None, "semester": "SoSe 2023",
                                         "semester_end": "SoSe 2023", "semester_ends_at": "2023-09-30T23:59:59+02:00"}, "2026-10-28T08:00:00")
        studip_sync.upsert_course(conn, {"id": "sem-neu", "title": "SEM-Messtechnik I", "number": None, "semester": "WiSe 2026/27",
                                         "semester_end": "WiSe 2026/27", "semester_ends_at": "2027-03-31T23:59:59+02:00"}, "2026-10-28T08:00:00")
        studip_sync.upsert_course(conn, {"id": "sem-titel", "title": "SEM-Learnweb-Kurs", "number": None, "semester": "SoSe 2026"}, "2026-10-28T08:00:00")
        studip_sync.upsert_course(conn, {"id": "sem-offen", "title": "SEM-Dauerkurs", "number": None, "semester": "WiSe 2022/23", "semester_end": "unbegrenzt"}, "2026-10-28T08:00:00")
        act = {r["id"]: r["active"] for r in db.rows(conn, "SELECT id, active FROM courses WHERE id LIKE 'sem-%'")}
        assert act == {"sem-alt": 0, "sem-neu": 1, "sem-titel": 0, "sem-offen": 1}
        assert db.row(conn, "SELECT semester_end, semester_ends_at FROM courses WHERE id='sem-alt'")["semester_end"] == "SoSe 2023"
        # der Nutzer schaltet den alten Kurs selbst ein: der naechste Abgleich laesst ihn in Ruhe
        conn.execute("UPDATE courses SET active=1, active_custom=1 WHERE id='sem-alt'")
        studip_sync.upsert_course(conn, {"id": "sem-alt", "title": "SEM-Technische Mechanik II", "number": None, "semester": "SoSe 2023",
                                         "semester_end": "SoSe 2023", "semester_ends_at": "2023-09-30T23:59:59+02:00"}, "2026-10-28T09:00:00")
        assert db.row(conn, "SELECT active FROM courses WHERE id='sem-alt'")["active"] == 1


def test_modules_follow_their_courses_and_old_courses_get_no_module(app, courses, monkeypatch):
    from app import db, semesters, study
    monkeypatch.setattr(study_mod(), "today", lambda: TODAY)
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, subject, kind, semester, active, test_minutes, created_at) VALUES ('sem-a1', 'SEM-Alt VL', 'SEM-Altfach', 'vorlesung', 'SoSe 2023', 0, 90, ?)", (db.now_iso(),))
        conn.execute("INSERT INTO courses(id, title, subject, kind, semester, active, test_minutes, created_at) VALUES ('sem-n1', 'SEM-Neu VL', 'SEM-Neufach', 'vorlesung', 'WiSe 2026/27', 1, 90, ?)", (db.now_iso(),))
        study.ensure_modules(conn)
        assert db.row(conn, "SELECT 1 AS x FROM modules WHERE name='SEM-Neufach'") and not db.row(conn, "SELECT 1 AS x FROM modules WHERE name='SEM-Altfach'")
        # ein bestehendes Modul, dessen Kurse alle alt sind, geht aus; von Hand eingeschaltete bleiben
        conn.execute("INSERT INTO modules(name, semester, color, sort, created_at, active) VALUES ('SEM-Altfach', 'SoSe 2023', '#123456', 99, ?, 1)", (db.now_iso(),))
        mid = db.row(conn, "SELECT id FROM modules WHERE name='SEM-Altfach'")["id"]
        conn.execute("UPDATE courses SET module_id=? WHERE id='sem-a1'", (mid,))
        conn.execute("INSERT INTO modules(name, semester, color, sort, created_at, active, active_custom) VALUES ('SEM-Handfach', 'SoSe 2023', '#123457', 98, ?, 1, 1)", (db.now_iso(),))
        hid = db.row(conn, "SELECT id FROM modules WHERE name='SEM-Handfach'")["id"]
        conn.execute("INSERT INTO courses(id, title, subject, kind, semester, active, test_minutes, created_at, module_id) VALUES ('sem-a2', 'SEM-Alt2', 'SEM-Handfach', 'vorlesung', 'SoSe 2023', 0, 90, ?, ?)", (db.now_iso(), hid))
        assert semesters.deactivate_stale_modules(conn) == 1
        assert db.row(conn, "SELECT active FROM modules WHERE id=?", (mid,))["active"] == 0
        assert db.row(conn, "SELECT active FROM modules WHERE id=?", (hid,))["active"] == 1


def test_migration_runs_once(app, courses, monkeypatch):
    from app import db, semesters
    monkeypatch.setattr(study_mod(), "today", lambda: TODAY)
    with db.cursor() as conn:
        conn.execute("DELETE FROM settings WHERE key='semester_rule_applied'")
        conn.execute("INSERT INTO courses(id, title, kind, semester, active, test_minutes, created_at) VALUES ('sem-m1', 'SEM-M1', 'vorlesung', 'WiSe 2023/24', 1, 90, ?)", (db.now_iso(),))
        r = semesters.migrate(conn)
        assert r["courses"] >= 1 and db.row(conn, "SELECT active FROM courses WHERE id='sem-m1'")["active"] == 0
        conn.execute("UPDATE courses SET active=1 WHERE id='sem-m1'")
        assert semesters.migrate(conn) == {"courses": 0, "modules": 0}
        assert db.row(conn, "SELECT active FROM courses WHERE id='sem-m1'")["active"] == 1


def test_fetch_courses_reads_start_and_end_semester():
    from app import studip_sync

    class Resp:
        def __init__(self, data):
            self.data = data

        def json(self):
            return self.data

    class Req:
        def get(self, url, headers=None):
            if url.endswith("/users/me"):
                return Resp({"data": {"id": "u1"}})
            return Resp({"data": [
                {"id": "c-alt", "attributes": {"title": "Alt  Kurs", "course-number": "1"},
                 "relationships": {"start-semester": {"data": {"type": "semesters", "id": "s23"}}, "end-semester": {"data": {"type": "semesters", "id": "s23"}}}},
                {"id": "c-offen", "attributes": {"title": "Dauerkurs"},
                 "relationships": {"start-semester": {"data": {"type": "semesters", "id": "s23"}}, "end-semester": {"data": None}}},
                {"id": "c-neu", "attributes": {"title": "Neu"},
                 "relationships": {"start-semester": {"data": {"type": "semesters", "id": "s26"}}, "end-semester": {"data": {"type": "semesters", "id": "s26"}}}},
            ], "included": [
                {"type": "semesters", "id": "s23", "attributes": {"title": "SoSe 2023", "start": "2023-04-01T00:00:00+02:00", "end": "2023-09-30T23:59:59+02:00"}},
                {"type": "semesters", "id": "s26", "attributes": {"title": "WiSe 2026/27", "start": "2026-10-01T00:00:00+02:00", "end": "2027-03-31T23:59:59+02:00"}},
            ], "links": {}})

    class Page:
        request = Req()

    out = {c["id"]: c for c in studip_sync.fetch_courses(Page())}
    assert out["c-alt"] == {"id": "c-alt", "title": "Alt Kurs", "number": "1", "semester": "SoSe 2023", "semester_end": "SoSe 2023", "semester_ends_at": "2023-09-30T23:59:59+02:00"}
    assert out["c-offen"]["semester_end"] == "unbegrenzt" and out["c-offen"]["semester_ends_at"] is None
    assert out["c-neu"]["semester_ends_at"].startswith("2027-03-31")


class _Fixed(date):
    """date.today() = 28.10.2026 (WiSe 2026/27)."""
    @classmethod
    def today(cls):
        return cls(2026, 10, 28)
