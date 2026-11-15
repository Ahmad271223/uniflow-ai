"""Zwei Geraete eines Kontos planen dieselbe Woche: die automatischen Lernpakete gibt es danach nur einmal
(app/plan_merge.py, docs/PLANER-KEINE-DOPPELPLANUNG.md). Fehler vom echten iPhone vom 14.11.2026: an einem Tag vier
Pakete, dieselbe Datei in zwei Paketen, ein Teil lokal erzeugt, ein Teil ueber den Geraete-Abgleich gekommen.

- Ursache nachgestellt mit zwei Geraeten gegen den Dienst (Windows-App mit eigener Datenbank und ein "iPad", das den
  Dienst direkt anspricht, wie tests/test_sync_client.py): ohne Zusammenfuehren stehen beide Planungen nebeneinander.
- Regeln an der gemeinsamen Abgleichsdatei plan-merge.json (Swift: StudyPlanMergeTests). Alle Werte erfunden."""
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

import pytest

from test_sync_client import FILE, ipad_pull, ipad_push, two_devices  # noqa: F401  (Fixture)

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "plan-merge.json"
TODAY = date(2026, 11, 16)          # Montag
WED, THU = "2026-11-18", "2026-11-19"


def _case(name: str) -> dict:
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    return next(c for c in fx["cases"] if c["name"] == name)


def _files(case: dict) -> list:
    return sorted((t["file_id"], t["package_id"]) for t in case["study_tasks"] if t["file_id"])


# ---------------------------------------------------------------- gemeinsame Abgleichsdatei

def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-plan-merge-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_every_case_is_stable_after_the_first_run():
    """Ein zweiter Lauf aendert nichts: kein Hin und Her auf einem Geraet"""
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    assert len(fx["cases"]) >= 17
    for c in fx["cases"]:
        assert c["again"] == {"tasks": 0, "packages": 0, "empty": 0, "moved": 0}, c["name"]


def test_account_planning_wins_over_the_unsent_own_one():
    c = _case("anderer_tag")
    assert c["result"] == {"tasks": 2, "packages": 1, "empty": 0, "moved": 0}
    assert [(p["id"], p["date"]) for p in c["study_packages"]] == [(1, WED)], "die Planung des Kontos bleibt, wie sie ist"
    assert _files(c) == [("datei-ue", 1), ("datei-vl", 1)], "jede Datei genau einmal"


def test_two_devices_seeing_the_same_rows_remove_the_same_one():
    """Kein Hin und Her mit Loeschmarken: die Wahl haengt nur an abgeglichenen, unveraenderlichen Werten"""
    c = _case("beide_im_konto")
    assert [p["id"] for p in c["study_packages"]] == [2] and ["study_packages", "1"] in c["tombstones"], "frueher geplant bleibt"
    c = _case("gleiche_sekunde")
    assert [p["id"] for p in c["study_packages"]] == [2], "gleiche Sekunde: kleinere Nummer im Dienst (107), hier die groessere lokale"


def test_nothing_touched_by_the_user_is_ever_removed():
    c = _case("angefasst_bleibt")
    kept = {p["id"] for p in c["study_packages"]}
    assert kept == {2, 4, 6, 8, 9, 10, 12, 14}
    by = {t["id"]: t for t in c["study_tasks"]}
    assert by[2]["status"] == "erledigt" and by[2]["actual_minutes"] == 50
    assert by[4]["status"] == "in_bearbeitung" and by[6]["moved_from"] == "2026-11-17" and by[12]["steps_done"] == "[0]"
    assert {9, 10} <= kept, "beide angefasst: beide bleiben"
    for name in ("eigenes_bleibt_liegen", "leeres_paket"):
        own = [p for p in _case(name)["study_packages"] if p["generated"] == 0]
        assert own and all(p["start_time"] for p in own), "von Hand angelegt: Tag und Uhrzeit bleiben"


def test_only_the_double_part_goes_and_nothing_is_lost():
    c = _case("teilmenge")
    assert c["result"]["tasks"] == 2 and c["result"]["packages"] == 0
    assert _files(c) == [("datei-neu", 2), ("datei-ue", 1), ("datei-vl", 1)]
    rest = next(p for p in c["study_packages"] if p["id"] == 2)
    assert (rest["planned_minutes"], rest["start_time"], rest["end_time"]) == (45, "10:15", "11:00")


