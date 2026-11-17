""""Neu" nur 24 Stunden (Auftrag des Inhabers 17.11.2026: "wenn etwas laenger als 24 Std in der App ist, automatisch nicht
mehr neu") und erst nach dem ersten Einlesen eines Kurses ("Ja, so bauen": was beim allerersten Einlesen schon da war,
gilt gar nicht als neu). Eine Regel fuer alle Stellen (`study.new_file_sql`): nie geoeffnet, vor hoechstens 24 Stunden
eingetragen (`first_seen`) und nach dem ersten vollstaendigen Einlesen des Kurses dazugekommen
(`courses.first_listed_at`, `studip_sync.mark_first_listing`). Dieselben Ablaeufe wie Neu24StundenTests.swift und
NeuNachErstemEinlesenTests.swift im iPad-Kern; 1:1 verglichen wird in den gemeinsamen Fixtures (library-files.json,
study-modules.json, studip-import.json, timetable-logic.json, schema/legacy.json)."""
import json
import os
import sqlite3
import time
from datetime import date

import pytest
from conftest import asgi_call

NOW = "2026-11-17T13:20:05"
LISTED = "2026-11-01T08:00:00"          # Dateiliste der Testkurse zum ersten Mal eingelesen


def _call(app, method, path, body=None, status=200):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    assert st == status, (method, path, st, raw[:300])
    return json.loads(raw) if raw else None


@pytest.fixture
def clock(monkeypatch):
    """Uhr des Dienstes (`db.now_iso`) einfrieren und weiterstellbar machen"""
    from app import db
    state = {"now": NOW}
    monkeypatch.setattr(db, "now_iso", lambda: state["now"])
    return state


def _setup(p):
    """Ein Modul mit vier nie als gelesen markierten Dateien: 23 Stunden alt, 25 Stunden alt, 23 Stunden alt aber
    geoeffnet, ohne Eintragezeit. Die Dateiliste des Kurses wurde am 1.11. zum ersten Mal eingelesen: alles kam danach."""
    from app import db
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES (?, '#175ee8', 97, 't')", (f"Neu24-{p}",)).lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at, first_listed_at) VALUES (?,?,?, 'vorlesung', 1, ?, 't', ?)",
                     (f"{p}-c", f"Neu24-{p}", f"Neu24-{p}", mid, LISTED))
        for fid, first_seen, seen in [("jung", "2026-11-16T14:20:05", 0), ("alt", "2026-11-16T12:20:05", 0),
                                      ("offen", "2026-11-16T14:20:05", 1), ("ohne", None, 0)]:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, first_seen, status, seen_by_user) VALUES (?,?,?,?,?, 'neu', ?)",
                         (f"{p}-{fid}", f"{p}-c", f"Vorlesung {fid}.pdf", 1_794_000_000, first_seen, seen))
    return mid


def _new(files, p):
    return sorted(f["id"] for f in files if f["id"].startswith(p + "-") and f.get("is_new") == 1)


def test_grenze_ist_24_stunden(clock, monkeypatch):
    from app import study
    assert study.NEW_FILE_HOURS == 24
    assert study.new_since() == "2026-11-16T13:20:05"
    assert study.new_file_sql("2026-11-16T13:20:05") == (
        "(f.seen_by_user=0 AND f.first_seen IS NOT NULL AND f.first_seen>='2026-11-16T13:20:05' "
        "AND (f.id LIKE 'demo-%' OR f.first_seen>(SELECT k.first_listed_at FROM courses k WHERE k.id=f.course_id)))")
    assert study.new_file_sql() == study.new_file_sql("2026-11-16T13:20:05")
    # wirkliche 24 Stunden ueber die Zeitumstellung (25.10.2026): 14:30 Winterzeit - 24 h = 15:30 Sommerzeit (wie der iPad-Kern)
    saved = os.environ.get("TZ")
    monkeypatch.setenv("TZ", "Europe/Berlin")
    time.tzset()
    try:
        clock["now"] = "2026-10-25T14:30:05"
        assert study.new_since() == "2026-10-24T15:30:05"
    finally:
        if saved is None:
            monkeypatch.delenv("TZ")
        else:
            monkeypatch.setenv("TZ", saved)
        time.tzset()


