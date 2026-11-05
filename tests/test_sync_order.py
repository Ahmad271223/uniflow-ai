"""Reihenfolge des Abgleichs (Wunsch des Inhabers 05.11.2026, app/sync_order.py, docs/SYNC-REIHENFOLGE-2026-11-05.md):
erst das aktuelle Semester samt Stundenplan, dann Noten und naechstes Semester, fruehere Semester zuletzt im
Hintergrund (neuestes zuerst, gedrosselt, fortsetzbar). Stud.IP als Stub mit 7 Semestern (ein Studierender im 7.
Semester), nie ein echter Abruf."""
import json
from datetime import date

import pytest

from conftest import asgi_call

TODAY = date(2026, 11, 5)                 # WiSe 2026/27 = 7. Semester
TERMS = [  # (Kurs, Titel, Semester, Beginn, Ende)
    ("so-s1", "Vorlesung Mathematik I", "WiSe 2023/24", "2023-10-01", "2024-03-31"),
    ("so-s2", "Vorlesung Mathematik II", "SoSe 2024", "2024-04-01", "2024-09-30"),
    ("so-s3", "Vorlesung Elektrotechnik I", "WiSe 2024/25", "2024-10-01", "2025-03-31"),
    ("so-s4", "Vorlesung Elektrotechnik II", "SoSe 2025", "2025-04-01", "2025-09-30"),
    ("so-s5", "Vorlesung Signale und Systeme", "WiSe 2025/26", "2025-10-01", "2026-03-31"),
    ("so-s6", "Vorlesung Regelungstechnik", "SoSe 2026", "2026-04-01", "2026-09-30"),
    ("so-s7", "Vorlesung Datenstrukturen", "WiSe 2026/27", "2026-10-01", "2027-03-31"),
    ("so-s7b", "Übung Datenstrukturen", "WiSe 2026/27", "2026-10-01", "2027-03-31"),
    ("so-s8", "Bachelorarbeit", "SoSe 2027", "2027-04-01", "2027-09-30"),
]


def _course(cid, title, sem, start, end):
    return {"id": cid, "title": title, "number": None, "semester": sem, "semester_end": sem, "semester_ends_at": end + "T23:59:59+02:00",
            "description": None, "miscellaneous": None, "term": {"title": sem, "start": start + "T00:00:00+02:00", "end": end + "T23:59:59+02:00"}}


