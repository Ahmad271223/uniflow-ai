"""Audit-Pakete 32 (zweite Fassung), 33 und 34 (08.11.2026, docs/audit/AUDIT-2026-11-08-PAKET-32b-34.md):
Geraete-Abgleich ein/aus, Hochschul-Konto entfernen, Zugangsdaten, Module, Lernkalender, Aufgaben, Lernpakete,
Dateien (geoeffnet, Favorit), Verlauf und Stundenplan (`app/server.py`, `app/reset.py`, `app/study.py`,
`app/timetable.py`). Teil 32 ist wortgleich mit Paket 32 aus docs/audit/AUDIT-2026-11-08-PAKET-30-32.md (Tests dort).

Dienst zuerst, dann PC. "Festgenagelt" heisst: Verhalten war schon richtig (oder ist im Vertrag mit dem iPad-Kern
festgeschrieben, packages/shared-contracts/fixtures/local-backend) und bleibt es."""
import json
import threading
import time
from datetime import date, timedelta

import pytest
from conftest import asgi_call
from test_audit_paket_28_29 import _stream
from test_audit_paket_30_32 import call, in_user
from test_reset import filled  # noqa: F401 - Fixture
from test_security import _multipart
from test_subscriptions import hosted, user  # noqa: F401 - hosted ist eine Fixture

TOMORROW = (date.today() + timedelta(days=1)).isoformat()


def package(app, headers=None, **body):
    """Lernpaket mit einer Aufgabe; liefert (Paket-ID, Aufgaben-ID)"""
    st, p = call(app, "POST", "/api/packages", {"date": TOMORROW, "title": "Audit 33", "minutes": 30, **body}, headers=headers)
    assert st == 200, p
    st, full = call(app, "GET", f"/api/packages/{p['id']}", headers=headers)
    return p["id"], full["tasks"][0]["id"]


# ================================================================== PAKET 33

# ---------------------------------------------------------------- P33-01: Geraete-Abgleich ein/aus

def test_p33_01_sync_switch_is_not_a_service_path(hosted):
    """Dienst: der Schalter der Windows-App schrieb service-account.json in den Datenordner des Dienstes (fuer alle
    Konten derselbe), statt wie die anderen /api/studora-Pfade 400 already_hosted zu melden."""
    from app import service_link
    _, h = user(hosted, "p33-01@beispiel.de")
    path = service_link.state_path()
    before = path.read_bytes() if path.exists() else None
    st, d = call(hosted, "POST", "/api/studora/sync/enabled", {"on": False}, headers=h)
    assert st == 400 and d["code"] == "already_hosted", (st, d)
    assert (path.read_bytes() if path.exists() else None) == before, "nichts in den Datenordner des Dienstes"


@pytest.mark.parametrize("on", ["false", "true", 0, 1, None, [False]])
def test_p33_01_sync_switch_needs_a_real_boolean_on_the_pc(app, on):
    from app import sync_client
    sync_client.set_enabled(True)
    st, d = call(app, "POST", "/api/studora/sync/enabled", {"on": on})
    assert st == 422, (on, st, d)
    assert sync_client.status()["enabled"] is True, "'false' schaltete den Abgleich frueher ein"


def test_p33_01_sync_switch_with_booleans_still_works(app):
    from app import sync_client
    assert call(app, "POST", "/api/studora/sync/enabled", {"on": False})[1]["enabled"] is False
    assert call(app, "POST", "/api/studora/sync/enabled", {"on": True})[1]["enabled"] is True


# ---------------------------------------------------------------- P33-02: Hochschul-Konto entfernen (nur PC)

def test_p33_02_reset_waits_for_the_account_sync(app, filled):  # noqa: F811
    """Laeuft der Abgleich mit dem StudiNow-Konto (sync_client), holte er nach dem Loeschen die Daten der vorigen Person
    zurueck in die neue Datenbank; der Reset prueft jetzt auch diese Sperre."""
    from app import db, sync_client
    assert sync_client._lock.acquire(blocking=False)
    try:
        st, d = call(app, "POST", "/api/university/reset")
    finally:
        sync_client._lock.release()
    assert st == 409, (st, d)
    with db.cursor() as conn:
        assert db.row(conn, "SELECT 1 AS ok FROM courses WHERE id='k1'"), "nichts geloescht"
    from app import reset
    reset.wipe(clear_webview=False)                                       # aufraeumen wie die anderen Reset-Tests