def test_alle_stellen_sagen_dasselbe(app, clock):
    from app import db, timetable
    p = "n24a"
    mid = _setup(p)
    want = [f"{p}-jung"]
    # Moduldetail: Zaehler und Dateizeilen (auch in den Wochen)
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert d["new_count"] == 1
    assert len(d["files"]) == 4 and all(f["is_new"] in (0, 1) for f in d["files"])
    assert _new(d["files"], p) == want
    in_weeks = [f for w in d["weeks"] for k in ("vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges") for f in w[k]]
    assert len(in_weeks) == 4 and _new(in_weeks, p) == want
    assert all(f["status"] == "neu" for f in d["files"]), "der Lernstand bleibt, wie er ist"
    # Modulkarte
    card = next(m for m in _call(app, "GET", "/api/modules") if m["id"] == mid)
    assert card["new_count"] == 1 and card["file_count"] == 4
    # Uebersicht
    dash = _call(app, "GET", "/api/dashboard")
    assert [f["id"] for f in dash["new_files"] if f["id"].startswith(p + "-")] == want
    assert next(m for m in dash["modules"] if m["id"] == mid)["new_count"] == 1
    assert [f["id"] for f in _call(app, "GET", "/api/overview")["new_files"] if f["id"].startswith(p + "-")] == want
    # Kurse
    course = next(c for c in _call(app, "GET", "/api/courses") if c["id"] == f"{p}-c")
    assert course["new_count"] == 1 and course["file_count"] == 4
    # Bibliothek
    lib = [f for f in _call(app, "GET", "/api/library")["files"] if f["id"].startswith(p + "-")]
    assert len(lib) == 4 and all(f["is_new"] in (0, 1) for f in lib)
    assert _new(lib, p) == want
    # Unterlagen am Termin
    with db.cursor() as conn:
        mats = timetable.materials_for_event(conn, {"module_id": mid}, date(2026, 11, 17))
    assert len(mats) == 4 and _new(mats, p) == want


def test_genau_an_der_grenze(app, clock):
    from app import db
    p = "n24g"
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, kind, active, created_at, first_listed_at) VALUES (?, 'Neu24 Grenze', 'vorlesung', 1, 't', ?)",
                     (f"{p}-c", LISTED))
        for fid, first_seen in [("genau", "2026-11-16T13:20:05"), ("sekunde", "2026-11-16T13:20:04"), ("leer", "")]:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, first_seen, status) VALUES (?,?,?,?,?, 'neu')",
                         (f"{p}-{fid}", f"{p}-c", f"{fid}.pdf", 1_794_000_000, first_seen))
    lib = _call(app, "GET", "/api/library")["files"]
    assert _new(lib, p) == [f"{p}-genau"], "genau 24 Stunden: noch neu; eine Sekunde aelter oder leeres first_seen: nicht mehr"


def test_nach_24_stunden_verschwindet_neu_ohne_zutun(app, clock):
    from app import db
    p = "n24v"
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Neu24-weg', '#175ee8', 96, 't')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at, first_listed_at) "
                     "VALUES (?, 'Neu24-weg', 'Neu24-weg', 'vorlesung', 1, ?, 't', ?)", (f"{p}-c", mid, LISTED))
        conn.execute("INSERT INTO files(id, course_id, name, chdate, first_seen, status) VALUES (?,?, 'a.pdf', 1794000000, '2026-11-16T12:30:00', 'neu')",
                     (f"{p}-a", f"{p}-c"))
    clock["now"] = "2026-11-17T12:00:00"
    assert _call(app, "GET", f"/api/modules/{mid}")["new_count"] == 1, "23,5 Stunden alt: neu"
    clock["now"] = "2026-11-17T13:00:00"          # eine Stunde spaeter: niemand hat etwas getan
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert d["new_count"] == 0 and _new(d["files"], p) == []
    assert [f["id"] for f in _call(app, "GET", "/api/dashboard")["new_files"] if f["id"].startswith(p + "-")] == []
    assert _new(_call(app, "GET", "/api/library")["files"], p) == []
    with db.cursor() as conn:
        row = db.row(conn, "SELECT status, seen_by_user, first_seen FROM files WHERE id=?", (f"{p}-a",))
    assert row == {"status": "neu", "seen_by_user": 0, "first_seen": "2026-11-16T12:30:00"}, "nichts wird als gelesen markiert"


