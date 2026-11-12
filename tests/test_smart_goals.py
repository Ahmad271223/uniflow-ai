"""Smart Planner 2.0 ueber die Endpunkte (app/smart_goals.py): Lernziele, Lernzeit, Plan anwenden, Neuplanung,
Doppelstart, Geraete-Doppel, Material, Rechte. Feste Uhr: Montag, 16.11.2026, 08:00 (Berlin). Alle Werte erfunden."""
import json
import threading
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from conftest import asgi_call

BERLIN = ZoneInfo("Europe/Berlin")


class Clock:
    def __init__(self):
        self.t = datetime(2026, 11, 16, 8, 0, tzinfo=BERLIN)

    def today(self):
        return self.t.date()

    def now(self):
        return self.t

    def advance(self, **kw):
        self.t += timedelta(**kw)


@pytest.fixture()
def env(app, tmp_path, monkeypatch):
    from app import db, smart_goals, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "smart.db")
    db.init_db()
    clock = Clock()
    monkeypatch.setattr(study, "today", clock.today)
    monkeypatch.setattr(smart_goals, "now", clock.now)
    return app, clock


def call(app, method, path, body=None):
    status, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    return status, json.loads(raw) if raw else None


def module(name, exam=None, course=None, sort=0):
    from app import db
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, exam_date, created_at) VALUES (?, '#336699', ?, ?, '2026-10-01T09:00:00')",
                           (name, sort, exam)).lastrowid
        if course:
            conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, active, created_at) VALUES (?, ?, ?, 'vorlesung', ?, 1, '2026-10-01')",
                         (course, name, name, mid))
    return mid


def blocks(mid=None):
    from app import db
    with db.cursor() as conn:
        sql = "SELECT * FROM study_packages WHERE source='smart'"
        return db.rows(conn, sql + (" AND module_id=?" if mid else "") + " ORDER BY date, start_time", (mid,) if mid else ())


def three():
    """Mathematik 200 h, Programmieren 250 h, Elektrotechnik 220 h; Klausuren nach Woche 10, 12, 14"""
    mon = date(2026, 11, 16)
    ids = []
    for i, (name, h, w) in enumerate((("Mathematik", 200, 10), ("Programmieren", 250, 12), ("Elektrotechnik", 220, 14))):
        mid = module(name, (mon + timedelta(weeks=w)).isoformat(), sort=i)
        ids.append(mid)
    return ids


def goals(app, ids, hours=(200, 250, 220)):
    for mid, h in zip(ids, hours):
        st, g = call(app, "PUT", f"/api/goals/{mid}", {"target_hours": h})
        assert st == 200 and g["target_minutes"] == h * 60


# ------------------------------------------------------------------ Einstellungen und Eingaben

def test_einstellungen_vorgaben_und_pruefung(env):
    app, _ = env
    st, s = call(app, "GET", "/api/goals/settings")
    assert st == 200 and s["sleep_hours"] == 10 and s["bedtime_hm"] == "23:00" and s["utilization"] == 60
    for bad in ({"sleep_hours": 3}, {"sleep_hours": "zehn"}, {"utilization": 0}, {"bedtime": "25:00"},
                {"commitments": [{"weekday": 7, "start": "10:00", "end": "11:00"}]},
                {"commitments": [{"weekday": 1, "start": "12:00", "end": "11:00"}]}, {"min_block": 90, "max_block": 60}):
        st, r = call(app, "PUT", "/api/goals/settings", bad)
        assert st == 400, bad
    st, s = call(app, "PUT", "/api/goals/settings", {"sleep_hours": 8.5, "utilization": 75,
                                                     "commitments": [{"weekday": 2, "start": "16:00", "end": "20:00", "kind": "arbeit"}]})
    assert st == 200 and s["sleep_minutes"] == 510 and s["utilization"] == 75 and s["commitments"][0]["title"] == "Arbeit"