def test_p33_02_no_account_sync_starts_while_wiping(app, filled, monkeypatch):  # noqa: F811
    from app import reset, sync_client
    seen = {}
    real = reset.wipe

    def spy(*a, **k):
        seen["locked"] = sync_client._lock.locked()
        return real(*a, **k)
    monkeypatch.setattr(reset, "wipe", spy)
    st, d = call(app, "POST", "/api/university/reset")
    assert st == 200 and d["ok"], d
    assert seen["locked"] is True and not sync_client._lock.locked()


def test_p33_02_reset_forgets_the_last_email(app, filled):  # noqa: F811
    """"Von der vorigen Person bleibt nichts": die Abmeldung behielt last_email (Vorschlag im Anmeldefeld)."""
    from app import reset, service_link
    service_link.save_state({"url": "https://app.studinow.app", "device_id": "win-audit", "user": {"email": "vorige@beispiel.de"}})
    reset.wipe(clear_webview=False)
    st = service_link.load_state()
    assert "vorige@beispiel.de" not in json.dumps(st), st
    assert st.get("device_id") == "win-audit"


def test_p33_02_reset_does_not_follow_symlinks(app, filled, tmp_path):  # noqa: F811
    """Festgenagelt: ein Verweis im Dateiordner wird entfernt, sein Ziel bleibt."""
    from app import config, reset
    outside = tmp_path / "fremd"
    outside.mkdir()
    (outside / "behalten.txt").write_text("x")
    (config.files_dir() / "link").symlink_to(outside, target_is_directory=True)
    reset.wipe(clear_webview=False)
    assert (outside / "behalten.txt").exists() and not (config.files_dir() / "link").exists()


# ---------------------------------------------------------------- P33-03 / P33-12: Modulname

@pytest.mark.parametrize("name", [None, 5, "", "   ", ["Neu"], "x" * 201])
def test_p33_03_module_rename_is_checked(hosted, name):
    _, h = user(hosted, f"p33-03-{len(str(name))}-{type(name).__name__}@beispiel.de")
    st, m = call(hosted, "POST", "/api/modules", {"name": "Analysis"}, headers=h)
    in_user(hosted, h, lambda c: c.execute("INSERT INTO courses(id, title, kind, active, module_id, subject) VALUES ('k33', 'Analysis VL', 'vorlesung', 1, ?, 'Analysis')", (m["id"],)))
    st, d = call(hosted, "PATCH", f"/api/modules/{m['id']}", {"name": name}, headers=h)
    assert st == 400, (name, st, d)
    assert in_user(hosted, h, lambda c: tuple(c.execute("SELECT m.name, c.subject FROM modules m JOIN courses c ON c.module_id=m.id").fetchone())) == ("Analysis", "Analysis")


def test_p33_03_module_rename_trims_and_carries_the_name_along(hosted):
    """Umbenennen ist eine Transaktion (db.cursor: Commit erst am Ende); der Name kommt wie beim Anlegen ohne Rand."""
    _, h = user(hosted, "p33-03-ok@beispiel.de")
    _, m = call(hosted, "POST", "/api/modules", {"name": "Analysis"}, headers=h)
    in_user(hosted, h, lambda c: c.execute("INSERT INTO courses(id, title, kind, active, module_id, subject) VALUES ('k33', 'Analysis VL', 'vorlesung', 1, ?, 'Analysis')", (m["id"],)))
    st, d = call(hosted, "PATCH", f"/api/modules/{m['id']}", {"name": "  Analysis II  "}, headers=h)
    assert st == 200 and d["name"] == "Analysis II", d
    assert in_user(hosted, h, lambda c: c.execute("SELECT subject FROM courses WHERE id='k33'").fetchone()[0]) == "Analysis II"


