"""Module nie doppelt (Befund Windows-App 27.10.2026: jedes Modul stand dreimal unter „Meine Module“, zwei davon leer).

Nach dem ersten Abgleich luden Übersicht, Module und Bibliothek gleichzeitig; jede Anfrage rief study.ensure_modules,
sah „noch kein Modul“ und legte alle an. Jetzt entscheidet ein INSERT ... WHERE NOT EXISTS mit der Schreibsperre, und
merge_duplicate_modules führt vorhandene Doppel beim Start zusammen, ohne etwas zu verlieren.
"""
import threading
import time


def _clean(conn, name):
    ids = [r[0] for r in conn.execute("SELECT id FROM modules WHERE name=?", (name,))]
    for i in ids:
        for t in ("course_events", "study_packages", "folders", "tests", "dismissed_tests"):
            conn.execute(f"DELETE FROM {t} WHERE module_id=?", (i,))
    conn.execute("DELETE FROM courses WHERE id LIKE 'race-%'")
    conn.execute("DELETE FROM modules WHERE name=?", (name,))


def test_parallel_requests_create_each_module_once(app):
    """Erste Anfrage legt an und hält die Schreibsperre, die zweite startet währenddessen: am Ende ein Modul."""
    from app import db, study
    name = "Testmodul Wettlauf"
    c1, c2 = db.connect(), db.connect()
    try:
        _clean(c1, name)
        for cid in ("race-vl", "race-ue"):
            c1.execute("INSERT INTO courses(id, title, subject, kind, active, created_at) VALUES (?,?,?,?,1,'2026-10-27')",
                       (cid, cid, name, "uebung" if cid.endswith("ue") else "vorlesung"))
        c1.commit()
        study.ensure_modules(c1)                         # legt an, noch nicht bestätigt (Schreibsperre gehalten)
        errors = []

        def second():
            try:
                study.ensure_modules(c2)                 # früher: sah das Modul nicht und legte es ein zweites Mal an
                c2.commit()
            except Exception as e:                       # noqa: BLE001
                errors.append(e)
        t = threading.Thread(target=second)
        t.start()
        time.sleep(0.4)
        c1.commit()
        t.join(10)
        assert not errors, errors
        ids = [r[0] for r in c1.execute("SELECT id FROM modules WHERE name=?", (name,))]
        assert len(ids) == 1, f"Modul doppelt angelegt: {ids}"
        assert {r[0] for r in c1.execute("SELECT module_id FROM courses WHERE id LIKE 'race-%'")} == {ids[0]}
    finally:
        c2.close()
        _clean(c1, name)
        c1.commit()
        c1.close()


def test_merge_duplicate_modules_keeps_everything(app):
    from app import db, study
    name = "Testmodul Doppel"
    with db.cursor() as conn:
        _clean(conn, name)
        ids = []
        for i in range(3):
            cur = conn.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?, 'WiSe 2026/27', '#123456', 0, '2026-10-27T09:40:39')", (name,))
            ids.append(cur.lastrowid)
        empty1, empty2, real = ids
        conn.execute("UPDATE modules SET exam_date='2027-02-10' WHERE id=?", (empty1,))       # Angabe am Doppel
        conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, active, created_at) VALUES ('race-a','A',?, 'vorlesung', ?, 1, '2026-10-27')", (name, real))
        conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, active, created_at) VALUES ('race-b','B',?, 'uebung', ?, 1, '2026-10-27')", (name, real))
        conn.execute("""INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                        VALUES (?, 'Termin', 'vorlesung', 0, '10:00', '11:00', 'weekly', 1, 'manual', '2026-10-27')""", (empty2,))
        conn.execute("INSERT INTO study_packages(date, module_id, subject, title, created_at) VALUES ('2026-11-02', ?, ?, 'Woche 3', '2026-10-27')", (empty1, name))
        conn.execute("INSERT INTO folders(name, module_id, created_at) VALUES ('Ordner', ?, '2026-10-27')", (empty2,))
        conn.execute("INSERT INTO tests(subject, module_id, week_no, auto, questions, created_at) VALUES (?, ?, 1, 1, '[]', '2026-10-27')", (name, real))
        conn.execute("INSERT INTO tests(subject, module_id, week_no, auto, questions, created_at) VALUES (?, ?, 1, 1, '[]', '2026-10-27')", (name, empty1))
        conn.execute("INSERT INTO dismissed_tests(module_id, week_no, dismissed_at) VALUES (?, 2, '2026-10-27')", (real,))
        conn.execute("INSERT INTO dismissed_tests(module_id, week_no, dismissed_at) VALUES (?, 2, '2026-10-27')", (empty2,))
        conn.execute("INSERT INTO dismissed_tests(module_id, week_no, dismissed_at) VALUES (?, 3, '2026-10-27')", (empty2,))
        try:
            assert study.merge_duplicate_modules(conn) == 2
            left = [r[0] for r in conn.execute("SELECT id FROM modules WHERE name=?", (name,))]
            assert left == [real], "es bleibt das Modul mit den Kursen"
            assert conn.execute("SELECT exam_date FROM modules WHERE id=?", (real,)).fetchone()[0] == "2027-02-10"
            for t in ("courses", "course_events", "study_packages", "folders", "tests", "dismissed_tests"):
                refs = {r[0] for r in conn.execute(f"SELECT module_id FROM {t} WHERE module_id IN (?,?,?)", ids)}
                assert refs == {real}, (t, refs)
            tests = sorted(r[0] for r in conn.execute("SELECT auto FROM tests WHERE module_id=?", (real,)))
            assert tests == [0, 1], "beide Tests bleiben, nur einer ist der automatische dieser Woche"
            assert sorted(r[0] for r in conn.execute("SELECT week_no FROM dismissed_tests WHERE module_id=?", (real,))) == [2, 3]
            assert study.merge_duplicate_modules(conn) == 0, "danach ohne Wirkung"
        finally:
            _clean(conn, name)


def test_init_db_merges_duplicates_on_start(app):
    from app import db
    name = "Testmodul Start"
    with db.cursor() as conn:
        _clean(conn, name)
        for _ in range(3):
            conn.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?, 'WiSe 2026/27', '#123456', 0, '2026-10-27')", (name,))
    db.init_db()
    with db.cursor() as conn:
        try:
            assert conn.execute("SELECT COUNT(*) FROM modules WHERE name=?", (name,)).fetchone()[0] == 1
        finally:
            _clean(conn, name)