def test_ungueltige_ziele(env):
    app, _ = env
    mid = module("Analysis")
    assert call(app, "PUT", "/api/goals/99999", {"target_hours": 10})[0] == 404
    for bad in ({"target_hours": -1}, {"target_hours": "viel"}, {"target_hours": 5000}, {"writing": "ja"},
                {"exam_attempt": 3}, {"exam_attempt": 2}, {"exam_date_2": "31.02.2027"}, {"priority": 9}):
        assert call(app, "PUT", f"/api/goals/{mid}", bad)[0] == 400, bad
    st, g = call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 200.5})          # Teilstunden
    assert st == 200 and g["target_minutes"] == 12030
    assert call(app, "POST", "/api/goals/plan", {"accept_partial": "ja"})[0] == 400


# ------------------------------------------------------------------ Pflichtbeispiel

def test_drei_klausuren_unterdeckung_dann_teilplan(env):
    app, _ = env
    ids = three()
    goals(app, ids)
    # 25 h je Woche: Montag bis Freitag 5 h (09:00-14:00), Rest gesperrt; Wochenende frei
    call(app, "PUT", "/api/settings", {"free_days": [5, 6]})
    call(app, "PUT", "/api/goals/settings", {"utilization": 100, "bedtime": "23:00", "sleep_hours": 10, "leisure_minutes": 540})
    st, o = call(app, "GET", "/api/goals")
    assert st == 200 and o["plan"]["status"] == "unterdeckt"
    assert o["plan"]["message"] == "670 h nötig, 350 h verfügbar, fehlen 320 h"
    assert not o["planned"] and blocks() == []
    st, r = call(app, "POST", "/api/goals/plan", {})
    assert st == 200 and r["applied"] is False and blocks() == []          # kein scheinbar vollstaendiger Plan
    kinds = {x["kind"] for x in r["result"]["options"]}
    assert {"ziele", "teilplan", "freizeit"} <= kinds and "nutzungsquote" not in kinds
    st, r = call(app, "POST", "/api/goals/plan", {"accept_partial": True})
    assert r["applied"] is True and r["result"]["status"] == "teilplan"
    bl = blocks()
    assert sum(int(b["planned_minutes"]) for b in bl) == 350 * 60
    exams = {m: e for m, e in zip(ids, ("2027-01-25", "2027-02-08", "2027-02-22"))}
    assert all(b["date"] < exams[b["module_id"]] for b in bl)
    assert all("09:00" <= b["start_time"] and b["end_time"] <= "14:00" for b in bl)


def test_machbarer_plan_erscheint_im_kalender_neben_vorlesungen(env):
    app, _ = env
    ids = three()
    goals(app, ids, (60, 80, 70))
    from app import db
    with db.cursor() as conn:
        conn.execute("""INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, attend, created_at)
                        VALUES (?, 'Mathe-VL', 'vorlesung', 1, '10:00', '12:00', 'weekly', 1, '2026-10-01')""", (ids[0],))
    st, r = call(app, "POST", "/api/goals/plan", {})
    assert st == 200 and r["applied"] and r["result"]["status"] == "ok"
    st, cal = call(app, "GET", "/api/calendar?start=2026-11-17&end=2026-11-17")
    day = cal["days"][0]
    smart = [p for p in day["packages"] if p["source"] == "smart"]
    assert smart, "Lernbloecke am Dienstag"
    for p in smart:
        assert not (p["start_time"] < "12:30" and p["end_time"] > "09:30"), "Block ueber Vorlesung samt Fahrtzeit"
        assert "09:00" <= p["start_time"] and p["end_time"] <= "21:00"          # Schlaf und Freizeit
    st, o = call(app, "GET", "/api/goals")
    m = {x["module_id"]: x for x in o["modules"]}
    assert m[ids[0]]["stats"]["status"] == "auf_kurs" and m[ids[0]]["stats"]["remaining_minutes"] == 60 * 60
    assert o["next_exam"]["module_id"] == ids[0] and o["next_exam"]["days"] == 70
    assert o["week"]["planned_minutes"] > 0