def test_oeffnen_nimmt_neu_sofort_weg(app, clock):
    p = "n24o"
    mid = _setup(p)
    _call(app, "POST", f"/api/files/{p}-jung/opened", {})
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert d["new_count"] == 0 and _new(d["files"], p) == []


# ----------------------------------------------------------------------------
# erst nach dem ersten Einlesen eines Kurses (courses.first_listed_at)
# ----------------------------------------------------------------------------

def _sync(clock, started, courses, abort_in=None):
    """Ein Abgleich zum Zeitpunkt `started` wie run_sync je Kurs: upsert_course, dann store_course_files mit der ganzen
    Liste. `abort_in`: in diesem Kurs bricht der Lauf nach der ersten Datei ab (Zeile steht, Liste nicht fertig)."""
    from app import db, studip_sync
    clock["now"] = started

    def download(url, target, size=0):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF-1.4 Test")

    with db.cursor() as conn:
        for cid, title, ids in courses:
            c = {"id": cid, "title": title, "number": None, "semester": "WiSe 2026/27"}
            studip_sync.upsert_course(conn, c, started)
            files = [{"id": f, "name": f"{f}.pdf", "size": 13, "mime": "application/pdf", "author": None, "chdate": 1_794_000_000,
                      "download_url": f"https://studip.test/{f}"} for f in ids]
            if cid == abort_in:
                # Abbruch mitten im Kurs: nur die erste Zeile wird noch geschrieben, die Funktion kommt nicht zu Ende
                conn.execute("INSERT INTO files(id, course_id, name, size, chdate, download_url, first_seen, status, kind) VALUES (?,?,?,13,1794000000,?,?, 'neu', 'pdf')",
                             (files[0]["id"], cid, files[0]["name"], files[0]["download_url"], started))
                continue
            studip_sync.store_course_files(conn, c, files, {}, download, started, [], pause=0)


def _new_everywhere(app, clock, now, p):
    """Was zu einem Zeitpunkt als neu gilt (nur Dateien dieses Tests): Uebersicht, Bibliothek, Modulkarten, Moduldetail
    und Kurse muessen dasselbe sagen."""
    from app import db
    clock["now"] = now
    dash = _call(app, "GET", "/api/dashboard")
    listed = sorted(f["id"] for f in dash["new_files"] if f["id"].startswith(p))
    assert sorted(f["id"] for f in _call(app, "GET", "/api/library")["files"] if f["id"].startswith(p) and f["is_new"] == 1) == listed
    with db.cursor() as conn:
        mods = [r["module_id"] for r in db.rows(conn, "SELECT DISTINCT module_id FROM courses WHERE id LIKE ? AND module_id IS NOT NULL", (p + "%",))]
    cards = {m["id"]: m["new_count"] for m in _call(app, "GET", "/api/modules")}
    rows, counts = [], 0
    for mid in mods:
        d = _call(app, "GET", f"/api/modules/{mid}")
        assert d["new_count"] == cards[mid]
        counts += d["new_count"]
        rows += [f["id"] for f in d["files"] if f["is_new"] == 1]
    assert sorted(rows) == listed and counts == len(listed)
    assert sum(c["new_count"] for c in _call(app, "GET", "/api/courses") if c["id"].startswith(p)) == len(listed)
    return [f[len(p):] for f in listed]


def _listed(cid):
    from app import db
    with db.cursor() as conn:
        return db.row(conn, "SELECT first_listed_at FROM courses WHERE id=?", (cid,))["first_listed_at"]


def test_erstes_einlesen_mit_50_dateien_dann_zwei_neue(app, clock):
    p = "e1-"
    _sync(clock, "2026-11-17T09:00:00", [(p + "k", "Einlesen Analysis Eins", [f"{p}a{i}" for i in range(1, 51)])])
    assert _new_everywhere(app, clock, "2026-11-17T09:05:00", p) == [], "was beim ersten Einlesen schon da war, ist nicht neu"
    assert _listed(p + "k") == "2026-11-17T09:00:00"
    from app import db
    with db.cursor() as conn:
        n = conn.execute("SELECT COUNT(*) FROM files WHERE course_id=? AND seen_by_user=0 AND status='neu'", (p + "k",)).fetchone()[0]
    assert n == 50, "nichts wird dafuer umgeschrieben"
    # zweiter Abgleich: zwei Dateien dazu
    _sync(clock, "2026-11-17T12:00:00", [(p + "k", "Einlesen Analysis Eins", [f"{p}a{i}" for i in range(1, 53)])])
    assert _new_everywhere(app, clock, "2026-11-17T12:05:00", p) == ["a51", "a52"]
    assert _listed(p + "k") == "2026-11-17T09:00:00", "der Zeitpunkt wird genau einmal gesetzt"
    assert _new_everywhere(app, clock, "2026-11-18T11:59:00", p) == ["a51", "a52"]
    assert _new_everywhere(app, clock, "2026-11-18T13:00:00", p) == [], "25 Stunden spaeter verschwindet Neu von selbst"


