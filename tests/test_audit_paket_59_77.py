"""Audit 09.11.2026, Pakete 59/61/77 (Geraete-Abgleich der Windows-App, Abbruch zwischen Serverannahme und lokaler
Zuordnung). Bericht docs/audit/AUDIT-2026-11-09-PAKET-59-61-70-71-76-77.md. Aufbau wie tests/test_sync_client.py
(Windows-App mit eigener Datenbank, Dienst per ASGI)."""
import json

import pytest

from test_sync_client import FILE, ipad_pull, page, two_devices  # noqa: F401 - Fixture


class _Killed(Exception):
    pass


def _server_counts(app, ipad):
    changes, _ = ipad_pull(app, ipad)
    return changes


@pytest.mark.parametrize("phase", ["after_push_before_mapping", "after_pull_before_commit"])
def test_p59_05_kill_after_the_server_took_the_push_retries_without_duplicates(two_devices, monkeypatch, phase):
    """P59-05/P59-F5/P77-F5: der Dienst hat die Sendung angenommen (Commit), die Windows-App endet vor dem Sichern der
    Zuordnung (Prozess-Abbruch, Stromausfall: die lokale Transaktion wird zurueckgerollt). Der naechste Lauf sendet
    dieselben op_ids erneut: keine doppelten Module, Pakete, Aufgaben oder Striche, die Zuordnung steht danach."""
    app, ipad = two_devices
    from app import db, sync_client
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, semester) VALUES ('Analysis', 'WiSe 26/27')").lastrowid
        pid = conn.execute("INSERT INTO study_packages(date, module_id, title, planned_minutes) VALUES ('2026-11-09', ?, 'Blatt 2', 60)", (mid,)).lastrowid
        conn.execute("INSERT INTO study_tasks(package_id, type, title) VALUES (?, 'uebung', 'Aufgabe 2')", (pid,))
        conn.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", (FILE, json.dumps(page("win-x"))))

    target = "handle_results" if phase == "after_push_before_mapping" else "mark_applied_tombstones"
    original = getattr(sync_client.Client, target)
    calls = {"n": 0}

    def killed(self, *a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            raise _Killed("Prozess beendet")
        return original(self, *a, **k)
    monkeypatch.setattr(sync_client.Client, target, killed)

    first = sync_client.run()
    assert not first["ok"], "der erste Lauf bricht ab"
    if phase == "after_push_before_mapping":
        mid_server = _server_counts(app, ipad)
        assert [m["name"] for m in mid_server["modules"]] == ["Analysis"], "der Dienst hat die Sendung schon angenommen"

    out = sync_client.run()
    assert out["ok"], out
    again = sync_client.run()
    assert again["ok"] and again["pushed"] == 0, again

    changes = _server_counts(app, ipad)
    assert [m["name"] for m in changes["modules"]] == ["Analysis"], "kein doppeltes Modul im Dienst"
    assert [p["title"] for p in changes["study_packages"]] == ["Blatt 2"]
    assert [t["title"] for t in changes["study_tasks"]] == ["Aufgabe 2"]
    assert changes["study_packages"][0]["module_id"] == changes["modules"][0]["id"]
    ids = [o["id"] for o in changes["annotations"][0]["data"]["pages"]["p1"]["objects"]]
    assert ids == ["win-x"], "Strich genau einmal"
    with db.cursor() as conn:
        assert [r["name"] for r in db.rows(conn, "SELECT name FROM modules")] == ["Analysis"], "lokal kein Doppel"
        assert db.row(conn, "SELECT COUNT(*) AS n FROM study_packages")["n"] == 1
        mapped = db.rows(conn, "SELECT entity FROM sync_link_map WHERE entity IN ('modules','study_packages','study_tasks')")
        assert sorted(r["entity"] for r in mapped) == ["modules", "study_packages", "study_tasks"], "Zuordnung steht"
        data = json.loads(db.row(conn, "SELECT data FROM annotations WHERE file_id=?", (FILE,))["data"])
        assert [o["id"] for o in data["pages"]["p1"]["objects"]] == ["win-x"]


# ====================================================================== P73-F6 / P72-F4: ganze Zeilen im Abgleich

def _task(conn, db):
    pid = conn.execute("INSERT INTO study_packages(date, title, planned_minutes, status, sort, generated, created_at) "
                       "VALUES ('2026-11-10', 'P', 30, 'geplant', 0, 0, '2026-11-01')").lastrowid
    tid = conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) "
                       "VALUES (?, 'lesen', 'T', 0, 30, 'geplant', '2026-11-01')", (pid,)).lastrowid
    base = dict(db.row(conn, "SELECT * FROM study_tasks WHERE id=?", (tid,)))
    whole = {k: base[k] for k in ("package_id", "type", "title", "sort", "est_minutes", "status")}
    return tid, base["sync_version"], whole