# ------------------------------------------------------------------ Lernzeit

def test_stoppuhr_eintrag_doppelbuchung_und_korrektur(env):
    app, clock = env
    mid = module("Programmieren", "2027-02-08")
    call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 100, "learned_before_hours": 2})
    st, s = call(app, "POST", "/api/sessions/start", {"uuid": "timer-aaaa-1", "module_id": mid})
    assert st == 200 and s["state"] == "laeuft"
    clock.advance(minutes=30)
    call(app, "POST", "/api/sessions/timer-aaaa-1/pause")
    clock.advance(minutes=20)                                                     # Pause zaehlt nicht
    call(app, "POST", "/api/sessions/timer-aaaa-1/resume")
    clock.advance(minutes=15)
    st, s = call(app, "POST", "/api/sessions/timer-aaaa-1/stop")
    assert s["state"] == "fertig" and s["credited_minutes"] == 45
    # dieselbe Lerneinheit von einem zweiten Geraet noch einmal gemeldet: zaehlt einmal
    assert call(app, "POST", "/api/sessions/start", {"uuid": "timer-aaaa-1", "module_id": mid})[1]["state"] == "fertig"
    # nachtraeglich eingetragene Zeit, die die Stoppuhr ueberlappt: zaehlt nur einmal
    a = int(datetime(2026, 11, 16, 8, 0, tzinfo=BERLIN).timestamp())
    st, x = call(app, "POST", "/api/sessions", {"uuid": "eintrag-bbbb-2", "module_id": mid, "start": a, "end": a + 3600})
    assert st == 200
    st, o = call(app, "GET", "/api/goals")
    m = o["modules"][0]
    assert m["credited_minutes"] == 65 and m["stats"]["learned_minutes"] == 65 + 120     # 08:00-09:00 + 09:20-09:25... einmal
    # Zukunft, zu lang, falsche Werte
    assert call(app, "POST", "/api/sessions", {"module_id": mid, "start": a + 99999, "end": a + 100000})[0] == 400
    assert call(app, "POST", "/api/sessions", {"module_id": mid, "minutes": 0})[0] == 400
    assert call(app, "POST", "/api/sessions", {"module_id": mid, "minutes": 30, "day": "2026-12-24"})[0] == 400
    assert call(app, "POST", "/api/sessions", {"module_id": 4242, "minutes": 30})[0] == 404
    # Korrektur: die Stoppuhr lief versehentlich weiter, wirklich gelernt 30 min
    st, s = call(app, "PATCH", "/api/sessions/timer-aaaa-1", {"minutes": 30})
    assert s["kind"] == "manual" and s["credited_minutes"] == 30
    assert call(app, "DELETE", "/api/sessions/eintrag-bbbb-2")[0] == 200
    st, o = call(app, "GET", "/api/goals")
    assert o["modules"][0]["credited_minutes"] == 30
    assert call(app, "POST", "/api/sessions/nicht-da-123/stop")[0] == 404


def test_abgehakter_block_zaehlt_nur_mit_minuten(env):
    app, clock = env
    mid = module("Elektrotechnik", "2027-02-22")
    call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 40})
    call(app, "POST", "/api/goals/plan", {})
    today = [b for b in blocks(mid) if b["date"] == "2026-11-16"]
    assert today, "heute ab jetzt geplant"
    b = today[0]
    assert call(app, "POST", f"/api/goals/blocks/{b['id']}/done", {})[0] == 400             # ohne Minuten
    st, r = call(app, "POST", f"/api/goals/blocks/{b['id']}/done", {"minutes": 40})
    assert r["status"] == "erledigt"
    st, r = call(app, "POST", f"/api/goals/blocks/{b['id']}/done", {"minutes": 25})          # zweiter Haken ersetzt
    st, o = call(app, "GET", "/api/goals")
    assert o["modules"][0]["credited_minutes"] == 25
    fut = [x for x in blocks(mid) if x["date"] > "2026-11-16"][0]
    assert call(app, "POST", f"/api/goals/blocks/{fut['id']}/done", {"minutes": 10})[0] == 400  # Zukunft
    call(app, "POST", f"/api/goals/blocks/{b['id']}/undone")
    st, o = call(app, "GET", "/api/goals")
    assert o["modules"][0]["credited_minutes"] == 0