@pytest.mark.parametrize("name", [5, ["Fach"], "x" * 201])
def test_p33_12_module_name_on_create_is_checked(hosted, name):
    _, h = user(hosted, f"p33-12-{type(name).__name__}-{len(str(name))}@beispiel.de")
    st, d = call(hosted, "POST", "/api/modules", {"name": name}, headers=h)
    assert st == 400, (st, d)
    assert call(hosted, "POST", "/api/modules", {"name": "y" * 200}, headers=h)[0] == 200


# ---------------------------------------------------------------- P33-04: Zugangsdaten

@pytest.mark.parametrize("body", [{"user": 123}, {"user": "luh1", "password": []}, {"user": ["x"]}])
def test_p33_04_credentials_in_the_service_are_always_410(hosted, body):
    """Dienst: Falsche Typen ergaben 500, bevor die Sperre (410 credentials_not_stored) griff."""
    _, h = user(hosted, f"p33-04-{len(json.dumps(body))}@beispiel.de")
    st, d = call(hosted, "PUT", "/api/credentials", body, headers=h)
    assert st == 410 and d["code"] == "credentials_not_stored", (st, d)


@pytest.mark.parametrize("body", [{"user": 123, "password": "p"}, {"user": "luh1", "password": []}, {"user": "luh1", "password": 5}])
def test_p33_04_credentials_on_the_pc_reject_wrong_types(app, monkeypatch, body):
    from app import config
    monkeypatch.setattr(config, "save_credentials", lambda *a: (_ for _ in ()).throw(AssertionError("nicht speichern")))
    st, d = call(app, "PUT", "/api/credentials", body)
    assert st == 422, (st, d)


# ---------------------------------------------------------------- P33-05 / P33-09: Vertrag mit dem iPad-Kern

def test_p33_05_09_pinned_by_the_core_contract():
    """Festgenagelt im Kern-Vertrag study-modules.json (Szenario 3): unbekannter Kurs -> 200 {ok: true}; Text und Objekt
    als expected_materials -> leere Liste (Zeichen/Schluessel werden gefiltert). Aendern nur zusammen mit UniFlowCore."""
    from pathlib import Path
    fx = json.loads((Path(__file__).resolve().parents[1] / "packages/shared-contracts/fixtures/local-backend/study-modules.json").read_text())
    steps = fx["scenarios"][3]["steps"]
    assert any(s["path"] == "/api/courses/gibt-es-nicht/module" and s["status"] == 200 for s in steps)
    assert any('"expected_materials": "tutorium"' in (s.get("raw") or "") and s["status"] == 200 for s in steps)


@pytest.mark.parametrize("value", [5, True, 1.5])
def test_p33_09_expected_materials_number_is_400_not_500(hosted, value):
    _, h = user(hosted, f"p33-09-{value}@beispiel.de")
    _, m = call(hosted, "POST", "/api/modules", {"name": "Physik"}, headers=h)
    st, d = call(hosted, "PATCH", f"/api/modules/{m['id']}", {"expected_materials": value}, headers=h)
    assert st == 400, (st, d)


# ---------------------------------------------------------------- P33-06: Lernkalender lesen

@pytest.mark.parametrize("query", ["start=abc&end=xyz", "start=2026-11-01&end=morgen", "start=0001-01-01&end=9999-12-31",
                                   "start=2026-01-01&end=2040-01-01"])
def test_p33_06_calendar_rejects_bad_dates_and_huge_spans(hosted, query):
    """Ungueltiges Datum: 500 statt 422; 0001-9999 baute eine Liste mit 3,6 Mio. Tagen (Speicher und Minuten eines
    Prozesses im Dienst). Grenze wie im iPad-Kern: hoechstens 3660 Tage (LocalTimetable.maxDays)."""
    _, h = user(hosted, f"p33-06-{abs(hash(query))}@beispiel.de")
    t0 = time.monotonic()
    st, d = call(hosted, "GET", f"/api/calendar?{query}", headers=h)
    assert st == 422, (st, str(d)[:200])
    assert time.monotonic() - t0 < 5


def test_p33_06_calendar_end_before_start_is_empty(hosted):
    """Festgenagelt (Kern-Vertrag study-plan.json, Schritt 66): Ende vor Beginn -> 200 ohne Tage."""
    _, h = user(hosted, "p33-06-leer@beispiel.de")
    st, d = call(hosted, "GET", "/api/calendar?start=2026-11-02&end=2026-11-01", headers=h)
    assert st == 200 and d["days"] == []


