""""Beenden" in der Demo-Leiste (Windows/Einzelplatz, 05.11.2026, nach DemoViews.swift der iPad-App): raeumt alles weg, was die
Demo angelegt oder beim Ausprobieren verursacht hat, und laesst die eigenen Daten in Ruhe."""
import json

from app import db, demo
from conftest import asgi_call


def _counts(conn):
    names = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    # settings: Schalter demo_content; sync_*: Buchfuehrung des Geraete-Abgleichs (Loeschmarken wachsen mit jedem Loeschen)
    return {n: conn.execute(f'SELECT COUNT(*) FROM "{n}"').fetchone()[0] for n in names if n != "settings" and not n.startswith("sync_")}


def _has(conn, table):
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def test_ending_the_demo_leaves_no_trace_in_any_table(app):
    """Nach Anlegen, Benutzen und Entfernen sind alle Tabellen so gross wie vorher (Notizen-Versionen, Plan, Aufgabenindex,
    Verlauf, Wochentests ... eingeschlossen)."""
    db.init_db()
    with db.cursor() as conn:
        demo.remove(conn)
        before = _counts(conn)
        demo.install(conn)
        mod = conn.execute("SELECT id FROM modules WHERE name=?", (demo.MODULE_NAME,)).fetchone()[0]
        task = conn.execute("SELECT id, package_id FROM study_tasks WHERE file_id='demo-skript' LIMIT 1").fetchone()
        now = db.now_iso()
        # Spuren eines Pruefers, der die Demo benutzt
        conn.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES ('demo-skript', 1, '{}', ?)", (now,))
        conn.execute("INSERT INTO recordings(file_id, page, title, url, duration, created_at) VALUES ('demo-skript', 1, 'x', 'a.webm', 1, ?)", (now,))
        conn.execute("INSERT OR IGNORE INTO plans(week_start, generated_at) VALUES ('2026-11-02', ?)", (now,))
        conn.execute("INSERT INTO plan_items(week_start, day, title, file_id, course_id) VALUES ('2026-11-02', 0, 'Demo lernen', 'demo-skript', 'demo-vorlesung')")
        conn.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, at) VALUES (?,?, 'geplant', 'erledigt', ?)", (task["id"], task["package_id"], now))
        conn.execute("INSERT INTO tests(subject, title, duration_min, questions, created_at) VALUES (?, 'Demo-Test', 10, '[]', ?)", (demo.SUBJECT, now))
        conn.execute("INSERT INTO dismissed_tests(module_id, week_no, dismissed_at) VALUES (?, 1, ?)", (mod, now))
        for table, sql, args in (
                ("doc_index", "INSERT INTO doc_index(file_id, version, module_id, tasks) VALUES ('demo-blatt', 'v1', ?, 3)", (mod,)),
                ("task_index", "INSERT INTO task_index(file_id, version, module_id, source, nr) VALUES ('demo-blatt', 'v1', ?, 'uebungsblatt', '1')", (mod,)),
                ("lecture_markers", "INSERT INTO lecture_markers(module_id, file_id, doc_version, page, lecture_date, created_at) VALUES (?, 'demo-folien', 'v1', 2, '2026-11-02', ?)", (mod, now))):
            if _has(conn, table):
                conn.execute(sql, args)
        assert _counts(conn) != before
        demo.remove(conn, thorough=True)
        conn.execute("DELETE FROM plans WHERE week_start='2026-11-02'")        # die Wochenhuelle gehoert nicht zur Demo
        after = _counts(conn)
        assert after == before, {k: (before[k], after.get(k)) for k in before if before[k] != after.get(k)}
        assert conn.execute("SELECT value FROM settings WHERE key='demo_content'").fetchone()[0] == "0"


def test_ending_the_demo_keeps_the_users_own_data(app):
    db.init_db()
    now = db.now_iso()
    with db.cursor() as conn:
        demo.remove(conn)
        conn.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES ('Eigenes Modul', NULL, '#123456', 1, ?)", (now,))
        conn.execute("INSERT INTO tests(subject, title, duration_min, questions, created_at) VALUES ('Mathe', 'Eigener Test', 10, '[]', ?)", (now,))
        demo.install(conn)
        demo.remove(conn, thorough=True)
        assert conn.execute("SELECT COUNT(*) FROM modules WHERE name='Eigenes Modul'").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM tests WHERE title='Eigener Test'").fetchone()[0] == 1
        conn.execute("DELETE FROM modules WHERE name='Eigenes Modul'")
        conn.execute("DELETE FROM tests WHERE title='Eigener Test'")


def test_api_thorough_flag_only_for_the_end_button(app):
    """Die Weboberflaeche beendet mit {"enabled": false, "thorough": true}; das gewohnte {"enabled": false} (und damit der
    Vertrag mit dem Swift-Kern, tools/gen-demo-fixture.py) bleibt unveraendert."""
    db.init_db()

    def post(body):
        st, _, b = asgi_call(app, "POST", "/api/demo", body=json.dumps(body))
        assert st == 200
        return json.loads(b)

    def versions():
        with db.cursor() as conn:
            return conn.execute("SELECT COUNT(*) FROM annotation_versions WHERE file_id='demo-skript'").fetchone()[0]
    for body, left in (({"enabled": False}, 1), ({"enabled": False, "thorough": True}, 0), ({"enabled": False, "thorough": "ja"}, 1)):
        post({"enabled": True})
        with db.cursor() as conn:
            conn.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES ('demo-skript', 1, '{}', ?)", (db.now_iso(),))
        d = post(body)
        assert d["enabled"] is False and d["files"] == 0
        assert versions() == left, body
        with db.cursor() as conn:
            conn.execute("DELETE FROM annotation_versions WHERE file_id='demo-skript'")