@pytest.fixture
def portal(app, monkeypatch, tmp_path):
    """Stud.IP-Stub: merkt sich jeden Abruf in `calls` (Art, Kurs) in Reihenfolge."""
    from app import db, older_semesters, studip_bulletin, studip_extras, studip_sync, studip_texts, study, sync_order, timetable
    monkeypatch.setattr(study, "today", lambda: TODAY)
    monkeypatch.setattr(sync_order, "OLDER_PAUSE_S", 0)
    sync_order.throttle_reset()
    calls: list[tuple[str, str]] = []

    with db.cursor() as conn:
        parked = [r["id"] for r in db.rows(conn, "SELECT id FROM courses WHERE COALESCE(active, 1)=0 AND id NOT LIKE 'so-%'")]
        conn.executemany("UPDATE courses SET active=1 WHERE id=?", [(i,) for i in parked])
        for t in ("older_semester_choice", "older_semester_courses", "sync_stage_state"):
            conn.execute(f"DROP TABLE IF EXISTS {t}")

    class Resp:
        def json(self):
            return {"data": {"id": "u1"}}

    class Req:
        def get(self, url, headers=None):
            calls.append(("me", ""))
            return Resp()

    class Page:
        request = Req()

    class Ctx:
        def new_page(self):
            return Page()

        def cookies(self):
            return []

        def close(self):
            pass

    class Chromium:
        def launch_persistent_context(self, *a, **k):
            return Ctx()

    class PW:
        chromium = Chromium()

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(studip_sync, "sync_playwright", lambda: PW())
    monkeypatch.setattr(studip_sync, "login", lambda page: calls.append(("login", "")))
    monkeypatch.setattr(studip_sync, "log", lambda m: None)
    monkeypatch.setattr(studip_sync, "_files_dir", lambda: tmp_path)
    monkeypatch.setattr(studip_sync.time, "sleep", lambda s: None)
    monkeypatch.setattr(studip_sync, "fetch_courses", lambda page: calls.append(("courses", "")) or [_course(*t) for t in TERMS])
    monkeypatch.setattr(studip_sync, "fetch_schedule_entries", lambda page, uid: calls.append(("schedule", "")) or [])
    monkeypatch.setattr(studip_sync, "fetch_calendar_ids", lambda page, uid: calls.append(("calendar", "")) or [])
    monkeypatch.setattr(studip_sync, "fetch_events", lambda page, cid: calls.append(("events", cid)) or [])
    monkeypatch.setattr(studip_sync, "fetch_news", lambda page, cid: calls.append(("news", cid)) or None)
    monkeypatch.setattr(studip_sync, "fetch_files", lambda page, cid: calls.append(("files", cid)) or [
        {"id": f"{cid}-f", "name": f"{cid}.pdf", "size": 4, "mime": "application/pdf", "author": None, "chdate": 1,
         "download_url": f"https://studip.example/{cid}", "folder": None}])
    monkeypatch.setattr(studip_sync, "fetch_folder_paths", lambda page, cid: {})

    def dl(page, url, target, size=0):
        calls.append(("download", url.rsplit("/", 1)[-1]))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF")

    monkeypatch.setattr(studip_sync, "download", dl)
    monkeypatch.setattr(timetable, "store_calendar", lambda conn, ids, fetched_at=None: True)
    monkeypatch.setattr(timetable, "auto_import", lambda conn: calls.append(("timetable", "")) or {"new": 2})
    monkeypatch.setattr(studip_extras, "sync", lambda *a, **k: calls.append(("extras", "")) or {})
    monkeypatch.setattr(studip_bulletin, "sync_allowed", lambda: False)
    monkeypatch.setattr(studip_texts, "run", lambda *a, **k: calls.append(("texts", "")) or {"texts": 0, "deadlines": 0, "requests": 0})
    yield calls
    with db.cursor() as conn:
        conn.executemany("UPDATE courses SET active=0 WHERE id=?", [(i,) for i in parked])
        conn.execute("DELETE FROM files WHERE course_id LIKE 'so-%'")
        conn.execute("UPDATE courses SET module_id=NULL WHERE id LIKE 'so-%'")
        conn.execute("DELETE FROM courses WHERE id LIKE 'so-%'")
        for t in ("older_semester_choice", "older_semester_courses", "sync_stage_state"):
            conn.execute(f"DROP TABLE IF EXISTS {t}")
    assert older_semesters.CHOICES                    # Modul geladen


OLDER = ["so-s6", "so-s5", "so-s4", "so-s3", "so-s2", "so-s1"]


def _first(calls, pred):
    return next(i for i, c in enumerate(calls) if pred(c))


def test_first_sync_loads_the_current_semester_before_anything_older(portal):
    from app import db, studip_sync, sync_order
    res = studip_sync.run_studip_sync()
    assert res["ok"], res
    calls = portal
    asked = [cid for kind, cid in calls if kind in ("events", "files", "news")]
    assert not set(asked) & set(OLDER), "der volle Lauf fragt kein frueheres Semester ab"
    # (a) vor (c): Stundenplan und aktuelle Kurse samt Dateien, dann das naechste Semester
    timetable = _first(calls, lambda c: c[0] == "timetable")
    cur_files = [i for i, c in enumerate(calls) if c[0] == "files" and c[1] in ("so-s7", "so-s7b")]
    cur_downloads = [i for i, c in enumerate(calls) if c[0] == "download" and c[1] in ("so-s7", "so-s7b")]
    upcoming = _first(calls, lambda c: c[1] == "so-s8")
    assert max(cur_files) < timetable < min(cur_downloads), "Stundenplan gleich nach den Listen, vor den Downloads"
    assert max(cur_downloads) < upcoming, "naechstes Semester erst nach dem aktuellen"
    with db.cursor() as conn:
        st = sync_order.status(conn)
    assert st["current"] == {"key": [2026, 2], "label": "WiSe 2026/27", "ready": True, "ready_at": st["current"]["ready_at"]}
    assert st["older"]["mode"] == "wifi" and (st["older"]["total"], st["older"]["done"], st["older"]["pending"]) == (6, 0, 6)
    assert st["hint"] == "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (0 von 6)"