def test_anfangs_leerer_kurs_und_spaeter_belegter_kurs(app, clock):
    p = "e2-"
    _sync(clock, "2026-11-17T09:00:00", [(p + "leer", "Einlesen Physik Zwei", []), (p + "k", "Einlesen Chemie Zwei", [p + "c1"])])
    assert _listed(p + "leer") == "2026-11-17T09:00:00", "auch eine leere Liste gilt als eingelesen"
    assert _new_everywhere(app, clock, "2026-11-17T09:05:00", p) == []
    # die erste Datei im anfangs leeren Kurs ist neu; ein spaeter belegter Kurs bringt Altdateien mit, die nicht neu sind
    _sync(clock, "2026-11-17T12:00:00", [(p + "leer", "Einlesen Physik Zwei", [p + "erste"]), (p + "k", "Einlesen Chemie Zwei", [p + "c1"]),
                                         (p + "spaet", "Einlesen Logik Zwei", [f"{p}l{i}" for i in range(1, 6)])])
    assert _new_everywhere(app, clock, "2026-11-17T12:05:00", p) == ["erste"]
    assert _listed(p + "spaet") == "2026-11-17T12:00:00"
    _sync(clock, "2026-11-17T16:00:00", [(p + "spaet", "Einlesen Logik Zwei", [f"{p}l{i}" for i in range(1, 7)])])
    assert _new_everywhere(app, clock, "2026-11-17T16:05:00", p) == ["erste", "l6"], "was danach im neuen Kurs dazukommt, ist neu"


def test_abgebrochener_erster_abgleich(app, clock):
    p = "e3-"
    ids = [f"{p}a{i}" for i in range(1, 6)]
    _sync(clock, "2026-11-17T09:00:00", [(p + "k", "Einlesen Algebra Drei", ids[:4])], abort_in=p + "k")
    assert _listed(p + "k") is None, "Zeitpunkt erst, wenn die Liste des Kurses ganz geschrieben ist"
    assert _new_everywhere(app, clock, "2026-11-17T09:05:00", p) == [], "ohne eingelesene Liste ist nichts neu"
    _sync(clock, "2026-11-17T10:00:00", [(p + "k", "Einlesen Algebra Drei", ids[:4])])
    assert _listed(p + "k") == "2026-11-17T10:00:00"
    assert _new_everywhere(app, clock, "2026-11-17T10:05:00", p) == [], "die Reste waren schon da"
    _sync(clock, "2026-11-17T14:00:00", [(p + "k", "Einlesen Algebra Drei", ids)])
    assert _new_everywhere(app, clock, "2026-11-17T14:05:00", p) == ["a5"]


def test_demo_dateien_bleiben_neu_und_eigene_dokumente_nie(app, clock):
    from app import db, demo
    clock["now"] = "2026-11-17T09:00:00"
    with db.cursor() as conn:
        demo.install(conn, today=date(2026, 11, 17))
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, first_seen, status, seen_by_user, kind) "
                     "VALUES ('e4-heft', '__user__', 'Mein Heft', '2026-11-17T09:00:00', 'neu', 0, 'notebook')")
    try:
        clock["now"] = "2026-11-17T09:05:00"
        dash = _call(app, "GET", "/api/dashboard")
        assert sorted(f["id"] for f in dash["new_files"] if f["id"].startswith("demo-")) == sorted(f["id"] for f in demo.FILES)
        assert not [f for f in dash["new_files"] if f["id"] == "e4-heft"], "eigene Dokumente kommen nicht aus der Hochschule"
        lib = {f["id"]: f["is_new"] for f in _call(app, "GET", "/api/library")["files"]}
        assert lib["e4-heft"] == 0 and all(lib[f["id"]] == 1 for f in demo.FILES)
        clock["now"] = "2026-11-18T10:00:00"
        assert not [f for f in _call(app, "GET", "/api/dashboard")["new_files"] if f["id"].startswith("demo-")], "auch Demo nur 24 Stunden"
    finally:
        with db.cursor() as conn:
            demo.remove(conn)
            conn.execute("DELETE FROM files WHERE id='e4-heft'")