# ------------------------------------------------------------------ Neuplanung

def test_ziel_erhoeht_klausur_verschoben_gesperrt_und_manuell_bleiben(env):
    app, clock = env
    ids = three()
    goals(app, ids, (30, 40, 30))
    call(app, "POST", "/api/goals/plan", {})
    before = blocks()
    locked = [b for b in before if b["date"] > "2026-11-18"][0]
    moved = [b for b in before if b["date"] > "2026-11-20" and b["id"] != locked["id"]][0]
    assert call(app, "PATCH", f"/api/goals/blocks/{locked['id']}", {"locked": True})[0] == 200
    st, p = call(app, "PATCH", f"/api/packages/{moved['id']}", {"start_time": "06:00", "end_time": "07:00"})
    assert st == 200 and p["manual"] == 1
    # Ziel leicht erhoeht -> wenige Aenderungen: sofort angepasst
    call(app, "PUT", f"/api/goals/{ids[2]}", {"target_hours": 31})
    st, o = call(app, "GET", "/api/goals")
    assert o["proposal"] is None and o["last_change"]["added"] >= 1
    # Klausur Mathematik zwei Wochen frueher -> grosse Umplanung: erst Vorschlag, Bloecke bleiben
    from app import db
    with db.cursor() as conn:
        conn.execute("UPDATE modules SET exam_date='2027-01-11' WHERE id=?", (ids[0],))
    n = len(blocks())
    st, o = call(app, "GET", "/api/goals")
    assert o["proposal"]["kind"] == "umplanung" and len(blocks()) == n
    st, r = call(app, "POST", "/api/goals/plan", {})
    assert r["applied"]
    after = {b["id"]: b for b in blocks()}
    assert after[locked["id"]]["date"] == locked["date"] and after[locked["id"]]["start_time"] == locked["start_time"]
    assert after[moved["id"]]["start_time"] == "06:00"
    assert all(b["date"] < "2027-01-11" for b in blocks(ids[0]) if not b["locked"] and not b["manual"])
    st, o = call(app, "GET", "/api/goals")
    assert o["proposal"] is None
    # gesperrter Block nach der Klausur: Konflikt, nicht verschoben
    with db.cursor() as conn:
        conn.execute("UPDATE study_packages SET date='2027-01-20', module_id=? WHERE id=?", (ids[0], locked["id"]))
    st, o = call(app, "GET", "/api/goals")
    assert any(c["kind"] == "klausur" and c["package_id"] == locked["id"] for c in o["conflicts"])
    assert {b["id"]: b for b in blocks()}[locked["id"]]["date"] == "2027-01-20"


def test_geloeschter_block_wird_neu_verteilt(env):
    app, clock = env
    mid = module("Mathematik", "2027-01-25")
    call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 20})
    call(app, "POST", "/api/goals/plan", {})
    call(app, "GET", "/api/goals")
    fut = [b for b in blocks(mid) if b["date"] > "2026-11-20"]
    assert call(app, "DELETE", f"/api/packages/{fut[0]['id']}")[0] == 200
    st, o = call(app, "GET", "/api/goals")
    assert sum(int(b["planned_minutes"]) for b in blocks(mid)) == 20 * 60, "geloeschte Zeit wieder eingeplant"
    n = len(blocks(mid))
    for _ in range(3):                                                              # danach steht der Plan still
        call(app, "GET", "/api/goals")
    assert len(blocks(mid)) == n and call(app, "GET", "/api/goals")[1]["proposal"] is None