def test_older_semesters_follow_newest_first_and_resume(portal, monkeypatch):
    from app import db, studip_sync, sync_order
    assert studip_sync.run_studip_sync()["ok"]
    portal.clear()
    # Stufe (d) haelt nach drei Semestern an (ein voller Abgleich wartet) ...
    seen = {"n": 0}

    def cont(pause=None):
        seen["n"] += 1
        return seen["n"] < 3

    monkeypatch.setattr(sync_order, "older_continue", cont)
    assert sync_order.run_older_now(run=studip_sync.run_studip_older_files)["ok"]
    assert [cid for kind, cid in portal if kind == "files"] == OLDER[:3], "neuestes Semester zuerst"
    with db.cursor() as conn:
        st = sync_order.status(conn)
    assert st["hint"] == "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (3 von 6)"
    # ... und macht beim naechsten Mal dort weiter, ohne Geladenes erneut abzufragen
    portal.clear()
    monkeypatch.setattr(sync_order, "older_continue", lambda pause=None: True)
    assert sync_order.run_older_now(run=studip_sync.run_studip_older_files)["ok"]
    assert [cid for kind, cid in portal if kind == "files"] == OLDER[3:]
    assert not [c for c in portal if c[0] in ("events", "timetable", "news")], "Stufe (d): nur Dateien, kein Stundenplan"
    with db.cursor() as conn:
        st = sync_order.status(conn)
        assert (st["older"]["done"], st["older"]["pending"], st["hint"]) == (6, 0, None)
        assert sync_order.run_older_now(run=studip_sync.run_studip_older_files) is None, "nichts mehr zu tun"


def test_mode_off_keeps_older_semesters_until_requested(portal, app):
    from app import db, older_semesters, studip_sync, sync_order
    st, _, body = asgi_call(app, "POST", "/api/older-semesters/mode", body=json.dumps({"mode": "off"}))
    assert st == 200 and json.loads(body) == {"mode": "off", "started": False}
    assert asgi_call(app, "POST", "/api/older-semesters/mode", body=json.dumps({"mode": "immer"}))[0] == 422
    assert studip_sync.run_studip_sync()["ok"]
    with db.cursor() as conn:
        assert older_semesters.pending(conn) == set()
        assert sync_order.status(conn)["hint"] is None, "Aus: kein Hinweis auf Hintergrundladen"
        older_semesters.request(conn, ["so-s3"], "2026-11-05T10:00:00")
    portal.clear()
    assert sync_order.run_older_now(run=studip_sync.run_studip_older_files)["ok"]
    assert [cid for kind, cid in portal if kind == "files"] == ["so-s3"]


def test_policy_pauses_for_low_power_wifi_and_closed_app(portal):
    from app import db, older_semesters, sync_order
    with db.cursor() as conn:
        assert sync_order.older_allowed(conn) == (True, None)
        assert sync_order.older_allowed(conn, low_power=True) == (False, "low_power")
        assert sync_order.older_allowed(conn, on_wifi=False) == (False, "wifi")
        assert sync_order.older_allowed(conn, app_open=False) == (False, "closed")
        older_semesters.set_mode(conn, "auto", "2026-11-05T10:00:00")
        assert sync_order.older_allowed(conn, on_wifi=False) == (True, None), "Automatisch auch ohne WLAN"
    assert sync_order.hint_text(True, "wifi", {"total": 6, "done": 2, "pending": 4}, paused="low_power") == \
        "Aktuelles Semester ist da · ältere Semester pausiert (Stromsparmodus) (2 von 6)"
    assert sync_order.hint_text(False, "wifi", {"total": 6, "done": 0, "pending": 6}) == "Aktuelles Semester wird geladen …"