def test_update_bestehender_datenbank_keine_flut(tmp_path, monkeypatch):
    """Datenbank einer aelteren Version (ohne courses.first_listed_at): die Migration traegt je Kurs nach, wann seine
    Liste zum ersten Mal eingelesen war. Niemand sieht ploetzlich hunderte neue Dateien; was ein spaeterer Abgleich in
    den letzten 24 Stunden brachte, bleibt neu. Derselbe Fall wie im iPad-Kern (NeuNachErstemEinlesenTests)."""
    from app import db, study
    path = tmp_path / "alt.db"
    monkeypatch.setattr(db, "DB_PATH", path)
    monkeypatch.setattr(db, "now_iso", lambda: "2026-11-10T08:00:00")
    db.init_db()
    with sqlite3.connect(path) as c:
        c.execute("ALTER TABLE courses DROP COLUMN first_listed_at")                # Stand vor dem Update
        for cid in ("k1", "k2", "k3", "k4"):
            c.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES (?, ?, 'vorlesung', 1, '2026-11-16T20:00:00')", (cid, f"Kurs {cid}"))
        rows = [(f"alt{i}", "k1", "2026-11-16T20:00:00") for i in range(1, 301)] + [(f"frisch{i}", "k1", "2026-11-17T08:00:00") for i in (1, 2)]
        rows += [(f"chemie{i}", "k3", "2026-11-17T12:00:00") for i in range(1, 41)] + [("uralt", "k4", None)]
        c.executemany("INSERT INTO files(id, course_id, name, first_seen, status, seen_by_user) VALUES (?, ?, 'x.pdf', ?, 'neu', 0)", rows)
        c.executemany("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,?,0,'Test')",
                      [("2026-11-16T20:00:00", "2026-11-16T20:10:00", 1), ("2026-11-17T08:00:00", "2026-11-17T08:02:00", 1),
                       ("2026-11-17T12:00:00", "2026-11-17T12:01:00", 0)])
    assert "first_listed_at" not in {r[1] for r in sqlite3.connect(path).execute("PRAGMA table_info(courses)")}

    monkeypatch.setattr(db, "now_iso", lambda: NOW)
    db.init_db()                                                                    # das Update
    c = sqlite3.connect(path)
    listed = dict(c.execute("SELECT id, first_listed_at FROM courses"))
    assert listed["k1"] == "2026-11-16T20:10:00", "Ende des ersten erfolgreichen Abgleichs nach der ersten Datei"
    assert listed["k2"] == NOW and listed["k3"] == NOW and listed["k4"] == NOW, "sonst der Zeitpunkt der Umstellung"
    assert listed["__user__"] is None
    new = [r[0] for r in c.execute(f"SELECT f.id FROM files f WHERE {study.new_file_sql()} ORDER BY f.id")]
    assert new == ["frisch1", "frisch2"], "keine Flut (nicht 342), wirklich Neues bleibt neu"
    assert c.execute("SELECT COUNT(*) FROM files WHERE seen_by_user=0 AND status='neu'").fetchone()[0] == 343, "nichts umgeschrieben"
    # die Umstellung laeuft genau einmal
    monkeypatch.setattr(db, "now_iso", lambda: "2026-11-19T09:00:00")
    db.init_db()
    assert dict(c.execute("SELECT id, first_listed_at FROM courses"))["k2"] == NOW
    # rein zusaetzlich: die Spalte darf leer sein und haengt hinten an; aeltere Anweisungen (Spaltenliste ohne sie) laufen weiter
    cols = [(r[1], r[2], r[3], r[4]) for r in c.execute("PRAGMA table_info(courses)")]
    assert cols[-1] == ("first_listed_at", "TEXT", 0, None)
    c.execute("INSERT INTO courses(id, title, number, semester, subject, kind, created_at) VALUES ('alt', 'Altkurs', NULL, NULL, 'Altkurs', 'vorlesung', 't')")
    assert c.execute("SELECT first_listed_at FROM courses WHERE id='alt'").fetchone()[0] is None