# ---------------------------------------------------------------- P33-07: Plan erstellen

@pytest.mark.parametrize("body", [{"replace": "false"}, {"replace": 1}, {"days": "abc"}, {"days": 10 ** 9}, {"start": "morgen"},
                                  {"horizon_x": 1, "days": [7]}])
def test_p33_07_generate_rejects_wrong_values_before_changing_anything(hosted, body):
    """`replace: "false"` ersetzte geplante Pakete; `days: 10**9` liess einen Prozess endlos planen."""
    _, h = user(hosted, f"p33-07-{abs(hash(json.dumps(body)))}@beispiel.de")
    pid, _ = package(hosted, h)
    t0 = time.monotonic()
    st, d = call(hosted, "POST", "/api/calendar/generate", {"start": TOMORROW, **body}, headers=h)
    assert st == 422, (st, d)
    assert time.monotonic() - t0 < 5
    assert call(hosted, "GET", f"/api/packages/{pid}", headers=h)[0] == 200


def test_p33_07_generate_with_real_values_still_works(hosted):
    _, h = user(hosted, "p33-07-ok@beispiel.de")
    for body in ({"days": 7, "replace": False}, {"days": "3", "replace": True}, {"replace": None}, {}):
        st, d = call(hosted, "POST", "/api/calendar/generate", {"start": TOMORROW, **body}, headers=h)
        assert st == 200, (body, d)


@pytest.mark.parametrize("horizon", [10 ** 9, "viel"])
def test_p33_07_suggest_horizon_is_bounded(hosted, horizon):
    """Gleiche Grenze fuer "Neu einplanen" (`horizon`, Schleife je Tag)."""
    _, h = user(hosted, f"p33-07-h-{horizon}@beispiel.de")
    t0 = time.monotonic()
    st, d = call(hosted, "POST", "/api/calendar/suggest", {"horizon": horizon}, headers=h)
    assert st == 422 and time.monotonic() - t0 < 5, (st, d)


# ---------------------------------------------------------------- P33-08: automatische Zuordnung

def test_p33_08_auto_assign_never_touches_manual_assignments(hosted):
    """Festgenagelt: nur Kurse ohne Modul; ein von Hand gewaehltes Modul bleibt, Unsicheres kommt als Liste zurueck."""
    _, h = user(hosted, "p33-08@beispiel.de")
    _, a = call(hosted, "POST", "/api/modules", {"name": "Lineare Algebra"}, headers=h)
    _, b = call(hosted, "POST", "/api/modules", {"name": "Analysis"}, headers=h)
    in_user(hosted, h, lambda c: c.execute("INSERT INTO courses(id, title, kind, active, module_id, subject) VALUES ('k-la', 'Lineare Algebra I', 'vorlesung', 1, ?, 'Analysis')", (b["id"],)))
    st, d = call(hosted, "POST", "/api/modules/auto-assign", headers=h)
    assert st == 200
    assert in_user(hosted, h, lambda c: c.execute("SELECT module_id FROM courses WHERE id='k-la'").fetchone()[0]) == b["id"]


# ---------------------------------------------------------------- P33-10: Aufgabenstatus

@pytest.mark.parametrize("extra", [{"actual_minutes": "abc"}, {"actual_minutes": -5}, {"actual_minutes": 10 ** 6},
                                   {"actual_minutes": [1]}, {"note": 123}, {"note": "x" * 2001}])
def test_p33_10_task_status_checks_minutes_and_note(hosted, extra):
    _, h = user(hosted, f"p33-10-{abs(hash(json.dumps(extra)))}@beispiel.de")
    _, tid = package(hosted, h)
    st, d = call(hosted, "POST", f"/api/tasks/{tid}/status", {"status": "erledigt", **extra}, headers=h)
    assert st == 422, (st, str(d)[:200])
    assert in_user(hosted, h, lambda c: c.execute("SELECT status FROM study_tasks WHERE id=?", (tid,)).fetchone()[0]) == "geplant"