def test_p73_f6_service_merges_only_the_fields_a_device_marks_as_changed(app):
    """Vertrag G2: ein Eintrag darf `changed` tragen (Felder, die das Geraet seit seiner Basis geaendert hat). Bei
    Konflikt (veraltete base_version) zaehlen nur diese; die uebrigen Werte der ganzen Zeile sind der alte Stand des
    Geraets und ueberschreiben nichts. A hakt ab, B aendert spaeter offline die Dauer: beides bleibt."""
    from app import db, sync
    with db.cursor() as conn:
        tid, v, whole = _task(conn, db)
        sync.push(conn, "windows", [{"entity": "study_tasks", "id": tid, "base_version": v, "updated_at": "2026-11-09T10:00:00.000Z",
                                     "data": {**whole, "status": "erledigt"}, "changed": ["status"]}], now="2026-11-09T10:30:00.000Z")
        out = sync.push(conn, "ipad", [{"entity": "study_tasks", "id": tid, "base_version": v, "updated_at": "2026-11-09T11:00:00.000Z",
                                        "data": {**whole, "est_minutes": 45}, "changed": ["est_minutes"]}], now="2026-11-09T11:30:00.000Z")
        row = db.row(conn, "SELECT status, est_minutes FROM study_tasks WHERE id=?", (tid,))
    assert (row["status"], row["est_minutes"]) == ("erledigt", 45)
    assert out["results"][0]["status"] == "conflict" and out["results"][0]["client_won"] == ["est_minutes"]


def test_p73_f6_without_changed_the_old_rule_stays(app):
    """Alte Geraete (ohne `changed`): unveraendert, ganze Zeile, spaeterer Schreiber je Feld (Vertrag bisher)."""
    from app import db, sync
    with db.cursor() as conn:
        tid, v, whole = _task(conn, db)
        sync.push(conn, "windows", [{"entity": "study_tasks", "id": tid, "base_version": v, "updated_at": "2026-11-09T10:00:00.000Z",
                                     "data": {**whole, "status": "erledigt"}}], now="2026-11-09T10:30:00.000Z")
        sync.push(conn, "ipad", [{"entity": "study_tasks", "id": tid, "base_version": v, "updated_at": "2026-11-09T11:00:00.000Z",
                                  "data": {**whole, "est_minutes": 45}}], now="2026-11-09T11:30:00.000Z")
        row = db.row(conn, "SELECT status, est_minutes FROM study_tasks WHERE id=?", (tid,))
    assert (row["status"], row["est_minutes"]) == ("geplant", 45)


def test_p73_f6_done_on_the_ipad_survives_a_later_offline_change_on_windows(two_devices):
    """Ende zu Ende: Aufgabe auf beiden Geraeten. Das iPad hakt ab; Windows hat die Dauer offline spaeter geaendert und
    gleicht danach ab. Die Erledigung bleibt, die neue Dauer auch (Windows meldet nur die geaenderten Felder)."""
    app, ipad = two_devices
    from app import db, sync_client
    from test_sync_client import ipad_push
    with db.cursor() as conn:
        pid = conn.execute("INSERT INTO study_packages(date, title, planned_minutes) VALUES ('2026-11-10', 'Blatt 3', 30)").lastrowid
        conn.execute("INSERT INTO study_tasks(package_id, type, title, est_minutes, status) VALUES (?, 'lesen', 'Kapitel 3', 30, 'geplant')", (pid,))
    assert sync_client.run()["ok"]
    changes, _ = ipad_pull(app, ipad)
    task = changes["study_tasks"][0]
    ipad_push(app, ipad, [{"entity": "study_tasks", "id": task["id"], "base_version": task["sync_version"],
                           "updated_at": "2026-11-09T10:00:00.000Z", "data": {"status": "erledigt"}}])
    with db.cursor() as conn:                                   # offline, spaeter als das iPad
        conn.execute("UPDATE study_tasks SET est_minutes=45")             # Trigger: Version hoch, Zeit jetzt
    sent = []
    real_call = sync_client._call

    def recording(method, path, body=None, *a, **k):
        if path == "/api/sync/push":
            sent.extend(body["items"])
        return real_call(method, path, body, *a, **k)
    mp = pytest.MonkeyPatch()
    mp.setattr(sync_client, "_call", recording)
    try:
        out = sync_client.run()
    finally:
        mp.undo()
    task_items = [i for i in sent if i["entity"] == "study_tasks"]
    assert task_items and task_items[0]["changed"] == ["est_minutes"], task_items
    assert task_items[0]["data"]["title"] == "Kapitel 3", "data bleibt die ganze Zeile"
    assert out["ok"], out
    changes, _ = ipad_pull(app, ipad)
    t = changes["study_tasks"][0]
    assert (t["status"], t["est_minutes"]) == ("erledigt", 45), "Erledigung des iPads und Dauer von Windows bleiben"
    with db.cursor() as conn:
        local = db.row(conn, "SELECT status, est_minutes FROM study_tasks")
    assert (local["status"], local["est_minutes"]) == ("erledigt", 45)