def test_verpasste_bloecke_werden_nachgeplant(env):
    app, clock = env
    mid = module("Mathematik", "2027-01-25")
    call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 20})
    call(app, "POST", "/api/goals/plan", {})
    first = [b for b in blocks(mid) if b["date"] <= "2026-11-17"]
    assert first
    clock.advance(days=2)
    st, o = call(app, "GET", "/api/goals")
    old = {b["id"]: b for b in blocks(mid)}
    assert all(old[b["id"]]["status"] == "verpasst" for b in first)
    fut = sum(int(b["planned_minutes"]) for b in blocks(mid) if b["date"] >= "2026-11-18" and b["status"] == "geplant")
    assert fut == 20 * 60, "verpasste Zeit wieder eingeplant"


def test_klausur_entfernt_und_ziel_erreicht(env):
    app, clock = env
    a = module("Mathematik", "2027-01-25", sort=0)
    b = module("Programmieren", "2027-02-08", sort=1)
    call(app, "PUT", f"/api/goals/{a}", {"target_hours": 10})
    call(app, "PUT", f"/api/goals/{b}", {"target_hours": 10, "learned_before_hours": 12})
    call(app, "POST", "/api/goals/plan", {})
    assert blocks(b) == []                                                         # Ziel schon erreicht
    st, o = call(app, "GET", "/api/goals")
    assert {m["module_id"]: m["stats"]["status"] for m in o["modules"]}[b] == "erreicht"
    call(app, "PUT", f"/api/goals/{a}", {"writing": False})                        # schreibe ich nicht
    st, o = call(app, "GET", "/api/goals")
    assert [x for x in blocks(a) if x["date"] > "2026-11-16"] == []


def test_doppelt_gestartete_neuplanung_plant_einmal(env):
    app, clock = env
    ids = three()
    goals(app, ids, (30, 40, 30))
    call(app, "POST", "/api/goals/plan", {})
    call(app, "PUT", f"/api/goals/{ids[1]}", {"target_hours": 41})
    res = []
    threads = [threading.Thread(target=lambda: res.append(call(app, "GET", "/api/goals")[0])) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert res == [200] * 4
    bl = blocks()
    keys = [(b["module_id"], b["date"], b["start_time"]) for b in bl]
    assert len(keys) == len(set(keys)), "keine doppelten Bloecke"
    assert sum(int(b["planned_minutes"]) for b in bl if b["module_id"] == ids[1]) == 41 * 60


def test_zwei_geraete_doppelte_bloecke_und_lernzeit_werden_zusammengefuehrt(env):
    app, clock = env
    mid = module("Mathematik", "2027-01-25")
    call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 10})
    call(app, "POST", "/api/goals/plan", {})
    from app import db
    bl = blocks(mid)
    with db.cursor() as conn:                                                     # was der Abgleich vom zweiten Geraet bringt
        for b in bl[:3]:
            conn.execute("""INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, status, sort, generated, created_at,
                                                       start_time, end_time, source) VALUES (?,?,?,?,?,'geplant',0,1,'x',?,?,'smart')""",
                         (b["date"], mid, b["subject"], b["title"], b["planned_minutes"], b["start_time"], b["end_time"]))
        a = int(datetime(2026, 11, 16, 7, 0, tzinfo=BERLIN).timestamp())
        for u in ("geraet-a-0001", "geraet-b-0001"):                              # dieselbe Stunde auf zwei Geraeten gemessen
            conn.execute("""INSERT INTO study_sessions(uuid, module_id, kind, state, segments, day, created_at, updated_at)
                            VALUES (?,?, 'timer', 'fertig', ?, '2026-11-16', 'x', 'x')""", (u, mid, json.dumps([[a, a + 3600]])))
    st, o = call(app, "GET", "/api/goals")
    assert o["modules"][0]["credited_minutes"] == 60                              # einmal, nicht zweimal
    after = blocks(mid)
    keys = [(b["date"], b["start_time"]) for b in after]
    assert len(keys) == len(set(keys)), "keine doppelten Bloecke"
    assert sum(int(b["planned_minutes"]) for b in after if b["status"] == "geplant") == 9 * 60    # 10 h Ziel - 1 h gelernt