def test_p33_10_task_status_with_valid_values(hosted):
    _, h = user(hosted, "p33-10-ok@beispiel.de")
    _, tid = package(hosted, h)
    st, d = call(hosted, "POST", f"/api/tasks/{tid}/status", {"status": "erledigt", "actual_minutes": "40", "note": "gut"}, headers=h)
    assert st == 200 and d["actual_minutes"] == 40, d
    st, d = call(hosted, "POST", f"/api/tasks/{tid}/status", {"status": "geplant", "actual_minutes": None, "note": None}, headers=h)
    assert st == 200 and d["actual_minutes"] == 40


# ---------------------------------------------------------------- P33-11: Blubber

def test_p33_11_blubber_is_off_and_empty(hosted):
    """Festgenagelt: Abgleich aus (studip_blubber.SYNC_ENABLED), ohne Beitraege keine Gruppe in der Oberflaeche."""
    from app import studip_blubber
    assert studip_blubber.SYNC_ENABLED is False
    _, h = user(hosted, "p33-11@beispiel.de")
    st, d = call(hosted, "GET", "/api/studip/blubber", headers=h)
    assert st == 200 and not d.get("threads"), d


# ================================================================== PAKET 34

# ---------------------------------------------------------------- P34-01: Test zur Aufgabe (nur PC)

def test_p34_01_start_test_is_501_in_the_service(hosted):
    _, h = user(hosted, "p34-01@beispiel.de")
    st, d = call(hosted, "POST", "/api/tasks/1/start-test", headers=h)
    assert st == 501 and d["code"] == "not_available_hosted"