def test_modules_by_semester_groups_all_terms(portal, app):
    from app import studip_sync
    assert studip_sync.run_studip_sync()["ok"]
    st, _, body = asgi_call(app, "GET", "/api/module-semesters")
    assert st == 200
    d = json.loads(body)
    mods = {m["id"]: m for m in json.loads(asgi_call(app, "GET", "/api/modules")[2])}
    cur_names = {mods[i]["name"] for i in d["current"]["module_ids"]}
    assert "Datenstrukturen" in cur_names and d["current"]["label"] == "WiSe 2026/27"
    assert [g["label"] for g in d["upcoming"]] == ["SoSe 2027"]
    labels = [g["label"] for g in d["older"]]
    assert labels[:6] == ["SoSe 2026", "WiSe 2025/26", "SoSe 2025", "WiSe 2024/25", "SoSe 2024", "WiSe 2023/24"], "neuestes zuerst"
    s6 = d["older"][0]
    assert s6["count"] == 1 and s6["items"][0]["name"] == "Regelungstechnik" and s6["items"][0]["course_ids"] == ["so-s6"]
    assert s6["items"][0]["files"] == 0 and s6["loaded"] is False, "Dateien fruehere Semester kommen erst in Stufe (d)"
    assert d["status"]["hint"].startswith("Aktuelles Semester ist da")


def test_current_term_uses_portal_terms_then_university_dates():
    from app import sync_order
    terms = [{"title": "WiSe 2026/27", "start": "2026-09-01", "end": "2027-02-28"}, {"title": "SoSe 2026", "start": "2026-03-01", "end": "2026-08-31"}]
    assert sync_order.current_term(date(2026, 9, 15), terms, "luh") == (2026, 2), "Semesterliste des Portals vor dem Datum"
    assert sync_order.current_term(date(2026, 9, 15), [], "luh") == (2026, 1), "LUH: WiSe ab Oktober"
    assert sync_order.current_term(date(2026, 9, 15), [], "hsh") == (2026, 2), "HsH: WiSe ab September"
    assert sync_order.current_term(date(2027, 2, 10), [], "hsh") == (2026, 2)
    assert sync_order.current_term(date(2026, 3, 2), [], "hsh") == (2026, 1)
    assert sync_order.term_key("20262") == (2026, 2) and sync_order.term_key("20261") == (2026, 1), "LSF-Semesterkennung"
    assert sync_order.term_key("WS 26/27") == (2026, 2)


def test_run_stages_orders_by_priority_and_survives_errors():
    from app import sync_order
    seen, ready = [], []

    def boom():
        raise RuntimeError("weg")
    steps = [("older", "alt", lambda: seen.append("older")), ("grades", "noten", lambda: seen.append("grades")),
             ("current", "plan", lambda: seen.append("plan")), ("upcoming", "next", lambda: seen.append("upcoming")),
             ("current", "dateien", boom)]
    out = sync_order.run_stages(steps, on_stage=ready.append)
    assert seen == ["plan", "grades", "upcoming", "older"]
    assert [s for s, _, _ in out] == ["current", "current", "grades", "upcoming", "older"]
    assert ("current", "dateien", False) in out and ready == ["current", "grades", "upcoming", "older"]


def test_routes_are_registered(app):
    from app import sync_order_api
    assert {r.path for r in sync_order_api.router.routes} == {"/api/sync-order", "/api/module-semesters"}