def test_older_app_without_outline_next_to_the_new_one():
    c = _case("gliederung")
    assert sorted((t["file_id"], t["title"]) for t in c["study_tasks"]) == [
        ("skript-1", "Skript.pdf"), ("skript-2", "1 Grundlagen · S. 4–9"), ("skript-2", "2 Methoden · S. 9–20")]
    c = _case("teile")
    assert sorted(t["title"] for t in c["study_tasks"]) == ["Folien lang.pdf (Teil 1/2)", "Folien lang.pdf (Teil 2/2)", "Kapitel 7.pdf (Teil 1/2)"]
    c = _case("andere_lehrwoche")
    assert sorted(t["title"] for t in c["study_tasks"]) == ["10_12112026.pdf", "Skript.pdf", "Skript.pdf · S. 30–60"]


def test_weekly_test_once_per_subject_and_week_free_tasks_stay():
    c = _case("wochentest")
    assert sorted((t["type"], t["package_id"]) for t in c["study_tasks"]) == [
        ("frei", 2), ("frei", 4), ("test", 1), ("test", 3), ("wiederholung", 1)]


def test_planner_blocks_stay_as_learning_time():
    c = _case("stundenplaner")
    assert [(p["id"], p["start_time"], p["end_time"]) for p in c["study_packages"]] == [(1, "08:00", "09:30"), (2, "08:00", "09:30")]
    assert [t["package_id"] for t in c["study_tasks"]] == [1]


def test_day_limit_counts_all_devices_together():
    c = _case("limit_stunden")
    assert [(p["id"], p["date"], p["start_time"]) for p in c["study_packages"]] == [(1, WED, "08:00"), (2, WED, "10:15"), (3, THU, "08:00")]
    c = _case("limit_faecher")
    assert next(p for p in c["study_packages"] if p["id"] == 3)["date"] == "2026-11-20", "Donnerstag hat schon zwei andere Faecher"
    c = _case("uebereinander")
    assert [(p["start_time"], p["end_time"]) for p in c["study_packages"]] == [("08:00", "09:00"), ("09:00", "10:00")]
    c = _case("nur_konto")
    assert c["result"]["moved"] == 0 and {p["date"] for p in c["study_packages"]} == {WED}
    c = _case("eigenes_bleibt_liegen")
    assert {p["id"]: p["date"] for p in c["study_packages"]} == {1: WED, 2: THU, 3: WED, 4: "2026-11-16", 5: "2026-11-16", 6: "2026-11-16"}
    for name in ("limit_stunden", "limit_faecher", "uebereinander", "eigenes_bleibt_liegen"):
        for p in _case(name)["study_packages"]:
            assert "08:00" <= p["start_time"] < p["end_time"] <= "21:00", (name, p)


def test_slots_and_material_rules():
    from app.plan_merge import same_material, same_planned, slot
    whole = slot({"title": "Skript.pdf"})
    part = slot({"title": "Skript.pdf (Teil 2/3)"})
    rest = slot({"title": "Skript.pdf · S. 30–60"})
    sec = slot({"title": "1 Signale · S. 4–9", "page_from": 4, "page_to": 9})
    assert (whole, part, rest, sec) == ((0, 0, 0, 0, 0), (0, 0, 0, 2, 3), (30, 60, 0, 0, 0), (4, 9, 1, 0, 0))
    assert slot({"title": "Skript.pdf · S. 30–60 (Teil 1/2)"}) == (30, 60, 0, 1, 2) and slot({"title": "Blatt · S. 7"}) == (7, 7, 0, 0, 0)
    assert same_material(whole, whole) and same_material(whole, sec) and same_material(part, whole)
    assert not same_material(part, slot({"title": "x (Teil 1/3)"})) and same_material(part, slot({"title": "x (Teil 2/2)"}))
    assert not same_material(sec, slot({"title": "2 · S. 9–20", "page_from": 9, "page_to": 20})), "Abschnitte teilen sich eine Seite: bleiben"
    assert not same_material(whole, rest), "ganze Datei und Skriptrest nach dem Marker: eine Planung"
    assert same_planned((4, whole), (6, whole)) and not same_planned((4, whole), (6, sec)) and same_planned((4, rest), (6, rest))


# ---------------------------------------------------------------- zwei Geraete gegen den Dienst

def _own_plan(conn, day: str, created: str, status: str = "geplant") -> int:
    """Die Windows-App hat die Datei selbst eingeplant (wie study._insert_package)"""
    mid = conn.execute("INSERT INTO modules(name, semester) VALUES ('Mathe I', 'WiSe 26/27')").lastrowid
    pid = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at, start_time, end_time) "
                       "VALUES (?, ?, 'Mathe I', 'Woche 5 · 16.11. – 22.11.', 5, 60, ?, 0, 1, ?, '08:00', '09:00')", (day, mid, status, created)).lastrowid
    conn.execute("INSERT INTO study_tasks(package_id, type, file_id, title, sort, est_minutes, status, created_at, start_time, end_time) "
                 "VALUES (?, 'uebung', ?, 'Blatt1.pdf', 0, 60, ?, ?, '08:00', '09:00')", (pid, FILE, status, created))
    return pid