def test_neue_unterlagen_kommen_ins_budget_ueberschuss_ist_konflikt(env):
    app, clock = env
    mid = module("Programmieren", "2026-12-07", course="kp")
    from app import db
    week1 = int(datetime(2026, 11, 16, 10).timestamp())
    with db.cursor() as conn:
        conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES ('blatt1', 'kp', 'Blatt 1.pdf', ?, 'Übungsblätter')", (week1,))
    call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 3})
    call(app, "PUT", "/api/goals/settings", {"utilization": 20})
    call(app, "POST", "/api/goals/plan", {})
    st, o = call(app, "GET", "/api/goals")
    with db.cursor() as conn:
        tasks = db.rows(conn, "SELECT t.*, p.source FROM study_tasks t JOIN study_packages p ON p.id=t.package_id")
    assert {t["file_id"] for t in tasks} == {"blatt1"} and sum(t["est_minutes"] for t in tasks) == 60 and tasks[0]["source"] == "smart"
    # viele neue Unterlagen (KI-Analyse fehlgeschlagen: keine Dauer -> Vorgabe je Art), Budget waechst nicht
    with db.cursor() as conn:
        for i in range(2, 12):
            conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, 'kp', ?, ?, 'Übungsblätter')",
                         (f"blatt{i}", f"Blatt {i}.pdf", week1 + 3600 * i))
    st, o = call(app, "GET", "/api/goals")
    budget = sum(int(b["planned_minutes"]) for b in blocks(mid))
    with db.cursor() as conn:
        used = db.row(conn, "SELECT COALESCE(SUM(est_minutes),0) n FROM study_tasks")["n"]
    assert used <= budget == 3 * 60
    assert any(c["kind"] == "material" for c in o["conflicts"])


def test_konfliktpruefung_beim_verschieben(env):
    app, clock = env
    mid = module("Mathematik", "2026-12-07")
    call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 10})
    from app import db
    with db.cursor() as conn:
        conn.execute("""INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, attend, created_at)
                        VALUES (?, 'Mathe-VL', 'vorlesung', 2, '10:00', '12:00', 'weekly', 1, '2026-10-01')""", (mid,))
    call(app, "POST", "/api/goals/plan", {})
    b = blocks(mid)[0]
    st, r = call(app, "POST", f"/api/goals/blocks/{b['id']}/check", {"date": "2026-11-18", "start": "11:00"})
    assert st == 200 and any(c["kind"] == "termin" for c in r["conflicts"])
    st, r = call(app, "POST", f"/api/goals/blocks/{b['id']}/check", {"date": "2026-12-08", "start": "15:00"})
    assert any(c["kind"] == "klausur" for c in r["conflicts"])
    st, r = call(app, "POST", f"/api/goals/blocks/{b['id']}/check", {"date": "2026-11-18", "start": "07:00"})
    assert r["conflicts"] == []


def test_kein_ki_aufruf_beim_oeffnen_und_verschieben(env, monkeypatch):
    app, clock = env
    from app import ai, planner

    def boom(*a, **k):
        raise AssertionError("KI aufgerufen")
    for mod in (ai, planner):
        for name in dir(mod):
            if callable(getattr(mod, name)) and not name.startswith("_") and getattr(getattr(mod, name), "__module__", "") == mod.__name__:
                monkeypatch.setattr(mod, name, boom)
    ids = three()
    goals(app, ids, (20, 20, 20))
    assert call(app, "POST", "/api/goals/plan", {})[0] == 200
    assert call(app, "GET", "/api/goals")[0] == 200
    b = blocks()[3]
    assert call(app, "PATCH", f"/api/packages/{b['id']}", {"date": "2026-11-25"})[0] == 200
    assert call(app, "GET", "/api/calendar?start=2026-11-16&end=2026-11-22")[0] == 200