def test_p34_01_parallel_start_test_generates_once(app, monkeypatch):
    """Zwei gleichzeitige Klicks erzeugten zwei Tests (zwei KI-Laeufe); jetzt eine Sperre je Aufgabe."""
    from app import server
    calls = []

    def slow_create(subject, minutes, **kw):
        calls.append(subject)
        time.sleep(0.3)
        from app import db
        with db.cursor() as conn:
            return conn.execute("INSERT INTO tests(subject, title, questions, created_at) VALUES (?, 'Audit-Test', '[]', ?)",
                                (subject or "Allgemein", db.now_iso())).lastrowid
    monkeypatch.setattr(server.planner, "create_test", slow_create)
    pid, _ = package(app, tasks=[{"type": "test", "title": "Test 34", "est_minutes": 20}])
    tid = call(app, "GET", f"/api/packages/{pid}")[1]["tasks"][0]["id"]
    out = []
    threads = [threading.Thread(target=lambda: out.append(call(app, "POST", f"/api/tasks/{tid}/start-test"))) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert [s for s, _ in out] == [200, 200], out
    assert len(calls) == 1 and out[0][1]["test_id"] == out[1][1]["test_id"], (calls, out)


# ---------------------------------------------------------------- P34-02: Import-Vorschau (nur PC)

def test_p34_02_import_preview_is_501_in_the_service(hosted):
    _, h = user(hosted, "p34-02@beispiel.de")
    body, ctype = _multipart("upload", "plan.pdf", b"%PDF-1.4", {"source": "pdf"})
    st, _, b = asgi_call(hosted, "POST", "/api/timetable/import/preview", body=body, content_type=ctype, headers=h)
    assert st == 501


def test_p34_02_import_preview_has_an_upload_limit(app):
    """Kein Limit am PC: Starlette las bis zur Caddy-Grenze und `await upload.read()` alles in den Speicher."""
    from app import server
    st, pulled = _stream(app, "POST", "/api/timetable/import/preview", [b"x" * 1024] * 3,
                         content_length=server.MAX_IMPORT_BYTES + (2 << 20), ctype="multipart/form-data; boundary=x")
    assert st == 413 and pulled == 0, (st, pulled)


@pytest.mark.parametrize("source,name,fail", [("pdf", "plan.pdf", False), ("pdf", "plan.pdf", True), ("image", "plan.png", False),
                                              ("image", "plan.png", True)])
def test_p34_02_import_preview_leaves_no_temp_files(app, monkeypatch, source, name, fail):
    import shutil
    from app import config, extract, timetable
    shutil.rmtree(config.data_dir() / "imports", ignore_errors=True)

    def parse(conn, raw="", image_path=None):
        if fail:
            raise ValueError("KI nicht erreichbar")
        return []
    monkeypatch.setattr(timetable, "ai_parse", parse)
    monkeypatch.setattr(extract, "extract_text", lambda p, n: "Mo 10:00 Analysis")
    body, ctype = _multipart("upload", name, b"%PDF-1.4 inhalt", {"source": source})
    st, _, b = asgi_call(app, "POST", "/api/timetable/import/preview", body=body, content_type=ctype)
    assert st == (500 if fail else 200), b
    left = list((config.data_dir() / "imports").glob("*")) if (config.data_dir() / "imports").exists() else []
    assert left == [], left


# ---------------------------------------------------------------- P34-03: Serie ab Datum teilen

def test_p34_03_splitting_a_series_keeps_later_exceptions(hosted):
    """Ausnahmen ab dem Stichtag (Ausfall, Verschiebung, "nicht hingehen") blieben an der alten Serie, die dort endet –
    sie waren verloren. Jetzt wandern sie zur neuen Serie; fruehere bleiben an der alten."""
    _, h = user(hosted, "p34-03@beispiel.de")
    st, e = call(hosted, "POST", "/api/timetable/events", {"title": "Analysis", "weekday": 0, "start_time": "10:00", "end_time": "11:30",
                                                         "date_from": "2026-10-12", "date_to": "2027-01-30"}, headers=h)
    assert st == 200, e
    for d, typ in (("2026-11-02", "cancelled"), ("2026-11-30", "cancelled"), ("2026-12-07", "skip")):
        assert call(hosted, "POST", "/api/timetable/exceptions", {"event_id": e["id"], "date": d, "type": typ}, headers=h)[0] == 200
    st, d = call(hosted, "PATCH", f"/api/timetable/events/{e['id']}", {"scope": "future", "date": "2026-11-16", "start_time": "12:00",
                                                                        "end_time": "13:30"}, headers=h)
    assert st == 200, d
    rows = in_user(hosted, h, lambda c: c.execute("SELECT event_id, date FROM event_exceptions ORDER BY date").fetchall())
    assert [tuple(r) for r in rows] == [(e["id"], "2026-11-02"), (d["new_id"], "2026-11-30"), (d["new_id"], "2026-12-07")], rows
    day = call(hosted, "GET", "/api/timetable/day?date=2026-11-30", headers=h)[1]
    assert [(x["event_id"], x["status"]) for x in day["events"]] == [(d["new_id"], "ausfall")], day["events"]


# ---------------------------------------------------------------- P34-04 / P34-05: Lernpakete und Minuten

@pytest.mark.parametrize("body", [{"tasks": [None]}, {"tasks": "abc"}, {"tasks": [{"est_minutes": "viel"}]}, {"date": "morgen"},
                                  {"date": None}, {"minutes": "abc"}, {"minutes": -10}, {"tasks": [{"est_minutes": 9_999_999}]}])
def test_p34_04_05_package_create_rejects_wrong_values(hosted, body):
    _, h = user(hosted, f"p34-04-{abs(hash(json.dumps(body)))}@beispiel.de")
    st, d = call(hosted, "POST", "/api/packages", {"date": TOMORROW, "title": "x", **body}, headers=h)
    assert st == 422, (st, d)
    assert in_user(hosted, h, lambda c: c.execute("SELECT COUNT(*) FROM study_packages").fetchone()[0]) == 0


@pytest.mark.parametrize("value", ["abc", -10, 9_999_999, [5]])
def test_p34_05_add_task_and_patch_task_check_minutes(hosted, value):
    _, h = user(hosted, f"p34-05-{abs(hash(json.dumps(value)))}@beispiel.de")
    pid, tid = package(hosted, h)
    st, d = call(hosted, "POST", f"/api/packages/{pid}/tasks", {"title": "neu", "est_minutes": value}, headers=h)
    assert st == 422, (st, d)
    st, d = call(hosted, "PATCH", f"/api/tasks/{tid}", {"est_minutes": value, "title": "nicht gespeichert"}, headers=h)
    assert st == 422, (st, d)
    assert in_user(hosted, h, lambda c: tuple(c.execute("SELECT COUNT(*), MAX(title) FROM study_tasks").fetchone())) == (1, "Audit 33")


def test_p34_05_minutes_as_numeric_text_still_work(hosted):
    """Kern-Vertrag study-plan.json: est_minutes "25" (Text) gilt."""
    _, h = user(hosted, "p34-05-ok@beispiel.de")
    pid, tid = package(hosted, h)
    assert call(hosted, "POST", f"/api/packages/{pid}/tasks", {"title": "neu", "est_minutes": "25"}, headers=h)[0] == 200
    st, d = call(hosted, "PATCH", f"/api/tasks/{tid}", {"est_minutes": 30, "title": "Lesen"}, headers=h)
    assert st == 200 and d["est_minutes"] == 30 and d["title"] == "Lesen"
    # Weboberflaeche mit geleertem Minutenfeld sendet 0: Wert bleibt
    st, d = call(hosted, "PATCH", f"/api/tasks/{tid}", {"est_minutes": 0, "title": "Lesen 2"}, headers=h)
    assert st == 200 and d["est_minutes"] == 30 and d["title"] == "Lesen 2"


# ---------------------------------------------------------------- P34-06 / P34-11: Vertrag

def test_p34_06_11_pinned_by_the_core_contract():
    """Festgenagelt im Kern-Vertrag: `favorite` nach Wahrheitswert wie Python (library-files.json: "ja" -> 1),
    DELETE eines unbekannten Termins -> 200 (timetable-logic.json, /api/timetable/events/999), `remove_ids: "12"`
    entfernt die Termine 1 und 2 (Zeichen des Textes, Schritt 60). Aendern nur zusammen mit UniFlowCore."""
    from pathlib import Path
    base = Path(__file__).resolve().parents[1] / "packages/shared-contracts/fixtures/local-backend"
    lib = json.loads((base / "library-files.json").read_text())["steps"]
    tt = json.loads((base / "timetable-logic.json").read_text())["steps"]
    assert any(s["path"].endswith("/favorite") and "ja" in json.dumps(s.get("body", s.get("raw"))) for s in lib)
    assert any(s["method"] == "DELETE" and s["path"] == "/api/timetable/events/999" and s["status"] == 200 for s in tt)
    assert any(s.get("body", {}).get("remove_ids") == "12" and s["response"]["removed"] == 2 for s in tt if isinstance(s.get("body"), dict))


# ---------------------------------------------------------------- P34-07: Datum im Stundenplan

@pytest.mark.parametrize("path", ["/api/timetable/week?start=abc", "/api/timetable/day?date=2026-02-30", "/api/timetable/free?date=x",
                                  "/api/timetable/free?date=" + "9" * 5000], ids=["week", "day", "free", "lang"])
def test_p34_07_timetable_dates_are_422(hosted, path):
    _, h = user(hosted, f"p34-07-{abs(hash(path))}@beispiel.de")
    st, d = call(hosted, "GET", path, headers=h)
    assert st == 422, (st, str(d)[:200])


def test_p34_07_event_materials_and_attendance_dates_are_422(hosted):
    _, h = user(hosted, "p34-07-ev@beispiel.de")
    _, e = call(hosted, "POST", "/api/timetable/events", {"title": "Analysis", "weekday": 0}, headers=h)
    assert call(hosted, "GET", f"/api/timetable/event-materials/{e['id']}?date=gestern", headers=h)[0] == 422
    assert call(hosted, "POST", "/api/timetable/attendance", {"event_id": e["id"], "date": "gestern", "mode": "today_skip"}, headers=h)[0] == 422


# ---------------------------------------------------------------- P34-08: Verlauf

@pytest.mark.parametrize("limit", [-1, 0, 100_000_000])
def test_p34_08_history_limit_is_bounded(hosted, limit):
    """`LIMIT -1` heisst in SQLite "alles"; jetzt 1 bis 500, ausserhalb 422."""
    _, h = user(hosted, f"p34-08-{limit}@beispiel.de")
    st, d = call(hosted, "GET", f"/api/tasks/history?limit={limit}", headers=h)
    assert st == 422, (st, d)
    assert call(hosted, "GET", "/api/tasks/history?limit=12", headers=h)[0] == 200


# ---------------------------------------------------------------- P34-10: Import bestaetigen

def test_p34_10_import_confirm_only_touches_the_own_database(hosted):
    """Festgenagelt: entries/remove_ids treffen nur Termine der eigenen Konto-Datenbank (Rechte wie DELETE/PATCH)."""
    _, ha = user(hosted, "p34-10-a@beispiel.de")
    _, hb = user(hosted, "p34-10-b@beispiel.de")
    _, e = call(hosted, "POST", "/api/timetable/events", {"title": "A-Termin", "weekday": 1}, headers=ha)
    st, d = call(hosted, "POST", "/api/timetable/import/confirm", {"entries": [{"existing_id": e["id"], "start_time": "07:00", "end_time": "08:00",
                                                                                "title": "x", "weekday": 1}], "remove_ids": [e["id"]]}, headers=hb)
    assert st == 200
    assert call(hosted, "GET", "/api/timetable/events", headers=ha)[1][0]["start_time"] == "08:00"


def test_p34_10_import_confirm_with_broken_entries_is_400(hosted):
    _, h = user(hosted, "p34-10-c@beispiel.de")
    for body in ({"entries": [None]}, {"entries": "abc"}, {"entries": [{"title": "x", "start_time": "10:00", "end_time": "11:00", "weekday": "Mo"}]}):
        st, d = call(hosted, "POST", "/api/timetable/import/confirm", body, headers=h)
        assert st == 400, (body, st, d)


# ---------------------------------------------------------------- P34-12: zuletzt gelesene Seite

@pytest.mark.parametrize("page", ["abc", -1, 0, 10 ** 7, [3]])
def test_p34_12_last_page_is_checked(hosted, page):
    from test_subscriptions import add_file
    _, h = user(hosted, f"p34-12-{abs(hash(json.dumps(page)))}@beispiel.de")
    add_file(hosted, h, "f34")
    st, d = call(hosted, "POST", "/api/files/f34/opened", {"last_page": page}, headers=h)
    assert st == 422, (st, d)
    assert call(hosted, "POST", "/api/files/f34/opened", {"last_page": "7"}, headers=h)[0] == 200


# ---------------------------------------------------------------- Nachtrag: conflicts/reslot ohne Hoechstwert

@pytest.mark.parametrize("days", [10**9, 3661, -1], ids=["riesig", "ueber-grenze", "negativ"])
def test_nachtrag_conflicts_days_is_bounded(hosted, days):
    """`days` lief ohne Hoechstwert in die Tagesschleife (10**9 = Thread endlos bzw. OverflowError); jetzt 0..3660."""
    _, h = user(hosted, f"konflikt-{days}@beispiel.de")
    st, d = call(hosted, "GET", f"/api/timetable/conflicts?days={days}", headers=h)
    assert st == 422, (st, str(d)[:200])


def test_nachtrag_conflicts_default_still_works(hosted):
    _, h = user(hosted, "konflikt-ok@beispiel.de")
    st, d = call(hosted, "GET", "/api/timetable/conflicts", headers=h)
    assert st == 200 and isinstance(d, list), (st, str(d)[:200])


@pytest.mark.parametrize("dates", [["gestern"], "2026-11-09", [None], ["2026-11-09"] * 4000],
                         ids=["kein-datum", "kein-array", "null", "zu-viele"])
def test_nachtrag_reslot_rejects_bad_dates(hosted, dates):
    """Ungueltige Daten gaben 500, eine Liste war unbegrenzt (jede Angabe plant einen Tag neu)."""
    _, h = user(hosted, f"reslot-{abs(hash(str(dates)[:40]))}@beispiel.de")
    st, d = call(hosted, "POST", "/api/timetable/reslot", {"dates": dates}, headers=h)
    assert st == 422, (st, str(d)[:200])


def test_nachtrag_reslot_valid_dates_still_work(hosted):
    _, h = user(hosted, "reslot-ok@beispiel.de")
    st, d = call(hosted, "POST", "/api/timetable/reslot", {"dates": ["2026-11-09"], "only_unset": True}, headers=h)
    assert st == 200 and d["reslotted"] == ["2026-11-09"], (st, str(d)[:200])