def _ipad_plans(app, ipad, day: str, created: str) -> dict:
    """Das iPad hat dieselbe Datei auf einen anderen Tag gelegt und war beim Abgleich schneller"""
    r = ipad_push(app, ipad, [
        {"entity": "modules", "local_id": -1, "updated_at": "2026-11-16T07:00:00.000Z", "data": {"name": "Mathe I", "semester": "WiSe 26/27"}},
        {"entity": "study_packages", "local_id": -5, "updated_at": "2026-11-16T07:00:00.000Z", "data": {
            "date": day, "module_id": -1, "subject": "Mathe I", "title": "Woche 5 · 16.11. – 22.11.", "week_no": 5, "planned_minutes": 60,
            "status": "geplant", "sort": 0, "generated": 1, "created_at": created, "start_time": "10:00", "end_time": "11:00"}},
        {"entity": "study_tasks", "local_id": -9, "updated_at": "2026-11-16T07:00:00.000Z", "data": {
            "package_id": -5, "type": "uebung", "file_id": FILE, "title": "Blatt1.pdf", "sort": 0, "est_minutes": 60, "status": "geplant",
            "created_at": created, "start_time": "10:00", "end_time": "11:00"}}])
    assert [x["status"] for x in r["results"]] == ["created"] * 3, r
    return {x["entity"]: x["id"] for x in r["results"]}


def _service(app, ipad) -> tuple[list, list, list]:
    changes, tombs = ipad_pull(app, ipad)
    return changes.get("study_packages", []), changes.get("study_tasks", []), tombs


@pytest.fixture
def monday(monkeypatch):
    from app import study
    monkeypatch.setattr(study, "today", lambda: TODAY)


def test_cause_two_devices_plan_the_same_file_on_different_days(two_devices, monday, monkeypatch):
    """Die Ursache: beide Geraete planen, bevor der Abgleich die Planung des anderen gebracht hat. Der Abgleich erkennt
    ein Paket nur an Tag + Fach + Titel als dasselbe; an verschiedenen Tagen stehen danach beide im Konto und auf
    jedem Geraet, dieselbe Datei zweimal. Mit dem Zusammenfuehren bleibt die frueher geplante, ueberall dieselbe."""
    app, ipad = two_devices
    from app import db, plan_merge, sync_client
    remote = _ipad_plans(app, ipad, WED, "2026-11-14T16:25:40")
    with db.cursor() as conn:
        own = _own_plan(conn, THU, "2026-11-15T15:30:30")

    # wie bisher (ohne Zusammenfuehren)
    real = plan_merge.after_pull
    monkeypatch.setattr(plan_merge, "after_pull", lambda *a, **k: {})
    assert sync_client.run()["ok"]
    with db.cursor() as conn:
        rows = db.rows(conn, "SELECT p.date FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.file_id=? ORDER BY p.date", (FILE,))
        assert [r["date"] for r in rows] == [WED, THU], "dieselbe Datei zweimal: einmal aus dem Konto, einmal selbst geplant"
    pkgs, tasks, _ = _service(app, ipad)
    assert len(pkgs) == 2 and len(tasks) == 2, "und beide Planungen stehen im Konto, also auch auf dem iPad"

    # mit Zusammenfuehren: die fruehere Planung (iPad) bleibt, die eigene geht ueberall
    monkeypatch.setattr(plan_merge, "after_pull", real)
    out = sync_client.run(force=True)
    assert out["ok"] and out["plan_merged"]["tasks"] == 1 and out["plan_merged"]["packages"] == 1, out
    with db.cursor() as conn:
        assert [r["date"] for r in db.rows(conn, "SELECT date FROM study_packages")] == [WED]
        assert db.row(conn, "SELECT COUNT(*) n FROM study_tasks WHERE file_id=?", (FILE,))["n"] == 1
        assert not db.row(conn, "SELECT 1 FROM study_packages WHERE id=?", (own,))
    pkgs, tasks, tombs = _service(app, ipad)
    assert [p["id"] for p in pkgs] == [remote["study_packages"]] and [t["id"] for t in tasks] == [remote["study_tasks"]]
    assert sorted(t["entity"] for t in tombs) == ["study_packages", "study_tasks"], "das iPad (auch eine aeltere App) bekommt die Loeschmarken"
    again = sync_client.run(force=True)
    assert again["ok"] and again["pushed"] == 0 and again["deleted"] == 0 and again["plan_merged"]["tasks"] == 0, again


def test_own_unsent_planning_never_reaches_the_account(two_devices, monday):
    """Kommt vom Konto schon eine Planung, uebernimmt das Geraet sie: die eigene, noch nicht gesendete geht nicht erst
    ins Konto (keine Loeschmarke, kein Doppel auf anderen Geraeten) - auch wenn sie frueher geplant war."""
    app, ipad = two_devices
    from app import db, sync_client
    remote = _ipad_plans(app, ipad, WED, "2026-11-15T15:30:30")
    with db.cursor() as conn:
        _own_plan(conn, THU, "2026-11-14T16:25:40")
    out = sync_client.run()
    assert out["ok"] and out["plan_merged"] == {"tasks": 1, "packages": 1, "empty": 0, "moved": 0}, out
    with db.cursor() as conn:
        assert [(r["date"], r["start_time"]) for r in db.rows(conn, "SELECT date, start_time FROM study_packages")] == [(WED, "10:00")]
    pkgs, tasks, tombs = _service(app, ipad)
    assert [p["id"] for p in pkgs] == [remote["study_packages"]] and len(tasks) == 1
    assert [t for t in tombs if t["entity"].startswith("study_")] == [], "nie im Konto gewesen: keine Loeschmarke"


def test_started_own_planning_stays_and_the_untouched_twin_goes(two_devices, monday):
    """Begonnenes bleibt immer: hier gewinnt die eigene, schon erledigte Aufgabe; das unberuehrte Paket des iPads geht."""
    app, ipad = two_devices
    from app import db, sync_client
    _ipad_plans(app, ipad, WED, "2026-11-14T16:25:40")
    with db.cursor() as conn:
        _own_plan(conn, "2026-11-13", "2026-11-12T09:00:00", status="erledigt")
        conn.execute("UPDATE study_tasks SET done_at='2026-11-13T18:00:00', actual_minutes=55")
    out = sync_client.run()
    assert out["ok"] and out["plan_merged"]["tasks"] == 1, out
    with db.cursor() as conn:
        assert [(r["date"], r["status"]) for r in db.rows(conn, "SELECT date, status FROM study_packages")] == [("2026-11-13", "erledigt")]
    pkgs, tasks, _ = _service(app, ipad)
    assert [(p["date"], p["status"]) for p in pkgs] == [("2026-11-13", "erledigt")]
    assert [(t["status"], t["actual_minutes"]) for t in tasks] == [("erledigt", 55)]


def test_hosted_calendar_merges_what_two_older_apps_pushed(two_devices, monday):
    """Im Dienst selbst (Web, PC ueber den Dienst): zwei aeltere Apps haben dieselbe Datei gesendet; der Lernkalender
    im Browser fuehrt sie zusammen, die Geraete bekommen die Loeschmarke."""
    app, ipad = two_devices
    from test_sync_client import _hosted
    first = _ipad_plans(app, ipad, WED, "2026-11-14T16:25:40")
    r = ipad_push(app, ipad, [
        {"entity": "study_packages", "local_id": -6, "updated_at": "2026-11-16T07:05:00.000Z", "data": {
            "date": THU, "module_id": first["modules"], "subject": "Mathe I", "title": "Woche 5 · 16.11. – 22.11.", "week_no": 5, "planned_minutes": 60,
            "status": "geplant", "sort": 0, "generated": 1, "created_at": "2026-11-15T15:30:30"}},
        {"entity": "study_tasks", "local_id": -7, "updated_at": "2026-11-16T07:05:00.000Z", "data": {
            "package_id": -6, "type": "uebung", "file_id": FILE, "title": "Blatt1.pdf", "sort": 0, "est_minutes": 60, "status": "geplant",
            "created_at": "2026-11-15T15:30:30"}}])
    assert [x["status"] for x in r["results"]] == ["created", "created"]
    assert len(_service(app, ipad)[0]) == 2
    st, cal = _hosted(app, "GET", f"/api/calendar?start={TODAY.isoformat()}&end=2026-11-22", headers=ipad)
    assert st == 200, cal
    pkgs, tasks, tombs = _service(app, ipad)
    assert [p["id"] for p in pkgs] == [first["study_packages"]] and [t["id"] for t in tasks] == [first["study_tasks"]]
    assert sorted(t["entity"] for t in tombs) == ["study_packages", "study_tasks"]
